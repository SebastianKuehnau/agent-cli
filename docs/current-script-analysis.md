# Existing `claude-task` Analysis

Phase 0 analysis. **Documentation only — nothing has been migrated, refactored, removed, or
decided.** Every classification in this document is a proposal for review, and every ownership or
architecture question is marked `OPEN`.

## Source and method

| Item | Value |
|---|---|
| Analysed file | `SebastianKuehnau/claude-container` → `bin/claude-task` |
| Size | 1137 lines, 44,497 bytes, 43 functions |
| Declared version | `CLAUDE_TASK_VERSION="0.2.1"` (`:20`) |
| Branch / commit | `main`, last commit touching the file `c664bc3142c3` (2026-07-24) |
| Fetched | 2026-08-11 |

All `:NNN` references are line numbers in that file. Supporting context was read from the same
repo: `.devcontainer/Dockerfile`, `devcontainer.json`, `docker-compose.yml`,
`scripts/entrypoint.sh`, `scripts/init-firewall.sh`, `scripts/init-vaadin-plugins.sh`,
`.github/workflows/build.yml`, `README.md`, `CLAUDE.md`, `docs/working-with-tasks.md`,
`docs/claude-task-cheatsheet.md`, `docs/container-capabilities.md`, and both `tasks/*.md` specs.

Claims in this document are tagged by evidence class:

- **[code]** — read directly from the script.
- **[verified]** — reproduced by executing code in a throwaway repo on macOS (see
  [Verification log](#verification-log)). No Docker was involved; no upstream repo was modified.
- **[docs]** — asserted by the upstream documentation.

---

## Overview

`claude-task` is a single-file bash orchestrator that gives each git branch its own git worktree and
its own throwaway Docker container running Claude Code. It is distributed as a standalone file
curl'd into `~/.local/bin` and is designed to work in a target project with no clone of its home
repository — which is why every template it scaffolds is embedded as a heredoc (`:617-621` [code]).

The core model, in one line: **branch → worktree → container → agent**, with the container always
`--rm` and `exec`'d into, so there is no persistent container and no session state file anywhere.

Four architectural properties dominate everything else and are the main input to the Agent CLI
design discussion:

1. **State is derived, never stored.** There is no session database, lockfile, or state directory.
   The "session" for a branch is reconstructed on every invocation from three sources: the branch
   name (as an argument), `git worktree list --porcelain`, and `docker ps`. See
   [Current state handling](#current-state-handling).
2. **The container is disposable; the worktree is durable.** `docker run --rm` (`:312`) plus `exec`
   (`:449`) means "pause" is just exiting, and "resume" is a brand-new container over the same
   worktree. Agent auth survives only because `~/.claude-container` is bind-mounted from the host.
3. **Git worktrees force a host-path-identical bind mount.** A linked worktree's `.git` is a *file*
   containing an absolute host path. The script mounts the main repo's `.git` at **the same absolute
   path inside the container** (`:364-367` [code]) so both `gitdir:` and `commondir` resolve. This
   is the single hardest constraint on any future runtime abstraction — see
   [`runtime-discussion.md`](./runtime-discussion.md).
4. **Two configuration tiers, chosen implicitly.** A project with
   `.devcontainer/claude-task.json` gets a per-project image and per-project Maven cache; a project
   without one silently falls back to a global image and global cache (`:406-419` [code]). The two
   paths differ in image, cache location, firewall default, and build-tool resolution.

The script is also **not tested or linted anywhere**. CI builds container images only; `bin/claude-task`
is never syntax-checked, linted, or executed in CI. See [Testing analysis](#testing-analysis).

---

## User-facing commands

Dispatch is a single `case` on `$1` (`:1108-1133` [code]). Anything that is not a recognised
`--flag` is treated as a branch name and starts a session.

| Invocation | Handler | Effect |
|---|---|---|
| `claude-task <branch>` | `cmd_start claude` | Start/attach a session; permission mode from config, default `bypass` |
| `claude-task --plan <branch>` | `cmd_start plan` | Same, forced `--permission-mode plan` |
| `claude-task --shell <branch>` | `cmd_start shell` | zsh instead of the agent; `docker exec` if already running |
| `claude-task --sync <branch>` | `cmd_sync` | Rebase onto `origin/main`, test, strip `tasks/`, push, open/update PR |
| `claude-task --done <branch>` | `cmd_done` | Remove container and worktree; branch kept |
| `claude-task --init [--force]` | `cmd_init` | Scaffold per-project config into the current repo |
| `claude-task --update` | `cmd_update` | Replace the installed script with the latest release |
| `claude-task --help` / `-h` | `usage` | Print usage, exit 0 |
| `claude-task` (no args) | `usage` | Print usage, **exit 1** (`:1125` [code]) |
| `claude-task --anything-else` | `usage` | Error + usage, exit 1 |

Modifiers: `--rebuild` (start commands only) and `--force` (`--init` and `--done`, with **different
meanings in each**).

Dispatch observations [code]:

- There is **no `--version` flag**, despite `CLAUDE_TASK_VERSION` existing. The version is only
  observable via `--update`'s output or by reading the file.
- Positional arguments are collected with `*) branch="$1"` in a loop, so extra positionals are
  **silently discarded, last one wins**: `claude-task foo bar` operates on `bar`
  (`:381-388`, `:454-461`, `:519-525`).
- `--force` is rejected by `cmd_sync` and the start commands (`--*) die`), so its scope is
  genuinely limited to `--init` and `--done`.
- Flag order is free within a command (the parse loops accept flags before or after the branch),
  which resolves an apparent contradiction in the upstream cheatsheet [docs].

---

## Functional inventory

### Index

Status is `OPEN` for every row: no keep/change/remove/move decision has been made.

| ID | Capability | Trigger | Proposed module | Status |
|---|---|---|---|---|
| F01 | Start agent session for a branch | `<branch>` | session + container | OPEN |
| F02 | Start in plan mode | `--plan` | session | OPEN |
| F03 | Debug shell / attach second terminal | `--shell` | session + container | OPEN |
| F04 | Sync branch to merge-ready | `--sync` | pull-request (orchestrator) | OPEN |
| F05 | Tear down a task | `--done` | worktree + container | OPEN |
| F06 | Scaffold per-project config | `--init` | config (+ new `scaffold`) | OPEN |
| F07 | Self-update | `--update` | new `selfupdate` | OPEN |
| F08 | Help, usage and dispatch | `--help`, no args | `bin/agent-task` | OPEN |
| F09 | Force image rebuild | `--rebuild` | container | OPEN |
| F10 | `--force` modifier (dual meaning) | `--init`, `--done` | config / worktree | OPEN |
| F11 | Git-repo precondition check | all commands | git | OPEN |
| F12 | Main-repo-root resolution | all commands | git | OPEN |
| F13 | Name sanitisation | naming | container (or `naming`) | OPEN |
| F14 | Project-name resolution (3-tier) | naming | config | OPEN |
| F15 | Container-name derivation | naming | container | OPEN |
| F16 | Image-tag derivation | naming | container | OPEN |
| F17 | Worktree-path derivation | worktree ops | worktree | OPEN |
| F18 | Worktree existence detection | worktree ops | worktree | OPEN |
| F19 | Worktree find-or-create (3-way branch resolution) | session start | worktree + git | OPEN |
| F20 | Worktree removal | `--done` | worktree | OPEN |
| F21 | Project-config discovery | all | config | OPEN |
| F22 | Config field read | all | config | OPEN |
| F23 | Env-file `KEY=value` parsing | naming | config | OPEN |
| F24 | Passthrough-env resolution | container run | config | OPEN |
| F25 | Build-tool detection fallback | `--sync` | config | OPEN |
| F26 | Config hashing | image build | container | OPEN |
| F27 | Rebuild-need detection via image label | image build | container | OPEN |
| F28 | Per-project image build | configured projects | container | OPEN |
| F29 | Global/fallback image provisioning | unconfigured projects | container | OPEN |
| F30 | Container run-argument assembly | session/sync | container | OPEN |
| F31 | `devcontainer.env` seeding (`cp -n`) | container run | config | OPEN |
| F32 | Global agent auth-state mounting | container run | container | OPEN |
| F33 | Maven cache provisioning + mounting | container run | container | OPEN |
| F34 | Main `.git` same-path mounting | container run | container + git | OPEN |
| F35 | Fixed host-env forwarding | container run | config | OPEN |
| F36 | Firewall profile selection | container run | container | OPEN |
| F37 | Running-container detection + reuse policy | session start | container | OPEN |
| F38 | Permission-mode resolution | session start | session | OPEN |
| F39 | Agent launch-command selection | session start | session | OPEN |
| F40 | Container removal | `--done` | container | OPEN |
| F41 | Pre-sync validation | `--sync` | pull-request | OPEN |
| F42 | Fetch + rebase onto `origin/main` | `--sync` | git | OPEN |
| F43 | Test execution per build tool | `--sync` | new `build` | OPEN |
| F44 | Task-spec stripping commit | `--sync` | **ownership OPEN** | OPEN |
| F45 | Push | `--sync` | git | OPEN |
| F46 | PR create-or-report | `--sync` | pull-request | OPEN |
| F47 | Sync exit-code contract (`10`) | `--sync` | pull-request | OPEN |
| F48 | Uncommitted/unpushed safety checks | `--done` | git | OPEN |
| F49 | Interactive questionnaire | `--init` | new `scaffold` | OPEN |
| F50 | `claude-task.json` generation | `--init` | config | OPEN |
| F51 | Dockerfile rendering (SDKMAN layer) | `--init` | **ownership OPEN** (runtime) | OPEN |
| F52 | `devcontainer.json` generation | `--init` | **ownership OPEN** (runtime) | OPEN |
| F53 | `devcontainer.env.example` generation | `--init` | config | OPEN |
| F54 | `allowed-domains.conf` generation | `--init` | **ownership OPEN** (runtime) | OPEN |
| F55 | `.mcp.json` merge | `--init` | **ownership OPEN** (agent config) | OPEN |
| F56 | `.claude/settings.json` generation | `--init` | **ownership OPEN** (agent config) | OPEN |
| F57 | `CLAUDE.md` skeleton generation | `--init` | **ownership OPEN** (agent config) | OPEN |
| F58 | `tasks/` directory creation | `--init` | **ownership OPEN** (task-spec skill) | OPEN |
| F59 | `.gitignore` entry management | `--init` | config | OPEN |
| F60 | `git add` staging + summary | `--init` | git | OPEN |
| F61 | Latest release-tag resolution | `--update` | new `selfupdate` | OPEN |
| F62 | Download, install, version report | `--update` | new `selfupdate` | OPEN |
| F63 | Logging primitives | everywhere | logging | OPEN |
| F64 | Per-command argument parsing | everywhere | `bin/agent-task` | OPEN |
| F65 | Version constant (no `--version`) | — | `bin/agent-task` | OPEN |

**Existing tests: none, for all 65 entries.** This is stated once here rather than repeated in every
block. See [Testing analysis](#testing-analysis).

---

### Group A — Commands and CLI surface

#### F01 — Start agent session for a branch

- **Trigger:** `claude-task <branch>` → `cmd_start claude` (`:378-450`).
- **Purpose:** Ensure a worktree exists for the branch, ensure an image exists, then `exec docker run`
  an interactive Claude Code session in it.
- **Inputs:** branch name; `--rebuild`; cwd (must be in a git repo); `.devcontainer/claude-task.json`
  **read from the worktree, not the main repo** (`:406`); `.devcontainer/devcontainer.env` from the
  main repo root; host env (`GH_TOKEN`, `TZ`, `GIT_USER_*`, `VAADIN_PRO_KEY`, `NOTIFICATION_URL`,
  passthrough names); `$HOME`.
- **Outputs:** a foreground interactive container; progress lines on stderr. The process is *replaced*
  by `docker` (`exec`), so nothing after the run executes.
- **Side effects:** creates the worktree and its parent `-worktrees` dir; may create a branch; may
  build/pull an image; creates the Maven cache dir; **writes `.devcontainer/devcontainer.env` into the
  worktree** via `cp -n` (F31); mutates host `~/.claude-container` state through the mount.
- **Dependencies:** `git`, `docker`, `jq` (only when a config file exists), `sed`, `tr`, `awk`,
  `sha256sum` (only for configured projects), `grep`, `basename`, `dirname`, `mkdir`, `cp`.
- **Failure cases:** not a git repo; git common-dir unresolvable; `worktree add` fails (branch checked
  out elsewhere, dirty target path); missing
  `.devcontainer/claude-task.Dockerfile` when a config exists (`:255`); `docker build`/`pull` failure;
  container name already running → refuses with a hint (`:428-430`); invalid `permissionMode` (`:441`);
  Docker daemon down (unhandled — raw docker error).
- **Proposed module:** `session.sh` (orchestration) + `container.sh` (run) + `worktree.sh` + `git.sh`.
- **Testability:** **poor as one unit.** Mixes CLI parsing, git, config, image build, and `exec` in one
  function. `exec` makes it untestable in-process; there is no dry-run and no way to obtain the computed
  `docker run` argv without running it. Extracting an "assemble argv" seam is the highest-value change
  for testability.
- **Open questions:** OPEN — should config be read from the worktree or the main repo? (branch-local
  config is a deliberate feature [docs], but it means a branch can silently change its own image and
  firewall). OPEN — should `exec` be replaced by a normal invocation so post-run cleanup/telemetry is
  possible?

#### F02 — Start in plan mode

- **Trigger:** `--plan <branch>` → `cmd_start plan` (`:1113-1114`, `:443`).
- **Purpose:** Force `claude --permission-mode plan`, overriding project config.
- **Inputs/Outputs/Side effects:** identical to F01 apart from the launch command.
- **Dependencies:** as F01.
- **Failure cases:** as F01. Note the `plan` mode path **bypasses the `permissionMode` validation**
  that the `claude` path performs, so it can never hit the "invalid permissionMode" error.
- **Proposed module:** `session.sh`.
- **Testability:** pure decision logic once the launch-command selection (F39) is extracted — then a
  table test over (mode, permissionMode) → argv is trivial.
- **Open questions:** OPEN — is a mode flag per permission level the right CLI shape, or should this be
  `--permission-mode <x>` passed through generically? OPEN — the inverse (`--yolo` to force bypass when
  a project pins `plan`/`ask`) is documented as a deliberately unimplemented gap [docs].

#### F03 — Debug shell / attach second terminal

- **Trigger:** `--shell <branch>` → `cmd_start shell` (`:423-426`, `:444`).
- **Purpose:** Open zsh instead of the agent. If a container for that branch is already running, attach
  a *second* terminal via `docker exec -it … /bin/zsh` instead of starting a new container.
- **Inputs:** branch; running-container state (F37).
- **Outputs:** interactive zsh (foreground, `exec`'d).
- **Side effects:** in the attach path, **none** beyond the shell itself. In the start path, all of F01's
  side effects (including worktree creation and image build) — i.e. `--shell` on a fresh branch will
  create a branch and build an image.
- **Dependencies:** `docker`, plus all of F01's when not attaching.
- **Failure cases:** container exists but is *stopped* (not removed) → `running_container` returns false,
  so it takes the start path and `docker run --name` fails on the name conflict; zsh missing from a
  custom image.
- **Proposed module:** `session.sh` (mode) + `container.sh` (`exec` vs `run`).
- **Testability:** the run-vs-exec branch is testable with a faked `docker ps`; the `exec` itself needs
  an integration test.
- **Open questions:** OPEN — should `--shell` on a non-existent worktree create one, or refuse?

#### F04 — Sync branch to merge-ready

- **Trigger:** `--sync <branch>` → `cmd_sync` (`:517-614`).
- **Purpose:** Run the mechanical "make this branch mergeable" pipeline headlessly, inside the same
  image/mount setup as a session: fetch, rebase onto `origin/main`, run tests, strip `tasks/`, push,
  create-or-report a PR.
- **Inputs:** branch; `GH_TOKEN` (mandatory, checked first `:530-531`); clean worktree (mandatory
  `:542-545`); `buildTool` from config or detected (F25); the whole container env of F30.
- **Outputs:** container stdout/stderr streamed; exit `0` success, `10` rebase conflict, other non-zero
  failure. Remote side effects: a pushed branch and a GitHub PR.
- **Side effects:** rewrites branch history (rebase); **adds a commit** `chore: strip task spec before
  merge`; force-pushes with lease; creates a PR; leaves an in-progress rebase on conflict (persisted via
  the shared `.git` mount) for a later interactive session to resolve.
- **Dependencies:** `docker`, `git` (host + container), `gh` (container), `jq` (configured projects),
  build tool inside the image.
- **Failure cases:** `GH_TOKEN` unset; worktree missing or dirty; unknown build tool (`:571`); rebase
  conflict → 10; test failure; push rejected; `gh` unauthenticated; **base branch hardcoded to
  `origin/main`** so any project using `master`/`develop` fails or rebases onto the wrong base;
  shell injection via branch name (see [D-06](#verified-defects-and-risks)).
- **Proposed module:** `pull-request.sh` as the orchestrator, delegating to `git.sh` (F42, F45),
  a new `build.sh` (F43), and `container.sh` (F30).
- **Testability:** **worst in the script.** The entire pipeline is a 25-line bash string interpolated at
  `:577-601` and executed by `bash -lc` *inside* the container, so none of it is reachable from a host
  test; it can only be exercised end-to-end with Docker + a real remote. The host-side parts (validation,
  build-tool → test-command mapping, exit-code mapping) are unit-testable once separated from the string.
- **Open questions:** OPEN — should the base branch be configurable/detected? OPEN — must the pipeline run
  *inside* the container at all, given it needs the container only for the build toolchain? OPEN — should
  rebase-vs-merge be a policy choice? OPEN — should the pipeline be decomposed into individually
  invocable steps (`agent-task rebase`, `agent-task test`, `agent-task pr`)?

#### F05 — Tear down a task

- **Trigger:** `--done <branch>` → `cmd_done` (`:452-501`).
- **Purpose:** Remove the container (if any) and the worktree. Deliberately leaves the branch.
- **Inputs:** branch; `--force`; worktree git status and upstream state.
- **Outputs:** progress on stderr; a closing note that the branch was kept (`:500`).
- **Side effects:** `docker rm -f`; `git worktree remove --force`. **Destructive and irreversible for
  uncommitted work** when `--force` is passed.
- **Dependencies:** `git`, `docker`.
- **Failure cases:** worktree not found → dies **before** the container is touched (`:471-473`), so a
  container whose worktree was manually deleted can never be cleaned up by this command
  ([D-05](#verified-defects-and-risks)); dirty worktree; unpushed commits; `worktree remove` fails
  (submodules, permissions).
- **Proposed module:** `worktree.sh` + `container.sh`, with the safety policy in `git.sh`.
- **Testability:** the safety checks (F48) are cleanly unit-testable against real temp repos with no
  Docker. Removal needs integration tests.
- **Open questions:** OPEN — should teardown also offer branch deletion? OPEN — should container cleanup be
  decoupled from worktree existence? OPEN — should there be a `--dry-run`?

#### F06 — Scaffold per-project config

- **Trigger:** `--init [--force]` → `cmd_init` (`:939-1055`).
- **Purpose:** Interactively generate the per-project container configuration and the surrounding
  agent-config files, then stage them for the user to review and commit.
- **Inputs:** 10 answers on stdin (6 constrained choices + 3 free-form CSV + project name); existing
  files (some are never overwritten).
- **Outputs:** 9 generated files + `tasks/` dir + `.gitignore` entries; a staged index; a printed
  summary and commit hint.
- **Side effects:** writes into the repo; runs `git add`; **is not atomic** — a failure part-way leaves
  files on disk and the index partially staged ([D-01](#verified-defects-and-risks)).
- **Dependencies:** `git`, `jq`, `sed`, `tr`, `xargs`, `basename`, `read`.
- **Failure cases:** already initialised without `--force` → prints current config, exit 1 (verified);
  `git add` refusing a globally-gitignored path → **exit 1 after writing everything**
  ([D-01](#verified-defects-and-risks), verified); unknown Java vendor or build tool in rendering
  (`:661`, `:668`).
- **Proposed module:** a new `scaffold.sh` (templates + questionnaire) writing through `config.sh`.
  Several of the individual writers have **ownership questions** — see F51–F58 and
  [Functionality ownership questions](#functionality-ownership-questions).
- **Testability:** **the most testable command in the script, and the only one needing no Docker.** Verified
  fully non-interactively drivable by piping newline-separated answers; unanswered prompts fall back to
  their defaults without aborting. A golden-file test suite over generated artifacts is straightforward.
- **Open questions:** OPEN — does Agent CLI own project scaffolding at all, or does the runtime project?
  OPEN — should it be non-interactive-first (flags/config file) with the questionnaire as sugar? OPEN —
  should it commit, or keep staging-only?

#### F07 — Self-update

- **Trigger:** `--update` → `cmd_update` (`:1068-1104`).
- **Purpose:** Resolve the latest GitHub release tag and overwrite the installed script in place.
- **Inputs:** `command -v claude-task` (falls back to `~/.local/bin/claude-task`); GitHub releases API.
- **Outputs:** version transition message, or "already up to date".
- **Side effects:** **overwrites the running executable**; `mkdir -p` of its directory; `mktemp` file.
- **Dependencies:** `curl`, `jq`, `mktemp`, `readlink` (optional), `mv`, `chmod`, `grep`, `cut`.
- **Failure cases:** rate-limited/offline API → dies; download failure → dies after cleanup; downloaded
  file lacking a version string → refuses (a weak sanity check, `:1088-1092`); **no checksum or signature
  verification**; `mv` across filesystems; unwritable target (unhandled); a symlinked install is resolved
  and *replaced*, destroying the symlink.
- **Proposed module:** a new `selfupdate.sh`. Multi-file distribution changes this problem fundamentally —
  see the open question.
- **Testability:** unit-testable with a faked `curl` + temp install dir; the version-string extraction and
  the same-version short-circuit are pure. Needs a network integration test for the real API shape.
- **Open questions:** OPEN — does Agent CLI stay a single curl'd file, or become a multi-file `lib/`
  install (tarball/git clone/package manager)? This decision drives whether F07 survives in any form.
  OPEN — should updates be verified (checksum/signature)?

#### F08 — Help, usage and dispatch

- **Trigger:** `--help`, `-h`, no args, unknown `--flag`; `main` (`:1108-1133`), `usage` (`:39-63`).
- **Purpose:** Route to a command handler; print usage.
- **Inputs:** `$1`.
- **Outputs:** usage text on **stdout** (`cat` heredoc, unlike all other messaging which goes to stderr).
- **Side effects:** none.
- **Failure cases:** no args → exit 1 (arguably wrong for a bare invocation); unknown flag → exit 1;
  a branch literally named like a flag is unreachable.
- **Proposed module:** `bin/agent-task`.
- **Testability:** trivially unit-testable (argv → chosen handler + exit code), *if* the handler is
  resolved as data rather than by immediately calling it.
- **Open questions:** OPEN — subcommands (`agent-task start|shell|sync|done|init`) instead of flag-modes?
  This is the single biggest CLI-shape decision and it affects F01–F10 and F64.

#### F09 — Force image rebuild (`--rebuild`)

- **Trigger:** `--rebuild` on `<branch>`/`--plan`/`--shell` (`:384`, forwarded to `build_project_image` `:413`).
- **Purpose:** Rebuild the project image with `--pull --no-cache` even when the config hash matches, to pick
  up a changed upstream base image.
- **Inputs/Outputs:** flag; a rebuilt image.
- **Side effects:** long Docker build; discards build cache.
- **Failure cases:** silently a **no-op for unconfigured projects** — `build_project_image` is only called
  on the config path (`:413`), so `--rebuild` on a project without `claude-task.json` is accepted and
  ignored; `--sync` hardcodes `0` (`:557`) so it can never force a rebuild.
- **Proposed module:** `container.sh`.
- **Testability:** unit-testable as a flag→build-args mapping with a faked `docker`.
- **Open questions:** OPEN — should `--rebuild` also force a re-pull on the global-image path?

#### F10 — `--force` modifier (dual meaning)

- **Trigger:** `--init --force` (overwrite machine-owned files, `:953`) and `--done --force` (skip safety
  checks, `:475`).
- **Purpose:** Two unrelated escape hatches sharing one flag name.
- **Side effects:** `--init --force` regenerates config/Dockerfile/devcontainer.json/allowlist but
  **still never overwrites** `CLAUDE.md` or `.claude/settings.json` (`:870`, `:908`).
  `--done --force` permits destroying uncommitted and unpushed work.
- **Failure cases:** the overloading is a UX hazard — the same word means "overwrite my files" and
  "destroy my unpushed commits".
- **Proposed module:** parsing in `bin/agent-task`; semantics in `config.sh` / `worktree.sh`.
- **Testability:** unit-testable per command.
- **Open questions:** OPEN — split into distinct, self-describing flags?

---

### Group B — Identity and naming

#### F11 — Git-repo precondition check

`require_git_repo` (`:67-70`) — `git rev-parse --is-inside-work-tree`, else die.
Called by `cmd_start`, `cmd_done`, `cmd_sync`, `cmd_init`. **Inputs:** cwd. **Side effects:** none.
**Failure:** outside a repo → `Not inside a git repository.`
**Module:** `git.sh`. **Testability:** trivial unit test in temp dirs (no Docker).
**Open:** OPEN — should a repo-root argument (`-C`) be supported so the tool need not be run from inside?

#### F12 — Main-repo-root resolution

`resolve_main_repo_root` (`:77-87`) — uses `git rev-parse --path-format=absolute --git-common-dir`
(deliberately not `--git-dir`) so it yields the *main* repo even when invoked from a linked worktree,
then strips a trailing `.git`; a non-`.git` basename is treated as a bare-repo root.
**Anchors:** image tag, container name, worktree base path, Maven cache, `devcontainer.env` lookup.
**Dependencies:** git ≥ 2.31 (for `--path-format`). **Failure:** unresolvable common dir → die;
bare-repo layout returns a path with no `.git` subdirectory, which silently disables the `.git` mount
(F34) and breaks git inside the container — documented upstream as "best-effort" [docs].
**Module:** `git.sh`. **Testability:** unit-testable against fixture repos (normal clone, linked
worktree, bare repo, submodule) with no Docker. **Open:** OPEN — is bare-repo support in scope?

#### F13 — Name sanitisation

`sanitize` (`:91-94`) — lowercase, collapse every run of characters outside `[a-z0-9._-]` to a single
`-`, strip leading `-`/`.` and trailing `-`.
**Used by:** F14 (project name), F15 (container name).
**Failure/risk:** **lossy and collision-prone** — verified: `feature/x`, `feature-x` and `Feature/X` all
produce `feature-x`; non-ASCII is mangled (`ümlaut` → `mlaut`); an all-punctuation branch yields the empty
string, producing the container name `claude-<proj>-`. See [D-03](#verified-defects-and-risks).
**Module:** `container.sh`, or a dedicated `naming.sh` since it is shared.
**Testability:** **pure function — the single best unit-test target in the script.** A table test with
collision assertions is ~20 lines.
**Open:** OPEN — should naming be collision-free (e.g. append a short hash of the raw branch)? This is a
behaviour change, so it needs an explicit decision.

#### F14 — Project-name resolution (3-tier precedence)

`resolve_project_name` (`:203-214`), with `project_name` (`:96-101`) as the last tier. Precedence:
1. `CLAUDE_TASK_NAME` from `<main-repo-root>/.devcontainer/devcontainer.env` (local override, read from the
   **main repo** so all worktrees agree),
2. `.name` in `.devcontainer/claude-task.json` (committed, team-canonical),
3. the main-repo directory basename.
Always passed through F13.
**Side effects:** none. **Failure:** changing the name while a container runs **orphans** it — the old name
no longer resolves, so `--shell`/`--done` cannot find it; documented as having no auto-recovery [docs].
**Note:** the config is read from the `config_dir` argument, which is the *worktree* — so tier 2 can differ
per branch while tier 1 is repo-global.
**Module:** `config.sh`. **Testability:** pure given a filesystem fixture; unit-testable, no Docker.
**Open:** OPEN — should identity be derived from something stable (remote URL, repo-root hash) rather than a
mutable directory name? OPEN — is an env-file-based override still wanted?

#### F15 — Container-name derivation

`container_name_for` (`:236-239`) — `claude-<project>-<sanitize(branch)>`. `cmd_sync` reuses it with
`"${branch}-sync"` (`:548`) to get a distinct headless container.
**Failure:** inherits every F13 collision; the `-sync` suffix could itself collide with a real branch named
`<x>-sync`.
**Module:** `container.sh`. **Testability:** pure. **Open:** OPEN — rename to an agent-neutral prefix
(`agent-`)? That is a breaking change for anyone with running containers.

#### F16 — Image-tag derivation

`image_tag_for_project` (`:232-234`) — `claude-task-<project>:latest`. Always `:latest`, so image identity is
carried entirely by the config-hash label (F27) rather than the tag.
**Module:** `container.sh`. **Testability:** pure.
**Open:** OPEN — tag by config hash instead of `:latest` so multiple configs can coexist and rollback is possible?

#### F17 — Worktree-path derivation

`worktree_path` (`:103-108`) — `<parent-of-repo>/<repo-basename>-worktrees/<branch>`, using the **raw,
unsanitised** branch, so `feature/x` nests as `…-worktrees/feature/x`.
**Rationale [docs]:** a sibling directory keeps IDE indexing, greps and git's own bookkeeping simple.
**Failure:** branches `feature` and `feature/x` cannot coexist (file-vs-directory conflict); a repo path
containing spaces breaks F18; writes outside the repo, so it needs write permission on the parent dir.
**Module:** `worktree.sh`. **Testability:** pure string logic — unit-testable, plus fixture tests for the
conflict cases. **Open:** OPEN — is a sibling directory the right layout, or should worktrees live in a
central per-user location (`~/.agent-cli/worktrees/<project>/<branch>`)?

---

### Group C — Worktree lifecycle

#### F18 — Worktree existence detection

`worktree_exists` (`:110-114`) — parses `git worktree list --porcelain` with
`awk '$1=="worktree" && $2==p'`.
**Failure:** **broken for any path containing a space** — awk splits on whitespace so `$2` is only the first
segment. Verified: a worktree at `…/my repo-worktrees/spacey` is reported as not existing, which makes
`--done`/`--sync` die with "No worktree found" and makes `find_or_create_worktree` attempt to re-add an
existing worktree. See [D-02](#verified-defects-and-risks).
**Module:** `worktree.sh`. **Testability:** **unit-testable with a fixture repo and no Docker; the
space-in-path case is a regression test that fails today.** **Open:** OPEN — accept paths with spaces as
supported, or reject them explicitly with a clear error?

#### F19 — Worktree find-or-create (3-way branch resolution)

`find_or_create_worktree` (`:116-140`). If the worktree exists, return its path. Otherwise `mkdir -p` the
parent and pick one of three creation strategies (`:128-137`):
1. local branch exists → `git worktree add <path> <branch>`
2. `origin/<branch>` exists → `git worktree add --track -b <branch> <path> origin/<branch>`
3. neither → `git worktree add -b <branch> <path>` (**new branch off current HEAD**)
**Side effects:** creates directories and possibly a branch; checks out a full working tree.
**Failure:** branch already checked out in another worktree; stale worktree metadata; no `origin` remote;
dirty/non-empty target path; no permission on the parent dir; case-insensitive-filesystem collisions.
**Note:** strategy 3 depends on the **caller's current HEAD**, which makes the command's result depend on
ambient state (which repo/branch you happened to be standing in).
**Module:** `worktree.sh` (path/existence) + `git.sh` (branch resolution). **Mixed responsibility** — see
[Proposed module classification](#proposed-module-classification).
**Testability:** all three strategies are integration-testable against temp repos with no Docker; the
strategy *choice* becomes a pure unit test if branch existence is injected.
**Open:** OPEN — should the base for a new branch be explicit (`--from origin/main`) rather than ambient HEAD?
OPEN — should `--track` behaviour be configurable?

#### F20 — Worktree removal

`git -C <main> worktree remove --force <path>` (`:499`). Always `--force` at the git level; the *user-facing*
safety comes from F48, not from git.
**Side effects:** deletes the working tree irreversibly. **Failure:** locked worktree, submodules, permissions.
**Module:** `worktree.sh`. **Testability:** integration, temp repos, no Docker.
**Open:** OPEN — also `git worktree prune`? OPEN — offer branch deletion here (currently explicitly out of scope)?

---

### Group D — Configuration

#### F21 — Project-config discovery

`config_path` (`:144-146`) → `<dir>/.devcontainer/claude-task.json`; `has_project_config` (`:148-150`).
This single predicate selects between the two entire operating modes (per-project vs global image/cache).
**Module:** `config.sh`. **Testability:** pure + fixture. **Open:** OPEN — should the config live under
`.devcontainer/` at all, given Agent CLI may not be devcontainer-based? OPEN — support a
user-level/global config layer?

#### F22 — Config field read

`cfg_get` (`:169-172`) — `jq -r "<filter> // \"<default>\"" <cfg>`. Only five reads exist in the whole
script: `.name`, `.firewall`, `.permissionMode`, `.buildTool` (and `has("passthroughEnv")` in F24). So
`version`, `variant`, `java.*`, `mcpServers`, `plugins` are **write-only at `--init` time and never read
again at runtime** — they influence behaviour only through the rendered Dockerfile and the materialised
agent-config files.
**Failure:** malformed JSON → jq error; `//` also swallows `false` and `null`; **the filter and default are
string-interpolated into the jq program** (`:171`), which is an injection surface if either ever becomes
caller-controlled.
**Module:** `config.sh`. **Testability:** pure given fixture JSON — unit-testable, no Docker.
**Open:** OPEN — validate the config against a schema and reject unknown keys, or stay permissive?
OPEN — what is `version: 1` for, given nothing reads it? Migration policy is undefined.

#### F23 — Env-file `KEY=value` parsing

`env_file_value` (`:179-193`) — anchored `grep`, last match wins, trims whitespace, strips one layer of
matching single or double quotes, tolerates a missing file, never fails.
Used only for `CLAUDE_TASK_NAME`.
**Failure:** no handling of `export KEY=`, escapes, or multiline values; a commented `#KEY=` correctly fails
to match (deliberate).
**Module:** `config.sh`. **Testability:** **pure, fixture-driven, excellent unit-test target** with a rich edge
case set (comments, quotes, whitespace, duplicates, CRLF, missing file).
**Open:** OPEN — keep a bespoke parser or adopt a documented subset/format?

#### F24 — Passthrough-env resolution

`resolve_passthrough_env` (`:159-167`). Precedence: `passthroughEnv` present in config → authoritative
(explicit `[]` forwards nothing); absent or no config → `DEFAULT_PASSTHROUGH_ENV`
(`OPENAI_API_KEY ANTHROPIC_API_KEY`, `:33`). Only *names* come from the committed config; values are read
from the host env at run time and never written to disk.
**Consumer:** F30 forwards each name only when set and non-empty, with a defensive identifier regex (`:353`).
**Module:** `config.sh`. **Testability:** pure given fixture JSON + a controlled environment; a strong unit-test
target including the `[]`-vs-absent distinction.
**Open:** OPEN — should there be a deny-list/redaction policy, or a warning when a named var is unset?

#### F25 — Build-tool detection fallback

`detect_build_tool` (`:219-228`) — `mvnw`/`pom.xml` → `maven`; `gradlew`/`build.gradle{,.kts}` → `gradle`;
else `none`. Used **only** by `cmd_sync` for unconfigured projects (`:560`); the configured path always
trusts `buildTool` (default `maven`).
**Failure:** polyglot repos; Maven checked first so a repo with both is called Maven; no support for other
ecosystems (npm, cargo, go, make…).
**Module:** `config.sh` (resolution) or a new `build.sh` (knowledge of build systems).
**Testability:** **pure filesystem probe — ideal unit test** over fixture directory layouts, no Docker.
**Open:** OPEN — is a hardcoded Maven/Gradle/none enum acceptable for a general tool, or should the test
command itself be configurable (`testCommand: "..."`)?

---

### Group E — Image management

#### F26 — Config hashing

`config_hash` (`:241-243`) — `sha256sum <file> | cut -c1-12`. Hashes **only the rendered Dockerfile**, not
`claude-task.json`.
**Failure:** `sha256sum` is a GNU coreutils name; present on this host at `/sbin/sha256sum` but historically
absent on macOS, where `shasum -a 256` is the portable form — **portability to be verified across target
macOS versions** ([D-04](#verified-defects-and-risks)).
**Consequence [code]:** hand-editing `claude-task.json` (e.g. `java.version`) does **not** change the
Dockerfile and therefore does **not** trigger a rebuild; only re-running `--init --force` does.
**Module:** `container.sh`. **Testability:** pure given a temp file. **Open:** OPEN — hash the effective
config rather than the rendered Dockerfile?

#### F27 — Rebuild-need detection

`needs_rebuild` (`:245-250`) — compares `config_hash` against the image label
`com.claude-task.config-hash` read via `docker image inspect`; a missing image (non-zero inspect) returns
"needs rebuild".
**Deliberately excluded from the hash [docs]:** `firewall` and `passthroughEnv`, as runtime concerns.
**Module:** `container.sh`. **Testability:** unit-testable with a faked `docker` on PATH; the label contract
itself needs one integration test.
**Open:** OPEN — is a label the right cache key, or should the tag carry the hash (F16)?

#### F28 — Per-project image build

`build_project_image` (`:252-269`) — requires `.devcontainer/claude-task.Dockerfile`, builds with
`-f`, `-t`, the hash label, and build context `<worktree>/.devcontainer`; `--pull --no-cache` when forced.
**Failure:** missing Dockerfile → die with a `--init` hint; build failure (notably the SDKMAN candidate
resolution, F51); build context limited to `.devcontainer` so the Dockerfile cannot `COPY` project files.
**Module:** `container.sh`. **Testability:** argv assembly is unit-testable with a faked `docker`; real builds
are slow integration tests.
**Open:** OPEN — is the build Agent CLI's job or the runtime project's? (see ownership questions)

#### F29 — Global/fallback image provisioning

`ensure_global_image` (`:275-292`) — if `<main-repo>/.devcontainer/Dockerfile` exists, build
`claude-container:latest` from it with `--target base` and `JAVA_VERSION`/`JAVA_VENDOR` from the **host env**;
otherwise `docker pull ghcr.io/sebastiankuehnau/claude-container:latest`. Echoes the resolved tag.
**Failure:** `--target base` is hardcoded, so the variant choice is ignored on this path; the local-build branch
triggers for *any* repo that happens to have `.devcontainer/Dockerfile`, not only claude-container itself;
network/registry failure; no digest pinning (`:latest` is mutable).
**Module:** `container.sh`. **Testability:** branch selection is unit-testable with fixtures + faked `docker`.
**Open:** OPEN — should Agent CLI ship/pull a default image at all, or require an explicit runtime config?
OPEN — pin by digest?

---

### Group F — Container run

#### F30 — Container run-argument assembly

`build_run_args` (`:298-372`) — the heart of the container layer. Populates a `RUN_ARGS` array **in the
caller's scope** via dynamic scoping (no return value). Assembles: `run --rm`, `-it` only when interactive,
`--name`, `--cap-add=NET_ADMIN --cap-add=NET_RAW` (**always**, even for `firewall=open`), four bind mounts,
four fixed `-e` vars (`NODE_OPTIONS`, `CLAUDE_CONFIG_DIR`, `DEVCONTAINER=true`), `-w /workspace`, an optional
`--env-file`, the TZ fallback chain, five conditional host-env forwards (F35), the passthrough set (F24), the
`.git` mount (F34), and `SKIP_FIREWALL` (F36).
**Inputs:** 7 positional parameters. **Outputs:** none — a side-effect on a caller variable.
**Side effects:** F31 (`cp -n`).
**Failure:** a caller that forgets `local -a RUN_ARGS` silently pollutes globals or appends to stale contents;
`-e DEVCONTAINER=true` is a claim the tool is a devcontainer when it is not; `-it` without a TTY aborts (hence
the `interactive` flag).
**Module:** `container.sh`. **Mixed responsibility** — also does config resolution (F24, F31) and git
knowledge (F34).
**Testability:** **the single highest-value extraction in the whole script.** As a pure
`(context) → argv[]` function it is exhaustively unit-testable — mounts, env precedence, TTY, firewall — with
zero Docker. Today it is untestable because it writes to a caller variable and performs filesystem side effects.
**Open:** OPEN — return argv on stdout (or a structured plan) instead of mutating a caller variable?
OPEN — should a `--dry-run`/`--print-argv` mode be part of the CLI contract?

#### F31 — `devcontainer.env` seeding (`cp -n`)

`:306-308` — copies `<worktree>/.devcontainer/devcontainer.env.example` to `devcontainer.env` if the latter is
missing, so a fresh worktree (which carries the tracked example but not the ignored real file) can be used with
`--env-file`. Never overwrites.
**Side effect:** **writes into the user's worktree on every session start and every sync.**
**Failure:** if the project never ran `--init`, `.devcontainer/devcontainer.env` is not in `.gitignore`, so this
creates an untracked file that `git status --porcelain` reports — which makes the F48 and F41 clean-tree checks
refuse (`--done` and `--sync` both fail with "uncommitted changes"). Narrow but real: it needs a tracked
`devcontainer.env.example` plus no matching ignore rule.
**Module:** `config.sh`. **Testability:** unit-testable with fixtures; the failure interaction above is a
valuable regression test.
**Open:** OPEN — should the tool write into the user's worktree at all, or resolve env in memory?

#### F32 — Global agent auth-state mounting

`:319-320` — `${HOME}/.claude-container/claude` → `/home/node/.claude` and
`${HOME}/.claude-container/claude.json` → `/home/node/.claude.json`; `CLAUDE_CONFIG_DIR` is set to match.
Account-scoped by design so login survives across worktrees, projects and rebuilds.
**Failure:** **the script never creates either path** — verified by inspection; only the Maven cache gets
`mkdir -p`. Docker then auto-creates a *missing* `claude.json` as a **directory**, which is the exact trap the
upstream `devcontainer.json` `initializeCommand` exists to avoid and which the README warns about
("claude.json (file, not directory!)"). On the documented script-only install path nothing creates them
([D-07](#verified-defects-and-risks)).
**Module:** `container.sh` (mount) + a bootstrap step that is currently missing.
**Testability:** unit-testable (assert the mount args); the bootstrap gap is an integration test.
**Open:** OPEN — should Agent CLI own host-state bootstrap (a `doctor`/`bootstrap` step)? OPEN — is
`~/.claude-container` the right location for an agent-neutral tool, and should the path be
per-agent?

#### F33 — Maven cache provisioning and mounting

Configured projects: `<main-repo>/.devcontainer/m2-cache`; unconfigured: `${HOME}/.claude-m2-cache`
(`:28`, `:411`, `:417`, `:555`, `:562`). `mkdir -p` then mounted at `/home/node/.m2/repository` (`:321`).
Mounted **unconditionally**, even for `buildTool: gradle` or `none`.
**Failure:** **no Gradle cache is ever mounted** — a documented known limitation [docs]; per-project cache lives
inside `.devcontainer/`, which is why `--init` adds a `.gitignore` entry for it.
**Module:** `container.sh`. **Testability:** unit-testable path selection.
**Open:** OPEN — generalise to a declarative cache list (`caches: [{host, container}]`) so Gradle, npm, pip
work uniformly? OPEN — is a Java/Maven-specific default appropriate for a general tool? (see ownership)

#### F34 — Main `.git` same-path mounting

`:364-367` — mounts `<main-repo>/.git` at the **identical absolute host path** inside the container, guarded by
`[[ -d "$main_git_dir" ]]`. Required because a linked worktree's `.git` is a file containing an absolute
`gitdir:` path whose metadir's `commondir` points back to the main `.git` — neither lives under the worktree.
**Failure:** the guard is a directory test, so the **bare-repo layout gets no mount at all** and git inside the
container fails; leaks host filesystem layout into the container; **cannot work on any runtime that cannot bind
arbitrary host paths at identical absolute paths** (remote/VM/rootless-with-path-remapping).
**Module:** `container.sh` + `git.sh` (it encodes git internals).
**Testability:** the argv is unit-testable; correctness needs an integration test that runs `git status` inside
a container over a linked worktree.
**Open:** **the pivotal runtime question** — see [`runtime-discussion.md`](./runtime-discussion.md). Alternatives
(copy instead of mount, `--git-dir` rewriting, non-worktree isolation) all change the model.

#### F35 — Fixed host-env forwarding

`:336-345` — `TZ` (host → env-file → built-in `Europe/Helsinki`), then `GH_TOKEN`, `GIT_USER_NAME`,
`GIT_USER_EMAIL`, `VAADIN_PRO_KEY`, `NOTIFICATION_URL`, each forwarded only when set and non-empty so an unset
host var never blanks an env-file value.
**Failure/observation:** this list is **hardcoded and domain-specific** — `VAADIN_PRO_KEY` and
`NOTIFICATION_URL` are Vaadin/notification concerns baked into a general orchestrator, while the generic
mechanism for exactly this (F24 `passthroughEnv`) already exists. Also, the TZ default here
(`Europe/Helsinki`) disagrees with `devcontainer.json` and `docker-compose.yml`, which default to
`Europe/Berlin`.
**Module:** `config.sh`. **Testability:** pure precedence logic — a strong table-driven unit test.
**Open:** OPEN — collapse the fixed list into `passthroughEnv` defaults? OPEN — do `VAADIN_PRO_KEY` and
`NOTIFICATION_URL` belong to Agent CLI or the runtime project? (see ownership)

#### F36 — Firewall profile selection

`firewall` from config, default `allowlist` (`:408`, `:552`); unconfigured projects hardcode `allowlist`
(`:415`, `:559`). Only effect: `firewall=open` adds `-e SKIP_FIREWALL=1` (`:369-371`). All actual enforcement
lives in the image's `entrypoint.sh` → `init-firewall.sh`, reading
`/workspace/.devcontainer/allowed-domains.conf`.
**Failure:** `NET_ADMIN`/`NET_RAW` are granted even when the firewall is off; the allowlist file is
resolved *inside* the container from the mounted worktree, so the host tool has no visibility into it; on
firewall init failure the entrypoint warns and **continues without a firewall**.
**Module:** `container.sh`, but the capability is really a runtime property.
**Testability:** trivial unit test for the flag; real enforcement is an integration test (attempt a blocked
domain).
**Open:** OPEN — is firewalling Agent CLI's concern, or purely the runtime's? OPEN — should `open` also drop
the network capabilities?

#### F37 — Running-container detection and reuse policy

`running_container` (`:374-376`) — `docker ps --format '{{.Names}}' | grep -qx`. Policy: `--shell` + running →
`docker exec` (`:423-426`); any other mode + running → **die** with a hint (`:428-430`).
**Failure:** only *running* containers are seen — a stopped-but-present container (possible if `--rm` cleanup
failed) is invisible here but blocks `docker run --name`, producing a raw Docker name-conflict error; there is
no detached/background mode and no `docker start`.
**Module:** `container.sh`. **Testability:** unit-testable with a faked `docker`; needs the stopped-container
case as a regression test.
**Open:** OPEN — should sessions be resumable/detachable (`docker start`, `tmux`, a persistent container)
rather than always `--rm`? This is a core session-model decision.

---

### Group G — Agent launch and container teardown

#### F38 — Permission-mode resolution

`:397-409`, `:435-446`. Default `bypass`; config `permissionMode` overrides it; an explicit `--plan` wins over
both. Validation is enum-checked (`bypass|plan|ask`) **only on the `claude` mode path** (`:441`).
**Rationale [docs]:** the container is sandboxed, so prompts are friction. The image's entrypoint additionally
deletes any stale `permissions.defaultMode` from the persistent `~/.claude` mount so the CLI flag is
authoritative.
**Module:** `session.sh`. **Testability:** **pure decision table (mode, config) → argv — ideal unit test.**
**Open:** OPEN — is bypass-by-default the right default for Agent CLI? OPEN — add the documented-but-unbuilt
per-invocation override?

#### F39 — Agent launch-command selection

`:435-446` — `claude --dangerously-skip-permissions` / `claude --permission-mode plan` / `claude` / `/bin/zsh`.
**Failure:** **the agent is hardcoded to `claude`.** `--init` offers `variant: opencode` and renders an
OpenCode base image, yet no start path can launch OpenCode — reachable only via `--shell`. Upstream states
plainly that "`claude-task` never launches OpenCode" [docs]. For a project named *Agent* CLI this is the most
significant functional gap.
**Module:** `session.sh`. **Testability:** pure argv mapping.
**Open:** OPEN — should the agent be pluggable (`agent: claude|opencode|…` with a per-agent launch/permission
mapping)? OPEN — how do agent-specific concepts (permission modes) generalise?

#### F40 — Container removal

`:493-496` — if `docker ps -a` lists the name, `docker rm -f`. Note this checks **all** containers (unlike
F37's running-only check).
**Failure:** unreachable when the worktree is already gone (F05/[D-05](#verified-defects-and-risks)); no
volume or image cleanup; no orphan sweep for renamed projects.
**Module:** `container.sh`. **Testability:** unit-testable with a faked `docker`.
**Open:** OPEN — add an orphan/prune command? OPEN — should images and caches ever be cleaned up?

---

### Group H — Sync pipeline

All of F42–F46 live inside **one interpolated bash string** executed by `bash -lc` in the container
(`:577-601`). They have no independent existence in the current code; the IDs are assigned so they can be
discussed and re-homed individually.

#### F41 — Pre-sync validation

`GH_TOKEN` must be non-empty (`:530-531`); repo required; worktree must exist (`:539-540`); worktree must be
clean (`:542-545`). Fails fast on the host before any container starts.
**Module:** `pull-request.sh`. **Testability:** unit/integration with temp repos, no Docker.
**Open:** OPEN — should `gh auth status` be accepted as an alternative to `GH_TOKEN`?

#### F42 — Fetch and rebase onto `origin/main`

`git fetch origin --quiet` then `git rebase origin/main` (`:579-583`), **base hardcoded**.
**Failure:** any project not using `main`; conflicts → exit 10 (F47) leaving an in-progress rebase on disk
(intentional, so an interactive session can resolve it).
**Module:** `git.sh`. **Testability:** integration against temp repos with a local "remote" — no Docker needed
if lifted out of the container.
**Open:** OPEN — configurable/auto-detected base branch? OPEN — rebase vs merge as policy?

#### F43 — Test execution per build tool

`:567-572` — maven: `./mvnw -q -ntp clean verify` (with an `-x` wrapper guard, falling back to `mvn`);
gradle: `./gradlew -q clean check` (falling back to `gradle`); none: echo and skip; anything else → die.
**Failure:** `clean verify` is a full build (slow); no way to override the command; no per-project test
selection; the exec-bit repair for wrappers lives in the image entrypoint, not here.
**Module:** a new `build.sh` (knowledge of build systems) invoked by `pull-request.sh`.
**Testability:** the tool→command mapping is a pure unit test; execution is an integration test.
**Open:** OPEN — replace the enum with a configurable `testCommand`? OPEN — is running tests part of "sync" at
all, or a separate `agent-task test`?

#### F44 — Task-spec stripping commit

`:586-590` — if `tasks/` is tracked, `git rm -r --quiet tasks/` + commit
`chore: strip task spec before merge`. Idempotent (no-op once stripped).
**Rationale [docs]:** the spec is committed to the feature branch so it lives in branch history and can be
reviewed, but must never reach `main`.
**Failure:** hardcoded directory name and commit message; **silently rewrites the user's branch**; couples a
generic sync pipeline to a specific task-spec workflow convention.
**Module:** **ownership OPEN** — this is arguably the `task-spec` skill's convention, not Agent CLI's. See
[Functionality ownership questions](#functionality-ownership-questions).
**Testability:** integration with temp repos, no Docker.
**Open:** OPEN — does Agent CLI know about `tasks/` at all? OPEN — if kept, should the path and message be
configurable, and should it be opt-in?

#### F45 — Push

`:591-595` — `git push --force-with-lease` when an upstream exists, else `git push -u origin HEAD`.
**Failure:** force-push (lease-protected but still history-rewriting); protected branches; no dry-run.
**Module:** `git.sh`. **Testability:** integration against a local bare "remote", no Docker.
**Open:** OPEN — should force-push require explicit opt-in?

#### F46 — PR create-or-report

`:596-600` — `gh pr view <branch>` to detect; otherwise `gh pr create --fill`.
**Failure:** `gh` unauthenticated; `--fill` derives title/body from commits with no template control; no
draft/reviewer/label support; GitHub-only.
**Module:** `pull-request.sh`. **Testability:** unit-testable with a faked `gh`; integration needs a real repo.
**Open:** OPEN — support other forges (GitLab, Bitbucket) behind the same module boundary? OPEN — PR template,
draft, reviewers?

#### F47 — Sync exit-code contract

Container exits `10` on rebase conflict (`:582`); the host maps `10` → a specific "resolve interactively" die,
any other non-zero → generic failure (`:604-611`).
**Failure:** `10` is a magic number shared across the host/container boundary with no shared constant; other
failure kinds are not distinguished.
**Module:** `pull-request.sh`. **Testability:** pure mapping — unit test with a faked docker exit status.
**Open:** OPEN — define a documented exit-code contract for the whole CLI?

---

### Group I — `--done` safety

#### F48 — Uncommitted/unpushed safety checks

`:475-491`. Dirty check: `git status --porcelain` non-empty → die with the path. Upstream check: if
`@{u}` resolves, `git log <upstream>.. --oneline` non-empty → die; if there is **no** upstream, the push check
is skipped with an informational note (commits may exist only locally). Both bypassed by `--force`.
**Failure:** untracked files count as dirty (interacts with F31); "no upstream" is the weakest case — a branch
with local-only commits and no upstream is removable without warning beyond a note.
**Module:** `git.sh` (predicates) with the policy in `worktree.sh`/CLI.
**Testability:** **excellent** — fully unit/integration testable against temp repos, no Docker. The matrix
(clean/dirty × upstream/none × pushed/unpushed × force) is a natural table test.
**Open:** OPEN — should the no-upstream case be a hard refusal? OPEN — should stashing be offered instead of
refusing?

---

### Group J — Scaffolding (`--init` internals)

Templates are embedded heredocs by design (`:617-621`) because the script is distributed standalone.

#### F49 — Interactive questionnaire

`ask_choice` (`:627-636`) + direct `read -rp` calls in `cmd_init`. Ten inputs in order: project name, Java
version (`17,21,25`), Java vendor (`temurin,corretto,zulu`), build tool (`maven,gradle,none`), variant
(`base,dind,opencode`), firewall (`open,allowlist`), permission mode (`bypass,plan,ask`), MCP servers CSV,
plugins CSV, passthrough-env CSV. Unrecognised constrained answers fall back to the default with a notice.
**Verified:** fully drivable non-interactively by piping newline-separated answers; `read` at EOF yields the
default without aborting, so a short answer list is tolerated. Prompts are suppressed when stdin is not a TTY.
**Failure:** substring-based validation (`,$allowed,` vs `*,$var,*`); no way to pass answers as flags; the
questionnaire order is the implicit contract for piped input, so reordering silently breaks scripted callers.
**Module:** a new `scaffold.sh`. **Testability:** **the best integration-test target in the script — no Docker
required.** Pipe answers, assert generated files byte-for-byte (golden files).
**Open:** OPEN — flags/config-file-first with the questionnaire as sugar? OPEN — does Agent CLI own this at all?

#### F50 — `claude-task.json` generation

`:1005-1013` — a single `jq -n` producing `{version, name, variant, java{version,vendor}, buildTool,
firewall, permissionMode, mcpServers, plugins, passthroughEnv}`. CSV answers are split via
`tr ',' '\n' | sed trim | jq -R . | jq -s .`.
**Verified** output for piped answers `my-app/21/zulu/gradle/base/allowlist/plan/github,context7/vaadin-skills@vaadin-marketplace/FOO_KEY,BAR_KEY`
matched exactly, including `"version": 1`.
**Failure:** an unused `project_name_val` is computed at `:1002-1003` and passed to F57 while `name_val` goes
into the JSON — two different project names in one command; no schema validation on later reads.
**Module:** `config.sh` (writer). **Testability:** golden-file unit test, no Docker.
**Open:** OPEN — file name, location, and format for Agent CLI's own config; migration policy for `version`.

#### F51 — Dockerfile rendering (SDKMAN layer)

`render_dockerfile` (`:647-708`) + `sed_escape_replacement` (`:623-625`). Emits
`FROM <GHCR image><suffix>:latest` then installs zip/unzip, SDKMAN, a Java candidate resolved **at build time**
by grepping `sdk list java`, the build tool, a `chown`, and `JAVA_HOME`/`PATH`.
**Verified** rendering for Java 21 + Zulu + Gradle: `FROM ghcr.io/sebastiankuehnau/claude-container:latest`,
candidate regex `21\.[0-9.]+-zulu`, `sdk install gradle`.
**Failure:** the candidate regex **requires a dot-patch segment**, so a candidate id without one (e.g.
`25-tem`) would fail the build with "No SDKMAN candidate found"; upstream flags the whole mechanism as
never verified against real SDKMAN output and references a "host verification checklist" that **does not
exist in the repo** [docs]; vendor→tag and build-tool→command maps are hardcoded; `:latest` base is unpinned.
**Module:** **ownership OPEN** — generating a container definition is arguably the runtime project's job.
**Testability:** rendering is a pure golden-file unit test (no Docker); whether the rendered image *builds* is
a slow integration test that is currently the highest-risk untested path.
**Open:** OPEN — does Agent CLI generate container definitions, or consume ones the runtime project owns?
OPEN — is SDKMAN the right toolchain mechanism, or should the base image carry the JDK matrix?

#### F52 — `devcontainer.json` generation

`write_devcontainer_json` (`:713-740`). Explicitly **IDE-facing only** — `claude-task` never runs
`devcontainer up`; it drives `docker build`/`docker run` directly (`:710-712` [code], confirmed [docs]).
Duplicates the mount/env set of F30 in a second, hand-maintained place.
**Failure:** two sources of truth that can drift (they already differ on `TZ` and on the `.git` mount, which
the generated devcontainer.json omits — so IDE-attached sessions in a worktree have the F34 problem).
**Module:** **ownership OPEN** (runtime project).
**Testability:** golden-file unit test.
**Open:** OPEN — keep IDE attach as a supported path? If yes, should the runtime config be generated from one
shared definition rather than duplicated?

#### F53 — `devcontainer.env.example` generation

`write_devcontainer_env_example` (`:744-761`) — commented template for `GH_TOKEN`, git identity, API keys, and
`CLAUDE_TASK_NAME`. Staged; then `cp -n`'d to the real `devcontainer.env` (`:1019-1020`).
**Module:** `config.sh`. **Testability:** golden file.
**Open:** OPEN — is a committed example + ignored real file the right pattern for Agent CLI?

#### F54 — `allowed-domains.conf` generation

`write_allowed_domains` (`:767-817`) — only when `firewall=allowlist` (`:1021-1023`). Emits a curated starter
list (Anthropic, npm, GitHub, Maven Central, SDKMAN), conditionally appends Gradle domains, then unconditionally
appends Vaadin and javadocs.dev domains.
**Failure:** Maven domains are emitted even for `buildTool: none`/`gradle`; Vaadin/javadoc domains are
unconditional — a **domain-specific default in a general tool**; the file is consumed only inside the container.
**Module:** **ownership OPEN** (runtime project).
**Testability:** golden file, with a per-build-tool matrix.
**Open:** OPEN — does Agent CLI ship a network policy? OPEN — should the Vaadin entries be a profile/preset
rather than a default?

#### F55 — `.mcp.json` merge

`mcp_server_json` (`:821-842`) + `write_mcp_json` (`:846-863`). Curated definitions for `github`, `context7`,
`filesystem` only; merges into an existing `.mcp.json` via `jq` without clobbering hand-added servers; unknown
names are skipped with a notice.
**Failure:** the GitHub entry writes a literal `<YOUR_TOKEN>` placeholder into a **committed** file; `names` is
not declared `local` (`:851`), leaking a global; the curated list is closed.
**Module:** **ownership OPEN** — agent configuration, not orchestration.
**Testability:** unit-testable merge semantics (existing file preserved, unknown skipped) — no Docker.
**Open:** OPEN — should Agent CLI write agent config files at all?

#### F56 — `.claude/settings.json` generation

`write_claude_settings` (`:867-902`) — **only if absent**, even under `--force`. Writes `permissions.deny`
(`rm -rf`, `curl|sh`, `wget|sh`), `enabledPlugins` from the CSV, and `extraKnownMarketplaces` with a
special case for `vaadin-marketplace`.
**Failure:** the special-cased marketplace is hardcoded; `names` again not `local` (`:877`); this is
Claude-specific config emitted by a tool that aspires to be agent-neutral.
**Module:** **ownership OPEN** (agent config).
**Testability:** golden file + "never overwrites" assertion.
**Open:** OPEN — ownership; OPEN — per-agent config abstraction?

#### F57 — `CLAUDE.md` skeleton generation

`write_claude_md_skeleton` (`:905-923`) — only if absent. Receives `project_name_val` (the directory basename),
**not** the answered `name_val` (see F50).
**Module:** **ownership OPEN** (agent config / task-spec skill).
**Testability:** golden file.
**Open:** OPEN — ownership; OPEN — is generating agent memory files in scope?

#### F58 — `tasks/` directory creation

`mkdir -p "$project_dir/tasks"` (`:1000`), deliberately with no `.gitkeep` (`:1027-1029` [code]), and
deliberately **not** gitignored so specs can be committed to a feature branch.
**Verified:** the directory is created and left empty.
**Failure:** the directory is the only trace of the task-spec workflow that Agent CLI creates; nothing in the
script ever writes a spec. The `task-spec` skill that upstream docs instruct users to run
("Run it here") **does not exist in the repository** and its origin is undocumented [docs].
**Module:** **ownership OPEN** — almost certainly the `task-spec` skill project.
**Testability:** trivial.
**Open:** OPEN — does Agent CLI know about `tasks/` at all (see also F44)?

#### F59 — `.gitignore` entry management

`ensure_gitignore_entries` (`:931-937`) — `touch` then append `.devcontainer/m2-cache/` and
`.devcontainer/devcontainer.env` if not already present (exact-line match).
**Failure:** no trailing-newline handling before appending; entries are tied to the current cache/env layout.
**Module:** `config.sh` or `git.sh`. **Testability:** unit test with fixtures (missing file, already present,
no trailing newline).
**Open:** OPEN — should the tool edit `.gitignore` at all?

#### F60 — `git add` staging and summary

`:1032-1055` — builds a fixed list of 8 paths (+ the allowlist when applicable), runs
`( cd "$project_dir" && git add "${to_add[@]}" )`, then prints the staged list and a commit hint. Deliberately
does not commit.
**Failure:** **verified defect** — `git add` without `-f` fails when any path is ignored, e.g. by a *global*
`core.excludesFile` containing `.claude`. With `set -e` the command aborts at that point: all files are already
written, 8 of 9 paths are staged, the summary and commit hint never print, exit 1. See
[D-01](#verified-defects-and-risks).
**Also:** `cmd_init` anchors on `git rev-parse --show-toplevel` (`:950`), **not** `resolve_main_repo_root` — so
running `--init` from inside a worktree scaffolds into the *worktree*, inconsistent with every other command.
**Module:** `git.sh`. **Testability:** integration with temp repos + a global excludes fixture; the failure above
is a ready-made regression test.
**Open:** OPEN — use `git add -f`, warn, or skip ignored paths? OPEN — should scaffolding stage at all?
OPEN — should `--init` anchor on the main repo root?

---

### Group K — Distribution

#### F61 — Latest release-tag resolution

`resolve_latest_tag` (`:1063-1066`) — `curl` the GitHub releases API, `jq -r '.tag_name // empty'`.
**Failure:** unauthenticated rate limits; offline; empty tag → die; no pre-release/pinning support.
**Module:** new `selfupdate.sh`. **Testability:** unit test with a faked `curl`.
**Open:** OPEN — see F07.

#### F62 — Download, install, version report

`cmd_update` (`:1068-1104`) — see F07 for the full analysis.
**Open:** OPEN — see F07.

---

### Group L — Cross-cutting

#### F63 — Logging primitives

`info` / `err` / `die` (`:35-37`) — all `printf` to **stderr**; `die` exits 1. `usage` and `cmd_init` instead
use `echo` to **stdout**.
**Failure:** no levels, no timestamps, no `--verbose`/`--quiet`, no structured output, single hardcoded exit
code for every failure, and an inconsistent stream policy. Because informational output goes to stderr, it is
interleaved with real errors and with Docker's own output.
**Module:** `logging.sh`. **Testability:** trivially unit-testable once `die`'s exit is injectable.
**Open:** OPEN — verbosity levels? machine-readable output (`--json`) for scripting? a documented exit-code
contract (see F47)?

#### F64 — Per-command argument parsing

Four near-duplicate `while`/`case` loops (`cmd_start :381-388`, `cmd_done :454-461`, `cmd_sync :519-525`,
`cmd_init :941-946`).
**Failure:** duplicated logic drifting per command; extra positionals silently dropped (last wins); no
`--` separator; no validation of branch names at all (which enables [D-06](#verified-defects-and-risks)).
**Module:** `bin/agent-task` (shared parser). **Testability:** **pure argv → parsed-options — excellent unit
test target** once extracted.
**Open:** OPEN — subcommands vs flag-modes (F08)? OPEN — add branch-name validation?

#### F65 — Version constant

`CLAUDE_TASK_VERSION="0.2.1"` (`:20`), used only by `cmd_update`'s comparison and its own sanity check.
**Failure:** no `--version` flag; no changelog or versioning policy exists upstream [docs].
**Module:** `bin/agent-task`. **Testability:** trivial.
**Open:** OPEN — add `--version`; define a versioning and compatibility policy.

---

## Internal responsibilities

| Responsibility | Where it lives today | Notes |
|---|---|---|
| CLI parsing | `main` + 4 duplicated loops in each `cmd_*` | F64; no shared parser, no validation |
| Configuration | `config_path`, `has_project_config`, `cfg_get`, `env_file_value`, `resolve_passthrough_env`, `resolve_project_name`, `detect_build_tool` | Reasonably cohesive already |
| Git repository handling | `require_git_repo`, `resolve_main_repo_root` | Also implicit in F34's knowledge of worktree internals |
| Git branch handling | 3-way resolution inside `find_or_create_worktree`; rebase/push inside the sync string; upstream checks in `cmd_done` | **Scattered across three places** |
| Git worktree handling | `worktree_path`, `worktree_exists`, `find_or_create_worktree`, removal in `cmd_done` | Removal is not in a worktree function |
| Container image handling | `image_tag_for_project`, `config_hash`, `needs_rebuild`, `build_project_image`, `ensure_global_image` | Cohesive |
| Container lifecycle | `container_name_for`, `running_container`, `build_run_args`, the `docker run`/`exec`/`rm` calls | Calls are inline in `cmd_*`, not wrapped |
| Coding-agent startup | the `case "$mode"` block in `cmd_start` | Hardcoded to `claude`; F39 |
| Task/spec handling | `tasks/` mkdir in `cmd_init`; the strip commit in the sync string | Two fragments of a workflow the script doesn't otherwise implement |
| GitHub / PR handling | push + `gh` calls inside the sync string | Not host-side at all |
| Build/test execution | `test_cmd` mapping + `detect_build_tool` | Would be a new `build.sh` |
| Scaffolding / templating | `render_dockerfile`, `write_*`, `mcp_server_json`, `ask_choice`, `sed_escape_replacement`, `ensure_gitignore_entries` | ~430 lines — the largest single block |
| Cleanup | `cmd_done` (container + worktree) | No orphan/prune handling |
| Logging | `info`, `err`, `die`; `echo` in `usage`/`cmd_init` | F63 |
| Validation | `require_git_repo`, `ask_choice` allow-lists, `permissionMode` enum, the identifier regex at `:353` | **No branch-name, path, or config-schema validation** |
| Filesystem handling | `mkdir -p` for worktree parent/caches, `cp -n` seeding, `mktemp`/`mv` in update | Spread across layers |
| Distribution / self-update | `resolve_latest_tag`, `cmd_update` | Tied to single-file distribution |
| Naming / sanitisation | `sanitize`, `project_name` | Shared by container and image naming; candidate for its own module |

Two responsibilities the target structure does not yet name: **build/test execution** and
**scaffolding/templating** (the largest block). Both need a home decision.

---

## Existing function map

43 functions. "Mixed" flags functions spanning more than one responsibility.

| # | Function | Line | Responsibility | Proposed module | Mixed |
|---|---|---|---|---|---|
| 1 | `info` | 35 | logging | `logging.sh` | |
| 2 | `err` | 36 | logging | `logging.sh` | |
| 3 | `die` | 37 | logging + control flow | `logging.sh` | |
| 4 | `usage` | 39 | CLI help | `bin/agent-task` | |
| 5 | `require_git_repo` | 67 | git validation | `git.sh` | |
| 6 | `resolve_main_repo_root` | 77 | git identity | `git.sh` | |
| 7 | `sanitize` | 91 | naming | `container.sh` / `naming.sh` | |
| 8 | `project_name` | 96 | naming | `config.sh` | |
| 9 | `worktree_path` | 103 | worktree paths | `worktree.sh` | |
| 10 | `worktree_exists` | 110 | worktree query | `worktree.sh` | |
| 11 | `find_or_create_worktree` | 116 | worktree create **+ branch resolution + fs** | `worktree.sh` + `git.sh` | **yes** |
| 12 | `config_path` | 144 | config location | `config.sh` | |
| 13 | `has_project_config` | 148 | config predicate | `config.sh` | |
| 14 | `resolve_passthrough_env` | 159 | config resolution | `config.sh` | |
| 15 | `cfg_get` | 169 | config read | `config.sh` | |
| 16 | `env_file_value` | 179 | env-file parsing | `config.sh` | |
| 17 | `resolve_project_name` | 203 | identity **+ config + env file + naming** | `config.sh` | **yes** |
| 18 | `detect_build_tool` | 219 | build-system detection | `config.sh` / `build.sh` | |
| 19 | `image_tag_for_project` | 232 | image naming | `container.sh` | |
| 20 | `container_name_for` | 236 | container naming | `container.sh` | |
| 21 | `config_hash` | 241 | hashing | `container.sh` | |
| 22 | `needs_rebuild` | 245 | image cache policy | `container.sh` | |
| 23 | `build_project_image` | 252 | image build **+ validation + policy** | `container.sh` | **yes** |
| 24 | `ensure_global_image` | 275 | image build/pull **+ fallback policy** | `container.sh` | **yes** |
| 25 | `build_run_args` | 298 | run argv **+ config + env + git + fs writes** | `container.sh` | **yes (worst)** |
| 26 | `running_container` | 374 | container query | `container.sh` | |
| 27 | `cmd_start` | 378 | **CLI + git + worktree + config + image + container + agent launch** | `session.sh` (orchestrator) | **yes (worst)** |
| 28 | `cmd_done` | 452 | **CLI + git safety + container rm + worktree rm** | `session.sh`/`worktree.sh` | **yes** |
| 29 | `cmd_sync` | 517 | **CLI + git + config + image + container + rebase + test + spec strip + push + PR + exit mapping** | `pull-request.sh` (orchestrator) | **yes (worst)** |
| 30 | `sed_escape_replacement` | 623 | templating util | `scaffold.sh` | |
| 31 | `ask_choice` | 627 | interactive prompt | `scaffold.sh` | |
| 32 | `render_dockerfile` | 647 | container definition templating | `scaffold.sh` / runtime project | **ownership** |
| 33 | `write_devcontainer_json` | 713 | runtime definition templating | `scaffold.sh` / runtime project | **ownership** |
| 34 | `write_devcontainer_env_example` | 744 | config templating | `scaffold.sh` | |
| 35 | `write_allowed_domains` | 767 | network policy templating | `scaffold.sh` / runtime project | **ownership** |
| 36 | `mcp_server_json` | 821 | agent config data | `scaffold.sh` / agent config | **ownership** |
| 37 | `write_mcp_json` | 846 | agent config merge | `scaffold.sh` / agent config | **ownership** |
| 38 | `write_claude_settings` | 867 | agent config write | `scaffold.sh` / agent config | **ownership** |
| 39 | `write_claude_md_skeleton` | 905 | agent memory write | `scaffold.sh` / agent config | **ownership** |
| 40 | `ensure_gitignore_entries` | 931 | repo hygiene | `config.sh` / `git.sh` | |
| 41 | `cmd_init` | 939 | **CLI + questionnaire + 9 writers + gitignore + git add** | `scaffold.sh` (orchestrator) | **yes** |
| 42 | `resolve_latest_tag` | 1063 | release lookup | `selfupdate.sh` | |
| 43 | `cmd_update` | 1068 | download + install | `selfupdate.sh` | |
| — | `main` | 1108 | dispatch | `bin/agent-task` | |

### Mixed-responsibility functions, spelled out

```
Function: cmd_start (:378-450)
Contains:
- CLI argument parsing (F01, F09)
- git repo validation + main-root resolution (F11, F12)
- worktree find-or-create incl. branch creation (F19)
- project-name resolution (F14)
- config reads: firewall, permissionMode (F22, F36, F38)
- two-mode image resolution + build/pull (F28, F29)
- Maven cache provisioning (F33)
- running-container detection + reuse/refusal policy (F37)
- run-argv assembly delegation (F30)
- agent launch-command selection (F39)
- process replacement (exec)
Potential future split:
- bin/agent-task   (parsing)
- git.sh           (repo/root)
- worktree.sh      (find-or-create)
- config.sh        (name, firewall, permission mode, cache path)
- container.sh     (image resolve/build, argv, run/exec, name checks)
- session.sh       (mode → launch command; orchestration)
```

```
Function: cmd_sync (:517-614)
Contains:
- CLI parsing (F04)
- GH_TOKEN + clean-tree preconditions (F41)
- main-root, worktree existence, project name (F12, F18, F14)
- config reads: firewall, buildTool (F22) or detection (F25)
- image resolution + build (F28, F29), cache provisioning (F33)
- run-argv assembly, headless (F30)
- an interpolated in-container pipeline: fetch, rebase, test, strip tasks/, push, PR (F42-F46)
- exit-code mapping (F47)
Potential future split:
- bin/agent-task    (parsing)
- git.sh            (fetch/rebase/push/upstream)
- build.sh          (build-tool → test command)
- pull-request.sh   (PR detect/create, orchestration, exit contract)
- container.sh      (headless exec of steps)
- task-spec ownership OPEN (the tasks/ strip commit, F44)
```

```
Function: build_run_args (:298-372)
Contains:
- filesystem side effect: cp -n devcontainer.env seeding (F31)
- container argv assembly: TTY, name, caps, workdir (F30)
- mount policy: auth, cache, worktree, main .git (F32, F33, F34)
- env policy: fixed vars, env-file, TZ precedence, conditional forwards (F35)
- config resolution: passthrough env (F24)
- firewall translation (F36)
Potential future split:
- config.sh     (env resolution + seeding, or removed entirely)
- container.sh  (pure context → argv)
- git.sh        (the .git mount rule, which encodes git worktree internals)
```

```
Function: cmd_init (:939-1055)
Contains:
- CLI parsing + already-initialised guard (F06, F10)
- 10-question questionnaire (F49)
- config JSON generation (F50)
- 7 file writers, 3 of them "never overwrite" (F51-F57)
- directory creation incl. tasks/ (F58)
- .gitignore management (F59)
- git staging + user-facing summary (F60)
Potential future split:
- bin/agent-task  (parsing)
- scaffold.sh     (questionnaire + templates)
- config.sh       (config writer)
- git.sh          (staging)
- runtime project / agent-config project / task-spec skill (ownership OPEN for F51-F58)
```

```
Function: find_or_create_worktree (:116-140)
Contains:
- path derivation (F17)
- existence check (F18)
- parent directory creation (filesystem)
- 3-way branch resolution: local / origin / new-off-HEAD (F19, git branch semantics)
- worktree creation
Potential future split:
- worktree.sh  (path, existence, add/remove)
- git.sh       (branch existence + which base to branch from)
```

---

## Proposed module classification

Mapping onto the preferred target layout. **This is a classification exercise only — no code has been
moved, and two modules (`build.sh`, `scaffold.sh`) are proposed additions that the target layout does not
yet name.**

```
bin/
  agent-task        F08, F64, F65 — dispatch, shared arg parsing, usage, version
lib/
  config.sh         F14, F21-F25, F31, F35, F50, F53, F59
  git.sh            F11, F12, F19(branch part), F42, F45, F48, F60
  worktree.sh       F17-F20
  container.sh      F13, F15, F16, F26-F30, F32-F34, F36, F37, F40, F09
  session.sh        F01-F03, F38, F39
  pull-request.sh   F04, F41, F46, F47
  logging.sh        F63
  build.sh          F25(detection), F43            <- proposed addition
  scaffold.sh       F06, F49, F51-F58              <- proposed addition, ownership OPEN
  selfupdate.sh     F07, F61, F62                  <- proposed addition, may not survive
```

### `config.sh`
`resolve_project_name`, `project_name`, `config_path`, `has_project_config`, `cfg_get`,
`env_file_value`, `resolve_passthrough_env`, `detect_build_tool`, the `devcontainer.env` seeding, the
fixed env-forward policy, and the config writer from `--init`.
Already the most cohesive cluster. Almost entirely pure or fixture-driven → highest unit-test yield.
OPEN: config file name/location/format; schema validation; whether a user-level config layer exists.

### `git.sh`
`require_git_repo`, `resolve_main_repo_root`, the branch-existence probes from
`find_or_create_worktree`, the `--done` dirty/upstream predicates, fetch/rebase/push, and `git add`.
Note that fetch/rebase/push currently exist **only** as text inside the sync string — moving them here
means extracting them from the container-side script, which is a design decision, not a mechanical move.
OPEN: does git run on the host, in the container, or either?

### `worktree.sh`
`worktree_path`, `worktree_exists`, `find_or_create_worktree` (path/existence part), and the removal
currently inlined in `cmd_done`.
OPEN: worktree layout (sibling vs central); space-in-path support; whether isolation must be worktrees at
all (see runtime discussion).

### `container.sh`
`sanitize`, `container_name_for`, `image_tag_for_project`, `config_hash`, `needs_rebuild`,
`build_project_image`, `ensure_global_image`, `build_run_args`, `running_container`, and the inline
`docker run` / `docker exec` / `docker rm` calls.
This is the module the runtime abstraction question lands on — see
[Container runtime requirements](#container-runtime-requirements).
OPEN: whether `sanitize` belongs here or in a shared `naming.sh`.

### `session.sh`
`cmd_start`'s orchestration, mode→permission resolution, and the agent launch mapping.
**Today there is no session state at all** — no file, no serialisation. If Agent CLI wants resumable,
listable, or detachable sessions, `session.sh` is largely new code rather than migrated code.
OPEN: is the agent pluggable? is `--rm` the right lifecycle?

### `pull-request.sh`
`cmd_sync`'s orchestration, preconditions, `gh` interaction, and the exit-code contract.
OPEN: forge-neutrality; base-branch configurability; whether "sync" stays one command.

### `logging.sh`
`info`, `err`, `die`, plus a policy for the `echo`-to-stdout usages in `usage`/`cmd_init`.
OPEN: levels, streams, machine-readable output, exit-code contract.

### Proposed additions
- **`build.sh`** — build-system knowledge (`detect_build_tool`, tool→test-command mapping). Currently split
  between `config.sh`-ish helpers and the container-side string.
- **`scaffold.sh`** — the ~430-line template block. Ownership is OPEN for most of its contents.
- **`selfupdate.sh`** — only meaningful if Agent CLI stays single-file-installable; a multi-file `lib/`
  layout makes F07 a different problem entirely.

---

## External dependencies

### Host-side commands

| Command | Used at | Mandatory? | Isolatable behind a module? | Test approach |
|---|---|---|---|---|
| `git` | F11, F12, F17-F20, F42, F45, F48, F60 | **Yes** — everything | Yes → `git.sh` | Real git on temp repos (fast, hermetic). Do **not** mock. |
| `docker` | F27-F30, F37, F40, F04 | **Yes** for any session | Yes → `container.sh` | Fake `docker` on `PATH` for argv assertions; real Docker for a small integration tier |
| `jq` | F22, F24, F50, F55, F56, F61 | Only with a config file / `--init` / `--update` | Yes → `config.sh` | Real `jq` (deterministic) |
| `sed` | F13, F51 (+ CSV trimming) | Yes | Yes | Real; **BSD vs GNU differences matter** |
| `tr` | F13, CSV splitting | Yes | Yes | Real |
| `awk` | F18 | Yes | Yes | Real; the space bug (D-02) is an awk-usage bug |
| `grep` | F23, F37, F59, F62 | Yes | Yes | Real; `-qx`, `-qxF`, `-E`, `-m1` used |
| `sha256sum` | F26 | Only for configured projects | Yes | Real; **portability to verify (D-04)** |
| `curl` | F61, F62 | Only `--update` | Yes → `selfupdate.sh` | Fake `curl` on `PATH` |
| `basename`/`dirname` | F12, F14, F17 | Yes | Yes | Real |
| `mkdir`/`cp`/`touch`/`mv`/`chmod`/`rm` | throughout | Yes | Partly | Real, in temp dirs |
| `mktemp` | F62 | Only `--update` | Yes | Real |
| `readlink` | F62 | Optional (`command -v` guarded) | Yes | Real; `-f` portability |
| `xargs` | F55, F56 (CSV trimming) | `--init` only | Yes | Real |
| `cut` | F26, F62 | Yes | Yes | Real |
| `sudo` | — | No (host) | — | — |
| `bash` | the script itself | **Yes**, bash ≥ 4 (arrays, `read -ra`, `[[ =~ ]]`, `${!var}`) | — | Test under both bash 3.2 (stock macOS `/bin/bash`) and 5.x if 3.2 must be supported — **OPEN** |

**Not used on the host but frequently assumed:** `gh` is *not* a host dependency — every `gh` call runs
inside the container (F46). `docker compose` and the `devcontainer` CLI are **never** invoked (F52 [code]).

### Container-side commands (dependencies of the image, not the script)

`git`, `gh`, `jq` (entrypoint), `bash`, `zsh`, `claude`, `iptables`/`ip`/`dig` (firewall),
`sudo`, `mvn`/`mvnw` or `gradle`/`gradlew`, `sdk` (SDKMAN, at build time), `curl`, `timeout`, `awk`.
For test purposes these are contract requirements on whatever runtime Agent CLI drives — see the
runtime interface below.

### Network dependencies

`ghcr.io` (base image pull), `api.github.com` (release lookup + `gh`), `github.com` (push),
`get.sdkman.io`/`api.sdkman.io` + Debian apt mirrors (image build), plus whatever the project's
`allowed-domains.conf` permits at run time.

### Host state dependencies

`$HOME/.claude-container/claude`, `$HOME/.claude-container/claude.json`, `$HOME/.claude-m2-cache`
(**none of which the script creates** — D-07), `~/.local/bin` for the install, the parent directory of the
repo (must be writable for worktrees), and `$HOME/.gitignore_global` / `core.excludesFile` (which can break
`--init` — D-01).

---

## Current state handling

**There is no persisted state.** No state file, database, lockfile, cache manifest, or session registry.
Everything is recomputed on every invocation. Concretely, the state of a "task" is spread across:

| State | Where it lives | Authority | Reconstructed by |
|---|---|---|---|
| Which tasks exist | `git worktree list` + branch refs | git | F18 |
| Task working files | the worktree on disk | filesystem | F17 |
| Is a session live | `docker ps` name match | Docker | F37 |
| Agent auth / history | `~/.claude-container/{claude,claude.json}` (host bind mount) | host filesystem | F32 |
| Agent conversation state | inside the mounted `~/.claude` | Claude Code | not managed |
| Project identity | env file → config `.name` → dir basename | recomputed each run | F14 |
| Image freshness | Docker image label `com.claude-task.config-hash` | Docker | F27 |
| Dependency cache | `m2-cache` dir (per-project or global) | filesystem | F33 |
| In-progress rebase | the shared `.git` (bind-mounted) | git | not managed |
| Task spec | `tasks/*.md` committed to the branch | git | not managed |

Consequences worth an explicit decision:

- **Derived state is self-healing but unqueryable.** There is no `agent-task list`, no way to see which
  tasks exist, which are running, or which are stale.
- **Identity is recomputed, so it can drift.** Renaming the project orphans a running container with no
  recovery path [docs].
- **The container is the session, and it is `--rm`.** Nothing survives a container exit except the worktree
  and the global mounts.
- **Name collisions are silent** (D-03) because nothing records which branch a container actually belongs to.
  A label or a small state file would make this detectable.

OPEN — does Agent CLI keep the "derive everything" model, or introduce explicit session state (a state
file, or Docker labels carrying the raw branch/project)? This choice determines how much of `session.sh` is
migration versus new construction.

---

## Container runtime requirements

Derived from what the script actually asks of Docker — deliberately stated **without** Docker specifics, so it
can be compared against Dev Containers, Docker Sandboxes, or anything else.

### Operations actually exercised

| Operation | Current implementation | Required by |
|---|---|---|
| Build an environment from a definition | `docker build -f <dockerfile> -t <tag> --label <hash> <context>` | F28 |
| Acquire a prebuilt environment | `docker pull <ref>` | F29 |
| Detect environment freshness | `docker image inspect` → label comparison | F27 |
| Detect a live instance by name | `docker ps --format '{{.Names}}'` | F37 |
| Detect any instance by name | `docker ps -a --format '{{.Names}}'` | F40 |
| Create + start + attach interactively, then auto-destroy | `docker run -it --rm --name …` | F01-F03 |
| Run a command headlessly, capture exit code | `docker run --rm` (no `-t`) | F04 |
| Exec a second interactive shell into a live instance | `docker exec -it … /bin/zsh` | F03 |
| Force-destroy an instance | `docker rm -f` | F40 |
| Mount a host directory read-write | `-v host:container` ×4 | F30, F32-F34 |
| **Mount a host path at an identical absolute path** | `-v /abs:/abs` | **F34 — the hard one** |
| Mount a single host *file* | `-v …/claude.json:/home/node/.claude.json` | F32 |
| Set environment variables | `-e` | F30, F35 |
| Load environment from a file | `--env-file` | F30 |
| Set the working directory | `-w /workspace` | F30 |
| Grant elevated network capability | `--cap-add=NET_ADMIN,NET_RAW` | F36 |
| Allocate a TTY conditionally | `-it` vs nothing | F30 |
| Name an instance for later lookup | `--name` | F15, F37, F40 |

### Minimal interface the current behaviour implies

Purely descriptive of today's needs; **not a proposal to implement**:

```
runtime_build      (definition, context, identity-label) -> environment-ref
runtime_acquire    (published-ref)                       -> environment-ref
runtime_is_current (environment-ref, identity-label)     -> bool
runtime_exists     (instance-name, include-stopped)      -> bool
runtime_create+run (environment-ref, instance-name, mounts[], env{}, workdir,
                    capabilities[], tty?, command[])     -> exit-code    # create/start/attach/destroy fused
runtime_exec       (instance-name, command[], tty?)      -> exit-code
runtime_remove     (instance-name, force)                -> void
```

Note what is **absent** from today's usage, and would therefore be new capability rather than migration:
`runtime_stop`, `runtime_start` (restart a stopped instance), detached/background execution, log retrieval,
port publishing, health checks, and resource limits. The script's model fuses create/start/attach/destroy
into one blocking call.

### Requirements the runtime must satisfy

1. **Host-path-identical bind mounts** for the git worktree scheme (F34). This is the single most
   constraining requirement.
2. **Single-file bind mounts** (`claude.json`), including the failure mode where a missing source is
   auto-created as a directory (F32, D-07).
3. **Bidirectional read-write persistence** to host paths — the agent edits the worktree, and its auth state
   is written back to `~/.claude-container`.
4. **Interactive TTY attach**, and a **second concurrent attach** to the same instance (F03).
5. **Headless execution with a preserved exit code**, including a custom code (`10`) crossing the boundary
   (F04, F47).
6. **Elevated network capability** for in-container iptables (F36) — or, alternatively, the runtime provides
   network policy itself and this requirement disappears.
7. **Stable name-based addressing** across separate CLI invocations (F37, F40) — the only handle the tool keeps.
8. **Credential delivery via environment variables** (F35), never written to disk.
9. **Content-addressed environment freshness** — currently a label, so the runtime must support arbitrary
   metadata on a built environment, or Agent CLI must track it itself.
10. **Concurrency:** multiple instances of the same project running at once (several branches, plus a
    `-sync` instance alongside an interactive one).

OPEN — items 1, 6, and 9 are the ones most likely to differ between candidate runtimes, and item 1 may not be
satisfiable at all by non-local runtimes. See [`runtime-discussion.md`](./runtime-discussion.md).

---

## Testing analysis

### Baseline: what exists today

**Nothing tests `bin/claude-task`.** Verified against the full repo tree and CI config:

- No `tests/` directory, no `*.bats`, no `*_test.sh`, no shellcheck configuration.
- `.github/workflows/build.yml` is the only workflow. It builds four container-image variants and runs three
  container-level tests (`VAADIN_PRO_KEY` visibility, `opencode --version`, dockerd boots). **The script is
  never linted, never `bash -n`'d, never executed in CI.**
- The only stated verification practice lives inside the two committed task specs: `bash -n` plus manual,
  human-gated Definition-of-Done checks [docs].
- A "host verification checklist" referenced in the script's own comment (`:645-646`) **does not exist** [docs].

So for every F-ID: **Existing tests: none.** The tables below are therefore all *missing* tests.

### Recommended test tiers

| Tier | Scope | Needs | Speed |
|---|---|---|---|
| **Unit** | pure functions: naming, path derivation, parsing, precedence, argv assembly, decision tables | bash + coreutils only | milliseconds |
| **Integration (git)** | worktree/branch/safety behaviour against real temp repositories and a local bare "remote" | `git` only, **no Docker** | seconds |
| **Integration (scaffold)** | `--init` golden files, driven by piped answers | `git` + `jq`, **no Docker** | seconds |
| **Integration (runtime)** | build/run/exec/rm, mounts, TTY, exit codes | Docker | minutes |
| **System / E2E** | full lifecycle: init → start → commit → sync → PR → done | Docker + a real or faked forge | slow, few cases |

A useful property fell out of the verification work: **the two largest testable surfaces (`--init` and all
git/worktree logic) need no Docker at all.** That makes a fast, hermetic majority-of-coverage tier realistic.

### Per-capability testing requirements

Grouped to stay readable; every F-ID appears exactly once.

**Pure logic → unit tests (no external state).**
F13 sanitize · F15 container name · F16 image tag · F17 worktree path · F26 hashing ·
F38 permission resolution · F39 launch-command mapping · F43 tool→test-command mapping ·
F47 exit-code mapping · F63 logging · F64 arg parsing · F65 version.
*Mocks/fakes:* none.
*Edge cases:* F13 — the verified collision set (`feature/x` vs `feature-x` vs `Feature/X`), non-ASCII,
all-punctuation → empty, leading/trailing separators, very long names vs Docker's name limits.
F17 — `feature` vs `feature/x` conflict, spaces, absolute-path assumptions.
F38/F39 — the full (mode × permissionMode) matrix including the invalid-enum path and the fact that
`--plan` skips validation.
F64 — extra positionals (last-wins), flags before/after the branch, unknown flags, empty argv, `--` handling.

**Filesystem-fixture logic → unit tests with temp directories.**
F21 config discovery · F22 config read · F23 env-file parsing · F24 passthrough resolution ·
F25 build-tool detection · F14 project-name precedence · F31 env seeding · F59 gitignore entries.
*Mocks/fakes:* none — real files in `mktemp -d`; a controlled environment for F24/F14.
*Edge cases:* F22 — absent field, explicit `null`, explicit `false` (the `//` operator swallows it),
malformed JSON, and the jq-interpolation hardening question.
F23 — commented `#KEY=`, quoted/unquoted, leading/trailing whitespace, duplicate keys (last wins),
missing file, CRLF, `export KEY=`.
F24 — field present vs absent vs explicit `[]` (three distinct behaviours), non-identifier names,
set-but-empty host vars.
F25 — maven-only, gradle-only, both (maven wins), neither, wrapper present but `pom.xml` absent.
F14 — all three tiers plus sanitisation, and the worktree-vs-main-repo asymmetry.
F31 — the regression that seeding an unignored `devcontainer.env` makes F41/F48 refuse.

**Argv assembly → unit tests against a fake `docker` on `PATH`.**
F27 rebuild detection · F28 project build · F29 global build/pull · F30 run args · F32 auth mounts ·
F33 cache mounts · F34 `.git` mount · F35 env forwarding · F36 firewall flag · F37 running detection ·
F40 removal · F09 rebuild flag.
*Mocks/fakes:* a `docker` shim recording argv and returning scripted output for `ps`/`image inspect`.
*Edge cases:* F30 — interactive vs headless (`-it` present/absent), env-file present/absent, TZ precedence
(host > file > built-in default), passthrough set/unset/invalid-name, and **argument ordering** where later
`-e` must override `--env-file`.
F34 — normal clone (mount present), bare repo (mount absent → must this fail loudly?), path with spaces.
F32 — missing host auth paths (the D-07 directory trap).
F27 — no image, image without the label, matching label, mismatching label, `docker` failure.
F37 — running, stopped-but-present, absent, and a name that is a substring of another (`grep -qx` guards this
— worth a regression test).
*Prerequisite:* F30 must first be refactored to return argv instead of mutating a caller variable; otherwise
this whole tier is unreachable.

**Real-git integration tests (no Docker).**
F11 repo check · F12 main-root resolution · F18 existence detection · F19 find-or-create ·
F20 removal · F48 safety checks · F42 rebase · F45 push · F60 staging.
*Mocks/fakes:* none for git. A local bare repo as `origin` for F42/F45. A fixture `core.excludesFile`
for F60.
*Edge cases:* F12 — main checkout, linked worktree, bare repo, submodule, symlinked path, old git without
`--path-format`.
F18 — **path containing a space (fails today, D-02)**, path that is a prefix of another, stale metadata.
F19 — all three branch-resolution strategies, branch already checked out elsewhere, no `origin`, non-empty
target dir, and the ambient-HEAD dependency of the new-branch case.
F48 — the (clean|dirty) × (upstream|none) × (pushed|unpushed) × (force|not) matrix, plus untracked-only dirt.
F42 — clean rebase, conflicting rebase (must produce 10 and leave the rebase in progress), non-`main` base
(fails today).
F60 — **globally-ignored `.claude` (fails today, D-01)**, already-staged, and the worktree-vs-main-root anchor.

**Scaffolding integration tests (no Docker) — golden files.**
F06 init · F49 questionnaire · F50 config JSON · F51 Dockerfile · F52 devcontainer.json ·
F53 env example · F54 allowlist · F55 `.mcp.json` · F56 settings · F57 CLAUDE.md · F58 tasks dir ·
F10 force semantics.
*Mocks/fakes:* none — pipe answers on stdin (**verified to work**), assert files byte-for-byte.
*Edge cases:* the full answer matrix (3 Java versions × 3 vendors × 3 build tools × 3 variants ×
2 firewalls × 3 permission modes is too large — sample the axes that change output: vendor→tag, build tool→
SDKMAN line and allowlist additions, variant→image suffix, firewall→file written or not).
Idempotency: re-run refuses; `--force` regenerates machine-owned files but **must not** overwrite
`CLAUDE.md`/`.claude/settings.json`. `.mcp.json` merge must preserve hand-added servers and skip unknown names.
Short/empty answer lists must fall back to defaults. Ignored-path staging must not abort mid-way.

**Runtime integration tests (Docker required).**
F01 start · F02 plan · F03 shell/attach · F05 done · F44 spec strip · F46 PR.
*Mocks/fakes:* a fake `gh` for F46 unit-level; a real repo for E2E.
*Edge cases:* F01 — session actually starts and `git status` works **inside** the container over a linked
worktree (the F34 contract); container already running → refusal; auth mount round-trip.
F03 — second attach while a session is live; stopped-container name conflict.
F05 — container removed and worktree gone; the D-05 case where the worktree is already absent.
F44 — `tasks/` tracked vs untracked (no-op), idempotency on re-sync.

**System/E2E (few, slow).**
F04 sync end-to-end; the full init→start→sync→done lifecycle.
*Edge cases:* rebase conflict → exit 10 → interactive resolve → re-sync succeeds; test failure aborts before
push; PR exists → reported not recreated.

**Distribution.**
F07/F61/F62.
*Mocks/fakes:* fake `curl` serving a canned releases JSON and a canned script; a temp install dir.
*Edge cases:* rate-limited/empty tag; download failure leaves no partial install; downloaded file failing the
version sniff; same version → "already up to date"; symlinked install path; unwritable target; cross-filesystem
`mv`.

### Hard-to-test areas (and why)

1. **`cmd_sync`'s in-container pipeline (F42-F46).** 25 lines of bash inside an interpolated string executed
   by `bash -lc` in the container. Unreachable from any host test; only observable end-to-end. Highest-risk,
   least-testable code in the script.
2. **`exec docker …` (F01-F03).** Process replacement means no assertions after launch and no dry-run.
3. **`build_run_args`'s caller-variable contract (F30).** Cannot be called and inspected in isolation without
   replicating the dynamic-scoping convention; it also performs a filesystem write.
4. **The interactive questionnaire (F49).** Mitigated — verified drivable via stdin — but the *order* of
   prompts is an undocumented contract for scripted callers.
5. **Image builds (F28/F29/F51).** Minutes per case, network-dependent, and the SDKMAN candidate resolution is
   explicitly unverified upstream. Practically untestable in a fast suite.
6. **Firewall behaviour (F36).** Enforcement lives in the image, needs `NET_ADMIN`, and depends on live DNS.
7. **Host-environment coupling.** Behaviour depends on `$HOME`, `core.excludesFile` (D-01), host env vars, the
   parent directory's writability, and GNU-vs-BSD tool variants — so tests must control the environment
   explicitly or they will be machine-dependent.
8. **`die` calls `exit`.** Any function reachable via `die` can only be tested in a subshell, which is
   workable but must be a deliberate harness convention.

### Suggested minimum bar for migrated capabilities

For discussion, not a decision: every migrated capability gets (a) unit tests for its pure logic,
(b) a git-integration test where git semantics matter, (c) a fake-`docker` argv test where a container command
is produced, and (d) at most a handful of shared E2E tests for the lifecycle. Plus `shellcheck` and `bash -n`
in CI from the first commit — currently absent entirely.

---

## Coupling and testability problems

1. **Orchestration fused with execution.** `cmd_start`, `cmd_sync`, `cmd_init` each mix parsing, resolution,
   side effects, and process launch. There is no seam between "decide what to do" and "do it", so nothing can
   be asserted without performing it.
2. **No dry-run anywhere.** The computed `docker run` argv, the resolved config, the chosen image, and the
   worktree that would be created are all unobservable.
3. **Output parameters via dynamic scoping.** `build_run_args` writes `RUN_ARGS` in its caller. This is the
   single biggest structural obstacle to unit-testing the container layer.
4. **`exec` as the terminal operation.** Nothing can run after a session starts — no cleanup, no telemetry,
   no post-conditions.
5. **A pipeline embedded as an interpolated string.** F42-F46 exist only as text (`:577-601`), which also
   creates the injection defect D-06. Neither testable nor lintable.
6. **Two configuration modes selected by file existence.** `has_project_config` silently switches image,
   cache, firewall default, and build-tool resolution. Every test matrix doubles, and the global path is the
   one users are least likely to exercise deliberately.
7. **Git-internals knowledge leaking into the container layer.** The `.git` same-path mount rule (F34) sits in
   `build_run_args` and encodes how linked worktrees resolve their git dir.
8. **Domain-specific defaults in a general tool.** `VAADIN_PRO_KEY`, `NOTIFICATION_URL`, Vaadin/javadoc
   allowlist entries, `vaadin-marketplace` handling, Maven-first assumptions, and the `claude` binary itself
   are hardcoded.
9. **Duplicated truth.** The mount/env set exists in `build_run_args`, in the generated `devcontainer.json`,
   and in the repo's own `docker-compose.yml` — and they already disagree (TZ default, the `.git` mount).
10. **Host-environment sensitivity.** `sha256sum`/`readlink -f` availability, BSD-vs-GNU `sed`/`awk`,
    `core.excludesFile`, and `$HOME` layout all change behaviour.
11. **Undeclared globals.** `names` leaks in `write_mcp_json` (`:851`) and `write_claude_settings` (`:877`).
12. **No input validation.** Branch names are never validated, which is exactly how D-06 becomes reachable.
13. **Single failure mode.** `die` always exits 1; only `--sync` distinguishes an outcome (10). Callers and
    tests cannot tell failure classes apart.
14. **jq programs built by string interpolation** (`cfg_get`, `:171`) — currently safe, structurally fragile.

---

## Verified defects and risks

Found while analysing; recorded so the incremental review can decide what (if anything) to do about each.
**No fixes have been made.** D-01 through D-03 and D-06 were reproduced by execution on macOS; the rest are
read from the code.

| ID | Severity | Summary | Evidence | Related |
|---|---|---|---|---|
| **D-01** | High (UX) | `--init` aborts with exit 1 **after writing every file** when any scaffolded path is gitignored — e.g. a global `core.excludesFile` containing `.claude`. `git add` runs without `-f`; `set -e` then kills the command, so the "Staged" summary and commit hint never print and the index is left partially staged (8 of 9 paths). | **[verified]** in a throwaway repo: `git check-ignore -v .claude/settings.json` → `~/.gitignore_global:12:.claude`; exit 1; all 10 files present on disk. A global `.claude` ignore is a common developer setup. | F60, F06 |
| **D-02** | High | `worktree_exists` is broken for any path containing a space: `awk '$2==p'` splits the porcelain line on whitespace. Consequences: `--done`/`--sync` die with "No worktree found" for an existing worktree, and `find_or_create_worktree` tries to re-add it. | **[verified]** worktree at `…/my repo-worktrees/spacey` → `NOT FOUND`. | F18 |
| **D-03** | Medium | Container names collide. `sanitize` maps `feature/x`, `feature-x` and `Feature/X` to the same name, so two different branches with live worktrees fight over one container: the second start dies with "already running", and `--done` on one can remove the other's container. All-punctuation branches yield `claude-<proj>-`. Non-ASCII is mangled. | **[verified]** all three inputs → `claude-proj-feature-x`; `ümlaut` → `mlaut`. | F13, F15 |
| **D-04** | Medium (portability) | `config_hash` uses `sha256sum`, a GNU coreutils name. Present on this host at `/sbin/sha256sum`, but historically absent on macOS where `shasum -a 256` is the portable form. If absent, every configured project's rebuild check fails. Same class of question for `readlink -f`. | **[verified]** present here; **needs verification across supported macOS versions** before being called a bug. | F26, F62 |
| **D-05** | Medium | `--done` resolves and validates the worktree **before** touching the container (`:471-473`), so if a worktree was removed manually the container can never be cleaned up by the tool. There is no orphan sweep. | [code] | F05, F40 |
| **D-06** | Medium (security) | Shell injection via branch name in `--sync`. `${branch}` is interpolated unquoted into the bash string executed by `bash -lc` inside the container (`:581`). Git permits `'` in branch names, so a crafted name executes arbitrary commands in the container — which holds `GH_TOKEN` and the mounted repo. Bounded by container isolation; reachable via a fetched/remote branch name. | **[verified]** `git branch "has'quote"` succeeds; simulating the interpolation with `branch="x'; echo INJECTED; :'"` printed `INJECTED`. | F04, F42, F64 |
| **D-07** | Medium | The script never creates `~/.claude-container/claude` or `~/.claude-container/claude.json`, yet mounts both. Docker auto-creates a missing file target as a **directory**, which is precisely the trap the upstream `devcontainer.json` `initializeCommand` exists to prevent and the README warns about. On the documented script-only install path nothing creates them. | [code] + [docs] | F32 |
| **D-08** | Low | `--rebuild` is silently a no-op for projects without `claude-task.json`; `--sync` hardcodes no-rebuild so it can never force one. | [code] | F09 |
| **D-09** | Low | `cmd_init` anchors on `git rev-parse --show-toplevel`, not `resolve_main_repo_root`, so running `--init` inside a worktree scaffolds into the worktree — inconsistent with every other command. | [code] | F60 |
| **D-10** | Low | `cmd_init` computes two different project names: the answered `name_val` goes into the JSON, while the directory basename (`project_name_val`) is passed to the `CLAUDE.md` skeleton. | [code] | F50, F57 |
| **D-11** | Low | `ensure_global_image` hardcodes `--target base`, ignoring the configured `variant`; and it builds locally for **any** repo that happens to contain `.devcontainer/Dockerfile`, not only claude-container itself. | [code] | F29 |
| **D-12** | Low | `--sync` hardcodes `origin/main` as the rebase base — projects on `master`/`develop` cannot use it. | [code] | F42 |
| **D-13** | Low | `NET_ADMIN`/`NET_RAW` are granted even when `firewall: open`, i.e. capabilities are added for a feature that is switched off. | [code] | F36 |
| **D-14** | Low | The SDKMAN candidate regex requires a dot-patch segment (`__JAVA_VERSION__\.[0-9.]+-__VENDOR_TAG__`), so a candidate id without one (e.g. `25-tem`) fails the build. Upstream already flags the whole mechanism as unverified. | [code] + [docs] | F51 |
| **D-15** | Low | `TZ` default disagrees across surfaces: the script falls back to `Europe/Helsinki`, while the generated/committed `devcontainer.json` and `docker-compose.yml` default to `Europe/Berlin`. | [code] | F35 |
| **D-16** | Low | `names` is not declared `local` in `write_mcp_json` (`:851`) and `write_claude_settings` (`:877`), leaking a global. | [code] | F55, F56 |
| **D-17** | Low | The generated `.mcp.json` GitHub entry writes a literal `<YOUR_TOKEN>` placeholder into a file that `--init` then stages for commit. | [code] | F55 |
| **D-18** | Low | `--shell` cannot recover from a stopped-but-present container: `running_container` only sees running ones, so it takes the start path and hits a raw Docker name conflict. | [code] | F37, F03 |
| **D-19** | Low | Extra positional arguments are silently ignored (last wins) in all four parse loops — `claude-task foo bar` acts on `bar`. | [code] | F64 |
| **D-20** | Informational | `--init` writes `version: 1` into the config, but nothing ever reads it. No migration or compatibility policy exists. | [code] | F22, F50 |

---

## Functionality ownership questions

Candidates for relocation. **All statuses are `OPEN`** — this section exists to structure the discussion, not
to pre-empt it. The three candidate homes are **Agent CLI**, the **Runtime / Dev Environment project**, and the
**task-spec skill**.

```
Capability:  Dockerfile rendering (F51) + devcontainer.json generation (F52)
Currently:   ~90 lines of embedded templates in --init
Possible:    Runtime / Dev Environment project
Reason:      Agent CLI orchestrates worktrees and sessions; authoring container definitions and
             IDE-attach configs is the runtime's domain. Keeping them here also duplicates the
             mount/env truth that build_run_args already owns (D-15, and the omitted .git mount).
Counter:     Standalone distribution was the reason templates are embedded at all — moving them
             reintroduces a dependency on a second project being installed.
Decision:    OPEN
```

```
Capability:  Firewall allowlist generation (F54) + firewall profile plumbing (F36)
Currently:   write_allowed_domains + a single SKIP_FIREWALL env var
Possible:    Runtime project (enforcement already lives entirely in the image)
Reason:      Agent CLI contributes only "allowlist" vs "open"; every rule, the config path, and all
             enforcement are the image's. The shipped list also hardcodes Vaadin and javadocs.dev.
Counter:     Network policy is arguably a security-relevant orchestration concern the CLI should surface.
Decision:    OPEN
```

```
Capability:  .mcp.json (F55), .claude/settings.json (F56), CLAUDE.md skeleton (F57)
Currently:   three writers in --init, two of them never-overwrite
Possible:    An agent-configuration concern — the runtime project, the task-spec skill, or a new
             "agent profile" component
Reason:      These configure the *agent*, not the isolated task environment. They are also
             Claude-specific (marketplaces, plugin ids, permission deny rules) in a tool named
             Agent CLI (see F39).
Counter:     A single --init that leaves a working project is a real UX benefit.
Decision:    OPEN
```

```
Capability:  tasks/ directory creation (F58) + task-spec stripping commit (F44)
Currently:   mkdir in --init; git rm + commit inside the --sync pipeline
Possible:    task-spec skill
Reason:      "Specs live in tasks/, are committed to the feature branch, and are stripped before
             merge" is a workflow convention, not orchestration. Agent CLI implements two fragments
             of a workflow it does not otherwise participate in, with a hardcoded directory name and
             commit message. The skill that is documented to drive this flow does not exist in the
             upstream repo at all.
Counter:     Only the sync pipeline is positioned to strip the spec at the right moment (just before push).
Decision:    OPEN
```

```
Capability:  Vaadin-specific defaults — VAADIN_PRO_KEY forwarding (F35), vaadin/javadocs.dev
             allowlist entries (F54), vaadin-marketplace special case (F56), Maven-first
             assumptions (F25, F33, F43)
Currently:   hardcoded throughout
Possible:    Runtime project, or a "preset/profile" mechanism in Agent CLI
Reason:      A general orchestrator should not know about one vendor's licence key. The generic
             mechanism for it (passthroughEnv, F24) already exists.
Counter:     These are the actual daily-use defaults for this team; a generic tool with no presets
             is more setup for every project.
Decision:    OPEN
```

```
Capability:  Agent selection and launch (F39), permission-mode model (F38)
Currently:   hardcoded `claude` with a bypass/plan/ask enum
Possible:    Stays in Agent CLI, but as a pluggable agent abstraction
Reason:      The project is Agent CLI, and --init already offers an OpenCode variant that no start
             path can launch. Permission modes are a Claude concept that may not generalise.
Decision:    OPEN
```

```
Capability:  Java/Maven toolchain concerns — SDKMAN layer (F51), m2 cache (F33),
             build-tool detection and test commands (F25, F43)
Currently:   in the CLI and its templates
Possible:    Runtime project (toolchain) + a generic, configurable test command in Agent CLI
Reason:      Cache mounting and toolchain installation are environment properties. The documented
             Gradle-cache gap is a symptom of hardcoding one ecosystem.
Decision:    OPEN
```

```
Capability:  Self-update (F07, F61, F62)
Currently:   single-file curl-replace
Possible:    Removed, or replaced by a packaging story
Reason:      A modular lib/ layout invalidates single-file self-update entirely.
Decision:    OPEN — blocked on the distribution decision, which should be settled early because it
             constrains the module layout.
```

```
Capability:  Host state bootstrap (F32 / D-07)
Currently:   nobody does it — neither the script nor the documented install path
Possible:    Agent CLI (a `bootstrap`/`doctor` step), or the runtime project
Reason:      It is a real gap today, not a relocation.
Decision:    OPEN
```

---

## Doc-vs-implementation discrepancies

Not blockers, but they affect what "current behaviour" means during review — anyone reasoning from the
upstream docs alone will be wrong on these points.

1. `docs/container-capabilities.md` §8 states "Plan mode by default on start (never bypass mode)" — the
   opposite of the implemented `bypass` default (F38).
2. `--sync` is missing from README's daily-use command list and from the capabilities command table.
3. `--init` is documented as "five quick questions"; the script asks six constrained questions (permission
   mode is undocumented) plus three free-form prompts (F49).
4. The README's `--init` staged-file list omits `.devcontainer/devcontainer.env.example`, and never names the
   two `.gitignore` entries actually written.
5. README references `ghcr.io/petrixh/claude-container`; the script and CI use
   `ghcr.io/sebastiankuehnau/claude-container`.
6. Variant counts disagree across docs (three / four / five) — CI builds four.
7. Base-image contents disagree (Node 20 vs 22; Java 21 vs 25).
8. The `task-spec` skill is documented with an instruction to run it, but does not exist in the repo (F58).
9. The "host verification checklist" cited in the script's own comment does not exist.
10. `.claude/hooks/claude-md-sync.sh` and `.claude/settings.json` are documented in the upstream `CLAUDE.md`
    but absent from the repo.
11. The install snippet omits `mkdir -p ~/.local/bin`, and no documentation covers who creates the
    `~/.claude-container` state (D-07).
12. `--done --force` is shown with the modifier before the branch while the modifier table says "after" —
    harmless, since the parse loops accept either (F64).

---

## Open questions

Consolidated. Ordered so that earlier answers constrain later ones.

### Decide first — these constrain the module layout
1. **Distribution:** single curl'd file, or a multi-file `lib/` install? Determines whether F07 survives and
   whether `lib/*.sh` is even reachable at run time.
2. **Runtime model:** Dev Containers, Docker Sandboxes, both behind an interface, or something else? See
   [`runtime-discussion.md`](./runtime-discussion.md). Item 1 in
   [Container runtime requirements](#container-runtime-requirements) (host-path-identical mounts) may rule
   candidates out outright.
3. **Isolation primitive:** are git worktrees the mechanism, or one option among several (clone-per-task,
   copy-into-environment, remote checkout)? F34 exists only because of worktrees.
4. **Agent neutrality:** is the launched agent pluggable (F39), and how do agent-specific concepts such as
   permission modes generalise (F38)?
5. **Session model:** keep `--rm` disposable containers with fully derived state, or introduce persistent
   sessions with explicit state (F37, [Current state handling](#current-state-handling))? Determines how much
   of `session.sh` is new code.

### CLI and UX
6. Subcommands (`agent-task start|shell|sync|done|init`) or flag-modes (F08, F64)?
7. Split the overloaded `--force` (F10)?
8. Add `--version` (F65), `--dry-run` (F30), `--json` (F63), and a documented exit-code contract (F47, F63)?
9. Is there a `list` / `status` command? Nothing today can enumerate tasks
   ([Current state handling](#current-state-handling)).
10. Should branch names be validated (D-06, D-03)?

### Naming and layout
11. Collision-free naming, or accept D-03? Any change is breaking for running containers.
12. Worktree layout: sibling `-worktrees` dir (F17) or a central per-user location?
13. Project identity: mutable directory name / env file / config `.name` (F14), or something stable?
14. Are paths with spaces supported (D-02) or explicitly rejected?

### Configuration
15. Config file name, location, and format — is `.devcontainer/claude-task.json` still right if the runtime
    is not a devcontainer (F21)?
16. Schema validation and a real meaning for `version` (F22, D-20)?
17. Is branch-local config (read from the worktree) intended, given it lets a branch change its own image and
    firewall (F01)?
18. Collapse the hardcoded env forwards into `passthroughEnv` (F35)?
19. Generalise caches beyond Maven (F33) and test commands beyond Maven/Gradle (F43)?

### Sync pipeline
20. Configurable base branch (D-12) and rebase-vs-merge policy?
21. Must the pipeline run inside the container (F04)? Should it be decomposable into separate commands?
22. Forge-neutrality beyond `gh` (F46)?
23. Should force-push require explicit opt-in (F45)?
24. Does the `tasks/` strip belong here at all (F44)?

### Ownership
25. Each block in [Functionality ownership questions](#functionality-ownership-questions) — nine
    decisions, all OPEN.
26. Who owns host-state bootstrap (D-07)?

### Testing and quality
27. What is the minimum test bar for a capability to be considered migrated?
28. `shellcheck` + `bash -n` in CI from the first commit?
29. Is stock macOS `/bin/bash` 3.2 a supported interpreter, or is bash ≥ 4 (or 5) assumed?
30. Which GNU-vs-BSD tool assumptions are acceptable (D-04)?
31. Is a Docker-requiring CI tier acceptable, or must CI stay Docker-free (which is feasible for the majority
    of the suite)?

---

## Verification log

Everything tagged **[verified]** was reproduced locally on macOS (Darwin 25.6, bash 5.3, git 2.55, jq 1.8.2)
in throwaway directories under a scratch path. **No Docker was used, no upstream repository was modified, and
all fixtures were deleted afterwards.**

| Check | Method | Result |
|---|---|---|
| `sanitize` collisions | Extracted the function verbatim; ran a table of branch names | `feature/x`, `feature-x`, `Feature/X` → `claude-proj-feature-x`; `ümlaut` → `mlaut`; `""` → `claude-proj-` |
| `worktree_exists` with spaces | Real repo at `…/my repo`, real linked worktree, ran the script's awk expression | `NOT FOUND` for an existing worktree |
| `--init` non-interactive | Piped 10 newline-separated answers into `claude-task --init` in a fresh repo | Answers consumed in order; generated JSON matched the answers exactly |
| `--init` failure on ignored paths | Same run, with a global `core.excludesFile` ignoring `.claude` | Exit 1 after writing all 10 files; 8 of 9 paths staged; summary never printed |
| `--init` re-run guard | Ran `--init` again with `</dev/null` | Refused: "Project already initialized", exit 1 |
| Rendered Dockerfile | Inspected the generated file | `FROM ghcr.io/sebastiankuehnau/claude-container:latest`; regex `21\.[0-9.]+-zulu`; `sdk install gradle` |
| `read` at EOF under `set -e` | Isolated harness, avoiding `&&`/`||` suspension of `set -e` | EOF yields the default and continues — piping short answer lists is safe |
| Branch-name injection | `git branch "has'quote"`; simulated the `:581` interpolation | Git accepts the quote; the injected `echo INJECTED` executed |
| Host tool availability | `command -v` for each dependency | `sha256sum` at `/sbin/sha256sum`; `readlink -f` works; `sed` is BSD; `timeout` absent |
| No tests upstream | Full repo tree via the GitHub trees API + reading `build.yml` | No `tests/`, no `*.bats`, no shellcheck; CI builds images only |
