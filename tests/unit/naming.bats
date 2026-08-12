#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/naming.sh"
}

# --- naming_slug ------------------------------------------------------------

@test "slug lowercases and replaces separators with hyphens" {
  assert_equal "$(naming_slug 'Feature/New CRUD')" "feature-new-crud"
}

@test "slug collapses runs of separators into a single hyphen" {
  assert_equal "$(naming_slug 'a///b___c   d')" "a-b-c-d"
}

@test "slug trims leading and trailing separators" {
  assert_equal "$(naming_slug '///feature/x///')" "feature-x"
}

@test "slug truncates and never ends in a hyphen" {
  run --separate-stderr bash -c \
    "source '$AGENT_LIB/naming.sh'; naming_slug 'aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd/eeeeeeeeee'"
  assert_success
  [[ ${#output} -le 40 ]] || fail "slug longer than 40: $output"
  [[ "$output" != *- ]] || fail "slug ends in a hyphen: $output"
}

@test "slug honours an explicit max length" {
  assert_equal "$(naming_slug 'abcdefghij' 4)" "abcd"
}

@test "slug of punctuation-only input falls back to 'branch'" {
  assert_equal "$(naming_slug '///')" "branch"
  assert_equal "$(naming_slug '...')" "branch"
}

@test "slug of empty input falls back to 'branch'" {
  assert_equal "$(naming_slug '')" "branch"
}

@test "slug produces only lowercase letters, digits and hyphens" {
  local slug
  slug="$(naming_slug 'Feature/Ümlaut_v1.2 (WIP)')"
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || fail "unexpected characters in slug: $slug"
}

# --- naming_short_hash ------------------------------------------------------

@test "short hash is 6 hex characters" {
  local h
  h="$(naming_short_hash 'feature/new-crud')"
  assert_equal "${#h}" "6"
  [[ "$h" =~ ^[0-9a-f]{6}$ ]] || fail "not hex: $h"
}

@test "short hash is stable across calls" {
  assert_equal "$(naming_short_hash 'feature/new-crud')" \
    "$(naming_short_hash 'feature/new-crud')"
}

@test "short hash is derived from the raw, unsanitized input" {
  # These three share a slug; the hash is what keeps them apart.
  assert_not_equal "$(naming_short_hash 'feature/foo')" "$(naming_short_hash 'feature-foo')"
  assert_not_equal "$(naming_short_hash 'feature/foo')" "$(naming_short_hash 'Feature/Foo')"
  assert_not_equal "$(naming_short_hash 'feature-foo')" "$(naming_short_hash 'Feature/Foo')"
}

# --- naming_worktree_id -----------------------------------------------------

@test "worktree id is <slug>-<hash>" {
  local id
  id="$(naming_worktree_id 'feature/new-crud')"
  [[ "$id" =~ ^feature-new-crud-[0-9a-f]{6}$ ]] || fail "unexpected id: $id"
}

@test "worktree id is a single path segment even for a branch with slashes" {
  local id
  id="$(naming_worktree_id 'release/1.2/hotfix')"
  [[ "$id" != */* ]] || fail "worktree id contains a slash: $id"
}

@test "same branch always yields the same worktree id" {
  assert_equal "$(naming_worktree_id 'feature/new-crud')" \
    "$(naming_worktree_id 'feature/new-crud')"
}

@test "colliding slugs yield different worktree ids" {
  local a b c
  a="$(naming_worktree_id 'feature/foo')"
  b="$(naming_worktree_id 'feature-foo')"
  c="$(naming_worktree_id 'Feature/Foo')"

  # Same slug prefix ...
  assert_equal "${a%-*}" "feature-foo"
  assert_equal "${b%-*}" "feature-foo"
  assert_equal "${c%-*}" "feature-foo"

  # ... but three distinct identifiers.
  assert_not_equal "$a" "$b"
  assert_not_equal "$a" "$c"
  assert_not_equal "$b" "$c"
}

# --- naming_project_id ------------------------------------------------------

@test "project id is the sanitized repository directory name" {
  assert_equal "$(naming_project_id '/Users/me/projects/My App')" "my-app"
}

@test "project id ignores a trailing slash" {
  assert_equal "$(naming_project_id '/Users/me/projects/my-app/')" "my-app"
}

@test "project id is capped at 20 characters" {
  local id
  id="$(naming_project_id '/tmp/a-very-long-project-directory-name-indeed')"
  [[ ${#id} -le 20 ]] || fail "project id longer than 20: $id"
}

# --- naming_sandbox_name ----------------------------------------------------

@test "sandbox name combines the agent-neutral prefix, project, slug and hash" {
  local name
  name="$(naming_sandbox_name 'my-app' 'feature/new-crud')"
  [[ "$name" =~ ^agent-my-app-feature-new-crud-[0-9a-f]{6}$ ]] || fail "unexpected name: $name"
}

@test "sandbox name is deterministic" {
  assert_equal "$(naming_sandbox_name 'my-app' 'feature/new-crud')" \
    "$(naming_sandbox_name 'my-app' 'feature/new-crud')"
}

@test "sandbox names differ for colliding branch slugs" {
  assert_not_equal "$(naming_sandbox_name 'my-app' 'feature/foo')" \
    "$(naming_sandbox_name 'my-app' 'feature-foo')"
}

@test "sandbox names differ for different projects" {
  assert_not_equal "$(naming_sandbox_name 'app-one' 'feature/foo')" \
    "$(naming_sandbox_name 'app-two' 'feature/foo')"
}

@test "sandbox name uses only characters sbx accepts" {
  local name
  name="$(naming_sandbox_name 'My Äpp!' 'feature/Ümlaut #1')"
  [[ "$name" =~ ^[a-z0-9.+-]+$ ]] || fail "unexpected characters in sandbox name: $name"
}

@test "sandbox name keeps the full hash as its last segment" {
  local name
  name="$(naming_sandbox_name 'a-very-long-project-name-here' \
    'feature/a-very-long-branch-name-that-exceeds-the-cap')"
  [[ "${name##*-}" =~ ^[0-9a-f]{6}$ ]] || fail "hash truncated or missing: $name"
}
