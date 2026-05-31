# `/shipyard:config` — show / get / set / edit shipyard configuration

Thin wrapper around `plugins/shipyard/scripts/shipyard-config.sh` for managing the four-layer config: built-in defaults, `~/.shipyard/config.json` (user-global), `<repo>/shipyard.config.json` (committed), and `<repo>/.shipyard/config.local.json` (gitignored personal override).

## Subcommands

```
/shipyard:config show                                    # effective config with per-field source layer
/shipyard:config show --plain                            # raw merged JSON, no annotations
/shipyard:config show --layer <defaults|user|repo|local> # one layer in isolation

/shipyard:config get <dot.path>                          # one field's value
/shipyard:config get <dot.path> --with-source            # value + tab + source layer

/shipyard:config set <dot.path> <value>                  # writes to <repo>/shipyard.config.json
/shipyard:config set <dot.path> <value> --local          # writes to <repo>/.shipyard/config.local.json
/shipyard:config set <dot.path> <value> --global         # writes to ~/.shipyard/config.json

/shipyard:config edit                                    # open <repo>/shipyard.config.json in $EDITOR
/shipyard:config edit --local                            # open <repo>/.shipyard/config.local.json
/shipyard:config edit --global                           # open ~/.shipyard/config.json

/shipyard:config validate                                # validate all layers against their schemas
/shipyard:config validate --layer <defaults|user|repo|local>
```

## How the layers compose

Effective config is computed via deep-merge in this order (later layers win):

1. **Built-in defaults** — hardcoded in `shipyard-config.sh`. Always present.
2. **`~/.shipyard/config.json`** — user-global. Default models, default auto-merge policy, and the cost-tracking opt-out across all repos (set via the `default_models` / `default_auto_merge_policy` / `cost_tracking_enabled` aliases, which remap onto the canonical `models.*` / `auto_merge.policy` / `cost_tracking.enabled` paths on load — issue #403).
3. **`<repo>/shipyard.config.json`** — committed. Repo-level shared policy. The presence of this file is what makes a repo "shipyard-initialized."
4. **`<repo>/.shipyard/config.local.json`** — gitignored. Personal overrides for this repo only. Sparse — list only the fields you want to override.

Arrays are *replaced*, not concatenated — repo-level `trust.authors` fully overrides user-global `trust.authors` rather than appending. This is intentional: surprise concatenation would make it impossible to remove a user-global trusted author at the repo level. Objects merge key-by-key recursively.

## `show` — effective config with annotated sources

```bash
$ /shipyard:config show
{
  "effective": {
    "version": 1,
    "auto_merge": { "policy": "trusted-only" },
    ...
  },
  "sources": {
    "version": "defaults",
    "auto_merge.policy": "repo",
    "trust.authors": "local",
    ...
  }
}
```

Each leaf in the effective config is tagged with the source layer that produced it. Drift between committed policy and personal override is immediately visible.

`show --plain` skips the annotations and emits just the merged JSON — useful for piping into other tools (`jq '.auto_merge.policy'` etc.).

`show --layer <name>` prints just one layer's content — useful for debugging "is this field actually in my repo config, or am I inheriting it from defaults?"

## `get` — resolve a dot-path

```bash
$ /shipyard:config get auto_merge.policy
trusted-only

$ /shipyard:config get auto_merge.policy --with-source
trusted-only	repo

$ /shipyard:config get trust.authors
["mattsears18"]
```

Strings come out unquoted; arrays / objects / numbers / booleans come out as compact JSON on a single line (so `--with-source`'s tab-separated contract survives).

Exit codes:
- `0` — value found
- `3` — dot-path not present in the effective config

## `set` — write to a layer

```bash
$ /shipyard:config set auto_merge.policy never --repo
wrote auto_merge.policy = never to /path/to/repo/shipyard.config.json

$ /shipyard:config set models.issue_work claude-haiku-4-5 --local
wrote models.issue_work = claude-haiku-4-5 to /path/to/repo/.shipyard/config.local.json

$ /shipyard:config set trust.authors '["alice","bob"]' --repo
wrote trust.authors = ["alice","bob"] to /path/to/repo/shipyard.config.json
```

The value is parsed as JSON first (so `true`, `false`, `42`, `["alice"]` come through as their natural types). If it doesn't parse, it's treated as a string.

Every `set` runs schema validation against the target layer's schema before the write commits. A failing value never lands on disk:

```bash
$ /shipyard:config set auto_merge.policy maybe --repo
shipyard-config.sh: schema validation failed for /tmp/...:
  .auto_merge.policy: value maybe not in enum ["always","trusted-only","never"]
set: refusing to write — value fails schema validation
```

Targets:
- `--repo` (default) → `<repo>/shipyard.config.json`
- `--local` → `<repo>/.shipyard/config.local.json`
- `--global` → `~/.shipyard/config.json`

Writes are atomic (tmp-file + `mv -f`); a crash mid-write leaves the previous file intact.

## `edit` — open in $EDITOR

```bash
$ /shipyard:config edit            # opens <repo>/shipyard.config.json
$ /shipyard:config edit --local    # opens <repo>/.shipyard/config.local.json
$ /shipyard:config edit --global   # opens ~/.shipyard/config.json
```

Falls back to `vi` if `$EDITOR` is unset. **No validation happens during `edit` itself** — but the next `shipyard-config.sh load` (which every `/shipyard:*` command does at startup) will re-validate and surface errors. Run `/shipyard:config validate` after editing to check the file without invoking a full command.

## `validate` — schema check

```bash
$ /shipyard:config validate
ok

$ /shipyard:config validate --layer repo
ok

$ /shipyard:config validate --layer local
shipyard-config.sh: schema validation failed for /path/.shipyard/config.local.json:
  .auto_merge.policy: value bogus not in enum ["always","trusted-only","never"]
```

Validation covers: required fields, type matches, enum membership, pattern matches, integer minimum, `additionalProperties: false` enforcement on objects with strict schemas, and a secret-name forbidden-surface check (any key matching `/token|secret|api_key|password|credential/i` is rejected regardless of where in the file it appears — committed config must never carry credentials).

## Implementation (what the assistant does)

The command is a thin wrapper. The assistant's job is to:

1. **Resolve the subcommand** from the user's args (`show` / `get` / `set` / `edit` / `validate`).
2. **Translate to `shipyard-config.sh`** invocations:
   ```bash
   # show → shipyard-config.sh show [args]
   plugins/shipyard/scripts/shipyard-config.sh show "$@"

   # get → shipyard-config.sh get <path> [--with-source]
   plugins/shipyard/scripts/shipyard-config.sh get "$path" "$@"

   # set → shipyard-config.sh set <path> <value> [--repo|--local|--global]
   plugins/shipyard/scripts/shipyard-config.sh set "$path" "$value" "$target"

   # validate → shipyard-config.sh validate [--layer <name>]
   plugins/shipyard/scripts/shipyard-config.sh validate "$@"
   ```
3. **For `edit`:** resolve the target file path and shell out to `$EDITOR`:
   ```bash
   case "${target:-repo}" in
     repo)
       file="$(git rev-parse --show-toplevel)/shipyard.config.json" ;;
     local)
       file="$(git rev-parse --show-toplevel)/.shipyard/config.local.json" ;;
     global)
       file="${SHIPYARD_HOME:-$HOME/.shipyard}/config.json" ;;
   esac
   mkdir -p "$(dirname "$file")"
   [ -f "$file" ] || echo '{"version":1}' > "$file"
   "${EDITOR:-vi}" "$file"
   plugins/shipyard/scripts/shipyard-config.sh validate --layer "$target"
   ```
4. **Forward exit codes.** Don't silently swallow non-zero exits from `shipyard-config.sh` — the caller relies on them (`exit 1` for `exists` misses, `exit 3` for `get` misses, `exit 70` for validation failures).

## Don't

- **Don't bypass schema validation by hand-writing to the JSON files.** The schema is the contract; bypassing it causes surprise dispatch-time failures when shipyard's loader rejects the malformed config.
- **Don't put secrets in any of these files.** The schema rejects credential-shaped keys at load time, but the rule applies regardless. Move secrets to environment variables.
- **Don't commit `.shipyard/config.local.json`.** It's gitignored for a reason. `/shipyard:init` adds `.shipyard/` to `.gitignore` automatically.
- **Don't expect `set --local` to work outside a git repo.** The helper resolves paths via `git rev-parse --show-toplevel`; outside a git context the call exits 64 with a clear error.

## Related

- [`/shipyard:init`](./init.md) — bootstrap `shipyard.config.json` for a new repo.
- [`plugins/shipyard/scripts/shipyard-config.sh`](../scripts/shipyard-config.sh) — the underlying loader / validator / writer.
- [`plugins/shipyard/schemas/`](../schemas/) — the repo and user-global schemas.
- Issue [#165](https://github.com/mattsears18/shipyard/issues/165) — the config-system spec.
