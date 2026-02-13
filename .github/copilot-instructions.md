# AI Coding Agent Instructions for registry-cache

## Project Overview
**registry-cache** is a Docker-based container registry cache using Sonatype Nexus 3. It provides proxy caching for Docker Hub and GitHub Container Registry (GHCR), reducing bandwidth and improving deployment speed. The project emphasizes declarative, template-driven configuration with automated secret injection.

## Architecture

### Three-Stage Service Initialization (`docker-compose.yml`)
```
nexus-init-pre → nexus → nexus-init-post
```

1. **nexus-init-pre**: Initializes Nexus volume with security config to skip UI wizard
2. **nexus**: Main Nexus 3 service (ports 8081=UI, 5000=Docker registry)
3. **nexus-init-post**: Programmatically configures repositories via REST API

### Key Data Flow
- Secrets (`secrets/*`) → mounted in `nexus-init-post` container
- Templates (`nexus-config/repos/*.json.template`) → rendered with credentials
- Rendered configs → Nexus REST API → repository creation/updates

## Critical Patterns & Conventions

### Repository Template System
Repository configuration uses **JSON templates with `__USERNAME__` and `__PASSWORD__` placeholders**:
```json
// In dockerhub.json.template
"authentication": {
  "type": "username",
  "username": "__USERNAME__",
  "password": "__PASSWORD__"
}
```

The `init-post.sh` script renders these by:
1. Reading credentials from `/run/secrets/{NAME}-{username|token}`
2. Using `sed` to replace placeholders with actual values
3. Writing rendered JSON to `/tmp/rendered/`

**Pattern**: New repository types must follow this template-with-placeholders convention.

### Repository Reconciliation Algorithm
The `init-post.sh` implements **declarative reconciliation** (lines ~120-180):

1. **Discover desired state**: All `*.json*` files in template directory
2. **Discover actual state**: Query `GET /service/rest/v1/repositories`
3. **Delete obsolete**: Remove repos in actual but not in desired
4. **Order by type**: Hosted → Proxy → Group (critical ordering)
5. **Create/update**: Delete then recreate (simpler than patch)

**Why ordering matters**: Group repos depend on component repos being available; proxy repos should exist before groups reference them.

## Developer Workflows

### Launch the Stack
```bash
./registry-cache.sh              # Pull latest images & start
./registry-cache.sh restart      # Full restart (down + up)
./registry-cache.sh down         # Stop all services
```

**Important**: Script manages directory context and Nexus data volume ownership (UID 200:200).

### Debug with Logs
```bash
docker-compose logs -f nexus-init-post  # See configuration steps
docker-compose logs nexus              # Main service logs
```

### Manual API Interaction
```bash
# After reading admin-password secret:
ADMIN_PW=$(cat secrets/admin-password)
curl -u admin:$ADMIN_PW http://localhost:8081/service/rest/v1/repositories | jq .
```

### Add a New Proxy Repository
1. Create `nexus-config/repos/{name}.json.template` with URI and authentication structure
2. If credentials needed: add `secrets/{name}-username` and `secrets/{name}-token` files
3. Update docker-compose `secrets:` section to reference new secret files
4. Run `./registry-cache.sh restart` — reconciliation loop auto-creates it

## Integration Points & External Dependencies

### Sonatype Nexus 3 REST API
- **Status check**: `GET /service/rest/v1/status` (readiness probe)
- **Repository list**: `GET /service/rest/v1/repositories`
- **Repository create**: `POST /service/rest/v1/repositories/{docker/proxy|docker/hosted|docker/group}`
- **Repository delete**: `DELETE /service/rest/v1/repositories/{name}`
- **Admin password change**: `PUT /service/rest/v1/security/users/admin/change-password` (first-time setup)
- **Anonymous access**: `PUT /service/rest/v1/security/anonymous`
- **Security realms**: `PUT /service/rest/v1/security/realms/active`

### Docker Registry Protocol
- Nexus exposes port 5000 for Docker registry v2 protocol
- v1 disabled in templates (`"v1Enabled": false`)
- Uses Docker token authentication realm for layer auth

### Container Runtime Assumptions
- Docker Compose v2 (depends_on uses `service_completed_successfully` and `service_started`)
- UID/GID 200:200 for Nexus process (set by init-pre.sh)
- Linux/Unix file ownership model

## Project-Specific Constraints & Anti-Patterns

### Do NOT:
- **Hardcode credentials** anywhere except `secrets/` files — all config is version-controlled
- **Attempt to patch repositories** via API — the reconciliation always deletes then recreates
- **Rely on file-based Nexus XML config** — use REST API for any programmatic changes
- **Skip service dependency ordering** — Nexus must be ready before init-post runs

### Must Handle:
- **First-time vs. subsequent deployments**: Check for `/nexus-data/admin.password` file (OTP exists on first boot only)
- **Credential injection timing**: Wait for security subsystem before API calls (retry loop ~line 75)
- **Port conflicts**: Port 8081 (UI) and 5000 (registry) must be available
- **Volume permissions**: nexus-data must be writable by UID 200 or `sudo chown` will be needed

## Key Files Reference

| File | Purpose |
|------|---------|
| [registry-cache.sh](registry-cache.sh) | Entry point; orchestrates docker-compose and volume ownership |
| [docker-compose.yml](docker-compose.yml) | Service definitions, volumes, secrets, networking |
| [nexus-config/init-pre.sh](nexus-config/init-pre.sh) | Disables UI wizard, sets correct file ownership |
| [nexus-config/init-post.sh](nexus-config/init-post.sh) | Core: API waits, password reset, repo reconciliation |
| [nexus-config/repos/*.json.template](nexus-config/repos/) | Repository type definitions (proxy/hosted/group) |
| [secrets/*](secrets/) | Credentials (version-controlled; use real values in production) |
