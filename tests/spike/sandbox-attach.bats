#!/usr/bin/env bats
#
# Spike: does naming the agent on a re-attach actually make the real `sbx`
# verify it?
#
# `sbx run --help` (v0.42.1) documents both forms:
#
#   sbx run --name existing-sandbox          # attach, agent read from the spec
#   sbx run claude --name existing-sandbox   # attach and verify the expected agent
#
# lib/sandbox.sh's sandbox_build_attach_argv builds the second, so that a
# sandbox which merely happens to carry the derived name — made by hand, by
# another tool, or for another agent — is refused instead of silently attached
# to. That guarantee is a claim about the CLI, and this is the only place it is
# checked against the CLI. If the negative case below ever passes, the extra
# argv element buys nothing and the comment in lib/sandbox.sh is wrong.
#
# Skipped automatically when sbx is unavailable, so the normal suite stays
# runnable everywhere. Run explicitly with:
#
#   bats tests/spike/sandbox-attach.bats
#
# Note this creates two real sandboxes, one of them from the Claude template.

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
  source "$AGENT_LIB/sandbox.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-app"
  make_repo "$REPO" >/dev/null

  mkdir -p "$REPO/.sbx/kit"
  cat >"$REPO/.sbx/kit/spec.yaml" <<'EOF'
schemaVersion: "2"
kind: mixin
name: agent-cli-spike
displayName: agent-cli sandbox-attach spike
description: Minimal kit used only to verify the re-attach argv.
EOF

  CLAUDE_SANDBOX="agent-cli-spike-attach-claude"
  OTHER_SANDBOX="agent-cli-spike-attach-shell"

  # Clean up leftovers from an interrupted earlier run first.
  spike_rm "$CLAUDE_SANDBOX"
  spike_rm "$OTHER_SANDBOX"
}

teardown() {
  spike_rm "$CLAUDE_SANDBOX"
  spike_rm "$OTHER_SANDBOX"
}

spike_rm() {
  sbx rm --force "$1" >/dev/null 2>&1 || sbx rm "$1" >/dev/null 2>&1 || true
}

@test "the attach argv is accepted for a sandbox created the way task-agent creates one" {
  sandbox_create "$CLAUDE_SANDBOX" "$REPO/.sbx/kit" "$REPO"

  # Not sandbox_attach: that execs and would hand the terminal to the agent.
  # The agent argument after `--` keeps this non-interactive; what is asserted
  # is only that sbx did not refuse the attach itself.
  sandbox_build_attach_argv "$CLAUDE_SANDBOX"
  run "${AGENT_SBX_ARGV[@]}" -- --version
  assert_success
}

@test "naming the agent refuses a sandbox that belongs to another agent" {
  # Same name, different agent — exactly the collision the extra argv element
  # exists for. stdin is /dev/null for the whole suite, so even a wrongly
  # accepted attach ends at EOF instead of hanging.
  sbx create --kit "$REPO/.sbx/kit" --name "$OTHER_SANDBOX" shell "$REPO"

  sandbox_build_attach_argv "$OTHER_SANDBOX"
  run "${AGENT_SBX_ARGV[@]}"
  assert_failure
}
