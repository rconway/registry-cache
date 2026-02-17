# Registry Cache - AI Coding Agent Instructions

## Project Overview
Registry Cache is a **pull-through proxy** for Docker container registries. It runs two Docker Registry v2 services (one for DockerHub, one for GitHub Container Registry) that cache image layers locally, reducing redundant pulls and enabling offline/air-gapped deployments.

## Architecture Essentials

### Multi-Registry Pattern
- **Two independent registries**: `registry-dockerhub` (port 5000) and `registry-ghcr` (port 5001)
- Each configured with `proxy: remoteurl` to their respective upstream registries
- Uses filesystem storage in `./dockerhub` and `./ghcr` directories
- Shared `registry-cache` Docker network for inter-container communication

### Configuration Flow
Registry configurations are **embedded in docker-compose.yml** (not separate files). Authentication credentials come from `.env` environment variables:
- `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` - for upstream DockerHub access
- `GHCR_USERNAME` / `GHCR_PASSWORD` - for upstream GHCR access

## Developer Workflows

### Setup & Operations
```bash
# Start/restart all registries
./registry-cache.sh                # Default: up -d
./registry-cache.sh restart        # Pull latest, stop, restart
./registry-cache.sh down           # Shutdown registries
```

The script ensures required directories (`./dockerhub`, `./ghcr`) exist and runs `docker-compose` operations.

### Integration with Docker & k3d

**Docker daemon configuration** (`/etc/docker/daemon.json`):
```json
{
  "registry-mirrors": ["http://localhost:5000"]
}
```

**k3d cluster integration**:
- Create cluster with custom `registries.yaml` pointing `docker.io` endpoint to `http://registry-cache:5000`
- Join k3d to the `registry-cache` Docker network: `--network registry-cache`
- Or connect manually after cluster creation: `docker network connect k3d-<name> registry-cache`

## Project Patterns & Conventions

### When Modifying Registry Config
- **Edit docker-compose.yml, not filesystem files** - configs are embedded as YAML inline
- Remember both registries need separate configs under the `configs:` section
- Port mapping convention: DockerHub=5000, GHCR=5001 (for easy mental model)

### Environment & Secrets
- `.env` file contains authentication tokens - keep it in `.gitignore` 
- Never commit credentials to the repository
- All registry authentication flows through environment variable substitution in docker-compose

### Storage & Persistence
- Cached layers persist in `./dockerhub/` and `./ghcr/` directories
- These are mounted as volumes; clearing them will force re-pulls of all images

## Key Documentation
- Registry v2 configuration reference: https://docs.docker.com/registry/configuration/
- See README.md for complete Docker daemon and k3d integration examples
