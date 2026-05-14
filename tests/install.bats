#!/usr/bin/env bats
#
# Unit tests for charts/site/files/scripts/install.sh.
#
# The script is sourced in library mode (FP_INSTALL_SH_LIB=1) so we
# can exercise individual functions without firing the whole flow.
# `wp` and `php` are stubbed via a per-test PATH shim — each test
# writes its own fakes into $BATS_TEST_TMPDIR/bin and prepends it.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../charts/site/files/scripts/install.sh"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  PATH="${STUB_BIN}:${PATH}"

  # Capture every fake-binary invocation in this file for assertions.
  CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : > "$CALL_LOG"
  export CALL_LOG
}

# Write a stub at $STUB_BIN/<name> that logs its argv to $CALL_LOG and
# exits with the given status (default 0). $1=name, $2=exit, $3=stdout.
stub() {
  local name="$1" exit_code="${2:-0}" stdout="${3:-}"
  cat >"${STUB_BIN}/${name}" <<EOF
#!/bin/sh
printf '%s' "${name}" >>"\$CALL_LOG"
for a in "\$@"; do printf ' %s' "\$a" >>"\$CALL_LOG"; done
printf '\n' >>"\$CALL_LOG"
${stdout:+printf '%s\n' "$stdout"}
exit ${exit_code}
EOF
  chmod +x "${STUB_BIN}/${name}"
}

# Load install.sh in library mode and override $WP to point at our stub.
load_lib() {
  export FP_INSTALL_SH_LIB=1
  export WP_BIN="wp"
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

# --- activate_theme -------------------------------------------------

@test "activate_theme: no-op when ACTIVE_THEME is unset" {
  stub wp
  load_lib
  unset ACTIVE_THEME
  run activate_theme
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "activate_theme: no-op when ACTIVE_THEME is empty string" {
  stub wp
  load_lib
  ACTIVE_THEME=""
  run activate_theme
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "activate_theme: invokes wp with --skip-themes and the slug" {
  stub wp
  load_lib
  ACTIVE_THEME="twentytwentyfive"
  run activate_theme
  [ "$status" -eq 0 ]
  grep -q '^wp --skip-themes theme activate twentytwentyfive$' "$CALL_LOG"
}

# --- run_post_deploy_commands --------------------------------------

@test "run_post_deploy_commands: no-op when var is unset" {
  stub wp
  load_lib
  unset POST_DEPLOY_COMMANDS
  run run_post_deploy_commands
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "run_post_deploy_commands: each line becomes a wp invocation" {
  stub wp
  load_lib
  # Two commands, with one carrying an embedded quoted arg (the
  # documented use case for set -x + eval).
  POST_DEPLOY_COMMANDS='option update blogdescription "test site"
rewrite flush --hard'
  run run_post_deploy_commands
  [ "$status" -eq 0 ]
  [ "$(grep -c '^wp ' "$CALL_LOG")" -eq 2 ]
  grep -qF 'wp option update blogdescription test site' "$CALL_LOG"
  grep -qF 'wp rewrite flush --hard' "$CALL_LOG"
}

@test "run_post_deploy_commands: skips blank lines" {
  stub wp
  load_lib
  POST_DEPLOY_COMMANDS='option update foo bar

rewrite flush'
  run run_post_deploy_commands
  [ "$status" -eq 0 ]
  [ "$(grep -c '^wp ' "$CALL_LOG")" -eq 2 ]
}

@test "run_post_deploy_commands: a failing command surfaces as non-zero" {
  stub wp 1
  load_lib
  POST_DEPLOY_COMMANDS='option update foo bar'
  # Matches the old template behaviour: a failing wp-cli invocation
  # exits the Job non-zero, Helm marks the release failed, and the
  # operator sees the failure in the Job logs.
  run run_post_deploy_commands
  [ "$status" -ne 0 ]
  grep -qF 'wp option update foo bar' "$CALL_LOG"
}

# --- apply_latest_snapshot -----------------------------------------

@test "apply_latest_snapshot: no-op when SNAPSHOTS_DIR is unset" {
  stub wp
  load_lib
  unset SNAPSHOTS_DIR
  run apply_latest_snapshot
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "apply_latest_snapshot: missing dir prints a message and exits 0" {
  stub wp
  load_lib
  SNAPSHOTS_DIR="${BATS_TEST_TMPDIR}/does-not-exist"
  run apply_latest_snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "apply_latest_snapshot: zero manifests prints empty-message and exits 0" {
  stub wp
  load_lib
  SNAPSHOTS_DIR="${BATS_TEST_TMPDIR}/snapshots"
  mkdir -p "${SNAPSHOTS_DIR}/empty-slug"
  run apply_latest_snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"no snapshot manifest.json files"* ]]
  # `wp fp apply` must NOT have run.
  ! grep -q 'fp apply' "$CALL_LOG"
}

@test "apply_latest_snapshot: single manifest takes the fast path" {
  stub wp
  load_lib
  SNAPSHOTS_DIR="${BATS_TEST_TMPDIR}/snapshots"
  mkdir -p "${SNAPSHOTS_DIR}/2026-01-15-launch"
  echo '{"created": "2026-01-15T00:00:00Z"}' \
    >"${SNAPSHOTS_DIR}/2026-01-15-launch/manifest.json"
  run apply_latest_snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"applying ${SNAPSHOTS_DIR}/2026-01-15-launch"* ]]
  grep -qF "fp apply --snapshot-dir=${SNAPSHOTS_DIR}/2026-01-15-launch" "$CALL_LOG"
}

@test "apply_latest_snapshot: picks the newest by manifest.created when multiple" {
  stub wp
  load_lib
  SNAPSHOTS_DIR="${BATS_TEST_TMPDIR}/snapshots"
  mkdir -p "${SNAPSHOTS_DIR}/old" "${SNAPSHOTS_DIR}/new" "${SNAPSHOTS_DIR}/middle"
  echo '{"created": "2026-01-10T00:00:00Z"}' >"${SNAPSHOTS_DIR}/old/manifest.json"
  echo '{"created": "2026-03-01T00:00:00Z"}' >"${SNAPSHOTS_DIR}/new/manifest.json"
  echo '{"created": "2026-02-15T00:00:00Z"}' >"${SNAPSHOTS_DIR}/middle/manifest.json"
  run apply_latest_snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 snapshot directories found"* ]]
  [[ "$output" == *"-> ${SNAPSHOTS_DIR}/new (picked)"* ]]
  [[ "$output" == *"${SNAPSHOTS_DIR}/old (skipped — older)"* ]]
  [[ "$output" == *"${SNAPSHOTS_DIR}/middle (skipped — older)"* ]]
  grep -qF "fp apply --snapshot-dir=${SNAPSHOTS_DIR}/new" "$CALL_LOG"
}

@test "apply_latest_snapshot: errors when every manifest lacks 'created'" {
  stub wp
  load_lib
  SNAPSHOTS_DIR="${BATS_TEST_TMPDIR}/snapshots"
  mkdir -p "${SNAPSHOTS_DIR}/a" "${SNAPSHOTS_DIR}/b"
  echo '{"version": 1}' >"${SNAPSHOTS_DIR}/a/manifest.json"
  echo '{"version": 1}' >"${SNAPSHOTS_DIR}/b/manifest.json"
  run apply_latest_snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to pick a snapshot"* ]]
  ! grep -q 'fp apply' "$CALL_LOG"
}

# --- run_core_install ---------------------------------------------

@test "run_core_install: skips when core is already installed" {
  # `wp core is-installed` returns 0 → already installed
  stub wp 0
  load_lib
  export WP_HOME="https://example.test"
  export SITE_TITLE="Example"
  export ADMIN_USER="admin"
  export ADMIN_EMAIL="admin@example.test"
  export ADMIN_PASSWORD="pw"
  run run_core_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  # Only the is-installed probe should have run.
  [ "$(grep -c '^wp ' "$CALL_LOG")" -eq 1 ]
  grep -q 'core is-installed' "$CALL_LOG"
  ! grep -q 'core install --url' "$CALL_LOG"
}

@test "run_core_install: appends --skip-email when SKIP_EMAIL=1" {
  # Make `wp` exit 1 for is-installed (so we proceed) but 0 for install.
  # Simplest: a stub that exits 1 only when `core is-installed` is the
  # argv, else 0.
  cat >"${STUB_BIN}/wp" <<'EOF'
#!/bin/sh
printf 'wp' >>"$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$CALL_LOG"; done
printf '\n' >>"$CALL_LOG"
case "$*" in
  *"core is-installed"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${STUB_BIN}/wp"
  load_lib
  export WP_HOME="https://example.test"
  export SITE_TITLE="Example"
  export ADMIN_USER="admin"
  export ADMIN_EMAIL="admin@example.test"
  export ADMIN_PASSWORD="pw"
  export SKIP_EMAIL=1
  run run_core_install
  [ "$status" -eq 0 ]
  grep -q -- '--skip-email' "$CALL_LOG"
}

@test "run_core_install: omits --skip-email when SKIP_EMAIL=0" {
  cat >"${STUB_BIN}/wp" <<'EOF'
#!/bin/sh
printf 'wp' >>"$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$CALL_LOG"; done
printf '\n' >>"$CALL_LOG"
case "$*" in
  *"core is-installed"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${STUB_BIN}/wp"
  load_lib
  export WP_HOME="https://example.test"
  export SITE_TITLE="Example"
  export ADMIN_USER="admin"
  export ADMIN_EMAIL="admin@example.test"
  export ADMIN_PASSWORD="pw"
  export SKIP_EMAIL=0
  run run_core_install
  [ "$status" -eq 0 ]
  ! grep -q -- '--skip-email' "$CALL_LOG"
  grep -q 'core install --url=https://example.test' "$CALL_LOG"
}
