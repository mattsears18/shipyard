#!/usr/bin/env bash
# backlog-filter.sh — the executable, single-source-of-truth definition of
# /shipyard:do-work's backlog eligibility filter (issue #1247).
#
# Background
# ----------
# The eligibility filter that decides which open issues /do-work may
# dispatch against was, before this script existed, a six-clause predicate
# expressed as PROSE and re-derived from scratch by an LLM at three
# independent call-sites:
#
#   - commands/do-work/setup/04-backlog-divert.md step 4 (build raw_backlog)
#   - commands/do-work/steady-state.md step C          (mid-session re-check)
#   - commands/do-work/drain.md termination-assertion step 4 (fresh-fetch
#     verification before ending the session)
#
# Three prose copies of the same predicate have already drifted TWICE:
#   - #332 — a shorthand ("drop issues with no assignee") silently erased
#     every self-assigned resumable-work issue.
#   - #1194 — the same class of regression recurred one layer down, in a
#     mid-drain ad-hoc re-derivation.
# A third divergence was found (not yet regressed in production, but
# already committed to the spec text): `needs-triage` was explicitly
# excluded from the drop-label enumeration in setup.md (it was routed to
# investigate_candidates instead) but was listed INSIDE the drop-label
# enumeration in both steady-state.md and drain.md — the exact contradiction
# a hand-rolled second copy cannot help but eventually produce. (That label
# was retired outright in #1120; the divergence it illustrates is why this
# script exists, and the lesson outlives the label.)
#
# This script is the fix: ONE implementation of the classification/routing
# decision, invoked identically at all three call-sites, so they cannot
# disagree. The three .md files now mark their prose descriptions
# non-normative and point here.
#
# Subcommands
# -----------
#
#   classify --me <login> --trusted-authors <csv> [--closed-by-healthy-pr <csv>]
#            [--closed-by-open-pr <json-object>]
#            [--peer-claimed <csv>] [--investigate-dispatch true|false]
#            [--prioritize-label <label>] [--today YYYY-MM-DD]
#            [--respect-assignees true|false]
#            [--milestones-enabled true|false] [--milestones-prioritize-dispatch true|false]
#            [--probe-verdicts <json-object>] [--recheck-probe-enabled true|false]
#            [--pr-collision-verdicts <json-object>]
#            [--sub-issues <json-object>]
#            [--someday-milestone <title>] [--someday-recheck-days <N>]
#            [--fallback-milestone <title>]
#     Reads a JSON array of issues on stdin — the exact projection setup.md
#     step 4's wide fetch produces: [{number, title, body, labels: [name,...],
#     assignees: [login,...], author: {login}, createdAt, updatedAt,
#     milestone: "<N · Title>"|null}, ...]. `milestone` is the issue's
#     milestone TITLE (already flattened from gh's `{number,title,...}`
#     object by the caller's wide-fetch --jq projection, mirroring how
#     `labels`/`assignees` are flattened) or null/absent when unmilestoned.
#     `author`, by contrast, is the ONE field that is deliberately NOT
#     flattened — it stays the object `{login}`. That three-flattened-one-
#     not asymmetry is checked up front (issue #1555): a mis-marshalled
#     payload exits 64 naming the offending field and issue number, rather
#     than escaping as a raw positional jq error. See `validate-issues`.
#     Emits one NDJSON line per issue on stdout:
#       {"number":N,"verdict":"eligible"}
#       {"number":N,"verdict":"route","reason":"investigate"}
#       {"number":N,"verdict":"route","reason":"operator"}
#       {"number":N,"verdict":"drop","reason":"<reason>"}
#       {"number":N,"verdict":"gate","reason":"<label>"}
#       {"number":N,"verdict":"gate","reason":"tracking","evidence_pointer":"<content-sourced citation>"}
#       {"number":N,"verdict":"gate","reason":"tracking-unjustified"}
#       {"number":N,"verdict":"drop","reason":"covered-by-open-pr","evidence_pointer":"PR #M closingIssuesReferences includes #N"}
#       {"number":N,"verdict":"drop","reason":"pr-collision-gated"}
#       {"number":N,"verdict":"drop","reason":"someday-milestone","evidence_pointer":"milestone <title>","someday_recheck_action":"first-park"|"not-due"|"cheap-reset"}
#     The `tracking` shapes are that label's special case (issues #1364 and
#     #1556) — see has_tracking_justification's own comment block below for
#     the full, precedence-ordered signal list. Every OTHER gate label (`blocked:ci`, `wontfix`, `discussion`,
#     `needs-human-review`) always emits the plain
#     `{"verdict":"gate","reason":"<label>"}` shape; among GATE verdicts only
#     `tracking` ever carries `evidence_pointer` or the
#     `tracking-unjustified` reason. The `covered-by-open-pr` and
#     `someday-milestone` DROP verdicts (issues #1389 and #1406) are the
#     other shapes that carry an `evidence_pointer`. The `someday-milestone`
#     DROP additionally carries `someday_recheck_action` whenever
#     `--someday-recheck-days` is non-zero (issue #1422) — the caller's
#     signal for whether to write/refresh the `do-work-someday-recheck` body
#     marker; see `someday-recheck-write` below. When the recheck cadence
#     ELAPSED and something about the issue changed since the marker was
#     written, the issue is NOT a someday-milestone drop at all that pass —
#     it comes back as a plain `{"verdict":"eligible"}` line instead (no
#     `someday_recheck_action` field), for exactly one real scope-agent pass.
#     Output ORDER: every "eligible" line first, in rank order. The default
#     (milestone ranking OFF — either --milestones-enabled or
#     --milestones-prioritize-dispatch is false, matching a repo that never
#     opted into milestones.*) is BYTE-IDENTICAL to the pre-#1241 order:
#     prioritized-label tier, then P0>P1>P2>unlabeled, then
#     bug>fix(*)>feat(*)>chore(*)>other, then oldest-updatedAt-first.
#     When BOTH --milestones-enabled and --milestones-prioritize-dispatch
#     are true, the eligible order becomes (issue #1241 — see
#     do-work-RATIONALE.md for why each tier sits where it does):
#       1. P0 — global, wins in ANY milestone (an emergency escape, not
#          part of the sequencing plan).
#       2. prioritized-label tier — an explicit per-run operator override,
#          now ranked below P0 (this is a behavior CHANGE from the
#          milestone-off order, where the prioritized-label tier is
#          outermost and can rank ABOVE a P0).
#       3. milestone sequence, ascending, parsed from the issue's milestone
#          title's `N · ` numeric prefix — this is "the earliest milestone
#          with dispatchable work," which falls out of the sort for free:
#          a milestone with zero eligible issues simply never appears in
#          this list, so ascending-N naturally skips it. An unmilestoned
#          issue, or one whose milestone title doesn't parse, sorts to the
#          tail rather than being dropped -- and when --fallback-milestone
#          names a milestone that is actually present in this input, it
#          sorts TIED WITH that milestone rather than strictly after it,
#          so tier 4 below (P1>P2>unlabeled) decides between an
#          unmilestoned issue and a fallback-milestoned one (issue #1499).
#       4. P1>P2>unlabeled, then type, then staleness — the same
#          tiebreakers as the milestone-off order, now operating WITHIN a
#          milestone rather than across the whole backlog.
#     Then every "route":"investigate" line, in its own rank order
#     (P0>P1>P2>unlabeled, then staleness — no prioritized-label, type, or
#     milestone tier, per 04d-investigate-routing.md — milestone ranking is
#     scoped to raw_backlog only). Then every remaining line
#     (route:operator, drop:*, gate:*) in input order, as an audit trail.
#     A caller that wants only the ranked eligible numbers does:
#     `jq -r 'select(.verdict=="eligible") | .number'`.
#     `--respect-assignees` (issue #1248) gates the "drop:assigned-other"
#     clause. Default `true` when the flag is omitted entirely (preserves
#     the #1194-fixed predicate for a caller that hasn't been updated yet).
#     Real callers should always pass the resolved `backlog.respect_assignees`
#     config value explicitly (config default: `false` — on a single-
#     contributor repo, the common shipyard-marketplace case, "assigned to
#     someone else" has no correct exclusion to make). When `false`, an
#     issue's `assignees` array never affects its verdict — self-assigned,
#     unassigned, and other-assigned issues are all equally eligible. It is
#     orthogonal to the milestone-ranking flags above: `--respect-assignees`
#     decides which issues reach the eligible bucket at all, the milestone
#     flags decide only how that bucket is ordered.
#     `--closed-by-open-pr` (issue #1389) is a JSON object mapping issue
#     number (as a STRING key, same convention as `--probe-verdicts`) to the
#     number of an OPEN `--me`-authored PR whose `closingIssuesReferences`
#     names that issue — REGARDLESS of that PR's check health or
#     `mergeStateStatus`. Defaults to `{}` when omitted (the clause never
#     fires, byte-identical to pre-#1389 behavior). Produced by the
#     `closed-by-open-pr` subcommand below. This is deliberately a WIDER set
#     than `--closed-by-healthy-pr`, because the two flags answer two
#     different questions and #1389 is the bug that came from conflating
#     them: PR health decides "does this PR belong in `failed_prs`?", which
#     is a question about the PR. Whether an ISSUE is already covered by
#     in-flight work is a question about the issue, and health is irrelevant
#     to it — an issue whose open PR is red is fix-checks work on that PR,
#     not workable issue-work, so dispatching an issue-worker at it can only
#     bail (the #1389 repro burned 3 worker + 3 scope-agent dispatches,
#     ~250k tokens, on five such issues in one session). The
#     `closed/abandoned PR -> issue stays dispatchable` row is untouched:
#     the subcommand queries `--state open` only, so a closed or abandoned
#     PR contributes no entry and #332's resumable-work case is preserved by
#     construction. Evaluated AFTER `--closed-by-healthy-pr` in
#     `classify_one`, so an issue in BOTH sets keeps emitting the older
#     `closed-by-healthy-pr` reason verbatim and only the two genuinely-new
#     rows (open+red, open+DIRTY) emit `covered-by-open-pr`.
#     `--probe-verdicts` (issue #1356) is a JSON object mapping issue number
#     (as a STRING key — `{"123":"changed"}`, not `{123:"changed"}`, since
#     JSON object keys are always strings) to the verdict a prior
#     `eval-probes` pass (below) already computed for that issue's
#     `do-work-recheck` marker: `changed` / `unchanged` / `unknown`. Defaults
#     to `{}` when omitted (every issue falls back to `unknown`, the safe
#     default — see `--recheck-probe-enabled` below for the flag that
#     disables this mechanism at the class level rather than per-issue).
#     Any issue whose body carries a `do-work-recheck` marker (any line, not
#     line-1-restricted — the position discipline only ever applied to
#     `do-work-blocked-until`) is EVENT-GATED rather than TIME-GATED: its
#     eligibility is decided from this map's verdict, not from the calendar
#     date. `changed` -> eligible now, REGARDLESS of whether the paired
#     `do-work-blocked-until` date (if any) is still in the future — the one
#     case that brings admission forward, matching the read-side semantics
#     `eval-recheck-probe.sh`'s own header comment documents.
#     `unchanged`/`unknown`/no-entry-in-map -> `{"verdict":"drop","reason":
#     "event-gated"}`, REGARDLESS of whether the calendar date has already
#     elapsed — this is the fix for the churn loop issue #1356 documents: an
#     event-gated issue never silently re-admits itself into the dispatch
#     pool (and never triggers a fresh scope-agent pass that would invent a
#     new date) just because a placeholder date happened to pass; only an
#     explicit `changed` probe verdict does. A plain calendar-only issue
#     (no `do-work-recheck` marker at all) is completely unaffected — this
#     clause never runs for it, and `time_gate_future`'s line-1-only
#     calendar check is exactly what it was before this issue.
#     `--recheck-probe-enabled` (default `true`, mirrors the
#     `scope.recheck_probe_enabled` config knob) is the class-level kill
#     switch: when `false`, EVERY issue is treated as though it carries no
#     `do-work-recheck` marker at all, regardless of its body or of
#     `--probe-verdicts` — full calendar-only fallback, byte-identical to
#     the pre-#1356 behavior. This is deliberately a caller-supplied flag,
#     not something `classify` reads from config itself, so the pure
#     function stays free of I/O (see the design note near the bottom of
#     this header for why that purity is load-bearing).
#     `--pr-collision-verdicts` (issue #1429) is a JSON object mapping issue
#     number (STRING key, same convention as `--probe-verdicts`) to
#     `"resolved"` or `"open"` — the verdict a prior `eval-pr-collision` pass
#     (below) already computed for that issue's `do-work-blocked-by-prs`
#     marker. Defaults to `{}` (every issue falls back to `"open"`, the safe
#     default — no separate class-level kill switch, since the underlying
#     probe is a fixed `gh pr view --json state` call, not the arbitrary
#     allowlisted-verb grammar `--recheck-probe-enabled` guards). Any issue
#     whose body's FIRST LINE (line-1-only, like `do-work-blocked-until` —
#     NOT the any-line convention `do-work-recheck` uses) carries a
#     `do-work-blocked-by-prs: N,M` marker is PR-COLLISION-GATED: `"resolved"`
#     (every listed PR is now MERGED or CLOSED) admits the issue; `"open"`
#     (at least one listed PR is still OPEN, or the map carries no entry for
#     this issue) drops it with `{"verdict":"drop","reason":
#     "pr-collision-gated"}`. This is the self-clearing companion to a
#     `blocked-by-in-flight-pr` defer (see 06-scope-preflight.md) — it re-
#     admits the issue to a FRESH scope-agent pass the moment every blocking
#     PR resolves, rather than requiring pre-drain re-validation or a human
#     to notice. It does NOT reuse a cached scope from the original defer —
#     that cost-avoidance optimization, and the semantic premise re-
#     validation it would require, is deliberately not wired here; see
#     do-work.md's `deferred_issues` entry for the tracked follow-up.
#     `--sub-issues` (issue #1556) is a JSON object mapping issue number
#     (STRING key, same convention as `--probe-verdicts`) to that issue's
#     GitHub sub-issue nodes — `[{"number":N,"state":"OPEN"|"CLOSED"}, ...]`
#     — as read by a prior `sub-issues` pass (below). Defaults to `{}`, which
#     reproduces pre-#1556 behavior byte-for-byte. Consumed by exactly ONE
#     clause: the `tracking` provisional gate's justification check. A
#     non-empty entry is that gate's strongest (and only STRUCTURED) signal —
#     `tracking` is defined as "parent epic, decomposed into sub-issues", so
#     a populated sub-issue graph is the textbook case the label exists for,
#     and it is invisible to every body-prose signal because the relationship
#     is structured GitHub state rather than text. Before #1556 a correctly
#     decomposed epic therefore surfaced as `tracking-unjustified` — an
#     anomaly channel firing on a healthy epic — while an issue that merely
#     happened to carry an "Options" heading passed clean.
#     `--someday-milestone <title>` (issue #1406) is a THIRD, distinct park
#     mechanism from time-gate/event-gate above — not a leaf of either. An
#     issue whose `milestone` field (the same flattened title the
#     milestone-ranking flags above already read) matches this title —
#     compared case-insensitively, trimmed, against the title with any
#     leading `N · ` sequence-number prefix stripped, so the configured
#     value is just the human-readable name ("Someday"), not the whole
#     "6 · Someday" string that would drift every time
#     `shipyard:update-roadmap` renumbers phases — drops with
#     {"verdict":"drop","reason":"someday-milestone","evidence_pointer":
#     "milestone <title>"}, unconditionally, with NO probe and NO calendar
#     involved. This is deliberately NOT modeled as a leaf of the
#     time-gate/event-gate taxonomy: an event gate's eligibility is decided
#     by a live probe verdict against a `do-work-recheck` marker, and a
#     "Someday" milestone issue is explicitly the case where no such probe
#     is expressible (`eval-recheck-probe.sh`'s allowlist covers `npm-view`,
#     `gh-api`, and -- issue #1496 -- `url-json`, the last of which is
#     additionally inert until the repo allowlists a host in its committed
#     `scope.recheck_probe_url_hosts`) -- bolting a third "always unknown,
#     never probed"
#     state onto `is_event_gated`/`probe_verdict` would only obscure that
#     these are two structurally different admission questions ("has the
#     watched value changed" vs. "has a human moved this out of Someday").
#     Defaults to "" (empty string), which never matches any issue's
#     milestone (a real milestone title is never empty) — the mechanism is
#     off by construction until a caller passes a non-empty title, matching
#     the `backlog.someday_milestone` config knob's own default. Evaluated
#     independently of `--milestones-enabled`/`--milestones-prioritize-
#     dispatch` — those two gate milestone-aware RANKING of the eligible
#     bucket; this gates ELIGIBILITY itself and must keep working on a repo
#     that has not opted into milestone-ranked dispatch at all (the #1406
#     motivating repro has `milestones.enabled: false`). See
#     do-work-RATIONALE.md for the full design writeup.
#     `--someday-recheck-days <N>` (issue #1422, follow-up to #1406) is the
#     slow re-scope cadence, in days, for a someday-milestone-parked issue.
#     Default "0" — disables the cadence entirely, reproducing #1406's
#     original "permanent drop, never look again" behavior byte-for-byte
#     until a caller explicitly passes a non-zero value (the
#     `backlog.someday_recheck_days` config knob's own built-in default is
#     30 — a real caller resolves and passes THAT, this script's own
#     internal default only protects existing callers/fixtures that predate
#     this flag). Non-zero: `someday_recheck_state()` (see CLASSIFY_JQ) is
#     evaluated purely from data already in the wide-fetch payload — no
#     extra I/O, `classify` stays a pure function — and decides one of
#     "first-park"/"not-due"/"cheap-reset"/"escalate" per someday-parked
#     issue; see that function's own doc comment for the full state
#     semantics. Irrelevant (never evaluated) for an issue that doesn't
#     match `--someday-milestone` in the first place.
#     `--fallback-milestone <title>` (issue #1499) is the BARE title of the
#     repo's fallback milestone — the `milestones.fallback` config knob's
#     value ("Ongoing maintenance" by default), matched against
#     `milestone_title_bare()` exactly the way `--someday-milestone` is.
#     Default "" — the clause is off by construction for every caller and
#     fixture that predates this flag, so their ranking is byte-identical.
#     It affects ONLY tier 3 of the milestone-on `_sort_key`, and only for
#     an issue that has NO milestone (or an unparseable one): such an issue
#     ranks at the fallback milestone's own sequence number instead of at
#     the `999999999` sentinel, so the two TIE and `priority_rank` decides
#     between them. Before this, the sentinel was strictly larger than any
#     real N, so a fallback-milestoned P2 outranked an unmilestoned P1 —
#     a wholesale severity override, not a tiebreak, and the exact
#     opposite of what `milestone_seq()`'s own comment claimed ("sorts to
#     the tail ALONGSIDE where the fallback milestone already sorts").
#     The fallback's N is read back from THIS input (the lowest N among
#     issues whose bare milestone title matches), not from a config number
#     — `classify` stays a pure function with no I/O. When no input issue
#     carries the fallback milestone there is nothing to tie with, so the
#     sentinel stands and unmilestoned issues sort last exactly as before.
#     Deliberately honors the configured title even if that milestone is
#     NOT the highest-N one in the input: the schema guarantees the
#     fallback always holds the highest N, and a repo that violates that
#     invariant is better served by "tie with the milestone you named"
#     than by this script silently second-guessing its own config.
#     Exit 0 always (even on an empty input array — emits nothing).
#
#   someday-recheck-write --repo <owner/repo> --someday-recheck-days <N>
#            [--today YYYY-MM-DD]
#     < classify NDJSON (or any NDJSON carrying {number, someday_recheck_action})
#       on stdin
#     The I/O half of the `someday_recheck_state` mechanism above — kept out
#     of `classify` for the same reason `eval-probes`/`closed-by-healthy-pr`
#     are: the pure decision and the live GitHub write are different
#     concerns, and only the write needs network access. For every input
#     line whose `someday_recheck_action` is `"first-park"` or
#     `"cheap-reset"` (any other value, or an absent field, is ignored —
#     `"not-due"` needs no write, `"escalate"` issues are not someday-drops
#     at all that pass), fetches the issue's current body, writes or
#     refreshes a `<!-- do-work-someday-recheck: YYYY-MM-DD -->` marker
#     dated `--today + --someday-recheck-days` days (mirrors the
#     `do-work-blocked-until` writer's own idempotent
#     "sed-replace-if-present, else prepend" shape — see
#     06c-scope-handling-ui.md step 4b), and edits the issue only when the
#     body actually changed. `--someday-recheck-days 0` is a no-op (nothing
#     to write — mirrors `classify`'s own disabled posture). A single
#     synthetic line `{"number":N,"someday_recheck_action":"cheap-reset"}`
#     is also a valid, minimal input — this is how 06c-scope-handling-ui.md
#     step 4d resets the cadence clock for one specific issue after a
#     scope-agent's own defer conclusion lands, without needing a full
#     classify NDJSON on hand. Best-effort: a per-issue `gh` failure logs a
#     WARNING to stderr and continues to the next issue rather than aborting
#     the whole call. Exit 0 always (even on empty/no-matching input); 64
#     bad usage; 65 missing jq.
#
#   sub-issues --repo <owner/repo>
#     < wide-fetch-issue-json (array) on stdin — the same payload `classify`
#     reads (only `number`/`labels` used).
#     Live-queries: for every issue carrying the `tracking` label, reads its
#     GitHub sub-issue graph via a single `gh api graphql` call per issue
#     (issue #1556). Prints a JSON object mapping issue number (STRING key,
#     same convention as `--probe-verdicts`) to that issue's sub-issue
#     nodes:
#       {"4688":[{"number":4698,"state":"CLOSED"},{"number":4701,"state":"OPEN"}]}
#     — ready to pass straight through as `classify --sub-issues`. Issues
#     with no `tracking` label are never queried and contribute no key;
#     neither does an issue whose sub-issue graph is empty, or whose read
#     failed for any reason (the API erroring, `subIssues` being unavailable
#     on this GitHub deployment, a malformed response). A missing key makes
#     `classify` fall through to the body-prose tracking signals — exactly
#     the pre-#1556 behavior — so an inconclusive read can only ever surface
#     the gate as `tracking-unjustified`, never fabricate a justification.
#     Empty object (`{}`), not empty string, when no issue in the input
#     carries the label — so `--sub-issues "$(...)"` composes directly
#     without a caller-side empty-string special case.
#     Cost is near zero on a normal backlog: the `tracking` set is typically
#     tiny, and an input with none in it makes no network call at all.
#     Exit codes: 0 success (even if the set is empty); 64 bad usage; 65 if
#     `gh` or `jq` is missing.
#
#   eval-probes --repo <owner/repo>
#     < wide-fetch-issue-json (array) on stdin — the exact same payload
#     `classify` reads (only `number` and `body` are used).
#     Live-queries: for every issue whose body carries a `do-work-recheck`
#     marker (issue #1356, generalizing #1198's evaluator beyond its single
#     original `external-dependency`-defer, operator-sweep-only caller to
#     ANY defer class and to the ordinary dispatch-eligibility filter), runs
#     `eval-recheck-probe.sh --bulk` and captures its verdict. This is the
#     live-network precomputation half of the event-gate filter — kept as
#     its own subcommand for exactly the same reason `closed-by-healthy-pr`
#     is: `classify` itself stays a pure function with zero `gh`/`npm` calls
#     of its own, fixture-testable forever (see the design note below).
#     Prints a JSON object `{"<number>":"<verdict>", ...}` on stdout —
#     ready to pass straight through as `classify --probe-verdicts`. Issues
#     with no `do-work-recheck` marker contribute no key (silence, not an
#     `"absent"` entry — matches `eval-recheck-probe.sh --bulk`'s own output
#     contract). Empty object (`{}`), not empty string, when no issue in the
#     input carries a marker — so `--probe-verdicts "$(...)"` composes
#     directly without a caller-side empty-string special case.
#     Exit codes: 0 success (even if no issue carries a marker); 65 if `gh`
#     or `jq` is missing.
#
#   eval-pr-collision --repo <owner/repo>
#     < wide-fetch-issue-json (array) on stdin — same payload `classify`
#     reads (only `number`/`body` used).
#     Live-queries: for every issue whose body's first line carries a
#     `do-work-blocked-by-prs: N,M` marker (issue #1429), queries every
#     listed PR's current state via `gh pr view <N> --json state -q .state`
#     — a single fixed call per PR, no arbitrary command grammar, so unlike
#     `eval-probes` there is no separate allowlist-evaluator script to
#     delegate to. Verdict is `"resolved"` only when EVERY listed PR is
#     MERGED or CLOSED; `"open"` otherwise (including a query error or an
#     unrecognized state) — same fail-safe-to-gated posture
#     `eval-recheck-probe.sh` documents for its own probes. Prints a JSON
#     object `{"<number>":"resolved"|"open", ...}` on stdout, ready to pass
#     straight through as `classify --pr-collision-verdicts`. Issues with no
#     marker contribute no key. Empty object (`{}`) when no issue in the
#     input carries a marker.
#     Exit codes: 0 success (even if no issue carries a marker); 65 if `gh`
#     or `jq` is missing.
#
#   validate-issues
#     Reads the same wide-fetch JSON array on stdin and checks ONLY its
#     shape — the marshalling contract `classify` depends on (issue #1555).
#     Pure, offline, no flags. Exists because the projection is subtly
#     non-uniform: `labels`, `assignees` and `milestone` flatten to
#     scalars while `author` stays the object `{login}`, and getting that
#     asymmetry wrong used to surface as a raw POSITIONAL jq error with no
#     field name ("Cannot index string with string \"login\""), diagnosable
#     only by re-reading this header. Emits one `input error: ...` line per
#     offending field on stderr — each naming the field, the wrong type,
#     the issue number, and the flattening expression that fixes it —
#     followed by the canonical `gh issue list` fetch command in full.
#     Permissive about ABSENT fields (every one is optional to `classify`,
#     which defaults them) and about extra unknown fields; strict only
#     about a field that is present, non-null, and the wrong type, so it
#     can never reject an input `classify` would have handled correctly.
#     `classify` runs this same check itself before classifying, so a
#     direct `classify` caller is covered without calling this first;
#     `classify-backlog.sh run` calls it explicitly to fail BEFORE
#     spending its live-network input-gathering calls.
#     Exit codes: 0 valid; 64 invalid shape (or unparseable JSON); 65 if
#     `jq` is missing.
#
#   closed-by-healthy-pr --repo <owner/repo> --me <login>
#     Live-queries GitHub: the set of issue numbers with an OPEN PR,
#     authored by --me, that (a) is currently healthy — its latest-per-name
#     check-rollup projection (the #333 group-by, reused verbatim rather
#     than re-derived) has ZERO failing checks, and mergeStateStatus !=
#     DIRTY — and (b) has this issue in closingIssuesReferences. Health is
#     deliberately NOT gated on mergeStateStatus's CLEAN/HAS_HOOKS/UNSTABLE
#     allowlist (the pre-#1262 behavior): on a ruleset-protected default
#     branch, a PR whose required checks are merely queued reports
#     mergeStateStatus == BLOCKED even though nothing has actually failed —
#     misclassifying a genuinely healthy, still-in-flight PR as unhealthy
#     and leaving its issue in the workable backlog, risking a duplicate PR
#     against work already in flight (issue #1262). DIRTY is excluded on
#     its own — that state belongs to the fix-rebase path, never "healthy,"
#     regardless of check state.
#     This is the "closed-by-@me-authored-healthy-PR" drop clause's input
#     set — it requires live network access, so unlike `classify` it is NOT
#     a pure function and is not fixture-tested; it is the thin,
#     single-copy replacement for the `gh pr list` + jq block that used to
#     be written out in full in setup.md step 4 and silently assumed
#     ("apply the same filter") at the other two call-sites.
#     Prints a comma-separated, numerically-sorted, deduped list of issue
#     numbers to stdout (empty output, not "(none)", when the set is empty
#     — so `--closed-by-healthy-pr "$(...)"` composes directly).
#     Exit codes: 0 success (even if the set is empty); 65 if `gh` or `jq`
#     is missing.
#
#   closed-by-open-pr --repo <owner/repo> --me <login>
#     Live-queries GitHub: the set of issue numbers with an OPEN PR authored
#     by --me that names them in closingIssuesReferences — with NO health
#     filter of any kind (no check-rollup walk, no mergeStateStatus test).
#     The sibling of `closed-by-healthy-pr` above, and deliberately NOT a
#     replacement for it: that subcommand keeps its exact current meaning
#     and its current consumers, because "is this PR healthy?" is still the
#     right question for the `failed_prs` / fix-checks routing it feeds.
#     This one answers the different question issue #1389 identified as
#     being wrongly answered by that same health check — "is this ISSUE
#     already covered by in-flight work?" — for which health is irrelevant.
#     Prints a JSON object `{"<issue-number>": <pr-number>, ...}` on stdout,
#     ready to pass straight through as `classify --closed-by-open-pr`. The
#     PR number is carried (rather than a bare CSV of issue numbers, the
#     shape `closed-by-healthy-pr` uses) so `classify` can emit a concrete
#     `evidence_pointer` naming the covering PR. When more than one open PR
#     closes the same issue, the LOWEST PR number wins — arbitrary but
#     deterministic, so the emitted evidence pointer is stable across runs.
#     Empty object (`{}`), not empty string, when no open PR closes any
#     issue — so `--closed-by-open-pr "$(...)"` composes without a
#     caller-side empty-string special case.
#     Uses `closingIssuesReferences` — GitHub's canonical "this PR
#     auto-closes that issue" signal — never a PR-body substring search
#     (issue #301). Its `gh pr list` projection is strictly cheaper than
#     `closed-by-healthy-pr`'s: `number,closingIssuesReferences` only, with
#     no `statusCheckRollup` (the expensive per-check array).
#     Exit codes: 0 success (even if the set is empty); 65 if `gh` or `jq`
#     is missing.
#
#   summary --me <login>
#     < wide-fetch-issue-json (array) on stdin — the exact same payload
#     `classify` reads, passed BEFORE classification runs.
#     Emits the `unfiltered_open_count` / `me_assigned_open` invariant-line
#     tokens (issue #1246) as a single JSON object on stdout:
#       {"unfiltered_open_count":36,"me_assigned_open":16}
#     `unfiltered_open_count` is simply the input array's length;
#     `me_assigned_open` is the count of issues whose `assignees` array
#     contains --me (case-insensitive). A deliberately separate subcommand
#     from `classify` rather than a line folded into its NDJSON stream —
#     `classify`'s output contract (one line per input issue, in a
#     documented rank order) is depended on verbatim by three call-sites
#     and their fixture tests; appending a summary line there would change
#     that contract for every existing consumer. Kept here (not computed
#     ad hoc by each caller) for the same reason `classify` itself exists:
#     the caller already holds the pre-filter payload, so this is the
#     single place the count is computed, rather than three independent
#     `jq 'length'` / assignee-matching one-liners that could drift.
#     Exit 0 always (even on an empty input array — emits count 0/0).
#
# Design note — why classify takes precomputed sets rather than doing its
# own network I/O for --closed-by-healthy-pr / --peer-claimed: the
# classification/routing DECISION is the part that has actually drifted
# (see the #332/#1194/#1120 history above) and is exactly what
# needs to be fixture-testable against fixed inputs, byte-for-byte,
# forever. The live network calls that produce those input sets are
# comparatively simple, already had their own bugs fixed once each (#301's
# closingIssuesReferences fix, #333's latest-per-name rollup fix) and
# aren't where the drift has occurred. Keeping `classify` pure means its
# test suite runs with no `gh` calls, no `--repo`, and no network at all.
#
# Why "Blocked by #N still open" needs no extra input: the wide-fetch
# payload IS the complete set of this repo's currently-open issues (the
# server-side fetch is `--state open`, no other filter) — so "is #N still
# open" is answered by "does #N appear in this same payload's own `number`
# list", with no separate per-reference `gh issue view` call required. A
# referenced #N that has already closed (or was never an issue in this
# repo) simply doesn't appear, and the issue is correctly treated as
# unblocked.
#
# Exit codes: 0 success; 64 bad usage; 65 missing dependency (jq/gh).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  backlog-filter.sh classify --me <login> --trusted-authors <csv>
      [--closed-by-healthy-pr <csv-of-numbers>]
      [--closed-by-open-pr <json-object>] [--peer-claimed <csv-of-numbers>]
      [--investigate-dispatch true|false] [--prioritize-label <label>]
      [--today YYYY-MM-DD] [--respect-assignees true|false]
      [--milestones-enabled true|false]
      [--milestones-prioritize-dispatch true|false]
      [--probe-verdicts <json-object>] [--recheck-probe-enabled true|false]
      [--pr-collision-verdicts <json-object>] [--sub-issues <json-object>]
      [--someday-milestone <title>] [--someday-recheck-days <N>]
      [--fallback-milestone <title>]
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh validate-issues
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh closed-by-healthy-pr --repo <owner/repo> --me <login>

  backlog-filter.sh closed-by-open-pr --repo <owner/repo> --me <login>

  backlog-filter.sh someday-recheck-write --repo <owner/repo>
      --someday-recheck-days <N> [--today YYYY-MM-DD]
    < classify NDJSON (or {number, someday_recheck_action} lines) on stdin

  backlog-filter.sh eval-probes --repo <owner/repo>
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh eval-pr-collision --repo <owner/repo>
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh sub-issues --repo <owner/repo>
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh summary --me <login>
    < wide-fetch-issue-json (array) on stdin
EOF
}

# _csv_to_json_number_array <csv> — "" -> [], "3,7,7,x" -> [3,7] (non-numeric
# tokens dropped silently — defensive against a caller passing a stray
# empty field from a trailing comma).
_csv_to_json_number_array() {
  local csv="$1"
  jq -nc --arg csv "$csv" '
    ($csv | split(",") | map(select(test("^[0-9]+$"))) | map(tonumber))
  '
}

# _csv_to_json_lower_string_array <csv> — "" -> [], "Foo,bar" -> ["foo","bar"].
_csv_to_json_lower_string_array() {
  local csv="$1"
  jq -nc --arg csv "$csv" '
    ($csv | split(",") | map(select(length > 0)) | map(ascii_downcase))
  '
}

# --- Wide-fetch input-shape validation (issue #1555) -------------------------
#
# The wide-fetch projection every caller must hand `classify` is subtly
# NON-UNIFORM: `labels`, `assignees` and `milestone` are flattened to
# scalars, while `author` deliberately stays the object `{login}`. Three
# flattened, one not. Before this validation existed, a caller that got
# the asymmetry wrong got a raw POSITIONAL jq error with no field name
# ("object (...) cannot be matched, as it is not a string" / "Cannot index
# string with string \"login\"") and had to diagnose it by re-reading this
# file's header comment. Issue #1555's repro burned two failed invocations
# on exactly that, on a purely mechanical input-marshalling step.
#
# This validator fails up front with the offending FIELD named, the issue
# number it came from, the flattening expression that fixes it, and the
# canonical fetch command printed in full.
#
# Deliberately permissive about ABSENT fields: `classify` already defaults
# every optional field (`.labels // []`, `.milestone` null-safe, and
# `createdAt` is documented-but-unconsumed), and every pre-#1555 fixture
# omits at least one of them. Only a field that is PRESENT and non-null
# with the wrong type is an error, so this check can never reject an input
# the classifier would otherwise have handled correctly. Extra unknown
# fields are ignored too.

# shellcheck disable=SC2016
VALIDATE_ISSUES_JQ='
def tname: if . == null then "null" else type end;
def shape: if type == "array" then ("array of " + (map(tname) | unique | join("/"))) else tname end;

def loc($v; $i):
  if (($v | type) == "object") and (($v.number | type) == "number")
  then "issue #\($v.number)" else "element [\($i)]" end;

def str_or_null($v; $k; $w):
  if ($v | has($k)) and ($v[$k] != null) and (($v[$k] | type) != "string")
  then [".\($k) must be a string or null, got \($v[$k] | tname) (\($w))"]
  else [] end;

def flat_str_array($v; $k; $fix; $w):
  if ($v | has($k)) and ($v[$k] != null)
     and ((($v[$k] | type) != "array")
          or (((($v[$k] | map(tname) | unique) - ["string"]) | length) > 0))
  then [".\($k) must be an array of plain strings — flatten with `\($fix)` — got \($v[$k] | shape) (\($w))"]
  else [] end;

if type != "array" then
  ["top-level value must be a JSON array of issues, got \(tname)"]
else
  [ to_entries[]
    | .key as $i
    | .value as $v
    | if ($v | type) != "object" then
        ["element [\($i)] must be an object, got \($v | tname)"]
      else
        loc($v; $i) as $w
        | (if (($v | has("number")) | not) or (($v.number | type) != "number")
           then [".number must be a number, got \($v.number | tname) (\($w))"]
           else [] end)
          + flat_str_array($v; "labels"; "labels: [.labels[].name]"; $w)
          + flat_str_array($v; "assignees"; "assignees: [.assignees[].login]"; $w)
          + (if ($v | has("author")) and ($v.author != null)
                and ((($v.author | type) != "object") or (($v.author.login | type) != "string"))
             then [".author must be an object {login: \"<login>\"} — do NOT flatten it to a string the way labels/assignees/milestone are flattened — got \($v.author | tname) (\($w))"]
             else [] end)
          + (if ($v | has("milestone")) and ($v.milestone != null) and (($v.milestone | type) != "string")
             then [".milestone must be the milestone TITLE string or null — flatten with `milestone: (.milestone.title // null)` — got \($v.milestone | tname) (\($w))"]
             else [] end)
          + str_or_null($v; "title"; $w)
          + str_or_null($v; "body"; $w)
          + str_or_null($v; "createdAt"; $w)
          + str_or_null($v; "updatedAt"; $w)
      end
  ] | (add // [])
end
| .[]
'

# _wide_fetch_hint <label> — prints the canonical wide-fetch command, so the
# fix is readable at the point of failure rather than one file away.
_wide_fetch_hint() {
  local label="$1"
  {
    printf '%s: the canonical wide-fetch projection (setup/04-backlog-divert.md step 4) is:\n' "$label"
    printf '  gh issue list --repo <owner/repo> --state open --limit 200 \\\n'
    printf '    --json number,title,labels,assignees,body,author,createdAt,updatedAt,milestone \\\n'
    printf "    --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, createdAt, updatedAt, milestone: (.milestone.title // null)}]'\n"
    printf '%s: note the asymmetry — labels/assignees/milestone flatten to scalars; author stays the object {login}.\n' "$label"
  } >&2
}

# _validate_issues_json <json> <label> — 0 when the payload matches the
# wide-fetch shape, 64 (with named-field diagnostics on stderr) when it
# does not. At most 5 field errors are printed, then a count of the rest.
_validate_issues_json() {
  local json="$1" label="$2"
  local errs rc err_count
  errs=$(printf '%s' "$json" | jq -r "$VALIDATE_ISSUES_JQ" 2>/dev/null)
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s: input error: payload is not valid JSON (jq could not parse it)\n' "$label" >&2
    _wide_fetch_hint "$label"
    return 64
  fi
  if [[ -z "$errs" ]]; then
    return 0
  fi
  err_count=$(printf '%s\n' "$errs" | wc -l | tr -d ' ')
  printf '%s\n' "$errs" | head -5 | sed "s|^|${label}: input error: |" >&2
  if [[ "$err_count" -gt 5 ]]; then
    printf '%s: input error: ... and %s more\n' "$label" "$((err_count - 5))" >&2
  fi
  _wide_fetch_hint "$label"
  return 64
}

# The symptom-shaped-body regex, verbatim from
# setup/04d-investigate-routing.md's SYMPTOM_REGEX — kept as a single
# source string here so a future edit to the signal only has to change one
# place. jq's built-in regex engine (Oniguruma) accepts the same syntax.
SYMPTOM_REGEX='(Traceback \(most recent call last\)|Fatal error:|Unhandled( Promise)? [Rr]ejection|Exception in thread|Segmentation fault|NullPointerException|panic:|Stack trace:|sentry\.io/(organizations|issues)/|[Ff]ingerprint:[[:space:]]*[0-9a-f]{8,}|at [A-Za-z0-9_.$]+ ?\([^)]*:[0-9]+:[0-9]+\))'

# The jq classification program. Reads the wide-fetch array as `.` (top
# level input), emits the ordered NDJSON stream described in the header
# comment. Every dynamic input arrives via --arg/--argjson — no shell
# interpolation inside the program string itself.
# shellcheck disable=SC2016
# NOTE on style: every function below takes its issue as a `$`-prefixed
# (value) parameter, never a bare filter parameter. jq bare (non-$) function
# parameters are dynamically-scoped filters re-evaluated against whatever
# `.` happens to be at each point they are REFERENCED inside the function
# body — not lexically-captured values — so a bare `issue` referenced from
# inside a nested select()/map()/any() (where `.` has already changed to
# some inner iteration variable) silently evaluates against the WRONG
# value. `$`-parameters are evaluated once, at the call site, and behave
# like ordinary bound values from then on, which is what every function
# below actually needs.
CLASSIFY_JQ='
def lower: ascii_downcase;

# Dispatch-gate labels that DROP an issue outright (never routed) — the
# literal enumeration from setup.md step 4. agent-console is deliberately
# absent: it is a ROUTE, handled by its own clause below, never by this
# drop-on-label clause. (`needs-triage` was a second such route until
# #1120 retired the label; investigate entry is now detection-only.)
#
# `tracking` is the one PROVISIONAL member of this list (defensive gate,
# #1081, pending migration to needs-human-review by 01c sub-sweep e) — see
# backlog-ownership.md bucket 5.5 Notes for the full history. The other
# four (`blocked:ci`, `wontfix`, `discussion`, `needs-human-review`) are
# settled, intentional gates with a stated owner in backlog-ownership.md;
# label presence alone is sufficient justification for those. `tracking`
# alone gets the extra has_tracking_justification() check below (#1364) —
# a provisional/defensive rule may not drop an issue on label presence
# alone with no content-sourced signal that the label reflects the issue
# real state.
def gate_labels: ["blocked:ci", "wontfix", "discussion", "needs-human-review", "tracking"];

# has_tracking_justification($issue; $subs) -- issues #1364 and #1556. The
# bare `tracking` gate above is explicitly documented as provisional (a
# defensive gate against the label object never being migrated, #1081)
# rather than a settled, intentional routing decision -- so unlike the other
# four gate labels, it must not fire silently on label presence alone: it
# requires at least one recognized human-owned signal. Absence of every
# signal means the label is doing all the work, which is the case worth
# surfacing rather than silently dropping. Returns a short citation string
# (becomes the emitted `evidence_pointer`) on a match, or null on no match
# -- mirrors the deferred_issues evidence_pointer convention (a single
# concrete, content-sourced citation string), not that subsystem full
# object shape (defer_reason_class/provenance/deferred_at do not apply to
# a pure mechanical classifier with no LLM judgment involved).
#
# The recognized signals, in precedence order:
#   1. a populated GitHub sub-issue graph   (structured, #1556)
#   2. a `Decision required` heading        (body prose, #1364)
#   3. an `Options` heading                 (body prose, #1364)
#   4. a `Blocked by #N` reference          (body prose, #1364)
#   5. a task-list of issue references      (body prose, #1556)
# Signal 1 ranks first because it is the definitional case and the only
# non-prose one; signal 5 ranks last so that adding it cannot change the
# evidence_pointer any pre-#1556 match already emitted.
# sub_issue_justification($issue; $subs) -- issue #1556. The one STRUCTURED
# signal in this list, and the strongest justification there is: `tracking`
# is DEFINED as "parent epic/strategy, decomposed into sub-issues", so an
# issue with a populated GitHub sub-issue graph is the textbook case the
# label exists for. It was also the one case the body-prose-only signal list
# could not see, because the sub-issue relationship is structured GitHub
# state, never body text -- so a correctly decomposed epic surfaced as
# `tracking-unjustified` (an anomaly) while an issue that merely happened to
# carry an "Options" heading passed clean. $subs is the precomputed map the
# `sub-issues` subcommand produces (network I/O happens THERE, never here --
# classify stays pure, same discipline as probe_verdict / pr_collision_
# verdict above). A missing entry -- no precompute ran, the repo has no
# sub-issue graph, the API read failed -- yields null and falls through to
# the body-prose signals below, i.e. exactly the pre-#1556 behavior.
def sub_issue_justification($issue; $subs):
  (($subs[($issue.number | tostring)]) // []) as $raw
  | (if (($raw | type) == "array")
     then ($raw | map(select((type == "object") and (.number != null))))
     else [] end) as $nodes
  | if (($nodes | length) == 0) then null
    else
      ($nodes | length) as $total
      | ([$nodes[] | select(((.state // "") | lower) == "open")] | length) as $open
      | ($nodes | map("#" + (.number | tostring))) as $refs
      | (if ($total > 10)
         then (($refs[0:10] | join(", ")) + ", ...")
         else ($refs | join(", ")) end) as $list
      | (($total | tostring)
         + (if ($total == 1) then " sub-issue (" else " sub-issues (" end)
         + $list + "); " + ($open | tostring) + " open")
    end;

# task_list_justification($issue) -- issue #1556, the second half. A body
# task-list of issue references (`- [ ] #123`, or the same line carrying a
# full issue URL) is the PRE-sub-issues way of expressing the identical
# decomposition, still common in older epics filed before GitHub shipped the
# structured sub-issue graph. Ranked LAST so the three original prose
# signals keep emitting byte-identical evidence_pointer strings for every
# issue that already matched one of them.
def task_list_justification($issue):
  ($issue.body // "") as $b
  | ([$b | scan("(?im)^[ \\t]*[-*+][ \\t]+\\[[ xX]\\][ \\t]+(?:https://github\\.com/[^ /]+/[^ /]+/issues/|#)([0-9]+)")] | first) as $tcap
  | if ($tcap == null) then null
    else ("Task-list issue reference #" + $tcap[0] + " in body")
    end;

def has_tracking_justification($issue; $subs):
  (sub_issue_justification($issue; $subs)) as $sub
  | ($issue.body // "") as $b
  | if ($sub != null) then $sub
    elif ($b | test("(?im)^#{1,6}\\s*decision required\\b")) then
      "Decision-required heading in body"
    elif ($b | test("(?im)^#{1,6}\\s*options?\\b")) then
      "Options heading in body"
    else
      ([$b | scan("(?i)blocked by #([0-9]+)")] | first) as $bcap
      | if ($bcap == null) then task_list_justification($issue)
        else ("Blocked by #" + $bcap[0] + " reference in body")
        end
    end;

def priority_rank($issue):
  if ($issue.labels | index("P0") != null) then 0
  elif ($issue.labels | index("P1") != null) then 1
  elif ($issue.labels | index("P2") != null) then 2
  else 3
  end;

def type_rank($issue):
  if ($issue.labels | index("bug") != null) then 0
  elif ($issue.title | test("^fix\\(")) then 1
  elif ($issue.title | test("^feat\\(")) then 2
  elif ($issue.title | test("^chore\\(")) then 3
  else 4
  end;

# milestone_seq($issue) -- the issue milestone sequence number, parsed
# from the milestone title "N · Title" prefix (U+00B7 MIDDLE DOT, one
# space each side -- the fixed, non-configurable numbering contract per
# schemas/shipyard.config.schema.json milestones block). An unmilestoned
# issue, or one whose milestone title does not parse (malformed, or a
# pre-#1239 milestone that predates the numbering convention), gets a
# sentinel far larger than any real sequence number so it sorts to the
# tail rather than being dropped from the ranked list (issue #1241
# acceptance: "An issue with no milestone at all still ranks"). This def
# reports the RAW sentinel; milestone_rank below is what the sort key
# actually uses, and it is what turns "strictly after the fallback
# milestone" into "tied with it" when the caller names one (issue #1499).
# capture() wrapped in [...] then `first` turns "zero outputs on
# no-match" into a real `null` we can branch on, same defensive pattern
# time_gate_future uses below for the identical reason. NOTE: no literal
# apostrophes anywhere in this program string -- CLASSIFY_JQ is itself a
# single-quoted bash string, so an apostrophe (even inside a comment)
# would terminate it early.
def milestone_seq($issue):
  ($issue.milestone // "") as $m
  | ([$m | capture("^\\s*(?<n>[0-9]+)\\s*·")] | first) as $cap
  | if ($cap == null) then 999999999
    else ($cap.n | tonumber)
    end;

# milestone_title_bare($issue) -- the issue milestone title with any
# leading "N · " sequence-number prefix stripped, trimmed and lowercased.
# "6 · Someday" -> "someday". An unmilestoned issue (null/absent) -> "".
# Shared by is_someday below -- kept as its own def so a future consumer
# does not have to re-derive the strip regex. NOTE: no literal apostrophes
# anywhere in this program string -- see the style note near the top of
# this CLASSIFY_JQ definition.
def milestone_title_bare($issue):
  ($issue.milestone // "") as $m
  | ($m | sub("^\\s*[0-9]+\\s*·\\s*"; "") | ascii_downcase | gsub("^\\s+|\\s+$"; ""));

# fallback_milestone_seq($issues; $fallback) -- issue #1499. The sequence
# number the FALLBACK milestone occupies in THIS input, or null when it
# cannot be established (no title configured, or no input issue carries
# that milestone). Read back from the data rather than taken as a config
# number so classify stays a pure function -- the caller supplies only the
# bare TITLE, exactly as it does for --someday-milestone, and never a
# number it would have to keep in sync with the repo own milestone list.
# `min` over the matching issues sequence numbers (rather than `first`)
# is the conservative pick: every issue on one milestone reports the same
# N, so they agree in practice, and if a malformed payload ever disagreed
# the LOWER number is the one that ranks unmilestoned issues no later than
# the fallback -- never accidentally promoting them past a real phase.
# jq `[] | min` is null, which is exactly the "cannot be established"
# signal milestone_rank below branches on. NOTE: no literal apostrophes
# anywhere in this program string -- see the style note on milestone_seq.
def fallback_milestone_seq($issues; $fallback):
  ($fallback | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $target
  | if $target == "" then null
    else ([$issues[]
           | select(milestone_title_bare(.) == $target)
           | milestone_seq(.)]
          | min)
    end;

# milestone_rank($issue; $unmilestoned_seq) -- issue #1499. The value tier
# 3 of the milestone-on _sort_key actually sorts on: milestone_seq, with
# the unmilestoned/unparseable sentinel remapped onto the fallback
# milestone own sequence number whenever the caller named a fallback
# milestone that is present in this input.
#
# Why this exists: milestone_seq sentinel (999999999) is strictly LARGER
# than any real N, and _sort_key puts milestone ABOVE priority_rank. So an
# unmilestoned issue lost to every milestoned issue -- including one in
# the fallback phase, which is semantically the SAME state ("no phase
# fits"). That made a fallback-milestoned P2 outrank an unmilestoned P1,
# a wholesale severity override rather than a tiebreak, and it contradicted
# milestone_seq own stated intent ("alongside where the fallback milestone
# already sorts"). Remapping the sentinel onto the fallback N makes the two
# genuinely equivalent, so priority_rank decides between them.
#
# When $unmilestoned_seq is null (no fallback title configured, or no
# input issue carries it) this is the identity on milestone_seq -- the
# sentinel stands and unmilestoned issues sort last, byte-identical to
# pre-#1499 behavior. A fallback milestone whose OWN title does not parse
# also yields 999999999 here, which remaps to itself: still a tie, still
# correct.
def milestone_rank($issue; $unmilestoned_seq):
  milestone_seq($issue) as $seq
  | if ($seq == 999999999) and ($unmilestoned_seq != null)
    then $unmilestoned_seq
    else $seq
    end;

# is_someday($issue; $someday) -- issue #1406. True only when $someday is
# non-empty (the off-by-default posture -- an empty configured title never
# matches any real milestone) AND the issue bare milestone title
# case-insensitively equals it. Deliberately an EXACT match, not a
# substring/regex test -- a milestone named "Someday, maybe" is a
# different phase than one named "Someday", and silently catching both
# would be the same "shorthand erased real signal" class of bug #332 and
# #1194 document for the label-drop clauses above.
def is_someday($issue; $someday):
  ($someday | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $target
  | ($target != "") and (milestone_title_bare($issue) == $target);

# someday_recheck_marker_date($issue) -- issue #1422. Extracts the date
# from a <!-- do-work-someday-recheck: YYYY-MM-DD --> marker anywhere in
# the body (multiline scan -- mirrors the do-work-recheck marker own "no
# line-1 position discipline" convention, not the do-work-blocked-until
# marker: this marker is orchestrator-written and orchestrator-read only,
# never hand-authored on a specific line, so there is no human placement
# convention to protect). A DISTINCT marker text from do-work-blocked-
# until on purpose -- it answers a different question (when to next
# reconsider a Someday park recheck cadence, not when an issue becomes
# calendar-eligible again), and conflating the two would let an unrelated
# defer class own blocked-until date (e.g. an external-dependency
# recheck window) silently gate the Someday cadence or vice versa.
# Returns the date string, or null when no marker is present. Reuses the
# capture()-wrapped-in-[...]-then-first defensive pattern from
# time_gate_future/milestone_seq above, for the same reason: capture()
# produces zero outputs (not null) on no match.
def someday_recheck_marker_date($issue):
  ($issue.body // "") as $b
  | ([$b | capture("(?m)^<!--\\s*do-work-someday-recheck:\\s*(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})\\s*-->\\s*$")] | first) as $cap
  | if ($cap == null) then null else $cap.d end;

# someday_recheck_state($issue; $today; $cadence_days) -- issue #1422, the
# follow-up to #1406 own "drop is unconditional once matched" note. The
# pure decision behind the slow-cadence re-scope, computable entirely from
# data classify already has in hand (issue.body, issue.updatedAt) -- no
# extra I/O, keeping classify itself a pure function per this file own
# header design note. One of four states:
#   "first-park"  -- no do-work-someday-recheck marker exists yet (this
#                     issue has never been through the cadence before, or
#                     the cadence was just turned on). The caller writes
#                     an initial marker $cadence_days out; no comparison
#                     baseline exists yet so there is nothing to escalate.
#   "not-due"     -- a marker exists and its date is still in the future.
#                     No action needed.
#   "cheap-reset" -- the marker elapsed, but nothing about the issue has
#                     changed since the marker was written (updatedAt --
#                     which GitHub bumps on a body edit, a new comment, OR
#                     a label change -- has not advanced past that write
#                     date). The caller silently refreshes the marker for
#                     another cadence window. Zero scope-agent cost -- this
#                     is the DEFAULT, expected-common outcome the issue own
#                     cost framing argues for ("stop paying full scope
#                     cost every session for an identical answer").
#   "escalate"    -- the marker elapsed AND something changed since it was
#                     written. The caller lets this ONE issue back into
#                     `eligible` for exactly one real scope-agent pass this
#                     session (see classify_one is_someday branch below)
#                     rather than reopening it to permanent dispatch
#                     eligibility.
# $cadence_days == 0 disables the mechanism entirely -- the caller (see the
# call site below) never invokes this function in that case, reproducing
# #1406 original unconditional-permanent-drop behavior byte-for-byte.
def someday_recheck_state($issue; $today; $cadence_days):
  (someday_recheck_marker_date($issue)) as $marker_date
  | if ($marker_date == null) then
      "first-park"
    elif ($marker_date > $today) then
      "not-due"
    else
      # Elapsed. The date the marker was WRITTEN is derivable from the
      # marker itself (every writer computes marker_date == write_date +
      # cadence_days) -- no separate "last checked" field needs to be
      # persisted anywhere.
      ($marker_date | strptime("%Y-%m-%d") | mktime) as $marker_epoch
      | ($marker_epoch - ($cadence_days * 86400)) as $window_start_epoch
      | ($window_start_epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) as $window_start
      | if (($issue.updatedAt // "") > $window_start) then "escalate" else "cheap-reset" end
    end;

def prioritized_tier($issue; $plabel):
  if ($plabel == "") then 0
  elif ($issue.labels | index($plabel) != null) then 0
  else 1
  end;

def matches_gate_label($issue):
  [gate_labels[] | select(. as $g | $issue.labels | index($g) != null)] | first;

def is_agent_console($issue):
  ($issue.labels | index("agent-console") != null);

# Two signals, OR-d. The third — a `needs-triage` label — was retired in
# #1120 along with the label object itself; entry is now purely detection-
# based (see 04d-investigate-routing.md).
def is_investigate_signal($issue; $re):
  (($issue.author.login // "") | test("\\[bot\\]$|^app/"))
  or (($issue.body // "") | test($re; "i"));

def is_untrusted($issue; $trusted):
  (($issue.author.login // "") | lower) as $a | ($trusted | index($a)) == null;

def is_peer_claimed($issue; $peer):
  ($peer | index($issue.number) != null);

def is_assigned_to_other($issue; $me):
  ($issue.assignees | length) > 0
  and ((($issue.assignees | map(lower)) | index($me)) == null);

def blocked_by_open_issue($issue; $opennums):
  (($issue.body // "") | [scan("(?i)blocked by #([0-9]+)")]) as $refs
  | ($refs | map(.[0] | tonumber)) as $nums
  | ($nums | any(. as $n | ($n != $issue.number) and ($opennums | index($n) != null)));

def time_gate_future($issue; $today):
  ($issue.body // "") as $b
  | ($b | split("\n") | (.[0] // "")) as $first_line
  # capture() produces NO output at all (an empty stream, not a null) when
  # the string fails to match -- wrapping in [...] then `first` turns "zero
  # outputs" into a real `null` we can bind and branch on below. Binding
  # `capture(...)` directly via `as $cap` would otherwise make this entire
  # function silently produce zero outputs on every non-matching (the
  # overwhelmingly common) case -- every eligible issue would silently
  # vanish from classify output, because this def is called from every
  # classify_one and would swallow its own return value.
  | ([$first_line | capture("^<!--\\s*do-work-blocked-until:\\s*(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})\\s*-->\\s*$")] | first) as $cap
  | if ($cap == null) then false
    else ($cap.d > $today)
    end;

def is_closed_by_healthy_pr($issue; $healthy):
  ($healthy | index($issue.number) != null);

# covered_by_open_pr($issue; $covered) -- issue #1389. Returns the number of
# an OPEN --me-authored PR whose closingIssuesReferences names this issue,
# or null when no such PR exists. Health is deliberately NOT consulted: the
# check-rollup/mergeStateStatus test that feeds is_closed_by_healthy_pr
# above answers "should this PR go in failed_prs?", a question about the PR,
# and reusing it to answer "should this issue go in raw_backlog?" is the bug
# #1389 documents. An issue whose open PR is red is fix-checks work on that
# PR; an issue whose open PR is DIRTY is fix-rebase work on that PR. Neither
# is workable issue-work, so dispatching an issue-worker at either can only
# bail (issue-work.md step 0 catches it, but only AFTER a full worker
# dispatch has read the issue). The closed/abandoned-PR row that #332
# protects never reaches this map at all -- the producing subcommand queries
# --state open only -- so resumable work stays dispatchable by construction.
def covered_by_open_pr($issue; $covered):
  ($covered[($issue.number | tostring)] // null);

# is_event_gated($issue; $recheck_probe_enabled) -- issue #1356. True only
# when the class-level kill switch is on AND the body carries a
# `do-work-recheck` marker on ANY line (multiline flag "m" -- unlike
# `do-work-blocked-until`, this marker carries no line-1 "position
# discipline" requirement; eval-recheck-probe.sh extract_marker scans the
# whole body the same way, matching every occurrence of the marker line, so
# this mirrors the read side contract exactly). When true, the issue
# eligibility is decided entirely by probe_verdict below -- never by the
# calendar -- which is what stops the churn-loop this issue closes: an
# unresolved event gate keeps dropping the issue on every single classify
# pass regardless of whether a paired blocked-until date elapses, and never
# invents a new date to do it.
def is_event_gated($issue; $recheck_probe_enabled):
  $recheck_probe_enabled and (($issue.body // "") | test("(?m)^<!-- do-work-recheck: .+ -->$"));

# probe_verdict($issue; $verdicts) -- looks up the precomputed verdict
# eval-probes already ran (network I/O happens there, never here -- classify
# stays pure). No entry in the map (the precompute step was not run, or it
# produced no verdict for this issue for any reason) fails safe to
# "unknown", the same never-treat-inconclusive-as-resolved posture
# eval-recheck-probe.sh documents in its own header comment.
def probe_verdict($issue; $verdicts):
  ($verdicts[($issue.number | tostring)] // "unknown");

# is_pr_collision_gated($issue) -- issue #1429. True when the FIRST LINE of
# the body carries a `do-work-blocked-by-prs: N,M` marker -- the self-
# clearing companion to a `blocked-by-in-flight-pr` defer (mirrors the
# line-1-only position discipline `do-work-blocked-until` uses, not the
# any-line convention `do-work-recheck` uses, since this marker is written
# by the same step-4e recording path that writes `do-work-blocked-until`
# for the other two self-clearing classes). Same capture()-then-[...]-then-
# first idiom time_gate_future uses above, for the same reason: a bare
# `as $cap` bind would swallow the entire output of classify_one on every
# non-matching (the common) case.
def is_pr_collision_gated($issue):
  ($issue.body // "") as $b
  | ($b | split("\n") | (.[0] // "")) as $first_line
  | ([$first_line | capture("^<!--\\s*do-work-blocked-by-prs:\\s*(?<prs>[0-9]+(,[0-9]+)*)\\s*-->\\s*$")] | first) as $cap
  | ($cap != null);

# pr_collision_verdict($issue; $verdicts) -- looks up the precomputed
# verdict eval-pr-collision already ran (network I/O happens there, never
# here -- classify stays pure, same discipline as probe_verdict above). No
# entry in the map (the precompute step was not run, or it produced no
# verdict for this issue for any reason) fails safe to "open" -- the GATED
# value -- never "resolved", so a missing precompute keeps the issue
# dropped rather than silently admitting it.
def pr_collision_verdict($issue; $verdicts):
  ($verdicts[($issue.number | tostring)] // "open");

def classify_one($issue; $me; $trusted; $healthy; $covered; $peer; $investigate_dispatch; $today; $re; $opennums; $respect_assignees; $recheck_probe_enabled; $probe_verdicts; $pr_collision_verdicts; $someday_milestone; $someday_recheck_days; $unmilestoned_seq; $sub_issues):
  (matches_gate_label($issue)) as $gate_hit
  | is_event_gated($issue; $recheck_probe_enabled) as $event_gated
  | is_pr_collision_gated($issue) as $pr_collision_gated
  | if is_untrusted($issue; $trusted) then
      {number: $issue.number, verdict: "drop", reason: "untrusted-author"}
    elif ($gate_hit != null) then
      (if ($gate_hit == "tracking") then
         (has_tracking_justification($issue; $sub_issues)) as $justification
         | (if ($justification != null) then
              {number: $issue.number, verdict: "gate", reason: "tracking", evidence_pointer: $justification}
            else
              {number: $issue.number, verdict: "gate", reason: "tracking-unjustified"}
            end)
       else
         {number: $issue.number, verdict: "gate", reason: $gate_hit}
       end)
    elif is_agent_console($issue) then
      {number: $issue.number, verdict: "route", reason: "operator"}
    elif is_investigate_signal($issue; $re) then
      (if $investigate_dispatch then
         {number: $issue.number, verdict: "route", reason: "investigate"}
       else
         {number: $issue.number, verdict: "drop", reason: "investigate-disabled"}
       end)
    elif is_peer_claimed($issue; $peer) then
      {number: $issue.number, verdict: "drop", reason: "peer-claimed"}
    elif ($respect_assignees and is_assigned_to_other($issue; $me)) then
      {number: $issue.number, verdict: "drop", reason: "assigned-other"}
    elif blocked_by_open_issue($issue; $opennums) then
      {number: $issue.number, verdict: "drop", reason: "blocked-by-open-issue"}
    elif ($event_gated and (probe_verdict($issue; $probe_verdicts) != "changed")) then
      {number: $issue.number, verdict: "drop", reason: "event-gated"}
    elif ($pr_collision_gated and (pr_collision_verdict($issue; $pr_collision_verdicts) != "resolved")) then
      {number: $issue.number, verdict: "drop", reason: "pr-collision-gated"}
    elif ((($event_gated | not)) and time_gate_future($issue; $today)) then
      {number: $issue.number, verdict: "drop", reason: "time-gated"}
    elif is_someday($issue; $someday_milestone) then
      (if ($someday_recheck_days > 0) then
         (someday_recheck_state($issue; $today; $someday_recheck_days)) as $recheck_state
         | if ($recheck_state == "escalate") then
             # #1422 -- exactly ONE real scope-agent pass this session, not
             # permanent dispatch eligibility: the marker gets refreshed
             # (resetting the cadence clock) wherever the scope-agent own
             # conclusion is recorded, whatever defer class it lands on --
             # see 06c-scope-handling-ui.md step 4d.
             {number: $issue.number, verdict: "eligible"}
           else
             {number: $issue.number, verdict: "drop", reason: "someday-milestone",
              evidence_pointer: ("milestone " + ($issue.milestone // "")),
              someday_recheck_action: $recheck_state}
           end
       else
         {number: $issue.number, verdict: "drop", reason: "someday-milestone",
          evidence_pointer: ("milestone " + ($issue.milestone // ""))}
       end)
    elif is_closed_by_healthy_pr($issue; $healthy) then
      {number: $issue.number, verdict: "drop", reason: "closed-by-healthy-pr"}
    elif (covered_by_open_pr($issue; $covered) != null) then
      # Ordered AFTER the healthy clause on purpose (issue #1389): the
      # covered set is a strict SUPERSET of the healthy set, so putting it
      # first would silently relabel every already-dropped healthy row.
      # Reaching here therefore means "open PR, but NOT healthy" -- exactly
      # the two rows (open+red, open+DIRTY) that used to stay dispatchable.
      (covered_by_open_pr($issue; $covered)) as $pr
      | {number: $issue.number, verdict: "drop", reason: "covered-by-open-pr",
         evidence_pointer: ("PR #" + ($pr | tostring)
                            + " closingIssuesReferences includes #"
                            + ($issue.number | tostring))}
    else
      {number: $issue.number, verdict: "eligible"}
    end
  | . + {
      _priority_rank: priority_rank($issue),
      _type_rank: type_rank($issue),
      _prioritized_tier: prioritized_tier($issue; $prioritize_label),
      _updatedAt: ($issue.updatedAt // ""),
      # _sort_key -- the eligible-bucket sort key, issue #1241. Computed
      # here (not left inline at the final sort_by) so BOTH branches are
      # visible together with the byte-identical-by-construction guarantee
      # they exist to satisfy: the milestone-off branch is a verbatim copy
      # of the pre-#1241 [_prioritized_tier, _priority_rank, _type_rank,
      # _updatedAt] key, so a repo with milestones.enabled:false OR
      # milestones.prioritize_dispatch:false gets the exact same ranking
      # as every prior release, never a "close enough" approximation. The
      # milestone-on branch promotes P0 to a global tier ABOVE
      # _prioritized_tier -- a deliberate behavior CHANGE, gated so it can
      # only fire when a repo has actually opted into milestone-ordered
      # dispatch (see header comment + do-work-RATIONALE.md for the full
      # tier-ordering rationale). The milestone tier is milestone_rank,
      # not milestone_seq, so an unmilestoned issue TIES with the fallback
      # milestone rather than losing to it -- the milestone tier then has
      # nothing to say and priority_rank below decides (issue #1499).
      _sort_key: (
        if $milestone_rank_on then
          [(if priority_rank($issue) == 0 then 0 else 1 end),
           prioritized_tier($issue; $prioritize_label),
           milestone_rank($issue; $unmilestoned_seq),
           priority_rank($issue),
           type_rank($issue),
           ($issue.updatedAt // "")]
        else
          [prioritized_tier($issue; $prioritize_label),
           priority_rank($issue),
           type_rank($issue),
           ($issue.updatedAt // "")]
        end
      )
    };

. as $issues
| ($issues | map(.number)) as $opennums
# $unmilestoned_seq (issue #1499) -- one whole-input computation, hoisted
# out of the per-issue map because it is a property of the BACKLOG, not of
# any single issue. null whenever no fallback milestone was named or none
# is present in this input, which makes milestone_rank the identity.
| (fallback_milestone_seq($issues; $fallback_milestone)) as $unmilestoned_seq
| ($issues | map(. as $issue | classify_one($issue; $me; $trusted; $healthy; $covered_by_open_pr; $peer; $investigate_dispatch; $today; $symptom_re; $opennums; $respect_assignees; $recheck_probe_enabled; $probe_verdicts; $pr_collision_verdicts; $someday_milestone; $someday_recheck_days; $unmilestoned_seq; $sub_issues))) as $classified
| (
    ($classified | map(select(.verdict == "eligible"))
      | sort_by(._sort_key))
    +
    ($classified | map(select(.verdict == "route" and .reason == "investigate"))
      | sort_by([._priority_rank, ._updatedAt]))
    +
    ($classified | map(select(
        (.verdict != "eligible")
        and (.verdict != "route" or .reason != "investigate")
      )))
  )
| .[]
| (if has("someday_recheck_action") then {number, verdict, reason, evidence_pointer, someday_recheck_action}
   elif has("evidence_pointer") then {number, verdict, reason, evidence_pointer}
   elif has("reason") then {number, verdict, reason}
   else {number, verdict}
   end)
'

cmd_classify() {
  local me="" trusted_csv="" healthy_csv="" peer_csv="" investigate_dispatch="true"
  local prioritize_label="" today="" respect_assignees="true"
  # milestones.enabled / milestones.prioritize_dispatch (issue #1241) --
  # BOTH default "false" so a caller that never passes these flags at all
  # (every pre-#1241 invocation, and every fixture test written before
  # this issue) gets the exact pre-#1241 behavior with zero code change on
  # its end -- the milestone-ranking gate below can only ever turn ON via
  # an explicit true/true pair.
  local milestones_enabled="false" milestones_prioritize_dispatch="false"
  # --probe-verdicts / --recheck-probe-enabled (issue #1356). Default
  # "{}" / "true" reproduces pre-#1356 behavior byte-for-byte for every
  # existing caller and fixture: with an empty verdicts map and no
  # do-work-recheck marker in the body, is_event_gated is false for every
  # issue and classify_one falls straight through to the unchanged
  # time_gate_future branch.
  local probe_verdicts_json="{}" recheck_probe_enabled="true"
  # --pr-collision-verdicts (issue #1429). Default "{}" reproduces pre-#1429
  # behavior byte-for-byte: with an empty verdicts map and no do-work-
  # blocked-by-prs marker in the body, is_pr_collision_gated is false for
  # every issue and classify_one falls straight through to the unchanged
  # time_gate_future branch. No kill-switch flag (unlike --recheck-probe-
  # enabled) -- the underlying probe is a fixed `gh pr view --json state`
  # per listed PR, not the arbitrary allowlisted-verb grammar
  # eval-recheck-probe.sh guards, so there is no equivalent security
  # surface to gate off.
  local pr_collision_verdicts_json="{}"
  # --sub-issues (issue #1556). Default "{}" reproduces pre-#1556 behavior
  # byte-for-byte for every existing caller and fixture: with an empty map,
  # sub_issue_justification returns null for every issue and
  # has_tracking_justification falls straight through to the unchanged
  # body-prose signal chain. Produced by the `sub-issues` subcommand below.
  local sub_issues_json="{}"
  # --closed-by-open-pr (issue #1389). Default "{}" reproduces pre-#1389
  # behavior byte-for-byte for every existing caller and fixture: with an
  # empty map, covered_by_open_pr returns null for every issue and
  # classify_one falls straight through to the unchanged `eligible` branch.
  local covered_by_open_pr_json="{}"
  # --someday-milestone (issue #1406). Default "" -- an empty configured
  # title never matches a real milestone title (is_someday requires a
  # non-empty $target), so the clause is off by construction for every
  # existing caller and fixture until a non-empty value is explicitly
  # passed. Mirrors the `backlog.someday_milestone` config knob's own
  # default and off-by-default posture.
  local someday_milestone=""
  # --someday-recheck-days (issue #1422). Default "0" -- disables the
  # slow-cadence re-scope mechanism entirely, reproducing #1406's original
  # unconditional-permanent-drop behavior byte-for-byte for every existing
  # caller and fixture that predates this flag. A real caller passes the
  # resolved `backlog.someday_recheck_days` config value (built-in default
  # 30) explicitly, same convention as every other config-backed flag here.
  local someday_recheck_days="0"
  # --fallback-milestone (issue #1499). Default "" -- an empty configured
  # title never matches a real milestone title (fallback_milestone_seq
  # returns null for a non-empty $target too when no input issue carries
  # it), so milestone_rank is the identity on milestone_seq and the
  # ranking is byte-identical to pre-#1499 for every existing caller and
  # fixture. Mirrors the `milestones.fallback` config knob (schema default
  # "Ongoing maintenance"); a real caller resolves and passes THAT.
  local fallback_milestone=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --me) me="${2:-}"; shift 2 ;;
      --trusted-authors) trusted_csv="${2:-}"; shift 2 ;;
      --closed-by-healthy-pr) healthy_csv="${2:-}"; shift 2 ;;
      --closed-by-open-pr) covered_by_open_pr_json="${2:-}"; shift 2 ;;
      --peer-claimed) peer_csv="${2:-}"; shift 2 ;;
      --investigate-dispatch) investigate_dispatch="${2:-}"; shift 2 ;;
      --prioritize-label) prioritize_label="${2:-}"; shift 2 ;;
      --today) today="${2:-}"; shift 2 ;;
      --respect-assignees) respect_assignees="${2:-}"; shift 2 ;;
      --milestones-enabled) milestones_enabled="${2:-}"; shift 2 ;;
      --milestones-prioritize-dispatch) milestones_prioritize_dispatch="${2:-}"; shift 2 ;;
      --probe-verdicts) probe_verdicts_json="${2:-}"; shift 2 ;;
      --recheck-probe-enabled) recheck_probe_enabled="${2:-}"; shift 2 ;;
      --pr-collision-verdicts) pr_collision_verdicts_json="${2:-}"; shift 2 ;;
      --sub-issues) sub_issues_json="${2:-}"; shift 2 ;;
      --someday-milestone) someday_milestone="${2:-}"; shift 2 ;;
      --someday-recheck-days) someday_recheck_days="${2:-}"; shift 2 ;;
      --fallback-milestone) fallback_milestone="${2:-}"; shift 2 ;;
      *) echo "classify: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$me" ]]; then
    echo "classify: --me is required" >&2
    usage
    return 64
  fi
  if [[ -z "$trusted_csv" ]]; then
    echo "classify: --trusted-authors is required (pass an explicit empty-safe value, not an omitted flag, if the trusted set is genuinely empty)" >&2
    usage
    return 64
  fi
  case "$investigate_dispatch" in
    true|false) ;;
    *) echo "classify: --investigate-dispatch must be true or false, got: $investigate_dispatch" >&2; return 64 ;;
  esac
  case "$respect_assignees" in
    true|false) ;;
    *) echo "classify: --respect-assignees must be true or false, got: $respect_assignees" >&2; return 64 ;;
  esac
  case "$milestones_enabled" in
    true|false) ;;
    *) echo "classify: --milestones-enabled must be true or false, got: $milestones_enabled" >&2; return 64 ;;
  esac
  case "$milestones_prioritize_dispatch" in
    true|false) ;;
    *) echo "classify: --milestones-prioritize-dispatch must be true or false, got: $milestones_prioritize_dispatch" >&2; return 64 ;;
  esac
  case "$recheck_probe_enabled" in
    true|false) ;;
    *) echo "classify: --recheck-probe-enabled must be true or false, got: $recheck_probe_enabled" >&2; return 64 ;;
  esac
  if [[ -z "$today" ]]; then
    today="$(date -u +%F)"
  fi
  if ! [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "classify: --today must be YYYY-MM-DD, got: $today" >&2
    return 64
  fi
  if [[ -z "$someday_recheck_days" ]]; then
    someday_recheck_days="0"
  fi
  if ! [[ "$someday_recheck_days" =~ ^[0-9]+$ ]]; then
    echo "classify: --someday-recheck-days must be a non-negative integer, got: $someday_recheck_days" >&2
    return 64
  fi

  require_jq "backlog-filter.sh"

  if ! printf '%s' "$probe_verdicts_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --probe-verdicts must be a JSON object, got: $probe_verdicts_json" >&2
    return 64
  fi

  if [[ -z "$pr_collision_verdicts_json" ]]; then
    pr_collision_verdicts_json="{}"
  fi
  if ! printf '%s' "$pr_collision_verdicts_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --pr-collision-verdicts must be a JSON object, got: $pr_collision_verdicts_json" >&2
    return 64
  fi

  if [[ -z "$sub_issues_json" ]]; then
    sub_issues_json="{}"
  fi
  if ! printf '%s' "$sub_issues_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --sub-issues must be a JSON object, got: $sub_issues_json" >&2
    return 64
  fi

  if [[ -z "$covered_by_open_pr_json" ]]; then
    covered_by_open_pr_json="{}"
  fi
  if ! printf '%s' "$covered_by_open_pr_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --closed-by-open-pr must be a JSON object, got: $covered_by_open_pr_json" >&2
    return 64
  fi

  local me_lower trusted_json healthy_json peer_json input milestone_rank_on
  me_lower=$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')
  trusted_json=$(_csv_to_json_lower_string_array "$trusted_csv")
  healthy_json=$(_csv_to_json_number_array "$healthy_csv")
  peer_json=$(_csv_to_json_number_array "$peer_csv")
  input=$(cat)

  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # Wide-fetch shape check (issue #1555). Runs BEFORE the classification jq
  # so a mis-marshalled payload fails with the offending field named, rather
  # than as a raw positional jq error from deep inside CLASSIFY_JQ.
  _validate_issues_json "$input" "classify" || return 64

  # The AND-gate itself -- milestone-aware ranking requires BOTH knobs
  # true. Either one false reproduces the pre-#1241 sort byte-for-byte
  # (see CLASSIFY_JQ's _sort_key comment above) -- this is what makes the
  # "milestones.enabled:false OR prioritize_dispatch:false -> unchanged
  # ranking" acceptance criterion hold structurally rather than by
  # convention.
  milestone_rank_on="false"
  if [[ "$milestones_enabled" == "true" && "$milestones_prioritize_dispatch" == "true" ]]; then
    milestone_rank_on="true"
  fi

  printf '%s' "$input" | jq -c \
    --arg me "$me_lower" \
    --argjson trusted "$trusted_json" \
    --argjson healthy "$healthy_json" \
    --argjson peer "$peer_json" \
    --argjson investigate_dispatch "$investigate_dispatch" \
    --arg prioritize_label "$prioritize_label" \
    --arg today "$today" \
    --argjson milestone_rank_on "$milestone_rank_on" \
    --arg symptom_re "$SYMPTOM_REGEX" \
    --argjson respect_assignees "$respect_assignees" \
    --argjson recheck_probe_enabled "$recheck_probe_enabled" \
    --argjson probe_verdicts "$probe_verdicts_json" \
    --argjson pr_collision_verdicts "$pr_collision_verdicts_json" \
    --argjson sub_issues "$sub_issues_json" \
    --argjson covered_by_open_pr "$covered_by_open_pr_json" \
    --arg someday_milestone "$someday_milestone" \
    --argjson someday_recheck_days "$someday_recheck_days" \
    --arg fallback_milestone "$fallback_milestone" \
    "$CLASSIFY_JQ"
}

# validate-issues (issue #1555) — the shape check above, exposed as its own
# subcommand so a caller can fail fast BEFORE spending the live-network
# calls that `classify-backlog.sh run` gathers on its behalf, and so the
# check itself is directly fixture-testable.
cmd_validate_issues() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      *) echo "validate-issues: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  require_jq "backlog-filter.sh"

  local input
  input=$(cat)
  if [[ -z "$input" ]]; then
    input="[]"
  fi

  _validate_issues_json "$input" "validate-issues" || return 64
  return 0
}

cmd_closed_by_healthy_pr() {
  local repo="" me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --me) me="${2:-}"; shift 2 ;;
      *) echo "closed-by-healthy-pr: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "closed-by-healthy-pr: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$me" ]]; then
    echo "closed-by-healthy-pr: --me is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "closed-by-healthy-pr: gh is required but not installed" >&2
    return 65
  fi

  # Direct `gh pr list` (not gh-batch.sh) — its GraphQL projection only
  # returns the aggregate `statusCheckRollup.state`, not the per-check
  # array this latest-per-name group-by needs. `gh pr list --json
  # statusCheckRollup` returns the real per-check array, same as every
  # other rollup walk in setup/04-backlog-divert.md and drain.md.
  gh pr list --repo "$repo" --state open --author "$me" --limit 200 \
    --json number,mergeStateStatus,statusCheckRollup,closingIssuesReferences 2>/dev/null | jq -r '
    [.[] | select(.mergeStateStatus != "DIRTY")
      | select(
        ([(.statusCheckRollup // [])
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
        ] | length) == 0
      )
      | .closingIssuesReferences[]?.number
    ] | unique | join(",")
  '
}

# cmd_closed_by_open_pr — the live-network half of the covered-by-open-PR
# drop clause (issue #1389). Deliberately a SIBLING of
# cmd_closed_by_healthy_pr, not a modification of it: that function answers
# "should this PR go in failed_prs?" and must keep doing exactly that, while
# this one answers "is this ISSUE already covered by in-flight work?" — a
# question to which the PR's check health and mergeStateStatus are simply
# irrelevant. Conflating the two is the bug #1389 documents.
cmd_closed_by_open_pr() {
  local repo="" me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --me) me="${2:-}"; shift 2 ;;
      *) echo "closed-by-open-pr: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "closed-by-open-pr: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$me" ]]; then
    echo "closed-by-open-pr: --me is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "closed-by-open-pr: gh is required but not installed" >&2
    return 65
  fi

  # `--state open` is what preserves #332's resumable-work row by
  # construction: a closed or merged-without-closing PR is never returned,
  # so its issue never enters the map and stays dispatchable. The projection
  # is deliberately narrower than cmd_closed_by_healthy_pr's — no
  # statusCheckRollup, because no health test is performed here.
  local pr_json
  pr_json=$(gh pr list --repo "$repo" --state open --author "$me" --limit 200 \
    --json number,closingIssuesReferences 2>/dev/null)
  if [[ -z "$pr_json" ]]; then
    pr_json="[]"
  fi

  # shellcheck disable=SC2016
  printf '%s' "$pr_json" | jq -c '
    [ .[] | . as $pr | (($pr.closingIssuesReferences // [])[] | {issue: .number, pr: $pr.number}) ]
    | group_by(.issue)
    | map({ (.[0].issue | tostring): (map(.pr) | min) })
    | add // {}
  '
}

# cmd_someday_recheck_write — the I/O half of the someday-recheck cadence
# (issue #1422). Kept out of `classify` for the same reason
# `closed-by-healthy-pr`/`eval-probes` are: the pure decision
# (someday_recheck_state, evaluated inside CLASSIFY_JQ) and the live GitHub
# write are different concerns, and only the write needs network access.
cmd_someday_recheck_write() {
  local repo="" someday_recheck_days="" today=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --someday-recheck-days) someday_recheck_days="${2:-}"; shift 2 ;;
      --today) today="${2:-}"; shift 2 ;;
      *) echo "someday-recheck-write: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$repo" ]]; then
    echo "someday-recheck-write: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$someday_recheck_days" ]] || ! [[ "$someday_recheck_days" =~ ^[0-9]+$ ]]; then
    echo "someday-recheck-write: --someday-recheck-days must be a non-negative integer" >&2
    usage
    return 64
  fi
  if [[ -z "$today" ]]; then
    today="$(date -u +%F)"
  fi
  if ! [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "someday-recheck-write: --today must be YYYY-MM-DD, got: $today" >&2
    return 64
  fi

  require_jq "backlog-filter.sh"

  # 0 -- mechanism disabled, mirrors classify's own posture. Still consume
  # stdin so a caller piping via `|` doesn't see a broken-pipe error.
  if [[ "$someday_recheck_days" -eq 0 ]]; then
    cat >/dev/null
    return 0
  fi

  local new_date
  # jq-based date arithmetic, not a shell `date -d`/`date -v` fallback
  # chain, and NOT bare `date`'s idea of "now" -- this must add
  # $someday_recheck_days to $today (the caller-supplied or default-derived
  # value validated above), not to whatever the wall clock reads at call
  # time, or a caller that pins --today for determinism/tests would get a
  # marker date computed off the wrong anchor. Mirrors someday_recheck_state
  # in CLASSIFY_JQ's own strptime/mktime/strftime pattern, so both halves of
  # this mechanism agree on the exact same date math.
  new_date=$(jq -rn --arg today "$today" --argjson days "$someday_recheck_days" '
    ($today | strptime("%Y-%m-%d") | mktime) as $t
    | ($t + ($days * 86400)) | strftime("%Y-%m-%d")
  ')

  local input numbers n current_body new_body
  input=$(cat)
  if [[ -z "$input" ]]; then
    return 0
  fi

  # select() on a possibly-absent field: `.someday_recheck_action ==
  # "first-park"` is false (not an error) when the field is absent, so
  # ordinary classify NDJSON lines with no such field are silently skipped
  # -- no separate `has(...)` guard needed.
  numbers=$(printf '%s\n' "$input" | jq -r 'select(.someday_recheck_action == "first-park" or .someday_recheck_action == "cheap-reset") | .number' 2>/dev/null)

  for n in $numbers; do
    if ! current_body=$(gh issue view "$n" --repo "$repo" --json body --jq '.body' 2>/dev/null); then
      echo "someday-recheck-write: WARNING: #$n could not be read — skipping marker write" >&2
      continue
    fi
    if printf '%s' "$current_body" | grep -q '<!-- do-work-someday-recheck:'; then
      new_body=$(printf '%s' "$current_body" | sed -E "s/<!-- do-work-someday-recheck: [0-9]{4}-[0-9]{2}-[0-9]{2} -->/<!-- do-work-someday-recheck: $new_date -->/")
    else
      new_body="<!-- do-work-someday-recheck: $new_date -->

$current_body"
    fi
    if [[ "$new_body" != "$current_body" ]]; then
      if ! gh issue edit "$n" --repo "$repo" --body "$new_body" >/dev/null 2>&1; then
        echo "someday-recheck-write: WARNING: #$n do-work-someday-recheck marker edit failed" >&2
      fi
    fi
  done
}

# cmd_eval_probes — the live-network precomputation half of the event-gate
# filter (issue #1356). Reads the same wide-fetch payload `classify` reads
# (only `number`/`body` matter), extracts every issue whose body carries a
# `do-work-recheck` marker, and evaluates each via
# `eval-recheck-probe.sh --bulk` (the single executable source of truth for
# marker validation + probe execution — this function never re-derives that
# logic). Kept separate from `classify` for the same reason
# `closed-by-healthy-pr` is (see the design note near the top of this file):
# the classification DECISION needs to stay a pure, fixture-testable
# function with zero network calls of its own.
cmd_eval_probes() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) echo "eval-probes: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "eval-probes: --repo is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"

  local evaluator input
  evaluator="${here}/eval-recheck-probe.sh"
  if [[ ! -f "$evaluator" ]]; then
    echo "eval-probes: eval-recheck-probe.sh not found at $evaluator" >&2
    return 65
  fi

  input=$(cat)
  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # Pre-filter to {number,body} NDJSON, restricted to issues whose body
  # actually carries a do-work-recheck marker -- avoids spawning a
  # subprocess (let alone a network probe) for the overwhelmingly common
  # case of a marker-free issue. eval-recheck-probe.sh --bulk would reach
  # the identical "absent" verdict on its own; this is purely an efficiency
  # pre-filter, not a second copy of the marker grammar (the actual
  # validation still happens exactly once, inside eval-recheck-probe.sh).
  printf '%s' "$input" | jq -c '
    .[] | select((.body // "") | test("(?m)^<!-- do-work-recheck: .+ -->$"))
        | {number, body}
  ' | bash "$evaluator" --bulk "$repo" | jq -sc '
    map({(.number | tostring): .verdict}) | add // {}
  '
}

# cmd_eval_pr_collision — the live-network precomputation half of the
# `blocked-by-in-flight-pr` self-clearing marker (issue #1429). Reads the
# same wide-fetch payload `classify` reads (only `number`/`body` matter),
# extracts every issue whose body's FIRST LINE carries a
# `do-work-blocked-by-prs: N,M` marker, and for each queries every listed
# PR's current state via a single, fixed `gh pr view <N> --json state -q
# .state` call — no arbitrary command grammar, so (unlike eval-probes /
# eval-recheck-probe.sh) there is no separate allowlist-evaluator script to
# delegate to. Verdict is "resolved" only when EVERY listed PR is MERGED or
# CLOSED; "open" otherwise, including when a query errors or returns
# anything unrecognized — the same fail-safe-to-gated posture
# eval-recheck-probe.sh documents (never treat an inconclusive read as
# proof the collision resolved). Kept separate from `classify` for the
# same reason `closed-by-healthy-pr` / `eval-probes` are: the
# classification DECISION stays a pure, fixture-testable function with
# zero network calls of its own.
cmd_eval_pr_collision() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) echo "eval-pr-collision: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "eval-pr-collision: --repo is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "eval-pr-collision: gh is required but not installed" >&2
    return 65
  fi

  local input
  input=$(cat)
  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # Pre-filter to {number, prs} pairs, restricted to issues whose body's
  # first line actually carries the marker -- same efficiency pre-filter
  # eval-probes uses, avoiding a subprocess (let alone a network call) for
  # the overwhelmingly common marker-free case. `prs` is the raw
  # comma-separated capture group; re-split in bash below rather than
  # re-deriving the marker regex a second time in jq beyond the capture
  # this line already performs.
  local pairs number prs_csv pr verdict any_open
  pairs=$(printf '%s' "$input" | jq -r '
    .[] | (.body // "") as $b
        | ($b | split("\n") | (.[0] // "")) as $first_line
        | ($first_line | capture("^<!--\\s*do-work-blocked-by-prs:\\s*(?<prs>[0-9]+(,[0-9]+)*)\\s*-->\\s*$")) as $cap
        | select($cap != null)
        | "\(.number)\t\($cap.prs)"
  ' 2>/dev/null)

  printf '{'
  local first_entry=true
  while IFS=$'\t' read -r number prs_csv; do
    [[ -z "$number" ]] && continue
    any_open=false
    IFS=',' read -ra pr_list <<<"$prs_csv"
    for pr in "${pr_list[@]}"; do
      verdict=$(gh pr view "$pr" --repo "$repo" --json state -q .state 2>/dev/null)
      case "$verdict" in
        MERGED|CLOSED) ;;
        *) any_open=true ;;
      esac
    done
    if [[ "$first_entry" == "true" ]]; then
      first_entry=false
    else
      printf ','
    fi
    if [[ "$any_open" == "true" ]]; then
      printf '"%s":"open"' "$number"
    else
      printf '"%s":"resolved"' "$number"
    fi
  done <<<"$pairs"
  printf '}\n'
}

# cmd_sub_issues — the live-network precomputation half of the `tracking`
# provisional gate's STRUCTURED justification signal (issue #1556). Reads
# the same wide-fetch payload `classify` reads (only `number`/`labels`
# matter), and for every issue carrying the `tracking` label queries its
# GitHub sub-issue graph. Kept separate from `classify` for the same reason
# `closed-by-healthy-pr` / `eval-probes` / `eval-pr-collision` are: the
# classification DECISION stays a pure, fixture-testable function with zero
# network calls of its own.
#
# Cost is near zero on a normal backlog: the pre-filter means only
# `tracking`-labeled issues are queried at all, and that set is typically
# tiny (often empty, in which case not a single GraphQL call is made).
#
# Fail-safe posture: any failure for a given issue — the API erroring, the
# `subIssues` connection being unavailable on this GitHub deployment, a
# malformed response — contributes NO key, which makes
# has_tracking_justification fall through to its body-prose signals, i.e.
# exactly the pre-#1556 behavior for that issue. A missing read never
# fabricates a justification.
cmd_sub_issues() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) echo "sub-issues: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "sub-issues: --repo is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "sub-issues: gh is required but not installed" >&2
    return 65
  fi

  local owner name input numbers n nodes first_entry
  owner="${repo%%/*}"
  name="${repo##*/}"
  if [[ -z "$owner" || -z "$name" || "$owner" == "$repo" ]]; then
    echo "sub-issues: --repo must be owner/name, got: $repo" >&2
    return 64
  fi

  input=$(cat)
  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # Pre-filter to `tracking`-labeled issue numbers only -- the same
  # efficiency pre-filter eval-probes / eval-pr-collision use, avoiding a
  # network call for every issue that could not possibly reach the
  # tracking-justification branch in the first place. Label matching is
  # case-insensitive, mirroring matches_gate_label's own `lower` normalization.
  numbers=$(printf '%s' "$input" | jq -r '
    .[] | select((((.labels // []) | map(ascii_downcase)) | index("tracking")) != null) | .number
  ' 2>/dev/null)

  printf '{'
  first_entry=true
  for n in $numbers; do
    [[ -z "$n" ]] && continue
    # The $owner/$name/$number tokens below are GraphQL variables bound by
    # the -F flags, NOT shell variables -- single quotes are required.
    # shellcheck disable=SC2016
    nodes=$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){subIssues(first:50){nodes{number state}}}}}' \
      -F owner="$owner" -F name="$name" -F number="$n" \
      --jq '.data.repository.issue.subIssues.nodes' 2>/dev/null)
    [[ -z "$nodes" ]] && continue
    # Non-array, empty, or otherwise unusable -> no key, never a fabricated
    # one. An issue with zero sub-issues is NOT a justification.
    nodes=$(printf '%s' "$nodes" | jq -c '
      if type == "array"
      then map(select((type == "object") and (.number != null)) | {number, state})
      else [] end
    ' 2>/dev/null)
    [[ -z "$nodes" ]] && continue
    if ! printf '%s' "$nodes" | jq -e 'length > 0' >/dev/null 2>&1; then
      continue
    fi
    if [[ "$first_entry" == "true" ]]; then
      first_entry=false
    else
      printf ','
    fi
    printf '"%s":%s' "$n" "$nodes"
  done
  printf '}\n'
}

# cmd_summary — the unfiltered_open_count / me_assigned_open invariant-line
# tokens (issue #1246). Reads the same wide-fetch payload `classify` reads,
# BEFORE classification runs, so a regression in the classifier itself is
# visible as a "raw_backlog=0 but unfiltered_open_count=29" divergence
# rather than silently indistinguishable from a genuinely empty backlog.
cmd_summary() {
  local me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --me) me="${2:-}"; shift 2 ;;
      *) echo "summary: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$me" ]]; then
    echo "summary: --me is required" >&2
    usage
    return 64
  fi

  require_jq "backlog-filter.sh"

  local me_lower input
  me_lower=$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')
  input=$(cat)

  if [[ -z "$input" ]]; then
    input="[]"
  fi

  printf '%s' "$input" | jq -c --arg me "$me_lower" '
    {
      unfiltered_open_count: length,
      me_assigned_open:
        (map(select(((.assignees // []) | map(ascii_downcase)) | index($me) != null))
         | length)
    }
  '
}

main() {
  local sub="${1:-}"
  case "$sub" in
    classify)
      shift
      cmd_classify "$@"
      ;;
    validate-issues)
      shift
      cmd_validate_issues "$@"
      ;;
    closed-by-healthy-pr)
      shift
      cmd_closed_by_healthy_pr "$@"
      ;;
    closed-by-open-pr)
      shift
      cmd_closed_by_open_pr "$@"
      ;;
    someday-recheck-write)
      shift
      cmd_someday_recheck_write "$@"
      ;;
    eval-probes)
      shift
      cmd_eval_probes "$@"
      ;;
    eval-pr-collision)
      shift
      cmd_eval_pr_collision "$@"
      ;;
    sub-issues)
      shift
      cmd_sub_issues "$@"
      ;;
    summary)
      shift
      cmd_summary "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "backlog-filter.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"
exit $?
