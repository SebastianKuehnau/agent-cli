#!/usr/bin/env bash
# Git worktree location and lifecycle for agent-cli.
#
# Requires lib/naming.sh (for the worktree identifier) and lib/logging.sh.

if [[ -n "${AGENT_WORKTREE_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_WORKTREE_SH_LOADED=1

# worktree_root <main-repo-root>
#
# Sibling directory next to the main repository:
#   /Users/me/projects/my-app  ->  /Users/me/projects/my-app-worktrees
#
# A sibling (rather than a directory inside the repo) keeps the worktrees out of
# the repository's own ignore rules, IDE indexing and greps.
worktree_root() {
  local main_root="${1%/}"
  local parent="${main_root%/*}"
  local name="${main_root##*/}"

  # A repository directly at the filesystem root has no parent segment.
  [[ "$parent" == "$main_root" || -z "$parent" ]] && parent=""

  printf '%s/%s-worktrees' "$parent" "$name"
}

# worktree_path <main-repo-root> <branch>
#
# Deterministic path for a branch's worktree. The same inputs always produce the
# same path, and colliding slugs (feature/x vs feature-x) get distinct paths
# because the identifier carries a hash of the raw branch name.
worktree_path() {
  printf '%s/%s' "$(worktree_root "$1")" "$(naming_worktree_id "$2")"
}

# worktree_find_for_branch <main-repo-root> <branch>
#
# Print the path of the worktree git has registered for <branch>, or nothing.
#
# `git worktree list --porcelain` emits one attribute per line as
# `<key> <value>`, blank-line separated per worktree. Taking the whole remainder
# of the line as the value is what makes paths containing spaces work — the
# predecessor split on whitespace and silently failed to find any such worktree.
#
# Known limitation: paths containing a literal newline are not supported.
worktree_find_for_branch() {
  local main_root="$1" branch="$2"
  local wanted="refs/heads/$branch"
  local current="" line

  while IFS= read -r line; do
    case "$line" in
      "worktree "*) current="${line#worktree }" ;;
      "branch "*)
        if [[ "${line#branch }" == "$wanted" ]]; then
          printf '%s' "$current"
          return 0
        fi
        ;;
      "") current="" ;;
    esac
  done < <(git -C "$main_root" worktree list --porcelain 2>/dev/null)

  return 1
}

# worktree_branch_at_path <main-repo-root> <path>
#
# Print the branch ref registered for a worktree path, or nothing if that path
# is not a registered worktree.
worktree_branch_at_path() {
  local main_root="$1" wanted="${2%/}"
  local current="" line

  while IFS= read -r line; do
    case "$line" in
      "worktree "*) current="${line#worktree }" ;;
      "branch "*)
        if [[ "${current%/}" == "$wanted" ]]; then
          printf '%s' "${line#branch }"
          return 0
        fi
        ;;
      "detached")
        if [[ "${current%/}" == "$wanted" ]]; then
          printf 'detached'
          return 0
        fi
        ;;
      "") current="" ;;
    esac
  done < <(git -C "$main_root" worktree list --porcelain 2>/dev/null)

  return 1
}

# worktree_ensure <main-repo-root> <branch>
#
# Print the path of the worktree to use for <branch>, creating it if needed.
#
# Git's registered worktree information is the source of truth: if the branch
# already has a worktree somewhere else (an older layout, or a manually created
# one), that path is reused rather than adding a second worktree for the same
# branch — which git would refuse anyway.
worktree_ensure() {
  local main_root="$1" branch="$2"

  local existing
  if existing="$(worktree_find_for_branch "$main_root" "$branch")"; then
    printf '%s' "$existing"
    return 0
  fi

  local path
  path="$(worktree_path "$main_root" "$branch")"

  # The derived path may already be registered to a different branch — refuse
  # rather than letting `git worktree add` fail with a less obvious message.
  local occupant
  if occupant="$(worktree_branch_at_path "$main_root" "$path")"; then
    die "Worktree path is already registered to a different branch:" \
      "  path:   $path" \
      "  branch: ${occupant#refs/heads/}" \
      "Remove that worktree, or use a different branch name."
  fi

  if [[ -e "$path" ]]; then
    die "Worktree path already exists but is not a registered git worktree:" \
      "  $path" \
      "Remove or rename it, then run agent-task again."
  fi

  local root
  root="$(worktree_root "$main_root")"
  mkdir -p "$root" ||
    die "Could not create the worktree directory: $root"

  git -C "$main_root" worktree add "$path" "$branch" >&2 ||
    die "Failed to create the worktree for '$branch' at:" \
      "  $path"

  printf '%s' "$path"
}

# worktree_remove <main-repo-root> <path>
#
# Remove a worktree. Deliberately never passes --force: git already refuses
# when the worktree has modified or untracked files, which is the only real
# hazard here. Unpushed commits are not a hazard at all, because agent-cli
# never deletes the branch — its ref keeps them reachable regardless of
# whether the worktree that once held them still exists.
worktree_remove() {
  local main_root="$1" path="$2"

  git -C "$main_root" worktree remove "$path" >&2 ||
    die "Failed to remove the worktree at:" \
      "  $path" \
      "It may contain uncommitted or untracked changes. Commit, stash, or" \
      "remove them, then run agent-task --done again." \
      "" \
      "To remove it anyway and discard those changes, run:" \
      "  git -C '$main_root' worktree remove --force '$path'"
}
