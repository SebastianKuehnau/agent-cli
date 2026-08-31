# Context

Domain vocabulary for agent-cli. Glossary only — no implementation details, no architectural rules
(those live in `CLAUDE.md`), no decisions (those live in `docs/adr/`).

## The core model

**Task** — one unit of agent work, identified by a **branch** name. A task owns exactly one branch,
one worktree and one sandbox. `task-agent <branch>` starts a task; `task-agent --done <branch>` tears
it down. Nothing about a task is written down: it is rediscovered from git and the sandbox runtime on
every invocation.

**Worktree** — the linked git worktree a task's agent edits. It lives outside the main repository,
under a sibling `<project>-worktrees/` directory, and its edits and commits are immediately visible on
the host.

**Sandbox** — the isolated Docker Sandboxes container a task's agent runs in. Named
`agent-<project>-<branch-slug>-<hash>`. Created from a **template** and one **kit**.

**Agent** — the AI coding tool running inside the sandbox. Currently always Claude Code.

## Sandbox configuration

These four terms are easy to confuse. The distinction matters because each one can express things the
others cannot.

**Template** — a container **image** that a sandbox runs, in the sense `sbx template` and `sbx run -t`
use the word. It carries installed software: language runtimes, system packages, browsers. It cannot
express network policy, ports, secrets or MCP servers. agent-cli uses the agent's default template and
supplies no template of its own.

> Note the collision: in everyday speech "template" suggests a reusable starting configuration, which
> is what a **preset** is here. When this repo says *template* it always means the image.

**Kit** — a declarative YAML artifact (`spec.yaml`, schema version 2) that extends a sandbox with
network permissions, environment variables, setup and startup commands, files, credentials and agent
instructions. Read by the sandbox runtime at creation time. A kit cannot express ports, MCP servers or
a template.

**Project Kit** — the kit belonging to one project, at `<project>/.sbx/kit/spec.yaml`. Version
controlled with the project, editable by hand, and the only kit agent-cli passes to a sandbox. It is
the single configurable layer of a task's environment.

**Preset** — a named, remotely published **starting value** for a project kit, selected once at
`task-agent --init <preset>` time. A preset is not a live dependency: `--init` writes a copy, and from
then on the project owns that copy. Changing a preset never affects a project that was already
initialised from it.

**Kit Digest** — a content hash over a project kit's entire directory, used to notice that the kit
changed since the sandbox was built from it. It answers "is this sandbox's kit still current?", a
question the sandbox runtime cannot answer itself.

## Boundaries worth naming

**Host state** — configuration that lives on the developer's machine and is not version controlled:
the global network policy, the sandbox runtime login, agent authentication, registered MCP servers,
stored secrets. A preset cannot carry any of it. Some of it is required once per machine before any
task can start.

**Agent configuration** — the agent's own settings *inside* a sandbox: installed skill plugins, MCP
servers, the status line, `~/.claude/settings.json`. It is neither host state nor a task-agent
concern: it is **kit content**, delivered by a preset's setup steps
([ADR 0003](docs/adr/0003-agent-configuration-lives-in-the-preset-kit.md)). Note `~/.claude/skills`
inside a sandbox is a mount of the *host's* skills directory, and so is host state that a kit must
not write to.

**Passthrough** — forwarding a `sbx` option through `task-agent` to the sandbox runtime. agent-cli
deliberately has none; see [ADR 0002](docs/adr/0002-ports-and-env-stay-outside-task-agent.md).
