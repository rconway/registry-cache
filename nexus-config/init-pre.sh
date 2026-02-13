#!/bin/sh
set -e

mkdir -p /nexus-data/etc

# Disable UI wizard (only if missing)
if [ ! -f /nexus-data/etc/security.properties ]; then
  echo "security-setup-complete=true" > /nexus-data/etc/security.properties
fi

# Disable Docker registry onboarding gate (only if missing)
if [ ! -f /nexus-data/etc/nexus.properties ]; then
  echo "nexus.onboarding.eula.accepted=true" > /nexus-data/etc/nexus.properties
fi

# Ensure Nexus can read/write
chown -R 200:200 /nexus-data/etc
