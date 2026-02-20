# Registry Cache

A pull-through proxy for Docker container registries using nginx routing based on DNS virtual hosts.

## Configuration

Copy `.env.example` to `.env` and configure for your environment:

```bash
cp .env.example .env
```

Edit `.env` to set:
- `REGISTRY_DOMAIN`: The base domain for virtual hosts (e.g., `registry.example.com`)
- `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD`: Credentials for docker.io access
- `GHCR_USERNAME` / `GHCR_PASSWORD`: Credentials for ghcr.io access
- `QUAY_USERNAME` / `QUAY_PASSWORD`: Credentials for quay.io access

## Architecture

- **nginx proxy** (port 5000): Single endpoint that routes requests to appropriate registry backends based on the Host header
- **registry-dockerhub** (internal): Caches layers from `docker.io`
- **registry-ghcr** (internal): Caches layers from `ghcr.io`
- **registry-quay** (internal): Caches layers from `quay.io`

Requests are routed based on DNS virtual hostnames (e.g., `docker.io.registry.example.com`, `ghcr.io.registry.example.com`), which all resolve to the nginx proxy IP. The Host header in HTTP requests allows nginx to route each request to the correct upstream registry cache.

## DNS Configuration

Configure your DNS to create virtual host entries, all pointing to the nginx proxy:

```
docker.io.<your-domain>    A    <proxy-ip>
ghcr.io.<your-domain>      A    <proxy-ip>
quay.io.<your-domain>      A    <proxy-ip>
```

Replace `<your-domain>` with the value of `REGISTRY_DOMAIN` from your `.env` file.

## Configure k3d Cluster with containerd

Generate `registries.yaml` directly from the deployed proxy (source of truth):

```bash
./registry-cache.sh registries > registries.yaml
```

You can also fetch it remotely from the proxy:

```bash
curl -fsSL http://<proxy-ip>:5000/registries.yaml -o registries.yaml
```

This keeps the k3d/containerd mirror config synchronized with the nginx virtual host routing currently deployed in `docker-compose.yml`.

Generated example:

**registries.yaml:**

```yaml
mirrors:
  "docker.io":
    endpoint:
      - http://docker.io.<your-domain>:5000
  "ghcr.io":
    endpoint:
      - http://ghcr.io.<your-domain>:5000
  "quay.io":
    endpoint:
      - http://quay.io.<your-domain>:5000

configs:
  "docker.io":
    tls:
      insecure: true
  "ghcr.io":
    tls:
      insecure: true
  "quay.io":
    tls:
      insecure: true
```

Replace `<your-domain>` with your configured `REGISTRY_DOMAIN`.

When containerd pulls `docker.io/library/nginx`, it connects to the virtual host endpoint and includes the Host header. The nginx proxy uses this Host header to route the request to the correct backend cache.

Authentication credentials for upstream registries are managed within each individual registry cache service—not in the k3d configuration. Each registry service in `docker-compose.yml` is configured with its upstream credentials via the `.env` file.

**How fallback works:**

- If a registry is mapped in nginx and configured in docker-compose.yml, containerd pulls from cache
- If a registry is unmapped in nginx, the connection fails and containerd falls back directly to the upstream registry
- This allows transparent fallback for unmapped registries while caching known ones

**Create the cluster:**

```bash
k3d cluster create <cluster-name> \
  --registry-config registries.yaml \
  --network registry-cache \
  ...
```

**Update `registries.yaml` in an existing running cluster:**

`k3d` applies `--registry-config` at cluster/node creation time. To update a running cluster, copy the new config into each k3d node and restart the nodes so `containerd` reloads it.

```bash
CLUSTER=<cluster-name>

# Copy updated registries.yaml into all cluster nodes
for n in $(docker ps --filter "label=io.x-k3d.cluster=$CLUSTER" --format '{{.Names}}'); do
  docker cp registries.yaml "$n:/etc/rancher/k3s/registries.yaml"
done

# Restart the cluster so k3s/containerd reloads registry config
k3d cluster stop "$CLUSTER"
k3d cluster start "$CLUSTER"
```

Verify on a node:

```bash
docker exec k3d-<cluster-name>-server-0 cat /etc/rancher/k3s/registries.yaml
```

If you prefer a clean re-apply, recreate the cluster with `--registry-config registries.yaml`.

**Alternative networking:** If you prefer to let k3d create its own network, add the `registry-cache` container to the k3d cluster's network after creation:

```bash
docker network connect k3d-<cluster-name> registry-cache
```

## Configure Docker Daemon

To use the registry cache with the Docker daemon, update `/etc/docker/daemon.json` to add the mirror and mark it as insecure (required for HTTP/nip.io):

```json
{
  "registry-mirrors": ["http://docker.io.${REGISTRY_DOMAIN}:5000"],
  "insecure-registries": ["docker.io.${REGISTRY_DOMAIN}:5000"]
}
```

Replace `${REGISTRY_DOMAIN}` with your configured domain (e.g., `registry.c0a800e9.nip.io` using nip.io for local testing).

Restart Docker for changes to take effect:

```bash
sudo systemctl daemon-reload && sudo systemctl restart docker
```

Now when you run `docker pull` commands, they will be cached by the registry-cache proxy.

## Benchmark Cache Performance

Use the benchmark script to compare cache vs upstream and tag vs digest pulls:

```bash
./benchmark-cache.sh
```

This runs timed tests for:
- `docker pull` upstream tag vs cache tag
- `docker pull` upstream digest vs cache digest
- `curl` blob download speed from cache vs upstream

At the end of each run, it also prints a `[summary]` section with aggregate stats (`avg`, `median`, `p95`, `min`, `max`) so transient outliers are easy to spot.

Useful options:

```bash
./benchmark-cache.sh --pulls 3 --prune-between
./benchmark-cache.sh --cache-host docker.io.<your-domain>:5000 --repo library/nginx --tag latest --pulls 3
```

Environment overrides are also supported: `CACHE_HOST`, `REPO`, `TAG`, `PULLS`, `PRUNE_BETWEEN`.

## Compare Local Path vs CDN

Use the path comparison script from a client machine to isolate whether cache performance is limited by local network path quality:

```bash
./compare-paths.sh --cache-host docker.io.<your-domain>:5000 --runs 3
```

This runs:
- `iperf3` single stream, parallel (`-P 4`), and reverse (`-R -P 4`) to the cache host
- `curl` A/B tests comparing cache blob speed vs a public CDN file
- Per-run output and average summaries for both cache and CDN transfers

Useful options:

```bash
./compare-paths.sh --cache-host 192.168.0.53:5001 --runs 5
./compare-paths.sh --cache-host 192.168.0.53:5001 --cdn-url https://proof.ovh.net/files/100Mb.dat --runs 3
./compare-paths.sh --cache-host 192.168.0.53:5001 --skip-iperf --runs 3
```

Interpretation guidelines:
- If cache speed is close to `iperf3` throughput, the local path to cache is the limit
- If cache speed is much lower than `iperf3`, investigate cache host NIC/cable/switch/CPU/disk
- If CDN speed is much higher than cache speed, the local path to cache is likely the bottleneck

## Adding More Registry Caches

To add caching for a new registry:

1. Add a new DNS virtual host entry (e.g., `quay.io.<your-domain>` → proxy IP)
2. Add a new registry service to `docker-compose.yml` following the existing pattern
3. Add an upstream block to the nginx config with the container name
4. Add a map entry in the nginx `map $http_host $backend` block (e.g., `"quay.io.${REGISTRY_DOMAIN}:5000" quay_backend;`)
5. Update k3d `registries.yaml` for any clusters that need to use the new registry
  - Re-generate from the running proxy: `./registry-cache.sh registries > registries.yaml`

The single nginx endpoint and virtual host approach means:
- Existing k3d clusters with unmapped registries will automatically fall back to pulling directly from upstream
- New clusters can immediately benefit from any new cache added to docker-compose.yml by updating their registries.yaml

