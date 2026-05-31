# /shipyard:do-work — Drain + termination

Three phases sit at the wind-down side of the orchestrator:

1. **Soft drain** — the user-message-triggered "stop dispatching, let in-flight finish" mode.
2. **Termination** — the mechanical "all queues empty" exit condition.
3. **End-of-session drain** — the post-dispatch-loop merge-train watcher that keeps the orchestrator alive until session-opened PRs settle.

All three share the same authority: they DON'T cancel in-flight work, they DON'T ask the user to confirm, they wait until the merge train is genuinely done — per the progress-based exit (every session_pr settled), with `max_drain_hours` (default 8h) as the ultimate ceiling (issue [#374](https://github.com/mattsears18/shipyard/issues/374)). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state); the steady-state loop ([`steady-state.md`](./steady-state.md)) hands off here once it can't dispatch any more work; this file hands off to [`cleanup-summary.md`](./cleanup-summary.md) once drain exits.

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
5. When `in_flight` empties → run the [end-of-session drain](#end-of-session-drain) (progress-based termination — keeps polling until every session_pr is settled, with a `max_drain_hours` safety ceiling) → end-of-session cleanup → end-of-session summary → exit.

**Second trigger** — typing a stop phrase again while already draining — still waits for `in_flight` to empty (in-flight agents are never hard-cancelled), but **skips the end-of-session drain phase entirely** and goes straight to cleanup + summary. Whatever's still pending in `session_prs` at that moment lands in the summary as "still in flight at exit."

Letting in-flight agents finish naturally is safe because they commit at logical milestones and PRs use `--auto`. See [RATIONALE → Soft drain](../do-work-RATIONALE.md#soft-drain--why-its-safe-to-let-agents-finish).

## Termination assertion

**Termination is mechanical, not discretionary. Never ask the user whether to continue.** The pool draining is NOT the termination signal. The only signal that ends the loop early is a literal `stop` / `drain` / `/do-work stop` user message (see [Soft drain](#soft-drain)) — softer phrasings are conversational noise.

Before declaring termination (which triggers the drain phase → cleanup → summary → exit), the orchestrator MUST run the following four-step assertion **in order**. Each step is a thing-to-do, not a thing-to-assert-against-stored-state — step 4 in particular must execute the live `gh` query, not infer the result from cached `raw_backlog` size.

1. **`in_flight` is empty.** Check from working memory (the [orchestrator-state struct](../do-work.md#orchestrator-state) `in_flight` map). If non-empty, do NOT proceed — return control and let the existing in-flight workers finish; this step re-runs on the next completion notification.
2. **`failed_prs` is empty.** Check from working memory. If non-empty, fill the pool from `failed_prs` per [dispatch rule 2](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
3. **`ready_issues` is empty.** Check from working memory. If non-empty, fill the pool from `ready_issues` per [dispatch rule 3](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
4. **Fresh-fetch verification.** Run the canonical step-4 backlog query **now** — against the live tracker, not stored state. **Use the same wide-fetch + client-side filter shape that [setup.md step 4](./setup.md#4-fetch--rank-the-backlog) uses** (the previous narrower `-linked:pr` + `-label:...` server-side qualifiers were removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — they silently excluded resumable-work issues like prior-session self-assigns whose linked PR had been closed or never opened, producing premature "backlog empty → drain" handoffs):

   ```bash
   # Wide fetch — server-side filter is purely --state open. All
   # eligibility checks happen client-side (see setup.md step 4 for
   # the canonical client-side filter pass).
   gh issue list --repo <owner/repo> --state open --limit 200 \
     --json number,labels,assignees,body,author \
     --jq '[.[] | {number, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'
   ```

   Then apply the same client-side filter [setup.md step 4](./setup.md#4-fetch--rank-the-backlog) applies — trusted-author check, dispatch-gate labels (`blocked:agent`, `blocked:agent-hard`, `blocked:ci`, `wontfix`, `needs-design`, `needs-triage`, `discussion`, `needs-refinement`, `needs-human-review`), assignee≠@me, `Blocked by #N` still-open, closed-by-@me-authored-healthy-PR — and project the result to a sorted number list for the diff below. Read the client-side filter directly from setup.md's spec; never re-derive it in this file (the two MUST stay in lockstep — that's exactly the bug [#332](https://github.com/mattsears18/shipyard/issues/332) documented).

   Stamp `last_fresh_fetch` (the steady-state step E invariant-line token) with the current UTC timestamp the moment this call returns. Stamp `unfiltered_open_count` (the [steady-state step E invariant-line token added in #332](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn)) with the count returned by the wide fetch BEFORE the client-side filter runs — this is the surface the user (and the next session's orchestrator) reads to spot a "raw_backlog=0 but unfiltered_open_count=29" smell that would otherwise hide a regression in the client-side filter itself. Subtract the union of `in_flight` (target numbers), `ready_issues` (numbers), `raw_backlog` (numbers), `deferred_issues` (issue numbers), and any issues closed earlier this session (via PR auto-close) from the post-filter list. If the resulting net-new set is **non-empty**, append the new numbers to `raw_backlog` in priority order (same ranking as step 4), run scope-refill via step D, and retry dispatch from [steady-state step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action). **Do NOT proceed to drain.** If the set is empty, all four steps have passed — proceed to the [end-of-session drain](#end-of-session-drain) below.

The fresh-fetch in step 4 is mandatory regardless of how recent the last step-D refresh was. Cached `raw_backlog` reflects the dispatch loop's view of the world as of the most recent refresh; user-filed mid-session issues can sit on the live tracker for an arbitrarily long stretch without surfacing into `raw_backlog`. The canonical termination-boundary commitment is: a fresh `gh issue list` runs immediately before the orchestrator hands off to drain — no exceptions.

See [RATIONALE → Termination](../do-work-RATIONALE.md#termination--why-the-merge-train-continuing-isnt-a-stop-signal) for the broader why-the-merge-train-isn't-the-stop-signal discussion and [issue #195](https://github.com/mattsears18/shipyard/issues/195) for the mechanical-compliance failure that prompted the numbered-procedure restructuring.

**Drain-mode termination**: when `draining = true` (see [Soft drain](#soft-drain)), the exit condition collapses to step 1 only (`in_flight` empty) — steps 2–4 are skipped, `failed_prs` / `ready_issues` / `raw_backlog` are left as-is and rebuilt next session. The fresh-fetch in step 4 is deliberately bypassed: drain mode is the user's explicit "stop dispatching" signal, and surfacing new candidates would contradict that. The drain → cleanup → summary flow below still runs.

### Pre-drain re-validation of deferred entries

Once the four-step assertion passes (all queues empty, live backlog returns no net-new), the orchestrator MUST run a fifth step **before transitioning `drain.active = true`** — whenever `deferred_issues` contains any entries at all (regardless of provenance):

**Step 5 (fires whenever `deferred_issues` is non-empty):** Re-validate every entry against current state. The two provenance classes get different mechanisms but both run; a session that reaches drain through a mix of `orchestrator-judgment` and `scope-agent` defers gets both branches exercised.

#### 5.a — Re-validate `orchestrator-judgment` entries

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
   - If **no** (the reason is a free-form judgment, not a named blocker): **dispatch a scope agent** for this issue now — but **first re-run the [pre-scope orchestrator-side detector batch](./setup.md#pre-scope-orchestrator-side-detectors-synthetic-defers) from setup.md step 6** against the issue body. If any detector fires, synthesize the deferred entry directly (skip the scope-agent dispatch) and leave the entry in `deferred_issues` with the fresh synthesized fields — same behavior as the initial pre-flight, applied to re-validation. This keeps the detector load-bearing across both call sites; without re-running it here, a re-validation that dispatches a scope agent against a body the detector batch guards (a `.github/workflows/`-proposing body, a `.claude/settings.json` / `.claude/settings.local.json` / `.mcp.json`-proposing body, or any future detector's target) would likely return `ready` (the scope agent has no detector built in) and immediately reproduce the orphan-branch / classifier-denial failure mode the detector exists to prevent. If no detector fires, dispatch the scope agent normally:
     ```
     [Dispatch scope agent for issue #<N> — pre-drain re-validation of orchestrator-judgment defer]
     ```
     - If the scope agent returns a **deferred shape**: update the entry's provenance to `"scope-agent"` (now it's authoritative). Leave in `deferred_issues`. **Important:** the entry now belongs to the 5.b cohort going forward; it does NOT get re-run by 5.b in the same pre-drain pass (one re-validation per entry per pass), but a subsequent pre-drain entry (e.g. a future session) would treat it as a scope-agent defer.
     - If the scope agent returns a **ready shape**: remove from `deferred_issues`, push into `raw_backlog`. Log: `[pre-drain-revalidate] #<N> was orchestrator-judgment deferred but scope agent found it ready; returned to raw_backlog`.

#### 5.b — Re-validate `scope-agent` entries

For each entry in `deferred_issues` where `provenance == "scope-agent"` (excluding any entry that just got promoted to `scope-agent` provenance by 5.a — those have a fresh scope agent return and don't need another one in this pass):

**Dispatch a fresh scope agent** for this issue now — but **first re-run the [pre-scope orchestrator-side detector batch](./setup.md#pre-scope-orchestrator-side-detectors-synthetic-defers) from setup.md step 6** against the issue body. If any detector fires, synthesize the deferred entry directly (skip the scope-agent dispatch) and update the existing entry's `reason`, `defer_reason_class`, `evidence_pointer`, `provenance` (set to `"orchestrator-judgment"` since the detector — not a scope agent — produced the fresh determination), and `deferred_at` to the synthesized values. The entry stays in `deferred_issues`; log `[pre-drain-revalidate] #<N> pre-scope detector re-confirmed defer (class=<defer_reason_class>, evidence=<evidence_pointer>) — <fresh reason>`. This is the same defense-in-depth posture as 5.a's detector re-run — a body that proposes a change to any path the detector batch guards (workflow files, Claude-Code self-modification targets, or future detectors) should never be promoted back to `raw_backlog` via re-validation, regardless of the original defer's provenance. If no detector fires, dispatch the scope agent normally. The original scope-agent return reflected the issue's state at scope time; main may have advanced since (a sibling PR landed, a blocker resolved, a dep updated), the audit data may have aged, or the original scope agent may have been permissively-conservative on a body that's tractable on second look. The phase-slicing bias documented in [setup.md step 6](./setup.md#6-initial-scope-pre-flight)'s prompt instruction means a fresh scope agent will actively look for a phase-1 slice that the original agent — even if running against the same body — might have missed; this is the load-bearing reason re-validation produces different answers than the first scope pass even when the issue's body hasn't changed. A fresh scope pre-flight is the same mechanism 5.a uses for free-form orchestrator-judgment defers, and the same authoritative answer applies:

```
[Dispatch scope agent for issue #<N> — pre-drain re-validation of scope-agent defer]
  Original defer reason: <entry.reason>
  Original defer_reason_class: <entry.defer_reason_class>
  Original evidence_pointer: <entry.evidence_pointer>
  Would_be_dispatchable_as_phase_1_if (from original defer): <entry.would_be_dispatchable_as_phase_1_if or "not provided">
  Pass through to the scope agent so it can check whether the unblocking condition has resolved.
  The fresh defer (if any) MUST supply a new evidence_pointer — the orchestrator validates it the same way as the original (per-class shape check in setup.md step 6).
```

- If the scope agent returns a **ready shape** (with or without `phase_1_scope`): remove from `deferred_issues`, push into `raw_backlog`. The candidate is re-scoped by the next dispatch via step C's normal flow; the `phase_1_scope` field — if present — flows through to the worker prompt as documented in [setup.md step 6](./setup.md#6-initial-scope-pre-flight)'s ready-entry handling. Log: `[pre-drain-revalidate] #<N> was scope-agent deferred but fresh scope agent found it ready<scope-suffix>; returned to raw_backlog`. The `<scope-suffix>` is ` (as phase-1 slice: <phase_1_scope>)` when the fresh return supplied one, empty otherwise.
- If the scope agent returns a **deferred shape**: run the [per-class `evidence_pointer` validator from setup.md step 6](./setup.md#6-initial-scope-pre-flight)'s Deferred-entries handler against the fresh return. If the new `evidence_pointer` fails validation, treat the fresh return as malformed: remove the entry from `deferred_issues`, push the issue back into `raw_backlog`, and log `[pre-drain-revalidate] #<N> scope-agent re-validation returned malformed defer (evidence_pointer "<pointer>" failed per-class shape check) — promoted to raw_backlog for fresh scope pass`. This closes the loophole where a re-validation could re-confirm a defer with stale speculative evidence indefinitely. If the new `evidence_pointer` validates, leave the entry in `deferred_issues` and update `reason`, `defer_reason_class`, `evidence_pointer`, and `would_be_dispatchable_as_phase_1_if` to the fresh return's values (the old fields may be stale; the new ones are the current authoritative diagnosis), then bump `deferred_at` to the current timestamp. Log: `[pre-drain-revalidate] #<N> scope-agent re-confirmed deferred (class=<defer_reason_class>, evidence=<evidence_pointer>) — <fresh reason>`.

The cost of 5.b is one scope-agent invocation per scope-agent defer that actually reaches the pre-drain check — bounded by `|deferred_issues with scope-agent provenance|`. The bound is acceptable because the alternative (treating scope-agent defers as authoritative ground truth and letting drain fire on a single misjudgment) was the failure mode [#299](https://github.com/mattsears18/shipyard/issues/299) documented — a `mattsears18/lightwork` session that drained on 15+ workable issues because the JIT scope pre-flight at C=1 had returned `deferred` on each of them in sequence. The phase-slicing bias added by [#298](https://github.com/mattsears18/shipyard/issues/298) makes the re-validation more likely to flip an entry to ready — not because the issue's state has changed, but because the slicing-biased prompt actively searches for a phase-1 slice the original conservative pass passed over.

#### 5.c — After processing all entries

After both 5.a and 5.b have run:

1. If `raw_backlog` gained any issues from either branch: run scope-refill via step D and retry dispatch from steady-state step C. **Do NOT proceed to drain.** The termination assertion (steps 1–4 above) must pass again.

2. If no issues were re-admitted (all defers were confirmed still-valid by their respective re-validation): emit the **pre-drain audit banner** and proceed to drain:

   ```
   PRE-DRAIN AUDIT
       deferred_issues total: <N> (<M> added this session)
       of those, scope-agent-backed: <K> (re-validated)  orchestrator-judgment: <J> (re-validated)
       defer_reason_class breakdown:
           external-dependency: <c_ext>
           human-decision-required: <c_human>
           untrusted-author: <c_untrusted>
           confirmed-blocker-still-open: <c_blocker>
           confirmed-non-shippable-as-single-PR: <c_unsliceable>
       all defers re-validated — blockers still active, scope agents re-confirmed
       last live backlog fetch: <HH:MM:SS UTC>
       proceeding to drain
   ```

   `defer_reason_class` is the load-bearing field added by [#298](https://github.com/mattsears18/shipyard/issues/298) — every `deferred_issues` entry MUST carry one of the five values above. An entry that reaches this banner without a class is a spec violation; the orchestrator MUST treat such entries as needing a fresh scope agent re-dispatch (same path as 5.b) before letting drain fire. `evidence_pointer` is the load-bearing field added by [#302](https://github.com/mattsears18/shipyard/issues/302) — every entry MUST carry a per-class-valid mechanical citation, and entries that survive 5.b have already been re-validated through the per-class shape check. An entry that reaches this banner without a non-empty `evidence_pointer` is also a spec violation (treat the same way: promote to `raw_backlog`, re-dispatch scope agent before drain fires). Omit any breakdown line whose count is zero to keep the banner terse on sessions with few defers.

   The banner is always emitted when step 5 ran — it is the audit trail for the user. When `deferred_issues` is empty (step 5 was a no-op), the banner is skipped (no audit needed — there was nothing to re-validate).

**Why this gate exists.** The termination assertion's step 4 subtracts `deferred_issues` numbers from the live backlog before checking net-new issues. This means the orchestrator can construct an "empty net-new set" entirely through self-defers — deferring every remaining workable issue (either through working-memory judgment or through a chain of conservative scope-agent returns), then declaring termination because the live backlog minus the deferred set is empty. The re-validation pass prevents this: before `drain.active` can flip, every defer must be confirmed against current state. See [RATIONALE → Pre-drain re-validation](../do-work-RATIONALE.md#pre-drain-re-validation-of-deferred-entries) for the sessions that motivated this rule ([#246](https://github.com/mattsears18/shipyard/issues/246) added the orchestrator-judgment branch; [#299](https://github.com/mattsears18/shipyard/issues/299) extended it to scope-agent entries).

**Drain-mode termination:** when `draining = true`, step 5 (both 5.a and 5.b) is skipped — drain mode is the user's "stop dispatching" signal, and re-evaluating deferred issues would contradict that intent.

Once the four-step assertion passes AND step 5 re-validation clears (or was a no-op), run end-of-session drain → cleanup → summary.

## End-of-session drain

Once termination conditions are met, some PRs may still be `pending` CI or waiting for auto-merge. **Don't terminate while the merge train is still draining.** The drain phase keeps the orchestrator alive past the dispatch loop's end, watching the merge train and dispatching fix-checks workers against newly-red PRs, until every session-opened PR has settled (progress-based — per-PR head-movement quiescence, not a wall-clock window; issue [#374](https://github.com/mattsears18/shipyard/issues/374)) OR the `max_drain_hours` ceiling fires. See [RATIONALE → End-of-session drain](../do-work-RATIONALE.md#end-of-session-drain--why-it-exists-past-the-dispatch-loops-end).

### Drain protocol

**Initial snapshot.** Capture the set of PRs the orchestrator opened this session (`session_prs` — track this from step A's `shipped` reconciles throughout the run). These are the PRs whose status determines drain termination. Pre-existing PRs the orchestrator only fixed via fix-checks count too (they're authored by `@me` and shipyard touched them this session). Inherited `@me` PRs left `DIRTY`-but-green by a *prior* session are also in `session_prs` — they were adopted into this session's ownership set by [setup step 5.7](./setup.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off) (or step D's failed-PR scan at C=1) so this drain's `D_dirty` classifier can dispatch a fix-rebase worker against them; closes [#373](https://github.com/mattsears18/shipyard/issues/373). PRs from other authors don't.

Also initialize three per-session structures that gate fix-rebase re-dispatch and progress-based termination:

- `rebase_blocked_prs = {}` — the per-session set of PR numbers that returned `blocked rebase` from a fix-rebase dispatch. A PR that blocks on rebase once doesn't get re-dispatched within the same session, even if it stays DIRTY — re-dispatching against a non-trivial conflict would just produce the same `blocked rebase` outcome and burn another worker. The set counts toward the drain's "settled" definition so a non-trivially-conflicted PR doesn't keep the drain alive indefinitely.
- `rebase_success_counts = {}` — a per-session map of `<pr-number> → <count>` tracking how many times each PR has returned `rebased` (NOT `blocked rebase`) from a fix-rebase dispatch this session. A successful rebase that gets undone by a subsequent sibling merge is a winnable race — the merge train can land the rebased branch if CI finishes faster than the next conflicting merge — so the per-poll dispatcher SHOULD re-dispatch fix-rebase against a PR that's gone DIRTY again. The map caps total cost at 3 successful rebases per PR per session (same number as the fix-checks 3-attempt circuit breaker); a PR that hits the cap is treated as "settled — merge train moving faster than rebase can keep up, defer to next session" and surfaced in the end-of-session summary as still-DIRTY.
- `head_unchanged_since = {}` — a per-session map of `<pr-number> → {oid, since}` tracking each open PR's last-observed `headRefOid` and the UTC timestamp it was first observed at that value (issue [#374](https://github.com/mattsears18/shipyard/issues/374)). This is the progress signal that replaces the old wall-clock ceiling: a PR whose head commit hasn't moved for `settled_minutes` (config `ci.settled_minutes`, default 20) is "settled" even if its checks are still pending — auto-merge is waiting on long-running CI, not stuck. Every poll, for each open PR: if its current `headRefOid` differs from the stored `oid` (or there's no stored entry), reset the entry to `{oid: <current>, since: <now>}`; otherwise leave `since` untouched. The PR's "head unchanged for" duration is `now - head_unchanged_since[<pr>].since`. A head-commit movement (a fresh push, a successful rebase force-push) resets the clock, so a PR actively being worked never counts as settled.

Read the two #374 duration knobs once at drain entry (they don't change mid-session):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
settled_minutes=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.settled_minutes 2>/dev/null || echo 20)
max_drain_hours=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.max_drain_hours 2>/dev/null || echo 8)
```

**Run the primary-checkout branch-leak guard once at drain entry** ([#387](https://github.com/mattsears18/shipyard/issues/387)). Drain is exactly where a leaked `do-work/*` checkout on the primary does its damage: it holds git's per-branch lock on a PR head branch, so the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release) below and the fix-rebase worker's `git switch <head>` both collide with it. The [#387](https://github.com/mattsears18/shipyard/issues/387) repro surfaced precisely here — drain dispatching a fix-rebase for the one DIRTY PR (#384, head `do-work/issue-378`) against a primary the harness had leaked onto `do-work/issue-378`. Restoring the primary to the default branch at drain entry frees the head branch *before* the first per-PR reap runs. Run the **exact** guard from [steady-state.md step A.0.6](./steady-state.md#a06-primary-checkout-branch-leak-guard-fires-every-reconcile-turn-before-a1) (same path-derivation, same clean-restore-vs-dirty-skip branch, same `primary_leak_counters` increments) — it is the single source of truth; do not re-derive a variant here.

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
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
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
- `R_new` = PRs whose rollup contains a hard failure (`FAILURE` / `ERROR` / `TIMED_OUT` / `CANCELLED` / `ACTION_REQUIRED`) **on the latest run per check name** AND are NOT carrying `blocked:ci` AND are not already in `in_flight` or `failed_prs`
- `D_dirty` = PRs whose `mergeStateStatus == "DIRTY"` AND have **no** hard-failure check **on the latest run per check name** (rollup is fully `SUCCESS` / `SKIPPED` / `NEUTRAL` / `PENDING` / `IN_PROGRESS` / `QUEUED`) AND are NOT in `in_flight` AND are NOT in `rebase_blocked_prs` (the prior dispatch returned `blocked rebase` — re-dispatching would produce the same conflict) AND have `rebase_success_counts[<pr>] < 3` (PRs that have been successfully rebased 3 times in this session are rate-limit-capped and treated as settled — the merge train is advancing faster than rebase can keep up, defer to next session). A PR that was successfully rebased earlier this session and has since gone DIRTY again from a sibling merge IS in `D_dirty` as long as its success-count is under cap — a successful rebase doesn't gate future re-dispatches the way a `blocked rebase` does.
- `B` = PRs carrying `blocked:ci` (these are "settled — human needs to look")
- `P_settled` = PRs whose rollup is fully `PENDING` / `IN_PROGRESS` / `QUEUED` AND whose `headRefOid` has been unchanged for at least `settled_minutes` (i.e. `now - head_unchanged_since[<pr>].since >= settled_minutes` — auto-merge is waiting on long-running checks, not stuck; issue [#374](https://github.com/mattsears18/shipyard/issues/374)). Before #374 this was "unchanged since the *previous poll*" — a single 60s interval — which conflated "head hasn't moved for one minute" with "settled." A pending PR mid-CI-run trivially has an unchanged head between two adjacent polls; the `settled_minutes` threshold (default 20) is what distinguishes a healthy-but-slow merge train from a genuinely stalled one. First update `head_unchanged_since[<pr>]` (reset on head movement, else leave `since` untouched) so this comparison reads the freshly-maintained timestamp.

**Latest-per-name semantics for `R_new` and `D_dirty`** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns every check run for the PR's head SHA — including superseded runs. A check that ran, failed, was re-triggered, and passed appears twice (one FAILURE entry + one SUCCESS entry). A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk would (a) keep already-fixed PRs in `R_new` forever, dispatching pointless fix-checks workers that return `noop: already green`, and (b) keep already-fixed PRs OUT of `D_dirty`, sending the drain-phase fix-rebase worker the false signal "this PR has failing checks — bail" when in fact it's green. Both failure modes were observed in lightwork session `c6afe19d-a6a6-40e4-9eb8-de409d046a49` against PRs #1193 and #1211. De-duplicate by check name and take the most recent entry per check (by `completedAt`, fallback `startedAt`):

```bash
# Latest-per-name failure count. Used by both R_new (>0 means failing) and D_dirty (==0 means clean enough to rebase).
fails=$(echo "$pr_rollup_json" | jq '
  [.statusCheckRollup
   | group_by(.name)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
  | length')
```

The `group_by(.name) | map(... | last)` reduction is load-bearing: it collapses N entries per check name to 1 (the latest), so a stale FAILURE entry superseded by a later SUCCESS is correctly filtered out. Apply this projection in every per-PR rollup walk in both the per-poll snapshot and any fan-out re-snapshot via `gh-batch.sh pr-status`.

**Defense-in-depth advisory log.** When the orchestrator's snapshot for a PR says `fails > 0` based on the raw rollup but `fails == 0` based on the latest-per-name projection (i.e., the *only* failure entries are stale-superseded), emit `[stale-rollup-detected] PR #<M> has <N> stale FAILURE entries superseded by later SUCCESS; treating as green` to the orchestrator log before proceeding. Surfaces the failure mode for telemetry without blocking the dispatch.

A PR is **settled** when any of: it's merged/closed, it's labeled `blocked:ci`, it has had a `blocked rebase` return this session (membership in `rebase_blocked_prs`), it has hit the rate-limit cap (`rebase_success_counts[<pr>] >= 3` — three successful rebases in one session, but the merge train keeps re-DIRTY-ing it; surrender for this session and let the next pick it up), or membership in `P_settled` (its checks are all pending AND its head commit has been unchanged for at least `settled_minutes`). The progress signal — per-PR head-commit movement, not the wall clock — is what the `settled_minutes` threshold reads (issue [#374](https://github.com/mattsears18/shipyard/issues/374)). A PR actively churning (head moving every few minutes from rebases or pushes) never reaches the `settled_minutes` threshold and keeps the drain alive; a PR whose head went quiet 20+ min ago is settled regardless of how long the overall session has been running.

### Pre-dispatch head-branch reap (self-PID lock release)

Closes [#370](https://github.com/mattsears18/shipyard/issues/370). Before dispatching **any** drain-phase fix-checks-only or fix-rebase worker (per-poll actions 1 and 2 below), the orchestrator MUST first release any agent worktree that's still holding a `git worktree --lock` on the PR's head branch with **our own session's PID**.

**The failure mode.** A fresh drain-phase worker lands in its own isolated worktree, then runs the safe two-step (`git fetch origin <head>` + `git switch <head>`) to land on the PR's head branch (`fix-checks-only.md` step 1 / `fix-rebase.md` step 1). When the original issue-work worker's worktree is *still locked* against that head branch — because the [step A.1 immediate-reap (#282)](./steady-state.md#a-reconcile-the-return) deferred on `peer-alive`, or the worker returned `blocked` / `errored` (so the A.1 `shipped`-only reap never ran for it), or a transient `gh` failure aborted the reap — `git switch` fails with *"is already checked out at \<path\>"* and the worker bails with `blocked rebase #<M>: head branch <HEAD_REF> locked in another worktree` (`fix-rebase.md` step 1) or `Cannot apply fix to PR branch — <head> is locked by another worktree` (fix-checks-only). The fresh worker has already identified the correct fix; it just can't push it. Since the orchestrator's own end-of-session reap (cleanup-summary step 3b) runs *after* drain, drain-phase dispatches always race the lock — and drain is exactly where fix-rebase / fix-checks dispatches are supposed to land ([`dont.md`](./dont.md) bans fix-rebase outside drain). Observed in lightwork session `do-work-20260528T015557Z-14129`: 3 PRs (#1355, #1361, #1363) all bailed identically against self-PID-locked head branches.

**Why it's safe to reap.** The lock holds *our orchestrator's* PID (the harness writes the orchestrator PID into every dispatched agent's worktree lock). `classify-lock` short-circuits such a lock to `self-ancestor` once `SHIPYARD_ORCHESTRATOR_PID` is declared — which means "this lock is held by an orchestrator that is itself / an ancestor of ours, about to retire its own worktree." The original worker's return was already reconciled at [step A](./steady-state.md#a-reconcile-the-return) by the time drain runs; its worktree is logically done. This is the same self-ancestor reap logic [setup.md step 3b](./setup.md#3-ensure-label-exists--recover-from-prior-session) runs at session start and the A.1 `shipped`-immediate reap (#282) runs on issue-work completion — extended to the mid-session drain dispatch site for PRs whose originating worker did NOT take the `shipped` path (so A.1 never reaped them).

**The reap.** For each PR `#<M>` the drain is about to dispatch a worker against, resolve its head branch, find any `agent-*` worktree **or the primary checkout** locked against that branch, and reap / restore it iff safe. The two holders are handled differently: an `agent-*` worktree is reaped iff the lock classifies as reapable (`no-lock` / `dead` / `self-ancestor`), deferring only on `peer-alive`; the **primary checkout** holding the head branch is the [#387](https://github.com/mattsears18/shipyard/issues/387) harness-leak case — restore it to the default branch iff its tree is clean (never reap the primary; it's the user's checkout), warn-and-skip if dirty. The drain-entry guard above usually handles the primary case first, but this per-PR check is the belt-and-suspenders for a leak that lands *mid-drain* (after the entry guard ran).

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
cd "$(git rev-parse --show-toplevel)"
# Declare the orchestrator PID once so classify-lock short-circuits self-locks
# to `self-ancestor` (issue #263) regardless of process-tree shape.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)

# $head_ref is the PR's headRefName (already in the drain snapshot's
# `headRefName` field — no extra `gh` round-trip needed).

# --- Primary-checkout holder (issue #387) ---------------------------------
# Before scanning agent-* worktrees, check whether the PRIMARY checkout is
# the one parked on this PR's head branch (the harness-leak case). If so,
# restore-if-clean / warn-if-dirty per the A.0.6 guard — NEVER reap the
# primary. Frees the per-branch lock so the fix-rebase worker can switch.
PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel)"
case "$PRIMARY_CHECKOUT" in
  */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
esac
PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")
if [ "$PRIMARY_BRANCH" = "$head_ref" ]; then
  DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
  if [ -z "$(git -C "$PRIMARY_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
    git -C "$PRIMARY_CHECKOUT" checkout "$DEFAULT_BRANCH" 2>/dev/null \
      && git -C "$PRIMARY_CHECKOUT" pull --ff-only 2>/dev/null || true
    echo "[primary-leak] restored primary from $head_ref to $DEFAULT_BRANCH before fix-rebase dispatch (#387)"
    primary_leak_restores=$((primary_leak_restores + 1))
  else
    echo "[primary-leak] WARNING: primary checkout holds head branch $head_ref AND has uncommitted changes; NOT auto-restoring (possible real edits). fix-rebase for this PR will bail until you restore manually: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH (#387)"
    primary_leak_dirty_skips=$((primary_leak_dirty_skips + 1))
  fi
fi
# --------------------------------------------------------------------------

for wt_dir in $(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null); do
  [ -d "$wt_dir" ] || continue
  branch_ref=$(sed 's|ref: refs/heads/||' "$wt_dir/HEAD" 2>/dev/null)
  [ "$branch_ref" = "$head_ref" ] || continue

  name=$(basename "$wt_dir")
  worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
  [ -z "$worktree_path" ] && continue

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" classify-lock "$wt_dir/locked")
  lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
  [ -z "$lock_pid" ] && lock_pid="null"

  if [ "$classification" = "peer-alive" ]; then
    # A genuinely-live non-orchestrator PID holds the lock. Don't yank it.
    # Defer; the fresh worker will bail with `blocked rebase` and the PR is
    # surfaced in the summary — same outcome as pre-#370, but only for the
    # truly-unsafe case rather than the common self-PID case.
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action deferred \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "<session-id>" \
      --reason "peer-alive" \
      --lock-pid "$lock_pid" \
      --phase "drain-pre-dispatch" 2>/dev/null || true
    break
  fi

  # no-lock / dead / self-ancestor — safe to reap. The helper does the
  # `git worktree unlock` + `git worktree remove --force` AND the audit-log
  # write in one transaction (issue #284).
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "$name" \
    --session-id "<session-id>" \
    --classification "$classification" \
    --lock-pid "$lock_pid" \
    --phase "drain-pre-dispatch" 2>/dev/null || true

  # Drop the local branch ref so the fresh worker's `git switch <head>`
  # recreates it cleanly without the "already checked out" collision.
  git branch -D "$head_ref" 2>/dev/null || true
  break   # at most one worktree per head branch
done
git worktree prune 2>/dev/null || true
```

This block is **fire-and-forget** (every command suffixes `2>/dev/null` and / or `|| true`) so a filesystem race can't abort the drain poll. It runs **once per PR per dispatch**, immediately before the `Agent` dispatch for that PR — NOT once per poll across all PRs (a PR not being dispatched this poll, e.g. one held back by the `max_drain_rebases` cap, doesn't need its lock released yet). The `peer-alive` defer is intentionally conservative: it preserves the exact pre-#370 behavior for the genuinely-unsafe case (a live non-orchestrator process holding the lock), so #370's fix narrows the bail surface to only the truly-unsafe locks rather than removing the safety entirely. Audit entries carry `"phase":"drain-pre-dispatch"` so an operator can distinguish drain-phase reaps from setup-3b (session start), steady-state-A1-shipped (#282 immediate-reap), and reconcile-A.0.5 (#358 crash-recovery) in `~/.shipyard/reap-audit.jsonl`.

The **primary-checkout holder** branch (issue [#387](https://github.com/mattsears18/shipyard/issues/387)) is intentionally *not* a reap — the primary is the user's checkout, never a shipyard-owned worktree, so it's restore-if-clean / warn-if-dirty, exactly as the [A.0.6 guard](./steady-state.md#a06-primary-checkout-branch-leak-guard-fires-every-reconcile-turn-before-a1) does it. It increments the same `primary_leak_counters` map the entry-guard and steady-state guard feed, so the end-of-session friction line counts a mid-drain leak the same as a reconcile-turn one. The dirty-skip path leaves the head branch locked and the fix-rebase worker for that PR will bail `blocked rebase` — the correct conservative outcome when the primary has uncommitted work shipyard must not touch.

**Per-poll actions.**

1. If `R_new > 0`: push the newly-red PRs onto `failed_prs` (deduped) and dispatch fix-checks-only workers against them — same `--concurrency` cap, same 3-attempt rule, same `blocked:ci` stamp on exhaustion that step A enforces. Drain runs the same dispatcher logic step C uses, just with `failed_prs` as the only queue that's still drainable (no new issue work, no diverts; `divert_queue` is intentionally NOT re-evaluated during drain — a red main mid-drain becomes next session's problem because dispatching a fix-main-ci agent here would extend the session indefinitely). **Before each dispatch, run the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release) against that PR's head branch** so the fresh fix-checks worker's `git switch <head>` doesn't collide with a self-PID-locked worktree from the originating worker (#370).
2. If `D_dirty > 0`: dispatch a fix-rebase worker for each, **subject to the `--concurrency` cap** (combined fix-checks + fix-rebase in-flight count must not exceed `--concurrency`) **AND the CI-minute config gates from issue [#323](https://github.com/mattsears18/shipyard/issues/323)**. **Before each dispatch, run the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release) against that PR's head branch** (#370) — this is the load-bearing call for fix-rebase, the mode `dont.md` confines to drain and the one the #370 repro caught bailing on every self-PID-locked PR.

   **CI-minute pre-dispatch gates (gated on `ci.*` config keys).** Before the per-PR re-dispatch policy below, check the config keys in this order — both default to off (preserves pre-#323 behavior); flip them in `shipyard.config.json`'s `ci.*` block to engage:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
   # Read both keys once per poll (cheap — the helper short-circuits on cached defaults).
   skip_rebase=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get \
     ci.skip_drain_rebase 2>/dev/null || echo "false")
   max_rebases=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get \
     ci.max_drain_rebases 2>/dev/null || echo "null")

   # 2a. Skip-all gate. `skip_drain_rebase: true` wins over `max_drain_rebases`
   # — when both are set the cap is moot.
   if [ "$skip_rebase" = "true" ]; then
     # Every D_dirty PR gets surfaced in the end-of-session summary as "needs
     # manual rebase" instead of consuming one full CI suite per force-push.
     # Increment counter once per PR per poll where it WOULD have dispatched.
     for pr in $D_dirty; do
       ci_session_counters.drain_rebases_skipped=$((ci_session_counters.drain_rebases_skipped + 1))
       echo "[drain] PR #$pr DIRTY but ci.skip_drain_rebase=true; surfacing in summary instead of dispatching rebase. (#323)"
     done
     # Do NOT dispatch any fix-rebase worker this poll. fix-checks dispatches
     # from action 1 above still proceed (red PRs remain urgent).
     # Move on to action 3 (bookkeeping).
   else
     # 2b. Soft-cap gate. When max_drain_rebases is non-null, dispatch only the
     # top-N PRs (lowest PR number first — matches drain.md's deterministic
     # ordering) and surface the rest. The cap is per-session (across all polls)
     # — track total fix-rebase dispatches in ci_session_counters.drain_rebases_dispatched.
     if [ "$max_rebases" != "null" ]; then
       remaining_cap=$((max_rebases - ci_session_counters.drain_rebases_dispatched))
       if [ "$remaining_cap" -le 0 ]; then
         for pr in $D_dirty; do
           ci_session_counters.drain_rebases_skipped=$((ci_session_counters.drain_rebases_skipped + 1))
           echo "[drain] PR #$pr DIRTY but ci.max_drain_rebases cap ($max_rebases) reached; surfacing in summary. (#323)"
         done
         # Skip the per-PR re-dispatch loop entirely this poll.
       else
         # Dispatch the first $remaining_cap PRs from D_dirty (already sorted
         # lowest-first per the drain spec). Increment drain_rebases_dispatched
         # once per dispatch — NOT once per `rebased` return — so the cap
         # bounds CI cost regardless of outcome.
         D_dirty_to_dispatch=$(echo "$D_dirty" | head -n "$remaining_cap")
         D_dirty_to_skip=$(echo "$D_dirty" | tail -n "+$((remaining_cap + 1))")
         for pr in $D_dirty_to_skip; do
           ci_session_counters.drain_rebases_skipped=$((ci_session_counters.drain_rebases_skipped + 1))
         done
         # Replace D_dirty with the dispatchable subset for the rest of this action.
         D_dirty="$D_dirty_to_dispatch"
       fi
     fi
     # Continue to the normal per-PR re-dispatch policy below with the
     # (possibly truncated) D_dirty set.
   fi
   ```

   The two gates are intentionally distinct: `skip_drain_rebase: true` is the "I'd rather see DIRTY PRs in the summary than burn CI" stance; `max_drain_rebases: <N>` is the "rebase the top-N and surface the rest" compromise. Most cost-conscious operators on repos with expensive E2E will pick one or the other; a few will set both (in which case `skip_drain_rebase` wins).

   Fix-checks dispatches in action 1 above take priority — a red PR is more urgent than a stale base. After filling the pool with fix-checks workers, any remaining slots dispatch fix-rebase workers from the (possibly cap-truncated) `D_dirty` set (lowest PR number first, so dispatch order is deterministic across re-dispatches). The per-PR re-dispatch policy splits by return outcome:

   - **`blocked rebase #<M>: <reason>`** — add `<M>` to `rebase_blocked_prs`. Do NOT re-dispatch this session even if the PR is still DIRTY at subsequent polls; the same conflict will produce the same outcome. The drain's settled definition counts `rebase_blocked_prs` membership as settled so the PR doesn't keep the drain alive forever.
   - **`rebased #<M>`** — increment `rebase_success_counts[<M>]` by 1 (initialize to 0 if absent). Do NOT add to `rebase_blocked_prs`. If the PR transitions DIRTY again later in the session (sibling merge re-introduced the conflict), it re-enters `D_dirty` and gets re-dispatched **as long as** `rebase_success_counts[<M>] < 3`. At the cap (3 successful rebases on one PR in one session), the PR is treated as settled: log `[drain] PR #<M> hit rebase-cap (3 successful rebases); deferring to next session — merge train advancing faster than rebase can keep up` and skip future re-dispatches.
   - **`noop: not dirty (<reason>)`** — no bookkeeping change. The PR transitioned out of DIRTY between dispatch and pre-flight (a parallel auto-merge landed it, or the rollup flipped to red and the agent correctly bailed because rebase isn't the right tool). Don't increment either counter; the drain's next poll will re-classify the PR's state from scratch.
   - **`errored`** — no bookkeeping change (matches the existing pattern for transient worker errors). The PR may re-enter `D_dirty` on the next poll and get re-dispatched naturally.

   This split fixes the merge-train race documented in [#265](https://github.com/mattsears18/shipyard/issues/265): a successful rebase followed by a sibling merge re-introducing DIRTY is a winnable race, NOT a stuck state. Capping at 3 successful rebases keeps the worst-case cost bounded (≤3 Haiku-pinned dispatches per PR per session) while letting normal merge-train races resolve on their own.
3. Update the per-PR `head_unchanged_since` map (reset on head movement, else leave `since` untouched — see the [Initial snapshot](#drain-protocol) structure) and the in-flight worker counts (fix-checks + fix-rebase combined). `M_since_last` feeds the status line's `merged_this_poll` token; termination no longer reads a rolling no-progress window (it's per-PR settle now, issue [#374](https://github.com/mattsears18/shipyard/issues/374)).
4. Print one drain status line per poll:
   ```
   [drain] open=<O> merged_this_poll=<M_since_last> newly_red=<R_new> dirty=<D_dirty> blocked_ci=<B> rebase_blocked=<|rebase_blocked_prs|> rebase_capped=<count of PRs where rebase_success_counts[<pr>] >= 3> in_flight=<n>(fix-checks=<a>, fix-rebase=<b>) · elapsed=<MM:SS>/<max_drain_hours>h
   ```

   `rebase_capped` is the count of PRs that hit the 3-successful-rebase rate-limit cap — distinct from `rebase_blocked` because the failure mode is different (race against a fast merge train, not a deterministic conflict). Both classes show up in the end-of-session summary as still-DIRTY PRs needing the next session's attention. The `elapsed` token now carries the `max_drain_hours` ceiling as its denominator so the operator can see how much of the ultimate budget is consumed (issue [#374](https://github.com/mattsears18/shipyard/issues/374)).

   **Per-PR progress detail (issue [#374](https://github.com/mattsears18/shipyard/issues/374)).** For each still-pending PR (member of neither merged/closed nor `blocked:ci`), print one indented follow-on line so the operator can watch the progress signal that determines settle:

   ```
       PR #<M>: head unchanged <H>m / <settled_minutes>m settled-threshold (checks: <pending|green|dirty>)
   ```

   `<H>` is `now - head_unchanged_since[<M>].since` in whole minutes. A PR that crosses `settled_minutes` reads e.g. `head unchanged 21m / 20m settled-threshold` and is now a member of `P_settled`. This is the "bonus" surface the issue asked for — it makes the otherwise-invisible head-movement clock legible while drain works.

**Termination criterion (progress-based, issue [#374](https://github.com/mattsears18/shipyard/issues/374)).** The exit signal is **per-PR progress**, not the wall clock. Drain continues as long as **any** PR in `session_prs` is NOT yet settled — i.e. **any** of these is true:

- Any fix-checks OR fix-rebase worker is in flight, OR
- Any PR is still open with a non-`blocked:ci` rollup AND its head commit has moved within the last `settled_minutes` (it's actively churning — fresh push, rebase force-push, or a check transition that re-triggered the head), OR
- Any PR is open, not `blocked:ci`, not in `rebase_blocked_prs`, not rate-limit-capped, and its checks have not been pending-with-unmoved-head for `settled_minutes` yet (it hasn't crossed the settle threshold).

Drain terminates the moment **every** PR in `session_prs` is settled AND no fix-checks / fix-rebase worker is in flight. A PR is settled per the [settled definition above](#drain-protocol): merged/closed, `blocked:ci`, in `rebase_blocked_prs`, rate-limit-capped (`rebase_success_counts[<pr>] >= 3`), or in `P_settled` (pending with `headRefOid` unchanged for `settled_minutes`). There is **no fixed 5-poll no-progress window** anymore — the per-PR `settled_minutes` head-movement threshold subsumes it. A multi-PR merge train with full E2E sharding + release-please cascades that legitimately takes >2h to land is no longer cut off mid-flight, because each PR stays unsettled exactly as long as its head keeps moving (rebases re-DIRTY-ing siblings keep resetting the clock); drain exits only once the train has genuinely gone quiet for `settled_minutes` per PR.

**Ultimate ceiling: `max_drain_hours` (config `ci.max_drain_hours`, default 8h).** As a belt-and-braces safety net against degenerate cases (a runaway CI loop, an infinite rebase that keeps moving the head every poll so no PR ever settles), drain forcibly exits once total drain elapsed exceeds `max_drain_hours`, even if forward progress is still observable. This replaces the old hardcoded 120-min ceiling (issue [#374](https://github.com/mattsears18/shipyard/issues/374)) — the old value fired on wall-clock time alone, killing healthy-but-slow merge trains; the progress-based exit above is now the primary path and `max_drain_hours` is the rarely-hit outer bound. Surface a ceiling exit in the summary as `drain exited at max_drain_hours ceiling (<X>h) — <n> PRs still pending`.

**On exit, regardless of how drain terminated**: report the final state of every PR in `session_prs` in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary), separated by status (merged ✓ / blocked:ci / still-pending). The user can re-run `/do-work` later to sweep what's left.

### When drain catches a systemic CI failure

**The drain phase classifies into `P_failing` PRs but does NOT dispatch a fix-checks-only worker against them.** That dispatch is steady-state-only — drain's [Per-poll actions](#drain-protocol) above explicitly fill `failed_prs` from `R_new` and dispatch fix-checks workers against newly-red PRs, but the dispatch loop's resolution window closes at drain entry; once drain is active no new fix-checks-only workers are spawned for PRs that were already failing at drain entry (only for PRs that go red *during* drain via `R_new`). The asymmetry is intentional: drain is the "wind-down, let the merge train settle" phase, and a fix-checks-only worker takes 5–20 min to resolve a checks failure — exactly the cost drain is trying to bound.

The settled paths for a `P_failing` PR are:

1. **Auto-resolve on rerun (lucky).** A transient infrastructure flake (network blip, runner cancellation, opportunistic timeout) resolves itself on the next CI scheduler tick. The drain's per-poll snapshot sees the rollup flip green and the PR proceeds through `auto-merge` normally.
2. **Hit `blocked:ci`.** The steady-state 3-attempt fix-checks-only circuit breaker has already stamped this PR; drain treats `blocked:ci` PRs as **settled** in the [termination criterion](#drain-protocol) so they don't keep the drain alive forever.

**The gap.** When the failure is **systemic** rather than per-PR — a 20-min GitHub Actions job timeout on a shard, a runner-pool exhaustion cancellation, a `concurrency: cancel-in-progress` flap, a flaky test that fails ≥50% of runs — neither path closes the loop. Path 1 is unreliable (the rerun hits the same systemic ceiling), and path 2 requires the steady-state fix-checks-only worker to have run first; if the PR ENTERED drain with checks failing for systemic reasons, no fix-checks worker ever stamps `blocked:ci` (the stamp is the worker's exhaustion signal, not the orchestrator's). The PR sits OPEN with no `blocked:ci` label and no path to resolution within the session.

**Today's escape valve.** The user can intervene mid-drain by running `gh run rerun --failed --repo <owner/repo> <run-id>` against the failing run. If the systemic failure was actually transient (an infra blip), the rerun succeeds and the PR settles via path 1. If it wasn't, the rerun fails the same way and the PR rolls forward to next session — at which point steady-state's fix-checks-only worker can dispatch normally and either fix the systemic issue (bump `timeout-minutes`, split the shard, mark the test `.skip` with a follow-up issue) or exhaust to `blocked:ci`. The user-visible signal that a session hit this gap is a `P_failing` PR in the end-of-session summary's "still-pending" cohort with no `blocked:ci` label.

**Filing follow-up issues.** When this gap traps a session, file an issue against the **target repo** (not against shipyard) describing the systemic failure (e.g., "Web E2E shard 2/3 hits 20-min job timeout — split the shard or bump `timeout-minutes`"). Reference the trapped PR. The follow-up issue is the durable record that this isn't a per-PR test bug but an infrastructure decision that needs a human or a future steady-state session.

**Why this gap is documented but not closed.** Two larger options would close it but expand drain's behavioral surface materially:

- **Option (2): Allow one fix-checks-only dispatch from drain when ALL other queues are empty.** Bounded — only fires if `divert_queue + failed_prs + ready_issues + raw_backlog == 0` and the drain has a `P_failing` PR. Mitigates the "human has to do this anyway" path but adds a new dispatch surface to drain that the wind-down framing doesn't currently allow.
- **Option (3): Pattern-match failure logs for known systemic shapes** (job timeouts, runner cancellations, `cancel-in-progress` flaps) and surface them in the end-of-session summary as a distinct cohort so the user knows it's an infra issue, not a test bug. Larger scope; needs a log-parsing surface that doesn't exist today.

Both options are tracked as follow-up work to [#359](https://github.com/mattsears18/shipyard/issues/359) — file a fresh issue when implementing either. The current documentation closes the spec gap (a reader, LLM or human, can now see plainly that drain doesn't dispatch fix-checks-only and what the escape valves are) without committing to a behavioral change that needs its own design pass.
