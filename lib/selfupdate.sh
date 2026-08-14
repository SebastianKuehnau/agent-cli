#!/usr/bin/env bash
# Self-update for a single-file task-agent install.
#
# Only makes sense for the single-file distribution (see scripts/build-bundle.sh):
# a git checkout has its own lib/ files to update and is refreshed with
# `git pull`, which bin/task-agent's cmd_update checks for before calling in
# here at all.
#
# Requires lib/version.sh for TASK_AGENT_VERSION.

if [[ -n "${AGENT_SELFUPDATE_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SELFUPDATE_SH_LOADED=1

# Overridable so tests can point at local file:// URLs (curl handles those
# natively) instead of depending on GitHub being reachable.
: "${TASK_AGENT_REPO:=SebastianKuehnau/agent-cli}"
: "${TASK_AGENT_UPDATE_ASSET:=task-agent}"
: "${TASK_AGENT_UPDATE_URL:=https://github.com/${TASK_AGENT_REPO}/releases/latest/download/${TASK_AGENT_UPDATE_ASSET}}"
: "${TASK_AGENT_LATEST_URL:=https://github.com/${TASK_AGENT_REPO}/releases/latest}"

# selfupdate_latest_version
#
# Print the version of the latest release, without the `v` prefix, or fail.
#
# GitHub redirects <repo>/releases/latest to <repo>/releases/tag/vX.Y.Z, so the
# tag can be read straight off the effective URL of a HEAD request. That keeps
# agent-cli free of a JSON parser and of the GitHub API's unauthenticated rate
# limit — the whole point of not needing `jq` or a token.
#
# A repository with no releases at all redirects to <repo>/releases instead;
# requiring the `v` prefix rejects that (and anything else unexpected) rather
# than reporting a nonsense version.
selfupdate_latest_version() {
  local effective tag

  effective="$(curl --fail --silent --head --location \
    --output /dev/null --write-out '%{url_effective}' \
    "$TASK_AGENT_LATEST_URL" 2>/dev/null)" || return 1

  tag="${effective%/}"
  tag="${tag##*/}"

  [[ "$tag" == v?* ]] || return 1

  printf '%s' "${tag#v}"
}

# selfupdate_run <self-path>
#
# Install the latest release over <self-path>, unless it is already installed.
#
# The comparison is deliberately "differs" rather than "is newer": there is no
# version ordering to get wrong, and it means a deliberate rollback (a release
# republished at a lower version) still installs.
#
# If the latest version cannot be determined at all, the download is attempted
# anyway. Refusing would turn any hiccup in resolving the version into a broken
# --update, whereas an unnecessary download is merely wasteful — and if the
# machine is offline, the download fails with its own clear message regardless.
#
# The download is atomic: it lands in a temporary file in the same directory
# as <self-path> (so the final `mv` is a same-filesystem rename) and is only
# moved into place after both the transfer and a non-empty check have
# succeeded, mirroring scaffold_init's download.
selfupdate_run() {
  local self="$1"

  command -v curl >/dev/null 2>&1 ||
    die "curl is not installed or not on PATH." \
      "Install curl and try again."

  local latest
  if latest="$(selfupdate_latest_version)"; then
    if [[ "$latest" == "$TASK_AGENT_VERSION" ]]; then
      success "task-agent $TASK_AGENT_VERSION is already the latest release."
      return 0
    fi
    info "Updating task-agent from $TASK_AGENT_VERSION to $latest"
  else
    warning "Could not determine the latest released version from:"
    warning "  $TASK_AGENT_LATEST_URL"
    warning "Downloading the latest release anyway."
  fi

  local dir tmp
  dir="$(dirname "$self")"
  tmp="$(mktemp "$dir/.task-agent.XXXXXX")" ||
    die "Could not create a temporary file in $dir"

  # shellcheck disable=SC2064  # $tmp must be expanded now, not at trap time.
  trap "rm -f -- '$tmp'" EXIT

  info "Downloading the latest task-agent from $TASK_AGENT_UPDATE_URL"

  if ! curl --fail --silent --show-error --location \
    --output "$tmp" "$TASK_AGENT_UPDATE_URL"; then
    die "Failed to download the update from:" \
      "  $TASK_AGENT_UPDATE_URL" \
      "$self was not changed."
  fi

  if [[ ! -s "$tmp" ]]; then
    die "The downloaded update is empty:" \
      "  $TASK_AGENT_UPDATE_URL" \
      "$self was not changed."
  fi

  chmod +x "$tmp" ||
    die "Could not make the downloaded update executable: $tmp"

  mv -- "$tmp" "$self" ||
    die "Could not install the update at: $self"

  trap - EXIT

  success "Updated task-agent from $TASK_AGENT_UPDATE_URL"
}
