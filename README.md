# Registry Cache

## Configure Docker Daemon

File `/etc/docker/daemon.json`...

```json
{
  "registry-mirrors": ["http://localhost:5000"]
}
```

Restart docker daemon...

```bash
sudo systemctl restart docker
```

Check...

```bash
docker info | grep -A3 "Registry Mirrors"
```

## Configure k3d Cluster

Create cluster with the following registry settings.

registries.yaml...

```yaml
mirrors:
  "docker.io":
    endpoint:
      - http://registry-cache:5000
```

Create the cluster `<cluster-name>` specifying the registry settings and joining the docker network of the `registry-cache`...

```bash
k3d cluster create <cluster-name> \
  --registry-config "registries.yaml" \
  --network registry-cache \
  ...
```

Alternative to running the k3d cluster in the docker network of the `registry-cache` (ref. `--network registry-cache`) - instead you can allow k3d to create its own dedicated docker network (default behaviour), and then add the `registry-cache` container to the network of the k3d cluster.

```bash
docker network connect k3d-<cluster-name> registry-cache
```
