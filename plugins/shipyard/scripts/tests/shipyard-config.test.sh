#!/usr/bin/env bash
# Test suite for scripts/shipyard-config.sh.
#
# Covers the six subcommands the orchestrator and `/shipyard:*` commands
# drive:
#
#   load     — emit the effective merged config on stdout (defaults + user
#              + repo + local layers, deep-merged last-wins). --strict
#              requires the repo-level layer.
#   show     — pretty-print the effective config with each leaf's source
#              layer annotated; --plain emits raw JSON; --layer <name>
#              prints just one layer.
#   get      — resolve a dot-path against the merged config; --with-source
#              adds a trailing tab + the source layer name.
#   set      — write a field to a target layer (--repo / --local / --global).
#              Validates before writing; refuses on schema failures.
#   validate — run schema validation against a specific layer or all of them.
#   exists   — exit 0 if the repo-level layer is present, 1 otherwise.
#
# Atomicity is checked the same way session-state.test.sh does: a successful
# `set` leaves no .tmp.<pid> stragglers on the filesystem.
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/shipyard-config.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../shipyard-config.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 600
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected exit code: %s\n' "$expected"
    printf '    actual:             %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"
    fail=$((fail+1))
  fi
}

# Each test gets a private repo + SHIPYARD_HOME under fresh tmpdirs so the
# suite never touches the real ~/.shipyard or any real repo.
mktmprepo() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# --------------------------------------------------------------------------
echo "== defaults (no config files anywhere)"
repo=$(mktmprepo)
home=$(mktmprepo)
export SHIPYARD_REPO_ROOT="$repo"
export SHIPYARD_HOME="$home"

out=$("$helper" load 2>&1)
assert_contains "$out" '"version": 1'                   "load emits version"
assert_contains "$out" '"policy": "trusted-only"'       "load emits default auto_merge.policy"
assert_contains "$out" '"session_stamp": "shipyard"'    "load emits default labels.session_stamp"
assert_contains "$out" '"issue_work": "claude-opus-4-7"' "load emits default models.issue_work"

assert_equals "$("$helper" get auto_merge.policy)" "trusted-only" "get auto_merge.policy returns default"
assert_equals "$("$helper" get models.issue_work)" "claude-opus-4-7" "get models.issue_work returns default"

# concurrency.default — issue #268: built-in default is 1 (sequential) because
# most repos that follow the "cut a release per PR" convention hard-collide on
# plugin.json / version-row paths and the second slot parks. Asserting the
# literal here prevents an accidental flip back to 2.
assert_equals "$("$helper" get concurrency.default)" "1" "get concurrency.default returns 1 (issue #268)"

# get on an unknown path
"$helper" get nonexistent.path 2>/dev/null
assert_exit_code "$?" 3 "get unknown path exits 3"

# exists when no repo-level file → exit 1
"$helper" exists
assert_exit_code "$?" 1 "exists returns 1 when no repo-level file"

# load --strict when no repo-level file → exit 1
"$helper" load --strict 2>/dev/null
assert_exit_code "$?" 1 "load --strict exits 1 when no repo-level file"

# --------------------------------------------------------------------------
echo "== set --repo creates shipyard.config.json"
out=$("$helper" set auto_merge.policy always --repo 2>&1)
assert_contains "$out" "wrote auto_merge.policy" "set --repo emits write line"
assert_file_exists "$repo/shipyard.config.json" "shipyard.config.json created"
assert_equals "$("$helper" get auto_merge.policy)" "always" "get reflects the new value"
assert_equals "$("$helper" get auto_merge.policy --with-source | cut -f2)" "repo" "source is repo"

# exists now returns 0
"$helper" exists
assert_exit_code "$?" 0 "exists returns 0 after set --repo"

# load --strict now succeeds
out=$("$helper" load --strict 2>&1)
assert_contains "$out" '"policy": "always"' "load --strict emits the merged value"

# atomic-write hygiene: no .tmp.<pid> stragglers in repo or .shipyard
straggler_count=$(find "$repo" -name '*.tmp.*' | wc -l | tr -d ' ')
assert_equals "$straggler_count" "0" "no .tmp.<pid> files left after set"

# --------------------------------------------------------------------------
echo "== set --local (sparse personal override)"
out=$("$helper" set auto_merge.policy never --local 2>&1)
assert_contains "$out" ".shipyard/config.local.json" "set --local writes to .shipyard/config.local.json"
assert_file_exists "$repo/.shipyard/config.local.json" "local override file created"
assert_equals "$("$helper" get auto_merge.policy)" "never" "local override wins"
assert_equals "$("$helper" get auto_merge.policy --with-source | cut -f2)" "local" "source is local"

# --------------------------------------------------------------------------
echo "== set --global (user-global)"
out=$("$helper" set default_auto_merge_policy never --global 2>&1)
assert_contains "$out" "config.json" "set --global writes to ~/.shipyard/config.json"
assert_file_exists "$home/config.json" "user-global file created"
# This field is only in the user schema, so it's not in the merged effective
# config under that name — but loading the user layer alone should show it.
out=$("$helper" show --layer user 2>&1)
assert_contains "$out" '"default_auto_merge_policy": "never"' "user-layer show reflects the value"

# --------------------------------------------------------------------------
echo "== layer ordering: defaults < user < repo < local"
# Reset to clean state
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"

# Layer in: user sets trust.authors=[alice]
"$helper" set trust.authors '["alice"]' --global
assert_equals "$("$helper" get trust.authors)" '["alice"]'         "user layer wins over defaults"
assert_equals "$("$helper" get trust.authors --with-source | cut -f2)" "user"  "source: user"

# Layer in: repo sets trust.authors=[bob]
"$helper" set trust.authors '["bob"]' --repo
assert_equals "$("$helper" get trust.authors)" '["bob"]'          "repo layer wins over user"
assert_equals "$("$helper" get trust.authors --with-source | cut -f2)" "repo"  "source: repo"

# Layer in: local sets trust.authors=[carol]
"$helper" set trust.authors '["carol"]' --local
assert_equals "$("$helper" get trust.authors)" '["carol"]'        "local layer wins over repo"
assert_equals "$("$helper" get trust.authors --with-source | cut -f2)" "local" "source: local"

# --------------------------------------------------------------------------
echo "== deep merge preserves untouched keys across layers"
# Set repo: auto_merge.policy = always
# Set local: cost_tracking.enabled = false
# Expect: auto_merge.policy from repo, cost_tracking.enabled from local,
# everything else from defaults.
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"
"$helper" set auto_merge.policy always --repo
"$helper" set cost_tracking.enabled false --local
assert_equals "$("$helper" get auto_merge.policy --with-source | cut -f2)"   "repo"     "auto_merge.policy from repo"
assert_equals "$("$helper" get cost_tracking.enabled --with-source | cut -f2)" "local"  "cost_tracking.enabled from local"
assert_equals "$("$helper" get labels.session_stamp --with-source | cut -f2)" "defaults" "labels.session_stamp falls through to defaults"
assert_equals "$("$helper" get cost_tracking.comment_on_pr --with-source | cut -f2)" "defaults" "untouched sibling falls through to defaults"

# --------------------------------------------------------------------------
echo "== schema validation rejects bad values"
# enum violation
"$helper" set auto_merge.policy maybe --repo 2>/dev/null
assert_exit_code "$?" 70 "bad enum value rejected"

# Force a manual write of an unknown field, then validate
echo '{"version":1,"banana_split":true}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "unknown field rejected by additionalProperties:false"

# Force a manual write of a wrong-type value
echo '{"version":1,"auto_merge":{"policy":42}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "wrong type rejected"

# Missing required field (version)
echo '{"auto_merge":{"policy":"never"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "missing required version rejected"

# Reset to valid
echo '{"version":1}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo
assert_exit_code "$?" 0 "valid minimal config passes validation"

# --------------------------------------------------------------------------
echo "== secret-name forbidden surface"
# Any key matching /token|secret|api_key|password|credential/i should be
# rejected regardless of whether the schema accepts it (the schema also
# rejects unknown fields, but the secret-name check is a second layer
# that would catch typos like "accesToken" in a future-expanded schema).
echo '{"version":1,"api_key":"abc123"}' > "$repo/shipyard.config.json"
out=$("$helper" load 2>&1) || true
assert_contains "$out" "secret-like field" "secret-name api_key rejected at load"

echo '{"version":1,"auth_token":"abc"}' > "$repo/shipyard.config.json"
out=$("$helper" load 2>&1) || true
assert_contains "$out" "secret-like field" "secret-name auth_token rejected at load"

echo '{"version":1,"my_password":"abc"}' > "$repo/shipyard.config.json"
out=$("$helper" load 2>&1) || true
assert_contains "$out" "secret-like field" "secret-name password rejected at load"

# Reset
echo '{"version":1}' > "$repo/shipyard.config.json"

# --------------------------------------------------------------------------
echo "== show --layer / --plain"
"$helper" set auto_merge.policy never --repo
out=$("$helper" show --plain 2>&1)
assert_contains "$out" '"policy": "never"' "show --plain emits effective config"
# Without --plain, output is the annotated shape with .effective and .sources
out=$("$helper" show 2>&1)
assert_contains "$out" '"effective"' "show without --plain includes .effective"
assert_contains "$out" '"sources"'   "show without --plain includes .sources"

out=$("$helper" show --layer defaults 2>&1)
assert_contains "$out" '"policy": "trusted-only"' "show --layer defaults emits the defaults"

out=$("$helper" show --layer repo 2>&1)
assert_contains "$out" '"policy": "never"' "show --layer repo emits the repo layer"

# --------------------------------------------------------------------------
echo "== show with array-valued leaves (regression: issue #214)"
# `show` (the merged + source-annotated view) used to error with
#   jq: error: Cannot index array with string "0"
# whenever any effective-config leaf was an array element. The cause was
# `cmd_show`'s jq helper round-tripping `paths(scalars)` (which yields
# mixed-type arrays like ["trust","authors",0]) through join("." )+split(".")
# which coerces the integer `0` to the string "0" and breaks `getpath`.
# This regression test asserts the merged view works with a populated
# `trust.authors` and emits the expected source annotations for each
# array element.
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"
cat > "$repo/shipyard.config.json" <<'JSON'
{
  "version": 1,
  "trust": { "authors": ["foo", "bar"] }
}
JSON

out=$("$helper" show 2>&1)
assert_exit_code "$?" 0 "show exits 0 with populated trust.authors array"
assert_contains "$out" '"effective"' "show emits .effective on array-leaf config"
assert_contains "$out" '"sources"'   "show emits .sources on array-leaf config"
assert_contains "$out" '"foo"'       "show effective preserves trust.authors[0]"
assert_contains "$out" '"bar"'       "show effective preserves trust.authors[1]"

# Source annotations should attribute each array element to the layer it
# came from — repo here. Round-trip through jq to extract just the sources
# map so the assertion is robust to key ordering.
src0=$(printf '%s\n' "$out" | jq -r '.sources["trust.authors.0"]')
src1=$(printf '%s\n' "$out" | jq -r '.sources["trust.authors.1"]')
assert_equals "$src0" "repo" "source of trust.authors.0 is repo"
assert_equals "$src1" "repo" "source of trust.authors.1 is repo"

# Defaults-side array leaves (inline_trivial.patterns) should resolve to
# "defaults" — confirms the fix doesn't accidentally re-attribute them.
src_pattern0=$(printf '%s\n' "$out" | jq -r '.sources["inline_trivial.patterns.0"]')
assert_equals "$src_pattern0" "defaults" "defaults-side array element falls through to defaults"

# Scalar leaves on the same config still annotate correctly.
src_version=$(printf '%s\n' "$out" | jq -r '.sources.version')
assert_equals "$src_version" "repo" "source of scalar leaf (version) is repo"

# --------------------------------------------------------------------------
echo "== usage errors"
"$helper" 2>/dev/null
assert_exit_code "$?" 64 "no args → exit 64 (usage)"

"$helper" bogus 2>/dev/null
assert_exit_code "$?" 64 "unknown subcommand → exit 64"

"$helper" get 2>/dev/null
assert_exit_code "$?" 64 "get with no path → exit 64"

"$helper" set 2>/dev/null
assert_exit_code "$?" 64 "set with no args → exit 64"

"$helper" set 'bad path!' value --repo 2>/dev/null
assert_exit_code "$?" 64 "set with invalid path → exit 64"

# --------------------------------------------------------------------------
echo "== validate all layers"
# Make all four layers valid; validate --layer all should pass.
echo '{"version":1,"auto_merge":{"policy":"trusted-only"}}' > "$repo/shipyard.config.json"
mkdir -p "$repo/.shipyard"
echo '{"version":1,"cost_tracking":{"enabled":false}}' > "$repo/.shipyard/config.local.json"
echo '{"version":1,"default_auto_merge_policy":"never"}' > "$home/config.json"
out=$("$helper" validate 2>&1)
assert_exit_code "$?" 0 "validate all layers passes when each is valid"
assert_contains "$out" "ok" "validate emits ok"

# Break the local layer; validate should fail
echo '{"version":1,"auto_merge":{"policy":"bogus"}}' > "$repo/.shipyard/config.local.json"
"$helper" validate 2>/dev/null
assert_exit_code "$?" 70 "validate fails when local layer is invalid"

# --------------------------------------------------------------------------
echo "== concurrency.soft_collision_paths (issue #254)"
# Per-repo extension of the built-in soft-collision glob set. The orchestrator
# unions this array with the spec'd default set + any --soft-collision-path
# CLI flags at dispatch time; the loader's job is just to expose it.
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"

# A valid array of glob strings should validate and round-trip through get
cat > "$repo/shipyard.config.json" <<'JSON'
{
  "version": 1,
  "concurrency": {
    "default": 2,
    "soft_collision": 3,
    "soft_collision_paths": [
      "plugins/shipyard/commands/**/*.md",
      "plugins/shipyard/agents/**/*.md"
    ]
  }
}
JSON
"$helper" validate --layer repo
assert_exit_code "$?" 0 "valid soft_collision_paths array passes validation"
out=$("$helper" get concurrency.soft_collision_paths)
assert_contains "$out" "plugins/shipyard/commands/**/*.md" "get exposes soft_collision_paths[0]"
assert_contains "$out" "plugins/shipyard/agents/**/*.md"   "get exposes soft_collision_paths[1]"
assert_equals "$("$helper" get concurrency.soft_collision_paths --with-source | cut -f2)" "repo" "source is repo"

# An empty array is also valid (opt-out / placeholder shape)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "concurrency": { "soft_collision_paths": [] } }
JSON
"$helper" validate --layer repo
assert_exit_code "$?" 0 "empty soft_collision_paths array passes validation"

# Wrong type (object instead of array) is rejected
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "concurrency": { "soft_collision_paths": {} } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "non-array soft_collision_paths rejected"

# Non-string array items are rejected (items: { type: string })
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "concurrency": { "soft_collision_paths": ["ok.md", 42] } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "non-string soft_collision_paths item rejected"

# set --repo can write the field with --local for personal overrides too
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard"
"$helper" set concurrency.soft_collision_paths '["my/extra/**/*.md"]' --local
assert_equals "$("$helper" get concurrency.soft_collision_paths)" '["my/extra/**/*.md"]' "set --local round-trips an array"

# --------------------------------------------------------------------------
echo "== main_ci aggregation config (issue #262)"
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"

# Defaults: aggregation_mode = branch-protection, required_workflows = []
assert_equals "$("$helper" get main_ci.aggregation_mode)" "branch-protection" "main_ci.aggregation_mode default is branch-protection"
assert_equals "$("$helper" get main_ci.required_workflows)" "[]"             "main_ci.required_workflows default is empty array"
assert_equals "$("$helper" get main_ci.aggregation_mode --with-source | cut -f2)" "defaults" "main_ci.aggregation_mode source is defaults"

# Setting aggregation_mode = all-workflows (restores pre-#262 behavior)
"$helper" set main_ci.aggregation_mode all-workflows --repo
assert_equals "$("$helper" get main_ci.aggregation_mode)" "all-workflows"   "set aggregation_mode=all-workflows round-trips"
assert_equals "$("$helper" get main_ci.aggregation_mode --with-source | cut -f2)" "repo" "source is repo after set"

# Setting required_workflows explicitly
"$helper" set main_ci.required_workflows '["CI","Lint"]' --repo
assert_equals "$("$helper" get main_ci.required_workflows)" '["CI","Lint"]' "set required_workflows round-trips an array"

# Schema validation rejects bad aggregation_mode enum
"$helper" set main_ci.aggregation_mode banana --repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci.aggregation_mode rejects unknown enum value"

# Schema validation rejects wrong type for required_workflows
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "main_ci": { "required_workflows": "CI" } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci.required_workflows rejects non-array value"

# Schema validation rejects non-string items inside required_workflows
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "main_ci": { "required_workflows": ["CI", 42] } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci.required_workflows rejects non-string items"

# Schema validation rejects unknown main_ci fields (additionalProperties: false)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "main_ci": { "banana_mode": true } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci rejects unknown fields"

# Layered override: local can flip aggregation_mode without touching the repo file
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard"
"$helper" set main_ci.aggregation_mode all-workflows --repo
"$helper" set main_ci.aggregation_mode branch-protection --local
assert_equals "$("$helper" get main_ci.aggregation_mode)" "branch-protection" "local layer overrides repo for main_ci.aggregation_mode"
assert_equals "$("$helper" get main_ci.aggregation_mode --with-source | cut -f2)" "local" "source reflects local layer after override"

# --------------------------------------------------------------------------
echo
total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  printf '%sPASS%s  %d/%d assertions passed\n' "$GREEN" "$RESET" "$pass" "$total"
  exit 0
else
  printf '%sFAIL%s  %d/%d assertions failed\n' "$RED" "$RESET" "$fail" "$total"
  exit 1
fi
