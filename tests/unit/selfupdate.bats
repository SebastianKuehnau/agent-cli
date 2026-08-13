#!/usr/bin/env bats
#
# Tests for `agent-task --update` / lib/selfupdate.sh.
#
# The download URL is redirected to a local file:// URL, which curl handles
# natively, so these tests need no network and never touch GitHub. A separate
# opt-in test at the bottom exercises the real URL.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  INSTALL_DIR="$TMP/install"
  mkdir -p "$INSTALL_DIR"
  SELF="$INSTALL_DIR/agent-task"
  printf '#!/usr/bin/env bash\n# old version\n' >"$SELF"
  chmod +x "$SELF"

  FIXTURE="$TMP/new-agent-task"
  printf '#!/usr/bin/env bash\n# new version\n' >"$FIXTURE"
}

# update_with_url — run selfupdate_run against <url>.
update_with_url() {
  run --separate-stderr env \
    AGENT_TASK_UPDATE_URL="$1" \
    bash -c "
      source '$AGENT_LIB/logging.sh'
      source '$AGENT_LIB/selfupdate.sh'
      selfupdate_run '$SELF'
    "
}

# --- happy path -------------------------------------------------------------

@test "selfupdate_run overwrites the target with the downloaded content" {
  update_with_url "file://$FIXTURE"
  assert_success
  run diff "$FIXTURE" "$SELF"
  assert_success
}

@test "selfupdate_run makes the result executable" {
  chmod -x "$SELF"
  update_with_url "file://$FIXTURE"
  assert_success
  [[ -x "$SELF" ]] || fail "updated file is not executable"
}

@test "selfupdate_run leaves no temporary files behind" {
  update_with_url "file://$FIXTURE"
  assert_success
  local leftovers
  leftovers="$(find "$INSTALL_DIR" -name '.agent-task.*' | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

# --- atomicity / failure -----------------------------------------------------

@test "a failed download leaves the existing install untouched" {
  local before
  before="$(cat "$SELF")"

  update_with_url "file://$TMP/does-not-exist"
  assert_failure
  [[ "$stderr" == *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(cat "$SELF")" "$before"
}

@test "a failed download leaves no temporary file behind" {
  update_with_url "file://$TMP/does-not-exist"
  assert_failure
  local leftovers
  leftovers="$(find "$INSTALL_DIR" -name '.agent-task.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

@test "an empty download leaves the existing install untouched" {
  : >"$TMP/empty"
  local before
  before="$(cat "$SELF")"

  update_with_url "file://$TMP/empty"
  assert_failure
  [[ "$stderr" == *"empty"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(cat "$SELF")" "$before"
}

# --- optional network test --------------------------------------------------

@test "the real update URL is reachable and non-empty (AGENT_TASK_NETWORK_TESTS=1)" {
  [[ -n "${AGENT_TASK_NETWORK_TESTS:-}" ]] ||
    skip "set AGENT_TASK_NETWORK_TESTS=1 to test against the real URL"

  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/selfupdate.sh'
    selfupdate_run '$SELF'
  "
  assert_success
  [[ -s "$SELF" ]] || fail "updated file is empty"
  grep -q 'agent-task' "$SELF" || fail "updated file does not look like agent-task"
}
