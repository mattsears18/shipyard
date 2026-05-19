# mattsears-plugins

Personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugins by Matt Sears.

## Plugins

### `app-audits`

Audit web + mobile apps across UX, performance, security, and accessibility — autonomously files GitHub issues for every finding.

**Surfaces:**

- `/audit lighthouse <url>` — perf / SEO / best-practices / agentic browsing via Lighthouse
- `/audit web-ux <url>` — live tour via Chrome DevTools MCP
- `/audit mobile-ux` — review of stored screenshots (`store-assets/screenshots/{ios,android}/*`)
- `/audit ux <url>` — web-ux + mobile-ux in parallel
- `/audit security <url>` — deps, secrets in git, Firebase rules, headers, mobile manifests
- `/audit a11y <url>` — Lighthouse a11y category + manual keyboard / screen-reader tour
- `/audit all <url>` — every audit in parallel

Each audit runs in an isolated subagent, files its own issues using the shared `filing-github-issues` skill (Conventional Commits titles, label discovery, duplicate search), and respects the severity rules in `audit-rubrics` (P0–P2). Fully autonomous — no approval gates.

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
