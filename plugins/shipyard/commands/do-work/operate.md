# /shipyard:do-work — Operator phase (default-on)

The browser-operator layer of `/do-work`, loaded **by default on every run** since [#661](https://github.com/mattsears18/shipyard/issues/661) made autonomous, operator-inclusive operation the default. It is loaded for a plain `/do-work` run. It is **skipped only under the `--no-operate` / `--hands-off` opt-out** — the rare dispatch-only run.

This phase adds one capability to the autonomous loop: the orchestrator drains an [`operator_queue`](../do-work.md#orchestrator-state) of **browser-completable operator actions** by driving the user's real, logged-in Chrome — the work `/do-work` otherwise *defers* or *hands back*. It turns "I can't proceed, handing this back" moments into "I did it in the browser."

It owns the browser-driving machinery (backend selection, self-onboarding preflight, stale-tab recovery, standing authorization, read-page perception) **plus** the queue-drain loop and the proactive browser-completable sweep — see [On-demand bodies](#on-demand-bodies) below for where each of those now lives.

## How it fits the loop

- **Preflight runs once** at session start (right after [setup step 1.7](./setup/01-repo-recovery.md#17-resolve-trusted-author-allowlist), before the first dispatch) on every run except under `--no-operate` / `--hands-off`. It selects + connects a browser backend and front-loads site permissions. See [Preflight](#preflight--detect-gaps-and-guided-setup).
- **The code loop is unchanged.** Issue-workers still dispatch into worktrees and parallelize per `--concurrency`. The operator layer does not change how code work is dispatched, ranked, or reconciled.
- **Browser actions serialize on the main orchestrator thread.** The user's real Chrome is a singleton — only one driver at a time — so the orchestrator drains `operator_queue` items itself (never via a subagent), one at a time, in the **idle gaps**: while waiting for a code worker to return, and at each [step-D refresh tick](./steady-state.md#d-periodic-refresh). Code churns in parallel worktrees while the orchestrator operates the browser in between.
- **Termination includes the operator queue.** The loop does not end until the code backlog, the in-flight set, **and** `operator_queue` are all empty (plus the usual main-green drain). See [drain.md termination](./drain.md#termination-assertion).

### Degradation — no backend reachable

If the preflight finds **no browser backend reachable**, the operator layer degrades gracefully rather than aborting: the normal code loop runs to completion, and any `operator_queue` items are **surfaced as hand-backs** in the end-of-session summary (and left on their `needs-operator` label) instead of being driven. Print one warning at preflight time and proceed. the operator layer never kills or blocks the autonomous code loop.

## Browser backend — selection and detection

Backend-agnostic. The preflight detects and selects, in order:

1. **`claude-in-chrome` (the Claude Chrome extension)** — **preferred.** Runs *inside* the user's real Chrome, so it natively inherits every logged-in session (GitHub, Vercel, Firebase Console, App Store Connect, etc.) with no remote-debugging setup and no logged-out-isolated-instance hazard. Per-site access is gated by the extension's own permission grants. Richer toolset (`read_page`, `get_page_text`, `find`, `browser_batch`, `gif_creator`).
2. **`chrome-devtools-mcp` (with `--autoConnect`)** — **fallback.** A DevTools-protocol driver, used only when the extension is absent. Carries the remote-debugging caveats in [chrome-devtools-mcp fallback notes](./operate/03-error-handling-and-safety.md#chrome-devtools-mcp-fallback-notes).
3. **Neither available** — the operator layer [degrades](#degradation--no-backend-reachable) to code-loop-only with operator items surfaced as hand-backs.

### Detection

- **Extension present?** The `mcp__claude-in-chrome__*` tools are in the available tool set. Confirm a live connection with `mcp__claude-in-chrome__tabs_context_mcp` (the canonical session-start call — it also surfaces current tabs for [tab reuse](./operate/02-execution-and-playbooks.md#tab-reuse)). Live context → select the extension backend.
- **Else chrome-devtools-mcp present?** The `mcp__chrome-devtools__*` tools are present. Confirm with `mcp__chrome-devtools__list_pages` (returns pages, not a connection error) → select the chrome-devtools-mcp backend.
- **Else** → no backend; degrade.

### Backend tool mapping

The playbooks are written **backend-neutral** in terms of these abstract actions:

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

## Preflight — detect gaps and guided setup

Runs **once** at session start by default (unless `--no-operate`), before the first dispatch. It verifies every prerequisite and, on any gap, **alerts the user and walks them through the fix interactively** rather than failing opaquely. **Silent on success** — when everything is already configured it prints a single one-line [summary](#preflight-summary) and the loop proceeds with zero friction.

### Self-heal loop (applied to each failing check)

1. **Alerts** — names the specific gap in plain language.
2. **Instructs** — prints the exact steps to fix it (commands to run, UI toggles to flip).
3. **Waits** — asks via `AskUserQuestion`, options scaled to the gap, e.g. `["Done — re-check", "Use fallback backend", "Run code loop only (no browser)"]`.
4. **Re-checks** — on "Done", re-runs that check's detection; on success, advances.
5. **Caps retries** — after **2** failed re-checks for the same gap, stop looping and either fall back (a degraded backend) or [degrade to code-loop-only](#degradation--no-backend-reachable).

Never spin silently. The one **hard blocker** is gh auth (the whole loop needs it); a missing browser backend is *not* a hard blocker for the operator layer — it degrades to code-loop-only.

### Checks (in order)

**1. GitHub CLI auth (hard blocker).** `gh auth status`. If unauthenticated: instruct `gh auth login`, re-check; if unresolved after the cap, abort the whole `/do-work` run (the code loop needs `gh` too).

**2. Browser backend present.** Run [detection](#detection).
- **Extension detected** → check 3.
- **Only chrome-devtools-mcp detected** → note the preferred extension isn't present; offer `["Proceed on chrome-devtools fallback", "Walk me through installing the extension", "Run code loop only (no browser)"]`.
- **Neither detected** → guided install, recommending the extension first (install/enable it, confirm the `mcp__claude-in-chrome__*` tools load, note a Claude Code restart may be needed for a newly-added MCP server). If the user skips → degrade to code-loop-only.

**3. Backend connectivity.** Confirm the selected backend responds:
- Extension: `tabs_context_mcp` returns a live context. If it returns `No MCP tab groups found` / an empty context, the MCP tab group is absent — **not** a connectivity failure; recreate it with `tabs_context_mcp({createIfEmpty:true})` and proceed. (A closed/stale tab group later surfaces mid-run as a misleading `Permission denied by user` — see [Error handling](./operate/03-error-handling-and-safety.md#error-handling) for the recover-then-retry.)
- chrome-devtools-mcp: `list_pages` responds and is not a logged-out isolated instance (see [Error handling](./operate/03-error-handling-and-safety.md#error-handling)).

**4. Site permissions (extension only; non-blocking).** The extension gates access **per site**. Front-load grants for the domains the run will touch — `github.com` always, plus any third-party console the operator queue is likely to route to (Vercel, Firebase, App Store Connect, etc., per the [deep-link table](./operate/03-error-handling-and-safety.md#third-party-console-deep-links)). Only the user can grant in the extension UI; the walkthrough explains the model and asks `["github.com granted", "I'll grant on first navigation", "Skip"]`. Non-blocking — a missing grant just surfaces a one-time prompt on first navigation.

**5. Chrome recency (soft advisory).** The extension needs a current Chrome; the chrome-devtools-mcp fallback historically required Chrome 144+. One-line advisory only if a problem is suspected; never block.

### Preflight summary

```
Preflight (operator): ✓ gh auth (mattsears18) · ✓ backend: claude-in-chrome · ✓ github.com permitted
```

Degraded paths reflect in the summary (e.g. `⚠ backend: chrome-devtools-mcp (fallback)` or `→ no browser backend — operator items will be handed back`).

## On-demand bodies

This file is a **thin router**: the browser-backend selection and self-onboarding preflight above genuinely run every session, so they stay eager. Everything else — the `operator_queue` mechanics, standing authorization, per-kind playbooks, error handling / safety, and the steady-state hooks — is only exercised when `operator_queue` is actually non-empty, so it moved on-demand into [`operate/`](./operate/), mirroring the [thin-router + on-demand-sub-file pattern](../do-work.md#phase-routing) `do-work.md` and `setup.md` already use.

| Operator sub-phase | Owns | When to load |
|---|---|---|
| [`operate/01-queue-and-authorization.md`](./operate/01-queue-and-authorization.md) | The `operator_queue`'s two feeders (reactive step-A.1, proactive step-D), the security/access-control-heavy-queue expectation note, standing authorization (+ the session-owned-vs-inherited-PR scope correction), and the harness-classifier-denial branch for operator actions | Once the queue holds (or is about to hold) an item, or when a worker/scope-agent return needs classifying as browser-completable |
| [`operate/02-execution-and-playbooks.md`](./operate/02-execution-and-playbooks.md) | Draining-an-item mechanics (plan-then-act, tab reuse, perception, batching, recording) and the per-kind playbooks (`close-pr` / `merge-pr` / `toggle-setting` / `console-action` / `paste-secret` / `reply-comment` / `verify`) + judgment-calls-are-never-enqueued | When actually executing (draining) a popped `operator_queue` item |
| [`operate/03-error-handling-and-safety.md`](./operate/03-error-handling-and-safety.md) | Browser-navigation error handling (incl. the extension's stale-tab-group recovery), the trust/safety boundary for browser actions, chrome-devtools-mcp fallback notes, and the third-party console deep-link table | When a navigation/action errors, or when classifying an action against the trust boundary, or deriving a provider deep link |
| [`operate/04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md) | The two hooks [`steady-state.md`](./steady-state.md) calls into (step-A.1 reactive enqueue, step-D proactive sweep + drain) | Consulted from `steady-state.md`'s own A.1 / D steps, on every run except `--no-operate` / `--hands-off` |
| [`operate/05-dont.md`](./operate/05-dont.md) | The operator-phase-specific prohibition list | Sidebar reference alongside whichever operator sub-phase above is active |

### How to load on demand

Read only the sub-phase relevant to what's currently happening. The eager preflight above never needs any of these five. Once the operator layer has something to *do* — a worker return or scope-agent defer names a browser-completable action, or the step-D proactive sweep finds one — load [`04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md) first (it's the entry point `steady-state.md` calls into), which in turn points at [`01-queue-and-authorization.md`](./operate/01-queue-and-authorization.md) for the enqueue/authorization mechanics and [`02-execution-and-playbooks.md`](./operate/02-execution-and-playbooks.md) for the actual drain + playbook. Reach for [`03-error-handling-and-safety.md`](./operate/03-error-handling-and-safety.md) only when a navigation/action actually errors, or when an action needs trust/safety classification. Keep [`05-dont.md`](./operate/05-dont.md) as a sidebar alongside whichever of the four you're executing, the same way [`dont.md`](./dont.md) is a sidebar across every top-level phase.

**Don't pre-load adjacent sub-phases.** Each operator sub-file is self-contained for its topic; pulling the others into context defeats the split that exists to keep the eager surface small. The next sub-phase's file loads when the loop actually reaches it — most sessions with an empty `operator_queue` never load any of the five at all.
