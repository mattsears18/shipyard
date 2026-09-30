#!/usr/bin/env bash
# Test: the config-declared append-only-doc conflict carve-out in fix-rebase
# mode (issue #1309).
#
# Background — issue #1309: fix-rebase.md's §4.6 version-coordination
# carve-out was gated on the ENTIRE conflicted file set being a subset of
# `{manifest_path, changelog_path}`. If even one other file conflicted — even
# a mechanically-trivial one, like an append-only doc where both sides added
# a new, non-overlapping section — the carve-out didn't apply AT ALL: the
# manifest+CHANGELOG rows fell back to being treated as a normal "both sides
# edited the same key" non-trivial conflict too, and the whole rebase bailed.
# Two real drain-phase dispatches against this repo hit exactly this shape:
# PR #1245's rebase conflicted on 5 files, 4 of which (manifest, CHANGELOG,
# `do-work-rationale.md`, `worktree-reap.sh`) were mechanically trivial and
# 1 of which (`steady-state.md`) was genuinely not — but because
# `do-work-rationale.md` wasn't in `{manifest_path, changelog_path}`, the
# gate bailed before even attempting the resolvable subset.
#
# The fix has two parts:
#   1. (item 1 of the issue — a documentation decision, not a behavior
#      change) fix-rebase.md now states explicitly, in a "Design note", that
#      the trivial-or-bail gate is deliberately all-or-nothing — not
#      per-file — and why (a clean `git rebase --abort` with the branch
#      untouched is worth more than resolving a trivial subset of a rebase
#      that needs a human either way).
#   2. (item 2 of the issue — the actionable half) a config-declared list,
#      `version_coordination.append_only_paths` (default `[]`), of doc paths
#      whose conflicts are recognized by the SAME §4.6 gate as the manifest
#      and CHANGELOG rows — so a conflict confined to
#      `{manifest, changelog} ∪ append_only_paths` resolves in full, instead
#      of bailing over the append-only file alone. Per-file resolution is
#      mechanical: regenerate the conflict in diff3 style and, IF every
#      hunk's common-ancestor section is empty (both sides purely appended,
#      no shared content touched — "the conflict regions don't overlap" per
#      the issue), concatenate both sides; bail (whole rebase) if any hunk's
#      ancestor section is non-empty. This repo's own config sets
#      `append_only_paths` to `["docs/design/do-work-rationale.md"]`.
#
# This test pins FOUR layers:
#   (A) resolve-append-only-conflict.sh — direct behavioral tests: a
#       pure-append (non-overlapping) conflict resolves; an overlapping-edit
#       conflict is refused; a non-conflicted file is refused as
#       indeterminate; a multi-hunk pure-append file resolves all hunks.
#   (B) Config/schema — the schema declares `append_only_paths` (array of
#       strings, default `[]`), the built-in default is `[]`, and this
#       repo's own `shipyard.config.json` lists `do-work-rationale.md` and
#       validates.
#   (C) Spec assertions — fix-rebase.md links to #1309, states the
#       all-or-nothing design note, reads `append_only_paths`, widens gate 2
#       to the union, and names the resolve-append-only-conflict.sh script.
#   (D) Behavioral — reconstruct the PR-#1245 shape (manifest + CHANGELOG +
#       an append-only doc all conflict, nothing else) using real git, and
#       confirm §4.6's widened gate-2 logic (mirrored here) accepts the
#       whole set and every file resolves cleanly.
#
# Pure bash + git + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-rebase-append-only-conflict.test.sh

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

script="$repo_root/plugins/shipyard/scripts/resolve-append-only-conflict.sh"
fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_helper="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
marker_scanner="$repo_root/plugins/shipyard/scripts/conflict-marker-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  # $1 file, $2 needle (literal), $3 label
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

assert_file_exists() { if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
assert_executable()  { if [[ -x "$1" ]]; then ok "$2"; else bad "$2 (not executable: $1)"; fi; }

echo "fix-rebase append-only-doc conflict carve-out (issue #1309)"
echo

# ---------------------------------------------------------------------------
# (A) resolve-append-only-conflict.sh — direct behavioral tests.
# ---------------------------------------------------------------------------

assert_file_exists "$script" "scripts/resolve-append-only-conflict.sh exists"
assert_executable "$script" "scripts/resolve-append-only-conflict.sh has the exec bit set"

if [[ ! -f "$script" ]] || ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipping (A)/(D) behavioral tests — script or git/jq unavailable)"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # -- (A1) Pure-append conflict: both sides added a new, non-overlapping
  # section. Must resolve cleanly, keeping both sections, no markers left.
  fx="$work/pure-append"
  mkdir -p "$fx"
  git -C "$fx" init -q -b main
  git -C "$fx" config user.email t@t.t
  git -C "$fx" config user.name t
  git -C "$fx" config commit.gpgsign false
  printf '# Rationale\n\n## Section A\n\nBase content.\n' > "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm base
  git -C "$fx" checkout -qb pr
  printf '\n## Section B (PR)\n\nPR own new section.\n' >> "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "pr work"
  git -C "$fx" checkout -q main
  printf '\n## Section C (main)\n\nMain own new section.\n' >> "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "main advanced"
  git -C "$fx" checkout -q pr
  git -C "$fx" rebase main >/dev/null 2>&1 || true

  out="$(cd "$fx" && bash "$script" RATIONALE.md 2>&1)"
  status=$?
  if [[ $status -eq 0 && "$out" == RESOLVED:RATIONALE.md* ]]; then
    ok "(A1) pure-append conflict: exit 0, RESOLVED verdict"
  else
    bad "(A1) pure-append conflict: expected exit 0 + RESOLVED, got exit $status: $out"
  fi
  if grep -qF "Section B (PR)" "$fx/RATIONALE.md" && grep -qF "Section C (main)" "$fx/RATIONALE.md"; then
    ok "(A1) both sides' sections survive in the resolved file"
  else
    bad "(A1) expected both sections present in resolved RATIONALE.md"
  fi
  if [[ -f "$marker_scanner" ]]; then
    if bash "$marker_scanner" "$fx/RATIONALE.md" >/dev/null 2>&1; then
      ok "(A1) resolved file is conflict-marker-clean (#436-style scan)"
    else
      bad "(A1) resolved file still carries conflict markers"
    fi
  fi

  # -- (A2) Overlapping-edit conflict: both sides edited the SAME pre-existing
  # line differently. Must refuse (OVERLAP), never silently pick a side.
  fx="$work/overlap"
  mkdir -p "$fx"
  git -C "$fx" init -q -b main
  git -C "$fx" config user.email t@t.t
  git -C "$fx" config user.name t
  git -C "$fx" config commit.gpgsign false
  printf '# Rationale\n\n## Section A\n\nBase content both sides will edit.\n' > "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm base
  git -C "$fx" checkout -qb pr
  printf '# Rationale\n\n## Section A\n\nPR edited this shared line.\n' > "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "pr work"
  git -C "$fx" checkout -q main
  printf '# Rationale\n\n## Section A\n\nMain edited this shared line differently.\n' > "$fx/RATIONALE.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "main advanced"
  git -C "$fx" checkout -q pr
  git -C "$fx" rebase main >/dev/null 2>&1 || true

  out="$(cd "$fx" && bash "$script" RATIONALE.md 2>&1)"
  status=$?
  if [[ $status -eq 1 && "$out" == OVERLAP:RATIONALE.md* ]]; then
    ok "(A2) overlapping-edit conflict: exit 1, OVERLAP verdict"
  else
    bad "(A2) overlapping-edit conflict: expected exit 1 + OVERLAP, got exit $status: $out"
  fi

  # -- (A3) Not-a-conflicted-path: refuses as indeterminate, never guesses.
  fx="$work/not-conflicted"
  mkdir -p "$fx"
  git -C "$fx" init -q -b main
  git -C "$fx" config user.email t@t.t
  git -C "$fx" config user.name t
  git -C "$fx" config commit.gpgsign false
  printf 'hello\n' > "$fx/README.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm base

  out="$(cd "$fx" && bash "$script" README.md 2>&1)"
  status=$?
  if [[ $status -eq 2 && "$out" == *"INDETERMINATE:"* ]]; then
    ok "(A3) non-conflicted path: exit 2, INDETERMINATE verdict"
  else
    bad "(A3) non-conflicted path: expected exit 2 + INDETERMINATE, got exit $status: $out"
  fi

  # -- (A4) Multi-hunk pure-append file: two independent conflict regions in
  # the same file, both purely additive. Both must resolve.
  fx="$work/multi-hunk"
  mkdir -p "$fx"
  git -C "$fx" init -q -b main
  git -C "$fx" config user.email t@t.t
  git -C "$fx" config user.name t
  git -C "$fx" config commit.gpgsign false
  printf 'Intro.\n\n## Middle\n\nMiddle content.\n\n## End\n\nEnd content.\n' > "$fx/DOC.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm base
  git -C "$fx" checkout -qb pr
  printf 'Intro.\n\n## PR-Top\n\nPR top addition.\n\n## Middle\n\nMiddle content.\n\n## End\n\nEnd content.\n\n## PR-Bottom\n\nPR bottom addition.\n' > "$fx/DOC.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "pr work (two additions)"
  git -C "$fx" checkout -q main
  printf 'Intro.\n\n## Main-Top\n\nMain top addition.\n\n## Middle\n\nMiddle content.\n\n## End\n\nEnd content.\n\n## Main-Bottom\n\nMain bottom addition.\n' > "$fx/DOC.md"
  git -C "$fx" add -A && git -C "$fx" commit -qm "main advanced (two additions)"
  git -C "$fx" checkout -q pr
  git -C "$fx" rebase main >/dev/null 2>&1 || true

  out="$(cd "$fx" && bash "$script" DOC.md 2>&1)"
  status=$?
  if [[ $status -eq 0 && "$out" == RESOLVED:DOC.md\ \(2\ hunk* ]]; then
    ok "(A4) multi-hunk pure-append file: exit 0, both hunks counted"
  else
    bad "(A4) multi-hunk pure-append file: expected exit 0 + 2 hunks, got exit $status: $out"
  fi
  for needle in "PR-Top" "PR-Bottom" "Main-Top" "Main-Bottom"; do
    if grep -qF "$needle" "$fx/DOC.md"; then
      ok "(A4) resolved DOC.md retains $needle"
    else
      bad "(A4) resolved DOC.md is missing $needle"
    fi
  done
fi

# ---------------------------------------------------------------------------
# (B) Config/schema.
# ---------------------------------------------------------------------------

if [[ -f "$schema" ]]; then
  assert_contains "$schema" '"append_only_paths"' \
    "schema declares version_coordination.append_only_paths"
  assert_contains "$schema" 'issue #1309' \
    "schema description links to issue #1309"
fi

if [[ -f "$config_helper" ]] && command -v jq >/dev/null 2>&1; then
  home="$(mktemp -d)"
  fresh_repo="$(mktemp -d)"
  out=$(SHIPYARD_REPO_ROOT="$fresh_repo" SHIPYARD_HOME="$home" "$config_helper" get version_coordination.append_only_paths 2>&1)
  if [[ "$out" == "[]" ]]; then
    ok "default version_coordination.append_only_paths is [] on a repo with no config"
  else
    bad "default version_coordination.append_only_paths: expected [], got: $out"
  fi
  rm -rf "$home" "$fresh_repo"

  # This repo's own committed shipyard.config.json.
  out=$(SHIPYARD_REPO_ROOT="$repo_root" SHIPYARD_HOME="$(mktemp -d)" "$config_helper" get version_coordination.append_only_paths 2>&1)
  if [[ "$out" == *"do-work-rationale.md"* ]]; then
    ok "this repo's shipyard.config.json lists do-work-rationale.md in append_only_paths"
  else
    bad "this repo's shipyard.config.json append_only_paths: expected do-work-rationale.md, got: $out"
  fi

  validate_out=$(cd "$repo_root" && "$config_helper" validate --layer repo 2>&1)
  validate_status=$?
  if [[ $validate_status -eq 0 ]]; then
    ok "this repo's shipyard.config.json (with append_only_paths) validates against the schema"
  else
    bad "this repo's shipyard.config.json failed schema validation: $validate_out"
  fi
fi

# ---------------------------------------------------------------------------
# (C) Spec assertions.
# ---------------------------------------------------------------------------

if [[ -f "$fix_rebase" ]]; then
  assert_contains "$fix_rebase" 'issues/1309' \
    "fix-rebase.md links to originating issue #1309"
  assert_contains "$fix_rebase" 'Design note' \
    "fix-rebase.md's step 4 carries a Design note"
  assert_contains "$fix_rebase" 'deliberately all-or-nothing' \
    "fix-rebase.md states the trivial-or-bail gate is deliberately all-or-nothing"
  assert_contains "$fix_rebase" 'version_coordination.append_only_paths' \
    "fix-rebase.md reads version_coordination.append_only_paths"
  assert_contains "$fix_rebase" 'resolve-append-only-conflict.sh' \
    "fix-rebase.md names the resolve-append-only-conflict.sh script"
  assert_contains "$fix_rebase" 'a non-empty JSON array — independent of' \
    "fix-rebase.md documents append-only eligibility as independent of version_coordination.enabled"
  assert_contains "$fix_rebase" 'resolves in full instead of bailing on the append-only file alone' \
    "fix-rebase.md widens gate 2 to the manifest/changelog + append_only_paths union"
  assert_contains "$fix_rebase" 'resolved-vs-blocking split' \
    "fix-rebase.md's step 7 return guidance asks for the resolved-vs-blocking split"
  # Existing #466 bail message text must survive verbatim (regression guard —
  # fix-rebase-version-coordination.test.sh also pins this).
  assert_contains "$fix_rebase" 'beyond coordinated manifest+CHANGELOG rows' \
    "fix-rebase.md still bails with the original #466 message text for the pre-existing case"
fi

# ---------------------------------------------------------------------------
# (D) Behavioral — reconstruct the PR-#1245 shape: manifest + CHANGELOG +
# an append-only doc all conflict, nothing else. The widened §4.6 gate 2
# (mirrored here) must accept the whole set; nothing should bail.
# ---------------------------------------------------------------------------

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || [[ ! -f "$script" ]]; then
  echo "  (skipping (D) — git/jq/script unavailable)"
else
  fx="$(mktemp -d)"
  (
    cd "$fx" || exit 1
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false

    printf '{\n  "version": "1.0.0"\n}\n' > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### 1.0.0 — 2026-05-31\n\nBase entry.\n' > CHANGELOG.md
    printf '# Rationale\n\n## Section A\n\nBase content.\n' > RATIONALE.md
    git add -A && git commit -qm base

    git checkout -qb pr
    printf '{\n  "version": "1.0.1"\n}\n' > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### 1.0.1 — 2026-06-01\n\nPR entry.\n\n### 1.0.0 — 2026-05-31\n\nBase entry.\n' > CHANGELOG.md
    printf '\n## Section B (PR)\n\nPR own new section.\n' >> RATIONALE.md
    git add -A && git commit -qm "PR work"

    git checkout -q main
    printf '{\n  "version": "1.0.3"\n}\n' > plugin.json
    printf '# Changelog\n\n## shipyard\n\n### 1.0.3 — 2026-06-01\n\nSibling entry.\n\n### 1.0.0 — 2026-05-31\n\nBase entry.\n' > CHANGELOG.md
    printf '\n## Section C (main)\n\nMain own new section.\n' >> RATIONALE.md
    git add -A && git commit -qm "main advanced"

    git checkout -q pr
    git rebase main >/dev/null 2>&1 || true
  ) || { bad "(D) mixed-conflict fixture setup failed"; }

  cd "$fx" || bad "(D) could not cd into fixture"

  conflicted="$(git diff --name-only --diff-filter=U | LC_ALL=C sort | tr '\n' ' ')"
  if [[ "$conflicted" == "CHANGELOG.md RATIONALE.md plugin.json " ]]; then
    ok "(D) rebase conflicted on exactly the three trivial files (manifest+CHANGELOG+append-only doc)"
  else
    bad "(D) unexpected conflicted set: $conflicted"
  fi

  # append_only_paths gate-2 membership check, mirroring §4.6 item 2's jq test.
  append_only_paths='["RATIONALE.md"]'
  gate2_ok=1
  for f in $conflicted; do
    is_vc=0
    [[ "$f" == "plugin.json" || "$f" == "CHANGELOG.md" ]] && is_vc=1
    is_append_only=0
    if printf '%s' "$append_only_paths" | jq -e --arg f "$f" 'type == "array" and (index($f) != null)' >/dev/null 2>&1; then
      is_append_only=1
    fi
    if [[ "$is_vc" -eq 0 && "$is_append_only" -eq 0 ]]; then
      gate2_ok=0
    fi
  done
  if [[ "$gate2_ok" -eq 1 ]]; then
    ok "(D) widened gate 2 accepts the whole conflicted set (manifest ∪ changelog ∪ append_only_paths)"
  else
    bad "(D) widened gate 2 unexpectedly rejected a file in the recognized set"
  fi

  # Resolve the append-only doc via the real script (the manifest/CHANGELOG
  # resolution recipe itself is already pinned by fix-rebase-version-
  # coordination.test.sh — this test's job is proving the THIRD file no
  # longer poisons the whole rebase, not re-testing the version-bump math).
  ao_out="$(bash "$script" RATIONALE.md 2>&1)"
  ao_status=$?
  if [[ $ao_status -eq 0 ]]; then
    ok "(D) append-only doc (RATIONALE.md) resolves cleanly alongside the manifest+CHANGELOG conflict"
  else
    bad "(D) append-only doc resolution failed: exit $ao_status: $ao_out"
  fi
  if grep -qF "Section B (PR)" RATIONALE.md && grep -qF "Section C (main)" RATIONALE.md; then
    ok "(D) resolved RATIONALE.md retains both sides' sections"
  else
    bad "(D) resolved RATIONALE.md is missing a section"
  fi

  cd "$repo_root" || true
  rm -rf "$fx"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
