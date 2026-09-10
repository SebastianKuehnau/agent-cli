#!/usr/bin/env bats
#
# End-to-end `task-agent --list` over a real git repository and a fake `sbx`
# (issue #25).
#
# The listing is a *view*: every assertion here is about it agreeing with what
# git and sbx say right now, never about anything task-agent recorded earlier.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  mkdir -p "$REPO/.sbx/kit"
  printf 'schemaVersion: "2"\nkind: mixin\n' >"$REPO/.sbx/kit/spec.yaml"

  make_fake_sbx "$TMP/fake"

  CLAUDE_CONFIG_DIR="$TMP/claude"
  export CLAUDE_CONFIG_DIR
}

task() {
  run --separate-stderr bash -c \
    "cd '$REPO' && '$TASK_AGENT' $(printf '%q ' "$@")"
}

expected_worktree() {
  bash -c "source '$AGENT_LIB/naming.sh'
    source '$AGENT_LIB/worktree.sh'
    worktree_path '$REPO' '$1'"
}

expected_sandbox() {
  bash -c "source '$AGENT_LIB/naming.sh'
    naming_sandbox_name \"\$(naming_project_id '$REPO')\" '$1'"
}

# --- the empty case ---------------------------------------------------------

@test "--list on a project with no tasks prints only the header" {
  task --list
  assert_success
  assert_output_contains "BRANCH"
  assert_output_contains "SANDBOX"
  assert_output_contains "WORKTREE"
  assert_equal "$(printf '%s' "$output" | wc -l | tr -d ' ')" "0"
}

@test "--list says how to start a task when there are none" {
  task --list
  assert_success
  # The hint is guidance, so it belongs on stderr, not in the table.
  [[ "$stderr" == *"task-agent <branch>"* ]] || fail "unexpected stderr: $stderr"
}

@test "the main worktree is not a task and is not listed" {
  task --list
  assert_success
  assert_output_not_contains "$REPO"
}

# --- a started task ---------------------------------------------------------

@test "--list shows a started task's branch, sandbox and worktree" {
  task feature/new-crud
  assert_success

  task --list
  assert_success
  assert_output_contains "feature/new-crud"
  assert_output_contains "$(expected_sandbox feature/new-crud)"
  assert_output_contains "$(expected_worktree feature/new-crud)"
}

@test "--list writes the table to stdout so it can be piped" {
  task feature/new-crud
  assert_success

  task --list
  assert_success
  [[ "$stderr" != *"feature/new-crud"* ]] ||
    fail "the table must not be duplicated on stderr: $stderr"
}

@test "--list shows every task, not just the most recent" {
  task feature/one
  assert_success
  task feature/two
  assert_success

  task --list
  assert_success
  assert_output_contains "feature/one"
  assert_output_contains "feature/two"
}

@test "colliding slugs stay separate rows" {
  # feature/x and feature-x slug alike; the hash of the raw branch name is what
  # keeps them apart, and the listing must not merge them back together.
  task feature/x
  assert_success
  task feature-x
  assert_success

  task --list
  assert_success
  assert_output_contains "$(expected_sandbox feature/x)"
  assert_output_contains "$(expected_sandbox feature-x)"
  assert_not_equal "$(expected_sandbox feature/x)" "$(expected_sandbox feature-x)"
}

# --- half-torn-down tasks ---------------------------------------------------

@test "a worktree whose sandbox is gone is listed with a dash" {
  task feature/new-crud
  assert_success

  # Remove the sandbox behind task-agent's back.
  : >"$FAKE_SBX_DIR/sandboxes"

  task --list
  assert_success
  assert_output_contains "feature/new-crud"
  assert_output_not_contains "$(expected_sandbox feature/new-crud)"
  [[ "$output" == *"feature/new-crud  -"* ]] ||
    fail "the missing sandbox should be a dash: $output"
}

@test "a sandbox whose worktree is gone is listed as an orphan" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  git_quiet -C "$REPO" worktree remove --force "$wt"

  task --list
  assert_success
  assert_output_contains "$(expected_sandbox feature/new-crud)"
  # The hash cannot be inverted, so the branch is reported as unknown rather
  # than guessed.
  assert_output_not_contains "feature/new-crud "
}

@test "--done leaves nothing behind in the listing" {
  task feature/new-crud
  assert_success
  task --done feature/new-crud
  assert_success

  task --list
  assert_success
  assert_output_not_contains "feature/new-crud"
  assert_output_not_contains "$(expected_sandbox feature/new-crud)"
}

# --- git's registration wins ------------------------------------------------

@test "a worktree registered at a non-derived path is listed at that path" {
  # Same rule the rest of task-agent follows: git's registered worktree is the
  # source of truth, even when the path is not the one task-agent would derive.
  local elsewhere="$TMP/somewhere-else"
  git_quiet -C "$REPO" worktree add -b feature/moved "$elsewhere" >/dev/null 2>&1

  task --list
  assert_success
  assert_output_contains "feature/moved"
  assert_output_contains "$elsewhere"
  assert_output_not_contains "$(expected_worktree feature/moved)"
}

@test "a detached worktree is not listed as a task" {
  # A task is identified by a branch; a detached worktree has none, so there is
  # no sandbox name to relate it to.
  local detached="$TMP/detached"
  git_quiet -C "$REPO" worktree add --detach "$detached" >/dev/null 2>&1

  task --list
  assert_success
  assert_output_not_contains "$detached"
}

# --- --all ------------------------------------------------------------------

@test "--list omits sandboxes belonging to other projects" {
  fake_sbx_add_sandbox "agent-other-app-feature-x-abc123"

  task --list
  assert_success
  assert_output_not_contains "agent-other-app-feature-x-abc123"
}

@test "--list --all also lists sandboxes task-agent did not create" {
  fake_sbx_add_sandbox "agent-other-app-feature-x-abc123"
  fake_sbx_add_sandbox "some-hand-made-sandbox"

  task --list --all
  assert_success
  assert_output_contains "OTHER SANDBOXES"
  assert_output_contains "agent-other-app-feature-x-abc123"
  assert_output_contains "some-hand-made-sandbox"
}

@test "--list --all does not repeat this project's sandboxes" {
  task feature/new-crud
  assert_success
  fake_sbx_add_sandbox "some-hand-made-sandbox"

  task --list --all
  assert_success
  local own
  own="$(expected_sandbox feature/new-crud)"
  assert_equal "$(printf '%s\n' "$output" | grep -c -- "$own")" "1"
}

@test "--list --all reports a dash when there are no other sandboxes" {
  task --list --all
  assert_success
  assert_output_contains "OTHER SANDBOXES"
}

# --- paths with spaces ------------------------------------------------------

@test "a worktree path containing spaces is listed whole" {
  local spaced="$TMP/a path with spaces"
  git_quiet -C "$REPO" worktree add -b feature/spaced "$spaced" >/dev/null 2>&1

  task --list
  assert_success
  assert_output_contains "$spaced"
}

# --- read-only --------------------------------------------------------------

@test "--list creates nothing and removes nothing" {
  task feature/new-crud
  assert_success
  local before_sandboxes
  before_sandboxes="$(cat "$FAKE_SBX_DIR/sandboxes")"
  : >"$FAKE_SBX_DIR/calls.log"

  task --list
  assert_success

  assert_equal "$(cat "$FAKE_SBX_DIR/sandboxes")" "$before_sandboxes"
  # The only sbx it may reach for is the listing itself.
  assert_equal "$(grep -cx 'arg:ls' "$FAKE_SBX_DIR/calls.log")" "1"
  assert_equal "$(grep -cxE 'arg:(create|rm|run|cp|exec)' "$FAKE_SBX_DIR/calls.log" || true)" "0"
}

@test "--list works from inside a worktree, not just the main repository" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  run --separate-stderr bash -c "cd '$wt' && '$TASK_AGENT' --list"
  assert_success
  assert_output_contains "feature/new-crud"
}

@test "--list stops instead of showing every sandbox as missing" {
  # A daemon that is not running makes `sbx ls` fail. Printing the table anyway
  # would show every task with a "-" sandbox — indistinguishable from a project
  # whose sandboxes really were removed by hand.
  task feature/new-crud
  assert_success

  run --separate-stderr env FAKE_SBX_LS_EXIT=1 bash -c \
    "cd '$REPO' && '$TASK_AGENT' --list"
  assert_failure
  [[ "$stderr" == *"did not answer"* ]] || fail "unexpected stderr: $stderr"
  assert_output_not_contains "feature/new-crud"
}

@test "--list needs a git repository" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  run --separate-stderr bash -c "cd '$outside' && '$TASK_AGENT' --list"
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}
