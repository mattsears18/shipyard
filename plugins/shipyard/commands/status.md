---
description: Live dashboard of in-flight /shipyard:do-work workers. Reads the per-session state file(s) and prints a snapshot of what each worker is doing right now (mode, target, elapsed, tokens, stale detection).
argument-hint: [--json] [--stale] [--stale-seconds N]
---

# /shipyard:status

Live dashboard of every active `/shipyard:do-work` worker. Answers *"what is shipyard actually doing right now?"* without having to wait for workers to return.

Thin wrapper around [`plugins/shipyard/scripts/status.sh`](../scripts/status.sh), which reads the per-session state file(s) at `~/.shipyard/sessions/<session-id>.json` (the same file [`/shipyard:do-work`](./do-work.md) writes through every turn via [`session-state.sh`](../scripts/session-state.sh)).

## When to use

- A worker has been running for 5+ minutes and you want to know whether it's stuck or doing real work.
- The orchestrator is mid-drain and you want to see what the remaining workers are mid-step on.
- A worktree may have been reaped — workers go silent, no signal until next orchestrator refresh.
- You want a quick "is shipyard busy or idle?" answer without grepping the transcript.

## Output

Default (text) format — one row per in-flight worker, grouped by session:

```
$ /shipyard:status
SHIPYARD STATUS — 3 active worker(s) across 1 session(s)

  WORKER                     TARGET                           ELAPSED    TOKENS       STALE-AGE
  ────────────────────────── ──────────────────────────────── ────────── ──────────── ──────────
  [session: 7c1a-… · repo: mattsears18/shipyard]
  issue                      #142                             3m 12s     8.4k         3m 12s
  issue                      #143                             45s        4.1k         45s
  fix-checks                 PR #156                          1m 02s     2.0k         1m 02s

TOTAL: 14.5k tokens in flight, oldest worker 3m 12s
```

Workers that haven't updated within 5 minutes get a `⚠ STALE` marker — the orchestrator's reconciler uses the same signal to detect likely-reaped worktrees.

## Flags

- **`--json`** — emit a machine-readable JSON projection (one object per active session). Useful for piping into `jq` or for shell-script integrations. The shape is `[{session_id, repo, started_at, updated_at, concurrency, in_flight: [{slot, kind, target, started_at, progress_current, progress_total, progress_updated_at, tokens}]}]`.

- **`--stale`** — filter to ONLY workers whose last progress update (or dispatch time, if no progress write has happened yet) is older than the stale threshold. Useful for spotting workers that may be wedged.

- **`--stale-seconds N`** — override the stale threshold (default `300` = 5 minutes). Also honored via the `SHIPYARD_STATUS_STALE_S` environment variable.

```bash
/shipyard:status                              # default text dashboard
/shipyard:status --json | jq '.[].in_flight'  # machine-readable
/shipyard:status --stale                      # only the stuck ones
/shipyard:status --stale-seconds 60           # 1-minute threshold
```

## Progress counters (batch workers)

Batch-style workers (e.g. a refiner processing N issues per dispatch) can publish progress via `session-state.sh set-progress --slot <id> --current K --total N`. When set, the counter renders next to the worker kind:

```
  refining (4/7)             batch                            14s        3.2k         2s
```

The `progress_current` / `progress_total` fields live on the per-slot record inside the session state file's `.in_flight[<slot>]` block. Individual issue-work / fix-checks-only dispatches typically don't set progress — the kind alone is informative enough — but the helper is available to any worker that wants to surface batch progress.

## Substrate-agnostic — works under both `agent` and `workflow` dispatch (#790)

As of the [#790](https://github.com/mattsears18/shipyard/issues/790) substrate cutover, `/shipyard:do-work` dispatches its workers through the [Dynamic Workflows substrate](../workflows/README.md) (the `Workflow` tool) **by default** (`dispatch.substrate: "workflow"`), rather than the legacy `Agent` tool. `/shipyard:status` keeps reporting accurate live rows across that change **without any code path of its own that branches on the substrate** — and here is why that holds:

- The dashboard reads only the per-session state file at `~/.shipyard/sessions/<id>.json`. It never talks to the `Agent` tool or the `Workflow` tool directly.
- The orchestrator writes each in-flight worker's `.in_flight[<slot>]` record (`kind` / `target` / `started_at` / progress trio) **identically regardless of substrate** — see [dispatch-rules.md's workflow-substrate section, step 5](./do-work/dispatch-rules.md#workflow-substrate-dispatch-for-every-worker-mode-opt-in-via-dispatchsubstrate-workflow--789-phase-3-of-782): *"Write the `.in_flight` slot exactly as the `Agent`-tool path does."* A `Workflow`-dispatched worker's slot has the same shape as an `Agent`-dispatched one, so text, `--json`, and `--stale` all render it the same way.
- Token counts (the `TOKENS` column) come from `.tokens.per_issue` / `.tokens.per_pr`, bumped by the orchestrator's step-A reconcile **after** the structured `Workflow` return has been translated back into the free-text vocabulary — so cost attribution is unaffected by substrate too (see [`/shipyard:cost`](./cost.md)).

The upshot: the cutover is invisible to this dashboard by construction. A regression that reverts `dispatch.substrate` to `"agent"` (the instant-revert override) is equally invisible — `/shipyard:status` renders both the same because both write the same file. The `dispatch-substrate-cutover-790.test.sh` suite asserts a synthetic `Workflow`-dispatched session file renders correctly through all three output modes.

## Relationship to Agent View ([#785](https://github.com/mattsears18/shipyard/issues/785))

Claude Code's native [Agent View](https://code.claude.com/docs/en/agent-view) (`claude agents`) is a harness-level dashboard for **every** detached background session on the machine — whatever spawned them, `/shipyard:do-work` or otherwise. It's not a competitor to `/shipyard:status`; the two sit at different layers and answer different questions, so the decision here is **complement, not defer** — neither dashboard re-implements the other:

| | Agent View | `/shipyard:status` |
|---|---|---|
| Scope | Every background session/subagent on this machine | Only this repo's `/shipyard:do-work` session(s) |
| Granularity | One row per session/subagent (process-level) | One row per in-flight worker *and* its shipyard-specific semantics |
| Fields | Status (needs-input / working / completed), one-line Haiku-generated summary, PR label when a session opens one | `mode` (issue / fix-checks / fix-rebase / …), `target` (issue or PR number), elapsed, token usage, staleness | 
| Best for | Attaching to a specific worker's live transcript, peeking at its last output, or stepping in mid-task | Answering "what is shipyard's dispatch loop doing *right now*, and is any of it stuck?" across the whole session at a glance |
| Data source | The harness's own supervisor process | `~/.shipyard/sessions/<id>.json`, written by [`session-state.sh`](../scripts/session-state.sh) |

Agent View has no visibility into shipyard's own concepts — which issue a worker was dispatched against, its `blocked-by` chain, per-worker token budget, or the mode taxonomy (`issue-work` vs `fix-checks-only` vs `fix-main-ci`, etc.) — because those live in shipyard's session-state file, not in anything the harness tracks. Conversely, `/shipyard:status` has no transcript access and can't attach to or steer a worker; that's what Agent View is for. **When a worker looks stale in `/shipyard:status`, attach to it via Agent View to see its live transcript and confirm whether it's actually stuck** — the two tools are meant to be used together, not as alternatives.

This holds regardless of `dispatch.substrate`: under `agent`, each worker is literally the kind of `isolation: "worktree"` subagent Agent View surfaces as its own row; under the default `workflow` substrate, the `Workflow` tool's `agent()` calls are a distinct harness mechanism that Agent View does not enumerate the same way — but `/shipyard:status` renders identically either way (see the "Substrate-agnostic" section above), so this dashboard's own reliability doesn't depend on which substrate is active.

## Privacy

Same as the cost-tracking ledger: the session state files at `~/.shipyard/sessions/` are local-only — shipyard never uploads them anywhere. They contain session IDs, repo names, issue/PR numbers, and token counts — no secrets, no message bodies, no code diffs. The files are reaped at end-of-session cleanup.

## Implementation (what the assistant does)

The command is a thin wrapper. The assistant's job is to:

1. **Resolve the flags** from the user's args (`--json`, `--stale`, `--stale-seconds N`).
2. **Forward to the helper script**:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/status.sh "$@"
   ```
3. **Print the helper's output verbatim.** The helper handles the empty-sessions case ("no active sessions") and the no-in-flight case ("sessions present but no slots active") without any orchestrator intervention.

## Related

- [`/shipyard:do-work`](./do-work.md) — the orchestrator. Writes the per-session state files that `/shipyard:status` reads.
- [`/shipyard:cost`](./cost.md) — token-cost reports. Reads the same session state files for the current-session view.
- [`plugins/shipyard/scripts/status.sh`](../scripts/status.sh) — the dashboard renderer.
- [`plugins/shipyard/scripts/session-state.sh`](../scripts/session-state.sh) — the per-session state file writer (`init` / `update` / `set-progress` / `bump-tokens`).
- Issue [#167](https://github.com/mattsears18/shipyard/issues/167) — this spec.

## Don't

- **Don't poll `/shipyard:status` in a tight loop.** Each call walks every session file and re-renders. For a continuous view, pair with the standard shell `watch` utility: `watch -n 2 /shipyard:status` (rather than relaunching the command repeatedly inside an assistant turn — that burns context).
- **Don't expect history.** `/shipyard:status` shows the *current* in-flight state. The `--history` flag is deferred to a follow-up (see [issue body in #167](https://github.com/mattsears18/shipyard/issues/167)). For post-session analysis use [`/shipyard:cost report`](./cost.md), which reads the persistent cross-session ledger.
- **Don't edit the session state files directly.** They're managed by `session-state.sh`'s atomic-write contract — hand-edits race against in-progress writes.
- **Don't expect a live count against the harness's `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` / `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` runaway-fanout caps (see [`do-work-RATIONALE.md`'s "Runaway guards"](./do-work-RATIONALE.md#runaway-guards--subagent--web-search-session-caps-764)).** The session state file this dashboard reads has no visibility into the harness's internal subagent/web-search counters, so `/shipyard:status` doesn't render one — a fabricated number would look authoritative without being real. If the harness ever exposes those counters, wiring them into the session state file (the same way per-dispatch token usage already is) and rendering them here is the natural follow-up.
