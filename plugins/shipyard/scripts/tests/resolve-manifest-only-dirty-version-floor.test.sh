#!/usr/bin/env bash
# Test: resolve-manifest-only-dirty.sh's post-rebase version-floor
# enforcement and version-cursor participation (issue #1539).
#
# Background — issue #1539. The release-bump guard
# (scripts/tests/release-bump-required.test.sh) requires the head manifest
# version to be STRICTLY GREATER than the merge-base's; the resolver treated
# ">=" as sufficient, keeping the branch's existing version whenever it was
# merely not BELOW the new base. Live repro, session 013FyjKGyvKG5R6SrUVRsWcn:
#
#   resolved pr=1535 version=4.51.7 head=dbff4c4caeb3     <- reported success
#   FAIL: plugins/** changed but plugin.json's .version was not bumped
#         (base=4.51.7, head=4.51.7)                      <- guard, one cycle later
#
# The resolver flipped the PR DIRTY -> MERGEABLE at a version equal to its
# new merge-base, and the failure landed one CI cycle downstream of the action
# that caused it. Worse, the bad state is OUTSIDE the resolver's own entry
# condition — a PR that is merely failing a check reports BLOCKED, not DIRTY —
# so a re-run returned `deferred reason=not-dirty` and the only way out was a
# separate fix-checks-only dispatch.
#
# Secondary finding (same issue): a single resolve pass handed PRs #1535 and
# #1536 both `4.51.7`, because the resolver never consulted or advanced
# next-available-version.sh's `--cursor-file`. Cost: a guaranteed extra
# DIRTY -> resolve round for every PR after the first.
#
# This file pins THREE layers:
#   (A) Source assertions — the resolver links #1539, uses lib/common.sh's
#       shared strictly-greater comparison rather than reimplementing one,
#       and accepts --cursor-file.
#   (B) Unit — lib/common.sh's version_gt treats EQUAL as not-greater. That
#       exact boundary is the bug.
#   (C) Behavioral — drive the REAL script end-to-end against real git repos
#       and a stubbed `gh`, across the four shapes that reach it, asserting
#       the pushed head is strictly above the new merge-base every time.
#
# Pure bash + git + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/resolve-manifest-only-dirty-version-floor.test.sh

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

resolver="$repo_root/plugins/shipyard/scripts/resolve-manifest-only-dirty.sh"
common_lib="$repo_root/plugins/shipyard/scripts/lib/common.sh"

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

echo "resolve-manifest-only-dirty version-floor enforcement (issue #1539)"
echo

# ---------------------------------------------------------------------------
# (A) Source assertions.
# ---------------------------------------------------------------------------

if [[ -f "$resolver" ]]; then
  assert_contains "$resolver" '#1539' \
    "resolver links to originating issue #1539"
  assert_contains "$resolver" 'version_gt' \
    "resolver uses the shared strictly-greater comparison, not its own compare"
  assert_contains "$resolver" 'allocate_slot' \
    "resolver funnels every version choice through one allocator"
  assert_contains "$resolver" '--cursor-file' \
    "resolver accepts --cursor-file"
  assert_contains "$resolver" 'cursor_advance' \
    "resolver advances the cursor after a successful push"
  assert_contains "$resolver" 'STRICTLY GREATER' \
    "resolver states the strictly-greater contract it must satisfy"
  # The tertiary finding's disposition must be recorded where the entry
  # condition lives, not left silent — the DIRTY-only gate stays narrow and
  # the bad state is made unreachable instead of recoverable.
  assert_contains "$resolver" 'BLOCKED, not' \
    "resolver documents why the DIRTY-only entry condition is not widened"
  # Issue #1571 — the allocator must not count the PR's own pre-allocated
  # claim against it. The early return lives in allocate_slot; pin both the
  # issue link and the fact that the decision is made there.
  assert_contains "$resolver" '#1571' \
    "resolver links to originating issue #1571"
  # Escaped rather than single-quoted: the needle contains literal `$pr` /
  # `$floor`, and a single-quoted needle trips shellcheck's SC2016.
  assert_contains "$resolver" "version_gt \"\$pr\" \"\$floor\"" \
    "allocate_slot keeps the PR's own slot when main has not reached it"
else
  bad "resolver script exists at $resolver"
fi

if [[ -f "$common_lib" ]]; then
  assert_contains "$common_lib" 'version_gt() {' \
    "lib/common.sh owns the shared version_gt helper"
  assert_contains "$common_lib" 'version_max() {' \
    "lib/common.sh owns the shared version_max helper"
  assert_contains "$common_lib" 'is_semver() {' \
    "lib/common.sh owns the shared is_semver helper"
else
  bad "lib/common.sh exists at $common_lib"
fi

# ---------------------------------------------------------------------------
# (B) Unit — the equal-is-not-greater boundary.
# ---------------------------------------------------------------------------

echo
echo "== lib/common.sh version_gt boundary"
# shellcheck source=../lib/common.sh disable=SC1091
source "$common_lib"

if version_gt "4.51.8" "4.51.7"; then ok "version_gt 4.51.8 4.51.7 is true"; else bad "version_gt 4.51.8 4.51.7 should be true"; fi
if version_gt "4.51.7" "4.51.7"; then bad "version_gt on EQUAL versions must be false (the #1539 boundary)"; else ok "version_gt 4.51.7 4.51.7 is false (equal is not greater)"; fi
if version_gt "4.51.6" "4.51.7"; then bad "version_gt on a downgrade must be false"; else ok "version_gt 4.51.6 4.51.7 is false"; fi
if version_gt "1.5.10" "1.5.9"; then ok "version_gt is version-aware (1.5.10 > 1.5.9), not lexicographic"; else bad "version_gt must sort 1.5.10 above 1.5.9"; fi
if version_gt "" "4.51.7"; then bad "version_gt with an empty operand must be false"; else ok "version_gt '' 4.51.7 is false (unknown is never 'lower')"; fi

# ---------------------------------------------------------------------------
# (C) Behavioral — drive the real script against real git repos.
# ---------------------------------------------------------------------------

echo
echo "== behavioral (real git + stubbed gh)"

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipping behavioral tests — git/jq unavailable)"
else

FX_ROOT="$(mktemp -d)"
cleanup() { cd /; rm -rf "$FX_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

# A `gh` stand-in that reports the PR OPEN + DIRTY, which is the only gh call
# the resolver makes. Written once and reused by every fixture.
GH_STUB="$FX_ROOT/gh-stub"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '{"state":"OPEN","mergeStateStatus":"DIRTY"}\n'
STUB
chmod +x "$GH_STUB"

write_manifest() { printf '{\n  "name": "fixture",\n  "version": "%s"\n}\n' "$1" > "$2"; }

# write_changelog <file> <ver1> <date1> <body1> [<ver2> <date2> <body2> ...]
# Each entry carries its OWN date: a shared entry must be byte-identical
# across branches or changelog-monotonicity-scan.sh reads the differing date
# as a deleted released heading (it compares whole heading lines, not just the
# version component).
write_changelog() {
  local file="$1"; shift
  { printf '# Changelog\n\n## shipyard\n\n'
    while [ $# -gt 0 ]; do
      printf '### %s — %s\n\n%s\n\n' "$1" "$2" "$3"
      shift 3
    done
  } > "$file"
}

# new_fixture <name> — creates $FX_ROOT/<name>/{origin.git,work} with a `main`
# branch carrying plugin.json + CHANGELOG.md at BASE_VER. Echoes the work dir.
BASE_VER="4.51.6"
new_fixture() {
  local fx="$FX_ROOT/$1"
  mkdir -p "$fx/origin.git" "$fx/work"
  git init --bare -q -b main "$fx/origin.git"
  (
    cd "$fx/work" || exit 1
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false
    write_manifest "$BASE_VER" plugin.json
    write_changelog CHANGELOG.md "$BASE_VER" 2026-08-01 "Base entry."
    git add -A && git commit -qm "chore: base"
    git remote add origin "$fx/origin.git"
    git push -q origin main
  ) || return 1
  printf '%s/work' "$fx"
}

# add_pr_branch <work> <branch> <ver> — a PR branch that bumps the manifest to
# <ver> and prepends a matching CHANGELOG entry, pushed to origin.
add_pr_branch() {
  local work="$1" branch="$2" ver="$3"
  (
    cd "$work" || exit 1
    git checkout -q -b "$branch" main
    write_manifest "$ver" plugin.json
    write_changelog CHANGELOG.md "$ver" 2026-08-02 "PR entry for $ver." "$BASE_VER" 2026-08-01 "Base entry."
    git add -A && git commit -qm "fix: pr work for $ver"
    git push -q origin "$branch"
    git checkout -q main
  )
}

# advance_main <work> <ver> <touch_changelog: yes|no>
advance_main() {
  local work="$1" ver="$2" touch_cl="$3"
  (
    cd "$work" || exit 1
    git checkout -q main
    write_manifest "$ver" plugin.json
    if [ "$touch_cl" = "yes" ]; then
      write_changelog CHANGELOG.md "$ver" 2026-08-03 "Sibling entry for $ver." "$BASE_VER" 2026-08-01 "Base entry."
    fi
    git add -A && git commit -qm "chore: sibling merged $ver"
    git push -q origin main
  )
}

# assert_resolved <label> <rc> — the resolver's own one-line stdout IS its
# diagnosis (`resolved …` or `deferred reason=<code>: <detail>`), so surface it
# on failure rather than leaving a bare exit code.
assert_resolved() {
  if [[ "$2" == "0" ]]; then
    ok "$1 (${RESOLVE_OUT})"
  else
    bad "$1 (exit $2: ${RESOLVE_OUT:-<no output>})"
  fi
}

# run_resolver <work> <branch> <cursor-file> — runs the real script. Sets the
# globals: RESOLVE_OUT, RESOLVE_RC.
run_resolver() {
  local work="$1" branch="$2" cursor="$3"
  RESOLVE_OUT=$(
    cd "$work" || exit 1
    GH="$GH_STUB" bash "$resolver" resolve \
      --repo fixture/repo --pr 1 --head-ref "$branch" --default-branch main \
      --manifest plugin.json --version-jq .version --changelog CHANGELOG.md \
      --cursor-file "$cursor" 2>/dev/null
  )
  RESOLVE_RC=$?
}

# version_at <work> <ref> — the manifest version at a ref, after a fetch.
version_at() {
  local work="$1" ref="$2"
  ( cd "$work" && git fetch -q origin >/dev/null 2>&1; git -C "$work" show "$ref:plugin.json" 2>/dev/null | jq -r '.version' 2>/dev/null )
}

# --- Shape 1: the #1539 repro — CHANGELOG-only conflict, manifest EQUAL. ----
# A sibling merged the SAME version this PR carries, so both sides' `.version`
# edit is identical and git auto-merges it silently; only the CHANGELOG
# conflicts. Pre-fix this reported `resolved version=4.51.7` against a
# 4.51.7 merge-base and reddened CI one cycle later.
if work=$(new_fixture equal-changelog-conflict); then
  add_pr_branch "$work" pr/equal 4.51.7
  advance_main "$work" 4.51.7 yes
  run_resolver "$work" pr/equal "$FX_ROOT/cursor-1"

  assert_resolved "shape 1: resolver exits 0 (resolved)" "$RESOLVE_RC"
  head_v=$(version_at "$work" "origin/pr/equal")
  floor_v=$(version_at "$work" "origin/main")
  assert_equals "shape 1: floor is unchanged at main's version" "4.51.7" "$floor_v"
  if version_gt "$head_v" "$floor_v"; then
    ok "shape 1: head ($head_v) is STRICTLY greater than the merge-base ($floor_v)"
  else
    bad "shape 1: head ($head_v) must be strictly greater than the merge-base ($floor_v) — this is #1539"
  fi
  assert_equals "shape 1: resolved to the next free patch slot" "4.51.8" "$head_v"

  # The CHANGELOG heading has to move in lockstep — the guard also requires a
  # matching `### <version> — <date>` heading for the bumped version.
  cl=$( cd "$work" && git show "origin/pr/equal:CHANGELOG.md" 2>/dev/null )
  if grep -qF "### $head_v — " <<< "$cl"; then
    ok "shape 1: CHANGELOG carries a matching '### $head_v' heading"
  else
    bad "shape 1: CHANGELOG has no '### $head_v' heading (the guard's second check)"
  fi
  dupes=$(grep -oE '^### [0-9]+\.[0-9]+\.[0-9]+' <<< "$cl" | sort | uniq -d | wc -l | tr -d ' ')
  assert_equals "shape 1: no duplicate CHANGELOG version headings" "0" "$dupes"
else
  bad "shape 1: fixture setup"
fi

# --- Shape 2: clean rebase, manifest EQUAL. ---------------------------------
# The sibling commit touched only the manifest, so nothing conflicts at all —
# the rebase is clean and the pre-fix code did no version work whatsoever.
if work=$(new_fixture equal-clean-rebase); then
  add_pr_branch "$work" pr/clean 4.51.7
  advance_main "$work" 4.51.7 no
  run_resolver "$work" pr/clean "$FX_ROOT/cursor-2"

  assert_resolved "shape 2: resolver exits 0 (resolved)" "$RESOLVE_RC"
  head_v=$(version_at "$work" "origin/pr/clean")
  floor_v=$(version_at "$work" "origin/main")
  if version_gt "$head_v" "$floor_v"; then
    ok "shape 2: head ($head_v) is STRICTLY greater than the merge-base ($floor_v)"
  else
    bad "shape 2: head ($head_v) must be strictly greater than the merge-base ($floor_v) — this is #1539"
  fi
  cl=$( cd "$work" && git show "origin/pr/clean:CHANGELOG.md" 2>/dev/null )
  if grep -qF "### $head_v — " <<< "$cl"; then
    ok "shape 2: CHANGELOG carries a matching '### $head_v' heading"
  else
    bad "shape 2: CHANGELOG has no '### $head_v' heading (the guard's second check)"
  fi
else
  bad "shape 2: fixture setup"
fi

# --- Shape 3: the already-working leapfrog case must not regress. -----------
# The PR's version is strictly BELOW the new floor, so the manifest genuinely
# conflicts and the pre-existing floor+1 resolution already produced a correct
# answer. Pinned so the fix doesn't change it.
if work=$(new_fixture leapfrog); then
  add_pr_branch "$work" pr/leap 4.51.7
  advance_main "$work" 4.51.9 yes
  run_resolver "$work" pr/leap "$FX_ROOT/cursor-3"

  assert_resolved "shape 3: resolver exits 0 (resolved)" "$RESOLVE_RC"
  head_v=$(version_at "$work" "origin/pr/leap")
  floor_v=$(version_at "$work" "origin/main")
  assert_equals "shape 3: leapfrogged PR resolves to floor + 1 patch" "4.51.10" "$head_v"
  if version_gt "$head_v" "$floor_v"; then
    ok "shape 3: head ($head_v) is STRICTLY greater than the merge-base ($floor_v)"
  else
    bad "shape 3: head ($head_v) must be strictly greater than the merge-base ($floor_v)"
  fi
else
  bad "shape 3: fixture setup"
fi

# --- Shape 4: two PRs resolved in ONE pass get DISTINCT slots. --------------
# The secondary finding. Both PRs floor off the same main, so without cursor
# participation both are handed the identical next slot and whichever merges
# first immediately re-dirties the other at that same version.
if work=$(new_fixture cursor-monotonic); then
  add_pr_branch "$work" pr/first 4.51.7
  add_pr_branch "$work" pr/second 4.51.8
  advance_main "$work" 4.51.9 yes

  cursor="$FX_ROOT/cursor-4"
  run_resolver "$work" pr/first "$cursor"
  rc_first=$RESOLVE_RC
  run_resolver "$work" pr/second "$cursor"
  rc_second=$RESOLVE_RC

  assert_equals "shape 4: first resolve exits 0" "0" "$rc_first"
  assert_equals "shape 4: second resolve exits 0" "0" "$rc_second"
  v_first=$(version_at "$work" "origin/pr/first")
  v_second=$(version_at "$work" "origin/pr/second")
  if [ -n "$v_first" ] && [ "$v_first" != "$v_second" ]; then
    ok "shape 4: the two PRs got DISTINCT slots ($v_first vs $v_second)"
  else
    bad "shape 4: both PRs were handed the same slot ($v_first) — the #1539 secondary finding"
  fi
  if version_gt "$v_second" "$v_first"; then
    ok "shape 4: the second slot is above the first (cursor advanced)"
  else
    bad "shape 4: second slot ($v_second) must be above the first ($v_first)"
  fi
  if [ -f "$cursor" ]; then
    ok "shape 4: the cursor file was written"
    assert_equals "shape 4: cursor holds the highest slot handed out" "$v_second" "$(cat "$cursor")"
  else
    bad "shape 4: the cursor file was never written"
  fi
else
  bad "shape 4: fixture setup"
fi

# --- Shape 5: the #1571 repro — the PR KEEPS its own pre-allocated slot. -----
# The orchestrator dispatched this PR at 4.51.8 (a sibling already held 4.51.7)
# and `compute` advanced the cursor to 4.51.8 in the same breath. The sibling
# then merged, taking main to 4.51.7 and DIRTYing this PR. 4.51.8 is still
# free and still strictly above the new floor, so the resolve must LEAVE IT
# ALONE. Pre-fix the cursor fold counted this PR's own claim against it —
# `max(floor 4.51.7, cursor 4.51.8)` = 4.51.8 — and handed out 4.51.9,
# permanently skipping 4.51.8 in the released sequence.
if work=$(new_fixture keeps-own-slot); then
  add_pr_branch "$work" pr/own 4.51.8
  advance_main "$work" 4.51.7 yes
  cursor="$FX_ROOT/cursor-5"
  printf '4.51.8' > "$cursor"          # what `compute` left at dispatch time
  run_resolver "$work" pr/own "$cursor"

  assert_resolved "shape 5: resolver exits 0 (resolved)" "$RESOLVE_RC"
  head_v=$(version_at "$work" "origin/pr/own")
  floor_v=$(version_at "$work" "origin/main")
  assert_equals "shape 5: floor is the sibling's merged version" "4.51.7" "$floor_v"
  assert_equals "shape 5: PR keeps its own pre-allocated slot (no gap)" "4.51.8" "$head_v"
  if version_gt "$head_v" "$floor_v"; then
    ok "shape 5: head ($head_v) is STRICTLY greater than the merge-base ($floor_v)"
  else
    bad "shape 5: head ($head_v) must be strictly greater than the merge-base ($floor_v)"
  fi
  cl=$( cd "$work" && git show "origin/pr/own:CHANGELOG.md" 2>/dev/null )
  if grep -qF "### $head_v — " <<< "$cl"; then
    ok "shape 5: CHANGELOG carries a matching '### $head_v' heading"
  else
    bad "shape 5: CHANGELOG has no '### $head_v' heading"
  fi
  if grep -qF "### 4.51.7 — " <<< "$cl"; then
    ok "shape 5: the sibling's released '### 4.51.7' heading survived"
  else
    bad "shape 5: the sibling's released '### 4.51.7' heading was dropped"
  fi
else
  bad "shape 5: fixture setup"
fi

# --- Shape 6: a cursor ABOVE the PR's version still wins. -------------------
# The complement of shape 5, and the guarantee that keeping `pr_version` does
# not weaken #1539. Here main merged the SAME version the PR carries (4.51.7),
# so the claim is genuinely dead — and the cursor sits at 4.51.8 because a
# LATER dispatch already claimed that slot. Reallocation must skip past the
# cursor, not merely past the floor: floor+1 would be 4.51.8, which is taken.
if work=$(new_fixture cursor-above-pr); then
  add_pr_branch "$work" pr/dead 4.51.7
  advance_main "$work" 4.51.7 yes
  cursor="$FX_ROOT/cursor-6"
  printf '4.51.8' > "$cursor"          # a later dispatch already claimed this
  run_resolver "$work" pr/dead "$cursor"

  assert_resolved "shape 6: resolver exits 0 (resolved)" "$RESOLVE_RC"
  head_v=$(version_at "$work" "origin/pr/dead")
  floor_v=$(version_at "$work" "origin/main")
  assert_equals "shape 6: dead claim reallocates ABOVE the cursor, not the floor" \
    "4.51.9" "$head_v"
  if version_gt "$head_v" "$floor_v"; then
    ok "shape 6: head ($head_v) is STRICTLY greater than the merge-base ($floor_v)"
  else
    bad "shape 6: head ($head_v) must be strictly greater than the merge-base ($floor_v)"
  fi
  assert_equals "shape 6: cursor advanced to the slot handed out" "4.51.9" "$(cat "$cursor")"
else
  bad "shape 6: fixture setup"
fi

fi  # git/jq available

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
