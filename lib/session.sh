#!/usr/bin/env bash
# Orchestration for `task-agent <branch> [--base <branch>]`,
# `task-agent --done <branch>`, and their workbench counterparts `--here` and
# `--done --here`.
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

  # Validated up front, before anything is created: an invalid setting must
  # cost a re-run, never a half-built task.
  transcripts_validate_mode
  projectconfig_validate_mode

  git_validate_branch "$branch"
  git_validate_branch "$base"

  local main_root
  main_root="$(git_main_repo_root)" || exit 1

  # Fail before creating anything if the project has not been initialised.
  scaffold_require_kit "$main_root"

  # The main checkout is never a task's worktree (issue #36). Git reports it
  # alongside the linked worktrees, so without this a task for the branch
  # checked out there would mount the developer's own checkout — the
  # workbench's directory — as if it were a worktree of its own.
  local registered
  if registered="$(worktree_find_for_branch "$main_root" "$branch")" &&
    worktree_is_main_checkout "$main_root" "$registered"; then
    die "'$branch' is checked out in the main checkout, which is never a task's worktree:" \
      "  $main_root" \
      "To work on it there, beside your IDE, start the workbench:" \
      "  task-agent --here" \
      "To run a parallel task on top of it, fork it:" \
      "  task-agent $branch --fork"
  fi

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

  # A fresh worktree holds tracked files only, so an untracked .claude/ — which
  # is the usual shape — would be missing from the very directory the sandbox
  # mounts. Gaps are filled every start, never overwritten. A failure here is
  # reported but not fatal: a task with incomplete project configuration is
  # still a task, and refusing to start would be the worse outcome.
  projectconfig_seed "$main_root" "$worktree" || true

  local project sandbox
  project="$(naming_project_id "$main_root")"
  sandbox="$(naming_sandbox_name "$project" "$branch")"

  local kit_dir kit_hash
  kit_dir="$(scaffold_kit_dir "$main_root")"
  kit_hash="$(scaffold_kit_hash "$main_root")" || kit_hash=""

  if sandbox_exists "$sandbox"; then
    info "Reusing sandbox '$sandbox'"
    session_sync_kit "$main_root" "$sandbox" "$kit_dir" "$kit_hash" \
      "task-agent --done <branch>" \
      "$worktree" "$(git_git_metadata_dir "$main_root")"
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

# session_sync_kit <main-root> <sandbox> <kit-dir> <kit-hash> <rebuild-hint> <workspace...>
#
# Bring an existing sandbox's Sandbox Kit up to date with the project's current
# one (issue #7). Before this, editing .sbx/kit had no effect until the sandbox
# was recreated by hand.
#
# Applying a kit means **recreating** the sandbox, by remove-then-create. Up to
# sbx v0.42.1 `sbx kit add` could not do it at all ("duplicate kit name"). From
# v0.48.0 it can replace a same-named kit, but it reruns the kit's install steps
# on top of the kept container, so the result depends on the sandbox's kit
# history rather than on the current kit (issue #37). Remove-then-create always
# yields exactly the current kit. tests/spike/sandbox-kit.bats pins both
# behaviours down against the real CLI.
#
# Because that is destructive to anything living only inside the container, it is
# not silent: see session_kit_should_recreate.
#
# <workspace...> are exactly what the sandbox was created with, since the
# recreate has to reproduce them: a task's worktree plus the git metadata dir,
# or the main checkout alone for the workbench. <rebuild-hint> is the command
# that tears this sandbox down, quoted to the user when a change is skipped.
session_sync_kit() {
  local main_root="$1" sandbox="$2" kit_dir="$3" kit_hash="$4" hint="$5"
  shift 5

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

  session_kit_should_recreate "$sandbox" "$hint" || return 0

  info "Recreating sandbox '$sandbox' from the current Sandbox Kit"
  # The transcripts live only inside the container, so they have to come out
  # before it is destroyed. A failure here is reported but never stops the
  # recreate — see lib/transcripts.sh.
  transcripts_rescue "$sandbox" || true
  sandbox_remove "$sandbox"
  sandbox_create "$sandbox" "$kit_dir" "$@"

  kit_cache_write "$main_root" "$sandbox" "$kit_hash" || true
  success "Recreated '$sandbox' from the current Sandbox Kit"
}

# session_kit_should_recreate <sandbox> <rebuild-hint> — 0 to recreate, non-zero
# to leave it be.
#
# Honours TASK_AGENT_KIT_RECREATE (ask | yes | no). In `ask` mode with no
# terminal to ask at, the answer is no: recreating a sandbox unasked would throw
# away container state the user may still want, and skipping it only leaves the
# sandbox as it already was.
session_kit_should_recreate() {
  local sandbox="$1" hint="$2"

  case "$TASK_AGENT_KIT_RECREATE" in
    yes) return 0 ;;
    no)
      session_kit_kept "$sandbox" "TASK_AGENT_KIT_RECREATE=no." "$hint"
      return 1
      ;;
    ask) ;;
    *)
      die "Invalid TASK_AGENT_KIT_RECREATE: '$TASK_AGENT_KIT_RECREATE'" \
        "Use one of: ask (the default), yes, no."
      ;;
  esac

  warning "The Sandbox Kit changed since sandbox '$sandbox' was created."
  warning "Applying it recreates that sandbox from scratch, so anything that exists"
  warning "only inside the container is lost."
  warning "The agent's transcripts are copied to the host first, so they still"
  warning "reach /insights, but the session itself cannot be resumed afterwards."
  warning "The checkout on the host, its files and its commits are not affected."

  if [[ ! -t 0 ]]; then
    session_kit_kept "$sandbox" "Not asking, because stdin is not a terminal." "$hint"
    warning "  Set TASK_AGENT_KIT_RECREATE=yes to recreate without being asked."
    return 1
  fi

  if confirm "Recreate '$sandbox' from the current kit?"; then
    return 0
  fi

  session_kit_kept "$sandbox" "Not recreating it." "$hint"
  return 1
}

# session_kit_kept <sandbox> <reason> <rebuild-hint>
#
# Report that a changed kit was not applied. The digest is deliberately not
# recorded, so the next run offers again rather than treating the old kit as
# current.
session_kit_kept() {
  warning "$2 Sandbox '$1' keeps the kit it was created with."
  warning "To apply the current kit later, rebuild the sandbox:"
  warning "  $3   # then start it again"
}

# session_done <branch> [force]
#
# Remove the sandbox and the worktree for a branch, if they exist. The branch
# itself is always kept — this is teardown of the ephemeral parts of the
# branch -> worktree -> sandbox -> agent model, not branch deletion.
#
# Sandbox and worktree removal are independent: each is checked and removed
# on its own, so a worktree that was removed by hand can never block cleanup
# of an orphaned sandbox, or vice versa.
#
# <force> is the literal string `force`, from `task-agent --done --force`
# (issue #23). It reaches only worktree_remove: the sandbox is removed with
# `sbx rm --force` either way, and the branch is never touched by either.
session_done() {
  local branch="$1" force="${2:-}"

  git_require_git
  git_require_repo
  sandbox_require_cli

  # Validated up front, before anything is removed: an invalid setting must
  # cost a re-run, never a half-torn-down task.
  transcripts_validate_mode
  projectconfig_validate_mode

  git_validate_branch "$branch"

  local main_root
  main_root="$(git_main_repo_root)" || exit 1

  # Looked up before anything is removed: the main checkout is never a task's
  # worktree (issue #36), so if git reports it for this branch, only a sandbox
  # left over from before that rule can be torn down here — never the checkout.
  local worktree="" on_main=""
  if worktree="$(worktree_find_for_branch "$main_root" "$branch")"; then
    worktree_is_main_checkout "$main_root" "$worktree" && on_main=1
  else
    worktree=""
  fi

  if [[ -n "$on_main" && "$force" == "force" ]]; then
    die "--force is not valid here: '$branch' is checked out in the main checkout," \
      "which task-agent never removes:" \
      "  $main_root"
  fi

  local project sandbox
  project="$(naming_project_id "$main_root")"
  sandbox="$(naming_sandbox_name "$project" "$branch")"

  if sandbox_exists "$sandbox"; then
    # Last chance to get the agent's transcripts out: they exist only inside
    # the container. Deliberately not allowed to abort the teardown — a broken
    # rescue must never leave an undeletable sandbox behind.
    transcripts_rescue "$sandbox" || true
    info "Removing sandbox '$sandbox'"
    sandbox_remove "$sandbox"
  else
    info "No sandbox found for '$branch'"
  fi

  # Drop the applied-kit record either way: it describes a sandbox that is gone,
  # and a stale entry would otherwise claim a later sandbox of the same name
  # already has this kit.
  kit_cache_remove "$main_root" "$sandbox"

  if [[ -n "$on_main" ]]; then
    warning "'$branch' is checked out in the main checkout, which is never a task's worktree."
    warning "It was left untouched: $main_root"
    warning "To remove the workbench on it instead, run: task-agent --done --here"
  elif [[ -n "$worktree" ]]; then
    # Remove the seeded copies first, so they cannot be the untracked files
    # that make git refuse — that would make --force the habit rather than the
    # exception. Never allowed to block the teardown, and it can lose nothing:
    # a file it deletes is byte-identical to one still in the main repository.
    projectconfig_prune "$main_root" "$worktree" || true

    if [[ "$force" == "force" ]]; then
      warning "Discarding any uncommitted and untracked changes in: $worktree"
    fi
    info "Removing worktree: $worktree"
    worktree_remove "$main_root" "$worktree" "$force"
  else
    info "No worktree found for '$branch'"
  fi

  success "Branch '$branch' was kept."
}

# session_here <base>
#
# `task-agent --here`: the agent for the checkout the caller is standing in
# (issue #34). In the main checkout that is the project's workbench; inside a
# task's worktree it is that task, exactly as `task-agent <its branch>` — never
# a second sandbox on the same directory. <base> only reaches session_start,
# where it is ignored because the worktree's branch already exists.
session_here() {
  local base="$1"

  git_require_git
  git_require_repo
  sandbox_require_cli

  local main_root checkout
  main_root="$(git_main_repo_root)" || exit 1
  checkout="$(git_checkout_root)" || exit 1

  if [[ "$checkout" != "${main_root%/}" ]]; then
    local branch
    branch="$(session_here_branch "$main_root" "$checkout")" || exit 1
    info "Inside the worktree of '$branch': starting that task"
    session_start "$branch" "$base"
    return
  fi

  session_workbench_start "$main_root"
}

# session_here_branch <main-root> <checkout> — the branch of a linked worktree.
#
# Prints the bare branch name, or dies: a detached worktree has no branch, so
# there is no task it could belong to.
session_here_branch() {
  local main_root="$1" checkout="$2" ref
  ref="$(worktree_branch_at_path "$main_root" "$checkout")" ||
    die "This checkout is not a worktree git knows about: $checkout"
  [[ "$ref" != "detached" ]] ||
    die "This worktree has a detached HEAD, so it belongs to no task:" \
      "  $checkout" \
      "Check out a branch in it, or run --here from the main checkout."
  printf '%s' "${ref#refs/heads/}"
}

# session_workbench_start <main-root>
#
# Create or re-attach the workbench: one sandbox per project whose only
# workspace is the main checkout. No branch is created and no worktree added —
# the agent works on whatever the developer has checked out, beside their IDE.
#
# One workspace suffices because the main checkout's .git is inside it; the
# second workspace a task needs exists only to resolve a linked worktree's
# `gitdir:` pointer. The project's .claude/ is already there too, so there is
# nothing to seed.
session_workbench_start() {
  local main_root="$1"

  transcripts_validate_mode
  scaffold_require_kit "$main_root"

  local sandbox
  sandbox="$(naming_workbench_name "$(naming_project_id "$main_root")")"
  info "Workbench on the main checkout: $main_root"

  local kit_dir kit_hash
  kit_dir="$(scaffold_kit_dir "$main_root")"
  kit_hash="$(scaffold_kit_hash "$main_root")" || kit_hash=""

  if sandbox_exists "$sandbox"; then
    info "Reusing workbench '$sandbox'"
    session_sync_kit "$main_root" "$sandbox" "$kit_dir" "$kit_hash" \
      "task-agent --done --here" "$main_root"
  else
    info "Creating workbench '$sandbox'"
    sandbox_create "$sandbox" "$kit_dir" "$main_root"
    [[ -n "$kit_hash" ]] && kit_cache_write "$main_root" "$sandbox" "$kit_hash"
  fi

  sandbox_attach "$sandbox"
}

# session_workbench_done
#
# `task-agent --done --here`: remove the workbench sandbox, rescuing its
# transcripts first. The main checkout is never touched — there is no worktree
# to remove and no branch that belongs to the workbench.
#
# Inside a task's worktree this is refused rather than read as `--done
# <branch>`: that would delete the directory the caller's shell, and very
# likely their IDE, is standing in.
session_workbench_done() {
  git_require_git
  git_require_repo
  sandbox_require_cli

  transcripts_validate_mode

  local main_root checkout
  main_root="$(git_main_repo_root)" || exit 1
  checkout="$(git_checkout_root)" || exit 1

  if [[ "$checkout" != "${main_root%/}" ]]; then
    local branch
    branch="$(session_here_branch "$main_root" "$checkout")" || exit 1
    die "--done --here removes the workbench, and this is the worktree of a task." \
      "Removing it would delete the directory you are standing in. Instead, run" \
      "from the main checkout ($main_root):" \
      "  task-agent --done $branch"
  fi

  local sandbox
  sandbox="$(naming_workbench_name "$(naming_project_id "$main_root")")"

  if sandbox_exists "$sandbox"; then
    transcripts_rescue "$sandbox" || true
    info "Removing workbench '$sandbox'"
    sandbox_remove "$sandbox"
  else
    info "No workbench found for this project"
  fi

  kit_cache_remove "$main_root" "$sandbox"

  success "The main checkout was not touched."
}

# session_fork <branch>
#
# `task-agent <branch> --fork` (issue #36): an ordinary task on the derived
# branch `<branch>-fork`, created from the tip of <branch>. It is how to run a
# parallel task on top of a branch — including the one checked out in the main
# checkout, which session_start refuses as a task of its own.
#
# The fork is a task like any other. Nothing records what it was forked from
# (architectural rule 1), an existing fork is reused untouched rather than
# re-synced onto <branch>'s new tip (rule 4), and uncommitted changes in the
# main checkout are not part of it — they are reported, never stashed, copied
# or committed.
session_fork() {
  local branch="$1"

  git_require_git
  git_require_repo
  sandbox_require_cli

  git_validate_branch "$branch"
  local fork
  fork="$(naming_fork_branch "$branch")"
  git_validate_branch "$fork"

  local main_root
  main_root="$(git_main_repo_root)" || exit 1

  # Checked here rather than left to git_resolve_base: a missing base there
  # reads as a --base problem, and --fork has no --base. <branch> itself is
  # never created as a side effect.
  git_local_branch_exists "$main_root" "$branch" ||
    git_remote_branch_exists "$main_root" "$branch" ||
    die "'$branch' does not exist locally or as origin/$branch, so there is nothing to fork."

  if git_local_branch_exists "$main_root" "$fork"; then
    info "Reusing the existing fork '$fork' as it is; it is not synced with '$branch'."
  fi

  local registered
  if registered="$(worktree_find_for_branch "$main_root" "$branch")" &&
    worktree_is_main_checkout "$main_root" "$registered" &&
    [[ -n "$(git -C "$main_root" status --porcelain 2>/dev/null)" ]]; then
    info "The main checkout has uncommitted changes. They are not part of the fork,"
    info "which starts from the last commit on '$branch'."
  fi

  # The base is explicit, never HEAD (architectural rule 3): <branch> itself.
  session_start "$fork" "$branch"
}
