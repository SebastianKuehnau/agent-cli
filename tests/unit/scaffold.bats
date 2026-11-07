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
# syntax=docker/sandbox-kit:3
schemaVersion: "3"
kind: mixin
displayName: my-project
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
  mkdir -p "$BASE/presets/generic" "$BASE/presets/vaadin" \
    "$BASE/presets/vaadin-claude"
  printf '# syntax=docker/sandbox-kit:3\nschemaVersion: "3"\nkind: mixin\ndisplayName: generic-marker\n' \
    >"$BASE/presets/generic/spec.yaml"
  printf '# syntax=docker/sandbox-kit:3\nschemaVersion: "3"\nkind: mixin\ndisplayName: __PROJECT__ env\ndescription: __PROJECT__ kit\n' \
    >"$BASE/presets/vaadin/spec.yaml"
  printf '# syntax=docker/sandbox-kit:3\nschemaVersion: "3"\nkind: mixin\ndisplayName: __PROJECT__ claude\ndescription: __PROJECT__ kit\n' \
    >"$BASE/presets/vaadin-claude/spec.yaml"
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
  grep -q 'displayName: generic-marker' "$REPO/.sbx/kit/spec.yaml" ||
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

@test "--init vaadin-claude resolves the vaadin-claude preset" {
  make_preset_base
  init_preset "$REPO" vaadin-claude
  assert_success
  grep -q 'displayName: my-app claude' "$REPO/.sbx/kit/spec.yaml" ||
    fail "did not get the vaadin-claude preset: $(cat "$REPO/.sbx/kit/spec.yaml")"
  [[ "$stderr" == *"'vaadin-claude' preset"* ]] || fail "unexpected stderr: $stderr"
}

@test "an unknown preset fails, names the known ones, and creates nothing" {
  make_preset_base
  init_preset "$REPO" nosuchpreset
  assert_failure
  [[ "$stderr" == *"Unknown preset: nosuchpreset"* ]] ||
    fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"generic"* && "$stderr" == *"vaadin"* &&
    "$stderr" == *"vaadin-claude"* ]] ||
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
  grep -q '^displayName: my-app env$' "$REPO/.sbx/kit/spec.yaml" ||
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
  grep -q '^displayName: my-vaadin-app env$' "$spacey/.sbx/kit/spec.yaml" ||
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

@test "the vaadin-claude preset points at the licence section of the README" {
  make_preset_base
  init_preset "$REPO" vaadin-claude
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
  for name in generic vaadin vaadin-claude; do
    assert_file_exists "$root/presets/$name/spec.yaml"
  done
}

@test "every shipped preset uses the __PROJECT__ placeholder in its display name" {
  # v3 has no `name:` field (strict decoding rejects it), so displayName is
  # where the project's name goes.
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin vaadin-claude; do
    grep -q '^displayName: __PROJECT__ ' "$root/presets/$name/spec.yaml" ||
      fail "preset '$name' does not use the placeholder in its display name"
  done
}

@test "every shipped preset is a schema v3 kit" {
  # sbx v0.51.0 resolves the claude agent to a v3 kit and refuses to compose it
  # with v1/v2 kits (issue #43). Without the syntax line on line 1, sbx parses
  # the file as a Dockerfile.
  local root="${AGENT_LIB%/lib}" name spec
  for name in generic vaadin vaadin-claude; do
    spec="$root/presets/$name/spec.yaml"
    assert_equal "$(head -n 1 "$spec")" "# syntax=docker/sandbox-kit:3"
    grep -q '^schemaVersion: "3"$' "$spec" ||
      fail "preset '$name' is not schema version 3"
    ! grep -Eq '^(name|setup|environment|permissions):' "$spec" ||
      fail "preset '$name' still uses a v2 top-level key"
  done
}

@test "every shipped preset installs JDK 25 and fills its truststore" {
  # The v3 claude workload ships no JDK, and its truststore stays empty until
  # update-ca-certificates runs — Maven then fails on every download.
  local root="${AGENT_LIB%/lib}" name spec
  for name in generic vaadin vaadin-claude; do
    spec="$root/presets/$name/spec.yaml"
    grep -q 'openjdk-25-jdk-headless' "$spec" ||
      fail "preset '$name' installs no JDK 25"
    grep -q 'update-ca-certificates -f' "$spec" ||
      fail "preset '$name' leaves the Java truststore empty"
  done
}

@test "every shipped preset updates Claude Code at setup time" {
  # The workload image bakes in whatever Claude Code was current when it was
  # built, and nothing in a sandbox ever refreshes it (issue #19). Every preset
  # has to ask, including the generic one — an agent weeks out of date is not a
  # Vaadin-specific problem.
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin vaadin-claude; do
    grep -q 'claude update' "$root/presets/$name/spec.yaml" ||
      fail "preset '$name' never updates Claude Code"
  done
}

@test "the Claude Code update cannot fail a sandbox build" {
  # Best-effort on purpose: an update that cannot reach the network must not
  # stop the sandbox from being created, because the image's version still
  # works. Dropping the guard would make every offline `task-agent <branch>`
  # fail at sandbox creation.
  local root="${AGENT_LIB%/lib}" name
  for name in generic vaadin vaadin-claude; do
    grep -q 'claude update || true' "$root/presets/$name/spec.yaml" ||
      fail "preset '$name' lets a failed update break sandbox creation"
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
  grep -q '^displayName: my-app ' "$REPO/.sbx/kit/spec.yaml" ||
    fail "unexpected name: $(grep '^displayName:' "$REPO/.sbx/kit/spec.yaml")"
}

@test "the real vaadin-claude preset URL is reachable and substituted (TASK_AGENT_NETWORK_TESTS=1)" {
  # Presets are published from this repository's default branch, so this test
  # fails until the preset files are pushed there.
  [[ -n "${TASK_AGENT_NETWORK_TESTS:-}" ]] ||
    skip "set TASK_AGENT_NETWORK_TESTS=1 to test against the real URL"

  run --separate-stderr bash -c "cd '$REPO' && '$TASK_AGENT' --init vaadin-claude"
  assert_success
  grep -q '^displayName: my-app ' "$REPO/.sbx/kit/spec.yaml" ||
    fail "unexpected name: $(grep '^displayName:' "$REPO/.sbx/kit/spec.yaml")"
}

# --- the vaadin-claude preset's agent configuration -------------------------
#
# This preset is the only place agent configuration lives: task-agent itself
# never writes any (docs/adr/0003-agent-configuration-lives-in-the-preset-kit.md).
# These guard the two properties of that setup step that are not obvious from
# reading it, and that would fail silently inside a sandbox.

@test "the vaadin-claude preset configures a status line" {
  local shipped="${AGENT_LIB%/lib}/presets/vaadin-claude/spec.yaml"
  grep -q 'statusLine' "$shipped" ||
    fail "the vaadin-claude preset configures no status line"
  grep -q 'used_percentage' "$shipped" ||
    fail "the status line does not read the context-window usage"
}

@test "the vaadin-claude preset merges settings.json rather than replacing it" {
  # ~/.claude/settings.json is seeded by Docker Sandboxes. Overwriting it would
  # throw that away, so the step must go through jq.
  local shipped="${AGENT_LIB%/lib}/presets/vaadin-claude/spec.yaml"
  grep -q 'jq --arg cmd' "$shipped" ||
    fail "the vaadin-claude preset does not merge settings.json with jq"
  ! grep -q "cat >.*settings.json" "$shipped" ||
    fail "the vaadin-claude preset overwrites settings.json"
}

@test "the vaadin-claude preset never writes into ~/.claude/skills" {
  # That path is a read-write mount of the *host* skills directory: writing
  # there would leak sandbox configuration onto the developer's machine.
  # Comment lines are excluded: the preset explains the hazard in one, and
  # explaining it is not doing it.
  local shipped="${AGENT_LIB%/lib}/presets/vaadin-claude/spec.yaml"
  ! grep -v '^[[:space:]]*#' "$shipped" | grep -q '\.claude/skills' ||
    fail "the vaadin-claude preset writes into the host's skills directory"
}

@test "the vaadin-claude preset installs the skill plugins" {
  local shipped="${AGENT_LIB%/lib}/presets/vaadin-claude/spec.yaml"
  grep -q 'claude plugin install vaadin-skills@vaadin-marketplace' "$shipped" ||
    fail "the vaadin-claude preset does not install the Vaadin skills"
  grep -q 'claude plugin install mattpocock-skills@claude-plugins-official' "$shipped" ||
    fail "the vaadin-claude preset does not install the general skills"
}
