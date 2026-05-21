# `/shipyard:init` — bootstrap shipyard for this repo

Creates `shipyard.config.json` at the repo root (committed) and seeds `.gitignore` with `.shipyard/` (gitignored, for personal overrides + session state). Optional interactive prompts walk you through the most-common knobs; flags let you bypass the interactive flow for scripted setup.

## What this command does

1. **Resolve the repo root.** Uses `git rev-parse --show-toplevel`. Fails fast if you're not inside a git repo — shipyard's config sits at the repo root and the gate keys off that path.
2. **Detect existing shipyard usage.** Looks for the `shipyard` label, prior `shipyard`-stamped PRs, the absence of `.shipyard/` in `.gitignore`. Pre-fills sensible defaults when the repo's been used before (e.g., trusted-author list from prior closed PRs).
3. **Optionally prompt** (skip with non-interactive flags below):
   - Repo owner/name (inferred from `gh repo view` and the git remote)
   - Auto-merge policy (`always` / `trusted-only` / `never` — default `trusted-only`)
   - Trusted authors (defaults to repo owner)
   - Cost-tracking on/off (default on)
4. **Write `shipyard.config.json`** at the repo root using the atomic-write helper in `plugins/shipyard/scripts/shipyard-config.sh`. Validates against the JSON schema before writing.
5. **Append `.shipyard/` to `.gitignore`** if not already present. Creates `.gitignore` if it doesn't exist. **Never** modifies any other line — the addition is appended, with a leading newline if the file doesn't end in one.
6. **Create `.shipyard/`** as an empty directory (for session state, gh-cache, etc. — the helper scripts create subdirectories on demand).
7. **Print a summary** of the effective config (calls `shipyard-config.sh show`).

## Args

```
/shipyard:init                              # interactive
/shipyard:init --auto-merge trusted-only    # non-interactive with one flag
/shipyard:init --auto-merge never --trust mattsears18,collaborator2
/shipyard:init --force                      # overwrite existing shipyard.config.json
/shipyard:init --dry-run                    # print what would be written; no writes
```

Flags:

- `--auto-merge <always|trusted-only|never>` — sets `auto_merge.policy`. Omit to use the default (`trusted-only`).
- `--trust <comma-separated>` — sets `trust.authors`. Defaults to `[<repo-owner>]`.
- `--cost-tracking <on|off>` — sets `cost_tracking.enabled` and `cost_tracking.comment_on_pr`. Default `on`.
- `--force` — overwrite an existing `shipyard.config.json`. Without this, the command refuses to clobber.
- `--dry-run` — print the resolved config to stdout and exit; don't touch the filesystem.
- `--non-interactive` — never prompt. Use defaults for any field a flag didn't supply.

## Implementation (what the assistant should do when this command runs)

The command is intentionally a thin wrapper around `shipyard-config.sh`. The assistant's job is:

1. **Resolve the repo root.**
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel) || {
     echo "/shipyard:init must run inside a git repo"
     exit 64
   }
   ```

2. **Refuse to clobber unless `--force`.**
   ```bash
   if [ -f "$REPO_ROOT/shipyard.config.json" ] && [ "$FORCE" != "1" ]; then
     echo "shipyard.config.json already exists. Use --force to overwrite, or"
     echo "edit it directly with \`/shipyard:config edit\`."
     exit 1
   fi
   ```

3. **Detect prior usage (best-effort).**
   ```bash
   # Did the repo ever have a shipyard-labeled PR?
   prior_shipyard=$(gh pr list --repo "$OWNER/$REPO" --search 'label:shipyard' --state all --limit 1 --json number --jq '.[0].number' 2>/dev/null)
   ```
   If `prior_shipyard` is non-empty, surface that in the prompt ("This repo has prior shipyard usage; defaults match the existing convention").

4. **Resolve config values.**
   - In interactive mode, prompt for any value not supplied via flag.
   - In non-interactive / scripted mode, take values from flags and fall back to defaults.

5. **Build the config and write it via `shipyard-config.sh set --repo`.** One `set` call per field so each write goes through schema validation:
   ```bash
   plugins/shipyard/scripts/shipyard-config.sh set repo.owner "$OWNER" --repo
   plugins/shipyard/scripts/shipyard-config.sh set repo.name "$REPO" --repo
   plugins/shipyard/scripts/shipyard-config.sh set auto_merge.policy "$AUTO_MERGE" --repo
   plugins/shipyard/scripts/shipyard-config.sh set trust.authors "$TRUST_JSON" --repo
   plugins/shipyard/scripts/shipyard-config.sh set cost_tracking.enabled "$COST_BOOL" --repo
   ```

6. **Update `.gitignore`.**
   ```bash
   GITIGNORE="$REPO_ROOT/.gitignore"
   if ! [ -f "$GITIGNORE" ] || ! grep -qx '\.shipyard/' "$GITIGNORE"; then
     # Append a leading newline if the file doesn't end in one.
     [ -f "$GITIGNORE" ] && [ "$(tail -c 1 "$GITIGNORE")" != "" ] && printf '\n' >> "$GITIGNORE"
     printf '.shipyard/\n' >> "$GITIGNORE"
   fi
   ```

7. **Create `.shipyard/` (empty).** The helper scripts create subdirectories on demand (`sessions/`, `gh-cache/`, etc.); this command just ensures the parent directory exists so the personal-override path `.shipyard/config.local.json` is writable without the user doing it manually.
   ```bash
   mkdir -p "$REPO_ROOT/.shipyard"
   ```

8. **Print the effective config.**
   ```bash
   plugins/shipyard/scripts/shipyard-config.sh show
   ```

9. **Print next-step hints.**
   ```
   shipyard.config.json written to <path>. Next steps:
     - Review the file and commit it.
     - Run /shipyard:do-work to start a session.
     - Personal overrides go in .shipyard/config.local.json (gitignored).
     - Edit committed policy via /shipyard:config set <path> <value>.
   ```

## Don't

- **Don't write committed config without schema validation.** Every `shipyard-config.sh set --repo` call validates before the atomic-write completes. Skipping that creates a footgun (typos in `auto_merge.policy`, etc.) that surfaces as a silent dispatch-time failure later.
- **Don't commit `.shipyard/`.** Step 6 adds it to `.gitignore`; never `git add` anything under that directory yourself.
- **Don't add secrets to `shipyard.config.json`.** The schema rejects keys matching `/token|secret|api_key|password|credential/i`, but the rule applies regardless: this file is committed and reviewable in PRs.
- **Don't enable `auto_merge.policy: always` reflexively.** That setting arms auto-merge on every PR shipyard opens, including PRs that originated from external-author issues. The `trusted-only` default is deliberate; only switch to `always` if you've audited the implications for your repo's threat model.
- **Don't run `/shipyard:init` repeatedly in CI.** It's a one-time bootstrap. Subsequent edits should use `/shipyard:config set` or hand-editing the committed file (with a follow-up `shipyard-config.sh validate` to catch typos).

## Related

- Issue [#165](https://github.com/mattsears18/shipyard/issues/165) — the config-system spec this command implements.
- [`/shipyard:config`](./config.md) — show / get / set / edit subcommands for managing the config post-init.
- [`plugins/shipyard/scripts/shipyard-config.sh`](../scripts/shipyard-config.sh) — the underlying loader / validator / writer.
- [`plugins/shipyard/schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) — the repo-config schema.
