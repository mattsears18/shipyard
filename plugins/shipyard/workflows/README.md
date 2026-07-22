# `plugins/shipyard/workflows/` — Dynamic Workflows substrate

This directory holds shipyard's [Claude Code Dynamic Workflows](https://code.claude.com/docs/en/workflows) scripts — the `Workflow`-tool substrate for `/shipyard:do-work`'s dispatch loop.

> **Phase 4 — the substrate cutover (issue [#790](https://github.com/mattsears18/shipyard/issues/790), part of the [#782](https://github.com/mattsears18/shipyard/issues/782) epic; carries the `2.x` → `3.0.0` major bump).** Phase 1 ([#787](https://github.com/mattsears18/shipyard/issues/787)) committed this directory as inert reference scaffolding. Phase 2 ([#788](https://github.com/mattsears18/shipyard/issues/788)) wired the first mode — `issue-work`. Phase 3 ([#789](https://github.com/mattsears18/shipyard/issues/789)) wired the remaining six — `fix-checks-only`, `fix-rebase`, `fix-main-ci`, `fix-failing-prs-batch`, `investigate`, `spike` — so ALL SEVEN `mode:`-driven workers run through [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) when opted in. **Phase 4 (this state) flips the built-in default of `dispatch.substrate` from `"agent"` to `"workflow"`** — so `/do-work` runs its dispatch loop on the `Workflow` tool by default, for every mode, with no config. The hand-rolled `Agent`-tool orchestrator ([`commands/do-work/dispatch-rules.md`](../commands/do-work/dispatch-rules.md) + [`steady-state.md`](../commands/do-work/steady-state.md)) is **retained, fully working, for one release** behind `dispatch.substrate: "agent"` — see the instant-revert box below. Retiring the `Agent`-tool path is the final #782 phase, not this one. See [dispatch-rules.md's substrate section](../commands/do-work/dispatch-rules.md#workflow-substrate-dispatch-for-every-worker-mode-opt-in-via-dispatchsubstrate-workflow--789-phase-3-of-782) for the full per-mode call-site walkthrough.

> ### ⚠️ Regression? Instant revert
> **`/shipyard:config set dispatch.substrate agent`** reverts the dispatch loop to the legacy `Agent`-tool path instantly, for every mode. That path is retained and fully working through this release — the cutover is a default flip, not a removal, so the revert is a one-line config change with no reinstall. Use it if a `Workflow`-substrate dispatch misbehaves; then file the regression against [`mattsears18/shipyard`](https://github.com/mattsears18/shipyard/issues) so the substrate can be fixed before the `Agent`-tool path is retired.

## Why scaffold now

The [#782](https://github.com/mattsears18/shipyard/issues/782) epic re-expresses the do-work dispatch loop on Claude Code's native Dynamic Workflows — a deterministic JavaScript orchestration script (`agent()`, `pipeline()`, `parallel()`, schema-validated returns) instead of prose the orchestrator re-interprets each turn. The practitioner consensus for a **known-shape** workflow (select → dispatch → verify → merge, with blocked-by sequencing — exactly shipyard's topology) favors deterministic orchestration: zero routing-token overhead, fixed cost/latency, and an auditable topology (declared, diffable, reviewable — like infrastructure-as-code).

Committing the **shape first**, behind a flag, let each subsequent phase migrate the substrate against a stable target rather than designing it and the migration in the same PR. Phase 1 (#787) committed the substrate script + structured-return schema + config flag, default untouched. Phase 2 (#788) wired the first real mode — `issue-work`. Phase 3 (#789) wired the remaining six modes. Phase 4 (#790, this state) **flips the default onto the substrate** now that all seven modes are wired and validated — the first phase that changes what a repo gets without opting in. The legacy `Agent`-tool path stays fully working for one release as the instant-revert override (see the box above), so the cutover is reversible with a one-line config change.

## Contents

| File | What it is |
|---|---|
| [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) | The dispatch-loop script: `select issues → dispatch (build the mode-specific prompt) → collect`. Every one of the seven `mode:` values has a full prompt builder (`buildIssueWorkPrompt`, `buildFixChecksOnlyPrompt`, `buildFixRebasePrompt`, `buildFixMainCiPrompt`, `buildFixFailingPrsBatchPrompt`, `buildInvestigatePrompt`, `buildSpikePrompt`) mirroring its dispatch-rules.md template byte-for-byte, including that mode's augmentations (verify-gate / user-feedback / phase-1-slice / version-coordination for issue-work; the version-coordination §4.6 carve-out for fix-rebase; the triage.auto_close policy for investigate; the decompose.max_subissues fan-out cap for spike). Heavily commented, including the worktree-isolation gap this substrate has relative to the `Agent` tool and how the caller closes it (per-mode: fresh branch off default vs. checked out directly onto an existing PR branch). |
| [`../schemas/worker-return.schema.json`](../schemas/worker-return.schema.json) | The structured-return schema each `agent()` call validates against — the schema-validated replacement for the free-text return-string convention ([`worker-preamble` § "Return-contract discipline"](../skills/worker-preamble/SKILL.md)) **for workflow-dispatched workers only**. Mirrored (by hand, not imported — the workflow runtime executes this script with no filesystem access of its own) as `workerReturnSchema` inside the `.workflow.js` file; keep the two in sync on any return-contract change. |

## The `dispatch.substrate` flag

A repo/user/local config knob selects the substrate (built-in default `"workflow"`, as of the #790 cutover):

```bash
/shipyard:config get dispatch.substrate          # -> workflow (default, as of #790)
/shipyard:config show | jq '.effective.dispatch'  # visible in the effective config
/shipyard:config set dispatch.substrate agent     # instant revert to the legacy Agent-tool path
```

| Value | Meaning |
|---|---|
| `workflow` (default, as of #790) | **Every mode** dispatches via the `Workflow` tool against this directory's script, with the orchestrator translating the structured return back into the same free-text vocabulary before handing it to reconcile. See [dispatch-rules.md's substrate section](../commands/do-work/dispatch-rules.md#workflow-substrate-dispatch-for-every-worker-mode-opt-in-via-dispatchsubstrate-workflow--789-phase-3-of-782) for the full per-mode call-site walkthrough. |
| `agent` | The legacy orchestrator dispatches each worker one-by-one via the `Agent` tool (`subagent_type` / `isolation: "worktree"` / `model`). Free-text worker return-string contract applies. **The instant-revert target** — retained fully working for one release; identical behavior to pre-#790. |

The knob lives in [`schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) (`dispatch.substrate`, enum `["agent","workflow"]`, default `"workflow"`) and the built-in defaults in [`scripts/shipyard-config.sh`](../scripts/shipyard-config.sh); it follows the standard 4-layer merge and is schema-validated on every load/set.

## The structured-return contract

Under the `agent` substrate a worker's last line is a free-text terminal string (`shipped #N via PR #M (auto-merge: enabled, checks: green)`, `blocked: <reason>`, `reaped: …`) that the orchestrator parses from prose. Under the `workflow` substrate each `agent()` call validates its worker's return against [`worker-return.schema.json`](../schemas/worker-return.schema.json), so a malformed or ambiguous return **fails loudly at the stage boundary** instead of being re-parsed — killing a class of "worker contract ambiguous" friction. The orchestrator then translates that structured result back into the free-text vocabulary before it reaches [steady-state.md's step A.1](../commands/do-work/steady-state.md#a1-parse-the-return-string), so reconcile logic itself never branches on which substrate produced the return.

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

## Worktree isolation under the `workflow` substrate

The `Agent` tool's `isolation: "worktree"` parameter has the harness auto-provision and cwd-pin an isolated worktree before a dispatched subagent runs its first tool call. The Dynamic Workflows docs document no equivalent option on `agent()` — the workflow script itself has no filesystem/shell access, and `agent()`'s documented options are `label` / `model` / `schema`, nothing isolation-shaped. Rather than assume parity that isn't documented, every mode's wiring closes the gap at the call site instead: the **orchestrator** (which still has full shell access, unlike the script) runs `git worktree add` itself before invoking the `Workflow` tool, passes the resulting path in as `worktreePath`, and the generated prompt's first instruction is an explicit `cd` into that path followed by the same git-dir-vs-git-common-dir verification `shipyard:worker-preamble`'s step-0 fail-fast already uses for the `Agent`-tool path. The exact `git worktree add` invocation is mode-dependent: `issue-work` / `investigate` / `spike` get a fresh branch off default (`-b do-work/issue-<N> origin/<default-branch>`); `fix-checks-only` / `fix-rebase` are checked out directly onto the **existing** PR branch being fixed/rebased (`-B <headRefName> origin/<headRefName>`); `fix-main-ci` / `fix-failing-prs-batch` get a synthetic-divert branch off default. See the script's own header comment ("Worktree isolation") and dispatch-rules.md's substrate section for the full per-mode mechanics.

## What stays OUT of the workflow script

shipyard's durable edge — **which** issues/PRs/diverts to pick, gate-label exclusion, author-trust gating, `blocked-by` chain sequencing, divert-queue priority, version coordination, house conventions — stays as the workflow's **control flow / injected input** (via the `args` global), not re-derived inside the script. The script owns the orchestration *shape* (select → dispatch → collect); the orchestrator owns the *policy*. That division is what no native tool provides and what every phase of the epic preserves.

## Out of scope for phase 4 (#790)

Deferred to later #782 phases — do not do these here:

- Removing or altering any part of the legacy `Agent`-tool dispatch path — it is retained, fully working, for one release as the instant-revert override. Its removal is the **final** #782 phase, gated on the `workflow` substrate proving itself across a release under the flipped default.
- Wiring `shipyard:decompose-worker` dispatch to this substrate — it doesn't take a `mode:` value, isn't dispatched from the per-issue decision tree, and is deliberately outside the per-mode routing table (see dispatch-rules.md's own callout for why).
- Exercising the script's own `parallel()` fan-out for a real multi-unit batch — the current wiring invokes the script once per work unit, mirroring the orchestrator's existing one-`Agent`-call-per-pool-slot shape; a genuine batch-dispatch mode is a separate, later design decision.
