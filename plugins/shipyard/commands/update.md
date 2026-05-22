---
description: Update shipyard — runs `claude plugin marketplace update shipyard` and `claude plugin update shipyard@shipyard` in order, then tells you to run `/reload-plugins` so the refreshed plugin registers.
---

# /shipyard:update

One-keystroke shipyard update. Replaces the two-step `claude plugin marketplace update shipyard` + `claude plugin update shipyard@shipyard` dance documented in the README's [Updating section](../../../README.md#updating).

Thin wrapper — no flags, no version pinning, no diff display. If those become useful later they're follow-up issues.

## What the assistant should do when this command runs

Execute the two `claude plugin` commands sequentially. **Don't swallow errors** — if either command exits non-zero, print its stderr/stdout verbatim and stop. The user can re-run the command (or run the underlying `claude plugin` commands directly) once they understand the failure.

1. **Refresh the marketplace listing.**
   ```bash
   claude plugin marketplace update shipyard
   ```
   Print the command's output as-is. If it exits non-zero, surface the error and abort — don't try to be clever about retrying or running the next step anyway.

2. **Update the installed plugin.**
   ```bash
   claude plugin update shipyard@shipyard
   ```
   Same rules — print the output, abort on non-zero exit.

3. **Tell the user to reload.** After both commands succeed, print:

   > Shipyard updated. Run `/reload-plugins` to register the refreshed slash commands, agents, and hooks. (The update command itself can't reload the plugin it's running inside of.)

## Why `/reload-plugins` isn't auto-run

A slash command can't reload the plugin it's a member of — by the time the reload would happen, the current command's process is still holding the old plugin code. The user runs `/reload-plugins` after the command returns so the harness re-scans the marketplace and picks up the new version. This is the same caveat the README's Updating section calls out.

## Related

- README [Updating section](../../../README.md#updating) — the canonical step-by-step instructions (this command is the one-keystroke shortcut).
- [`CHANGELOG.md`](../../../CHANGELOG.md) — what's in each release.
- Issue [#215](https://github.com/mattsears18/shipyard/issues/215) — this spec.
