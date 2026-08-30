#!/usr/bin/env bash
# Rescue the agent's transcripts out of a sandbox before it is destroyed.
#
# Every sandbox has its own ~/.claude inside the container, so an agent's
# session transcripts (projects/<slug>/<session-id>.jsonl) exist only there.
# Claude Code's /insights builds its report by scanning the *host's*
# $CLAUDE_CONFIG_DIR/projects, so without this module all work done through
# task-agent is invisible to it: the sandbox is exactly where the transcripts
# are, and exactly what --done deletes.
#
# One entry point, transcripts_rescue, called immediately before every
# sandbox_remove in lib/session.sh.
#
# Command construction is kept separate from execution, as in lib/sandbox.sh:
# the transcripts_build_*_argv functions only fill AGENT_SBX_ARGV, so the argv
# can be asserted element by element with no Docker involved.
#
# Note this runs in the opposite direction to what architectural rule 9
# forbids: sandbox -> host, transcripts only, never credentials. See the rule's
# own wording in CLAUDE.md.

if [[ -n "${AGENT_TRANSCRIPTS_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_TRANSCRIPTS_SH_LOADED=1

# Whether to rescue transcripts before a sandbox is destroyed: yes (the
# default) or no. Same vocabulary and same strictness as
# TASK_AGENT_KIT_RECREATE — a typo must not silently switch the feature off.
: "${TASK_AGENT_RESCUE_TRANSCRIPTS:=yes}"

# The listing is run by the sandbox's own shell so that $CLAUDE_CONFIG_DIR and
# $HOME are resolved *inside* the container. A kit can set CLAUDE_CONFIG_DIR
# (kits carry environment variables), and hardcoding ~/.claude would make the
# rescue silently do nothing for such a project.
#
# -mindepth 2 -maxdepth 2 on purpose: that is exactly projects/<slug>/*.jsonl.
# It skips the subdirectories (memory/, tool-results/, subagent transcripts),
# which /insights does not read either.
#
# Single-quoted at every level: none of this may be expanded on the host.
# shellcheck disable=SC2016  # not expanding here is the entire point.
readonly AGENT_TRANSCRIPTS_LIST_SCRIPT='d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; [ -d "$d" ] || exit 0; find "$d" -mindepth 2 -maxdepth 2 -type f -name "*.jsonl"'

# transcripts_validate_mode
#
# Reject an invalid TASK_AGENT_RESCUE_TRANSCRIPTS. Called early — before
# anything has been created or destroyed — so a typo costs a re-run, never a
# half-torn-down task. Treating it as "no" would switch the rescue off exactly
# for the user who tried to configure it.
transcripts_validate_mode() {
  case "$TASK_AGENT_RESCUE_TRANSCRIPTS" in
    yes | no) return 0 ;;
    *)
      die "Invalid TASK_AGENT_RESCUE_TRANSCRIPTS: '$TASK_AGENT_RESCUE_TRANSCRIPTS'" \
        "Use one of: yes (the default), no."
      ;;
  esac
}

# transcripts_host_projects_dir
#
# Where /insights looks on the host. Resolved the same way Claude Code does.
transcripts_host_projects_dir() {
  printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# transcripts_build_list_argv <sandbox>
#
# `sbx exec` starts the sandbox first if it is stopped. That is accepted: it is
# the only way to read files out of a container, and a stopped sandbox is the
# normal state at --done time — the agent has usually exited by then.
transcripts_build_list_argv() {
  AGENT_SBX_ARGV=(sbx exec "$1" sh -c "$AGENT_TRANSCRIPTS_LIST_SCRIPT")
}

# transcripts_build_copy_argv <sandbox> <remote-file> <dest-dir>
#
# `sbx cp SRC DST` requires exactly one side to be SANDBOX:PATH. The
# destination is a directory that already exists, so the file is placed inside
# it under its own name.
transcripts_build_copy_argv() {
  AGENT_SBX_ARGV=(sbx cp "$1:$2" "$3/")
}

# transcripts_is_transcript_path <line> — a plausible listing line?
#
# `sbx exec` may print progress of its own (it starts a stopped sandbox before
# running the command), and that noise arrives on the same stream as find's
# output. Only absolute paths ending in .jsonl are taken as results; anything
# else is ignored rather than turned into a bogus copy.
transcripts_is_transcript_path() {
  [[ "$1" == /*.jsonl ]]
}

# transcripts_list <sandbox>
#
# Print one absolute in-sandbox transcript path per line, and return the exit
# status of the `sbx exec` that produced them. The output is captured before
# it is split so that status is not swallowed by a pipeline or a process
# substitution — a sandbox that cannot be reached at all must be reportable.
#
# Splitting is line-oriented, taking the whole line as the value, so a path
# containing spaces survives.
transcripts_list() {
  local out status line
  transcripts_build_list_argv "$1"
  out="$("${AGENT_SBX_ARGV[@]}" 2>/dev/null)"
  status=$?

  while IFS= read -r line; do
    transcripts_is_transcript_path "$line" && printf '%s\n' "$line"
  done <<<"$out"

  return "$status"
}

# transcripts_copy_one <sandbox> <remote-file> <host-projects-dir>
#
# Copy one transcript to <host-projects-dir>/<slug>/, atomically: into a
# temporary directory alongside the destination first, then mv into place. Same
# reasoning as kit_cache_write — an interrupted copy must not leave a truncated
# .jsonl in the user's ~/.claude/projects, where /insights would read it.
transcripts_copy_one() {
  local sandbox="$1" remote="$2" host_projects="$3"
  local slug base dest tmp

  # <...>/projects/<slug>/<session>.jsonl
  base="${remote##*/}"
  slug="${remote%/*}"
  slug="${slug##*/}"
  dest="$host_projects/$slug"

  mkdir -p "$dest" 2>/dev/null || return 1
  tmp="$(mktemp -d "$dest/.rescue.XXXXXX" 2>/dev/null)" || return 1

  # stdout is dropped, stderr is not: if sbx refuses, its own message is the
  # only thing that explains why, exactly as with sandbox_create/sandbox_remove.
  transcripts_build_copy_argv "$sandbox" "$remote" "$tmp"
  if "${AGENT_SBX_ARGV[@]}" >/dev/null &&
    [[ -f "$tmp/$base" ]] &&
    mv -- "$tmp/$base" "$dest/$base"; then
    rmdir -- "$tmp" 2>/dev/null || rm -rf -- "$tmp"
    return 0
  fi

  rm -rf -- "$tmp"
  return 1
}

# transcripts_rescue <sandbox>
#
# Copy the sandbox's transcripts to the host. Returns non-zero when something
# could not be rescued, but callers must carry on regardless: a broken rescue
# must never be able to leave an undeletable sandbox behind.
transcripts_rescue() {
  local sandbox="$1"

  [[ "$TASK_AGENT_RESCUE_TRANSCRIPTS" == "yes" ]] || return 0

  local host_projects
  host_projects="$(transcripts_host_projects_dir)"

  local -a files=()
  local line listing listed=0
  listing="$(transcripts_list "$sandbox")" || listed=1
  while IFS= read -r line; do
    [[ -n "$line" ]] && files+=("$line")
  done <<<"$listing"

  if ((listed != 0)); then
    warning "Could not list the agent transcripts in '$sandbox'."
  fi

  if ((${#files[@]} == 0)); then
    ((listed == 0)) && return 0
    transcripts_rescue_failed "$sandbox" "an unknown number of transcripts"
    return 1
  fi

  info "Rescuing ${#files[@]} agent transcript(s) from '$sandbox' to $host_projects"

  local file failed=0 copied=0
  for file in "${files[@]}"; do
    if transcripts_copy_one "$sandbox" "$file" "$host_projects"; then
      copied=$((copied + 1))
    else
      failed=$((failed + 1))
      warning "Could not rescue $file"
    fi
  done

  if ((failed > 0)); then
    transcripts_rescue_failed "$sandbox" "$failed transcript(s)"
    return 1
  fi

  success "Rescued $copied agent transcript(s) from '$sandbox'"
}

# transcripts_rescue_failed <sandbox> <what>
#
# Report a rescue that did not fully succeed, and name the commands that still
# reach the files.
#
# The wording is deliberately conditional. The caller removes the sandbox
# immediately afterwards and is not allowed to stop for this, so the hint is
# only actionable when the sandbox happens to survive — most plausibly because
# its removal failed too. Promising otherwise would be a lie.
transcripts_rescue_failed() {
  warning "Could not rescue $2 from '$1' — removing the sandbox loses them."
  warning "If the sandbox is still there afterwards, copy them by hand:"
  warning "  sbx exec $1 sh -c 'ls \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}\"/projects/*/*.jsonl'"
  warning "  sbx cp $1:<path> $(transcripts_host_projects_dir)/<slug>/"
}
