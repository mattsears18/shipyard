#!/usr/bin/env bash
# cost-history.sh — persistent cross-session cost ledger at $SHIPYARD_HOME/.
#
# Background (issue #163, perf umbrella #152, Phase 0 of #152): per-session
# token data lives in `$SHIPYARD_HOME/sessions/<session-id>.json` (written
# by session-state.sh — issue #153), but the session file is removed by
# the orchestrator's end-of-session cleanup. Without a persistent record
# the user has no way to ask "how much have I spent on shipyard this
# month?", spot trends, or identify chronically expensive issue patterns.
#
# This helper bridges that gap. At end-of-session, the orchestrator calls
# `cost-history.sh flush --session-id <id>`; the helper reads the soon-to-
# be-deleted session file, appends a session record to
# `$SHIPYARD_HOME/cost-history.jsonl`, and upserts one issue record per
# touched issue into `$SHIPYARD_HOME/cost-history-issues.jsonl`. Reports
# read from those two files exclusively — they never touch the per-session
# files.
#
# Storage layout:
#
#   $SHIPYARD_HOME/                                  (default: ~/.shipyard/)
#     cost-history.jsonl          # append-only; one line per session
#     cost-history-issues.jsonl   # append-only; one line per (repo, issue)
#                                 # — re-touches append a fresh line; the
#                                 # reader dedupes by keeping the latest
#                                 # entry per (repo, issue_number).
#
# Append-only JSONL is intentional:
#   - Safe under concurrent writes from parallel `/do-work` orchestrators.
#     Each `flush` writes its line in one `>>` redirect; the kernel
#     guarantees atomicity for writes ≤ PIPE_BUF (4 KiB on Linux), which
#     every record fits comfortably under. No locks, no read-modify-write
#     race.
#   - Easy to grep/jq from the shell without parsing surrounding state.
#   - Cheap rotation: truncating the file is the reset path.
#
# The `--issue` ledger uses append-with-dedupe-at-read instead of in-place
# update so concurrent writers never clobber each other — if session A and
# session B both touch issue #142 at the same time, both append, and the
# reader picks the most recent. Old entries don't bloat reports because
# reports project through `jq` first.
#
# Subcommands:
#
#   flush --session-id <id> [--dry-run]
#     Read $SHIPYARD_HOME/sessions/<id>.json and append:
#       - One session record to cost-history.jsonl
#       - One issue record per touched issue to cost-history-issues.jsonl
#     Idempotent: a session id that already appears in cost-history.jsonl
#     is silently skipped (no duplicate session records). The orchestrator
#     calls this once at end-of-session cleanup, before
#     `session-state.sh cleanup`. Exit 0 if the session file is missing
#     (nothing to flush — equivalent to a session that never ran).
#     --dry-run emits the records to stdout instead of appending.
#
#   report [--last 7d|30d|90d|all] [--repo <owner/repo>] [--by-issue]
#          [--by-mode] [--by-model] [--top N] [--trend]
#          [--format markdown|csv|json]
#     Read cost-history.jsonl + cost-history-issues.jsonl and print a
#     report. Default: --last 30d, --format markdown.
#     --by-issue and --top imply reading cost-history-issues.jsonl;
#     other dimensions read from cost-history.jsonl.
#
#   reset [--yes]
#     Truncate cost-history.jsonl and cost-history-issues.jsonl. Prompts
#     for confirmation on stdin unless --yes is passed (non-interactive
#     use, e.g. test suite). The reset is destructive — there is no
#     undo. Backed-up file paths are echoed to stderr; we move the old
#     files to `.bak.<ts>` rather than `rm` them so an accidental reset
#     can be recovered by hand.
#
#   export --to <path>
#     Copy the two ledger files into a tarball at <path> (which must end
#     in `.tar.gz`). Idempotent re-runs overwrite. The tarball is the
#     portable backup / migration format; restore by extracting back into
#     $SHIPYARD_HOME/ before the next `/do-work` session.
#
#   read [--ledger sessions|issues]
#     Emit the raw jsonl on stdout. `--ledger sessions` (default) reads
#     cost-history.jsonl; `--ledger issues` reads cost-history-issues.jsonl.
#     Used by the test suite and by callers that want to do their own
#     downstream projection.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory. Defaults to $HOME/.shipyard. Same env
#                   var used by session-state.sh and shipyard-config.sh;
#                   relocating it relocates all three.
#
# Exit codes:
#
#   0   — success (including "nothing to flush" — exit 0 with no output)
#   3   — read of a missing ledger file
#   64  — usage error (bad subcommand or missing required argument)
#   65+ — internal helper failure (jq missing, write failure, etc.)
#   70  — reset aborted by user

set -u

# --------------------------------------------------------------------------
# Dependency check — jq is required for record projection and report
# aggregation. Same posture as session-state.sh and shipyard-config.sh.
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "cost-history.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  cost-history.sh flush  --session-id <id> [--dry-run]
  cost-history.sh report [--last 7d|30d|90d|all] [--repo <owner/repo>]
                         [--by-issue] [--by-mode] [--by-model] [--top N]
                         [--trend] [--show-setup] [--format markdown|csv|json]
  cost-history.sh reset  [--yes]
  cost-history.sh export --to <path>.tar.gz
  cost-history.sh read   [--ledger sessions|issues]

Environment:
  SHIPYARD_HOME  base dir for ledger files (default: $HOME/.shipyard)

Exit codes:
  0    success
  3    ledger file missing (read)
  64   usage error
  65+  internal helper failure
  70   reset aborted by user
EOF
}

# --------------------------------------------------------------------------
# Path resolution
# --------------------------------------------------------------------------
shipyard_home() {
  printf '%s\n' "${SHIPYARD_HOME:-${HOME}/.shipyard}"
}

session_ledger_path() {
  printf '%s/cost-history.jsonl\n' "$(shipyard_home)"
}

issue_ledger_path() {
  printf '%s/cost-history-issues.jsonl\n' "$(shipyard_home)"
}

session_file_path() {
  local session_id="$1"
  printf '%s/sessions/%s.json\n' "$(shipyard_home)" "$session_id"
}

# Atomic append: write the line to a tmp file, then concatenate. For
# `>>` the kernel guarantees write atomicity up to PIPE_BUF (≥ 4 KiB on
# every modern OS we care about) and every session/issue record is well
# under that. We still funnel through `printf | tee -a` so concurrent
# writers from parallel orchestrators don't see partial lines.
append_jsonl() {
  local target="$1"
  local line="$2"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  # `printf '%s\n'` ensures exactly one trailing newline regardless of
  # whether $line already had one. Newline-after-line is the .jsonl
  # contract; without it the next append would extend the previous record.
  printf '%s\n' "$line" >> "$target"
}

# --------------------------------------------------------------------------
# flush — read the soon-to-be-deleted session file, project two record
# shapes (session-level, per-issue), and append.
# --------------------------------------------------------------------------
# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables (`$session`, `$now`, etc.) bound via the `--arg`
# / `--argjson` flags. The single-quoted form is the correct, safe shape
# — shell expansion would corrupt the jq program. The disable is scoped
# to this function only.
cmd_flush() {
  local session_id=""
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "flush: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "flush: --session-id is required" >&2
    usage
    exit 64
  fi

  local source
  source=$(session_file_path "$session_id")

  # Missing session file is not an error — the orchestrator might call
  # flush for a session that was never initialised (e.g. immediate exit
  # before step 1.5). Exit 0 with no output so the cleanup chain isn't
  # broken.
  if [[ ! -f "$source" ]]; then
    return 0
  fi

  # 0-byte file guard (issue #357). A session file that exists but is empty
  # is a known corruption mode: prior shipyard versions could silently
  # truncate the session JSON when an `update`'s jq pipeline failed
  # mid-write (root cause now fixed in session-state.sh's atomic_write,
  # but existing corrupted files on disk and external truncation modes
  # remain). Without this guard, jq's projection below would produce
  # `null` for every field and the ledger would gain a zero-cost stub
  # line: misleading for `/shipyard:cost report` (looks like a real
  # zero-cost session) and indistinguishable from a session that ran
  # without bumping any tokens. Detect explicitly, log a clear message
  # so the operator can correlate with the truncation event, and exit 0
  # without writing the stub. Cost data is unrecoverable for this
  # session — better to surface the loss than fabricate $0.
  if [[ ! -s "$source" ]]; then
    echo "[cost-tracking] session file 0-byte at flush; cost data unrecoverable for session $session_id" >&2
    return 0
  fi

  # Self-healing setup-timing flush (issue #283). The orchestrator is
  # supposed to call `setup-timing.sh flush` at step 6.8 before dispatch,
  # but the spec embeds the flush in a long step body and readers commonly
  # skim past it — especially at `concurrency == 1` where step 0.7's
  # "skip the parallel batch" guidance was misread as "skip every
  # timing call." Result: sessions whose sidecars contain real per-phase
  # data still landed in the ledger with `setup: null`, dropping the data
  # we explicitly added in #238 to measure. Defense in depth: before
  # reading `.setup` from the session file, auto-flush any pending
  # timing sidecar so the ledger record always captures what was
  # actually instrumented. `setup-timing.sh flush` is idempotent (no-op
  # when the sidecar is gone) and writes through `session-state.sh
  # update` — same atomic-write guarantees as the rest of the file's
  # mutations. Fire-and-forget: a flush failure must NOT block the
  # cost-history flush from running.
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${this_dir}/setup-timing.sh" ]]; then
    "${this_dir}/setup-timing.sh" flush --session-id "$session_id" 2>/dev/null || true
  fi

  local session_target issue_target
  session_target=$(session_ledger_path)
  issue_target=$(issue_ledger_path)

  # Dedupe gate: if the session id already appears in the session
  # ledger, skip. Cheap grep (one read of the file, no jq parse) keeps
  # idempotency cheap even on a long ledger.
  if [[ $dry_run -eq 0 ]] && [[ -f "$session_target" ]] \
       && grep -F -q "\"session_id\":\"$session_id\"" "$session_target" 2>/dev/null; then
    return 0
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Project the session record. The schema mirrors the issue body's
  # design — session metadata + tokens block + by-model + by-mode rollups
  # computed from per_invocation. Also persists the `setup` timing block
  # (issue #238) when the session state contains it.
  local session_record
  session_record=$(jq -c \
    --arg now "$now" '
      . as $s
      | {
          session_id: $s.session_id,
          repo: $s.repo,
          started_at: $s.started_at,
          ended_at: $now,
          duration_seconds: (
            (($now | fromdateiso8601) - ($s.started_at | fromdateiso8601))
          ),
          issues_worked: (
            [ $s.tokens.per_invocation[]?.issue ] | map(select(. != null)) | unique
          ),
          prs_created: (
            [ $s.tokens.per_invocation[]?.pr ] | map(select(. != null)) | unique
          ),
          tokens: ($s.tokens.totals // {}) | del(.estimated_usd),
          estimated_usd: ($s.tokens.totals.estimated_usd // 0),
          by_model: (
            [ $s.tokens.per_invocation[]? | select(.model != null) ]
            | group_by(.model)
            | map({
                key: .[0].model,
                value: {
                  input:          (map(.input // 0) | add // 0),
                  output:         (map(.output // 0) | add // 0),
                  cache_read:     (map(.cache_read // 0) | add // 0),
                  cache_creation: (map(.cache_creation // 0) | add // 0),
                  estimated_usd:  (map(.estimated_usd // 0) | add // 0)
                }
              })
            | from_entries
          ),
          by_mode: (
            [ $s.tokens.per_invocation[]? | select(.mode != null) ]
            | group_by(.mode)
            | map({
                key: .[0].mode,
                value: {
                  input:          (map(.input // 0) | add // 0),
                  output:         (map(.output // 0) | add // 0),
                  cache_read:     (map(.cache_read // 0) | add // 0),
                  cache_creation: (map(.cache_creation // 0) | add // 0),
                  estimated_usd:  (map(.estimated_usd // 0) | add // 0)
                }
              })
            | from_entries
          ),
          setup: ($s.setup // null)
        }
    ' "$source")

  if [[ -z "$session_record" ]]; then
    echo "flush: failed to project session record from $source" >&2
    exit 68
  fi

  # Project one issue record per issue in `.tokens.per_issue`. Each gets
  # session-id and last-touched (now) so the reader can dedupe by picking
  # the latest record per (repo, issue_number).
  local issue_records
  issue_records=$(jq -c \
    --arg now "$now" '
      . as $s
      | ($s.tokens.per_issue // {}) as $per_issue
      | ($s.tokens.per_invocation // []) as $invs
      | ($per_issue | keys) as $issue_keys
      | $issue_keys[]
      | . as $k
      | {
          repo: $s.repo,
          issue_number: ($k | tonumber),
          last_touched: $now,
          session_id: $s.session_id,
          tokens: ($per_issue[$k] | del(.estimated_usd)),
          estimated_usd: ($per_issue[$k].estimated_usd // 0),
          modes_used: (
            [ $invs[] | select(.issue == ($k | tonumber)) | .mode ]
            | map(select(. != null)) | unique
          ),
          models_used: (
            [ $invs[] | select(.issue == ($k | tonumber)) | .model ]
            | map(select(. != null)) | unique
          ),
          pr: (
            [ $invs[] | select(.issue == ($k | tonumber)) | .pr ]
            | map(select(. != null)) | last
          )
        }
    ' "$source")

  if [[ $dry_run -eq 1 ]]; then
    printf '== session record:\n%s\n' "$session_record"
    if [[ -n "$issue_records" ]]; then
      printf '== issue records:\n%s\n' "$issue_records"
    fi
    return 0
  fi

  append_jsonl "$session_target" "$session_record"

  # Issue records are one per line already (jq -c on a stream).
  if [[ -n "$issue_records" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      append_jsonl "$issue_target" "$line"
    done <<< "$issue_records"
  fi
}

# --------------------------------------------------------------------------
# Read: emit the raw jsonl. Used by tests and downstream tools.
# --------------------------------------------------------------------------
cmd_read() {
  local ledger="sessions"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ledger) ledger="${2:-}"; shift 2 ;;
      *) echo "read: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local target
  case "$ledger" in
    sessions) target=$(session_ledger_path) ;;
    issues)   target=$(issue_ledger_path) ;;
    *) echo "read: --ledger must be sessions|issues (got: $ledger)" >&2; exit 64 ;;
  esac

  if [[ ! -f "$target" ]]; then
    echo "read: $target does not exist" >&2
    exit 3
  fi

  cat "$target"
}

# --------------------------------------------------------------------------
# Report: aggregate the ledgers and project an output format.
# --------------------------------------------------------------------------
# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables bound via `--arg` / `--argjson`. Single-quoting
# is the correct, safe shape.
cmd_report() {
  local last="30d"
  local repo_filter=""
  local by_issue=0
  local by_mode=0
  local by_model=0
  local top=""
  local trend=0
  local show_setup=0
  local format="markdown"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last)   last="${2:-}"; shift 2 ;;
      --repo)   repo_filter="${2:-}"; shift 2 ;;
      --by-issue) by_issue=1; shift ;;
      --by-mode)  by_mode=1; shift ;;
      --by-model) by_model=1; shift ;;
      --top)    top="${2:-}"; shift 2 ;;
      --trend)  trend=1; shift ;;
      --show-setup) show_setup=1; shift ;;
      --format) format="${2:-markdown}"; shift 2 ;;
      *) echo "report: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  case "$format" in
    markdown|csv|json) ;;
    *) echo "report: --format must be markdown|csv|json (got: $format)" >&2; exit 64 ;;
  esac

  # Convert --last to a cutoff timestamp (ISO 8601). `all` → epoch zero.
  local cutoff_iso
  case "$last" in
    all) cutoff_iso="1970-01-01T00:00:00Z" ;;
    *d)
      local days="${last%d}"
      if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "report: --last must be Nd or 'all' (got: $last)" >&2
        exit 64
      fi
      # Portable date arithmetic. macOS's BSD `date` lacks `-d`; GNU's
      # lacks `-v`. Try GNU first (CI Linux runners + most dev Linuxes),
      # fall back to BSD (macOS dev machines).
      if date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
        cutoff_iso=$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ)
      else
        cutoff_iso=$(date -u -v-"${days}d" +%Y-%m-%dT%H:%M:%SZ)
      fi
      ;;
    *)
      echo "report: --last must be Nd or 'all' (got: $last)" >&2
      exit 64
      ;;
  esac

  if [[ -n "$top" ]] && ! [[ "$top" =~ ^[0-9]+$ ]]; then
    echo "report: --top must be a positive integer (got: $top)" >&2
    exit 64
  fi

  local session_ledger issue_ledger
  session_ledger=$(session_ledger_path)
  issue_ledger=$(issue_ledger_path)

  # Empty-ledger short-circuit: emit the empty header so callers (and
  # tests) can rely on a consistent shape.
  if [[ ! -f "$session_ledger" ]] || [[ ! -s "$session_ledger" ]]; then
    case "$format" in
      markdown) printf 'No shipyard sessions recorded yet. Run /shipyard:do-work to start tracking.\n' ;;
      csv)      printf 'session_id,repo,started_at,ended_at,duration_seconds,total_tokens,estimated_usd\n' ;;
      json)     printf '{"sessions": [], "totals": {"sessions": 0, "issues_worked": 0, "prs_created": 0, "estimated_usd": 0}}\n' ;;
    esac
    return 0
  fi

  # Project filtered sessions (slurped into a single array). This is the
  # core data structure every output format derives from.
  local jq_filter='select(.started_at >= $cutoff)'
  if [[ -n "$repo_filter" ]]; then
    jq_filter="$jq_filter | select(.repo == \$repo)"
  fi

  local sessions
  sessions=$(jq -s -c \
    --arg cutoff "$cutoff_iso" \
    --arg repo "$repo_filter" \
    "[ .[] | $jq_filter ]" "$session_ledger")

  # Compute totals + by-model + by-mode + trend buckets in one jq pass
  # — keeping them all in one shape makes the format-specific renderers
  # trivial.
  local rollup
  rollup=$(printf '%s' "$sessions" | jq -c '
    . as $sessions
    | {
        sessions: ($sessions | length),
        issues_worked: ([$sessions[].issues_worked[]?] | unique | length),
        prs_created:   ([$sessions[].prs_created[]?] | unique | length),
        tokens: {
          input:          ([$sessions[].tokens.input          // 0] | add // 0),
          output:         ([$sessions[].tokens.output         // 0] | add // 0),
          cache_read:     ([$sessions[].tokens.cache_read     // 0] | add // 0),
          cache_creation: ([$sessions[].tokens.cache_creation // 0] | add // 0)
        },
        estimated_usd: ([$sessions[].estimated_usd // 0] | add // 0),
        by_model: (
          [ $sessions[].by_model // {} | to_entries[]? ]
          | group_by(.key)
          | map({
              key: .[0].key,
              value: {
                input:          (map(.value.input          // 0) | add // 0),
                output:         (map(.value.output         // 0) | add // 0),
                cache_read:     (map(.value.cache_read     // 0) | add // 0),
                cache_creation: (map(.value.cache_creation // 0) | add // 0),
                estimated_usd:  (map(.value.estimated_usd  // 0) | add // 0)
              }
            })
          | from_entries
        ),
        by_mode: (
          [ $sessions[].by_mode // {} | to_entries[]? ]
          | group_by(.key)
          | map({
              key: .[0].key,
              value: {
                input:          (map(.value.input          // 0) | add // 0),
                output:         (map(.value.output         // 0) | add // 0),
                cache_read:     (map(.value.cache_read     // 0) | add // 0),
                cache_creation: (map(.value.cache_creation // 0) | add // 0),
                estimated_usd:  (map(.value.estimated_usd  // 0) | add // 0)
              }
            })
          | from_entries
        )
      }
  ')

  # Per-issue rollup: dedupe issue ledger by (repo, issue_number), keep
  # the latest record (highest last_touched), then filter by cutoff +
  # optional --repo. Returns empty array if the issue ledger doesn't
  # exist (no issue-touched sessions yet).
  local issue_filter='select(.last_touched >= $cutoff)'
  if [[ -n "$repo_filter" ]]; then
    issue_filter="$issue_filter | select(.repo == \$repo)"
  fi

  local issues
  if [[ -f "$issue_ledger" ]] && [[ -s "$issue_ledger" ]]; then
    issues=$(jq -s -c \
      --arg cutoff "$cutoff_iso" \
      --arg repo "$repo_filter" \
      "
      [ .[] | $issue_filter ]
      | group_by([.repo, .issue_number])
      | map(max_by(.last_touched))
      " "$issue_ledger")
  else
    issues='[]'
  fi

  # Trend buckets: weekly rollup, bucketed by the ISO date of the Monday
  # at-or-before each session's started_at. Computed via epoch arithmetic
  # so the math is portable (no GNU `date -d` dependency, no BSD `date -j`
  # branch). Empty array when no sessions in range.
  local trend_buckets
  trend_buckets=$(printf '%s' "$sessions" | jq -c '
    [ .[]
      | (.started_at | fromdateiso8601) as $epoch
      # Days since 1970-01-01 (a Thursday). Adjust so Monday is day 0:
      # Monday 1970-01-05 is day 4 in raw count; offset by +3 to map
      # Mondays to day-mod-7 = 0.
      | (($epoch / 86400) | floor) as $day
      | (($day + 3) % 7) as $weekday_offset
      | (($day - $weekday_offset) * 86400) as $week_start_epoch
      | { week_starting: ($week_start_epoch | todate | .[0:10]),
          usd: (.estimated_usd // 0),
          sessions: 1 } ]
    | group_by(.week_starting)
    | map({
        week_starting: .[0].week_starting,
        sessions: (map(.sessions) | add),
        estimated_usd: (map(.usd) | add)
      })
    | sort_by(.week_starting)
  ')

  case "$format" in
    json)
      # When --show-setup is requested, include a setup_timing aggregate in
      # the JSON output so callers can pipe into jq for further analysis.
      local setup_agg='null'
      if [[ "$show_setup" -eq 1 ]]; then
        setup_agg=$(printf '%s' "$sessions" | jq -c '
          [ .[] | select(.setup != null) ] as $inst
          | if ($inst | length) == 0 then null
            else {
              sessions_with_timing: ($inst | length),
              wall_clock: {
                mean: ($inst | map(.setup.wall_clock_seconds // 0) | add / length),
                median: (
                  ($inst | map(.setup.wall_clock_seconds // 0) | sort) as $s
                  | ($s | length) as $n
                  | if ($n % 2) == 1 then $s[($n / 2 | floor)]
                    else (($s[($n / 2) - 1] + $s[$n / 2]) / 2)
                    end
                )
              },
              phases: (
                [ $inst[]
                  | select(.setup.phases != null)
                  | .setup.phases | to_entries[]
                  | { phase: .key, seconds: .value }
                ]
                | group_by(.phase)
                | map({
                    key: .[0].phase,
                    value: {
                      mean: (map(.seconds) | add / length),
                      count: length
                    }
                  })
                | from_entries
              )
            }
            end
        ')
      fi
      jq -n \
        --argjson rollup "$rollup" \
        --argjson sessions "$sessions" \
        --argjson issues "$issues" \
        --argjson trend "$trend_buckets" \
        --argjson setup_timing "$setup_agg" \
        --arg cutoff "$cutoff_iso" \
        --arg last "$last" \
        '{
          range: { last: $last, since: $cutoff },
          rollup: $rollup,
          trend: $trend,
          sessions: $sessions,
          issues: $issues,
          setup_timing: $setup_timing
        }'
      ;;
    csv)
      # Sessions CSV with the seven core columns. Useful for piping
      # into a spreadsheet for ad-hoc analysis.
      printf 'session_id,repo,started_at,ended_at,duration_seconds,total_tokens,estimated_usd\n'
      printf '%s' "$sessions" | jq -r '
        .[]
        | [
            .session_id,
            .repo,
            .started_at,
            .ended_at,
            (.duration_seconds // 0 | tostring),
            ((.tokens.input // 0) + (.tokens.output // 0)
              + (.tokens.cache_read // 0) + (.tokens.cache_creation // 0) | tostring),
            (.estimated_usd // 0 | tostring)
          ]
        | @csv
      '
      ;;
    markdown)
      render_markdown_report \
        "$cutoff_iso" "$last" "$repo_filter" \
        "$rollup" "$sessions" "$issues" "$trend_buckets" \
        "$by_issue" "$by_mode" "$by_model" "$trend" "$top" "$show_setup"
      ;;
  esac
}

# render_markdown_report — separated from cmd_report so the format-
# specific projection is easier to read.
render_markdown_report() {
  local cutoff="$1"
  local last="$2"
  local repo_filter="$3"
  local rollup="$4"
  local sessions="$5"
  local issues="$6"
  local trend_buckets="$7"
  local by_issue="$8"
  local by_mode="$9"
  local by_model="${10}"
  local trend="${11}"
  local top="${12}"
  local show_setup="${13:-0}"

  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Header.
  if [[ -n "$repo_filter" ]]; then
    printf 'Shipyard cost — %s (last %s, %s to %s)\n' \
      "$repo_filter" "$last" "${cutoff:0:10}" "${now_iso:0:10}"
  else
    printf 'Shipyard cost — last %s (%s to %s)\n' \
      "$last" "${cutoff:0:10}" "${now_iso:0:10}"
  fi
  printf '%s\n\n' "$(printf '═%.0s' {1..56})"

  # Totals block.
  printf 'TOTALS\n'
  printf '%s' "$rollup" | jq -r '
    "  Sessions:        " + (.sessions | tostring) +
    "\n  Issues worked:   " + (.issues_worked | tostring) +
    "\n  PRs created:     " + (.prs_created | tostring) +
    "\n  Tokens:          " +
      ((.tokens.input // 0) | tostring) + " input, " +
      ((.tokens.output // 0) | tostring) + " output (" +
      (((.tokens.cache_read // 0) + (.tokens.cache_creation // 0)) | tostring) + " cache)" +
    "\n  Spend:           $" + (.estimated_usd | . * 100 | round / 100 | tostring) +
      (if .sessions > 0
        then " (avg $" + ((.estimated_usd / .sessions) | . * 100 | round / 100 | tostring) + "/session)"
        else "" end)
  '
  printf '\n'

  if [[ "$by_model" -eq 1 ]]; then
    printf '\nBY MODEL\n'
    printf '%s' "$rollup" | jq -r '
      .by_model
      | to_entries
      | sort_by(-.value.estimated_usd)
      | .[]
      | "  " + .key + "  $" + (.value.estimated_usd | . * 100 | round / 100 | tostring)
    '
  fi

  if [[ "$by_mode" -eq 1 ]]; then
    printf '\nBY MODE\n'
    printf '%s' "$rollup" | jq -r '
      .by_mode
      | to_entries
      | sort_by(-.value.estimated_usd)
      | .[]
      | "  " + .key + "  $" + (.value.estimated_usd | . * 100 | round / 100 | tostring)
    '
  fi

  if [[ "$by_issue" -eq 1 ]] || [[ -n "$top" ]]; then
    local top_n="${top:-10}"
    printf '\nTOP %s MOST EXPENSIVE ISSUES\n' "$top_n"
    printf '%s' "$issues" | jq -r --argjson top "$top_n" '
      sort_by(-(.estimated_usd // 0))
      | .[0:$top]
      | .[]
      | "  #" + (.issue_number | tostring) +
        "  " + .repo +
        "  $" + ((.estimated_usd // 0) | . * 100 | round / 100 | tostring) +
        (if (.pr // null) != null then "  (PR #" + (.pr | tostring) + ")" else "" end)
    '
  fi

  if [[ "$trend" -eq 1 ]]; then
    printf '\nTREND (weekly)\n'
    printf '%s' "$trend_buckets" | jq -r '
      .[]
      | "  " + .week_starting +
        "  $" + (.estimated_usd | . * 100 | round / 100 | tostring) +
        "  (" + (.sessions | tostring) +
        (if .sessions == 1 then " session" else " sessions" end) + ")"
    '
  fi

  if [[ "$show_setup" -eq 1 ]]; then
    # Aggregate setup timing across all sessions in range. For each session
    # that has a `setup` block, extract the wall_clock_seconds total and the
    # per-phase durations. Compute the median and mean wall-clock, plus the
    # mean per-phase. Sessions without a `setup` block (recorded before this
    # feature landed) are silently excluded from the aggregate.
    printf '\nSETUP PHASE TIMING (sessions with instrumentation)\n'
    printf '%s' "$sessions" | jq -r '
      [ .[] | select(.setup != null) ] as $instrumented
      | ($instrumented | length) as $n
      | if $n == 0 then
          "  No sessions with setup timing recorded yet.\n  Run at least one /shipyard:do-work session after upgrading to see data here."
        else
          # Wall-clock aggregate
          ($instrumented | map(.setup.wall_clock_seconds // 0) | sort) as $wcs
          | ($wcs | add / $n) as $mean_wall
          | (if ($n % 2) == 1
              then $wcs[($n / 2 | floor)]
              else (($wcs[($n / 2) - 1] + $wcs[$n / 2]) / 2)
              end) as $median_wall
          # Per-phase means across sessions
          | [ $instrumented[]
              | select(.setup.phases != null)
              | .setup.phases
              | to_entries[]
              | { phase: .key, seconds: .value }
            ] as $all_phase_entries
          | ($all_phase_entries
              | group_by(.phase)
              | map({
                  phase: .[0].phase,
                  mean: (map(.seconds) | add / length),
                  count: length
                })
              | sort_by(-.mean)
            ) as $phase_means
          # Render
          | "  Sessions with timing: " + ($n | tostring) +
            "\n  Wall clock — mean: " + ($mean_wall | . * 10 | round / 10 | tostring) + "s" +
            "  median: " + ($median_wall | . * 10 | round / 10 | tostring) + "s" +
            "\n\n  Per-phase means (slowest first):" +
            ($phase_means | map(
                "\n    " + .phase + ": " + (.mean | . * 10 | round / 10 | tostring) + "s" +
                "  (n=" + (.count | tostring) + ")"
              ) | join(""))
        end
    '
  fi

  # Always-on footer pointing at the deeper flags.
  printf '\nWant more detail? Try '\''%s'\''.\n' \
    "/shipyard:cost report --by-issue --top 20"
}

# --------------------------------------------------------------------------
# Reset: truncate the ledger files. Destructive — prompts unless --yes.
# --------------------------------------------------------------------------
cmd_reset() {
  local yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) echo "reset: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local session_target issue_target
  session_target=$(session_ledger_path)
  issue_target=$(issue_ledger_path)

  if [[ $yes -ne 1 ]]; then
    printf 'This will move the following files to .bak.<timestamp>:\n' >&2
    printf '  %s\n' "$session_target" >&2
    printf '  %s\n' "$issue_target" >&2
    printf 'Continue? [y/N] ' >&2
    local reply
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "reset: aborted" >&2; exit 70 ;;
    esac
  fi

  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local moved=0
  for target in "$session_target" "$issue_target"; do
    if [[ -f "$target" ]]; then
      mv "$target" "$target.bak.$ts"
      printf 'reset: moved %s -> %s.bak.%s\n' "$target" "$target" "$ts" >&2
      moved=$((moved + 1))
    fi
  done

  if [[ $moved -eq 0 ]]; then
    printf 'reset: no ledger files to remove (nothing to reset)\n' >&2
  fi
}

# --------------------------------------------------------------------------
# Export: bundle the ledger files into a tarball.
# --------------------------------------------------------------------------
cmd_export() {
  local to=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      *) echo "export: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$to" ]]; then
    echo "export: --to <path>.tar.gz is required" >&2
    usage
    exit 64
  fi

  # Don't enforce the .tar.gz suffix strictly — but if it's absent, warn.
  # The format is tar+gzip regardless of the suffix.
  case "$to" in
    *.tar.gz|*.tgz) ;;
    *) echo "export: warning — destination $to does not end in .tar.gz / .tgz" >&2 ;;
  esac

  local home
  home=$(shipyard_home)
  if [[ ! -d "$home" ]]; then
    echo "export: $home does not exist (nothing to export)" >&2
    exit 0
  fi

  # Bundle only the ledger files, not the sessions/ directory (those are
  # transient and the orchestrator reaps them anyway). Use a relative
  # path inside the tarball so a restore extracts cleanly into any
  # SHIPYARD_HOME.
  local files=()
  for f in cost-history.jsonl cost-history-issues.jsonl; do
    if [[ -f "$home/$f" ]]; then
      files+=("$f")
    fi
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "export: no ledger files found in $home (nothing to export)" >&2
    exit 0
  fi

  mkdir -p "$(dirname "$to")"
  if ! (cd "$home" && tar -czf "$to" "${files[@]}"); then
    echo "export: tar failed (target: $to)" >&2
    exit 69
  fi

  printf 'export: wrote %s (%s file(s))\n' "$to" "${#files[@]}" >&2
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
  flush)  cmd_flush "$@" ;;
  report) cmd_report "$@" ;;
  reset)  cmd_reset "$@" ;;
  export) cmd_export "$@" ;;
  read)   cmd_read "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "cost-history.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
