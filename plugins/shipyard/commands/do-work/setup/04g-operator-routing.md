# /shipyard:do-work — Setup phase · `agent-console` routing (a route, not a drop)

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Route `agent-console` issues to `operator_queue`" bullet. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why this fragment exists (issue [#1251](https://github.com/mattsears18/shipyard/issues/1251))

`agent-console` used to be enumerated in `04-backlog-divert.md`'s drop-label list, under a header whose verb is *drop*, beside labels that genuinely mean not-workable (`blocked:ci`, `wontfix`, `discussion`, `needs-human-review`, `tracking`). It was never actually dropped — trailing prose explained it is drained by the [operator phase](../operate.md) — but structure is read before prose, and structure is what gets copied when someone re-derives the filter.

Maintainer: *"the agent-console labeled issues are ALWAYS dispatchable. That's the whole reason why we named it AGENT console. Should we just eliminate that label because it keeps creating confusion?"*

**The label stays.** Eliminating it would send console work (a cloud console, a deploy platform, a store listing) to a code worker that structurally cannot drive it, or starve the operator path of input — the `operator_queue` + operator phase, the browser-backend preflight, and `/my-turn --chrome-prompt` all depend on this label as their entry signal. **Renaming it again is also not the fix** — it was already renamed once for exactly this reason (`needs-operator` → `agent-console`, [#995](https://github.com/mattsears18/shipyard/issues/995)) and the confusion survived the rename. The fix is how the filter *models* the label, not what it's called.

**Evidence this misled in practice:** a completion-ledger taxonomy built from this spec ([`04f-completion-ledger.md`](./04f-completion-ledger.md#the-bucket-taxonomy)) initially placed `agent-console` in its `human-gated` bucket, reading the drop-list enumeration as authoritative — corrected only because the maintainer objected (see that file's "Correction" callout). Separately, [#1093](https://github.com/mattsears18/shipyard/issues/1093) exists entirely because `/my-turn` filters `agent-console` out of the human queue on the *premise* that the operator phase drains it — a premise nothing recorded, requiring a whole config knob (`my_turn.assume_operator_enabled`) to compensate for the queue membership never being explicit here.

## The rule, stated once

**`agent-console` is dispatchable — by the operator phase, not a code worker. It is never a human hand-back unless the operator phase is disabled.**

## How the routing works

At step 4, a trusted-author issue carrying `agent-console` is removed from the code-worker candidate set — the same mechanical effect as a drop, so `raw_backlog` never contains it. What makes this a *route* rather than a drop is what happens to the label afterward. **Exception — a parked `agent-console` issue is a drop, not a route ([#1592](https://github.com/mattsears18/shipyard/issues/1592)):** `classify` evaluates the park clauses (`blocked-by-open-issue`, `event-gated`, `pr-collision-gated`, `time-gated`, `someday-milestone`) before the operator route, and the proactive sweep skips an issue classify dropped, so a configured park mechanism holds for operator items too.

- **Operator phase active (the default — see [`operate.md`](../operate.md)).** The label itself is the durable signal [`operate/01-queue-and-authorization.md`'s proactive feeder](../operate/01-queue-and-authorization.md#the-operator_queue-and-its-two-feeders) reads at each step-D tick to enqueue the issue into `operator_queue`, which the orchestrator drains itself by driving the user's real browser. No separate enqueue call is needed at step 4 — the proactive sweep already scans for `agent-console`-labeled open issues independently, so removing the issue from `raw_backlog` here and leaving the label in place is sufficient hand-off. The [completion ledger](./04f-completion-ledger.md#the-bucket-taxonomy) counts it as bucket 5 — dispatchable — not bucket 4 (human-gated). With the operator phase enabled, an `agent-console` issue blocks session completion the same as any other dispatchable issue, via `operator_queue`'s own drained-to-empty termination condition ([`drain.md`](../drain.md#termination-assertion)).
- **`--no-operate` / `--hands-off`.** The operator phase never runs and `operator_queue` stays unused, so an `agent-console` issue has no worker capable of draining it this session. It falls through to the **only** case where it genuinely belongs beside `needs-human-review` — explicitly, not by silent assumption. Report it as such rather than letting it vanish from both the dispatch queue and the summary.

## Rename provenance (moved here from the old drop-list prose)

`agent-console` was renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995) — `needs-operator` read as "needs a *human* operator," the opposite of its meaning. The legacy-name back-compat window is closed ([#1082](https://github.com/mattsears18/shipyard/issues/1082)): zero issues in this repo carried `needs-operator` at migration time, so this filter no longer recognizes the old name.

## What this fragment does not change

Per [#1251](https://github.com/mattsears18/shipyard/issues/1251)'s scope: this is a modeling/structure fix to the filter and its documentation. `operator_queue`'s drain mechanics, its two feeders, and what `agent-console` *means* are unchanged — see [`operate/01-queue-and-authorization.md`](../operate/01-queue-and-authorization.md) for that machinery, which already treats `operator_queue` as first-class session state (listed alongside `raw_backlog` / `ready_issues` / `investigate_candidates` in [`do-work.md`'s orchestrator-state](../../do-work.md#orchestrator-state)) and already implements the `--no-operate` fallback described above. Retiring `/my-turn`'s `my_turn.assume_operator_enabled` knob (the mechanism [#1093](https://github.com/mattsears18/shipyard/issues/1093) built to compensate for this exact gap) is a follow-up, not part of this fix — `/my-turn` can now read `operator_queue` membership directly instead of inferring it, but that consumer-side change is out of scope here.
