#!/usr/bin/env bash
# shipyard-config.sh — layered config resolver for `/shipyard:*` commands.
#
# Background (issue #165): every `/shipyard:*` command used to infer its
# behavior from convention and runtime probing — repo identity from
# `gh repo view` context, auto-merge gating from a hardcoded
# `originating_author_trust` switch, trusted-authors from a single global
# list, no place to put the model / cache / inline-trivial knobs that
# downstream issues need. This helper introduces a 4-layer config model
# (last-wins deep merge):
#
#   1. Built-in defaults              — hardcoded in this script
#   2. ~/.shipyard/config.json        — user-global; pricing, default models
#   3. <repo>/shipyard.config.json    — committed; repo-level shared policy
#   4. <repo>/.shipyard/config.local.json — gitignored; personal override
#
# Effective config = deep-merge in that order. The repo-level file is the
# *opt-in surface* — `/shipyard:do-work` warns when it's missing and asks
# the user to run `/shipyard:init` (the issue's risk-mitigation explicitly
# defers the hard refusal gate until `/shipyard:init` is widely available;
# we ship warn-only by default and a `--strict` opt-in for early adopters).
#
# Subcommands:
#
#   load     — emit the effective merged config on stdout. Layers loaded in
#              the order above; each is validated against its schema before
#              merging. Exits 0 on success even if the repo-level layer is
#              missing (built-in defaults are always present). Use `--strict`
#              to require the repo-level layer.
#
#   show     — pretty-print the effective config with each field's source
#              layer annotated. `--layer <name>` prints just one layer.
#              `--source` (default) annotates source; `--plain` emits raw
#              JSON without annotations.
#
#   get      — print one field's value (dot-path: `auto_merge.policy`).
#              `--with-source` adds a trailing tab + the source layer.
#
#   set      — write a field to a target layer. `--repo` (default; writes
#              <repo>/shipyard.config.json), `--local` (writes
#              <repo>/.shipyard/config.local.json), `--global` (writes
#              ~/.shipyard/config.json). Uses atomic-write (mirrors
#              session-state.sh). Creates the file if missing — `--repo`
#              and `--global` get the `version: 1` sentinel; `--local` is
#              sparse.
#
#   validate — run schema validation against a specific layer or all of
#              them. `--layer <name>` to scope; otherwise validates the three
#              file layers that exist (built-in defaults are constructed
#              in-script and don't need re-validation).
#
#   exists   — exit 0 if the repo-level layer exists at <repo>/shipyard.config.json,
#              exit 1 otherwise. Used by `/shipyard:do-work`'s opt-in gate.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory for user-global config + sessions.
#                   Defaults to $HOME/.shipyard. Same env var used by
#                   session-state.sh.
#   SHIPYARD_REPO_ROOT — override the repo root resolution. Defaults to
#                       `git rev-parse --show-toplevel` from cwd. Used by
#                       the test suite to point at a tmpdir.
#   SHIPYARD_CONFIG_FAILURE_MARKER — override the path of the session-local
#                       schema-failure record (issue #1388). Defaults to
#                       `$PWD/.shipyard-config-schema-failure`, and only when
#                       `$PWD/.shipyard-plugin-root` exists (the orchestrator
#                       worktree's own signature). Used by the test suite.
#   SHIPYARD_CONFIG_BEHIND_WARN — set to 0 to silence `get`'s stderr warning
#                       when the resolved repo root's HEAD lacks upstream
#                       commits touching shipyard.config.json (issue #1610).
#
# Exit codes:
#
#   0   — success
#   1   — exists subcommand: repo-level layer not present
#   3   — `get` path miss (field not present in effective config)
#   64  — usage error
#   65+ — internal helper failure (jq missing, write failure, etc.)
#   70  — schema validation failed

set -u

# --------------------------------------------------------------------------
# Shared helpers (require_jq, atomic_write) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# --------------------------------------------------------------------------
# Dependency check — jq is required for merge, projection, and validation
# (we implement a small Draft-07 subset in-script, no external validator).
# --------------------------------------------------------------------------
require_jq

usage() {
  cat <<'EOF' >&2
Usage:
  shipyard-config.sh load     [--strict]
  shipyard-config.sh show     [--layer defaults|user|repo|local] [--plain]
  shipyard-config.sh get      <dot.path> [--with-source]
  shipyard-config.sh set      <dot.path> <value> [--repo|--local|--global]
  shipyard-config.sh validate [--layer defaults|user|repo|local|all]
  shipyard-config.sh exists

Environment:
  SHIPYARD_HOME       base dir for user-global config (default: $HOME/.shipyard)
  SHIPYARD_REPO_ROOT  override the repo-root resolution (default: git toplevel of cwd)
  SHIPYARD_CONFIG_FAILURE_MARKER
                      override the session-local schema-failure record path
                      (default: $PWD/.shipyard-config-schema-failure, written
                      only inside the orchestrator worktree)
  SHIPYARD_CONFIG_BEHIND_WARN
                      0 silences get's [config-behind] stderr warning (#1610)

Exit codes:
  0    success
  1    exists: repo-level layer missing
  3    get: dot-path not found in effective config
  64   usage error
  65+  internal helper failure
  70   schema validation failed
EOF
}

# --------------------------------------------------------------------------
# Built-in defaults — the bottom layer. Every downstream consumer that does
# `shipyard-config.sh get foo.bar` should see at least the default value,
# even on a brand-new repo with no config files anywhere.
#
# Conventions captured here mirror what shipyard's spec / hardcoded logic
# currently does. Changes to defaults are visible because every consumer
# reads via this helper.
# --------------------------------------------------------------------------
DEFAULTS_JQ='{
  "version": 1,
  "auto_merge": {
    "policy": "trusted-only",
    "method": "squash"
  },
  "trust": {
    "authors": []
  },
  "backlog": {
    "respect_assignees": false,
    "self_assign": false,
    "someday_milestone": "",
    "someday_recheck_days": 30
  },
  "labels": {
    "session_stamp": "shipyard",
    "blocked_soft": "blocked:agent-soft",
    "ci_blocked": "blocked:ci",
    "needs_human_review": "needs-human-review",
    "user_feedback": "user-feedback"
  },
  "blocked_agent": {
    "soft_retry_minutes": 30
  },
  "inline_trivial": {
    "enabled": false,
    "max_body_chars": 200,
    "patterns": ["typo", "dep-bump", "doc-only", "comment-only", "config-tweak"]
  },
  "verify_gate": {
    "enabled": false
  },
  "models": {
    "issue_work": "claude-opus-5",
    "fix_checks_only": "claude-opus-5",
    "fix_rebase": "claude-opus-5",
    "fix_main_ci": "claude-opus-5",
    "fix_failing_prs_batch": "claude-opus-5",
    "investigate": "claude-opus-5",
    "verify": "claude-opus-5"
  },
  "triage": {
    "auto_close": "confident-only",
    "max_investigations_per_session": null
  },
  "cost_tracking": {
    "enabled": true,
    "comment_on_pr": true
  },
  "concurrency": {
    "default": 1,
    "soft_collision": 3,
    "soft_collision_paths": []
  },
  "main_ci": {
    "aggregation_mode": "branch-protection",
    "required_workflows": [],
    "max_fix_attempts": 3
  },
  "merge_gate": {
    "command": "",
    "serialize": false,
    "max_unmerged_ahead": 2,
    "clear_state_command": ""
  },
  "version_coordination": {
    "enabled": false,
    "manifest_path": "",
    "manifest_version_jq": ".version",
    "changelog_path": "",
    "serialize_drain_rebase": true,
    "append_only_paths": [],
    "generated_paths": []
  },
  "ci": {
    "skip_drain_rebase": false,
    "max_drain_rebases": null,
    "verify_check_failing_on_head_before_dispatch": false,
    "skip_speculative_rerun": true,
    "require_in_progress_check_to_settle": false,
    "settled_minutes": 20,
    "max_drain_hours": 8,
    "backpressure_multiplier": 5,
    "backpressure_min_in_flight": 1,
    "prefer_cheap_under_backpressure": true
  },
  "awaiting_external": {
    "enabled": true,
    "max_hours": 2
  },
  "paused_on_environment": {
    "enabled": true,
    "max_hours": 4,
    "poll_interval_seconds": 300,
    "pause_when_in_flight_at_or_below": 0
  },
  "flake_registry": {
    "enabled": false,
    "window_days": 7,
    "rerun_threshold": 3,
    "distinct_prs_threshold": 2,
    "actions": ["file-tracking-issue", "stop-auto-rerunning", "apply-blocked-ci"],
    "prune_window_days": 90
  },
  "operator_denial_registry": {
    "enabled": false,
    "prune_window_days": 180
  },
  "scope": {
    "inline_incidental_fixes": true,
    "diagnosis_reuse_hours": 72,
    "self_modification_paths": [".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/hooks/"],
    "orchestrator_only_skills": ["shipyard:update-roadmap", "update-roadmap"],
    "external_dependency_recheck_days": 14,
    "recheck_probe_enabled": true,
    "recheck_probe_timeout_seconds": 15,
    "recheck_probe_url_hosts": [],
    "recheck_probe_max_bytes": 1048576
  },
  "decompose": {
    "auto": true,
    "max_subissues": 8
  },
  "dependencies": {
    "new_dep_version": "latest-stable"
  },
  "worktree_reap": {
    "max_per_session": 10,
    "warn_threshold": 20,
    "disk_free_floor_mb": 10240
  },
  "my_turn": {
    "stale_undispatched_days": 7,
    "max_diagnostic_reads_per_item": 1,
    "disposition_call_detection": true,
    "assume_operator_enabled": true
  },
  "milestones": {
    "enabled": false,
    "fallback": "Ongoing maintenance",
    "assign_on_file": true,
    "prioritize_dispatch": true,
    "sweep_on_loop_end": true
  }
}'

# --------------------------------------------------------------------------
# Path resolution
# --------------------------------------------------------------------------
shipyard_home() {
  printf '%s\n' "${SHIPYARD_HOME:-${HOME}/.shipyard}"
}

user_config_path() {
  printf '%s/config.json\n' "$(shipyard_home)"
}

repo_root() {
  if [[ -n "${SHIPYARD_REPO_ROOT:-}" ]]; then
    printf '%s\n' "$SHIPYARD_REPO_ROOT"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null
}

repo_config_path() {
  local root
  root=$(repo_root)
  if [[ -z "$root" ]]; then
    return 1
  fi
  printf '%s/shipyard.config.json\n' "$root"
}

local_config_path() {
  local root
  root=$(repo_root)
  if [[ -z "$root" ]]; then
    return 1
  fi
  printf '%s/.shipyard/config.local.json\n' "$root"
}

# --------------------------------------------------------------------------
# Behind-upstream warning for the committed repo layer (issue #1610).
#
# The repo layer is read from a WORKING TREE, so a checkout that has not
# pulled the commit declaring a key returns the pre-declaration value with
# total confidence. For declarative opt-in keys (version_coordination.
# generated_paths, append_only_paths, ...) an empty value means "not opted
# in", so a stale read is indistinguishable from a genuine "not declared" —
# the #1610 repro discarded a correct fix-rebase on exactly that.
#
# The predicate is commit-based, not content-based: "does origin/<default>
# carry a commit touching shipyard.config.json that HEAD lacks?" That
# ignores a checkout's own deliberate local edits (a PR branch changing the
# config is not stale) and needs no JSON parsing, so it is cheap enough to
# run on every `get`. detect-config-staleness.sh (#1493) is the heavier,
# key-naming drift check the orchestrator runs per refresh tick; this is
# the read-time signal every consumer gets for free.
#
# Advisory only: stderr, never a change to stdout or the exit status.
# Fail-silent on anything it cannot resolve (not a git tree, no origin
# default ref) — it must never produce a false positive. Opt out with
# SHIPYARD_CONFIG_BEHIND_WARN=0.
# --------------------------------------------------------------------------
default_upstream_ref() {
  local root="$1" ref
  ref=$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$ref" ]] && git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$ref"
    return 0
  fi
  for ref in origin/main origin/master; do
    if git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

warn_if_repo_layer_behind() {
  [[ "${SHIPYARD_CONFIG_BEHIND_WARN:-1}" == "0" ]] && return 0
  local root ref behind
  root=$(repo_root) || return 0
  [[ -n "$root" && -d "$root" ]] || return 0
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  ref=$(default_upstream_ref "$root") || return 0
  behind=$(git -C "$root" rev-list --count "HEAD..$ref" -- shipyard.config.json 2>/dev/null) || return 0
  [[ "$behind" =~ ^[0-9]+$ ]] || return 0
  if (( behind > 0 )); then
    echo "shipyard-config: WARNING [config-behind]: $root is behind $ref on shipyard.config.json ($behind upstream commit(s) touching it that this checkout's HEAD lacks). Values read here are this checkout's, not the repo's agreed state — an empty/absent opt-in key may be declared upstream. Read from an up-to-date worktree or 'git show $ref:shipyard.config.json' before treating such a value as authoritative. (#1610)" >&2
  fi
  return 0
}

# atomic_write() (same-fs tmp + rename; POSIX-atomic) now lives in
# lib/common.sh (issue #887) — this was a byte-for-byte functional copy of
# session-state.sh's implementation, minus the 0-byte guard the shared
# version adds. shipyard-config.test.sh's issue-#871 regression test pins
# the 66/67 return-code contract this preserves.

# --------------------------------------------------------------------------
# Schema validation — minimal Draft-07 subset implemented in jq. We don't
# bring in a full validator (ajv, jsonschema CLI) because shipyard's
# dependency surface is intentionally small — jq is already required.
#
# Checks performed:
#   - required fields present
#   - type matches declared `type`
#   - enum values match declared `enum`
#   - pattern matches declared `pattern` (when the field is a string)
#   - additionalProperties == false → unknown keys flagged
#   - integer minimum / maximum
#   - secret-name forbidden-surface check (any key matching
#     /token|secret|api_key|password|credential/i is rejected regardless
#     of schema — this is the issue body's secret-leak mitigation)
#
# Things NOT checked (out of scope — file follow-up if a future schema
# needs them): $ref resolution, allOf/oneOf/anyOf composition, format
# constraints beyond pattern.
# --------------------------------------------------------------------------
validate_no_secret_keys() {
  # Reject committed config / overrides that carry anything that looks
  # like a credential. The defense is structural — the schema also blocks
  # via additionalProperties, but the secret-name check is a second layer
  # that catches typos (api-key, accesToken, etc.) the schema's strict
  # property list might miss in a future-expanded version.
  local file="$1"
  local hits
  hits=$(jq -r '
    paths(scalars) as $p
    | $p | join(".")
    | select(test("token|secret|api[_-]?key|password|credential"; "i"))
  ' "$file" 2>/dev/null)
  if [[ -n "$hits" ]]; then
    echo "shipyard-config.sh: secret-like field(s) found in $file:" >&2
    # Indent each line with two spaces. Multi-line var; the parameter
    # expansion substitutes once per newline.
    printf '  %s\n' "${hits//$'\n'/$'\n  '}" >&2
    echo "  shipyard config must not carry credentials. Move these to env vars." >&2
    return 70
  fi
  return 0
}

# Validate a JSON file against a schema. Returns 0 on success, 70 on failure.
# Implementation is intentionally minimal — see the function docstring above
# for what's covered. Caller is expected to have already done jq syntax
# validation by reading the file with `jq .` (file-malformedness exits 4).
validate_against_schema() {
  local file="$1"
  local schema="$2"

  if [[ ! -f "$file" ]]; then
    # Missing file is not a validation failure — caller decides whether
    # the layer is required (e.g. `load --strict`).
    return 0
  fi

  if [[ ! -f "$schema" ]]; then
    echo "shipyard-config.sh: schema not found: $schema" >&2
    return 65
  fi

  # Parseability gate. If jq can't read the file, surface the line/column
  # info jq emits and bail before doing semantic checks.
  if ! jq empty "$file" 2>/dev/null; then
    echo "shipyard-config.sh: $file is not valid JSON" >&2
    jq empty "$file" 2>&1 | sed 's/^/  /' >&2
    return 70
  fi

  # Secret-name gate (additive).
  if ! validate_no_secret_keys "$file"; then
    return 70
  fi

  # Schema-driven checks. The jq program below walks the schema and the
  # data in lockstep and emits a list of error strings; a non-empty list
  # is a failure. We keep the jq program in a separate heredoc-style
  # variable so jq-syntax comments (which use `#`) and apostrophes inside
  # them don't conflict with bash's single-quoted command-line.
  local errors
  local jq_validate_program
  jq_validate_program=$(cat <<'JQEOF'
def check_type($val; $expected; $path):
    if $expected == "integer" then
      if ($val | type) == "number" and ($val == ($val | floor)) then empty
      else ($path + ": expected integer, got " + ($val | type)) end
    elif $expected == "number" then
      if ($val | type) == "number" then empty
      else ($path + ": expected number, got " + ($val | type)) end
    elif ($val | type) == $expected then empty
    else ($path + ": expected " + $expected + ", got " + ($val | type)) end ;

# Multi-type support (issue #323): JSON Schema allows `"type": ["integer", "null"]`
# to declare a nullable value. The single-string check above doesn't handle
# arrays — this wrapper accepts either form and returns empty when any of the
# allowed types match.
def check_type_multi($val; $expected; $path):
    if ($expected | type) == "array"
      then
        # Try each allowed type; collect errors; if ANY succeeded (errors
        # list is shorter than expected list), the value is valid.
        ([ $expected[] | . as $t | [ check_type($val; $t; $path) ] ]) as $per_type
        | if ($per_type | map(length == 0) | any) then empty
          else ($path + ": expected one of " + ($expected | tostring) + ", got " + ($val | type)) end
      else check_type($val; $expected; $path) end ;

def walk($schema_node; $data_node; $path):
    (
      if $schema_node.type and $data_node != null
        then check_type_multi($data_node; $schema_node.type; $path)
        else empty end
    ),
    (
      if $schema_node.enum and $data_node != null
        then (
          if ($schema_node.enum | index($data_node)) then empty
          else ($path + ": value " + ($data_node | tostring) + " not in enum " + ($schema_node.enum | tostring)) end )
        else empty end
    ),
    (
      if $schema_node.pattern and ($data_node | type) == "string"
        then (
          if ($data_node | test($schema_node.pattern)) then empty
          else ($path + ": value " + $data_node + " does not match pattern " + $schema_node.pattern) end )
        else empty end
    ),
    (
      if $schema_node.minimum != null and ($data_node | type) == "number"
        then (
          if $data_node >= $schema_node.minimum then empty
          else ($path + ": " + ($data_node | tostring) + " < minimum " + ($schema_node.minimum | tostring)) end )
        else empty end
    ),
    (
      if $schema_node.required and ($data_node | type) == "object"
        then (
          $schema_node.required[] | . as $req
          | if $data_node | has($req) then empty
            else ($path + ": missing required field " + $req) end )
        else empty end
    ),
    (
      if $schema_node.additionalProperties == false and ($data_node | type) == "object"
        then (
          ($data_node | keys)[] | . as $k
          | if ($schema_node.properties // {}) | has($k) then empty
            else ($path + ": unknown field " + $k) end )
        else empty end
    ),
    (
      if ($schema_node.properties // null) != null and ($data_node | type) == "object"
        then (
          $schema_node.properties | keys[] | . as $k
          | if $data_node | has($k)
            then walk($schema_node.properties[$k]; $data_node[$k]; $path + "." + $k)
            else empty end )
        else empty end
    ),
    (
      if ($schema_node.items // null) != null and ($data_node | type) == "array"
        then (
          $data_node | to_entries[]
          | walk($schema_node.items; .value; $path + "[" + (.key | tostring) + "]") )
        else empty end ) ;

. as $data
| $schema[0] as $s
| [ walk($s; $data; "") ] | unique | .[]
JQEOF
)
  errors=$(jq -r --slurpfile schema "$schema" "$jq_validate_program" "$file" 2>&1)

  if [[ -n "$errors" ]]; then
    echo "shipyard-config.sh: schema validation failed for $file:" >&2
    printf '  %s\n' "${errors//$'\n'/$'\n  '}" >&2
    return 70
  fi
  return 0
}

# --------------------------------------------------------------------------
# Resolve schema path. The schemas live next to this script under
# ../schemas/. Resolving relative to the script's own directory means the
# helper works the same whether invoked from the test suite (which copies
# the script to a tmpdir) or from the plugin install path.
# --------------------------------------------------------------------------
script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

repo_schema_path() {
  printf '%s/../schemas/shipyard.config.schema.json\n' "$(script_dir)"
}

user_schema_path() {
  printf '%s/../schemas/shipyard.user-config.schema.json\n' "$(script_dir)"
}

# --------------------------------------------------------------------------
# Session-local schema-failure record (issue #1388).
#
# A layer that fails schema validation makes `load` — and therefore `get` —
# exit 70 with empty stdout. That is loud at the one call site that checks
# (`/do-work` setup step 0.4, which records SHIPYARD_CONFIG_SCHEMA_FAILURE
# and prints a warning), but EVERY other consumer is deliberately fail-open:
# `resolve-dispatch-model.sh`, `flake-enforce.sh`, and the worker specs all
# wrap their reads as `... 2>/dev/null || echo <default>`, so the degrade is
# indistinguishable from "this repo sets no override for that key".
#
# The fail-open behavior is correct and is NOT changed here — a config
# problem must never fail a dispatch. What is added is a *record*: the
# failure is appended to a session-local marker file that
# `commands/do-work/cleanup-summary.md`'s end-of-session summary surfaces,
# so a fail-open read is never COMPLETELY silent even when step 0.4's `load`
# was not the call that hit it.
#
# Where the marker lives, and why:
#
#   - `$SHIPYARD_CONFIG_FAILURE_MARKER` when set (explicit override; tests).
#   - otherwise `$PWD/.shipyard-config-schema-failure`, and ONLY when
#     `$PWD/.shipyard-plugin-root` exists.
#
# `.shipyard-plugin-root` is step 0.5's stash and exists only in the
# orchestrator's own worktree, which is created per session and reaped at
# session end — so gating on it gives (a) session-scoped lifetime for free,
# with no clearing step and no cross-session bleed, and (b) a guarantee that
# a dispatched worker's `get` call can never drop an untracked file into
# the worktree whose diff becomes a PR. Orchestrator-side reads are the ones
# the record is for anyway (resolve-dispatch-model.sh and flake-enforce.sh
# both run there), and a worker reading the same broken config hits the same
# failure the orchestrator already recorded.
#
# Recording is best-effort and never affects the caller's exit status.
# --------------------------------------------------------------------------
config_failure_marker_path() {
  if [[ -n "${SHIPYARD_CONFIG_FAILURE_MARKER:-}" ]]; then
    printf '%s\n' "$SHIPYARD_CONFIG_FAILURE_MARKER"
    return 0
  fi
  if [[ -f "$PWD/.shipyard-plugin-root" ]]; then
    printf '%s\n' "$PWD/.shipyard-config-schema-failure"
    return 0
  fi
  return 1
}

# record_schema_failure <config-file> <validator-stderr>
#
# Appends one TSV row: <ISO8601-UTC>\t<config file>\t<rejected fields>.
# The rejected-fields field mirrors step 0.4's REJECTED_FIELDS shape (the
# validator's per-field indented stderr lines, `; `-joined) so the summary
# renders the two sources identically.
record_schema_failure() {
  local file="$1"
  local detail="$2"
  local marker fields
  marker=$(config_failure_marker_path) || return 0

  # POSIX [[:space:]] (not \s) so the grep matches on BSD grep too; awk for
  # the join (NOT `paste -d '; '` — paste's -d is a cycled list of
  # single-char delimiters, so '; ' would alternate ';' then ' ').
  fields=$(printf '%s\n' "$detail" \
    | grep -E '^[[:space:]]+\.' \
    | sed 's/^[[:space:]]*//' \
    | awk 'NR>1{printf "; "} {printf "%s", $0} END{if (NR>0) print ""}')
  if [[ -z "$fields" ]]; then
    # Non-field-shaped failure (malformed JSON, secret-like key, missing
    # schema). Flatten the diagnostic onto one line so the TSV row holds.
    fields=$(printf '%s' "$detail" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ *$//')
  fi
  [[ -z "$fields" ]] && fields="(no detail)"

  # Dedupe on (file, fields): a fail-open `get` runs on nearly every
  # orchestrator turn, so an unbounded append would grow to hundreds of
  # identical rows in one session and bury the signal it exists to carry.
  local key
  key=$(printf '\t%s\t%s' "$file" "$fields")
  if [[ -f "$marker" ]] && grep -Fq -- "$key" "$marker" 2>/dev/null; then
    return 0
  fi
  printf '%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" >> "$marker" 2>/dev/null || true
  return 0
}

# --------------------------------------------------------------------------
# Layer loading
#
# Each function reads its layer's file (or an empty object when missing) and
# emits JSON on stdout. The caller composes the deep-merge.
# --------------------------------------------------------------------------
load_defaults() {
  jq -n "$DEFAULTS_JQ"
}

load_user() {
  local path
  path=$(user_config_path)
  if [[ ! -f "$path" ]]; then
    printf '{}\n'
    return 0
  fi
  local verr
  # Capture (rather than pass through) the validator's diagnostic so the
  # same text can be re-emitted on stderr AND recorded for the end-of-session
  # summary (#1388). Behavior on stderr is byte-identical to the pre-#1388
  # pass-through.
  if ! verr=$(validate_against_schema "$path" "$(user_schema_path)" 2>&1); then
    [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
    record_schema_failure "$path" "$verr"
    return 70
  fi
  [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
  cat "$path"
}

# --------------------------------------------------------------------------
# User-layer key remapping (issue #403).
#
# The user-global schema historically declared convenience aliases under
# their own top-level names (default_auto_merge_policy, default_models,
# cost_tracking_enabled) instead of the canonical paths every consumer
# reads (auto_merge.policy, models.*, cost_tracking.enabled). Because the
# merge is a flat last-wins union with no key remapping, a user who set
# `default_auto_merge_policy: never` got a clean validate pass and zero
# effect — the alias landed under its own name and nothing read it.
#
# This step translates the aliases into the canonical paths BEFORE the user
# layer feeds the deep-merge, so a user-global setting actually overrides the
# built-in default (with repo/local still winning per last-wins). The aliases
# are removed from the normalized object so they can never leak into the
# effective config under their inert names.
#
# As of #854, the user-global schema ALSO accepts the canonical `models`
# top-level key directly (alongside `default_models`) — `cmd_set` writes
# whatever dot-path the caller passed verbatim, and `set models.fix_rebase
# <id> --global` used to fail schema validation because only `default_models`
# was schema-legal at that layer, forcing the alias name on every --global
# write. The merge below already anticipated a coexisting `.models` (the
# `(.models // {})` fallback), it just needed the schema to let one land on
# disk — see `shipyard.user-config.schema.json`'s `models` property.
#
# Reads raw user JSON on stdin (or "{}"), emits the normalized object.
normalize_user_layer() {
  jq '
    # default_auto_merge_policy -> auto_merge.policy
    (if has("default_auto_merge_policy")
       then .auto_merge = ((.auto_merge // {}) + {policy: .default_auto_merge_policy})
       else . end)
    # default_models.<k> -> models.<k> (merge key-by-key; explicit models.* still wins)
    | (if has("default_models")
         then .models = (.default_models + (.models // {}))
         else . end)
    # cost_tracking_enabled -> cost_tracking.enabled
    | (if has("cost_tracking_enabled")
         then .cost_tracking = ((.cost_tracking // {}) + {enabled: .cost_tracking_enabled})
         else . end)
    # Drop the aliases so they never leak into the effective config inert.
    | del(.default_auto_merge_policy, .default_models, .cost_tracking_enabled)
  '
}

# Load the user layer normalized for merge consumption. This is what feeds
# the effective/merged config (cmd_load, cmd_show effective + source-map,
# cmd_get value + source). The raw load_user() is reserved for the
# `show --layer user` / `validate --layer user` paths, which must reflect
# the on-disk file verbatim.
load_user_merged() {
  local raw
  raw=$(load_user) || return $?
  printf '%s' "$raw" | normalize_user_layer
}

load_repo() {
  local path
  if ! path=$(repo_config_path); then
    printf '{}\n'
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    printf '{}\n'
    return 0
  fi
  local verr
  if ! verr=$(validate_against_schema "$path" "$(repo_schema_path)" 2>&1); then
    [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
    record_schema_failure "$path" "$verr"
    return 70
  fi
  [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
  cat "$path"
}

load_local() {
  local path
  if ! path=$(local_config_path); then
    printf '{}\n'
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    printf '{}\n'
    return 0
  fi
  local verr
  if ! verr=$(validate_against_schema "$path" "$(repo_schema_path)" 2>&1); then
    [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
    record_schema_failure "$path" "$verr"
    return 70
  fi
  [[ -n "$verr" ]] && printf '%s\n' "$verr" >&2
  cat "$path"
}

# --------------------------------------------------------------------------
# Deep merge — last wins. Objects merge key-by-key recursively; arrays and
# scalars are replaced (not concatenated). jq's `* operator` does this
# natively for two operands; we chain through all four layers.
#
# Note: arrays are *replaced* by design. Repo-level trust.authors should
# fully override user-global trust.authors, not append — surprise concat
# would make it impossible to remove a user-global trusted author at the
# repo level.
# --------------------------------------------------------------------------
deep_merge_layers() {
  local defaults="$1"
  local user="$2"
  local repo="$3"
  local local_="$4"
  jq -n \
    --argjson d "$defaults" \
    --argjson u "$user" \
    --argjson r "$repo" \
    --argjson l "$local_" \
    '$d * $u * $r * $l'
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------
cmd_load() {
  local strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict) strict=1; shift ;;
      *) echo "load: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ $strict -eq 1 ]]; then
    local rpath
    if ! rpath=$(repo_config_path) || [[ ! -f "$rpath" ]]; then
      echo "load --strict: repo-level shipyard.config.json not found" >&2
      echo "  run /shipyard:init to create it" >&2
      exit 1
    fi
  fi

  local d u r l
  d=$(load_defaults) || exit $?
  u=$(load_user_merged) || exit $?
  r=$(load_repo) || exit $?
  l=$(load_local) || exit $?
  deep_merge_layers "$d" "$u" "$r" "$l"
}

cmd_show() {
  local layer=""
  local plain=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --layer) layer="${2:-}"; shift 2 ;;
      --plain) plain=1; shift ;;
      *) echo "show: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -n "$layer" ]]; then
    case "$layer" in
      defaults) load_defaults ;;
      user)     load_user ;;
      repo)     load_repo ;;
      local)    load_local ;;
      *) echo "show: --layer must be one of defaults|user|repo|local" >&2; exit 64 ;;
    esac
    return
  fi

  # Effective config, with per-field source annotation. The implementation
  # is straightforward: load each layer separately and tag the keys it
  # provides; merge with last-wins; for each leaf in the effective config,
  # the latest non-empty source wins.
  local d u r l merged
  d=$(load_defaults) || exit $?
  # Use the normalized user layer so the source map attributes a remapped
  # canonical path (e.g. auto_merge.policy set via the user-global alias
  # default_auto_merge_policy) to the "user" layer, not "defaults" (#403).
  u=$(load_user_merged) || exit $?
  r=$(load_repo) || exit $?
  l=$(load_local) || exit $?
  merged=$(deep_merge_layers "$d" "$u" "$r" "$l")

  if [[ $plain -eq 1 ]]; then
    printf '%s\n' "$merged"
    return
  fi

  # Build a flat "key=source" projection for each layer at every leaf path.
  # Then for each leaf in `merged`, look up the latest layer that set it.
  #
  # Path-shape note (issue #214): `paths(scalars)` yields each path as a
  # mixed array of strings (object keys) and integers (array indices) —
  # e.g. `["trust","authors",0]`. We carry that mixed-type array as the
  # canonical form for `getpath` lookups, and only stringify it (via
  # `join(".")`) for the source-map output key. Round-tripping through
  # `join`+`split` would coerce the integer `0` back to the string `"0"`
  # and break `getpath` with `Cannot index array with string "0"`.
  printf '%s\n' "$merged" | jq --argjson d "$d" --argjson u "$u" --argjson r "$r" --argjson l "$l" '
    # Flatten an object into a list of leaf paths. `path` is the mixed-type
    # array form (used for getpath lookups); the dotted string form is built
    # on the source-map write side.
    def leaves:
      [ paths(scalars) as $p
        | { path: $p, value: getpath($p) } ];

    # $path is the mixed-type array form (strings for object keys, integers
    # for array indices). Empty path = whole object.
    def has_path($obj; $path):
      if ($path | length) == 0 then ($obj | length > 0)
      else ($obj | getpath($path) != null) end ;

    . as $eff
    | ($eff | leaves) as $leaves
    | reduce $leaves[] as $leaf (
        {"effective": $eff, "sources": {}};
        .sources[ ($leaf.path | map(tostring) | join(".")) ] = (
          if has_path($l; $leaf.path) then "local"
          elif has_path($r; $leaf.path) then "repo"
          elif has_path($u; $leaf.path) then "user"
          else "defaults" end
        )
      )
  '
}

cmd_get() {
  local path=""
  local with_source=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-source) with_source=1; shift ;;
      --*) echo "get: unknown arg $1" >&2; usage; exit 64 ;;
      *) if [[ -z "$path" ]]; then path="$1"; shift; else echo "get: unexpected arg $1" >&2; exit 64; fi ;;
    esac
  done

  if [[ -z "$path" ]]; then
    echo "get: <dot.path> is required" >&2
    usage
    exit 64
  fi

  local effective
  effective=$(cmd_load) || exit $?

  warn_if_repo_layer_behind

  local jq_path
  # Convert dot-path to jq path; pre-validate that components are safe
  # identifiers (no array indexing, no special chars). Caller is the user
  # so the strictness is light — fail closed on anything weird.
  if [[ "$path" =~ [^A-Za-z0-9._-] ]]; then
    echo "get: dot-path may only contain A-Z, a-z, 0-9, ., _, -" >&2
    exit 64
  fi
  jq_path=".${path}"

  # Resolve the value. Use `jq -r` for strings (unquoted, caller-friendly)
  # and `jq -c` for arrays/objects/numbers/booleans (compact JSON, single
  # line — `--with-source` appends a tab + source layer, so multi-line
  # output would break the tab-separated contract).
  local val_type
  val_type=$(printf '%s\n' "$effective" | jq -r "$jq_path | type" 2>/dev/null)
  if [[ -z "$val_type" || "$val_type" == "null" ]]; then
    echo "get: path $path not present in effective config" >&2
    exit 3
  fi
  local val
  if [[ "$val_type" == "string" ]]; then
    val=$(printf '%s\n' "$effective" | jq -r "$jq_path" 2>/dev/null)
  else
    val=$(printf '%s\n' "$effective" | jq -c "$jq_path" 2>/dev/null)
  fi
  if [[ -z "$val" ]]; then
    echo "get: path $path not present in effective config" >&2
    exit 3
  fi

  if [[ $with_source -eq 1 ]]; then
    # Resolve source by checking each layer in reverse order. The user layer
    # is normalized (#403) so a value set via a user-global alias resolves to
    # the "user" source at its canonical path, matching the effective value.
    local d u r l src="defaults"
    d=$(load_defaults)
    u=$(load_user_merged) || exit $?
    r=$(load_repo) || exit $?
    l=$(load_local) || exit $?
    for layer_name in local repo user defaults; do
      case "$layer_name" in
        local)    local layer_json="$l" ;;
        repo)     local layer_json="$r" ;;
        user)     local layer_json="$u" ;;
        defaults) local layer_json="$d" ;;
      esac
      # `type` returns "null" when the path is missing (jq's getpath
      # semantics). Anything else means the field was set in this layer.
      local present_type
      present_type=$(printf '%s\n' "$layer_json" | jq -r "$jq_path | type" 2>/dev/null)
      if [[ -n "$present_type" && "$present_type" != "null" ]]; then
        src="$layer_name"
        break
      fi
    done
    printf '%s\t%s\n' "$val" "$src"
  else
    printf '%s\n' "$val"
  fi
}

cmd_set() {
  local path=""
  local value=""
  local target="repo"
  local positional=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)   target="repo"; shift ;;
      --local)  target="local"; shift ;;
      --global) target="global"; shift ;;
      --*)      echo "set: unknown arg $1" >&2; usage; exit 64 ;;
      *)
        if [[ $positional -eq 0 ]]; then path="$1"; positional=1
        elif [[ $positional -eq 1 ]]; then value="$1"; positional=2
        else echo "set: unexpected arg $1" >&2; exit 64; fi
        shift ;;
    esac
  done

  if [[ -z "$path" || -z "$value" ]]; then
    echo "set: <dot.path> <value> are required" >&2
    usage
    exit 64
  fi

  if [[ "$path" =~ [^A-Za-z0-9._-] ]]; then
    echo "set: dot-path may only contain A-Z, a-z, 0-9, ., _, -" >&2
    exit 64
  fi

  local target_path
  case "$target" in
    repo)
      if ! target_path=$(repo_config_path); then
        echo "set --repo: not inside a git repo (SHIPYARD_REPO_ROOT not set)" >&2
        exit 64
      fi ;;
    local)
      if ! target_path=$(local_config_path); then
        echo "set --local: not inside a git repo (SHIPYARD_REPO_ROOT not set)" >&2
        exit 64
      fi ;;
    global)
      target_path=$(user_config_path) ;;
  esac

  # Build the existing-or-empty document to write into.
  local existing
  if [[ -f "$target_path" ]]; then
    existing=$(cat "$target_path")
  else
    # Seed with `version: 1` so the file is schema-valid on first write.
    existing='{"version": 1}'
  fi

  # Parse the value — try JSON first (lets the user set numbers/bools/arrays);
  # fall back to string. `jq empty` succeeds on any valid JSON, including
  # `false` / `null` / `0` (which `jq -e .` would mark as falsy and exit 1
  # on — wrong signal for "is this valid JSON?").
  local parsed_value
  if printf '%s' "$value" | jq empty >/dev/null 2>&1; then
    parsed_value="$value"
  else
    parsed_value=$(printf '%s' "$value" | jq -R .)
  fi

  # Construct jq path expression. Dot-path components become a chain of
  # object accesses. setpath() handles creating intermediate objects.
  local path_components
  path_components=$(printf '%s' "$path" | jq -R 'split(".")')

  local updated
  updated=$(printf '%s' "$existing" | jq \
    --argjson path "$path_components" \
    --argjson value "$parsed_value" \
    'setpath($path; $value)')

  # Validate before writing. Repo and local layers validate against the
  # repo schema; the global layer against the user schema.
  local tmp_for_validation
  tmp_for_validation=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_for_validation'" EXIT
  printf '%s\n' "$updated" > "$tmp_for_validation"

  local schema
  case "$target" in
    repo|local) schema=$(repo_schema_path) ;;
    global)     schema=$(user_schema_path) ;;
  esac

  if ! validate_against_schema "$tmp_for_validation" "$schema"; then
    echo "set: refusing to write — value fails schema validation" >&2
    rm -f "$tmp_for_validation"
    trap - EXIT
    exit 70
  fi
  rm -f "$tmp_for_validation"
  trap - EXIT

  # Check atomic_write's own exit status (66 tmpfile-write failure, 67
  # rename failure — see atomic_write above) rather than assuming success.
  # `set -o pipefail` isn't in effect for this script, so `$?` right after
  # a pipeline reflects the last command's status already — but we read
  # PIPESTATUS explicitly so this check keeps working even if a command
  # gets inserted into the pipeline later (issue #871).
  printf '%s\n' "$updated" | atomic_write "$target_path"
  local write_status="${PIPESTATUS[1]}"
  if [[ "$write_status" -ne 0 ]]; then
    echo "set: failed to write $path = $value to $target_path (atomic_write exited $write_status)" >&2
    exit "$write_status"
  fi
  printf 'wrote %s = %s to %s\n' "$path" "$value" "$target_path"
}

cmd_validate() {
  local layer="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --layer) layer="${2:-}"; shift 2 ;;
      *) echo "validate: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local fail=0
  case "$layer" in
    defaults)
      # Defaults are constructed from a literal; they're valid by
      # construction. Validate anyway for the test suite's benefit.
      local tmp
      tmp=$(mktemp)
      load_defaults > "$tmp"
      validate_against_schema "$tmp" "$(repo_schema_path)" || fail=$?
      rm -f "$tmp"
      ;;
    user)
      local path
      path=$(user_config_path)
      if [[ -f "$path" ]]; then
        validate_against_schema "$path" "$(user_schema_path)" || fail=$?
      else
        echo "validate --layer user: $path does not exist (skipping)" >&2
      fi
      ;;
    repo)
      local path
      if path=$(repo_config_path) && [[ -f "$path" ]]; then
        validate_against_schema "$path" "$(repo_schema_path)" || fail=$?
      else
        echo "validate --layer repo: shipyard.config.json does not exist (skipping)" >&2
      fi
      ;;
    local)
      local path
      if path=$(local_config_path) && [[ -f "$path" ]]; then
        validate_against_schema "$path" "$(repo_schema_path)" || fail=$?
      else
        echo "validate --layer local: .shipyard/config.local.json does not exist (skipping)" >&2
      fi
      ;;
    all)
      cmd_validate --layer defaults || fail=$?
      cmd_validate --layer user || fail=$?
      cmd_validate --layer repo || fail=$?
      cmd_validate --layer local || fail=$?
      ;;
    *)
      echo "validate: --layer must be one of defaults|user|repo|local|all" >&2
      exit 64
      ;;
  esac

  if [[ $fail -ne 0 ]]; then
    exit $fail
  fi
  echo "ok"
}

cmd_exists() {
  local path
  if ! path=$(repo_config_path); then
    exit 1
  fi
  if [[ -f "$path" ]]; then
    exit 0
  fi
  exit 1
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

subcmd="$1"
shift

case "$subcmd" in
  load)     cmd_load "$@" ;;
  show)     cmd_show "$@" ;;
  get)      cmd_get "$@" ;;
  set)      cmd_set "$@" ;;
  validate) cmd_validate "$@" ;;
  exists)   cmd_exists "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "shipyard-config.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
