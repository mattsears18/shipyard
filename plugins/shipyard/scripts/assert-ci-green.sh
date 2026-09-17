#!/usr/bin/env bash
# assert-ci-green.sh — the SINGLE EXECUTABLE SOURCE OF TRUTH for the question
# "did CI actually pass for <commit|branch>?"
#
# The whole point of this script is that it can never answer "green" without
# having observed at least one run. An absence-assertion that cannot distinguish
# "nothing bad found" from "nothing looked at" is not a check.
#
# Background (issue #717)
# -----------------------
# `gh run list --commit <sha>` requires a **full 40-char SHA**. An abbreviated
# SHA (`git rev-parse --short HEAD`, a 7-char hash pasted from a log) silently
# matches ZERO runs — gh exits 0 and prints an empty list. Any verification
# shaped as
#
#     failures=$(gh run list --commit "$sha" --json conclusion \
#                  --jq '[.[] | select(.conclusion != "success")] | length')
#     [ "$failures" -eq 0 ] && echo "main is green"
#
# therefore **passes on the empty set** — reporting green while having observed
# nothing at all. It converts "I could not verify" into "verified green", which
# is the dangerous direction: every downstream `checks: green` claim in the
# return contract inherits a verdict that was never actually taken.
#
# The same failure family shows up whenever a tool's degenerate/empty output is
# read as a pass (GNU grep printing `binary file matches` instead of the matched
# lines; `grep -P` erroring out unsupported on macOS and the error being
# swallowed). The structural fix is the same everywhere: assert you observed
# something BEFORE you assert that what you observed was clean.
#
# Background (issue #1495) — the SECOND vacuous shape: a path-filtered skip
# ------------------------------------------------------------------------
# #717 covered "0 runs observed". #1495 is the same class one layer down: a run
# IS observed, its required job's `conclusion` IS `success`, and yet **zero
# tests ran** — every substantive step was `skipped` by a `paths`/`paths-ignore`
# / `detect-paths` docs-only gate:
#
#     1  Set up job                                    : success
#     2  Require detect-paths to complete              : success
#     3  Skip on docs-only changes                     : success
#     4  Run actions/checkout@v7.0.1                   : skipped
#     ..
#    13  Unit tests — product (web + native, coverage) : skipped
#    ..
#    19  Complete job                                  : success
#
# The run's own `conclusion` field has no way to express "I passed vacuously",
# so a `conclusion == success` read is green-when-red in the dangerous
# direction: the last run that actually executed the suite may still be failing,
# and that stale red silently poisons every PR branched afterwards. This sits
# directly under the main-CI divert — the highest-priority dispatch in the loop.
#
# The fix is the same structural move as #717's, applied to steps instead of
# runs: assert the job actually DID something before reading its `success` as
# evidence. When the deciding run turns out to be vacuous, walk back to the most
# recent run of that same workflow whose steps really executed and use THAT
# verdict; if no run in the lookback window executed, the answer is `unproven`.
#
# Verdicts (exit code == verdict; the word is also printed on stdout)
# ------------------------------------------------------------------
#   0  green    >=1 run matched AND every workflow's latest completed run passed
#                  AND that run actually executed its steps
#   1  red      >=1 workflow's latest *executed* run failed
#   3  pending  runs matched, but no workflow has a completed verdict yet
#   2  unknown  NOT VERIFIED — 0 runs matched, the ref could not be resolved to a
#               full SHA, or the gh call failed. **Never treat as green.**
#   4  unproven NOT VERIFIED — a run matched and reported success, but every
#               substantive step was `skipped` (a path filter short-circuited the
#               job) and no run within the lookback window actually executed.
#               The success carries no evidence about the tree. **Never treat as
#               green.** (#1495)
#
# `unknown` and `unproven` are deliberately their own verdicts rather than being
# folded into `red` or `green`: the caller usually wants to retry / widen the
# window / bail, not to act as if it has a verdict. What it must never do is
# proceed as if green. They are kept distinct from each other because they are
# differently actionable — `unknown` means "look again / widen the window",
# `unproven` means "the newest run is structurally incapable of telling you, go
# find one that ran".
#
# Aggregation precedence across workflows: red > unproven > pending > green.
# `unproven` outranks `pending` because a pending workflow resolves itself on the
# next refresh, whereas an unproven one will keep reporting a vacuous success on
# every subsequent docs-only commit.
#
# Usage — live (the normal path):
#   bash assert-ci-green.sh <owner/repo> --commit <ref>  [--limit N]
#                                                        [--max-lookback N]
#                                                        [--no-step-check]
#   bash assert-ci-green.sh <owner/repo> --branch <name> [--limit N]
#                                                        [--max-lookback N]
#                                                        [--no-step-check]
#
#   Step-level verification is ON by default and costs one extra
#   `gh run view --json jobs` call per workflow whose deciding run is green,
#   plus up to `--max-lookback` (default 5) more per vacuous workflow while
#   walking back. `--no-step-check` restores the pre-#1495 run-level-only
#   behaviour for callers that cannot afford those calls.
#
#   `--commit <ref>` accepts a full 40-char SHA (used as-is) or any git ref this
#   worktree can resolve (`HEAD`, a branch name, a short SHA) — the script
#   resolves it to the full SHA itself via `git rev-parse`, so the abbreviated-SHA
#   footgun cannot be reintroduced by a caller. A ref that cannot be resolved to
#   40 hex chars is `unknown`, never green.
#
# Usage — pure decision (hermetic; used by the tests and by callers that already
# hold a `gh run list --json ...` payload):
#   bash assert-ci-green.sh --classify '<json-array>'
#   printf '%s' "$json" | bash assert-ci-green.sh --classify -
#
# Usage — pure step-level decision (hermetic; takes the `.jobs` array from
# `gh run view <id> --json jobs`, answers "did this run actually do anything?"):
#   bash assert-ci-green.sh --classify-steps '<jobs-json-array>'
#   printf '%s' "$jobs" | bash assert-ci-green.sh --classify-steps -
#     prints `executed` (exit 0) | `vacuous` (exit 4) | `unknown` (exit 2)
#
# Fail-safe posture: any signal that cannot be read resolves toward `unknown` /
# `unproven` (i.e. toward "I did not verify"), never toward `green`. Claiming
# green without evidence is the one outcome this script exists to make
# impossible.
#
# One deliberate, narrow exception (#1495): if the *step-level* read itself
# fails — `gh run view --json jobs` errors, is rate-limited, or the token cannot
# see job detail — the workflow KEEPS its run-level verdict and a loud advisory
# goes to stderr. That is not a "fail toward green" violation: unlike the
# empty-set case, a real completed run WAS observed, so there is genuine (if
# weaker) evidence in hand. Degrading every green to `unproven` on an API hiccup
# would make the script unusable in constrained environments, which is a worse
# failure than the one it would prevent. Callers who want the strict posture can
# treat the advisory as fatal themselves.

set -uo pipefail

readonly EXIT_GREEN=0
readonly EXIT_RED=1
readonly EXIT_UNKNOWN=2
readonly EXIT_PENDING=3
readonly EXIT_UNPROVEN=4

# Steps the GitHub Actions runner injects into every job. They run (and succeed)
# even when every user-authored step was skipped, so they must be excluded before
# asking "did this job do any real work?".
# shellcheck disable=SC2016  # `$l` is a jq binding, not a shell expansion.
readonly RUNNER_STEP_JQ='
  def is_runner_step:
    ((.name // "") | ascii_downcase) as $l
    | ($l == "set up job")
      or ($l == "complete job")
      or ($l | startswith("set up runner"))
      or ($l | startswith("post "));
'

# ---------------------------------------------------------------------------
# The decision. Pure function of a `gh run list --json` payload — no I/O, no
# network. This is the whole rule; everything else in this file just feeds it.
#
# Per-workflow granularity (matching do-work/setup/04-backlog-divert.md § 4.5a):
# a single `success` proves only that ONE workflow passed. For each workflow we
# take its most recent COMPLETED, non-`cancelled` run — `cancelled` is normal
# traffic on an active branch (GitHub's concurrency-group supersession), not a
# verdict — and the branch is green only when every workflow's verdict is green.
# ---------------------------------------------------------------------------
classify() {
  local json="$1" total

  total="$(printf '%s' "$json" | jq 'if type == "array" then length else -1 end' 2>/dev/null)"
  case "$total" in
    ''|*[!0-9-]*) total=-1 ;;
  esac

  # A payload that isn't a JSON array at all means we could not read the signal.
  if [ "$total" -lt 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: could not parse the run list as a JSON array — NOT VERIFIED" >&2
    return "$EXIT_UNKNOWN"
  fi

  # --- BEGIN empty-set guard (#717) -- do not remove; see negative control in
  # --- scripts/tests/assert-ci-green.test.sh, which deletes this exact block and
  # --- asserts the script then vacuously reports green on an empty run list.
  #
  # THE load-bearing line of this script. Zero runs matched => we observed
  # nothing => `unknown`, never green. This is what makes "count the failures,
  # assert the count is 0" safe: the count is only meaningful once we know the
  # set was non-empty.
  if [ "$total" -eq 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: 0 runs matched — NOT VERIFIED (an empty result set is not a pass)" >&2
    return "$EXIT_UNKNOWN"
  fi
  # --- END empty-set guard (#717) ---

  local verdict
  verdict="$(printf '%s' "$json" | jq -r '
    # Per workflow, the most recent completed non-cancelled run is the verdict.
    def wf_name: (.workflowName // .name // "(unnamed)");
    def sort_key: (.createdAt // .startedAt // "");
    [ group_by(wf_name)[]
      | [ .[]
          | select((.status // "") == "completed")
          | select(((.conclusion // "") | ascii_downcase) != "cancelled")
        ]
        | sort_by(sort_key)
        | last
        | if . == null then "pending"
          elif ((.conclusion // "") | ascii_downcase)
               | IN("success", "skipped", "neutral") then "green"
          else "red"
          end
    ]
    | if any(.[]; . == "red") then "red"
      elif any(.[]; . == "pending") then "pending"
      else "green"
      end
  ' 2>/dev/null)"

  case "$verdict" in
    green)
      printf 'green\n'
      echo "assert-ci-green: ${total} run(s) observed; every workflow's latest completed run passed" >&2
      return "$EXIT_GREEN"
      ;;
    red)
      printf 'red\n'
      echo "assert-ci-green: ${total} run(s) observed; at least one workflow's latest completed run failed" >&2
      return "$EXIT_RED"
      ;;
    pending)
      printf 'pending\n'
      echo "assert-ci-green: ${total} run(s) observed; no completed verdict yet — NOT VERIFIED" >&2
      return "$EXIT_PENDING"
      ;;
    *)
      printf 'unknown\n'
      echo "assert-ci-green: could not classify the run list — NOT VERIFIED" >&2
      return "$EXIT_UNKNOWN"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The step-level decision (#1495). Pure function of a `gh run view --json jobs`
# payload's `.jobs` array — no I/O, no network. Answers the one question the
# run-level `conclusion` field structurally cannot: did this run actually DO
# anything, or did a path filter skip its way to a vacuous `success`?
#
# A job is VACUOUS when, among its user-authored steps (runner-injected ones
# excluded — see RUNNER_STEP_JQ):
#
#   (a) at least one step was `skipped`, AND
#   (b) EITHER skipped steps outnumber steps that actually ran,
#       OR a checkout-shaped step was skipped.
#
# (b)'s first clause is the general signal — a job whose real work was gated off
# skips far more than it runs. The second is the crisp special case: a job that
# never even checked out the tree cannot have tested it, whatever its conclusion
# says. Requiring a STRICT majority in the first clause is what keeps the very
# common trailing `if: failure()` artifact-upload step (1 skipped, many run) from
# false-positiving.
#
# A run is vacuous when at least one of its jobs is vacuous AND no sibling job
# executed SUBSTANTIVELY (#1564). A non-vacuous sibling is substantive when the
# number of user-authored steps it actually ran is >= the user-authored step
# count of the largest vacuous job — i.e. the run demonstrably did at least as
# much real work as the skipped job would have done.
#
# Both halves are load-bearing:
#   * #1495: the `detect-paths` job ran for real (a handful of steps) while the
#     required `🧪 Unit Tests` job skipped everything. A "were ALL jobs vacuous?"
#     rule would have missed that, and detect-paths is not substantive against a
#     test job that would have run many more steps, so the run stays VACUOUS.
#   * #1564: on a single-workflow repo with a legitimately path-scoped sibling
#     job (`🧹 Lint (marketing)`: 1 step ran, 6 skipped), the plain "ANY job
#     vacuous => run vacuous" rule marked EVERY run vacuous while Lint &
#     Typecheck / Unit Tests / Web E2E each ran ~20 steps. The 5-run walk-back
#     never found an "executed" run, main_ci pinned to `unknown`, and the
#     fix-main-ci divert went silently dead. Those executed siblings are
#     substantive, so that run is EXECUTED.
#
# Scoring per *required* check instead was considered and rejected: in the
# #1564 repro the path-scoped `🧹 Lint (marketing)` job IS itself a required
# check (the standard way to require a path-filtered job is a step-level skip,
# which is exactly the shape this guard looks for), so a required-only rule
# would not have fixed the repro — and it would cost an extra API call.
#
# A job with zero user-authored steps (the ordinary job-level `if:` skip, where
# GitHub reports `conclusion: skipped` and no step detail) is NOT vacuous — it
# never claimed to have run, so there is no false success to catch.
#
# Over-triggering is cheap and safe: a false `vacuous` costs one extra API call
# and a walk-back that lands on the same verdict. Under-triggering is the bug.
# ---------------------------------------------------------------------------
classify_steps() {
  local json="$1" total verdict

  total="$(printf '%s' "$json" | jq 'if type == "array" then length else -1 end' 2>/dev/null)"
  case "$total" in
    ''|*[!0-9-]*) total=-1 ;;
  esac

  if [ "$total" -lt 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: could not parse the jobs payload as a JSON array — step-level signal NOT READ" >&2
    return "$EXIT_UNKNOWN"
  fi

  if [ "$total" -eq 0 ]; then
    printf 'unknown\n'
    echo "assert-ci-green: the run reported 0 jobs — step-level signal NOT READ" >&2
    return "$EXIT_UNKNOWN"
  fi

  # Pre-guard default. Deliberately the permissive answer, so that deleting the
  # marker-delimited block below yields a mutant that reproduces the ORIGINAL
  # bug (every job reads as `executed`, so a path-filtered vacuous success reads
  # as green) rather than one that merely crashes. That is what makes the
  # negative control in scripts/tests/assert-ci-green.test.sh meaningful.
  verdict="executed"

  # --- BEGIN vacuous-steps guard (#1495) -- do not remove; see negative control
  # --- in scripts/tests/assert-ci-green.test.sh, which deletes this exact block
  # --- and asserts the mutant then reports `executed` for an all-steps-skipped
  # --- job (i.e. reintroduces the green-when-red path-filter bug).
  verdict="$(printf '%s' "$json" | jq -r "$RUNNER_STEP_JQ"'
    def concl: ((.conclusion // "") | ascii_downcase);
    def is_checkout:
      ((.name // "") | ascii_downcase) as $l
      | ($l | test("actions/checkout")) or ($l | test("^checkout( |$)"));

    [ .[]
      | [ (.steps // [])[] | select(is_runner_step | not) ] as $user
      | ([ $user[] | select(concl == "skipped") ] | length) as $skipped
      | ([ $user[] | select(concl != "" and concl != "skipped") ] | length) as $ran
      | ([ $user[] | select(is_checkout) | select(concl == "skipped") ] | length) as $checkout_skipped
      | { vacuous: ($skipped > 0 and ($skipped > $ran or $checkout_skipped > 0)),
          ran: $ran,
          size: ($user | length) }
    ]
    | ([ .[] | select(.vacuous) | .size ] | max) as $vacuous_size
    | if $vacuous_size == null then "executed"
      # #1564: a sibling that ran at least as many steps as the largest vacuous
      # job would have is substantive evidence about the tree.
      elif any(.[]; (.vacuous | not) and .ran > 0 and .ran >= $vacuous_size) then "executed"
      else "vacuous"
      end
  ' 2>/dev/null)"
  # --- END vacuous-steps guard (#1495) ---

  case "$verdict" in
    vacuous)
      printf 'vacuous\n'
      echo "assert-ci-green: at least one job reported a conclusion but every substantive step was skipped, and no sibling job executed substantively — NO SIGNAL" >&2
      return "$EXIT_UNPROVEN"
      ;;
    executed)
      printf 'executed\n'
      return "$EXIT_GREEN"
      ;;
    *)
      printf 'unknown\n'
      echo "assert-ci-green: could not classify the jobs payload — step-level signal NOT READ" >&2
      return "$EXIT_UNKNOWN"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Run-list projections feeding the step-level walk-back. Both mirror `classify`'s
# per-workflow / latest-completed-non-cancelled selection rule exactly, so the
# run the walk-back inspects is always the same run `classify` decided on.
# ---------------------------------------------------------------------------

# Emits one `<workflowName>\t<databaseId>\t<conclusion>` line per workflow, for
# the workflow's deciding run.
deciding_runs() {
  printf '%s' "$1" | jq -r '
    def wf_name: (.workflowName // .name // "(unnamed)");
    def sort_key: (.createdAt // .startedAt // "");
    group_by(wf_name)[]
    | [ .[]
        | select((.status // "") == "completed")
        | select(((.conclusion // "") | ascii_downcase) != "cancelled")
      ]
      | sort_by(sort_key)
      | if length == 0 then empty
        else (last | [ wf_name, ((.databaseId // "") | tostring), ((.conclusion // "") | ascii_downcase) ] | @tsv)
        end
  ' 2>/dev/null
}

# Emits `<databaseId>\t<conclusion>` for the given workflow's completed,
# non-cancelled runs OTHER than $3, newest first.
older_runs() {
  printf '%s' "$1" | jq -r --arg wf "$2" --arg skip "$3" '
    def wf_name: (.workflowName // .name // "(unnamed)");
    def sort_key: (.createdAt // .startedAt // "");
    [ .[]
      | select(wf_name == $wf)
      | select((.status // "") == "completed")
      | select(((.conclusion // "") | ascii_downcase) != "cancelled")
      | select(((.databaseId // "") | tostring) != $skip)
    ]
    | sort_by(sort_key)
    | reverse
    | .[]
    | [ ((.databaseId // "") | tostring), ((.conclusion // "") | ascii_downcase) ]
    | @tsv
  ' 2>/dev/null
}

# `</dev/null` matters: this runs inside `while read` loops fed by heredocs, and
# an unredirected gh would otherwise eat the loop's remaining input.
fetch_jobs() {
  gh run view "$2" --repo "$1" --json jobs --jq '.jobs' </dev/null 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step-level verification + walk-back (#1495). Called only when the run-level
# verdict was already `green`; a red or pending verdict needs no strengthening.
# Prints the refined verdict word on stdout and returns the matching exit code.
# ---------------------------------------------------------------------------
step_verify() {
  local repo="$1" json="$2" max_lookback="$3"
  local any_red=0 any_unproven=0
  local wf run_id concl jobs steps_word
  local found n oid oconcl ojobs oword

  while IFS=$'\t' read -r wf run_id concl; do
    [ -n "${run_id:-}" ] || continue

    jobs="$(fetch_jobs "$repo" "$run_id")"
    if [ -z "$jobs" ]; then
      echo "assert-ci-green: could not read jobs for run ${run_id} (${wf}) — step-level check skipped for this workflow; its run-level verdict is retained (see the fail-safe note at the top of this script)" >&2
      continue
    fi

    steps_word="$(classify_steps "$jobs" 2>/dev/null)"
    [ "$steps_word" = "vacuous" ] || continue

    echo "assert-ci-green: run ${run_id} ('${wf}') reported '${concl}' but every substantive step was SKIPPED — that success carries no evidence about the tree (#1495). Walking back for the last run that really executed…" >&2

    found=0
    n=0
    while IFS=$'\t' read -r oid oconcl; do
      [ -n "${oid:-}" ] || continue
      n=$((n + 1))
      if [ "$n" -gt "$max_lookback" ]; then
        echo "assert-ci-green: lookback limit (${max_lookback}) reached for '${wf}' without finding an executed run" >&2
        break
      fi
      ojobs="$(fetch_jobs "$repo" "$oid")"
      [ -n "$ojobs" ] || continue
      oword="$(classify_steps "$ojobs" 2>/dev/null)"
      [ "$oword" = "executed" ] || continue

      found=1
      case "$oconcl" in
        success|skipped|neutral)
          echo "assert-ci-green: the last run of '${wf}' that actually executed is ${oid} (${oconcl}) — '${wf}' resolves GREEN" >&2
          ;;
        *)
          echo "assert-ci-green: the last run of '${wf}' that actually executed is ${oid} (${oconcl}) — '${wf}' resolves RED, and that red is still live" >&2
          any_red=1
          ;;
      esac
      break
    done <<EOF
$(older_runs "$json" "$wf" "$run_id")
EOF

    if [ "$found" -eq 0 ]; then
      echo "assert-ci-green: no run of '${wf}' in the window actually executed its steps — UNPROVEN, NOT green" >&2
      any_unproven=1
    fi
  done <<EOF
$(deciding_runs "$json")
EOF

  if [ "$any_red" -eq 1 ]; then
    printf 'red\n'
    return "$EXIT_RED"
  fi
  if [ "$any_unproven" -eq 1 ]; then
    printf 'unproven\n'
    return "$EXIT_UNPROVEN"
  fi
  printf 'green\n'
  return "$EXIT_GREEN"
}

# ---------------------------------------------------------------------------
# Full-SHA resolution. `gh run list --commit` matches on the FULL 40-char SHA and
# silently returns an empty list for an abbreviated one — so resolving the ref is
# the script's job, not the caller's (#717).
# ---------------------------------------------------------------------------
resolve_full_sha() {
  local ref="$1" full

  # Already a full SHA — use it as-is (it may be a commit this clone doesn't have,
  # e.g. a merge commit from a PR merged server-side and not yet fetched).
  if printf '%s' "$ref" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s' "$ref" | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  full="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)"
  if printf '%s' "$full" | grep -Eq '^[0-9a-f]{40}$'; then
    printf '%s' "$full"
    return 0
  fi

  return 1
}

usage() {
  cat >&2 <<'EOF'
usage: assert-ci-green.sh <owner/repo> --commit <ref>  [--limit N] [--max-lookback N] [--no-step-check]
       assert-ci-green.sh <owner/repo> --branch <name> [--limit N] [--max-lookback N] [--no-step-check]
       assert-ci-green.sh --classify <json-array|->
       assert-ci-green.sh --classify-steps <jobs-json-array|->
       assert-ci-green.sh --help

exit: 0 green | 1 red | 2 unknown (NOT VERIFIED) | 3 pending | 4 unproven (NOT VERIFIED)
       (--help is the sole exception: it always exits 0, regardless of the
       green/red/pending vocabulary above, matching the -h/--help exit-0
       convention every other scripts/*.sh usage() block honors — #1550.)
EOF
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  if [ "${1:-}" = "--classify" ]; then
    local payload="${2:-}"
    if [ -z "$payload" ]; then usage; exit "$EXIT_UNKNOWN"; fi
    if [ "$payload" = "-" ]; then payload="$(cat)"; fi
    classify "$payload"
    exit $?
  fi

  if [ "${1:-}" = "--classify-steps" ]; then
    local jobs_payload="${2:-}"
    if [ -z "$jobs_payload" ]; then usage; exit "$EXIT_UNKNOWN"; fi
    if [ "$jobs_payload" = "-" ]; then jobs_payload="$(cat)"; fi
    classify_steps "$jobs_payload"
    exit $?
  fi

  local repo="${1:-}"
  shift || true
  if [ -z "$repo" ] || [ "$#" -eq 0 ]; then usage; exit "$EXIT_UNKNOWN"; fi

  local mode="" target="" limit=60 max_lookback=5 step_check=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit) mode="commit"; target="${2:-}"; shift 2 || true ;;
      --branch) mode="branch"; target="${2:-}"; shift 2 || true ;;
      --limit)  limit="${2:-60}";              shift 2 || true ;;
      --max-lookback) max_lookback="${2:-5}";  shift 2 || true ;;
      --no-step-check) step_check=0;           shift    || true ;;
      *) usage; exit "$EXIT_UNKNOWN" ;;
    esac
  done

  if [ -z "$mode" ] || [ -z "$target" ]; then usage; exit "$EXIT_UNKNOWN"; fi
  case "$limit" in ''|*[!0-9]*) limit=60 ;; esac
  case "$max_lookback" in ''|*[!0-9]*) max_lookback=5 ;; esac

  local json
  if [ "$mode" = "commit" ]; then
    local sha
    if ! sha="$(resolve_full_sha "$target")"; then
      printf 'unknown\n'
      echo "assert-ci-green: could not resolve '${target}' to a full 40-char SHA — NOT VERIFIED." >&2
      echo "  \`gh run list --commit\` matches ONLY on the full SHA; an abbreviated SHA silently" >&2
      echo "  matches zero runs, which a naive 'failures == 0' check would read as green (#717)." >&2
      echo "  Pass a full SHA (\`git rev-parse HEAD\`, never \`--short\`) or a resolvable git ref." >&2
      exit "$EXIT_UNKNOWN"
    fi
    echo "assert-ci-green: repo=${repo} commit=${sha} (full SHA)" >&2
    json="$(gh run list --repo "$repo" --commit "$sha" --limit "$limit" \
      --json workflowName,name,status,conclusion,createdAt,databaseId 2>/dev/null)"
  else
    echo "assert-ci-green: repo=${repo} branch=${target}" >&2
    # Do NOT pass --status completed: it hides in-progress workflows, which would
    # let a still-running required workflow read as "nothing red here" (4.5a).
    json="$(gh run list --repo "$repo" --branch "$target" --limit "$limit" \
      --json workflowName,name,status,conclusion,createdAt,databaseId 2>/dev/null)"
  fi

  if [ -z "$json" ]; then
    printf 'unknown\n'
    echo "assert-ci-green: the gh run list call returned nothing — NOT VERIFIED" >&2
    exit "$EXIT_UNKNOWN"
  fi

  # `classify`'s stdout is captured (so the word is printed exactly once, below);
  # its stderr passes straight through as the human-readable explanation.
  local verdict_word verdict_code
  verdict_word="$(classify "$json")"
  verdict_code=$?

  # #1495: a run-level `green` is only provisional until we confirm the deciding
  # run actually executed its steps. Red / pending / unknown need no
  # strengthening — they are already not-green.
  if [ "$verdict_code" -eq "$EXIT_GREEN" ] && [ "$step_check" -eq 1 ]; then
    verdict_word="$(step_verify "$repo" "$json" "$max_lookback")"
    verdict_code=$?
  fi

  printf '%s\n' "$verdict_word"
  exit "$verdict_code"
}

main "$@"
