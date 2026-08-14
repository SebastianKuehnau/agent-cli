#!/usr/bin/env bash
# Docker Sandboxes (`sbx`) interaction for agent-cli.
#
# Command construction is kept separate from command execution: the
# `sandbox_build_*_argv` functions only fill the global array AGENT_SBX_ARGV, so
# they can be unit tested element by element with no Docker involved. The two
# `sandbox_create` / `sandbox_attach` functions are the only ones that actually
# invoke sbx, and they always do so as "${AGENT_SBX_ARGV[@]}" — branch names and
# paths stay separate argv elements and are never interpolated into a shell
# string.

if [[ -n "${AGENT_SANDBOX_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SANDBOX_SH_LOADED=1

# The agent sbx runs inside the sandbox. Phase 1 supports Claude only.
readonly AGENT_SBX_AGENT="claude"

# Populated by the sandbox_build_*_argv functions.
declare -a AGENT_SBX_ARGV=()

# sandbox_require_cli
sandbox_require_cli() {
  command -v sbx >/dev/null 2>&1 ||
    die "The Docker Sandboxes CLI (sbx) is not installed or not on PATH." \
      "Install Docker Sandboxes, then run task-agent again."
}

# sandbox_exists <name>
#
# `sbx ls -q` prints one sandbox name per line, which is why agent-cli needs no
# JSON parser. Docker Sandboxes is the source of truth for sandbox existence —
# agent-cli keeps no session state of its own.
sandbox_exists() {
  local name="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$name" ]] && return 0
  done < <(sbx ls -q 2>/dev/null)
  return 1
}

# sandbox_build_create_argv <name> <kit-dir> <workspace> [extra-workspace...]
#
# The first workspace is the git worktree the agent works in. Every workspace is
# mounted inside the sandbox at the same absolute path it has on the host, which
# is what makes a *linked* worktree work: its .git file holds an absolute
# `gitdir:` path into the main repository, and that metadir's commondir points
# back again. Passing the main repository's git metadata directory as a second
# workspace makes both pointers resolve unchanged, with no rewriting.
#
# Note --clone is deliberately not used: it would run the agent on an
# in-container clone, so edits and commits would no longer be immediately
# visible on the host.
sandbox_build_create_argv() {
  local name="$1" kit_dir="$2"
  shift 2

  AGENT_SBX_ARGV=(sbx create --kit "$kit_dir" --name "$name" "$AGENT_SBX_AGENT")

  local workspace
  for workspace in "$@"; do
    AGENT_SBX_ARGV+=("$workspace")
  done
}

# sandbox_build_attach_argv <name>
#
# `sbx run --name X` re-attaches to an existing sandbox and reads the agent from
# that sandbox's stored spec, so the agent and the workspaces do not have to be
# repeated.
sandbox_build_attach_argv() {
  AGENT_SBX_ARGV=(sbx run --name "$1")
}

# sandbox_create <name> <kit-dir> <workspace> [extra-workspace...]
sandbox_create() {
  sandbox_build_create_argv "$@"
  "${AGENT_SBX_ARGV[@]}" ||
    die "Failed to create the sandbox '$1'." \
      "The sbx output above should explain why."
}

# sandbox_attach <name>
#
# Replaces the current process so the agent owns the terminal directly.
sandbox_attach() {
  sandbox_build_attach_argv "$1"
  exec "${AGENT_SBX_ARGV[@]}"
}

# There is deliberately no `sbx kit add` wrapper here. It cannot express "this
# kit changed": by its own documentation it recreates the sandbox "with the new
# kit appended to its original kit list", so re-adding the project's own kit
# fails with
#
#   compose: duplicate kit name "<name>" — each kit in a composition must have
#   a unique name
#
# which is what tests/spike/sandbox-kit.bats demonstrates against the real CLI.
# `sbx kit` offers add, inspect, pack, pull, push and validate — there is no
# replace or remove to reach for either.
#
# Since applying a kit recreates the sandbox regardless, a changed kit is applied
# here by remove-then-create, using commands the spike already covers. The one
# thing given up is that `sbx kit add`'s own swap preserves kit-owned volumes
# (agent session state) while `sbx rm` does not — which is why the user is asked
# first. See lib/session.sh's session_sync_kit.

# sandbox_build_remove_argv <name>
sandbox_build_remove_argv() {
  AGENT_SBX_ARGV=(sbx rm --force "$1")
}

# sandbox_remove <name>
sandbox_remove() {
  sandbox_build_remove_argv "$@"
  "${AGENT_SBX_ARGV[@]}" ||
    die "Failed to remove the sandbox '$1'." \
      "The sbx output above should explain why."
}
