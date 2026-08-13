#!/usr/bin/env bash
# Orchestration for `agent-task <branch> [--base <branch>]` and
# `agent-task --done <branch>`.
#
# This module only sequences the other modules; it contains no git plumbing, no
# path derivation and no sbx argument construction of its own.
#
# There is deliberately no session state file. Everything is rediscovered on each
# invocation from git (`git worktree list`) and Docker Sandboxes (`sbx ls`), so
# agent-cli stays reconstructable from those two systems alone.

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

  if sandbox_exists "$sandbox"; then
    info "Reusing sandbox '$sandbox'"
  else
    info "Creating sandbox '$sandbox'"
    sandbox_create \
      "$sandbox" \
      "$(scaffold_kit_dir "$main_root")" \
      "$worktree" \
      "$(git_git_metadata_dir "$main_root")"
  fi

  sandbox_attach "$sandbox"
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

  local worktree
  if worktree="$(worktree_find_for_branch "$main_root" "$branch")"; then
    info "Removing worktree: $worktree"
    worktree_remove "$main_root" "$worktree"
  else
    info "No worktree found for '$branch'"
  fi

  success "Branch '$branch' was kept."
}
