# /shipyard:do-work — Setup phase · scope entry handling

**Setup sub-phase (cluster 4 of 5, part 4 of 5 — [#994](https://github.com/mattsears18/shipyard/issues/994), re-split by [#1431](https://github.com/mattsears18/shipyard/issues/1431) and [#1446](https://github.com/mattsears18/shipyard/issues/1446)).** Finishes step **6** from [`06b-scope-carveouts.md`](./06b-scope-carveouts.md) — handling each returned scope-agent entry (ready / deferred / already-landed / rejected, the re-gate guard, `raw_backlog` removal). Steps **6.5 → 6.8** (status-line + state-change-banner UI, setup-timing flush) moved to [`06e-scope-ui-timing.md`](./06e-scope-ui-timing.md) when this file crossed its token-budget cap. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`06b-scope-carveouts.md`](./06b-scope-carveouts.md) (same cluster, part 3 of 5). Next: [`06e-scope-ui-timing.md`](./06e-scope-ui-timing.md) (same cluster, part 5 of 5).

#### Handling each returned entry (fires as each background agent completes)

- **Ready entries** — partition each `files` array into `{ hard: [...], soft: [...] }` by matching each path against the soft-collision glob set defined in the [Dispatch rules](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) (default + any `--soft-collision-path` extensions). Paths that match a soft-collision glob go into `soft`; everything else goes into `hard`. The orchestrator does the partitioning — scoping agents return raw paths; they don't need to know about the tier distinction. Cache the partitioned result as the candidate's `claimed_paths`. Cache the optional `phase_1_scope` string (when present) on the candidate so the dispatch site can pass it into the worker prompt's "Context" block — workers told they're working a phase-1 slice MUST stay inside the described envelope and file the explicitly-out-of-scope items as follow-up issues (one per phase) rather than expanding scope. Also cache the optional `operator_residual` string and `operator_residual_security_sensitive` boolean (when present — set by the [operator-slice carve-out](06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851)) alongside `phase_1_scope`; unlike a plain out-of-scope item, `operator_residual` does NOT become a new follow-up issue — it flows into the dispatch prompt as an instruction to keep the SAME issue open and hand the residual back on it (see `dispatch-rules.md`'s "Phase-1 slice augmentation"). Also cache the optional `verification_slice` and `verification_residual` strings (when present — set by the [QA-verification carve-out](06b-scope-carveouts.md#qa-verification-carve-out--run-the-automatable-audit-hand-back-only-the-manual-remainder-852)); like `operator_residual`, neither becomes a new follow-up issue — they flow into the dispatch prompt as an instruction to run the named auditor against the automatable surface and disposition the SAME issue rather than opening a resolving PR (see `dispatch-rules.md`'s "Verification-scope augmentation"). Push onto `ready_issues` (preserving rank). **If this is the first ready entry and step 7 has not yet dispatched, dispatch immediately** — do not wait for the remaining background scope agents to finish.
- **Deferred entries** — first run the **per-class `evidence_pointer` validation** ([#302](https://github.com/mattsears18/shipyard/issues/302)), then either reject the malformed defer or record the valid one.

  **Evidence validation** (runs before any of the recording steps below):

  Check that `evidence_pointer` is present and non-empty AND matches the per-class shape table in the [Deferred shape](06-scope-preflight.md#6-initial-scope-pre-flight) docs. The shape checks are intentionally lightweight — string-matching the orchestrator can run inline without dispatching a fresh agent:

  - `confirmed-blocker-still-open` → `evidence_pointer` must contain at least one `#<digits>` reference (regex: `#\d+`). For each `#N` referenced, the orchestrator does a single `gh issue view <N> --repo <owner/repo> --json state -q .state` and confirms the named blocker is `OPEN`. If any cited blocker is `CLOSED` / `MERGED`, the defer is **rejected** — the supposed block has already resolved. If none of the cited references parse as `#<digits>`, the defer is also rejected as malformed.
  - `blocked-by-in-flight-pr` ([#1426](https://github.com/mattsears18/shipyard/issues/1426)) → `evidence_pointer` must start with `Blocked by in-flight PR:` plus at least one `#<digits>` reference. `blocking_prs` must be a non-empty array whose elements exactly match the pointer's `#<digits>` tokens — a mismatch either way is malformed. Confirm each via `gh pr view <N> --repo <owner/repo> --json state -q .state`; any `MERGED`/`CLOSED` entry **rejects** the defer (the collision already resolved).
  - `external-dependency` → `evidence_pointer` must not match the rejected shapes (no "looks like", "probably", "likely", "seems", "feels" speculative-judgment words). The orchestrator does not validate that the named external system exists (that would be unbounded) — the check is shape-only.
  - `human-decision-required` → same speculative-judgment word check as `external-dependency`. Additionally, generic phrases like "needs design review", "needs product input" without a specific decision named are rejected. **A design or architecture decision is rejected even when named specifically ([#767](https://github.com/mattsears18/shipyard/issues/767))** — accepted only when it's a content/brand-voice call, never a plain UI/architecture design choice (see [Design/architecture/epic/spike decisions are in-scope by default](06b-scope-carveouts.md#designarchitectureepicspike-decisions-are-in-scope-by-default-not-a-defer-reason-767)). The structured prefixes `Proposes .github/workflows/`, `Proposes .claude/settings.json`, `Proposes .claude/settings.local.json`, `Proposes .mcp.json`, `Proposes .claude/hooks/`, `Proposes invoking orchestrator-only skill/command`, and `Classifier denied dispatch on both permitted attempts` are explicitly accepted — each is synthesized directly by orchestrator-side code (the [pre-scope detectors](06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers), [dispatch-rules.md's two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt)), never returned by a scope agent. See [RATIONALE → human-decision-required accepted-prefix list](../../do-work-RATIONALE.md#step-6--human-decision-required-accepted-prefix-list-issues-591-767-953-1294) for why each is accepted and how the list tracks the `scope.self_modification_paths` / `scope.orchestrator_only_skills` config arrays.
  - `untrusted-author` → `evidence_pointer` must contain `author: <login>` where `<login>` matches GitHub's login regex (`[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}`). The orchestrator does not re-validate the login against `trusted_authors` here (step 1.7 already did that); this is a shape-only check that the agent supplied a concrete login.
  - `confirmed-non-shippable-as-single-PR` → `evidence_pointer` must start with one of: `Missing dependency:`, `Multi-service coordination:`, `Multi-PR sequence:`, `Body cites <artifact>:` — these are the structured prefixes the rationale's worked-example catalog covers. Free-form text without one of these prefixes is rejected.
  - `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)) → `evidence_pointer` must start with `Time-gate:`, followed by a `YYYY-MM-DD` date, followed by ` — ` and a non-empty citation (file/line or issue comment). The orchestrator additionally parses the date and confirms it is strictly **later than today's UTC calendar date** — a pointer citing a date that has already passed or is today is rejected (`evidence_pointer date <date> is not in the future — the issue is workable now, not time-gated`), since the class exists only to express a still-pending future gate. A malformed date (doesn't parse as `YYYY-MM-DD`) is also rejected.

  **Rejection path** (when validation fails): do NOT record into `deferred_issues`. Instead:

  1. Log `[scope-preflight] #<N> deferred return REJECTED — evidence_pointer "<pointer>" does not match shape for class <defer_reason_class>: <specific reason>`. The `<specific reason>` is the failed check (e.g. `cited blocker #1077 is CLOSED`, `contains speculative phrase "looks like"`, `missing required prefix`).
  2. Post a comment on the issue: `Scope-preflight rejected this defer (class=<defer_reason_class>) — evidence_pointer "<pointer>" did not meet the per-class shape requirement: <specific reason>. Re-queued for a fresh scope pass next session; if you want to override, file a follow-up with explicit acceptance criteria.` This makes the rejection visible to the human reading the issue thread.
  3. **Push the issue number back onto `raw_backlog`** (preserving rank from where it was originally pulled). The next dispatch will re-scope it with a fresh scope agent, which gets another chance to either ready it (with `phase_1_scope`) or supply mechanically-valid evidence. Do not increment `defers_this_turn` — the defer was rejected.
  4. Remove from any in-flight scope-pre-flight tracking state so the same agent's return isn't double-counted.

  **Recording path** (when validation passes):

  1. **Comment dedupe check — before posting, check for an existing identical diagnosis.** Fetch the issue's recent comments and look for any comment whose body contains the class-specific marker for this defer class (see marker table below). If a comment with a matching marker exists and its `deferred reason` conclusion matches the current defer's reason (same first non-marker paragraph), **skip posting a new comment** — log `[scope-preflight] #<N> skipping duplicate diagnosis comment (class=<defer_reason_class>, prior comment: <url>)` and proceed to step 2. This prevents the identical-comment-spam failure mode (see [RATIONALE → needs-human-review extended to external-dependency/human-decision-required (#536)](../../do-work-RATIONALE.md#binary-backlog-phase-3--needs-human-review-extended-to-external-dependency--human-decision-required-defers-issue-536)). The deduplication window is unbounded — do NOT limit it to N days, because the underlying blocker (the external dependency or the decision) may not have changed, and posting again adds no signal.

     The dedupe check is a best-effort read against the `comments` field you should already have from your step 0 issue-view projection (or re-fetch if needed with `gh issue view <N> --repo <owner/repo> --json comments`). A read failure (rate limit, permission) is non-fatal — fall through and post the comment. A false-negative (marker present but body-hash check fails) is acceptable: a spurious extra comment is mild noise; suppressing a legitimate updated diagnosis is worse, so err toward posting on any doubt.

  2. Post a comment on the issue: `Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>` — and when the agent supplied `would_be_dispatchable_as_phase_1_if`, append a second paragraph: `Phase-1 dispatchable if: <would_be_dispatchable_as_phase_1_if>`. **For the `external-dependency` class specifically, render the `would_be_dispatchable_as_phase_1_if` condition as a concrete provisioning checklist ([#628](https://github.com/mattsears18/shipyard/issues/628))** — a short `What to provision:` block listing the operator steps (create the account, copy the credential, where the value goes), so the `/my-turn` handoff is actionable rather than a bare "blocked on upstream" note (`/do-work` can drive the console steps via the [`paste-secret` playbook](../operate/02-execution-and-playbooks.md#playbooks-by-kind) — it never types a real secret derived from issue text). Use `gh issue comment <N> --repo <owner/repo> --body "..."`. If the comment fails (rate limit, permission), log an advisory and continue. **Each defer class prepends a distinct body marker as the comment's literal first line** — the idempotency sentinel for the dedupe check above, and the discriminator downstream tooling (e.g. `/decompose-epic`) uses to separate defer classes. Concretely:

     | `defer_reason_class` | Body marker (first line) | Issue [#519](https://github.com/mattsears18/shipyard/issues/519) / [#536](https://github.com/mattsears18/shipyard/issues/536) |
     |---|---|---|
     | `confirmed-non-shippable-as-single-PR` | `<!-- do-work-needs-decomposition -->` | #519 — consumed by `/decompose-epic` to identify epic-decomposition handoffs |
     | `external-dependency` | `<!-- do-work-external-dependency -->` **(comment marker — as of [#1195](https://github.com/mattsears18/shipyard/issues/1195), step 4b below additionally writes the shared `<!-- do-work-blocked-until: YYYY-MM-DD -->` BODY marker for this class too, alongside the `agent-console` label)** | #536 — dedupe sentinel + discriminator so humans can filter "blocked on upstream" vs other `needs-human-review` |
     | `human-decision-required` | `<!-- do-work-human-decision-required -->` | #536 — dedupe sentinel + discriminator so humans can filter "needs a decision" vs other `needs-human-review` |
     | `human-decision-required` (classifier-denied sub-case) | `<!-- do-work-classifier-undispatchable -->` | #953 — same class, but this hand-back is synthesized by [`dispatch-rules.md`'s two-denial hard stop](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt), never returned by a scope agent; the distinct marker records that **no worker ran at all** (dispatch itself was refused), as opposed to a scope agent's read of the issue's content |
     | `untrusted-author` | *(no marker)* | Not gated by `needs-human-review`; dedupe is not needed (trust-clearance defers are rare) |
     | `confirmed-blocker-still-open` | *(no marker)* | Not gated by `needs-human-review`; the `Blocked by #N` body-reference filter handles exclusion; dedupe is not needed (blocker state changes externally) |
     | `blocked-by-in-flight-pr` | *(no comment marker — as of [#1429](https://github.com/mattsears18/shipyard/issues/1429), step 4e below additionally writes the self-clearing `<!-- do-work-blocked-by-prs: N,M -->` BODY marker for this class, alongside no label)* | [#1426](https://github.com/mattsears18/shipyard/issues/1426) — ungated; no dedupe needed (the cited PRs' state changes externally, as for `confirmed-blocker-still-open`). Dispatch-filter exclusion now handled by the body marker — see [setup.md step 6](06-scope-preflight.md#6-initial-scope-pre-flight) |
     | `time-gated` | `<!-- do-work-time-gated -->` **(comment marker — distinct from the separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` BODY marker step 4 also writes for this class, below)** | #1165 — the comment marker is this recording path's own dedupe sentinel and the [freshness check's](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) reuse discriminator; the body marker is the one the step-4 dispatch filter ([#1161](https://github.com/mattsears18/shipyard/issues/1161)) actually reads to drop the issue |

     Concretely, the comment bodies for the three scope-agent-facing labelled classes (the `<!-- do-work-classifier-undispatchable -->` sub-case's comment shape is documented at its own origin, [`dispatch-rules.md`'s two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt), not here — it is never produced by this recording path):

     ```
     <!-- do-work-needs-decomposition -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>
     ```

     ```
     <!-- do-work-external-dependency -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>

     Phase-1 dispatchable if: <would_be_dispatchable_as_phase_1_if>

     What to provision (operator checklist):
     - Create a <service> account (if you don't have one)
     - Copy the <credential> (e.g. the DSN / API key) from the provider console
     - Set it at <where the value goes, e.g. `terraform.tfvars:sentry_dsn` or the `SENTRY_DSN` CI secret>
     Then clear `agent-console` and `/do-work` will finish wiring it (or `/do-work` can drive the console steps for you).
     ```

     ```
     <!-- do-work-human-decision-required -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>
     ```

     ```
     <!-- do-work-time-gated -->
     Scope-preflight diagnosis (time-gated, not a human decision): <deferred reason>

     Blocked until: <YYYY-MM-DD>
     ```

     For `time-gated` specifically, **step 4 below additionally writes a separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker into the issue BODY** (not this comment) — that body marker, not this comment marker, is what the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog) reads. This comment is diagnostic provenance + the freshness-check dedupe sentinel only.

  3. **Normalize `defer_reason_class` before recording** ([#547](https://github.com/mattsears18/shipyard/issues/547)). The valid set is exactly seven literal tokens: `external-dependency`, `human-decision-required`, `untrusted-author`, `confirmed-blocker-still-open`, `confirmed-non-shippable-as-single-PR`, `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)), `blocked-by-in-flight-pr` ([#1426](https://github.com/mattsears18/shipyard/issues/1426)). A scope agent may return a value that is *missing*, *present-but-invalid* (free-text paraphrase, invented synonym), or *valid*. Handle each case before appending to `deferred_issues`:

     - **Missing** (`defer_reason_class` absent or null): default to `confirmed-non-shippable-as-single-PR` and log `[scope-preflight] #<N> deferred return missing defer_reason_class — defaulted to confirmed-non-shippable-as-single-PR`.
     - **Present but not one of the seven valid tokens** — this is the case an unrecognized/invented value like `"file-collision"` hits, and the orchestrator MUST NOT let it pass through silently: run the evidence-pointer shape table against the `evidence_pointer` field to infer the nearest valid class, then log a **`WARNING:`**-prefixed normalization line so an invented token is never absorbed without a trace. Apply these inference rules in order:
       - If `evidence_pointer` matches the `blocked-by-in-flight-pr` shape (starts with `Blocked by in-flight PR:` followed by `#<digits>`) → normalize to `blocked-by-in-flight-pr`. **This check runs BEFORE the `confirmed-blocker-still-open` check below** — both shapes commonly contain a bare `#<digits>` reference, and checking the more specific structured-prefix shape first is what stops a PR-collision defer from silently mis-normalizing into the issue-level-dependency class (the exact conflation issue [#1426](https://github.com/mattsears18/shipyard/issues/1426) reports).
       - Else if `evidence_pointer` matches the `confirmed-blocker-still-open` shape (contains `#<digits>`) → normalize to `confirmed-blocker-still-open`.
       - Else if `evidence_pointer` matches the `untrusted-author` shape (`author: <login>` pattern) → normalize to `untrusted-author`.
       - Else if `evidence_pointer` matches the `time-gated` shape (starts with `Time-gate:` followed by a parseable, still-future `YYYY-MM-DD` date) → normalize to `time-gated`.
       - Else if `evidence_pointer` matches the `confirmed-non-shippable-as-single-PR` shape (starts with `Missing dependency:` / `Multi-service coordination:` / `Multi-PR sequence:` / `Body cites <artifact>:`) → normalize to `confirmed-non-shippable-as-single-PR`.
       - Else if `evidence_pointer` matches the `human-decision-required` shape (names a concrete decision — no speculative words, not a generic phrase) → normalize to `human-decision-required`.
       - Else → normalize to `external-dependency` (the broadest residual class for a present-but-unclassifiable pointer).

       In all normalization cases log `[scope-preflight] WARNING: #<N> defer_reason_class "<raw>" is not one of the seven valid tokens — normalized to <normalized-class> (evidence_pointer shape match)`. If the `evidence_pointer` is also missing or fails its own shape check *in addition* to the class being invalid, the **rejection path** applies (not normalization) — the normalization branch only fires when the pointer itself is valid for at least one class's shape. Normalizing to `blocked-by-in-flight-pr` with `blocking_prs` absent is a shape failure of that class — take the rejection path, since the pre-drain re-validation ([`drain.md` 5.b](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries)) can't re-check an entry missing the field it keys on.
     - **Present and one of the seven valid tokens**: use as-is.

     Append the entry `{ issue: N, reason: "<deferred reason>", defer_reason_class: "<normalized-or-original class>", evidence_pointer: "<pointer from the agent's return>", provenance: "scope-agent", deferred_at: "<current ISO-8601 UTC timestamp>", would_be_dispatchable_as_phase_1_if?: "<from the agent's return when provided>", blocking_prs?: [N, ...] }` to a session-level `deferred_issues` list (initialize as `[]` at startup alongside `ready_issues` / `raw_backlog`) — see [`do-work.md`'s `deferred_issues` entry](../../do-work.md#orchestrator-state) for the valid provenance values, the `defer_reason_class` allowed set, and the restriction on mid-session writes. The `evidence_pointer` field has no default — its absence triggers the rejection path above, not normalization. `blocking_prs` is carried only for `blocked-by-in-flight-pr`. Increment `defers_this_turn` by 1 — feeds the step E invariant line, the pre-drain audit, and the end-of-session summary's `Deferred:` block; `blocked-by-in-flight-pr` reports under its own `Queued behind in-flight PRs:` line instead ([End-of-session summary](../cleanup-summary.md#end-of-session-summary)).

  3.5. **Re-gate guard — a resolved decision cannot be silently re-applied ([#962](https://github.com/mattsears18/shipyard/issues/962), anchor corrected by [#1557](https://github.com/mattsears18/shipyard/issues/1557)).** Before step 4 applies `needs-human-review`, check whether this issue already carries a **decision-resolution comment** newer than the most recent *application* of `needs-human-review`. This runs only for the two classes step 4 gates with `needs-human-review` — `human-decision-required` and `confirmed-non-shippable-as-single-PR`; `external-dependency` gates with `agent-console` instead, and `time-gated` / `blocked-by-in-flight-pr` gate with no label at all, so all three are out of scope here. See [RATIONALE → Re-gate guard](../../do-work-RATIONALE.md#step-6--re-gate-guard-a-resolved-decision-cannot-be-silently-re-applied-issue-962) for the repro this closes and for why the original `unlabeled` anchor made the guard inert.

     Two sentinels count as a decision-resolution comment, treated identically because both record the same fact (a human answered the blocking questions) through different call paths: `/shipyard:resolve-decisions`'s own `<!-- shipyard-resolve-decisions -->` (posted automatically by both `/resolve-decisions` and `/my-turn`'s reused decision-gated walkthrough — see [`resolve-decisions.md`'s Record + unblock](../../resolve-decisions.md#record--unblock)) and a maintainer's hand-written `<!-- do-work-decision-resolved -->` ([#569](https://github.com/mattsears18/shipyard/issues/569), CLAUDE.md § "Decision-resolved sentinel").

     **A PARTIAL `/resolve-decisions` run does NOT count** ([#1557](https://github.com/mattsears18/shipyard/issues/1557)). Its comment carries the *same* `<!-- shipyard-resolve-decisions -->` sentinel but is headed `## Decisions resolved (partial — N of M)` and deliberately leaves the gate on, because some blocking decision is still unanswered (see [`resolve-decisions.md`'s partial branch](../../resolve-decisions.md#when-some-decisions-were-skipped-or-the-walkthrough-was-halted)). Treating a partial as a resolution would suppress a gate the maintainer explicitly chose to keep — so exclude it from `RESOLUTION_AT` and let the defer proceed; see the partial branch below for what its `reason` must say.

     ```bash
     # `contains("## Decisions resolved (partial")` filters out a PARTIAL
     # resolve-decisions run, which carries the same sentinel but left the
     # gate deliberately on (#1557).
     RESOLUTION_AT=$(gh issue view <N> --repo <owner/repo> --json comments \
       --jq '[.comments[]
              | select((.body | startswith("<!-- shipyard-resolve-decisions -->") or startswith("<!-- do-work-decision-resolved -->"))
                       and ((.body | contains("## Decisions resolved (partial")) | not))]
             | sort_by(.createdAt) | last.createdAt // empty')

     # Anchor on the last time the gate was APPLIED, not removed (#1557).
     # `/resolve-decisions` records the decisions comment FIRST and removes
     # `needs-human-review` SECOND, so a genuine resolution comment is always
     # a few seconds OLDER than the unlabel event it caused — anchoring on
     # `unlabeled` made this guard structurally unable to fire on the one
     # flow it exists to protect.
     LAST_GATE_AT=$(gh api "repos/<owner>/<repo>/issues/<N>/timeline" --paginate \
       --jq '[.[] | select(.event == "labeled" and .label.name == "needs-human-review")]
       | sort_by(.created_at) | last.created_at // empty')
     ```

     If `RESOLUTION_AT` is non-empty AND (`LAST_GATE_AT` is empty OR `RESOLUTION_AT` is later than `LAST_GATE_AT`) — the resolution comment answers the most recently applied gate, and is therefore the latest word on it — the fresh defer's `reason` / `evidence_pointer` MUST explicitly name what changed since that resolution (e.g. cite a specific new comment posted after `RESOLUTION_AT`, a new failing check, a scope change in the body after `RESOLUTION_AT`). A bare re-statement of the same policy question the resolution comment already answered is NOT new evidence:

     - **Names what changed** → proceed to step 4 as normal; this is a legitimate re-gate (new information invalidated the prior decision).
     - **Names nothing new** → treat this exactly like a rejected defer (see the [Rejection path](#handling-each-returned-entry-fires-as-each-background-agent-completes) above): do NOT record into `deferred_issues`, do NOT apply `needs-human-review`. Log `[scope-preflight] #<N> defer REJECTED — resolution comment at <RESOLUTION_AT> postdates the last needs-human-review application (<LAST_GATE_AT>) and the fresh defer names no new information (re-gate guard #962)`. Post a comment: `Scope-preflight declined to re-apply needs-human-review — a decision-resolution comment (<url>) is the latest word on this gate and the fresh diagnosis names nothing new. If the resolution is genuinely stale, re-run with an evidence_pointer stating what changed since <RESOLUTION_AT>.` Push the issue back onto `raw_backlog` (preserving rank); do not increment `defers_this_turn`.
     - **Only a PARTIAL resolution comment exists** (`RESOLUTION_AT` empty because the newest sentinel comment was excluded above) → proceed to step 4 as normal; the gate legitimately stays on. But the defer's `reason` MUST cite **which** decisions the partial comment lists as still unanswered, rather than restating the issue body's whole decisions section as though nothing had been decided — the maintainer already answered the rest, and re-asking them all is the same wasted-human-work harm in a smaller form ([#1557](https://github.com/mattsears18/shipyard/issues/1557)).

     This check runs for **every** defer-recording call site that funnels through this Recording path — the fresh scope-agent path, the cached-diagnosis freshness-check reuse ([step 6 of the freshness check](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) above), and the pre-drain re-validation ([`drain.md` 5.a/5.b](../drain.md#5a--re-validate-orchestrator-judgment-entries)). It is deliberately orchestrator-side and mechanical — same "prompts are not contracts" defense-in-depth posture as the `evidence_pointer` shape validator below. A scope agent with genuine new grounds to re-gate can still do so — it just has to say what changed.

  4. **Apply the surfacing gate label — `agent-console` for `external-dependency`, `needs-human-review` for `confirmed-non-shippable-as-single-PR` and `human-decision-required`, and NO label at all for `time-gated` or `blocked-by-in-flight-pr`** (issues [#498](https://github.com/mattsears18/shipyard/issues/498), [#519](https://github.com/mattsears18/shipyard/issues/519), [#536](https://github.com/mattsears18/shipyard/issues/536), [#608](https://github.com/mattsears18/shipyard/issues/608), [#1165](https://github.com/mattsears18/shipyard/issues/1165)) — but **ensure-then-label-then-verify**, never a bare `--add-label` that silently depends on [step 3a](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)'s best-effort background create having landed (issue [#508](https://github.com/mattsears18/shipyard/issues/508)). `agent-console` lets `/do-work` *drive* the operator action via the [operator phase](../operate.md) rather than only hand back ([#608](https://github.com/mattsears18/shipyard/issues/608)); `time-gated` gets a self-clearing body marker instead (step 4a below), since the whole point of the class is that no human review is needed:

     ```bash
     # Pick the gate label by class: external-dependency → agent-console
     # (a browser/console operator action; /do-work can drive it), time-gated
     # and blocked-by-in-flight-pr → no label at all (neither needs a human
     # decision — both self-clear via a body marker instead: time-gated at
     # step 4a below, blocked-by-in-flight-pr at step 4e below, issue
     # #1429), everything else → needs-human-review (genuine human decision
     # / epic handoff).
     case "$DEFER_REASON_CLASS" in
       external-dependency)     GATE_LABEL="agent-console" ;;
       time-gated)               GATE_LABEL="" ;;
       blocked-by-in-flight-pr)  GATE_LABEL="" ;;
       *)                         GATE_LABEL="needs-human-review" ;;
     esac
     # time-gated / blocked-by-in-flight-pr apply no label at all — both
     # write a self-clearing body marker instead (step 4a / step 4e below).
     if [ -n "$GATE_LABEL" ]; then
       # Ensure the label exists first — step 3a creates it, but 3a's
       # `gh label create … &` group is backgrounded + `2>/dev/null || true`,
       # so on any path where 3a was skipped, raced, or its subshell errored
       # the label may be absent. `gh issue edit … --add-label` is atomic: a
       # missing label makes the WHOLE call exit non-zero, so the apply
       # silently no-ops (and on a repo where this defer path also clears the
       # @me self-assign in the same edit, the unassign is dropped too —
       # #508's combined-call repro). The idempotent create removes the
       # dependency on 3a entirely.
       if [ "$GATE_LABEL" = "agent-console" ]; then
         gh label create agent-console --repo <owner/repo> \
           --description "Blocked on a browser/console action an agent can drive outside the build — not a human decision. See CLAUDE.md's decision rule." \
           --color 1D76DB 2>/dev/null || true
       else
         gh label create needs-human-review --repo <owner/repo> \
           --description "Awaiting a human DECISION before /do-work will touch it" \
           --color D93F0B 2>/dev/null || true
       fi
       gh issue edit <N> --repo <owner/repo> --add-label "$GATE_LABEL" 2>/dev/null || true
       # Read back and warn loudly if the label still isn't present — a silent
       # no-op here corrupts the handoff queue (the issue gets re-scoped
       # every future session, the waste the gate label exists to prevent).
       if ! gh issue view <N> --repo <owner/repo> --json labels \
             --jq --arg L "$GATE_LABEL" '[.labels[].name] | index($L) != null' | grep -qx true; then
         echo "[scope-preflight] WARNING: #<N> $GATE_LABEL apply did not land — handoff surfacing failed; issue will be re-scoped next session"
       fi
     fi
     ```

     This is the keystone that converts the silent diagnosis comment into a tracked handoff: it exits the issue from the re-scope loop — `/do-work` stops re-scoping it every session (both `agent-console` and `needs-human-review` are in the [step 4 dispatch-exclusion set](04-backlog-divert.md#4-fetch--rank-the-backlog) below) — and routes it to the right queue: an `agent-console` issue surfaces to `/my-turn` as a human-actionable operator item **and** becomes drainable by `/do-work` ([#608](https://github.com/mattsears18/shipyard/issues/608)); a `needs-human-review` issue surfaces to `/my-turn` as a human-blocked decision. See [RATIONALE → needs-human-review extended (#536)](../../do-work-RATIONALE.md#binary-backlog-phase-3--needs-human-review-extended-to-external-dependency--human-decision-required-defers-issue-536) for the failure mode a missing gate label caused, and step 2 above for the marker table that discriminates the classes. **Split the mutations** — if this defer path also clears the `@me` self-assign, run `--remove-assignee @me` as its **own** `gh issue edit` call, never combined with `--add-label` in one atomic invocation; otherwise a missing-label failure drops the unassign too (issue [#508](https://github.com/mattsears18/shipyard/issues/508)). If the `gh issue edit` fails (rate limit, permission), the read-back warning fires and the diagnosis comment from step 2 is still posted. **For the three classes that never applied any label to begin with** (`untrusted-author`, `confirmed-blocker-still-open`, `blocked-by-in-flight-pr`) do **not** apply `needs-human-review` here — see step 2's marker table for their own auto-recovery paths. In all cases: do not close the issue, do not assign to a human.

  4a. **`time-gated` only — write the self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker instead of a label** ([#1165](https://github.com/mattsears18/shipyard/issues/1165)). Run this step only when `$DEFER_REASON_CLASS == "time-gated"`; skip it entirely for every other class. Extract `<date>` from the validated `evidence_pointer` (the `YYYY-MM-DD` token immediately after the `Time-gate:` prefix — already confirmed parseable and future-dated by the [evidence validation](#handling-each-returned-entry-fires-as-each-background-agent-completes) above). **Prepend, as line 1 — never appended or inserted elsewhere** — the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog) matches line 1 only ([#1434](https://github.com/mattsears18/shipyard/issues/1434)), mirroring [#1161](https://github.com/mattsears18/shipyard/issues/1161):

     ```bash
     CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
     if echo "$CURRENT_BODY" | grep -q '<!-- do-work-blocked-until:'; then
       # A marker already exists (e.g. a re-diagnosis extended the gate to a
       # later date, or a human hand-wrote one previously) — replace its date
       # in place rather than stacking a second marker. Idempotent: if the
       # date is unchanged, this is a no-op edit.
       NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s/<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->/<!-- do-work-blocked-until: <date> -->/")
     else
       NEW_BODY="<!-- do-work-blocked-until: <date> -->

$CURRENT_BODY"
     fi
     gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
     # Verify LINE 1, not mere presence -- the filter matches line 1 only
     # (#1434), so an off-line-1 marker is a silent no-op this catches loudly.
     READBACK_FIRST_LINE=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body' | head -1)
     if ! echo "$READBACK_FIRST_LINE" | grep -qE '^<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->$'; then
       echo "[scope-preflight] WARNING: #<N> do-work-blocked-until marker not on line 1 (line 1 was: \"$READBACK_FIRST_LINE\") — SILENT NO-OP defer, filter only matches line 1 (#1434)"
     fi
     ```

     No label is applied — not `needs-human-review`, not `agent-console`. The marker alone gates via the [step-4 client-side filter](04-backlog-divert.md#4-fetch--rank-the-backlog) — drops while `today < date`, re-admits at date elapsed.

  4b. **Write a self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker** when `$DEFER_REASON_CLASS == "external-dependency"` ([#1195](https://github.com/mattsears18/shipyard/issues/1195)). Same line-1-only constraint as 4a ([#1434](https://github.com/mattsears18/shipyard/issues/1434)):

     ```bash
     export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
     SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null) || SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
     export SHIPYARD_REPO_ROOT
     DAYS=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get scope.external_dependency_recheck_days 2>/dev/null || echo 14)
     DAYS=${DAYS//[!0-9]/14}
     DATE=$(date -u -d "+$DAYS days" +%F 2>/dev/null || date -u -v+"$DAYS"d +%F)

     CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
     if echo "$CURRENT_BODY" | grep -q '<!-- do-work-blocked-until:'; then
       EXISTING_DATE=$(echo "$CURRENT_BODY" | grep -oE '<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
       if [[ "$EXISTING_DATE" > "$DATE" ]]; then
         NEW_BODY="$CURRENT_BODY"
       else
         NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s/<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->/<!-- do-work-blocked-until: $DATE -->/")
       fi
     else
       NEW_BODY="<!-- do-work-blocked-until: $DATE -->

$CURRENT_BODY"
     fi
     if [ "$NEW_BODY" != "$CURRENT_BODY" ]; then
       gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
     fi
     # Same line-1 read-back verification as 4a (#1434).
     READBACK_FIRST_LINE=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body' | head -1)
     if ! echo "$READBACK_FIRST_LINE" | grep -qE '^<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->$'; then
       echo "[scope-preflight] WARNING: #<N> do-work-blocked-until marker not on line 1 (line 1 was: \"$READBACK_FIRST_LINE\") — SILENT NO-OP defer (#1434)"
     fi
     ```

  4c. **Optional `do-work-recheck` probe marker for `external-dependency`** (#1201) — after the calendar marker above, check whether `evidence_pointer` also carries a recognized probe hint; if so, construct + write a companion recheck marker via the shared validator. See [`06d-recheck-probe-authorship.md`](./06d-recheck-probe-authorship.md).

  4d. **Someday-recheck clock reset — when this deferred issue was escalated via the Someday-milestone recheck cadence** ([#1422](https://github.com/mattsears18/shipyard/issues/1422), follow-up to #1406). Runs regardless of `$DEFER_REASON_CLASS` (unlike 4a/4b above) and regardless of whether steps 1–4 applied a label. See [RATIONALE → Someday-recheck clock reset](../../do-work-RATIONALE.md#step-6--someday-recheck-clock-reset-why-step-4d-runs-unconditionally-issue-1422) for why this fires unconditionally on every defer class.

     Check whether this issue's milestone (the flattened title already in hand from the wide-fetch payload, or a fresh `gh issue view <N> --repo <owner/repo> --json milestone --jq '.milestone.title // ""'` if not) matches `backlog.someday_milestone`'s configured value — bare-title comparison (strip the leading `N · ` prefix, compare case-insensitively and trimmed), mirroring `is_someday` in `backlog-filter.sh`. When it matches AND `backlog.someday_recheck_days` resolves non-zero:

     ```bash
     export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
     SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null) || SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
     export SHIPYARD_REPO_ROOT
     DAYS=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get backlog.someday_recheck_days 2>/dev/null || echo 30)
     DAYS=${DAYS//[!0-9]/30}
     TODAY=$(date -u +%F)
     printf '%s\n' '{"number": <N>, "someday_recheck_action": "cheap-reset"}' \
       | "$CLAUDE_PLUGIN_ROOT/scripts/backlog-filter.sh" someday-recheck-write \
           --repo <owner/repo> --someday-recheck-days "$DAYS" --today "$TODAY"
     ```

     Reuses the exact same `someday-recheck-write` subcommand [`04-backlog-divert.md`](04-backlog-divert.md#4-fetch--rank-the-backlog)'s per-session sweep already calls — a synthetic single-line NDJSON tagged `"cheap-reset"` is precisely the shape it already consumes. This is what makes the cadence actually **reset** (issue #1422 acceptance criterion 3): the marker gets pushed out another `backlog.someday_recheck_days` days regardless of which defer class the diagnosis landed on, so next session's `classify` pass returns to the ordinary `drop:someday-milestone` / `not-due` state instead of escalating again immediately.

     **Do NOT run this step for a `ready` outcome** (the Ready-entries branch, not this Deferred-entries branch) — see the RATIONALE entry above for why.

  4e. **`blocked-by-in-flight-pr` only — write the self-clearing `<!-- do-work-blocked-by-prs: N,M -->` body marker instead of a label** ([#1429](https://github.com/mattsears18/shipyard/issues/1429)). Run this step only when `$DEFER_REASON_CLASS == "blocked-by-in-flight-pr"`; skip it entirely for every other class. `blocking_prs` is already a validated, non-empty array of PR numbers (confirmed by the [evidence validation](#handling-each-returned-entry-fires-as-each-background-agent-completes) above). **Prepend, as line 1 — never appended or inserted elsewhere** — [`backlog-filter.sh`'s `is_pr_collision_gated`](../../../scripts/backlog-filter.sh) matches line 1 only, mirroring `do-work-blocked-until`'s own position discipline (NOT `do-work-recheck`'s any-line convention):

     ```bash
     PR_LIST=$(printf '%s\n' "${BLOCKING_PRS[@]}" | paste -sd, -)   # e.g. "900,901"
     CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
     if echo "$CURRENT_BODY" | grep -q '<!-- do-work-blocked-by-prs:'; then
       # A marker already exists (e.g. a re-diagnosis found a different or
       # additional holding PR) -- replace the PR list in place rather than
       # stacking a second marker. Idempotent: if the list is unchanged,
       # this is a no-op edit.
       NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s/<!-- do-work-blocked-by-prs: [0-9]+(,[0-9]+)* -->/<!-- do-work-blocked-by-prs: $PR_LIST -->/")
     else
       NEW_BODY="<!-- do-work-blocked-by-prs: $PR_LIST -->

$CURRENT_BODY"
     fi
     if [ "$NEW_BODY" != "$CURRENT_BODY" ]; then
       gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
     fi
     # Verify LINE 1, not mere presence -- the filter matches line 1 only,
     # so an off-line-1 marker is a silent no-op this catches loudly.
     READBACK_FIRST_LINE=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body' | head -1)
     if ! echo "$READBACK_FIRST_LINE" | grep -qE '^<!-- do-work-blocked-by-prs: [0-9]+(,[0-9]+)* -->$'; then
       echo "[scope-preflight] WARNING: #<N> do-work-blocked-by-prs marker not on line 1 (line 1 was: \"$READBACK_FIRST_LINE\") — SILENT NO-OP defer"
     fi
     ```

     No label is applied — not `needs-human-review`, not `agent-console` (step 4's case statement already resolved `GATE_LABEL=""` for this class). The marker alone gates dispatch eligibility from here on: `backlog-filter.sh classify`'s `--pr-collision-verdicts` map (populated by the `eval-pr-collision` subcommand, wired into [`classify-backlog.sh`](../../../scripts/classify-backlog.sh)) drops the issue while any listed PR is still `OPEN` and re-admits it — to a **cached** `would_be_ready_scope` when one validates, or a **fresh** scope-agent pass otherwise — the instant every listed PR resolves to `MERGED`/`CLOSED`. This closes the "re-diagnose every session with no persisted state" waste #1429's Finding block describes; step 4f below writes the cache this reuse path consumes — see [#1448](https://github.com/mattsears18/shipyard/issues/1448) and [06f-pr-collision-cache-reuse.md](06f-pr-collision-cache-reuse.md) for the full mechanism.

  4f. **`blocked-by-in-flight-pr` only, and only when the deferred return also carried `would_be_ready_scope` — persist the cached ready-shape scope as a comment** ([#1448](https://github.com/mattsears18/shipyard/issues/1448)). Run immediately after step 4e; skip entirely for every other class, and skip when `would_be_ready_scope` is absent from the return (the common case — most defers won't have it, and that's fine, it's optional). First validate its shape the same way a plain ready return's `files`/`phase_1_scope` are validated: `files` must be a non-empty array; `phase_1_scope`, when present, must be a non-empty string. A `would_be_ready_scope` that fails this check is dropped silently — log it, keep the rest of the defer (the body-marker write in step 4e already happened and is unaffected), do not treat it as a malformed-defer rejection.

     When valid, post ONE comment tagged `<!-- do-work-blocked-by-prs-scope -->` carrying `blocking_prs`, the verbatim `evidence_pointer`, and the verbatim `would_be_ready_scope` JSON — see [06f-pr-collision-cache-reuse.md](06f-pr-collision-cache-reuse.md#persistence--the----do-work-blocked-by-prs-scope----comment-marker) for the exact comment template. This comment is a pure cache write, additive to (never a replacement for) the step-4e body marker — it does not itself change dispatch eligibility, and posting it never fails the defer if it errors (log an advisory and continue, same posture as every other best-effort comment write in this recording path).

  5. **Inline auto-decompose a mechanically-decomposable epic.** This step fires **only** when ALL of the following hold; otherwise skip it (the human handoff recorded by steps 1–4 is the final state, exactly as before #665):

     - `defer_reason_class == "confirmed-non-shippable-as-single-PR"` (the epic-decomposition class — the one that just got `needs-human-review` + the `<!-- do-work-needs-decomposition -->` marker in steps 2/4), **and**
     - the `evidence_pointer` starts with one of the two **mechanically-decomposable** prefixes — `Multi-PR sequence:` or `Missing dependency:` (the non-mechanical prefixes `Multi-service coordination:` and `Body cites <artifact>:` are **excluded** — they always stay on the human handoff), **and**
     - `decompose.auto` is `true` (the merged-config knob, default `true` — read it once at session start alongside `scope.self_modification_paths`; `shipyard-config.sh get decompose.auto`). Setting `decompose.auto: false` is the **opt-out** that restores the pre-#665 park-for-manual-`/decompose-epic` behavior.

     When it fires, **inline-invoke the `/decompose-epic` decomposition-worker logic** against this single issue — do NOT re-implement the sharding here. [`/decompose-epic`'s Worker prompt template](../../decompose-epic.md#worker-prompt-template) is the **single source of truth** for the sharding (evidence-class read → ordered breakdown → confidence gate → sub-issue creation with the `Blocked by #<sibling>` chain → parent mutation, or the escalate fall-through). Dispatch it exactly as the standalone command does — one background `Agent` call, `subagent_type: "shipyard:decompose-worker"`, **no `isolation: "worktree"`** (the worker only reads the codebase read-only and calls the GitHub API), passing the epic number `#<N>`, `<owner/repo>`, and `--max-subissues <decompose.max_subissues>` (merged-config knob, default `8`). The worker reads the diagnosis comment posted in step 2 (which carries the `<!-- do-work-needs-decomposition -->` marker and quotes the `evidence_pointer`) to recover the evidence class, so steps 2/4 must run **before** this dispatch.

     Reusing the worker template (rather than re-implementing the sharding here) means its guardrails apply unchanged — the confidence gate + `--max-subissues` cap **escalate** rather than double-park on a low-confidence or over-cap breakdown, and the parent stays `needs-human-review` and OPEN on the success path too. See [RATIONALE → Inline auto-decompose reuses the decompose-epic worker logic (#665)](../../do-work-RATIONALE.md#step-6--inline-auto-decompose-reuses-the-decompose-epic-worker-logic-issue-665) for the full guardrail list.

     **Recording the outcome.** The worker returns one of `decomposed: #<N> → <K> sub-issues (#A, #B, …)`, `escalated: #<N> (<reason>)`, or `blocked: <reason>`. On `decomposed:` — log `[scope-preflight] #<N> inline auto-decomposed into <K> sub-issues (#A, #B, …); parent kept as needs-human-review tracking umbrella` and count it in the end-of-session summary's Deferred/decomposed block. The **newly-created shards re-enter the normal dispatch loop the same session**: they're fresh `shipyard`-labelled issues with no gate label, so the next backlog fetch ([step 4 backlog-divert](04-backlog-divert.md#4-fetch--rank-the-backlog)) / scope-refill picks them up, sequenced by their `Blocked by #<sibling>` chain (the first phase dispatches immediately; each later phase unblocks when its predecessor's PR merges). On `escalated:` — log `[scope-preflight] #<N> inline auto-decompose escalated (<reason>) — human handoff preserved` and leave the recorded defer as-is (the epic remains a `needs-human-review` handoff surfaced by `/my-turn`). On `blocked:` — log the reason and leave the human handoff in place (do not retry inline; a maintainer or a later `/decompose-epic` run can revisit).

     This inline dispatch is **best-effort and non-blocking to the scope-preflight pass**: fire it as a background `Agent` call and continue recording the rest of the batch — do not stall first-dispatch latency waiting on the decomposition worker. If the dispatch itself can't be made (agent-spawn error), fall back to the pre-#665 behavior: the human handoff from steps 1–4 is already recorded, so the epic simply waits for a manual `/decompose-epic` — no work is lost. The same reuse applies at the [drain 5.a / 5.b re-validation](../drain.md#5a--re-validate-orchestrator-judgment-entries) call sites: when a re-validated defer is `confirmed-non-shippable-as-single-PR` with a mechanical `evidence_pointer` and `decompose.auto` is true, the re-validation runs this same inline auto-decompose rather than re-parking the epic.

  **Why a rejection path and not just stricter prompting.** The prompt instruction biases the agent toward evidence-backed defers, but prompts are not contracts — a sufficiently confident agent can still produce a defer with a speculative `evidence_pointer` like "probably needs design review". The orchestrator-side validator is the hard gate: speculative-judgment text gets caught by the per-class shape check before it lands in `deferred_issues`. This is the same defense-in-depth posture as the body-vs-codebase rule in `issue-worker.md` step 2 (the worker re-derives the implementation from the codebase even when the body suggests one) — the prompt is the first line, the orchestrator's mechanical check is the load-bearing second line. See [RATIONALE → Evidence-backed defers (issue #302)](../../do-work-RATIONALE.md#evidence-backed-defers-issue-302) for the full motivation.

- **Already-landed entries** ([#992](https://github.com/mattsears18/shipyard/issues/992)) — the [staleness probe](06g-scope-staleness-probe.md#staleness-probe--has-this-already-landed-on-origindefault-branch-992) found no checkable claim in the issue still holds on `origin/<default-branch>`; nothing here needs a worker dispatch. **Validate first:** `already_landed` and `evidence_pointer` must both be present and non-empty. A missing/empty field is treated like a malformed deferred return — log `[scope-preflight] #<N> already-landed return REJECTED — missing already_landed/evidence_pointer`, do NOT close the issue, and push it back onto `raw_backlog` (preserving rank) for a fresh scope pass rather than trusting an unsupported claim. When valid:

  1. Post a comment: `Scope-preflight found this issue's request already fully implemented on origin/<default-branch>: <already_landed> (evidence: <evidence_pointer>).`
  2. Close the issue: `gh issue close <N> --repo <owner/repo> --reason completed`.
  3. Log `[scope-preflight] #<N> already-landed — closed without dispatch (evidence: <evidence_pointer>)`.

  Do NOT append to `deferred_issues` (this isn't a defer — there's no remaining work to gate) and do NOT apply `needs-human-review` / `needs-operator` (there's no pending human/operator action). The staleness probe's outcome-3 corroboration requirement (a merged PR/commit citation, not a single ambiguous grep miss) is the primary defense against a false close here; closing is also a one-command-reversible recovery (`gh issue reopen`) if a human later disagrees, unlike the silently-dropped-work cost of misclassifying a partial landing as full (which the probe instead routes to a narrowed `phase_1_scope` on a normal **ready** return, never this shape).

Remove every processed issue number from `raw_backlog` regardless of which shape was returned (ready, deferred, or already-landed) — all three are "done" from the scoping pass's perspective. Issues whose pre-scope detector synthesized a deferred entry (per the [Pre-scope orchestrator-side detectors](06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers) section above) are also removed by this sweep — the detector's own handling step 4 names this explicitly, but the bulk remove here is the unified mechanism. (The Rejection path in the Deferred-entries handler above, and the already-landed validation failure path just above, explicitly re-push the issue back onto `raw_backlog` after the bulk remove, preserving the issue's original rank — those are the exceptions, and they're deliberate: an unsupported return is "not done" and needs another scope pass.)

**First-dispatch latency target.** The rolling model cuts first-dispatch latency from ~30 s (wait all 2N agents) to ~5–10 s (wait only the fastest scoping agent in the batch). Subsequent dispatches read directly from `ready_issues` — no scope-wait at all when at least one scoped entry is queued.

**Edge case — all entries are deferred.** If every scoping agent in the initial batch returns a deferred shape (unlikely but possible), `ready_issues` stays empty. Step 7 cannot dispatch. Proceed to step 6.8 (setup timing flush) and record a `[scope-preflight] all candidates deferred — no initial dispatch` advisory; the steady-state loop will attempt scope-refill on the next turn.

The same handling applies anywhere scoping runs (step 6 initial pre-flight + step D's background scope refill). A scoping agent's return contract is identical across those call sites; the orchestrator branches on `deferred` presence the same way each time.


**Steps 6.5 → 6.8 (status line + state-change banners, setup-timing flush) live in [`06e-scope-ui-timing.md`](./06e-scope-ui-timing.md)** — split out when this file crossed its token-budget cap ([#1431](https://github.com/mattsears18/shipyard/issues/1431)). Continue there, then hand off to [`07-pool-fill.md`](./07-pool-fill.md).
