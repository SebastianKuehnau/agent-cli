#!/usr/bin/env bash
# `task-agent --init` — install the Docker Sandbox Kit into the current project.
#
# This is the whole of --init. It does not touch .gitignore, does not stage or
# commit anything, does not create Claude configuration, and does not ask any
# questions.

if [[ -n "${AGENT_SCAFFOLD_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SCAFFOLD_SH_LOADED=1

# Where presets are published: this repository itself, so the authored file and
# the downloaded file are the same file and cannot drift apart. Overridable so
# tests can point at a local directory via file:// (curl handles that natively)
# instead of depending on GitHub being reachable.
: "${TASK_AGENT_PRESET_BASE_URL:=https://raw.githubusercontent.com/SebastianKuehnau/agent-cli/main}"

readonly AGENT_KIT_RELATIVE_DIR=".sbx/kit"
readonly AGENT_KIT_RELATIVE_SPEC=".sbx/kit/spec.yaml"

# The preset used when `--init` is given no preset name.
readonly AGENT_DEFAULT_PRESET="generic"

# Placeholder a preset may use where the project's own name belongs. Substituted
# by scaffold_init; a preset that does not use it is copied byte for byte.
readonly AGENT_PRESET_SENTINEL="__PROJECT__"

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
      "  task-agent --init" \
      ""
}

# scaffold_kit_hash <main-repo-root>
#
# Print a digest of the project's *entire* Sandbox Kit, or fail if there is no
# kit directory. This is what `task-agent <branch>` compares against the kit
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

# scaffold_preset_url <preset>
#
# Resolve a preset name to the URL of its spec.yaml, or fail naming the presets
# that do exist. See docs/adr/0001-presets-as-url-lookup-not-kit-composition.md
# for why a preset is a URL rather than a composable kit.
#
# Every preset is one file at presets/<name>/spec.yaml in this repository. Note
# this changed the default: before presets existed, `--init` downloaded a kit
# from a separate repository that was in fact Vaadin-specific. `generic` is now
# genuinely generic, and Vaadin is `--init vaadin`.
scaffold_preset_url() {
  case "$1" in
    generic)
      printf '%s/presets/generic/spec.yaml' "${TASK_AGENT_PRESET_BASE_URL%/}"
      ;;
    vaadin)
      printf '%s/presets/vaadin/spec.yaml' "${TASK_AGENT_PRESET_BASE_URL%/}"
      ;;
    *)
      die "Unknown preset: $1" \
        "" \
        "Available presets:" \
        "  generic   JAVA_HOME, Maven/GitHub network access (the default)" \
        "  vaadin    generic, plus Vaadin skills and MCP, Playwright, host Ollama" \
        "" \
        "To use a spec of your own instead, set TASK_AGENT_KIT_URL." \
        ""
      ;;
  esac
}

# scaffold_init <main-repo-root> [preset]
#
# Download a preset's kit spec into <main-repo-root>/.sbx/kit/spec.yaml.
#
# An explicitly set TASK_AGENT_KIT_URL wins over the preset, so an arbitrary
# spec can be used without adding it to the table in scaffold_preset_url.
#
# The download is atomic: it lands in a temporary file inside the target
# directory (so the final `mv` is a same-filesystem rename) and is only moved
# into place after the transfer, a non-empty check and the placeholder
# substitution have all succeeded. A failed or empty download therefore never
# leaves a partial spec.yaml behind.
scaffold_init() {
  local main_root="${1%/}"
  local preset="${2:-$AGENT_DEFAULT_PRESET}"

  command -v curl >/dev/null 2>&1 ||
    die "curl is not installed or not on PATH." \
      "Install curl and try again."

  local kit_dir spec
  kit_dir="$(scaffold_kit_dir "$main_root")"
  spec="$(scaffold_kit_spec "$main_root")"

  if [[ -e "$spec" ]]; then
    die "Sandbox Kit already exists at $AGENT_KIT_RELATIVE_SPEC" \
      "Edit that file directly; task-agent will not overwrite it."
  fi

  # Resolve the preset before creating anything: an unknown preset name is an
  # argument error, and an argument error must leave the project untouched.
  local url
  if [[ -n "${TASK_AGENT_KIT_URL:-}" ]]; then
    url="$TASK_AGENT_KIT_URL"
    if (($# >= 2)); then
      warning "TASK_AGENT_KIT_URL is set; ignoring the '$preset' preset."
    fi
  else
    url="$(scaffold_preset_url "$preset")" || exit 1
  fi

  mkdir -p "$kit_dir" ||
    die "Could not create $AGENT_KIT_RELATIVE_DIR in $main_root"

  local tmp
  tmp="$(mktemp "$kit_dir/.spec.yaml.XXXXXX")" ||
    die "Could not create a temporary file in $kit_dir"

  # shellcheck disable=SC2064  # $tmp must be expanded now, not at trap time.
  trap "rm -f -- '$tmp'" EXIT

  info "Downloading Sandbox Kit from $url"

  if ! curl --fail --silent --show-error --location \
    --output "$tmp" "$url"; then
    die "Failed to download the Sandbox Kit from:" \
      "  $url" \
      "$AGENT_KIT_RELATIVE_SPEC was not created."
  fi

  if [[ ! -s "$tmp" ]]; then
    die "The downloaded Sandbox Kit is empty:" \
      "  $url" \
      "$AGENT_KIT_RELATIVE_SPEC was not created."
  fi

  # Substitute the project-name placeholder, but only when the preset actually
  # uses it: a spec without the sentinel is moved into place untouched, so
  # `--init` stays a byte-for-byte copy for every spec that does not opt in.
  #
  # naming_project_id yields only [a-z0-9-], so it can never contain a sed
  # delimiter, `&`, a backslash or a newline. That is what makes a plain `s///`
  # safe here without quoting the replacement.
  # The second temporary file is created only on this path, so a preset that
  # does not use the sentinel leaves nothing extra behind in .sbx/kit.
  local project tmp_sub
  if LC_ALL=C grep -q -- "$AGENT_PRESET_SENTINEL" "$tmp"; then
    project="$(naming_project_id "$main_root")"

    tmp_sub="$(mktemp "$kit_dir/.spec.yaml.XXXXXX")" ||
      die "Could not create a temporary file in $kit_dir"
    # shellcheck disable=SC2064  # Both paths must be expanded now, not at trap time.
    trap "rm -f -- '$tmp' '$tmp_sub'" EXIT

    LC_ALL=C sed "s/$AGENT_PRESET_SENTINEL/$project/g" "$tmp" >"$tmp_sub" ||
      die "Could not set the project name in the downloaded Sandbox Kit."
    mv -- "$tmp_sub" "$tmp" ||
      die "Could not set the project name in the downloaded Sandbox Kit."
  fi

  mv -- "$tmp" "$spec" ||
    die "Could not move the downloaded Sandbox Kit into place: $spec"

  trap - EXIT

  success "Created $AGENT_KIT_RELATIVE_SPEC from the '$preset' preset"
  info "Edit it to describe this project's toolchain and network policy."
  scaffold_preset_notes "$preset"
}

# scaffold_preset_notes <preset>
#
# Anything the user has to know that the preset itself cannot do for them.
# Printed once, right after --init.
scaffold_preset_notes() {
  case "$1" in
    vaadin)
      info ""
      info "Vaadin Pro components and TestBench need a licence inside the sandbox."
      info "task-agent does not deliver one; see 'Vaadin licence in the sandbox'"
      info "in the README for what works and what does not."
      ;;
  esac
}
