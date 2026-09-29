# /shipyard:do-work — Setup phase · status-line UI + timing flush

**Setup sub-phase (cluster 4 of 5, part 5 of 5 — [#1431](https://github.com/mattsears18/shipyard/issues/1431), re-split by [#1446](https://github.com/mattsears18/shipyard/issues/1446)).** Owns steps **6.5 → 6.8**: the status-line + state-change-banner UI and the setup-timing flush into session state. Split out of [`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md) at that file's natural seam (per-returned-entry handling vs. UI/timing material) when 06c crossed its token-budget cap — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md) (same cluster, part 4 of 5). Next sub-phase: [`07-pool-fill.md`](./07-pool-fill.md).

### 6.5 Status line + state-change banners (UI)

There are two UI surfaces — both unconditionally re-print whenever repo-health state changes, so the user never has to scroll back to figure out what's going on.

#### Status line — one-line repo-health header

Print before the initial pool fill, and again at the top of any turn where state visibly changed (a completion landed, a divert flipped, the failing-PR count crossed the threshold either way, main flipped color, or a soft-collision claim count changed). Format:

```
/do-work · <owner/repo> · main:<emoji> · in-flight: <n>/<concurrency> [<labels>] · failing PRs: <m> (@me: <k>)<soft-suffix><divert-suffix>
```

Fields:

- **main:** — `🟢 green`, `🔴 red (<workflow-summary>, run <id>)`, `⏳ pending`, or `❔ unknown`. When red, `<workflow-summary>` is derived from `main_ci.red_workflow_count` and `main_ci.red_workflow_names`:
  - 1 failing workflow → `<workflow-name>, run <id>` (e.g. `Deploy to Play Store, run 18234567`)
  - 2–3 failing workflows → `<name1>, <name2>[, <name3>], run <id>` (list all names if they fit, truncate with `+N more` if needed to keep the status line under ~120 chars)
  - 4+ failing workflows → `<red_workflow_count> workflows: <name1>, <name2>, +<N> more, run <id>` (limit to 2 names before `+N more`)

  In all cases the run ID (`main_ci.earliest_red_run_id`) remains at the end of the parenthetical so the user can navigate directly to the failing run. No extra `gh` call — all data is in the `main_ci` cache from step 4.5a.

  When `main_ci.non_required_red_workflow_count > 0` (non-required workflows are red but main is gated to required-only), append a parenthetical suffix to the main field after the primary `🟢/🔴/⏳/❔` parenthetical (or directly after the emoji when status is green / pending / unknown): ` (infra: <name1>, <name2>[, +<N> more])`. Limit to 2 names plus `+N more` to stay terse. Example: `main:🟢 (infra: Android Release Notes)` — the green emoji communicates "no divert", the parenthetical surfaces the non-gating failure so the maintainer doesn't lose visibility into it. When `non_required_red_workflow_count == 0` (the common case), omit the suffix entirely.
- **in-flight labels** — comma-separated, derived from each entry's `kind`/`target`: issue → `#N`, fix-checks → `fix-checks #M`, fix-main-ci → `⚠️ fix-main-ci`, fix-failing-prs-batch → `⚠️ fix-prs-batch`. Empty list → `[ ]`.
- **failing PRs:** — the all-authors count from `failing_pr_count_all`. The `(@me: <k>)` parenthetical comes from `failed_prs.length + in_flight fix-checks count`. Append ` ⚠️` to the count when it's ≥ 10 (matches the divert threshold).
- **soft-suffix** — when one or more soft-collision paths are claimed by in-flight workers, append ` · [soft: <path>×<n>, <path>×<n>, ...]` listing each distinct claimed soft path and how many in-flight workers are holding it. Order by claim count desc, then alphabetical. Bracket and brackets are part of the surface (visually similar to the in-flight labels). Append ` ⚠️` to any path whose count equals `--soft-collision-concurrency` (the cap — next claimer on that path will park). Omit the suffix entirely when no soft-collision claims are active.
- **divert-suffix** — when a divert is enqueued but not yet in flight, append ` · diverting: <kind>`. When already in flight, the `[ ]` labels already make that visible, no suffix needed.
- **flake-escalated-suffix** ([#589](https://github.com/mattsears18/shipyard/issues/589)) — when any signature in `main_ci_fix_attempts` has `escalated == true`, append ` · flake-escalated: <sig> (<attempts> fix attempts, each green-on-PR/red-on-merge)`. This is the fix-main-ci attempt-cap circuit breaker firing: main is still red on `<sig>` but the orchestrator has stopped auto-diverting because each of `<attempts>` fix PRs passed on its own PR run and re-reddened the merge commit (a flaky-CI signature). When more than one signature is escalated, list each (comma-separated). The suffix persists until a human gets main green on `<sig>` (which clears the counter). Distinct from `· diverting:` — an escalated signature is explicitly NOT being diverted.

Examples:

```
/do-work · mattsears18/lightwork · main:🟢 · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/shipyard · main:🟢 · in-flight: 3/4 [#63, #65, #67] · failing PRs: 0 (@me: 0) · [soft: plugins/shipyard/commands/do-work.md×3 ⚠️, CHANGELOG.md×3 ⚠️]
/do-work · mattsears18/lightwork · main:🔴 (Deploy to Play Store, run 18234567) · in-flight: 2/2 [⚠️ fix-main-ci, #769] · failing PRs: 12 ⚠️ (@me: 2) · diverting: fix-failing-prs-batch
/do-work · mattsears18/lightwork · main:🔴 (3 workflows: Deploy to Play Store, Lighthouse CI, +1 more, run 18234567) · in-flight: 1/2 [⚠️ fix-main-ci] · failing PRs: 0 (@me: 0)
/do-work · mattsears18/lightwork · main:🟢 (infra: Android Release Notes) · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/lightwork · main:⏳ · in-flight: 0/2 [ ] · failing PRs: 0 (@me: 0)
/do-work · mattsears18/lightwork · main:🔴 (Web E2E Tests, run 18234567) · in-flight: 1/2 [#769] · failing PRs: 0 (@me: 0) · flake-escalated: Web E2E Tests (3 fix attempts, each green-on-PR/red-on-merge)
```

The soft-suffix is the human's signal that merge conflicts may surface at PR-land time on those paths. When a count hits the cap (` ⚠️`), the orchestrator is also one step away from parking — and the user can decide whether to bump `--soft-collision-concurrency` mid-session (next-session-only, the cap isn't hot-reloadable today) or let dispatch park.

When to print the status line: (a) startup, right before the initial pool fill; (b) any turn where `divert_queue` gained or lost an entry; (c) any turn where `main_ci.status` changed since the previous print; (d) any turn where `failing_pr_count_all` crossed the 10 threshold in either direction; (e) start of the end-of-session summary; (f) right after any state-change banner below; (g) any turn where a soft-collision claim count crossed `--soft-collision-concurrency` (entering or leaving the cap) on any path.

#### State-change banners — make divert events impossible to miss

The status line is for at-a-glance state. **Banners** are for the moments where state CHANGES — they're a 3-line block with blank lines above and below, so they stand out from completion-reconcile logs. Print every time one of the trigger conditions fires; never suppress them.

**Main flipped red → enqueueing a fix-main-ci diversion:**

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflow: <earliest_red_workflow_name>
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

When `red_workflow_count > 1`, replace the single `Failed workflow:` line with a plural form listing all failing workflows from `red_workflow_names`:

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflows (3): Deploy to Play Store, Lighthouse CI, Visual Regression
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

The workflow list in the banner is always the **full** `red_workflow_names` list (no truncation — banners are one-shot so verbosity is fine). Use a comma-separated inline list.

When `non_required_red_workflow_count > 0` AND the banner above is firing (a `green → red` transition on the *gating* set), append an info line after the workflows list noting which non-required workflows are also red, so the maintainer's mental model stays accurate:

```
   Non-required workflows also red (not diverting): Android Release Notes
```

When the banner is NOT firing because the gating set is green but `non_required_red_workflow_count` flipped from 0 → ≥1 (e.g. an infra workflow just turned red while CI stayed green), print a softer notification banner instead — this is a `🔔` advisory, not a divert trigger:

```

🔔  NON-REQUIRED CI WORKFLOW(S) RED — main_ci.status stays green, no divert
   Failed (non-required): Android Release Notes
   Note: these workflows aren't in branch protection's required_status_checks list; resolve in their respective consoles.

```

Trigger this notification banner only on the 0 → ≥1 transition (not every refresh) to keep the surface terse — the per-turn status-line `(infra: ...)` suffix carries the steady-state visibility.

**fix-main-ci dispatched (slot now in flight):**

```

🔧  DISPATCHED fix-main-ci on slot <id> — agent investigating <earliest_red_run_id>

```

**fix-main-ci attempt-cap hit → flake escalation, NOT diverting** ([#589](https://github.com/mattsears18/shipyard/issues/589)). Fired once per signature on the transition into `main_ci_fix_attempts[<sig>].escalated == true` (when `attempts >= main_ci.max_fix_attempts` and the red branch of [step 4.5a's enqueue rule](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) declines to enqueue):

```

🚩  FIX-MAIN-CI CAP HIT — likely flaky test, NOT diverting again
   Workflow: <earliest_red_workflow_name>
   Fix attempts this session: <attempts> (each green on its own PR run, red on the merge commit)
   Latest fix PR: #<last_pr> · earliest red run: <earliest_red_run_url>
   This pass-on-PR/fail-on-merge pattern is a strong flaky-CI signal (a deterministic
   regression would fail the PR run too). Recommended: quarantine the test (test.fixme /
   skip) + file a tracking issue, OR investigate CI-side. No further auto-dispatch for this
   workflow until a human gets main green on it.

```

The cap is the fix-main-ci analogue of the `blocked:ci` 3-attempt circuit breaker for fix-checks. After the banner fires, the status line carries `· flake-escalated: <sig> (<attempts> fix attempts, each green-on-PR/red-on-merge)` until a human resolves it (main goes green on `<sig>`, which clears the counter at the next green refresh).

**Main flipped back to green (red → green transition):**

```

✅  MAIN CI RESTORED — back to green at run <newest_green_run_id>

```

If a fix-main-ci diversion is in flight when this fires, also add: `   (in-flight fix-main-ci will finish naturally; result may already be redundant)`.

**Failing-PR count crossed UP through 10 — enqueueing a fix-failing-prs-batch diversion:**

```

⚠️  FAILING PR PILEUP — <n> open PRs are red, threshold is 10
   Sample: #<a>, #<b>, #<c>, ... (+ <k> more)
   Diverting next available slot to investigate common root cause.

```

**fix-failing-prs-batch dispatched:**

```

🔧  DISPATCHED fix-failing-prs-batch on slot <id> — investigating <n> failing PRs

```

**Failing-PR count crossed DOWN through 10:**

```

✅  PR PILEUP CLEARED — <n> failing PRs remain (below 10 threshold)

```

**Diversion completed (any kind):**

When a `fix-main-ci` or `fix-failing-prs-batch` worker returns, print a banner BEFORE the normal reconcile line:

- `shipped` → `✅  DIVERSION RESOLVED — fix-main-ci shipped via PR #<M> (auto-merge enabled)`
- `noop` → `➖  DIVERSION NO-OP — fix-main-ci: main already green by the time the agent started`
- `blocked` → `🛑  DIVERSION BLOCKED — fix-main-ci: <reason>. No auto-retry; needs human attention.` (and the status line that follows will keep showing `main:🔴` until a human resolves it)

**End-of-session — diversion summary block.** The end-of-session summary (below) carries a `Diversions:` block when `D > 0` — counts per kind, with shipped/noop/blocked breakdowns and PR numbers. That's how the user sees what diversions fired even if they weren't watching the session live.

The rule of thumb is: banners are LOUD and one-shot (printed when the transition happens), the status line is the persistent at-a-glance view (re-printed whenever the underlying state changes). Both should appear together when a divert fires — banner first, then the updated status line immediately below it.

### 6.8 Flush setup timing into session state

**Before dispatching the first wave of workers**, flush the setup-timing sidecar into the session state file's `setup` block. This ensures the timing data survives even if the session terminates mid-run (e.g. a Claude Code crash between pool fill and the first completion notification). The flush is fire-and-forget — a failure must NOT block pool fill.

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" flush \
  --session-id "<session-id>" 2>/dev/null || true
```

After this call the sidecar is gone and the session state file's `.setup` block contains the full per-phase wall-clock breakdown. The cost-history flush at end-of-session will pick it up automatically.
