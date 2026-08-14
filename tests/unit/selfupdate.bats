#!/usr/bin/env bats
#
# Tests for `task-agent --update` / lib/selfupdate.sh.
#
# Both URLs involved — the release asset and the "what is the latest version"
# probe — are redirected to local file:// URLs, which curl handles natively, so
# these tests need no network and never touch GitHub. The probe fixtures mimic
# GitHub's redirect target, whose last path segment is the release tag
# (.../releases/tag/vX.Y.Z). A separate opt-in test at the bottom exercises the
# real URLs.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  INSTALL_DIR="$TMP/install"
  mkdir -p "$INSTALL_DIR"
  SELF="$INSTALL_DIR/task-agent"
  printf '#!/usr/bin/env bash\n# old version\n' >"$SELF"
  chmod +x "$SELF"

  FIXTURE="$TMP/new-task-agent"
  printf '#!/usr/bin/env bash\n# new version\n' >"$FIXTURE"

  # The version this install reports, straight from the source of truth.
  INSTALLED_VERSION="$(bash -c \
    "source '$AGENT_LIB/version.sh'; printf '%s' \"\$TASK_AGENT_VERSION\"")"

  # Fake redirect targets: .../releases/tag/<tag>
  mkdir -p "$TMP/releases/tag"
  printf 'x\n' >"$TMP/releases/tag/v$INSTALLED_VERSION"
  printf 'x\n' >"$TMP/releases/tag/v9.9.9"
  # A repository with no releases at all redirects to .../releases instead.
  printf 'x\n' >"$TMP/releases-index"

  SAME_VERSION_URL="file://$TMP/releases/tag/v$INSTALLED_VERSION"
  NEWER_VERSION_URL="file://$TMP/releases/tag/v9.9.9"
  UNRESOLVABLE_URL="file://$TMP/no-such-release"
}

# update_with_url <asset-url> [latest-url]
#
# Run selfupdate_run against <asset-url>. The latest-version probe defaults to
# an unresolvable URL, which puts the version comparison out of the way for the
# tests that are only about the download itself.
update_with_url() {
  run --separate-stderr env \
    TASK_AGENT_UPDATE_URL="$1" \
    TASK_AGENT_LATEST_URL="${2:-$UNRESOLVABLE_URL}" \
    bash -c "
      source '$AGENT_LIB/version.sh'
      source '$AGENT_LIB/logging.sh'
      source '$AGENT_LIB/selfupdate.sh'
      selfupdate_run '$SELF'
    "
}

# latest_version_from <latest-url>
latest_version_from() {
  run --separate-stderr env TASK_AGENT_LATEST_URL="$1" \
    bash -c "
      source '$AGENT_LIB/version.sh'
      source '$AGENT_LIB/logging.sh'
      source '$AGENT_LIB/selfupdate.sh'
      selfupdate_latest_version
    "
}

# --- default URLs -----------------------------------------------------------

@test "the default asset is the renamed one" {
  # Releases publish both task-agent and, for pre-rename installs, agent-task.
  # This install must ask for the current name (issue #8).
  run bash -c "
    source '$AGENT_LIB/version.sh'
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/selfupdate.sh'
    printf '%s' \"\$TASK_AGENT_UPDATE_URL\"
  "
  assert_success
  assert_equal "$output" \
    "https://github.com/SebastianKuehnau/agent-cli/releases/latest/download/task-agent"
}

@test "the default version probe URL is the latest-release redirect" {
  run bash -c "
    source '$AGENT_LIB/version.sh'
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/selfupdate.sh'
    printf '%s' \"\$TASK_AGENT_LATEST_URL\"
  "
  assert_success
  assert_equal "$output" \
    "https://github.com/SebastianKuehnau/agent-cli/releases/latest"
}

# --- version probe ----------------------------------------------------------

@test "selfupdate_latest_version reads the tag off the redirect target" {
  latest_version_from "$NEWER_VERSION_URL"
  assert_success
  assert_equal "$output" "9.9.9"
}

@test "selfupdate_latest_version strips the v prefix" {
  latest_version_from "$SAME_VERSION_URL"
  assert_success
  assert_equal "$output" "$INSTALLED_VERSION"
}

@test "selfupdate_latest_version fails when the URL is unreachable" {
  latest_version_from "$UNRESOLVABLE_URL"
  assert_failure
  assert_equal "$output" ""
}

@test "selfupdate_latest_version fails when the target is not a tag" {
  # GitHub redirects a repository with no releases to .../releases, whose last
  # path segment must not be mistaken for a version.
  latest_version_from "file://$TMP/releases-index"
  assert_failure
  assert_equal "$output" ""
}

# --- version comparison (issue #6) ------------------------------------------

@test "nothing is downloaded when the installed version is the latest" {
  local before
  before="$(cat "$SELF")"

  update_with_url "file://$FIXTURE" "$SAME_VERSION_URL"
  assert_success
  assert_equal "$(cat "$SELF")" "$before"
  [[ "$stderr" == *"already the latest release"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" != *"Downloading"* ]] || fail "downloaded despite being up to date: $stderr"
}

@test "a different released version is installed" {
  update_with_url "file://$FIXTURE" "$NEWER_VERSION_URL"
  assert_success
  run diff "$FIXTURE" "$SELF"
  assert_success
}

@test "the version being installed is reported" {
  update_with_url "file://$FIXTURE" "$NEWER_VERSION_URL"
  assert_success
  [[ "$stderr" == *"$INSTALLED_VERSION to 9.9.9"* ]] || fail "unexpected stderr: $stderr"
}

@test "an unresolvable version probe warns and downloads anyway" {
  # A broken probe must not be able to break --update itself.
  update_with_url "file://$FIXTURE" "$UNRESOLVABLE_URL"
  assert_success
  [[ "$stderr" == *"Could not determine the latest released version"* ]] ||
    fail "unexpected stderr: $stderr"
  run diff "$FIXTURE" "$SELF"
  assert_success
}

@test "being up to date is not reported as an error" {
  update_with_url "file://$TMP/does-not-exist" "$SAME_VERSION_URL"
  assert_success
  # The asset URL is broken, but it is never fetched, so this still succeeds.
  [[ "$stderr" != *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
}

# --- happy path -------------------------------------------------------------

@test "selfupdate_run overwrites the target with the downloaded content" {
  update_with_url "file://$FIXTURE"
  assert_success
  run diff "$FIXTURE" "$SELF"
  assert_success
}

@test "selfupdate_run makes the result executable" {
  chmod -x "$SELF"
  update_with_url "file://$FIXTURE"
  assert_success
  [[ -x "$SELF" ]] || fail "updated file is not executable"
}

@test "selfupdate_run leaves no temporary files behind" {
  update_with_url "file://$FIXTURE"
  assert_success
  local leftovers
  leftovers="$(find "$INSTALL_DIR" -name '.task-agent.*' | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

# --- atomicity / failure -----------------------------------------------------

@test "a failed download leaves the existing install untouched" {
  local before
  before="$(cat "$SELF")"

  update_with_url "file://$TMP/does-not-exist"
  assert_failure
  [[ "$stderr" == *"Failed to download"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(cat "$SELF")" "$before"
}

@test "a failed download leaves no temporary file behind" {
  update_with_url "file://$TMP/does-not-exist"
  assert_failure
  local leftovers
  leftovers="$(find "$INSTALL_DIR" -name '.task-agent.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

@test "an empty download leaves the existing install untouched" {
  : >"$TMP/empty"
  local before
  before="$(cat "$SELF")"

  update_with_url "file://$TMP/empty"
  assert_failure
  [[ "$stderr" == *"empty"* ]] || fail "unexpected stderr: $stderr"
  assert_equal "$(cat "$SELF")" "$before"
}

# --- optional network test --------------------------------------------------

@test "the real release URLs are reachable (TASK_AGENT_NETWORK_TESTS=1)" {
  [[ -n "${TASK_AGENT_NETWORK_TESTS:-}" ]] ||
    skip "set TASK_AGENT_NETWORK_TESTS=1 to test against the real URLs"

  # The version probe must resolve to something version-shaped. This asserts
  # on the probe rather than on a full selfupdate_run, so that the test stays
  # valid once the released version equals the installed one — at which point
  # a real run correctly downloads nothing at all.
  run --separate-stderr bash -c "
    source '$AGENT_LIB/version.sh'
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/selfupdate.sh'
    selfupdate_latest_version
  "
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+ ]] || fail "not a version: '$output'"

  # And the asset itself must exist for that release.
  run curl --fail --silent --head --location --output /dev/null \
    "https://github.com/SebastianKuehnau/agent-cli/releases/latest/download/task-agent"
  assert_success
}
