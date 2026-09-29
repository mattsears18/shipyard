#!/usr/bin/env bash
# playwright-summary-buckets.sh — attribute a Playwright job's failures from
# the END-OF-RUN SUMMARY BUCKETS, never from per-spec `##[error]` annotations.
#
# Background (issue #1598)
# ------------------------
# Playwright emits a `##[error]` annotation for every failed *attempt* —
# including attempts that later pass on retry. Those annotations therefore
# cannot tell `failed` from `flaky`: a spec that timed out once and passed on
# its retry looks exactly like a spec that genuinely failed. `gh run view
# --log-failed` surfaces exactly those annotations, so reading it is the
# natural move — and the wrong one. Only the reporter's end-of-run summary
# decides:
#
#     1 failed
#       [chromium] › e2e/web/cookie-consent.spec.ts:325:5 › COOKIE-CONSENT-7
#     2 flaky
#       [chromium] › e2e/web/recurring-series.spec.ts:251:5 › RECURRING-SERIES-4
#       [chromium] › e2e/web/tasks-crud.spec.ts:586:5 › TASKS-CRUD-12
#     8 skipped
#     266 passed (38.7m)
#
# The #1598 repro attributed the two `flaky` specs (their annotations were in
# `--log-failed`) to the PR's own diff, posted that as a public comment, and
# dispatched a fix-checks worker against them — ~176k tokens for a `noop`,
# on a repo running `failOnFlakyTests: false`, where a retry-recovered flake
# is structurally incapable of reddening the run.
#
# The summary lives in the FULL job log (`/actions/jobs/<id>/logs`), not in
# `--log-failed`. This script parses it.
#
# Subcommands
# -----------
#
#   parse (--log <file> | --repo <owner/repo> --job <job-id>)
#     Prints one JSON line:
#       {"summary_found":true,
#        "failed":[<entry>...], "flaky":[<entry>...],
#        "interrupted":[<entry>...], "did_not_run":[<entry>...],
#        "counts":{"failed":1,"flaky":2,"skipped":8,"passed":266}}
#     Only the LAST summary block in the log counts. When no summary block
#     is present at all, prints {"summary_found":false,...} and exits 3 —
#     INDETERMINATE, never a pass: the caller must not conclude "nothing
#     failed" from it (e.g. the job died before the reporter printed, or the
#     job isn't a Playwright job).
#
#   classify (--log <file> | --repo <owner/repo> --job <job-id>) --spec <text>
#     Prints exactly one word for the spec (a case-sensitive substring match
#     against summary entries, e.g. `tasks-crud.spec.ts:586` or
#     `TASKS-CRUD-12`):
#       failed         — in the `failed` (or `interrupted`) bucket: a real failure
#       flaky          — only in the `flaky` bucket: passed on retry, did NOT
#                        fail the run unless the repo sets failOnFlakyTests: true
#       absent         — named in no failure bucket: NOT a dispatchable failure
#       indeterminate  — no summary block found (exit 3)
#
# The `gh` dependency is resolved via $GH (default `gh`) so tests can mock it.
#
# Exit codes: 0 summary found; 3 no summary found (indeterminate); 64 bad
# usage; 65 missing dependency (jq/gh); 66 log unreadable / fetch failed.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  playwright-summary-buckets.sh parse    (--log <file> | --repo <owner/repo> --job <job-id>)
  playwright-summary-buckets.sh classify (--log <file> | --repo <owner/repo> --job <job-id>) --spec <text>
EOF
}

require_jq "playwright-summary-buckets.sh"

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  parse|classify) ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 64 ;;
  *) echo "playwright-summary-buckets.sh: unknown subcommand: $sub" >&2; usage >&2; exit 64 ;;
esac

log=""
repo=""
job=""
spec=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) log="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --job) job="${2:-}"; shift 2 ;;
    --spec) spec="${2:-}"; shift 2 ;;
    *) echo "playwright-summary-buckets.sh $sub: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ -n "$log" ] && { [ -n "$repo" ] || [ -n "$job" ]; }; then
  echo "playwright-summary-buckets.sh $sub: pass either --log or --repo/--job, not both" >&2
  exit 64
fi
if [ -z "$log" ] && { [ -z "$repo" ] || [ -z "$job" ]; }; then
  echo "playwright-summary-buckets.sh $sub: --log <file>, or both --repo and --job, are required" >&2
  usage >&2
  exit 64
fi
if [ "$sub" = "classify" ] && [ -z "$spec" ]; then
  echo "playwright-summary-buckets.sh classify: --spec is required" >&2
  exit 64
fi

tmp=""
trap '[ -n "$tmp" ] && rm -f "$tmp"' EXIT

if [ -z "$log" ]; then
  GH="${GH:-gh}"
  if ! command -v "$GH" >/dev/null 2>&1; then
    echo "playwright-summary-buckets.sh: gh is required but not installed" >&2
    exit 65
  fi
  tmp="$(mktemp)"
  if ! "$GH" api "repos/${repo}/actions/jobs/${job}/logs" > "$tmp" 2>/dev/null; then
    echo "playwright-summary-buckets.sh: failed to fetch logs for job ${job} in ${repo}" >&2
    exit 66
  fi
  log="$tmp"
fi

if [ ! -r "$log" ]; then
  echo "playwright-summary-buckets.sh: log not readable: $log" >&2
  exit 66
fi

# awk emits tab-separated records for the LAST summary block only:
#   C<TAB><bucket><TAB><n>     a bucket header's count
#   E<TAB><bucket><TAB><text>  an entry listed under a failed/flaky/interrupted/did-not-run header
# A summary block starts at the first bucket header following a non-summary
# line; starting a new block discards the previous one.
records="$(awk '
  function clean(s) {
    sub(/\r$/, "", s)
    gsub(/\033\[[0-9;]*[A-Za-z]/, "", s)
    # GitHub Actions job logs prefix every line with an ISO-8601 timestamp.
    sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "", s)
    return s
  }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  BEGIN { in_summary = 0; cur = ""; n = 0 }
  {
    line = clean($0)
    if (match(line, /^[ \t]*[0-9]+ (failed|flaky|skipped|passed|interrupted|did not run)([ \t]+\(.*\))?[ \t]*$/)) {
      if (!in_summary) { n = 0; in_summary = 1 }
      t = trim(line)
      cnt = t; sub(/ .*/, "", cnt)
      b = t; sub(/^[0-9]+ /, "", b); sub(/[ \t]+\(.*$/, "", b)
      if (b == "did not run") b = "did_not_run"
      out[++n] = "C\t" b "\t" cnt
      cur = (b == "failed" || b == "flaky" || b == "interrupted" || b == "did_not_run") ? b : ""
      next
    }
    if (in_summary) {
      if (trim(line) == "") next
      if (cur != "" && line ~ /^[ \t]+/ && (index(line, "\342\200\272") > 0 || line ~ /\.(spec|test)\.[cm]?[jt]sx?:[0-9]+/)) {
        out[++n] = "E\t" cur "\t" trim(line)
        next
      }
      in_summary = 0; cur = ""
    }
  }
  END { for (i = 1; i <= n; i++) print out[i] }
' "$log")"

json="$(jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t")) as $r
  | {
      summary_found: (($r | length) > 0),
      failed:      [$r[] | select(.[0] == "E" and .[1] == "failed")      | .[2]],
      flaky:       [$r[] | select(.[0] == "E" and .[1] == "flaky")       | .[2]],
      interrupted: [$r[] | select(.[0] == "E" and .[1] == "interrupted") | .[2]],
      did_not_run: [$r[] | select(.[0] == "E" and .[1] == "did_not_run") | .[2]],
      counts: ([$r[] | select(.[0] == "C") | {(.[1]): (.[2] | tonumber)}] | add // {})
    }' <<< "$records")"

found="$(jq -r '.summary_found' <<< "$json")"

if [ "$sub" = "parse" ]; then
  printf '%s\n' "$json"
  [ "$found" = "true" ] && exit 0
  exit 3
fi

# classify
if [ "$found" != "true" ]; then
  echo "indeterminate"
  exit 3
fi
verdict="$(jq -r --arg s "$spec" '
  if ([.failed[], .interrupted[]] | any(contains($s))) then "failed"
  elif ([.flaky[]] | any(contains($s))) then "flaky"
  else "absent" end' <<< "$json")"
echo "$verdict"
exit 0
