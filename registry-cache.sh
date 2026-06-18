#!/usr/bin/env bash

ORIG_DIR="$(pwd)"
cd "$(dirname "$0")"
BIN_DIR="$(pwd)"

onExit() {
  cd "${ORIG_DIR}"
}
trap onExit EXIT

[[ -e .env ]] && source .env

mkdir -p data/dockerhub
mkdir -p data/ghcr
mkdir -p data/quay

if [[ -z "${REGISTRY_DOMAIN}" ]]; then
  if command -v ip &>/dev/null; then
    IP_ADDRESS="`ip route get 1.1.1.1 2>/dev/null | awk '{print $7}'`"
  elif command -v hostname &>/dev/null; then
    IP_ADDRESS="`hostname -i 2>/dev/null | awk '{ for(i=1; i<=NF; i++){if($i !~ /^127\./){print $i;exit}}}'`"
  fi
  IP_ADDRESS="${IP_ADDRESS:-127.0.0.1}"
  NIP_ADDRESS="`echo $IP_ADDRESS | awk '{split($1,a,".");printf("%02x%02x%02x%02x.nip.io\n",a[1],a[2],a[3],a[4]);exit}'`"
  REGISTRY_DOMAIN="registry.${NIP_ADDRESS}"
fi
export REGISTRY_DOMAIN

if [ "$1" = "registries" ]; then
  URL="${REGISTRIES_URL:-http://${REGISTRY_DOMAIN}:5000/registries.yaml}"

  if [ -n "$2" ]; then
    curl -fsSL "$URL" > "$2"
    echo "Wrote $2 from $URL"
  else
    curl -fsSL "$URL"
  fi
elif [ "$1" = "down" ]; then
  echo "Shutting down..."
  docker-compose down
elif [ "$1" = "restart" ]; then
  echo "Restarting..."
  echo "Using REGISTRY_DOMAIN=${REGISTRY_DOMAIN}"
  docker-compose pull
  docker-compose down
  docker-compose up -d
else
  echo "Running..."
  echo "Using REGISTRY_DOMAIN=${REGISTRY_DOMAIN}"
  docker-compose pull
  docker-compose up -d
fi
