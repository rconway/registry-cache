# Registry Cache - AI Coding Agent Instructions

## Project Overview
Registry Cache is a **pull-through proxy** for Docker container registries using **nginx virtual host routing**. A single nginx proxy (port 5000) routes requests to multiple backend registry caches based on DNS virtual hostnames. This enables scalable, multi-registry caching with a single endpoint.

## Architecture Essentials

### Virtual Host Routing Architecture
- **nginx proxy** (`registry-cache`, port 5000): Single public endpoint that routes based on HTTP Host header
- **Backend registries**: `registry-dockerhub` and `registry-ghcr` run internally (not directly exposed)
- **Routing mechanism**: nginx maps `$http_host` to backend upstreams (e.g., `docker.io.<domain>:5000` → `dockerhub_backend`)
- **DNS virtual hosts**: All registry endpoints (docker.io.<domain>, ghcr.io.<domain>) resolve to the nginx proxy IP
- **Shared network**: `registry-cache` Docker network for inter-container communication

**Key insight**: Clients use virtual hostnames that all point to the same nginx IP. The Host header in HTTP requests tells nginx which backend to route to.

### Configuration Flow
All configurations are **embedded in docker-compose.yml** as inline YAML (not separate files):
- **nginx config**: Contains upstream definitions, `map $http_host $backend` routing table, and proxy server
- **Registry configs**: Each backend has a `proxy: remoteurl` config pointing to its upstream registry

Environment variables from `.env`:
- `REGISTRY_DOMAIN` - Base domain for virtual hosts (e.g., `registry.example.com`)
- `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` - Upstream DockerHub authentication
- `GHCR_USERNAME` / `GHCR_PASSWORD` - Upstream GHCR authentication

**Example virtual host**: `docker.io.registry.example.com:5000` resolves to nginx, which routes to `registry-dockerhub` based on the Host header.

## Developer Workflows

### Initial Setup
```bash
# 1. Configure environment
cp .env.example .env
# Edit .env to set REGISTRY_DOMAIN and credentials

# 2. Start services
./registry-cache.sh                # Default: pull, up -d
```

The script ensures storage directories (`./data/dockerhub`, `./data/ghcr`) exist before starting.

### Operations
```bash
./registry-cache.sh restart        # Pull latest images, restart all services
./registry-cache.sh down           # Shutdown all services
```

### DNS Configuration
Set up DNS A records for virtual hosts pointing to the nginx proxy IP:
```
docker.io.<REGISTRY_DOMAIN>    A    <proxy-ip>
ghcr.io.<REGISTRY_DOMAIN>      A    <proxy-ip>
```

For local testing, use nip.io: `docker.io.registry.192.168.1.100.nip.io` (auto-resolves to 192.168.1.100).

### Integration with k3d
Create `registries.yaml` using virtual host endpoints (**not** localhost ports):
```yaml
mirrors:
  "docker.io":
    endpoint:
      - http://docker.io.<REGISTRY_DOMAIN>:5000
  "ghcr.io":
    endpoint:
      - http://ghcr.io.<REGISTRY_DOMAIN>:5000
configs:
  "docker.io":
    tls:
      insecure: true
  "ghcr.io":
    tls:
      insecure: true
```

Create cluster with network integration:
```bash
k3d cluster create <name> \
  --registry-config registries.yaml \
  --network registry-cache
```

**Fallback behavior**: Unmapped registries automatically fall back to direct upstream pulls when nginx connection fails.

### Integration with Docker Daemon
Update `/etc/docker/daemon.json` to use the virtual host endpoint:
```json
{
  "registry-mirrors": ["http://docker.io.${REGISTRY_DOMAIN}:5000"],
  "insecure-registries": ["docker.io.${REGISTRY_DOMAIN}:5000"]
}
```

Restart Docker: `sudo systemctl daemon-reload && sudo systemctl restart docker`

## Project Patterns & Conventions

### Adding New Registry Backends
Follow this pattern (see README.md "Adding More Registry Caches"):
1. Add DNS virtual host entry (`quay.io.<domain>` → proxy IP)
2. Add registry service to `docker-compose.yml` following existing pattern
3. Add upstream block to nginx config: `upstream quay_backend { server registry-quay:5000; }`
4. Add map entry: `"quay.io.${REGISTRY_DOMAIN}:5000" quay_backend;`
5. Update client `registries.yaml` files for the new registry

### When Modifying Configurations
- **Edit docker-compose.yml only** - all configs are embedded inline under the `configs:` section
- Each registry backend needs its own config with `proxy: remoteurl`, `username`, `password`
- nginx config uses `$$` for literal `$` in embedded YAML (e.g., `$$http_host`)
- Test changes locally with `./registry-cache.sh restart`

### Storage & Persistence
- Cached layers persist in `./data/dockerhub/` and `./data/ghcr/` directories (volume mounts)
- Clearing these directories forces re-download of all cached images

### Environment & Secrets
- `.env` file contains credentials - keep it in `.gitignore`
- `REGISTRY_DOMAIN` is central to the architecture - used in nginx routing and client configs
- All authentication flows through environment variable substitution in docker-compose.yml
