#!/bin/sh
set -e

echo "Installing dependencies..."
apk add --no-cache curl jq

NEXUS_URL="http://nexus:8081"

echo "Waiting for Nexus API..."
until curl -sf -o /dev/null "$NEXUS_URL/service/rest/v1/status"; do
  sleep 3
done

echo "Waiting for Nexus repository subsystem..."
until curl -sf "$NEXUS_URL/service/rest/v1/repositories" | grep -q '\['; do
  sleep 3
done

echo "Nexus is fully ready."

NEW_ADMIN_PASSWORD=$(cat /run/secrets/admin-password 2>/dev/null || echo "")
if [ -z "$NEW_ADMIN_PASSWORD" ]; then
  echo "ERROR: admin-password secret not found"
  exit 1
fi
if [ "$NEW_ADMIN_PASSWORD" = "changeme" ]; then
  echo "ERROR: admin password cannot be the default value 'changeme'"
  exit 1
fi
AUTH="admin:$NEW_ADMIN_PASSWORD"

TEMPLATE_DIR="/config/repos"
WORK_DIR="/tmp/rendered"

OTP_FILE="/nexus-data/admin.password"

###############################################################################
# 1. Bootstrap admin password if first-time setup
###############################################################################
if [ -f "$OTP_FILE" ]; then
  echo "First-time Nexus setup detected."

  OTP=$(cat "$OTP_FILE")

  echo "Setting admin password..."
  curl -sf \
    -u "admin:$OTP" \
    -X PUT "$NEXUS_URL/service/rest/v1/security/users/admin/change-password" \
    -H "Content-Type: text/plain" \
    --data "$NEW_ADMIN_PASSWORD"

  rm -f "$OTP_FILE"
  echo "Bootstrap complete."
else
  echo "Nexus admin password already configured."
fi

###############################################################################
# 2. Accept Community Edition EULA (required for CE 3.77.0+)
###############################################################################
echo "Accepting Community Edition EULA..."

EULA_DATA=$(curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/system/eula")
if echo "$EULA_DATA" | jq -e '.accepted == false' >/dev/null 2>&1; then
  # Modify the response to set accepted=true and POST it back
  EULA_ACCEPT=$(echo "$EULA_DATA" | jq '.accepted = true')
  curl -sf -u "$AUTH" \
    -X POST "$NEXUS_URL/service/rest/v1/system/eula" \
    -H "Content-Type: application/json" \
    -d "$EULA_ACCEPT" \
    >/dev/null 2>&1 || echo "EULA acceptance failed."
  echo "EULA accepted."
else
  echo "EULA already accepted."
fi

###############################################################################
# 3. Enable anonymous access
###############################################################################
echo "Enabling anonymous access..."
curl -sf -u "$AUTH" \
  -X PUT "$NEXUS_URL/service/rest/v1/security/anonymous" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "userId": "anonymous", "realmName": "NexusAuthenticatingRealm"}' \
  || echo "Anonymous access may already be enabled."

###############################################################################
# 4. Wait for security subsystem
###############################################################################
echo "Waiting for Nexus security subsystem..."
until curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/realms/active" | jq -e . >/dev/null 2>&1; do
  sleep 3
done

###############################################################################
# 5. Activate Docker realms
###############################################################################
echo "Configuring security realms..."

REALMS_JSON='["NexusAuthenticatingRealm","DockerToken"]'
echo "Setting realms to: $REALMS_JSON"

curl -sf -u "$AUTH" \
  -X PUT "$NEXUS_URL/service/rest/v1/security/realms/active" \
  -H "Content-Type: application/json" \
  -d "$REALMS_JSON" \
  || echo "Realm update failed."

###############################################################################
# 6. Render templates
###############################################################################
mkdir -p "$WORK_DIR"

render_repo() {
  NAME="$1"
  TEMPLATE="$TEMPLATE_DIR/$NAME.json.template"
  OUTPUT="$WORK_DIR/$NAME.json"

  if [ -f "$TEMPLATE" ]; then
    USERNAME=$(cat /run/secrets/${NAME}-username 2>/dev/null || echo "")
    PASSWORD=$(cat /run/secrets/${NAME}-token 2>/dev/null || echo "")

    sed \
      -e "s/__USERNAME__/$USERNAME/g" \
      -e "s/__PASSWORD__/$PASSWORD/g" \
      "$TEMPLATE" > "$OUTPUT"
  else
    cp "$TEMPLATE_DIR/$NAME.json" "$OUTPUT"
  fi
}

echo "Rendering repository templates..."
for FILE in $TEMPLATE_DIR/*.json*; do
  NAME=$(basename "$FILE" | sed 's/.json.*//')
  render_repo "$NAME"
done

###############################################################################
# 7. Reconcile repositories
###############################################################################
DESIRED=$(ls "$WORK_DIR" | sed 's/.json//')
ACTUAL=$(curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories" | jq -r '.[].name')

echo "Desired repos: $DESIRED"
echo "Actual repos:  $ACTUAL"

# Delete obsolete repos
for REPO in $ACTUAL; do
  if ! echo "$DESIRED" | grep -q "^$REPO$"; then
    echo "Deleting obsolete repo: $REPO"
    curl -s -u "$AUTH" -X DELETE "$NEXUS_URL/service/rest/v1/repositories/$REPO"
  fi
done

###############################################################################
# Helper: determine repo type from JSON
###############################################################################
repo_type() {
  FILE="$1"
  if jq -e '.group' "$FILE" >/dev/null 2>&1; then
    echo "group"
  elif jq -e '.proxy' "$FILE" >/dev/null 2>&1; then
    echo "proxy"
  else
    echo "hosted"
  fi
}

###############################################################################
# 7b. ORDERING FIX — sort repos by type
###############################################################################
PROXY_REPOS=""
GROUP_REPOS=""
HOSTED_REPOS=""

for REPO in $DESIRED; do
  FILE="$WORK_DIR/$REPO.json"
  TYPE=$(repo_type "$FILE")

  case "$TYPE" in
    proxy)  PROXY_REPOS="$PROXY_REPOS $REPO" ;;
    group)  GROUP_REPOS="$GROUP_REPOS $REPO" ;;
    hosted) HOSTED_REPOS="$HOSTED_REPOS $REPO" ;;
  esac
done

ORDERED="$HOSTED_REPOS $PROXY_REPOS $GROUP_REPOS"

###############################################################################
# 7c. Create/update desired repos in correct order
###############################################################################
# Set FORCE_REPO_UPDATE=true to recreate existing repos (deletes cached data)
FORCE_UPDATE="${FORCE_REPO_UPDATE:-false}"

for REPO in $ORDERED; do
  FILE="$WORK_DIR/$REPO.json"
  TYPE=$(repo_type "$FILE")

  if echo "$ACTUAL" | grep -q "^$REPO$"; then
    if [ "$FORCE_UPDATE" = "true" ]; then
      echo "Force updating repo: $REPO (will lose cached data)"
      curl -s -u "$AUTH" -X DELETE "$NEXUS_URL/service/rest/v1/repositories/$REPO"
      sleep 1
    else
      echo "Repo already exists: $REPO (skipping, set FORCE_REPO_UPDATE=true to update)"
      continue
    fi
  else
    echo "Creating repo: $REPO"
  fi

  case "$TYPE" in
    proxy)  ENDPOINT="docker/proxy" ;;
    group)  ENDPOINT="docker/group" ;;
    hosted) ENDPOINT="docker/hosted" ;;
  esac

  curl -s -u "$AUTH" \
    -X POST "$NEXUS_URL/service/rest/v1/repositories/$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d @"$FILE"
done

echo "Reconciliation complete."
