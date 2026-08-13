#!/usr/bin/env bash
# Self-update for a single-file agent-task install.
#
# Only makes sense for the single-file distribution (see scripts/build-bundle.sh):
# a git checkout has its own lib/ files to update and is refreshed with
# `git pull`, which bin/agent-task's cmd_update checks for before calling in
# here at all.

if [[ -n "${AGENT_SELFUPDATE_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_SELFUPDATE_SH_LOADED=1

# Overridable so tests can point at a local file:// URL instead of depending
# on GitHub being reachable.
: "${AGENT_TASK_REPO:=SebastianKuehnau/agent-cli}"
: "${AGENT_TASK_UPDATE_ASSET:=agent-task}"
: "${AGENT_TASK_UPDATE_URL:=https://github.com/${AGENT_TASK_REPO}/releases/latest/download/${AGENT_TASK_UPDATE_ASSET}}"

# selfupdate_run <self-path>
#
# Download the latest release and overwrite <self-path> with it. Always
# re-downloads; there is no "already up to date" short-circuit, and the
# bundle carries no embedded version marker to compare against.
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

  local dir tmp
  dir="$(dirname "$self")"
  tmp="$(mktemp "$dir/.agent-task.XXXXXX")" ||
    die "Could not create a temporary file in $dir"

  # shellcheck disable=SC2064  # $tmp must be expanded now, not at trap time.
  trap "rm -f -- '$tmp'" EXIT

  info "Downloading the latest agent-task from $AGENT_TASK_UPDATE_URL"

  if ! curl --fail --silent --show-error --location \
    --output "$tmp" "$AGENT_TASK_UPDATE_URL"; then
    die "Failed to download the update from:" \
      "  $AGENT_TASK_UPDATE_URL" \
      "$self was not changed."
  fi

  if [[ ! -s "$tmp" ]]; then
    die "The downloaded update is empty:" \
      "  $AGENT_TASK_UPDATE_URL" \
      "$self was not changed."
  fi

  chmod +x "$tmp" ||
    die "Could not make the downloaded update executable: $tmp"

  mv -- "$tmp" "$self" ||
    die "Could not install the update at: $self"

  trap - EXIT

  success "Updated agent-task from $AGENT_TASK_UPDATE_URL"
}
