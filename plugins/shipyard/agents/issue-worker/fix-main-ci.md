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

7. **Enable auto-merge, snapshot, return.** Follow the auto-merge + snapshot + return pattern from the worker-preamble skill.

   **7.a — Run the ungated-admin-direct-merge pre-check FIRST, before any merge call ([#720](https://github.com/mattsears18/shipyard/issues/720)).** Do not type `gh pr merge` until this has returned. On repo shapes where `gh pr merge --auto` does **not** queue behind CI, it falls through to an *immediate direct merge* — landing your fix while its own checks are still `IN_PROGRESS`. **This mode is the sharpest case in the whole system:** your entire job is restoring a red default branch, so an ungated merge of an unverified fix is how a red-main window *compounds* instead of closing. The condition is a **script, not a rule for you to re-derive** — do not reason about `allow_auto_merge` yourself:

   ```bash
   VERDICT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo>)
   ```

   - **`VERDICT == "ungated"`** → **do NOT run `gh pr merge --auto`.** Re-create the missing merge gate by hand: block on the PR's own checks, then merge only if they settle green. This is the one case where this mode DOES `--watch` (it self-heartbeats on every tick, so it's watchdog-safe), and the block is affordable precisely because you own a dispatch slot — the orchestrator's loop is not waiting on your turn:

     ```bash
     gh pr checks <pr-num> --repo <owner/repo> --watch --interval 30
     ```

     - Checks settle **green** → merge now: `gh pr merge <pr-num> --repo <owner/repo> --merge --delete-branch` (use the repo's configured merge method).
     - Checks settle **red** → do NOT merge. Your fix did not work. Return the step-8 string with `checks: failing` so the orchestrator's triage dispatches a fix-checks-only worker against the PR. Do NOT run the fix-loop inline — that's mode-switching, which this file forbids.

   - **`VERDICT == "gated"`** → `--auto` genuinely queues behind CI. Arm it normally (7.b).

   **7.b — Arm auto-merge (only when 7.a returned `gated`), then snapshot:**

   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   gh pr view <pr-num> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
   ```

   Categorize the snapshot per `shipyard:worker-preamble` § "Auto-merge + snapshot-and-return pattern" (fragment [`auto-merge.md`](../../skills/worker-preamble/auto-merge.md)) — including the `merged-direct` → `merged-direct-ungated` refinement, which is the defense-in-depth backstop for a 7.a misprediction.

   Synthetic diverts have no `originating_author_trust` field — they're not scoped to an issue author. Never gate on trust. But **do** gate on 7.a: the trust gate and the ungated-merge gate are orthogonal, and skipping the latter is what [#720](https://github.com/mattsears18/shipyard/issues/720) exists to prevent.

8. **Return one line** — synchronously, after the work reaches its real end state. Per `shipyard:worker-preamble` § "Return-contract discipline" ([#529](https://github.com/mattsears18/shipyard/issues/529)), do NOT arm a `run_in_background` process / `Monitor` / background-waiter and return a non-terminal narrative (e.g. *"I'll wait for the notification"*) before it resolves — that reports the dispatch complete while the work is stranded. Block your own turn on the foreground command if you must wait, then return exactly one of:
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
- Don't `--watch` checks — **except** on the step-7.a `ungated` branch, which is the one sanctioned `--watch` in this mode (it re-creates the merge gate the repo lacks). Outside that branch: snapshot once and return; orchestrator triage owns failure recovery.
- **Don't arm `--auto` without running the step-7.a detector first.** On an ungated repo shape `--auto` is not a queue — it's an immediate merge, and it will land your unverified main-CI fix on the very branch you were dispatched to repair ([#720](https://github.com/mattsears18/shipyard/issues/720)).
- Don't accept a snapshot update unless you can verify the new output is correct from the diff alone. If you can't, return `blocked` — speculative snapshot acceptance silently corrupts the test signal.
