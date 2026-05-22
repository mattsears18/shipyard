#!/usr/bin/env bash
# session-state.sh — atomic JSON read/write helpers for the /shipyard:do-work
# orchestrator's session-state file.
#
# Background (see issue #103): the orchestrator's eight state structures
# (in_flight, ready_issues, failed_prs, raw_backlog, divert_queue,
# session_prs, deferred_issues, main_ci, plus soft-collision counters) used
# to live entirely in the LLM's working memory — re-narrated as prose in the
# invariant line and status line every turn. That's token-expensive and
# drift-prone. Promoting state to a small JSON file at
# `$SHIPYARD_HOME/sessions/<session-id>.json` (default
# `$HOME/.shipyard/sessions/<session-id>.json`) gives us:
#
#   1. A machine-readable view that external tools (dashboards, notifiers)
#      can subscribe to via file-change watchers.
#   2. A durable record that survives across orchestrator turns — the model
#      no longer pays the token cost of re-typing state each turn.
#   3. A foundation for a future `/do-work --resume <session-id>` flag.
#
# Atomicity is the load-bearing property. Every update writes to
# `<path>.tmp.<pid>` and atomically renames into place — a partial write
# (process killed mid-update, filesystem full, etc.) leaves the previous
# state file intact rather than corrupting the source of truth.
#
# This file is the *durable record*, not the orchestrator's working memory.
# The orchestrator still has to keep the model in its head to make
# dispatch decisions (path collisions, lockfile sections, etc.); the JSON
# file is what the model writes through each turn so the artifact exists
# outside the transcript.
#
# Subcommands:
#
#   init     — create a fresh session state file at the deterministic path.
#              `--session-id` and `--repo` are required; `--concurrency`,
#              `--soft-collision-concurrency`, and `--force` are optional.
#              Without `--force`, refuses to overwrite an existing file
#              (exit 2) — protects against accidentally clobbering an
#              active session's state.
#
#   read     — emit the current state on stdout. Whole file when called
#              without `--path`; a single jq path when called with one.
#              Exit 3 if the session file does not exist.
#
#   update   — merge one or more jq `--set` expressions into the file
#              atomically. Each `--set` is a complete jq assignment, e.g.
#              `.session_prs += [96]` or `.main_ci.status = "green"`.
#              Exit 3 if the session file does not exist (no file is
#              created — update is "modify existing state," not "create").
#
#   cleanup  — remove the session file at end-of-session. Idempotent
#              (re-runs after the file is gone exit 0 — the failure mode
#              we're guarding against is a half-cleanup, not a missing
#              file).
#
#   bump-tokens — atomically add token-usage counts to the session's
#              `.tokens` block. The `tokens` field tracks token spend
#              at three levels of granularity: `totals` (cumulative
#              across the session, including orchestrator overhead),
#              `per_issue.<N>` (sum across every agent that touched
#              issue N), and `per_pr.<M>` (sum across every agent that
#              touched PR M). Pass `--issue N` and/or `--pr M` to
#              attribute the delta — neither flag only bumps `totals`
#              (use for orchestrator-side overhead). `--mode` and
#              `--model` are recorded into a small `.tokens.per_invocation`
#              ring buffer for traceability (capped at the most recent
#              200 entries to keep the file small). Exit 3 if the session
#              file does not exist.
#
#   read-tokens — emit token data on stdout. `--format json` (default)
#              prints the relevant slice; `--format comment` emits a
#              ready-to-post Markdown comment body marked with the
#              `<!-- do-work-cost-tracking -->` sentinel for idempotent
#              edit-or-create on the issue/PR. Pair with `--issue N` or
#              `--pr M` to scope; without either, emits the session-wide
#              totals. Exit 3 if the session file does not exist.
#
#   set-progress — atomically set `progress_current` / `progress_total` on
#              a single in-flight slot. Used by /shipyard:status (issue
#              #167) to render batch-style progress (e.g. `4/7`) on
#              workers that process N items per dispatch. The two values
#              live on the slot record itself (not on a separate per-worker
#              status file) — the session state file is already the
#              single source of truth for in-flight worker bookkeeping.
#              `--slot <id>` is required; `--current N` / `--total N` are
#              optional (pass either, both, or neither — neither is a
#              no-op success). Pass `--current null` / `--total null` to
#              clear a previously-set value. Exit 3 if the session file
#              does not exist; exit 64 if the slot is unknown.
#
# Pricing table:
#
#   The USD estimate in `bump-tokens` and `read-tokens` uses a hardcoded
#   pricing table embedded in this script (per 1M tokens, current as of
#   2026-05-21). Update the `PRICING_JQ` block below when Anthropic
#   changes pricing. Unknown models fall back to zero — the token counts
#   are still tracked, only the dollar estimate is `0.00`.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory for shipyard's per-user state. Defaults
#                   to `$HOME/.shipyard`. Sessions live at
#                   `$SHIPYARD_HOME/sessions/<session-id>.json`. Override
#                   via env (no CLI flag) so the orchestrator and the test
#                   suite can both relocate without touching the wire.
#
# Exit codes:
#
#   0   — success
#   2   — refused to clobber an existing file (init without --force)
#   3   — session file does not exist (read or update)
#   64  — usage error (bad subcommand or missing required argument).
#         Mirrors `sysexits.h`'s EX_USAGE so callers can branch on it.
#   65+ — internal helper failure (jq missing, write permission denied,
#         etc.) — never papered over with exit 0; the orchestrator should
#         see and surface these.

set -u

# --------------------------------------------------------------------------
# Dependency check — jq is required for both read (path selection) and
# update (atomic merge). The script intentionally has no python3 fallback:
# jq is already in shipyard's dependency surface (used by every gh query in
# do-work.md), and a single tool simplifies the atomic-write contract.
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "session-state.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  session-state.sh init        --session-id <id> --repo <owner/repo>
                               [--concurrency N] [--soft-collision-concurrency N]
                               [--force]
  session-state.sh read        --session-id <id> [--path <jq-path>]
  session-state.sh update      --session-id <id> --set '<jq-expr>' [--set ...]
  session-state.sh cleanup     --session-id <id>
  session-state.sh bump-tokens --session-id <id>
                               [--issue N] [--pr N]
                               [--input N] [--output N]
                               [--cache-read N] [--cache-creation N]
                               [--mode <kind>] [--model <id>]
  session-state.sh read-tokens --session-id <id>
                               [--issue N] [--pr N]
                               [--format json|comment]
  session-state.sh set-progress --session-id <id>
                               --slot <slot-id>
                               [--current N|null] [--total N|null]

Environment:
  SHIPYARD_HOME                base dir for sessions/ (default: $HOME/.shipyard)

Exit codes:
  0   success
  2   refused to clobber (init w/o --force)
  3   session file missing (read, update, bump-tokens, read-tokens, set-progress)
  64  usage error
  65+ internal helper failure
EOF
}

# --------------------------------------------------------------------------
# Pricing table — USD per 1M tokens, current as of 2026-05-21. Update
# alongside Anthropic's pricing page. Models not listed fall back to zero
# (token counts still recorded, USD estimate emits 0.00).
# --------------------------------------------------------------------------
PRICING_JQ='{
  "claude-opus-4-7":   { "input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_creation": 18.75 },
  "claude-opus-4-6":   { "input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_creation": 18.75 },
  "claude-sonnet-4-6": { "input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_creation":  3.75 },
  "claude-sonnet-4-5": { "input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_creation":  3.75 },
  "claude-haiku-4-5":  { "input":  1.00, "output":  5.00, "cache_read": 0.10, "cache_creation":  1.25 }
}'

# Resolve the canonical session-file path. Mirrors the spec in
# commands/do-work.md: `$SHIPYARD_HOME/sessions/<session-id>.json`.
session_path() {
  local session_id="$1"
  local home="${SHIPYARD_HOME:-${HOME}/.shipyard}"
  printf '%s/sessions/%s.json\n' "$home" "$session_id"
}

# Atomic write: take JSON on stdin, write to <target>.tmp.<pid>, then
# `mv -f` into place. POSIX rename(2) is atomic on the same filesystem,
# which the tmp-in-same-dir pattern guarantees. A crash mid-write leaves
# only the .tmp file, which the next successful write replaces.
atomic_write() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  # Trap so we don't leak the tmp file on a mid-write crash.
  # shellcheck disable=SC2064
  # rationale: we want the trap to capture the current value of $tmp, not
  # the value at trap-fire time (the variable is reused for each write).
  trap "rm -f '$tmp'" EXIT
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    trap - EXIT
    echo "session-state.sh: failed to write tmp file $tmp" >&2
    return 66
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    trap - EXIT
    echo "session-state.sh: failed to rename $tmp -> $target" >&2
    return 67
  fi
  trap - EXIT
}

cmd_init() {
  local session_id=""
  local repo=""
  local concurrency=2
  local soft_concurrency=3
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --concurrency) concurrency="${2:-}"; shift 2 ;;
      --soft-collision-concurrency) soft_concurrency="${2:-}"; shift 2 ;;
      --force) force=1; shift ;;
      *) echo "init: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "init: --session-id is required" >&2
    usage
    exit 64
  fi
  if [[ -z "$repo" ]]; then
    echo "init: --repo is required" >&2
    usage
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ -e "$target" && "$force" -ne 1 ]]; then
    echo "init: $target already exists (use --force to overwrite)" >&2
    exit 2
  fi

  # Build the initial JSON via jq -n so quoting / number-vs-string typing
  # is handled correctly. Every field the spec calls out is initialised to
  # its empty value so reads of fresh sessions never trip on missing keys.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg session_id "$session_id" \
    --arg repo "$repo" \
    --argjson concurrency "$concurrency" \
    --argjson soft "$soft_concurrency" \
    --arg now "$now" \
    '{
       session_id: $session_id,
       repo: $repo,
       concurrency: $concurrency,
       soft_collision_concurrency: $soft,
       started_at: $now,
       updated_at: $now,
       in_flight: {},
       ready_issues: [],
       failed_prs: [],
       raw_backlog: [],
       divert_queue: [],
       session_prs: [],
       deferred_issues: [],
       soft_caps: {},
       main_ci: {
         status: "unknown",
         earliest_red_run_id: null,
         earliest_red_run_url: null,
         earliest_red_sha: null,
         checked_at: null
       },
       drain: {
         active: false,
         started_at: null,
         polls: 0
       },
       tokens: {
         totals: {
           input: 0,
           output: 0,
           cache_read: 0,
           cache_creation: 0,
           estimated_usd: 0
         },
         per_issue: {},
         per_pr: {},
         per_invocation: []
       }
     }' | atomic_write "$target"
}

cmd_read() {
  local session_id=""
  local path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      *) echo "read: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "read: --session-id is required" >&2
    usage
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "read: $target does not exist" >&2
    exit 3
  fi

  if [[ -z "$path" ]]; then
    cat "$target"
  else
    # `jq -r` so string values come out unquoted (matches the
    # caller-friendly shape the tests assert on). Use the user-supplied
    # path verbatim — they're the trusted side of this call (the
    # orchestrator's own scripts).
    jq -r "$path" "$target"
  fi
}

cmd_update() {
  local session_id=""
  local -a sets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --set) sets+=("${2:-}"); shift 2 ;;
      *) echo "update: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "update: --session-id is required" >&2
    usage
    exit 64
  fi
  if [[ ${#sets[@]} -eq 0 ]]; then
    echo "update: at least one --set <jq-expr> is required" >&2
    usage
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "update: $target does not exist (use init first)" >&2
    exit 3
  fi

  # Compose all --set expressions into a single jq pipeline. Each --set is
  # a complete assignment; piping them through `|` makes a single jq
  # invocation that touches the file once. The `.updated_at = <now>`
  # bookend gives every successful write a fresh timestamp.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local jq_pipeline=""
  for expr in "${sets[@]}"; do
    if [[ -z "$jq_pipeline" ]]; then
      jq_pipeline="$expr"
    else
      jq_pipeline="$jq_pipeline | $expr"
    fi
  done
  jq_pipeline="$jq_pipeline | .updated_at = \$now"

  if ! jq --arg now "$now" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "update: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables (`$input`, `$pr`, `$usd_delta`, etc.) bound via the
# `--arg` / `--argjson` flags. The single-quoted form is the correct,
# safe shape — shell expansion would corrupt the jq program. The disable
# is scoped to this function only.
cmd_bump_tokens() {
  local session_id=""
  local issue=""
  local pr=""
  local input=0
  local output=0
  local cache_read=0
  local cache_creation=0
  local mode=""
  local model=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --input) input="${2:-0}"; shift 2 ;;
      --output) output="${2:-0}"; shift 2 ;;
      --cache-read) cache_read="${2:-0}"; shift 2 ;;
      --cache-creation) cache_creation="${2:-0}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      *) echo "bump-tokens: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "bump-tokens: --session-id is required" >&2
    usage
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "bump-tokens: $target does not exist (use init first)" >&2
    exit 3
  fi

  # Normalise unset counts to 0; reject negative deltas (the orchestrator
  # never subtracts tokens, only adds them — guard against typos).
  local n
  for n in "$input" "$output" "$cache_read" "$cache_creation"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: token counts must be non-negative integers (got: $n)" >&2
      exit 64
    fi
  done

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Compose the jq pipeline. The structure mirrors the orchestrator's three
  # attribution levels: always bump `.tokens.totals`; conditionally bump the
  # per-issue / per-pr buckets when --issue / --pr is supplied; always
  # append a `per_invocation` ring-buffer entry (cap at 200) for trace.
  #
  # `cost` is computed inline using the embedded pricing table:
  #
  #   usd = (input * P.input + output * P.output
  #        + cache_read * P.cache_read + cache_creation * P.cache_creation) / 1e6
  #
  # Unknown models → zero USD (price lookup returns `null`, multiplications
  # short-circuit to 0 via the `// 0` fallback).
  local jq_args=(
    --arg now "$now"
    --argjson input "$input"
    --argjson output "$output"
    --argjson cache_read "$cache_read"
    --argjson cache_creation "$cache_creation"
    --arg mode "$mode"
    --arg model "$model"
    --arg issue "$issue"
    --arg pr "$pr"
    --argjson pricing "$(jq -c -n "$PRICING_JQ")"
  )

  local issue_branch=""
  if [[ -n "$issue" ]]; then
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: --issue must be a positive integer (got: $issue)" >&2
      exit 64
    fi
    issue_branch='
      | .tokens.per_issue[$issue] //= {input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0}
      | .tokens.per_issue[$issue].input          += $input
      | .tokens.per_issue[$issue].output         += $output
      | .tokens.per_issue[$issue].cache_read     += $cache_read
      | .tokens.per_issue[$issue].cache_creation += $cache_creation
      | .tokens.per_issue[$issue].estimated_usd  += $usd_delta
    '
  fi

  local pr_branch=""
  if [[ -n "$pr" ]]; then
    if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: --pr must be a positive integer (got: $pr)" >&2
      exit 64
    fi
    pr_branch='
      | .tokens.per_pr[$pr] //= {input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0, issue: null}
      | .tokens.per_pr[$pr].input          += $input
      | .tokens.per_pr[$pr].output         += $output
      | .tokens.per_pr[$pr].cache_read     += $cache_read
      | .tokens.per_pr[$pr].cache_creation += $cache_creation
      | .tokens.per_pr[$pr].estimated_usd  += $usd_delta
    '
    # If an --issue was provided alongside --pr, cross-link them so a future
    # PR-targeted read can resolve the corresponding issue without a GitHub
    # round-trip.
    if [[ -n "$issue" ]]; then
      pr_branch="$pr_branch
      | .tokens.per_pr[\$pr].issue = (\$issue | tonumber)
      "
    fi
  fi

  # Compose the full pipeline. `$usd_delta` is computed once at the top and
  # reused in every accumulator below.
  #
  # Pricing lookup is longest-prefix-match, not exact-match: the harness
  # reports dated model ids like `claude-haiku-4-5-20251001`, and some
  # callers pass bare aliases like `opus` / `sonnet` / `haiku`. The pricing
  # table is keyed on the canonical undated id (`claude-haiku-4-5`); a
  # longest-prefix match resolves the dated suffix, and a fallback alias
  # table resolves bare aliases. Both fall through to a zero row only when
  # the model is genuinely unknown to the table (closes #226).
  local jq_pipeline='
    {opus: "claude-opus-4-7", sonnet: "claude-sonnet-4-6", haiku: "claude-haiku-4-5"} as $aliases
    | ($aliases[$model] // $model) as $resolved
    | (
        $pricing
        | to_entries
        | map(select(.key as $k | $resolved | startswith($k)))
        | sort_by(-(.key | length))
        | (.[0].value // {input:0, output:0, cache_read:0, cache_creation:0})
      ) as $p
    | (
        ($input * ($p.input // 0)
         + $output * ($p.output // 0)
         + $cache_read * ($p.cache_read // 0)
         + $cache_creation * ($p.cache_creation // 0)
        ) / 1000000
      ) as $usd_delta
    | .tokens.totals.input          += $input
    | .tokens.totals.output         += $output
    | .tokens.totals.cache_read     += $cache_read
    | .tokens.totals.cache_creation += $cache_creation
    | .tokens.totals.estimated_usd  += $usd_delta
    '"$issue_branch""$pr_branch"'
    | .tokens.per_invocation += [{
        at: $now,
        mode: ($mode | if . == "" then null else . end),
        model: ($model | if . == "" then null else . end),
        issue: ($issue | if . == "" then null else (. | tonumber) end),
        pr: ($pr | if . == "" then null else (. | tonumber) end),
        input: $input,
        output: $output,
        cache_read: $cache_read,
        cache_creation: $cache_creation,
        estimated_usd: $usd_delta
      }]
    | .tokens.per_invocation = (.tokens.per_invocation | if length > 200 then .[-200:] else . end)
    | .updated_at = $now
  '

  if ! jq "${jq_args[@]}" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "bump-tokens: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# shellcheck disable=SC2016
# rationale: same as cmd_bump_tokens — the jq programs in this function
# use single quotes to wrap jq syntax with embedded jq variables, not
# shell variables. Single-quoting is correct.
cmd_read_tokens() {
  local session_id=""
  local issue=""
  local pr=""
  local format="json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --format) format="${2:-json}"; shift 2 ;;
      *) echo "read-tokens: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "read-tokens: --session-id is required" >&2
    usage
    exit 64
  fi

  if [[ "$format" != "json" && "$format" != "comment" ]]; then
    echo "read-tokens: --format must be 'json' or 'comment' (got: $format)" >&2
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "read-tokens: $target does not exist" >&2
    exit 3
  fi

  # Resolve the scope. --pr wins over --issue if both supplied (the comment
  # surfaces on the PR; issue scoping is only used for /shipyard:my-turn
  # cost surfacing). Without either, scope is session-wide totals.
  local scope_jq
  if [[ -n "$pr" ]]; then
    scope_jq='.tokens.per_pr[$key] // {input:0, output:0, cache_read:0, cache_creation:0, estimated_usd:0, issue:null}'
  elif [[ -n "$issue" ]]; then
    scope_jq='.tokens.per_issue[$key] // {input:0, output:0, cache_read:0, cache_creation:0, estimated_usd:0}'
  else
    scope_jq='.tokens.totals'
  fi

  local key=""
  if [[ -n "$pr" ]]; then
    key="$pr"
  elif [[ -n "$issue" ]]; then
    key="$issue"
  fi

  if [[ "$format" == "json" ]]; then
    jq --arg key "$key" "$scope_jq" "$target"
    return 0
  fi

  # format=comment: emit a Markdown body marked with the dedup sentinel.
  # Mode counts come from per_invocation entries that match the scope.
  local mode_filter
  local scope_label
  if [[ -n "$pr" ]]; then
    mode_filter='[.tokens.per_invocation[] | select(.pr == ($key | tonumber))]'
    scope_label="PR #$pr"
  elif [[ -n "$issue" ]]; then
    mode_filter='[.tokens.per_invocation[] | select(.issue == ($key | tonumber))]'
    scope_label="Issue #$issue"
  else
    mode_filter='.tokens.per_invocation'
    scope_label="session"
  fi

  local session_repo
  session_repo=$(jq -r '.repo' "$target")
  local session_started
  session_started=$(jq -r '.started_at' "$target")
  local session_id_str
  session_id_str=$(jq -r '.session_id' "$target")

  jq -r \
    --arg key "$key" \
    --arg scope_label "$scope_label" \
    --arg session_id "$session_id_str" \
    --arg started "$session_started" \
    --arg repo "$session_repo" \
    "
    ($scope_jq) as \$scope
    | ($mode_filter) as \$invocations
    | (\$invocations | map(.mode) | unique | map(select(. != null)) | join(\", \")) as \$modes
    | (\$invocations | map(.model) | unique | map(select(. != null)) | join(\", \")) as \$models
    | (\$invocations | length) as \$count
    | (\$scope.input + \$scope.output + \$scope.cache_read + \$scope.cache_creation) as \$total_tokens
    | \"<!-- do-work-cost-tracking -->\n\" +
      \"### Shipyard cost — \" + \$scope_label + \"\n\n\" +
      \"| Metric | Value |\n\" +
      \"|---|---|\n\" +
      \"| Input tokens | \" + (\$scope.input | tostring) + \" |\n\" +
      \"| Output tokens | \" + (\$scope.output | tostring) + \" |\n\" +
      \"| Cache read | \" + (\$scope.cache_read | tostring) + \" |\n\" +
      \"| Cache creation | \" + (\$scope.cache_creation | tostring) + \" |\n\" +
      \"| **Total tokens** | **\" + (\$total_tokens | tostring) + \"** |\n\" +
      \"| Estimated cost (USD) | \" + (\$scope.estimated_usd | . * 10000 | round / 10000 | tostring) + \" |\n\" +
      \"| Worker invocations | \" + (\$count | tostring) + \" |\n\" +
      (if \$modes != \"\" then \"| Modes | \" + \$modes + \" |\n\" else \"\" end) +
      (if \$models != \"\" then \"| Models | \" + \$models + \" |\n\" else \"\" end) +
      \"| Session | \`\" + \$session_id + \"\` (\" + \$started + \") |\n\" +
      \"| Repo | \" + \$repo + \" |\n\n\" +
      \"_Posted automatically by \`/shipyard:do-work\` for cost-tracking. Edit-or-create idempotency keyed on the HTML sentinel comment above._\n\"
    " "$target"
}

# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables (`$slot`, `$current`, `$total`) bound via the
# `--arg` / `--argjson` flags. The single-quoted form is the correct,
# safe shape — shell expansion would corrupt the jq program. The disable
# is scoped to this function only.
cmd_set_progress() {
  local session_id=""
  local slot=""
  local current=""
  local current_set=0
  local total=""
  local total_set=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --slot) slot="${2:-}"; shift 2 ;;
      --current) current="${2:-}"; current_set=1; shift 2 ;;
      --total) total="${2:-}"; total_set=1; shift 2 ;;
      *) echo "set-progress: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "set-progress: --session-id is required" >&2
    usage
    exit 64
  fi
  if [[ -z "$slot" ]]; then
    echo "set-progress: --slot is required" >&2
    usage
    exit 64
  fi

  # Neither flag set → no-op success. Callers can pass `set-progress
  # --session-id x --slot s1` defensively from a batch refactor without
  # tripping a usage error.
  if [[ $current_set -eq 0 && $total_set -eq 0 ]]; then
    return 0
  fi

  # Validate the values. Accept positive integers or the literal `null`
  # (which clears a previously-set value). Negative numbers and non-integers
  # are rejected so a typo doesn't silently persist as a string.
  local current_jq="null"
  if [[ $current_set -eq 1 ]]; then
    if [[ "$current" == "null" ]]; then
      current_jq="null"
    elif [[ "$current" =~ ^[0-9]+$ ]]; then
      current_jq="$current"
    else
      echo "set-progress: --current must be a non-negative integer or 'null' (got: $current)" >&2
      exit 64
    fi
  fi

  local total_jq="null"
  if [[ $total_set -eq 1 ]]; then
    if [[ "$total" == "null" ]]; then
      total_jq="null"
    elif [[ "$total" =~ ^[0-9]+$ ]]; then
      total_jq="$total"
    else
      echo "set-progress: --total must be a non-negative integer or 'null' (got: $total)" >&2
      exit 64
    fi
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "set-progress: $target does not exist (use init first)" >&2
    exit 3
  fi

  # Verify the slot exists in .in_flight. set-progress is "modify an
  # existing slot record," not "create a slot" — the slot is added by
  # step C dispatch with the worker's claimed_paths + agent_id. If the
  # caller is updating a slot that doesn't exist, that's a programming
  # error worth surfacing (likely the worker returned and the slot got
  # released before the progress write landed — race window is narrow
  # but real).
  if ! jq -e --arg slot "$slot" '.in_flight | has($slot)' "$target" >/dev/null 2>&1; then
    echo "set-progress: slot '$slot' not present in .in_flight" >&2
    exit 64
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Compose the jq pipeline. Each field is updated only when its --set was
  # provided this call — preserves a previously-set total when only current
  # advances (the common case for a progressing batch worker).
  local jq_pipeline=""
  if [[ $current_set -eq 1 ]]; then
    jq_pipeline=".in_flight[\$slot].progress_current = $current_jq"
  fi
  if [[ $total_set -eq 1 ]]; then
    if [[ -z "$jq_pipeline" ]]; then
      jq_pipeline=".in_flight[\$slot].progress_total = $total_jq"
    else
      jq_pipeline="$jq_pipeline | .in_flight[\$slot].progress_total = $total_jq"
    fi
  fi
  jq_pipeline="$jq_pipeline | .in_flight[\$slot].progress_updated_at = \$now | .updated_at = \$now"

  if ! jq --arg slot "$slot" --arg now "$now" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "set-progress: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

cmd_cleanup() {
  local session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      *) echo "cleanup: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "cleanup: --session-id is required" >&2
    usage
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  # Idempotent: missing file is a no-op success. The failure mode we're
  # guarding against is a session that half-cleaned (the file exists but
  # is corrupt, or the cleanup ran on the wrong session-id) — not a
  # session whose file is already gone.
  if [[ -f "$target" ]]; then
    rm -f "$target"
  fi
  # Also drop any leftover .tmp.<pid> files from a crashed update — these
  # are safe to remove unconditionally because they're per-pid and the
  # session we're cleaning up is by definition done.
  rm -f "${target}.tmp."* 2>/dev/null || true
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
  init)         cmd_init "$@" ;;
  read)         cmd_read "$@" ;;
  update)       cmd_update "$@" ;;
  cleanup)      cmd_cleanup "$@" ;;
  bump-tokens)  cmd_bump_tokens "$@" ;;
  read-tokens)  cmd_read_tokens "$@" ;;
  set-progress) cmd_set_progress "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "session-state.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
