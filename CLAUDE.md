# CLAUDE.md — charts

Guidance for Claude Code when working in this repo.

## What this repo is

**Helm charts for the FrankenPress stack.** Currently one chart: `site`,
which deploys a single FrankenPress WordPress site to Kubernetes.

Charts are published as OCI artifacts on GHCR:
**`oci://ghcr.io/frankenpress/charts/site`** (latest: `v0.12.0` — `charts/site/Chart.yaml` is authoritative).

Public docs: **<https://docs.frankenpress.com/components/charts>**

## Style: Bitnami chart conventions, throughout

- Every public value in `values.yaml` carries a `## @param <path> <description>` annotation. Bitnami's `readme-generator-for-helm` (and our docs) consume these.
- Naming/labels/image templating goes through [`bitnami/common`](https://github.com/bitnami/charts/tree/main/bitnami/common) helpers (`common.names.fullname`, `common.labels.standard`, `common.images.image`, `common.tplvalues.render`). Don't reinvent them.
- Subchart deps via Bitnami's OCI registry: `oci://registry-1.docker.io/bitnamicharts/<name>`.
- Production-grade `securityContext` defaults that satisfy PSA `restricted:latest` out of the box: `readOnlyRootFilesystem`, `runAsUser:33`, `runAsNonRoot:true`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]` (no `add`), pod-level `seccompProfile.type:RuntimeDefault`. Works with the `runtime` v0.1.x line because that runtime ships FrankenPHP with the `cap_net_bind_service` file capability stripped (`setcap -r`); a custom runtime that re-adds the cap needs the chart values overridden — see the comment block above `containerSecurityContext` in `values.yaml`.

## File layout

- `charts/site/Chart.yaml` — pinned deps:
  - `bitnami/common` (library, always loaded)
  - `bitnami/mariadb` (conditional `mariadb.enabled`)
  - `bitnami/redis` (conditional `redis.enabled`)
  - `bitnami/minio` (conditional `minio.enabled`)
- `charts/site/values.yaml` — single source of truth for the public API. Every value documented inline.
- `charts/site/templates/_helpers.tpl` — chart-local helpers. **Wraps subchart-vs-external resolution** (`site.databaseHost`, `site.cacheHost`, `site.s3Endpoint`, `site.s3SecretName`, etc.) so flipping `<subchart>.enabled: false` is a one-line change in values.
- `charts/site/templates/*.yaml` — single-tenant resources for the site: Deployment, Service, ConfigMap (env), Secret (keys+salts), install Job + its Secret, wpcron CronJob, ServiceAccount, HPA, Ingress, HTTPRoute, ServiceMonitor.
- `charts/site/files/scripts/install.sh` — install/upgrade Job body, sourced into `templates/job-install.yaml` via `.Files.Get`. Pure POSIX shell, env-var driven (`SKIP_EMAIL`, `ACTIVE_THEME`, `SNAPSHOTS_DIR`, `POST_DEPLOY_COMMANDS`). Unit-tested by `tests/install.bats`.
- `charts/site/README.md` — chart-specific README (TL;DR + production topology).
- `tests/install.bats` — bats unit tests for the install-Job shell (sources `install.sh` in library mode with stubbed `wp` / `php`).
- `tests/lockdown-test.sh`, `tests/credential-sync-test.sh` — kind-cluster end-to-end tests gating the load-bearing lockdown + admin-credential-sync properties.
- `.github/workflows/lint.yml` — `helm lint` + `helm template` + `chart-testing ct lint` on push/PR.
- `.github/workflows/release.yml` — **on tag push (`v*.*.*`)**, `helm package` + push to OCI. Tag-driven releases — pushes to main do NOT auto-release.

## Conventions

- **Subchart deps are conditional defaults for instant kind-cluster deploys** — they're explicitly **NOT for production**. Production users disable the subcharts and supply external endpoints (DragonflyDB Operator, MariaDB Operator, AWS S3, External Secrets Operator).
- **Bitnami subchart Service/Secret names are `<release>-<subchart>`**, not `<release>-<our-chart>-<subchart>`. The bitnami `common.names.fullname` produces `<release>-<subchart>` from inside the subchart's own context. Our `_helpers.tpl` accounts for this — don't break it.
- **All Bitnami images overridden to `bitnamilegacy/*`** by default. Bitnami withdrew their public `bitnami/<name>` images from free Docker Hub in 2025 ("Bitnami Secure Images" commercial pivot). The legacy mirror is the canonical override path. If `bitnamilegacy` ever goes away too, we'd switch to inline templates using upstream images.
- **Chart version is bumped on every change** to templates / values / Chart.yaml. Releases happen by tagging `vX.Y.Z` matching the Chart.yaml version. Tag-driven, never push-to-main-driven.
- **`appVersion` tracks `site-template`** — the WordPress site image we test against. Bump it when you bump the default `image.tag` in values.
- **Install Job picks latest snapshot by `manifest.created` (v0.12.0+).** Multiple `web/imports/<slug>/` directories baked into the site image can coexist — the install Job reads each `manifest.json`, picks the one with the highest `created` UTC timestamp, and applies that one. Older snapshots are logged as `skipped — older` but kept as history. Single-snapshot tenants take a fast path (no per-manifest parse). Pre-v0.12.0 the Job hard-failed on >1 `manifest.json` and tenants had to `git rm` the previous snapshot per release; that constraint is gone. Pairs with `frankenpress/fp` v0.5.0+ which defaults `fp snapshot` slugs to UTC timestamps.
- **Install-Job shell lives in `files/scripts/install.sh`, not inline in `job-install.yaml`.** The YAML emits a small env-var preamble (`SKIP_EMAIL`, `ACTIVE_THEME`, `SNAPSHOTS_DIR`, `POST_DEPLOY_COMMANDS`) for the conditionals, then sources the script via `{{ .Files.Get "files/scripts/install.sh" | indent 14 }}`. Job inputs hash (which keeps the Job re-firing on values changes — see `job-install.yaml` header) deliberately includes whole `.Values.siteInstall`, so changing `install.sh` itself doesn't bust the hash — bump `Chart.Version` for behavioural changes. When editing the install flow: edit `install.sh`, run `bats tests/install.bats`, then `helm template` to verify the YAML still renders.

## Don'ts

- **Don't bypass `bitnami/common` helpers and reinvent labels/fullname templating.** Inconsistency between site and bitnami subchart resources causes label-selector mismatches.
- **Don't hard-code Bedrock or WordPress paths in `values.yaml`.** The chart consumes images that already encode those paths.
- **Don't inline production credentials** (DB passwords, S3 keys) into `values.yaml` even as defaults. Use `existingSecret` patterns.
- **Don't drop the `condition:` field on optional subchart deps.** Without it, `<name>.enabled: false` doesn't actually skip the subchart.
- **Don't change the release.yml trigger back to `push: branches: [main]`.** It causes the OCI push to fail with "already exists" on every commit since the chart version is constant between bumps.
- **Don't add a fallback like `chart-releaser-action` that needs a `gh-pages` branch.** OCI is the canonical channel; secondary channels add maintenance burden without value.
- **Don't bump the site chart version without updating `appVersion`** if the change requires a newer site image. The two move together unless the chart change is purely template-side.

## Local testing

```bash
# Lint
helm lint charts/site

# Render manifests without installing
helm template smoketest charts/site --namespace smoketest

# Pull subchart deps
helm dependency update charts/site

# Unit-test the install Job's shell body (no cluster, ~1s)
bats tests/install.bats

# Install on a kind cluster (use a locally-built site image)
helm install mysite charts/site \
  --namespace mysite --create-namespace \
  --set image.registry= \
  --set image.repository=site \
  --set image.tag=dev \
  --set image.pullPolicy=Never

# Kind end-to-end tests — gate the lockdown + admin-credential-sync
# properties before tagging a release.
KUBE_CONTEXT=kind-frankenpress KEEP=1 ./tests/lockdown-test.sh
KUBE_CONTEXT=kind-frankenpress KEEP=1 ./tests/credential-sync-test.sh
```

## When you bump a value

If you add or rename a `values.yaml` key:

1. Add the `## @param` annotation
2. Update `charts/site/README.md` if it's surfaced there
3. Update `https://docs.frankenpress.com/components/charts` (in [`docs`](https://github.com/frankenpress/docs))
4. Update `https://docs.frankenpress.com/operations/configuration`
5. Bump `Chart.yaml.version` (patch unless it's a breaking schema change)

## Releasing a new chart version

```bash
# Bump Chart.yaml.version in your PR. After merge:
git tag v0.1.2
git push origin v0.1.2
```

The release workflow packages and pushes to
`oci://ghcr.io/frankenpress/charts/site:0.1.2`.

## Companion repos

| Repo | Purpose |
|---|---|
| [`runtime`](https://github.com/frankenpress/runtime) | Base container image |
| [`mu-plugin`](https://github.com/frankenpress/mu-plugin) | Must-use plugin |
| [`site-template`](https://github.com/frankenpress/site-template) | GitHub template for new sites — what this chart deploys |
| [`charts`](https://github.com/frankenpress/charts) (this repo) | Helm charts |
| [`docs`](https://github.com/frankenpress/docs) | Mintlify docs site |
