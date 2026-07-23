#!/usr/bin/env bash
# Test: do-work-dispatch.workflow.js FAILS LOUDLY on unusable `args` instead of
# silently dispatching zero workers and reporting success — issue #817.
#
# Background — issue #817
# -----------------------
# `plugins/shipyard/workflows/do-work-dispatch.workflow.js` guarded its input
# with two fall-open defaults and a pure `.map()`:
#
#   const input = typeof args === 'object' && args !== null ? args : {}
#   const selectedIssues = Array.isArray(input.issues) ? input.issues : []
#   const workUnits = selectedIssues.map(...)      // pure map, no filter
#
# If `args` arrived as a JSON *string* rather than a parsed object — which the
# `Workflow` tool's own docs warn is an easy caller mistake ("Pass arrays/objects
# as actual JSON values in the tool call, NOT as a JSON-encoded string") — all
# three collapsed to empty, `parallel([])` resolved instantly, and the script
# returned `[]`. The run was reported as a SUCCESS with `agent_count: 0` in 37ms.
# No error, no warning, and (because the script emitted no `log()`/`phase()` at
# all) nothing in `/workflows` or the transcript either.
#
# Since #791 made this script the ONLY dispatch substrate, that meant a
# `/shipyard:do-work` session could report a completed dispatch that never
# spawned a worker, strand its `.in_flight` pool slot waiting on a completion
# that already happened, and leave no diagnosable trace anywhere. P1.
#
# WHY EXISTING CI DID NOT CATCH IT — and what this suite does differently
# ----------------------------------------------------------------------
# Every sibling suite (dispatch-workflow-substrate-788 / -789,
# dispatch-substrate-cutover-790, legacy-agent-dispatch-retired-791,
# workflow-meta-pure-literal-809) inspects the file as TEXT — grep for a builder
# name, extract a schema enum, parse the `meta` AST. None of them EXECUTES the
# script, so a runtime fall-open at the `args` boundary was invisible to all of
# them.
#
# The #817 issue body names the specific verification blind spot that let this
# ship: an `args.issues: []` smoke test returns `[]` on BOTH the healthy and the
# broken path, so a ZERO-UNIT PROBE CANNOT DISTINGUISH THEM. That is how the bug
# survived the post-#809 verification. This suite therefore:
#
#   (A) EXECUTES the script under a harness, rather than grepping it.
#   (B) Always drives a NON-EMPTY work-unit list on the healthy paths, so a
#       regression to fall-open produces zero agent calls and fails loudly here.
#   (C) Covers the STRING-`args` case explicitly — the shape that actually broke.
#   (D) Pins that the former blind-spot probe (`issues: []`) now THROWS, so the
#       probe that used to prove nothing is itself now a distinguishing signal.
#
# THE HARNESS
# -----------
# The Dynamic Workflows runtime executes the script with `agent`, `parallel`,
# `pipeline`, `log`, and `args` injected as globals, top-level `await` allowed,
# and a top-level `return`. That is not a shape `node` can run directly, so the
# harness compiles the source into an AsyncFunction whose parameters ARE those
# globals (rewriting `export const meta` to a plain `const`, since an export
# statement is illegal inside a function body). This mirrors the runtime closely
# enough to exercise the input-handling contract, which is what #817 is about.
#
# It does NOT invoke the real `Workflow` tool — that is not reachable from a
# bash CI suite. The `Workflow`-tool-boundary rules (meta must be a pure literal,
# no nondeterminism) are covered by workflow-meta-pure-literal-809.test.sh and
# check-workflow-meta-literal.mjs; this suite covers the script's own runtime
# behavior once the boundary has accepted it.
#
# Pure bash + node (+ jq), all already assumed present by CI's ubuntu-latest
# runner and by other suites in this repo. Run with:
#   bash plugins/shipyard/scripts/tests/workflow-args-fail-loud-817.test.sh

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

workflow_js="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

for tool in node jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH — this suite cannot verify runtime args handling" >&2
    exit 1
  fi
done

if [[ ! -f "$workflow_js" ]]; then
  echo "FAIL: workflow script not found at $workflow_js" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

harness="$tmp/harness.mjs"
cat > "$harness" <<'HARNESS_EOF'
// Compile do-work-dispatch.workflow.js the way the Dynamic Workflows runtime
// does — `agent` / `parallel` / `pipeline` / `log` / `args` as injected globals,
// top-level await, top-level return — and report what it did.
//
// Usage: node harness.mjs <workflow.js> <args-spec.json>
// The args spec is one of:
//   {"kind": "absent"}                  -> `args` is undefined (bare dry read)
//   {"kind": "string", "value": "..."}  -> `args` is that STRING
//   {"kind": "raw",    "value": <any>}  -> `args` is that parsed JSON value
//
// Emits a single JSON line on stdout:
//   {"threw":bool,"error":str,"result":[...],"logs":[...],"agentLabels":[...]}
import fs from 'node:fs'

const src = fs
  .readFileSync(process.argv[2], 'utf8')
  .replace(/^export const meta =/m, 'const meta =')

const spec = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

const logs = []
const agentLabels = []

const fakeAgent = async (prompt, opts) => {
  agentLabels.push((opts && opts.label) || '<no-label>')
  return { mode: 'issue-work', outcome: 'shipped', summary: String(prompt).slice(0, 40) }
}
const fakeParallel = async (tasks) => Promise.all(tasks.map((t) => t()))
const fakePipeline = async (list, fn) => Promise.all(list.map(fn))
const fakeLog = (m) => logs.push(String(m))
const fakePhase = (m) => logs.push('phase: ' + String(m))

const params = ['agent', 'parallel', 'pipeline', 'log', 'phase']
const values = [fakeAgent, fakeParallel, fakePipeline, fakeLog, fakePhase]

// `absent` must leave `args` genuinely undeclared-or-undefined, which is what a
// bare dry read looks like. The script's own guard is `typeof args`, so passing
// `undefined` through a declared parameter is the faithful reproduction.
if (spec.kind !== 'absent') {
  params.push('args')
  values.push(spec.kind === 'string' ? spec.value : spec.value)
}

const out = { threw: false, error: '', result: null, logs, agentLabels }
try {
  const fn = new AsyncFunction(...params, src)
  out.result = await fn(...values)
} catch (err) {
  out.threw = true
  out.error = err && err.message ? err.message : String(err)
}
process.stdout.write(JSON.stringify(out) + '\n')
HARNESS_EOF

# run_case <spec-json> -> echoes the harness's JSON result line
run_case() {
  local spec="$1" specfile
  specfile="$tmp/spec.$$.json"
  printf '%s' "$spec" > "$specfile"
  node "$harness" "$workflow_js" "$specfile" 2>"$tmp/stderr.log"
}

# A well-formed single work unit — the exact shape the orchestrator injects for
# one pool slot (dispatch-rules.md's `mode: issue-work` call site).
unit_json='{"repo":"mattsears18/shipyard","issues":[{"number":817,"mode":"issue-work","model":"sonnet","trust":"trusted","branch":"do-work/issue-817","worktreePath":"/tmp/wt-817"}]}'

# ==========================================================================
echo "== (A) the script is syntactically valid and still declares its guards"
# ==========================================================================

if node --check "$workflow_js" >/dev/null 2>&1; then
  assert_pass "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
else
  assert_fail "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
fi

assert_contains_js() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$workflow_js" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s:\n    %s\n' "$workflow_js" "$needle"
  fi
}

assert_contains_js "JSON.parse(trimmedArgs)" \
  "the script parses a JSON-STRING args (guarded JSON.parse)"
assert_contains_js "argsJsonParseError" \
  "a JSON.parse failure is remembered for the diagnostic, not swallowed"
assert_contains_js "argsAreNonEmpty" \
  "the script distinguishes 'no args at all' from 'args given but unusable'"
assert_contains_js "throw new Error(" \
  "the script throws rather than returning an empty success"
assert_contains_js "#817" \
  "the script cites issue #817 so the rationale survives a future edit"

# The negative assertions below must run against EXECUTABLE code only. The file's
# header comment deliberately quotes the #817 fall-open guard verbatim (and names
# `Date.now()` / `Math.random()` as forms to avoid), so a naive whole-file grep
# false-positives on the documentation that exists to prevent the regression.
# Strip block-comment body lines, comment openers, and whole-line `//` comments.
code_only="$tmp/code-only.js"
grep -vE '^[[:space:]]*(\*|/\*|//)' "$workflow_js" > "$code_only"

# The fall-open form that WAS the bug. If it reappears as real code — not as the
# header's quoted example — the guard has been reverted.
if grep -qF -- "const input = typeof args === 'object' && args !== null ? args : {}" "$code_only" 2>/dev/null; then
  assert_fail "the #817 fall-open input guard is NOT back (typeof args === 'object' ? args : {})"
else
  assert_pass "the #817 fall-open input guard is NOT back (typeof args === 'object' ? args : {})"
fi

# And the header comment must KEEP quoting it — that documentation is why the
# next reader knows the fall-open shape is forbidden rather than merely absent.
if grep -qF -- "const input = typeof args === 'object' && args !== null ? args : {}" "$workflow_js" 2>/dev/null; then
  assert_pass "the header still quotes the #817 fall-open guard as the forbidden form"
else
  assert_fail "the header still quotes the #817 fall-open guard as the forbidden form"
fi

# ==========================================================================
echo
echo "== (B) AC 1 — a JSON-STRING args dispatches correctly, never returns [] silently"
# ==========================================================================
# This is the shape that actually broke. Before the fix this case produced
# result [] / 0 agents / 0 logs and reported success.

string_spec="$(jq -nc --arg v "$unit_json" '{kind:"string", value:$v}')"
out="$(run_case "$string_spec")"

if [[ "$(jq -r '.threw' <<<"$out")" == "false" ]]; then
  assert_pass "string-shaped args does not throw"
else
  assert_fail "string-shaped args does not throw"
  printf '    error: %s\n' "$(jq -r '.error' <<<"$out")"
fi

if [[ "$(jq -r '.agentLabels | length' <<<"$out")" == "1" ]]; then
  assert_pass "string-shaped args dispatches exactly 1 agent (was 0 — the #817 bug)"
else
  assert_fail "string-shaped args dispatches exactly 1 agent (was 0 — the #817 bug)"
  printf '    agentLabels: %s\n' "$(jq -c '.agentLabels' <<<"$out")"
fi

if [[ "$(jq -r '.result | length' <<<"$out")" == "1" ]]; then
  assert_pass "string-shaped args returns 1 result (was [] — the #817 bug)"
else
  assert_fail "string-shaped args returns 1 result (was [] — the #817 bug)"
  printf '    result: %s\n' "$(jq -c '.result' <<<"$out")"
fi

if [[ "$(jq -r '.agentLabels[0]' <<<"$out")" == "issue-work #817" ]]; then
  assert_pass "string-shaped args routes to the right mode/target (label 'issue-work #817')"
else
  assert_fail "string-shaped args routes to the right mode/target (label 'issue-work #817')"
  printf '    agentLabels: %s\n' "$(jq -c '.agentLabels' <<<"$out")"
fi

# ==========================================================================
echo
echo "== (C) the healthy OBJECT args path is unchanged"
# ==========================================================================
# The regression guard for the fix itself: tolerating a string must not break
# the shape the orchestrator actually sends.

object_spec="$(jq -nc --argjson v "$unit_json" '{kind:"raw", value:$v}')"
out="$(run_case "$object_spec")"

if [[ "$(jq -r '.threw' <<<"$out")" == "false" && "$(jq -r '.agentLabels | length' <<<"$out")" == "1" ]]; then
  assert_pass "object-shaped args still dispatches exactly 1 agent and does not throw"
else
  assert_fail "object-shaped args still dispatches exactly 1 agent and does not throw"
  printf '    out: %s\n' "$out"
fi

# Multi-unit fan-out — the future batch-dispatch path the script preserves.
multi_json='{"repo":"o/r","concurrency":2,"issues":[{"number":1,"mode":"issue-work","worktreePath":"/tmp/a"},{"pr":42,"mode":"fix-checks-only","headRefName":"do-work/issue-1","worktreePath":"/tmp/b"}]}'
multi_spec="$(jq -nc --argjson v "$multi_json" '{kind:"raw", value:$v}')"
out="$(run_case "$multi_spec")"

if [[ "$(jq -r '.agentLabels | length' <<<"$out")" == "2" ]]; then
  assert_pass "a 2-unit args dispatches 2 agents (fan-out is not swallowed)"
else
  assert_fail "a 2-unit args dispatches 2 agents (fan-out is not swallowed)"
  printf '    agentLabels: %s\n' "$(jq -c '.agentLabels' <<<"$out")"
fi

if jq -e '.agentLabels | index("fix-checks-only PR#42")' <<<"$out" >/dev/null 2>&1; then
  assert_pass "a PR-targeted unit labels as 'fix-checks-only PR#42' (mode/target resolution)"
else
  assert_fail "a PR-targeted unit labels as 'fix-checks-only PR#42' (mode/target resolution)"
  printf '    agentLabels: %s\n' "$(jq -c '.agentLabels' <<<"$out")"
fi

# ==========================================================================
echo
echo "== (D) AC 2 — non-empty args yielding ZERO work units THROWS, naming the shape"
# ==========================================================================

# assert_throws_naming <spec> <label> [needle...]
assert_throws_naming() {
  local spec="$1" label="$2"; shift 2
  local out err needle
  out="$(run_case "$spec")"
  if [[ "$(jq -r '.threw' <<<"$out")" != "true" ]]; then
    assert_fail "$label"
    printf '    did NOT throw — returned: %s\n' "$(jq -c '.result' <<<"$out")"
    return
  fi
  err="$(jq -r '.error' <<<"$out")"
  for needle in "$@"; do
    if ! grep -qF -- "$needle" <<<"$err"; then
      assert_fail "$label"
      printf '    expected the error to mention %s, got:\n    %s\n' "$needle" "$err"
      return
    fi
  done
  assert_pass "$label"
}

# `issues` present but not an array — the classic malformed payload.
assert_throws_naming \
  "$(jq -nc '{kind:"raw", value:{repo:"o/r", issues:"not-an-array"}}')" \
  "args.issues as a string THROWS, naming typeof args and the non-array issues" \
  "typeof args = object" "NOT an array"

# `issues` missing entirely, but other keys present.
assert_throws_naming \
  "$(jq -nc '{kind:"raw", value:{repo:"o/r", concurrency:3}}')" \
  "args with no issues key at all THROWS, naming the top-level keys it did get" \
  "NOT an array" "top-level keys"

# A JSON string that does not parse — the string tolerance must not swallow it.
assert_throws_naming \
  "$(jq -nc '{kind:"string", value:"{not valid json"}')" \
  "an UNPARSEABLE string args THROWS and reports the JSON.parse failure" \
  "typeof args = string" "JSON.parse of the string-shaped args FAILED"

# A JSON string encoding a non-object.
assert_throws_naming \
  "$(jq -nc '{kind:"string", value:"\"just-a-string\""}')" \
  "a string args encoding a bare JSON string THROWS" \
  "typeof args = string"

# A scalar args — neither object nor string.
assert_throws_naming \
  "$(jq -nc '{kind:"raw", value:7}')" \
  "a numeric args THROWS rather than falling open to {}" \
  "typeof args = number"

# ==========================================================================
echo
echo "== (E) AC 2, blind-spot half — the zero-unit PROBE that proved nothing now THROWS"
# ==========================================================================
# From the #817 issue body: "an args.issues: [] smoke test returns [] on both the
# healthy and the broken path, so a zero-unit probe CANNOT distinguish them. That
# is how it survived my own post-#809 check." Under the fix that probe is no
# longer ambiguous — an explicitly empty issues list is a caller bug and throws.
# This assertion is the reason the suite exists in the shape it does: it pins
# that the cheap probe is now a real signal, and (B)/(C) above ensure the suite
# itself never relies on a zero-unit probe to claim the script works.

assert_throws_naming \
  "$(jq -nc '{kind:"raw", value:{repo:"o/r", issues:[]}}')" \
  "the former blind-spot probe (issues: []) now THROWS instead of returning []" \
  "ZERO work units" "args.issues length = 0"

# ==========================================================================
echo
echo "== (F) AC 3 — a bare invocation with NO args is still a harmless dry read"
# ==========================================================================

out="$(run_case '{"kind":"absent"}')"

if [[ "$(jq -r '.threw' <<<"$out")" == "false" ]]; then
  assert_pass "no args at all does NOT throw (the dry-read path is preserved)"
else
  assert_fail "no args at all does NOT throw (the dry-read path is preserved)"
  printf '    error: %s\n' "$(jq -r '.error' <<<"$out")"
fi

if [[ "$(jq -r '.result | length' <<<"$out")" == "0" ]]; then
  assert_pass "no args at all returns an empty result list"
else
  assert_fail "no args at all returns an empty result list"
  printf '    result: %s\n' "$(jq -c '.result' <<<"$out")"
fi

if [[ "$(jq -r '.agentLabels | length' <<<"$out")" == "0" ]]; then
  assert_pass "no args at all spawns no agents"
else
  assert_fail "no args at all spawns no agents"
fi

# An explicitly EMPTY object is the same harmless case — nothing was asked for.
out="$(run_case '{"kind":"raw","value":{}}')"
if [[ "$(jq -r '.threw' <<<"$out")" == "false" && "$(jq -r '.result | length' <<<"$out")" == "0" ]]; then
  assert_pass "an explicitly empty args object is treated as a dry read, not a caller bug"
else
  assert_fail "an explicitly empty args object is treated as a dry read, not a caller bug"
  printf '    out: %s\n' "$out"
fi

# ==========================================================================
echo
echo "== (G) AC 4 — dispatch emits a log() naming unit count and per-unit mode/target"
# ==========================================================================
# The script previously emitted NO log()/phase() at all, which is exactly why the
# empty run was invisible in /workflows and the transcript.

out="$(run_case "$object_spec")"
logline="$(jq -r '.logs | join(" | ")' <<<"$out")"

if [[ "$(jq -r '.logs | length' <<<"$out")" -ge 1 ]]; then
  assert_pass "a healthy dispatch emits at least one log() line"
else
  assert_fail "a healthy dispatch emits at least one log() line"
fi

for needle in "1 work unit" "issue-work #817" "mattsears18/shipyard"; do
  if grep -qF -- "$needle" <<<"$logline"; then
    assert_pass "the dispatch log names '$needle'"
  else
    assert_fail "the dispatch log names '$needle'"
    printf '    logs: %s\n' "$logline"
  fi
done

out="$(run_case "$multi_spec")"
logline="$(jq -r '.logs | join(" | ")' <<<"$out")"
for needle in "2 work unit" "issue-work #1" "fix-checks-only PR#42"; do
  if grep -qF -- "$needle" <<<"$logline"; then
    assert_pass "the multi-unit dispatch log names '$needle'"
  else
    assert_fail "the multi-unit dispatch log names '$needle'"
    printf '    logs: %s\n' "$logline"
  fi
done

# Even the harmless dry read is now visible, so "0 agents" is never silent.
out="$(run_case '{"kind":"absent"}')"
if jq -r '.logs | join(" ")' <<<"$out" | grep -qF -- "dry read"; then
  assert_pass "the no-args dry read emits a log() saying so (0 agents is never silent)"
else
  assert_fail "the no-args dry read emits a log() saying so (0 agents is never silent)"
  printf '    logs: %s\n' "$(jq -c '.logs' <<<"$out")"
fi

# ==========================================================================
echo
echo "== (H) the #809 pure-literal meta rule is not regressed by this change"
# ==========================================================================
# Cheap cross-check: #817's fix edits the same file #809 fixed, and the `meta`
# rule is enforced at the tool boundary where no runtime test can see it.

checker="$repo_root/plugins/shipyard/scripts/check-workflow-meta-literal.mjs"
if [[ -f "$checker" ]]; then
  if node "$checker" "$workflow_js" >/dev/null 2>&1; then
    assert_pass "meta is still a pure literal after the #817 change (checker agrees)"
  else
    assert_fail "meta is still a pure literal after the #817 change (checker agrees)"
    node "$checker" "$workflow_js" 2>&1 | sed 's/^/    /'
  fi
else
  echo "  SKIP  check-workflow-meta-literal.mjs not present"
fi

# The tool-boundary nondeterminism rules apply to the new code too. Checked
# against the comment-stripped copy — the header NAMES these forms as ones to
# avoid, which is documentation, not usage.
for banned in "Date.now()" "Math.random()"; do
  if grep -qF -- "$banned" "$code_only" 2>/dev/null; then
    assert_fail "the script does not use $banned (tool-boundary nondeterminism rule)"
  else
    assert_pass "the script does not use $banned (tool-boundary nondeterminism rule)"
  fi
done

# ==========================================================================
echo
printf 'workflow-args-fail-loud-817: %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$pass" "$RESET" "$([[ $fail -gt 0 ]] && printf '%s' "$RED" || printf '%s' "$GREEN")" "$fail" "$RESET"

[[ $fail -eq 0 ]]
