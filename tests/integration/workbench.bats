#!/usr/bin/env bats
#
# End-to-end `task-agent --here` and `task-agent --done --here` over a real git
# repository and a fake `sbx` (issue #34).
#
# The workbench is the project's one sandbox on the main checkout itself: no
# branch is created, no worktree is added, and the agent sees whatever is
# checked out there. Inside a task's worktree, --here reaches that task instead.

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

# task_in <dir> <args...> — run task-agent from <dir>.
task_in() {
  local dir="$1"
  shift
  run --separate-stderr bash -c \
    "cd '$dir' && '$TASK_AGENT' $(printf '%q ' "$@")"
}

task() {
  task_in "$REPO" "$@"
}

workbench() {
  bash -c "source '$AGENT_LIB/naming.sh'
    naming_workbench_name \"\$(naming_project_id '$REPO')\""
}

expected_sandbox() {
  bash -c "source '$AGENT_LIB/naming.sh'
    naming_sandbox_name \"\$(naming_project_id '$REPO')\" '$1'"
}

expected_worktree() {
  bash -c "source '$AGENT_LIB/naming.sh'
    source '$AGENT_LIB/worktree.sh'
    worktree_path '$REPO' '$1'"
}

# --- the workbench on the main checkout -------------------------------------

@test "the workbench sandbox is named after the project, not after a branch" {
  assert_equal "$(workbench)" "agent-my-app-workbench"
}

@test "--here in the main checkout creates the workbench on the main checkout" {
  task --here
  assert_success

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_output_contains "$(workbench)"

  # The main checkout is the only workspace: its .git is inside it.
  run fake_sbx_calls
  assert_output_contains "$(printf 'arg:create\narg:--kit\narg:%s\narg:--name\narg:%s\narg:claude\narg:%s\n=== call' \
    "$REPO/.sbx/kit" "$(workbench)" "$REPO")"
}

@test "--here attaches to the workbench, verifying the agent" {
  task --here
  assert_success

  run fake_sbx_calls
  assert_output_contains "$(printf 'arg:run\narg:claude\narg:--name\narg:%s' "$(workbench)")"
}

@test "--here creates no branch and no worktree" {
  task --here
  assert_success

  run git -C "$REPO" branch --format='%(refname:short)'
  assert_equal "$output" "main"

  run git -C "$REPO" worktree list --porcelain
  assert_equal "$(grep -c '^worktree ' <<<"$output")" "1"
  [[ ! -d "$TMP/my-app-worktrees" ]] || fail "a worktree directory was created"
}

@test "a second --here reuses the workbench" {
  task --here
  assert_success
  task --here
  assert_success

  assert_equal "$(fake_sbx_subcommand_call_count create)" "1"
  assert_equal "$(fake_sbx_subcommand_call_count run)" "2"
}

@test "the workbench does not depend on the branch checked out" {
  task --here
  assert_success
  git_quiet -C "$REPO" checkout --quiet -b feature/other
  task --here
  assert_success

  assert_equal "$(fake_sbx_subcommand_call_count create)" "1"
  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" "$(workbench)"
}

@test "--here works from a subdirectory of the main checkout" {
  mkdir -p "$REPO/src/deep"
  task_in "$REPO/src/deep" --here
  assert_success

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" "$(workbench)"
}

@test "--here hands sbx the physical path, even when invoked via a symlink" {
  ln -s "$REPO" "$TMP/link"
  task_in "$TMP/link" --here
  assert_success

  run fake_sbx_calls
  assert_output_contains "arg:$REPO"
  assert_output_not_contains "arg:$TMP/link"
}

@test "--here works when the repository path contains spaces" {
  local spaced="$TMP/with space/my-app"
  mkdir -p "$TMP/with space"
  mv "$REPO" "$spaced"
  REPO="$spaced"

  task --here
  assert_success
  run fake_sbx_calls
  assert_output_contains "arg:$REPO"
}

@test "--here in a project without a Sandbox Kit creates nothing" {
  rm -rf "$REPO/.sbx"
  task --here
  assert_failure
  assert_equal "$(fake_sbx_subcommand_call_count create)" "0"
}

# --- the kit -----------------------------------------------------------------

@test "a changed kit recreates the workbench on the main checkout" {
  task --here
  assert_success
  printf 'changed\n' >>"$REPO/.sbx/kit/spec.yaml"

  TASK_AGENT_KIT_RECREATE=yes task --here
  assert_success

  assert_equal "$(fake_sbx_subcommand_call_count rm)" "1"
  assert_equal "$(fake_sbx_subcommand_call_count create)" "2"
  # The recreated sandbox still has the main checkout as its only workspace.
  run fake_sbx_calls
  assert_output_contains "$(printf 'arg:%s\narg:claude\narg:%s\n=== call\narg:run' "$(workbench)" "$REPO")"
}

@test "a changed kit with no terminal leaves the workbench and names --done --here" {
  task --here
  assert_success
  printf 'changed\n' >>"$REPO/.sbx/kit/spec.yaml"

  task --here
  assert_success
  assert_equal "$(fake_sbx_subcommand_call_count rm)" "0"
  [[ "$stderr" == *"task-agent --done --here"* ]] || fail "unexpected stderr: $stderr"
}

# --- --here inside a task's worktree ------------------------------------------

@test "--here inside a task's worktree reaches that task, not a second sandbox" {
  task feature/x
  assert_success

  task_in "$(expected_worktree feature/x)" --here
  assert_success

  assert_equal "$(fake_sbx_subcommand_call_count create)" "1"
  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" "$(expected_sandbox feature/x)"
  run fake_sbx_calls
  assert_output_contains "$(printf 'arg:run\narg:claude\narg:--name\narg:%s' "$(expected_sandbox feature/x)")"
}

@test "--here inside a task's worktree whose sandbox is gone recreates the task's" {
  task feature/x
  assert_success
  : >"$FAKE_SBX_DIR/sandboxes"

  task_in "$(expected_worktree feature/x)" --here
  assert_success

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" "$(expected_sandbox feature/x)"
}

@test "--here in a detached worktree is refused" {
  git_quiet -C "$REPO" worktree add --quiet --detach "$TMP/detached" HEAD
  task_in "$TMP/detached" --here
  assert_failure
  [[ "$stderr" == *"detached"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(fake_sbx_subcommand_call_count create)" "0"
}

# --- --done --here -------------------------------------------------------------

@test "--done --here removes the workbench and leaves the checkout alone" {
  printf 'work in progress\n' >"$REPO/untracked.txt"
  task --here
  assert_success

  task --done --here
  assert_success

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" ""
  assert_file_exists "$REPO/untracked.txt"
  run git -C "$REPO" branch --show-current
  assert_equal "$output" "main"
}

@test "--done --here rescues transcripts before removing the workbench" {
  task --here
  assert_success
  fake_sbx_add_transcript "/home/agent/.claude/projects/-x/session.jsonl"

  task --done --here
  assert_success

  run fake_sbx_calls
  # exec (the rescue's listing) comes before rm.
  local exec_line rm_line
  exec_line="$(grep -n '^arg:exec$' "$FAKE_SBX_DIR/calls.log" | head -1 | cut -d: -f1)"
  rm_line="$(grep -n '^arg:rm$' "$FAKE_SBX_DIR/calls.log" | head -1 | cut -d: -f1)"
  [[ -n "$exec_line" && -n "$rm_line" && "$exec_line" -lt "$rm_line" ]] ||
    fail "rescue did not run before removal"
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/-x/session.jsonl"
}

@test "--done --here drops the workbench's applied-kit record" {
  task --here
  assert_success
  task --done --here
  assert_success

  [[ ! -e "$REPO/.git/agent-cli/kit/$(workbench)" ]] || fail "kit record left behind"
}

@test "--done --here with no workbench says so and succeeds" {
  task --done --here
  assert_success
  [[ "$stderr" == *"No workbench"* ]] || fail "unexpected stderr: $stderr"
}

@test "--done --here stops when the runtime is unreachable" {
  task --here
  assert_success

  FAKE_SBX_LS_EXIT=1 task --done --here
  assert_failure
  assert_equal "$(fake_sbx_subcommand_call_count rm)" "0"
}

@test "--done --here inside a task's worktree is refused and removes nothing" {
  task feature/x
  assert_success

  task_in "$(expected_worktree feature/x)" --done --here
  assert_failure
  [[ "$stderr" == *"task-agent --done feature/x"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(fake_sbx_subcommand_call_count rm)" "0"
  [[ -d "$(expected_worktree feature/x)" ]] || fail "worktree was removed"
}

@test "--done --here leaves the project's tasks alone" {
  task feature/x
  assert_success
  task --here
  assert_success

  task --done --here
  assert_success

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_equal "$output" "$(expected_sandbox feature/x)"
}

# --- --list ------------------------------------------------------------------

@test "--list shows the workbench as its own row on the main checkout" {
  task --here
  assert_success

  task --list
  assert_success
  local row
  row="$(grep -F "$(workbench)" <<<"$output")"
  [[ "$row" == "(workbench)"* ]] || fail "unexpected row: $row"
  [[ "$row" == *"  $REPO" ]] || fail "unexpected row: $row"
}

@test "--list does not report the workbench as an orphan" {
  task --here
  assert_success

  task --list
  assert_success
  assert_equal "$(grep -c -F "$(workbench)" <<<"$output")" "1"
  run grep -E '^-  ' <<<"$output"
  assert_failure
}

@test "--list shows no workbench row when there is no workbench" {
  task feature/x
  assert_success
  task --list
  assert_success
  assert_output_not_contains "(workbench)"
}

@test "--list --all does not repeat the workbench under other sandboxes" {
  task --here
  assert_success
  task --list --all
  assert_success
  assert_equal "$(grep -c -F "$(workbench)" <<<"$output")" "1"
}
