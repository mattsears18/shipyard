#!/usr/bin/env bash
# assert-ci-green.sh — the SINGLE EXECUTABLE SOURCE OF TRUTH for the question
# "did CI actually pass for <commit|branch>?"
#
# The whole point of this script is that it can never answer "green" without
# having observed at least one run. An absence-assertion that cannot distinguish
# "nothing bad found" from "nothing looked at" is not a check.
#
# Background (issue #717)
# -----------------------
# `gh run list --commit <sha>` requires a **full 40-char SHA**. An abbreviated
# SHA (`git rev-parse --short HEAD`, a 7-char hash pasted from a log) silently
# matches ZERO runs — gh exits 0 and prints an empty list. Any verification
# shaped as
#
#     failures=$(gh run list --commit "$sha" --json conclusion \
#                  --jq '[.[] | select(.conclusion != "success")] | length')
#     [ "$failures" -eq 0 ] && echo "main is green"
#
# therefore **passes on the empty set** — reporting green while having observed
# nothing at all. It converts "I could not verify" into "verified green", which
# is the dangerous direction: every downstream `checks: green` claim in the
# return contract inherits a verdict that was never actually taken.
#
# The same failure family shows up whenever a tool's degenerate/empty output is
# read as a pass (GNU grep printing `binary file matches` instead of the matched
# lines; `grep -P` erroring out unsupported on macOS and the error being
# swallowed). The structural fix is the same everywhere: assert you observed
# something BEFORE you assert that what you observed was clean.
#
# Verdicts (exit code == verdict; the word is also printed on stdout)
# ------------------------------------------------------------------
#   0  green    >=1 run matched AND every workflow's latest completed run passed
#   1  red      >=1 workflow's latest completed run failed
#   3  pending  runs matched, but no workflow has a completed verdict yet
#   2  unknown  NOT VERIFIED — 0 runs matched, the ref could not be resolved to a
#               full SHA, or the gh call failed. **Never treat as green.**
#
# `unknown` is deliberately its own verdict rather than being folded into `red`
# or `green`: the caller usually wants to retry / widen the window / bail, not to
# act as if it has a verdict. What it must never do is proceed as if green.
#
# Usage — live (the normal path):
#   bash assert-ci-green.sh <owner/repo> --commit <ref>  [--limit N]
#   bash assert-ci-green.sh <owner/repo> --branch <name> [--limit N]
#
#   `--commit <ref>` accepts a full 40-char SHA (used as-is) or any git ref this
#   worktree can resolve (`HEAD`, a branch name, a short SHA) — the script
#   resolves it to the full SHA itself via `git rev-parse`, so the abbreviated-SHA
#   footgun cannot be reintroduced by a caller. A ref that cannot be resolved to
#   40 hex chars is `unknown`, never green.
#
# Usage — pure decision (hermetic; used by the tests and by callers that already
# hold a `gh run list --json ...` payload):
#   bash assert-ci-green.sh --classify '<json-array>'
#   printf '%s' "$json" | bash assert-ci-green.sh --classify -
#
# Fail-safe posture: any signal that cannot be read resolves toward `unknown`
# (i.e. toward "I did not verify"), never toward `green`. Claiming green without
# evidence is the one outcome this script exists to make impossible.

set -uo pipefail

readonly EXIT_GREEN=0
readonly EXIT_RED=1
readonly EXIT_UNKNOWN=2
readonly EXIT_PENDING=3

# ---------------------------------------------------------------------------
# The decision. Pure function of a `gh run list --json` payload — no I/O, no
# network. This is the whole rule; everything else in this file just feeds it.
#
# Per-workflow granularity (matching do-work/setup/04-backlog-divert.md § 4.5a):
# a single `success` proves only that ONE workflow passed. For each workflow we
# take its most recent COMPLETED, non-`cancelled` run — `cancelled` is normal
# traffic on an active branch (GitHub's concurrency-group supersession), not a
# verdict — and the branch is green only when every workflow's verdict is green.
# ---------------------------------------------------------------------------
classify() {
  local json="$1" total

  total="$(printf '%s' "$json" | jq 'if type == "array" then length else -1 end' 2>/dev/null)"
  case "$total" in
    ''|*[!0-9-]*) total=-1 ;;
  esac

  # A payload that isn't a JSON array at all means we could not read the signal.
  if [ "$total" -lt 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: could not parse the run list as a JSON array — NOT VERIFIED" >&2
    return "$EXIT_UNKNOWN"
  fi

  # --- BEGIN empty-set guard (#717) -- do not remove; see negative control in
  # --- scripts/tests/assert-ci-green.test.sh, which deletes this exact block and
  # --- asserts the script then vacuously reports green on an empty run list.
  #
  # THE load-bearing line of this script. Zero runs matched => we observed
  # nothing => `unknown`, never green. This is what makes "count the failures,
  # assert the count is 0" safe: the count is only meaningful once we know the
  # set was non-empty.
  if [ "$total" -eq 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: 0 runs matched — NOT VERIFIED (an empty result set is not a pass)" >&2
    return "$EXIT_UNKNOWN"
  fi
  # --- END empty-set guard (#717) ---

  local verdict
  verdict="$(printf '%s' "$json" | jq -r '
    # Per workflow, the most recent completed non-cancelled run is the verdict.
    def wf_name: (.workflowName // .name // "(unnamed)");
    def sort_key: (.createdAt // .startedAt // "");
    [ group_by(wf_name)[]
      | [ .[]
          | select((.status // "") == "completed")
          | select(((.conclusion // "") | ascii_downcase) != "cancelled")
        ]
        | sort_by(sort_key)
        | last
        | if . == null then "pending"
          elif ((.conclusion // "") | ascii_downcase)
               | IN("success", "skipped", "neutral") then "green"
          else "red"
          end
    ]
    | if any(.[]; . == "red") then "red"
      elif any(.[]; . == "pending") then "pending"
      else "green"
      end
  ' 2>/dev/null)"

  case "$verdict" in
    green)
      printf 'green\n'
      echo "assert-ci-green: ${total} run(s) observed; every workflow's latest completed run passed" >&2
      return "$EXIT_GREEN"
      ;;
    red)
      printf 'red\n'
      echo "assert-ci-green: ${total} run(s) observed; at least one workflow's latest completed run failed" >&2
      return "$EXIT_RED"
      ;;
    pending)
      printf 'pending\n'
      echo "assert-ci-green: ${total} run(s) observed; no completed verdict yet — NOT VERIFIED" >&2
      return "$EXIT_PENDING"
      ;;
    *)
      printf 'unknown\n'
      echo "assert-ci-green: could not classify the run list — NOT VERIFIED" >&2
      return "$EXIT_UNKNOWN"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Full-SHA resolution. `gh run list --commit` matches on the FULL 40-char SHA and
# silently returns an empty list for an abbreviated one — so resolving the ref is
# the script's job, not the caller's (#717).
# ---------------------------------------------------------------------------
resolve_full_sha() {
  local ref="$1" full

  # Already a full SHA — use it as-is (it may be a commit this clone doesn't have,
  # e.g. a merge commit from a PR merged server-side and not yet fetched).
  if printf '%s' "$ref" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s' "$ref" | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  full="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)"
  if printf '%s' "$full" | grep -Eq '^[0-9a-f]{40}$'; then
    printf '%s' "$full"
    return 0
  fi

  return 1
}

usage() {
  cat >&2 <<'EOF'
usage: assert-ci-green.sh <owner/repo> --commit <ref>  [--limit N]
       assert-ci-green.sh <owner/repo> --branch <name> [--limit N]
       assert-ci-green.sh --classify <json-array|->

exit: 0 green | 1 red | 2 unknown (NOT VERIFIED) | 3 pending
EOF
}

main() {
  if [ "${1:-}" = "--classify" ]; then
    local payload="${2:-}"
    if [ -z "$payload" ]; then usage; exit "$EXIT_UNKNOWN"; fi
    if [ "$payload" = "-" ]; then payload="$(cat)"; fi
    classify "$payload"
    exit $?
  fi

  local repo="${1:-}"
  shift || true
  if [ -z "$repo" ] || [ "$#" -eq 0 ]; then usage; exit "$EXIT_UNKNOWN"; fi

  local mode="" target="" limit=60
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit) mode="commit"; target="${2:-}"; shift 2 || true ;;
      --branch) mode="branch"; target="${2:-}"; shift 2 || true ;;
      --limit)  limit="${2:-60}";              shift 2 || true ;;
      *) usage; exit "$EXIT_UNKNOWN" ;;
    esac
  done

  if [ -z "$mode" ] || [ -z "$target" ]; then usage; exit "$EXIT_UNKNOWN"; fi
  case "$limit" in ''|*[!0-9]*) limit=60 ;; esac

  local json
  if [ "$mode" = "commit" ]; then
    local sha
    if ! sha="$(resolve_full_sha "$target")"; then
      printf 'unknown\n'
      echo "assert-ci-green: could not resolve '${target}' to a full 40-char SHA — NOT VERIFIED." >&2
      echo "  \`gh run list --commit\` matches ONLY on the full SHA; an abbreviated SHA silently" >&2
      echo "  matches zero runs, which a naive 'failures == 0' check would read as green (#717)." >&2
      echo "  Pass a full SHA (\`git rev-parse HEAD\`, never \`--short\`) or a resolvable git ref." >&2
      exit "$EXIT_UNKNOWN"
    fi
    echo "assert-ci-green: repo=${repo} commit=${sha} (full SHA)" >&2
    json="$(gh run list --repo "$repo" --commit "$sha" --limit "$limit" \
      --json workflowName,name,status,conclusion,createdAt,databaseId 2>/dev/null)"
  else
    echo "assert-ci-green: repo=${repo} branch=${target}" >&2
    # Do NOT pass --status completed: it hides in-progress workflows, which would
    # let a still-running required workflow read as "nothing red here" (4.5a).
    json="$(gh run list --repo "$repo" --branch "$target" --limit "$limit" \
      --json workflowName,name,status,conclusion,createdAt,databaseId 2>/dev/null)"
  fi

  if [ -z "$json" ]; then
    printf 'unknown\n'
    echo "assert-ci-green: the gh run list call returned nothing — NOT VERIFIED" >&2
    exit "$EXIT_UNKNOWN"
  fi

  classify "$json"
  exit $?
}

main "$@"
