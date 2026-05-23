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
# Dependency check — jq is required for merge, projection, and validation
# (we implement a small Draft-07 subset in-script, no external validator).
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "shipyard-config.sh: jq is required but not installed" >&2
  exit 65
fi

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
    "policy": "trusted-only"
  },
  "trust": {
    "authors": []
  },
  "labels": {
    "session_stamp": "shipyard",
    "blocked": "blocked:agent",
    "ci_blocked": "blocked:ci",
    "needs_refinement": "needs-refinement",
    "needs_human_review": "needs-human-review",
    "needs_triage": "needs-triage",
    "user_feedback": "user-feedback"
  },
  "inline_trivial": {
    "enabled": false,
    "max_body_chars": 200,
    "patterns": ["typo", "dep-bump", "doc-only", "comment-only", "config-tweak"]
  },
  "models": {
    "issue_work": "claude-opus-4-7",
    "fix_checks_only": "claude-haiku-4-5",
    "fix_rebase": "claude-haiku-4-5",
    "fix_main_ci": "claude-sonnet-4-6",
    "fix_failing_prs_batch": "claude-sonnet-4-6"
  },
  "cost_tracking": {
    "enabled": true,
    "comment_on_pr": true,
    "comment_on_issue": false
  },
  "concurrency": {
    "default": 2,
    "soft_collision": 3,
    "soft_collision_paths": []
  },
  "main_ci": {
    "aggregation_mode": "branch-protection",
    "required_workflows": []
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
# Atomic write — mirrors session-state.sh's pattern. Same-fs tmp + rename
# is POSIX-atomic; a crash mid-write leaves the previous file intact.
# --------------------------------------------------------------------------
atomic_write() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    trap - EXIT
    echo "shipyard-config.sh: failed to write tmp file $tmp" >&2
    return 66
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    trap - EXIT
    echo "shipyard-config.sh: failed to rename $tmp -> $target" >&2
    return 67
  fi
  trap - EXIT
}

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

def walk($schema_node; $data_node; $path):
    (
      if $schema_node.type and $data_node != null
        then check_type($data_node; $schema_node.type; $path)
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
  if ! validate_against_schema "$path" "$(user_schema_path)" >&2; then
    return 70
  fi
  cat "$path"
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
  if ! validate_against_schema "$path" "$(repo_schema_path)" >&2; then
    return 70
  fi
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
  if ! validate_against_schema "$path" "$(repo_schema_path)" >&2; then
    return 70
  fi
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
  u=$(load_user) || exit $?
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
  u=$(load_user) || exit $?
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
    # Resolve source by checking each layer in reverse order.
    local d u r l src="defaults"
    d=$(load_defaults)
    u=$(load_user) || exit $?
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

  printf '%s\n' "$updated" | atomic_write "$target_path"
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
