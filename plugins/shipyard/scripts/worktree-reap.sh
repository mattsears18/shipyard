#!/usr/bin/env bash
# worktree-reap.sh — classify whether an agent worktree lock-file is safe
# to reap at end-of-session cleanup.
#
# Background (see issue #138): the orchestrator's end-of-session cleanup
# (`commands/do-work.md` → End-of-session cleanup → step 3) iterates
# `.git/worktrees/agent-*` and uses a PID liveness check to defer reaping
# whenever the lock-holding PID is alive — the idea being that an alive PID
# means a peer agent is still running and yanking its worktree would destroy
# in-flight work.
#
# That liveness check has a bug: the harness writes the **orchestrator's**
# PID into every dispatched agent's lock file (lock content is literally
# `claude agent <agent-id> (pid <orchestrator-pid>)`). At end-of-session
# cleanup the orchestrator is by definition still alive (it's the process
# running cleanup), so a strict liveness check defers EVERY worktree the
# orchestrator itself owns. The reporter saw 2 agent worktrees stuck because
# the lock PID was the orchestrator's PID 53391 — alive, but not a peer.
#
# Issue #138 added a third classification — **self-ancestor** — that walks
# the caller's own process-ancestor chain (self, parent, grandparent, …)
# and treats a lock-PID match anywhere in that chain as "the orchestrator
# about to retire its own worktree." Safe to reap.
#
# Issue #263 added a faster, more reliable path on top of the ancestor walk:
# the env var `SHIPYARD_ORCHESTRATOR_PID` (or the `--orchestrator-pid <N>`
# flag) lets the caller declare the orchestrator's PID explicitly. When the
# lock PID matches that declared PID, classification short-circuits to
# `self-ancestor` without traversing `/proc`. This matters because the
# ancestor walk can fail in two real-world cases:
#   - Process re-parenting: an intermediate harness layer in the orchestrator
#     → bash chain returns empty PPID, causing the walk to break before
#     reaching the orchestrator (the reporter saw this in production).
#   - Subagent invocation: when a dispatched subagent (fix-rebase, fix-checks)
#     runs classify-lock for diagnostic purposes, its `$$` is the subagent's
#     bash, and the ancestor walk goes up through the subagent's harness —
#     not the orchestrator's. The orchestrator IS the spawning principal but
#     isn't a Unix-ancestor of the subagent's bash.
# The env var path solves both: the orchestrator exports its own PID once at
# session start, every classify-lock call (orchestrator-side or subagent-side
# if propagated) gets an authoritative answer regardless of process-tree shape.
#
# Subcommand:
#
#   classify-lock <lock-file-path> [--orchestrator-pid <N>]
#     Emits one of (on stdout, single token, trailing newline):
#       no-lock        — lock file doesn't exist (safe to reap)
#       dead           — lock PID is dead (safe to reap, original semantics)
#       self-ancestor  — lock PID is alive AND is either (a) the declared
#                        orchestrator PID (via `SHIPYARD_ORCHESTRATOR_PID`
#                        env var or `--orchestrator-pid` flag) or (b) our
#                        own / an ancestor of ours (safe to reap — orchestrator
#                        owns this lock)
#       peer-alive     — lock PID is alive AND is NOT the declared orchestrator
#                        PID AND is NOT in our ancestor chain (defer — likely
#                        a peer agent or other instance)
#     Env vars:
#       SHIPYARD_ORCHESTRATOR_PID — explicit orchestrator PID. Takes
#                        precedence over the ancestor walk for the
#                        self-ancestor check. Overridden by `--orchestrator-pid`
#                        if both are set.
#     Exit codes:
#       0  classification emitted
#       2  bad usage (missing path, malformed flag value)
#
# Callers should reap on `no-lock` / `dead` / `self-ancestor`, defer on
# `peer-alive`.
#
# Pure bash + `ps`. No jq, no python, no awk — the helper has to be cheap
# to call from the cleanup loop (potentially once per agent worktree).

set -u

usage() {
  cat <<'EOF' >&2
Usage:
  worktree-reap.sh classify-lock <lock-file-path> [--orchestrator-pid <N>]
  worktree-reap.sh detect-orchestrator-pid [<comm-name>]

classify-lock — Prints one of: no-lock | dead | self-ancestor | peer-alive

detect-orchestrator-pid — Walks the process-ancestor chain and prints the
                          PID of the nearest ancestor whose `comm` matches
                          <comm-name> (default `claude`). Empty stdout if
                          no match. Useful for bootstrapping
                          SHIPYARD_ORCHESTRATOR_PID in shell snippets that
                          want classify-lock to short-circuit reliably.

Env vars:
  SHIPYARD_ORCHESTRATOR_PID  Explicit orchestrator PID for self-ancestor
                             short-circuit (classify-lock). Overridden by
                             --orchestrator-pid.

Exit codes:
  0  classification emitted (classify-lock) / PID printed or empty (detect)
  2  usage error (missing path, malformed flag)
EOF
}

# Extract the lock PID from a lock file.
#
# Lock-file format (set by the Claude Code harness):
#   claude agent <agent-id> (pid <N>)
#
# Returns the numeric PID on stdout, or empty string if no PID can be parsed.
# Robust to: missing file, malformed content, multiple PID-like tokens (takes
# the first one — the harness format only ever has one).
extract_lock_pid() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 0
  # `\(pid <N>\)` is the canonical shape. The grep below matches `pid <N>)`
  # and strips the trailing `)`; matches `<N>)` for the first decimal
  # sequence followed by a close-paren.
  grep -oE '[0-9]+\)' "$lock_file" 2>/dev/null | tr -d ')' | head -1
}

# Is `pid` alive? Returns 0 (alive) / 1 (dead-or-unknown).
pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  ps -p "$pid" -o pid= >/dev/null 2>&1
}

# Walk our own ancestor chain and emit each PID on its own line: self, parent,
# grandparent, ... up to PID 1 (init) or until `ps` stops resolving.
#
# Stops at PID 1 because every PID is an ancestor of itself trivially via
# init, and matching against PID 1 would defeat the point of the check.
#
# The orchestrator's PID will be in this list whenever this helper is called
# from a shell the orchestrator launched (transitively, however many harness
# layers are in between).
self_ancestor_pids() {
  local pid=$$
  local guard=0
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
    echo "$pid"
    # Bound the walk — defensive against pathological /proc states that
    # could loop. 64 ancestors is far beyond any real process tree.
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && break
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && break
    [ "$parent" = "$pid" ] && break   # paranoid: self-cycle
    pid="$parent"
  done
}

# Is `pid` in our own ancestor chain?
is_self_ancestor() {
  local target="$1"
  [ -n "$target" ] || return 1
  local p
  while IFS= read -r p; do
    [ "$p" = "$target" ] && return 0
  done < <(self_ancestor_pids)
  return 1
}

# Walk our own ancestor chain looking for a process whose comm matches the
# Claude Code orchestrator (default: literal `claude`). Emits the matched PID
# on stdout (empty if no match found). Used by the `detect-orchestrator-pid`
# subcommand and by `classify-lock`'s lazy auto-detect path to bootstrap the
# `SHIPYARD_ORCHESTRATOR_PID` short-circuit when callers haven't set it
# explicitly.
#
# The match is intentionally narrow: if the Claude Code binary is renamed,
# this detection returns empty and callers fall back to the ancestor-walk
# semantics inside `classify-lock`. False matches (a foreign `claude` process
# in the chain) are extremely unlikely — process names in the ancestor chain
# of a bash spawned by Claude Code are bash, sh, claude, login, etc. The risk
# threshold is low because a detected PID only short-circuits to
# `self-ancestor` when it EXACTLY matches the lock PID; a wrong detection
# only matters if it coincidentally matches a foreign live PID (negligible
# probability).
detect_orchestrator_pid() {
  local match_comm="${1:-claude}"
  local pid=$$
  local guard=0
  local comm
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && return 0
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    # `comm` on macOS returns the full executable path; basename it for the match.
    comm=$(basename "$comm" 2>/dev/null)
    if [ "$comm" = "$match_comm" ]; then
      echo "$pid"
      return 0
    fi
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && return 0
    [ "$parent" = "$pid" ] && return 0
    pid="$parent"
  done
}

classify_lock() {
  local lock_file=""
  local orchestrator_pid="${SHIPYARD_ORCHESTRATOR_PID:-}"

  # Argv parsing: positional <lock-file-path> first, then optional
  # --orchestrator-pid <N>. Flag-after-positional is the typical shape from
  # the orchestrator's call sites (`classify-lock "$wt_dir/locked"
  # --orchestrator-pid $$`); flag-before-positional also accepted.
  while [ $# -gt 0 ]; do
    case "$1" in
      --orchestrator-pid)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --orchestrator-pid requires a non-negative integer (got: ${2:-})" >&2
          return 2
        fi
        orchestrator_pid="$2"
        shift 2
        ;;
      --orchestrator-pid=*)
        local val="${1#--orchestrator-pid=}"
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --orchestrator-pid requires a non-negative integer (got: $val)" >&2
          return 2
        fi
        orchestrator_pid="$val"
        shift
        ;;
      --)
        shift
        ;;
      -*)
        echo "classify-lock: unknown flag: $1" >&2
        return 2
        ;;
      *)
        if [ -z "$lock_file" ]; then
          lock_file="$1"
        else
          echo "classify-lock: unexpected positional arg: $1" >&2
          return 2
        fi
        shift
        ;;
    esac
  done

  # An env-var value that isn't a non-negative integer is a configuration
  # bug at the call site — better to surface it than silently drop into the
  # ancestor-walk fallback. The --orchestrator-pid flag path already validates
  # above; this guard catches malformed env-var values.
  if [ -n "$orchestrator_pid" ] && ! [[ "$orchestrator_pid" =~ ^[0-9]+$ ]]; then
    echo "classify-lock: SHIPYARD_ORCHESTRATOR_PID must be a non-negative integer (got: $orchestrator_pid)" >&2
    return 2
  fi

  if [ -z "$lock_file" ]; then
    usage
    return 2
  fi

  if [ ! -f "$lock_file" ]; then
    echo "no-lock"
    return 0
  fi

  local lock_pid
  lock_pid=$(extract_lock_pid "$lock_file")

  # Lock file exists but has no parseable PID — treat as dead (the original
  # semantics didn't trip the liveness check either when extraction failed).
  if [ -z "$lock_pid" ]; then
    echo "dead"
    return 0
  fi

  if ! pid_alive "$lock_pid"; then
    echo "dead"
    return 0
  fi

  # Issue #263 fix: short-circuit on declared orchestrator PID before the
  # ancestor walk. This makes the classification authoritative regardless of
  # process-tree shape — covers cases where the ancestor walk fails because
  # an intermediate harness layer returns empty PPID, OR cases where the
  # caller is a subagent whose process tree doesn't actually reach back to
  # the orchestrator. The check is gated on `pid_alive` above so a stale
  # orchestrator PID (recycled by the OS) wouldn't wrongly match a live
  # peer's PID — the env var only short-circuits when the lock PID is alive
  # AND equals the declared orchestrator PID.
  if [ -n "$orchestrator_pid" ] && [ "$lock_pid" = "$orchestrator_pid" ]; then
    echo "self-ancestor"
    return 0
  fi

  if is_self_ancestor "$lock_pid"; then
    echo "self-ancestor"
    return 0
  fi

  echo "peer-alive"
  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    classify-lock)
      shift
      classify_lock "$@"
      ;;
    detect-orchestrator-pid)
      # Emit the PID of the nearest ancestor whose `comm` is `claude` (or
      # the override passed as the first arg). Empty stdout on no match.
      # Exit 0 whether or not a match was found — the caller decides what
      # to do with an empty result.
      shift
      detect_orchestrator_pid "${1:-claude}"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 2
      return 0
      ;;
    *)
      echo "worktree-reap.sh: unknown subcommand: $sub" >&2
      usage
      return 2
      ;;
  esac
}

main "$@"
