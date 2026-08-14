#!/usr/bin/env bash
# Git repository and branch operations for agent-cli.
#
# Deliberately knows nothing about worktree paths or the sandbox runtime.

if [[ -n "${AGENT_GIT_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_GIT_SH_LOADED=1

# git_require_git — the tool is useless without git on PATH.
git_require_git() {
  command -v git >/dev/null 2>&1 ||
    die "git is not installed or not on PATH." \
      "Install git and try again."
}

# git_require_repo — refuse to do anything outside a git repository.
git_require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "Not inside a git repository." \
      "Run task-agent from within a git repository."
}

# git_main_repo_root
#
# Absolute path of the *main* repository, correct when invoked from the main
# checkout, from a linked worktree, or from any subdirectory of either.
#
# `--git-common-dir` (not `--git-dir`) is the key: inside a linked worktree
# `--git-dir` points at `<main>/.git/worktrees/<id>`, whereas the common dir
# always points at the main `<main>/.git`.
git_main_repo_root() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    die "Could not resolve the git common directory." \
      "This needs git 2.31 or newer (for --path-format)."

  [[ -n "$common_dir" ]] ||
    die "Could not resolve the git common directory."

  common_dir="${common_dir%/}"

  if [[ "${common_dir##*/}" == ".git" ]]; then
    printf '%s' "${common_dir%/.git}"
  else
    # Bare repository: the common dir *is* the repository root. Linked worktrees
    # off a bare repo are supported by git, and the sandbox mount below still
    # works because we mount the common dir itself.
    printf '%s' "$common_dir"
  fi
}

# git_git_metadata_dir <main-repo-root>
#
# The directory that a linked worktree's `.git` file ultimately points into.
# For a normal clone that is `<root>/.git`; for a bare repo it is the root.
# This is the path that must be visible inside the sandbox at its host path for
# git to work in a linked worktree.
git_git_metadata_dir() {
  local root="${1%/}"
  if [[ -d "$root/.git" ]]; then
    printf '%s' "$root/.git"
  else
    printf '%s' "$root"
  fi
}

# git_validate_branch <branch>
#
# Reject anything git would refuse, plus two shapes git's own validator accepts
# but that are hostile as identifiers:
#   - a leading `-`, which would be parsed as an option by later commands
#   - `@{`, which is revision shorthand (`@{-1}`, `@{upstream}`) rather than a name
#
# Runs before any directory, branch or sandbox is created.
git_validate_branch() {
  local branch="$1"

  [[ -n "$branch" ]] ||
    die "Branch name must not be empty."

  [[ "$branch" != -* ]] ||
    die "Invalid branch name: '$branch'" \
      "A branch name must not start with '-'."

  [[ "$branch" != *"@{"* ]] ||
    die "Invalid branch name: '$branch'" \
      "'@{' is git revision shorthand, not a branch name."

  git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
    die "Invalid branch name: '$branch'" \
      "See 'git check-ref-format --help' for the rules."
}

# git_local_branch_exists <repo> <branch>
git_local_branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

# git_remote_branch_exists <repo> <branch> [remote]
git_remote_branch_exists() {
  local remote="${3:-origin}"
  git -C "$1" show-ref --verify --quiet "refs/remotes/$remote/$2"
}

# git_resolve_base <repo> <base> [remote]
#
# Print the ref that a new branch should be created from:
#   local refs/heads/<base>  ->  <base>
#   else refs/remotes/<remote>/<base>  ->  <remote>/<base>
#   else fail
#
# It deliberately never falls back to HEAD. The predecessor created new branches
# from the caller's ambient HEAD, which made the result depend on whichever
# branch the user happened to be standing on.
git_resolve_base() {
  local repo="$1" base="$2" remote="${3:-origin}"

  if git_local_branch_exists "$repo" "$base"; then
    printf '%s' "$base"
    return 0
  fi

  if git_remote_branch_exists "$repo" "$base" "$remote"; then
    printf '%s/%s' "$remote" "$base"
    return 0
  fi

  die "Base branch '$base' does not exist locally or as $remote/$base." \
    "Fetch it first, or pass an existing branch with --base."
}

# git_ensure_branch <repo> <branch> <base> [remote]
#
# Make sure <branch> exists locally, then print how it was obtained:
#   existing  — already present locally; left completely untouched
#   tracking  — created from <remote>/<branch> with tracking
#   created   — created from the resolved <base>
#
# An existing local branch is never reset, rebased, or merged with the base;
# --base only matters when a branch has to be created.
git_ensure_branch() {
  local repo="$1" branch="$2" base="$3" remote="${4:-origin}"

  if git_local_branch_exists "$repo" "$branch"; then
    printf 'existing'
    return 0
  fi

  if git_remote_branch_exists "$repo" "$branch" "$remote"; then
    git -C "$repo" branch --track "$branch" "$remote/$branch" >/dev/null 2>&1 ||
      die "Failed to create local branch '$branch' tracking $remote/$branch."
    printf 'tracking'
    return 0
  fi

  local base_ref
  base_ref="$(git_resolve_base "$repo" "$base" "$remote")" || exit 1

  git -C "$repo" branch "$branch" "$base_ref" >/dev/null 2>&1 ||
    die "Failed to create branch '$branch' from '$base_ref'."
  printf 'created'
}
