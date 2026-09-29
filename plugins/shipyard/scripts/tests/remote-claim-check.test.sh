#!/usr/bin/env bash
# Test suite for scripts/remote-claim-check.sh (issue #1606).
#
# The per-dispatch remote in-flight-claim guard: before /do-work dispatches
# an issue-work worker for #N, look at the REMOTE for evidence that some
# other session — shipyard or not — is already working it (an open PR that
# closes it, an open PR on an issue-<N>/slice-<N> branch, or a freshly
# pushed do-work/issue-<N> branch with no PR yet). detect-peer-sessions.sh
# only sees sessions that write $SHIPYARD_HOME/sessions/*.json, which is
# the #1606 gap.
#
# `classify` is pure and covered directly; `check` is covered against a
# PATH-prepended gh stub (same pattern as classify-backlog.test.sh).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/remote-claim-check.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../remote-claim-check.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
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

# Fixed clock: 2026-09-26T14:00:00Z
NOW=1790431200
FRESH="2026-09-26T13:30:00Z"   # 30 min before NOW
STALE="2026-09-26T10:00:00Z"   # 4 h before NOW

classify() {
  local issue="$1"; shift
  bash "$helper" classify --issue "$issue" --now "$NOW" "$@"
}

echo "== classify (pure)"

out=$(printf '{"prs":[],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=false" "(1) no PRs, no branches -> not claimed"

out=$(printf '{}' | classify 5351)
assert_equals "$out" "remote_claimed=false" "(2) missing keys default to empty"

out=$(printf '{"prs":[{"number":5353,"headRefName":"fix/tz-dates","closing":[5351]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=true signal=open-pr-closing ref=PR #5353" "(3) #1606 repro: a peer's open PR that closes the issue claims it, whatever its branch name"

out=$(printf '{"prs":[{"number":900,"headRefName":"do-work/issue-5351","closing":[]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=true signal=open-pr-branch ref=PR #900" "(4) an open PR on do-work/issue-<N> with no closing keyword (native draft, #785) claims it"

out=$(printf '{"prs":[{"number":901,"headRefName":"do-work/slice-5351","closing":[]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=true signal=open-pr-branch ref=PR #901" "(5) a split-dispatch slice branch (#1562) claims it"

out=$(printf '{"prs":[{"number":902,"headRefName":"feat/issue-5351-retry","closing":[]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=true signal=open-pr-branch ref=PR #902" "(6) a non-shipyard branch naming issue-<N> as a segment prefix claims it"

out=$(printf '{"prs":[{"number":903,"headRefName":"do-work/issue-53510","closing":[]},{"number":904,"headRefName":"tissue-5351","closing":[]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=false" "(7) issue-53510 and tissue-5351 do NOT match #5351 (digit and segment boundaries)"

out=$(printf '{"prs":[{"number":905,"headRefName":"x","closing":[1,2]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=false" "(8) a PR closing OTHER issues does not claim this one"

out=$(printf '{"prs":[{"number":906,"headRefName":"do-work/issue-5351","closing":[]},{"number":907,"headRefName":"y","closing":[5351]}],"branches":[]}' | classify 5351)
assert_equals "$out" "remote_claimed=true signal=open-pr-closing ref=PR #907" "(9) open-pr-closing outranks open-pr-branch"

out=$(printf '{"prs":[],"branches":[{"name":"do-work/issue-5351","committed_at":"%s"}]}' "$FRESH" | classify 5351)
assert_equals "$out" "remote_claimed=true signal=remote-branch ref=do-work/issue-5351" "(10) a fresh pushed branch with no PR yet claims it"

out=$(printf '{"prs":[],"branches":[{"name":"do-work/issue-5351","committed_at":"%s"}]}' "$STALE" | classify 5351)
assert_equals "$out" "remote_claimed=false" "(11) a branch older than the default 120-min window is abandoned, not a claim"

out=$(printf '{"prs":[],"branches":[{"name":"do-work/issue-5351","committed_at":"%s"}]}' "$STALE" | classify 5351 --window-min 300)
assert_equals "$out" "remote_claimed=true signal=remote-branch ref=do-work/issue-5351" "(12) --window-min widens the freshness window"

out=$(printf '{"prs":[],"branches":[{"name":"do-work/issue-5351","committed_at":null}]}' | classify 5351)
assert_equals "$out" "remote_claimed=false" "(13) a branch with no readable commit date is not counted"

echo "== usage"

bash "$helper" classify </dev/null >/dev/null 2>&1; rc=$?
assert_equals "$rc" "64" "(14) classify without --issue exits 64"

printf '[1]' | bash "$helper" classify --issue 1 >/dev/null 2>&1; rc=$?
assert_equals "$rc" "64" "(15) non-object stdin exits 64"

bash "$helper" check --issue 1 >/dev/null 2>&1; rc=$?
assert_equals "$rc" "64" "(16) check without --repo exits 64"

bash "$helper" bogus --issue 1 >/dev/null 2>&1; rc=$?
assert_equals "$rc" "64" "(17) unknown subcommand exits 64"

bash "$helper" classify --issue 1 --window-min abc </dev/null >/dev/null 2>&1; rc=$?
assert_equals "$rc" "64" "(18) non-integer --window-min exits 64"

echo "== check (stubbed gh)"

WORK="$(mktemp -d 2>/dev/null || true)"
if [[ -n "$WORK" && -d "$WORK" ]]; then
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
# Driven by env: STUB_PRS (projected pr list JSON), STUB_SHA_ISSUE /
# STUB_SHA_SLICE (sha or empty), STUB_DATE, STUB_FAIL (pr|ref|commit).
case "$1" in
  pr)
    [ "${STUB_FAIL:-}" = "pr" ] && exit 1
    printf '%s\n' "${STUB_PRS:-[]}" ;;
  api)
    case "$2" in
      */git/matching-refs/heads/do-work/issue-*)
        [ "${STUB_FAIL:-}" = "ref" ] && exit 1
        printf '%s\n' "${STUB_SHA_ISSUE:-}" ;;
      */git/matching-refs/heads/do-work/slice-*)
        printf '%s\n' "${STUB_SHA_SLICE:-}" ;;
      */commits/*)
        [ "${STUB_FAIL:-}" = "commit" ] && exit 1
        printf '%s\n' "${STUB_DATE:-}" ;;
    esac ;;
esac
exit 0
GHMOCK
  chmod +x "$WORK/bin/gh"

  run_check() { PATH="$WORK/bin:$PATH" bash "$helper" check --repo o/r --issue 5351 --now "$NOW" 2>/dev/null; }

  out=$(STUB_PRS='[]' run_check)
  assert_equals "$out" "remote_claimed=false" "(19) check: nothing on the remote -> not claimed"

  out=$(STUB_PRS='[{"number":5353,"headRefName":"fix/x","closing":[5351]}]' run_check)
  assert_equals "$out" "remote_claimed=true signal=open-pr-closing ref=PR #5353" "(20) check: #1606 repro shape — peer's closing PR is seen"

  out=$(STUB_PRS='[]' STUB_SHA_ISSUE=abc123 STUB_DATE="$FRESH" run_check)
  assert_equals "$out" "remote_claimed=true signal=remote-branch ref=do-work/issue-5351" "(21) check: fresh pushed branch without a PR is seen"

  out=$(STUB_PRS='[]' STUB_SHA_SLICE=def456 STUB_DATE="$STALE" run_check)
  assert_equals "$out" "remote_claimed=false" "(22) check: a stale slice branch is ignored"

  out=$(STUB_FAIL="pr" run_check)
  assert_equals "$out" "remote_claimed=unknown reason=gh-pr-list-failed" "(23) check: a gh pr list failure fails OPEN as unknown"

  out=$(STUB_PRS='[]' STUB_FAIL="ref" run_check)
  assert_equals "$out" "remote_claimed=unknown reason=gh-ref-lookup-failed" "(24) check: a ref-lookup failure reports unknown"

  out=$(STUB_PRS='[]' STUB_SHA_ISSUE=abc STUB_FAIL="commit" run_check)
  assert_equals "$out" "remote_claimed=unknown reason=gh-commit-lookup-failed" "(25) check: a commit-lookup failure reports unknown"

  PATH="$WORK/bin:$PATH" STUB_FAIL=pr bash "$helper" check --repo o/r --issue 5351 >/dev/null 2>&1; rc=$?
  assert_equals "$rc" "0" "(26) check: unknown still exits 0 (never fails the dispatch turn)"

  rm -rf "$WORK"
fi

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
