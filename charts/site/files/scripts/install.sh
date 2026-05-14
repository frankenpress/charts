#!/bin/sh
# Install / upgrade entry-point for the FrankenPress site Helm chart.
#
# Mounted into the install Job container as a shell script body — see
# `templates/job-install.yaml`, which exports the conditional inputs as
# env vars before sourcing this file. Keeping the logic in a real .sh
# means shellcheck + bats can exercise it without rendering Helm.
#
# Required env vars (set by the chart from values + secrets):
#   WP_HOME, SITE_TITLE, ADMIN_USER, ADMIN_EMAIL, ADMIN_PASSWORD
#   DB_HOST, DB_USER, DB_PASSWORD
#
# Optional env vars (default to empty / off):
#   SKIP_EMAIL              "1" → pass --skip-email to `wp core install`
#   ACTIVE_THEME            theme slug to activate post-install
#   SNAPSHOTS_DIR           root dir containing one or more snapshot subdirs
#   POST_DEPLOY_COMMANDS    newline-separated wp-cli arg strings

set -eu
WP="${WP_BIN:-wp --allow-root --path=/app/web/wp}"

# Direct mysqli probe — doesn't load WordPress, so it works before
# `wp core install` has created wp_options. (`wp db *` commands all
# bootstrap WP first and hard-fail with "site not installed" on a fresh
# DB. `wp db check` also shells out to `mysqlcheck` which isn't in the
# runtime image.)
db_ready() {
  php -r '
    $m = @new mysqli(
      getenv("DB_HOST"),
      getenv("DB_USER"),
      getenv("DB_PASSWORD")
    );
    if ($m->connect_errno) { exit(1); }
    $m->close();
  ' >/dev/null 2>&1
}

# Pick the snapshot dir under $1 whose manifest.json carries the highest
# `created` (UTC ISO 8601). Prints the dir path on stdout; non-zero exit
# means no usable candidate. PHP is the canonical JSON parser available
# in the runtime image (FrankenPHP base); jq is not.
pick_latest_snapshot() {
  php -r '
    $best_created = null; $best_dir = null;
    foreach (glob($argv[1] . "/*/manifest.json") as $manifest) {
      $data = json_decode(file_get_contents($manifest), true);
      if (!is_array($data)) { continue; }
      $created = (string)($data["created"] ?? "");
      if ($created === "") { continue; }
      if ($best_created === null || $created > $best_created) {
        $best_created = $created;
        $best_dir = dirname($manifest);
      }
    }
    if ($best_dir === null) {
      fwrite(STDERR, "no manifest contained a \"created\" field; cannot pick latest\n");
      exit(1);
    }
    echo $best_dir;
  ' "$1"
}

wait_for_db() {
  echo "[install] waiting for database..."
  for i in $(seq 1 60); do
    if db_ready; then
      echo "[install] db ready (iter=$i)"
      return 0
    fi
    sleep 2
  done
  echo "[install] database never became reachable; aborting"
  return 1
}

run_core_install() {
  if $WP core is-installed >/dev/null 2>&1; then
    echo "[install] core already installed; skipping"
    return 0
  fi
  echo "[install] running wp core install"
  if [ "${SKIP_EMAIL:-0}" = "1" ]; then
    $WP core install \
      --url="$WP_HOME" \
      --title="$SITE_TITLE" \
      --admin_user="$ADMIN_USER" \
      --admin_email="$ADMIN_EMAIL" \
      --admin_password="$ADMIN_PASSWORD" \
      --skip-email
  else
    $WP core install \
      --url="$WP_HOME" \
      --title="$SITE_TITLE" \
      --admin_user="$ADMIN_USER" \
      --admin_email="$ADMIN_EMAIL" \
      --admin_password="$ADMIN_PASSWORD"
  fi
}

activate_theme() {
  [ -z "${ACTIVE_THEME:-}" ] && return 0
  # Idempotent — wp_options.{template,stylesheet} already matching is a
  # no-op. `--skip-themes` so a previously broken active theme doesn't
  # fatal WP load before we can switch away from it (recovery path
  # after a botched paid-theme release). `set -x` echoes the resolved
  # command before exec — avoids nested-quote rendering issues.
  echo "[install] activating theme:"
  ( set -x; $WP --skip-themes theme activate "$ACTIVE_THEME" )
}

# FrankenPress snapshot apply. Picks the snapshot dir under
# $SNAPSHOTS_DIR whose manifest.json carries the highest `created`
# and runs `wp fp apply --snapshot-dir=<dir>` against it.
#
# Multiple snapshot dirs may coexist under SNAPSHOTS_DIR — the
# FrankenPress convention is that designers commit iterations as new
# dirs (e.g. timestamped slugs) rather than `git rm`-ing the previous
# one. Git log + commit messages carry the human-readable "what
# changed"; `manifest.created` is the deterministic apply-order key.
#
# `wp fp apply` (frankenpress/mu-plugin v0.8.0+) is adapter-scoped +
# additive — uses WP-Importer for content, update_option for scoped
# options, never DROP / DELETE / TRUNCATE. Idempotent via
# fp_snapshot_applied_ref + fp_snapshot_applied_sha256 option markers;
# re-runs short-circuit in <100ms.
apply_latest_snapshot() {
  [ -z "${SNAPSHOTS_DIR:-}" ] && return 0
  if [ ! -d "$SNAPSHOTS_DIR" ]; then
    echo "[snapshot] $SNAPSHOTS_DIR not found; no snapshots in this image"
    return 0
  fi
  manifest_count=$(find "$SNAPSHOTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$manifest_count" -eq 0 ]; then
    echo "[snapshot] no snapshot manifest.json files under $SNAPSHOTS_DIR (designer hasn't committed any yet)"
    return 0
  fi
  if [ "$manifest_count" -eq 1 ]; then
    # Single-snapshot fast path: skip the per-manifest parse, just
    # apply the only candidate. Preserves behaviour for tenants who
    # haven't accumulated iterations yet.
    latest_dir=$(find "$SNAPSHOTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | head -1 | xargs dirname)
  else
    latest_dir=$(pick_latest_snapshot "$SNAPSHOTS_DIR") || {
      echo "[snapshot] ERROR: failed to pick a snapshot from $manifest_count candidate manifests under $SNAPSHOTS_DIR"
      echo "[snapshot] Snapshot directories found:"
      find "$SNAPSHOTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | xargs -n1 dirname
      echo "[snapshot] check that every manifest.json has a valid \"created\" UTC ISO 8601 timestamp."
      return 1
    }
    echo "[snapshot] $manifest_count snapshot directories found; picking latest by manifest.created:"
    find "$SNAPSHOTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | xargs -n1 dirname | while read -r dir; do
      if [ "$dir" = "$latest_dir" ]; then
        echo "  -> $dir (picked)"
      else
        echo "     $dir (skipped — older)"
      fi
    done
  fi
  echo "[snapshot] applying $latest_dir"
  ( set -x; $WP fp apply --snapshot-dir="$latest_dir" )
}

# Post-deploy commands. Run on every install + upgrade. Failures exit
# non-zero (Helm marks release failed; Deployment itself is not rolled
# back — pod is already serving traffic). Each line in
# POST_DEPLOY_COMMANDS is one wp-cli arg string — `eval` so embedded
# quotes (often `"` for PHP eval strings) tokenize the way the operator
# wrote them, matching the old per-line `( set -x; $WP {{ . }} )`
# Helm-range rendering.
run_post_deploy_commands() {
  [ -z "${POST_DEPLOY_COMMANDS:-}" ] && return 0
  cmd_count=$(printf '%s\n' "$POST_DEPLOY_COMMANDS" | grep -c '[^[:space:]]' || true)
  echo "[post-deploy] running $cmd_count command(s):"
  printf '%s\n' "$POST_DEPLOY_COMMANDS" | while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    ( set -x; eval "$WP $cmd" )
  done
}

main() {
  wait_for_db
  run_core_install
  echo "[install] running core update-db (idempotent)"
  $WP core update-db
  activate_theme
  apply_latest_snapshot
  run_post_deploy_commands
  echo "[install] done"
}

# Only run main when invoked directly. Bats can `source` the file to
# unit-test individual functions without firing the whole flow.
case "${FP_INSTALL_SH_LIB:-0}" in
  1) ;;
  *) main "$@" ;;
esac
