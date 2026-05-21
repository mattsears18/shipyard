# Fix-main-ci mode (repo-level diversion)

The orchestrator sends this when the **earliest unfixed red run** on the default branch needs fixing. The dispatch prompt gives you `<earliest_red_run_id>`, `<earliest_red_run_url>`, `<earliest_red_sha>`, and the default branch name.

The single highest-leverage action is: identify the root cause and ship the smallest possible fix on its own PR. You do NOT close any issue and you do NOT batch multiple fixes — **one PR, one root cause.**

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-main-ci specifics.

## Inputs (from the dispatch prompt)

- `<earliest_red_run_id>` — the earliest unfixed red run on the default branch (where the red streak started).
- `<earliest_red_run_url>` — its URL, for the PR body.
- `<earliest_red_sha>` — the SHA the run was on, used to deterministically name the fix branch.
- Default branch name (e.g., `main`).
- Target repo `<owner/repo>`.

## Process

1. **Pre-flight: re-confirm main is still red.** State drifts between dispatch and you starting. Run:
   ```bash
   gh run list --repo <owner/repo> --branch <default-branch> --status completed --limit 1 \
     --json conclusion,databaseId
   ```
   If `conclusion == "success"` → return `noop: main already green`. Don't open a PR.

2. **Pull failed logs from the earliest red run:**
   ```bash
   gh run view <earliest_red_run_id> --repo <owner/repo> --log-failed
   ```
   The earliest red run gives you the *first* failure mode — the one most likely to be the root cause, not a downstream symptom. Newer red runs may have cascading failures that go away once you fix the earliest one.

3. **Triage the failure.** Categorize before fixing:
   - **Code regression** — a commit broke a test or build. Fix the code.
   - **Test infrastructure** — flaky CI, expired secret, broken external service. If the root cause is structural (the underlying infra needs human intervention to fix — rotate a secret, ask the vendor, upgrade a runner image), return `blocked main-ci-fix: <reason>`. Don't paper over it.
   - **Snapshot/fixture drift** — accept the snapshot update IF you can verify the new output is actually correct from the diff. Otherwise return `blocked`.
   - **Dependency update** — pin or patch the bad version with a comment explaining why.

4. **Sync + branch.** You're already in your isolated worktree:
   ```bash
   git fetch origin
   git checkout -B do-work/fix-main-ci-<short-sha> origin/<default-branch>
   ```
   `<short-sha>` is the first 7 chars of `<earliest_red_sha>` so the branch name is deterministic across re-dispatches.

5. **Implement the smallest fix.** No drive-by refactors. If the test suite has changed since the red run, run it locally to confirm your fix actually addresses the right failure.

6. **Commit + push + PR:**
   ```bash
   git add <specific paths>
   git commit -m "fix(ci): restore green main — <one-line root cause>"
   git push -u origin do-work/fix-main-ci-<short-sha>

   gh pr create --repo <owner/repo> \
     --label shipyard \
     --title "fix(ci): restore green main — <one-line root cause>" \
     --body "$(cat <<'EOF'
   Restores green CI on `<default-branch>`. Earliest unfixed red run: <earliest_red_run_url> at <earliest_red_sha>.

   ## Root cause
   <2-3 sentences>

   ## Fix
   <what changed and why this is minimal>

   ## Test plan
   - [ ] CI on this PR is green
   - [ ] Manual reproduction: <if applicable>
   EOF
   )"
   ```
   No `Closes #N` line — this is a synthetic divert, not tied to an issue. The `--label shipyard` is required by the worker-preamble skill.

7. **Enable auto-merge, snapshot, return.** Follow the auto-merge + snapshot + return pattern from the worker-preamble skill:

   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   gh pr view <pr-num> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
   ```

   Synthetic diverts have no `originating_author_trust` field — they're not scoped to an issue author. Always arm auto-merge directly; never gate on trust.

8. **Return one line:**
   - `shipped main-ci-fix via PR #<M> (auto-merge: enabled, checks: <green|pending|failing>)`
   - `noop: main already green` — pre-flight (step 1) found green.
   - `blocked main-ci-fix: <reason>` — structural failure or root cause requires human judgment.

## Hard rules

- **One PR per dispatch.** Do not open multiple PRs to address multiple symptoms. If you spot more than one issue, fix the earliest red run only; the orchestrator's next step-D refresh will re-dispatch a new fix-main-ci agent if main is still red after this PR merges.
- **No issue to close.** Synthetic diverts don't reference an issue number — omit `Closes #N` from the PR body.
- **No drive-by scope.** Touch only the file(s) needed to land main back to green.
- **Leave your worktree on `do-work/fix-main-ci-<short-sha>` when you return** (not `main` / the default branch). See worker-preamble's worktree discipline rule 3.

## Don't

- Don't open a PR if pre-flight found main green. Return `noop: main already green` and exit — opening a PR just to find out CI passes wastes an orchestrator turn.
- Don't paper over infrastructure failures with code changes that look like fixes. If a secret has expired or an external service is down, the only correct action is `blocked main-ci-fix: <reason>` — let a human rotate the secret or call the vendor.
- Don't expand scope. The temptation in this mode is "while I'm here, let me also fix this other thing I noticed." Resist — every extra change increases the chance the PR doesn't land cleanly, and the orchestrator will run again to pick up the other things.
- Don't `--watch` checks. Snapshot once and return; orchestrator triage owns failure recovery.
- Don't accept a snapshot update unless you can verify the new output is correct from the diff alone. If you can't, return `blocked` — speculative snapshot acceptance silently corrupts the test signal.
