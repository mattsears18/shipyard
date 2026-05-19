# Changelog

All notable changes to the plugins in this repository will be documented here.

## shipyard

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
