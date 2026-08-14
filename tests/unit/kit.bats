#!/usr/bin/env bats
#
# The Sandbox Kit digest (scaffold_kit_hash) and the applied-kit cache
# (lib/kit.sh) that together let `task-agent <branch>` notice a changed kit
# (issue #7).
#
# The digest is what decides whether a sandbox is offered for rebuilding, so the
# tests below are mostly about what must and must not change it.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  source "$AGENT_LIB/logging.sh"
  source "$AGENT_LIB/naming.sh"
  source "$AGENT_LIB/git.sh"
  source "$AGENT_LIB/scaffold.sh"
  source "$AGENT_LIB/kit.sh"

  TMP="$(make_tmpdir)"
  REPO="$TMP/my-app"
  make_repo "$REPO" >/dev/null
  mkdir -p "$REPO/.sbx/kit"
  printf 'schemaVersion: "2"\nkind: mixin\n' >"$REPO/.sbx/kit/spec.yaml"

  SANDBOX="agent-my-app-feature-x-a84c91"
}

# --- digest -----------------------------------------------------------------

@test "scaffold_kit_hash produces a digest for an initialised project" {
  run scaffold_kit_hash "$REPO"
  assert_success
  [[ "$output" =~ ^[0-9a-f]{64}$ ]] || fail "not a sha256 digest: '$output'"
}

@test "scaffold_kit_hash fails when there is no kit at all" {
  local bare="$TMP/no-kit"
  make_repo "$bare" >/dev/null
  run scaffold_kit_hash "$bare"
  assert_failure
}

@test "the digest is stable across calls" {
  local first second
  first="$(scaffold_kit_hash "$REPO")"
  second="$(scaffold_kit_hash "$REPO")"
  assert_equal "$second" "$first"
}

@test "an identical kit in a different repository has the same digest" {
  # The digest must not depend on where the checkout lives, or moving a
  # repository would look like a kit change.
  local other="$TMP/other-app"
  make_repo "$other" >/dev/null
  mkdir -p "$other/.sbx/kit"
  cp "$REPO/.sbx/kit/spec.yaml" "$other/.sbx/kit/spec.yaml"

  assert_equal "$(scaffold_kit_hash "$other")" "$(scaffold_kit_hash "$REPO")"
}

@test "editing spec.yaml changes the digest" {
  local before
  before="$(scaffold_kit_hash "$REPO")"
  printf 'schemaVersion: "2"\nkind: mixin\nname: changed\n' >"$REPO/.sbx/kit/spec.yaml"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "adding a second kit file changes the digest" {
  # The kit is a directory, not just spec.yaml.
  local before
  before="$(scaffold_kit_hash "$REPO")"
  printf 'extra\n' >"$REPO/.sbx/kit/extra.yaml"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "removing a kit file changes the digest" {
  printf 'extra\n' >"$REPO/.sbx/kit/extra.yaml"
  local before
  before="$(scaffold_kit_hash "$REPO")"
  rm "$REPO/.sbx/kit/extra.yaml"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "renaming a kit file changes the digest" {
  # Paths are hashed alongside contents; a content-only digest would miss this.
  printf 'extra\n' >"$REPO/.sbx/kit/one.yaml"
  local before
  before="$(scaffold_kit_hash "$REPO")"
  mv "$REPO/.sbx/kit/one.yaml" "$REPO/.sbx/kit/two.yaml"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "making a kit file executable changes the digest" {
  # A kit may ship setup scripts, where the bit is the whole point.
  printf '#!/bin/sh\necho hi\n' >"$REPO/.sbx/kit/setup.sh"
  local before
  before="$(scaffold_kit_hash "$REPO")"
  chmod +x "$REPO/.sbx/kit/setup.sh"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "touching a kit file without changing it leaves the digest alone" {
  # Content, not mtime: a checkout or a `touch` must not look like a change.
  local before
  before="$(scaffold_kit_hash "$REPO")"
  touch "$REPO/.sbx/kit/spec.yaml"
  assert_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "a change outside .sbx/kit leaves the digest alone" {
  local before
  before="$(scaffold_kit_hash "$REPO")"
  printf 'not part of the kit\n' >"$REPO/.sbx/other.yaml"
  printf 'nor this\n' >"$REPO/README.md"
  assert_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

@test "the digest works for a repository path containing spaces" {
  local spaced
  spaced="$(make_tmpdir 'my app')/repo with spaces"
  make_repo "$spaced" >/dev/null
  mkdir -p "$spaced/.sbx/kit"
  cp "$REPO/.sbx/kit/spec.yaml" "$spaced/.sbx/kit/spec.yaml"

  run scaffold_kit_hash "$spaced"
  assert_success
  assert_equal "$output" "$(scaffold_kit_hash "$REPO")"
}

@test "a kit file name containing a space is covered" {
  local before
  before="$(scaffold_kit_hash "$REPO")"
  printf 'extra\n' >"$REPO/.sbx/kit/two words.yaml"
  assert_not_equal "$(scaffold_kit_hash "$REPO")" "$before"
}

# --- cache location ---------------------------------------------------------

@test "the cache lives under the main repository's .git directory" {
  assert_equal "$(kit_cache_dir "$REPO")" "$REPO/.git/agent-cli/kit"
}

@test "the cache file is named after the sandbox" {
  assert_equal "$(kit_cache_file "$REPO" "$SANDBOX")" \
    "$REPO/.git/agent-cli/kit/$SANDBOX"
}

# --- cache round trip -------------------------------------------------------

@test "an unrecorded sandbox reads as unknown" {
  run kit_cache_read "$REPO" "$SANDBOX"
  assert_failure
  assert_equal "$output" ""
}

@test "what was written is what is read back" {
  local digest
  digest="$(scaffold_kit_hash "$REPO")"
  run kit_cache_write "$REPO" "$SANDBOX" "$digest"
  assert_success

  run kit_cache_read "$REPO" "$SANDBOX"
  assert_success
  assert_equal "$output" "$digest"
}

@test "a second write replaces the first" {
  kit_cache_write "$REPO" "$SANDBOX" "aaa"
  kit_cache_write "$REPO" "$SANDBOX" "bbb"
  run kit_cache_read "$REPO" "$SANDBOX"
  assert_success
  assert_equal "$output" "bbb"
}

@test "two sandboxes are recorded independently" {
  kit_cache_write "$REPO" "$SANDBOX" "aaa"
  kit_cache_write "$REPO" "agent-my-app-other-77bd02" "bbb"

  run kit_cache_read "$REPO" "$SANDBOX"
  assert_equal "$output" "aaa"
  run kit_cache_read "$REPO" "agent-my-app-other-77bd02"
  assert_equal "$output" "bbb"
}

@test "an empty cache file reads as unknown, not as an empty digest" {
  mkdir -p "$(kit_cache_dir "$REPO")"
  : >"$(kit_cache_file "$REPO" "$SANDBOX")"
  run kit_cache_read "$REPO" "$SANDBOX"
  assert_failure
}

@test "writing leaves no temporary files behind" {
  kit_cache_write "$REPO" "$SANDBOX" "aaa"
  local leftovers
  leftovers="$(find "$(kit_cache_dir "$REPO")" -name '.digest.*' | wc -l | tr -d ' ')"
  assert_equal "$leftovers" "0"
}

@test "removing a record makes the sandbox unknown again" {
  kit_cache_write "$REPO" "$SANDBOX" "aaa"
  kit_cache_remove "$REPO" "$SANDBOX"
  run kit_cache_read "$REPO" "$SANDBOX"
  assert_failure
}

@test "removing a record that does not exist is not an error" {
  run kit_cache_remove "$REPO" "$SANDBOX"
  assert_success
}

@test "an unwritable cache directory is reported but not fatal" {
  # Losing the cache may only cost a needless re-apply, never a failed start.
  local dir
  dir="$(git_git_metadata_dir "$REPO")/agent-cli"
  mkdir -p "$dir"
  chmod -w "$dir"

  run --separate-stderr kit_cache_write "$REPO" "$SANDBOX" "aaa"
  chmod +w "$dir"

  assert_failure
  [[ "$stderr" == *"re-applied next time"* ]] || fail "unexpected stderr: $stderr"
}

# --- the cache is a cache, not a source of truth ----------------------------

@test "the cache is not committed and not visible to git status" {
  kit_cache_write "$REPO" "$SANDBOX" "aaa"
  run git -c core.excludesFile=/dev/null -C "$REPO" status --porcelain
  assert_success
  assert_output_not_contains "agent-cli"
}
