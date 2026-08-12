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

```bash
git clone https://github.com/SebastianKuehnau/agent-cli.git
ln -s "$PWD/agent-cli/bin/agent-task" ~/.local/bin/agent-task
```

## Usage

```
Usage:
  agent-task --init
  agent-task <branch> [--base <branch>]

Commands:
  --init        Download the Docker Sandbox Kit into the current project.
  <branch>      Create or reuse the branch, its worktree and its sandbox,
                then start the agent inside it.

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

## Development

```bash
brew install bats-core     # or: npm install -g bats
tests/run-tests.sh
```

See [CLAUDE.md](./CLAUDE.md) for the module layout, the architectural rules, and the testing
conventions. Background reading lives in [`docs/`](./docs).
