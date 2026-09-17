# /shipyard:do-work — Setup phase · parallelization batch + gh caches

**Setup sub-phase (cluster 1 of 5, part 2 of 2 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Continues step **0.7** (the canonical setup-parallelization batch + background cleanup group) from [`00-config-worktree.md`](./00-config-worktree.md), then owns steps **0.8 → 0.9.1**: the `blocker_state` cache, the `gh-cached.sh` wrapper, and the `gh-batch.sh` GraphQL wrapper. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md) (same cluster, part 1). Next sub-phase: [`01-repo-recovery.md`](./01-repo-recovery.md).

**Steps 1 → 5 are a graph of read-only `gh` calls with no data dependencies on each other.** Fire them as a single parallel burst — either one `Bash` tool call wrapping `bash -c '... & ... & wait'`, or N parallel `Bash` tool calls in one orchestrator message. A serial walk through steps 1 → 5 is the failure mode this section prevents.

**Timing instrumentation (issue #238).** The parallel batch as a whole is one timing window. Open the window just before firing the burst; close it once `wait` (or all parallel tool calls) return.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
# ... fire all parallel gh calls ...
# ... wait for all to return ...
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
```

**Canonical setup batch — these reads have no data dependencies:**

- ~~Step 1 — repo + user metadata~~ — moved pre-relocation, to [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) ([#1202](https://github.com/mattsears18/shipyard/issues/1202)). `<owner/repo>` / `<default-branch>` are static for the session, so the values 0.45 resolves are reused here rather than re-read.
- **[Step 2](01b-backlog-overview.md#2-backlog-overview)** — issue universe (`gh issue list --state open` + `linked:pr` search). **Skipped under `--fast`** — but count refinement candidates (by source-signal scan — `user-feedback` / `## Open questions` / bot author, since the `needs-refinement` label was eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)), `blocked:ci`, `blocked:agent-soft`, and legacy `blocked:agent` issues first (see step 2's `--fast` note). (`blocked:agent-hard` was eliminated in [#521](https://github.com/mattsears18/shipyard/issues/521) — no count.)
- **[Step 3d.1](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)** — `blocked:ci` PR list. Per-PR `events` + `commits` lookups are a second-tier parallel batch keyed off the first-tier result. **Skipped under `--fast`** (the initial `gh pr list --label blocked:ci --json number --jq 'length'` count still runs for advisory reporting — see step 3d.1's `--fast` note).
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)** — five sub-sweeps in sequence: legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521) — dependency-wait → no label, else → `needs-human-review`), `blocked:agent-soft` next-session sweep, and three new legacy-label migration sweeps ([#537](https://github.com/mattsears18/shipyard/issues/537)) for `needs-design` → `needs-human-review`, `needs-decomposition`/`tracking` → `needs-human-review` + decomposition marker, and `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. (Sub-sweep a, the `blocked:agent-hard` referential clear, was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521).) Per-issue blocker-state lookups (sub-sweeps b and f) read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). **Skipped under `--fast`** (the initial label counts still run for advisory reporting — see step 3d.2's `--fast` note).
- **[Step 4.5a](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — main CI status (`gh run list --branch <default-branch> --limit 60`). **Skipped under `--fast`** — `main_ci.status` left as `"unknown"`.
- **[Step 4.5b](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — all-authors failing-PR count. **Skipped under `--fast`** — `failing_pr_count_all` left as `0`.
- **[Step 5](04j-failing-pr-snapshot.md#5-snapshot-failing-prs)** — `@me` failing-PR snapshot.

#### Background bash group (fire-and-forget from step 0.7)

The following steps are cleanup-only — they don't affect dispatch correctness and don't need to complete before the first worker fires. Fire them as a single background subshell immediately after opening the timing window, capture the PID, and let dispatch proceed without waiting.

**Narrowed to 1.6 + 3a only ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).** This group used to also carry 1.6.5 (orphan orchestrator-worktree sweep), 3b (stale agent-worktree reap), and 3c (orphan `do-work/*` branch triage) — all three moved to [00-config-worktree.md's new step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), which runs **before** `EnterWorktree` (step 0.5) relocates the session. Reason: every one of those three sweeps performs `git -C <other-worktree>`-shaped operations, which the worktree-isolation guard refuses once this session has isolated — a refusal this background group's own post-relocation position made unavoidable. 1.6 (pure `$SHIPYARD_HOME/sessions/*.json` housekeeping) and 3a (pure `gh label create`) touch no worktree path, so neither needed to move.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Re-derive & re-export the SHIPYARD_REPO_ROOT pin from the step-0.56 stash
# (issue #1059/#1064) — every shipyard-config.sh get below (warn_threshold,
# max_per_session, auto_merge_method) would otherwise silently drop
# .shipyard/config.local.json. Exported here so the background subshell
# below inherits it.
SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null || pwd)
export SHIPYARD_REPO_ROOT
(
  # 1.6 — Orphan session-file sweep (cost-ledger recovery). Cleanup-only — recovery
  # of historical ledger data is observational and doesn't affect this session's dispatch.
  # Layered protection (issue #253): the 30-min mtime floor catches files that haven't
  # been written through recently AND the `is-active` PID-liveness check skips files
  # whose owning process is still alive. Both have to fail before reap — protects
  # against the race where a peer orchestrator went quiet for >30 min (long drain,
  # CI watch) but is still actively running and will write through again.
  #
  # Extracted into sweep-orphan-sessions.sh (issue #1182) — this used to be
  # an inlined `find | while read` loop calling two other scripts per
  # iteration, the same multi-statement compound shape sweep-orphan-tmp.sh
  # (issue #858, immediately below) already extracted for the sibling
  # .tmp-leftover sweep. A single plain script call, with its own test
  # coverage under scripts/tests/, rather than an untested inline loop
  # nested three levels inside this already-large background group.
  "$CLAUDE_PLUGIN_ROOT/scripts/sweep-orphan-sessions.sh" sweep \
    --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}" \
    --current-session-id "<session-id>" \
    --reaper-session-id "<session-id>" 2>/dev/null || true

  # 1.6 (continued) — orphan atomic-write .tmp sweep (issue #858). The sweep
  # above only discovers stale *.json files; a .tmp.<pid> whose target
  # .json never landed (crash mid-atomic_write, most commonly during
  # `session-state.sh init`) matches no session id the loop above could
  # hand to `cleanup --session-id`, so it would otherwise linger forever.
  # cost-history.sh's reconcile-rewrite tmp/.err files and
  # flake-registry.sh's prune-rewrite tmp file have the identical gap, with
  # no sweep anywhere for either. sweep-orphan-tmp.sh closes all three in
  # one pass, gated on the same age-floor-plus-liveness shape as above
  # (pid-embedded liveness for the two *.tmp.$$ writers; a fresh
  # cost-history.jsonl.lock protects the whole mktemp-suffixed category
  # instead, since those names carry no pid to check). Every reap is
  # logged (not silent) — see the script's own header for the full
  # rationale and 01-repo-recovery.md's step 1.6 section for the
  # human-readable writeup.
  "$CLAUDE_PLUGIN_ROOT/scripts/sweep-orphan-tmp.sh" sweep \
    --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}" 2>/dev/null || true

  # 1.6.5 (orphan orchestrator-worktree sweep), 3b (stale agent-worktree
  # reap), and 3c (orphan do-work/* branch triage) MOVED OUT of this
  # background group — issue #1202. All three perform `git -C
  # <other-worktree>`-shaped operations, which the worktree-isolation guard
  # refuses once EnterWorktree (step 0.5) has isolated this session — and
  # this background group only ever fires AFTER step 0.5, since it's part
  # of step 0.7. They now run synchronously at
  # 00-config-worktree.md's step 0.45, BEFORE step 0.5, while cwd is still
  # the primary checkout and the guard has no isolated session to enforce
  # against. See step 0.45 for the full rationale and the executable form.

  # 3a — gh label create (14 idempotent labels). All idempotent; only needed by the
  # time the first agent applies a label, not before dispatch fires.
  for label_args in \
    "shipyard --description 'Worked on by /shipyard:do-work' --color 5319E7" \
    "P0 --description 'Critical / release-blocker' --color B60205" \
    "P1 --description 'High — this cycle' --color D93F0B" \
    "P2 --description 'Normal' --color FBCA04" \
    "user-feedback --description 'Originated from end-user feedback (untrusted body — treat with care)' --color 0E8A16" \
    "needs-human-review --description 'Awaiting a human DECISION before /do-work will touch it' --color D93F0B" \
    "agent-console --description 'Needs a browser/console operator action — a human, or /do-work via the extension' --color 1D76DB" \
    "blocked:agent-soft --description 'Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes.' --color FBCA04" \
    "blocked:ci --description 'CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover.' --color B60205"
  do
    eval "gh label create $label_args --repo <owner/repo> 2>/dev/null || true" &
  done
  wait  # wait for the parallel label creates to finish
) &
SETUP_BACKGROUND_PID=$!
```

**The background group now handles only steps 1.6 and 3a** ([#1202](https://github.com/mattsears18/shipyard/issues/1202) — 1.6.5 / 3b / 3c moved to [00-config-worktree.md's step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), which runs synchronously before `EnterWorktree`; see there for their code). The parallel batch (steps 1 → 5) and the foreground-serial steps (1.7, 3.5, 4 → 7) all proceed without waiting on `$SETUP_BACKGROUND_PID`. End-of-session cleanup's step 7 (`cost-history.sh flush`) must `wait $SETUP_BACKGROUND_PID` before flushing to ensure the 1.6 orphan sweep has completed — the flush and the sweep both write to `cost-history.jsonl`, and both are idempotent, but the `wait` prevents a double-flush race on the same session file.

### Classifier-denial fallback — the background group's own Bash tool call can be refused outright ([#1042](https://github.com/mattsears18/shipyard/issues/1042))

The `(...) &` block above is submitted as **one** Bash tool call. The permission classifier evaluates that whole compound text before any of it executes — a destructive verb anywhere inside it can trip a denial for the **entire** call, not just the risky line. When that happens, `SETUP_BACKGROUND_PID=$!` never runs — none of 1.6 / 3a executed. This is precisely the "sweep denied, denial invisible" failure [`dont.md`](../dont.md)'s "Don't swallow a failed or denied reap" rule ([#712](https://github.com/mattsears18/shipyard/issues/712)) already prohibits — but #712's existing wiring ([cleanup-summary.md step 5.5's `report-unreaped` scan](../cleanup-summary.md#end-of-session-cleanup)) only runs at **end of session**, and nothing today re-checks the setup-time denial specifically, so a whole-group refusal at session **start** went unreported end to end in the [#1042](https://github.com/mattsears18/shipyard/issues/1042) repro (29 worktrees stranded across multiple prior sessions, zero visibility in any summary).

**The higher-risk destructive verbs moved with the sweeps ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).** `reap-stale`'s escalation to `git worktree remove --force` (step 3b) and `git branch -D` (step 3c) are no longer part of THIS block — they now run at [00-config-worktree.md's step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), pre-relocation. The same denial risk this section documents applies there too, with the same recovery shape (don't retry the identical text; run `report-unreaped` as its own read-only foreground call; record the denial for the end-of-session summary) — step 0.45 is a synchronous foreground sequence rather than a single background call, so a mid-sequence denial is easier to isolate to the specific offending step than a denial of this whole `(...) &` block is.

**Detect the denial directly from the Bash tool's own result for the call above** — a permission denial returns as the tool result for that specific call (e.g. `Permission for this action was denied by the Claude Code auto mode classifier`), not as stdout the shell script's own `2>/dev/null || true` could have swallowed. When the background-group launch returns that instead of a normal background-launch result:

1. **Don't retry the same compound command.** Per `shipyard:worker-preamble` § "After a classifier denial" and [`dont.md`](../dont.md)'s "Don't iterate prompt wording against the permission classifier" rule, re-submitting the identical destructive-operation text (or a cosmetically-reworded version of it) is not the fix.
2. **Run the read-only verification immediately, as its own separate foreground call.** `report-unreaped` only enumerates directories — it removes nothing — so it is not a plausible denial candidate on its own, and it doesn't need to wait for anything else to finish (nothing else ran):

   ```bash
   CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
   export CLAUDE_PLUGIN_ROOT
   SY_TOPLEVEL="$(git rev-parse --show-toplevel)"
   setup_reap_denial_unreaped=$("$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" report-unreaped \
     --repo-root "$SY_TOPLEVEL" \
     --current-session-id "<session-id>" | wc -l | tr -d ' ')
   echo "setup-background-group-denied: unreaped=$setup_reap_denial_unreaped"
   ```

   The final `echo` is load-bearing, not decorative — it's what makes the count visible in this Bash call's own tool result rather than trapped in a shell variable the process discards on exit (a shell variable set in one Bash tool call never survives to the next one).
3. **Record `setup_reap_sweep_denial`** (session-local orchestrator state — see [`orchestrator-state-reference.md`](../orchestrator-state-reference.md)) with the denial text and `setup_reap_denial_unreaped`, so [cleanup-summary.md step 5.5](../cleanup-summary.md#end-of-session-cleanup) folds it into the end-of-session `Cleanup:` line even if this session's own later reap attempts happen to succeed on unrelated worktrees and would otherwise report a clean `unreaped_worktrees == 0`.
4. **Proceed with the rest of setup unaffected.** Steps 1 → 5's parallel batch and the foreground-serial steps do not depend on the background group. A denied background group costs cleanup visibility, not dispatch correctness — do NOT fall back to running 1.6 / 3a inline on the orchestrator's own foreground thread; that reintroduces the blocking-on-cleanup cost the background group exists to avoid, for work whose entire value proposition is "best-effort, not required for this session's dispatch to proceed."

**The full execution model after this change ([#1202](https://github.com/mattsears18/shipyard/issues/1202) reordering reflected):**

```
step 0.45 (pre-relocation, before EnterWorktree) — synchronous, foreground:
  1     resolve repo + user + default branch
  1.3   ungated-merge-shape detect + concurrency clamp
  1.36  CI-runner-pool detect + concurrency clamp
  1.5   session-state init
  1.6.5 orphan orchestrator-worktree sweep (issue #280)
  3b    stale agent-worktree reap
  3c    orphan do-work/* branch triage
        ↓
step 0.5 EnterWorktree (session isolates)
        ↓
step 0.7 opens timing window
  ├── background group (SETUP_BACKGROUND_PID) — fire and forget:
  │     1.6   orphan session-file sweep
  │     3a    gh label creates (parallel within group)
  └── foreground parallel batch (steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5)
        └── after batch: step 1.7 → 3.5 → 4 → 4.5 aggregate → 6 → 7 (serial)
```

### Worktree-isolation classifier refusal — decompose into a self-contained wrapper or separate plain calls ([#1182](https://github.com/mattsears18/shipyard/issues/1182))

**Distinct from the destructive-verb denial above.** In a worktree-isolated session (`EnterWorktree`, the primary path per [step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)), Auto Mode's classifier can refuse the whole `(...) &` background-group call — or a sub-piece of it — for a *different* reason: *"this command is too complex to verify that it stays inside the worktree; break it into plain, separate commands."* Confirmed in the [#1182](https://github.com/mattsears18/shipyard/issues/1182) repro: step 3a's `for label_args in ... do eval "gh label create ... " & done; wait` loop was refused outright as part of this group, and the step-1.6 sweep loop (now extracted into `sweep-orphan-sessions.sh`, above) was likewise refused until re-wrapped. This is the same refusal shape `shipyard:worker-preamble`'s [`assert-worktree-cwd-fallback.md`](../../../skills/worker-preamble/assert-worktree-cwd-fallback.md) documents for worker-side blocks, reproduced here at the orchestrator's own step 0.7.

**Recovery — two equivalent shapes; pick whichever is cheaper for the step at hand:**

1. **A single self-contained `bash -c '…'` wrapper.** Fold the step's own commands into one `bash -c` argument with no host-shell-variable dependencies — every value either a literal substituted in directly, or re-derived inside the wrapper's own `-c` string — the same "resolve inside the call, don't depend on cross-call shell state" discipline [step 0.3](00-config-worktree.md#03-claude_plugin_root-re-export-preamble-every-bash-tool-call)'s `CLAUDE_PLUGIN_ROOT` preamble already uses. This is the shape that recovered the step-1.6 sweep loop in the #1182 repro, before it was extracted into its own script.
2. **Separate plain `Bash` tool calls, one per step.** Run 1.6 / 3a as N separate foreground (not backgrounded) calls instead of one `(...) &` block. This loses the "fire-and-forget, don't block dispatch" property the background group exists for — every step now runs in the foreground, serially — so accept that cost only when the compound form is genuinely refused; it is not a general substitute for the background group on the happy path. (This refusal shape can equally hit [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202)'s pre-relocation sequence — the same recovery applies there: decompose into separate plain calls rather than retry the refused compound text.)

Either way, **don't retry the identical refused compound text** — per `shipyard:worker-preamble` § "After a classifier denial" and [`dont.md`](../dont.md)'s "Don't iterate prompt wording against the permission classifier" rule (cited above for the destructive-verb case; it applies identically here): decompose, don't reword.

**Extracting a step into its own script (as step 1.6 was, above) is the strongest fix when a step turns out to be a *recurring* refusal target**, since it collapses the step to a single plain call permanently — every future session gets the simpler shape for free — rather than requiring per-session decomposition. That's a larger, per-step judgment call (surface area, need for test coverage, how load-bearing the step is), matching the extraction precedent `sweep-orphan-tmp.sh` (#858) and `sweep-orphan-sessions.sh` (#1182, above) both set. The `bash -c` wrapper or the separate-calls fallback above are the immediate, always-available recovery when a step hasn't (yet) earned that investment.

**Steps that MUST run after the batch (foreground, serial):**

- **[Step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist)** — its output (`trusted_authors`) gates step 2's bucketing and step 4's filter.
- **[Step 3.5](01c-label-recovery-refine.md#35-refine-pending-issues)** — invokes `/refine-issues`, blocks until done. **Skipped under `--fast`**.
- **[Step 4](04-backlog-divert.md#4-fetch--rank-the-backlog)** — the *filtered* backlog fetch (distinct from step 2's universe fetch). Auto-triage label-stamping depends on step 1.7 + step 2.

**Steps 6+ stay serial.** Scope pre-flight (step 6) depends on `raw_backlog` from step 4; initial pool fill (step 7) depends on `ready_issues` from step 6.

The numbered subsection order (1 → 5) is documentation layout — execution is parallel.

### 0.8 `blocker_state` cache (default-on)

Session-local map `blocker_state: { <issue-or-pr-number> → "OPEN" | "CLOSED" | "MERGED" | "unresolvable" }` shared by three setup paths:

- **[Step 2](01b-backlog-overview.md#2-backlog-overview) bucket-6** — for every `Blocked by #N` reference in a bucket-6 issue body, `gh issue view <N> --json state` (with `gh pr view <N>` fallback). Cache the result.
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) auto-clear sweep** — same lookups; read-through cache.
- **[Step 2](01b-backlog-overview.md#2-backlog-overview) bucket-7** classification — same cache.

Cache lifetime is session-scoped. The cache is a latency optimization; it never gates correctness.

**Cache-miss policy.** Query `gh issue view <N>` first; on `not found`, fall back to `gh pr view <N>`; on both failing, cache `"unresolvable"` (the consumer treats it as "not all closed" — i.e. don't auto-clear). `unresolvable` entries survive subsequent lookups — no retry burst per consumer.

### 0.9 `gh-cached.sh` wrapper (opt-in per call-site)

Within a single orchestrator session (typically 5–15 minutes), GitHub state doesn't change much except for the artifacts shipyard itself is modifying. But the orchestrator re-queries the same data across phases — `gh pr list` at the start of dispatch, again in drain, again in summary; `gh issue list` at backlog fetch and again on the lightweight backlog re-check before every dispatch. Most of those answers haven't changed. `plugins/shipyard/scripts/gh-cached.sh` is a session-scoped wrapper that caches stdout from a `gh` call keyed by its argv, with a caller-supplied TTL, so the redundant re-fetches return from disk instead of re-hitting the GitHub API. Closes [#160](https://github.com/mattsears18/shipyard/issues/160) — phase 3 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**Shape.** Run `gh` through the wrapper instead of calling `gh` directly:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 60 -- \
  gh-args-without-the-gh-prefix
```

The wrapper invokes `gh` itself (the argv after `--` is everything you'd normally pass to `gh`, minus the literal `gh`). Cache files live at `$SHIPYARD_HOME/cache/<session-id>/<sha256-of-argv>`. Cache hit → emits cached stdout, no network call, exit 0. Cache miss → invokes `gh`, streams stdout to disk + caller, exit mirrors `gh`. Non-zero `gh` exits are NOT cached (errors must retry naturally).

**TTL bands per query category.** Caller picks the TTL — no default, because the right freshness depends on the query:

| Query | Suggested TTL | Reasoning |
|---|---|---|
| `gh issue list --state open` (backlog universe) | **60s** | Backlog changes slowly; ephemeral edits to label/title don't change dispatch decisions |
| `gh pr list --state open` (in-flight check, drain snapshot) | **30s** | In-flight PRs change faster — new PRs, mergeStateStatus flips — but minutes of staleness still tolerable |
| `gh pr view <N> --json statusCheckRollup,mergeStateStatus` | **10s** | CI churns fast; the trust-but-verify spot-check and drain reconcile both depend on freshness |
| `gh label list` | **600s** | Labels change once per release |
| `gh api graphql` (batch status, status-rollup queries) | **10s** | Same churn class as per-PR view |
| `gh repo view --json defaultBranchRef` | **3600s** | Default branch rarely changes mid-session |
| `gh api repos/<owner/repo>/collaborators` | **3600s** | Trusted-author resolution is session-scoped already; this is belt-and-braces |

These are *suggestions*. A caller that needs harder freshness should pass a smaller TTL; a caller in a known-quiet section can pass a larger one. The wrapper is intentionally opt-in per call-site — the spec doesn't require every `gh` call to go through it. Use it for the high-volume queries the orchestrator re-runs across phases; leave one-shot queries (e.g. `gh issue view <N>` at scope pre-flight) to call `gh` directly.

**Invalidation on writes.** Whenever shipyard itself does a state-changing call (issue close, PR create, label add, assignee change), the relevant cached reads need to be flushed so subsequent reads see the new state. Two policies:

- **Conservative (default).** Flush the entire session cache after any state-changing call:
  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  "$CLAUDE_PLUGIN_ROOT/scripts/gh-cached.sh" invalidate --session-id "<session-id>"
  ```
  Burns one extra round of cold reads on the next refresh but never serves stale data after a write. Use this when in doubt — the cost is "one re-read per shipyard write," which is small compared to the savings on the hot read paths.
- **Targeted (advanced).** When the write affects a specific PR or issue and the caller knows which cached reads depend on that artifact, pass `--pattern <sha-prefix>` to invalidate just the matching entries. Practical use is rare — the `--pattern` surface is intentionally narrow because callers don't easily know the sha shape. Stick with the conservative policy unless profiling shows the broad flush dominates.

**End-of-session cleanup.** The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is reaped by the [End-of-session cleanup](../cleanup-summary.md#end-of-session-cleanup) sequence:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/gh-cached.sh" cleanup --session-id "<session-id>"
```

Idempotent. Runs in the same cleanup chain that reaps the session state file — both are session-scoped artifacts under `$SHIPYARD_HOME`.

**Disable for debugging.** `SHIPYARD_GH_CACHE_DISABLED=1` in the environment makes every `run` invocation a live `gh` call with no read or write — useful for confirming "is the cache hiding a real change?" without touching the call-sites. The `stats` subcommand still reads whatever's already on disk; `cleanup` and `invalidate` still operate on the existing dir.

**Observability.** `gh-cached.sh stats --session-id <id>` emits `{"hits": N, "misses": N, "invalidations": N, "bytes": N}` for the session — useful in end-of-session summary blocks and for the cost-tracking ledger when measuring perf wins against the baseline.

### 0.9.1 `gh-batch.sh` GraphQL wrapper (opt-in per call-site)

Where `gh-cached.sh` reduces redundant *re-fetches* across phases, `gh-batch.sh` reduces *fan-out*: N sequential `gh pr view <M>` / `gh issue view <N>` calls collapse to a single `gh api graphql` query with aliased per-record sub-queries. Closes [#159](https://github.com/mattsears18/shipyard/issues/159) — phase 2 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**When to reach for it.** Any call-site that fires `gh pr view <M>` or `gh issue view <N>` in a loop over a known list of numbers is a candidate. Highest-leverage sites today:

- **[Drain phase](../drain.md#drain-protocol) per-poll re-snapshot** — `D_dirty` / `R_new` / `P_settled` reconciles read per-PR fields for a known subset of session_prs every 60s. Use `pr-status` instead of N `gh pr view <M>` calls.
- **[Step 0.8 blocker_state cache](#08-blocker_state-cache-default-on)** — populated lazily today; when N+ entries are missed at once (bucket-6/-7 cold start), `issue-state` fills the cache in one round-trip instead of N.
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) referential-blocker resolution** — the `Blocked by #N` sweep already cache-reads, but cold starts on a large stale-block backlog benefit from batching the lookups via `issue-state` + a single `pr-status` fallback for cases where the referenced number is a PR.
- **Scope pre-flight scoping batches** — when N candidates' issue bodies need a fresh state check before dispatch.

**Shape.**

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Batch PR status — same projection as `gh pr view <M> --json
# number,state,mergeable,mergeStateStatus,statusCheckRollup,headRefName,headRefOid`
# but for N PRs in one query. Emits one JSON object keyed by PR number string.
"$CLAUDE_PLUGIN_ROOT/scripts/gh-batch.sh" pr-status \
  --repo <owner/repo> \
  --numbers "142 143 144"
# → {"142": {"number":142,"state":"OPEN","mergeable":"MERGEABLE",...}, "143": {...}, "144": {...}}

# Batch issue state + labels. Same shape — keyed by issue number string.
"$CLAUDE_PLUGIN_ROOT/scripts/gh-batch.sh" issue-state \
  --repo <owner/repo> \
  --numbers "100,200,300"
# → {"100": {"number":100,"state":"OPEN","labels":["P1","bug"]}, ...}
```

`--numbers` accepts space- or comma-separated integers. Non-numeric tokens fail loudly (exit 64) — defense in depth against any caller injecting unvalidated user input into the GraphQL body.

**Limits and behavior.**

- **Chunked at 50 aliases per query.** GraphQL has a soft node-cost limit; the wrapper auto-splits large `--numbers` lists into chunks and merges the JSON before emitting. Override via `SHIPYARD_GH_BATCH_CHUNK_SIZE`. Typical orchestrator fan-out (drain ≤10, blocker-state cache cold-start ≤20) fits in a single chunk.
- **Missing artifacts drop silently.** A PR / issue that no longer exists (deleted, transferred, never existed) resolves to a null alias and is dropped from the output — the caller treats a missing key as "not trackable." Never fail the whole batch on one missing number.
- **Failure fails the whole batch.** `gh api graphql` failure (rate limit, 5xx, malformed query) exits 2 with stderr forwarded. No partial output is emitted — callers retry the whole batch, not individual chunks.
- **`mergeable` may return UNKNOWN.** GitHub computes it on-demand; `mergeStateStatus` (`CLEAN` / `DIRTY` / `BLOCKED` / `BEHIND` / `UNSTABLE`) is the more stable signal. Prefer `mergeStateStatus` where possible.

**Composing with `gh-cached.sh`.** The two wrappers compose cleanly: run the batch helper through the cache wrapper to get both fan-in *and* cross-phase memoization. Suggested TTL bands:

| Batch query | Suggested TTL | Reasoning |
|---|---|---|
| `gh-batch.sh pr-status` | **10s** | Same churn class as per-PR `statusCheckRollup` (10s band in [§0.9](#09-gh-cachedsh-wrapper-opt-in-per-call-site)) |
| `gh-batch.sh issue-state` | **30s** | Issue state + labels change much slower than CI |

The compose pattern (cached batch read):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 10 -- \
  "$CLAUDE_PLUGIN_ROOT/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "142 143 144"
```

Cache hit → no GraphQL call. Cache miss → batched GraphQL call (1 round-trip for up to 50 numbers) cached for the next 10s.
