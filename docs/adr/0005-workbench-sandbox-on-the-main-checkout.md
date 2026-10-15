# 0005 — A workbench: one sandbox on the main checkout

- **Status:** accepted
- **Date:** 2026-10-15
- **Issue:** [#34](https://github.com/SebastianKuehnau/agent-cli/issues/34)

## Context

Every agent `task-agent` started used to be a **task**: its own branch, its own linked worktree under
`<project>-worktrees/`, its own sandbox. That is right for work that should run in parallel, and
wrong for the most frequent kind of agent use: a question about the code, or a small change on the
branch already checked out.

The worktree is deliberately outside the repository, so the IDE does not show it. Seeing the agent's
edits means opening the worktree as a second IDE project — a second window, a second index. The
observed result was that for anything small, Claude Code got run directly on the host **without a
sandbox**, which is the very thing task-agent exists to prevent.

Four ways out were considered.

**Open the worktree in the IDE automatically.** Cheap, and changes nothing about the model. But it is
still a second window and a second index, which was the friction in the first place, and the agent
still works on a fresh branch rather than on the developer's current state.

**A sandbox per branch on the main checkout.** Keeps "one sandbox per branch". But the main
checkout's branch changes under a running sandbox whenever the developer switches in the IDE, so the
name would describe a branch the sandbox is not on, and sandboxes would accumulate per branch ever
checked out.

**Run the agent without a sandbox.** What was happening anyway. Gives up isolation entirely.

**One branch-independent sandbox per project on the main checkout.** The agent edits exactly the
files the IDE has open, inside a sandbox.

## Decision

`task-agent --here` in the main checkout creates or re-attaches the project's **workbench**: one
sandbox, `agent-<project>-workbench`, whose only workspace is the main checkout. No branch is created
and no worktree is added. It persists between invocations. `task-agent --done --here` removes it,
rescuing its transcripts first, and never touches the checkout.

`--here` means "the agent for the checkout I am standing in". Inside a task's worktree it therefore
starts that task, exactly as `task-agent <its branch>` would — never a second sandbox on the same
directory. `--done --here` inside a task's worktree is refused, because it would delete the directory
the caller is standing in.

## Consequences

- **A workbench is not a task.** "A task owns exactly one branch, one worktree and one sandbox"
  still holds; the workbench owns a sandbox and nothing else. It is a second concept, not an
  exception to the first, and `CONTEXT.md` names it separately.
- **The agent sees whatever is checked out**, including the developer's uncommitted changes, and can
  commit on that branch. That is the point, and it is also the cost: there is no isolation *between
  the developer and the agent*, only between the agent and the machine. Rules about what the agent
  may do with git belong in the project's `.claude/settings.json`, not in task-agent.
- **One workspace suffices.** The main checkout's `.git` is inside it, so the second workspace a task
  needs — for a linked worktree's `gitdir:` pointer — does not exist here, and there is no
  `.claude/` to seed (ADR 0004): it is already in the main checkout.
- **The name cannot collide with a task's.** A task's sandbox name always ends in a hex hash, and
  `workbench` is not hex. It does carry the project prefix, so `--list` must recognise it before its
  orphan pass, or it would be reported as a sandbox with no worktree.
- **A task and the workbench could still share a directory**, when the main checkout had a task's
  branch checked out — `task-agent <branch>` then reused the main checkout as that task's worktree.
  Resolved by [ADR 0006](0006-main-checkout-is-never-a-task-worktree.md): that is now refused, and
  `task-agent <branch> --fork` runs a parallel task on top of the branch instead.
- **Architectural rule 1 is untouched.** The workbench is rediscovered by name from `sbx ls -q` like
  any task's sandbox; nothing records that it exists.
