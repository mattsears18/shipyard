# /shipyard:do-work — Setup phase · config + worktree

**Setup sub-phase (cluster 1 of 5).** Owns the Lightweight C=1 index, the run-once Setup preamble, and steps 0.3 → 0.9.1: `CLAUDE_PLUGIN_ROOT` re-export, repo-level opt-in check, orchestrator-worktree relocation, per-worktree session-id storage, the fire-once parallelization batch, the `blocker_state` cache, and the `gh-cached.sh` / `gh-batch.sh` wrappers. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Next sub-phase: [`01-repo-recovery.md`](./01-repo-recovery.md).

## Lightweight C=1 path — what's skipped and what stays

Default `--concurrency` is `1`, and at C=1 a substantial chunk of the orchestrator's parallel-coordination machinery is **already skipped** by per-step gates throughout the spec. This section is a single index of those gates so a reader doesn't have to grep across the phase files to assemble the picture — every entry below is implemented by the linked spec callout, not by this section. Closes [#347](https://github.com/mattsears18/shipyard/issues/347).

**The C=1 path is the default.** No flag, no config opt-in — pass `--concurrency 1` (or omit `--concurrency` entirely; `1` is the default) and the gates below fire automatically.

### What's skipped at C=1

| Skipped at C=1 | Why | Owning callout |
|---|---|---|
| Parallel setup batch (`step_0_7_parallel_batch` timing window, the fire-once-batch read burst, pre-population of a candidate pool) | At C=1 there's only one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Steps 1 → 5 run serially instead. | [step 0.7](#07-setup-parallelization-contract-fire-once-batch) |
| Initial failing-PR snapshot (step 5) | The failing-PR set is only relevant when there's a free slot to dispatch a fix-checks worker against it, and at C=1 the slot is guaranteed to be free between dispatches. Defer the query to the first idle turn in steady-state's step D. | [step 5](04-backlog-divert.md#5-snapshot-failing-prs) |
| Batched initial scope pre-flight (step 6's `2 × concurrency` pre-flight) | At C=1 pre-flighting 2 candidates upfront is wasted token spend — by the time the single slot returns, rankings may have shifted and pre-flighted decisions are stale. Pre-flight only the top candidate immediately before each dispatch instead. | [step 6](06-scope-preflight.md#6-initial-scope-pre-flight) |
| Initial pool fill burst (step 7's parallel `Agent` burst across N slots) | The "pool" is a single slot. Dispatch exactly one worker via the same dispatch rules; no `run_in_background: true` needed. | [step 7](07-pool-fill.md#7-initial-pool-fill) |
| Path-collision check (step C's `claimed_paths.hard` ∩ `in_flight` pass) | The check is a pure overhead pass that always resolves to "no collision" because `in_flight` is either empty or holds exactly one slot (the current worker, which has already been released by step B before step C runs). | [steady-state.md step C — Hard collision](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Soft-cap counter (the `--soft-collision-concurrency` tier) | No main-concurrency cap to burst past and no peer slots to share a path with. Don't track `claimed_paths.soft`, don't decrement on return, don't consult the soft cap. | [steady-state.md step C — Soft collision](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Section-aware lockfile-collision check (`lockfile_sections` claim-and-check) | No peer slots and no contention on any lockfile section — the check always resolves to "no collision." The scope pre-flight still returns `lockfile_sections` in its ready shape so the session-state schema remains valid, but the orchestrator ignores the field at dispatch time. | [steady-state.md step C — Section-aware lockfile rule](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Rolling scope-refill background burst (step D's `2 × concurrency` background scope agents) | The just-in-time per-dispatch scope call (above) is the C=1 equivalent. `scope_bg_count` stays `0` and the per-dispatch JIT call is synchronous. | [step 6 C=1 note](06-scope-preflight.md#6-initial-scope-pre-flight) (see also the in-state struct ref at [`scope_bg_count`](../../do-work.md#orchestrator-state)) |

### What stays at C=1

These steps are **not** gated by concurrency — they fire identically at C=1 and C≥2:

- **Worktree relocation (step 0.5).** The orchestrator runs in its own isolated worktree at every concurrency level. This is the lock against `/do-work` running concurrently in the user's primary checkout (the threat the [worktree-isolation contract](../dont.md) names), and the safety property is independent of how many workers the orchestrator dispatches.
- **Config opt-in check (step 0.4).** The merged 4-layer config is read once at session start regardless of concurrency — defaults / pricing / model overrides / auto-merge policy all apply at C=1 too.
- **Session-state init (step 1.5) + every write-through.** The session-state JSON file is the durable record that [`/shipyard:status`](../../status.md), the orphan session-file sweep, the cost-tracking comments, and a future `--resume <session-id>` flag all read from. The mirror fires whether the session has one slot or four.
- **Trusted-author allowlist (step 1.7) + bucket 0.5 + step 4 client-side filter.** Author trust is the security gate against prompt-injection from stranger-authored issues. It fires before dispatch at every concurrency level; lowering it for "single-trusted-author personal repo" sessions would defeat the defense-in-depth posture documented in [`dont.md`'s security boundary](../dont.md).
- **Background cleanup group (the `(...) &` subshell in step 0.7).** The orphan session-file sweep (1.6), orphan orchestrator-worktree sweep (1.6.5), label create (3a), agent-worktree reap (3b), and orphan-branch triage (3c) all run in a single background subshell at every concurrency level. Skipping them at C=1 would mean orphan files / worktrees from earlier C=1 crashes accumulate forever (issue [#280](https://github.com/mattsears18/shipyard/issues/280)).
- **Per-step setup-timing brackets** (`setup-timing.sh start` / `end` calls in steps 0.5, 1.7, 3.5, 4, 6). These are the data source for the [#258](https://github.com/mattsears18/shipyard/issues/258) measurement umbrella and the cross-session perf ledger — kept at every level. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (there's nothing to time when the batch doesn't run).
- **Backlog fetch + rank + triage (step 4), divert checks (step 4.5).** The dispatch queues still need to exist and stay current at C=1; only the parallel coordination over the *fill* changes.
- **Drain + cleanup + end-of-session summary.** Drain semantics are identical at C=1 — the per-poll merge-train watcher, the fix-rebase dispatch for `D_dirty`, the progress-based exit + `max_drain_hours` ceiling, the end-of-session HTML report — all apply unchanged.

### When the inline-trivial fast path **also** fires (orthogonal to C=1)

The C=1 path above is about *what the orchestrator does for any candidate at C=1*. The [inline-trivial fast path](../inline-trivial.md) is a **separate, orthogonal** dispatch-time optimization that fires for *some candidates* (typos, dep-bumps, doc-only, comment-only, config-tweak — pattern-matched) when `inline_trivial.enabled == true` in config. Inline-trivial works at every concurrency level, requires opt-in via config (default OFF), and is **conservative-by-default** with strict eligibility rules (body ≤ 200 chars, no headings, no long code fences, no disqualifying labels, trusted author). Don't confuse the two: C=1 is "the orchestrator runs sequentially with no parallel-coordination overhead"; inline-trivial is "for this specific candidate, the orchestrator runs the work inline instead of dispatching a worker." A session can be C=1 with inline-trivial off (the default), C=1 with inline-trivial on, C≥2 with inline-trivial off, or C≥2 with inline-trivial on — every combination is valid and the two optimizations stack.

### When to pick C=1 vs C≥2

C=1 is the default and the right choice for most personal-repo backlogs because the dominant failure mode is the manifest / version-row hard collision documented in the [thin entry's `--concurrency` flag docs](../../do-work.md#args). Pick `--concurrency 2+` only when realized parallelism is genuinely real — a feature-development backlog against a service with no per-PR version bump, where two workers can land truly independent changes simultaneously without colliding on `package.json` or `CHANGELOG.md`. The [#268](https://github.com/mattsears18/shipyard/issues/268) dogfooding rationale walks through the empirical observation that drove the default.

## Setup (run once)

### 0.3 `CLAUDE_PLUGIN_ROOT` re-export preamble (every Bash-tool call)

**The harness does not propagate `$CLAUDE_PLUGIN_ROOT` into the Bash-tool subprocess shells.** Verified deterministically against this repo as `do-work-20260525T142439Z-64308` ([#354](https://github.com/mattsears18/shipyard/issues/354)): the env var that's documented as the canonical "where is the installed plugin" pointer expands to the **empty string** inside every Bash-tool call. The very first templated invocation of `/shipyard:do-work` — step 0.4's `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists` — therefore evaluates as `/scripts/shipyard-config.sh` and exits 127 (`no such file or directory`). Every subsequent script invocation in setup / steady-state / drain / cleanup-summary / inline-trivial would fail the same way.

This is the same class of harness-env friction as [#322](https://github.com/mattsears18/shipyard/issues/322) (`$WORKTREE_PATH` not persisting across Bash tool calls): each Bash tool call is hermetic — variables you set in call N are NOT visible in call N+1, and `export` in call N does not persist. Setting the env var once at session start doesn't help.

**The fix is an idempotent preamble at the top of every Bash snippet that references `${CLAUDE_PLUGIN_ROOT}/scripts/...`:**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
```

Semantics:

- **When the harness DOES set `$CLAUDE_PLUGIN_ROOT`** (slash-command launch contexts, future harness fixes, manual `export` for testing) — the `${VAR:-default}` short-circuits and the export is a no-op. Subsequent `${CLAUDE_PLUGIN_ROOT}/scripts/...` calls resolve to the harness-provided installed-plugin path.
- **When the harness does NOT set it** (the observed steady-state for every Bash-tool call inside this orchestrator) — the fallback **probes three install layouts in order** before defaulting:
  1. **Repo-local** (`<repo>/plugins/shipyard`) — but only when that path actually carries a `scripts/` subdir. This is the dogfooding case: shipyard's own checkout (or a worktree of it) runs the spec from the same repo it's orchestrating against, so the repo-local plugin source IS the tree to execute. The `-d "$R/plugins/shipyard/scripts"` guard is load-bearing — it's what lets the probe *fall through* on a consumer repo instead of resolving to a non-existent path.
  2. **Authoritative installed path** (`installPath` for `shipyard@shipyard` in `$HOME/.claude/plugins/installed_plugins.json`) — the consumer-install case, done *correctly* ([#681](https://github.com/mattsears18/shipyard/issues/681)). `installed_plugins.json` records the exact directory of the loaded install (under `cache/<marketplace>/<plugin>/<version>/`), so it's immune to the two failure modes of a bare marketplace glob: a stale sibling backup dir shadowing the live install, and a marketplace checkout whose version doesn't match the loaded one. Guarded by `-d "$I/scripts"` so a malformed/partial entry falls through to layer 3.
  3. **Marketplace install** (`$HOME/.claude/plugins/marketplaces/*/plugins/shipyard`) — the fallback consumer-install path ([#417](https://github.com/mattsears18/shipyard/issues/417)) used only when `installed_plugins.json` is unreadable. When `/shipyard:do-work` runs against a repo that installed shipyard via the marketplace (e.g. `mattsears18/lightwork`), there is no repo-local `plugins/shipyard`; the old bare `$(git rev-parse --show-toplevel)/plugins/shipyard` fallback resolved to `<repo>/plugins/shipyard` which doesn't exist, so every `${CLAUDE_PLUGIN_ROOT}/scripts/*.sh` call exited 127. This glob is **hardened** ([#681](https://github.com/mattsears18/shipyard/issues/681)): the old `ls -d …/*/plugins/shipyard | head -1` sorted its matches, and because `.` (`0x2E`) sorts before `/` (`0x2F`) a `shipyard.bak` sibling won `head -1` over the real `shipyard` dir — silently selecting a backup. The replacement tries the **exact** `marketplaces/shipyard/plugins/shipyard` path first, **excludes** `.bak`/`.old`/`.orig`/`.disabled` siblings, and requires a real `scripts/` dir on the chosen match.
  4. **Repo-local anyway** (the `${M:-$R/plugins/shipyard}` default) — when no layer resolves, fall back to the repo-local path so error messages name a meaningful (if missing) location rather than the empty string.

**Echo the resolved value once, at this step ([#681](https://github.com/mattsears18/shipyard/issues/681)).** The variable is load-bearing for the whole session — every `${CLAUDE_PLUGIN_ROOT}/scripts/*.sh` call routes through it — yet it resolves *invisibly*, so a fallback that picked the wrong directory (a stale `.bak` copy, a version-mismatched marketplace checkout) is undetectable from the session log. The first real usage (step 0.4) therefore prints the resolved path to stderr immediately after the preamble: `echo "resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT" >&2`. One line, once — enough for an operator (or a later reader of the transcript) to confirm the session ran against the intended install. Do NOT repeat the echo in every block; the one at step 0.4 covers the session.

**Defense in depth — the helpers also self-locate.** Every script under `plugins/shipyard/scripts/*.sh` resolves sibling-script paths via `BASH_SOURCE[0]`, not via `$CLAUDE_PLUGIN_ROOT`. The preamble only fixes layer 1 (how the orchestrator *invokes* a script); layer 2 (how a script finds its peers) was already correct. Together the two layers mean a templated invocation works regardless of how the harness configures (or fails to configure) the env var.

**Every bash block in this file (and `steady-state.md` / `drain.md` / `cleanup-summary.md` / `inline-trivial.md`) that uses `${CLAUDE_PLUGIN_ROOT}` already carries this preamble as its first line.** Don't strip it; don't move it after the first `${CLAUDE_PLUGIN_ROOT}/...` usage; don't substitute a different fallback path. The pattern is regression-guarded by [`scripts/tests/claude-plugin-root-preamble.test.sh`](../../../scripts/tests/claude-plugin-root-preamble.test.sh) — any new bash block that references `${CLAUDE_PLUGIN_ROOT}` without the preamble at its top fails CI.

### 0.4 Check the repo-level opt-in (`shipyard.config.json`)

**Run this BEFORE the worktree relocation.** The check is a single `shipyard-config.sh exists` call against the user's primary checkout — read-only, no writes, so the worktree-isolation rule doesn't apply yet.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Echo the resolved value once (#681): it's load-bearing for the whole session
# yet resolves invisibly, so a wrong pick (stale .bak, version-mismatched
# marketplace checkout) would otherwise be undetectable from the log.
echo "resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT" >&2
cd "$(git rev-parse --show-toplevel)"
"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists
case $? in
  0)
    # Repo is shipyard-initialized — load the merged config so subsequent
    # steps can read tunables like trust.authors, auto_merge.policy, etc.
    #
    # `load` can itself fail: a `shipyard.config.json` (or
    # `.shipyard/config.local.json`) that's present but schema-invalid makes
    # `load` exit non-zero (70 = schema validation failed; 65 = internal
    # helper failure) with EMPTY stdout. Capturing stdout alone would set
    # `EFFECTIVE_CONFIG=""` and every downstream `shipyard-config.sh get`
    # would silently fall back to built-in defaults — the user's per-repo
    # trust list / auto-merge policy / cost-tracking knobs all ignored for
    # the rest of the session with NO warning (issue #367). Capture the exit
    # code and stderr, and surface a loud warning on failure.
    CONFIG_LOAD_STDERR=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" load 2>&1 1>/tmp/shipyard-effective-config.$$)
    CONFIG_LOAD_RC=$?
    if [ "$CONFIG_LOAD_RC" -eq 0 ]; then
      EFFECTIVE_CONFIG=$(cat /tmp/shipyard-effective-config.$$)
    else
      # Schema-invalid (or otherwise unloadable) config. Fall back to
      # built-in defaults — but LOUDLY, and record the failure so the
      # end-of-session summary surfaces it (the silent-degrade is the
      # actual bug #367 flags as more important than the regex breadth).
      EFFECTIVE_CONFIG=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" load 2>/dev/null < /dev/null) || EFFECTIVE_CONFIG=""
      # The loader's stderr already names each rejected field on its own
      # indented line (e.g. `  .auto_merge.policy: value bogus not in
      # enum [...]`). Extract just those lines and `; `-join them. POSIX
      # `[[:space:]]` (not `\s`) so the grep matches on BSD grep too; awk
      # for the join (NOT `paste -d '; '` — `paste`'s -d is a cycled list
      # of single-char delimiters, so '; ' would alternate `;` then ` `).
      REJECTED_FIELDS=$(printf '%s\n' "$CONFIG_LOAD_STDERR" \
        | grep -E '^[[:space:]]+\.' \
        | sed 's/^[[:space:]]*//' \
        | awk 'NR>1{printf "; "} {printf "%s", $0} END{if (NR>0) print ""}')
      [ -z "$REJECTED_FIELDS" ] && REJECTED_FIELDS="(loader exit $CONFIG_LOAD_RC; see stderr above)"
      cat <<EOF
warning: shipyard.config.json failed schema validation (loader exit $CONFIG_LOAD_RC).

  Rejected: $REJECTED_FIELDS

  Your per-repo config is NOT being applied — every config read this session
  (trust.authors, auto_merge.policy, cost_tracking.*, ci.*, etc.) falls back
  to built-in defaults. Fix the rejected field(s) and re-run, or run
  /shipyard:config validate to see the full report.
EOF
      # Note: EFFECTIVE_CONFIG above re-runs `load` to recover the merged
      # defaults+user layers; on a hard schema failure in the repo/local
      # layer that re-run also exits non-zero, leaving EFFECTIVE_CONFIG="".
      # Downstream `shipyard-config.sh get` calls each independently fall
      # back to defaults, so an empty EFFECTIVE_CONFIG is safe (not
      # load-bearing) — but the warning above is the user-facing signal.
      SHIPYARD_CONFIG_SCHEMA_FAILURE="$REJECTED_FIELDS"
    fi
    rm -f /tmp/shipyard-effective-config.$$ ;;
  1)
    # Repo is NOT shipyard-initialized. Warn loudly and continue with
    # built-in defaults — but record the unconfigured state so the
    # end-of-session summary surfaces it for the user. The hard refusal
    # gate ships in a later release once /shipyard:init is widely used
    # (issue #165's risk-mitigation section explicitly defers it).
    cat <<'EOF'
warning: this repo is not shipyard-initialized.

  No shipyard.config.json found at the repo root. Running with built-in
  defaults — auto_merge.policy=trusted-only, no per-repo trust list, etc.

  To opt in (recommended for shared / team repos):
    /shipyard:init

  To suppress this warning, run with --no-config (built-in defaults only).
  A future release will refuse to dispatch without shipyard.config.json
  unless --force is passed.
EOF
    EFFECTIVE_CONFIG=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" load)
    SHIPYARD_UNCONFIGURED=1 ;;
esac
```

`EFFECTIVE_CONFIG` is the merged result of all layers (defaults < user-global < repo < local). Subsequent steps that previously hardcoded a value should now read it via `jq` from `$EFFECTIVE_CONFIG` or via a fresh `shipyard-config.sh get <path>` call. The migration of hardcoded values is incremental — this PR introduces the loader; downstream issues (#156, #157, #160, #163) will swap each hardcoded value for a config read.

**The `exists == 0` but `load` fails branch ([#367](https://github.com/mattsears18/shipyard/issues/367)).** A repo can be shipyard-initialized (`exists` returns 0) yet have a `shipyard.config.json` that fails schema validation — a typo'd enum value, an unknown top-level key, a missing required field. Before #367 the `case 0)` branch captured `load`'s stdout unconditionally; on a schema failure stdout is empty and the exit code (70) was discarded, so `EFFECTIVE_CONFIG` silently became `""` and every downstream `shipyard-config.sh get` fell back to built-in defaults with no warning — the user's per-repo trust list, auto-merge policy, and cost-tracking knobs all quietly ignored for the entire session. The branch above now captures the loader's exit code and stderr, prints a **loud one-line warning naming the rejected field(s)** plus which config keys are defaulting as a result, and records the failure detail in the session-local `SHIPYARD_CONFIG_SCHEMA_FAILURE` variable so the [end-of-session summary](../cleanup-summary.md#end-of-session-summary) surfaces the same line. The fall-through to defaults is unchanged (still conservative-by-design — `auto_merge.policy=trusted-only`, trust resolution via the live collaborators API); the only behavioral change is that the degrade is now *visible* at both step 0.4 and end-of-session.

`SHIPYARD_CONFIG_SCHEMA_FAILURE` is session-local working memory (like `SHIPYARD_UNCONFIGURED`) — not mirrored to the session-state file. It's set only on the schema-failure path; when unset, the end-of-session summary omits the `Config:` line entirely (silence is the right default for a clean config load). Treat the two as mutually-exclusive-ish in practice: `SHIPYARD_UNCONFIGURED=1` means no `shipyard.config.json` at all, while `SHIPYARD_CONFIG_SCHEMA_FAILURE` means one is present but invalid.

Flags interpreted here:

- `--force` / `--no-config` — skip the warn and continue with built-in defaults. Equivalent for now; once the hard-refusal gate ships, `--force` will be the explicit "I know this repo is unconfigured" opt-out.
- `--strict` — refuse to dispatch if `shipyard.config.json` is missing. Early-adopter opt-in for the future-default behavior.

```bash
case "${1:-}" in
  --strict)
    if [ "$SHIPYARD_UNCONFIGURED" = "1" ]; then
      echo "/shipyard:do-work --strict: shipyard.config.json is required"
      echo "  run /shipyard:init to bootstrap, or drop --strict to fall back to defaults"
      exit 1
    fi ;;
  --no-config|--force) : ;;  # already handled above
esac
```

### 0.5 Move into the orchestrator's worktree

**Before any other setup, the orchestrator MUST relocate every write into a dedicated worktree.** The user's primary checkout is strictly read-only for the rest of the session. The hard rule: every *write* (`Edit`, `Write`, `git commit`, `git reset`, `git branch <new>`, label setup, README/CHANGELOG/CLAUDE.md tweaks, `plugin.json` version bumps, etc.) goes through the orchestrator worktree. Read-only operations (`git status`, `gh issue list`, `gh pr view`, `find`, `grep`, `git worktree list`, `gh run list`, label-existence checks via `gh label list`, etc.) MAY run in either checkout.

**Timing instrumentation (issue #238).** Bracket this step with `setup-timing.sh start` / `end` calls. Both are fire-and-forget (`2>/dev/null || true`) — never let a timing failure abort setup.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

Create (or reuse) the orchestrator's worktree under `.claude/worktrees/orchestrator-<session-id>` from the tip of the default branch. `<session-id>` is the current Claude Code session identifier — stable across the run, distinct from each dispatched agent's `<id>`:

```bash
# Run this once from the user's primary checkout (the only write to .git/worktrees/ that the primary will see this session)
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
ORCH_WT=".claude/worktrees/orchestrator-<session-id>"
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)

# If a prior session left this exact path around, reuse it after refreshing to origin's tip.
if [ -d "$ORCH_WT" ] && git worktree list --porcelain | grep -q "^worktree $(pwd)/$ORCH_WT$"; then
  git -C "$ORCH_WT" fetch origin "$DEFAULT_BRANCH"
  git -C "$ORCH_WT" checkout "$DEFAULT_BRANCH"
  git -C "$ORCH_WT" reset --hard "origin/$DEFAULT_BRANCH"
else
  git fetch origin "$DEFAULT_BRANCH"
  git worktree add "$ORCH_WT" "origin/$DEFAULT_BRANCH"
fi
```

**From this point on, every subsequent `Bash` / `Edit` / `Write` tool call in the orchestrator's session runs with `<repo-root>/.claude/worktrees/orchestrator-<session-id>` as cwd.** Prepend `cd "$ORCH_WT" && ` (or pass `-C "$ORCH_WT"` to git) for any command whose effect lands on disk or on a branch ref. The user's primary checkout's HEAD MUST NOT change during this session — if you find yourself running a write-class command in the primary checkout, back up, switch to the orchestrator worktree, retry. See [RATIONALE → Why a dedicated worktree](../../do-work-RATIONALE.md#step-05--why-a-dedicated-orchestrator-worktree) for the failure modes this prevents.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Close the step_0_5_worktree timing window.
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

End-of-session cleanup also runs from the orchestrator worktree, and reaps the orchestrator's own worktree last — see [End-of-session cleanup](../cleanup-summary.md#end-of-session-cleanup) below.

### 0.55 Session-id storage (per-worktree, not /tmp)

**The session id MUST be stashed at `<orch-worktree>/.shipyard-session-id`, NOT at any globally-shared path like `/tmp/shipyard-session-id.txt`.** Closes [#365](https://github.com/mattsears18/shipyard/issues/365).

The orchestrator's many Bash tool calls each need to know `<session-id>` to substitute into the `--session-id "<session-id>"` templates throughout this file (e.g. `session-state.sh update`, `setup-timing.sh end`, `cost-history.sh flush`, the `--reaper-session-id "<session-id>"` audit-stamps). The harness-env quirk (same class as [#322](https://github.com/mattsears18/shipyard/issues/322) for `$WORKTREE_PATH` and [#354](https://github.com/mattsears18/shipyard/issues/354) for `$CLAUDE_PLUGIN_ROOT`) is that **each Bash tool call is hermetic** — env vars set in call N are not visible in call N+1, and `export SESSION_ID=...` doesn't persist. A natural workaround is to write the id to a file the orchestrator re-reads at the top of every Bash call.

**The file MUST live inside the orchestrator's own worktree.** The orchestrator worktree path is unique per session by construction (`.claude/worktrees/orchestrator-<session-id>` — see [step 0.5](#05-move-into-the-orchestrators-worktree)), so a per-worktree path is unique per session by extension. A globally-shared path like `/tmp/shipyard-session-id.txt` is **forbidden** — when two `/shipyard:do-work` sessions run concurrently against different repos, both write to the same `/tmp` path; the later starter clobbers the first, redirecting every subsequent `session-state.sh bump-tokens` / `update` call to the WRONG session file. Token attributions, `session_prs` appends, and `reconciled_agent_ids` entries leak into the wrong session's state, corrupting both cost ledgers. This is the failure mode #365 documents end-to-end.

**Write the id at session start, immediately after the orchestrator worktree is created.** Place this block after the [step 0.5 timing close](#05-move-into-the-orchestrators-worktree) and before [step 0.7](#07-setup-parallelization-contract-fire-once-batch):

```bash
# `$ORCH_WT` was set in step 0.5; derive the absolute path so the read-back
# below works regardless of the caller's cwd inside the worktree subtree.
printf '%s\n' "<session-id>" > "$ORCH_WT/.shipyard-session-id"
```

**Read it back at the top of every Bash tool call that needs the id.** Cheap (one `cat`); robust against the harness's per-call hermetic-shell semantics; impossible to race because the path is per-session-unique:

```bash
SESSION_ID=$(cat "$ORCH_WT/.shipyard-session-id")
# ... use $SESSION_ID in subsequent calls; e.g. session-state.sh update --session-id "$SESSION_ID" --set '...'
```

Equivalently — when `$ORCH_WT` isn't already in scope — derive the orchestrator worktree path and read the stash from there. **Do NOT derive it from `git rev-parse --show-toplevel`** (issue [#477](https://github.com/mattsears18/shipyard/issues/477)): `git rev-parse --show-toplevel` returns whatever worktree the shell's cwd is in, and the harness can silently relocate the orchestrator's own Bash-tool cwd into a just-returned **agent's** `agent-*` isolation worktree on a reconcile turn (the same `isolation: "worktree"` cwd-leak class as [#452](https://github.com/mattsears18/shipyard/issues/452), which [A.0.6's primary-leak guard](../steady-state.md#a06-primary-checkout-branch-leak-guard-fires-every-reconcile-turn-before-a1) already hardens against). When cwd is in an `agent-*` worktree, `git rev-parse --show-toplevel` returns the **agent** worktree path — which has no `.shipyard-session-id` stash (that file lives only in the orchestrator worktree, per the "MUST live inside the orchestrator's own worktree" rule above). The `cat` then comes up empty, every downstream `session-state.sh` call is invoked with an empty `--session-id` and exits 64 (`--session-id is required`), and the turn silently loses its cost attribution + `session_prs` append (a lost `session_prs` append can strand a PR out of the drain watch list).

Derive the session id with the `worktree-reap.sh derive-session-id` helper instead of an inline `awk` walk. The helper globs `<repo-root>/.claude/worktrees/orchestrator-*` (cwd-independent given the explicit `--repo-root`, so it is immune to the #477 cwd-leak) and reads the `.shipyard-session-id` stash from the **newest-by-mtime** orchestrator worktree.

**Newest-by-mtime, not first-in-listing-order — issue [#513](https://github.com/mattsears18/shipyard/issues/513).** The previous inline derive used `awk '... {print p; exit}'`, which returns the *first* `orchestrator-*` entry in `git worktree list --porcelain` order. When prior crashed sessions leave their `orchestrator-<dead-id>` worktrees un-reaped (the [step 1.6.5 sweep](01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees) didn't run, or hasn't run yet), "first in listing order" is the **oldest orphan**, so the derive read a dead orphan's stash and every `session-state.sh update` / `bump-tokens` write landed in the orphan's session file — same repo, so the `--expected-repo` guard never tripped, silently corrupting the cost ledger, `/shipyard:status`, and `--resume` while this session's real file stayed at init defaults (the #513 repro: 245k tokens + 11 deferred issues + `session_prs += [1897]` all misattributed to a 6-day-old orphan). The live session's orchestrator worktree was created **this run** in [step 0.5](#05-move-into-the-orchestrators-worktree), so among any set of coexisting orchestrator worktrees it has the newest directory mtime — selecting newest resolves to the live session whenever orphans coexist, and is a no-op (a single candidate) in the common one-worktree case. (The deeper fix is to make [step 1.6.5](01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees) reap orphans so the multi-orchestrator-worktree precondition rarely arises in the first place; newest-by-mtime is the correctness floor for when it does.)

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Derive the session id from the NEWEST orchestrator-* worktree's stash
# (issue #513 — newest, not first-in-listing-order, so an accumulated orphan
# from a prior crashed session can't shadow the live session). cwd-independent
# given the explicit --repo-root (immune to the #477 cwd-leak).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
  --repo-root "$REPO_ROOT" 2>/dev/null)
# Last-resort fallback for a non-worktree layout where the glob found no
# orchestrator worktree: the cwd-derived stash read. Vulnerable to the #477
# cwd-leak, so only when the helper came up empty.
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
```

The `REPO_ROOT` derived from `git rev-parse --show-toplevel` here only feeds the `--repo-root` glob anchor — under the #477 cwd-leak it may resolve to an `agent-*` worktree, but every linked worktree's `.claude/worktrees/` directory shares the same primary checkout, so the glob still enumerates the same orchestrator worktrees regardless of which linked worktree the cwd sits in. (The cwd-leak only breaks a derive that *reads the stash directly from `show-toplevel`* — which is exactly the last-resort fallback line, used only when the glob found nothing.)

**Defense in depth — `session-state.sh` enforces a cross-repo write guard.** Even if the orchestrator's id-stash mechanism is bypassed or corrupted, `session-state.sh update` and `session-state.sh bump-tokens` accept an `--expected-repo <owner/repo>` flag (also accepted via `SHIPYARD_EXPECTED_REPO=<owner/repo>` env var). When the flag is set and the resolved session file's `.repo` field doesn't match, the call exits 66 with a loud stderr log naming both repos — refusing the write rather than silently corrupting another session's state. The orchestrator SHOULD pass `--expected-repo <owner/repo>` on every `update` and `bump-tokens` call; the `--skip-repo-check` flag is reserved for the rare legitimate cross-repo helper (e.g., the orphan-sweep at step 1.6, which intentionally operates on session files belonging to other repos). See [session-state.sh's cross-repo guard](../../../scripts/session-state.sh) for the exit-code contract.

**Don't reach for option 2 from #365** ("skip the file entirely, compute the session id from the worktree path"). The compute-from-worktree-path approach is appealing in theory but invasive in practice — the orchestrator's many Bash tool calls would all need to walk `git worktree list` to find their worktree, parse the orchestrator-<id> suffix, and handle the edge cases where the cwd isn't inside an orchestrator worktree (foreground vs. background subshells, the user's primary-checkout invocation, etc.). The per-worktree stash file is the minimum-surgery shim that addresses the race without redesigning the lookup pattern. Reserve compute-from-worktree-path for a follow-up issue if the stash-file approach ever becomes load-bearing in a way that warrants the larger change.

### 0.7 Setup parallelization contract (fire-once-batch)

> **Skip the parallel batch when `concurrency == 1` — but keep the background cleanup group.** At C=1 there is only ever one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Skip the parallel batch (steps 1 → 5) entirely and run them serially. Step 5's failing-PR snapshot is also deferred (see [Step 5](04-backlog-divert.md#5-snapshot-failing-prs)); step 6's scope pre-flight is just-in-time (see [Step 6](06-scope-preflight.md#6-initial-scope-pre-flight)); step 7 fires exactly one dispatch (see [Step 7](07-pool-fill.md#7-initial-pool-fill)). Steps that are still required at C=1:
>
> - **Foreground**: worktree setup (step 0.5), config check (step 0.4), session-state init (step 1.5), trusted-author allowlist (step 1.7), backlog overview (step 2), refine pass (step 3.5), backlog fetch + rank (step 4), divert checks (step 4.5).
> - **Background cleanup group** (the `(...) &` subshell below — also fires at C=1): orphan session-file sweep (step 1.6), orphan orchestrator-worktree sweep ([step 1.6.5](01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees)), label create (step 3a), agent-worktree reap (step 3b), orphan-branch triage (step 3c). These are independent of dispatch coordination — they're recovery work for state stranded by prior crashed sessions, and skipping them at C=1 would mean orphan files / worktrees from earlier C=1 crashes accumulate forever (issue #280 — the failure mode where a single-slot user's machine accrues unreaped orchestrator worktrees across crash-and-restart cycles).
>
> What IS skipped at C=1 is purely the *parallel coordination* machinery — the `step_0_7_parallel_batch` timing window, the fire-once-batch read burst, the pre-population of a candidate pool. The background group `(...) &` itself still fires; its contents are cleanup and never racing with the (single) dispatch slot. Readers should be able to see this gate as the explicit boundary between "C≥2 parallel setup with read burst" and "C=1 serial setup with read calls" — the cleanup background group is on the same side of the gate in both modes.
>
> **Per-step timing brackets stay required at every concurrency level.** The `setup-timing.sh start` / `end` brackets in steps 0.5, 1.7, 3.5, 4, and 6 are NOT "skip when C=1" — they're the data source for the #258 measurement umbrella and the cross-session perf ledger. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (the parallel batch isn't run, so there's nothing to time). Step 6.8's explicit `flush` call also stays required at every concurrency level — though [issue #283](https://github.com/mattsears18/shipyard/issues/283) added auto-flush hooks in `session-state.sh update` and `cost-history.sh flush` as defense in depth, so a forgotten 6.8 no longer silently drops the data.

**Steps 1 → 5 are a graph of read-only `gh` calls with no data dependencies on each other.** Fire them as a single parallel burst — either one `Bash` tool call wrapping `bash -c '... & ... & wait'`, or N parallel `Bash` tool calls in one orchestrator message. A serial walk through steps 1 → 5 is the failure mode this section prevents.

**Timing instrumentation (issue #238).** The parallel batch as a whole is one timing window. Open the window just before firing the burst; close it once `wait` (or all parallel tool calls) return.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
# ... fire all parallel gh calls ...
# ... wait for all to return ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
```

**Canonical setup batch — these reads have no data dependencies:**

- **[Step 1](01-repo-recovery.md#1-resolve-repo--user)** — repo + user metadata (3 `gh` calls).
- **[Step 2](01-repo-recovery.md#2-backlog-overview)** — issue universe (`gh issue list --state open` + `linked:pr` search). **Skipped under `--fast`** — but count refinement candidates (by source-signal scan — `user-feedback` / `## Open questions` / bot author, since the `needs-refinement` label was eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)), `blocked:ci`, `blocked:agent-soft`, and legacy `blocked:agent` issues first (see step 2's `--fast` note). (`blocked:agent-hard` was eliminated in [#521](https://github.com/mattsears18/shipyard/issues/521) — no count.)
- **[Step 3d.1](01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session)** — `blocked:ci` PR list. Per-PR `events` + `commits` lookups are a second-tier parallel batch keyed off the first-tier result. **Skipped under `--fast`** (the initial `gh pr list --label blocked:ci --json number --jq 'length'` count still runs for advisory reporting — see step 3d.1's `--fast` note).
- **[Step 3d.2](01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session)** — five sub-sweeps in sequence: legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521) — dependency-wait → no label, else → `needs-human-review`), `blocked:agent-soft` next-session sweep, and three new legacy-label migration sweeps ([#537](https://github.com/mattsears18/shipyard/issues/537)) for `needs-design` → `needs-human-review`, `needs-decomposition`/`tracking` → `needs-human-review` + decomposition marker, and `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. (Sub-sweep a, the `blocked:agent-hard` referential clear, was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521).) Per-issue blocker-state lookups (sub-sweeps b and f) read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). **Skipped under `--fast`** (the initial label counts still run for advisory reporting — see step 3d.2's `--fast` note).
- **[Step 4.5a](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — main CI status (`gh run list --branch <default-branch> --limit 60`). **Skipped under `--fast`** — `main_ci.status` left as `"unknown"`.
- **[Step 4.5b](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — all-authors failing-PR count. **Skipped under `--fast`** — `failing_pr_count_all` left as `0`.
- **[Step 5](04-backlog-divert.md#5-snapshot-failing-prs)** — `@me` failing-PR snapshot.

**Background bash group (fire-and-forget from step 0.7).** The following steps are cleanup-only — they don't affect dispatch correctness and don't need to complete before the first worker fires. Fire them as a single background subshell immediately after opening the timing window, capture the PID, and let dispatch proceed without waiting:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
(
  # 1.6 — Orphan session-file sweep (cost-ledger recovery). Cleanup-only — recovery
  # of historical ledger data is observational and doesn't affect this session's dispatch.
  # Layered protection (issue #253): the 30-min mtime floor catches files that haven't
  # been written through recently AND the `is-active` PID-liveness check skips files
  # whose owning process is still alive. Both have to fail before reap — protects
  # against the race where a peer orchestrator went quiet for >30 min (long drain,
  # CI watch) but is still actively running and will write through again.
  SESSIONS_DIR="${SHIPYARD_HOME:-$HOME/.shipyard}/sessions"
  find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' -mmin +30 2>/dev/null | while read -r orphan; do
    orphan_id=$(basename "$orphan" .json)
    [[ "$orphan_id" == "<session-id>" ]] && continue
    # PID-liveness gate: if the orchestrator that owns this file is still alive,
    # skip the reap regardless of mtime. is-active exits 0 when the file's .pid
    # is alive (per kill -0). Exit 1 on missing file, missing/null pid, or dead pid.
    if "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" is-active --session-id "$orphan_id" 2>/dev/null; then
      continue
    fi
    "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "$orphan_id" 2>/dev/null || true
    # --reap-audit (issue #281) writes one JSONL line to
    # ~/.shipyard/reap-audit.jsonl capturing the reaped session's
    # pid / repo / tokens / mtime, plus the reaper's session id and pid,
    # so a subsequent "where did my session file go?" investigation has
    # forensic data. The line lands in the same JSONL file as worktree-reap
    # audit entries (issue #284) so a reader can correlate session-file and
    # worktree reaps for the same session.
    "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" cleanup --session-id "$orphan_id" \
      --reap-audit \
      --reaper-session-id "<session-id>" \
      --reason "orphan-sweep-step-1.6" \
      --phase "setup-1.6" 2>/dev/null || true
  done

  # 1.6.5 — Reap orphan orchestrator worktrees (issue #280). Parallel to step 1.6
  # but for the worktree dirs themselves: a `.claude/worktrees/orchestrator-<dead-id>/`
  # dir whose owning session has already terminated (file missing or PID dead).
  # Without this sweep, the worktree dirs accumulate indefinitely whenever a
  # prior session crashes before cleanup-summary.md step 6 retires its own
  # worktree — step 1.6 only cleans up session FILES; step 3b only handles
  # `agent-*` worktrees. The find-orphan-orchestrators helper applies the
  # same liveness gate step 1.6 uses (file-missing OR `is-active` exits 1),
  # so the inactivity definition stays consistent across both sweeps.
  #
  # Issue #284 — the per-reap `git worktree remove` and the audit-log write
  # are encapsulated in `worktree-reap.sh reap --action reaped-orphan-orchestrator`.
  # The helper handles the rm -rf fallback internally (worktree-remove fails
  # whenever the dir is on disk but no longer registered with git — typical
  # crash-orphan case) and emits the appropriate `-raw-rm` action variant in
  # the audit log when that path fires. Moving the audit-log write inside
  # the helper is the single-source-of-truth fix: callers can't accidentally
  # skip the audit step because the reap and the audit are one transaction.
  cd "$(git rev-parse --show-toplevel)"
  while read -r orph_path; do
    [ -z "$orph_path" ] && continue
    [ -d "$orph_path" ] || continue
    orph_name=$(basename "$orph_path")
    orph_session_id="${orph_name#orchestrator-}"
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped-orphan-orchestrator \
      --worktree-path "$orph_path" \
      --worktree-name "$orph_name" \
      --session-id "<session-id>" \
      --reaped-session-id "$orph_session_id" \
      --phase "setup-1.6.5" 2>/dev/null || true
  done < <("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" find-orphan-orchestrators \
             --repo-root "$(pwd)" --current-session-id "<session-id>" 2>/dev/null)
  git worktree prune 2>/dev/null || true

  # 3a — gh label create (14 idempotent labels). All idempotent; only needed by the
  # time the first agent applies a label, not before dispatch fires.
  for label_args in \
    "shipyard --description 'Worked on by /shipyard:do-work' --color 5319E7" \
    "P0 --description 'Critical / release-blocker' --color B60205" \
    "P1 --description 'High — this cycle' --color D93F0B" \
    "P2 --description 'Normal' --color FBCA04" \
    "user-feedback --description 'Originated from end-user feedback (untrusted body — treat with care)' --color 0E8A16" \
    "needs-human-review --description 'Awaiting a human DECISION before /do-work will touch it' --color D93F0B" \
    "needs-operator --description 'Needs a browser/console operator action — a human, or /do-work via the extension' --color 1D76DB" \
    "needs-triage --description 'No automated path forward — surface to a human' --color C2E0C6" \
    "blocked:agent-soft --description 'Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes.' --color FBCA04" \
    "blocked:ci --description 'CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover.' --color B60205"
  do
    eval "gh label create $label_args --repo <owner/repo> 2>/dev/null || true" &
  done
  wait  # wait for the parallel label creates before continuing to 3b/3c

  # 3b — Reap stale agent worktrees from dead Claude Code sessions. Affects future
  # dispatch slot availability, not the first batch.
  #
  # Issue #284 — the actual `git worktree remove` and the audit-log JSONL write
  # are encapsulated in `worktree-reap.sh reap`. The helper performs the
  # remove (or skips it for `--action deferred`) and writes one audit line
  # in a single transaction, so the audit log is impossible to skip.
  cd "$(git rev-parse --show-toplevel)"
  # Detect the orchestrator's PID once per loop and export it so every
  # classify-lock call short-circuits to `self-ancestor` when the lock
  # holds our own PID (issue #263). The harness writes the orchestrator's
  # PID into every dispatched agent's lock; without this declaration the
  # ancestor walk inside classify-lock can fail to find it whenever an
  # intermediate harness layer returns empty PPID.
  export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)
  # Use `find` instead of a bare `agent-*` glob so the loop survives zsh's
  # default `nomatch` option when no agent worktrees exist
  # ([#335](https://github.com/mattsears18/shipyard/issues/335)). Bare globs
  # raise a fatal error under zsh and abort the entire bg subshell —
  # including the remaining cleanup sub-steps (3c orphan-branch triage).
  # `find` exits 0 on no matches; the loop body simply doesn't iterate.
  for wt_dir in $(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null); do
    [ -d "$wt_dir" ] || continue
    name=$(basename "$wt_dir")
    worktree_path=$(git worktree list --porcelain | awk -v n="$name" '/^worktree /{p=$2} /^branch /{b=$2} /^$/{if (p ~ n) print p}' | head -1)
    [ -z "$worktree_path" ] && worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
    [ -z "$worktree_path" ] && continue
    classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" classify-lock "$wt_dir/locked")
    # Extract the lock PID for the audit log (best effort; null literal when
    # the lock file is missing or unparseable).
    lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
    [ -z "$lock_pid" ] && lock_pid="null"
    if [ "$classification" = "peer-alive" ]; then
      "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
        --action deferred \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "<session-id>" \
        --reason "peer-alive" \
        --lock-pid "$lock_pid" \
        --phase "setup-3b" 2>/dev/null || true
      continue
    fi
    git worktree unlock "$worktree_path" 2>/dev/null
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "<session-id>" \
      --classification "$classification" \
      --lock-pid "$lock_pid" \
      --phase "setup-3b" 2>/dev/null || true
  done
  git worktree prune

  # 3c — Orphan worktree triage (discovery + handling). The discovery is cheap;
  # the expensive push/PR-create branch only fires when orphans exist. Neither
  # gates dispatch decisions.
  stale_assigns_count=0
  declare -a stale_assigns_numbers
  git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||' | while read -r branch; do
    path=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
    [ -z "$path" ] && continue
    # Issue #739 — extract the issue number permissively so a collision-
    # fallback LOCAL branch name (`do-work/issue-<N>-<timestamp>`, produced
    # by issue-work.md §3 when a prior worktree still held the canonical
    # name — see #736/#738) still resolves to `<N>`, not the garbage
    # compound string `<N>-<timestamp>`. `canonical_branch` is what the
    # collision-fallback worker actually pushed to and opened its PR
    # against (its own local checkout may be named differently), so every
    # remote/PR lookup below must key off it, never off `$branch` verbatim.
    n=$(echo "$branch" | sed -E 's|^do-work/issue-([0-9]+).*|\1|')
    canonical_branch="do-work/issue-$n"
    ahead=$(git -C "$path" rev-list --count "origin/<default-branch>..HEAD" 2>/dev/null || echo 0)
    if [ "$ahead" -eq 0 ]; then
      # Issue #712 — non-force FIRST, force only behind evidence. `git worktree
      # remove` (no --force) refuses on a dirty tree, which is the exact safety
      # property Claude Code's auto-mode permission classifier is protecting
      # when it denies a bare `--force` as [Irreversible Local Destruction]. The
      # `ahead -eq 0` test immediately above IS the preceding, explicit check
      # that makes the escalation safe here: this worktree carries no commits
      # beyond the base branch, so nothing being force-removed exists only here.
      git worktree remove "$path" 2>/dev/null \
        || git worktree remove --force "$path" 2>/dev/null
      git branch -D "$branch" 2>/dev/null
      gh issue edit "$n" --repo <owner/repo> --remove-assignee @me 2>/dev/null || true
    else
      # Resolve against the CANONICAL remote branch name, not `$branch`
      # verbatim — a collision-fallback worker's local branch carries a
      # disambiguating suffix, but it pushes and opens its PR against
      # `do-work/issue-<N>` (see issue-work.md §3/§5). Checking `$branch`
      # here would never find that push, causing this sweep to push a
      # second, spurious remote branch and then open a duplicate PR.
      pushed=$(git ls-remote --heads origin "$canonical_branch" 2>/dev/null)
      if [ -z "$pushed" ]; then
        git -C "$path" push -u origin "HEAD:refs/heads/$canonical_branch" 2>/dev/null || true
      fi
      open_pr=$(gh pr list --repo <owner/repo> --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)
      if [ -z "$open_pr" ]; then
        (cd "$path" && gh pr create --repo <owner/repo> --head "$canonical_branch" --fill --label shipyard 2>/dev/null) || true
        pr_num=$(gh pr list --repo <owner/repo> --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)
        # #720: gate the arm behind the ungated-merge detector. This PR is a
        # PRIOR session's orphaned branch, opened with `--fill` — nothing in this
        # session ever reviewed its diff. On an ungated repo `--auto` is not a
        # queue; it direct-merges that unreviewed work immediately, and the
        # `2>/dev/null || true` makes it silent. Fail-safe: an unreadable verdict
        # resolves to `ungated` (defer), never to an immediate merge.
        if [ -n "$pr_num" ]; then
          verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" \
            <owner/repo> 2>/dev/null || echo ungated)
          if [ "$verdict" = "gated" ]; then
            gh pr merge "$pr_num" --repo <owner/repo> --auto --merge --delete-branch 2>/dev/null || true
          else
            # Leave OPEN + unarmed. The PR carries `--label shipyard` (above),
            # which is exactly the label drain's deferred-merge lander keys on —
            # so it gets merged on the first poll its checks are green, with no
            # `session_prs` plumbing needed. Do NOT block on `gh pr checks
            # --watch` here: this runs in setup's background cleanup group and a
            # block would stall session start, once per orphan.
            echo "[setup-3c] PR #${pr_num} left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
          fi
        fi
      fi
    fi
  done

  # 3c (row 5) — Stale @me self-assigns with no worktree, no PR, no branch
  # (issue #303). Catches the state the worktree loop above CAN'T see:
  # a prior session that left the @me assignment on an issue after its
  # on-disk worktree was already cleaned up. Without this sweep the
  # assignment survives indefinitely across sessions; the issue silently
  # passes the worker-side step-0 pre-flight (it's still assigned to
  # @me, not someone else) and gets re-dispatched against stale prior-
  # session artifacts. Action is conservative: clear the assignment only,
  # leave the `shipyard` label as provenance, and let the normal step-4
  # backlog fetch pick the issue up on the next dispatch.
  for n in $(gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number --jq '.[].number' 2>/dev/null); do
    # If a worktree for this issue exists, the loop above already handled it;
    # skip. Extract issue numbers from every do-work worktree branch the same
    # permissive way as the loop above (#739) so a collision-fallback local
    # branch name (`do-work/issue-$n-<timestamp>`) is still recognized as
    # "already handled" instead of falling through to the assignee-clear
    # below on an issue whose worktree is alive, just suffixed.
    if git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\/issue-/{print $2}' \
      | sed -E 's|^refs/heads/do-work/issue-([0-9]+).*|\1|' | grep -qx "$n"; then
      continue
    fi
    # If a do-work branch for this issue still exists on origin, leave it
    # alone — it may belong to an open PR the `-linked:pr` filter missed
    # (e.g., draft PR linked via a different reference shape). Conservative
    # gate: only clear assignment when NOTHING in the dispatch artifacts
    # exists for this issue anymore.
    if [ -n "$(git ls-remote --heads origin "do-work/issue-$n" 2>/dev/null)" ]; then
      continue
    fi
    gh issue edit "$n" --repo <owner/repo> --remove-assignee @me 2>/dev/null || true
    stale_assigns_count=$((stale_assigns_count + 1))
    stale_assigns_numbers+=("$n")
  done
) &
SETUP_BACKGROUND_PID=$!
```

The background group handles steps 1.6, 1.6.5, 3a, 3b, and 3c. The parallel batch (steps 1 → 5) and the foreground-serial steps (1.7, 3.5, 4 → 7) all proceed without waiting on `$SETUP_BACKGROUND_PID`. End-of-session cleanup's step 7 (`cost-history.sh flush`) must `wait $SETUP_BACKGROUND_PID` before flushing to ensure the 1.6 orphan sweep has completed — the flush and the sweep both write to `cost-history.jsonl`, and both are idempotent, but the `wait` prevents a double-flush race on the same session file.

**The full execution model after this change:**

```
step 0.7 opens timing window
  ├── background group (SETUP_BACKGROUND_PID) — fire and forget:
  │     1.6   orphan session-file sweep
  │     1.6.5 orphan orchestrator-worktree sweep (issue #280)
  │     3a    gh label creates (parallel within group)
  │     3b    stale worktree reap
  │     3c   orphan worktree triage
  └── foreground parallel batch (steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5)
        └── after batch: step 1.7 → 3.5 → 4 → 4.5 aggregate → 6 → 7 (serial)
```

**Steps that MUST run after the batch (foreground, serial):**

- **[Step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist)** — its output (`trusted_authors`) gates step 2's bucketing and step 4's filter.
- **[Step 3.5](01-repo-recovery.md#35-refine-pending-issues)** — invokes `/refine-issues`, blocks until done. **Skipped under `--fast`**.
- **[Step 4](04-backlog-divert.md#4-fetch--rank-the-backlog)** — the *filtered* backlog fetch (distinct from step 2's universe fetch). Auto-triage label-stamping depends on step 1.7 + step 2.

**Steps 6+ stay serial.** Scope pre-flight (step 6) depends on `raw_backlog` from step 4; initial pool fill (step 7) depends on `ready_issues` from step 6.

The numbered subsection order (1 → 5) is documentation layout — execution is parallel.

### 0.8 `blocker_state` cache (default-on)

Session-local map `blocker_state: { <issue-or-pr-number> → "OPEN" | "CLOSED" | "MERGED" | "unresolvable" }` shared by three setup paths:

- **[Step 2](01-repo-recovery.md#2-backlog-overview) bucket-6** — for every `Blocked by #N` reference in a bucket-6 issue body, `gh issue view <N> --json state` (with `gh pr view <N>` fallback). Cache the result.
- **[Step 3d.2](01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) auto-clear sweep** — same lookups; read-through cache.
- **[Step 2](01-repo-recovery.md#2-backlog-overview) bucket-7** classification — same cache.

Cache lifetime is session-scoped. The cache is a latency optimization; it never gates correctness.

**Cache-miss policy.** Query `gh issue view <N>` first; on `not found`, fall back to `gh pr view <N>`; on both failing, cache `"unresolvable"` (the consumer treats it as "not all closed" — i.e. don't auto-clear). `unresolvable` entries survive subsequent lookups — no retry burst per consumer.

### 0.9 `gh-cached.sh` wrapper (opt-in per call-site)

Within a single orchestrator session (typically 5–15 minutes), GitHub state doesn't change much except for the artifacts shipyard itself is modifying. But the orchestrator re-queries the same data across phases — `gh pr list` at the start of dispatch, again in drain, again in summary; `gh issue list` at backlog fetch and again on the lightweight backlog re-check before every dispatch. Most of those answers haven't changed. `plugins/shipyard/scripts/gh-cached.sh` is a session-scoped wrapper that caches stdout from a `gh` call keyed by its argv, with a caller-supplied TTL, so the redundant re-fetches return from disk instead of re-hitting the GitHub API. Closes [#160](https://github.com/mattsears18/shipyard/issues/160) — phase 3 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**Shape.** Run `gh` through the wrapper instead of calling `gh` directly:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 60 -- \
  gh-args-without-the-gh-prefix
```

The wrapper invokes `gh` itself (the argv after `--` is everything you'd normally pass to `gh`, minus the literal `gh`). Cache files live at `$SHIPYARD_HOME/cache/<session-id>/<sha256-of-argv>`. Cache hit → emits cached stdout, no network call, exit 0. Cache miss → invokes `gh`, streams stdout to disk + caller, exit mirrors `gh`. Non-zero `gh` exits are NOT cached (errors must retry naturally).

**TTL bands per query category.** Caller picks the TTL — no default, because the right freshness depends on the query:

| Query | Suggested TTL | Reasoning |
|---|---|---|
| `gh issue list --state open` (backlog universe) | **60s** | Backlog changes slowly; ephemeral edits to label/title don't change dispatch decisions |
| `gh pr list --state open` (in-flight check, drain snapshot) | **30s** | In-flight PRs change faster — new PRs, mergeStateStatus flips — but minutes of staleness still tolerable |
| `gh pr view <N> --json statusCheckRollup,mergeStateStatus` | **10s** | CI churns fast; the trust-but-verify spot-check and drain reconcile both depend on freshness |
| `gh label list` | **600s** | Labels change once per release |
| `gh api graphql` (batch status, status-rollup queries) | **10s** | Same churn class as per-PR view |
| `gh repo view --json defaultBranchRef` | **3600s** | Default branch rarely changes mid-session |
| `gh api repos/<owner/repo>/collaborators` | **3600s** | Trusted-author resolution is session-scoped already; this is belt-and-braces |

These are *suggestions*. A caller that needs harder freshness should pass a smaller TTL; a caller in a known-quiet section can pass a larger one. The wrapper is intentionally opt-in per call-site — the spec doesn't require every `gh` call to go through it. Use it for the high-volume queries the orchestrator re-runs across phases; leave one-shot queries (e.g. `gh issue view <N>` at scope pre-flight) to call `gh` directly.

**Invalidation on writes.** Whenever shipyard itself does a state-changing call (issue close, PR create, label add, assignee change), the relevant cached reads need to be flushed so subsequent reads see the new state. Two policies:

- **Conservative (default).** Flush the entire session cache after any state-changing call:
  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
  "${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" invalidate --session-id "<session-id>"
  ```
  Burns one extra round of cold reads on the next refresh but never serves stale data after a write. Use this when in doubt — the cost is "one re-read per shipyard write," which is small compared to the savings on the hot read paths.
- **Targeted (advanced).** When the write affects a specific PR or issue and the caller knows which cached reads depend on that artifact, pass `--pattern <sha-prefix>` to invalidate just the matching entries. Practical use is rare — the `--pattern` surface is intentionally narrow because callers don't easily know the sha shape. Stick with the conservative policy unless profiling shows the broad flush dominates.

**End-of-session cleanup.** The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is reaped by the [End-of-session cleanup](../cleanup-summary.md#end-of-session-cleanup) sequence:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" cleanup --session-id "<session-id>"
```

Idempotent. Runs in the same cleanup chain that reaps the session state file — both are session-scoped artifacts under `$SHIPYARD_HOME`.

**Disable for debugging.** `SHIPYARD_GH_CACHE_DISABLED=1` in the environment makes every `run` invocation a live `gh` call with no read or write — useful for confirming "is the cache hiding a real change?" without touching the call-sites. The `stats` subcommand still reads whatever's already on disk; `cleanup` and `invalidate` still operate on the existing dir.

**Observability.** `gh-cached.sh stats --session-id <id>` emits `{"hits": N, "misses": N, "invalidations": N, "bytes": N}` for the session — useful in end-of-session summary blocks and for the cost-tracking ledger when measuring perf wins against the baseline.

### 0.9.1 `gh-batch.sh` GraphQL wrapper (opt-in per call-site)

Where `gh-cached.sh` reduces redundant *re-fetches* across phases, `gh-batch.sh` reduces *fan-out*: N sequential `gh pr view <M>` / `gh issue view <N>` calls collapse to a single `gh api graphql` query with aliased per-record sub-queries. Closes [#159](https://github.com/mattsears18/shipyard/issues/159) — phase 2 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**When to reach for it.** Any call-site that fires `gh pr view <M>` or `gh issue view <N>` in a loop over a known list of numbers is a candidate. Highest-leverage sites today:

- **[Drain phase](../drain.md#drain-protocol) per-poll re-snapshot** — `D_dirty` / `R_new` / `P_settled` reconciles read per-PR fields for a known subset of session_prs every 60s. Use `pr-status` instead of N `gh pr view <M>` calls.
- **[Step 0.8 blocker_state cache](#08-blocker_state-cache-default-on)** — populated lazily today; when N+ entries are missed at once (bucket-6/-7 cold start), `issue-state` fills the cache in one round-trip instead of N.
- **[Step 3d.2](01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) referential-blocker resolution** — the `Blocked by #N` sweep already cache-reads, but cold starts on a large stale-block backlog benefit from batching the lookups via `issue-state` + a single `pr-status` fallback for cases where the referenced number is a PR.
- **Scope pre-flight scoping batches** — when N candidates' issue bodies need a fresh state check before dispatch.

**Shape.**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Batch PR status — same projection as `gh pr view <M> --json
# number,state,mergeable,mergeStateStatus,statusCheckRollup,headRefName,headRefOid`
# but for N PRs in one query. Emits one JSON object keyed by PR number string.
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
  --repo <owner/repo> \
  --numbers "142 143 144"
# → {"142": {"number":142,"state":"OPEN","mergeable":"MERGEABLE",...}, "143": {...}, "144": {...}}

# Batch issue state + labels. Same shape — keyed by issue number string.
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" issue-state \
  --repo <owner/repo> \
  --numbers "100,200,300"
# → {"100": {"number":100,"state":"OPEN","labels":["P1","bug"]}, ...}
```

`--numbers` accepts space- or comma-separated integers. Non-numeric tokens fail loudly (exit 64) — defense in depth against any caller injecting unvalidated user input into the GraphQL body.

**Limits and behavior.**

- **Chunked at 50 aliases per query.** GraphQL has a soft node-cost limit; the wrapper auto-splits large `--numbers` lists into chunks and merges the JSON before emitting. Override via `SHIPYARD_GH_BATCH_CHUNK_SIZE`. Typical orchestrator fan-out (drain ≤10, blocker-state cache cold-start ≤20) fits in a single chunk.
- **Missing artifacts drop silently.** A PR / issue that no longer exists (deleted, transferred, never existed) resolves to a null alias and is dropped from the output — the caller treats a missing key as "not trackable." Never fail the whole batch on one missing number.
- **Failure fails the whole batch.** `gh api graphql` failure (rate limit, 5xx, malformed query) exits 2 with stderr forwarded. No partial output is emitted — callers retry the whole batch, not individual chunks.
- **`mergeable` may return UNKNOWN.** GitHub computes it on-demand; `mergeStateStatus` (`CLEAN` / `DIRTY` / `BLOCKED` / `BEHIND` / `UNSTABLE`) is the more stable signal. Prefer `mergeStateStatus` where possible.

**Composing with `gh-cached.sh`.** The two wrappers compose cleanly: run the batch helper through the cache wrapper to get both fan-in *and* cross-phase memoization. Suggested TTL bands:

| Batch query | Suggested TTL | Reasoning |
|---|---|---|
| `gh-batch.sh pr-status` | **10s** | Same churn class as per-PR `statusCheckRollup` (10s band in [§0.9](#09-gh-cachedsh-wrapper-opt-in-per-call-site)) |
| `gh-batch.sh issue-state` | **30s** | Issue state + labels change much slower than CI |

The compose pattern (cached batch read):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 10 -- \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "142 143 144"
```

Cache hit → no GraphQL call. Cache miss → batched GraphQL call (1 round-trip for up to 50 numbers) cached for the next 10s.
