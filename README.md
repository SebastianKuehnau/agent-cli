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
  task-agent --init [<preset>]
  task-agent <branch> [--base <branch>]
  task-agent --done <branch>
  task-agent --update
  task-agent --version

Commands:
  --init        Download the Docker Sandbox Kit into the current project,
                starting from <preset>. Default: generic.
                  generic   JAVA_HOME, Maven/GitHub network access.
                  vaadin    generic, plus Vaadin skills and MCP, Playwright,
                            and access to a host Ollama.
                The kit is a starting value: it is yours to edit afterwards,
                and a later change to the preset does not affect it.
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

#### Presets

`--init` takes an optional preset, which decides what the kit starts out containing:

```bash
task-agent --init            # generic (the default)
task-agent --init vaadin
task-agent --init vaadin-claude
```

| Preset | Contains |
| --- | --- |
| `generic` | `JAVA_HOME`, Maven and GitHub network access. Deliberately small. |
| `vaadin` | the above, plus the Vaadin skills and MCP, and Playwright browsers |
| `vaadin-claude` | the above, plus general engineering skills and a status line showing context-window usage |

The presets themselves live in this repository under
[`presets/`](presets/) and are downloaded from its default branch, so the file you read is the file
`--init` hands out.

> **Changed in this version.** `--init` previously downloaded a single kit from a separate repository,
> and that kit was Vaadin-specific even though it was the default. `generic` is now genuinely generic;
> use `--init vaadin` for the Vaadin one.

A preset is a **starting value, not a dependency**. `--init` writes a copy that your project then owns;
nothing reads the preset again afterwards, so a preset edited upstream never changes a project that was
already initialised from it. Delete whatever you do not need — dropping the Playwright install step
from the `vaadin` kit is three lines.

Presets do not compose: `vaadin` contains Playwright rather than being combined with a `playwright`
preset. See [ADR 0001](docs/adr/0001-presets-as-url-lookup-not-kit-composition.md) for why.

`TASK_AGENT_KIT_URL` still takes precedence over any preset, so you can start from a spec of your own:

```bash
TASK_AGENT_KIT_URL=https://example.com/my-kit.yaml task-agent --init
```

If a preset uses the `__PROJECT__` placeholder, `--init` replaces it with your project's directory
name. A spec without the placeholder is copied byte for byte.

#### Agent configuration in the sandbox

`task-agent` writes no agent configuration — no `.claude/settings.json`, no `CLAUDE.md`, no MCP file.
Everything the agent needs inside a sandbox comes from the kit, which is why the `vaadin-claude`
preset exists (see [ADR 0003](docs/adr/0003-agent-configuration-lives-in-the-preset-kit.md)). Its
`setup.install` steps do three things:

- install the Vaadin skills and MCP (`vaadin-skills@vaadin-marketplace`);
- install general engineering skills — tdd, code review, bug diagnosis and so on
  (`mattpocock-skills@claude-plugins-official`);
- write `~/.claude/statusline.sh` and configure it as Claude Code's status line, so every prompt
  shows the model and how much of the context window is used:

  ```
  Opus 5 [####------] 42%
  ```

Two details are load-bearing if you edit that step:

- `~/.claude/settings.json` is seeded by Docker Sandboxes, so the step **merges** into it with `jq`
  rather than writing it. Overwriting it throws away what sbx put there.
- `~/.claude/skills` is a **read-write mount of your host's** skills directory. Never write into it
  from a kit: the file would land on your machine, not in the sandbox. Skills belong in plugins,
  which are container-local.

The kit is yours once `--init` has copied it: deleting the status-line step, or moving it into a
kit that started from `generic`, is an ordinary edit. A changed kit reaches an existing sandbox only
by recreating it, which `task-agent <branch>` offers to do.

#### Vaadin licence in the sandbox

Vaadin Pro components and TestBench need a licence, and **`task-agent` does not deliver one**. This
section records what was measured against `sbx` v0.39.0 so you do not have to rediscover it.

The two Vaadin licence kinds behave differently, and that decides everything:

| Kind | Validated | Needs to be *inside* the sandbox? |
| --- | --- | --- |
| `proKey` (development builds) | online, interactively via your Vaadin account | — interactive login is a non-starter in a sandbox |
| `offlineKey` / `offlineKeyV2` (production builds) | locally, against a signature | **yes** |

Vaadin's own [licence documentation](https://vaadin.com/docs/latest/flow/configuration/licenses) names
the offline key as the container answer: place the file in the build's home directory, or pass it via
the `vaadin.offlineKey` system property or the `VAADIN_OFFLINE_KEY` environment variable.

Three things that do **not** work, each verified:

- **`sbx secret set-custom`** delivers a *placeholder* to the sandbox, not the secret. Its own output
  says `Generated placeholder: sbx-cs-…`; the real value is substituted by the proxy into outbound
  request headers. An offline key is checked locally, so there is no request to rewrite and the
  placeholder fails the signature check.
- **Kit `environment.variables` do not interpolate.** A kit declaring `${VAADIN_OFFLINE_KEY}` delivers
  the literal string `${VAADIN_OFFLINE_KEY}`. Putting the real value in the kit means committing it.
- **`sbx setup`** imports secrets only for the built-in agent services, not arbitrary ones.

So today the options are to run the sandbox's build without commercial features, or to publish the key
into the sandbox yourself with `sbx create --env` outside `task-agent`. Adding a `--env` passthrough to
`task-agent` is a deliberate non-decision — see
[ADR 0002](docs/adr/0002-ports-and-env-stay-outside-task-agent.md).

#### Ports

A kit cannot publish ports; the kit schema has no `ports` field. Publish them on the running sandbox:

```bash
sbx ls                                        # find the sandbox name
sbx ports agent-my-app-feature-x-a1b2c3 --publish 8080
```

Inside the sandbox, `localhost` is the sandbox itself. Services on your **host** are reachable as
`host.docker.internal`, and the network rule for them is written with the loopback name — a rule for
`localhost:11434` is what makes `host.docker.internal:11434` reachable.

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
[task-agent] warning: kit update — so anything that exists only inside the container is lost.
[task-agent] warning: The agent's transcripts are copied to the host first, so they still
[task-agent] warning: reach /insights, but the session itself cannot be resumed afterwards.
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

#### Your agent sessions are kept

The agent runs inside the sandbox, so its session transcripts are written inside the sandbox too — and
Claude Code's `/insights` reads transcripts from **your** machine. Left alone, every session you run
through `task-agent` would be missing from that report, because the sandbox holding it is exactly what
gets deleted.

So before removing a sandbox — on `--done`, and when a changed Sandbox Kit forces a rebuild —
`task-agent` copies the agent's transcripts out to `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`, if
you set one):

```text
[task-agent] Rescuing 3 agent transcript(s) from 'agent-my-app-…' to /Users/you/.claude/projects
[task-agent] Rescued 3 agent transcript(s) from 'agent-my-app-…'
```

Only the session transcripts are copied, in that one direction. Nothing else is read out of the
sandbox, and nothing — credentials included — is copied into it.

This never stands between you and a teardown: if the copy fails, `task-agent` says so, tells you how
to fetch the files by hand, and removes the sandbox anyway. To switch it off:

```bash
TASK_AGENT_RESCUE_TRANSCRIPTS=no task-agent --done feature/new-crud
```

One limit worth knowing: this only covers teardowns `task-agent` performs. Removing a sandbox yourself
with `sbx rm`, `sbx prune` or `sbx reset` takes its transcripts with it.

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

Run the **Prepare release** workflow from the Actions tab and choose `patch`, `minor` or `major`.
That is the whole procedure — nothing is edited or tagged by hand.

It runs the test suite, works the next version out from `lib/version.sh`, writes the constant back,
commits, tags, and pushes the commit and the tag together. Then it builds the single-file bundle with
`scripts/build-bundle.sh` and publishes it as that release's `task-agent` asset — the exact file
`task-agent --update` downloads. `bin/` and `lib/` remain the source of truth; the bundle is a
release-time build artifact, not something committed to the repository.

Computing the version instead of accepting one typed in is what makes a release unable to skip or
reuse a number, and doing the bump and the tag in one atomic push is what keeps them from disagreeing.
Pushing a `v*` tag by hand still works and publishes through the same steps, but then the tag must sit
on a commit whose `TASK_AGENT_VERSION` matches it — otherwise the release is refused.

That check is what makes `--update` trustworthy: a release named `vX.Y.Z` always contains a bundle
that reports `X.Y.Z`, so "already the latest release" can never be a lie.

See [CLAUDE.md](./CLAUDE.md) for the module layout, the architectural rules, and the testing
conventions. Background reading lives in [`docs/`](./docs).
