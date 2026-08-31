#!/usr/bin/env bash
# Shared helpers for the agent-cli bats suite.
#
# `status`, `output` and `stderr` are set by bats' own `run`.
# shellcheck disable=SC2154

# No terminal on stdin, ever (issue #14).
#
# bats inherits stdin from whoever started it, so a suite run from a terminal
# hands that terminal to task-agent — and anything that asks (`confirm` in
# lib/logging.sh, reached when a changed Sandbox Kit is found in the default
# TASK_AGENT_KIT_RECREATE=ask mode) then blocks in `read` until the developer
# types something. Under CI, where stdin is not a tty, the same tests pass.
#
# The suite must not depend on which of the two it is running under, so stdin is
# neutralised here, once, for every test file: this is loaded from `setup`, which
# bats runs in the same shell as the test body, so every command a test starts
# inherits /dev/null. Tests that want to exercise a prompt must feed it
# explicitly (see tests/unit/logging.bats), and the non-interactive way to say
# yes is TASK_AGENT_KIT_RECREATE=yes.
exec 0</dev/null

# Repository under test.
AGENT_REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AGENT_REPO_ROOT
export TASK_AGENT="$AGENT_REPO_ROOT/bin/task-agent"
export AGENT_LIB="$AGENT_REPO_ROOT/lib"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

fail() {
  printf '%s\n' "$@" >&2
  return 1
}

assert_success() {
  if ((status != 0)); then
    fail "expected success, got exit status $status" "output:" "$output"
  fi
}

assert_failure() {
  if ((status == 0)); then
    fail "expected failure, got exit status 0" "output:" "$output"
  fi
  if (($# > 0)) && ((status != $1)); then
    fail "expected exit status $1, got $status" "output:" "$output"
  fi
}

assert_equal() {
  if [[ "$1" != "$2" ]]; then
    fail "expected: '$2'" "actual:   '$1'"
  fi
}

assert_not_equal() {
  if [[ "$1" == "$2" ]]; then
    fail "expected values to differ, both were: '$1'"
  fi
}

assert_output_contains() {
  if [[ "$output" != *"$1"* ]]; then
    fail "expected output to contain: '$1'" "output:" "$output"
  fi
}

assert_output_not_contains() {
  if [[ "$output" == *"$1"* ]]; then
    fail "expected output NOT to contain: '$1'" "output:" "$output"
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_file_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path NOT to exist: $1"
}

# assert_argv <expected...> — compare AGENT_SBX_ARGV element by element.
# Never joins the array into a string, so quoting bugs cannot hide.
assert_argv() {
  local -a expected=("$@")
  if ((${#AGENT_SBX_ARGV[@]} != ${#expected[@]})); then
    fail "argv length ${#AGENT_SBX_ARGV[@]}, expected ${#expected[@]}" \
      "actual: $(printf '[%s] ' "${AGENT_SBX_ARGV[@]}")"
  fi
  local i
  for i in "${!expected[@]}"; do
    if [[ "${AGENT_SBX_ARGV[$i]}" != "${expected[$i]}" ]]; then
      fail "argv[$i]: expected '${expected[$i]}', got '${AGENT_SBX_ARGV[$i]}'" \
        "actual: $(printf '[%s] ' "${AGENT_SBX_ARGV[@]}")"
    fi
  done
}

# ---------------------------------------------------------------------------
# Temporary directories
# ---------------------------------------------------------------------------

# make_tmpdir [suffix] — a scratch directory removed in teardown.
# The optional suffix lets a test deliberately create a path containing spaces.
#
# The path is canonicalised with `pwd -P`. This matters: on macOS `mktemp -d`
# hands back /var/folders/... but /var is a symlink to /private/var, and git
# always reports the *physical* path. Without this, every assertion comparing a
# fixture path against git's output fails, and — far worse — a path handed to
# `sbx` would not be the path the worktree's .git pointer refers to.
make_tmpdir() {
  local base
  base="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/agent.XXXXXX")"
  base="$(cd -P "$base" && pwd)"
  if (($# > 0)); then
    base="$base/$1"
    mkdir -p "$base"
  fi
  printf '%s' "$base"
}

# ---------------------------------------------------------------------------
# Git fixtures
# ---------------------------------------------------------------------------

# git_quiet <args...> — run git with identity and hooks fixed so the suite is
# independent of the developer's global git configuration.
git_quiet() {
  git \
    -c user.name="Agent CLI Test" \
    -c user.email="test@example.invalid" \
    -c commit.gpgsign=false \
    -c init.defaultBranch=main \
    -c advice.detachedHead=false \
    "$@"
}

# make_repo <path> [initial-branch] — a repository with one commit.
make_repo() {
  local path="$1" branch="${2:-main}"
  mkdir -p "$path"
  git_quiet -C "$path" init --quiet --initial-branch="$branch"
  printf 'hello\n' >"$path/README.md"
  git_quiet -C "$path" add README.md
  git_quiet -C "$path" commit --quiet -m "initial commit"
  printf '%s' "$path"
}

# add_commit <repo> <file> <content> — commit on the current branch.
add_commit() {
  local repo="$1" file="$2" content="$3"
  printf '%s\n' "$content" >"$repo/$file"
  git_quiet -C "$repo" add "$file"
  git_quiet -C "$repo" commit --quiet -m "add $file"
}

# make_bare_origin <source-repo> <bare-path> — a local bare repo wired up as
# `origin`, so remote-branch behaviour is testable without any network.
make_bare_origin() {
  local repo="$1" bare="$2"
  git_quiet init --quiet --bare "$bare"
  git_quiet -C "$repo" remote add origin "$bare"
  git_quiet -C "$repo" push --quiet origin HEAD
  git_quiet -C "$repo" fetch --quiet origin
  printf '%s' "$bare"
}

# ---------------------------------------------------------------------------
# Fake sbx
# ---------------------------------------------------------------------------

# make_fake_sbx <dir> — install a fake `sbx` at the front of PATH.
#
# It records every invocation, one argument per line with an explicit separator,
# into $dir/calls.log so tests can assert on argument boundaries. The list of
# sandboxes it reports comes from $dir/sandboxes (one name per line), and the
# in-sandbox transcript paths `sbx exec` reports from $dir/transcripts.
make_fake_sbx() {
  local dir="$1"
  mkdir -p "$dir/bin"
  : >"$dir/calls.log"
  : >"$dir/sandboxes"
  : >"$dir/transcripts"

  cat >"$dir/bin/sbx" <<'FAKE'
#!/usr/bin/env bash
log="${FAKE_SBX_DIR}/calls.log"
{
  printf '=== call\n'
  for a in "$@"; do printf 'arg:%s\n' "$a"; done
} >>"$log"

case "$1" in
  ls)
    cat "${FAKE_SBX_DIR}/sandboxes" 2>/dev/null
    ;;
  create)
    # Register the sandbox so a follow-up existence check succeeds.
    name=""
    while (($# > 0)); do
      [[ "$1" == "--name" ]] && name="$2"
      shift
    done
    [[ -n "$name" ]] && printf '%s\n' "$name" >>"${FAKE_SBX_DIR}/sandboxes"
    ;;
  rm)
    # Deregister the sandbox so a follow-up existence check fails.
    name=""
    for a in "$@"; do
      [[ "$a" == "--force" || "$a" == "rm" ]] && continue
      name="$a"
    done
    if [[ -n "$name" && -f "${FAKE_SBX_DIR}/sandboxes" ]]; then
      grep -vx "$name" "${FAKE_SBX_DIR}/sandboxes" >"${FAKE_SBX_DIR}/sandboxes.tmp" || true
      mv "${FAKE_SBX_DIR}/sandboxes.tmp" "${FAKE_SBX_DIR}/sandboxes"
    fi
    ;;
  exec)
    # Stands in for the transcript listing. The command the real sbx would run
    # inside the container is deliberately *not* executed here: the point of
    # the fake is that the paths come from the fixture, not from this host.
    cat "${FAKE_SBX_DIR}/transcripts" 2>/dev/null
    exit "${FAKE_SBX_EXEC_EXIT:-${FAKE_SBX_EXIT:-0}}"
    ;;
  cp)
    # `sbx cp SANDBOX:PATH DST/` — materialise the file at the destination so
    # the caller's atomic move has something to move.
    src="$2"
    dst="${3%/}"
    remote="${src#*:}"
    base="${remote##*/}"
    if [[ -n "$dst" && -d "$dst" ]]; then
      printf 'transcript of %s\n' "$remote" >"$dst/$base"
    fi
    exit "${FAKE_SBX_CP_EXIT:-${FAKE_SBX_EXIT:-0}}"
    ;;
  kit)
    # task-agent does not use `sbx kit` (see tests/spike/sandbox-kit.bats), so
    # this branch exists only so that a regression calling it is visible in the
    # log rather than silently succeeding as an unknown subcommand.
    exit "${FAKE_SBX_KIT_EXIT:-${FAKE_SBX_EXIT:-0}}"
    ;;
  run) : ;;
esac
exit "${FAKE_SBX_EXIT:-0}"
FAKE

  chmod +x "$dir/bin/sbx"
  export FAKE_SBX_DIR="$dir"
  export PATH="$dir/bin:$PATH"
}

# fake_sbx_add_sandbox <name>
fake_sbx_add_sandbox() {
  printf '%s\n' "$1" >>"$FAKE_SBX_DIR/sandboxes"
}

# fake_sbx_add_transcript <absolute-in-sandbox-path>
#
# Make `sbx exec` report one more transcript. The path is used verbatim, so a
# test can deliberately pass one containing a space.
fake_sbx_add_transcript() {
  printf '%s\n' "$1" >>"$FAKE_SBX_DIR/transcripts"
}

# fake_sbx_subcommand_call_count <subcommand>
#
# Matches the whole line, so a path among the arguments cannot be mistaken for
# the subcommand itself.
fake_sbx_subcommand_call_count() {
  grep -cx "arg:$1" "$FAKE_SBX_DIR/calls.log" || true
}

# fake_sbx_calls — the recorded log.
fake_sbx_calls() {
  cat "$FAKE_SBX_DIR/calls.log"
}

# fake_sbx_call_count
fake_sbx_call_count() {
  grep -c '^=== call$' "$FAKE_SBX_DIR/calls.log" || true
}

# fake_sbx_kit_call_count — recorded `sbx kit ...` invocations.
#
# Matches the whole line, so a kit *directory* among the arguments cannot be
# mistaken for the `kit` subcommand.
fake_sbx_kit_call_count() {
  grep -cx 'arg:kit' "$FAKE_SBX_DIR/calls.log" || true
}
