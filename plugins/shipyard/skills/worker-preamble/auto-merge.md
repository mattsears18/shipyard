# Worker-preamble fragment — Auto-merge + snapshot-and-return pattern

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode opens a PR and needs the auto-merge / snapshot / return categorization — issue-work, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate (fixable path), and the fix-checks-only snapshot. The mode-specific per-file specs under `agents/issue-worker/` point here by name (`worker-preamble § "Auto-merge + snapshot-and-return pattern"`).

## Auto-merge + snapshot-and-return pattern

After `gh pr create` returns:

0.5. **First, decide whether this PR is on the ungated admin-direct-merge path — and if so, wait for the PR's own checks before merging instead of merging ungated ([#598](https://github.com/mattsears18/shipyard/issues/598)).** The `merged-direct-ungated` advisory in step 1.5 (from [#457](https://github.com/mattsears18/shipyard/issues/457)) is a *post-hoc* signal: by the time you can read `state: MERGED`, the merge has already fired and an ungated red has potentially already reached the default branch. On the repos shipyard is dogfooded against (`mattsears18/shipyard`, `mattsears18/mattsears18.com` — admin dispatcher + no required status checks, *regardless of whether `allow_auto_merge` is `false` (#438) or `true` (#465)*) that post-hoc path is the *common* case, not the edge case, so a pre-merge wait recovers a gate that already exists (the PR's own CI) instead of fixing `main` forward after the fact. The #598 repro: PR #596 (a README refresh) admin-direct-merged ungated, dropped the `decompose-epic.md` substring that `decompose-epic.test.sh` asserts, reddened `main`, and cost a whole second PR (#597) + a ~9-minute red-`main` window to fix forward — a regression the PR's *own* checks (which completed ~53s after merge) would have gated for free.

   **Run the detector as a script — don't re-derive the condition ([#716](https://github.com/mattsears18/shipyard/issues/716)).** The rule below is implemented once, executably, in [`scripts/detect-ungated-admin-direct-merge.sh`](../../scripts/detect-ungated-admin-direct-merge.sh). Call it and branch on the verdict:

   ```bash
   VERDICT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" <owner/repo>)
   # `ungated` => do NOT arm --auto; --watch the PR's checks, merge only if green.
   # `gated`   => --auto genuinely queues behind CI; arm it (step 1 below).
   ```

   The script is the **single source of truth** for this decision. It exists because the condition previously lived as prose in both this fragment and `agents/issue-worker/issue-work.md` step 6, and the two copies drifted into contradicting each other — issue-work.md claimed the gate only fires on `allow_auto_merge: false` and named "repo allows auto-merge" as a *skip* condition, so a worker that read that file (rather than this fragment) skipped the gate entirely and admin-direct-merged ungated (the #716 repro: PR #715 landed while CI was `IN_PROGRESS`; its sibling PR #713, whose worker loaded this fragment, correctly held). **Never restate this condition in prose in a third place.** The remainder of this section documents *what the script implements* and why — it is the reference explanation, not a second implementation to hand-execute.

   Read the three signals **before** arming auto-merge — the two-shape test below combines them (it does NOT require all three; shape 2 fires on `(b)` + `(c)` alone, regardless of `(a)`):

   ```bash
   # (a) repo-level auto-merge flag (shape 1 keys on this being OFF; shape 2 ignores it).
   #     NOTE: the allow-auto-merge flag is NOT exposed by `gh repo view --json`
   #     (there is no autoMergeAllowed field there) — read it from the REST repo
   #     object as `.allow_auto_merge`.
   ALLOW_AUTO_MERGE=$(gh api "repos/<owner/repo>" --jq '.allow_auto_merge')
   # (b) the dispatching user has admin/maintain on the repo (so the direct merge is permitted), and
   VIEWER_PERM=$(gh repo view <owner/repo> --json viewerPermission --jq '.viewerPermission')
   # (c) the PR's base branch has NO required status checks (so a direct merge fires before CI completes).
   #     On an UNPROTECTED branch this endpoint 404s — the `2>/dev/null` drops the
   #     error body and the integer guard normalizes any non-numeric result to 0.
   DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
   REQUIRED_CHECKS=$(gh api "repos/<owner/repo>/branches/${DEFAULT_BRANCH}/protection/required_status_checks/contexts" \
     --jq 'length' 2>/dev/null)
   case "${REQUIRED_CHECKS}" in (*[!0-9]*|'') REQUIRED_CHECKS=0;; esac
   # Ruleset-aware fallback (#645). Classic branch protection (the contexts
   # endpoint above) and repository RULESETS are two SEPARATE gating mechanisms;
   # the contexts probe only sees CLASSIC protection. On a repo whose default
   # branch is gated by a *ruleset* (GitHub Rulesets — increasingly the default
   # shape), the classic probe returns 0 contexts even though the branch IS
   # gated: a false "ungated" reading that would mis-fire shape 2 and send the
   # worker into an unnecessary --watch-then-merge block. So when the classic
   # probe reads 0, ALSO probe the rulesets endpoint for a `required_status_checks`
   # rule; if one is active, the branch IS gated on CI after all — set
   # REQUIRED_CHECKS to a non-zero sentinel so the two-shape test below does NOT
   # classify this as the ungated admin-direct path. NOTE: check ONLY for the
   # `required_status_checks` rule type here, NOT `pull_request` — a `pull_request`
   # ruleset rule requires the change arrive via a PR but does NOT gate the merge
   # on CI, so an admin `--auto` still direct-merges *immediately* (ungated) on a
   # repo whose ruleset has `pull_request` but no `required_status_checks` (the
   # `mattsears18/shipyard` shape: ruleset `[deletion, non_fast_forward,
   # pull_request]`). Including `pull_request` here would over-gate that shape —
   # falsely skipping the protective wait and allowing an ungated merge. (A
   # "can I direct-write to the branch" probe would instead check `pull_request`
   # — which a PR rule blocks — a different question from "will an admin --auto
   # land ungated", which only required status checks answer.)
   if [ "$REQUIRED_CHECKS" = "0" ]; then
     RULESET_GATED=$(gh api "repos/<owner/repo>/rules/branches/${DEFAULT_BRANCH}" \
       --jq '[.[].type] | contains(["required_status_checks"]) | tostring' \
       2>/dev/null || echo "false")
     case "$RULESET_GATED" in (true) REQUIRED_CHECKS=1;; esac   # ruleset requires status checks — gated, NOT ungated
   fi
   ```

   There are **two distinct shapes** that put the PR on the ungated admin-direct path — mirror the orchestrator-side two-shape detector in [`commands/do-work/setup.md` §1.3](../../commands/do-work/setup/01-repo-recovery.md#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) (issues [#438](https://github.com/mattsears18/shipyard/issues/438) / [#465](https://github.com/mattsears18/shipyard/issues/465)). The path is ungated when `VIEWER_PERM` is `ADMIN` or `MAINTAIN` **AND** either shape holds:

   - **Shape 1 (#438):** `ALLOW_AUTO_MERGE == false`. With repo-level auto-merge disabled, `gh pr merge --auto` has nothing to queue against, so an admin's call falls through to an immediate direct merge.
   - **Shape 2 (#465), which fires *regardless of `ALLOW_AUTO_MERGE`*:** `REQUIRED_CHECKS == 0`. Even with `allow_auto_merge: true`, when the base branch has zero *required* status checks `gh pr merge --auto` has no pending check to wait on — so an admin's call merges *immediately* rather than queuing behind CI. The original #438 detector missed this because it only checked `ALLOW_AUTO_MERGE == false`; the #465 repro (this dogfood repo, `allow_auto_merge: true` + admin + no required checks) is the now-current shape (see issue [#602](https://github.com/mattsears18/shipyard/issues/602)).

   > **Ruleset-aware `REQUIRED_CHECKS` reading (#645).** The signal-(c) `REQUIRED_CHECKS` count above comes from the **classic** branch-protection contexts endpoint, which does NOT see repository **rulesets**. A default branch gated by a *ruleset* (GitHub Rulesets, not classic protection) returns 0 from the contexts endpoint even though it requires checks — a false "ungated" reading that would mis-fire shape 2 on the now-common Rulesets-protected repo shape (the #645 repro: `mattsears18/lightwork` protects `main` via a ruleset requiring 4 checks, yet the classic contexts probe reports 0). The signal-(c) snippet closes this by probing `repos/{owner}/{repo}/rules/branches/{branch}` when the classic count is 0 and treating the branch as gated when an active ruleset has a `required_status_checks` rule. Treat the branch as gated if **either** classic protection **or** an active ruleset requires status checks. **Check only the `required_status_checks` rule, not `pull_request`** — a `pull_request` ruleset rule requires the change to arrive via a PR but does NOT gate the *merge* on CI, so an admin `--auto` still direct-merges immediately (ungated) on a ruleset that has `pull_request` but no `required_status_checks` (the `mattsears18/shipyard` shape). Including `pull_request` would over-gate that shape and falsely skip the protective wait. (A "can I direct-write to the branch" probe would instead check `pull_request` — a different question from "will an admin `--auto` land ungated".)

   ```bash
   # Two-shape ungated-path test (mirrors setup.md §1.3). VIEWER_PERM gates both.
   if { [ "$VIEWER_PERM" = "ADMIN" ] || [ "$VIEWER_PERM" = "MAINTAIN" ]; } \
      && { [ "$ALLOW_AUTO_MERGE" = "false" ] || [ "$REQUIRED_CHECKS" = "0" ]; }; then
     UNGATED_ADMIN_DIRECT=1   # shape 1 (#438) OR shape 2 (#465)
   fi
   ```

   When the two-shape test holds — this is the ungated admin-direct path. Do NOT fire `gh pr merge --auto --merge` (it would direct-merge immediately, ungated). Instead **block on the PR's own checks to settle, then merge only when green** — this is the one issue-work case where you DO `--watch`, because the merge gate the repo lacks must be re-created by the worker:

   ```bash
   # Block until the PR's checks settle (self-heartbeats on every interval tick — watchdog-safe).
   gh pr checks <pr-num> --repo <owner/repo> --watch --interval 30
   ```

   - If the checks settle **green**, merge now (the PR is gated by its own CI even though the repo's ruleset isn't): `gh pr merge <pr-num> --repo <owner/repo> --squash --delete-branch` (use the repo's configured merge method — `--merge`/`--squash`/`--rebase`; default to `--squash` only if the repo doesn't constrain it). **Report this outcome as `auto-merge: gated-manual` — never `merged-direct`** ([#734](https://github.com/mattsears18/shipyard/issues/734); see the callout immediately below step 1.5 for why the two tokens must not collapse into one). This merge never called `--auto`, so there is nothing for step 1 / step 1.5 to arm or categorize: skip both entirely and go straight to step 2's check-rollup snapshot (it will read `checks: green`, since the `--watch` above already confirmed it) and the step-3 return.
   - If the checks settle **red**, this is exactly the case the fix-checks loop exists for: do NOT merge a red PR. Hand it back via the mode's normal return (`shipped #<N> via PR #<M> (auto-merge: unavailable — needs manual merge, checks: failing)` for issue-work) so the orchestrator's reconcile dispatches a fresh fix-checks-only worker against it. Do NOT run the fix-loop inline — that's mode-switching, which the per-mode files forbid.

   When the two-shape test does NOT hold, skip this wait entirely and arm auto-merge normally (step 1 below). Concretely, the skip is correct only when **required status checks ARE configured** (`REQUIRED_CHECKS > 0`, so gh blocks the direct merge until they pass) **OR** the dispatcher lacks `ADMIN`/`MAINTAIN` (so the direct-merge fall-through isn't permitted and `gh pr merge --auto` queues normally). In those configurations `gh pr merge --auto` is genuinely gated — and if a real auto-merge queue forms after arming (`autoMergeRequest != null` in step 1.5's snapshot), it waits for green by design. Do NOT skip on `ALLOW_AUTO_MERGE == true` alone: an admin dispatcher on a repo with zero required checks is the #465 shape-2 ungated path even when auto-merge is enabled, so `allow_auto_merge: true` is *not* on its own sufficient to make the merge gated. The proactive wait fires on both ungated shapes it's meant to close.

   **`gated-manual` is the routine, correct outcome on this branch — not an anomaly.** Every PR that reaches this bullet gets `gated-manual`, exactly as every PR that reaches step 1 with a genuine queue gets `enabled`. Don't read the name as "something unusual happened"; it names *how* the merge was gated (the worker watched and merged by hand) rather than *whether* it was gated (it was).

1. Arm auto-merge (when the step-0.5 ungated-path check did NOT fire). Capture stderr into a local variable — step 1.1 below needs the text, not just the exit status:
   ```bash
   MERGE_ARM_ERR=$(gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch 2>&1 1>/dev/null) || true
   ```
   If the call errors because auto-merge isn't enabled at the repo level, **don't try to enable it** — that's a repo-config decision. Capture the error to a local variable but proceed to step 1.5 below — the call's exit status alone is NOT a reliable signal of the actual merge outcome (see issue [#340](https://github.com/mattsears18/shipyard/issues/340)).

1.1. **Detect the `workflow`-OAuth-scope cause and name it distinctly — don't let it collapse into the generic `unavailable` ([#812](https://github.com/mattsears18/shipyard/issues/812)).** When the PR's diff touches `.github/workflows/`, GitHub blocks `enablePullRequestAutoMerge` for an OAuth-app token lacking the `workflow` scope, even though `repo` alone is sufficient for everything else the worker just did (`git push` uses a different credential path; `gh pr create` and a non-workflow `gh pr merge` don't touch this scope at all). The GraphQL error has a stable signature:

   ```
   GraphQL: Pull request refusing to allow an OAuth App to create or update workflow
   `.github/workflows/<file>.yml` without `workflow` scope (enablePullRequestAutoMerge)
   ```

   Match it case-insensitively against the captured error text:

   ```bash
   WORKFLOW_SCOPE_BLOCKED=0
   if printf '%s' "$MERGE_ARM_ERR" | grep -qi "without .workflow. scope"; then
     WORKFLOW_SCOPE_BLOCKED=1
   fi
   ```

   **Why this cause gets its own token instead of riding the generic `unavailable — needs manual merge` suffix.** The three things that can make `--auto` fail to arm want three different responses, and only one collapses cleanly into "manual merge, nothing more to say": repo-level auto-merge disabled is a repo-config decision (nothing to do); a transient `gh` failure is worth a retry; but a `workflow`-scope-missing token is a **deterministic, session-wide precondition** — every other workflow-touching PR this session (and `fix-main-ci` mode exists specifically to touch `.github/workflows/`) will hit the identical error, and no amount of per-PR retrying fixes it. Only a human running `gh auth refresh -h github.com -s workflow` once does. Lumping it into `unavailable` makes every occurrence look like an independent, unexplained failure instead of one root cause with one fix.

   When `WORKFLOW_SCOPE_BLOCKED=1`, skip the generic step 1.5 categorization below entirely — the outcome is fixed, not read off `gh pr view`: report **`auto-merge: unavailable — gh token lacks workflow scope`** as the return-string suffix (see [issue-work.md step 8](../../agents/issue-worker/issue-work.md#8-return) for the exact line). Everything else about the `unavailable` path is unchanged — the PR is left OPEN and unarmed, step 2's check-rollup snapshot still runs for the `checks:` suffix, and you still never attempt to escalate your own token's scope (that's a human action, not something to route around).

1.5. **Re-snapshot the PR's actual state before categorizing the auto-merge outcome.** Skip this step when step 1.1 already set `WORKFLOW_SCOPE_BLOCKED=1` — the outcome is already decided. Closes [#340](https://github.com/mattsears18/shipyard/issues/340) — `gh pr merge --auto` does NOT always error when `allow_auto_merge: false` is set at the repo level. When the dispatching user has admin permissions on a repo with auto-merge disabled, `gh` **silently falls through to a direct merge**: the PR lands immediately (if CI is green) or queues for merge (if pending). The call returns exit 0, `autoMergeRequest` is `null` because no auto-merge was armed, and a worker that decides the auto-merge outcome from the call's exit status alone returns `auto-merge: unavailable — needs manual merge` even when the PR is already `state: MERGED`. Repro: 5 PRs in a 26-PR session against `mattsears18/mattsears18.com` (`allow_auto_merge: false`) all returned `unavailable` despite landing as MERGED.

   The right check is to read both `state` and `autoMergeRequest` directly:

   ```bash
   gh pr view <pr-num> --repo <owner/repo> --json state,autoMergeRequest \
     --jq '{state, autoMerge: (.autoMergeRequest != null)}'
   ```

   Categorize into one of three base `auto-merge:` values for the return-string suffix:
   - `.autoMerge == true` → **`auto-merge: enabled`** (queued; auto-merge armed and waiting on checks)
   - `.state == "MERGED"` → **`auto-merge: merged-direct`** (gh's `--auto` call silently direct-merged because the repo has `allow_auto_merge: false` but the dispatching user has admin permissions; PR is already landed) — but see the `merged-direct-ungated` refinement below, which splits this case by whether CI had actually completed at merge time
   - Otherwise (`.state == "OPEN"` AND `.autoMerge == false`) → **`auto-merge: unavailable — needs manual merge`** (the call genuinely failed and no merge happened). This bucket is for the generic/transient/repo-config case only — a `workflow`-scope-missing failure is caught by step 1.1 *before* this categorization runs and reports the distinct `unavailable — gh token lacks workflow scope` token instead ([#812](https://github.com/mattsears18/shipyard/issues/812)); don't re-derive that distinction here from the plain `state`/`autoMergeRequest` read, which can't tell the two causes apart.

   **This categorization block runs only on the step-1 `--auto` path — never on the step-0.5 `gated-manual` branch ([#734](https://github.com/mattsears18/shipyard/issues/734)).** Two structurally different events both leave the PR at `state: MERGED` with `autoMergeRequest: null`, and `gh pr view`'s snapshot alone cannot tell them apart: (1) the step-0.5 detector correctly identified an ungated repo shape, the worker itself blocked on `gh pr checks --watch` until green and then merged by hand — the missing gate was re-created, nothing was skipped; (2) the step-1 `--auto` call was armed because the detector said `gated`, but `gh` still silently fell through to an immediate direct merge — a misprediction, and exactly the [#716](https://github.com/mattsears18/shipyard/issues/716) regression shape this detector exists to catch. If the worker source-of-truth for which branch fired isn't tracked separately, both events collapse onto the identical `merged-direct` token and the reconciler loses the one signal that would reveal case (2) — the failure mode reported in [#734](https://github.com/mattsears18/shipyard/issues/734), where 2 of 3 workers on the same session reported a correctly-gated manual merge with the same vocabulary a genuine ungated-merge regression would use. **The fix is procedural, not a new API read: track which branch you took.** If you executed the step-0.5 green-checks merge, you already know the outcome is `gated-manual` — return that token directly and skip this categorization block. Only fall through to `merged-direct`/`merged-direct-ungated`/`enabled`/`unavailable` when you actually called `gh pr merge --auto` in step 1. Reaching `merged-direct` (or `merged-direct-ungated`) on a PR where step 0.5's detector returned `ungated` means the manual-merge branch was skipped somehow — treat that as a #716-class regression worth flagging loudly, not a routine outcome.

   **The `merged-direct` ⇒ `merged-direct-ungated` refinement (issue [#457](https://github.com/mattsears18/shipyard/issues/457)).** `merged-direct` only means "gh direct-merged this PR instead of queuing it." It does NOT, on its own, mean CI gated the merge. The admin-direct-merge fall-through respects the repo's **required status checks**: if the repo has required checks configured, gh blocks the direct merge until they pass (so the landed PR was green at merge time). But on a repo with **no required status checks**, the direct merge fires *immediately* — landing the PR while its checks are still `IN_PROGRESS`/`QUEUED`. The "auto-merge waits for green" guarantee silently does not hold in that configuration; if the post-merge build then fails on the default branch, `main` goes red with no PR-level gate having caught it. Repro: session `do-work-20260601T004608Z` against `mattsears18/mattsears18.com` (dispatcher is repo admin; no required checks) landed all 25 issue-work PRs (#182–#210) as `merged-direct` while their `build` check was still `IN_PROGRESS`.

     **Split `merged-direct` by the check rollup you snapshot in step 2:**
     - `merged-direct` AND step-2 rollup categorizes as `checks: green` → keep **`auto-merge: merged-direct`** (CI had completed and was green at merge time — the merge was effectively gated, whether by required checks or by happening to land after CI finished). Informational only.
     - `merged-direct` AND step-2 rollup categorizes as `checks: pending` or `checks: failing` → emit **`auto-merge: merged-direct-ungated`** instead (the PR landed before CI completed; nothing gated it). This is a *loud advisory*: the merge commit is already on the default branch and its build may yet flip `main` red. The orchestrator's reconcile treats `merged-direct-ungated` as a signal to refresh its main-CI watch (the existing [step 4.5a main-CI divert](../../commands/do-work/setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) machinery), so a post-merge red is caught by a `fix-main-ci` divert rather than going unnoticed. **With the step-0.5 proactive wait ([#598](https://github.com/mattsears18/shipyard/issues/598)) in place, `merged-direct-ungated` should now be rare** — step 0.5 catches the ungated admin-direct configuration *before* the merge fires and holds for the PR's checks, so a PR only lands ungated when step 0.5's detection couldn't apply (e.g. the merge raced a config change, or `gh` direct-merged despite a non-admin/required-checks reading). This refinement remains the **defense-in-depth backstop** for exactly those residual cases the pre-merge wait can't cover — do NOT remove it on the assumption step 0.5 handles everything.

   The `merged-direct` distinction is informational; the `merged-direct-ungated` distinction is the one piece of *behavioral* signal in this suffix — it tells the orchestrator a PR landed ungated so it can watch main CI for the fallout. Both still ride the `shipped #<N> via PR #<M> (auto-merge: ..., checks: ...)` return shape; neither blocks the worker. A `merged-direct`/`merged-direct-ungated` PR must never be surfaced to the user as "needs manual merge" friction — it's already landed.

2. Snapshot the current check-rollup state with a single `gh pr view <M> --json statusCheckRollup,mergeStateStatus`. This is a **one-shot read for the return string, never a wait** — don't `--watch` CI, and don't *wait* on a backgrounded CI-watch either, in any mode except **fix-checks-only** (see `worker-preamble § "Return-contract discipline"` rule 2 / [#707](https://github.com/mattsears18/shipyard/issues/707)): the commit / push / PR-open never gates on a CI result, so the snapshot reflects whatever state CI is in *at this instant* and the worker returns immediately regardless of `checks: green|pending|failing`. The orchestrator's per-iteration PR triage owns failure recovery on a periodic refresh; blocking on `--watch` (or stalling on a background watcher before returning) would tie up your agent and its concurrency slot for the full CI duration (often 5–20 min) for no gain. **Categorize the latest run per check name** (issue [#333](https://github.com/mattsears18/shipyard/issues/333) — `statusCheckRollup` returns every check run for the head SHA, including superseded runs; a stale FAILURE entry from an earlier run that's since been re-triggered and now passes would otherwise mis-categorize a `green` rollup as `failing`):

   ```bash
   gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus --jq '
     {mergeStateStatus: .mergeStateStatus,
      checks: [.statusCheckRollup
               | group_by(.name)
               | map(sort_by(.completedAt // .startedAt // "") | last)
               | .[] | {name, conclusion: (.conclusion // null), status: (.status // null)}]}'
   ```

   Then categorize the `checks` array:
   - All entries `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup, no checks configured) → `checks: green`.
   - Any entry `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → `checks: failing`.
   - Otherwise (`QUEUED` / `IN_PROGRESS` / `PENDING`) → `checks: pending` (the normal case right after push).

   The `group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last)` reduction is load-bearing — it collapses N entries per check name to 1 (the most recent), so a stale FAILURE entry that's been superseded by a later SUCCESS doesn't trip the `failing` categorization. The `(.conclusion // .status)` test pattern is what the orchestrator's reconcile path uses too; using it here keeps the worker's snapshot categorization and the orchestrator's trust-but-verify spot-check in sync.

   **Note:** if step 1.5 categorized as `merged-direct`, the PR is already on the default branch and the rollup snapshot reflects the post-merge merge-commit's checks. On a repo with **required status checks** the merge couldn't have landed until they passed, so expect `checks: green`. On a repo with **no required checks** the admin direct-merge fires *before* CI completes, so the rollup is commonly `checks: pending` (or, if a check has already failed, `checks: failing`) — that is exactly the `merged-direct-ungated` case from step 1.5's refinement, and the step-2 rollup is what decides between the two suffixes. Run the categorization regardless; don't assume `green`.

3. Return one line in the mode-specific format the dispatching prompt specifies.

**Exception — fix-checks-only mode (and the issue-work step-0.5 ungated-merge wait).** fix-checks-only is the primary place you DO block on `gh pr checks <M> --watch --interval 30`, because resolving a known-failing PR is the agent's entire job. See `agents/issue-worker/fix-checks-only.md` for the full fix-loop semantics. Returning `green #<M>` from fix-checks-only mode is a load-bearing claim — the rollup must be fully `SUCCESS` at the moment of return, not "pushed and queued." The **issue-work step-0.5 ungated-merge wait** ([#598](https://github.com/mattsears18/shipyard/issues/598)) is the one *other* place a `--watch` block is correct: on the admin + `allow_auto_merge: false` + no-required-checks path the worker must re-create the missing merge gate by waiting for the PR's own checks to settle before merging. Both are watchdog-safe — `gh pr checks --watch --interval 30` emits a status table on every tick, so it self-heartbeats (see `worker-preamble § "Heartbeat emission around long-running commands"` in [`ci-pitfalls.md`](./ci-pitfalls.md)). Outside those two cases the no-`--watch` rule stands: don't block on CI just to report it.
