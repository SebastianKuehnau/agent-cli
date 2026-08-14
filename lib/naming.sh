#!/usr/bin/env bash
# Pure naming functions for agent-cli.
#
# Nothing here touches git, the filesystem, or the sandbox runtime — every
# function is a deterministic string transformation, which is what makes them
# cheap to unit test.
#
# The core problem being solved: the predecessor tool used a lossy sanitiser as
# an identifier, so `feature/x`, `feature-x` and `Feature/X` all collapsed onto
# the same worktree path and container name. Here every identifier is
# `<slug>-<hash>`, where the hash is taken from the *raw* input, so colliding
# slugs still produce distinct identifiers.

if [[ -n "${AGENT_NAMING_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_NAMING_SH_LOADED=1

# Length caps. The hash is never truncated and always ends the identifier.
readonly AGENT_SLUG_MAX_LENGTH=40
readonly AGENT_SANDBOX_PROJECT_MAX_LENGTH=20
readonly AGENT_SANDBOX_BRANCH_MAX_LENGTH=30
readonly AGENT_SHORT_HASH_LENGTH=6

# naming_slug <text> [max-length]
#
# Lowercase, collapse every run of characters outside [a-z0-9] into a single
# hyphen, trim leading/trailing hyphens, then truncate (trimming again so the
# result never ends in a hyphen). An input with no usable characters at all
# yields the literal `branch` rather than an empty string.
naming_slug() {
  local text="$1"
  local max="${2:-$AGENT_SLUG_MAX_LENGTH}"

  local slug
  slug="$(printf '%s' "$text" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  slug="$(printf '%s' "$slug" | LC_ALL=C tr -c 'a-z0-9' '-')"
  # Collapse runs of hyphens, then trim.
  while [[ "$slug" == *--* ]]; do
    slug="${slug//--/-}"
  done
  slug="${slug#-}"
  slug="${slug%-}"

  if ((${#slug} > max)); then
    slug="${slug:0:max}"
    slug="${slug%-}"
  fi

  if [[ -z "$slug" ]]; then
    slug="branch"
  fi

  printf '%s' "$slug"
}

# naming_short_hash <text>
#
# First AGENT_SHORT_HASH_LENGTH hex characters of the SHA-256 of the raw input.
# `printf '%s'` (no trailing newline) keeps the digest stable and independent of
# how the caller obtained the string.
#
# `shasum -a 256` is preferred because it ships with macOS via perl; `sha256sum`
# is the GNU coreutils name and is used as a fallback on Linux images that lack
# perl. Neither is a new dependency.
naming_short_hash() {
  local text="$1"
  local digest

  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$text" | shasum -a 256)"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$text" | sha256sum)"
  else
    printf 'no SHA-256 utility found (need shasum or sha256sum)\n' >&2
    return 1
  fi

  printf '%s' "${digest:0:AGENT_SHORT_HASH_LENGTH}"
}

# naming_stream_hash
#
# Full SHA-256 of stdin. The streaming counterpart to naming_short_hash, for
# input too large or too binary to pass as an argument (see scaffold_kit_hash).
# Not truncated: this one is used to decide whether something changed, where
# there is no length limit to respect and no reason to weaken it.
naming_stream_hash() {
  local digest

  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256)"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum)"
  else
    printf 'no SHA-256 utility found (need shasum or sha256sum)\n' >&2
    return 1
  fi

  # Both tools print "<digest>  <filename>"; keep the digest only.
  printf '%s' "${digest%% *}"
}

# naming_worktree_id <branch>
#
# Stable, collision-resistant directory name for a branch's worktree, e.g.
# `feature/new-crud` -> `feature-new-crud-a84c91`. Note it is a single path
# segment: unlike the predecessor, a branch containing `/` never nests.
naming_worktree_id() {
  local branch="$1"
  printf '%s-%s' "$(naming_slug "$branch")" "$(naming_short_hash "$branch")"
}

# naming_project_id <path>
#
# Project identifier derived from the main repository directory name.
naming_project_id() {
  local path="$1"
  path="${path%/}"
  naming_slug "${path##*/}" "$AGENT_SANDBOX_PROJECT_MAX_LENGTH"
}

# naming_sandbox_name <project-id> <branch>
#
# Deterministic sandbox name: agent-<project>-<branch-slug>-<hash>.
#
# The `agent-` prefix is agent-neutral by design (the predecessor used
# `claude-`). The character set is restricted to lowercase letters, digits and
# hyphens, which is a strict subset of what `sbx --name` accepts.
naming_sandbox_name() {
  local project="$1"
  local branch="$2"

  printf 'agent-%s-%s-%s' \
    "$(naming_slug "$project" "$AGENT_SANDBOX_PROJECT_MAX_LENGTH")" \
    "$(naming_slug "$branch" "$AGENT_SANDBOX_BRANCH_MAX_LENGTH")" \
    "$(naming_short_hash "$branch")"
}
