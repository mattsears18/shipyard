#!/usr/bin/env bash
# gh-cached.sh — session-scoped cache wrapper for read-only `gh` CLI calls.
#
# Background (issue #160 / phase 3 of #152): within a single orchestrator
# session (typically 5-15 minutes) GitHub state doesn't change much except
# for the artifacts shipyard itself is modifying. But the orchestrator
# re-fetches state on every phase transition:
#
#   Phase 1 (setup):       gh issue list                        (~50 issues)
#   Phase 4 (dispatch):    gh pr list (in-flight check)         (~10 PRs)
#   Phase 5 (drain):       gh pr list again + per-PR gh pr view (~10 PRs + N views)
#   Phase 6 (summary):     gh pr list again                     (~10 PRs)
#
# Most of those answers haven't changed. A wrapper that:
#
#   1. keys by the full argv (so different filters land in different cache
#      slots);
#   2. caches the stdout to a session-scoped file;
#   3. honors a per-call TTL passed by the caller;
#   4. exposes an `invalidate` subcommand so the orchestrator can drop
#      cache files after a write (issue close, PR create, label add, etc.)
#
# … eliminates the redundant calls without losing freshness.
#
# Subcommands:
#
#   run      — Run `gh <args...>` if no fresh cache hit exists; otherwise
#              emit the cached stdout. Required flags:
#                --ttl <seconds>   how long a cache file is "fresh"
#                --session-id <id> session-scoped cache namespace
#              The remaining argv after `--` is passed verbatim to `gh`.
#              Exit code mirrors the underlying `gh` call on a miss; on a
#              hit, exit 0 (the cached output is by definition a prior
#              successful run — we never cache errors).
#
#   invalidate — Drop cache files. Required flag:
#                --session-id <id>
#              Optional:
#                --pattern <substring>  only invalidate files whose argv-hash
#                                       label matches; without it, drops
#                                       every cache file for the session.
#              Idempotent — exits 0 even when nothing matched.
#
#   stats    — Emit JSON cache-usage stats for the session. Required:
#                --session-id <id>
#              Output: `{"hits": N, "misses": N, "invalidations": N, "bytes": N}`.
#              All counters live in a single `_stats.json` next to the
#              cache files and are bumped via atomic-write (mirrors
#              session-state.sh).
#
#   cleanup  — Remove the entire session cache directory. Required:
#                --session-id <id>
#              Idempotent — exits 0 if the directory was already gone.
#
# Caching contract — load-bearing rules:
#
#   - Cache keys are sha256(argv concatenated by NUL). Two calls with the
#     same arg vector resolve to the same file regardless of the order in
#     which the flags appear if and only if the caller passes them in the
#     same order. We do NOT canonicalize — order-sensitive keying keeps the
#     wrapper simple and matches gh's own argument-order semantics for the
#     queries we care about.
#
#   - Only stdout is cached. Stderr is passed through live (not cached) so
#     warnings and rate-limit advisories surface to the orchestrator.
#
#   - Only zero-exit calls are cached. A non-zero `gh` exit means either a
#     transient failure (rate limit, 5xx) or a programming error (bad
#     query). Caching either is the wrong move — both cases should retry on
#     the next call, not serve stale "success" data.
#
#   - TTLs are caller-supplied. We don't ship a default because the right
#     TTL depends on the query: `gh issue list` can survive 60s of staleness,
#     `gh pr view <N> --json statusCheckRollup` should not (CI churns fast).
#     The do-work spec documents the TTL bands per call-site.
#
#   - The cache is session-scoped. `$SHIPYARD_HOME/cache/<session-id>/` is
#     reaped at end-of-session along with the session state file. We never
#     reuse cache across sessions — the cost of a cold start is one round
#     of normal `gh` calls; the cost of cross-session stale data would be
#     dispatch decisions based on the previous session's view of the world.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory for shipyard's per-user state. Defaults
#                   to `$HOME/.shipyard`. Cache lives at
#                   `$SHIPYARD_HOME/cache/<session-id>/`. Mirrors
#                   `session-state.sh`'s convention so callers point at one
#                   home and get both paths.
#
#   SHIPYARD_GH_CACHE_DISABLED — when set to `1`, every `run` call invokes
#                   `gh` live and skips both reads and writes to the cache.
#                   Useful for debugging "is the cache hiding a real
#                   change?" without uninstalling. Stats subcommand still
#                   works; `invalidate` and `cleanup` still operate on
#                   whatever's already on disk.
#
# Exit codes:
#
#   0   — success (cache hit OR successful gh call OR successful subcommand)
#   2   — cache miss followed by a failed `gh` call. Stdout is whatever gh
#         emitted before the failure; stderr was passed through live; the
#         cache file is NOT created. The caller can retry on the next
#         iteration.
#   3   — required dependency missing (gh, sha256sum/shasum, jq)
#   64  — usage error (missing or malformed flag)
#   65+ — internal helper failure (filesystem permission denied, atomic-rename
#         failure, etc.)

set -u

# --------------------------------------------------------------------------
# Dependency checks. `gh` is the underlying CLI we wrap; `sha256sum` (Linux)
# or `shasum` (macOS) hashes argv; `jq` is used for stats JSON updates.
# --------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! have_cmd gh; then
  echo "gh-cached.sh: gh CLI is required but not installed" >&2
  exit 3
fi

# Resolve the SHA implementation once. macOS ships shasum but not
# sha256sum; Linux usually ships both. We standardize on a function so the
# rest of the script doesn't branch.
sha256_stdin() {
  if have_cmd sha256sum; then
    sha256sum | awk '{print $1}'
  elif have_cmd shasum; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "gh-cached.sh: need sha256sum or shasum (neither found)" >&2
    return 3
  fi
}

usage() {
  cat <<'EOF' >&2
Usage:
  gh-cached.sh run        --session-id <id> --ttl <seconds> -- <gh-args...>
  gh-cached.sh invalidate --session-id <id> [--pattern <substring>]
  gh-cached.sh stats      --session-id <id>
  gh-cached.sh cleanup    --session-id <id>

Environment:
  SHIPYARD_HOME              base dir for cache/ (default: $HOME/.shipyard)
  SHIPYARD_GH_CACHE_DISABLED set to 1 to bypass the cache on every run

Exit codes:
  0    success
  2    cache miss followed by failed `gh` call
  3    missing dependency (gh / sha256sum|shasum / jq)
  64   usage error
  65+  internal helper failure
EOF
}

# Resolve the canonical cache directory for a session.
cache_dir() {
  local session_id="$1"
  local home="${SHIPYARD_HOME:-${HOME}/.shipyard}"
  printf '%s/cache/%s\n' "$home" "$session_id"
}

# Atomic write: stdin → target. Same pattern as session-state.sh — tmp
# in the same dir + rename. POSIX-atomic on the same filesystem; a crash
# mid-write leaves the previous file (or no file) intact rather than a
# corrupted half-write.
atomic_write() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  # shellcheck disable=SC2064
  # rationale: capture current $tmp value, not deferred expansion.
  trap "rm -f '$tmp'" EXIT
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    trap - EXIT
    echo "gh-cached.sh: failed to write tmp file $tmp" >&2
    return 66
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    trap - EXIT
    echo "gh-cached.sh: failed to rename $tmp -> $target" >&2
    return 67
  fi
  trap - EXIT
}

# Compute the file mtime in epoch seconds. macOS BSD stat vs Linux GNU
# stat disagree on the flag — try both, in that order.
file_mtime_epoch() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    printf '0\n'
    return
  fi
  local m
  m=$(stat -f '%m' "$f" 2>/dev/null)
  if [[ -z "$m" ]]; then
    m=$(stat -c '%Y' "$f" 2>/dev/null)
  fi
  if [[ -z "$m" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$m"
  fi
}

# Bump one or more stats counters atomically. Counters live in
# <cache-dir>/_stats.json. Missing fields default to 0; jq is required.
bump_stats() {
  local dir="$1"
  shift
  if ! have_cmd jq; then
    # Stats bookkeeping is observational — silently skip when jq isn't
    # available rather than fail the wrapper. The cache still works.
    return 0
  fi
  mkdir -p "$dir"
  local file="$dir/_stats.json"
  local existing='{"hits":0,"misses":0,"invalidations":0,"bytes":0}'
  if [[ -f "$file" ]]; then
    existing=$(cat "$file" 2>/dev/null || printf '%s' "$existing")
    # Defensive: malformed stats file falls back to defaults rather than
    # propagating a parse error. Stats lossiness is acceptable.
    if ! printf '%s' "$existing" | jq empty >/dev/null 2>&1; then
      existing='{"hits":0,"misses":0,"invalidations":0,"bytes":0}'
    fi
  fi
  local jq_pipeline=""
  while [[ $# -gt 0 ]]; do
    local key="$1"
    local delta="$2"
    shift 2
    if [[ -z "$jq_pipeline" ]]; then
      jq_pipeline=".$key = ((.$key // 0) + $delta)"
    else
      jq_pipeline="$jq_pipeline | .$key = ((.$key // 0) + $delta)"
    fi
  done
  if [[ -z "$jq_pipeline" ]]; then
    return 0
  fi
  printf '%s' "$existing" | jq "$jq_pipeline" 2>/dev/null | atomic_write "$file" || return 0
}

cmd_run() {
  local session_id=""
  local ttl=""
  local gh_args=()
  local saw_double_dash=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --ttl)        ttl="${2:-}"; shift 2 ;;
      --)           saw_double_dash=1; shift; break ;;
      -h|--help)    usage; exit 0 ;;
      *)
        echo "run: unexpected arg before --: $1" >&2
        usage
        exit 64
        ;;
    esac
  done

  if [[ $saw_double_dash -eq 1 ]]; then
    gh_args=("$@")
  fi

  if [[ -z "$session_id" ]]; then
    echo "run: --session-id is required" >&2
    usage
    exit 64
  fi
  if [[ -z "$ttl" ]]; then
    echo "run: --ttl is required" >&2
    usage
    exit 64
  fi
  if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "run: --ttl must be a non-negative integer (got: $ttl)" >&2
    exit 64
  fi
  if [[ ${#gh_args[@]} -eq 0 ]]; then
    echo "run: missing gh arguments after --" >&2
    usage
    exit 64
  fi

  # Disabled-cache fast path: run gh live, no read, no write, no stats.
  if [[ "${SHIPYARD_GH_CACHE_DISABLED:-0}" == "1" ]]; then
    gh "${gh_args[@]}"
    return $?
  fi

  local dir
  dir=$(cache_dir "$session_id")

  # Compute the cache key from argv. printf %s\0 between args; we
  # deliberately include the literal arg vector (no canonicalization) so
  # different orderings land in different slots. That matches gh's own
  # behavior — `gh issue list --state open --limit 100` and `gh issue
  # list --limit 100 --state open` are equivalent semantically but two
  # different cache slots is fine: caller controls the surface.
  local key
  if ! key=$(printf '%s\0' "${gh_args[@]}" | sha256_stdin); then
    return 3
  fi
  local cache_file="$dir/$key"

  # Cache-hit path: file exists and is fresh (mtime within TTL).
  if [[ -f "$cache_file" ]]; then
    local now mtime age
    now=$(date -u +%s)
    mtime=$(file_mtime_epoch "$cache_file")
    age=$((now - mtime))
    if [[ "$age" -ge 0 && "$age" -lt "$ttl" ]]; then
      cat "$cache_file"
      bump_stats "$dir" hits 1
      return 0
    fi
  fi

  # Cache miss (or stale): run gh, capture stdout, pass stderr through.
  # Using a temp file (rather than `out=$(...)`) lets us preserve the exact
  # bytes including trailing newlines.
  mkdir -p "$dir"
  local tmp_out="${cache_file}.run.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_out'" EXIT
  gh "${gh_args[@]}" > "$tmp_out"
  local gh_rc=$?

  # On success, atomically promote tmp_out to the cache file and serve
  # the contents. On failure, emit the captured stdout (matches gh's
  # own behavior — useful for the caller to surface partial output) but
  # don't cache the failed call.
  if [[ "$gh_rc" -eq 0 ]]; then
    local bytes
    bytes=$(wc -c < "$tmp_out" | tr -d ' ')
    if ! mv -f "$tmp_out" "$cache_file"; then
      # Failed to commit cache file; serve the output anyway from tmp.
      cat "$tmp_out" 2>/dev/null || true
      rm -f "$tmp_out"
      trap - EXIT
      return 0
    fi
    trap - EXIT
    cat "$cache_file"
    bump_stats "$dir" misses 1 bytes "$bytes"
    return 0
  fi

  # gh failed. Pass through whatever stdout it produced, do not cache.
  cat "$tmp_out" 2>/dev/null || true
  rm -f "$tmp_out"
  trap - EXIT
  bump_stats "$dir" misses 1
  return 2
}

cmd_invalidate() {
  local session_id=""
  local pattern=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --pattern)    pattern="${2:-}"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "invalidate: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "invalidate: --session-id is required" >&2
    usage
    exit 64
  fi

  local dir
  dir=$(cache_dir "$session_id")
  if [[ ! -d "$dir" ]]; then
    # Nothing to invalidate is success — idempotent.
    return 0
  fi

  local removed=0
  if [[ -z "$pattern" ]]; then
    # Drop every cache file (but keep the stats file — counters survive
    # invalidation calls, otherwise a `stats` query right after a flush
    # would silently report 0 across the session and obscure cumulative
    # cache usage).
    local f
    shopt -s nullglob
    for f in "$dir"/*; do
      local base
      base=$(basename "$f")
      if [[ "$base" == "_stats.json" ]]; then
        continue
      fi
      if [[ -f "$f" ]]; then
        rm -f "$f"
        removed=$((removed + 1))
      fi
    done
    shopt -u nullglob
  else
    # Match cache files whose basename (the argv sha) starts with the
    # pattern. The pattern surface is intentionally narrow — callers
    # don't know the sha shape, so the practical use is `--pattern ""`
    # (drop everything) or, less commonly, a sha prefix from a prior
    # stats inspection. Substring-on-basename suffices.
    local f
    shopt -s nullglob
    for f in "$dir"/*; do
      local base
      base=$(basename "$f")
      if [[ "$base" == "_stats.json" ]]; then
        continue
      fi
      if [[ "$base" == *"$pattern"* ]]; then
        rm -f "$f"
        removed=$((removed + 1))
      fi
    done
    shopt -u nullglob
  fi

  if [[ "$removed" -gt 0 ]]; then
    bump_stats "$dir" invalidations "$removed"
  fi
}

cmd_stats() {
  local session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "stats: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "stats: --session-id is required" >&2
    usage
    exit 64
  fi

  local dir
  dir=$(cache_dir "$session_id")
  local file="$dir/_stats.json"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    # No activity yet — emit zeroed defaults so the caller doesn't have
    # to special-case missing files.
    printf '{"hits":0,"misses":0,"invalidations":0,"bytes":0}\n'
  fi
}

cmd_cleanup() {
  local session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "cleanup: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "cleanup: --session-id is required" >&2
    usage
    exit 64
  fi

  local dir
  dir=$(cache_dir "$session_id")
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
  fi
  # Idempotent: missing dir is a no-op success.
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
  run)         cmd_run "$@" ;;
  invalidate)  cmd_invalidate "$@" ;;
  stats)       cmd_stats "$@" ;;
  cleanup)     cmd_cleanup "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "gh-cached.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
