# Domain docs

## Layout

Single-context: one `CONTEXT.md` and one `docs/adr/` directory at the repo root (neither exists yet).

This repo is a single bash CLI (`bin/task-agent` + `lib/*.sh`), not a monorepo — there's no need for
a `CONTEXT-MAP.md` or per-package contexts.

## Consumer rules

- Skills that read domain context (e.g. `domain-modeling`, `codebase-design`) should read
  `CONTEXT.md` and `docs/adr/*.md` at the repo root once they exist.
- `CLAUDE.md` stays authoritative for this repo's hard architectural constraints (see its
  "Architectural rules" section); `CONTEXT.md` is for domain vocabulary and models, not a duplicate
  of those rules.
