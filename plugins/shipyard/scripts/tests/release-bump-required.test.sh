#!/usr/bin/env bash
# Test/guard: "always cut a release" enforcement (issue #839).
#
# Background: CLAUDE.md's "Release process" section states plainly —
# "ALWAYS cut a release when a PR merges ... A PR that merges without a
# version bump is invisible to every existing installation." Nothing
# enforced that rule; it was prose, honored by convention only. It was
# already violated in a way that cost real users a working product:
#
#   commit    version   substrate state
#   ce7a577   4.0.3     broken (`meta` is a BinaryExpression)
#   cf8771b   4.0.3     broken (merge of #807)
#   bb31052   4.0.3     fixed  (make do-work-dispatch meta a pure literal)
#
# bb31052 fixed a total dispatch outage but shipped it under the SAME
# version string as the broken build. A user running "shipyard 4.0.3" hit
# the outage, and `/shipyard:update` had no version delta to act on — it
# would report them current while leaving the broken substrate installed.
# See issue #835 for the user-facing report this caused.
#
# This file is BOTH the guard and its test suite. The repo's test-discovery
# job (`find plugins -type f -name '*.test.sh'` in .github/workflows/tests.yml)
# picks up any `*.test.sh` file automatically, so this single file — with no
# CI workflow edit — is enough to gate every push and PR. That matters:
# workers are hard-blocked from editing `.github/workflows/`, so a
# workflow-file deliverable would make this issue undispatchable.
#
# The guard fails (exit 1, CI red) when BOTH of:
#   (a) the diff vs the merge-base touches anything under `plugins/**`, AND
#   (b) plugins/shipyard/.claude-plugin/plugin.json's `.version` is not
#       STRICTLY GREATER (version-aware, via `sort -V`) than the merge-base's
#       value — this also catches an accidental downgrade, not just "same".
#
# It also asserts the bumped version has a matching `### <version> — <date>`
# heading in CHANGELOG.md (the other documented half of the release
# process), and composes with (rather than duplicates) the existing
# changelog-monotonicity-scan.sh (#555) so a release that quietly deletes a
# prior released heading is caught too.
#
# Shallow-clone handling (load-bearing — see "Handle the shallow clone" in
# the issue): actions/checkout defaults to a shallow, single-commit fetch,
# so `origin/main` is NOT guaranteed present. The guard fetches the base
# ref itself, deepening as needed, and SKIPS GRACEFULLY (exit 0, not a
# failure) if the base still cannot be resolved after a bounded number of
# attempts. A guard that hard-fails when it cannot determine the base would
# block every PR the first time that assumption breaks — this property
# matters more than the guard's strictness.
#
# Escape hatch: a `[no-release]` marker anywhere in the commit range's
# messages, OR the RELEASE_BUMP_SKIP_LABEL env var being non-empty (a
# future workflow could set this from a `skip-release` PR label — this
# script has no PR context by default and is not wired to one, per the
# issue's CI-workflow-file constraint).
#
# Portability: written for bash 3.2 (macOS's shipped bash) as well as
# CI's modern bash — no associative arrays, no `mapfile`/`readarray`, no
# `${var,,}` case conversion, no `declare -n`. See issue #839's "macOS
# ships bash 3.2" callout; an earlier PR in this session broke on exactly
# this portability floor.
#
# Run with:
#
#   bash plugins/shipyard/scripts/tests/release-bump-required.test.sh
#
# Env overrides (all optional):
#   RELEASE_BUMP_MANIFEST_PATH   default: plugins/shipyard/.claude-plugin/plugin.json
#   RELEASE_BUMP_CHANGELOG_PATH  default: CHANGELOG.md
#   RELEASE_BUMP_WATCHED_PREFIX  default: plugins/
#   RELEASE_BUMP_BASE_BRANCH     default branch name to try first when
#                                 auto-resolving the merge-base (falls back
#                                 to main, then master)
#   RELEASE_BUMP_SKIP_LABEL      any non-empty value trips the escape hatch

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

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required" >&2
  exit 1
fi

MANIFEST_PATH="${RELEASE_BUMP_MANIFEST_PATH:-plugins/shipyard/.claude-plugin/plugin.json}"
CHANGELOG_PATH="${RELEASE_BUMP_CHANGELOG_PATH:-CHANGELOG.md}"
WATCHED_PREFIX="${RELEASE_BUMP_WATCHED_PREFIX:-plugins/}"
SCANNER="$repo_root/plugins/shipyard/scripts/changelog-monotonicity-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "Release-bump-required gate (issue #839)"
echo

# ── Core helpers ───────────────────────────────────────────────────────────

# rbr_version_gt <a> <b> — true (exit 0) iff <a> is STRICTLY greater than
# <b>, version-aware (sort -V). Equal strings are NOT "greater".
rbr_version_gt() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  local highest
  highest="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
  [[ "$highest" == "$a" ]]
}

# rbr_resolve_merge_base — echoes a resolvable merge-base sha between HEAD
# and the repo's base branch, or returns non-zero if it genuinely cannot be
# determined (no remote configured, base branch not fetchable, or the two
# histories share no common ancestor within a bounded deepen budget).
#
# Must be called with cwd already inside the target repo.
rbr_resolve_merge_base() {
  local base_branch="${RELEASE_BUMP_BASE_BRANCH:-}"
  local branches=()
  if [[ -n "$base_branch" ]]; then
    branches+=("$base_branch")
  fi
  branches+=(main master)

  local b mb
  # Fast path: a usable remote-tracking ref is already present locally
  # (non-shallow clone, or a prior fetch already ran).
  for b in "${branches[@]}"; do
    if git rev-parse --verify "origin/$b" >/dev/null 2>&1; then
      mb="$(git merge-base HEAD "origin/$b" 2>/dev/null)"
      if [[ -n "$mb" ]]; then
        echo "$mb"
        return 0
      fi
    fi
  done

  if ! git remote get-url origin >/dev/null 2>&1; then
    return 1
  fi

  # Shallow clone: origin/main isn't present at all, or the two histories
  # don't overlap within what's already fetched. Fetch the base branch and
  # progressively deepen both sides until a common ancestor surfaces, or
  # give up after a bounded number of attempts.
  local depth
  for depth in 50 500 5000; do
    git fetch --no-tags --deepen="$depth" origin >/dev/null 2>&1 || true
    for b in "${branches[@]}"; do
      if git fetch --no-tags --depth="$depth" origin "$b" >/dev/null 2>&1; then
        mb="$(git merge-base HEAD FETCH_HEAD 2>/dev/null)"
        if [[ -n "$mb" ]]; then
          echo "$mb"
          return 0
        fi
      fi
    done
  done

  # Last resort: fully unshallow. Slower, but correctness beats speed here.
  git fetch --no-tags --unshallow origin >/dev/null 2>&1 || true
  for b in "${branches[@]}"; do
    if git fetch --no-tags origin "${b}:refs/remotes/origin/${b}" >/dev/null 2>&1; then
      mb="$(git merge-base HEAD "origin/$b" 2>/dev/null)"
      if [[ -n "$mb" ]]; then
        echo "$mb"
        return 0
      fi
    fi
  done

  return 1
}

# rbr_check <dir> [<explicit-merge-base-ref>] — the guard itself. Prints
# exactly one line prefixed SKIP:/PASS:/FAIL: to stdout. Exit status 0 for
# SKIP or PASS, 1 for FAIL. Every non-violation outcome (can't resolve base,
# not a git repo, manifest missing at base, etc.) is SKIP, never a hard
# error — per the issue, failing to determine the base must never block a
# PR. FAIL is reserved exclusively for a confirmed, detected violation.
rbr_check() {
  local dir="$1"
  local explicit_base="${2:-}"

  (
    cd "$dir" 2>/dev/null || { echo "SKIP: cannot cd into $dir"; exit 0; }

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "SKIP: $dir is not inside a git work tree"
      exit 0
    fi

    local merge_base
    if [[ -n "$explicit_base" ]]; then
      if ! git rev-parse --verify "${explicit_base}^{commit}" >/dev/null 2>&1; then
        echo "SKIP: explicit base ref '$explicit_base' does not resolve"
        exit 0
      fi
      merge_base="$(git merge-base HEAD "$explicit_base" 2>/dev/null)"
      if [[ -z "$merge_base" ]]; then
        echo "SKIP: could not compute merge-base between HEAD and '$explicit_base'"
        exit 0
      fi
    else
      merge_base="$(rbr_resolve_merge_base)"
      if [[ -z "$merge_base" ]]; then
        echo "SKIP: base ref could not be resolved (shallow clone / no remote) — release-bump gate cannot run, passing rather than blocking the PR"
        exit 0
      fi
    fi

    # Changed files vs merge-base. Comparing against the working tree (not
    # HEAD) rather than "merge-base...HEAD" means this also works pre-commit
    # (a worker's local pre-push run) and is identical to a HEAD-vs-base
    # diff once everything is committed (CI's case). `git diff` alone never
    # reports untracked files (by design), so a brand-new file under
    # plugins/** that hasn't been `git add`ed yet would otherwise be
    # invisible to this check — union in `git ls-files --others` to catch it.
    local changed
    changed="$( { git diff --name-only "$merge_base" -- . 2>/dev/null; \
                  git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
    if ! printf '%s\n' "$changed" | grep -q "^${WATCHED_PREFIX}"; then
      echo "PASS: diff vs merge-base ($merge_base) does not touch ${WATCHED_PREFIX}** — release bump not required"
      exit 0
    fi

    # Escape hatch #1: env override (e.g. a future workflow wiring a
    # `skip-release` PR label through to this script).
    if [[ -n "${RELEASE_BUMP_SKIP_LABEL:-}" ]]; then
      echo "PASS: escape hatch honored — RELEASE_BUMP_SKIP_LABEL='${RELEASE_BUMP_SKIP_LABEL}'"
      exit 0
    fi

    # Escape hatch #2: a `[no-release]` marker anywhere in the commit
    # range's messages. No-op (and harmless) when merge_base == HEAD, since
    # the range is then empty.
    if git log --format=%B "${merge_base}..HEAD" 2>/dev/null | grep -qF '[no-release]'; then
      echo "PASS: escape hatch honored — [no-release] marker found in ${merge_base}..HEAD"
      exit 0
    fi

    if [[ ! -f "$MANIFEST_PATH" ]]; then
      echo "SKIP: $MANIFEST_PATH missing from working tree despite ${WATCHED_PREFIX}** changes — nothing to compare"
      exit 0
    fi

    local head_version
    head_version="$(jq -r '.version // empty' "$MANIFEST_PATH" 2>/dev/null)"
    if [[ -z "$head_version" ]]; then
      echo "SKIP: could not read .version from $MANIFEST_PATH"
      exit 0
    fi

    local base_version
    base_version="$(git show "${merge_base}:${MANIFEST_PATH}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
    if [[ -z "$base_version" ]]; then
      echo "SKIP: $MANIFEST_PATH did not exist (or had no .version) at merge-base ($merge_base) — nothing to compare"
      exit 0
    fi

    if ! rbr_version_gt "$head_version" "$base_version"; then
      echo "FAIL: ${WATCHED_PREFIX}** changed but ${MANIFEST_PATH}'s .version was not bumped (base=${base_version}, head=${head_version}) — see https://github.com/mattsears18/shipyard/issues/839"
      exit 1
    fi

    if [[ ! -f "$CHANGELOG_PATH" ]]; then
      echo "FAIL: version bumped to ${head_version} but ${CHANGELOG_PATH} is missing"
      exit 1
    fi
    if ! grep -qF "### ${head_version} — " "$CHANGELOG_PATH"; then
      echo "FAIL: version bumped to ${head_version} but no matching '### ${head_version} — <date>' heading found in ${CHANGELOG_PATH}"
      exit 1
    fi

    # Compose with (don't duplicate) the existing heading-deletion detector —
    # a release that bumps the version and adds its own heading but silently
    # deletes a PRIOR released heading in the same edit is still a broken
    # release. Skip this layer if the scanner binary isn't present (older
    # plugin installation) rather than hard-failing on a missing dependency.
    if [[ -f "$SCANNER" ]]; then
      if ! bash "$SCANNER" "$merge_base" >/dev/null 2>&1; then
        echo "FAIL: version bumped to ${head_version} correctly, but changelog-monotonicity-scan detected a deleted released heading — see https://github.com/mattsears18/shipyard/issues/555"
        exit 1
      fi
    fi

    echo "PASS: ${WATCHED_PREFIX}** changed and ${MANIFEST_PATH} bumped ${base_version} -> ${head_version} with a matching CHANGELOG heading"
    exit 0
  )
}

# ── (1) Live gate — this run's actual verdict on THIS PR/push ────────────────
# This is not a fixture: it is the guard doing its real job against the
# repo's actual current state, which is why this file needs no separate
# CI workflow wiring — running it IS the gate.
live_result="$(rbr_check "$repo_root")"
live_rc=$?
case "$live_result" in
  FAIL:*)
    bad "live gate: $live_result"
    ;;
  PASS:*|SKIP:*)
    ok "live gate: $live_result"
    ;;
  *)
    bad "live gate: unexpected output '$live_result' (rc=$live_rc)"
    ;;
esac

# ── (2) Regression pin — the real bb31052 violation, from actual repo history ─
# Best-effort: if this clone doesn't have bb31052 and its parent reachable
# (e.g. a genuinely shallow test environment with no way to fetch them),
# skip this section rather than fail the suite — the live gate above and
# the synthetic fixtures below already exercise the same logic paths.
bb_commit="bb31052cd55753ba7b20c7ee1a0cd9893f6080db"
if git -C "$repo_root" rev-parse --verify "${bb_commit}^{commit}" >/dev/null 2>&1 \
  && git -C "$repo_root" rev-parse --verify "${bb_commit}~1^{commit}" >/dev/null 2>&1; then
  # Reproduce the violation exactly: at bb31052, HEAD = bb31052 and the
  # "merge-base" is its own parent (bb31052~1) — both carry plugin.json
  # version 4.0.3, and bb31052 touches plugins/** (the do-work-dispatch
  # workflow-meta fix). The guard must have failed here.
  bb_dir="$(mktemp -d)"
  git -C "$repo_root" worktree add -q --detach "$bb_dir" "$bb_commit" 2>/dev/null
  if [[ -d "$bb_dir/.git" || -f "$bb_dir/.git" ]]; then
    bb_result="$(rbr_check "$bb_dir" "${bb_commit}~1")"
    bb_rc=$?
    if [[ "$bb_rc" -eq 1 && "$bb_result" == FAIL:* ]]; then
      ok "regression pin: guard correctly fails against the real bb31052 violation ($bb_result)"
    else
      bad "regression pin: guard did NOT fail against bb31052 (rc=$bb_rc, output: $bb_result) — the motivating violation would have shipped undetected"
    fi
    git -C "$repo_root" worktree remove --force "$bb_dir" >/dev/null 2>&1 || true
  else
    echo "  (skip) could not materialize a worktree at $bb_commit — skipping the bb31052 regression pin"
  fi
else
  echo "  (skip) bb31052 / its parent not reachable in this clone — skipping the bb31052 regression pin (shallow test environment)"
fi

# ── (3) Synthetic behavioral fixtures ─────────────────────────────────────────
# Isolated temp git repos so each scenario is deterministic and independent
# of the real repo's history. Mirrors the manifest/changelog layout of the
# real repo so the fixtures exercise the exact same code paths.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture_init() {
  local dir="$1"
  mkdir -p "$dir/plugins/shipyard/.claude-plugin"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
}

fixture_write_manifest() {
  local dir="$1" version="$2"
  printf '{\n  "name": "shipyard",\n  "version": "%s"\n}\n' "$version" \
    > "$dir/plugins/shipyard/.claude-plugin/plugin.json"
}

fixture_write_changelog() {
  local dir="$1"
  shift
  {
    echo "# Changelog"
    echo
    echo "## shipyard"
    echo
    for entry in "$@"; do
      echo "### ${entry}"
      echo
      echo "Release notes."
      echo
    done
  } > "$dir/CHANGELOG.md"
}

fixture_commit() {
  local dir="$1" msg="$2"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
}

# (3a) CLEAN BUMP: plugins/** touched, version bumped, matching heading → PASS
fix_a="$work/clean-bump"
fixture_init "$fix_a"
fixture_write_manifest "$fix_a" "1.0.0"
fixture_write_changelog "$fix_a" "1.0.0 — 2026-01-01"
fixture_commit "$fix_a" "base"
fixture_write_manifest "$fix_a" "1.1.0"
fixture_write_changelog "$fix_a" "1.1.0 — 2026-01-02" "1.0.0 — 2026-01-01"
echo "new feature" >> "$fix_a/plugins/shipyard/.claude-plugin/plugin.json.marker" 2>/dev/null || true
mkdir -p "$fix_a/plugins/shipyard/scripts"
echo "# new script" > "$fix_a/plugins/shipyard/scripts/new-thing.sh"
fixture_commit "$fix_a" "head: bump + new script"
res="$(rbr_check "$fix_a" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 0 && "$res" == PASS:* ]]; then
  ok "(3a) clean bump: plugins touched + version bumped + heading present → PASS ($res)"
else
  bad "(3a) clean bump: expected PASS, got rc=$rc: $res"
fi

# (3b) VIOLATION: plugins/** touched, version NOT bumped → FAIL
fix_b="$work/no-bump"
fixture_init "$fix_b"
fixture_write_manifest "$fix_b" "1.0.0"
fixture_write_changelog "$fix_b" "1.0.0 — 2026-01-01"
fixture_commit "$fix_b" "base"
mkdir -p "$fix_b/plugins/shipyard/scripts"
echo "fix" > "$fix_b/plugins/shipyard/scripts/fixed-thing.sh"
fixture_commit "$fix_b" "head: fix without a version bump"
res="$(rbr_check "$fix_b" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 1 && "$res" == FAIL:* ]]; then
  ok "(3b) violation: plugins touched, no version bump → FAIL ($res)"
else
  bad "(3b) violation: expected FAIL, got rc=$rc: $res"
fi

# (3c) DOWNGRADE: plugins/** touched, version went DOWN → FAIL (strictly-greater)
fix_c="$work/downgrade"
fixture_init "$fix_c"
fixture_write_manifest "$fix_c" "2.0.0"
fixture_write_changelog "$fix_c" "2.0.0 — 2026-01-01"
fixture_commit "$fix_c" "base"
fixture_write_manifest "$fix_c" "1.9.9"
fixture_write_changelog "$fix_c" "1.9.9 — 2026-01-02" "2.0.0 — 2026-01-01"
mkdir -p "$fix_c/plugins/shipyard/scripts"
echo "oops" > "$fix_c/plugins/shipyard/scripts/oops.sh"
fixture_commit "$fix_c" "head: accidental downgrade"
res="$(rbr_check "$fix_c" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 1 && "$res" == FAIL:* ]]; then
  ok "(3c) downgrade: version went down → FAIL, not just 'different' ($res)"
else
  bad "(3c) downgrade: expected FAIL, got rc=$rc: $res"
fi

# (3d) MISSING CHANGELOG HEADING: version bumped but no matching heading → FAIL
fix_d="$work/no-heading"
fixture_init "$fix_d"
fixture_write_manifest "$fix_d" "1.0.0"
fixture_write_changelog "$fix_d" "1.0.0 — 2026-01-01"
fixture_commit "$fix_d" "base"
fixture_write_manifest "$fix_d" "1.1.0"
# CHANGELOG NOT updated with a 1.1.0 heading.
mkdir -p "$fix_d/plugins/shipyard/scripts"
echo "x" > "$fix_d/plugins/shipyard/scripts/x.sh"
fixture_commit "$fix_d" "head: bump manifest, forget CHANGELOG"
res="$(rbr_check "$fix_d" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 1 && "$res" == FAIL:* ]] && printf '%s' "$res" | grep -qF "CHANGELOG"; then
  ok "(3d) missing heading: version bumped but CHANGELOG heading absent → FAIL ($res)"
else
  bad "(3d) missing heading: expected a CHANGELOG-naming FAIL, got rc=$rc: $res"
fi

# (3e) NOT APPLICABLE: no plugins/** files touched → PASS
fix_e="$work/not-applicable"
fixture_init "$fix_e"
fixture_write_manifest "$fix_e" "1.0.0"
fixture_write_changelog "$fix_e" "1.0.0 — 2026-01-01"
echo "hello" > "$fix_e/README.md"
fixture_commit "$fix_e" "base"
echo "world" >> "$fix_e/README.md"
fixture_commit "$fix_e" "head: docs-only, no plugins/ touch, no bump"
res="$(rbr_check "$fix_e" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 0 && "$res" == PASS:* ]]; then
  ok "(3e) not applicable: no plugins/** changes → PASS without requiring a bump ($res)"
else
  bad "(3e) not applicable: expected PASS, got rc=$rc: $res"
fi

# (3f) ESCAPE HATCH — commit-message marker: plugins/** touched, no bump,
# but a [no-release] marker in the commit range → PASS
fix_f="$work/no-release-marker"
fixture_init "$fix_f"
fixture_write_manifest "$fix_f" "1.0.0"
fixture_write_changelog "$fix_f" "1.0.0 — 2026-01-01"
fixture_commit "$fix_f" "base"
mkdir -p "$fix_f/plugins/shipyard/scripts"
echo "internal only" > "$fix_f/plugins/shipyard/scripts/internal.sh"
fixture_commit "$fix_f" "chore(internal): test-only tweak [no-release]"
res="$(rbr_check "$fix_f" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 0 && "$res" == PASS:* ]] && printf '%s' "$res" | grep -qF "escape hatch"; then
  ok "(3f) escape hatch: [no-release] commit marker honored → PASS ($res)"
else
  bad "(3f) escape hatch: expected an escape-hatch PASS, got rc=$rc: $res"
fi

# (3g) ESCAPE HATCH — env override: plugins/** touched, no bump, but
# RELEASE_BUMP_SKIP_LABEL set → PASS
fix_g="$work/skip-label"
fixture_init "$fix_g"
fixture_write_manifest "$fix_g" "1.0.0"
fixture_write_changelog "$fix_g" "1.0.0 — 2026-01-01"
fixture_commit "$fix_g" "base"
mkdir -p "$fix_g/plugins/shipyard/scripts"
echo "internal only" > "$fix_g/plugins/shipyard/scripts/internal2.sh"
fixture_commit "$fix_g" "chore(internal): another test-only tweak"
res="$(RELEASE_BUMP_SKIP_LABEL="skip-release" rbr_check "$fix_g" "HEAD~1")"; rc=$?
if [[ "$rc" -eq 0 && "$res" == PASS:* ]] && printf '%s' "$res" | grep -qF "RELEASE_BUMP_SKIP_LABEL"; then
  ok "(3g) escape hatch: RELEASE_BUMP_SKIP_LABEL env override honored → PASS ($res)"
else
  bad "(3g) escape hatch: expected an env-override PASS, got rc=$rc: $res"
fi

# (3h) UNRESOLVABLE BASE: no remote configured, no explicit base given →
# SKIP (never FAIL) — the shallow-clone-can't-determine-base case, minus
# the network machinery (exercised for real in (3i) below).
fix_h="$work/unresolvable-base"
fixture_init "$fix_h"
fixture_write_manifest "$fix_h" "1.0.0"
fixture_write_changelog "$fix_h" "1.0.0 — 2026-01-01"
fixture_commit "$fix_h" "only commit"
res="$(rbr_check "$fix_h")"; rc=$?
if [[ "$rc" -eq 0 && "$res" == SKIP:* ]]; then
  ok "(3h) unresolvable base: no remote, no explicit ref → SKIP, not FAIL ($res)"
else
  bad "(3h) unresolvable base: expected SKIP, got rc=$rc: $res"
fi

# (3i) REAL SHALLOW CLONE: reproduce the actual CI failure mode end-to-end —
# a genuinely shallow `git clone --depth=1` checkout (origin/main NOT
# reachable via a simple parent-pointer walk) must still resolve the
# merge-base via rbr_resolve_merge_base's fetch+deepen logic, entirely over
# a local file:// remote (no real network required). This is the strongest
# proof of the issue's core "handle the shallow clone" requirement.
bare="$work/origin.git"
git init -q --bare -b main "$bare"

seed="$work/seed"
fixture_init "$seed"
git -C "$seed" remote add origin "file://$bare"
fixture_write_manifest "$seed" "1.0.0"
fixture_write_changelog "$seed" "1.0.0 — 2026-01-01"
fixture_commit "$seed" "c1: initial"
# c2: the eventual PR's fork point — still 1.0.0, includes plugins/ already.
echo "seed" > "$seed/plugins/shipyard/.claude-plugin/seed-marker"
fixture_commit "$seed" "c2: fork point"
git -C "$seed" push -q origin main
fork_point="$(git -C "$seed" rev-parse HEAD)"
# c3: main advances past the fork point with an unrelated, correctly
# version-bumped release, so main's tip is NOT the PR's parent.
fixture_write_manifest "$seed" "1.1.0"
fixture_write_changelog "$seed" "1.1.0 — 2026-01-03" "1.0.0 — 2026-01-01"
fixture_commit "$seed" "c3: unrelated release, main moves on"
git -C "$seed" push -q origin main

# c4: the "PR" branches from the fork point (c2) — a violation commit that
# touches plugins/** without bumping the version.
git -C "$seed" checkout -q -b pr-branch "$fork_point"
mkdir -p "$seed/plugins/shipyard/scripts"
echo "pr change" > "$seed/plugins/shipyard/scripts/pr-change.sh"
fixture_commit "$seed" "c4: PR change, no version bump"
git -C "$seed" push -q origin pr-branch

# Now take a GENUINELY shallow clone of just the PR branch tip — depth=1
# means c4 has NO parent info at all, exactly like actions/checkout's
# default `pull_request` behavior.
shallow="$work/shallow-pr"
git clone -q --depth=1 --branch pr-branch --no-single-branch "file://$bare" "$shallow" 2>/dev/null \
  || git clone -q --depth=1 --branch pr-branch "file://$bare" "$shallow" 2>/dev/null

if [[ -d "$shallow/.git" ]] && (cd "$shallow" && git rev-parse --is-shallow-repository 2>/dev/null | grep -q true); then
  res="$(RELEASE_BUMP_BASE_BRANCH=main rbr_check "$shallow")"; rc=$?
  if [[ "$rc" -eq 1 && "$res" == FAIL:* ]]; then
    ok "(3i) real shallow clone: fetch+deepen resolved the merge-base and correctly failed the violation ($res)"
  else
    bad "(3i) real shallow clone: expected FAIL after resolving the base via fetch+deepen, got rc=$rc: $res"
  fi
else
  echo "  (skip) could not produce a genuinely shallow clone in this environment — skipping (3i)"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
