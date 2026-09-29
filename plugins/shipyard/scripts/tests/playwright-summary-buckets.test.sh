#!/usr/bin/env bash
# Test suite for scripts/playwright-summary-buckets.sh (issue #1598).
#
# Covers:
#   usage / arg validation      — missing args, conflicting sources, unknown subcommand
#   the #1598 repro             — 1 failed + 2 flaky: only the failed spec is `failed`;
#                                 the two retry-recovered specs are `flaky`, even though
#                                 all three carry `##[error]` annotations in the log
#   annotation-only spec        — a spec named only in `##[error]` lines is `absent`
#   GH timestamp + ANSI prefixes — stripped before matching
#   last summary wins           — an earlier summary block is discarded
#   no summary at all           — parse/classify exit 3 (indeterminate, never a pass)
#   --repo/--job fetch path     — mocked via $GH; fetch failure exits 66
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/playwright-summary-buckets.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../playwright-summary-buckets.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: helper not found at $script" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want: %s\n' "$want"
    printf '    got:  %s\n' "$got"
    fail=$((fail+1))
  fi
}

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "playwright-summary-buckets.sh test suite"
echo "========================================"

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(bash "$script" parse 2>&1)"; rc=$?
assert_contains "$out" "required" "parse with no source errors"
assert_eq "$rc" "64" "parse with no source exits 64"

out="$(bash "$script" parse --log /dev/null --repo o/r --job 1 2>&1)"; rc=$?
assert_eq "$rc" "64" "--log together with --repo/--job exits 64"

out="$(bash "$script" classify --log /dev/null 2>&1)"; rc=$?
assert_contains "$out" "--spec is required" "classify without --spec errors"
assert_eq "$rc" "64" "classify without --spec exits 64"

out="$(bash "$script" bogus 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand is rejected"
assert_eq "$rc" "64" "unknown subcommand exits 64"

out="$(bash "$script" parse --log "${WORK}/does-not-exist.log" 2>&1)"; rc=$?
assert_eq "$rc" "66" "unreadable log exits 66"

# --------------------------------------------------------------------------
echo
echo "the #1598 repro — 1 failed, 2 flaky, all three annotated with ##[error]"
# --------------------------------------------------------------------------
ESC=$'\033'
REPRO="${WORK}/repro.log"
{
  echo "2026-09-19T08:00:00.0000000Z Running 277 tests using 4 workers"
  echo "2026-09-19T08:05:00.0000000Z ##[error]  1) [chromium] › e2e/web/cookie-consent.spec.ts:325:5 › COOKIE-CONSENT-7 some title"
  echo "2026-09-19T08:06:00.0000000Z ##[error]  2) [chromium] › e2e/web/recurring-series.spec.ts:251:5 › RECURRING-SERIES-4 other"
  echo "2026-09-19T08:07:00.0000000Z ##[error]  3) [chromium] › e2e/web/tasks-crud.spec.ts:586:5 › TASKS-CRUD-12 third"
  echo "2026-09-19T08:38:00.0000000Z "
  echo "2026-09-19T08:38:00.0000000Z   ${ESC}[31m1 failed${ESC}[39m"
  echo "2026-09-19T08:38:00.0000000Z     [chromium] › e2e/web/cookie-consent.spec.ts:325:5 › COOKIE-CONSENT-7 some title "
  echo "2026-09-19T08:38:00.0000000Z   ${ESC}[33m2 flaky${ESC}[39m"
  echo "2026-09-19T08:38:00.0000000Z     [chromium] › e2e/web/recurring-series.spec.ts:251:5 › RECURRING-SERIES-4 other "
  echo "2026-09-19T08:38:00.0000000Z     [chromium] › e2e/web/tasks-crud.spec.ts:586:5 › TASKS-CRUD-12 third "
  echo "2026-09-19T08:38:00.0000000Z   8 skipped"
  echo "2026-09-19T08:38:00.0000000Z   ${ESC}[32m266 passed${ESC}[39m${ESC}[2m (38.7m)${ESC}[22m"
  echo "2026-09-19T08:38:01.0000000Z ##[error]Process completed with exit code 1."
} > "$REPRO"

out="$(bash "$script" parse --log "$REPRO")"; rc=$?
assert_eq "$rc" "0" "parse exits 0 when a summary is present"
assert_eq "$(jq -r '.summary_found' <<< "$out")" "true" "summary_found is true"
assert_eq "$(jq -r '.failed | length' <<< "$out")" "1" "exactly one failed entry"
assert_contains "$(jq -r '.failed[0]' <<< "$out")" "COOKIE-CONSENT-7" "the failed entry is COOKIE-CONSENT-7"
assert_eq "$(jq -r '.flaky | length' <<< "$out")" "2" "exactly two flaky entries"
assert_eq "$(jq -c '.counts' <<< "$out")" '{"failed":1,"flaky":2,"skipped":8,"passed":266}' "bucket counts parsed (ANSI + timestamp stripped)"

assert_eq "$(bash "$script" classify --log "$REPRO" --spec "cookie-consent.spec.ts:325")" "failed" "COOKIE-CONSENT-7 classifies as failed"
assert_eq "$(bash "$script" classify --log "$REPRO" --spec "RECURRING-SERIES-4")" "flaky" "RECURRING-SERIES-4 classifies as flaky, despite its ##[error] annotation"
assert_eq "$(bash "$script" classify --log "$REPRO" --spec "tasks-crud.spec.ts:586")" "flaky" "TASKS-CRUD-12 classifies as flaky, despite its ##[error] annotation"
assert_eq "$(bash "$script" classify --log "$REPRO" --spec "nonexistent.spec.ts")" "absent" "an unnamed spec classifies as absent"

# --------------------------------------------------------------------------
echo
echo "annotation-only spec — named in ##[error] but in no summary failure bucket"
# --------------------------------------------------------------------------
ANNOT="${WORK}/annot.log"
cat > "$ANNOT" <<'EOF'
##[error]  1) [chromium] › e2e/web/settings.spec.ts:40:5 › SETTINGS-2 retried once
  1 flaky
    [chromium] › e2e/web/settings.spec.ts:40:5 › SETTINGS-2 retried once
  50 passed (3.1m)
EOF
assert_eq "$(bash "$script" classify --log "$ANNOT" --spec "SETTINGS-2")" "flaky" "flaky-only spec is flaky, not failed"
out="$(bash "$script" parse --log "$ANNOT")"
assert_eq "$(jq -r '.failed | length' <<< "$out")" "0" "no failed entries when every annotation recovered on retry"

# --------------------------------------------------------------------------
echo
echo "no-project entries, interrupted + did-not-run buckets"
# --------------------------------------------------------------------------
PLAIN="${WORK}/plain.log"
cat > "$PLAIN" <<'EOF'
  1 failed
    tests/login.spec.ts:12:3 › logs in
  1 interrupted
    tests/upload.test.ts:9:1 › uploads
  2 did not run
  4 passed (10s)
EOF
out="$(bash "$script" parse --log "$PLAIN")"
assert_eq "$(jq -r '.failed[0]' <<< "$out")" "tests/login.spec.ts:12:3 › logs in" "entry without a [project] prefix is captured"
assert_eq "$(jq -r '.counts.did_not_run' <<< "$out")" "2" "did-not-run count captured under did_not_run"
assert_eq "$(bash "$script" classify --log "$PLAIN" --spec "upload.test.ts")" "failed" "interrupted spec classifies as failed"

# --------------------------------------------------------------------------
echo
echo "last summary wins"
# --------------------------------------------------------------------------
TWO="${WORK}/two.log"
cat > "$TWO" <<'EOF'
  1 failed
    [chromium] › e2e/a.spec.ts:1:1 › A
  3 passed (1s)
Rerunning...
  1 flaky
    [chromium] › e2e/a.spec.ts:1:1 › A
  3 passed (1s)
EOF
assert_eq "$(bash "$script" classify --log "$TWO" --spec "e2e/a.spec.ts")" "flaky" "an earlier summary block is discarded"

# --------------------------------------------------------------------------
echo
echo "no summary — indeterminate, never a pass"
# --------------------------------------------------------------------------
NONE="${WORK}/none.log"
printf '%s\n' "##[error]  1) [chromium] › e2e/x.spec.ts:1:1 › X" "##[error]Process completed with exit code 1." > "$NONE"
out="$(bash "$script" parse --log "$NONE")"; rc=$?
assert_eq "$rc" "3" "parse exits 3 with no summary"
assert_eq "$(jq -r '.summary_found' <<< "$out")" "false" "summary_found is false"
out="$(bash "$script" classify --log "$NONE" --spec "x.spec.ts")"; rc=$?
assert_eq "$out" "indeterminate" "classify reports indeterminate with no summary"
assert_eq "$rc" "3" "classify exits 3 with no summary"

# --------------------------------------------------------------------------
echo
echo "--repo/--job fetch path (mocked gh)"
# --------------------------------------------------------------------------
GH_OK="${WORK}/gh-ok"
cat > "$GH_OK" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [ "\$2" = "repos/o/r/actions/jobs/42/logs" ]; then
  cat "${REPRO}"
  exit 0
fi
exit 1
MOCK
chmod +x "$GH_OK"
assert_eq "$(GH="$GH_OK" bash "$script" classify --repo o/r --job 42 --spec "TASKS-CRUD-12")" "flaky" "fetched job log is parsed"

GH_FAIL="${WORK}/gh-fail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$GH_FAIL"
chmod +x "$GH_FAIL"
out="$(GH="$GH_FAIL" bash "$script" parse --repo o/r --job 42 2>&1)"; rc=$?
assert_eq "$rc" "66" "a failed log fetch exits 66"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
