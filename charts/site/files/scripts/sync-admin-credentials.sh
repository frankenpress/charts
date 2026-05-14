#!/bin/sh
# Reconciles wp_users with the admin credentials Secret on every Pod
# start. Runs as the `sync-admin-credentials` initContainer in the
# site Deployment — see `templates/deployment.yaml`.
#
# Pair with stakater/Reloader (or any controller that rolls the
# Deployment when the Secret changes) so credential rotation is
# self-driving end-to-end. Idempotent: with N>1 replicas under the
# default rolling update (maxSurge:1, maxUnavailable:0), the first
# Pod to roll wins the write; subsequent Pods see DB-in-sync here
# and short-circuit. WP fires at most one "Password Changed"
# notification per rotation.
#
# Required env vars (set by the chart from values + secrets):
#   DB_HOST, DB_USER, DB_PASSWORD
#   ADMIN_USER, ADMIN_EMAIL, ADMIN_PASSWORD
#
# Optional env vars:
#   FP_SMTP_HOST  — when set, WP's "password changed" email goes via
#                   the configured SMTP server. When empty/unset, a
#                   `--require=` file is dropped to suppress the
#                   notification entirely (otherwise WP falls through
#                   to mail() → /usr/sbin/sendmail, which isn't in
#                   the runtime image, and emits a noisy
#                   "sendmail: not found" on every sync).

set -eu
WP="${WP_BIN:-wp --allow-root --path=/app/web/wp}"

# Direct mysqli probe — doesn't load WordPress, so it works before
# `wp core install` has created wp_options on a fresh deploy. Same
# probe as files/scripts/install.sh.
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

wait_for_db() {
  echo "[sync-creds] waiting for database..."
  for i in $(seq 1 60); do
    if db_ready; then
      echo "[sync-creds] db ready (iter=$i)"
      return 0
    fi
    sleep 2
  done
  echo "[sync-creds] database never became reachable; aborting"
  return 1
}

# Resolve the WP user we're targeting. Prefer matching by email
# (survives username changes); fall back to username. Prints the
# target on stdout. Non-zero exit means neither resolves — caller
# should treat that as a hard error.
resolve_target() {
  if $WP user get "$ADMIN_EMAIL" --field=ID >/dev/null 2>&1; then
    echo "$ADMIN_EMAIL"
    return 0
  fi
  if $WP user get "$ADMIN_USER" --field=ID >/dev/null 2>&1; then
    echo "$ADMIN_USER"
    return 0
  fi
  return 1
}

# Compare desired creds against current DB state. Prints "match" if
# password + email + login all align, else "drift". Any `wp eval`
# failure is treated as drift (safer to attempt the update than to
# silently skip).
check_drift() {
  $WP eval '
    $u = get_user_by( "email", getenv("ADMIN_EMAIL") );
    if ( ! $u ) { $u = get_user_by( "login", getenv("ADMIN_USER") ); }
    if ( ! $u ) { echo "drift"; return; }
    $pw_match    = wp_check_password( getenv("ADMIN_PASSWORD"), $u->user_pass, $u->ID );
    $email_match = ( $u->user_email === getenv("ADMIN_EMAIL") );
    $login_match = ( $u->user_login === getenv("ADMIN_USER") );
    echo ( $pw_match && $email_match && $login_match ) ? "match" : "drift";
  ' 2>/dev/null || echo "drift"
}

# Drop a `--require=` file that disables WP's password-change and
# email-change notifications, and print the resulting `--require=...`
# flag on stdout. Called only when FP_SMTP_HOST is empty/unset —
# otherwise we let WP send the notification via the configured SMTP.
write_silence_file() {
  silence_file="${SILENCE_FILE:-/tmp/no-user-emails.php}"
  # `--require=` files are loaded during wp-cli bootstrap, before
  # WordPress — so `add_filter` isn't defined yet. Defer registration
  # via `WP_CLI::add_hook('after_wp_load', ...)`.
  cat > "$silence_file" <<'PHP'
<?php
WP_CLI::add_hook( 'after_wp_load', function() {
    add_filter( 'send_password_change_email', '__return_false' );
    add_filter( 'send_email_change_email',    '__return_false' );
});
PHP
  echo "--require=$silence_file"
}

main() {
  wait_for_db

  # Fresh deploy: WP isn't installed yet. The post-install Helm hook
  # Job creates the admin user with the same Secret we'd be syncing
  # from, so there's nothing to reconcile.
  if ! $WP core is-installed >/dev/null 2>&1; then
    echo "[sync-creds] WP not yet installed; skipping (post-install Job will bootstrap)"
    return 0
  fi

  if ! TARGET=$(resolve_target); then
    echo "[sync-creds] neither ADMIN_EMAIL nor ADMIN_USER resolves to an existing user; aborting"
    return 1
  fi

  drift=$(check_drift)
  if [ "$drift" = "match" ]; then
    echo "[sync-creds] DB already in sync with Secret; skipping update"
    return 0
  fi

  echo "[sync-creds] credential drift detected; running wp user update"

  if [ -n "${FP_SMTP_HOST:-}" ]; then
    REQUIRE_FLAG=""
  else
    REQUIRE_FLAG=$(write_silence_file)
  fi

  # shellcheck disable=SC2086 -- intentional word-split on REQUIRE_FLAG
  $WP $REQUIRE_FLAG user update "$TARGET" \
    --user_pass="$ADMIN_PASSWORD" \
    --user_email="$ADMIN_EMAIL"

  echo "[sync-creds] done"
}

# Library mode: when sourced with FP_SYNC_ADMIN_SH_LIB=1, only the
# function definitions are loaded — bats sources the file this way
# to test individual functions with stubbed `wp` / `php`.
case "${FP_SYNC_ADMIN_SH_LIB:-0}" in
  1) ;;
  *) main "$@" ;;
esac
