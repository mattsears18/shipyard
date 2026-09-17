#!/usr/bin/env bash
# classify-backlog.sh — turns setup/04-backlog-divert.md step 4's classify
# block into a single plain command (issue #1398).
#
# Background
# ----------
# Step 4's "Invocation" section builds five config-read variables plus two
# live-network precomputed sets (and, conditionally, a third), then feeds
# all of them into `backlog-filter.sh classify` in what the spec explicitly
# calls out as needing to be **one** `Bash` call — the intermediate shell
# variables (`$ME_LOGIN`, `$CLOSED_HEALTHY_CSV`, `$COVERED_BY_OPEN_PR_JSON`,
# `$PROBE_VERDICTS_JSON`, the five config reads) don't survive between
# separate Bash tool calls, so decomposing into multiple plain commands
# loses them entirely (see `dont.md`'s post-relocation compound-block rule,
# #1277). But pasting the block as written is refused verbatim by the
# worktree-isolation guard: "this command is too complex to verify that it
# stays inside the worktree." Every orchestrator session hits this and
# improvises its own workaround — the exact cost #1277 was filed to
# eliminate one layer down, recurring here because no script existed yet
# to absorb the block.
#
# This is that script — mirroring the `stale-check-refresh.sh` /
# `next-available-version.sh` / `pre-dispatch-branch-reap.sh` /
# `concurrent-session-guard.sh` extraction precedent (#1289): the whole
# input-gathering + classify sequence becomes ONE plain command
# (`bash classify-backlog.sh run ...`), so the guard sees a single,
# unproblematic invocation instead of a multi-statement block.
#
# This script does no classification logic of its own — it is a thin
# orchestration layer that resolves the five config reads and the two (or
# three) live-network precomputed sets, then delegates the actual
# eligibility decision to `backlog-filter.sh classify`, the single
# normative implementation (#1247). Keeping the decision logic in exactly
# one place (not reimplemented here) is the same discipline
# `backlog-filter.sh`'s own header documents for why IT exists.
#
# Subcommand
# ----------
#
#   run --repo <owner/repo> --me <login> --trusted-authors <csv>
#       --issues-file <path> [--peer-claimed <csv>]
#       [--prioritize-label <label>] [--out <path>]
#     Reads the wide-fetch issue JSON array from --issues-file (the exact
#     payload setup.md step 4's wide fetch produces — see
#     `backlog-filter.sh classify`'s own header for the shape, and that
#     step's literal `gh issue list` command for the projection that
#     produces it). Internally:
#       - validates --issues-file against that shape FIRST, via
#         `backlog-filter.sh validate-issues`, before spending any of the
#         live-network calls below — a mis-marshalled payload exits 64 with
#         the offending field, its issue number, and the fix named, rather
#         than as the raw positional jq error #1555 reports;
#       - resolves `triage.investigate_dispatch` (fallback true — this key
#         has no built-in default, so a repo with no config always takes
#         the fallback), `backlog.respect_assignees` (default false),
#         `milestones.enabled` (default false), `milestones.
#         prioritize_dispatch` (fallback false on error; the built-in
#         config default is actually true, but stays inert unless
#         `milestones.enabled` is also true), `scope.
#         recheck_probe_enabled` (default true), `backlog.
#         someday_milestone` (default "" — off; issue #1406, deliberately
#         NOT gated on `milestones.enabled`, since the whole point is to
#         work on a repo that has not opted into milestone-ranked dispatch
#         at all), and `backlog.someday_recheck_days` (built-in default 30
#         — issue #1422, the slow re-scope cadence for a someday_milestone
#         park; inert whenever someday_milestone is ""), and
#         `milestones.fallback` (schema default "Ongoing maintenance" —
#         issue #1499, the title an unmilestoned issue ranks TIED WITH
#         instead of strictly behind; read unconditionally but inert
#         unless the two milestone-ranking knobs above are both true, and
#         resolved to "" on any error so the tie clause simply never
#         fires) via
#         `shipyard-config.sh get` (each read falls back to its documented
#         value on any error, matching the `|| echo "<default>"` posture
#         the original inline block had for every config read);
#       - runs `backlog-filter.sh closed-by-healthy-pr` and
#         `closed-by-open-pr` against --repo/--me (the latter falls back to
#         `{}` on any failure — the clause never fires rather than aborting
#         the whole classify);
#       - when `scope.recheck_probe_enabled` resolves true, runs
#         `backlog-filter.sh eval-probes` against --issues-file (falls back
#         to `{}` on any failure, same posture);
#       - unconditionally runs `backlog-filter.sh eval-pr-collision` against
#         --issues-file (issue #1429) — no kill-switch gate, since the
#         underlying probe is a fixed `gh pr view --json state` call, not
#         the arbitrary allowlisted-verb grammar `eval-probes` guards
#         (falls back to `{}` on any failure, same posture);
#       - unconditionally runs `backlog-filter.sh sub-issues` against
#         --issues-file (issue #1556) — the `tracking` provisional gate's
#         structured justification signal. Makes no network call at all
#         unless the backlog actually carries a `tracking`-labeled issue
#         (falls back to `{}` on any failure, same posture — an
#         inconclusive read can only surface the gate as
#         `tracking-unjustified`, never fabricate a justification);
#       - feeds every resolved input into `backlog-filter.sh classify`,
#         reading --issues-file as stdin;
#       - pipes the resulting NDJSON into `backlog-filter.sh
#         someday-recheck-write` (issue #1422), which writes/refreshes the
#         `do-work-someday-recheck` body marker for any `first-park`/
#         `cheap-reset` line — best-effort (`|| true`), never fails the
#         whole `run` call. A no-op whenever `someday_recheck_days` is `0`
#         or no line carries `someday_recheck_action` (the common case).
#     Writes the classify NDJSON to --out (default: stdout). Same NDJSON
#     shape as `backlog-filter.sh classify` — see that script's header for
#     the full per-line verdict contract. `raw_backlog` /
#     `investigate_candidates` extraction stays the caller's job (a plain
#     `jq -r 'select(...)' <ndjson-file>` positional-argument call, which
#     was never the refused shape — only the classify invocation itself
#     was).
#     Exit codes: 0 success; 64 bad usage OR --issues-file failing the
#     wide-fetch shape check; 65 missing dependency (jq/gh); 66
#     --issues-file not found/unreadable.
#
# Exit codes: 0 success; 64 bad usage (including a mis-marshalled
# --issues-file, issue #1555); 65 missing dependency (jq/gh); 66
# --issues-file not found/unreadable.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  classify-backlog.sh run --repo <owner/repo> --me <login>
      --trusted-authors <csv> --issues-file <path>
      [--peer-claimed <csv-of-numbers>] [--prioritize-label <label>]
      [--out <path>]
EOF
}

require_jq "classify-backlog.sh"
# GH is overridable (mirrors stale-check-refresh.sh's / next-available-
# version.sh's own GH="${GH:-gh}" convention) so the test suite can inject
# a mock gh binary and run with zero network access. classify-backlog.sh
# never calls gh directly itself — it's exported so the delegated
# backlog-filter.sh subcommand invocations below pick it up.
GH="${GH:-gh}"
export GH
if ! command -v "$GH" >/dev/null 2>&1; then
  echo "classify-backlog.sh: gh is required but not installed" >&2
  exit 65
fi

BACKLOG_FILTER="${here}/backlog-filter.sh"
SHIPYARD_CONFIG="${here}/shipyard-config.sh"

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  run)
    repo=""
    me=""
    trusted_authors=""
    issues_file=""
    peer_claimed=""
    prioritize_label=""
    out=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --me) me="${2:-}"; shift 2 ;;
        --trusted-authors) trusted_authors="${2:-}"; shift 2 ;;
        --issues-file) issues_file="${2:-}"; shift 2 ;;
        --peer-claimed) peer_claimed="${2:-}"; shift 2 ;;
        --prioritize-label) prioritize_label="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        *) echo "classify-backlog.sh run: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ] || [ -z "$me" ] || [ -z "$trusted_authors" ] || [ -z "$issues_file" ]; then
      echo "classify-backlog.sh run: --repo, --me, --trusted-authors, and --issues-file are required" >&2
      usage >&2
      exit 64
    fi

    if [ ! -f "$issues_file" ] || [ ! -r "$issues_file" ]; then
      echo "classify-backlog.sh run: --issues-file not found or unreadable: $issues_file" >&2
      exit 66
    fi

    # --- Input-shape check, BEFORE any live-network call (issue #1555) -------
    # `classify` validates its own stdin too, but by then this script has
    # already spent two-to-three `gh`-backed subcommand invocations gathering
    # inputs for a payload that was never going to classify. Failing here
    # keeps a mechanical marshalling mistake cheap, and surfaces it with the
    # offending field named instead of as a positional jq error.
    if ! "$BACKLOG_FILTER" validate-issues < "$issues_file"; then
      echo "classify-backlog.sh run: --issues-file does not match the wide-fetch shape (see the diagnostics above): $issues_file" >&2
      exit 64
    fi

    # --- Config reads (each falls back to its documented default on any
    # error, matching the original inline block's `|| echo "<default>"`
    # posture) --------------------------------------------------------------
    investigate_dispatch=$("$SHIPYARD_CONFIG" get triage.investigate_dispatch 2>/dev/null || echo "true")
    respect_assignees=$("$SHIPYARD_CONFIG" get backlog.respect_assignees 2>/dev/null || echo "false")
    milestones_enabled=$("$SHIPYARD_CONFIG" get milestones.enabled 2>/dev/null || echo "false")
    milestones_prioritize_dispatch=$("$SHIPYARD_CONFIG" get milestones.prioritize_dispatch 2>/dev/null || echo "false")
    recheck_probe_enabled=$("$SHIPYARD_CONFIG" get scope.recheck_probe_enabled 2>/dev/null || echo "true")
    someday_milestone=$("$SHIPYARD_CONFIG" get backlog.someday_milestone 2>/dev/null || echo "")
    someday_recheck_days=$("$SHIPYARD_CONFIG" get backlog.someday_recheck_days 2>/dev/null || echo "30")
    if ! [[ "$someday_recheck_days" =~ ^[0-9]+$ ]]; then
      someday_recheck_days="30"
    fi
    # milestones.fallback (issue #1499). "" on any error — the tie clause
    # is off by construction rather than guessing a title. Read
    # unconditionally: classify already ignores it whenever milestone
    # ranking is off, so there is no second gate to keep in sync here.
    fallback_milestone=$("$SHIPYARD_CONFIG" get milestones.fallback 2>/dev/null || echo "")

    # --- Live-network precomputed sets --------------------------------------
    closed_healthy_csv=$("$BACKLOG_FILTER" closed-by-healthy-pr --repo "$repo" --me "$me")

    covered_by_open_pr_json=$("$BACKLOG_FILTER" closed-by-open-pr --repo "$repo" --me "$me" 2>/dev/null || echo "{}")

    probe_verdicts_json="{}"
    if [ "$recheck_probe_enabled" = "true" ]; then
      probe_verdicts_json=$("$BACKLOG_FILTER" eval-probes --repo "$repo" < "$issues_file" 2>/dev/null || echo "{}")
    fi

    pr_collision_verdicts_json=$("$BACKLOG_FILTER" eval-pr-collision --repo "$repo" < "$issues_file" 2>/dev/null || echo "{}")

    sub_issues_json=$("$BACKLOG_FILTER" sub-issues --repo "$repo" < "$issues_file" 2>/dev/null || echo "{}")

    # --- Classify ------------------------------------------------------------
    classify_out=$("$BACKLOG_FILTER" classify \
      --me "$me" \
      --trusted-authors "$trusted_authors" \
      --closed-by-healthy-pr "$closed_healthy_csv" \
      --closed-by-open-pr "$covered_by_open_pr_json" \
      --peer-claimed "$peer_claimed" \
      --investigate-dispatch "$investigate_dispatch" \
      --prioritize-label "$prioritize_label" \
      --respect-assignees "$respect_assignees" \
      --milestones-enabled "$milestones_enabled" \
      --milestones-prioritize-dispatch "$milestones_prioritize_dispatch" \
      --recheck-probe-enabled "$recheck_probe_enabled" \
      --probe-verdicts "$probe_verdicts_json" \
      --pr-collision-verdicts "$pr_collision_verdicts_json" \
      --sub-issues "$sub_issues_json" \
      --someday-milestone "$someday_milestone" \
      --someday-recheck-days "$someday_recheck_days" \
      --fallback-milestone "$fallback_milestone" \
      < "$issues_file")
    classify_rc=$?

    if [ "$classify_rc" -ne 0 ]; then
      echo "classify-backlog.sh run: backlog-filter.sh classify exited $classify_rc" >&2
      exit "$classify_rc"
    fi

    # --- Someday-recheck marker write (issue #1422) --------------------------
    # Best-effort side effect: writes/refreshes the do-work-someday-recheck
    # body marker for any first-park/cheap-reset line in $classify_out. Never
    # fails the whole `run` call -- a marker-write failure here just means
    # the same someday-parked issue gets re-evaluated (and the write
    # re-attempted) on the very next classify-backlog.sh invocation.
    printf '%s\n' "$classify_out" | "$BACKLOG_FILTER" someday-recheck-write \
      --repo "$repo" --someday-recheck-days "$someday_recheck_days" 2>&1 | sed 's/^/classify-backlog.sh run: /' >&2 || true

    if [ -n "$out" ]; then
      printf '%s\n' "$classify_out" > "$out"
    else
      printf '%s\n' "$classify_out"
    fi
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "classify-backlog.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
