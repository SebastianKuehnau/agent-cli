#!/usr/bin/env bash
# `agent-task --init` — install the Docker Sandbox Kit into the current project.
#
# This is the whole of --init. It does not touch .gitignore, does not stage or
# commit anything, does not create Claude configuration, and does not ask any
# questions.

if [[ -n "${AGENT_SCAFFOLD_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SCAFFOLD_SH_LOADED=1

# Overridable so tests can point at a local file:// URL (curl handles that
# natively) instead of depending on GitHub being reachable.
: "${AGENT_TASK_KIT_URL:=https://raw.githubusercontent.com/SebastianKuehnau/claude-sandboxed/main/.sbx/kit/spec.yaml}"

readonly AGENT_KIT_RELATIVE_DIR=".sbx/kit"
readonly AGENT_KIT_RELATIVE_SPEC=".sbx/kit/spec.yaml"

# scaffold_kit_dir <main-repo-root>
scaffold_kit_dir() {
  printf '%s/%s' "${1%/}" "$AGENT_KIT_RELATIVE_DIR"
}

# scaffold_kit_spec <main-repo-root>
scaffold_kit_spec() {
  printf '%s/%s' "${1%/}" "$AGENT_KIT_RELATIVE_SPEC"
}

# scaffold_require_kit <main-repo-root>
#
# Used by the session workflow: a sandbox must never be started without the
# project's own kit.
scaffold_require_kit() {
  local spec
  spec="$(scaffold_kit_spec "$1")"

  [[ -f "$spec" ]] ||
    die "No Sandbox Kit found at $AGENT_KIT_RELATIVE_SPEC." \
      "" \
      "Run:" \
      "" \
      "  agent-task --init" \
      ""
}

# scaffold_kit_hash <main-repo-root>
#
# Print a digest of the project's *entire* Sandbox Kit, or fail if there is no
# kit directory. This is what `agent-task <branch>` compares against the kit
# that was last applied to an existing sandbox (issue #7).
#
# Every file under .sbx/kit contributes both its path relative to the kit
# directory and its content, in a stable (LC_ALL=C) order. Consequences worth
# knowing:
#
#   - The digest covers the whole kit, not just spec.yaml: a kit may reference
#     further files, and editing one of those is just as much a kit change.
#   - Adding, removing and renaming a file all change the digest, because paths
#     are hashed too — a content-only digest would miss a pure rename.
#   - The digest is independent of where the repository lives, so moving a
#     checkout does not look like a kit change.
#   - The executable bit is included, since a kit may ship setup scripts whose
#     bit matters, and a chmod is otherwise invisible to a content digest.
#
# A file name containing a newline would confuse the line-oriented read below.
# That is accepted deliberately: the effect is a differing digest, i.e. the kit
# is re-applied more often than needed, never a missed change.
scaffold_kit_hash() {
  local kit_dir
  kit_dir="$(scaffold_kit_dir "$1")"

  [[ -d "$kit_dir" ]] || return 1

  local path
  while IFS= read -r path; do
    printf '%s\n' "${path#"$kit_dir/"}"
    if [[ -x "$path" ]]; then
      printf 'mode:exec\n'
    else
      printf 'mode:plain\n'
    fi
    cat -- "$path"
  done < <(find "$kit_dir" -type f | LC_ALL=C sort) | naming_stream_hash
}

# scaffold_init <main-repo-root>
#
# Download the kit spec into <main-repo-root>/.sbx/kit/spec.yaml.
#
# The download is atomic: it lands in a temporary file inside the target
# directory (so the final `mv` is a same-filesystem rename) and is only moved
# into place after both the transfer and a non-empty check have succeeded. A
# failed or empty download therefore never leaves a partial spec.yaml behind.
scaffold_init() {
  local main_root="${1%/}"

  command -v curl >/dev/null 2>&1 ||
    die "curl is not installed or not on PATH." \
      "Install curl and try again."

  local kit_dir spec
  kit_dir="$(scaffold_kit_dir "$main_root")"
  spec="$(scaffold_kit_spec "$main_root")"

  if [[ -e "$spec" ]]; then
    die "Sandbox Kit already exists at $AGENT_KIT_RELATIVE_SPEC" \
      "Edit that file directly; agent-task will not overwrite it."
  fi

  mkdir -p "$kit_dir" ||
    die "Could not create $AGENT_KIT_RELATIVE_DIR in $main_root"

  local tmp
  tmp="$(mktemp "$kit_dir/.spec.yaml.XXXXXX")" ||
    die "Could not create a temporary file in $kit_dir"

  # shellcheck disable=SC2064  # $tmp must be expanded now, not at trap time.
  trap "rm -f -- '$tmp'" EXIT

  info "Downloading Sandbox Kit from $AGENT_TASK_KIT_URL"

  if ! curl --fail --silent --show-error --location \
    --output "$tmp" "$AGENT_TASK_KIT_URL"; then
    die "Failed to download the Sandbox Kit from:" \
      "  $AGENT_TASK_KIT_URL" \
      "$AGENT_KIT_RELATIVE_SPEC was not created."
  fi

  if [[ ! -s "$tmp" ]]; then
    die "The downloaded Sandbox Kit is empty:" \
      "  $AGENT_TASK_KIT_URL" \
      "$AGENT_KIT_RELATIVE_SPEC was not created."
  fi

  mv -- "$tmp" "$spec" ||
    die "Could not move the downloaded Sandbox Kit into place: $spec"

  trap - EXIT

  success "Created $AGENT_KIT_RELATIVE_SPEC"
  info "Edit it to describe this project's toolchain and network policy."
}
