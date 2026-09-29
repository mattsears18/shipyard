#!/usr/bin/env bash
# Test: issue-work-verification-dispatch.md's absolute "never open a PR"
# rule now carries a narrow, explicit carve-out for an incidental
# test-coverage-only PR — matching the maintainer's own repeated real-world
# dispatch pattern (#3329/PR #3374 on mattsears18/lightwork) — instead of
# unconditionally forbidding it (#1044).
#
# Background: issue-work.md §6.6's on-demand fragment
# (issue-work-verification-dispatch.md) told every verification-dispatch
# worker "Never open a PR for the verification-only path itself" with no
# exception. In practice, two real dispatches against a QA epic did exactly
# the opposite on purpose, at the maintainer's explicit direction: a
# mechanically-verifiable, already-acknowledged test-coverage gap found
# during verification was landed as a small, non-closing (`Refs #<N>`) PR
# rather than deferred to a follow-up `bug` issue. The absolute rule was
# restated (in slightly different words) in five more places beyond the
# fragment the issue names, so this test asserts the carve-out is
# consistently documented everywhere the old absolute wording lived, that
# the "never fix a real bug inline" default is preserved for anything that
# ISN'T a pure coverage gap, and that the load-bearing session_prs
# consequence (an incidental PR needs to be drainable) is wired through the
# structured return schema and its hand-copied Dynamic-Workflows literal.
#
# Pure bash + node/jq for syntax/JSON sanity, no other external deps. Run
# with:
#
#   bash plugins/shipyard/scripts/tests/verification-incidental-coverage-pr-1044.test.sh

# setup-fragment-content-scan: allow-file
# This suite regression-tests a SPECIFIC historical PR (#1044) against the
# exact fragment file (06b-scope-carveouts.md) it touched — its purpose IS
# to verify that particular file, not generic step content that happens to
# live there today (issue #1453).
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

fragment_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work-verification-dispatch.md"
issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
carveouts_path="$repo_root/plugins/shipyard/commands/do-work/setup/06b-scope-carveouts.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
core_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.core.js"
generated_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
parity_checker="$repo_root/plugins/shipyard/scripts/check-worker-return-schema-parity.mjs"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (did not find %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sFAIL%s  %s (unexpectedly found %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  fi
}

echo "== verification-incidental-coverage-pr-1044.test.sh =="

# --- (A) The primary fragment named in the issue documents the narrow carve-out ---
assert_file_exists "$fragment_path" "issue-work-verification-dispatch.md exists"
assert_contains "$fragment_path" "Incidental fix — narrow exception" \
  "fragment documents the narrow incidental-fix exception"
assert_contains "$fragment_path" "zero test coverage that the code itself already acknowledges" \
  "fragment scopes the exception to an already-acknowledged coverage gap, not any trivial fix"
assert_contains "$fragment_path" "Out of scope — file a follow-up \`bug\` issue" \
  "fragment still routes an out-of-bound finding to a follow-up bug issue"
assert_contains "$fragment_path" "The bound is CI risk and unresolved design, not the mere fact that the finding is a bug" \
  "fragment states the bound is CI risk and design, not bug-vs-coverage (#1623)"
assert_contains "$fragment_path" "In scope — a bug you have already diagnosed" \
  "fragment admits an already-diagnosed bug to the incidental-fix carve-out (#1623)"
assert_contains "$fragment_path" "Reference, never close" \
  "fragment states the incidental PR must reference, never close, the verification issue"
assert_contains "$fragment_path" "\`Refs #<N>\`" \
  "fragment names the bare-reference form (Refs #<N>) for the incidental PR"
assert_contains "$fragment_path" "never a closing keyword" \
  "fragment forbids a closing keyword on the incidental PR"
assert_contains "$fragment_path" "Gate auto-merge on \`originating_author_trust\`" \
  "fragment routes the incidental PR through the normal auto-merge trust gate"

# The old ABSOLUTE wording (no exception at all) must be gone.
assert_not_contains "$fragment_path" \
  "**Never open a PR for the verification-only path itself** — there is no code slice to ship. If the audit surfaces something trivially fixable while you're at it, file it as a normal follow-up \`bug\` issue (the auditor already does this) rather than fixing it inline — fixing code is out of scope for a verification dispatch, exactly as scope-creep is out of scope on the code-worker path." \
  "fragment no longer states the never-open-a-PR rule with zero exception"

# The narrowed replacement wording IS present.
assert_contains "$fragment_path" "Step 3's incidental carve-out is the only PR this path may produce" \
  "fragment's closing paragraph names step 3 as the only PR this path may produce"
assert_contains "$fragment_path" "Never open a *resolving* PR" \
  "fragment scopes its no-PR rule to a RESOLVING PR, not all PRs"
assert_contains "$fragment_path" "incidental PR: #<M>" \
  "fragment tells the worker to surface the incidental PR number via step 8's optional suffix"

# --- (B) issue-work.md's own restatements of the rule are updated, not just the fragment ---
assert_file_exists "$issue_work_path" "issue-work.md exists"
assert_contains "$issue_work_path" "the fragment's own step 3 documents one narrow, non-closing exception ([#1044]" \
  "issue-work.md §6.6 stub now names the narrow exception instead of an absolute prohibition"
assert_contains "$issue_work_path" "Don't open a resolving PR, and don't implement anything beyond the narrow coverage-only exception" \
  "issue-work.md's Don't-list bullet is narrowed to 'resolving PR' + the coverage-only exception"
assert_not_contains "$issue_work_path" \
  "Don't open a PR, and don't implement code, on a verification-slice dispatch ([#852](https://github.com/mattsears18/shipyard/issues/852)).** A \"Verification slice\" Context paragraph means the deliverable is verification, not a code change — run [§6.6](#66-verification-disposition-run-the-auditor-file-bugs-disposition--without-a-pr-852) instead of steps 2–6.5. If the audit surfaces a trivially-fixable bug, file it as a follow-up issue (the dispatched auditor already does this) — don't fix it inline." \
  "issue-work.md's old absolute Don't-list bullet wording is gone"
assert_contains "$issue_work_path" "incidental PR: #<M>" \
  "issue-work.md step 8 documents the optional incidental-PR return suffix"
assert_contains "$issue_work_path" "this PR DOES get appended to \`session_prs\`" \
  "issue-work.md step 8 states the incidental PR (unlike the base verified shape) IS tracked in session_prs"

# --- (C) The scope-preflight carve-out doc no longer states an unqualified 'no PR' ---
assert_file_exists "$carveouts_path" "06b-scope-carveouts.md exists"
assert_contains "$carveouts_path" "this path opens **no *resolving* PR**" \
  "06b-scope-carveouts.md qualifies the no-PR claim to 'resolving PR'"
assert_contains "$carveouts_path" "[#1044](https://github.com/mattsears18/shipyard/issues/1044)" \
  "06b-scope-carveouts.md cross-references #1044's narrow exception"

# --- (D) The load-bearing session_prs consequence: steady-state.md's reconcile handler ---
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_contains "$steady_state_path" "No *resolving* PR was opened for \`#<N>\` — do NOT append anything to \`session_prs\` on \`#<N>\`'s account." \
  "steady-state.md qualifies the no-session_prs-append rule to #<N>'s own resolution"
assert_contains "$steady_state_path" "Optional \`incidental PR: #<M>\` token" \
  "steady-state.md documents the optional incidental-PR token"
assert_contains "$steady_state_path" "DO append \`<M>\` to \`session_prs\`" \
  "steady-state.md instructs the orchestrator to append the incidental PR to session_prs"

# --- (E) Structured-return schema carries the optional field, and its hand-copied ---
# --- Dynamic-Workflows literal (do-work-dispatch.core.js, regenerated into ---
# --- do-work-dispatch.workflow.js) stays in parity with it. ---
assert_file_exists "$schema_path" "schemas/worker-return.schema.json exists"
assert_contains "$schema_path" "\"incidental_pr\"" \
  "canonical schema declares the optional incidental_pr field"
assert_contains "$schema_path" "disposition: \\\"verified\\\"" \
  "canonical schema's incidental_pr description scopes it to the verified disposition"

assert_file_exists "$core_js_path" "workflows/do-work-dispatch.core.js exists"
assert_contains "$core_js_path" "incidental_pr: { type: ['integer', 'null'], minimum: 1 }" \
  "do-work-dispatch.core.js's workerReturnSchema literal declares incidental_pr"

assert_file_exists "$generated_js_path" "workflows/do-work-dispatch.workflow.js (generated) exists"
assert_contains "$generated_js_path" "incidental_pr: { type: ['integer', 'null'], minimum: 1 }" \
  "the generated workflow.js carries the regenerated incidental_pr field (core.js was regenerated, not just edited)"

if [[ -f "$schema_path" ]]; then
  if command -v jq >/dev/null 2>&1 && jq empty "$schema_path" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "worker-return.schema.json is valid JSON"
    pass=$((pass + 1))
  elif ! command -v jq >/dev/null 2>&1; then
    printf '  %sPASS%s  %s (jq unavailable — skipped)\n' "$GREEN" "$RESET" "worker-return.schema.json JSON-validity check"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "worker-return.schema.json is valid JSON"
    fail=$((fail + 1))
  fi
fi

if [[ -f "$parity_checker" ]] && command -v node >/dev/null 2>&1; then
  if node "$parity_checker" "$schema_path" "$generated_js_path" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "check-worker-return-schema-parity.mjs reports no drift between the two"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "check-worker-return-schema-parity.mjs reports no drift between the two"
    fail=$((fail + 1))
  fi
fi

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail"
  exit 1
fi
