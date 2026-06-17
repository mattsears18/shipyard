---
description: Action-taking sibling of /my-turn — surveys with the same ranking, then drives the #1 action in the user's real, logged-in Chrome. Invoking the command is standing authorization to perform any browser-completable action. Backend-agnostic: prefers the claude-in-chrome extension, falls back to chrome-devtools-mcp, then to read-only /my-turn.
argument-hint: [--repo owner/repo] [--setup] [--all] [--dry-run] [--record]
---

# /my-turn-and-do

The **action-taking sibling** of [`/shipyard:my-turn`](./my-turn.md). `/my-turn` is read-only — it surfaces the single next item blocked on the user and stops. `/my-turn-and-do` keeps going: it runs the same ranked survey, prints the #1 action, then **executes it in the user's real, logged-in Chrome**.

**Invoking this command is itself the authorization.** Running `/my-turn-and-do` grants standing consent, for the duration of that run, to perform **anything completable by manipulating the browser** — navigate, click, fill, type, submit, comment, close, merge — without stopping for a fresh in-chat "say 'close it' to proceed" confirmation per action. The user is watching their own logged-in browser; the act of invoking the command is the go-ahead. The command still **prints a plan** before it touches the browser (transparency is preserved — see [Plan step](#plan-step--print-before-touching-the-browser)), but it then proceeds through that plan and **does** the action, reporting what it did, rather than blocking on a per-action yes/no. ([#608](https://github.com/mattsears18/shipyard/issues/608).)

The survey and ranking are identical to `/my-turn` — this command reuses `/my-turn`'s ranking directly and does not re-derive it. The difference is the execution step: `/my-turn-and-do` drives the browser to the artifact, reads the context, and performs the action (or hands back for genuine judgment calls — see [Judgment-call tee-up](#judgment-call-tee-up-not-rubber-stamp)).

Pairs with [`/shipyard:my-turn`](./my-turn.md) (read-only survey) and [`/shipyard:do-work`](./do-work.md) (agent-driven code loop).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--setup** (optional): run the [preflight](#preflight--detect-gaps-and-guided-setup) checks and guided setup **only**, then stop — no survey, no browser action. Use it for first-run onboarding or to re-verify the setup after a Chrome / extension / machine change. (The inline preflight runs on every invocation regardless; `--setup` is the standalone "just configure me" mode.)
- **--dry-run** (optional): survey + plan only. Print the #1 action and the browser steps that would be taken, then stop — **no browser action, no mutations**. This is the "preview, do nothing" escape hatch — the way to see the intended action *without* the standing authorization taking effect.
- **--all** (optional): run the full ranked list through the execution loop, not just the top item. Each item's plan is printed, then executed under the same standing authorization as the top item (no per-item yes/no). Use sparingly — the command is designed for focused one-item execution, and running the whole list autonomously is a larger commitment.

> **`--yes` is gone (no-op if passed).** Under the standing-authorization model the invocation *is* the consent, so there's no routine soft-confirm left for `--yes` to skip. A stray `--yes` in `$ARGUMENTS` is accepted and ignored (it does not error) for backwards-compatibility, but it has no effect — the command already proceeds without per-action confirmation. To preview without acting, use `--dry-run`.
- **--record** (optional): record the browser action as a GIF for later review (extension backend only). Off by default — recording is token- and file-cost-heavy, so it's opt-in. See [Recording](#recording---record).

## Browser backend — selection and detection

This command is **backend-agnostic**. It does not assume any single browser-driving mechanism; it detects which is available and selects the best one at setup, before running the survey. Selection order:

1. **`claude-in-chrome` (the Claude Chrome extension)** — **preferred.** It runs *inside* the user's real Chrome, so it natively inherits every logged-in session (GitHub, Vercel, Firebase Console, App Store Connect, etc.) with no remote-debugging setup and no logged-out-isolated-instance hazard. Per-site access is gated by the extension's own permission grants. Richer toolset (`read_page`, `get_page_text`, `find`, `browser_batch`, `gif_creator`).
2. **`chrome-devtools-mcp` (with `--autoConnect`)** — **fallback.** A DevTools-protocol driver. Used only when the extension is absent. Carries the remote-debugging caveats described under [chrome-devtools-mcp fallback notes](#chrome-devtools-mcp-fallback-notes).
3. **Neither available** — fall through to read-only [`/my-turn`](./my-turn.md) output (see [Absence detection](#absence-detection)).

### Detection (at setup, before any survey work)

- **Extension present?** The `mcp__claude-in-chrome__*` tools are in the available tool set. Confirm a live browser connection with `mcp__claude-in-chrome__tabs_context_mcp` (also the canonical session-start call — it surfaces the user's current tabs, used for [tab reuse](#tab-reuse) below). If that returns a live context, select the **extension** backend.
- **Else chrome-devtools-mcp present?** The `mcp__chrome-devtools__*` tools are in the available tool set. Confirm reachability with `mcp__chrome-devtools__list_pages`. If it returns pages (not a connection error), select the **chrome-devtools-mcp** backend.
- **Else** → neither is reachable; [Absence detection](#absence-detection) applies.

### Backend tool mapping

The execution playbooks below are written **backend-neutral** in terms of these abstract actions. Map each to the selected backend's tools:

| Abstract action | claude-in-chrome (preferred) | chrome-devtools-mcp (fallback) |
|---|---|---|
| See current tabs | `tabs_context_mcp` | `list_pages` |
| Open / reuse tab | `tabs_create_mcp` / reuse from context | `new_page` / `select_page` |
| Navigate | `navigate` | `navigate_page` |
| **Read page (default perception)** | `read_page` / `get_page_text` | `take_snapshot` |
| Find an element | `find` | `take_snapshot` (locate via uid) |
| Click | `computer` (click) | `click` |
| Fill a field / form | `form_input` | `fill` / `fill_form` |
| Screenshot (only when visual state matters) | `computer` (screenshot) | `take_screenshot` |
| Batch deterministic steps | `browser_batch` | sequential calls (no batch) |
| Record action | `gif_creator` | — (not supported; `--record` is a no-op) |

### Absence detection

If **neither** backend is reachable, the command:

1. Prints a clear prereq-failure message naming the specific gap:
   ```
   No browser backend reachable — execution step will be skipped.

   Preferred: the Claude Chrome extension (claude-in-chrome).
     Install/enable it and grant this site access, then re-run.
   Fallback: chrome-devtools-mcp with --autoConnect.
     Configure the MCP server, enable remote debugging at
     chrome://inspect/#remote-debugging, and restart Claude Code.

   Falling back to read-only /my-turn output:
   ```
2. Falls through to `/my-turn` read-only output so the user still gets the survey result.
3. Does **not** silently act in a logged-out isolated Chrome and does **not** guess at an alternative driving mechanism.

If a backend is *selected* but its connection later errors mid-run, treat it as a prereq failure for the remainder of the run and hand back (see [Error handling](#error-handling)).

## Preflight — detect gaps and guided setup

Before the survey (and before any browser action), `/my-turn-and-do` runs a **preflight** that verifies every prerequisite and, on any gap, **alerts the user and walks them through the fix interactively** rather than failing opaquely. Preflight is **silent on success** — when everything is already configured it prints a single one-line [summary](#preflight-summary) and proceeds with zero friction.

With **`--setup`**, preflight runs **standalone**: it performs the checks and guided fixes, prints the summary, then **stops** — no survey, no browser action.

### Self-heal loop (applied to each failing check)

For each prerequisite that fails, the command:

1. **Alerts** — names the specific gap in plain language.
2. **Instructs** — prints the exact steps to fix it (commands to run, UI toggles to flip).
3. **Waits** — asks via `AskUserQuestion` with options scaled to the gap, e.g. `["Done — re-check", "Use fallback backend", "Skip to read-only"]`.
4. **Re-checks** — on "Done", re-runs that check's detection. On success, advances to the next check.
5. **Caps retries** — after **2** failed re-checks for the same gap, stop looping and either fall back (if a degraded path exists) or drop to read-only `/my-turn`.

Never spin silently, and never proceed past an unmet **hard blocker** (gh auth, or no backend at all).

### Checks (in order)

**1. GitHub CLI auth (hard blocker).** `gh auth status`. If unauthenticated: instruct `gh auth login`, then re-check. Without it the survey can't run — if unresolved after the retry cap, abort with the `gh auth login` directive (do NOT fall through to a browser action).

**2. Browser backend present.** Run [backend detection](#detection-at-setup-before-any-survey-work).
- **Extension detected** → proceed to check 3.
- **Only chrome-devtools-mcp detected** → note the preferred extension isn't present; offer `["Proceed on chrome-devtools fallback", "Walk me through installing the extension", "Skip to read-only"]`.
- **Neither detected** → guided install, recommending the extension first:
  - **Claude Chrome extension (preferred):** install / enable the extension, confirm the `mcp__claude-in-chrome__*` tools load; note that a Claude Code restart may be required for a newly-added MCP server. Re-check.
  - **chrome-devtools-mcp (fallback):** configure the MCP server with `--autoConnect`, enable remote debugging at `chrome://inspect/#remote-debugging`, restart Claude Code (see [chrome-devtools-mcp fallback notes](#chrome-devtools-mcp-fallback-notes)). Re-check.
  - If the user skips both → read-only `/my-turn`.

**3. Backend connectivity.** Confirm the selected backend actually responds:
- Extension: `tabs_context_mcp` returns a live context. If it errors → guide (open Chrome, confirm the extension is connected / enabled), re-check. If it returns `No MCP tab groups found` or an empty context, the MCP tab group is absent — that's **not** a connectivity failure; recreate it with `tabs_context_mcp({createIfEmpty:true})` and proceed. (A closed/stale tab group later surfaces mid-run as a misleading `Permission denied by user` — see [Error handling](#error-handling) for the recover-then-retry recovery.)
- chrome-devtools-mcp: `list_pages` responds (not a connection error) and is not a logged-out isolated instance (see [Error handling](#error-handling)). If it errors → guide the `--autoConnect` / remote-debugging fix, re-check.

**4. Site permissions (extension only; non-blocking).** The extension gates access **per site**. Front-load the grants for the domains this command will touch — `github.com` always, plus any third-party console the survey is likely to route to (Vercel, Firebase, App Store Connect, etc., per the [deep-link table](#third-party-console-deep-links)). Because only the user can grant access in the extension UI, the walkthrough explains the model and asks `["github.com granted", "I'll grant on first navigation", "Skip"]`. This is **non-blocking** — a missing grant just surfaces a one-time prompt on first navigation; front-loading avoids a stall mid-action. (Not applicable to the chrome-devtools-mcp backend, which uses the real profile's existing sessions directly.)

**5. Chrome recency (soft advisory).** The extension needs a current Chrome; the chrome-devtools-mcp fallback historically required Chrome 144+. Print a one-line advisory only if a problem is suspected; never block on it.

### Preflight summary

After the checks pass (or the user opts into a degraded path), print a one-line summary, then continue — or, under `--setup`, stop:

```
Preflight: ✓ gh auth (mattsears18) · ✓ backend: claude-in-chrome · ✓ github.com permitted
```

If a degraded path was chosen, the summary reflects it (e.g. `⚠ backend: chrome-devtools-mcp (fallback)` or `→ read-only: no backend reachable`).

## Setup

### 1. Resolve repo

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
```

### 2. Run preflight

Run the [preflight](#preflight--detect-gaps-and-guided-setup) checks and guided setup. This confirms gh auth (check 1), selects and connects the browser backend (checks 2–3), and front-loads site permissions (check 4), self-healing any gap interactively.

**If `--setup` was passed, stop here** after printing the preflight summary — do NOT survey or act.

Otherwise continue once preflight clears (or has settled on a degraded path: a fallback backend, or read-only when no backend is reachable).

### 3. Resolve the authenticated user

```bash
gh api user --jq .login   # → $ME  (auth already confirmed by preflight check 1)
```

The browser backend was already selected and connected during preflight; if it settled on read-only (no backend reachable), run the survey as read-only `/my-turn` output and do NOT attempt to execute the action.

## Survey + ranking

Run the **identical survey passes and ranking** as [`/shipyard:my-turn`](./my-turn.md): passes A–D (open PRs, open issues, unanswered review comments, recent failed CI), the P0/P1/P2 tiers, the leverage-score-then-age within-tier sort, the dedup step, and the release-please discretionary de-prioritization. This command does not change the ranking; it adds an execution phase after it.

In the interest of focus, the default behavior is **single-item mode** (equivalent to `/my-turn`'s default — the top-ranked item only). With `--all`, run through the full ranked list.

## Plan step — print before touching the browser

After ranking, before any browser action, print the plan for the top item. The plan has three parts:

1. **The action.** Same format as `/my-turn`'s `→ Next:` directive — imperative verb, artifact ref, URL.
2. **The browser steps.** A numbered list of the concrete browser actions that will be taken: which URL to navigate to, what to read or click, what to fill in, what to submit. This is not prose description — it is the exact sequence (in backend-neutral terms).
3. **The action classification.** One line classifying the planned action as one of:
   - `Read-only (navigation + reading)` — pure navigation/reading; executed directly.
   - `Mutation — will execute: <what will be mutated>` — a browser-completable mutation (click, fill, submit, comment, close, merge). Executed directly under the standing authorization the invocation granted; the plan line announces it, then the command does it. No per-action yes/no.
   - `Judgment call — will tee up, then hand back` — the action is too context-dependent for the command to *decide* on the user's behalf (e.g., "review PR #42 and approve/request-changes"); the browser is driven to the artifact and the context surfaced, but the final decision stays with the user. This is the one class the standing authorization does NOT cover — see [Judgment-call tee-up](#judgment-call-tee-up-not-rubber-stamp). It's distinct from a *mutation*: a mutation is a mechanical action the ranking already determined ("close superseded duplicate PR #1994"); a judgment call needs a human's evaluation, not just their go-ahead.

The plan also prints which backend was selected (e.g., `Backend: claude-in-chrome`) so the user knows whether they're acting in their real logged-in profile.

The plan is **always printed** — it is the transparency record of what the command is about to do, and it is not optional even though the command no longer blocks on a per-action confirmation. If `--dry-run` is set, stop here: print the plan and exit, do not touch the browser. Otherwise, proceed through the plan and execute it.

## Execution step

### Tab reuse

Before navigating, consult the tab context fetched during [detection](#detection-at-setup-before-any-survey-work) (`tabs_context_mcp` / `list_pages`). If a tab is already open on the target artifact (the exact PR/issue/console URL, or the same origin + path), **reuse it** rather than opening a new tab. Only open a new tab when no relevant tab exists. This avoids cluttering the user's real browser with duplicate tabs.

### Perception — read the page, don't reflexively screenshot

The default way to confirm a page loaded and to extract context is to **read the page** (`read_page` / `get_page_text` on the extension; `take_snapshot` on chrome-devtools-mcp) — structured text is cheaper, more reliable, and more token-efficient than a screenshot. Take a **screenshot only when visual state genuinely matters**: confirming the browser is the real logged-in profile, or when an action depends on layout/rendering that text can't convey.

### Efficiency — batch deterministic sequences

On the extension backend, bundle deterministic multi-step sequences (navigate → wait → read → act) into a single `browser_batch` call to cut round-trips. On the fallback backend, run the steps sequentially. Because there is no per-action confirmation gate to break the sequence (see below), a navigate → read → mutate run can batch end-to-end on the extension backend.

### Execution under standing authorization (non-dry-run, non-judgment)

For any planned action classified as a **mutation** (`Mutation — will execute: …` in the plan), **just do it** — the invocation already granted standing authorization for browser-completable actions. Announce the action on a single line, then perform it, then report the result. Do NOT stop and wait for an in-chat "y/n" / "close it" / "merge it":

```
Executing: <one-line description of the mutation>
  URL: <target URL>
[performs the browser action]
Done: <one-line description of what happened — e.g. "Closed PR #1994.">
```

This covers the full set of browser-completable mutations — clicking a button, filling and submitting a form, posting a comment, closing or merging a PR — when they are the **mechanical action the ranking already surfaced**. The standing authorization is the user's pre-given consent for exactly these. Two boundaries still apply:

- **Judgment calls are not mutations.** An action that needs the user's *evaluation* (not just their go-ahead) — a PR review where a reasonable maintainer might approve or request changes, a nuanced question that needs a drafted-then-human-vetted reply — is teed up and handed back, never decided autonomously. See [Judgment-call tee-up](#judgment-call-tee-up-not-rubber-stamp). The dividing line is *decision*, not *reversibility*: closing a clearly-superseded duplicate PR is mechanical (execute it); deciding *whether* to approve a substantive PR is a judgment call (tee it up).
- **`--dry-run` is the no-op preview.** When the user wants to see the plan *without* the standing authorization taking effect, that's exactly what `--dry-run` is for — it stops at the plan and touches nothing.

The rationale for collapsing the old per-action prompt: the user is physically watching their own logged-in browser, and they invoked a command whose entire stated purpose is "do the thing in my browser." Re-asking "are you sure?" for each mechanical action the ranking already chose is the friction [#608](https://github.com/mattsears18/shipyard/issues/608) removes — it read as the agent refusing to act.

### Navigation and execution playbooks

Drive Chrome via the selected backend (mapped through the [tool table](#backend-tool-mapping)). Standard sequence per action type — all perception steps default to **reading the page**, not screenshotting:

**Review a PR:**
1. Navigate to the PR URL (reuse an open tab if present).
2. Read the page to confirm it loaded.
3. Read the PR description, diff summary, and any failing check names.
4. Summarize: PR title, files changed count, failing checks (if any), any review comments awaiting response.
5. Hand back — do NOT submit a review, approve, or request changes autonomously. Judgment call: the user reads the summary and decides. Print: "Teed up PR #<N> — review the summary above and act from the browser or GitHub UI."

**Investigate a failing CI run (blocked:ci):**
1. Navigate to the PR's checks page (reuse an open tab if present).
2. Read the page to confirm it loaded.
3. Read the failing check names and, if accessible, the first error lines from the check log output.
4. Summarize the failure.
5. Hand back — do NOT push a fix. Print: "Teed up the failing check details above — fix via `/do-work` or investigate manually."

**Navigate to a third-party console action (paste a secret, enable a provider, create a test user, etc.):**
1. Navigate to the provider deep link (derived the same way as `/my-turn`'s [third-party console deep-link](#third-party-console-deep-links) derivation).
2. Confirm the page loaded and the user is logged in — here a **screenshot is warranted** (logged-in state is visual and the deep link targets a real account).
3. If NOT logged in: print "Navigated to <URL> but the page appears logged out — action requires manual login." Hand back.
4. If logged in: if the action is mechanical (toggle a switch, fill a form with known values), execute it directly under the standing authorization (announce it, do it, report). If the action needs a value only the user holds (paste a real secret from their password manager), tee up the page and hand back — that's not browser-completable from the command's side.

**Reply to a question or @mention on an issue/PR:**
1. Navigate to the issue or PR (reuse an open tab if present).
2. Read the page to confirm it loaded.
3. Read the question or mention in context.
4. Summarize the question and provide a draft response.
5. **Do NOT post the comment autonomously.** This is always a judgment call — the user reads the draft and posts it (or edits it) from the browser or the GitHub UI. Print: "Draft reply above — post it from the browser when ready."

**Epic awaiting decomposition:**
1. Navigate to the issue (reuse an open tab if present).
2. Read the body to surface the scope and the `<!-- do-work-needs-decomposition -->` / `<!-- do-work-decompose-agent -->` markers.
3. Summarize the decomposition state (not yet attempted → suggest running `/shipyard:decompose-epic`; `couldn't auto-decompose` → hand-decomposition required).
4. Hand back.

### Recording (--record)

When `--record` is passed **and the extension backend is selected**, wrap the browser action in `gif_creator`: capture a few frames before and after each action for smooth playback, and write the GIF to a meaningfully-named file (e.g., `my-turn-and-do-pr-585-checks.gif`) so the user can identify and review it afterward. Surface the file path on completion.

If `--record` is passed but the selected backend is **chrome-devtools-mcp** (no GIF support), print a one-line note that recording is unavailable on the fallback backend and proceed without recording. `--record` is never a hard failure.

### Error handling

If a browser navigation fails (page not found, MCP tool call errors), print the error and hand back to the user with the plan still intact. Do not retry automatically — a failed navigation is a signal that the URL or the browser session state needs inspection. **Exception: a `Permission denied by user` (or any "lacks permission") error on the extension backend gets the stale-tab recovery below before it's treated as a genuine denial — see the next paragraph.**

**Extension backend — `Permission denied by user` is ambiguous: recover the tab group first, then retry once, before concluding the user denied access ([#607](https://github.com/mattsears18/shipyard/issues/607)).** On the extension backend, a **stale or closed MCP tab group** makes `navigate` (and any other browser action that targets a held tab) fail with the *exact same* `Permission denied by user` string a genuine site-grant decline produces. The error is indistinguishable on its face — and the execution step holds a `tabId` across turns, so a tab/group the user closed (or that aged out) is a common, silently-recoverable condition, **not** a permission denial. Do NOT read `Permission denied by user` as authoritative and bail to read-only / `gh`. Run this ordered recovery instead:

1. **Recover the tab group.** Call `tabs_context_mcp`. If it returns a live context with an MCP tab group, the held `tabId` may simply be stale — drop it and reuse a tab from the returned context (per [tab reuse](#tab-reuse)). If it returns `No MCP tab groups found` or an empty context, the group was closed — recreate it with `tabs_context_mcp({createIfEmpty:true})` (equivalently `tabs_create_mcp`), which yields a fresh group/tab.
2. **Retry the navigation once** against the recovered/recreated tab.
3. **Branch on the retry outcome:**
   - **Retry succeeds** (the common case — the original failure was the dead tab) → continue the playbook transparently. This was never a permission problem; do not surface it to the user as one and do not fall back.
   - **Retry still fails with `Permission denied by user`** → *now* it's a genuine site-grant decline. Print: "The Claude Chrome extension doesn't yet have access to <site> — grant it in the extension's site permissions and re-run." This is a one-time setup grant, not a failure of the command.

The single retry cap is deliberate: one tab-group recovery + one navigate covers the stale-tab case without masking a real denial behind an unbounded retry loop. Reserve the read-only / `gh` fallback for genuinely unreachable backends ([Absence detection](#absence-detection)), never for a closed tab — bailing to `gh` on a recoverable browser error defeats the command's core value proposition (driving the real browser) and erodes trust in the browser-driving premise.

If the **chrome-devtools-mcp** fallback backend appears to be a logged-out isolated instance (the GitHub login page appears when navigating to a GitHub URL), print: "Chrome appears to be logged out — remote debugging may be pointing at an isolated instance rather than your real profile. Verify `--autoConnect` is configured (not `--remote-debugging-port`) and Chrome is open with remote debugging enabled." Hand back. (This hazard does not apply to the extension backend, which always runs in the real profile.)

## Guardrails

### Standing authorization satisfies the gate for browser-completable actions

This command used to **hard-confirm** every irreversible / outward-facing browser action (close, merge, comment, submit, delete) with a fresh in-chat prompt, even mid-run. That gate is now **satisfied by the command invocation itself** for anything completable by manipulating the browser ([#608](https://github.com/mattsears18/shipyard/issues/608)). Running `/my-turn-and-do` is the user's standing, up-front consent to perform the browser-completable action the ranking surfaced — closing a PR, merging a PR, posting a comment, submitting a form, deleting an artifact — without a per-action "are you sure?". The user is watching their own logged-in browser; the invocation is the go-ahead, and re-asking per action is the exact friction this command exists to remove.

What the standing authorization does **not** override:

- **Judgment calls.** Standing authorization is consent to *do the mechanical action the ranking chose*, not consent to *make a decision on the user's behalf*. PR reviews, nuanced question replies, and "should this even be done?" calls are still teed up and handed back (see [Judgment-call tee-up](#judgment-call-tee-up-not-rubber-stamp)). The dividing line is *decision*, not *reversibility*.
- **Things that aren't completable in the browser.** The authorization is scoped to browser actions. It is not consent to run arbitrary shell commands, push code, or act outside the browser the command is driving.
- **The plan step.** Transparency is preserved — the [plan](#plan-step--print-before-touching-the-browser) is always printed before the browser is touched, so the user sees what is about to happen. The command proceeds *through* the plan; it does not block *on* it.
- **`--dry-run`.** Always available as the "preview, do nothing" path for when the user wants the plan without the action.

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

## chrome-devtools-mcp fallback notes

These notes apply **only when the chrome-devtools-mcp fallback backend is selected** — the extension backend needs none of this.

### Why --autoConnect (not --remote-debugging-port)

The old `--remote-debugging-port=<port>` flag is **ignored on the default profile since Chrome 136** (Chrome's anti-cookie-theft policy). Passing it launches an isolated Chrome instance that is logged out of every service. `--autoConnect` is the modern path: it attaches to an **already-running Chrome** with remote debugging enabled, preserving the real user profile and all auth sessions.

### Enabling remote debugging in your running Chrome

Chrome's remote debugging is a per-session toggle — it is NOT on by default:

1. Open `chrome://inspect/#remote-debugging` in your running Chrome.
2. Enable **"Discover network targets"**. On macOS, you can also launch Chrome from the terminal with `--remote-debugging-port=9222`, but since Chrome 136 this only works for non-default profiles. The recommended path is the `chrome://inspect` toggle on your running browser.
3. Confirm your `chrome-devtools-mcp` MCP server is configured with `--autoConnect` in your Claude Code MCP settings.
4. **Restart Claude Code after adding or changing an MCP server** — newly-added MCP servers only load after a restart.

> **Recommendation:** Prefer the `claude-in-chrome` extension over this fallback. It avoids the remote-debugging toggle, the Chrome-136 default-profile hazard, and the logged-out-isolated-instance failure mode entirely.

## Third-party console deep-links

When navigating to a third-party provider console, derive the URL using the same template table as `/my-turn`'s [third-party console deep-links section](./my-turn.md#third-party-console-deep-links): substitute identifiers from the action's context (issue/PR body, comments, repo config). Fallback to the provider's top-level console when the specific page can't be fully constructed. Never fabricate an identifier to fill a template — a wrong deep link navigates to someone else's app.

## Output

### Single-item mode (default)

A mechanical mutation the ranking surfaced — closing a clearly-superseded duplicate PR. Under standing authorization the command announces it, then does it, then reports; no per-action yes/no:

```
→ Next: close superseded duplicate PR #1994 (replaced by #2001)
  https://github.com/owner/repo/pull/1994

Backend: claude-in-chrome

Plan:
  1. Navigate to https://github.com/owner/repo/pull/1994 (reuse open tab if present)
  2. Read the page to confirm it loaded and is still open
  3. Click "Close pull request"

Action: Mutation — will execute: close PR #1994

Executing: close PR #1994
  URL: https://github.com/owner/repo/pull/1994
[read page — PR #1994, open, logged in as mattsears18]
[click "Close pull request"]
Done: Closed PR #1994.
```

### Dry-run mode

Same survey + plan, but `--dry-run` stops before the browser is touched — the standing authorization does not take effect:

```
→ Next: close superseded duplicate PR #1994 (replaced by #2001)
  https://github.com/owner/repo/pull/1994

Backend: claude-in-chrome

Plan:
  1. Navigate to https://github.com/owner/repo/pull/1994 (reuse open tab if present)
  2. Read the page to confirm it loaded and is still open
  3. Click "Close pull request"

Action: Mutation — will execute: close PR #1994

[dry-run — no browser action taken]
```

### Setup mode (--setup)

```
Preflight:
  ✗ Browser backend — neither the Claude Chrome extension nor chrome-devtools-mcp is reachable.

  Recommended: the Claude Chrome extension (claude-in-chrome).
    1. Install / enable the Claude extension in Chrome.
    2. Grant it access to github.com in the extension's site permissions.
    3. Restart Claude Code so the newly-added MCP server loads.

  [AskUserQuestion] Backend setup → "Done — re-check" / "Use chrome-devtools-mcp instead" / "Skip to read-only"
  > Done — re-check
  ✓ Browser backend — claude-in-chrome detected and connected.

Preflight: ✓ gh auth (mattsears18) · ✓ backend: claude-in-chrome · ✓ github.com permitted

Setup complete — re-run /my-turn-and-do (without --setup) to survey and act.
```

## Don't

- **Don't skip preflight, and don't fail opaquely.** Always run the [preflight](#preflight--detect-gaps-and-guided-setup) first. On any gap, alert the user and walk them through the fix interactively (self-heal loop) before falling back — a missing prerequisite is a setup step to guide the user through, not a terse error to dump. Preflight stays silent when everything is already configured.
- **Don't assume a backend.** Always run [backend detection](#detection-at-setup-before-any-survey-work) first and act through whichever is live. A missing browser backend is a setup gap, not a reason to fail silently or guess at an alternative driving mechanism.
- **Don't loop forever on a gap.** The self-heal loop is retry-capped (2 re-checks per gap); after that, fall back to a degraded path or read-only rather than re-prompting indefinitely.
- **Don't act in a logged-out isolated Chrome.** This only arises on the chrome-devtools-mcp fallback (`--remote-debugging-port` launches a non-profile Chrome). If that backend appears logged out, detect it and print setup instructions rather than proceeding. The extension backend always runs in the real profile.
- **Don't treat `Permission denied by user` as authoritative on the extension backend without first recovering the tab group.** A stale or closed MCP tab group produces the *same* error string as a genuine site-grant decline ([#607](https://github.com/mattsears18/shipyard/issues/607)). On that error, call `tabs_context_mcp` (and `tabs_context_mcp({createIfEmpty:true})` if it reports `No MCP tab groups found` / an empty context) to recreate the group/tab, then retry the navigate once — per the recover-then-retry steps in [Error handling](#error-handling). Only if the *retry* still denies is it a real permission decline that warrants the grant-instructions branch. Never bail to read-only / `gh` on a closed tab — that fallback is reserved for a genuinely unreachable backend ([Absence detection](#absence-detection)).
- **Don't reflexively screenshot.** Read the page for perception; screenshot only when visual state genuinely matters (logged-in confirmation, layout-dependent actions).
- **Don't rubber-stamp judgment calls.** Standing authorization covers the *mechanical* browser action the ranking surfaced (e.g. close a clearly-superseded duplicate PR), NOT decisions that need the user's evaluation. PR reviews where a reasonable maintainer might approve or request changes, nuanced question responses, and "should this be done at all?" calls — tee them up in the browser and hand back. Do NOT submit a substantive review or post a drafted reply autonomously; the dividing line is *decision* (hand back), not *reversibility* (execute under standing authorization).
- **Don't re-ask for per-action confirmation.** Under the standing-authorization model ([#608](https://github.com/mattsears18/shipyard/issues/608)), invoking the command IS the consent for browser-completable actions — close, merge, comment, submit, delete. Do NOT stop mid-run and wait for an in-chat "say 'close it' to proceed" / "merge it" / "y/n"; that round-trip reads as the agent refusing to act. Announce the action in the plan, then do it, then report. The only "preview without acting" path is `--dry-run`.
- **Don't expand scope.** If the #1 action leads to a discovery that suggests 5 follow-up actions, surface them as follow-up items (print the list) and hand back — don't chain into an autonomous multi-action loop. The command is one-item focused by design; expansion is always opt-in via `--all`. Standing authorization is consent to do the *surfaced* action, not license to invent and execute new ones.
- **Don't act outside the browser.** The standing authorization is scoped to browser-completable actions. It is not consent to run arbitrary shell commands, push code, or take actions outside the Chrome the command is driving.
- **Don't scan other repos.** Current repo only unless `--repo` overrides it. Cross-repo execution is out of scope.
- **Don't skip the plan step.** Always print the plan before touching the browser. The user must see what is about to happen before it happens — the plan is the transparency record and is not optional, even though the command proceeds through it without a per-action confirmation.
- **Don't post progress comments or mutation-summaries to public GitHub artifacts** (issue or PR comments) as the result of the command's browser actions without the user's explicit direction. The command drives the browser on the user's behalf; it does not self-narrate its own actions into the public comment thread.
