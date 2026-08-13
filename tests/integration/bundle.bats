#!/usr/bin/env bats
#
# Regression tests for scripts/build-bundle.sh (issue #5): a single-file
# install must never crash trying to source lib/*.sh, because for that install
# shape there is no lib/ next to it in the first place.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  BUNDLE="$TMP/agent-task"
  "$AGENT_REPO_ROOT/scripts/build-bundle.sh" >"$BUNDLE"
  chmod +x "$BUNDLE"

  # A directory that intentionally has no sibling lib/, matching a real
  # single-file install (e.g. ~/.local/bin with nothing else in it).
  INSTALL_DIR="$TMP/install"
  mkdir -p "$INSTALL_DIR"
  cp "$BUNDLE" "$INSTALL_DIR/agent-task"
  chmod +x "$INSTALL_DIR/agent-task"

  make_fake_sbx "$TMP/fake"
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

@test "the bundle's --help output matches bin/agent-task's" {
  run "$INSTALL_DIR/agent-task" --help
  assert_success
  local bundled="$output"

  run "$AGENT_TASK" --help
  assert_success

  assert_equal "$bundled" "$output"
}

@test "a branch invocation on the bundle reaches the kit check, with no sibling lib/" {
  local repo="$TMP/my-app"
  make_repo "$repo" >/dev/null

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/agent-task' feature/x"
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

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/agent-task' feature/x"
  assert_success

  run --separate-stderr bash -c "cd '$repo' && '$INSTALL_DIR/agent-task' --done feature/x"
  assert_success
  [[ "$stderr" == *"was kept"* ]] || fail "unexpected stderr: $stderr"
}

@test "--update on the bundle proceeds instead of refusing, since lib/ is absent" {
  run --separate-stderr env AGENT_TASK_UPDATE_URL="file://$TMP/does-not-exist" \
    "$INSTALL_DIR/agent-task" --update
  assert_failure
  # It must fail on the download (no such fixture), not on the lib/ check.
  [[ "$stderr" == *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" != *"git checkout"* ]] || fail "bundle was wrongly treated as a git checkout: $stderr"
}

@test "--update on a checkout (this repo) refuses, since lib/ is present" {
  run --separate-stderr "$AGENT_TASK" --update
  assert_failure
  [[ "$stderr" == *"git checkout"* ]] || fail "unexpected stderr: $stderr"
}
