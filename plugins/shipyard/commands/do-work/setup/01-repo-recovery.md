# /shipyard:do-work — Setup phase · repo resolve + recovery + refine

**Setup sub-phase (cluster 2 of 5).** Owns steps 1 → 3.5: resolve repo + user, silent-direct-merge repo-shape detection, missing-`workflow`-scope preflight warning, session-state initialisation, orphan session-file + orphan orchestrator-worktree reaps, trusted-author allowlist resolution, backlog overview, label-ensure + prior-session recovery, and the refinement invocation. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md). Next: [`04-backlog-divert.md`](./04-backlog-divert.md).

### 1. Resolve repo + user

These three reads are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5, not serially before them.

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
gh api user -q .login                                  # the gh-authenticated user
gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name   # default branch (cached as <default-branch>)
```

Cache all three for the session.

(The trusted-author allowlist used by step 4's filter and step 7's `originating_author_trust` computation is populated separately by [step 1.7 below](#17-resolve-trusted-author-allowlist).)

### 1.3 Detect the silent-direct-merge repo shape (admin + ungated-merge config)

Closes issues [#438](https://github.com/mattsears18/shipyard/issues/438) and [#465](https://github.com/mattsears18/shipyard/issues/465). When the dispatching user has admin permissions, the worker's `gh pr merge --auto` can silently fall through to a **direct merge** instead of queuing (the `merged-direct` outcome documented in `shipyard:worker-preamble` § "Auto-merge + snapshot-and-return pattern" step 1.5 — fragment [`auto-merge.md`](../../../skills/worker-preamble/auto-merge.md) — and issue [#340](https://github.com/mattsears18/shipyard/issues/340)). At `--concurrency ≥ 2` that breaks version coordination in two compounding ways: (1) whichever PR direct-merges first advances `main`'s manifest version, so every concurrent PR with a lower-or-equal version goes DIRTY even when distinctly pre-assigned a version; (2) every merge changes the top-of-file CHANGELOG entry, re-DIRTYing even distinctly-versioned rebased PRs on the CHANGELOG insert point (the cascade the [drain CHANGELOG-serialization gate](../drain.md#drain-protocol) addresses).

This is a **warning, not a behavior change** — the orchestrator does not flip auto-merge config or add required checks on the repo (that's a maintainer decision). The *behavioral* gates that keep an ungated `--auto` from landing a PR before its CI live at the merge call sites themselves (see the [call-site table](#the-condition-lives-in-exactly-one-place) below); this step only surfaces the shape to the operator, because it also explains why C≥2 version coordination on this repo cannot hold without serialized merges.

**The condition lives in exactly one place.** Do **not** re-derive the two-shape rule here. It is one executable script — [`scripts/detect-ungated-admin-direct-merge.sh`](../../../scripts/detect-ungated-admin-direct-merge.sh) — which owns the whole rule (both shapes, the `#645` ruleset-aware fallback, the `#479` numeric normalize, and the fail-safe posture that an unreadable signal resolves toward *ungated*). This step calls it:

```bash
verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo> 2>/dev/null || echo ungated)
if [ "$verdict" = "ungated" ]; then
  echo "[setup] WARNING (#438/#465): \`gh pr merge --auto\` will SILENTLY DIRECT-MERGE on this repo (no queue) — you have admin/maintain and either allow_auto_merge=false (#438) or the default branch has zero required status checks (#465, fires even when allow_auto_merge=true). Shipyard's merge call sites gate on this automatically (#720): workers block on the PR's own checks, and the orchestrator-turn sites defer to drain's merge lander. But at --concurrency >= 2, version/CHANGELOG coordination across in-flight PRs still cannot hold: the first PR to merge advances main and re-DIRTYs siblings. Recommend --concurrency 1 here, or add a required status check (and/or enable allow_auto_merge) so --auto actually queues. version_coordination.serialize_drain_rebase (drain phase) mitigates the CHANGELOG cascade but not the steady-state leapfrog."
fi
```

**Why this step no longer inlines the detection ([#720](https://github.com/mattsears18/shipyard/issues/720)).** It used to carry its own ~55-line reimplementation of the rule — a *third* copy alongside the worker-preamble fragment and `issue-work.md`. That is precisely the drift hazard [#716](https://github.com/mattsears18/shipyard/issues/716) was filed for: the copies diverged, and whichever one a given code path happened to read decided whether the gate fired at all. #716 extracted the rule into the script; #720 finished the job by routing every remaining call site — including this one — through it. **A condition restated in prose (or re-implemented in bash) in N files will drift; a condition that is one command cannot.** If you find yourself about to write `allow_auto_merge` or `required_status_checks` into a spec file, stop and call the script instead.

The warning fires unconditionally of `--concurrency` (the steady-state leapfrog is worst at C≥2, but a C=1 operator who later raises concurrency benefits from having seen it once). The script's reads fold into the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) alongside step 1's reads — fire them in the same burst, not serially. The script fails safe on its own (any unreadable signal resolves toward `ungated`), so a transient read failure produces at worst an extra advisory line — never a hard failure on a diagnostic read.

**Clamp the effective concurrency on `ungated` — a committed config default cannot silently win over the detector ([#733](https://github.com/mattsears18/shipyard/issues/733)).** The warning above is advisory-only by design (§1.3's opening line), which leaves a gap: a repo can commit `concurrency.default: 2` in `shipyard.config.json` while its own merge shape is `ungated`, and nothing stops a session that omits `--concurrency` from reading that committed default and dispatching two workers straight into the steady-state leapfrog the warning describes. Resolve the session's effective concurrency here, immediately after the verdict, and clamp it when the shape is `ungated`:

```bash
# Effective concurrency = explicit --concurrency CLI value if the operator
# passed one, else this repo's committed concurrency.default (already loaded
# into $EFFECTIVE_CONFIG by step 0.4), else the built-in default of 1.
if [ -n "<--concurrency CLI value, if passed>" ]; then
  EFFECTIVE_CONCURRENCY="<--concurrency CLI value>"
else
  EFFECTIVE_CONCURRENCY=$(printf '%s' "$EFFECTIVE_CONFIG" | jq -r '.concurrency.default // 1' 2>/dev/null)
  [ -n "$EFFECTIVE_CONCURRENCY" ] && [ "$EFFECTIVE_CONCURRENCY" != "null" ] || EFFECTIVE_CONCURRENCY=1
fi

# The clamp only overrides a CONFIG-sourced value — an explicit CLI flag is
# the operator asking for it by hand and always wins, even on an ungated
# shape (they've seen the warning above; --concurrency is the override valve).
if [ "$verdict" = "ungated" ] && [ -z "<--concurrency CLI value, if passed>" ] && [ "$EFFECTIVE_CONCURRENCY" -gt 1 ] 2>/dev/null; then
  echo "[setup] concurrency clamped ${EFFECTIVE_CONCURRENCY} -> 1 (ungated merge shape)"
  EFFECTIVE_CONCURRENCY=1
fi
```

`EFFECTIVE_CONCURRENCY` is the value [step 1.5](#15-initialise-the-session-state-file) passes to `session-state.sh init --concurrency` — every downstream concurrency read (pool sizing, the parallel-vs-serial gates in [`00-config-worktree.md`'s C=1 index](00-config-worktree.md#lightweight-c1-path--whats-skipped-and-what-stays)) derives from that session-state value, so clamping here is sufficient; no other call site needs its own copy of this resolution. This clamp is deliberately narrow: it only downgrades a *config-sourced* default, never an explicit CLI flag, and it only fires on `ungated` — a `gated` repo's committed `concurrency.default: 2` (or higher) passes through unchanged, because on that shape `--auto` genuinely queues and the steady-state leapfrog this clamp exists to prevent cannot occur.

**Where the behavioral gates actually are.** Every `gh pr merge --auto` call site in shipyard now branches on this same script's verdict — the split is by whether the caller can afford to block:

| Call site | Runs on | On `ungated` |
|---|---|---|
| [issue-work §6.a](../../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) | worker's own slot | Block on `gh pr checks --watch`, merge only if green |
| [fix-main-ci step 7.a](../../../agents/issue-worker/fix-main-ci.md) | worker's own slot | Same — blocking wait |
| [fix-failing-prs-batch step 7.a](../../../agents/issue-worker/fix-failing-prs-batch.md) | worker's own slot | Same — blocking wait |
| [inline-trivial §E](../inline-trivial.md#e-arm-auto-merge) | orchestrator turn | Leave unarmed → [drain's merge lander](../drain.md#deferred-merge-lander-merge-unarmed-green-session-prs--720) |
| [A.0.5 crash recovery](../steady-state.md#a05-crash-return-detection--pre-reap-recovery) | orchestrator turn | Leave unarmed → drain's merge lander |
| [setup-3c orphan recovery](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) | orchestrator turn (setup) | Leave unarmed → drain's merge lander |
| [drain release-train](../drain.md#release-pr-auto-arming-and-deploy-watch-own-the-tail-phase-c--663) | orchestrator turn (drain poll) | Leave unarmed → drain's merge lander |

A **worker** can afford a multi-minute `--watch` — it owns a dispatch slot and blocks nobody. The **orchestrator** cannot: a block on its own turn stalls the dispatch loop, every in-flight reconcile, and every other PR. So the orchestrator-turn sites leave the PR open and unarmed, and drain's poll loop — which is already a queue — merges it the moment its checks go green.

### 1.35 Preflight-warn on missing `gh` `workflow` OAuth scope ([#818](https://github.com/mattsears18/shipyard/issues/818))

**Cheap, cached alongside the other repo-config preflight reads above (step 1.3).** GitHub blocks `enablePullRequestAutoMerge` for an OAuth-app token when the PR's diff touches `.github/workflows/*`, unless the token carries the `workflow` scope — `repo` alone is not enough. Issue [#812](https://github.com/mattsears18/shipyard/issues/812) (landed) teaches the **reactive** half of this problem: a worker discovers the gap at the first failed `gh pr merge --auto` call on a workflow-touching PR and reports the `auto-merge: unavailable — gh token lacks workflow scope` outcome, hoisted into a once-per-session end-of-session banner. This step is the **proactive** half — a one-time warning at session start, before the first workflow-touching PR is even opened, when the session shape suggests one is likely.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"

verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-missing-workflow-scope.sh" <owner/repo> <default-branch> 2>/dev/null || echo silent)
if [ "$verdict" = "warn" ]; then
  GH_TOKEN_SCOPES=$(gh auth status 2>&1 | grep -o "Token scopes: '[^']*'" | sed "s/Token scopes: //")
  cat <<EOF
warning: gh token is missing the \`workflow\` OAuth scope, and this session
looks likely to touch .github/workflows/ (an open issue/PR references it, or
main's most recent CI run failed).

  Current token scopes: ${GH_TOKEN_SCOPES:-<unreadable>}

  Any PR that modifies a workflow file will fail to arm auto-merge with
  "auto-merge: unavailable — gh token lacks workflow scope" (#812) until
  the scope is added. Fix once, for this and every future session:

    gh auth refresh -h github.com -s workflow

  This warning prints once per session. It will NOT repeat even if more
  workflow-touching work is discovered later.
EOF
fi
```

**The condition lives in exactly one place** — [`scripts/detect-missing-workflow-scope.sh`](../../../scripts/detect-missing-workflow-scope.sh) — same rationale as [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config)'s single-source-of-truth script: a two-signal condition restated as prose here would drift from the script the way `issue-work.md` and `auto-merge.md` drifted before [#716](https://github.com/mattsears18/shipyard/issues/716). The script's decision logic (`--decide <has_workflow_scope> <workflow_signal>`) is unit-testable without a live `gh`/network call.

**Silent by default — the common case.** The script short-circuits to `silent` the instant the token already carries `workflow` (no further reads spent), and also resolves to `silent` when the token lacks the scope but nothing in the session shape suggests workflow-touching work. No warning fires on either path — this is deliberate: the issue's acceptance criteria explicitly forbid adding noise to the common case. The two cheap signals that flip it to `warn` (both single API calls, only spent when the scope is actually missing): an open issue or PR referencing `.github/workflows/`, or the default branch's most recent workflow run having concluded `failure` (a proxy for "a fix-main-ci divert — which routinely edits workflow files — is likely this session"; the full `main_ci.status` aggregate computed later in [step 4.5a](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) is deliberately not re-derived here, since this is an advisory warning, not a dispatch decision). Any read failure inside the script resolves toward `silent` — fail toward not warning, matching step 1.3's fail-safe posture on its own diagnostic reads.

**One-time, not per-PR.** This step runs once during setup. It does NOT re-check later in the session (e.g. after a new workflow-touching issue enters the backlog) — the reactive #812 path is the backstop for anything this early heuristic misses, and repeating the warning per-PR would be exactly the noise #812 itself was filed to move away from.

**Never attempt to refresh, escalate, or modify the token's scopes.** This step only surfaces the remediation command for a human to run — it does not call `gh auth refresh` itself. Auth handling is left entirely to the operator.

### 1.5 Initialise the session state file

Stand up the durable JSON mirror (see [Session state file](../../do-work.md#session-state-file) and the full [schema + helper reference](../session-state-file.md)). One-shot setup write — every subsequent mutation routes through `session-state.sh update`.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# <session-id> is the orchestrator's session identifier — the same value
# step 0.5 used in the orchestrator-worktree path. Stable across the run.
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" init \
  --session-id "<session-id>" \
  --repo "<owner/repo>" \
  --concurrency "$EFFECTIVE_CONCURRENCY" \
  --soft-collision-concurrency <N from --soft-collision-concurrency arg>
```

`$EFFECTIVE_CONCURRENCY` is resolved (and, on an `ungated` merge shape, clamped) by [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) — don't re-read `--concurrency` or `concurrency.default` independently here, or the clamp becomes bypassable by whichever read happens second.

The file lands at `$SHIPYARD_HOME/sessions/<session-id>.json` (default: `~/.shipyard/sessions/<session-id>.json`). The default config above is the entire schema with empty queues + an `unknown` `main_ci` state — everything else gets filled in by later setup steps and the steady-state loop.

**If `init` returns exit code 2** ("file already exists"), call `init --force` to clobber the stale file. Log `[session-state] --force overrode stale state file from <prior session>`.

**If `init` returns 65+** (jq missing, permission denied, etc.), continue without the session-state file. The invariant line emits `state=disabled` to make the degradation visible. Don't block the session on file-write failure.

### 1.6 Reap orphan session files (cost-ledger recovery)

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. The canonical code lives in the background group above; this section documents the intent, race-safety rules, and skip condition. Do NOT duplicate the implementation here.

**Sweep `$SHIPYARD_HOME/sessions/` for orphan files left behind by prior sessions that crashed or exited without running [`cleanup-summary.md`'s step 7 → step 8 flush + cleanup chain](../cleanup-summary.md#end-of-session-cleanup).** Without this sweep, any session that doesn't terminate via the happy-path cleanup strands its per-session ledger on disk forever — the cross-session reports at `/shipyard:cost report` then under-count by full sessions. See [issue #227](https://github.com/mattsears18/shipyard/issues/227) for the regression where a multi-PR `lightwork` session's `$11.47` of tracked spend never landed in `~/.shipyard/cost-history.jsonl`.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Find session files that aren't the current session and haven't been
# modified in the last 30 minutes (the 30-min floor is a race-safety
# margin against a concurrent /do-work session that's about to flush its
# own file — we never reap something another orchestrator might still
# be writing to). Stacked with a PID-liveness check (`is-active`) for
# defense in depth — see issue #253 for the failure mode where the
# mtime floor alone was insufficient.
SESSIONS_DIR="${SHIPYARD_HOME:-$HOME/.shipyard}/sessions"
find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' -mmin +30 2>/dev/null | while read -r orphan; do
  orphan_id=$(basename "$orphan" .json)
  if [[ "$orphan_id" == "<session-id>" ]]; then
    continue  # skip our own session
  fi
  # PID-liveness gate (#253). is-active exits 0 when the session file's
  # `.pid` is alive (per `kill -0 $pid`); exit 1 otherwise (missing file,
  # missing/null pid, dead pid). If the owning process is alive, skip the
  # reap regardless of mtime — defends against the race where a quiet-but-
  # alive orchestrator's file would otherwise get reaped during a long
  # drain phase or CI watch (the failure trace in #253). PID recycling is
  # still possible but the mtime floor above is the second gate against
  # that — both have to fail to reap, so a recycled pid + fresh mtime
  # scenario still skips.
  if "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" is-active --session-id "$orphan_id" 2>/dev/null; then
    echo "[orphan-reap] skipped $orphan_id (pid alive)"
    continue
  fi
  # Flush is idempotent — re-flushing a session id already in the ledger
  # is a no-op. Cleanup is also idempotent.
  "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "$orphan_id" 2>/dev/null || true
  # --reap-audit (issue #281) records one JSONL line per reap to
  # ~/.shipyard/reap-audit.jsonl with the reaped session's metadata
  # (pid, repo, tokens, mtime) + the reaper's session-id / pid. Without
  # this line, a "where did my session file go?" investigation has no
  # forensic trail. Same JSONL file as worktree-reap.sh's audit log (#284).
  "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" cleanup --session-id "$orphan_id" \
    --reap-audit \
    --reaper-session-id "<session-id>" \
    --reason "orphan-sweep-step-1.6" \
    --phase "setup-1.6" 2>/dev/null || true
  echo "[orphan-reap] flushed + reaped $orphan_id"
done
```

Both helpers are idempotent and exit 0 on already-flushed / already-reaped sessions, so this sweep is safe to re-run. The 30-minute floor is the race-safety boundary against a concurrent `/do-work` orchestrator in another terminal that's about to flush its own file — we never reap something another orchestrator might still be writing to. (Concurrent orchestrators are uncommon but possible — multiple repos, multiple terminals; the floor is the cheap safe default.)

**Two gates, not one (issue #253).** The mtime floor alone failed in production when an orchestrator went quiet for >30 minutes during a long drain phase — the peer's sweep then reaped the still-active session's state file mid-write. The fix layers a PID-liveness gate (`session-state.sh is-active`) **before** the mtime check: if the owning process is alive, skip the reap regardless of mtime. The `.pid` field is stamped into the session file at `session-state.sh init` time (defaulting to `$PPID`, overridable via `--pid <N>`). `is-active` reads that field and runs `kill -0 $pid` to check liveness. Both gates have to fail before a file is reaped, so even a recycled-pid + recent-mtime scenario (the only known failure mode of `is-active`) still skips. Sessions written by older shipyard versions have no `.pid` field — `is-active` exits 1 in that case, falling through to mtime-only behaviour for the migration period.

**Cost-tracking degraded-recovery (issue #253's workaround, extended by #281).** Workers calling `session-state.sh bump-tokens` against a session whose file was reaped mid-session can pass `--allow-degraded-init` (with optional `--degraded-init-repo <r>`) to auto-recreate a fresh state file marked with `.degraded_recovery_at` rather than erroring exit-3. [Issue #281](https://github.com/mattsears18/shipyard/issues/281) extended the same flag to `session-state.sh update` — the orchestrator's working-memory mirror writes now survive a mid-session disappear without forcing a manual `init --force`. Data from before the disappear is lost (the file was gone), but every write from the disappear forward lands somewhere durable. Callers that want strict "must-have-pre-existing-file" semantics simply omit the flag — the original exit-3 behaviour is preserved by default so silent typos / wrong-session-id mistakes still surface.

**Reap-audit logging (issue #281).** When step 1.6 reaps a peer's session file, it now calls `cleanup --reap-audit --reaper-session-id <session-id>`, which captures the reaped file's metadata (pid, repo, tokens.totals, degraded_attribution_count, mtime, started_at, updated_at) and writes one JSONL line to `~/.shipyard/reap-audit.jsonl` with `action: "reaped-session-file"`. Same audit-log file as worktree-reap.sh emits (issue #284), so a reader can correlate session-file reaps with worktree reaps for the same session id. Without this, a "where did my session file go?" investigation has no forensic trail — just the symptomatic `exit 3` from a downstream write. The audit-log write is fire-and-forget — a permission error / disk-full / corrupt source JSON never aborts the reap (the reap itself is the load-bearing work; the audit line is observability).

**Don't block the session on sweep failures** — log `[orphan-reap] <reason>` and proceed. Recovery of historical data is observational; the dispatch loop's job comes first. If `SHIPYARD_KEEP_SESSIONS=1` is set (per the [step 8 cleanup-summary opt-out](../cleanup-summary.md#end-of-session-cleanup)), skip the sweep entirely — the user explicitly opted into keeping session files as permanent records.

### 1.6.5 Reap orphan orchestrator worktrees

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. The canonical code lives in the background group above; this section documents the intent, race-safety rules, and skip condition. Do NOT duplicate the implementation here.

**Sweep `.claude/worktrees/` for `orchestrator-<dead-session-id>/` directories left behind by prior sessions that crashed before reaching [`cleanup-summary.md`'s step 6 (orchestrator-worktree reap)](../cleanup-summary.md#end-of-session-cleanup).** Companion to [step 1.6](#16-reap-orphan-session-files-cost-ledger-recovery), which reaps orphan session *files*; this step reaps the *worktrees* themselves. Neither sweep was sufficient on its own:

- **Step 1.6** only deletes the session JSON from `$SHIPYARD_HOME/sessions/`. The worktree dir under the repo's `.claude/worktrees/` is untouched, so a dead session's worktree dir accumulates indefinitely.
- **Step 3b** only reaps `agent-*` worktrees (the per-dispatched-agent isolation worktrees). It scopes intentionally — `orchestrator-*` worktrees have different lock semantics and historically were retired by the owning session's own cleanup-summary step 6.

When a prior session crashed *between* step 7→8 (cost-history flush + session-file cleanup) and step 6 (orchestrator-worktree reap), the session file is gone but the worktree lingers. See [issue #280](https://github.com/mattsears18/shipyard/issues/280) for the production trace: a single-slot user's `git worktree list` accumulated multiple `orchestrator-dowork-*` detached-HEAD entries across crash-and-restart cycles, none of which any spec-defined step would ever reap.

The discovery uses [`worktree-reap.sh find-orphan-orchestrators`](../../../scripts/worktree-reap.sh), which applies the same liveness gate as step 1.6 — `is-active` exits 0 if the owning session's PID is alive, exit 1 otherwise (missing file, missing/null pid, dead pid). Both the worktree-sweep and the session-file-sweep treat "file missing" as inactive: the common case for the bug is that prior cleanup got far enough to flush + delete the session file but stopped short of reaping its own worktree.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# (Pseudocode — the canonical implementation lives in step 0.7's
# background group. This snippet illustrates the per-orphan action.)
while read -r orph_path; do
  orph_name=$(basename "$orph_path")
  orph_session_id="${orph_name#orchestrator-}"
  # Issue #284 — `worktree-reap.sh reap` handles BOTH the git-worktree-remove
  # attempt AND the rm -rf fallback internally, and emits the appropriate
  # action variant (`reaped-orphan-orchestrator` vs the `-raw-rm` suffix)
  # in a single audit-log line.
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped-orphan-orchestrator \
    --worktree-path "$orph_path" \
    --worktree-name "$orph_name" \
    --session-id "<session-id>" \
    --reaped-session-id "$orph_session_id" \
    --phase "setup-1.6.5"
done < <("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" find-orphan-orchestrators \
           --repo-root "$(git rev-parse --show-toplevel)" \
           --current-session-id "<session-id>")
git worktree prune
```

**Audit-log shape** — same `~/.shipyard/reap-audit.jsonl` as steps 3 / 3b, but with a distinct `action` value so the source is traceable. The helper emits these variants for us (issue #284 moved the JSONL writes into [`worktree-reap.sh reap`](../../../scripts/worktree-reap.sh) — see step 3b for the same pattern):

- `action: "reaped-orphan-orchestrator"` — successful `git worktree remove --force`.
- `action: "reaped-orphan-orchestrator-raw-rm"` — fallback when the worktree was unregistered with git (raw dir left after a crash); resolved via `rm -rf`. The helper chooses between these automatically; the caller passes the same `--action reaped-orphan-orchestrator` and the helper picks the right line based on which path actually succeeded.
- `action: "reaped-orphan-orchestrator-failed"` — emitted only when BOTH `git worktree remove` and `rm -rf` failed (the dir is somehow non-removable — permissions, mount issue). Surfaces the failure for traceability rather than swallowing it silently.
- Each line carries a `reaped_session_id` field (the embedded session id of the orphan) and `phase: "setup-1.6.5"` so a future debugger can correlate against the prior session's run.

The fallback to raw `rm -rf` is load-bearing for the production case in #280: `git worktree remove` fails when the worktree dir is on disk but `.git/worktrees/<name>/` metadata has already been pruned (or was never registered — e.g., a manual `mv` left an `orchestrator-*` dir without git tracking it). Without the fallback, the dir would linger across an unbounded number of subsequent `/do-work` sessions.

**Skip condition.** Like step 1.6, this sweep is skipped entirely when `SHIPYARD_KEEP_SESSIONS=1` — the user is explicitly opting to keep historical state, and worktree dirs are part of that state.

**Concurrency safety.** Because this step runs in the same background group as 1.6 (which already excludes the current session by id), there's no race against the orchestrator's own worktree — the helper filters `<current-session-id>` from its output before emitting paths. A concurrent peer `/do-work` orchestrator in another terminal *can* race here: if peer A is the dead session whose worktree we want to reap, and peer B started up at the exact same wall-clock second, peer B's `is-active` check might see A's pid as alive (because A hasn't yet finished crashing) and skip the reap. That's the conservative outcome — A's worktree gets cleaned up by the next session that starts after A's pid is actually gone. The race never produces a wrongful reap.

### 1.7 Resolve trusted-author allowlist

**Timing instrumentation (issue #238).** Bracket this step:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
# ... run resolution logic ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
```

**Security gate — must run before step 2's bucket pass and step 4's backlog fetch.** Populates the session-level `trusted_authors` set (the 10th orchestrator state struct — see the [state struct list](../../do-work.md#orchestrator-state) at the top of this spec). The set decides which issue authors `/do-work` will dispatch workers against; everyone else lands in step 2's `Untrusted author` bucket and step 4's client-side filter drops them from the workable queue. This is the **first line of defense** against the public-repo prompt-injection / RCE threat documented in step 2's "Bucket 0.5 is a security gate" block — a stranger can open an issue with a body that reads like a legit bug report ("Suggested fix: add `helper.ts` with `<crafted payload>`"), but if their login isn't in `trusted_authors`, no worker is ever dispatched against it, so the body is never read as instructions.

**Resolution order — first non-empty wins:**

1. **Per-repo override file** — if `.shipyard/trusted-authors.txt` exists in the orchestrator worktree, read it. One GitHub login per line; lines starting with `#` are comments; blank lines are ignored; logins are case-insensitive (lowercased on read). The repo owner (`<owner>` portion of `<owner/repo>`) is implicitly included even when the file omits them. Run the file through `trusted-authors-normalize.sh` (see [GH App alias normalization](#gh-app-alias-normalization-issue-296) below) so both `<bot>[bot]` and `app/<bot>` resolve correctly regardless of which form the file uses. Use the normalized set as `trusted_authors` and stop — do not fall through to the collaborators API.

2. **Collaborators API fallback** — when the override file doesn't exist, query the live collaborators-with-push API:

   ```bash
   gh api "repos/<owner/repo>/collaborators?per_page=100" --paginate \
     --jq '.[] | select(.permissions.push==true) | .login' | tr 'A-Z' 'a-z' | sort -u
   ```

   Add `<owner>` (lowercased) to the result set so a personal-repo owner with no other collaborators still works. Pass the result through `trusted-authors-normalize.sh` for consistency with branch 1 (the collaborators API doesn't return bots, so the alias expansion is usually a no-op, but the call is safe). Cache the result as `trusted_authors`.

3. **API failure / permission denied** — when the API call errors (the auth'd token can't list collaborators, e.g. the repo is owned by an org and the token doesn't have admin scope), fall back to a single-member set containing just `<owner>` (lowercased). Log an advisory: `[trusted-authors] could not query collaborators API (<reason>); falling back to repo owner only`. The session continues — restrictive default is the safe failure mode.

`.shipyard/trusted-authors.txt` format — one GitHub login per line; comments (`#`) and blank lines OK; case-insensitive; repo owner is implicitly trusted. Bot / GitHub-App accounts are NOT auto-trusted — the collaborators-API fallback excludes them, and maintainers must add them to the override file explicitly. Either login shape works: `sentry[bot]` (REST) OR `app/sentry` (GraphQL) — `trusted-authors-normalize.sh` cross-adds the alias, and the orchestrator's downstream `author.login` comparison matches either one (see [GH App alias normalization](#gh-app-alias-normalization-issue-296) below). Cache lifetime is session-scoped — resolve once at startup, never re-resolve mid-session. See [RATIONALE → Step 1.7](../../do-work-RATIONALE.md#step-17--why-a-per-repo-override-file-exists) for the policy discussion.

#### GH App alias normalization (issue #296)

GitHub returns **two different login shapes** for the same GH App account depending on which API the caller hits:

- **REST** (e.g. `/repos/.../issues/N/events`) returns the legacy-style login: `sentry[bot]`.
- **GraphQL Bot/App actor objects** (what `gh issue list --json author` and `gh issue view --json author` return) expose: `app/sentry`.

The two strings have nothing in common after lowercasing. Before [#296](https://github.com/mattsears18/shipyard/issues/296), a maintainer who put `sentry[bot]` in `.shipyard/trusted-authors.txt` would see every Sentry-filed issue silently bucketed as untrusted by step 2's bucket-0.5 filter and dropped by step 4's client-side filter, because the comparison value (the GraphQL `app/sentry` shape) never matched the file's REST-shaped entry. The setup-time advisory `[trusted-authors] loaded 2 author(s)` was misleading — the bot was "in the file" but not effectively trusted.

The fix is alias normalization at allowlist-load time. The helper `${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh` reads the cleaned set and, for every `<name>[bot]` or `app/<name>` entry, **adds the other shape** to the set. So a file with `sentry[bot]` produces `{sentry[bot], app/sentry}`; a file with `app/sentry` produces `{app/sentry, sentry[bot]}`. Either form matches the GraphQL `author.login` value the orchestrator compares against. Human logins (no `[bot]` suffix, no `app/` prefix) pass through unchanged.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Branch 1 (override file present) — read + normalize in one pipeline:
allowlist_file=".shipyard/trusted-authors.txt"
trusted_authors=$(
  {
    cat "$allowlist_file"
    printf '%s\n' "<owner>"   # repo owner is implicitly trusted
  } | "${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh"
)

# The advisory log SHOULD report which aliases were applied so the
# maintainer knows the normalization fired (issue #296 acceptance criterion):
"${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh" \
  --report-aliases "$allowlist_file" | while IFS= read -r line; do
  [ -z "$line" ] || echo "$line"
done
```

The helper is idempotent — running it on a set that already contains both forms produces the same set. The cross-alias is one-directional in the sense that the *content* is preserved (no shape is rewritten) — both shapes coexist after normalization.

The same normalization runs inside the GitHub Actions workflow that resolves the allowlist with the file-based pipeline (`.github/workflows/label-event-audit.yml`) — it inlines the alias-cross-add as a `sed` pipeline (workflows can't reach into the shipyard plugin's scripts dir from a consumer repo). (`.github/workflows/intake-refinement-gate.yml` previously inlined the same pipeline but was retired in [#520](https://github.com/mattsears18/shipyard/issues/520) when the refinement gate was eliminated.) The orchestrator-side helper and the workflow-side inlining are kept in sync by the `trusted-authors-normalize.test.sh` test suite plus a workflow-side smoke pattern (any change to the alias logic in one place must change it in both).

**Protect the override file with CODEOWNERS.** Because the file IS the security boundary, repos that adopt `/shipyard:do-work` should add a `.github/CODEOWNERS` rule naming the maintainer(s) for `.shipyard/trusted-authors.txt` and enable "Require review from Code Owners" in branch protection on the default branch — otherwise anyone with `write` access can extend the allowlist via a single PR with no maintainer in the loop. This repo's own [`.github/CODEOWNERS`](../../../../../.github/CODEOWNERS) is the reference example.

**Output.** A single advisory line goes into the session log right after resolution:

- `[trusted-authors] loaded <K> author(s) from .shipyard/trusted-authors.txt`, or
- `[trusted-authors] loaded <K> collaborator(s) from repos/<owner/repo>/collaborators API`, or
- `[trusted-authors] fallback to repo owner only — <reason for API failure>`.

The count `<K>` is the **post-normalization** size — it includes both the alias expansions from [GH App alias normalization](#gh-app-alias-normalization-issue-296) and the implicitly-trusted repo owner. The advisory is one line — not a block, not a list of logins — so the startup output stays scannable.

When any GH-App aliases were added (one or more `<bot>[bot]` ↔ `app/<bot>` cross-adds fired), emit one additional `[trusted-authors] alias: <input> -> <added>` line per alias on the line immediately following the main advisory. Sourced from `trusted-authors-normalize.sh --report-aliases` so the maintainer can verify which form was matched. Skip when no aliases were needed (the typical human-only repo case) — silence is the right default.

### 2. Backlog overview

> **`--fast` skip:** When `--fast` is set, skip the full universe fetch and the UI table. Instead, run three cheap counts for advisory reporting in the end-of-session `--fast was used` block:
>
> ```bash
> # These five run in parallel as part of the parallelization batch even under --fast.
> # Refinement-candidate count is by source-signal scan (no needs-refinement label since #520):
> # user-feedback label, OR an "## Open questions" heading, OR a bot author; minus issues already
> # in the human queue (needs-human-review / needs-triage).
> gh issue list --repo <owner/repo> --state open --limit 200 --json number,labels,body,author \
>   --jq '[ .[]
>           | select([.labels[].name] | any(. == "needs-human-review" or . == "needs-triage") | not)
>           | select((.labels | any(.name == "user-feedback"))
>                    or ((.body // "") | test("(?m)^## Open [qQ]uestions[[:space:]]*$"))
>                    or ((.author.type // "") == "Bot")) ] | length'
> gh pr list --repo <owner/repo> --state open --label blocked:ci --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent --json number --jq 'length'  # legacy (pre-#300, migrated by 3d.2 sub-sweep b)
> gh issue list --repo <owner/repo> --state open --label needs-design --json number --jq 'length'  # legacy pre-#515, migrated by 3d.2 sub-sweep d
> gh issue list --repo <owner/repo> --state open --label needs-decomposition --json number --jq 'length'  # legacy pre-#519, migrated by 3d.2 sub-sweep e
> gh issue list --repo <owner/repo> --state open --label tracking --json number --jq 'length'  # legacy pre-#519, migrated by 3d.2 sub-sweep e
> gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --json number --jq 'length'  # legacy pre-#521, migrated by 3d.2 sub-sweep f
> ```
>
> Save the counts as `fast_skip_needs_refinement` (refinement candidates deferred), `fast_skip_blocked_ci`, `fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`, `fast_skip_legacy_needs_design`, `fast_skip_legacy_needs_decomposition`, `fast_skip_legacy_tracking`, and `fast_skip_legacy_blocked_agent_hard`. Proceed immediately to step 3.

Before any other setup, fetch every open issue and print an upfront summary of what will be worked on, what will be skipped, and why. The user reads this once at the start of the session and uses it to (a) calibrate expectations for how many issues this run will close, and (b) start unblocking the blocked work in parallel while the orchestrator runs. The summary is **informational only** — print it, then continue with step 3. No confirmation needed.

Fetch the universe of open issues and the linked-PR subset. Both calls are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5:

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'

gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number \
  --search 'is:issue is:open linked:pr' \
  --jq '[.[].number]'
```

The `--jq` projection flattens `labels` / `assignees` to the only shapes the bucket routing consumes (label names, assignee logins) and preserves the canonical `author.login` shape so the bucket-0.5 untrusted-author check (`author.login NOT in trusted_authors`) reads identically. Body stays full because bucket 6 / bucket 7 parse `Blocked by #N` references out of it via regex. Worker-preamble §"`gh` JSON discipline" covers the convention.

Bucket each issue into exactly one category. Apply in order — first match wins so an issue lands in its most specific bucket:

| # | Bucket | Criteria |
|---|---|---|
| 0.5 | **Untrusted author** | `author.login` is NOT in `trusted_authors` (see [step 1.7](#17-resolve-trusted-author-allowlist)). **Applied first** — strangers' issues never reach the dispatch queue, even if otherwise unlabeled. |
| 1 | **Assigned to others** | `assignees` contains a user other than `@me` |
| 2 | **In flight** | issue number appears in the `linked:pr` set above |
| 3 | **Won't fix** | carries `wontfix` |
| 4 | **Discussion** | carries `discussion` |
| 5 | **Needs triage** | carries `needs-triage`. **Design-gated issues** (formerly `needs-design`) and **epic-decomposition handoffs** (formerly `needs-decomposition` / `tracking`) now carry `needs-human-review` and land in bucket 5.5 — [#515](https://github.com/mattsears18/shipyard/issues/515) folded `needs-design` into `needs-human-review`, and [#519](https://github.com/mattsears18/shipyard/issues/519) folded the `needs-decomposition` / `tracking` epic-decomposition pair into `needs-human-review` (the epic handoff is distinguished by the `<!-- do-work-needs-decomposition -->` body marker that [`/decompose-epic`](../../decompose-epic.md) consumes — see [#498](https://github.com/mattsears18/shipyard/issues/498) / [#501](https://github.com/mattsears18/shipyard/issues/501)). |
| 5.4 | **Awaiting refinement** | matches a refinement **source signal** and NOT `needs-human-review`/`needs-triage` — `user-feedback` label, OR an `## Open questions` heading, OR a bot author. No persisted `needs-refinement` label anymore ([#520](https://github.com/mattsears18/shipyard/issues/520)); `/refine-issues` recomputes candidacy live and branches by signal (user-feedback classify+rewrite, open-questions resolve-defaults, no-pattern fall-through). |
| 5.5 | **Awaiting human review** | carries `needs-human-review`. Subsumes the former `needs-design` design-gate ([#515](https://github.com/mattsears18/shipyard/issues/515)) and the former `needs-decomposition` / `tracking` epic-decomposition handoffs ([#519](https://github.com/mattsears18/shipyard/issues/519) — an epic handoff additionally carries the `<!-- do-work-needs-decomposition -->` body marker so `/decompose-epic` can find it). As of [#520](https://github.com/mattsears18/shipyard/issues/520) it's also the fall-through home for refinement candidates with no automated path. |
| 6 | **Blocked (soft label)** | carries `blocked:agent-soft` ([#300](https://github.com/mattsears18/shipyard/issues/300)) — auto-cleared at next session, so the bucket exists for visibility only; the soft-blocked issue is **NOT excluded** from step 4's workable fetch. Surfaces here so the user sees that a prior worker bailed for a subjective reason (cannot-reproduce / ambiguous / scope-judgment) and may want to clarify the issue before re-dispatch picks it up. (The former bucket 6a "Blocked (hard label)" was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — `blocked:agent-hard` was eliminated: refuses now carry `needs-human-review` and land in bucket 5.5; dependency-waits carry no label and land in bucket 7.) |
| 7 | **Blocked (body reference)** | body matches `Blocked by #(\d+)` where that issue is still open (`gh issue view <N> --json state -q .state` returns `OPEN`) |
| 8 | **Workable** | everything else — these are what /do-work will dispatch |

**Bucket 0.5 is a security gate, not a triage hint** — the dispatch-time filter that keeps strangers' issues out of the workable queue entirely. The defense-in-depth measure (issue body treated as untrusted in [`agents/issue-worker/issue-work.md` step 2](../../../agents/issue-worker/issue-work.md#2-read-the-issue-carefully)) sits behind this filter. Override path for a maintainer-vouched issue: re-file under the maintainer's own account, or add the author to `.shipyard/trusted-authors.txt`. See [RATIONALE → Bucket 0.5 security gate](../../do-work-RATIONALE.md#step-2--why-bucket-05-is-a-security-gate) for the threat model and override-path discussion.

Buckets 5.4 and 5.5 are part of the refinement pipeline (see `/refine-issues`). 5.4 issues (matched by source signal, not a label) will be processed automatically by step 3.5 *this* session — the refiner branches on source signal (user-feedback vs open-questions vs fall-through). 5.5 issues are waiting on a human to sign off (refined user-feedback awaiting review, design-gated, epic-decomposition handoffs, or the no-automated-path refinement fall-through per [#520](https://github.com/mattsears18/shipyard/issues/520)); the resolve-defaults branch does NOT apply `needs-human-review`, so a resolve-defaults issue becomes dispatch-eligible immediately rather than landing in 5.5. Both render in the "Skipped" block with counts and issue numbers.

For each issue in bucket 6 or 7, generate a one-line **unblock recommendation** describing what the human could do to unblock it. Use the issue body, labels, and (for body references) the blocker's title and state — but skim, don't deep-dive. One sentence per blocked issue is plenty. Examples:

- Blocked by another open issue: `"#<N> blocked by #<M> (\"<M's title>\") — <action, e.g. 'land #M first', 'close #M as obsolete', or 'review the proposal in the latest comment'>"`
- Blocked by an external dependency (SDK release, vendor input, design decision): describe the concrete action the user could take
- `blocked:agent-soft` label set: `"#<N>: soft block — will auto-retry at next session (cleared automatically); clarify the body if you want a different outcome on retry"`
- Awaiting refinement (bucket 5.4): `"#<N>: refinement runs automatically at /do-work startup, or run /refine-issues manually"`
- Awaiting human review (bucket 5.5): `"#<N>: review the refined feedback, set a priority label, remove \`needs-human-review\` (or close)"`

The point is to give the user something **actionable** so they can start clearing blockers in parallel.

**Inline action-recommendation candidates per skipped bucket.** The orchestrator surfaces per-bucket candidate counts under each Skipped-bucket so the "this bucket has N issues you could probably act on right now" signal is visible at the bucket itself. Apply only to buckets where a mechanical signal distinguishes "likely-actionable" from "genuinely stuck" residue. The orchestrator does NOT auto-act on these. See [RATIONALE → Inline action recommendations](../../do-work-RATIONALE.md#step-2--inline-action-recommendation-rationale) for the cost discussion.

Compute candidates for the following buckets:

- **Bucket 6 (soft label) does NOT compute candidates** — every soft-label issue is auto-cleared at next-session backlog fetch and is already counted as workable in step 4, so there's nothing the user could pre-empt. (The former bucket 6a `likely-clearable` candidate computation was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) along with the `blocked:agent-hard` label and the [step 3d.2 sub-sweep a](#3-ensure-label-exists--recover-from-prior-session) it pre-visualized — dependency-waits now live in bucket 7, gated purely by the open-blocker body reference.)

- **Bucket 5 (Needs triage / decomposition) — `likely-triageable` candidates.** Score each issue by the presence of mechanical triage signals in its labels and body:
  - `+1` if labels contain any of `P0` / `P1` / `P2` (priority already set).
  - `+1` if labels contain any of `bug` / `enhancement` / `fix` / `feat` (issue type already declared).
  - `+1` if body contains `## Acceptance` or `## Acceptance criteria` (criteria section present).
  - `+1` if body contains `## Repro` / `## Reproduction` / `## Steps to reproduce` (repro section present).
  - `+1` if labels do NOT contain `needs-human-review` (no co-gate beyond `needs-triage`; `needs-human-review` now subsumes the former `needs-design` design-gate per [#515](https://github.com/mattsears18/shipyard/issues/515)).

  Score `>= 3` → `likely-triageable` candidate. The recommendation is "review then remove `needs-triage`" — the orchestrator does NOT auto-remove the label. Score `< 3` → "genuinely fuzzy" residue; not a candidate.

Print the summary using **two-mode rendering**, picked by row count:

- **Two or more non-zero buckets** → fixed-width aligned text table (not markdown table; spaces-aligned columns, `─` U+2500 header divider).
- **Exactly one non-zero bucket** → single-line summary, no table.
- **Zero buckets total** → empty-backlog one-liner.

The full shape, **two-or-more-rows mode**:

```
/do-work backlog overview — <owner/repo>

By priority: P0=<n>  P1=<n>  P2=<n>  unlabeled=<n>
Top workable items: #<a>, #<b>, #<c>, ...

Bucket                                       Count   Issues
───────────────────────────────────────────  ─────   ──────────────────────────────────────────────
Workable (will be worked this session)           6   #<a>, #<b>, #<c>, +<K> more
⛔ Untrusted author                              2   #U → @stranger, #V → @stranger2
blocked:agent-soft label                         2   #S1, #S2 — auto-cleared at next-session backlog fetch (no exclusion)
Blocked (body reference)                         1   #D
needs-triage / decomposition                     2   #E, #F
  ⚠ likely-triageable                            1   #E — review then remove `needs-triage`
Awaiting refinement                              1   #R
Awaiting human review                            1   #H
Discussion                                       1   #G
Won't fix                                        1   #X
In flight (open PR)                              2   #I → PR #J, #K → PR #L
Assigned to others                               1   #M → @user

Total open: <W + S>  (workable: <W>, skipped: <S>)

Auto-cleared this session:
  blocked:agent-soft → workable: <cleared_blocked_soft> issue(s)  (#S1, #S2, ...)  (next-session sweep — no held bucket)
  legacy blocked:agent → needs-human-review: <migrated_legacy_review> issue(s)  (#L1, ...)  (no open Blocked-by ref)
  legacy blocked:agent → no label (dependency-wait): <migrated_legacy_dep> issue(s)  (#L2, ...)  (open Blocked-by ref; body-ref filter gates)
  legacy needs-design → needs-human-review: <migrated_needs_design> issue(s)  (#D1, ...)  (pre-#515 fold)
  legacy needs-decomposition/tracking → needs-human-review + decomposition marker: <migrated_needs_decomp> issue(s)  (#E1, ...)  (pre-#519 fold)
  legacy blocked:agent-hard → needs-human-review: <migrated_hard_review> issue(s)  (#F1, ...)  (no open Blocked-by ref)
  legacy blocked:agent-hard → no label (dependency-wait): <migrated_hard_dep> issue(s)  (#F2, ...)  (open Blocked-by ref; body-ref filter gates)

PR-side state:
  blocked:ci PRs: <c> total
    will be re-evaluated this session: <k>  (#J, #K, ...)
    held (no new commits since label applied): <h>  (#L, #M, ...)

Unblock recommendations (work these in parallel while /do-work runs):
  - #A: <recommendation>
  - #C: <recommendation>
  ...
```

**One-row mode** (the table is skipped; replace the bucket block with a single-line summary). When the lone bucket is `Workable`: `Workable: 6 issues (#90, #91, #92, #93, #94, #89). Nothing skipped.` When the lone bucket is a skip: `Workable: 0. Skipped: 2 issues in 'blocked:agent-soft' label (#S1, #S2).`

**Zero-row mode** (empty universe): replace everything below the header with `Backlog is empty — nothing to work on this session.`

**Bucket-table rules:**

- **Row count picks the mode.** Count non-zero buckets. `0` → empty-backlog one-liner. `1` → single-line summary. `≥2` → fixed-width aligned text table. The `Workable` row counts only when `<W> > 0`; action-recommendation sub-rows (`⚠ likely-clearable` / `⚠ likely-triageable`) don't count as their own bucket. See [RATIONALE → Bucket-table mode selection](../../do-work-RATIONALE.md#step-2--bucket-table-mode-selection-rationale).
- **Workable-row-always-prints is a table-mode rule, not a row-counting rule.** When the table renders (`≥2` non-zero buckets), the `Workable` row prints even with `<W> == 0`.
- **Column widths in two-or-more-rows mode.** Computed at print time:
  - **Bucket** column: width = max(label length across rendered rows), clamped to a minimum of 30 and a maximum of 60 characters. Sub-row labels include their 2-space indent in the length.
  - **Count** column: right-aligned, width = max(digit count across rows), clamped to a minimum of 5.
  - **Issues** column: width = max(content length across rendered rows), clamped to a minimum of 30 and a maximum of 80 characters. Content wider than the cap is NOT line-wrapped — the per-row truncation rule below handles overflow.
  - Column separator: **3 spaces** (visible gap without looking like a tab). Header divider: one `─` (U+2500) per character of the header label, separated by the same 3-space gaps.
- **Row order**: `Workable` first, then `Untrusted author` (security-relevant skip, surfaced near top), `Blocked (label)`, `Blocked (body reference)`, `Needs-triage/design`, `Awaiting refinement`, `Awaiting human review`, `Discussion`, `Won't fix`, `In flight`, `Assigned to others`.
- **Issues column content.** Comma-separated issue numbers (with arrow-targets like `#G → PR #H` or `#I → @user`). Truncate after **10 numbers** with `, +<K> more`.
- **`Total open` line** stays below the table; **`By priority` and `Top workable items`** stay above.

The **PR-side state** block prints whenever `<c> > 0`. Numbers come from `cleared_ciblocked` / `held_ciblocked` recorded by [step 3d.1](#3-ensure-label-exists--recover-from-prior-session).

The **Auto-cleared this session** block prints when `cleared_blocked_soft > 0` or `migrated_legacy > 0` (= `migrated_legacy_dep + migrated_legacy_review`) or any of the new legacy-migration counters `migrated_needs_design`, `migrated_needs_decomp`, `migrated_hard_review`, `migrated_hard_dep` is `> 0`. Numbers come from step 3d.2. Omit rows with a zero count. (The former `blocked:agent-hard` cleared/held counters were removed in [#521](https://github.com/mattsears18/shipyard/issues/521) with sub-sweep a; sub-sweeps d/e/f ([#537](https://github.com/mattsears18/shipyard/issues/537)) add migration lines for the #515/#519/#521 legacy labels.)

Edge cases:

- **`W == 0`** — print the summary anyway, then continue with setup. Step 4's filtered fetch will return empty and the loop will terminate cleanly.
- **No blocked issues** — omit the "Unblock recommendations" section entirely.
- **Priority labels not yet triaged** — the breakdown reflects current label state; step 4's auto-triage pass labels the unlabeled survivors before dispatch.
- **Buckets with zero count** — in table mode, omit those rows (except `Workable`, which always prints in table mode). Action-recommendation sub-rows with zero candidates are also omitted.
- **Very large backlogs** — per-row Issues column truncates after ~10 numbers with `, +<K> more`.
- **`likely-triageable` candidates are advisory only** — surfaced in the step-2 overview for visibility; the orchestrator does not auto-act on them. (The former `likely-clearable` candidate / step-3d.2-sub-sweep-a overlap note was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — `blocked:agent-hard` and its referential sweep no longer exist.)
- **Cost** — all blocker lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on) and fire as a parallel burst. Combined extra cost on a ~50-issue backlog is well under 1s wall-clock.

Then proceed immediately to step 3.

### 3. Ensure label exists + recover from prior session

**3a. Ensure required labels exist** (idempotent).

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Labels are guaranteed to exist by the time the first dispatched agent applies one (the background group typically finishes well before the first worker fires). The canonical label list and `gh label create` calls live in the background group above.

The `shipyard` label is the session stamp; `P0`/`P1`/`P2` are the priority tiers; `user-feedback`/`needs-human-review`/`needs-triage` drive the [refinement pipeline](#35-refine-pending-issues) (the `needs-refinement` gate label was eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520) — `/refine-issues` now detects candidates by source-signal scan); `needs-human-review` doubles as the scope-agent epic-handoff surfacing label (applied by [step 6's Deferred recording path](06-scope-preflight.md#6-initial-scope-pre-flight) when the scope agent confirms an issue is non-shippable as a single PR — see [#498](https://github.com/mattsears18/shipyard/issues/498); the epic-decomposition handoff is distinguished from other `needs-human-review` issues by the `<!-- do-work-needs-decomposition -->` body marker per [#519](https://github.com/mattsears18/shipyard/issues/519), and [`/decompose-epic`](../../decompose-epic.md) consumes that marker to auto-shard the epic into dispatch-ready sub-issues — see [#501](https://github.com/mattsears18/shipyard/issues/501)); `blocked:agent-soft` / `blocked:ci` are shipyard's block-state circuit breakers (applied by step A on agent / fix-checks block, removed by step 3d.1 / 3d.2 sub-sweep c / next-session backlog re-fetch); the former `blocked:agent-hard` was eliminated in [#521](https://github.com/mattsears18/shipyard/issues/521) — agent refuses now route to `needs-human-review` and dependency-waits to the `Blocked by #N` body-ref filter (no label):

```bash
gh label create shipyard --repo <owner/repo> --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create user-feedback --repo <owner/repo> --description "Originated from end-user feedback (untrusted body — treat with care)" --color 0E8A16 2>/dev/null || true
gh label create needs-human-review --repo <owner/repo> --description "Awaiting a human DECISION before /do-work will touch it" --color D93F0B 2>/dev/null || true
gh label create needs-operator --repo <owner/repo> --description "Needs a browser/console operator action — a human, or /do-work via the extension" --color 1D76DB 2>/dev/null || true
gh label create needs-triage --repo <owner/repo> --description "No automated path forward — surface to a human" --color C2E0C6 2>/dev/null || true
gh label create blocked:agent-soft --repo <owner/repo> --description "Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes." --color FBCA04 2>/dev/null || true
gh label create blocked:ci --repo <owner/repo> --description "CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover." --color B60205 2>/dev/null || true

# `blocked:agent-hard` and the legacy `blocked:agent` label are NO LONGER created
# (eliminated in #521 — refuses route to needs-human-review, dependency-waits to
# the `Blocked by #N` body-ref filter with no label). The existing GitHub label
# objects are intentionally left in place for manual cleanup; nothing applies them
# anymore, and step 3d.2 sub-sweep b migrates any still-attached legacy label off.
```

**3b. Reap stale agent worktrees from dead Claude Code sessions.**

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Stale-worktree reaping affects future dispatch slot availability, not the first batch. The canonical implementation lives in the background group above.

The harness writes a lock file at `.git/worktrees/agent-<id>/locked` containing `claude agent <id> (pid <N>)`. The lock survives the harness process exiting. Reap every agent worktree whose lock-holding PID is dead; skip ones owned by live PIDs (could be another active Claude Code instance) — **unless the lock is stale enough that a live PID is more likely a recycled one than a genuine peer** (issue [#755](https://github.com/mattsears18/shipyard/issues/755); see [`worktree-reap.sh`'s `classify-lock` docstring](../../../scripts/worktree-reap.sh) for the full rationale). `classify-lock` applies this staleness corroboration itself — no separate check is needed here.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
reaped_stale=0
deferred_stale=0
# Issue #712 — worktrees the sweep TRIED to reap but couldn't. Silent-degrade
# (the old `|| true` posture) is what let them accumulate unnoticed.
unreaped_stale=0
# Declare our orchestrator PID so classify-lock can short-circuit reliably
# (issue #263). The harness writes our PID into every agent lock file;
# without an explicit declaration, classify-lock's ancestor walk can fail
# to find it whenever an intermediate harness layer returns empty PPID.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)
# Use `find` instead of a bare `agent-*` glob so the loop survives zsh's
# default `nomatch` option when no agent worktrees exist
# ([#335](https://github.com/mattsears18/shipyard/issues/335)). Bare globs
# raise a fatal error under zsh; `find` exits 0 on no matches and the
# loop body simply doesn't iterate.
for wt_dir in $(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null); do
  [ -d "$wt_dir" ] || continue
  name=$(basename "$wt_dir")
  worktree_path=$(git worktree list --porcelain | awk -v n="$name" '/^worktree /{p=$2} /^branch /{b=$2} /^$/{if (p ~ n) print p}' | head -1)
  [ -z "$worktree_path" ] && worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
  [ -z "$worktree_path" ] && continue

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
    classify-lock "$wt_dir/locked")

  if [ "$classification" = "peer-alive" ]; then
    # Lock-holding PID is alive, not in our ancestor chain, AND the lock
    # is fresh enough (within `classify-lock`'s staleness floor, default
    # 60 min) that a genuine peer is plausible. Defer.
    deferred_stale=$((deferred_stale + 1))
    continue
  fi

  # no-lock / dead / self-ancestor / peer-alive-stale — safe to reap.
  # (`self-ancestor` is rare at startup since by definition we just
  # launched, but covers the PID-recycling edge case where a stale lock
  # happens to name our PID. `peer-alive-stale` (#755) is the second-gate
  # override: the lock-holding PID is alive but the lock file's mtime is
  # past the staleness floor, so a genuine peer is implausible and the
  # more likely explanation is a dead prior-session PID the OS has since
  # recycled onto an unrelated live process — the exact failure mode that
  # left prior-session `agent-*` worktrees deferred indefinitely and
  # forced manual `git worktree unlock` + move-aside + `prune`
  # intervention every session before this gate existed.)
  git worktree unlock "$worktree_path" 2>/dev/null
  # Issue #712 — route the remove through `worktree-reap.sh reap`, which
  # escalates plain `git worktree remove` → evidence-gated `--force` and emits a
  # `reaped-failed` audit line (never a silent `reaped`) when the removal did
  # not actually happen. A bare `git worktree remove --force` here is denied
  # outright by Claude Code's auto-mode permission classifier
  # ("[Irreversible Local Destruction]"), and because the call was fire-and-
  # forget the denial was invisible — which is how stale worktrees accumulated
  # to six unnoticed in the #712 repro. Count `reaped_stale` from the verified
  # end state (path gone), not from the call's exit status.
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "$name" \
    --session-id "<session-id>" \
    --classification "$classification" \
    --phase "setup-3b-recovery" 2>/dev/null || true
  if [ ! -e "$worktree_path" ]; then
    reaped_stale=$((reaped_stale + 1))
  else
    unreaped_stale=$((unreaped_stale + 1))
  fi
done
git worktree prune
```

Record `reaped_stale`, `unreaped_stale`, and `deferred_stale` — all three surface in the end-of-session summary. A non-zero `unreaped_stale` means a reap was refused (auto-mode permission classifier, a dirty worktree carrying unpushed commits, or a filesystem error); the summary pairs the count with the `/clean_gone` remediation rather than degrading silently ([#712](https://github.com/mattsears18/shipyard/issues/712)).

**3c. Orphan worktree triage** — scan for `do-work/*` branches whose worktrees survived step 3b (legitimate orphans from THIS session, not dead-process leftovers).

> **Background step.** Both the discovery query and the handling (push / PR-create for orphans with commits) run inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch). Neither gates dispatch decisions. The discovery query is cheap; the expensive push/PR-create branch only fires when orphans exist. The canonical implementation lives in the background group above; this section documents the decision table and `salvaged_count` / `abandoned_count` / `stale_assigns_count` tracking semantics.

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR), `abandoned_count` (worktrees removed), and `stale_assigns_count` (issues whose `@me` self-assign was cleared by the fifth row's no-worktree-no-PR-no-branch sweep) — all three default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 4). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '[.statusCheckRollup \| group_by(.name) \| map(sort_by(.completedAt // .startedAt // "") \| last) \| .[] \| select((.conclusion // .status // "") \| test("FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED"))] \| length'`. If count > 0 → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. Latest-per-name projection per issue [#333](https://github.com/mattsears18/shipyard/issues/333) — a naïve `.statusCheckRollup[]` walk would false-positive on stale superseded FAILUREs. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |
| **Self-assigned with no worktree, no PR, no branch on origin** (issue [#303](https://github.com/mattsears18/shipyard/issues/303)) | After the worktree loop above, run `gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number` and for each result confirm `[ ! -d <repo-root>/.claude/worktrees/agent-* ]` doesn't claim it (no worktree-on-disk this loop already touched) AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `gh issue edit <N> --repo <owner/repo> --remove-assignee @me` (leave the `shipyard` label as provenance — it's not load-bearing for re-dispatch). `stale_assigns_count++`. Next dispatch retries from scratch. |

The fifth row closes a gap [#303](https://github.com/mattsears18/shipyard/issues/303) opened: prior sessions sometimes leave the `@me` self-assign on an issue after their on-disk worktree has been cleaned up (returned `blocked`, errored before first commit, etc.). The first four rows only see issues whose worktree is still present — so this state survives unbounded across sessions, with the issue silently failing the worker-side step-0 pre-flight ("assignee is `@me`, not someone else, so don't bail") and getting re-dispatched against stale prior-session artifacts.

The row's action is intentionally conservative: clear the assignment only, leave the `shipyard` label (provenance — it tells the next session this issue went through `/do-work` before), let the normal step-4 backlog fetch pick the issue back up, and let the orchestrator's normal dispatch path arrange a fresh worktree. Don't touch the issue body, don't post a comment, don't close — the issue may genuinely still be workable and the prior session's `blocked` may have been transient.

**3d.1. Auto-clear stale `blocked:ci` labels.** The label is sticky on purpose, but a new commit on the PR's head branch means the premise ("no movement since shipyard gave up") is no longer true. Auto-clear those PRs so they flow back into step 5's failing-PR snapshot for another 3 attempts. This sweep is the *only* place `blocked:ci` is removed by the orchestrator (step A applies; 3d.1 removes; no other step touches it).

> **`--fast` skip:** When `--fast` is set, skip this entire sweep. The initial `blocked:ci` count (`fast_skip_blocked_ci`) captured in step 2's `--fast` note is sufficient for the advisory summary — stale `blocked:ci` labels persist until the next normal session. Set `cleared_ciblocked=0` and `held_ciblocked=0`.

Fire the initial PR list as part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-PR `events` + `commits` lookups are a second-tier parallel batch. The serial loop below is shown for readability:

```bash
# All open PRs currently carrying blocked:ci, regardless of author. Foreign authors
# matter here too — the sweep is about the label's premise, not who owns the PR.
gh pr list --repo <owner/repo> --state open --label blocked:ci --limit 200 \
  --json number,headRefOid,headRefName \
  > /tmp/do-work-ciblocked-prs.json

cleared_ciblocked=0
held_ciblocked=0
declare -a cleared_pr_numbers
declare -a held_pr_numbers

for pr in $(jq -r '.[].number' /tmp/do-work-ciblocked-prs.json); do
  head_oid=$(jq -r --argjson n "$pr" '.[] | select(.number == $n) | .headRefOid' /tmp/do-work-ciblocked-prs.json)

  # Newest `labeled` event for blocked:ci on this PR (shipyard, a bot, or a human — doesn't matter who).
  # We're comparing "when was this label applied" against "when was the last commit on the head branch."
  label_ts=$(gh api "repos/<owner/repo>/issues/$pr/events" --paginate \
    --jq '[.[] | select(.event == "labeled" and .label.name == "blocked:ci")] | sort_by(.created_at) | last | .created_at')

  # When was the head commit authored?
  commit_ts=$(gh api "repos/<owner/repo>/commits/$head_oid" --jq '.commit.committer.date')

  if [ -z "$label_ts" ] || [ -z "$commit_ts" ]; then
    # Can't compute — leave the label alone, log advisory.
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
    continue
  fi

  # Compare ISO-8601 timestamps lexicographically (UTC-Z form sorts correctly).
  if [[ "$commit_ts" > "$label_ts" ]]; then
    gh pr edit "$pr" --repo <owner/repo> --remove-label blocked:ci
    cleared_ciblocked=$((cleared_ciblocked + 1))
    cleared_pr_numbers+=("$pr")
  else
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
  fi
done
```

Record `cleared_ciblocked` and `held_ciblocked` (plus the matching PR-number arrays). Cleared PRs flow into step 5's failing-PR snapshot naturally.

**Regression guard.** The `commit_ts > label_ts` comparison enforces "auto-clear fires only when a new commit has landed since the label was applied." If the comparison can't be computed (head branch deleted, events aged out of the ~90-day pagination window, network blip), hold — the safe default is to preserve the block. See [RATIONALE → Step 3d sweeps](../../do-work-RATIONALE.md#step-3d--why-the-blockedci--blockedagent-hard-sweeps-have-different-shapes).

**3d.2. Migrate legacy labels + sweep `blocked:agent-soft`.** Five sub-sweeps running in sequence, all before step 4's backlog fetch. Closes [#521](https://github.com/mattsears18/shipyard/issues/521) — the former **sub-sweep a** (the `blocked:agent-hard` referential clear) is **deleted**: refuses no longer carry a block label (they carry `needs-human-review`, never auto-cleared by a sweep — a human clears it), and dependency-waits carry no label at all (the [`Blocked by #N` body-reference filter](04-backlog-divert.md#4-fetch--rank-the-backlog) in step 4 gates them and auto-clears the instant the blocker closes, so the label-plus-sweep was pure redundancy — see [steady-state.md's bail handler](../steady-state.md#a1-parse-the-return-string)). The companion [step A.5 mid-session referential sweep](../steady-state.md#a5-removed--521) is removed for the same reason. Sub-sweep b (legacy migration) is **re-pointed** to the #521 routing; sub-sweep c (`blocked:agent-soft`) is unchanged. Sub-sweeps d/e/f ([#537](https://github.com/mattsears18/shipyard/issues/537)) migrate the remaining legacy gate labels left over from the [#515](https://github.com/mattsears18/shipyard/issues/515)/[#519](https://github.com/mattsears18/shipyard/issues/519)/[#521](https://github.com/mattsears18/shipyard/issues/521) folds: `needs-design` → `needs-human-review`; `needs-decomposition`/`tracking` → `needs-human-review` + `<!-- do-work-needs-decomposition -->` marker comment; `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. All three sweeps are idempotent one-shot-per-issue (the old label is removed, so a second pass finds nothing to migrate).

> **`--fast` skip:** When `--fast` is set, skip all five sub-sweeps. The initial label counts (`fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`, `fast_skip_legacy_needs_design`, `fast_skip_legacy_needs_decomposition`, `fast_skip_legacy_tracking`, `fast_skip_legacy_blocked_agent_hard`) captured in step 2's `--fast` note are sufficient for the advisory summary — stale labels persist until the next normal session. Set every `cleared_*`, `migrated_*`, and `held_*` counter to 0.

Fire the initial issue lists (one per label) in the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-issue blocker lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). Serial loop shown for readability.

**Sub-sweep b — legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521)).** Pre-#300 sessions stamped a single `blocked:agent` label; #521 eliminated the `blocked:agent-hard` target that sub-sweep b previously migrated to. Re-point it by the same discriminator the bail handler uses — **presence of an open `Blocked by #N` reference**: a legacy issue with an open `Blocked by #N` is a dependency-wait → just **remove** the legacy label and let the body-ref filter gate it (no replacement label); otherwise it's an unclassifiable legacy refuse → **`needs-human-review`** (a human must look). The legacy label is removed in both branches.

```bash
# All open issues carrying the bare `blocked:agent` label (but NOT also
# blocked:agent-soft — that's already classified). Cheap: at most one extra
# gh call this session.
gh issue list --repo <owner/repo> --state open --label blocked:agent --limit 200 \
  --json number,body,labels \
  --jq '[.[] | select((.labels[].name | IN("blocked:agent-soft")) | not) | {number, body}]' \
  > /tmp/do-work-blocked-legacy-issues.json

migrated_legacy_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_legacy_review=0   # → needs-human-review (unclassifiable legacy refuse)
declare -a migrated_legacy_dep_numbers
declare -a migrated_legacy_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-legacy-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-blocked-legacy-issues.json)

  # Same `Blocked by #N` extraction the bail handler uses. Any reference to a
  # still-OPEN issue ⇒ dependency-wait; reads through the blocker_state cache.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch
    # and auto-clears when the referenced blocker closes. No replacement label.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent\` per [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_legacy_dep=$((migrated_legacy_dep + 1))
    migrated_legacy_dep_numbers+=("$n")
  else
    # Unclassifiable legacy refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent\` → \`needs-human-review\` per [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_legacy_review=$((migrated_legacy_review + 1))
    migrated_legacy_review_numbers+=("$n")
  fi
done
```

The migration runs **once per legacy issue** — after the first run there are no more bare-`blocked:agent`-labeled issues. The label itself stays registered (the `gh label create` at the top of step 3d still fires for it) so a future audit can confirm zero open issues carry it before deletion. Eventually (after a few sessions with zero legacy hits) the label can be deleted via `gh label delete blocked:agent`. (`migrated_legacy = migrated_legacy_dep + migrated_legacy_review` for the advisory summary.)

**Sub-sweep c — `blocked:agent-soft` next-session sweep.** Subjective bails from prior sessions (`cannot reproduce`, `ambiguous`, `suggested fix exceeds expected scope`, `PR already open for this issue`) are auto-cleared at next-session backlog fetch — this is the **whole point** of the soft/hard split. There's no `Blocked by #N` referential check: the label by itself is the signal that "a prior worker bailed for a subjective reason that may not hold this session." Just remove the label and let step 4 pick the issue up naturally.

```bash
# All open issues currently carrying the `blocked:agent-soft` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --limit 200 \
  --json number \
  > /tmp/do-work-blocked-soft-issues.json

cleared_blocked_soft=0
declare -a cleared_blocked_soft_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-soft-issues.json); do
  gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-soft 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Auto-cleared \`blocked:agent-soft\` at next-session backlog fetch — subjective bails (cannot-reproduce / ambiguous / scope-judgment) do not persist across sessions. If the underlying ambiguity is still unresolved, a fresh worker dispatch this session may re-stamp the label." 2>/dev/null || true
  cleared_blocked_soft=$((cleared_blocked_soft + 1))
  cleared_blocked_soft_numbers+=("$n")
done
```

No "held" bucket for soft labels — every soft-labeled issue is cleared at the start of every session. The re-stamping risk (worker bails for the same reason → soft label re-applied this session) is intentional: subjective bails get exactly one re-dispatch per session, and the in-session re-dispatch gate (orchestrator's `session_blocked_soft` map per [steady-state.md A.1](../steady-state.md#a1-parse-the-return-string)) prevents tight retry loops within the same session. The cost of clearing-then-immediately-re-stamping is one extra `gh issue edit` per issue per session — cheap relative to the cost of permanently hiding workable issues.

**Sub-sweep d — legacy `needs-design` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#515](https://github.com/mattsears18/shipyard/issues/515) folded `needs-design` into `needs-human-review`. Consumer repos still carrying pre-fold issues with `needs-design` would otherwise pass the step-4 dispatch filter (which only excludes `needs-human-review`, not the former `needs-design`). Simple one-to-one rename: add `needs-human-review`, remove `needs-design`, post one comment. The migration is idempotent — after the first pass no issues carry `needs-design`, so subsequent sessions iterate over an empty list in O(0).

```bash
# All open issues carrying the legacy `needs-design` label.
gh issue list --repo <owner/repo> --state open --label needs-design --limit 200 \
  --json number \
  > /tmp/do-work-legacy-needs-design.json

migrated_needs_design=0
declare -a migrated_needs_design_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-design.json); do
  # Add the current label first so the issue is never unlabelled mid-transition.
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-design 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`needs-design\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The \`needs-design\` label was folded into \`needs-human-review\` in [#515](https://github.com/mattsears18/shipyard/issues/515) — \`/do-work\` now excludes \`needs-human-review\` issues from dispatch, so this issue remains gated until a human reviews and removes the label." 2>/dev/null || true
  migrated_needs_design=$((migrated_needs_design + 1))
  migrated_needs_design_numbers+=("$n")
done
```

**Sub-sweep e — legacy `needs-decomposition` / `tracking` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#519](https://github.com/mattsears18/shipyard/issues/519) folded the epic-decomposition pair into `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker. Issues still carrying the pre-fold labels would otherwise pass the step-4 filter. For each legacy epic issue: add `needs-human-review`, remove the legacy label, AND post a comment containing the `<!-- do-work-needs-decomposition -->` marker (the discriminator `/decompose-epic` uses to identify epic handoffs in the broader `needs-human-review` pool). The migration is idempotent — the legacy labels are removed on the first pass.

```bash
# Collect all open issues carrying needs-decomposition OR tracking (but NOT already
# needs-human-review — already migrated by a prior pass or manually).
gh issue list --repo <owner/repo> --state open --label needs-decomposition --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  > /tmp/do-work-legacy-needs-decomp.json

gh issue list --repo <owner/repo> --state open --label tracking --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  >> /tmp/do-work-legacy-needs-decomp.json

# Deduplicate (an issue could carry both labels) and process each once.
migrated_needs_decomp=0
declare -a migrated_needs_decomp_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-decomp.json | sort -un); do
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  # Remove whichever legacy labels the issue carries (one or both).
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-decomposition 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label tracking 2>/dev/null || true
  # Post the marker comment. /decompose-epic keys off <!-- do-work-needs-decomposition -->
  # to distinguish epic handoffs from other needs-human-review issues.
  gh issue comment "$n" --repo <owner/repo> --body "<!-- do-work-needs-decomposition -->
Migrated legacy \`needs-decomposition\`/\`tracking\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The epic-decomposition pair was folded into \`needs-human-review\` + the \`<!-- do-work-needs-decomposition -->\` marker in [#519](https://github.com/mattsears18/shipyard/issues/519). The marker above lets \`/decompose-epic\` find this issue among the broader \`needs-human-review\` pool and auto-shard it into dispatch-ready sub-issues." 2>/dev/null || true
  migrated_needs_decomp=$((migrated_needs_decomp + 1))
  migrated_needs_decomp_numbers+=("$n")
done
```

**Sub-sweep f — legacy `blocked:agent-hard` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#521](https://github.com/mattsears18/shipyard/issues/521) eliminated `blocked:agent-hard`, splitting it into refuses (`needs-human-review`) and dependency-waits (no label, body-ref filter gates). Pre-#521 sessions still carry `blocked:agent-hard` on open issues. Uses the same discriminator as sub-sweep b — presence of an open `Blocked by #N` reference — to route each legacy issue. Reads through the `blocker_state` cache.

```bash
# All open issues carrying the legacy `blocked:agent-hard` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --limit 200 \
  --json number,body,labels \
  --jq '[.[] | {number, body}]' \
  > /tmp/do-work-legacy-hard-issues.json

migrated_hard_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_hard_review=0   # → needs-human-review (unclassifiable refuse)
declare -a migrated_hard_dep_numbers
declare -a migrated_hard_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-hard-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-legacy-hard-issues.json)

  # Same `Blocked by #N` extraction as sub-sweep b.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent-hard\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_hard_dep=$((migrated_hard_dep + 1))
    migrated_hard_dep_numbers+=("$n")
  else
    # Refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent-hard\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_hard_review=$((migrated_hard_review + 1))
    migrated_hard_review_numbers+=("$n")
  fi
done
```

The sub-f migration runs **once per legacy issue** — after the first pass there are no more `blocked:agent-hard`-labeled issues. The label object is left registered (same rationale as `blocked:agent` in sub-sweep b) so a future audit can confirm zero open issues carry it before deletion.

**Order matters.** Sub-sweeps b → c → d → e → f run in sequence (sub-sweep a was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521)). c runs after b so the soft sweep operates on the post-migration label set — a legacy `blocked:agent` issue migrated to `blocked:agent-soft` by a maintainer mid-window is swept by c on the same pass. d/e/f run after c and operate on the post-b-migration state so no issue is processed by two sweeps in the same pass (the old label is always removed before the loop ends, making each sweep idempotent and one-shot-per-issue).

### 3.5 Refine pending issues

> **`--fast` skip:** When `--fast` is set, skip this entire step. Issues matching a refinement source signal remain unrefined this session; they will be processed by the next normal `/do-work` invocation. The `fast_skip_needs_refinement` count captured in step 2's `--fast` note surfaces in the end-of-session advisory block so the user knows how many refinement tasks were deferred. Proceed immediately to step 4.

**Timing instrumentation (issue #238).** Bracket this step even when it runs with no refinement-candidate issues — the wall clock still measures the `/refine-issues` invocation overhead:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
# /refine-issues --repo <owner/repo> --concurrency <N>
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
```

When `--fast` causes this step to be **skipped entirely**, call only the `start` + `end` pair with a near-zero elapsed (both calls back-to-back), so the ledger contains a `0.0s` entry for the phase rather than a missing key. This makes cross-session aggregation consistent — the report can always average `step_3_5_refine_issues` without handling absent keys for `--fast` sessions separately.

Invoke `/refine-issues` and **wait for it to complete** before proceeding to step 4. This scans every open issue for a refinement source signal — there is no persisted `needs-refinement` gate label (eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)); candidacy is recomputed live — and branches per-issue on source signal:

- **classify+rewrite branch** (`user-feedback` label present): classify as already-done / declined / legitimate, preserve original text in a comment, rewrite the body into the repo's issue template. Legitimate items get `needs-human-review` co-applied.
- **resolve-defaults branch** (no `user-feedback`, body has `## Open questions`): commit reasonable defaults for each question, rewrite body removing the section. Does NOT apply `needs-human-review` — trusted-author issues become dispatch-eligible in the same session.
- **fall-through branch** (no `user-feedback`, no recognizable pattern — bot-authored / bare one-liner / unrecognized): add `needs-human-review`, comment with explanation. Surfaces via `/shipyard:my-turn`. (This is the genuine no-automated-path subset only — never the auto-processable work above.)

After this step, every dispatch-ready survivor of the first two branches is either dispatch-eligible (resolve-defaults) or carries `needs-human-review` (legitimate user-feedback). The fall-through branch lands the no-pattern subset on `needs-human-review`.

```
/refine-issues --repo <owner/repo> --concurrency <do-work concurrency>
```

Pass-through args:

- **`--repo`** — same value `/do-work` is using.
- **`--concurrency`** — same value `/do-work` is using (default `1` unless overridden — see [`/do-work`'s `--concurrency` arg](../../do-work.md#args) for the rationale).
- **`--issue`** is NEVER passed from `/do-work` — refinement always operates on the full eligible set during a `/do-work` startup.
- **`--dry-run`** is NEVER passed from `/do-work` — startup refinement always commits.

The refined-and-now-`needs-human-review` issues will be picked up by the *next* `/do-work` session, after a human reviews. Step 4's backlog fetch (just below) excludes `needs-human-review` and `needs-triage`, so none leak into the dispatch queue this session. Resolve-defaults issues, however, ARE picked up this session — they become dispatch-eligible the moment the refiner removes the `## Open questions` section (no gate label to drop).

**Implementation note.** The refinement logic itself lives in `/refine-issues`. This step is a thin invocation — no duplication of the bucket spec, sentinel logic, or worker prompt template. If we later change the refinement prompt, we only update one file (`commands/refine-issues.md`).
