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

Each audit runs in an isolated subagent, files its own issues using the shared `filing-github-issues` skill (Conventional Commits titles, label discovery, duplicate search), and respects the severity rules in `audit-rubrics` (P0–P2 file, P3 skip). Fully autonomous — no approval gates.

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
```

## License

MIT
