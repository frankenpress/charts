# charts

**FrankenPress Helm charts** — Kubernetes deployment for the [FrankenPress
WordPress stack](https://github.com/frankenpress).

**Documentation:** <https://docs.frankenpress.com/components/charts>

## Charts

| Chart | Description |
|---|---|
| [`site`](./charts/site) | Deploys a single FrankenPress WordPress site. Optionally bundles MariaDB + Redis + MinIO subcharts for instant on-cluster deploy (NOT for production). |

## Install

The charts are published as OCI artifacts on GHCR:

```bash
helm install mysite oci://ghcr.io/frankenpress/charts/site \
  --version 0.12.1 \
  --namespace mysite --create-namespace
```

Each chart's directory contains its own README with full values reference.
See [`charts/site/README.md`](./charts/site/README.md) for `site`.

## Style

All charts here are written **Bitnami chart style**:

- Every public value is annotated with `## @param` so docs can be auto-generated.
- The [`bitnami/common`](https://github.com/bitnami/charts/tree/main/bitnami/common)
  library chart is included as a dependency for consistent helpers
  (`common.names.fullname`, `common.labels.standard`, `common.images.image`,
  `common.tplvalues.render`, etc.).
- Subchart dependencies use Bitnami's OCI registry (`oci://registry-1.docker.io/bitnamicharts`).
- Production-grade defaults for `securityContext`, probes, and resources.

## Production topology

The default chart values bundle in-cluster MariaDB / Redis / MinIO
subcharts so a fresh `helm install` works on a kind cluster with zero
prerequisites. **Those defaults are not recommended for production.**

For production, disable the subcharts and point at managed services or
operator-managed instances:

| Component | Default | Recommended for production |
|---|---|---|
| Database | bitnami/mariadb subchart | [MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator) |
| HTTP cache | bitnami/redis subchart | [DragonflyDB Operator](https://github.com/dragonflydb/dragonfly-operator) (same RESP protocol, dramatically better single-node throughput) |
| Object storage | bitnami/minio subchart | AWS S3 / R2 / GCS XML / etc. |
| WP keys+salts | auto-generated Job | [External Secrets Operator](https://external-secrets.io/) |

See [`charts/site/README.md`](./charts/site/README.md) for an
example production values file.

## Local development

```bash
# Lint
helm lint charts/site

# Render manifests without installing
helm template smoketest charts/site --namespace smoketest

# Pull subchart deps
helm dependency update charts/site

# Unit-test the install Job's shell (no cluster needed)
bats tests/install.bats

# Install on a kind cluster
kind create cluster --name fp
helm install mysite charts/site --namespace mysite --create-namespace
```

## License

Apache-2.0
