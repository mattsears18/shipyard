#!/usr/bin/env bash
# Test suite for scripts/classify-blocked-bail.sh (steady-state.md's A.1
# "blocked #<N>" bail classification — issue #521's soft/refuse/dependency-
# wait/operator split, issue #1279's decision-freshness re-gate suppression
# — extracted to a script by issue #1289).
#
# Covers:
#   usage / arg validation        — missing --repo/--issue/--reason
#   dependency-wait                — a "Blocked by #N" reference to an OPEN
#                                     issue routes to dependency-wait, no label
#   dependency-wait ref already OK — body already carries the Blocked-by line;
#                                     no duplicate edit
#   operator                       — "external provisioning required" routes
#                                     to agent-console
#   soft                           — "cannot reproduce" routes to blocked:agent-soft
#   refuse (default)                — an unrecognized reason routes to
#                                     needs-human-review
#   refuse suppressed by #1279     — a decision-resolved comment posted AFTER
#                                     the last refuse-escalation comment
#                                     suppresses the re-gate
#   refuse NOT suppressed           — a decision comment posted BEFORE the
#                                     last escalation does not suppress a
#                                     fresh one
#
# The `gh` dependency is mocked via the $GH env var so this suite needs no
# network access and is CI-safe.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/classify-blocked-bail.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../classify-blocked-bail.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: helper not found at $script" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, want %s)\n' "$RED" "$RESET" "$label" "$got" "$want"
    fail=$((fail+1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_gh <path> — a mock gh dispatching on subcommand. Fixtures live under
# $WORK, keyed by issue number:
#   issue.<N>.body       -> `issue view <N> --json body -q .body`
#   issue.<N>.state.<M>  -> `issue view <M> --json state -q .state` (blocker lookup)
#   issue.<N>.comments   -> `issue view <N> --json comments --jq ...`
# All mutating calls (`issue edit`, `issue comment`, `label create`) are
# logged to $GH_LOG rather than actually mutating anything.
make_gh() {
  local path="$1"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
work="${WORK}"
if [ "\$1 \$2" = "issue view" ]; then
  n="\$3"
  if [ "\$7" = "body" ]; then
    cat "\${work}/issue.\${n}.body" 2>/dev/null
    exit 0
  fi
  if [ "\$7" = "state" ]; then
    cat "\${work}/issue.\${n}.state" 2>/dev/null
    exit 0
  fi
  if [ "\$7" = "comments" ]; then
    cat "\${work}/issue.\${n}.comments" 2>/dev/null
    exit 0
  fi
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  cat "\${work}/pr.\${3}.state" 2>/dev/null
  exit 0
fi
if [ "\$1 \$2" = "issue edit" ]; then
  echo "ISSUE-EDIT: \$*" >> "\$GH_LOG"
  exit 0
fi
if [ "\$1 \$2" = "issue comment" ]; then
  echo "ISSUE-COMMENT: \$*" >> "\$GH_LOG"
  exit 0
fi
if [ "\$1 \$2" = "label create" ]; then
  echo "LABEL-CREATE: \$*" >> "\$GH_LOG"
  exit 0
fi
exit 0
MOCK
  chmod +x "$path"
}

GH_MOCK="${WORK}/gh"
make_gh "$GH_MOCK"
export GH_LOG="${WORK}/gh.log"

echo "classify-blocked-bail.sh test suite"
echo "===================================="

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(bash "$script" classify --repo o/r --issue 1 2>&1)"; rc=$?
assert_contains "$out" "required" "classify without --reason errors"
assert_exit "$rc" "64" "missing required args exits 64"

# --------------------------------------------------------------------------
echo
echo "dependency-wait: reason names an OPEN blocker -> no label, blocker referenced"
# --------------------------------------------------------------------------
echo "some body text" > "${WORK}/issue.10.body"
echo "OPEN" > "${WORK}/issue.99.state"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 10 --reason "blocked by #99, waiting on it" 2>&1)"
assert_contains "$out" "class=dependency-wait" "dependency-wait class returned"
assert_contains "$out" "open_blocker=99" "open_blocker names the referenced issue"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "ISSUE-EDIT" "dependency-wait edits the issue body to persist the Blocked-by reference"
assert_contains "$ghlog" "ISSUE-COMMENT" "dependency-wait posts an explanatory comment"

# --------------------------------------------------------------------------
echo
echo "dependency-wait: body already carries the Blocked-by line -> no duplicate edit"
# --------------------------------------------------------------------------
echo "Blocked by #99

some body text" > "${WORK}/issue.11.body"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 11 --reason "blocked by #99, waiting on it" 2>&1)"
assert_contains "$out" "class=dependency-wait" "dependency-wait class returned when body already has the reference"
ghlog="$(cat "$GH_LOG")"
if [[ "$ghlog" == *"ISSUE-EDIT"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "no duplicate body edit when Blocked-by line already present"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "no duplicate body edit when Blocked-by line already present"; pass=$((pass+1))
fi

# --------------------------------------------------------------------------
echo
echo "operator: external provisioning required -> agent-console"
# --------------------------------------------------------------------------
echo "" > "${WORK}/issue.12.body"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 12 --reason "external provisioning required — sentry: create an account" 2>&1)"
assert_contains "$out" "class=operator label=agent-console" "operator class routes to agent-console"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "agent-console" "agent-console label applied"

# --------------------------------------------------------------------------
echo
echo "operator: irreversible external action -> agent-console (#1519)"
# --------------------------------------------------------------------------
# The worker-side irreversible-external-action gate hands back the exact
# command instead of running it. That is a queued operator action, NOT a
# human decision — routing it to needs-human-review (the table's conservative
# refuse default) would park a perfectly drainable item in the human-only
# queue, which /my-turn deliberately filters agent-console out of.
echo "" > "${WORK}/issue.121.body"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 121 --reason "irreversible external action — delete the EXPO_PUBLIC_FCM_WEB_VAPID_KEY production row on vercel; handed back rather than executed. exact command: \`vercel env rm EXPO_PUBLIC_FCM_WEB_VAPID_KEY production\`" 2>&1)"
assert_contains "$out" "class=operator label=agent-console" "irreversible-external-action bail routes to agent-console (#1519)"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "agent-console" "agent-console label applied for the #1519 gate bail"

# The comment must explain WHY it is an operator item, not reuse the
# provisioning wording — a maintainer reading the issue needs to know a
# worker deliberately declined the action, not that a service is unprovisioned.
assert_contains "$ghlog" "irreversibly mutate live external state" \
  "comment explains the #1519 hand-back rather than the #628 provisioning case"

# --------------------------------------------------------------------------
echo
echo "soft: cannot reproduce -> blocked:agent-soft"
# --------------------------------------------------------------------------
echo "" > "${WORK}/issue.13.body"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 13 --reason "cannot reproduce the described bug" 2>&1)"
assert_contains "$out" "class=soft label=blocked:agent-soft" "soft class returned for cannot-reproduce"
assert_contains "$out" "now=" "soft class reports a timestamp for session_blocked_soft bookkeeping"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "blocked:agent-soft" "blocked:agent-soft label applied"

# --------------------------------------------------------------------------
echo
echo "refuse (default): an unrecognized reason -> needs-human-review"
# --------------------------------------------------------------------------
echo '[]' > "${WORK}/issue.14.comments"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 14 --reason "something entirely unrecognized happened" 2>&1)"
assert_contains "$out" "class=refuse label=needs-human-review" "unrecognized reason defaults to refuse/needs-human-review"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "needs-human-review" "needs-human-review label applied"
assert_contains "$ghlog" "do-work-agent-refuse" "provenance marker included in the comment"

# --------------------------------------------------------------------------
echo
echo "refuse suppressed (#1279): a decision recorded AFTER the last escalation"
# --------------------------------------------------------------------------
cat > "${WORK}/issue.15.comments" <<'EOF'
[
  {"body": "<!-- do-work-agent-refuse -->\nWorker returned blocked: something.", "createdAt": "2026-08-01T00:00:00Z"},
  {"body": "<!-- do-work-decision-resolved -->\nDecided: proceed with option A.", "createdAt": "2026-08-02T00:00:00Z"}
]
EOF
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 15 --reason "something entirely unrecognized happened" 2>&1)"
assert_contains "$out" "class=refuse label=none reason=decision-already-recorded-after-escalation" \
  "a fresher decision comment suppresses the re-gate"
ghlog="$(cat "$GH_LOG")"
# The suppression comment's own explanatory text legitimately quotes
# "needs-human-review" ("NOT re-applying `needs-human-review`...") — check
# for the --add-label MUTATION specifically, not a bare substring match
# against the whole log (which would false-positive on that quoted mention).
if [[ "$ghlog" == *"--add-label needs-human-review"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "no needs-human-review label applied when suppressed"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "no needs-human-review label applied when suppressed"; pass=$((pass+1))
fi

# --------------------------------------------------------------------------
echo
echo "refuse NOT suppressed: a decision recorded BEFORE the last escalation"
# --------------------------------------------------------------------------
cat > "${WORK}/issue.16.comments" <<'EOF'
[
  {"body": "<!-- do-work-decision-resolved -->\nDecided: proceed with option A.", "createdAt": "2026-08-01T00:00:00Z"},
  {"body": "<!-- do-work-agent-refuse -->\nWorker returned blocked: something.", "createdAt": "2026-08-02T00:00:00Z"}
]
EOF
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 16 --reason "something entirely unrecognized happened" 2>&1)"
assert_contains "$out" "class=refuse label=needs-human-review" \
  "a STALE decision (predating the last escalation) does NOT suppress a fresh refuse"

# --------------------------------------------------------------------------
echo
echo "refuse NOT suppressed (#1557): a PARTIAL /resolve-decisions run is not a decision"
# --------------------------------------------------------------------------
# A partial walkthrough posts the SAME <!-- shipyard-resolve-decisions -->
# sentinel but deliberately leaves the gate on, because a blocking decision
# is still unanswered. Matching it as a full resolution would suppress a gate
# the maintainer explicitly chose to keep.
cat > "${WORK}/issue.17.comments" <<'EOF'
[
  {"body": "<!-- do-work-agent-refuse -->\nWorker returned blocked: something.", "createdAt": "2026-08-01T00:00:00Z"},
  {"body": "<!-- shipyard-resolve-decisions -->\n## Decisions resolved (partial — 2 of 4)\n\nStill open: the retention window, the cohort split.", "createdAt": "2026-08-02T00:00:00Z"}
]
EOF
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 17 --reason "something entirely unrecognized happened" 2>&1)"
assert_contains "$out" "class=refuse label=needs-human-review" \
  "a PARTIAL resolve-decisions comment does NOT suppress the re-gate (#1557)"

# --------------------------------------------------------------------------
echo
echo "refuse suppressed (#1557): a FULL run still suppresses, partial sibling notwithstanding"
# --------------------------------------------------------------------------
cat > "${WORK}/issue.18.comments" <<'EOF'
[
  {"body": "<!-- do-work-agent-refuse -->\nWorker returned blocked: something.", "createdAt": "2026-08-01T00:00:00Z"},
  {"body": "<!-- shipyard-resolve-decisions -->\n## Decisions resolved (partial — 2 of 4)\n\nStill open: the retention window.", "createdAt": "2026-08-02T00:00:00Z"},
  {"body": "<!-- shipyard-resolve-decisions -->\n## Decisions resolved (via /resolve-decisions)\n\n1. **Retention window** → **90 days**.", "createdAt": "2026-08-03T00:00:00Z"}
]
EOF
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" classify \
  --repo o/r --issue 18 --reason "something entirely unrecognized happened" 2>&1)"
assert_contains "$out" "class=refuse label=none reason=decision-already-recorded-after-escalation" \
  "a FULL resolve-decisions comment still suppresses the re-gate (#1557)"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
