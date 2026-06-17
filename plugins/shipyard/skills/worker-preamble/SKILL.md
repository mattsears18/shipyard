---
name: worker-preamble
description: Shared worktree-discipline + dispatch-contract preamble for every `/shipyard:do-work` worker mode (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch). Dispatch prompts in `commands/do-work.md` reference this skill instead of inlining the same ~600-char preamble five times — one source of truth for worktree isolation rules, return-contract scaffolding, and the `--label shipyard` requirement. Closes [#107](https://github.com/mattsears18/shipyard/issues/107).
---

# Worker preamble (every `/shipyard:do-work` mode)

The contract every dispatched worker — regardless of mode — operates under. The orchestrator's per-mode dispatch prompts in `commands/do-work.md` reference this skill by name (`shipyard:worker-preamble`) instead of repeating the language verbatim. Mode-specific rules (branch naming, return strings, scope-expansion rules) stay in the per-mode dispatch prompt and in the dispatched agent's per-mode file (`agents/issue-worker/<mode>.md` — loaded by the thin entry router `agents/issue-worker.md` from the `mode:` field). This file owns only the shared ground rules.

## Worktree discipline (load-bearing)

You are running inside an **isolated git worktree**. Your initial working directory is the worktree path; the user's primary checkout lives at a different path and is strictly off-limits.

Three rules, no exceptions:

1. **Never `cd` outside your worktree.** Your tools (Bash, Edit, Read, Write) inherit cwd from your worktree. The moment you `cd` to anything else — including the user's primary checkout path — subsequent git/gh commands operate on whatever git directory is at that path, which can silently corrupt the user's checkout.
2. **Never use `gh pr checkout <M>`.** That command resolves to the cwd at call time and switches whatever working tree is there. If your cwd has drifted (or the harness mis-set it), `gh pr checkout` will move the user's primary HEAD without warning. Always use `git fetch origin <branch>` followed by `git switch <branch>` — those operate on the cwd's git context predictably and won't escape it.
3. **Never `git switch` to the repo's default branch (`main` / `master` / etc.) when your work is done.** The global "switch back to main when local work is done" rule is for the user's *primary* checkout, not your isolated worktree. Parking your worktree on `[main]` locks the user's primary out of `git switch main` (git enforces one-worktree-per-branch). Leave your worktree on your work branch — the orchestrator's cleanup phase handles the rest.

## Step-0 cwd fail-fast — assert you're actually in your worktree ([#486](https://github.com/mattsears18/shipyard/issues/486))

The three rules above assume your initial working directory **is** the isolated worktree. That assumption is normally true — but it is set by the **Claude Code harness**, not by shipyard, and an `isolation: "worktree"` dispatch can land with its process cwd **pinned to the PRIMARY checkout root** instead of the created worktree. When that happens, every git-mutating command you run targets the user's primary checkout, and on any repo with the global `enforce-worktree.sh` PreToolUse hook installed (the exact environment shipyard's worktree-isolation contract assumes) the hook hard-blocks your `git commit` as *"targets the PRIMARY checkout."*

**This is the [#486](https://github.com/mattsears18/shipyard/issues/486) failure mode, and it is catastrophic when undetected:** the worker runs the *entire* task — implements the fix, validates it, stages the diff — and only dies at the **final `git commit`**, after burning its whole run (the #486 repro: ~94 min of Opus on a single dispatch). The orchestrator can't rescue the staged work either (its own session may share the mispinned cwd; `EnterWorktree` refuses a subagent cwd override), so the validated work is recoverable only by a human-run commit out-of-band.

**Why shipyard can't fix the root cause.** The cwd is set by the harness's dispatch machinery, not by anything in this repo — shipyard cannot force an `isolation: "worktree"` dispatch's process cwd to the created worktree, nor pin the orchestrator session's cwd to its `orchestrator-<session-id>` worktree. Those are AC items (1) and (2) of [#486](https://github.com/mattsears18/shipyard/issues/486), and they are **harness-level, out of shipyard's control**. The in-repo mitigation is to **fail fast at step 0** so a mispinned dispatch returns immediately instead of after a full wasted run — this guard, plus a regression test, are the shipyard-implementable slice.

**The check — run it once, first thing, before any task work.** Compare your worktree toplevel against the repo's known worktree-vs-primary shape. A shipyard-orchestrated dispatch's cwd, when correct, resolves to a path under `.claude/worktrees/` (the worker's `agent-*` worktree or the orchestrator's `orchestrator-*` worktree). When the cwd is mispinned to primary, `git rev-parse --show-toplevel` resolves to the primary checkout root — which is the **parent** of `.claude/worktrees/`, and which `git rev-parse --git-common-dir` reveals because a linked worktree's `.git` is a *file* pointing at `<primary>/.git/worktrees/<name>`, whereas the primary's `.git` is a directory:

```bash
# Step-0 cwd fail-fast (#486). Run before implementing anything.
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"

# A linked worktree has a *separate* per-worktree git dir
# (<common>/worktrees/<name>) distinct from the common dir. The PRIMARY
# checkout has git-dir == git-common-dir. If they're equal, this cwd is a
# primary checkout, NOT an isolated worktree — the dispatch-isolation cwd
# override is wrong.
if [ -n "$TOPLEVEL" ] && [ "$(cd "$GIT_DIR" 2>/dev/null && pwd -P)" = "$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" ]; then
  echo "blocked: dispatch-isolation cwd override is wrong — my cwd ($TOPLEVEL) is a PRIMARY checkout, not an isolated worktree. An isolation: \"worktree\" dispatch was pinned to the primary checkout root (see #486). Every git-mutating command here would target the user's primary checkout and the enforce-worktree hook will block my final commit. Failing fast at step 0 instead of burning the full run. Re-dispatch required."
  exit 0
fi
```

The `git-dir == git-common-dir` equality is the load-bearing signal: it is true **only** for a primary checkout and false for every linked worktree, regardless of where under the tree the cwd sits, so it catches the mispin without hard-coding the primary's absolute path or assuming a `.claude/worktrees/` layout. (For an extra belt: a correct dispatch's toplevel contains `/.claude/worktrees/` — but the git-dir equality is the canonical test and the one the regression guard asserts.)

**Return `blocked:`, not `reaped:`.** The mispin is a deterministic property of *this* dispatch's cwd — re-running the identical dispatch could land the same wrong cwd, so it is not the retryable-infrastructure-noise case `reaped:` is reserved for. `blocked:` is correct: the orchestrator's reconcile classifies it as a refuse and applies `needs-human-review` (per [#521](https://github.com/mattsears18/shipyard/issues/521)), surfacing the harness-level misroute for a human (or a future harness fix) rather than silently re-enqueueing a dispatch that may misfire the same way. **This guard runs in every worker mode** — the catastrophic-wasted-run failure mode is identical whether the dispatch was issue-work, fix-checks-only, fix-rebase, fix-main-ci, or fix-failing-prs-batch, so it lives in the shared preamble rather than per-mode.

**When NOT to fire.** A correctly-pinned dispatch (cwd under `.claude/worktrees/agent-*` or `orchestrator-*`) has git-dir ≠ git-common-dir and sails through — the guard is a no-op on the normal path, one cheap `git rev-parse` pair. Running outside any orchestrated session (a human invoking a worker spec by hand in the primary checkout for testing) would trip it, which is correct: a worker spec is not meant to mutate the primary checkout.

## PR-creation contract

When opening a PR from any worker mode, every call **MUST** include:

```bash
gh pr create --repo <owner/repo> --label shipyard ...
```

The `shipyard` label is the orchestrator's session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it; omitting it makes the PR invisible to the orchestrator's own state machine. Add other mode-specific labels (e.g. `needs-human-review` for external-trust PRs) **alongside** `shipyard`, never as a replacement.

For issue-work mode the PR body MUST include a **closing keyword** — `Closes #<N>` (or `Fixes`/`Resolves #<N>`), case-insensitive, on its own line — so the issue auto-closes on merge. A **bare reference** (`Refs #<N>`, `Related to #<N>`, plain `#<N>`) does NOT register a closing link and leaves the issue OPEN forever after merge; the bare forms are reserved for *additional, non-resolving* issue mentions only. Repo-local "don't auto-close" conventions govern incidental references — they do NOT exempt the dispatched issue's resolving PR, which is the intended-close case (see `agents/issue-worker/issue-work.md` § "5. Commit + push + PR" and § "5.8 Post-PR-create closing-link verification" — issue [#481](https://github.com/mattsears18/shipyard/issues/481)). For synthetic diverts (fix-main-ci, fix-failing-prs-batch) there is no issue to close — omit the `Closes` line.

## Auto-merge + snapshot-and-return pattern

After `gh pr create` returns:

0.5. **First, decide whether this PR is on the ungated admin-direct-merge path — and if so, wait for the PR's own checks before merging instead of merging ungated ([#598](https://github.com/mattsears18/shipyard/issues/598)).** The `merged-direct-ungated` advisory in step 1.5 (from [#457](https://github.com/mattsears18/shipyard/issues/457)) is a *post-hoc* signal: by the time you can read `state: MERGED`, the merge has already fired and an ungated red has potentially already reached the default branch. On the repos shipyard is dogfooded against (`mattsears18/shipyard`, `mattsears18/mattsears18.com` — admin dispatcher + no required status checks, *regardless of whether `allow_auto_merge` is `false` (#438) or `true` (#465)*) that post-hoc path is the *common* case, not the edge case, so a pre-merge wait recovers a gate that already exists (the PR's own CI) instead of fixing `main` forward after the fact. The #598 repro: PR #596 (a README refresh) admin-direct-merged ungated, dropped the `decompose-epic.md` substring that `decompose-epic.test.sh` asserts, reddened `main`, and cost a whole second PR (#597) + a ~9-minute red-`main` window to fix forward — a regression the PR's *own* checks (which completed ~53s after merge) would have gated for free.

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
   ```

   There are **two distinct shapes** that put the PR on the ungated admin-direct path — mirror the orchestrator-side two-shape detector in [`commands/do-work/setup.md` §1.3](../../commands/do-work/setup.md#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config) (issues [#438](https://github.com/mattsears18/shipyard/issues/438) / [#465](https://github.com/mattsears18/shipyard/issues/465)). The path is ungated when `VIEWER_PERM` is `ADMIN` or `MAINTAIN` **AND** either shape holds:

   - **Shape 1 (#438):** `ALLOW_AUTO_MERGE == false`. With repo-level auto-merge disabled, `gh pr merge --auto` has nothing to queue against, so an admin's call falls through to an immediate direct merge.
   - **Shape 2 (#465), which fires *regardless of `ALLOW_AUTO_MERGE`*:** `REQUIRED_CHECKS == 0`. Even with `allow_auto_merge: true`, when the base branch has zero *required* status checks `gh pr merge --auto` has no pending check to wait on — so an admin's call merges *immediately* rather than queuing behind CI. The original #438 detector missed this because it only checked `ALLOW_AUTO_MERGE == false`; the #465 repro (this dogfood repo, `allow_auto_merge: true` + admin + no required checks) is the now-current shape (see issue [#602](https://github.com/mattsears18/shipyard/issues/602)).

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

   - If the checks settle **green**, merge now (the PR is gated by its own CI even though the repo's ruleset isn't): `gh pr merge <pr-num> --repo <owner/repo> --squash --delete-branch` (use the repo's configured merge method — `--merge`/`--squash`/`--rebase`; default to `--squash` only if the repo doesn't constrain it).
   - If the checks settle **red**, this is exactly the case the fix-checks loop exists for: do NOT merge a red PR. Hand it back via the mode's normal return (`shipped #<N> via PR #<M> (auto-merge: unavailable — needs manual merge, checks: failing)` for issue-work) so the orchestrator's reconcile dispatches a fresh fix-checks-only worker against it. Do NOT run the fix-loop inline — that's mode-switching, which the per-mode files forbid.

   When the two-shape test does NOT hold, skip this wait entirely and arm auto-merge normally (step 1 below). Concretely, the skip is correct only when **required status checks ARE configured** (`REQUIRED_CHECKS > 0`, so gh blocks the direct merge until they pass) **OR** the dispatcher lacks `ADMIN`/`MAINTAIN` (so the direct-merge fall-through isn't permitted and `gh pr merge --auto` queues normally). In those configurations `gh pr merge --auto` is genuinely gated — and if a real auto-merge queue forms after arming (`autoMergeRequest != null` in step 1.5's snapshot), it waits for green by design. Do NOT skip on `ALLOW_AUTO_MERGE == true` alone: an admin dispatcher on a repo with zero required checks is the #465 shape-2 ungated path even when auto-merge is enabled, so `allow_auto_merge: true` is *not* on its own sufficient to make the merge gated. The proactive wait fires on both ungated shapes it's meant to close.

1. Arm auto-merge (when the step-0.5 ungated-path check did NOT fire):
   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   ```
   If the call errors because auto-merge isn't enabled at the repo level, **don't try to enable it** — that's a repo-config decision. Capture the error to a local variable but proceed to step 1.5 below — the call's exit status alone is NOT a reliable signal of the actual merge outcome (see issue [#340](https://github.com/mattsears18/shipyard/issues/340)).

1.5. **Re-snapshot the PR's actual state before categorizing the auto-merge outcome.** Closes [#340](https://github.com/mattsears18/shipyard/issues/340) — `gh pr merge --auto` does NOT always error when `allow_auto_merge: false` is set at the repo level. When the dispatching user has admin permissions on a repo with auto-merge disabled, `gh` **silently falls through to a direct merge**: the PR lands immediately (if CI is green) or queues for merge (if pending). The call returns exit 0, `autoMergeRequest` is `null` because no auto-merge was armed, and a worker that decides the auto-merge outcome from the call's exit status alone returns `auto-merge: unavailable — needs manual merge` even when the PR is already `state: MERGED`. Repro: 5 PRs in a 26-PR session against `mattsears18/mattsears18.com` (`allow_auto_merge: false`) all returned `unavailable` despite landing as MERGED.

   The right check is to read both `state` and `autoMergeRequest` directly:

   ```bash
   gh pr view <pr-num> --repo <owner/repo> --json state,autoMergeRequest \
     --jq '{state, autoMerge: (.autoMergeRequest != null)}'
   ```

   Categorize into one of three base `auto-merge:` values for the return-string suffix:
   - `.autoMerge == true` → **`auto-merge: enabled`** (queued; auto-merge armed and waiting on checks)
   - `.state == "MERGED"` → **`auto-merge: merged-direct`** (gh silently direct-merged because the repo has `allow_auto_merge: false` but the dispatching user has admin permissions; PR is already landed) — but see the `merged-direct-ungated` refinement below, which splits this case by whether CI had actually completed at merge time
   - Otherwise (`.state == "OPEN"` AND `.autoMerge == false`) → **`auto-merge: unavailable — needs manual merge`** (the call genuinely failed and no merge happened)

   **The `merged-direct` ⇒ `merged-direct-ungated` refinement (issue [#457](https://github.com/mattsears18/shipyard/issues/457)).** `merged-direct` only means "gh direct-merged this PR instead of queuing it." It does NOT, on its own, mean CI gated the merge. The admin-direct-merge fall-through respects the repo's **required status checks**: if the repo has required checks configured, gh blocks the direct merge until they pass (so the landed PR was green at merge time). But on a repo with **no required status checks**, the direct merge fires *immediately* — landing the PR while its checks are still `IN_PROGRESS`/`QUEUED`. The "auto-merge waits for green" guarantee silently does not hold in that configuration; if the post-merge build then fails on the default branch, `main` goes red with no PR-level gate having caught it. Repro: session `do-work-20260601T004608Z` against `mattsears18/mattsears18.com` (dispatcher is repo admin; no required checks) landed all 25 issue-work PRs (#182–#210) as `merged-direct` while their `build` check was still `IN_PROGRESS`.

     **Split `merged-direct` by the check rollup you snapshot in step 2:**
     - `merged-direct` AND step-2 rollup categorizes as `checks: green` → keep **`auto-merge: merged-direct`** (CI had completed and was green at merge time — the merge was effectively gated, whether by required checks or by happening to land after CI finished). Informational only.
     - `merged-direct` AND step-2 rollup categorizes as `checks: pending` or `checks: failing` → emit **`auto-merge: merged-direct-ungated`** instead (the PR landed before CI completed; nothing gated it). This is a *loud advisory*: the merge commit is already on the default branch and its build may yet flip `main` red. The orchestrator's reconcile treats `merged-direct-ungated` as a signal to refresh its main-CI watch (the existing [step 4.5a main-CI divert](../../commands/do-work/setup.md#45-divert-checks-main-ci--pr-pileup) machinery), so a post-merge red is caught by a `fix-main-ci` divert rather than going unnoticed. **With the step-0.5 proactive wait ([#598](https://github.com/mattsears18/shipyard/issues/598)) in place, `merged-direct-ungated` should now be rare** — step 0.5 catches the ungated admin-direct configuration *before* the merge fires and holds for the PR's checks, so a PR only lands ungated when step 0.5's detection couldn't apply (e.g. the merge raced a config change, or `gh` direct-merged despite a non-admin/required-checks reading). This refinement remains the **defense-in-depth backstop** for exactly those residual cases the pre-merge wait can't cover — do NOT remove it on the assumption step 0.5 handles everything.

   The `merged-direct` distinction is informational; the `merged-direct-ungated` distinction is the one piece of *behavioral* signal in this suffix — it tells the orchestrator a PR landed ungated so it can watch main CI for the fallout. Both still ride the `shipped #<N> via PR #<M> (auto-merge: ..., checks: ...)` return shape; neither blocks the worker. A `merged-direct`/`merged-direct-ungated` PR must never be surfaced to the user as "needs manual merge" friction — it's already landed.

2. Snapshot the current check-rollup state with a single `gh pr view <M> --json statusCheckRollup,mergeStateStatus`. Don't `--watch` CI in any mode except **fix-checks-only**. The orchestrator's per-iteration PR triage owns failure recovery on a periodic refresh; blocking on `--watch` would tie up your agent and its concurrency slot for the full CI duration (often 5–20 min) for no gain. **Categorize the latest run per check name** (issue [#333](https://github.com/mattsears18/shipyard/issues/333) — `statusCheckRollup` returns every check run for the head SHA, including superseded runs; a stale FAILURE entry from an earlier run that's since been re-triggered and now passes would otherwise mis-categorize a `green` rollup as `failing`):

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

**Exception — fix-checks-only mode (and the issue-work step-0.5 ungated-merge wait).** fix-checks-only is the primary place you DO block on `gh pr checks <M> --watch --interval 30`, because resolving a known-failing PR is the agent's entire job. See `agents/issue-worker/fix-checks-only.md` for the full fix-loop semantics. Returning `green #<M>` from fix-checks-only mode is a load-bearing claim — the rollup must be fully `SUCCESS` at the moment of return, not "pushed and queued." The **issue-work step-0.5 ungated-merge wait** ([#598](https://github.com/mattsears18/shipyard/issues/598)) is the one *other* place a `--watch` block is correct: on the admin + `allow_auto_merge: false` + no-required-checks path the worker must re-create the missing merge gate by waiting for the PR's own checks to settle before merging. Both are watchdog-safe — `gh pr checks --watch --interval 30` emits a status table on every tick, so it self-heartbeats (see the heartbeat-emission section). Outside those two cases the no-`--watch` rule stands: don't block on CI just to report it.

## Return-contract discipline

Every worker mode's last line is the orchestrator's only signal of outcome. The valid terminal strings are mode-specific (see the dispatching prompt for the exact set), but three universal rules apply:

- **Run all work synchronously to a terminal state — NEVER arm a background process and return ([#529](https://github.com/mattsears18/shipyard/issues/529)).** You must NOT arm a `Bash` call with `run_in_background: true`, a `Monitor` sub-task, a `TaskCreate` background-waiter, or any other process that resolves *after* your turn ends, and then return before it resolves. Doing so is a contract violation with a specific, costly failure mode: the harness treats the assistant message ending your turn as a `status: completed` **even though the work is not done** — no commit, no pushed branch, no PR, a half-finished edit set — so the orchestrator records the dispatch as complete while the actual work is stranded mid-flight. The orchestrator's crash-aware reap + re-dispatch (A.0.5) recovers it, but at the full token cost of a wasted dispatch (the #529 repro burned ~145k tokens for zero output: a worker armed a background test-waiter against #522 and returned *"I have a background waiter armed … I'll wait for that notification"* — a non-terminal narrative — leaving #522 OPEN with no PR and 0 commits in its worktree). If you need to wait on a long-running command (a test suite, CI), **block your own turn on a foreground call** (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism; see the heartbeat-emission section for keeping a silent foreground command watchdog-safe) until you have a terminal string to return. The terminal string is emitted *after* the work reaches its real end state, never *instead of* finishing it. (This composes with — but is distinct from — the "Stop background processes before returning" section below: that section covers cleaning up a process you legitimately spawned mid-turn; this rule forbids using a backgrounded process *as your wait mechanism* and returning a non-terminal narrative in its place.)
- **No narrative status updates.** Strings like `"waiting for monitor"`, `"shard 2 still running"`, `"unit tests pass, awaiting E2E"`, `"routine progress"`, `"I'll wait for that notification"` are contract violations — the agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging stale state (and, per the rule above, a narrative emitted while a backgrounded process is still in flight strands the work as incomplete-but-reported-complete). Either return one of the documented terminal strings, or keep the foreground bash call alive (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism) until you have one to return.
- **`blocked: <reason>` is always available.** If you hit a real blocker before push (ambiguous scope, can't reproduce, conflict needs human judgment, 3-attempt fix-loop cap hit), return `blocked: <reason>` and exit. Don't burn the session on one issue.

## Heartbeat emission around long-running commands

The Claude Code harness runs a **stream watchdog** over each worker dispatch: if the worker emits no stream output (stdout/stderr) for ~600s, the harness concludes the agent has stalled, kills it, and the orchestrator gets back `status: failed / summary: Agent stalled: no progress for 600s (stream watchdog did not recover)`. The killed worker leaves an agent worktree behind for the next session's startup sweep to reap, and the failure path emits no `usage` block, so the burned tokens aren't attributed to any per-PR bucket (issue [#372](https://github.com/mattsears18/shipyard/issues/372) — observed in a `mattsears18/lightwork` drain-phase `fix-checks-worker` dispatch killed mid-`Web E2E Tests` shard).

The watchdog is correct for foregrounded LLM work — 600s of genuine silence from the model *is* a stall. It misfires on worker modes (especially **fix-checks-only**, which is the canonical victim because its whole job is babysitting CI) that shell out to commands which legitimately run for 5–15 minutes with **no intervening stream output**:

- `npm ci` / `npm install` against a cold cache,
- `gh run view <run-id> --log-failed > /tmp/log` (the redirect swallows all output — the watchdog sees zero stream bytes for the whole download),
- a test suite run that buffers output (`npm run test:e2e:web`, `npx lhci autorun`, `pytest -q`),
- `gh pr checks <M> --watch --interval 30` parked on a long E2E shard.

The watchdog keys on **stream output**, not on tool-call boundaries — a single Bash tool call that runs silently for 600s trips it even though the agent is making real progress. **The fix is to keep stream output flowing while a long-running command is in flight.** Three patterns, in order of preference:

1. **Don't redirect long-running command output to a file.** The single biggest offender is `... > /tmp/log` on a slow command — the redirect is exactly what starves the watchdog. Let the command stream to the terminal and `tee` if you also need the file:
   ```bash
   # BAD — silent for the whole download, trips the watchdog on a big failed-log fetch.
   gh run view "$run_id" --repo "$repo" --log-failed > /tmp/failed.log
   # GOOD — output streams to stdout (feeds the watchdog) AND lands in the file.
   gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tee /tmp/failed.log
   ```
2. **Prefer the streaming/progress form of the command.** `npm ci` already prints progress to stderr by default — do NOT silence it with `--silent` / `--quiet` / `> /dev/null` on the path where the watchdog is a risk. `gh pr checks <M> --watch --interval 30` emits a status table on every interval tick, so it self-heartbeats and never needs wrapping (this is why the fix-checks-only fix-loop is watchdog-safe as written). For a test runner that buffers, pass its line-reporter / non-quiet flag (`jest --verbose`, `pytest -v`, `vitest --reporter=verbose`) so each test result is a stream write.
3. **Wrap a genuinely-silent unavoidable command in a heartbeat loop.** When a command *must* run silently for minutes (a compile step with no progress output, a vendor CLI that only prints on completion), background it and emit a heartbeat line on an interval until it exits. The heartbeat lines are the stream output the watchdog needs:
   ```bash
   # Run the silent command in the background, emit a heartbeat every 60s until it finishes.
   slow_silent_command > /tmp/out.log 2>&1 &
   cmd_pid=$!
   while kill -0 "$cmd_pid" 2>/dev/null; do
     echo "[heartbeat] $(date -u +%H:%M:%S) — still running slow_silent_command (pid $cmd_pid)"
     sleep 60
   done
   wait "$cmd_pid"   # propagate the real exit status
   ```
   The `[heartbeat]` prefix is a convention, not a parsed sentinel — its only job is to be a stream write the watchdog can see. Keep the interval comfortably under the watchdog window (60s against a ~600s watchdog leaves a 10× margin); don't tighten it to the point of log spam.

**Scope.** This applies to *every* worker mode, but the high-risk surface is fix-checks-only (CI babysitting on E2E/Lighthouse-heavy repos) and fix-main-ci / fix-failing-prs-batch (which run the target repo's full test suite locally). issue-work workers usually checkpoint at natural tool-call boundaries often enough to self-heartbeat; the rule still applies if you run a long silent build or test step. **Do NOT** add busy-work `echo`s to *fast* commands — the heartbeat pattern is reserved for commands that can plausibly exceed the watchdog window with no natural output. Reflexive heartbeating everywhere is log noise that costs context tokens for no liveness benefit.

> **Not implementable from this repo: a tunable watchdog threshold.** Issue [#372](https://github.com/mattsears18/shipyard/issues/372) also floated a per-mode `stall_seconds` config knob (e.g. `workers.fix_checks_only.stall_seconds = 1200`). The 600s watchdog lives in the Claude Code **harness**, not in shipyard — shipyard can't read, raise, or disable it from a config file, so a config key would be an unenforceable no-op. The heartbeat contract above is the in-repo lever that actually moves the failure mode: it keeps the existing watchdog from firing rather than trying to change a threshold shipyard doesn't own.

## Stop background processes before returning

If your worker spawned anything that lives **outside** the foreground tool-call lifecycle — a `Monitor` sub-task watching CI, a `Bash` call with `run_in_background: true` (e.g. a long-tail `gh pr checks --watch` you backgrounded so you could keep working in parallel), a `TaskCreate` sub-Agent — **stop it explicitly before you emit your terminal return string**. These processes belong to your session's background pool, not your "main turn," so the harness does not auto-reap them when your final assistant message lands. Each one will keep firing notifications (`<result>Still waiting (check 8)...</result>`, `<result>All historical background tasks have completed...</result>`) for the rest of its internal max-runtime (Monitors: 15–60 min; backgrounded bash: until the command exits or the shell is killed), and **every notification re-invokes the orchestrator for a no-op turn** because the parent agent is the wake target for everything spawned underneath it. The lightwork session that filed [#297](https://github.com/mattsears18/shipyard/issues/297) accumulated 50+ stale wake events across two fix-checks-worker dispatches that left their Monitor sub-tasks running after returning.

Apply this rule on **every** termination path — clean `green` / `shipped` / `rebased` / `noop:` returns, `blocked: <reason>` bails, and even the `reaped: ...` escape hatch from the next section. The notification leak is independent of whether the worker succeeded; what matters is that the worker spawned something whose lifetime exceeds its turn.

Mechanism per tool family:

| What you spawned | How to stop it before returning |
|---|---|
| `Monitor` sub-task (any subscription) | `TaskStop` against the task id you got back from `TaskCreate` / `Monitor` |
| `Bash` with `run_in_background: true` | `KillShell` against the shell id from the background-call's response (or `BashOutput` if you need the final exit code first, then `KillShell`) |
| `TaskCreate` sub-Agent that's still running | `TaskStop` against its task id |
| Foreground `Bash` (no `run_in_background:`) — e.g. `gh pr checks <M> --watch` | **Nothing** — foreground bash blocks your turn until it exits, so it can't outlive the return |

If you never spawned any of the above, this section is a no-op — the foreground-only path (the default) is already clean. The rule is "if you spawned it, you stop it"; it is NOT "always call TaskStop defensively at the end of every dispatch."

If `TaskStop` / `KillShell` errors (the process already exited on its own, the id was wrong, etc.), log an advisory and continue — the goal is best-effort cleanup, not blocking your return on a stop call that races against a process that was already done.

## Worktree-reaped escape hatch

The orchestrator's end-of-session cleanup reaps `.claude/worktrees/agent-*` directories. It liveness-checks the lock-holding PID before reaping, but defense in depth: an agent whose worktree IS reaped mid-run must NOT silently fall through to operating in the primary checkout.

**Bash-tool isolation — the gotcha that makes the naïve pattern wrong.** Each `Bash` tool call spawns a fresh shell. Variables you set in one call (including `export`-ed ones) **do not survive** into the next call — the harness does not share shell state across invocations. A pattern that reads "save once at session start, check before each write" works fine in an interactive terminal but trips the very guard it's meant to enforce when run through the Bash tool: the first write-class call after some intervening read-only calls finds `$WORKTREE_PATH` empty, the `! -d ""` check is true, and the worker emits a false-positive `reaped:` exit on its first commit ([#322](https://github.com/mattsears18/shipyard/issues/322)).

**Re-derive `WORKTREE_PATH` at the top of every write-class Bash call.** One extra line per call, no cross-call state assumption. Apply before every `git commit`, `git push`, `gh pr create`, `gh pr merge`, `gh issue edit`, `gh pr edit`, `gh pr comment`, `gh issue comment`, and any other call that mutates the repo or the GitHub-side state:

```bash
# Top of every write-class Bash call — re-derive inside the call, don't rely on prior state.
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ ! -d "$WORKTREE_PATH" ] || [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --format='%H' 2>/dev/null | head -c 12)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi
# ... actual write call here, e.g.:
# git commit -m "..."
```

The re-derivation is cheap (a single `git rev-parse` against the cwd) and self-correcting: if your cwd is still inside the worktree, `WORKTREE_PATH` resolves to the same path the orchestrator handed you; if the worktree has been reaped, `git rev-parse` errors and `WORKTREE_PATH` is empty, which the `! -d "$WORKTREE_PATH"` check catches. The second arm of the OR (`git rev-parse --show-toplevel != $WORKTREE_PATH`) is the redundant-but-cheap belt to the suspenders — if `cd` ever drifted to a sibling worktree or the primary checkout, the toplevel won't match the just-derived path and the same `reaped:` bail fires.

**Why not "save once, reuse via `export`."** The Bash tool does not run your calls inside a persistent shell session — there's no parent process whose environment survives across tool-result boundaries. `export WORKTREE_PATH=...` in call N does not make `$WORKTREE_PATH` readable in call N+1. The same constraint applies to `set -o`, `cd`, shell aliases, and shopt — every Bash tool call is hermetic. Re-deriving at the top of each write-class call is the only pattern that holds across the tool's actual isolation semantics. (For read-only calls — `git log`, `gh issue view`, `gh pr list`, etc. — you can skip the guard; the cost of a misread is wasted tokens, not a corrupt write.)

The `reaped:` prefix is load-bearing and intentionally distinct from `blocked:`: the orchestrator's step A reconcile parses it as a **retryable** outcome — it re-enqueues the issue for a fresh dispatch rather than applying any block label. The `blocked:` prefix is reserved for deterministic failures (ambiguous scope, cannot reproduce, refuses) where retrying would produce the same result; reconcile then classifies the bail per [#521](https://github.com/mattsears18/shipyard/issues/521) (refuse → `needs-human-review`, dependency-wait → no label, subjective → `blocked:agent-soft`). A mid-run reap is external-infrastructure noise, not a worker logic failure. Do NOT try to `cd` to a different worktree, recreate your worktree, or operate in the primary checkout — exit immediately.

## Incremental progress posting (investigation-heavy work)

For workers whose job involves a multi-step investigation before any commit lands (scope pre-flight analysis, diagnostic investigation, fix-checks root-cause search), a worktree reap mid-run destroys the findings before they can be communicated. To prevent silent value loss, **post investigation findings to the originating issue before attempting any git/gh write**:

```bash
# After reaching a diagnostic conclusion but BEFORE git commit / git push / gh pr create:
gh issue comment <N> --repo <owner/repo> --body "$(cat <<'EOF'
<!-- shipyard-worker-progress -->
**Investigation finding (pre-push):** <your diagnostic summary here — file paths, line numbers, root cause, rejected hypotheses>

This comment is posted before the final push so findings survive a mid-run worktree reap.
EOF
)"
```

**When to post a progress comment.** Post one if BOTH are true:
1. You have produced a concrete finding that isn't yet in the remote (uncommitted work, diagnostic conclusion, scope decision).
2. The finding would be permanently lost if your worktree were reaped in the next 30 seconds.

**What the comment should contain.** Exactly what the orchestrator would have had to transcribe manually if your run was interrupted: file paths, line numbers, rejected alternatives, root-cause hypothesis. Not a progress update ("working on it") — findings only.

**When NOT to post.** If you're about to push a commit that encodes the finding, the commit is the durable record — skip the comment. If the issue is a typo-fix and there are no intermediate findings, skip. The goal is to prevent loss, not to narrate every step.

The `<!-- shipyard-worker-progress -->` sentinel lets the orchestrator identify and summarize these comments without re-reading the entire thread.

## Dependency-bootstrap check for Node-based target repos

The Claude Code harness creates your agent worktree with `git worktree add` and nothing else — it does NOT install npm dependencies, does NOT symlink `node_modules` from the primary checkout, and does NOT run `npm ci`. For most target repos this is fine (Python, Go, plain shell, docs-only). For **Node-based target repos** it's a silent test-correctness gap, because:

- The repo's pre-push / pre-commit hooks usually shell out to locally-installed binaries via `node_modules/.bin/<tool>` (jest, prettier, eslint, firebase, etc.).
- When `node_modules/` is missing, those shell-outs hit `ENOENT` at the `execFileSync` level. A naive hook script that wraps the call in a try/catch and treats "no output" or "non-numeric exit status" as success will **silently pass** instead of failing loudly. The lightwork project's `scripts/test.js` does exactly this — `--passWithNoTests` semantics get applied to a missing-binary spawn-failure and the push proceeds with zero tests actually run. ([#316](https://github.com/mattsears18/shipyard/issues/316)).
- Net effect: your worker thinks it ran the project's test suite locally, when in fact it ran nothing. The code lands and CI catches the regression — except now you've burned an iteration on a problem your local-test discipline was supposed to catch.

**The check.** Before your first `git push`, if the target repo ships a `package.json` AND your worktree has no `node_modules/`, treat it as a setup-incomplete state — not a "this repo has no deps" state:

```bash
# Run this once near the top of step 4 (implement) — before you write code, before
# you run tests, definitely before you push.
if [ -f package.json ] && [ ! -d node_modules ]; then
  echo "worker-preamble: package.json present but node_modules missing — Node deps not bootstrapped" >&2
  # Try the cheap recovery paths in order. See remediation section below.
fi
```

The check is a one-liner; the remediation is the substantive part.

**Remediation, in order of preference:**

1. **Symlink from the primary checkout.** Cheapest, fastest, and works for almost all tooling (jest, eslint, prettier, firebase CLI). The primary checkout's `node_modules/` is at a deterministic path relative to your worktree — `.claude/worktrees/agent-<id>/` lives inside `<primary-checkout>/.claude/worktrees/`, so the primary's `node_modules` is exactly `../../../node_modules` from your worktree root:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     ln -s ../../../node_modules node_modules
     # Also add to the per-worktree exclude so the symlink can NEVER be
     # implicitly staged into a commit (issue #351 — see the "Pre-commit
     # hygiene" section below for the salvage cost when it leaks). The
     # per-worktree `.git/info/exclude` is the canonical git mechanism for
     # "ignore this in this checkout only" — it doesn't pollute the repo's
     # `.gitignore` (which would be a public spec change).
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```
   Native modules built against the host Node version need rebuild for native modules to load — acceptable trade-off since shipyard already requires the primary checkout to be on a compatible Node version. The symlink only persists for the worktree's lifetime; the orchestrator's reap doesn't touch the primary checkout's `node_modules/`.

   **Auto Mode constraint.** In Auto Mode the symlink step is typically denied by the auto-mode classifier with a message like: *"Symlinking the parent repo's `node_modules` into the worktree creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* If you are running under Auto Mode, **skip the symlink entirely and go directly to `npm ci` (path 2 below)** — attempting the `ln -s` first wastes one tool-call turn on a denial that is predictable. Observed in `/shipyard:do-work` session against `mattsears18/lightwork` on 2026-05-24 ([#328](https://github.com/mattsears18/shipyard/issues/328)).

   **Alternative — `cp -al` (hard-link copy).** A hard-link copy doesn't create a cross-directory writable link, so the auto-mode classifier should allow it. Same disk semantics as a symlink (files are not duplicated byte-for-byte), but each file is independently owned by the worktree. Caveat: hard links only work within the same filesystem, which is normally satisfied when the worktree and primary checkout share the same mount. Use as an alternative when `ln -s` is denied and `npm ci` is too slow:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     cp -al ../../../node_modules node_modules
     # Same gitignore-via-info/exclude hygiene as the symlink path — the
     # hard-link tree shouldn't leak into a commit either.
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```

   **Next 16 / Turbopack constraint — skip BOTH link strategies, go straight to `npm ci` ([#458](https://github.com/mattsears18/shipyard/issues/458)).** Next.js 16's Turbopack refuses a `node_modules` that resolves outside the worktree's filesystem root, failing the build/dev/test with `Symlink ... points out of the filesystem root`. The `../../../node_modules` symlink target is literally outside the worktree root, so the symlink path (path 1) is dead on a Turbopack repo — and the `cp -al` hard-link copy is risky too (Turbopack resolves the real inode, which still lives under the primary checkout's tree, so it can trip the same root check). Don't attempt either link strategy and let each worker rediscover the failure; **detect Turbopack/Next 16 first and fall through deterministically to `npm ci` (path 2)**:
   ```bash
   # Turbopack/Next-16 detection: a next >=16 dep, OR a --turbopack flag wired
   # into any package.json script (next dev/build --turbopack), OR a turbopack
   # config key. Any hit ⇒ skip the link strategies, go straight to npm ci.
   uses_turbopack=false
   if [ -f package.json ]; then
     next_major=$(node -p "((require('./package.json').dependencies?.next||require('./package.json').devDependencies?.next||'').match(/\d+/)||[0])[0]" 2>/dev/null)
     if { [ -n "$next_major" ] && [ "$next_major" -ge 16 ] 2>/dev/null; } \
        || grep -q -- '--turbopack' package.json 2>/dev/null \
        || node -e "process.exit(require('./package.json').turbopack?0:1)" 2>/dev/null; then
       uses_turbopack=true
     fi
   fi
   ```
   When `uses_turbopack=true`, skip path 1's symlink AND its `cp -al` alternative entirely and run `npm ci` (path 2) — the link strategies cannot satisfy Turbopack's root check, so attempting them first only burns a turn on a predictable failure (the same wasted-turn logic as the Auto Mode constraint above). Repro: session `do-work-20260601T004608Z` against `mattsears18/mattsears18.com` (Next 16 + Turbopack) — workers #169 / #140 / #170 each hit `Symlink points out of the filesystem root` on the symlink path and self-recovered to `npm ci`.

2. **Fall back to `npm ci`.** Most correct, slowest (30–90s typical). Use when the symlink path doesn't exist (worktree was created somewhere unusual), when running under Auto Mode (see constraint above), when the repo uses Next 16 / Turbopack (see constraint above — the link strategies fail Turbopack's filesystem-root check), or when a previous attempt with the symlink hit native-module loader errors:
   ```bash
   npm ci --no-audit --no-fund --prefer-offline
   ```

3. **Bail with `blocked:` if both paths fail.** Don't push a Node-repo change whose local tests didn't actually run — the silent-pass failure is exactly the gap this check exists to close. Return `blocked: cannot bootstrap node_modules — symlink target missing AND npm ci failed (<reason>)` and let the orchestrator pick a different issue.

**When NOT to run the check.** Don't run it for non-Node repos (no `package.json`), don't run it inside a sub-directory of a monorepo unless that sub-dir has its own `package.json` (the root's deps may satisfy the sub-dir's tooling), and don't run it for documentation-only changes to a Node repo (no tests to skip silently if your diff is `*.md` files).

**Why this lives in the preamble and not per-mode.** Every dispatched worker (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch) eventually runs `git push` against the target repo. The silent-test-skip failure mode is identical across modes. One check in the shared preamble beats five copy-pasted recipes in the per-mode files.

## Husky / `core.hooksPath` hooks silently skipped on a missing exec bit

A third silent-quality-gate-bypass, adjacent to the two above but with a different root cause ([#459](https://github.com/mattsears18/shipyard/issues/459)). Here `node_modules` is present and the test config is fine — but the repo's **pre-commit hook itself never runs**, because the hook file in your fresh agent worktree lacks the executable bit. The commit lands with lint-staged / prettier / eslint never having fired, and you didn't pass `--no-verify` — git skipped the hook on its own.

**Mechanism.** Husky (and any repo that sets `core.hooksPath` to a committed hooks dir) relies on the hook file being mode `100755`. Git **silently ignores a hook that isn't marked executable** — it prints a one-line `hint:` to stderr (`hint: The '.husky/pre-commit' hook was ignored because it's not set as executable.`) and then **exits 0, committing anyway**. The hint is advisory; the commit is not blocked. Two ways a fresh worktree ends up with non-executable hooks:

- **The hook was committed without the exec bit.** `git worktree add` checks out each file with the mode recorded in the index. If the repo committed `.husky/pre-commit` as `100644` (a common mistake — easy to do on Windows or after a `chmod`-losing copy), every checkout, worktree or not, gets a non-executable hook. The primary checkout often masks this because the developer ran `husky install` once, which can re-set the bit out-of-band.
- **The repo provisions hooks via a `prepare` / `postinstall` script that never ran in the worktree.** Husky v9's `prepare: "husky"` script (run by `npm install`) is what wires `core.hooksPath` and sets perms. A bare `git worktree add` runs no npm lifecycle script, so if the repo depends on `prepare` to make hooks live, the worktree's hooks are inert. (This overlaps the dependency-bootstrap gap above — if you `npm ci` to bootstrap deps, its `prepare` script usually fixes the hooks as a side effect; the failure mode here is specifically the path where deps were symlinked, not `npm ci`'d, so `prepare` never ran.)

Confirmed repro (issue #459): `mattsears18.com` session `do-work-20260601T004608Z`, the #170 issue-work worker — git silently skipped the non-executable `.husky/pre-commit`, so lint-staged / formatting gates never ran on the commit. A local sanity check shows the behavior cleanly: a `.husky/pre-commit` that `exit 1`s blocks the commit when mode `755`, but is skipped (commit exits 0, only a `hint:` to stderr) when mode `644`.

**The check.** Before your first commit, if the repo wires a committed hooks dir (`.husky/` present, or `git config core.hooksPath` resolves inside the worktree), confirm the hooks that exist are executable. Cheap one-liner:

```bash
# Resolve the hooks dir: explicit core.hooksPath wins, else .husky/ is the husky default.
HOOKS_DIR="$(git config --get core.hooksPath || true)"
[ -z "$HOOKS_DIR" ] && [ -d .husky ] && HOOKS_DIR=.husky
if [ -n "$HOOKS_DIR" ] && [ -d "$HOOKS_DIR" ]; then
  # Any extensionless regular hook file present-but-not-executable is the silent-skip risk.
  NON_EXEC=$(find "$HOOKS_DIR" -maxdepth 1 -type f ! -perm -u+x ! -name '*.*' 2>/dev/null)
  if [ -n "$NON_EXEC" ]; then
    echo "worker-preamble: hooks present but not executable — git will silently skip them:" >&2
    echo "$NON_EXEC" >&2
  fi
fi
```

The `! -name '*.*'` filter skips husky's own helper files (`_/husky.sh`, `.gitignore`) — hook entrypoints are extensionless (`pre-commit`, `commit-msg`, `pre-push`).

**Remediation, in order:**

1. **`chmod +x` the hook files in the worktree.** Restores the exec bit locally so git runs the hooks for *your* commits. This does NOT change the committed mode (so it's not a stray diff) — it only fixes the working-tree perms for this worktree's lifetime, which is exactly the scope of the problem:
   ```bash
   chmod +x "$HOOKS_DIR"/* 2>/dev/null || true
   ```
   If the underlying cause is the committed mode being `100644` (not just a worktree-checkout artifact), that's a real repo bug worth fixing in the issue you're working — but only if it's in scope. Don't fold a `git update-index --chmod=+x` mode-fix into an unrelated PR; file a follow-up issue instead.

2. **Or `npm ci` to let the `prepare` script re-provision hooks.** If the repo wires hooks through husky's `prepare` script and you haven't bootstrapped deps yet, `npm ci` runs `prepare` as a lifecycle step, which re-sets `core.hooksPath` and the exec bits. Prefer this when you're already going to `npm ci` for the dependency-bootstrap check above — one command fixes both gaps.

3. **Never reach for `--no-verify` as a "workaround."** This is the inverse of the `--no-verify` prohibition: the hook *should* run and you must make it run, not skip it because it's inconvenient that it isn't running. A silently-skipped hook is a latent quality-gate bypass; the fix is to make the gate fire, never to formalize the bypass.

**When NOT to worry about this.** Repos with no `.husky/` and no `core.hooksPath` (the hooks live in the default `.git/hooks`, which `git worktree add` shares from the common dir and which carry their committed mode) — there's nothing to fix. Documentation-only diffs that wouldn't trip a lint-staged gate anyway. And the shipyard repo itself has no husky setup, so a worker dispatched against `mattsears18/shipyard` skips this check — it's the *target-repo* hooks (lightwork, mattsears18.com, etc.) that this guards.

## Test-runner silent-pass when the target repo ignores worktree paths

A second silent-pass failure mode, distinct from the missing-`node_modules` case above ([#369](https://github.com/mattsears18/shipyard/issues/369)). Here `node_modules` is fully present and the binaries resolve fine — but the target repo's test config **ignores the worker's own worktree path**, so the runner silently skips every test the worker just wrote.

**Mechanism.** A repo that runs `/shipyard:do-work` against itself commonly adds `/.claude/worktrees/` to its test runner's path-ignore list (jest `testPathIgnorePatterns`, vitest `exclude`, pytest `norecursedirs`, mocha `--ignore`) so the **primary** checkout's test runner doesn't sweep into agent worktrees during local dev. That pattern is correct for the primary use case but **wrong** for the worker use case: when the worker (or its pre-push hook) runs the suite *from inside* `.claude/worktrees/agent-*/`, the runner computes the absolute path of every test file — which now begins with `.../.claude/worktrees/agent-*/...` — and the ignore pattern matches the worker's own files. The runner reports "No tests found" / "0 tests", the hook treats that as a pass, and the push proceeds with zero tests actually run. The lightwork repro: `jest.config.js` with `testPathIgnorePatterns: ['/node_modules/', '/functions/', '/.claude/worktrees/']` silently skipped a worker's new `__tests__/chunk-load-recovery.test.ts` while reporting code 0 (session `do-work-20260528T015557Z-14129`, [`lightwork#1362`](https://github.com/mattsears18/lightwork/pull/1362)).

**The signal.** When you run the target repo's test suite (or read your pre-push hook's output) and see a **zero-tests-found pass** — `No tests found`, `0 tests`, `0 passed`, `--passWithNoTests` firing — against a diff that **does** add or modify test files, do NOT treat it as a green local run. A zero-test pass on a test-touching diff is the silent-pass tell.

**The recovery, in order:**

1. **Re-run with the worktree-ignore entry stripped.** If the repo's config ignores `/.claude/worktrees/`, re-run the suite with the *other* ignore entries preserved but the worktree entry dropped, so the runner sees your worktree's tests. Jest takes repeatable `--testPathIgnorePatterns` flags that **replace** the config value, so pass the surviving entries explicitly:
   ```bash
   # jest: replace the config's ignore list, keeping everything EXCEPT /.claude/worktrees/
   npx jest --testPathIgnorePatterns='/node_modules/' --testPathIgnorePatterns='/functions/'
   ```
   The vitest / pytest / mocha equivalents differ (`vitest --exclude`, pytest `--override-ini`, mocha `--ignore`) — the principle is the same: override the config so the runner stops ignoring your own worktree. Confirm the re-run now reports a non-zero test count before trusting it.

2. **Bail loudly if you can't override.** If the runner has no clean override (or the override still reports zero tests), do NOT let the push ride the silent pass. Return:
   ```
   blocked: pre-push test runner silently passed — target repo's test config ignores worktree paths, local tests did not run
   ```
   This is option 3 from [#369](https://github.com/mattsears18/shipyard/issues/369): the smallest-signal response. It doesn't second-guess the target repo's config; it just refuses to launder a zero-test pass into a "tests pass locally" claim. CI will run the tests from a fresh (non-worktree) checkout, but bailing here saves the wasted iteration the orchestrator otherwise pays for.

**When NOT to worry about this.** Documentation-only diffs (no test files touched) legitimately produce a zero-test pass — that's not the failure mode. The tell is specifically a zero-test pass on a diff that *added or changed* test files. And the override (step 1) is only needed when the config actually ignores `/.claude/worktrees/`; most repos don't, and their runner finds your tests normally.

## Mirror new string constants into locale / parity files

A recurring, self-inflicted CI red ([#418](https://github.com/mattsears18/shipyard/issues/418)): you add a user-facing string to a centralized strings module (e.g. `lib/strings.ts`, `src/i18n/keys.ts`, a `messages.ts` constant bag), open the PR, and CI goes red on a **parity test** that asserts every string key has a matching entry in every locale file. The repo's local pre-push hook didn't catch it (the parity test isn't always wired into the pre-push suite), so the break only surfaces in CI — costing a fix-checks cycle to add the one missing key. Repro: a single `mattsears18/lightwork` session (`do-work-20260531T113301Z-98771`) tripped this 3× across PRs #1443 / #1444 / #1447 — each added a `Strings.*` leaf in `lib/strings.ts` but forgot the matching key in `locales/en.json`, reddening the repo's `i18n.test.ts` parity test.

**The class is general** even though the trigger is repo-specific: many repos lock down a "centralized strings ↔ locale-file parity" invariant with a test. The shapes vary —

- i18n locale parity: `locales/en.json`, `locales/*.json`, `lang/*.yml`, a `messages/` dir — the test asserts the key set matches across every locale.
- Enum / constant ↔ lookup-table parity: a string-constant enum whose every member must have a row in a display-name map, a color map, an icon map.
- Snapshot / fixture parity: a generated `*.snap` or golden fixture that enumerates the full key set.

**The check.** Before opening the PR, if your diff **adds a key to a centralized string / constant module**, grep for a parity or locale test (`i18n.test.*`, `*parity*`, `locales/`, `messages/`, `lang/`, a `*.snap` enumerating keys) and **mirror the new key into every file the test requires** — the locale JSON, the display-name map, the fixture — in the same PR. The cheapest signal is to run the repo's full test suite locally (not just the pre-push subset) once after adding a string; if a parity test reds, add the missing mirror entry before you push. When the repo ships only a stub / placeholder value convention for non-default locales (common — translators fill them in later), mirror the key with the default-locale value or the repo's documented placeholder, not a blank.

**When NOT to worry about this.** Diffs that don't touch a centralized string / constant module (pure logic, config, docs) can't trip a key-parity test — skip the check. And if the repo has no parity test (the grep comes up empty), there's nothing to mirror; don't invent locale files the repo doesn't have.

## Pin the default branch in git-using test fixtures

A pre-push silent-pass with an *invisible host dependency* ([#475](https://github.com/mattsears18/shipyard/issues/475)): you add or edit a shell test fixture that builds a throwaway repo with a bare `git init` and later refers to the default branch by name — `git checkout main`, `git rev-parse main`, `git branch -f main`, an assertion against a `refs/heads/main` ref. Your pre-push sweep runs the suite locally and it passes — because your dev machine's `init.defaultBranch` is `main` (the macOS / recent-git default). CI's runner is GitHub-hosted Ubuntu, whose `init.defaultBranch` is **`master`**, so the fresh repo's initial branch is `master`, the `main` pathspec doesn't resolve, and the test reds with `error: pathspec 'main' did not match any file(s) known to git` (or an empty-ref assertion failure). The break only surfaces post-push, and on a repo that admin-direct-merges **ungated** (no required status checks — the `merged-direct-ungated` case) there is no PR gate to catch it before it reddens the default branch.

Repro ([#466](https://github.com/mattsears18/shipyard/issues/466) → recovery [#473](https://github.com/mattsears18/shipyard/issues/473)): a worker added `plugins/shipyard/scripts/tests/fix-rebase-version-coordination.test.sh`, which `git init -q`'d a fixture repo then `git checkout main`'d it. The worker's macOS pre-push sweep passed; PR #472 admin-direct-merged ungated; CI's Ubuntu runner failed the `git checkout main` with `pathspec 'main' did not match`, cascading three assertion failures and reddening both the `Tests` and `Shell scripts (lint + tests)` workflows on `main`. Recovery PR #473 pinned the fixture with `git init -q -b main`.

**The authoring rule.** When your diff **adds or edits a `*.test.sh` (or any test fixture) that runs `git init` and then references the default branch by name**, pin the fixture's initial branch so it's deterministic regardless of the host's `init.defaultBranch`:

```bash
# Pin the default branch — CI's init.defaultBranch may be 'master', not 'main'.
git init -q -b main
# (equivalent, for older git that lacks `git init -b`:)
git -c init.defaultBranch=main init -q
```

A bare `git init` whose fixture never names the default branch (it only uses `git branch` / `git for-each-ref` generically, or commits onto whatever the initial branch is without caring what it's called) is **not** at risk — don't churn those. The risk is specifically *bare `git init` + a hard-coded branch name later in the same fixture*.

**The verification recipe (catches the whole class deterministically).** Pinning is the fix; this is the cheap way to *prove* you got it — and to catch any fixture you edited that still has a latent host dependency. Re-run the new/changed suite once under a forced non-`main` default, exactly how recovery PR #473 reproduced the failure. An ephemeral `GIT_CONFIG_GLOBAL` pointed at a config that sets `init.defaultBranch=master` reproduces CI's Ubuntu environment without touching your real git config:

```bash
# Reproduce CI's `init.defaultBranch=master` locally and re-run the suite.
# If it passes here, it passes on CI's Ubuntu runner too.
tmp_gitconfig="$(mktemp)"
printf '[init]\n\tdefaultBranch = master\n' > "$tmp_gitconfig"
GIT_CONFIG_GLOBAL="$tmp_gitconfig" bash plugins/shipyard/scripts/tests/<changed-suite>.test.sh
rm -f "$tmp_gitconfig"
```

A suite that passes under `init.defaultBranch=master` has no remaining host dependency on the default-branch name; one that fails has exactly the #475 gap and needs a `git init -b main` pin (or its assertions de-hardcoded) before you push.

**When NOT to worry about this.** Diffs that don't add or edit a git-using `*.test.sh` fixture (pure docs, config, non-shell tests, a fixture that doesn't shell out to `git init`) can't trip this — skip the check. And a target repo that isn't shell-test-driven, or whose CI runner shares your host's `init.defaultBranch`, won't surface the divergence; the recipe is cheap insurance specifically when you're authoring a new git-using shell fixture against a self-hosting repo like `mattsears18/shipyard`.

## Pre-commit hygiene — escape symlinks

A companion failure mode to the dependency-bootstrap symlink ([#351](https://github.com/mattsears18/shipyard/issues/351)): the worker creates `node_modules → ../../../node_modules` per the bootstrap rules above, then accidentally stages it into a commit via a stray `git add -A`, a misclick on `git add node_modules`, or path globbing that happens to include the symlink. The committed `120000` symlink mode rides into the commit and stays dangerous forever — when a downstream consumer cherry-picks the commit onto a different checkout depth, `../../../node_modules` resolves to a different (or non-existent) path. The salvage cost is a follow-up `fix(repo): remove stray node_modules symlink from cherry-pick` commit on the receiving end; the prevention cost is zero if you follow the symlink-creation hygiene above.

The `refuse-escape-symlink-commit.sh` hook (registered as PreToolUse → Bash in `hooks.json`) is the load-bearing enforcement. It refuses any Bash `git commit` invocation whose staged file set includes a symlink whose target either starts with `/` or contains a literal `..` path segment. The hook's stderr explains the failure mode and the fix; do NOT bypass it.

If you genuinely need to commit a symlink with `../` in the target (rare — and a strong signal to re-think the design), return `blocked:` so a human can decide. The hook intentionally has no bypass flag, paralleling the no-`--no-verify` rule for commit hooks.

## GitHub push-protection blocking a synthetic test-fixture secret

A push-time analogue to the classifier-denial boundary ([#440](https://github.com/mattsears18/shipyard/issues/440)): you add a NEW test fixture containing a realistic-shaped secret — `xoxb-`/`xoxp-` Slack tokens, `sk_live_`/`sk_test_` Stripe keys, `ghp_`/`github_pat_` GitHub tokens, `AKIA…` AWS keys — because the fixture's whole job is to exercise a scrubber, a secret-scanning rule, or a redaction regex you're adding. The fixture value is **synthetic** (made up, matches the shape but unlocks nothing), but it's realistic enough that **GitHub's server-side push-protection** rejects your `git push` with a `GH013: Repository rule violations` / "Push cannot contain secrets" error naming the detector that matched (Slack API Token, Stripe API Key, etc.).

**The trap: this is NOT the same scanner as `.gitleaks.toml`.** This repo wires two distinct committed-content scanners, and allowlisting a fixture in one does NOT exempt it from the other:

- **`.gitleaks.toml`** (driven by `.github/workflows/secret-scan.yml`) is the in-repo gitleaks config. Its `[allowlist].paths` already exempts the scrubber test fixtures (`plugins/shipyard/scripts/tests/report-plugin-error.test.sh`, etc.) — so the CI gitleaks job stays green on those files.
- **GitHub native push-protection** (Settings → Code security → "Push protection") is a *separate, server-side* detector that runs on every push regardless of `.gitleaks.toml`. It has its own ruleset and its own (org/repo-level) bypass surface. A path allowlisted in `.gitleaks.toml` is still subject to push-protection. This is exactly the surprise the #402 and #408 scrubber-fixture workers hit: the fixtures were already gitleaks-allowlisted, yet the push still bounced.

**What to do when push-protection blocks a synthetic-fixture push, in order:**

1. **NEVER click the server-side unblock URL.** The error output includes an "allow secret" / "unblock" link that registers a push-protection bypass for that blob. Following it is a repo-security-posture decision (it tells GitHub "this secret is intentional, let it through forever"), which is a **maintainer** decision, not a worker decision — and it normalizes a bypass path that a future real-secret leak could ride. Treat the unblock URL exactly like the classifier-denial "argue past it" surface: off-limits.
2. **Rewrite the fixture to an obviously-synthetic value that still matches the pattern under test.** The detector keys on *shape*; your test keys on *the scrubber matching the shape*. Both are satisfied by a value that's clearly fake to a human reader — embed an `EXAMPLE` / `NOT-A-REAL-TOKEN` / `DO-NOT-USE` marker inside the token body while preserving the prefix and length class the regex needs:
   ```
   # Bounced by push-protection (realistic random-looking body — shown
   # here abstractly so this very doc doesn't trip the detector):
   xoxb-<11 digits>-<11 digits>-<24 random alphanumerics>
   # Synthetic, still matches the xoxb-[…] shape under test, passes push-protection:
   xoxb-EXAMPLE-NOT-A-REAL-TOKEN-000000000000
   ```
   Verify the rewritten value still exercises the regex/scrubber you're testing — run the test locally — before re-pushing. The point is a fixture that (a) the detector lets through and (b) still asserts what the original asserted.
3. **Rebuild the commit so the flagged blob never enters pushed history.** Push-protection scans the *diff*, but the flagged blob also lives in your local commit. A plain amend-then-push can still bounce if the original blob is reachable. Rebuild the offending commit (`git commit --amend` for a single-commit branch, or `git rebase` to rewrite the commit that introduced the blob) so the realistic-shaped value is gone from the history you push — then `git push --force-with-lease` your own feature branch. (Force-pushing *your own* `do-work/issue-<N>` branch is fine per the "don't force-push shared/main" rule; this isn't a shared branch.)
4. **If the fixture genuinely can't be made synthetic-looking while still testing what it must** (rare — some detectors validate a checksum, e.g. Stripe key Luhn-style checks, so an `EXAMPLE`-laced body won't match), do NOT click the unblock URL and do NOT bypass. Return `blocked: push-protection blocks synthetic fixture and value can't be made obviously-fake while still matching the detector — needs maintainer decision on repo push-protection bypass` and let the maintainer decide whether to register a bypass or restructure the test.

**Mirror to `.gitleaks.toml` when you add a fixture file.** If your new fixture lives in a *new* file (not one already covered by `.gitleaks.toml`'s `[allowlist].paths`), the CI gitleaks job will red on it even after push-protection is satisfied. Add the new fixture path to `.gitleaks.toml`'s `paths` allowlist in the same PR — otherwise you trade a push-time block for a CI-time red and pay a fix-checks cycle. The two scanners protect the same surface (committed content) but are configured independently; a synthetic-fixture PR usually needs to satisfy both.

**When NOT to worry about this.** A diff with no new realistic-shaped secret values can't trip push-protection — most PRs never touch this. The failure mode is specific to work that *adds* secret-shaped fixtures (scrubber tests, secret-scan rule tests, redaction-regex tests). And if push-protection blocks a value that is NOT synthetic — a real token that leaked into your diff — none of the above applies: scrub the real secret out entirely, rotate it if it was ever real, and never commit it. The synthetic-fixture path is for values that were fake from the start.

## Never `--no-verify`

You are forbidden from passing `--no-verify`, `--no-gpg-sign`, `--no-commit-hooks`, or any other flag that bypasses commit hooks, even if you believe the hook failure is environmental, unrelated to your changes, or a false positive. If a pre-commit hook fails:

1. Try to fix the underlying cause within scope (your changes' code).
2. If the cause is outside scope, return `blocked: pre-commit hook <NAME> failed for reason <X>` so the orchestrator can decide.
3. NEVER bypass. Not even "just this once."

Same rule for `git push --no-verify`. Same rule for any hook-bypass flag. The plugin's `permissions.deny` block in `plugin.json` enforces this at the harness level, but the rule applies even if the deny pattern is somehow bypassed.

## After a classifier denial

Auto Mode (and other harness-side classifiers) sometimes deny a tool call — an Edit, a Write, a Bash, an `npm install`, a symlink — with a reason like *"...creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* The denial is a hard boundary enforced by the harness, not a suggestion you can argue past. The correct posture is to treat the denial as a deterministic failure for **this** dispatch and let a human decide whether to re-authorize, change the classifier policy, or redirect the work.

**Three behaviors you MUST NOT do after a denial, even when you believe the denial was wrong:**

1. **Do NOT post a comment to any public GitHub artifact** (issue comment, PR description, PR comment, PR review) that summarizes, reframes, paraphrases, fabricates, or explains the classifier's reasoning. Classifier denials are between the worker and the harness; surfacing them to public-facing channels creates a content-integrity attack surface — even when well-intentioned, a public-facing comment fabricating *why* the classifier denied something is a side-channel that a future worker, reviewer, or scraper could read as authoritative. The harness's classifier reasoning is not yours to relay.
2. **Do NOT attempt to file a follow-up issue arguing the denial was wrong.** "The classifier was overly strict, please relax the policy" is not a worker decision; it's a maintainer decision. If you genuinely believe a denial pattern is misclassified at the policy level, the right surface is `mattsears18/shipyard` issues filed by the *user* after they see your `blocked:` return, not a self-filed escalation from inside the dispatch.
3. **Do NOT retry the same denied call through a workaround** — a different tool, a renamed file, a Base64-encoded payload, a shell-out that produces the same effect via a different syscall, or any other "I'll just do it a different way" strategy. Classifier policy targets *effects*, not tool names; routing around the deny is treated as the same policy violation. If the first attempt was denied, the second through any synonym is denied too.

**The correct response to a classifier denial is one foreground call: return.**

> `blocked: classifier denied <one-line description of what was denied>`

That's it. No comment, no follow-up issue, no creative retry. The `blocked:` return is the orchestrator's signal that the dispatch hit a deterministic boundary; step A reconcile will classify it as a refuse and apply `needs-human-review` (per [#521](https://github.com/mattsears18/shipyard/issues/521)) and the user can decide what to do next. The one-line description should name the operation (e.g., "Edit to .claude/settings.json", "symlink ../../../node_modules to ./node_modules", "npm install firebase-tools") so the maintainer can pattern-match the denial without reading the full transcript — but **do not include the classifier's prose reasoning** (paraphrased or verbatim) in the return string. The orchestrator captures it in the transcript record on its own.

**Why this is in the preamble.** A classifier-denial event is observably frustrating — the worker has a plan, sees the denial, and reaches for the next thing on the "ways to make this work" list. The next thing is often a content-integrity violation (posting to explain the denial) or a policy-bypass violation (retrying through a different surface). Both have been observed in the wild — issue [#341](https://github.com/mattsears18/shipyard/issues/341) documents a 2026-05-25 session where a worker attempted to post a fabricated explanation of the classifier's reasoning to a public GitHub issue after three denied Edit/Write attempts; the second-order classifier caught the comment-post too, so no harmful content landed, but the *intent* to escalate is the gap. This section closes that gap by naming the failure mode up front so the worker doesn't have to derive the correct response under the cognitive load of a denial.

## `gh` JSON discipline

Every `gh` call whose output you'll read MUST scope the response to the fields you actually consume. The default output is ~30 fields per issue / ~50 fields per PR — most of which the worker never reads. Each unused field is wasted tool-result tokens that ride in your context for the rest of the session.

The rule applies to **every read-shape `gh` subcommand**:

- `gh issue view / list`, `gh pr view / list`, `gh run list / view` — pass `--json <fields>`. Pick the smallest field set that satisfies the immediate read.
- `gh api <path>` — pass `--jq '<expr>'` to project the response inline. Same effect as piping to `jq`, one less subprocess.
- `gh repo view` — pass `--json <fields> -q <expr>` when reading (e.g. `--json defaultBranchRef -q .defaultBranchRef.name`).

Mutation-shape subcommands — `gh issue close`, `gh issue comment`, `gh issue edit`, `gh pr comment`, `gh pr edit`, `gh pr merge`, `gh pr create`, `gh label create` — are exempt: their output is small (usually empty or a single URL on success) and there's no field to scope.

**Two patterns, in increasing terseness:**

```bash
# Good — field-scoped, jq projection done client-side after the call returns.
gh pr view 142 --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
# (your jq runs against the small JSON returned)

# Better — field-scoped AND inline-projected, so the response itself is already the shape you want.
gh pr view 142 --repo <owner/repo> \
  --json statusCheckRollup,mergeStateStatus \
  -q '{mergeable: .mergeStateStatus, checks: [.statusCheckRollup[] | {name, conclusion}]}'
```

Prefer the inline `-q` form when the projection is a stable shape. Drop to the field-scoped-only form when the caller does multiple independent projections on the same response (worth the extra fields to avoid a second `gh` round-trip).

**Common projections worth remembering:**

| Need | Pattern |
|---|---|
| PR's check rollup (pass/fail/pending) | `gh pr view <M> --json statusCheckRollup,mergeStateStatus` |
| PR's head branch (for `git switch`) | `gh pr view <M> --json headRefName -q .headRefName` |
| Default branch | `gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name` |
| Issue body + labels + comments (issue-work step 0) | `gh issue view <N> --json state,assignees,labels,body,title,comments,author` |
| List PRs awaiting review with status fields | `gh pr list --json number,title,statusCheckRollup,mergeStateStatus,headRefName,labels` |
| Count something via gh + jq | `... --json number --jq 'length'` (NOT `... --json number | jq 'length'`) |

**Don't go default-mode.** A bare `gh issue list` / `gh pr list` / `gh pr view` (no `--json`) returns the full default projection in human-readable form — fine for an interactive terminal, expensive when piped into agent context. The rule applies even for "I just need to know if it exists" — use `--json number --jq 'length'` (or `--json id -q .id`) and let the response be a single integer / string.

**Don't pipe `gh ... --json` into a separate `jq`** when `--jq` (the gh-internal flag) would do the same projection. The piped form forks a second process and serializes the full JSON across a pipe before jq filters it; `--jq` filters server-side on the gh-CLI side of the boundary, so the agent's stdout block already arrives projected. The token savings are downstream of that — a smaller stdout block carries fewer tokens into the next tool-result. (Two-step pipes are still fine when you need `jq` features `gh --jq` doesn't expose — `--slurp`, multi-input, advanced output formatting.)

## What this skill does NOT cover

Mode-specific scope intentionally lives in the per-mode dispatch prompt and the agent's own spec:

- **Branch naming** (`do-work/issue-<N>`, `do-work/fix-main-ci-<short-sha>`, `do-work/fix-pr-pileup-<timestamp>`, or the PR's existing head branch for fix-checks/fix-rebase) — set by the dispatching prompt.
- **Return-string vocabulary** (`shipped #<N> via PR #<M>`, `green #<M>`, `rebased #<M>`, `shipped main-ci-fix via PR #<M>`, etc.) — set by the dispatching prompt and validated by the orchestrator's step A reconcile.
- **Fix-loop attempt caps** (3 for fix-checks-only, 1 for fix-rebase, 1 for fix-main-ci / fix-failing-prs-batch) — set in each per-mode file under `agents/issue-worker/`.
- **Trivial-conflict-or-bail policy** for fix-rebase — set in `agents/issue-worker/fix-rebase.md`.
- **Author-trust → auto-merge gating** for issue-work — passed through as `originating_author_trust` in the dispatching prompt and consumed by `agents/issue-worker/issue-work.md`'s step 6. When the field is **absent** from the dispatch prompt, the worker does NOT hard-default to `external`: it resolves the issue author's collaborator permission live (`repos/{owner}/{repo}/collaborators/{author}/permission` — `admin`/`maintain`/`write` ⇒ trusted, anything else including a non-collaborator's `read`/`none` or an API error ⇒ external), so owner-authored issues on solo repos still auto-merge while genuinely untrusted authors still gate (issue [#599](https://github.com/mattsears18/shipyard/issues/599)). The full fallback lives in issue-work step 6.

When in doubt, the per-mode prompt overrides this skill where they disagree — but the rules above are deliberately universal and shouldn't conflict.
