# /shipyard:do-work — Setup phase · repo resolve + recovery + refine

**Setup sub-phase (cluster 2 of 5, part 1 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns steps **1 → 1.75**: resolve repo + user, silent-direct-merge repo-shape detection, missing-`workflow`-scope preflight warning, session-state initialisation, orphan session-file + orphan orchestrator-worktree reaps, trusted-author allowlist resolution, and config-named-label existence verification — the GH App alias normalization sub-step of step 1.7 and all of step 1.75 are stub pointers here; their full content lives in `01f`/`01e` below ([#1431](https://github.com/mattsears18/shipyard/issues/1431)). The rest of this cluster — backlog overview (step 2) and label-ensure + prior-session recovery + refinement (steps 3 → 3.5) — continues in **[`01b-backlog-overview.md`](./01b-backlog-overview.md)** and **[`01c-label-recovery-refine.md`](./01c-label-recovery-refine.md)** — this file was split into three once it grew past the per-`Read` token cap on its own ([#994](https://github.com/mattsears18/shipyard/issues/994); the original single-file split from [#611](https://github.com/mattsears18/shipyard/issues/611) was sized against the 256KB byte limit, not the 25k-token `Read` cap that actually binds). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md) / [`00b-parallelization-cache.md`](./00b-parallelization-cache.md). Next: [`01b-backlog-overview.md`](./01b-backlog-overview.md) (same cluster, part 2).

### 1. Resolve repo + user

> **Execution timing ([#1202](https://github.com/mattsears18/shipyard/issues/1202)):** these three reads now execute PRE-relocation, as part of [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) — this section documents the commands; 0.45 is where they actually fire, ahead of `EnterWorktree`.

These three reads are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5, not serially before them.

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
gh api user -q .login                                  # the gh-authenticated user
gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name   # default branch (cached as <default-branch>)
```

Cache all three for the session.

(The trusted-author allowlist used by step 4's filter and step 7's `originating_author_trust` computation is populated separately by [step 1.7 below](#17-resolve-trusted-author-allowlist).)

### 1.3 Detect the silent-direct-merge repo shape (admin + ungated-merge config)

> **Execution timing ([#1202](https://github.com/mattsears18/shipyard/issues/1202)):** this detector's read and the `$EFFECTIVE_CONCURRENCY` clamp now execute PRE-relocation, as part of [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) — [step 1.5](#15-initialise-the-session-state-file)'s `session-state.sh init --concurrency` needs this clamp's output, and 1.5 itself moved pre-relocation to unblock the *1.6.5 (removed — the harness reaps worktrees)* / *3b (removed — the harness reaps worktrees)* sweeps. **One resolution detail changes with the timing:** the `CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)` line below reads a stash file step 0.5 writes — it doesn't exist yet at this pre-relocation point. Use the pre-relocation compound preamble (step 0.3's form) instead. Everything else — the detector call, the clamp logic — is unchanged.

Closes issues [#438](https://github.com/mattsears18/shipyard/issues/438) and [#465](https://github.com/mattsears18/shipyard/issues/465). When the dispatching user has admin permissions, the worker's `gh pr merge --auto` can silently fall through to a **direct merge** instead of queuing (the `merged-direct` outcome documented in `shipyard:worker-preamble` § "Auto-merge + snapshot-and-return pattern" step 1.5 — fragment [`auto-merge.md`](../../../skills/worker-preamble/auto-merge.md) — and issue [#340](https://github.com/mattsears18/shipyard/issues/340)). At `--concurrency ≥ 2` this produces the **steady-state leapfrog**: the first PR to direct-merge advances `main`'s version and changes the top-of-file CHANGELOG entry, re-DIRTYing every other in-flight PR even when distinctly versioned (the cascade the [drain CHANGELOG-serialization gate](../drain.md#drain-protocol) addresses). See [RATIONALE → Step 1.3 mechanics](../../do-work-RATIONALE.md#step-13--silent-direct-merge-version-coordination-mechanics-438-465) for the full two-part breakdown.

This is a **warning, not a behavior change** — the orchestrator does not flip auto-merge config or add required checks on the repo (that's a maintainer decision). The *behavioral* gates that keep an ungated `--auto` from landing a PR before its CI live at the merge call sites themselves (see the [call-site table](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) below); this step only surfaces the shape to the operator, because it also explains why C≥2 version coordination on this repo cannot hold without serialized merges.

**The condition lives in exactly one place.** Do **not** re-derive the two-shape rule here. It is one executable script — [`scripts/detect-ungated-admin-direct-merge.sh`](../../../scripts/detect-ungated-admin-direct-merge.sh) — which owns the whole rule (both shapes, the `#645` ruleset-aware fallback, the `#479` numeric normalize, and the fail-safe posture that an unreadable signal resolves toward *ungated*). This step calls it:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
verdict=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo> 2>/dev/null || echo ungated)
# The repo is POSITIONAL — there is no `--repo` flag (#1502). A mis-invocation
# prints `USAGE_ERROR: ...` on stdout and exits 64, which the `|| echo ungated`
# fallback then appends to, producing a verdict that matches NEITHER literal.
# Normalize it back to the conservative reading rather than silently skipping
# the warning: re-run once with the literal positional form above, and if it
# still reports USAGE_ERROR, treat the shape as `ungated` and fix the call site.
case "$verdict" in USAGE_ERROR:*) verdict=ungated ;; esac
if [ "$verdict" = "ungated" ]; then
  echo "[setup] WARNING (#438/#465): \`gh pr merge --auto\` will SILENTLY DIRECT-MERGE on this repo (no queue) — you have admin/maintain and either allow_auto_merge=false (#438) or the default branch has zero required status checks (#465, fires even when allow_auto_merge=true). Shipyard's merge call sites gate on this automatically (#720): workers block on the PR's own checks, and the orchestrator-turn sites defer to drain's merge lander. But at --concurrency >= 2, version/CHANGELOG coordination across in-flight PRs still cannot hold: the first PR to merge advances main and re-DIRTYs siblings. Recommend --concurrency 1 here, or add a required status check (and/or enable allow_auto_merge) so --auto actually queues. version_coordination.serialize_drain_rebase (drain phase) mitigates the CHANGELOG cascade but not the steady-state leapfrog."
fi
```

**This step calls the shared detector script rather than re-deriving the rule ([#720](https://github.com/mattsears18/shipyard/issues/720)) — a condition restated in prose (or re-implemented in bash) in N files will drift; a condition that is one command cannot.** If you find yourself about to write `allow_auto_merge` or `required_status_checks` into a spec file, stop and call the script instead. See [RATIONALE → Step 1.3 script extraction](../../do-work-RATIONALE.md#step-13--why-detection-was-extracted-to-a-script-720) for the drift history.

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
  echo "[setup] concurrency clamped $EFFECTIVE_CONCURRENCY -> 1 (ungated merge shape)"
  EFFECTIVE_CONCURRENCY=1
fi
```

`EFFECTIVE_CONCURRENCY` is the value [step 1.5](#15-initialise-the-session-state-file) passes to `session-state.sh init --concurrency` — every downstream concurrency read (pool sizing, the parallel-vs-serial gates in [`00j-c1-path-index.md`'s C=1 index](00j-c1-path-index.md#lightweight-c1-path--whats-skipped-and-what-stays)) derives from that session-state value, so clamping here is sufficient; no other call site needs its own copy of this resolution. This clamp is deliberately narrow: it only downgrades a *config-sourced* default, never an explicit CLI flag, and it only fires on `ungated` — a `gated` repo's committed `concurrency.default: 2` (or higher) passes through unchanged, because on that shape `--auto` genuinely queues and the steady-state leapfrog this clamp exists to prevent cannot occur.

**Where the behavioral gates actually are.** Every `gh pr merge --auto` call site in shipyard now branches on this same script's verdict — the split is by whether the caller can afford to block:

| Call site | Runs on | On `ungated` |
|---|---|---|
| [issue-work §6.a](../../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) | worker's own slot | Block on `gh pr checks --watch`, merge only if green |
| [fix-main-ci step 7.a](../../../agents/issue-worker/fix-main-ci.md) | worker's own slot | Same — blocking wait |
| [fix-failing-prs-batch step 7.a](../../../agents/issue-worker/fix-failing-prs-batch.md) | worker's own slot | Same — blocking wait |
| [inline-trivial §E](../inline-trivial.md#e-arm-auto-merge) | orchestrator turn | Leave unarmed → [drain's merge lander](../drain.md#deferred-merge-lander-merge-unarmed-green-session-prs--720) |
| [A.0.5 crash recovery](../steady-state.md#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing) | orchestrator turn | Leave unarmed → drain's merge lander |
| [setup-3c orphan recovery](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) | orchestrator turn (setup) | Leave unarmed → drain's merge lander |
| [drain release-train](../drain.md#release-pr-auto-arming-and-deploy-watch-own-the-tail-phase-c--663) | orchestrator turn (drain poll) | Leave unarmed → drain's merge lander |

A **worker** can afford a multi-minute `--watch` — it owns a dispatch slot and blocks nobody. The **orchestrator** cannot: a block on its own turn stalls the dispatch loop, every in-flight reconcile, and every other PR. So the orchestrator-turn sites leave the PR open and unarmed, and drain's poll loop — which is already a queue — merges it the moment its checks go green.

### 1.35 Preflight-warn on missing `gh` `workflow` OAuth scope ([#818](https://github.com/mattsears18/shipyard/issues/818))

**Cheap, cached alongside the other repo-config preflight reads above (step 1.3).** GitHub blocks `enablePullRequestAutoMerge` for an OAuth-app token when the PR's diff touches `.github/workflows/*`, unless the token carries the `workflow` scope — `repo` alone is not enough. This step is the **proactive** half of the fix (a one-time session-start warning, before any workflow-touching PR is opened); [#812](https://github.com/mattsears18/shipyard/issues/812) separately landed the **reactive** half (a worker-side failure report). See [RATIONALE → Step 1.35 reactive vs proactive](../../do-work-RATIONALE.md#step-135--reactive-vs-proactive-workflow-scope-warning-812-716) for how the two halves fit together.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT

verdict=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/detect-missing-workflow-scope.sh" <owner/repo> <default-branch> 2>/dev/null || echo silent)
# The repo is POSITIONAL — there is no `--repo` flag (#1502). A mis-invocation
# prints `USAGE_ERROR: ...` on stdout and exits 64 instead of the pre-#1502
# behaviour of probing the repo `--repo`, failing both reads, and printing a
# confident `silent`. Surface it rather than inheriting the quiet default:
# re-run once with the literal positional form above, and if it still reports
# USAGE_ERROR, print `[setup] could not run the workflow-scope preflight
# (detect-missing-workflow-scope.sh invoked incorrectly) — see #1502` and
# continue. Never treat USAGE_ERROR as `silent`: a check that never ran is not
# a check that found nothing.
case "$verdict" in USAGE_ERROR:*) verdict=usage-error ;; esac
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

**The condition lives in exactly one place** — [`scripts/detect-missing-workflow-scope.sh`](../../../scripts/detect-missing-workflow-scope.sh) — same single-source-of-truth rationale as [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config)'s script. The script's decision logic (`--decide <has_workflow_scope> <workflow_signal>`) is unit-testable without a live `gh`/network call.

**Silent by default — the common case.** The script short-circuits to `silent` the instant the token already carries `workflow` (no further reads spent), and also resolves to `silent` when the token lacks the scope but nothing in the session shape suggests workflow-touching work. No warning fires on either path — this is deliberate: the issue's acceptance criteria explicitly forbid adding noise to the common case. The two cheap signals that flip it to `warn` (both single API calls, only spent when the scope is actually missing): an open issue or PR referencing `.github/workflows/`, or the default branch's most recent workflow run having concluded `failure` (a proxy for "a fix-main-ci divert — which routinely edits workflow files — is likely this session"; the full `main_ci.status` aggregate computed later in [step 4.5a](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) is deliberately not re-derived here, since this is an advisory warning, not a dispatch decision). Any read failure inside the script resolves toward `silent` — fail toward not warning, matching step 1.3's fail-safe posture on its own diagnostic reads.

**One-time, not per-PR.** This step runs once during setup. It does NOT re-check later in the session (e.g. after a new workflow-touching issue enters the backlog) — the reactive #812 path is the backstop for anything this early heuristic misses, and repeating the warning per-PR would be exactly the noise #812 itself was filed to move away from.

**Never attempt to refresh, escalate, or modify the token's scopes.** This step only surfaces the remediation command for a human to run — it does not call `gh auth refresh` itself. Auth handling is left entirely to the operator.

### 1.36 Detect CI executor pool capacity and clamp toward it ([#1141](https://github.com/mattsears18/shipyard/issues/1141))

> **Execution timing ([#1202](https://github.com/mattsears18/shipyard/issues/1202)):** this detector's read and the second `$EFFECTIVE_CONCURRENCY` clamp now execute PRE-relocation, as part of [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) — same reason as [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) above, and the same `CLAUDE_PLUGIN_ROOT` resolution-detail change applies: use the pre-relocation compound preamble (step 0.3's form), not the `.shipyard-plugin-root` stash below (doesn't exist yet at this point). Everything else is unchanged.

`--concurrency N` bounds how many **workers** the orchestrator keeps in flight. It says nothing about how many **CI runs** those workers generate, or whether the repo's CI executor can absorb them. On a repo whose CI runs on a small, fixed self-hosted runner pool — a maintainer's own Macs is the observed case — worker throughput and CI-landing throughput decouple: the session dispatches happily while the queue behind the runners grows without bound, and the session's own landing-based termination condition ([`do-work.md`'s completion contract](../../do-work.md)) becomes unreachable purely on CI capacity, not correctness. See [RATIONALE → CI executor pool capacity repro](../../do-work-RATIONALE.md#step-136--ci-executor-pool-capacity-repro-1141) for the session that motivated this.

**The read lives in exactly one place** — [`scripts/detect-ci-runner-capacity.sh`](../../../scripts/detect-ci-runner-capacity.sh), the same single-executable-source-of-truth pattern as [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config)'s merge-shape detector. It reads `repos/{owner}/{repo}/actions/runners` for the self-hosted runner pool's online/idle counts and `gh run list --status queued` for the current repo-wide queue depth, and fails safe toward `unknown` on any unreadable signal — never toward a fabricated pool size.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
CI_POOL_LINE=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/detect-ci-runner-capacity.sh" <owner/repo> 2>/dev/null || echo unknown)
CI_POOL_SHAPE=$(printf '%s' "$CI_POOL_LINE" | awk '{print $1}')
CI_POOL_TOTAL=0
CI_POOL_QUEUED=0
if [ "$CI_POOL_SHAPE" = "self-hosted" ]; then
  CI_POOL_TOTAL=$(printf '%s' "$CI_POOL_LINE" | grep -oE 'pool_total=[0-9]+' | cut -d= -f2)
  CI_POOL_QUEUED=$(printf '%s' "$CI_POOL_LINE" | grep -oE 'queued=[0-9]+' | cut -d= -f2)
fi
```

**Clamp only a config-sourced `EFFECTIVE_CONCURRENCY`, never an explicit `--concurrency` — same narrow-clamp shape as [step 1.3's #733 clamp](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config).** An operator who passed `--concurrency` by hand is asking for it explicitly and always wins, even against a small pool — the queue-depth advisory in the [end-of-session summary](../cleanup-summary.md#end-of-session-summary) is what surfaces the mismatch for them to act on next time. Only a **built-in/config default** concurrency gets clamped down here:

```bash
if [ "$CI_POOL_SHAPE" = "self-hosted" ] && [ -z "<--concurrency CLI value, if passed>" ] && [ "$CI_POOL_TOTAL" -gt 0 ] 2>/dev/null && [ "$EFFECTIVE_CONCURRENCY" -gt "$CI_POOL_TOTAL" ] 2>/dev/null; then
  echo "[setup] concurrency clamped $EFFECTIVE_CONCURRENCY -> $CI_POOL_TOTAL (self-hosted CI runner pool has only $CI_POOL_TOTAL online runner(s) — #1141)"
  EFFECTIVE_CONCURRENCY="$CI_POOL_TOTAL"
fi
```

`EFFECTIVE_CONCURRENCY` (now clamped by both step 1.3's merge-shape check and this pool-capacity check, in that order) is the value [step 1.5](#15-initialise-the-session-state-file) passes to `session-state.sh init --concurrency`. This clamp fires on `self-hosted` regardless of whether step 1.3 already clamped for a different reason — the two checks are independent and compose (a repo can be `ungated` AND have a small self-hosted pool; whichever check produces the lower value governs, since each re-reads the current `EFFECTIVE_CONCURRENCY`).

**Hold `CI_POOL_SHAPE` / `CI_POOL_TOTAL` / `CI_POOL_QUEUED` for the write-through in [step 1.5](#15-initialise-the-session-state-file).** The observation gets persisted into session state unconditionally — whether or not the clamp above fired — right after `session-state.sh init` creates the file (the field can't be `--set` before the file exists). This is what lets the [end-of-session summary](../cleanup-summary.md#end-of-session-summary) surface a "queue depth far exceeds pool capacity" advisory even on a session where the operator's **explicit** `--concurrency` was left un-clamped (the repro this issue reports: `--concurrency 4` against a 4-runner pool that itself degraded to 4 from 6 mid-session). See step 1.5 for the exact `update --set ".ci_capacity = ..."` call. On `hosted` (no self-hosted runners registered — the common case, GitHub-hosted runners are elastic) or `unknown` (couldn't read the signal), `.ci_capacity.shape` records that value too, so the summary step can distinguish "checked, nothing to report" from "never checked" if it ever needs to.

**This step's reads fold into the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch)** alongside step 1's and step 1.3's reads — fire them in the same burst, not serially. Both `gh api .../actions/runners` and `gh run list --status queued` are read-only diagnostic calls; a failure degrades to `unknown` and never blocks setup.

**One-time, not re-checked mid-session.** The pool size is read once at startup, matching step 1.3's and step 1.35's "one-time diagnostic" posture. Queue depth is inherently a live number — the end-of-session summary re-reads it fresh at session end rather than trusting `queued_at_start`, since a 4+-hour session's queue depth at the end is the number that matters for the "why didn't these land" question.

### 1.37 Detect CI-cheap-path availability ([#1157](https://github.com/mattsears18/shipyard/issues/1157))

Follow-up to [step 1.36](#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141) / [#1156](https://github.com/mattsears18/shipyard/issues/1156)'s dispatch-time backpressure hold. Both treat every candidate issue as equally CI-expensive when deciding whether to fill a freed slot. On a repo whose CI is path-gated — a `pull_request`-triggered workflow declares `paths-ignore: ['docs/**', '**/*.md']` (or similar) so a diff confined to those globs never triggers the heavy job — a docs-only or config-only PR costs the saturated runner pool nothing, and [steady-state.md step C](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action)'s CI-cheap bias can prefer such a candidate instead of leaving the slot idle. This step is the one-time, session-start read that tells step C whether such a lane even exists on this repo.

**The read lives in exactly one place** — [`scripts/detect-ci-cheap-path.sh`](../../../scripts/detect-ci-cheap-path.sh)'s repo-shape mode, the same single-executable-source-of-truth pattern as steps 1.3 and 1.36's detectors. It scans `.github/workflows/*.yml` / `*.yaml` in the checked-out repo (a local file read — no network call, unlike the other two detectors) for any `paths-ignore:` glob list and reports the union, deduplicated. **Deliberately narrow**: only `paths-ignore:` (an exclude list, directly invertible: "the diff matches the ignore list" ⇒ "this workflow doesn't even run") counts as a cheap path. A workflow that instead uses an include-only `paths:` allowlist is NOT treated as evidence of a cheap path — its implicit complement isn't safely invertible without also knowing every other path in the repo. A repo with no `paths-ignore:` anywhere reports `no-cheap-path` honestly rather than guessing one — the bias is a no-op on such a repo, exactly the "should probably be a no-op on a repo where every PR runs the full CI matrix" design question the originating issue raised.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
CI_CHEAP_LINE=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/detect-ci-cheap-path.sh" "<repo-checkout>/.github/workflows" 2>/dev/null || echo no-cheap-path)
CI_CHEAP_GLOBS=""
if [ "${CI_CHEAP_LINE%% *}" = "cheap-path-available" ]; then
  CI_CHEAP_GLOBS=$(printf '%s' "$CI_CHEAP_LINE" | sed -n 's/^cheap-path-available globs=//p')
fi
```

**Hold `CI_CHEAP_GLOBS` for the write-through in [step 1.5](#15-initialise-the-session-state-file)** — folded into the same `.ci_capacity` object step 1.36 writes, as `cheap_ci_globs` (comma-separated glob list, empty string when no cheap path exists). Unconditional write, same posture as `.ci_capacity.shape`.

**This step's read folds into the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch)** alongside the others — it's a local filesystem read (no `gh api`/`gh run list` call), so it's cheap regardless of batching, but batching keeps the setup-step ordering consistent with steps 1 / 1.3 / 1.36.

**One-time, not re-checked mid-session.** A repo's CI workflow shape doesn't change mid-session in the overwhelming common case; if it does (a workflow-editing PR merges to the default branch during a long session), the stale glob list only means the CI-cheap bias under-fires (misses a newly-cheap path) or over-fires (biases toward a path that's no longer cheap) for the rest of the session — never a correctness problem, since [steady-state.md step C](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action)'s bias only ever *prefers* a candidate among otherwise-eligible ones; it never skips the normal eligibility checks.

### 1.5 Initialise the session state file

> **Execution timing ([#1202](https://github.com/mattsears18/shipyard/issues/1202)):** this `session-state.sh init` call (and its `.ci_capacity` write-through) now executes PRE-relocation, as part of [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) — before `EnterWorktree`, so the *1.6.5 (removed — the harness reaps worktrees)* / *3b (removed — the harness reaps worktrees)* sweeps (which now also run pre-relocation) have a session-state file to consult for *step 3b's `.in_flight` guard (removed — the harness reaps worktrees)* by the time they run. Use the pre-relocation `CLAUDE_PLUGIN_ROOT` form (step 0.3's compound preamble) here, NOT the `.shipyard-plugin-root` stash below — that stash is a step-0.5-and-later artifact that doesn't exist yet at this point in the session. Commands are otherwise unchanged; only the execution point (and that one resolution detail) moved.

Stand up the durable JSON mirror (see [Session state file](../../do-work.md#session-state-file) and the full [schema + helper reference](../session-state-file.md)). One-shot setup write — every subsequent mutation routes through `session-state.sh update`.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# <session-id> is the orchestrator's session identifier — the same value
# step 0.5 used in the orchestrator-worktree path. Stable across the run.
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" init \
  --session-id "<session-id>" \
  --repo "<owner/repo>" \
  --concurrency "$EFFECTIVE_CONCURRENCY" \
  --soft-collision-concurrency <N from --soft-collision-concurrency arg>
```

`$EFFECTIVE_CONCURRENCY` is resolved (and, on an `ungated` merge shape or a small self-hosted CI runner pool, clamped) by [step 1.3](#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) and [step 1.36](#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141) — don't re-read `--concurrency` or `concurrency.default` independently here, or the clamps become bypassable by whichever read happens second.

**Immediately after `init` returns successfully**, write through the CI-capacity observation step 1.36 computed (`CI_POOL_SHAPE` / `CI_POOL_TOTAL` / `CI_POOL_QUEUED`) plus [step 1.37](#137-detect-ci-cheap-path-availability-1157)'s `CI_CHEAP_GLOBS` — unconditionally, regardless of either value, so the end-of-session summary and steady-state.md step C always have a `.ci_capacity.shape` / `.ci_capacity.cheap_ci_globs` to branch on:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update \
  --session-id "<session-id>" \
  --set ".ci_capacity = { shape: \"$CI_POOL_SHAPE\", pool_total: ${CI_POOL_TOTAL:-0}, queued_at_start: ${CI_POOL_QUEUED:-0}, cheap_ci_globs: \"${CI_CHEAP_GLOBS:-}\" }"
```

The file lands at `$SHIPYARD_HOME/sessions/<session-id>.json` (default: `~/.shipyard/sessions/<session-id>.json`). The default config above is the entire schema with empty queues + an `unknown` `main_ci` state — everything else gets filled in by later setup steps and the steady-state loop.

**If `init` returns exit code 2** ("file already exists"), call `init --force` to clobber the stale file. Log `[session-state] --force overrode stale state file from <prior session>`.

**If `init` returns 65+** (jq missing, permission denied, etc.), continue without the session-state file. The invariant line emits `state=disabled` to make the degradation visible. Don't block the session on file-write failure.

### 1.6 Reap orphan session files (cost-ledger recovery)

> **Background step — stays post-relocation ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. The canonical code lives in the background group above; this section documents the intent, race-safety rules, and skip condition. Do NOT duplicate the implementation here. **Unlike *step 1.6.5 (removed — the harness reaps worktrees)* immediately below, this sweep does NOT move pre-relocation** — it's pure `$SHIPYARD_HOME/sessions/*.json` file housekeeping with no `git -C <other-worktree>` operations, so the worktree-isolation guard never has a reason to fire on it, and there's no benefit to running it any earlier than it already does.

**Sweep `$SHIPYARD_HOME/sessions/` for orphan files left behind by prior sessions that crashed or exited without running [`cleanup-summary.md`'s step 7 → step 8 flush + cleanup chain](../cleanup-summary.md#end-of-session-cleanup).** Without this sweep, any session that doesn't terminate via the happy-path cleanup strands its per-session ledger on disk forever — the cross-session reports at `/shipyard:cost report` then under-count by full sessions. See [RATIONALE → Step 1.6 orphan session-file regression](../../do-work-RATIONALE.md#step-16--orphan-session-file-regression-227) for the production repro (issue #227).

**Extracted into [`scripts/sweep-orphan-sessions.sh`](../../../scripts/sweep-orphan-sessions.sh) (issue #1182)** — this section used to duplicate the sweep as an inline `find | while read` loop calling `session-state.sh` / `cost-history.sh` per iteration, directly contradicting its own "Do NOT duplicate the implementation here" callout above (and, independent of the duplication, a multi-statement compound shape Auto Mode's classifier can refuse outright as part of the larger step-0.7 background group — the concrete repro that motivated the extraction). The canonical call, run from inside the step-0.7 background group:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/sweep-orphan-sessions.sh" sweep \
  --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}" \
  --current-session-id "<session-id>" \
  --reaper-session-id "<session-id>"
```

**Same two-gate shape as before, now inside the script.** Session files older than 30 minutes (`--stale-min`, race-safety margin against a concurrent `/do-work` session about to flush its own file) AND whose owning process is confirmed dead via `session-state.sh is-active` (PID-liveness — see issue #253 for the failure mode where the mtime floor alone was insufficient) qualify for reap; either gate alone is not enough. Every reap flushes cost-history for that session id (idempotent — a no-op if already flushed) then calls `session-state.sh cleanup --reap-audit`, so a re-run of the sweep is always safe. The script's own header carries the full rationale; regression coverage lives at [`scripts/tests/sweep-orphan-sessions.test.sh`](../../../scripts/tests/sweep-orphan-sessions.test.sh).

**Orphan atomic-write `.tmp` sweep (issue #858).** The sweep above only discovers stale `*.json` session files — it has no way to discover a `.tmp.<pid>` leftover whose target `.json` never successfully landed (a crash between `atomic_write`'s `cat > "$tmp"` and its `mv -f "$tmp" "$target"`, most commonly during `session-state.sh init`). That file matches no session id the sweep above could hand to `cleanup --session-id`, so under that sweep alone it would linger forever. `cost-history.sh`'s reconcile-rewrite path (`mktemp "${session_target}.XXXXXX"` / `.err.XXXXXX`) and `flake-registry.sh`'s prune rewrite (`<path>.tmp.$$`) have the identical structural gap, with no sweep anywhere for either. [`scripts/sweep-orphan-tmp.sh`](../../../scripts/sweep-orphan-tmp.sh) closes all three in one pass, right after the sweep above, in the same background bash group:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/sweep-orphan-tmp.sh" sweep \
  --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}"
```

**Same two-gate shape as the `*.json` sweep above, applied per category** — see the script's own header for the full rationale, summarized here:

- `sessions/*.json.tmp.<pid>` and `flake-registry.jsonl.tmp.<pid>` embed the writer's pid directly in the filename (the `.tmp.$$` convention both `atomic_write()` and `flake-registry.sh`'s prune rewrite use), so the sweep gates on the same 30-minute mtime floor **plus** a precise per-file `kill -0 <pid>` liveness check — no `is-active` JSON lookup is possible here (there's no session record to read a `.pid` field from), but the filename itself carries an equally authoritative signal.
- `cost-history.jsonl.<rand>` / `.err.<rand>` (from `mktemp`) carry no pid in the name, so no per-file liveness check is possible. Instead, the **entire category** is skipped for the pass while `cost-history.jsonl.lock` — the mkdir-based flush lock `cost-history.sh` holds across its whole reconcile-rewrite critical section — exists and is fresher than its own staleness floor (30s, mirroring `cost-history.sh`'s `FLUSH_LOCK_STALE_SECONDS`). A lock older than that is treated exactly as `cost-history.sh` itself treats it: a crashed owner's abandoned lock, safe to sweep past.

**Every reap is logged, not silent** — one `reaped: <path> (age=…m category=…)` line per file, printed to stdout (or `reaped (dry-run): …` under `--dry-run`, and `skip: <path> (<why>)` to stderr for anything the age/liveness/lock gates protect). This matters specifically for the `cost-history.jsonl` category: a `.tmp`/`.err` leftover there can be evidence of a real, already-surfaced failure (`cost-history.sh`'s deliberate abort-on-jq-failure path, issue #901) rather than ordinary garbage, so silently vacuuming it away would erase the only trace of what happened — consistent with the observability sweep issues #871–#877 completed this session, which replaced several other silent-failure paths in this plugin with visible diagnostics.

`reap-audit.jsonl` and `autoreport-failures.jsonl` are deliberately **not** in scope for this sweep — both are plain `>>` appends with no tmp-file step, so neither has an atomic-write leftover to reap.

Regression coverage: [`scripts/tests/sweep-orphan-tmp.test.sh`](../../../scripts/tests/sweep-orphan-tmp.test.sh), including the crash-mid-`atomic_write` repro (a `.tmp.<pid>` with no corresponding `.json`, reaped) and its mirror-image safety case (a fresh/in-progress `.tmp` — young by mtime, or whose writer pid is still alive — left untouched).

**Two gates, not one.** A PID-liveness gate (`session-state.sh is-active`) runs **before** the mtime check: if the owning process is alive, skip the reap regardless of mtime. The `.pid` field is stamped into the session file at `session-state.sh init` time (defaulting to `$PPID`, overridable via `--pid <N>`); `is-active` reads it and runs `kill -0 $pid`. Both gates have to fail before a file is reaped. Sessions written by older shipyard versions have no `.pid` field — `is-active` exits 1 in that case, falling through to mtime-only behaviour for the migration period. See [RATIONALE → Step 1.6 two-gate protection](../../do-work-RATIONALE.md#step-16--two-gate-reap-protection-production-failure-253) for the production incident (issue #253) that motivated the second gate.

**Cost-tracking degraded-recovery (issue #253's workaround, extended by #281).** Workers calling `session-state.sh bump-tokens` against a session whose file was reaped mid-session can pass `--allow-degraded-init` (with optional `--degraded-init-repo <r>`) to auto-recreate a fresh state file marked with `.degraded_recovery_at` rather than erroring exit-3. [Issue #281](https://github.com/mattsears18/shipyard/issues/281) extended the same flag to `session-state.sh update` — the orchestrator's working-memory mirror writes now survive a mid-session disappear without forcing a manual `init --force`. Data from before the disappear is lost (the file was gone), but every write from the disappear forward lands somewhere durable. Callers that want strict "must-have-pre-existing-file" semantics simply omit the flag — the original exit-3 behaviour is preserved by default so silent typos / wrong-session-id mistakes still surface.

**Reap-audit logging (issue #281).** When step 1.6 reaps a peer's session file, it now calls `cleanup --reap-audit --reaper-session-id <session-id>`, which captures the reaped file's metadata (pid, repo, tokens.totals, degraded_attribution_count, mtime, started_at, updated_at) and writes one JSONL line to `~/.shipyard/reap-audit.jsonl` with `action: "reaped-session-file"`. Same audit-log file as worktree-reap.sh emits (issue #284), so a reader can correlate session-file reaps with worktree reaps for the same session id. Without this, a "where did my session file go?" investigation has no forensic trail — just the symptomatic `exit 3` from a downstream write. The audit-log write is fire-and-forget — a permission error / disk-full / corrupt source JSON never aborts the reap (the reap itself is the load-bearing work; the audit line is observability).

**Don't block the session on sweep failures** — log `[orphan-reap] <reason>` and proceed. Recovery of historical data is observational; the dispatch loop's job comes first. If `SHIPYARD_KEEP_SESSIONS=1` is set (per the [step 8 cleanup-summary opt-out](../cleanup-summary.md#end-of-session-cleanup)), skip the sweep entirely — the user explicitly opted into keeping session files as permanent records.

### 1.65 Detect live peer sessions on this repo ([#1204](https://github.com/mattsears18/shipyard/issues/1204))

**Synchronous — part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch), not step 1.6's fire-and-forget background group.** Its result gates [step 4](04-backlog-divert.md#4-fetch--rank-the-backlog)'s backlog filter, so it must complete before dispatch, unlike step 1.6's cost-ledger housekeeping.

Nothing before this step looked for another `/shipyard:do-work` session working the SAME repo. Two sessions started minutes apart can fetch and rank the same deterministic backlog and dispatch a worker against the same issue at once — one merges a PR while the other's worker keeps implementing against an issue that already closed. Self-assign (step 1) doesn't catch this: both sessions assign as the same `gh`-authenticated user, so "don't work issues assigned to other users" sees its own login and passes.

The session-state file at `$SHIPYARD_HOME/sessions/<id>.json` already carries everything needed: `.repo`, `.in_flight[].target`, and mtime as a liveness proxy. This step walks the same directory [step 1.6](#16-reap-orphan-session-files-cost-ledger-recovery) already globs (no second walk), applying its mtime-staleness convention in the opposite direction — a file is a LIVE peer candidate only when its mtime is fresh, not stale:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
PEER_LINES=$("$CLAUDE_PLUGIN_ROOT/scripts/detect-peer-sessions.sh" check \
  --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}" \
  --repo "<owner/repo>" \
  --current-session-id "<session-id>" 2>/dev/null || echo "summary: peers=0 claimed_targets=(none)")
PEER_COUNT=$(printf '%s\n' "$PEER_LINES" | grep -o 'peers=[0-9]*' | tail -1 | cut -d= -f2)
PEER_CLAIMED_TARGETS=$(printf '%s\n' "$PEER_LINES" | grep -o 'claimed_targets=.*' | tail -1 | cut -d= -f2-)
[ "$PEER_CLAIMED_TARGETS" = "(none)" ] && PEER_CLAIMED_TARGETS=""
```

Write through unconditionally, holding the value for the rest of the session (same posture as `trusted_authors` — resolved once, never re-resolved mid-session):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
PEER_TARGETS_JSON=$(printf '%s' "$PEER_CLAIMED_TARGETS" | jq -R 'split(",") | map(select(length>0) | tonumber)')
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update --session-id "<session-id>" \
  --set ".peer_sessions.count = ${PEER_COUNT:-0}" \
  --set ".peer_sessions.claimed_targets = $PEER_TARGETS_JSON" \
  --set ".peer_sessions.checked_at = \"<iso-8601 UTC now>\""
```

`PEER_CLAIMED_TARGETS` feeds [step 4's drop rule](04-backlog-divert.md#4-fetch--rank-the-backlog) (mechanics + warn-and-continue policy: [`04e-peer-session-drop.md`](04e-peer-session-drop.md)). `PEER_COUNT` feeds [step E's invariant line](../steady-state.md#e-invariant-line-end-of-every-steady-state-turn) as `peers=<n>`.

**Fail-safe.** Always exits 0, degrading to `peers=0 claimed_targets=(none)` on any read failure — never blocks dispatch. A stale peer file (past the freshness window, step 1.6's floor) is never live, so a dead-mid-flight peer can't permanently starve this session's backlog.

### 1.7 Resolve trusted-author allowlist

**Timing instrumentation (issue #238).** Bracket this step:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
# ... run resolution logic ...
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
```

**Security gate — must run before step 2's bucket pass and step 4's backlog fetch.** Populates the session-level `trusted_authors` set (the 10th orchestrator state struct — see the [state struct list](../../do-work.md#orchestrator-state) at the top of this spec). The set decides which issue authors `/do-work` will dispatch workers against; everyone else lands in step 2's `Untrusted author` bucket and step 4's client-side filter drops them from the workable queue — the **first line of defense** against the public-repo prompt-injection threat. See [RATIONALE → Step 2 bucket 0.5 security gate](../../do-work-RATIONALE.md#step-2--why-bucket-05-is-a-security-gate) for the threat model.

**Resolution order — first non-empty wins:**

1. **Per-repo override file** — if `.shipyard/trusted-authors.txt` exists in the orchestrator worktree, read it. **The file must be git-tracked (committed), not a local-only override** — this bare relative read runs against a fresh checkout of `origin/<default-branch>` in the orchestrator worktree, which only materializes tracked content. It's the one file under `.shipyard/` meant to be committed; everything else there (`config.local.json`, `flake-suspects.txt`) is deliberately gitignored per-machine state. One GitHub login per line; lines starting with `#` are comments; blank lines are ignored; logins are case-insensitive (lowercased on read). The repo owner (`<owner>` portion of `<owner/repo>`) is implicitly included even when the file omits them. Run the file through `trusted-authors-normalize.sh` (see [GH App alias normalization](./01f-gh-app-alias-normalization.md#gh-app-alias-normalization-issue-296)) so both `<bot>[bot]` and `app/<bot>` resolve correctly regardless of which form the file uses. Use the normalized set as `trusted_authors` and stop — do not fall through to the collaborators API.

2. **Collaborators API fallback** — when the override file doesn't exist, query the live collaborators-with-push API:

   ```bash
   gh api "repos/<owner/repo>/collaborators?per_page=100" --paginate \
     --jq '.[] | select(.permissions.push==true) | .login' | tr 'A-Z' 'a-z' | sort -u
   ```

   Add `<owner>` (lowercased) to the result set so a personal-repo owner with no other collaborators still works. Pass the result through `trusted-authors-normalize.sh` for consistency with branch 1 (the collaborators API doesn't return bots, so the alias expansion is usually a no-op, but the call is safe). Cache the result as `trusted_authors`.

3. **API failure / permission denied** — when the API call errors (the auth'd token can't list collaborators, e.g. the repo is owned by an org and the token doesn't have admin scope), fall back to a single-member set containing just `<owner>` (lowercased). Log an advisory: `[trusted-authors] could not query collaborators API (<reason>); falling back to repo owner only`. The session continues — restrictive default is the safe failure mode.

`.shipyard/trusted-authors.txt` format — one GitHub login per line; comments (`#`) and blank lines OK; case-insensitive; repo owner is implicitly trusted. Bot / GitHub-App accounts are NOT auto-trusted — the collaborators-API fallback excludes them, and maintainers must add them to the override file explicitly. Either login shape works: `sentry[bot]` (REST) OR `app/sentry` (GraphQL) — `trusted-authors-normalize.sh` cross-adds the alias, and the orchestrator's downstream `author.login` comparison matches either one (see [GH App alias normalization](./01f-gh-app-alias-normalization.md#gh-app-alias-normalization-issue-296)). Cache lifetime is session-scoped — resolve once at startup, never re-resolve mid-session. See [RATIONALE → Step 1.7](../../do-work-RATIONALE.md#step-17--why-a-per-repo-override-file-exists) for the policy discussion.

#### GH App alias normalization (issue #296)

**Full detail moved to [`01f-gh-app-alias-normalization.md`](./01f-gh-app-alias-normalization.md)** ([#1431](https://github.com/mattsears18/shipyard/issues/1431), splitting this file back under the per-file byte cap). Load it now — it owns the complete sub-step: why GitHub returns two different login shapes for the same GH App account, the `trusted-authors-normalize.sh` cross-add mechanism, the GitHub Actions workflow-side inlining, the CODEOWNERS protection recommendation for the override file, and the advisory-output line shapes (including the per-alias log line).

### 1.75 Verify config-named labels exist in the target repo ([#1359](https://github.com/mattsears18/shipyard/issues/1359))

**Full detail moved to [`01e-verify-config-labels.md`](./01e-verify-config-labels.md)** ([#1431](https://github.com/mattsears18/shipyard/issues/1431), splitting this file back under the per-file byte cap). Load it now — it owns the complete step: the load-bearing gap this check closes, the unconditional-execution shape, the `verify-config-labels.sh` invocation, the `OK`/`MISSING`/`INDETERMINATE` branch handling, and why the comparison lives in a script rather than inline prose.

