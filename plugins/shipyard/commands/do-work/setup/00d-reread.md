# /shipyard:do-work — Setup phase · post-relocation re-read of pre-relocation spec files

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md#06-re-read-stale-spec-files-1191)'s step-0.6 pointer — not part of the ordered per-session walk except when step 0.4's staleness warning fired.** Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

**Now a post-relocation backstop, not the primary defense ([#1351](https://github.com/mattsears18/shipyard/issues/1351)).** [Step 0.42](./00-config-worktree.md#042-immediate-fresh-re-read-on-staleness-1351) already re-reads these same 3 files immediately on detecting staleness, pre-relocation, while a step numbered between 0.4 and 0.5 (the window [step 0.45](./00-config-worktree.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) lives in) can still actually run. This step still matters for two narrower cases: (a) 0.42's `git show` failed for a file (network hiccup) and this is the first genuinely-fresh read of it, and (b) the advisory below, which is pure defense-in-depth detection for the case where a pre-relocation-window step slipped through anyway.

## Why this exists ([#1191](https://github.com/mattsears18/shipyard/issues/1191))

`dont.md`, `setup.md`, and `00-config-worktree.md` are necessarily read from the PRIMARY checkout — the orchestrator can't relocate into its own worktree until it has read [step 0.5](./00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s instructions for doing so. When [step 0.4](./00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson)'s dogfooding staleness check fires (the primary checkout is behind `origin/<default-branch>`), those already-read spec files are confirmed stale — not merely "stale going forward." Step 0.5's relocation re-resolves `CLAUDE_PLUGIN_ROOT` for *later* reads, but nothing before this step told the orchestrator to re-read what it had already consumed. A phase file whose prose changed since (a routing rule, a defer class, a label rename) would otherwise run silently unchanged for the rest of the session, with no further warning.

**Repro:** a session against a 59-commit-stale primary checkout produced 5 consecutive refused Bash calls, because it was still executing the pre-[#1181](https://github.com/mattsears18/shipyard/issues/1181) form of step 0.3's compound `CLAUDE_PLUGIN_ROOT` preamble — unaware the stale copy it read had already been superseded at `origin/<default-branch>`.

## Action — discard the in-context copies, `Read` them fresh

By this point `CLAUDE_PLUGIN_ROOT` has already been re-resolved post-relocation (step 0.5) and stashed at `.shipyard-plugin-root`; that stash — not step 0.4's pre-relocation value — is the source for these re-reads:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
```

Then `Read` (not `cat` — these are spec files the orchestrator reasons over, not text to pipe) each of the three files below, treating the fresh content as authoritative and superseding whatever was read pre-relocation:

- `$CLAUDE_PLUGIN_ROOT/commands/do-work/dont.md`
- `$CLAUDE_PLUGIN_ROOT/commands/do-work/setup.md`
- `$CLAUDE_PLUGIN_ROOT/commands/do-work/setup/00-config-worktree.md`

Three `Read` calls — cheap, and only on the dogfooding-and-stale path. Steps 0.3/0.4 themselves already ran and are not re-executed, only re-read for their *current* text; any behavioral difference between the stale and fresh copies (a routing rule, a defer class, a label rename, a preamble-shape fix like #1181's) governs from this point forward.

## Advisory — report a still-missed pre-relocation step, don't silently swallow it ([#1351](https://github.com/mattsears18/shipyard/issues/1351))

Compare the just-`Read` fresh `00-config-worktree.md` against the primary checkout's on-disk copy — still reachable via the `.shipyard-primary-root` stash [step 0.56](./00k-repo-root-pin.md#056-pin-shipyard_repo_root-to-the-primary-checkout-1059) wrote, since the primary checkout itself is untouched by relocation:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
PRIMARY_ROOT=$(cat .shipyard-primary-root 2>/dev/null)
if [ -n "$PRIMARY_ROOT" ]; then
  SY_STILL_MISSED=$(diff -u \
    "$PRIMARY_ROOT/plugins/shipyard/commands/do-work/setup/00-config-worktree.md" \
    "$CLAUDE_PLUGIN_ROOT/commands/do-work/setup/00-config-worktree.md" 2>/dev/null \
    | grep -E '^\+### 0\.4[0-9]' || true)
  if [ -n "$SY_STILL_MISSED" ]; then
    echo "advisory: pre-relocation step heading(s) existed in the fresh spec but EnterWorktree already ran — too late to execute them in their documented pre-relocation position this session (#1351):" >&2
    printf '%s\n' "$SY_STILL_MISSED" | sed 's/^\+/  - /' >&2
    SHIPYARD_PRERELOC_STEP_MISSED=$(printf '%s' "$SY_STILL_MISSED" | sed 's/^\+### //' | tr '\n' ',' | sed 's/,$//')
  fi
fi
```

**When this fires, it means [step 0.42](./00-config-worktree.md#042-immediate-fresh-re-read-on-staleness-1351)'s earlier catch didn't run at all (its own `git show` call failed — the per-file `warn:` there already named which) or ran against a copy that still didn't carry the step** — a genuine miss, not merely a delayed catch. Don't silently continue: `SHIPYARD_PRERELOC_STEP_MISSED` is session-local working memory (like `SHIPYARD_PRERELOC_STEP_CAUGHT` from step 0.42) read by [`cleanup-summary.md`'s end-of-session summary](../cleanup-summary.md#end-of-session-summary), so the session record says "steps `<list>` skipped this session — spec was stale at read time" instead of reporting nothing. Both variables are mutually informative, not mutually exclusive-ish the way `SHIPYARD_UNCONFIGURED`/`SHIPYARD_CONFIG_SCHEMA_FAILURE` are: a session can catch some newly-added steps at 0.42 and still miss others here, if 0.42's fetch partially failed.
