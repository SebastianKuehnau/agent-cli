#!/usr/bin/env bats
#
# Tests for `task-agent --init`.
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

# init_in <dir> — run `task-agent --init` from <dir> with the fixture URL.
init_in() {
  run --separate-stderr env \
    TASK_AGENT_KIT_URL="file://$FIXTURE" \
    bash -c "cd '$1' && '$TASK_AGENT' --init"
}

# init_with_url <dir> <url>
init_with_url() {
  run --separate-stderr env \
    TASK_AGENT_KIT_URL="$2" \
    bash -c "cd '$1' && '$TASK_AGENT' --init"
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
  [[ "$stderr" == *"task-agent --init"* ]] ||
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

# --- presets ----------------------------------------------------------------
#
# TASK_AGENT_PRESET_BASE_URL is redirected at a local directory laid out the way
# the publishing repository is, so preset *resolution* is exercised without
# network. TASK_AGENT_KIT_URL must be unset for these: it deliberately wins over
# any preset.

# make_preset_base — build a local stand-in for the preset publishing repo.
#
# The `generic` stand-in deliberately carries no __PROJECT__ sentinel, so the
# byte-for-byte assertion below tests something: a spec that does not opt in is
# copied untouched. The shipped presets both use the sentinel, which is asserted
# separately at the bottom of this file.
make_preset_base() {
  BASE="$TMP/preset-base"
  mkdir -p "$BASE/presets/generic" "$BASE/presets/vaadin"
  printf 'schemaVersion: "2"\nkind: mixin\nname: generic-marker\n' \
    >"$BASE/presets/generic/spec.yaml"
  printf 'schemaVersion: "2"\nkind: mixin\nname: __PROJECT__\ndisplayName: __PROJECT__ env\n' \
    >"$BASE/presets/vaadin/spec.yaml"
}

# init_preset <dir> [preset...] — run --init against the local preset base.
init_preset() {
  local dir="$1"
  shift
  run --separate-stderr env \
    -u TASK_AGENT_KIT_URL \
    TASK_AGENT_PRESET_BASE_URL="file://$BASE" \
    bash -c "cd '$dir' && '$TASK_AGENT' --init $*"
}

@test "--init with no preset resolves the generic preset" {
  make_preset_base
  init_preset "$REPO"
  assert_success
  grep -q 'name: generic-marker' "$REPO/.sbx/kit/spec.yaml" ||
    fail "did not get the generic preset: $(cat "$REPO/.sbx/kit/spec.yaml")"
  [[ "$stderr" == *"'generic' preset"* ]] || fail "unexpected stderr: $stderr"
}

@test "--init vaadin resolves the vaadin preset" {
  make_preset_base
  init_preset "$REPO" vaadin
  assert_success
  grep -q 'displayName: my-app env' "$REPO/.sbx/kit/spec.yaml" ||
    fail "did not get the vaadin preset: $(cat "$REPO/.sbx/kit/spec.yaml")"
  [[ "$stderr" == *"'vaadin' preset"* ]] || fail "unexpected stderr: $stderr"
}

@test "an unknown preset fails, names the known ones, and creates nothing" {
  make_preset_base
  init_preset "$REPO" nosuchpreset
  assert_failure
  [[ "$stderr" == *"Unknown preset: nosuchpreset"* ]] ||
    fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"generic"* && "$stderr" == *"vaadin"* ]] ||
    fail "error does not list the available presets: $stderr"
  assert_file_not_exists "$REPO/.sbx/kit/spec.yaml"
}

@test "an unknown preset creates no .sbx directory at all" {
  # An unknown preset is an argument error, so it must be caught before the
  # project is touched — not leave an empty .sbx/kit behind.
  make_preset_base
  init_preset "$REPO" nosuchpreset
  assert_failure
  assert_file_not_exists "$REPO/.sbx"
}

@test "an unknown preset leaves an already-present kit directory untouched" {
  make_preset_base
  mkdir -p "$REPO/.sbx/kit"
  printf 'notes\n' >"$REPO/.sbx/kit/README.md"

  init_preset "$REPO" nosuchpreset
  assert_failure
  assert_file_exists "$REPO/.sbx/kit/README.md"
  local leftovers
  leftovers="$(find "$REPO/.sbx/kit" -name '.spec.yaml.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

# --- the __PROJECT__ placeholder --------------------------------------------

@test "__PROJECT__ is replaced with the project directory name" {
  make_preset_base
  init_preset "$REPO" vaadin
  assert_success
  grep -q '^name: my-app$' "$REPO/.sbx/kit/spec.yaml" ||
    fail "placeholder not substituted: $(cat "$REPO/.sbx/kit/spec.yaml")"
  ! grep -q '__PROJECT__' "$REPO/.sbx/kit/spec.yaml" ||
    fail "placeholder survived: $(cat "$REPO/.sbx/kit/spec.yaml")"
}

@test "every __PROJECT__ occurrence is replaced, not just the first" {
  make_preset_base
  init_preset "$REPO" vaadin
  assert_success
  local count
  count="$(grep -c 'my-app' "$REPO/.sbx/kit/spec.yaml")"
  assert_equal "$count" "2"
}

@test "a project name needing slugification is slugified" {
  make_preset_base
  local spacey="$TMP/My Vaadin App"
  make_repo "$spacey" >/dev/null
  init_preset "$spacey" vaadin
  assert_success
  grep -q '^name: my-vaadin-app$' "$spacey/.sbx/kit/spec.yaml" ||
    fail "unexpected name: $(cat "$spacey/.sbx/kit/spec.yaml")"
}

@test "a preset without the placeholder is copied byte for byte" {
  make_preset_base
  init_preset "$REPO"
  assert_success
  run diff "$BASE/presets/generic/spec.yaml" "$REPO/.sbx/kit/spec.yaml"
  assert_success
}

# --- precedence and interaction ---------------------------------------------

@test "TASK_AGENT_KIT_URL wins over an explicitly named preset, and warns" {
  make_preset_base
  run --separate-stderr env \
    TASK_AGENT_KIT_URL="file://$FIXTURE" \
    TASK_AGENT_PRESET_BASE_URL="file://$BASE" \
    bash -c "cd '$REPO' && '$TASK_AGENT' --init vaadin"
  assert_success
  run diff "$FIXTURE" "$REPO/.sbx/kit/spec.yaml"
  assert_success
}

@test "the override warning names the ignored preset" {
  make_preset_base
  run --separate-stderr env \
    TASK_AGENT_KIT_URL="file://$FIXTURE" \
    TASK_AGENT_PRESET_BASE_URL="file://$BASE" \
    bash -c "cd '$REPO' && '$TASK_AGENT' --init vaadin"
  assert_success
  [[ "$stderr" == *"ignoring the 'vaadin' preset"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "TASK_AGENT_KIT_URL without a preset warns about nothing" {
  make_preset_base
  init_in "$REPO"
  assert_success
  [[ "$stderr" != *"ignoring"* ]] || fail "unexpected warning: $stderr"
}

@test "--base is still rejected when a preset is given" {
  make_preset_base
  init_preset "$REPO" "vaadin --base main"
  assert_failure
  [[ "$stderr" == *"--base is not valid with --init"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "two presets are rejected" {
  make_preset_base
  init_preset "$REPO" "generic vaadin"
  assert_failure
  [[ "$stderr" == *"Unexpected extra argument"* ]] ||
    fail "unexpected stderr: $stderr"
}

@test "the vaadin preset points at the licence section of the README" {
  make_preset_base
  init_preset "$REPO" vaadin
  assert_success
  [[ "$stderr" == *"licence"* && "$stderr" == *"README"* ]] ||
    fail "no licence pointer: $stderr"
}

@test "the generic preset prints no licence pointer" {
  make_preset_base
  init_preset "$REPO"
  assert_success
  [[ "$stderr" != *"licence"* ]] || fail "unexpected licence note: $stderr"
}

# --- the shipped presets ----------------------------------------------------
#
# presets/<name>/spec.yaml in this repo IS what gets downloaded: the default
# TASK_AGENT_PRESET_BASE_URL points at this repository, so the authored file and
# the published file are the same file. These guard the contract those files have
# with the code above.

@test "every preset named by scaffold_preset_url exists in this repo" {
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin; do
    assert_file_exists "$root/presets/$name/spec.yaml"
  done
}

@test "every shipped preset uses the __PROJECT__ placeholder as its name" {
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin; do
    grep -q '^name: __PROJECT__$' "$root/presets/$name/spec.yaml" ||
      fail "preset '$name' does not use the placeholder as its name"
  done
}

@test "every shipped preset declares schema version 2" {
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin; do
    grep -q '^schemaVersion: "2"$' "$root/presets/$name/spec.yaml" ||
      fail "preset '$name' is not schema version 2"
  done
}

@test "the generic preset carries no Vaadin-specific configuration" {
  # The kit --init used to download was Vaadin-specific despite being the
  # default. `generic` must stay generic; Vaadin is an explicit --init vaadin.
  local shipped="${AGENT_LIB%/lib}/presets/generic/spec.yaml"
  ! grep -qi 'vaadin' "$shipped" ||
    fail "the generic preset mentions Vaadin: $(grep -i vaadin "$shipped")"
}

@test "the preset base URL points at this repository" {
  run bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/scaffold.sh'
    printf '%s' \"\$TASK_AGENT_PRESET_BASE_URL\"
  "
  assert_success
  [[ "$output" == *"/agent-cli/"* ]] ||
    fail "presets are not published from this repository: $output"
}

# --- optional network test --------------------------------------------------

@test "the real generic preset URL is reachable and non-empty (TASK_AGENT_NETWORK_TESTS=1)" {
  [[ -n "${TASK_AGENT_NETWORK_TESTS:-}" ]] ||
    skip "set TASK_AGENT_NETWORK_TESTS=1 to test against the real URL"

  run --separate-stderr bash -c "cd '$REPO' && '$TASK_AGENT' --init"
  assert_success
  assert_file_exists "$REPO/.sbx/kit/spec.yaml"
  [[ -s "$REPO/.sbx/kit/spec.yaml" ]] || fail "downloaded spec.yaml is empty"
  grep -q 'schemaVersion' "$REPO/.sbx/kit/spec.yaml" ||
    fail "downloaded spec.yaml does not look like a kit spec"
}

@test "the real vaadin preset URL is reachable and substituted (TASK_AGENT_NETWORK_TESTS=1)" {
  # Presets are published from this repository's default branch, so this test
  # fails until the preset files are pushed there.
  [[ -n "${TASK_AGENT_NETWORK_TESTS:-}" ]] ||
    skip "set TASK_AGENT_NETWORK_TESTS=1 to test against the real URL"

  run --separate-stderr bash -c "cd '$REPO' && '$TASK_AGENT' --init vaadin"
  assert_success
  grep -q '^name: my-app$' "$REPO/.sbx/kit/spec.yaml" ||
    fail "unexpected name: $(grep '^name:' "$REPO/.sbx/kit/spec.yaml")"
}
