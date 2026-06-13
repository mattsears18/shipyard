---
name: auditing-authenticated-surfaces
description: Use when auditing a web URL whose interesting surfaces live behind a login wall (authenticated / signed-in / login-walled pages — dashboard, feed, settings, account). Provides the safe pattern for reaching those surfaces — a login harness that never echoes secrets, a pre-provisioned account, the SPA storageState session gotcha, and asserting on a protected route rather than `/`. Invoked by the live-URL auditors that tour signed-in surfaces (`web-ux`, `a11y`).
---

# Auditing authenticated surfaces

The interesting surfaces of most apps — the dashboard, the feed, account settings, the create/edit flows — live **behind a login wall**. A live-URL auditor (`web-ux`, `a11y`, etc.) that only tours the public marketing pages misses the bulk of the app. This skill is the reusable, framework-agnostic kernel for reaching authenticated surfaces *safely and reliably*.

The four rules below are the load-bearing kernel. Project-specific wiring — **which** account, **which** gitignored env file, **which** seed/provision command — stays in the consumer repo (its `CLAUDE.md`, its audit-setup docs). This skill captures only the generic pattern; the consumer repo supplies the particulars.

## 1. Auditors must NOT self-authenticate by typing secrets

**Do not type an email/password into the browser MCP, and do not pull credentials into agent context.** A password typed through a browser-automation MCP (`fill`, `type_text`, `fill_form`) — or read into the agent's working memory so it can be typed — lands in transcripts and tool-call logs, which is a credential-handling hazard. The credential leaks into every downstream record of the session even when the audit itself is benign.

The safe pattern is a **login harness**: a small script (Playwright, Puppeteer, a shell wrapper around a headless browser — whatever the consumer repo provides) that:

- **Reads credentials directly from a gitignored env file** (`.env.audit`, `.env.local`, etc.) — never from the agent's context, never echoed to stdout. The harness sources the secret and uses it without the agent ever seeing the value.
- **Never echoes the secret.** No `echo "$AUDIT_PASSWORD"`, no logging the filled value, no screenshotting the password field mid-type. The harness's output is *artifacts*, not credentials.
- **Performs the login and captures artifacts for the auditor to judge** — screenshots of the authenticated surfaces, `axe-core` JSON (accessibility violations), DOM probes (snapshots of the a11y tree / element queries). The auditor then reads those artifacts and forms findings, exactly as it would for a public surface — the only difference is the harness, not the auditor, holds the secret.

The division of labor is the whole point: the **harness** handles the secret (reads it from disk, types it into the live browser, never surfaces it); the **auditor** handles the judgment (reads the captured artifacts, files findings). The secret never crosses into the auditor's context.

## 2. A fresh signup can't reach authenticated surfaces — require a pre-provisioned account

Do **not** try to create a net-new account autonomously to get past the login wall. Email-verification links, OAuth round-trips, SMS / phone verification, age gates, and CAPTCHA all block an autonomous signup — the auditor will stall waiting for a verification step it can't complete, or worse, half-create an account that's stuck in an unverified limbo state.

Instead, **require a pre-provisioned account**: a real, already-verified test account whose credentials live in the gitignored env file (rule 1). The consumer repo is responsible for provisioning it (a seed command, a manually-created test user, a fixture account) and documenting it; the auditor consumes it. If the pre-provisioned account is missing, the auditor should surface that as a setup gap — *not* attempt a signup.

## 3. SPA session gotcha — log in and tour within ONE live context

Many SPA auth SDKs — **Firebase Web SDK is the common one**, but also several OAuth/OIDC client libraries — store the auth token in **IndexedDB or localStorage**, not in cookies. Playwright's `storageState` (and equivalent "save the session, reload it later" mechanisms in other automation tools) **does NOT serialize IndexedDB**, and serializes localStorage incompletely for some SDKs. The consequence: a saved-then-reloaded `storageState` comes back **logged out** — the token the SDK needs is simply gone, so the reloaded context renders the public/logged-out view and every authenticated-surface finding is silently wrong.

**The fix: log in and tour the authenticated surfaces within ONE live browser context.** Don't log in, save `storageState`, tear down, and reload it for the tour. Keep the context that performed the login alive for the entire authenticated portion of the audit — navigate between authenticated routes within that same live session. If the tour must span multiple harness invocations, each invocation re-authenticates fresh rather than restoring a serialized session.

## 4. Assert on a protected route, not `/`

The landing page (`/`) renders the **public marketing view when logged out** — so a screenshot of `/` looking like a normal page is a **false "we're authenticated" signal**. An auditor that confirms login by hitting `/` and seeing content will happily tour the *logged-out* app believing it's signed in.

**Assert on a route that genuinely requires auth** — one that **302s / redirects to the login page when unauthenticated** (`/dashboard`, `/settings`, `/account`, an app-specific protected path the consumer repo names). After the harness logs in, navigate to the protected route and confirm it **renders the authenticated view** (not a redirect to login). That round-trip — protected route renders → you're authenticated; protected route 302s to login → you're not — is the reliable session check. `/` is not.

## Putting it together

A correct authenticated-surface audit:

1. Confirms a **pre-provisioned** test account exists (rule 2) with credentials in a **gitignored env file** (rule 1).
2. Runs the consumer repo's **login harness**, which reads the secret from that file, logs in **without echoing it**, and keeps **one live context** alive (rule 3).
3. **Verifies the session against a protected route** that 302s when logged out (rule 4) — not against `/`.
4. Within that same live context, tours the authenticated surfaces and captures **artifacts** (screenshots / axe-core JSON / DOM probes) for the auditor to judge (rule 1).

The auditor never holds the secret; the harness never holds the judgment.
