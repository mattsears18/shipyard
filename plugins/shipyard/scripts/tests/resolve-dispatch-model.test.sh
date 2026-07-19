#!/usr/bin/env bash
# Test: the `models.*` config surface is HONORED at dispatch time — the
# effective dispatch model matches the configured one (issue #727).
#
# Background — issue #727
# -----------------------
# `models.*` was a DEAD config surface. It was defined in the repo schema,
# settable via `/shipyard:config set models.issue_work <id>`, aliased from the
# user-global layer as `default_models.*`, documented in CLAUDE.md, and covered
# by shipyard-config.test.sh — and READ BY NOTHING. `grep -rn 'models\.issue_work'`
# hit only the schema, the config command's own docs, and its tests; no dispatch
# path consumed it. Real model selection lived exclusively in each agent shim's
# `model:` frontmatter, which a consumer repo cannot override.
#
# The repro: this repo's own committed shipyard.config.json sets
# `models.issue_work: claude-sonnet-4-6`, yet all five issue-work dispatches of
# session 01Kz7y78wD4CDxf6Fkhn7rH1 ran on claude-opus-4-8 (the inherited session
# model), because `shipyard:issue-worker` pins no model and nothing read the key.
# The user asked for Sonnet and silently got Opus — a ~5x cost difference per
# dispatch, with no warning anywhere. A config key that silently no-ops is worse
# than no config key.
#
# The fix (option (a) on #727): scripts/resolve-dispatch-model.sh reads
# `models.<mode>` from the merged config and maps it onto the `Agent` tool's
# `model` parameter (an enum — opus/sonnet/haiku/fable — which takes precedence
# over frontmatter). The orchestrator calls it at every dispatch site.
#
# This test pins:
#   (A) the resolver script exists and is executable;
#   (B) the id -> Agent-alias mapping (concrete ids, dated ids, bare aliases);
#   (C) fail-open: unknown id / absent key / unreadable config => EMPTY output
#       (caller omits `model`, frontmatter default applies) — never a hard fail,
#       never a silently-substituted wrong-tier model;
#   (D) mode-name normalization (hyphenated dispatch names == underscored keys)
#       and rejection of an unknown mode;
#   (E) THE REGRESSION GUARD — a repo config that sets `models.<mode>` resolves
#       to that model, and the user-global `default_models.<mode>` alias does too;
#   (F) built-in defaults mirror each shim's frontmatter pin family-for-family,
#       so honoring the config is a behavioral no-op on an unconfigured repo;
#   (G) the orchestrator's dispatch spec actually CALLS the resolver and passes
#       `model` on the Agent call — the "config is read by nothing" gap itself.
#   (H) the advisory `--fallback-chain` helper (issue #766) — a per-family
#       degrade-on-overload chain (opus->sonnet,haiku; sonnet->haiku;
#       haiku->empty; fable->opus,sonnet,haiku), accepting either a bare
#       family alias or a full model id, fail-open on an unrecognized family,
#       and a usage error on a missing argument. This helper is NOT wired
#       into dispatch (the `Agent` tool has no fallback parameter) — it exists
#       so `do-work-RATIONALE.md`'s fallbackModel recommendation has a single
#       source of truth for the chain ordering instead of hand-maintained
#       prose. See the script's own header comment for why this doesn't
#       repeat #727's dead-config-surface mistake.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/resolve-dispatch-model.test.sh

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

RESOLVER="$repo_root/plugins/shipyard/scripts/resolve-dispatch-model.sh"
CONFIG_HELPER="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
AGENTS_DIR="$repo_root/plugins/shipyard/agents"
DISPATCH_RULES_MD="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
POOL_FILL_MD="$repo_root/plugins/shipyard/commands/do-work/setup/07-pool-fill.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected: [%s]\n    got:      [%s]\n' "$want" "$got"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

# map <model-id> -> stdout of the pure mapping path
map() { bash "$RESOLVER" --map "$1" 2>/dev/null; }

# resolve_in <tmp-repo-root> <tmp-home> <mode> -> stdout of the live path
resolve_in() {
  SHIPYARD_REPO_ROOT="$1" SHIPYARD_HOME="$2" bash "$RESOLVER" "$3" 2>/dev/null
}

echo "== (A) the resolver script exists and is executable"

if [[ -f "$RESOLVER" ]]; then
  assert_pass "scripts/resolve-dispatch-model.sh exists"
else
  assert_fail "scripts/resolve-dispatch-model.sh exists"
  echo "  cannot continue without the resolver" >&2
  exit 1
fi
if [[ -x "$RESOLVER" ]]; then
  assert_pass "resolve-dispatch-model.sh is executable"
else
  assert_fail "resolve-dispatch-model.sh is executable"
fi

echo
echo "== (B) model-id -> Agent-tool alias mapping"

assert_equals "$(map claude-opus-4-8)"   "opus"   "claude-opus-4-8 -> opus"
assert_equals "$(map claude-opus-4-7)"   "opus"   "claude-opus-4-7 -> opus"
assert_equals "$(map claude-sonnet-4-6)" "sonnet" "claude-sonnet-4-6 -> sonnet (the #727 repro value)"
assert_equals "$(map claude-haiku-4-5)"  "haiku"  "claude-haiku-4-5 -> haiku"
assert_equals "$(map claude-fable-5)"    "fable"  "claude-fable-5 -> fable"
# The harness reports dated ids; the pricing table resolves them, so must we.
assert_equals "$(map claude-haiku-4-5-20251001)" "haiku" "dated id (claude-haiku-4-5-20251001) -> haiku"
# Bare aliases are already Agent-tool values — they must pass through unchanged.
assert_equals "$(map opus)"   "opus"   "bare alias opus passes through"
assert_equals "$(map sonnet)" "sonnet" "bare alias sonnet passes through"
assert_equals "$(map haiku)"  "haiku"  "bare alias haiku passes through"
# Case-insensitive: a config value is user-typed.
assert_equals "$(map Claude-Sonnet-4-6)" "sonnet" "mapping is case-insensitive"

echo
echo "== (C) fail-open — unknown / empty ids resolve to EMPTY, never a wrong model"

assert_equals "$(map 'gpt-4o')"            "" "unknown family (gpt-4o) -> empty (frontmatter default applies)"
assert_equals "$(map 'claude-notreal-9-9')" "" "unknown family (claude-notreal-9-9) -> empty"
assert_equals "$(map '')"                  "" "empty id -> empty"

bash "$RESOLVER" --map 'gpt-4o' >/dev/null 2>&1
assert_equals "$?" "0" "unknown id exits 0 (fail-open — never hard-fails a dispatch)"

warn=$(bash "$RESOLVER" --map 'gpt-4o' 2>&1 >/dev/null)
if [[ "$warn" == *"no known model family"* ]]; then
  assert_pass "unknown id warns on stderr (not silent)"
else
  assert_fail "unknown id warns on stderr (not silent)"
  printf '    stderr was: [%s]\n' "$warn"
fi

echo
echo "== (D) mode-name normalization + unknown-mode rejection"

tmp_root="$(mktemp -d)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_home"' EXIT

# An unconfigured repo (no shipyard.config.json) still resolves via built-in
# defaults, and hyphenated == underscored.
h=$(resolve_in "$tmp_root" "$tmp_home" fix-checks-only)
u=$(resolve_in "$tmp_root" "$tmp_home" fix_checks_only)
assert_equals "$h" "$u" "hyphenated and underscored mode names resolve identically"

bash "$RESOLVER" not-a-mode >/dev/null 2>&1
assert_equals "$?" "64" "unknown mode exits 64 (usage error)"

bash "$RESOLVER" >/dev/null 2>&1
assert_equals "$?" "64" "missing mode arg exits 64"

echo
echo "== (E) REGRESSION GUARD — a configured models.<mode> is the effective dispatch model"

# Repo layer: the exact shape of the #727 repro (repo config asks for Sonnet on
# issue-work; the shim's frontmatter would otherwise give Opus).
cat > "$tmp_root/shipyard.config.json" <<'JSON'
{
  "version": 1,
  "models": {
    "issue_work": "claude-sonnet-4-6",
    "fix_checks_only": "claude-opus-4-8"
  }
}
JSON

assert_equals "$(resolve_in "$tmp_root" "$tmp_home" issue-work)" "sonnet" \
  "repo config models.issue_work=claude-sonnet-4-6 => dispatch model 'sonnet' (NOT the frontmatter default)"
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" fix-checks-only)" "opus" \
  "repo config can raise a mode's tier too (fix_checks_only=claude-opus-4-8 => 'opus')"
# An unset mode falls through to the built-in default, not to the sibling's value.
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" fix-rebase)" "haiku" \
  "a mode absent from the repo config falls back to the built-in default ('haiku')"

# Local layer wins over repo layer.
mkdir -p "$tmp_root/.shipyard"
cat > "$tmp_root/.shipyard/config.local.json" <<'JSON'
{ "version": 1, "models": { "issue_work": "claude-haiku-4-5" } }
JSON
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" issue-work)" "haiku" \
  "local layer overrides repo layer (models.issue_work=claude-haiku-4-5 => 'haiku')"
rm -f "$tmp_root/.shipyard/config.local.json"

# User-global layer: the `default_models.*` alias remaps onto models.* on load
# (#403). Honoring it end-to-end is what makes the user-global surface real.
rm -f "$tmp_root/shipyard.config.json"
cat > "$tmp_home/config.json" <<'JSON'
{ "version": 1, "default_models": { "investigate": "claude-haiku-4-5" } }
JSON
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" investigate)" "haiku" \
  "user-global default_models.investigate=claude-haiku-4-5 => dispatch model 'haiku'"

# ...and an explicit repo value still beats the user-global alias.
cat > "$tmp_root/shipyard.config.json" <<'JSON'
{ "version": 1, "models": { "investigate": "claude-sonnet-4-6" } }
JSON
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" investigate)" "sonnet" \
  "explicit repo models.investigate beats the user-global default_models alias"
rm -f "$tmp_home/config.json" "$tmp_root/shipyard.config.json"

# A config layer that fails schema validation must not hard-fail the dispatch
# either — the resolver swallows the loader's error and falls back to the
# frontmatter default (same fail-open contract as an unknown id).
cat > "$tmp_root/shipyard.config.json" <<'JSON'
{ "models": { "issue_work": "claude-haiku-4-5" } }
JSON
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" issue-work)" "" \
  "a schema-invalid config layer resolves to empty (fail-open, not a dispatch failure)"
rm -f "$tmp_root/shipyard.config.json"

# A garbage config value must not fail the dispatch — it falls back to the
# frontmatter default, loudly on stderr.
cat > "$tmp_root/shipyard.config.json" <<'JSON'
{ "version": 1, "models": { "issue_work": "not-a-real-model" } }
JSON
assert_equals "$(resolve_in "$tmp_root" "$tmp_home" issue-work)" "" \
  "an unrecognized configured id resolves to empty (frontmatter default applies)"
SHIPYARD_REPO_ROOT="$tmp_root" SHIPYARD_HOME="$tmp_home" bash "$RESOLVER" issue-work >/dev/null 2>&1
assert_equals "$?" "0" "an unrecognized configured id still exits 0 (fail-open)"
rm -f "$tmp_root/shipyard.config.json"

echo
echo "== (F) built-in defaults mirror the shim frontmatter pins (honoring config is a no-op unconfigured)"

# Each shim's frontmatter model is the DEFAULT for its mode. The built-in
# `models.*` defaults must resolve to the SAME family, or simply loading the
# defaults would silently re-tier every mode on repos that set no override.
#
# `<mode-key>:<shim-file>` pairs — a plain array, not an associative one, so the
# suite runs on bash 3.2 (macOS) as well as CI's bash 5.
shim_pairs=(
  "fix_checks_only:fix-checks-worker.md"
  "fix_rebase:fix-rebase-worker.md"
  "fix_main_ci:fix-main-ci-worker.md"
  "fix_failing_prs_batch:fix-pr-batch-worker.md"
  "investigate:investigate-worker.md"
)

# The built-in defaults are what an unconfigured consumer repo gets, so read
# them with the repo's own shipyard.config.json out of the picture.
defaults_root="$(mktemp -d)"
defaults_home="$(mktemp -d)"

for pair in "${shim_pairs[@]}"; do
  mode="${pair%%:*}"
  shim_file="${pair#*:}"
  shim="$AGENTS_DIR/$shim_file"
  if [[ ! -f "$shim" ]]; then
    assert_fail "shim exists for mode $mode ($shim_file)"
    continue
  fi
  frontmatter_model=$(grep -m1 '^model:' "$shim" | sed -e 's/^model:[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '"'"'")
  default_model=$(SHIPYARD_REPO_ROOT="$defaults_root" SHIPYARD_HOME="$defaults_home" \
    bash "$CONFIG_HELPER" get "models.${mode}" 2>/dev/null)
  assert_equals "$(map "$default_model")" "$(map "$frontmatter_model")" \
    "built-in models.${mode} ($default_model) matches $shim_file frontmatter ($frontmatter_model)"
done

# issue-work pins no frontmatter model (it inherits the session model), and its
# built-in default is the Opus tier — the config default must not silently
# down-tier the one mode that intentionally runs on the big model.
issue_work_default=$(SHIPYARD_REPO_ROOT="$defaults_root" SHIPYARD_HOME="$defaults_home" \
  bash "$CONFIG_HELPER" get models.issue_work 2>/dev/null)
assert_equals "$(map "$issue_work_default")" "opus" \
  "built-in models.issue_work ($issue_work_default) resolves to the opus tier (matches the unpinned issue-worker's intent)"

rm -rf "$defaults_root" "$defaults_home"

echo
echo "== (G) the orchestrator's dispatch spec actually calls the resolver (#727's core gap)"

assert_contains "$DISPATCH_RULES_MD" "resolve-dispatch-model.sh" \
  "dispatch-rules.md invokes scripts/resolve-dispatch-model.sh"
assert_contains "$DISPATCH_RULES_MD" "models.<mode>" \
  "dispatch-rules.md names the models.<mode> config key it honors"
assert_contains "$DISPATCH_RULES_MD" "727" \
  "dispatch-rules.md cites issue #727 for the model-resolution rule"
assert_contains "$POOL_FILL_MD" "resolve-dispatch-model.sh" \
  "setup/07-pool-fill.md (the initial-pool-fill dispatch site) resolves the model too"

# The whole point: the resolved value must reach the Agent call's `model` param.
# (BT keeps the markdown backticks out of a single-quoted literal — SC2016.)
BT=$'\x60'
assert_contains "$DISPATCH_RULES_MD" "model: \"<dispatch_model>\"" \
  "dispatch-rules.md passes the resolved value as the Agent tool's model parameter"

# And the fail-open contract must be spelled out at the call site, so an empty
# resolution isn't mistaken for "pass an empty model".
assert_contains "$DISPATCH_RULES_MD" "**omit** the ${BT}model${BT} parameter" \
  "dispatch-rules.md tells the caller to OMIT the model parameter when resolution is empty"

echo
echo "== (H) advisory --fallback-chain helper (#766) — NOT wired into dispatch"

fallback() { bash "$RESOLVER" --fallback-chain "$1" 2>/dev/null; }

assert_equals "$(fallback opus)"   "sonnet,haiku"      "opus family -> sonnet,haiku"
assert_equals "$(fallback sonnet)" "haiku"              "sonnet family -> haiku"
assert_equals "$(fallback haiku)"  ""                   "haiku family -> empty (already the floor tier)"
assert_equals "$(fallback fable)"  "opus,sonnet,haiku"  "fable family -> opus,sonnet,haiku (caps at Claude Code's documented 3-model limit)"

# Case-insensitive, and a full model id resolves through map_model first.
assert_equals "$(fallback OPUS)"              "sonnet,haiku" "family match is case-insensitive"
assert_equals "$(fallback claude-opus-4-8)"   "sonnet,haiku" "full model id (claude-opus-4-8) resolves via map_model then chains"
assert_equals "$(fallback claude-sonnet-4-6)" "haiku"        "full model id (claude-sonnet-4-6) resolves via map_model then chains"

# Fail-open: an unrecognized family warns on stderr and prints empty, never a
# hard failure — same posture as the --map path in (C).
assert_equals "$(fallback 'gpt-4o')" "" "unrecognized family (gpt-4o) -> empty, not a hard failure"
bash "$RESOLVER" --fallback-chain 'gpt-4o' >/dev/null 2>&1
assert_equals "$?" "0" "unrecognized family exits 0 (fail-open)"
warn=$(bash "$RESOLVER" --fallback-chain 'gpt-4o' 2>&1 >/dev/null)
if [[ "$warn" == *"no fallback-chain recommendation"* ]]; then
  assert_pass "unrecognized family warns on stderr (not silent)"
else
  assert_fail "unrecognized family warns on stderr (not silent)"
  printf '    stderr was: [%s]\n' "$warn"
fi

# Usage error on a missing argument.
bash "$RESOLVER" --fallback-chain >/dev/null 2>&1
assert_equals "$?" "64" "--fallback-chain with no argument exits 64 (usage error)"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
