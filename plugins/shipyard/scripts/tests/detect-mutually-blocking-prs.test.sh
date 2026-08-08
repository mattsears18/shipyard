#!/usr/bin/env bash
# Test: the mutually-blocking-PR detector — decide whether two open PRs each
# pass a required check the other is failing, so neither can go green alone
# (issue #1140).
#
# Background — issue #1140
# -------------------------
# Two open PRs each fixed the exact required check the OTHER was failing:
#
#   PR #3612 (scopes the npm-audit gate)  — passes Lint&Typecheck, fails E2E
#   PR #3614 (fixes the E2E flake)        — passes E2E, fails Lint&Typecheck
#
# Neither could go green alone, stalling an 11-PR-deep merge train, and the
# drain's only response was `blocked:ci` on both PRs with the real
# explanation ("these two unblock each other") recorded nowhere.
#
# This test pins:
#   (A) the detector's pairwise decision truth table (pure `--decide-pair`
#       mode);
#   (B) the live signal-extraction helpers (csv_subset, the latest-per-name
#       rollup dedup in pr_required_check_sets, files_disjoint) behave
#       correctly against synthetic/mocked `gh` output;
#   (C) the live end-to-end `main()` flow reproduces the #1140 repro shape
#       (3612<->3614 mutually block; an unrelated third red PR does not
#       pair with either) against a fully mocked `gh` binary on PATH;
#   (D) drain.md wires the detector in as a per-poll, surfacing-only step
#       BEFORE the per-poll dispatch actions, with the idempotency sentinel
#       and the explicit no-routing-change statement;
#   (E) cleanup-summary.md carries the dedicated summary line, correctly
#       gated to omit-when-empty;
#   (F) do-work-RATIONALE.md documents why automated combining is out of
#       scope for this PR.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-mutually-blocking-prs.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-mutually-blocking-prs.sh"
DRAIN_MD="$repo_root/plugins/shipyard/commands/do-work/drain.md"
SUMMARY_MD="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
RATIONALE_MD="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "Mutually-blocking PR detector regression tests (issue #1140)"
echo

# ---------------------------------------------------------------------------
# (A) decide_pair() — pure pairwise decision truth table.
# ---------------------------------------------------------------------------
echo "(A) detector script — pairwise decision truth table (--decide-pair)"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-mutually-blocking-prs.sh exists"

  assert_verdict() {
    local got
    got="$(bash "$DETECTOR" --decide-pair "$1" "$2" "$3" "$4" 2>/dev/null)"
    assert_equals "$6" "$5" "$got"
  }

  # The #1140 repro shape itself: each PR's single failing required check is
  # exactly what the other passes.
  assert_verdict "e2e" "lint" "lint" "e2e" \
    mutually-blocking "repro shape: A fails e2e/passes lint, B fails lint/passes e2e"

  # Neither PR has any failing required check -> nothing to block on.
  assert_verdict "" "" "" "" \
    independent "no failing checks on either side is independent"

  # A has a failing check but B has none -> B isn't blocked, so not mutual.
  assert_verdict "e2e" "lint" "" "lint,e2e" \
    independent "only one side has a failing required check is independent"

  # A's failing check is NOT among B's passing checks -> B's fix wouldn't
  # help A at all.
  assert_verdict "e2e" "lint" "unrelated-check" "e2e" \
    independent "A's failure isn't covered by B's passing set is independent"

  # Partial coverage: B covers A's failure, but A does NOT cover ALL of B's
  # failures (B fails two required checks, A only passes one of them) -> not
  # a COMPLETE blocking set, so independent (issue #1140 step 2: "the
  # failures are the complete blocking set").
  assert_verdict "e2e" "lint" "lint,typecheck" "e2e" \
    independent "partial coverage (B fails 2 checks, A only covers 1) is independent"

  # Full multi-check mutual coverage still resolves to mutually-blocking.
  assert_verdict "e2e,typecheck" "lint,security" "lint,security" "e2e,typecheck" \
    mutually-blocking "full multi-check mutual coverage is mutually-blocking"

  # A PR failing AND passing the exact same check name is a malformed signal
  # (shouldn't happen from a real rollup — a check has one latest
  # conclusion), but the pure function must not crash on it; the CSV-subset
  # test only cares about presence, so this still resolves deterministically.
  assert_verdict "e2e" "e2e" "e2e" "e2e" \
    mutually-blocking "self-consistent (degenerate) input does not crash the decision"
else
  assert_fail "detect-mutually-blocking-prs.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Live signal-extraction helpers, sourced with the trailing `main "$@"`
#     stripped off, `gh` shadowed by a shell function for hermetic testing.
# ---------------------------------------------------------------------------
echo "(B) signal extraction — csv_subset, latest-per-name rollup dedup, files_disjoint"
if [[ -f "$DETECTOR" ]]; then
  tmp_src="$(mktemp)"
  sed '$d' "$DETECTOR" > "$tmp_src"
  # shellcheck disable=SC1090
  source "$tmp_src"
  rm -f "$tmp_src"

  # csv_subset / csv_has direct checks.
  if csv_subset "lint,e2e" "lint,e2e,security"; then
    assert_pass "csv_subset: full needle coverage in a larger haystack"
  else
    assert_fail "csv_subset: full needle coverage in a larger haystack"
  fi

  if csv_subset "lint,e2e" "lint"; then
    assert_fail "csv_subset: partial coverage should NOT be a subset"
  else
    assert_pass "csv_subset: partial coverage correctly rejected"
  fi

  if csv_subset "" "anything"; then
    assert_pass "csv_subset: empty needle is vacuously a subset"
  else
    assert_fail "csv_subset: empty needle is vacuously a subset"
  fi

  # pr_required_check_sets: a stale FAILURE superseded by a later SUCCESS on
  # the SAME check name must not count (issue #333's latest-per-name rule,
  # reused here) -- and a check name NOT in the required set must be ignored
  # even though it fails.
  # shellcheck disable=SC2329 # invoked indirectly by the sourced pr_required_check_sets(), which shellcheck can't trace through the dynamically-generated tmp_src
  gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then
      cat <<'JSON'
{"statusCheckRollup":[
  {"name":"lint","conclusion":"SUCCESS","completedAt":"2026-08-08T00:00:00Z"},
  {"name":"e2e","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"},
  {"name":"e2e","conclusion":"SUCCESS","completedAt":"2026-08-08T00:05:00Z"},
  {"name":"unrelated-optional-check","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"}
]}
JSON
    fi
  }
  required_json='["lint","e2e"]'
  out="$(pr_required_check_sets "owner/repo" 1 "$required_json")"
  assert_equals "pr_required_check_sets: stale FAILURE superseded by later SUCCESS is not counted, non-required check ignored" \
    "|e2e,lint" "$out"

  # files_disjoint: no overlap -> "1", overlap -> "0", unreadable -> "unknown".
  gh() {
    if [[ "$1" == "pr" && "$2" == "diff" ]]; then
      case "$3" in
        10) printf 'a.ts\nb.ts\n' ;;
        11) printf 'c.ts\n' ;;
        20) printf 'shared.ts\n' ;;
        21) printf 'shared.ts\nd.ts\n' ;;
        30) printf '' ;;
        31) printf 'e.ts\n' ;;
      esac
    fi
  }
  assert_equals "files_disjoint: no shared files" "1" "$(files_disjoint owner/repo 10 11)"
  assert_equals "files_disjoint: shared file present" "0" "$(files_disjoint owner/repo 20 21)"
  assert_equals "files_disjoint: one side unreadable -> unknown" "unknown" "$(files_disjoint owner/repo 30 31)"
else
  assert_fail "detect-mutually-blocking-prs.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (C) Live end-to-end main() — the #1140 repro shape, against a fully mocked
#     `gh` binary on PATH (three PRs: 3612<->3614 mutually block; 3699 fails
#     BOTH required checks and pairs with neither).
# ---------------------------------------------------------------------------
echo "(C) live end-to-end scan — reproduces the #1140 repro shape"
if [[ -f "$DETECTOR" ]]; then
  fakebin="$(mktemp -d)"
  cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo "main"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  case "$2" in
    *protection/required_status_checks/contexts*) printf 'Lint & Typecheck\nWeb E2E Tests\n' ;;
    *) printf '' ;;
  esac
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case "$3" in
    3612)
      cat <<'JSON'
{"statusCheckRollup":[
  {"name":"Lint & Typecheck","conclusion":"SUCCESS","completedAt":"2026-08-08T00:00:00Z"},
  {"name":"Web E2E Tests","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"}
]}
JSON
      ;;
    3614)
      cat <<'JSON'
{"statusCheckRollup":[
  {"name":"Lint & Typecheck","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"},
  {"name":"Web E2E Tests","conclusion":"SUCCESS","completedAt":"2026-08-08T00:00:00Z"}
]}
JSON
      ;;
    3699)
      cat <<'JSON'
{"statusCheckRollup":[
  {"name":"Lint & Typecheck","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"},
  {"name":"Web E2E Tests","conclusion":"FAILURE","completedAt":"2026-08-08T00:00:00Z"}
]}
JSON
      ;;
  esac
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
  case "$3" in
    3612) printf 'src/audit-scope.ts\n' ;;
    3614) printf 'src/e2e-fixture.ts\n' ;;
    3699) printf 'src/other.ts\n' ;;
  esac
  exit 0
fi
FAKEGH
  chmod +x "$fakebin/gh"

  scan_out="$(PATH="$fakebin:$PATH" bash "$DETECTOR" owner/repo 3612 3614 3699 2>/dev/null)"
  scan_exit=$?
  rm -rf "$fakebin"

  assert_equals "live scan exit code" "0" "$scan_exit"
  assert_equals "live scan finds exactly the 3612<->3614 pair, file-disjoint" \
    "3612,3614,1" "$scan_out"

  pair_count="$(printf '%s\n' "$scan_out" | grep -c ',' || true)"
  assert_equals "live scan reports exactly one pair (3699 pairs with neither)" "1" "$pair_count"
else
  assert_fail "detect-mutually-blocking-prs.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (D) drain.md — wired in as a per-poll, surfacing-only step BEFORE the
#     per-poll dispatch actions; explicit no-routing-change statement;
#     idempotency sentinel present.
# ---------------------------------------------------------------------------
echo "(D) drain.md — wiring, ordering, and no-routing-change guarantee"
if [[ -f "$DRAIN_MD" ]]; then
  assert_pass "drain.md exists"
  assert_contains "$DRAIN_MD" 'detect-mutually-blocking-prs.sh' \
    "drain.md invokes detect-mutually-blocking-prs.sh"
  assert_contains "$DRAIN_MD" 'do-work-mutually-blocking pr-pair=' \
    "drain.md uses the idempotency sentinel to avoid re-posting every poll"
  assert_contains "$DRAIN_MD" 'does not change dispatch routing' \
    "drain.md states explicitly that detection does not change dispatch routing"
  assert_contains "$DRAIN_MD" 'Automated combining' \
    "drain.md names automated combining as explicitly out of scope"
  assert_contains "$DRAIN_MD" 'mutually_blocking_pairs_detected' \
    "drain.md tracks a per-session mutually_blocking_pairs_detected counter"

  # Ordering: the "Mutually-blocking PR detection" heading must appear
  # BEFORE the "**Per-poll actions.**" heading it's meant to precede.
  mb_line="$(grep -n '^### Mutually-blocking PR detection' "$DRAIN_MD" | head -1 | cut -d: -f1)"
  actions_line="$(grep -n '^\*\*Per-poll actions\.\*\*' "$DRAIN_MD" | head -1 | cut -d: -f1)"
  if [[ -n "$mb_line" && -n "$actions_line" && "$mb_line" -lt "$actions_line" ]]; then
    assert_pass "mutually-blocking detection section precedes Per-poll actions (line $mb_line < $actions_line)"
  else
    assert_fail "mutually-blocking detection section precedes Per-poll actions (mb=$mb_line, actions=$actions_line)"
  fi
else
  assert_fail "drain.md exists (missing at $DRAIN_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (E) cleanup-summary.md — dedicated, omit-when-empty summary line.
# ---------------------------------------------------------------------------
echo "(E) cleanup-summary.md — end-of-session summary line"
if [[ -f "$SUMMARY_MD" ]]; then
  assert_pass "cleanup-summary.md exists"
  assert_contains "$SUMMARY_MD" 'Mutually-blocking PRs (#1140):' \
    "cleanup-summary.md's example block carries the Mutually-blocking PRs line"
  assert_contains "$SUMMARY_MD" "\`Mutually-blocking PRs (#1140)\`: **omit entirely**" \
    "cleanup-summary.md's per-line rules gate the line to omit-when-empty"
else
  assert_fail "cleanup-summary.md exists (missing at $SUMMARY_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (F) do-work-RATIONALE.md — documents why automated combining is deferred.
# ---------------------------------------------------------------------------
echo "(F) do-work-RATIONALE.md — combining-out-of-scope rationale"
if [[ -f "$RATIONALE_MD" ]]; then
  assert_pass "do-work-RATIONALE.md exists"
  assert_contains "$RATIONALE_MD" 'Mutually-blocking PR detection — why combining is out of scope' \
    "RATIONALE documents why combining is out of scope for #1140"
else
  assert_fail "do-work-RATIONALE.md exists (missing at $RATIONALE_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
