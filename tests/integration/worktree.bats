#!/usr/bin/env bats
#
# Integration tests for lib/worktree.sh against real temporary repositories.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/naming.sh"
  source "$AGENT_LIB/worktree.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null
}

# wt <code...> — run worktree code in a subshell so `die` cannot abort the test.
wt() {
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/naming.sh'
    source '$AGENT_LIB/worktree.sh'
    $*
  "
}

# --- path derivation --------------------------------------------------------

@test "worktree root is a sibling directory of the main repository" {
  assert_equal "$(worktree_root "$REPO")" "$TMP/my-app-worktrees"
}

@test "worktree root ignores a trailing slash" {
  assert_equal "$(worktree_root "$REPO/")" "$TMP/my-app-worktrees"
}

@test "worktree path is <root>/<slug>-<hash>" {
  local path
  path="$(worktree_path "$REPO" 'feature/new-crud')"
  [[ "$path" =~ ^"$TMP/my-app-worktrees/feature-new-crud-"[0-9a-f]{6}$ ]] ||
    fail "unexpected path: $path"
}

@test "worktree path is deterministic" {
  assert_equal "$(worktree_path "$REPO" 'feature/new-crud')" \
    "$(worktree_path "$REPO" 'feature/new-crud')"
}

@test "a branch containing slashes does not nest directories" {
  local path root
  path="$(worktree_path "$REPO" 'release/1.2/hotfix')"
  root="$(worktree_root "$REPO")"
  [[ "${path#"$root"/}" != */* ]] || fail "path nests below the root: $path"
}

@test "colliding branch slugs get distinct worktree paths" {
  assert_not_equal \
    "$(worktree_path "$REPO" 'feature/foo')" \
    "$(worktree_path "$REPO" 'feature-foo')"
}

# --- lookup -----------------------------------------------------------------

@test "an unregistered branch has no worktree" {
  wt "worktree_find_for_branch '$REPO' 'feature/nope'"
  assert_failure
  assert_equal "$output" ""
}

@test "a registered worktree is found by branch" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/somewhere-else" feature/x

  wt "worktree_find_for_branch '$REPO' 'feature/x'"
  assert_success
  assert_equal "$output" "$TMP/somewhere-else"
}

@test "a registered worktree whose path contains spaces is found" {
  # The predecessor split `git worktree list --porcelain` on whitespace and
  # reported any such worktree as missing.
  local spacey="$TMP/work trees/with spaces"
  mkdir -p "$TMP/work trees"
  git_quiet -C "$REPO" branch feature/spacey
  git_quiet -C "$REPO" worktree add --quiet "$spacey" feature/spacey

  wt "worktree_find_for_branch '$REPO' 'feature/spacey'"
  assert_success
  assert_equal "$output" "$spacey"
}

@test "the main worktree's own branch is reported" {
  wt "worktree_find_for_branch '$REPO' 'main'"
  assert_success
  assert_equal "$output" "$REPO"
}

@test "the branch registered at a path is reported" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/wt" feature/x

  wt "worktree_branch_at_path '$REPO' '$TMP/wt'"
  assert_success
  assert_equal "$output" "refs/heads/feature/x"
}

@test "a detached worktree is reported as detached" {
  git_quiet -C "$REPO" worktree add --quiet --detach "$TMP/wt-detached" HEAD

  wt "worktree_branch_at_path '$REPO' '$TMP/wt-detached'"
  assert_success
  assert_equal "$output" "detached"
}

# --- creation and reuse -----------------------------------------------------

@test "a worktree is created at the derived path" {
  git_quiet -C "$REPO" branch feature/new-crud

  wt "worktree_ensure '$REPO' 'feature/new-crud'"
  assert_success
  assert_equal "$output" "$(worktree_path "$REPO" 'feature/new-crud')"
  [[ -d "$output" ]] || fail "worktree directory was not created: $output"
  [[ -e "$output/.git" ]] || fail "worktree has no .git: $output"
}

@test "the created worktree has the requested branch checked out" {
  git_quiet -C "$REPO" branch feature/new-crud
  wt "worktree_ensure '$REPO' 'feature/new-crud'"
  assert_success

  run git -C "$output" branch --show-current
  assert_success
  assert_equal "$output" "feature/new-crud"
}

@test "the worktree parent directory is created if missing" {
  git_quiet -C "$REPO" branch feature/x
  assert_file_not_exists "$TMP/my-app-worktrees"

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  [[ -d "$TMP/my-app-worktrees" ]] || fail "worktree root was not created"
}

@test "an existing worktree is reused, not duplicated" {
  git_quiet -C "$REPO" branch feature/x

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  local first="$output"

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  assert_equal "$output" "$first"

  local count
  count="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
  assert_equal "$count" "2" # the main checkout plus exactly one linked worktree
}

@test "git's registered worktree wins over the derived path" {
  # A worktree created by hand somewhere else must be reused rather than a
  # second one being added for the same branch.
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/hand-made" feature/x

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  assert_equal "$output" "$TMP/hand-made"
  assert_not_equal "$output" "$(worktree_path "$REPO" 'feature/x')"

  local count
  count="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
  assert_equal "$count" "2"
}

@test "a branch checked out in another worktree is reused rather than failing" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/elsewhere" feature/x

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  assert_equal "$output" "$TMP/elsewhere"
}

@test "the derived path being occupied by another branch fails clearly" {
  git_quiet -C "$REPO" branch feature/a
  git_quiet -C "$REPO" branch feature/b

  # Register feature/b at exactly the path feature/a would derive.
  local target
  target="$(worktree_path "$REPO" 'feature/a')"
  mkdir -p "$(dirname "$target")"
  git_quiet -C "$REPO" worktree add --quiet "$target" feature/b

  wt "worktree_ensure '$REPO' 'feature/a'"
  assert_failure
  [[ "$stderr" == *"already registered to a different branch"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "the derived path existing as a plain directory fails clearly" {
  git_quiet -C "$REPO" branch feature/x
  local target
  target="$(worktree_path "$REPO" 'feature/x')"
  mkdir -p "$target"
  printf 'in the way\n' >"$target/stray.txt"

  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_failure
  [[ "$stderr" == *"not a registered git worktree"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "worktrees work when the repository path contains spaces" {
  local spacey="$TMP/my project with spaces"
  make_repo "$spacey" >/dev/null
  git_quiet -C "$spacey" branch feature/new-crud

  wt "worktree_ensure '$spacey' 'feature/new-crud'"
  assert_success
  [[ "$output" == "$TMP/my project with spaces-worktrees/"* ]] ||
    fail "unexpected worktree path: $output"
  [[ -d "$output" ]] || fail "worktree directory was not created: $output"

  # And it is found again on a second call rather than being recreated.
  local first="$output"
  wt "worktree_ensure '$spacey' 'feature/new-crud'"
  assert_success
  assert_equal "$output" "$first"
}

@test "a linked worktree can run git commands against the main repository" {
  # The core architectural assumption, verified on the host: a linked worktree's
  # .git file resolves back into the main repository's metadata.
  git_quiet -C "$REPO" branch feature/x
  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  local path="$output"

  run git -C "$path" status --porcelain
  assert_success

  run git -C "$path" branch --show-current
  assert_success
  assert_equal "$output" "feature/x"
}

@test "a commit made in the worktree is visible from the main repository" {
  git_quiet -C "$REPO" branch feature/x
  wt "worktree_ensure '$REPO' 'feature/x'"
  assert_success
  local path="$output"

  add_commit "$path" from-worktree.txt "written in the worktree"

  run git -C "$REPO" cat-file -e feature/x:from-worktree.txt
  assert_success
}
