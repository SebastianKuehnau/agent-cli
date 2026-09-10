#!/usr/bin/env bash
# Carry the project's own .claude configuration into a task's worktree
# (issue #24).
#
# The problem is git's, not the sandbox's. `git worktree add` checks out
# *tracked* files, and a project's `.claude/` is very often untracked — either
# entirely, or just `settings.local.json`, which is personal by convention. So a
# freshly created worktree has no `.claude/` at all, the sandbox mounts that
# worktree at the same absolute path it has on the host, and the agent inside
# starts with none of the project configuration the same agent has when it runs
# on the main checkout.
#
# There is nowhere else to put it. Claude Code reads project settings from
# `<cwd>/.claude`, so the files have to be inside the worktree; mounting the
# main repository's `.claude` elsewhere would put them at a path nothing reads.
#
# Two operations, deliberately symmetric:
#
#   projectconfig_seed   fills gaps in <worktree>/.claude from <main-root>/.claude
#   projectconfig_prune  removes the copies again, before the worktree is
#                        removed, so that they cannot be what makes
#                        `git worktree remove` refuse
#
# Neither is state. Both re-derive what to do by comparing the two directories
# on the spot, so nothing is written down about which files were copied
# (architectural rule 1) and a copy the user has since edited is recognised as
# theirs by being different.

if [[ -n "${AGENT_PROJECTCONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_PROJECTCONFIG_SH_LOADED=1

# Whether to carry the project's .claude into a task's worktree: yes (the
# default) or no. Same vocabulary and same strictness as TASK_AGENT_KIT_RECREATE
# and TASK_AGENT_RESCUE_TRANSCRIPTS — a typo must not silently switch it off.
: "${TASK_AGENT_PROJECT_CONFIG:=yes}"

# The directory carried, relative to the repository root. One name, not a list:
# this is Claude Code's project configuration directory, not a general-purpose
# file-copying feature.
readonly AGENT_PROJECT_CONFIG_DIR=".claude"

# projectconfig_validate_mode
#
# Reject an invalid TASK_AGENT_PROJECT_CONFIG, early, before anything has been
# created or removed.
projectconfig_validate_mode() {
  case "$TASK_AGENT_PROJECT_CONFIG" in
    yes | no) return 0 ;;
    *)
      die "Invalid TASK_AGENT_PROJECT_CONFIG: '$TASK_AGENT_PROJECT_CONFIG'" \
        "Use one of: yes (the default), no."
      ;;
  esac
}

# projectconfig_relative_files <dir>
#
# Every regular file under <dir>, as a path relative to it, NUL-separated.
# NUL rather than newline because a configuration directory is the user's and
# may hold anything; the caller reads it with `read -d ''`.
projectconfig_relative_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  (cd -P "$dir" 2>/dev/null && find . -type f -print0) 2>/dev/null
}

# projectconfig_seed <main-repo-root> <worktree>
#
# Copy the main repository's .claude into the worktree, filling gaps only: a
# file that already exists in the worktree is never touched, whether it got
# there by being tracked, by an earlier seed, or by the agent writing it. That
# is what makes this safe to run on every start rather than only on the run that
# created the worktree — a task started again picks up configuration added since,
# and never loses a change the agent made.
#
# Deliberately not a sync: nothing is deleted here, and nothing is overwritten.
projectconfig_seed() {
  local main_root="$1" worktree="$2"

  [[ "$TASK_AGENT_PROJECT_CONFIG" == "yes" ]] || return 0

  local source_dir="$main_root/$AGENT_PROJECT_CONFIG_DIR"
  local target_dir="$worktree/$AGENT_PROJECT_CONFIG_DIR"

  [[ -d "$source_dir" ]] || return 0
  # A worktree is always a different directory from the main repository, but
  # copying a directory onto itself would be silently destructive, so refuse
  # rather than rely on that.
  [[ "${worktree%/}" != "${main_root%/}" ]] || return 0

  local rel copied=0 failed=0
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    [[ -e "$target_dir/$rel" ]] && continue

    if mkdir -p "$(dirname "$target_dir/$rel")" 2>/dev/null &&
      cp -p "$source_dir/$rel" "$target_dir/$rel" 2>/dev/null; then
      copied=$((copied + 1))
    else
      failed=$((failed + 1))
      warning "Could not copy $AGENT_PROJECT_CONFIG_DIR/$rel into the worktree"
    fi
  done < <(projectconfig_relative_files "$source_dir")

  if ((copied > 0)); then
    info "Copied $copied file(s) from $AGENT_PROJECT_CONFIG_DIR/ into the worktree"
  fi

  ((failed == 0))
}

# projectconfig_prune <main-repo-root> <worktree>
#
# Undo the seeding, immediately before the worktree is removed.
#
# Without this the copies would be untracked files in the worktree, and git
# refuses to remove a worktree that has any — so every `--done` of a project
# with an untracked `.claude/` would need `--force`, which would teach the user
# to reach for `--force` habitually and lose real work with it.
#
# Three conditions before a file is deleted, all of them re-derived rather than
# remembered:
#
#   1. the main repository has a file at the same relative path;
#   2. the two are byte-identical, so nothing the agent changed is thrown away;
#   3. git does not track it in the worktree, so a committed file is never
#      touched even when it happens to match.
#
# A file deleted here is by definition still in the main repository, so this
# cannot lose anything even if the worktree removal it precedes then fails.
# Like the transcript rescue, it must never block teardown: it reports and
# returns non-zero, and the caller carries on.
projectconfig_prune() {
  local main_root="$1" worktree="$2"

  local source_dir="$main_root/$AGENT_PROJECT_CONFIG_DIR"
  local target_dir="$worktree/$AGENT_PROJECT_CONFIG_DIR"

  [[ -d "$source_dir" && -d "$target_dir" ]] || return 0
  [[ "${worktree%/}" != "${main_root%/}" ]] || return 0

  local rel failed=0
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    [[ -f "$target_dir/$rel" ]] || continue
    cmp -s "$source_dir/$rel" "$target_dir/$rel" || continue
    git -C "$worktree" ls-files --error-unmatch -- \
      "$AGENT_PROJECT_CONFIG_DIR/$rel" >/dev/null 2>&1 && continue

    rm -f -- "$target_dir/$rel" 2>/dev/null || failed=$((failed + 1))
  done < <(projectconfig_relative_files "$source_dir")

  # Bottom-up, and only the empty ones: a directory the agent left something in
  # stays, and so does .claude itself when it still holds anything.
  find "$target_dir" -depth -type d -exec rmdir {} + 2>/dev/null || true

  ((failed == 0))
}
