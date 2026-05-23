#!/usr/bin/env bash
# setup-timing.sh — wall-clock instrumentation for /shipyard:do-work setup phases.
#
# Background (issue #238): the cost ledger captures total session duration and
# per-worker token cost, but not how long each setup step takes. Without
# per-phase wall-clock data, perf work targeting setup (#231 / #232 / #233
# in the #235 umbrella) is sized from spec-level reasoning rather than
# measurement. This helper records start/end timestamps for each named setup
# phase and flushes the result into the session state file's `setup` block,
# which the cost-history.sh flush persists into the cross-session ledger.
#
# Usage (bracket each setup step in setup.md with start + end calls):
#
#   # Before the step
#   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
#     --session-id "<session-id>" --phase step_0_5_worktree
#
#   # ... run the step ...
#
#   # After the step completes
#   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
#     --session-id "<session-id>" --phase step_0_5_worktree
#
# The helper writes timing data into temporary state in
# $SHIPYARD_HOME/sessions/<session-id>.timing.json (a sidecar to the main
# session file). This sidecar avoids contention with the orchestrator's
# concurrent session-state.sh update calls during the parallelised setup
# batch. The `flush` subcommand merges the sidecar into the session state
# file's `setup` block via `session-state.sh update`.
#
# Subcommands:
#
#   start --session-id <id> --phase <name>
#     Record the current UTC timestamp as the start of <phase>.
#     Creates the sidecar if it doesn't exist. Idempotent (re-starting a
#     phase overwrites the previous start time — useful if a step is retried).
#
#   end --session-id <id> --phase <name>
#     Record the current UTC timestamp as the end of <phase> and compute the
#     wall-clock duration in seconds. If no matching `start` call exists,
#     records the end time but logs a warning (duration is 0.0).
#
#   record-scope-preflight --session-id <id>
#                          --candidates-scoped <N>
#                          --ready-count <N>
#                          --deferred-count <N>
#                          --elapsed-seconds <F>
#     Record the scope_preflight sub-block. Called once after step 6 finishes.
#
#   flush --session-id <id>
#     Merge the sidecar into the session state file's `setup` block via
#     `session-state.sh update`. Computes `wall_clock_seconds` as the delta
#     between the earliest phase start and the latest phase end (or `now` if
#     flush is called before all phases are closed). Cleans up the sidecar
#     after a successful flush. Idempotent — re-flush is a no-op if the
#     sidecar is gone.
#
#   read --session-id <id> [--format json|text]
#     Emit the current timing state (sidecar if present, otherwise the
#     session-state `setup` block). Useful for debugging.
#
# Phase naming convention (matches the proposed spec in issue #238):
#
#   step_0_5_worktree           # step 0.5: move into orchestrator worktree
#   step_0_7_parallel_batch     # step 0.7: fire setup parallelisation batch
#   step_1_7_trusted_authors    # step 1.7: resolve trusted-author allowlist
#   step_3_5_refine_issues      # step 3.5: invoke /refine-issues
#   step_4_backlog_fetch_and_rank  # step 4: fetch + rank backlog
#   step_6_scope_preflight      # step 6: initial scope pre-flight
#
# The orchestrator may also instrument ad-hoc phases (e.g. step_3d_sweeps);
# this helper imposes no constraint on phase names beyond "no spaces."
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory. Defaults to $HOME/.shipyard. Same env
#                   var used by session-state.sh and cost-history.sh.
#
# Exit codes:
#
#   0   — success
#   3   — session file does not exist (flush --session-id references missing session)
#   64  — usage error (bad subcommand, missing required argument)
#   65+ — internal helper failure (jq missing, write error, etc.)

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "setup-timing.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  setup-timing.sh start  --session-id <id> --phase <name>
  setup-timing.sh end    --session-id <id> --phase <name>
  setup-timing.sh record-scope-preflight --session-id <id>
                         --candidates-scoped <N> --ready-count <N>
                         --deferred-count <N> --elapsed-seconds <F>
  setup-timing.sh flush  --session-id <id>
  setup-timing.sh read   --session-id <id> [--format json|text]

Environment:
  SHIPYARD_HOME  base dir (default: $HOME/.shipyard)

Exit codes:
  0    success
  3    session file missing (flush)
  64   usage error
  65+  internal helper failure
EOF
}

shipyard_home() {
  printf '%s\n' "${SHIPYARD_HOME:-${HOME}/.shipyard}"
}

sidecar_path() {
  local session_id="$1"
  printf '%s/sessions/%s.timing.json\n' "$(shipyard_home)" "$session_id"
}

session_state_path() {
  local session_id="$1"
  printf '%s/sessions/%s.json\n' "$(shipyard_home)" "$session_id"
}

# Atomic write for the sidecar (same pattern as session-state.sh atomic_write).
atomic_write_sidecar() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    trap - EXIT
    echo "setup-timing.sh: failed to write tmp file $tmp" >&2
    return 66
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    trap - EXIT
    echo "setup-timing.sh: failed to rename $tmp -> $target" >&2
    return 67
  fi
  trap - EXIT
}

# Read the sidecar into a variable, returning an empty JSON object if it
# doesn't exist yet.
read_sidecar() {
  local sidecar="$1"
  if [[ -f "$sidecar" ]]; then
    cat "$sidecar"
  else
    printf '{}'
  fi
}

# --------------------------------------------------------------------------
# start — record phase start timestamp
# --------------------------------------------------------------------------
cmd_start() {
  local session_id="" phase=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      *) echo "start: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "start: --session-id is required" >&2; usage; exit 64
  fi
  if [[ -z "$phase" ]]; then
    echo "start: --phase is required" >&2; usage; exit 64
  fi
  # Phase names must not contain spaces (they're used as JSON keys).
  if [[ "$phase" == *" "* ]]; then
    echo "start: --phase must not contain spaces (got: $phase)" >&2; exit 64
  fi

  local sidecar
  sidecar=$(sidecar_path "$session_id")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local current
  current=$(read_sidecar "$sidecar")

  local updated
  updated=$(printf '%s' "$current" | jq -c \
    --arg phase "$phase" \
    --arg now "$now" \
    '.phases[$phase].started_at = $now
     | .setup_started_at //= $now')

  printf '%s' "$updated" | atomic_write_sidecar "$sidecar"
}

# --------------------------------------------------------------------------
# end — record phase end timestamp and compute duration
# --------------------------------------------------------------------------
cmd_end() {
  local session_id="" phase=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      *) echo "end: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "end: --session-id is required" >&2; usage; exit 64
  fi
  if [[ -z "$phase" ]]; then
    echo "end: --phase is required" >&2; usage; exit 64
  fi

  local sidecar
  sidecar=$(sidecar_path "$session_id")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local current
  current=$(read_sidecar "$sidecar")

  local updated
  updated=$(printf '%s' "$current" | jq -c \
    --arg phase "$phase" \
    --arg now "$now" '
    # If a start was recorded, compute duration; otherwise warn (duration 0.0).
    (.phases[$phase].started_at) as $started
    | (if $started != null
        then (($now | fromdateiso8601) - ($started | fromdateiso8601))
        else 0
        end) as $dur
    | .phases[$phase].ended_at = $now
    | .phases[$phase].duration_seconds = $dur
    | .setup_ended_at = $now
  ')

  printf '%s' "$updated" | atomic_write_sidecar "$sidecar"

  # Advisory when no start was found for this phase.
  if ! printf '%s' "$current" | jq -e --arg phase "$phase" '.phases[$phase].started_at != null' >/dev/null 2>&1; then
    echo "setup-timing.sh: warning — end called for phase '$phase' with no matching start" >&2
  fi
}

# --------------------------------------------------------------------------
# record-scope-preflight — store the scope_preflight sub-block
# --------------------------------------------------------------------------
cmd_record_scope_preflight() {
  local session_id=""
  local candidates_scoped=""
  local ready_count=""
  local deferred_count=""
  local elapsed_seconds=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --candidates-scoped) candidates_scoped="${2:-}"; shift 2 ;;
      --ready-count) ready_count="${2:-}"; shift 2 ;;
      --deferred-count) deferred_count="${2:-}"; shift 2 ;;
      --elapsed-seconds) elapsed_seconds="${2:-}"; shift 2 ;;
      *) echo "record-scope-preflight: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "record-scope-preflight: --session-id is required" >&2; usage; exit 64
  fi

  # Validate numerics: accept integers and floats with optional decimal.
  for _val in "$candidates_scoped" "$ready_count" "$deferred_count" "$elapsed_seconds"; do
    if [[ -n "$_val" ]] && ! [[ "$_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      echo "record-scope-preflight: numeric args must be non-negative numbers (got: $_val)" >&2
      exit 64
    fi
  done

  local sidecar
  sidecar=$(sidecar_path "$session_id")

  local current
  current=$(read_sidecar "$sidecar")

  local updated
  # shellcheck disable=SC2016
  # rationale: single-quoted jq program uses jq variables ($candidates etc.)
  # bound via --argjson; shell expansion would corrupt the jq program.
  updated=$(printf '%s' "$current" | jq -c \
    --argjson candidates "${candidates_scoped:-0}" \
    --argjson ready "${ready_count:-0}" \
    --argjson deferred "${deferred_count:-0}" \
    --argjson elapsed "${elapsed_seconds:-0}" \
    '{
      candidates: $candidates,
      ready: $ready,
      deferred: $deferred,
      elapsed_seconds: $elapsed,
      avg_seconds_per_candidate: (
        if $candidates > 0
        then ($elapsed / $candidates * 10 | round / 10)
        else 0
        end
      )
    } as $preflight
    | . + {scope_preflight: $preflight}
  ')

  printf '%s' "$updated" | atomic_write_sidecar "$sidecar"
}

# --------------------------------------------------------------------------
# flush — merge sidecar into session state `setup` block
# --------------------------------------------------------------------------
cmd_flush() {
  local session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      *) echo "flush: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "flush: --session-id is required" >&2; usage; exit 64
  fi

  local sidecar
  sidecar=$(sidecar_path "$session_id")

  # Idempotent: if the sidecar is gone, the flush already ran.
  if [[ ! -f "$sidecar" ]]; then
    return 0
  fi

  local session_file
  session_file=$(session_state_path "$session_id")
  if [[ ! -f "$session_file" ]]; then
    echo "flush: session file $session_file does not exist" >&2
    exit 3
  fi

  # Build the `setup` block from the sidecar's contents.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local setup_block
  setup_block=$(jq -c \
    --arg now "$now" '
    . as $s
    | ($s.setup_started_at // $now) as $started
    | ($s.setup_ended_at // $now) as $ended
    | (($ended | fromdateiso8601) - ($started | fromdateiso8601)) as $wall
    | {
        started_at: $started,
        ended_at: $ended,
        wall_clock_seconds: ($wall | . * 10 | round / 10),
        phases: (
          ($s.phases // {})
          | to_entries
          | map({
              key: .key,
              value: (.value.duration_seconds // 0)
            })
          | from_entries
        ),
        scope_preflight: ($s.scope_preflight // null)
      }
  ' "$sidecar")

  if [[ -z "$setup_block" ]]; then
    echo "flush: failed to project setup block from sidecar $sidecar" >&2
    exit 68
  fi

  # Locate the session-state.sh helper relative to this script.
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local session_state_helper="${this_dir}/session-state.sh"

  if [[ ! -f "$session_state_helper" ]]; then
    echo "flush: session-state.sh not found at $session_state_helper" >&2
    exit 65
  fi

  # Merge via session-state.sh update so we get the same atomic-write
  # guarantee and the `updated_at` bookend.
  if ! "$session_state_helper" update \
       --session-id "$session_id" \
       --set ".setup = $setup_block"; then
    echo "flush: session-state.sh update failed" >&2
    exit 68
  fi

  # Remove the sidecar — flush is done.
  rm -f "$sidecar" "${sidecar}.tmp."* 2>/dev/null || true
}

# --------------------------------------------------------------------------
# read — emit timing state (sidecar or session-state setup block)
# --------------------------------------------------------------------------
cmd_read() {
  local session_id="" format="json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --format) format="${2:-json}"; shift 2 ;;
      *) echo "read: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "read: --session-id is required" >&2; usage; exit 64
  fi
  if [[ "$format" != "json" && "$format" != "text" ]]; then
    echo "read: --format must be json|text (got: $format)" >&2; exit 64
  fi

  local sidecar
  sidecar=$(sidecar_path "$session_id")

  local data
  if [[ -f "$sidecar" ]]; then
    data=$(cat "$sidecar")
  else
    local session_file
    session_file=$(session_state_path "$session_id")
    if [[ -f "$session_file" ]]; then
      data=$(jq '.setup // {}' "$session_file")
    else
      data='{}'
    fi
  fi

  if [[ "$format" == "json" ]]; then
    printf '%s\n' "$data"
  else
    # text: human-readable phase table
    printf '%s\n' "$data" | jq -r '
      "Setup timing:",
      "  wall_clock_seconds: " + ((.wall_clock_seconds // .phases | if type == "object" then "pending" else (. | tostring) end)),
      "  phases:",
      ((.phases // {}) | to_entries[]
        | "    " + .key + ": " + (.value | tostring) + "s")
    ' 2>/dev/null || printf '%s\n' "$data"
  fi
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
  start)                   cmd_start "$@" ;;
  end)                     cmd_end "$@" ;;
  record-scope-preflight)  cmd_record_scope_preflight "$@" ;;
  flush)                   cmd_flush "$@" ;;
  read)                    cmd_read "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "setup-timing.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
