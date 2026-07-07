#!/usr/bin/env bash
# Test: the version-coordinated manifest+CHANGELOG re-number trivial
# resolution in fix-rebase mode (issue #466).
#
# Background — issue #466: fix-rebase.md's conflict policy is
# trivial-or-bail. A single-value manifest `.version` row conflict reads
# as "both sides edited the same JSON key with different values" → the
# step-4 non-trivial rule → bail. The CHANGELOG "take both" rule would
# leave a bogus out-of-order `### <stale-version>` entry below the newer
# one. So on a `version_coordination.enabled` repo, a fix-rebase against a
# version-leapfrogged PR is a GUARANTEED `blocked rebase` — even though the
# resolution is fully deterministic (take main's version, bump to the next
# free patch, re-number this PR's CHANGELOG heading to that slot, place
# newest-first). The orchestrator had to do it by hand (session
# do-work-20260601T013917Z-76896, PR #462: pre-allocated 1.8.38, main
# advanced to 1.8.41, resolved to 1.8.42).
#
# The fix adds fix-rebase.md §4.6 — a narrow carve-out from the bail rule:
# when version_coordination.enabled AND the ONLY conflicts are the manifest
# `.version` row + the CHANGELOG top-of-file insert, resolve deterministically.
# Bail when the conflict touches source/spec content beyond those rows.
# Pairs with the existing post-resolution conflict-marker assertion (#436).
#
# This test pins TWO layers:
#   (A) Spec assertions — the §4.6 carve-out exists in fix-rebase.md, links
#       to #466, names the eligibility gates + resolution + #436 pairing,
#       and the dispatch prompt template in steady-state.md surfaces the
#       coordination context.
#   (B) Behavioral — using real git, reconstruct the #466 conflict shape
#       (sibling advanced the version + prepended a CHANGELOG entry) and
#       prove the §4.6 resolution recipe (a) produces a conflict-marker-clean
#       tree the #436 assertion passes, (b) yields strictly-descending,
#       no-duplicate CHANGELOG headings, and (c) sets the manifest version to
#       main's floor + 1 patch (NOT the PR's stale pre-allocated value).
#
# Pure bash + git + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-rebase-version-coordination.test.sh

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

fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
# The fix-rebase divert prompt template lives in the Dispatch rules reference
# block, which moved out of steady-state.md into dispatch-rules.md (issue #616).
dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
scanner="$repo_root/plugins/shipyard/scripts/conflict-marker-scan.sh"

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

echo "fix-rebase version-coordination re-number resolution (issue #466)"
echo

# ---------------------------------------------------------------------------
# (A) Spec assertions.
# ---------------------------------------------------------------------------

if [[ -f "$fix_rebase" ]]; then
  assert_contains "$fix_rebase" 'issues/466' \
    "fix-rebase.md links to originating issue #466"
  assert_contains "$fix_rebase" 'version_coordination.enabled' \
    "fix-rebase.md gates the carve-out on version_coordination.enabled"
  assert_contains "$fix_rebase" 'next free slot' \
    "fix-rebase.md names the next-free-slot bump"
  # #673: the re-number must be bump-level-aware (major/minor/patch), not patch-only.
  assert_contains "$fix_rebase" 'issues/673' \
    "fix-rebase.md links to the bump-level-aware fix (#673)"
  assert_contains "$fix_rebase" 'bump_level' \
    "fix-rebase.md infers the PR's release level (bump_level), not a hardcoded patch"
  assert_contains "$fix_rebase" 'newest-first' \
    "fix-rebase.md requires the re-numbered CHANGELOG entry placed newest-first"
  assert_contains "$fix_rebase" '--diff-filter=U' \
    "fix-rebase.md enumerates conflicted files to bound the carve-out"
  assert_contains "$fix_rebase" 'beyond coordinated manifest+CHANGELOG rows' \
    "fix-rebase.md bails when the conflict extends beyond the two coordinated rows"
  # The carve-out MUST pair with the #436 conflict-marker assertion.
  assert_contains "$fix_rebase" 'issues/436' \
    "fix-rebase.md pairs the carve-out with the #436 conflict-marker assertion"
  # The manifest_version_jq config key must be read so non-.version manifests work.
  assert_contains "$fix_rebase" 'manifest_version_jq' \
    "fix-rebase.md reads manifest_version_jq (not hardcoded .version)"
fi

if [[ -f "$dispatch_rules" ]]; then
  assert_contains "$dispatch_rules" 'Version-coordination (authoritative)' \
    "dispatch-rules.md fix-rebase prompt surfaces the version-coordination context"
  assert_contains "$dispatch_rules" '§4.6' \
    "dispatch-rules.md fix-rebase prompt points the worker at §4.6"
fi

# ---------------------------------------------------------------------------
# (B) Behavioral — reconstruct the #466 conflict and prove the resolution.
#     Parameterized over the PR's release level (issue #673): the re-number
#     must preserve the PR's intended major/minor/patch level, NOT collapse
#     every leapfrogged PR to a patch bump of main's floor.
# ---------------------------------------------------------------------------

# Level-aware next-free computation, mirroring fix-rebase.md §4.6 step 1:
# infer the PR's level from (base_version -> pr_version) delta, then bump the
# floor at that level. Echoes the computed next-free version.
compute_next_free() {
  # $1 base_version  $2 pr_version  $3 floor
  local base="$1" pr="$2" floor="$3" level
  local bMAJ bMIN pMAJ pMIN fMAJ fMIN fPAT
  IFS='.' read -r bMAJ bMIN _ <<< "$base"
  IFS='.' read -r pMAJ pMIN _ <<< "$pr"
  if   [ "${pMAJ:-0}" -gt "${bMAJ:-0}" ]; then level="major"
  elif [ "${pMIN:-0}" -gt "${bMIN:-0}" ]; then level="minor"
  else level="patch"; fi
  IFS='.' read -r fMAJ fMIN fPAT <<< "$floor"
  case "$level" in
    major)   echo "$((fMAJ + 1)).0.0" ;;
    minor)   echo "${fMAJ}.$((fMIN + 1)).0" ;;
    patch|*) echo "${fMAJ}.${fMIN}.$((fPAT + 1))" ;;
  esac
}

# run_fixture BASE_VER PR_VER MAIN_VER -> sets globals: conflicted,
# resolved_version, headings, marker_rc, dupes. Reconstructs the #466 conflict
# (PR pre-allocated PR_VER, sibling advanced main to MAIN_VER) and applies the
# §4.6 recipe with the level-aware compute_next_free.
run_fixture() {
  local base_ver="$1" pr_ver="$2" main_ver="$3"
  local fx; fx="$(mktemp -d)"
  (
    cd "$fx" || exit 1
    git init -q -b main  # pin default branch — CI's init.defaultBranch may not be 'main' (#466 main-CI fix)
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false

    printf '{\n  "version": "%s"\n}\n' "$base_ver" > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### %s — 2026-05-31\n\nBase entry.\n' "$base_ver" > CHANGELOG.md
    git add -A && git commit -qm "base"

    git checkout -qb pr
    printf '{\n  "version": "%s"\n}\n' "$pr_ver" > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### %s — 2026-06-01\n\nPR entry (this PR work).\n\n### %s — 2026-05-31\n\nBase entry.\n' "$pr_ver" "$base_ver" > CHANGELOG.md
    git add -A && git commit -qm "PR work"

    git checkout -q main
    printf '{\n  "version": "%s"\n}\n' "$main_ver" > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### %s — 2026-06-01\n\nSibling entry.\n\n### %s — 2026-05-31\n\nBase entry.\n' "$main_ver" "$base_ver" > CHANGELOG.md
    git add -A && git commit -qm "main advanced"

    git checkout -q pr
    git rebase main >/dev/null 2>&1 || true
  ) || { bad "fixture setup failed for $pr_ver over $main_ver"; return 1; }

  cd "$fx" || { bad "could not cd into fixture"; return 1; }
  conflicted="$(git diff --name-only --diff-filter=U | sort | tr '\n' ' ')"

  # §4.6 resolution recipe (level-aware).
  local floor next
  floor="$(git show "main:plugin.json" | jq -r '.version')"
  next="$(compute_next_free "$base_ver" "$pr_ver" "$floor")"

  git show "main:plugin.json" | jq --arg v "$next" '.version = $v' > plugin.json
  git show "main:CHANGELOG.md" > CHANGELOG.md
  awk -v nv="$next" '
    /^## shipyard$/ && !inserted {
      print; print ""
      print "### " nv " — 2026-06-01"
      print ""; print "PR entry (this PR work)."
      inserted=1; next
    }
    { print }
  ' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

  git add plugin.json CHANGELOG.md
  GIT_EDITOR=true git rebase --continue >/dev/null 2>&1

  resolved_version="$(jq -r '.version' plugin.json)"
  headings="$(grep -oE '^### [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
  marker_rc=0
  bash "$scanner" plugin.json CHANGELOG.md >/dev/null 2>&1 || marker_rc=$?
  dupes="$(grep -oE '^### [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | sort | uniq -d | wc -l | tr -d ' ')"

  cd "$repo_root" || true
  rm -rf "$fx"
}

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipping behavioral tests — git/jq unavailable)"
else
  # --- Patch PR (the original #466 shape): 1.8.37 -> PR 1.8.38, main 1.8.41.
  if run_fixture "1.8.37" "1.8.38" "1.8.41"; then
    assert_equals "[patch] rebase conflicted on exactly the two coordinated files" \
      "CHANGELOG.md plugin.json " "$conflicted"
    assert_equals "[patch] resolved = main floor (1.8.41) + 1 patch, NOT stale 1.8.38" \
      "1.8.42" "$resolved_version"
    assert_equals "[patch] CHANGELOG headings strictly descending, newest-first" \
      "1.8.42 1.8.41 1.8.37" "$headings"
    assert_equals "[patch] no duplicate CHANGELOG headings" "0" "$dupes"
    assert_equals "[patch] resolved tree conflict-marker-clean (#436)" "0" "$marker_rc"
  fi

  # --- Minor PR (#673): base 2.3.9 -> PR 2.4.0 (feature), main advanced 2.3.12.
  #     Patch-only would wrongly resolve to 2.3.13; level-aware must give 2.4.0.
  if run_fixture "2.3.9" "2.4.0" "2.3.12"; then
    assert_equals "[minor] resolved preserves the minor level (2.4.0), NOT patch 2.3.13" \
      "2.4.0" "$resolved_version"
    assert_equals "[minor] CHANGELOG headings strictly descending, newest-first" \
      "2.4.0 2.3.12 2.3.9" "$headings"
    assert_equals "[minor] no duplicate CHANGELOG headings" "0" "$dupes"
    assert_equals "[minor] resolved tree conflict-marker-clean (#436)" "0" "$marker_rc"
  fi

  # --- Major PR (#673): base 2.3.9 -> PR 3.0.0 (breaking), main advanced 2.4.5.
  #     Patch-only would wrongly resolve to 2.4.6; level-aware must give 3.0.0.
  if run_fixture "2.3.9" "3.0.0" "2.4.5"; then
    assert_equals "[major] resolved preserves the major level (3.0.0), NOT patch 2.4.6" \
      "3.0.0" "$resolved_version"
    assert_equals "[major] CHANGELOG headings strictly descending, newest-first" \
      "3.0.0 2.4.5 2.3.9" "$headings"
    assert_equals "[major] no duplicate CHANGELOG headings" "0" "$dupes"
    assert_equals "[major] resolved tree conflict-marker-clean (#436)" "0" "$marker_rc"
  fi
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
