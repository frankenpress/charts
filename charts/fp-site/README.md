# fp-site Helm chart

Deploys a [FrankenPress](https://github.com/EightOEight/fp-runtime) WordPress
site (Caddy + FrankenPHP + Souin + S3) to Kubernetes.

## TL;DR

```bash
helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --namespace mysite --create-namespace \
  --set image.repository=ghcr.io/<your-org>/<your-site>,image.tag=v1.0.0 \
  --set site.url=https://mysite.example.com
```

This brings up the site **plus in-cluster MariaDB + Redis + MinIO** for
instant deploy. **Those subcharts are NOT recommended for production** —
see [Production topology](#production-topology) below.

## Requirements

- Kubernetes ≥ 1.27
- Helm ≥ 3.8 (for OCI registry support)

## Architecture

```
                                  ┌──────────────┐
                  ┌──────────────►│  MariaDB     │  (subchart, dev only)
  ┌────────────┐  │                └──────────────┘
  │ fp-site    │──┤              ┌──────────────┐
  │ (FrankenPHP│  ├─────────────►│  Redis       │  (subchart, dev only)
  │  + Caddy + │  │                └──────────────┘
  │  Souin)    │──┘              ┌──────────────┐
  └────────────┘  └──────────────►│  MinIO       │  (subchart, dev only)
                                  └──────────────┘
```

For production, replace the three subcharts with:
- **DragonflyDB Operator** for the cache (drop-in Redis-compatible)
- **MariaDB Operator** for the database
- **AWS S3** (or any S3-compatible: R2, GCS XML) for media

## Production topology

```bash
helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --namespace mysite --create-namespace \
  --values values-prod.yaml
```

```yaml
# values-prod.yaml
image:
  repository: ghcr.io/your-org/your-site
  tag: v1.0.0

site:
  url: https://mysite.example.com
  env: production

replicaCount: 3
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10

ingress:
  enabled: true
  className: nginx
  hostname: mysite.example.com
  tls: true

# Disable in-cluster subcharts.
mariadb:
  enabled: false
redis:
  enabled: false
minio:
  enabled: false

# Point at production services.
externalDatabase:
  host: mysite-mariadb-primary.databases.svc.cluster.local
  port: 3306
  database: mysite
  user: mysite
  existingSecret: mysite-db-credentials
  existingSecretPasswordKey: password

externalCache:
  host: mysite-dragonfly.cache.svc.cluster.local
  port: 6379
  existingSecret: mysite-cache-credentials  # optional

externalS3:
  bucket: mysite-media-prod
  region: eu-west-1
  bucketUrl: https://cdn.mysite.example.com
  existingSecret: mysite-s3-credentials      # keys: access-key, secret-key

# Use External Secrets Operator (recommended) instead of auto-generated keys.
keysSalts:
  autoGenerate: false
  existingSecret: mysite-wp-keys
```

### Recommended production operators

- **[DragonflyDB Operator](https://github.com/dragonflydb/dragonfly-operator)**
  — same RESP protocol as Redis, dramatically better single-node throughput.
  Deploy a `Dragonfly` resource per site or per namespace.
- **[MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator)**
  — declarative MariaDB clusters with backups, replication, and recovery.
- **[External Secrets Operator](https://external-secrets.io/)** — fetch
  WP keys+salts and DB/S3 credentials from your cloud secret manager
  (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault, 1Password, etc.).

## Local development on a kind cluster

```bash
# 1. Spin up a kind cluster
kind create cluster --name fp

# 2. Build the site image and load it into kind
cd /path/to/your-site
docker build -t fp-site:dev --build-arg FP_RUNTIME_IMAGE=fp-runtime --build-arg FP_RUNTIME_VERSION=dev .
kind load docker-image fp-site:dev --name fp

# 3. Install the chart with all subcharts enabled (default)
helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --namespace mysite --create-namespace \
  --set image.repository=fp-site,image.tag=dev,image.pullPolicy=Never

# 4. Wait for pods to come up
kubectl --namespace mysite get pods --watch

# 5. Port-forward and visit the install page
kubectl --namespace mysite port-forward svc/mysite-fp-site 8080:80
open http://localhost:8080/wp/wp-admin/install.php
```

## Values reference

See `values.yaml` (every parameter is documented inline with `## @param`
annotations following the Bitnami chart convention).

## Companion repos

| Repo | Purpose |
|---|---|
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) | Caddy + FrankenPHP + Souin base image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Must-use plugin (S3 bootstrap + Souin invalidator) |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new sites — what this chart deploys |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) (this repo) | Helm charts |

## License

Apache-2.0
