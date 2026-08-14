#!/usr/bin/env bash
# Orchestration for `agent-task <branch> [--base <branch>]` and
# `agent-task --done <branch>`.
#
# This module only sequences the other modules; it contains no git plumbing, no
# path derivation and no sbx argument construction of its own.
#
# Everything is rediscovered on each invocation from git (`git worktree list`)
# and Docker Sandboxes (`sbx ls`), so agent-cli stays reconstructable from those
# two systems alone. The single piece of persisted data — the digest of the kit
# last applied to a sandbox, in lib/kit.sh — is a cache, never consulted to
# decide what exists.

if [[ -n "${AGENT_SESSION_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SESSION_SH_LOADED=1

# session_start <branch> <base>
session_start() {
  local branch="$1" base="$2"

  git_require_git
  git_require_repo
  sandbox_require_cli

  git_validate_branch "$branch"
  git_validate_branch "$base"

  local main_root
  main_root="$(git_main_repo_root)" || exit 1

  # Fail before creating anything if the project has not been initialised.
  scaffold_require_kit "$main_root"

  local branch_state
  branch_state="$(git_ensure_branch "$main_root" "$branch" "$base")" || exit 1
  case "$branch_state" in
    existing) info "Reusing existing branch '$branch'" ;;
    tracking) info "Created branch '$branch' tracking origin/$branch" ;;
    created) info "Created branch '$branch' from '$base'" ;;
  esac

  local worktree
  worktree="$(worktree_ensure "$main_root" "$branch")" || exit 1
  info "Worktree: $worktree"

  local project sandbox
  project="$(naming_project_id "$main_root")"
  sandbox="$(naming_sandbox_name "$project" "$branch")"

  local kit_dir kit_hash
  kit_dir="$(scaffold_kit_dir "$main_root")"
  kit_hash="$(scaffold_kit_hash "$main_root")" || kit_hash=""

  if sandbox_exists "$sandbox"; then
    info "Reusing sandbox '$sandbox'"
    session_sync_kit "$main_root" "$sandbox" "$kit_dir" "$kit_hash"
  else
    info "Creating sandbox '$sandbox'"
    sandbox_create \
      "$sandbox" \
      "$kit_dir" \
      "$worktree" \
      "$(git_git_metadata_dir "$main_root")"
    # The sandbox was just built from this kit, so record it as applied.
    [[ -n "$kit_hash" ]] && kit_cache_write "$main_root" "$sandbox" "$kit_hash"
  fi

  sandbox_attach "$sandbox"
}

# session_sync_kit <main-root> <sandbox> <kit-dir> <kit-hash>
#
# Bring an existing sandbox's Sandbox Kit up to date with the project's current
# one (issue #7). Before this, editing .sbx/kit had no effect until the sandbox
# was recreated by hand.
#
# A sandbox with no cache entry — one created by an older agent-task, or whose
# entry was lost — has an unknown kit, so the kit is applied. Applying an
# unchanged kit is wasteful but harmless; skipping a changed one is the bug this
# exists to prevent.
#
# Nothing here is allowed to stop the agent from starting: `sbx kit add` is
# experimental, so a failure warns, prints the manual command, and continues. The
# digest is deliberately *not* recorded in that case, so the next run tries
# again instead of inheriting a false "already applied".
session_sync_kit() {
  local main_root="$1" sandbox="$2" kit_dir="$3" kit_hash="$4"

  # No digest means no comparison is possible; leave the sandbox alone rather
  # than re-applying the kit on every single start.
  [[ -n "$kit_hash" ]] || return 0

  local applied
  applied="$(kit_cache_read "$main_root" "$sandbox")" || applied=""

  if [[ "$applied" == "$kit_hash" ]]; then
    return 0
  fi

  if [[ -n "$applied" ]]; then
    info "The Sandbox Kit changed — applying it to '$sandbox'"
  else
    info "The kit applied to '$sandbox' is unknown — applying the current one"
  fi

  if sandbox_apply_kit "$sandbox" "$kit_dir"; then
    kit_cache_write "$main_root" "$sandbox" "$kit_hash" || true
    success "Applied the current Sandbox Kit to '$sandbox'"
    return 0
  fi

  warning "Could not apply the changed Sandbox Kit to '$sandbox'."
  warning "'sbx kit add' is an experimental Docker Sandboxes feature; apply it yourself with:"
  warning "  sbx kit add $sandbox $kit_dir"
  warning "Starting the agent with the sandbox as it is."
}

# session_done <branch>
#
# Remove the sandbox and the worktree for a branch, if they exist. The branch
# itself is always kept — this is teardown of the ephemeral parts of the
# branch -> worktree -> sandbox -> agent model, not branch deletion.
#
# Sandbox and worktree removal are independent: each is checked and removed
# on its own, so a worktree that was removed by hand can never block cleanup
# of an orphaned sandbox, or vice versa.
session_done() {
  local branch="$1"

  git_require_git
  git_require_repo
  sandbox_require_cli

  git_validate_branch "$branch"

  local main_root
  main_root="$(git_main_repo_root)" || exit 1

  local project sandbox
  project="$(naming_project_id "$main_root")"
  sandbox="$(naming_sandbox_name "$project" "$branch")"

  if sandbox_exists "$sandbox"; then
    info "Removing sandbox '$sandbox'"
    sandbox_remove "$sandbox"
  else
    info "No sandbox found for '$branch'"
  fi

  # Drop the applied-kit record either way: it describes a sandbox that is gone,
  # and a stale entry would otherwise claim a later sandbox of the same name
  # already has this kit.
  kit_cache_remove "$main_root" "$sandbox"

  local worktree
  if worktree="$(worktree_find_for_branch "$main_root" "$branch")"; then
    info "Removing worktree: $worktree"
    worktree_remove "$main_root" "$worktree"
  else
    info "No worktree found for '$branch'"
  fi

  success "Branch '$branch' was kept."
}
