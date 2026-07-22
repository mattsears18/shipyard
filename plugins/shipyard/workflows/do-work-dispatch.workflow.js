/*
 * do-work-dispatch.workflow.js — Dynamic Workflows scaffold for /shipyard:do-work
 * ==============================================================================
 *
 * PHASE 1 SCAFFOLD (issue #787, part of the #782 epic). This script encodes the
 * KNOWN SHAPE of the /shipyard:do-work dispatch loop as a native Claude Code
 * Dynamic Workflow (the `Workflow` tool), so it can run ALONGSIDE — not in place
 * of — the existing hand-rolled `Agent`-tool orchestrator
 * (commands/do-work/dispatch-rules.md + steady-state.md).
 *
 * IT IS NOT WIRED TO ANYTHING YET. As of #787:
 *   - `dispatch.substrate` defaults to "agent" (schemas/shipyard.config.schema.json),
 *     so /do-work dispatches exactly as before.
 *   - No worker mode is dispatched through this script. Selecting
 *     `dispatch.substrate: "workflow"` is reserved and inert until the cutover
 *     phase (#790+) wires a mode to it.
 *   - This file is a reference/template committed for review and iteration. The
 *     later #782 phases (migrate issue-work → migrate fix-* modes → cut over
 *     /status → retire the legacy path) evolve it into the live substrate.
 *
 * WHY SCAFFOLD IT NOW. Moving the dispatch plan "into code" is the durable win the
 * epic is after: zero routing-token overhead, fixed cost/latency, and an auditable
 * topology (declared, diffable, reviewable — like infrastructure-as-code). shipyard's
 * do-work topology (select → dispatch → verify → merge, with blocked-by sequencing)
 * is exactly a known-shape workflow. Committing the shape first lets each subsequent
 * phase migrate one mode against a stable target instead of designing the substrate
 * and the migration in the same PR.
 *
 * RUNTIME API used here (Claude Code Dynamic Workflows — code.claude.com/docs/en/workflows):
 *   - `export const meta = { name, description }` — the saved-workflow header.
 *   - top-level `await` — the body is plain JavaScript.
 *   - `agent(prompt, opts)` — spawn ONE subagent. `opts.schema` validates its
 *     structured return (we point it at schemas/worker-return.schema.json's shape);
 *     `opts.label` names it in the /workflows progress view; `opts.model` routes the
 *     stage to a specific model (mirrors resolve-dispatch-model.sh's per-mode tiering).
 *   - `pipeline(list, fn)` — run one agent per item in a list.
 *   - `parallel(tasks, opts)` — run a bounded-concurrency pool over tasks (the
 *     `--concurrency N` rolling worker pool). NOTE: the exact `parallel()` option
 *     surface is not fully public as of this writing; the shape below is the
 *     intended encoding and is refined when a mode is actually wired (see the
 *     "SCAFFOLD" comment on the parallel() call).
 *   - `args` — global carrying invocation input (here: the selected-issue set,
 *     concurrency, repo, and per-mode model map the orchestrator hands in).
 *
 * The runtime caps concurrency at 16 agents and 1,000 agents/run regardless of what
 * this script requests — see the docs "Behavior and limits" table.
 *
 * WHAT STAYS OUT OF THIS SCRIPT (shipyard's durable policy edge, kept as the
 * workflow's control flow / injected via `args`, NOT re-derived here):
 *   - WHICH issues to pick (backlog fetch + gate-label exclusion + author trust +
 *     blocked-by sequencing) — commands/do-work/setup/* + dispatch-rules.md.
 *   - Worktree isolation, per-mode model resolution, version coordination — the
 *     orchestrator computes these and passes them in.
 * The script's job is the ORCHESTRATION shape (select → pipeline → parallel), not
 * the policy. That division is what no native tool provides and what the epic keeps.
 */

export const meta = {
  name: 'do-work-dispatch',
  description:
    'SCAFFOLD (#787, not yet wired): the /shipyard:do-work dispatch loop expressed as a ' +
    'Dynamic Workflow — select issues → pipeline(implement, verify, open-PR/arm-merge) ' +
    'with a parallel() concurrency pool and schema-validated worker returns. Inert until ' +
    'dispatch.substrate == "workflow" AND a later #782 phase wires a mode to it.',
}

// ---------------------------------------------------------------------------
// Invocation input (injected by the orchestrator via the `args` global).
// The orchestrator — NOT this script — decides these, applying shipyard's
// prioritization + gate-label exclusion + author-trust + blocked-by sequencing.
// Defaults keep the script runnable in isolation for a dry read.
// ---------------------------------------------------------------------------
const input = typeof args === 'object' && args !== null ? args : {}
const repo = input.repo ?? '<owner/repo>'
const concurrency = Math.max(1, Number(input.concurrency ?? 1)) // --concurrency N; runtime caps at 16
const selectedIssues = Array.isArray(input.issues) ? input.issues : [] // [{ number, mode, model, trust, branch }]

// Per-role model map, mirroring resolve-dispatch-model.sh's tiering. Passed in so
// the substrate stays config-driven rather than hardcoding model ids here.
const models = input.models ?? {}

// The structured-return contract every stage validates against. This is the shape
// of schemas/worker-return.schema.json — the workflow runtime validates each
// agent() result against `schema`, so a malformed return fails at the stage
// boundary instead of being re-parsed from prose (the free-text return-string
// convention this replaces for workflow-dispatched workers only).
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: {
      type: 'string',
      enum: [
        'issue-work',
        'fix-checks-only',
        'fix-rebase',
        'fix-main-ci',
        'fix-failing-prs-batch',
        'investigate',
        'spike',
      ],
    },
    outcome: {
      type: 'string',
      enum: ['shipped', 'green', 'rebased', 'noop', 'blocked', 'reaped', 'disposition'],
    },
    issue: { type: ['integer', 'null'] },
    pr: { type: ['integer', 'null'] },
    auto_merge: {
      type: ['string', 'null'],
      enum: [
        'enabled',
        'gated-manual',
        'merged-direct',
        'merged-direct-ungated',
        'unavailable',
        'gated-external',
        null,
      ],
    },
    checks: { type: ['string', 'null'], enum: ['green', 'pending', 'failing', null] },
    disposition: {
      type: ['string', 'null'],
      enum: ['fix', 'needs-human-review', 'auto-close-noise', 'duplicate', 'decomposed', 'designed', null],
    },
    blocked_reason: { type: ['string', 'null'] },
    blocked_stage: { type: ['string', 'null'] },
    last_push: { type: ['string', 'null'] },
    summary: { type: ['string', 'null'] },
  },
}

// ---------------------------------------------------------------------------
// STAGE 1 — SELECT.
// The orchestrator pre-computes the selection and injects it via `args.issues`;
// this stage normalizes it into the unit-of-work list the pipeline fans out over.
// (A future phase MAY move a read-only "confirm still workable" pre-flight here as
// its own agent() call — the issue-work step-0 recheck — but selection policy
// itself stays in the orchestrator, not this script.)
// ---------------------------------------------------------------------------
const workUnits = selectedIssues.map((it) => ({
  number: it.number,
  mode: it.mode ?? 'issue-work',
  model: it.model ?? models[it.mode ?? 'issue-work'],
  trust: it.trust ?? 'external', // conservative default; orchestrator normally sets this
  branch: it.branch ?? `do-work/issue-${it.number}`,
}))

// ---------------------------------------------------------------------------
// STAGE 2 — DISPATCH one worker per unit, bounded by the concurrency pool.
//
// Each worker runs the SAME per-mode lifecycle it runs today (implement → verify →
// open-PR / arm-merge), driven by the per-mode spec in agents/issue-worker/<mode>.md
// via the worker-preamble skill — the pipeline(implement, verify, open-PR/arm-merge)
// the AC names is that per-worker lifecycle, authored inside the per-mode spec, not a
// re-implementation of it here. The workflow's contribution is the schema-validated
// return + the bounded fan-out.
//
// `parallel(tasks, { concurrency })` is the rolling worker pool — the substrate form
// of the orchestrator's `in_flight` set bounded by `--concurrency N`. Worktree
// isolation still applies per worker (the orchestrator provisions each unit's
// worktree; a worker never touches another's).
//
// SCAFFOLD: `parallel()`'s exact option surface is not fully public yet. If the
// runtime exposes bounded concurrency directly, this is the call; otherwise the
// migration phase chunks `workUnits` into groups of `concurrency` and awaits each
// group via `pipeline()`. Both encode the same rolling-pool semantics — the shape
// is what's committed here, the precise primitive is pinned at wire-up time.
// ---------------------------------------------------------------------------
const dispatchWorker = (unit) =>
  agent(buildWorkerPrompt(unit, repo), {
    label: `${unit.mode} #${unit.number}`,
    model: unit.model, // per-mode tier from resolve-dispatch-model.sh, injected via args
    schema: workerReturnSchema, // structured return validated at the stage boundary
  })

// eslint-disable-next-line no-undef -- `parallel` is a workflow-runtime global (see header)
const results =
  typeof parallel === 'function'
    ? await parallel(workUnits.map((u) => () => dispatchWorker(u)), { concurrency })
    : await pipeline(workUnits, dispatchWorker) // fallback: sequential fan-out

// ---------------------------------------------------------------------------
// STAGE 3 — COLLECT.
// Hand the schema-validated structured results back to the orchestrator's reconcile,
// which owns the state transitions (session_prs, failed_prs, deferred_issues, the
// blocked-reason → label classification per #521, cost bump-tokens). The workflow
// does NOT reconcile — it produces the validated results the reconcile consumes.
// ---------------------------------------------------------------------------
return results.filter(Boolean)

// ===========================================================================
// Helper — build the per-worker dispatch prompt.
//
// This is the SAME prompt the Agent-tool path builds today: `mode: <mode>`, the
// issue number, repo, branch, originating_author_trust, and (for issue-work under
// version coordination) next_available_version. The one delta for workflow-dispatched
// workers is the return contract: instead of the free-text terminal string, the
// worker returns a structured object matching schemas/worker-return.schema.json
// (worker-preamble § "Return-contract discipline" gains a workflow-substrate branch
// in the wire-up phase; this scaffold documents the intended shape).
// ===========================================================================
function buildWorkerPrompt(unit, repoSlug) {
  return [
    `mode: ${unit.mode}`,
    `Work issue #${unit.number} in ${repoSlug} to completion. You are already self-assigned.`,
    `The originating issue's author trust is **${unit.trust}** — load-bearing for auto-merge gating.`,
    `Branch: ${unit.branch}. Open a PR that closes the issue.`,
    ``,
    `Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/${unit.mode}.md\`.`,
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json`,
    `(this is the workflow-substrate return contract — NOT the free-text return string).`,
  ].join('\n')
}
