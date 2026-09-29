---
name: auditing-authenticated-surfaces
description: Use when auditing a web URL whose interesting surfaces live behind a login wall (authenticated / signed-in / login-walled pages — dashboard, feed, settings, account). Provides the safe pattern for reaching those surfaces — a login harness that never echoes secrets, a pre-provisioned account, the SPA storageState session gotcha, and asserting on a protected route rather than `/` — plus the inverse check for public/anonymous audits: how to actually prove a session is SIGNED OUT (never via `indexedDB.databases()` emptiness). Invoked by the live-URL auditors that tour signed-in or signed-out surfaces (`web-ux`, `a11y`, `marketing`).
---

# Auditing authenticated surfaces

The interesting surfaces of most apps — the dashboard, the feed, account settings, the create/edit flows — live **behind a login wall**. A live-URL auditor (`web-ux`, `a11y`, etc.) that only tours the public marketing pages misses the bulk of the app. This skill is the reusable, framework-agnostic kernel for reaching authenticated surfaces *safely and reliably*.

The five rules below are the load-bearing kernel — rules 1–4 get you *in*; rule 5 proves you're *out*, for audits whose findings are about what an anonymous visitor sees. Project-specific wiring — **which** account, **which** gitignored env file, **which** seed/provision command — stays in the consumer repo (its `CLAUDE.md`, its audit-setup docs). This skill captures only the generic pattern; the consumer repo supplies the particulars.

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

## 5. Proving a session is SIGNED OUT — record count, not database existence

Audits of public / anonymous surfaces ("a signed-out visitor has no way to sign up", "the landing page shows signed-in chrome") are only as good as the claim that the browser really was signed out. Verify that claim — and never with `indexedDB.databases()`.

**`indexedDB.databases()` returning `[]` is not a signed-out proof, and a non-empty list is not a signed-in proof.** On a Firebase-Web-SDK app the auth database's *existence* is uncorrelated with auth state in both directions: the list is empty on a fresh origin *before the SDK has initialised* (an early probe sees `[]` whatever the auth state), and once it initialises the SDK creates `firebaseLocalStorageDb` whether or not a user record is stored in it. Only the **record count inside the auth object store** carries the signal. Getting this wrong is not a quiet miss — it produces a *confidently* wrong finding that carries a stated verification step and reads as evidence-backed ([#1601](https://github.com/mattsears18/shipyard/issues/1601): an audit "verified signed-out" via `databases() → []` while the auth store held a live user record the whole time; two of the resulting issue's three headline findings did not reproduce once the store was genuinely empty).

**The check, for Firebase Web SDK** (other SDKs: the consumer repo names its own store or key — the shape is the same). Run it only **after the page has fully loaded**, so the SDK has initialised:

```js
// -1 = unknown. Never create the database as a side effect of probing it.
const authRecords = await new Promise((resolve) => {
  const req = indexedDB.open('firebaseLocalStorageDb');
  req.onupgradeneeded = () => req.transaction.abort(); // DB absent → abort, don't create it
  req.onerror = () => resolve(-1);                     // includes that aborted-absent case
  req.onblocked = () => resolve(-1);
  req.onsuccess = () => {
    const db = req.result;
    try {
      if (!db.objectStoreNames.contains('firebaseLocalStorage')) return resolve(-1);
      const c = db.transaction('firebaseLocalStorage', 'readonly')
        .objectStore('firebaseLocalStorage').count();
      c.onsuccess = () => resolve(c.result);
      c.onerror = () => resolve(-1);
    } catch { resolve(-1); } finally { db.close(); }
  };
});
// 0 → no stored user (signed out); > 0 → SIGNED IN; -1 → unknown
```

Three properties are load-bearing:

- **Fail closed on unknown.** `-1` — an unreadable store, a missing database, a missing object store — means *unknown*, never "signed out". A plain `indexedDB.open()` on a name that doesn't exist silently **creates** an empty database; the `onupgradeneeded` abort is what keeps an absent database in the unknown bucket instead of letting the probe manufacture one (and leave it behind for the app to trip over).
- **Corroborate with a protected route — the inverse of rule 4.** Navigate to a route that requires auth and confirm it **redirects to the login page**. A signed-out claim needs both: a record count of `0` *and* the protected route bouncing to login. Either one disagreeing → unknown. `/` rendering the public landing proves nothing in either direction.
- **Mind rule 3 from the other side.** A reloaded `storageState` comes back logged out because the IndexedDB token was never serialised — a context the record count correctly reports as `0`. It is genuinely signed out, but it says nothing about what a real signed-in user sees; don't reuse it to reason about the authenticated view, and don't mistake the logged-out render for an authenticated-surface finding.

**If the verdict is unknown, do not file a finding whose premise is "a signed-out visitor sees X".** Either re-establish a verified signed-out context (a fresh browser profile or incognito context, then re-run both checks) or drop the finding. When you do file one, name the evidence in the issue body — the record count and the protected-route redirect you observed — not merely "verified signed-out".

## Putting it together

A correct authenticated-surface audit:

1. Confirms a **pre-provisioned** test account exists (rule 2) with credentials in a **gitignored env file** (rule 1).
2. Runs the consumer repo's **login harness**, which reads the secret from that file, logs in **without echoing it**, and keeps **one live context** alive (rule 3).
3. **Verifies the session against a protected route** that 302s when logged out (rule 4) — not against `/`.
4. Within that same live context, tours the authenticated surfaces and captures **artifacts** (screenshots / axe-core JSON / DOM probes) for the auditor to judge (rule 1).

For a **signed-out** (public / anonymous-surface) audit, replace steps 1–3 with rule 5: start a fresh context, confirm the auth-store record count is `0` *and* a protected route redirects to login, and only then attribute what you see to an anonymous visitor.

The auditor never holds the secret; the harness never holds the judgment.
