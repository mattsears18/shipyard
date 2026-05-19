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

## Optional: auto-file issues on skill/agent failure

The `app-audits` plugin can automatically file a GitHub issue against `mattsears18/claude-plugins` whenever one of its own skills or agents appears to have failed during your session. The point: real failures become structured bug reports without anyone having to type one up.

It is **opt-in** — nothing is filed unless you set:

```sh
export CLAUDE_PLUGINS_AUTOREPORT=1
```

Once enabled, hooks (`PostToolUse` on `Task|Agent` and `SubagentStop`) invoke `plugins/app-audits/scripts/report-plugin-error.sh`. That script:

1. **Detects** failure signals — `is_error: true`, `error:` / `stderr:` fields, or `blocked:` / `Error:` / `Traceback (...)` / `Fatal:` markers in the agent output. Only acts on subagents/skills whose name starts with `app-audits:`.
2. **Scrubs secrets** — GitHub PATs (`ghp_…`), Anthropic / OpenAI keys (`sk-ant-…`, `sk-…`), AWS access keys, `Authorization:` / `Bearer …` headers, email addresses, `$HOME` paths, and any 40+ char hex blob.
3. **Builds a signature** from the skill/agent name + a digit-normalized error excerpt, then **searches open `auto-reported` issues** for a match. If found → adds a comment with the new occurrence. If not → files a fresh issue with `auto-reported` and `bug` labels.
4. **Never breaks your session** — the helper traps errors and always exits 0. The hook runs the helper detached in the background so reports don't block the foreground.

### Configuration

| Env var | Default | Effect |
|---|---|---|
| `CLAUDE_PLUGINS_AUTOREPORT` | unset | Must be `1` to enable. |
| `CLAUDE_PLUGINS_AUTOREPORT_REPO` | `mattsears18/claude-plugins` | Target repo for auto-reports. |
| `CLAUDE_PLUGINS_AUTOREPORT_DRY` | unset | When `1`, the helper prints the would-be issue as JSON to stdout instead of calling `gh`. Used by the test suite and useful for local previews. |

### Issue shape

Every auto-report has these sections:

- `## What happened` — short failure summary.
- `## Skill/Agent` — name, hook event, tool.
- `## Reproduction` — invoking prompt + description (scrubbed).
- `## Error details` — first ~2000 chars of the failure output (scrubbed).
- `## Environment` — OS, shell, Claude Code version, model.
- `## Transcript excerpt` — last 80 lines of the agent transcript, scrubbed.
- `## Recommendations for improvement` — pattern-level suggestions for maintainers.
- An HTML-comment de-dup signature: `<!-- autoreport-key=<skill>::<normalized-error> -->`.

### Try it out (dry run)

```sh
echo '{"tool_name":"Agent","tool_input":{"subagent_type":"app-audits:issue-worker","prompt":"work issue 1"},"tool_response":{"is_error":true,"error":"Error: gh api 404"}}' \
  | CLAUDE_PLUGINS_AUTOREPORT=1 CLAUDE_PLUGINS_AUTOREPORT_DRY=1 \
    bash plugins/app-audits/scripts/report-plugin-error.sh
```

You'll get a JSON blob with the `title`, `body`, `labels`, `signature`, and `who` that *would* have been filed.

### Test suite

```sh
bash plugins/app-audits/scripts/tests/report-plugin-error.test.sh
```

### Follow-ups

- v1 ships with `auto-reported` and `bug` labels only. Per-skill / per-agent labels (e.g. `skill:filing-github-issues`, `agent:issue-worker`) are deferred to keep label cardinality controlled until we see what categories actually show up in practice.

## License

MIT
