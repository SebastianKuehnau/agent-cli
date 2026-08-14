#!/usr/bin/env bats
#
# Docker Sandbox interaction, exercised against a fake `sbx` placed earlier on
# PATH. Argument construction is asserted element by element via AGENT_SBX_ARGV,
# never by comparing one joined string — that is the only way a quoting bug in a
# path containing spaces can actually be caught.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/naming.sh"
  source "$AGENT_LIB/sandbox.sh"

  TMP="$(make_tmpdir)"
  make_fake_sbx "$TMP/fake"
}

# --- CLI presence -----------------------------------------------------------

@test "sandbox_require_cli succeeds when sbx is on PATH" {
  run sandbox_require_cli
  assert_success
}

@test "sandbox_require_cli gives an actionable error when sbx is missing" {
  run --separate-stderr env PATH="/usr/bin:/bin" bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/sandbox.sh'
    sandbox_require_cli
  "
  assert_failure
  [[ "$stderr" == *"sbx"* ]] || fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"Install Docker Sandboxes"* ]] || fail "unexpected stderr: $stderr"
}

# --- existence --------------------------------------------------------------

@test "a sandbox that sbx does not list does not exist" {
  run sandbox_exists "agent-my-app-feature-x-abc123"
  assert_failure
}

@test "a sandbox that sbx lists exists" {
  fake_sbx_add_sandbox "agent-my-app-feature-x-abc123"
  run sandbox_exists "agent-my-app-feature-x-abc123"
  assert_success
}

@test "sandbox existence matches whole names, not substrings" {
  fake_sbx_add_sandbox "agent-my-app-feature-x-abc123-extra"
  run sandbox_exists "agent-my-app-feature-x-abc123"
  assert_failure
}

@test "sandbox existence picks the right name out of several" {
  fake_sbx_add_sandbox "agent-other-main-000000"
  fake_sbx_add_sandbox "agent-my-app-feature-x-abc123"
  fake_sbx_add_sandbox "agent-third-develop-111111"
  run sandbox_exists "agent-my-app-feature-x-abc123"
  assert_success
}

# --- create argv ------------------------------------------------------------

@test "create argv has the expected shape" {
  sandbox_build_create_argv \
    "agent-my-app-feature-new-crud-a84c91" \
    "/repo/.sbx/kit" \
    "/repo-worktrees/feature-new-crud-a84c91" \
    "/repo/.git"

  assert_argv \
    sbx create \
    --kit "/repo/.sbx/kit" \
    --name "agent-my-app-feature-new-crud-a84c91" \
    claude \
    "/repo-worktrees/feature-new-crud-a84c91" \
    "/repo/.git"
}

@test "the worktree is the first workspace" {
  sandbox_build_create_argv "n" "/kit" "/the/worktree" "/repo/.git"
  # The agent name is immediately followed by the primary workspace.
  local i
  for i in "${!AGENT_SBX_ARGV[@]}"; do
    if [[ "${AGENT_SBX_ARGV[$i]}" == "claude" ]]; then
      assert_equal "${AGENT_SBX_ARGV[$((i + 1))]}" "/the/worktree"
      return 0
    fi
  done
  fail "agent name not found in argv"
}

@test "the main repository git metadata is supplied as a workspace" {
  sandbox_build_create_argv "n" "/kit" "/the/worktree" "/repo/.git"
  local found=0 a
  for a in "${AGENT_SBX_ARGV[@]}"; do
    [[ "$a" == "/repo/.git" ]] && found=1
  done
  ((found)) || fail "git metadata workspace missing: ${AGENT_SBX_ARGV[*]}"
}

@test "the kit directory is passed with --kit" {
  sandbox_build_create_argv "n" "/repo/.sbx/kit" "/wt" "/repo/.git"
  local i
  for i in "${!AGENT_SBX_ARGV[@]}"; do
    if [[ "${AGENT_SBX_ARGV[$i]}" == "--kit" ]]; then
      assert_equal "${AGENT_SBX_ARGV[$((i + 1))]}" "/repo/.sbx/kit"
      return 0
    fi
  done
  fail "--kit not found in argv"
}

@test "--clone is never used, because it would break host visibility" {
  sandbox_build_create_argv "n" "/kit" "/wt" "/repo/.git"
  local a
  for a in "${AGENT_SBX_ARGV[@]}"; do
    if [[ "$a" == "--clone" ]]; then
      fail "--clone must not be used"
    fi
  done
}

@test "paths containing spaces stay single argv elements" {
  sandbox_build_create_argv \
    "agent-my-app-feature-x-abc123" \
    "/Users/me/my project/.sbx/kit" \
    "/Users/me/my project-worktrees/feature-x-abc123" \
    "/Users/me/my project/.git"

  assert_argv \
    sbx create \
    --kit "/Users/me/my project/.sbx/kit" \
    --name "agent-my-app-feature-x-abc123" \
    claude \
    "/Users/me/my project-worktrees/feature-x-abc123" \
    "/Users/me/my project/.git"
}

@test "additional workspaces beyond the first two are appended in order" {
  sandbox_build_create_argv "n" "/kit" "/a" "/b" "/c"
  assert_argv sbx create --kit /kit --name n claude /a /b /c
}

# --- attach argv ------------------------------------------------------------

@test "attach argv re-attaches by name only" {
  sandbox_build_attach_argv "agent-my-app-feature-x-abc123"
  assert_argv sbx run --name "agent-my-app-feature-x-abc123"
}

@test "attach argv keeps a name containing hyphens intact" {
  sandbox_build_attach_argv "agent-a-b-c-d-e-123456"
  assert_argv sbx run --name "agent-a-b-c-d-e-123456"
}

# --- execution --------------------------------------------------------------

@test "sandbox_create invokes sbx with the constructed argv" {
  run sandbox_create "agent-x-123456" "/kit" "/wt with space" "/repo/.git"
  assert_success

  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:create"
  assert_output_contains "arg:--kit"
  assert_output_contains "arg:/kit"
  assert_output_contains "arg:--name"
  assert_output_contains "arg:agent-x-123456"
  assert_output_contains "arg:claude"
  # One log line per argument proves the space did not split the argument.
  assert_output_contains "arg:/wt with space"
}

@test "sandbox_create reports a useful error when sbx fails" {
  run --separate-stderr env FAKE_SBX_EXIT=1 bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/sandbox.sh'
    sandbox_create 'agent-x-123456' '/kit' '/wt' '/repo/.git'
  "
  assert_failure
  [[ "$stderr" == *"Failed to create the sandbox 'agent-x-123456'"* ]] ||
    fail "unexpected stderr: $stderr"
}

# --- remove argv -------------------------------------------------------------

@test "remove argv has the expected shape" {
  sandbox_build_remove_argv "agent-my-app-feature-x-abc123"
  assert_argv sbx rm --force "agent-my-app-feature-x-abc123"
}

@test "remove argv keeps a name containing hyphens intact" {
  sandbox_build_remove_argv "agent-a-b-c-d-e-123456"
  assert_argv sbx rm --force "agent-a-b-c-d-e-123456"
}

# --- remove execution ---------------------------------------------------------

@test "sandbox_remove invokes sbx with the constructed argv" {
  fake_sbx_add_sandbox "agent-x-123456"
  run sandbox_remove "agent-x-123456"
  assert_success

  run cat "$FAKE_SBX_DIR/calls.log"
  assert_output_contains "arg:rm"
  assert_output_contains "arg:--force"
  assert_output_contains "arg:agent-x-123456"
}

@test "sandbox_remove makes the sandbox no longer exist" {
  fake_sbx_add_sandbox "agent-x-123456"
  run sandbox_remove "agent-x-123456"
  assert_success

  run sandbox_exists "agent-x-123456"
  assert_failure
}

@test "sandbox_remove reports a useful error when sbx fails" {
  run --separate-stderr env FAKE_SBX_EXIT=1 bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/sandbox.sh'
    sandbox_remove 'agent-x-123456'
  "
  assert_failure
  [[ "$stderr" == *"Failed to remove the sandbox 'agent-x-123456'"* ]] ||
    fail "unexpected stderr: $stderr"
}
