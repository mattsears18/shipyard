#!/usr/bin/env bash
# Test: the vacuous-CI-pass guard (issue #717).
#
# Background — issue #717: `gh run list --commit <sha>` matches ONLY on a full
# 40-char SHA. An abbreviated SHA silently matches ZERO runs, so a verification
# shaped as "count the non-success runs, assert the count is 0" **passes on the
# empty set** — reporting green while having observed nothing at all. It converts
# "I could not verify" into "verified green", the dangerous direction.
#
# This suite pins both halves of the fix in `scripts/assert-ci-green.sh`:
#
#   1. An empty run list is `unknown` (exit 2), NEVER green.
#   2. A `--commit <ref>` is resolved to the FULL SHA before it reaches gh, so a
#      caller passing `HEAD` / a short SHA cannot reintroduce the zero-match trap.
#
# ...plus the per-workflow / latest-run classification the verdict rides on, and
# the doc call-sites that tell workers to use the script.
#
# NEGATIVE CONTROL (the load-bearing test). Per #717's own guidance — "any new
# guard you add should be negative-controlled: prove the test fails when the
# guard is removed" — test 9 deletes the marker-delimited empty-set guard from a
# COPY of the script and asserts the mutant then reports **green** on an empty run
# list. If the guard ever stops being load-bearing (someone reimplements the
# emptiness check elsewhere, or deletes the markers), that test fails loudly. A
# test that passes both with and without the fix would itself be an instance of
# the very bug this file is about.
#
# Pure bash + jq + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-ci-green.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

script="$repo_root/plugins/shipyard/scripts/assert-ci-green.sh"
ci_pitfalls="$repo_root/plugins/shipyard/skills/worker-preamble/ci-pitfalls.md"
fix_main_ci="$repo_root/plugins/shipyard/agents/issue-worker/fix-main-ci.md"
# The step-4.5a `main_ci` aggregation lives in one of do-work/setup/'s fragments.
# Scan ACROSS the fragment set rather than naming one file: a router/fragment
# split can relocate the prose without changing its meaning, and a hardcoded
# fragment path would then red in CI with no local warning (issue #1453).
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()   { pass=$((pass + 1)); echo "${GREEN}PASS${RESET}: $1"; }
bad()  { fail=$((fail + 1)); echo "${RED}FAIL${RESET}: $1"; }

# Run `<script> --classify <json>` and assert the verdict word + exit code.
expect_classify() {
  local json="$1" want_word="$2" want_code="$3" desc="$4"
  local got_word got_code
  got_word="$(bash "$script" --classify "$json" 2>/dev/null)"
  got_code=$?
  if [[ "$got_word" == "$want_word" && "$got_code" -eq "$want_code" ]]; then
    ok "$desc"
  else
    bad "$desc (want '${want_word}'/${want_code}, got '${got_word}'/${got_code})"
  fi
}

run() { local d="$1"; shift; echo; echo "--- $d"; "$@"; }

if [[ ! -x "$script" && ! -f "$script" ]]; then
  echo "FAIL: $script not found" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. THE BUG: an empty run list is `unknown`, never green.
# ---------------------------------------------------------------------------
run "1. empty run list => unknown (NOT green)"
expect_classify '[]' unknown 2 "an empty run list classifies as unknown, exit 2"

# The precise shape of the #717 footgun: a caller that only asks "how many
# non-success runs are there?" gets 0 from an empty list. Confirm the script does
# NOT answer green for that input — the count is meaningless on an empty set.
if [[ "$(printf '%s' '[]' | jq '[.[] | select(.conclusion != "success")] | length')" == "0" ]]; then
  ok "sanity: the naive 'failures == 0' predicate DOES report 0 on an empty list (the bug it must not be trusted on)"
else
  bad "sanity: naive predicate did not behave as documented"
fi

# ---------------------------------------------------------------------------
# 2-8. Classification over a non-empty set.
# ---------------------------------------------------------------------------
run "2. all workflows green => green"
expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"},
  {"workflowName":"Shell","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"}
]' green 0 "every workflow's latest completed run passed => green, exit 0"

run "3. one workflow red => red"
expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"failure","createdAt":"2026-07-11T10:00:00Z"},
  {"workflowName":"Shell","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"}
]' red 1 "a failing workflow => red, exit 1"

run "4. nothing completed yet => pending (NOT green)"
expect_classify '[
  {"workflowName":"Tests","status":"in_progress","conclusion":null,"createdAt":"2026-07-11T10:00:00Z"}
]' pending 3 "runs matched but no completed verdict => pending, exit 3"

run "5. latest run per workflow wins (stale FAILURE superseded by SUCCESS)"
expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"failure","createdAt":"2026-07-11T09:00:00Z"},
  {"workflowName":"Tests","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"}
]' green 0 "a re-run that now passes is not mis-read as failing (#333)"

run "6. cancelled runs are skipped over, not treated as a verdict"
expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"cancelled","createdAt":"2026-07-11T10:00:00Z"},
  {"workflowName":"Tests","status":"completed","conclusion":"success","createdAt":"2026-07-11T09:00:00Z"}
]' green 0 "a supersession-cancelled newest run falls back to the last real verdict (#261)"

expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"cancelled","createdAt":"2026-07-11T10:00:00Z"}
]' pending 3 "a workflow whose ONLY completed run was cancelled => pending, never green"

run "7. a green workflow does not mask a pending sibling"
expect_classify '[
  {"workflowName":"Tests","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"},
  {"workflowName":"Shell","status":"queued","conclusion":null,"createdAt":"2026-07-11T10:00:00Z"}
]' pending 3 "per-workflow aggregation: one green + one pending => pending (#333 / 4.5a)"

run "8. an unreadable payload is unknown, never green"
expect_classify 'null' unknown 2 "a non-array payload => unknown, exit 2"
expect_classify 'not json at all' unknown 2 "garbage => unknown, exit 2"

# ---------------------------------------------------------------------------
# 9. NEGATIVE CONTROL — prove the empty-set guard is what prevents the vacuous
#    pass. Delete the marker-delimited guard block from a copy of the script and
#    assert the mutant reports GREEN on an empty run list.
#
#    If this test fails, either (a) the markers moved/vanished, or (b) removing
#    the guard changed nothing — meaning the real test above would pass even with
#    the bug present, i.e. it is not actually testing anything.
# ---------------------------------------------------------------------------
run "9. NEGATIVE CONTROL: removing the empty-set guard reintroduces the vacuous pass"

tmp_mutant="$(mktemp -t assert-ci-green-mutant.XXXXXX)"
trap 'rm -f "$tmp_mutant"' EXIT

if ! grep -q 'BEGIN empty-set guard (#717)' "$script" || ! grep -q 'END empty-set guard (#717)' "$script"; then
  bad "the empty-set guard markers are missing from $script — the negative control cannot run"
else
  sed '/BEGIN empty-set guard (#717)/,/END empty-set guard (#717)/d' "$script" > "$tmp_mutant"

  if [[ "$(wc -l < "$tmp_mutant")" -ge "$(wc -l < "$script")" ]]; then
    bad "the mutant is not smaller than the original — the guard block was not removed"
  else
    mutant_word="$(bash "$tmp_mutant" --classify '[]' 2>/dev/null)"
    mutant_code=$?
    if [[ "$mutant_word" == "green" && "$mutant_code" -eq 0 ]]; then
      ok "guard-removed mutant vacuously reports green on an empty run list => the guard is load-bearing"
    else
      bad "guard-removed mutant returned '${mutant_word}'/${mutant_code}, expected 'green'/0 — the test above is not actually gated on the guard"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 10. Full-SHA enforcement: a short SHA / ref must reach gh as a FULL 40-char SHA.
# ---------------------------------------------------------------------------
run "10. --commit resolves to the full 40-char SHA before calling gh"

tmp_repo="$(mktemp -d -t assert-ci-green-repo.XXXXXX)"
tmp_bin="$(mktemp -d -t assert-ci-green-bin.XXXXXX)"
trap 'rm -f "$tmp_mutant"; rm -rf "$tmp_repo" "$tmp_bin"' EXIT

# A fake `gh` that records the args it was handed and returns one green run.
cat > "$tmp_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_ARGS"
printf '%s' '[{"workflowName":"Tests","status":"completed","conclusion":"success","createdAt":"2026-07-11T10:00:00Z"}]'
STUB
chmod +x "$tmp_bin/gh"

(
  cd "$tmp_repo" || exit 1
  git init -q .
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m "seed"
) >/dev/null 2>&1

full_sha="$(git -C "$tmp_repo" rev-parse HEAD)"
short_sha="$(git -C "$tmp_repo" rev-parse --short HEAD)"
stub_args="$tmp_repo/gh-args.txt"

verdict="$(cd "$tmp_repo" && GH_STUB_ARGS="$stub_args" PATH="$tmp_bin:$PATH" \
  bash "$script" owner/repo --commit "$short_sha" 2>/dev/null)"
verdict_code=$?

if [[ "$verdict" == "green" && "$verdict_code" -eq 0 ]]; then
  ok "a resolvable short SHA yields a real verdict (green) rather than a zero-match"
else
  bad "short-SHA run returned '${verdict}'/${verdict_code}, expected 'green'/0"
fi

if grep -q -- "--commit ${full_sha}" "$stub_args" 2>/dev/null; then
  ok "gh received the FULL 40-char SHA (${full_sha:0:12}...), not the short one (${short_sha})"
else
  bad "gh did NOT receive the full SHA — got: $(cat "$stub_args" 2>/dev/null)"
fi

if grep -q -- "--commit ${short_sha} " "$stub_args" 2>/dev/null; then
  bad "gh was handed the ABBREVIATED SHA — this is exactly the #717 zero-match footgun"
else
  ok "gh was never handed an abbreviated SHA"
fi

# An unresolvable ref must be `unknown` — and must never reach gh at all.
: > "$stub_args"
unres="$(cd "$tmp_repo" && GH_STUB_ARGS="$stub_args" PATH="$tmp_bin:$PATH" \
  bash "$script" owner/repo --commit deadbeef 2>/dev/null)"
unres_code=$?
if [[ "$unres" == "unknown" && "$unres_code" -eq 2 ]]; then
  ok "an unresolvable ref => unknown, exit 2 (never green)"
else
  bad "unresolvable ref returned '${unres}'/${unres_code}, expected 'unknown'/2"
fi
if [[ ! -s "$stub_args" ]]; then
  ok "an unresolvable ref short-circuits before the gh call"
else
  bad "an unresolvable ref still called gh: $(cat "$stub_args")"
fi

# A full SHA is passed through as-is (it may name a commit this clone lacks —
# e.g. a server-side merge commit — so it must NOT require local resolution).
: > "$stub_args"
absent_sha="0123456789abcdef0123456789abcdef01234567"
away="$(cd "$tmp_bin" && GH_STUB_ARGS="$stub_args" PATH="$tmp_bin:$PATH" \
  bash "$script" owner/repo --commit "$absent_sha" 2>/dev/null)"
if [[ "$away" == "green" ]] && grep -q -- "--commit ${absent_sha}" "$stub_args"; then
  ok "a full SHA absent from the local clone is passed through to gh unchanged"
else
  bad "full-SHA passthrough failed: verdict='${away}', args=$(cat "$stub_args" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 11. --branch mode must not filter --status completed (it would hide in-progress
#     workflows, letting a still-running required workflow read as "nothing red").
# ---------------------------------------------------------------------------
run "11. --branch mode does not filter --status completed"
: > "$stub_args"
(cd "$tmp_repo" && GH_STUB_ARGS="$stub_args" PATH="$tmp_bin:$PATH" \
  bash "$script" owner/repo --branch main >/dev/null 2>&1)
if grep -q -- "--branch main" "$stub_args" && ! grep -q -- "--status completed" "$stub_args"; then
  ok "branch mode queries all statuses (no --status completed filter)"
else
  bad "branch-mode gh args were: $(cat "$stub_args" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 12. Doc call-sites: the rule and the helper must be reachable from the specs
#     that perform CI verification.
# ---------------------------------------------------------------------------
run "12. doc call-sites reference the guard + the helper"

assert_contains() {
  local file="$1" needle="$2" desc="$3"
  if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
    ok "$desc"
  else
    bad "$desc (missing '${needle}' in ${file#"$repo_root"/})"
  fi
}

assert_contains "$ci_pitfalls" "assert-ci-green.sh" \
  "worker-preamble ci-pitfalls.md names the shared helper"
assert_contains "$ci_pitfalls" "717" \
  "worker-preamble ci-pitfalls.md cites issue #717"
assert_contains "$fix_main_ci" "assert-ci-green.sh" \
  "fix-main-ci.md's green-main pre-flight uses the shared helper"

# ===========================================================================
# #1495 — the SECOND vacuous shape: a run whose required job reported `success`
# with every substantive step `skipped` by a path filter. Zero tests ran, so the
# success carries no evidence about the tree, yet `conclusion` cannot say so.
# ===========================================================================

# Run `<script> --classify-steps <jobs-json>` and assert the word + exit code.
expect_steps() {
  local json="$1" want_word="$2" want_code="$3" desc="$4"
  local got_word got_code
  got_word="$(bash "$script" --classify-steps "$json" 2>/dev/null)"
  got_code=$?
  if [[ "$got_word" == "$want_word" && "$got_code" -eq "$want_code" ]]; then
    ok "$desc"
  else
    bad "$desc (want '${want_word}'/${want_code}, got '${got_word}'/${got_code})"
  fi
}

# The exact job shape from #1495's repro: guard steps succeed, checkout and every
# test step is skipped, the runner's own bookkeeping succeeds.
jobs_vacuous='[{"name":"Unit Tests","conclusion":"success","steps":[
  {"number":1,"name":"Set up job","conclusion":"success"},
  {"number":2,"name":"Require detect-paths to complete","conclusion":"success"},
  {"number":3,"name":"Skip on docs-only changes","conclusion":"success"},
  {"number":4,"name":"Run actions/checkout@v7.0.1","conclusion":"skipped"},
  {"number":12,"name":"Unit tests - meta (config/process)","conclusion":"skipped"},
  {"number":13,"name":"Unit tests - product (web + native)","conclusion":"skipped"},
  {"number":14,"name":"Cloud Functions tests","conclusion":"skipped"},
  {"number":19,"name":"Complete job","conclusion":"success"}]}]'

jobs_executed='[{"name":"Unit Tests","conclusion":"success","steps":[
  {"number":1,"name":"Set up job","conclusion":"success"},
  {"number":2,"name":"Run actions/checkout@v7.0.1","conclusion":"success"},
  {"number":3,"name":"Install deps","conclusion":"success"},
  {"number":4,"name":"Unit tests","conclusion":"success"},
  {"number":5,"name":"Upload failure artifacts","conclusion":"skipped"},
  {"number":6,"name":"Post Run actions/checkout@v7.0.1","conclusion":"success"},
  {"number":7,"name":"Complete job","conclusion":"success"}]}]'

run "13. --classify-steps: the path-filtered vacuous success is detected"
expect_steps "$jobs_vacuous" vacuous 4 \
  "a job whose checkout + every test step was skipped => vacuous, exit 4 (#1495)"
expect_steps "$jobs_executed" executed 0 \
  "a job that really ran => executed, exit 0 (a trailing if:failure() skip is not vacuity)"

# Per-JOB granularity is load-bearing: in #1495's repro the `detect-paths` job ran
# for real while the required test job skipped everything. A "were ALL jobs
# vacuous?" rule would have missed the bug entirely.
expect_steps '[{"name":"detect-paths","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Compute changed paths","conclusion":"success"},
    {"number":3,"name":"Complete job","conclusion":"success"}]},
  {"name":"Unit Tests","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Run actions/checkout@v7.0.1","conclusion":"skipped"},
    {"number":3,"name":"Unit tests","conclusion":"skipped"},
    {"number":4,"name":"Complete job","conclusion":"success"}]}]' vacuous 4 \
  "one real job does not launder a sibling job that skipped everything"

# #1564 — the lightwork shape: ONE path-scoped sibling job (`🧹 Lint (marketing)`,
# gated on apps/marketing/** via dorny/paths-filter) skips its install/lint/test
# steps on every non-marketing commit, while the jobs that carry evidence about
# the tree (Lint & Typecheck, Unit Tests, Web E2E) all run their steps in full.
# The pre-#1564 "any job vacuous => run vacuous" rule read EVERY such run as
# vacuous, pinned main_ci to unknown, and silently disabled the fix-main-ci divert.
jobs_lightwork='[
  {"name":"🔍 Detect changed paths","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Run actions/checkout@v4","conclusion":"success"},
    {"number":3,"name":"Run dorny/paths-filter@v3","conclusion":"success"},
    {"number":4,"name":"Post Run actions/checkout@v4","conclusion":"success"},
    {"number":5,"name":"Complete job","conclusion":"success"}]},
  {"name":"🧪 Unit Tests","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Run actions/checkout@v4","conclusion":"success"},
    {"number":3,"name":"Setup node","conclusion":"success"},
    {"number":4,"name":"Install deps","conclusion":"success"},
    {"number":5,"name":"Unit tests - web","conclusion":"success"},
    {"number":6,"name":"Unit tests - native","conclusion":"success"},
    {"number":7,"name":"Cloud Functions tests","conclusion":"success"},
    {"number":8,"name":"Upload coverage","conclusion":"success"},
    {"number":9,"name":"Upload failure artifacts","conclusion":"skipped"},
    {"number":10,"name":"Complete job","conclusion":"success"}]},
  {"name":"🧹 Lint (marketing)","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Skip on non-marketing changes","conclusion":"success"},
    {"number":3,"name":"Run actions/checkout@v4","conclusion":"skipped"},
    {"number":4,"name":"Setup node","conclusion":"skipped"},
    {"number":5,"name":"Install deps","conclusion":"skipped"},
    {"number":6,"name":"Lint","conclusion":"skipped"},
    {"number":7,"name":"Typecheck","conclusion":"skipped"},
    {"number":8,"name":"Complete job","conclusion":"success"}]}]'

run "13b. #1564: a path-scoped sibling skip does not sink a run whose substantive jobs executed"
expect_steps "$jobs_lightwork" executed 0 \
  "lightwork shape (path-scoped sibling skipped, Unit Tests ran 7 steps) => executed, exit 0 (#1564)"

# The original #1495 shape at realistic size: detect-paths checks out and runs a
# few steps, but the test job that would have run far more skipped everything.
# detect-paths is NOT substantive against it, so the run stays vacuous.
expect_steps '[
  {"name":"detect-paths","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Run actions/checkout@v4","conclusion":"success"},
    {"number":3,"name":"Run dorny/paths-filter@v3","conclusion":"success"},
    {"number":4,"name":"Complete job","conclusion":"success"}]},
  {"name":"🧪 Unit Tests","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Require detect-paths to complete","conclusion":"success"},
    {"number":3,"name":"Skip on docs-only changes","conclusion":"success"},
    {"number":4,"name":"Run actions/checkout@v4","conclusion":"skipped"},
    {"number":5,"name":"Setup node","conclusion":"skipped"},
    {"number":6,"name":"Install deps","conclusion":"skipped"},
    {"number":7,"name":"Unit tests - meta","conclusion":"skipped"},
    {"number":8,"name":"Unit tests - product","conclusion":"skipped"},
    {"number":9,"name":"Cloud Functions tests","conclusion":"skipped"},
    {"number":10,"name":"Complete job","conclusion":"success"}]}]' vacuous 4 \
  "#1495 shape (required test job skipped everything, only detect-paths ran) => still vacuous, exit 4"

# A vacuous job whose only "executed" sibling is itself mostly skipped does not
# count: substantive means a NON-vacuous sibling.
expect_steps '[
  {"name":"A","conclusion":"success","steps":[
    {"number":1,"name":"Run actions/checkout@v4","conclusion":"skipped"},
    {"number":2,"name":"Lint","conclusion":"skipped"}]},
  {"name":"B","conclusion":"success","steps":[
    {"number":1,"name":"Gate","conclusion":"success"},
    {"number":2,"name":"Gate 2","conclusion":"success"},
    {"number":3,"name":"Gate 3","conclusion":"success"},
    {"number":4,"name":"Run actions/checkout@v4","conclusion":"skipped"},
    {"number":5,"name":"Tests","conclusion":"skipped"}]}]' vacuous 4 \
  "two vacuous jobs cannot launder each other, however many gate steps they ran"

# An ordinary job-level `if:` skip reports conclusion=skipped with no step detail.
# It never claimed to have run, so there is no false success to catch.
expect_steps '[{"name":"deploy","conclusion":"skipped","steps":[]},
  {"name":"Unit Tests","conclusion":"success","steps":[
    {"number":1,"name":"Set up job","conclusion":"success"},
    {"number":2,"name":"Run actions/checkout@v4","conclusion":"success"},
    {"number":3,"name":"Unit tests","conclusion":"success"},
    {"number":4,"name":"Complete job","conclusion":"success"}]}]' executed 0 \
  "a job-level skip with no steps is not vacuity (no false success to catch)"

expect_steps '[]' unknown 2 "a run reporting 0 jobs => unknown, never executed"
expect_steps 'not json'  unknown 2 "an unreadable jobs payload => unknown, never executed"

# ---------------------------------------------------------------------------
# 14-17. Live mode: a vacuous newest run must not read as green — walk back to
#        the last run that actually executed and use THAT verdict.
# ---------------------------------------------------------------------------
tmp_live="$(mktemp -d -t assert-ci-green-live.XXXXXX)"
trap 'rm -f "$tmp_mutant"; rm -rf "$tmp_repo" "$tmp_bin" "$tmp_live"' EXIT

mkdir -p "$tmp_live/bin" "$tmp_live/jobs"

# A `gh` stub that dispatches on the subcommand: `run list` serves the run-list
# fixture, `run view <id>` serves that run's jobs fixture (or fails if absent,
# exercising the unreadable-jobs fallback).
cat > "$tmp_live/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_ARGS"
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  cat "$GH_STUB_RUNS"
  exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "view" ]]; then
  f="$GH_STUB_JOBS_DIR/${3:-}.json"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_live/bin/gh"

# Three completed `Tests` runs, newest first by createdAt. All three report
# `success` at the RUN level — the run list alone cannot tell them apart.
cat > "$tmp_live/runs.json" <<'JSON'
[
 {"workflowName":"Tests","databaseId":300,"status":"completed","conclusion":"success","createdAt":"2026-08-20T03:00:00Z"},
 {"workflowName":"Tests","databaseId":200,"status":"completed","conclusion":"failure","createdAt":"2026-08-20T02:00:00Z"},
 {"workflowName":"Tests","databaseId":100,"status":"completed","conclusion":"success","createdAt":"2026-08-20T01:00:00Z"}
]
JSON

printf '%s' "$jobs_vacuous"  > "$tmp_live/jobs/300.json"
printf '%s' "$jobs_executed" > "$tmp_live/jobs/200.json"
printf '%s' "$jobs_executed" > "$tmp_live/jobs/100.json"

live_args="$tmp_live/gh-args.txt"

# Run the script in live --branch mode against the stub. $1 = script path,
# remaining args are appended. Sets `live_word` / `live_code`.
run_live() {
  local s="$1"; shift
  : > "$live_args"
  live_word="$(GH_STUB_ARGS="$live_args" GH_STUB_RUNS="$tmp_live/runs.json" \
    GH_STUB_JOBS_DIR="$tmp_live/jobs" PATH="$tmp_live/bin:$PATH" \
    bash "$s" owner/repo --branch main "$@" 2>/dev/null)"
  live_code=$?
}

run "14. THE BUG: a vacuous newest run does not read as green — walk back finds the live red"
run_live "$script"
if [[ "$live_word" == "red" && "$live_code" -eq 1 ]]; then
  ok "newest run success-but-vacuous, last executed run failed => red, exit 1 (#1495)"
else
  bad "expected 'red'/1, got '${live_word}'/${live_code}"
fi

# Sanity: the run-level classifier ALONE (the pre-#1495 answer) says green here.
# If it didn't, test 14 would be passing for the wrong reason.
expect_classify "$(cat "$tmp_live/runs.json")" green 0 \
  "sanity: the run-level verdict on this fixture is green (the false-green #1495 reports)"

run "15. walk-back that lands on a real success resolves green"
printf '%s' "$jobs_executed" > "$tmp_live/jobs/200.json"
cat > "$tmp_live/runs.json" <<'JSON'
[
 {"workflowName":"Tests","databaseId":300,"status":"completed","conclusion":"success","createdAt":"2026-08-20T03:00:00Z"},
 {"workflowName":"Tests","databaseId":200,"status":"completed","conclusion":"success","createdAt":"2026-08-20T02:00:00Z"}
]
JSON
run_live "$script"
if [[ "$live_word" == "green" && "$live_code" -eq 0 ]]; then
  ok "vacuous newest run + executed green predecessor => green, exit 0"
else
  bad "expected 'green'/0, got '${live_word}'/${live_code}"
fi

run "16. nothing in the window executed => unproven (exit 4), never green"
printf '%s' "$jobs_vacuous" > "$tmp_live/jobs/200.json"
run_live "$script"
if [[ "$live_word" == "unproven" && "$live_code" -eq 4 ]]; then
  ok "every run in the window vacuous => unproven, exit 4 — NOT VERIFIED, not green"
else
  bad "expected 'unproven'/4, got '${live_word}'/${live_code}"
fi

run "16b. #1564: a window of lightwork-shaped runs resolves green, not unproven"
printf '%s' "$jobs_lightwork" > "$tmp_live/jobs/300.json"
printf '%s' "$jobs_lightwork" > "$tmp_live/jobs/200.json"
run_live "$script"
if [[ "$live_word" == "green" && "$live_code" -eq 0 ]]; then
  ok "every run has only a path-scoped sibling skip => green, exit 0 (fix-main-ci divert stays live)"
else
  bad "expected 'green'/0 for lightwork-shaped runs, got '${live_word}'/${live_code}"
fi
printf '%s' "$jobs_vacuous" > "$tmp_live/jobs/300.json"
printf '%s' "$jobs_vacuous" > "$tmp_live/jobs/200.json"

run "17. --no-step-check restores the pre-#1495 run-level-only behaviour"
run_live "$script" --no-step-check
if [[ "$live_word" == "green" && "$live_code" -eq 0 ]]; then
  ok "--no-step-check opts out of the extra gh calls (and back into the weaker verdict)"
else
  bad "expected 'green'/0 with --no-step-check, got '${live_word}'/${live_code}"
fi
if ! grep -q "run view" "$live_args"; then
  ok "--no-step-check makes no gh run view calls at all"
else
  bad "--no-step-check still called gh run view: $(cat "$live_args")"
fi

run "18. an unreadable jobs payload retains the run-level verdict (documented fail-safe carve-out)"
rm -f "$tmp_live/jobs/300.json" "$tmp_live/jobs/200.json"
run_live "$script"
if [[ "$live_word" == "green" && "$live_code" -eq 0 ]]; then
  ok "a failing gh run view does not degrade an observed completed run to unproven"
else
  bad "expected 'green'/0 when job detail is unreadable, got '${live_word}'/${live_code}"
fi

# ---------------------------------------------------------------------------
# 19. NEGATIVE CONTROL — prove the vacuous-steps guard is what prevents the
#     path-filtered false green. Delete the marker-delimited block from a copy
#     and assert the mutant reports `executed` for an all-skipped job, and
#     `green` for a branch whose every run was vacuous.
# ---------------------------------------------------------------------------
run "19. NEGATIVE CONTROL: removing the vacuous-steps guard reintroduces the false green"

tmp_mutant2="$(mktemp -t assert-ci-green-mutant2.XXXXXX)"
trap 'rm -f "$tmp_mutant" "$tmp_mutant2"; rm -rf "$tmp_repo" "$tmp_bin" "$tmp_live"' EXIT

if ! grep -q 'BEGIN vacuous-steps guard (#1495)' "$script" || ! grep -q 'END vacuous-steps guard (#1495)' "$script"; then
  bad "the vacuous-steps guard markers are missing from $script — the negative control cannot run"
else
  sed '/BEGIN vacuous-steps guard (#1495)/,/END vacuous-steps guard (#1495)/d' "$script" > "$tmp_mutant2"

  if [[ "$(wc -l < "$tmp_mutant2")" -ge "$(wc -l < "$script")" ]]; then
    bad "the mutant is not smaller than the original — the guard block was not removed"
  else
    m_word="$(bash "$tmp_mutant2" --classify-steps "$jobs_vacuous" 2>/dev/null)"
    m_code=$?
    if [[ "$m_word" == "executed" && "$m_code" -eq 0 ]]; then
      ok "guard-removed mutant reads an all-skipped job as 'executed' => the guard is load-bearing"
    else
      bad "guard-removed mutant returned '${m_word}'/${m_code}, expected 'executed'/0 — test 13 is not actually gated on the guard"
    fi

    # And end-to-end: the mutant reports the branch green even though every run
    # in the window was a vacuous, path-filtered skip. That is the #1495 bug.
    printf '%s' "$jobs_vacuous" > "$tmp_live/jobs/300.json"
    printf '%s' "$jobs_vacuous" > "$tmp_live/jobs/200.json"
    run_live "$tmp_mutant2"
    if [[ "$live_word" == "green" && "$live_code" -eq 0 ]]; then
      ok "guard-removed mutant reports GREEN for a branch whose every run was vacuous (the #1495 false green)"
    else
      bad "guard-removed mutant returned '${live_word}'/${live_code} end-to-end, expected 'green'/0"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 20. Doc call-sites for the new verdict.
# ---------------------------------------------------------------------------
run "20. doc call-sites cover the unproven verdict"

assert_contains "$fix_main_ci" "unproven" \
  "fix-main-ci.md's pre-flight documents the unproven (exit 4) branch"
assert_contains "$fix_main_ci" "1495" \
  "fix-main-ci.md cites issue #1495"
assert_setup_contains() {
  local needle="$1" desc="$2"
  if find "$setup_dir" -type f -name '*.md' -exec grep -qF -- "$needle" {} + 2>/dev/null; then
    ok "$desc"
  else
    bad "$desc (no do-work/setup/*.md fragment contains '${needle}')"
  fi
}

assert_setup_contains "unproven" \
  "do-work/setup's 4.5a aggregation carries the unproven per-workflow state"
assert_setup_contains "1495" \
  "do-work/setup's 4.5a aggregation cites issue #1495"
assert_contains "$ci_pitfalls" "1495" \
  "worker-preamble ci-pitfalls.md cites issue #1495"

echo
echo "-----------------------------------------"
echo "${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ "$fail" -eq 0 ]] || exit 1
