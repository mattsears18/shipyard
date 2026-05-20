# Changelog

All notable changes to the plugins in this repository will be documented here.

## shipyard

### 1.3.0 — 2026-05-20

Introduces a **soft-collision tier** in `/shipyard:do-work`'s dispatch rules so additive docs files (CLAUDE.md, README.md, CHANGELOG.md, `docs/**/*.md`, and — critically for the shipyard plugin repo itself — `plugins/*/commands/*.md` and `plugins/*/agents/*.md`) no longer hard-park parallel workers. Closes [#63](https://github.com/mattsears18/claude-plugins/issues/63).

Previously every path claim was treated as a hard collision: two ready-issue candidates both touching `CLAUDE.md` would park one of them until the other returned, even though their actual edits land in independent sections and conflict-free at squash-merge time. In audit-heavy sessions this dropped pool utilization by ~25–30% — an 8-slot pool often ran at 4–6/8 because docs files were claim-locked. The orchestrator was relaxing this pragmatically (treating CLAUDE.md as "relaxed-soft") without spec authorization. This release formalizes that into a configurable tier.

- **New collision tiers in `commands/do-work.md` dispatch rules.** Path claims are now partitioned into `claimed_paths.hard` (existing park-on-collision behavior) and `claimed_paths.soft` (capped concurrency). The default soft-collision glob set is: `CHANGELOG.md`, `CLAUDE.md`, `README.md`, `E2E_TESTS.md`, `docs/**/*.md`, plus `plugins/*/commands/*.md` / `plugins/*/agents/*.md` / `plugins/*/skills/**/SKILL.md` so future sessions running on the shipyard plugin repo itself can drain in parallel (the meta-bottleneck — every backlog issue on this repo touches `commands/do-work.md`). Up to `--soft-collision-concurrency` simultaneous claimers per **distinct soft path** (default `3`); fourth claimer parks. Hard-vs-soft compatibility is asymmetric: any hard claim against an in-flight soft OR hard claim on the same path blocks; soft claims only check against the soft cap.
- **New CLI args.** `--soft-collision-concurrency N` (default `3`, set `1` to opt out of the tier entirely) and `--soft-collision-path GLOB` (repeatable, additive — extends the default set). Both surface in the args list at the top of the command.
- **Status line gains a soft-suffix surface (step 6.5).** When any soft-collision path is claimed, the status line appends ` · [soft: <path>×<n>, ...]` listing distinct claimed soft paths and their in-flight counts, ordered by count desc. Cap-reached counts get a `⚠️` so the user sees merge-conflict risk at a glance. The status-line re-print trigger list gains "(g) any turn where a soft-collision claim count crossed the cap on any path."
- **Scope pre-flight (step 6) partitions paths automatically.** Scoping agents still return raw `files: [...]` arrays — the orchestrator does the soft/hard partitioning by matching each path against the configured glob set. Agents don't need to know about the tier distinction.
- **New `Don't` entry: orchestrator owns cross-worker merge-conflict resolution on soft-collision paths.** Two PRs both editing CLAUDE.md will conflict at land time because GitHub serializes the merges; agents can't pre-resolve because they have no visibility into each other's worktrees. The orchestrator inspects `mergeStateStatus` before letting the second soft-collision PR land and dispatches a fix-rebase worker for any `DIRTY` PR on a soft-collision file. The existing fix-rebase trivial-conflict-or-bail policy already handles additive CHANGELOG/CLAUDE.md/docs conflicts — clean rebases in 95%+ of cases, `blocked rebase` surfaces in the end-of-session summary as a "manual merge needed" note for the rest. **Don't** ask agents to coordinate (they can't) and **don't** serialize all soft-collision dispatches (that defeats the tier).
- **Updated `Don't dispatch two workers whose claimed_paths overlap`** to scope it explicitly to `claimed_paths.hard` and cross-reference the new soft tier so future readers don't misread it as "hard rule against ALL overlaps."
- **In-flight state shape updated.** `in_flight[slot].claimed_paths` is now `{ hard: [...], soft: [...] }` (was a flat array). `ready_issues` entries gain the same partition. Step C's lightweight backlog re-check is unaffected — it still appends raw issue numbers and partitioning happens at scope time. Step E's `idle_reason` valid set gains `all ready_issues blocked by soft-cap on <path> (×<N> active)` for the case where every ready candidate would push some soft path past its cap.

Motivating session: this orchestrator session itself, where 9 of the 11 candidate backlog issues all touched `commands/do-work.md`. The orchestrator was running at 1/4 capacity because every other ready candidate hard-collided with the in-flight worker. The fix is meta — landing this PR is what unblocks the rest of the queue. Same general theme as the audit-heavy throughput hit the issue describes (`mattsears18/lightwork`'s 12 in-flight PRs all touching CLAUDE.md), different surface.

### 1.2.9 — 2026-05-20

Adds a drain-phase **fix-rebase** worker mode so the end-of-session drain can auto-rebase PRs whose only blocker is a stale base (`mergeStateStatus: DIRTY` with no failing checks). Closes [#61](https://github.com/mattsears18/claude-plugins/issues/61).

Previously the drain phase only dispatched fix-checks workers against newly-red PRs — DIRTY-but-green PRs sat untouched until the drain's no-progress termination criterion fired, leaving sessions to end with a tail of PRs needing manual rebase. After this change, the drain treats DIRTY PRs as actionable: a lightweight worker rebases onto current main, force-pushes with lease, and lets the merge train re-arm auto-merge naturally.

- **New `fix-rebase` mode in `plugins/shipyard/agents/issue-worker.md`.** Sits alongside `fix-checks-only` as a PR-targeted dispatch mode. The worker lands on the PR's head branch via the safe two-step (`git fetch origin <ref> && git switch <ref>`), pre-flights `mergeStateStatus` (bailing if no longer DIRTY or if hard failures appeared), runs `git rebase origin/<default-branch>`, applies a **trivial-or-bail conflict policy**, and `git push --force-with-lease`. The trivial-resolvable set is intentionally narrow: append-only conflicts in `CHANGELOG.md` / `CLAUDE.md` / `README.md` / shared docs, `ci.yml` shard-matrix appends, and lockfile entries that can be regenerated by re-running the package manager. Anything semantic (same function body / same imports / same JSON key with different values / file rename collisions / snapshot or fixture conflicts) hits `git rebase --abort` and returns `blocked rebase` immediately. The worker does NOT touch the PR title / body / labels, does NOT call `gh pr merge` manually (auto-merge was armed when the PR was opened and rebasing doesn't un-arm it), and does NOT `--watch` checks.
- **New drain-phase dispatch rule in `commands/do-work.md`.** Per-poll bookkeeping now tracks `D_dirty` (PRs in `session_prs` with `mergeStateStatus == "DIRTY"`, no hard-failure checks, not in flight, not yet in `rebase_blocked_prs`) alongside the existing `R_new` / `M_since_last` / `P_settled` sets. The drain dispatcher fills the pool with fix-checks workers first (red PRs are more urgent than stale-base PRs), then any remaining slots run fix-rebase workers — combined fix-checks + fix-rebase in-flight count stays under the session's `--concurrency` cap. Each fix-rebase is **one-shot per PR per session**: a `blocked rebase` return puts the PR into `rebase_blocked_prs` and the drain doesn't re-dispatch even if the PR stays DIRTY across subsequent polls. The drain's "settled" definition counts `rebase_blocked_prs` members as settled so a non-trivially-conflicted PR doesn't keep the drain alive indefinitely.
- **Drain status line gains visibility.** The per-poll `[drain] open=… newly_red=…` line now includes `dirty=<D_dirty>`, `rebase_blocked=<n>`, and a worker-count breakdown (`in_flight=<n>(fix-checks=<a>, fix-rebase=<b>)`) so the user can see at-a-glance how many PRs the rebase logic is working through.
- **End-of-session summary gains a `Drain-phase rebases` line** with the per-outcome breakdown (`<rebased_count> succeeded (#A, #B, ...)`, `<rebase_blocked_count> blocked (#C — <reason>, ...)`) — omitted entirely when both counts are zero so small sessions with no DIRTY churn stay terse. The `Drain phase` summary's `final session_prs state` partition also gains a `rebase-blocked: <r>` field alongside the existing `merged` / `ci-blocked` / `still pending` counters so the partition still sums to `|session_prs|`.
- **Open-PR drain query gains `headRefName,headRefOid`** so the fix-rebase prompt template has the branch identifiers it needs without a second `gh pr view` per dispatch. The fields are cheap to add to the existing rollup query.
- **New `Don't` rules.** Two on the orchestrator side ("don't dispatch fix-rebase outside the drain," "don't retry a `blocked rebase` PR within the same session"), two on the worker side ("don't resolve a non-trivial merge conflict in fix-rebase mode," "don't `gh pr merge` manually in fix-rebase mode") — both pairs cite #61 as the motivating bug.

Discovered after a `mattsears18/lightwork` session that ended with 6 of 11 open PRs in DIRTY state — #962, #961, #960, #958, #953, #824 all just needed `git fetch && git rebase origin/main && git push --force-with-lease` and would have auto-merged. The drain phase was capped at 15 min anyway under the old policy; by the time the cap fired, the merge train had advanced main far enough to invalidate most open PRs' bases, but the orchestrator had no mechanism to do anything about it. The new mode closes the gap without expanding scope into rewriting tests or touching PR descriptions.

### 1.2.8 — 2026-05-20

Hardens the fix-checks-only return contract so the orchestrator can't be fooled by a worker that returns `green #<M>` before CI has actually completed. Closes [#56](https://github.com/mattsears18/claude-plugins/issues/56).

- **Stricter `green` semantics in `plugins/shipyard/agents/issue-worker.md`.** The fix-checks-only mode return-value spec now spells out unambiguously that `green #<M>` means "a full CI run completed and passed AFTER your final push" — not "pushed and queued," not "rebased onto a commit that should fix this," not "the failure looked transient so I optimistically declared victory." The contract is "the `statusCheckRollup` is fully `SUCCESS` / `SKIPPED` / `NEUTRAL` at the moment you return." A new worker-side `Don't` entry reinforces that hypotheses about a fix landing don't satisfy the contract — only an observed-green rollup does. The standard fix-loop's `gh pr checks <M> --watch --interval 30` step already drives this; the rewrite is for the ad-hoc dispatch case where a custom prompt drops the watch step.
- **Orchestrator-side trust-but-verify in `plugins/shipyard/commands/do-work.md` step A reconcile.** Every `green #<M>` and `noop: already green #<M>` return now triggers a one-call `gh pr view <M> --json statusCheckRollup,mergeStateStatus` spot-check. The orchestrator walks the rollup and downgrades silently:
  - any `PENDING` / `IN_PROGRESS` / `QUEUED` entry → return becomes `pending`, `<M>` is added to `session_prs` for the end-of-session drain to watch, advisory line logged: `[fix-checks-verify] downgraded #<M> green→pending: ... drain will reconcile.`
  - any `FAILURE` / `ERROR` / `TIMED_OUT` entry → return becomes `failing`, `<M>` is pushed onto `failed_prs` (deduped) for the next dispatch cycle to pick up, advisory logged: `[fix-checks-verify] downgraded #<M> green→failing: ... re-queued for fix-checks.`
- **New `Don't` entry in `commands/do-work.md`.** "Don't accept a `green #<M>` return from a fix-checks-only worker without verifying the rollup" — documents the failure mode and the spot-check as its defense, with a back-reference to the motivating bug.
- **Hardened fix-checks dispatch prompt template.** The prompt the orchestrator sends to fix-checks-only workers (in the dispatch-rules section) now restates the `green` contract inline so workers see the strict definition even before reading the agent spec: "**`green #<M>` means a full CI run completed and passed AFTER your final push — not 'pushed and queued.'**"

Discovered after a `mattsears18/lightwork` ad-hoc dispatch on PR #824: the orchestrator authored a one-off "rebase the PR onto current main, lift `ci-blocked`, the recent bundle-shrink work probably fixes the webserver hang" prompt that explicitly told the agent to skip `--watch`. The agent rebased, lifted, and returned `green` optimistically. The orchestrator trusted the return, the session ended, and CI subsequently hung all 3 E2E shards for the full 20-min timeout — exactly the same failure mode that triggered the original `ci-blocked` label. PR #824 sat red and unlabeled until the next session's step 5 picked it up. The trust-but-verify spot-check makes that path impossible: even if a future ad-hoc prompt drops `--watch`, the orchestrator catches the discrepancy and downgrades to `pending` / `failing` automatically. Issue [#56](https://github.com/mattsears18/claude-plugins/issues/56) also proposed a canonical `lift-ci-blocked` dispatch mode and a history-aware retry counter; those remain valuable but are intentionally out of scope for this release — split into follow-up issues so this fix lands minimally.

### 1.2.7 — 2026-05-20

Hardens worktree teardown so the orchestrator never reaps a still-running agent's worktree, and gives the issue-worker template an explicit escape hatch if it ever happens anyway. Closes [#64](https://github.com/mattsears18/claude-plugins/issues/64).

- **End-of-session cleanup step 3 now liveness-checks before reaping.** Previously the shutdown reap was unconditional — "at shutdown every dispatched agent is done, regardless of lock state." That assumption was load-bearing on correct termination logic, and the premature-termination bug (#57) demonstrated the failure mode: cleanup fired while a dispatched fix-checks agent was mid-rebase, its worktree got force-removed, and the agent returned later with `blocked: assigned worktree ... was cleaned up mid-session`. The fix mirrors step 3b's startup-time PID liveness check on the shutdown side: parse the lock file at `.git/worktrees/agent-<id>/locked`, `ps -p <pid>` it, and skip the reap entirely if the PID is alive. A new `<deferred_live>` counter surfaces in the end-of-session summary so the user sees when this defensive path triggered (which is itself a signal that termination ran early).
- **Issue-worker template gains a "detect-my-worktree-was-reaped" escape hatch.** New section in `plugins/shipyard/agents/issue-worker.md` instructing the worker to capture its worktree path at session start, then verify both directory existence and `git rev-parse --show-toplevel` consistency before every git/gh write. If the worktree is gone, the worker returns `blocked: my worktree was reaped while I was running — work was abandoned (last push: <SHA>)` and exits immediately — never tries to `cd` to the primary checkout, never tries to operate in a foreign worktree. The exact return string is load-bearing for step A's reconcile parsing.
- **New `Don't` entry on the worker side.** "Don't try to recover from a reaped worktree by relocating" — captures the silent-corruption failure mode that worktree isolation exists to prevent.

Discovered after a `mattsears18/lightwork` session in which `/do-work` terminated early (#57), the end-of-session reap ran, and the previously-dispatched fix-checks agent for PR #954 returned ~2 minutes later with its worktree gone. The agent had pushed a real fix (commit `b986129`) before the reap — the work survived on the remote — but it couldn't follow up to enable auto-merge because its workspace was gone. Combined with #57's fix this closes the whole class: termination no longer fires early, and even if it does, the worktree-side liveness check + worker-side escape hatch keep the failure recoverable.

### 1.2.6 — 2026-05-20

Routes visual-evidence auditor screenshots to a known subdirectory under `.shipyard/audits/` so they stop cluttering the repo root with untracked PNGs after every `/shipyard:audit` run. Closes [#68](https://github.com/mattsears18/claude-plugins/issues/68).

- **New routing rule in `plugins/shipyard/agents/web-ux-auditor.md` and `plugins/shipyard/agents/a11y-auditor.md`.** Every `take_screenshot` call must save to `.shipyard/audits/<YYYY-MM-DD>/screenshots/<route-or-finding-id>.png` — never to the repo root or any working directory. If the tool only accepts a `filePath` argument, the auditor passes the full relative path explicitly; if it auto-names, the auditor immediately `mv`s the output into the target directory before continuing the tour.
- **Embedding via relative path.** Issue bodies now reference screenshots with `![](./.shipyard/audits/<YYYY-MM-DD>/screenshots/<file>.png)` so the markdown renders the image inline when viewed in a checked-out repo and is a click-through reference on github.com.
- **Cleanup-unreferenced-screenshots step.** After all issues are filed, each auditor walks `.shipyard/audits/<YYYY-MM-DD>/screenshots/` and deletes any file that didn't end up cited in an issue body. The "no evidence, no finding" rule already filtered out screenshots without a home; this filters out the inverse — screenshots that were captured during exploration but didn't make it into a final issue. The audit run's directory is the only one each auditor is allowed to clean (never prior dates, never `store-assets/`).
- **Return-summary additions.** Each auditor's end-of-run summary now reports retained screenshots (`<path> → #NNN`) and the count of unreferenced screenshots that were deleted, so the orchestrator's consolidated report can list which evidence survives the session.
- **Mobile-ux gets a derived-screenshot clause.** `mobile-ux-auditor` primarily reads committed store screenshots from `store-assets/screenshots/{ios,android}/`, so its evidence path is unchanged. But if it ever produces a derived screenshot (annotated overlay, cropped detail, side-by-side comparison), that derived asset goes under `.shipyard/audits/<YYYY-MM-DD>/screenshots/` like the other agents — explicitly NOT next to the source files in `store-assets/`, which are committed canonical assets.
- **Pre-dispatch directory creation in `plugins/shipyard/commands/audit.md`.** `/shipyard:audit` now `mkdir -p`s `.shipyard/audits/<YYYY-MM-DD>/screenshots/` before dispatching any visual-evidence auditor, so the auditors can write without re-checking. This is the orchestrator's promise the auditors rely on.
- **New `Don't` rules.** Each visual-evidence agent gets two new entries: "Don't save screenshots to the repo root or any working directory other than the per-run screenshots dir" and "Don't leave unreferenced screenshots behind."

Discovered after a `mattsears18/lightwork` `/shipyard:audit all` run left four screenshots in the repo root (`lw-forgot-password.png`, `lw-login-audit.png`, `lw-marketing-full.png`, `lw-register-audit.png`, ~770 KB total) — never referenced by any committed code, never embedded in the issues they supported, never moved or deleted by the audit's own cleanup. The user had to `git status` and `rm` them by hand. Same general theme as #57 (premature termination cleanup gap), different surface.

### 1.2.5 — 2026-05-20

Adds a `PreToolUse` guard against an agent editing files outside its own worktree. Closes [#60](https://github.com/mattsears18/claude-plugins/issues/60).

The companion hook (`enforce-worktree-isolation.sh`) blocks the dispatch side — refusing any `shipyard:issue-worker` dispatch missing `isolation: "worktree"`. That ensures every worker gets a worktree but doesn't constrain what the worker does once it's running. In a real session, a worker accidentally wrote into the user's primary checkout's `CLAUDE.md`, then caught the drift on the next `git status` and reverted. The next case might not self-catch.

- **New hook `plugins/shipyard/hooks/enforce-edit-scope.sh`.** PreToolUse, matchers `Edit|Write|MultiEdit|NotebookEdit`. Decision: when the hook's `cwd` is inside `.claude/worktrees/agent-<id>/`, the target `file_path` (resolved against `cwd` if relative) MUST resolve to a path inside that worktree. Otherwise exit 2 with a clear stderr explaining the violation and the fix. Edits in the orchestrator's own worktree (`orchestrator-<...>`), bare primary-checkout sessions, and Read/Bash/etc. fall through transparently — the hook only constrains workers, only on write tools.
- **Defensive defaults.** Malformed JSON, missing fields, exotic OS paths — every error path falls through to "allowed." A blocking hook that misfires would break every edit in every worker; we'd rather miss an occasional out-of-scope write than wall up the whole fleet. Walks parts of the cwd path manually (no symlink resolution) so a symlinked worktree root doesn't get rewritten to the underlying mount.
- **Test suite at `plugins/shipyard/hooks/tests/enforce-edit-scope.test.sh`.** 29 cases — in-worktree writes (root + nested), out-of-worktree writes to the primary checkout / sibling agent worktree / unrelated sibling repo, non-edit tools, relative path resolution including `../../../` escapes, malformed-payload safety, and the orchestrator-worktree fall-through. Mirrors the pattern in `scripts/tests/report-plugin-error.test.sh` — pure bash + python3, no external dependencies.
- **`commands/do-work.md` "Don't" extended.** The existing `Don't dispatch without isolation: "worktree"` entry now documents both hooks side-by-side — the dispatch-side guard and the new file-side guard — with the fix-it advice for each block message.

### 1.2.4 — 2026-05-20

Adds an automatic post-run report-writer to `/shipyard:audit` so the consolidated summary survives the session. Closes [#66](https://github.com/mattsears18/claude-plugins/issues/66).

- **New "Write the consolidated report to disk" section** in `plugins/shipyard/commands/audit.md`, appended after the existing "End-of-run summary" section. The orchestrator now persists the same content it emits in chat to `./.shipyard/audits/<YYYY-MM-DD>-shipyard-audit.md` after dispatching its agents and synthesizing the verdict.
- **Same-day collision handling.** If the target file already exists (rerun same day), the writer suffixes `-2`, `-3`, etc. until a free path is found — never clobbers a prior report.
- **No `git add`.** The `.shipyard/` directory is meant to stay local; the host repo decides whether to track it via its own `.gitignore`. Mirrors the convention already used for `.claude/` and `.husky/`.
- **Failure-mode guidance.** If the working directory isn't a git repo or `.shipyard/` can't be created (read-only FS, permissions), the writer reports the failure inline rather than blocking the chat summary.
- **Chat output adds a final "Report saved: …" line** so the user sees where the file landed without having to ask.

Discovered after a `mattsears18/lightwork` `/shipyard:audit all` run that dispatched 12 agents in parallel; the orchestrator produced a great chat summary, then the user asked for a saved report and the main session had to manually rebuild the same markdown table because the original synthesis had already aged out of context. The asymmetry — a complete report exists in the orchestrator's head for ~30 seconds and then is thrown away — was the motivating cost.

### 1.2.3 — 2026-05-20

Replaces the end-of-session drain's hard 15-min cap with a no-forward-progress termination criterion so `/shipyard:do-work` keeps monitoring the merge train until every session PR is genuinely settled. Closes [#57](https://github.com/mattsears18/claude-plugins/issues/57) and [#58](https://github.com/mattsears18/claude-plugins/issues/58).

- **New `session_prs` orchestrator-state set.** Tracks PR numbers this session opened or fix-checks-touched. Populated by step A's reconcile on every `shipped` return (issue, fix-main-ci, fix-failing-prs-batch) and read by the end-of-session drain to decide what to watch and when to exit. Listed as the seventh data structure in the "Orchestrator state" section.
- **`End-of-session drain` section fully rewritten.** Replaces the old "poll every 60s for up to 15 min" rule with per-poll bookkeeping (`O` open, `M_since_last` merged, `R_new` newly-red, `B` ci-blocked, `P_settled` pending-no-churn) and a forward-progress termination criterion: drain continues as long as a merge happened in the last 5 polls OR fix-checks workers are in flight OR any rollup state changed in the last 5 polls. Drain terminates when all three are false for 5 consecutive polls AND every `session_prs` entry is settled. Hard 120-min ceiling as a safety net for degenerate cases.
- **Newly-red PRs during drain dispatch fix-checks.** Drain runs the same dispatcher logic step C uses, with `failed_prs` as the only drainable queue (no new issue work, no diverts — a red main mid-drain is next session's problem). Same `--concurrency` cap, same 3-attempt rule, same `ci-blocked` stamp on exhaustion.
- **`ci-blocked` PRs count as "settled"** for drain-termination purposes — they're the "human needs to look" signal, not a reason to keep polling. The drain's open-PR query intentionally does NOT filter `-label:ci-blocked` (unlike step 5's query) so per-poll counts are accurate.
- **Soft drain second-trigger semantics tightened.** Typing a stop phrase twice while already draining now skips the end-of-session drain phase entirely (was: "skips the CI pending-poll phase"). Whatever's still pending in `session_prs` lands in the summary as "still in flight at exit."
- **End-of-session summary gets a `Drain phase` line** reporting termination reason (`all PRs settled` / `no forward progress for 5 polls` / `120-min ceiling` / `second stop signal — drain skipped`), elapsed minutes, and the final `session_prs` partition (merged / ci-blocked / still-pending) so the user sees at-a-glance whether the session left anything red.
- **New `Don't` rule.** "Don't exit the end-of-session drain while the merge train is still making forward progress" — captures the failure mode that motivated this fix (a 41-PR session on lightwork that terminated with 11 PRs still draining).

Discovered after a `mattsears18/lightwork` session that shipped 41 PRs (#909–#968), then ran cleanup + summary + exit at the 15-min mark with 11 PRs still in the merge train (10 pending CI / auto-merge, 1 ci-blocked). The user had to manually nudge the orchestrator to keep working. The new criterion lets small sessions exit fast and large sessions stay alive until the train is genuinely stalled.

### 1.2.2 — 2026-05-19

Fixes a silent failure mode where foreign `ci-blocked` labels could jam `/shipyard:do-work` forever. Closes [#53](https://github.com/mattsears18/claude-plugins/issues/53) and [#54](https://github.com/mattsears18/claude-plugins/issues/54).

- **Bootstrap `ci-blocked` in step 3a** with a shipyard-ownership description ("Applied by shipyard after 3 failed fix-checks attempts; remove to let shipyard retry"). Closes #53 — the label was referenced in 5 places in `commands/do-work.md` but never created, so the first `gh pr edit --add-label ci-blocked` in a fresh repo errored out.
- **New step 3d auto-clear sweep.** At session start, after the orphan-worktree triage, walk every open PR carrying `ci-blocked` and compare the label's application timestamp (`GET /repos/{owner}/{repo}/issues/{n}/events`, filtered to `event: labeled` + `label.name: ci-blocked`, newest match) against the head commit's `committedDate`. If the commit is newer, remove the label — someone pushed since shipyard gave up, so the "3 attempts then stop" premise no longer applies and the PR flows back into step 5's failing-PR snapshot for another round of fix-checks.
- **Regression guard.** PRs with no new commits since the label was applied stay labeled — the original "human needs to look" semantics (Don't section L873) are preserved. Auto-clear only fires when commit_ts > label_ts.
- **Failure modes fall back to "held."** Deleted head branches, events that aged out of pagination, network blips → the sweep can't make a confident judgment, so the label stays. Next session retries.
- **Step 2 backlog overview gets a PR-side block.** When `ci-blocked` PRs exist, the upfront summary now reports `<c> total · will be re-evaluated this session: <k> · held (no new commits): <h>` with PR numbers — so the user sees the wall instead of silently building behind it.
- **Don't section L873 + L879 extended** to document the new lifecycle: applied by step A's fix-checks reconcile, removed only by step 3d's auto-clear sweep. Anything else flipping the label is foreign.

Discovered today on `mattsears18/lightwork` — several open `@me` PRs were carrying `ci-blocked` labels of unknown origin (the label existed in the repo but shipyard's label-bootstrap never created it; someone had hand-created it to match the spec). The orchestrator dutifully filtered them out via `-label:ci-blocked -is:draft` and idled with work still red on the board, with no surfacing in the upfront summary.

### 1.2.1 — 2026-05-19

Replaces the README's embedded infographic PNG (1920×1200, 161 KB) with an SVG export (735 KB, optimized via svgo). The SVG renders crisply at any DPI — eliminating the soft-text issue on retina / 4K displays. Figma exports text as outlined paths rather than `<text>` nodes, so the SVG is font-independent (no Inter dependency for viewers). Closes [#51](https://github.com/mattsears18/claude-plugins/issues/51).

### 1.2.0 — 2026-05-19

**Breaking: the session-stamp label `do-work` was renamed to `shipyard`** to match the plugin's name. Every issue and PR `/do-work` touches now carries the `shipyard` label. Closes [#47](https://github.com/mattsears18/claude-plugins/issues/47).

The plugin is named `shipyard`. The slash command is `/shipyard:do-work`. The agent is `shipyard:issue-worker`. The lone outlier was the label, which still referenced the old slug — confusing in the orchestrator's end-of-session summary ("PRs opened with do-work label (lifetime)") and out of step with the rest of the rename.

What changed inside the plugin tree:

- `plugins/shipyard/commands/do-work.md` — step 3a now creates the `shipyard` label (with description `"Worked on by /shipyard:do-work"`); all dispatch-template `--label do-work` references → `--label shipyard`; the self-assign line in dispatch rule #3 (`--add-label do-work`) → `--add-label shipyard`; the orphan-triage `gh issue list --label do-work` filter → `--label shipyard`; the end-of-session lifetime queries → `--label shipyard`; the "Don't remove the `do-work` label" rule → "Don't remove the `shipyard` label".
- `plugins/shipyard/agents/issue-worker.md` — the three `--label do-work` references inside the in-spec PR-creation snippets (normal mode, fix-main-ci mode, fix-failing-prs-batch mode) all flip to `--label shipyard`.

What did NOT change (deliberately):

- The branch convention `do-work/issue-<N>` (and `do-work/fix-main-ci-<short-sha>` / `do-work/fix-pr-pileup-<short-timestamp>`) — branches are a separate decision. If we want to flip those too, that's a separate follow-up.
- The slash command name `/do-work` (full slug `/shipyard:do-work`).
- The refinement-agent sentinel `<!-- do-work-refinement-agent -->` — that's an idempotency marker, not a label.
- Historical references in CHANGELOG entries describing past work.

**Migration for users with external automation keyed on the `do-work` label.** Rename the existing label in place — this preserves all associations with closed issues and merged PRs:

```bash
gh label edit do-work --repo <your-owner/your-repo> \
  --name shipyard \
  --description "Worked on by /shipyard:do-work"
```

If your `gh` version doesn't support `gh label edit --name`, fall back to create-new + add-to-all + delete-old:

```bash
gh label create shipyard --repo <your-owner/your-repo> \
  --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
for n in $(gh issue list --repo <your-owner/your-repo> --label do-work --state all --limit 1000 --json number --jq '.[].number'); do
  gh issue edit "$n" --repo <your-owner/your-repo> --add-label shipyard
done
for n in $(gh pr list --repo <your-owner/your-repo> --label do-work --state all --limit 1000 --json number --jq '.[].number'); do
  gh pr edit "$n" --repo <your-owner/your-repo> --add-label shipyard
done
gh label delete do-work --repo <your-owner/your-repo> --confirm
```

External dashboards, GitHub Actions, or scripts that filter PRs/issues by `label:do-work` need to flip to `label:shipyard`. The `/do-work` command's step-3a label-create block is already idempotent — it will create the new `shipyard` label on first run in any repo, so users don't need to do the migration step manually unless they have historical `do-work`-labeled issues/PRs they want to preserve.

### 1.1.3 — 2026-05-19

Adds a new root-`README.md` section — **"Plays well with everything that files GitHub issues"** — placed between **See it in action** and **Install**. Closes [#48](https://github.com/mattsears18/claude-plugins/issues/48).

- Frames shipyard as the back half of a self-healing loop: anything that auto-files GitHub issues (Sentry, Datadog, Dependabot, GHAS/CodeQL, customer-support integrations, your own infra) becomes work shipyard can do.
- Includes an illustrative Sentry round-trip walkthrough (exception → Sentry-filed issue → `/do-work` picks it up → PR with `Closes #N` → auto-merge → Sentry issue closes). Called out as illustrative, not a case study.
- Keeps honest caveats: upstream issue quality matters, user feedback still flows through `/refine-feedback` + human gate, not everything is auto-fixable, label hygiene at the auto-filer matters for ranking.
- No code changes; plugin behavior is unchanged from 1.1.2.

### 1.1.2 — 2026-05-19

- docs: refresh embedded README infographic with full footer band

### 1.1.1 — 2026-05-19

Embeds the Shipyard infographic (technical version, 1600×900) above the fold in the root `README.md`. Closes [#43](https://github.com/mattsears18/claude-plugins/issues/43).

- Adds `docs/images/shipyard-infographic.png` — a five-stage diagram of the autonomous engineering loop (Sources → Refine + Review → Orchestrator → Workers → PR Pipeline).
- Inserts a centered `<img>` block in `README.md` immediately after the intro paragraph, with a one-line caption linking to the `#shipyard` section for the prose walkthrough.
- No code changes; plugin behavior is unchanged from 1.1.0.

### 1.1.0 — 2026-05-19

Removes the optional main-CI statusline feature. The script (`plugins/shipyard/scripts/statusline.sh`), its README section, and the `SHIPYARD_STATUSLINE_CACHE_TTL` env var reference are gone. Closes [#40](https://github.com/mattsears18/claude-plugins/issues/40).

The feature wasn't working in practice and the maintenance cost of a broken-but-documented surface exceeded its value. The orchestrator-printed "status line" in `/do-work` (the `/do-work · <repo> · main:<emoji> · ...` header) is a different feature and is unchanged.

Migration for anyone wiring the script into their Claude Code settings: drop the `statusLine` block from `~/.claude/settings.json` (or the per-project `.claude/settings.json`) that points at `${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh`. No data loss — the script's cache was a 30s file in `$TMPDIR` and clears itself.

### 1.0.1 — 2026-05-19

Docs-only refresh of the root `README.md` after the `app-audits` → `shipyard` rename in 1.0.0. Closes [#39](https://github.com/mattsears18/claude-plugins/issues/39).

- Adds a **Quick start** above-the-fold section with copy-pasteable install + first `/do-work` invocation.
- Adds a **How it works** section with a prose walkthrough of the autonomous engineering loop (inputs → refine → human review → orchestrator → workers → PR → auto-merge). Links to [#37](https://github.com/mattsears18/claude-plugins/issues/37) for the in-progress Figma infographic.
- Adds a **What's been hardened** section listing safety properties that have actually shipped, each linked to its issue: idle prevention ([#23](https://github.com/mattsears18/claude-plugins/issues/23)), user-feedback intake ([#24](https://github.com/mattsears18/claude-plugins/issues/24)), `--no-verify` guards ([#26](https://github.com/mattsears18/claude-plugins/issues/26)), pre-dispatch backlog re-check ([#29](https://github.com/mattsears18/claude-plugins/issues/29)), orchestrator worktree isolation ([#34](https://github.com/mattsears18/claude-plugins/issues/34)).
- Adds a **See it in action** section linking to the filtered list of `do-work`-labeled merged PRs as living proof.
- Updates the **Layout** file tree to match the current `plugins/shipyard/` structure (commands/agents/skills/hooks/scripts/assets).
- No behavior changes; plugin code, hooks, and commands are unchanged from 1.0.0.

### 1.0.0 — 2026-05-19

**Breaking: plugin renamed from `app-audits` → `shipyard`.** Every slug under the old prefix moves to the new one (`shipyard:do-work`, `shipyard:audit`, `shipyard:issue-worker`, `shipyard:lighthouse-auditor`, `shipyard:security-auditor`, `shipyard:dx-auditor`, etc.). Closes [#25](https://github.com/mattsears18/claude-plugins/issues/25).

The plugin started as an audit suite but grew into a general-purpose autonomous engineering loop: audits surface work, users feed work in, an orchestrator refines / dispatches / fixes / ships, and a fleet of specialized agents do hands-on work in parallel worktrees. The old name no longer fit. `shipyard` captures the mental model — many specialists working in parallel on different vessels at every stage of their lifecycle, coordinated by a foreman.

Migration: anything referencing `app-audits:*` in scripts, settings, or `subagent_type` dispatches must flip to `shipyard:*`. No alias layer ships; this is a clean cutover.

Other changes in this release:

- `plugin.json` description + keywords rewritten to reflect the broader scope (orchestrator, autonomous-agents, backlog-burndown alongside the existing audit-flavored keywords).
- `marketplace.json` entry: `category` flipped from `quality` → `engineering`; `source` repointed to `./plugins/shipyard`.
- Statusline cache TTL env var renamed: `APP_AUDITS_STATUSLINE_CACHE_TTL` → `SHIPYARD_STATUSLINE_CACHE_TTL`.
- `enforce-worktree-isolation` hook now matches `subagent_type: "shipyard:issue-worker"` in incoming tool calls (was `app-audits:issue-worker`).
- README, plugin tree, and all internal cross-references updated atomically.

### 0.15.x and earlier

Released under the `app-audits` name. See [git log](https://github.com/mattsears18/claude-plugins/commits/main/plugins/shipyard) for the full history.
