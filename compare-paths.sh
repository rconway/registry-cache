#!/usr/bin/env bash
set -euo pipefail

CACHE_HOST=""
REPO="library/nginx"
TAG="latest"
RUNS=3
CDN_URL="https://speed.cloudflare.com/__down?bytes=100000000"
BLOB_DIGEST=""
SKIP_IPERF=false
IPERF_PORT=5201
CDN_INSECURE=false

usage() {
  cat <<EOF
Usage: ./compare-paths.sh --cache-host <host:port> [options]

Required:
  --cache-host <host:port>       Cache endpoint (example: registry.rconway.uk:5001)

Options:
  --repo <name>                  Image repo path (default: library/nginx)
  --tag <tag>                    Image tag (default: latest)
  --runs <n>                     Repetitions per test (default: 3)
  --blob-digest <sha256:...>     Skip manifest lookup and test this blob directly
  --cdn-url <url>                Public file URL for internet baseline
                                 (default: https://speed.cloudflare.com/__down?bytes=100000000)
  --cdn-insecure                 Skip TLS verification for CDN URL (testing only)
  --iperf-port <port>            iperf3 server port on cache host (default: 5201)
  --skip-iperf                   Skip iperf tests
  --help                         Show this help

Examples:
  ./compare-paths.sh --cache-host registry.rconway.uk:5001
  ./compare-paths.sh --cache-host 192.168.0.53:5001 --runs 5 --repo library/nginx --tag latest
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
    --runs)
      RUNS="$2"; shift 2 ;;
    --blob-digest)
      BLOB_DIGEST="$2"; shift 2 ;;
    --cdn-url)
      CDN_URL="$2"; shift 2 ;;
    --iperf-port)
      IPERF_PORT="$2"; shift 2 ;;
    --cdn-insecure)
      CDN_INSECURE=true; shift ;;
    --skip-iperf)
      SKIP_IPERF=true; shift ;;
    --help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

for cmd in curl python3 awk; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [[ "$SKIP_IPERF" == "false" ]]; then
  command -v iperf3 >/dev/null || { echo "Missing required command: iperf3 (or use --skip-iperf)" >&2; exit 1; }
fi

if [[ -z "$CACHE_HOST" ]]; then
  echo "--cache-host is required" >&2
  usage
  exit 1
fi

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "--runs must be a positive integer" >&2
  exit 1
fi

CACHE_QUERY=""
if [[ "$CACHE_HOST" == docker.io.* ]]; then
  CACHE_QUERY="?ns=docker.io"
fi

CACHE_IPERF_HOST="${CACHE_HOST%%:*}"

resolve_root_digest() {
  local headers digest
  headers=$(curl -fsS -D - -o /dev/null \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://${CACHE_HOST}/v2/${REPO}/manifests/${TAG}${CACHE_QUERY}" 2>/dev/null) || true

  digest=$(awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' <<<"$headers" | tr -d '\r')
  echo "$digest"
}

resolve_blob_digest() {
  local root_digest="$1"
  local root_json manifest_digest manifest_json

  root_json=$(curl -fsS \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://${CACHE_HOST}/v2/${REPO}/manifests/${root_digest}${CACHE_QUERY}")

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
' <<<"$root_json")

  if [[ -z "$manifest_digest" ]]; then
    echo ""
    return 0
  fi

  if [[ "$manifest_digest" == sha256:* ]]; then
    manifest_json=$(curl -fsS \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "http://${CACHE_HOST}/v2/${REPO}/manifests/${manifest_digest}${CACHE_QUERY}")
  else
    manifest_json="$root_json"
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

run_curl() {
  local label="$1"
  local url="$2"
  local out curl_opts=()
  if [[ "$CDN_INSECURE" == "true" && "$label" == cdn-run* ]]; then
    curl_opts+=("-k")
  fi

  if out=$(curl "${curl_opts[@]}" -LfsS -o /dev/null -w '%{http_code}|%{time_total}|%{size_download}|%{speed_download}|%{remote_ip}' "$url" 2>/dev/null); then
    printf '%s|%s\n' "$label" "$out"
  else
    printf '%s|ERR|0|0|0|n/a\n' "$label"
  fi
}

print_summary() {
  local prefix="$1"
  local file="$2"
  awk -F'|' -v pfx="$prefix" '
    $1 ~ pfx && $2 ~ /^[0-9]+$/ && $2 != "000" {
      n += 1
      t += $3
      b += $4
      s += $5
    }
    END {
      if (n == 0) {
        print pfx "-summary|no-data"
      } else {
        avg_t = t / n
        avg_b = b / n
        avg_s = s / n
        printf "%s-summary|runs=%d|avg_time=%.3fs|avg_bytes=%.0f|avg_speed=%.0fB/s|avg_speed=%.2fMB/s\n", pfx, n, avg_t, avg_b, avg_s, avg_s/1048576
      }
    }
  ' "$file"
}

if [[ -z "$BLOB_DIGEST" ]]; then
  ROOT_DIGEST=$(resolve_root_digest)
  if [[ -z "$ROOT_DIGEST" ]]; then
    echo "Failed to resolve root digest for ${REPO}:${TAG} from cache ${CACHE_HOST}" >&2
    exit 1
  fi
  BLOB_DIGEST=$(resolve_blob_digest "$ROOT_DIGEST")
  if [[ -z "$BLOB_DIGEST" ]]; then
    echo "Failed to resolve blob digest for ${REPO}:${TAG}" >&2
    exit 1
  fi
fi

CACHE_BLOB_URL="http://${CACHE_HOST}/v2/${REPO}/blobs/${BLOB_DIGEST}${CACHE_QUERY}"

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

echo "Target: cache=${CACHE_HOST} repo=${REPO}:${TAG} runs=${RUNS}"
echo "Blob:   ${BLOB_DIGEST}"
echo "CDN:    ${CDN_URL}"
echo

if [[ "$SKIP_IPERF" == "false" ]]; then
  echo "[iperf3]"
  iperf3 -c "$CACHE_IPERF_HOST" -p "$IPERF_PORT" | sed 's/^/iperf-single|/'
  iperf3 -c "$CACHE_IPERF_HOST" -p "$IPERF_PORT" -P 4 | sed 's/^/iperf-p4|/'
  iperf3 -c "$CACHE_IPERF_HOST" -p "$IPERF_PORT" -R -P 4 | sed 's/^/iperf-rev-p4|/'
  echo
fi

echo "[curl-ab]"
for i in $(seq 1 "$RUNS"); do
  run_curl "cache-run${i}" "$CACHE_BLOB_URL" | tee -a "$TMP_OUT"
  run_curl "cdn-run${i}" "$CDN_URL" | tee -a "$TMP_OUT"
done

echo
print_summary "cache-run" "$TMP_OUT"
print_summary "cdn-run" "$TMP_OUT"

echo
cat <<EOF
Interpretation:
- If cache avg speed ~= iperf capacity to cache host, LAN path is limiting cache pulls.
- If cache avg speed is much lower than iperf, check cache host NIC/cables/switch and host CPU/disk.
- If CDN avg speed is much higher than cache, your local path to cache host is currently the bottleneck.
EOF
