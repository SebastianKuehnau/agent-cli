# 0006 — The main checkout is never a task's worktree; `--fork` runs a task on top of a branch

- **Status:** accepted
- **Date:** 2026-10-15
- **Issue:** [#36](https://github.com/SebastianKuehnau/agent-cli/issues/36)
- **Amends:** architectural rule 5 in `CLAUDE.md`; resolves the open point in
  [ADR 0005](0005-workbench-sandbox-on-the-main-checkout.md)

## Context

`git worktree list --porcelain` reports the main checkout alongside the linked worktrees. Rule 5 —
reuse whatever worktree git has registered for a branch — therefore handed out the main checkout
whenever the requested branch was the one checked out there. `task-agent <branch>` then created a
*task* sandbox that mounted the developer's own checkout.

Before the workbench this was an oddity. With it, it meant two sandboxes on one directory: the
workbench and a task, two agents sharing the same files, index and HEAD, neither aware of the other.
`task-agent --done <branch>` made it worse: it removed the sandbox and then failed on
`git worktree remove` of the main working tree.

Three answers were considered.

**Leave it, and document it.** No code. But the result — two agents on one index — is never what
anyone wants, and documenting a trap does not remove it.

**Warn and proceed.** Keeps every existing invocation working. But the warning would describe a state
the tool had just created on purpose, and the `--done` failure remains.

**Refuse, and offer the two things a user actually means.** Working on the checked-out branch beside
the IDE is the workbench (`--here`). Running a parallel task *on top of* that branch needs a branch of
its own, because git does not allow one branch in two worktrees — that is `--fork`.

## Decision

`task-agent <branch>` refuses when `<branch>` is checked out in the main checkout, before anything is
created, and names both ways out: `task-agent --here` and `task-agent <branch> --fork`.

`task-agent <branch> --fork` starts an ordinary task on `<branch>-fork`, created from the tip of
`<branch>`. It works for any branch that exists locally or as `origin/<branch>`, not only the
checked-out one. `task-agent --done <branch> --fork` tears that task down, so the derived name never
has to be typed.

`task-agent --done <branch>` for the main checkout's branch never touches the checkout. It still
removes a task sandbox of that name if one exists — rescuing its transcripts first — because a
task-agent from before this decision can have created one, and refusing outright would leave a
sandbox only `sbx rm` could remove, losing the transcripts. `--force` is refused there, before
anything is removed: there is no worktree for it to act on.

## Consequences

- **Rule 5 gains one exception:** the main checkout is never a task's worktree. Every other
  registered worktree is still reused, at whatever path git has.
- **A fork is a task like any other.** Its identity is the derived branch name; worktree path and
  sandbox name follow from rule 2 unchanged. Nothing records what it was forked from (rule 1), so
  `--done <branch>-fork` works just as well, and a `<branch>-fork` that already existed for some other
  reason is simply reused.
- **A fork is not re-synced.** An existing fork is reused untouched (rule 4) even after `<branch>`
  moved on, and `task-agent` says so. Re-syncing would mean a reset or a rebase on every start —
  exactly what rule 4 forbids, and destructive to the fork's own commits.
- **Uncommitted changes are not carried.** The fork starts at `<branch>`'s last commit. Changes in
  the main checkout are reported, never stashed, copied or committed: each of those would either
  modify the developer's checkout behind their back or invent a commit they did not make.
- **The base is explicit.** A fork is created with `<branch>` as its base, never from HEAD (rule 3),
  which is also why `--fork` rejects `--base`.
