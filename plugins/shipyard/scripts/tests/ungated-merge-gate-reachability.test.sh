#!/usr/bin/env bash
# Test: the ungated-admin-direct-merge gate is RELIABLY REACHED on every
# issue-work merge path, and its condition exists in exactly one place
# (issue #716).
#
# Background — issue #716
# -----------------------
# The #598/#602 pre-merge check-wait ("don't let `gh pr merge --auto` land a PR
# before its own CI completes on a repo where --auto doesn't actually queue")
# was implemented, tested, and *correct* — yet it did not fire for the worker on
# PR #715, which admin-direct-merged while CI was still IN_PROGRESS. Its sibling
# worker on PR #713, same session and same repo shape, DID hold for its checks.
#
# The condition was never wrong. It was *unreachable* on one of the two paths,
# because it existed as prose in TWO files that had drifted apart:
#
#   skills/worker-preamble/auto-merge.md §0.5  (on-demand fragment) — CORRECT:
#     fires on admin AND (allow_auto_merge==false OR required_checks==0), and
#     says explicitly "Do NOT skip on ALLOW_AUTO_MERGE == true alone."
#
#   agents/issue-worker/issue-work.md §6 (loaded by EVERY issue-work worker) — WRONG:
#     (a) put the `gh pr merge --auto` fenced block BEFORE the "First run the
#         pre-check" paragraph, so a worker executing commands as it read had
#         already merged by the time it reached the guard;
#     (b) restated the trigger as an AND of all three signals (shape 1 / #438
#         only), omitting shape 2 (#465), and named "repo allows auto-merge" as
#         a *skip* condition — the exact inverse of the fragment's rule. On
#         mattsears18/shipyard (allow_auto_merge: TRUE + admin + zero required
#         checks) that text affirmatively instructs the worker to skip the wait;
#     (c) hard-coded "because allow_auto_merge: false" as the cause of a
#         merged-direct outcome — which is verbatim what the #715 worker
#         reported back ("auto-merge isn't enabled on the repo") on a repo where
#         allow_auto_merge is demonstrably true, proving it was reciting the doc
#         rather than reading the API.
#
# The fix: extract the condition into ONE executable script
# (scripts/detect-ungated-admin-direct-merge.sh) that both call sites invoke,
# and reorder issue-work.md §6 so the guard structurally precedes the merge.
# A condition restated in prose in two files WILL drift; a condition that is one
# command cannot.
#
# This test pins:
#   (A) the detector script exists and its decision truth table is correct —
#       especially the #465/#715 shape (admin + allow_auto_merge TRUE + zero
#       required checks => ungated), which is the case that regressed;
#   (B) issue-work.md §6 invokes the guard BEFORE any `gh pr merge --auto`
#       (the ordering trap);
#   (C) issue-work.md no longer carries the shape-1-only skip language;
#   (D) both call sites reference the one script (no third prose copy).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/ungated-merge-gate-reachability.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-ungated-admin-direct-merge.sh"
ISSUE_WORK_MD="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
AUTO_MERGE_MD="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_fail "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
  else
    assert_pass "$label"
  fi
}

# decide <viewer> <allow_auto_merge> <required_checks> <expected> <label>
assert_verdict() {
  local got
  got="$(bash "$DETECTOR" --decide "$1" "$2" "$3" 2>/dev/null)"
  if [[ "$got" == "$4" ]]; then
    assert_pass "$5 (perm=$1 allow_auto_merge=$2 required_checks=${3:-<unreadable>} => $got)"
  else
    assert_fail "$5 (perm=$1 allow_auto_merge=$2 required_checks=${3:-<unreadable>} => expected [$4], got [$got])"
  fi
}

echo "ungated-admin-direct-merge gate reachability regression tests (issue #716)"
echo

# ---------------------------------------------------------------------------
# (A) The detector script: exists, and its decision logic is correct.
#
# This is the whole rule, so it gets a full truth table. The FIRST row is the
# #465/#715 shape — the one that regressed, and the reason this file exists.
# ---------------------------------------------------------------------------
echo "(A) detector script — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-ungated-admin-direct-merge.sh exists"

  # THE REGRESSION CASE (#465 / #602 / #716): allow_auto_merge is TRUE, yet with
  # zero required status checks an admin's --auto has no pending check to wait
  # on, so it merges IMMEDIATELY. This is mattsears18/shipyard's live shape and
  # the exact configuration PR #715 merged ungated under. If this row ever flips
  # to `gated`, the #716 bug is back.
  assert_verdict ADMIN    true  0  ungated \
    "#465/#715 shape: admin + allow_auto_merge TRUE + zero required checks is UNGATED"

  # Shape 1 (#438): no auto-merge queue exists to arm at all.
  assert_verdict ADMIN    false 0  ungated \
    "#438 shape 1: admin + allow_auto_merge false is ungated"
  assert_verdict ADMIN    false 3  ungated \
    "#438 shape 1 holds even when required checks ARE configured (no queue to arm)"

  # The genuinely-gated case. This row is why the gate must NOT be made
  # "unconditional whenever the viewer is admin" (issue #716's candidate 3):
  # on a ruleset-protected repo (e.g. lightwork's main, 4 required checks)
  # --auto really does queue, and forcing a --watch would block the worker for
  # the full CI duration and tie up its concurrency slot for no gain.
  assert_verdict ADMIN    true  4  gated \
    "required checks configured + auto-merge allowed => --auto genuinely queues (do NOT over-gate)"

  assert_verdict MAINTAIN true  0  ungated \
    "MAINTAIN also has the direct-merge fall-through"

  # Without ADMIN/MAINTAIN the direct-merge fall-through isn't permitted, so
  # --auto queues normally regardless of repo config.
  assert_verdict WRITE    true  0  gated \
    "non-admin cannot direct-merge => gated"
  assert_verdict WRITE    false 0  gated \
    "non-admin cannot direct-merge even with auto-merge disabled => gated"
  assert_verdict READ     false 0  gated \
    "read-only viewer => gated"

  # Fail-safe: an unreadable required-checks signal must resolve toward WAITING
  # (ungated), never toward merging. Waiting when we needn't costs one worker's
  # time; not waiting when we must lands a red commit on the default branch.
  assert_verdict ADMIN    true  ""  ungated \
    "unreadable required-checks signal fails SAFE (toward waiting), not toward merging"

  # The ruleset-aware probe (#645) must survive the extraction into the script:
  # classic branch protection and rulesets are separate mechanisms, and a
  # ruleset-gated branch reads 0 from the classic contexts endpoint.
  assert_contains "$DETECTOR" 'rules/branches/' \
    "detector probes the rulesets endpoint as a fallback (#645)"
  assert_contains "$DETECTOR" 'contains(["required_status_checks"])' \
    "detector's ruleset probe checks the required_status_checks rule (#645)"
  # It must NOT also gate on `pull_request`: that rule requires a PR but does
  # not gate the MERGE on CI, so including it would mark the shipyard shape
  # ([deletion, non_fast_forward, pull_request]) as gated and falsely SKIP the
  # protective wait — reintroducing #716.
  if grep -qF 'contains(["pull_request"])' "$DETECTOR"; then
    assert_fail "detector's ruleset probe must NOT gate on pull_request (would re-open #716)"
  else
    assert_pass "detector's ruleset probe does NOT gate on pull_request (#645/#716)"
  fi
else
  assert_fail "detect-ungated-admin-direct-merge.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) issue-work.md step 6 — ORDERING. The guard must be invoked BEFORE any
#     `gh pr merge --auto` appears in the step. This is the trap that let the
#     #715 worker merge before it ever reached the pre-check.
# ---------------------------------------------------------------------------
echo "(B) issue-work.md step 6 — guard precedes the merge call"
if [[ -f "$ISSUE_WORK_MD" ]]; then
  assert_pass "issue-work.md exists"

  step6_start=$(grep -n '^### 6\. Enable auto-merge' "$ISSUE_WORK_MD" | head -1 | cut -d: -f1)
  step7_start=$(grep -n '^### 7\.' "$ISSUE_WORK_MD" | head -1 | cut -d: -f1)

  if [[ -n "$step6_start" && -n "$step7_start" && "$step7_start" -gt "$step6_start" ]]; then
    step6=$(mktemp)
    sed -n "${step6_start},${step7_start}p" "$ISSUE_WORK_MD" > "$step6"

    guard_line=$(grep -n 'detect-ungated-admin-direct-merge.sh' "$step6" | head -1 | cut -d: -f1)
    # Match the EXECUTABLE command template, not prose mentions of the flag.
    # Throughout this file the runnable form always carries the `<pr-num>`
    # placeholder (`gh pr merge <pr-num> --repo <owner/repo> --auto ...`), while
    # narrative references write a bare "`gh pr merge --auto`". Only the former
    # is a command a worker would actually fire, so only the former can spring
    # the ordering trap.
    merge_line=$(grep -n 'gh pr merge <pr-num>.*--auto' "$step6" | head -1 | cut -d: -f1)

    if [[ -n "$guard_line" ]]; then
      assert_pass "step 6 invokes the ungated-merge detector"
    else
      assert_fail "step 6 invokes the ungated-merge detector"
    fi

    if [[ -n "$guard_line" && -n "$merge_line" && "$guard_line" -lt "$merge_line" ]]; then
      assert_pass "step 6 runs the detector BEFORE any \`gh pr merge --auto\` (guard=+$guard_line, merge=+$merge_line)"
    else
      assert_fail "step 6 runs the detector BEFORE any \`gh pr merge --auto\` (guard=+${guard_line:-absent}, merge=+${merge_line:-absent}) — the #716 ordering trap is back"
    fi

    # The ungated branch must prescribe the --watch-then-merge-if-green recovery.
    assert_contains "$step6" 'gh pr checks' \
      "step 6's ungated branch blocks on the PR's own checks"
    assert_contains "$step6" 'ungated' \
      "step 6 branches on the detector's ungated verdict"

    rm -f "$step6"
  else
    assert_fail "could not locate step 6 boundaries in issue-work.md (start=${step6_start:-?}, step7=${step7_start:-?})"
  fi
else
  assert_fail "issue-work.md exists (missing at $ISSUE_WORK_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (C) issue-work.md must NOT carry the shape-1-only prose that told the #715
#     worker to skip the gate on this repo.
# ---------------------------------------------------------------------------
echo "(C) issue-work.md — no shape-1-only skip language"
if [[ -f "$ISSUE_WORK_MD" ]]; then
  # The literal skip-condition list that named "repo allows auto-merge" as a
  # reason the pre-check does NOT fire. On admin + zero-required-checks repos
  # that is exactly backwards — shape 2 (#465) fires regardless of
  # allow_auto_merge.
  assert_not_contains "$ISSUE_WORK_MD" 'pre-check does NOT fire (repo allows auto-merge' \
    "issue-work.md no longer lists 'repo allows auto-merge' as a pre-check SKIP condition (#716)"

  # The merged-direct cause must not be hard-coded to allow_auto_merge: false —
  # that false attribution is what the #715 worker echoed back verbatim.
  # shellcheck disable=SC2016
  # Single-quoted on purpose: the needle is the LITERAL markdown text, backticks
  # and all. Nothing here is meant to expand.
  assert_not_contains "$ISSUE_WORK_MD" 'direct-merged because `allow_auto_merge: false`' \
    "issue-work.md does not hard-code allow_auto_merge:false as the merged-direct cause (#716)"
  # shellcheck disable=SC2016
  assert_not_contains "$ISSUE_WORK_MD" 'direct-merged because the repo has `allow_auto_merge: false`' \
    "issue-work.md does not hard-code the shape-1 merged-direct explanation (#716)"

  # And it must name both shapes where it explains the ungated path.
  assert_contains "$ISSUE_WORK_MD" 'zero required status checks' \
    "issue-work.md names the zero-required-checks shape (#465) in its ungated-path explanation"
fi
echo

# ---------------------------------------------------------------------------
# (D) Single source of truth — both call sites point at the one script.
# ---------------------------------------------------------------------------
echo "(D) single source of truth — both call sites invoke the script"
assert_contains "$ISSUE_WORK_MD" 'detect-ungated-admin-direct-merge.sh' \
  "issue-work.md §6 invokes the detector script (#716)"
assert_contains "$AUTO_MERGE_MD" 'detect-ungated-admin-direct-merge.sh' \
  "auto-merge.md §0.5 invokes the detector script (#716)"
assert_contains "$AUTO_MERGE_MD" 'single source of truth' \
  "auto-merge.md names the script as the single source of truth for the condition (#716)"
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
