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
#
# Applying a changed kit means recreating the sandbox: `sbx kit add` cannot
# express "this kit changed" (see tests/spike/sandbox-kit.bats). Because that is
# destructive to container-only state, the default is to ask — and the suite
# neutralises stdin (tests/helpers/common.bash), so the default here is "do not
# touch it", which is exactly the non-interactive behaviour being asserted below.
# That neutralisation is what these tests rely on, not anything bats does by
# itself: bats passes on the terminal it was started from, and without it the
# tests below would sit at the prompt forever (issue #14).

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

# sbx_subcommands — the sbx subcommands invoked, in order, one per line.
sbx_subcommands() {
  grep -E '^arg:(create|rm|run|ls|kit)$' "$FAKE_SBX_DIR/calls.log" || true
}

@test "creating a sandbox records the kit it was created from" {
  task feature/new-crud
  assert_success
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"
}

@test "an unchanged kit leaves the sandbox alone on reuse" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"
}

@test "a changed kit is never applied behind sbx kit add" {
  # The command it used to call cannot re-apply a kit of the same name, so it
  # must not be called at all.
  task feature/new-crud
  assert_success
  change_kit
  task feature/new-crud
  assert_success
  assert_equal "$(fake_sbx_kit_call_count)" "0"
}

@test "a changed kit with no terminal to ask at is reported, not applied" {
  task feature/new-crud
  assert_success
  local before
  before="$(recorded_digest "$(expected_sandbox feature/new-crud)")"
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  task feature/new-crud
  assert_success

  [[ "$stderr" == *"Sandbox Kit changed"* ]] || fail "change not reported: $stderr"
  [[ "$stderr" == *"stdin is not a terminal"* ]] || fail "reason not given: $stderr"
  [[ "$stderr" == *"TASK_AGENT_KIT_RECREATE=yes"* ]] || fail "no way out offered: $stderr"

  # Nothing was rebuilt, and the agent still started.
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$before"
}

@test "the destructive part is spelled out before anything happens" {
  task feature/new-crud
  assert_success
  change_kit
  task feature/new-crud
  assert_success
  [[ "$stderr" == *"only inside the container is lost"* ]] ||
    fail "consequence not stated: $stderr"
  [[ "$stderr" == *"session state"* ]] ||
    fail "the loss that actually bites is not named: $stderr"
  [[ "$stderr" == *"not affected"* ]] || fail "worktree safety not stated: $stderr"
}

@test "TASK_AGENT_KIT_RECREATE=yes recreates the sandbox from the changed kit" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success

  # Removed, recreated, then attached to — in that order.
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:rm
arg:create
arg:run"
  [[ "$stderr" == *"Recreated"* ]] || fail "recreation not reported: $stderr"
}

@test "the recreated sandbox keeps its name, kit, worktree and git metadata dir" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:--name"
  assert_output_contains "arg:$(expected_sandbox feature/new-crud)"
  assert_output_contains "arg:--kit"
  assert_output_contains "arg:$REPO/.sbx/kit"
  assert_output_contains "arg:$wt"
  assert_output_contains "arg:$REPO/.git"

  # And exactly one sandbox of that name is left registered.
  assert_equal "$(grep -cx "$(expected_sandbox feature/new-crud)" "$FAKE_SBX_DIR/sandboxes")" "1"
}

@test "recreating records the new digest, so the next run does nothing" {
  task feature/new-crud
  assert_success
  change_kit
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/new-crud
  assert_success
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"

  : >"$FAKE_SBX_DIR/calls.log"
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"
}

@test "a kit change that was skipped is offered again on the next run" {
  # Not recording the digest on the skip path is what makes this work.
  task feature/new-crud
  assert_success
  change_kit
  task feature/new-crud
  assert_success

  : >"$FAKE_SBX_DIR/calls.log"
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:rm
arg:create
arg:run"
}

@test "TASK_AGENT_KIT_RECREATE=no keeps the sandbox and says why" {
  task feature/new-crud
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  change_kit
  export TASK_AGENT_KIT_RECREATE=no
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success

  [[ "$stderr" == *"TASK_AGENT_KIT_RECREATE=no"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"--done"* ]] || fail "no manual route offered: $stderr"
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"
}

@test "an invalid TASK_AGENT_KIT_RECREATE fails instead of guessing" {
  # Guessing "no" for a typo would silently stop applying kit changes.
  task feature/new-crud
  assert_success

  change_kit
  export TASK_AGENT_KIT_RECREATE=maybe
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_failure
  [[ "$stderr" == *"Invalid TASK_AGENT_KIT_RECREATE"* ]] || fail "unexpected stderr: $stderr"
}

@test "a sandbox whose kit was never tracked is adopted, not rebuilt" {
  # The state a sandbox from an older task-agent is in. Destroying it unasked
  # would be a nasty surprise on upgrade.
  task feature/new-crud
  assert_success
  rm -rf "$REPO/.git/agent-cli"
  : >"$FAKE_SBX_DIR/calls.log"

  task feature/new-crud
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"
  [[ "$stderr" == *"not tracked yet"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(recorded_digest "$(expected_sandbox feature/new-crud)")" "$(kit_digest)"
}

@test "an adopted sandbox picks up the next kit change normally" {
  task feature/new-crud
  assert_success
  rm -rf "$REPO/.git/agent-cli"
  task feature/new-crud
  assert_success

  change_kit
  : >"$FAKE_SBX_DIR/calls.log"
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/new-crud
  unset TASK_AGENT_KIT_RECREATE
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:rm
arg:create
arg:run"
}

@test "each sandbox tracks its own kit" {
  task feature/one
  assert_success
  change_kit
  task feature/two
  assert_success

  # feature/two was created from the changed kit; feature/one predates it.
  : >"$FAKE_SBX_DIR/calls.log"
  export TASK_AGENT_KIT_RECREATE=yes
  task feature/two
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:run"

  : >"$FAKE_SBX_DIR/calls.log"
  task feature/one
  unset TASK_AGENT_KIT_RECREATE
  assert_success
  assert_equal "$(sbx_subcommands)" "arg:ls
arg:rm
arg:create
arg:run"
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
