#!/usr/bin/env bash
# Build the self-contained single-file task-agent distribution artifact.
#
# bin/task-agent + lib/*.sh stay the source of truth for development and
# testing (that split is what makes every module unit-testable). This script
# concatenates them into one file with no `source` calls, for the release
# workflow to publish as a GitHub Release asset — for users who install a
# single downloaded file rather than cloning the repository.
#
# No text surgery beyond dropping bin/task-agent's own `source
# "$AGENT_LIB_DIR/..."` lines is needed: every lib file's shebang line and its
# AGENT_*_SH_LOADED include-guard are harmless wherever they land in the
# concatenation, since each file appears exactly once.
#
# Usage: scripts/build-bundle.sh > task-agent

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cat \
  "$ROOT/lib/version.sh" \
  "$ROOT/lib/logging.sh" \
  "$ROOT/lib/naming.sh" \
  "$ROOT/lib/git.sh" \
  "$ROOT/lib/worktree.sh" \
  "$ROOT/lib/sandbox.sh" \
  "$ROOT/lib/scaffold.sh" \
  "$ROOT/lib/kit.sh" \
  "$ROOT/lib/transcripts.sh" \
  "$ROOT/lib/session.sh" \
  "$ROOT/lib/selfupdate.sh"

# shellcheck disable=SC2016  # the pattern is intentionally literal, not expanded.
grep -v '^source "\$AGENT_LIB_DIR/' "$ROOT/bin/task-agent"
