#!/usr/bin/env bash
# detect-mutually-blocking-prs.sh — decide whether two open PRs against
# <owner/repo> are MUTUALLY BLOCKING each other's required CI checks: each
# PR passes a required check the other is currently failing, and each PR's
# set of failing required checks is FULLY covered by the other's passing
# checks (issue #1140's "the failures are the complete blocking set").
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for that decision.
#
# Background (issue #1140)
# -------------------------
# Two open PRs each fixed the exact required check the OTHER was failing:
#
#   PR #3612 (scopes the npm-audit gate)  — passes Lint&Typecheck, fails E2E
#   PR #3614 (fixes the E2E flake)        — passes E2E, fails Lint&Typecheck
#
# Neither could go green alone, so neither could merge — stalling the whole
# merge train (11 further PRs stacked behind them). The drain had no concept
# of this state: it saw two ordinary red PRs and treated them as such, which
# is a category error — no amount of re-running or rebasing resolves it, and
# nothing recorded the real explanation ("these two unblock each other").
#
# This detector closes the DETECTION half of that gap. It never mutates a PR,
# never gates auto-merge, and never combines branches — it only decides
# whether the mutually-blocking RELATIONSHIP holds between two PRs, so a
# caller (drain.md) can post a loud, human-legible diagnosis instead of
# silently applying blocked:ci with the real cause lost. Automated combining
# (cherry-picking the smaller PR onto the larger) is a deliberately separate,
# higher-risk capability — tracked as a follow-up, not implemented here.
#
# Scope: PAIRS only (2 PRs). The issue's own algorithm says "a pair (or
# cycle)" — a 3+-PR cycle is a documented gap for a future iteration; the
# reproduced failure (and the common real-world shape: two repo-wide
# breakages landing within hours of each other) is a pair.
#
# Usage — live detection (the normal path):
#   bash detect-mutually-blocking-prs.sh <owner/repo> <pr1> <pr2> [<pr3> ...]
#     -> for every PAIR among the given PR numbers whose latest-run-per-name
#        REQUIRED checks mutually resolve each other, prints one line on
#        stdout: "<pr_a>,<pr_b>,<files_disjoint>" where <files_disjoint> is
#        1 (diffs share no changed file), 0 (diffs overlap), or "unknown"
#        (a diff could not be read).
#     -> prints nothing on stdout when no pair is mutually blocking.
#     -> diagnostics on stderr.
#     -> exit 0 on a successful (possibly empty) scan; 2 when a required
#        signal could not be read for one or more PRs and NO pair was found
#        (treat as "no pairs this poll" — the safe/inert default, see below);
#        1 on a usage error.
#
# Usage — pure decision (hermetic, for tests and for callers that already
# hold the four signals):
#   bash detect-mutually-blocking-prs.sh --decide-pair \
#     <a_failing_required_csv> <a_passing_required_csv> \
#     <b_failing_required_csv> <b_passing_required_csv>
#     -> prints "mutually-blocking" or "independent" on stdout.
#   A CSV is a comma-separated list of required-check NAMES (no spaces), or
#   an empty string when the PR has no checks in that bucket.
#
# Fail-safe posture — the OPPOSITE direction from this directory's
# auto-merge-gating detectors, and deliberately so. This script only ever
# ADDS a diagnosis (a PR comment + an end-of-session summary line) — it never
# gates auto-merge, never blocks a dispatch, never mutates a branch. So a
# signal that can't be read resolves toward "independent" (no pair reported)
# rather than toward a blocking verdict: missing a diagnosis once costs
# nothing but one missed comment on a later-resolving poll, while a false
# positive would spam an incorrect diagnosis onto two unrelated red PRs.

set -uo pipefail

# ---------------------------------------------------------------------------
# The pairwise decision. Pure function of four CSV sets — no I/O, no network.
# ---------------------------------------------------------------------------

csv_has() {
  # csv_has <needle> <haystack_csv> -- is <needle> a member of <haystack_csv>?
  case ",$2," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

csv_subset() {
  # csv_subset <needle_csv> <haystack_csv> -- is every element of
  # <needle_csv> present in <haystack_csv>? decide_pair() below never calls
  # this with an empty needle (an empty failing-set short-circuits first).
  local needle="$1" haystack="$2" IFS=','
  local item
  for item in $needle; do
    [ -z "$item" ] && continue
    csv_has "$item" "$haystack" || return 1
  done
  return 0
}

decide_pair() {
  local a_failing="$1" a_passing="$2" b_failing="$3" b_passing="$4"

  # A PR with no failing required checks isn't part of a blocking pair by
  # definition — it isn't blocked on anything.
  if [ -z "$a_failing" ] || [ -z "$b_failing" ]; then
    printf 'independent\n'
    return 0
  fi

  # Mutually blocking iff EVERY required check A is failing is one B
  # currently passes, AND vice versa — the "complete blocking set" the issue
  # names: combining the two fully resolves both, not just partially.
  if csv_subset "$a_failing" "$b_passing" && csv_subset "$b_failing" "$a_passing"; then
    printf 'mutually-blocking\n'
  else
    printf 'independent\n'
  fi
}

# ---------------------------------------------------------------------------
# Signal extraction (live mode only).
# ---------------------------------------------------------------------------

# Required status-check context NAMES for <repo>'s default branch. Classic
# branch protection first; ruleset fallback second — mirrors
# detect-ungated-admin-direct-merge.sh's read_required_checks, extended to
# return NAMES (newline-separated) rather than a bare count, since this
# decision needs to match check names across two PRs' rollups.
read_required_check_names() {
  local repo="$1" branch="$2" names
  names="$(gh api "repos/${repo}/branches/${branch}/protection/required_status_checks/contexts" \
    --jq '.[]' 2>/dev/null)"
  if [ -z "$names" ]; then
    names="$(gh api "repos/${repo}/rules/branches/${branch}" \
      --jq '[.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' \
      2>/dev/null)"
  fi
  printf '%s' "$names"
}

# Latest-run-per-check-name rollup for one PR (issue #333's de-dup — a
# superseded FAILURE entry must not count once a later SUCCESS landed for
# the same check name), restricted to the required check names, split into
# failing/passing CSV sets. Prints "<failing_csv>|<passing_csv>" on stdout;
# prints nothing and returns 1 if the rollup couldn't be read at all.
pr_required_check_sets() {
  local repo="$1" pr="$2" required_json="$3" rollup
  rollup="$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup 2>/dev/null)"
  if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    return 1
  fi
  printf '%s' "$rollup" | jq -r --argjson names "$required_json" '
    ([.statusCheckRollup
      | group_by(.name)
      | map(sort_by(.completedAt // .startedAt // "") | last)
      | .[]
      | select(.name as $n | $names | index($n) != null)]) as $latest
    | { failing: ([$latest[] | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED")) | .name] | join(",")),
        passing: ([$latest[] | select((.conclusion // .status // "") | test("SUCCESS|SKIPPED|NEUTRAL")) | .name] | join(",")) }
    | "\(.failing)|\(.passing)"'
}

# Whether two PRs' changed-file sets are disjoint. Informational only — this
# detector never combines branches, but the caller's diagnosis comment is
# more actionable when it says whether a manual combine would even apply
# cleanly. Prints "1" (disjoint), "0" (overlap), or "unknown" (a diff
# couldn't be read).
files_disjoint() {
  local repo="$1" pr_a="$2" pr_b="$3" files_a files_b overlap
  files_a="$(gh pr diff "$pr_a" --repo "$repo" --name-only 2>/dev/null)"
  files_b="$(gh pr diff "$pr_b" --repo "$repo" --name-only 2>/dev/null)"
  if [ -z "$files_a" ] || [ -z "$files_b" ]; then
    printf 'unknown\n'
    return
  fi
  overlap="$(comm -12 <(printf '%s\n' "$files_a" | sort) <(printf '%s\n' "$files_b" | sort) 2>/dev/null)"
  if [ -z "$overlap" ]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

main() {
  if [ "${1:-}" = "--decide-pair" ]; then
    if [ "$#" -ne 5 ]; then
      echo "usage: $0 --decide-pair <a_failing_csv> <a_passing_csv> <b_failing_csv> <b_passing_csv>" >&2
      exit 1
    fi
    decide_pair "$2" "$3" "$4" "$5"
    exit 0
  fi

  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <owner/repo> <pr1> <pr2> [<pr3> ...]" >&2
    echo "       $0 --decide-pair <a_failing_csv> <a_passing_csv> <b_failing_csv> <b_passing_csv>" >&2
    exit 1
  fi
  shift
  if [ "$#" -lt 2 ]; then
    echo "usage: $0 <owner/repo> <pr1> <pr2> [<pr3> ...] -- need at least two PR numbers to look for a pair" >&2
    exit 1
  fi
  local -a prs=("$@")

  local default_branch required_names required_json
  default_branch="$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
  if [ -z "$default_branch" ]; then
    echo "detect-mutually-blocking-prs: could not read default branch for '${repo}' -- no pairs reported" >&2
    exit 2
  fi

  required_names="$(read_required_check_names "$repo" "$default_branch")"
  if [ -z "$required_names" ]; then
    echo "detect-mutually-blocking-prs: repo '${repo}' has no required status checks on ${default_branch} -- nothing can mutually-block; no pairs reported" >&2
    exit 0
  fi
  required_json="$(printf '%s\n' "$required_names" | jq -R -s 'split("\n") | map(select(length>0))')"

  # Parallel indexed arrays keyed by position in $prs (portable to bash 3.2 —
  # no associative arrays; this repo's scripts must run on macOS's stock
  # /bin/bash as well as CI's newer bash).
  local -a failing_arr=() passing_arr=() read_ok_arr=()
  local pr sets idx=0 read_failed=0
  for pr in "${prs[@]}"; do
    sets="$(pr_required_check_sets "$repo" "$pr" "$required_json")"
    if [ -z "$sets" ]; then
      echo "detect-mutually-blocking-prs: could not read statusCheckRollup for PR #${pr} -- skipping it this scan" >&2
      read_failed=1
      failing_arr[idx]=""
      passing_arr[idx]=""
      read_ok_arr[idx]=0
    else
      failing_arr[idx]="${sets%%|*}"
      passing_arr[idx]="${sets#*|}"
      read_ok_arr[idx]=1
    fi
    idx=$((idx + 1))
  done

  local n="${#prs[@]}" i j a b verdict disjoint found_any=0
  for ((i = 0; i < n; i++)); do
    [ "${read_ok_arr[$i]}" = "1" ] || continue
    for ((j = i + 1; j < n; j++)); do
      [ "${read_ok_arr[$j]}" = "1" ] || continue
      a="${prs[$i]}"
      b="${prs[$j]}"
      verdict="$(decide_pair "${failing_arr[$i]}" "${passing_arr[$i]}" "${failing_arr[$j]}" "${passing_arr[$j]}")"
      if [ "$verdict" = "mutually-blocking" ]; then
        found_any=1
        disjoint="$(files_disjoint "$repo" "$a" "$b")"
        {
          printf 'PR #%s <-> PR #%s mutually block each other'"'"'s required checks\n' "$a" "$b"
          printf '  #%s: failing=[%s] passing=[%s]\n' "$a" "${failing_arr[$i]}" "${passing_arr[$i]}"
          printf '  #%s: failing=[%s] passing=[%s]\n' "$b" "${failing_arr[$j]}" "${passing_arr[$j]}"
          printf '  files_disjoint=%s\n' "$disjoint"
        } >&2
        printf '%s,%s,%s\n' "$a" "$b" "$disjoint"
      fi
    done
  done

  if [ "$found_any" = "0" ]; then
    echo "detect-mutually-blocking-prs: no mutually-blocking pairs found among {${prs[*]}}" >&2
    if [ "$read_failed" = "1" ]; then
      exit 2
    fi
  fi

  exit 0
}

main "$@"
