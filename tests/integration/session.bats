#!/usr/bin/env bats
#
# End-to-end orchestration of `task-agent <branch>` over a real git repository
# and a fake `sbx`. This covers the create-then-reuse contract: running the same
# command twice must reuse the branch, the worktree and the sandbox.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  # A project that has been initialised.
  mkdir -p "$REPO/.sbx/kit"
  printf 'schemaVersion: "2"\nkind: mixin\n' >"$REPO/.sbx/kit/spec.yaml"

  make_fake_sbx "$TMP/fake"
}

task() {
  run --separate-stderr bash -c \
    "cd '$REPO' && '$TASK_AGENT' $(printf '%q ' "$@")"
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

# --- first run --------------------------------------------------------------

@test "a first run creates the branch, the worktree and the sandbox" {
  task feature/new-crud
  assert_success

  run git -C "$REPO" show-ref --verify --quiet refs/heads/feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  [[ -d "$wt" ]] || fail "worktree not created: $wt"

  run cat "$FAKE_SBX_DIR/sandboxes"
  assert_output_contains "$(expected_sandbox feature/new-crud)"
}

@test "the new branch is based on main, not on the caller's current HEAD" {
  git_quiet -C "$REPO" switch --quiet -c experimental/foo
  add_commit "$REPO" only-on-experimental.txt "experimental"

  task feature/new-crud
  assert_success

  assert_equal \
    "$(git -C "$REPO" rev-parse feature/new-crud)" \
    "$(git -C "$REPO" rev-parse main)"
  run git -C "$REPO" cat-file -e feature/new-crud:only-on-experimental.txt
  assert_failure
}

@test "--base selects the base for a new branch" {
  git_quiet -C "$REPO" branch develop
  git_quiet -C "$REPO" switch --quiet develop
  add_commit "$REPO" only-on-develop.txt "develop"
  git_quiet -C "$REPO" switch --quiet main

  task feature/from-develop --base develop
  assert_success

  assert_equal \
    "$(git -C "$REPO" rev-parse feature/from-develop)" \
    "$(git -C "$REPO" rev-parse develop)"
}

@test "the sandbox is created with the worktree and the git metadata dir" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"

  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:--kit"
  assert_output_contains "arg:$REPO/.sbx/kit"
  assert_output_contains "arg:claude"
  assert_output_contains "arg:$wt"
  assert_output_contains "arg:$REPO/.git"
}

@test "the sandbox is attached to after being created" {
  task feature/new-crud
  assert_success

  # Exactly one create and one run, in that order.
  run grep -E '^arg:(create|run|ls)$' "$FAKE_SBX_DIR/calls.log"
  assert_success
  assert_equal "$output" "arg:ls
arg:create
arg:run"
}

@test "the checked-out branch inside the worktree is the requested one" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  run git -C "$wt" branch --show-current
  assert_success
  assert_equal "$output" "feature/new-crud"
}

# --- second run: reuse ------------------------------------------------------

@test "a second identical run reuses branch, worktree and sandbox" {
  task feature/new-crud
  assert_success
  local head_before
  head_before="$(git -C "$REPO" rev-parse feature/new-crud)"

  task feature/new-crud
  assert_success
  [[ "$stderr" == *"Reusing existing branch"* ]] || fail "branch not reused: $stderr"
  [[ "$stderr" == *"Reusing sandbox"* ]] || fail "sandbox not reused: $stderr"

  # The branch was not moved.
  assert_equal "$(git -C "$REPO" rev-parse feature/new-crud)" "$head_before"

  # Exactly one linked worktree (plus the main checkout).
  local count
  count="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
  assert_equal "$count" "2"

  # Exactly one sandbox, created once.
  assert_equal "$(wc -l <"$FAKE_SBX_DIR/sandboxes" | tr -d ' ')" "1"
  assert_equal "$(grep -c '^arg:create$' "$FAKE_SBX_DIR/calls.log")" "1"
}

@test "a reused run attaches without creating a second sandbox" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success

  run grep -E '^arg:(create|run|ls)$' "$FAKE_SBX_DIR/calls.log"
  assert_success
  assert_equal "$output" "arg:ls
arg:run"
}

@test "--base is ignored when the branch already exists" {
  git_quiet -C "$REPO" branch develop
  git_quiet -C "$REPO" switch --quiet develop
  add_commit "$REPO" only-on-develop.txt "develop"
  git_quiet -C "$REPO" switch --quiet main

  task feature/x
  assert_success
  local head_before
  head_before="$(git -C "$REPO" rev-parse feature/x)"

  task feature/x --base develop
  assert_success
  assert_equal "$(git -C "$REPO" rev-parse feature/x)" "$head_before"
}

# --- changed Sandbox Kit (issue #7) -----------------------------------------

# kit_digest — the digest task-agent computes for the project's current kit.
kit_digest() {
  bash -c "source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/naming.sh'
    source '$AGENT_LIB/scaffold.sh'
    scaffold_kit_hash '$REPO'"
}

# recorded_digest <sandbox> — the digest recorded as applied to <sandbox>.
recorded_digest() {
  bash -c "source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/git.sh'
    source '$AGENT_LIB/kit.sh'
    kit_cache_read '$REPO' '$1'"
}

change_kit() {
  printf 'schemaVersion: "2"\nkind: mixin\nname: changed\n' >"$REPO/.sbx/kit/spec.yaml"
}

@test "creating a sandbox does not also apply the kit to it" {
  # `sbx create --kit` already did that; a second application would be noise.
  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"
}

@test "creating a sandbox records the kit it was created from" {
  task feature/new-crud
  assert_success
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"
}

@test "an unchanged kit is not re-applied on reuse" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"
}

@test "a changed kit is applied to the existing sandbox" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  task feature/new-crud
  assert_success

  assert_equal "$(fake_sbx_kit_call_count)" "1"
  [[ "$stderr" == *"Sandbox Kit changed"* ]] || fail "change not reported: $stderr"
  [[ "$stderr" == *"Applied the current Sandbox Kit"* ]] || fail "not applied: $stderr"
}

@test "the kit is applied with the sandbox name and the kit directory, as separate arguments" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  task feature/new-crud
  assert_success

  # One argument per line, so a quoting bug cannot hide behind a joined string.
  run grep -A 3 -x 'arg:kit' "$FAKE_SBX_DIR/calls.log"
  assert_success
  assert_equal "$output" "arg:kit
arg:add
arg:$(expected_sandbox feature/new-crud)
arg:$REPO/.sbx/kit"
}

@test "applying a changed kit records the new digest" {
  task feature/new-crud
  assert_success
  change_kit
  task feature/new-crud
  assert_success

  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"
}

@test "a changed kit is applied once, not on every following run" {
  task feature/new-crud
  assert_success
  change_kit
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"
}

@test "a sandbox whose applied kit is unknown gets the current kit applied" {
  # The state a sandbox created by an older task-agent is in, and the state a
  # lost cache entry leaves behind: the kit in there cannot be known, so apply.
  task feature/new-crud
  assert_success
  rm -rf "$REPO/.git/agent-cli"
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "1"
  [[ "$stderr" == *"is unknown"* ]] || fail "unexpected stderr: $stderr"
}

@test "the agent still starts when applying the kit fails" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  export FAKE_SBX_KIT_EXIT=1
  task feature/new-crud
  unset FAKE_SBX_KIT_EXIT
  assert_success

  # `sbx kit add` is experimental; its failure must not block the agent.
  [[ "$stderr" == *"Could not apply the changed Sandbox Kit"* ]] ||
    fail "failure not reported: $stderr"
  [[ "$stderr" == *"sbx kit add $(expected_sandbox feature/new-crud) $REPO/.sbx/kit"* ]] ||
    fail "no manual command offered: $stderr"
  run grep -cx 'arg:run' "$FAKE_SBX_DIR/calls.log"
  assert_equal "$output" "1"
}

@test "a failed kit application is retried on the next run" {
  task feature/new-crud
  assert_success
  local before
  before="$(recorded_digest "$(expected_sandbox feature/new-crud)")"

  change_kit
  export FAKE_SBX_KIT_EXIT=1
  task feature/new-crud
  unset FAKE_SBX_KIT_EXIT
  assert_success

  # The digest must not have moved on, or the failure would be swallowed.
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$before"

  : >"$FAKE_SBX_DIR/calls.log"
  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "1"
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"
}

@test "each sandbox tracks its own applied kit" {
  task feature/one
  assert_success
  change_kit
  task feature/two
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  # feature/two was created from the changed kit, feature/one predates it.
  task feature/two
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"

  task feature/one
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "1"
}

# --- naming -----------------------------------------------------------------

@test "the sandbox name is deterministic across runs" {
  task feature/new-crud
  assert_success
  local first
  first="$(cat "$FAKE_SBX_DIR/sandboxes")"

  task feature/new-crud
  assert_success
  assert_equal "$(cat "$FAKE_SBX_DIR/sandboxes")" "$first"
}

@test "colliding branch slugs get separate worktrees and sandboxes" {
  task feature/foo
  assert_success
  task feature-foo
  assert_success

  # Two linked worktrees plus the main checkout.
  local count
  count="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
  assert_equal "$count" "3"

  # Two distinct sandboxes.
  assert_equal "$(sort -u "$FAKE_SBX_DIR/sandboxes" | wc -l | tr -d ' ')" "2"
}

# --- invocation context -----------------------------------------------------

@test "running from a subdirectory works" {
  mkdir -p "$REPO/src/main/java"
  run --separate-stderr bash -c \
    "cd '$REPO/src/main/java' && '$TASK_AGENT' feature/new-crud"
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  [[ -d "$wt" ]] || fail "worktree not created: $wt"
}

@test "running from inside an existing worktree reuses that session" {
  task feature/new-crud
  assert_success
  local wt
  wt="$(expected_worktree feature/new-crud)"

  run --separate-stderr bash -c "cd '$wt' && '$TASK_AGENT' feature/new-crud"
  assert_success
  [[ "$stderr" == *"Reusing sandbox"* ]] || fail "sandbox not reused: $stderr"
  assert_equal "$(grep -c '^arg:create$' "$FAKE_SBX_DIR/calls.log")" "1"
}

@test "an existing origin branch is checked out as a tracking branch" {
  make_bare_origin "$REPO" "$TMP/origin.git" >/dev/null
  git_quiet -C "$REPO" branch feature/remote-only
  git_quiet -C "$REPO" push --quiet origin feature/remote-only
  git_quiet -C "$REPO" branch -D feature/remote-only

  task feature/remote-only
  assert_success
  [[ "$stderr" == *"tracking origin/feature/remote-only"* ]] ||
    fail "unexpected stderr: $stderr"
}

# --- repository paths with spaces ------------------------------------------

@test "the whole workflow works when the repository path contains spaces" {
  local spacey="$TMP/my project with spaces"
  make_repo "$spacey" >/dev/null
  mkdir -p "$spacey/.sbx/kit"
  printf 'schemaVersion: "2"\n' >"$spacey/.sbx/kit/spec.yaml"

  run --separate-stderr bash -c \
    "cd '$spacey' && '$TASK_AGENT' feature/new-crud"
  assert_success

  # The worktree path with spaces reached sbx as a single argument.
  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:$spacey-worktrees/"
  assert_output_contains "arg:$spacey/.git"
  assert_output_contains "arg:$spacey/.sbx/kit"
}

# --- symlinked invocation paths --------------------------------------------

@test "every path handed to sbx is physical, even when invoked via a symlink" {
  # Regression test for the failure the Docker Sandboxes spike exposed. A linked
  # worktree's .git file holds git's *physical* path into the main repository.
  # If agent-cli handed sbx a symlinked alias instead, the mount inside the
  # sandbox would sit at a path the .git pointer does not name, and git inside
  # the sandbox would fail with "not a git repository".
  ln -s "$REPO" "$TMP/link-to-repo"

  run --separate-stderr bash -c \
    "cd '$TMP/link-to-repo' && '$TASK_AGENT' feature/new-crud"
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"

  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:$wt"
  assert_output_contains "arg:$REPO/.git"
  assert_output_contains "arg:$REPO/.sbx/kit"
  assert_output_not_contains "link-to-repo"
}

@test "the worktree .git pointer names a path that was handed to sbx" {
  # The end-to-end invariant, asserted on the host: whatever absolute path the
  # worktree's .git file points into must be covered by one of the workspaces
  # passed to sbx. This is exactly what makes git work inside the sandbox.
  task feature/new-crud
  assert_success

  local wt gitdir
  wt="$(expected_worktree feature/new-crud)"
  gitdir="$(sed -n 's/^gitdir: //p' "$wt/.git")"
  [[ -n "$gitdir" ]] || fail "worktree .git has no gitdir line: $(cat "$wt/.git")"

  # The gitdir lives under the metadata workspace we passed.
  [[ "$gitdir" == "$REPO/.git/"* ]] ||
    fail "gitdir '$gitdir' is not under the workspace '$REPO/.git'"

  # And commondir resolves back into that same workspace.
  local commondir
  commondir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  assert_equal "$commondir" "$REPO/.git"

  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:$REPO/.git"
}

# --- preconditions ----------------------------------------------------------

@test "a missing Sandbox Kit stops the run before anything is created" {
  rm -rf "$REPO/.sbx"

  task feature/new-crud
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] || fail "unexpected stderr: $stderr"

  run git -C "$REPO" show-ref --verify --quiet refs/heads/feature/new-crud
  assert_failure
  assert_file_not_exists "$TMP/my-app-worktrees"
  assert_equal "$(fake_sbx_call_count)" "0"
}

@test "a missing base branch stops the run before anything is created" {
  task feature/new-crud --base does-not-exist
  assert_failure
  [[ "$stderr" == *"does not exist locally or as origin/does-not-exist"* ]] ||
    fail "unexpected stderr: $stderr"

  assert_file_not_exists "$TMP/my-app-worktrees"
  assert_equal "$(fake_sbx_call_count)" "0"
}

@test "a sandbox creation failure is reported and not silently ignored" {
  run --separate-stderr env FAKE_SBX_EXIT=1 bash -c \
    "cd '$REPO' && '$TASK_AGENT' feature/new-crud"
  assert_failure
  [[ "$stderr" == *"Failed to create the sandbox"* ]] ||
    fail "unexpected stderr: $stderr"
}

# --- no persisted state beyond the kit cache --------------------------------

@test "no agent-cli session state is written anywhere" {
  task feature/new-crud
  assert_success

  assert_file_not_exists "$REPO/.agent"
  assert_file_not_exists "$REPO/.agent-cli"

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_not_exists "$wt/.agent"
  assert_file_not_exists "$wt/.agent-cli"
}

@test "the applied-kit cache is the only thing agent-cli persists" {
  task feature/new-crud
  assert_success

  # Everything under .git/agent-cli must be the kit cache and nothing else, so
  # that "no persisted session state" stays true apart from the one documented
  # exception (issue #7).
  run find "$REPO/.git/agent-cli" -mindepth 1 -maxdepth 1
  assert_success
  assert_equal "$output" "$REPO/.git/agent-cli/kit"
}

@test "the sandbox and worktree are still discovered with the cache deleted" {
  # The cache is a cache: removing it may cost a kit re-application, but must
  # not change what task-agent concludes exists.
  task feature/new-crud
  assert_success
  rm -rf "$REPO/.git/agent-cli"
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  [[ "$stderr" == *"Reusing existing branch"* ]] || fail "branch not reused: $stderr"
  [[ "$stderr" == *"Reusing sandbox"* ]] || fail "sandbox not reused: $stderr"
  assert_equal "$(grep -c '^arg:create$' "$FAKE_SBX_DIR/calls.log")" "0"
}
