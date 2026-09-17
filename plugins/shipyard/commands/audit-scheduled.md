---
description: Run only the /shipyard:audit dimensions whose configured cadence is due, per the audits.schedule config block. Composes with /loop for cron-like polling.
argument-hint: [--repo owner/repo] [--dry-run]
---

# /shipyard:audit-scheduled

Run the `/shipyard:audit` dimensions that are due per the repo's `audits.schedule` config, and only those. Closes [#975](https://github.com/mattsears18/shipyard/issues/975).

The problem this solves: `shipyard:testing-auditor` (tests that lie, coverage holes, CI gate completeness) and `shipyard:functional-qa-auditor` (signs in as a real user, exercises features end-to-end) — and every other `/audit` dimension — are invoke-on-demand only. In practice that means they run when a maintainer already suspects a problem, which is exactly the case where they add the least value. An auditor that only runs when you already suspect a problem is a debugging tool, not a guardrail — the whole point of the audit fleet is catching drift the maintainer hasn't noticed yet, and that needs a cadence.

This command does not invent a new execution engine — it reuses three things shipyard already has: [`/shipyard:audit`](./audit.md)'s own dispatch table (this command runs the exact same per-dimension agent dispatch, reconciliation, and report writing), the `audit-key` fingerprint dedup already built into [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) (so a scheduled run that finds nothing new produces zero new issues, for free), and the `/loop` skill for the actual periodic trigger (this command decides *whether* a dimension is due; `/loop` decides *when to check*). The only new surface is the `audits.schedule` config block and the tiny cadence-gating state kept at `~/.shipyard/audit-schedule-state.json` by [`scripts/audit-schedule.sh`](../scripts/audit-schedule.sh).

## When to use

- Wired into `/loop` for periodic drift detection with zero webhook setup: `/loop 1h /shipyard:audit-scheduled` checks hourly and only actually runs an auditor when its configured cadence has elapsed.
- Run by hand any time you want to "catch up" on whatever's overdue without remembering which dimension was last run when.
- `--dry-run` to see what *would* run without running it — useful when tuning `audits.schedule` cadences.

Not the right surface when:

- You want to run a specific dimension right now, regardless of cadence — use `/shipyard:audit <dimension> [<url>]` directly. This command is purely a cadence gate in front of that same dispatch machinery.
- `audits.schedule` is empty or absent — this command has nothing to do and says so; it does not fall back to running everything (that's what `/audit all` is for).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): target GitHub repo. If omitted, auto-detect via `gh repo view --json nameWithOwner -q .nameWithOwner`. If that fails (not in a repo), ask via `AskUserQuestion`.
- **--dry-run** (optional): list the due dimensions and their `seconds_since_last_run` without dispatching any auditor or recording a new last-run timestamp. Use this to sanity-check `audits.schedule` cadences before wiring the command into `/loop`.

## What the assistant should do when this command runs

The mechanics split the same way `/shipyard:eas-watch` does: this spec owns orchestration (resolve config, decide what's due, dispatch, record), [`scripts/audit-schedule.sh`](../scripts/audit-schedule.sh) owns the cadence math and the tiny state file, and [`commands/audit.md`](./audit.md) owns everything about *how* a dimension actually runs (which agents, the run-id marker, reconciliation, the HTML report). Don't reimplement any of audit.md's dispatch logic here — read it and follow it per due dimension.

### 1. Resolve inputs

- `repo`: from `--repo`, else `gh repo view --json nameWithOwner -q .nameWithOwner`. If that fails, ask via `AskUserQuestion` rather than guessing.
- `dry_run`: `true` if `--dry-run` was passed, else `false`.

### 2. Read the effective `audits.schedule` config

```bash
SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/audit-schedule.sh"
SCHEDULE_JSON=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get audits.schedule 2>/dev/null)
```

`shipyard-config.sh get` prints `null` (via jq's default `-r` string coercion this may render as the literal text `null`, or the call may simply fail with exit 3 when the path isn't present) when the repo has no `audits.schedule` block configured. Treat either case as "nothing scheduled": if `$SCHEDULE_JSON` is empty or the literal string `null`, print **"No audits.schedule configured — nothing to do. See `/shipyard:init` or CLAUDE.md's Configuration section to add one."** and stop. Do NOT fall back to running `/audit all` — an absent schedule means the maintainer hasn't opted in yet, not "run everything."

### 3. Compute what's due

```bash
DUE=$(printf '%s' "$SCHEDULE_JSON" | "$SCRIPT" due --repo "<owner/repo>" --schedule-json -)
```

Output is JSONL (one compact JSON object per due entry: `{dimension, cadence, url, last_run_at, seconds_since_last_run}`) or empty if nothing is due. If `$DUE` is empty, print **"Nothing due right now."** and stop — this is the routine, expected outcome on most `/loop`-driven invocations, not an error.

### 4. `--dry-run`: report and stop

If `dry_run` is true, print one line per due entry and stop **without dispatching anything and without calling `record`**:

```
Would run: <dimension> (cadence <cadence>, last run <last_run_at-or-"never">)
```

### 5. Dispatch each due dimension through `/shipyard:audit`'s own machinery

For each due entry (parallel dispatch across entries is fine — each dimension gets its own `AUDIT_RUN_ID` and reconciliation, exactly as `/audit all` already dispatches its agents in parallel):

1. Follow [`commands/audit.md`](./audit.md) **exactly as if the user had typed** `/shipyard:audit <dimension> [<url>]` — generate a fresh `AUDIT_RUN_ID`, look up `<dimension>` in its Dispatching table, dispatch the matching agent(s) with the Agent-prompt template (substituting `<url>` from the schedule entry when present), reconcile filed issues against the run-id marker, and write the consolidated report. Do not skip or shortcut any of audit.md's steps — the dedup guarantee this command relies on (the `audit-key` check inside `filing-github-issues`) only holds because the auditor runs its normal verify-before-file process.
2. For a `dimension: "all"` schedule entry, this means the full `all` fan-out from audit.md's table — every agent, in parallel — exactly as a bare `/audit all` would.
3. If the entry's dispatch needs a URL and the schedule entry doesn't carry one (`url` is `null`), follow audit.md's own missing-URL handling for that dimension rather than skipping it silently.

### 6. Record completion — only after the dimension's dispatch actually returns

**Do NOT call `record` before the dispatch has returned.** Recording early and then having the dispatch fail partway (agent spawn error, tool denial) would silently mark the dimension "done" for a full cadence cycle when nothing actually ran — the eas-watch.md precedent ("don't advance the cursor before surfacing") applies here identically.

```bash
"$SCRIPT" record --repo "<owner/repo>" --dimension "<dimension>"
```

Do this once per due dimension, right after that dimension's own audit.md flow (agent dispatch + reconciliation) completes — not batched at the very end of the whole command, so a later dimension's failure doesn't retroactively un-record an earlier dimension's success.

### 7. Summary

Print a final summary listing each dimension that ran, its finding count (from that dimension's audit.md reconciliation), and the report path(s) audit.md wrote. If any due dimension's dispatch failed to return, name it explicitly and note that its `record` call was skipped (so it will be re-attempted on the next `/shipyard:audit-scheduled` invocation) rather than silently treating the run as complete.

## Composition recipes

### Periodic polling with `/loop`

```bash
/loop 1h /shipyard:audit-scheduled
```

Checks hourly; only actually dispatches an auditor when its configured cadence has elapsed. A `cadence` of `7d` under an hourly `/loop` still only runs weekly — the loop interval is just how often the cadence gate gets *checked*, not how often auditors run.

### Worked example — weekly testing + functional-qa, daily security

`shipyard.config.json`:

```json
{
  "version": 1,
  "audits": {
    "schedule": [
      { "dimension": "testing", "cadence": "7d" },
      { "dimension": "functional-qa", "cadence": "7d", "url": "https://app.example.com" },
      { "dimension": "security", "cadence": "24h" }
    ]
  }
}
```

Then:

```bash
/loop 1h /shipyard:audit-scheduled
```

Result: `security` gets checked daily, `testing` and `functional-qa` weekly — each only firing an actual auditor dispatch (and only actually costing tokens / CI time) on the day its cadence rolls over, and only filing issues for genuinely new findings thanks to the existing `audit-key` dedup.

### Preview before wiring into `/loop`

```bash
/shipyard:audit-scheduled --dry-run
```

Confirms which dimensions would fire and how overdue each is, without spending anything, before committing to a `/loop` cadence.

## Don't

- **Don't fall back to `/audit all` when `audits.schedule` is empty.** An absent schedule means the maintainer hasn't opted into recurring audits yet — running everything anyway would be a surprising, uncapped-cost default. Say so and stop (step 2).
- **Don't record a dimension as run before its dispatch actually returns.** See step 6 — recording early on a failed dispatch silently loses a full cadence cycle's worth of coverage.
- **Don't reimplement `/shipyard:audit`'s dispatch table, run-id marker, reconciliation, or report-writing logic here.** This command is a cadence gate in front of that machinery, not a second copy of it — every dedup / reconciliation guarantee `/audit` already provides only holds if the same flow actually runs.
- **Don't invent a new state or dedup mechanism.** Cadence state lives at `~/.shipyard/audit-schedule-state.json` (the existing `~/.shipyard/` convention — see `eas-state.json`, `cost-history.jsonl`), and finding-level dedup is the existing `audit-key` fingerprint. Nothing about "has this dimension run recently" or "have I already filed this finding" needs new machinery.
- **Don't write to the state file from inside this spec.** The atomic-write contract lives in `audit-schedule.sh`'s `record` subcommand. The spec calls it; the spec doesn't reimplement it.

## Related

- [`/shipyard:audit`](./audit.md) — the dispatch table, agent-prompt template, and reconciliation logic this command reuses per due dimension.
- [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) — the `audit-key` fingerprint dedup that makes a scheduled run idempotent (no issue churn on a repeat finding).
- [`/shipyard:eas-watch`](./eas-watch.md) — the precedent for this command's shape: a small `~/.shipyard/` state file, a poll-and-diff/due model, and `/loop` composition for cron-like behavior with no external scheduler.
- [`/loop`](../../../README.md) — periodic-invocation harness; the canonical companion for this command.
