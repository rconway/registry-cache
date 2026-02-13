#!/bin/sh
set -e

mkdir -p /nexus-data/etc

# Ensure Nexus can read/write
chown -R 200:200 /nexus-data/etc
