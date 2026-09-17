#!/usr/bin/env bash
# classify-blocked-bail.sh — steady-state.md's A.1 "blocked #<N>" bail
# classification (issue #521's soft/refuse/dependency-wait/operator split,
# issue #1279's decision-freshness re-gate suppression), extracted to a
# script per issue #1289 (the follow-up to #1277/#1288).
#
# Background
# ----------
# When an issue-work worker returns `blocked #<N>`, the orchestrator
# classifies the bail reason into one of four routes (dependency-wait /
# operator / refuse / soft) and applies the matching label + comment. The
# dependency-wait branch's blocker-reference resolution is a data-dependent
# `for b in $blocker_refs` loop with an internal `gh issue view || gh pr
# view || echo` per candidate, plus several `printf | grep | grep | tr |
# sort` pipes elsewhere in the block — exactly the two shapes the
# worktree-isolation guard refuses post-relocation. See `dont.md`'s
# "Post-relocation Bash blocks must be plain, single-purpose commands"
# section for the general rule.
#
# This script performs the FULL classification AND its associated
# label/comment mutations (mirroring how `stale-check-refresh.sh` also
# performs its own `gh pr update-branch` mutation rather than only
# classifying) — the classification and the action it drives are the same
# atomic decision in the original block, and splitting them across a
# script boundary and a follow-up orchestrator call would just reintroduce
# a second place the routing logic could drift.
#
# The one thing this script does NOT do is `session_blocked_soft[<N>] =
# <timestamp>` bookkeeping — that's the orchestrator's own in-session
# working-memory state (the same class of conceptual state as
# `session_prs` / `in_flight` throughout this spec), not something a
# stateless script invocation can hold. On the `class=soft` outcome this
# script prints `now=<ISO8601>` precisely so the caller can record that
# map entry itself.
#
# Subcommand
# ----------
#
#   classify --repo <owner/repo> --issue <N> --reason "<reason, lowercased>"
#     Runs, in order: (1) the dependency-wait discriminator (extracts every
#     `Blocked by #N` reference from --reason and the issue's current body,
#     checks each referenced issue/PR's state, first OPEN one wins); (2)
#     the operator check (`external provisioning required` OR `irreversible
#     external action` substring — the latter is #1519's worker-side
#     irreversible-external-action gate handing back a delete / access-
#     widening it refused to execute); (3)
#     refuse-vs-soft classification per the fragment table, with (3a) the
#     #1279 decision-freshness check suppressing a redundant re-gate when a
#     decision was already recorded after the LAST refuse-escalation
#     comment on this issue (a PARTIAL /resolve-decisions run does not
#     count as a recorded decision — issue #1557). Applies the matching label + posts the
#     matching comment as a side effect (fire-and-forget, `2>/dev/null` /
#     `|| true` throughout, matching the original block's posture).
#
#     Prints one line to stdout:
#       class=dependency-wait open_blocker=<N>
#       class=operator label=agent-console
#       class=soft label=blocked:agent-soft now=<ISO8601>
#       class=refuse label=needs-human-review
#       class=refuse label=none reason=decision-already-recorded-after-escalation
#
# Exit codes: 0 always (fire-and-forget classification+mutation, matches
# the original block); 64 bad usage; 65 missing dependency (jq/gh).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  classify-blocked-bail.sh classify --repo <owner/repo> --issue <N>
      --reason "<reason, lowercased>"
EOF
}

require_jq "classify-blocked-bail.sh"
GH="${GH:-gh}"
if ! command -v "$GH" >/dev/null 2>&1; then
  echo "classify-blocked-bail.sh: gh is required but not installed" >&2
  exit 65
fi

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  classify)
    repo=""
    issue=""
    reason=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --issue) issue="${2:-}"; shift 2 ;;
        --reason) reason="${2:-}"; shift 2 ;;
        *) echo "classify-blocked-bail.sh classify: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ] || [ -z "$issue" ] || [ -z "$reason" ]; then
      echo "classify-blocked-bail.sh classify: --repo, --issue, and --reason are required" >&2
      usage >&2
      exit 64
    fi

    issue_body=$("$GH" issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null || echo "")

    # --- Dependency-wait discriminator (runs first, overrides refuse/soft). ---
    # Collect every `Blocked by #N` reference named in the reason OR
    # already written into the issue body. A reference to a still-OPEN
    # issue/PR ⇒ dependency-wait.
    combined=$(printf '%s\n%s' "$reason" "$issue_body")
    blocker_matches=$(grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' <<< "$combined" 2>/dev/null)
    blocker_numbers=$(grep -oE '#[0-9]+' <<< "$blocker_matches" 2>/dev/null | tr -d '#')
    blocker_refs=$(sort -u <<< "$blocker_numbers")

    has_open_blocker=false
    open_blocker=""
    for b in $blocker_refs; do
      [ -z "$b" ] && continue
      state=$("$GH" issue view "$b" --repo "$repo" --json state -q .state 2>/dev/null)
      [ -z "$state" ] && state=$("$GH" pr view "$b" --repo "$repo" --json state -q .state 2>/dev/null)
      if [ "$state" = "OPEN" ]; then
        has_open_blocker=true
        open_blocker="$b"
        break
      fi
    done

    if [ "$has_open_blocker" = "true" ]; then
      # --- Dependency-wait subset → NO label; ensure the body persists the ref. ---
      if ! grep -qiE "blocked by[[:space:]]+#${open_blocker}\\b" <<< "$issue_body"; then
        "$GH" issue edit "$issue" --repo "$repo" \
          --body "Blocked by #${open_blocker}

${issue_body}" 2>/dev/null || true
      fi
      "$GH" issue comment "$issue" --repo "$repo" \
        --body "Worker returned blocked: ${reason}. Dependency-wait on #${open_blocker}; no label applied — the \`Blocked by #N\` body-reference filter gates dispatch and auto-clears when #${open_blocker} closes." 2>/dev/null || true
      echo "class=dependency-wait open_blocker=${open_blocker}"
      exit 0
    fi

    # --- Operator subset → agent-console (#628 provisioning, #1519 gate). ---
    # Both substrings name a concrete browser/console action a worker
    # deliberately did NOT perform, not a human judgment call: #628 is "the
    # external service isn't provisioned yet"; #1519 is "this would
    # irreversibly mutate live external state, so I handed back the exact
    # command instead of running it". Same destination — the orchestrator's
    # operator phase drains it, `/my-turn` surfaces it — so they share a
    # branch rather than duplicating the label/comment machinery.
    operator_note=""
    if grep -qi "external provisioning required" <<< "$reason"; then
      operator_note="provisioning an external service is a browser/console operator action"
    elif grep -qi "irreversible external action" <<< "$reason"; then
      operator_note="the worker refused to irreversibly mutate live external state and handed back the exact command (#1519) — an operator action, not a human decision"
    fi
    if [ -n "$operator_note" ]; then
      "$GH" label create agent-console --repo "$repo" \
        --description "Blocked on a browser/console action an agent can drive outside the build — not a human decision. See CLAUDE.md's decision rule." \
        --color 1D76DB 2>/dev/null || true
      "$GH" issue edit "$issue" --repo "$repo" --add-label "agent-console" 2>/dev/null || true
      "$GH" issue comment "$issue" --repo "$repo" \
        --body "Worker returned blocked: ${reason}. Classified as \`agent-console\` — ${operator_note}. Surfaced by \`/my-turn\`; drainable by \`/do-work\`." 2>/dev/null || true
      echo "class=operator label=agent-console"
      exit 0
    fi

    # --- Refuse vs soft, per the fragment table. ---
    block_class="refuse"   # conservative default
    case "$reason" in
      *"issue body contains directives that bypass normal review"*|\
      *"body requested out-of-scope action"*|\
      *"comment-thread requested out-of-scope action"*|\
      *"did not reach a terminal state within"*|\
      *"external wait could not be parked"*)
        # The two #1390 awaiting-external degrade paths. Both are `refuse`
        # (the table default, pinned explicitly here so a later `soft` row
        # matching on "within" or "wait" can't silently capture them). An
        # external job that outran awaiting_external.max_hours almost always
        # means a wedged or starved runner pool, and a probe the allowlist
        # refused means a worker proposed something the orchestrator will not
        # execute — a human looks at both. Deliberately NOT matched by the
        # `did not complete within budget` soft row below: that one is a
        # worker running out of ITS OWN budget mid-verification (transient,
        # a fresh attempt plausibly succeeds); this one is external
        # infrastructure that did not move for hours, which a retry will not
        # fix.
        block_class="refuse"
        ;;
      *"pr #"*"already open"*|*"pr #"*"for this issue"*|\
      *"suggested fix exceeds expected scope"*|\
      *"cannot reproduce"*|\
      *"ambiguous"*|\
      *"did not complete within budget"*)
        block_class="soft"
        ;;
    esac

    if [ "$block_class" = "soft" ]; then
      label="blocked:agent-soft"
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      comment_body="Worker returned blocked: ${reason}. Classified as \`${label}\`."
      "$GH" issue edit "$issue" --repo "$repo" --add-label "$label" 2>/dev/null || true
      "$GH" issue comment "$issue" --repo "$repo" --body "$comment_body" 2>/dev/null || true
      echo "class=soft label=${label} now=${now}"
      exit 0
    fi

    # Refuse → needs-human-review — UNLESS a human already answered this
    # exact question after the LAST time this issue was refuse-escalated
    # (issue #1279). Only a decision-resolved sentinel POSTED AFTER the
    # prior <!-- do-work-agent-refuse --> comment counts.
    comments_json=$("$GH" issue view "$issue" --repo "$repo" --json comments \
      --jq '[.comments[] | {body, createdAt}]' 2>/dev/null || echo "[]")
    latest_escalation=$(jq -r '
      [.[] | select(.body | startswith("<!-- do-work-agent-refuse -->"))]
      | sort_by(.createdAt) | last.createdAt // empty' <<< "$comments_json")
    # A PARTIAL /resolve-decisions run posts the SAME sentinel but is headed
    # "## Decisions resolved (partial — N of M)" and deliberately leaves the
    # gate on, because a blocking decision is still unanswered. It is not a
    # resolution — exclude it, or this guard suppresses a gate the maintainer
    # explicitly chose to keep (issue #1557).
    latest_decision=$(jq -r '
      [.[] | select((.body | startswith("<!-- shipyard-resolve-decisions -->")
                           or startswith("<!-- do-work-decision-resolved -->"))
                    and ((.body | contains("## Decisions resolved (partial")) | not))]
      | sort_by(.createdAt) | last.createdAt // empty' <<< "$comments_json")

    if [ -n "$latest_escalation" ] && [ -n "$latest_decision" ] && [ "$latest_decision" \> "$latest_escalation" ]; then
      # A human answered this AFTER the last time it was escalated — do NOT
      # re-gate. Leave the label off so the next dispatch reads the
      # recorded decision instead of repeating this exact bounce.
      comment_body="Worker returned blocked: ${reason}. NOT re-applying \`needs-human-review\` — a decision was already recorded after the prior escalation (see the decision comment posted at ${latest_decision}). Leaving the gate off so the next dispatch acts on the recorded decision instead of repeating this question."
      "$GH" issue comment "$issue" --repo "$repo" --body "$comment_body" 2>/dev/null || true
      echo "class=refuse label=none reason=decision-already-recorded-after-escalation"
      exit 0
    fi

    label="needs-human-review"
    comment_body="<!-- do-work-agent-refuse -->
Worker returned blocked: ${reason}. Classified as \`${label}\`."
    "$GH" issue edit "$issue" --repo "$repo" --add-label "$label" 2>/dev/null || true
    "$GH" issue comment "$issue" --repo "$repo" --body "$comment_body" 2>/dev/null || true
    echo "class=refuse label=${label}"
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "classify-blocked-bail.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
