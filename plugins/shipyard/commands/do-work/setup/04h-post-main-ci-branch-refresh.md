# /shipyard:do-work — Setup phase · post-main-CI-fix branch-refresh

Fragment of step **4.5a** ([`04-backlog-divert.md`](./04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)) — deep-link only, from `04`'s `main_ci.status == "green"` transition bullet. Not part of the ordered per-session walk; loaded only when that transition fires.

#### Post-main-CI-fix branch-refresh — un-stick session PRs carrying a stale failing required check ([#993](https://github.com/mattsears18/shipyard/issues/993))


GitHub does **not** re-run a PR's already-completed required check just because the PR's base branch went from red to green — without a new commit or an explicit branch update, a PR that recorded a `FAILURE` while `main` was broken keeps that stale conclusion forever, even though the underlying cause is now fixed and a fresh run would pass. Left unhandled, this permanently strands every `session_prs` entry that happened to run its required checks during the `main`-red window: `mergeStateStatus` reads `MERGEABLE` and auto-merge is armed, but the stale check will never re-run on its own, so the PR sits `BLOCKED` indefinitely — even though a `fix-main-ci` dispatch already landed the remedy and `main` is green again. See [RATIONALE → Stale-red vs genuinely-red](../../do-work-RATIONALE.md#stale-red-vs-genuinely-red-993) for the session repro that motivated this (a 7-PR merge train left `BLOCKED` forever after the diversion that unblocked it had already merged).

**Fires immediately after the `main_ci.status == "green"` bullet above, and only on a genuine transition into green** — never on every green evaluation, because a PR carrying a check that's failing against the *current, already-fixed* `main` must NOT get a masking re-run. Before overwriting the cached `main_ci` object with this evaluation's result, capture its existing `.status` as `previous_main_ci_status` (an absent/first-run cache counts as non-green). The refresh below runs only when `previous_main_ci_status != "green"` AND the freshly-computed `main_ci.status == "green"`.

**Extracted to [`scripts/stale-check-refresh.sh`](../../../scripts/stale-check-refresh.sh) ([#1277](https://github.com/mattsears18/shipyard/issues/1277))** — this used to be an inline `for pr in $session_prs; do ... done` loop with three internal `gh pr view | jq` pipes, both shapes the worktree-isolation guard refuses post-relocation. The script is the normative implementation now (mirroring `backlog-filter.sh classify`'s #1247 precedent) — see [`dont.md`'s post-relocation compound-block rule](../dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277) for when to extract vs. decompose in place. Side benefit: the script's `--state-file` gives "once per PR per fix" a real persistence mechanism — the old inline loop's bash associative array could not actually survive between the separate Bash calls this check runs from, so that guarantee never held in practice.

`$previous_main_ci_status != "green"` → run the command sequence below. `$previous_main_ci_status == "green"` → skip this section entirely; don't run it.

Resolve the pin, read the fix commit's SHA and date, then call the script — all in **one** `Bash` call (plain sequential statements, no loop/pipe/`if`, so keeping them together avoids re-deriving `$fix_commit_sha` / `$fix_commit_date` in a second call that could never see them otherwise — a shell variable does not survive between separate `Bash` tool calls):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
fix_commit_sha=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.sha')
fix_commit_date=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.commit.committer.date')
"$CLAUDE_PLUGIN_ROOT/scripts/stale-check-refresh.sh" run \
  --repo <owner/repo> \
  --fix-commit-sha "$fix_commit_sha" \
  --fix-commit-date "$fix_commit_date" \
  --session-prs "$session_prs"
```

**Guards, matching the issue's suggested fix exactly (now implemented inside the script):**

- **Only for PRs whose failing check predates the fix.** A PR whose latest failing run completed *after* `fix_commit_date` already ran against the fixed base and is genuinely red — running `gh pr update-branch` there would mask a real failure behind a fresh run rather than surface it. The `completedAt < fix_commit_date` comparison (latest-per-name, the same de-duplication convention used throughout [drain.md](../drain.md#drain-protocol) and [steady-state.md](../steady-state.md#a1-parse-the-return-string)) is what tells stale-red apart from genuinely-red.
- **Once per PR per fix, never in a loop.** The script's `--state-file` (`.shipyard-stale-refresh-done` by default, in the orchestrator worktree root) records the `main` SHA the refresh already ran against for that PR; it prevents a second re-poll from calling `update-branch` again for the same fix before the freshly-triggered check has had a chance to complete.
- **Skip DIRTY PRs.** Those belong to `fix-rebase`, not this gate — `gh pr update-branch` rebases a DIRTY branch onto the new base as a side effect, which is a different, already-bookkept code path (`rebase_success_counts`, `rebase_blocked_prs` in [drain.md](../drain.md#drain-protocol)). Leaving DIRTY PRs to that existing mechanism avoids double-counting a rebase outside its owning bookkeeping.

**Session-scoped state.** `.shipyard-stale-refresh-done` (a per-session, per-PR-and-SHA append-only text file) lives in the orchestrator worktree, never persisted across sessions — a fresh session starts without it and re-evaluates from scratch, which is safe since the dedup only prevents redundant `update-branch` calls within one continuous drive of the same fix.

This mechanism is **evaluated at every call site that runs 4.5a** — session setup and [step D's periodic refresh](../steady-state.md#d-periodic-refresh) — so it fires automatically the first time either path observes the red→green transition; no separate wiring is needed at either call site. See [drain.md's post-main-CI-fix branch-refresh](../drain.md#post-main-ci-fix-branch-refresh-drain-phase-993) for the corresponding drain-phase health read — drain does not enqueue new `divert_queue` work, but it still needs to observe this same transition so a fix that lands *during* drain un-sticks the PRs it stranded, rather than leaving the whole merge train `BLOCKED` for the next session to discover.
