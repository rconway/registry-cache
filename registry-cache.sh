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

if [ "$1" = "registries" ]; then
  REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-reg.127.0.0.1.nip.io}"
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
  docker-compose pull
  docker-compose down
  docker-compose up -d
else
  echo "Running..."
  docker-compose pull
  docker-compose up -d
fi
