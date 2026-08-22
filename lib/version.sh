#!/usr/bin/env bash
# The version of task-agent, and the single source of truth for it.
#
# It is a plain constant in the source rather than something derived at runtime
# from git: the single-file release bundle has no repository to ask, and asking
# git would make an installed bundle's version depend on whichever directory it
# happened to be run from.
#
# `.github/workflows/publish.yml` refuses to publish a tag that does not match
# this value, so a release named vX.Y.Z always contains a bundle that reports
# X.Y.Z — which is what makes `--update`'s version comparison trustworthy.
#
# Do not edit this by hand: the "Prepare release" workflow writes it, commits it
# and tags that commit in one step, which is what keeps the tag and this value
# from disagreeing (issue #16).

if [[ -n "${AGENT_VERSION_SH_LOADED:-}" ]]; then
  return 0
fi
AGENT_VERSION_SH_LOADED=1

# shellcheck disable=SC2034  # read by bin/task-agent and lib/selfupdate.sh.
readonly TASK_AGENT_VERSION="0.3.3"
