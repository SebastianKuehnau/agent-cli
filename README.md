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
ln -s "$PWD/agent-cli/bin/task-agent" ~/.local/bin/task-agent
```

**Single file** — download the self-contained release bundle; update with `task-agent --update`.

```bash
curl -Lo ~/.local/bin/task-agent \
  https://github.com/SebastianKuehnau/agent-cli/releases/latest/download/task-agent
chmod +x ~/.local/bin/task-agent
```

### Coming from `agent-task`

The command was called `agent-task` up to v0.1.0 and is `task-agent` from v0.2.0 on. Nothing about
your existing tasks changes — branches, worktrees and sandboxes keep their names, so tasks started
with `agent-task` are picked up by `task-agent` unchanged.

Only how you invoke it changes:

```bash
# git checkout
ln -sfn "$PWD/agent-cli/bin/task-agent" ~/.local/bin/task-agent
rm ~/.local/bin/agent-task

# single file: --update keeps working and installs the renamed tool in place,
# because each release also publishes the bundle under the old asset name.
agent-task --update
mv ~/.local/bin/agent-task ~/.local/bin/task-agent
```

## Usage

```
Usage:
  task-agent --init
  task-agent <branch> [--base <branch>]
  task-agent --done <branch>
  task-agent --update
  task-agent --version

Commands:
  --init        Download the Docker Sandbox Kit into the current project.
  <branch>      Create or reuse the branch, its worktree and its sandbox,
                then start the agent inside it.
  --done        Remove the sandbox and worktree for <branch>. The branch
                itself is kept.
  --update      Install the latest task-agent release, unless it is already
                installed. Only works for a single-file install; a git
                checkout is updated with 'git pull' instead.
  --version     Print the installed version.

Options:
  --base        Base branch for a newly created branch. Default: main.
                Ignored when the branch already exists.
  --help, -h    Show this help.
```

### Initialise a project

Once per project:

```bash
cd ~/projects/my-app
task-agent --init
```

This downloads a Sandbox Kit to `.sbx/kit/spec.yaml` and does nothing else — it does not touch
`.gitignore`, does not stage or commit anything, and does not create any agent configuration. Edit the
spec to describe your project's toolchain and network policy, then commit it.

An existing `.sbx/kit/spec.yaml` is never overwritten.

### Updating the Sandbox Kit

Edit `.sbx/kit` whenever your project's toolchain or network policy changes, then run
`task-agent <branch>` again. It notices:

```text
New sandbox:      task-agent uses .sbx/kit when creating it.
Existing sandbox: task-agent compares .sbx/kit against the kit that sandbox was built from,
                  and offers to rebuild the sandbox when they differ.
Unchanged kit:    nothing happens.
```

The comparison covers the whole `.sbx/kit` directory — not just `spec.yaml` — so editing, adding,
removing or renaming any file in it counts as a change. Moving your checkout somewhere else does not.

**Applying a kit means recreating the sandbox.** Docker Sandboxes has no in-place kit update: `sbx kit
add` only *appends* a kit to a sandbox, and recreates the sandbox to do even that. So `task-agent`
asks first, and tells you what is at stake:

```text
[task-agent] warning: The Sandbox Kit changed since sandbox 'agent-my-app-…' was created.
[task-agent] warning: Applying it recreates that sandbox — Docker Sandboxes has no in-place
[task-agent] warning: kit update — so anything that exists only inside the container is lost,
[task-agent] warning: the agent's session state in there included.
[task-agent] warning: The worktree on the host, its files and its commits are not affected.
[task-agent] Recreate 'agent-my-app-…' from the current kit? [y/N]
```

Answer `n` and the sandbox is left exactly as it was; you are asked again next time, so nothing is
silently forgotten. Set `TASK_AGENT_KIT_RECREATE` to skip the question:

```bash
TASK_AGENT_KIT_RECREATE=yes task-agent feature/new-crud   # rebuild without asking
TASK_AGENT_KIT_RECREATE=no  task-agent feature/new-crud   # never rebuild, just report
```

Without a terminal to ask at (a script, CI), the answer is no and `task-agent` says so rather than
rebuilding your sandbox unasked.

Which kit a sandbox was built from is remembered in `.git/agent-cli/kit/` in your repository. It is a
cache, not state: delete it and the only consequence is that those sandboxes are treated as up to date
again, so the next kit change is the one that gets offered.

### Work on a task

```bash
task-agent feature/new-crud
```

That single command creates the branch from `main`, creates a worktree for it, creates a sandbox, and
starts Claude Code inside it. To base a new branch on something else:

```bash
task-agent feature/new-crud --base develop
```

Run the same command again later and everything is reused — same branch, same worktree, same sandbox:

```bash
task-agent feature/new-crud       # resumes where you left off
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

There is no state file. What exists is rediscovered from `git worktree list` and `sbx ls`, so you can
inspect and clean up with plain `git` and `sbx` commands. The one thing written down — which Sandbox
Kit a sandbox last got, under `.git/agent-cli/kit/` — is a cache that nothing depends on being there.

### Tear down a task

```bash
task-agent --done feature/new-crud
```

Removes the sandbox and the worktree for `feature/new-crud`, if they exist. The branch itself is
always kept — `--done` tears down the ephemeral parts of a task, not the branch it lives on. It is
idempotent: running it again when nothing is left just reports that.

If the worktree has uncommitted or untracked changes, `--done` refuses to remove it (git's own
worktree-removal safety check, not a separate one agent-cli adds) rather than silently discarding
work. Commit, stash, or remove those changes and run it again.

### Updating task-agent

```bash
task-agent --update
```

Installs the latest release in place — but only if it is not already installed:

```bash
$ task-agent --version
0.2.0
$ task-agent --update
[task-agent] task-agent 0.2.0 is already the latest release.
```

The installed version is the one printed by `task-agent --version`; the latest released version is
read from where `…/releases/latest` redirects to, which needs no GitHub token and no API quota. If
that check cannot be made at all, `task-agent` says so and downloads anyway, so a hiccup in the check
can never leave you unable to update.

This only works for a single-file install (see [Install](#install) above) — a git checkout has
nothing for `--update` to replace, and is told to run `git pull` instead.

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

The spike is what keeps this project's assumptions about Docker Sandboxes honest — that a *linked* git
worktree keeps working inside a sandbox, including committing to the host repository from within it,
and that recreating a sandbox really does apply a changed kit to it. It is
excluded from the default run because it creates real sandboxes and takes minutes rather than seconds,
so a green `tests/run-tests.sh` on its own does not mean those assumptions still hold.

### Releasing

Bump `TASK_AGENT_VERSION` in `lib/version.sh` in the commit you are about to tag, then push the
matching `v*` tag. That runs `.github/workflows/release.yml`, which refuses a tag that does not match
the declared version, builds the single-file bundle with `scripts/build-bundle.sh`, and publishes it
as that release's `task-agent` asset — the exact file `task-agent --update` downloads. `bin/` and
`lib/` remain the source of truth; the bundle is a release-time build artifact, not something
committed to the repository.

The tag check is what makes `--update` trustworthy: a release named `vX.Y.Z` always contains a bundle
that reports `X.Y.Z`, so "already the latest release" can never be a lie.

See [CLAUDE.md](./CLAUDE.md) for the module layout, the architectural rules, and the testing
conventions. Background reading lives in [`docs/`](./docs).
