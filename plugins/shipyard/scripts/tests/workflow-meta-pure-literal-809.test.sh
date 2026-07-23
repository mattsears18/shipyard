#!/usr/bin/env bash
# Test: every Dynamic Workflows script's `export const meta` is a PURE LITERAL —
# issue #809.
#
# Background — issue #809
# -----------------------
# `plugins/shipyard/workflows/do-work-dispatch.workflow.js` shipped in 4.0.0
# through 4.0.3 with a `meta.description` assembled by string concatenation:
#
#   export const meta = {
#     name: 'do-work-dispatch',
#     description:
#       'The /shipyard:do-work dispatch loop ... — the ' +
#       'only substrate every `mode:`-driven worker ... ' +
#       ...
#   }
#
# The `Workflow` tool validates `meta` at the TOOL-CALL BOUNDARY and rejects the
# whole script unless every node inside is a literal. Each `+` is a
# `BinaryExpression`, so every invocation died with:
#
#   Invalid workflow script: meta must be a pure literal:
#   non-literal node type in meta: BinaryExpression
#
# Since #791 made that script the ONLY dispatch substrate and deleted the
# `dispatch.substrate: "agent"` fallback, the net effect was that
# `/shipyard:do-work` could not dispatch ANY worker, in ANY mode, on ANY 4.0.x
# release, with no config-level workaround. P0.
#
# WHY EXISTING CI DID NOT CATCH IT — and what this suite does differently
# ----------------------------------------------------------------------
# `node --check` PASSES on the broken file: string concatenation is perfectly
# valid JavaScript. The four sibling suites (dispatch-workflow-substrate-788 /
# -789, dispatch-substrate-cutover-790, legacy-agent-dispatch-retired-791) assert
# prompt-builder output shapes, schema enum parity, and substrate wiring — none
# invokes the `Workflow` tool, and the pure-literal rule is enforced by the tool,
# not by the JS parser. A grep for `export const meta` would not have caught it
# either.
#
# So this suite drives `scripts/check-workflow-meta-literal.mjs`, which actually
# PARSES the `meta` object with a recursive-descent parser admitting only literal
# nodes. Two halves, both load-bearing:
#
#   (A) POSITIVE — every real workflow script in the repo passes, and a battery
#       of valid-but-tricky metas passes (a description containing a literal `+`
#       and backtick CHARACTERS, escaped apostrophes, nested literal objects and
#       arrays, comments inside the object). These are exactly the cases a naive
#       "grep the meta block for + or backtick" guard would false-positive on, so
#       they pin that the checker is a parser and not a grep.
#
#   (B) NEGATIVE — the checker FAILS on a byte-for-byte copy of the #809
#       regression, and on every other way `meta` can go non-literal: template
#       literal, bare identifier, function call, spread, computed key, shorthand
#       property, concatenation nested inside an object or array value, plus the
#       missing/empty `name`/`description` cases the tool also rejects.
#
# (B) is the part that matters. A guard that has never been run against the
# broken input is a guard nobody knows works — the whole reason #809 shipped.
#
# Pure bash + node. Run with:
#   bash plugins/shipyard/scripts/tests/workflow-meta-pure-literal-809.test.sh

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

checker="$repo_root/plugins/shipyard/scripts/check-workflow-meta-literal.mjs"
workflows_dir="$repo_root/plugins/shipyard/workflows"
dispatch_js="$workflows_dir/do-work-dispatch.workflow.js"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify the pure-literal rule" >&2
  exit 1
fi

if [[ ! -f "$checker" ]]; then
  echo "FAIL: checker not found at $checker" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Assert the checker ACCEPTS a file.
assert_literal() {
  local path="$1" label="$2" out
  if out=$(node "$checker" "$path" 2>&1); then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    checker rejected it:\n'
    printf '    %s\n' "$out"
  fi
}

# Assert the checker REJECTS a file, and (optionally) that the diagnostic names
# an expected node type.
assert_not_literal() {
  local path="$1" label="$2" expect_node="${3:-}" out rc
  out=$(node "$checker" "$path" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_fail "$label"
    printf '    checker ACCEPTED a non-literal meta — the guard is not working\n'
    return
  fi
  if [[ -n "$expect_node" ]] && ! grep -qF -- "$expect_node" <<<"$out"; then
    assert_fail "$label"
    printf '    expected the diagnostic to name %s, got:\n' "$expect_node"
    printf '    %s\n' "$out"
    return
  fi
  assert_pass "$label"
}

# ==========================================================================
echo "== (A) the real workflow scripts in this repo have a pure-literal meta"
# ==========================================================================

# This is the assertion that would have been red on 4.0.0 through 4.0.3.
assert_literal "$dispatch_js" "do-work-dispatch.workflow.js: meta is a pure literal"

# Glob every workflow script so a future one is covered without editing this file
# — the same discovery-not-enumeration principle .github/workflows/tests.yml uses
# to find test suites.
shopt -s nullglob
workflow_scripts=("$workflows_dir"/*.workflow.js)
shopt -u nullglob

if [[ ${#workflow_scripts[@]} -eq 0 ]]; then
  assert_fail "at least one *.workflow.js exists under plugins/shipyard/workflows/"
else
  assert_pass "discovered ${#workflow_scripts[@]} workflow script(s) under plugins/shipyard/workflows/"
  for ws in "${workflow_scripts[@]}"; do
    assert_literal "$ws" "$(basename "$ws"): meta is a pure literal"
  done
fi

# The tool also requires `meta.name` — pin that the real script declares one, so
# a future edit can't drop it and still pass the literal check vacuously.
if node -e "
  import('file://$checker').then(m => {
    const fs = require('fs')
    const r = m.checkSource(fs.readFileSync('$dispatch_js','utf8'), 'x')
    process.exit(r.ok && r.meta.value.name.value === 'do-work-dispatch' ? 0 : 1)
  }).catch(() => process.exit(1))
" 2>/dev/null; then
  assert_pass "do-work-dispatch.workflow.js declares meta.name === 'do-work-dispatch'"
else
  assert_fail "do-work-dispatch.workflow.js declares meta.name === 'do-work-dispatch'"
fi

# ==========================================================================
echo
echo "== (B) VALID-BUT-TRICKY metas are accepted (proves this is a parser, not a grep)"
# ==========================================================================

# A `+` and a backtick appearing as CHARACTERS INSIDE the string are perfectly
# legal — the string is still a single StringLiteral. A grep-based guard scanning
# the meta block for `+` or a backtick would false-positive here and block a
# correct file.
f="$tmp/plus-and-backtick-inside-string.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'Handles a + b, and `mode:`-driven workers, and 1 + 1 = 2.',
}
EOF
assert_literal "$f" "a description containing literal '+' and backtick CHARACTERS is accepted"

f="$tmp/escaped-apostrophe.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'The caller pre-provisions each worker\'s isolated worktree.',
}
EOF
assert_literal "$f" "a description with an escaped apostrophe is accepted"

f="$tmp/double-quoted.js"
cat > "$f" <<'EOF'
export const meta = {
  "name": "x",
  "description": "A double-quoted string literal is still a literal.",
}
EOF
assert_literal "$f" "double-quoted keys and values are accepted"

f="$tmp/nested-literals.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'y',
  tags: ['issue-work', 'spike', 'fix-rebase'],
  limits: { agents: 16, perRun: 1000, enabled: true, fallback: null },
}
EOF
assert_literal "$f" "nested literal object and array values are accepted"

f="$tmp/comments-inside.js"
cat > "$f" <<'EOF'
export const meta = {
  // a line comment inside meta is trivia, not a node
  name: 'x',
  /* and a block comment too */
  description: 'y',
}
EOF
assert_literal "$f" "comments inside the meta object are accepted (trivia, not nodes)"

f="$tmp/one-line.js"
cat > "$f" <<'EOF'
export const meta = { name: 'x', description: 'y' }
EOF
assert_literal "$f" "a single-line meta is accepted"

# ==========================================================================
echo
echo "== (C) THE #809 REGRESSION ITSELF — a byte-for-byte copy must FAIL"
# ==========================================================================

# This is the exact `meta` block that shipped in 4.0.0–4.0.3, reproduced verbatim
# from `workflows/do-work-dispatch.workflow.js:140` as it stood before the fix.
# If this fixture ever starts PASSING, the guard has been broken and #809 can
# silently ship again.
f="$tmp/issue-809-verbatim.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'do-work-dispatch',
  description:
    'The /shipyard:do-work dispatch loop expressed as a Dynamic Workflow — the ' +
    'only substrate every `mode:`-driven worker is dispatched through, as of ' +
    '#791 (the final phase of the #782 epic). Modes: issue-work, ' +
    'fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, ' +
    'investigate, spike. Each mode has a prompt builder carrying that mode\'s ' +
    'augmentations (author-trust gate, verify-gate opt-in, user-feedback ' +
    'preamble, phase-1 slice, version coordination, triage policy, decompose ' +
    'fan-out cap) and validates the worker return against a structured schema. ' +
    'The caller pre-provisions each worker\'s isolated worktree and passes it as ' +
    'the work unit\'s worktreePath — the runtime has no isolation primitive.',
}
EOF
assert_not_literal "$f" "the verbatim #809 meta is REJECTED as a BinaryExpression" "BinaryExpression"

# And it must still be valid JavaScript — that's the whole point: `node --check`
# passes, so `node --check` was never going to catch this.
if node --check "$f" >/dev/null 2>&1; then
  assert_pass "the #809 fixture PASSES 'node --check' (proving node --check is insufficient)"
else
  assert_fail "the #809 fixture PASSES 'node --check' (proving node --check is insufficient)"
fi

# ==========================================================================
echo
echo "== (D) every other way meta can go non-literal is REJECTED"
# ==========================================================================

f="$tmp/template-literal.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: `a no-substitution template is still a TemplateLiteral node`,
}
EOF
assert_not_literal "$f" "a backtick template literal is REJECTED" "TemplateLiteral"

f="$tmp/template-interpolation.js"
cat > "$f" <<'EOF'
const MODES = 'issue-work'
export const meta = {
  name: 'x',
  description: `dispatch loop for ${MODES}`,
}
EOF
assert_not_literal "$f" "template interpolation is REJECTED" "TemplateLiteral"

f="$tmp/bare-identifier.js"
cat > "$f" <<'EOF'
const DESCRIPTION = 'the dispatch loop'
export const meta = {
  name: 'x',
  description: DESCRIPTION,
}
EOF
assert_not_literal "$f" "a bare identifier value is REJECTED" "Identifier"

f="$tmp/function-call.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: buildDescription(),
}
EOF
assert_not_literal "$f" "a function call value is REJECTED"

f="$tmp/spread.js"
cat > "$f" <<'EOF'
const BASE = { name: 'x' }
export const meta = {
  ...BASE,
  description: 'y',
}
EOF
assert_not_literal "$f" "an object spread is REJECTED" "SpreadElement"

f="$tmp/computed-key.js"
cat > "$f" <<'EOF'
const KEY = 'description'
export const meta = {
  name: 'x',
  [KEY]: 'y',
}
EOF
assert_not_literal "$f" "a computed property key is REJECTED"

f="$tmp/shorthand.js"
cat > "$f" <<'EOF'
const description = 'y'
export const meta = {
  name: 'x',
  description,
}
EOF
assert_not_literal "$f" "a shorthand property is REJECTED"

f="$tmp/method-shorthand.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'y',
  describe() { return 'z' },
}
EOF
assert_not_literal "$f" "a method shorthand is REJECTED"

f="$tmp/concat-nested-in-object.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'y',
  extra: { blurb: 'a' + 'b' },
}
EOF
assert_not_literal "$f" "concatenation nested inside an object value is REJECTED" "BinaryExpression"

f="$tmp/concat-nested-in-array.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: 'y',
  tags: ['a' + 'b', 'c'],
}
EOF
assert_not_literal "$f" "concatenation nested inside an array element is REJECTED" "BinaryExpression"

f="$tmp/ternary.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: true ? 'a' : 'b',
}
EOF
assert_not_literal "$f" "a ternary value is REJECTED"

# ==========================================================================
echo
echo "== (E) the tool's other meta requirements — name and description must exist"
# ==========================================================================

f="$tmp/missing-description.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
}
EOF
assert_not_literal "$f" "a meta missing 'description' is REJECTED" "MissingProperty"

f="$tmp/missing-name.js"
cat > "$f" <<'EOF'
export const meta = {
  description: 'y',
}
EOF
assert_not_literal "$f" "a meta missing 'name' is REJECTED" "MissingProperty"

f="$tmp/empty-description.js"
cat > "$f" <<'EOF'
export const meta = {
  name: 'x',
  description: '   ',
}
EOF
assert_not_literal "$f" "a blank 'description' is REJECTED" "InvalidProperty"

f="$tmp/no-meta-at-all.js"
cat > "$f" <<'EOF'
const meta = { name: 'x', description: 'y' }
EOF
assert_not_literal "$f" "a file with no exported meta is REJECTED" "MissingExport"

# The locator must not be fooled by an `export const meta = { name, description }`
# example written inside a comment — the real do-work-dispatch header contains
# exactly that, and an unanchored locator parses the comment and reports a bogus
# shorthand-property failure on a perfectly good file.
f="$tmp/meta-example-in-comment.js"
cat > "$f" <<'EOF'
/*
 * RUNTIME API used here:
 *   - `export const meta = { name, description }` — the saved-workflow header.
 *   - some other line with export const meta = { ...spread } in prose
 */
export const meta = {
  name: 'x',
  description: 'y',
}
EOF
assert_literal "$f" "an 'export const meta' EXAMPLE inside a comment does not fool the locator"

# ==========================================================================
echo
echo "== (F) the checker is wired into this repo's CI discovery"
# ==========================================================================

if [[ -x "$checker" || -f "$checker" ]]; then
  assert_pass "check-workflow-meta-literal.mjs is present at the expected path"
else
  assert_fail "check-workflow-meta-literal.mjs is present at the expected path"
fi

# This suite lives under plugins/ and matches *.test.sh, so tests.yml's
# `find plugins -type f -name '*.test.sh'` discovery picks it up with no
# workflow edit. Pin that self-referential fact so a rename can't silently
# drop the guard out of CI.
if [[ "$(basename "${BASH_SOURCE[0]}")" == *.test.sh ]]; then
  assert_pass "this suite is named *.test.sh so tests.yml's find-based discovery runs it"
else
  assert_fail "this suite is named *.test.sh so tests.yml's find-based discovery runs it"
fi

# ==========================================================================
echo
printf 'workflow-meta-pure-literal-809: %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$pass" "$RESET" "$([[ $fail -gt 0 ]] && printf '%s' "$RED" || printf '%s' "$GREEN")" "$fail" "$RESET"

[[ $fail -eq 0 ]]
