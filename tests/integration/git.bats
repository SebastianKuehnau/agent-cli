#!/usr/bin/env bats
#
# Integration tests for lib/git.sh against real temporary repositories.
# Git is never mocked here. Remote behaviour uses local bare repos, so the suite
# needs no network and no GitHub.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/git.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null
}

# in_repo <args...> — run a lib function from inside the repo, in a subshell so
# `die`'s exit does not abort the test itself.
in_repo() {
  local dir="$1"
  shift
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/git.sh'
    cd '$dir' || exit 99
    $*
  "
}

# --- repository preconditions ----------------------------------------------

@test "git_require_repo fails outside a git repository" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  in_repo "$outside" 'git_require_repo'
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "git_require_repo succeeds inside a git repository" {
  in_repo "$REPO" 'git_require_repo'
  assert_success
}

# --- main repository resolution --------------------------------------------

@test "main repo root resolves from the repository root" {
  in_repo "$REPO" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$REPO"
}

@test "main repo root resolves from a subdirectory" {
  mkdir -p "$REPO/src/main/java"
  in_repo "$REPO/src/main/java" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$REPO"
}

@test "main repo root resolves from inside a linked worktree" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/wt" feature/x
  in_repo "$TMP/wt" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$REPO"
}

@test "main repo root resolves from a subdirectory of a linked worktree" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/wt" feature/x
  mkdir -p "$TMP/wt/deep/nested"
  in_repo "$TMP/wt/deep/nested" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$REPO"
}

@test "main repo root resolves when the repository path contains spaces" {
  local spacey="$TMP/my project with spaces"
  make_repo "$spacey" >/dev/null
  in_repo "$spacey" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$spacey"
}

@test "main repo root is a physical path when reached through a symlink" {
  # Git canonicalises paths, so everything agent-cli derives from
  # git_main_repo_root is physical too. That consistency is what makes the
  # worktree's .git pointer resolve inside a sandbox: the path we hand to sbx
  # must be the same path git recorded, not a symlinked alias of it.
  ln -s "$REPO" "$TMP/link-to-repo"

  in_repo "$TMP/link-to-repo" 'git_main_repo_root'
  assert_success
  assert_equal "$output" "$REPO"
}

@test "git metadata dir under a symlinked path is physical too" {
  ln -s "$REPO" "$TMP/link-to-repo"

  in_repo "$TMP/link-to-repo" 'git_git_metadata_dir "$(git_main_repo_root)"'
  assert_success
  assert_equal "$output" "$REPO/.git"
  [[ -d "$output" ]] || fail "metadata dir does not exist: $output"
}

@test "git metadata dir is the .git directory of a normal clone" {
  in_repo "$REPO" 'git_git_metadata_dir "$(git_main_repo_root)"'
  assert_success
  assert_equal "$output" "$REPO/.git"
}

# --- branch validation ------------------------------------------------------

@test "valid branch names are accepted" {
  local name
  for name in main develop feature/new-crud release/1.2.3 fix_123 a.b-c; do
    in_repo "$REPO" "git_validate_branch '$name'"
    assert_success
  done
}

@test "an empty branch name is rejected" {
  in_repo "$REPO" "git_validate_branch ''"
  assert_failure
  [[ "$stderr" == *"must not be empty"* ]] || fail "unexpected stderr: $stderr"
}

@test "branch names git itself rejects are rejected" {
  local name
  for name in 'feature//x' 'feature/x..y' 'has space' 'trailing.lock' 'tilde~1' 'caret^' 'colon:x' 'question?' 'star*' 'open[bracket'; do
    in_repo "$REPO" "git_validate_branch '$name'"
    assert_failure
    [[ "$stderr" == *"Invalid branch name"* ]] ||
      fail "expected rejection of '$name', stderr: $stderr"
  done
}

@test "a branch name starting with a hyphen is rejected" {
  in_repo "$REPO" "git_validate_branch '-oops'"
  assert_failure
  [[ "$stderr" == *"must not start with '-'"* ]] || fail "unexpected stderr: $stderr"
}

@test "git revision shorthand is rejected as a branch name" {
  in_repo "$REPO" 'git_validate_branch "@{-1}"'
  assert_failure
  [[ "$stderr" == *"revision shorthand"* ]] || fail "unexpected stderr: $stderr"
}

# --- branch detection -------------------------------------------------------

@test "local branch existence is detected" {
  git_quiet -C "$REPO" branch feature/x
  in_repo "$REPO" "git_local_branch_exists '$REPO' 'feature/x'"
  assert_success
  in_repo "$REPO" "git_local_branch_exists '$REPO' 'feature/nope'"
  assert_failure
}

@test "remote branch existence is detected" {
  make_bare_origin "$REPO" "$TMP/origin.git" >/dev/null
  git_quiet -C "$REPO" branch feature/remote-only
  git_quiet -C "$REPO" push --quiet origin feature/remote-only
  git_quiet -C "$REPO" branch -D feature/remote-only

  in_repo "$REPO" "git_remote_branch_exists '$REPO' 'feature/remote-only'"
  assert_success
  in_repo "$REPO" "git_remote_branch_exists '$REPO' 'feature/nope'"
  assert_failure
}

# --- base resolution --------------------------------------------------------

@test "base resolution prefers a local branch" {
  in_repo "$REPO" "git_resolve_base '$REPO' 'main'"
  assert_success
  assert_equal "$output" "main"
}

@test "base resolution falls back to origin/<base>" {
  make_bare_origin "$REPO" "$TMP/origin.git" >/dev/null
  git_quiet -C "$REPO" branch develop
  git_quiet -C "$REPO" push --quiet origin develop
  git_quiet -C "$REPO" branch -D develop

  in_repo "$REPO" "git_resolve_base '$REPO' 'develop'"
  assert_success
  assert_equal "$output" "origin/develop"
}

@test "a missing base branch fails instead of falling back to HEAD" {
  in_repo "$REPO" "git_resolve_base '$REPO' 'does-not-exist'"
  assert_failure
  [[ "$stderr" == *"does not exist locally or as origin/does-not-exist"* ]] ||
    fail "unexpected stderr: $stderr"
}

# --- branch creation --------------------------------------------------------

@test "a new branch is created from the default base" {
  add_commit "$REPO" second.txt "second"
  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/new-crud' 'main'"
  assert_success
  assert_equal "$output" "created"
  assert_equal \
    "$(git -C "$REPO" rev-parse feature/new-crud)" \
    "$(git -C "$REPO" rev-parse main)"
}

@test "a new branch is created from an explicit base" {
  git_quiet -C "$REPO" branch develop
  git_quiet -C "$REPO" switch --quiet develop
  add_commit "$REPO" only-on-develop.txt "develop"
  git_quiet -C "$REPO" switch --quiet main

  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/from-develop' 'develop'"
  assert_success
  assert_equal "$output" "created"
  assert_equal \
    "$(git -C "$REPO" rev-parse feature/from-develop)" \
    "$(git -C "$REPO" rev-parse develop)"
  # And it really carries develop's commit, not main's.
  run git -C "$REPO" cat-file -e feature/from-develop:only-on-develop.txt
  assert_success
}

@test "a new branch is created from the base, NOT the caller's current HEAD" {
  # This is the behaviour the predecessor got wrong: it branched off whatever
  # the user happened to have checked out.
  git_quiet -C "$REPO" switch --quiet -c experimental/foo
  add_commit "$REPO" only-on-experimental.txt "experimental"

  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/new-crud' 'main'"
  assert_success
  assert_equal "$output" "created"

  assert_equal \
    "$(git -C "$REPO" rev-parse feature/new-crud)" \
    "$(git -C "$REPO" rev-parse main)"
  assert_not_equal \
    "$(git -C "$REPO" rev-parse feature/new-crud)" \
    "$(git -C "$REPO" rev-parse experimental/foo)"

  run git -C "$REPO" cat-file -e feature/new-crud:only-on-experimental.txt
  assert_failure
}

@test "an existing local branch is reused and left untouched" {
  git_quiet -C "$REPO" branch feature/x
  local before
  before="$(git -C "$REPO" rev-parse feature/x)"

  # Move main forward so a merge/rebase/reset would be visible.
  add_commit "$REPO" moved-on.txt "main moved on"

  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/x' 'main'"
  assert_success
  assert_equal "$output" "existing"
  assert_equal "$(git -C "$REPO" rev-parse feature/x)" "$before"
}

@test "an existing origin branch becomes a local tracking branch" {
  make_bare_origin "$REPO" "$TMP/origin.git" >/dev/null
  git_quiet -C "$REPO" branch feature/remote-only
  add_commit "$REPO" ignored.txt "x"
  git_quiet -C "$REPO" push --quiet origin feature/remote-only
  git_quiet -C "$REPO" branch -D feature/remote-only

  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/remote-only' 'main'"
  assert_success
  assert_equal "$output" "tracking"

  assert_equal \
    "$(git -C "$REPO" rev-parse feature/remote-only)" \
    "$(git -C "$REPO" rev-parse origin/feature/remote-only)"
  assert_equal \
    "$(git -C "$REPO" rev-parse --abbrev-ref 'feature/remote-only@{upstream}')" \
    "origin/feature/remote-only"
}

@test "creating a branch fails cleanly when the base is missing" {
  in_repo "$REPO" "git_ensure_branch '$REPO' 'feature/x' 'nonexistent-base'"
  assert_failure
  in_repo "$REPO" "git_local_branch_exists '$REPO' 'feature/x'"
  assert_failure
}

@test "branches containing slashes are created correctly" {
  in_repo "$REPO" "git_ensure_branch '$REPO' 'release/1.2/hotfix' 'main'"
  assert_success
  in_repo "$REPO" "git_local_branch_exists '$REPO' 'release/1.2/hotfix'"
  assert_success
}

@test "branch operations work when the repository path contains spaces" {
  local spacey="$TMP/my project with spaces"
  make_repo "$spacey" >/dev/null
  in_repo "$spacey" "git_ensure_branch '$spacey' 'feature/new-crud' 'main'"
  assert_success
  assert_equal "$output" "created"
  in_repo "$spacey" "git_local_branch_exists '$spacey' 'feature/new-crud'"
  assert_success
}
