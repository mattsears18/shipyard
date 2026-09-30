#!/usr/bin/env bash
# detect-peer-sessions.sh — detect other LIVE /shipyard:do-work sessions
# working the SAME repo right now, and report the issue/PR numbers they
# already have claimed (their .in_flight[].target set), so this session's
# setup can exclude those targets from its own raw_backlog before dispatch.
#
# Background (issue #1204)
# -------------------------
# Nothing in setup, dispatch, or drain previously looked for a peer
# /do-work session. Two sessions started ~13 minutes apart both fetched the
# same repo's backlog, both ranked it identically (ranking is deterministic),
# and both dispatched a worker against the SAME issue at the same time — one
# opened and merged a PR while the other's worker was still implementing
# against an issue that had already closed. Each duplicate dispatch costs a
# full worker run (~250k tokens observed) for nothing.
#
# The session-state file at $SHIPYARD_HOME/sessions/<id>.json already
# carries everything needed to detect this: `.repo`, `.in_flight[].target`,
# and (via mtime) a liveness proxy. sweep-orphan-sessions.sh already globs
# this exact directory (for the OPPOSITE purpose — reaping sessions whose
# mtime is OLDER than a staleness floor); this script walks the same
# directory and applies the same mtime-floor convention in the opposite
# direction: a session file is a LIVE PEER candidate only when its mtime is
# WITHIN the freshness window (the file is written through on every
# reconcile, so a fresh mtime is direct evidence the owning orchestrator is
# still turning). A session whose file has gone stale — including one that
# crashed mid-flight and left `.in_flight` permanently populated — ages out
# of consideration once its mtime crosses the same floor, so a dead peer
# can never permanently starve a fresh session's backlog.
#
# This is advisory, not a lock. Two sessions can still race between one's
# check here and the other's next write — the goal is to reliably catch the
# common case (a peer that has been running for minutes), not to build a
# distributed mutex. See RATIONALE in do-work-rationale.md for the
# warn-and-continue policy this script's caller applies on a fully
# overlapping peer, rather than halting the session to ask a human.
#
# Subcommands:
#
#   check --shipyard-home <dir> --repo <owner/repo> --current-session-id <id>
#         [--fresh-min <N>]
#     Sweeps $SHIPYARD_HOME/sessions/*.json whose mtime is within
#     --fresh-min minutes (default 30, overridable via
#     SHIPYARD_PEER_FRESH_MIN — same default as sweep-orphan-sessions.sh's
#     staleness floor, per do-work's "follow the existing convention and
#     threshold rather than inventing a new one"), excluding the file named
#     by --current-session-id. For each fresh file whose `.repo` field
#     matches --repo (case-sensitive, exact `owner/repo` string), prints
#     one line naming the peer and the issue/PR numbers its `.in_flight`
#     claims:
#       peer: <session-id> claimed=<N,N,...|(none)>
#     A malformed/unreadable session file is skipped silently (advisory
#     read — never fail the caller's setup flow on one bad file) and noted
#     to stderr as `skip: <path> (<why>)`.
#     Always ends with exactly one summary line:
#       summary: peers=<P> claimed_targets=<N,N,...|(none)>
#     `claimed_targets` is the deduped, numerically-sorted union of every
#     peer's claimed targets — this is the set setup step 4's client-side
#     filter excludes from raw_backlog.
#     Exit codes:
#       0  check completed (even if zero peers found — always emits at
#          least the summary line)
#       64 bad usage (missing --shipyard-home / --repo /
#          --current-session-id, malformed --fresh-min)
set -u

FRESH_MIN_DEFAULT="${SHIPYARD_PEER_FRESH_MIN:-30}"

usage() {
  cat <<'EOF'
Usage: detect-peer-sessions.sh check --shipyard-home <dir> --repo <owner/repo> --current-session-id <id> [--fresh-min <N>]
EOF
}

# Portable file-mtime-in-seconds (epoch). GNU first, BSD/macOS fallback —
# same order sweep-orphan-sessions.sh and sweep-orphan-tmp.sh use.
_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

_age_minutes() {
  local m now
  m=$(_mtime_epoch "$1")
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  echo $(( (now - m) / 60 ))
}

# Normalize a raw `.in_flight[].target` value into a bare integer. The
# schema documents `target` as a number, but a live repro has shown it
# written as a string with a leading '#' (e.g. "#1201") — strip any
# non-digit characters and keep whatever digits remain. Empty/unparseable
# input yields no output (the caller drops it).
_normalize_target() {
  local raw="$1" digits
  digits=$(printf '%s' "$raw" | tr -dc '0-9')
  [[ -n "$digits" ]] && printf '%s\n' "$digits"
}

check() {
  local shipyard_home="" repo="" current_session_id="" fresh_min="$FRESH_MIN_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shipyard-home) shipyard_home="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --current-session-id) current_session_id="${2:-}"; shift 2 ;;
      --fresh-min) fresh_min="${2:-}"; shift 2 ;;
      *) echo "check: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$shipyard_home" ]]; then
    echo "check: --shipyard-home is required" >&2
    usage
    return 64
  fi
  if [[ -z "$repo" ]]; then
    echo "check: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$current_session_id" ]]; then
    echo "check: --current-session-id is required" >&2
    usage
    return 64
  fi
  if [[ ! "$fresh_min" =~ ^[0-9]+$ ]]; then
    echo "check: --fresh-min must be a non-negative integer, got: $fresh_min" >&2
    return 64
  fi

  local sessions_dir="$shipyard_home/sessions"
  local peers=0
  # Accumulate every peer's targets into one newline-delimited buffer and
  # dedupe with `sort -u` at the end, rather than an associative array —
  # `declare -A` requires bash >= 4, and macOS ships bash 3.2 as `/bin/bash`
  # by default (no associative-array support at all, a hard parse error).
  # This script has to run under whatever `bash` the caller's shell resolves
  # to, so it avoids the bash-4-only feature entirely.
  local claimed_all=""

  if [[ ! -d "$sessions_dir" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "summary: peers=0 claimed_targets=(none)"
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    local candidate_id
    candidate_id=$(basename "$candidate" .json)

    if [[ "$candidate_id" == "$current_session_id" ]]; then
      continue
    fi

    local body
    if ! body=$(jq -c '.' "$candidate" 2>/dev/null); then
      echo "skip: $candidate (unreadable/malformed JSON)" >&2
      continue
    fi

    local candidate_repo
    candidate_repo=$(printf '%s' "$body" | jq -r '.repo // empty' 2>/dev/null)
    if [[ "$candidate_repo" != "$repo" ]]; then
      continue
    fi

    # Live peer on the same repo, within the freshness window. Collect its
    # in_flight targets.
    local targets_raw target norm
    targets_raw=$(printf '%s' "$body" | jq -r '
      (.in_flight // {}) | to_entries[]? | .value.target // empty
    ' 2>/dev/null)

    local peer_targets=()
    while IFS= read -r target; do
      [[ -z "$target" ]] && continue
      norm=$(_normalize_target "$target")
      [[ -z "$norm" ]] && continue
      peer_targets+=("$norm")
      claimed_all="${claimed_all}${norm}
"
    done <<<"$targets_raw"

    local age
    age=$(_age_minutes "$candidate") || age="?"

    peers=$((peers+1))
    if [[ "${#peer_targets[@]}" -eq 0 ]]; then
      echo "peer: $candidate_id claimed=(none) (age=${age}m)"
    else
      local joined
      joined=$(IFS=,; echo "${peer_targets[*]}")
      echo "peer: $candidate_id claimed=$joined (age=${age}m)"
    fi
  done < <(find "$sessions_dir" -maxdepth 1 -type f -name '*.json' -mmin "-$fresh_min" 2>/dev/null)

  local sorted
  sorted=$(printf '%s' "$claimed_all" | sed '/^$/d' | sort -n -u | paste -sd, -)
  if [[ -z "$sorted" ]]; then
    echo "summary: peers=$peers claimed_targets=(none)"
  else
    echo "summary: peers=$peers claimed_targets=$sorted"
  fi
  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    check)
      shift
      check "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "detect-peer-sessions.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"
exit $?
