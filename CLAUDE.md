# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Phase 1 is implemented: `task-agent --init` and `task-agent <branch> [--base <branch>]`, backed by
Docker Sandboxes (`sbx`). The tool is **bash**, not Java — the `.idea/` directory is a leftover of the
original scaffold and is not used by the build or the tests.

`--done` and `--update` were added on top of Phase 1 by explicit decision (issues #3 and #4), and
`--version` by a further one (issue #6, which needed a version to compare), which is why none of them
are in the Phase 1 exclusion list under "Scope discipline" below. Everything else in that list still
applies.

The command was renamed from `agent-task` to `task-agent` in v0.2.0 (issue #8). The rename covers the
executable, the `TASK_AGENT_*` environment overrides, the `[task-agent]` log prefix and the release
asset. It deliberately stops there: the repository is still `agent-cli`, the internal `AGENT_*`
variable prefix still refers to agent-cli rather than to the command, and — load-bearing — the
`agent-` sandbox prefix and every derived worktree path are **unchanged**, so tasks started before the
rename are still found afterwards. Do not "finish" the rename into those.

## Intent

`agent-cli` is an orchestrator CLI for isolated AI agent development. The model is
**branch → worktree → sandbox → agent**: each task gets its own git branch, its own linked git
worktree, and its own Docker Sandbox running Claude Code.

Two analysis documents in `docs/` explain where the design comes from:

- `docs/current-script-analysis.md` — a function-by-function dissection of the predecessor tool
  `claude-task`, including the defects Phase 1 deliberately fixes.
- `docs/runtime-discussion.md` — the runtime comparison that led to Docker Sandboxes.

## Layout

```
bin/task-agent       argument parsing, dispatch, help — no git or sbx logic
lib/version.sh       TASK_AGENT_VERSION — the single source of truth for the version
lib/logging.sh       info / success / warning / error / die  (everything to stderr)
lib/naming.sh        pure naming functions: slug, short hash, worktree/sandbox/project ids
lib/git.sh           repo checks, main-root resolution, branch validation/detection/creation
lib/worktree.sh      worktree path derivation, registered-worktree lookup, create-or-reuse/remove
lib/sandbox.sh       sbx presence, existence check, argv construction, execution
lib/scaffold.sh      `--init` and the kit digest: create .sbx/kit, download spec.yaml atomically
lib/kit.sh           the applied-Sandbox-Kit cache under .git/agent-cli/kit (a cache, not state)
lib/session.sh       orchestration of `task-agent <branch>` and `task-agent --done <branch>`
lib/selfupdate.sh    `--update` only: version probe, then install the latest release in place
scripts/build-bundle.sh  dev-time only: concatenates bin/ + lib/ into the single-file release
                         artifact `.github/workflows/release.yml` publishes; not runtime code
tests/               bats suite (see below)
```

`bin/task-agent` resolves its own directory through symlinks, so a symlinked install works.

## Architectural rules

These are load-bearing. Breaking one of them breaks the tool's core guarantees.

1. **No persisted session state, with one bounded exception.** What exists is rediscovered per
   invocation from `git worktree list --porcelain` and `sbx ls -q` — never read back from a file
   agent-cli wrote earlier. Do not add a session registry, a database, a lockfile,
   `~/.agent-cli/sessions/` or equivalent.

   The one exception, added by explicit decision for issue #7, is the applied-Sandbox-Kit cache in
   `lib/kit.sh` at `<main-repo>/.git/agent-cli/kit/<sandbox>`. It exists because Docker Sandboxes
   offers no way to ask a sandbox which kit it currently has. It is permitted only as a **cache**,
   and that is what bounds the exception:

   - It may never be consulted to decide whether a branch, a worktree or a sandbox exists.
   - Losing, deleting or corrupting it may only cause the kit to be applied once more than
     necessary — never a wrong conclusion, never a failed start.

   Any new persisted data must meet the same two conditions, or it is not allowed.
2. **Identifiers are `<slug>-<hash>`, and the hash comes from the raw branch name.** This is what
   keeps `feature/foo`, `feature-foo` and `Feature/Foo` apart. Never use a bare sanitised branch name
   as a path or a sandbox name.
3. **A new branch is created from the resolved base, never from the caller's HEAD.** `--base` defaults
   to `main`. If the base does not exist locally or as `origin/<base>`, fail — do not fall back.
4. **An existing branch is reused untouched.** No reset, no rebase, no merge of the base into it.
5. **Git's registered worktree information is the source of truth.** If a branch already has a
   worktree, reuse that path even when it differs from the derived one.
6. **Parse `git worktree list --porcelain` line-oriented, taking the whole remainder of the line as
   the value.** Splitting on whitespace breaks every path containing a space.
7. **External commands are invoked through bash arrays**, never by interpolating branch names or
   paths into a shell string. `lib/sandbox.sh` separates argv construction from execution so the argv
   can be asserted element by element in tests.
8. **`--clone` is never passed to `sbx`.** It would run the agent on an in-container clone, breaking
   the guarantee that edits and commits are immediately visible on the host.
9. **agent-cli does not manage Claude authentication.** No `~/.claude` copying, no `ANTHROPIC_API_KEY`
   forwarding. That is Docker Sandboxes' responsibility.
10. **Every path handed to `sbx` must be the *physical* path.** Git canonicalises paths, so a linked
    worktree's `.git` pointer always names a physical path. Mounting a symlinked alias instead puts
    the workspace at a path the pointer does not name, and git inside the sandbox fails with
    `fatal: not a git repository`. agent-cli gets this right for free by deriving everything from
    `git_main_repo_root` and `git worktree list`, both of which git reports physically — so never
    introduce a path from another source (`$PWD`, an argument, `mktemp`) without canonicalising it
    with `cd -P … && pwd`.

## How the linked worktree works inside the sandbox

A linked worktree's `.git` is a *file* containing an absolute `gitdir:` path into the main
repository's metadata, and that metadata directory's `commondir` points back again. Neither target
lives under the worktree.

`sbx` mounts every workspace **at the same absolute path it has on the host**, so agent-cli simply
passes two workspaces — the worktree, and the main repository's `.git` directory — and both pointers
resolve unchanged. No path rewriting, no clone, no copy.

`tests/spike/sandbox-worktree.bats` exists specifically to keep this assumption honest.

## Dependencies

Runtime: `bash`, `git`, `curl`, `sbx`. Nothing else — no `jq`, no Node, no `docker` CLI, no `gh`.
`shasum` (macOS, via perl) or `sha256sum` is used for the short hash; one of the two is always present.

Development only: `bats-core` for the tests and, optionally, `shellcheck`.

## Testing

Tests are part of the implementation, not a follow-up. Every capability has automated tests.

```bash
tests/run-tests.sh                     # unit + integration (the default)
tests/run-tests.sh unit
tests/run-tests.sh integration
tests/run-tests.sh spike               # real Docker Sandboxes; auto-skips without sbx
tests/run-tests.sh all

TASK_AGENT_NETWORK_TESTS=1 tests/run-tests.sh unit   # also hits the real kit URL

shellcheck -x -s bash bin/task-agent lib/*.sh
```

Conventions:

- Git is **never** mocked. Integration tests build real temporary repositories, and remote behaviour
  uses local bare repositories as `origin` — no GitHub, no network.
- `sbx` **is** faked, via `make_fake_sbx` in `tests/helpers/common.bash`, which puts a recording stub
  earlier on `PATH`. It logs one line per argument so argument boundaries can be asserted.
- Assertions on constructed commands compare argv element by element (`assert_argv`), never a joined
  string.
- Tests that depend on the developer's environment must neutralise it — e.g. pass
  `-c core.excludesFile=/dev/null` when asserting on `git status`.
- **Fixture paths are canonicalised by `make_tmpdir`.** On macOS `mktemp -d` returns `/var/folders/…`,
  which is a symlink to `/private/var/folders/…`, while git reports the physical path. Never build a
  fixture path that bypasses `make_tmpdir`. To reproduce the macOS condition on Linux:

  ```bash
  mkdir -p /tmp/symroot/real && ln -sfn /tmp/symroot/real /tmp/symroot/link
  TMPDIR=/tmp/symroot/link tests/run-tests.sh
  ```

## Scope discipline

Phase 1 is intentionally small. `--done` and `--update` were added on top of it by explicit decision
(issues #3 and #4) — see [`--done`](#how---done-tears-down-a-task) below — and `--version` by another
one (issue #6). Still not implemented, and not to be added without a further explicit decision:
`--submit`, `--sync`, `--status`, `--shell`, `--plan`, `--force`, `--rebuild`; pull requests and
GitHub integration; branch deletion;
test or build execution; task specs and the `task-spec` skill; skill installation; Dev Containers; raw
`docker run`; project configuration files; and any generic `runtime_*` abstraction (Docker Sandboxes is
the only runtime, and a one-implementation interface is unverifiable).

## How `--done` tears down a task

`session_done` (`lib/session.sh`) removes the sandbox and the worktree for a branch — never the
branch itself — and treats the two removals as independent: it checks and removes each on its own,
so a worktree that was deleted by hand can never block cleanup of an orphaned sandbox, or vice versa.

Worktree removal (`worktree_remove`, `lib/worktree.sh`) deliberately never passes `--force` to
`git worktree remove`. Git already refuses when the worktree has modified or untracked files, which
is the only real hazard: because the branch is never deleted, unpushed *commits* are never at risk —
the branch ref keeps them reachable whether or not a worktree for it still exists. Do not add an
agent-cli-level `--force` for this without an explicit decision (see "Scope discipline" above);
a user who wants to override git's own refusal can already do so directly with
`git worktree remove --force`.

## How `--update` and the release bundle fit together

`bin/task-agent` + `lib/*.sh` is the only source layout and stays that way — it is what makes every
module unit-testable. `scripts/build-bundle.sh` is a release-time build step, not a second
implementation: it concatenates the lib files and `bin/task-agent` (minus its `source
"$AGENT_LIB_DIR/..."` lines) into one self-contained file with no text surgery beyond dropping those
lines. `.github/workflows/release.yml` runs it on every `v*` tag push and publishes the result as
that release's `task-agent` asset — plus an identical copy named `agent-task`, because installs from
before the rename look for that asset name and would otherwise get a 404 from `--update` instead of
the release that renames the tool. Keep publishing both.

`cmd_update` (`bin/task-agent`) tells the two supported install shapes apart by checking whether
`$AGENT_LIB_DIR` exists: if it does, this is a git checkout (or a symlink into one) and `--update` has
nothing of its own to replace, so it refuses with a `git pull` hint; if it does not, this is a
single-file bundle install and `--update` downloads the latest release over it in place
(`lib/selfupdate.sh`, mirroring `scaffold_init`'s atomic-download pattern). This is also the fix for
the original bug report (issue #5): a bundle has no `source` lines to fail on in the first place, so
it can never hit the "`lib/*.sh`: No such file or directory" crash that a single file dropped next to
a `--init`-only script could.

## How a changed Sandbox Kit reaches an existing sandbox

`.sbx/kit` is read by `sbx create`. Before issue #7, editing it afterwards had no effect until the
sandbox was recreated by hand. Now `session_start` compares the kit against the one the sandbox
already has and applies it with `sbx kit add` when they differ.

Three pieces, deliberately separate:

- `scaffold_kit_hash` (`lib/scaffold.sh`) digests the **whole** `.sbx/kit` directory — every file's
  path, executable bit and content, in `LC_ALL=C` order. Paths are in the digest so a pure rename
  counts as a change; the digest is independent of where the checkout lives, so moving a repository
  does not look like a kit change.
- `lib/kit.sh` remembers the digest last applied, per sandbox. See architectural rule 1 for the
  invariant that keeps this a cache rather than session state.
- `sandbox_apply_kit` (`lib/sandbox.sh`) is the only sbx call in the file that **returns** a failure
  instead of calling `die`.

That last point is the load-bearing one. `sbx kit add` is an *experimental* Docker Sandboxes feature:
it may be missing from an installed sbx, and its contract may change. So `session_sync_kit`
(`lib/session.sh`) warns, prints the equivalent manual command, and starts the agent anyway — a
slightly stale sandbox beats a tool that refuses to run. On that path the digest is deliberately
**not** recorded, so the next run retries instead of inheriting a false "already applied".

A sandbox with no cache entry — created by an older task-agent, or whose entry was lost — has an
unknown kit, so the kit is applied. Applying an unchanged kit is wasteful; skipping a changed one is
the bug this exists to prevent. `--done` drops the entry, otherwise it would later claim that a
freshly created sandbox of the same name already has that kit.

`tests/spike/sandbox-kit.bats` is what keeps the `sbx kit add` assumption honest — it is the only
place the real, experimental CLI contract is exercised, and it skips itself when sbx is unavailable.
A green `tests/run-tests.sh` therefore does **not** mean `sbx kit add` still works as assumed.

## How the version and `--update`'s version check work

`lib/version.sh`'s `TASK_AGENT_VERSION` is the only place the version is written down, and
`task-agent --version` prints it. It is a plain constant rather than something derived from git: the
release bundle has no repository to ask, and asking git would make an installed bundle's version
depend on whichever directory it was run from.

`.github/workflows/release.yml` refuses to publish a tag that does not match `TASK_AGENT_VERSION`.
That check is load-bearing, not hygiene — it is the only thing that makes a version comparison
against the latest release mean anything. Bump the constant in the commit you tag.

`selfupdate_latest_version` (`lib/selfupdate.sh`) resolves the latest released version from where
`https://github.com/<repo>/releases/latest` **redirects** to (`…/releases/tag/vX.Y.Z`), read off
`curl --head`'s `%{url_effective}`. Deliberately not the GitHub API: that would mean a JSON parser
(`jq` is not a dependency and must not become one) and the unauthenticated rate limit. A repository
with no releases redirects to `…/releases`, so the `v` prefix is required before a segment is
believed to be a tag.

Two decisions in `selfupdate_run` worth keeping:

- The comparison is **"differs"**, not "is newer". There is no version ordering to get wrong, and a
  deliberate rollback (a release republished at a lower version) still installs.
- If the latest version **cannot be determined**, the download is attempted anyway, with a warning.
  Refusing would turn any hiccup in the probe into a broken `--update`, whereas an unnecessary
  download is merely wasteful — and an offline machine fails at the download with its own clear
  message regardless. Do not "fix" this into a hard failure.
