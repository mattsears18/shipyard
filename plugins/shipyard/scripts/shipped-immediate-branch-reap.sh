#!/usr/bin/env bash
# shipped-immediate-branch-reap.sh — steady-state.md's A.1 "shipped"-return
# immediate worktree reap (closes #282, force-reaps peer-alive per #576),
# extracted to a script per issue #1289 (the follow-up to #1277/#1288).
#
# *** LOAD-BEARING WORKTREE-LOCK-REAPING LOGIC — READ BEFORE EDITING ***
#
# Same family as `pre-dispatch-branch-reap.sh` (dispatch-rules.md §2d) and
# `drain-pre-dispatch-branch-reap.sh` (drain.md's pre-dispatch reap) — see
# either script's header for the shared concurrency-safety history
# (#368/#576/#771/#832/#1206/#1274). This one fires immediately when an
# issue-work worker returns `shipped #<N> via PR #<M>` — the worker's
# TERMINAL contract, so the agent subprocess has exited and its worktree
# has no further purpose by definition. Unlike step B's general-purpose
# reap (which conservatively defers on peer-alive for unknown return
# shapes), this call site KNOWS the worker is done and force-reaps even on
# peer-alive (audited as "peer-alive-force"), mirroring A.0.5's crash-return
# posture. Deferring here would reproduce the #576 drain-phase bail window:
# a peer-alive defer leaves the head branch locked, and drain's OWN
# pre-dispatch reap would then also (in the pre-#576 world) defer on it,
# leaving fix-checks/fix-rebase stuck bailing "branch locked in another
# worktree."
#
# Deliberately NO in-flight guard (#832) here — and that omission is
# correct, not an oversight. Every other reap site in this family scans
# MULTIPLE candidate worktrees (any agent-* whose branch matches some
# pattern) and needs the in-flight snapshot to avoid yanking a live peer's
# worktree it merely resembles. This site targets EXACTLY ONE worktree —
# THIS just-shipped slot's own `do-work/issue-<N>` branch, which is unique
# per issue number by construction, so no other in-flight peer can hold it.
# `classify-lock` is still the correct (and only necessary) liveness check
# for this single worktree.
#
# Subcommand
# ----------
#
#   reap --issue <N>
#     Anchors cwd to a stable directory (issue #497 — before the reap, so a
#     harness cwd-leak into the very worktree this removes can't strand the
#     closing `git worktree prune`), derives the session id cwd-independently
#     (issue #548 — via `session-identity.sh derive-session-id`, falling
#     back to the `.shipyard-session-id` stash file), derives the primary
#     checkout path (porcelain-derived), exports SHIPYARD_ORCHESTRATOR_PID
#     (#263), walks `.git/worktrees/agent-*` for the worktree whose HEAD is
#     exactly `do-work/issue-<N>`, classifies its lock, force-reaps
#     regardless of classification (relabeling `peer-alive` ->
#     `peer-alive-force` for audit visibility). On a VERIFIED successful
#     removal (see #1404 below), drops the local branch ref so a
#     same-session fix-rebase dispatch can recreate it cleanly. Stops after
#     the first match (`break` — at most one match per issue number), then
#     runs `git worktree prune`.
#
#     Every mutating step is fire-and-forget (`2>/dev/null` and/or
#     `|| true`), matching the original block's posture.
#
#     Issue #1404 — the delegated `worktree-reap.sh reap --action reaped`
#     call's own exit status is NOT a trustworthy success signal: its
#     `reap_action()` (for the `reaped` action) `return`s 0 unconditionally
#     regardless of whether the underlying removal actually happened — it
#     only varies which action string ("reaped" vs "reaped-failed") lands in
#     the AUDIT LOG (see #712) — and this caller's own `2>/dev/null || true`
#     additionally discards stderr and any non-reap_action exit (e.g. the
#     delegated process crashing before reaching that branch at all). Before
#     ever reporting success, this script re-checks the filesystem itself:
#     did `$worktree_path` actually disappear? If it did not, this script
#     records the failure via `worktree-reap.sh reap --action reaped-failed`
#     itself (the #1274 directly-invocable failure-log path) — so the audit
#     trail is correct even when the delegated call never wrote its own
#     "reaped-failed" line — and reports the distinct `reaped=failed` token
#     below rather than `reaped=true`. It also does NOT drop the local
#     branch ref in this case, since the worktree still holds it checked
#     out.
#
#     Prints exactly one line to stdout so the caller's SEPARATE, later
#     verify-the-reap-happened call (issue #1274) can substitute these
#     literal values (shell variables don't survive across Bash tool
#     calls):
#
#       reaped=false session_id=<id-or-unknown>
#     or
#       reaped=true worktree_path=<path> worktree_name=<name> classification=<local_classification> lock_pid=<pid-or-null> session_id=<id-or-unknown>
#     or (#1404 — a genuine match was found but the delegated removal did
#     not actually take)
#       reaped=failed worktree_path=<path> worktree_name=<name> classification=<local_classification> lock_pid=<pid-or-null> session_id=<id-or-unknown> reason=delegated-reap-did-not-remove-worktree
#
# Exit codes: 0 always (fire-and-forget, matches the original block); 64 bad
# usage.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  shipped-immediate-branch-reap.sh reap --issue <N>
EOF
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  reap)
    issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) issue="${2:-}"; shift 2 ;;
        *) echo "shipped-immediate-branch-reap.sh reap: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$issue" ]; then
      echo "shipped-immediate-branch-reap.sh reap: --issue is required" >&2
      usage >&2
      exit 64
    fi

    head_ref="do-work/issue-${issue}"
    # A split dispatch (operator_residual / verification_slice) branches
    # `do-work/slice-<N>` instead, so its PR can't auto-link to the issue it
    # must not close (issue #1562). Still exactly one worktree per issue
    # number, so matching either exact name preserves this loop's
    # unique-by-construction property.
    slice_ref="do-work/slice-${issue}"

    # Anchor cwd to a stable directory BEFORE the reap (issue #497). The
    # harness can leak the orchestrator's cwd into an `agent-*` worktree
    # this block then `git worktree remove --force`s; once that dir is
    # gone, `git worktree prune` (and any follow-up git command) fails with
    # "fatal: Unable to read current working directory". Derive the anchor
    # cwd-independently via the #477 porcelain idiom (orchestrator worktree
    # first, primary as fallback) while cwd is still valid, then cd to it.
    STABLE_DIR=$(awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}' \
      <(git worktree list --porcelain 2>/dev/null))
    [ -z "$STABLE_DIR" ] && STABLE_DIR=$(awk '/^worktree /{print substr($0,10); exit}' \
      <(git worktree list --porcelain 2>/dev/null))
    cd "${STABLE_DIR:-/}" 2>/dev/null || cd /

    # Derive the session id cwd-independently while STABLE_DIR is still
    # valid. After the cd above, cwd is either the orchestrator worktree or
    # the primary checkout — both are safe anchors for the derive helper.
    # This closes #548: the reap's --session-id must not read from the
    # (possibly leaked-to-agent) cwd; it must read from the orchestrator
    # worktree stash.
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    SESSION_ID=$("${here}/session-identity.sh" derive-session-id --repo-root "$REPO_ROOT" 2>/dev/null)
    [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
    if [ -z "$SESSION_ID" ]; then
      echo "[session-id-derive] empty — reap audit-log entries will lack session-id; check for #477 cwd-leak (#548)" >&2
      SESSION_ID="unknown"
    fi

    # PRIMARY is the first `worktree ` entry — the .git/worktrees walk
    # below needs the primary's path (linked worktrees share the common
    # .git dir).
    PRIMARY_CHECKOUT=$(awk '/^worktree /{print substr($0,10); exit}' <(git worktree list --porcelain 2>/dev/null))

    # Bootstrap the orchestrator PID so classify-lock can short-circuit on
    # our own session's locks (issue #263).
    export SHIPYARD_ORCHESTRATOR_PID
    SHIPYARD_ORCHESTRATOR_PID=$("${here}/session-identity.sh" detect-orchestrator-pid)

    reaped=false
    reap_failed=false
    worktree_path=""
    name=""
    local_classification=""
    lock_pid=""

    # In-flight guard (#832) deliberately NOT applied here — see header
    # comment. The do-work/issue-<N> branch filter below scopes this loop
    # to exactly one worktree, unique per issue number by construction.
    for wt_dir in "${PRIMARY_CHECKOUT}/.git/worktrees"/agent-*; do
      [ -d "$wt_dir" ] || continue
      branch_ref=$(sed 's|ref: refs/heads/||' "$wt_dir/HEAD" 2>/dev/null)
      if [ "$branch_ref" != "$head_ref" ] && [ "$branch_ref" != "$slice_ref" ]; then
        continue
      fi

      name=$(basename "$wt_dir")
      worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
      [ -z "$worktree_path" ] && continue

      classification=$("${here}/worktree-reap.sh" classify-lock "$wt_dir/locked")

      # Anchor on the literal `pid` keyword, not "first digit-run before a
      # close-paren" — the latter misparses a real `(pid <N> start <ctime>)`
      # lock as the ctime's trailing year (issue #1206).
      lock_pid_match=$(grep -m1 -oE '\(pid[[:space:]]+[0-9]+' "$wt_dir/locked" 2>/dev/null)
      lock_pid="${lock_pid_match//[!0-9]/}"
      [ -z "$lock_pid" ] && lock_pid="null"

      # no-lock / dead / self-ancestor / peer-alive — all safe to reap
      # here. A `shipped` return is the worker's terminal contract; the
      # agent is done by definition. Force-reap on peer-alive mirrors
      # A.0.5's posture for crash returns and closes the #576 drain-phase
      # bail window. Audit with classification "peer-alive-force" so the
      # override is traceable in ~/.shipyard/reap-audit.jsonl.
      local_classification="$classification"
      [ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"
      "${here}/worktree-reap.sh" reap \
        --action reaped \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "$SESSION_ID" \
        --classification "$local_classification" \
        --lock-pid "$lock_pid" \
        --phase "steady-state-A1-shipped" 2>/dev/null || true

      # Issue #1404 — verify the delegated removal actually happened before
      # ever reporting success. The delegated call's own exit status is not
      # a trustworthy signal (see the header comment above): re-check the
      # filesystem itself.
      if [ -e "$worktree_path" ]; then
        # The worktree survived — whether because the removal failed
        # cleanly (worktree-reap.sh's own reap_action already logged
        # "reaped-failed" internally, per #712) or because the delegated
        # call crashed before ever reaching that branch (nothing logged at
        # all). Record the failure here too, via the #1274
        # directly-invocable failure-log action, so the audit trail is
        # correct in BOTH cases rather than depending on every caller (e.g.
        # steady-state.md's own belt-and-suspenders verify step, which
        # exists for the unrelated classifier-denial case) to notice and
        # backfill it.
        "${here}/worktree-reap.sh" reap \
          --action reaped-failed \
          --worktree-path "$worktree_path" \
          --worktree-name "$name" \
          --session-id "$SESSION_ID" \
          --classification "$local_classification" \
          --reason "delegated-reap-did-not-remove-worktree" \
          --lock-pid "$lock_pid" \
          --phase "steady-state-A1-shipped" 2>/dev/null || true
        reap_failed=true
        break   # at most one match per issue number — nothing else to try
      fi

      # Drop the local branch ref so a same-session fix-rebase dispatch can
      # recreate do-work/issue-<N> cleanly via `git switch` without
      # tripping the "branch already exists in another worktree" check.
      # `-D` (force) rather than `-d` because the branch may have unmerged
      # commits relative to current local main — the canonical record is
      # on origin, not this branch. Only reached when the removal above was
      # actually verified (worktree_path no longer exists) — dropping the
      # branch ref while a still-present worktree holds it checked out
      # would be wrong (#1404).
      # Drop the ref this worktree actually held ($branch_ref), not the
      # canonical name — on a split dispatch those differ ($slice_ref,
      # issue #1562) and dropping the wrong one would leave the real branch
      # pinned.
      git branch -D "$branch_ref" 2>/dev/null || true
      reaped=true
      break   # at most one match per issue number
    done
    git worktree prune 2>/dev/null || true

    if [ "$reaped" = "true" ]; then
      echo "reaped=true worktree_path=${worktree_path} worktree_name=${name} classification=${local_classification} lock_pid=${lock_pid} session_id=${SESSION_ID}"
    elif [ "$reap_failed" = "true" ]; then
      echo "reaped=failed worktree_path=${worktree_path} worktree_name=${name} classification=${local_classification} lock_pid=${lock_pid} session_id=${SESSION_ID} reason=delegated-reap-did-not-remove-worktree"
    else
      echo "reaped=false session_id=${SESSION_ID}"
    fi
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "shipped-immediate-branch-reap.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
