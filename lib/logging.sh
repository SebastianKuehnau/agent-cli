#!/usr/bin/env bash
# Logging primitives for agent-cli.
#
# Everything goes to stderr so that a command's real output (if any) stays clean
# on stdout and remains pipeable.

if [[ -n "${AGENT_LOGGING_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_LOGGING_SH_LOADED=1

# Colour only when stderr is a terminal and the user has not opted out.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly AGENT_C_RESET=$'\033[0m'
  readonly AGENT_C_DIM=$'\033[2m'
  readonly AGENT_C_GREEN=$'\033[32m'
  readonly AGENT_C_YELLOW=$'\033[33m'
  readonly AGENT_C_RED=$'\033[31m'
else
  readonly AGENT_C_RESET=""
  readonly AGENT_C_DIM=""
  readonly AGENT_C_GREEN=""
  readonly AGENT_C_YELLOW=""
  readonly AGENT_C_RED=""
fi

readonly AGENT_LOG_PREFIX="[task-agent]"

info() {
  printf '%s%s%s %s\n' "$AGENT_C_DIM" "$AGENT_LOG_PREFIX" "$AGENT_C_RESET" "$*" >&2
}

success() {
  printf '%s%s%s %s\n' "$AGENT_C_GREEN" "$AGENT_LOG_PREFIX" "$AGENT_C_RESET" "$*" >&2
}

warning() {
  printf '%s%s warning:%s %s\n' "$AGENT_C_YELLOW" "$AGENT_LOG_PREFIX" "$AGENT_C_RESET" "$*" >&2
}

error() {
  printf '%s%s error:%s %s\n' "$AGENT_C_RED" "$AGENT_LOG_PREFIX" "$AGENT_C_RESET" "$*" >&2
}

# die [message...] — report and exit 1. Multiple arguments become multiple lines
# so callers can append an actionable hint without embedding newlines.
die() {
  if (($# > 0)); then
    error "$1"
    shift
    local line
    for line in "$@"; do
      printf '%s\n' "$line" >&2
    done
  fi
  exit 1
}
