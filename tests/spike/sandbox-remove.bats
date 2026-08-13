#!/usr/bin/env bats
#
# Spike: does `sbx rm --force <name>` (lib/sandbox.sh's sandbox_remove) actually
# remove a real sandbox?
#
# This is deliberately verified against the real `sbx` CLI rather than coded
# defensively in product code: tests/spike/sandbox-worktree.bats's own
# teardown helper falls back from `sbx rm --force` to plain `sbx rm`, which is
# the only local signal that `--force` might not always be accepted — but
# there is no way to confirm that without a real sbx binary. If this spike
# ever fails with `--force` rejected, lib/sandbox.sh's
# sandbox_build_remove_argv is the single call site to change.
#
# Skipped automatically when sbx is unavailable, so the normal suite stays
# runnable everywhere. Run explicitly with:
#
#   bats tests/spike/sandbox-remove.bats

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
displayName: agent-cli sandbox-remove spike
description: Minimal kit used only to verify sandbox removal.
EOF

  SANDBOX="agent-cli-spike-remove"
  # Clean up any leftover from an interrupted earlier run first.
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

teardown() {
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

@test "sandbox_remove removes a real sandbox" {
  sbx create --kit "$REPO/.sbx/kit" --name "$SANDBOX" shell "$REPO"

  run sandbox_exists "$SANDBOX"
  assert_success

  run sandbox_remove "$SANDBOX"
  assert_success

  run sandbox_exists "$SANDBOX"
  assert_failure
}
