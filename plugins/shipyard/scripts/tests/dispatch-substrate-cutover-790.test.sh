#!/usr/bin/env bash
# Test: the dispatch-substrate cutover — issue #790, phase 4 of the #782 epic.
#
# Background
# ----------
# #787 (phase 1) committed the Dynamic Workflows substrate as inert scaffolding.
# #788 (phase 2) wired one mode; #789 (phase 3) wired the remaining six — so with
# `dispatch.substrate: "workflow"` set, all seven `mode:`-driven workers dispatch
# through workflows/do-work-dispatch.workflow.js with schema-validated returns.
# THIS slice (#790) is the CUTOVER: it flips the built-in default of
# `dispatch.substrate` from "agent" to "workflow", carries the 3.0.0 major bump,
# and retains "agent" as a fully-working instant-revert override for one release.
#
# This is a HIGH-BLAST-RADIUS change (it changes shipyard's default runtime
# behavior for every user on next update), so this suite is deliberately the
# strongest validation feasible short of a live `Workflow`-tool dispatch:
#
#   (A) the default flipped, and the substrate SELECTOR reads the flipped value;
#       the instant-revert override to "agent" round-trips and wins.
#   (B) the workflow script actually EXECUTES under the same async wrapper the
#       Dynamic Workflows runtime uses, routing every one of the seven modes to a
#       real per-mode builder, each carrying the structured-return schema — and
#       the schema the script hands `agent()` matches worker-return.schema.json
#       (the drift the script's own header warns CI can't otherwise catch);
#   (C) every structured-return EXAMPLE the builders document is schema-valid and
#       has a translation-table row in dispatch-rules.md — the structured→free-text
#       round-trip the orchestrator's reconcile depends on;
#   (D) `/shipyard:status` renders a synthetic `Workflow`-dispatched session file
#       correctly across text / --json / --stale (the #790 /status acceptance
#       criterion — /status is substrate-agnostic because the orchestrator writes
#       the same .in_flight slot regardless of substrate);
#   (E) the instant-revert is documented PROMINENTLY (CHANGELOG 3.0.0 + README),
#       and the release bump landed (plugin.json 3.0.0).
#
# Pure bash (+ jq + node, both already assumed present by CI's ubuntu-latest
# runner and by other suites in this repo). Run with:
#
#   bash plugins/shipyard/scripts/tests/dispatch-substrate-cutover-790.test.sh

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

helper="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
status_sh="$repo_root/plugins/shipyard/scripts/status.sh"
workflow_js="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
workflow_readme="$repo_root/plugins/shipyard/workflows/README.md"
worker_schema="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
config_schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
changelog="$repo_root/CHANGELOG.md"
plugin_json="$repo_root/plugins/shipyard/.claude-plugin/plugin.json"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }
assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then assert_pass "$label"
  else assert_fail "$label"; printf '    expected: %q\n    actual:   %q\n' "$expected" "$actual"; fi
}
assert_contains_file() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then assert_pass "$label"
  else assert_fail "$label"; printf '    expected to find in %s:\n    %s\n' "$file" "$needle"; fi
}

for f in "$helper" "$status_sh" "$workflow_js" "$workflow_readme" "$worker_schema" \
         "$config_schema" "$dispatch_rules" "$changelog" "$plugin_json"; do
  [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# ==========================================================================
echo "== (A) the substrate knob is RETIRED — one substrate, no config, stale configs rejected"
# ==========================================================================
# #790 flipped `dispatch.substrate` from "agent" to "workflow" and kept the
# legacy path for one release behind an instant-revert override. #791 removed
# the legacy path AND the knob, so what this section guards flipped too: the
# key must be gone from every layer, and a config that still carries it must be
# REJECTED (not silently ignored) so an upgrading repo is told to delete it.
#
# A private repo + SHIPYARD_HOME so we never touch the real ~/.shipyard or repo
# config. Mirrors shipyard-config.test.sh's harness.
cfg_repo=$(mktemp -d)
cfg_home=$(mktemp -d)
export SHIPYARD_REPO_ROOT="$cfg_repo"
export SHIPYARD_HOME="$cfg_home"

# The key resolves to nothing — it is not a built-in default any more.
assert_eq "$("$helper" get dispatch.substrate 2>/dev/null)" "" \
  "dispatch.substrate resolves to empty — the knob was retired (#791)"

# The built-in default block in shipyard-config.sh no longer declares it.
if grep -qF '"substrate"' "$helper"; then
  assert_fail "shipyard-config.sh built-in defaults no longer declare a dispatch substrate"
else
  assert_pass "shipyard-config.sh built-in defaults no longer declare a dispatch substrate"
fi

# The JSON schema no longer declares it either.
if grep -qF '"substrate"' "$config_schema"; then
  assert_fail "shipyard.config.schema.json no longer declares dispatch.substrate"
else
  assert_pass "shipyard.config.schema.json no longer declares dispatch.substrate"
fi

# A stale config carrying the retired knob is REJECTED, not ignored — the repo
# schema is additionalProperties:false, so the upgrade surfaces loudly. This is
# the breaking change that earns #791 its major version bump.
printf '{"version":1,"dispatch":{"substrate":"agent"}}' > "$cfg_repo/shipyard.config.json"
"$helper" validate --layer repo >/dev/null 2>&1
assert_eq "$?" "70" "a stale dispatch.substrate: agent config is rejected, not silently ignored (#791)"
printf '{"version":1,"dispatch":{"substrate":"workflow"}}' > "$cfg_repo/shipyard.config.json"
"$helper" validate --layer repo >/dev/null 2>&1
assert_eq "$?" "70" "a stale dispatch.substrate: workflow config is rejected too (#791)"
rm -rf "$cfg_repo" "$cfg_home"
unset SHIPYARD_REPO_ROOT SHIPYARD_HOME

# ==========================================================================
echo
echo "== (B)+(C) the workflow script executes; every mode builds; schema + translation round-trip"
# ==========================================================================
# This runs the workflow script through the SAME async wrapper the Dynamic
# Workflows runtime uses (top-level `await` + top-level `return` are legal only
# inside that wrapper), stubbing the runtime globals `agent`/`parallel`/`pipeline`
# and feeding one work unit per mode via `args`. The `agent()` stub captures the
# built prompt + opts for every mode — the strongest validation short of an
# actual `Workflow`-tool dispatch. If node is unavailable, this section skips.
if command -v node >/dev/null 2>&1; then
  harness=$(mktemp --suffix=.js 2>/dev/null || mktemp -t cutover790.XXXXXX.js)
  cat > "$harness" <<'NODE_EOF'
'use strict';
const { readFileSync } = require('fs');
const [wfPath, schemaPath, dispatchRulesPath] = process.argv.slice(2);

let fails = 0;
const ok = (cond, msg) => { console.log((cond ? '  PASS  ' : '  FAIL  ') + msg); if (!cond) fails++; };

// Strip the ESM `export` so `new Function` can wrap the body; the Dynamic
// Workflows runtime executes the script as an async function body (which is why
// top-level await + top-level return are legal in it), so this wrapper is a
// faithful stand-in. Source is the repo's own committed file (trusted input).
const src = readFileSync(wfPath, 'utf8').replace(/^export\s+const\s+meta/m, 'const meta');

const modes = ['issue-work', 'fix-checks-only', 'fix-rebase', 'fix-main-ci',
               'fix-failing-prs-batch', 'investigate', 'spike'];
const models = { 'issue-work': 'sonnet', 'fix-checks-only': 'haiku', 'fix-rebase': 'haiku',
                 'fix-main-ci': 'sonnet', 'fix-failing-prs-batch': 'sonnet',
                 'investigate': 'sonnet', 'spike': 'opus' };
const WT = '/tmp/wt-790';
const unitFor = (mode) => {
  const base = { mode, worktreePath: WT, model: models[mode] };
  switch (mode) {
    case 'issue-work':
    case 'investigate':
    case 'spike':
      return { ...base, number: 790, trust: 'trusted', branch: 'do-work/issue-790',
               ...(mode === 'investigate' ? { triageAutoClose: 'confident-only' } : {}),
               ...(mode === 'spike' ? { decomposeMaxSubissues: 8 } : {}) };
    case 'fix-checks-only':
      return { ...base, pr: 42, headRefName: 'feat/x' };
    case 'fix-rebase':
      return { ...base, pr: 43, headRefName: 'feat/y' };
    case 'fix-main-ci':
      return { ...base, branch: 'do-work/fix-main-ci-abc1234',
               earliestRedRunUrl: 'https://example/run/1', earliestRedSha: 'abc1234' };
    case 'fix-failing-prs-batch':
      return { ...base, branch: 'do-work/fix-pr-pileup-1700000000',
               failingPrCountAll: 12, failingPrNumbers: '#1, #2, #3' };
    default:
      return base;
  }
};

const captured = [];
const agentStub = (prompt, opts) => { captured.push({ prompt, opts }); return Promise.resolve({ mode: 'issue-work', outcome: 'noop' }); };
const parallelStub = (tasks) => Promise.all(tasks.map((t) => t()));
const pipelineStub = (list, fn) => Promise.all(list.map(fn));
const argsObj = { repo: 'owner/repo', concurrency: 1, models, issues: modes.map(unitFor) };

(async () => {
  let results;
  try {
    // eslint-disable-next-line no-new-func -- faithful stand-in for the Dynamic Workflows runtime wrapper; src is the repo's own committed file
    const runner = new Function('agent', 'parallel', 'pipeline', 'args', `return (async () => { ${src} })();`);
    results = await runner(agentStub, parallelStub, pipelineStub, argsObj);
  } catch (e) {
    ok(false, 'workflow script executes under the runtime async wrapper: ' + e.message);
    console.log('\nnode-harness passed: 0  failed: 1');
    process.exit(1);
  }

  ok(Array.isArray(results), 'workflow script returns an array of results');
  ok(captured.length === modes.length,
     `every one of the ${modes.length} modes routed to a builder and dispatched an agent() (captured ${captured.length})`);

  const jsonSchema = JSON.parse(readFileSync(schemaPath, 'utf8'));
  const dispatchRules = readFileSync(dispatchRulesPath, 'utf8');

  for (const mode of modes) {
    const cap = captured.find((c) => c.prompt.startsWith(`mode: ${mode}`));
    ok(!!cap, `${mode}: buildWorkerPrompt produced a prompt headed "mode: ${mode}"`);
    if (!cap) continue;
    ok(!!cap.opts && !!cap.opts.schema, `${mode}: the agent() call carries the structured-return schema`);
    ok(cap.opts && cap.opts.model === models[mode], `${mode}: the resolved per-mode model tier is passed through to agent() (${models[mode]})`);
    ok(/Return a STRUCTURED result/.test(cap.prompt), `${mode}: prompt states the structured-return contract`);
    ok(cap.prompt.includes('worker-preamble'), `${mode}: prompt loads the worker-preamble skill`);
    ok(/Anchor to your isolated worktree FIRST/.test(cap.prompt),
       `${mode}: prompt anchors the worker to the pre-provisioned worktree (workflow substrate has no auto-isolation)`);
    ok(cap.prompt.includes(WT), `${mode}: the pre-provisioned worktree path is interpolated into the anchor step`);

    // (C) round-trip: every structured-return EXAMPLE the builder documents must be
    // schema-valid AND representable by dispatch-rules.md's translation table.
    const examples = [...cap.prompt.matchAll(/"mode":\s*"([^"]+)",\s*"outcome":\s*"([^"]+)"/g)];
    ok(examples.length > 0, `${mode}: prompt documents at least one structured-return example`);
    for (const m of examples) {
      const exMode = m[1];
      const outcome = m[2];
      ok(exMode === mode, `${mode}: documented example's "mode" matches the dispatch mode (got ${exMode})`);
      ok(jsonSchema.properties.outcome.enum.includes(outcome),
         `${mode}: documented example outcome "${outcome}" is a valid schema outcome`);
    }
    // Optional qualifier fields on the examples must also be schema-valid.
    for (const m of cap.prompt.matchAll(/"auto_merge":\s*"([^"]+)"/g)) {
      ok(jsonSchema.properties.auto_merge.enum.includes(m[1]),
         `${mode}: documented auto_merge "${m[1]}" is a valid schema value`);
    }
    for (const m of cap.prompt.matchAll(/"disposition":\s*"([^"]+)"/g)) {
      ok(jsonSchema.properties.disposition.enum.includes(m[1]),
         `${mode}: documented disposition "${m[1]}" is a valid schema value`);
    }
  }

  // (B) schema-drift guard: the workerReturnSchema the script hands agent() (we
  // captured the live object) must match worker-return.schema.json enum-for-enum.
  // The script's own header warns this drift is invisible to CI otherwise.
  const jsSchema = captured[0].opts.schema;
  const enumEq = (a, b) => Array.isArray(a) && Array.isArray(b) &&
    JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());
  for (const field of ['mode', 'outcome', 'auto_merge', 'disposition', 'checks']) {
    ok(enumEq(jsSchema.properties[field] && jsSchema.properties[field].enum,
              jsonSchema.properties[field] && jsonSchema.properties[field].enum),
       `workerReturnSchema.${field} enum in the .js matches worker-return.schema.json`);
  }
  ok(enumEq(jsSchema.required, jsonSchema.required),
     'workerReturnSchema.required in the .js matches worker-return.schema.json');

  // (C) mode-level table coverage: dispatch-rules.md's translation table mentions
  // every mode (so no mode's structured returns are untranslatable at reconcile).
  for (const mode of modes) {
    ok(dispatchRules.includes('`' + mode + '`') || dispatchRules.includes('"mode": "' + mode + '"') || dispatchRules.includes(mode),
       `dispatch-rules.md's substrate section references mode ${mode} for translation`);
  }

  console.log(`\nnode-harness passed: ${captured.length ? 'ok' : 'n/a'}  failures: ${fails}`);
  process.exit(fails === 0 ? 0 : 1);
})();
NODE_EOF

  if node "$harness" "$workflow_js" "$worker_schema" "$dispatch_rules"; then
    assert_pass "node harness: workflow executes + every mode builds + schema/translation round-trip (see PASS lines above)"
  else
    assert_fail "node harness: workflow executes + every mode builds + schema/translation round-trip (see FAIL lines above)"
  fi
  rm -f "$harness"
else
  echo "  SKIP  node not on PATH — skipping the workflow-execution harness"
fi

# ==========================================================================
echo
echo "== (D) /shipyard:status renders a synthetic Workflow-dispatched session correctly"
# ==========================================================================
# The orchestrator writes the SAME .in_flight slot shape regardless of substrate
# (dispatch-rules.md step 5). Build a session file exactly as a workflow-substrate
# dispatch would, and assert status.sh renders it across text / --json / --stale.
st_home=$(mktemp -d)
mkdir -p "$st_home/sessions"
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old_iso=$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
cat > "$st_home/sessions/sess-workflow.json" <<JSON
{
  "session_id": "sess-workflow",
  "repo": "mattsears18/shipyard",
  "started_at": "$old_iso",
  "updated_at": "$now_iso",
  "concurrency": 2,
  "in_flight": {
    "slot1": { "kind": "issue", "target": 790, "claimed_paths": { "hard": [], "soft": [] }, "agent_id": "wf-a", "started_at": "$now_iso", "progress_current": null, "progress_total": null, "progress_updated_at": null },
    "slot2": { "kind": "fix-checks", "target": 42, "claimed_paths": { "hard": [], "soft": [] }, "agent_id": "wf-b", "started_at": "$old_iso", "progress_current": null, "progress_total": null, "progress_updated_at": "$old_iso" }
  },
  "tokens": { "per_issue": { "790": { "input": 5000, "output": 1200, "cache_read": 0, "cache_creation": 0, "estimated_usd": 0 } }, "per_pr": { "42": { "input": 2000, "output": 400, "cache_read": 0, "cache_creation": 0, "estimated_usd": 0 } } }
}
JSON

st_text=$(SHIPYARD_HOME="$st_home" bash "$status_sh" 2>&1)
if printf '%s' "$st_text" | grep -qF '#790'; then assert_pass "status text renders the workflow-dispatched issue-work row (#790)"; else assert_fail "status text renders the workflow-dispatched issue-work row (#790)"; fi
if printf '%s' "$st_text" | grep -qF 'PR #42'; then assert_pass "status text renders the workflow-dispatched fix-checks row (PR #42)"; else assert_fail "status text renders the workflow-dispatched fix-checks row (PR #42)"; fi
if printf '%s' "$st_text" | grep -qF '2 active worker(s)'; then assert_pass "status text counts both workflow-dispatched workers"; else assert_fail "status text counts both workflow-dispatched workers"; fi

st_json=$(SHIPYARD_HOME="$st_home" bash "$status_sh" --json 2>&1)
if printf '%s' "$st_json" | jq -e '.[0].in_flight | length == 2' >/dev/null 2>&1; then assert_pass "status --json projects both workflow-dispatched slots"; else assert_fail "status --json projects both workflow-dispatched slots"; fi
if printf '%s' "$st_json" | jq -e '[.[0].in_flight[].target] | index(790) != null' >/dev/null 2>&1; then assert_pass "status --json includes the issue-work target 790"; else assert_fail "status --json includes the issue-work target 790"; fi

st_stale=$(SHIPYARD_HOME="$st_home" bash "$status_sh" --stale 2>&1)
if printf '%s' "$st_stale" | grep -qF 'PR #42'; then assert_pass "status --stale surfaces the 20-min-old workflow-dispatched worker"; else assert_fail "status --stale surfaces the 20-min-old workflow-dispatched worker"; fi
if printf '%s' "$st_stale" | grep -qF '#790'; then assert_fail "status --stale must NOT surface the fresh worker (#790)"; else assert_pass "status --stale correctly excludes the fresh workflow-dispatched worker (#790)"; fi
rm -rf "$st_home"

# ==========================================================================
echo
echo "== (E) migration documented prominently + release bump landed"
# ==========================================================================
# #790's instant-revert escape hatch was removed by #791 along with the knob it
# reverted to. What must be prominent now is the MIGRATION callout telling an
# upgrading repo to delete its stale `dispatch` config block — the breaking
# change that earns the major bump.
if grep -qF "dispatch.substrate agent" "$workflow_readme"; then
  assert_fail "workflows/README.md no longer advertises the retired instant-revert command (#791)"
else
  assert_pass "workflows/README.md no longer advertises the retired instant-revert command (#791)"
fi
assert_contains_file "$workflow_readme" "delete your \`dispatch\` config block" \
  "workflows/README.md carries a prominent upgrade/migration callout (#791)"
assert_contains_file "$changelog" "### 3.0.0" \
  "CHANGELOG.md has the 3.0.0 entry"
if grep -A40 '### 3.0.0' "$changelog" | grep -qF 'dispatch.substrate agent'; then
  assert_pass "the CHANGELOG 3.0.0 entry documents the one-line instant-revert"
else
  assert_fail "the CHANGELOG 3.0.0 entry documents the one-line instant-revert"
fi
# Assert the major bump to 3.x LANDED AND PERSISTS, rather than pinning the
# exact "3.0.0" string — a later release (e.g. #785) legitimately bumps past
# 3.0.0 in its own PR, and a literal-equality assertion here would otherwise
# permanently red every subsequent release's CI for a version this test
# doesn't actually care about (it only cares that the cutover's major bump
# happened, not that no further release ever occurs).
current_version="$(jq -r '.version' "$plugin_json")"
if [[ "$(printf '%s\n%s\n' "3.0.0" "$current_version" | sort -V | head -n1)" == "3.0.0" ]]; then
  assert_pass "plugin.json version is at or past 3.0.0 (major — the substrate cutover), currently ${current_version}"
else
  assert_fail "plugin.json version is at or past 3.0.0 (major — the substrate cutover), currently ${current_version}"
fi

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
