#!/usr/bin/env bats
#
# Argument parsing, dispatch and help for bin/task-agent.
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
    "cd '$REPO' && '$TASK_AGENT' $(printf '%q ' "$@")"
}

# --- help -------------------------------------------------------------------

@test "--help prints usage on stdout and exits 0" {
  cli --help
  assert_success
  assert_output_contains "Usage:"
  assert_output_contains "task-agent --init"
  assert_output_contains "task-agent <branch> [--base <branch>]"
}

@test "-h is equivalent to --help" {
  cli -h
  assert_success
  assert_output_contains "Usage:"
}

@test "help calls the command task-agent, not agent-task" {
  # The command was renamed in v0.2.0 (issue #8); a half-done rename would show
  # up here first.
  cli --help
  assert_success
  assert_output_contains "task-agent --init"
  assert_output_not_contains "agent-task"
}

@test "log output is prefixed with the current command name" {
  cli feature/new-crud
  assert_failure
  [[ "$stderr" == *"[task-agent]"* ]] || fail "unexpected log prefix: $stderr"
  [[ "$stderr" != *"[agent-task]"* ]] || fail "stale log prefix: $stderr"
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
  for flag in --submit --sync --status --shell --plan --force --rebuild; do
    assert_output_not_contains "$flag"
  done
}

@test "help documents --done, --update and --version" {
  cli --help
  assert_success
  assert_output_contains "--done"
  assert_output_contains "--update"
  assert_output_contains "--version"
}

# --- version ----------------------------------------------------------------

@test "--version prints the version from lib/version.sh on stdout" {
  local declared
  declared="$(bash -c "source '$AGENT_LIB/version.sh'; printf '%s' \"\$TASK_AGENT_VERSION\"")"

  cli --version
  assert_success
  assert_equal "$output" "$declared"
  # A version is data a script may want to read, so — unlike every log line —
  # it must be on stdout and nothing else may join it there.
  assert_equal "$stderr" ""
}

@test "the version looks like a version" {
  cli --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a version: '$output'"
}

@test "--version works outside a git repository" {
  # It reports a property of the install, not of any repository.
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  run --separate-stderr bash -c "cd '$outside' && '$TASK_AGENT' --version"
  assert_success
}

@test "--version with a branch name is rejected" {
  cli --version feature/x
  assert_failure
  [[ "$stderr" == *"--version does not take a branch name"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--version with --base is rejected" {
  cli --version --base develop
  assert_failure
  [[ "$stderr" == *"--base is not valid with --version"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--version and --update together are rejected" {
  cli --version --update
  assert_failure
  [[ "$stderr" == *"Only one of --init, --done, --update, --version may be given"* ]] ||
    fail "unexpected stderr: $stderr"
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

@test "--init's positional argument is a preset, so a branch name is rejected" {
  # --init used to reject every positional argument. It now takes one: a preset
  # name. A branch name is not one, so it still fails — with the message that
  # says what the argument is actually for.
  cli --init feature/x
  assert_failure
  [[ "$stderr" == *"Unknown preset: feature/x"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "--init with two positional arguments is rejected" {
  cli --init generic vaadin
  assert_failure
  [[ "$stderr" == *"Unexpected extra argument: vaadin"* ]] ||
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
  [[ "$stderr" == *"Only one of --init, --done, --update, --version may be given"* ]] ||
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
  [[ "$stderr" == *"Only one of --init, --done, --update, --version may be given"* ]] ||
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
  [[ "$stderr" == *"task-agent --init"* ]] || fail "unexpected stderr: $stderr"
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
    bash -c "cd '$REPO' && '$TASK_AGENT' feature/x"
  assert_failure
  [[ "$stderr" == *"sbx"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"Docker Sandboxes"* ]] || fail "unexpected stderr: $stderr"
}

@test "running outside a git repository fails for a branch invocation" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  run --separate-stderr bash -c "cd '$outside' && '$TASK_AGENT' feature/x"
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}
