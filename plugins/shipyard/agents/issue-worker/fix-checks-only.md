# Fix-checks-only mode (PR triage)

Repair failing CI on an existing PR. **No new PR, no scope expansion, no PR title/description edits, no issue close.** Run the fix-loop until checks are green or the 3-attempt cap is hit.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-checks-only specifics.

## Inputs (from the dispatch prompt)

- PR number `#M`.
- Head branch name `<headRefName>` — the orchestrator passes this so you don't have to look it up.
- Target repo `<owner/repo>`.

## Setup

The harness placed you inside an isolated worktree on some placeholder branch (typically `worktree-agent-<id>`). Land on the PR's actual head branch with the **safe two-step** — do NOT use `gh pr checkout` (see worker-preamble's worktree discipline rule 2):

```bash
HEAD_REF=$(gh pr view <M> --repo <owner/repo> --json headRefName -q .headRefName)
git fetch origin "$HEAD_REF"
git switch "$HEAD_REF"
```

**If `git switch` fails with "is already checked out at <path>"** — the head branch is still locked in the originating worker's worktree. The orchestrator's pre-dispatch head-branch reap should already have released a `self-ancestor` (our own session's PID) lock before you started, regardless of dispatch site: from the steady-state `failed_prs` queue it's the [steady-state 2d reap (#368)](../../commands/do-work/steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action), and from drain it's the [drain pre-dispatch reap (#370)](../../commands/do-work/drain.md#pre-dispatch-head-branch-reap-self-pid-lock-release). A surviving collision means the lock is `peer-alive` (a genuinely-live non-orchestrator process), which the orchestrator correctly declined to yank. Bail with `blocked #<M> at fix-checks: head branch <HEAD_REF> locked in another worktree — needs end-of-session reap` rather than working around it with a temporary branch. The next session's startup sweep clears the lock.

## Hard rules

1. Do NOT modify scope. Do NOT amend the PR title/description. Do NOT close the linked issue from this PR. Do NOT add new tests or refactors — fix only what's needed to turn the failing checks green.
2. **Hard cap: 3 fix attempts.** After the 3rd failure, return `blocked #<M> at fix-checks: <last failing check> — <last error excerpt>`. The orchestrator will label the PR `blocked:ci` and move on. Do not let one PR consume the session.
3. **`green #<M>` is a load-bearing claim**, not a hypothesis — see the return contract below.

## Return contract — read carefully

When you finish, your **last line MUST be exactly one of the three strings below** (with `<M>` substituted). Anything else is a contract violation that wastes orchestrator turns. The exact semantics of `green` matter:

- `green #<M>` — **a full CI run completed and passed AFTER your final push.** Not "pushed and queued." Not "the failure looked transient so I optimistically declared victory." Not "I rebased onto a green main so it should work now." Not "I fixed what I concluded the failure was, so it should be green now." The contract is "the rollup is fully `SUCCESS` (or `SKIPPED` / `NEUTRAL`) at the moment you return." You enforce this by running the `gh pr checks <M> --watch --interval 30` step in the fix-loop below to completion — not by polling once and assuming the queued runs will eventually pass — **and then re-confirming the specific check(s) that were failing at dispatch flipped to SUCCESS on the post-push SHA** (the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) below). The orchestrator's [step A reconcile](../../commands/do-work/steady-state.md#a-reconcile-the-return) spot-checks `statusCheckRollup` on every `green` return and will downgrade you to `pending` / `failing` if the rollup contradicts your claim. The advisory log will say `[fix-checks-verify] downgraded #<M> green→…` — that's the breadcrumb saying you returned too early.
- `noop: already green #<M>` — no failures by the time you started. Same verification semantics: confirm with a single `gh pr view <M> --json statusCheckRollup` that the rollup is fully passing before returning this. The orchestrator spot-checks this path too.

  **Use the latest-per-name projection, not the raw rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns every check run for the PR's head SHA — including superseded runs. A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk false-positives whenever a check ran, failed, was re-triggered, and passed — the first FAILURE entry trips the bail even though the latest run is SUCCESS. De-duplicate by `name` and take the most recent entry per check before walking for failures:

  ```bash
  fails=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length')
  ```

  If `fails == 0` at the moment of return, you can claim `noop: already green` (or `green`). If `fails > 0` AND you haven't pushed any fix this dispatch, you have real work to do — fall into the fix-loop. The reduction is load-bearing: `group_by(.name) | map(... | last)` collapses N entries per check name to 1 (the latest), so a stale FAILURE superseded by a later SUCCESS is correctly filtered out.

- `blocked #<M> at fix-checks: <reason>` — 3 attempts exhausted or the failure is structural.

**Do NOT return mid-stream status updates.** Strings like the following are contract violations and are NOT acceptable terminal returns:

- `"E2E shards typically take 8-15 min. Let me wait for the Monitor notifications."`
- `"Let me wait for the monitor to report results."`
- `"Routine progress, no action needed. Waiting for unit + E2E results."`
- `"Lint & Typecheck pass. Waiting for unit + E2E."`
- `"Unit tests pass. Awaiting E2E shards."`
- `"Shard 3/3 passes. Awaiting shards 1 and 2 (2 was the previously failing one)."`
- `"Routine progress."` / `"Waiting for X."` / `"Shard N still running."`

Each of those returns is treated by the harness as a **completion notification**, forcing the orchestrator to spend a turn just to acknowledge "stale re-notification, no state change." A single fix-checks dispatch that returns six narrative updates burns six orchestrator turns for what should have been one terminal return. The orchestrator's [step A reconcile](../../commands/do-work/steady-state.md#a-reconcile-the-return) parses your last line by matching the documented prefixes (`green`, `noop:`, `blocked`); a string that doesn't match falls through to a defensive `gh pr view <M>` probe, and the orchestrator logs `[fix-checks-unrecognized]` against your worker.

**If checks are still running when you'd otherwise be ready to return, block your own turn on the watch loop until they finish — then return one of the three values above.** The agent harness's notion of "completion" is "you produced your final assistant message and stopped" — it has no way to distinguish "I'm waiting for monitor notifications" from "I'm done." So the only correct way to wait for CI is to keep the foreground bash call running:

```bash
gh pr checks <M> --repo <owner/repo> --watch --interval 30
```

This command exits zero when the rollup resolves to all green, non-zero on any failure — either way, you re-enter the fix-loop or fall through to the return. Do not produce intermediate assistant messages narrating "shard 2 still running" or "waiting for monitor"; those are visible as completions to the harness and the contract violation kicks in.

## Named-failing-check re-verification gate (load-bearing)

Closes [#416](https://github.com/mattsears18/shipyard/issues/416) — a **false-green** failure mode. `gh pr checks <M> --watch` exiting zero is *necessary* but not *sufficient* to claim `green`. Two ways a worker reaches "I'm ready to return `green`" while the PR is still red:

1. **Misdiagnosis.** You concluded the failure was cause X, fixed X, and re-watched — but the *real* failing check was Y, and your fix didn't touch it. The canonical repro is the jest worktree-ignore artifact (issue body of #416, lightwork session `do-work-20260531T113301Z-98771`): the required **🧪 Unit Tests** check was failing because the PR added `Strings.*` keys without mirroring them into `locales/en.json` (an i18n-parity test failure), but the worker concluded the failure was the repo's `jest.config.js` `testPathIgnorePatterns: ['/.claude/worktrees/']` "No tests found" artifact (a real-but-unrelated worktree gotcha — see worker-preamble § "Test-runner silent-pass when the target repo ignores worktree paths"), "fixed" *that*, and returned `green` while Unit Tests was still red.
2. **Premature return.** Your fix is pushed, but CI hasn't re-run the named check yet. `--watch` can exit zero on a *stale* all-green rollup (the new run is still QUEUED and the rollup reflects the pre-push SHA's checks, or a superseded run). "I pushed a fix so it should be green" is a hypothesis, not a verified state.

**The gate: before returning `green`, re-fetch the specific check(s) that were failing at dispatch and confirm each one's *latest* run on the current head SHA concluded SUCCESS.** Never infer the named check passed from a local test run, from `--watch`'s exit code alone, or from "I fixed what I thought was wrong."

Record the failing check name(s) when you first identify them (fix-loop step 1). Then, after your final push and watch, re-probe by name with the same latest-per-name projection the `noop:` path above uses — and additionally assert the rollup's head SHA matches the SHA you just pushed, so you're not reading a stale pre-push rollup:

```bash
# The SHA you just pushed (the head of the PR's branch in your worktree).
PUSHED_SHA=$(git rev-parse HEAD)

# Re-fetch the rollup AND the head SHA GitHub currently associates with the PR.
gh pr view <M> --repo <owner/repo> --json statusCheckRollup,headRefOid --jq "
  .headRefOid as \$head |
  {
    head_matches_pushed: (\$head == \"$PUSHED_SHA\"),
    # For each check that was failing at dispatch, the latest run's conclusion.
    named_checks: [.statusCheckRollup
                   | group_by(.name)
                   | map(sort_by(.completedAt // .startedAt // \"\") | last)
                   | .[]
                   | select(.name == \"<failing-check-name>\")
                   | {name, conclusion: (.conclusion // .status // null)}]
  }"
```

Treat the return as `green` **only when all three hold**:

- `head_matches_pushed == true` — GitHub's PR head is the SHA you pushed (you're not reading a stale rollup from before your push).
- Every named-at-dispatch failing check appears in `named_checks` with `conclusion == "SUCCESS"` (or `SKIPPED` / `NEUTRAL`).
- The overall rollup is all-green per the latest-per-name projection used in the `noop:` path above (no *other* check regressed).

If a named check is still `QUEUED` / `IN_PROGRESS` / `null` (CI hasn't re-run it), you are NOT done — keep the `gh pr checks <M> --watch --interval 30` foreground call alive until it resolves, then re-probe. Do NOT return `green` on a queued named check.

If a named check is **still FAILURE after your fix**, your diagnosis was wrong — re-read the failing log, treat the original failure as un-fixed, and loop (respecting the 3-attempt cap). Do NOT "fix" a *different* check and declare victory; the gate exists precisely to catch the misdiagnosis case.

**Recognize the i18n-parity signature as a distinct, common pattern.** When the failing log says a parity / completeness test is missing keys — e.g. `locales/en.json is missing keys derived from lib/strings.ts`, `__tests__/i18n.test.ts` asserting every `Strings.*` key has a translation — the fix is to mirror the new keys into the locale file(s), NOT to declare the failure a worktree-ignore artifact. A "No tests found" / zero-test pass from re-running jest with the worktree path stripped does NOT resolve an i18n-parity failure; those are two different checks. If you see a zero-test pass on a diff that touched `Strings.*` / `lib/strings.ts` and a *separate* parity test is red, the parity test is the real failure.

## Fix-loop

In this mode — and only this mode — you do block on CI, because resolving a known-failing PR is the agent's entire job.

```bash
gh pr checks <M> --repo <owner/repo> --watch --interval 30
```

On failure:

1. Identify the failing check:
   ```bash
   gh pr checks <M> --repo <owner/repo> --json name,state,link
   ```
   **Record the failing check name(s)** — you need them for the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) before you can return `green`. The gate re-probes these exact names on the post-push SHA; fixing a *different* check and declaring victory is the misdiagnosis failure mode #416 documents.
1.5. **Pre-rerun flake-suspects check (the `stop-auto-rerunning` consumer side — issue #385).** Before you re-run / re-watch a failing check, ask whether it's a *known chronic flake* that a prior session escalated. Phase 2 of the flake registry writes crossed flakes to a per-repo `.shipyard/flake-suspects.txt`; the contract is that `fix-checks-only` **refuses to keep auto-rerunning** a listed flake until a human signs off (deletes the line). This is the enforcement that turns the registry from a passive ledger into the "fix the root cause instead of re-running forever" rule. **Gate the check on `flake_registry.enabled == true`** (same gate as the recording side below) — when disabled, skip this step entirely (pre-#378 behavior).

   Build the suspect key from the failing check's `(workflow, job, test)` — the same pipe-joined shape `stop-auto-rerunning` wrote (`<workflow>|<job>|<test>`, test component empty when you can't pin it) — and probe the list:
   ```bash
   ENABLED=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
   if [[ "$ENABLED" == "true" ]]; then
     KEY="<workflowName>|<failing job name>|<test-id-or-empty>"
     if "${CLAUDE_PLUGIN_ROOT}/scripts/flake-enforce.sh" is-suspect --key "$KEY" --repo-root "$(git rev-parse --show-toplevel)"; then
       # Known chronic flake — do NOT auto-rerun. The escalation (tracking issue,
       # blocked:ci label) was already applied by the orchestrator's setup-time
       # enforce pass; your job is to stop, not to burn fix attempts on it.
       echo "blocked #<M> at fix-checks: chronic flake <KEY> is on .shipyard/flake-suspects.txt — auto-rerun suppressed pending human signoff (see the test-stability tracking issue)"
       exit 0
     fi
   fi
   ```
   When the key matches, return the `blocked #<M> at fix-checks: chronic flake ...` string above verbatim and stop — do NOT fall through to re-running, and do NOT count this against the 3-attempt cap (you never attempted a fix; you deliberately declined to rerun a known flake). The orchestrator's reconcile labels the PR `blocked:ci` on a `blocked #<M> at fix-checks:` return, which is exactly the desired end state for a chronic-flake-blocked PR (the setup-time `apply-blocked-ci` action may already have applied it; the label is idempotent). When the key is NOT on the list, proceed normally to step 2.
2. Pull failed logs. **Stream the output rather than redirecting it to a file** — a big `--log-failed` fetch piped to `> /tmp/log` produces zero stream output for its whole duration and can trip the harness's ~600s stall watchdog (worker-preamble § "Heartbeat emission around long-running commands"; issue [#372](https://github.com/mattsears18/shipyard/issues/372)). Pipe through `tee` if you also need the file:
   ```bash
   gh run view <run-id> --repo <owner/repo> --log-failed 2>&1 | tee /tmp/failed.log
   ```
   The same heartbeat discipline applies to `npm ci` and to a buffered local test re-run in step 3 — keep stream output flowing so a 5–15 min command doesn't read as a stall.
3. Reproduce locally if practical.
4. Fix the smallest thing that resolves the failure. Don't expand scope.
5. `git commit` + `git push` to the same branch. Never `--no-verify` (see worker-preamble). Never force-push unless rewriting history is genuinely required.
6. Re-watch checks.

**Hard cap: 3 fix attempts.** After the 3rd failure, return `blocked #<M> at fix-checks: <last failing check> — <last error excerpt>`. The orchestrator will label the PR `blocked:ci` and move on.

**Record root-cause context before returning `green`.** When you identify the actual root cause of a failure (especially flake / race / environmental issues that look mysterious from the failing log alone), post a one-line comment on the PR before returning. Format: `Fix-checks: <one-line root cause>` (e.g., "Fix-checks: flaky because of a race in the test setup — serialized the fixture init"). This stops the next session's auditor or human reviewer from re-flagging the same failure mode without context. Routine "applied the obvious fix to the obvious error" cases don't need a comment — the diff is the explanation. Use `gh pr comment <M> --repo <owner/repo> --body "..."`; if it errors, log an advisory and continue — don't block the return on a comment failure. This is the fix-checks-only analog of issue-work mode's step 5.5 decision-context rule.

**Record a flake event in the cross-PR flake registry when you conclude a failure was a flake (issue #378, phase 1).** Each `fix-checks-only` worker handles flakes in isolation — none of them sees that the SAME test has flaked on N other PRs this week. The flake registry is the session-spanning record that surfaces the chronic pattern so it can be escalated rather than silently re-run forever. **Gate this on config: only record when `flake_registry.enabled == true`** in the effective config (it defaults to `false`, preserving pre-#378 behavior). When enabled, the orchestrator's dispatch prompt will say so; if you're unsure whether it's enabled, you can probe it yourself:

```bash
# Only record if the registry is enabled for this repo.
ENABLED=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
```

**When to record.** Record exactly one event per (workflow, job, test) failure that you concluded was a *flake* — a transient/environmental/race failure that was NOT a real defect in the PR's diff. Concretely: you re-ran the check (or pushed a no-op-equivalent flake-mitigation) and it went green without a substantive code fix that addressed a real bug, OR the failure log shows a known-flaky shape (timeout on a runner, `boundingBox()` returning null intermittently, network blip, runner cancellation). Do NOT record a real failure you fixed with a genuine code change — that's not a flake, it's a bug your PR introduced and corrected. The registry is for chronic *non-actionable-per-PR* flakes; polluting it with real-bug fixes defeats the escalation signal.

**How to record.** One call per flake event, before you return `green`. The `--test` field is optional — if you can pin the failure to a specific test ID (from the failing log), pass it; otherwise the event keys on workflow+job alone:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/flake-registry.sh" record \
  --repo <owner/repo> --pr <M> \
  --workflow "<workflowName>" --job "<failing job name>" \
  [--test "<test-id>"] --action rerun-failed
# If the record call errors (registry write failure, helper missing), log an
# advisory and continue — never block the `green` return on a registry write.
```

The registry lives at `~/.shipyard/flake-registry.jsonl` (one line per event). The orchestrator reads it at setup time via `flake-registry.sh crossed` and enforces the three escalation actions through `flake-enforce.sh enforce` (issue #385, phase 2): `file-tracking-issue` opens a deduped chronic-flake tracking issue, `stop-auto-rerunning` writes the crossed key to `.shipyard/flake-suspects.txt`, and `apply-blocked-ci` labels affected PRs. **Your recording job here is unchanged** — honestly record one event per flake conclusion when enabled. The *consumption* of those events now has two sides you participate in: (1) you record events (this section), and (2) you honor the `stop-auto-rerunning` output via the pre-rerun suspects check in [fix-loop step 1.5](#fix-loop) — refusing to keep auto-rerunning a flake a prior session escalated. The `file-tracking-issue` and `apply-blocked-ci` actions are performed by the orchestrator's setup-time enforce pass, not from this mode.

## Don't

- Don't open a new PR. The PR is already open; this mode repairs CI only.
- Don't modify the PR title or description.
- Don't close the linked issue from this PR. The original PR body already has the `Closes #N` line; merging the rebased branch closes the issue automatically.
- Don't add new tests or refactors. Fix only what's needed to turn the failing checks green.
- Don't keep trying past 3 fix attempts. The cap is a circuit breaker, not a suggestion.
- **Don't return `green #<M>` on the basis of a hypothesis.** "I rebased onto a commit that should fix this" is a hypothesis until CI confirms it. The contract is unambiguous: `green` means the rollup is fully `SUCCESS` (or `SKIPPED` / `NEUTRAL`) at the moment of return. If checks are still queued / running, you have not finished the fix-loop — keep watching, or return `blocked` if the 3-attempt cap is up. The orchestrator's step A reconcile spot-checks every `green` return against `gh pr view <M> --json statusCheckRollup` and will silently downgrade you to `pending` / `failing` if the rollup contradicts the claim. Returning `green` on a `PENDING` rollup wastes a turn and earns you a `[fix-checks-verify] downgraded` advisory in the orchestrator's log.
- **Don't return `green #<M>` without re-verifying the NAMED failing check flipped to SUCCESS** ([#416](https://github.com/mattsears18/shipyard/issues/416)). `--watch` exiting zero is necessary but not sufficient — it can exit on a stale pre-push rollup, and it says nothing about *which* check you fixed. If you concluded the failure was cause X, fixed X, and the real failing check Y is still red, you've misdiagnosed; returning `green` ships a false-green that nearly auto-merges a red PR. Re-probe the specific check(s) that were failing at dispatch on the post-push SHA per the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) — confirm each named check's latest run is SUCCESS AND the rollup head SHA matches your push — before you may claim `green`. The canonical trap: "fixing" the jest worktree-ignore "No tests found" artifact while the real failure is an i18n-parity test (`locales/en.json` missing keys) — two different checks; fixing the former never turns the latter green.
- **Don't return narrative status updates.** Strings like "waiting for monitor," "shard 2 still running," "routine progress, awaiting E2E," "unit tests pass, awaiting shards" are NOT acceptable terminal returns. The agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging a stale re-notification. The only acceptable terminal returns are the three documented strings: `green #<M>`, `noop: already green #<M>`, `blocked #<M> at fix-checks: <reason>`. If CI is still running and you'd otherwise return, keep the `gh pr checks <M> --watch --interval 30` foreground bash call alive instead — that blocks your own turn until the rollup resolves.
- **Don't return without `TaskStop`'ing any `Monitor` sub-tasks you spawned.** This mode is the canonical spawner of Monitors (watching shard rollups, polling for run completion) and the canonical victim of [#297](https://github.com/mattsears18/shipyard/issues/297)'s notification leak — workers returned `green`/`blocked`/`reaped:` and left their Monitors running, each one re-invoking the orchestrator for a no-op turn for the next 15–60 min. The worker-preamble's "Stop background processes before returning" section is the source of truth — it applies on EVERY termination path (clean returns, bails, reaps). If you only used the foreground `gh pr checks <M> --watch --interval 30` pattern (no `Monitor`, no `run_in_background: true` Bash), there's nothing to stop; the foreground command exits with your push and can't outlive the return.
- Don't `--no-verify` to skip hooks. Fix the underlying issue. (See worker-preamble for the absolute prohibition.)
- Don't disable a failing test to make checks pass. If the test is genuinely broken (not the code), comment on the PR with the evidence and return `blocked #<M> at fix-checks: <reason>`.
- Don't edit `.github/workflows/` or branch protection to make a check pass.
- **Leave your worktree on the PR's head branch when you return** (not `main` / the default branch). See worker-preamble's worktree discipline rule 3.
