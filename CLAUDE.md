# CLAUDE.md — fp-charts

Guidance for Claude Code when working in this repo.

## What this repo is

**Helm charts for the FrankenPress stack.** Currently one chart: `fp-site`,
which deploys a single FrankenPress WordPress site to Kubernetes.

Charts are published as OCI artifacts on GHCR:
**`oci://ghcr.io/eightoeight/charts/fp-site`** (current: `0.5.0`).

Public docs: **<https://docs.frankenpress.com/components/fp-charts>**

## Style: Bitnami chart conventions, throughout

- Every public value in `values.yaml` carries a `## @param <path> <description>` annotation. Bitnami's `readme-generator-for-helm` (and our docs) consume these.
- Naming/labels/image templating goes through [`bitnami/common`](https://github.com/bitnami/charts/tree/main/bitnami/common) helpers (`common.names.fullname`, `common.labels.standard`, `common.images.image`, `common.tplvalues.render`). Don't reinvent them.
- Subchart deps via Bitnami's OCI registry: `oci://registry-1.docker.io/bitnamicharts/<name>`.
- Production-grade `securityContext` defaults that satisfy PSA `restricted:latest` out of the box: `readOnlyRootFilesystem`, `runAsUser:33`, `runAsNonRoot:true`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]` (no `add`), pod-level `seccompProfile.type:RuntimeDefault`. Works with the `fp-runtime` v0.1.x line because that runtime ships FrankenPHP with the `cap_net_bind_service` file capability stripped (`setcap -r`); a custom runtime that re-adds the cap needs the chart values overridden — see the comment block above `containerSecurityContext` in `values.yaml`.

## File layout

- `charts/fp-site/Chart.yaml` — pinned deps:
  - `bitnami/common` (library, always loaded)
  - `bitnami/mariadb` (conditional `mariadb.enabled`)
  - `bitnami/redis` (conditional `redis.enabled`)
  - `bitnami/minio` (conditional `minio.enabled`)
- `charts/fp-site/values.yaml` — single source of truth for the public API. Every value documented inline.
- `charts/fp-site/templates/_helpers.tpl` — chart-local helpers. **Wraps subchart-vs-external resolution** (`fp-site.databaseHost`, `fp-site.cacheHost`, `fp-site.s3Endpoint`, `fp-site.s3SecretName`, etc.) so flipping `<subchart>.enabled: false` is a one-line change in values.
- `charts/fp-site/templates/{deployment,service,configmap,secret,cronjob-wpcron,serviceaccount,ingress,httproute,hpa}.yaml` — single-tenant resources for the site.
- `charts/fp-site/README.md` — chart-specific README (TL;DR + production topology).
- `.github/workflows/lint.yml` — `helm lint` + `helm template` + `chart-testing ct lint` on push/PR.
- `.github/workflows/release.yml` — **on tag push (`v*.*.*`)**, `helm package` + push to OCI. Tag-driven releases — pushes to main do NOT auto-release.

## Conventions

- **Subchart deps are conditional defaults for instant kind-cluster deploys** — they're explicitly **NOT for production**. Production users disable the subcharts and supply external endpoints (DragonflyDB Operator, MariaDB Operator, AWS S3, External Secrets Operator).
- **Bitnami subchart Service/Secret names are `<release>-<subchart>`**, not `<release>-<our-chart>-<subchart>`. The bitnami `common.names.fullname` produces `<release>-<subchart>` from inside the subchart's own context. Our `_helpers.tpl` accounts for this — don't break it.
- **All Bitnami images overridden to `bitnamilegacy/*`** by default. Bitnami withdrew their public `bitnami/<name>` images from free Docker Hub in 2025 ("Bitnami Secure Images" commercial pivot). The legacy mirror is the canonical override path. If `bitnamilegacy` ever goes away too, we'd switch to inline templates using upstream images.
- **Chart version is bumped on every change** to templates / values / Chart.yaml. Releases happen by tagging `vX.Y.Z` matching the Chart.yaml version. Tag-driven, never push-to-main-driven.
- **`appVersion` tracks `fp-site-template`** — the WordPress site image we test against. Bump it when you bump the default `image.tag` in values.

## Don'ts

- **Don't bypass `bitnami/common` helpers and reinvent labels/fullname templating.** Inconsistency between fp-site and bitnami subchart resources causes label-selector mismatches.
- **Don't hard-code Bedrock or WordPress paths in `values.yaml`.** The chart consumes images that already encode those paths.
- **Don't inline production credentials** (DB passwords, S3 keys) into `values.yaml` even as defaults. Use `existingSecret` patterns.
- **Don't drop the `condition:` field on optional subchart deps.** Without it, `<name>.enabled: false` doesn't actually skip the subchart.
- **Don't change the release.yml trigger back to `push: branches: [main]`.** It causes the OCI push to fail with "already exists" on every commit since the chart version is constant between bumps.
- **Don't add a fallback like `chart-releaser-action` that needs a `gh-pages` branch.** OCI is the canonical channel; secondary channels add maintenance burden without value.
- **Don't bump the fp-site chart version without updating `appVersion`** if the change requires a newer site image. The two move together unless the chart change is purely template-side.

## Local testing

```bash
# Lint
helm lint charts/fp-site

# Render manifests without installing
helm template smoketest charts/fp-site --namespace smoketest

# Pull subchart deps
helm dependency update charts/fp-site

# Install on a kind cluster (use a locally-built fp-site image)
helm install mysite charts/fp-site \
  --namespace mysite --create-namespace \
  --set image.registry= \
  --set image.repository=fp-site \
  --set image.tag=dev \
  --set image.pullPolicy=Never
```

## When you bump a value

If you add or rename a `values.yaml` key:

1. Add the `## @param` annotation
2. Update `charts/fp-site/README.md` if it's surfaced there
3. Update `https://docs.frankenpress.com/components/fp-charts` (in [`docs`](https://github.com/EightOEight/docs))
4. Update `https://docs.frankenpress.com/operations/configuration`
5. Bump `Chart.yaml.version` (patch unless it's a breaking schema change)

## Releasing a new chart version

```bash
# Bump Chart.yaml.version in your PR. After merge:
git tag v0.1.2
git push origin v0.1.2
```

The release workflow packages and pushes to
`oci://ghcr.io/eightoeight/charts/fp-site:0.1.2`.

## Companion repos

| Repo | Purpose |
|---|---|
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) | Base container image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Must-use plugin |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new sites — what this chart deploys |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) (this repo) | Helm charts |
| [`docs`](https://github.com/EightOEight/docs) | Mintlify docs site |
