# /shipyard:do-work — Setup phase

The session-startup steps (0.4 → 7). Runs once, end of phase hands off to [steady-state](./steady-state.md). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and the [session state file schema](../do-work.md#session-state-file); this file owns the actual setup-step execution.

## Setup (run once)

### 0.4 Check the repo-level opt-in (`shipyard.config.json`)

**Run this BEFORE the worktree relocation.** The check is a single `shipyard-config.sh exists` call against the user's primary checkout — read-only, no writes, so the worktree-isolation rule doesn't apply yet.

```bash
cd "$(git rev-parse --show-toplevel)"
"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists
case $? in
  0)
    # Repo is shipyard-initialized — load the merged config so subsequent
    # steps can read tunables like trust.authors, auto_merge.policy, etc.
    EFFECTIVE_CONFIG=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" load) ;;
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
# Close the step_0_5_worktree timing window.
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

End-of-session cleanup also runs from the orchestrator worktree, and reaps the orchestrator's own worktree last — see [End-of-session cleanup](./cleanup-summary.md#end-of-session-cleanup) below.

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
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
# ... fire all parallel gh calls ...
# ... wait for all to return ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
```

**Canonical setup batch — these reads have no data dependencies:**

- **[Step 1](#1-resolve-repo--user)** — repo + user metadata (3 `gh` calls).
- **[Step 2](#2-backlog-overview)** — issue universe (`gh issue list --state open` + `linked:pr` search). **Skipped under `--fast`** — but count `needs-refinement`, `blocked:ci`, `blocked:agent` issues first (see step 2's `--fast` note).
- **[Step 3d.1](#3-ensure-label-exists--recover-from-prior-session)** — `blocked:ci` PR list. Per-PR `events` + `commits` lookups are a second-tier parallel batch keyed off the first-tier result. **Skipped under `--fast`** (the initial `gh pr list --label blocked:ci --json number --jq 'length'` count still runs for advisory reporting — see step 3d.1's `--fast` note).
- **[Step 3d.2](#3-ensure-label-exists--recover-from-prior-session)** — `blocked:agent`-label issue list. Per-issue blocker-state lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). **Skipped under `--fast`** (the initial `gh issue list --label blocked:agent --json number --jq 'length'` count still runs for advisory reporting — see step 3d.2's `--fast` note).
- **[Step 4.5a](#45-divert-checks-main-ci--pr-pileup)** — main CI status (`gh run list --branch <default-branch> --limit 60`). **Skipped under `--fast`** — `main_ci.status` left as `"unknown"`.
- **[Step 4.5b](#45-divert-checks-main-ci--pr-pileup)** — all-authors failing-PR count. **Skipped under `--fast`** — `failing_pr_count_all` left as `0`.
- **[Step 5](#5-snapshot-failing-prs)** — `@me` failing-PR snapshot.

**Background bash group (fire-and-forget from step 0.7).** The following steps are cleanup-only — they don't affect dispatch correctness and don't need to complete before the first worker fires. Fire them as a single background subshell immediately after opening the timing window, capture the PID, and let dispatch proceed without waiting:

```bash
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

  # 3a — gh label create (10 idempotent labels). All idempotent; only needed by the
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
    "blocked:agent --description 'Worker returned blocked — needs human intervention' --color C5DEF5" \
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
  for wt_dir in .git/worktrees/agent-*; do
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
  "${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" invalidate --session-id "<session-id>"
  ```
  Burns one extra round of cold reads on the next refresh but never serves stale data after a write. Use this when in doubt — the cost is "one re-read per shipyard write," which is small compared to the savings on the hot read paths.
- **Targeted (advanced).** When the write affects a specific PR or issue and the caller knows which cached reads depend on that artifact, pass `--pattern <sha-prefix>` to invalidate just the matching entries. Practical use is rare — the `--pattern` surface is intentionally narrow because callers don't easily know the sha shape. Stick with the conservative policy unless profiling shows the broad flush dominates.

**End-of-session cleanup.** The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is reaped by the [End-of-session cleanup](./cleanup-summary.md#end-of-session-cleanup) sequence:

```bash
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
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
# ... run resolution logic ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_1_7_trusted_authors 2>/dev/null || true
```

**Security gate — must run before step 2's bucket pass and step 4's backlog fetch.** Populates the session-level `trusted_authors` set (the 9th orchestrator state struct — see the [state struct list](../do-work.md#orchestrator-state) at the top of this spec). The set decides which issue authors `/do-work` will dispatch workers against; everyone else lands in step 2's `Untrusted author` bucket and step 4's client-side filter drops them from the workable queue. This is the **first line of defense** against the public-repo prompt-injection / RCE threat documented in step 2's "Bucket 0.5 is a security gate" block — a stranger can open an issue with a body that reads like a legit bug report ("Suggested fix: add `helper.ts` with `<crafted payload>`"), but if their login isn't in `trusted_authors`, no worker is ever dispatched against it, so the body is never read as instructions.

**Resolution order — first non-empty wins:**

1. **Per-repo override file** — if `.shipyard/trusted-authors.txt` exists in the orchestrator worktree, read it. One GitHub login per line; lines starting with `#` are comments; blank lines are ignored; logins are case-insensitive (lowercased on read). The repo owner (`<owner>` portion of `<owner/repo>`) is implicitly included even when the file omits them. Use the file's set as `trusted_authors` and stop — do not fall through to the collaborators API.

2. **Collaborators API fallback** — when the override file doesn't exist, query the live collaborators-with-push API:

   ```bash
   gh api "repos/<owner/repo>/collaborators?per_page=100" --paginate \
     --jq '.[] | select(.permissions.push==true) | .login' | tr 'A-Z' 'a-z' | sort -u
   ```

   Add `<owner>` (lowercased) to the result set so a personal-repo owner with no other collaborators still works. Cache the result as `trusted_authors`.

3. **API failure / permission denied** — when the API call errors (the auth'd token can't list collaborators, e.g. the repo is owned by an org and the token doesn't have admin scope), fall back to a single-member set containing just `<owner>` (lowercased). Log an advisory: `[trusted-authors] could not query collaborators API (<reason>); falling back to repo owner only`. The session continues — restrictive default is the safe failure mode.

`.shipyard/trusted-authors.txt` format — one GitHub login per line; comments (`#`) and blank lines OK; case-insensitive; repo owner is implicitly trusted. Bot accounts (`dependabot[bot]`, `github-actions[bot]`, etc.) are NOT auto-trusted — the collaborators-API fallback excludes them, and maintainers must add them to the override file explicitly. Cache lifetime is session-scoped — resolve once at startup, never re-resolve mid-session. See [RATIONALE → Step 1.7](../do-work-RATIONALE.md#step-17--why-a-per-repo-override-file-exists) for the policy discussion.

**Protect the override file with CODEOWNERS.** Because the file IS the security boundary, repos that adopt `/shipyard:do-work` should add a `.github/CODEOWNERS` rule naming the maintainer(s) for `.shipyard/trusted-authors.txt` and enable "Require review from Code Owners" in branch protection on the default branch — otherwise anyone with `write` access can extend the allowlist via a single PR with no maintainer in the loop. This repo's own [`.github/CODEOWNERS`](../../../../.github/CODEOWNERS) is the reference example.

**Output.** A single advisory line goes into the session log right after resolution:

- `[trusted-authors] loaded <K> author(s) from .shipyard/trusted-authors.txt`, or
- `[trusted-authors] loaded <K> collaborator(s) from repos/<owner/repo>/collaborators API`, or
- `[trusted-authors] fallback to repo owner only — <reason for API failure>`.

The count `<K>` includes the repo owner (which is always in the set). The advisory is one line — not a block, not a list of logins — so the startup output stays scannable.

### 2. Backlog overview

> **`--fast` skip:** When `--fast` is set, skip the full universe fetch and the UI table. Instead, run three cheap counts for advisory reporting in the end-of-session `--fast was used` block:
>
> ```bash
> # These three run in parallel as part of the parallelization batch even under --fast.
> gh issue list --repo <owner/repo> --state open --label needs-refinement --json number --jq 'length'
> gh pr list --repo <owner/repo> --state open --label blocked:ci --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent --json number --jq 'length'
> ```
>
> Save the three counts as `fast_skip_needs_refinement`, `fast_skip_blocked_ci`, and `fast_skip_blocked_agent`. Proceed immediately to step 3.

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
| 6 | **Blocked (label)** | carries `blocked:agent` |
| 7 | **Blocked (body reference)** | body matches `Blocked by #(\d+)` where that issue is still open (`gh issue view <N> --json state -q .state` returns `OPEN`) |
| 8 | **Workable** | everything else — these are what /do-work will dispatch |

**Bucket 0.5 is a security gate, not a triage hint** — the dispatch-time filter that keeps strangers' issues out of the workable queue entirely. The defense-in-depth measure (issue body treated as untrusted in [`agents/issue-worker/issue-work.md` step 2](../../agents/issue-worker/issue-work.md#2-read-the-issue-carefully)) sits behind this filter. Override path for a maintainer-vouched issue: re-file under the maintainer's own account, or add the author to `.shipyard/trusted-authors.txt`. See [RATIONALE → Bucket 0.5 security gate](../do-work-RATIONALE.md#step-2--why-bucket-05-is-a-security-gate) for the threat model and override-path discussion.

Buckets 5.4 and 5.5 are part of the refinement pipeline (see `/refine-issues`). 5.4 issues will be processed automatically by step 3.5 *this* session — the refiner branches on source signal (user-feedback vs open-questions vs fall-through). 5.5 issues are waiting on a human to sign off on the refined version (this is the `user-feedback` path's human-gate, applied by the classify+rewrite branch — `needs-human-review` is **decoupled** from `needs-refinement` and is NOT applied by the resolve-defaults or escalate-to-triage branches). Both render in the "Skipped" block with counts and issue numbers.

For each issue in bucket 6 or 7, generate a one-line **unblock recommendation** describing what the human could do to unblock it. Use the issue body, labels, and (for body references) the blocker's title and state — but skim, don't deep-dive. One sentence per blocked issue is plenty. Examples:

- Blocked by another open issue: `"#<N> blocked by #<M> (\"<M's title>\") — <action, e.g. 'land #M first', 'close #M as obsolete', or 'review the proposal in the latest comment'>"`
- Blocked by an external dependency (SDK release, vendor input, design decision): describe the concrete action the user could take
- `blocked:agent` label set with no discernible blocker: `"unclear blocker — comment to clarify or remove the label"`
- Awaiting refinement (bucket 5.4): `"#<N>: refinement runs automatically at /do-work startup, or run /refine-issues manually"`
- Awaiting human review (bucket 5.5): `"#<N>: review the refined feedback, set a priority label, remove \`needs-human-review\` (or close)"`

The point is to give the user something **actionable** so they can start clearing blockers in parallel.

**Inline action-recommendation candidates per skipped bucket.** The orchestrator surfaces per-bucket candidate counts under each Skipped-bucket so the "this bucket has N issues you could probably act on right now" signal is visible at the bucket itself. Apply only to buckets where a mechanical signal distinguishes "likely-actionable" from "genuinely stuck" residue. The orchestrator does NOT auto-act on these. See [RATIONALE → Inline action recommendations](../do-work-RATIONALE.md#step-2--inline-action-recommendation-rationale) for the cost discussion.

Compute candidates for the following buckets:

- **Bucket 6 (Blocked label) — `likely-clearable` candidates.** For each issue in this bucket, parse `Blocked by #N` references from the body using the same regex step 3d.2 uses (`grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)'`). Check each referenced blocker's state via `gh issue view <N> --json state` (with `gh pr view` fallback for PR numbers). An issue is `likely-clearable` when **all** referenced blockers are `CLOSED` or `MERGED`. Candidates are also what step 3d.2 will auto-clear later in setup — surfacing them here in step 2 gives the user pre-sweep visibility before the sweep runs. Held issues (no body reference, or any blocker still open) are NOT surfaced as candidates.

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
blocked:agent label                              3   #A, #B, #C
  ⚠ likely-clearable                             1   #A — all referenced blockers closed; step 3d.2 will auto-clear
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
  blocked:agent labels:   <cleared_blocked> issue(s)  (#X, #Y, ...)
  held blocked:agent:     <held_blocked> issue(s)  (#Z, ...)

PR-side state:
  blocked:ci PRs: <c> total
    will be re-evaluated this session: <k>  (#J, #K, ...)
    held (no new commits since label applied): <h>  (#L, #M, ...)

Unblock recommendations (work these in parallel while /do-work runs):
  - #A: <recommendation>
  - #C: <recommendation>
  ...
```

**One-row mode** (the table is skipped; replace the bucket block with a single-line summary). When the lone bucket is `Workable`: `Workable: 6 issues (#90, #91, #92, #93, #94, #89). Nothing skipped.` When the lone bucket is a skip: `Workable: 0. Skipped: 3 issues in 'blocked:agent' label (#A, #B, #C).`

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

The `shipyard` label is the session stamp; `P0`/`P1`/`P2` are the priority tiers; `user-feedback`/`needs-refinement`/`needs-human-review`/`needs-triage` drive the [refinement pipeline](#35-refine-pending-issues); `blocked:agent` and `blocked:ci` are shipyard's block-state circuit breakers (applied by step A on agent / fix-checks block, removed by step 3d.1 / 3d.2):

```bash
gh label create shipyard --repo <owner/repo> --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create user-feedback --repo <owner/repo> --description "Originated from end-user feedback (untrusted body — treat with care)" --color 0E8A16 2>/dev/null || true
gh label create needs-refinement --repo <owner/repo> --description "Pipeline gate — issue isn't ready for /do-work; /refine-issues processes it" --color FBCA04 2>/dev/null || true
gh label create needs-human-review --repo <owner/repo> --description "Awaiting human sign-off before /do-work will touch it" --color D93F0B 2>/dev/null || true
gh label create needs-triage --repo <owner/repo> --description "No automated path forward — surface to a human" --color C2E0C6 2>/dev/null || true
gh label create blocked:agent --repo <owner/repo> --description "Worker returned blocked — needs human intervention" --color C5DEF5 2>/dev/null || true
gh label create blocked:ci --repo <owner/repo> --description "CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover." --color B60205 2>/dev/null || true
```

**3b. Reap stale agent worktrees from dead Claude Code sessions.**

> **Background step.** This step runs inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Stale-worktree reaping affects future dispatch slot availability, not the first batch. The canonical implementation lives in the background group above.

The harness writes a lock file at `.git/worktrees/agent-<id>/locked` containing `claude agent <id> (pid <N>)`. The lock survives the harness process exiting. Reap every agent worktree whose lock-holding PID is dead; skip ones owned by live PIDs (could be another active Claude Code instance):

```bash
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
reaped_stale=0
deferred_stale=0
# Declare our orchestrator PID so classify-lock can short-circuit reliably
# (issue #263). The harness writes our PID into every agent lock file;
# without an explicit declaration, classify-lock's ancestor walk can fail
# to find it whenever an intermediate harness layer returns empty PPID.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)
for wt_dir in .git/worktrees/agent-*; do
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

> **Background step.** Both the discovery query and the handling (push / PR-create for orphans with commits) run inside the background bash group fired from [step 0.7](#07-setup-parallelization-contract-fire-once-batch). Neither gates dispatch decisions. The discovery query is cheap; the expensive push/PR-create branch only fires when orphans exist. The canonical implementation lives in the background group above; this section documents the decision table and `salvaged_count`/`abandoned_count` tracking semantics.

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR) and `abandoned_count` (worktrees removed) — both default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 4). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup`. If any check is `FAILURE` / `ERROR` / `TIMED_OUT` → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |

**Inconsistency log (advisory)** — also run a one-line label cross-check:

```bash
gh issue list --repo <owner/repo> --label shipyard --assignee @me --state open --search '-linked:pr' --json number
```

Any results here that DON'T correspond to a `do-work/*` worktree on disk are "dispatched but agent died before its first commit" cases. Log them in the session summary as an advisory — don't auto-act.

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

**Regression guard.** The `commit_ts > label_ts` comparison enforces "auto-clear fires only when a new commit has landed since the label was applied." If the comparison can't be computed (head branch deleted, events aged out of the ~90-day pagination window, network blip), hold — the safe default is to preserve the block. See [RATIONALE → Step 3d sweeps](../do-work-RATIONALE.md#step-3d--why-the-blockedci--blockedagent-sweeps-have-different-shapes).

**3d.2. Auto-clear stale `blocked:agent` labels.** Issues carrying `Blocked by #N` references in their body stay labeled even after all referenced blockers merge — step 4's `-label:blocked:agent` filter then silently hides them. Same auto-clear pattern as `blocked:ci` but the condition is referential: clear when every `Blocked by #N` reference resolves to a CLOSED or MERGED issue. Sweep runs after 3d.1, before step 4's backlog fetch.

> **`--fast` skip:** When `--fast` is set, skip this entire sweep. The initial `blocked:agent` count (`fast_skip_blocked_agent`) captured in step 2's `--fast` note is sufficient for the advisory summary — stale `blocked:agent` labels persist until the next normal session. Set `cleared_blocked=0` and `held_blocked=0`.

Fire the initial issue list in the [setup parallelization batch](#07-setup-parallelization-contract-fire-once-batch); per-issue blocker lookups read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). Serial loop shown for readability:

```bash
# All open issues currently carrying the `blocked:agent` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent --limit 200 \
  --json number,body \
  > /tmp/do-work-blocked-issues.json

cleared_blocked=0
held_blocked=0
declare -a cleared_blocked_numbers
declare -a held_blocked_numbers

for n in $(jq -r '.[].number' /tmp/do-work-blocked-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-blocked-issues.json)

  # Extract every `Blocked by #N` reference (case-insensitive, all matches).
  # The grep pattern catches `Blocked by #123`, `blocked by #45, #67, #89`, etc.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | sort -u)

  if [ -z "$blockers" ]; then
    # No `Blocked by #N` reference in body — can't make a judgment. Hold.
    held_blocked=$((held_blocked + 1))
    held_blocked_numbers+=("$n")
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
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent
    gh issue comment "$n" --repo <owner/repo> \
      --body "Auto-cleared \`blocked:agent\` — all referenced blockers ($closed_list) are now closed."
    cleared_blocked=$((cleared_blocked + 1))
    cleared_blocked_numbers+=("$n")
  else
    held_blocked=$((held_blocked + 1))
    held_blocked_numbers+=("$n")
  fi
done
```

Record `cleared_blocked` and `held_blocked` (plus the matching issue-number arrays) — both surface in step 2's backlog overview when either is > 0, and again in the end-of-session summary. The issues whose labels just got cleared will be picked up automatically by step 4's backlog fetch — they're no longer carrying `blocked:agent`, so step 4's `-label:blocked:agent` filter doesn't exclude them anymore.

**Held cases — when the sweep deliberately doesn't clear:** no `Blocked by #N` reference in the body; any referenced blocker is still OPEN; unresolvable reference (both `gh issue view` and `gh pr view` error). Secondary gates past the `Blocked by` line aren't auto-detected — false positives are recoverable via the issue worker's own `blocked` return. See [RATIONALE → Step 3d sweeps](../do-work-RATIONALE.md#step-3d--why-the-blockedci--blockedagent-sweeps-have-different-shapes) for the asymmetry between the two sweeps and the held-case discussion.

### 3.5 Refine pending issues

> **`--fast` skip:** When `--fast` is set, skip this entire step. Issues carrying `needs-refinement` remain unrefined this session; they will be processed by the next normal `/do-work` invocation. The `fast_skip_needs_refinement` count captured in step 2's `--fast` note surfaces in the end-of-session advisory block so the user knows how many refinement tasks were deferred. Proceed immediately to step 4.

**Timing instrumentation (issue #238).** Bracket this step even when it runs with no `needs-refinement` issues — the wall clock still measures the `/refine-issues` invocation overhead:

```bash
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
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
# ... run step 4 ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
```

```bash
gh issue list --repo <owner/repo> --state open --limit 100 \
  --json number,title,labels,assignees,body,author,createdAt,updatedAt \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, createdAt, updatedAt}]' \
  --search 'is:issue is:open -linked:pr -label:blocked:agent -label:wontfix -label:needs-design -label:needs-triage -label:discussion -label:needs-refinement -label:needs-human-review'
```

The `--jq` projection mirrors step 2's: flatten `labels` / `assignees` to the consumed shapes (names, logins) and preserve `author.login` as the canonical shape downstream filters and step 7's `originating_author_trust` computation reference. Body stays full because the client-side filter walks it for `Blocked by #N` references. Worker-preamble §"`gh` JSON discipline" covers the convention.

Add `label:<L>` qualifiers for each `--label` arg.

**Why each `blocked:*` label is enumerated explicitly.** GitHub's search syntax (which `gh issue list --search` passes through) does NOT support label-name glob patterns — `-label:blocked:*` does not match `blocked:agent` or `blocked:ci`; it's treated as a literal label name `blocked:*` which doesn't exist. Every block-tier label that should hide an issue from the workable queue must appear as its own `-label:<exact-name>` qualifier. Today the workable filter only excludes `blocked:agent`; `blocked:ci` is a PR-side label so it has no effect on issue search (issues never carry it). If future block tiers are added (`blocked:external`, `blocked:design`, etc.), enumerate each one here.

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

Client-side filter:

- **Drop issues whose `author.login` (lowercased) is NOT in `trusted_authors`.** This is the dispatch-time security gate — see [step 1.7](#17-resolve-trusted-author-allowlist) for how the set is populated. An issue filed by a stranger on a public repo lands in step 2's `Untrusted author` bucket and never enters the workable queue, even if all the other filters pass. Belt-and-suspenders with the step-2 bucket pass: step 2 surfaces the count to the user; step 4 enforces the actual drop at dispatch time. Both read the same `trusted_authors` cache so they can never disagree.
- Drop issues assigned to a user **other than** the gh-authenticated user (they own it).
- Drop issues whose body contains `Blocked by #N` where #N is still open.
- Drop the issue if any of the following returns a result — belt-and-suspenders against the `-linked:pr` qualifier. All three commands must include `--state open` so that a closed-without-merging PR doesn't incorrectly suppress the issue:
  ```bash
  gh pr list --repo <owner/repo> --state open --search 'in:body "Closes #<N>"' --json number,title,url
  gh pr list --repo <owner/repo> --state open --search 'in:body "Fixes #<N>"' --json number,title,url
  gh pr list --repo <owner/repo> --state open --search 'in:body "Resolves #<N>"' --json number,title,url
  ```

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

Filter to PRs where `statusCheckRollup` contains any entry with `conclusion: FAILURE` / `state: FAILURE` / `ERROR` / `TIMED_OUT`. Count distinct PR numbers → `failing_pr_count_all`. Cache the count and the matching PR numbers (`failing_prs_all_authors`).

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

Filter to PRs where `statusCheckRollup` contains any entry with `conclusion: FAILURE` / `state: FAILURE` / `ERROR` / `TIMED_OUT`. Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

Each entry → push onto `failed_prs`, **deduped against entries already in `failed_prs`** (step 3c may already have enqueued some). These are the highest-priority work items *after* `divert_queue` because a red PR you opened last session won't auto-merge no matter how many new issues you ship. Note: this query is `@me`-scoped on purpose — `failed_prs` is for fix-checks work on PRs *you authored*. The all-authors count from step 4.5b feeds the divert decision, not this queue.

The `-label:blocked:ci` filter is still correct because [step 3d's auto-clear sweep](#3-ensure-label-exists--recover-from-prior-session) already ran — refreshed PRs are unlabeled by 3d and flow through normally; only genuinely-stuck PRs still carry the label here. See [RATIONALE → Step 5 filter correctness](../do-work-RATIONALE.md#step-5--why-the--labelblockedci-filter-is-still-correct).

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

Take the top `2 × concurrency` from `raw_backlog`. Dispatch read-only scoping agents in parallel with `run_in_background: true` (one message, multiple background `Agent` tool calls). Each returns **one of two shapes**:

**Ready shape** (default — the candidate is shippable as a single-worker dispatch):

```
{ issue: N, files: ["path/a", "path/b", ...], lockfile_sections: ["overrides", "dependencies", ...] }
```

**Deferred shape** (the scope agent read the issue + code and concluded the fix isn't ship-able as a single `shipyard:issue-worker` dispatch — multi-PR migration, SDK upgrade, external decision, infrastructure provisioning, etc.):

```
{ issue: N, deferred: "<one-paragraph reason the orchestrator should tell the human>" }
```

Scoping-agent prompt instruction: *If your read of the issue + codebase suggests the fix isn't a single-worker job — multi-PR migration, SDK upgrade, external decision (legal/design), infrastructure provisioning — return the deferred shape with a one-paragraph `deferred` value explaining what the orchestrator should tell the human. When in doubt — default to ready.* See [RATIONALE → Deferred shape](../do-work-RATIONALE.md#step-6--why-scope-pre-flight-has-a-deferred-shape).

`lockfile_sections` (ready shape only) is the set of root-manifest sections the candidate will touch — typically top-level keys in `package.json` (`overrides`, `dependencies`, `devDependencies`, `peerDependencies`, `optionalDependencies`, `scripts`, `engines`, `config`, `workspaces`, `resolutions`, `pnpm`, etc.). For non-`package.json` lockfile-class files (`Gemfile`, `go.mod`, `Cargo.toml`, `requirements.txt`, generated SQL migrations, root build config like `vite.config.ts` / `tsconfig.json`) use the filename as the section token (e.g., `"go.mod"`, `"Cargo.toml"`, `"migrations"`). Return an **empty array** for issues that don't touch any lockfile-class file. Budget ~30s per scoping agent.

**Handling each returned entry (fires as each background agent completes):**

- **Ready entries** — partition each `files` array into `{ hard: [...], soft: [...] }` by matching each path against the soft-collision glob set defined in the [Dispatch rules](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) (default + any `--soft-collision-path` extensions). Paths that match a soft-collision glob go into `soft`; everything else goes into `hard`. The orchestrator does the partitioning — scoping agents return raw paths; they don't need to know about the tier distinction. Cache the partitioned result as the candidate's `claimed_paths`. Push onto `ready_issues` (preserving rank). **If this is the first ready entry and step 7 has not yet dispatched, dispatch immediately** — do not wait for the remaining background scope agents to finish.
- **Deferred entries** — do NOT push onto `ready_issues` and do NOT dispatch a worker. Instead:
  1. Post a comment on the issue: `Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>`. Use `gh issue comment <N> --repo <owner/repo> --body "..."`. If the comment fails (rate limit, permission), log an advisory and continue — don't block the pre-flight pass on a single comment failure.
  2. Append the entry `{ issue: N, reason: "<deferred reason>", provenance: "scope-agent", deferred_at: "<current ISO-8601 UTC timestamp>" }` to a session-level `deferred_issues` list (a new piece of orchestrator state — initialize as `[]` at startup alongside `ready_issues` / `raw_backlog`). The `provenance: "scope-agent"` value records that a real scope agent read the codebase and made this call — see [`do-work.md`'s `deferred_issues` entry](../do-work.md#orchestrator-state) for the valid provenance values and the restriction on mid-session writes. Increment `defers_this_turn` by 1 — this feeds the step E invariant line's `defers_this_turn` token and the pre-drain audit. This feeds the end-of-session summary's `Deferred:` block (see [End-of-session summary](./cleanup-summary.md#end-of-session-summary)).
  3. **Do not** add a label, do not close the issue, do not assign to a human. The issue stays open with the diagnosis comment — the human reads the comment and decides what to do (open a multi-PR plan, escalate, defer to a sprint, etc.).

Remove every processed issue number from `raw_backlog` regardless of which shape was returned (ready *or* deferred) — both are "done" from the scoping pass's perspective.

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
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" flush \
  --session-id "<session-id>" 2>/dev/null || true
```

After this call the sidecar is gone and the session state file's `.setup` block contains the full per-phase wall-clock breakdown. The cost-history flush at end-of-session will pick it up automatically.

### 7. Initial pool fill

> **Fire one when `concurrency == 1`.** At C=1 the "pool" is a single slot. Skip the parallel `Agent` burst and dispatch exactly one worker: apply the dispatch rules from [steady-state dispatch rules](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) to pick the top candidate, run the just-in-time scope pre-flight for that one candidate (per the C=1 note in [step 6](#6-initial-scope-pre-flight)), then dispatch a single `Agent` call (no `run_in_background: true` needed — the slot is already available). Return control immediately after dispatch; the steady-state loop handles the rest.

Dispatch up to `--concurrency` workers in parallel — one message with N background `Agent` calls (`run_in_background: true`, `isolation: "worktree"`, and `subagent_type` matching the worker's `mode:` per the [per-mode subagent_type routing table](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) — `shipyard:issue-worker` for `mode: issue-work`, `shipyard:fix-checks-worker` for `mode: fix-checks-only`, etc.). For each slot, pick the next job using the **dispatch rules** below.

**Per-slot metadata.** Each new `in_flight` slot record MUST include `started_at` (ISO-8601 UTC) alongside `kind` / `target` / `claimed_paths` / `agent_id`. This powers [`/shipyard:status`](../status.md)'s `ELAPSED` column and stale-worker detection — see the [steady-state per-slot dispatch metadata write-through note](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) for the canonical shape. Same write-through pattern applies to every dispatch site in the session (initial pool fill, step C, divert-queue pop, fix-checks pop, drain-phase fix-rebase dispatch).

Once the pool is full, **return control** — you'll be notified the moment any agent completes. Do not poll. Do not sleep.
