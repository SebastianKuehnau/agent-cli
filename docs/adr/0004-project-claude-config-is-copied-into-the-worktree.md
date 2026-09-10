# 0004 — The project's `.claude` is copied into the worktree

- **Status:** accepted
- **Date:** 2026-09-10
- **Issue:** [#24](https://github.com/SebastianKuehnau/agent-cli/issues/24)
- **Amends:** [ADR 0003 — Agent configuration lives in the preset kit](0003-agent-configuration-lives-in-the-preset-kit.md)

## Context

An agent started with `task-agent <branch>` behaves differently from the same agent started in the
main checkout: the project's permission allowlist, its slash commands and its `CLAUDE.md` overrides
are all missing.

The cause is git, not the sandbox. `git worktree add` checks out **tracked** files, and a project's
`.claude/` is very often untracked — either entirely, or at least `settings.local.json`, which is
personal by convention and routinely gitignored. So the worktree has no `.claude/`, the sandbox
mounts that worktree at the same absolute path it has on the host, and Claude Code inside finds no
project configuration to read.

Four ways out were considered.

**Do nothing; tell people to commit `.claude/settings.json`.** Consistent with ADR 0003 and free.
But it cannot reach `settings.local.json` at all — the file is untracked *on purpose* — and it makes
a personal tooling choice into a repository-wide one.

**Mount the main repository's `.claude` as an extra workspace.** Cheap, and `sbx` already mounts
every workspace at its host path. But Claude Code reads project settings from `<cwd>/.claude`, and
the main repository's `.claude` is at a different path, so nothing would read it.

**Symlink `<worktree>/.claude` at `<main-root>/.claude` and mount the target.** One source of truth,
no drift. Rejected on the blast radius: a read-write mount lets a sandboxed agent edit the real
project's configuration, and a read-only one breaks Claude Code the moment it records a permission
decision.

**Copy.** The files end up exactly where Claude Code looks, and the sandbox can only ever change the
task's own copy.

## Decision

`task-agent <branch>` copies `<main-root>/.claude` into the task's worktree, **filling gaps only**.
`task-agent --done <branch>` removes those copies again, immediately before removing the worktree.
`TASK_AGENT_PROJECT_CONFIG=no` turns both off.

Four rules make that safe:

1. **Nothing is ever overwritten.** A file already present in the worktree is skipped, whether it got
   there by being tracked, by an earlier start, or by the agent writing it. That is what makes the
   copy safe to run on *every* start, so a task started again picks up configuration added since,
   and never loses a change the agent made.
2. **Nothing is ever deleted by the copy.** It fills gaps; it is not a sync. Removing a file from the
   project does not remove it from a running task's worktree.
3. **The prune re-derives what to remove, three conditions deep**: the main repository has a file at
   the same relative path, the two are byte-identical, and git does not track it in the worktree.
   A file the agent changed therefore stays — and still stops `--done` exactly as any other
   uncommitted change would.
4. **Neither step can fail a task.** A failed copy is reported and the task starts anyway; a failed
   prune is reported and the teardown continues, the same rule the transcript rescue follows.

## Consequences

- **ADR 0003 still holds, and this is not an exception to it.** That ADR is about the agent's
  configuration *inside* the sandbox — `~/.claude`, skills, MCP servers, the status line — which
  remains kit content that task-agent never writes. This is the *project's* configuration, which
  lives in the repository, is version-controllable, and is missing only because of how a worktree is
  built. task-agent still knows nothing about Claude's configuration format: it copies opaque files.
- **The prune is what keeps `--force` exceptional.** Without it the copies are untracked files, git
  refuses to remove the worktree, and every `--done` of such a project needs `--force` — which would
  teach the habit of reaching for `--force`, and eventually lose real work with it. The test that
  covers this was verified to fail when the prune is removed.
- **A copy can drift from the project's original.** Deliberate: the alternative is a shared file a
  sandboxed agent can edit. The copies are per-task and disappear with the task.
- **It is `.claude` and nothing else.** Not a general file-copying feature and not configurable to
  other paths, so there is no mechanism here to grow.
- **Whether this matters at all depends on the machine.** Where `.claude` is in the developer's
  global gitignore it was never dirt to begin with, and the prune is invisible. Where it is not, the
  prune is the difference between `--done` working and refusing. Tests neutralise
  `core.excludesFile`, or they would only pass on the first kind of machine.
