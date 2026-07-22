# `plugins/shipyard/workflows/` — Dynamic Workflows substrate (scaffold)

This directory holds shipyard's [Claude Code Dynamic Workflows](https://code.claude.com/docs/en/workflows) scripts — the `Workflow`-tool substrate for `/shipyard:do-work`'s dispatch loop.

> **Phase 1 scaffold — nothing here is wired yet (issue [#787](https://github.com/mattsears18/shipyard/issues/787), part of the [#782](https://github.com/mattsears18/shipyard/issues/782) epic).** Everything in this directory is **additive scaffolding committed alongside — not replacing** — the existing hand-rolled `Agent`-tool orchestrator ([`commands/do-work/dispatch-rules.md`](../commands/do-work/dispatch-rules.md) + [`steady-state.md`](../commands/do-work/steady-state.md)). At the shipped default (`dispatch.substrate: "agent"`) `/do-work` dispatches exactly as it does today. No worker mode runs through the workflow script. Selecting `dispatch.substrate: "workflow"` is **reserved and inert** until the cutover phase (#790+) wires a mode to it.

## Why scaffold now

The [#782](https://github.com/mattsears18/shipyard/issues/782) epic re-expresses the do-work dispatch loop on Claude Code's native Dynamic Workflows — a deterministic JavaScript orchestration script (`agent()`, `pipeline()`, `parallel()`, schema-validated returns) instead of prose the orchestrator re-interprets each turn. The practitioner consensus for a **known-shape** workflow (select → dispatch → verify → merge, with blocked-by sequencing — exactly shipyard's topology) favors deterministic orchestration: zero routing-token overhead, fixed cost/latency, and an auditable topology (declared, diffable, reviewable — like infrastructure-as-code).

Committing the **shape first**, behind a flag, lets each subsequent phase migrate one mode against a stable target rather than designing the substrate and the migration in the same PR. This is the phase-1 slice: substrate script + structured-return schema + config flag, with the default untouched.

## Contents

| File | What it is |
|---|---|
| [`do-work-dispatch.workflow.js`](./do-work-dispatch.workflow.js) | The dispatch-loop scaffold: `select issues → pipeline(implement, verify, open-PR/arm-merge)` with a `parallel()` concurrency pool (the `--concurrency N` rolling worker pool) and schema-validated worker returns. Heavily commented; **not yet invoked**. |
| [`../schemas/worker-return.schema.json`](../schemas/worker-return.schema.json) | The structured-return schema each pipeline stage validates against — the schema-validated replacement for the free-text return-string convention ([`worker-preamble` § "Return-contract discipline"](../skills/worker-preamble/SKILL.md)) **for workflow-dispatched workers only**. |

## The `dispatch.substrate` flag

A repo/user/local config knob selects the substrate (built-in default `"agent"`):

```bash
/shipyard:config get dispatch.substrate          # -> agent (default)
/shipyard:config show | jq '.effective.dispatch'  # visible in the effective config
/shipyard:config set dispatch.substrate workflow  # reserved — inert until cutover
```

| Value | Meaning |
|---|---|
| `agent` (default) | The existing orchestrator dispatches each worker one-by-one via the `Agent` tool (`subagent_type` / `isolation: "worktree"` / `model`). Free-text worker return-string contract applies. **No behavior change from pre-#787.** |
| `workflow` | The Dynamic Workflows substrate — the loop authored as this directory's script, workers returning schema-validated structured results. **Reserved scaffolding as of #787: selecting it does NOT yet change dispatch.** Leave at `agent` until the cutover phase ships. |

The knob lives in [`schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) (`dispatch.substrate`, enum `["agent","workflow"]`, default `"agent"`) and the built-in defaults in [`scripts/shipyard-config.sh`](../scripts/shipyard-config.sh); it follows the standard 4-layer merge and is schema-validated on every load/set.

## The structured-return contract

Under the `agent` substrate a worker's last line is a free-text terminal string (`shipped #N via PR #M (auto-merge: enabled, checks: green)`, `blocked: <reason>`, `reaped: …`) that the orchestrator parses from prose. Under the `workflow` substrate each `agent()` / `pipeline()` stage validates its worker's return against [`worker-return.schema.json`](../schemas/worker-return.schema.json), so a malformed or ambiguous return **fails loudly at the stage boundary** instead of being re-parsed — killing a class of "worker contract ambiguous" friction.

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

See the schema's field descriptions for the full mapping (outcome classes, the `auto_merge` categorization including the `merged-direct-ungated` refinement, the investigate/spike `disposition` set, and the `reaped` retryable path).

## What stays OUT of the workflow script

shipyard's durable edge — **which** issues to pick, gate-label exclusion, author-trust gating, `blocked-by` chain sequencing, version coordination, house conventions — stays as the workflow's **control flow / injected input** (via the `args` global), not re-derived inside the script. The script owns the orchestration *shape* (select → pipeline → parallel); the orchestrator owns the *policy*. That division is what no native tool provides and what every phase of the epic preserves.

## Out of scope for phase 1 (#787)

Deferred to later #782 phases — do not do these here:

- Wiring any worker mode to the script (the cutover — #790+).
- Flipping the `dispatch.substrate` default off `"agent"`.
- Removing or altering any part of the existing `Agent`-tool dispatch path.
