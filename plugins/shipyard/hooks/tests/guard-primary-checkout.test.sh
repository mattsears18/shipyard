#!/usr/bin/env bash
# Test suite for hooks/guard-primary-checkout.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/guard-primary-checkout.test.sh
#
# The hook is the primary-checkout guard, wired into hooks.json by default as
# of issue #741 (previously it was opt-in-only via /shipyard:init, issue
# #482). It fires (warn or block, per SHIPYARD_PRIMARY_GUARD) when an
# Edit/Write/MultiEdit/NotebookEdit or a write-class git Bash call (commit,
# checkout, switch, reset, branch -d/-D/-f, merge, rebase, cherry-pick,
# stash, clean) runs in the repo's PRIMARY checkout rather than a linked
# worktree. It allows everything in a linked worktree, allows read-class git
# and other non-mutating tools, and fails open on any uncertainty.
#
# Each test crafts a PreToolUse JSON payload, pipes it to the hook with a given
# SHIPYARD_PRIMARY_GUARD mode + cwd, and asserts on exit code + stderr.
# Exit 2 == blocked. Exit 0 == allowed (transparent or warn-only).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../guard-primary-checkout.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

# The hook shells out to git + jq.
for dep in git jq python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "SKIP: $dep not available" >&2; exit 0; }
done

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Build a real git primary checkout + a linked worktree so the hook's git
# detection (--absolute-git-dir vs --git-common-dir) runs against true state,
# not a mocked layout.
TMP=$(mktemp -d -t shipyard-primary-guard-test.XXXXXX)
trap 'git -C "$TMP/primary" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT

PRIMARY="$TMP/primary"
mkdir -p "$PRIMARY"
git -C "$PRIMARY" init -q -b main
git -C "$PRIMARY" config user.email t@t.t
git -C "$PRIMARY" config user.name t
git -C "$PRIMARY" commit -q --allow-empty -m init
git -C "$PRIMARY" worktree add -q "$PRIMARY/.claude/worktrees/agent-deadbeef" >/dev/null 2>&1
WT="$PRIMARY/.claude/worktrees/agent-deadbeef"

NONREPO="$TMP/not-a-repo"
mkdir -p "$NONREPO"

# Helper — invoke hook with payload on stdin, a given mode + cwd.
# Returns "<exit_code>::<stderr>".
run_hook() {
  local mode="$1" payload="$2"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | SHIPYARD_PRIMARY_GUARD="$mode" bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1" want="$2" label="$3"
  local got="${result%%::*}"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (want exit %s, got %s)\n' "$RED" "$RESET" "$label" "$want" "$got"
    printf '    stderr: %s\n' "${result#*::}"; fail=$((fail+1))
  fi
}

assert_blocked_with() {
  local result="$1" needle="$2" label="$3"
  local got="${result%%::*}" stderr="${result#*::}"
  if [[ "$got" == "2" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 2 and stderr containing %q\n    got exit %s, stderr: %s\n' "$needle" "$got" "$stderr"
    fail=$((fail+1))
  fi
}

assert_warned_with() {
  local result="$1" needle="$2" label="$3"
  local got="${result%%::*}" stderr="${result#*::}"
  if [[ "$got" == "0" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 0 and stderr containing %q\n    got exit %s, stderr: %s\n' "$needle" "$got" "$stderr"
    fail=$((fail+1))
  fi
}

editpayload() {
  # Args: tool_name, file_path, cwd
  python3 -c "
import json,sys
print(json.dumps({'tool_name': sys.argv[1], 'cwd': sys.argv[3],
                  'tool_input': {'file_path': sys.argv[2]}}))" "$1" "$2" "$3"
}
bashpayload() {
  # Args: command, cwd
  python3 -c "
import json,sys
print(json.dumps({'tool_name': 'Bash', 'cwd': sys.argv[2],
                  'tool_input': {'command': sys.argv[1]}}))" "$1" "$2"
}

# -----------------------------------------------------------------------------
echo "== block mode: edits in the primary checkout are blocked"
# -----------------------------------------------------------------------------
for tool in Edit Write MultiEdit NotebookEdit; do
  out=$(run_hook block "$(editpayload "$tool" "$PRIMARY/file.txt" "$PRIMARY")")
  assert_blocked_with "$out" "PRIMARY checkout" "$tool in primary → blocked"
done

# -----------------------------------------------------------------------------
echo "== block mode: edits in a linked worktree are allowed"
# -----------------------------------------------------------------------------
for tool in Edit Write MultiEdit NotebookEdit; do
  out=$(run_hook block "$(editpayload "$tool" "$WT/file.txt" "$WT")")
  assert_exit "$out" "0" "$tool in linked worktree → allowed"
done

# -----------------------------------------------------------------------------
echo "== block message leads with the EnterWorktree tool (issue #482 comment)"
# -----------------------------------------------------------------------------
out=$(run_hook block "$(editpayload Edit "$PRIMARY/file.txt" "$PRIMARY")")
assert_blocked_with "$out" "EnterWorktree" "block message names EnterWorktree first"

# -----------------------------------------------------------------------------
echo "== git commit Bash calls are in scope; other Bash calls are not"
# -----------------------------------------------------------------------------
out=$(run_hook block "$(bashpayload "git commit -m wip" "$PRIMARY")")
assert_blocked_with "$out" "PRIMARY checkout" "git commit in primary → blocked"

out=$(run_hook block "$(bashpayload "git add -A && git commit -m wip" "$PRIMARY")")
assert_blocked_with "$out" "PRIMARY checkout" "compound git commit in primary → blocked"

out=$(run_hook block "$(bashpayload "git status" "$PRIMARY")")
assert_exit "$out" "0" "git status in primary → allowed (not a mutating commit)"

out=$(run_hook block "$(bashpayload "git log --oneline" "$PRIMARY")")
assert_exit "$out" "0" "git log in primary → allowed"

out=$(run_hook block "$(bashpayload "echo committing" "$PRIMARY")")
assert_exit "$out" "0" "non-git command mentioning commit → allowed"

out=$(run_hook block "$(bashpayload "git commit -m wip" "$WT")")
assert_exit "$out" "0" "git commit in linked worktree → allowed"

# -----------------------------------------------------------------------------
echo "== the full write-class git surface is in scope (issue #741), not just commit"
# -----------------------------------------------------------------------------
# Deny list — every one of these can move the primary's HEAD or dirty its
# index, and #741's repro showed `git checkout -B` slipping past the old
# commit-only gate uncaught.
for cmd in \
  "git checkout -B do-work/issue-741 origin/main" \
  "git checkout main" \
  "git switch main" \
  "git switch -c foo" \
  "git reset --hard HEAD~1" \
  "git branch -D do-work/issue-1" \
  "git branch -d do-work/issue-1" \
  "git branch -f main origin/main" \
  "git merge origin/main" \
  "git rebase main" \
  "git cherry-pick abc123" \
  "git stash" \
  "git stash pop" \
  "git clean -fd" \
  ; do
  out=$(run_hook block "$(bashpayload "$cmd" "$PRIMARY")")
  assert_blocked_with "$out" "PRIMARY checkout" "'$cmd' in primary → blocked"
done

# Allow list — read-class git must keep falling through even after the
# widened gate. The worktree-isolation spec explicitly permits the
# orchestrator and workers to run these against the primary checkout.
for cmd in \
  "git status" \
  "git log --oneline" \
  "git show HEAD" \
  "git diff" \
  "git diff --name-only origin/main...HEAD" \
  "git ls-remote origin" \
  "git rev-parse --show-toplevel" \
  "git worktree list" \
  "git worktree list --porcelain" \
  "git fetch origin" \
  "git branch" \
  "git branch --list" \
  "git branch -a" \
  ; do
  out=$(run_hook block "$(bashpayload "$cmd" "$PRIMARY")")
  assert_exit "$out" "0" "'$cmd' in primary → allowed (read-class)"
done

# The write-class verbs are also allowed once the cwd is a linked worktree —
# the guard gates on cwd, not on the command string alone.
out=$(run_hook block "$(bashpayload "git checkout -B do-work/issue-741 origin/main" "$WT")")
assert_exit "$out" "0" "git checkout -B in linked worktree → allowed"

# The #387 sanctioned corrective write (do-work's primary-checkout
# branch-leak guard) runs `git -C <primary> checkout <default>` from the
# orchestrator's OWN worktree cwd, never from cwd=primary itself. Assert that
# shape stays allowed under the widened gate — the guard must key off cwd,
# not off whether the command string merely mentions a write verb.
out=$(run_hook block "$(bashpayload "git -C \"$PRIMARY\" checkout main 2>/dev/null && git -C \"$PRIMARY\" pull --ff-only 2>/dev/null || true" "$WT")")
assert_exit "$out" "0" "#387 corrective 'git -C <primary> checkout' from a worktree cwd → allowed"

# -----------------------------------------------------------------------------
echo "== warn mode warns but does not block; off mode is a no-op"
# -----------------------------------------------------------------------------
out=$(run_hook warn "$(editpayload Edit "$PRIMARY/file.txt" "$PRIMARY")")
assert_warned_with "$out" "PRIMARY checkout" "warn mode in primary → exit 0 with guidance"

out=$(run_hook off "$(editpayload Edit "$PRIMARY/file.txt" "$PRIMARY")")
assert_exit "$out" "0" "off mode in primary → silent no-op"
if [[ -n "${out#*::}" ]]; then
  printf '  %sFAIL%s  off mode emits no stderr\n    stderr: %s\n' "$RED" "$RESET" "${out#*::}"; fail=$((fail+1))
else
  printf '  %sPASS%s  off mode emits no stderr\n' "$GREEN" "$RESET"; pass=$((pass+1))
fi

# Default mode (env unset) should warn, not block.
default_stderr=$(printf '%s' "$(editpayload Edit "$PRIMARY/file.txt" "$PRIMARY")" | env -u SHIPYARD_PRIMARY_GUARD bash "$hook" 2>&1 >/dev/null)
default_exit=$?
assert_warned_with "${default_exit}::${default_stderr}" "PRIMARY checkout" \
  "unset SHIPYARD_PRIMARY_GUARD defaults to warn (exit 0 with guidance)"

# -----------------------------------------------------------------------------
echo "== non-mutating tools pass through in every mode"
# -----------------------------------------------------------------------------
for tool in Read Grep Glob; do
  out=$(run_hook block "$(editpayload "$tool" "$PRIMARY/file.txt" "$PRIMARY")")
  assert_exit "$out" "0" "$tool in primary → allowed (not a mutating tool)"
done

# -----------------------------------------------------------------------------
echo "== fail-open: not-a-repo, missing fields, malformed input → allowed"
# -----------------------------------------------------------------------------
out=$(run_hook block "$(editpayload Edit "$NONREPO/file.txt" "$NONREPO")")
assert_exit "$out" "0" "edit outside any git repo → allowed (fail-open)"

out=$(run_hook block "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook block "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook block '{"tool_name":"Edit"}')
assert_exit "$out" "0" "missing tool_input/cwd → allowed"

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------
total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"; exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"; exit 1
fi
