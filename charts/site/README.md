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

# 5. Retrieve the auto-generated admin password
kubectl --namespace mysite get secret mysite-fp-site-install \
  -o jsonpath='{.data.admin_password}' | base64 -d

# 6. Port-forward and log into wp-admin
kubectl --namespace mysite port-forward svc/mysite-fp-site 8080:80
open http://localhost:8080/wp/wp-admin/
```

## First install

The chart runs `wp core install` and `wp core update-db` from a
post-install/post-upgrade Helm hook Job — a fresh `helm install`
produces a usable WordPress site without any manual `kubectl exec`.

The install step is idempotent (`wp core is-installed` short-circuits
re-runs), so it's safe across `helm upgrade`s and pod restarts.

### Default (auto-generated admin)

By default the chart creates a `<release>-fp-site-install` Secret with
a random 32-char password. Retrieve it with:

```bash
kubectl --namespace mysite get secret mysite-fp-site-install \
  -o jsonpath='{.data.admin_password}' | base64 -d
```

Override the username, email, or password at install time:

```bash
helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --set siteInstall.adminUser=alice \
  --set siteInstall.adminEmail=alice@example.com \
  --set siteInstall.adminPassword=please-change-me
```

### Bring-your-own Secret (any source)

Point at a pre-existing Secret — the chart doesn't care how it got
there. `kubectl create secret`, External Secrets Operator, Sealed
Secrets, SOPS — all work the same:

```bash
kubectl create secret generic mysite-admin \
  --from-literal=admin_user=alice \
  --from-literal=admin_email=alice@example.com \
  --from-literal=admin_password=$(openssl rand -base64 24)

helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --set siteInstall.existingSecret=mysite-admin
```

If the Secret uses different key names (e.g. one synced from AWS
Secrets Manager), specify them:

```yaml
siteInstall:
  existingSecret: mysite-admin
  existingSecretAdminUserKey: username
  existingSecretAdminEmailKey: email
  existingSecretAdminPasswordKey: password
```

### Password rotation

**Admin password.** WordPress stores a *hash* of the password in
`wp_users`, so changing the Secret value alone won't update the live
login. The chart ships with `syncAdminCredentials: true` by default —
an initContainer on every site Pod that reads the install Secret and
runs `wp user update` when the DB has drifted from it. Pair with a
controller that rolls the Deployment when the Secret changes (e.g.
[stakater/Reloader](https://github.com/stakater/Reloader)) and
rotation is self-driving end-to-end:

```yaml
# Annotate the Deployment so Reloader watches the install Secret and
# rolls the Pods when its contents change. Use `commonAnnotations`
# (lands on the Deployment's metadata.annotations, which is what
# Reloader watches), NOT `podAnnotations` (lands on the pod-template).
# For an auto-generated install Secret, the name is
# `<release>-fp-site-install`.
commonAnnotations:
  secret.reloader.stakater.com/reload: "mysite-fp-site-install"
```

```bash
# Whatever rotates your Secret (manual edit, ESO sync from cloud
# secrets manager, sealed-secret rotation, etc.) updates the value:
kubectl patch secret mysite-fp-site-install \
  -p '{"stringData":{"admin_password":"new-value"}}'

# Reloader rolls the Deployment → initContainer detects drift →
# wp user update runs → DB caught up to Secret. No `helm upgrade`
# required.
```

The initContainer is idempotent: it short-circuits when the DB hash
already matches the Secret (via `wp_check_password`). With multiple
replicas under the default rolling update strategy, only the first
Pod to roll runs the update — subsequent Pods see the DB in sync and
exit early, so a single rotation produces at most one DB write and at
most one WP-emitted "Password Changed" notification.

Set `syncAdminCredentials: false` to skip the initContainer entirely
(e.g. when an external IdP owns the WP admin user).

**Database password.** The Deployment, wpcron CronJob, and install Job
all read `DB_PASSWORD` from `secretKeyRef`. When the Secret value
changes, restart the Deployment and pods pick up the new value
automatically — no chart-side reconciliation needed.

```bash
kubectl rollout restart deployment/mysite-fp-site
```

(Rotating the password on the DB server itself is out of scope — that's
the DB's lifecycle. The chart consumes whatever's in the Secret.)

### Skipping install

For sites being restored from an existing database dump, skip the
install Job entirely:

```bash
helm install mysite oci://ghcr.io/eightoeight/charts/fp-site \
  --set siteInstall.enabled=false
```

`wp core update-db` won't run either — make sure your dump is
schema-compatible with the WP core version baked into the site image.

## Values reference

See `values.yaml` (every parameter is documented inline with `## @param`
annotations following the Bitnami chart convention).

## Companion repos

| Repo | Purpose |
|---|---|
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) | Caddy + FrankenPHP + Souin base image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Must-use plugin (S3 bootstrap + Souin invalidator + Site Health + SMTP) |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new sites — what this chart deploys |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) (this repo) | Helm charts |

## License

Apache-2.0
