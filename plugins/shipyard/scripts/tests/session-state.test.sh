#!/usr/bin/env bash
# Test suite for scripts/session-state.sh.
#
# Covers the four subcommands the orchestrator drives:
#
#   init     — create a fresh session state file at a deterministic path
#   update   — merge a JSON snippet into the file atomically (temp + rename)
#   read     — emit the current state JSON on stdout (whole-file or jq path)
#   cleanup  — remove the session file (end-of-session housekeeping)
#
# Atomicity is the load-bearing property: every update writes to
# <path>.tmp.<pid> and renames into place. A partial-write crash leaves the
# previous file intact rather than corrupting the source of truth.
#
# Pure bash + python3 (already required elsewhere in shipyard's script set).
# Run with:
#
#   bash plugins/shipyard/scripts/tests/session-state.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../session-state.sh"

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
    printf '    actual: %s\n' "$haystack" | head -c 400
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

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"
    fail=$((fail+1))
  fi
}

assert_file_missing() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file still present: %s\n' "$path"
    fail=$((fail+1))
  fi
}

# Each test gets a private SHIPYARD_HOME under a fresh tmpdir so the suite
# never touches the real ~/.shipyard.
mktmphome() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# --------------------------------------------------------------------------
echo "== init"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init \
  --session-id "abc-123" \
  --repo "owner/repo" \
  --concurrency 4 \
  --soft-collision-concurrency 3 \
  >/dev/null

session_file="$tmphome/sessions/abc-123.json"
assert_file_exists "$session_file" "init creates session file at \$SHIPYARD_HOME/sessions/<id>.json"

content=$(cat "$session_file")
assert_contains "$content" '"session_id": "abc-123"' "session_id persisted"
assert_contains "$content" '"repo": "owner/repo"' "repo persisted"
assert_contains "$content" '"concurrency": 4' "concurrency persisted"
assert_contains "$content" '"soft_collision_concurrency": 3' "soft_collision_concurrency persisted"
assert_contains "$content" '"in_flight": {}' "in_flight initialised to empty object"
assert_contains "$content" '"ready_issues": []' "ready_issues initialised to empty array"
assert_contains "$content" '"failed_prs": []' "failed_prs initialised to empty array"
assert_contains "$content" '"divert_queue": []' "divert_queue initialised to empty array"
assert_contains "$content" '"session_prs": []' "session_prs initialised to empty array"
assert_contains "$content" '"deferred_issues": []' "deferred_issues initialised to empty array"
assert_contains "$content" '"raw_backlog": []' "raw_backlog initialised to empty array"
assert_contains "$content" '"main_ci"' "main_ci block initialised"
assert_contains "$content" '"started_at"' "started_at timestamp present"
rm -rf "$tmphome"

# init refuses to clobber an existing session file unless --force.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" >/dev/null
# Mutate the file to prove it isn't being overwritten.
echo '{"sentinel":"untouched"}' > "$tmphome/sessions/s1.json"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=2" "init without --force on existing file exits 2"
assert_contains "$(cat "$tmphome/sessions/s1.json")" '"sentinel"' "init without --force does not clobber existing file"

SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" --force >/dev/null
assert_contains "$(cat "$tmphome/sessions/s1.json")" '"session_id": "s1"' "init --force overwrites existing file"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "r1" --repo "o/r" --concurrency 2 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1")
assert_contains "$out" '"session_id": "r1"' "read with no path emits whole state"

# Read a specific jq path.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1" --path ".concurrency")
assert_equals "$out" "2" "read --path .concurrency returns the concurrency value"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1" --path ".repo")
assert_equals "$out" "o/r" "read --path .repo returns the repo string"

# Missing session file → exit 3, empty stdout.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "missing" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read of missing session exits 3"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "u1" --repo "o/r" --concurrency 2 >/dev/null

# Update a top-level field via --set.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "u1" \
  --set '.session_prs = [96, 98]' \
  --set '.main_ci.status = "green"' >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".session_prs")
assert_contains "$out" "96" "update --set persists session_prs first entry"
assert_contains "$out" "98" "update --set persists session_prs second entry"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".main_ci.status")
assert_equals "$out" "green" "update --set persists nested main_ci.status"

# Update preserves unrelated fields.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".concurrency")
assert_equals "$out" "2" "update does not perturb unrelated fields"

# Append-to-array semantics via --set with jq's `+=` shape.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "u1" \
  --set '.session_prs += [100]' >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".session_prs | length")
assert_equals "$out" "3" "update --set with += appends to array"

# Atomic write: temp file must not linger after a successful update.
# Use a glob rather than `ls | grep` (shellcheck SC2010) to enumerate any
# files other than the canonical u1.json in the sessions dir.
leftover=""
shopt -s nullglob
for f in "$tmphome/sessions/"*; do
  case "$(basename "$f")" in
    u1.json) ;;
    *) leftover="$leftover $(basename "$f")" ;;
  esac
done
shopt -u nullglob
assert_equals "${leftover# }" "" "update does not leave .tmp files behind after successful write"

# Update of a missing session file → exit 3, no file created.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "missing" \
  --set '.foo = "bar"' 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "update of missing session exits 3"
assert_file_missing "$tmphome/sessions/missing.json" "update of missing session does not create the file"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== cleanup"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "c1" --repo "o/r" >/dev/null
session_file="$tmphome/sessions/c1.json"
assert_file_exists "$session_file" "session file exists before cleanup"

SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "c1" >/dev/null
assert_file_missing "$session_file" "cleanup removes the session file"

# Cleanup of a missing session is a no-op (exit 0) — re-runs must be safe.
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "c1"
rc=$?
assert_equals "$rc" "0" "cleanup of missing session is idempotent (exit 0)"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== unknown subcommand"
# --------------------------------------------------------------------------

out=$(bash "$helper" frobnicate 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64 (EX_USAGE)"
assert_contains "$out" "Usage" "unknown subcommand prints usage hint"

# --------------------------------------------------------------------------
echo "== missing args"
# --------------------------------------------------------------------------

out=$(bash "$helper" init 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "init without --session-id exits 64"
assert_contains "$out" "session-id" "init without --session-id mentions the missing arg"

out=$(bash "$helper" read 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "read without --session-id exits 64"

out=$(bash "$helper" update --session-id x 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "update without --set exits 64"

# --------------------------------------------------------------------------
echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
