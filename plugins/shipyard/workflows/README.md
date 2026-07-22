# `plugins/shipyard/workflows/` — Dynamic Workflows substrate

This directory holds shipyard's [Claude Code Dynamic Workflows](https://code.claude.com/docs/en/workflows) scripts — the `Workflow`-tool substrate for `/shipyard:do-work`'s dispatch loop.

> **Phase 2 — `issue-work` is wired (issue [#788](https://github.com/mattsears18/shipyard/issues/788), part of the [#782](https://github.com/mattsears18/shipyard/issues/782) epic).** Phase 1 ([#787](https://github.com/mattsears18/shipyard/issues/787)) committed this directory as inert reference scaffolding. Phase 2 wires **one mode** — `issue-work` — to actually run through [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) when a repo opts in with `dispatch.substrate: "workflow"`. Everything here is still **additive — not replacing** — the existing hand-rolled `Agent`-tool orchestrator ([`commands/do-work/dispatch-rules.md`](../commands/do-work/dispatch-rules.md) + [`steady-state.md`](../commands/do-work/steady-state.md)): at the shipped default (`dispatch.substrate: "agent"`) `/do-work` dispatches exactly as it does today, and even with `"workflow"` selected, every mode OTHER than `issue-work` (`fix-checks-only`, `fix-rebase`, `fix-main-ci`, `fix-failing-prs-batch`, `investigate`, `spike`) still dispatches through the unchanged `Agent`-tool path — see [dispatch-rules.md's substrate section](../commands/do-work/dispatch-rules.md#workflow-substrate-dispatch-for-mode-issue-work-opt-in-via-dispatchsubstrate-workflow--788-phase-2-of-782) for the full mixed-mode-operation picture. Migrating the remaining modes and cutting over the default are both still deferred (#790+).

## Why scaffold now

The [#782](https://github.com/mattsears18/shipyard/issues/782) epic re-expresses the do-work dispatch loop on Claude Code's native Dynamic Workflows — a deterministic JavaScript orchestration script (`agent()`, `pipeline()`, `parallel()`, schema-validated returns) instead of prose the orchestrator re-interprets each turn. The practitioner consensus for a **known-shape** workflow (select → dispatch → verify → merge, with blocked-by sequencing — exactly shipyard's topology) favors deterministic orchestration: zero routing-token overhead, fixed cost/latency, and an auditable topology (declared, diffable, reviewable — like infrastructure-as-code).

Committing the **shape first**, behind a flag, lets each subsequent phase migrate one mode against a stable target rather than designing the substrate and the migration in the same PR. Phase 1 (#787) committed the substrate script + structured-return schema + config flag, with the default untouched. Phase 2 (#788, this state) wires the first real mode — `issue-work` — against that stable target; the default is still untouched, and only `issue-work` moves.

## Contents

| File | What it is |
|---|---|
| [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) | The dispatch-loop script: `select issues → dispatch (build the mode-specific prompt) → collect`. `issue-work` has a full prompt builder (`buildIssueWorkPrompt`) mirroring dispatch-rules.md's `mode: issue-work` template byte-for-byte, including the verify-gate / user-feedback / phase-1-slice / version-coordination augmentations. Every other mode still uses a generic placeholder builder — none of them are reachable through this script via `/do-work`'s own routing yet. Heavily commented, including the worktree-isolation gap this substrate has relative to the `Agent` tool and how the caller closes it. |
| [`../schemas/worker-return.schema.json`](../schemas/worker-return.schema.json) | The structured-return schema each `agent()` call validates against — the schema-validated replacement for the free-text return-string convention ([`worker-preamble` § "Return-contract discipline"](../skills/worker-preamble/SKILL.md)) **for workflow-dispatched workers only**. Mirrored (by hand, not imported — the workflow runtime executes this script with no filesystem access of its own) as `workerReturnSchema` inside the `.workflow.js` file; keep the two in sync on any return-contract change. |

## The `dispatch.substrate` flag

A repo/user/local config knob selects the substrate (built-in default `"agent"`):

```bash
/shipyard:config get dispatch.substrate          # -> agent (default)
/shipyard:config show | jq '.effective.dispatch'  # visible in the effective config
/shipyard:config set dispatch.substrate workflow  # opt-in — issue-work only, as of phase 2
```

| Value | Meaning |
|---|---|
| `agent` (default) | The existing orchestrator dispatches each worker one-by-one via the `Agent` tool (`subagent_type` / `isolation: "worktree"` / `model`). Free-text worker return-string contract applies. **No behavior change from pre-#787.** |
| `workflow` | **`issue-work` candidates only** (as of phase 2, #788) dispatch via the `Workflow` tool against this directory's script, with the orchestrator translating the structured return back into the same free-text vocabulary before handing it to reconcile. Every other mode (`fix-checks-only`, `fix-rebase`, `fix-main-ci`, `fix-failing-prs-batch`, `investigate`, `spike`) is **unaffected** — still `Agent`-tool dispatch, unconditionally, until a later #782 phase migrates it. See [dispatch-rules.md's substrate section](../commands/do-work/dispatch-rules.md#workflow-substrate-dispatch-for-mode-issue-work-opt-in-via-dispatchsubstrate-workflow--788-phase-2-of-782) for the full call-site walkthrough. |

The knob lives in [`schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) (`dispatch.substrate`, enum `["agent","workflow"]`, default `"agent"`) and the built-in defaults in [`scripts/shipyard-config.sh`](../scripts/shipyard-config.sh); it follows the standard 4-layer merge and is schema-validated on every load/set.

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

The `Agent` tool's `isolation: "worktree"` parameter has the harness auto-provision and cwd-pin an isolated worktree before a dispatched subagent runs its first tool call. The Dynamic Workflows docs document no equivalent option on `agent()` — the workflow script itself has no filesystem/shell access, and `agent()`'s documented options are `label` / `model` / `schema`, nothing isolation-shaped. Rather than assume parity that isn't documented, the `issue-work` wiring closes the gap at the call site instead: the **orchestrator** (which still has full shell access, unlike the script) runs `git worktree add` itself before invoking the `Workflow` tool, passes the resulting path in as `worktreePath`, and the generated prompt's first instruction is an explicit `cd` into that path followed by the same git-dir-vs-git-common-dir verification `shipyard:worker-preamble`'s step-0 fail-fast already uses for the `Agent`-tool path. See the script's own header comment ("Worktree isolation") and dispatch-rules.md's substrate section for the full mechanics.

## What stays OUT of the workflow script

shipyard's durable edge — **which** issues to pick, gate-label exclusion, author-trust gating, `blocked-by` chain sequencing, version coordination, house conventions — stays as the workflow's **control flow / injected input** (via the `args` global), not re-derived inside the script. The script owns the orchestration *shape* (select → dispatch → collect); the orchestrator owns the *policy*. That division is what no native tool provides and what every phase of the epic preserves.

## Out of scope for phase 2 (#788)

Deferred to later #782 phases — do not do these here:

- Migrating any mode other than `issue-work` to the script.
- Flipping the `dispatch.substrate` default off `"agent"` (the cutover — #790+).
- Removing or altering any part of the existing `Agent`-tool dispatch path.
- Exercising the script's own `parallel()` fan-out for a real multi-unit batch — the current wiring invokes the script once per work unit, mirroring the orchestrator's existing one-`Agent`-call-per-pool-slot shape; a genuine batch-dispatch mode is a separate, later design decision.
