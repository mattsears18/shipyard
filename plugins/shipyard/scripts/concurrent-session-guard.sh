#!/usr/bin/env bash
# concurrent-session-guard.sh — dispatch-rules.md's "Concurrent-session
# guard (per-dispatch, before self-assign)", extracted to a script per
# issue #1289 (the follow-up to #1277/#1288).
#
# *** LOAD-BEARING CONCURRENCY-SAFETY LOGIC — READ BEFORE EDITING ***
#
# This is the second of the two blocks #1277's worker deliberately deferred
# rewriting under a rushed dispatch — see `pre-dispatch-branch-reap.sh`'s
# header for the shared rationale. Unlike that script, this one is
# READ-ONLY: it never reaps, never mutates a worktree, and never touches a
# branch ref. It answers exactly one question — "does a peer /do-work
# session already hold a live lock on a do-work/issue-<N> worktree?" — so a
# second concurrent session doesn't independently dispatch against the same
# issue and race to push to the same branch. Because it's read-only, the
# blast radius of a bug here is a wrongly-skipped or wrongly-dispatched
# candidate, never data loss — but it still preserves the original block's
# `unknown`-fails-closed posture (issue #1206) exactly, since a lock this
# check can't parse is exactly the case where guessing "available" is
# dangerous.
#
# Subcommand
# ----------
#
#   check --issue <N>
#     Exports SHIPYARD_ORCHESTRATOR_PID (issue #263 — so classify-lock
#     distinguishes our own session's locks, self-ancestor, from genuine
#     peer-session locks, peer-alive), walks every `agent-*` worktree under
#     the CURRENT checkout's `.git/worktrees` (uses `find`, not a bare
#     `agent-*` glob — under zsh's default `nomatch` option a glob
#     expanding to zero entries raises a fatal error; same class as
#     issues/335, which fixed setup.md's 3b loop — see issues/546 for
#     this guard's own repro),
#     and for the first one whose HEAD ref matches `do-work/issue-<N>`,
#     classifies its lock. `peer-alive` OR `unknown` (issue #1206 — a lock
#     file that exists but couldn't be parsed; treated identically: fail
#     closed) both set peer_locked=true and stop scanning; every other
#     classification (no-lock / dead / self-ancestor) keeps scanning past
#     it — a worktree with a DIFFERENT branch match is checked next, but a
#     branch match with a safe classification does NOT itself continue the
#     loop searching for a different (unsafe) worktree on the same branch
#     (git enforces one-worktree-per-branch, so there is at most one
#     candidate to find per invocation).
#
#     Prints exactly one line to stdout:
#       peer_locked=false
#     or
#       peer_locked=true classification=<peer-alive|unknown>
#
# Exit codes: 0 always (read-only classification, never fails the caller's
# dispatch turn); 64 bad usage.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  concurrent-session-guard.sh check --issue <N>
EOF
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  check)
    issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) issue="${2:-}"; shift 2 ;;
        *) echo "concurrent-session-guard.sh check: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$issue" ]; then
      echo "concurrent-session-guard.sh check: --issue is required" >&2
      usage >&2
      exit 64
    fi

    head_ref="do-work/issue-${issue}"
    # A split dispatch (operator_residual / verification_slice) is branched
    # `do-work/slice-<N>` instead, so its PR can't auto-link to the issue it
    # must not close (issue #1562). It is the SAME issue number, so a live
    # peer holding that worktree is the same race this guard exists to catch
    # — match either exact name. Deterministic-from-<N> by design: that is
    # why the neutral name carries no free-text slug.
    slice_ref="do-work/slice-${issue}"

    # Declare our orchestrator PID so classify-lock distinguishes our own
    # session's locks (self-ancestor) from genuine peer-session locks
    # (peer-alive). Issue #263: without this, classify-lock's ancestor walk
    # can mis-classify our own session's locks as peer-alive whenever an
    # intermediate harness layer returns empty PPID, blocking dispatch
    # against issues we're actively working.
    export SHIPYARD_ORCHESTRATOR_PID
    SHIPYARD_ORCHESTRATOR_PID=$("${here}/session-identity.sh" detect-orchestrator-pid)

    peer_locked=false
    peer_classification=""

    # while-read fed by process substitution, not `for x in $(find ...)`
    # (shellcheck SC2044 — word-splitting on find's output is fragile).
    # Process substitution keeps the loop in the main shell, so `break` and
    # every variable set inside still take effect after the loop ends.
    while IFS= read -r wt_dir; do
      branch_ref=$(sed 's|ref: refs/heads/||' "$wt_dir/HEAD" 2>/dev/null)
      if [ "$branch_ref" != "$head_ref" ] && [ "$branch_ref" != "$slice_ref" ]; then
        continue
      fi
      classification=$("${here}/worktree-reap.sh" classify-lock "$wt_dir/locked")
      # `unknown` (issue #1206 — lock file exists but couldn't be parsed) is
      # treated identically to `peer-alive` here: fail closed. Skipping the
      # candidate this dispatch turn is cheap and reversible; misclassifying
      # a live peer's lock as available and racing it to push the same
      # do-work/issue-<N> branch is not.
      if [ "$classification" = "peer-alive" ] || [ "$classification" = "unknown" ]; then
        peer_locked=true
        peer_classification="$classification"
        break
      fi
    done < <(find "$(git rev-parse --show-toplevel)/.git/worktrees" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null)

    if [ "$peer_locked" = "true" ]; then
      echo "peer_locked=true classification=${peer_classification}"
    else
      echo "peer_locked=false"
    fi
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "concurrent-session-guard.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
