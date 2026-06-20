#!/usr/bin/env bash
# Test suite for hooks/reap-on-session-end.sh — the SessionEnd hook shim
# (#638). Guards the shim contract: it consumes stdin, drives the helper
# end-to-end (a stale worktree-agent-* ref gets reaped through the shim), and
# NEVER exits non-zero (a cleanup failure must not break session exit).
#
# Run with:
#   bash plugins/shipyard/hooks/tests/reap-on-session-end.test.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shim="${here}/../reap-on-session-end.sh"

if [[ ! -f "$shim" ]]; then
  echo "FAIL: shim not found at $shim" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

tmproot=$(mktemp -d -t reap-on-session-end-test.XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '$tmproot'" EXIT

ok() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass + 1))
}
no() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail + 1))
}

make_repo() {
  local d="$1"
  git init -q "$d"
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch worktree-agent-deadbeef
}

# 1) End-to-end through the shim: stale ref reaped, exit 0.
repo="$tmproot/r1"
make_repo "$repo"
printf '{"hook_event_name":"SessionEnd","cwd":"%s","session_id":"s1"}' "$repo" |
  bash "$shim" >/dev/null 2>&1
rc=$?
if [[ "$rc" == 0 ]]; then ok "shim exits 0"; else no "shim exits 0 (got $rc)"; fi
if git -C "$repo" show-ref --verify --quiet refs/heads/worktree-agent-deadbeef; then
  no "shim drives the helper (stale ref reaped end-to-end)"
else
  ok "shim drives the helper (stale ref reaped end-to-end)"
fi

# 2) Empty stdin → still exits 0 (consumes stdin, no SIGPIPE, no error).
if echo -n "" | bash "$shim" >/dev/null 2>&1; then ok "exits 0 on empty stdin"; else no "exits 0 on empty stdin"; fi

# 3) Garbage stdin → still exits 0 (never breaks session exit).
if printf 'not json at all' | bash "$shim" >/dev/null 2>&1; then ok "exits 0 on non-JSON stdin"; else no "exits 0 on non-JSON stdin"; fi

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
