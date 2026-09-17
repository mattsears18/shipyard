# /shipyard:do-work — Operator phase · queue, feeders, and standing authorization

**Operator sub-phase (1 of 4 on-demand bodies, plus [`05-dont.md`](./05-dont.md)).** Owns the `operator_queue`'s two feeders (reactive + proactive), the security/access-control-heavy-queue expectation note, standing authorization (including the session-owned-vs-inherited-PR scope correction), and the harness-classifier-denial branch for operator actions. Router: [`operate.md`](../operate.md). Sidebar: [`dont.md`](../dont.md) (orchestrator-wide) and [`05-dont.md`](./05-dont.md) (operator-phase-specific). Next: [`02-execution-and-playbooks.md`](./02-execution-and-playbooks.md).

### Degradation — security/access-control-heavy operator queue (expected, not a failure)

Even with a working browser backend, a fraction of operator work — sometimes the **majority** on auth-heavy repos — is access-control configuration that Claude's safety boundary forbids it from mutating (see [Safety](../operate/03-error-handling-and-safety.md#safety--trust-boundary) and the [`toggle-setting` / `console-action` classification](../operate/02-execution-and-playbooks.md#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control)). Those items are **teed up and handed back**, not driven: Claude navigates to the setting, confirms logged-in, optionally verifies current state, then leaves the mutation to the human. This is **expected behavior, not a degradation or a failure** — a session whose operator queue is entirely Firebase Auth password policy, OAuth redirect URIs, and authorized-domain allowlists will correctly hand every item back while still draining the code backlog.

**Size this fraction by the effect-based test, not by the word "security"** ([#936](https://github.com/mattsears18/shipyard/issues/936)). Only an action that changes *who can access what*, or the *strength of an authentication/authorization control*, belongs in this expected-hand-back bucket. Console work that merely sits under a provider's "Security" nav heading — dead-config cleanup, non-secret env-var removal, cosmetic project settings — is **attempted**, with the harness permission classifier as the real gate and the [two-denials branch](#operator-action-denied-by-the-harness-permission-classifier-746) as the degrade path. Counting those as pre-emptive hand-backs is what made this bucket look larger than it is, and it strands work the maintainer could have unblocked with a scoped allow-rule.

**Then size it further by direction** ([#970](https://github.com/mattsears18/shipyard/issues/970)). Of the actions that DO pass the effect-based test above, only the ones that *grant*, *widen*, or *create a new credential* stay in the hand-back bucket — narrowing a scope, revoking a stale grant, or deleting a value a merged change made redundant is attempted the same as any out-of-category action (see the [direction split](../operate/03-error-handling-and-safety.md#safety--trust-boundary) and the [classification table](../operate/02-execution-and-playbooks.md#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control)). A realistic `agent-console` queue is smaller than it first looks: on a five-item queue that's mostly access-control-flavored, only the items that genuinely widen access or mint a new credential land here — a referrer restriction added to an API key, or deleting a now-redundant secret, are attempted, not handed back.

Set expectations accordingly: the operator layer does **not** promise to auto-complete provider-console *access-control* work; it promises to attempt everything else and to tee up the rest so the human's remaining clicks are pre-navigated. The end-of-session summary distinguishes driven items from teed-up-and-handed-back items so an auth-heavy backlog reads as "teed up, your turn," not "stuck."

These security hand-backs do **not** stay on `agent-console` ([#848](https://github.com/mattsears18/shipyard/issues/848)) — the hand-back step relabels the issue to `needs-human-review` so it lands on `/my-turn`'s walked human-only queue instead of behind `agent-console`'s pointer-only line (which exists precisely because most `agent-console` items *are* eventually `/do-work`-drivable; a security mutation never is). A session with an entirely-security operator queue therefore ends with those issues on `needs-human-review`, individually walkable via `/my-turn`, not silently parked.

## The `operator_queue` and its two feeders

The [`operator_queue`](../../do-work.md#orchestrator-state) holds browser-completable items: `{ id, source, kind, target, plan, origin_ref, rank_key }`. It is fed two ways.

### Reactive feeder (steady-state step A.1)

When a worker reconcile names a browser-completable action, [steady-state.md step A.1](../steady-state.md#a1-parse-the-return-string) enqueues an `operator_queue` item instead of only stamping a defer label:

- A worker `blocked:` / `deferred:` bail whose reason is a browser action (e.g. "PR can't merge until the Vercel preview deployment is approved") — **unless** the action is a secret/credential-value write, which is never enqueued; see [Secret/credential-value writes](#secretcredential-value-writes-are-never-enqueued--hand-back-at-classification-time-991) below.
- A scope-agent `external-dependency` defer (the action lives in a provider console). By default (unless `--no-operate`), the [setup step-6 recording path](../setup/06-scope-preflight.md#6-initial-scope-pre-flight) still applies the `agent-console` label (the durable signal) **and** enqueues the operator item (the in-session working copy) — again, unless the defer is itself a secret/credential-value write.

### Proactive feeder (steady-state step D)

At each [step-D refresh](../steady-state.md#d-periodic-refresh) the orchestrator runs a **browser-completable sweep** — `/my-turn`'s discovery/ranking (open PRs, the issue backlog, recent comments, failed CI), **filtered to the browser-completable subset** — and enqueues items not already present:

- Open issues carrying the **`agent-console`** label (the durable operator-action signal) — **excluding** any whose action is a secret/credential-value write (below).
- Superseded / clearly-duplicate PRs to close.
- A provider-console toggle an issue references.
- An *unambiguous* drafted reply where the response is mechanical, not a judgment call.

**Genuine judgment calls are never enqueued.** PR reviews where a reasonable maintainer might approve or request changes, nuanced replies, "should this be done at all?" — these stay hand-backs and are surfaced to `/my-turn` (the `needs-human-review` class), not driven. The dividing line is *decision* (hand back) vs *mechanical action the ranking already chose* (drive it). See [Judgment calls](../operate/02-execution-and-playbooks.md#judgment-calls-are-never-enqueued).

### Secret/credential-value writes are never enqueued — hand back at classification time ([#991](https://github.com/mattsears18/shipyard/issues/991))

A candidate action whose effect is writing, creating, or storing a secret or credential **value** — a CI secret, a Secret Manager / KMS entry, a `.env`/config value flagged secret, an API-key or token value — is `paste-secret`-shaped **by effect**, regardless of which feeder found it, regardless of backend, and regardless of whether the value is freshly known to the human or was itself just read via an authenticated CLI call. This is structurally undrainable, not merely hard: the harness-level prohibition on entering a secret/credential value not supplied live by the user binds **every mechanism equally** — a browser form field, an authenticated CLI flag/prompt/piped-stdin, or a command built specifically so the value never touches agent context. There is no backend, no classification path, and no framing under which `/do-work` can complete the write. See [Safety](../operate/03-error-handling-and-safety.md#safety--trust-boundary) and the [`paste-secret` playbook](../operate/02-execution-and-playbooks.md#playbooks-by-kind).

**Neither feeder adds a `kind: paste-secret` (or any secret-value-write) item to `operator_queue`.** Recognizing the shape is enough to skip straight to the hand-back — there is no attempt step to gate on a classifier denial, and no retry/reframe machinery to build around one:

- **Reactive feeder** — a worker `blocked:`/`deferred:` bail whose reason is a secret/credential-value write (e.g. "needs the `EXPO_ASC_*` secret pasted in repo settings", "store a deploy-hook URL in Secret Manager") is classified at parse time and routed straight to the hand-back below.
- **Proactive feeder** — the step-D sweep excludes this shape from what it enqueues; an `agent-console`-labeled issue whose action is a secret-value write gets the hand-back treatment directly during the sweep instead of being pushed into `operator_queue` for a later drain.

**The hand-back is still productive — it is the complete, expected outcome for this class, not a consolation prize after a failed attempt.** Read-only verification against the target console/CLI (confirm the value is still absent, confirm the exact key/path/scope it needs) and composing the exact remediation command or navigation path for the human is the whole job here. Do this inline — a direct [`verify`](../operate/02-execution-and-playbooks.md#playbooks-by-kind)-shaped read, not a queued item — then post the hand-back with the composed remediation and append to **`operator_handbacks`** (`reason: "values-only-user-has"`), same as the `paste-secret` playbook's own tee-up step.

**Do not route this through the [exhaustion checklist](../operate/03-error-handling-and-safety.md#exhaustion-checklist--before-declaring-a-console-unreachable-998).** That checklist governs *reachability* claims ("I couldn't get to it on this attempt" vs "it's unreachable") — a secret/credential-value write is undrainable **by policy**, not by reachability, so walking the checklist against it is a pointless exhaustion exercise on an action that was never going to be attempted regardless of which identity, domain-form, or CLI-auth-state is reached.

### Draining

When the orchestrator is idle (a code worker is in flight and not yet returned, or it's a step-D tick), it pops the highest-`rank_key` `operator_queue` item, runs its [playbook](../operate/02-execution-and-playbooks.md#playbooks-by-kind), records the result, and removes it from the queue (clearing the issue's `agent-console` label on success). Serialized — at most one browser action in flight at a time. Write-through the queue to the session-state file on each enqueue/drain.

**Hand-backs and post-completion items get a [`verify`](../operate/02-execution-and-playbooks.md#playbooks-by-kind) read first.** Before handing an item back (a security `toggle-setting`, a logged-out console, an `external-dependency` defer), the operator reads the live console state to confirm/deny the premise and make the hand-back instructions concrete — so the teed-up item carries exact toggles/values, not a guess. And when a human completes an action mid-session (flips the toggle, pastes the secret), a `verify` re-read of the console reports pass/fail; a verified pass is what lets the drain confidently clear the `agent-console` label and close the originating issue, while a verified fail keeps the item handed back with the discrepancy named. Reading never mutates, so this `verify` step stays inside the safety boundary even for security/access-control settings the operator may not *change*. (A `paste-secret`-shaped candidate gets the same read-first treatment, just inline at classification time rather than mid-drain — see [Secret/credential-value writes](#secretcredential-value-writes-are-never-enqueued--hand-back-at-classification-time-991) above.)

## Standing authorization

**Running `/do-work` is itself the authorization** ([#608](https://github.com/mattsears18/shipyard/issues/608); default-on since [#661](https://github.com/mattsears18/shipyard/issues/661)) — the operator layer is the default, so a bare `/do-work` grants it; only `--no-operate` / `--hands-off` withholds it. It grants standing consent, for the duration of the run, to perform **anything completable by manipulating the browser** — navigate, click, fill, type, submit, comment, close, merge — without a per-action in-chat "say 'close it' to proceed" confirmation, **for session-owned artifacts** (see [Scope](#scope-of-standing-authorization--session-owned-artifacts-vs-inherited-third-party-prs-746) below). The user is watching their own logged-in browser; the act of invoking the command is the go-ahead. The orchestrator **announces** each browser action (one line) before performing it, then reports what it did — transparency without a blocking yes/no.

What standing authorization does **not** cover:

- **Judgment calls** — consent to do the *mechanical action the ranking chose*, not to *make a decision on the user's behalf*. See [Judgment calls](../operate/02-execution-and-playbooks.md#judgment-calls-are-never-enqueued).
- **Actions outside the browser** — it is not consent to run arbitrary shell commands, push code, or act outside the Chrome being driven.
- **Untrusted-author–derived actions** — never perform a browser action whose content/target is derived from an issue authored by a login outside `trusted_authors`. See [Safety](../operate/03-error-handling-and-safety.md#safety--trust-boundary).
- **`--dry-run`** — the "preview, do nothing" path. With `--dry-run`, the orchestrator prints each operator item's plan and does **not** touch the browser.
- **What the Claude Code harness classifier will independently grant** — this section states the operator layer's *own* policy; it is not a technical override of the harness's auto-mode permission classifier, which evaluates every mutating tool call on its own terms and can still deny one. See the next two sections.

### Scope of standing authorization — session-owned artifacts vs inherited third-party PRs ([#746](https://github.com/mattsears18/shipyard/issues/746))

Standing authorization reliably covers **session-owned artifacts**:

- Any PR in `session_prs` (opened, fix-checks-touched, or adopted by this session).
- Any issue this session dispatched a worker against.

For a `merge-pr` / `close-pr` item whose target PR is **not** session-owned — an **inherited third-party PR** the session never opened or touched (the common case: a Dependabot PR, a PR from another contributor or bot) — the harness classifier reasons about the action *by name* and denies it:

```
Permission for this action was denied by the Claude Code auto mode classifier.
Reason: [External System Writes] Closing and commenting on dependabot PR #124 —
an item the agent did not create this session — was not named by the user;
`/shipyard:do-work` does not authorize closing that specific PR.
```

**That denial is correct, not a bug.** Closing or merging a PR outside the session's own artifacts is outward-facing and irreversible, and the classifier is right to gate it even though the operator layer's default posture is otherwise operator-inclusive. Nothing here exists to weaken, work around, or bypass that gate.

**The fix is a batched confirmation, not a bypass.** The observed classifier behavior keys off "was not named by the user" — an action the *user* has explicitly named in-chat (via `AskUserQuestion`) is subsequently permitted. So before draining the **first** `merge-pr` / `close-pr` item in a session whose target is not session-owned, batch **every currently-queued** such item into **one** `AskUserQuestion` — never one confirmation per item:

```
AskUserQuestion:
  "N inherited PR(s) are queued for merge/close — none opened by this session:
     - #124 close (superseded — @astrojs/check peer-caps typescript to ^5||^6)
     - #131 merge (green, no conflicts)
   Proceed with all of these?"
  options: ["Proceed with all", "Review one at a time", "Skip — leave as hand-backs"]
```

- **"Proceed with all"** → drive each queued item's playbook normally; the user's explicit naming is what lets the classifier's own evaluation pass. Track a session-local flag (`inherited_pr_confirmed = true`) so a **later**-arriving inherited-PR item (surfaced by the proactive sweep after this point) is driven directly without re-asking — the batch confirmation covers the rest of the session, not just the items queued at ask-time.
- **"Review one at a time"** → fall back to per-item confirmation for the rest of this session (no batching benefit, but still explicit per-item naming rather than a blind auto-drive attempt).
- **"Skip — leave as hand-backs"** → leave every queued inherited-PR item as a hand-back (`agent-console` / surfaced to [`/my-turn`](../../my-turn.md)); do not attempt to drive any of them this session.

This is a **one-shot, session-scoped ask**, not a per-action round-trip — it composes with the "no per-action confirmation" promise above: standing authorization alone covers the common (session-owned) case, and this one batched question covers the inherited-PR tail. It fires at most once per session regardless of how many inherited-PR items eventually surface.

### Production-class console actions — one batched confirmation, then stop the class after a denial ([#1563](https://github.com/mattsears18/shipyard/issues/1563))

The inherited-PR batch above has a sibling: **production-class** `toggle-setting` / `console-action` items. An item is production-class when its command or browser action **mutates a production data store or a shared cloud resource**. Examples: enabling PITR or a backup schedule on a prod database, creating scheduler jobs, running a backfill or migration against prod data, or editing prod membership rows. It does not matter whether the item is driven by CLI (`gcloud`, `firebase`, `vercel`) or by browser. A maintainer decision recorded through `/shipyard:my-turn`, with the exact commands, does **not** change the class. The classifier evaluates the command itself, and a decision on a GitHub issue is not a confirmation the classifier can see. Without this section, the operator drains these items one at a time. The first denial then surfaces the problem, and the classifier stays noticeably stricter for the rest of the session. In #1563's repro, a read-only `gh run view` and a prod `firestore_get_document` read were both denied after the first prod mutation was refused.

**This section decides *how* an item is attempted, never *whether* one may be.** A **delete** or an **access-widening** change to a live surface is still a hand-back no matter what the user answers. See `shipyard:worker-preamble` § "Never irreversibly mutate live external state" and the [security/access-control table](./02-execution-and-playbooks.md#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control). This batch covers only the attempt-class remainder: creates, narrowings, and additive writes.

**1. Batch before the first attempt.** Before running the **first** production-class item in a session, collect **every** queued production-class item. What happens next depends on whether the session is attended:

- **Attended** (an interactive session where `AskUserQuestion` is available): ask **one** question that names every item's **exact command**. The explicit naming is what the classifier's "was not named by the user" test keys off, just as it does for inherited PRs:

  ```
  AskUserQuestion:
    "N production-class action(s) are queued — each mutates a live prod resource:
       - #4770  gcloud firestore databases update --project <prod> --enable-pitr
       - #4752  gcloud scheduler jobs create http <job> --project <prod> ...
     Run all of these now?"
    options: ["Run all", "Review one at a time", "Skip — hand them all back"]
  ```

  The answers follow the same shape as the inherited-PR options: "Run all" sets the session-local `prod_class_confirmed = true` ([`orchestrator-state-reference.md`](../orchestrator-state-reference.md)), and the other two options fall back to per-item confirmation or to a hand-back.
- **Unattended** (a background job, a scheduled routine, `claude -p`, or any session where `AskUserQuestion` is unavailable): **attempt none of them.** Post one consolidated hand-back, with one `operator_handbacks` entry per item and `reason: "prod-class-unattended"`. Each issue keeps `agent-console` and gets a comment carrying its exact command and the permission-rule remedy from step 3 below.

**2. Stop the class after the first denial.** When a classifier denial's category tag names **`Modify Shared Resources`** or **`Production Reads`**, set the session-local `prod_class_stopped = { category, denied_at }`. For the rest of the session, attempt **no** further production-class action, including **reads** of a prod resource. That means no prod `firestore_get_document` and no `gcloud ... describe` against the prod project. Record the denial **once** in `operator_denials`. Then hand back every remaining production-class item with `reason: "prod-class-stopped"`, each carrying its exact command and the remedy. This **replaces** the one-re-attempt rule in [step 2 below](#2-at-most-one-re-attempt--and-only-to-cite-an-explicit-confirmation-already-on-record) for this class. If the classifier refused an item the user already named in the batch, citing that confirmation again will not change its answer. Keep draining **non**-production items. The stop is scoped to the class, not the session. If an unrelated read is also denied after the stop, handle it on its own path; it is not a reason to end the session.

**3. Name the permission-rule remedy.** Every production-class hand-back comment, and the matching [end-of-session summary](../cleanup-summary.md#end-of-session-summary) entry, names the concrete allow rule that would make the next session automatable. Derive the rule from the handed-back command's leading tokens, for example `Bash(gcloud firestore:*)` or `Bash(gcloud scheduler:*)`, and add it via `/permissions` or `permissions.allow` in `.claude/settings.json`. The remedy is a suggestion for the maintainer. It is not the classifier's reasoning, so it may appear in a public comment, while the verbatim `denial_text` stays local ([step 3 below](#3-on-a-second-denial-or-nothing-to-cite-degrade-to-a-hand-back--never-drop-it)). Never add the rule yourself. Changing permission settings is the maintainer's call.

## Operator action denied by the harness permission classifier ([#746](https://github.com/mattsears18/shipyard/issues/746))

Even a properly-scoped, batch-confirmed operator action can still be refused outright by the harness classifier — the same layer that can deny the orchestrator's own `Agent` dispatch calls ([#718](../orchestrator-state-reference.md)). A denial here means the mutating call (`gh pr close` / `gh pr merge` / a browser mutation) never executed. **The denial is correct, not a bug** — see the reasoning in the [Scope](#scope-of-standing-authorization--session-owned-artifacts-vs-inherited-third-party-prs-746) section above. This section exists so a denied item has a **defined next step** instead of silently vanishing from `operator_queue`.

### 1. Record the denial

Append an entry to the session-local **`operator_denials`** struct (see [`orchestrator-state-reference.md`](../orchestrator-state-reference.md)):

```
{ kind: "merge-pr" | "close-pr" | "paste-secret" | "toggle-setting" | "reply-comment" | "console-action",
  target: "<url or #N>", denied_at: "<iso-8601 UTC>",
  denial_text: "<verbatim first line of the harness denial>",
  outcome: "reframed" | "handed-back" | "shipped-after-reframe" }
```

Log the advisory inline so the denial is visible in the turn transcript, not just at exit:

```
[operator-denied] kind=<kind> target=<target> attempt=<1|2> — operator action refused by the permission classifier (#746)
```

### 2. At most ONE re-attempt — and only to cite an explicit confirmation already on record

Mirrors [dispatch-rules.md's #718 discipline](../dispatch-rules.md#dispatch-denied-by-the-harness-permission-classifier-718), applied to operator actions. A re-attempt is permitted **if and only if** the first attempt's framing failed to reflect an explicit user confirmation that already exists — e.g. the batched `AskUserQuestion` above named this exact item and the user answered "Proceed with all," but the tool call wasn't phrased to surface that. The corrected attempt states the confirmation plainly (quote the batched question and the answer). That is the *only* kind of change permitted.

**Forbidden, without exception:**

- Do NOT iterate wording against the classifier — no rephrasing across attempts hoping one slips through.
- Do NOT route around the denial through a different mechanism (a browser click instead of `gh pr close`, or vice versa) — classifier policy targets the *effect*, not the tool name.
- Do NOT re-attempt when there is no explicit confirmation to cite. If the batched confirmation was never obtained for this item (e.g. discovered mid-drain after a "Skip" answer, or the user chose "Review one at a time" and hasn't confirmed this specific item), there is nothing to correct — go straight to step 3.

### 3. On a second denial (or nothing to cite): degrade to a hand-back — never drop it

1. Record the second denial in `operator_denials` with `outcome: "handed-back"`.
2. Remove the item from `operator_queue`, but keep (or apply) its `agent-console` label so it surfaces to [`/my-turn`](../../my-turn.md) rather than vanishing.
2.5. Append an entry to the session-local **`operator_handbacks`** list ([`orchestrator-state-reference.md`](../orchestrator-state-reference.md)) with `reason: "denied-by-classifier"` — this is what promotes the hand-back from the local `Operator denied:` transcript line into the [end-of-session `Operator queue — needs you` block](../cleanup-summary.md#end-of-session-summary), so a permission-classifier hand-back reads as an explicit "needs you" item rather than only a routine denial-count line (#849).
3. **Do not post the classifier's reasoning to any public GitHub artifact.** If a hand-back comment is warranted, state the fact and outcome only — mirrors `shipyard:worker-preamble` § "After a classifier denial" and [#718's same rule for dispatch denials](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt). The verbatim `denial_text` stays **local** — the end-of-session summary and the on-disk HTML report only.
4. Do NOT file a follow-up issue arguing the denial was wrong — that's a maintainer decision, made after they see the `Operator denied:` line in the summary.

### 4. The queue does not stay silently short one item

A hand-back removes an item from `operator_queue`, but the item is not *lost* — it stays durably visible as an `agent-console` hand-back. Continue draining the rest of the queue in the same turn; a denial is never a reason to stop draining. The one narrowing is a production-class denial: it stops that **class** only ([#1563](#production-class-console-actions--one-batched-confirmation-then-stop-the-class-after-a-denial-1563)), and every other item keeps draining.
