#!/usr/bin/env bash
# heal-stale-primary-checkout.sh — setup step 0.41's staleness GATE
# (closes #1386). Turns step 0.4's advisory "your primary checkout is N
# commits behind" warning into a hard decision: fast-forward the primary
# checkout (provably lossless) so the session runs the CURRENT spec, or
# refuse to run at all.
#
# Background — why a gate, and why HERE (issue #1386)
# ---------------------------------------------------
# In the dogfooding case (shipyard orchestrating its own repo),
# CLAUDE_PLUGIN_ROOT resolves REPO-LOCAL, so every spec file the session
# reads is whatever commit the user's primary checkout happens to sit at.
# A long chain of fixes tried to make a stale session recover:
#
#   #907  — added the staleness WARNING at step 0.4.
#   #1191 — step 0.6:  post-relocation fresh re-read of the bootstrap files.
#   #1351 — step 0.42: pre-relocation fresh re-read + a diff that detects
#                      newly-added pre-relocation-window (0.4x) steps.
#   #1319 — warns the dispatched WORKER, via the dispatch prompt.
#
# Every one of those fixes lives in spec prose, so a checkout stale enough
# to need it is stale enough to lack the pointer TO it. #1386's repro:
# a 155-commit-stale primary ran a `00-config-worktree.md` whose step
# sequence was `0.3 -> 0.4 -> 0.5 -> 0.55 -> 0.56 -> 0.7` — no 0.42, no
# 0.45, no 0.6 — so all three recovery steps were invisible at exactly the
# moment they were needed. The recursion is structural: any fix expressed
# as "the stale file should tell you to do X" is one release behind by
# construction.
#
# Step 0.4's staleness check is the one anchor that breaks it: it has been
# present in essentially its current form since #907, so even a badly
# drifted checkout reaches it. This script changes what happens NEXT —
# the check's ACTION, not its position.
#
# Two independent classes of damage this closes
# ---------------------------------------------
#   1. Unreachable recovery steps (the tabulated 0.42 / 0.45 / 0.6 misses
#      above). A session that skips 0.45 also runs the pre-relocation
#      worktree sweeps AFTER `EnterWorktree`, where the isolation guard
#      refuses the `git -C <other-worktree>` calls they need.
#   2. Silent whole-session config reversion. #1059 correctly pins
#      SHIPYARD_REPO_ROOT to the PRIMARY checkout so post-relocation reads
#      still see the gitignored `.shipyard/config.local.json` layer. On a
#      STALE primary that pin selects a `shipyard.config.json` predating
#      the current schema (#1386's repro: `.labels.blocked` /
#      `.labels.blocked_hard`, retired by #1376, inside the drift window),
#      so `shipyard-config.sh` exits 70 on every read. Every consumer is
#      deliberately fail-open, so the observable symptom is an empty string
#      and exit 0 — indistinguishable from "this repo sets no override."
#      `models.*`, `trust.authors`, `auto_merge.policy`, `concurrency.*`,
#      `cost_tracking.*`, `ci.*` and `flake_registry.*` all silently revert
#      to built-in defaults for the whole session. A primary that is never
#      allowed to be stale cannot carry a config predating its own schema,
#      so the gate closes this path with no separate work.
#
# Preconditions on the WRITE — do not widen
# -----------------------------------------
# `dont.md` forbids writes to the user's primary checkout and names exactly
# one sanctioned exception: A.0.6's primary-checkout branch-leak guard (see
# `primary-leak-guard.sh`), which may move the primary's HEAD only when the
# tree is CLEAN, making the restore provably lossless. This script extends
# that same clean-tree-only posture to a fast-forward, which is strictly
# weaker: it discards nothing by construction.
#
#   - Heals ONLY when the primary is on the default branch AND it has no
#     TRACKED modifications (staged or unstaged). A user parked on a
#     feature branch is doing deliberate work; moving their HEAD would be a
#     surprise, not a correction — so that case refuses with an actionable
#     message instead.
#   - UNTRACKED files do not block the heal (issue #1616). A fast-forward
#     cannot lose untracked content: git refuses the merge outright rather
#     than overwrite an untracked path the incoming commits would add, and
#     that refusal surfaces as `heal-failed` (with a reason naming the
#     collision), never a clobber. Untracked tool artifacts (`.codex/`,
#     `AGENTS.md`, editor dirs, scratch notes) are the common case on a
#     maintainer checkout, so treating them as "possible real edits"
#     turned a routine lossless fast-forward into a session-ending refusal.
#   - The merge is `--ff-only` against the already-fetched remote-tracking
#     ref. Local commits ahead of origin make the fast-forward impossible,
#     which surfaces as `heal-failed` rather than a merge commit.
#   - Never `git stash`, never `git clean`, never `git reset --hard`, never
#     `git checkout <branch>`. The only write is the fast-forward.
#
# Migration cost (bounded, one-time). A checkout stale enough to predate
# THIS script still misses it — the same one-level-deep property every
# prior fix had. The difference is that this is the LAST such miss: once a
# session runs step 0.41 it either becomes fresh or stops, so no future
# recovery step inherits the hole. That is a bounded one-time cost versus
# the current unbounded recursion.
#
# Subcommand
# ----------
#
#   run --primary <path> --default-branch <name> [--max-attempts <n>]
#       [--attempt <n>] [--no-fetch]
#
#     --primary         the user's PRIMARY checkout root (step 0.4's
#                       SHIPYARD_PRIMARY_CHECKOUT_ROOT).
#     --default-branch  the repo's default branch name (step 0.4's
#                       STALENESS_DEFAULT_BRANCH).
#     --attempt         which heal attempt this is, 1-based. The caller
#                       restarts setup from step 0.3 after a `healed`
#                       verdict, which re-enters this gate; passing the
#                       incremented attempt number caps that loop.
#     --max-attempts    attempt cap (default 2). At or past the cap the
#                       script refuses instead of healing again.
#     --no-fetch        skip the best-effort `git fetch` (step 0.4 already
#                       fetched; useful for offline tests).
#
# Output (stdout, key=value lines):
#   verdict=<fresh|healed|dirty-refuse|branch-refuse|attempt-refuse|heal-failed|error>
#   primary_checkout=<path-or-empty>
#   primary_branch=<branch-or-empty>
#   default_branch=<branch-or-empty>
#   behind_before=<n-or-empty>
#   behind_after=<n-or-empty>
#   head_before=<short-sha-or-empty>
#   head_after=<short-sha-or-empty>
#   reason=<free-text, populated on every non-fresh verdict>
#
# Each verdict is its OWN value — none are folded together. #1323's lesson
# on `primary-leak-guard.sh` was that a blanket swallow made "checked, all
# fine" indistinguishable from "could not check at all"; the same applies
# here to "I won't heal" (three distinct refusals) versus "I tried and
# couldn't" (`heal-failed`) versus "nothing to do" (`fresh`).
#
# Exit codes: 0 on fresh/healed; 1 on any refusal (dirty / branch /
# attempt); 2 on heal-failed; 3 on error; 64 bad usage. Unlike
# `primary-leak-guard.sh` this is a GATE, not an advisory — a non-zero exit
# means the caller must NOT continue setup.

set -u

usage() {
  cat <<'EOF'
Usage:
  heal-stale-primary-checkout.sh run --primary <path> --default-branch <name> \
      [--attempt <n>] [--max-attempts <n>] [--no-fetch]
EOF
}

PRIMARY_CHECKOUT=""
PRIMARY_BRANCH=""
DEFAULT_BRANCH=""
BEHIND_BEFORE=""
BEHIND_AFTER=""
HEAD_BEFORE=""
HEAD_AFTER=""

emit() {
  local verdict="$1" reason="$2"
  printf 'verdict=%s\n' "$verdict"
  printf 'primary_checkout=%s\n' "$PRIMARY_CHECKOUT"
  printf 'primary_branch=%s\n' "$PRIMARY_BRANCH"
  printf 'default_branch=%s\n' "$DEFAULT_BRANCH"
  printf 'behind_before=%s\n' "$BEHIND_BEFORE"
  printf 'behind_after=%s\n' "$BEHIND_AFTER"
  printf 'head_before=%s\n' "$HEAD_BEFORE"
  printf 'head_after=%s\n' "$HEAD_AFTER"
  printf 'reason=%s\n' "$reason"
}

behind_count() {
  # Commits on origin/<default> that HEAD lacks. Empty when the ref pair
  # can't be resolved (no remote-tracking ref, unborn HEAD).
  git -C "$PRIMARY_CHECKOUT" rev-list --count "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  run)
    attempt=1
    max_attempts=2
    do_fetch=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --primary)        PRIMARY_CHECKOUT="${2:-}"; shift 2 ;;
        --default-branch) DEFAULT_BRANCH="${2:-}"; shift 2 ;;
        --attempt)        attempt="${2:-}"; shift 2 ;;
        --max-attempts)   max_attempts="${2:-}"; shift 2 ;;
        --no-fetch)       do_fetch=0; shift ;;
        *) echo "heal-stale-primary-checkout.sh run: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$PRIMARY_CHECKOUT" ] || [ -z "$DEFAULT_BRANCH" ]; then
      echo "heal-stale-primary-checkout.sh run: --primary and --default-branch are required" >&2
      usage >&2
      exit 64
    fi
    case "$attempt" in ''|*[!0-9]*) echo "heal-stale-primary-checkout.sh run: --attempt must be a non-negative integer" >&2; exit 64 ;; esac
    case "$max_attempts" in ''|*[!0-9]*) echo "heal-stale-primary-checkout.sh run: --max-attempts must be a non-negative integer" >&2; exit 64 ;; esac

    if ! git -C "$PRIMARY_CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
      emit "error" "not a readable git checkout: $PRIMARY_CHECKOUT"
      exit 3
    fi

    HEAD_BEFORE=$(git -C "$PRIMARY_CHECKOUT" rev-parse --short HEAD 2>/dev/null)

    # Best-effort refresh. Step 0.4 already fetched, so a failure here is
    # not fatal: the staleness count below still reads the last-known
    # remote-tracking ref, which is a valid (if conservative) signal.
    if [ "$do_fetch" -eq 1 ]; then
      git -C "$PRIMARY_CHECKOUT" fetch origin "$DEFAULT_BRANCH" --quiet >/dev/null 2>&1 || true
    fi

    BEHIND_BEFORE=$(behind_count)
    if [ -z "$BEHIND_BEFORE" ]; then
      emit "error" "could not compute HEAD..origin/$DEFAULT_BRANCH in $PRIMARY_CHECKOUT (no remote-tracking ref, or unborn HEAD)"
      exit 3
    fi

    if [ "$BEHIND_BEFORE" -eq 0 ]; then
      BEHIND_AFTER="$BEHIND_BEFORE"
      HEAD_AFTER="$HEAD_BEFORE"
      emit "fresh" ""
      exit 0
    fi

    # --- Stale. Decide whether a lossless fast-forward is available. ------

    if [ "$attempt" -ge "$max_attempts" ] && [ "$max_attempts" -gt 0 ]; then
      emit "attempt-refuse" "stale primary checkout: $BEHIND_BEFORE commit(s) behind origin/$DEFAULT_BRANCH after $attempt self-heal attempt(s) (cap $max_attempts) — the checkout is not converging; run 'git -C \"$PRIMARY_CHECKOUT\" pull --ff-only' by hand and re-run /shipyard:do-work"
      exit 1
    fi

    PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")
    if [ "$PRIMARY_BRANCH" != "$DEFAULT_BRANCH" ]; then
      emit "branch-refuse" "stale primary checkout: $BEHIND_BEFORE commit(s) behind origin/$DEFAULT_BRANCH, and the primary is on '$PRIMARY_BRANCH' rather than '$DEFAULT_BRANCH' — NOT moving your HEAD. Switch back and refresh: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH && git -C \"$PRIMARY_CHECKOUT\" pull --ff-only, then re-run /shipyard:do-work"
      exit 1
    fi

    # Tracked modifications only (#1616): `--untracked-files=no` keeps an
    # untracked-only tree healable, since the fast-forward below cannot lose
    # untracked content — git aborts rather than overwrite one.
    if [ -n "$(git -C "$PRIMARY_CHECKOUT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      emit "dirty-refuse" "stale primary checkout: $BEHIND_BEFORE commit(s) behind origin/$DEFAULT_BRANCH, and its working tree has uncommitted changes to tracked files — NOT auto-updating (possible real edits). Commit or set them aside, then run 'git -C \"$PRIMARY_CHECKOUT\" pull --ff-only' and re-run /shipyard:do-work"
      exit 1
    fi

    # No tracked modifications on the default branch — the fast-forward
    # discards nothing (untracked paths survive, or git refuses the merge).
    # `merge --ff-only <remote-tracking ref>` rather than `pull --ff-only`:
    # same effect, no dependency on branch upstream configuration, and no
    # second fetch. The human-facing remedy stays spelled `git pull
    # --ff-only` because that is what a human would type.
    # LC_ALL=C pins git's message language so the untracked-collision
    # match below isn't defeated by a localized host.
    if ! MERGE_ERR=$(LC_ALL=C git -C "$PRIMARY_CHECKOUT" merge --ff-only "origin/$DEFAULT_BRANCH" 2>&1 >/dev/null); then
      if printf '%s' "$MERGE_ERR" | grep -q "untracked working tree files would be overwritten"; then
        emit "heal-failed" "fast-forward of $PRIMARY_BRANCH to origin/$DEFAULT_BRANCH refused by git — an untracked file in the primary would be overwritten by an incoming commit (nothing was changed). Move or delete the colliding untracked path(s) that 'git -C \"$PRIMARY_CHECKOUT\" pull --ff-only' names, then re-run /shipyard:do-work"
        exit 2
      fi
      emit "heal-failed" "fast-forward of $PRIMARY_BRANCH to origin/$DEFAULT_BRANCH failed — the primary likely has local commits not on origin (a fast-forward would not be lossless). Reconcile it by hand (git -C \"$PRIMARY_CHECKOUT\" status; git -C \"$PRIMARY_CHECKOUT\" log --oneline origin/$DEFAULT_BRANCH..HEAD) and re-run /shipyard:do-work"
      exit 2
    fi

    HEAD_AFTER=$(git -C "$PRIMARY_CHECKOUT" rev-parse --short HEAD 2>/dev/null)
    BEHIND_AFTER=$(behind_count)
    if [ -z "$BEHIND_AFTER" ] || [ "$BEHIND_AFTER" -ne 0 ]; then
      emit "heal-failed" "fast-forward reported success but the primary is still ${BEHIND_AFTER:-unknown} commit(s) behind origin/$DEFAULT_BRANCH — refusing to continue on an indeterminate spec version"
      exit 2
    fi

    emit "healed" "fast-forwarded the primary checkout $HEAD_BEFORE -> $HEAD_AFTER ($BEHIND_BEFORE commit(s)); every spec file already read this session is INVALIDATED — re-read the bootstrap files from disk and restart setup from step 0.3"
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "heal-stale-primary-checkout.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
