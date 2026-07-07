#!/usr/bin/env bash
# Test: the version-coordination next-available-version computation is
# bump-type-aware (issue #671).
#
# Background — issue #671: the per-dispatch next-available-version computation
# in dispatch-rules.md (and the parallel A.0.5 crash-recovery bump in
# steady-state.md, #575) only ever computed a PATCH bump
# (next = max_inflight + 1 on the Z segment). It was blind to issues that
# explicitly require a MAJOR (breaking) or MINOR (feature) bump. On a
# version-coordinated repo that cuts a release per PR (shipyard itself), the
# injected "Next-available version (orchestrator-supplied): use this exact
# value" paragraph then CONTRADICTED the issue body's stated version intent,
# handing the worker two conflicting instructions. Repro (the #659 epic's
# shards, main 1.27.1): #661 declared MAJOR (→2.0.0) but the formula would have
# injected 1.27.2 (patch); #662/#663/#665 were features (minor → 2.1.0/2.2.0/
# 2.3.0) but the formula injected patch; only #664 (perf → patch) was right.
#
# The fix makes the computation infer the bump LEVEL from the issue's
# Conventional Commits title/body and compute the next free slot at THAT level,
# while the version_cursor still advances to the EXACT computed value so a batch
# of N dispatches stays monotonic (collision-avoidance guarantee preserved).
# The injected paragraph is weakened from "use this exact value" to a floor +
# recommended-slot form that leaves the semver level to the worker.
#
# This test pins TWO layers:
#   (A) Spec assertions — the bump-type-aware logic + #671 references + the
#       weakened floor/level paragraph exist in dispatch-rules.md, and the
#       a05_version_bump helper in steady-state.md carries the same inference.
#   (B) Behavioral — replicate the inference + level-aware bump + cursor
#       advance and prove (a) each level bumps correctly, (b) the #671 repro
#       shard sequence produces the semantically-correct versions, and
#       (c) a batch of same-level dispatches stays strictly monotonic.
#
# Pure bash. Run with:
#
#   bash plugins/shipyard/scripts/tests/version-coordination-bump-level.test.sh

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

dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  # $1 file, $2 needle (literal), $3 label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

assert_equals() {
  # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then ok "$1 (got: $3)"; else bad "$1 (expected '$2', got '$3')"; fi
}

echo "version-coordination bump-type-aware next-available-version (issue #671)"
echo

# ---------------------------------------------------------------------------
# (A) Spec assertions.
# ---------------------------------------------------------------------------

if [[ -f "$dispatch_rules" ]]; then
  assert_contains "$dispatch_rules" 'issues/671' \
    "dispatch-rules.md links to originating issue #671"
  assert_contains "$dispatch_rules" 'bump-type-aware' \
    "dispatch-rules.md calls the computation bump-type-aware"
  assert_contains "$dispatch_rules" 'bump_level=' \
    "dispatch-rules.md infers a bump_level"
  assert_contains "$dispatch_rules" 'bump_level="minor"' \
    "dispatch-rules.md maps feat → minor"
  assert_contains "$dispatch_rules" 'bump_level="major"' \
    "dispatch-rules.md maps breaking-change → major"
  # shellcheck disable=SC2016  # literal grep needle — matched verbatim in the spec, not expanded
  assert_contains "$dispatch_rules" 'major)   next_available_version="$((MAJ + 1)).0.0"' \
    "dispatch-rules.md major bump zeroes minor+patch"
  # shellcheck disable=SC2016  # literal grep needle — matched verbatim in the spec, not expanded
  assert_contains "$dispatch_rules" 'minor)   next_available_version="${MAJ}.$((MIN + 1)).0"' \
    "dispatch-rules.md minor bump zeroes patch"
  # The weakened paragraph must present a floor + level, NOT a patch-only
  # "use this exact value" directive.
  assert_contains "$dispatch_rules" 'collision-avoidance **floor**' \
    "dispatch-rules.md paragraph presents the floor as the collision boundary"
  assert_contains "$dispatch_rules" 'the level is yours to raise' \
    "dispatch-rules.md paragraph leaves the semver level to the worker"
  # The old rigid directive must be gone.
  if grep -qF 'Use this exact value when bumping' "$dispatch_rules"; then
    bad "dispatch-rules.md still carries the patch-only 'Use this exact value' directive"
  else
    ok "dispatch-rules.md dropped the patch-only 'Use this exact value' directive"
  fi
  # Cursor still advances to the exact computed value (monotonicity preserved).
  # shellcheck disable=SC2016  # literal grep needle — matched verbatim in the spec, not expanded
  assert_contains "$dispatch_rules" 'version_cursor="$next_available_version"' \
    "dispatch-rules.md still advances the cursor to the exact computed value"
fi

if [[ -f "$steady_state" ]]; then
  assert_contains "$steady_state" 'a05_level' \
    "steady-state.md a05 recovery infers a bump level"
  # shellcheck disable=SC2016  # literal grep needle — matched verbatim in the spec, not expanded
  assert_contains "$steady_state" 'major)   next_ver="$((vc_maj + 1)).0.0"' \
    "steady-state.md a05 recovery major bump zeroes minor+patch"
  # shellcheck disable=SC2016  # literal grep needle — matched verbatim in the spec, not expanded
  assert_contains "$steady_state" 'minor)   next_ver="${vc_maj}.$((vc_min + 1)).0"' \
    "steady-state.md a05 recovery minor bump zeroes patch"
  assert_contains "$steady_state" 'issues/671' \
    "steady-state.md a05 recovery links to #671"
fi

# ---------------------------------------------------------------------------
# (B) Behavioral — replicate the inference + level-aware bump + cursor advance.
# ---------------------------------------------------------------------------

# Mirror of the spec's inference (title-then-body Conventional Commits scan).
infer_level() {
  # $1 title, $2 body → echoes patch|minor|major
  local title="$1" body="$2" level="patch"
  printf '%s' "$title" | grep -qiE '^[[:space:]]*feat(\([^)]*\))?[[:space:]]*:' && level="minor"
  if printf '%s' "$title" | grep -qiE '^[[:space:]]*[a-z]+(\([^)]*\))?!:' \
     || printf '%s\n%s' "$title" "$body" | grep -qiE 'BREAKING[ -]CHANGE|major version bump|\(X\.0\.0\)'; then
    level="major"
  fi
  printf '%s' "$level"
}

# Mirror of the spec's level-aware bump.
bump_at() {
  # $1 floor (X.Y.Z), $2 level → echoes next version
  local floor="$1" level="$2" MAJ MIN PAT
  IFS='.' read -r MAJ MIN PAT <<< "$floor"
  case "$level" in
    major)   printf '%s' "$((MAJ + 1)).0.0" ;;
    minor)   printf '%s' "${MAJ}.$((MIN + 1)).0" ;;
    patch|*) printf '%s' "${MAJ}.${MIN}.$((PAT + 1))" ;;
  esac
}

# --- level inference ---
assert_equals "feat: → minor" "minor" "$(infer_level 'feat: add cross-PR sweep' '')"
assert_equals "feat(scope): → minor" "minor" "$(infer_level 'feat(do-work): add operator layer' '')"
assert_equals "fix: → patch" "patch" "$(infer_level 'fix(do-work): correct floor' '')"
assert_equals "perf: → patch" "patch" "$(infer_level 'perf: speed up scan' '')"
assert_equals "feat!: → major" "major" "$(infer_level 'feat!: drop legacy label' '')"
assert_equals "fix!: → major" "major" "$(infer_level 'fix!: change return contract' '')"
assert_equals "BREAKING CHANGE in body → major" "major" \
  "$(infer_level 'fix: rework thing' 'This is a breaking change.
BREAKING CHANGE: return string changed.')"
assert_equals "explicit MAJOR (X.0.0) body → major" "major" \
  "$(infer_level 'refactor: phase a' 'ships as a MAJOR version bump (X.0.0) — breaking change')"

# --- level-aware bump from a fixed floor ---
assert_equals "major bump from 1.27.1" "2.0.0" "$(bump_at '1.27.1' major)"
assert_equals "minor bump from 1.27.1" "1.28.0" "$(bump_at '1.27.1' minor)"
assert_equals "patch bump from 1.27.1" "1.27.2" "$(bump_at '1.27.1' patch)"
assert_equals "major bump zeroes minor+patch (2.4.7 → 3.0.0)" "3.0.0" "$(bump_at '2.4.7' major)"
assert_equals "minor bump zeroes patch (2.4.7 → 2.5.0)" "2.5.0" "$(bump_at '2.4.7' minor)"

# --- the #671 repro: the #659 epic's shards, sequential w/ cursor, floor 1.27.1 ---
# Each row: floor is the running cursor; version is bump_at(cursor, inferred).
floor="1.27.1"
declare -a got=()
# #661 — MAJOR (breaking).
v=$(bump_at "$floor" "$(infer_level 'refactor: own-the-tail phase a' 'ships as a MAJOR version bump (X.0.0) — breaking change')"); got+=("$v"); floor="$v"
# #662 — feature (minor).
v=$(bump_at "$floor" "$(infer_level 'feat: end-of-dispatch tail-drive' '')"); got+=("$v"); floor="$v"
# #663 — feature (minor).
v=$(bump_at "$floor" "$(infer_level 'feat: own-the-tail merge sweeps' '')"); got+=("$v"); floor="$v"
# #664 — perf (patch).
v=$(bump_at "$floor" "$(infer_level 'perf: cheaper failed-PR scan' '')"); got+=("$v"); floor="$v"
# #665 — feature (minor).
v=$(bump_at "$floor" "$(infer_level 'feat: default-on operator layer' '')"); got+=("$v"); floor="$v"
assert_equals "#659 shard sequence yields semver-correct versions" \
  "2.0.0 2.1.0 2.2.0 2.2.1 2.3.0" "${got[*]}"

# --- batch monotonicity: same-level batch stays strictly increasing ---
# Two MAJOR dispatches in one batch: the cursor advance means slot 2's floor is
# slot 1's computed value, so they never collide (3.0.0 then 4.0.0).
cur="2.3.0"
s1=$(bump_at "$cur" major); cur="$s1"
s2=$(bump_at "$cur" major); cur="$s2"
assert_equals "two same-level (major) batch siblings are distinct + monotonic" \
  "3.0.0 4.0.0" "$s1 $s2"
# Mixed-level batch: minor then patch → 2.4.0 then 2.4.1 (no collision).
cur="2.3.0"
m1=$(bump_at "$cur" minor); cur="$m1"
m2=$(bump_at "$cur" patch); cur="$m2"
assert_equals "mixed-level (minor,patch) batch siblings are distinct + monotonic" \
  "2.4.0 2.4.1" "$m1 $m2"

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
