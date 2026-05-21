# /shipyard:do-work — Drain + termination

Three phases sit at the wind-down side of the orchestrator:

1. **Soft drain** — the user-message-triggered "stop dispatching, let in-flight finish" mode.
2. **Termination** — the mechanical "all queues empty" exit condition.
3. **End-of-session drain** — the post-dispatch-loop merge-train watcher that keeps the orchestrator alive until session-opened PRs settle.

All three share the same authority: they DON'T cancel in-flight work, they DON'T ask the user to confirm, they wait until the merge train is genuinely done (or until the 120-min ceiling fires). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state); the steady-state loop ([`steady-state.md`](./steady-state.md)) hands off here once it can't dispatch any more work; this file hands off to [`cleanup-summary.md`](./cleanup-summary.md) once drain exits.

## Soft drain

The orchestrator wakes on two kinds of events: agent-completion notifications and new user messages. On user-message turns only, evaluate the new message body — if its entire **trimmed** body matches one of these trigger phrases (case-insensitive, full body only — never as a substring), drain mode is engaged:

- `stop`
- `drain`
- `/do-work stop`

Substring matching is deliberately avoided. Phrases like "don't stop yet" or "I'll drain it later" do not trigger.

**On first trigger:**

1. Acknowledge in chat: *"Draining: \<N\> in flight, no new dispatches. Will exit when they finish or settle."*
2. Set `draining = true` in TodoWrite.
3. Steady-state Step A (reconcile) and Step B (release slot) continue normally — in-flight agents must still be properly recorded as they complete.
4. Steady-state Step C (dispatch) and Step D (periodic refresh) become no-ops while `draining = true` (the guards in those steps handle this).
5. When `in_flight` empties → run the [end-of-session drain](#end-of-session-drain) (no-progress termination — keeps polling until the merge train is stalled, with a 120-min safety ceiling) → end-of-session cleanup → end-of-session summary → exit.

**Second trigger** — typing a stop phrase again while already draining — still waits for `in_flight` to empty (in-flight agents are never hard-cancelled), but **skips the end-of-session drain phase entirely** and goes straight to cleanup + summary. Whatever's still pending in `session_prs` at that moment lands in the summary as "still in flight at exit."

Letting in-flight agents finish naturally is safe because they commit at logical milestones and PRs use `--auto`. See [RATIONALE → Soft drain](../do-work-RATIONALE.md#soft-drain--why-its-safe-to-let-agents-finish).

## Termination

**Termination is mechanical, not discretionary. Never ask the user whether to continue.** The pool draining is NOT the termination signal. The only signal that ends the loop early is a literal `stop` / `drain` / `/do-work stop` user message (see [Soft drain](#soft-drain)) — softer phrasings are conversational noise.

The loop ends when **all of** the following are true at the same time:

- `in_flight` is empty (no agents running),
- `failed_prs` is empty,
- `ready_issues` is empty,
- `raw_backlog` is empty AND a fresh step-4 fetch returns zero new candidates.

If any one is non-empty, fill the pool from the highest-priority queue and return control. See [RATIONALE → Termination](../do-work-RATIONALE.md#termination--why-the-merge-train-continuing-isnt-a-stop-signal).

**Drain-mode termination**: when `draining = true` (see [Soft drain](#soft-drain)), the exit condition collapses to `in_flight` empty — `failed_prs` / `ready_issues` / `raw_backlog` are left as-is and rebuilt next session. The drain → cleanup → summary flow below still runs.

Run end-of-session drain → cleanup → summary.

## End-of-session drain

Once termination conditions are met, some PRs may still be `pending` CI or waiting for auto-merge. **Don't terminate while the merge train is still draining.** The drain phase keeps the orchestrator alive past the dispatch loop's end, watching the merge train and dispatching fix-checks workers against newly-red PRs, until either every session-opened PR has settled OR the train has clearly stalled. See [RATIONALE → End-of-session drain](../do-work-RATIONALE.md#end-of-session-drain--why-it-exists-past-the-dispatch-loops-end).

### Drain protocol

**Initial snapshot.** Capture the set of PRs the orchestrator opened this session (`session_prs` — track this from step A's `shipped` reconciles throughout the run). These are the PRs whose status determines drain termination. Pre-existing PRs the orchestrator only fixed via fix-checks count too (they're authored by `@me` and shipyard touched them this session). PRs from other authors don't.

Also initialize `rebase_blocked_prs = {}` — the per-session set of PR numbers that returned `blocked rebase` from a fix-rebase dispatch. Membership is one-shot per session (a PR that blocks on rebase once doesn't get re-dispatched within the same session, even if it stays DIRTY), and the set counts toward the drain's "settled" definition so a non-trivially-conflicted PR doesn't keep the drain alive indefinitely.

Open-PR query for the drain loop:

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-is:draft' \
  --json number,statusCheckRollup,mergeStateStatus,headRefName,headRefOid,labels --limit 200
```

This intentionally **does NOT filter `-label:blocked:ci`** — `blocked:ci` PRs need to be counted as "settled" so they don't keep the drain open forever, and they need to be visible to the snapshot so the per-poll counts are accurate.

`mergeStateStatus` and `headRefName` / `headRefOid` are required for the `D_dirty` set below (drain-phase fix-rebase dispatch) — `mergeStateStatus == "DIRTY"` is the signal that a PR is stale relative to current main but otherwise healthy, and the head-branch identifiers are passed into the fix-rebase prompt template. The fields are also cheap — adding them to an existing query doesn't change the call count.

**Per-poll bookkeeping.** Every 60s, snapshot the open PRs and compute:

- `O` = open PRs in `session_prs` (not yet merged or closed)
- `M_since_last` = PRs that merged or closed since the previous poll (delta vs. the previous `O`)
- `R_new` = PRs whose rollup contains a hard failure (`FAILURE` / `ERROR` / `TIMED_OUT`) AND are NOT carrying `blocked:ci` AND are not already in `in_flight` or `failed_prs`
- `D_dirty` = PRs whose `mergeStateStatus == "DIRTY"` AND have **no** hard-failure check (rollup is fully `SUCCESS` / `SKIPPED` / `NEUTRAL` / `PENDING` / `IN_PROGRESS` / `QUEUED`) AND are NOT in `in_flight` AND have not already had a fix-rebase attempt blocked this session (`blocked rebase` is one-shot per dispatch per session — track in `rebase_blocked_prs`)
- `B` = PRs carrying `blocked:ci` (these are "settled — human needs to look")
- `P_settled` = PRs whose rollup is fully `PENDING` / `IN_PROGRESS` / `QUEUED` AND whose `headRefOid` hasn't changed since the previous poll (auto-merge waiting on long-running checks)

A PR is **settled** when any of: it's merged/closed, it's labeled `blocked:ci`, it has had a `blocked rebase` return this session (membership in `rebase_blocked_prs`), or all its checks are pending AND the head commit hasn't moved AND `P_settled` has been true for it across the last 5 polls (i.e. no churn).

**Per-poll actions.**

1. If `R_new > 0`: push the newly-red PRs onto `failed_prs` (deduped) and dispatch fix-checks-only workers against them — same `--concurrency` cap, same 3-attempt rule, same `blocked:ci` stamp on exhaustion that step A enforces. Drain runs the same dispatcher logic step C uses, just with `failed_prs` as the only queue that's still drainable (no new issue work, no diverts; `divert_queue` is intentionally NOT re-evaluated during drain — a red main mid-drain becomes next session's problem because dispatching a fix-main-ci agent here would extend the session indefinitely).
2. If `D_dirty > 0`: dispatch a fix-rebase worker for each, **subject to the `--concurrency` cap** (combined fix-checks + fix-rebase in-flight count must not exceed `--concurrency`). Fix-checks dispatches in action 1 above take priority — a red PR is more urgent than a stale base. After filling the pool with fix-checks workers, any remaining slots dispatch fix-rebase workers from the `D_dirty` set (lowest PR number first, so dispatch order is deterministic across re-dispatches). Each fix-rebase dispatch is **one-shot per PR per session**: if the worker returns `blocked rebase #<M>: <reason>`, add `<M>` to `rebase_blocked_prs` and do NOT re-dispatch this session even if the PR is still DIRTY at the next poll. The drain's settled definition above counts `rebase_blocked_prs` membership as settled so the PR doesn't keep the drain alive forever.
3. Update the rolling 5-poll window of `M_since_last` values and the in-flight worker counts (fix-checks + fix-rebase combined).
4. Print one drain status line per poll:
   ```
   [drain] open=<O> merged_this_poll=<M_since_last> newly_red=<R_new> dirty=<D_dirty> blocked_ci=<B> rebase_blocked=<|rebase_blocked_prs|> in_flight=<n>(fix-checks=<a>, fix-rebase=<b>) · elapsed=<MM:SS>
   ```

**Termination criterion (forward-progress rule).** Drain continues as long as **any** of these is true:

- A merge or close happened in the last 5 polls (`sum(M_since_last) > 0` over the trailing 5-min window), OR
- Any fix-checks OR fix-rebase worker is in flight, OR
- Any PR has had a rollup state transition in the last 5 polls (pending → green/failure, head-commit change, `mergeStateStatus` transition including DIRTY → CLEAN after a rebase, etc.)

Drain terminates when **all** of the following are true for 5 consecutive polls (i.e. 5 min of zero forward progress):

- No PR has merged or closed.
- No fix-checks or fix-rebase worker is in flight.
- No rollup state has changed.
- Every PR in `session_prs` is either (a) merged/closed, (b) `blocked:ci`, (c) in `rebase_blocked_prs` (one-shot rebase attempt was non-trivial), or (d) pending with no head-commit movement.

**Hard ceiling: 120 min.** As a safety net against degenerate cases (a 90-minute test suite, a runaway CI loop), drain forcibly exits at the 120-min mark even if forward progress is still observable. Surface this in the summary as `drain exited at 120-min ceiling — <n> PRs still pending`.

**On exit, regardless of how drain terminated**: report the final state of every PR in `session_prs` in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary), separated by status (merged ✓ / blocked:ci / still-pending). The user can re-run `/do-work` later to sweep what's left.
