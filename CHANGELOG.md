# Changelog

All notable changes to the plugins in this repository will be documented here.

## shipyard

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
