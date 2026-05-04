# CLAUDE.md

Guidance for Claude Code when working in `fp-charts`.

## Conventions

- **Bitnami chart style** throughout. Every public value gets a
  `## @param <path> <description>` annotation so README generators can
  emit consistent reference tables. When adding a value, add the annotation.
- Use the [`bitnami/common`](https://github.com/bitnami/charts/tree/main/bitnami/common)
  library helpers (`common.names.fullname`, `common.labels.standard`,
  `common.images.image`, `common.tplvalues.render`) instead of inlining
  the same logic.
- Subchart dependencies via OCI: `oci://registry-1.docker.io/bitnamicharts/<name>`.
- **In-cluster subcharts are dev defaults only.** Every subchart is
  conditional (`<name>.enabled: true`). Production values disable them
  and supply external service endpoints (operator-managed or managed cloud).
- **No Bitnami "lite" subchart values copy-paste.** When you need to
  configure a subchart, use the `<name>:` block at the top level of
  `values.yaml` (Helm's standard subchart override mechanism).

## File layout

- `charts/<name>/` — one chart per directory.
- `charts/<name>/Chart.yaml` — pin `bitnami/common` and any subcharts to
  exact minor.patch versions. Bumps via Renovate or manual.
- `charts/<name>/values.yaml` — the source of truth for the public API.
  Document every value.
- `charts/<name>/templates/_helpers.tpl` — chart-local helpers. Wrap
  subchart-vs-external resolution here (see `fp-site.databaseHost`,
  `fp-site.cacheHost`, `fp-site.s3Endpoint`).
- `charts/<name>/README.md` — chart README. Quickstart + production
  topology + values reference (auto-generated from `## @param` annotations).

## Don'ts

- Don't bypass `bitnami/common` helpers and reinvent labels / fullname
  templating.
- Don't hard-code Bedrock / WordPress paths in values.yaml. The chart
  consumes images that already encode that — values stay platform-agnostic.
- Don't inline production credentials (DB passwords, S3 keys) into
  values.yaml even as defaults. Use `existingSecret` patterns.
- Don't skip the `condition:` field on optional subchart deps. Without
  it, `<name>.enabled: false` doesn't actually skip the subchart.

## Testing

- `helm lint charts/fp-site` — every push.
- `helm template smoketest charts/fp-site` — verify the chart renders
  with default values (no errors).
- `ct lint` (chart-testing) — full-fat lint, version increment check, etc.
- For interactive testing: `kind create cluster --name fp` then
  `helm install --namespace fp ...`.

## Companion repos

| Repo | Purpose |
|---|---|
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) | Caddy + FrankenPHP + Souin base image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Must-use plugin (S3 bootstrap + Souin invalidator) |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new WP sites |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) (this repo) | Helm charts |
