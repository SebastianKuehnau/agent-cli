#!/usr/bin/env bats
#
# Spike: does anything in a sandbox outlive `sbx rm`? (issue #45)
#
# The kit spec changed on 2026-11-06 (docker/sandbox-kit-spec#209, BREAKING):
# `volume@1` block storage is keyed on (owner scope, sandbox name, path) and
# *survives sandbox deletion* — `sbx rm` followed by `sbx create` under the same
# name reattaches it. The spec's own config example puts that volume at
# /home/agent/.claude/projects.
#
# task-agent derives a task's sandbox name from its branch, so the same branch
# always gets the same name back. If retained storage ever covers ~/.claude:
#
#   - `--done` stops being a clean teardown: a later start of the same branch
#     inherits the old sessions, settings and plugins;
#   - transcript rule 3 in CLAUDE.md ("a recreated sandbox starts with an empty
#     projects/") no longer holds, and transcripts are rescued again;
#   - the kit-recreate warning ("the session itself cannot be resumed
#     afterwards") becomes wrong, in the harmless direction.
#
# Read statically on 2026-11-13, before this spike had run: the spec repo's own
# sbx TCK adapter (tck/adapters/sbx) leaves volume@1 *unclaimed* because "sbx
# mounts nothing at a declared volume path", and sbx v0.53.0's release notes
# mention no volume retention. So the first two sections are expected to pass on
# v0.53.0. They are written to fail the day that changes, which is the signal to
# reopen #45 — not to adjust the assertions.
#
# The third section answers the other open question from the same spec update:
# which of a task sandbox's two workspaces (the worktree, then the main
# repository's .git) the runtime-owned WORKSPACE_DIR names. Project kits use it
# in hooks, e.g. `cd "$WORKSPACE_DIR"` for a Maven warm-up.
#
# Skipped automatically when sbx is unavailable. Run explicitly with:
#
#   bats tests/spike/sandbox-volume.bats
#
# Caveat: if a test here finds retained storage, it cannot clean it up — there
# is no known sbx command for that yet, which is part of what #45 asks.

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

  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-volume-app"
  make_repo "$REPO" >/dev/null

  KIT_DIR="$REPO/.sbx/kit"
  mkdir -p "$KIT_DIR"

  SANDBOX="agent-cli-spike-volume"
  spike_rm
}

teardown() {
  spike_rm
}

spike_rm() {
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

# write_kit [extra capability YAML]
#
# A minimal v3 mixin. The argument is appended under `capabilities:` verbatim.
write_kit() {
  {
    cat <<'EOF'
# syntax=docker/sandbox-kit:3
schemaVersion: "3"
kind: mixin
displayName: agent-cli volume spike
description: Used only to measure what survives sbx rm (issue #45).
EOF
    if [[ -n "${1:-}" ]]; then
      printf 'capabilities:\n%s\n' "$1"
    fi
  } >"$KIT_DIR/spec.yaml"
}

# recreate <agent> <workspace>... — remove the sandbox and create it again under
# the same name, from the same kit and workspaces. This is exactly what
# `task-agent --done <branch>` followed by `task-agent <branch>` does.
recreate() {
  spike_rm
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" "$@"
}

# in_sandbox <command>... — run a command inside the sandbox as the agent user,
# with carriage returns stripped (sbx exec may allocate a pty).
in_sandbox() {
  local out status=0
  out="$(sbx exec "$SANDBOX" "$@")" || status=$?
  printf '%s' "${out//$'\r'/}"
  return "$status"
}

# --- what task-agent relies on today: the claude agent's ~/.claude -----------

@test "the claude agent's ~/.claude/projects does not survive sbx rm and create" {
  # The invariant behind transcript rule 3 and behind --done being a clean
  # teardown, measured with the agent task-agent actually runs.
  write_kit
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" claude "$REPO"

  local dir
  dir="$(in_sandbox sh -c 'printf %s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/agent-cli-spike"')"
  in_sandbox sh -c "test ! -e '$dir/marker.jsonl'" || fail "a fresh sandbox already had $dir/marker.jsonl — storage from an earlier run was reattached"

  in_sandbox sh -c "mkdir -p '$dir' && echo kept > '$dir/marker.jsonl'"

  recreate claude "$REPO"

  in_sandbox sh -c "test ! -e '$dir/marker.jsonl'" || fail "$dir/marker.jsonl survived sbx rm — see issue #45 before changing this test"
}

@test "the claude agent mounts nothing under ~/.claude except the host's skills" {
  # Measured on v0.51.0: the only mount there is ~/.claude/skills (the host's
  # skills store). A volume on ~/.claude or below it would show up here even
  # before sbx retains it across deletion.
  write_kit
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" claude "$REPO"

  # /proc/self/mountinfo field 5 is the mount point; no findmnt needed.
  run in_sandbox sh -c 'b="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    awk -v base="$b" "\$5 == base || index(\$5, base \"/\") == 1 { print \$5 }" /proc/self/mountinfo |
      grep -vxF "$b/skills" || true'
  assert_success
  assert_equal "$output" ""
}

# --- volume@1 in a kit: characterised, not relied on --------------------------

VOLUME_PATH="/home/agent/agent-cli-spike-volume"

volume_capability() {
  cat <<EOF
  - type: com.docker.sandbox/volume@1
    config:
      path: $VOLUME_PATH
      mode: "0777"
EOF
}

@test "sbx accepts a kit declaring volume@1" {
  # If this fails, the two tests below say nothing; the output says why.
  write_kit "$(volume_capability)"
  run sbx create --kit "$KIT_DIR" --name "$SANDBOX" shell "$REPO"
  assert_success
}

@test "sbx mounts nothing at a kit's volume@1 path" {
  # What the spec repo's sbx TCK adapter states as of 2026-11-09. Failing here
  # means sbx has started implementing volume@1: re-measure the next test and
  # the claude agent's kit (issue #45).
  write_kit "$(volume_capability)"
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" shell "$REPO"

  run in_sandbox awk -v p="$VOLUME_PATH" '$5 == p { print $5 }' /proc/self/mountinfo
  assert_success
  assert_equal "$output" ""
}

@test "a file at a kit's volume@1 path does not survive sbx rm and create" {
  write_kit "$(volume_capability)"
  sbx create --kit "$KIT_DIR" --name "$SANDBOX" shell "$REPO"

  in_sandbox sh -c "test ! -e '$VOLUME_PATH/marker'" || fail "a fresh sandbox already had $VOLUME_PATH/marker — storage from an earlier run was reattached"

  in_sandbox sh -c "mkdir -p '$VOLUME_PATH' && echo kept > '$VOLUME_PATH/marker'"

  recreate shell "$REPO"

  in_sandbox sh -c "test ! -e '$VOLUME_PATH/marker'" || fail "$VOLUME_PATH/marker survived sbx rm: sbx now retains volume@1 storage (issue #45)"
}

# --- which workspace WORKSPACE_DIR names ---------------------------------------

# workspace_dir_kit — an install hook that records what WORKSPACE_DIR it sees.
# Hooks are deny-by-default, so the variable is listed in `env:` — the way a
# project kit would have to ask for it. "<unset>" distinguishes absent from empty.
workspace_dir_kit() {
  write_kit "$(cat <<'EOF'
  - type: com.docker.sandbox/lifecycle@1
    config:
      install:
        - description: Record WORKSPACE_DIR
          user: "1000"
          env: [WORKSPACE_DIR]
          command: "printf %s \"${WORKSPACE_DIR-<unset>}\" > /tmp/spike-workspace-dir"
EOF
)"
}

@test "WORKSPACE_DIR in a task sandbox names the worktree, not the .git workspace" {
  local branch="feature/spike-volume" worktree="$TMP/spike-volume-app-worktrees/feature-spike-volume"
  git_quiet -C "$REPO" branch "$branch"
  mkdir -p "$(dirname "$worktree")"
  git_quiet -C "$REPO" worktree add --quiet "$worktree" "$branch"

  # The kit lives in the main checkout, as for a real task; the workspaces are
  # the ones session_start passes, in its order.
  workspace_dir_kit
  sandbox_create "$SANDBOX" "$KIT_DIR" "$worktree" "$(git_git_metadata_dir "$REPO")"

  run in_sandbox cat /tmp/spike-workspace-dir
  assert_success
  assert_equal "$output" "$worktree"
}

@test "WORKSPACE_DIR in the workbench names the main checkout" {
  workspace_dir_kit
  sandbox_create "$SANDBOX" "$KIT_DIR" "$REPO"

  run in_sandbox cat /tmp/spike-workspace-dir
  assert_success
  assert_equal "$output" "$REPO"
}
