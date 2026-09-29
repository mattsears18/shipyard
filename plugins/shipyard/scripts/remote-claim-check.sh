#!/usr/bin/env bash
# remote-claim-check.sh — tool-agnostic "is someone already working issue #N?"
# check against the REMOTE, run by /shipyard:do-work immediately before each
# issue-work dispatch (issue #1606).
#
# Background (issue #1606)
# ------------------------
# do-work's peer-session detector (detect-peer-sessions.sh, #1204) only reads
# $SHIPYARD_HOME/sessions/*.json. A Claude Code session working the same repo
# WITHOUT a shipyard session file — e.g. a plain orchestrator session that
# dispatches its own `shipyard:issue-worker` agents — is structurally
# invisible to it, so do-work reports `peers=0` and dispatches a duplicate
# worker against an issue the other session is already working. Repro
# (lightwork, 2026-09-26): session A's worker opened PR #5353 for #5351;
# /do-work session B reported peers=0 at setup AND after #5353 merged,
# dispatched its own worker, and produced a near-identical competing PR
# (#5356, including a second competing data-migration script).
#
# The load-bearing fix is to look at the one place every session — shipyard
# or not — leaves a trace: the remote. This script checks three signals, in
# precedence order, and reports the first that fires:
#
#   open-pr-closing  an open PR whose closingIssuesReferences include #N
#                    (the #1389 covered-by-open-PR signal, subsumed here so
#                    the per-dispatch guard is one call, not two)
#   open-pr-branch   an open PR whose head branch names the issue as a path
#                    segment `issue-<N>` / `slice-<N>` (e.g.
#                    do-work/issue-<N>, fix/issue-<N>-foo) — catches a PR that
#                    carries no closing keyword (a native auto-opened draft,
#                    #785, or a split-dispatch slice PR, #1562)
#   remote-branch    a pushed `do-work/issue-<N>` or `do-work/slice-<N>`
#                    branch with NO PR yet, whose tip commit is within the
#                    freshness window — a peer worker that has pushed but not
#                    yet reached `gh pr create`. A branch older than the
#                    window is treated as abandoned (not a claim), so a dead
#                    branch can never permanently starve an issue.
#
# Honest limitation: a peer worker that has neither pushed nor opened a PR
# leaves no remote trace at all, so no remote check can see it. The window
# this closes is "peer has pushed/opened a PR since our backlog fetch" —
# the repro's window — not "peer exists anywhere". Consulting Claude Code's
# own live-session listing for the pre-push window is out of scope for a
# script (it isn't reachable from a Bash subprocess).
#
# This is advisory and read-only: it never writes to GitHub, never touches a
# branch or worktree. Blast radius of a bug is a wrongly-parked or
# wrongly-dispatched candidate, never data loss.
#
# Subcommands
# -----------
#
#   check --repo <owner/repo> --issue <N> [--window-min <M>]
#     Performs the live `gh` reads (1 `gh pr list`, 2 `gh api` ref lookups,
#     plus 1 commit lookup per branch found) and classifies the result.
#
#   classify --issue <N> [--window-min <M>] [--now <epoch-seconds>]
#     Pure classification — no network. Reads a JSON object on stdin:
#       { "prs":      [ { "number": 12, "headRefName": "...", "closing": [N, ...] } ],
#         "branches": [ { "name": "do-work/issue-N", "committed_at": "<iso-8601>" } ] }
#     Exists so the decision logic is unit-testable without `gh`.
#
#   --window-min defaults to 120 (override via SHIPYARD_REMOTE_CLAIM_WINDOW_MIN).
#
# Output — exactly one line on stdout:
#   remote_claimed=false
#   remote_claimed=true signal=<open-pr-closing|open-pr-branch|remote-branch> ref=<PR #M|branch name>
#   remote_claimed=unknown reason=<why>     (check only: a `gh` read failed)
#
# `unknown` FAILS OPEN — the caller proceeds with the dispatch. Unlike
# concurrent-session-guard.sh's unparseable-lock case (#1206, fail closed),
# a GitHub API blip here would otherwise park EVERY candidate for the whole
# outage, and issue-work.md step 0's own duplicate-PR check remains the
# backstop inside the dispatched worker.
#
# Exit codes: 0 always on a completed check (including unknown); 64 bad usage.

set -u

WINDOW_MIN_DEFAULT="${SHIPYARD_REMOTE_CLAIM_WINDOW_MIN:-120}"

usage() {
  cat <<'EOF'
Usage:
  remote-claim-check.sh check --repo <owner/repo> --issue <N> [--window-min <M>]
  remote-claim-check.sh classify --issue <N> [--window-min <M>] [--now <epoch>] < payload.json
EOF
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

do_classify() {
  local issue="$1" window="$2" now="$3"
  jq -r --argjson n "$issue" --argjson window "$window" --argjson now "$now" '
    def seg: "(^|/)(issue|slice)-" + ($n|tostring) + "($|[^0-9])";
    (.prs // []) as $prs
    | (.branches // []) as $branches
    | ([ $prs[] | select((.closing // []) | index($n)) ] | first) as $closing
    | ([ $prs[] | select((.headRefName // "") | test(seg)) ] | first) as $branchpr
    | ([ $branches[]
         | select(.committed_at != null)
         | select((.committed_at | fromdateiso8601) >= ($now - $window * 60))
       ] | first) as $fresh
    | if $closing != null then
        "remote_claimed=true signal=open-pr-closing ref=PR #\($closing.number)"
      elif $branchpr != null then
        "remote_claimed=true signal=open-pr-branch ref=PR #\($branchpr.number)"
      elif $fresh != null then
        "remote_claimed=true signal=remote-branch ref=\($fresh.name)"
      else
        "remote_claimed=false"
      end
  '
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  check|classify) ;;
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 64 ;;
  *) echo "remote-claim-check.sh: unknown subcommand: $sub" >&2; usage >&2; exit 64 ;;
esac

repo=""
issue=""
window="$WINDOW_MIN_DEFAULT"
now=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --issue) issue="${2:-}"; shift 2 ;;
    --window-min) window="${2:-}"; shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "remote-claim-check.sh: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if ! is_uint "$issue"; then
  echo "remote-claim-check.sh: --issue <N> is required (positive integer)" >&2
  usage >&2
  exit 64
fi
if ! is_uint "$window"; then
  echo "remote-claim-check.sh: --window-min must be a non-negative integer, got: $window" >&2
  exit 64
fi
if [ -n "$now" ] && ! is_uint "$now"; then
  echo "remote-claim-check.sh: --now must be epoch seconds, got: $now" >&2
  exit 64
fi
[ -z "$now" ] && now="$(date +%s)"

case "$sub" in
  classify)
    payload="$(cat)"
    if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "remote-claim-check.sh classify: stdin must be a JSON object" >&2
      exit 64
    fi
    printf '%s' "$payload" | do_classify "$issue" "$window" "$now"
    ;;
  check)
    if [ -z "$repo" ]; then
      echo "remote-claim-check.sh check: --repo <owner/repo> is required" >&2
      usage >&2
      exit 64
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "remote_claimed=unknown reason=gh-not-installed"
      exit 0
    fi

    if ! prs="$(gh pr list --repo "$repo" --state open --limit 200 \
        --json number,headRefName,closingIssuesReferences \
        --jq '[.[] | {number, headRefName, closing: [.closingIssuesReferences[]?.number]}]' 2>/dev/null)"; then
      echo "remote_claimed=unknown reason=gh-pr-list-failed"
      exit 0
    fi
    [ -z "$prs" ] && prs="[]"

    branches="[]"
    for name in "do-work/issue-$issue" "do-work/slice-$issue"; do
      # matching-refs is a PREFIX match (do-work/issue-12 also matches
      # do-work/issue-123), so filter to the exact ref. It returns [] — not
      # a 404 — when nothing matches, so a non-zero exit is a real failure.
      if ! sha="$(gh api "repos/$repo/git/matching-refs/heads/$name" \
          --jq "[.[] | select(.ref == \"refs/heads/$name\") | .object.sha] | first // empty" 2>/dev/null)"; then
        echo "remote_claimed=unknown reason=gh-ref-lookup-failed"
        exit 0
      fi
      [ -z "$sha" ] && continue
      if ! committed_at="$(gh api "repos/$repo/commits/$sha" --jq '.commit.committer.date' 2>/dev/null)"; then
        echo "remote_claimed=unknown reason=gh-commit-lookup-failed"
        exit 0
      fi
      branches="$(printf '%s' "$branches" | jq -c --arg name "$name" --arg at "$committed_at" \
        '. + [{name: $name, committed_at: (if $at == "" then null else $at end)}]')"
    done

    jq -n -c --argjson prs "$prs" --argjson branches "$branches" '{prs: $prs, branches: $branches}' \
      | do_classify "$issue" "$window" "$now"
    ;;
esac
