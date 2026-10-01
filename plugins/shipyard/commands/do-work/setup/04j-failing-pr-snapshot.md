# /shipyard:do-work — Setup phase · failing-PR snapshot + drain hand-off + flake registry

**Setup sub-phase (cluster 3 of 5, part 2 of 2 — [#1446](https://github.com/mattsears18/shipyard/issues/1446)).** Continues from [`04-backlog-divert.md`](./04-backlog-divert.md): steps **5 → 5.8** — the failing-PR snapshot, seeding inherited DIRTY PRs into `session_prs` for cross-session drain hand-off, seeding inherited draft PRs, and the flake-registry enforcement. Split out at this seam once `04-backlog-divert.md` crossed the token-budget warn band ([#1446](https://github.com/mattsears18/shipyard/issues/1446); PR #1437 had already once red-lined CI on this same file at 60,184 bytes) — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233) / [#1431](https://github.com/mattsears18/shipyard/issues/1431). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`04-backlog-divert.md`](./04-backlog-divert.md) (same cluster, part 1). Next sub-phase: [`06-scope-preflight.md`](./06-scope-preflight.md).

### 5. Snapshot failing PRs

> **Lazy-load when `concurrency == 1`.** At C=1 the orchestrator runs sequentially — at most one slot is ever in flight. The failing-PR set is only relevant when there's a free moment to dispatch a fix-checks worker, and a free moment is guaranteed to exist whenever the single slot returns and all queues are empty. Skip this query at setup and defer it to the first idle turn in the steady-state loop (step D's Failed-PR scan). Set `failed_prs = []` at startup. The `-label:blocked:ci` filter note still applies when the deferred query eventually runs.

This read is part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire it in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b. The filtering / deduping logic runs locally on the returned JSON.

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs) AND `mergeStateStatus != "DIRTY"` (mirrors `drain.md`'s `R_new`, [#1060](https://github.com/mattsears18/shipyard/issues/1060)). Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). Same reasoning as step 4.5b above: `statusCheckRollup` returns every check run for the head SHA, and stale FAILURE entries superseded by later SUCCESS would otherwise re-enqueue PRs into `failed_prs` that are actually green. The orchestrator then dispatches a fix-checks worker, which returns `noop: already green` — wasted dispatch slot and tokens. De-duplicate first:

**Second discriminator — `mergeStateStatus == "BLOCKED"` with zero pending checks ([#1435](https://github.com/mattsears18/shipyard/issues/1435)).** A "latest conclusion is FAILURE" scan misses a required check *context* that never ran (a renamed/disabled workflow, or a required-check name with no matching job) — it never appears in `statusCheckRollup`, so the PR stays `BLOCKED` forever with no explicit FAILURE. `BLOCKED` with zero pending/in-progress checks isn't queue latency (a healthy PR's `BLOCKED` clears once its last pending check resolves) — it's an independent "needs fixing" signal on its own. Both discriminators read the same already-fetched `statusCheckRollup`; no extra `gh` call.

```bash
failed_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100 \
  --jq '[.[] | . as $pr
    | ($pr.statusCheckRollup | group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last)) as $latest
    | ($latest | map(select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))) | length) as $fails
    | ($latest | map(select(((.conclusion // null) == null) and ((.state // .status // "") | test("PENDING|IN_PROGRESS|QUEUED|EXPECTED")))) | length) as $pending
    | select(($fails > 0 or ($pr.mergeStateStatus == "BLOCKED" and $pending == 0)) and $pr.mergeStateStatus != "DIRTY")]')
```

Each entry → push onto `failed_prs`, **deduped against entries already in `failed_prs`** (step 3c may already have enqueued some). These are the highest-priority work items *after* `divert_queue` because a red PR you opened last session won't auto-merge no matter how many new issues you ship. Note: this query is `@me`-scoped on purpose — `failed_prs` is for fix-checks work on PRs *you authored*. The all-authors count from step 4.5b feeds the divert decision, not this queue.

**Why `BLOCKED` alone is never the trigger — the `$pr.mergeStateStatus == "BLOCKED"` guard is deliberately narrower than "not mergeable" ([#1435](https://github.com/mattsears18/shipyard/issues/1435)).** `DIRTY` is excluded via the outer select's explicit `$pr.mergeStateStatus != "DIRTY"` conjunct ([#1441](https://github.com/mattsears18/shipyard/issues/1441)), needed for **both** branches — a DIRTY PR's rollup can still carry a stale frozen FAILURE (tripping `$fails > 0`) and would otherwise vacuously pass `$pending == 0` too. A `BLOCKED` PR blocked by a required **review**, not CI, is a rarer accepted false positive: the dispatched worker finds nothing red and returns `noop: already green #<M>` — a bounded one-dispatch cost, cheaper than leaving a stuck PR silent indefinitely.

**Classification, not one state.** A session PR's blocked-ness resolves to one of three causes: **conflict** (`DIRTY` → `fix-rebase` via `session_prs`, step 5.7 / the drain's `D_dirty` classifier), **red** (an explicit failing check, or `BLOCKED` with zero pending → `failed_prs` → `fix-checks-only`), and **pending** (`BLOCKED`/unmergeable with checks still queued — a healthy queue wait, left alone). A watcher tracking only open-vs-closed count can't tell a permanently red-blocked PR from one progressing through a busy queue — don't infer "settling" from open/closed alone; use this classification instead.

The `-label:blocked:ci` filter is still correct because [step 3d's auto-clear sweep](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) already ran — refreshed PRs are unlabeled by 3d and flow through normally; only genuinely-stuck PRs still carry the label here. See [RATIONALE → Step 5 filter correctness](../../../../../docs/design/do-work-rationale.md#step-5--why-the--labelblockedci-filter-is-still-correct).

### 5.7 Seed inherited DIRTY PRs into `session_prs` (cross-session drain hand-off)

Closes [#373](https://github.com/mattsears18/shipyard/issues/373) — the **cross-session DIRTY-PR blackhole**: a PR left `DIRTY` by a prior session is invisible to both steady-state (fix-rebase is drain-only) and the drain (it's not in `session_prs`), forever, until a human rebases it manually. See [RATIONALE → Step 5.7 cross-session DIRTY-PR blackhole](../../../../../docs/design/do-work-rationale.md#step-57--the-cross-session-dirty-pr-blackhole-issue-373) for the full failure mechanism and the `mattsears18/lightwork` repro (PRs #1355/#1361/#1364/#1371 stranded 24+ hours).

This step snapshots the inherited DIRTY PRs authored by `@me` and seeds them into `session_prs` at setup, so the existing drain machinery owns them — no new dispatch surface. The drain's per-poll `D_dirty` classifier then dispatches a fix-rebase worker for each (subject to the same `--concurrency` cap, `rebase_blocked_prs` gate, and 3-successful-rebase rate cap that govern session-opened DIRTY PRs). Query source is a direct DIRTY-PR query, not `failed_prs` (which is scoped to red-check PRs and would miss the DIRTY-but-green case) — projected the same `@me` + `mergeStateStatus == "DIRTY"` way the drain's `D_dirty` set already is.

This read is part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it can fire in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5. Query `@me`-authored open PRs and keep those whose `mergeStateStatus == "DIRTY"`, regardless of check colour — matching the drain's [`D_dirty` definition](../drain.md#drain-protocol) exactly: as of [#1060](https://github.com/mattsears18/shipyard/issues/1060), `mergeStateStatus == "DIRTY"` alone routes a PR to `fix-rebase`, because no check can be queued or refreshed while a PR is DIRTY — a failing check on a DIRTY PR is a frozen fossil of the last buildable base, not live evidence about the PR's current health, so it's never a reason to withhold the PR from this seed. (`drain.md`'s `D_dirty_red` is an *informational* subset of `D_dirty` for the status line only, never a routing distinction — this seed doesn't need to reproduce that split, since the drain re-derives `D_dirty_red` itself from a fresh rollup read at poll time.)

```bash
inherited_dirty_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-is:draft' \
  --json number,mergeStateStatus \
  --limit 200 \
  --jq '[.[] | select(.mergeStateStatus == "DIRTY") | .number]')
```

Append each number to `session_prs`, **deduped** against entries already there (a PR this session opened and that has since gone DIRTY is already in `session_prs` — don't double-add). The dedup also means re-running this step is idempotent. Do NOT mark these PRs in any other queue (`failed_prs`, `ready_issues`, `divert_queue`) — `session_prs` membership is the entire mechanism; the drain's existing classifier does the rest. See [RATIONALE → Step 5.7](../../../../../docs/design/do-work-rationale.md#step-57--the-cross-session-dirty-pr-blackhole-issue-373) for why this seeds at setup rather than re-querying inside drain.

> **Lazy-load when `concurrency == 1`** — same carve-out as [step 5](#5-snapshot-failing-prs). At C=1 the inherited-DIRTY snapshot can defer to the first idle turn alongside the step-5 failed-PR scan; the drain only consumes `session_prs` at end-of-session, so seeding it any time before drain entry is sufficient. When deferred, [steady-state step D's failed-PR scan](../steady-state.md#d-periodic-refresh) runs this query in the same sub-step (it's the same `@me` open-PR list, just a different projection) and seeds `session_prs` then. Set the snapshot aside at startup and let step D pick it up.

### 5.75 Seed inherited draft PRs (draft-PR recovery)

Closes #1069 — a draft PR is invisible to the step-5 scan (checks read SKIPPED, not red) and to 5.7's DIRTY seed (`mergeStateStatus` is usually CLEAN). Read [`04c-draft-pr-recovery.md`](./04c-draft-pr-recovery.md) now and run it in full: classify inherited `@me` draft PRs, auto-ready the safe ones, hand back the rest, record both for the summary.

### 5.8 Enforce the flake registry (chronic-flake escalation)

Closes [#385](https://github.com/mattsears18/shipyard/issues/385) — phase 2 of the cross-PR flake registry. [Phase 1](#5-snapshot-failing-prs) (issue #378, `scripts/flake-registry.sh`) shipped the data layer: each `fix-checks-only` worker records a flake event when it concludes a failure was a flake, and `flake-registry.sh crossed` names which (workflow, job, test) flakes have crossed the escalation threshold (≥ `rerun_threshold` events spanning ≥ `distinct_prs_threshold` distinct PRs within `window_days`). Phase 1 deliberately stopped at "name the crossed flakes." This step is the **enforcement consumer** — it reads `crossed` and performs the three configured escalation actions so a chronic flake gets root-caused instead of silently re-run forever. Also closes [#863](https://github.com/mattsears18/shipyard/issues/863): the `--prune-window-days` flag on the `flake-enforce.sh enforce` call below is the scheduled prune this step was missing — see that call's comment for the wiring.

**Gate on `flake_registry.enabled`.** Skip this step entirely unless the effective config has `flake_registry.enabled == true` (it defaults to `false`, preserving pre-#378 behavior). The check is one config read against the already-loaded `EFFECTIVE_CONFIG` (step 0.4). **No shell `if` wraps the enforcement calls below, and no pipe carries `flake-enforce.sh`'s output into `sed` ([#1277](https://github.com/mattsears18/shipyard/issues/1277))** — the gate branches in prose instead (same style as step 6.a's ungated-admin-direct-merge check), and the output prefix runs as a second, file-argument `sed` call. See [`dont.md`'s post-relocation compound-block rule](../dont.md#post-relocation-bash-command-shape--measurements-retired-2026-09-30).

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
# Pin SHIPYARD_REPO_ROOT to the step-0.56 primary-root literal (#1619) rather than
# `git rev-parse --show-toplevel` (issue #1059) — the latter resolves to
# the orchestrator worktree post-relocation, not the primary checkout where
# the gitignored flake-suspects.txt persists across sessions, and every
# shipyard-config.sh call in this step (including this very FLAKE_ENABLED
# read) must read repo-level config from the primary, not the orchestrator
# worktree.
export SHIPYARD_REPO_ROOT="<primary-root literal>"
FLAKE_ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
```

`FLAKE_ENABLED != "true"` → skip the rest of this step entirely; nothing below runs. `FLAKE_ENABLED == "true"` → continue with the reads and the enforcement call below, in order.

Read crossed flakes and enforce the per-row actions. The helper computes `crossed` itself (passing the configured window/thresholds through), files a deduped tracking issue per crossed flake, writes the crossed key to `<repo-root>/.shipyard/flake-suspects.txt`, and labels affected PRs `blocked:ci` — each action idempotent so re-running across sessions doesn't duplicate side effects. `--repo-root` MUST be the PRIMARY checkout, not the orchestrator worktree (issue #1059) — `.shipyard/flake-suspects.txt` is gitignored, so a fresh orchestrator worktree checked out from `origin/<default-branch>` never contains a suspects file a prior session wrote; pointing this call at the orchestrator worktree would silently restart flake tracking from empty every session instead of accumulating across them. Use the `$SHIPYARD_REPO_ROOT` pin exported above, not `git rev-parse --show-toplevel` (which resolves to wherever cwd currently is — the orchestrator worktree, post-relocation).

`--prune-window-days` (issue #863): `flake-registry.sh` has always shipped a `prune` subcommand, but nothing ever called it — with flake_registry enabled, `~/.shipyard/flake-registry.jsonl` grew unbounded forever. This is the scheduled call: once per session, gated on the same `flake_registry.enabled` flag as the rest of this step, opted into `flake-enforce.sh`'s own `--prune-window-days` flag so a bare `enforce` invocation elsewhere (tests, manual runs) still leaves the registry untouched by default. `PRUNE_WINDOW_DAYS` reads `flake_registry.prune_window_days` (default 90 — generous; the registry is cheap to keep).

Re-export both pins as literals (variables don't survive across separate Bash calls), read `PRUNE_WINDOW_DAYS`, then run the enforcement call — one plain sequence, output redirected to a scratch log rather than piped into `sed`:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
export SHIPYARD_REPO_ROOT="<primary-root literal>"
PRUNE_WINDOW_DAYS=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get flake_registry.prune_window_days 2>/dev/null || echo 90)
case "$PRUNE_WINDOW_DAYS" in ''|*[!0-9]*) PRUNE_WINDOW_DAYS=90 ;; esac
"$CLAUDE_PLUGIN_ROOT/scripts/flake-enforce.sh" enforce \
  --repo "<owner/repo>" \
  --repo-root "$SHIPYARD_REPO_ROOT" \
  --prune-window-days "$PRUNE_WINDOW_DAYS" \
  > .shipyard-flake-enforce.log 2>&1
FLAKE_ENFORCE_EXIT=$?
```

Prefix and print the captured log as its own, separate command — `sed` reading a file argument directly is not a pipe:

```bash
sed 's/^/[flake-enforce] /' .shipyard-flake-enforce.log
```

If `$FLAKE_ENFORCE_EXIT` was non-zero, this is the same advisory the old `|| echo` fallback gave — log it and continue setup rather than blocking the session on a flake-enforcement hiccup:

```bash
[ "$FLAKE_ENFORCE_EXIT" -ne 0 ] && echo "[flake-enforce] advisory: enforce pass errored; continuing setup"
```

**Read site: setup, once per session.** The issue's open question ("setup once per session vs. per-dispatch") resolves to **setup** — it's the cheapest site and the registry escalation state changes slowly (a flake crosses the threshold over days, not within a single session's dispatch cadence). The one piece of mid-session freshness that matters — a flake escalated by *this* session's own `fix-checks-only` recording — is still honored without a per-dispatch enforce pass, because the `stop-auto-rerunning` consumer (fix-checks-only's [pre-rerun suspects check](../../../agents/issue-worker/fix-checks-only.md#fix-loop)) re-reads `.shipyard/flake-suspects.txt` on every dispatch. So a flake that crosses mid-session is suppressed by the next fix-checks worker even though the issue-filing / PR-labeling actions ran only at setup. Per-dispatch enforcement of the issue-filing and labeling actions is a deliberate non-goal for this slice; see the issue's scope notes.

**Idempotence is load-bearing here.** `/do-work` re-runs setup every session. The enforce helper dedupes all three actions: `file-tracking-issue` skips when an OPEN issue already carries the flake's `flake-key=<...>` marker; `stop-auto-rerunning` skips a key already in the suspects file; `apply-blocked-ci` skips a PR already labeled `blocked:ci`. A session that finds no newly-crossed flakes (or only already-enforced ones) makes zero GitHub writes. The added prune call (#863) is separately idempotent — pruning to the same window twice in a row is a no-op rewrite the second time — and fire-and-forget: `flake-enforce.sh` logs a `prune advisory` line and continues into the rest of enforcement if the prune itself fails, so a housekeeping hiccup never blocks the escalation actions this step exists for.

This step is **independent of the parallelization batch** (it shells out to a local helper that itself calls `gh`, rather than being a single projectable `gh` query the orchestrator can co-fire). Run it after the failing-PR snapshots (steps 5 / 5.7) so the `blocked:ci` labels it applies are visible to any subsequent `-label:blocked:ci`-filtered query in the same session. It's also fine to defer to the first idle turn at C=1 alongside the other lazy-loaded snapshots — the escalation state isn't time-critical within a session.
