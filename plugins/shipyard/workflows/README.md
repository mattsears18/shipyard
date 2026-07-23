# `plugins/shipyard/workflows/` — Dynamic Workflows substrate

This directory holds shipyard's [Claude Code Dynamic Workflows](https://code.claude.com/docs/en/workflows) scripts — the `Workflow`-tool substrate for `/shipyard:do-work`'s dispatch loop, **an alternate way a `mode:`-driven worker can be dispatched** (see the note below — it is no longer the only way).

> **Phase 5 of 5 shipped as planned (issue [#791](https://github.com/mattsears18/shipyard/issues/791), completing the [#782](https://github.com/mattsears18/shipyard/issues/782) epic; carried the `3.x` → `4.0.0` major bump) — since partially reverted by [#825](https://github.com/mattsears18/shipyard/issues/825).** Phase 1 ([#787](https://github.com/mattsears18/shipyard/issues/787)) committed this directory as inert reference scaffolding. Phase 2 ([#788](https://github.com/mattsears18/shipyard/issues/788)) wired the first mode — `issue-work`. Phase 3 ([#789](https://github.com/mattsears18/shipyard/issues/789)) wired the remaining six — `fix-checks-only`, `fix-rebase`, `fix-main-ci`, `fix-failing-prs-batch`, `investigate`, `spike`. Phase 4 ([#790](https://github.com/mattsears18/shipyard/issues/790)) flipped the built-in `dispatch.substrate` default from `"agent"` to `"workflow"`, retaining the hand-rolled `Agent`-tool orchestrator for one release as an instant-revert override. Phase 5 removed that legacy path and deleted the `dispatch.substrate` knob. **[#825](https://github.com/mattsears18/shipyard/issues/825) then found this substrate's dispatched workers could not perform a single file write** (the harness refused every `Edit`/`Write` call with a "parent bg session hasn't isolated" error, reproduced regardless of the parent orchestrator's own isolation state) and restored the `Agent`-tool dispatch shape as the default for `mode:`-driven workers — **without** reintroducing the `dispatch.substrate` knob. This directory's script is retained as the documented alternate shape, unmodified by #825. See [dispatch-rules.md's dispatch-shapes section](../commands/do-work/dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) for the current default/alternate split, and its [Workflow-substrate section](../commands/do-work/dispatch-rules.md#workflow-substrate-dispatch--an-alternate-dispatch-shape-825) for the full per-mode call-site walkthrough of this script.

> ### ⚠️ Upgrading from ≤ 3.1.x — delete your `dispatch` config block
> `dispatch.substrate` is gone from the schema, and the repo/local config schema is `additionalProperties: false` — so a `shipyard.config.json` (or `.shipyard/config.local.json`) that still carries a `dispatch` object now **fails validation** rather than being ignored. Delete the block; there is nothing to replace it with. If you were relying on `dispatch.substrate: "agent"` to route around a `Workflow`-substrate regression, that escape hatch no longer exists — file the regression against [`mattsears18/shipyard`](https://github.com/mattsears18/shipyard/issues) instead.

## Why this substrate

The [#782](https://github.com/mattsears18/shipyard/issues/782) epic re-expresses the do-work dispatch loop on Claude Code's native Dynamic Workflows — a deterministic JavaScript orchestration script (`agent()`, `pipeline()`, `parallel()`, schema-validated returns) instead of prose the orchestrator re-interprets each turn. The practitioner consensus for a **known-shape** workflow (select → dispatch → verify → merge, with blocked-by sequencing — exactly shipyard's topology) favors deterministic orchestration: zero routing-token overhead, fixed cost/latency, and an auditable topology (declared, diffable, reviewable — like infrastructure-as-code).

Committing the **shape first**, behind a flag, let each phase migrate against a stable target rather than designing the substrate and the migration in the same PR — and let the cutover (#790) ship reversibly, with a one-line config revert, before the legacy path was finally removed (#791).

## Contents

| File | What it is |
|---|---|
| [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) | The dispatch-loop script: `select issues → dispatch (build the mode-specific prompt) → collect`. Every one of the seven `mode:` values has a full prompt builder (`buildIssueWorkPrompt`, `buildFixChecksOnlyPrompt`, `buildFixRebasePrompt`, `buildFixMainCiPrompt`, `buildFixFailingPrsBatchPrompt`, `buildInvestigatePrompt`, `buildSpikePrompt`) mirroring its dispatch-rules.md prompt template, including that mode's augmentations (verify-gate / user-feedback / phase-1-slice / version-coordination for issue-work; the version-coordination §4.6 carve-out for fix-rebase; the triage.auto_close policy for investigate; the decompose.max_subissues fan-out cap for spike). Heavily commented, including the worktree-isolation gap this substrate has and how the caller closes it (per-mode: fresh branch off default vs. checked out directly onto an existing PR branch). |
| [`../schemas/worker-return.schema.json`](../schemas/worker-return.schema.json) | The structured-return schema each `agent()` call validates against — the schema-validated return contract for every workflow-dispatched worker (see [`worker-preamble` § "Return-contract discipline"](../skills/worker-preamble/SKILL.md)). Mirrored (by hand, not imported — the workflow runtime executes this script with no filesystem access of its own) as `workerReturnSchema` inside the `.workflow.js` file; keep the two in sync on any return-contract change. |

## No configuration

There is no substrate flag. The `dispatch.substrate` knob that selected between substrates during the migration was removed in #791 (see the upgrade box above) and was **not** reintroduced when [#825](https://github.com/mattsears18/shipyard/issues/825) restored the `Agent`-tool shape as the default — the choice is spec-level (documented in dispatch-rules.md), not a config a repo owner tunes. `/shipyard:do-work` dispatches every `mode:`-driven worker through the default `Agent`-tool shape; this directory's script is the documented alternate.

The `Agent` tool is still used elsewhere in shipyard — [`shipyard:verify-worker`](../agents/verify-worker.md) (dispatched by the issue-work worker, with `isolation: "worktree"`), [`shipyard:decompose-worker`](../agents/decompose-worker.md), the read-only scope-preflight and refinement workers — none of which take a `mode:` value. This substrate governs the seven worker modes only.

## The structured-return contract

Each `agent()` call validates its worker's return against [`worker-return.schema.json`](../schemas/worker-return.schema.json), so a malformed or ambiguous return **fails loudly at the stage boundary** instead of being re-parsed from prose — killing a class of "worker contract ambiguous" friction. The orchestrator then translates that structured result back into the free-text vocabulary the reconcile is written against before it reaches [steady-state.md's step A.1](../commands/do-work/steady-state.md#a1-parse-the-return-string), so reconcile logic never has to learn a second return format.

The schema is a 1:1 structured encoding of the same vocabulary the per-mode specs document — e.g. the free-text `shipped #N via PR #M (auto-merge: enabled, checks: green)` becomes:

```json
{ "mode": "issue-work", "outcome": "shipped", "issue": 787, "pr": 812,
  "auto_merge": "enabled", "checks": "green" }
```

and `blocked #N at pre-push: local unit suite failing` becomes:

```json
{ "mode": "issue-work", "outcome": "blocked", "issue": 787,
  "blocked_stage": "pre-push", "blocked_reason": "local unit suite failing" }
```

See the schema's field descriptions (or dispatch-rules.md's translation table) for the full mapping (outcome classes, the `auto_merge` categorization including the `merged-direct-ungated` refinement, the investigate/spike `disposition` set, and the `reaped` retryable path).

## Worktree isolation — the caller's job

The Dynamic Workflows docs document no worktree/isolation/sandboxing option on `agent()`: the workflow script itself has no filesystem/shell access, and `agent()`'s documented options are `label` / `model` / `schema`, nothing isolation-shaped. (The retired `Agent`-tool path got this for free — `isolation: "worktree"` had the harness auto-provision and cwd-pin the worktree before the subagent's first tool call.) Rather than assume undocumented parity, every mode's wiring closes the gap at the call site: the **orchestrator** (which still has full shell access, unlike the script) runs `git worktree add` itself before invoking the `Workflow` tool, passes the resulting path in as `worktreePath`, and the generated prompt's first instruction is an explicit `cd` into that path followed by the same git-dir-vs-git-common-dir verification `shipyard:worker-preamble`'s step-0 fail-fast uses.

The exact `git worktree add` invocation is mode-dependent: `issue-work` / `investigate` / `spike` get a fresh branch off default (`-b do-work/issue-<N> origin/<default-branch>`); `fix-checks-only` / `fix-rebase` are checked out directly onto the **existing** PR branch being fixed/rebased (`-B <headRefName> origin/<headRefName>`); `fix-main-ci` / `fix-failing-prs-batch` get a synthetic-divert branch off default. See the script's own header comment ("Worktree isolation") and dispatch-rules.md's substrate section for the full per-mode mechanics.

**Two enforcement layers, because the guarantee is load-bearing:** [`hooks/enforce-worktree-isolation.sh`](../hooks/enforce-worktree-isolation.sh) hard-fails a `Workflow` dispatch of this script carrying a work unit with no `worktreePath`, and the script's own `worktreeAnchorLines` helper emits a `CALLER BUG` instruction telling the worker to return `blocked` (stage `worktree-anchor`) rather than operate from an unpinned cwd.

**Reap a pre-provisioned worktree if the dispatch never happens.** Because the orchestrator creates the worktree *before* the `Workflow` call, a call the harness refuses (permission classifier) leaves a real directory and branch behind with no worker and no `.in_flight` slot — nothing else will clean it up. See [dispatch-rules.md § "Dispatch denied by the harness permission classifier"](../commands/do-work/dispatch-rules.md#dispatch-denied-by-the-harness-permission-classifier-718).

## What stays OUT of the workflow script

shipyard's durable edge — **which** issues/PRs/diverts to pick, gate-label exclusion, author-trust gating, `blocked-by` chain sequencing, divert-queue priority, version coordination, house conventions — stays as the workflow's **control flow / injected input** (via the `args` global), not re-derived inside the script. The script owns the orchestration *shape* (select → dispatch → collect); the orchestrator owns the *policy*. That division is what no native tool provides and what every phase of the epic preserved.

## Still out of scope

Not part of the #782 epic; a separate design decision if ever wanted:

- Wiring `shipyard:decompose-worker` (or the other non-`mode:` agents) to this substrate — they don't take a `mode:` value, aren't dispatched from the per-issue decision tree, and are deliberately outside the per-mode routing table (see dispatch-rules.md's own callout for why).
- Exercising the script's own `parallel()` fan-out for a real multi-unit batch — the current wiring invokes the script once per work unit, mirroring the orchestrator's `--concurrency N` rolling pool; a genuine batch-dispatch mode is a separate, later design decision.
