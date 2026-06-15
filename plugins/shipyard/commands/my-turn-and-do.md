---
description: Action-taking sibling of /my-turn — surveys with the same ranking, then drives the #1 action in the user's real, logged-in Chrome via chrome-devtools-mcp. Requires Chrome 144+ with --autoConnect enabled.
argument-hint: [--repo owner/repo] [--all] [--dry-run] [--yes]
---

# /my-turn-and-do

The **action-taking sibling** of [`/shipyard:my-turn`](./my-turn.md). `/my-turn` is read-only — it surfaces the single next item blocked on the user and stops. `/my-turn-and-do` keeps going: it runs the same ranked survey, prints the #1 action, then **executes it in the user's real, logged-in Chrome** via `chrome-devtools-mcp` (Chrome 144+ with `--autoConnect`).

The survey and ranking are identical to `/my-turn` — this command reuses `/my-turn`'s ranking directly and does not re-derive it. The difference is the execution step: `/my-turn-and-do` drives the browser to the artifact, reads the context, and performs the action (or hands back for judgment calls).

Pairs with [`/shipyard:my-turn`](./my-turn.md) (read-only survey) and [`/shipyard:do-work`](./do-work.md) (agent-driven code loop).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--dry-run** (optional): survey + plan only. Print the #1 action and the browser steps that would be taken, then stop — **no browser action, no mutations**. Useful to confirm the intended action before executing.
- **--yes** (optional): pre-approve *this run's* planned mutations. Skips the "about to do X — confirm?" prompt for the planned action. Does NOT blanket-approve all future runs, and does NOT bypass the hard confirmation gate for destructive or outward-facing actions (see [Guardrails](#guardrails)).
- **--all** (optional): run the full ranked list through the execution loop, not just the top item. Each item is individually confirmed (or pre-approved via `--yes`) before the browser is driven. Use sparingly — the command is designed for focused one-item execution.

## Prerequisites — chrome-devtools-mcp with --autoConnect

This command requires a `chrome-devtools-mcp` server configured with `--autoConnect`. Without it, the command detects the absence and prints clear setup instructions rather than failing opaquely.

### Why --autoConnect (not --remote-debugging-port)

The old `--remote-debugging-port=<port>` flag is **ignored on the default profile since Chrome 136** (Chrome's anti-cookie-theft policy). Passing it launches an isolated Chrome instance that is logged out of every service. `--autoConnect` is the modern path: it attaches to an **already-running Chrome** with remote debugging enabled, preserving the real user profile and all auth sessions. Auth-gated pages (GitHub, Vercel, Firebase Console, App Store Connect, etc.) work because the browser is your real profile.

### Enabling remote debugging in your running Chrome

Chrome's remote debugging is a per-session toggle — it is NOT on by default:

1. Open `chrome://inspect/#remote-debugging` in your running Chrome.
2. Enable **"Discover network targets"** or use the **"Open dedicated DevTools for Node"** toggle. On macOS, you can also launch Chrome from the terminal with `--remote-debugging-port=9222`, but since Chrome 136 this only works for non-default profiles. The recommended path is the `chrome://inspect` toggle on your running browser.
3. Confirm your `chrome-devtools-mcp` MCP server is configured with `--autoConnect` in your Claude Code MCP settings (`.claude/settings.json` or `~/.claude/settings.json`).
4. **Restart Claude Code after adding or changing an MCP server** — newly-added user-scope MCP servers only load after a restart. If the browser tools are missing after configuring, restart Claude Code first.

### Absence detection

At setup, before doing any survey work, the command checks:

```bash
# Can we see chrome-devtools-mcp tools? (The MCP server exposes tools like
# mcp__chrome-devtools__navigate_page, mcp__chrome-devtools__take_screenshot, etc.)
```

If the chrome-devtools-mcp tools are absent from the available tool set, the command:

1. Prints a clear prereq-failure message naming the specific gap (server not configured vs. server configured but Chrome remote debugging not enabled vs. Claude Code needs restart).
2. Falls through to `/my-turn` read-only output so the user gets the survey result even if execution can't proceed.
3. Does **not** silently act in a logged-out isolated Chrome.

If the server is present but Chrome itself isn't reachable (the MCP server is configured but returns a connection error), the command treats it as a prereq failure and falls through to read-only output.

## Setup

### 1. Resolve repo

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
```

### 2. Resolve the authenticated user

```bash
gh api user --jq .login   # → $ME
```

If `gh` is not authenticated, abort with a clear error directing the user to `gh auth login`.

### 3. Prereq check — chrome-devtools-mcp availability

Before running the survey, confirm the `chrome-devtools-mcp` toolset is available. The canonical check is to attempt a `mcp__chrome-devtools__list_pages` call (or equivalent tool listing). If the tools are absent:

```
chrome-devtools-mcp not reachable — execution step will be skipped.

Setup:
1. Configure chrome-devtools-mcp with --autoConnect in your MCP settings.
2. Enable remote debugging in your running Chrome at chrome://inspect/#remote-debugging.
3. Restart Claude Code (MCP servers load at startup).

Falling back to read-only /my-turn output:
```

Then run the survey and print the `/my-turn`-style output as a fallback. Do NOT attempt to execute the action.

## Survey + ranking

Run the **identical survey passes and ranking** as [`/shipyard:my-turn`](./my-turn.md): passes A–D (open PRs, open issues, unanswered review comments, recent failed CI), the P0/P1/P2 tiers, the leverage-score-then-age within-tier sort, the dedup step, and the release-please discretionary de-prioritization. This command does not change the ranking; it adds an execution phase after it.

In the interest of focus, the default behavior is **single-item mode** (equivalent to `/my-turn`'s default — the top-ranked item only). With `--all`, run through the full ranked list.

## Plan step — print before touching the browser

After ranking, before any browser action, print the plan for the top item. The plan has three parts:

1. **The action.** Same format as `/my-turn`'s `→ Next:` directive — imperative verb, artifact ref, URL.
2. **The browser steps.** A numbered list of the concrete browser actions that will be taken: which URL to navigate to, what to read or click, what to fill in, what to submit. This is not prose description — it is the exact sequence.
3. **The gate classification.** One line classifying the planned action as either:
   - `Read-only (navigation + reading)` — free to execute without confirmation.
   - `Mutation — confirm before executing: <what will be mutated>` — requires explicit confirmation (or `--yes`).
   - `Judgment call — will tee up, then hand back` — the action is too context-dependent to auto-execute (e.g., "review PR #42"); the browser will be driven to the artifact and the context surfaced, but the final decision stays with the user.

If `--dry-run` is set, stop here. Print the plan and exit. Do not touch the browser.

## Execution step

### Confirmation gate (non-dry-run, non-judgment)

For any planned action classified as a **mutation**, confirm before executing — unless `--yes` was passed for this run:

```
About to: <one-line description of the mutation>
  URL: <target URL>

Proceed? (y/n)
```

Wait for the user's response. A `y` / `yes` / `Y` response proceeds. Anything else aborts the execution step and prints the plan summary with a "Skipped — run with --yes to pre-approve" note.

**Destructive and outward-facing actions always prompt, regardless of `--yes`.** `--yes` pre-approves the *planned* mutation for *this run*; it never silently bypasses:

- Closing or merging a PR.
- Deleting a branch, comment, or artifact.
- Posting a public comment or review.
- Submitting a form that sends a message, triggers a build, or processes a payment.
- Approving a review (as distinct from submitting a review that requests changes).

For these, even `--yes` produces a final "you're about to close/merge/post/submit — confirm?" prompt. The rationale: these are outward-facing or irreversible; the user's intent from a previous command invocation should not carry over to a new context where the target might have changed.

### Navigation and execution

Drive Chrome via `chrome-devtools-mcp` using `--autoConnect` (the MCP tools available to this session). Standard sequence per action type:

**Review a PR:**
1. Navigate to the PR URL.
2. Take a screenshot or snapshot to confirm the page loaded.
3. Read the PR description, diff summary, and any failing check names via page inspection.
4. Summarize: PR title, files changed count, failing checks (if any), any review comments awaiting response.
5. Hand back — do NOT submit a review, approve, or request changes autonomously. Judgment call: the user reads the summary and decides. Print: "Teed up PR #<N> — review the summary above and act from the browser or GitHub UI."

**Investigate a failing CI run (blocked:ci):**
1. Navigate to the PR's checks page.
2. Screenshot to confirm loaded.
3. Read the failing check names and, if accessible, the first error lines from the check log output via page inspection.
4. Summarize the failure.
5. Hand back — do NOT push a fix. Print: "Teed up the failing check details above — fix via `/do-work` or investigate manually."

**Navigate to a third-party console action (paste a secret, enable a provider, create a test user, etc.):**
1. Navigate to the provider deep link (derived the same way as `/my-turn`'s [third-party console deep-link](#third-party-console-deep-links) derivation).
2. Screenshot to confirm the page loaded and the user is logged in.
3. If NOT logged in: print "Navigated to <URL> but the page appears logged out — action requires manual login." Hand back.
4. If logged in: if the action is mechanical and reversible (toggle a switch, fill a form with known values), execute it after the confirmation gate above.

**Reply to a question or @mention on an issue/PR:**
1. Navigate to the issue or PR.
2. Screenshot to confirm loaded.
3. Read the question or mention in context.
4. Summarize the question and provide a draft response.
5. **Do NOT post the comment autonomously.** This is always a judgment call — the user reads the draft and posts it (or edits it) from the browser or the GitHub UI. Print: "Draft reply above — post it from the browser when ready."

**Epic awaiting decomposition:**
1. Navigate to the issue.
2. Read the body to surface the scope and the `<!-- do-work-needs-decomposition -->` / `<!-- do-work-decompose-agent -->` markers.
3. Summarize the decomposition state (not yet attempted → suggest running `/shipyard:decompose-epic`; `couldn't auto-decompose` → hand-decomposition required).
4. Hand back.

### Error handling

If a browser navigation fails (page not found, MCP tool call errors), print the error and hand back to the user with the plan still intact. Do not retry automatically — a failed navigation is a signal that the URL or the browser session state needs inspection.

If the `--autoConnect` browser appears to be a logged-out isolated instance (the GitHub login page appears when navigating to a GitHub URL), print: "Chrome appears to be logged out — remote debugging may be pointing at an isolated instance rather than your real profile. Verify `--autoConnect` is configured (not `--remote-debugging-port`) and Chrome is open with remote debugging enabled." Hand back.

## Guardrails

### Hard confirmation for irreversible / outward-facing actions

Even with `--yes`, the following always prompt before execution:

- Closing or merging a PR (`gh pr merge`, clicking a Merge button).
- Posting a public comment, review, or form submission.
- Deleting any artifact (branch, comment, file).
- Any action that sends a message or triggers an external service.

The `--yes` flag is a "skip the routine soft-confirm"; it is NOT a "bypass all gates." The routine soft-confirm covers read-only navigation confirmation and mechanical-action confirms for reversible operations.

### Judgment-call tee-up, not rubber-stamp

Actions that require the user's judgment — PR review, deciding whether to close an issue, responding to a nuanced question — are **always** tee-up-and-hand-back. The command drives the browser to the artifact, reads context, and surfaces it as a summary; it does not make the judgment for the user and does not submit the decision autonomously.

The rule of thumb: if a reasonable maintainer might look at the same artifact and reach a different conclusion, it's a judgment call. Tee it up; hand back.

### --dry-run for previewing

`--dry-run` is the escape hatch for "what would you do?" — survey, rank, plan, stop. No browser opened, no mutations, no judgment calls teed up. Useful for validating the command's intended behavior before giving it browser access.

### shipyard label on any issues or PRs created

If the execution step creates a GitHub issue or PR (e.g., as a follow-up to a browser action), the creation call MUST include `--label shipyard` per the repo-wide session-stamp convention (CLAUDE.md "Session-stamp label" section). Ensure the label exists first:

```bash
gh label create shipyard --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
```

## Third-party console deep-links

When navigating to a third-party provider console, derive the URL using the same template table as `/my-turn`'s [third-party console deep-links section](./my-turn.md#third-party-console-deep-links): substitute identifiers from the action's context (issue/PR body, comments, repo config). Fallback to the provider's top-level console when the specific page can't be fully constructed. Never fabricate an identifier to fill a template — a wrong deep link navigates to someone else's app.

## Output

### Single-item mode (default)

```
→ Next: re-paste the empty EXPO_ASC_* + ANDROID_SERVICE_ACCOUNT_JSON CI secrets (#1382)
  https://github.com/owner/repo/issues/1382

Plan:
  1. Navigate to https://github.com/owner/repo/settings/secrets/actions
  2. Click "New repository secret"
  3. Hand back — post real secret values from your password manager

Gate: Mutation — confirm before executing: add repository secret(s)

Executing...
[screenshot taken — GitHub Actions Secrets page, logged in as mattsears18]
About to navigate to the repo secrets page. Proceed? (y/n) y
Navigated to https://github.com/owner/repo/settings/secrets/actions
Teed up — the secrets page is open. Add the values from your password manager.
```

### Dry-run mode

```
→ Next: re-paste the empty EXPO_ASC_* + ANDROID_SERVICE_ACCOUNT_JSON CI secrets (#1382)
  https://github.com/owner/repo/issues/1382

Plan:
  1. Navigate to https://github.com/owner/repo/settings/secrets/actions
  2. Click "New repository secret"
  3. Hand back — post real secret values from your password manager

Gate: Mutation — confirm before executing: add repository secret(s)

[dry-run — no browser action taken]
```

## Don't

- **Don't act in a logged-out isolated Chrome.** The `--remote-debugging-port` flag launches a non-profile Chrome; `--autoConnect` attaches to the real profile. If the browser appears logged out, detect it and print setup instructions rather than proceeding.
- **Don't rubber-stamp judgment calls.** PR review, nuanced question responses, issue closure decisions — tee them up in the browser and hand back. Do NOT submit a review, post a comment, or close an issue without the user's explicit confirmation.
- **Don't bypass the hard confirmation gate with --yes.** `--yes` skips the routine soft-confirm. Merges, comment posts, deletes, and form submissions with external effects always prompt once more.
- **Don't run without the prereq check.** Always verify `chrome-devtools-mcp` tools are available before attempting browser actions. A missing MCP server is a setup gap, not a reason to fail silently or guess at an alternative browser-driving mechanism.
- **Don't expand scope.** If the #1 action leads to a discovery that suggests 5 follow-up actions, surface them as follow-up items (print the list) and hand back — don't chain into an autonomous multi-action loop. The command is one-item focused by design; expansion is always opt-in via `--all`.
- **Don't scan other repos.** Current repo only unless `--repo` overrides it. Cross-repo execution is out of scope.
- **Don't skip the plan step.** Always print the plan before touching the browser. The user must see what is about to happen before it happens — the plan is not optional even with `--yes`.
- **Don't post progress comments or mutation-summaries to public GitHub artifacts** (issue or PR comments) as the result of the command's browser actions without the user's explicit direction. The command drives the browser on the user's behalf; it does not self-narrate its own actions into the public comment thread.
