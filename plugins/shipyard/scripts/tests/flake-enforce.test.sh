#!/usr/bin/env bash
# Test suite for scripts/flake-enforce.sh (issue #385 — flake-registry phase 2).
#
# Covers the enforcement consumer:
#   enforce --dry-run    — planned actions printed, NO side effects.
#   enforce (real)       — all three actions fire with a mocked `gh`.
#   dedupe               — re-running enforces nothing new (issue exists,
#                          suspect present, PR already blocked:ci).
#   per-row actions      — a row whose `actions` omits an action skips it.
#   suspects-list        — comments/blanks stripped, keys listed.
#   is-suspect           — exit 0 present / exit 1 absent / exit 64 no --key.
#   nothing-crossed      — empty crossed array is a clean no-op.
#
# The two gh-dependent actions (file-tracking-issue, apply-blocked-ci) are
# exercised against a mock `gh` binary injected via $GH, so the suite needs no
# network and is CI-safe. The local action (stop-auto-rerunning) writes a real
# file under a temp repo root.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/flake-enforce.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
enforce="${here}/../flake-enforce.sh"
registry="${here}/../flake-registry.sh"

if [[ ! -f "$enforce" ]]; then
  echo "FAIL: helper not found at $enforce" >&2
  exit 1
fi
# enforce (without --from-stdin) shells out to flake-registry.sh's `crossed`;
# the phase-1 helper must be present for that path to work.
if [[ ! -f "$registry" ]]; then
  echo "FAIL: phase-1 flake-registry.sh not found at $registry" >&2
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
    printf '    actual: %s\n' "$haystack" | head -c 600; printf '\n'
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 600; printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
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

# --------------------------------------------------------------------------
# Test scaffolding: isolated SHIPYARD_HOME + repo root + mock gh per test.
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_registry() {
  # Seed a crossed flake: 3 events across 2 distinct PRs for CI/E2E/AUTH-1.
  local home="$1"
  mkdir -p "$home"
  cat > "${home}/flake-registry.jsonl" <<EOF
{"at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","repo":"o/r","pr":1,"workflow":"CI","job":"E2E","test":"AUTH-1","action":"rerun-failed"}
{"at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","repo":"o/r","pr":2,"workflow":"CI","job":"E2E","test":"AUTH-1","action":"rerun-failed"}
{"at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","repo":"o/r","pr":2,"workflow":"CI","job":"E2E","test":"AUTH-1","action":"rerun-failed"}
EOF
}

# Mock gh that records calls and emits canned responses. $1 controls the
# "existing issue" + "pr already labeled" toggles.
make_gh() {
  local path="$1" existing_issue="$2" pr_labels="$3"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
echo "GH-CALL: \$*" >> "\$GH_LOG"
case "\$1 \$2" in
  "issue list")   printf '%s' "${existing_issue}" ;;
  "issue create") echo "https://github.com/o/r/issues/999" ;;
  "pr view")      printf 'OPEN\n%s\n' "${pr_labels}" ;;
  *) : ;;
esac
MOCK
  chmod +x "$path"
}

echo "flake-enforce.sh test suite"
echo "============================"

# --------------------------------------------------------------------------
echo
echo "enforce --dry-run — planned actions, no side effects"
# --------------------------------------------------------------------------
T="${WORK}/dry"; mkdir -p "$T/repo"
make_registry "$T/home"
out="$(SHIPYARD_HOME="$T/home" "$enforce" enforce --repo o/r --dry-run --repo-root "$T/repo" 2>&1)"
assert_contains "$out" "DRY-RUN file-tracking-issue repo=o/r" "dry-run announces file-tracking-issue"
assert_contains "$out" "DRY-RUN stop-auto-rerunning" "dry-run announces stop-auto-rerunning"
assert_contains "$out" "DRY-RUN apply-blocked-ci repo=o/r pr=1" "dry-run announces apply-blocked-ci for pr 1"
assert_contains "$out" "DRY-RUN apply-blocked-ci repo=o/r pr=2" "dry-run announces apply-blocked-ci for pr 2"
if [[ ! -e "$T/repo/.shipyard/flake-suspects.txt" ]]; then
  printf '  %sPASS%s  dry-run wrote NO suspects file\n' "$GREEN" "$RESET"; pass=$((pass+1))
else
  printf '  %sFAIL%s  dry-run should not write suspects file\n' "$RED" "$RESET"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "enforce (real, mocked gh) — all three actions fire"
# --------------------------------------------------------------------------
T="${WORK}/real"; mkdir -p "$T/repo"
make_registry "$T/home"
make_gh "$T/gh" "" "shipyard"            # no existing issue; pr not labeled
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(SHIPYARD_HOME="$T/home" GH="$T/gh" "$enforce" enforce --repo o/r --repo-root "$T/repo" 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "issue create --repo o/r" "files a tracking issue"
assert_contains "$ghlog" "label create audit:test-stability" "ensures stability label exists"
assert_contains "$ghlog" "pr edit 1 --repo o/r --add-label blocked:ci" "labels pr 1 blocked:ci"
assert_contains "$ghlog" "pr edit 2 --repo o/r --add-label blocked:ci" "labels pr 2 blocked:ci"
assert_contains "$ghlog" "pr comment 1" "comments on pr 1"
suspects="$(cat "$T/repo/.shipyard/flake-suspects.txt")"
assert_contains "$suspects" "CI|E2E|AUTH-1" "writes the suspect key"

# --------------------------------------------------------------------------
echo
echo "dedupe — re-running enforces nothing new"
# --------------------------------------------------------------------------
make_gh "$T/gh" "https://github.com/o/r/issues/999" "shipyard,blocked:ci"  # exists + labeled
: > "$GH_LOG"
out="$(SHIPYARD_HOME="$T/home" GH="$T/gh" "$enforce" enforce --repo o/r --repo-root "$T/repo" 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "issue create" "dedupe: no duplicate issue created"
assert_not_contains "$ghlog" "pr edit" "dedupe: no re-label of already-blocked PRs"
assert_contains "$out" "file-tracking-issue skip (exists)" "dedupe: reports issue skip"
assert_contains "$out" "stop-auto-rerunning skip" "dedupe: reports suspect skip"
count="$(grep -c '^CI|E2E|AUTH-1$' "$T/repo/.shipyard/flake-suspects.txt")"
assert_equals "$count" "1" "dedupe: suspect key present exactly once after two runs"

# --------------------------------------------------------------------------
echo
echo "per-row actions — a row omitting an action skips it"
# --------------------------------------------------------------------------
T="${WORK}/perrow"; mkdir -p "$T/repo"
make_gh "$T/gh" "" "shipyard"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
# Feed a crossed row that only requests stop-auto-rerunning.
crossed='[{"repo":"o/r","workflow":"CI","job":"E2E","test":"X","events":3,"distinct_prs":2,"prs":[5,6],"actions":["stop-auto-rerunning"]}]'
out="$(printf '%s' "$crossed" | SHIPYARD_HOME="$T/home" GH="$T/gh" "$enforce" enforce --repo o/r --repo-root "$T/repo" --from-stdin 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "issue create" "per-row: file-tracking-issue NOT run when omitted"
assert_not_contains "$ghlog" "pr edit" "per-row: apply-blocked-ci NOT run when omitted"
assert_contains "$(cat "$T/repo/.shipyard/flake-suspects.txt")" "CI|E2E|X" "per-row: stop-auto-rerunning DID run"

# --------------------------------------------------------------------------
echo
echo "nothing-crossed — empty array is a clean no-op"
# --------------------------------------------------------------------------
T="${WORK}/empty"; mkdir -p "$T/repo"
: > "${WORK}/empty.log"
out="$(printf '[]' | GH_LOG="${WORK}/empty.log" "$enforce" enforce --repo o/r --repo-root "$T/repo" --from-stdin 2>&1)"; rc=$?
assert_exit "$rc" "0" "empty crossed exits 0"
if [[ ! -e "$T/repo/.shipyard/flake-suspects.txt" ]]; then
  printf '  %sPASS%s  empty crossed wrote nothing\n' "$GREEN" "$RESET"; pass=$((pass+1))
else
  printf '  %sFAIL%s  empty crossed should write nothing\n' "$RED" "$RESET"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "suspects-list / is-suspect — the consumer side"
# --------------------------------------------------------------------------
T="${WORK}/consume"; mkdir -p "$T/repo/.shipyard"
cat > "$T/repo/.shipyard/flake-suspects.txt" <<EOF
# a comment line
CI|E2E|AUTH-1

CI|Unit|
EOF
listed="$("$enforce" suspects-list --repo-root "$T/repo")"
assert_contains "$listed" "CI|E2E|AUTH-1" "suspects-list emits a key"
assert_contains "$listed" "CI|Unit|" "suspects-list emits a workflow+job-only key"
assert_not_contains "$listed" "# a comment" "suspects-list strips comments"
# Exactly two non-empty lines remain after stripping comments + blanks.
listed_lines="$(printf '%s\n' "$listed" | grep -c .)"
assert_equals "$listed_lines" "2" "suspects-list strips comments and blank lines (2 keys remain)"

"$enforce" is-suspect --key "CI|E2E|AUTH-1" --repo-root "$T/repo"; rc=$?
assert_exit "$rc" "0" "is-suspect exit 0 for present key"
"$enforce" is-suspect --key "CI|E2E|NOPE" --repo-root "$T/repo"; rc=$?
assert_exit "$rc" "1" "is-suspect exit 1 for absent key"
"$enforce" is-suspect --repo-root "$T/repo" 2>/dev/null; rc=$?
assert_exit "$rc" "64" "is-suspect exit 64 when --key missing"

# is-suspect against a repo with no suspects file → exit 1 (not an error).
T2="${WORK}/nosuspects"; mkdir -p "$T2/repo"
"$enforce" is-suspect --key "CI|E2E|AUTH-1" --repo-root "$T2/repo"; rc=$?
assert_exit "$rc" "1" "is-suspect exit 1 when suspects file absent"

# --------------------------------------------------------------------------
echo
echo "usage errors"
# --------------------------------------------------------------------------
"$enforce" 2>/dev/null; rc=$?
assert_exit "$rc" "64" "no subcommand exits 64"
"$enforce" bogus 2>/dev/null; rc=$?
assert_exit "$rc" "64" "unknown subcommand exits 64"

# --------------------------------------------------------------------------
echo
echo "============================"
printf 'PASS: %d  FAIL: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
