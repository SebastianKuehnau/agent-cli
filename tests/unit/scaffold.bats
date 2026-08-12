#!/usr/bin/env bats
#
# Tests for `agent-task --init`.
#
# The download URL is redirected to a local file:// URL, which curl handles
# natively, so these tests need no network and never touch GitHub. A separate
# opt-in test at the bottom exercises the real URL.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  FIXTURE="$TMP/spec.yaml"
  cat >"$FIXTURE" <<'EOF'
schemaVersion: "2"
kind: mixin
name: my-project
EOF
}

# init_in <dir> — run `agent-task --init` from <dir> with the fixture URL.
init_in() {
  run --separate-stderr env \
    AGENT_TASK_KIT_URL="file://$FIXTURE" \
    bash -c "cd '$1' && '$AGENT_TASK' --init"
}

# init_with_url <dir> <url>
init_with_url() {
  run --separate-stderr env \
    AGENT_TASK_KIT_URL="$2" \
    bash -c "cd '$1' && '$AGENT_TASK' --init"
}

# --- happy path -------------------------------------------------------------

@test "a fresh project gets .sbx/kit/spec.yaml" {
  init_in "$REPO"
  assert_success
  assert_file_exists "$REPO/.sbx/kit/spec.yaml"
}

@test "the downloaded content lands byte-for-byte at the exact target" {
  init_in "$REPO"
  assert_success
  run diff "$FIXTURE" "$REPO/.sbx/kit/spec.yaml"
  assert_success
}

@test "missing .sbx and .sbx/kit directories are created" {
  assert_file_not_exists "$REPO/.sbx"
  init_in "$REPO"
  assert_success
  [[ -d "$REPO/.sbx/kit" ]] || fail ".sbx/kit was not created"
}

@test "--init works from a subdirectory and writes to the main repo root" {
  mkdir -p "$REPO/src/main/java"
  init_in "$REPO/src/main/java"
  assert_success
  assert_file_exists "$REPO/.sbx/kit/spec.yaml"
  assert_file_not_exists "$REPO/src/main/java/.sbx"
}

@test "--init from a linked worktree writes to the main repository" {
  git_quiet -C "$REPO" branch feature/x
  git_quiet -C "$REPO" worktree add --quiet "$TMP/wt" feature/x

  init_in "$TMP/wt"
  assert_success
  assert_file_exists "$REPO/.sbx/kit/spec.yaml"
  assert_file_not_exists "$TMP/wt/.sbx/kit/spec.yaml"
}

@test "--init works when the repository path contains spaces" {
  local spacey="$TMP/my project with spaces"
  make_repo "$spacey" >/dev/null
  init_in "$spacey"
  assert_success
  assert_file_exists "$spacey/.sbx/kit/spec.yaml"
}

@test "--init leaves no temporary files behind" {
  init_in "$REPO"
  assert_success
  local leftovers
  leftovers="$(find "$REPO/.sbx/kit" -name '.spec.yaml.*' | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

# --- scope: --init touches nothing else -------------------------------------

@test "--init does not modify .gitignore, stage, or commit" {
  local head_before
  head_before="$(git -C "$REPO" rev-parse HEAD)"

  init_in "$REPO"
  assert_success

  assert_file_not_exists "$REPO/.gitignore"
  assert_equal "$(git -C "$REPO" rev-parse HEAD)" "$head_before"

  # Nothing staged: the new file is untracked, not in the index.
  run git -C "$REPO" diff --cached --name-only
  assert_success
  assert_equal "$output" ""

  # And the only change in the tree is the kit itself. core.excludesFile is
  # neutralised so the assertion does not depend on the developer's global
  # gitignore (which may well list .sbx).
  run git -C "$REPO" -c core.excludesFile=/dev/null status --porcelain
  assert_success
  assert_equal "$output" "?? .sbx/"
}

@test "--init creates no Claude config, task directories or extra files" {
  init_in "$REPO"
  assert_success

  assert_file_not_exists "$REPO/.claude"
  assert_file_not_exists "$REPO/CLAUDE.md"
  assert_file_not_exists "$REPO/tasks"
  assert_file_not_exists "$REPO/.mcp.json"
  assert_file_not_exists "$REPO/.devcontainer"

  # .sbx contains exactly one file.
  local count
  count="$(find "$REPO/.sbx" -type f | wc -l | tr -d ' ')"
  assert_equal "$count" "1"
}

# --- refusal ----------------------------------------------------------------

@test "an existing spec.yaml is refused and never overwritten" {
  mkdir -p "$REPO/.sbx/kit"
  printf 'my own edits\n' >"$REPO/.sbx/kit/spec.yaml"

  init_in "$REPO"
  assert_failure
  [[ "$stderr" == *"already exists at .sbx/kit/spec.yaml"* ]] ||
    fail "unexpected stderr: $stderr"
  assert_equal "$(cat "$REPO/.sbx/kit/spec.yaml")" "my own edits"
}

@test "--init outside a git repository fails" {
  local outside="$TMP/not-a-repo"
  mkdir -p "$outside"
  init_in "$outside"
  assert_failure
  [[ "$stderr" == *"Not inside a git repository"* ]] ||
    fail "unexpected stderr: $stderr"
}

# --- atomicity --------------------------------------------------------------

@test "a failed download leaves no spec.yaml behind" {
  init_with_url "$REPO" "file://$TMP/does-not-exist.yaml"
  assert_failure
  assert_file_not_exists "$REPO/.sbx/kit/spec.yaml"
  [[ "$stderr" == *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
}

@test "a failed download leaves no temporary file behind" {
  init_with_url "$REPO" "file://$TMP/does-not-exist.yaml"
  assert_failure
  local leftovers
  leftovers="$(find "$REPO/.sbx/kit" -name '.spec.yaml.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

@test "an empty download leaves no spec.yaml behind" {
  : >"$TMP/empty.yaml"
  init_with_url "$REPO" "file://$TMP/empty.yaml"
  assert_failure
  assert_file_not_exists "$REPO/.sbx/kit/spec.yaml"
  [[ "$stderr" == *"empty"* ]] || fail "unexpected stderr: $stderr"
}

@test "a failed download does not clobber an unrelated pre-existing kit dir" {
  mkdir -p "$REPO/.sbx/kit"
  printf 'notes\n' >"$REPO/.sbx/kit/README.md"

  init_with_url "$REPO" "file://$TMP/does-not-exist.yaml"
  assert_failure
  assert_file_exists "$REPO/.sbx/kit/README.md"
}

# --- scaffold_require_kit ---------------------------------------------------

@test "scaffold_require_kit fails with an actionable message when the kit is missing" {
  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/scaffold.sh'
    scaffold_require_kit '$REPO'
  "
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found at .sbx/kit/spec.yaml"* ]] ||
    fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"agent-task --init"* ]] ||
    fail "error message lacks the --init hint: $stderr"
}

@test "scaffold_require_kit succeeds once the kit exists" {
  init_in "$REPO"
  assert_success
  run bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/scaffold.sh'
    scaffold_require_kit '$REPO'
  "
  assert_success
}

# --- optional network test --------------------------------------------------

@test "the real kit URL is reachable and non-empty (AGENT_TASK_NETWORK_TESTS=1)" {
  [[ -n "${AGENT_TASK_NETWORK_TESTS:-}" ]] ||
    skip "set AGENT_TASK_NETWORK_TESTS=1 to test against the real URL"

  run --separate-stderr bash -c "cd '$REPO' && '$AGENT_TASK' --init"
  assert_success
  assert_file_exists "$REPO/.sbx/kit/spec.yaml"
  [[ -s "$REPO/.sbx/kit/spec.yaml" ]] || fail "downloaded spec.yaml is empty"
  grep -q 'schemaVersion' "$REPO/.sbx/kit/spec.yaml" ||
    fail "downloaded spec.yaml does not look like a kit spec"
}
