#!/usr/bin/env bats
#
# End-to-end `agent-task --done <branch>` over a real git repository and a
# fake `sbx`. Mirrors session.bats' setup so a session can be started and then
# torn down within the same test.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  mkdir -p "$REPO/.sbx/kit"
  printf 'schemaVersion: "2"\nkind: mixin\n' >"$REPO/.sbx/kit/spec.yaml"

  make_fake_sbx "$TMP/fake"
}

task() {
  run --separate-stderr bash -c \
    "cd '$REPO' && '$AGENT_TASK' $(printf '%q ' "$@")"
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

# --- removal ------------------------------------------------------------

@test "--done removes an existing worktree and sandbox, keeps the branch" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  [[ -d "$wt" ]] || fail "worktree was not created: $wt"

  task --done feature/new-crud
  assert_success
  [[ "$stderr" == *"Removing sandbox"* ]] || fail "sandbox removal not reported: $stderr"
  [[ "$stderr" == *"Removing worktree"* ]] || fail "worktree removal not reported: $stderr"
  [[ "$stderr" == *"was kept"* ]] || fail "branch-kept message missing: $stderr"

  [[ ! -e "$wt" ]] || fail "worktree still exists: $wt"
  run git -C "$REPO" worktree list --porcelain
  assert_success
  assert_output_not_contains "$wt"

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_output_not_contains "agent-my-app-feature-new-crud"

  # The branch itself is untouched.
  run git -C "$REPO" show-ref --verify --quiet refs/heads/feature/new-crud
  assert_success
}

@test "--done drops the applied-kit record" {
  # A record left behind would claim a later sandbox of the same name already
  # has this kit, and the kit would silently never be applied to it.
  task feature/new-crud
  assert_success
  local record="$REPO/.git/agent-cli/kit/$(expected_sandbox feature/new-crud)"
  assert_file_exists "$record"

  task --done feature/new-crud
  assert_success
  assert_file_not_exists "$record"
}

@test "a sandbox recreated after --done gets the current kit" {
  task feature/new-crud
  assert_success
  task --done feature/new-crud
  assert_success

  # Recreated from the kit as it is now, and recorded as such — so the next run
  # neither re-applies it nor skips a later change.
  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"
  assert_file_exists "$REPO/.git/agent-cli/kit/$(expected_sandbox feature/new-crud)"
}

@test "--done removes an orphaned kit record when no sandbox is left" {
  task feature/new-crud
  assert_success
  local record="$REPO/.git/agent-cli/kit/$(expected_sandbox feature/new-crud)"

  # The sandbox is gone from sbx's point of view, but the record is still there.
  : >"$FAKE_SBX_DIR/sandboxes"

  task --done feature/new-crud
  assert_success
  [[ "$stderr" == *"No sandbox found"* ]] || fail "unexpected stderr: $stderr"
  assert_file_not_exists "$record"
}

@test "--done is a no-op with an informative message when nothing exists" {
  task --done feature/never-started
  assert_success
  [[ "$stderr" == *"No sandbox found"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"No worktree found"* ]] || fail "unexpected stderr: $stderr"
}

@test "--done removes an orphaned sandbox even if the worktree is already gone" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  git -C "$REPO" worktree remove "$wt"

  task --done feature/new-crud
  assert_success
  [[ "$stderr" == *"Removing sandbox"* ]] || fail "sandbox not cleaned up: $stderr"
  [[ "$stderr" == *"No worktree found"* ]] || fail "unexpected stderr: $stderr"

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_output_not_contains "agent-my-app-feature-new-crud"
}

# --- safety ---------------------------------------------------------------

@test "--done refuses to remove a dirty worktree, and leaves it in place" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  printf 'uncommitted\n' >"$wt/dirty.txt"

  task --done feature/new-crud
  assert_failure
  [[ "$stderr" == *"Failed to remove the worktree"* ]] || fail "unexpected stderr: $stderr"

  [[ -d "$wt" ]] || fail "worktree was removed despite being dirty: $wt"
  assert_file_exists "$wt/dirty.txt"

  # The sandbox was still cleaned up — removal is independent per resource.
  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_output_not_contains "agent-my-app-feature-new-crud"
}

@test "unpushed commits alone do not block --done, because the branch is kept" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  add_commit "$wt" only-local.txt "local only, never pushed"

  task --done feature/new-crud
  assert_success

  [[ ! -e "$wt" ]] || fail "worktree still exists: $wt"
  run git -C "$REPO" cat-file -e feature/new-crud:only-local.txt
  assert_success
}

# --- validation -------------------------------------------------------------

@test "--done validates the branch name before touching anything" {
  task --done 'feature/x..y'
  assert_failure
  [[ "$stderr" == *"Invalid branch name"* ]] || fail "unexpected stderr: $stderr"
}

@test "--done outside a git repository fails" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  run --separate-stderr bash -c "cd '$outside' && '$AGENT_TASK' --done feature/x"
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}
