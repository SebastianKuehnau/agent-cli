#!/usr/bin/env bats
#
# Regression tests for scripts/build-bundle.sh (issue #5): a single-file
# install must never crash trying to source lib/*.sh, because for that install
# shape there is no lib/ next to it in the first place.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  BUNDLE="$TMP/task-agent"
  "$AGENT_REPO_ROOT/scripts/build-bundle.sh" >"$BUNDLE"
  chmod +x "$BUNDLE"

  # A directory that intentionally has no sibling lib/, matching a real
  # single-file install (e.g. ~/.local/bin with nothing else in it).
  INSTALL_DIR="$TMP/install"
  mkdir -p "$INSTALL_DIR"
  cp "$BUNDLE" "$INSTALL_DIR/task-agent"
  chmod +x "$INSTALL_DIR/task-agent"

  make_fake_sbx "$TMP/fake"

  # Keep the transcript rescue inside the fixture, not in the developer's own
  # ~/.claude/projects.
  CLAUDE_CONFIG_DIR="$TMP/claude"
  export CLAUDE_CONFIG_DIR
}

@test "the bundle is syntactically valid bash" {
  run bash -n "$BUNDLE"
  assert_success
}

@test "the bundle contains no source lines" {
  run grep -c '^source ' "$BUNDLE"
  assert_failure  # grep -c finds none -> exit 1
  assert_equal "$output" "0"
}

@test "the bundle's --help output matches bin/task-agent's" {
  run "$INSTALL_DIR/task-agent" --help
  assert_success
  local bundled="$output"

  run "$TASK_AGENT" --help
  assert_success

  assert_equal "$bundled" "$output"
}

@test "a branch invocation on the bundle reaches the kit check, with no sibling lib/" {
  local repo="$TMP/my-app"
  make_repo "$repo" >/dev/null

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' feature/x"
  assert_failure
  [[ "$stderr" == *"No Sandbox Kit found"* ]] ||
    fail "bundle did not reach the kit check (a source-time crash?): $stderr"
  [[ "$stderr" != *"No such file or directory"* ]] ||
    fail "bundle tried to source a missing lib/ file: $stderr"
}

@test "--done on the bundle works end to end, with no sibling lib/" {
  local repo="$TMP/my-app-done"
  make_repo "$repo" >/dev/null
  mkdir -p "$repo/.sbx/kit"
  printf 'schemaVersion: "2"\n' >"$repo/.sbx/kit/spec.yaml"

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' feature/x"
  assert_success

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' --done feature/x"
  assert_success
  [[ "$stderr" == *"was kept"* ]] || fail "unexpected stderr: $stderr"
}

@test "the bundle rescues transcripts on --done, with no sibling lib/" {
  # Proves lib/transcripts.sh made it into the bundle, and early enough in the
  # concatenation for lib/session.sh to call it.
  local repo="$TMP/my-app-rescue"
  make_repo "$repo" >/dev/null
  mkdir -p "$repo/.sbx/kit"
  printf 'schemaVersion: "2"\n' >"$repo/.sbx/kit/spec.yaml"

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' feature/x"
  assert_success

  fake_sbx_add_transcript "/home/agent/.claude/projects/-wt-feature-x/abc.jsonl"
  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' --done feature/x"
  assert_success
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/-wt-feature-x/abc.jsonl"
}

@test "the bundle applies a changed Sandbox Kit, with no sibling lib/" {
  # Proves lib/kit.sh made it into the bundle, and in a usable order.
  local repo="$TMP/my-app-kit"
  make_repo "$repo" >/dev/null
  mkdir -p "$repo/.sbx/kit"
  printf 'schemaVersion: "2"\n' >"$repo/.sbx/kit/spec.yaml"

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' feature/x"
  assert_success
  : >"$FAKE_SBX_DIR/calls.log"

  printf 'schemaVersion: "2"\nname: changed\n' >"$repo/.sbx/kit/spec.yaml"
  run --separate-stderr env TASK_AGENT_KIT_RECREATE=yes \
    bash -c "cd '$repo' && '$INSTALL_DIR/task-agent' feature/x"
  assert_success
  [[ "$stderr" == *"Recreated"* ]] || fail "unexpected stderr: $stderr"

  run grep -E '^arg:(create|rm|run|ls)$' "$FAKE_SBX_DIR/calls.log"
  assert_success
  assert_equal "$output" "arg:ls
arg:rm
arg:create
arg:run"
}

@test "the bundle reports the same version as the checkout" {
  run "$INSTALL_DIR/task-agent" --version
  assert_success
  local bundled="$output"

  run "$TASK_AGENT" --version
  assert_success

  assert_equal "$bundled" "$output"
}

@test "--update on the bundle proceeds instead of refusing, since lib/ is absent" {
  # Both URLs are local: an unresolvable version probe warns and falls through
  # to the download, which is the step under test here.
  run --separate-stderr env \
    TASK_AGENT_UPDATE_URL="file://$TMP/does-not-exist" \
    TASK_AGENT_LATEST_URL="file://$TMP/no-such-release" \
    "$INSTALL_DIR/task-agent" --update
  assert_failure
  # It must fail on the download (no such fixture), not on the lib/ check.
  [[ "$stderr" == *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" != *"git checkout"* ]] || fail "bundle was wrongly treated as a git checkout: $stderr"
}

@test "--update on a checkout (this repo) refuses, since lib/ is present" {
  run --separate-stderr "$TASK_AGENT" --update
  assert_failure
  [[ "$stderr" == *"git checkout"* ]] || fail "unexpected stderr: $stderr"
}
