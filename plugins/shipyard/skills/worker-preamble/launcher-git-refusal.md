# A command-rewriting hook makes the isolation guard refuse plain `git` ([#1558](https://github.com/mattsears18/shipyard/issues/1558))

On-demand fragment of `shipyard:worker-preamble`. Load it the first time a `Bash` call is refused with wording like this:

> This agent is isolated in the worktree `<path>`, but this command runs `<launcher>` with a git command among its operands: what runs it, and from which directory or root, cannot be read here … Refusing to run it

The rule applies to the orchestrator too, from the moment it enters its own worktree (see `commands/do-work/dont.md` § "Post-relocation Bash blocks must be plain, single-purpose commands").

## What is happening

Some hosts install a global `PreToolUse` hook that rewrites commands before they run. The RTK token proxy (`~/.claude/RTK.md`) is the known example: it turns `git status` into `rtk git status`. Claude Code's worktree-isolation check then sees a **launcher** (`rtk`) with `git` as one of its operands. It cannot tell which directory that git runs against, so it refuses the call. This is the check working as designed, not a bug in your command.

What the refusal looks like:

- **Isolated sessions only.** The same command runs fine in a session that never entered a worktree.
- **Selective by subcommand.** The hook rewrites only some git subcommands. On the #1558 repro, `git rev-parse --short HEAD` and `git merge-base --is-ancestor` ran, but `git fetch`, `git status`, `git log`, and `git rev-list` were refused. Expect some git calls to work and others not.
- **`-C` does not help.** `git -C <worktree> log -1` is still rewritten, so it is still refused.
- **Not only git.** The hook also rewrites other tools, such as `grep` to `rtk grep`. If the rewritten command has a `git` token among its operands (for example, a search pattern containing `/usr/bin/git`), it is refused for the same reason.

## The fix: call the binary by absolute path

The hook matches the bare command name. An absolute path skips the rewrite, so the isolation check sees a plain git call it can verify:

```bash
/usr/bin/git fetch origin
```

```bash
/usr/bin/git -C /abs/path/to/your/worktree status --short
```

Both forms were verified live in an isolated worktree on a host with the RTK hook active. The mandatory `-C "$WORKTREE_PATH"` anchoring from `worker-preamble` § "Mid-session cwd anchoring" still applies. Only the binary path changes.

- **Switch after the first refusal and keep the absolute path for the rest of the dispatch.** Because the rewrite is selective, a command that ran once tells you nothing about the next subcommand. Don't retry the refused form.
- **Spec commands written as `git …` mean `/usr/bin/git …` on such a host.** Substitute the absolute path. Keep every argument exactly as the spec wrote it.
- **`/usr/bin/git` is the usual location** on macOS and most Linux distributions. If it doesn't exist, run `command -v git` as its own plain call and use the path it prints.
- **Other rewritten tools work the same way.** Use `/usr/bin/grep`, `/usr/bin/sed`, and so on when the rewritten form trips the check.
- **Scripts are not affected *by this hook*.** A shipyard helper script runs git inside its own body, where the rewrite hook never sees it — so the git calls a script makes need no absolute-path treatment. **But invoke the script by direct exec, not via `bash`** — `"$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh"`, never `bash "$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh"`. The launcher form is refused by a *different* rule ([#1566](https://github.com/mattsears18/shipyard/issues/1566), below).

## What not to do

- **Don't disable, edit, or reconfigure the hook.** It is user-global tooling outside the target repo, the same stance `ci-pitfalls.md` takes on the diff-rewriting variant of this proxy.
- **Don't route through the launcher's own passthrough** (for example, `rtk proxy git …`). That is still a launcher with `git` among its operands.
- **Don't `cd` out of your worktree** to find a place where the check doesn't fire. That breaks worktree discipline Rule 1.
- **Don't return `blocked:` over this.** The absolute-path form is a complete workaround. Return `blocked:` only if the absolute-path form is refused too, and quote the refusal text.

## Related refusal: `bash` in front of a script path ([#1566](https://github.com/mattsears18/shipyard/issues/1566))

This fragment's hook is one the *host* inserts. There is a second launcher refusal you cause yourself, with a different message and a different fix:

> …but this command runs bash in a plain command; **what it reads or is handed as shell text cannot be shown not to run git.** Refusing to run it

It fires when `bash` (or `sh`) is handed a script path the guard cannot statically resolve — an expansion rather than a spelled-out literal. Both halves are required: `bash <literal-path>` runs, and `"$VAR/scripts/x.sh"` runs, but `bash "$VAR/scripts/x.sh"` is refused.

**The fix is to drop the launcher**, not to substitute the literal — direct exec works with an expansion *and* with a literal, so it needs no judgment about which values you hold:

```
"$CLAUDE_PLUGIN_ROOT/scripts/some-script.sh" --flag
```

Every script in `plugins/shipyard/scripts/` ships executable with a shebang (CI-enforced), so this is always safe. The one exception is a script **you** wrote this dispatch with the `Write` tool — that has no exec bit, so `chmod +x <path>` as its own plain command first, then direct-exec it.

Full rule, measurement table, and carve-outs: `commands/do-work/dont.md` § "The launcher rule (#1566)".

## Related refusal: object literals in `session-state.sh update --set`

The same #1558 session also saw `session-state.sh update --set '<JSON object literal>'` refused as "too complex to verify". That one comes from the command-shape check, not from the launcher hook, and #1561 already fixed it. Assign one field per `--set`, or write the expression to a file and pass `--set-file <path>`. See `commands/do-work/session-state-file.md`.
