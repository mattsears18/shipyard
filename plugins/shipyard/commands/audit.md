---
description: Audit a web/mobile app across one or more dimensions and autonomously file GitHub issues for the findings.
argument-hint: <type|all> [url] [--repo owner/repo]
---

# /audit

Run an autonomous audit and file GitHub issues for every finding. No approval gates — file first, summarize after.

## Args

`$ARGUMENTS` may include:

- **Audit type** (required, first positional): one of `lighthouse`, `web-ux`, `mobile-ux`, `ux` (= web-ux + mobile-ux), `security`, `a11y`, `seo`, `privacy`, `release-readiness`, `pwa`, `tech-debt`, `testing`, `dx`, `docs`, or `all`.
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
| `docs` | `shipyard:docs-auditor` | no |
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

This directory is a sibling to the `<YYYY-MM-DD>-shipyard-audit.html` report this command writes after the run, and is the orchestrator's promise to the auditors: the path exists and is safe to write into. Auditors save screenshots there with stable, finding-keyed filenames (e.g. `login.png`, `modal-focus-trap.png`), embed them via relative path in issue bodies (`![](./.shipyard/audits/<YYYY-MM-DD>/screenshots/<file>.png)`), and delete any unreferenced screenshots before returning. The user-visible effect is that `git status` after `/shipyard:audit` no longer shows stray PNGs in the repo root — all audit artifacts live under `.shipyard/` and stay out of the host repo's tracked tree (unless the host repo opts to commit them via its own `.gitignore` rules).

## End-of-run summary

Once all agents return, present a consolidated summary:

- **Per-audit verdict** (one line each)
- **Issues filed** (numbered list with URLs, grouped by audit)
- **Skipped — duplicates** (with links to the existing issues)
- **Out of scope / surfaces not reviewed** (so the user can ask for follow-ups)

Do not file any issues from the main session — that's each agent's job. The main session orchestrates and reports.

## Write the consolidated report to disk

After emitting the chat summary, persist the same content to `./.shipyard/audits/<YYYY-MM-DD>-shipyard-audit.html` so it survives the session. Don't skip this step — the data is already in your context; the cost of writing it is one tool call and the value of having it on disk is large.

Reports are **styled HTML, not markdown** — markdown is fine for grep / version control / diffing but a poor end-user surface. The maintainer wants to read these in a browser with typography, sectioning, status-colored severity badges, hover states, and clickable issue/PR links. The HTML target also makes "save to PDF" trivial via the print stylesheet. Reports are static (one-shot generation, no JS, no live updates); they're the HTML version of what was already `.md`.

1. **Create the directory if missing**, scoped to the host repo's working directory:

   ```bash
   mkdir -p .shipyard/audits
   ```

   Do NOT `git add` it. The directory is meant to stay local — the host repo decides whether to track `.shipyard/` via its own `.gitignore`.

2. **Ensure the shared stylesheet exists at `.shipyard/styles.css`.** Every report links to this single file via a relative `../styles.css` href, so all reports under `.shipyard/audits/` and `.shipyard/do-work/` share one CSS source. The CSS is per-host-repo — it sits in the host repo's `.shipyard/`, NOT bundled in the plugin — so the plugin's job is to *write* the file the first time any report-writing command runs against the host repo and never again. Each report-writing command (this one, `/shipyard:do-work`, any future report writer) runs the same idempotent check:

   ```bash
   if [ ! -f .shipyard/styles.css ]; then
     # Write the default stylesheet — see template below
     :
   fi
   ```

   **Idempotency rule:** only write when the file does not exist. If the user has hand-edited `.shipyard/styles.css`, do NOT clobber it — the leading version comment (`/* shipyard-styles v1 — ... */`) lets a future migration tool detect "default version" vs "user-modified," but this command never overwrites. Also do NOT `git add` it — same gitignore convention as the rest of `.shipyard/`.

   **Default stylesheet template** — ~150 lines max, dark-theme default with light-theme override via `prefers-color-scheme`, system font stack, status-colored badges (P0 red, P1 orange, P2 yellow, merged green, open blue), subtle bordered/rounded sections, zebra-striped tables with right-aligned numeric columns and hover row highlight, issue-link styling with muted `#` prefix and `PR` badge variant, one-time print stylesheet so the user can save to PDF cleanly. Write this exact content via the `Write` tool when the file is missing:

   ```css
   /* shipyard-styles v1 — written by /shipyard:audit and /shipyard:do-work; safe to hand-edit (plugin only writes when missing) */
   :root {
     color-scheme: dark light;
     --bg: #0a0c10;
     --bg-elev: #11151c;
     --bg-elev-2: #161b24;
     --border: #1f2630;
     --border-strong: #2a3340;
     --text: #e6edf3;
     --text-dim: #8b949e;
     --text-faint: #5b6470;
     --accent: #6ee7b7;
     --link: #79c0ff;
     --p0: #f87171;
     --p1: #fb923c;
     --p2: #fbbf24;
     --merged: #6ee7b7;
     --open: #60a5fa;
     --closed: #a78bfa;
   }
   @media (prefers-color-scheme: light) {
     :root {
       --bg: #f6f8fa; --bg-elev: #ffffff; --bg-elev-2: #f0f3f6;
       --border: #d0d7de; --border-strong: #afb8c1;
       --text: #1f2328; --text-dim: #59636e; --text-faint: #818b96;
       --accent: #1a7f37; --link: #0969da;
       --p0: #cf222e; --p1: #bc4c00; --p2: #9a6700;
       --merged: #1a7f37; --open: #0969da; --closed: #8250df;
     }
   }
   * { box-sizing: border-box; }
   html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', system-ui, sans-serif; font-size: 14px; line-height: 1.55; }
   main { max-width: 960px; margin: 0 auto; padding: 32px 28px 64px; }
   header { padding-bottom: 20px; border-bottom: 1px solid var(--border); margin-bottom: 28px; }
   header h1 { font-size: 22px; font-weight: 600; margin: 0 0 8px; letter-spacing: -0.01em; }
   header .meta { color: var(--text-dim); font-size: 13px; }
   h2 { font-size: 16px; font-weight: 600; margin: 32px 0 12px; letter-spacing: -0.005em; }
   h3 { font-size: 13px; font-weight: 600; margin: 20px 0 8px; color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.08em; }
   p, ul, ol { margin: 0 0 12px; }
   ul, ol { padding-left: 22px; }
   li { margin: 4px 0; }
   a { color: var(--link); text-decoration: none; }
   a:hover { text-decoration: underline; }
   code { font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 12.5px; background: var(--bg-elev-2); border: 1px solid var(--border); border-radius: 4px; padding: 1px 5px; }
   section { background: var(--bg-elev); border: 1px solid var(--border); border-radius: 10px; padding: 18px 20px; margin: 0 0 20px; }
   section > h2:first-child { margin-top: 0; }
   table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 0 0 12px; }
   th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); }
   th { color: var(--text-dim); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; background: var(--bg-elev-2); }
   tbody tr:nth-child(even) { background: var(--bg-elev-2); }
   tbody tr:hover { background: var(--border); }
   td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
   .badge { display: inline-block; font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: 999px; line-height: 1.5; vertical-align: 1px; }
   .badge.p0 { background: color-mix(in srgb, var(--p0) 18%, transparent); color: var(--p0); border: 1px solid color-mix(in srgb, var(--p0) 40%, transparent); }
   .badge.p1 { background: color-mix(in srgb, var(--p1) 18%, transparent); color: var(--p1); border: 1px solid color-mix(in srgb, var(--p1) 40%, transparent); }
   .badge.p2 { background: color-mix(in srgb, var(--p2) 22%, transparent); color: var(--p2); border: 1px solid color-mix(in srgb, var(--p2) 40%, transparent); }
   .badge.merged { background: color-mix(in srgb, var(--merged) 18%, transparent); color: var(--merged); border: 1px solid color-mix(in srgb, var(--merged) 40%, transparent); }
   .badge.open { background: color-mix(in srgb, var(--open) 18%, transparent); color: var(--open); border: 1px solid color-mix(in srgb, var(--open) 40%, transparent); }
   .badge.closed { background: color-mix(in srgb, var(--closed) 18%, transparent); color: var(--closed); border: 1px solid color-mix(in srgb, var(--closed) 40%, transparent); }
   .badge.pr { background: var(--bg-elev-2); color: var(--text-dim); border: 1px solid var(--border-strong); margin-right: 4px; }
   a.issue, a.pr-link { font-variant-numeric: tabular-nums; }
   a.issue .hash, a.pr-link .hash { color: var(--text-faint); margin-right: 1px; }
   img { max-width: 100%; height: auto; border: 1px solid var(--border); border-radius: 6px; }
   hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
   @media print {
     :root { color-scheme: light; --bg: #fff; --bg-elev: #fff; --bg-elev-2: #f6f8fa; --border: #d0d7de; --text: #1f2328; --text-dim: #59636e; --link: #0969da; }
     body { background: #fff; }
     main { max-width: none; padding: 0; }
     section { break-inside: avoid; box-shadow: none; }
     a { text-decoration: underline; color: inherit; }
   }
   ```

   Future report-writing commands inherit this same idempotent-write contract — if a third report writer is added (e.g., a release-cut report), it runs the same `[ ! -f .shipyard/styles.css ]` check with this same template before its own `Write` call. The CSS template is intentionally inline in this command (the canonical source); other commands link here rather than re-stating it.

3. **Compute the target path.** Base name is `<YYYY-MM-DD>-shipyard-audit.html` using today's date in the local timezone. If that file already exists (rerun same day), suffix `-2`, `-3`, etc. until a free path is found — don't clobber. Suggested check:

   ```bash
   base="$(date +%Y-%m-%d)-shipyard-audit"
   path=".shipyard/audits/${base}.html"
   n=2
   while [ -e "$path" ]; do path=".shipyard/audits/${base}-${n}.html"; n=$((n+1)); done
   ```

4. **Write the report** using the `Write` tool. Mirror the same structure the chat summary emitted, plus a metadata header. Use the HTML skeleton below — populate the placeholders directly; the `Write` tool dumps the populated HTML to the target path in one call. Don't bother running the markup through any pre-processor; templated string substitution is sufficient. Recommended HTML shape:

   ```html
   <!doctype html>
   <html lang="en">
   <head>
     <meta charset="utf-8" />
     <meta name="viewport" content="width=device-width, initial-scale=1" />
     <title>Shipyard audit — <target> — <YYYY-MM-DD></title>
     <link rel="stylesheet" href="../styles.css" />
   </head>
   <body>
     <main>
       <header>
         <h1>Shipyard audit — <target></h1>
         <div class="meta">
           <strong>Target:</strong> <URL or owner/repo> ·
           <strong>Branch / SHA:</strong> <branch>@<short-sha> ·
           <strong>Audit type(s):</strong> <type list> ·
           <strong>Dispatched agents:</strong> <agent slugs> ·
           <strong>Total issues filed:</strong> <count>
         </div>
       </header>

       <section>
         <h2>Per-audit verdict</h2>
         <table>
           <thead><tr><th>Audit</th><th>Verdict</th><th class="num">Filed</th></tr></thead>
           <tbody>
             <tr><td><audit></td><td><one-line verdict></td><td class="num"><count></td></tr>
           </tbody>
         </table>
       </section>

       <section>
         <h2>Issues filed</h2>
         <h3><audit-name></h3>
         <ul>
           <li><a class="issue" href="<issue URL>"><span class="hash">#</span><n></a> — <title> — <span class="badge p1">P1</span></li>
         </ul>
       </section>

       <section>
         <h2>Highest-signal findings</h2>
         <ol>
           <li><cross-cutting item 1></li>
           <li><cross-cutting item 2></li>
         </ol>
       </section>

       <section>
         <h2>Surfaces NOT reviewed</h2>
         <ul>
           <li><surface or dimension not covered, with a one-line reason or follow-up suggestion></li>
         </ul>
       </section>

       <section>
         <h2>Process notes</h2>
         <ul>
           <li><agent failures, partial returns, skipped dispatches></li>
         </ul>
       </section>
     </main>
   </body>
   </html>
   ```

   Severity badges: pick the matching CSS class — `p0` / `p1` / `p2`. PR links use `<a class="pr-link" href="..."><span class="badge pr">PR</span><span class="hash">#</span>M</a>` so the small "PR" prefix visually distinguishes them from issue links. Same-day audit chains can sibling-link at `.shipyard/audits/<YYYY-MM-DD>-index.html` listing every audit's report file — optional, only emit when more than one audit ran for the same day.

   Omit sections that have no content (e.g. no skipped audits → drop "Surfaces NOT reviewed"). Don't pad — empty rows are noise. Escape any user-supplied content (issue titles, agent error messages) appropriately when interpolating into HTML (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;` inside attributes); raw markup from issue titles is the most likely escaping miss.

5. **Surface the path in chat** as the last line of your reply so the user sees where it landed:

   > Report saved: `.shipyard/audits/<filename>.html`

If the working directory isn't a git repo or `.shipyard/` can't be created (read-only filesystem, permissions), report the failure inline (`Report could not be saved: <reason>`) and continue — don't block the chat summary on it.
