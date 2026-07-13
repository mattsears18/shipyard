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
   - Default `/do-work` concurrency (default `1`). The interactive prompt MUST explain the tradeoff so the human can make an informed choice: most repos that follow shipyard's "always cut a release when a PR merges" convention (or any release-please-style flow) bump a manifest like `plugin.json` or append to `CHANGELOG.md`'s top row on every PR — both treated as HARD paths by the [steady-state dispatch rules](./do-work/dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c), so a second in-flight worker hard-collides on that manifest and the second slot parks for the rest of the session. The default is therefore `1`; only set `2+` if you've confirmed your repo's PRs don't claim a shared manifest path (e.g. a feature backlog against a service with no per-PR version bump). See issue [#268](https://github.com/mattsears18/shipyard/issues/268) for the dogfooding rationale.
   - **Primary-checkout guard (default `off`).** Offer (opt-in) to install a Claude Code `PreToolUse` hook that fires when an `Edit` / `Write` / `git commit` runs in the repo's **primary checkout** rather than a linked git worktree — forcing each editing session into its own `git worktree`. This protects a user's *interactive* sessions from colliding in one shared working tree (the native `worktree.bgIsolation: "worktree"` setting only isolates *background* sessions; this extends the same protection to interactive ones). See [step 9.5 below](#95-optionally-install-the-primary-checkout-guard) for the full prompt + install logic. Issue [#482](https://github.com/mattsears18/shipyard/issues/482).
   - **Worktree-reap allowlist (default `off`).** Offer (opt-in) to append the worktree-reap commands to `settings.json`'s `permissions.allow`, so `/do-work`'s end-of-session worktree cleanup is pre-authorized rather than depending on Claude Code's auto-mode classifier permitting it each time. See [step 9.6 below](#96-optionally-pre-authorize-the-worktree-reap-commands) for the full prompt + install logic. Issue [#714](https://github.com/mattsears18/shipyard/issues/714).
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
- `--reap-allowlist <on|off>` — appends the worktree-reap `permissions.allow` rules to `settings.json` so the end-of-session worktree reap is pre-authorized (issue [#714](https://github.com/mattsears18/shipyard/issues/714)). Default `off` (nothing written). See [step 9.6](#96-optionally-pre-authorize-the-worktree-reap-commands).
- `--reap-allowlist-scope <global|repo>` — where the allow rules are written: `global` (`~/.claude/settings.json`) or `repo` (`.claude/settings.json`). Default `repo`. Only consulted when `--reap-allowlist on`.
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

**As of issue [#741](https://github.com/mattsears18/shipyard/issues/741), `guard-primary-checkout.sh` is ALSO wired into the plugin's own `hooks.json` and runs by default (warn mode) for every session, regardless of this opt-in.** This step layers a **user-level** wiring on top of that plugin-level baseline — mainly useful for pinning `block` mode (the plugin-level default is `warn`, which never blocks) at a specific repo or globally. It does not newly enable a guard that was not already running.

**The prompt (interactive).** Explain the tradeoff before asking:

> shipyard's plugin-level primary-checkout guard runs in `warn` mode by default — it prints guidance but doesn't block. I can install an additional `PreToolUse` hook entry in your own settings that pins a stricter mode: `warn` (unchanged, but explicit) or `block` (hard-blocks an `Edit` / `Write` / write-class `git` command until you're in a worktree). Pick a mode:
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

**Don't** hard-block by default, and don't write the hook without the paired CLAUDE.md rule (the issue's carrot+stick refinement is explicit that init should offer both). Note: this step's `settings.json` entry is a **user-level addition** layered on top of the plugin-level `hooks.json` wiring (issue #741) — it does not duplicate the "should this guard exist at all" decision, only "should this repo/user pin a stricter mode than the plugin default."

### 9.6 Optionally pre-authorize the worktree-reap commands

Issue [#714](https://github.com/mattsears18/shipyard/issues/714), following [#712](https://github.com/mattsears18/shipyard/issues/712) / [#713](https://github.com/mattsears18/shipyard/issues/713). This is **opt-in, default off** — do nothing unless the user picks `on` (interactively, or via `--reap-allowlist on`). When `--reap-allowlist off` (the default) or the user declines, skip this entire step.

**The problem.** `/do-work` reaps its agent worktrees at end of session. Claude Code's auto-mode classifier can **deny** the reap — a bare `git worktree remove --force` reads as `[Irreversible Local Destruction]` — and because the reaps are fire-and-forget (`2>/dev/null || true`), a denial is silent and worktrees just accumulate. #713 made the reap *more likely to be permitted* (plain non-force remove first, `--force` only behind an evidence gate) and made a denial *visible* (the `reaped-failed` audit action + the `report-unreaped` post-sweep). Neither *guarantees* the classifier permits it. An `allow` rule removes the denial as a possibility instead of merely surfacing it.

**Why an `allow` rule actually works here (verified, not assumed).** The issue that requested this flagged — correctly — that it is *not obvious* a `permissions.allow` entry and the auto-mode classifier are the same gate. They are, subject to one carve-out, and the carve-out does not bite:

1. Claude Code evaluates rules **deny → ask → allow**, and per the [permission-modes docs](https://code.claude.com/docs/en/permission-modes) *"actions matching your allow or deny rules resolve immediately, **except writes to protected paths**, which route to the classifier even when an allow rule matches."* So an `allow` match short-circuits the classifier for everything that isn't a protected-path write.
2. `.claude/**` **is** a protected path — which would sink this feature, since shipyard's worktrees live at `.claude/worktrees/<name>` — **except that `.claude/worktrees` is explicitly carved out of the protected list** ("everything under `.claude`, except for `.claude/worktrees`, where Claude stores its own git worktrees"). Shipyard's worktrees therefore sit in the one `.claude/` subtree the protected-path exception does *not* cover, so the allow rule resolves immediately.

That second point is load-bearing and worth re-checking if this ever stops working: **if Claude Code ever removes the `.claude/worktrees` carve-out, these rules silently stop short-circuiting the classifier** and the reap goes back to being classifier-gated.

**The prompt (interactive).** State the permission-surface tradeoff before asking — this widens what Claude may run without asking, so the user must opt in with informed consent:

> `/do-work` removes its agent worktrees when a session ends. Claude Code's auto-mode classifier can deny that removal (a `git worktree remove --force` reads as irreversible destruction), and the reap is fire-and-forget — so a denial is silent and stale worktrees pile up in `.claude/worktrees/`. I can add three `permissions.allow` rules to `settings.json` that pre-authorize the worktree-reap commands:
>
> ```
> Bash(git worktree remove:*)
> Bash(git worktree prune:*)
> Bash(git worktree unlock:*)
> ```
>
> **This widens your permission surface**: Claude will be able to run those three `git worktree` subcommands (including `git worktree remove --force`) without asking, in any repo the scope covers. They only affect git's own worktree registry and the worktree directories themselves — they cannot touch your primary checkout's HEAD, your commits, or your remote. Add them? (default: **no**)
>
> And a scope: **repo** (`.claude/settings.json`, this repo only) or **global** (`~/.claude/settings.json`, every repo).

**Install logic** (only when the user opted in). Append to `permissions.allow`, idempotently, preserving everything already there:

1. **Resolve the scope path.** `repo` → `$REPO_ROOT/.claude/settings.json`; `global` → `~/.claude/settings.json`.

2. **Under `--dry-run`, print the rules that *would* be appended and return — write nothing.**

3. **Merge the rules in.** Create the file as `{}` if absent. Append only the rules not already present (never reorder or drop the user's existing entries, never dedupe-sort their list), and write atomically:

   ```bash
   SETTINGS="$SCOPE_SETTINGS_PATH"   # .claude/settings.json | ~/.claude/settings.json
   mkdir -p "$(dirname "$SETTINGS")"
   [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

   REAP_RULES='[
     "Bash(git worktree remove:*)",
     "Bash(git worktree prune:*)",
     "Bash(git worktree unlock:*)"
   ]'

   tmp=$(mktemp)
   jq --argjson rules "$REAP_RULES" '
     .permissions //= {}
     | .permissions.allow = (
         (.permissions.allow // []) as $cur
         | $cur + [ $rules[] | select( . as $r | ($cur | index($r)) | not ) ]
       )
   ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
   ```

   Re-running `/shipyard:init --reap-allowlist on` is therefore a no-op once the rules are present.

4. **Print a confirmation** naming the file touched, the rules added (or "already present"), and how to undo (delete the three entries from `permissions.allow`).

**What these rules do and don't cover.** Be precise about this in the confirmation output — overselling it is how a user ends up believing the reap can no longer be denied when it still can:

- `Bash(git worktree remove:*)` prefix-matches **both** `git worktree remove <path>` and `git worktree remove --force <path>` — the `:*` matches any continuation, so the evidence-gated `--force` escalation from #713 is covered by the same single rule.
- `prune` and `unlock` are the other two reap verbs: the fast path (#664) frees the branch with `git worktree unlock` + `git worktree prune` and never calls `remove` at all, so allowlisting `remove` alone would leave the *common* path still classifier-gated.
- **The rules gate agent-typed Bash calls, not commands inside a script.** shipyard routes most reaps through [`scripts/worktree-reap.sh`](../scripts/worktree-reap.sh), and Claude Code's permission matcher only ever sees the **top-level Bash tool call** — it cannot introspect the `git` commands a shell script runs internally. So these rules matter for the reap commands an agent types *directly* (the orchestrator's inline `git worktree prune` blocks, ad-hoc cleanup, `/clean_gone`) and for shrinking the destructive-looking surface of the compound reap blocks — they do **not** retroactively gate (or un-gate) anything inside `worktree-reap.sh`.
- **Compound commands still route to the classifier if any subcommand is unmatched.** Claude Code requires a rule to match *each* subcommand of a chained command independently (separators: `&&`, `||`, `;`, `|`, `&`, newlines). The orchestrator's reap blocks also run `find` / `sed` / `cd` / `git branch -D`, so allowlisting the three worktree verbs **reduces** the denial surface rather than eliminating it. This is belt-and-braces, not a hard guarantee.

**Don't** write the rules without explicit consent — an `allow` entry is a permission-surface change, and silently widening a user's permission surface is exactly what the permission system exists to prevent; **never write the allow rules without explicit consent**, and never infer consent from the mere presence of `--reap-allowlist-scope`. Don't broaden the rules beyond the three worktree verbs (a blanket `Bash(git:*)` or `Bash(rm:*)` is emphatically not the ask). Don't ever **touch** the `permissions.deny` block — it carries the `--no-verify` / hook-bypass prohibitions, and this step only ever *appends to `allow`*. And don't register these in the plugin's own `plugin.json` permissions — like the #482 guard hook, this is a per-user opt-in that belongs in *their* `settings.json`.

## Don't

- **Don't write committed config without schema validation.** Every `shipyard-config.sh set --repo` call validates before the atomic-write completes. Skipping that creates a footgun (typos in `auto_merge.policy`, etc.) that surfaces as a silent dispatch-time failure later.
- **Don't commit `.shipyard/`.** Step 6 adds it to `.gitignore`; never `git add` anything under that directory yourself.
- **Don't add secrets to `shipyard.config.json`.** The schema rejects keys matching `/token|secret|api_key|password|credential/i`, but the rule applies regardless: this file is committed and reviewable in PRs.
- **Don't enable `auto_merge.policy: always` reflexively.** That setting arms auto-merge on every PR shipyard opens, including PRs that originated from external-author issues. The `trusted-only` default is deliberate; only switch to `always` if you've audited the implications for your repo's threat model.
- **Don't run `/shipyard:init` repeatedly in CI.** It's a one-time bootstrap. Subsequent edits should use `/shipyard:config set` or hand-editing the committed file (with a follow-up `shipyard-config.sh validate` to catch typos).
- **Don't widen the permission surface without explicit consent.** The [step 9.6](#96-optionally-pre-authorize-the-worktree-reap-commands) worktree-reap allowlist is default-`off` and must stay that way: writing a `permissions.allow` entry lets Claude run those commands without asking, and a user who never agreed to that is exactly who the permission system protects. Prompt, take a yes, and only then write. The same rule bars quietly adding *other* rules while you're in there — append the three worktree verbs and nothing else.

## Related

- Issue [#165](https://github.com/mattsears18/shipyard/issues/165) — the config-system spec this command implements.
- Issue [#482](https://github.com/mattsears18/shipyard/issues/482) — the primary-checkout guard offered in [step 9.5](#95-optionally-install-the-primary-checkout-guard).
- Issue [#714](https://github.com/mattsears18/shipyard/issues/714) — the worktree-reap allowlist offered in [step 9.6](#96-optionally-pre-authorize-the-worktree-reap-commands); follows [#712](https://github.com/mattsears18/shipyard/issues/712) / [#713](https://github.com/mattsears18/shipyard/issues/713), which made the reap non-force-first and made a denial visible.
- [`plugins/shipyard/scripts/worktree-reap.sh`](../scripts/worktree-reap.sh) — the reap helper whose commands [step 9.6](#96-optionally-pre-authorize-the-worktree-reap-commands) pre-authorizes.
- [`plugins/shipyard/hooks/guard-primary-checkout.sh`](../hooks/guard-primary-checkout.sh) — the guard hook (`off`/`warn`/`block` via `SHIPYARD_PRIMARY_GUARD`). Registered in the plugin's own `hooks.json` (default `warn`, issue [#741](https://github.com/mattsears18/shipyard/issues/741)); this init step additionally wires it into the user's `settings.json` via `${CLAUDE_PLUGIN_ROOT}` to let a user pin a stricter mode.
- [`/shipyard:config`](./config.md) — show / get / set / edit subcommands for managing the config post-init.
- [`plugins/shipyard/scripts/shipyard-config.sh`](../scripts/shipyard-config.sh) — the underlying loader / validator / writer.
- [`plugins/shipyard/schemas/shipyard.config.schema.json`](../schemas/shipyard.config.schema.json) — the repo-config schema.
