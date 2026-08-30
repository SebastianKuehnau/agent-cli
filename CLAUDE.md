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

Issue #18 added the transcript rescue. It adds no flag and no argument: it is a step inside the two
teardown paths that already existed. A standalone `--rescue` was considered and deliberately left out
— see "Scope discipline".

`--init` gained an optional **preset** argument by a further explicit decision — see "How presets
work" below. That decision covers the preset argument and nothing else: it is not licence to start
forwarding `sbx` options. `task-agent` passes none, deliberately
(`docs/adr/0002-ports-and-env-stay-outside-task-agent.md`).

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
lib/scaffold.sh      `--init`, the preset table and the kit digest: create .sbx/kit, download
                     spec.yaml atomically, substitute the __PROJECT__ placeholder
lib/kit.sh           the applied-Sandbox-Kit cache under .git/agent-cli/kit (a cache, not state)
lib/transcripts.sh   rescuing the agent's *.jsonl session transcripts out of a sandbox to the
                     host, immediately before the sandbox is destroyed
lib/session.sh       orchestration of `task-agent <branch>` and `task-agent --done <branch>`
lib/selfupdate.sh    `--update` only: version probe, then install the latest release in place
scripts/build-bundle.sh  dev-time only: concatenates bin/ + lib/ into the single-file release
                         artifact `.github/workflows/publish.yml` publishes; not runtime code
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
9. **agent-cli does not manage Claude authentication.** No copying of credentials into or out of a
   sandbox, no `ANTHROPIC_API_KEY` forwarding. That is Docker Sandboxes' responsibility.

   The rule targets F32 of the predecessor, which bind-mounted `~/.claude-container/{claude,claude.json}`
   into the container to carry credentials. It is deliberately about **credentials**, not about
   `~/.claude` as a directory: rescuing the agent's *transcripts* out of a sandbox before it is
   destroyed is a separate, permitted concern (`lib/transcripts.sh`, issue #18). It runs in the
   opposite direction — sandbox to host — copies `*.jsonl` only, and never touches
   `.credentials.json`. `docs/current-script-analysis.md` lists "Agent auth / history" and
   "Agent conversation state" as two separate rows for exactly this reason.
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
- **stdin is neutralised for the whole suite**, in `tests/helpers/common.bash` (issue #14). bats hands
  a test the terminal it was started from, so without this a suite run from a terminal blocks in
  `confirm` the moment a test reaches the changed-kit prompt, while the same test passes in CI. No
  test may therefore rely on inheriting a terminal: exercise a prompt by feeding it explicitly (see
  `tests/unit/logging.bats`), and drive the recreate path with `TASK_AGENT_KIT_RECREATE=yes`.
  Reproducing the hang needs a pty that stays open — `script` closes its master side, so `read` gets
  EOF and the test passes.
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
`--submit`, `--sync`, `--status`, `--shell`, `--plan`, `--force`, `--rebuild`, `--rescue`; pull requests
and GitHub integration; branch deletion;
test or build execution; task specs and the `task-spec` skill; skill installation; Dev Containers; raw
`docker run`; project configuration files (`.sbxenv.yaml` included); custom template images; **any
`sbx` option passthrough** (`--publish`, `--env`, `--env-file`, `--memory`, `--cpus`, `--template`,
`--static-mcp`); and any generic `runtime_*` abstraction (Docker Sandboxes is the only runtime, and a
one-implementation interface is unverifiable).

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

## How the agent's transcripts get out of a sandbox

Every sandbox has its own `~/.claude`, so an agent's session transcripts
(`projects/<slug>/<session-id>.jsonl`) exist only there. Claude Code's `/insights` builds its report
by scanning the **host's** `$CLAUDE_CONFIG_DIR/projects`, so without help every session run through
`task-agent` is invisible to it — the sandbox is exactly where the transcripts are, and exactly what
`--done` deletes.

`lib/transcripts.sh` has one entry point, `transcripts_rescue <sandbox>`, called immediately **before**
`sandbox_remove` at both places that destroy a sandbox: `session_done` and `session_sync_kit`.

- `sbx exec` runs `find -mindepth 2 -maxdepth 2 -name '*.jsonl'` over
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`. Depth 2 matches `projects/<slug>/<session>.jsonl` and
  skips the subdirectories (`memory/`, `tool-results/`, subagent transcripts), which `/insights` does
  not read either. The config directory is resolved **inside** the sandbox, because a kit can set
  `CLAUDE_CONFIG_DIR` there.
- One `sbx cp` per file, into a staging directory next to the destination and then `mv` into place.
  Atomic for the same reason `kit_cache_write` is: a truncated `.jsonl` in the user's
  `~/.claude/projects` is worse than a missing one, because `/insights` reads whatever is there.
- The host slug is taken from the in-sandbox path verbatim, never re-derived. It matches anyway —
  `sbx` mounts every workspace at the same absolute path it has on the host — and re-deriving it would
  mean reimplementing Claude Code's path slugging.

Four rules hold this together:

1. **A rescue never blocks teardown.** It reports and returns non-zero; both call sites discard that.
   A broken rescue must never be able to leave an undeletable sandbox behind.
2. **All projects in the sandbox are rescued, not just the task's own slug.** The agent can work
   outside its worktree, and those transcripts vanish just the same.
3. **Every file is copied every time; there is no skip-if-unchanged check.** `sbx rm` destroys the
   container filesystem, so a recreated sandbox starts with an empty `projects/` and the same
   transcript is never rescued twice. A size-or-mtime comparison would also rest on `sbx cp`
   preserving mtime, which `sbx cp --help` does not promise.
4. **An invalid `TASK_AGENT_RESCUE_TRANSCRIPTS` fails, and fails early.** It is validated at the top of
   `session_start` and `session_done`, before anything is created or removed, so a typo costs a re-run
   rather than a half-torn-down task. Values are `yes` (the default) and `no`, matching
   `TASK_AGENT_KIT_RECREATE`'s vocabulary and its refusal to read a typo as "off".

Why this happens at teardown and not periodically, and why there is no lifecycle event to hook, is in
[ADR 0003](docs/adr/0003-rescue-transcripts-at-teardown-only.md). That ADR also records the known
limit: a `sbx prune`, `sbx reset` or `sbx rm` run by hand destroys transcripts without `task-agent`
ever being involved.

## How `--update` and the release bundle fit together

`bin/task-agent` + `lib/*.sh` is the only source layout and stays that way — it is what makes every
module unit-testable. `scripts/build-bundle.sh` is a release-time build step, not a second
implementation: it concatenates the lib files and `bin/task-agent` (minus its `source
"$AGENT_LIB_DIR/..."` lines) into one self-contained file with no text surgery beyond dropping those
lines. `.github/workflows/publish.yml` runs it for every release and publishes the result as
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
sandbox was recreated by hand. Now `session_start` compares the kit against the one the sandbox was
built from and offers to rebuild it when they differ.

**Applying a kit means recreating the sandbox, and `sbx kit add` is not usable for this.** That was
established by running `tests/spike/sandbox-kit.bats` against a real sbx, and it is the reason the
implementation looks the way it does:

- `sbx kit add <name> <kit-dir>` recreates the sandbox "with the new kit **appended to its original
  kit list**" (its own `--help`). Handing it the project's own, already-applied kit therefore fails
  with `compose: duplicate kit name "<name>"`. The kit's name identifies the project's kit and does not
  change when its contents do, so this is the normal case, not an edge case — `sbx kit add` cannot
  express "this kit changed".
- There is nothing else to reach for: `sbx kit` offers `add`, `inspect`, `pack`, `pull`, `push` and
  `validate`. No replace, no remove.
- Applying a kit recreates the sandbox regardless. So `sandbox_remove` + `sandbox_create` is not a
  workaround; it is the same operation via commands the spike verifies.

One real trade-off comes with that. `sbx kit add`'s swap preserves kit-owned volumes — explicitly
including agent session state — whereas `sbx rm` does not, so recreating loses the agent's session
inside that sandbox. Getting the preserving behaviour would mean rewriting the kit's `name` per
version so it appends as a *new* kit, which means YAML surgery without a parser and a kit list that
grows forever, with the old kit's settings still composed in — i.e. "add a mixin", not "apply the
current kit". That is why the loss is accepted and the user is asked instead.

Do not reintroduce a `sbx kit add` call path without re-running that spike first. Note it also refuses
sandboxes created before its recreate feature shipped, so it could never have been depended on
unconditionally.

Three pieces, deliberately separate:

- `scaffold_kit_hash` (`lib/scaffold.sh`) digests the **whole** `.sbx/kit` directory — every file's
  path, executable bit and content, in `LC_ALL=C` order. Paths are in the digest so a pure rename
  counts as a change; the digest is independent of where the checkout lives, so moving a repository
  does not look like a kit change.
- `lib/kit.sh` remembers the digest a sandbox was built from, per sandbox. See architectural rule 1
  for the invariant that keeps this a cache rather than session state.
- `session_sync_kit` and `session_kit_should_recreate` (`lib/session.sh`) decide and act.

Because recreating destroys anything living only inside the container, it is never silent. The default
is to ask (`confirm` in `lib/logging.sh`), and `TASK_AGENT_KIT_RECREATE` overrides that with `yes` or
`no`. Three rules hold that together:

1. **No terminal means no.** In `ask` mode with a non-TTY stdin (a script, CI), `task-agent` reports
   the change and leaves the sandbox alone. Consent cannot be inferred from silence, and a piped
   "yes" is not a terminal either — `TASK_AGENT_KIT_RECREATE=yes` is the supported way to say yes
   non-interactively.
2. **A skip is never recorded.** Declining, `no`, and the non-TTY path all leave the digest untouched,
   so the next run offers again rather than treating the old kit as current.
3. **An invalid `TASK_AGENT_KIT_RECREATE` fails.** Treating a typo as `no` would silently switch kit
   updates off.

A sandbox with **no** cache entry — created by an older task-agent, or whose entry was lost — is
*adopted*: the current digest is recorded and nothing is rebuilt. Rebuilding would destroy a sandbox
nobody asked us to touch (every existing sandbox, on the first run after upgrading), and the cost of
adopting is missing at most one kit change — exactly the pre-issue-#7 behaviour. Do not "improve" this
into a rebuild. `--done` drops the entry, otherwise it would later claim that a freshly created
sandbox of the same name already has that kit.

`tests/spike/sandbox-kit.bats` is the only place the real CLI contract is exercised, and it skips
itself when sbx is unavailable. A green `tests/run-tests.sh` therefore says nothing about whether
Docker Sandboxes still behaves as described above.

## How presets work

`--init [PRESET]` decides what the project kit starts out containing. A preset is a **name that
resolves to a URL** — the table is `scaffold_preset_url` in `lib/scaffold.sh` — and `--init` downloads
that one file, exactly as it always did. `TASK_AGENT_KIT_URL` still wins over any preset, and warns
when it silently overrides an explicitly named one.

Three things about this are load-bearing.

**Presets are published from this repository, and every one of them lives at
`presets/<name>/spec.yaml`.** `TASK_AGENT_PRESET_BASE_URL` defaults to this repo's raw default branch,
so the authored file and the downloaded file are the same file — there is no copy step and nothing can
drift. `presets/` is therefore not sample material: editing a file in it changes what `--init` hands
out, on the next push, for every installed version.

`--init` used to download from a separate repository (`claude-sandboxed`, since renamed to
`vaadin-claude-sandbox`, now being retired) whose kit was **Vaadin-specific despite being the only,
default kit**. `generic` is a new file and is genuinely generic; Vaadin is `--init vaadin`. A test
asserts `presets/generic/spec.yaml` never mentions Vaadin again.

**Kit composition does not exist, so presets do not compose.** The kit schema accepts a `mixins:` field
and `sbx kit validate` warns that the runtime does not apply it. agent-cli therefore passes exactly one
`--kit`, and a combined environment is one preset containing everything rather than two composed ones.
The full reasoning, including why layering would have broken the single-tree kit digest, is in
`docs/adr/0001-presets-as-url-lookup-not-kit-composition.md`. Do not reintroduce `mixins` without
re-running that validation first.

**The `__PROJECT__` substitution is opt-in and byte-preserving.** `scaffold_init` replaces the sentinel
only when the downloaded spec actually contains it, so a spec without it is moved into place untouched
— which is what keeps `--init` a byte-for-byte copy for every spec that does not ask for otherwise. The
replacement value comes from `naming_project_id`, whose output is `[a-z0-9-]` only; that is what makes a
plain `sed "s///"` safe here with no quoting. The substitution is **cosmetic**: the kit name shows up in
`sbx kit inspect`, while per-sandbox policy rules are labelled from the *sandbox* name, so a wrong kit
name changes no behaviour.

`tests/unit/scaffold.bats` guards the contract between the shipped presets and the code: every name in
`scaffold_preset_url` must have a file, every file must use the sentinel and declare schema version 2,
and `TASK_AGENT_PRESET_BASE_URL` must point at this repository. Add a preset by adding both the table
entry and the file — the test fails if you add only one.

## No custom template image

agent-cli passes no `-t`, and there is no Dockerfile here. That is a measured decision, not an
omission: `docker/sandbox-templates:claude-code` already ships OpenJDK 25.0.3, Node 22, npm, Python
3.14, a Docker daemon, and passwordless `sudo` for the `agent` user. `mvn` is absent, but Vaadin
projects carry the Maven wrapper and `repo.maven.apache.org` is in the kit's allowlist. SDKMAN is
absent, so a `sdk install java …` line in a kit is dead code — it cannot work, and `|| true` only hides
that.

The one thing genuinely missing is browser binaries, which is why the `vaadin` preset installs them at
setup time instead. Reach for a custom image only when that download cost per sandbox becomes the
problem, and note it would require a `-t` passthrough, which "Scope discipline" forbids.

## How the version and `--update`'s version check work

`lib/version.sh`'s `TASK_AGENT_VERSION` is the only place the version is written down, and
`task-agent --version` prints it. It is a plain constant rather than something derived from git: the
release bundle has no repository to ask, and asking git would make an installed bundle's version
depend on whichever directory it was run from.

`.github/workflows/publish.yml` refuses to publish a tag that does not match `TASK_AGENT_VERSION`.
That check is load-bearing, not hygiene — it is the only thing that makes a version comparison
against the latest release mean anything. The constant belongs in the commit that is tagged, which is
why `prepare-release.yml` writes it and tags it in one step — see "How a release is cut" below.

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

## How a release is cut

Run **Prepare release** from the Actions tab and pick `patch`, `minor` or `major`. That is the whole
procedure; nothing is edited or tagged by hand.

Three workflow files, and the split between them is deliberate:

- `prepare-release.yml` (`workflow_dispatch`) — runs CI, computes the next version from
  `lib/version.sh`, rewrites the constant, commits, tags, and pushes branch and tag with
  `git push --atomic`. Then it calls `publish.yml`.
- `publish.yml` (`workflow_call`, input `tag`) — checks out **the tag**, verifies it against
  `TASK_AGENT_VERSION`, builds the bundle and creates the release with both assets.
- `release.yml` (`on: push` of `v*`) — a thin caller of `publish.yml` for a tag pushed by hand, which
  stays supported.

Four things about this are load-bearing.

**The version is computed, never typed.** `patch`/`minor`/`major` is applied to what `lib/version.sh`
declares, and an existing tag is refused. A release can therefore neither skip a number nor reuse one.

**The bump and the tag are one act, pushed atomically.** Separating them is what produced v0.3.1
through v0.3.3 (issue #16): three tags on commits declaring a different version, each refused by the
version guard, so no release was built at all while `--update` kept resolving v0.3.0. `--atomic` means
a tag can never arrive without the commit that declares its version.

**`prepare-release.yml` publishes inside its own run.** GitHub does not trigger `on: push` workflows
for pushes made with the default `GITHUB_TOKEN`, so its tag push does *not* start `release.yml`. That
is why publishing lives in a reusable workflow both callers share rather than in `release.yml` — a
second copy of the build is exactly how the two paths would drift. Do not "simplify" this by inlining
the build, and do not add a PAT to make the tag push trigger: a token with write access, kept fresh by
hand, is a worse dependency than one `uses:` line.

**The version guard in `publish.yml` stays, even though `prepare-release.yml` cannot violate it.**
Hand-tagging remains possible, and the guard is the only reason `--update`'s "already the latest
release" is trustworthy.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`SebastianKuehnau/agent-cli`), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. `CONTEXT.md` is the glossary — in
particular it separates **template** (an image), **kit**, **project kit** and **preset**, which are
easy to confuse. See `docs/agents/domain.md`.
