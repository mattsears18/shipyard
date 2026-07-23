#!/usr/bin/env bash
# detect-missing-workflow-scope.sh — decide whether to print the session-start
# preflight warning for a `gh` token missing the `workflow` OAuth scope
# (issue #818 — the PROACTIVE half of #812's reactive detection).
#
# Background (issue #812 / #818)
# -------------------------------
# GitHub blocks `enablePullRequestAutoMerge` for an OAuth-app token when the
# PR's diff touches `.github/workflows/*`, unless the token carries the
# `workflow` scope. `repo` alone is not enough. #812 taught the REACTIVE path
# (the worker discovers this at the first failed `gh pr merge --auto` call and
# emits the `auto-merge: unavailable — gh token lacks `workflow` scope` token
# / end-of-session banner). This script backs the PROACTIVE half: a one-time
# session-start warning, printed BEFORE the first workflow-touching PR is ever
# opened, when the session shape suggests one is likely this session.
#
# Two independent concerns, split so the DECISION LOGIC is unit-testable
# without a live gh/network call — same shape as
# detect-ungated-admin-direct-merge.sh's `--decide` mode:
#
#   --decide <has_workflow_scope:0|1> <workflow_signal:0|1>
#       Pure decision: prints "warn" or "silent". No network I/O. This is
#       what the regression test drives.
#
#   <owner/repo> [default-branch]
#       Live mode: reads `gh auth status` for the token's scope list, probes
#       two cheap signals for "this session looks likely to touch
#       .github/workflows/", and prints "warn" or "silent" to stdout:
#         (a) an open issue OR PR (GitHub's issue-search endpoint returns
#             both) whose title/body references `.github/workflows/`
#         (b) the default branch's most recent workflow run concluded
#             `failure` — a cheap proxy for "a fix-main-ci divert (which
#             routinely edits workflow files) is likely to fire this
#             session"; the canonical `main_ci.status` aggregate computed in
#             do-work/setup/04-backlog-divert.md#45 is deliberately NOT
#             re-derived here (that would be a second copy of that rule) —
#             this is a cheaper, narrower, single-call proxy good enough for
#             an advisory warning, not a dispatch decision.
#       Silent by default: has-scope short-circuits to "silent" without
#       spending either read; missing-scope-but-no-signal is also "silent".
#       Any read failure resolves toward "silent" — fail toward NOT warning.
#       A missed warning costs one avoidable auto-merge failure later in the
#       session, which #812's reactive path already surfaces; a FALSE warning
#       (or a network error surfaced as a hard failure) costs nothing but is
#       pure noise on the common case, which the issue's acceptance criteria
#       explicitly forbid.
#
# Usage: commands/do-work/setup/01-repo-recovery.md's "1.35" preflight step.
set -u

decide() {
  local has_scope="$1" signal="$2"
  if [[ "$has_scope" == "1" ]]; then
    echo "silent"
    return
  fi
  if [[ "$signal" == "1" ]]; then
    echo "warn"
  else
    echo "silent"
  fi
}

if [[ "${1:-}" == "--decide" ]]; then
  decide "${2:-0}" "${3:-0}"
  exit 0
fi

REPO="${1:-}"
DEFAULT_BRANCH="${2:-}"

if [[ -z "$REPO" ]]; then
  # No repo to probe — fail toward silent rather than erroring the caller.
  echo "silent"
  exit 0
fi

# --- Does the token already carry `workflow`? ---
GH_AUTH_STATUS="$(gh auth status 2>&1 || true)"
HAS_SCOPE=0
if printf '%s' "$GH_AUTH_STATUS" | grep -q "Token scopes:.*'workflow'"; then
  HAS_SCOPE=1
fi

if [[ "$HAS_SCOPE" == "1" ]]; then
  echo "silent"
  exit 0
fi

# --- Does the session shape suggest workflow-touching work is likely? ---
SIGNAL=0

ISSUE_HIT=$(gh api search/issues \
  -f q="repo:${REPO} is:open \".github/workflows\" in:body,title" \
  --jq '.total_count' 2>/dev/null || echo 0)
[[ "$ISSUE_HIT" =~ ^[0-9]+$ ]] || ISSUE_HIT=0
if [[ "$ISSUE_HIT" -gt 0 ]]; then
  SIGNAL=1
fi

if [[ "$SIGNAL" == "0" && -n "$DEFAULT_BRANCH" ]]; then
  LATEST_CONCLUSION=$(gh run list --repo "$REPO" --branch "$DEFAULT_BRANCH" \
    --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo unknown)
  if [[ "$LATEST_CONCLUSION" == "failure" ]]; then
    SIGNAL=1
  fi
fi

decide "$HAS_SCOPE" "$SIGNAL"
