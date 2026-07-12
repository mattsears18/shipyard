#!/usr/bin/env bash
# detect-ungated-admin-direct-merge.sh — decide whether a PR against <owner/repo>
# is on the "ungated admin-direct-merge" path, where `gh pr merge --auto` does
# NOT queue behind CI but instead lands the PR *immediately*, before its own
# checks complete.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for that decision.
#
# Background (issues #438 / #465 / #598 / #602 / #645 / #716)
# ----------------------------------------------------------
# `gh pr merge --auto` is widely assumed to mean "queue this PR and merge it
# when CI goes green." That guarantee silently does not hold in two repo
# configurations, both of which cause an admin's `--auto` call to fall through
# to an *immediate direct merge*:
#
#   Shape 1 (#438): allow_auto_merge == false.
#     With repo-level auto-merge disabled there is no queue to arm, so gh
#     falls through to a direct merge.
#
#   Shape 2 (#465): the base branch has ZERO required status checks.
#     Fires REGARDLESS of allow_auto_merge. Even with allow_auto_merge: true,
#     with no *required* check gating the branch there is no pending check for
#     `--auto` to wait on — so the merge fires immediately.
#
# Either shape requires the caller to hold ADMIN or MAINTAIN (otherwise the
# direct-merge fall-through isn't permitted and `--auto` queues normally).
#
# On the ungated path the PR's own CI is the ONLY gate that exists, and
# `--auto` bypasses it — so the worker must re-create the gate by hand:
# wait for the PR's checks to settle, then merge only when green (#598).
#
# Why this is a SCRIPT and not prose (issue #716)
# -----------------------------------------------
# This condition previously existed as prose in TWO places — the worker-preamble
# `auto-merge.md` fragment (correct: two-shape) and `agents/issue-worker/
# issue-work.md` step 6 (WRONG: it restated the trigger as shape 1 only, and
# explicitly listed "repo allows auto-merge" as a *skip* condition). Because
# `auto-merge.md` is an on-demand fragment and `issue-work.md` is loaded by
# every issue-work worker, whichever copy a given worker happened to read
# decided whether the gate fired. The #716 repro: in one session, the worker on
# PR #713 loaded the fragment and correctly held for its checks, while the
# worker on PR #715 followed issue-work.md's prose, concluded "auto-merge isn't
# enabled on the repo" (it is: allow_auto_merge == true), and admin-direct-merged
# while CI was still IN_PROGRESS.
#
# A condition restated in prose in two files WILL drift. A condition that is one
# executable command cannot. Both call sites now invoke this script; neither
# restates the rule.
#
# Usage — live detection (the normal path):
#   bash detect-ungated-admin-direct-merge.sh <owner/repo>
#     -> prints `ungated` or `gated` on stdout; diagnostic signals on stderr.
#     -> exit 0 on a successful decision, 1 on a usage/API error.
#
#   `ungated` => do NOT run `gh pr merge --auto`. Block on
#                `gh pr checks <M> --watch --interval 30`, then merge only if green.
#   `gated`   => `gh pr merge --auto` genuinely queues behind CI. Arm it and return.
#
# Usage — pure decision (hermetic, for tests and for callers that already hold
# the three signals):
#   bash detect-ungated-admin-direct-merge.sh --decide <VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>
#
# Fail-safe posture: any signal that cannot be read resolves toward `ungated`
# (i.e. toward *waiting for CI*). Waiting when we didn't need to costs one
# worker's time; not waiting when we needed to lands a red commit on the
# default branch with no gate at all. The asymmetry is deliberate.

set -uo pipefail

# ---------------------------------------------------------------------------
# The decision. Pure function of the three signals — no I/O, no network.
# This is the whole rule; everything else in this file just feeds it.
# ---------------------------------------------------------------------------
decide() {
  local viewer_perm="$1" allow_auto_merge="$2" required_checks="$3"

  # Normalize. A non-numeric / empty required-checks reading means "we could not
  # determine that the branch is gated" — treat as 0 (ungated-leaning), matching
  # the fail-safe posture above.
  case "$required_checks" in
    ''|*[!0-9]*) required_checks=0 ;;
  esac
  viewer_perm="$(printf '%s' "$viewer_perm" | tr '[:lower:]' '[:upper:]')"

  # The direct-merge fall-through is only available to ADMIN / MAINTAIN. Without
  # it, `--auto` queues normally no matter how the repo is configured.
  case "$viewer_perm" in
    ADMIN|MAINTAIN) ;;
    *) printf 'gated\n'; return 0 ;;
  esac

  # Shape 1 (#438): no auto-merge queue exists to arm.
  # Shape 2 (#465): no required check exists to wait on — fires regardless of
  #                 allow_auto_merge. This is the shape that #716 regressed on.
  if [ "$allow_auto_merge" = "false" ] || [ "$required_checks" -eq 0 ]; then
    printf 'ungated\n'
    return 0
  fi

  printf 'gated\n'
}

# ---------------------------------------------------------------------------
# Signal (c): required status checks on the default branch.
#
# Classic branch protection and repository RULESETS are two SEPARATE gating
# mechanisms. The classic `protection/required_status_checks/contexts` endpoint
# does NOT see rulesets, so a ruleset-gated branch reads 0 there — a false
# "ungated" that would send the worker into an unnecessary --watch block (#645).
# So when the classic probe reads 0, ALSO probe the rulesets endpoint.
#
# Check ONLY the `required_status_checks` rule, NOT `pull_request`: a
# `pull_request` rule requires the change to arrive via a PR but does NOT gate
# the *merge* on CI, so an admin `--auto` still lands immediately on a ruleset
# that has `pull_request` but no `required_status_checks` (the
# mattsears18/shipyard shape: [deletion, non_fast_forward, pull_request]).
# Including `pull_request` here would over-gate that shape and falsely SKIP the
# protective wait — reintroducing the exact bug this file exists to prevent.
# ---------------------------------------------------------------------------
read_required_checks() {
  local repo="$1" branch="$2" count ruleset_gated

  count="$(gh api "repos/${repo}/branches/${branch}/protection/required_status_checks/contexts" \
    --jq 'length' 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac

  if [ "$count" -eq 0 ]; then
    ruleset_gated="$(gh api "repos/${repo}/rules/branches/${branch}" \
      --jq '[.[].type] | contains(["required_status_checks"]) | tostring' 2>/dev/null || echo false)"
    [ "$ruleset_gated" = "true" ] && count=1
  fi

  printf '%s' "$count"
}

main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide <VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>" >&2
      exit 1
    fi
    decide "$2" "$3" "$4"
    exit 0
  fi

  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <owner/repo>" >&2
    echo "       $0 --decide <VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>" >&2
    exit 1
  fi

  local allow_auto_merge viewer_perm default_branch required_checks verdict

  # NOTE: allow_auto_merge is NOT exposed by `gh repo view --json` (there is no
  # autoMergeAllowed field). It must be read from the REST repo object.
  allow_auto_merge="$(gh api "repos/${repo}" --jq '.allow_auto_merge' 2>/dev/null)"
  viewer_perm="$(gh repo view "$repo" --json viewerPermission --jq '.viewerPermission' 2>/dev/null)"
  default_branch="$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"

  if [ -z "$viewer_perm" ] || [ -z "$default_branch" ]; then
    echo "detect-ungated-admin-direct-merge: could not read repo signals for '${repo}'" >&2
    exit 1
  fi

  required_checks="$(read_required_checks "$repo" "$default_branch")"
  verdict="$(decide "$viewer_perm" "$allow_auto_merge" "$required_checks")"

  {
    printf 'repo=%s default_branch=%s\n' "$repo" "$default_branch"
    printf 'viewer_permission=%s allow_auto_merge=%s required_checks=%s\n' \
      "$viewer_perm" "$allow_auto_merge" "$required_checks"
    if [ "$verdict" = "ungated" ]; then
      printf 'verdict=ungated -- "gh pr merge --auto" would land this PR IMMEDIATELY, before CI completes.\n'
      printf 'ACTION: do NOT arm --auto. Run "gh pr checks <M> --watch --interval 30", then merge only if green.\n'
    else
      printf 'verdict=gated -- "gh pr merge --auto" genuinely queues behind CI. Arm it normally.\n'
    fi
  } >&2

  printf '%s\n' "$verdict"
}

main "$@"
