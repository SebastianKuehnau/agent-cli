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
      "Install Docker Sandboxes, then run agent-task again."
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

# sandbox_build_kit_add_argv <name> <kit-dir>
sandbox_build_kit_add_argv() {
  AGENT_SBX_ARGV=(sbx kit add "$1" "$2")
}

# sandbox_apply_kit <name> <kit-dir>
#
# Apply a Sandbox Kit to an *existing* sandbox, returning non-zero on failure
# rather than dying — unlike every other sbx call in this file.
#
# That is on purpose: `sbx kit add` is an experimental Docker Sandboxes feature,
# so an installed sbx may not have it at all, and its contract may change. A
# sandbox running a slightly stale kit is a far better outcome than agent-task
# refusing to start the agent, so the caller warns and carries on.
sandbox_apply_kit() {
  sandbox_build_kit_add_argv "$@"
  "${AGENT_SBX_ARGV[@]}"
}

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
