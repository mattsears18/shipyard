#!/usr/bin/env bash
# gh-batch.sh — batched read helpers for issue/PR state via `gh api graphql`.
#
# Background (issue #159 / phase 2 of #152): the orchestrator's drain phase
# and several setup paths currently fire N sequential `gh pr view <M>` or
# `gh issue view <N>` calls — one per artifact:
#
#   gh pr view 142 --json mergeable,statusCheckRollup,mergeStateStatus
#   gh pr view 143 --json mergeable,statusCheckRollup,mergeStateStatus
#   gh pr view 144 --json mergeable,statusCheckRollup,mergeStateStatus
#   # ... N total
#
# Each per-call costs one network round-trip, one separate tool-result
# block in the agent's context, and a repeat of the same JSON query
# framing tokens. With GraphQL aliasing, a single `gh api graphql` call
# returns all N records in one response:
#
#   query {
#     pr_142: repository(owner: "...", name: "...") {
#       pullRequest(number: 142) { number, mergeable, ... }
#     }
#     pr_143: repository(owner: "...", name: "...") { ... }
#   }
#
# One round-trip, one tool result. This wrapper hides the query templating
# behind two ergonomic subcommands.
#
# Subcommands:
#
#   pr-status   — Batch-fetch status for a list of PR numbers. Required:
#                   --repo <owner/name>
#                   --numbers <space- or comma-separated list>
#                 Emits a single JSON object mapping PR number (as a
#                 string) → {number, mergeable, mergeStateStatus,
#                 statusCheckRollupState, headRefName, headRefOid, state,
#                 closingIssueNumbers}.
#                 `closingIssueNumbers` is the flat list of issue numbers
#                 the PR's body closes via a [closing keyword] (Closes /
#                 Fixes / Resolves #N) — the canonical signal GitHub
#                 uses to auto-close issues on merge. Empty array when
#                 the PR carries no closing keywords. This is the
#                 authoritative replacement for substring-searching PR
#                 bodies, which false-positives on release-PR CHANGELOG
#                 manifests (see issue #301).
#                 PRs that don't exist (or are inaccessible) are
#                 silently dropped from the output — the caller decides
#                 how to handle missing entries.
#                 [closing keyword]: https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue
#
#   issue-state — Batch-fetch state + labels for a list of issue numbers.
#                 Required flags are the same as pr-status. Emits a
#                 single JSON object mapping issue number (as a string)
#                 → {number, state, labels: [string, ...]}.
#                 Same drop-on-missing behavior as pr-status — useful for
#                 `blocker_state` lookups where a referenced #N might be
#                 either an issue or a PR; the caller can fall back to
#                 pr-status on misses.
#
# Caching: opt-in by wrapping the call in `gh-cached.sh run`. The wrapper
# itself does not cache — `gh-cached.sh` keys on the full argv and the
# argv differs per (repo, numbers) tuple, so the caching layer composes
# cleanly without any new contract here. Suggested TTL band: 10s for
# pr-status (matches per-PR statusCheckRollup churn — see do-work setup.md
# §0.9), 30s for issue-state (state changes much slower than CI).
#
# Limits:
#
#   - GitHub GraphQL caps a single query at ~50,000 "node cost" units, but
#     practically the bigger limit is the per-query alias count. We chunk
#     internally at 50 aliases per request — anything larger fires as
#     multiple requests and the wrapper merges the JSON before emitting.
#     Most call-sites hit fewer than 10 numbers at a time; the chunk
#     boundary exists for the rare drain-phase case where 20+ PRs are
#     in flight simultaneously.
#
#   - `mergeable` is computed on-demand by GitHub and may return
#     `UNKNOWN`. Callers should treat UNKNOWN as "not yet computed" and
#     refresh on the next poll if the value matters. mergeStateStatus
#     gives the same signal in a more stable form (DIRTY / CLEAN /
#     BLOCKED / BEHIND / UNSTABLE / etc.) — prefer that field where
#     possible.
#
# Environment variables:
#
#   SHIPYARD_GH_BATCH_CHUNK_SIZE — override the per-query alias chunk
#                   size (default: 50). Lower values produce more,
#                   smaller queries; higher values may hit GraphQL's
#                   node-cost limit on dense projections. Tests use
#                   this to exercise multi-chunk behavior without
#                   needing 50+ fake PRs.
#
# Exit codes:
#
#   0   — success (one JSON object emitted to stdout)
#   2   — `gh api graphql` call failed; stderr surfaces the gh error.
#         Partial output (if any chunks succeeded before the failure)
#         is NOT emitted — failure of any chunk fails the whole batch.
#   3   — required dependency missing (gh, jq)
#   64  — usage error (missing flag, malformed --numbers list, etc.)

set -u

# --------------------------------------------------------------------------
# Dependency checks. `gh` for the GraphQL call, `jq` for the response
# parsing + chunk merge. Both are already hard dependencies of shipyard.
# --------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! have_cmd gh; then
  echo "gh-batch.sh: gh CLI is required but not installed" >&2
  exit 3
fi
if ! have_cmd jq; then
  echo "gh-batch.sh: jq is required but not installed" >&2
  exit 3
fi

usage() {
  cat <<'EOF' >&2
Usage:
  gh-batch.sh pr-status   --repo <owner/name> --numbers "<n> <n> ..."
  gh-batch.sh issue-state --repo <owner/name> --numbers "<n> <n> ..."

The --numbers list accepts space- or comma-separated integers.

Environment:
  SHIPYARD_GH_BATCH_CHUNK_SIZE  alias chunk size per GraphQL query
                                (default: 50; lower = more queries,
                                higher = larger queries — beware
                                GraphQL node-cost limits).

Exit codes:
  0    success — one JSON object on stdout
  2    `gh api graphql` failed (any chunk)
  3    missing dependency (gh, jq)
  64   usage error
EOF
}

# Parse the --numbers list. Accepts space- or comma-separated integers.
# Emits one number per line on stdout for easy iteration in callers.
# Rejects any non-numeric token with exit 64 so we never construct a
# malformed query (and never inject anything user-controlled into the
# query body — the only inputs we interpolate are the validated integers
# and the owner/name strings, validated below).
parse_numbers() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  local tok
  # Replace commas with spaces, then split on whitespace.
  raw="${raw//,/ }"
  for tok in $raw; do
    [[ -z "$tok" ]] && continue
    if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
      echo "gh-batch.sh: --numbers must be integers (got: $tok)" >&2
      return 64
    fi
    printf '%s\n' "$tok"
  done
}

# Validate the --repo flag. GitHub repo names follow `[A-Za-z0-9_.-]+`
# for both owner and name. We're permissive but reject characters that
# would break out of the GraphQL string literal (quote, backslash, etc.) —
# defense in depth even though the only callers are our own scripts.
parse_repo() {
  local repo="$1"
  if [[ -z "$repo" ]]; then
    echo "gh-batch.sh: --repo is required" >&2
    return 64
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "gh-batch.sh: --repo must be owner/name (got: $repo)" >&2
    return 64
  fi
  printf '%s\n' "$repo"
}

# Build the per-chunk GraphQL query body for a list of numbers + a
# per-number field projection. We use `pullRequest` or `issue` resolvers
# under aliased `repository(...)` blocks so each artifact appears as its
# own top-level key in the response. The `pr_<N>` / `issue_<N>` alias
# prefix lets the caller find each record by number after the response
# parse.
#
# Args:
#   $1: kind — "pr" or "issue"
#   $2: owner
#   $3: name
#   $4..: numbers
build_query() {
  local kind="$1"; shift
  local owner="$1"; shift
  local name="$1"; shift
  local resolver projection
  case "$kind" in
    pr)
      resolver="pullRequest"
      # `closingIssuesReferences` is the canonical GitHub signal for
      # "what issues does this PR auto-close on merge" (issue #301) —
      # a structural projection of the body's `Closes #N` / `Fixes #N`
      # / `Resolves #N` keywords, scoped to the open-PR set. `first:
      # 100` is the upper bound a PR can plausibly reference; if a real
      # PR ever exceeds it we'll surface a paginated-fetch issue rather
      # than silently truncate (the `pageInfo` projection would also let
      # us detect this — left out today because no real PR is close to
      # 100 closing keywords).
      projection='number mergeable mergeStateStatus state headRefName headRefOid statusCheckRollup { state } closingIssuesReferences(first: 100) { nodes { number } }'
      ;;
    issue)
      resolver="issue"
      projection='number state labels(first: 50) { nodes { name } }'
      ;;
    *)
      echo "build_query: unknown kind $kind" >&2
      return 64
      ;;
  esac
  local n
  printf 'query {\n'
  for n in "$@"; do
    printf '  %s_%s: repository(owner: "%s", name: "%s") { %s(number: %s) { %s } }\n' \
      "$kind" "$n" "$owner" "$name" "$resolver" "$n" "$projection"
  done
  printf '}\n'
}

# Reduce a GraphQL response for a `pr-status` chunk into a `{ "<N>": {...} }`
# object on stdout. Drops null entries (PR doesn't exist or no access).
#
# Input: one JSON object on stdin matching the GraphQL response shape:
#   { "data": { "pr_142": { "pullRequest": { ... } }, "pr_143": {...} } }
reduce_pr_chunk() {
  jq '
    .data
    | to_entries
    | map(
        select(.value != null and .value.pullRequest != null)
        | {
            (.value.pullRequest.number | tostring): {
              number: .value.pullRequest.number,
              state: .value.pullRequest.state,
              mergeable: .value.pullRequest.mergeable,
              mergeStateStatus: .value.pullRequest.mergeStateStatus,
              headRefName: .value.pullRequest.headRefName,
              headRefOid: .value.pullRequest.headRefOid,
              statusCheckRollupState: (.value.pullRequest.statusCheckRollup.state // null),
              closingIssueNumbers: (.value.pullRequest.closingIssuesReferences.nodes // [] | map(.number))
            }
          }
      )
    | add // {}
  '
}

# Reduce a GraphQL response for an `issue-state` chunk. Same shape as
# pr-status, different projection (state + flattened label-name list).
reduce_issue_chunk() {
  jq '
    .data
    | to_entries
    | map(
        select(.value != null and .value.issue != null)
        | {
            (.value.issue.number | tostring): {
              number: .value.issue.number,
              state: .value.issue.state,
              labels: (.value.issue.labels.nodes // [] | map(.name))
            }
          }
      )
    | add // {}
  '
}

# Resolve the chunk size (env override → default 50).
chunk_size() {
  local v="${SHIPYARD_GH_BATCH_CHUNK_SIZE:-50}"
  if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    # Out-of-range / non-numeric → silently fall back to default.
    v=50
  fi
  printf '%s\n' "$v"
}

# Run the GraphQL query for a single chunk of numbers, then pipe through
# the appropriate reducer. Stdout: one chunk-shaped `{<n>:{...}, ...}`
# object. Returns the gh exit code on failure.
run_chunk() {
  local kind="$1"; shift
  local owner="$1"; shift
  local name="$1"; shift
  # Remaining args are the chunk's numbers.
  local query
  query=$(build_query "$kind" "$owner" "$name" "$@")
  # Use `-f query=...` (form encoding) — gh handles the escaping into
  # the multipart body. The query string itself only contains
  # whitespace + identifiers + integers + the validated owner/name
  # strings, so there's no untrusted interpolation surface.
  local resp
  resp=$(gh api graphql -f query="$query" 2>&1)
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "gh-batch.sh: gh api graphql failed (rc=$rc): $resp" >&2
    return 2
  fi
  # If the response carries a top-level `errors` array AND no `data`,
  # treat as failure. Partial-success responses (some aliases resolved,
  # some errored — common when a PR was deleted) are kept; reducers
  # drop the null aliases.
  local has_data has_errors
  has_data=$(printf '%s' "$resp" | jq 'has("data") and (.data != null)' 2>/dev/null)
  has_errors=$(printf '%s' "$resp" | jq 'has("errors") and ((.errors | length) > 0)' 2>/dev/null)
  if [[ "$has_data" != "true" ]] && [[ "$has_errors" == "true" ]]; then
    local err_msg
    err_msg=$(printf '%s' "$resp" | jq -r '.errors[0].message // "unknown graphql error"' 2>/dev/null)
    echo "gh-batch.sh: graphql error: $err_msg" >&2
    return 2
  fi
  case "$kind" in
    pr)    printf '%s' "$resp" | reduce_pr_chunk ;;
    issue) printf '%s' "$resp" | reduce_issue_chunk ;;
  esac
}

cmd_pr_status() {
  local repo="" numbers_raw=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)    repo="${2:-}"; shift 2 ;;
      --numbers) numbers_raw="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "pr-status: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local validated_repo
  if ! validated_repo=$(parse_repo "$repo"); then
    usage
    exit 64
  fi

  local owner="${validated_repo%/*}"
  local name="${validated_repo#*/}"

  local numbers
  if ! numbers=$(parse_numbers "$numbers_raw"); then
    exit 64
  fi

  # Empty list → emit empty object and exit 0. Saves the orchestrator
  # from having to special-case "no PRs to query."
  if [[ -z "$numbers" ]]; then
    printf '{}\n'
    return 0
  fi

  local cs
  cs=$(chunk_size)

  local -a all_nums=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && all_nums+=("$n")
  done <<< "$numbers"

  if [[ ${#all_nums[@]} -eq 0 ]]; then
    printf '{}\n'
    return 0
  fi

  # Chunk + dispatch. Each chunk's reduced output is one `{<n>:{...}}`
  # JSON object; we concatenate them via `jq -s 'add'` at the end.
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT

  local i=0
  local chunk_idx=0
  while [[ $i -lt ${#all_nums[@]} ]]; do
    local end=$((i + cs))
    [[ $end -gt ${#all_nums[@]} ]] && end=${#all_nums[@]}
    local -a chunk=()
    local j=$i
    while [[ $j -lt $end ]]; do
      chunk+=("${all_nums[$j]}")
      j=$((j + 1))
    done
    if ! run_chunk "pr" "$owner" "$name" "${chunk[@]}" > "$tmpdir/chunk_$chunk_idx.json"; then
      return 2
    fi
    chunk_idx=$((chunk_idx + 1))
    i=$end
  done

  # Merge every chunk file. `jq -s 'reduce .[] as $x ({}; . * $x)'`
  # gives a proper key-merge across the array of objects.
  jq -s 'reduce .[] as $x ({}; . * $x)' "$tmpdir"/chunk_*.json
}

cmd_issue_state() {
  local repo="" numbers_raw=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)    repo="${2:-}"; shift 2 ;;
      --numbers) numbers_raw="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "issue-state: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local validated_repo
  if ! validated_repo=$(parse_repo "$repo"); then
    usage
    exit 64
  fi

  local owner="${validated_repo%/*}"
  local name="${validated_repo#*/}"

  local numbers
  if ! numbers=$(parse_numbers "$numbers_raw"); then
    exit 64
  fi

  if [[ -z "$numbers" ]]; then
    printf '{}\n'
    return 0
  fi

  local cs
  cs=$(chunk_size)

  local -a all_nums=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && all_nums+=("$n")
  done <<< "$numbers"

  if [[ ${#all_nums[@]} -eq 0 ]]; then
    printf '{}\n'
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT

  local i=0
  local chunk_idx=0
  while [[ $i -lt ${#all_nums[@]} ]]; do
    local end=$((i + cs))
    [[ $end -gt ${#all_nums[@]} ]] && end=${#all_nums[@]}
    local -a chunk=()
    local j=$i
    while [[ $j -lt $end ]]; do
      chunk+=("${all_nums[$j]}")
      j=$((j + 1))
    done
    if ! run_chunk "issue" "$owner" "$name" "${chunk[@]}" > "$tmpdir/chunk_$chunk_idx.json"; then
      return 2
    fi
    chunk_idx=$((chunk_idx + 1))
    i=$end
  done

  jq -s 'reduce .[] as $x ({}; . * $x)' "$tmpdir"/chunk_*.json
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

subcmd="$1"
shift

case "$subcmd" in
  pr-status)   cmd_pr_status "$@" ;;
  issue-state) cmd_issue_state "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "gh-batch.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
