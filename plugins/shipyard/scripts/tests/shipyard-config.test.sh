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
assert_contains "$out" '"issue_work": "claude-sonnet-5"' "load emits default models.issue_work"

assert_equals "$("$helper" get auto_merge.policy)" "trusted-only" "get auto_merge.policy returns default"
assert_equals "$("$helper" get models.issue_work)" "claude-sonnet-5" "get models.issue_work returns default"
assert_equals "$("$helper" get models.verify)" "claude-opus-4-8" "get models.verify returns the Opus 4.8 verify-gate default (#784)"

# concurrency.default — issue #268: built-in default is 1 (sequential) because
# most repos that follow the "cut a release per PR" convention hard-collide on
# plugin.json / version-row paths and the second slot parks. Asserting the
# literal here prevents an accidental flip back to 2.
assert_equals "$("$helper" get concurrency.default)" "1" "get concurrency.default returns 1 (issue #268)"

# dependencies.new_dep_version — issue #694: a worker introducing a NEW dependency
# defaults to installing the latest stable version (with an unconditional peer/SDK
# carve-out). The built-in default is latest-stable; asserting the literal here
# prevents an accidental flip to conservative pinning.
assert_equals "$("$helper" get dependencies.new_dep_version)" "latest-stable" "get dependencies.new_dep_version returns latest-stable (issue #694)"

# worktree_reap.max_per_session / warn_threshold — issue #836: the step-3b
# cross-session stale-worktree sweep is bounded (default 10 per session,
# oldest-first) and the session-start advisory fires once the on-disk
# agent-* count meets/exceeds warn_threshold (default 20). Asserting the
# literals here prevents an accidental drift in either default.
assert_equals "$("$helper" get worktree_reap.max_per_session)" "10" "get worktree_reap.max_per_session returns 10 (issue #836)"
assert_equals "$("$helper" get worktree_reap.warn_threshold)" "20" "get worktree_reap.warn_threshold returns 20 (issue #836)"

# dispatch.substrate — RETIRED (#791). #787 scaffolded the Dynamic Workflows
# substrate, #788/#789 wired all seven modes to it, and #790 flipped the built-in
# default to "workflow" while retaining the legacy "agent" path for one release
# as an instant-revert override. #791 removed that legacy path, so the knob is
# dead config: it is gone from the built-in defaults AND from the schema.
"$helper" get dispatch.substrate >/dev/null 2>&1
assert_exit_code "$?" 3 "get dispatch.substrate exits 3 — the knob was retired (#791)"

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
# `show --layer user` reflects the on-disk file verbatim (the alias name), even
# though the merge path remaps it onto auto_merge.policy (issue #403, asserted
# in the dedicated remap section below). The raw user layer must NOT be
# normalized so the file's actual contents stay inspectable.
out=$("$helper" show --layer user 2>&1)
assert_contains "$out" '"default_auto_merge_policy": "never"' "user-layer show reflects the on-disk alias verbatim"

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
echo "== user-global aliases remap onto canonical paths (issue #403)"
# The user-global schema declares convenience aliases (default_auto_merge_policy,
# default_models, cost_tracking_enabled) that historically validated cleanly but
# were silently inert — the flat last-wins merge never remapped them onto the
# canonical paths every consumer reads. normalize_user_layer() now translates
# them on load. These assertions lock the remap so the drift can't silently
# return, and verify the aliases (and the three removed keys) no longer leak
# into the effective config under their inert names.
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"

# default_auto_merge_policy -> auto_merge.policy (with source attribution = user).
cat > "$home/config.json" <<'JSON'
{
  "version": 1,
  "default_auto_merge_policy": "never",
  "default_models": { "issue_work": "claude-test-model", "fix_rebase": "claude-rebase-model" },
  "cost_tracking_enabled": false
}
JSON
assert_equals "$("$helper" get auto_merge.policy)" "never" "default_auto_merge_policy remaps to auto_merge.policy"
assert_equals "$("$helper" get auto_merge.policy --with-source | cut -f2)" "user" "remapped auto_merge.policy sourced to user layer"
assert_equals "$("$helper" get models.issue_work)" "claude-test-model" "default_models.issue_work remaps to models.issue_work"
assert_equals "$("$helper" get models.fix_rebase)" "claude-rebase-model" "default_models.fix_rebase remaps to models.fix_rebase"
# A mode NOT named in default_models still falls through to the built-in default.
assert_equals "$("$helper" get models.fix_main_ci)" "claude-sonnet-5" "unset mode falls through to built-in default model"
assert_equals "$("$helper" get cost_tracking.enabled)" "false" "cost_tracking_enabled remaps to cost_tracking.enabled"
assert_equals "$("$helper" get cost_tracking.enabled --with-source | cut -f2)" "user" "remapped cost_tracking.enabled sourced to user layer"

# The alias names must NOT leak into the effective (merged) config.
eff=$("$helper" load 2>&1)
assert_equals "$(printf '%s' "$eff" | jq -r 'has("default_auto_merge_policy")')" "false" "default_auto_merge_policy alias absent from effective config"
assert_equals "$(printf '%s' "$eff" | jq -r 'has("default_models")')" "false" "default_models alias absent from effective config"
assert_equals "$(printf '%s' "$eff" | jq -r 'has("cost_tracking_enabled")')" "false" "cost_tracking_enabled alias absent from effective config"

# Repo-level canonical paths still win over the user-global alias (last-wins).
"$helper" set auto_merge.policy always --repo
assert_equals "$("$helper" get auto_merge.policy)" "always" "repo auto_merge.policy wins over user alias"
assert_equals "$("$helper" get auto_merge.policy --with-source | cut -f2)" "repo" "source is repo when repo overrides the alias"
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard"

# The three removed keys (currency, pricing_override, exclude_repos_from_cost_tracking)
# are no longer in the schema — setting them is now an unknown-field validation error.
echo '{"version":1,"currency":"USD"}' > "$home/config.json"
"$helper" validate --layer user 2>/dev/null
assert_exit_code "$?" 70 "removed key 'currency' rejected by user schema"
echo '{"version":1,"pricing_override":{"claude-opus-4-7":{"input":1}}}' > "$home/config.json"
"$helper" validate --layer user 2>/dev/null
assert_exit_code "$?" 70 "removed key 'pricing_override' rejected by user schema"
echo '{"version":1,"exclude_repos_from_cost_tracking":["owner/repo"]}' > "$home/config.json"
"$helper" validate --layer user 2>/dev/null
assert_exit_code "$?" 70 "removed key 'exclude_repos_from_cost_tracking' rejected by user schema"
rm -f "$home/config.json"

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
echo "== main_ci.max_fix_attempts — fix-main-ci flake circuit breaker (#589)"
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"
# Built-in default is 3 (the fix-main-ci analogue of the blocked:ci 3-attempt cap).
assert_equals "$("$helper" get main_ci.max_fix_attempts)" "3" "default main_ci.max_fix_attempts is 3"
assert_equals "$("$helper" get main_ci.max_fix_attempts --with-source | cut -f2)" "defaults" "default comes from the built-in layer"

# Repo-level override is honored and validates.
out=$("$helper" set main_ci.max_fix_attempts 2 --repo 2>&1)
assert_contains "$out" "wrote main_ci.max_fix_attempts" "set --repo writes main_ci.max_fix_attempts"
assert_equals "$("$helper" get main_ci.max_fix_attempts)" "2" "repo override returns 2"
assert_equals "$("$helper" get main_ci.max_fix_attempts --with-source | cut -f2)" "repo" "override source is repo"
# Sibling main_ci keys untouched by the override (deep merge).
assert_equals "$("$helper" get main_ci.aggregation_mode)" "branch-protection" "aggregation_mode still falls through to default"

# Schema rejects a non-integer.
echo '{"version":1,"main_ci":{"max_fix_attempts":"three"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci.max_fix_attempts rejects non-integer"

# Schema rejects below the minimum (1).
echo '{"version":1,"main_ci":{"max_fix_attempts":0}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "main_ci.max_fix_attempts rejects 0 (below minimum)"

# A valid override validates.
echo '{"version":1,"main_ci":{"max_fix_attempts":5}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo
assert_exit_code "$?" 0 "main_ci.max_fix_attempts accepts a valid integer >= 1"

# Reset to valid
echo '{"version":1}' > "$repo/shipyard.config.json"

# --------------------------------------------------------------------------
echo "== dispatch.substrate — retired knob is rejected, not ignored (#791)"
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"
# `set` on the retired key must fail schema validation rather than write a key
# nothing reads.
out=$("$helper" set dispatch.substrate workflow --repo 2>&1)
assert_contains "$out" "unknown field dispatch" "set dispatch.substrate is rejected — the knob was retired (#791)"

# A stale config carrying the retired block is rejected outright
# (additionalProperties:false at the root), so an upgrading repo is told to
# delete it instead of silently running with dead config. This is the breaking
# change behind #791's major version bump.
echo '{"version":1,"dispatch":{"substrate":"agent"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "a stale dispatch.substrate: agent config is rejected (#791)"
echo '{"version":1,"dispatch":{"substrate":"workflow"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "a stale dispatch.substrate: workflow config is rejected (#791)"

# Reset to valid
echo '{"version":1}' > "$repo/shipyard.config.json"

# --------------------------------------------------------------------------
echo "== load (not just validate) surfaces schema failures non-silently (issue #367)"
# The orchestrator's step 0.4 captures `load`'s exit code AND stderr to warn
# loudly when a present-but-invalid shipyard.config.json would otherwise make
# EFFECTIVE_CONFIG silently empty. This locks the contract step 0.4 relies on:
#   (a) `load` against an invalid repo config exits 70 (NOT 0),
#   (b) stdout is empty (so a naive `EFFECTIVE_CONFIG=$(... load)` would be ""),
#   (c) stderr names each rejected field on its own indented `  .path:` line.
echo '{"version":1,"auto_merge":{"policy":"bogus-enum"}}' > "$repo/shipyard.config.json"
load_stdout=$("$helper" load 2>/dev/null)
load_rc=$?
assert_exit_code "$load_rc" 70 "load exits 70 on schema-invalid repo config"
assert_equals "$load_stdout" "" "load emits EMPTY stdout on schema failure (the silent-degrade trap)"

load_stderr=$("$helper" load 2>&1 1>/dev/null)
assert_contains "$load_stderr" "schema validation failed" "load stderr announces schema validation failure"
assert_contains "$load_stderr" ".auto_merge.policy"        "load stderr names the rejected field path"
# The orchestrator extracts rejected-field lines via `grep -E '^\s+\.'` — verify
# at least one indented dotted-path line exists for that extraction to match.
rejected_lines=$(printf '%s\n' "$load_stderr" | grep -Ec '^[[:space:]]+\.')
assert_equals "$([ "$rejected_lines" -ge 1 ] && echo yes || echo no)" "yes" "load stderr has >=1 indented '  .path:' line for step 0.4 extraction"

# Multiple violations → multiple indented lines (the `; `-join in step 0.4
# turns these into a single warning string).
echo '{"version":1,"auto_merge":{"policy":"bogus"},"repo":{"owner":"Has Space"}}' > "$repo/shipyard.config.json"
load_stderr_multi=$("$helper" load 2>&1 1>/dev/null)
multi_lines=$(printf '%s\n' "$load_stderr_multi" | grep -Ec '^[[:space:]]+\.')
assert_equals "$([ "$multi_lines" -ge 2 ] && echo yes || echo no)" "yes" "load stderr names multiple rejected fields when >1 violation"

# Reset to valid
echo '{"version":1}' > "$repo/shipyard.config.json"
"$helper" load >/dev/null 2>&1
assert_exit_code "$?" 0 "load exits 0 again after config repaired"

# --------------------------------------------------------------------------
echo "== trust.authors accepts every GitHub login shape (issue #371)"
# The trust.authors[] items used to carry pattern ^[A-Za-z0-9][A-Za-z0-9-]*$,
# which rejected the documented GH App alias shapes app/<name> (GraphQL) and
# <name>[bot] (REST) — the exact forms setup.md § "GH App alias normalization"
# claims work. The pattern was dropped: the field is only a comparison key, so
# an entry that matches nothing is a harmless no-op. Items must still be strings.

# Repo layer (validated against shipyard.config.schema.json): a mixed array of
# plain login, REST bot, GraphQL app, dependabot bot, and a nonsense-but-string
# entry all load cleanly.
echo '{"version":1,"trust":{"authors":["mattsears18","sentry[bot]","app/sentry","dependabot[bot]","not-a-real-user"]}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo
assert_exit_code "$?" 0 "trust.authors (repo) accepts mixed login shapes incl. app/sentry and sentry[bot]"

# User layer (validated against shipyard.user-config.schema.json): same shapes.
# (User schema requires version.)
echo '{"version":1,"trust":{"authors":["alice","app/sentry","dependabot[bot]"]}}' > "$home/config.json"
"$helper" validate --layer user
assert_exit_code "$?" 0 "trust.authors (user) accepts mixed login shapes incl. app/sentry"
rm -f "$home/config.json"

# Non-string items are still rejected (items: { type: string }).
echo '{"version":1,"trust":{"authors":["alice",42]}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "trust.authors rejects non-string (number) item"

# Reset to valid
echo '{"version":1}' > "$repo/shipyard.config.json"

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
echo "== ci CI-minute discipline config (issue #323)"
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard" "$home/config.json"

# Defaults: every key at the pre-#323-preserving value
assert_equals "$("$helper" get ci.skip_drain_rebase)"                            "false" "ci.skip_drain_rebase default is false"
assert_equals "$("$helper" get ci.verify_check_failing_on_head_before_dispatch)" "false" "ci.verify_check_failing_on_head_before_dispatch default is false"
assert_equals "$("$helper" get ci.require_in_progress_check_to_settle)"          "false" "ci.require_in_progress_check_to_settle default is false"
assert_equals "$("$helper" get ci.skip_speculative_rerun)"                       "true"  "ci.skip_speculative_rerun default is true"
# max_drain_rebases defaults to null, which the `get` helper exit-3s on by spec —
# verify the exit code and message rather than the value (no value to compare).
"$helper" get ci.max_drain_rebases 2>/dev/null
assert_exit_code "$?" 3 "ci.max_drain_rebases default is null (get exit-3s on null)"
assert_equals "$("$helper" get ci.skip_drain_rebase --with-source | cut -f2)" "defaults" "ci.skip_drain_rebase source is defaults"
# #374 drain-duration knobs ship with active non-zero defaults (not opt-in gates)
assert_equals "$("$helper" get ci.settled_minutes)" "20" "ci.settled_minutes default is 20 (#374)"
assert_equals "$("$helper" get ci.max_drain_hours)"  "8"  "ci.max_drain_hours default is 8 (#374)"

# Setting ci.skip_drain_rebase = true (the headline cost-discipline flip)
"$helper" set ci.skip_drain_rebase true --repo
assert_equals "$("$helper" get ci.skip_drain_rebase)" "true" "set ci.skip_drain_rebase=true round-trips"
assert_equals "$("$helper" get ci.skip_drain_rebase --with-source | cut -f2)" "repo" "source is repo after set"

# Setting ci.max_drain_rebases as an integer
"$helper" set ci.max_drain_rebases 3 --repo
assert_equals "$("$helper" get ci.max_drain_rebases)" "3" "set ci.max_drain_rebases=3 round-trips as integer"

# Setting the verify-stale-failure flag
"$helper" set ci.verify_check_failing_on_head_before_dispatch true --repo
assert_equals "$("$helper" get ci.verify_check_failing_on_head_before_dispatch)" "true" "set ci.verify_check_failing_on_head_before_dispatch round-trips"

# Setting the #374 drain-duration knobs
"$helper" set ci.settled_minutes 30 --repo
assert_equals "$("$helper" get ci.settled_minutes)" "30" "set ci.settled_minutes=30 round-trips as integer (#374)"
"$helper" set ci.max_drain_hours 12 --repo
assert_equals "$("$helper" get ci.max_drain_hours)" "12" "set ci.max_drain_hours=12 round-trips (#374)"

# Schema validation rejects settled_minutes below minimum (minimum: 1)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "ci": { "settled_minutes": 0 } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "ci.settled_minutes rejects value below minimum 1 (#374)"

# Schema validation rejects max_drain_hours below minimum (minimum: 0.1)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "ci": { "max_drain_hours": 0 } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "ci.max_drain_hours rejects value below minimum 0.1 (#374)"

# Schema validation rejects non-boolean for skip_drain_rebase
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "ci": { "skip_drain_rebase": "yes" } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "ci.skip_drain_rebase rejects non-boolean value"

# Schema validation rejects negative max_drain_rebases (minimum: 0)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "ci": { "max_drain_rebases": -1 } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "ci.max_drain_rebases rejects negative integer"

# Schema validation rejects unknown ci fields (additionalProperties: false)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "ci": { "skip_everything": true } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "ci rejects unknown fields"

# Layered override: local can flip skip_drain_rebase without touching the repo file
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard"
"$helper" set ci.skip_drain_rebase true --repo
"$helper" set ci.skip_drain_rebase false --local
assert_equals "$("$helper" get ci.skip_drain_rebase)" "false" "local layer overrides repo for ci.skip_drain_rebase"
assert_equals "$("$helper" get ci.skip_drain_rebase --with-source | cut -f2)" "local" "source reflects local layer after override"

# --------------------------------------------------------------------------
echo "== scope.diagnosis_reuse_hours (issue #563)"
repo=$(mktmprepo)
home=$(mktmprepo)
export SHIPYARD_REPO_ROOT="$repo"
export SHIPYARD_HOME="$home"

# Built-in default is 72
assert_equals "$("$helper" get scope.diagnosis_reuse_hours)" "72" "scope.diagnosis_reuse_hours default is 72"

# Can be overridden at the repo layer
"$helper" set scope.diagnosis_reuse_hours 24 --repo
assert_equals "$("$helper" get scope.diagnosis_reuse_hours)" "24" "scope.diagnosis_reuse_hours can be set to 24 at repo layer"
assert_equals "$("$helper" get scope.diagnosis_reuse_hours --with-source | cut -f2)" "repo" "source is repo after set"

# Can be disabled (set to 0)
"$helper" set scope.diagnosis_reuse_hours 0 --repo
assert_equals "$("$helper" get scope.diagnosis_reuse_hours)" "0" "scope.diagnosis_reuse_hours can be set to 0 (disable caching)"

# Schema validation rejects a negative value
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "diagnosis_reuse_hours": -1 } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "scope.diagnosis_reuse_hours rejects negative integer (#563)"

# Schema validation rejects a non-integer value
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "diagnosis_reuse_hours": "72h" } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "scope.diagnosis_reuse_hours rejects non-integer string (#563)"

# Schema validation rejects unknown scope fields (additionalProperties: false)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "cache_everything": true } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "scope rejects unknown fields (#563)"

# Local override takes precedence over repo value
rm -rf "$repo/shipyard.config.json" "$repo/.shipyard"
"$helper" set scope.diagnosis_reuse_hours 48 --repo
"$helper" set scope.diagnosis_reuse_hours 168 --local
assert_equals "$("$helper" get scope.diagnosis_reuse_hours)" "168" "local layer overrides repo for scope.diagnosis_reuse_hours"
assert_equals "$("$helper" get scope.diagnosis_reuse_hours --with-source | cut -f2)" "local" "source reflects local layer for scope.diagnosis_reuse_hours"

# --------------------------------------------------------------------------
echo "== scope.self_modification_paths (issue #591)"
repo=$(mktmprepo)
home=$(mktmprepo)
export SHIPYARD_REPO_ROOT="$repo"
export SHIPYARD_HOME="$home"

# Built-in default is the four-path Auto-Mode-denied agent-config set, including .claude/hooks/
default_smp="$("$helper" get scope.self_modification_paths)"
assert_equals "$default_smp" \
  '[".claude/settings.json",".claude/settings.local.json",".mcp.json",".claude/hooks/"]' \
  "scope.self_modification_paths default is the four-path set (#591)"
# .claude/hooks/ coverage is in the default (the gap #591 closed)
case "$default_smp" in
  *'.claude/hooks/'*) assert_equals "yes" "yes" "scope.self_modification_paths default includes .claude/hooks/ (#591)" ;;
  *) assert_equals "no" "yes" "scope.self_modification_paths default includes .claude/hooks/ (#591)" ;;
esac

# Can be emptied to disable Detector 2 (users not running under Auto Mode)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "self_modification_paths": [] } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 0 "scope.self_modification_paths accepts an empty array (disable Detector 2) (#591)"
assert_equals "$("$helper" get scope.self_modification_paths)" "[]" "scope.self_modification_paths can be emptied to [] (#591)"

# Can be customized (repo layer)
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "self_modification_paths": [".claude/settings.json", ".claude/hooks/", ".vscode/settings.json"] } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 0 "scope.self_modification_paths accepts a custom string array (#591)"

# Schema validation rejects a non-array value
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "self_modification_paths": ".claude/settings.json" } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "scope.self_modification_paths rejects a non-array value (#591)"

# Schema validation rejects non-string array items
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "scope": { "self_modification_paths": [42] } }
JSON
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "scope.self_modification_paths rejects non-string array items (#591)"

# --------------------------------------------------------------------------
echo "== merge_gate — local-only-CI merge gate (issue #643)"
repo=$(mktmprepo)
home=$(mktmprepo)
export SHIPYARD_REPO_ROOT="$repo"
export SHIPYARD_HOME="$home"

# Built-in defaults preserve cloud-CI behavior: empty command = no gate runs.
# (An empty-string default key reports as "not present in effective config" for
# `get`/`--with-source`, matching the existing version_coordination.manifest_path
# convention — so source is asserted on the non-empty-default keys below.)
assert_equals "$("$helper" get merge_gate.command)" "" "default merge_gate.command is empty (cloud-CI behavior unchanged)"
assert_equals "$("$helper" get merge_gate.serialize)" "false" "default merge_gate.serialize is false"
assert_equals "$("$helper" get merge_gate.serialize --with-source | cut -f2)" "defaults" "merge_gate.serialize default comes from the built-in layer"
assert_equals "$("$helper" get merge_gate.max_unmerged_ahead)" "2" "default merge_gate.max_unmerged_ahead is 2"
assert_equals "$("$helper" get merge_gate.clear_state_command)" "" "default merge_gate.clear_state_command is empty"

# Repo-level override is honored and validates; sibling keys untouched (deep merge).
out=$("$helper" set merge_gate.command "npm run ci:report" --repo 2>&1)
assert_contains "$out" "wrote merge_gate.command" "set --repo writes merge_gate.command"
assert_equals "$("$helper" get merge_gate.command)" "npm run ci:report" "repo override returns the command"
assert_equals "$("$helper" get merge_gate.command --with-source | cut -f2)" "repo" "override source is repo"
assert_equals "$("$helper" get merge_gate.max_unmerged_ahead)" "2" "max_unmerged_ahead still falls through to default after command override"

# serialize + max_unmerged_ahead overrides validate.
cat > "$repo/shipyard.config.json" <<'JSON'
{ "version": 1, "merge_gate": { "command": "make ci", "serialize": true, "max_unmerged_ahead": 1, "clear_state_command": "git clean -fdX -- app" } }
JSON
"$helper" validate --layer repo
assert_exit_code "$?" 0 "merge_gate accepts a full valid block"

# Schema rejects a non-string command.
echo '{"version":1,"merge_gate":{"command":42}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "merge_gate.command rejects a non-string value"

# Schema rejects a non-boolean serialize.
echo '{"version":1,"merge_gate":{"serialize":"yes"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "merge_gate.serialize rejects a non-boolean value"

# Schema rejects max_unmerged_ahead below the minimum (1).
echo '{"version":1,"merge_gate":{"max_unmerged_ahead":0}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "merge_gate.max_unmerged_ahead rejects 0 (below minimum)"

# Schema rejects a non-integer max_unmerged_ahead.
echo '{"version":1,"merge_gate":{"max_unmerged_ahead":2.5}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "merge_gate.max_unmerged_ahead rejects a non-integer"

# Schema rejects unknown merge_gate fields (additionalProperties: false).
echo '{"version":1,"merge_gate":{"banana":true}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "merge_gate rejects unknown fields"

# Local layer overrides repo for merge_gate.serialize (deep merge across layers).
echo '{"version":1,"merge_gate":{"serialize":true}}' > "$repo/shipyard.config.json"
"$helper" set merge_gate.serialize false --local
assert_equals "$("$helper" get merge_gate.serialize)" "false" "local layer overrides repo for merge_gate.serialize"

# --------------------------------------------------------------------------
echo "== worktree_reap — bounded/checkpointed sweep + threshold warning (issue #836)"

# A valid full block validates.
echo '{"version":1,"worktree_reap":{"max_per_session":25,"warn_threshold":50}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo
assert_exit_code "$?" 0 "worktree_reap accepts a full valid block"
assert_equals "$("$helper" get worktree_reap.max_per_session)" "25" "repo override returns max_per_session"
assert_equals "$("$helper" get worktree_reap.warn_threshold)" "50" "repo override returns warn_threshold"

# max_per_session: 0 is allowed (disables removal, minimum: 0).
echo '{"version":1,"worktree_reap":{"max_per_session":0}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo
assert_exit_code "$?" 0 "worktree_reap.max_per_session accepts 0 (disables removal)"

# Schema rejects a negative max_per_session.
echo '{"version":1,"worktree_reap":{"max_per_session":-1}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "worktree_reap.max_per_session rejects a negative value"

# Schema rejects a non-integer warn_threshold.
echo '{"version":1,"worktree_reap":{"warn_threshold":"lots"}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "worktree_reap.warn_threshold rejects a non-integer"

# Schema rejects unknown worktree_reap fields (additionalProperties: false).
echo '{"version":1,"worktree_reap":{"banana":true}}' > "$repo/shipyard.config.json"
"$helper" validate --layer repo 2>/dev/null
assert_exit_code "$?" 70 "worktree_reap rejects unknown fields"

# Reset to valid
rm -rf "$repo/.shipyard"
echo '{"version":1}' > "$repo/shipyard.config.json"

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
