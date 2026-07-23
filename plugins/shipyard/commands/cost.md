# `/shipyard:cost` — token-spend reports + current-session cost

Thin wrapper around [`plugins/shipyard/scripts/cost-history.sh`](../scripts/cost-history.sh) (persistent cross-session ledger, [#163](https://github.com/mattsears18/shipyard/issues/163)) and [`plugins/shipyard/scripts/session-state.sh`](../scripts/session-state.sh) (per-session ledger, [#153](https://github.com/mattsears18/shipyard/issues/153)).

## Storage layout

```
~/.shipyard/
  cost-history.jsonl          # append-only; one line per /shipyard:do-work session (cross-session)
  cost-history-issues.jsonl   # append-only; one line per (repo, issue), latest wins (cross-session)
  sessions/<session-id>.json  # per-session state (per-session, transient; reaped at end-of-session)
```

Cross-session files are user-scoped (one ledger across every repo shipyard runs against). They survive `git clean`, worktree teardown, and `/shipyard:do-work` re-runs. The per-session files are transient — written during a `/do-work` session and reaped by its end-of-session cleanup.

## Subcommands

```
/shipyard:cost                               # this session's totals (per-session ledger)
/shipyard:cost report                        # default: last 30 days, markdown
/shipyard:cost report --last 7d              # last 7 days
/shipyard:cost report --last 90d             # last 90 days
/shipyard:cost report --last all             # all time (no cutoff)
/shipyard:cost report --repo <owner/name>    # scoped to one repo
/shipyard:cost report --by-issue             # add the per-issue top-N section
/shipyard:cost report --by-mode              # add the by-worker-mode breakdown
/shipyard:cost report --by-model             # add the by-Anthropic-model breakdown
/shipyard:cost report --top 10               # 10 most expensive issues in range
/shipyard:cost report --trend                # weekly cost trend
/shipyard:cost report --show-setup           # add per-phase setup timing breakdown (issue #238)
/shipyard:cost report --format markdown      # default
/shipyard:cost report --format csv           # for spreadsheets (sessions only)
/shipyard:cost report --format json          # for further processing (full rollup)

/shipyard:cost reset                         # destructive — moves ledger files to .bak.<ts>
/shipyard:cost reset --yes                   # skip confirmation prompt

/shipyard:cost export --to <path>.tar.gz     # bundle ledger files for backup
```

## When to use which

- **`/shipyard:cost` (no args)** — the current session. Reads the active session's `sessions/<id>.json` and prints session-wide totals using `session-state.sh read-tokens`. If you're not inside a `/shipyard:do-work` run, this falls through to "no active session" and you should use `/shipyard:cost report` instead.
- **`/shipyard:cost report`** — the cross-session view. Reads the persistent ledger. Works regardless of whether a session is currently running.

## Default report shape

```
$ /shipyard:cost report
Shipyard cost — last 30d (2026-04-21 to 2026-05-21)
════════════════════════════════════════════════════════

TOTALS
  Sessions:        47
  Issues worked:   132
  PRs created:     118
  Tokens:          14200000 input, 1800000 output (5200000 cache)
  Spend:           $342.18 (avg $7.28/session)

Want more detail? Try '/shipyard:cost report --by-issue --top 20'.
```

## Substrate-agnostic — no cost gap from the dispatch migration (#790 / #791)

The [#790](https://github.com/mattsears18/shipyard/issues/790) cutover made the [Dynamic Workflows substrate](../workflows/README.md) the default dispatch mechanism for every worker mode, and [#791](https://github.com/mattsears18/shipyard/issues/791) made it the only one (retiring the legacy `Agent`-tool path and the `dispatch.substrate` knob). `/shipyard:cost` was **unaffected by both** — there is no silent cost-tracking gap — because token attribution never depended on how a worker was dispatched:

- Per-session and per-issue/per-PR token totals live in `.tokens.*` on the session-state file, written by the orchestrator's step-A reconcile via `session-state.sh bump-tokens`.
- Under the `Workflow`-substrate alternate shape, the structured worker return is translated back into the free-text vocabulary **before** it reaches step-A reconcile ([dispatch-rules.md's translation table](./do-work/dispatch-rules.md#workflow-substrate-dispatch--an-alternate-dispatch-shape-825)); under the default `Agent`-tool shape the worker already returns the free-text terminal string directly, with nothing to translate. Either way the reconcile — and the `bump-tokens` call inside it — reads the same free-text vocabulary, unchanged.
- The end-of-session cleanup flushes the same rolled-up record into the persistent ledger (`cost-history.jsonl`) either way.

The one caveat is orthogonal to dispatch: a model id missing from the pricing table is still flagged as a LOWER BOUND (next section). Note that per-mode model *tiering* — which does move the numbers — is resolved by [`resolve-dispatch-model.sh`](../scripts/resolve-dispatch-model.sh) from `models.<mode>` and is likewise unchanged by the migration.

## Unpriced models — when the totals are a LOWER BOUND

The USD figures come from a hand-maintained pricing table (`PRICING_JQ` in `scripts/session-state.sh`), which goes stale every time Anthropic ships a model. A model the table has never heard of is reported, **not** silently priced at zero ([#728](https://github.com/mattsears18/shipyard/issues/728)) — `$0.00` is a legitimate value and must never double as the "I don't know what to charge" sentinel.

When any session in the window ran on an unpriced model, the `Spend:` line is tagged `[LOWER BOUND]` and the report prints an advisory naming the offending model ids:

```
TOTALS
  ...
  Spend:           $12.40 (avg $6.20/session)  [LOWER BOUND]

⚠  UNPRICED MODELS — the spend above is a LOWER BOUND
  2 session(s) ran on 1 model(s) missing from the pricing table; their token counts are
  recorded but their USD cost is booked as $0.00:
    - claude-opus-4-9
  Fix: add them to PRICING_JQ in scripts/session-state.sh (issue #728).
```

**`--show-setup`** adds a `SETUP PHASE TIMING` section that aggregates per-phase wall-clock data across sessions. Only sessions recorded after the #238 instrumentation landed contribute — older sessions don't have a `setup` block. Once ≥ 3 instrumented sessions exist, the per-phase means become actionable for prioritizing the perf work in #235 (#231, #232, #233).

The deeper flags compose:

```
$ /shipyard:cost report --last 7d --by-model --by-mode --by-issue --top 5 --trend --show-setup
... TOTALS block (last 7d) ...

BY MODEL
  claude-sonnet-5  $18.40
  claude-opus-4-8  $23.70
  claude-haiku-4-5  $3.50

BY MODE
  issue-work  $38.20
  fix-checks-only  $4.10
  orchestrator-overhead  $3.30

TOP 5 MOST EXPENSIVE ISSUES
  #128  mattsears18/shipyard  $14.20  (PR #189)
  #142  mattsears18/shipyard  $9.80   (PR #195)
  ...

TREND (weekly)
  2026-05-13  $76.26  (10 sessions)
  2026-05-20  $42.10  (3 sessions)

SETUP PHASE TIMING (sessions with instrumentation)
  Sessions with timing: 13
  Wall clock — mean: 32.4s  median: 28.1s

  Per-phase means (slowest first):
    step_6_scope_preflight: 24.1s  (n=13)
    step_3_5_refine_issues: 3.8s   (n=13)
    step_4_backlog_fetch_and_rank: 2.1s  (n=13)
    step_0_7_parallel_batch: 1.9s  (n=13)
    step_1_7_trusted_authors: 0.9s  (n=13)
    step_0_5_worktree: 0.4s  (n=13)
```

## `--format csv` and `--format json`

- **`csv`** emits session rows only (`session_id,repo,started_at,ended_at,duration_seconds,total_tokens,estimated_usd`). Drop into a spreadsheet for ad-hoc pivots.
- **`json`** emits a complete projection: `{ range, rollup, trend, sessions, issues }`. Pipe into `jq` for further processing. Example:
  ```bash
  /shipyard:cost report --last 90d --format json | jq '.rollup.by_mode'
  ```

## `reset`

Destructive — but safe: the helper *moves* the ledger files to `cost-history.jsonl.bak.<timestamp>` rather than `rm`'ing them. Recovery is a manual `mv` away. Use `--yes` to skip the confirmation prompt in scripted contexts (e.g. the test suite).

```bash
$ /shipyard:cost reset
This will move the following files to .bak.<timestamp>:
  /Users/you/.shipyard/cost-history.jsonl
  /Users/you/.shipyard/cost-history-issues.jsonl
Continue? [y/N] y
reset: moved /Users/you/.shipyard/cost-history.jsonl -> ....bak.20260521T133538Z
reset: moved /Users/you/.shipyard/cost-history-issues.jsonl -> ....bak.20260521T133538Z
```

## `export`

Tarball both ledger files for backup or migration to another machine. Restore by extracting back into the destination's `~/.shipyard/` (the tarball uses relative paths):

```bash
$ /shipyard:cost export --to ~/Dropbox/shipyard-cost-2026-05.tar.gz
export: wrote /Users/you/Dropbox/shipyard-cost-2026-05.tar.gz (2 file(s))
```

## Implementation (what the assistant does)

The command is a thin wrapper. The assistant's job is to:

1. **Resolve the subcommand** from the user's args.
2. **For `/shipyard:cost` (no args, current session)**: locate the active session id (the orchestrator's session id, available in the calling context) and call `session-state.sh read-tokens --session-id <id> --format json` or `--format comment`. If there's no active session, fall through to suggesting `/shipyard:cost report`.
3. **For `/shipyard:cost report [...]`**: forward the args verbatim to `cost-history.sh report`:
   ```bash
   plugins/shipyard/scripts/cost-history.sh report "$@"
   ```
4. **For `/shipyard:cost reset [--yes]`** and **`export --to <path>`**: forward verbatim. The reset prompt is on stdin — the assistant pipes the user's confirmation through.

## Privacy

Both `cost-history.jsonl` and `cost-history-issues.jsonl` live entirely on the local filesystem — they are never uploaded anywhere by shipyard. The orchestrator's only outbound writes are to GitHub via `gh`; the ledger is not part of those flows. If you want to opt out a specific repo from cost-tracking even locally, set `cost_tracking.enabled: false` for that repo via `/shipyard:config set cost_tracking.enabled false --repo`. To turn cost-tracking off across every repo from the user-global layer, set the `cost_tracking_enabled` alias in `~/.shipyard/config.json` (it remaps onto `cost_tracking.enabled` on load; a repo-level `cost_tracking.enabled` still wins).

The ledger files are safe to `rm` — deleting them only forfeits historical reports. New sessions append fresh data after deletion.

## Retention

Default: **keep forever**. The data is tiny (≈ 500 bytes per session record, ≈ 200 bytes per issue record); even 1000 sessions stays comfortably under 1 MB. If you want to rotate, `/shipyard:cost reset` moves the current files to `.bak.<ts>` so a manual archival rotation is just a `mv` away.

## Don't

- **Don't hand-write to the JSONL files.** They're append-only by contract — `cost-history.sh flush` is the only safe writer. Editing in place could break the dedupe semantics (issue ledger expects the latest record per `(repo, issue_number)`).
- **Don't expect `/shipyard:cost` (no args) to work outside an active `/do-work` session.** That subcommand is per-session; without an active session id, use `/shipyard:cost report` for cross-session views.
- **Don't commit the ledger files.** They live at `~/.shipyard/` (user-scoped), not in the repo — but if you ever copy them into a project, make sure they're gitignored. They contain repo names + issue numbers but no secrets; still, they're personal usage data.

## Related

- [`/shipyard:do-work`](./do-work.md) — the orchestrator. End-of-session cleanup calls `cost-history.sh flush` ([step 7 of the cleanup chain](./do-work/cleanup-summary.md#end-of-session-cleanup)).
- [`/shipyard:config`](./config.md) — `cost_tracking.enabled` opt-out (repo/local), and the user-global `cost_tracking_enabled` alias.
- [`plugins/shipyard/scripts/cost-history.sh`](../scripts/cost-history.sh) — the underlying ledger / report tool.
- [`plugins/shipyard/scripts/session-state.sh`](../scripts/session-state.sh) — the per-session ledger (`bump-tokens`, `read-tokens`).
- Issue [#163](https://github.com/mattsears18/shipyard/issues/163) — this spec.
- Issue [#153](https://github.com/mattsears18/shipyard/issues/153) — the per-session ledger this builds on.
- Issue [#152](https://github.com/mattsears18/shipyard/issues/152) — the parent perf umbrella.
