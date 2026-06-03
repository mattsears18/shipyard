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
   - Default `/do-work` concurrency (default `1`). The interactive prompt MUST explain the tradeoff so the human can make an informed choice: most repos that follow shipyard's "always cut a release when a PR merges" convention (or any release-please-style flow) bump a manifest like `plugin.json` or append to `CHANGELOG.md`'s top row on every PR — both treated as HARD paths by the [steady-state dispatch rules](./do-work/steady-state.md#dispatch-rules-used-by-step-7-and-step-c), so a second in-flight worker hard-collides on that manifest and the second slot parks for the rest of the session. The default is therefore `1`; only set `2+` if you've confirmed your repo's PRs don't claim a shared manifest path (e.g. a feature backlog against a service with no per-PR version bump). See issue [#268](https://github.com/mattsears18/shipyard/issues/268) for the dogfooding rationale.
   - **Primary-checkout guard (default `off`).** Offer (opt-in) to install a Claude Code `PreToolUse` hook that fires when an `Edit` / `Write` / `git commit` runs in the repo's **primary checkout** rather than a linked git worktree — forcing each editing session into its own `git worktree`. This protects a user's *interactive* sessions from colliding in one shared working tree (the native `worktree.bgIsolation: "worktree"` setting only isolates *background* sessions; this extends the same protection to interactive ones). See [step 9.5 below](#95-optionally-install-the-primary-checkout-guard) for the full prompt + install logic. Issue [#482](https://github.com/mattsears18/shipyard/issues/482).
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
- `--concurrency <N>` — sets `concurrency.default`. Default `1`. See the prompt note above for when raising this is safe.
- `--primary-guard <off|warn|block>` — installs (or skips) the primary-checkout guard hook (issue [#482](https://github.com/mattsears18/shipyard/issues/482)). Default `off` (no hook installed). `warn` installs the hook in advisory mode (prints guidance, doesn't block); `block` installs it as a hard block. See [step 9.5](#95-optionally-install-the-primary-checkout-guard).
- `--primary-guard-scope <global|repo>` — where the guard hook + paired CLAUDE.md rule are written: `global` (`~/.claude/settings.json` + `~/.claude/CLAUDE.md`) or `repo` (`.claude/settings.json` + repo `CLAUDE.md`). Default `repo`. Only consulted when `--primary-guard` is `warn` or `block`.
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

5. **Build the config and write it via `shipyard-config.sh set --repo`.** One `set` call per field so each write goes through schema validation — with one exception: nested objects whose schema declares a `required: [...]` pair (currently just `.repo`, which requires both `owner` and `name`) MUST be written in a single `set` call with a JSON-object value, because each per-field `set` commits the intermediate state to disk and the validator refuses to leave the parent half-populated. See issue [#305](https://github.com/mattsears18/shipyard/issues/305) for the dogfooding rationale.

   ```bash
   # repo.owner + repo.name are a schema-required pair → write as one JSON object.
   plugins/shipyard/scripts/shipyard-config.sh set repo \
     "$(jq -nc --arg owner "$OWNER" --arg name "$REPO" '{owner: $owner, name: $name}')" \
     --repo

   # All other fields are independent — one set call per field.
   plugins/shipyard/scripts/shipyard-config.sh set auto_merge.policy "$AUTO_MERGE" --repo
   plugins/shipyard/scripts/shipyard-config.sh set trust.authors "$TRUST_JSON" --repo
   plugins/shipyard/scripts/shipyard-config.sh set cost_tracking.enabled "$COST_BOOL" --repo
   # Only emit a concurrency.default write when the user picked a non-default value;
   # the built-in default (1) covers the common case without bloating the committed
   # config with a redundant entry.
   if [[ "$CONCURRENCY" -ne 1 ]]; then
     plugins/shipyard/scripts/shipyard-config.sh set concurrency.default "$CONCURRENCY" --repo
   fi
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

### 9.5 Optionally install the primary-checkout guard

Issue [#482](https://github.com/mattsears18/shipyard/issues/482). This is **opt-in, default off** — do nothing unless the user picks `warn` or `block` (interactively, or via `--primary-guard`). When `--primary-guard off` (the default) or the user declines the prompt, skip this entire step.

**The prompt (interactive).** Explain the tradeoff before asking:

> shipyard isolates *background* `/do-work` workers in their own worktrees, but nothing protects your *interactive* sessions from colliding in this repo's primary checkout — two sessions sharing one working tree can switch the branch / dirty the index out from under each other. I can install a `PreToolUse` hook that fires when an `Edit` / `Write` / `git commit` runs in the primary checkout (not a linked worktree), nudging each editing session into its own `git worktree`. Pick a mode:
>   - **off** (default) — don't install it.
>   - **warn** — print guidance but don't block. Lowest friction; good for trying it out.
>   - **block** — hard-block the edit/commit until you're in a worktree. Strongest protection.
>
> And a scope: **repo** (`.claude/settings.json`, this repo only) or **global** (`~/.claude/settings.json`, every repo).

**Install logic** (only when mode is `warn` or `block`). Two artifacts go in together — the hook (stick) AND a paired CLAUDE.md rule (carrot). Per the issue's "carrot+stick" refinement: with only the hook, every fresh session burns one fired edit before it self-corrects; the CLAUDE.md line makes sessions enter a worktree *proactively* (the `EnterWorktree` tool's own contract only fires when a user or CLAUDE.md asks for a worktree).

1. **Resolve scope paths.** For `repo` scope: `$REPO_ROOT/.claude/settings.json` + `$REPO_ROOT/CLAUDE.md`. For `global` scope: `~/.claude/settings.json` + `~/.claude/CLAUDE.md`.

2. **Wire the hook into `settings.json`** — a `PreToolUse` entry matching `Edit|Write|MultiEdit|NotebookEdit|Bash`, invoking the shipped reference script with the chosen mode in its `env` block. The script (`plugins/shipyard/hooks/guard-primary-checkout.sh`) reads `SHIPYARD_PRIMARY_GUARD` (`off`/`warn`/`block`) so the same file serves all three policies. Merge into the existing `hooks.PreToolUse` array rather than clobbering it (use `jq` and the atomic-write pattern):

   ```jsonc
   {
     "matcher": "Edit|Write|MultiEdit|NotebookEdit|Bash",
     "hooks": [
       {
         "type": "command",
         "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/guard-primary-checkout.sh\"",
         "env": { "SHIPYARD_PRIMARY_GUARD": "<warn|block>" }
       }
     ]
   }
   ```

   Before appending, check for an existing entry whose `command` already references `guard-primary-checkout.sh` and update its `env.SHIPYARD_PRIMARY_GUARD` in place instead of adding a duplicate (so re-running `/shipyard:init` is idempotent).

3. **Append the paired CLAUDE.md rule** to the scope's `CLAUDE.md` (create it if absent; never rewrite existing content — append a `## Worktrees` section or a single bullet under one if present). The rule text should read roughly:

   > **Enter a git worktree before the first edit of any task.** This repo (or your global setup) installs a primary-checkout guard that fires when you `Edit` / `Write` / `git commit` in the primary checkout. Call the `EnterWorktree` tool proactively at the start of editing work rather than burning a fired edit first. Reserve `ExitWorktree "remove"` + `discard_changes: true` for genuinely abandoned work — when a task's local work is done (PR opened) the branch isn't on `main` yet, so end with `ExitWorktree "keep"` (or just leave it) and reap merged worktrees later.

   This carries the issue's third refinement: the `ExitWorktree` cleanup lifecycle is tied to **merge state, not "worker finished"** — `keep` while in-flight, reap when `[gone]`, `remove` + `discard_changes: true` only for abandoned work.

4. **Print a confirmation** naming both files touched and how to change/remove the guard later (edit `SHIPYARD_PRIMARY_GUARD` on the hook entry, or re-run `/shipyard:init --primary-guard off`).

**Don't** hard-block by default, don't write the hook without the paired CLAUDE.md rule (the issue's carrot+stick refinement is explicit that init should offer both), and don't register this in the plugin's own `hooks.json` — it's a per-user opt-in that belongs in *their* `settings.json`, never in the plugin's always-on hook set.

## Don't

- **Don't write committed config without schema validation.** Every `shipyard-config.sh set --repo` call validates before the atomic-write completes. Skipping that creates a footgun (typos in `auto_merge.policy`, etc.) that surfaces as a silent dispatch-time failure later.
- **Don't commit `.shipyard/`.** Step 6 adds it to `.gitignore`; never `git add` anything under that directory yourself.
- **Don't add secrets to `shipyard.config.json`.** The schema rejects keys matching `/token|secret|api_key|password|credential/i`, but the rule applies regardless: this file is committed and reviewable in PRs.
- **Don't enable `auto_merge.policy: always` reflexively.** That setting arms auto-merge on every PR shipyard opens, including PRs that originated from external-author issues. The `trusted-only` default is deliberate; only switch to `always` if you've audited the implications for your repo's threat model.
- **Don't run `/shipyard:init` repeatedly in CI.** It's a one-time bootstrap. Subsequent edits should use `/shipyard:config set` or hand-editing the committed file (with a follow-up `shipyard-config.sh validate` to catch typos).

## Related

- Issue [#165](https://github.com/mattsears18/shipyard/issues/165) — the config-system spec this command implements.
- Issue [#482](https://github.com/mattsears18/shipyard/issues/482) — the primary-checkout guard offered in [step 9.5](#95-optionally-install-the-primary-checkout-guard).
- [`plugins/shipyard/hooks/guard-primary-checkout.sh`](../hooks/guard-primary-checkout.sh) — the reference guard hook (`off`/`warn`/`block` via `SHIPYARD_PRIMARY_GUARD`); shipped so init can wire it into the user's `settings.json` via `${CLAUDE_PLUGIN_ROOT}`. NOT registered in the plugin's `hooks.json`.
- [`/shipyard:config`](./config.md) — show / get / set / edit subcommands for managing the config post-init.
- [`plugins/shipyard/scripts/shipyard-config.sh`](../scripts/shipyard-config.sh) — the underlying loader / validator / writer.
- [`plugins/shipyard/schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) — the repo-config schema.
