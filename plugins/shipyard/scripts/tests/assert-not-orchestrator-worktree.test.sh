#!/usr/bin/env bash
# Test: scripts/assert-not-orchestrator-worktree.sh — the "is this worker's
# worktree actually the /do-work orchestrator's own worktree?" predicate
# (issue #1613), plus the worker-preamble wiring that makes a worker run it.
#
# Pure bash + git, no network. Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-not-orchestrator-worktree.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$here/../.."
script="$here/../assert-not-orchestrator-worktree.sh"

echo "assert-not-orchestrator-worktree.sh tests (issue #1613)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

primary="$tmproot/primary"
git init -q -b main "$primary"
(
  cd "$primary" || exit 1
  git config user.email test@example.com
  git config user.name 'Test User'
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
)

wt_root="$primary/.claude/worktrees"
agent="$wt_root/agent-deadbeef"
orch="$wt_root/orchestrator-do-work-20260929T115546Z-71289"
orch_hand="$wt_root/do-work-orchestrator-20260929"
stash_only="$wt_root/agent-stashleak"
git -C "$primary" worktree add -q -b wt-agent "$agent" >/dev/null 2>&1
git -C "$primary" worktree add -q -b wt-orch "$orch" >/dev/null 2>&1
git -C "$primary" worktree add -q -b wt-orch-hand "$orch_hand" >/dev/null 2>&1
git -C "$primary" worktree add -q -b wt-stash "$stash_only" >/dev/null 2>&1
printf 'do-work-x\n' > "$stash_only/.shipyard-session-id"
mkdir -p "$agent/sub/dir"

check() {
  local label="$1" dir="$2" want_out="$3" want_code="$4"
  local out code
  out="$("$script" "$dir" 2>/dev/null)"
  code=$?
  if [[ "$out" == "$want_out" && "$code" -eq "$want_code" ]]; then
    ok "$label: stdout='$out', exit=$code"
  else
    bad "$label: got stdout='$out' exit=$code (expected '$want_out'/$want_code)"
  fi
}

check "agent-* worktree"                          "$agent"      ok           0
check "agent-* worktree, from a subdirectory"     "$agent/sub/dir" ok        0
check "orchestrator-<session-id> worktree"        "$orch"       orchestrator 1
check "hand-named do-work-orchestrator-* worktree" "$orch_hand" orchestrator 1
check "agent-* worktree carrying .shipyard-session-id" "$stash_only" orchestrator 1
check "non-git directory"                         "$tmproot"    error        2

out="$("$script" 2>/dev/null)"; code=$?
if [[ -z "$out" && "$code" -eq 2 ]]; then ok "missing DIR: usage, exit 2"; else bad "missing DIR: got '$out'/$code"; fi
"$script" --help >/dev/null 2>&1; code=$?
if [[ "$code" -eq 0 ]]; then ok "--help exits 0"; else bad "--help exited $code"; fi

err="$("$script" "$orch" 2>&1 >/dev/null)"
if grep -qF "#1613" <<<"$err"; then ok "orchestrator diagnostic cites #1613"; else bad "orchestrator diagnostic missing #1613: $err"; fi

# The predicate is only worth anything if the always-loaded preamble tells a
# worker to run it at step 0, and the reconcile knows how to route the bail.
skill="$plugin_root/skills/worker-preamble/SKILL.md"
frag="$plugin_root/skills/worker-preamble/orchestrator-worktree-pin.md"
steady="$plugin_root/commands/do-work/steady-state.md"
if grep -qF "assert-not-orchestrator-worktree.sh" "$skill"; then ok "worker-preamble SKILL.md invokes the predicate"; else bad "worker-preamble SKILL.md does not invoke assert-not-orchestrator-worktree.sh"; fi
if grep -qF "orchestrator-worktree-pin.md" "$skill"; then ok "worker-preamble SKILL.md links the fragment"; else bad "SKILL.md does not link orchestrator-worktree-pin.md"; fi
if [[ -f "$frag" ]] && grep -qF "isolation pinned to the orchestrator's worktree" "$frag"; then ok "fragment carries the canonical blocked phrase"; else bad "fragment missing or lacks the canonical blocked phrase"; fi
if grep -qF "isolation pinned to the orchestrator's worktree" "$steady"; then ok "steady-state bail table routes the phrase"; else bad "steady-state.md has no bail-table row for the phrase"; fi

echo
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
exit 1
