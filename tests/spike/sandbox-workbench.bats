#!/usr/bin/env bats
#
# The workbench's sbx contract (issue #34, ADR 0005).
#
# A workbench mounts the main checkout as its only workspace. That is simpler
# than a task's two workspaces — the main checkout's .git is a directory inside
# it, not a pointer elsewhere — but it is still an assumption about sbx, and the
# whole point of the workbench rests on two more: an edit inside the sandbox is
# the edit the developer's IDE sees, and a branch switched on the host is the
# branch the agent sees, with no recreate in between.
#
# Skipped automatically when sbx is unavailable. Run explicitly with:
#
#   bats tests/spike/sandbox-workbench.bats
#
# They create real sandboxes and remove them again in teardown.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  if ! command -v sbx >/dev/null 2>&1; then
    skip "sbx is not installed — Docker Sandboxes required for the spike"
  fi
  if ! sbx ls >/dev/null 2>&1; then
    skip "sbx is installed but not usable (is the Docker Sandboxes daemon running?)"
  fi

  # Canonical, for the same reason as in sandbox-worktree.bats.
  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-app"
  make_repo "$REPO" >/dev/null

  # `shell` rather than `claude`, so no agent authentication is needed.
  mkdir -p "$REPO/.sbx/kit"
  cat >"$REPO/.sbx/kit/spec.yaml" <<'EOF'
schemaVersion: "2"
kind: mixin
name: agent-cli-spike
displayName: agent-cli workbench spike
description: Minimal kit used only to verify workbench behaviour.
EOF

  SANDBOX=""
}

teardown() {
  [[ -n "${SANDBOX:-}" ]] || return 0
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || true
}

# spike_create <name> — a sandbox over the main checkout alone, the way
# session_workbench_start creates one.
spike_create() {
  SANDBOX="$1"
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || true
  sbx create --kit "$REPO/.sbx/kit" --name "$SANDBOX" shell "$REPO"
}

in_sandbox() {
  sbx exec -w "$REPO" "$SANDBOX" "$@"
}

@test "git works inside a sandbox whose only workspace is the main checkout" {
  spike_create "agent-cli-spike-wb-status"

  run in_sandbox git status --porcelain
  assert_success

  run in_sandbox git branch --show-current
  assert_success
  assert_equal "${output//$'\r'/}" "main"
}

@test "a branch switched on the host is the branch the sandbox sees" {
  spike_create "agent-cli-spike-wb-switch"

  git_quiet -C "$REPO" checkout --quiet -b feature/switched

  run in_sandbox git branch --show-current
  assert_success
  assert_equal "${output//$'\r'/}" "feature/switched"
}

@test "an edit inside the sandbox is immediately visible in the main checkout" {
  spike_create "agent-cli-spike-wb-edit"

  run in_sandbox sh -c "printf 'edited in sandbox\n' > '$REPO/from-sandbox.txt'"
  assert_success

  assert_equal "$(cat "$REPO/from-sandbox.txt")" "edited in sandbox"
  run git -C "$REPO" status --porcelain
  assert_output_contains "from-sandbox.txt"
}

@test "an uncommitted edit on the host is visible inside the sandbox" {
  spike_create "agent-cli-spike-wb-host-edit"

  printf 'work in progress\n' >"$REPO/wip.txt"

  run in_sandbox cat "$REPO/wip.txt"
  assert_success
  assert_equal "${output//$'\r'/}" "work in progress"
}

@test "a commit made inside the sandbox lands on the host's checked-out branch" {
  spike_create "agent-cli-spike-wb-commit"
  git_quiet -C "$REPO" checkout --quiet -b feature/agent

  run in_sandbox sh -c "
    printf 'committed in sandbox\n' > committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' add committed.txt &&
    git -c user.name='Sandbox' -c user.email='sandbox@example.invalid' commit -q -m 'commit from the workbench'
  "
  assert_success

  run git -C "$REPO" log -1 --pretty=%s feature/agent
  assert_success
  assert_equal "$output" "commit from the workbench"
}
