#!/usr/bin/env bash
# status.sh — render the /shipyard:status live dashboard from the
# per-session state file(s) at `$SHIPYARD_HOME/sessions/*.json`.
#
# Background (issue #167): /shipyard:do-work workers run as background
# subagents. Once dispatched, the user has no visibility into what each
# worker is doing until it returns. This script reads the durable session
# state file the orchestrator writes through every turn (via
# session-state.sh init/update/set-progress) and produces a dashboard
# answering "what is shipyard actually doing right now?".
#
# Per the refinement-resolved defaults: NO `last_tool` field is rendered,
# and the `--history` flag is deferred to a follow-up. The fields this
# script reads off each in-flight slot are:
#
#   .in_flight[<slot>].kind                    — issue / fix-checks / fix-rebase / fix-main-ci / fix-failing-prs-batch
#   .in_flight[<slot>].target                  — #N or "main" or "pr-pileup"
#   .in_flight[<slot>].started_at              — ISO-8601 UTC, set on dispatch
#   .in_flight[<slot>].progress_current        — optional batch counter (from set-progress)
#   .in_flight[<slot>].progress_total          — optional batch denominator
#   .in_flight[<slot>].progress_updated_at     — last set-progress write
#   .tokens.per_issue[<N>]                     — per-issue token totals (#153)
#   .tokens.per_pr[<M>]                        — per-pr token totals (#153)
#
# Subcommands:
#
#   render   — default; print the dashboard as fixed-width text.
#   render --json    — emit a machine-readable JSON projection of the
#                      same data (one object per active session).
#   render --stale   — show only workers whose progress_updated_at (or
#                      started_at if no progress write yet) is older
#                      than the stale threshold (5 min by default).
#
# Environment variables:
#
#   SHIPYARD_HOME            base dir (default: $HOME/.shipyard) — same as
#                            session-state.sh, mirrors the do-work spec.
#   SHIPYARD_STATUS_STALE_S  stale threshold in seconds (default: 300 = 5 min).
#
# Exit codes:
#
#   0   success (including "no active sessions")
#   64  usage error
#   65+ internal helper failure (jq missing, date arithmetic failed, etc.)

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "status.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  status.sh [render] [--json] [--stale]

Reads per-session state files at $SHIPYARD_HOME/sessions/*.json and
prints a dashboard of active /shipyard:do-work workers.

Flags:
  --json     emit a machine-readable JSON projection (one object per
             active session) instead of the text dashboard.
  --stale    show only workers whose last progress update (or dispatch
             time if no progress write yet) is older than the stale
             threshold (default: 5 minutes; override via
             SHIPYARD_STATUS_STALE_S).

Environment:
  SHIPYARD_HOME             base dir for sessions/ (default: $HOME/.shipyard)
  SHIPYARD_STATUS_STALE_S   stale threshold in seconds (default: 300)
EOF
}

# Resolve the sessions directory. Mirrors session-state.sh's `session_path()`.
sessions_dir() {
  local home="${SHIPYARD_HOME:-${HOME}/.shipyard}"
  printf '%s/sessions\n' "$home"
}

# Convert a number of seconds to a compact `Hh Mm Ss` or `Mm Ss` or `Ss`
# string. Used for elapsed time + stale-age rendering.
fmt_duration() {
  local s="$1"
  if [[ -z "$s" || "$s" == "null" || ! "$s" =~ ^-?[0-9]+$ ]]; then
    printf '—'
    return
  fi
  if [[ "$s" -lt 0 ]]; then s=0; fi
  local hours minutes seconds
  hours=$((s / 3600))
  minutes=$(((s % 3600) / 60))
  seconds=$((s % 60))
  if [[ "$hours" -gt 0 ]]; then
    printf '%dh %02dm %02ds' "$hours" "$minutes" "$seconds"
  elif [[ "$minutes" -gt 0 ]]; then
    printf '%dm %02ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

# Compact token count: 12340 -> "12.3k", 1240000 -> "1.2M". Used in the
# dashboard's TOKENS column. Plain digits below 1000 to avoid `0.5k`-style
# noise for short-lived workers.
fmt_tokens() {
  local n="$1"
  if [[ -z "$n" || "$n" == "null" || ! "$n" =~ ^[0-9]+$ ]]; then
    printf '—'
    return
  fi
  if [[ "$n" -lt 1000 ]]; then
    printf '%d' "$n"
  elif [[ "$n" -lt 1000000 ]]; then
    # awk for the decimal: bash arithmetic is integer-only.
    awk -v n="$n" 'BEGIN { printf "%.1fk", n / 1000 }'
  else
    awk -v n="$n" 'BEGIN { printf "%.1fM", n / 1000000 }'
  fi
}

# Parse an ISO-8601 UTC timestamp into epoch seconds. macOS BSD date and
# GNU date disagree on the input flag (`-j -f` vs `-d`), so try both.
iso_to_epoch() {
  local ts="$1"
  if [[ -z "$ts" || "$ts" == "null" ]]; then
    printf '0\n'
    return
  fi
  # Strip the trailing Z so both `date` variants accept the format.
  local stripped="${ts%Z}"
  # GNU date (Linux).
  local epoch
  epoch=$(date -u -d "$stripped" +%s 2>/dev/null || true)
  if [[ -z "$epoch" ]]; then
    # BSD date (macOS).
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null || true)
  fi
  if [[ -z "$epoch" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$epoch"
  fi
}

# Render the dashboard as a JSON projection (machine-readable). Same
# fields as the text renderer, structured per-session-per-slot.
render_json() {
  local dir="$1"
  local stale_only="$2"
  local stale_s="$3"
  local now_epoch
  now_epoch=$(date -u +%s)

  # Walk every session file in the dir. Emit one JSON object per session.
  local files=()
  if [[ -d "$dir" ]]; then
    shopt -s nullglob
    for f in "$dir"/*.json; do
      files+=("$f")
    done
    shopt -u nullglob
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '[]\n'
    return
  fi

  # Build the projection. jq does the per-slot extraction; the shell layer
  # computes elapsed seconds (jq can't portably do the date arithmetic).
  local out_entries=()
  local f
  for f in "${files[@]}"; do
    # Read base session metadata + in_flight slots.
    local session_json
    session_json=$(jq -c \
      --argjson now "$now_epoch" \
      --argjson stale_s "$stale_s" \
      --arg stale_only "$stale_only" \
      '
      {
        session_id: .session_id,
        repo: .repo,
        started_at: .started_at,
        updated_at: .updated_at,
        concurrency: .concurrency,
        in_flight: [
          .in_flight | to_entries[] | {
            slot: .key,
            kind: .value.kind,
            target: .value.target,
            started_at: (.value.started_at // null),
            progress_current: (.value.progress_current // null),
            progress_total: (.value.progress_total // null),
            progress_updated_at: (.value.progress_updated_at // null),
            tokens: (
              if (.value.kind == "issue") then
                (.value.target | tostring) as $key
                | ($key as $k | { input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0 })
              else { input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0 }
              end
            )
          }
        ]
      }
      ' "$f" 2>/dev/null) || continue

    # Augment per-slot tokens by joining .tokens.per_issue / per_pr from the
    # session file. Doing this in a second jq pass keeps the projection
    # readable.
    session_json=$(jq -c --slurpfile state <(jq '{tokens}' "$f") '
      .in_flight |= map(
        . as $slot
        | $state[0].tokens as $tok
        | (
            if $slot.kind == "issue" then
              ($tok.per_issue[$slot.target | tostring] // null)
            elif ($slot.kind | test("^fix-")) then
              ($tok.per_pr[$slot.target | tostring] // null)
            else null
            end
          ) as $bucket
        | .tokens = (
            if $bucket == null then
              { input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0 }
            else $bucket
            end
          )
      )
    ' <<< "$session_json")

    out_entries+=("$session_json")
  done

  if [[ ${#out_entries[@]} -eq 0 ]]; then
    printf '[]\n'
    return
  fi

  # Apply the stale filter (if requested) and the elapsed-seconds enrichment
  # in one final pass. The shell pre-computed `now_epoch`; jq uses it.
  printf '%s\n' "${out_entries[@]}" | jq -s \
    --argjson now "$now_epoch" \
    --argjson stale_s "$stale_s" \
    --arg stale_only "$stale_only" \
    '
    map(
      .in_flight |= map(
        # Synthesise an epoch the dashboard can use without re-doing the
        # date parse. We piggyback the shell-side computation by sending
        # `.started_at_epoch` / `.progress_updated_at_epoch` if available
        # via a pre-step; absent that, the JSON consumer can derive them.
        . + {
          stale: (
            (.progress_updated_at // .started_at) as $ref
            | if $ref == null then false
              else
                # Best-effort: jq can compare ISO strings lexicographically
                # so long as both are UTC-Z. We compute "stale" as "ref is
                # older than now - stale_s" but jq lacks portable date math;
                # the shell-side renderer computes the real boolean. Default
                # to false here so JSON consumers see the raw timestamps.
                false
              end
          )
        }
      )
    )
    | if $stale_only == "1" then
        map(. as $s | $s.in_flight |= map(select(.stale == true)) | $s)
        | map(select(.in_flight | length > 0))
      else . end
    '
}

# Render the dashboard as fixed-width text.
render_text() {
  local dir="$1"
  local stale_only="$2"
  local stale_s="$3"
  local now_epoch
  now_epoch=$(date -u +%s)

  local files=()
  if [[ -d "$dir" ]]; then
    shopt -s nullglob
    for f in "$dir"/*.json; do
      files+=("$f")
    done
    shopt -u nullglob
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    printf 'SHIPYARD STATUS — no active sessions.\n\n'
    printf 'Looked in: %s\n' "$dir"
    printf "\n"
    printf 'A session file appears here when /shipyard:do-work is running.\n'
    return
  fi

  # Pre-compute the per-session row data into a tab-delimited buffer the
  # text-rendering loop walks. Keeps the loop body simple and avoids
  # repeated jq invocations.
  local rows=()
  local total_in_flight=0
  local total_tokens=0
  local oldest_elapsed=0

  local f
  for f in "${files[@]}"; do
    # Skip files that aren't valid JSON (a half-written file would be a
    # race against an in-progress atomic write — read it on the next tick).
    if ! jq -e '.' "$f" >/dev/null 2>&1; then
      continue
    fi

    local session_id repo
    session_id=$(jq -r '.session_id' "$f")
    repo=$(jq -r '.repo' "$f")

    # Walk each in-flight slot.
    local slot_count
    slot_count=$(jq -r '.in_flight | length' "$f")
    if [[ "$slot_count" -eq 0 ]]; then
      continue
    fi

    # Token bookkeeping per slot — read once per file.
    local slots_json
    slots_json=$(jq -c '
      .tokens as $tok
      | .in_flight | to_entries | map(
          . as $entry
          | {
              slot: .key,
              kind: .value.kind,
              target: .value.target,
              started_at: (.value.started_at // null),
              progress_current: (.value.progress_current // null),
              progress_total: (.value.progress_total // null),
              progress_updated_at: (.value.progress_updated_at // null),
              tokens: (
                if .value.kind == "issue" then
                  ($tok.per_issue[.value.target | tostring] // {input:0,output:0,cache_read:0,cache_creation:0,estimated_usd:0})
                elif (.value.kind | test("^fix-")) then
                  ($tok.per_pr[.value.target | tostring] // {input:0,output:0,cache_read:0,cache_creation:0,estimated_usd:0})
                else {input:0,output:0,cache_read:0,cache_creation:0,estimated_usd:0}
                end
              )
            }
        )
      ' "$f")

    local n
    n=$(jq -r 'length' <<< "$slots_json")
    local i
    for ((i = 0; i < n; i++)); do
      local slot kind target started_at progress_current progress_total progress_updated_at
      local t_input t_output t_cache_read t_cache_creation
      slot=$(jq -r ".[$i].slot" <<< "$slots_json")
      kind=$(jq -r ".[$i].kind" <<< "$slots_json")
      target=$(jq -r ".[$i].target" <<< "$slots_json")
      started_at=$(jq -r ".[$i].started_at // \"null\"" <<< "$slots_json")
      progress_current=$(jq -r ".[$i].progress_current // \"null\"" <<< "$slots_json")
      progress_total=$(jq -r ".[$i].progress_total // \"null\"" <<< "$slots_json")
      progress_updated_at=$(jq -r ".[$i].progress_updated_at // \"null\"" <<< "$slots_json")
      t_input=$(jq -r ".[$i].tokens.input // 0" <<< "$slots_json")
      t_output=$(jq -r ".[$i].tokens.output // 0" <<< "$slots_json")
      t_cache_read=$(jq -r ".[$i].tokens.cache_read // 0" <<< "$slots_json")
      t_cache_creation=$(jq -r ".[$i].tokens.cache_creation // 0" <<< "$slots_json")

      # Compute elapsed seconds since started_at (or session.started_at as
      # a fallback for legacy slots without a per-slot timestamp).
      local started_ref="$started_at"
      if [[ "$started_ref" == "null" ]]; then
        started_ref=$(jq -r '.started_at' "$f")
      fi
      local started_epoch
      started_epoch=$(iso_to_epoch "$started_ref")
      local elapsed=$((now_epoch - started_epoch))
      if [[ "$started_epoch" -eq 0 ]]; then
        elapsed=-1
      fi

      # Stale detection: progress_updated_at (or started_at if no progress
      # yet) more than stale_s ago.
      local ref_ts="$progress_updated_at"
      if [[ "$ref_ts" == "null" ]]; then
        ref_ts="$started_ref"
      fi
      local ref_epoch
      ref_epoch=$(iso_to_epoch "$ref_ts")
      local stale_age=$((now_epoch - ref_epoch))
      local is_stale=0
      if [[ "$ref_epoch" -gt 0 && "$stale_age" -ge "$stale_s" ]]; then
        is_stale=1
      fi

      # Stale-only filter.
      if [[ "$stale_only" == "1" && "$is_stale" -eq 0 ]]; then
        continue
      fi

      # Aggregate token count for the TOKENS column.
      local slot_tokens=$((t_input + t_output + t_cache_read + t_cache_creation))
      total_tokens=$((total_tokens + slot_tokens))
      total_in_flight=$((total_in_flight + 1))
      if [[ "$elapsed" -gt "$oldest_elapsed" ]]; then
        oldest_elapsed="$elapsed"
      fi

      # Format the row. Use tabs as a delimiter — the renderer below
      # walks it and pads to fixed widths.
      local progress_str=""
      if [[ "$progress_current" != "null" && "$progress_total" != "null" ]]; then
        progress_str=" ($progress_current/$progress_total)"
      fi

      local target_str
      case "$kind" in
        issue)                     target_str="#$target" ;;
        fix-checks*)               target_str="PR #$target" ;;
        fix-rebase)                target_str="PR #$target" ;;
        fix-main-ci)               target_str="main" ;;
        fix-failing-prs-batch)     target_str="pr-pileup" ;;
        *)                         target_str="$target" ;;
      esac

      local stale_marker=""
      if [[ "$is_stale" -eq 1 ]]; then
        stale_marker=" ⚠ STALE"
      fi

      local elapsed_str
      elapsed_str=$(fmt_duration "$elapsed")
      local tokens_str
      tokens_str=$(fmt_tokens "$slot_tokens")
      local stale_age_str
      stale_age_str=$(fmt_duration "$stale_age")

      rows+=("$session_id"$'\t'"$repo"$'\t'"$slot"$'\t'"$kind$progress_str"$'\t'"$target_str"$'\t'"$elapsed_str"$'\t'"$tokens_str"$'\t'"$stale_marker"$'\t'"$stale_age_str")
    done
  done

  # Header — count of distinct sessions + total workers.
  local session_count=0
  if [[ ${#rows[@]} -gt 0 ]]; then
    session_count=$(printf '%s\n' "${rows[@]}" | awk -F'\t' '{print $1}' | sort -u | wc -l | tr -d ' ')
  fi

  printf 'SHIPYARD STATUS — %d active worker(s) across %d session(s)\n\n' \
    "$total_in_flight" "$session_count"

  if [[ "$total_in_flight" -eq 0 ]]; then
    if [[ "$stale_only" == "1" ]]; then
      printf '  (no stale workers — all in-flight workers have updated within %d seconds)\n' "$stale_s"
    else
      printf '  (no in-flight workers; sessions present but no slots active)\n'
    fi
    return
  fi

  # Render the table. Columns: WORKER (kind+progress) / TARGET / ELAPSED / TOKENS / STALE.
  printf '  %-26s %-32s %-10s %-12s %-10s %s\n' "WORKER" "TARGET" "ELAPSED" "TOKENS" "STALE-AGE" ""
  printf '  %-26s %-32s %-10s %-12s %-10s %s\n' \
    "──────────────────────────" \
    "────────────────────────────────" \
    "──────────" \
    "────────────" \
    "──────────" \
    ""

  # Group rows by session for readability.
  local current_session=""
  local r
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r session_id repo slot worker target elapsed tokens stale_marker stale_age <<< "$r"
    if [[ "$session_id" != "$current_session" ]]; then
      if [[ -n "$current_session" ]]; then
        printf '\n'
      fi
      printf '  [session: %s · repo: %s]\n' "$session_id" "$repo"
      current_session="$session_id"
    fi
    printf '  %-26s %-32s %-10s %-12s %-10s%s\n' \
      "$worker" "$target" "$elapsed" "$tokens" "$stale_age" "$stale_marker"
  done

  printf '\n'
  local total_tokens_str
  total_tokens_str=$(fmt_tokens "$total_tokens")
  local oldest_elapsed_str
  oldest_elapsed_str=$(fmt_duration "$oldest_elapsed")
  printf 'TOTAL: %s tokens in flight, oldest worker %s\n' "$total_tokens_str" "$oldest_elapsed_str"
}

# ----------------------------------------------------------------------
# Argument parsing.
# ----------------------------------------------------------------------

format="text"
stale_only="0"
stale_s="${SHIPYARD_STATUS_STALE_S:-300}"

# Optional first positional subcommand.
if [[ $# -gt 0 ]]; then
  case "$1" in
    render) shift ;;
    -h|--help|help) usage; exit 0 ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) format="json"; shift ;;
    --stale) stale_only="1"; shift ;;
    --stale-seconds) stale_s="${2:-300}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "status.sh: unknown arg $1" >&2; usage; exit 64 ;;
  esac
done

if ! [[ "$stale_s" =~ ^[0-9]+$ ]]; then
  echo "status.sh: stale threshold must be a non-negative integer (got: $stale_s)" >&2
  exit 64
fi

dir=$(sessions_dir)

case "$format" in
  text) render_text "$dir" "$stale_only" "$stale_s" ;;
  json) render_json "$dir" "$stale_only" "$stale_s" ;;
esac
