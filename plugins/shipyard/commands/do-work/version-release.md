# /shipyard:do-work — Release-on-non-claim version-slot hook (issue #1420)

**Loaded from [`steady-state.md`'s step B](./steady-state.md#b-release-the-slot), immediately before the completed entry is removed from `in_flight` — not part of the ordered per-session walk.** Split out from `steady-state.md` itself ([#611](https://github.com/mattsears18/shipyard/issues/611)'s phase-file size cap — `steady-state.md` was within ~3KB of the 245760-byte cap on `main` before this hook existed, the same pressure [`invariant-line.md`](./invariant-line.md) and [`disk-space-guard.md`](./disk-space-guard.md) exist to relieve). Router: [`steady-state.md`](./steady-state.md). Sidebar: [`dont.md`](./dont.md).

## Why this step exists

[`next-available-version.sh compute`](../../scripts/next-available-version.sh) advances the session-local `version_cursor` **the instant it hands a slot out**, before the worker has done anything. When that dispatch terminates *without ever opening a PR* — a `blocked` return, a permission-classifier denial, a crash, or an explicit worker decline — nothing claims the slot, and every later `compute` in the session floors above the phantom.

`reseed-if-idle` ([#1417](https://github.com/mattsears18/shipyard/issues/1417)) cannot recover this variant, and that is not a shortcoming in it: it fires only once `session_prs` has **no OPEN member**, while this leak routinely happens with sibling PRs still open. The [#1420](https://github.com/mattsears18/shipyard/issues/1420) repro observed the cursor at `4.40.0` while the true highest claim across every open PR was `4.38.0` — from a worker that *declined* and never took any version at all, so no amount of bump-level discipline would have prevented it. **This step is the other half of the self-heal.**

See [`orchestrator-state-reference.md`](./orchestrator-state-reference.md#cold-orchestrator-state-structures) for the `version_cursor` struct, and [RATIONALE](../do-work-RATIONALE.md#release-on-non-claim--why-a-released-slot-becomes-a-hole-instead-of-a-cursor-rollback-and-why-that-needs-no-per-slot-promise-ledger-issue-1420) for the full design — in particular why a released slot becomes a *hole* rather than a cursor rollback, and why that needs no per-slot promise ledger.

## Ordering — run this BEFORE removing the slot from `in_flight`

The value this step needs is `.in_flight[<slot-id>].version_slot`, written at dispatch time per [dispatch-rules.md](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c). It lives on the entry step B is about to delete, so the read has to happen first.

## Why step B is the single funnel

Every mode's terminal return passes through step B — [A.0.5 says so explicitly](./steady-state.md#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing): *"Step B still fires on every completion path — A.0.5 does NOT replace it."* One call here therefore covers a `blocked` return, a crash-recovery reap, an explicit worker decline, and every disposition outcome that resolves an issue without a PR. **Do NOT scatter this across A.1's per-mode return branches** — that would need a dozen call sites and would grow one more with every future return shape, which is precisely the forgettability the [#1399](https://github.com/mattsears18/shipyard/issues/1399) token family exists to guard against.

The one non-claiming shape that never reaches step B is a **permission-classifier denial**: by the dispatch ordering rule, no `in_flight` slot is ever written for it. [dispatch-rules.md's denial cleanup](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) releases its own slot there, beside the worktree reap it already performs.

## The gate — did this dispatch claim its slot?

A dispatch **claimed** its slot iff this turn's [A.1](./steady-state.md#a1-parse-the-return-string) appended a PR to `session_prs` on this slot's account:

- `shipped #<N> via PR #<M>`
- `investigated+fixed #<N> via PR #<M>`
- `spiked+shipped #<N> via PR #<M>`
- `shipped main-ci-fix via PR #<M>` / `shipped pr-batch-fix via PR #<M>`
- `verified #<N>` carrying the optional `incidental PR: #<M>` token
- Either **`partial`** shape ([§6.5](../../agents/issue-worker/issue-work.md#65-split-dispatch-disposition-hand-back-the-operatorsecurity-residual-keep-the-issue-open-851) operator-residual, [§6.7](../../agents/issue-worker/issue-work.md#67-deferred-slice-disposition-hand-back-an-autonomously-workable-residual-to-a-new-issue-keep-the-issue-open-986) deferred-slice) — these opened a real PR that bumped the manifest, so they are claims even though `#<N>` stays open.

**Everything else is a non-claiming terminal** and releases: `blocked`, `errored`, `reaped`, any `noop:` shape, `investigated+needs-human-review` / `+closed-noise` / `+duplicate`, `spiked+needs-human-review`, a bare `verified #<N>` with no incidental PR, and an A.0.5 crash-recovery reap that recovered nothing.

## The call

**Skip entirely** when `version_coordination.enabled` is `false` or no `manifest_path` is configured (set `version_release=n/a`), or when the slot claimed its PR per the gate above (set `version_release=none`). Otherwise run it, substituting the literal `version_slot` value read off the entry:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
release_result=$("$CLAUDE_PLUGIN_ROOT/scripts/next-available-version.sh" release \
  --version "<version_slot>" \
  --cursor-file .shipyard-version-cursor 2>/dev/null || echo "release=noop-no-version")
```

## Setting the `version_release` token

Parse the single `release=<...>` line and set this turn's [`version_release`](./invariant-line.md) invariant-line token:

- `recorded-hole` / `already-recorded` / `noop-no-cursor` / `noop-above-cursor` → **`version_release=released`**. The hook ran; what it decided is the script's business, not the token's — exactly as `ci_backpressure=checked` reports the check ran rather than what the queue depth was.
- `noop-no-version` / `noop-bad-version`, or you skipped the call on a coordination-enabled repo → **`version_release=skipped`**. **This is the divergence smell the token exists for**: the slot carried no recorded `version_slot`, which means the dispatch-time bookkeeping was dropped, and this slot's version has leaked for the rest of the session.

## Fire-and-forget — and why that is safe

Never block the turn on this call. A release **never lowers the cursor**: slots are handed out monotonically, so a released slot may not be the highest one outstanding, and decrementing would hand a later batch member's already-promised value back out — reintroducing the exact [#437](https://github.com/mattsears18/shipyard/issues/437) collision the cursor exists to prevent. The released version is recorded as a *hole* instead, and the next `compute` hands it back out (reporting it as `reclaimed_slot`) only when it sits strictly above the floor derived from ground truth alone.

**A skipped or failed release therefore degrades to the status quo — the slot stays leaked, exactly as before #1420 — never to a collision.** That asymmetry is what lets this hook ship without per-slot promise bookkeeping, and it is why there is deliberately no mechanical dispatch-blocking backstop here of the kind [#1414](https://github.com/mattsears18/shipyard/issues/1414) added for `ci_backpressure`: a skipped release cannot produce an unsafe dispatch, only a slightly inflated version number.
