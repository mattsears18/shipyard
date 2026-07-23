#!/usr/bin/env bash
# Test: scripts/assert-worktree-cwd.sh — the extracted worktree-vs-primary-
# checkout cwd predicate (issue #826).
#
# Background: skills/worker-preamble/SKILL.md § "Step-0 cwd fail-fast" (#486)
# and § "Mid-session cwd anchoring" (#748) both used to inline the same
# git-dir-vs-git-common-dir comparison as a compound `if` + command-
# substitution snippet — a shape the harness's Auto Mode classifier refuses
# to run as one Bash tool call. #826 extracts the comparison into this one
# script so both SKILL.md sections invoke a single hook-friendly command
# instead of duplicating prose that can drift out of sync (the same fix #716
# applied to the ungated-admin-direct-merge rule).
#
# This test exercises the SCRIPT directly (pass/fail/error paths) — distinct
# from worktree-cwd-fail-fast.test.sh, which exercises the pre-#826 inline
# predicate and greps SKILL.md for its wiring. Both tests co-exist: this one
# guards the script's own behavior; that one guards that SKILL.md still cites
# the git-common-dir signal (now via the script) rather than silently
# dropping the guard.
#
# Pure bash + git, no network, no external deps. Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-worktree-cwd.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../assert-worktree-cwd.sh"

echo "assert-worktree-cwd.sh tests (issue #826)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

# Build fixtures: a throwaway primary checkout + a linked worktree, mirroring
# worktree-cwd-fail-fast.test.sh's fixture shape. Pin the default branch
# (worker-preamble § "Pin the default branch in git-using test fixtures",
# issue #475) so the fixture is deterministic regardless of the host's
# init.defaultBranch.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

primary="$tmproot/primary"
git init -q -b main "$primary"
(
  cd "$primary" || exit 1
  git config user.email test@example.com
  git config user.name 'Test User'
  echo "seed" > seed.txt
  git add seed.txt
  git commit -q -m "seed"
)

# --- (1) primary checkout -> `primary` on stdout, exit 1 -------------------
out="$(bash "$script" "$primary" 2>/tmp/assert-worktree-cwd-test-stderr.$$)"
code=$?
if [[ "$out" == "primary" && "$code" -eq 1 ]]; then
  ok "primary checkout: stdout='primary', exit=1"
else
  bad "primary checkout: got stdout='$out' exit=$code (expected 'primary'/1)"
fi
if grep -qF "verdict=primary" "/tmp/assert-worktree-cwd-test-stderr.$$" 2>/dev/null; then
  ok "primary checkout: stderr carries the verdict=primary diagnostic"
else
  bad "primary checkout: stderr missing verdict=primary diagnostic"
fi
rm -f "/tmp/assert-worktree-cwd-test-stderr.$$"

worktree="$primary/.claude/worktrees/agent-deadbeef"
(
  cd "$primary" || exit 1
  git worktree add -q -b do-work/issue-826 "$worktree" >/dev/null 2>&1
)

if [[ -d "$worktree" ]]; then
  # --- (2) linked worktree -> `worktree` on stdout, exit 0 -----------------
  out="$(bash "$script" "$worktree" 2>/dev/null)"
  code=$?
  if [[ "$out" == "worktree" && "$code" -eq 0 ]]; then
    ok "linked worktree: stdout='worktree', exit=0"
  else
    bad "linked worktree: got stdout='$out' exit=$code (expected 'worktree'/0)"
  fi

  # --- (3) subdirectory of the linked worktree — path-independent ----------
  subdir="$worktree/plugins/shipyard"
  mkdir -p "$subdir"
  out="$(bash "$script" "$subdir" 2>/dev/null)"
  code=$?
  if [[ "$out" == "worktree" && "$code" -eq 0 ]]; then
    ok "subdir of linked worktree: stdout='worktree', exit=0 (path-independent detection)"
  else
    bad "subdir of linked worktree: got stdout='$out' exit=$code (expected 'worktree'/0)"
  fi

  # --- (4) subdirectory of the primary checkout — still classifies primary -
  primary_subdir="$primary/some/nested/dir"
  mkdir -p "$primary_subdir"
  out="$(bash "$script" "$primary_subdir" 2>/dev/null)"
  code=$?
  if [[ "$out" == "primary" && "$code" -eq 1 ]]; then
    ok "subdir of primary checkout: stdout='primary', exit=1 (catches nested mispin)"
  else
    bad "subdir of primary checkout: got stdout='$out' exit=$code (expected 'primary'/1)"
  fi

  # --- (5) DIR defaults to cwd when omitted ---------------------------------
  out="$(cd "$worktree" && bash "$script" 2>/dev/null)"
  code=$?
  if [[ "$out" == "worktree" && "$code" -eq 0 ]]; then
    ok "no DIR argument defaults to cwd (invoked from within the linked worktree)"
  else
    bad "no DIR argument: got stdout='$out' exit=$code (expected 'worktree'/0)"
  fi
else
  bad "could not create linked worktree fixture (git worktree add failed)"
fi

# --- (6) DIR outside any git repo -> `error` on stdout, exit 2 -------------
non_git_dir="$tmproot/not-a-repo"
mkdir -p "$non_git_dir"
out="$(bash "$script" "$non_git_dir" 2>/dev/null)"
code=$?
if [[ "$out" == "error" && "$code" -eq 2 ]]; then
  ok "non-git directory: stdout='error', exit=2"
else
  bad "non-git directory: got stdout='$out' exit=$code (expected 'error'/2)"
fi

# --- (7) -h / --help prints usage on stderr and exits 2, without touching git
out_stderr="$(bash "$script" --help 2>&1 1>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "usage: assert-worktree-cwd.sh" <<<"$out_stderr"; then
  ok "--help prints usage on stderr and exits 2"
else
  bad "--help: got exit=$code stderr='$out_stderr' (expected exit 2 + usage text)"
fi

# --- (8) shellcheck-clean (belt-and-suspenders; shellcheck.test.sh also
# discovers this file, but a direct check here fails fast in this suite too).
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$script" >/tmp/assert-worktree-cwd-shellcheck.$$ 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported issues: $(cat "/tmp/assert-worktree-cwd-shellcheck.$$")"
  fi
  rm -f "/tmp/assert-worktree-cwd-shellcheck.$$"
else
  echo "  (shellcheck not installed locally — skipping; CI's shellcheck.yml still gates this)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
