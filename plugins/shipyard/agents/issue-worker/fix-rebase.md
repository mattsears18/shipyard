# Fix-rebase mode (drain-phase stale-base PR)

The orchestrator dispatches this when the end-of-session [drain](../../commands/do-work.md#end-of-session-drain) finds an `@me` PR in `mergeStateStatus: DIRTY` with **no failing checks** — the PR is green-or-pending but its base is stale relative to the freshly-advanced default branch, so auto-merge won't fire until it's rebased onto current default.

This is intentionally a **light-touch** mode. You are NOT fixing failing tests. You are NOT modifying the PR's scope. You are NOT touching the PR title / description / linked issue. The single goal is to take the PR's branch, rebase it onto current default, push, and return — letting CI re-run on the rebased head and auto-merge land it.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-rebase specifics.

## Inputs (from the dispatch prompt)

- PR number `#M`.
- Head branch name `<headRefName>` — the orchestrator passes this so you don't have to look it up.
- Target repo `<owner/repo>`.

## Process

1. **Land on the PR's head branch** — the harness placed you on some placeholder branch. Use the safe two-step, do NOT use `gh pr checkout` (see worker-preamble's worktree discipline rule 2):
   ```bash
   HEAD_REF=$(gh pr view <M> --repo <owner/repo> --json headRefName -q .headRefName)
   git fetch origin "$HEAD_REF"
   git switch "$HEAD_REF"
   ```

2. **Pre-flight: confirm DIRTY is still the state.** State drifts between dispatch and you starting — another merge train tick may have already auto-merged this PR, or someone may have pushed a fix that resolved the dirty state, or new check failures may have appeared:
   ```bash
   gh pr view <M> --repo <owner/repo> --json mergeStateStatus,statusCheckRollup,state
   ```
   Bail before touching anything if:
   - `state != "OPEN"` → return `noop: PR #<M> already closed/merged`.
   - `mergeStateStatus in {"CLEAN", "HAS_HOOKS", "UNSTABLE", "BLOCKED"}` and not `DIRTY` → return `noop: not dirty (mergeStateStatus=<X>)`. Auto-merge will figure it out — don't churn the branch unnecessarily.
   - Any `statusCheckRollup` entry has `conclusion in {FAILURE, ERROR, TIMED_OUT}` → return `blocked rebase #<M>: PR has failing checks — needs fix-checks, not rebase`. The drain will route this through the normal fix-checks dispatcher.

   Only proceed when `mergeStateStatus == "DIRTY"` and there are no hard check failures.

3. **Fetch + rebase onto current default branch:**
   ```bash
   DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
   git fetch origin "$DEFAULT_BRANCH"
   git rebase "origin/$DEFAULT_BRANCH"
   ```

   The rebase either lands cleanly or stops on a conflict. Both paths are handled in step 4.

4. **Conflict triage.** If `git rebase` exits non-zero with conflicts, the conflict resolution policy is **trivial-or-bail**:

   - **Trivial conflicts that auto-resolve:** additive-only conflicts in shared docs / config where both sides only appended content and the merge can be reconstructed by concatenating both blocks. The canonical examples (any of these is fair game):
     - `CHANGELOG.md` — both sides added entries at the top. Take both: newer entry first (yours), then theirs, then the rest of the file. If both touched the same version's entry block, that's a non-trivial conflict — bail.
     - Append-only docs like `CLAUDE.md`, `README.md`, `E2E_TESTS.md`, `CONTRIBUTING.md` — both sides added new bullets/sections to the end (or to a non-overlapping section). Concat both, drop the conflict markers, no semantic merging required.
     - `ci.yml` shard matrix appends — both sides added an entry to an array literal. Concat the array entries, dedupe, no reordering.
     - Lockfiles (`package-lock.json` / `pnpm-lock.yaml` / `Cargo.lock` / `go.sum`) when the conflict is on dependency entries that both sides touched independently — **DO NOT manually resolve.** Instead re-run the package manager (`pnpm install` / `npm install` / `cargo update` / `go mod tidy`) inside the rebased worktree so the lockfile is regenerated against the rebased `package.json` / `Cargo.toml` / `go.mod`. If the regeneration succeeds and the result is committable, that counts as trivial; if the regeneration itself errors (incompatible peer deps, version pinning conflict, etc.) bail.

   - **Non-trivial conflicts — bail immediately:** anything where the merge requires semantic judgment about which side's change is correct or how they should compose. Examples:
     - Both sides modified the same function body / same imports block / same type definition.
     - One side renamed a file the other side modified.
     - Both sides edited the same JSON config key with different values.
     - Anything involving test fixtures or snapshots where you can't tell from the diff alone which output is right.

     For any non-trivial conflict, `git rebase --abort` to restore the branch to its pre-rebase state, then return `blocked rebase #<M>: <one-line conflict description, e.g. "merge conflict in src/auth.ts — both sides modified handleLogin">`. The orchestrator will leave the PR for human rebase and the drain will continue without it.

   The instinct to "just resolve it, the conflict looks small enough" is the failure mode this rule exists to prevent. If you have to read more than the conflict markers to figure out the right resolution, it's non-trivial. Bail.

5. **Verify the working tree is clean after resolution.** Every conflict was either auto-resolvable or you bailed in step 4. If you got here with `git status` showing nothing staged/unstaged but the rebase didn't complete, something is off — bail with `blocked rebase #<M>: rebase ended in inconsistent state`.

   ```bash
   git status --porcelain   # must be empty
   git rev-parse HEAD       # should NOT equal origin/$DEFAULT_BRANCH (you'd have nothing to push)
   ```

   If the rebase produced zero new commits because the branch was already a fast-forward of default (rare — would mean `mergeStateStatus` was lying), return `noop: not dirty (already fast-forward)`. No push needed.

6. **Push the rebased branch.** This is a fast-forward-incompatible operation (rebase rewrites commit SHAs), so a force push with lease is required:
   ```bash
   git push --force-with-lease origin "$HEAD_REF"
   ```

   `--force-with-lease` (not plain `--force`) refuses the push if someone else pushed to the branch between your `git fetch` and your `git push`. That's the safety net against clobbering a concurrent author push — bail with `blocked rebase #<M>: head branch moved during rebase — retry next session` if the lease check rejects.

7. **Return one line.** No `gh pr edit`, no `gh pr merge --auto` re-call (auto-merge was already armed when the PR was opened; rebasing doesn't un-arm it), no `--watch`. The drain phase's next per-poll snapshot will see the PR transition out of DIRTY:
   - `rebased #<M>` — rebase succeeded, branch was force-pushed, drain phase resumes monitoring it.
   - `noop: not dirty (<reason>)` — pre-flight (step 2) found the PR was no longer DIRTY by the time you started; reason is the actual `mergeStateStatus` or `state` value observed.
   - `blocked rebase #<M>: <reason>` — conflict was non-trivial, head branch moved under you, or some other deterministic failure. The drain will leave this PR alone for the rest of the session and surface it in the end-of-session summary as a still-DIRTY PR needing human attention.

## Hard rules

- One rebase attempt per dispatch. If the first attempt blocks, return `blocked` — do NOT retry. The drain will move on; a human (or the next session) can pick it up.
- Never `gh pr merge` manually. Auto-merge was armed when the PR was first opened (or by the orchestrator's reconcile after a fix-checks). Rebasing a green-or-pending PR is sufficient to re-arm the merge train; manual merging would skip the merge train's protection against last-second base drift.
- Never edit the PR's title, body, or labels. The PR's existing description references the original commits — a rebase preserves their content, not necessarily their SHAs, but the human-readable summary stays correct.
- Never close the linked issue from this dispatch. The PR's body already has the `Closes #N` line; merging the rebased branch closes the issue automatically.
- **Leave your worktree on the PR's head branch when you return** (not `main` / the default branch). See worker-preamble's worktree discipline rule 3.

## Don't

- **Don't resolve a non-trivial merge conflict.** The trivial-or-bail rule exists because rebase-mode dispatches happen during the drain phase, when the orchestrator is winding down and the goal is keeping the merge train moving — not authoring code. A merge conflict that requires reading more than the conflict markers is a signal that the rebase needs a human (or a fresh issue-mode dispatch in a future session). `git rebase --abort` and return `blocked rebase`. The instinct to "just figure out which side wins, it looks small" is the failure mode this rule prevents — semantic merges in a drain context don't have the test scaffolding or review attention they need to be correct.
- **Don't `gh pr merge` manually.** Auto-merge was armed when the PR was originally opened (in issue-work mode's step 6, or by the orchestrator's reconcile after a fix-checks-only dispatch). Force-pushing a rebased branch doesn't un-arm auto-merge — the next green CI run on the rebased head will trigger it. Manually calling `gh pr merge` would bypass the merge train's protection against last-second base drift; the auto path is what should resolve the PR.
- Don't `--watch` checks. Push the rebased branch, return one line, let the drain's next poll observe the state transition.
- Don't retry on `blocked rebase`. One dispatch, one rebase attempt — the drain doesn't re-dispatch within the same session.
