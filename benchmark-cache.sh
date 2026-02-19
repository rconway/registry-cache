#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

CACHE_HOST_DEFAULT="docker.io.${REGISTRY_DOMAIN:-registry.example.com}:5000"
CACHE_HOST="${CACHE_HOST:-$CACHE_HOST_DEFAULT}"
REPO="${REPO:-library/nginx}"
TAG="${TAG:-latest}"
UPSTREAM_REGISTRY="${UPSTREAM_REGISTRY:-registry-1.docker.io}"
PULLS="${PULLS:-2}"
PRUNE_BETWEEN="${PRUNE_BETWEEN:-false}"

usage() {
  cat <<EOF
Usage: ./benchmark-cache.sh [options]

Options:
  --cache-host <host:port>      Cache endpoint (default: $CACHE_HOST)
  --repo <name>                 Image repo path (default: $REPO)
  --tag <tag>                   Image tag (default: $TAG)
  --pulls <n>                   Repetitions per test (default: $PULLS)
  --prune-between               Run 'docker image prune -af' between docker pull tests
  --help                        Show this help

Environment overrides:
  CACHE_HOST, REPO, TAG, PULLS, PRUNE_BETWEEN, UPSTREAM_REGISTRY

Examples:
  ./benchmark-cache.sh
  ./benchmark-cache.sh --cache-host docker.io.registry.example.com:5000 --repo library/nginx --tag latest --pulls 3
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-host)
      CACHE_HOST="$2"; shift 2 ;;
    --repo)
      REPO="$2"; shift 2 ;;
    --tag)
      TAG="$2"; shift 2 ;;
    --pulls)
      PULLS="$2"; shift 2 ;;
    --prune-between)
      PRUNE_BETWEEN=true; shift ;;
    --help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

for cmd in docker curl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

if ! [[ "$PULLS" =~ ^[0-9]+$ ]] || [[ "$PULLS" -lt 1 ]]; then
  echo "--pulls must be a positive integer" >&2
  exit 1
fi

UPSTREAM_TAG_REF="${REPO#library/}:${TAG}"
if [[ "$REPO" != library/* ]]; then
  UPSTREAM_TAG_REF="${REPO}:${TAG}"
fi

cache_tag_ref() {
  echo "${CACHE_HOST}/${REPO}:${TAG}"
}

CACHE_QUERY=""
if [[ "$CACHE_HOST" == docker.io.* ]]; then
  CACHE_QUERY="?ns=docker.io"
fi

time_cmd() {
  local label="$1"
  shift
  local start end ms
  start=$(date +%s%3N)
  if "$@" >/dev/null 2>&1; then
    end=$(date +%s%3N)
    ms=$((end - start))
    printf "%s|ok|%s\n" "$label" "$ms"
  else
    end=$(date +%s%3N)
    ms=$((end - start))
    printf "%s|fail|%s\n" "$label" "$ms"
  fi
}

clean_local_image() {
  docker image rm -f "$UPSTREAM_TAG_REF" >/dev/null 2>&1 || true
  docker image rm -f "$(cache_tag_ref)" >/dev/null 2>&1 || true
}

resolve_digest() {
  local digest headers
  headers=$(curl -fsS -D - -o /dev/null -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' "http://${CACHE_HOST}/v2/${REPO}/manifests/${TAG}${CACHE_QUERY}" 2>/dev/null) || true
  digest=$(awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' <<<"$headers" | tr -d '\r')
  if [[ -z "$digest" ]]; then
    docker pull "$(cache_tag_ref)" >/dev/null 2>&1 || true
    digest=$(docker image inspect "$(cache_tag_ref)" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F'@' '{print $2}') || true
  fi
  echo "$digest"
}

get_token() {
  local scope token auth=()
  scope="repository:${REPO}:pull"
  if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
    auth=(-u "${DOCKERHUB_USERNAME}:${DOCKERHUB_PASSWORD}")
  fi
  token=$(curl -fsS "${auth[@]}" "https://auth.docker.io/token?service=registry.docker.io&scope=${scope}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))') || true
  echo "$token"
}

select_layer_digest() {
  local root_digest="$1"
  local index_json manifest_digest manifest_json
  index_json=$(curl -fsS -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' "http://${CACHE_HOST}/v2/${REPO}/manifests/${root_digest}${CACHE_QUERY}")

  manifest_digest=$(python3 -c 'import json,sys
obj=json.load(sys.stdin)
if "layers" in obj:
    print(obj.get("config",{}).get("digest",""))
    sys.exit(0)
for m in obj.get("manifests",[]):
    p=m.get("platform",{})
    if p.get("os")=="linux" and p.get("architecture") in ("amd64","x86_64"):
        print(m.get("digest",""))
        sys.exit(0)
if obj.get("manifests"):
    print(obj["manifests"][0].get("digest",""))
' <<<"$index_json")

  if [[ -z "$manifest_digest" ]]; then
    echo ""
    return 0
  fi

  if [[ "$manifest_digest" == sha256:* ]]; then
    manifest_json=$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "http://${CACHE_HOST}/v2/${REPO}/manifests/${manifest_digest}${CACHE_QUERY}")
  else
    manifest_json="$index_json"
  fi

  python3 -c 'import json,sys
obj=json.load(sys.stdin)
layers=obj.get("layers",[])
if not layers:
    print("")
    sys.exit(0)
l=max(layers,key=lambda x:x.get("size",0))
print(l.get("digest",""))
' <<<"$manifest_json"
}

print_header() {
  echo
  echo "Benchmark target:"
  echo "  cache:    http://${CACHE_HOST}"
  echo "  upstream: https://${UPSTREAM_REGISTRY}"
  echo "  image:    ${REPO}:${TAG}"
  echo "  pulls:    ${PULLS}"
  echo
}

run_docker_pull_bench() {
  local digest="$1"
  local upstream_digest_ref cache_digest_ref cache_ref
  upstream_digest_ref="${UPSTREAM_TAG_REF%@*}@${digest}"
  cache_ref="$(cache_tag_ref)"
  cache_digest_ref="${CACHE_HOST}/${REPO}@${digest}"

  echo "[docker pull benchmarks]"
  for i in $(seq 1 "$PULLS"); do
    clean_local_image
    [[ "$PRUNE_BETWEEN" == "true" ]] && docker image prune -af >/dev/null 2>&1 || true
    time_cmd "upstream-tag-run${i}" docker pull "$UPSTREAM_TAG_REF" | tee -a "$RESULTS_FILE"

    clean_local_image
    [[ "$PRUNE_BETWEEN" == "true" ]] && docker image prune -af >/dev/null 2>&1 || true
    time_cmd "cache-tag-run${i}" docker pull "$cache_ref" | tee -a "$RESULTS_FILE"

    clean_local_image
    [[ "$PRUNE_BETWEEN" == "true" ]] && docker image prune -af >/dev/null 2>&1 || true
    time_cmd "upstream-digest-run${i}" docker pull "$upstream_digest_ref" | tee -a "$RESULTS_FILE"

    clean_local_image
    [[ "$PRUNE_BETWEEN" == "true" ]] && docker image prune -af >/dev/null 2>&1 || true
    time_cmd "cache-digest-run${i}" docker pull "$cache_digest_ref" | tee -a "$RESULTS_FILE"
  done
}

run_curl_blob_bench() {
  local blob_digest="$1"
  local token="$2"
  local cache_blob_url upstream_blob_url
  cache_blob_url="http://${CACHE_HOST}/v2/${REPO}/blobs/${blob_digest}${CACHE_QUERY}"
  upstream_blob_url="https://${UPSTREAM_REGISTRY}/v2/${REPO}/blobs/${blob_digest}"

  echo
  echo "[curl blob benchmarks]"
  for i in $(seq 1 "$PULLS"); do
    curl -LfsS -o /dev/null -w "cache-blob-run${i}|ok|%{http_code}|%{time_total}s|%{size_download}|%{speed_download}\n" "$cache_blob_url" | tee -a "$RESULTS_FILE"
    if [[ -n "$token" ]]; then
      curl -LfsS -H "Authorization: Bearer ${token}" -o /dev/null -w "upstream-blob-run${i}|ok|%{http_code}|%{time_total}s|%{size_download}|%{speed_download}\n" "$upstream_blob_url" | tee -a "$RESULTS_FILE"
    else
      echo "upstream-blob-run${i}|skip|no-token|0|0|0" | tee -a "$RESULTS_FILE"
    fi
  done
}

print_ms_summary() {
  local prefix="$1"
  local values
  values=$(awk -F'|' -v p="$prefix" '$1 ~ ("^" p "-run[0-9]+$") && $2=="ok" {print $3}' "$RESULTS_FILE" | sort -n)
  if [[ -z "$values" ]]; then
    echo "${prefix}-summary|no-data"
    return 0
  fi
  printf "%s\n" "$values" | python3 -c 'import math,statistics,sys
vals=[int(x.strip()) for x in sys.stdin if x.strip()]
n=len(vals)
vals.sort()
avg=sum(vals)/n
med=statistics.median(vals)
p95=vals[max(0, math.ceil(0.95*n)-1)]
print(f"runs={n}|avg_ms={avg:.0f}|median_ms={med:.0f}|p95_ms={p95}|min_ms={vals[0]}|max_ms={vals[-1]}")'
}

print_speed_summary() {
  local prefix="$1"
  local rows
  rows=$(awk -F'|' -v p="$prefix" '$1 ~ ("^" p "-run[0-9]+$") && $2=="ok" && $3 ~ /^[0-9]+$/ {gsub(/s$/, "", $4); print $4"|"$6}' "$RESULTS_FILE")
  if [[ -z "$rows" ]]; then
    echo "${prefix}-summary|no-data"
    return 0
  fi
  printf "%s\n" "$rows" | python3 -c 'import math,statistics,sys
times=[]
speeds=[]
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    t,s=line.split("|",1)
    times.append(float(t))
    speeds.append(float(s))
n=len(speeds)
idx=max(0, math.ceil(0.95*n)-1)
speeds_sorted=sorted(speeds)
print(f"runs={n}|avg_time_s={sum(times)/n:.3f}|avg_speed_Bps={sum(speeds)/n:.0f}|median_speed_Bps={statistics.median(speeds):.0f}|p95_speed_Bps={speeds_sorted[idx]:.0f}|avg_speed_MBps={(sum(speeds)/n)/1048576:.2f}")'
}

original_cache_host="$CACHE_HOST"
for candidate in "$CACHE_HOST" 127.0.0.1:5001 localhost:5001; do
  CACHE_HOST="$candidate"
  CACHE_QUERY=""
  if [[ "$CACHE_HOST" == docker.io.* ]]; then
    CACHE_QUERY="?ns=docker.io"
  fi
  digest=$(resolve_digest)
  if [[ -n "$digest" ]]; then
    break
  fi
done

if [[ -z "$digest" ]]; then
  echo "Failed to resolve digest for ${REPO}:${TAG} from cache ${original_cache_host} (also tried 127.0.0.1:5001 and localhost:5001)" >&2
  exit 1
fi

if [[ "$CACHE_HOST" != "$original_cache_host" ]]; then
  echo "Using fallback cache host: ${CACHE_HOST}"
fi

print_header

echo "Resolved digest: ${digest}"

blob_digest=$(select_layer_digest "$digest")
if [[ -z "$blob_digest" ]]; then
  echo "Failed to resolve a blob layer digest from ${digest}" >&2
  exit 1
fi

echo "Selected blob digest: ${blob_digest}"

token=$(get_token)

run_docker_pull_bench "$digest"
run_curl_blob_bench "$blob_digest" "$token"

echo
echo "[summary]"
echo -n "upstream-tag|"; print_ms_summary "upstream-tag"
echo -n "cache-tag|"; print_ms_summary "cache-tag"
echo -n "upstream-digest|"; print_ms_summary "upstream-digest"
echo -n "cache-digest|"; print_ms_summary "cache-digest"
echo -n "cache-blob|"; print_speed_summary "cache-blob"
echo -n "upstream-blob|"; print_speed_summary "upstream-blob"

echo
cat <<EOF
Tips:
- Compare cache vs upstream by matching run numbers.
- If cache is slower only for docker pull but not curl, client runtime unpack/verification is likely dominant.
- If cache and upstream curl are both slow from a remote client, network path is the likely bottleneck.
EOF
