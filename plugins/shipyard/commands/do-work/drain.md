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

**Two distinct conditions — don't conflate them ([#662](https://github.com/mattsears18/shipyard/issues/662)).** Emptying the *dispatch pool* (all queues empty, live backlog returns no net-new candidate) ends the **dispatch loop** and hands off to the drain — it does **not** complete the session. **Session completion** is the stronger condition the drain drives toward and asserts at exit:

> The session is complete only when **every open workable issue is closed or dispositioned** — merged via its resolving PR, or labeled to a genuine human/operator review class (`needs-human-review` / `needs-operator` / `needs-triage`) — **AND every PR this session opened is merged**, or blocked on a confirmed **external dependency** the agent cannot itself perform (a secret value only a human can supply, an upstream release, a provider-console action). Those genuine external dependencies are the **only** legitimate residual stopping points. A PR that is merely red, DIRTY, or slow is not "complete" — it is unfinished tail the drain must keep driving toward merge.

The four-step assertion below is the **dispatch-pool-empty gate** — the precondition for the orchestrator to stop dispatching new workers and enter the [end-of-session drain](#end-of-session-drain). It is necessary but **not sufficient** for session completion: the drain is where the completion condition above is pursued (drive the tail) and ultimately asserted, or where a **bounded-exit concession** is recorded when a PR can't be driven to merge within the session's safety bounds (see [End-of-session drain](#end-of-session-drain) → Completion vs bounded-exit). Do not treat passing the four-step assertion as "session done."

**Any end-of-session follow-up/friction-issue filing runs BEFORE this assertion, never after — and never during or after [cleanup](./cleanup-summary.md#end-of-session-cleanup) ([#743](https://github.com/mattsears18/shipyard/issues/743)).** Some operator conventions (e.g. a maintainer's global instructions) direct the orchestrator to file GitHub issues for friction the session hit — spec gaps, misclassifications, ambiguous contracts — before considering the session done. Because the [`dont.md`](./dont.md) rule ["don't hand a workable issue to the human"](./dont.md) applies to *every* workable issue including ones this session just filed, a friction issue filed after the four-step assertion has already passed is itself a fresh workable candidate the loop is now obligated to dispatch — but if that filing happens after [cleanup](./cleanup-summary.md#end-of-session-cleanup) has already flushed the cost ledger (`cost-history.sh flush`) and retired the session-state file (`session-state.sh cleanup`), the resulting dispatch runs with no durable session record to attribute its tokens to, and the ledger silently under-reports the session by however much that dispatch cost (see [issue #743](https://github.com/mattsears18/shipyard/issues/743) for the repro — a session's own follow-up issue and its ~250k-token resolving PR were entirely absent from the flushed ledger line). File any such issues **before** running the four-step assertion below, in the same turn the friction was identified — the assertion's own step 4 fresh-fetch (below) will then naturally pick up what was just filed as a net-new candidate and loop back through dispatch rather than terminating around it, closing the loop the ordinary way instead of needing a special case. If a friction issue is discovered mid-drain (after the assertion has already passed once), file it immediately and let [step 5's re-validation](#pre-drain-re-validation-of-deferred-entries) and the drain's own polling naturally re-admit it — do not defer the filing to "after this session wraps up." A related, narrower mechanism exists too: `session-state.sh bump-tokens --allow-degraded-init` self-heals a missing session file if a dispatch somehow still lands post-cleanup despite this ordering (see [cleanup-summary.md](./cleanup-summary.md#end-of-session-cleanup) for the re-entrancy safety net) — but that is defense in depth, not a substitute for filing before the assertion runs.

Before handing off to the drain (which then drives the tail → cleanup → summary → exit), the orchestrator MUST run the following four-step assertion **in order**. Each step is a thing-to-do, not a thing-to-assert-against-stored-state — step 4 in particular must execute the live `gh` query, not infer the result from cached `raw_backlog` size.

1. **`in_flight` is empty.** Check from working memory (the [orchestrator-state struct](../do-work.md#orchestrator-state) `in_flight` map). If non-empty, do NOT proceed — return control and let the existing in-flight workers finish; this step re-runs on the next completion notification.
2. **`failed_prs` is empty.** Check from working memory. If non-empty, fill the pool from `failed_prs` per [dispatch rule 2](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
3. **`ready_issues` is empty.** Check from working memory. If non-empty, fill the pool from `ready_issues` per [dispatch rule 3](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) and return control.
4. **Fresh-fetch verification.** Run the canonical step-4 backlog query **now** — against the live tracker, not stored state. **Use the same wide-fetch + client-side filter shape that [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) uses** (the previous narrower `-linked:pr` + `-label:...` server-side qualifiers were removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — they silently excluded resumable-work issues like prior-session self-assigns whose linked PR had been closed or never opened, producing premature "backlog empty → drain" handoffs):

   ```bash
   # Wide fetch — server-side filter is purely --state open. All
   # eligibility checks happen client-side (see setup.md step 4 for
   # the canonical client-side filter pass).
   gh issue list --repo <owner/repo> --state open --limit 200 \
     --json number,labels,assignees,body,author \
     --jq '[.[] | {number, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'
   ```

   Then apply the same client-side filter [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) applies — trusted-author check, dispatch-gate labels (`blocked:ci`, `wontfix`, `needs-triage`, `discussion`, `needs-human-review`, `needs-operator` (the operator-action gate added in [#608](https://github.com/mattsears18/shipyard/issues/608) — excluded from code-worker dispatch; drained by the operator phase by default, disabled under `--no-operate` / `--hands-off`) — `blocked:agent-hard` and the legacy `blocked:agent` were eliminated per [#521](https://github.com/mattsears18/shipyard/issues/521): refuses now carry `needs-human-review` and dependency-waits carry no label (gated by the `Blocked by #N` still-open check below), so neither appears here; `needs-design` was folded into `needs-human-review` per [#515](https://github.com/mattsears18/shipyard/issues/515), the `needs-decomposition` / `tracking` epic-decomposition pair per [#519](https://github.com/mattsears18/shipyard/issues/519), and `needs-refinement` was eliminated entirely per [#520](https://github.com/mattsears18/shipyard/issues/520) — refinement is now a pre-dispatch source-signal scan, leaving no persisted gate state to exclude here), assignee≠@me, `Blocked by #N` still-open, closed-by-@me-authored-healthy-PR — and project the result to a sorted number list for the diff below. Read the client-side filter directly from setup.md's spec; never re-derive it in this file (the two MUST stay in lockstep — that's exactly the bug [#332](https://github.com/mattsears18/shipyard/issues/332) documented).

   Stamp `last_fresh_fetch` (the steady-state step E invariant-line token) with the current UTC timestamp the moment this call returns. Stamp `unfiltered_open_count` (the [steady-state step E invariant-line token added in #332](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn)) with the count returned by the wide fetch BEFORE the client-side filter runs — this is the surface the user (and the next session's orchestrator) reads to spot a "raw_backlog=0 but unfiltered_open_count=29" smell that would otherwise hide a regression in the client-side filter itself. Subtract the union of `in_flight` (target numbers), `ready_issues` (numbers), `raw_backlog` (numbers), `deferred_issues` (issue numbers), and any issues closed earlier this session (via PR auto-close) from the post-filter list. If the resulting net-new set is **non-empty**, append the new numbers to `raw_backlog` in priority order (same ranking as step 4), run scope-refill via step D, and retry dispatch from [steady-state step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action). **Do NOT proceed to drain.** If the set is empty, all four steps have passed — proceed to the [end-of-session drain](#end-of-session-drain) below.

   **The workable count is MECHANICAL, never discretionary ([#531](https://github.com/mattsears18/shipyard/issues/531)).** The post-filter list is produced by the [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) client-side filter alone — trusted-author check, dispatch-gate labels, assignee≠@me, `Blocked by #N` still-open, closed-by-@me-authored-healthy-PR — and **nothing else**. The orchestrator MAY NOT judgment-exclude a candidate from this list. "It's a follow-up I filed this session" / "it's a meta-issue about the orchestrator" / "it rewrites the reconcile path I'm running" / "feels like it should wait" are NOT filter criteria — none appears in the step-4 client-side filter, and none matches a [`defer_reason_class`](./setup/06-scope-preflight.md#6-initial-scope-pre-flight) (`external-dependency`, `human-decision-required`, `untrusted-author`, `confirmed-blocker-still-open`, `confirmed-non-shippable-as-single-PR`). An issue that passes the mechanical filter is workable; if the mechanical net-new count is **> 0**, the loop MUST NOT terminate — it MUST append the candidates to `raw_backlog` and dispatch. The only sanctioned ways off the dispatch queue are the five `defer_reason_class` defers (each re-validated by [step 5](#pre-drain-re-validation-of-deferred-entries) before drain fires) and the mechanical exclusions enumerated above; constructing an "empty net-new set" by quietly dropping mechanically-workable issues is the exact bypass [#531](https://github.com/mattsears18/shipyard/issues/531) documents (a session drained on workable self-filed follow-ups #529 / #530 because the orchestrator judgment-excluded its own just-filed issues from "workable," then declared termination — forcing the maintainer to manually re-instruct it to finish them). See also the dont.md rule ["Don't hand a workable issue to the human"](./dont.md).

**The operator layer adds a fifth gate: `operator_queue` must be empty.** By default (the operator layer is on unless `--no-operate` / `--hands-off`), the loop has a second work-source the orchestrator drains itself (the [operator phase](./operate.md)). Before declaring termination, the `operator_queue` must also be empty — if it holds any item, do NOT proceed to drain; drain the next item on the main thread (per [operate/01-queue-and-authorization.md](./operate/01-queue-and-authorization.md#draining)) and return control. The exception is the degraded path (no browser backend reachable): there the queue can't be drained, so its items are surfaced as hand-backs in the end-of-session summary and do **not** block termination. Under `--no-operate` / `--hands-off`, `operator_queue` is always empty and this gate is a no-op.

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
   - If **no** (the reason is a free-form judgment, not a named blocker): **dispatch a scope agent** for this issue now — but **first re-run the [pre-scope orchestrator-side detector batch](./setup/06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers) from setup.md step 6** against the issue body. If any detector fires, synthesize the deferred entry directly (skip the scope-agent dispatch) and leave the entry in `deferred_issues` with the fresh synthesized fields — same behavior as the initial pre-flight, applied to re-validation. This keeps the detector load-bearing across both call sites; without re-running it here, a re-validation that dispatches a scope agent against a body the detector batch guards (a `.github/workflows/`-proposing body, a `.claude/settings.json` / `.claude/settings.local.json` / `.mcp.json` / `.claude/hooks/`-proposing body, or any future detector's target) would likely return `ready` (the scope agent has no detector built in) and immediately reproduce the orphan-branch / classifier-denial failure mode the detector exists to prevent. (Detector 2's matched path set is config-driven via `scope.self_modification_paths` and includes `.claude/hooks/` by default — issue [#591](https://github.com/mattsears18/shipyard/issues/591); the re-run resolves the same effective array.) If no detector fires, dispatch the scope agent normally:
     ```
     [Dispatch scope agent for issue #<N> — pre-drain re-validation of orchestrator-judgment defer]
     ```
     - If the scope agent returns a **deferred shape**: update the entry's provenance to `"scope-agent"` (now it's authoritative). Leave in `deferred_issues`. **Important:** the entry now belongs to the 5.b cohort going forward; it does NOT get re-run by 5.b in the same pre-drain pass (one re-validation per entry per pass), but a subsequent pre-drain entry (e.g. a future session) would treat it as a scope-agent defer.
     - If the scope agent returns a **ready shape**: remove from `deferred_issues`, push into `raw_backlog`. Log: `[pre-drain-revalidate] #<N> was orchestrator-judgment deferred but scope agent found it ready; returned to raw_backlog`.

#### 5.b — Re-validate `scope-agent` and `cached-diagnosis` entries

For each entry in `deferred_issues` where `provenance == "scope-agent"` OR `provenance == "cached-diagnosis"` (excluding any entry that just got promoted to `scope-agent` provenance by 5.a — those have a fresh scope agent return and don't need another one in this pass):

**First re-run the [pre-scope orchestrator-side detector batch](./setup/06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers) from setup.md step 6** against the issue body. If any detector fires, synthesize the deferred entry directly (skip the scope-agent dispatch) and update the existing entry's `reason`, `defer_reason_class`, `evidence_pointer`, `provenance` (set to `"orchestrator-judgment"` since the detector — not a scope agent — produced the fresh determination), and `deferred_at` to the synthesized values. The entry stays in `deferred_issues`; log `[pre-drain-revalidate] #<N> pre-scope detector re-confirmed defer (class=<defer_reason_class>, evidence=<evidence_pointer>) — <fresh reason>`. This is the same defense-in-depth posture as 5.a's detector re-run — a body that proposes a change to any path the detector batch guards (workflow files, Claude-Code self-modification targets, or future detectors) should never be promoted back to `raw_backlog` via re-validation, regardless of the original defer's provenance.

**If no detector fires, check the freshness carve-out before dispatching a scope agent.** Skip the scope-agent dispatch and re-validate mechanically when ALL THREE of the following are true. Two tiers apply based on whether the entry is same-session or cross-session:

**Tier 1 — Same-session carve-out** (issue [#549](https://github.com/mattsears18/shipyard/issues/549)): applies when `entry.deferred_at >= session.started_at`.

**Tier 2 — Cross-session diagnosis-reuse window** (issue [#563](https://github.com/mattsears18/shipyard/issues/563)): applies when `entry.deferred_at < session.started_at` AND `entry.provenance == "cached-diagnosis"` (an entry recorded by a prior session's scope-result freshness check) AND `now_utc - entry.deferred_at < scope.diagnosis_reuse_hours` (config knob, default 72h). **`scope-agent`-provenance cross-session entries are NOT eligible for Tier 2** — the `cached-diagnosis` provenance is the explicit signal that the entry originated from a comment reuse path, not from a real scope agent; re-validating a prior scope-agent return cross-session requires a fresh agent pass per the original [#549](https://github.com/mattsears18/shipyard/issues/549) rationale (phase-slicing bias, main may have advanced).

For entries that qualify under either tier, skip the scope-agent dispatch and re-validate mechanically when ALL THREE of the following are true:

1. **The entry is within the applicable freshness tier** (Tier 1: same-session; Tier 2: `cached-diagnosis` provenance + within `scope.diagnosis_reuse_hours`).
2. **`entry.evidence_pointer` re-validates mechanically right now.** Run the same per-class shape check from [setup.md step 6's per-class validator](./setup/06-scope-preflight.md#per-class-evidence-shapes--what-evidence_pointer-must-look-like) against the existing `evidence_pointer`, then run the cheap class-specific ground-truth probe:
   - `confirmed-blocker-still-open` → re-run `gh issue view <N> --repo <owner/repo> --json state -q .state` (and/or `gh pr view`) for each `#N` reference in the pointer; all cited blockers must still be `OPEN`.
   - `external-dependency` → shape check only (no speculative-judgment words in the pointer).
   - `human-decision-required` → shape check only (no speculative-judgment words; specific decision named — or the structured `Proposes .github/workflows/` / `Proposes .claude/` prefix from the pre-scope detectors, which are already re-confirmed by the detector batch above).
   - `untrusted-author` → shape check only (`author: <login>` present in the pointer with a valid login format).
   - `confirmed-non-shippable-as-single-PR` → shape check only (pointer starts with one of the four structural prefixes: `Missing dependency:` / `Multi-service coordination:` / `Multi-PR sequence:` / `Body cites <artifact>:`).
3. **The issue body has not been amended since the defer** — fetch `gh issue view <N> --repo <owner/repo> --json updatedAt -q .updatedAt` and confirm the returned timestamp precedes `entry.deferred_at`. An amendment between the defer and now means the original diagnosis is potentially stale, so the carve-out does not apply.

If all three pass → keep the entry in `deferred_issues` as-is. Log (Tier 1): `[pre-drain-revalidate] #<N> same-session freshness carve-out — mechanical re-validation confirmed (class=<entry.defer_reason_class>, evidence=<entry.evidence_pointer>); scope-agent dispatch skipped`. Log (Tier 2): `[pre-drain-revalidate] #<N> cross-session diagnosis-reuse — cached-diagnosis entry is <age>h old (window: <window>h), evidence re-validated; scope-agent dispatch skipped`. Do NOT bump `deferred_at` in either case (the field records when the original defer was recorded; the carve-out is a confirmation, not a new defer). Move on to the next entry.

If any of the three conditions fails → fall through to the scope-agent dispatch path below. Log one line naming the failing condition:
- Condition 1 fails (cross-session scope-agent provenance): `[pre-drain-revalidate] #<N> freshness carve-out skipped — entry is from a prior session with scope-agent provenance (deferred_at <entry.deferred_at>); dispatching scope agent`
- Condition 1 fails (cross-session cached-diagnosis, window expired): `[pre-drain-revalidate] #<N> freshness carve-out skipped — cached-diagnosis entry is <age>h old (window: <window>h); dispatching scope agent`
- Condition 2 fails: `[pre-drain-revalidate] #<N> freshness carve-out skipped — evidence_pointer mechanical re-validation failed (<specific reason>); dispatching scope agent`
- Condition 3 fails: `[pre-drain-revalidate] #<N> freshness carve-out skipped — issue body updated at <updatedAt> after defer at <entry.deferred_at>; dispatching scope agent`

**Why the carve-out is safe.** The three conditions together close the gap the full scope-agent re-dispatch is designed to cover. Condition 1 (Tier 1) excludes cross-session `scope-agent` entries — the justifications for why a fresh scope-agent pass produces new answers ("main may have advanced since", "audit data may have aged", "original agent may have been permissively-conservative on a body that's tractable on second look") are all cross-session arguments; they do not apply to a same-session defer where the original agent ran minutes ago under the same prompt. Condition 1 (Tier 2) admits cross-session `cached-diagnosis` entries within the reuse window — these entries explicitly record that a prior session found a fresh comment and skipped the agent, so the same rationale that made the skip safe at scope-preflight time still applies until the comment ages out. Condition 2 re-proves the defer's mechanical grounding right now (the blocker is still open, the pointer still passes shape validation) — the exact checks the scope agent would perform if it ran and returned the same deferred shape. Condition 3 catches the only event that would genuinely make the diagnosis stale: an amendment between the diagnosis and the pre-drain re-validation. All three together are equivalent to "the scope agent, re-run now, would reach the same conclusion" — so the dispatch adds cost without correctness gain. The #299 drain-on-misjudged-defers protection stays fully intact for cross-session `scope-agent` entries (condition 1 fails → scope-agent dispatch runs, same as before), for expired cached-diagnosis entries, and for entries whose evidence has shifted or whose issue body was amended.

**Dispatch a fresh scope agent** for entries that do not qualify for the carve-out. The original scope-agent return reflected the issue's state at scope time; main may have advanced since (a sibling PR landed, a blocker resolved, a dep updated), the audit data may have aged, or the original scope agent may have been permissively-conservative on a body that's tractable on second look. The phase-slicing bias documented in [setup.md step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight)'s prompt instruction means a fresh scope agent will actively look for a phase-1 slice that the original agent — even if running against the same body — might have missed; this is the load-bearing reason re-validation produces different answers than the first scope pass even when the issue's body hasn't changed. A fresh scope pre-flight is the same mechanism 5.a uses for free-form orchestrator-judgment defers, and the same authoritative answer applies:

```
[Dispatch scope agent for issue #<N> — pre-drain re-validation of scope-agent defer]
  Original defer reason: <entry.reason>
  Original defer_reason_class: <entry.defer_reason_class>
  Original evidence_pointer: <entry.evidence_pointer>
  Would_be_dispatchable_as_phase_1_if (from original defer): <entry.would_be_dispatchable_as_phase_1_if or "not provided">
  Pass through to the scope agent so it can check whether the unblocking condition has resolved.
  The fresh defer (if any) MUST supply a new evidence_pointer — the orchestrator validates it the same way as the original (per-class shape check in setup.md step 6).
```

- If the scope agent returns a **ready shape** (with or without `phase_1_scope`): remove from `deferred_issues`, push into `raw_backlog`. **If the entry's `defer_reason_class` was `confirmed-non-shippable-as-single-PR`, also remove the `needs-human-review` surfacing label** ([#498](https://github.com/mattsears18/shipyard/issues/498); re-keyed from the former `needs-decomposition` label to `needs-human-review` by [#519](https://github.com/mattsears18/shipyard/issues/519)'s binary-backlog fold) — `gh issue edit <N> --repo <owner/repo> --remove-label needs-human-review 2>/dev/null || true`. The original defer applied that label (per [setup.md step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight)'s Deferred recording path); a fresh scope agent finding the issue ready means the original was a slicing miss, not a true unsliceable epic, so the surfacing label must come off or the issue would stay hidden from both the dispatch queue (it's in the step 4 exclusion set) and re-admission would be a no-op. The `<!-- do-work-needs-decomposition -->` trigger marker comment can be left in place — it's harmless once the label is gone, because [`/decompose-epic`'s candidate fetch](../decompose-epic.md#3-fetch-candidates) filters on the `needs-human-review` label *first* and only then on the marker, so a marker-without-label issue is never re-picked as a decomposition candidate. (This removal is gated on `defer_reason_class == "confirmed-non-shippable-as-single-PR"` precisely because `needs-human-review` is now a shared binary-backlog gate — only the epic-handoff defer class applied it via this path, so a class-gated `--remove-label` won't strip a `needs-human-review` an issue carries for an *unrelated* reason. The other four defer classes never applied `needs-human-review` through step 6, so the `--remove-label` is correctly skipped for them.) The candidate is re-scoped by the next dispatch via step C's normal flow; the `phase_1_scope` field — if present — flows through to the worker prompt as documented in [setup.md step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight)'s ready-entry handling. Log: `[pre-drain-revalidate] #<N> was scope-agent deferred but fresh scope agent found it ready<scope-suffix>; returned to raw_backlog<label-suffix>`. The `<scope-suffix>` is ` (as phase-1 slice: <phase_1_scope>)` when the fresh return supplied one, empty otherwise; the `<label-suffix>` is ` (removed needs-human-review)` when the original class was `confirmed-non-shippable-as-single-PR`, empty otherwise.
- If the scope agent returns a **deferred shape**: run the [per-class `evidence_pointer` validator from setup.md step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight)'s Deferred-entries handler against the fresh return. If the new `evidence_pointer` fails validation, treat the fresh return as malformed: remove the entry from `deferred_issues`, push the issue back into `raw_backlog`, and log `[pre-drain-revalidate] #<N> scope-agent re-validation returned malformed defer (evidence_pointer "<pointer>" failed per-class shape check) — promoted to raw_backlog for fresh scope pass`. This closes the loophole where a re-validation could re-confirm a defer with stale speculative evidence indefinitely. If the new `evidence_pointer` validates, leave the entry in `deferred_issues` and update `reason`, `defer_reason_class`, `evidence_pointer`, and `would_be_dispatchable_as_phase_1_if` to the fresh return's values (the old fields may be stale; the new ones are the current authoritative diagnosis), then bump `deferred_at` to the current timestamp. Log: `[pre-drain-revalidate] #<N> scope-agent re-confirmed deferred (class=<defer_reason_class>, evidence=<evidence_pointer>) — <fresh reason>`. **Then run setup.md step 6's [inline auto-decompose (Recording path step 5)](./setup/06-scope-preflight.md#handling-each-returned-entry-fires-as-each-background-agent-completes) on the re-confirmed defer** ([#665](https://github.com/mattsears18/shipyard/issues/665)) — when the re-confirmed class is `confirmed-non-shippable-as-single-PR`, the `evidence_pointer` prefix is mechanically decomposable (`Multi-PR sequence:` / `Missing dependency:`), and `decompose.auto` is true, inline-invoke the `/decompose-epic` worker logic (same single source of truth) rather than re-parking the epic for a manual run; on any escalate/blocked/non-mechanical/opt-out outcome the epic stays the recorded `needs-human-review` handoff, unchanged. (The 5.a scope-agent-returns-deferred branch above routes through the same step-5 handling when it records a mechanical `confirmed-non-shippable-as-single-PR` defer.)

The cost of 5.b is **at most** one scope-agent invocation per entry that reaches the pre-drain check — bounded by `|deferred_issues with scope-agent or cached-diagnosis provenance that do NOT qualify for either freshness carve-out tier|`. Same-session entries (Tier 1) and cross-session `cached-diagnosis` entries within the reuse window (Tier 2) are handled in microseconds with a `gh issue view --json updatedAt` call instead of a full ~40k-token scope-agent dispatch. The full scope-agent re-dispatch still fires for cross-session `scope-agent` entries, for expired `cached-diagnosis` entries, and for any entry whose evidence has shifted or whose issue body was amended. The #299-drain-on-misjudged-defers protection is fully intact for all non-carve-out entries. The cross-session `cached-diagnosis` Tier-2 extension ([#563](https://github.com/mattsears18/shipyard/issues/563)) legalizes the cost-discipline skip that the original session already documented as a deviation — the prior session found a fresh comment and recorded `cached-diagnosis`; the drain session honors that finding within the configured window rather than spending the same agent cost to re-derive the same conclusion again.

#### 5.c — After processing all entries

After both 5.a and 5.b have run:

1. If `raw_backlog` gained any issues from either branch: run scope-refill via step D and retry dispatch from steady-state step C. **Do NOT proceed to drain.** The termination assertion (steps 1–4 above) must pass again.

2. If no issues were re-admitted (all defers were confirmed still-valid by their respective re-validation): emit the **pre-drain audit banner** and proceed to drain:

   ```
   PRE-DRAIN AUDIT
       deferred_issues total: <N> (<M> added this session)
       of those, scope-agent-backed: <K> (re-validated: <Ka> scope-agent dispatch, <Kb> same-session mechanical, <Kc> cross-session diagnosis-reuse)  cached-diagnosis: <Kd> (re-validated: <Kd_skip> diagnosis-reuse, <Kd_full> scope-agent dispatch)  orchestrator-judgment: <J> (re-validated)
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

   In the `scope-agent-backed` line: `<Ka>` is the count of scope-agent entries that went through the full scope-agent re-dispatch; `<Kb>` is the count that qualified for the same-session freshness carve-out (Tier 1); `<Kc>` is the count that qualified for the cross-session diagnosis-reuse window (Tier 2 — scope-agent entries whose `cached-diagnosis` counterpart still within the window). In the `cached-diagnosis` line: `<Kd_skip>` is the count of `cached-diagnosis` entries mechanically re-validated within the window (no scope-agent dispatch); `<Kd_full>` is the count whose window expired and required a full scope-agent re-dispatch. Omit any count that is 0 to keep the banner terse. When all entries used full re-dispatch (all `<Kb>`, `<Kc>`, `<Kd_skip>` are 0), emit the shorter form `(re-validated via scope agent)` for the scope-agent-backed line and omit the cached-diagnosis line entirely.

   `defer_reason_class` is the load-bearing field added by [#298](https://github.com/mattsears18/shipyard/issues/298) — every `deferred_issues` entry MUST carry one of the five values above. An entry that reaches this banner without a class is a spec violation; the orchestrator MUST treat such entries as needing a fresh scope agent re-dispatch (same path as 5.b) before letting drain fire. `evidence_pointer` is the load-bearing field added by [#302](https://github.com/mattsears18/shipyard/issues/302) — every entry MUST carry a per-class-valid mechanical citation, and entries that survive 5.b have already been re-validated through the per-class shape check. An entry that reaches this banner without a non-empty `evidence_pointer` is also a spec violation (treat the same way: promote to `raw_backlog`, re-dispatch scope agent before drain fires). Omit any breakdown line whose count is zero to keep the banner terse on sessions with few defers.

   The banner is always emitted when step 5 ran — it is the audit trail for the user. When `deferred_issues` is empty (step 5 was a no-op), the banner is skipped (no audit needed — there was nothing to re-validate).

**Why this gate exists.** The termination assertion's step 4 subtracts `deferred_issues` numbers from the live backlog before checking net-new issues. This means the orchestrator can construct an "empty net-new set" entirely through self-defers — deferring every remaining workable issue (either through working-memory judgment or through a chain of conservative scope-agent returns), then declaring termination because the live backlog minus the deferred set is empty. The re-validation pass prevents this: before `drain.active` can flip, every defer must be confirmed against current state. See [RATIONALE → Pre-drain re-validation](../do-work-RATIONALE.md#pre-drain-re-validation-of-deferred-entries) for the sessions that motivated this rule ([#246](https://github.com/mattsears18/shipyard/issues/246) added the orchestrator-judgment branch; [#299](https://github.com/mattsears18/shipyard/issues/299) extended it to scope-agent entries).

**Drain-mode termination:** when `draining = true`, step 5 (both 5.a and 5.b) is skipped — drain mode is the user's "stop dispatching" signal, and re-evaluating deferred issues would contradict that intent.

Once the four-step assertion passes AND step 5 re-validation clears (or was a no-op), run end-of-session drain → cleanup → summary.

## End-of-session drain

Once the dispatch-pool-empty gate passes, some PRs may still be `pending` CI or waiting for auto-merge. **Don't terminate while the merge train is still draining.** The drain phase keeps the orchestrator alive past the dispatch loop's end and **drives the tail toward session completion** — every PR in `session_prs` to **merged**, or to a confirmed **external dependency** the agent cannot itself perform. Driving means keeping the merge train moving across polls: watching the merge train, re-triggering transient/flaky CI, dispatching fix-checks workers against newly-red PRs, rebasing DIRTY PRs onto the advancing base, and arming release PRs as their blockers land (the concrete auto-heal / dependency-update / release-arming *step mechanics* are phase c of #659, [#663](https://github.com/mattsears18/shipyard/issues/663); this phase defines the *contract* those mechanics satisfy). The drain polls until every session-opened PR reaches a completing terminal state or a bounded-exit concession (settled — progress-based per-PR head-movement quiescence, not a wall-clock window; issue [#374](https://github.com/mattsears18/shipyard/issues/374)) OR the `max_drain_hours` ceiling fires. See [RATIONALE → End-of-session drain](../do-work-RATIONALE.md#end-of-session-drain--why-it-exists-past-the-dispatch-loops-end).

### Drain protocol

**Initial snapshot.** Capture the set of PRs the orchestrator opened this session (`session_prs` — track this from step A's `shipped` reconciles throughout the run). These are the PRs whose status determines drain termination. Pre-existing PRs the orchestrator only fixed via fix-checks count too (they're authored by `@me` and shipyard touched them this session). Inherited `@me` PRs left `DIRTY`-but-green by a *prior* session are also in `session_prs` — they were adopted into this session's ownership set by [setup step 5.7](./setup/04-backlog-divert.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off) (or step D's failed-PR scan at C=1) so this drain's `D_dirty` classifier can dispatch a fix-rebase worker against them; closes [#373](https://github.com/mattsears18/shipyard/issues/373). PRs from other authors don't.

Also initialize three per-session structures that gate fix-rebase re-dispatch and progress-based termination:

- `rebase_blocked_prs = {}` — the per-session set of PR numbers that returned `blocked rebase` from a fix-rebase dispatch. A PR that blocks on rebase once doesn't get re-dispatched within the same session, even if it stays DIRTY — re-dispatching against a non-trivial conflict would just produce the same `blocked rebase` outcome and burn another worker. The set counts toward the drain's "settled" definition so a non-trivially-conflicted PR doesn't keep the drain alive indefinitely.
- `rebase_success_counts = {}` — a per-session map of `<pr-number> → <count>` tracking how many times each PR has returned `rebased` (NOT `blocked rebase`) from a fix-rebase dispatch this session. A successful rebase that gets undone by a subsequent sibling merge is a winnable race — the merge train can land the rebased branch if CI finishes faster than the next conflicting merge — so the per-poll dispatcher SHOULD re-dispatch fix-rebase against a PR that's gone DIRTY again. The map caps total cost at 3 successful rebases per PR per session (same number as the fix-checks 3-attempt circuit breaker); a PR that hits the cap is treated as "settled — merge train moving faster than rebase can keep up, defer to next session" and surfaced in the end-of-session summary as still-DIRTY.
- `head_unchanged_since = {}` — a per-session map of `<pr-number> → {oid, since}` tracking each open PR's last-observed `headRefOid` and the UTC timestamp it was first observed at that value (issue [#374](https://github.com/mattsears18/shipyard/issues/374)). This is the progress signal that replaces the old wall-clock ceiling: a PR whose head commit hasn't moved for `settled_minutes` (config `ci.settled_minutes`, default 20) is "settled" even if its checks are still pending — auto-merge is waiting on long-running CI, not stuck. Every poll, for each open PR: if its current `headRefOid` differs from the stored `oid` (or there's no stored entry), reset the entry to `{oid: <current>, since: <now>}`; otherwise leave `since` untouched. The PR's "head unchanged for" duration is `now - head_unchanged_since[<pr>].since`. A head-commit movement (a fresh push, a successful rebase force-push) resets the clock, so a PR actively being worked never counts as settled.

Read the two #374 duration knobs once at drain entry (they don't change mid-session):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
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

`mergeStateStatus`, `statusCheckRollup`, and `headRefName` / `headRefOid` are required for the `D_dirty` / `D_dirty_red` split below — `mergeStateStatus == "DIRTY"` signals a stale base, and the latest-per-name rollup determines whether the PR goes to fix-rebase (`D_dirty`, no hard failures) or fix-checks (`D_dirty_red`, has hard failures). The head-branch identifiers are passed into the fix-rebase prompt template. **Never classify a DIRTY PR as fix-rebase-eligible from `mergeStateStatus` alone** — always compute the rollup split (issue [#577](https://github.com/mattsears18/shipyard/issues/577)).

**Batching the per-PR refresh.** When the drain loop has already snapshotted the open-PR list (above) but needs to re-resolve per-PR fields *for a known subset* — e.g. the "did this `D_dirty` PR's `mergeStateStatus` flip to `CLEAN` since the previous poll, or did its `headRefOid` move?" check that powers the forward-progress rule below — use `plugins/shipyard/scripts/gh-batch.sh pr-status` instead of N sequential `gh pr view <M>`:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
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
- `D_dirty_red` = PRs whose `mergeStateStatus == "DIRTY"` AND have **at least one** hard-failure check **on the latest run per check name** AND are NOT carrying `blocked:ci` AND are not already in `in_flight` or `failed_prs`. These PRs need `fix-checks`, not `fix-rebase` — the rebase is useless until the check failures are resolved. They are routed to fix-checks directly in per-poll action 1 alongside `R_new` (see action 1 below and issue [#577](https://github.com/mattsears18/shipyard/issues/577)). **Never dispatch a fix-rebase worker against a PR in `D_dirty_red`** — the fix-rebase worker's own precondition check will bail with `blocked rebase: PR has failing checks` immediately, wasting a Haiku dispatch plus an extra orchestrator round-trip.
- `D_dirty` = PRs whose `mergeStateStatus == "DIRTY"` AND have **no** hard-failure check **on the latest run per check name** (rollup is fully `SUCCESS` / `SKIPPED` / `NEUTRAL` / `PENDING` / `IN_PROGRESS` / `QUEUED`) AND are NOT in `D_dirty_red` AND are NOT in `in_flight` AND are NOT in `rebase_blocked_prs` (the prior dispatch returned `blocked rebase` — re-dispatching would produce the same conflict) AND have `rebase_success_counts[<pr>] < 3` (PRs that have been successfully rebased 3 times in this session are rate-limit-capped and treated as settled — the merge train is advancing faster than rebase can keep up, defer to next session). A PR that was successfully rebased earlier this session and has since gone DIRTY again from a sibling merge IS in `D_dirty` as long as its success-count is under cap — a successful rebase doesn't gate future re-dispatches the way a `blocked rebase` does. The rollup check is load-bearing: a DIRTY PR with a failing check goes to `D_dirty_red` (→ fix-checks), not `D_dirty` (→ fix-rebase). **Always compute `D_dirty` using the latest-per-name rollup projection** — never classify a PR as fix-rebase-eligible based on `mergeStateStatus` alone (issue [#577](https://github.com/mattsears18/shipyard/issues/577)).
- `B` = PRs carrying `blocked:ci` (these are "settled — human needs to look")
- `P_settled` = PRs whose rollup is fully `PENDING` / `IN_PROGRESS` / `QUEUED` AND whose `headRefOid` has been unchanged for at least `settled_minutes` (i.e. `now - head_unchanged_since[<pr>].since >= settled_minutes` — auto-merge is waiting on long-running checks, not stuck; issue [#374](https://github.com/mattsears18/shipyard/issues/374)). Before #374 this was "unchanged since the *previous poll*" — a single 60s interval — which conflated "head hasn't moved for one minute" with "settled." A pending PR mid-CI-run trivially has an unchanged head between two adjacent polls; the `settled_minutes` threshold (default 20) is what distinguishes a healthy-but-slow merge train from a genuinely stalled one. First update `head_unchanged_since[<pr>]` (reset on head movement, else leave `since` untouched) so this comparison reads the freshly-maintained timestamp.

**Latest-per-name semantics for `R_new`, `D_dirty_red`, and `D_dirty`** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns every check run for the PR's head SHA — including superseded runs. A check that ran, failed, was re-triggered, and passed appears twice (one FAILURE entry + one SUCCESS entry). A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk would (a) keep already-fixed PRs in `R_new` forever, dispatching pointless fix-checks workers that return `noop: already green`, and (b) keep already-fixed PRs OUT of `D_dirty`, sending the drain-phase fix-rebase worker the false signal "this PR has failing checks — bail" when in fact it's green. Both failure modes were observed in lightwork session `c6afe19d-a6a6-40e4-9eb8-de409d046a49` against PRs #1193 and #1211. De-duplicate by check name and take the most recent entry per check (by `completedAt`, fallback `startedAt`):

```bash
# Latest-per-name failure count. Used by R_new (>0 means failing), D_dirty_red (>0 AND DIRTY → fix-checks),
# and D_dirty (==0 AND DIRTY → fix-rebase). Never classify a DIRTY PR as fix-rebase-eligible without this check.
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

**The failure mode.** A fresh drain-phase worker lands in its own isolated worktree, then runs the safe two-step (`git fetch origin <head>` + `git switch <head>`) to land on the PR's head branch (`fix-checks-only.md` step 1 / `fix-rebase.md` step 1). When the original issue-work worker's worktree is *still locked* against that head branch — because the worker returned `blocked` / `errored` (so the A.1 `shipped`-only reap never ran for it), or a transient `gh` failure aborted the A.1 reap — `git switch` fails with *"is already checked out at \<path\>"* and the worker bails with `blocked rebase #<M>: head branch <HEAD_REF> locked in another worktree` (`fix-rebase.md` step 1) or `Cannot apply fix to PR branch — <head> is locked by another worktree` (fix-checks-only). The fresh worker has already identified the correct fix; it just can't push it. Since the orchestrator's own end-of-session reap (cleanup-summary step 3b) runs *after* drain, drain-phase dispatches always race the lock — and drain is exactly where fix-rebase / fix-checks dispatches are supposed to land ([`dont.md`](./dont.md) bans fix-rebase outside drain). Observed in lightwork session `do-work-20260528T015557Z-14129`: 3 PRs (#1355, #1361, #1363) all bailed identically against self-PID-locked head branches. Observed again in session `do-work-20260614T024327Z-75752`: 2 fix-checks drain dispatches (#1976, #1977) bailed on completed issue-work worktrees still holding their `do-work/issue-<N>` branches — the A.1 immediate-reap had deferred on `peer-alive`, leaving the locks intact at drain time (issue [#576](https://github.com/mattsears18/shipyard/issues/576)).

**Why it's safe to reap.** The lock holds *our orchestrator's* PID (the harness writes the orchestrator PID into every dispatched agent's worktree lock). `classify-lock` short-circuits such a lock to `self-ancestor` once `SHIPYARD_ORCHESTRATOR_PID` is declared — which means "this lock is held by an orchestrator that is itself / an ancestor of ours, about to retire its own worktree." The original worker's return was already reconciled at [step A](./steady-state.md#a-reconcile-the-return) by the time drain runs; its worktree is logically done. This is the same self-ancestor reap logic [setup.md step 3b](./setup/01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) runs at session start and the A.1 `shipped`-immediate reap (#282) runs on issue-work completion — extended to the mid-session drain dispatch site for PRs whose originating worker did NOT take the `shipped` path (so A.1 never reaped them).

**Force-reap even on `peer-alive` at the drain dispatch site.** When the lock's classification is `peer-alive` (a live PID that `SHIPYARD_ORCHESTRATOR_PID` did not short-circuit to `self-ancestor`), the general-purpose drain pre-dispatch reap defers conservatively. However, at drain time **all** issue-work workers in this session have already returned their terminal strings; the PR we are about to dispatch against is in `session_prs` specifically because its worker returned `shipped`. An issue-work worktree holding a `do-work/issue-<N>` branch at drain time is a completed-and-logically-done worktree — the same reasoning that justifies A.0.5's force-reap on crash returns applies here: the agent is non-recoverable by definition, so `peer-alive` does not justify keeping the head branch locked. Override `peer-alive` to force-reap for worktrees whose HEAD ref matches the `do-work/issue-*` pattern (distinguishing them from live fix-checks or fix-rebase workers whose lock must NOT be yanked). Audit the override with classification `peer-alive-force-drain` so it is distinguishable from the A.1 `peer-alive-force` in `~/.shipyard/reap-audit.jsonl`. This closes the second leg of the [#576](https://github.com/mattsears18/shipyard/issues/576) failure path: even if A.1's force-reap was not yet in place (older plugin version), drain's own pre-dispatch check now catches and reaps the lingering completed worktree.

**The reap.** For each PR `#<M>` the drain is about to dispatch a worker against, resolve its head branch, find any `agent-*` worktree **or the primary checkout** locked against that branch, and reap / restore it iff safe. The two holders are handled differently: an `agent-*` worktree is reaped iff the lock classifies as reapable (`no-lock` / `dead` / `self-ancestor`), deferring only on `peer-alive`; the **primary checkout** holding the head branch is the [#387](https://github.com/mattsears18/shipyard/issues/387) harness-leak case — restore it to the default branch iff its tree is clean (never reap the primary; it's the user's checkout), warn-and-skip if dirty. The drain-entry guard above usually handles the primary case first, but this per-PR check is the belt-and-suspenders for a leak that lands *mid-drain* (after the entry guard ran).

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
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
# Derive PRIMARY_CHECKOUT independent of cwd (issue #452) — the harness can
# leak the orchestrator's cwd into a dispatched agent-* worktree, and a
# cwd-strip that only handles orchestrator-* would mis-derive the primary
# and mutate the wrong tree. `git worktree list --porcelain`'s first
# `worktree ` entry is always the primary, whatever the cwd. Fall back to
# the cwd-strip (now covering agent-* too) only if the porcelain read is empty.
PRIMARY_CHECKOUT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
if [ -z "$PRIMARY_CHECKOUT" ]; then
  PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel)"
  case "$PRIMARY_CHECKOUT" in
    */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
    */.claude/worktrees/agent-*)        PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/agent-*}" ;;
  esac
fi
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
    # Check whether this is a completed issue-work worktree (i.e., the
    # branch follows the do-work/issue-<N> pattern). If so, the originating
    # worker has already returned its terminal string — the worktree is
    # logically done and the peer-alive PID is a transient harness artifact.
    # Force-reap it so the drain worker can claim the branch, matching A.0.5's
    # posture for crash returns (issue #576). For any other branch pattern
    # (e.g., a live fix-checks or fix-rebase worker), preserve the conservative
    # defer — yanking a genuinely-live worker's worktree is unsafe.
    case "$branch_ref" in
      do-work/issue-*)
        # Completed issue-work worktree — force-reap. Audit with
        # "peer-alive-force-drain" so the override is distinguishable
        # from normal reaps in ~/.shipyard/reap-audit.jsonl.
        ;;
      *)
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
        ;;
    esac
  fi

  # no-lock / dead / self-ancestor / peer-alive-force-drain (for completed
  # issue-work worktrees) — safe to reap. The helper does the
  # `git worktree unlock` + `git worktree remove --force` AND the audit-log
  # write in one transaction (issue #284).
  drain_classification="$classification"
  [ "$classification" = "peer-alive" ] && drain_classification="peer-alive-force-drain"
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "$name" \
    --session-id "<session-id>" \
    --classification "$drain_classification" \
    --lock-pid "$lock_pid" \
    --phase "drain-pre-dispatch" 2>/dev/null || true

  # Drop the local branch ref so the fresh worker's `git switch <head>`
  # recreates it cleanly without the "already checked out" collision.
  git branch -D "$head_ref" 2>/dev/null || true
  break   # at most one worktree per head branch
done
git worktree prune 2>/dev/null || true
```

This block is **fire-and-forget** (every command suffixes `2>/dev/null` and / or `|| true`) so a filesystem race can't abort the drain poll. It runs **once per PR per dispatch**, immediately before the `Agent` dispatch for that PR — NOT once per poll across all PRs (a PR not being dispatched this poll, e.g. one held back by the `max_drain_rebases` cap, doesn't need its lock released yet). The `peer-alive` defer is intentionally conservative for non-issue-work branches (a live fix-checks or fix-rebase worker's lock must not be yanked), but completed issue-work worktrees (`do-work/issue-*` branch pattern) are force-reaped even on `peer-alive` — those workers have already returned their terminal strings and their worktrees are logically done. Audit entries carry `"phase":"drain-pre-dispatch"` and classification `"peer-alive-force-drain"` (for the force-reap path) or `"peer-alive"` (for the conservative defer path) so an operator can distinguish these cases and distinguish drain-phase reaps from setup-3b (session start), steady-state-A1-shipped (#282 immediate-reap, with `"peer-alive-force"` for its own force-reap path), and reconcile-A.0.5 (#358 crash-recovery) in `~/.shipyard/reap-audit.jsonl`.

The **primary-checkout holder** branch (issue [#387](https://github.com/mattsears18/shipyard/issues/387)) is intentionally *not* a reap — the primary is the user's checkout, never a shipyard-owned worktree, so it's restore-if-clean / warn-if-dirty, exactly as the [A.0.6 guard](./steady-state.md#a06-primary-checkout-branch-leak-guard-fires-every-reconcile-turn-before-a1) does it. It increments the same `primary_leak_counters` map the entry-guard and steady-state guard feed, so the end-of-session friction line counts a mid-drain leak the same as a reconcile-turn one. The dirty-skip path leaves the head branch locked and the fix-rebase worker for that PR will bail `blocked rebase` — the correct conservative outcome when the primary has uncommitted work shipyard must not touch.

**Per-poll actions.**

1. If `R_new > 0` OR `D_dirty_red > 0`: push all PRs from **both** sets onto `failed_prs` (deduped) and dispatch fix-checks-only workers against them — same `--concurrency` cap, same 3-attempt rule, same `blocked:ci` stamp on exhaustion that step A enforces. `D_dirty_red` PRs (DIRTY-AND-red) are routed here, not to fix-rebase in action 2: fix-checks rebases as part of getting green, so a dedicated fix-rebase pass would be wasted. Drain runs the same dispatcher logic step C uses, just with `failed_prs` as the only queue that's still drainable (no new issue work, no diverts; `divert_queue` is intentionally NOT re-evaluated during drain — a red main mid-drain becomes next session's problem because dispatching a fix-main-ci agent here would extend the session indefinitely). **Before each dispatch, run the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release) against that PR's head branch** so the fresh fix-checks worker's `git switch <head>` doesn't collide with a self-PID-locked worktree from the originating worker (#370). Emit `[drain] PR #<M> DIRTY+failing → fix-checks (not fix-rebase); routing via D_dirty_red (#577)` for each `D_dirty_red` PR to make the routing decision visible in the drain log.
2. If `D_dirty > 0`: dispatch a fix-rebase worker for each, **subject to the `--concurrency` cap** (combined fix-checks + fix-rebase in-flight count must not exceed `--concurrency`) **AND the CI-minute config gates from issue [#323](https://github.com/mattsears18/shipyard/issues/323)**. **Before each dispatch, run the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release) against that PR's head branch** (#370) — this is the load-bearing call for fix-rebase, the mode `dont.md` confines to drain and the one the #370 repro caught bailing on every self-PID-locked PR.

   **CI-minute pre-dispatch gates (gated on `ci.*` config keys).** Before the per-PR re-dispatch policy below, check the config keys in this order — both default to off (preserves pre-#323 behavior); flip them in `shipyard.config.json`'s `ci.*` block to engage:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
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

   **CHANGELOG-serialization gate (gated on `version_coordination.serialize_drain_rebase`).** Closes issue [#438](https://github.com/mattsears18/shipyard/issues/438). On a repo where every PR appends a top-of-file `### <version>` CHANGELOG entry (the canonical version-coordinated shape — `version_coordination.enabled` AND a non-empty `changelog_path`), **parallel drain rebases cannot converge**: each merge moves the CHANGELOG insert point, so the moment one rebased PR lands, every sibling that just rebased onto the previous CHANGELOG head goes DIRTY again on the CHANGELOG-append row. The #438 repro saw drain rebases for 6 distinctly-versioned PRs (1.8.18–1.8.23) all re-DIRTY on the CHANGELOG insert after the first merge; only **serial** rebase (rebase one → let it merge → rebase the next) converged. When the gate is engaged, drain dispatches a fix-rebase for **at most one** DIRTY PR per poll and does not dispatch the next until the in-flight one has merged (or settled out of DIRTY). This runs **after** the CI-minute truncation above — it caps the already-truncated `D_dirty` set to its single lowest-numbered member:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
   # Read the coordination keys once per poll. Defaults preserve pre-#438
   # behavior on non-coordinated repos: serialize_drain_rebase defaults true,
   # but the gate only engages when enabled AND changelog_path is non-empty,
   # so a repo without version_coordination.enabled never serializes.
   vc_enabled=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get \
     version_coordination.enabled 2>/dev/null || echo "false")
   vc_changelog=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get \
     version_coordination.changelog_path 2>/dev/null || echo "")
   vc_serialize=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get \
     version_coordination.serialize_drain_rebase 2>/dev/null || echo "true")

   if [ "$vc_enabled" = "true" ] && [ -n "$vc_changelog" ] && [ "$vc_serialize" = "true" ]; then
     # If a fix-rebase worker is already in flight this drain, dispatch NONE
     # this poll — wait for it to merge (or settle out of DIRTY) before
     # rebasing the next. The in-flight count is the combined fix-checks +
     # fix-rebase count; the fix-rebase component is what gates here.
     if [ "$fix_rebase_in_flight" -gt 0 ]; then
       echo "[drain] version_coordination.serialize_drain_rebase: a fix-rebase is in flight; deferring remaining DIRTY PRs ($D_dirty) to a later poll. (#438)"
       D_dirty=""   # dispatch nothing this poll
     else
       # No rebase in flight — dispatch exactly the lowest-numbered DIRTY PR
       # (D_dirty is already sorted lowest-first) and defer the rest.
       D_dirty=$(echo "$D_dirty" | head -n 1)
     fi
   fi
   ```

   The deferred PRs are NOT surfaced as "needs manual rebase" the way `skip_drain_rebase` / `max_drain_rebases` skips are — they remain in `D_dirty` and get picked up on a subsequent poll once the in-flight rebase merges. Serialization trades wall-clock (one rebase + its CI per merge cycle) for convergence; it does not skip any rebase, so it composes cleanly with the CI-minute gates above (which DO skip — a PR truncated by `max_drain_rebases` is surfaced and never re-enters `D_dirty`, whereas a PR deferred by this gate does). The gate is a no-op on repos without `version_coordination.enabled` or without a `changelog_path`, and can be disabled on a coordinated repo whose CHANGELOG convention is conflict-free (per-PR fragment files) by setting `version_coordination.serialize_drain_rebase: false`.

   Fix-checks dispatches in action 1 above take priority — a red PR is more urgent than a stale base. After filling the pool with fix-checks workers, any remaining slots dispatch fix-rebase workers from the (possibly cap-truncated) `D_dirty` set (lowest PR number first, so dispatch order is deterministic across re-dispatches). The per-PR re-dispatch policy splits by return outcome:

   - **`blocked rebase #<M>: <reason>`** — add `<M>` to `rebase_blocked_prs`. Do NOT re-dispatch this session even if the PR is still DIRTY at subsequent polls; the same conflict will produce the same outcome. The drain's settled definition counts `rebase_blocked_prs` membership as settled so the PR doesn't keep the drain alive forever.
   - **`rebased #<M>`** — increment `rebase_success_counts[<M>]` by 1 (initialize to 0 if absent). Do NOT add to `rebase_blocked_prs`. If the PR transitions DIRTY again later in the session (sibling merge re-introduced the conflict), it re-enters `D_dirty` and gets re-dispatched **as long as** `rebase_success_counts[<M>] < 3`. At the cap (3 successful rebases on one PR in one session), the PR is treated as settled: log `[drain] PR #<M> hit rebase-cap (3 successful rebases); deferring to next session — merge train advancing faster than rebase can keep up` and skip future re-dispatches.
   - **`noop: not dirty (<reason>)`** — no bookkeeping change. The PR transitioned out of DIRTY between dispatch and pre-flight (a parallel auto-merge landed it, or the rollup flipped to red and the agent correctly bailed because rebase isn't the right tool). Don't increment either counter; the drain's next poll will re-classify the PR's state from scratch.
   - **`errored`** — no bookkeeping change (matches the existing pattern for transient worker errors). The PR may re-enter `D_dirty` on the next poll and get re-dispatched naturally.

   This split fixes the merge-train race documented in [#265](https://github.com/mattsears18/shipyard/issues/265): a successful rebase followed by a sibling merge re-introducing DIRTY is a winnable race, NOT a stuck state. Capping at 3 successful rebases keeps the worst-case cost bounded (≤3 Haiku-pinned dispatches per PR per session) while letting normal merge-train races resolve on their own.
3. Update the per-PR `head_unchanged_since` map (reset on head movement, else leave `since` untouched — see the [Initial snapshot](#drain-protocol) structure) and the in-flight worker counts (fix-checks + fix-rebase combined). `M_since_last` feeds the status line's `merged_this_poll` token; termination no longer reads a rolling no-progress window (it's per-PR settle now, issue [#374](https://github.com/mattsears18/shipyard/issues/374)).
4. Print one drain status line per poll:
   ```
   [drain] open=<O> merged_this_poll=<M_since_last> newly_red=<R_new> dirty_red=<D_dirty_red> dirty=<D_dirty> blocked_ci=<B> rebase_blocked=<|rebase_blocked_prs|> rebase_capped=<count of PRs where rebase_success_counts[<pr>] >= 3> in_flight=<n>(fix-checks=<a>, fix-rebase=<b>) · elapsed=<MM:SS>/<max_drain_hours>h
   ```

   `dirty_red=<D_dirty_red>` surfaces PRs that are both DIRTY and failing so the operator can see at a glance which are being routed to fix-checks rather than fix-rebase. Omit the `dirty_red=` token when `D_dirty_red == 0` to keep the line terse on sessions where no DIRTY-AND-red PRs appear.

   `rebase_capped` is the count of PRs that hit the 3-successful-rebase rate-limit cap — distinct from `rebase_blocked` because the failure mode is different (race against a fast merge train, not a deterministic conflict). Both classes show up in the end-of-session summary as still-DIRTY PRs needing the next session's attention. The `elapsed` token now carries the `max_drain_hours` ceiling as its denominator so the operator can see how much of the ultimate budget is consumed (issue [#374](https://github.com/mattsears18/shipyard/issues/374)).

   **Per-PR progress detail (issue [#374](https://github.com/mattsears18/shipyard/issues/374)).** For each still-pending PR (member of neither merged/closed nor `blocked:ci`), print one indented follow-on line so the operator can watch the progress signal that determines settle:

   ```
       PR #<M>: head unchanged <H>m / <settled_minutes>m settled-threshold (checks: <pending|green|dirty>)
   ```

   `<H>` is `now - head_unchanged_since[<M>].since` in whole minutes. A PR that crosses `settled_minutes` reads e.g. `head unchanged 21m / 20m settled-threshold` and is now a member of `P_settled`. This is the "bonus" surface the issue asked for — it makes the otherwise-invisible head-movement clock legible while drain works.

**Completion vs bounded-exit ([#662](https://github.com/mattsears18/shipyard/issues/662)).** A PR reaches a **completing** terminal state only two ways: it **merges**, or it is blocked on a confirmed **external dependency** the agent cannot itself perform (a human-supplied secret, an upstream release, a provider-console action). Every *other* "settled" class in the criterion below — `blocked:ci`, `rebase_blocked_prs`, rate-limit-capped, or `P_settled` still-pending when `max_drain_hours` fires — is a **bounded-exit concession**: it stops the drain from spinning forever, but it leaves the session **incomplete**. Bounded-exit PRs are surfaced in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) as unfinished tail for the next `/do-work` run (or a human / external action), NOT reported as done. So the settled definition below governs *when the drain stops polling* (the safety bound); it does not redefine *completion* (merged-or-confirmed-external). The drain's obligation is to keep driving the tail toward the completing states — only the `max_drain_hours` ceiling and the per-PR caps may cut that short, and when they do the outcome is an explicit incomplete-session bounded-exit, never a silent "done."

**Termination criterion (progress-based, issue [#374](https://github.com/mattsears18/shipyard/issues/374)).** The exit signal is **per-PR progress**, not the wall clock. Drain continues as long as **any** PR in `session_prs` is NOT yet settled — i.e. **any** of these is true:

- Any fix-checks OR fix-rebase worker is in flight, OR
- Any PR is still open with a non-`blocked:ci` rollup AND its head commit has moved within the last `settled_minutes` (it's actively churning — fresh push, rebase force-push, or a check transition that re-triggered the head), OR
- Any PR is open, not `blocked:ci`, not in `rebase_blocked_prs`, not rate-limit-capped, and its checks have not been pending-with-unmoved-head for `settled_minutes` yet (it hasn't crossed the settle threshold).

Drain terminates the moment **every** PR in `session_prs` is settled AND no fix-checks / fix-rebase worker is in flight. A PR is settled per the [settled definition above](#drain-protocol): merged/closed, `blocked:ci`, in `rebase_blocked_prs`, rate-limit-capped (`rebase_success_counts[<pr>] >= 3`), or in `P_settled` (pending with `headRefOid` unchanged for `settled_minutes`). There is **no fixed 5-poll no-progress window** anymore — the per-PR `settled_minutes` head-movement threshold subsumes it. A multi-PR merge train with full E2E sharding + release-please cascades that legitimately takes >2h to land is no longer cut off mid-flight, because each PR stays unsettled exactly as long as its head keeps moving (rebases re-DIRTY-ing siblings keep resetting the clock); drain exits only once the train has genuinely gone quiet for `settled_minutes` per PR.

**Ultimate ceiling: `max_drain_hours` (config `ci.max_drain_hours`, default 8h).** As a belt-and-braces safety net against degenerate cases (a runaway CI loop, an infinite rebase that keeps moving the head every poll so no PR ever settles), drain forcibly exits once total drain elapsed exceeds `max_drain_hours`, even if forward progress is still observable. This replaces the old hardcoded 120-min ceiling (issue [#374](https://github.com/mattsears18/shipyard/issues/374)) — the old value fired on wall-clock time alone, killing healthy-but-slow merge trains; the progress-based exit above is now the primary path and `max_drain_hours` is the rarely-hit outer bound. Surface a ceiling exit in the summary as `drain exited at max_drain_hours ceiling (<X>h) — <n> PRs still pending`.

**On exit, regardless of how drain terminated**: report the final state of every PR in `session_prs` in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary), separated by status — **completing** (merged ✓ / confirmed external-dependency) vs **bounded-exit / incomplete** (blocked:ci / rebase-capped / still-pending at ceiling). A session that exits with any bounded-exit PR is **not** complete; the user can re-run `/do-work` later to sweep what's left (a fresh run's drive-the-tail drain picks the incomplete PRs back up).

### Local-only-CI merge gate

Closes [#643](https://github.com/mattsears18/shipyard/issues/643). The default drain protocol assumes **cloud CI auto-runs on every PR push** — push → checks run → rollup goes green → `--auto` merges. On a **local-only-CI repo** that assumption is false: the merge-blocking commit status is posted by a **manually-run command** (e.g. lightwork's `local-ci` status, posted only after a session runs `npm run ci:report` — a ~20-min emulator-backed full suite incl. E2E), not by cloud CI. Nothing posts the gate status on push, so every shipped PR sits OPEN with `--auto` armed but **never merges** — the dispatch loop "succeeds" (PRs shipped) while the backlog never actually drains. The [#643 repro](https://github.com/mattsears18/shipyard/issues/643): session `dowork-20260622T234502Z-39390` on `mattsears18/lightwork` shipped 9 issues; each PR required a manual `ci:report` run before `--auto` could fire, and the orchestrator had to improvise the entire merge-gate loop off-book. This section makes the loop first-class.

**Engagement.** The loop is gated entirely on `merge_gate.command` (config `merge_gate.*`, schema in `shipyard.config.schema.json`). Read it once at drain entry:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
mg_command=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get merge_gate.command 2>/dev/null || echo "")
```

When `mg_command` is empty (the default), this entire section is a **no-op** — cloud-CI behavior is unchanged, exactly as before #643. The rest of the section applies ONLY when `merge_gate.command` is non-empty.

**Interaction with `P_settled` — the load-bearing correction.** On a local-CI repo a shipped PR's checks are `pending` *forever* until the gate command posts the status, and its head commit never moves once shipped — so the default [`P_settled` classifier](#drain-protocol) (`pending` rollup + head unchanged for `settled_minutes`) would mark every shipped PR **settled** and let drain exit with the whole backlog unmerged. **When `merge_gate.command` is non-empty, a PR whose missing status is the local gate is NOT settled by `P_settled` until the gate command has run against its HEAD.** Track a per-session `merge_gate_run = {}` map of `<pr-number> → {sha, conclusion}` recording the last gate run per PR; a PR is gate-pending (not `P_settled`-eligible) while its current `headRefOid` has no `merge_gate_run` entry (or the entry's `sha` is stale). This keeps drain alive long enough to run the gate, rather than declaring victory while PRs hang.

**Per-poll merge-gate action (runs after the existing per-poll actions, only when `mg_command` is non-empty).** For each open, non-`blocked:ci` PR in `session_prs` whose `headRefOid` has no fresh `merge_gate_run` entry:

1. **Pace to the cap.** Count PRs that are shipped-but-unmerged AND already have a gate run queued/in-flight ahead of the merge. If that count is `>= merge_gate.max_unmerged_ahead` (default 2), do NOT start a new gate run this poll — let the gate catch up first. This bounds concurrent pressure on an expensive (~20 min) gate; it matches the #643 operator's manual "keep ≤2 unmerged PRs ahead of the gate" choice.
2. **Serialize on a shared resource (gated on `merge_gate.serialize`).** When `merge_gate.serialize: true`, run at most ONE gate command at a time across the whole session — required when the command contends on a single machine-wide resource (an emulator on a fixed port, a serialization lock, a single test DB). Before starting a run, apply the **single-shared-resource pacing pattern** (below): wait-for-free → orphan-reap → run. When `serialize: false` (default), gate runs may overlap (the command is stateless or per-worktree-isolated).
3. **Clear stale generated state (gated on `merge_gate.clear_state_command`).** If a **reused** gate-runner worktree carries stale gitignored/generated artifacts between runs (the #643 session hit stale Expo typed-routes in a reused `ci:report` runner, producing a spurious gate failure), run `merge_gate.clear_state_command` in the worktree first to evict them. A fresh-or-cleaned worktree per gate run is the reliable shape — never run the gate twice in one worktree without clearing generated state in between.
4. **Run the gate against the PR's HEAD.** Check out the PR's head commit in a worktree and run `merge_gate.command`; it posts the gate commit-status for that SHA as a side effect. Capture full output so a **contention failure** (port-in-use, lock-held, orphaned emulator) is distinguishable from a **real code failure** — only the latter should be treated as the PR going red. Record `merge_gate_run[<pr>] = {sha: <headRefOid>, conclusion: <success|failure>}`. On success, `--auto` (already armed at ship time) fires on the next status sync and the PR merges normally. On a real failure, the PR's checks rollup goes red and the existing `R_new` / fix-checks path handles it. On a contention failure, do NOT mark the PR red — re-queue the gate run for a later poll once the resource is free.

**Single-shared-resource pacing pattern (emulator / fixed-port / lock-backed gate).** When the gate command contends on one machine-wide resource, three things must compose so concurrent runs (the orchestrator's own gate runs, a worker's pre-push gate, a leaked orphan from a prior run) don't fail each other on contention rather than on code:

- **Wait-for-free.** Before starting a gate run, poll for the shared resource being idle (e.g. the emulator port unbound, the lock unheld). Block the gate run — not the whole drain poll — until free.
- **Orphan-reap.** A prior gate run that crashed or was reaped can leave the resource held (an orphaned emulator process bound to the fixed port). Detect-and-kill the orphan before waiting times out, so a leaked process can't wedge the gate indefinitely. This is the gate-resource analogue of the [pre-dispatch head-branch reap](#pre-dispatch-head-branch-reap-self-pid-lock-release).
- **Serialized runs.** With `merge_gate.serialize: true` the orchestrator runs exactly one gate at a time, so its own runs never contend with each other — the wait-for-free + orphan-reap then only has to handle *external* contenders (a worker's pre-push gate, a concurrent run in another worktree).

This pattern is documented here rather than re-invented per session: the #643 orchestrator had to improvise orphan-emulator detection+kill, the wait-for-free loop, and full-output capture to tell real failures from contention. Codifying it means a less careful run on a local-CI repo doesn't just leave a pile of unmerged PRs.

**Termination interaction.** Drain's [termination criterion](#drain-protocol) is unchanged in shape — it still exits when every `session_pr` is settled — but the gate-pending correction above means a shipped-but-ungated PR keeps drain alive until its gate run completes (success → it merges → settled-as-merged; real failure → red → fix-checks or `blocked:ci` → settled). The `max_drain_hours` ceiling still applies as the outer bound, so a wedged gate (resource permanently held, command hanging) can't run drain forever.

### Release-PR auto-arming and deploy watch (own-the-tail phase c — [#663](https://github.com/mattsears18/shipyard/issues/663))

Closes the "own the release train" slice of the [#659](https://github.com/mattsears18/shipyard/issues/659) own-the-tail epic. A repo that produces **release PRs** — a release-please `chore(main): release …` PR, an aggregated release-bump PR, or any PR whose sole job is to cut a version + CHANGELOG entry and (on merge) trigger a deploy — otherwise strands its tail on a human: the session ships feature PRs, they merge, and the release PR that would actually *publish* those merges sits OPEN with nobody to arm it. Under the repo's **standing authority** (the [Permissions section](../../../../CLAUDE.md) grants landing on `main` via PR + auto-merge without asking on this personal-tooling repo, and the equivalent grant on any repo whose `auto_merge.policy` is not `never`), drain arms auto-merge on the release PR and drives it to merged → deployed, then picks up the next release PR for the following batch.

**Engagement.** This sweep runs during drain, once per poll, **only after** the per-poll actions and the merge-gate action above. It is a no-op when `auto_merge.policy == never` (read once at drain entry — the operator has opted every PR, release or not, out of auto-merge) or when no open release PR exists.

**Identifying a release PR.** Match an open `@me` (or bot-authored — see the carve-out) PR against the repo's release convention, in priority order:

1. A configured release marker if the repo sets one (a `release` / `autorelease: pending` label, or a `version_coordination`-declared release-branch prefix).
2. A release-please head-branch prefix (`release-please--*`) or a conventional release title (`chore(main): release`, `chore: release`, `chore(release):`).
3. Nothing matches → not a release PR; skip it.

Never infer "release PR" from a version bump *inside a feature PR* — on this repo every feature PR cuts its own release ([per-PR release rule](../../agents/issue-worker/issue-work.md#4-implement)), and those are ordinary feature PRs already in `session_prs`, armed at ship time. This sweep targets **standalone** release PRs (release-please-style aggregation, or a catch-up release bump) that no worker armed.

**Security carve-out — preserved, not bypassed.** A release PR is auto-armed **only** when its author clears the same trust gate every other auto-merge decision uses ([issue-work.md step 6](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust), [`external-author-gate.yml`](../../../../.github/workflows/external-author-gate.yml)):

- The author is **push-capable / in `trust.authors`** (the repo owner, a vetted collaborator), OR a **trusted release bot** the repo lists in `trust.authors` (e.g. `github-actions[bot]`, `release-please[bot]`). Release bots are the common case and are exactly why they must be *explicitly* trusted rather than auto-cleared — a release PR opened by an *untrusted* actor (a fork bot, a stranger who titled their PR `chore: release` to smuggle a merge) is **never** armed. Resolve trust the same way issue-work step 6 does when the field is absent: `repos/{owner}/{repo}/collaborators/{author}/permission` → `admin`/`maintain`/`write` ⇒ trusted, anything else ⇒ external.
- When the release PR's author is **external**, do NOT arm — label it `needs-human-review` and comment (same treatment as an external-author feature PR), then continue. The release still lands, but a human signs off on the merge. The standing-authority grant covers *trusted* release authorship, not a bypass of the external-author defense-in-depth.

**Arming.** For a trusted release PR not already armed this session, branch on the drain-entry `merge_gating` verdict ([#720](https://github.com/mattsears18/shipyard/issues/720) — read once at drain entry per the [deferred-merge lander](#deferred-merge-lander-merge-unarmed-green-session-prs--720) below; do NOT re-probe per poll):

```bash
if [ "$merge_gating" = "gated" ]; then
  # `--auto` genuinely queues behind CI. Arm it with the repo's release merge
  # method (release-please repos typically squash; a plain release-bump PR merges).
  gh pr merge <M> --repo <owner/repo> --auto --merge --delete-branch
else
  # UNGATED: `--auto` would direct-merge this release PR immediately, before its
  # own CI completes — publishing an unverified release. Leave it OPEN and
  # unarmed; the deferred-merge lander merges it on the first poll its checks are
  # green. Do NOT block on `gh pr checks --watch` here: this runs on the
  # orchestrator's turn and would stall the drain loop for every other PR.
  echo "[release-train] PR #<M> left unarmed (ungated repo) — deferred to the merge lander (#720)"
fi
```

The ungated branch is not a downgrade: on such a repo `--auto` was never a queue, so "arm it" and "merge it when green" are the same statement — the lander just runs the queue on drain's poll instead of GitHub's. A release PR is the *last* thing that should merge unverified: it cuts a version and, on repos with a deploy pipeline, ships it.

Add `<M>` to `session_prs` (deduped) so the existing drain termination machinery watches it to merged, exactly like any other session PR — it participates in `P_settled` / `head_unchanged_since` / the `max_drain_hours` ceiling with no special-casing. Log `[release-train] armed auto-merge on release PR #<M> (author <login>, trusted); watching to merged→deploy (#663)`.

**Deploy watch.** When a release PR merges (drain's per-poll snapshot sees it leave `O`), the merge commonly triggers a **deploy** — a `deploy` / `publish` / `release` workflow keyed on the merge to the default branch or a pushed tag. Watch that workflow's outcome **within the existing drain window** (bounded by `max_drain_hours` — the deploy watch never *extends* drain past its ceiling; it rides the same budget):

```bash
# After the release PR merges, find the deploy workflow run triggered by the
# merge SHA (best-effort — many repos have no deploy workflow, in which case
# this is a clean no-op and the release is "settled = merged").
#
# `.mergeCommit.oid` is the FULL 40-char SHA — keep it that way. `gh run list
# --commit` matches ONLY on a full SHA and silently returns an empty list for an
# abbreviated one, so never `cut`/`--short` this value on its way into the call.
# An empty result here means "no deploy workflow found" ONLY because we know the
# SHA was full; with a short SHA the same empty list would mean "we looked at
# nothing" and every downstream conclusion would be vacuous (issue #717 —
# `shipyard:worker-preamble` § "An absence-assertion that observed nothing is not
# a pass", fragment `skills/worker-preamble/ci-pitfalls.md`).
merge_sha=$(gh pr view <M> --repo <owner/repo> --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null || echo "")
if ! printf '%s' "$merge_sha" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "[release-train] could not read a full merge SHA for PR #<M> — deploy watch NOT VERIFIED (skipping, not concluding green)"
  merge_sha=""
fi
if [ -n "$merge_sha" ]; then
  gh run list --repo <owner/repo> --commit "$merge_sha" \
    --json databaseId,name,status,conclusion,workflowName \
    --jq '[.[] | select(.workflowName | test("deploy|publish|release"; "i"))]' 2>/dev/null || echo "[]"
fi
```

- **No deploy workflow found** → the release is settled at merge; nothing to watch. (The common case on this repo — there is no deploy pipeline; `plugin.json` is the version surface and the marketplace reads it directly.)
- **Deploy in progress** → let it ride the normal per-poll snapshot; the release PR is already merged so it doesn't hold `session_prs` open, but surface the deploy's status in the drain status line (`release #<M> merged · deploy <workflow> <status>`) so the operator sees the tail completing.
- **Deploy concluded FAILURE / TIMED_OUT** → surface it loudly in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) as `release #<M> merged but deploy <workflow> failed — <conclusion>` and, if the failure is a systemic CI/infra shape rather than a code defect, file a follow-up issue against the **target repo** (same posture as the [systemic-CI-failure section](#when-drain-catches-a-systemic-ci-failure) below). Do NOT auto-retry the deploy from drain — a failed deploy is a human/operator decision (roll back, re-run, or fix-forward), not a fix-checks target.

**Next release PR.** Once a release PR merges and its deploy settles (or there's no deploy), the sweep's next poll picks up the **next** open release PR (release-please opens a fresh one as soon as new conventional commits land on the default branch). It arms that one under the same trust gate — so a session that merges several feature batches drives each successive release PR to merged without a human, one at a time. This is fire-and-forget and bounded by `max_drain_hours`: a release train that can't converge within the ceiling surfaces its still-open release PRs in the summary for the next session.

### Deferred-merge lander (merge unarmed green session PRs — [#720](https://github.com/mattsears18/shipyard/issues/720))

Closes the orchestrator-turn half of [#720](https://github.com/mattsears18/shipyard/issues/720). On an **ungated** repo shape (`gh pr merge --auto` doesn't queue — it direct-merges immediately; see [`detect-ungated-admin-direct-merge.sh`](../../scripts/detect-ungated-admin-direct-merge.sh)), the four orchestrator-turn call sites that would otherwise arm `--auto` — [inline-trivial §E](./inline-trivial.md#e-arm-auto-merge), the [A.0.5 crash-recovery re-arm](./steady-state.md#a05-crash-return-detection--pre-reap-recovery), the [setup-3c orphan-recovery re-arm](./setup/00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch), and the [release-train sweep](#release-pr-auto-arming-and-deploy-watch-own-the-tail-phase-c--663) above — deliberately **leave the PR OPEN and unarmed** rather than merging it ungated. They cannot re-create the gate by blocking on `gh pr checks --watch` the way a worker does ([fix-main-ci step 7.a](../../agents/issue-worker/fix-main-ci.md), [issue-work §6.a](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust)), because they run on the **orchestrator's own turn** — a multi-minute block there stalls the dispatch loop, every in-flight reconcile, and every other PR's progress.

**This section is where those PRs actually land.** Without it, an unarmed PR would never merge and drain would spin until its ceiling — a hang strictly worse than the ungated merge it replaced. The lander is what makes "don't arm" a safe instruction rather than a leak.

**The insight:** drain is *already* a poll loop over `session_prs`. On an ungated repo, "arm auto-merge" and "merge it when the checks go green" are the same statement — there is no queue to arm, so the queue is drain's own poll. Merging a **green** PR directly is not the #720 hazard; it is precisely correct (the [`merged-direct` + `checks: green` case](../../agents/issue-worker/issue-work.md#7-snapshot-check-state--auto-merge-state-then-return--dont-block-on-ci) the spec already calls "effectively gated. Informational."). The hazard is merging a **pending or failing** PR, which this action never does.

**Engagement.** Read the verdict **once at drain entry** (a per-repo property — do NOT re-probe per poll):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
merge_gating=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo> 2>/dev/null || echo ungated)
```

The action is a **no-op when `merge_gating == "gated"`** (GitHub's real auto-merge queue owns the merge — never race it) and a no-op when `auto_merge.policy == never`.

**Candidate set — precise, and deliberately narrow.** Drain's [open-PR query](#drain-protocol) already snapshots every open `@me` PR *with its labels*, so the lander needs no extra fetch. A PR is a candidate when **all** of these hold:

| Condition | Why |
|---|---|
| Carries the **`shipyard`** label | The session stamp on every PR shipyard creates. This is the trust boundary: it admits session PRs *and* the [setup-3c orphan-recovery PR](./setup/00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) (which isn't in `session_prs` but is created `--label shipyard`), while **excluding the user's own hand-authored PRs** — never surprise-merge a human's work-in-progress. |
| `autoMergeRequest == null` (unarmed) | An armed PR is GitHub's to merge. Never race a real auto-merge queue. |
| **Not** labeled `needs-human-review` | The PR was left unarmed as a **trust/review gate**, not for the ungated-repo reason. The lander must never launder a trust gate into a merge. |
| **Not** labeled `blocked:ci` | Circuit-breaker already tripped; a human owns it. |
| Latest-run-per-check rollup is **green** | The whole point — this *is* the CI gate. |

**Per-poll action (runs last, after the per-poll actions, the merge-gate action, and the release-train sweep).** When `merge_gating == "ungated"`, for each candidate:

- Rollup **green** (all `SUCCESS`/`SKIPPED`/`NEUTRAL`, or no checks configured) → **merge it now**: `gh pr merge <M> --repo <owner/repo> --merge --delete-branch` (repo's configured merge method). Log `[drain] PR #<M> unarmed + green on ungated repo → direct-merged by deferred-merge lander (#720)`. The PR leaves `O` on the next snapshot and settles normally.
- Rollup **failing** → do nothing here. The PR is already in `R_new` / `P_failing` and per-poll action 1 dispatches fix-checks against it; the lander picks it up on a later poll once it goes green.
- Rollup **pending** → do nothing. Wait for a later poll. This is the queue behaving as a queue.

Reuse the **exact** latest-run-per-check reduction from the [initial snapshot](#drain-protocol) (`group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last)`) — a stale `FAILURE` superseded by a later `SUCCESS` must not hold a mergeable PR open (issue [#333](https://github.com/mattsears18/shipyard/issues/333)).

**The `needs-human-review` exclusion is load-bearing, not defensive boilerplate.** Every site that hands a PR to this lander declined to arm it *because the repo is ungated*. A **different** set of sites declines to arm *because the author is external* ([issue-work §6](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust), the release-train trust carve-out) — and those PRs are also open and unarmed, so without this exclusion the lander would merge them on green and silently defeat the external-author auto-merge gate. **Unarmed is not one state; it is two, and only one of them is the lander's.**

**Drain exit with a still-unarmed PR.** If drain hits `settled_minutes` / `max_drain_hours` while an unarmed PR's checks are still pending, the PR stays OPEN and unmerged — nothing merges it after the session ends (on an ungated repo there is no queue to persist into; that is the premise). This is **correct and already-modeled**: it is exactly the [bounded-exit / incomplete](#end-of-session-drain) class from [#662](https://github.com/mattsears18/shipyard/issues/662), surfaced in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) as unfinished tail and picked back up by the **next** `/do-work` run's drive-the-tail drain. Do **not** "just arm `--auto`" at drain exit as a last resort — that reintroduces the exact ungated merge this whole mechanism exists to prevent, at the one moment nobody is watching.

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
