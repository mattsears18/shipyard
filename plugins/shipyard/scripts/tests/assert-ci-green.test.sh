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

echo
echo "-----------------------------------------"
echo "${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ "$fail" -eq 0 ]] || exit 1
