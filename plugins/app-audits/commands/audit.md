---
description: Audit a web/mobile app across one or more dimensions and autonomously file GitHub issues for the findings.
argument-hint: <type|all> [url] [--repo owner/repo]
---

# /audit

Run an autonomous audit and file GitHub issues for every finding. No approval gates — file first, summarize after.

## Args

`$ARGUMENTS` may include:

- **Audit type** (required, first positional): one of `lighthouse`, `web-ux`, `mobile-ux`, `ux` (= web-ux + mobile-ux), `security`, `a11y`, `seo`, `privacy`, `release-readiness`, `pwa`, `tech-debt`, `testing`, `dx`, or `all`.
- **URL** (optional, second positional, web audits only): the page to audit. If omitted and the audit needs a URL, ask via `AskUserQuestion`.
- **--repo owner/repo** (optional): target GitHub repo. If omitted, auto-detect via `gh repo view --json nameWithOwner -q .nameWithOwner`. If that fails (not in a repo), ask via `AskUserQuestion`.

## Dispatching

Resolve the target repo *once* in the main session and pass it to every agent. Then dispatch:

| Type | Agents to dispatch | Needs URL? |
|---|---|---|
| `lighthouse` | `app-audits:lighthouse-auditor` | yes |
| `web-ux` | `app-audits:web-ux-auditor` | yes |
| `mobile-ux` | `app-audits:mobile-ux-auditor` | no |
| `ux` | `web-ux-auditor` + `mobile-ux-auditor` (parallel) | yes (web side) |
| `security` | `app-audits:security-auditor` | optional |
| `a11y` | `app-audits:a11y-auditor` | yes |
| `seo` | `app-audits:seo-auditor` | yes |
| `privacy` | `app-audits:privacy-auditor` | optional |
| `release-readiness` | `app-audits:release-readiness-auditor` | optional |
| `pwa` | `app-audits:pwa-auditor` | yes |
| `tech-debt` | `app-audits:tech-debt-auditor` | no |
| `testing` | `app-audits:testing-auditor` | no |
| `dx` | `app-audits:dx-auditor` | no |
| `all` | every agent above (parallel) | yes |

When dispatching multiple agents, send them as multiple `Agent` tool calls in a single message so they run concurrently.

Every agent applies its own `audit:<dimension>` label to issues it files — that gives the tracker a single filter dimension to find issues by audit source (e.g. `is:open label:audit:lighthouse`).

## Agent prompt template

Build each agent prompt like:

> Audit `<URL or repo>` for `<audit-type>` and file GitHub issues in `<owner/repo>`. Use the shared `app-audits:filing-github-issues` skill for filing conventions and `app-audits:audit-rubrics` for severity/grouping. File P0–P2 findings autonomously — no approval gates. Return a one-paragraph summary of what was filed.

## End-of-run summary

Once all agents return, present a consolidated summary:

- **Per-audit verdict** (one line each)
- **Issues filed** (numbered list with URLs, grouped by audit)
- **Skipped — duplicates** (with links to the existing issues)
- **Out of scope / surfaces not reviewed** (so the user can ask for follow-ups)

Do not file any issues from the main session — that's each agent's job. The main session orchestrates and reports.
