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

## Termination assertion

**Termination is mechanical, not discretionary. Never ask the user whether to continue.** The pool draining is NOT the termination signal. The only signal that ends the loop early is a literal `stop` / `drain` / `/do-work stop` user message (see [Soft drain](#soft-drain)) — softer phrasings are conversational noise.

Before declaring termination (which triggers the drain phase → cleanup → summary → exit), the orchestrator MUST run the following four-step assertion **in order**. Each step is a thing-to-do, not a thing-to-assert-against-stored-state — step 4 in particular must execute the live `gh` query, not infer the result from cached `raw_backlog` size.

1. **`in_flight` is empty.** Check from working memory (the [orchestrator-state struct](../do-work.md#orchestrator-state) `in_flight` map). If non-empty, do NOT proceed — return control and let the existing in-flight workers finish; this step re-runs on the next completion notification.
2. **`failed_prs` is empty.** Check from working memory. If non-empty, fill the pool from `failed_prs` per [dispatch rule 2](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
3. **`ready_issues` is empty.** Check from working memory. If non-empty, fill the pool from `ready_issues` per [dispatch rule 3](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
4. **Fresh-fetch verification.** Run the canonical step-4 backlog query **now** — against the live tracker, not stored state:

   ```bash
   gh issue list --repo <owner/repo> --state open --limit 100 \
     --json number --search 'is:issue is:open -linked:pr -label:blocked:agent -label:wontfix -label:needs-design -label:needs-triage -label:discussion -label:needs-refinement -label:needs-human-review' \
     --jq '[.[].number] | sort'
   ```

   Stamp `last_fresh_fetch` (the steady-state step E invariant-line token) with the current UTC timestamp the moment this call returns. Subtract the union of `in_flight` (target numbers), `ready_issues` (numbers), `raw_backlog` (numbers), `deferred_issues` (issue numbers), and any issues closed earlier this session (via PR auto-close). If the resulting net-new set is **non-empty**, append the new numbers to `raw_backlog` in priority order (same ranking as step 4), run scope-refill via step D, and retry dispatch from [steady-state step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action). **Do NOT proceed to drain.** If the set is empty, all four steps have passed — proceed to the [end-of-session drain](#end-of-session-drain) below.

The fresh-fetch in step 4 is mandatory regardless of how recent the last step-D refresh was. Cached `raw_backlog` reflects the dispatch loop's view of the world as of the most recent refresh; user-filed mid-session issues can sit on the live tracker for an arbitrarily long stretch without surfacing into `raw_backlog`. The canonical termination-boundary commitment is: a fresh `gh issue list` runs immediately before the orchestrator hands off to drain — no exceptions.

See [RATIONALE → Termination](../do-work-RATIONALE.md#termination--why-the-merge-train-continuing-isnt-a-stop-signal) for the broader why-the-merge-train-isn't-the-stop-signal discussion and [issue #195](https://github.com/mattsears18/shipyard/issues/195) for the mechanical-compliance failure that prompted the numbered-procedure restructuring.

**Drain-mode termination**: when `draining = true` (see [Soft drain](#soft-drain)), the exit condition collapses to step 1 only (`in_flight` empty) — steps 2–4 are skipped, `failed_prs` / `ready_issues` / `raw_backlog` are left as-is and rebuilt next session. The fresh-fetch in step 4 is deliberately bypassed: drain mode is the user's explicit "stop dispatching" signal, and surfacing new candidates would contradict that. The drain → cleanup → summary flow below still runs.

### Pre-drain re-validation of `orchestrator-judgment` defers

Once the four-step assertion passes (all queues empty, live backlog returns no net-new), the orchestrator MUST run a fifth step **before transitioning `drain.active = true`** — but ONLY when `deferred_issues` contains any entry with `provenance == "orchestrator-judgment"`:

**Step 5 (fires ONLY when `deferred_issues` has `orchestrator-judgment` entries):** Re-validate each `orchestrator-judgment` entry against current state.

For each entry in `deferred_issues` where `provenance == "orchestrator-judgment"`:

1. **Re-read the defer reason.** Does it name a specific blocker issue or PR (e.g., "Gated on #1077", "Blocked on #1052")?
   - If **yes**: look up the blocker's current state:
     ```bash
     gh issue view <blocker> --repo <owner/repo> --json state -q .state 2>/dev/null \
       || gh pr view <blocker> --repo <owner/repo> --json state -q .state 2>/dev/null \
       || echo "unresolvable"
     ```
     If the blocker is `CLOSED` or `MERGED` → the defer reason is **stale**. Remove this entry from `deferred_issues`, move the issue back to `raw_backlog`, log: `[pre-drain-revalidate] #<N> defer reason stale — blocker #<blocker> is now <state>; returned to raw_backlog`. Invalidate the `gh-cached.sh` backlog cache.
     If the blocker is still `OPEN` → the defer reason is **still valid**. Leave the entry in `deferred_issues`.
   - If **no** (the reason is a free-form judgment, not a named blocker): **dispatch a scope agent** for this issue now. A fresh scope pre-flight is the only way to get an authoritative, evidence-backed answer:
     ```
     [Dispatch scope agent for issue #<N> — pre-drain re-validation of orchestrator-judgment defer]
     ```
     - If the scope agent returns a **deferred shape**: update the entry's provenance to `"scope-agent"` (now it's authoritative). Leave in `deferred_issues`.
     - If the scope agent returns a **ready shape**: remove from `deferred_issues`, push into `raw_backlog`. Log: `[pre-drain-revalidate] #<N> was orchestrator-judgment deferred but scope agent found it ready; returned to raw_backlog`.

2. After processing all `orchestrator-judgment` entries, if `raw_backlog` gained any issues: run scope-refill via step D and retry dispatch from steady-state step C. **Do NOT proceed to drain.** The termination assertion (steps 1–4 above) must pass again.

3. If no issues were re-admitted (all `orchestrator-judgment` defers were confirmed still-valid): emit the **pre-drain audit banner** and proceed to drain:

   ```
   PRE-DRAIN AUDIT
       deferred_issues total: <N> (<M> added this session)
       of those, scope-agent-backed: <K>  orchestrator-judgment: <J>
       orchestrator-judgment entries all re-validated — blockers still active (or scope agent confirmed)
       last live backlog fetch: <HH:MM:SS UTC>
       proceeding to drain
   ```

   The banner is always emitted when step 5 ran — it is the audit trail for the user. When `deferred_issues` has zero `orchestrator-judgment` entries, step 5 is a no-op and the banner is skipped (no audit needed — all defers were scope-agent-backed).

**Why this gate exists.** The termination assertion's step 4 subtracts `deferred_issues` numbers from the live backlog before checking net-new issues. This means the orchestrator can construct an "empty net-new set" entirely through self-defers — deferring every remaining workable issue using working-memory judgment, then declaring termination because the live backlog minus the deferred set is empty. The re-validation pass prevents this: before `drain.active` can flip, every `orchestrator-judgment` defer must be confirmed against current state. See [RATIONALE → Pre-drain re-validation](../do-work-RATIONALE.md#pre-drain-re-validation-of-orchestrator-judgment-defers) for the session that motivated this rule ([#246](https://github.com/mattsears18/shipyard/issues/246)).

**Drain-mode termination:** when `draining = true`, step 5 is also skipped — drain mode is the user's "stop dispatching" signal, and re-evaluating deferred issues would contradict that intent.

Once the four-step assertion passes AND step 5 re-validation clears (or was a no-op), run end-of-session drain → cleanup → summary.

## End-of-session drain

Once termination conditions are met, some PRs may still be `pending` CI or waiting for auto-merge. **Don't terminate while the merge train is still draining.** The drain phase keeps the orchestrator alive past the dispatch loop's end, watching the merge train and dispatching fix-checks workers against newly-red PRs, until either every session-opened PR has settled OR the train has clearly stalled. See [RATIONALE → End-of-session drain](../do-work-RATIONALE.md#end-of-session-drain--why-it-exists-past-the-dispatch-loops-end).

### Drain protocol

**Initial snapshot.** Capture the set of PRs the orchestrator opened this session (`session_prs` — track this from step A's `shipped` reconciles throughout the run). These are the PRs whose status determines drain termination. Pre-existing PRs the orchestrator only fixed via fix-checks count too (they're authored by `@me` and shipyard touched them this session). PRs from other authors don't.

Also initialize two per-session structures that gate fix-rebase re-dispatch:

- `rebase_blocked_prs = {}` — the per-session set of PR numbers that returned `blocked rebase` from a fix-rebase dispatch. A PR that blocks on rebase once doesn't get re-dispatched within the same session, even if it stays DIRTY — re-dispatching against a non-trivial conflict would just produce the same `blocked rebase` outcome and burn another worker. The set counts toward the drain's "settled" definition so a non-trivially-conflicted PR doesn't keep the drain alive indefinitely.
- `rebase_success_counts = {}` — a per-session map of `<pr-number> → <count>` tracking how many times each PR has returned `rebased` (NOT `blocked rebase`) from a fix-rebase dispatch this session. A successful rebase that gets undone by a subsequent sibling merge is a winnable race — the merge train can land the rebased branch if CI finishes faster than the next conflicting merge — so the per-poll dispatcher SHOULD re-dispatch fix-rebase against a PR that's gone DIRTY again. The map caps total cost at 3 successful rebases per PR per session (same number as the fix-checks 3-attempt circuit breaker); a PR that hits the cap is treated as "settled — merge train moving faster than rebase can keep up, defer to next session" and surfaced in the end-of-session summary as still-DIRTY.

The two structures are intentionally distinct: `rebase_blocked_prs` is the **deterministic-failure** gate (the same conflict will produce the same outcome on retry — don't waste a worker), `rebase_success_counts` is the **rate-limit** gate (the merge train is racing rebases — cap the spend without giving up on the first race). Conflating them — the spec's original "one-shot per PR per session" language — caused the race documented in [#265](https://github.com/mattsears18/shipyard/issues/265), where a successfully-rebased PR couldn't recover from a sibling merge re-introducing DIRTY.

Open-PR query for the drain loop:

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-is:draft' \
  --json number,statusCheckRollup,mergeStateStatus,headRefName,headRefOid,labels --limit 200
```

This intentionally **does NOT filter `-label:blocked:ci`** — `blocked:ci` PRs need to be counted as "settled" so they don't keep the drain open forever, and they need to be visible to the snapshot so the per-poll counts are accurate.

`mergeStateStatus` and `headRefName` / `headRefOid` are required for the `D_dirty` set below (drain-phase fix-rebase dispatch) — `mergeStateStatus == "DIRTY"` is the signal that a PR is stale relative to current main but otherwise healthy, and the head-branch identifiers are passed into the fix-rebase prompt template. The fields are also cheap — adding them to an existing query doesn't change the call count.

**Batching the per-PR refresh.** When the drain loop has already snapshotted the open-PR list (above) but needs to re-resolve per-PR fields *for a known subset* — e.g. the "did this `D_dirty` PR's `mergeStateStatus` flip to `CLEAN` since the previous poll, or did its `headRefOid` move?" check that powers the forward-progress rule below — use `plugins/shipyard/scripts/gh-batch.sh pr-status` instead of N sequential `gh pr view <M>`:

```bash
# One round-trip + one tool-result block instead of N. Same projection
# fields the per-PR `gh pr view` would return.
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
  --repo <owner/repo> \
  --numbers "142 143 144 145 146"
```

Emits a JSON object keyed by PR number (string) → `{number, state, mergeable, mergeStateStatus, statusCheckRollupState, headRefName, headRefOid}`. PRs that no longer exist (deleted, transferred) are silently dropped from the output — the caller treats a missing key as "settled, no longer trackable." Suggested TTL band when composing with `gh-cached.sh` (issue [#160](https://github.com/mattsears18/shipyard/issues/160)): **10s**, same churn class as per-PR `statusCheckRollup` queries.

The wrapper auto-chunks at 50 aliases per query (override via `SHIPYARD_GH_BATCH_CHUNK_SIZE`). For typical drain-phase fan-out (3–8 PRs) the entire batch fires as one query.

**Per-poll bookkeeping.** Every 60s, snapshot the open PRs and compute:

- `O` = open PRs in `session_prs` (not yet merged or closed)
- `M_since_last` = PRs that merged or closed since the previous poll (delta vs. the previous `O`)
- `R_new` = PRs whose rollup contains a hard failure (`FAILURE` / `ERROR` / `TIMED_OUT`) AND are NOT carrying `blocked:ci` AND are not already in `in_flight` or `failed_prs`
- `D_dirty` = PRs whose `mergeStateStatus == "DIRTY"` AND have **no** hard-failure check (rollup is fully `SUCCESS` / `SKIPPED` / `NEUTRAL` / `PENDING` / `IN_PROGRESS` / `QUEUED`) AND are NOT in `in_flight` AND are NOT in `rebase_blocked_prs` (the prior dispatch returned `blocked rebase` — re-dispatching would produce the same conflict) AND have `rebase_success_counts[<pr>] < 3` (PRs that have been successfully rebased 3 times in this session are rate-limit-capped and treated as settled — the merge train is advancing faster than rebase can keep up, defer to next session). A PR that was successfully rebased earlier this session and has since gone DIRTY again from a sibling merge IS in `D_dirty` as long as its success-count is under cap — a successful rebase doesn't gate future re-dispatches the way a `blocked rebase` does.
- `B` = PRs carrying `blocked:ci` (these are "settled — human needs to look")
- `P_settled` = PRs whose rollup is fully `PENDING` / `IN_PROGRESS` / `QUEUED` AND whose `headRefOid` hasn't changed since the previous poll (auto-merge waiting on long-running checks)

A PR is **settled** when any of: it's merged/closed, it's labeled `blocked:ci`, it has had a `blocked rebase` return this session (membership in `rebase_blocked_prs`), it has hit the rate-limit cap (`rebase_success_counts[<pr>] >= 3` — three successful rebases in one session, but the merge train keeps re-DIRTY-ing it; surrender for this session and let the next pick it up), or all its checks are pending AND the head commit hasn't moved AND `P_settled` has been true for it across the last 5 polls (i.e. no churn).

**Per-poll actions.**

1. If `R_new > 0`: push the newly-red PRs onto `failed_prs` (deduped) and dispatch fix-checks-only workers against them — same `--concurrency` cap, same 3-attempt rule, same `blocked:ci` stamp on exhaustion that step A enforces. Drain runs the same dispatcher logic step C uses, just with `failed_prs` as the only queue that's still drainable (no new issue work, no diverts; `divert_queue` is intentionally NOT re-evaluated during drain — a red main mid-drain becomes next session's problem because dispatching a fix-main-ci agent here would extend the session indefinitely).
2. If `D_dirty > 0`: dispatch a fix-rebase worker for each, **subject to the `--concurrency` cap** (combined fix-checks + fix-rebase in-flight count must not exceed `--concurrency`). Fix-checks dispatches in action 1 above take priority — a red PR is more urgent than a stale base. After filling the pool with fix-checks workers, any remaining slots dispatch fix-rebase workers from the `D_dirty` set (lowest PR number first, so dispatch order is deterministic across re-dispatches). The per-PR re-dispatch policy splits by return outcome:

   - **`blocked rebase #<M>: <reason>`** — add `<M>` to `rebase_blocked_prs`. Do NOT re-dispatch this session even if the PR is still DIRTY at subsequent polls; the same conflict will produce the same outcome. The drain's settled definition counts `rebase_blocked_prs` membership as settled so the PR doesn't keep the drain alive forever.
   - **`rebased #<M>`** — increment `rebase_success_counts[<M>]` by 1 (initialize to 0 if absent). Do NOT add to `rebase_blocked_prs`. If the PR transitions DIRTY again later in the session (sibling merge re-introduced the conflict), it re-enters `D_dirty` and gets re-dispatched **as long as** `rebase_success_counts[<M>] < 3`. At the cap (3 successful rebases on one PR in one session), the PR is treated as settled: log `[drain] PR #<M> hit rebase-cap (3 successful rebases); deferring to next session — merge train advancing faster than rebase can keep up` and skip future re-dispatches.
   - **`noop: not dirty (<reason>)`** — no bookkeeping change. The PR transitioned out of DIRTY between dispatch and pre-flight (a parallel auto-merge landed it, or the rollup flipped to red and the agent correctly bailed because rebase isn't the right tool). Don't increment either counter; the drain's next poll will re-classify the PR's state from scratch.
   - **`errored`** — no bookkeeping change (matches the existing pattern for transient worker errors). The PR may re-enter `D_dirty` on the next poll and get re-dispatched naturally.

   This split fixes the merge-train race documented in [#265](https://github.com/mattsears18/shipyard/issues/265): a successful rebase followed by a sibling merge re-introducing DIRTY is a winnable race, NOT a stuck state. Capping at 3 successful rebases keeps the worst-case cost bounded (≤3 Haiku-pinned dispatches per PR per session) while letting normal merge-train races resolve on their own.
3. Update the rolling 5-poll window of `M_since_last` values and the in-flight worker counts (fix-checks + fix-rebase combined).
4. Print one drain status line per poll:
   ```
   [drain] open=<O> merged_this_poll=<M_since_last> newly_red=<R_new> dirty=<D_dirty> blocked_ci=<B> rebase_blocked=<|rebase_blocked_prs|> rebase_capped=<count of PRs where rebase_success_counts[<pr>] >= 3> in_flight=<n>(fix-checks=<a>, fix-rebase=<b>) · elapsed=<MM:SS>
   ```

   `rebase_capped` is the count of PRs that hit the 3-successful-rebase rate-limit cap — distinct from `rebase_blocked` because the failure mode is different (race against a fast merge train, not a deterministic conflict). Both classes show up in the end-of-session summary as still-DIRTY PRs needing the next session's attention.

**Termination criterion (forward-progress rule).** Drain continues as long as **any** of these is true:

- A merge or close happened in the last 5 polls (`sum(M_since_last) > 0` over the trailing 5-min window), OR
- Any fix-checks OR fix-rebase worker is in flight, OR
- Any PR has had a rollup state transition in the last 5 polls (pending → green/failure, head-commit change, `mergeStateStatus` transition including DIRTY → CLEAN after a rebase, etc.)

Drain terminates when **all** of the following are true for 5 consecutive polls (i.e. 5 min of zero forward progress):

- No PR has merged or closed.
- No fix-checks or fix-rebase worker is in flight.
- No rollup state has changed.
- Every PR in `session_prs` is either (a) merged/closed, (b) `blocked:ci`, (c) in `rebase_blocked_prs` (a rebase attempt returned `blocked rebase` — non-trivial conflict), (d) rate-limit-capped (`rebase_success_counts[<pr>] >= 3` — the merge train is racing rebases faster than they can settle), or (e) pending with no head-commit movement.

**Hard ceiling: 120 min.** As a safety net against degenerate cases (a 90-minute test suite, a runaway CI loop), drain forcibly exits at the 120-min mark even if forward progress is still observable. Surface this in the summary as `drain exited at 120-min ceiling — <n> PRs still pending`.

**On exit, regardless of how drain terminated**: report the final state of every PR in `session_prs` in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary), separated by status (merged ✓ / blocked:ci / still-pending). The user can re-run `/do-work` later to sweep what's left.
