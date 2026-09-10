# 0002 — Ports and environment variables stay outside task-agent

- **Status:** accepted
- **Date:** 2026-08-21
- **Measured against:** Docker Sandboxes `sbx` v0.39.0 (`def8cb0523a77e757bdd6ef52b459fe374f3783e`)

## Context

Two things a project plausibly wants from its sandbox cannot be expressed in a project kit, so the
question arises whether `task-agent` should forward them to `sbx`.

**Ports.** A Vaadin dev server on 8080 is only reachable from the host if the port is published. The
kit schema has no `ports` field — `sbx kit validate` rejects one. Publishing happens either at creation
time (`sbx create --publish`) or afterwards on a running sandbox (`sbx ports <name> --publish 8080`).

**Environment variables carrying host secrets.** A Vaadin Pro or TestBench licence is the concrete
case. Three measurements bound it:

- Kit `environment.variables` does **not** interpolate. A kit declaring `${VAR}` delivers the literal
  string `${VAR}` into the sandbox (verified in a throwaway sandbox). So a kit cannot collect a value
  from the host, and putting the value in the kit means committing it.
- `sbx secret set-custom` delivers a **placeholder** to the sandbox, not the secret. Its own output
  says so: `Generated placeholder: sbx-cs-…`. The real value is substituted by the proxy into outbound
  **request headers** only. A Vaadin offline key is validated locally, against a signature — there is
  no request for the proxy to rewrite, so a placeholder fails.
- `sbx setup` imports secrets only for the built-in agent services, not arbitrary ones.

Together: getting a locally-validated key into a sandbox requires either an option passthrough in
`task-agent` or the secret in a version-controlled file. There is no third way in v0.39.0.

## Decision

`task-agent` forwards **no** `sbx` options. Its argument surface stays `--init [PRESET]`,
`<branch> [--base <branch>]`, `--done`, `--update`, `--version`.

- Ports are published by hand after the sandbox exists: `sbx ports <sandbox> --publish 8080`.
- Licence delivery is **documented, not implemented**. `README.md` records what works, what does not,
  and why; `--init vaadin` prints a pointer to that section.

## Consequences

- **`task-agent` keeps one job.** It maps a branch to a worktree and a sandbox. Every option it
  forwards is an option it must parse, validate, test and version, and each one invites the next —
  `--publish` invites `--env`, which invites `--memory`, `--cpus`, `--template`.
- **Two commands instead of one, for ports.** The user must look up the generated sandbox name. This is
  real friction and the main argument against this decision.
- **Consistency is the deciding factor.** A tool that forwards `-e` but not `-p` is harder to explain
  than one that forwards neither. If this is ever reopened, reopen it for both at once.
- **The licence limitation is visible rather than silently broken.** A reader who needs Pro components
  finds the measurements instead of rediscovering them.

## What would justify revisiting this

A single decision to add passthrough for `--publish` **and** `--env` together, with the argument that
`task-agent` is the only thing that knows the sandbox name at creation time. Note that both options are
create-time only: `sbx run` ignores `--publish` when re-attaching, and `--env` applies to the agent
session. Any passthrough must therefore be a pure argv addition in `lib/sandbox.sh` and must not be
remembered anywhere — architectural rule 1 still applies.

## Re-measured on sbx v0.42.1 (2026-09-10)

The decision is unchanged, and the list of options it would have to forward got *shorter*:

- **CPU and memory are kit content now.** v0.42.0 lets a kit set them in a `sandbox.resources` block,
  so a project that needs them writes them in its own `.sbx/kit/spec.yaml` and task-agent forwards
  nothing. `--cpus`/`--memory` are off the table for good; only `--publish` and `--env` are left, which
  is exactly the pair this decision says to reopen together or not at all.
- **Ports changed behaviour, in the direction of the documented workaround.** v0.42.0 is a `BREAKING`
  release for ports: `--publish` and kit-declared ports now default to `tcp4` instead of dual-stack
  `tcp`, so `http://localhost:<port>` reaches a sandbox service that listens only on IPv4 — which is
  the common case for a dev server. `sbx ports <sandbox> --publish 8080` also starts a stopped sandbox
  by itself now. The by-hand step this ADR documents therefore got more reliable, not less.
- The kit schema still has no `ports` field, and kit `environment.variables` still does not
  interpolate, so the two measurements that produced this decision stand.
