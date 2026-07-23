# /shipyard:do-work — Session state file

The session-state JSON schema, the `session-state.sh` helper subcommand reference, the write-through site table, and the cost-tracking write-through rules — the parts of the durable per-session record that are each **consumed once** (the schema, read at `init`) or by a **specific site** named in its own row (the write-through table is a 15-row lookup pointing back into the other phase files that actually perform each write). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and a short pointer to this file; this file owns the on-disk mirror's full shape and mechanics. **Reference block — load it when you need the exact schema, a `session-state.sh` subcommand's flags, or which step writes which field — not on every turn** (mirrors the [dispatch-rules.md split #616](./dispatch-rules.md); split out under [#808](https://github.com/mattsears18/shipyard/issues/808)).

## Session state file

The orchestrator mirrors every [orchestrator-state](../do-work.md#orchestrator-state) structure into a small JSON file at `$SHIPYARD_HOME/sessions/<session-id>.json` (default: `~/.shipyard/sessions/<session-id>.json`). The file is the durable record of the session — written through whenever state changes, read back by external tools (and a future `/do-work --resume <session-id>` flag), and removed at end-of-session by the cleanup step. The LLM's per-turn working memory still drives dispatch decisions; the file is the mirror, not the algorithm. See [RATIONALE → Session state file](../do-work-RATIONALE.md#session-state-file--why-a-file-at-all) for the design discussion.

### Schema

```json
{
  "session_id": "<uuid or stable id>",
  "repo": "owner/repo",
  "concurrency": 2,
  "soft_collision_concurrency": 3,
  "started_at": "2026-05-20T17:31:14Z",
  "updated_at": "2026-05-20T18:04:22Z",

  "in_flight": {
    "slot1": { "kind": "issue", "target": 90, "claimed_paths": { "hard": [], "soft": [] }, "agent_id": "...", "started_at": "2026-05-20T17:35:01Z", "progress_current": null, "progress_total": null, "progress_updated_at": null }
  },
  "ready_issues": [],
  "scope_bg_count": 0,
  "failed_prs": [],
  "raw_backlog": [],
  "divert_queue": [],
  "operator_queue": [],
  "session_prs": [],
  "deferred_issues": [
    { "issue": 1075, "reason": "Gated on #1077 — low-urgency soft concern", "defer_reason_class": "confirmed-blocker-still-open", "evidence_pointer": "Blocked by #1077", "provenance": "orchestrator-judgment", "deferred_at": "2026-05-23T14:12:00Z" }
  ],
  "soft_caps": { "CLAUDE.md": 2 },
  "main_ci": {
    "status": "green",
    "earliest_red_run_id": null,
    "earliest_red_run_url": null,
    "earliest_red_sha": null,
    "checked_at": "2026-05-20T18:04:22Z"
  },
  "drain": { "active": false, "started_at": null, "polls": 0 },

  "tokens": {
    "totals": {
      "input": 0, "output": 0, "cache_read": 0, "cache_creation": 0,
      "estimated_usd": 0
    },
    "per_issue": {
      "153": { "input": 18203, "output": 4102, "cache_read": 8210, "cache_creation": 0, "estimated_usd": 0.59 }
    },
    "per_pr": {
      "200": { "input": 18203, "output": 4102, "cache_read": 8210, "cache_creation": 0, "estimated_usd": 0.59, "issue": 153 }
    },
    "per_invocation": [],
    "degraded_attribution_count": 0
  }
}
```

Field names match the [orchestrator-state](../do-work.md#orchestrator-state) structure names 1:1 so a reader of either surface (file or prose) can cross-reference without translation. `started_at` and `updated_at` are always-present ISO-8601 UTC timestamps; `updated_at` advances on every successful `update` call so external watchers can detect change without diffing the body.

The `tokens` block is the **per-session** cost ledger — written through `session-state.sh bump-tokens` after each Agent dispatch returns. `.tokens.totals` is cumulative across the session (including orchestrator overhead); `.tokens.per_issue[<N>]` and `.tokens.per_pr[<M>]` are attribution buckets the cost-comment hook in [step A reconcile](./steady-state.md#a-reconcile-the-return) reads when posting `<!-- do-work-cost-tracking -->`-marked comments on the resulting issue/PR. The persistent cross-session ledger at `~/.shipyard/cost-history.jsonl` is [#163](https://github.com/mattsears18/shipyard/issues/163)'s scope — out of scope here. `per_invocation` is a ring buffer capped at the most-recent 200 entries; each entry carries `degraded: <bool>`. `degraded_attribution_count` counts the degraded bumps (see [step A.0 degraded path](./steady-state.md#degraded-path--total-only-fallback-when-the-harness-usage-block-lacks-the-breakdown) — harness-gap fallback from [#279](https://github.com/mattsears18/shipyard/issues/279)) and, together with `per_invocation | length`, drives the [end-of-session banner](./cleanup-summary.md#end-of-session-summary) — which branches on the ratio so "100% of dispatches degraded" reads as a structural harness shape rather than per-dispatch degradation ([#295](https://github.com/mattsears18/shipyard/issues/295)).

### Helper script — `plugins/shipyard/scripts/session-state.sh`

Every write goes through the helper, which writes to `<target>.tmp.<pid>` and atomically renames into place. **Never edit the JSON directly with `Edit` / `Write` / `jq` / a shell heredoc** — none of those preserve the atomic-rename contract. Subcommands:

```bash
# Set up the session file at startup (step 0.5). init stamps a .pid (default
# $PPID) so the orphan-sweep (setup.md step 1.6) can skip via `is-active`
# while this process is alive — defends against #253's concurrent-sweep race.
plugins/shipyard/scripts/session-state.sh init \
  --session-id "<session-id>" \
  --repo "<owner/repo>" \
  --concurrency <N> \
  --soft-collision-concurrency <N>

# Read the whole file or one jq path.
plugins/shipyard/scripts/session-state.sh read --session-id "<session-id>" [--path ".session_prs"]

# Merge jq assignments atomically. --allow-degraded-init: RECOMMENDED (#281 — survives mid-session file disappear).
plugins/shipyard/scripts/session-state.sh update --session-id "<session-id>" \
  --set '.session_prs += [96]' --set '.main_ci.status = "green"' --allow-degraded-init --degraded-init-repo "<owner/repo>"

# Liveness check for the orphan-sweep (setup.md step 1.6). Exit 0 when file
# exists AND .pid is alive (kill -0); exit 1 otherwise.
plugins/shipyard/scripts/session-state.sh is-active --session-id "<session-id>"

# Bump token-usage counts after an Agent dispatch returns. --issue / --pr
# optional. --allow-degraded-init + --degraded-init-repo REQUIRED (see
# steady-state.md A.0). Strict path — harness <usage> exposes the breakdown:
plugins/shipyard/scripts/session-state.sh bump-tokens \
  --session-id "<session-id>" --issue <N> --pr <M> \
  --input <N> --output <N> --cache-read <N> --cache-creation <N> \
  --mode <mode> --model <model-id> --allow-degraded-init --degraded-init-repo "<owner/repo>"
# Degraded path (#279 — <usage> total-only): REPLACE the four breakdown flags
# with `--input <total_tokens> --degraded-total-only` (mutually exclusive; #320).

# Read aggregated token data. --format json (default) or comment (Markdown
# body with the <!-- do-work-cost-tracking --> sentinel for idempotent posting).
plugins/shipyard/scripts/session-state.sh read-tokens \
  --session-id "<session-id>" --pr <M> --format comment

# Set progress counters on an in-flight slot (feeds /shipyard:status; #167).
plugins/shipyard/scripts/session-state.sh set-progress \
  --session-id "<session-id>" --slot "<slot-id>" --current 4 --total 7

# Remove the file at end-of-session (cleanup step).
plugins/shipyard/scripts/session-state.sh cleanup --session-id "<session-id>"
```

Exit codes:

- `0` — success.
- `2` — `init` refused to clobber an existing file (use `--force` if the clobber is intentional). Protects against accidentally re-initialising a session that's still active.
- `3` — `read` or `update` ran on a session file that does not exist. Distinct from `0` so the orchestrator can branch on "first-write to a session that wasn't initialised" vs "successful read."
- `64` — usage error (bad subcommand, missing required arg). Mirrors `sysexits.h`'s `EX_USAGE`.
- `65+` — internal helper failure (jq missing, write permission denied). Never papered over — the orchestrator should surface these so the user sees why state stopped updating.

### When the orchestrator writes through

Every state-mutation site writes through. Batch writes at end-of-turn — one `update` call with multiple `--set` flags, not a flurry per field. See [RATIONALE → Write-through cadence](../do-work-RATIONALE.md#write-through-cadence--why-batched-per-turn).

| Site | What changes | When |
|---|---|---|
| [Step 0.5 → step 1.5](./setup/01-repo-recovery.md#15-initialise-the-session-state-file) | Session file created with `init` | once, at startup |
| [Step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) | `raw_backlog`, `trusted_authors` (if dynamically loaded) | once, post-fetch |
| [Step 4.5](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) | `main_ci`, `divert_queue` | at setup + step D refresh |
| [Step 5](./setup/04-backlog-divert.md#5-snapshot-failing-prs) | `failed_prs`; [step 5.7](./setup/04-backlog-divert.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off) seeds `session_prs` with inherited DIRTY-but-green `@me` PRs (deferred to step D at C=1) | once, post-snapshot |
| [Step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight) | `scope_bg_count` (incremented when batch fires; decremented as each background agent returns), `ready_issues` (appended as results arrive), `deferred_issues` (with `provenance: "scope-agent"` and `deferred_at` on new entries) | rolling, as background scope agents return |
| Step 7 (initial pool fill) | `in_flight`, `soft_caps` | per dispatch |
| [Step A reconcile](./steady-state.md#a-reconcile-the-return) | `in_flight` (release), `session_prs`, `failed_prs`, `deferred_issues` (via blocked), `tokens` (via `bump-tokens`) | every completion |
| [Step B release](./steady-state.md#b-release-the-slot) | `in_flight` (slot removal), `soft_caps` (decrement) | every completion |
| [Step C dispatch](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) | `in_flight` (new slot), `ready_issues` (consumed), `failed_prs` (consumed), `soft_caps` (increment), `raw_backlog` (post-refill) | every dispatch |
| [Step D refresh](./steady-state.md#d-periodic-refresh) | `main_ci`, `divert_queue`, `failed_prs`, `session_prs` (inherited/mid-session DIRTY-but-green `@me` PRs adopted for drain — #373), `scope_bg_count` (incremented on refill burst fire; decremented as each background agent returns), `ready_issues` (appended as results arrive), `raw_backlog`, `deferred_issues` | every full-pool refresh |
| Drain phase | `drain.active`, `drain.polls`, `session_prs`, `failed_prs`, `in_flight` | every poll |
| [Cleanup step 7](./cleanup-summary.md#end-of-session-cleanup) | Session record flushed to `~/.shipyard/cost-history.jsonl` via `cost-history.sh flush` | last, immediately before the session file is removed |
| [Cleanup step 8](./cleanup-summary.md#end-of-session-cleanup) | Session file removed via `session-state.sh cleanup` | last, after the user-facing summary prints |

### Failure mode — write-through breakage

If `session-state.sh update` fails (exit code != 0), log `[session-state] update failed: <exit code> — session file out of sync with working memory; continuing` and continue the turn. Working memory is authoritative; the next turn's update cycle re-attempts the write. Do not stall dispatch on a file-write failure. Mid-session exit-3 (file disappeared) is handled inline by `--allow-degraded-init` (issue #281) — the canonical `update` template above passes it by default. See [RATIONALE → Failure mode](../do-work-RATIONALE.md#failure-mode--write-through-breakage) for the full failure-mode discussion.

### Cost-tracking write-through

After every Agent dispatch returns, the orchestrator extracts the dispatch's `usage` payload (input/output/cache_read/cache_creation token counts; model id) and attributes it via `bump-tokens` before reconciling the return string. **This is not optional, and the call site is [step A.0](./steady-state.md#a0-attribute-the-dispatchs-token-usage-mandatory--before-any-return-string-parsing) — not this section.** The numbered first-step framing is load-bearing: a previous version of these docs described the hook only in prose here and in the write-through table below, and the orchestrator silently skipped attribution across an entire 16-PR session ([#197](https://github.com/mattsears18/shipyard/issues/197)). The mechanical contract lives at the dispatch site (A.0); this section documents the *rules* the helper call follows.

The attribution rules:

- **Worker dispatches with an associated issue or PR** — pass `--issue <N>` (issue-work, fix-checks-only) and/or `--pr <M>` (fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch) along with `--mode <mode>` and `--model <id>`. Both the per-issue/per-pr bucket and `.tokens.totals` get bumped; a `per_invocation` ring-buffer entry is recorded for trace.
- **Orchestrator-side overhead** — calls without `--issue` or `--pr` only bump `.tokens.totals`. Use this for the orchestrator's own per-turn token cost (the scope-pre-flight pass at step 6, the periodic refresh at step D, etc.) — those don't attribute to a specific PR.

The hook is observational and write-only — `bump-tokens` never affects dispatch decisions. If the helper call errors, log `[bump-tokens] attribution failed: <exit code>; continuing` and proceed; the dollar-cost data point is lost but the session marches on.

The persistent cross-session ledger at `~/.shipyard/cost-history.jsonl` is [#163](https://github.com/mattsears18/shipyard/issues/163)'s scope — out of scope here. This section covers the per-session in-memory accounting only; the artifact comments posted on the issue/PR are the durable export.

**This accounting is post-hoc, not pre-emptive — and stays that way.** The Claude API's beta "Task Budgets" feature (`output_config.task_budget`) gives a dispatch a token ceiling it's aware of *while running*; shipyard has no equivalent because the feature is not exposed on the `Agent`-tool dispatch surface this section's write-through attributes *after the fact* — confirmed unsupported on Claude Code, dual-sourced against both the platform docs and the `Agent` tool's own parameter surface. See [RATIONALE → Task Budgets](../do-work-RATIONALE.md#task-budgets--not-exposed-on-the-agent-dispatch-surface-spiked-and-closed-negative-765) for the full investigation and why no `budgets.<mode>` config surface follows from it.
