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
# This helper fixes that by adding a fourth classification: **self-ancestor**.
# A lock PID that's alive but is part of our own process ancestor chain (self,
# parent, grandparent, …) is not a peer — it's the orchestrator about to
# retire its own worktree. Safe to reap.
#
# Subcommand:
#
#   classify-lock <lock-file-path>
#     Emits one of (on stdout, single token, trailing newline):
#       no-lock        — lock file doesn't exist (safe to reap)
#       dead           — lock PID is dead (safe to reap, original semantics)
#       self-ancestor  — lock PID is alive AND is our own / an ancestor of
#                        ours (safe to reap — orchestrator owns this lock)
#       peer-alive     — lock PID is alive AND is NOT in our ancestor chain
#                        (defer — likely a peer agent or other instance)
#     Exit codes:
#       0  classification emitted
#       2  bad usage (missing path)
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
  worktree-reap.sh classify-lock <lock-file-path>

Prints one of: no-lock | dead | self-ancestor | peer-alive
Exit codes:
  0  classification emitted
  2  usage error (missing path)
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

classify_lock() {
  local lock_file="${1:-}"
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
      classify_lock "${1:-}"
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
