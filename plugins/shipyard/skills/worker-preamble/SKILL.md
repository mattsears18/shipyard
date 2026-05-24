---
name: worker-preamble
description: Shared worktree-discipline + dispatch-contract preamble for every `/shipyard:do-work` worker mode (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch). Dispatch prompts in `commands/do-work.md` reference this skill instead of inlining the same ~600-char preamble five times — one source of truth for worktree isolation rules, return-contract scaffolding, and the `--label shipyard` requirement. Closes [#107](https://github.com/mattsears18/shipyard/issues/107).
---

# Worker preamble (every `/shipyard:do-work` mode)

The contract every dispatched worker — regardless of mode — operates under. The orchestrator's per-mode dispatch prompts in `commands/do-work.md` reference this skill by name (`shipyard:worker-preamble`) instead of repeating the language verbatim. Mode-specific rules (branch naming, return strings, scope-expansion rules) stay in the per-mode dispatch prompt and in the dispatched agent's per-mode file (`agents/issue-worker/<mode>.md` — loaded by the thin entry router `agents/issue-worker.md` from the `mode:` field). This file owns only the shared ground rules.

## Worktree discipline (load-bearing)

You are running inside an **isolated git worktree**. Your initial working directory is the worktree path; the user's primary checkout lives at a different path and is strictly off-limits.

Three rules, no exceptions:

1. **Never `cd` outside your worktree.** Your tools (Bash, Edit, Read, Write) inherit cwd from your worktree. The moment you `cd` to anything else — including the user's primary checkout path — subsequent git/gh commands operate on whatever git directory is at that path, which can silently corrupt the user's checkout.
2. **Never use `gh pr checkout <M>`.** That command resolves to the cwd at call time and switches whatever working tree is there. If your cwd has drifted (or the harness mis-set it), `gh pr checkout` will move the user's primary HEAD without warning. Always use `git fetch origin <branch>` followed by `git switch <branch>` — those operate on the cwd's git context predictably and won't escape it.
3. **Never `git switch` to the repo's default branch (`main` / `master` / etc.) when your work is done.** The global "switch back to main when local work is done" rule is for the user's *primary* checkout, not your isolated worktree. Parking your worktree on `[main]` locks the user's primary out of `git switch main` (git enforces one-worktree-per-branch). Leave your worktree on your work branch — the orchestrator's cleanup phase handles the rest.

## PR-creation contract

When opening a PR from any worker mode, every call **MUST** include:

```bash
gh pr create --repo <owner/repo> --label shipyard ...
```

The `shipyard` label is the orchestrator's session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it; omitting it makes the PR invisible to the orchestrator's own state machine. Add other mode-specific labels (e.g. `needs-human-review` for external-trust PRs) **alongside** `shipyard`, never as a replacement.

For issue-work mode the PR body MUST include `Closes #<N>` (case-insensitive, on its own line) so the issue auto-closes on merge. For synthetic diverts (fix-main-ci, fix-failing-prs-batch) there is no issue to close — omit the `Closes` line.

## Auto-merge + snapshot-and-return pattern

After `gh pr create` returns:

1. Arm auto-merge:
   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   ```
   If the call errors because auto-merge isn't enabled at the repo level, **don't try to enable it** — that's a repo-config decision. Note it in your return summary as `auto-merge: unavailable — needs manual merge`.

2. Snapshot the current check-rollup state with a single `gh pr view <M> --json statusCheckRollup,mergeStateStatus`. Don't `--watch` CI in any mode except **fix-checks-only**. The orchestrator's per-iteration PR triage owns failure recovery on a periodic refresh; blocking on `--watch` would tie up your agent and its concurrency slot for the full CI duration (often 5–20 min) for no gain. Categorize the snapshot:
   - All `CONCLUSION: SUCCESS` (or empty rollup, no checks configured) → `checks: green`.
   - Any `CONCLUSION: FAILURE` / `ERROR` / `TIMED_OUT` already present → `checks: failing`.
   - Otherwise (`QUEUED` / `IN_PROGRESS` / `PENDING`) → `checks: pending` (the normal case right after push).

3. Return one line in the mode-specific format the dispatching prompt specifies.

**Exception — fix-checks-only mode.** That mode is the one place you DO block on `gh pr checks <M> --watch --interval 30`, because resolving a known-failing PR is the agent's entire job. See `agents/issue-worker/fix-checks-only.md` for the full fix-loop semantics. Returning `green #<M>` from fix-checks-only mode is a load-bearing claim — the rollup must be fully `SUCCESS` at the moment of return, not "pushed and queued."

## Return-contract discipline

Every worker mode's last line is the orchestrator's only signal of outcome. The valid terminal strings are mode-specific (see the dispatching prompt for the exact set), but two universal rules apply:

- **No narrative status updates.** Strings like `"waiting for monitor"`, `"shard 2 still running"`, `"unit tests pass, awaiting E2E"`, `"routine progress"` are contract violations — the agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging stale state. Either return one of the documented terminal strings, or keep the foreground bash call alive (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism) until you have one to return.
- **`blocked: <reason>` is always available.** If you hit a real blocker before push (ambiguous scope, can't reproduce, conflict needs human judgment, 3-attempt fix-loop cap hit), return `blocked: <reason>` and exit. Don't burn the session on one issue.

## Stop background processes before returning

If your worker spawned anything that lives **outside** the foreground tool-call lifecycle — a `Monitor` sub-task watching CI, a `Bash` call with `run_in_background: true` (e.g. a long-tail `gh pr checks --watch` you backgrounded so you could keep working in parallel), a `TaskCreate` sub-Agent — **stop it explicitly before you emit your terminal return string**. These processes belong to your session's background pool, not your "main turn," so the harness does not auto-reap them when your final assistant message lands. Each one will keep firing notifications (`<result>Still waiting (check 8)...</result>`, `<result>All historical background tasks have completed...</result>`) for the rest of its internal max-runtime (Monitors: 15–60 min; backgrounded bash: until the command exits or the shell is killed), and **every notification re-invokes the orchestrator for a no-op turn** because the parent agent is the wake target for everything spawned underneath it. The lightwork session that filed [#297](https://github.com/mattsears18/shipyard/issues/297) accumulated 50+ stale wake events across two fix-checks-worker dispatches that left their Monitor sub-tasks running after returning.

Apply this rule on **every** termination path — clean `green` / `shipped` / `rebased` / `noop:` returns, `blocked: <reason>` bails, and even the `reaped: ...` escape hatch from the next section. The notification leak is independent of whether the worker succeeded; what matters is that the worker spawned something whose lifetime exceeds its turn.

Mechanism per tool family:

| What you spawned | How to stop it before returning |
|---|---|
| `Monitor` sub-task (any subscription) | `TaskStop` against the task id you got back from `TaskCreate` / `Monitor` |
| `Bash` with `run_in_background: true` | `KillShell` against the shell id from the background-call's response (or `BashOutput` if you need the final exit code first, then `KillShell`) |
| `TaskCreate` sub-Agent that's still running | `TaskStop` against its task id |
| Foreground `Bash` (no `run_in_background:`) — e.g. `gh pr checks <M> --watch` | **Nothing** — foreground bash blocks your turn until it exits, so it can't outlive the return |

If you never spawned any of the above, this section is a no-op — the foreground-only path (the default) is already clean. The rule is "if you spawned it, you stop it"; it is NOT "always call TaskStop defensively at the end of every dispatch."

If `TaskStop` / `KillShell` errors (the process already exited on its own, the id was wrong, etc.), log an advisory and continue — the goal is best-effort cleanup, not blocking your return on a stop call that races against a process that was already done.

## Worktree-reaped escape hatch

The orchestrator's end-of-session cleanup reaps `.claude/worktrees/agent-*` directories. It liveness-checks the lock-holding PID before reaping, but defense in depth: an agent whose worktree IS reaped mid-run must NOT silently fall through to operating in the primary checkout. Save your worktree path once at session start:

```bash
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
```

Before every git/gh write — `git commit`, `git push`, `gh pr create`, `gh pr merge`, `gh issue edit` — verify the worktree still exists and your cwd hasn't been relocated:

```bash
if [ ! -d "$WORKTREE_PATH" ] || [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --format='%H' 2>/dev/null | head -c 12)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi
```

The `reaped:` prefix is load-bearing and intentionally distinct from `blocked:`: the orchestrator's step A reconcile parses it as a **retryable** outcome — it re-enqueues the issue for a fresh dispatch rather than applying the `blocked:agent` label. The `blocked:` prefix is reserved for deterministic failures (ambiguous scope, cannot reproduce) where retrying would produce the same result; a mid-run reap is external-infrastructure noise, not a worker logic failure. Do NOT try to `cd` to a different worktree, recreate your worktree, or operate in the primary checkout — exit immediately.

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

## Never `--no-verify`

You are forbidden from passing `--no-verify`, `--no-gpg-sign`, `--no-commit-hooks`, or any other flag that bypasses commit hooks, even if you believe the hook failure is environmental, unrelated to your changes, or a false positive. If a pre-commit hook fails:

1. Try to fix the underlying cause within scope (your changes' code).
2. If the cause is outside scope, return `blocked: pre-commit hook <NAME> failed for reason <X>` so the orchestrator can decide.
3. NEVER bypass. Not even "just this once."

Same rule for `git push --no-verify`. Same rule for any hook-bypass flag. The plugin's `permissions.deny` block in `plugin.json` enforces this at the harness level, but the rule applies even if the deny pattern is somehow bypassed.

## `gh` JSON discipline

Every `gh` call whose output you'll read MUST scope the response to the fields you actually consume. The default output is ~30 fields per issue / ~50 fields per PR — most of which the worker never reads. Each unused field is wasted tool-result tokens that ride in your context for the rest of the session.

The rule applies to **every read-shape `gh` subcommand**:

- `gh issue view / list`, `gh pr view / list`, `gh run list / view` — pass `--json <fields>`. Pick the smallest field set that satisfies the immediate read.
- `gh api <path>` — pass `--jq '<expr>'` to project the response inline. Same effect as piping to `jq`, one less subprocess.
- `gh repo view` — pass `--json <fields> -q <expr>` when reading (e.g. `--json defaultBranchRef -q .defaultBranchRef.name`).

Mutation-shape subcommands — `gh issue close`, `gh issue comment`, `gh issue edit`, `gh pr comment`, `gh pr edit`, `gh pr merge`, `gh pr create`, `gh label create` — are exempt: their output is small (usually empty or a single URL on success) and there's no field to scope.

**Two patterns, in increasing terseness:**

```bash
# Good — field-scoped, jq projection done client-side after the call returns.
gh pr view 142 --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
# (your jq runs against the small JSON returned)

# Better — field-scoped AND inline-projected, so the response itself is already the shape you want.
gh pr view 142 --repo <owner/repo> \
  --json statusCheckRollup,mergeStateStatus \
  -q '{mergeable: .mergeStateStatus, checks: [.statusCheckRollup[] | {name, conclusion}]}'
```

Prefer the inline `-q` form when the projection is a stable shape. Drop to the field-scoped-only form when the caller does multiple independent projections on the same response (worth the extra fields to avoid a second `gh` round-trip).

**Common projections worth remembering:**

| Need | Pattern |
|---|---|
| PR's check rollup (pass/fail/pending) | `gh pr view <M> --json statusCheckRollup,mergeStateStatus` |
| PR's head branch (for `git switch`) | `gh pr view <M> --json headRefName -q .headRefName` |
| Default branch | `gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name` |
| Issue body + labels + comments (issue-work step 0) | `gh issue view <N> --json state,assignees,labels,body,title,comments,author` |
| List PRs awaiting review with status fields | `gh pr list --json number,title,statusCheckRollup,mergeStateStatus,headRefName,labels` |
| Count something via gh + jq | `... --json number --jq 'length'` (NOT `... --json number | jq 'length'`) |

**Don't go default-mode.** A bare `gh issue list` / `gh pr list` / `gh pr view` (no `--json`) returns the full default projection in human-readable form — fine for an interactive terminal, expensive when piped into agent context. The rule applies even for "I just need to know if it exists" — use `--json number --jq 'length'` (or `--json id -q .id`) and let the response be a single integer / string.

**Don't pipe `gh ... --json` into a separate `jq`** when `--jq` (the gh-internal flag) would do the same projection. The piped form forks a second process and serializes the full JSON across a pipe before jq filters it; `--jq` filters server-side on the gh-CLI side of the boundary, so the agent's stdout block already arrives projected. The token savings are downstream of that — a smaller stdout block carries fewer tokens into the next tool-result. (Two-step pipes are still fine when you need `jq` features `gh --jq` doesn't expose — `--slurp`, multi-input, advanced output formatting.)

## What this skill does NOT cover

Mode-specific scope intentionally lives in the per-mode dispatch prompt and the agent's own spec:

- **Branch naming** (`do-work/issue-<N>`, `do-work/fix-main-ci-<short-sha>`, `do-work/fix-pr-pileup-<timestamp>`, or the PR's existing head branch for fix-checks/fix-rebase) — set by the dispatching prompt.
- **Return-string vocabulary** (`shipped #<N> via PR #<M>`, `green #<M>`, `rebased #<M>`, `shipped main-ci-fix via PR #<M>`, etc.) — set by the dispatching prompt and validated by the orchestrator's step A reconcile.
- **Fix-loop attempt caps** (3 for fix-checks-only, 1 for fix-rebase, 1 for fix-main-ci / fix-failing-prs-batch) — set in each per-mode file under `agents/issue-worker/`.
- **Trivial-conflict-or-bail policy** for fix-rebase — set in `agents/issue-worker/fix-rebase.md`.
- **Author-trust → auto-merge gating** for issue-work — passed through as `originating_author_trust` in the dispatching prompt and consumed by `agents/issue-worker/issue-work.md`'s step 6.

When in doubt, the per-mode prompt overrides this skill where they disagree — but the rules above are deliberately universal and shouldn't conflict.
