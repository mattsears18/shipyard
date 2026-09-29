#!/usr/bin/env bash
# Test: every `unit.<field>` a Workflow-substrate prompt builder reads survives
# do-work-dispatch.core.js's STAGE 1 `workUnits` normalization — issue #1615.
#
# Background
# ----------
# The prompt builders under plugins/shipyard/workflows/prompt-templates/ gate
# optional paragraphs on fields of the work unit they are handed (for example
# `unit.stalePremisePhrase` renders the #1491 stale-premise paragraph). But the
# unit they receive is NOT the orchestrator's raw `args.issues[]` entry — it is
# the object STAGE 1's `workUnits` map builds from it, field by field. A field
# the map forgets to copy is silently dropped, so its paragraph can never render
# under the Workflow substrate even when the orchestrator passes it.
#
# #1615 found six such fields: stalePremisePhrase / stalePremiseCorrection
# (#1491), splitDispatch (#1562), and pluginRoot / pluginRootStale /
# skillCacheStale (#969 / #1319). check-dispatch-prompt-parity.mjs does not
# catch this class — it asserts anchor text exists in the builder, not that the
# builder's gating field survives the core's normalization.
#
# This suite closes the class two ways:
#   (A) structural — every `unit.<field>` read anywhere in prompt-templates/ is
#       declared as a key of the `workUnits` map in core.js, so a new builder
#       field that forgets the map fails CI instead of silently never rendering.
#   (B) behavioral — the generated do-work-dispatch.workflow.js, executed the way
#       the Dynamic Workflows runtime does, actually renders each affected
#       paragraph when the orchestrator supplies the field.
#
# Pure bash + node. Run with:
#
#   bash plugins/shipyard/scripts/tests/workflow-unit-field-passthrough-1615.test.sh

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

workflows_dir="$repo_root/plugins/shipyard/workflows"
core_js="$workflows_dir/do-work-dispatch.core.js"
workflow_js="$workflows_dir/do-work-dispatch.workflow.js"
templates_dir="$workflows_dir/prompt-templates"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

for f in "$core_js" "$workflow_js"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ==========================================================================
echo "== (A) every unit.<field> a builder reads is declared in core.js's workUnits map"
# ==========================================================================

# The body of the `workUnits = selectedIssues.map((it) => ({ ... }))` literal.
map_body="$(awk '
  /^const workUnits = selectedIssues\.map\(/ { inside = 1; next }
  inside && /^\}\)\)/ { exit }
  inside { print }
' "$core_js")"

if [[ -z "$map_body" ]]; then
  assert_fail "located the workUnits map literal in do-work-dispatch.core.js"
else
  assert_pass "located the workUnits map literal in do-work-dispatch.core.js"
fi

builder_fields="$(grep -ohE '\bunit\.[A-Za-z0-9_]+' "$templates_dir"/*.mjs | sed 's/^unit\.//' | sort -u)"
if [[ -z "$builder_fields" ]]; then
  assert_fail "found unit.<field> reads in prompt-templates/*.mjs"
fi

while IFS= read -r field; do
  [[ -z "$field" ]] && continue
  if printf '%s\n' "$map_body" | grep -qE "^[[:space:]]+${field}:"; then
    assert_pass "workUnits map declares '${field}' (read by a prompt builder)"
  else
    assert_fail "workUnits map declares '${field}' (read by a prompt builder, but dropped by core.js's normalization — its paragraph can never render under the Workflow substrate)"
  fi
done <<< "$builder_fields"

# ==========================================================================
echo "== (B) the generated workflow renders each affected paragraph end-to-end"
# ==========================================================================

harness="$tmp/harness.mjs"
cat > "$harness" <<'HARNESS_EOF'
// Execute do-work-dispatch.workflow.js with the runtime's injected globals and
// print every prompt handed to agent(), JSON-encoded, one array on stdout.
import fs from 'node:fs'
const src = fs
  .readFileSync(process.argv[2], 'utf8')
  .replace(/^export const meta =/m, 'const meta =')
const args = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const prompts = []
const agent = async (prompt) => {
  prompts.push(String(prompt))
  return { mode: 'issue-work', outcome: 'shipped', summary: 'ok' }
}
const parallel = async (tasks) => Promise.all(tasks.map((t) => t()))
const pipeline = async (list, fn) => Promise.all(list.map(fn))
const noop = () => {}
const fn = new AsyncFunction('agent', 'parallel', 'pipeline', 'log', 'phase', 'args', src)
await fn(agent, parallel, pipeline, noop, noop, args)
process.stdout.write(JSON.stringify(prompts))
HARNESS_EOF

cat > "$tmp/args.json" <<'ARGS_EOF'
{
  "repo": "mattsears18/shipyard",
  "issues": [
    {
      "number": 1615, "mode": "issue-work", "model": "sonnet", "trust": "trusted",
      "branch": "do-work/slice-1615", "worktreePath": "/tmp/wt-1615",
      "pluginRoot": "/tmp/PLUGIN-ROOT-SENTINEL-1615",
      "pluginRootStale": "PLUGIN-ROOT-STALE-SENTINEL-1615",
      "skillCacheStale": "SKILL-CACHE-STALE-SENTINEL-1615",
      "splitDispatch": true,
      "stalePremisePhrase": "STALE-PHRASE-SENTINEL-1615",
      "stalePremiseCorrection": "STALE-CORRECTION-SENTINEL-1615"
    }
  ]
}
ARGS_EOF

if ! node "$harness" "$workflow_js" "$tmp/args.json" > "$tmp/prompts.json" 2>"$tmp/stderr.log"; then
  assert_fail "workflow executed with a fully-populated issue-work unit"
  sed 's/^/    /' "$tmp/stderr.log"
else
  assert_pass "workflow executed with a fully-populated issue-work unit"
fi

prompt="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(p.join("\n----\n"))' "$tmp/prompts.json" 2>/dev/null)"

check_rendered() {
  local needle="$1" label="$2"
  if [[ "$prompt" == *"$needle"* ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
  fi
}

check_rendered "STALE-PHRASE-SENTINEL-1615" "#1491 stale-premise paragraph renders the phrase (stalePremisePhrase)"
check_rendered "STALE-CORRECTION-SENTINEL-1615" "#1491 stale-premise paragraph renders the correction (stalePremiseCorrection)"
check_rendered "Neutral branch name (split dispatch, #1562)" "#1562 neutral-branch paragraph renders (splitDispatch)"
check_rendered "/tmp/PLUGIN-ROOT-SENTINEL-1615" "orchestrator-supplied plugin root renders (pluginRoot)"
check_rendered "PLUGIN-ROOT-STALE-SENTINEL-1615" "#1319 staleness warning renders (pluginRootStale)"
check_rendered "SKILL-CACHE-STALE-SENTINEL-1615" "#1319 skill-cache warning renders (skillCacheStale)"

echo
echo "workflow-unit-field-passthrough-1615: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
