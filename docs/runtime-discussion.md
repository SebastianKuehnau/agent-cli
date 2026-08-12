# Runtime Discussion: How should Agent CLI support isolated development runtimes?

Companion to [`current-script-analysis.md`](./current-script-analysis.md). **Architecture discussion only —
nothing is implemented, no runtime is selected, and no abstraction is proposed for adoption.** Every decision
point is marked `OPEN`.

The question this document frames:

> **How should Agent CLI support different isolated development runtimes?**

It compares **Dev Containers** and **Docker Sandboxes** as candidates, records what the existing
`claude-task` script actually demands of a runtime, and identifies which parts of a future architecture
should stay runtime-independent.

---

## 1. Where the current script actually sits

An important framing correction before comparing anything: **`claude-task` does not use Dev Containers.**

- It drives `docker build` and `docker run` directly and **never invokes `devcontainer up`** or the
  devcontainers CLI (`bin/claude-task:710-712`, confirmed by the upstream docs).
- It *generates* a `.devcontainer/devcontainer.json`, but that file is explicitly for **IDE attach only**
  (VS Code / IntelliJ Gateway).
- It sets `-e DEVCONTAINER=true` and mounts into `/home/node`, i.e. it *impersonates* a devcontainer to
  satisfy the image's expectations, without being one.

So today's runtime is **"raw Docker, with a devcontainer-shaped image and a devcontainer.json kept on the
side for IDEs."** Both candidate runtimes below are therefore changes from the status quo, not one of them
being "what we already have". That also means the generated `devcontainer.json` is a **second, hand-maintained
copy** of the mount/env truth that `build_run_args` owns — and the two already disagree (the devcontainer.json
omits the critical `.git` mount, and defaults `TZ` differently).

`OPEN` — is IDE attach a supported first-class path, or an incidental convenience? The answer changes whether a
devcontainer definition must exist at all.

---

## 2. What the runtime is actually asked to do

Full detail is in
[Container runtime requirements](./current-script-analysis.md#container-runtime-requirements). Condensed, the
script needs ten things, ordered by how likely they are to discriminate between runtimes:

| # | Requirement | Why it exists | Discriminating? |
|---|---|---|---|
| R1 | **Bind a host path at an identical absolute path inside the environment** | Git worktree `.git` resolution (F34) | **Yes — the hard one** |
| R2 | Elevated network capability (`NET_ADMIN`/`NET_RAW`) for in-environment iptables | Firewall (F36) | **Yes** |
| R3 | Arbitrary metadata on a built environment, for freshness checks | Config-hash label (F27) | **Yes** |
| R4 | Bind-mount a single host **file** (not just directories) | `claude.json` auth state (F32) | Somewhat |
| R5 | Interactive TTY attach, **plus a second concurrent attach** | `--shell` alongside a live session (F03) | Somewhat |
| R6 | Headless execution preserving a custom exit code (`10`) | `--sync` conflict signalling (F04, F47) | Somewhat |
| R7 | Stable name-based addressing across separate CLI invocations | The only handle the tool keeps (F37, F40) | Somewhat |
| R8 | Read-write host persistence in both directions | Agent edits the worktree; auth writes back | No |
| R9 | Credentials via environment variables, never on disk | `GH_TOKEN`, API keys (F35) | No |
| R10 | Multiple concurrent environments per project | Several branches + a `-sync` run | No |

And what the script **never** asks for — so supporting it would be new capability, not migration:
stop/restart of a stopped environment, detached/background execution, log retrieval, port publishing,
health checks, resource limits, or snapshotting.

### R1 in detail — the constraint that shapes everything

A linked git worktree's `.git` is a *file* containing an absolute path:

```
/repo-worktrees/feature-x/.git   ->  "gitdir: /abs/host/path/repo/.git/worktrees/feature-x"
                                      └─ and that metadir's `commondir` points back to /abs/host/path/repo/.git
```

Neither target lives under the worktree. The script's solution is to mount the main repo's `.git` at
**the same absolute path inside the container** so both pointers resolve unchanged
(`bin/claude-task:359-367`). Elegant, and it means git inside the environment "just works" — including
in-progress rebases surviving across `--sync` and interactive sessions.

The cost: **the environment's filesystem layout is coupled to the host's.** Any runtime that cannot reproduce
an arbitrary host absolute path — a remote machine, a VM with its own filesystem, a rootless setup that remaps
paths, a sandbox that only exposes a fixed workspace mount — breaks git entirely, not partially.

`OPEN` — this is decision #1. Three broad escape routes exist, each with different consequences:

| Route | Mechanism | Consequence |
|---|---|---|
| **Keep worktrees + identical-path mounts** | today's behaviour | Constrains runtimes to local, arbitrary-bind-mount-capable ones |
| **Keep worktrees, rewrite git pointers** | mount the worktree elsewhere and fix `gitdir`/`commondir` inside the environment | Portable, but Agent CLI now owns git plumbing internals; a rewritten worktree may confuse host-side tools |
| **Drop worktrees as the primitive** | clone-per-task, or copy/sync the tree into the environment | Removes R1 entirely and unlocks remote runtimes; loses cheap worktrees, shared object store, host-side IDE access, and the shared-`.git` rebase-handoff trick |

Note that this is really a question about the **isolation primitive**, not the runtime — which is why it is
listed as open question #3 in the analysis document, ahead of the runtime choice itself.

---

## 3. Dev Containers

The [Dev Container specification](https://containers.dev) plus the `devcontainer` CLI: a declarative
`devcontainer.json` describing an environment, with `devcontainer up` / `exec` as the driver.

### Lifecycle

Declarative and multi-phase, with defined hooks: `initializeCommand` (on the **host**, before the container
exists — this is exactly where the upstream repo creates the `~/.claude-container` paths, addressing D-07),
then `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand`.
Containers are normally **persistent and restartable** rather than `--rm`.

### Fit against the requirements

| Req | Fit | Notes |
|---|---|---|
| R1 identical-path mount | **Good** | `mounts` accepts arbitrary bind sources/targets; the upstream `devcontainer.json` proves the pattern (though it currently omits the `.git` mount) |
| R2 network capability | **Good** | `runArgs: ["--cap-add=NET_ADMIN", …]` — already used upstream |
| R3 environment metadata | Adequate | Underlying image labels remain available; the spec adds its own `devcontainerId` |
| R4 single-file mount | Good | Bind mounts are pass-through |
| R5 second attach | Good | `devcontainer exec`, or `docker exec` directly |
| R6 headless + exit code | Good | `devcontainer exec` propagates exit status |
| R7 name addressing | **Weak** | Identity is `devcontainerId`, derived from workspace folder + config — **not** a name the CLI chooses. Today's whole lookup model (`docker ps` name match) would have to change |
| R8-R10 | Good | Standard |

### Strengths

- **A standard.** IDE attach (VS Code, IntelliJ Gateway, GitHub Codespaces) comes for free — and IDE access
  is already something this workflow uses.
- **Lifecycle hooks solve real current gaps.** `initializeCommand` is the natural home for host-state
  bootstrap (D-07), which today nobody does.
- **Features ecosystem** could replace the hand-rolled SDKMAN layer (F51, whose candidate-resolution is
  upstream's own flagged unverified risk, D-14).
- **One definition, two consumers.** Removes today's duplicated mount/env truth between `build_run_args` and
  the generated `devcontainer.json`.

### Weaknesses

- **A Node/npm dependency** (`@devcontainers/cli`) for a bash tool that is currently curl-installable with no
  runtime dependencies beyond git/docker/jq. This collides directly with open question #1 (distribution).
- **Identity mismatch (R7).** The spec addresses environments by workspace folder; Agent CLI addresses them by
  `<project>-<branch>` name. Since each task *is* its own folder (the worktree), this may actually align well
  — one worktree, one devcontainer — but it inverts today's lookup model and needs verification.
- **Persistent-by-default lifecycle** vs today's `--rm`. Better for resumability (open question #5), but it
  introduces state the current tool deliberately has none of, and therefore stale-environment management.
- **Indirection cost.** Debugging moves from "read the `docker run` argv" to "reason about spec resolution".
  Note the current script has no way to print its argv either (no `--dry-run`), so this is a wash unless
  Agent CLI adds one.
- **Not itself an isolation boundary.** Devcontainers are a *configuration* standard; the security properties
  come from whatever the container runtime provides. Choosing devcontainers does not answer "how isolated is
  this?".

`OPEN` — would Agent CLI shell out to the `devcontainer` CLI, or read `devcontainer.json` and drive Docker
itself (today's shape, plus config parsing)? The second keeps dependencies minimal but reimplements a spec —
partially, which is how divergence bugs appear.

---

## 4. Docker Sandboxes

**Terminology caveat, and it matters for the discussion:** "Docker Sandbox" is not a single stable product name
the way "Dev Containers" is. It plausibly refers to any of: Docker's sandboxed/agentic-workload features,
a rootless/hardened container profile, `docker sandbox`-style tooling for agent isolation, or simply
"a hardened `docker run` profile we define ourselves". The comparison below is written against the *properties*
such an approach implies, and each property is testable against whichever concrete implementation is meant.

`OPEN` — **before comparing further, pin down which concrete artifact is intended.** Its actual API and
availability (including on Apple Silicon, which this team uses) determine most of the table below. This is the
single most important information gap in this document.

### Lifecycle

Imperative and short-lived: create → run → discard, per task. Conceptually the closest to today's
`docker run --rm`, so the smallest conceptual change from the status quo.

### Fit against the requirements

| Req | Fit | Notes |
|---|---|---|
| R1 identical-path mount | **Unknown — the decisive question** | A hardened/sandboxed profile may restrict bind mounts to a designated workspace path. If arbitrary host paths cannot be mounted at identical absolute paths, git worktrees do not work without route 2 or 3 from §2 |
| R2 network capability | **Likely restricted, possibly unnecessary** | Granting `NET_ADMIN` inside a sandbox may be disallowed — but a sandbox that provides its own egress policy makes the in-container firewall redundant, which would be a net simplification (F36, F54 could both leave Agent CLI) |
| R3 environment metadata | Unknown | May not expose image labels the same way; Agent CLI might have to track freshness itself |
| R4 single-file mount | Unknown | Often restricted in hardened profiles |
| R5 second attach | Unknown | Ephemeral models frequently support one session only — this would break `--shell`-alongside-a-session (F03) |
| R6 headless + exit code | Likely good | Core to any batch execution model |
| R7 name addressing | Unknown | If addressing is by opaque id, Agent CLI must persist a task→id mapping, i.e. real session state (open question #5) |
| R8 host persistence | **Possibly the crux** | If the sandbox is copy-in/copy-out rather than bind-mounted, the "agent edits your worktree live" property is gone — a fundamental workflow change, not a detail |
| R9 env credentials | Likely good | |
| R10 concurrency | Likely good | |

### Strengths

- **Stronger isolation by construction**, which is the actual point of running an autonomous agent in
  bypass/YOLO permission mode. Today's isolation is a container plus an iptables allowlist that
  **fails open**: if firewall init fails, the image's entrypoint warns and continues without it.
- **Lifecycle already matches** the disposable `--rm` model.
- **Could absorb the firewall entirely** (F36, F54) — removing ~60 lines of allowlist templating and one
  ownership question from Agent CLI.
- **No Node dependency**, keeping the single-file distribution option alive.

### Weaknesses

- **Availability, maturity, and platform support are unverified.**
- **Restrictions may be incompatible with the git-worktree model (R1)** — potentially forcing the isolation
  primitive to change.
- **No IDE-attach story**, unlike devcontainers.
- **Likely no reusable prebuilt-image workflow** comparable to today's project image + cache, which matters:
  a fresh Maven cache per task would be a serious regression in this workflow.

---

## 5. Side-by-side

| Dimension | Raw Docker (today) | Dev Containers | Docker Sandboxes |
|---|---|---|---|
| Lifecycle | create+run+destroy fused, `--rm` | declarative, persistent, multi-hook | create/run/discard, ephemeral |
| Isolation model | container + fail-open iptables allowlist | inherited from the runtime; spec is config-only | isolation is the point; likely stronger by default |
| Worktree mounting | identical-path bind mount | arbitrary binds → same trick available | **unknown; possibly restricted** |
| Persistence | host bind mounts, both directions | host bind mounts + named volumes | unknown; may be copy-in/copy-out |
| Startup | image cached → seconds | similar, plus lifecycle hooks | likely fast; image reuse unclear |
| Resume | none — new container each time | native (restart the container) | unlikely; ephemeral by design |
| CLI integration | `docker` only | `devcontainer` CLI (Node) or reimplement the spec | unknown |
| Agent execution | `docker run … claude …` | `devcontainer exec` or the container's command | likely `run`-style |
| Credentials | `-e` from host env | `containerEnv` / `remoteEnv` / `--env-file` | likely `-e` equivalent |
| Networking | in-container iptables, allowlist, fail-open | same (via `runArgs`) | likely runtime-enforced egress policy |
| Cleanup | `docker rm -f` + `worktree remove` | `devcontainer` teardown; stale-container management needed | implicit on discard |
| Portability | local Docker only | broad (incl. Codespaces) | tied to one vendor implementation |
| IDE attach | via the generated `devcontainer.json` | **native** | none known |
| Testability | fake `docker` on `PATH` | fake `devcontainer` CLI, or test spec generation | unknown; likely fakeable |
| Second attach (`--shell`) | `docker exec` | `devcontainer exec` | **may be unsupported** |
| Delta from today | — | medium (new dependency, new identity model) | small conceptually, **large if R1/R8 fail** |

---

## 6. Implications for Agent CLI architecture

### What should stay runtime-independent

These carry no container semantics and should not change if the runtime changes. From the
[function map](./current-script-analysis.md#existing-function-map):

- **All git and worktree logic** — `git.sh`, `worktree.sh` (F11, F12, F17-F20, F42, F45, F48, F60).
  *Caveat:* only if the isolation primitive stays "git worktree on the host". If the runtime forces
  clone-in-environment, this becomes runtime-dependent by definition.
- **All configuration resolution** — `config.sh` (F14, F21-F25, F35). Pure precedence and parsing.
- **Naming and identity** — `sanitize`, project name, and the *policy* of deriving a stable per-task
  identifier (F13-F16). The runtime consumes the name; it should not define it.
- **CLI surface, parsing, logging, exit codes** — `bin/agent-task`, `logging.sh` (F08, F63, F64, F65).
- **The session/task model** — what a task *is*, its lifecycle states, and how state is discovered or stored
  (F37, [Current state handling](./current-script-analysis.md#current-state-handling)).
- **The sync workflow's decision logic** — preconditions, step ordering, exit-code contract, PR policy
  (F41, F46, F47). Note the *execution* of F42-F46 is currently runtime-bound only because it was written as
  an in-container bash string; that is an implementation accident, not a requirement.
- **Build-tool knowledge** — detection and tool→test-command mapping (F25, F43), even though the commands run
  inside the environment.

### What is inherently runtime-dependent

- Environment build/acquire and freshness (F26-F29).
- Run-argument/spec assembly, mounts, env injection, TTY, capabilities (F30, F32-F36).
- Instance existence, exec, and removal (F37, F40).
- Container definition templates (F51, F52) and the network allowlist (F54) — all three of which also carry
  an open **ownership** question.

### A conceptual interface

Purely to structure the discussion. **Not a proposal to implement, and deliberately not a design.** It is a
restatement of §2's requirements in the vocabulary the task description used:

```
runtime_exists   (task-id)                     -> bool          # incl. "stopped but present"?  OPEN
runtime_create   (definition, task-id, spec)   -> handle
runtime_start    (task-id)                     -> void          # no current equivalent
runtime_stop     (task-id)                     -> void          # no current equivalent
runtime_remove   (task-id, force)              -> void
runtime_exec     (task-id, command[], tty?)    -> exit-code
runtime_shell    (task-id)                     -> exit-code
```

Observations that matter more than the shape:

1. **Today's model fuses create+start+attach+destroy into one blocking call.** A seven-operation interface is
   therefore not a refactoring of existing code — `runtime_start`/`runtime_stop` have **no current
   implementation at all**. Adopting this interface is adopting a persistent-session model
   (open question #5), whether or not that is intended.
2. **`spec` is where the abstraction leaks.** Mounts, env, capabilities, TTY, and workdir must cross the
   boundary somehow. If `spec` is "a list of `docker run` flags", the abstraction is cosmetic. If it is a
   neutral structure, every runtime needs a translator — and R1 (identical-path mounts) may simply be
   *unexpressible* for some runtimes, which no interface design can paper over.
3. **`task-id` presumes name-based addressing (R7).** A runtime with opaque ids forces Agent CLI to persist a
   mapping, which again means real session state.
4. **A one-implementation interface is speculative generality**, which the phase constraints explicitly warn
   against. An interface is justified by a *second* concrete runtime, not by the possibility of one.

`OPEN` — should Agent CLI target one runtime well and refactor later when a second is genuinely needed, or
design the seam up front? The analysis suggests the honest deciding question is narrower: **can the intended
Docker Sandbox satisfy R1 and R8?** If yes, an interface is cheap and worthwhile. If no, the divergence is not
at the runtime layer at all — it is in the isolation primitive, and no `runtime_*` interface will hide it.

### The fail-open firewall is worth separating from the runtime choice

Today's isolation has a specific weakness, independent of which runtime wins: the agent runs with
`--dangerously-skip-permissions` by default, and its network confinement is an in-container iptables allowlist
that **continues without a firewall if initialisation fails** (the image entrypoint warns and proceeds). The
`.claude/settings.json` deny rules that `--init` writes are the only other guardrail, and those are
agent-level, not environment-level.

`OPEN` — should Agent CLI verify that confinement is actually in effect before launching an agent in bypass
mode (fail closed), regardless of runtime? This is a policy question the runtime choice does not settle.

---

## 7. Questions to resolve with the user before implementation

Ordered by how much they constrain everything else.

1. **Which concrete "Docker Sandbox" is meant?** Product, API, platform support. Without this, §4 stays
   speculative and the comparison cannot be completed. *(blocking)*
2. **Are git worktrees the isolation primitive, or one option?** Determines whether R1 is a hard requirement
   or a local optimisation. *(blocking — this is the real fork in the road)*
3. **Is live host-filesystem editing required?** If the agent's edits must appear in the host worktree
   immediately (for host-side IDEs, `git` commands, and review), copy-in/copy-out runtimes are excluded (R8).
4. **Is IDE attach a first-class supported path?** If yes, devcontainers have a large structural advantage and
   a devcontainer definition must exist regardless.
5. **Is resumability wanted?** Persistent, restartable environments versus today's disposable `--rm`. Drives
   whether session state exists at all.
6. **Must `--shell` work alongside a live agent session?** (R5) A genuinely used affordance today that some
   ephemeral models cannot provide.
7. **Distribution:** single-file curl versus a dependency-bearing install. A Node dependency for the
   `devcontainer` CLI conflicts with the former.
8. **Who owns the container definition, the network policy, and the toolchain layer** — Agent CLI or the
   Runtime project? See
   [Functionality ownership questions](./current-script-analysis.md#functionality-ownership-questions).
9. **One runtime now, or a seam from the start?** With one implementation, an interface is unverifiable.
10. **Should confinement fail closed** before an agent starts in bypass mode?
11. **Is per-project image + persistent dependency cache a hard requirement?** A fresh Maven cache per task
    would be a significant regression in this workflow, and it constrains ephemeral runtimes.
12. **Are non-local runtimes (remote/VM/cloud) in scope at all, ever?** If never, R1 stops being a constraint
    and the identical-path mount is simply fine. If someday, it should be designed around now — this is the
    cheapest question to answer and it eliminates the most uncertainty.
