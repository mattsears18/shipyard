# Changelog

All notable changes to the plugins in this repository will be documented here.

## shipyard

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
