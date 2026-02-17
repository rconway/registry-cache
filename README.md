# registry-cache

## /etc/docker/daemon.json

```json
{
  "registry-mirrors": ["http://registry.rconway.uk:5000"],
  "insecure-registries": [
    "registry.rconway.uk:5000"
  ]
}
```

Restart the docker daemon after making these changes...

```bash
sudo systemctl daemon-reload && sudo systemctl restart docker
```

## k3d registries.yaml

```yaml
mirrors:
  "*":
    endpoint:
      - http://registry.rconway.uk:5000

configs:
  "registry.rconway.uk:5000":
    tls:
      insecure_skip_verify: true
```
