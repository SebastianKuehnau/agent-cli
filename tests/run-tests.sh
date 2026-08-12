#!/usr/bin/env bash
#
# Run the agent-cli test suite.
#
#   tests/run-tests.sh                 unit + integration
#   tests/run-tests.sh unit            one group
#   tests/run-tests.sh spike           the real-Docker-Sandbox spike
#   tests/run-tests.sh all             everything, spike included
#
# Environment:
#   AGENT_TASK_NETWORK_TESTS=1   also run the opt-in test against the real
#                                Sandbox Kit URL on GitHub.

set -euo pipefail

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  cat >&2 <<'EOF'
bats is required to run the test suite but was not found on PATH.

Install it with one of:

  brew install bats-core
  npm install -g bats

bats is a development dependency only: bin/agent-task itself needs nothing
beyond bash, git, curl and sbx.
EOF
  exit 1
fi

group="${1:-default}"

declare -a targets=()
case "$group" in
  default) targets=("$TESTS_DIR/unit" "$TESTS_DIR/integration") ;;
  unit) targets=("$TESTS_DIR/unit") ;;
  integration) targets=("$TESTS_DIR/integration") ;;
  spike) targets=("$TESTS_DIR/spike") ;;
  all) targets=("$TESTS_DIR/unit" "$TESTS_DIR/integration" "$TESTS_DIR/spike") ;;
  *)
    printf 'Unknown test group: %s\n' "$group" >&2
    printf 'Use one of: default, unit, integration, spike, all\n' >&2
    exit 1
    ;;
esac

exec bats --print-output-on-failure --recursive "${targets[@]}"
