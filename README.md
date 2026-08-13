# agent-cli

Orchestrator CLI for isolated AI agent development. Each task gets its own git branch, its own linked
git worktree, and its own [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) running Claude Code:

```
branch  →  worktree  →  sandbox  →  agent
```

Your edits and commits happen in a real worktree on your machine, so they are visible to your IDE and
to `git` immediately — the sandbox is the isolation boundary, not a copy of your code.

## Requirements

`bash`, `git`, `curl`, and the [Docker Sandboxes CLI](https://docs.docker.com/reference/cli/sbx/)
(`sbx`). Nothing else.

## Install

Two ways to install, each updated differently:

**Git checkout** — `bin/` and `lib/` stay side by side; update with `git pull`.

```bash
git clone https://github.com/SebastianKuehnau/agent-cli.git
ln -s "$PWD/agent-cli/bin/agent-task" ~/.local/bin/agent-task
```

**Single file** — download the self-contained release bundle; update with `agent-task --update`.

```bash
curl -Lo ~/.local/bin/agent-task \
  https://github.com/SebastianKuehnau/agent-cli/releases/latest/download/agent-task
chmod +x ~/.local/bin/agent-task
```

## Usage

```
Usage:
  agent-task --init
  agent-task <branch> [--base <branch>]
  agent-task --done <branch>
  agent-task --update

Commands:
  --init        Download the Docker Sandbox Kit into the current project.
  <branch>      Create or reuse the branch, its worktree and its sandbox,
                then start the agent inside it.
  --done        Remove the sandbox and worktree for <branch>. The branch
                itself is kept.
  --update      Download and install the latest agent-task release. Only
                works for a single-file install; a git checkout is updated
                with 'git pull' instead.

Options:
  --base        Base branch for a newly created branch. Default: main.
                Ignored when the branch already exists.
  --help, -h    Show this help.
```

### Initialise a project

Once per project:

```bash
cd ~/projects/my-app
agent-task --init
```

This downloads a Sandbox Kit to `.sbx/kit/spec.yaml` and does nothing else — it does not touch
`.gitignore`, does not stage or commit anything, and does not create any agent configuration. Edit the
spec to describe your project's toolchain and network policy, then commit it.

An existing `.sbx/kit/spec.yaml` is never overwritten.

### Updating the Sandbox Kit

`.sbx/kit/spec.yaml` is read when a sandbox is **created**. Editing it afterwards has no effect on a
sandbox that already exists — `agent-task` reuses that sandbox unchanged, kit edits or not.

To apply a changed kit to an existing sandbox today, run this yourself:

```bash
sbx kit add <sandbox-name> .sbx/kit
```

`sbx kit add` is currently an **experimental** Docker Sandboxes feature. `agent-task` does not call it
automatically:

```text
New sandbox:      agent-task uses .sbx/kit when creating it.
Existing sandbox: agent-task reuses the existing sandbox unchanged.
Future Agent CLI: may detect kit changes and use `sbx kit add` automatically — see docs/backlog.md.
```

### Work on a task

```bash
agent-task feature/new-crud
```

That single command creates the branch from `main`, creates a worktree for it, creates a sandbox, and
starts Claude Code inside it. To base a new branch on something else:

```bash
agent-task feature/new-crud --base develop
```

Run the same command again later and everything is reused — same branch, same worktree, same sandbox:

```bash
agent-task feature/new-crud       # resumes where you left off
```

### What gets created

For a repository at `~/projects/my-app` and branch `feature/new-crud`:

| | |
|---|---|
| Branch | `feature/new-crud`, created from `main` |
| Worktree | `~/projects/my-app-worktrees/feature-new-crud-a84c91` |
| Sandbox | `agent-my-app-feature-new-crud-a84c91` |

The trailing hash is derived from the raw branch name, so `feature/foo` and `feature-foo` never
collide.

There is no state file. Everything is rediscovered from `git worktree list` and `sbx ls`, so you can
inspect and clean up with plain `git` and `sbx` commands.

### Tear down a task

```bash
agent-task --done feature/new-crud
```

Removes the sandbox and the worktree for `feature/new-crud`, if they exist. The branch itself is
always kept — `--done` tears down the ephemeral parts of a task, not the branch it lives on. It is
idempotent: running it again when nothing is left just reports that.

If the worktree has uncommitted or untracked changes, `--done` refuses to remove it (git's own
worktree-removal safety check, not a separate one agent-cli adds) rather than silently discarding
work. Commit, stash, or remove those changes and run it again.

### Updating agent-task

```bash
agent-task --update
```

Downloads and installs the latest release in place. This only works for a single-file install (see
[Install](#install) above) — a git checkout has nothing for `--update` to replace, and is told to run
`git pull` instead.

## Development

```bash
brew install bats-core     # or: npm install -g bats
tests/run-tests.sh         # unit + integration; needs no Docker and no network
```

The default run deliberately leaves out one group. Run it separately whenever you touch how the
worktree or the sandbox is mounted:

```bash
tests/run-tests.sh spike   # real Docker Sandboxes; auto-skips when sbx is unavailable
```

The spike is what keeps this project's central assumption honest — that a *linked* git worktree keeps
working inside a sandbox, including committing to the host repository from within it. It is excluded
from the default run because it creates real sandboxes and takes minutes rather than seconds, so a
green `tests/run-tests.sh` on its own does not mean that assumption still holds.

### Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the single-file bundle with
`scripts/build-bundle.sh` and publishes it as that release's `agent-task` asset — the exact file
`agent-task --update` downloads. `bin/` and `lib/` remain the source of truth; the bundle is a
release-time build artifact, not something committed to the repository.

See [CLAUDE.md](./CLAUDE.md) for the module layout, the architectural rules, and the testing
conventions. Background reading lives in [`docs/`](./docs).
