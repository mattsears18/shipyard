#!/usr/bin/env bash
# Test suite for scripts/session-end-reap.sh — the SessionEnd backstop reap
# (#638). Guards: (1) a stale worktree-agent-* ref with no worktree IS reaped;
# (2) a non-git cwd is a clean no-op; (3) a missing worktree-reap.sh is a clean
# no-op; (4) cwd is read from the stdin payload when not overridden; (5) the
# helper never exits non-zero.
#
# Pure bash + git. Run with:
#   bash plugins/shipyard/scripts/tests/session-end-reap.test.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../session-end-reap.sh"
plugin_root="$(cd "${here}/../.." && pwd)" # tests/ -> scripts/ -> plugins/shipyard

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

tmproot=$(mktemp -d -t session-end-reap-test.XXXXXX)
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

# Build a throwaway git repo with one stale worktree-agent-* ref (no worktree)
# and one unrelated branch that must be left alone.
make_repo() {
  local d="$1"
  git init -q "$d"
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch worktree-agent-deadbeef
  git -C "$d" branch feature-keep-me
}

# 1) Stale worktree-agent-* ref is reaped; unrelated branch survives.
repo="$tmproot/r1"
make_repo "$repo"
SESSION_END_REAP_CWD="$repo" SESSION_END_REAP_PLUGIN_ROOT="$plugin_root" \
  bash "$helper" </dev/null >/dev/null 2>&1
rc=$?
if [[ "$rc" == 0 ]]; then ok "exits 0 on a normal repo"; else no "exits 0 on a normal repo (got $rc)"; fi
if git -C "$repo" show-ref --verify --quiet refs/heads/worktree-agent-deadbeef; then
  no "stale worktree-agent-* ref reaped"
else
  ok "stale worktree-agent-* ref reaped"
fi
if git -C "$repo" show-ref --verify --quiet refs/heads/feature-keep-me; then
  ok "unrelated branch left untouched"
else
  no "unrelated branch left untouched"
fi

# 2) cwd is read from the stdin payload when not overridden.
repo2="$tmproot/r2"
make_repo "$repo2"
printf '{"hook_event_name":"SessionEnd","cwd":"%s","session_id":"abc"}' "$repo2" |
  SESSION_END_REAP_PLUGIN_ROOT="$plugin_root" bash "$helper" >/dev/null 2>&1
if git -C "$repo2" show-ref --verify --quiet refs/heads/worktree-agent-deadbeef; then
  no "reads cwd from stdin payload"
else
  ok "reads cwd from stdin payload"
fi

# 3) Non-git cwd → clean no-op (exit 0).
if SESSION_END_REAP_CWD="$tmproot" SESSION_END_REAP_PLUGIN_ROOT="$plugin_root" \
  bash "$helper" </dev/null >/dev/null 2>&1; then
  ok "non-git cwd is a clean no-op"
else
  no "non-git cwd is a clean no-op"
fi

# 4) Missing worktree-reap.sh → clean no-op (exit 0), ref left intact.
repo3="$tmproot/r3"
make_repo "$repo3"
SESSION_END_REAP_CWD="$repo3" SESSION_END_REAP_PLUGIN_ROOT="$tmproot/nope" \
  bash "$helper" </dev/null >/dev/null 2>&1
rc=$?
if [[ "$rc" == 0 ]]; then ok "missing worktree-reap.sh is a clean no-op"; else no "missing worktree-reap.sh is a clean no-op (got $rc)"; fi
if git -C "$repo3" show-ref --verify --quiet refs/heads/worktree-agent-deadbeef; then
  ok "no reap attempted when helper script is absent"
else
  no "no reap attempted when helper script is absent"
fi

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
