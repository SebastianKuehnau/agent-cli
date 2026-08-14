#!/usr/bin/env bats
#
# Spike: does `sbx kit add <name> <kit-dir>` (lib/sandbox.sh's
# sandbox_apply_kit) actually apply a changed Sandbox Kit to an existing
# sandbox?
#
# This is the one assumption behind issue #7 that cannot be verified without a
# real sbx binary, and `sbx kit add` is an **experimental** Docker Sandboxes
# feature — its very existence, argument order and exit status are all outside
# agent-cli's control. The product code is written to survive it not working:
# session_sync_kit warns, prints the manual command and starts the agent anyway.
# This spike is what turns "we assume it works" into something checked.
#
# If it fails, lib/sandbox.sh's sandbox_build_kit_add_argv is the single call
# site to change.
#
# Skipped automatically when sbx is unavailable, so the normal suite stays
# runnable everywhere. Run explicitly with:
#
#   bats tests/spike/sandbox-kit.bats

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  if ! command -v sbx >/dev/null 2>&1; then
    skip "sbx is not installed — Docker Sandboxes required for the spike"
  fi
  if ! sbx ls >/dev/null 2>&1; then
    skip "sbx is installed but not usable (is the Docker Sandboxes daemon running?)"
  fi

  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/naming.sh"
  source "$AGENT_LIB/git.sh"
  source "$AGENT_LIB/sandbox.sh"
  source "$AGENT_LIB/scaffold.sh"
  source "$AGENT_LIB/kit.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-app"
  make_repo "$REPO" >/dev/null

  KIT_DIR="$REPO/.sbx/kit"
  mkdir -p "$KIT_DIR"
  write_kit "agent-cli kit spike"

  SANDBOX="agent-cli-spike-kit"
  # Clean up any leftover from an interrupted earlier run first.
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

teardown() {
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

# write_kit <description>
write_kit() {
  cat >"$KIT_DIR/spec.yaml" <<EOF
schemaVersion: "2"
kind: mixin
name: agent-cli-spike
displayName: agent-cli sandbox-kit spike
description: $1
EOF
}

@test "sbx has a kit subcommand at all" {
  # It is experimental, so this may legitimately start failing one day. When it
  # does, session_sync_kit's warning path is what users will see.
  run sbx kit --help
  assert_success
}

@test "sandbox_apply_kit applies a changed kit to a real sandbox" {
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" shell "$REPO"

  run sandbox_exists "$SANDBOX"
  assert_success

  write_kit "agent-cli kit spike, edited after the sandbox existed"

  run sandbox_apply_kit "$SANDBOX" "$KIT_DIR"
  assert_success

  # The sandbox must still be there and usable afterwards, not replaced by a
  # half-built one.
  run sandbox_exists "$SANDBOX"
  assert_success
}

@test "sandbox_apply_kit fails, rather than hangs, for a sandbox that does not exist" {
  # session_sync_kit only ever calls this for a sandbox sbx just listed, but a
  # non-zero exit here is what its warning path relies on.
  run sandbox_apply_kit "agent-cli-spike-does-not-exist" "$KIT_DIR"
  assert_failure
}

@test "the digest agent-cli compares is stable against a real kit directory" {
  local before after
  before="$(scaffold_kit_hash "$REPO")"
  assert_equal "$(scaffold_kit_hash "$REPO")" "$before"

  write_kit "changed"
  after="$(scaffold_kit_hash "$REPO")"
  assert_not_equal "$after" "$before"
}
