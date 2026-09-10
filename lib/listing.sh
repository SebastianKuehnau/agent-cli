#!/usr/bin/env bash
# `task-agent --list` — what tasks exist right now (issue #25).
#
# Nothing here reads anything task-agent wrote earlier. A task's existence is
# rediscovered exactly the way session_start and session_done rediscover it:
# `git worktree list --porcelain` for the worktrees, `sbx ls -q` for the
# sandboxes, and naming_sandbox_name to relate the two. That is what keeps this
# a *view* rather than a second source of truth (architectural rule 1) — and it
# is also why the listing can show a half-torn-down task at all: the two sides
# are looked up independently, so one missing never hides the other.
#
# The relation only runs one way. A sandbox name ends in a hash of the raw
# branch name, which cannot be inverted, so a sandbox with no matching worktree
# is reported as itself and never guessed back into a branch.
#
# State is kept in globals rather than passed by nameref, and membership is a
# loop rather than an associative-array lookup, because both of those are bash
# 4 features and nothing else in agent-cli uses one — macOS still ships bash
# 3.2, and a tool whose only hard dependency is bash must run on it.
#
# The table goes to **stdout**: it is data, like --version, and a listing that
# cannot be piped into grep is half a listing. Everything this module says
# *about* the listing still goes to stderr through lib/logging.sh.

if [[ -n "${AGENT_LISTING_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_LISTING_SH_LOADED=1

# Shown in a column when the other side of a task is missing.
readonly AGENT_LISTING_NONE="-"

# Every sandbox `sbx ls -q` reports, read once per run.
declare -a AGENT_LISTING_KNOWN=()

# One entry per task, in step: branch, its sandbox, its worktree. Three parallel
# arrays rather than delimited lines, because a worktree path may contain spaces
# and an array element cannot be mis-split.
declare -a AGENT_LISTING_BRANCHES=()
declare -a AGENT_LISTING_SANDBOXES=()
declare -a AGENT_LISTING_PATHS=()

# listing_run <main-repo-root> [all]
#
# <all> is the literal string `all` when `--list --all` was given: the machine's
# other sandboxes are then listed too, below the project's own table.
listing_run() {
  local main_root="$1" all="${2:-}"

  local project
  project="$(naming_project_id "$main_root")"

  listing_load_sandboxes
  listing_collect_tasks "$main_root" "$project"
  listing_print_table

  if ((${#AGENT_LISTING_BRANCHES[@]} == 0)); then
    info "No tasks for this project yet. Start one with: task-agent <branch>"
  fi

  if [[ "$all" == "all" ]]; then
    listing_print_others
  fi

  return 0
}

# listing_load_sandboxes
#
# `sbx ls -q` once, not once per branch: this is a listing, and the number of
# branches with worktrees is unbounded.
listing_load_sandboxes() {
  AGENT_LISTING_KNOWN=()

  # Captured before it is split, and the status checked: a listing that shows
  # every task with a missing sandbox because the daemon is down looks exactly
  # like a project whose sandboxes were all removed by hand. A view that cannot
  # tell those apart must stop rather than print the wrong one.
  local out status line
  out="$(sandbox_list_names)"
  status=$?
  ((status == 0)) || sandbox_die_unreachable "$status"

  while IFS= read -r line; do
    [[ -n "$line" ]] && AGENT_LISTING_KNOWN+=("$line")
  done <<<"$out"
}

# listing_known_has <sandbox-name> — does the runtime report this sandbox?
listing_known_has() {
  ((${#AGENT_LISTING_KNOWN[@]} == 0)) && return 1
  local item
  for item in "${AGENT_LISTING_KNOWN[@]}"; do
    [[ "$item" == "$1" ]] && return 0
  done
  return 1
}

# listing_collected_has <sandbox-name> — is it already a row in the table?
listing_collected_has() {
  ((${#AGENT_LISTING_SANDBOXES[@]} == 0)) && return 1
  local item
  for item in "${AGENT_LISTING_SANDBOXES[@]}"; do
    [[ "$item" == "$1" ]] && return 0
  done
  return 1
}

# listing_collect_tasks <main-repo-root> <project>
#
# One row per task:
#
#   - every linked worktree that has a branch, with the sandbox that branch
#     would use, or "-" when no such sandbox exists;
#   - every sandbox carrying this project's prefix that no such worktree
#     claimed — an orphan, with "-" for branch and worktree.
#
# The main worktree is skipped: it is the repository the user is standing in,
# not a task. A detached worktree is skipped too — a task is identified by a
# branch, so there is no sandbox name to relate it to.
#
# Parsing is line-oriented and takes the whole remainder of the line as the
# value, for the same reason worktree_find_for_branch does: splitting on
# whitespace loses every path containing a space.
listing_collect_tasks() {
  local main_root="$1" project="$2"

  AGENT_LISTING_BRANCHES=()
  AGENT_LISTING_SANDBOXES=()
  AGENT_LISTING_PATHS=()

  local current="" branch line sandbox
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) current="${line#worktree }" ;;
      "branch "*)
        [[ "${current%/}" == "${main_root%/}" ]] && continue
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        sandbox="$(naming_sandbox_name "$project" "$branch")"
        AGENT_LISTING_BRANCHES+=("$branch")
        AGENT_LISTING_PATHS+=("$current")
        if listing_known_has "$sandbox"; then
          AGENT_LISTING_SANDBOXES+=("$sandbox")
        else
          # Recorded as absent, not as unnamed: the row still says which branch
          # it is, and the sandbox for it simply is not there right now.
          AGENT_LISTING_SANDBOXES+=("$AGENT_LISTING_NONE")
        fi
        ;;
      "") current="" ;;
    esac
  done < <(git -C "$main_root" worktree list --porcelain 2>/dev/null)

  ((${#AGENT_LISTING_KNOWN[@]} == 0)) && return 0

  # Orphans: this project's sandboxes that no worktree above accounted for.
  # Two projects whose directory names slug alike share a prefix — the same
  # ambiguity naming_sandbox_name already has, not a new one.
  local prefix="agent-$project-"
  for sandbox in "${AGENT_LISTING_KNOWN[@]}"; do
    [[ "$sandbox" == "$prefix"* ]] || continue
    listing_collected_has "$sandbox" && continue
    AGENT_LISTING_BRANCHES+=("$AGENT_LISTING_NONE")
    AGENT_LISTING_SANDBOXES+=("$sandbox")
    AGENT_LISTING_PATHS+=("$AGENT_LISTING_NONE")
  done
}

# listing_print_table
#
# Columns are padded to the widest value actually present rather than to a fixed
# width, so short names do not print a screenful of spaces and a long one is
# never truncated. The last column is not padded, so a path stays exactly the
# path.
listing_print_table() {
  local -i bw=6 nw=7 # len("BRANCH"), len("SANDBOX")
  local i

  if ((${#AGENT_LISTING_BRANCHES[@]} > 0)); then
    for i in "${!AGENT_LISTING_BRANCHES[@]}"; do
      ((${#AGENT_LISTING_BRANCHES[i]} > bw)) && bw=${#AGENT_LISTING_BRANCHES[i]}
      ((${#AGENT_LISTING_SANDBOXES[i]} > nw)) && nw=${#AGENT_LISTING_SANDBOXES[i]}
    done
  fi

  printf '%-*s  %-*s  %s\n' "$bw" "BRANCH" "$nw" "SANDBOX" "WORKTREE"

  ((${#AGENT_LISTING_BRANCHES[@]} == 0)) && return 0
  for i in "${!AGENT_LISTING_BRANCHES[@]}"; do
    printf '%-*s  %-*s  %s\n' \
      "$bw" "${AGENT_LISTING_BRANCHES[i]}" \
      "$nw" "${AGENT_LISTING_SANDBOXES[i]}" \
      "${AGENT_LISTING_PATHS[i]}"
  done
}

# listing_print_others
#
# The rest of the machine: every sandbox `sbx ls -q` reports that the table
# above did not already account for. They may belong to another project, to a
# task-agent from before the current naming scheme, or to no task-agent at all
# — task-agent cannot tell them apart, and deliberately does not guess.
listing_print_others() {
  local -a others=()
  local sandbox

  if ((${#AGENT_LISTING_KNOWN[@]} > 0)); then
    for sandbox in "${AGENT_LISTING_KNOWN[@]}"; do
      listing_collected_has "$sandbox" && continue
      others+=("$sandbox")
    done
  fi

  printf '\nOTHER SANDBOXES\n'

  if ((${#others[@]} == 0)); then
    printf '%s\n' "$AGENT_LISTING_NONE"
    return 0
  fi

  printf '%s\n' "${others[@]}"
}
