#!/usr/bin/env bats
#
# THE ARCHITECTURAL SPIKE.
#
# Everything in agent-cli rests on one assumption: a *linked* git worktree keeps
# working inside a Docker Sandbox. A linked worktree's `.git` is a file holding
# an absolute path into the main repository's metadata, and that metadata
# directory's `commondir` points back again — neither target lives under the
# worktree itself.
#
# Docker Sandboxes should make this work without any rewriting, because
# `sbx create` documents that every workspace "will be mounted inside the sandbox
# at the same path as on the host". This file proves it, or proves it does not.
#
# Two variants are tested, because it is not obvious that sbx will accept a bare
# `.git` directory as a workspace:
#
#   variant A: workspaces = <worktree> <main-repo>/.git   (preferred: the main
#              checkout stays invisible to the agent)
#   variant B: workspaces = <worktree> <main-repo>        (fallback)
#
# lib/sandbox.sh currently implements variant A. If A fails and B passes, the
# single call site to change is `session_start`'s `git_git_metadata_dir` argument.
#
# These tests are skipped automatically when sbx is unavailable, so the normal
# suite stays runnable everywhere. Run them explicitly with:
#
#   bats tests/spike/sandbox-worktree.bats
#
# They create real sandboxes and remove them again in teardown.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  if ! command -v sbx >/dev/null 2>&1; then
    skip "sbx is not installed — Docker Sandboxes required for the spike"
  fi
  if ! sbx ls >/dev/null 2>&1; then
    skip "sbx is installed but not usable (is the Docker Sandboxes daemon running?)"
  fi

  # make_tmpdir canonicalises with `pwd -P`. That is essential here, not
  # cosmetic: on macOS mktemp hands back /var/folders/... while git records
  # /private/var/folders/... in the worktree's .git pointer. Mounting the
  # symlinked alias makes the sandbox resolve a path that does not exist inside
  # it, and git fails with "not a git repository".
  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-app"
  make_repo "$REPO" >/dev/null

  # A minimal kit. `shell` is used as the agent rather than `claude` so the spike
  # needs no agent authentication and no agent-specific image.
  mkdir -p "$REPO/.sbx/kit"
  cat >"$REPO/.sbx/kit/spec.yaml" <<'EOF'
schemaVersion: "2"
kind: mixin
name: agent-cli-spike
displayName: agent-cli worktree spike
description: Minimal kit used only to verify linked-worktree behaviour.
EOF

  BRANCH="feature/spike-check"
  git_quiet -C "$REPO" branch "$BRANCH"

  WORKTREE="$TMP/spike-app-worktrees/feature-spike-check"
  mkdir -p "$(dirname "$WORKTREE")"
  git_quiet -C "$REPO" worktree add --quiet "$WORKTREE" "$BRANCH"

  # Sanity checks on the host before blaming the sandbox for anything.
  run git -C "$WORKTREE" branch --show-current
  assert_success
  assert_equal "$output" "$BRANCH"

  # The worktree's .git pointer must name a path under the metadata directory
  # we are about to mount. If this fails, the spike itself is set up wrongly.
  local gitdir
  gitdir="$(sed -n 's/^gitdir: //p' "$WORKTREE/.git")"
  [[ "$gitdir" == "$REPO/.git/"* ]] ||
    fail "fixture is not canonical: gitdir '$gitdir' is not under '$REPO/.git'"

  SANDBOX=""
}

teardown() {
  spike_rm "${SANDBOX:-}"
}

# spike_rm <name> — remove a sandbox if it exists, ignoring failures.
spike_rm() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  command -v sbx >/dev/null 2>&1 || return 0
  sbx rm --force "$name" >/dev/null 2>&1 ||
    sbx rm "$name" >/dev/null 2>&1 ||
    true
}

# spike_create <name> <workspace...> — create a sandbox running the `shell`
# agent over the given workspaces.
#
# Any sandbox left over from an interrupted earlier run is removed first: sbx
# refuses to create a sandbox whose name already exists, and a stale one would
# otherwise fail the run for a reason that has nothing to do with worktrees.
spike_create() {
  local name="$1"
  shift
  spike_rm "$name"
  SANDBOX="$name"
  sbx create --kit "$REPO/.sbx/kit" --name "$name" shell "$@"
}

# in_sandbox <command...> — run a command inside the sandbox, in the worktree.
in_sandbox() {
  sbx exec -w "$WORKTREE" "$SANDBOX" "$@"
}

# ---------------------------------------------------------------------------
# Variant A — worktree plus the main repository's .git directory (preferred)
# ---------------------------------------------------------------------------

@test "variant A: sbx accepts the main repo .git directory as a workspace" {
  # SANDBOX is set here rather than relying on spike_create, because bats' `run`
  # executes in a subshell and the assignment would not reach teardown.
  SANDBOX="agent-cli-spike-a-create"
  run spike_create "$SANDBOX" "$WORKTREE" "$REPO/.git"
  assert_success
}

@test "variant A: the worktree is visible inside the sandbox at its host path" {
  spike_create "agent-cli-spike-a-visible" "$WORKTREE" "$REPO/.git"

  run in_sandbox test -f "$WORKTREE/README.md"
  assert_success

  run in_sandbox test -e "$WORKTREE/.git"
  assert_success
}

@test "variant A: the main repo git metadata is visible at its host path" {
  spike_create "agent-cli-spike-a-metadata" "$WORKTREE" "$REPO/.git"

  run in_sandbox test -d "$REPO/.git"
  assert_success
}

@test "variant A: git status succeeds inside the sandbox" {
  spike_create "agent-cli-spike-a-status" "$WORKTREE" "$REPO/.git"

  run in_sandbox git status --porcelain
  assert_success
}

@test "variant A: git reports the correct feature branch inside the sandbox" {
  spike_create "agent-cli-spike-a-branch" "$WORKTREE" "$REPO/.git"

  run in_sandbox git branch --show-current
  assert_success
  assert_equal "${output//$'\r'/}" "$BRANCH"
}

@test "variant A: a file changed inside the sandbox is immediately visible on the host" {
  spike_create "agent-cli-spike-a-edit" "$WORKTREE" "$REPO/.git"

  run in_sandbox sh -c "printf 'edited in sandbox\n' > '$WORKTREE/from-sandbox.txt'"
  assert_success

  assert_file_exists "$WORKTREE/from-sandbox.txt"
  assert_equal "$(cat "$WORKTREE/from-sandbox.txt")" "edited in sandbox"

  # And the host's git sees it as a change on the feature branch.
  run git -C "$WORKTREE" status --porcelain
  assert_success
  assert_output_contains "from-sandbox.txt"
}

@test "variant A: a commit made inside the sandbox is visible from the host repository" {
  spike_create "agent-cli-spike-a-commit" "$WORKTREE" "$REPO/.git"

  run in_sandbox sh -c "
    cd '$WORKTREE' &&
    printf 'committed in sandbox\n' > committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' add committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' commit -q -m 'commit from inside the sandbox'
  "
  assert_success

  # Visible from the host, in the worktree ...
  run git -C "$WORKTREE" log -1 --pretty=%s
  assert_success
  assert_equal "$output" "commit from inside the sandbox"

  # ... and from the main repository, on the feature branch.
  run git -C "$REPO" log -1 --pretty=%s "$BRANCH"
  assert_success
  assert_equal "$output" "commit from inside the sandbox"

  run git -C "$REPO" cat-file -e "$BRANCH:committed.txt"
  assert_success
}

@test "variant A: the main checkout is NOT writable from inside the sandbox" {
  # The point of mounting only .git rather than the whole repository.
  spike_create "agent-cli-spike-a-isolation" "$WORKTREE" "$REPO/.git"

  run in_sandbox test -f "$REPO/README.md"
  assert_failure
}

# ---------------------------------------------------------------------------
# Variant B — worktree plus the whole main repository (fallback)
# ---------------------------------------------------------------------------

@test "variant B: git status and branch work with the whole main repo mounted" {
  spike_create "agent-cli-spike-b-status" "$WORKTREE" "$REPO"

  run in_sandbox git status --porcelain
  assert_success

  run in_sandbox git branch --show-current
  assert_success
  assert_equal "${output//$'\r'/}" "$BRANCH"
}

@test "variant B: a commit made inside the sandbox is visible from the host repository" {
  spike_create "agent-cli-spike-b-commit" "$WORKTREE" "$REPO"

  run in_sandbox sh -c "
    cd '$WORKTREE' &&
    printf 'committed in sandbox\n' > committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' add committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' commit -q -m 'commit from inside the sandbox'
  "
  assert_success

  run git -C "$REPO" log -1 --pretty=%s "$BRANCH"
  assert_success
  assert_equal "$output" "commit from inside the sandbox"
}
