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
  session-state.sh init     --session-id <id> --repo <owner/repo>
                            [--concurrency N] [--soft-collision-concurrency N]
                            [--force]
  session-state.sh read     --session-id <id> [--path <jq-path>]
  session-state.sh update   --session-id <id> --set '<jq-expr>' [--set ...]
  session-state.sh cleanup  --session-id <id>

Environment:
  SHIPYARD_HOME             base dir for sessions/ (default: $HOME/.shipyard)

Exit codes:
  0   success
  2   refused to clobber (init w/o --force)
  3   session file missing (read or update)
  64  usage error
  65+ internal helper failure
EOF
}

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
  init)    cmd_init "$@" ;;
  read)    cmd_read "$@" ;;
  update)  cmd_update "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
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
