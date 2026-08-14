#!/usr/bin/env bash
# Orchestration for `task-agent <branch> [--base <branch>]` and
# `task-agent --done <branch>`.
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

# What to do when the Sandbox Kit changed under an existing sandbox: ask (the
# default), yes (recreate without asking), no (never recreate). Applying a kit
# means recreating the sandbox, so this is deliberately not silent by default.
: "${TASK_AGENT_KIT_RECREATE:=ask}"

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
    session_sync_kit "$main_root" "$sandbox" "$kit_dir" "$kit_hash" "$worktree"
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

# session_sync_kit <main-root> <sandbox> <kit-dir> <kit-hash> <worktree>
#
# Bring an existing sandbox's Sandbox Kit up to date with the project's current
# one (issue #7). Before this, editing .sbx/kit had no effect until the sandbox
# was recreated by hand.
#
# Applying a kit means **recreating** the sandbox. There is no in-place update:
# `sbx kit add` only appends to a sandbox's kit list, so handing it the project's
# own kit again fails with "duplicate kit name", and its output shows it recreates
# the sandbox anyway. tests/spike/sandbox-kit.bats pins both facts down against
# the real CLI. So the kit is applied here with remove-then-create, which the
# spike already covers, instead of an experimental command that cannot express
# what is needed.
#
# Because that is destructive to anything living only inside the container, it is
# not silent: see session_kit_should_recreate.
session_sync_kit() {
  local main_root="$1" sandbox="$2" kit_dir="$3" kit_hash="$4" worktree="$5"

  # No digest means no comparison is possible; leave the sandbox alone rather
  # than rebuilding it on every single start.
  [[ -n "$kit_hash" ]] || return 0

  local applied
  applied="$(kit_cache_read "$main_root" "$sandbox")" || applied=""

  if [[ "$applied" == "$kit_hash" ]]; then
    return 0
  fi

  # An untracked sandbox — created before task-agent tracked kits, or one whose
  # record was lost — is adopted rather than rebuilt. Its kit is unknown, and
  # destroying a sandbox nobody asked us to touch is a far worse outcome than
  # missing at most one kit change, which is exactly what happened before
  # issue #7 anyway.
  if [[ -z "$applied" ]]; then
    info "Recording the current Sandbox Kit for '$sandbox' (it was not tracked yet)"
    kit_cache_write "$main_root" "$sandbox" "$kit_hash" || true
    return 0
  fi

  session_kit_should_recreate "$sandbox" || return 0

  info "Recreating sandbox '$sandbox' from the current Sandbox Kit"
  sandbox_remove "$sandbox"
  sandbox_create \
    "$sandbox" \
    "$kit_dir" \
    "$worktree" \
    "$(git_git_metadata_dir "$main_root")"

  kit_cache_write "$main_root" "$sandbox" "$kit_hash" || true
  success "Recreated '$sandbox' from the current Sandbox Kit"
}

# session_kit_should_recreate <sandbox> — 0 to recreate, non-zero to leave it be.
#
# Honours TASK_AGENT_KIT_RECREATE (ask | yes | no). In `ask` mode with no
# terminal to ask at, the answer is no: recreating a sandbox unasked would throw
# away container state the user may still want, and skipping it only leaves the
# sandbox as it already was.
session_kit_should_recreate() {
  local sandbox="$1"

  case "$TASK_AGENT_KIT_RECREATE" in
    yes) return 0 ;;
    no)
      session_kit_kept "$sandbox" "TASK_AGENT_KIT_RECREATE=no."
      return 1
      ;;
    ask) ;;
    *)
      die "Invalid TASK_AGENT_KIT_RECREATE: '$TASK_AGENT_KIT_RECREATE'" \
        "Use one of: ask (the default), yes, no."
      ;;
  esac

  warning "The Sandbox Kit changed since sandbox '$sandbox' was created."
  warning "Applying it recreates that sandbox — Docker Sandboxes has no in-place"
  warning "kit update — so anything that exists only inside the container is lost,"
  warning "the agent's session state in there included."
  warning "The worktree on the host, its files and its commits are not affected."

  if [[ ! -t 0 ]]; then
    session_kit_kept "$sandbox" "Not asking, because stdin is not a terminal."
    warning "  Set TASK_AGENT_KIT_RECREATE=yes to recreate without being asked."
    return 1
  fi

  if confirm "Recreate '$sandbox' from the current kit?"; then
    return 0
  fi

  session_kit_kept "$sandbox" "Not recreating it."
  return 1
}

# session_kit_kept <sandbox> <reason>
#
# Report that a changed kit was not applied. The digest is deliberately not
# recorded, so the next run offers again rather than treating the old kit as
# current.
session_kit_kept() {
  warning "$2 Sandbox '$1' keeps the kit it was created with."
  warning "To apply the current kit later, rebuild the sandbox:"
  warning "  task-agent --done <branch>   # then start the task again"
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
