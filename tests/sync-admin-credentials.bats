#!/usr/bin/env bats
#
# Unit tests for charts/site/files/scripts/sync-admin-credentials.sh.
#
# The script is sourced in library mode (FP_SYNC_ADMIN_SH_LIB=1) so we
# can exercise individual functions without firing the whole flow.
# `wp` and `php` are stubbed via a per-test PATH shim.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../charts/site/files/scripts/sync-admin-credentials.sh"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  PATH="${STUB_BIN}:${PATH}"

  CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : > "$CALL_LOG"
  export CALL_LOG
}

# Inline-write a stub whose body is the second arg. Allows per-test
# wp behaviour (e.g. `wp user get <X>` succeeds, `<Y>` fails).
write_stub() {
  local name="$1" body="$2"
  cat >"${STUB_BIN}/${name}" <<EOF
#!/bin/sh
printf '%s' "${name}" >>"\$CALL_LOG"
for a in "\$@"; do printf ' %s' "\$a" >>"\$CALL_LOG"; done
printf '\n' >>"\$CALL_LOG"
${body}
EOF
  chmod +x "${STUB_BIN}/${name}"
}

load_lib() {
  export FP_SYNC_ADMIN_SH_LIB=1
  export WP_BIN="wp"
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

# --- resolve_target -----------------------------------------------

@test "resolve_target: prefers email when both users exist" {
  write_stub wp 'case "$*" in
    *"user get admin@example.test"*) exit 0 ;;
    *"user get admin"*) exit 0 ;;
    *) exit 1 ;;
  esac'
  load_lib
  ADMIN_EMAIL="admin@example.test"
  ADMIN_USER="admin"
  run resolve_target
  [ "$status" -eq 0 ]
  [ "$output" = "admin@example.test" ]
}

@test "resolve_target: falls back to username when email doesn't resolve" {
  write_stub wp 'case "$*" in
    *"user get alice@example.test"*) exit 1 ;;
    *"user get alice"*) exit 0 ;;
    *) exit 1 ;;
  esac'
  load_lib
  ADMIN_EMAIL="alice@example.test"
  ADMIN_USER="alice"
  run resolve_target
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "resolve_target: returns non-zero when neither resolves" {
  write_stub wp 'exit 1'
  load_lib
  ADMIN_EMAIL="nobody@example.test"
  ADMIN_USER="nobody"
  run resolve_target
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- check_drift ---------------------------------------------------

@test "check_drift: prints 'match' when wp eval echoes match" {
  write_stub wp 'echo match'
  load_lib
  ADMIN_EMAIL="x@example.test"
  ADMIN_USER="x"
  ADMIN_PASSWORD="pw"
  run check_drift
  [ "$status" -eq 0 ]
  [ "$output" = "match" ]
}

@test "check_drift: prints 'drift' when wp eval echoes drift" {
  write_stub wp 'echo drift'
  load_lib
  ADMIN_EMAIL="x@example.test"
  ADMIN_USER="x"
  ADMIN_PASSWORD="pw"
  run check_drift
  [ "$status" -eq 0 ]
  [ "$output" = "drift" ]
}

@test "check_drift: treats wp eval failure as drift" {
  # Stub fails with no stdout — caller should still get "drift".
  write_stub wp 'exit 1'
  load_lib
  ADMIN_EMAIL="x@example.test"
  ADMIN_USER="x"
  ADMIN_PASSWORD="pw"
  run check_drift
  [ "$status" -eq 0 ]
  [ "$output" = "drift" ]
}

# --- write_silence_file -------------------------------------------

@test "write_silence_file: writes the PHP filter and prints --require flag" {
  load_lib
  SILENCE_FILE="${BATS_TEST_TMPDIR}/silence.php"
  run write_silence_file
  [ "$status" -eq 0 ]
  [ "$output" = "--require=${SILENCE_FILE}" ]
  [ -f "$SILENCE_FILE" ]
  grep -q 'send_password_change_email' "$SILENCE_FILE"
  grep -q 'send_email_change_email' "$SILENCE_FILE"
  grep -q "WP_CLI::add_hook( 'after_wp_load'" "$SILENCE_FILE"
  # The PHP body must NOT contain the heredoc indent — i.e. lines
  # don't have leading spaces beyond what the PHP itself needs.
  head -1 "$SILENCE_FILE" | grep -qx '<?php'
}

# --- main flow -----------------------------------------------------

@test "main: skips when WP is not yet installed" {
  # wp core is-installed → exit 0 means installed; exit 1 means not.
  # We need is-installed=1 to test the skip path.
  # But db_ready must succeed first. Stub php to always succeed.
  write_stub php 'exit 0'
  write_stub wp 'case "$*" in
    *"core is-installed"*) exit 1 ;;
    *) exit 0 ;;
  esac'
  load_lib
  DB_HOST=h DB_USER=u DB_PASSWORD=p
  ADMIN_EMAIL=x@example.test ADMIN_USER=x ADMIN_PASSWORD=pw
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"WP not yet installed"* ]]
  # `wp user update` must NOT have run.
  ! grep -q 'user update' "$CALL_LOG"
}

@test "main: skips wp user update when drift check returns match" {
  write_stub php 'exit 0'
  write_stub wp 'case "$*" in
    *"core is-installed"*) exit 0 ;;
    *"user get x@example.test"*) exit 0 ;;
    *"eval "*) echo match ;;
    *) exit 0 ;;
  esac'
  load_lib
  DB_HOST=h DB_USER=u DB_PASSWORD=p
  ADMIN_EMAIL=x@example.test ADMIN_USER=x ADMIN_PASSWORD=pw
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in sync"* ]]
  ! grep -q 'user update' "$CALL_LOG"
}

@test "main: runs wp user update when drift detected (SMTP-on path)" {
  write_stub php 'exit 0'
  write_stub wp 'case "$*" in
    *"core is-installed"*) exit 0 ;;
    *"user get x@example.test"*) exit 0 ;;
    *"eval "*) echo drift ;;
    *) exit 0 ;;
  esac'
  load_lib
  DB_HOST=h DB_USER=u DB_PASSWORD=p
  ADMIN_EMAIL=x@example.test ADMIN_USER=x ADMIN_PASSWORD=pw
  FP_SMTP_HOST="smtp.example.test"
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" == *"done"* ]]
  grep -qF 'user update x@example.test' "$CALL_LOG"
  # SMTP-on: no --require= flag in the user update call.
  ! grep -E 'user update.*--require=' "$CALL_LOG"
}

@test "main: writes silence file and passes --require= when SMTP is off" {
  write_stub php 'exit 0'
  write_stub wp 'case "$*" in
    *"core is-installed"*) exit 0 ;;
    *"user get x@example.test"*) exit 0 ;;
    *"eval "*) echo drift ;;
    *) exit 0 ;;
  esac'
  load_lib
  DB_HOST=h DB_USER=u DB_PASSWORD=p
  ADMIN_EMAIL=x@example.test ADMIN_USER=x ADMIN_PASSWORD=pw
  unset FP_SMTP_HOST
  SILENCE_FILE="${BATS_TEST_TMPDIR}/silence.php"
  run main
  [ "$status" -eq 0 ]
  [ -f "$SILENCE_FILE" ]
  # Require flag is positioned BEFORE the wp-cli subcommand because
  # global wp-cli flags must precede the subcommand.
  grep -qF "wp --require=${SILENCE_FILE} user update x@example.test" "$CALL_LOG"
}

@test "main: aborts when no user resolves" {
  write_stub php 'exit 0'
  write_stub wp 'case "$*" in
    *"core is-installed"*) exit 0 ;;
    *"user get "*) exit 1 ;;
    *) exit 0 ;;
  esac'
  load_lib
  DB_HOST=h DB_USER=u DB_PASSWORD=p
  ADMIN_EMAIL=x@example.test ADMIN_USER=x ADMIN_PASSWORD=pw
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"neither ADMIN_EMAIL nor ADMIN_USER resolves"* ]]
  ! grep -q 'user update' "$CALL_LOG"
}
