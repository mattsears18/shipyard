# Worker-preamble fragment — Worktree-reaped escape hatch + incremental progress posting

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode performs git/gh **writes** (every mode does) so it can detect a mid-run worktree reap before a write, and — for investigation-heavy modes — post findings before the first write so a reap doesn't destroy them. The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "Worktree-reaped escape hatch"` and `worker-preamble § "Incremental progress posting"`).

## Worktree-reaped escape hatch

The orchestrator's end-of-session cleanup reaps `.claude/worktrees/agent-*` directories. It liveness-checks the lock-holding PID before reaping, but defense in depth: an agent whose worktree IS reaped mid-run must NOT silently fall through to operating in the primary checkout.

**Bash-tool isolation — the gotcha that makes the naïve pattern wrong.** Each `Bash` tool call spawns a fresh shell. Variables you set in one call (including `export`-ed ones) **do not survive** into the next call — the harness does not share shell state across invocations. A pattern that reads "save once at session start, check before each write" works fine in an interactive terminal but trips the very guard it's meant to enforce when run through the Bash tool: the first write-class call after some intervening read-only calls finds `$WORKTREE_PATH` empty, the `! -d ""` check is true, and the worker emits a false-positive `reaped:` exit on its first commit ([#322](https://github.com/mattsears18/shipyard/issues/322)).

**Re-derive `WORKTREE_PATH` at the top of every write-class Bash call.** One extra line per call, no cross-call state assumption. Apply before every `git commit`, `git push`, `gh pr create`, `gh pr merge`, `gh issue edit`, `gh pr edit`, `gh pr comment`, `gh issue comment`, and any other call that mutates the repo or the GitHub-side state:

```bash
# Top of every write-class Bash call — re-derive inside the call, don't rely on prior state.
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ ! -d "$WORKTREE_PATH" ] || [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --format='%H' 2>/dev/null | head -c 12)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi
# ... actual write call here, e.g.:
# git commit -m "..."
```

The re-derivation is cheap (a single `git rev-parse` against the cwd) and self-correcting: if your cwd is still inside the worktree, `WORKTREE_PATH` resolves to the same path the orchestrator handed you; if the worktree has been reaped, `git rev-parse` errors and `WORKTREE_PATH` is empty, which the `! -d "$WORKTREE_PATH"` check catches. The second arm of the OR (`git rev-parse --show-toplevel != $WORKTREE_PATH`) is the redundant-but-cheap belt to the suspenders — if `cd` ever drifted to a sibling worktree or the primary checkout, the toplevel won't match the just-derived path and the same `reaped:` bail fires.

**Why not "save once, reuse via `export`."** The Bash tool does not run your calls inside a persistent shell session — there's no parent process whose environment survives across tool-result boundaries. `export WORKTREE_PATH=...` in call N does not make `$WORKTREE_PATH` readable in call N+1. The same constraint applies to `set -o`, `cd`, shell aliases, and shopt — every Bash tool call is hermetic. Re-deriving at the top of each write-class call is the only pattern that holds across the tool's actual isolation semantics. (For read-only calls — `git log`, `gh issue view`, `gh pr list`, etc. — you can skip the guard; the cost of a misread is wasted tokens, not a corrupt write.)

The `reaped:` prefix is load-bearing and intentionally distinct from `blocked:`: the orchestrator's step A reconcile parses it as a **retryable** outcome — it re-enqueues the issue for a fresh dispatch rather than applying any block label. The `blocked:` prefix is reserved for deterministic failures (ambiguous scope, cannot reproduce, refuses) where retrying would produce the same result; reconcile then classifies the bail per [#521](https://github.com/mattsears18/shipyard/issues/521) (refuse → `needs-human-review`, dependency-wait → no label, subjective → `blocked:agent-soft`). A mid-run reap is external-infrastructure noise, not a worker logic failure. Do NOT try to `cd` to a different worktree, recreate your worktree, or operate in the primary checkout — exit immediately.

## Incremental progress posting (investigation-heavy work)

For workers whose job involves a multi-step investigation before any commit lands (scope pre-flight analysis, diagnostic investigation, fix-checks root-cause search), a worktree reap mid-run destroys the findings before they can be communicated. To prevent silent value loss, **post investigation findings to the originating issue before attempting any git/gh write**:

```bash
# After reaching a diagnostic conclusion but BEFORE git commit / git push / gh pr create:
gh issue comment <N> --repo <owner/repo> --body "$(cat <<'EOF'
<!-- shipyard-worker-progress -->
**Investigation finding (pre-push):** <your diagnostic summary here — file paths, line numbers, root cause, rejected hypotheses>

This comment is posted before the final push so findings survive a mid-run worktree reap.
EOF
)"
```

**When to post a progress comment.** Post one if BOTH are true:
1. You have produced a concrete finding that isn't yet in the remote (uncommitted work, diagnostic conclusion, scope decision).
2. The finding would be permanently lost if your worktree were reaped in the next 30 seconds.

**What the comment should contain.** Exactly what the orchestrator would have had to transcribe manually if your run was interrupted: file paths, line numbers, rejected alternatives, root-cause hypothesis. Not a progress update ("working on it") — findings only.

**When NOT to post.** If you're about to push a commit that encodes the finding, the commit is the durable record — skip the comment. If the issue is a typo-fix and there are no intermediate findings, skip. The goal is to prevent loss, not to narrate every step.

The `<!-- shipyard-worker-progress -->` sentinel lets the orchestrator identify and summarize these comments without re-reading the entire thread.
