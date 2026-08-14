#!/usr/bin/env bats
#
# lib/logging.sh — the confirmation prompt used before a destructive step
# (recreating a sandbox to apply a changed kit, issue #7).
#
# The decision is in confirm_is_yes, deliberately separate from the terminal I/O
# in confirm, so that what counts as consent is testable without a
# pseudo-terminal. confirm itself is only checked for the one property that
# matters without a terminal: it never says yes.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
}

# --- what counts as yes -----------------------------------------------------

@test "y and yes are yes, in any case" {
  local reply
  for reply in y Y yes YES Yes yEs; do
    run confirm_is_yes "$reply"
    assert_success
  done
}

@test "everything else is no" {
  local reply
  for reply in n N no NO "" " " ye yess yep sure 1 0 j ja Y' ' 'y y'; do
    run confirm_is_yes "$reply"
    assert_failure
  done
}

@test "an empty answer is no, so pressing Enter is not consent" {
  run confirm_is_yes ""
  assert_failure
}

# --- no terminal ------------------------------------------------------------

@test "confirm is no when stdin is not a terminal" {
  # A question nobody can answer must never be read as consent.
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    confirm 'Do the destructive thing?'
  " </dev/null
  assert_failure
}

@test "confirm does not even ask when there is no terminal" {
  # The caller prints the context; a prompt nobody sees would only be noise in a
  # log file.
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    confirm 'Do the destructive thing?'
  " </dev/null
  assert_failure
  [[ "$stderr" != *"Do the destructive thing?"* ]] ||
    fail "asked a question nobody could answer: $stderr"
}

@test "a 'yes' on a non-terminal stdin is still no" {
  # Piping yes into it is not a terminal, so it must not be taken as consent —
  # TASK_AGENT_KIT_RECREATE=yes is the supported way to say yes non-interactively.
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    printf 'yes\n' | confirm 'Do the destructive thing?'
  "
  assert_failure
}

# --- the log levels ---------------------------------------------------------

@test "info, success and warning all write to stderr, not stdout" {
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    info 'an info line'
    success 'a success line'
    warning 'a warning line'
  "
  assert_success
  assert_equal "$output" ""
  [[ "$stderr" == *"an info line"* ]] || fail "info missing: $stderr"
  [[ "$stderr" == *"a success line"* ]] || fail "success missing: $stderr"
  [[ "$stderr" == *"a warning line"* ]] || fail "warning missing: $stderr"
}

@test "die reports every line it is given and exits 1" {
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    die 'first line' 'second line'
  "
  assert_failure 1
  [[ "$stderr" == *"first line"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"second line"* ]] || fail "unexpected stderr: $stderr"
}
