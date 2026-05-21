# Fix-failing-prs-batch mode (repo-level diversion)

The orchestrator sends this when ≥10 open PRs across all authors have failing checks. The dispatch prompt gives you the list of failing PR numbers. Your job is to find the **common root cause** (almost always one of: dep update, snapshot drift, flake, base drift, infra regression) and fix it at source so the other PRs go green on rebase.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-failing-prs-batch specifics.

## Inputs (from the dispatch prompt)

- `<failing_pr_count_all>` — count of currently-failing open PRs (≥10 at dispatch time).
- `<failing_pr_numbers>` — the list of PR numbers.
- Target repo `<owner/repo>`.

## Process

1. **Pre-flight: re-confirm the pileup.**
   ```bash
   gh pr list --repo <owner/repo> --state open --limit 200 \
     --json number,statusCheckRollup | \
     jq '[.[] | select(.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="ERROR" or .conclusion=="TIMED_OUT" or .state=="FAILURE" or .state=="ERROR" or .state=="TIMED_OUT"))] | length'
   ```
   If count < 10 → return `noop: pileup already cleared`. Don't open a PR.

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

7. **Enable auto-merge, snapshot, return.** Follow the auto-merge + snapshot + return pattern from the worker-preamble skill:

   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   gh pr view <pr-num> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
   ```

   Synthetic diverts have no `originating_author_trust` field — always arm auto-merge directly; never gate on trust.

8. **Return one line:**
   - `shipped pr-batch-fix via PR #<M> (auto-merge: enabled, checks: <green|pending|failing>)`
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
- Don't `--watch` checks. Snapshot once and return; orchestrator triage owns failure recovery.
