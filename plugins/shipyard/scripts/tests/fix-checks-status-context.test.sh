#!/usr/bin/env bash
# Test: fix-checks-only rollup handling supports both CheckRun and
# StatusContext nodes from GitHub's statusCheckRollup union (issue #1684).
#
# StatusContext stores its result in `state` and its display/grouping key in
# `context`; omitting either field makes green rollups look pending, hides
# failed contexts, or merges distinct contexts together.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/fix-checks-status-context.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_count() {
  local file="$1"
  local needle="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(grep -Foc -- "$needle" "$file" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s (got %s)\n' "$GREEN" "$RESET" "$label" "$actual"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  %sPASS%s  %s (got %s)\n' "$GREEN" "$RESET" "$label" "$actual"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

echo "fix-checks-only StatusContext rollup handling (issue #1684)"
echo

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the recorded statusCheckRollup fixture" >&2
  exit 1
fi

# Keep these snippets aligned with the four rollup reads in fix-checks-only.md.
assert_count "$fix_checks_path" \
  '.conclusion // .status // .state // ""' 3 \
  "summary counts and failure selection include StatusContext.state"
assert_contains "$fix_checks_path" \
  '.conclusion // .status // .state // null' \
  "named-check conclusions include StatusContext.state"
assert_count "$fix_checks_path" \
  'group_by(.name // .context)' 5 \
  "four latest-per-check projections and their description include StatusContext.context"
assert_contains "$fix_checks_path" \
  'select((.name // .context) == \"<failing-check-name>\")' \
  "named-check matching accepts StatusContext.context"
assert_contains "$fix_checks_path" \
  'name: (.name // .context)' \
  "named-check output displays StatusContext.context"

ROLLUP=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"__typename":"CheckRun", "name":"Lint", "status":"COMPLETED", "conclusion":"SUCCESS", "completedAt":"2026-10-08T10:00:00Z"},
    {"__typename":"StatusContext", "context":"Vercel - app", "state":"FAILURE", "startedAt":"2026-10-08T10:30:00Z"},
    {"__typename":"StatusContext", "context":"Vercel - app", "state":"SUCCESS", "startedAt":"2026-10-08T11:00:00Z"},
    {"__typename":"StatusContext", "context":"Netlify - app", "state":"FAILURE", "startedAt":"2026-10-08T12:00:00Z"}
  ]
}
JSON
)

JQ_LATEST="$(cat <<'JQ'
  [.statusCheckRollup
   | group_by(.name // .context)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]]
JQ
)"

JQ_COUNTS="$(cat <<'JQ'
  [.statusCheckRollup
   | group_by(.name // .context)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | (.conclusion // .status // .state // "" | ascii_downcase)] as $c
  | {passed: ([$c[] | select(. == "success" or . == "skipped" or . == "neutral")] | length),
     pending: ([$c[] | select(. == "" or . == "pending" or . == "in_progress" or . == "queued" or . == "expected")] | length),
     failing: ([$c[] | select(. == "failure" or . == "error" or . == "timed_out" or . == "cancelled" or . == "action_required")] | length)}
JQ
)"

JQ_FAILURES="$(cat <<'JQ'
  [.statusCheckRollup
   | group_by(.name // .context)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | select((.conclusion // .status // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
   | (.name // .context)]
JQ
)"

JQ_NAMED_CHECK="$(cat <<'JQ'
  [.statusCheckRollup
   | group_by(.name // .context)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | select((.name // .context) == "Netlify - app")
   | {name: (.name // .context), conclusion: (.conclusion // .status // .state // null)}]
JQ
)"

counts="$(jq -c "$JQ_COUNTS" <<<"$ROLLUP")"
assert_equals \
  "CheckRun and StatusContext states produce distinct passed/failing counts with no false pending" \
  '{"passed":2,"pending":0,"failing":1}' "$counts"

failures="$(jq -c "$JQ_FAILURES" <<<"$ROLLUP")"
assert_equals \
  "failed StatusContext remains visible to the failure selector" \
  '["Netlify - app"]' "$failures"

named_check="$(jq -c "$JQ_NAMED_CHECK" <<<"$ROLLUP")"
assert_equals \
  "named-check verification finds and labels a StatusContext by context" \
  '[{"name":"Netlify - app","conclusion":"FAILURE"}]' "$named_check"

latest_contexts="$(jq -c "$JQ_LATEST" <<<"$ROLLUP" | jq -c '[.[] | select(.context != null) | .context] | sort')"
assert_equals \
  "latest-per-name reduction retains both distinct StatusContext contexts" \
  '["Netlify - app","Vercel - app"]' "$latest_contexts"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
