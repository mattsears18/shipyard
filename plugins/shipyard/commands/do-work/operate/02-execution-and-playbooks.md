# /shipyard:do-work — Operator phase · execution mechanics and playbooks

**Operator sub-phase (2 of 4 on-demand bodies, plus [`05-dont.md`](./05-dont.md)).** Owns the mechanics of draining a queued item (plan-then-act, tab reuse, perception, batching, recording), the per-kind playbooks (`close-pr` / `merge-pr` / `toggle-setting` / `console-action` / `paste-secret` / `reply-comment` / `verify`), and the judgment-calls-are-never-enqueued rule. Router: [`operate.md`](../operate.md). Sidebar: [`dont.md`](../dont.md) (orchestrator-wide) and [`05-dont.md`](./05-dont.md) (operator-phase-specific). Prev: [`01-queue-and-authorization.md`](./01-queue-and-authorization.md). Next: [`03-error-handling-and-safety.md`](./03-error-handling-and-safety.md).

## Draining an item — execution mechanics

### Plan, then act (announce, don't block)

Before touching the browser for an item, print its plan: the **action** (imperative, artifact ref, URL), the **ordered browser steps**, and the **backend** in use. Then proceed *through* the plan and execute it — announce each action on one line, perform it, report the result. Do **not** stop for a per-action yes/no (standing authorization). With `--dry-run`, stop at the plan and touch nothing.

```
Operator: close superseded duplicate PR #1994 (replaced by #2001)
  Backend: claude-in-chrome
  Plan: navigate #1994 → read (confirm open) → click "Close pull request"
Executing: close PR #1994
[read page — PR #1994, open, logged in as mattsears18]
[click "Close pull request"]
Done: Closed PR #1994.
```

### Tab reuse

Consult the tab context from preflight/detection. If a tab is already open on the target artifact (exact URL, or same origin + path), **reuse it** rather than opening a new tab — avoids cluttering the user's real browser.

### Perception — read the page, don't reflexively screenshot

Default perception is **reading the page** (`read_page` / `get_page_text` on the extension; `take_snapshot` on chrome-devtools-mcp) — cheaper, more reliable, more token-efficient than a screenshot. Screenshot **only when visual state genuinely matters** (confirming the real logged-in profile, or a layout-dependent action).

### Efficiency — batch deterministic sequences

On the extension backend, bundle deterministic multi-step sequences (navigate → wait → read → act) into a single `browser_batch` call. Since there's no per-action confirmation gate to break the sequence, a navigate → read → mutate run can batch end-to-end.

### Recording (`--record`)

When `--record` is passed and the extension backend is selected, wrap the action in `gif_creator` (a few frames before/after for smooth playback) and write a meaningfully-named GIF (e.g. `do-work-operate-close-pr-1994.gif`); surface the path. On chrome-devtools-mcp (no GIF support), print a one-line note and proceed. `--record` is never a hard failure.

## Playbooks by kind

All perception defaults to **reading the page**. The mutating playbooks (`close-pr` / `merge-pr` / `toggle-setting` / `paste-secret` / `reply-comment`) *complete* an action; [`verify`](#verify-read-only-console-verification--never-mutates) is the read-only outcome that only *reads* — it confirms a premise, makes a hand-back concrete, or checks that a just-completed human action took, and never mutates.

**`close-pr` / `merge-pr` (mechanical, ranking-surfaced):**
0. **If the target PR is not session-owned** (not in `session_prs`, not opened/touched this session), it needs the [batched inherited-PR confirmation](../operate/01-queue-and-authorization.md#scope-of-standing-authorization--session-owned-artifacts-vs-inherited-third-party-prs-746) before step 1 — standing authorization alone does not reliably cover it, and the harness classifier may deny the action outright regardless of this playbook. Skip this step for session-owned PRs.
1. Navigate to the PR URL (reuse an open tab).
2. Read the page; confirm it's still open and in the expected state.
3. Click "Close pull request" / "Merge". Announce, execute, report. (These are mechanical actions the ranking already chose — standing authorization covers them for session-owned PRs; deciding *whether* to merge a substantive PR is a judgment call, closing a clearly-superseded duplicate is mechanical.) If this call is denied by the harness classifier, follow [Operator action denied](../operate/01-queue-and-authorization.md#operator-action-denied-by-the-harness-permission-classifier-746) — do not retry with reworded phrasing.

**`toggle-setting` / `console-action` (third-party console):**
1. Navigate to the provider deep link (derived per [third-party deep-links](../operate/03-error-handling-and-safety.md#third-party-console-deep-links)).
2. Confirm the page loaded and the user is logged in — **screenshot is warranted** here (logged-in state is visual and the deep link targets a real account).
3. If NOT logged in: print "Navigated to <URL> but the page appears logged out — action requires manual login." Hand back (leave the item on its `needs-operator` label).
4. **Classify the action before mutating** (see [Claude-safe vs hand-back classification](#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control) below):
   - **Claude-safe to auto-drive** (mechanical, non-security: a feature flag, a display/timezone/locale preference, a non-security webhook URL, a build/deploy trigger): execute it (flip the switch / fill the form with known values), report.
   - **Hand back (security / access-control)** — the action modifies an **auth / security / access-control setting** (password policy, MFA/2FA enforcement, OAuth redirect URIs, authorized domains, IAM roles/bindings, sharing or member permissions, API-key / token scopes, firewall/allowlist rules, any "security" toggle): **tee up and hand back** — navigate, confirm logged-in, optionally read/verify the current state, then leave the mutation to the human. Print: "Security/access-control setting — opened <URL> and verified current state; flip it yourself (Claude does not modify access controls)." Leave the item on its `needs-operator` label. Do NOT perform the toggle even though the operator layer granted standing authorization — see the [Safety boundary note](../operate/03-error-handling-and-safety.md#safety--trust-boundary) for why this boundary outranks the flag.

#### Claude-safe to auto-drive vs hand back (security/access-control)

The `toggle-setting` / `console-action` step-4 classification, made concrete. Claude's safety boundary forbids modifying **system/security settings or access controls** — and that boundary **outranks** the operator layer's standing authorization *and* outranks explicit user authorization. So the most common class of provider-console operator work (auth/security config) is structurally a hand-back, not an auto-drive, regardless of the standing-authorization grant. Mirror the [`paste-secret`](#playbooks-by-kind) tee-up-and-hand-back shape: drive the browser *to* the setting and verify state, but leave the security mutation to the human.

| Claude-safe to **auto-drive** (mechanical, non-security) | **Hand back** (security / access-control) |
|---|---|
| Feature-flag / experiment toggle | Password policy, MFA/2FA enforcement |
| Display / timezone / locale / notification preference | OAuth redirect URIs, authorized domains, sign-in provider config |
| Non-security webhook URL, build/deploy trigger, cache purge | IAM roles/bindings, member or sharing permissions |
| Plan/usage display, cosmetic project settings | API-key / token scopes, service-account grants |
| | Firewall / IP-allowlist / network access rules, any "security" toggle |

When in doubt about which column an action falls in, **hand it back** — the conservative default is to not mutate a setting that *might* be access-control. A wrongly-handed-back mechanical toggle costs the user one click; a wrongly-auto-driven security toggle is a safety-boundary violation.

**`paste-secret` (third-party console / repo settings, value held by the user):**
1. Navigate to the secrets/settings page.
2. Confirm loaded + logged in.
3. **Tee up and hand back** — pasting a *real secret value* is not browser-completable from the orchestrator's side (the value lives in the user's password manager, not in any issue/PR — and must never be derived from issue text). Print: "Secrets page is open — paste the value from your password manager." Leave the item handed back.

**`reply-comment` (only when unambiguous):**
1. Navigate to the issue/PR, read the question in context.
2. If the response is **mechanical/unambiguous** (a factual pointer, a "done in #N" close-out): draft it, post it under standing authorization, report.
3. If it needs the user's **evaluation** (a nuanced or contestable reply): **do not post** — draft it and hand back ("Draft reply above — post it when ready"). This is a judgment call.

**`verify` (read-only console verification — never mutates):**

A first-class outcome on its own, and the read-only complement to every mutating playbook above. Where the others *complete* an action, `verify` only *reads* — navigate, perceive, report — so it stays inside the [safety boundary](../operate/03-error-handling-and-safety.md#safety--trust-boundary) unconditionally (reading isn't mutating, so the security/access-control carve-out that forces `toggle-setting` to hand back does **not** restrict `verify`). It is the highest-value thing the operator layer does on a security-setting-heavy backlog that is otherwise all hand-backs: even when no item is auto-drivable, reading the consoles makes the hand-backs precise and confirms the human's just-completed changes took. Two facets:

1. **Premise check / hand-back enrichment** — for **any** hand-back item (a `toggle-setting` security carve-out, a `paste-secret`, a logged-out console, a worker `external-dependency` defer), the operator MAY navigate to and read the relevant console *before* handing it back to:
   - **Confirm or deny the premise.** The issue may assume a setting is in a state it isn't (issues sit open while consoles drift). Reading the live state turns "I think prod requires uppercase chars" into "confirmed: prod Auth requires uppercase + numeric."
   - **Make the hand-back concrete.** Replace a vague "tighten the password policy" with the exact toggles/values the human must change ("uncheck these two boxes on prod"). The teed-up hand-back then carries precise instructions rather than a guess.
2. **Post-action verification** — for a **just-completed human action** (the user flipped a security toggle, pasted a secret, or saved a console change while you waited), the operator MAY re-read the console to confirm the change took and **report pass/fail**. This feeds the reconcile that closes the originating issue: a verified-pass lets the loop confidently clear the `needs-operator` label and close the issue; a verified-fail keeps it handed back with the discrepancy named.

Steps:
1. Navigate to the relevant console/page (reuse an open tab; derive the deep link per [third-party deep-links](../operate/03-error-handling-and-safety.md#third-party-console-deep-links)).
2. Confirm the page loaded and the user is logged in. If NOT logged in: print "Navigated to <URL> but the page appears logged out — can't verify state." and leave the item handed back.
3. **Read the page** (default perception — `read_page` / `get_page_text` / `take_snapshot`; never reflexively screenshot). Extract the specific setting/value the verification targets.
4. Report the observed state: for facet 1, a precise hand-back ("prod Auth requires uppercase+numeric — uncheck both to satisfy #N"); for facet 2, an explicit **pass/fail** against the expected post-action state ("prod length-only ✓; test min-length 6→8 ✓ — change verified").

`verify` never clicks, fills, or submits — it only navigates and reads. Because it never mutates, standing authorization always covers it and the security/access-control boundary never blocks it; a `verify` outcome is the read-only half that pairs with the [`toggle-setting` hand-back](#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control)'s "optionally read/verify the current state" step. `verify` is **not** enqueued as a standalone item by the proactive sweep — it rides on the hand-back/post-action items above as the read step that enriches them.

## Judgment calls are never enqueued

Standing authorization is consent to do the *mechanical action the ranking surfaced*, not to *make a decision on the user's behalf*. The proactive sweep never enqueues, and the reactive feeder never drives:

- **PR reviews** where a reasonable maintainer might approve or request changes — teed up, handed back.
- **Nuanced / contestable replies** — drafted, handed back.
- **"Should this be done at all?"** calls — surfaced, not acted on.

Rule of thumb: *if a reasonable maintainer might look at the same artifact and reach a different conclusion, it's a judgment call.* Tee it up (drive the browser to it, surface the context), hand back. These carry the `needs-human-review` label and surface to `/my-turn`, never `needs-operator`.
