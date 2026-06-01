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
steady_state="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
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
  assert_contains "$fix_rebase" 'next free patch' \
    "fix-rebase.md names the next-free-patch bump"
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

if [[ -f "$steady_state" ]]; then
  assert_contains "$steady_state" 'Version-coordination (authoritative)' \
    "steady-state.md fix-rebase prompt surfaces the version-coordination context"
  assert_contains "$steady_state" '§4.6' \
    "steady-state.md fix-rebase prompt points the worker at §4.6"
fi

# ---------------------------------------------------------------------------
# (B) Behavioral — reconstruct the #466 conflict and prove the resolution.
# ---------------------------------------------------------------------------

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipping behavioral tests — git/jq unavailable)"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  if ! cd "$work"; then
    bad "could not cd into the behavioral fixture dir"
  else
    git init -q
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false

    manifest="plugin.json"
    changelog="CHANGELOG.md"

    # Base: version 1.8.37, one CHANGELOG entry.
    printf '{\n  "version": "1.8.37"\n}\n' > "$manifest"
    cat > "$changelog" <<'EOF'
# Changelog

## shipyard

### 1.8.37 — 2026-05-31

Base entry.
EOF
    git add -A && git commit -qm "base 1.8.37"

    # PR branch: pre-allocated 1.8.38, prepends its CHANGELOG entry.
    git checkout -qb pr
    printf '{\n  "version": "1.8.38"\n}\n' > "$manifest"
    cat > "$changelog" <<'EOF'
# Changelog

## shipyard

### 1.8.38 — 2026-06-01

PR entry (this PR's work).

### 1.8.37 — 2026-05-31

Base entry.
EOF
    git add -A && git commit -qm "PR work, bump 1.8.38"

    # main advances past the PR: siblings landed 1.8.39, 1.8.40, 1.8.41.
    git checkout -q main
    printf '{\n  "version": "1.8.41"\n}\n' > "$manifest"
    cat > "$changelog" <<'EOF'
# Changelog

## shipyard

### 1.8.41 — 2026-06-01

Sibling entry.

### 1.8.37 — 2026-05-31

Base entry.
EOF
    git add -A && git commit -qm "main advanced to 1.8.41"

    # Rebase PR onto main — this is the #466 conflict.
    git checkout -q pr
    if git rebase main >/dev/null 2>&1; then
      echo "    (rebase unexpectedly clean — fixture did not reproduce the conflict)" >&2
    fi

    # Confirm BOTH files conflicted (the #466 shape) and nothing else.
    conflicted="$(git diff --name-only --diff-filter=U | sort | tr '\n' ' ')"

    # --- §4.6 resolution recipe ---------------------------------------------
    # 1. Compute next free version = main's floor + 1 patch.
    floor="$(git show "main:$manifest" | jq -r '.version')"
    IFS='.' read -r maj min pat <<< "$floor"
    next="${maj}.${min}.$((pat + 1))"

    # 2. Write resolved manifest (take main's tree, set version to next).
    git show "main:$manifest" | jq --arg v "$next" '.version = $v' > "$manifest"

    # 3. Re-number + reorder CHANGELOG: this PR's entry renumbered to $next,
    #    hoisted above main's top entry. Start from main's CHANGELOG, then
    #    splice the PR's (renumbered) block in at the top of the section.
    git show "main:$changelog" > "$changelog"
    # Insert the renumbered PR block immediately after the "## shipyard" line.
    awk '
      /^## shipyard$/ && !inserted {
        print
        print ""
        print "### NEXTVERSION — 2026-06-01"
        print ""
        print "PR entry (this PR'"'"'s work)."
        inserted=1
        next
      }
      { print }
    ' "$changelog" > "$changelog.tmp"
    sed "s/NEXTVERSION/$next/" "$changelog.tmp" > "$changelog"
    rm -f "$changelog.tmp"

    git add "$manifest" "$changelog"
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1

    # --- collect results ----------------------------------------------------
    resolved_version="$(jq -r '.version' "$manifest")"
    # CHANGELOG version headings in file order.
    headings="$(grep -oE '^### [0-9]+\.[0-9]+\.[0-9]+' "$changelog" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
    # Conflict-marker scan over the resolved tree.
    marker_rc=0
    bash "$scanner" "$manifest" "$changelog" >/dev/null 2>&1 || marker_rc=$?
    # Duplicate-heading count.
    dupes="$(grep -oE '^### [0-9]+\.[0-9]+\.[0-9]+' "$changelog" | sort | uniq -d | wc -l | tr -d ' ')"

    cd "$repo_root" || true

    # --- assertions ---------------------------------------------------------
    assert_equals "rebase conflicted on exactly the two coordinated files" \
      "CHANGELOG.md plugin.json " "$conflicted"
    assert_equals "resolved version = main floor (1.8.41) + 1 patch, NOT stale 1.8.38" \
      "1.8.42" "$resolved_version"
    assert_equals "CHANGELOG headings strictly descending, newest-first" \
      "1.8.42 1.8.41 1.8.37" "$headings"
    assert_equals "no duplicate CHANGELOG headings" "0" "$dupes"
    assert_equals "resolved tree is conflict-marker-clean (#436 assertion passes)" \
      "0" "$marker_rc"
  fi
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
