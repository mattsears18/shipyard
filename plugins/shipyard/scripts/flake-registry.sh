#!/usr/bin/env bash
# flake-registry.sh — cross-PR / cross-session flake ledger at $SHIPYARD_HOME/.
#
# Background (issue #378): the `fix-checks-only` worker handles flaky CI
# per-PR. When a check looks like a transient flake, the worker's fix-loop
# either pushes a flake-mitigation commit (which re-triggers CI naturally)
# or — historically — the failure resolved on its own. Each PR's worker is
# independent: none of them sees that the SAME test has flaked on N other
# PRs this week. Chronic flakes go uninvestigated, and the user's repo-level
# CI rule ("Flaky CI is a real failure — fix the root cause") gets silently
# violated because every flake event is treated in isolation.
#
# This helper is the session-spanning record that surfaces the chronic
# pattern. Each `fix-checks-only` worker that concludes a failure was a
# flake records one event line; a setup/dispatch-time reader computes
# per-test flake rates over a configurable window and reports which tests
# have crossed the escalation threshold.
#
# SCOPE (phase 1, issue #378). This helper ships the data layer:
#   - the JSONL append path (`record`),
#   - the windowed read + per-(workflow,job,test) aggregation (`report`),
#   - the threshold evaluation that names which tests have crossed the
#     escalation bar (`crossed`),
#   - housekeeping (`read`, `prune`, `reset`).
# The *enforcement* of the three threshold ACTIONS — file-tracking-issue,
# stop-auto-rerunning, apply-blocked-ci — is deliberately deferred to a
# follow-up phase (see the issue's phase plan). `crossed` returns the
# escalation candidates and the configured action set so the orchestrator
# can act on them once the enforcement phase lands; this helper does not
# itself file issues, write flake-suspects files, or label PRs.
#
# Storage layout:
#
#   $SHIPYARD_HOME/                       (default: ~/.shipyard/)
#     flake-registry.jsonl                # append-only; one line per flake event
#
# One event line (issue #378's proposed shape, with the optional `test`
# field — a flake the worker couldn't attribute to a specific test ID still
# records a line keyed on workflow+job):
#
#   {"at":"2026-05-29T12:23:00Z","repo":"mattsears18/lightwork","pr":1377,
#    "workflow":"CI","job":"🎭 Web E2E Tests (shard 2/3)","test":"AUTH-CORE-19",
#    "action":"rerun-failed","session":"<session-id>"}
#
# Append-only JSONL is intentional (same rationale as cost-history.sh):
#   - Safe under concurrent writes from parallel `/do-work` orchestrators —
#     each `record` writes its line in one `>>` redirect; the kernel
#     guarantees atomicity for writes <= PIPE_BUF (4 KiB on Linux), which
#     every event line fits comfortably under. No locks, no read-modify-write.
#   - Easy to grep/jq from the shell.
#   - Cheap rotation: `prune` rewrites without the stale lines; `reset`
#     moves the file aside.
#
# Privacy (same posture as cost-history.sh / cost.md's privacy notice):
#
#   flake-registry.jsonl lives entirely on the local filesystem at
#   $SHIPYARD_HOME/ (default ~/.shipyard/) — it is NEVER uploaded anywhere
#   by shipyard. The only outbound writes shipyard makes are to GitHub via
#   `gh`; the registry is not part of any of those flows. The data recorded
#   (repo, pr, workflow, job, test id, session id, timestamp) is not PII,
#   but on a private repo it accumulates a cross-session record of your CI
#   test names and PR numbers, so it stays local by design.
#
#   To opt OUT of collection entirely, set `flake_registry.enabled: false`
#   (the default) — when disabled, the fix-checks-only worker records no
#   events and nothing is written to flake-registry.jsonl. The file is safe
#   to `rm`; `reset` moves it to .bak.<ts> (recoverable, not rm'd) so a
#   manual archival rotation is just a `mv` away. Deleting it only forfeits
#   the historical flake-rate window.
#
# Subcommands:
#
#   record --repo <owner/repo> --pr <N> --workflow <name> --job <name>
#          [--test <id>] [--action <label>] [--session <id>] [--at <iso8601>]
#          [--dry-run]
#     Append one flake event to flake-registry.jsonl. `--test` is optional
#     (a flake the worker couldn't pin to a test ID still records, keyed on
#     workflow+job). `--action` defaults to "rerun-failed" (the historical
#     event shape). `--at` defaults to now (UTC, second precision). `--session`
#     is optional provenance. --dry-run emits the line to stdout instead of
#     appending.
#
#   report [--repo <owner/repo>] [--window-days N] [--format json|table]
#     Read flake-registry.jsonl and aggregate events into per-flake rows
#     keyed on (repo, workflow, job, test). Each row carries the event count,
#     the count of distinct PRs, the first/last event timestamps, and the PR
#     list. --window-days N (default 7) restricts to events within the last
#     N days. --repo filters to one repo. --format json (default) emits a
#     JSON array; table emits a human-readable summary.
#
#   crossed [--repo <owner/repo>] [--window-days N] [--rerun-threshold N]
#           [--distinct-prs-threshold N] [--actions <csv>] [--format json|table]
#     Like `report`, but emits only the flake rows that have CROSSED the
#     escalation threshold: event count >= rerun-threshold AND distinct-PR
#     count >= distinct-prs-threshold within the window. Defaults mirror
#     shipyard.config.json::flake_registry (window 7, rerun 3, distinct PRs
#     2). --actions echoes the configured action set onto each row so the
#     orchestrator's (future) enforcement phase knows what to do; it does
#     not itself perform any action. Defaults to the three issue-#378
#     actions. Exit 0 with an empty array when nothing has crossed.
#
#   read
#     Emit the raw jsonl on stdout. Exit 3 if the file is missing.
#
#   prune [--window-days N] [--dry-run]
#     Rewrite flake-registry.jsonl keeping only events within the last N
#     days (default 90 — generous; the registry is cheap to keep). Use to
#     stop unbounded growth. --dry-run prints what would remain.
#
#   reset [--yes]
#     Move flake-registry.jsonl to .bak.<ts> (recoverable, not rm'd).
#     Prompts on stdin unless --yes is passed.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory. Defaults to $HOME/.shipyard. Same env
#                   var used by session-state.sh, cost-history.sh, and
#                   shipyard-config.sh; relocating it relocates all of them.
#
# Exit codes:
#
#   0   — success (including "nothing crossed" — exit 0 with an empty array)
#   3   — read of a missing registry file
#   64  — usage error (bad subcommand or missing required argument)
#   65+ — internal helper failure (jq missing, write failure, etc.)
#   70  — reset aborted by user

set -u

# --------------------------------------------------------------------------
# Dependency check — jq is required for record projection and aggregation.
# Same posture as session-state.sh / cost-history.sh / shipyard-config.sh.
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "flake-registry.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  flake-registry.sh record  --repo <owner/repo> --pr <N> --workflow <name>
                            --job <name> [--test <id>] [--action <label>]
                            [--session <id>] [--at <iso8601>] [--dry-run]
  flake-registry.sh report  [--repo <owner/repo>] [--window-days N]
                            [--format json|table]
  flake-registry.sh crossed [--repo <owner/repo>] [--window-days N]
                            [--rerun-threshold N] [--distinct-prs-threshold N]
                            [--actions <csv>] [--format json|table]
  flake-registry.sh read
  flake-registry.sh prune   [--window-days N] [--dry-run]
  flake-registry.sh reset   [--yes]

Environment:
  SHIPYARD_HOME  base dir for the registry (default: $HOME/.shipyard)

Exit codes:
  0    success (incl. "nothing crossed" — empty array)
  3    read of a missing registry file
  64   usage error
  65+  internal helper failure
  70   reset aborted by user
EOF
}

# --------------------------------------------------------------------------
# Path resolution — mirrors cost-history.sh.
# --------------------------------------------------------------------------
shipyard_home() {
  printf '%s\n' "${SHIPYARD_HOME:-${HOME}/.shipyard}"
}

registry_path() {
  printf '%s/flake-registry.jsonl\n' "$(shipyard_home)"
}

now_iso() {
  # UTC, second precision. `-u` for UTC; the `%Y-%m-%dT%H:%M:%SZ` format is
  # the same shape session records use, so timestamps sort lexically.
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Cutoff timestamp N days before now (UTC, ISO8601). GNU and BSD date take
# different relative-date flags; try GNU first, fall back to BSD.
cutoff_iso() {
  local days="$1"
  date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# --------------------------------------------------------------------------
# Aggregation core — shared by report and crossed.
#
# Reads the registry, optionally filters by repo + window, and groups events
# by (repo, workflow, job, test) into rows. The `test` key is normalized to
# the empty string when absent so workflow+job-only flakes group cleanly.
# --------------------------------------------------------------------------
aggregate() {
  local repo_filter="$1"   # "" => all repos
  local cutoff="$2"        # "" => no window filter

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    printf '[]\n'
    return 0
  fi

  # Read each JSONL line and parse defensively — `fromjson? // empty` drops
  # any corrupt line so one bad write doesn't sink the whole aggregation.
  # Then slurp the parsed objects into an array and group.
  jq -R 'fromjson? // empty' "$path" | jq -s \
    --arg repo "$repo_filter" \
    --arg cutoff "$cutoff" '
    map(
      select($repo == "" or .repo == $repo)
      | select($cutoff == "" or (.at // "") >= $cutoff)
      | . + {test: (.test // "")}
    )
    | group_by([.repo, .workflow, .job, .test])
    | map({
        repo:     .[0].repo,
        workflow: .[0].workflow,
        job:      .[0].job,
        test:     .[0].test,
        events:   length,
        distinct_prs: ([.[].pr] | unique | length),
        prs:      ([.[].pr] | unique | sort),
        first_at: ([.[].at] | min),
        last_at:  ([.[].at] | max)
      })
    | sort_by(-.events, -.distinct_prs)
  '
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------
cmd_record() {
  local repo="" pr="" workflow="" job="" test="" action="rerun-failed"
  local session="" at="" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)     repo="${2:-}"; shift 2 ;;
      --pr)       pr="${2:-}"; shift 2 ;;
      --workflow) workflow="${2:-}"; shift 2 ;;
      --job)      job="${2:-}"; shift 2 ;;
      --test)     test="${2:-}"; shift 2 ;;
      --action)   action="${2:-}"; shift 2 ;;
      --session)  session="${2:-}"; shift 2 ;;
      --at)       at="${2:-}"; shift 2 ;;
      --dry-run)  dry_run=1; shift ;;
      *) echo "record: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$repo" || -z "$pr" || -z "$workflow" || -z "$job" ]]; then
    echo "record: --repo, --pr, --workflow, --job are required" >&2
    usage
    exit 64
  fi
  if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
    echo "record: --pr must be a positive integer (got: $pr)" >&2
    exit 64
  fi
  if [[ -z "$at" ]]; then
    at=$(now_iso)
  fi

  # Build the line. `--argjson pr` so the PR number lands as a JSON number,
  # not a string. Optional fields (test, session) are omitted when empty so
  # the on-disk shape stays clean; the aggregator normalizes test back to ""
  # at read time.
  local line
  line=$(jq -c -n \
    --arg at "$at" \
    --arg repo "$repo" \
    --argjson pr "$pr" \
    --arg workflow "$workflow" \
    --arg job "$job" \
    --arg test "$test" \
    --arg action "$action" \
    --arg session "$session" '
    {at: $at, repo: $repo, pr: $pr, workflow: $workflow, job: $job, action: $action}
    | (if $test    != "" then . + {test: $test}       else . end)
    | (if $session != "" then . + {session: $session}  else . end)
  ') || { echo "record: failed to build event line" >&2; exit 65; }

  if [[ $dry_run -eq 1 ]]; then
    printf '%s\n' "$line"
    return 0
  fi

  local path
  path=$(registry_path)
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$line" >> "$path" || {
    echo "record: failed to append to $path" >&2
    exit 66
  }
}

cmd_report() {
  local repo="" window_days=7 format="json"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)        repo="${2:-}"; shift 2 ;;
      --window-days) window_days="${2:-}"; shift 2 ;;
      --format)      format="${2:-}"; shift 2 ;;
      *) echo "report: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  if ! [[ "$window_days" =~ ^[0-9]+$ ]]; then
    echo "report: --window-days must be a non-negative integer" >&2
    exit 64
  fi

  local cutoff=""
  if [[ "$window_days" -gt 0 ]]; then
    cutoff=$(cutoff_iso "$window_days")
  fi

  local rows
  rows=$(aggregate "$repo" "$cutoff") || exit $?

  if [[ "$format" == "table" ]]; then
    printf '%s\n' "$rows" | jq -r '
      if length == 0 then "no flake events in window"
      else (
        ["EVENTS", "PRS", "WORKFLOW / JOB / TEST", "LAST"],
        (.[] | [
          (.events | tostring),
          (.distinct_prs | tostring),
          (.workflow + " / " + .job + (if .test != "" then " / " + .test else "" end)),
          .last_at
        ])
      ) | @tsv end'
  else
    printf '%s\n' "$rows"
  fi
}

cmd_crossed() {
  local repo="" window_days=7 rerun_threshold=3 distinct_prs_threshold=2
  local actions="file-tracking-issue,stop-auto-rerunning,apply-blocked-ci"
  local format="json"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)                   repo="${2:-}"; shift 2 ;;
      --window-days)            window_days="${2:-}"; shift 2 ;;
      --rerun-threshold)        rerun_threshold="${2:-}"; shift 2 ;;
      --distinct-prs-threshold) distinct_prs_threshold="${2:-}"; shift 2 ;;
      --actions)                actions="${2:-}"; shift 2 ;;
      --format)                 format="${2:-}"; shift 2 ;;
      *) echo "crossed: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  for n in "$window_days" "$rerun_threshold" "$distinct_prs_threshold"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "crossed: --window-days / --rerun-threshold / --distinct-prs-threshold must be non-negative integers" >&2
      exit 64
    fi
  done

  local cutoff=""
  if [[ "$window_days" -gt 0 ]]; then
    cutoff=$(cutoff_iso "$window_days")
  fi

  local rows
  rows=$(aggregate "$repo" "$cutoff") || exit $?

  # actions csv -> json array, trimming whitespace and dropping empties.
  local actions_json
  actions_json=$(printf '%s' "$actions" | jq -R '
    split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')

  local crossed
  crossed=$(printf '%s\n' "$rows" | jq \
    --argjson rt "$rerun_threshold" \
    --argjson dt "$distinct_prs_threshold" \
    --argjson actions "$actions_json" '
    map(select(.events >= $rt and .distinct_prs >= $dt) | . + {actions: $actions})
  ')

  if [[ "$format" == "table" ]]; then
    printf '%s\n' "$crossed" | jq -r '
      if length == 0 then "no flakes crossed the escalation threshold"
      else (
        ["EVENTS", "PRS", "WORKFLOW / JOB / TEST", "ACTIONS"],
        (.[] | [
          (.events | tostring),
          (.distinct_prs | tostring),
          (.workflow + " / " + .job + (if .test != "" then " / " + .test else "" end)),
          (.actions | join(","))
        ])
      ) | @tsv end'
  else
    printf '%s\n' "$crossed"
  fi
}

cmd_read() {
  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    echo "read: registry not found at $path" >&2
    exit 3
  fi
  cat "$path"
}

cmd_prune() {
  local window_days=90 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --window-days) window_days="${2:-}"; shift 2 ;;
      --dry-run)     dry_run=1; shift ;;
      *) echo "prune: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  if ! [[ "$window_days" =~ ^[0-9]+$ ]]; then
    echo "prune: --window-days must be a non-negative integer" >&2
    exit 64
  fi

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    # Nothing to prune.
    return 0
  fi

  local cutoff=""
  if [[ "$window_days" -gt 0 ]]; then
    cutoff=$(cutoff_iso "$window_days")
  fi

  local kept
  kept=$(jq -R 'fromjson? // empty' "$path" | jq -c \
    --arg cutoff "$cutoff" '
    select($cutoff == "" or (.at // "") >= $cutoff)')

  if [[ $dry_run -eq 1 ]]; then
    printf '%s\n' "$kept"
    return 0
  fi

  # Atomic rewrite: write to a sibling tmp then rename.
  local tmp="${path}.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if [[ -n "$kept" ]]; then
    printf '%s\n' "$kept" > "$tmp"
  else
    : > "$tmp"
  fi
  mv -f "$tmp" "$path" || { echo "prune: failed to rewrite $path" >&2; exit 67; }
  trap - EXIT
}

cmd_reset() {
  local yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) echo "reset: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    # Nothing to reset.
    return 0
  fi

  if [[ $yes -eq 0 ]]; then
    printf 'Move %s aside to a .bak file? [y/N] ' "$path" >&2
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "reset: aborted" >&2
      exit 70
    fi
  fi

  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local bak="${path}.bak.${ts}"
  mv -f "$path" "$bak" || { echo "reset: failed to move $path" >&2; exit 67; }
  echo "reset: moved $path -> $bak" >&2
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
  record)  cmd_record "$@" ;;
  report)  cmd_report "$@" ;;
  crossed) cmd_crossed "$@" ;;
  read)    cmd_read "$@" ;;
  prune)   cmd_prune "$@" ;;
  reset)   cmd_reset "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "flake-registry.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
