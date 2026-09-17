# /shipyard:do-work — Session-wide environmental pause (issue #1402)

**Loaded from [`steady-state.md`'s step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action), immediately after the queue-depth backpressure check and before step D — not part of the ordered per-session walk.** Split out from `steady-state.md` itself ([#611](https://github.com/mattsears18/shipyard/issues/611)'s phase-file size cap, the same pressure [`invariant-line.md`](./invariant-line.md) and [`disk-space-guard.md`](./disk-space-guard.md) exist to relieve — `steady-state.md` crossed the 245760-byte cap the moment this section's prose landed inline). Router: [`steady-state.md`](./steady-state.md). Sidebar: [`dont.md`](./dont.md).

**The problem this closes.** The queue-depth backpressure check above already retries forever in the ordinary case — a held slot just waits for the next agent completion (or the next dispatch turn's live re-read) to try again. But the loop's entire wake mechanism is "the orchestrator wakes when an agent completes" ([the turn-shape framing at the top of `steady-state.md`](./steady-state.md#a-reconcile-the-return)); if a hold fires and, after this turn's dispatch decisions, **no worker remains in flight**, there is no future completion to wake anything — the turn just ends, and a transient, self-clearing condition (the [#1402](https://github.com/mattsears18/shipyard/issues/1402) repro: a saturated self-hosted pool that recovered on its own within 45 idle minutes) silently strands the session exactly as if it had genuinely finished, with a human needing to notice and re-invoke `/do-work`. Under the default `ci.backpressure_min_in_flight: 1` escape valve this deadlock cannot occur (a hold verdict guarantees `in_flight >= 1`); it becomes reachable specifically when an operator has configured `ci.backpressure_min_in_flight: 0` — already documented there as producing "a session that goes fully idle despite non-empty queues." This is the mechanism that rescues that documented gap instead of leaving it a footgun.

**Distinct from `awaiting_external` ([#1390](https://github.com/mattsears18/shipyard/issues/1390)) — deliberately mirrors its three load-bearing properties anyway.** `awaiting_external` parks ONE worker on a long job IT started; `paused_on_environment` pauses the WHOLE dispatch loop on an environmental condition no single worker owns. They compose (a session can have live `awaiting_external` entries and a `paused_on_environment` pause at once) but never conflate: the resume mechanism, the state shape, and the bound are each independently derived, not shared fields. The three properties this deliberately mirrors from `awaiting_external`: (1) a **machine-checkable resume probe**, never prose — `resume_probe_pool_total` / `resume_probe_multiplier` feed [`scripts/watch-resume-probe.sh`](../../scripts/watch-resume-probe.sh), which re-runs [`detect-ci-runner-capacity.sh --decide-resume`](../../scripts/detect-ci-runner-capacity.sh) against a LIVE queue re-read; (2) the bound is **anchored at first pause and never extended by a re-pause**, exactly like `awaiting_external.max_hours`'s anchoring rule; (3) **expiry degrades to a genuine hand-back**, never a silent re-park. Unlike `awaiting_external`'s probe, this one is never worker-supplied — it is constructed entirely by the orchestrator from session-state values (`pool_total`, `ci.backpressure_multiplier`), so there is no untrusted-string trust boundary to re-validate at execution time the way [`validate-awaiting-external-probe.sh`](../../scripts/validate-awaiting-external-probe.sh) re-validates a worker's return; `watch-resume-probe.sh` takes only numeric/repo-slug arguments, not an arbitrary shell string.

**Scope note.** Currently CI-queue-depth-specific — the only environmental-halt detector this repo has wired ([#1156](https://github.com/mattsears18/shipyard/issues/1156)/[#1399](https://github.com/mattsears18/shipyard/issues/1399)). A broader environmental cause (sustained host-load contention, a provider outage) is out of scope for this issue — see the [suggested direction](https://github.com/mattsears18/shipyard/issues/1402) for the general shape; only the CI-backpressure trigger below is wired today.

**Trigger — checked once per turn, after all of this turn's step-C dispatch decisions, immediately before step E's invariant line.** Enter a pause when ALL of:

1. `paused_on_environment.enabled` resolves to `true` (config default `true`).
2. `ci_backpressure == "held"` fired at least once this turn (the queue-depth check above actually held a slot).
3. `dispatched_this_turn == 0` — nothing at all got dispatched this turn, not even a CI-cheap-bias substitute.
4. `in_flight` (the post-turn count, the same value step E's `in_flight=<n>/<concurrency>` token reports) is `<= paused_on_environment.pause_when_in_flight_at_or_below` (config default `0`).
5. No `paused_on_environment` entry is already active (a pause never re-anchors over a live one — see the anchoring property above).

When the trigger holds:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064) before the
# shipyard-config.sh reads below — each Bash-tool call is a fresh, hermetic
# subshell, so nothing set in an earlier call survives into this one.
SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null || pwd)
export SHIPYARD_REPO_ROOT
max_hours=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get paused_on_environment.max_hours 2>/dev/null)
poll_interval=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get paused_on_environment.poll_interval_seconds 2>/dev/null)
paused_at="<iso-8601 UTC now>"
deadline_at="<paused_at + ${max_hours:-4}h, computed once here — never recomputed on a later check>"
reason="CI queue backpressure: queued=${queued_live:-0} > threshold=$threshold = pool_total($pool_total)×${multiplier:-5} — held with in_flight<=$in_flight"

# One per-field --set each, never a single whole-object literal:
# post-relocation the isolation guard refuses that shape (#1561).
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update \
  --session-id "<session-id>" \
  --allow-degraded-init --degraded-init-repo "<owner/repo>" \
  --set ".paused_on_environment.reason = \"$reason\"" \
  --set ".paused_on_environment.resume_probe_repo = \"<owner/repo>\"" \
  --set ".paused_on_environment.resume_probe_pool_total = $pool_total" \
  --set ".paused_on_environment.resume_probe_multiplier = ${multiplier:-5}" \
  --set ".paused_on_environment.paused_at = \"$paused_at\"" \
  --set ".paused_on_environment.deadline_at = \"$deadline_at\""
```

Increment the session-local `paused_on_environment_stats.paused` counter (working memory only — see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md), not mirrored to the session-state file), then arm the resume watch as a **background `Monitor`** — this is the entire fix, in one call: it re-arms a future wake source that would otherwise not exist. **Never an inline poll loop** — a maintainer applying this issue found that the worktree-isolation guard refuses a `Monitor` command carrying a `while true` loop on the identical grounds it refuses an equivalent inline `Bash` block ("too complex to verify that it stays inside the worktree"); [`scripts/watch-resume-probe.sh`](../../scripts/watch-resume-probe.sh) is the committed extraction (mirrors [`watch-pr-terminal.sh`](../../scripts/watch-pr-terminal.sh)'s precedent for the identical class of refusal, [#1326](https://github.com/mattsears18/shipyard/issues/1326)) — the `Monitor` call invokes it as ONE plain command, never a loop of its own:

```
Monitor({
  command: "bash \"$CLAUDE_PLUGIN_ROOT/scripts/watch-resume-probe.sh\" --repo \"<owner/repo>\" --pool-total \"<pool_total>\" --multiplier \"<multiplier>\" --interval \"<poll_interval, default 300>\" --max-wait \"<seconds remaining to deadline_at — NOT a fresh max_hours window>\"",
  description: "paused_on_environment resume probe (#1402)",
  persistent: true
})
```

`persistent: true` is required whenever `max_hours` exceeds `Monitor`'s own 1-hour `timeout_ms` cap (the built-in default of 4h routinely does) — without it the harness would kill the watch long before the script's own bounded `--max-wait` gets a chance to fire. `--max-wait` is computed from the **remaining** time to the already-anchored `deadline_at`, never a fresh window — this is what makes the anchoring property hold even across the (rare) case of a `Monitor` itself needing to be re-armed mid-pause (a harness restart, a `TaskStop`): re-arm with the same shrinking remainder, never `paused_on_environment.max_hours` again from scratch.

**Emit the invariant line and end the turn normally.** Arming the `Monitor` does NOT itself end the turn early or skip step E — the turn completes exactly as any other idle turn does (`idle_reason="parked (CI queue backpressure: ...); paused_on_environment armed — resume watch active"`), just with a live background watch now guaranteeing a future notification exists. This is the load-bearing difference from the pre-#1402 behavior: previously an idle turn under this exact condition ended with nothing further scheduled; now it ends with a bounded wake source armed.

**Resume — a turn triggered by the `Monitor`'s own notification, not an agent completion.** When `watch-resume-probe.sh` reaches a terminal state, its one stdout line arrives as a notification the same way an agent's completion does (per `steady-state.md`'s turn-shape framing) — treat it as a reconcile event at the top of the turn, before step A's normal return-string parsing (there is no worker return to parse; this event has its own shape):

- **`resumed pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s`** → clear `.paused_on_environment` (`session-state.sh update --set ".paused_on_environment = null"`), increment `paused_on_environment_stats.resumed` and add `elapsed` (in whole minutes) to `.total_paused_minutes` (session-local working memory, not mirrored — see that struct's entry in [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)), then run the **canonical fresh backlog fetch** — the same fetch [drain.md's termination-assertion step 4](./drain.md#termination-assertion) and [`last_fresh_fetch`](./invariant-line.md) require before any termination-adjacent decision — before resuming normal dispatch from step C. Re-fetching here (rather than trusting whatever `raw_backlog`/`ready_issues` held at pause time) is what satisfies "resume re-fetches the backlog before dispatching": a pause can legitimately last long enough for the backlog itself to have changed. Log: `[paused-on-environment-resume] condition cleared (queued=<Q> <= threshold=<T>) after <elapsed>; fresh-fetched backlog and resumed dispatch.`
- **`held-timeout pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s max_wait=<S>s`** or **`error pool_total=<N> reason="<msg>" elapsed=<S>s`** → the bound expired without the environment clearing, or the watcher itself stopped being able to check (both are terminal per the watcher's own contract — see its header comment on why silence is never the outcome). Clear `.paused_on_environment`, increment `paused_on_environment_stats.expired` and add `elapsed` to `.total_paused_minutes`, and degrade to a genuine hand-back: log `[paused-on-environment-expired] condition did not clear within <max_hours>h (<last known reason>); degrading to hand-back.` and surface it exactly as a `blocked`-classified refuse would — `needs-human-review` is the correct disposition (a saturated pool that outlasted the bound, or a `gh` outage, is a human problem). This does not end the session by itself; the loop falls through to its normal termination-assertion path on the next turn, where the still-workable backlog (if any survives re-validation) is exactly what would have kept the loop running before this issue existed.

**Registered in [drain.md's termination-queue registry](./drain.md#termination-assertion)** — a session cannot declare itself done while a pause is active and unexpired, mirroring `awaiting_external`'s row 7 exactly.

**`paused_env=<none|active>` feeds step E's invariant line** — `active` whenever `.paused_on_environment` is non-null at emission time (read fresh, not cached, same posture as `awaiting_ext=<ae>`); `none` otherwise. Unlike `awaiting_ext`, there is no queue depth to report — at most one pause is ever active — so the token is binary rather than a count.
