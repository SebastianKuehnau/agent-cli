#!/usr/bin/env bats
#
# Spike: how does a *changed* Sandbox Kit actually reach an existing sandbox?
#
# task-agent applies a changed kit by remove-then-create (lib/session.sh). The
# reason used to be that `sbx kit add` could not express "this kit changed":
# up to sbx v0.42.1 it *appended* to a sandbox's kit list, so re-adding the
# project's own, same-named kit failed with
#
#   compose: duplicate kit name "<name>" — each kit in a composition must have
#   a unique name
#
# sbx v0.48.0 changed that (issue #37). Re-adding a same-named kit now
# succeeds, and the tests below pin down what it does instead, because that —
# not the success alone — is what a decision to use it would rest on:
#
#   - the kit list stays one entry: the same-named kit is replaced, not
#     appended (read from `sbx inspect --json`, which reports a sandbox's kits
#     as the references it was given — a path, not a digest);
#   - the changed kit's content takes effect;
#   - files in the container survive, in $HOME and outside it — the swap
#     container runs from an image committed from the old one;
#   - the workspace is still the host's bind mount;
#   - the network allowlist is replaced too: the old kit's hosts are denied,
#     the new kit's allowed;
#   - the new kit's setup.install steps run, on top of the kept container, and
#     on *every* `sbx kit add` — an unchanged step runs again, and a removed
#     step's effects stay. Unlike a fresh sandbox, the result depends on
#     history, so every install step would have to be idempotent.
#
# Whether task-agent should switch to it is not decided here; see issue #37.
# The help text still says "appended to its original kit list", and the
# command is still EXPERIMENTAL.
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

# write_kit <description> [value]
#
# <value> lands in SPIKE_VALUE inside the sandbox, which is how a test sees
# which version of the kit a sandbox is running. It also names the one host
# the kit allows, and the setup step appends it to /tmp/spike-setup.log, so a
# test can see which network rules and which install steps are in effect.
write_kit() {
  local value="${2:-one}"
  cat >"$KIT_DIR/spec.yaml" <<EOF
schemaVersion: "2"
kind: mixin
name: agent-cli-spike
displayName: agent-cli sandbox-kit spike
description: $1
setup:
  install:
    - command: "echo $value >> /tmp/spike-setup.log"
      user: "1000"
environment:
  variables:
    SPIKE_VALUE: "$value"
permissions:
  network:
    allow:
      - agent-cli-spike-$value.example.com
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

# --- what `sbx kit add` does with the project's own kit (v0.48.0) ----------

# kit_entries — how many times the project kit appears in the sandbox's kit list.
#
# Counted as the quoted path, so the workspace (a prefix of it) never matches.
# No JSON parser: jq is not a dependency, not even for the spikes.
kit_entries() {
  sbx inspect --json "$SANDBOX" | grep -cF "\"$KIT_DIR\"" || true
}

@test "sbx kit add accepts the kit a sandbox already has" {
  # Up to v0.42.1 this failed with "duplicate kit name". If it starts failing
  # again, issue #37's premise is gone.
  create_sandbox

  run sbx kit add "$SANDBOX" "$KIT_DIR"
  assert_success
}

@test "re-adding a changed kit replaces it instead of appending a second copy" {
  create_sandbox
  assert_equal "$(kit_entries)" "1"

  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"
  assert_equal "$(kit_entries)" "1"

  write_kit "edited a second time" "three"
  sbx kit add "$SANDBOX" "$KIT_DIR"
  assert_equal "$(kit_entries)" "1"
}

@test "the changed kit's content takes effect after sbx kit add" {
  create_sandbox
  run sbx exec "$SANDBOX" sh -c 'printf %s "$SPIKE_VALUE"'
  assert_equal "$output" "one"

  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"

  run sbx exec "$SANDBOX" sh -c 'printf %s "$SPIKE_VALUE"'
  assert_success
  assert_equal "$output" "two"
}

@test "container files survive sbx kit add, unlike remove-then-create" {
  create_sandbox
  sbx exec "$SANDBOX" sh -c 'echo kept > "$HOME/spike-marker"; echo kept > /tmp/spike-marker'

  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"

  run sbx exec "$SANDBOX" cat /home/agent/spike-marker /tmp/spike-marker
  assert_success
  assert_equal "${output//$'\r'/}" $'kept\nkept'
}

@test "the workspace is still the host's bind mount after sbx kit add" {
  create_sandbox
  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"

  run sbx exec "$SANDBOX" sh -c "printf 'from sandbox\\n' > '$REPO/after-kit-add.txt'"
  assert_success
  assert_equal "$(cat "$REPO/after-kit-add.txt")" "from sandbox"
}

# network_decision <value> — Allowed or Denied, for the host kit <value> allows.
network_decision() {
  sbx policy check network --sandbox "$SANDBOX" "agent-cli-spike-$1.example.com" |
    grep -oE 'Allowed|Denied' | head -1
}

@test "sbx kit add replaces the network allowlist" {
  create_sandbox
  assert_equal "$(network_decision one)" "Allowed"
  assert_equal "$(network_decision two)" "Denied"

  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"

  assert_equal "$(network_decision one)" "Denied"
  assert_equal "$(network_decision two)" "Allowed"
}

@test "sbx kit add runs the new kit's install steps on top of the kept container" {
  create_sandbox
  write_kit "edited after the sandbox existed" "two"
  sbx kit add "$SANDBOX" "$KIT_DIR"

  # "one" is the first kit's step, kept with the container; "two" ran on add.
  run sbx exec "$SANDBOX" cat /tmp/spike-setup.log
  assert_success
  assert_equal "${output//$'\r'/}" $'one\ntwo'
}

@test "sbx kit add runs an unchanged install step again" {
  create_sandbox
  sbx kit add "$SANDBOX" "$KIT_DIR"

  # A fresh sandbox would have run it once. This is why install steps would
  # have to be idempotent before session_sync_kit could use sbx kit add.
  run sbx exec "$SANDBOX" cat /tmp/spike-setup.log
  assert_success
  assert_equal "${output//$'\r'/}" $'one\none'
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
