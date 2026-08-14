#!/usr/bin/env bash
# The applied-Sandbox-Kit cache (issue #7).
#
# `task-agent <branch>` must notice that .sbx/kit changed since an existing
# sandbox was created, and Docker Sandboxes exposes no way to ask a sandbox
# which kit it currently has. So the digest of the kit that was last applied is
# remembered here, one file per sandbox:
#
#   <main-repo>/.git/agent-cli/kit/<sandbox-name>   ->  <digest>
#
# This is the one deliberate exception to "no persisted session state" (see
# CLAUDE.md, architectural rule 1), and it is bounded by one invariant: it is a
# **cache**, never a source of truth. Nothing here is ever consulted to decide
# whether a branch, a worktree or a sandbox exists — that is still rediscovered
# from `git worktree list` and `sbx ls` alone. Losing, deleting or corrupting
# these files may only cause the kit to be applied once more than necessary; it
# must never change what task-agent concludes about the world. Every function
# below is written to that rule: a read failure is indistinguishable from "not
# recorded", and a write failure is reported but never fatal.
#
# It lives under .git/ because it belongs to one checkout, is never committed,
# and disappears with the repository it describes. The file name is a sandbox
# name, which naming_sandbox_name restricts to lowercase letters, digits and
# hyphens — so it can never traverse out of the cache directory.

if [[ -n "${AGENT_KIT_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_KIT_SH_LOADED=1

readonly AGENT_KIT_CACHE_RELATIVE_DIR="agent-cli/kit"

# kit_cache_dir <main-repo-root>
kit_cache_dir() {
  printf '%s/%s' "$(git_git_metadata_dir "$1")" "$AGENT_KIT_CACHE_RELATIVE_DIR"
}

# kit_cache_file <main-repo-root> <sandbox-name>
kit_cache_file() {
  printf '%s/%s' "$(kit_cache_dir "$1")" "$2"
}

# kit_cache_read <main-repo-root> <sandbox-name>
#
# Print the digest recorded for <sandbox-name>, or fail. Failing covers "never
# recorded", "unreadable" and "empty" alike: all three mean the same thing to
# the caller — the applied kit is unknown, so apply it.
kit_cache_read() {
  local file digest
  file="$(kit_cache_file "$1" "$2")"

  [[ -f "$file" ]] || return 1
  IFS= read -r digest <"$file" 2>/dev/null || return 1
  [[ -n "$digest" ]] || return 1

  printf '%s' "$digest"
}

# kit_cache_write <main-repo-root> <sandbox-name> <digest>
#
# Record <digest> as the kit applied to <sandbox-name>. Written atomically, so a
# concurrent reader sees either the old digest or the new one, never a partial
# file — a truncated digest would compare unequal and cause a needless re-apply.
#
# A failure here (a read-only .git, say) is reported and returns non-zero, but
# callers are expected to carry on: the cost is re-applying the kit next time.
kit_cache_write() {
  local main_root="$1" sandbox="$2" digest="$3"
  local dir file tmp

  dir="$(kit_cache_dir "$main_root")"
  file="$(kit_cache_file "$main_root" "$sandbox")"

  if ! mkdir -p "$dir" 2>/dev/null; then
    warning "Could not create $dir — the Sandbox Kit will be re-applied next time."
    return 1
  fi

  tmp="$(mktemp "$dir/.digest.XXXXXX" 2>/dev/null)" || {
    warning "Could not write to $dir — the Sandbox Kit will be re-applied next time."
    return 1
  }

  if printf '%s\n' "$digest" >"$tmp" && mv -- "$tmp" "$file"; then
    return 0
  fi

  rm -f -- "$tmp"
  warning "Could not record the applied Sandbox Kit — it will be re-applied next time."
  return 1
}

# kit_cache_remove <main-repo-root> <sandbox-name>
#
# Drop the record for <sandbox-name>. Idempotent, and never an error: `--done`
# calls it whether or not a sandbox was there to remove.
kit_cache_remove() {
  rm -f -- "$(kit_cache_file "$1" "$2")" 2>/dev/null || true
}
