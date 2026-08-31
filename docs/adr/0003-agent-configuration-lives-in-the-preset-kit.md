# 0003 — Agent configuration lives in the preset kit, not in task-agent

- **Status:** accepted
- **Date:** 2026-08-31
- **Issue:** [#20](https://github.com/SebastianKuehnau/agent-cli/issues/20)
- **Measured against:** Claude Code 2.1.251 inside `docker/sandbox-templates:claude-code`

## Context

Starting a sandbox is easy, but the agent inside it starts unconfigured: no skills beyond whatever
the image ships, and no way to see how much of the context window a task has eaten. Issue #20 asks
for both.

There are two places that configuration could come from.

**task-agent could write it.** The predecessor tool did exactly that — `--init` generated
`.claude/settings.json`, `.mcp.json` and a `CLAUDE.md` skeleton, which
`docs/current-script-analysis.md` records as F55–F57 with ownership marked OPEN. Phase 1 deliberately
dropped all of it: `--init` writes `.sbx/kit/spec.yaml` and nothing else, and architectural rule 9
keeps agent authentication out of agent-cli entirely.

**The kit could carry it.** A kit already runs `setup.install` commands as the `agent` user, and the
`vaadin` preset already installs a skills plugin that way.

Four facts about the sandbox, established by inspecting a running one:

- `~/.claude/settings.json` is **container-local** and is **seeded by Docker Sandboxes**. It can be
  edited, but overwriting it discards what sbx put there.
- `~/.claude/skills` is a **read-write virtiofs mount of the host's** skills directory. Writing a
  skill there would install it on the developer's machine, not in the sandbox. Plugins avoid this:
  `claude plugin install` writes to `~/.claude/plugins`, which is container-local.
- `jq` is present in the image, so a status line script may use it.
- The status line payload carries `.context_window.used_percentage` (verified in the 2.1.251 binary),
  which is what makes a context-usage bar possible at all.

## Decision

Agent configuration is **kit content**, delivered by a preset. `task-agent` gains no flag, writes no
`.claude/` file and keeps knowing nothing about Claude's configuration format.

The new `vaadin-claude` preset is `vaadin` plus:

- `mattpocock-skills@claude-plugins-official` alongside the Vaadin skills;
- a `setup.install` step that writes `~/.claude/statusline.sh` — model name and a ten-cell
  context-usage bar — and **merges** `statusLine` into `~/.claude/settings.json` with `jq`.

`generic` and `vaadin` stay as they are. A preset is a starting value, so a user who wants the status
line in a generic project copies four lines out of `vaadin-claude`; presets do not compose
(ADR 0001), so shipping the combination as its own name is the only way to offer it.

## Consequences

- **The configuration is the project's, not the tool's.** `--init` copies the spec once; editing or
  deleting the status-line step afterwards is an ordinary kit edit, and a later change to the preset
  never reaches a project that was already initialised.
- **Changing it costs a sandbox rebuild.** Kit changes reach an existing sandbox only by recreating
  it (issue #7), and that is now also true of the agent's own configuration.
- **The setup step is only checkable against a real sbx.** `tests/spike/sandbox-preset-claude.bats`
  covers the three assumptions that would otherwise fail silently inside a sandbox: that the kit
  schema accepts a multi-line command, that the settings merge survives sbx's seeding, and that
  `claude plugin install` leaves the plugins enabled. The unit tests can only assert the shape of the
  shipped file — including that it never writes into `~/.claude/skills`.
- **The status line is a copy, not a reference.** It lives as a heredoc inside `spec.yaml` so that a
  kit stays one file and a sandbox start needs no extra download. Editing it means editing the
  preset.
