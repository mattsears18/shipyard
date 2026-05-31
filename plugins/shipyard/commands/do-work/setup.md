# /shipyard:do-work — Setup phase

The session-startup steps (0.4 → 7). Runs once, end of phase hands off to [steady-state](./steady-state.md). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and the [session state file schema](../do-work.md#session-state-file); this file owns the actual setup-step execution.

## Lightweight C=1 path — what's skipped and what stays

Default `--concurrency` is `1`, and at C=1 a substantial chunk of the orchestrator's parallel-coordination machinery is **already skipped** by per-step gates throughout the spec. This section is a single index of those gates so a reader doesn't have to grep across the phase files to assemble the picture — every entry below is implemented by the linked spec callout, not by this section. Closes [#347](https://github.com/mattsears18/shipyard/issues/347).

**The C=1 path is the default.** No flag, no config opt-in — pass `--concurrency 1` (or omit `--concurrency` entirely; `1` is the default) and the gates below fire automatically.

### What's skipped at C=1

| Skipped at C=1 | Why | Owning callout |
|---|---|---|
| Parallel setup batch (`step_0_7_parallel_batch` timing window, the fire-once-batch read burst, pre-population of a candidate pool) | At C=1 there's only one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Steps 1 → 5 run serially instead. | [step 0.7](#07-setup-parallelization-contract-fire-once-batch) |
| Initial failing-PR snapshot (step 5) | The failing-PR set is only relevant when there's a free slot to dispatch a fix-checks worker against it, and at C=1 the slot is guaranteed to be free between dispatches. Defer the query to the first idle turn in steady-state's step D. | [step 5](#5-snapshot-failing-prs) |
| Batched initial scope pre-flight (step 6's `2 × concurrency` pre-flight) | At C=1 pre-flighting 2 candidates upfront is wasted token spend — by the time the single slot returns, rankings may have shifted and pre-flighted decisions are stale. Pre-flight only the top candidate immediately before each dispatch instead. | [step 6](#6-initial-scope-pre-flight) |
| Initial pool fill burst (step 7's parallel `Agent` burst across N slots) | The "pool" is a single slot. Dispatch exactly one worker via the same dispatch rules; no `run_in_background: true` needed. | [step 7](#7-initial-pool-fill) |
| Path-collision check (step C's `claimed_paths.hard` ∩ `in_flight` pass) | The check is a pure overhead pass that always resolves to "no collision" because `in_flight` is either empty or holds exactly one slot (the current worker, which has already been released by step B before step C runs). | [steady-state.md step C — Hard collision](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) |
| Soft-cap counter (the `--soft-collision-concurrency` tier) | No main-concurrency cap to burst past and no peer slots to share a path with. Don't track `claimed_paths.soft`, don't decrement on return, don't consult the soft cap. | [steady-state.md step C — Soft collision](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) |
| Section-aware lockfile-collision check (`lockfile_sections` claim-and-check) | No peer slots and no contention on any lockfile section — the check always resolves to "no collision." The scope pre-flight still returns `lockfile_sections` in its ready shape so the session-state schema remains valid, but the orchestrator ignores the field at dispatch time. | [steady-state.md step C — Section-aware lockfile rule](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) |
| Rolling scope-refill background burst (step D's `2 × concurrency` background scope agents) | The just-in-time per-dispatch scope call (above) is the C=1 equivalent. `scope_bg_count` stays `0` and the per-dispatch JIT call is synchronous. | [step 6 C=1 note](#6-initial-scope-pre-flight) (see also the in-state struct ref at [`scope_bg_count`](../do-work.md#orchestrator-state)) |

### What stays at C=1

These steps are **not** gated by concurrency — they fire identically at C=1 and C≥2:

- **Worktree relocation (step 0.5).** The orchestrator runs in its own isolated worktree at every concurrency level. This is the lock against `/do-work` running concurrently in the user's primary checkout (the threat the [worktree-isolation contract](./dont.md) names), and the safety property is independent of how many workers the orchestrator dispatches.
- **Config opt-in check (step 0.4).** The merged 4-layer config is read once at session start regardless of concurrency — defaults / pricing / model overrides / auto-merge policy all apply at C=1 too.
- **Session-state init (step 1.5) + every write-through.** The session-state JSON file is the durable record that [`/shipyard:status`](../status.md), the orphan session-file sweep, the cost-tracking comments, and a future `--resume <session-id>` flag all read from. The mirror fires whether the session has one slot or four.
- **Trusted-author allowlist (step 1.7) + bucket 0.5 + step 4 client-side filter.** Author trust is the security gate against prompt-injection from stranger-authored issues. It fires before dispatch at every concurrency level; lowering it for "single-trusted-author personal repo" sessions would defeat the defense-in-depth posture documented in [`dont.md`'s security boundary](./dont.md).
- **Background cleanup group (the `(...) &` subshell in step 0.7).** The orphan session-file sweep (1.6), orphan orchestrator-worktree sweep (1.6.5), label create (3a), agent-worktree reap (3b), and orphan-branch triage (3c) all run in a single background subshell at every concurrency level. Skipping them at C=1 would mean orphan files / worktrees from earlier C=1 crashes accumulate forever (issue [#280](https://github.com/mattsears18/shipyard/issues/280)).
- **Per-step setup-timing brackets** (`setup-timing.sh start` / `end` calls in steps 0.5, 1.7, 3.5, 4, 6). These are the data source for the [#258](https://github.com/mattsears18/shipyard/issues/258) measurement umbrella and the cross-session perf ledger — kept at every level. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (there's nothing to time when the batch doesn't run).
- **Backlog fetch + rank + triage (step 4), divert checks (step 4.5).** The dispatch queues still need to exist and stay current at C=1; only the parallel coordination over the *fill* changes.
- **Drain + cleanup + end-of-session summary.** Drain semantics are identical at C=1 — the per-poll merge-train watcher, the fix-rebase dispatch for `D_dirty`, the progress-based exit + `max_drain_hours` ceiling, the end-of-session HTML report — all apply unchanged.

### When the inline-trivial fast path **also** fires (orthogonal to C=1)

The C=1 path above is about *what the orchestrator does for any candidate at C=1*. The [inline-trivial fast path](./inline-trivial.md) is a **separate, orthogonal** dispatch-time optimization that fires for *some candidates* (typos, dep-bumps, doc-only, comment-only, config-tweak — pattern-matched) when `inline_trivial.enabled == true` in config. Inline-trivial works at every concurrency level, requires opt-in via config (default OFF), and is **conservative-by-default** with strict eligibility rules (body ≤ 200 chars, no headings, no long code fences, no disqualifying labels, trusted author). Don't confuse the two: C=1 is "the orchestrator runs sequentially with no parallel-coordination overhead"; inline-trivial is "for this specific candidate, the orchestrator runs the work inline instead of dispatching a worker." A session can be C=1 with inline-trivial off (the default), C=1 with inline-trivial on, C≥2 with inline-trivial off, or C≥2 with inline-trivial on — every combination is valid and the two optimizations stack.

### When to pick C=1 vs C≥2

C=1 is the default and the right choice for most personal-repo backlogs because the dominant failure mode is the manifest / version-row hard collision documented in the [thin entry's `--concurrency` flag docs](../do-work.md#args). Pick `--concurrency 2+` only when realized parallelism is genuinely real — a feature-development backlog against a service with no per-PR version bump, where two workers can land truly independent changes simultaneously without colliding on `package.json` or `CHANGELOG.md`. The [#268](https://github.com/mattsears18/shipyard/issues/268) dogfooding rationale walks through the empirical observation that drove the default.

## Setup (run once)

### 0.3 `CLAUDE_PLUGIN_ROOT` re-export preamble (every Bash-tool call)

**The harness does not propagate `$CLAUDE_PLUGIN_ROOT` into the Bash-tool subprocess shells.** Verified deterministically against this repo as `do-work-20260525T142439Z-64308` ([#354](https://github.com/mattsears18/shipyard/issues/354)): the env var that's documented as the canonical "where is the installed plugin" pointer expands to the **empty string** inside every Bash-tool call. The very first templated invocation of `/shipyard:do-work` — step 0.4's `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists` — therefore evaluates as `/scripts/shipyard-config.sh` and exits 127 (`no such file or directory`). Every subsequent script invocation in setup / steady-state / drain / cleanup-summary / inline-trivial would fail the same way.

This is the same class of harness-env friction as [#322](https://github.com/mattsears18/shipyard/issues/322) (`$WORKTREE_PATH` not persisting across Bash tool calls): each Bash tool call is hermetic — variables you set in call N are NOT visible in call N+1, and `export` in call N does not persist. Setting the env var once at session start doesn't help.

**The fix is an idempotent preamble at the top of every Bash snippet that references `${CLAUDE_PLUGIN_ROOT}/scripts/...`:**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
```

Semantics:

- **When the harness DOES set `$CLAUDE_PLUGIN_ROOT`** (slash-command launch contexts, future harness fixes, manual `export` for testing) — the `${VAR:-default}` short-circuits and the export is a no-op. Subsequent `${CLAUDE_PLUGIN_ROOT}/scripts/...` calls resolve to the harness-provided installed-plugin path.
- **When the harness does NOT set it** (the observed steady-state for every Bash-tool call inside this orchestrator) — the fallback derives the path from `git rev-parse --show-toplevel + /plugins/shipyard`. Inside the orchestrator's worktree (or the user's primary checkout), this resolves to the repo-local plugin source — which IS the plugin tree the orchestrator wants to execute (we're running the spec from the same repo we're orchestrating against).

**Defense in depth — the helpers also self-locate.** Every script under `plugins/shipyard/scripts/*.sh` resolves sibling-script paths via `BASH_SOURCE[0]`, not via `$CLAUDE_PLUGIN_ROOT`. The preamble only fixes layer 1 (how the orchestrator *invokes* a script); layer 2 (how a script finds its peers) was already correct. Together the two layers mean a templated invocation works regardless of how the harness configures (or fails to configure) the env var.

**Every bash block in this file (and `steady-state.md` / `drain.md` / `cleanup-summary.md` / `inline-trivial.md`) that uses `${CLAUDE_PLUGIN_ROOT}` already carries this preamble as its first line.** Don't strip it; don't move it after the first `${CLAUDE_PLUGIN_ROOT}/...` usage; don't substitute a different fallback path. The pattern is regression-guarded by [`scripts/tests/claude-plugin-root-preamble.test.sh`](../../scripts/tests/claude-plugin-root-preamble.test.sh) — any new bash block that references `${CLAUDE_PLUGIN_ROOT}` without the preamble at its top fails CI.

### 0.4 Check the repo-level opt-in (`shipyard.config.json`)

**Run this BEFORE the worktree relocation.** The check is a single `shipyard-config.sh exists` call against the user's primary checkout — read-only, no writes, so the worktree-isolation rule doesn't apply yet.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
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

**The `exists == 0` but `load` fails branch ([#367](https://github.com/mattsears18/shipyard/issues/367)).** A repo can be shipyard-initialized (`exists` returns 0) yet have a `shipyard.config.json` that fails schema validation — a typo'd enum value, an unknown top-level key, a missing required field. Before #367 the `case 0)` branch captured `load`'s stdout unconditionally; on a schema failure stdout is empty and the exit code (70) was discarded, so `EFFECTIVE_CONFIG` silently became `""` and every downstream `shipyard-config.sh get` fell back to built-in defaults with no warning — the user's per-repo trust list, auto-merge policy, and cost-tracking knobs all quietly ignored for the entire session. The branch above now captures the loader's exit code and stderr, prints a **loud one-line warning naming the rejected field(s)** plus which config keys are defaulting as a result, and records the failure detail in the session-local `SHIPYARD_CONFIG_SCHEMA_FAILURE` variable so the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) surfaces the same line. The fall-through to defaults is unchanged (still conservative-by-design — `auto_merge.policy=trusted-only`, trust resolution via the live collaborators API); the only behavioral change is that the degrade is now *visible* at both step 0.4 and end-of-session.

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
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
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

**From this point on, every subsequent `Bash` / `Edit` / `Write` tool call in the orchestrator's session runs with `<repo-root>/.claude/worktrees/orchestrator-<session-id>` as cwd.** Prepend `cd "$ORCH_WT" && ` (or pass `-C "$ORCH_WT"` to git) for any command whose effect lands on disk or on a branch ref. The user's primary checkout's HEAD MUST NOT change during this session — if you find yourself running a write-class command in the primary checkout, back up, switch to the orchestrator worktree, retry. See [RATIONALE → Why a dedicated worktree](../do-work-RATIONALE.md#step-05--why-a-dedicated-orchestrator-worktree) for the failure modes this prevents.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
# Close the step_0_5_worktree timing window.
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

End-of-session cleanup also runs from the orchestrator worktree, and reaps the orchestrator's own worktree last — see [End-of-session cleanup](./cleanup-summary.md#end-of-session-cleanup) below.

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

Equivalently — when `$ORCH_WT` isn't already in scope but the cwd is inside the orchestrator worktree — derive the worktree root via `git rev-parse --show-toplevel` and read from there:

```bash
SESSION_ID=$(cat "$(git rev-parse --show-toplevel)/.shipyard-session-id")
```

**Defense in depth — `session-state.sh` enforces a cross-repo write guard.** Even if the orchestrator's id-stash mechanism is bypassed or corrupted, `session-state.sh update` and `session-state.sh bump-tokens` accept an `--expected-repo <owner/repo>` flag (also accepted via `SHIPYARD_EXPECTED_REPO=<owner/repo>` env var). When the flag is set and the resolved session file's `.repo` field doesn't match, the call exits 66 with a loud stderr log naming both repos — refusing the write rather than silently corrupting another session's state. The orchestrator SHOULD pass `--expected-repo <owner/repo>` on every `update` and `bump-tokens` call; the `--skip-repo-check` flag is reserved for the rare legitimate cross-repo helper (e.g., the orphan-sweep at step 1.6, which intentionally operates on session files belonging to other repos). See [session-state.sh's cross-repo guard](../../scripts/session-state.sh) for the exit-code contract.

**Don't reach for option 2 from #365** ("skip the file entirely, compute the session id from the worktree path"). The compute-from-worktree-path approach is appealing in theory but invasive in practice — the orchestrator's many Bash tool calls would all need to walk `git worktree list` to find their worktree, parse the orchestrator-<id> suffix, and handle the edge cases where the cwd isn't inside an orchestrator worktree (foreground vs. background subshells, the user's primary-checkout invocation, etc.). The per-worktree stash file is the minimum-surgery shim that addresses the race without redesigning the lookup pattern. Reserve compute-from-worktree-path for a follow-up issue if the stash-file approach ever becomes load-bearing in a way that warrants the larger change.

### 0.7 Setup parallelization contract (fire-once-batch)

> **Skip the parallel batch when `concurrency == 1` — but keep the background cleanup group.** At C=1 there is only ever one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Skip the parallel batch (steps 1 → 5) entirely and run them serially. Step 5's failing-PR snapshot is also deferred (see [Step 5](#5-snapshot-failing-prs)); step 6's scope pre-flight is just-in-time (see [Step 6](#6-initial-scope-pre-flight)); step 7 fires exactly one dispatch (see [Step 7](#7-initial-pool-fill)). Steps that are still required at C=1:
>
> - **Foreground**: worktree setup (step 0.5), config check (step 0.4), session-state init (step 1.5), trusted-author allowlist (step 1.7), backlog overview (step 2), refine pass (step 3.5), backlog fetch + rank (step 4), divert checks (step 4.5).
> - **Background cleanup group** (the `(...) &` subshell below — also fires at C=1): orphan session-file sweep (step 1.6), orphan orchestrator-worktree sweep ([step 1.6.5](#165-reap-orphan-orchestrator-worktrees)), label create (step 3a), agent-worktree reap (step 3b), orphan-branch triage (step 3c). These are independent of dispatch coordination — they're recovery work for state stranded by prior crashed sessions, and skipping them at C=1 would mean orphan files / worktrees from earlier C=1 crashes accumulate forever (issue #280 — the failure mode where a single-slot user's machine accrues unreaped orchestrator worktrees across crash-and-restart cycles).
>
> What IS skipped at C=1 is purely the *parallel coordination* machinery — the `step_0_7_parallel_batch` timing window, the fire-once-batch read burst, the pre-population of a candidate pool. The background group `(...) &` itself still fires; its contents are cleanup and never racing with the (single) dispatch slot. Readers should be able to see this gate as the explicit boundary between "C≥2 parallel setup with read burst" and "C=1 serial setup with read calls" — the cleanup background group is on the same side of the gate in both modes.
>
> **Per-step timing brackets stay required at every concurrency level.** The `setup-timing.sh start` / `end` brackets in steps 0.5, 1.7, 3.5, 4, and 6 are NOT "skip when C=1" — they're the data source for the #258 measurement umbrella and the cross-session perf ledger. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (the parallel batch isn't run, so there's nothing to time). Step 6.8's explicit `flush` call also stays required at every concurrency level — though [issue #283](https://github.com/mattsears18/shipyard/issues/283) added auto-flush hooks in `session-state.sh update` and `cost-history.sh flush` as defense in depth, so a forgotten 6.8 no longer silently drops the data.

**Steps 1 → 5 are a graph of read-only `gh` calls with no data dependencies on each other.** Fire them as a single parallel burst — either one `Bash` tool call wrapping `bash -c '... & ... & wait'`, or N parallel `Bash` tool calls in one orchestrator message. A serial walk through steps 1 → 5 is the failure mode this section prevents.

**Timing instrumentation (issue #238).** The parallel batch as a whole is one timing window. Open the window just before firing the burst; close it once `wait` (or all parallel tool calls) return.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
# ... fire all parallel gh calls ...
# ... wait for all to return ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
```

**Canonical setup batch — these reads have no data dependencies:**

- **[Step 1](#1-resolve-repo--user)** — repo + user metadata (3 `gh` calls).
- **[Step 2](#2-backlog-overview)** — issue universe (`gh issue list --state open` + `linked:pr` search). **Skipped under `--fast`** — but count `needs-refinement`, `blocked:ci`, `blocked:agent-hard`, `blocked:agent-soft`, and legacy `blocked:agent` issues first (see step 2's `--fast` note).
- **[Step 3d.1](#3-ensure-label-exists--recover-from-prior-session)** — `blocked:ci` PR list. Per-PR `events` + `commits` lookups are a second-tier parallel batch keyed off the first-tier result. **Skipped under `--fast`** (the initial `gh pr list --label blocked:ci --json number --jq 'length'` count still runs for advisory reporting — see step 3d.1's `--fast` note).
- **[Step 3d.2](#3-ensure-label-exists--recover-from-prior-session)** — three sub-sweeps in sequence: `blocked:agent-hard` referential clear, legacy `blocked:agent` → `-hard` migration, `blocked:agent-soft` next-session sweep. Per-issue blocker-state lookups (sub-sweep a) read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). **Skipped under `--fast`** (the initial label counts still run for advisory reporting — see step 3d.2's `--fast` note).
- **[Step 4.5a](#45-divert-checks-main-ci--pr-pileup)** — main CI status (`gh run list --branch <default-branch> --limit 60`). **Skipped under `--fast`** — `main_ci.status` left as `"unknown"`.
- **[Step 4.5b](#45-divert-checks-main-ci--pr-pileup)** — all-authors failing-PR count. **Skipped under `--fast`** — `failing_pr_count_all` left as `0`.
- **[Step 5](#5-snapshot-failing-prs)** — `@me` failing-PR snapshot.

**Background bash group (fire-and-forget from step 0.7).** The following steps are cleanup-only — they don't affect dispatch correctness and don't need to complete before the first worker fires. Fire them as a single background subshell immediately after opening the timing window, capture the PID, and let dispatch proceed without waiting:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
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

  # 3a — gh label create (12 idempotent labels). All idempotent; only needed by the
  # time the first agent applies a label, not before dispatch fires.
  for label_args in \
    "shipyard --description 'Worked on by /shipyard:do-work' --color 5319E7" \
    "P0 --description 'Critical / release-blocker' --color B60205" \
    "P1 --description 'High — this cycle' --color D93F0B" \
    "P2 --description 'Normal' --color FBCA04" \
    "user-feedback --description 'Originated from end-user feedback (untrusted body — treat with care)' --color 0E8A16" \
    "needs-refinement --description 'Pipeline gate — issue not ready for /do-work; /refine-issues processes it' --color FBCA04" \
    "needs-human-review --description 'Awaiting human sign-off before /do-work will touch it' --color D93F0B" \
    "needs-triage --description 'No automated path forward — surface to a human' --color C2E0C6" \
    "blocked:agent-hard --description 'Worker returned a security/scope/prompt-injection refuse — needs human review before retry. Hides from workable queue across sessions.' --color B60205" \
    "blocked:agent-soft --description 'Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes.' --color FBCA04" \
    "blocked:agent --description 'Legacy (pre-#300) — migrated to blocked:agent-hard at next session' --color C5DEF5" \
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
    ahead=$(git -C "$path" rev-list --count "origin/<default-branch>..HEAD" 2>/dev/null || echo 0)
    if [ "$ahead" -eq 0 ]; then
      git worktree remove --force "$path" 2>/dev/null
      git branch -D "$branch" 2>/dev/null
      issue_num=$(echo "$branch" | sed 's|do-work/issue-||')
      gh issue edit "$issue_num" --repo <owner/repo> --remove-assignee @me 2>/dev/null || true
    else
      pushed=$(git ls-remote --heads origin "$branch" 2>/dev/null)
      if [ -z "$pushed" ]; then
        git -C "$path" push -u origin "$branch" 2>/dev/null || true
      fi
      open_pr=$(gh pr list --repo <owner/repo> --head "$branch" --json number --jq '.[0].number' 2>/dev/null)
      if [ -z "$open_pr" ]; then
        (cd "$path" && gh pr create --repo <owner/repo> --fill --label shipyard 2>/dev/null) || true
        pr_num=$(gh pr list --repo <owner/repo> --head "$branch" --json number --jq '.[0].number' 2>/dev/null)
        [ -n "$pr_num" ] && gh pr merge "$pr_num" --repo <owner/repo> --auto --merge --delete-branch 2>/dev/null || true
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
    # If a worktree for this issue exists, the loop above already handled it; skip.
    if git worktree list --porcelain | grep -q "refs/heads/do-work/issue-$n$"; then
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

- **[Step 1.7](#17-resolve-trusted-author-allowlist)** — its output (`trusted_authors`) gates step 2's bucketing and step 4's filter.
- **[Step 3.5](#35-refine-pending-issues)** — invokes `/refine-issues`, blocks until done. **Skipped under `--fast`**.
- **[Step 4](#4-fetch--rank-the-backlog)** — the *filtered* backlog fetch (distinct from step 2's universe fetch). Auto-triage label-stamping depends on step 1.7 + step 2.

**Steps 6+ stay serial.** Scope pre-flight (step 6) depends on `raw_backlog` from step 4; initial pool fill (step 7) depends on `ready_issues` from step 6.

The numbered subsection order (1 → 5) is documentation layout — execution is parallel.

### 0.8 `blocker_state` cache (default-on)

Session-local map `blocker_state: { <issue-or-pr-number> → "OPEN" | "CLOSED" | "MERGED" | "unresolvable" }` shared by three setup paths:

- **[Step 2](#2-backlog-overview) bucket-6** — for every `Blocked by #N` reference in a bucket-6 issue body, `gh issue view <N> --json state` (with `gh pr view <N>` fallback). Cache the result.
- **[Step 3d.2](#3-ensure-label-exists--recover-from-prior-session) auto-clear sweep** — same lookups; read-through cache.
- **[Step 2](#2-backlog-overview) bucket-7** classification — same cache.

Cache lifetime is session-scoped. The cache is a latency optimization; it never gates correctness.

**Cache-miss policy.** Query `gh issue view <N>` first; on `not found`, fall back to `gh pr view <N>`; on both failing, cache `"unresolvable"` (the consumer treats it as "not all closed" — i.e. don't auto-clear). `unresolvable` entries survive subsequent lookups — no retry burst per consumer.

### 0.9 `gh-cached.sh` wrapper (opt-in per call-site)

Within a single orchestrator session (typically 5–15 minutes), GitHub state doesn't change much except for the artifacts shipyard itself is modifying. But the orchestrator re-queries the same data across phases — `gh pr list` at the start of dispatch, again in drain, again in summary; `gh issue list` at backlog fetch and again on the lightweight backlog re-check before every dispatch. Most of those answers haven't changed. `plugins/shipyard/scripts/gh-cached.sh` is a session-scoped wrapper that caches stdout from a `gh` call keyed by its argv, with a caller-supplied TTL, so the redundant re-fetches return from disk instead of re-hitting the GitHub API. Closes [#160](https://github.com/mattsears18/shipyard/issues/160) — phase 3 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**Shape.** Run `gh` through the wrapper instead of calling `gh` directly:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
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
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
  "${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" invalidate --session-id "<session-id>"
  ```
  Burns one extra round of cold reads on the next refresh but never serves stale data after a write. Use this when in doubt — the cost is "one re-read per shipyard write," which is small compared to the savings on the hot read paths.
- **Targeted (advanced).** When the write affects a specific PR or issue and the caller knows which cached reads depend on that artifact, pass `--pattern <sha-prefix>` to invalidate just the matching entries. Practical use is rare — the `--pattern` surface is intentionally narrow because callers don't easily know the sha shape. Stick with the conservative policy unless profiling shows the broad flush dominates.

**End-of-session cleanup.** The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is reaped by the [End-of-session cleanup](./cleanup-summary.md#end-of-session-cleanup) sequence:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" cleanup --session-id "<session-id>"
```

Idempotent. Runs in the same cleanup chain that reaps the session state file — both are session-scoped artifacts under `$SHIPYARD_HOME`.

**Disable for debugging.** `SHIPYARD_GH_CACHE_DISABLED=1` in the environment makes every `run` invocation a live `gh` call with no read or write — useful for confirming "is the cache hiding a real change?" without touching the call-sites. The `stats` subcommand still reads whatever's already on disk; `cleanup` and `invalidate` still operate on the existing dir.

**Observability.** `gh-cached.sh stats --session-id <id>` emits `{"hits": N, "misses": N, "invalidations": N, "bytes": N}` for the session — useful in end-of-session summary blocks and for the cost-tracking ledger when measuring perf wins against the baseline.

### 0.9.1 `gh-batch.sh` GraphQL wrapper (opt-in per call-site)

Where `gh-cached.sh` reduces redundant *re-fetches* across phases, `gh-batch.sh` reduces *fan-out*: N sequential `gh pr view <M>` / `gh issue view <N>` calls collapse to a single `gh api graphql` query with aliased per-record sub-queries. Closes [#159](https://github.com/mattsears18/shipyard/issues/159) — phase 2 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**When to reach for it.** Any call-site that fires `gh pr view <M>` or `gh issue view <N>` in a loop over a known list of numbers is a candidate. Highest-leverage sites today:

- **[Drain phase](./drain.md#drain-protocol) per-poll re-snapshot** — `D_dirty` / `R_new` / `P_settled` reconciles read per-PR fields for a known subset of session_prs every 60s. Use `pr-status` instead of N `gh pr view <M>` calls.
- **[Step 0.8 blocker_state cache](#08-blocker_state-cache-default-on)** — populated lazily today; when N+ entries are missed at once (bucket-6/-7 cold start), `issue-state` fills the cache in one round-trip instead of N.
- **[Step 3d.2](#3-ensure-label-exists--recover-from-prior-session) referential-blocker resolution** — the `Blocked by #N` sweep already cache-reads, but cold starts on a large stale-block backlog benefit from batching the lookups via `issue-state` + a single `pr-status` fallback for cases where the referenced number is a PR.
- **Scope pre-flight scoping batches** — when N candidates' issue bodies need a fresh state check before dispatch.

**Shape.**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
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
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 10 -- \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "142 143 144"
```

Cache hit → no GraphQL call. Cache miss → batched GraphQL call (1 round-trip for up to 50 numbers) cached for the next 10s.

### 1. Resolve repo + user

These three reads are part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5, not serially before them.

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
gh api user -q .login                                  # the gh-authenticated user
gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name   # default branch (cached as <default-branch>)
```

Cache all three for the session.

(The trusted-author allowlist used by step 4's filter and step 7's `originating_author_trust` computation is populated separately by [step 1.7 below](#17-resolve-trusted-author-allowlist).)

### 1.5 Initialise the session state file

Stand up the durable JSON mirror (see [Session state file](../do-work.md#session-state-file)). One-shot setup write — every subsequent mutation routes through `session-state.sh update`.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
# <session-id> is the orchestrator's session identifier — the same value
# step 0.5 used in the orchestrator-worktree path. Stable across the run.
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" init \
  --session-id "<session-id>" \
  --repo "<owner/repo>" \
  --concurrency <N from --concurrency arg> \
  --soft-collision-concurrency <N from --soft-collision-concurrency arg>
```

The file lands at `$SHIPYARD_HOME/sessions/<session-id>.json` (default: `~/.shipyard/sessions/<session-id>.json`). The default config above is the entire schema with empty queues + an `unknown` `main_ci` state — everything else gets filled in by later setup steps and the steady-state loop.

**If `init` returns exit code 2** ("file already exists"), call `init --force` to clobber the stale file. Log `[session-state] --force overrode stale state file from <prior session>`.

**If `init` returns 65+** (jq missing, permission denied, etc.), continue without the session-state file. The invariant line emits `state=disabled` to make the degradation visible. Don't block the session on file-write failure.

### 1.6 Reap orphan session files (cost-ledger recovery)

> **Background step.** This step runs inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. The canonical code lives in the background group above; this section documents the intent, race-safety rules, and skip condition. Do NOT duplicate the implementation here.

**Sweep `$SHIPYARD_HOME/sessions/` for orphan files left behind by prior sessions that crashed or exited without running [`cleanup-summary.md`'s step 7 → step 8 flush + cleanup chain](./cleanup-summary.md#end-of-session-cleanup).** Without this sweep, any session that doesn't terminate via the happy-path cleanup strands its per-session ledger on disk forever — the cross-session reports at `/shipyard:cost report` then under-count by full sessions. See [issue #227](https://github.com/mattsears18/shipyard/issues/227) for the regression where a multi-PR `lightwork` session's `$11.47` of tracked spend never landed in `~/.shipyard/cost-history.jsonl`.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
# Find session files that aren't the current session and haven't been
# modified in the last 30 minutes (the 30-min floor is a race-safety
# margin against a concurrent /do-work session that's about to flush its
# own file — we never reap something another orchestrator might still
# be writing to). Stacked with a PID-liveness check (`is-active`) for
# defense in depth — see issue #253 for the failure mode where the
# mtime floor alone was insufficient.
SESSIONS_DIR="${SHIPYARD_HOME:-$HOME/.shipyard}/sessions"
find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' -mmin +30 2>/dev/null | while read -r orphan; do
  orphan_id=$(basename "$orphan" .json)
  if [[ "$orphan_id" == "<session-id>" ]]; then
    continue  # skip our own session
  fi
  # PID-liveness gate (#253). is-active exits 0 when the session file's
  # `.pid` is alive (per `kill -0 $pid`); exit 1 otherwise (missing file,
  # missing/null pid, dead pid). If the owning process is alive, skip the
  # reap regardless of mtime — defends against the race where a quiet-but-
  # alive orchestrator's file would otherwise get reaped during a long
  # drain phase or CI watch (the failure trace in #253). PID recycling is
  # still possible but the mtime floor above is the second gate against
  # that — both have to fail to reap, so a recycled pid + fresh mtime
  # scenario still skips.
  if "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" is-active --session-id "$orphan_id" 2>/dev/null; then
    echo "[orphan-reap] skipped $orphan_id (pid alive)"
    continue
  fi
  # Flush is idempotent — re-flushing a session id already in the ledger
  # is a no-op. Cleanup is also idempotent.
  "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "$orphan_id" 2>/dev/null || true
  # --reap-audit (issue #281) records one JSONL line per reap to
  # ~/.shipyard/reap-audit.jsonl with the reaped session's metadata
  # (pid, repo, tokens, mtime) + the reaper's session-id / pid. Without
  # this line, a "where did my session file go?" investigation has no
  # forensic trail. Same JSONL file as worktree-reap.sh's audit log (#284).
  "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" cleanup --session-id "$orphan_id" \
    --reap-audit \
    --reaper-session-id "<session-id>" \
    --reason "orphan-sweep-step-1.6" \
    --phase "setup-1.6" 2>/dev/null || true
  echo "[orphan-reap] flushed + reaped $orphan_id"
done
```

Both helpers are idempotent and exit 0 on already-flushed / already-reaped sessions, so this sweep is safe to re-run. The 30-minute floor is the race-safety boundary against a concurrent `/do-work` orchestrator in another terminal that's about to flush its own file — we never reap something another orchestrator might still be writing to. (Concurrent orchestrators are uncommon but possible — multiple repos, multiple terminals; the floor is the cheap safe default.)

**Two gates, not one (issue #253).** The mtime floor alone failed in production when an orchestrator went quiet for >30 minutes during a long drain phase — the peer's sweep then reaped the still-active session's state file mid-write. The fix layers a PID-liveness gate (`session-state.sh is-active`) **before** the mtime check: if the owning process is alive, skip the reap regardless of mtime. The `.pid` field is stamped into the session file at `session-state.sh init` time (defaulting to `$PPID`, overridable via `--pid <N>`). `is-active` reads that field and runs `kill -0 $pid` to check liveness. Both gates have to fail before a file is reaped, so even a recycled-pid + recent-mtime scenario (the only known failure mode of `is-active`) still skips. Sessions written by older shipyard versions have no `.pid` field — `is-active` exits 1 in that case, falling through to mtime-only behaviour for the migration period.

**Cost-tracking degraded-recovery (issue #253's workaround, extended by #281).** Workers calling `session-state.sh bump-tokens` against a session whose file was reaped mid-session can pass `--allow-degraded-init` (with optional `--degraded-init-repo <r>`) to auto-recreate a fresh state file marked with `.degraded_recovery_at` rather than erroring exit-3. [Issue #281](https://github.com/mattsears18/shipyard/issues/281) extended the same flag to `session-state.sh update` — the orchestrator's working-memory mirror writes now survive a mid-session disappear without forcing a manual `init --force`. Data from before the disappear is lost (the file was gone), but every write from the disappear forward lands somewhere durable. Callers that want strict "must-have-pre-existing-file" semantics simply omit the flag — the original exit-3 behaviour is preserved by default so silent typos / wrong-session-id mistakes still surface.

**Reap-audit logging (issue #281).** When step 1.6 reaps a peer's session file, it now calls `cleanup --reap-audit --reaper-session-id <session-id>`, which captures the reaped file's metadata (pid, repo, tokens.totals, degraded_attribution_count, mtime, started_at, updated_at) and writes one JSONL line to `~/.shipyard/reap-audit.jsonl` with `action: "reaped-session-file"`. Same audit-log file as worktree-reap.sh emits (issue #284), so a reader can correlate session-file reaps with worktree reaps for the same session id. Without this, a "where did my session file go?" investigation has no forensic trail — just the symptomatic `exit 3` from a downstream write. The audit-log write is fire-and-forget — a permission error / disk-full / corrupt source JSON never aborts the reap (the reap itself is the load-bearing work; the audit line is observability).

**Don't block the session on sweep failures** — log `[orphan-reap] <reason>` and proceed. Recovery of historical data is observational; the dispatch loop's job comes first. If `SHIPYARD_KEEP_SESSIONS=1` is set (per the [step 8 cleanup-summary opt-out](./cleanup-summary.md#end-of-session-cleanup)), skip the sweep entirely — the user explicitly opted into keeping session files as permanent records.

### 1.6.5 Reap orphan orchestrator worktrees

> **Background step.** This step runs inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. The canonical code lives in the background group above; this section documents the intent, race-safety rules, and skip condition. Do NOT duplicate the implementation here.

**Sweep `.claude/worktrees/` for `orchestrator-<dead-session-id>/` directories left behind by prior sessions that crashed before reaching [`cleanup-summary.md`'s step 6 (orchestrator-worktree reap)](./cleanup-summary.md#end-of-session-cleanup).** Companion to [step 1.6](#16-reap-orphan-session-files-cost-ledger-recovery), which reaps orphan session *files*; this step reaps the *worktrees* themselves. Neither sweep was sufficient on its own:

- **Step 1.6** only deletes the session JSON from `$SHIPYARD_HOME/sessions/`. The worktree dir under the repo's `.claude/worktrees/` is untouched, so a dead session's worktree dir accumulates indefinitely.
- **Step 3b** only reaps `agent-*` worktrees (the per-dispatched-agent isolation worktrees). It scopes intentionally — `orchestrator-*` worktrees have different lock semantics and historically were retired by the owning session's own cleanup-summary step 6.

When a prior session crashed *between* step 7→8 (cost-history flush + session-file cleanup) and step 6 (orchestrator-worktree reap), the session file is gone but the worktree lingers. See [issue #280](https://github.com/mattsears18/shipyard/issues/280) for the production trace: a single-slot user's `git worktree list` accumulated multiple `orchestrator-dowork-*` detached-HEAD entries across crash-and-restart cycles, none of which any spec-defined step would ever reap.

The discovery uses [`worktree-reap.sh find-orphan-orchestrators`](../../scripts/worktree-reap.sh), which applies the same liveness gate as step 1.6 — `is-active` exits 0 if the owning session's PID is alive, exit 1 otherwise (missing file, missing/null pid, dead pid). Both the worktree-sweep and the session-file-sweep treat "file missing" as inactive: the common case for the bug is that prior cleanup got far enough to flush + delete the session file but stopped short of reaping its own worktree.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
# (Pseudocode — the canonical implementation lives in step 0.7's
# background group. This snippet illustrates the per-orphan action.)
while read -r orph_path; do
  orph_name=$(basename "$orph_path")
  orph_session_id="${orph_name#orchestrator-}"
  # Issue #284 — `worktree-reap.sh reap` handles BOTH the git-worktree-remove
  # attempt AND the rm -rf fallback internally, and emits the appropriate
  # action variant (`reaped-orphan-orchestrator` vs the `-raw-rm` suffix)
  # in a single audit-log line.
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped-orphan-orchestrator \
    --worktree-path "$orph_path" \
    --worktree-name "$orph_name" \
    --session-id "<session-id>" \
    --reaped-session-id "$orph_session_id" \
    --phase "setup-1.6.5"
done < <("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" find-orphan-orchestrators \
           --repo-root "$(git rev-parse --show-toplevel)" \
           --current-session-id "<session-id>")
git worktree prune
```

**Audit-log shape** — same `~/.shipyard/reap-audit.jsonl` as steps 3 / 3b, but with a distinct `action` value so the source is traceable. The helper emits these variants for us (issue #284 moved the JSONL writes into [`worktree-reap.sh reap`](../../scripts/worktree-reap.sh) — see step 3b for the same pattern):

- `action: "reaped-orphan-orchestrator"` — successful `git worktree remove --force`.
- `action: "reaped-orphan-orchestrator-raw-rm"` — fallback when the worktree was unregistered with git (raw dir left after a crash); resolved via `rm -rf`. The helper chooses between these automatically; the caller passes the same `--action reaped-orphan-orchestrator` and the helper picks the right line based on which path actually succeeded.
- `action: "reaped-orphan-orchestrator-failed"` — emitted only when BOTH `git worktree remove` and `rm -rf` failed (the dir is somehow non-removable — permissions, mount issue). Surfaces the failure for traceability rather than swallowing it silently.
- Each line carries a `reaped_session_id` field (the embedded session id of the orphan) and `phase: "setup-1.6.5"` so a future debugger can correlate against the prior session's run.

The fallback to raw `rm -rf` is load-bearing for the production case in #280: `git worktree remove` fails when the worktree dir is on disk but `.git/worktrees/<name>/` metadata has already been pruned (or was never registered — e.g., a manual `mv` left an `orchestrator-*` dir without git tracking it). Without the fallback, the dir would linger across an unbounded number of subsequent `/do-work` sessions.

**Skip condition.** Like step 1.6, this sweep is skipped entirely when `SHIPYARD_KEEP_SESSIONS=1` — the user is explicitly opting to keep historical state, and worktree dirs are part of that state.

**Concurrency safety.** Because this step runs in the same background group as 1.6 (which already excludes the current session by id), there's no race against the orchestrator's own worktree — the helper filters `<current-session-id>` from its output before emitting paths. A concurrent peer `/do-work` orchestrator in another terminal *can* race here: if peer A is the dead session whose worktree we want to reap, and peer B started up at the exact same wall-clock second, peer B's `is-active` check might see A's pid as alive (because A hasn't yet finished crashing) and skip the reap. That's the conservative outcome — A's worktree gets cleaned up by the next session that starts after A's pid is actually gone. The race never produces a wrongful reap.

### 1.7 Resolve trusted-author allowlist

**Timing instrumentation (issue #238).** Bracket this step:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
# ... run resolution logic ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
```

**Security gate — must run before step 2's bucket pass and step 4's backlog fetch.** Populates the session-level `trusted_authors` set (the 10th orchestrator state struct — see the [state struct list](../do-work.md#orchestrator-state) at the top of this spec). The set decides which issue authors `/do-work` will dispatch workers against; everyone else lands in step 2's `Untrusted author` bucket and step 4's client-side filter drops them from the workable queue. This is the **first line of defense** against the public-repo prompt-injection / RCE threat documented in step 2's "Bucket 0.5 is a security gate" block — a stranger can open an issue with a body that reads like a legit bug report ("Suggested fix: add `helper.ts` with `<crafted payload>`"), but if their login isn't in `trusted_authors`, no worker is ever dispatched against it, so the body is never read as instructions.

**Resolution order — first non-empty wins:**

1. **Per-repo override file** — if `.shipyard/trusted-authors.txt` exists in the orchestrator worktree, read it. One GitHub login per line; lines starting with `#` are comments; blank lines are ignored; logins are case-insensitive (lowercased on read). The repo owner (`<owner>` portion of `<owner/repo>`) is implicitly included even when the file omits them. Run the file through `trusted-authors-normalize.sh` (see [GH App alias normalization](#gh-app-alias-normalization-issue-296) below) so both `<bot>[bot]` and `app/<bot>` resolve correctly regardless of which form the file uses. Use the normalized set as `trusted_authors` and stop — do not fall through to the collaborators API.

2. **Collaborators API fallback** — when the override file doesn't exist, query the live collaborators-with-push API:

   ```bash
   gh api "repos/<owner/repo>/collaborators?per_page=100" --paginate \
     --jq '.[] | select(.permissions.push==true) | .login' | tr 'A-Z' 'a-z' | sort -u
   ```

   Add `<owner>` (lowercased) to the result set so a personal-repo owner with no other collaborators still works. Pass the result through `trusted-authors-normalize.sh` for consistency with branch 1 (the collaborators API doesn't return bots, so the alias expansion is usually a no-op, but the call is safe). Cache the result as `trusted_authors`.

3. **API failure / permission denied** — when the API call errors (the auth'd token can't list collaborators, e.g. the repo is owned by an org and the token doesn't have admin scope), fall back to a single-member set containing just `<owner>` (lowercased). Log an advisory: `[trusted-authors] could not query collaborators API (<reason>); falling back to repo owner only`. The session continues — restrictive default is the safe failure mode.

`.shipyard/trusted-authors.txt` format — one GitHub login per line; comments (`#`) and blank lines OK; case-insensitive; repo owner is implicitly trusted. Bot / GitHub-App accounts are NOT auto-trusted — the collaborators-API fallback excludes them, and maintainers must add them to the override file explicitly. Either login shape works: `sentry[bot]` (REST) OR `app/sentry` (GraphQL) — `trusted-authors-normalize.sh` cross-adds the alias, and the orchestrator's downstream `author.login` comparison matches either one (see [GH App alias normalization](#gh-app-alias-normalization-issue-296) below). Cache lifetime is session-scoped — resolve once at startup, never re-resolve mid-session. See [RATIONALE → Step 1.7](../do-work-RATIONALE.md#step-17--why-a-per-repo-override-file-exists) for the policy discussion.

#### GH App alias normalization (issue #296)

GitHub returns **two different login shapes** for the same GH App account depending on which API the caller hits:

- **REST** (e.g. `/repos/.../issues/N/events`) returns the legacy-style login: `sentry[bot]`.
- **GraphQL Bot/App actor objects** (what `gh issue list --json author` and `gh issue view --json author` return) expose: `app/sentry`.

The two strings have nothing in common after lowercasing. Before [#296](https://github.com/mattsears18/shipyard/issues/296), a maintainer who put `sentry[bot]` in `.shipyard/trusted-authors.txt` would see every Sentry-filed issue silently bucketed as untrusted by step 2's bucket-0.5 filter and dropped by step 4's client-side filter, because the comparison value (the GraphQL `app/sentry` shape) never matched the file's REST-shaped entry. The setup-time advisory `[trusted-authors] loaded 2 author(s)` was misleading — the bot was "in the file" but not effectively trusted.

The fix is alias normalization at allowlist-load time. The helper `${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh` reads the cleaned set and, for every `<name>[bot]` or `app/<name>` entry, **adds the other shape** to the set. So a file with `sentry[bot]` produces `{sentry[bot], app/sentry}`; a file with `app/sentry` produces `{app/sentry, sentry[bot]}`. Either form matches the GraphQL `author.login` value the orchestrator compares against. Human logins (no `[bot]` suffix, no `app/` prefix) pass through unchanged.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
# Branch 1 (override file present) — read + normalize in one pipeline:
allowlist_file=".shipyard/trusted-authors.txt"
trusted_authors=$(
  {
    cat "$allowlist_file"
    printf '%s\n' "<owner>"   # repo owner is implicitly trusted
  } | "${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh"
)

# The advisory log SHOULD report which aliases were applied so the
# maintainer knows the normalization fired (issue #296 acceptance criterion):
"${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh" \
  --report-aliases "$allowlist_file" | while IFS= read -r line; do
  [ -z "$line" ] || echo "$line"
done
```

The helper is idempotent — running it on a set that already contains both forms produces the same set. The cross-alias is one-directional in the sense that the *content* is preserved (no shape is rewritten) — both shapes coexist after normalization.

The same normalization runs inside the two GitHub Actions workflows that resolve the allowlist (`.github/workflows/intake-refinement-gate.yml` and `.github/workflows/label-event-audit.yml`) — they inline the alias-cross-add as a `sed` pipeline (workflows can't reach into the shipyard plugin's scripts dir from a consumer repo). The orchestrator-side helper and the workflow-side inlining are kept in sync by the `trusted-authors-normalize.test.sh` test suite plus a workflow-side smoke pattern (any change to the alias logic in one place must change it in all three).

**Protect the override file with CODEOWNERS.** Because the file IS the security boundary, repos that adopt `/shipyard:do-work` should add a `.github/CODEOWNERS` rule naming the maintainer(s) for `.shipyard/trusted-authors.txt` and enable "Require review from Code Owners" in branch protection on the default branch — otherwise anyone with `write` access can extend the allowlist via a single PR with no maintainer in the loop. This repo's own [`.github/CODEOWNERS`](../../../../.github/CODEOWNERS) is the reference example.

**Output.** A single advisory line goes into the session log right after resolution:

- `[trusted-authors] loaded <K> author(s) from .shipyard/trusted-authors.txt`, or
- `[trusted-authors] loaded <K> collaborator(s) from repos/<owner/repo>/collaborators API`, or
- `[trusted-authors] fallback to repo owner only — <reason for API failure>`.

The count `<K>` is the **post-normalization** size — it includes both the alias expansions from [GH App alias normalization](#gh-app-alias-normalization-issue-296) and the implicitly-trusted repo owner. The advisory is one line — not a block, not a list of logins — so the startup output stays scannable.

When any GH-App aliases were added (one or more `<bot>[bot]` ↔ `app/<bot>` cross-adds fired), emit one additional `[trusted-authors] alias: <input> -> <added>` line per alias on the line immediately following the main advisory. Sourced from `trusted-authors-normalize.sh --report-aliases` so the maintainer can verify which form was matched. Skip when no aliases were needed (the typical human-only repo case) — silence is the right default.

### 2. Backlog overview

> **`--fast` skip:** When `--fast` is set, skip the full universe fetch and the UI table. Instead, run three cheap counts for advisory reporting in the end-of-session `--fast was used` block:
>
> ```bash
> # These five run in parallel as part of the parallelization batch even under --fast.
> gh issue list --repo <owner/repo> --state open --label needs-refinement --json number --jq 'length'
> gh pr list --repo <owner/repo> --state open --label blocked:ci --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent --json number --jq 'length'  # legacy (pre-#300)
> ```
>
> Save the five counts as `fast_skip_needs_refinement`, `fast_skip_blocked_ci`, `fast_skip_blocked_agent_hard`, `fast_skip_blocked_agent_soft`, and `fast_skip_blocked_agent_legacy`. Proceed immediately to step 3.

Before any other setup, fetch every open issue and print an upfront summary of what will be worked on, what will be skipped, and why. The user reads this once at the start of the session and uses it to (a) calibrate expectations for how many issues this run will close, and (b) start unblocking the blocked work in parallel while the orchestrator runs. The summary is **informational only** — print it, then continue with step 3. No confirmation needed.

Fetch the universe of open issues and the linked-PR subset. Both calls are part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5:

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'

gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number \
  --search 'is:issue is:open linked:pr' \
  --jq '[.[].number]'
```

The `--jq` projection flattens `labels` / `assignees` to the only shapes the bucket routing consumes (label names, assignee logins) and preserves the canonical `author.login` shape so the bucket-0.5 untrusted-author check (`author.login NOT in trusted_authors`) reads identically. Body stays full because bucket 6 / bucket 7 parse `Blocked by #N` references out of it via regex. Worker-preamble §"`gh` JSON discipline" covers the convention.

Bucket each issue into exactly one category. Apply in order — first match wins so an issue lands in its most specific bucket:

| # | Bucket | Criteria |
|---|---|---|
| 0.5 | **Untrusted author** | `author.login` is NOT in `trusted_authors` (see [step 1.7](#17-resolve-trusted-author-allowlist)). **Applied first** — strangers' issues never reach the dispatch queue, even if otherwise unlabeled. |
| 1 | **Assigned to others** | `assignees` contains a user other than `@me` |
| 2 | **In flight** | issue number appears in the `linked:pr` set above |
| 3 | **Won't fix** | carries `wontfix` |
| 4 | **Discussion** | carries `discussion` |
| 5 | **Needs triage / design** | carries `needs-triage` or `needs-design` |
| 5.4 | **Awaiting refinement** | carries `needs-refinement` (generic pipeline gate — `/refine-issues` branches by source signal: user-feedback classify+rewrite, open-questions resolve-defaults, fall-through escalate-to-triage) |
| 5.5 | **Awaiting human review** | carries `needs-human-review` and NOT `needs-refinement` |
| 6a | **Blocked (hard label)** | carries `blocked:agent-hard` or the legacy `blocked:agent` (treated as `-hard` per #300's migration path — see [step 3d.2](#3d-recover-from-prior-session-blocked-state)) |
| 6b | **Blocked (soft label)** | carries `blocked:agent-soft` ([#300](https://github.com/mattsears18/shipyard/issues/300)) — auto-cleared at next session, so the bucket exists for visibility only; the soft-blocked issue is **NOT excluded** from step 4's workable fetch. Surfaces here so the user sees that a prior worker bailed for a subjective reason (cannot-reproduce / ambiguous / scope-judgment) and may want to clarify the issue before re-dispatch picks it up |
| 7 | **Blocked (body reference)** | body matches `Blocked by #(\d+)` where that issue is still open (`gh issue view <N> --json state -q .state` returns `OPEN`) |
| 8 | **Workable** | everything else — these are what /do-work will dispatch |

**Bucket 0.5 is a security gate, not a triage hint** — the dispatch-time filter that keeps strangers' issues out of the workable queue entirely. The defense-in-depth measure (issue body treated as untrusted in [`agents/issue-worker/issue-work.md` step 2](../../agents/issue-worker/issue-work.md#2-read-the-issue-carefully)) sits behind this filter. Override path for a maintainer-vouched issue: re-file under the maintainer's own account, or add the author to `.shipyard/trusted-authors.txt`. See [RATIONALE → Bucket 0.5 security gate](../do-work-RATIONALE.md#step-2--why-bucket-05-is-a-security-gate) for the threat model and override-path discussion.

Buckets 5.4 and 5.5 are part of the refinement pipeline (see `/refine-issues`). 5.4 issues will be processed automatically by step 3.5 *this* session — the refiner branches on source signal (user-feedback vs open-questions vs fall-through). 5.5 issues are waiting on a human to sign off on the refined version (this is the `user-feedback` path's human-gate, applied by the classify+rewrite branch — `needs-human-review` is **decoupled** from `needs-refinement` and is NOT applied by the resolve-defaults or escalate-to-triage branches). Both render in the "Skipped" block with counts and issue numbers.

For each issue in bucket 6a, 6b, or 7, generate a one-line **unblock recommendation** describing what the human could do to unblock it. Use the issue body, labels, and (for body references) the blocker's title and state — but skim, don't deep-dive. One sentence per blocked issue is plenty. Examples:

- Blocked by another open issue: `"#<N> blocked by #<M> (\"<M's title>\") — <action, e.g. 'land #M first', 'close #M as obsolete', or 'review the proposal in the latest comment'>"`
- Blocked by an external dependency (SDK release, vendor input, design decision): describe the concrete action the user could take
- `blocked:agent-hard` label set with no discernible blocker: `"#<N>: hard block — review the worker's blocked comment, then either fix the underlying issue (e.g. tighten the body) or remove the label"`
- `blocked:agent-soft` label set: `"#<N>: soft block — will auto-retry at next session (cleared automatically); clarify the body if you want a different outcome on retry"`
- Awaiting refinement (bucket 5.4): `"#<N>: refinement runs automatically at /do-work startup, or run /refine-issues manually"`
- Awaiting human review (bucket 5.5): `"#<N>: review the refined feedback, set a priority label, remove \`needs-human-review\` (or close)"`

The point is to give the user something **actionable** so they can start clearing blockers in parallel.

**Inline action-recommendation candidates per skipped bucket.** The orchestrator surfaces per-bucket candidate counts under each Skipped-bucket so the "this bucket has N issues you could probably act on right now" signal is visible at the bucket itself. Apply only to buckets where a mechanical signal distinguishes "likely-actionable" from "genuinely stuck" residue. The orchestrator does NOT auto-act on these. See [RATIONALE → Inline action recommendations](../do-work-RATIONALE.md#step-2--inline-action-recommendation-rationale) for the cost discussion.

Compute candidates for the following buckets:

- **Bucket 6a (Blocked hard label) — `likely-clearable` candidates.** For each issue in this bucket, parse `Blocked by #N` references from the body using the same regex step 3d.2 uses (`grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)'`). Check each referenced blocker's state via `gh issue view <N> --json state` (with `gh pr view` fallback for PR numbers). An issue is `likely-clearable` when **all** referenced blockers are `CLOSED` or `MERGED`. Candidates are also what step 3d.2 will auto-clear later in setup — surfacing them here in step 2 gives the user pre-sweep visibility before the sweep runs. Held issues (no body reference, or any blocker still open) are NOT surfaced as candidates. Bucket 6b (soft label) does NOT compute candidates — every soft-label issue is auto-cleared at next-session backlog fetch and is already counted as workable in step 4, so there's nothing the user could pre-empt.

- **Bucket 5 (Needs triage / design) — `likely-triageable` candidates.** Score each issue by the presence of mechanical triage signals in its labels and body:
  - `+1` if labels contain any of `P0` / `P1` / `P2` (priority already set).
  - `+1` if labels contain any of `bug` / `enhancement` / `fix` / `feat` (issue type already declared).
  - `+1` if body contains `## Acceptance` or `## Acceptance criteria` (criteria section present).
  - `+1` if body contains `## Repro` / `## Reproduction` / `## Steps to reproduce` (repro section present).
  - `+1` if labels contain NEITHER `needs-design` NOR `needs-human-review` (no co-gate beyond `needs-triage`).

  Score `>= 3` → `likely-triageable` candidate. The recommendation is "review then remove `needs-triage`" — the orchestrator does NOT auto-remove the label. Score `< 3` → "genuinely fuzzy" residue; not a candidate.

Print the summary using **two-mode rendering**, picked by row count:

- **Two or more non-zero buckets** → fixed-width aligned text table (not markdown table; spaces-aligned columns, `─` U+2500 header divider).
- **Exactly one non-zero bucket** → single-line summary, no table.
- **Zero buckets total** → empty-backlog one-liner.

The full shape, **two-or-more-rows mode**:

```
/do-work backlog overview — <owner/repo>

By priority: P0=<n>  P1=<n>  P2=<n>  unlabeled=<n>
Top workable items: #<a>, #<b>, #<c>, ...

Bucket                                       Count   Issues
───────────────────────────────────────────  ─────   ──────────────────────────────────────────────
Workable (will be worked this session)           6   #<a>, #<b>, #<c>, +<K> more
⛔ Untrusted author                              2   #U → @stranger, #V → @stranger2
blocked:agent-hard label                         3   #A, #B, #C
  ⚠ likely-clearable                             1   #A — all referenced blockers closed; step 3d.2 will auto-clear
blocked:agent-soft label                         2   #S1, #S2 — auto-cleared at next-session backlog fetch (no exclusion)
Blocked (body reference)                         1   #D
needs-triage / needs-design                      2   #E, #F
  ⚠ likely-triageable                            1   #E — review then remove `needs-triage`
Awaiting refinement                              1   #R
Awaiting human review                            1   #H
Discussion                                       1   #G
Won't fix                                        1   #X
In flight (open PR)                              2   #I → PR #J, #K → PR #L
Assigned to others                               1   #M → @user

Total open: <W + S>  (workable: <W>, skipped: <S>)

Auto-cleared this session:
  blocked:agent-hard labels:   <cleared_blocked_hard> issue(s)  (#X, #Y, ...)
  held blocked:agent-hard:     <held_blocked_hard> issue(s)  (#Z, ...)
  blocked:agent-soft → workable: <cleared_blocked_soft> issue(s)  (#S1, #S2, ...)  (next-session sweep — no held bucket)
  legacy blocked:agent migrated → blocked:agent-hard: <migrated_legacy> issue(s)  (#L1, ...)

PR-side state:
  blocked:ci PRs: <c> total
    will be re-evaluated this session: <k>  (#J, #K, ...)
    held (no new commits since label applied): <h>  (#L, #M, ...)

Unblock recommendations (work these in parallel while /do-work runs):
  - #A: <recommendation>
  - #C: <recommendation>
  ...
```

**One-row mode** (the table is skipped; replace the bucket block with a single-line summary). When the lone bucket is `Workable`: `Workable: 6 issues (#90, #91, #92, #93, #94, #89). Nothing skipped.` When the lone bucket is a skip: `Workable: 0. Skipped: 3 issues in 'blocked:agent-hard' label (#A, #B, #C).`

**Zero-row mode** (empty universe): replace everything below the header with `Backlog is empty — nothing to work on this session.`

**Bucket-table rules:**

- **Row count picks the mode.** Count non-zero buckets. `0` → empty-backlog one-liner. `1` → single-line summary. `≥2` → fixed-width aligned text table. The `Workable` row counts only when `<W> > 0`; action-recommendation sub-rows (`⚠ likely-clearable` / `⚠ likely-triageable`) don't count as their own bucket. See [RATIONALE → Bucket-table mode selection](../do-work-RATIONALE.md#step-2--bucket-table-mode-selection-rationale).
- **Workable-row-always-prints is a table-mode rule, not a row-counting rule.** When the table renders (`≥2` non-zero buckets), the `Workable` row prints even with `<W> == 0`.
- **Column widths in two-or-more-rows mode.** Computed at print time:
  - **Bucket** column: width = max(label length across rendered rows), clamped to a minimum of 30 and a maximum of 60 characters. Sub-row labels include their 2-space indent in the length.
  - **Count** column: right-aligned, width = max(digit count across rows), clamped to a minimum of 5.
  - **Issues** column: width = max(content length across rendered rows), clamped to a minimum of 30 and a maximum of 80 characters. Content wider than the cap is NOT line-wrapped — the per-row truncation rule below handles overflow.
  - Column separator: **3 spaces** (visible gap without looking like a tab). Header divider: one `─` (U+2500) per character of the header label, separated by the same 3-space gaps.
- **Row order**: `Workable` first, then `Untrusted author` (security-relevant skip, surfaced near top), `Blocked (label)`, `Blocked (body reference)`, `Needs-triage/design`, `Awaiting refinement`, `Awaiting human review`, `Discussion`, `Won't fix`, `In flight`, `Assigned to others`.
- **Issues column content.** Comma-separated issue numbers (with arrow-targets like `#G → PR #H` or `#I → @user`). Truncate after **10 numbers** with `, +<K> more`.
- **`Total open` line** stays below the table; **`By priority` and `Top workable items`** stay above.

The **PR-side state** block prints whenever `<c> > 0`. Numbers come from `cleared_ciblocked` / `held_ciblocked` recorded by [step 3d.1](#3-ensure-label-exists--recover-from-prior-session).

The **Auto-cleared this session** block prints when `cleared_blocked > 0` or `held_blocked > 0`. Numbers come from step 3d.2.

Edge cases:

- **`W == 0`** — print the summary anyway, then continue with setup. Step 4's filtered fetch will return empty and the loop will terminate cleanly.
- **No blocked issues** — omit the "Unblock recommendations" section entirely.
- **Priority labels not yet triaged** — the breakdown reflects current label state; step 4's auto-triage pass labels the unlabeled survivors before dispatch.
- **Buckets with zero count** — in table mode, omit those rows (except `Workable`, which always prints in table mode). Action-recommendation sub-rows with zero candidates are also omitted.
- **Very large backlogs** — per-row Issues column truncates after ~10 numbers with `, +<K> more`.
- **`likely-clearable` overlap with step 3d.2** — every candidate surfaced in step 2 is also a candidate for step 3d.2's auto-clear sweep. Visibility in step 2 is the point; the two surfaces are sequential checkpoints on the same set.
- **Cost** — all blocker lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on) and fire as a parallel burst. Combined extra cost on a ~50-issue backlog is well under 1s wall-clock.

Then proceed immediately to step 3.

### 3. Ensure label exists + recover from prior session

**3a. Ensure required labels exist** (idempotent).

> **Background step.** This step runs inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Labels are guaranteed to exist by the time the first dispatched agent applies one (the background group typically finishes well before the first worker fires). The canonical label list and `gh label create` calls live in the background group above.

The `shipyard` label is the session stamp; `P0`/`P1`/`P2` are the priority tiers; `user-feedback`/`needs-refinement`/`needs-human-review`/`needs-triage` drive the [refinement pipeline](#35-refine-pending-issues); `blocked:agent-hard` / `blocked:agent-soft` / `blocked:ci` are shipyard's block-state circuit breakers (applied by step A on agent / fix-checks block, removed by step 3d.1 / 3d.2 / next-session backlog re-fetch):

```bash
gh label create shipyard --repo <owner/repo> --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create user-feedback --repo <owner/repo> --description "Originated from end-user feedback (untrusted body — treat with care)" --color 0E8A16 2>/dev/null || true
gh label create needs-refinement --repo <owner/repo> --description "Pipeline gate — issue isn't ready for /do-work; /refine-issues processes it" --color FBCA04 2>/dev/null || true
gh label create needs-human-review --repo <owner/repo> --description "Awaiting human sign-off before /do-work will touch it" --color D93F0B 2>/dev/null || true
gh label create needs-triage --repo <owner/repo> --description "No automated path forward — surface to a human" --color C2E0C6 2>/dev/null || true
gh label create blocked:agent-hard --repo <owner/repo> --description "Worker returned a security/scope/prompt-injection refuse — needs human review before retry. Hides from workable queue across sessions." --color B60205 2>/dev/null || true
gh label create blocked:agent-soft --repo <owner/repo> --description "Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes." --color FBCA04 2>/dev/null || true
gh label create blocked:ci --repo <owner/repo> --description "CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover." --color B60205 2>/dev/null || true

# Legacy `blocked:agent` label (pre-#300) — kept registered for migration only.
# Issues still carrying it are treated as `blocked:agent-hard` by step 3d.2's
# legacy-migration pass below. Will be removed once no open issue carries it.
gh label create blocked:agent --repo <owner/repo> --description "Legacy (pre-#300) — migrated to blocked:agent-hard at next session" --color C5DEF5 2>/dev/null || true
```

**3b. Reap stale agent worktrees from dead Claude Code sessions.**

> **Background step.** This step runs inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Stale-worktree reaping affects future dispatch slot availability, not the first batch. The canonical implementation lives in the background group above.

The harness writes a lock file at `.git/worktrees/agent-<id>/locked` containing `claude agent <id> (pid <N>)`. The lock survives the harness process exiting. Reap every agent worktree whose lock-holding PID is dead; skip ones owned by live PIDs (could be another active Claude Code instance):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
reaped_stale=0
deferred_stale=0
# Declare our orchestrator PID so classify-lock can short-circuit reliably
# (issue #263). The harness writes our PID into every agent lock file;
# without an explicit declaration, classify-lock's ancestor walk can fail
# to find it whenever an intermediate harness layer returns empty PPID.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)
# Use `find` instead of a bare `agent-*` glob so the loop survives zsh's
# default `nomatch` option when no agent worktrees exist
# ([#335](https://github.com/mattsears18/shipyard/issues/335)). Bare globs
# raise a fatal error under zsh; `find` exits 0 on no matches and the
# loop body simply doesn't iterate.
for wt_dir in $(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null); do
  [ -d "$wt_dir" ] || continue
  name=$(basename "$wt_dir")
  worktree_path=$(git worktree list --porcelain | awk -v n="$name" '/^worktree /{p=$2} /^branch /{b=$2} /^$/{if (p ~ n) print p}' | head -1)
  [ -z "$worktree_path" ] && worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
  [ -z "$worktree_path" ] && continue

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
    classify-lock "$wt_dir/locked")

  if [ "$classification" = "peer-alive" ]; then
    # Lock-holding PID is alive AND not in our ancestor chain — likely
    # another active Claude Code instance. Defer.
    deferred_stale=$((deferred_stale + 1))
    continue
  fi

  # no-lock / dead / self-ancestor — safe to reap. (`self-ancestor` is
  # rare at startup since by definition we just launched, but covers the
  # PID-recycling edge case where a stale lock happens to name our PID.)
  git worktree unlock "$worktree_path" 2>/dev/null
  if git worktree remove --force "$worktree_path" 2>/dev/null; then
    reaped_stale=$((reaped_stale + 1))
  fi
done
git worktree prune
```

Record `reaped_stale` and `deferred_stale` — both surface in the end-of-session summary.

**3c. Orphan worktree triage** — scan for `do-work/*` branches whose worktrees survived step 3b (legitimate orphans from THIS session, not dead-process leftovers).

> **Background step.** Both the discovery query and the handling (push / PR-create for orphans with commits) run inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch). Neither gates dispatch decisions. The discovery query is cheap; the expensive push/PR-create branch only fires when orphans exist. The canonical implementation lives in the background group above; this section documents the decision table and `salvaged_count` / `abandoned_count` / `stale_assigns_count` tracking semantics.

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR), `abandoned_count` (worktrees removed), and `stale_assigns_count` (issues whose `@me` self-assign was cleared by the fifth row's no-worktree-no-PR-no-branch sweep) — all three default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 4). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '[.statusCheckRollup \| group_by(.name) \| map(sort_by(.completedAt // .startedAt // "") \| last) \| .[] \| select((.conclusion // .status // "") \| test("FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED"))] \| length'`. If count > 0 → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. Latest-per-name projection per issue [#333](https://github.com/mattsears18/shipyard/issues/333) — a naïve `.statusCheckRollup[]` walk would false-positive on stale superseded FAILUREs. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |
| **Self-assigned with no worktree, no PR, no branch on origin** (issue [#303](https://github.com/mattsears18/shipyard/issues/303)) | After the worktree loop above, run `gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number` and for each result confirm `[ ! -d <repo-root>/.claude/worktrees/agent-* ]` doesn't claim it (no worktree-on-disk this loop already touched) AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `gh issue edit <N> --repo <owner/repo> --remove-assignee @me` (leave the `shipyard` label as provenance — it's not load-bearing for re-dispatch). `stale_assigns_count++`. Next dispatch retries from scratch. |

The fifth row closes a gap [#303](https://github.com/mattsears18/shipyard/issues/303) opened: prior sessions sometimes leave the `@me` self-assign on an issue after their on-disk worktree has been cleaned up (returned `blocked`, errored before first commit, etc.). The first four rows only see issues whose worktree is still present — so this state survives unbounded across sessions, with the issue silently failing the worker-side step-0 pre-flight ("assignee is `@me`, not someone else, so don't bail") and getting re-dispatched against stale prior-session artifacts.

The row's action is intentionally conservative: clear the assignment only, leave the `shipyard` label (provenance — it tells the next session this issue went through `/do-work` before), let the normal step-4 backlog fetch pick the issue back up, and let the orchestrator's normal dispatch path arrange a fresh worktree. Don't touch the issue body, don't post a comment, don't close — the issue may genuinely still be workable and the prior session's `blocked` may have been transient.

**3d.1. Auto-clear stale `blocked:ci` labels.** The label is sticky on purpose, but a new commit on the PR's head branch means the premise ("no movement since shipyard gave up") is no longer true. Auto-clear those PRs so they flow back into step 5's failing-PR snapshot for another 3 attempts. This sweep is the *only* place `blocked:ci` is removed by the orchestrator (step A applies; 3d.1 removes; no other step touches it).

> **`--fast` skip:** When `--fast` is set, skip this entire sweep. The initial `blocked:ci` count (`fast_skip_blocked_ci`) captured in step 2's `--fast` note is sufficient for the advisory summary — stale `blocked:ci` labels persist until the next normal session. Set `cleared_ciblocked=0` and `held_ciblocked=0`.

Fire the initial PR list as part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch); per-PR `events` + `commits` lookups are a second-tier parallel batch. The serial loop below is shown for readability:

```bash
# All open PRs currently carrying blocked:ci, regardless of author. Foreign authors
# matter here too — the sweep is about the label's premise, not who owns the PR.
gh pr list --repo <owner/repo> --state open --label blocked:ci --limit 200 \
  --json number,headRefOid,headRefName \
  > /tmp/do-work-ciblocked-prs.json

cleared_ciblocked=0
held_ciblocked=0
declare -a cleared_pr_numbers
declare -a held_pr_numbers

for pr in $(jq -r '.[].number' /tmp/do-work-ciblocked-prs.json); do
  head_oid=$(jq -r --argjson n "$pr" '.[] | select(.number == $n) | .headRefOid' /tmp/do-work-ciblocked-prs.json)

  # Newest `labeled` event for blocked:ci on this PR (shipyard, a bot, or a human — doesn't matter who).
  # We're comparing "when was this label applied" against "when was the last commit on the head branch."
  label_ts=$(gh api "repos/<owner/repo>/issues/$pr/events" --paginate \
    --jq '[.[] | select(.event == "labeled" and .label.name == "blocked:ci")] | sort_by(.created_at) | last | .created_at')

  # When was the head commit authored?
  commit_ts=$(gh api "repos/<owner/repo>/commits/$head_oid" --jq '.commit.committer.date')

  if [ -z "$label_ts" ] || [ -z "$commit_ts" ]; then
    # Can't compute — leave the label alone, log advisory.
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
    continue
  fi

  # Compare ISO-8601 timestamps lexicographically (UTC-Z form sorts correctly).
  if [[ "$commit_ts" > "$label_ts" ]]; then
    gh pr edit "$pr" --repo <owner/repo> --remove-label blocked:ci
    cleared_ciblocked=$((cleared_ciblocked + 1))
    cleared_pr_numbers+=("$pr")
  else
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
  fi
done
```

Record `cleared_ciblocked` and `held_ciblocked` (plus the matching PR-number arrays). Cleared PRs flow into step 5's failing-PR snapshot naturally.

**Regression guard.** The `commit_ts > label_ts` comparison enforces "auto-clear fires only when a new commit has landed since the label was applied." If the comparison can't be computed (head branch deleted, events aged out of the ~90-day pagination window, network blip), hold — the safe default is to preserve the block. See [RATIONALE → Step 3d sweeps](../do-work-RATIONALE.md#step-3d--why-the-blockedci--blockedagent-hard-sweeps-have-different-shapes).

**3d.2. Auto-clear stale `blocked:agent-hard` labels + migrate legacy `blocked:agent` + sweep `blocked:agent-soft`.** Three sub-sweeps running in sequence, all before step 4's backlog fetch. Closes [#300](https://github.com/mattsears18/shipyard/issues/300) — the original sweep operated on a single `blocked:agent` label that conflated security/scope refuses with subjective bails; the split into `-hard` / `-soft` (per [step A.1's classification](./steady-state.md#a1-parse-the-return-string)) needs sub-sweep `b` for migration and sub-sweep `c` for the new auto-clear-at-next-session behavior.

> **`--fast` skip:** When `--fast` is set, skip all three sub-sweeps. The initial `blocked:agent`-family counts (`fast_skip_blocked_agent_hard`, `fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`) captured in step 2's `--fast` note are sufficient for the advisory summary — stale labels persist until the next normal session. Set every `cleared_*` and `held_*` counter to 0.

Fire the initial issue lists (one per label) in the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch); per-issue blocker lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). Serial loop shown for readability.

**Sub-sweep a — `blocked:agent-hard` referential clear** (same logic as the pre-#300 `blocked:agent` sweep, retargeted at the new label):

```bash
# All open issues currently carrying the `blocked:agent-hard` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --limit 200 \
  --json number,body \
  > /tmp/do-work-blocked-hard-issues.json

cleared_blocked_hard=0
held_blocked_hard=0
declare -a cleared_blocked_hard_numbers
declare -a held_blocked_hard_numbers

for n in $(jq -r '.[].number' /tmp/do-work-blocked-hard-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-blocked-hard-issues.json)

  # Extract every `Blocked by #N` reference (case-insensitive, all matches).
  # The grep pattern catches `Blocked by #123`, `blocked by #45, #67, #89`, etc.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | sort -u)

  if [ -z "$blockers" ]; then
    # No `Blocked by #N` reference in body — can't make a judgment. Hold.
    held_blocked_hard=$((held_blocked_hard + 1))
    held_blocked_hard_numbers+=("$n")
    continue
  fi

  # Check each referenced blocker's state. If ANY is OPEN (or unresolvable), hold.
  # Reads through the blocker_state cache (see step 0.8) — cache-hits skip the
  # gh call entirely; cache-misses populate the cache before consuming the value.
  all_closed=true
  closed_list=""
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      if [ -z "$state" ]; then
        # Could be a PR (gh issue view fails on PR numbers) — try gh pr view.
        state=$(gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      fi
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in
      CLOSED|MERGED)
        closed_list="${closed_list:+$closed_list, }#$b"
        ;;
      *)
        all_closed=false
        break
        ;;
    esac
  done

  if $all_closed; then
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard
    gh issue comment "$n" --repo <owner/repo> \
      --body "Auto-cleared \`blocked:agent-hard\` — all referenced blockers ($closed_list) are now closed."
    cleared_blocked_hard=$((cleared_blocked_hard + 1))
    cleared_blocked_hard_numbers+=("$n")
  else
    held_blocked_hard=$((held_blocked_hard + 1))
    held_blocked_hard_numbers+=("$n")
  fi
done
```

Record `cleared_blocked_hard` and `held_blocked_hard` (plus the matching issue-number arrays) — both surface in step 2's backlog overview when either is > 0, and again in the end-of-session summary. The issues whose labels just got cleared will be picked up automatically by step 4's backlog fetch — they're no longer carrying `blocked:agent-hard`, so step 4's `-label:blocked:agent-hard` filter doesn't exclude them anymore.

**Held cases — when sub-sweep a deliberately doesn't clear:** no `Blocked by #N` reference in the body; any referenced blocker is still OPEN; unresolvable reference (both `gh issue view` and `gh pr view` error). Secondary gates past the `Blocked by` line aren't auto-detected — false positives are recoverable via the issue worker's own `blocked` return. See [RATIONALE → Step 3d sweeps](../do-work-RATIONALE.md#step-3d--why-the-blockedci--blockedagent-hard-sweeps-have-different-shapes) for the asymmetry between the two sweeps and the held-case discussion.

**Sub-sweep b — legacy `blocked:agent` → `blocked:agent-hard` migration.** Closes [#300](https://github.com/mattsears18/shipyard/issues/300)'s legacy-handling concern. Pre-#300 sessions stamped a single `blocked:agent` label; the new `-hard`/`-soft` split lives next to it. Issues still carrying the bare `blocked:agent` label are migrated to `-hard` (the conservative default — pre-#300 sessions had no concept of "soft" so the worker that stamped the label might have been refusing for a security/scope reason). The legacy label is then removed.

```bash
# All open issues carrying the bare `blocked:agent` label (but NOT also -hard
# or -soft — those are already migrated). The intersection rule prevents
# double-stamping a freshly-migrated issue if the user manually re-stamped
# legacy in the same window. Cheap: at most one extra gh call this session.
gh issue list --repo <owner/repo> --state open --label blocked:agent --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("blocked:agent-hard","blocked:agent-soft")) | not) | .number]' \
  > /tmp/do-work-blocked-legacy-issues.json

migrated_legacy=0
declare -a migrated_legacy_numbers
for n in $(jq -r '.[]' /tmp/do-work-blocked-legacy-issues.json); do
  gh issue edit "$n" --repo <owner/repo> --add-label blocked:agent-hard 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Migrated \`blocked:agent\` → \`blocked:agent-hard\` per [#300](https://github.com/mattsears18/shipyard/issues/300). The original label was applied before the soft/hard split existed; conservative migration treats it as the hard class. If a maintainer determines the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
  migrated_legacy=$((migrated_legacy + 1))
  migrated_legacy_numbers+=("$n")
done
```

The migration runs **once per legacy issue** — after the first run there are no more bare-`blocked:agent`-labeled issues. The label itself stays registered (the `gh label create` at the top of step 3d still fires for it) so a future audit can confirm zero open issues carry it before deletion. Eventually (after a few sessions with zero legacy hits) the label can be deleted via `gh label delete blocked:agent`.

**Sub-sweep c — `blocked:agent-soft` next-session sweep.** Subjective bails from prior sessions (`cannot reproduce`, `ambiguous`, `suggested fix exceeds expected scope`, `PR already open for this issue`) are auto-cleared at next-session backlog fetch — this is the **whole point** of the soft/hard split. Unlike sub-sweep a, there's no `Blocked by #N` referential check: the label by itself is the signal that "a prior worker bailed for a subjective reason that may not hold this session." Just remove the label and let step 4 pick the issue up naturally.

```bash
# All open issues currently carrying the `blocked:agent-soft` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --limit 200 \
  --json number \
  > /tmp/do-work-blocked-soft-issues.json

cleared_blocked_soft=0
declare -a cleared_blocked_soft_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-soft-issues.json); do
  gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-soft 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Auto-cleared \`blocked:agent-soft\` at next-session backlog fetch — subjective bails (cannot-reproduce / ambiguous / scope-judgment) do not persist across sessions. If the underlying ambiguity is still unresolved, a fresh worker dispatch this session may re-stamp the label." 2>/dev/null || true
  cleared_blocked_soft=$((cleared_blocked_soft + 1))
  cleared_blocked_soft_numbers+=("$n")
done
```

No "held" bucket for soft labels — every soft-labeled issue is cleared at the start of every session. The re-stamping risk (worker bails for the same reason → soft label re-applied this session) is intentional: subjective bails get exactly one re-dispatch per session, and the in-session re-dispatch gate (orchestrator's `session_blocked_soft` map per [steady-state.md A.1](./steady-state.md#a1-parse-the-return-string)) prevents tight retry loops within the same session. The cost of clearing-then-immediately-re-stamping is one extra `gh issue edit` per issue per session — cheap relative to the cost of permanently hiding workable issues.

**Order matters.** Sub-sweeps a → b → c run in sequence. b runs after a so a legacy `blocked:agent` issue that ALSO carries `blocked:agent-hard` (manually added by a maintainer mid-migration window) doesn't get hard re-stamped redundantly. c runs after a/b so the sweep operates on the post-migration label set.

### 3.5 Refine pending issues

> **`--fast` skip:** When `--fast` is set, skip this entire step. Issues carrying `needs-refinement` remain unrefined this session; they will be processed by the next normal `/do-work` invocation. The `fast_skip_needs_refinement` count captured in step 2's `--fast` note surfaces in the end-of-session advisory block so the user knows how many refinement tasks were deferred. Proceed immediately to step 4.

**Timing instrumentation (issue #238).** Bracket this step even when it runs with no `needs-refinement` issues — the wall clock still measures the `/refine-issues` invocation overhead:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
# /refine-issues --repo <owner/repo> --concurrency <N>
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
```

When `--fast` causes this step to be **skipped entirely**, call only the `start` + `end` pair with a near-zero elapsed (both calls back-to-back), so the ledger contains a `0.0s` entry for the phase rather than a missing key. This makes cross-session aggregation consistent — the report can always average `step_3_5_refine_issues` without handling absent keys for `--fast` sessions separately.

Invoke `/refine-issues` and **wait for it to complete** before proceeding to step 4. This processes every open issue carrying `needs-refinement` — the generic pipeline gate — and branches per-issue on source signal:

- **classify+rewrite branch** (`user-feedback` + `needs-refinement`): classify as already-done / declined / legitimate, preserve original text in a comment, rewrite the body into the repo's issue template. Legitimate items get `needs-human-review` co-applied.
- **resolve-defaults branch** (`needs-refinement` only, body has `## Open questions`): commit reasonable defaults for each question, rewrite body, drop `needs-refinement`. Does NOT apply `needs-human-review` — trusted-author issues become dispatch-eligible in the same session.
- **escalate-to-triage branch** (`needs-refinement` only, no recognizable pattern): drop `needs-refinement`, add `needs-triage`, comment with explanation. Surfaces via `/shipyard:my-turn`.

After this step, `needs-refinement` is off every survivor in the first two branches; only `needs-human-review` remains (and only for the user-feedback classify+rewrite path). The escalate-to-triage branch swaps `needs-refinement` for `needs-triage`.

```
/refine-issues --repo <owner/repo> --concurrency <do-work concurrency>
```

Pass-through args:

- **`--repo`** — same value `/do-work` is using.
- **`--concurrency`** — same value `/do-work` is using (default `1` unless overridden — see [`/do-work`'s `--concurrency` arg](../do-work.md#args) for the rationale).
- **`--issue`** is NEVER passed from `/do-work` — refinement always operates on the full eligible set during a `/do-work` startup.
- **`--dry-run`** is NEVER passed from `/do-work` — startup refinement always commits.

The refined-and-now-`needs-human-review`-only issues will be picked up by the *next* `/do-work` session, after a human reviews. Step 4's backlog fetch (just below) excludes `needs-refinement`, `needs-human-review`, and `needs-triage`, so none leak into the dispatch queue this session. Resolve-defaults issues, however, ARE picked up this session — they become dispatch-eligible the moment `needs-refinement` drops.

**Implementation note.** The refinement logic itself lives in `/refine-issues`. This step is a thin invocation — no duplication of the bucket spec, sentinel logic, or worker prompt template. If we later change the refinement prompt, we only update one file (`commands/refine-issues.md`).

### 4. Fetch + rank the backlog

**Timing instrumentation (issue #238).** Bracket this step including the auto-triage label-apply loop and client-side filter pass:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
# ... run step 4 ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
```

```bash
# Wide fetch — server-side filter is ONLY `--state open` (plus any
# `--label <L>` qualifiers passed at invocation). All eligibility checks
# move to the client-side filter pass below. See issue #332 for the
# regression this shape exists to prevent.
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author,createdAt,updatedAt \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, createdAt, updatedAt}]'
```

The `--jq` projection mirrors step 2's: flatten `labels` / `assignees` to the consumed shapes (names, logins) and preserve `author.login` as the canonical shape downstream filters and step 7's `originating_author_trust` computation reference. Body stays full because the client-side filter walks it for `Blocked by #N` references. Worker-preamble §"`gh` JSON discipline" covers the convention.

Pass `--label <L>` qualifiers through as `--label <L>` (NOT `--search 'label:<L>'`) for any `--label` args supplied at invocation — the `--label` flag composes cleanly with the wide fetch above and is the canonical way to scope the universe down to a project subset.

**Why the server-side filter is intentionally wide (issue [#332](https://github.com/mattsears18/shipyard/issues/332)).** Earlier versions of this spec used a `--search` qualifier of the form `is:issue is:open -linked:pr` followed by `-label:` exclusions for each block-tier and gate label (`blocked:agent`, `blocked:agent-hard`, `wontfix`, `needs-design`, `needs-triage`, `discussion`, `needs-refinement`, `needs-human-review`) to do the eligibility filter on GitHub's side. That shape silently dropped two classes of workable issues:

1. **`-linked:pr` excludes issues that ever had a linked PR opened against them**, even when that PR has since been closed, abandoned, or superseded. The resumable-work case — a prior session opened a PR that got closed before merge, the issue is still open and still self-assigned to `@me` — is exactly the bucket `-linked:pr` was supposed to NOT exclude but does. Concretely: a `lightwork` session at 2026-05-25 surfaced 14 issues from a backlog of 29 open ones; the orchestrator confidently emitted `ready=0 raw=0` and drained while 15 workable issues sat invisible to the dispatch queue. The user manually pointed out the discrepancy ("dude. there are 29 open issues!").
2. **Server-side label-exclusion qualifiers cannot encode "@me-assigned is OK, anyone-else-assigned is not"** — the search syntax has no `assignee:@me OR no:assignee` form, so the previous spec had to choose between `no:assignee` (which excludes prior-session self-assigns — the very case resumption needs) or unbounded (which over-fetches and relies on client-side dedup). The fix is to pick the second option and do all assignee gating client-side.

The fix in this revision: server-side fetch is purely `--state open` + optional `--label <L>` qualifiers (when the caller scopes to a label-bounded project subset). Every other eligibility check — author trust, assignee≠@me, blocking labels, `Blocked by #N` references, `closed-by-open-pr` membership — moves to the client-side filter pass below. The cost is one ~30-issue-larger JSON payload per setup pass; the win is no silent ~50% miss rate on the resumable-work case. The same fix lands in [drain.md's termination-assertion step 4](./drain.md#termination-assertion) (the fresh-fetch verification) and [steady-state.md step C's lightweight backlog re-check](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) so all three call-sites read the same universe and never disagree on what's workable.

The `author` field has two uses: (1) step 4's client-side trusted-author filter (the search-qualifier syntax has no `-author:` exclusion form, so this is necessarily client-side); (2) step 7's `originating_author_trust` dispatch-time gate (the third defense-in-depth layer). See [RATIONALE → Step 4 author field](../do-work-RATIONALE.md#step-4--why-the-author-field-is-fetched).

**Auto-triage priority labels.** Before ranking, ensure every fetched issue carries exactly one of `P0`/`P1`/`P2`. For each issue whose `labels` array contains **none** of those three, judge severity from the title, body, and existing labels (`bug`, `security`, `a11y`, `perf`, `chore`, …) using the [audit-rubrics severity buckets](../../skills/audit-rubrics/SKILL.md):

- `P0` — broken or unusable: runtime errors on the golden path, exposed secrets, RCE vectors, contrast failures on primary actions
- `P1` — significant friction or risk: confusing affordances, missing security headers, a11y failures on common flows, CVEs without patches
- `P2` — polish or moderate risk: spacing nits, copy improvements, low-severity CVEs with patches available, plus anything that doesn't fit P0/P1 but still merits work

When torn between two tiers, pick the lower-severity one. Apply exactly one label per issue:

```bash
gh issue edit <N> --repo <owner/repo> --add-label <Px>
```

Skip any issue that already carries one or more `P0`/`P1`/`P2` labels — preserve the human judgment that set them. Don't remove existing priority labels, and don't add a second one. Legacy `P3` labels are treated as unlabeled. See [RATIONALE → Auto-triage priority](../do-work-RATIONALE.md#step-4--auto-triage-priority-rationale).

Client-side filter (in this exact order — each gate's drop reason should be logged so the [unfiltered_open_count](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) invariant token is auditable):

- **Drop issues whose `author.login` (lowercased) is NOT in `trusted_authors`.** This is the dispatch-time security gate — see [step 1.7](#17-resolve-trusted-author-allowlist) for how the set is populated. An issue filed by a stranger on a public repo lands in step 2's `Untrusted author` bucket and never enters the workable queue, even if all the other filters pass. Belt-and-suspenders with the step-2 bucket pass: step 2 surfaces the count to the user; step 4 enforces the actual drop at dispatch time. Both read the same `trusted_authors` cache so they can never disagree.
- **Drop issues carrying any of the dispatch-gate labels** — `blocked:agent` (legacy, treated as `-hard` per [#300](https://github.com/mattsears18/shipyard/issues/300)), `blocked:agent-hard`, `blocked:ci`, `wontfix`, `needs-design`, `needs-triage`, `discussion`, `needs-refinement`, `needs-human-review`. This is the client-side equivalent of the previous server-side `-label:...` qualifiers (removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — see the wide-fetch rationale above). The set is deliberately enumerated, not pattern-matched — see "Why each `blocked:*` label is enumerated explicitly" below. **`blocked:agent-soft` is intentionally NOT in this set** (soft-blocked issues auto-clear at next-session backlog fetch — that's the entire point of the soft/hard split per #300; the in-session [soft-bail filter](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) handles the same-session retry-window case).
- Drop issues assigned to a user **other than** the gh-authenticated user (they own it). `@me`-assigned issues PASS — that's the resumable-work case (a prior session self-assigned the issue but didn't ship it), and the entire point of [#332](https://github.com/mattsears18/shipyard/issues/332)'s rework is to keep that case visible to the dispatch queue.
- Drop issues whose body contains `Blocked by #N` where #N is still open.
- **Drop issues that have an open linked PR authored by `@me` AND that PR is healthy.** The "healthy" qualifier is load-bearing: a closed/abandoned PR (the resumable case) does NOT lock the issue against re-dispatch, and an open-but-failing PR is in the orchestrator's [`failed_prs` / fix-checks bucket](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) rather than the issue's. Build the set **once per setup pass** from open PRs' `closingIssuesReferences` field — the structural projection GitHub itself uses to decide which issues auto-close on merge — joined against `author.login == @me` and `mergeStateStatus ∈ {CLEAN, HAS_HOOKS, UNSTABLE}` (i.e. no failing checks):

  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
  # Build the "open, @me-authored, healthy" closing set once per setup pass.
  # Drop the candidate issue if any healthy @me-authored open PR has it in
  # closingIssuesReferences. The healthy gate uses the same latest-per-name
  # rollup projection issue #333 added so a re-triggered green check doesn't
  # false-positive as still-failing.
  open_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me --limit 200 \
    --json number --jq '[.[].number] | join(" ")')
  closed_by_open_healthy_pr=$("${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "$open_pr_numbers" \
    | jq '[.[] | select(
        .mergeStateStatus == "CLEAN"
        or .mergeStateStatus == "HAS_HOOKS"
        or .mergeStateStatus == "UNSTABLE"
      )
      | select(
        ([(.statusCheckRollup // [])
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT")
        ] | length) == 0
      )
      | .closingIssueNumbers[]
    ] | unique')
  # Then, for each candidate issue #N, drop if jq -e ".[] | select(. == <N>)" matches.
  ```

  Why the substring-search form was removed (issue [#301](https://github.com/mattsears18/shipyard/issues/301)): the previous implementation fired three `gh pr list --search 'in:body "Closes #<N>"'` queries per candidate and dropped the issue on any hit. That's a substring match against PR bodies, not a semantic check — release PRs commonly list closed-by-this-release issues in their CHANGELOG bodies, and each `Closes #<N>` line in such a manifest silently suppressed the referenced issue from the workable queue even though the PR isn't actually closing it on merge. `closingIssuesReferences` is GitHub's authoritative signal for "does this PR auto-close this issue?" — it matches exactly the issues that will auto-close, with no false positives on CHANGELOG manifests, meta-issue PRs that quote closed children, or comment-quoted PRs. Cost: one `gh pr list` + one batched GraphQL call (vs N×3 search calls); accuracy: exact match against GitHub's own closing-link definition.

  Why the `@me` + healthy join was added (issue [#332](https://github.com/mattsears18/shipyard/issues/332)): the previous `closed-by-open-pr` check joined against every open PR regardless of author or health, so an open PR by another author claiming to close issue #N — or an open `@me`-authored PR that was sitting red with no fix-checks worker assigned — both excluded #N from the dispatch queue. The first case is overreach (other authors can't lock our queue); the second case re-introduces exactly the [#332](https://github.com/mattsears18/shipyard/issues/332) failure mode the wide-fetch rework was designed to prevent (an abandoned/red PR shouldn't hide its issue from the workable queue indefinitely).

  Cache for the duration of step 4 — open PRs don't change between filter passes within a single setup invocation.

**Why each `blocked:*` label is enumerated explicitly.** GitHub's search syntax (which `gh issue list --search` passes through) does NOT support label-name glob patterns — `-label:blocked:*` does not match `blocked:agent-hard` or `blocked:ci`; it's treated as a literal label name `blocked:*` which doesn't exist. The same constraint applies to the client-side jq filter — every block-tier label that should hide an issue from the workable queue must appear as its own literal name. The workable filter excludes `blocked:agent-hard` and the legacy `blocked:agent` (treated as `-hard` per [#300](https://github.com/mattsears18/shipyard/issues/300)'s migration). `blocked:agent-soft` is intentionally NOT excluded — soft-blocked issues auto-clear at next-session backlog fetch (the whole point of the soft/hard split is that subjective bails don't permanently hide work). `blocked:ci` is a PR-side label so it has no effect on issue search (issues never carry it) — included in the enumeration for defense in depth in case a future revision applies it to issues too. If future block tiers are added (`blocked:external`, `blocked:design`, etc.), enumerate each one here.

Sort the survivors:

1. **Prioritized label** (only if `--prioritize-label` was passed): issues carrying that label come first. Issues without it fall to the next tier.
2. **Priority label**: `P0` > `P1` > `P2` > unlabeled. Convention: `P0` = critical/release-blocker, `P1` = high (this cycle), `P2` = normal. After the step-4 auto-triage pass, the `unlabeled` tier should normally be empty — it remains as a safety net for issues triage somehow skipped, and as the fallback bucket for legacy `P3` labels. If an issue carries multiple priority labels, rank by the highest one present.
3. **Type**: `bug` > `fix(...)` titles > `feat(...)` titles > `chore(...)` > everything else.
4. **Staleness**: oldest `updatedAt` first within the same tier — stale work counts.

This ordered list is the initial `raw_backlog`. If empty AND no failing PRs exist (next step) → loop ends immediately; report "backlog empty" and stop.

### 4.5 Divert checks (main CI + PR pileup)

> **`--fast` skip:** When `--fast` is set, skip both 4.5a and 4.5b. Leave `main_ci.status = "unknown"` and `failing_pr_count_all = 0`. `divert_queue` stays empty. The user accepts the risk of dispatching into a red `main` or a ≥10-PR pileup — this is the documented tradeoff in the `--fast` arg description. The step-D periodic refresh does NOT run divert checks either when `--fast` was set (to preserve the latency savings for the full session). Note the skip in the end-of-session `--fast was used` advisory block.

Two repo-health conditions can preempt all normal work. Run these checks at setup, repopulate `divert_queue`, then continue. The same checks re-run during the periodic refresh (step D).

Both reads (4.5a and 4.5b) are part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 5. The aggregation logic (per-workflow grouping in 4.5a, rollup filtering in 4.5b) runs locally on the JSON returned from each call; no further network I/O is needed.

**4.5a — Main CI status.** Determine whether main is currently healthy by looking at *each workflow's* most-recent COMPLETED run on `<default-branch>`. Main is green only when every workflow's last completed run was a success. Evaluate at **per-workflow** granularity — never aggregate across workflows on a single commit, and never filter `--status completed` in the `gh run list` call (it hides in-progress workflows). See [RATIONALE → Step 4.5a CI aggregation](../do-work-RATIONALE.md#step-45a--why-per-workflow-ci-aggregation-matters) for the failure modes this prevents.

```bash
# Most recent 60 runs on the default branch (any status — DO NOT filter --status completed)
gh run list --repo <owner/repo> --branch <default-branch> \
  --limit 60 \
  --json databaseId,conclusion,status,displayTitle,headSha,url,createdAt,workflowName

# Branch protection — used to scope the red-gating set to required workflows only.
# 404 is the expected response on repos without branch protection (open-source forks,
# personal repos that never configured it); fall through to "all workflows gate".
gh api "repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks" \
  --jq '.checks // [] | map(.context)' 2>/dev/null
```

Compute per-workflow status, then aggregate:

1. Group runs by `workflowName`. Within each group, keep `gh`'s newest-first `createdAt` order.
2. For each workflow, find its most recent run whose `status == "completed"` AND whose `conclusion != "cancelled"`. That's the workflow's current health:
   - `conclusion in {success, skipped, neutral}` → workflow is **green**
   - `conclusion in {failure, timed_out, startup_failure, action_required}` → workflow is **red**
   - no qualifying completed run in the window (only `in_progress` / `queued` / `waiting` / `requested`, or every completed run in the window was `cancelled`) → workflow is **pending**

   `cancelled` runs are skipped over rather than treated as a verdict because the common cause on actively-developed repos is GitHub's concurrency-group auto-cancellation when a newer commit lands on the same branch (the *supersession* case) — that is normal traffic, not a CI failure, and the next non-cancelled run on a newer SHA carries the actual verdict. Hung-then-timeout cancellations and manual cancellations are also non-actionable by `fix-main-ci` (there's no "fix" for a manual cancel; only the next run's verdict matters), so the same skip-and-keep-looking rule applies uniformly across all cancellation causes. If every completed run for a workflow in the 60-run window is `cancelled`, the workflow's status falls through to **pending** and step-D's next refresh re-evaluates once a non-cancelled run completes. Closes [#261](https://github.com/mattsears18/shipyard/issues/261).
3. Resolve the **required-workflows set** that gates red aggregation. Closes [#262](https://github.com/mattsears18/shipyard/issues/262) — non-required workflows (post-release recovery helpers, infrastructure-state probes, scheduled cleanup jobs) commonly fail for reasons unrelated to code health and shouldn't trigger a `fix-main-ci` divert. Resolution order (first match wins; later layers override the same field per the standard config merge):
   - **Config: explicit list.** If `main_ci.required_workflows` is set to a non-empty array in the effective merged config, that list IS the required set. Match against each workflow's `workflowName` exactly (case-sensitive).
   - **Config: `all-workflows` mode.** If `main_ci.aggregation_mode == "all-workflows"`, every workflow gates (the pre-#262 behavior). Skip the branch-protection probe.
   - **Branch protection (default behavior, `main_ci.aggregation_mode == "branch-protection"`).** Read `repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks.checks[].context` (the `.context` field is the check-run name GitHub matches against, which equals the workflow name when the workflow has a single job — the common case). The returned list IS the required set. If the API returns 404 (no branch protection rule), an empty list, or any error, fall through to **all-workflows** (the safety default — when there's no signal that any workflow is non-required, gate on everything, matching pre-#262 behavior). When the rule does exist but the protected branch isn't the default branch in this repo (rare), the 404 fall-through still applies.

   Match each workflow's status to the required set. The required set splits workflows into two buckets:
   - **Gating bucket** — workflows whose name is in the required set. These are the only workflows that contribute to `main_ci.status` red.
   - **Informational bucket** — workflows NOT in the required set. Their per-workflow status (green/red/pending) is still computed and surfaced (see `non_required_red_workflow_names` below) so the user retains visibility into infra-health failures, but they do NOT cause a `fix-main-ci` divert.

4. Aggregate to a single `main_ci.status` using the **gating bucket only**:
   - any **gating** workflow is **red** → `main_ci.status = "red"`. Use the *most recent* red run across all red gating workflows as `earliest_red_run_*` (most actionable for the fix-main-ci dispatch). Collect **all** red gating-workflow names into `red_workflow_names` (sorted alphabetically).
   - else any **gating** workflow is **pending** → `main_ci.status = "pending"`
   - else every **gating** workflow is **green** → `main_ci.status = "green"`
   - else (no gating runs at all in the window, or the gating set is empty) → `main_ci.status = "unknown"`

Cache `{ status, earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count, required_workflow_names, required_workflow_source, non_required_red_workflow_names, non_required_red_workflow_count, checked_at: now }` in `main_ci`.

- `earliest_red_workflow_name` — the `workflowName` of the most recent red gating run (the same run whose `databaseId` is `earliest_red_run_id`). Used by the status line to show a single name in the compact format.
- `red_workflow_names` — sorted list of all red gating workflow names. Used by the banner to show the full list.
- `red_workflow_count` — `red_workflow_names.length`. Used by the status line truncation logic.
- `required_workflow_names` — sorted list of the resolved required set. Empty array when the source was `all-workflows` (no filter applied). Used by the end-of-session debug surfaces and `/shipyard:status`.
- `required_workflow_source` — one of `config-list`, `config-all-workflows`, `branch-protection`, `branch-protection-fallback-all-workflows`. Tells the maintainer where the gating set came from. The last value means a branch-protection probe was attempted but produced no usable list (404, empty, or error) — useful for diagnosing "why is `red_workflow_names` showing infra workflows?" on a repo that DOES have branch protection (e.g. wrong default branch, missing token scope).
- `non_required_red_workflow_names` — sorted list of red workflow names that are NOT in the required set. Surfaced in the status line and banner so the user still sees infra failures even though they don't divert. Empty when the source was `all-workflows`.
- `non_required_red_workflow_count` — `non_required_red_workflow_names.length`.

- If `main_ci.status == "green"` → clear any `fix-main-ci` entry from `divert_queue`.
- If `main_ci.status == "red"` → enqueue `{ kind: "fix-main-ci", target: "main", earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count }` into `divert_queue` — unless an entry is already in `divert_queue` OR an `in_flight` slot is already working `kind: "fix-main-ci"` (don't double-dispatch the diversion).
- If `main_ci.status == "pending"` → don't enqueue; the next step-D refresh re-evaluates once a run completes.
- If `main_ci.status == "unknown"` → don't enqueue.

**Never** report `main_ci.status = "green"` on the basis of a single successful workflow run. The status line must derive from the per-workflow aggregate above.

**4.5b — Failing-PR pileup.** Count open PRs across **all authors** whose check rollup contains a hard failure:

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs). Count distinct PR numbers → `failing_pr_count_all`. Cache the count and the matching PR numbers (`failing_prs_all_authors`).

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns the union of every check run for the PR's head SHA, including superseded runs — a check that ran, failed, was re-triggered, and passed appears twice (one FAILURE + one SUCCESS). A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk false-positives on every such PR, silently inflating `failing_pr_count_all` past the divert-threshold (`>= 10`) and triggering an unnecessary `fix-failing-prs-batch` divert against a pileup that has already cleared. De-duplicate by `name` and take the most recent entry per check (by `completedAt`, fallback `startedAt`) before checking for hard failures:

```bash
failing_pr_numbers=$(gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length > 0) | .number]')
failing_pr_count_all=$(echo "$failing_pr_numbers" | jq 'length')
```

- If `failing_pr_count_all >= 10` → enqueue `{ kind: "fix-failing-prs-batch", target: "pr-pileup", failing_pr_numbers: [...] }` into `divert_queue` — unless one is already enqueued OR `in_flight`.
- If `failing_pr_count_all < 10` → clear any `fix-failing-prs-batch` entry from `divert_queue`.

Both checks are cheap (two `gh` calls) and the cached results power the status line in step 5.5. Don't re-run them per dispatch — only at setup and at step D's periodic refresh.

### 5. Snapshot failing PRs

> **Lazy-load when `concurrency == 1`.** At C=1 the orchestrator runs sequentially — at most one slot is ever in flight. The failing-PR set is only relevant when there's a free moment to dispatch a fix-checks worker, and a free moment is guaranteed to exist whenever the single slot returns and all queues are empty. Skip this query at setup and defer it to the first idle turn in the steady-state loop (step D's Failed-PR scan). Set `failed_prs = []` at startup. The `-label:blocked:ci` filter note still applies when the deferred query eventually runs.

This read is part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch) — fire it in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b. The filtering / deduping logic runs locally on the returned JSON.

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs). Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). Same reasoning as step 4.5b above: `statusCheckRollup` returns every check run for the head SHA, and stale FAILURE entries superseded by later SUCCESS would otherwise re-enqueue PRs into `failed_prs` that are actually green. The orchestrator then dispatches a fix-checks worker, which returns `noop: already green` — wasted dispatch slot and tokens. De-duplicate first:

```bash
failed_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100 \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length > 0)]')
```

Each entry → push onto `failed_prs`, **deduped against entries already in `failed_prs`** (step 3c may already have enqueued some). These are the highest-priority work items *after* `divert_queue` because a red PR you opened last session won't auto-merge no matter how many new issues you ship. Note: this query is `@me`-scoped on purpose — `failed_prs` is for fix-checks work on PRs *you authored*. The all-authors count from step 4.5b feeds the divert decision, not this queue.

The `-label:blocked:ci` filter is still correct because [step 3d's auto-clear sweep](#3-ensure-label-exists--recover-from-prior-session) already ran — refreshed PRs are unlabeled by 3d and flow through normally; only genuinely-stuck PRs still carry the label here. See [RATIONALE → Step 5 filter correctness](../do-work-RATIONALE.md#step-5--why-the--labelblockedci-filter-is-still-correct).

### 5.7 Seed inherited DIRTY PRs into `session_prs` (cross-session drain hand-off)

Closes [#373](https://github.com/mattsears18/shipyard/issues/373) — the **cross-session DIRTY-PR blackhole**. The end-of-session drain's [`D_dirty` set](./drain.md#drain-protocol) — the only place `/shipyard:do-work` dispatches a fix-rebase worker — is computed from `session_prs`, and `session_prs` is populated *only* by step A's `shipped` reconciles (PRs this session opened) plus pre-existing `@me` PRs that fix-checks touched this session. A PR left `DIRTY` by a *prior* session is neither: this session didn't open it, and if it's DIRTY-but-green there's no failing check for the step-5 scan to enqueue into `failed_prs`, so no fix-checks worker ever touches it. Net effect: an inherited DIRTY PR is invisible to the drain forever — steady-state never dispatches fix-rebase (it's drain-only by design), and drain never sees the PR (it's not in `session_prs`). The PR sits DIRTY across every subsequent session until a human rebases it manually. Observed in `mattsears18/lightwork` across five consecutive sessions (PRs #1355, #1361, #1364, #1371 stranded 24+ hours).

This step closes the loop with the minimum-surgery shim from the issue's suggested behavior: snapshot the inherited DIRTY PRs authored by `@me` and seed them into `session_prs` at setup, so the existing drain machinery owns them. The drain's per-poll `D_dirty` classifier then dispatches a fix-rebase worker for each (subject to the same `--concurrency` cap, `rebase_blocked_prs` gate, and 3-successful-rebase rate cap that govern session-opened DIRTY PRs). No new dispatch surface, no change to the steady-state-never-dispatches-fix-rebase rule — the inherited PRs simply join the set the drain already watches.

**This is a divergence from the issue's literal mechanic** ("append `failed_prs` entries whose `mergeStateStatus == \"DIRTY\"` to `session_prs`"). `failed_prs` holds only red-check PRs; the repro PRs were DIRTY-but-green, so they were never in `failed_prs` to begin with. Seeding from `failed_prs` alone would miss exactly the PRs the issue is about. The correct source is a direct DIRTY-PR query, projected the same `@me` + healthy-checks way the drain's `D_dirty` set is.

This read is part of the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch) — it can fire in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5. Query `@me`-authored open PRs and keep those whose `mergeStateStatus == "DIRTY"` AND whose latest-run-per-name check rollup has **no** hard failure (the drain's [`D_dirty` definition](./drain.md#drain-protocol) — a PR that's both DIRTY *and* red is fix-checks work, not rebase work, and the step-5 scan already enqueued it):

```bash
inherited_dirty_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-is:draft' \
  --json number,mergeStateStatus,statusCheckRollup \
  --limit 200 \
  --jq '[.[]
    | select(.mergeStateStatus == "DIRTY")
    | select(
        [.statusCheckRollup
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
        | length == 0)
    | .number]')
```

Append each number to `session_prs`, **deduped** against entries already there (a PR this session opened and that has since gone DIRTY is already in `session_prs` — don't double-add). The dedup also means re-running this step is idempotent. Do NOT mark these PRs in any other queue (`failed_prs`, `ready_issues`, `divert_queue`) — `session_prs` membership is the entire mechanism; the drain's existing classifier does the rest.

**Why seed at setup rather than re-query in drain.** The drain's [initial snapshot](./drain.md#drain-protocol) is documented as "the set of PRs the orchestrator opened this session" plus fix-checks-touched PRs — keeping that definition narrow (it's the per-session ownership boundary that prevents the drain from babysitting unrelated authors' PRs forever). Seeding `session_prs` at setup is the explicit, auditable hand-off: the orchestrator is *adopting* these inherited DIRTY PRs into the current session's ownership set, which is exactly the semantic the issue asks for. The drain code stays unchanged; only the membership of the set it reads grows.

> **Lazy-load when `concurrency == 1`** — same carve-out as [step 5](#5-snapshot-failing-prs). At C=1 the inherited-DIRTY snapshot can defer to the first idle turn alongside the step-5 failed-PR scan; the drain only consumes `session_prs` at end-of-session, so seeding it any time before drain entry is sufficient. When deferred, [steady-state step D's failed-PR scan](./steady-state.md#d-periodic-refresh) runs this query in the same sub-step (it's the same `@me` open-PR list, just a different projection) and seeds `session_prs` then. Set the snapshot aside at startup and let step D pick it up.

### 5.8 Enforce the flake registry (chronic-flake escalation)

Closes [#385](https://github.com/mattsears18/shipyard/issues/385) — phase 2 of the cross-PR flake registry. [Phase 1](#5-snapshot-failing-prs) (issue #378, `scripts/flake-registry.sh`) shipped the data layer: each `fix-checks-only` worker records a flake event when it concludes a failure was a flake, and `flake-registry.sh crossed` names which (workflow, job, test) flakes have crossed the escalation threshold (≥ `rerun_threshold` events spanning ≥ `distinct_prs_threshold` distinct PRs within `window_days`). Phase 1 deliberately stopped at "name the crossed flakes." This step is the **enforcement consumer** — it reads `crossed` and performs the three configured escalation actions so a chronic flake gets root-caused instead of silently re-run forever.

**Gate on `flake_registry.enabled`.** Skip this step entirely unless the effective config has `flake_registry.enabled == true` (it defaults to `false`, preserving pre-#378 behavior). The check is one config read against the already-loaded `EFFECTIVE_CONFIG` (step 0.4):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
FLAKE_ENABLED=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
if [ "$FLAKE_ENABLED" = "true" ]; then
  # Read crossed flakes and enforce the per-row actions. The helper computes
  # `crossed` itself (passing the configured window/thresholds through), files
  # a deduped tracking issue per crossed flake, writes the crossed key to
  # <repo-root>/.shipyard/flake-suspects.txt, and labels affected PRs blocked:ci
  # — each action idempotent so re-running across sessions doesn't duplicate
  # side effects. --repo-root is the orchestrator worktree (where the
  # per-repo flake-suspects file lives, alongside .shipyard/config.local.json).
  "${CLAUDE_PLUGIN_ROOT}/scripts/flake-enforce.sh" enforce \
    --repo "<owner/repo>" \
    --repo-root "$(git rev-parse --show-toplevel)" \
    2>&1 | sed 's/^/[flake-enforce] /' || echo "[flake-enforce] advisory: enforce pass errored; continuing setup"
fi
```

**Read site: setup, once per session.** The issue's open question ("setup once per session vs. per-dispatch") resolves to **setup** — it's the cheapest site and the registry escalation state changes slowly (a flake crosses the threshold over days, not within a single session's dispatch cadence). The one piece of mid-session freshness that matters — a flake escalated by *this* session's own `fix-checks-only` recording — is still honored without a per-dispatch enforce pass, because the `stop-auto-rerunning` consumer (fix-checks-only's [pre-rerun suspects check](../../agents/issue-worker/fix-checks-only.md#fix-loop)) re-reads `.shipyard/flake-suspects.txt` on every dispatch. So a flake that crosses mid-session is suppressed by the next fix-checks worker even though the issue-filing / PR-labeling actions ran only at setup. Per-dispatch enforcement of the issue-filing and labeling actions is a deliberate non-goal for this slice; see the issue's scope notes.

**Idempotence is load-bearing here.** `/do-work` re-runs setup every session. The enforce helper dedupes all three actions: `file-tracking-issue` skips when an OPEN issue already carries the flake's `flake-key=<...>` marker; `stop-auto-rerunning` skips a key already in the suspects file; `apply-blocked-ci` skips a PR already labeled `blocked:ci`. A session that finds no newly-crossed flakes (or only already-enforced ones) makes zero GitHub writes.

This step is **independent of the parallelization batch** (it shells out to a local helper that itself calls `gh`, rather than being a single projectable `gh` query the orchestrator can co-fire). Run it after the failing-PR snapshots (steps 5 / 5.7) so the `blocked:ci` labels it applies are visible to any subsequent `-label:blocked:ci`-filtered query in the same session. It's also fine to defer to the first idle turn at C=1 alongside the other lazy-loaded snapshots — the escalation state isn't time-critical within a session.

### 6. Initial scope pre-flight

> **Just-in-time when `concurrency == 1`.** At C=1 pre-flighting `2 × concurrency` (i.e., 2) candidates at setup is wasted token spend: by the time the single slot returns, rankings may have shifted (new comments, refined issues, closed blockers) and the pre-flighted decisions are stale. Instead, pre-flight **only the top candidate** immediately before each dispatch (inline with step 7 and step C). This converts the upfront batch-scope call into a single just-in-time call per dispatch. The rest of step 6's mechanics — ready/deferred shapes, `claimed_paths` partitioning, `deferred_issues` list, the comment-and-drop for deferred entries — are unchanged; only the timing (upfront vs per-dispatch) and the batch size (2 vs 1) change. Set `ready_issues = []` at startup; populate lazily.

**Rolling pre-flight (C≥2) — dispatch on the first result, don't wait for all.** The previous spec blocked until all `2 × concurrency` scoping agents returned before step 7 could fire — ~30 s of synchronous latency before the first worker launched. The rolling model fires the same batch in the background and dispatches as soon as ONE entry lands in `ready_issues`, hiding the remainder of the scope latency behind real worker execution. Closes [#233](https://github.com/mattsears18/shipyard/issues/233).

**Execution model for C≥2:**

```
step 6 opens timing window
  └── fire 2N scoping Agent calls with run_in_background: true
        ↓ first result arrives → push to ready_issues → step 7 dispatches immediately
        ↓ subsequent results arrive → push to ready_issues (queue fills while workers run)
  timing window stays open until all background scope agents complete
  record-scope-preflight fires after the last background agent returns
```

**Timing instrumentation (issue #238).** Open the timing window before firing the batch; close it after the last background scoping agent returns. The `record-scope-preflight` call is also deferred to that point so `ready-count` and `deferred-count` reflect the full batch.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
SCOPE_START_EPOCH=$(date -u +%s)
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# ... fire all 2N scoping agents with run_in_background: true ...
# ... step 7 dispatches the moment the first result lands in ready_issues ...
# ... remaining scope results arrive asynchronously and push to ready_issues ...
# ... after the LAST background scope agent completes: ...

SCOPE_END_EPOCH=$(date -u +%s)
SCOPE_ELAPSED=$(( SCOPE_END_EPOCH - SCOPE_START_EPOCH ))

"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# Record the per-candidate metrics for reporting.
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" record-scope-preflight \
  --session-id "<session-id>" \
  --candidates-scoped "${candidates_dispatched}" \
  --ready-count "${#ready_issues[@]}" \
  --deferred-count "${deferred_count}" \
  --elapsed-seconds "${SCOPE_ELAPSED}" 2>/dev/null || true
```

#### Pre-scope orchestrator-side detectors (synthetic defers)

**Before dispatching a scope agent against each candidate, run a small set of mechanical detectors on the issue body.** When a detector fires, the orchestrator synthesizes a deferred entry directly and **skips the scope-agent dispatch** for that candidate — the detector's evidence is already conclusive. This is a defense-in-depth layer in front of the scope agent: detectors catch structural conflicts (the body proposes a change that the worker's hard rules forbid touching) that would otherwise produce a "ready" scope return → worker dispatch → mid-run blocked-tool-call → orphan branch with no PR. Closes [#346](https://github.com/mattsears18/shipyard/issues/346).

The detector batch runs once per candidate, synchronously, immediately before the per-candidate scope-agent dispatch. Detectors are cheap pure string-matches against the issue body — no network calls, no `gh` round-trips. A candidate that trips any detector never reaches the scope-agent dispatch step.

**Detector 1 — `.github/workflows/` change proposal.** When the issue body literally contains the path fragment `.github/workflows/` (case-sensitive match; covers both prose mentions like *"add `.github/workflows/security.yml`"* and code-fence headers like ```` ```yaml .github/workflows/ci.yml ````), the body is proposing a CI workflow change. Workers' hard rules ([issue-work.md step 2 + Don't list](../../agents/issue-worker/issue-work.md), [fix-checks-only.md Don't list](../../agents/issue-worker/fix-checks-only.md), and the harness's auto-mode classifier) all forbid `.github/workflows/` modifications — a worker dispatched against such an issue produces a branch but can't open a PR. Synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue body proposes a `.github/workflows/` change — CI workflow modifications are gated to human review (worker hard rules + auto-mode classifier block the PR). Needs a maintainer to evaluate the proposed workflow content for prompt-injection risk, secret-leak risk, and CI-correctness before any worker can ship it.",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes .github/workflows/<filename-or-path-fragment> change — CI workflow modification requires human review (auto-mode classifier blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<filename-or-path-fragment>` is extracted by reading the first `.github/workflows/<token>` substring in the body, taking the token up to the first whitespace, backtick, or newline. If extraction fails (e.g., the body just mentions `.github/workflows/` without naming a file), use the literal token `<unspecified>`. The point is the evidence_pointer's structured prefix `Proposes .github/workflows/`, not the file's exact name — the validator (next section) keys on the prefix.

`provenance: "orchestrator-judgment"` is correct here: the orchestrator (not a scope agent) made this defer. Per [`do-work.md`'s `deferred_issues` entry](../do-work.md#orchestrator-state), `orchestrator-judgment` provenance entries get re-validated by [drain.md 5.a](./drain.md#5a--re-validate-orchestrator-judgment-entries) before drain — that re-validation dispatches a fresh scope agent, which (per the cross-reference at the end of this section) ALSO re-runs the pre-scope detector batch first. The synthetic defer stays valid across re-validation as long as the body still names a workflow path.

**Detector 2 — Claude-Code self-modification target proposal.** When the issue body literally contains any of the path fragments `.claude/settings.json`, `.claude/settings.local.json`, or `.mcp.json` (case-sensitive match; covers both prose mentions like *"add a hook to `.claude/settings.json`"* and code-fence headers like ```` ```json .claude/settings.json ````), the body is proposing a Claude-Code self-modification change. Claude Code's auto-mode classifier treats edits to these paths as **Self-Modification** and applies a HARD BLOCK that is **not cleared by user intent** — even explicit "make this edit" instructions are rejected, so the Edit / Write / Bash-heredoc paths are all blocked at the harness level. A worker dispatched against such an issue burns tokens producing the proposed diff, then either gets denied at the Edit step (best case: clean `blocked: classifier denied` return) or — worse — ends up posting a fabricated-reasoning comment to the issue when the classifier reasoning isn't surfaced cleanly (the failure mode `shipyard:worker-preamble` § "After a classifier denial" exists to close). The structurally correct outcome is the same as Detector 1: skip the dispatch, defer for human review. Synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue body proposes a Claude-Code self-modification target change (.claude/settings.json, .claude/settings.local.json, or .mcp.json) — the auto-mode classifier applies a HARD BLOCK on edits to these paths that is not cleared by user intent, so no worker can ship the change. Needs a maintainer to apply the proposed diff manually.",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes <self-modification-path> change — Claude-Code self-modification HARD BLOCK requires human application (auto-mode classifier blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<self-modification-path>` is the first matching path fragment found in the body (`.claude/settings.json`, `.claude/settings.local.json`, or `.mcp.json` — checked in that order; longer-prefix wins so `.claude/settings.local.json` is reported correctly when both prefixes would technically match). If multiple paths are mentioned, report only the first match; the maintainer reading the issue will see the full body. The point — same as Detector 1 — is the evidence_pointer's structured prefix `Proposes .claude/` or `Proposes .mcp.json`, not the exact file. The validator (next section) keys on the prefix family, not the specific path.

The `provenance: "orchestrator-judgment"` rationale, handling steps, and cross-references in the Detector 1 section apply unchanged here — both detectors share the same recording path (skip the per-class validator; post the standard `Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>` comment; append to `deferred_issues`; remove from `raw_backlog`; increment `defers_this_turn`; do NOT dispatch a scope agent). Closes [#348](https://github.com/mattsears18/shipyard/issues/348).

**Note — why not `CLAUDE.md`.** The issue body that motivated this detector also flagged `CLAUDE.md` as a "borderline" Claude-Code self-modification target. We intentionally do NOT match `CLAUDE.md` in the detector: many edits to project memory (adding a new repo rule, updating the release-process documentation, fixing a typo in the configuration block) ship cleanly through workers without classifier interference; only a narrow subset (changes to behavior rules) hits the HARD BLOCK. False-positively deferring every `CLAUDE.md`-touching issue would lose substantial work that a worker could ship. If `CLAUDE.md`-blocking cases prove common in practice, file a follow-up issue documenting the failure mode and the detector can be extended; today's evidence supports the narrow path-set above.

**Handling the synthetic deferred entry.** Apply the same recording path as a scope-agent-returned defer (per [Handling each returned entry → Deferred entries → Recording path](#handling-each-returned-entry-fires-as-each-background-agent-completes)):

1. **Skip the per-class validator.** The orchestrator constructed this entry; its `evidence_pointer` already matches the per-class shape table (`human-decision-required` accepts the `Proposes .github/workflows/` structured prefix — see the [Per-class evidence shapes](#per-class-evidence-shapes--what-evidence_pointer-must-look-like) table below). Running the validator against the orchestrator's own synthesis would be redundant.
2. **Post the comment.** Use the standard recording-path comment text (`Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>`). The maintainer reading the issue sees a clear explanation of why the workflow proposal is gated.
3. **Append to `deferred_issues`** with the synthesized entry exactly as shown above.
4. **Remove the issue from `raw_backlog`** as part of the standard "remove every processed issue number" sweep (line below the per-entry handler).
5. **Increment `defers_this_turn`** by 1 (same as scope-agent defers — feeds step E's invariant line and the pre-drain audit).
6. **Do NOT dispatch a scope agent for this candidate.** The detector's evidence is conclusive; spending a scope-agent's ~30 s + tokens on a defer the orchestrator already knows it will produce is waste.

**Why this lives at the orchestrator and not in the scope-agent prompt.** A scope-agent prompt instruction *could* tell the agent to defer on workflow-path mentions, but prompts aren't contracts — the same defense-in-depth posture that motivated [#302](https://github.com/mattsears18/shipyard/issues/302)'s orchestrator-side `evidence_pointer` validator applies here. The orchestrator can detect this case in three lines of string-match; the scope agent's deliberation adds nothing the orchestrator doesn't already know. Putting the detector at the orchestrator ALSO makes the defer survive a scope-agent version that hasn't been updated — the detector is the load-bearing mechanism, the agent prompt is informational at best.

**Future detectors.** The detector batch is intentionally extensible — when a new "worker hard rule conflicts with a recurring body shape" failure mode shows up, file an issue documenting the pattern and add a new detector here. Detectors share the same shape: a pure body string-match → a synthesized deferred entry with `provenance: "orchestrator-judgment"` and a structured `evidence_pointer` that matches the validator's per-class shape. The current single-detector implementation is the starting point; the section is structured so additional detectors slot in as numbered sub-sections without re-organizing the surrounding handler.

**Cross-references for re-validation paths.** [Drain.md 5.a's re-validation](./drain.md#5a--re-validate-orchestrator-judgment-entries) dispatches a fresh scope agent for `orchestrator-judgment` defers and [5.b's re-validation](./drain.md#5b--re-validate-scope-agent-entries) does the same for `scope-agent` defers. Both paths re-run the **same per-candidate pre-scope detector batch** documented in this section before firing the scope agent — a re-validation that re-detects any of the detector triggers (workflow-path mention, Claude-Code self-modification path mention, future detectors) synthesizes the defer again without dispatching the agent, just as the initial pass did. This keeps the synthesizer behavior load-bearing across both the initial pre-flight and every re-validation point; a body that proposes a change to any path the detector batch guards can never slip past into a worker dispatch by being re-scoped.

Take the top `2 × concurrency` from `raw_backlog`. Dispatch read-only scoping agents in parallel with `run_in_background: true` (one message, multiple background `Agent` tool calls). Each returns **one of two shapes**:

**Ready shape** (default — the candidate is shippable as a single-worker dispatch, possibly as a phase-1 slice with explicit out-of-scope items):

```
{ issue: N, files: ["path/a", "path/b", ...], lockfile_sections: ["overrides", "dependencies", ...], phase_1_scope?: "<one-line description of the phase-1 slice + what's out of scope>" }
```

`phase_1_scope` is **optional** and present only when the agent chose to slice — it tells the orchestrator what the worker will ship and what the worker MUST file as follow-up issues rather than touch. Absent on plain ready returns (single-phase issues). When present, it's passed through to the dispatched worker as an extra line in the dispatch prompt's "Context" block so the worker stays inside the phase-1 envelope.

**Deferred shape** (the scope agent read the issue + code and concluded the fix isn't ship-able as a single `shipyard:issue-worker` dispatch — even as a phase-1 slice — because there's no first phase that can ship independently: external decision pending, every phase depends on infrastructure that isn't provisioned, etc.):

```
{ issue: N, deferred: "<one-paragraph reason the orchestrator should tell the human>", defer_reason_class: "<class>", evidence_pointer: "<mechanical citation>", would_be_dispatchable_as_phase_1_if?: "<one-line description of the unblocked condition>" }
```

`defer_reason_class` is **required** on every deferred return. Valid values (one and only one per entry):

- `external-dependency` — gated on an upstream vendor, SDK, third-party API, or off-repo system that the worker can't move.
- `human-decision-required` — needs a product / design / legal call before any code path can be picked.
- `untrusted-author` — defense-in-depth defer for issues whose author hasn't been re-cleared against the trust list. (Rare — step 1.7 normally drops these before scope.)
- `confirmed-blocker-still-open` — gated on a referenced issue or PR (e.g. `Blocked by #N`) that is still open. The agent confirmed the named blocker is the load-bearing block.
- `confirmed-non-shippable-as-single-PR` — the agent attempted to find a phase-1 slice and failed. Use this class only when the agent CAN'T construct a phase-1 description; otherwise prefer the ready-with-`phase_1_scope` form.

`evidence_pointer` is **required** on every deferred return ([#302](https://github.com/mattsears18/shipyard/issues/302)) — a single concrete, mechanically-verifiable citation that grounds the chosen `defer_reason_class`. The orchestrator validates the pointer against the per-class shape table below before accepting the defer; a deferred return whose `evidence_pointer` is missing, empty, or doesn't match its class's shape is **rejected as a malformed defer** — see [Handling each returned entry → Deferred entries](#handling-each-returned-entry-fires-as-each-background-agent-completes) for the rejection path. The point is to prevent plausible-sounding-prose defers (the failure mode the rationale's [Phase-slicing bias + classified defers](../do-work-RATIONALE.md#phase-slicing-bias--classified-defers-issue-298) section already documented for `defer_reason_class` — same fix, one level deeper) from passing the audit; an agent that can't produce mechanical evidence for the class it picked isn't allowed to defer.

**Per-class evidence shapes — what `evidence_pointer` MUST look like:**

| Class | Required `evidence_pointer` shape | Example |
|---|---|---|
| `external-dependency` | A named external system or dependency the worker can't move, with a one-token identifier the orchestrator can read literally | `Stripe API change waiting on rollout` / `expo-router 4.x not yet published to npm` / `Apple Pay merchant ID provisioning pending` |
| `human-decision-required` | The specific decision being waited on, named in concrete terms (product, design, legal, billing, **CI/infrastructure policy**, **Claude-Code self-modification policy**) | `copy decision pending for placeholder field in src/components/EmailForm.tsx:42` / `legal review of TOS update pending` / `pricing change requires CFO sign-off` / `Proposes .github/workflows/security.yml change — CI workflow modification requires human review (auto-mode classifier blocks worker dispatch)` / `Proposes .claude/settings.json change — Claude-Code self-modification HARD BLOCK requires human application (auto-mode classifier blocks worker dispatch)` |
| `untrusted-author` | The login the orchestrator should re-validate against the trust list (lowercased GitHub handle) | `author: drive-by-contributor` |
| `confirmed-blocker-still-open` | One or more `#<N>` references to OPEN issues/PRs the agent confirmed are still open (must be parseable as `#<digits>` references) | `Blocked by #1077` / `Blocked by #1077, #1082` |
| `confirmed-non-shippable-as-single-PR` | A specific mechanical reason no phase-1 slice exists — typically a multi-service coordination requirement, a missing dependency that would itself need install+lock+test+ship as its own PR, or a referenced design artifact (Figma URL, RFC document) that hasn't been imported into the codebase yet | `Missing dependency: @company/payments-sdk not in package.json` / `Multi-service coordination: needs synchronized deploy of payments-api + customer-api` / `Body cites Figma file <url> that hasn't been imported into design-tokens.json` |

**Rejected evidence_pointer shapes** (the orchestrator's per-class validator will reject any defer whose pointer matches these patterns — see [Handling each returned entry → Deferred entries](#handling-each-returned-entry-fires-as-each-background-agent-completes) for the rejection path that promotes the issue back to `raw_backlog`):

- *"Looks like a multi-PR migration"* — no specific evidence; the speculative-judgment shape this issue exists to eliminate.
- *"Touches three platforms — likely complex"* — cross-platform ≠ multi-PR. Many cross-platform issues are tractable single-file fixes.
- *"UX change — probably needs design review"* — the scope agent isn't qualified to gate on design intent.
- *"Body is vague"* — that's a worker-side bail (handled by `agents/issue-worker/issue-work.md` step 2's `blocked: ambiguous` path), not a scope-side defer.
- *"Cross-platform — looks like a multi-PR migration"* — this is the exact shape that drained session `shipyard-do-work-20260524T165717Z-7245` per [#299](https://github.com/mattsears18/shipyard/issues/299) and motivated #302.
- Empty string, `null`, or any pointer that doesn't match the per-class shape in the table above.

`would_be_dispatchable_as_phase_1_if` is **optional but encouraged** — a one-line condition under which the issue would become a phase-1 ready candidate (e.g. "Phase-1 stub of the email-first flow is dispatchable once a copy decision is made on the placeholder field"). Used by [`drain.md` step 5.b](./drain.md#5b--re-validate-scope-agent-entries)'s pre-drain re-validation to ask whether the unblocking condition has changed — if it has, the issue is promoted back to `raw_backlog` for a fresh scope pass.

Scoping-agent prompt instruction: *Default to slicing, not deferring. If the issue is multi-phase, RETURN the smallest dispatchable phase-1 slice as a ready shape with explicit `phase_1_scope` text listing what's in and what's explicitly out of scope (the worker will file the out-of-scope items as follow-up issues, one per phase). Return the deferred shape ONLY when you can cite SPECIFIC MECHANICAL EVIDENCE for the defer — a named open blocker issue (`Blocked by #N`), a missing dependency the worker can't reasonably install/lock/test/ship in the same PR, multi-service coordination that requires synchronized deploys, an external vendor change the worker can't move, or a referenced design artifact (Figma, RFC) that hasn't been imported into the codebase. Speculative reads of the body — "looks like a multi-PR migration", "touches three platforms — likely complex", "UX change — probably needs design review", "body is vague" — are NOT evidence and will be rejected by the orchestrator's per-class validator. Every deferred return MUST include an `evidence_pointer` field that matches the per-class shape table in setup.md step 6; defers without an `evidence_pointer`, or with one that fails the per-class shape check, are treated as malformed and the issue is promoted back to raw_backlog for a fresh scope pass. When in doubt — default to ready (with phase_1_scope if multi-phase). When the issue truly can't be sliced, pick a `defer_reason_class` from the five allowed values, populate `evidence_pointer` with the concrete mechanical citation for that class, and, where possible, fill `would_be_dispatchable_as_phase_1_if` with the condition that would unblock the slice — the orchestrator's pre-drain re-validation reads that field to decide whether the unblocking condition has changed.* See [RATIONALE → Deferred shape](../do-work-RATIONALE.md#step-6--why-scope-pre-flight-has-a-deferred-shape) and [RATIONALE → Evidence-backed defers (issue #302)](../do-work-RATIONALE.md#evidence-backed-defers-issue-302).

`lockfile_sections` (ready shape only) is the set of root-manifest sections the candidate will touch — typically top-level keys in `package.json` (`overrides`, `dependencies`, `devDependencies`, `peerDependencies`, `optionalDependencies`, `scripts`, `engines`, `config`, `workspaces`, `resolutions`, `pnpm`, etc.). For non-`package.json` lockfile-class files (`Gemfile`, `go.mod`, `Cargo.toml`, `requirements.txt`, generated SQL migrations, root build config like `vite.config.ts` / `tsconfig.json`) use the filename as the section token (e.g., `"go.mod"`, `"Cargo.toml"`, `"migrations"`). Return an **empty array** for issues that don't touch any lockfile-class file. Budget ~30s per scoping agent.

**Handling each returned entry (fires as each background agent completes):**

- **Ready entries** — partition each `files` array into `{ hard: [...], soft: [...] }` by matching each path against the soft-collision glob set defined in the [Dispatch rules](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) (default + any `--soft-collision-path` extensions). Paths that match a soft-collision glob go into `soft`; everything else goes into `hard`. The orchestrator does the partitioning — scoping agents return raw paths; they don't need to know about the tier distinction. Cache the partitioned result as the candidate's `claimed_paths`. Cache the optional `phase_1_scope` string (when present) on the candidate so the dispatch site can pass it into the worker prompt's "Context" block — workers told they're working a phase-1 slice MUST stay inside the described envelope and file the explicitly-out-of-scope items as follow-up issues (one per phase) rather than expanding scope. Push onto `ready_issues` (preserving rank). **If this is the first ready entry and step 7 has not yet dispatched, dispatch immediately** — do not wait for the remaining background scope agents to finish.
- **Deferred entries** — first run the **per-class `evidence_pointer` validation** ([#302](https://github.com/mattsears18/shipyard/issues/302)), then either reject the malformed defer or record the valid one.

  **Evidence validation** (runs before any of the recording steps below):

  Check that `evidence_pointer` is present and non-empty AND matches the per-class shape table in the [Deferred shape](#6-initial-scope-pre-flight) docs. The shape checks are intentionally lightweight — string-matching the orchestrator can run inline without dispatching a fresh agent:

  - `confirmed-blocker-still-open` → `evidence_pointer` must contain at least one `#<digits>` reference (regex: `#\d+`). For each `#N` referenced, the orchestrator does a single `gh issue view <N> --repo <owner/repo> --json state -q .state` and confirms the named blocker is `OPEN`. If any cited blocker is `CLOSED` / `MERGED`, the defer is **rejected** — the supposed block has already resolved. If none of the cited references parse as `#<digits>`, the defer is also rejected as malformed.
  - `external-dependency` → `evidence_pointer` must not match the rejected shapes (no "looks like", "probably", "likely", "seems", "feels" speculative-judgment words). The orchestrator does not validate that the named external system exists (that would be unbounded) — the check is shape-only.
  - `human-decision-required` → same speculative-judgment word check as `external-dependency`. Additionally, generic phrases like "needs design review", "needs product input" without a specific decision named (e.g., what copy is being decided, what design surface) are rejected. The structured prefixes `Proposes .github/workflows/`, `Proposes .claude/settings.json`, `Proposes .claude/settings.local.json`, and `Proposes .mcp.json` are explicitly accepted (these are the shapes the [pre-scope detectors](#pre-scope-orchestrator-side-detectors-synthetic-defers) synthesize — Detector 1 produces the workflow shape, Detector 2 produces the Claude-Code self-modification shape; the decision being named is whether to accept the proposal, and both CI/infrastructure-policy and Claude-Code self-modification policy are valid decision categories per the per-class shape table above).
  - `untrusted-author` → `evidence_pointer` must contain `author: <login>` where `<login>` matches GitHub's login regex (`[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}`). The orchestrator does not re-validate the login against `trusted_authors` here (step 1.7 already did that); this is a shape-only check that the agent supplied a concrete login.
  - `confirmed-non-shippable-as-single-PR` → `evidence_pointer` must start with one of: `Missing dependency:`, `Multi-service coordination:`, `Multi-PR sequence:`, `Body cites <artifact>:` — these are the structured prefixes the rationale's worked-example catalog covers. Free-form text without one of these prefixes is rejected.

  **Rejection path** (when validation fails): do NOT record into `deferred_issues`. Instead:

  1. Log `[scope-preflight] #<N> deferred return REJECTED — evidence_pointer "<pointer>" does not match shape for class <defer_reason_class>: <specific reason>`. The `<specific reason>` is the failed check (e.g. `cited blocker #1077 is CLOSED`, `contains speculative phrase "looks like"`, `missing required prefix`).
  2. Post a comment on the issue: `Scope-preflight rejected this defer (class=<defer_reason_class>) — evidence_pointer "<pointer>" did not meet the per-class shape requirement: <specific reason>. Re-queued for a fresh scope pass next session; if you want to override, file a follow-up with explicit acceptance criteria.` This makes the rejection visible to the human reading the issue thread.
  3. **Push the issue number back onto `raw_backlog`** (preserving rank from where it was originally pulled). The next dispatch will re-scope it with a fresh scope agent, which gets another chance to either ready it (with `phase_1_scope`) or supply mechanically-valid evidence. Do not increment `defers_this_turn` — the defer was rejected.
  4. Remove from any in-flight scope-pre-flight tracking state so the same agent's return isn't double-counted.

  **Recording path** (when validation passes):

  1. Post a comment on the issue: `Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>` — and when the agent supplied `would_be_dispatchable_as_phase_1_if`, append a second paragraph: `Phase-1 dispatchable if: <would_be_dispatchable_as_phase_1_if>`. Use `gh issue comment <N> --repo <owner/repo> --body "..."`. If the comment fails (rate limit, permission), log an advisory and continue — don't block the pre-flight pass on a single comment failure.
  2. Append the entry `{ issue: N, reason: "<deferred reason>", defer_reason_class: "<class from the agent's return>", evidence_pointer: "<pointer from the agent's return>", provenance: "scope-agent", deferred_at: "<current ISO-8601 UTC timestamp>", would_be_dispatchable_as_phase_1_if?: "<from the agent's return when provided>" }` to a session-level `deferred_issues` list (a new piece of orchestrator state — initialize as `[]` at startup alongside `ready_issues` / `raw_backlog`). The `provenance: "scope-agent"` value records that a real scope agent read the codebase and made this call — see [`do-work.md`'s `deferred_issues` entry](../do-work.md#orchestrator-state) for the valid provenance values, the `defer_reason_class` allowed set, the `evidence_pointer` field, and the restriction on mid-session writes. If the agent's return is missing `defer_reason_class` (older scope agent that hasn't been updated, malformed return), default the class to `confirmed-non-shippable-as-single-PR` and log `[scope-preflight] #<N> deferred return missing defer_reason_class — defaulted to confirmed-non-shippable-as-single-PR`. The `evidence_pointer` field has no such default — its absence triggers the rejection path above, not a default. Increment `defers_this_turn` by 1 — this feeds the step E invariant line's `defers_this_turn` token and the pre-drain audit. This feeds the end-of-session summary's `Deferred:` block (see [End-of-session summary](./cleanup-summary.md#end-of-session-summary)).
  3. **Do not** add a label, do not close the issue, do not assign to a human. The issue stays open with the diagnosis comment — the human reads the comment and decides what to do (open a multi-PR plan, escalate, defer to a sprint, etc.).

  **Why a rejection path and not just stricter prompting.** The prompt instruction biases the agent toward evidence-backed defers, but prompts are not contracts — a sufficiently confident agent can still produce a defer with a speculative `evidence_pointer` like "probably needs design review". The orchestrator-side validator is the hard gate: speculative-judgment text gets caught by the per-class shape check before it lands in `deferred_issues`. This is the same defense-in-depth posture as the body-vs-codebase rule in `issue-worker.md` step 2 (the worker re-derives the implementation from the codebase even when the body suggests one) — the prompt is the first line, the orchestrator's mechanical check is the load-bearing second line. See [RATIONALE → Evidence-backed defers (issue #302)](../do-work-RATIONALE.md#evidence-backed-defers-issue-302) for the full motivation.

Remove every processed issue number from `raw_backlog` regardless of which shape was returned (ready *or* deferred) — both are "done" from the scoping pass's perspective. Issues whose pre-scope detector synthesized a deferred entry (per the [Pre-scope orchestrator-side detectors](#pre-scope-orchestrator-side-detectors-synthetic-defers) section above) are also removed by this sweep — the detector's own handling step 4 names this explicitly, but the bulk remove here is the unified mechanism. (The Rejection path in the Deferred-entries handler above explicitly re-pushes the issue back onto `raw_backlog` after the bulk remove, preserving the issue's original rank — that's the one exception, and it's deliberate: a rejected defer is "not done" and needs another scope pass.)

**First-dispatch latency target.** The rolling model cuts first-dispatch latency from ~30 s (wait all 2N agents) to ~5–10 s (wait only the fastest scoping agent in the batch). Subsequent dispatches read directly from `ready_issues` — no scope-wait at all when at least one scoped entry is queued.

**Edge case — all entries are deferred.** If every scoping agent in the initial batch returns a deferred shape (unlikely but possible), `ready_issues` stays empty. Step 7 cannot dispatch. Proceed to step 6.8 (setup timing flush) and record a `[scope-preflight] all candidates deferred — no initial dispatch` advisory; the steady-state loop will attempt scope-refill on the next turn.

The same handling applies anywhere scoping runs (step 6 initial pre-flight + step D's background scope refill). A scoping agent's return contract is identical across those call sites; the orchestrator branches on `deferred` presence the same way each time.

### 6.5 Status line + state-change banners (UI)

There are two UI surfaces — both unconditionally re-print whenever repo-health state changes, so the user never has to scroll back to figure out what's going on.

#### Status line — one-line repo-health header

Print before the initial pool fill, and again at the top of any turn where state visibly changed (a completion landed, a divert flipped, the failing-PR count crossed the threshold either way, main flipped color, or a soft-collision claim count changed). Format:

```
/do-work · <owner/repo> · main:<emoji> · in-flight: <n>/<concurrency> [<labels>] · failing PRs: <m> (@me: <k>)<soft-suffix><divert-suffix>
```

Fields:

- **main:** — `🟢 green`, `🔴 red (<workflow-summary>, run <id>)`, `⏳ pending`, or `❔ unknown`. When red, `<workflow-summary>` is derived from `main_ci.red_workflow_count` and `main_ci.red_workflow_names`:
  - 1 failing workflow → `<workflow-name>, run <id>` (e.g. `Deploy to Play Store, run 18234567`)
  - 2–3 failing workflows → `<name1>, <name2>[, <name3>], run <id>` (list all names if they fit, truncate with `+N more` if needed to keep the status line under ~120 chars)
  - 4+ failing workflows → `<red_workflow_count> workflows: <name1>, <name2>, +<N> more, run <id>` (limit to 2 names before `+N more`)

  In all cases the run ID (`main_ci.earliest_red_run_id`) remains at the end of the parenthetical so the user can navigate directly to the failing run. No extra `gh` call — all data is in the `main_ci` cache from step 4.5a.

  When `main_ci.non_required_red_workflow_count > 0` (non-required workflows are red but main is gated to required-only), append a parenthetical suffix to the main field after the primary `🟢/🔴/⏳/❔` parenthetical (or directly after the emoji when status is green / pending / unknown): ` (infra: <name1>, <name2>[, +<N> more])`. Limit to 2 names plus `+N more` to stay terse. Example: `main:🟢 (infra: Android Release Notes)` — the green emoji communicates "no divert", the parenthetical surfaces the non-gating failure so the maintainer doesn't lose visibility into it. When `non_required_red_workflow_count == 0` (the common case), omit the suffix entirely.
- **in-flight labels** — comma-separated, derived from each entry's `kind`/`target`: issue → `#N`, fix-checks → `fix-checks #M`, fix-main-ci → `⚠️ fix-main-ci`, fix-failing-prs-batch → `⚠️ fix-prs-batch`. Empty list → `[ ]`.
- **failing PRs:** — the all-authors count from `failing_pr_count_all`. The `(@me: <k>)` parenthetical comes from `failed_prs.length + in_flight fix-checks count`. Append ` ⚠️` to the count when it's ≥ 10 (matches the divert threshold).
- **soft-suffix** — when one or more soft-collision paths are claimed by in-flight workers, append ` · [soft: <path>×<n>, <path>×<n>, ...]` listing each distinct claimed soft path and how many in-flight workers are holding it. Order by claim count desc, then alphabetical. Bracket and brackets are part of the surface (visually similar to the in-flight labels). Append ` ⚠️` to any path whose count equals `--soft-collision-concurrency` (the cap — next claimer on that path will park). Omit the suffix entirely when no soft-collision claims are active.
- **divert-suffix** — when a divert is enqueued but not yet in flight, append ` · diverting: <kind>`. When already in flight, the `[ ]` labels already make that visible, no suffix needed.

Examples:

```
/do-work · mattsears18/lightwork · main:🟢 · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/shipyard · main:🟢 · in-flight: 3/4 [#63, #65, #67] · failing PRs: 0 (@me: 0) · [soft: plugins/shipyard/commands/do-work.md×3 ⚠️, CHANGELOG.md×3 ⚠️]
/do-work · mattsears18/lightwork · main:🔴 (Deploy to Play Store, run 18234567) · in-flight: 2/2 [⚠️ fix-main-ci, #769] · failing PRs: 12 ⚠️ (@me: 2) · diverting: fix-failing-prs-batch
/do-work · mattsears18/lightwork · main:🔴 (3 workflows: Deploy to Play Store, Lighthouse CI, +1 more, run 18234567) · in-flight: 1/2 [⚠️ fix-main-ci] · failing PRs: 0 (@me: 0)
/do-work · mattsears18/lightwork · main:🟢 (infra: Android Release Notes) · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/lightwork · main:⏳ · in-flight: 0/2 [ ] · failing PRs: 0 (@me: 0)
```

The soft-suffix is the human's signal that merge conflicts may surface at PR-land time on those paths. When a count hits the cap (` ⚠️`), the orchestrator is also one step away from parking — and the user can decide whether to bump `--soft-collision-concurrency` mid-session (next-session-only, the cap isn't hot-reloadable today) or let dispatch park.

When to print the status line: (a) startup, right before the initial pool fill; (b) any turn where `divert_queue` gained or lost an entry; (c) any turn where `main_ci.status` changed since the previous print; (d) any turn where `failing_pr_count_all` crossed the 10 threshold in either direction; (e) start of the end-of-session summary; (f) right after any state-change banner below; (g) any turn where a soft-collision claim count crossed `--soft-collision-concurrency` (entering or leaving the cap) on any path.

#### State-change banners — make divert events impossible to miss

The status line is for at-a-glance state. **Banners** are for the moments where state CHANGES — they're a 3-line block with blank lines above and below, so they stand out from completion-reconcile logs. Print every time one of the trigger conditions fires; never suppress them.

**Main flipped red → enqueueing a fix-main-ci diversion:**

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflow: <earliest_red_workflow_name>
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

When `red_workflow_count > 1`, replace the single `Failed workflow:` line with a plural form listing all failing workflows from `red_workflow_names`:

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflows (3): Deploy to Play Store, Lighthouse CI, Visual Regression
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

The workflow list in the banner is always the **full** `red_workflow_names` list (no truncation — banners are one-shot so verbosity is fine). Use a comma-separated inline list.

When `non_required_red_workflow_count > 0` AND the banner above is firing (a `green → red` transition on the *gating* set), append an info line after the workflows list noting which non-required workflows are also red, so the maintainer's mental model stays accurate:

```
   Non-required workflows also red (not diverting): Android Release Notes
```

When the banner is NOT firing because the gating set is green but `non_required_red_workflow_count` flipped from 0 → ≥1 (e.g. an infra workflow just turned red while CI stayed green), print a softer notification banner instead — this is a `🔔` advisory, not a divert trigger:

```

🔔  NON-REQUIRED CI WORKFLOW(S) RED — main_ci.status stays green, no divert
   Failed (non-required): Android Release Notes
   Note: these workflows aren't in branch protection's required_status_checks list; resolve in their respective consoles.

```

Trigger this notification banner only on the 0 → ≥1 transition (not every refresh) to keep the surface terse — the per-turn status-line `(infra: ...)` suffix carries the steady-state visibility.

**fix-main-ci dispatched (slot now in flight):**

```

🔧  DISPATCHED fix-main-ci on slot <id> — agent investigating <earliest_red_run_id>

```

**Main flipped back to green (red → green transition):**

```

✅  MAIN CI RESTORED — back to green at run <newest_green_run_id>

```

If a fix-main-ci diversion is in flight when this fires, also add: `   (in-flight fix-main-ci will finish naturally; result may already be redundant)`.

**Failing-PR count crossed UP through 10 — enqueueing a fix-failing-prs-batch diversion:**

```

⚠️  FAILING PR PILEUP — <n> open PRs are red, threshold is 10
   Sample: #<a>, #<b>, #<c>, ... (+ <k> more)
   Diverting next available slot to investigate common root cause.

```

**fix-failing-prs-batch dispatched:**

```

🔧  DISPATCHED fix-failing-prs-batch on slot <id> — investigating <n> failing PRs

```

**Failing-PR count crossed DOWN through 10:**

```

✅  PR PILEUP CLEARED — <n> failing PRs remain (below 10 threshold)

```

**Diversion completed (any kind):**

When a `fix-main-ci` or `fix-failing-prs-batch` worker returns, print a banner BEFORE the normal reconcile line:

- `shipped` → `✅  DIVERSION RESOLVED — fix-main-ci shipped via PR #<M> (auto-merge enabled)`
- `noop` → `➖  DIVERSION NO-OP — fix-main-ci: main already green by the time the agent started`
- `blocked` → `🛑  DIVERSION BLOCKED — fix-main-ci: <reason>. No auto-retry; needs human attention.` (and the status line that follows will keep showing `main:🔴` until a human resolves it)

**End-of-session — diversion summary block.** The end-of-session summary (below) carries a `Diversions:` block when `D > 0` — counts per kind, with shipped/noop/blocked breakdowns and PR numbers. That's how the user sees what diversions fired even if they weren't watching the session live.

The rule of thumb is: banners are LOUD and one-shot (printed when the transition happens), the status line is the persistent at-a-glance view (re-printed whenever the underlying state changes). Both should appear together when a divert fires — banner first, then the updated status line immediately below it.

### 6.8 Flush setup timing into session state

**Before dispatching the first wave of workers**, flush the setup-timing sidecar into the session state file's `setup` block. This ensures the timing data survives even if the session terminates mid-run (e.g. a Claude Code crash between pool fill and the first completion notification). The flush is fire-and-forget — a failure must NOT block pool fill.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/shipyard}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" flush \
  --session-id "<session-id>" 2>/dev/null || true
```

After this call the sidecar is gone and the session state file's `.setup` block contains the full per-phase wall-clock breakdown. The cost-history flush at end-of-session will pick it up automatically.

### 7. Initial pool fill

> **Fire one when `concurrency == 1`.** At C=1 the "pool" is a single slot. Skip the parallel `Agent` burst and dispatch exactly one worker: apply the dispatch rules from [steady-state dispatch rules](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) to pick the top candidate, run the just-in-time scope pre-flight for that one candidate (per the C=1 note in [step 6](#6-initial-scope-pre-flight)), then dispatch a single `Agent` call (no `run_in_background: true` needed — the slot is already available). Return control immediately after dispatch; the steady-state loop handles the rest.

Dispatch up to `--concurrency` workers in parallel — one message with N background `Agent` calls (`run_in_background: true`, `isolation: "worktree"`, and `subagent_type` matching the worker's `mode:` per the [per-mode subagent_type routing table](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) — `shipyard:issue-worker` for `mode: issue-work`, `shipyard:fix-checks-worker` for `mode: fix-checks-only`, etc.). For each slot, pick the next job using the **dispatch rules** below.

**Per-slot metadata.** Each new `in_flight` slot record MUST include `started_at` (ISO-8601 UTC) alongside `kind` / `target` / `claimed_paths` / `agent_id`. This powers [`/shipyard:status`](../status.md)'s `ELAPSED` column and stale-worker detection — see the [steady-state per-slot dispatch metadata write-through note](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) for the canonical shape. Same write-through pattern applies to every dispatch site in the session (initial pool fill, step C, divert-queue pop, fix-checks pop, drain-phase fix-rebase dispatch).

Once the pool is full, **return control** — you'll be notified the moment any agent completes. Do not poll. Do not sleep.
