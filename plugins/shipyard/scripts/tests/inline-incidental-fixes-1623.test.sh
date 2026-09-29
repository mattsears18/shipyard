#!/usr/bin/env bash
#
# inline-incidental-fixes-1623.test.sh
#
# Pins issue #1623: an issue-work worker MAY fix an incidental problem it
# finds in the same PR, instead of being required to file a follow-up issue.
#
# The rule it replaces ("file new issues ... don't fix them here. Scope creep
# makes PRs unreviewable and stalls auto-merge.") rested on TWO claims, and
# only one of them survived:
#
#   (a) "makes PRs unreviewable" - assumes a human reads the diff. False for
#       a repo whose worker PRs land via auto-merge with no reviewer, while
#       the cost (an issue per finding, plus a second full worker dispatch to
#       re-derive a diagnosis the first worker already held) is paid always.
#   (b) "stalls auto-merge" - survives. A larger diff has more surface to red
#       a required check, and a red check stalls auto-merge.
#
# So this suite asserts the prohibition is GONE and the bound is KEPT, at
# every site - and that two adjacent rules were NOT collaterally relaxed.
#
# The old text is swept for across the whole plugin tree rather than a fixed
# file list, so a site that reintroduces it fails by construction and names
# itself. Narrowing that sweep to clear a failure defeats the suite.
#
# Run:
#   bash plugins/shipyard/scripts/tests/inline-incidental-fixes-1623.test.sh

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

plugin_root="$repo_root/plugins/shipyard"
issue_work_path="$plugin_root/agents/issue-worker/issue-work.md"
fragment_path="$plugin_root/agents/issue-worker/issue-work-verification-dispatch.md"
dispatch_rules_path="$plugin_root/commands/do-work/dispatch-rules.md"
milestone_path="$plugin_root/skills/worker-preamble/milestone-prohibition.md"
schema_path="$plugin_root/schemas/shipyard.config.schema.json"
config_sh_path="$plugin_root/scripts/shipyard-config.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

record_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass + 1))
}

record_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail + 1))
}

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    record_fail "$label (file missing: $path)"
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    record_pass "$label"
  else
    record_fail "$(printf '%s (did not find %q in %s)' "$label" "$needle" "$path")"
  fi
}

assert_not_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    record_fail "$label (file missing: $path)"
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    record_fail "$(printf '%s (unexpectedly found %q in %s)' "$label" "$needle" "$path")"
  else
    record_pass "$label"
  fi
}

echo "== inline-incidental-fixes-1623.test.sh =="

# --- (A) Tree-wide sweep: the old prohibition is gone everywhere ---------
# Default-deny. A new or restored site naming either phrase fails here.
sweep_hits=""
sweep_hits="$(grep -rlF -e 'Scope creep makes PRs unreviewable' -e 'never fixed inline' "$plugin_root" --include='*.md' 2>/dev/null || true)"
if [[ -z "$sweep_hits" ]]; then
  record_pass "no file under plugins/shipyard still carries the old prohibition wording"
else
  record_fail "old prohibition wording survives in: $(echo "$sweep_hits" | tr '\n' ' ')"
fi

# --- (B) issue-work.md: the permission, and the bound that replaced it ---
assert_contains "$issue_work_path" "you may fix it in this PR" \
  "issue-work.md permits fixing an incidental finding in the same PR"
assert_contains "$issue_work_path" "the test is CI risk, not diff size" \
  "issue-work.md names CI risk (not diff size) as the test"
assert_contains "$issue_work_path" "a red check stalls auto-merge, the cost this bound protects" \
  "issue-work.md preserves the surviving auto-merge half of the original rationale"
assert_contains "$issue_work_path" "File a follow-up issue instead" \
  "issue-work.md keeps a filing path for out-of-bound findings"
assert_contains "$issue_work_path" "Also fixed while here:" \
  "issue-work.md requires the incidental fix be named in the PR body"
assert_contains "$issue_work_path" "\`scope.inline_incidental_fixes\`" \
  "issue-work.md names the config knob that gates the behavior"

# --- (C) Negative controls: two adjacent rules must NOT have moved -------
# The bullet above the changed one is about DESIGN restraint, a different
# rule; relaxing it would be collateral damage, not this issue's mandate.
assert_contains "$issue_work_path" "No drive-by refactors, no unrelated cleanups." \
  "NEGATIVE CONTROL: the drive-by-refactor prohibition is unchanged"
assert_contains "$issue_work_path" "Does not relax the bullet above." \
  "issue-work.md explicitly disclaims relaxing the drive-by-refactor rule"
# The orchestrator-supplied phase-1 slice boundary is a decomposition
# decision, not incidental scope creep, and still binds.
assert_contains "$dispatch_rules_path" "phase_1_scope" \
  "NEGATIVE CONTROL: the phase-1 slice boundary still exists in dispatch-rules.md"

# --- (D) dispatch-rules.md quotes the NEW rule, not the old one ---------
assert_contains "$dispatch_rules_path" "you may fix it in this PR when it sits in the same area and needs no design decision" \
  "dispatch-rules.md's inlined quote carries the new rule"
assert_not_contains "$dispatch_rules_path" "don't fix them here" \
  "dispatch-rules.md no longer inlines the old prohibition"

# --- (E) verification fragment: widened, still bounded ------------------
assert_contains "$fragment_path" "In scope — a bug you have already diagnosed" \
  "verification fragment admits an already-diagnosed bug to the incidental-fix carve-out"
assert_contains "$fragment_path" "The bound is CI risk and unresolved design, not the mere fact that the finding is a bug" \
  "verification fragment states the bound is CI risk and design, not bug-vs-coverage"
assert_contains "$fragment_path" "Never open a *resolving* PR" \
  "verification fragment scopes its no-PR rule to a RESOLVING PR"
assert_contains "$fragment_path" "never a closing keyword" \
  "NEGATIVE CONTROL: the incidental PR still may not close the verification issue"

# --- (F) milestone-prohibition.md's parenthetical agrees ----------------
assert_contains "$milestone_path" "a bug spotted mid-implementation that the worker does not fold into its own PR goes to a new issue" \
  "milestone-prohibition.md's description of the rule matches the new behavior"

# --- (G) the config knob exists, defaults to permitting ------------------
if command -v python3 >/dev/null 2>&1; then
  knob_default="$(python3 -c "
import json,sys
d=json.load(open('$schema_path'))
p=d['properties']['scope']['properties'].get('inline_incidental_fixes')
sys.stdout.write('MISSING' if p is None else str(p.get('default')))
" 2>/dev/null || echo ERROR)"
  if [[ "$knob_default" == "True" ]]; then
    record_pass "schema declares scope.inline_incidental_fixes with default true"
  else
    record_fail "schema's scope.inline_incidental_fixes default is '$knob_default', expected True"
  fi
else
  record_fail "python3 unavailable - cannot validate the schema knob"
fi

assert_contains "$config_sh_path" '"inline_incidental_fixes": true' \
  "shipyard-config.sh's DEFAULTS_JQ carries the knob, defaulting to true"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail"
  exit 1
fi
