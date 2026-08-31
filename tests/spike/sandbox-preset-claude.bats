#!/usr/bin/env bats
#
# Spike: does the vaadin-claude preset's agent configuration actually arrive?
#
# The preset writes ~/.claude/statusline.sh and merges ~/.claude/settings.json
# from a `setup.install` step, and installs two skill plugins. None of that can
# be checked without a real sbx, and three of its assumptions would fail
# silently inside a sandbox rather than loudly at --init time:
#
#   1. the kit schema accepts a *multi-line* command (a YAML block scalar
#      containing a heredoc) — every other command in the shipped presets is a
#      one-liner;
#   2. ~/.claude/settings.json is container-local and merged, not replaced —
#      Docker Sandboxes seeds that file, and overwriting it would throw the
#      seeded configuration away;
#   3. `claude plugin install` leaves both plugins *enabled*, not merely
#      downloaded.
#
# Skipped automatically when sbx is unavailable, so the normal suite stays
# runnable everywhere. Slow: the preset installs Playwright's chromium. Run
# explicitly with:
#
#   bats tests/spike/sandbox-preset-claude.bats

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  if ! command -v sbx >/dev/null 2>&1; then
    skip "sbx is not installed — Docker Sandboxes required for the spike"
  fi
  if ! sbx ls >/dev/null 2>&1; then
    skip "sbx is installed but not usable (is the Docker Sandboxes daemon running?)"
  fi

  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/naming.sh"
  source "$AGENT_LIB/sandbox.sh"
  source "$AGENT_LIB/scaffold.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/spike-claude-app"
  make_repo "$REPO" >/dev/null

  KIT_DIR="$REPO/.sbx/kit"
  mkdir -p "$KIT_DIR"

  # The *shipped* preset, substituted exactly as scaffold_init would. Copying
  # rather than downloading keeps the spike about sbx, not about GitHub, and
  # means a preset edited in this checkout is what gets exercised.
  SHIPPED="${AGENT_LIB%/lib}/presets/vaadin-claude/spec.yaml"
  LC_ALL=C sed "s/__PROJECT__/spike-claude-app/g" "$SHIPPED" >"$KIT_DIR/spec.yaml"

  SANDBOX="agent-cli-spike-preset-claude"
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

teardown() {
  sbx rm --force "$SANDBOX" >/dev/null 2>&1 || sbx rm "$SANDBOX" >/dev/null 2>&1 || true
}

# create_sandbox — the real thing: the claude agent, because the preset's setup
# steps call the `claude` CLI. The `shell` agent the other spikes use would not
# have it.
create_sandbox() {
  sandbox_create "$SANDBOX" "$KIT_DIR" "$REPO"
}

# in_sandbox <command>... — run a command inside the sandbox as the agent user.
in_sandbox() {
  sbx exec -w "$REPO" "$SANDBOX" "$@"
}

# --- the kit schema ---------------------------------------------------------

@test "sbx accepts the preset's multi-line setup command" {
  # If this fails, the block scalar has to become a one-liner (bash -c '...').
  run sbx kit validate "$KIT_DIR"
  assert_success
}

# --- what lands in the sandbox ----------------------------------------------

@test "the status line script is installed and executable" {
  create_sandbox

  run in_sandbox bash -c 'test -x "$HOME/.claude/statusline.sh"'
  assert_success
}

@test "the status line renders a real status line payload" {
  create_sandbox

  run in_sandbox bash -c \
    'printf "{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":40}}" | "$HOME/.claude/statusline.sh"'
  assert_success
  [[ "$output" == *"Opus"* && "$output" == *"40%"* ]] ||
    fail "unexpected status line: $output"
}

@test "settings.json keeps what Docker Sandboxes seeded and gains the status line" {
  # The merge, not the write: whatever sbx put in settings.json before the setup
  # step ran must still be there afterwards. The keys sbx seeds are its own
  # business, so this asserts only that there are keys beyond the two the preset
  # sets — a replaced file would have exactly those two.
  create_sandbox

  run in_sandbox bash -c \
    'jq -r ".statusLine.command" "$HOME/.claude/settings.json"'
  assert_success
  [[ "$output" == *"/.claude/statusline.sh" ]] ||
    fail "status line not configured: $output"

  run in_sandbox bash -c \
    'jq -r "keys - [\"statusLine\", \"enabledPlugins\"] | length" "$HOME/.claude/settings.json"'
  assert_success
  if ((output == 0)); then
    printf 'note: settings.json held nothing but the preset keys — nothing was seeded to merge with\n' >&3
  fi
}

@test "both skill plugins are installed and enabled" {
  create_sandbox

  run in_sandbox bash -c \
    'jq -r ".enabledPlugins | to_entries[] | select(.value) | .key" "$HOME/.claude/settings.json"'
  assert_success
  [[ "$output" == *"vaadin-skills@vaadin-marketplace"* ]] ||
    fail "the Vaadin skills are not enabled: $output"
  [[ "$output" == *"mattpocock-skills@claude-plugins-official"* ]] ||
    fail "the general skills are not enabled: $output"

  # Enabled in settings is not the same as present on disk.
  run in_sandbox claude plugin list
  assert_success
  [[ "$output" == *"vaadin-skills"* && "$output" == *"mattpocock-skills"* ]] ||
    fail "a plugin is enabled but not installed: $output"
}

@test "jq is present in the image the preset relies on" {
  # The preset installs jq when it is missing; if this passes, that guard is
  # merely insurance. If it starts failing, the guard is load-bearing and the
  # apt-get in the preset must stay.
  create_sandbox

  run in_sandbox bash -c 'command -v jq'
  assert_success
}
