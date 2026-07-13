# Fix-failing-prs-batch mode (repo-level diversion)

The orchestrator sends this when ≥10 open PRs across all authors have failing checks. The dispatch prompt gives you the list of failing PR numbers. Your job is to find the **common root cause** (almost always one of: dep update, snapshot drift, flake, base drift, infra regression) and fix it at source so the other PRs go green on rebase.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-failing-prs-batch specifics.

## Inputs (from the dispatch prompt)

- `<failing_pr_count_all>` — count of currently-failing open PRs (≥10 at dispatch time).
- `<failing_pr_numbers>` — the list of PR numbers.
- Target repo `<owner/repo>`.

## Process

1. **Pre-flight: re-confirm the pileup.** Use the **latest-per-name projection** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)) so stale superseded check runs don't inflate the count.
   ```bash
   gh pr list --repo <owner/repo> --state open --limit 200 \
     --json number,statusCheckRollup \
     --jq '[.[] | select(
       [.statusCheckRollup
        | group_by(.name)
        | map(sort_by(.completedAt // .startedAt // "") | last)
        | .[]
        | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
       | length > 0)] | length'
   ```
   If count < 10 → return `noop: pileup already cleared`. Don't open a PR. (The `--jq` flag projects the response server-side on the gh-CLI boundary — no second `jq` subprocess, no full-JSON pipe to wrap and re-parse. Worker-preamble §"`gh` JSON discipline" covers the convention.)

   The `group_by(.name) | map(... | last)` reduction de-duplicates by check name and takes the most recent entry, so a PR whose only "failure" is a stale FAILURE entry superseded by a later SUCCESS is correctly filtered out — without it the pre-flight count would inflate by the number of PRs with re-triggered-and-now-green checks, and the worker would open an unnecessary "fix" PR for a pileup that had already cleared.

2. **Sample failing logs** — up to 5 PRs (representative mix: oldest, newest, a few middle). For each, grab the failing-check name and a 20-line log excerpt:
   ```bash
   gh pr checks <pr-num> --repo <owner/repo> --json name,state,conclusion,link
   gh run view <run-id> --repo <owner/repo> --log-failed | head -200
   ```

3. **Identify the common root cause.** Look for:
   - Same error message / stack frame across multiple PRs
   - Same failing test name across multiple PRs
   - Same job name failing (e.g., all Lint failures point to a tool version mismatch)
   - All PRs based on the same SHA that's stale relative to a fixed main
   - All PRs affected by the same dependency in `package-lock.json` / `pnpm-lock.yaml`

   If the failures DON'T share a root cause (it's actually N unrelated bugs), return `blocked pr-batch-fix: no common root cause — <N> independent failures, sample: PR #X (<err1>), PR #Y (<err2>)`. The orchestrator's fix-checks-only flow handles per-PR failures one at a time; that's the right mechanism when there's no shared cause.

4. **Sync + branch:**
   ```bash
   git fetch origin
   DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
   git checkout -B do-work/fix-pr-pileup-<short-timestamp> origin/$DEFAULT_BRANCH
   ```
   `<short-timestamp>` is `$(date +%Y%m%d-%H%M)` so the branch is unique per dispatch.

5. **Implement the source-level fix.** This is almost always small (re-pin a dep, update a snapshot baseline, fix a fixture, repair a CI config). If it isn't small, you've probably misdiagnosed — back up and re-triage.

6. **Commit + push + PR:**
   ```bash
   git add <specific paths>
   git commit -m "fix(ci): unstick <N> failing PRs — <one-line root cause>"
   git push -u origin do-work/fix-pr-pileup-<short-timestamp>

   gh pr create --repo <owner/repo> \
     --label shipyard \
     --title "fix(ci): unstick <N> failing PRs — <one-line root cause>" \
     --body "$(cat <<'EOF'
   Fixes the common root cause behind <N> currently-failing PRs. The affected PRs will go green when rebased.

   ## Root cause
   <2-3 sentences>

   ## Affected PRs (motivating sample)
   - #<a>, #<b>, #<c>, ... (full list in dispatch context)

   ## Fix
   <what changed and why it addresses the shared failure>

   ## Test plan
   - [ ] CI on this PR is green
   - [ ] Rebasing one affected PR onto this fix produces green CI on that PR
   EOF
   )"
   ```
   No `Closes #N` — this is a synthetic divert. The `--label shipyard` is required by the worker-preamble skill.

7. **Enable auto-merge, snapshot, return.** Follow the auto-merge + snapshot + return pattern from the worker-preamble skill.

   **7.a — Run the ungated-admin-direct-merge pre-check FIRST, before any merge call ([#720](https://github.com/mattsears18/shipyard/issues/720)).** Do not type `gh pr merge` until this has returned. On repo shapes where `gh pr merge --auto` does **not** queue behind CI, it falls through to an *immediate direct merge* — landing your source-fix while its own checks are still `IN_PROGRESS`. That is especially bad in this mode: your fix is the intended remedy for a ≥10-PR red pileup, so if it lands unverified and is wrong it doesn't just red `main` — it deepens the very pileup you were dispatched to clear. The condition is a **script, not a rule for you to re-derive** — do not reason about `allow_auto_merge` yourself:

   ```bash
   VERDICT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo>)
   ```

   - **`VERDICT == "ungated"`** → **do NOT run `gh pr merge --auto`.** Re-create the missing merge gate by hand: block on the PR's own checks, then merge only if they settle green. This is the one case where this mode DOES `--watch` (it self-heartbeats on every tick, so it's watchdog-safe), and the block is affordable precisely because you own a dispatch slot — the orchestrator's loop is not waiting on your turn:

     ```bash
     gh pr checks <pr-num> --repo <owner/repo> --watch --interval 30
     ```

     - Checks settle **green** → merge now: `gh pr merge <pr-num> --repo <owner/repo> --merge --delete-branch` (use the repo's configured merge method). **Report this in step 8 as `auto-merge: gated-manual` — never `merged-direct`** ([#734](https://github.com/mattsears18/shipyard/issues/734)); `merged-direct` names a different event (7.b's `--auto` call falling through unexpectedly) and this branch never calls `--auto`. Skip 7.b's categorization entirely — go straight to the step-8 return with `checks: green` (already confirmed by the `--watch` above).
     - Checks settle **red** → do NOT merge. Return the step-8 string with `checks: failing` so the orchestrator's triage dispatches a fix-checks-only worker against the PR. Do NOT run the fix-loop inline — that's mode-switching, which this file forbids.

   - **`VERDICT == "gated"`** → `--auto` genuinely queues behind CI. Arm it normally (7.b).

   **7.b — Arm auto-merge (only when 7.a returned `gated`), then snapshot:**

   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   gh pr view <pr-num> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
   ```

   Categorize the snapshot per `shipyard:worker-preamble` § "Auto-merge + snapshot-and-return pattern" (fragment [`auto-merge.md`](../../skills/worker-preamble/auto-merge.md)) — including the `merged-direct` → `merged-direct-ungated` refinement, which is the defense-in-depth backstop for a 7.a misprediction. This categorization applies only on this `gated` branch — it never runs on the 7.a `ungated`/`gated-manual` branch above ([#734](https://github.com/mattsears18/shipyard/issues/734)).

   Synthetic diverts have no `originating_author_trust` field — never gate on trust. But **do** gate on 7.a: the trust gate and the ungated-merge gate are orthogonal, and skipping the latter is what [#720](https://github.com/mattsears18/shipyard/issues/720) exists to prevent.

8. **Return one line** — synchronously, after the work reaches its real end state. Per `shipyard:worker-preamble` § "Return-contract discipline" ([#529](https://github.com/mattsears18/shipyard/issues/529)), do NOT arm a `run_in_background` process / `Monitor` / background-waiter and return a non-terminal narrative (e.g. *"I'll wait for the notification"*) before it resolves — that reports the dispatch complete while the work is stranded. Block your own turn on the foreground command if you must wait, then return exactly one of:
   - `shipped pr-batch-fix via PR #<M> (auto-merge: enabled, checks: <green|pending|failing>)`
   - `shipped pr-batch-fix via PR #<M> (auto-merge: gated-manual, checks: green)` — 7.a's detector returned `ungated`; you watched checks yourself and merged by hand (issue [#734](https://github.com/mattsears18/shipyard/issues/734)). This is the routine outcome on that branch, not an anomaly — never report it as `merged-direct`.
   - `noop: pileup already cleared` — count fell below 10 between dispatch and pre-flight.
   - `blocked pr-batch-fix: <reason>` — no common root cause, or the fix is too large for one PR.

## Hard rules

- **One PR per dispatch.** Even if the pileup has multiple distinct root causes, fix only the one that affects the most PRs (or the most actionable one) in this dispatch — the orchestrator's next step-D refresh will re-dispatch a new fix-failing-prs-batch agent if the pileup persists.
- **No common root cause → bail.** If your triage finds N unrelated failures, that's the wrong tool. Return `blocked pr-batch-fix: no common root cause — ...` and let the orchestrator's fix-checks-only flow handle them one at a time.
- **No issue to close.** Omit `Closes #N` from the PR body.
- **Leave your worktree on `do-work/fix-pr-pileup-<short-timestamp>` when you return** (not `main` / the default branch). See worker-preamble's worktree discipline rule 3.

## Don't

- Don't open a PR if pre-flight found the count below 10. Return `noop: pileup already cleared` and exit.
- Don't try to fix all failures in one PR. Pick the single shared root cause and fix it; the rebase cascade takes care of the rest.
- Don't ship a fix without sampling at least 2-3 representative PRs. A "fix" derived from one PR's log is just a fix-checks-only dispatch in disguise — and not even a particularly well-scoped one. The whole point of the batch dispatch is the cross-PR pattern.
- Don't expand scope. Re-pin a dep, update a snapshot baseline, fix a fixture, repair a CI config — those are the right shapes. If your "fix" is touching 20 files across multiple modules, you've misdiagnosed.
- Don't `--watch` checks — **except** on the step-7.a `ungated` branch, which is the one sanctioned `--watch` in this mode (it re-creates the merge gate the repo lacks). Outside that branch: snapshot once and return; orchestrator triage owns failure recovery.
- **Don't arm `--auto` without running the step-7.a detector first.** On an ungated repo shape `--auto` is not a queue — it's an immediate merge, and it will land your unverified batch fix on `main`, deepening the pileup you were dispatched to clear ([#720](https://github.com/mattsears18/shipyard/issues/720)).
