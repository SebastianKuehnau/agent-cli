#!/usr/bin/env bats
#
# The project's .claude configuration reaching a task's worktree (issue #24).
#
# `git worktree add` checks out tracked files only, so an untracked `.claude/`
# — the usual shape, since `settings.local.json` is personal by convention —
# never appears in the worktree the sandbox mounts. These tests are about that
# gap being filled on the way in, and the copies being taken back out on the
# way out so they cannot be what makes `git worktree remove` refuse.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null

  mkdir -p "$REPO/.sbx/kit"
  printf 'schemaVersion: "2"\nkind: mixin\n' >"$REPO/.sbx/kit/spec.yaml"

  make_fake_sbx "$TMP/fake"

  CLAUDE_CONFIG_DIR="$TMP/claude"
  export CLAUDE_CONFIG_DIR

  # The project's own (untracked) Claude configuration.
  mkdir -p "$REPO/.claude"
  printf '{"permissions":{"allow":["Bash(mvn:*)"]}}\n' >"$REPO/.claude/settings.json"
  printf '{"local":true}\n' >"$REPO/.claude/settings.local.json"
}

task() {
  run --separate-stderr bash -c \
    "cd '$REPO' && '$TASK_AGENT' $(printf '%q ' "$@")"
}

expected_worktree() {
  bash -c "source '$AGENT_LIB/naming.sh'
    source '$AGENT_LIB/worktree.sh'
    worktree_path '$REPO' '$1'"
}

# --- seeding ----------------------------------------------------------------

@test "an untracked .claude reaches the worktree" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_exists "$wt/.claude/settings.json"
  assert_file_exists "$wt/.claude/settings.local.json"
}

@test "the copies are byte-identical to the project's" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  run diff "$REPO/.claude/settings.json" "$wt/.claude/settings.json"
  assert_success
}

@test "nested configuration directories are carried too" {
  mkdir -p "$REPO/.claude/commands"
  printf 'do the thing\n' >"$REPO/.claude/commands/thing.md"

  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_exists "$wt/.claude/commands/thing.md"
}

@test "the copy is reported" {
  task feature/new-crud
  assert_success
  [[ "$stderr" == *".claude/ into the worktree"* ]] ||
    fail "the copy was not reported: $stderr"
}

@test "a project with no .claude is left alone" {
  rm -rf "$REPO/.claude"

  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_not_exists "$wt/.claude"
  [[ "$stderr" != *".claude/ into the worktree"* ]] ||
    fail "reported a copy that cannot have happened: $stderr"
}

@test "a tracked .claude is not copied over — the checkout already has it" {
  printf '{"tracked":true}\n' >"$REPO/.claude/settings.json"
  git_quiet -C "$REPO" add -f .claude/settings.json
  git_quiet -C "$REPO" commit --quiet -m "track claude settings"

  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_equal "$(cat "$wt/.claude/settings.json")" '{"tracked":true}'
}

# --- never overwriting ------------------------------------------------------

@test "a file the agent changed in the worktree is never overwritten" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  printf '{"changed":"by the agent"}\n' >"$wt/.claude/settings.json"

  # Starting the same task again must not undo that.
  task feature/new-crud
  assert_success
  assert_equal "$(cat "$wt/.claude/settings.json")" '{"changed":"by the agent"}'
}

@test "a restart fills in configuration added since the worktree was created" {
  task feature/new-crud
  assert_success

  printf 'new instructions\n' >"$REPO/.claude/notes.md"

  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_exists "$wt/.claude/notes.md"
}

@test "a file deleted from the project is not deleted from the worktree" {
  # Seeding fills gaps; it is deliberately not a sync.
  task feature/new-crud
  assert_success
  rm "$REPO/.claude/settings.local.json"

  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_exists "$wt/.claude/settings.local.json"
}

# --- teardown ---------------------------------------------------------------

@test "--done removes the worktree even though .claude was copied in" {
  # The whole point of the prune: without it the copies are untracked files and
  # git refuses, so every --done of such a project would need --force.
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_exists "$wt/.claude/settings.json"

  # Neutralise the developer's global gitignore, which may well ignore .claude
  # and would hide the very problem this test is about.
  run --separate-stderr bash -c \
    "cd '$REPO' && git config core.excludesFile /dev/null && '$TASK_AGENT' --done feature/new-crud"
  assert_success
  assert_file_not_exists "$wt"
}

@test "a copy the agent changed still stops --done, as any other change would" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  printf '{"changed":"by the agent"}\n' >"$wt/.claude/settings.json"

  run --separate-stderr bash -c \
    "cd '$REPO' && git config core.excludesFile /dev/null && '$TASK_AGENT' --done feature/new-crud"
  assert_failure
  [[ -d "$wt" ]] || fail "a changed file was discarded without --force"
  assert_file_exists "$wt/.claude/settings.json"
}

@test "--done --force removes a worktree whose copies the agent changed" {
  task feature/new-crud
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  printf '{"changed":"by the agent"}\n' >"$wt/.claude/settings.json"

  run --separate-stderr bash -c \
    "cd '$REPO' && git config core.excludesFile /dev/null && '$TASK_AGENT' --done feature/new-crud --force"
  assert_success
  assert_file_not_exists "$wt"
}

@test "a tracked .claude file is never pruned" {
  printf '{"tracked":true}\n' >"$REPO/.claude/settings.json"
  git_quiet -C "$REPO" add -f .claude/settings.json
  git_quiet -C "$REPO" commit --quiet -m "track claude settings"

  task feature/new-crud
  assert_success
  local wt
  wt="$(expected_worktree feature/new-crud)"

  bash -c "source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/projectconfig.sh'
    projectconfig_prune '$REPO' '$wt'"

  # It is identical to the project's copy, but git tracks it, so it stays.
  assert_file_exists "$wt/.claude/settings.json"
}

@test "the prune leaves a directory the agent wrote into" {
  task feature/new-crud
  assert_success
  local wt
  wt="$(expected_worktree feature/new-crud)"
  printf 'the agent wrote this\n' >"$wt/.claude/agent-notes.md"

  bash -c "source '$AGENT_LIB/logging.sh'
    source '$AGENT_LIB/projectconfig.sh'
    projectconfig_prune '$REPO' '$wt'"

  assert_file_exists "$wt/.claude/agent-notes.md"
  assert_file_not_exists "$wt/.claude/settings.json"
}

# --- the opt-out ------------------------------------------------------------

@test "TASK_AGENT_PROJECT_CONFIG=no skips the copy entirely" {
  export TASK_AGENT_PROJECT_CONFIG=no
  task feature/new-crud
  unset TASK_AGENT_PROJECT_CONFIG
  assert_success

  local wt
  wt="$(expected_worktree feature/new-crud)"
  assert_file_not_exists "$wt/.claude"
}

@test "an invalid TASK_AGENT_PROJECT_CONFIG fails before anything is created" {
  export TASK_AGENT_PROJECT_CONFIG=0
  task feature/new-crud
  unset TASK_AGENT_PROJECT_CONFIG
  assert_failure
  [[ "$stderr" == *"Invalid TASK_AGENT_PROJECT_CONFIG"* ]] ||
    fail "unexpected stderr: $stderr"

  assert_file_not_exists "$(expected_worktree feature/new-crud)"
}

@test "an invalid TASK_AGENT_PROJECT_CONFIG fails before anything is removed" {
  task feature/new-crud
  assert_success
  local wt
  wt="$(expected_worktree feature/new-crud)"

  export TASK_AGENT_PROJECT_CONFIG=nope
  task --done feature/new-crud
  unset TASK_AGENT_PROJECT_CONFIG
  assert_failure
  [[ -d "$wt" ]] || fail "worktree was removed despite the invalid setting"
}
