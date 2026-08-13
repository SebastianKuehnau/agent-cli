#!/usr/bin/env bats
#
# Argument parsing, dispatch and help for bin/agent-task.
#
# Session-starting invocations are run inside a repo with no Sandbox Kit, so
# they stop at a well-defined, side-effect-free point after the arguments have
# been accepted. That lets argument handling be tested without Docker while
# still exercising the real entry point.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  # A fake sbx keeps `sandbox_require_cli` from being the thing that fails.
  make_fake_sbx "$TMP/fake"
}

cli() {
  run --separate-stderr bash -c \
    "cd '$REPO' && '$AGENT_TASK' $(printf '%q ' "$@")"
}

# --- help -------------------------------------------------------------------

@test "--help prints usage on stdout and exits 0" {
  cli --help
  assert_success
  assert_output_contains "Usage:"
  assert_output_contains "agent-task --init"
  assert_output_contains "agent-task <branch> [--base <branch>]"
}

@test "-h is equivalent to --help" {
  cli -h
  assert_success
  assert_output_contains "Usage:"
}

@test "help documents --base and its default" {
  cli --help
  assert_success
  assert_output_contains "--base"
  assert_output_contains "Default: main"
}

@test "help does not mention commands from later phases" {
  cli --help
  assert_success
  local flag
  for flag in --submit --sync --status --shell --plan --version --force --rebuild; do
    assert_output_not_contains "$flag"
  done
}

@test "help documents --done and --update" {
  cli --help
  assert_success
  assert_output_contains "--done"
  assert_output_contains "--update"
}

# --- no arguments -----------------------------------------------------------

@test "no arguments prints usage and exits non-zero" {
  cli
  assert_failure
  [[ "$stderr" == *"Usage:"* ]] || fail "usage not printed to stderr: $stderr"
}

# --- rejection --------------------------------------------------------------

@test "an unknown option is rejected" {
  cli --wat
  assert_failure
  [[ "$stderr" == *"Unknown option: --wat"* ]] || fail "unexpected stderr: $stderr"
}

@test "a later-phase option is rejected rather than silently ignored" {
  cli feature/x --submit
  assert_failure
  [[ "$stderr" == *"Unknown option: --submit"* ]] || fail "unexpected stderr: $stderr"
}

@test "--base without a value is rejected" {
  cli feature/x --base
  assert_failure
  [[ "$stderr" == *"--base requires a branch name"* ]] || fail "unexpected stderr: $stderr"
}

@test "--base= with an empty value is rejected" {
  cli feature/x --base=
  assert_failure
  [[ "$stderr" == *"--base requires a branch name"* ]] || fail "unexpected stderr: $stderr"
}

@test "an extra positional argument is rejected, not silently discarded" {
  # The predecessor took the last positional and ignored the rest.
  cli feature/x feature/y
  assert_failure
  [[ "$stderr" == *"Unexpected extra argument: feature/y"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--init with a branch name is rejected" {
  cli --init feature/x
  assert_failure
  [[ "$stderr" == *"--init does not take a branch name"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--init with --base is rejected" {
  cli --init --base develop
  assert_failure
  [[ "$stderr" == *"--base is not valid with --init"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--done without a branch name is rejected" {
  cli --done
  assert_failure
  [[ "$stderr" == *"No branch name given"* ]] || fail "unexpected stderr: $stderr"
}

@test "--done with --base is rejected" {
  cli --done feature/x --base develop
  assert_failure
  [[ "$stderr" == *"--base is not valid with --done"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--done and --init together are rejected" {
  cli --done --init
  assert_failure
  [[ "$stderr" == *"Only one of --init, --done, --update may be given"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--update with a branch name is rejected" {
  cli --update feature/x
  assert_failure
  [[ "$stderr" == *"--update does not take a branch name"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--update with --base is rejected" {
  cli --update --base develop
  assert_failure
  [[ "$stderr" == *"--base is not valid with --update"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--update and --done together are rejected" {
  cli --update --done feature/x
  assert_failure
  [[ "$stderr" == *"Only one of --init, --done, --update may be given"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--update refuses to run against a git checkout with lib/ present" {
  cli --update
  assert_failure
  [[ "$stderr" == *"git checkout"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"git -C"* && "$stderr" == *"pull"* ]] ||
    fail "missing git pull hint: $stderr"
}

@test "an invalid branch name is rejected before anything is created" {
  cli 'feature/x..y'
  assert_failure
  [[ "$stderr" == *"Invalid branch name"* ]] || fail "unexpected stderr: $stderr"

  # Nothing was created.
  assert_file_not_exists "$TMP/my-app-worktrees"
  assert_equal "$(fake_sbx_call_count)" "0"
}

@test "an invalid --base value is rejected before anything is created" {
  cli feature/x --base 'bad..base'
  assert_failure
  [[ "$stderr" == *"Invalid branch name"* ]] || fail "unexpected stderr: $stderr"
  assert_file_not_exists "$TMP/my-app-worktrees"
}

# --- acceptance -------------------------------------------------------------

@test "a bare branch argument is accepted and reaches the kit check" {
  cli feature/new-crud
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] ||
    fail "did not reach the kit check: $stderr"
}

@test "branch with --base is accepted and reaches the kit check" {
  git_quiet -C "$REPO" branch develop
  cli feature/new-crud --base develop
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] ||
    fail "did not reach the kit check: $stderr"
}

@test "--base may be given before the branch" {
  git_quiet -C "$REPO" branch develop
  cli --base develop feature/new-crud
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] ||
    fail "did not reach the kit check: $stderr"
}

@test "--base=<value> form is accepted" {
  git_quiet -C "$REPO" branch develop
  cli feature/new-crud --base=develop
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] ||
    fail "did not reach the kit check: $stderr"
}

@test "the missing-kit error tells the user to run --init" {
  cli feature/new-crud
  assert_failure
  [[ "$stderr" == *"agent-task --init"* ]] || fail "unexpected stderr: $stderr"
}

@test "the kit check runs before any branch or worktree is created" {
  cli feature/new-crud
  assert_failure
  run git -C "$REPO" show-ref --verify --quiet refs/heads/feature/new-crud
  assert_failure
  assert_file_not_exists "$TMP/my-app-worktrees"
}

# --- environment preconditions ---------------------------------------------

@test "a missing sbx CLI produces an actionable error" {
  # A PATH with git and curl but deliberately no sbx.
  local stub="$TMP/nosbx"
  mkdir -p "$stub"
  ln -s "$(command -v git)" "$stub/git"
  ln -s "$(command -v curl)" "$stub/curl"
  ln -s "$(command -v shasum 2>/dev/null || command -v sha256sum)" "$stub/shasum" 2>/dev/null || true

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" \
    bash -c "cd '$REPO' && '$AGENT_TASK' feature/x"
  assert_failure
  [[ "$stderr" == *"sbx"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"Docker Sandboxes"* ]] || fail "unexpected stderr: $stderr"
}

@test "running outside a git repository fails for a branch invocation" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  run --separate-stderr bash -c "cd '$outside' && '$AGENT_TASK' feature/x"
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}
