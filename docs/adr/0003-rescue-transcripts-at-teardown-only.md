# 0003 — Transcripts are rescued at teardown only

- **Status:** accepted
- **Date:** 2026-08-30
- **Measured against:** Docker Sandboxes `sbx` — `sbx --help`, `sbx cp --help`, `sbx exec --help`

## Context

An agent's session transcripts live at `$CLAUDE_CONFIG_DIR/projects/<slug>/<session-id>.jsonl` on the
machine the agent runs on. In agent-cli's model that machine is the sandbox, which has its own
`~/.claude`. Claude Code's `/insights` builds its report by scanning the **host's** config directory,
every project in it, and does not collect cloud sessions. So every session run through `task-agent` is
invisible to the analysis meant to improve how the developer works — and the sandbox holding those
transcripts is exactly what `--done` deletes.

Given that transcripts have to be copied host-wards at some point, the question is **when**.

Three candidate triggers exist:

1. **At teardown**, immediately before each `sandbox_remove`.
2. **Periodically, or every time the agent is attached to.**
3. **On a sandbox lifecycle event**, so that nothing has to be scheduled at all.

### What `/insights` does with a transcript it has already seen

`/insights` keeps two caches, and they do not behave the same way:

| Cache | Path | Staleness check |
|---|---|---|
| Session meta (counts, duration, tokens, commits) | `~/.claude/usage-data/session-meta/<id>.json` | yes — `transcript_mtime` |
| Facets (`underlying_goal`, `outcome`, `user_satisfaction`, `friction`) | `~/.claude/usage-data/facets/<id>.json` | **no** — keyed by session id alone |

A session copied out mid-flight therefore has its *qualitative* verdict frozen at that moment — the
outcome of a session that had not finished yet — while the numbers keep growing underneath it. The
facets cache is never revisited for that session id.

### Whether there is an event to hook

`sbx`'s command set is `completion, cp, create, daemon, diagnose, env, exec, help, kit, login, logout,
ls, mcp, policy, ports, prune, reset, rm, run, secret, setup, skills, stop, template, tui, version`.
There is no `events`. Beyond the CLI:

- **`docker events`.** Sandboxes are containers, so this would work — but `docker` is explicitly not a
  runtime dependency of agent-cli, and it would need a process that outlives the invocation.
  `task-agent` ends in `exec sbx run`; there is nothing left of it to receive an event.
- **A kit hook.** The kit schema carries setup and startup commands. Even granting a teardown
  equivalent, it would run *inside* the container and could not write to the host — that is the
  isolation boundary the whole problem is about.
- **`sbx daemon`.** Manages sandboxd; it is not a contract for attaching hooks.

There is also a mismatch in what "shutdown" would even mean. `sbx stop` leaves the container filesystem
intact — stopping loses nothing. Only `sbx rm`, `sbx prune` and `sbx reset` destroy it. A shutdown
event would fire when nothing is at risk.

## Decision

Rescue transcripts **once per sandbox, immediately before it is destroyed**, at the two places
agent-cli destroys one: `session_done` and `session_sync_kit`.

Not periodically, not on attach, and not driven by an event.

The facets cache is deliberately **not** invalidated when an already-rescued transcript is overwritten
(which the kit-recreate path can do). Doing so would hardcode an undocumented Claude Code cache layout
into agent-cli.

## Consequences

- **Rescuing once is not merely cheaper, it is more correct.** The trigger coincides with the moment a
  session is definitively over, which is the only moment at which a frozen qualitative verdict is the
  right verdict.
- **No background process, no new dependency, no scheduling.** `task-agent` stays a one-shot command
  that ends by handing the terminal to the agent.
- **A teardown that agent-cli does not perform rescues nothing.** `sbx prune`, `sbx reset` and a
  hand-run `sbx rm` destroy transcripts without agent-cli ever being involved. `sbx prune` in
  particular is an ordinary thing to type when a disk fills up. This is the real cost of this decision
  and it is not mitigated anywhere.
- **The kit-recreate path can rescue the same session twice**, and the second copy will not be
  re-analysed for facets. The numbers are corrected on the next report; the verdict is not.
- **The rescue is a step, not a command.** There is no `--rescue` flag, so there is no supported way to
  ask for one ahead of a manual cleanup. Adding one is a separate decision under "Scope discipline" in
  `CLAUDE.md`, and would be its own issue.

## What would justify revisiting this

Any of:

- `sbx` growing an event stream, or a documented teardown hook that can reach the host. That removes
  the second of the two reasons above, though not the first.
- `/insights` gaining a staleness check on the facets cache. That removes the first, though not the
  second — and it would make periodic syncing merely wasteful rather than wrong.
- Evidence that transcripts are being lost to `sbx prune` often enough to matter. The answer to that
  is a `--rescue` command, not a change of trigger.
