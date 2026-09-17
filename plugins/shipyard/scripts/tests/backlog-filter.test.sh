#!/usr/bin/env bash
# Test suite for scripts/backlog-filter.sh (issue #1247).
#
# backlog-filter.sh is the single, fixture-testable implementation of
# /shipyard:do-work's backlog eligibility filter -- the predicate that used
# to be re-derived from prose at three independent call-sites
# (setup/04-backlog-divert.md step 4, steady-state.md step C, drain.md's
# termination-assertion step 4) and drifted twice as a result (#332, #1194),
# plus a third divergence caught in the spec text itself (the since-retired
# needs-triage label,
# classified as a drop at two call-sites and a route at the third).
#
# This suite exercises `classify` almost exclusively -- `closed-by-healthy-pr`
# and its #1389 sibling `closed-by-open-pr` both perform live `gh` network
# calls by design (see the script's own header comment for why that split
# exists) and are not fixture-tested here; their bad-usage paths are covered,
# their network paths are not. The classification DECISION each one feeds --
# which is the part that has actually drifted historically -- is fully
# covered below, including all four rows of #1389's PR-state table. The one
# exception is #1556's `sub-issues` producer, whose tracking-only pre-filter
# and fail-safe-to-no-key behavior ARE covered, against a PATH-prepended gh
# stub (the same mocking pattern classify-backlog.test.sh uses).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/backlog-filter.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../backlog-filter.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed -- backlog-filter.sh requires it" >&2
  exit 0
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

# verdict_of <ndjson> <number> -- extract "verdict" (or "verdict:reason")
# for a given issue number out of classify's NDJSON stdout.
verdict_of() {
  local ndjson="$1" number="$2"
  printf '%s\n' "$ndjson" | jq -r --argjson n "$number" '
    select(.number == $n) | if (.reason // "") == "" then .verdict else (.verdict + ":" + .reason) end
  '
}

# order_of <ndjson> -- newline list of issue numbers in output order.
order_of() {
  local ndjson="$1"
  printf '%s\n' "$ndjson" | jq -r '.number'
}

# field_of <ndjson> <number> <field> -- extract an arbitrary field for a
# given issue number out of classify's NDJSON stdout (empty string when the
# field is absent). Used for `evidence_pointer` -- issue #1364 -- which
# verdict_of's verdict:reason concatenation never surfaces.
field_of() {
  local ndjson="$1" number="$2" field="$3"
  printf '%s\n' "$ndjson" | jq -r --argjson n "$number" --arg f "$field" '
    select(.number == $n) | .[$f] // ""
  '
}

classify() {
  bash "$helper" classify --me "test-me" --trusted-authors "alice,bob" --today "2026-08-11" "$@"
}

echo "backlog-filter.sh tests (issue #1247)"
echo

# --- bad usage -------------------------------------------------------------

out=$(bash "$helper" classify </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --me exits 64"
assert_contains "$out" "--me is required" "(1) missing --me explains why"

out=$(bash "$helper" classify --me x </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(2) missing --trusted-authors exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --investigate-dispatch maybe </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(3) invalid --investigate-dispatch exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --today "not-a-date" </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(4) invalid --today exits 64"

out=$(bash "$helper" bogus-subcommand 2>&1); rc=$?
assert_equals "$rc" "64" "(5) unknown subcommand exits 64"

out=$(bash "$helper" 2>&1); rc=$?
assert_equals "$rc" "64" "(6) no subcommand exits 64"

out=$(bash "$helper" --help 2>&1); rc=$?
assert_equals "$rc" "0" "(7) --help exits 0"

out=$(bash "$helper" closed-by-healthy-pr 2>&1); rc=$?
assert_equals "$rc" "64" "(8) closed-by-healthy-pr missing --repo exits 64"

out=$(bash "$helper" closed-by-healthy-pr --repo acme/widgets 2>&1); rc=$?
assert_equals "$rc" "64" "(9) closed-by-healthy-pr missing --me exits 64"

out=$(bash "$helper" summary </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(9a) summary missing --me exits 64"
assert_contains "$out" "--me is required" "(9a) summary missing --me explains why"

# --- empty input -------------------------------------------------------------

out=$(printf '%s' '[]' | classify); rc=$?
assert_equals "$rc" "0" "(10) empty array exits 0"
assert_equals "$out" "" "(10) empty array emits nothing"

# --- #1194 regression: assignee handling ------------------------------------
# The regression: a shorthand like "drop issues with no assignee" (or
# "--assignee @me" as a required filter) is NOT the same predicate as "drop
# issues assigned to someone OTHER than @me". Self-assigned issues, and
# unassigned issues, must both pass; only other-assigned issues drop.

fixture_assignees='[
  {"number":101,"title":"unassigned","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":102,"title":"self-assigned","body":"","labels":[],"assignees":["test-me"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":103,"title":"other-assigned","body":"","labels":[],"assignees":["someone-else"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":104,"title":"self-plus-other","body":"","labels":[],"assignees":["test-me","someone-else"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_assignees" | classify)
assert_equals "$(verdict_of "$out" 101)" "eligible" "(11) #1194: unassigned issue is eligible"
assert_equals "$(verdict_of "$out" 102)" "eligible" "(12) #1194: self-assigned (@me) issue is eligible -- the resumable-work case"
assert_equals "$(verdict_of "$out" 103)" "drop:assigned-other" "(13) #1194: other-assigned issue drops"
assert_equals "$(verdict_of "$out" 104)" "eligible" "(14) #1194: self+other assigned issue is still eligible (me is among assignees)"

# --- #1248: --respect-assignees gates the assigned-other clause -------------
# When the flag is omitted entirely, the script defaults to "true" (preserves
# the #1194-fixed predicate above for any caller that hasn't been updated
# yet). Real callers (setup.md step 4, steady-state.md step C, drain.md's
# termination assertion) always pass the resolved `backlog.respect_assignees`
# config value explicitly -- config default is "false".

out=$(printf '%s' "$fixture_assignees" | classify --respect-assignees true)
assert_equals "$(verdict_of "$out" 103)" "drop:assigned-other" "(14a) #1248: explicit --respect-assignees true reproduces the #1194 predicate"

out=$(printf '%s' "$fixture_assignees" | classify --respect-assignees false)
assert_equals "$(verdict_of "$out" 101)" "eligible" "(14b) #1248: --respect-assignees false -- unassigned issue is eligible"
assert_equals "$(verdict_of "$out" 102)" "eligible" "(14c) #1248: --respect-assignees false -- self-assigned issue is eligible"
assert_equals "$(verdict_of "$out" 103)" "eligible" "(14d) #1248: --respect-assignees false -- other-assigned issue is ALSO eligible (the clause never runs)"
assert_equals "$(verdict_of "$out" 104)" "eligible" "(14e) #1248: --respect-assignees false -- self-plus-other assigned issue is eligible"

out=$(bash "$helper" classify --me x --trusted-authors a --respect-assignees maybe </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(14f) #1248: invalid --respect-assignees exits 64"

# --- #332 regression: closed-PR does not lock the issue ---------------------
# The regression: excluding every issue that ever had ANY linked PR
# (including closed/abandoned ones) erased resumable work. This filter
# only drops on --closed-by-healthy-pr membership (an OPEN, healthy PR) --
# an issue with no entry in that set is eligible regardless of whether it
# had a prior, now-closed PR (the caller simply never puts a closed PR's
# issue numbers into that set to begin with).

fixture_closed_pr='[{"number":201,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_closed_pr" | classify)
assert_equals "$(verdict_of "$out" 201)" "eligible" "(15) #332: issue with no entry in closed-by-healthy-pr set is eligible (a prior closed PR does not lock it)"

out=$(printf '%s' "$fixture_closed_pr" | classify --closed-by-healthy-pr 201)
assert_equals "$(verdict_of "$out" 201)" "drop:closed-by-healthy-pr" "(16) closed-by-healthy-pr membership drops the issue"

# --- #1389: an issue covered by an OPEN-but-UNHEALTHY PR must also drop ----
# The bug: the "healthy" qualifier on the clause above answers "should this
# PR go in failed_prs?" -- a question about the PR -- and was being reused to
# answer "should this issue go in raw_backlog?", where health is irrelevant.
# An issue whose open @me PR names it in closingIssuesReferences is COVERED
# whether that PR is green, red, or DIRTY; dispatching an issue-worker at it
# can only bail. The four rows of the issue's own table are pinned below,
# one assertion each, so a regression on any single row fails loudly.
#
# Row shapes, expressed as set membership (the health determination itself
# lives in the producing subcommands, not in this pure classifier):
#   open + healthy  -> number in BOTH the healthy set and the covered map
#   open + red      -> number in the covered map only
#   open + DIRTY    -> number in the covered map only
#   closed/abandoned-> number in NEITHER (the subcommand queries --state open)

fixture_open_pr='[
  {"number":211,"title":"open+healthy","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":212,"title":"open+red","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":213,"title":"open+DIRTY","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":214,"title":"closed/abandoned PR","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'

out=$(printf '%s' "$fixture_open_pr" | classify \
  --closed-by-healthy-pr 211 \
  --closed-by-open-pr '{"211":901,"212":902,"213":903}')

# Row 1 -- unchanged behavior. The covered map is a strict SUPERSET of the
# healthy set, so #211 is in both; the healthy clause is evaluated first on
# purpose, so its verdict string stays byte-identical to pre-#1389 output
# and every existing consumer of `closed-by-healthy-pr` is unaffected.
assert_equals "$(verdict_of "$out" 211)" "drop:closed-by-healthy-pr" "(16a) #1389: open+healthy row keeps emitting closed-by-healthy-pr verbatim (covered map does not relabel it)"
assert_equals "$(field_of "$out" 211 "evidence_pointer")" "" "(16b) #1389: the healthy row carries no evidence_pointer (its output shape is unchanged)"

# Row 2 -- newly dropped. Was dispatchable before #1389; the #1389 repro
# burned a full worker dispatch (~162k tokens) reaching issue-work.md step
# 0's own duplicate-PR bail on exactly this shape.
assert_equals "$(verdict_of "$out" 212)" "drop:covered-by-open-pr" "(16c) #1389: open+RED PR covers its issue -- drops as covered-by-open-pr, not eligible"
assert_equals "$(field_of "$out" 212 "evidence_pointer")" "PR #902 closingIssuesReferences includes #212" "(16d) #1389: the covered drop cites the covering PR by number"

# Row 3 -- newly dropped. A DIRTY PR is fix-rebase work on the PR, never
# workable issue-work on the issue.
assert_equals "$(verdict_of "$out" 213)" "drop:covered-by-open-pr" "(16e) #1389: open+DIRTY PR covers its issue -- drops as covered-by-open-pr, not eligible"
assert_equals "$(field_of "$out" 213 "evidence_pointer")" "PR #903 closingIssuesReferences includes #213" "(16f) #1389: the DIRTY row's evidence_pointer names its own covering PR"

# Row 4 -- MUST NOT regress. This is #332's resumable-work case: a
# closed/abandoned PR does not lock its issue. Preserved by construction
# (the producing subcommand queries --state open only), pinned here anyway.
assert_equals "$(verdict_of "$out" 214)" "eligible" "(16g) #1389/#332: an issue whose linked PR is closed/abandoned appears in NEITHER set and stays dispatchable"

# The flag is opt-in: omitting it entirely reproduces pre-#1389 behavior
# byte-for-byte, so no existing caller changes verdict without opting in.
out=$(printf '%s' "$fixture_open_pr" | classify --closed-by-healthy-pr 211)
assert_equals "$(verdict_of "$out" 212)" "eligible" "(16h) #1389: with --closed-by-open-pr omitted, the clause never fires (default {} is byte-identical to pre-#1389)"
assert_equals "$(verdict_of "$out" 213)" "eligible" "(16i) #1389: default {} leaves the DIRTY row eligible too -- the new drop requires an explicit opt-in map"

# An explicit empty map is the same as omitting the flag.
out=$(printf '%s' "$fixture_open_pr" | classify --closed-by-open-pr '{}')
assert_equals "$(verdict_of "$out" 212)" "eligible" "(16j) #1389: an explicit empty --closed-by-open-pr map drops nothing"

# The covered clause is a DROP, not a gate -- it must not leak into the
# eligible bucket's ranked prefix, and the eligible rows must still lead.
out=$(printf '%s' "$fixture_open_pr" | classify --closed-by-open-pr '{"212":902,"213":903}')
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "211,214,212,213" "(16k) #1389: covered drops sort into the audit-trail tail, after every eligible line"

out=$(bash "$helper" classify --me x --trusted-authors a --closed-by-open-pr '[1,2]' </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(16l) #1389: a non-object --closed-by-open-pr value exits 64"

out=$(bash "$helper" closed-by-open-pr 2>&1); rc=$?
assert_equals "$rc" "64" "(16m) #1389: closed-by-open-pr missing --repo exits 64"

out=$(bash "$helper" closed-by-open-pr --repo acme/widgets 2>&1); rc=$?
assert_equals "$rc" "64" "(16n) #1389: closed-by-open-pr missing --me exits 64"

assert_contains "$(bash "$helper" --help 2>&1)" "closed-by-open-pr --repo" "(16o) #1389: --help documents the closed-by-open-pr subcommand"

# --- needs-triage is RETIRED and fully inert (#1120) -------------------------
# The label was investigate mode's original entry signal, kept as an
# accepted-but-not-required trigger through #1090's migration window, and
# retired outright in #1120 once entry no longer depended on it. It must now
# be treated as an ordinary free-form tag: it neither routes an issue to
# investigate nor gates/drops it. An issue carrying it with an ordinary body
# is just an ordinary dispatch candidate.
#
# This guards both directions of the retirement. If the label were still a
# route, (17) fails. If it were ever ADDED to the gate-label drop enumeration
# (the old steady-state.md/drain.md prose contradiction), (17) fails too.

fixture_triage='[{"number":301,"title":"t","body":"ordinary body","labels":["needs-triage"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_triage" | classify)
assert_equals "$(verdict_of "$out" 301)" "eligible" "(17) #1120: retired needs-triage label is inert — ordinary candidate, neither routed nor dropped"

out=$(printf '%s' "$fixture_triage" | classify --investigate-dispatch false)
assert_equals "$(verdict_of "$out" 301)" "eligible" "(18) #1120: retired needs-triage label stays inert even when triage.investigate_dispatch is false"

# A genuinely symptom-shaped body still routes to investigate with no label
# at all — the signal that replaced the label.
fixture_symptom='[{"number":302,"title":"t","body":"Traceback (most recent call last):\n  File x","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_symptom" | classify)
assert_equals "$(verdict_of "$out" 302)" "route:investigate" "(18b) #1120: symptom-shaped body routes to investigate with no label"

# --- agent-console is a route, not a drop -----------------------------------

fixture_console='[{"number":401,"title":"t","body":"","labels":["agent-console"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_console" | classify)
assert_equals "$(verdict_of "$out" 401)" "route:operator" "(19) agent-console labeled issue routes to operator, never a plain drop"

# --- dispatch-gate labels ----------------------------------------------------

fixture_gates='[
  {"number":501,"title":"t","body":"","labels":["blocked:ci"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":502,"title":"t","body":"","labels":["wontfix"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":503,"title":"t","body":"","labels":["discussion"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":504,"title":"t","body":"","labels":["needs-human-review"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":505,"title":"t","body":"","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_gates" | classify)
assert_equals "$(verdict_of "$out" 501)" "gate:blocked:ci" "(20) blocked:ci gates"
assert_equals "$(verdict_of "$out" 502)" "gate:wontfix" "(21) wontfix gates"
assert_equals "$(verdict_of "$out" 503)" "gate:discussion" "(22) discussion gates"
assert_equals "$(verdict_of "$out" 504)" "gate:needs-human-review" "(23) needs-human-review gates"
assert_equals "$(verdict_of "$out" 505)" "gate:tracking-unjustified" "(24) tracking with no content-sourced signal in the body gates as tracking-unjustified, not a plain silent tracking drop (#1364)"
assert_equals "$(field_of "$out" 505 "evidence_pointer")" "" "(24a) tracking-unjustified carries no evidence_pointer -- there is nothing to cite"

# --- #1364: tracking is a PROVISIONAL gate -- it requires a content-sourced --
# justification, unlike the other four (settled, intentional) gate labels
# above. Absence of a recognized human-owned signal in the body must not
# silently drop the issue under the plain "tracking" reason -- it surfaces
# as "tracking-unjustified" instead (asserted above). Presence of any of the
# three recognized signals (a "Decision required" heading, an "Options"
# heading, or a "Blocked by #N" reference) keeps the plain "tracking" reason
# AND records the matched signal as evidence_pointer, mirroring the
# deferred_issues evidence_pointer convention -- a content-sourced citation
# string, not a bare label-presence assertion.

fixture_tracking_justified='[
  {"number":701,"title":"t","body":"## Decision required\nsome text below the heading","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":702,"title":"t","body":"## Options\n1. do A\n2. do B","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":703,"title":"t","body":"Ship after triage. Blocked by #88 pending release.","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":704,"title":"t","body":"Just tracking this for visibility, nothing more.","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_tracking_justified" | classify)
assert_equals "$(verdict_of "$out" 701)" "gate:tracking" "(24b) tracking + Decision-required heading gates as plain tracking (justified)"
assert_contains "$(field_of "$out" 701 "evidence_pointer")" "Decision-required heading" "(24b) evidence_pointer cites the Decision-required heading"
assert_equals "$(verdict_of "$out" 702)" "gate:tracking" "(24c) tracking + Options heading gates as plain tracking (justified)"
assert_contains "$(field_of "$out" 702 "evidence_pointer")" "Options heading" "(24c) evidence_pointer cites the Options heading"
assert_equals "$(verdict_of "$out" 703)" "gate:tracking" "(24d) tracking + a Blocked by #N reference gates as plain tracking (justified)"
assert_contains "$(field_of "$out" 703 "evidence_pointer")" "Blocked by #88" "(24d) evidence_pointer cites the matched Blocked-by reference"
assert_equals "$(verdict_of "$out" 704)" "gate:tracking-unjustified" "(24e) tracking + a body with no recognized signal gates as tracking-unjustified even though non-empty"
assert_equals "$(field_of "$out" 704 "evidence_pointer")" "" "(24e) evidence_pointer stays absent on the unjustified case"

# --- #1556: the tracking signal list gains the GitHub sub-issue graph ------
# (the one STRUCTURED signal, and the definitional case for the label) plus
# a body task-list of issue references (the pre-sub-issues way of expressing
# the same decomposition). Before #1556 a correctly-decomposed epic with a
# real sub-issue graph but no recognized prose signal in its body surfaced
# as `tracking-unjustified` -- an anomaly channel firing on a healthy epic
# -- while an issue that merely happened to carry an "Options" heading
# passed clean. The repro was mattsears18/lightwork#4688 (four phases,
# #4698-#4701), which flipped to a justified gate after a one-line
# `Blocked by #4701` body edit that changed nothing about its actual nature.

# The #4688 shape verbatim: a long technical brief, no Decision-required
# heading, no Options heading, no Blocked-by reference -- justified purely
# by its sub-issue graph.
fixture_subissues='[
  {"number":4688,"title":"t","body":"A long technical brief. Rewrite occurrence generation as field-based date math, widen the schema, ship the UI, then raise the support floor.","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":4689,"title":"t","body":"Same brief, but nothing in the sub-issue map for this one.","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":4690,"title":"t","body":"An empty sub-issue array is NOT a justification.","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
subs_4688='{"4688":[{"number":4698,"state":"CLOSED"},{"number":4699,"state":"CLOSED"},{"number":4700,"state":"CLOSED"},{"number":4701,"state":"OPEN"}],"4690":[]}'
out=$(printf '%s' "$fixture_subissues" | classify --sub-issues "$subs_4688")
assert_equals "$(verdict_of "$out" 4688)" "gate:tracking" "(24f) tracking + a populated GitHub sub-issue graph gates as plain tracking (justified) even with zero prose signals in the body (#1556)"
assert_equals "$(field_of "$out" 4688 "evidence_pointer")" "4 sub-issues (#4698, #4699, #4700, #4701); 1 open" "(24f) evidence_pointer names the sub-issue count, the numbers, and how many are open"
assert_equals "$(verdict_of "$out" 4689)" "gate:tracking-unjustified" "(24g) an issue absent from the sub-issue map still gates as tracking-unjustified -- a missing read never fabricates a justification"
assert_equals "$(verdict_of "$out" 4690)" "gate:tracking-unjustified" "(24h) an EMPTY sub-issue array is not a justification -- zero sub-issues means the label is still doing all the work"

# Backward compatibility: the exact same fixture, with --sub-issues omitted
# entirely, reproduces pre-#1556 behavior byte-for-byte.
out=$(printf '%s' "$fixture_subissues" | classify)
assert_equals "$(verdict_of "$out" 4688)" "gate:tracking-unjustified" "(24i) omitting --sub-issues reproduces pre-#1556 behavior (default {} -- no entry for any issue)"

# Precedence: the structured signal outranks every prose signal, so an issue
# carrying BOTH cites the sub-issue graph.
fixture_subissue_precedence='[
  {"number":4691,"title":"t","body":"## Options\n1. do A\n2. do B","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_subissue_precedence" | classify --sub-issues '{"4691":[{"number":9,"state":"OPEN"}]}')
assert_equals "$(field_of "$out" 4691 "evidence_pointer")" "1 sub-issue (#9); 1 open" "(24j) the structured sub-issue signal outranks the prose signals, and singular is not pluralized"

# The sub-issue signal is scoped to the `tracking` gate alone -- an entry in
# the map for a non-tracking issue changes nothing about its verdict.
fixture_subissue_scope='[
  {"number":4692,"title":"fix: ordinary work","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_subissue_scope" | classify --sub-issues '{"4692":[{"number":9,"state":"OPEN"}]}')
assert_equals "$(verdict_of "$out" 4692)" "eligible" "(24k) --sub-issues is consumed ONLY by the tracking gate -- a non-tracking issue with sub-issues stays eligible"

# Task-list of issue references -- the pre-sub-issues decomposition shape,
# still common in older epics. Ranked LAST, so it can never displace an
# evidence_pointer one of the three original prose signals already emitted.
fixture_tasklist='[
  {"number":4693,"title":"t","body":"Phases:\n\n- [x] #11\n- [ ] #12\n","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":4694,"title":"t","body":"* [ ] https://github.com/o/r/issues/99 ship it","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":4695,"title":"t","body":"## Options\n\n- [ ] #77","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":4696,"title":"t","body":"A plain bullet list is not a task list:\n\n- #11\n- #12\n","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_tasklist" | classify)
assert_equals "$(verdict_of "$out" 4693)" "gate:tracking" "(24l) tracking + a body task-list of issue references gates as plain tracking (justified) (#1556)"
assert_equals "$(field_of "$out" 4693 "evidence_pointer")" "Task-list issue reference #11 in body" "(24l) evidence_pointer cites the first task-list reference"
assert_equals "$(verdict_of "$out" 4694)" "gate:tracking" "(24m) the task-list signal also accepts a full issue URL in place of the #N token"
assert_contains "$(field_of "$out" 4694 "evidence_pointer")" "#99" "(24m) evidence_pointer cites the URL-form reference number"
assert_equals "$(field_of "$out" 4695 "evidence_pointer")" "Options heading in body" "(24n) the task-list signal ranks LAST -- an issue carrying an Options heading too still cites the heading, unchanged from pre-#1556"
assert_equals "$(verdict_of "$out" 4696)" "gate:tracking-unjustified" "(24o) a plain bullet list of issue references (no checkbox) is NOT a task list and does not justify the gate"

# --- #1556: `sub-issues` bad-usage paths ------------------------------------

out=$(bash "$helper" sub-issues </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(24p) sub-issues missing --repo exits 64"
assert_contains "$out" "--repo is required" "(24p) sub-issues missing --repo explains why"

out=$(bash "$helper" sub-issues --repo not-a-slug </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(24q) sub-issues rejects a --repo that is not owner/name"

out=$(bash "$helper" classify --me x --trusted-authors a --sub-issues 'not-json' </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(24r) classify --sub-issues must be a JSON object"

# --- #1556: the `sub-issues` producer, against a stubbed gh -----------------
# Unlike closed-by-healthy-pr / closed-by-open-pr (whose network paths are
# deliberately uncovered here), this producer carries real logic worth
# pinning: the tracking-only pre-filter, and the fail-safe that turns any
# unusable read into NO key rather than a fabricated justification. Mocked
# via a PATH-prepended gh stub, the same pattern classify-backlog.test.sh
# uses. Skipped entirely if mktemp is unavailable.

SUBS_WORK="$(mktemp -d 2>/dev/null || true)"
if [[ -n "$SUBS_WORK" && -d "$SUBS_WORK" ]]; then
  mkdir -p "${SUBS_WORK}/bin"
  cat > "${SUBS_WORK}/bin/gh" <<'SUBSMOCK'
#!/usr/bin/env bash
# Stub for `gh api graphql ... -F number=<N> --jq ...`: answers per issue
# number so the producer's per-issue branches are all reachable.
num=""
for a in "$@"; do
  case "$a" in number=*) num="${a#number=}" ;; esac
done
case "$num" in
  4688) echo '[{"number":4698,"state":"CLOSED"},{"number":4701,"state":"OPEN"}]' ;;
  4690) echo '[]' ;;
  4697) exit 1 ;;
  *)    echo '[]' ;;
esac
SUBSMOCK
  chmod +x "${SUBS_WORK}/bin/gh"

  fixture_producer='[
    {"number":4688,"title":"t","body":"","labels":["Tracking"],"assignees":[],"author":{"login":"alice"}},
    {"number":4690,"title":"t","body":"","labels":["tracking"],"assignees":[],"author":{"login":"alice"}},
    {"number":4697,"title":"t","body":"","labels":["tracking"],"assignees":[],"author":{"login":"alice"}},
    {"number":4699,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"}}
  ]'
  out=$(printf '%s' "$fixture_producer" | PATH="${SUBS_WORK}/bin:${PATH}" bash "$helper" sub-issues --repo o/r 2>/dev/null)
  assert_equals "$out" '{"4688":[{"number":4698,"state":"CLOSED"},{"number":4701,"state":"OPEN"}]}' "(24s) sub-issues emits one key per tracking issue with a populated graph -- label match is case-insensitive, an empty graph (#4690) and a failed read (#4697) contribute no key, and a non-tracking issue (#4699) is never queried at all"

  out=$(printf '[{"number":1,"labels":[]}]' | PATH="${SUBS_WORK}/bin:${PATH}" bash "$helper" sub-issues --repo o/r 2>/dev/null)
  assert_equals "$out" "{}" "(24t) sub-issues emits an empty OBJECT (not an empty string) when no issue carries the tracking label -- so --sub-issues \"\$(...)\" composes directly"

  out=$(printf '' | PATH="${SUBS_WORK}/bin:${PATH}" bash "$helper" sub-issues --repo o/r 2>/dev/null)
  assert_equals "$out" "{}" "(24u) sub-issues emits {} on empty stdin"

  rm -rf "$SUBS_WORK"
fi

# --- untrusted author ---------------------------------------------------------

fixture_untrusted='[{"number":601,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"mallory"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_untrusted" | classify)
assert_equals "$(verdict_of "$out" 601)" "drop:untrusted-author" "(25) untrusted author drops -- checked before every other clause"

fixture_untrusted_case='[{"number":602,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"ALICE"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_untrusted_case" | classify)
assert_equals "$(verdict_of "$out" 602)" "eligible" "(26) author-login match is case-insensitive"

# --- peer-claimed --------------------------------------------------------------

fixture_peer='[{"number":701,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_peer" | classify --peer-claimed "701")
assert_equals "$(verdict_of "$out" 701)" "drop:peer-claimed" "(27) peer-claimed number drops"

out=$(printf '%s' "$fixture_peer" | classify --peer-claimed "999")
assert_equals "$(verdict_of "$out" 701)" "eligible" "(28) not-claimed number is unaffected by an unrelated peer-claimed set"

# --- Blocked by #N still-open --------------------------------------------------

fixture_blocked='[
  {"number":801,"title":"blocker","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":802,"title":"blocked","body":"Blocked by #801","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":803,"title":"blocked-by-absent","body":"Blocked by #99999","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_blocked" | classify)
assert_equals "$(verdict_of "$out" 802)" "drop:blocked-by-open-issue" "(29) Blocked by #N drops when #N is present in the open payload"
assert_equals "$(verdict_of "$out" 803)" "eligible" "(30) Blocked by #N does not drop when #N is absent from the open payload (closed/unknown)"

# --- time-gate ------------------------------------------------------------------

fixture_timegate='[
  {"number":901,"title":"t","body":"<!-- do-work-blocked-until: 2099-01-01 -->\nrest of body","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":902,"title":"t","body":"<!-- do-work-blocked-until: 2000-01-01 -->\nrest of body","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":903,"title":"t","body":"some text\n<!-- do-work-blocked-until: 2099-01-01 -->","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":904,"title":"t","body":"<!-- do-work-blocked-until: not-a-date -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":905,"title":"t","body":"no marker at all","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_timegate" | classify)
assert_equals "$(verdict_of "$out" 901)" "drop:time-gated" "(31) future do-work-blocked-until on line 1 drops"
assert_equals "$(verdict_of "$out" 902)" "eligible" "(32) past do-work-blocked-until on line 1 is eligible -- self-clearing"
assert_equals "$(verdict_of "$out" 903)" "eligible" "(33) marker NOT on line 1 is not live -- position discipline"
assert_equals "$(verdict_of "$out" 904)" "eligible" "(34) unparseable date on line 1 fails open -- not blocked"
assert_equals "$(verdict_of "$out" 905)" "eligible" "(35) no marker at all is unaffected"

# --- event-gate: do-work-recheck marker (issue #1356) -----------------------
# A do-work-recheck marker alongside do-work-blocked-until switches the
# issue from TIME-gated (calendar decides) to EVENT-gated (the probe
# verdict decides, regardless of the calendar). This is the fix for the
# churn loop #1356 describes: an unresolved event gate must never silently
# re-admit itself just because a placeholder date elapsed.

fixture_eventgate_future_unknown='[{"number":2001,"title":"t","body":"<!-- do-work-blocked-until: 2099-01-01 -->\n<!-- do-work-recheck: npm-view foo version == 1.0.0 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_future_unknown" | classify)
assert_equals "$(verdict_of "$out" 2001)" "drop:event-gated" "(35a) event-gated issue with no --probe-verdicts entry (defaults unknown) drops as event-gated, not time-gated"

fixture_eventgate_changed='[{"number":2002,"title":"t","body":"<!-- do-work-blocked-until: 2099-01-01 -->\n<!-- do-work-recheck: npm-view foo version == 1.0.0 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_changed" | classify --probe-verdicts '{"2002":"changed"}')
assert_equals "$(verdict_of "$out" 2002)" "eligible" "(35b) event-gated issue with probe verdict changed is eligible even though blocked-until is still in the future"

fixture_eventgate_elapsed_unchanged='[{"number":2003,"title":"t","body":"<!-- do-work-blocked-until: 2000-01-01 -->\n<!-- do-work-recheck: npm-view foo version == 1.0.0 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_elapsed_unchanged" | classify --probe-verdicts '{"2003":"unchanged"}')
assert_equals "$(verdict_of "$out" 2003)" "drop:event-gated" "(35c) #1356 churn-loop fix: event-gated issue whose blocked-until date already ELAPSED still drops when the probe reports unchanged -- never silently re-admitted by the calendar alone"

out=$(printf '%s' "$fixture_eventgate_elapsed_unchanged" | classify --probe-verdicts '{"2003":"unknown"}')
assert_equals "$(verdict_of "$out" 2003)" "drop:event-gated" "(35d) same as above with an explicit unknown verdict"

fixture_eventgate_disabled='[{"number":2004,"title":"t","body":"<!-- do-work-blocked-until: 2000-01-01 -->\n<!-- do-work-recheck: npm-view foo version == 1.0.0 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_disabled" | classify --recheck-probe-enabled false)
assert_equals "$(verdict_of "$out" 2004)" "eligible" "(35e) --recheck-probe-enabled false ignores the do-work-recheck marker entirely -- falls back to plain calendar (elapsed date => eligible)"

fixture_eventgate_marker_anywhere='[{"number":2005,"title":"t","body":"some preceding text\n<!-- do-work-recheck: npm-view foo version == 1.0.0 -->\nmore text","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_marker_anywhere" | classify --probe-verdicts '{"2005":"changed"}')
assert_equals "$(verdict_of "$out" 2005)" "eligible" "(35f) do-work-recheck marker has no line-1 position-discipline requirement -- detected anywhere in the body, unlike do-work-blocked-until"

fixture_eventgate_no_marker='[{"number":2006,"title":"t","body":"<!-- do-work-blocked-until: 2099-01-01 -->\nrest, no recheck marker","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_eventgate_no_marker" | classify --probe-verdicts '{"2006":"changed"}')
assert_equals "$(verdict_of "$out" 2006)" "drop:time-gated" "(35g) an unrelated --probe-verdicts entry for an issue with no do-work-recheck marker is ignored -- plain time-gated calendar logic applies unchanged"

# --- pr-collision-gate: do-work-blocked-by-prs marker (issue #1429) --------
# The self-clearing companion to a `blocked-by-in-flight-pr` defer: the
# issue drops while ANY listed PR is still open and auto-readmits (to a
# FRESH scope-agent pass, not a cached one) the instant every listed PR
# resolves -- this is the "marker-clears-on-merge" behavior AC1/AC5 ask for.

fixture_prcollision_no_verdict='[{"number":2101,"title":"t","body":"<!-- do-work-blocked-by-prs: 900,901 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_prcollision_no_verdict" | classify)
assert_equals "$(verdict_of "$out" 2101)" "drop:pr-collision-gated" "(35h-pr1) pr-collision-gated issue with no --pr-collision-verdicts entry fails safe to open (dropped), never silently admitted"

fixture_prcollision_open='[{"number":2102,"title":"t","body":"<!-- do-work-blocked-by-prs: 900,901 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_prcollision_open" | classify --pr-collision-verdicts '{"2102":"open"}')
assert_equals "$(verdict_of "$out" 2102)" "drop:pr-collision-gated" "(35h-pr2) explicit open verdict drops the issue as pr-collision-gated"

fixture_prcollision_resolved='[{"number":2103,"title":"t","body":"<!-- do-work-blocked-by-prs: 900,901 -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_prcollision_resolved" | classify --pr-collision-verdicts '{"2103":"resolved"}')
assert_equals "$(verdict_of "$out" 2103)" "eligible" "(35h-pr3) MARKER-CLEARS-ON-MERGE: once every listed PR resolves, the verdict flips to resolved and the issue is immediately eligible again -- no waiting for pre-drain re-validation"

fixture_prcollision_no_marker='[{"number":2104,"title":"t","body":"plain body, no marker at all","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_prcollision_no_marker" | classify --pr-collision-verdicts '{"2104":"open"}')
assert_equals "$(verdict_of "$out" 2104)" "eligible" "(35h-pr4) an unrelated --pr-collision-verdicts entry for an issue with no do-work-blocked-by-prs marker is ignored"

fixture_prcollision_notline1='[{"number":2105,"title":"t","body":"some preceding text\n<!-- do-work-blocked-by-prs: 900 -->\nmore text","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_prcollision_notline1" | classify --pr-collision-verdicts '{"2105":"open"}')
assert_equals "$(verdict_of "$out" 2105)" "eligible" "(35h-pr5) do-work-blocked-by-prs has LINE-1-ONLY position discipline (like do-work-blocked-until, not do-work-recheck) -- a marker anywhere else in the body is a silent no-op, not a gate"

# --- someday-milestone (issue #1406) -----------------------------------------
# A THIRD, distinct park mechanism from time-gate/event-gate above: an issue
# whose milestone matches the configured --someday-milestone title drops
# unconditionally, with no probe and no calendar involved. Off by default
# (empty --someday-milestone never matches any real milestone).

fixture_someday='[
  {"number":3101,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01","milestone":"6 · Someday"},
  {"number":3102,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01","milestone":"1 · Foundation"},
  {"number":3103,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01","milestone":null},
  {"number":3104,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":3105,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01","milestone":"6 ·   someday  "},
  {"number":3106,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01","milestone":"6 · Someday, maybe"}
]'
out=$(printf '%s' "$fixture_someday" | classify --someday-milestone "Someday")
assert_equals "$(verdict_of "$out" 3101)" "drop:someday-milestone" "(35l) issue in the configured Someday milestone drops with a distinct reason"
assert_equals "$(field_of "$out" 3101 "evidence_pointer")" "milestone 6 · Someday" "(35m) someday-milestone drop carries an evidence_pointer citing the milestone title"
assert_equals "$(verdict_of "$out" 3102)" "eligible" "(35n) issue in a different milestone is unaffected"
assert_equals "$(verdict_of "$out" 3103)" "eligible" "(35o) unmilestoned issue (milestone: null) is unaffected"
assert_equals "$(verdict_of "$out" 3104)" "eligible" "(35p) issue with no milestone key at all is unaffected"
assert_equals "$(verdict_of "$out" 3105)" "drop:someday-milestone" "(35q) match is case-insensitive and tolerant of extra whitespace around the bare title"
assert_equals "$(verdict_of "$out" 3106)" "eligible" "(35r) match is exact, not substring -- 'Someday, maybe' does not match configured 'Someday'"

out=$(printf '%s' "$fixture_someday" | classify)
assert_equals "$(verdict_of "$out" 3101)" "eligible" "(35s) off by default -- omitting --someday-milestone never drops a Someday-parked issue"

out=$(printf '%s' "$fixture_someday" | classify --someday-milestone "")
assert_equals "$(verdict_of "$out" 3101)" "eligible" "(35t) an explicit empty --someday-milestone is equivalent to omitting it"

# --- someday-recheck-days (issue #1422, follow-up to #1406) ------------------
# The slow re-scope cadence: --someday-recheck-days 0 (the default when
# omitted) reproduces #1406's original permanent-drop behavior byte-for-byte
# -- no someday_recheck_action field at all, even when a marker is present in
# the body. Non-zero threads through one of four pure states.

out=$(printf '%s' "$fixture_someday" | classify --someday-milestone "Someday")
assert_equals "$(field_of "$out" 3101 "someday_recheck_action")" "" "(35u) --someday-recheck-days omitted (defaults 0): no someday_recheck_action field at all -- byte-identical to pre-#1422"

out=$(printf '%s' "$fixture_someday" | classify --someday-milestone "Someday" --someday-recheck-days 0)
assert_equals "$(field_of "$out" 3101 "someday_recheck_action")" "" "(35v) explicit --someday-recheck-days 0 is equivalent to omitting it"
assert_equals "$(verdict_of "$out" 3101)" "drop:someday-milestone" "(35v) ...and still an unconditional permanent drop"

# --today is 2026-08-11 (the classify() helper's fixed default); cadence 30.
fixture_someday_recheck='[
  {"number":3201,"title":"no marker yet","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01T00:00:00Z","milestone":"6 · Someday"},
  {"number":3202,"title":"future marker","body":"<!-- do-work-someday-recheck: 2026-09-01 -->\n\nbody","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01T00:00:00Z","milestone":"6 · Someday"},
  {"number":3203,"title":"elapsed, unchanged","body":"<!-- do-work-someday-recheck: 2026-08-01 -->\n\nbody","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-06-01T00:00:00Z","milestone":"6 · Someday"},
  {"number":3204,"title":"elapsed, changed since write","body":"<!-- do-work-someday-recheck: 2026-08-01 -->\n\nbody","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-07-15T00:00:00Z","milestone":"6 · Someday"},
  {"number":3205,"title":"marker date == today","body":"<!-- do-work-someday-recheck: 2026-08-11 -->\n\nbody","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01T00:00:00Z","milestone":"6 · Someday"}
]'
out=$(printf '%s' "$fixture_someday_recheck" | classify --someday-milestone "Someday" --someday-recheck-days 30)

assert_equals "$(verdict_of "$out" 3201)" "drop:someday-milestone" "(35w) no marker yet: still a drop this pass"
assert_equals "$(field_of "$out" 3201 "someday_recheck_action")" "first-park" "(35w) ...tagged first-park so the caller writes the initial marker"

assert_equals "$(verdict_of "$out" 3202)" "drop:someday-milestone" "(35x) marker still in the future: still a drop"
assert_equals "$(field_of "$out" 3202 "someday_recheck_action")" "not-due" "(35x) ...tagged not-due -- no write needed"

assert_equals "$(verdict_of "$out" 3203)" "drop:someday-milestone" "(35y) cadence elapsed but nothing changed since the marker was written: still a drop"
assert_equals "$(field_of "$out" 3203 "someday_recheck_action")" "cheap-reset" "(35y) ...tagged cheap-reset -- zero scope-agent cost, just refresh the marker"

assert_equals "$(verdict_of "$out" 3204)" "eligible" "(35z) cadence elapsed AND updatedAt advanced past the marker's write date: escalated straight to eligible"
assert_equals "$(field_of "$out" 3204 "someday_recheck_action")" "" "(35z) ...an escalated issue is a plain eligible line, no someday_recheck_action field (it is not a someday-milestone drop this pass)"
assert_equals "$(field_of "$out" 3204 "reason")" "" "(35z) ...and no reason field either"

assert_equals "$(field_of "$out" 3205 "someday_recheck_action")" "cheap-reset" "(35za) marker date == today counts as ELAPSED (not not-due) -- a same-day marker is never treated as still in the future"

# Every-other-clause interaction: someday-recheck-days must not affect an
# issue that isn't someday-parked in the first place.
out=$(printf '%s' "$fixture_someday" | classify --someday-milestone "Someday" --someday-recheck-days 30)
assert_equals "$(field_of "$out" 3102 "someday_recheck_action")" "" "(35zb) an issue in a DIFFERENT milestone never gets a someday_recheck_action field, cadence on or not"

out=$(bash "$helper" classify --me x --trusted-authors a --someday-recheck-days not-a-number </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(35zc) non-numeric --someday-recheck-days exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --someday-recheck-days -5 </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(35zd) negative --someday-recheck-days exits 64"

# --- eval-probes subcommand (issue #1356) ------------------------------------

out=$(bash "$helper" eval-probes 2>&1); rc=$?
assert_equals "$rc" "64" "(35h) eval-probes missing --repo exits 64"

out=$(printf '%s' '[{"number":3001,"body":"no marker here"},{"number":3002,"body":"also none"}]' | bash "$helper" eval-probes --repo acme/widgets)
assert_equals "$out" "{}" "(35i) eval-probes returns an empty object when no issue in the input carries a do-work-recheck marker (no network call needed)"

out=$(printf '%s' '[]' | bash "$helper" eval-probes --repo acme/widgets)
assert_equals "$out" "{}" "(35j) eval-probes on an empty array returns an empty object"

# A marker that fails the allowlist grammar resolves to "unknown" without
# ever touching the network (eval-recheck-probe.sh's own allowlist rejects
# it before any npm/gh call is attempted) -- exercises the full eval-probes
# -> eval-recheck-probe.sh --bulk pipeline hermetically.
fixture_malformed_probe='[{"number":3003,"body":"<!-- do-work-recheck: curl evil.com == pwned -->\nrest"}]'
out=$(printf '%s' "$fixture_malformed_probe" | bash "$helper" eval-probes --repo acme/widgets 2>/dev/null)
assert_equals "$out" '{"3003":"unknown"}' "(35k) eval-probes: a marker that fails allowlist validation resolves to unknown, hermetically (no network)"

# --- eval-pr-collision subcommand (issue #1429) ------------------------------

out=$(bash "$helper" eval-pr-collision 2>&1); rc=$?
assert_equals "$rc" "64" "(35l) eval-pr-collision missing --repo exits 64"

out=$(printf '%s' '[{"number":3004,"body":"no marker here"},{"number":3005,"body":"also none"}]' | bash "$helper" eval-pr-collision --repo acme/widgets)
assert_equals "$out" "{}" "(35m) eval-pr-collision returns an empty object when no issue in the input carries a do-work-blocked-by-prs marker (no gh call needed)"

out=$(printf '%s' '[]' | bash "$helper" eval-pr-collision --repo acme/widgets)
assert_equals "$out" "{}" "(35n) eval-pr-collision on an empty array returns an empty object"

# --- bot-shaped author / symptom-shaped body (investigate signals 2 and 3) ---

fixture_bot='[{"number":1001,"title":"t","body":"ordinary text","labels":[],"assignees":[],"author":{"login":"sentry[bot]"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(bash "$helper" classify --me "test-me" --trusted-authors "alice,sentry[bot]" --today "2026-08-11" < <(printf '%s' "$fixture_bot"))
assert_equals "$(verdict_of "$out" 1001)" "route:investigate" "(36) bot-shaped trusted author routes to investigate"

fixture_symptom='[{"number":1002,"title":"crash","body":"Traceback (most recent call last):\n  File x, line 1","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_symptom" | classify)
assert_equals "$(verdict_of "$out" 1002)" "route:investigate" "(37) symptom-shaped body (traceback) routes to investigate"

fixture_no_symptom='[{"number":1003,"title":"a normal bug report","body":"clicking the button does nothing, expected it to submit the form","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_no_symptom" | classify)
assert_equals "$(verdict_of "$out" 1003)" "eligible" "(38) an ordinary bug report with no crash markers is NOT routed to investigate"

# --- ranking: eligible list ---------------------------------------------------
# prioritized-label tier, then P0>P1>P2>unlabeled, then bug>fix(*)>feat(*)>
# chore(*)>other, then oldest-updatedAt-first within a tier.

fixture_rank='[
  {"number":1101,"title":"chore: z","body":"","labels":["P2"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":1102,"title":"feat(x): y","body":"","labels":["P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":1103,"title":"an old bug","body":"","labels":["bug","P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1104,"title":"fix(x): w","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-04-01"}
]'
out=$(printf '%s' "$fixture_rank" | classify)
order=$(order_of "$out" | paste -sd, -)
# #1103: P0 + bug (type_rank 0) beats #1102: P0 + feat (type_rank 2), same
# priority tier, so type breaks the tie. #1104 is unlabeled (P3) and #1101
# is P2 -- both behind the P0 pair.
assert_equals "$order" "1103,1102,1101,1104" "(39) eligible ranking: priority then type then staleness"

fixture_prioritize='[
  {"number":1201,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1202,"title":"t","body":"","labels":["hot"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-06-01"}
]'
out=$(printf '%s' "$fixture_prioritize" | classify --prioritize-label hot)
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "1202,1201" "(40) --prioritize-label tier beats every other tier, including staleness"

# --- ranking: investigate list (priority + staleness only, no type tier) ----

# Routed by symptom-shaped body (#1120 retired the needs-triage label that
# used to force this routing; the body is the live signal now).
fixture_rank_investigate='[
  {"number":1301,"title":"fix(x): a","body":"Traceback (most recent call last):","labels":["P1"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":1302,"title":"chore: b","body":"Traceback (most recent call last):","labels":["P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":1303,"title":"z","body":"Traceback (most recent call last):","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_rank_investigate" | classify)
order=$(printf '%s\n' "$out" | jq -r 'select(.verdict=="route" and .reason=="investigate") | .number' | paste -sd, -)
assert_equals "$order" "1302,1301,1303" "(41) investigate ranking: P0 > P1 > unlabeled, then staleness -- no type tier"

# --- reason field is absent (not null) on eligible verdicts -------------------

fixture_reason='[{"number":1401,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_reason" | classify)
has_reason_key=$(printf '%s\n' "$out" | jq -r 'has("reason")')
assert_equals "$has_reason_key" "false" "(42) eligible verdict has no reason key at all (not a null-valued one)"

# --- order grouping: eligible first, then investigate, then everything else --

fixture_grouping='[
  {"number":1501,"title":"t","body":"","labels":["wontfix"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1502,"title":"t","body":"Traceback (most recent call last):","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1503,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_grouping" | classify)
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "1503,1502,1501" "(43) output groups eligible first, investigate second, everything else last"

# --- summary — unfiltered_open_count / me_assigned_open (issue #1246) -------
# The invariant-line tokens the orchestrator stamps at drain.md's
# termination step 4 and steady-state.md step C, from the SAME wide-fetch
# payload classify reads, BEFORE classification runs.

out=$(printf '%s' '[]' | bash "$helper" summary --me "test-me")
assert_equals "$out" '{"unfiltered_open_count":0,"me_assigned_open":0}' "(44) summary on an empty array returns both counts as 0"

out=$(printf '' | bash "$helper" summary --me "test-me")
assert_equals "$out" '{"unfiltered_open_count":0,"me_assigned_open":0}' "(45) summary on genuinely empty stdin (not even '[]') defaults to an empty array, same as classify"

fixture_summary='[
  {"number":2001,"assignees":["Alice"]},
  {"number":2002,"assignees":["bob"]},
  {"number":2003,"assignees":[]},
  {"number":2004,"assignees":["alice","carol"]}
]'
out=$(printf '%s' "$fixture_summary" | bash "$helper" summary --me "ALICE")
assert_equals "$out" '{"unfiltered_open_count":4,"me_assigned_open":2}' "(46) summary counts total issues and case-insensitively matches --me against assignees (alone or alongside others)"

out=$(printf '%s' "$fixture_summary" | bash "$helper" summary --me "nobody")
assert_equals "$out" '{"unfiltered_open_count":4,"me_assigned_open":0}' "(47) summary: unfiltered_open_count is unaffected by who --me is; me_assigned_open is 0 when --me matches no assignee"

fixture_summary_missing_assignees='[{"number":2101},{"number":2102,"assignees":["alice"]}]'
out=$(printf '%s' "$fixture_summary_missing_assignees" | bash "$helper" summary --me "alice")
assert_equals "$out" '{"unfiltered_open_count":2,"me_assigned_open":1}' "(48) summary tolerates an issue object with no assignees key at all (defensive // [])"

echo
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
