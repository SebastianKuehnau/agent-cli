# Issue tracker

Issues for this repo live in **GitHub Issues** at `SebastianKuehnau/agent-cli`.

## How skills should interact with it

Use the `gh` CLI to read, create, and update issues:

- `gh issue list` / `gh issue view <n>` — read
- `gh issue create` — file a new issue
- `gh issue comment <n>` / `gh issue edit <n>` — update

Reference issues by number (e.g. `#7`) in commits and docs, matching the convention already used in
`CLAUDE.md` (issues #3, #4, #6, #7, #8 are cited by number in "Project status").

## PRs as a request surface

- **Enabled**: no

Pull requests are not treated as an issue-equivalent request surface (e.g. `triage`-style skills
should not pull open PRs into the same queue as issues). Flip this to `yes` here if that's wanted later.
