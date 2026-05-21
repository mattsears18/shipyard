#!/usr/bin/env bash
# Test suite for scripts/gh-batch.sh — the GraphQL-batched PR/issue
# state wrapper added in #159.
#
# Strategy: stand up a fake `gh` binary in a per-test tmpdir, point PATH
# at it, and assert the wrapper's behavior. The fake gh inspects the
# argv to figure out which aliases were requested in the GraphQL query
# body, then emits a synthetic response matching the GraphQL shape.
# Per-test counters let us assert "ran one query" vs "chunked into N
# queries" by argv count rather than parsing the query body itself.
#
# Pure bash + jq (jq is already a hard dep of shipyard).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/gh-batch.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../gh-batch.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 500
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 500
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
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

# Spin up an isolated env: a fake `gh` binary that parses the GraphQL
# query body out of its argv, extracts the aliases (pr_<N> / issue_<N>),
# and emits a synthetic response keyed on those aliases.
#
# The fake records each call (one line per call, joined argv) to a
# counter file so tests can assert "1 call total" vs "2 calls (chunked)"
# without parsing the query body itself.
mktmpenv() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'SH'
#!/usr/bin/env bash
# Fake `gh` for gh-batch.test.sh. We only support the form
# `gh api graphql -f query=<body>` — every other invocation is a test
# bug. The query body comes in as the value of the -f query= arg.
counter="${GH_BATCH_TEST_COUNTER:-/tmp/gh-batch-test-counter}"
mkdir -p "$(dirname "$counter")"
[[ -f "$counter" ]] || : > "$counter"
# Record one marker line per invocation. The query body is multiline,
# so don't use $* in the counter — wc -l would tally newlines, not
# calls. The argv-capture file is separate (see argv path below).
echo "CALL" >> "$counter"
# Also save the most recent argv for tests that want to assert the
# shape of the query body.
argv_log="${counter%.*}.argv"
{ printf '%s\n' "----- call -----"; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$argv_log"

# Failure injection: if GH_BATCH_FAIL=1 is set, exit nonzero (simulating
# rate limit, 5xx, etc.).
if [[ "${GH_BATCH_FAIL:-0}" == "1" ]]; then
  echo "rate limit exceeded" >&2
  exit 1
fi

# Find the query body. We're called like:
#   gh api graphql -f query=<multiline body>
query=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      kv="${2:-}"
      shift 2
      if [[ "$kv" == query=* ]]; then
        query="${kv#query=}"
      fi
      ;;
    *) shift ;;
  esac
done

# Determine kind (pr or issue) by looking at the query body for which
# resolver shows up.
if [[ "$query" == *"pullRequest("* ]]; then
  kind=pr
elif [[ "$query" == *"issue("* ]]; then
  kind=issue
else
  echo "fake gh: cannot determine kind from query" >&2
  exit 1
fi

# Extract every "pr_NNN:" / "issue_NNN:" alias label.
aliases=$(printf '%s\n' "$query" | grep -oE "${kind}_[0-9]+" | sort -u)

# Build a synthetic GraphQL response. For each alias we emit a record
# with the alias's number as both .number and a derived state. The
# magic test number 999 produces a `null` entry to exercise the
# drop-on-missing branch in the reducer.
{
  printf '{"data":{'
  first=1
  for a in $aliases; do
    n="${a#${kind}_}"
    if [[ $first -eq 0 ]]; then printf ','; fi
    first=0
    if [[ "$n" == "999" ]]; then
      # Missing artifact — alias resolves to a null repository or null
      # pullRequest/issue. Use null repository here.
      printf '"%s":null' "$a"
    else
      if [[ "$kind" == "pr" ]]; then
        printf '"%s":{"pullRequest":{"number":%s,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","headRefName":"feat/%s","headRefOid":"abc%s","statusCheckRollup":{"state":"SUCCESS"}}}' \
          "$a" "$n" "$n" "$n"
      else
        printf '"%s":{"issue":{"number":%s,"state":"OPEN","labels":{"nodes":[{"name":"P2"},{"name":"shipyard"}]}}}' \
          "$a" "$n"
      fi
    fi
  done
  printf '}}'
} 2>/dev/null
SH
  chmod +x "$d/bin/gh"
  echo "$d"
}

count_calls() {
  local counter="$1"
  if [[ -f "$counter" ]]; then
    wc -l < "$counter" | tr -d ' '
  else
    echo 0
  fi
}

# --------------------------------------------------------------------------
echo "== usage / dispatch"
# --------------------------------------------------------------------------

# No subcommand → exit 64.
out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no subcommand exits 64"

# Unknown subcommand → exit 64.
out=$(bash "$helper" wat 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

# --help prints usage.
out=$(bash "$helper" --help 2>&1)
assert_contains "$out" "Usage:" "--help prints usage"
assert_contains "$out" "gh-batch.sh pr-status" "usage mentions pr-status"
assert_contains "$out" "gh-batch.sh issue-state" "usage mentions issue-state"

# --------------------------------------------------------------------------
echo "== pr-status: usage errors"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Missing --repo.
out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --numbers "1 2" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "pr-status without --repo exits 64"

# Malformed --repo (no slash).
out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo foo --numbers "1 2" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "pr-status with malformed --repo exits 64"

# Non-numeric token in --numbers.
out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "1 abc 3" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "pr-status with non-numeric --numbers exits 64"

# Unknown flag.
out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "1" --bogus thing 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "pr-status with unknown flag exits 64"

# Sanity: no fake gh calls from usage-error paths.
assert_equals "$(count_calls "$counter")" "0" "usage errors do not invoke gh"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: empty list → empty object"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "")
assert_equals "$out" "{}" "empty --numbers emits {} and skips gh"
assert_equals "$(count_calls "$counter")" "0" "empty --numbers does not invoke gh"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: single chunk, multiple PRs"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "142 143 144")
assert_equals "$(count_calls "$counter")" "1" "3 PRs fit in one chunk → 1 gh call"

# Output should be a JSON object keyed by PR number (string), with
# expected projection fields.
key_142=$(printf '%s' "$out" | jq -r '."142".number')
assert_equals "$key_142" "142" "output has key 142 with number=142"
state_143=$(printf '%s' "$out" | jq -r '."143".statusCheckRollupState')
assert_equals "$state_143" "SUCCESS" "PR 143 carries statusCheckRollupState"
head_144=$(printf '%s' "$out" | jq -r '."144".headRefName')
assert_equals "$head_144" "feat/144" "PR 144 carries headRefName"
oid_142=$(printf '%s' "$out" | jq -r '."142".headRefOid')
assert_equals "$oid_142" "abc142" "PR 142 carries headRefOid"

# Object has exactly 3 keys (no extras, no drops).
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "3" "output has exactly 3 PR entries"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: comma-separated --numbers"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "10,20,30")
assert_equals "$(count_calls "$counter")" "1" "comma-separated --numbers parses in one chunk"
key_20=$(printf '%s' "$out" | jq -r '."20".number')
assert_equals "$key_20" "20" "comma-parsed list resolves PR 20"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: drops missing PRs (null aliases)"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Magic 999 → fake gh emits null for the alias.
out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "142 999 144")
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "2" "999 (null alias) drops from output; 2 entries remain"
has_999=$(printf '%s' "$out" | jq 'has("999")')
assert_equals "$has_999" "false" "999 not present in output"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: chunks across the size boundary"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Force chunk size to 2 so 5 PRs → 3 chunks (2 + 2 + 1).
out=$(GH_BATCH_TEST_COUNTER="$counter" SHIPYARD_GH_BATCH_CHUNK_SIZE=2 PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "1 2 3 4 5")
assert_equals "$(count_calls "$counter")" "3" "5 PRs at chunk-size 2 → 3 gh calls"

# Merged output still has 5 entries.
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "5" "merged output has 5 entries across 3 chunks"
key_3=$(printf '%s' "$out" | jq -r '."3".number')
assert_equals "$key_3" "3" "middle-chunk PR 3 present in merged output"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== pr-status: gh failure → exit 2, no partial output"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" GH_BATCH_FAIL=1 PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "1 2 3" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=2" "gh failure surfaces as exit 2"

# Stdout (everything before the rc= line) must be empty / no chunk JSON.
stdout_only=$(printf '%s' "$out" | sed '$d')
assert_not_contains "$stdout_only" '"pullRequest"' "no partial output on gh failure"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== issue-state: usage errors"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --numbers "1 2" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "issue-state without --repo exits 64"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "1 fish 3" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "issue-state with non-numeric --numbers exits 64"

assert_equals "$(count_calls "$counter")" "0" "issue-state usage errors do not invoke gh"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== issue-state: single chunk, multiple issues, labels flattened"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "100 200")
assert_equals "$(count_calls "$counter")" "1" "2 issues in one chunk → 1 gh call"

key_100=$(printf '%s' "$out" | jq -r '."100".number')
assert_equals "$key_100" "100" "issue 100 keyed by string number"

state_200=$(printf '%s' "$out" | jq -r '."200".state')
assert_equals "$state_200" "OPEN" "issue 200 has state"

# Labels should be a flat array of strings, not the GraphQL nodes shape.
labels_100=$(printf '%s' "$out" | jq -c '."100".labels')
assert_equals "$labels_100" '["P2","shipyard"]' "labels flattened to array of strings"

# Two keys, no extras.
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "2" "issue-state output has exactly 2 entries"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== issue-state: empty list → empty object"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "")
assert_equals "$out" "{}" "issue-state empty --numbers emits {} and skips gh"
assert_equals "$(count_calls "$counter")" "0" "issue-state empty --numbers does not invoke gh"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== issue-state: drops missing issues"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "100 999 300")
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "2" "issue-state drops null alias (999)"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== issue-state: chunks across boundary"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

out=$(GH_BATCH_TEST_COUNTER="$counter" SHIPYARD_GH_BATCH_CHUNK_SIZE=3 PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "10 20 30 40 50 60 70")
# 7 issues at chunk size 3 → 3 chunks (3 + 3 + 1).
assert_equals "$(count_calls "$counter")" "3" "7 issues at chunk-size 3 → 3 gh calls"
key_count=$(printf '%s' "$out" | jq 'length')
assert_equals "$key_count" "7" "merged issue-state output has 7 entries across 3 chunks"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== SHIPYARD_GH_BATCH_CHUNK_SIZE: malformed value falls back to default"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Non-numeric chunk size → silently falls back to 50. With 3 PRs, that
# means 1 chunk = 1 gh call.
out=$(GH_BATCH_TEST_COUNTER="$counter" SHIPYARD_GH_BATCH_CHUNK_SIZE="lots" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo owner/name --numbers "1 2 3")
assert_equals "$(count_calls "$counter")" "1" "malformed chunk size → default 50 → 1 call for 3 PRs"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== query body shape: repo owner/name + integer numbers only"
# --------------------------------------------------------------------------

# Exercise the query template to confirm only the validated tokens make
# it into the query. We capture the fake gh's argv (which includes the
# -f query=... arg) and grep for what we expect / don't expect.
env=$(mktmpenv)
counter="$env/calls.log"
argv_log="$env/calls.argv"

GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" pr-status --repo my-org/my.repo --numbers "42 7" >/dev/null

argv=$(cat "$argv_log")
assert_contains "$argv" 'owner: "my-org"' "query includes owner literal"
assert_contains "$argv" 'name: "my.repo"' "query includes name literal"
assert_contains "$argv" 'pr_42: repository' "query carries alias for PR 42"
assert_contains "$argv" 'pr_7: repository' "query carries alias for PR 7"
assert_contains "$argv" 'pullRequest(number: 42)' "query uses pullRequest resolver"
assert_contains "$argv" 'statusCheckRollup' "PR projection requests statusCheckRollup"

rm -rf "$env"

env=$(mktmpenv)
counter="$env/calls.log"
argv_log="$env/calls.argv"

GH_BATCH_TEST_COUNTER="$counter" PATH="$env/bin:$PATH" \
  bash "$helper" issue-state --repo owner/name --numbers "5" >/dev/null

argv=$(cat "$argv_log")
assert_contains "$argv" 'issue_5: repository' "issue query carries alias for issue 5"
assert_contains "$argv" 'issue(number: 5)' "issue query uses issue resolver"
assert_contains "$argv" 'labels(first: 50)' "issue projection requests labels"

rm -rf "$env"

# --------------------------------------------------------------------------
echo
if [[ $fail -eq 0 ]]; then
  printf '%s== gh-batch.sh: %d/%d assertions passed%s\n' "$GREEN" "$pass" "$((pass+fail))" "$RESET"
  exit 0
else
  printf '%s== gh-batch.sh: %d failed, %d passed%s\n' "$RED" "$fail" "$pass" "$RESET"
  exit 1
fi
