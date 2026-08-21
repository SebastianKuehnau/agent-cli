# 0001 — Presets are a URL lookup, not kit composition

- **Status:** accepted
- **Date:** 2026-08-21
- **Measured against:** Docker Sandboxes `sbx` v0.39.0 (`def8cb0523a77e757bdd6ef52b459fe374f3783e`)

## Context

`task-agent --init` scaffolds a project kit. We wanted a way to start a project from a *flavoured*
kit — a Vaadin project should begin with the Vaadin network allowlist, the Vaadin skills plugin and
the host-Ollama wiring already in place, while a plain project starts from a generic kit.

The obvious shape is layering: a shared base kit plus a small project overlay. The kit schema appears
to support exactly that. It does not.

`sbx kit validate` on a `spec.yaml` declaring `mixins:` succeeds — and warns:

```
WARN: field "mixins" is accepted but not yet implemented:
      mixin composition is accepted in the schema but not yet applied by the runtime
```

So kit-level composition is a schema stub. The only composition the runtime offers is repeating
`--kit` on `sbx create`, which layers kits in argv, not in the artifact.

Three further facts constrain the alternatives:

- **The release bundle has no filesystem.** `scripts/build-bundle.sh` concatenates `lib/` and
  `bin/task-agent` into one file. A bundle install therefore cannot read preset files shipped
  alongside it; a preset must either be fetched over the network or be embedded in the script text.
- **There is no separate repository to publish to.** `--init` used to download its kit from
  `SebastianKuehnau/claude-sandboxed`, which has since been renamed to `vaadin-claude-sandbox` — so
  that URL worked only through GitHub's rename redirect — and is being retired. That kit was also
  Vaadin-specific despite being the only, default kit.
- **A preset is a starting value, not a dependency.** `--init` already writes a copy of the spec into
  the project, which the project then owns and edits. Nothing reads the source again afterwards.

## Decision

A preset is a **name that resolves to a URL**. `lib/scaffold.sh` holds a lookup table mapping preset
names to raw URLs at `presets/<name>/spec.yaml` **in this repository's default branch**.
`task-agent --init [PRESET]` downloads that one file, exactly as `--init` already did.

Publishing from this repository means the authored file and the downloaded file are the same file.
There is no copy step and therefore nothing to drift.

`generic` is a newly written, genuinely generic preset. Vaadin moved to `--init vaadin`. This changes
what `--init` with no argument produces, which is accepted deliberately: a default kit that opens
Vaadin hosts is harder to justify than one explicit word.

`TASK_AGENT_KIT_URL` keeps its meaning and takes precedence over any preset, so an arbitrary spec can
still be used without touching the table.

agent-cli continues to pass **exactly one** `--kit` to `sbx`.

## Consequences

- **One kit, one digest.** `scaffold_kit_hash` keeps digesting a single directory, so the
  applied-kit cache from issue #7 needs no change. Layered kits would have forced the digest — and the
  invariant in architectural rule 1 that keeps it a cache — to span two trees, one of which lives
  outside the repository.
- **Every preset is self-contained, and combinations are duplicated.** A Vaadin-plus-Playwright
  environment is one preset containing both, not two composed presets. This is acceptable only because
  a preset is a starting value: an over-broad preset costs the user a few deleted lines, while a
  too-narrow one costs them research they cannot do from memory (see the Playwright download hosts in
  `presets/vaadin/spec.yaml`).
- **`--init` needs network.** It already did.
- **Presets version independently of task-agent, but live in its repository.** Publishing a preset is a
  push to the default branch, with no release. The price is that a released `task-agent` names preset
  URLs on `main`, so deleting or renaming a preset file breaks `--init` for installed versions.
- **Installs from before this change keep working only while the old redirect lives.** They hardcode
  the `claude-sandboxed` URL. `--update` moves them onto presets; until then, retiring that repository
  outright breaks their `--init`.
- **No pinning is needed.** Because `--init` writes an owned copy, a preset edited upstream changes
  nothing for existing projects.

## Do not "fix" this

If a future reader sees `mixins:` in the kit schema and concludes that the layered design was simply
missed: re-run `sbx kit validate` on a spec that uses it and read the warning. Reintroduce composition
only after that warning is gone, and then revisit the digest invariant first.
