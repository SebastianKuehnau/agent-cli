# Backlog

Ideas for future phases. Nothing here is implemented or scheduled.

## Apply changed Sandbox Kit to existing sandbox

**Status:** Backlog / not implemented.

When `.sbx/kit/spec.yaml` changes after a sandbox has already been created, `agent-task` currently
reuses that sandbox unchanged — the kit edit has no effect until the sandbox is recreated by hand.
Agent CLI should detect that the effective Sandbox Kit has changed and apply it.

Investigate using:

```bash
sbx kit add <sandbox-name> .sbx/kit
```

to update the existing sandbox rather than requiring the user to manually recreate it.

### Questions to resolve before implementation

* How should Agent CLI detect that `spec.yaml` changed?
* Should the kit content be hashed?
* Where should the last applied hash be stored without introducing Agent CLI session state?
* Can the currently applied kit/hash be discovered through Docker Sandboxes instead?
* What happens when `sbx kit add` is unavailable because the installed Docker Sandboxes version is
  too old?
* What happens if `sbx kit add` fails?
* Should Agent CLI ask before restarting/recreating an active sandbox?
* Since `sbx kit add` is experimental, how much should Agent CLI depend on its current CLI contract?
