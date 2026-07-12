#!/usr/bin/env bash
# Test: the /shipyard:init + /shipyard:config command spec files exist and
# document the contracts that shipyard-config.sh implements (issue #165).
#
# Background — issue #165: shipyard introduces a 4-layer config system
# (built-in defaults < user-global < repo-level committed < per-repo
# personal override). The loader is shipyard-config.sh (covered by
# shipyard-config.test.sh). This test guards the *spec* surface — if
# anyone deletes the command files, removes a documented subcommand,
# strips the schema-reference docs, or backs out the opt-in gate in
# do-work.md, this test fails.
#
# The schemas at plugins/shipyard/schemas/*.json are also exercised here
# (shape + required-keys), since the loader's test suite covers
# semantics, but it doesn't pin the schemas themselves against drift.
#
# Pure bash, no external dependencies beyond jq for the schema reads
# (already required across shipyard). Run with:
#
#   bash plugins/shipyard/scripts/tests/shipyard-init-config.test.sh

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

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected %s to contain: %s\n' "$path" "$needle"
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

assert_jq() {
  local file="$1"
  local jq_expr="$2"
  local expected="$3"
  local label="$4"
  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$file"
    fail=$((fail+1))
    return
  fi
  local actual
  actual=$(jq -r "$jq_expr" "$file" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    jq expr: %s\n' "$jq_expr"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

# --------------------------------------------------------------------------
echo "== /shipyard:init command file"

init_md="$repo_root/plugins/shipyard/commands/init.md"
assert_file_exists "$init_md" "commands/init.md exists"
assert_file_contains "$init_md" '/shipyard:init' "init.md self-references the slash command"
assert_file_contains "$init_md" 'shipyard.config.json' "init.md mentions the committed config file"
assert_file_contains "$init_md" '.gitignore' "init.md mentions the .gitignore append"
assert_file_contains "$init_md" '.shipyard/' "init.md mentions the gitignored .shipyard/ directory"
assert_file_contains "$init_md" '--auto-merge' "init.md documents --auto-merge flag"
assert_file_contains "$init_md" '--trust' "init.md documents --trust flag"
assert_file_contains "$init_md" '--force' "init.md documents --force flag"
assert_file_contains "$init_md" '--dry-run' "init.md documents --dry-run flag"
assert_file_contains "$init_md" 'shipyard-config.sh' "init.md routes through shipyard-config.sh"

# --------------------------------------------------------------------------
# Issue #714 — /shipyard:init offers to pre-authorize the worktree-reap
# commands in .claude/settings.json (opt-in, default off).
#
# These assertions pin the load-bearing properties of that offer:
#   - the flags exist and are documented,
#   - the exact allow rules are named (a typo'd rule is a silent no-op),
#   - the default is OFF (an allow rule is a permission-surface change, so it
#     must never be written without explicit consent),
#   - the two caveats that make the rules honest are documented: the
#     `.claude/worktrees` protected-path carve-out (the reason the rule works
#     at all) and the script-internal-commands-aren't-gated nuance.
echo "== /shipyard:init worktree-reap allowlist offer (#714)"

assert_file_contains "$init_md" '--reap-allowlist' "init.md documents --reap-allowlist flag"
assert_file_contains "$init_md" '--reap-allowlist-scope' "init.md documents --reap-allowlist-scope flag"
# Needles are matched with `grep -qF` (fixed string) — write them literally,
# with no regex metacharacters and no backslash escapes.
assert_file_contains "$init_md" 'Bash(git worktree remove:*)' "init.md names the worktree-remove allow rule"
assert_file_contains "$init_md" 'Bash(git worktree prune:*)' "init.md names the worktree-prune allow rule"
assert_file_contains "$init_md" 'Bash(git worktree unlock:*)' "init.md names the worktree-unlock allow rule"
assert_file_contains "$init_md" 'permissions.allow' "init.md targets the permissions.allow block"
assert_file_contains "$init_md" 'never write the allow rules without explicit consent' "init.md requires explicit consent before widening the permission surface"
assert_file_contains "$init_md" '.claude/worktrees' "init.md documents the .claude/worktrees protected-path carve-out"

# The deny block is a hard-bypass guard (--no-verify et al). The reap-allowlist
# install path must never touch it — only ever append to `allow`.
assert_file_contains "$init_md" 'permissions.deny' "init.md forbids the install path from touching permissions.deny"

# --------------------------------------------------------------------------
echo "== /shipyard:config command file"

config_md="$repo_root/plugins/shipyard/commands/config.md"
assert_file_exists "$config_md" "commands/config.md exists"
assert_file_contains "$config_md" '/shipyard:config' "config.md self-references the slash command"
assert_file_contains "$config_md" '/shipyard:config show' "config.md documents show"
assert_file_contains "$config_md" '/shipyard:config get' "config.md documents get"
assert_file_contains "$config_md" '/shipyard:config set' "config.md documents set"
assert_file_contains "$config_md" '/shipyard:config edit' "config.md documents edit"
assert_file_contains "$config_md" '/shipyard:config validate' "config.md documents validate"
assert_file_contains "$config_md" '--repo' "config.md documents --repo target"
assert_file_contains "$config_md" '--local' "config.md documents --local target"
assert_file_contains "$config_md" '--global' "config.md documents --global target"
assert_file_contains "$config_md" 'shipyard-config.sh' "config.md routes through shipyard-config.sh"

# --------------------------------------------------------------------------
echo "== Schemas"

repo_schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
user_schema="$repo_root/plugins/shipyard/schemas/shipyard.user-config.schema.json"

assert_file_exists "$repo_schema" "schemas/shipyard.config.schema.json exists"
assert_file_exists "$user_schema" "schemas/shipyard.user-config.schema.json exists"

# Repo schema shape
assert_jq "$repo_schema" '.title' "Shipyard repo config" "repo schema has title"
assert_jq "$repo_schema" '.type'  "object"               "repo schema is an object"
assert_jq "$repo_schema" '.required | contains(["version"])' "true" "repo schema requires version"
assert_jq "$repo_schema" '.properties.auto_merge.properties.policy.enum | sort | join(",")' "always,never,trusted-only" "repo schema auto_merge.policy enum"
assert_jq "$repo_schema" '.properties.labels.properties.session_stamp.type' "string" "repo schema labels.session_stamp is string"
assert_jq "$repo_schema" '.properties.trust.properties.authors.type'        "array"  "repo schema trust.authors is array"
assert_jq "$repo_schema" '.properties.models.properties.issue_work.type'    "string" "repo schema models.issue_work is string"
assert_jq "$repo_schema" '.properties.cost_tracking.properties.enabled.type' "boolean" "repo schema cost_tracking.enabled is boolean"

# User schema shape
assert_jq "$user_schema" '.title' "Shipyard user-global config" "user schema has title"
assert_jq "$user_schema" '.required | contains(["version"])' "true" "user schema requires version"
assert_jq "$user_schema" '.properties.default_auto_merge_policy.enum | sort | join(",")' "always,never,trusted-only" "user schema default_auto_merge_policy enum"
assert_jq "$user_schema" '.properties.default_models.properties.issue_work.type' "string" "user schema default_models.issue_work is string"
# Inert keys removed in issue #403 (currency, pricing_override,
# exclude_repos_from_cost_tracking) — none were ever consumed.
assert_jq "$user_schema" '.properties | has("pricing_override")' "false" "user schema no longer declares pricing_override (#403)"
assert_jq "$user_schema" '.properties | has("currency")' "false" "user schema no longer declares currency (#403)"
assert_jq "$user_schema" '.properties | has("exclude_repos_from_cost_tracking")' "false" "user schema no longer declares exclude_repos_from_cost_tracking (#403)"

# --------------------------------------------------------------------------
echo "== Repo's own shipyard.config.json"

repo_config="$repo_root/shipyard.config.json"
assert_file_exists "$repo_config" "<repo-root>/shipyard.config.json exists (this repo is shipyard-initialized)"
assert_jq "$repo_config" '.version'       "1"                   "repo config: version is 1"
assert_jq "$repo_config" '.repo.owner'    "mattsears18"          "repo config: owner is mattsears18"
assert_jq "$repo_config" '.repo.name'     "shipyard"             "repo config: name is shipyard"
assert_jq "$repo_config" '.auto_merge.policy' "trusted-only"     "repo config: auto_merge.policy is trusted-only"
assert_jq "$repo_config" '.trust.authors | contains(["mattsears18"])' "true" "repo config: trust.authors includes mattsears18"
# The labels block must match the canonical blocked:* namespace.
# Per #300 the single blocked:agent label split into blocked:agent-hard /
# blocked:agent-soft (with the bare blocked:agent kept as a legacy alias
# for migration); the labels block carries all three.
assert_jq "$repo_config" '.labels.session_stamp' "shipyard"            "repo config: labels.session_stamp"
assert_jq "$repo_config" '.labels.blocked'       "blocked:agent"       "repo config: labels.blocked is blocked:agent (legacy alias kept for migration)"
assert_jq "$repo_config" '.labels.blocked_hard'  "blocked:agent-hard"  "repo config: labels.blocked_hard is blocked:agent-hard (#300)"
assert_jq "$repo_config" '.labels.blocked_soft'  "blocked:agent-soft"  "repo config: labels.blocked_soft is blocked:agent-soft (#300)"
assert_jq "$repo_config" '.labels.ci_blocked'    "blocked:ci"          "repo config: labels.ci_blocked is blocked:ci"
assert_jq "$repo_config" '.blocked_agent.soft_retry_minutes' "30"      "repo config: blocked_agent.soft_retry_minutes default 30 (#300)"

# --------------------------------------------------------------------------
echo "== do-work setup phase opt-in gate (step 0.4)"

# After the issue #154 split, setup-phase content lives in
# commands/do-work/setup.md rather than the entry. The opt-in gate (step 0.4)
# is a setup-phase step. Since #611 split setup.md into a thin router +
# step-cluster sub-files, step 0.4 lives in setup/00-config-worktree.md.
do_work_setup_md="$repo_root/plugins/shipyard/commands/do-work/setup/00-config-worktree.md"
assert_file_contains "$do_work_setup_md" '0.4 Check the repo-level opt-in' "do-work/setup.md contains step 0.4"
assert_file_contains "$do_work_setup_md" 'shipyard-config.sh' "do-work/setup.md references shipyard-config.sh"
assert_file_contains "$do_work_setup_md" 'shipyard.config.json' "do-work/setup.md references the committed config file"
assert_file_contains "$do_work_setup_md" '/shipyard:init' "do-work/setup.md points users at /shipyard:init"

# --------------------------------------------------------------------------
echo "== CLAUDE.md documents the layers"

claude_md="$repo_root/CLAUDE.md"
assert_file_contains "$claude_md" 'shipyard.config.json' "CLAUDE.md mentions shipyard.config.json"
assert_file_contains "$claude_md" 'config.local.json'    "CLAUDE.md mentions the personal override file"
assert_file_contains "$claude_md" '4-layer'               "CLAUDE.md describes the layer count"
assert_file_contains "$claude_md" '/shipyard:init'        "CLAUDE.md references /shipyard:init"
assert_file_contains "$claude_md" '/shipyard:config'      "CLAUDE.md references /shipyard:config"

# --------------------------------------------------------------------------
echo "== Plugin version bump"

plugin_json="$repo_root/plugins/shipyard/.claude-plugin/plugin.json"
# Version must be at least 1.3.31 — the floor where the shipyard.config.json
# loader plus /shipyard:init / /shipyard:config landed. This is the stable
# invariant that the feature shipped: the CHANGELOG entry that originally
# recorded it (### 1.3.31, #165) rotates out as the CHANGELOG ages, so we
# do NOT assert its continued presence (issue #388). The feature's actual
# surface — the command files, schemas, repo config, and do-work opt-in gate
# asserted above — is what guards against the feature being backed out.
current_version=$(jq -r '.version' "$plugin_json" 2>/dev/null)
if [[ -n "$current_version" ]]; then
  # Strip semver pre-release / build suffix if any, split into integers.
  IFS='.' read -r v_major v_minor v_patch <<< "${current_version%%[-+]*}"
  if [[ "$v_major" =~ ^[0-9]+$ ]] && [[ "$v_minor" =~ ^[0-9]+$ ]] && [[ "$v_patch" =~ ^[0-9]+$ ]] \
       && (( v_major > 1 \
             || (v_major == 1 && v_minor > 3) \
             || (v_major == 1 && v_minor == 3 && v_patch >= 31) )); then
    printf '  %sPASS%s  plugin.json at or past 1.3.31 (actual: %s)\n' \
      "$GREEN" "$RESET" "$current_version"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  plugin.json at or past 1.3.31 (actual: %s)\n' \
      "$RED" "$RESET" "$current_version"
    fail=$((fail+1))
  fi
else
  printf '  %sFAIL%s  plugin.json at or past 1.3.31 — .version missing\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

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
