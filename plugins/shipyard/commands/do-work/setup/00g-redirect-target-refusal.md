# Redirect-target refusal (post-relocation Bash guard)

Fragment of step **0.5** — redirect-target validation (the third post-relocation refusal trigger, alongside braced expansions and argument-position command substitutions [#1325](https://github.com/mattsears18/shipyard/issues/1325)).

**A shell redirect target outside the worktree is refused too — and the message misattributes it to git ([#1325](https://github.com/mattsears18/shipyard/issues/1325)).** This is a **third, distinct** post-relocation refusal trigger — alongside the two documented in [Claude Code's command-shape check](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation) (a braced `${VAR}` expansion; argument-position `$(cmd)` substitution) and [`dont.md`](../dont.md#post-relocation-bash-command-shape--measurements-retired-2026-09-30)'s compound-block rule (loops, pipes, `if`/`case` wrappers spanning multiple `gh`/`git` calls). A **plain, single-statement, non-git command** — no braces, no substitution, no loop — is still refused post-relocation when its only shell redirect (`>`, `>>`, `2>`) targets a path outside this worktree, e.g. a scratch dir under `$CLAUDE_JOB_DIR/tmp/` or `/tmp/`:

```bash
gh issue list --repo <owner/repo> --state open --limit 400 --json number,title,labels,assignees,author,createdAt,updatedAt > /tmp/backlog.json
```

The refusal message names "git operations" — wrong here, since `gh issue list` performs no git operation at all — so don't go hunting for a stray `git`/`-C` when this fires; the trigger is the redirect target, not the command. See `bash-refusal-triggers.md`'s [Claude Code's command-shape check](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation) for the full repro. This shape has no CI-enforced sweep the way the other two do — the guard's verification logic and its refusal-message wording are both Claude Code harness code, not present in this repository, so no PR here can narrow the guard or fix the wording; the only available mitigation is this documentation.

**Remedy — keep the redirect target inside the orchestrator worktree**, in order of preference:

1. Redirect to a worktree-local scratch file using the existing `.shipyard-*` untracked-scratch convention already in use for exactly this purpose (`.shipyard-fetched-issues.json`, `.shipyard-classified.ndjson` in [`04-backlog-divert.md`](./04-backlog-divert.md), and step 0.5's own `.shipyard-plugin-root` / `.shipyard-plugin-root-version` stashes) — these are git-ignored, cost nothing to leave behind, and are reaped with the rest of the worktree at end-of-session: `gh issue list --repo <owner/repo> ... > .shipyard-fetched-issues.json`.
2. When the data is already in the assistant's context (e.g. read back from a separate plain `Bash` call's stdout), persist it with the `Write` tool instead of a shell redirect — `Write` is not a shell command and isn't subject to this guard at all.

Never redirect to `$CLAUDE_JOB_DIR/tmp/...` or a bare `/tmp/...` path post-relocation.
