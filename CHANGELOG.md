# Changelog

All notable changes to the plugins in this repository will be documented here.

## shipyard

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
