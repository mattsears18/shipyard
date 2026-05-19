# mattsears-plugins

Personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugins by Matt Sears.

## What's in this repo

A growing set of Claude Code plugins for software engineering automation. Today the headliner is `app-audits` — an autonomous engineering loop that discovers work via audits, refines raw user feedback into actionable tickets, and burns down the backlog with a rolling pool of parallel workers.

> The `app-audits` plugin is being renamed to `shipyard` — see [#25](https://github.com/mattsears18/claude-plugins/issues/25). The "audits" framing no longer fits what the plugin does.

## Plugins

### `app-audits`

An autonomous engineering loop for web + mobile app development. Three things it does:

1. **Finds work** — `/audit` runs deep audits across UX, performance, security, accessibility, DX, privacy, PWA readiness, release readiness, SEO, tech debt, and testing, and autonomously files GitHub issues for every finding.
2. **Refines work** — `/refine-feedback` ingests raw user-feedback issues (filed into the repo by your app's feedback form via a backend proxy), classifies them (already-done / decline / legitimate), preserves the original text in a comment, and rewrites the body to be implementation-ready. Gated by a `needs-human-review` label so no code-modifying agent runs until a human signs off.
3. **Does work** — `/do-work` orchestrates a rolling pool of parallel issue-workers, each in an isolated git worktree. It dispatches up to `--concurrency` workers at once, opens PRs with auto-merge, and gracefully handles failing checks, red main CI, and PR pileups via specialized diversion workers.

**Slash commands:**

- `/audit lighthouse <url>` — perf / SEO / best-practices / agentic browsing via Lighthouse
- `/audit web-ux <url>` — live tour via Chrome DevTools MCP
- `/audit mobile-ux` — review of stored screenshots (`store-assets/screenshots/{ios,android}/*`)
- `/audit ux <url>` — web-ux + mobile-ux in parallel
- `/audit security <url>` — deps, secrets in git, Firebase rules, headers, mobile manifests
- `/audit a11y <url>` — Lighthouse a11y category + manual keyboard / screen-reader tour
- `/audit dx` — developer-experience catalog (lints, hooks, observability, contributor docs, etc.)
- `/audit all <url>` — every audit in parallel
- `/refine-feedback` — process raw user-feedback issues (classify, preserve, rewrite, sign-off gate)
- `/do-work` — burn down the issue backlog with a rolling pool of parallel workers

Each audit runs in an isolated subagent, files its own issues using the shared `filing-github-issues` skill (Conventional Commits titles, label discovery, duplicate search), and respects the severity rules in `audit-rubrics` (P0–P2). Fully autonomous — no per-step approval gates.

## Install

```sh
claude plugin marketplace add mattsears18/claude-plugins
claude plugin install app-audits@mattsears-plugins
```

Restart Claude Code after install. `/audit` should now be available.

## Layout

```
.claude-plugin/marketplace.json
plugins/
  app-audits/
    .claude-plugin/plugin.json
    commands/audit.md
    agents/
      lighthouse-auditor.md
      web-ux-auditor.md
      mobile-ux-auditor.md
      security-auditor.md
      a11y-auditor.md
    skills/
      filing-github-issues/SKILL.md
      audit-rubrics/SKILL.md
    scripts/
      statusline.sh
```

## Optional: main-CI statusline

The `app-audits` plugin ships `scripts/statusline.sh` — a Claude Code statusline that polls the **last completed CI run on the default branch** for the cwd's GitHub repo and renders it in your status bar:

- `main:✓` (green) — last completed run was a success
- `main:✗ #<run-id>` (red) — last completed run failed; ID is the *earliest unfixed* red run (where the streak started)
- `main:?` (dim) — not a GitHub repo, no completed runs yet, or `gh` not authed

Pairs naturally with `/do-work` — when the orchestrator diverts a worker to fix main, the statusline shows you exactly why.

Wire it up by adding to `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project):

```json
{
  "statusLine": {
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh"
  }
}
```

The script caches each repo's status for 30s (override via `APP_AUDITS_STATUSLINE_CACHE_TTL`), so it's a single `gh` call per repo per cache window — cheap to keep running.

## License

MIT
