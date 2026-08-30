#!/usr/bin/env bats
#
# Rescuing the agent's transcripts out of a sandbox, exercised against a fake
# `sbx` placed earlier on PATH. Argument construction is asserted element by
# element via AGENT_SBX_ARGV — in-sandbox transcript paths are arbitrary host
# paths, so a quoting bug here would be a quoting bug on a real user's disk.
#
# CLAUDE_CONFIG_DIR is redirected into the test's own temporary directory in
# setup. Without that, every one of these tests would write into the
# developer's real ~/.claude/projects.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/transcripts.sh"

  TMP="$(make_tmpdir)"
  make_fake_sbx "$TMP/fake"

  CLAUDE_CONFIG_DIR="$TMP/claude"
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR"

  SANDBOX="agent-my-app-feature-new-crud-a84c91"
}

# --- host destination -------------------------------------------------------

@test "the host destination follows CLAUDE_CONFIG_DIR" {
  CLAUDE_CONFIG_DIR="/somewhere/else"
  assert_equal "$(transcripts_host_projects_dir)" "/somewhere/else/projects"
}

@test "the host destination falls back to ~/.claude, as /insights does" {
  run env -u CLAUDE_CONFIG_DIR HOME="/home/someone" bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    transcripts_host_projects_dir
  "
  assert_success
  assert_equal "$output" "/home/someone/.claude/projects"
}

# --- listing argv -----------------------------------------------------------

@test "list argv has the expected shape" {
  transcripts_build_list_argv "$SANDBOX"
  assert_argv sbx exec "$SANDBOX" sh -c "$AGENT_TRANSCRIPTS_LIST_SCRIPT"
}

@test "the listing resolves the config directory inside the sandbox" {
  # A kit can set CLAUDE_CONFIG_DIR in the container. Hardcoding ~/.claude here
  # would make the rescue silently do nothing for such a project.
  [[ "$AGENT_TRANSCRIPTS_LIST_SCRIPT" == *'${CLAUDE_CONFIG_DIR:-$HOME/.claude}'* ]] ||
    fail "listing does not honour an in-sandbox CLAUDE_CONFIG_DIR: $AGENT_TRANSCRIPTS_LIST_SCRIPT"
}

@test "the listing is pinned to depth 2, so it skips the subdirectories" {
  # projects/<slug>/<session>.jsonl and nothing else: memory/, tool-results/
  # and subagent transcripts are not what /insights reads.
  [[ "$AGENT_TRANSCRIPTS_LIST_SCRIPT" == *"-mindepth 2"* ]] ||
    fail "no -mindepth 2: $AGENT_TRANSCRIPTS_LIST_SCRIPT"
  [[ "$AGENT_TRANSCRIPTS_LIST_SCRIPT" == *"-maxdepth 2"* ]] ||
    fail "no -maxdepth 2: $AGENT_TRANSCRIPTS_LIST_SCRIPT"
}

@test "the listing script is one argv element, not several words" {
  # sbx, exec, <name>, sh, -c, <script>
  transcripts_build_list_argv "$SANDBOX"
  assert_equal "${#AGENT_SBX_ARGV[@]}" "6"
}

# --- copy argv --------------------------------------------------------------

@test "copy argv has the expected shape" {
  transcripts_build_copy_argv "$SANDBOX" "/home/agent/.claude/projects/p/s.jsonl" "/dest"
  assert_argv sbx cp "$SANDBOX:/home/agent/.claude/projects/p/s.jsonl" "/dest/"
}

@test "copy argv keeps a path containing spaces a single element" {
  transcripts_build_copy_argv "$SANDBOX" "/a path/with spaces/s.jsonl" "/dest dir"
  assert_argv sbx cp "$SANDBOX:/a path/with spaces/s.jsonl" "/dest dir/"
}

# --- listing noise ----------------------------------------------------------

@test "only absolute .jsonl paths count as listing results" {
  # `sbx exec` starts a stopped sandbox first and may print progress of its own
  # onto the same stream. That must never turn into a copy.
  run transcripts_is_transcript_path "/home/agent/.claude/projects/p/s.jsonl"
  assert_success

  run transcripts_is_transcript_path "Starting sandbox agent-my-app..."
  assert_failure
  run transcripts_is_transcript_path "projects/p/s.jsonl"
  assert_failure
  run transcripts_is_transcript_path "/home/agent/.claude/projects/p/memory.md"
  assert_failure
  run transcripts_is_transcript_path ""
  assert_failure
}

# --- configuration ----------------------------------------------------------

@test "the rescue is on by default" {
  run env -u TASK_AGENT_RESCUE_TRANSCRIPTS bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    printf '%s' \"\$TASK_AGENT_RESCUE_TRANSCRIPTS\"
  "
  assert_success
  assert_equal "$output" "yes"
}

@test "yes and no are accepted" {
  TASK_AGENT_RESCUE_TRANSCRIPTS=yes
  run transcripts_validate_mode
  assert_success

  TASK_AGENT_RESCUE_TRANSCRIPTS=no
  run transcripts_validate_mode
  assert_success
}

@test "an invalid setting is an error, not a silent 'no'" {
  # Treating a typo as "no" would switch the rescue off for exactly the user
  # who was trying to configure it. Same rule as TASK_AGENT_KIT_RECREATE.
  run --separate-stderr env TASK_AGENT_RESCUE_TRANSCRIPTS=0 bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    transcripts_validate_mode
  "
  assert_failure
  [[ "$stderr" == *"Invalid TASK_AGENT_RESCUE_TRANSCRIPTS: '0'"* ]] ||
    fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"yes (the default), no"* ]] || fail "unexpected stderr: $stderr"
}

@test "TASK_AGENT_RESCUE_TRANSCRIPTS=no makes no sbx calls at all" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/-repo-wt/session.jsonl"

  TASK_AGENT_RESCUE_TRANSCRIPTS=no
  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_equal "$(fake_sbx_call_count)" "0"
}

# --- rescuing ---------------------------------------------------------------

@test "a transcript lands under the same project slug on the host" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/-repo-worktrees-feature-x/abc.jsonl"

  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/-repo-worktrees-feature-x/abc.jsonl"
}

@test "several transcripts across several projects are all rescued" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-a/one.jsonl"
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-a/two.jsonl"
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-b/three.jsonl"

  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/proj-a/one.jsonl"
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/proj-a/two.jsonl"
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/proj-b/three.jsonl"
}

@test "an in-sandbox path containing spaces survives the round trip" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/my project/a b.jsonl"

  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/my project/a b.jsonl"

  run cat "$FAKE_SBX_DIR/calls.log"
  # One log line per argument: proof the space did not split the argument.
  assert_output_contains "arg:$SANDBOX:/home/agent/.claude/projects/my project/a b.jsonl"
}

@test "noise on the listing stream is ignored rather than copied" {
  fake_sbx_add_transcript "Starting sandbox $SANDBOX..."
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-a/one.jsonl"

  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_file_exists "$CLAUDE_CONFIG_DIR/projects/proj-a/one.jsonl"
  # Exactly one exec plus one cp — the noise line produced no copy.
  assert_equal "$(fake_sbx_subcommand_call_count cp)" "1"
}

@test "a sandbox with no transcripts is a silent success" {
  run transcripts_rescue "$SANDBOX"
  assert_success
  assert_equal "$(fake_sbx_subcommand_call_count cp)" "0"
}

@test "nothing is left behind in the destination when a copy fails" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-a/one.jsonl"

  run --separate-stderr env FAKE_SBX_CP_EXIT=1 bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    transcripts_rescue '$SANDBOX'
  "
  assert_failure
  [[ "$stderr" == *"Could not rescue"* ]] || fail "unexpected stderr: $stderr"

  # No truncated .jsonl, and no leftover staging directory either: /insights
  # reads whatever is in there.
  assert_file_not_exists "$CLAUDE_CONFIG_DIR/projects/proj-a/one.jsonl"
  run bash -c "ls -A '$CLAUDE_CONFIG_DIR/projects/proj-a'"
  assert_success
  assert_equal "$output" ""
}

@test "a listing that fails is reported, and names how to get at the files" {
  run --separate-stderr env FAKE_SBX_EXEC_EXIT=1 bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    transcripts_rescue '$SANDBOX'
  "
  assert_failure
  [[ "$stderr" == *"Could not list the agent transcripts"* ]] ||
    fail "unexpected stderr: $stderr"
  [[ "$stderr" == *"sbx cp $SANDBOX:"* ]] || fail "no manual hint: $stderr"
}

@test "the rescue reports where the transcripts went" {
  fake_sbx_add_transcript "/home/agent/.claude/projects/proj-a/one.jsonl"

  run --separate-stderr bash -c "
    source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/transcripts.sh'
    transcripts_rescue '$SANDBOX'
  "
  assert_success
  [[ "$stderr" == *"$CLAUDE_CONFIG_DIR/projects"* ]] ||
    fail "destination not reported: $stderr"
}
