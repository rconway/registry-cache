#!/usr/bin/env bash

ORIG_DIR="$(pwd)"
cd "$(dirname "$0")"
BIN_DIR="$(pwd)"

onExit() {
  cd "${ORIG_DIR}"
}
trap onExit EXIT

mkdir -p nexus-data
sudo chown 200:200 nexus-data

if [ "$1" = "down" ]; then
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
