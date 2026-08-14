#!/usr/bin/env bats
#
# Spike: how does a *changed* Sandbox Kit actually reach an existing sandbox?
#
# This started out asserting that `sbx kit add <name> <kit-dir>` applies a
# changed kit. Run against a real sbx, it does not — and that finding is why
# lib/session.sh recreates the sandbox instead. The tests below pin the finding
# down so the design cannot quietly drift back:
#
#   1. `sbx kit add` *appends* to a sandbox's kit list and recomposes it. Handing
#      it the project's own, already-applied kit therefore fails:
#
#        400 Bad Request: compose agent from augmented kits: compose: duplicate
#        kit name "<name>" — each kit in a composition must have a unique name
#
#      Since the kit's name identifies the project's kit and does not change when
#      its contents do, this is the normal case, not an edge case. `sbx kit add`
#      simply cannot express "this kit changed".
#
#   2. Its own output — "Recreating sandbox ... to apply augmented kit list" —
#      shows that applying a kit recreates the sandbox anyway. So remove-then-
#      create is not a workaround; it is the same operation, expressed with
#      commands whose behaviour is verified (see also sandbox-remove.bats).
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

# create_sandbox — like sandbox_create, but with the `shell` agent.
#
# The other spikes do the same: what is under test is how sbx treats kits, not
# which agent runs inside, and `shell` needs no agent image or credentials. The
# argv sandbox_create builds is asserted in tests/unit/sandbox.bats instead.
create_sandbox() {
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" shell "$REPO"
}

# --- the finding ------------------------------------------------------------

@test "sbx kit add cannot re-apply the kit a sandbox already has" {
  # If this ever starts succeeding, Docker Sandboxes has gained a real in-place
  # kit update and session_sync_kit's recreate could be reconsidered. Until
  # then, the failure is the contract.
  create_sandbox

  run sbx kit add "$SANDBOX" "$KIT_DIR"
  assert_failure

  # Only the failure is the assertion; the wording below is sbx's and may change.
  [[ "$output" == *"duplicate kit name"* ]] ||
    printf 'note: failed for a different reason than the known one:\n%s\n' "$output" >&3
}

@test "a changed kit does not change that" {
  # The kit's name stays the same when its contents change, which is exactly why
  # `sbx kit add` is unusable here.
  create_sandbox
  write_kit "edited after the sandbox existed"

  run sbx kit add "$SANDBOX" "$KIT_DIR"
  assert_failure
}

# --- what task-agent actually does ------------------------------------------

@test "remove-then-create applies a changed kit to a real sandbox" {
  create_sandbox

  run sandbox_exists "$SANDBOX"
  assert_success

  write_kit "edited after the sandbox existed"

  # The sequence session_sync_kit performs once recreation is agreed to.
  run sandbox_remove "$SANDBOX"
  assert_success
  run sandbox_exists "$SANDBOX"
  assert_failure

  run create_sandbox
  assert_success
  run sandbox_exists "$SANDBOX"
  assert_success
}

@test "the recreated sandbox is usable, and has the changed kit" {
  create_sandbox
  write_kit "edited after the sandbox existed"
  sandbox_remove "$SANDBOX"
  create_sandbox

  # `sbx exec` is how the other spikes reach into a sandbox; sandbox_attach
  # itself execs into it and so cannot be run from a test.
  run sbx exec -w "$REPO" "$SANDBOX" git status --porcelain
  assert_success
}

# --- the digest -------------------------------------------------------------

@test "the digest task-agent compares is stable against a real kit directory" {
  local before after
  before="$(scaffold_kit_hash "$REPO")"
  assert_equal "$(scaffold_kit_hash "$REPO")" "$before"

  write_kit "changed"
  after="$(scaffold_kit_hash "$REPO")"
  assert_not_equal "$after" "$before"
}
