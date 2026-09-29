#!/usr/bin/env bash
# Test: `shipyard-config.sh get` warns when the checkout it reads from is
# behind its upstream on shipyard.config.json (issue #1610).
#
# Background
# ----------
# The repo layer is read from a WORKING TREE. #1610's repro (session
# do-work-20260928T134101Z-17500 against mattsears18/lightwork): lightwork
# PR #5438 declared 18 `version_coordination.generated_paths` entries and
# merged; the orchestrator confirmed them on origin/main, then told a
# fix-rebase worker to verify with
#   SHIPYARD_REPO_ROOT=<primary checkout> shipyard-config.sh get \
#     version_coordination.generated_paths
# and bail if empty. The primary's working tree had not pulled #5438, so
# the read returned `[]` — indistinguishable from "not declared" — and a
# correct rebase would have been discarded had the worker obeyed.
#
# The fix: `get` emits a `[config-behind]` stderr warning when the resolved
# root's HEAD lacks upstream commits touching shipyard.config.json. stdout
# and the exit status are unchanged (advisory only), a checkout's own local
# edits are never reported (commit-based predicate), and anything the check
# cannot resolve stays silent (no false positives).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done
if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

config_helper="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "0" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$desc"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$desc"
    fail=$((fail + 1))
  fi
}

assert_streq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    check "$desc" 0
  else
    check "$desc (expected '$expected', got '$actual')" 1
  fi
}

assert_has() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then check "$desc" 0; else check "$desc (missing '$needle')" 1; fi
}

assert_lacks() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then check "$desc" 0; else check "$desc (unexpected '$needle')" 1; fi
}

echo "config-behind-upstream warning regression tests (issue #1610)"
echo

# --- Static assertions -------------------------------------------------

grep -q 'warn_if_repo_layer_behind' "$config_helper"
check "shipyard-config.sh defines and calls the behind-upstream check" "$?"

grep -q 'SHIPYARD_CONFIG_BEHIND_WARN' "$config_helper"
check "shipyard-config.sh documents the SHIPYARD_CONFIG_BEHIND_WARN opt-out" "$?"

grep -q 'issues/1610' "$fix_rebase"
check "fix-rebase.md §4.7 cites issue #1610" "$?"

grep -q 'get version_coordination.generated_paths 2>/dev/null' "$fix_rebase"
rc=$?
check "fix-rebase.md §4.7 no longer discards the generated_paths read's stderr" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

grep -q 'never assert "not declared" from a read that could be stale' "$fix_rebase"
check "fix-rebase.md §4.7 forbids asserting 'not declared' from a possibly-stale read" "$?"

grep -ql 'issues/1610' "$setup_dir"/*.md 2>/dev/null
check "the repo-root-pin setup fragment cites issue #1610" "$?"

grep -ql "Never hand a dispatched worker the pinned primary checkout" "$setup_dir"/*.md 2>/dev/null
check "the setup fragment forbids pointing a worker's precondition check at the pinned primary" "$?"

# --- Functional ---------------------------------------------------------

tmp_src="$(mktemp -d)"
tmp_clone="$(mktemp -d)"
tmp_home="$(mktemp -d)"
tmp_plain="$(mktemp -d)"
rmdir "$tmp_clone"
trap 'rm -rf "$tmp_src" "$tmp_clone" "$tmp_home" "$tmp_plain"' EXIT

gitc() { git -c user.email=t@t -c user.name=t "$@"; }

printf '%s\n' '{"version":1}' > "$tmp_src/shipyard.config.json"
git -C "$tmp_src" init -q
git -C "$tmp_src" checkout -q -b main
gitc -C "$tmp_src" add -A
gitc -C "$tmp_src" commit -q -m init
git clone -q "$tmp_src" "$tmp_clone"

run_get() {
  # $1 = root; remaining = extra env assignments via env(1)
  local root="$1"; shift
  env SHIPYARD_HOME="$tmp_home" SHIPYARD_REPO_ROOT="$root" "$@" \
    "$config_helper" get version_coordination.generated_paths
}

# Scenario 1: fresh clone — no warning.
err=$(run_get "$tmp_clone" 2>&1 >/dev/null)
assert_lacks "fresh checkout: no [config-behind] warning" "[config-behind]" "$err"

# Scenario 2: the #1610 repro — upstream declares generated_paths, the clone
# fetched but did not pull (exactly the orchestrator's frozen primary).
printf '%s\n' '{"version":1,"version_coordination":{"generated_paths":[{"path":"gen/hash.json","command":"npm run gen"}]}}' \
  > "$tmp_src/shipyard.config.json"
gitc -C "$tmp_src" commit -q -am "declare generated_paths"
git -C "$tmp_clone" fetch -q origin

out=$(run_get "$tmp_clone" 2>/dev/null)
assert_streq "stale checkout: stdout is still the working tree's value (unchanged contract)" "[]" "$out"
err=$(run_get "$tmp_clone" 2>&1 >/dev/null)
assert_has "stale checkout: [config-behind] warning on stderr" "[config-behind]" "$err"
assert_has "warning names the upstream ref" "origin/main" "$err"
assert_has "warning names the upstream commit count" "1 upstream commit(s)" "$err"
run_get "$tmp_clone" >/dev/null 2>&1
check "stale checkout: exit status stays 0 (advisory, not a gate)" "$?"

# Scenario 3: opt-out.
err=$(run_get "$tmp_clone" SHIPYARD_CONFIG_BEHIND_WARN=0 2>&1 >/dev/null)
assert_lacks "SHIPYARD_CONFIG_BEHIND_WARN=0 silences the warning" "[config-behind]" "$err"

# Scenario 4: an upstream commit that does NOT touch the config is not
# reported — the predicate is path-limited.
git -C "$tmp_clone" merge -q --ff-only origin/main
printf 'x\n' > "$tmp_src/README.md"
gitc -C "$tmp_src" add README.md
gitc -C "$tmp_src" commit -q -m "unrelated"
git -C "$tmp_clone" fetch -q origin
err=$(run_get "$tmp_clone" 2>&1 >/dev/null)
assert_lacks "behind only on unrelated paths: no warning" "[config-behind]" "$err"
out=$(run_get "$tmp_clone" 2>/dev/null)
assert_streq "after pulling, the declaration is read" '[{"path":"gen/hash.json","command":"npm run gen"}]' "$out"

# Scenario 5: a checkout's own local (committed) config edit is not stale.
git -C "$tmp_clone" merge -q --ff-only origin/main
printf '%s\n' '{"version":1}' > "$tmp_clone/shipyard.config.json"
gitc -C "$tmp_clone" commit -q -am "local branch edits config"
err=$(run_get "$tmp_clone" 2>&1 >/dev/null)
assert_lacks "a local branch's own config edit is not reported as behind" "[config-behind]" "$err"

# Scenario 6: not a git tree at all — silent.
printf '%s\n' '{"version":1}' > "$tmp_plain/shipyard.config.json"
err=$(run_get "$tmp_plain" 2>&1 >/dev/null)
assert_lacks "non-git root: no warning" "[config-behind]" "$err"

# Scenario 7: a git repo with no origin — silent.
git -C "$tmp_src" checkout -q main
err=$(run_get "$tmp_src" 2>&1 >/dev/null)
assert_lacks "repo with no origin remote: no warning" "[config-behind]" "$err"

echo
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
