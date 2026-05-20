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
| `lighthouse` | `shipyard:lighthouse-auditor` | yes |
| `web-ux` | `shipyard:web-ux-auditor` | yes |
| `mobile-ux` | `shipyard:mobile-ux-auditor` | no |
| `ux` | `web-ux-auditor` + `mobile-ux-auditor` (parallel) | yes (web side) |
| `security` | `shipyard:security-auditor` | optional |
| `a11y` | `shipyard:a11y-auditor` | yes |
| `seo` | `shipyard:seo-auditor` | yes |
| `privacy` | `shipyard:privacy-auditor` | optional |
| `release-readiness` | `shipyard:release-readiness-auditor` | optional |
| `pwa` | `shipyard:pwa-auditor` | yes |
| `tech-debt` | `shipyard:tech-debt-auditor` | no |
| `testing` | `shipyard:testing-auditor` | no |
| `dx` | `shipyard:dx-auditor` | no |
| `all` | every agent above (parallel) | yes |

When dispatching multiple agents, send them as multiple `Agent` tool calls in a single message so they run concurrently.

Every agent applies its own `audit:<dimension>` label to issues it files — that gives the tracker a single filter dimension to find issues by audit source (e.g. `is:open label:audit:lighthouse`).

## Agent prompt template

Build each agent prompt like:

> Audit `<URL or repo>` for `<audit-type>` and file GitHub issues in `<owner/repo>`. Use the shared `shipyard:filing-github-issues` skill for filing conventions and `shipyard:audit-rubrics` for severity/grouping. File P0–P2 findings autonomously — no approval gates. Return a one-paragraph summary of what was filed.

## Pre-dispatch: create the screenshots directory

Before dispatching any visual-evidence auditor (`web-ux`, `a11y`, `mobile-ux`), create the per-run screenshots directory so the agents can route output there without re-checking:

```bash
mkdir -p ".shipyard/audits/$(date +%Y-%m-%d)/screenshots"
```

This directory is a sibling to the `<YYYY-MM-DD>-shipyard-audit.md` report this command writes after the run, and is the orchestrator's promise to the auditors: the path exists and is safe to write into. Auditors save screenshots there with stable, finding-keyed filenames (e.g. `login.png`, `modal-focus-trap.png`), embed them via relative path in issue bodies (`![](./.shipyard/audits/<YYYY-MM-DD>/screenshots/<file>.png)`), and delete any unreferenced screenshots before returning. The user-visible effect is that `git status` after `/shipyard:audit` no longer shows stray PNGs in the repo root — all audit artifacts live under `.shipyard/` and stay out of the host repo's tracked tree (unless the host repo opts to commit them via its own `.gitignore` rules).

## End-of-run summary

Once all agents return, present a consolidated summary:

- **Per-audit verdict** (one line each)
- **Issues filed** (numbered list with URLs, grouped by audit)
- **Skipped — duplicates** (with links to the existing issues)
- **Out of scope / surfaces not reviewed** (so the user can ask for follow-ups)

Do not file any issues from the main session — that's each agent's job. The main session orchestrates and reports.

## Write the consolidated report to disk

After emitting the chat summary, persist the same content to `./.shipyard/audits/<YYYY-MM-DD>-shipyard-audit.md` so it survives the session. Don't skip this step — the data is already in your context; the cost of writing it is one tool call and the value of having it on disk is large.

1. **Create the directory if missing**, scoped to the host repo's working directory:

   ```bash
   mkdir -p .shipyard/audits
   ```

   Do NOT `git add` it. The directory is meant to stay local — the host repo decides whether to track `.shipyard/` via its own `.gitignore`.

2. **Compute the target path.** Base name is `<YYYY-MM-DD>-shipyard-audit.md` using today's date in the local timezone. If that file already exists (rerun same day), suffix `-2`, `-3`, etc. until a free path is found — don't clobber. Suggested check:

   ```bash
   base="$(date +%Y-%m-%d)-shipyard-audit"
   path=".shipyard/audits/${base}.md"
   n=2
   while [ -e "$path" ]; do path=".shipyard/audits/${base}-${n}.md"; n=$((n+1)); done
   ```

3. **Write the report** using the `Write` tool. Mirror the same structure the chat summary emitted, plus a metadata header. Recommended layout:

   ```markdown
   # Shipyard audit — <target URL or owner/repo> — <YYYY-MM-DD>

   - **Target:** <URL or owner/repo>
   - **Branch / SHA:** <branch>@<short-sha> (if known)
   - **Audit type(s):** <type list, e.g. `all` or `lighthouse, security, a11y`>
   - **Dispatched agents:** <agent slugs, comma-separated>
   - **Total issues filed:** <count>

   ## Per-audit verdict

   | Audit | Verdict | Filed |
   |---|---|---|
   | <audit> | <one-line verdict> | <count> |

   ## Issues filed

   ### <audit-name>

   - [#<n>] <title> — <severity> — <issue URL>

   ## Highest-signal findings

   1. <cross-cutting item 1>
   2. <cross-cutting item 2>
   ...

   ## Surfaces NOT reviewed

   - <surface or dimension not covered, with a one-line reason or follow-up suggestion>

   ## Process notes

   - <agent failures, partial returns, skipped dispatches, e.g. "lighthouse-auditor returned a grouping but didn't file via gh">
   ```

   Omit sections that have no content (e.g. no skipped audits → drop "Surfaces NOT reviewed"). Don't pad — empty bullets are noise.

4. **Surface the path in chat** as the last line of your reply so the user sees where it landed:

   > Report saved: `.shipyard/audits/<filename>.md`

If the working directory isn't a git repo or `.shipyard/` can't be created (read-only filesystem, permissions), report the failure inline (`Report could not be saved: <reason>`) and continue — don't block the chat summary on it.
