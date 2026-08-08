# /shipyard:do-work — End-of-session cleanup + summary + report

The session's wind-down trio. Runs after [drain](./drain.md) exits:

1. **End-of-session cleanup** — reap agent worktrees, prune branches, flush the cost ledger, retire the session-state file. Last step retires the orchestrator's own worktree.
2. **End-of-session summary** — bucket breakdown + flat session-result lines, printed to chat.
3. **Write the consolidated report to disk** — same content, styled HTML, saved under `~/.shipyard/do-work-reports/<owner>-<repo>/`.

The thin entry [`commands/do-work.md`](../do-work.md) owns the hot [orchestrator-state struct list](../do-work.md#orchestrator-state) and a pointer to the [session state file](../do-work.md#session-state-file) (cold long-tail detail split into [`orchestrator-state-reference.md`](./orchestrator-state-reference.md) and [`session-state-file.md`](./session-state-file.md)); this file owns the actual cleanup-reap + summary-render + report-write semantics.

## End-of-session cleanup

Each dispatched agent created a worktree and a local branch. After auto-merge fires with `--delete-branch`, the remote branch is gone but the local branch + worktree linger. Reap them before the summary.

**Run from the orchestrator worktree** (set up in step 0.5) — NOT from the user's primary checkout. Reaping the orchestrator's own worktree happens last, after the user-facing summary prints — see step 6 below.

**Backstop — the `SessionEnd` hook** ([#638](https://github.com/mattsears18/shipyard/issues/638)). The `SessionEnd` hook (`hooks/reap-on-session-end.sh` → `scripts/session-end-reap.sh`) runs independent of the orchestrator's turn — on every session exit it reaps stale `worktree-agent-*` branch refs (#326) + prunes. It is a backstop, not a replacement: this pass is still the fuller sweep (this-session worktrees, `[gone]` `do-work/issue-*` refs, the orchestrator's own worktree). See [RATIONALE → SessionEnd hook backstop](../do-work-RATIONALE.md#end-of-session-cleanup--sessionend-hook-backstop-638) for why the in-turn pass can't be relied on alone.

**Relationship to the immediate-reap in steady-state.md.** Per [#282](https://github.com/mattsears18/shipyard/issues/282), the orchestrator's `shipped #<N>` reconcile in [steady-state.md step A.1](./steady-state.md#a1-parse-the-return-string) reaps the agent worktree for `do-work/issue-<N>` immediately rather than waiting for end-of-session. This pass typically sees only worktrees from `blocked` / `errored` returns, `peer-alive` defers, or synthetic-divert workers — it remains the ultimate sweep; never assume the immediate-reap path covered everything. See [RATIONALE → Immediate-reap relationship](../do-work-RATIONALE.md#end-of-session-cleanup--immediate-reap-relationship-282) for the fuller picture.

**Re-entrancy safety net — a dispatch after this section has already run once this session must not lose its tokens ([#743](https://github.com/mattsears18/shipyard/issues/743)).** See [RATIONALE → Re-entrancy safety net](../do-work-RATIONALE.md#end-of-session-cleanup--re-entrancy-safety-net-743) for why this is belt-and-suspenders behind [drain.md's termination assertion](./drain.md#termination-assertion):

- Steps 7 (flush) and 8 (session-state cleanup) below are NOT the last things that are allowed to touch this session's ledger data. If the orchestrator dispatches another worker after step 8 has already removed the session-state file, [step A.0's `bump-tokens` call](./steady-state.md#a0-attribute-the-dispatchs-token-usage-mandatory--before-any-return-string-parsing) already self-heals it — `--allow-degraded-init --degraded-init-repo` (mandatory on every `bump-tokens` call, per [#253](https://github.com/mattsears18/shipyard/issues/253)) recreates a fresh session file **under the same session id**, stamped `.degraded_recovery_at`, and the new dispatch's tokens land there. No orchestrator action is needed for this half — it already happens on every `bump-tokens` call regardless of mode.
- What is NOT automatic: step 7's `cost-history.sh flush` already ran once for this session id earlier in this same wind-down, so a second plain `flush --session-id <id>` call hits the ledger's own idempotency dedupe gate and silently skips. **If cleanup runs a second time this session**, re-run step 7 with `--reconcile` instead of the plain call: `cost-history.sh flush --session-id <id> --reconcile` MERGES the existing ledger line with the freshly-projected cumulative one instead of skipping it (as of [#745](https://github.com/mattsears18/shipyard/issues/745) this is an element-wise-max/union merge — never write your own `--force-replace`). See the flag's doc comment in `scripts/cost-history.sh` for the exact mechanics. Step 8 (`session-state.sh cleanup`) is already idempotent and needs no special handling on a second call.
- **This section is not a place to file new issues.** If you find yourself wanting to file a follow-up/friction issue while inside cleanup, or after the [end-of-session summary](#end-of-session-summary) has already printed, the corrective action is documented in [drain.md's termination assertion](./drain.md#termination-assertion), not here.

1. Prune stale remote refs so merged-and-deleted branches surface as `[gone]`:
   ```bash
   git fetch --prune
   ```

2. Snapshot what's about to be reaped (for the summary):
   ```bash
   git branch -v | grep '\[gone\]' || echo "(no gone branches)"
   ls -d .claude/worktrees/agent-*/ 2>/dev/null || echo "(no agent worktrees)"
   ```

3. **Reap all agent worktrees from THIS session — classify the lock-holding PID first.** Cleanup can fire while a dispatched agent is still in flight; reaping its worktree would destroy unpushed work. Run the helper [`scripts/worktree-reap.sh classify-lock <lock-file>`](../../scripts/worktree-reap.sh) against each worktree's lock file. It returns one of `no-lock` / `dead` / `self-ancestor` / `peer-alive`. Reap on the first three; defer only on `peer-alive`.

   **3.0. Targeted this-session reap FIRST — by explicit agent-id, before the generic sweep ([#509](https://github.com/mattsears18/shipyard/issues/509)).** The generic loop below (step 3.1) iterates *every* `.git/worktrees/agent-*` directory; on a busy checkout with many accumulated cross-session worktrees it can stall before finishing, stranding this session's own shipped worktrees. See [RATIONALE → Targeted-reap-first ordering](../do-work-RATIONALE.md#step-3--targeted-reap-first-ordering-509) for the repro and the full explanation of why the targeted pass runs before the generic sweep.

   The orchestrator already knows its **own** session's agent-ids — the union of [`reconciled_agent_ids`](./orchestrator-state-reference.md) (every agent reconciled by [steady-state.md step A](./steady-state.md#a-reconcile-the-return)) and the live `in_flight.<slot>.agent_id` values — so it can target them directly. Run the targeted pass first via [`scripts/worktree-reap.sh reap-session-worktrees`](../../scripts/worktree-reap.sh):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   # Declare our orchestrator PID so classify-lock short-circuits on our own
   # locks (issue #263) — same rationale as the generic sweep below.
   export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" detect-orchestrator-pid)

   # Feed this session's agent-ids (one per line) on stdin: the union of
   # reconciled_agent_ids and every live in_flight slot's agent_id. The helper
   # de-dupes, resolves each to its agent-<id> worktree, classifies the lock,
   # reaps on no-lock/dead/self-ancestor (audit phase "cleanup-session-targeted"),
   # and defers only on peer-alive. Worktrees the steady-state immediate-reap
   # (#282) already removed mid-session are skipped silently (no line).
   targeted_reaped=0
   targeted_deferred=0
   # Issue #712 — `unreaped:` is emitted when the removal was ATTEMPTED but the
   # worktree is still on disk afterwards (auto-mode permission denial, dirty
   # tree carrying unpushed commits, filesystem error). The helper reports the
   # verified end state rather than its intent, so this counter is never
   # inflated by a reap that didn't happen.
   targeted_unreaped=0
   while IFS= read -r status_line; do
     case "$status_line" in
       reaped:*)   targeted_reaped=$((targeted_reaped + 1)) ;;
       deferred:*) targeted_deferred=$((targeted_deferred + 1)) ;;
       unreaped:*) targeted_unreaped=$((targeted_unreaped + 1)) ;;
     esac
   done < <(
     printf '%s\n' "${session_agent_ids[@]}" \
       | "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap-session-worktrees \
           --repo-root "$REPO_ROOT" \
           --session-id "<session-id>"
   )
   ```

   `session_agent_ids` is the deduplicated list `reconciled_agent_ids ∪ { in_flight.*.agent_id }` from [`orchestrator-state-reference.md`](./orchestrator-state-reference.md). Fold `targeted_reaped` into the `reaped_worktrees` total, `targeted_deferred` into `deferred_live`, and `targeted_unreaped` into the step 5.5 `unreaped_worktrees` advisory ([#712](https://github.com/mattsears18/shipyard/issues/712)) for the summary — the generic sweep below (step 3.1) is now the **straggler** pass: it sweeps anything the targeted pass didn't already reap (cross-session leftovers, and — defensively — any this-session worktree whose id wasn't in `session_agent_ids`). Running it second means a stall in the generic loop no longer strands this session's own work, because that work is already gone.

   **3.1. Generic sweep — the straggler + safety-net pass.** Now iterate the remaining `.git/worktrees/agent-*`. The `self-ancestor` case is load-bearing: the Claude Code harness writes the **orchestrator's** PID into every dispatched agent's lock file (lock content is literally `claude agent <agent-id> (pid <orchestrator-pid>)`), so at end-of-session cleanup the lock PID is alive by definition — it's the process running cleanup. A strict liveness check would defer every worktree the orchestrator itself owns (see [issue #138](https://github.com/mattsears18/shipyard/issues/138)). `self-ancestor` means the lock PID is the declared orchestrator PID (via `SHIPYARD_ORCHESTRATOR_PID`, set below from `detect-orchestrator-pid`'s ancestor walk) OR is in our own process ancestor chain — not a peer agent, just the orchestrator about to retire its own worktree. Safe to reap. The env-var declaration was added in [issue #263](https://github.com/mattsears18/shipyard/issues/263) because the ancestor-walk path from #138 mis-classifies whenever an intermediate harness layer returns empty PPID. See [RATIONALE → Liveness check at shutdown](../do-work-RATIONALE.md#end-of-session-cleanup--why-the-orchestrator-worktree-is-reaped-last):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   cd "$(git rev-parse --show-toplevel)"
   # Seed the running totals from step 3.0's targeted pass so the generic
   # sweep ADDS to them (don't reset to 0 — that would discard the
   # this-session worktrees already reaped above).
   reaped_worktrees=${targeted_reaped:-0}
   deferred_live=${targeted_deferred:-0}
   # Declare our orchestrator PID so classify-lock can short-circuit on
   # our own locks regardless of process-tree shape (issue #263). Every
   # agent worktree's lock holds the orchestrator's PID (the harness
   # writes it at dispatch time); without an explicit declaration, the
   # ancestor walk inside classify-lock can fail to find the orchestrator
   # whenever an intermediate harness layer returns empty PPID, deferring
   # the reap and stranding worktrees.
   export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" detect-orchestrator-pid)

   for wt_dir in .git/worktrees/agent-*; do
     [ -d "$wt_dir" ] || continue
     name=$(basename "$wt_dir")
     worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
     [ -z "$worktree_path" ] && continue

     classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
       classify-lock "$wt_dir/locked")

     # Extract the lock PID for the audit log (best effort; null literal
     # when the lock file is missing or unparseable).
     lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
     [ -z "$lock_pid" ] && lock_pid="null"

     if [ "$classification" = "peer-alive" ]; then
       # Lock PID is alive AND not in our ancestor chain — a genuine peer
       # (another Claude Code instance's orchestrator, or a still-running
       # dispatched agent whose return hasn't been processed yet). Yanking
       # its worktree out from under it destroys in-flight or unpushed
       # work product. Defer.
       deferred_live=$((deferred_live + 1))
       "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
         --action deferred \
         --worktree-path "$worktree_path" \
         --worktree-name "$name" \
         --session-id "<session-id>" \
         --reason "peer-alive" \
         --lock-pid "$lock_pid" 2>/dev/null || true
       continue
     fi

     # no-lock / dead / self-ancestor — safe to reap.
     git worktree unlock "$worktree_path" 2>/dev/null
     # Issue #284 — the worktree-reap.sh `reap` subcommand performs the
     # actual `git worktree remove --force` AND writes the audit log in
     # one transaction. The helper is the single source of truth so the
     # audit-log write can't be skipped.
     #
     # Counting `reaped_worktrees` requires us to know whether the remove
     # actually succeeded. Probe `git worktree list` for the path after
     # the helper returns: if it's gone, increment.
     "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
       --action reaped \
       --worktree-path "$worktree_path" \
       --worktree-name "$name" \
       --session-id "<session-id>" \
       --classification "$classification" \
       --lock-pid "$lock_pid" 2>/dev/null || true
     if ! git worktree list | awk -v n="$name" '$0 ~ n {found=1} END{exit !found}'; then
       reaped_worktrees=$((reaped_worktrees + 1))
     fi
   done
   git worktree prune
   ```

   The audit log at `~/.shipyard/reap-audit.jsonl` is append-only JSONL. Each line records: `ts` (ISO-8601 UTC), `session` (orchestrator session id), `actor_pid` (the reaping process), `worktree` (the `.git/worktrees/<name>` directory name), `action` (`reaped` or `deferred`), `classification` (from `worktree-reap.sh` — `no-lock`, `dead`, `self-ancestor`), and `lock_pid` (the PID from the lock file, or `null` if unparseable). The audit-line emission lives inside [`worktree-reap.sh reap`](../../scripts/worktree-reap.sh) (issue #284), so the reap and the audit happen as one transaction the orchestrator can't skip. The log write itself is fire-and-forget — a filesystem permission issue must never abort the cleanup loop. When a worker later returns `reaped: my worktree was reaped while I was running`, the orchestrator can cross-reference this log to understand which session did the reaping and why. The log is not purged automatically; a typical `/do-work` session adds at most a few lines.

4. **Reap `[gone]` branches.** Worktrees that were attached to merged-then-deleted branches are already gone (step 3 cleared them); now delete the orphaned local branch refs. The `[gone]` upstream marker is what makes this safe — only branches whose remote was deleted post-merge match. Open / blocked / in-flight PRs still have live remotes, so they're untouched:

   ```bash
   reaped_branches=0
   git branch -v | grep '\[gone\]' | sed 's/^[+* ]//' | awk '{print $1}' | while read branch; do
     git branch -D "$branch" 2>/dev/null && reaped_branches=$((reaped_branches + 1))
   done
   ```

4.5. **Reap orphan `worktree-agent-*` branch refs ([issue #326](https://github.com/mattsears18/shipyard/issues/326)).** The Claude Code harness creates a `worktree-agent-<id>` local branch ref for every agent dispatched with `isolation: "worktree"`. When the harness reaps the worktree directory it does NOT delete the branch ref — the ref leaks and accumulates indefinitely (`git branch | grep -c worktree-agent-` can reach 100+ on an active machine). Run this sweep **before step 6** (orchestrator worktree reap) so any still-live agent branches are detected as live by `git worktree list --porcelain` at scan time.

   The helper [`scripts/worktree-reap.sh reap-orphan-branches`](../../scripts/worktree-reap.sh) enumerates all local `worktree-agent-*` branches, checks each against `git worktree list --porcelain`, and `git branch -D`s any that have no live worktree referencing them. A successful deletion emits one JSONL line to `~/.shipyard/reap-audit.jsonl` with `"action":"reaped-orphan-branch"`, `"branch"`, `"session"`, and `"reason":"no-live-worktree"`, and a matching `reaped-branch: <name>` line on stdout. A `git branch -D` failure (e.g. an unmerged commit, a permission error, or a concurrent-delete race) does NOT emit either — it instead writes an `"action":"reaped-branch-failed"` audit line with `"reason":"branch-delete-failed"` and no stdout line, so a failed delete is never mistaken for a successful reap (issue #874). The sweep is idempotent — a second pass is a no-op. It is safe — branches with a live worktree are skipped unconditionally.

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   reaped_orphan_branches=0
   while IFS= read -r branch_line; do
     [ -z "$branch_line" ] && continue
     # strip "reaped-branch: " prefix
     branch_name="${branch_line#reaped-branch: }"
     reaped_orphan_branches=$((reaped_orphan_branches + 1))
   done < <(
     "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap-orphan-branches \
       --repo-root "$(git rev-parse --show-toplevel)" \
       --session-id "<session-id>"
   )
   ```

   Record `<reaped_orphan_branches>` for the end-of-session summary's cleanup line. When `reaped_orphan_branches == 0` (normal on a fresh checkout or after a clean prior session), omit the count from the summary to reduce noise.

5. Final consistency pass — drop any worktrees whose checkout directory was deleted out from under git:
   ```bash
   git worktree prune
   ```

5.5. **Verify the reaps actually happened — never silent-degrade ([#712](https://github.com/mattsears18/shipyard/issues/712)).** Every reap above is fire-and-forget (`2>/dev/null || true`) inside a background subshell, so a reap that *doesn't happen* produces no signal — including a classifier denial of `git worktree remove --force` in Claude Code's auto permission mode, which kills the whole Bash tool call before any reap-audit line is written. See [RATIONALE → Verify-reaps failure mode](../do-work-RATIONALE.md#step-55--verify-reaps-failure-mode-712) for the denial-message example and the repro that motivated this step.

   The only mechanism that catches this is an independent, after-the-fact probe of the filesystem — assert on the **end state**, not on any step's exit code. That uniformly covers a classifier denial, a git failure, the force-evidence gate declining, and a sweep that never ran:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   unreaped_worktrees=0
   while IFS= read -r leftover_path; do
     [ -z "$leftover_path" ] && continue
     unreaped_worktrees=$((unreaped_worktrees + 1))
     printf 'unreaped-leftover: %s\n' "$leftover_path"
   done < <(
     "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" report-unreaped \
       --repo-root "$(git rev-parse --show-toplevel)" \
       --current-session-id "<session-id>"
   )
   echo "unreaped-worktrees: ${unreaped_worktrees}"
   ```

   **The final `echo` is load-bearing, not decorative.** Every path piped through the `while ... done < <(...)` process substitution above is consumed entirely by the loop — none of it reaches this Bash call's own stdout on its own. Without an explicit `echo` of the tally (and, for diagnosability, each leftover path as it's counted), this step computes `$unreaped_worktrees` correctly inside the subprocess and then discards it: a shell variable set in one Bash tool call does not survive into the next one, and nothing else in this block ever prints the number anywhere the orchestrator can read it back for the summary. Skipping the `echo` is indistinguishable, from the orchestrator's side, from an empty result — the exact "line never appears even when worktrees are stranded" symptom [#1042](https://github.com/mattsears18/shipyard/issues/1042) reports. Read the printed `unreaped-worktrees: <N>` line back into `<unreaped_worktrees>` for the summary render below, rather than trusting the in-process shell variable to have persisted.

   `report-unreaped` excludes this session's own `orchestrator-<session-id>` worktree (still live — it's reaped last, in step 6) and the `*.reap-dead-*` scratch dirs the [#664](https://github.com/mattsears18/shipyard/issues/664) fast path has already renamed aside (registration pruned, branch freed, background unlink in flight). Everything else it emits is a genuine leftover.

   **Fold in a setup-time whole-group classifier denial, if one was recorded.** When [`setup_reap_sweep_denial`](./orchestrator-state-reference.md) is non-null — [00b-parallelization-cache.md's background-group launch](./setup/00b-parallelization-cache.md#classifier-denial-fallback--the-background-groups-own-bash-tool-call-can-be-refused-outright-1042) was itself refused outright at session start, before any of steps 1.6 / 1.6.5 / 3a / 3b / 3c ran — take `unreaped_worktrees = max(unreaped_worktrees, setup_reap_sweep_denial.unreaped_count)`. This directory scan is already the authoritative end-state check (it re-derives from disk, not from either sweep's own bookkeeping), so in the ordinary case the two numbers agree or this scan's own count is the larger one (this session's later reap attempts found more to legitimately fail on); the `max` only matters as a floor for the degenerate case where every worktree the setup-time denial saw was cleared by some *other* mechanism in between (a different session, a manual `/clean_gone`) but the fold would otherwise under-report a denial that genuinely happened this session and is worth surfacing regardless of whether it's still visible on disk this instant.

   **When `unreaped_worktrees > 0`, say so and say what to do about it.** Add the advisory line to the [End-of-session summary](#end-of-session-summary) — the count alone is a mystery; the count plus the one command that fixes it is actionable:

   ```
   Cleanup: <unreaped_worktrees> worktree(s) could not be reaped (permission denied or dirty) — run /clean_gone
   ```

   Omit the line entirely when the count is 0 (the normal case — no noise). **If a cleanup Bash call was denied by the permission classifier during this session, do NOT swallow it either**: the denial is visible to you in the tool result even though it never reached the helper, so fold it into the same advisory rather than proceeding as if cleanup succeeded. Per `shipyard:worker-preamble` § "After a classifier denial", do not retry the denied command through a workaround and do not argue the denial — surface the leftover count and the `/clean_gone` remediation, and move on.

Record `<reaped_worktrees>`, `<reaped_branches>`, `<reaped_orphan_branches>`, `<deferred_live>`, and `<unreaped_worktrees>`; pipe them into the summary alongside `<reaped_stale>` and `<deferred_stale>` from step 3b. A non-zero `<deferred_live>` is a signal worth surfacing — it means an agent was still running when end-of-session cleanup fired (termination declared too early). The worktree survives so the next session's step 3b sweep can finish reaping once the PID is actually dead.

6. **Reap the orchestrator's own worktree — last, after the summary prints.** The orchestrator worktree (`.claude/worktrees/orchestrator-<session-id>`) is still around because the orchestrator was running inside it. After the [End-of-session summary](#end-of-session-summary) prints — and only then; you can't remove the worktree you're still cwd'd into — jump back to the user's primary checkout (read-only at this point), then unlock + remove:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"

   # Capture both paths BEFORE we move
   ORCH_WT_ABS="$(git -C "<repo-root>/.claude/worktrees/orchestrator-<session-id>" rev-parse --show-toplevel)"
   PRIMARY_ABS="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"  # first entry = primary

   cd "$PRIMARY_ABS"

   # Issue #729 — drop the session-id stash (written at step 0.55) BEFORE
   # attempting the remove. It is the orchestrator worktree's only untracked
   # file, so leaving it in place makes the tree permanently dirty — the
   # plain, non-force `git worktree remove` below then refuses on EVERY
   # session (git refuses `remove` on a dirty tree by design), so the
   # `--force` fallback fires unconditionally and #712's non-force-first
   # safety property never actually applies to the one worktree guaranteed
   # to need reaping every single run. Nothing downstream reads this file —
   # steps 7/7.5/8 below all use the `<session-id>` template value, never a
   # file re-read — so deleting it here is free.
   rm -f "$ORCH_WT_ABS/.shipyard-session-id"

   git worktree unlock "$ORCH_WT_ABS" 2>/dev/null

   # Issue #712 / #729 — route the actual remove through worktree-reap.sh's
   # `reap` action instead of a raw `git worktree remove --force` fallback,
   # so any escalation this worktree still needs (e.g. it's dirty for some
   # OTHER reason than the stash above) goes through the same evidence gate
   # (`worktree_force_is_safe`) as every other reap call site in this file,
   # and this reap gets an audit-log line like every other one. The helper's
   # `fast_worktree_remove` tries a non-destructive rename-aside first, then
   # falls back to plain `git worktree remove`, and only escalates to
   # `--force` behind the evidence gate.
   "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
     --action reaped \
     --worktree-path "$ORCH_WT_ABS" \
     --worktree-name "orchestrator-<session-id>" \
     --session-id "<session-id>" \
     --classification "self-orchestrator" 2>/dev/null || true
   git worktree prune
   ```

   `git worktree remove` only modifies shared `.git/worktrees/` metadata — the primary's HEAD never moves. The reap-audit log (`~/.shipyard/reap-audit.jsonl`) now records this removal too — an `"action":"reaped"` line with `"classification":"self-orchestrator"` on success, or `"action":"reaped-failed"` with a `reason` (`unsafe-to-force-unpushed-work` or `worktree-remove-failed`) when the tree was dirty for some reason beyond the stash file and the evidence gate declined to force it. If the remove fails (e.g., genuine uncommitted orchestrator edits — itself a bug; or an auto-mode permission denial per [#712](https://github.com/mattsears18/shipyard/issues/712)), surface that in the summary as `orchestrator worktree NOT reaped: <reason>` and leave it for next session's step 3b sweep.

7. **Flush the session's token data to the persistent cross-session ledger** — before the session file is deleted, append its rolled-up record to `~/.shipyard/cost-history.jsonl` so it survives into the next session's reports ([issue #163](https://github.com/mattsears18/shipyard/issues/163)):

   **Wait on the setup background group first.** Step 0.7's background group (`$SETUP_BACKGROUND_PID`) includes the step 1.6 orphan-session-file sweep, which also writes to `cost-history.jsonl`. Both the sweep and this flush are idempotent, but they can race on the same session file if the background group is still running when end-of-session cleanup reaches step 7. The `wait` costs nothing when the group has already finished (the typical case — ~2s of background work vs. the full session duration):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   # Wait for the setup background group to finish before flushing, to avoid
   # a race between step 1.6's orphan sweep and this flush writing to the same
   # cost-history.jsonl. Both are idempotent, but the wait eliminates the race.
   wait "${SETUP_BACKGROUND_PID:-}" 2>/dev/null || true

   "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "<session-id>"
   ```

   The `flush` subcommand is idempotent (a session id that already appears in the ledger is silently skipped) and exits 0 with no output when the session file is missing — same don't-gate-exit posture as `session-state.sh cleanup`. The two ledger files (`cost-history.jsonl`, `cost-history-issues.jsonl`) are read by `/shipyard:cost report` to produce cross-session usage reports. **Order matters: flush before cleanup**, otherwise the data we want to persist is already gone.

7.5. **Reap the `gh-cached.sh` cache directory** — drop the session-scoped `gh` response cache from [step 0.9](./setup/00b-parallelization-cache.md#09-gh-cachedsh-wrapper-opt-in-per-call-site):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   "${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" cleanup --session-id "<session-id>"
   ```

   Idempotent; same don't-gate-exit posture as the session-state cleanup. The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is session-scoped and has no value after the session terminates — leaving it behind would accumulate on long-running workstations.

8. **Remove the session state file** — close out the durable mirror from [step 1.5](./setup/01-repo-recovery.md#15-initialise-the-session-state-file):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" cleanup --session-id "<session-id>"
   ```

   The `cleanup` subcommand is idempotent. Don't gate session exit on this call; a stale session file gets overwritten by the next session's `init --force`. If `SHIPYARD_KEEP_SESSIONS=1` is set, skip the cleanup call (file stays as a permanent record).

## End-of-session summary

When the loop ends (drain completes or times out, and cleanup has run), report. Lead with a **bucket breakdown** in the same shape as step 2's backlog overview — same two-mode rendering (≥2 non-zero buckets → fixed-width aligned text table; 1 non-zero bucket → single-line summary; 0 buckets → empty-backlog one-liner). The breakdown shows the **remaining open** issues partitioned by skip reason, plus a `Workable` row carrying the remaining workable count (and a reason if 0). Then print the existing flat summary lines below it:

The full shape, **two-or-more-rows mode**:

```
/do-work session — <owner/repo>

Bucket                                       Count   Issues
───────────────────────────────────────────  ─────   ──────────────────────────────────────────────
Workable (remaining after session)               2   #<a>, #<b>   — OR reason text if 0
⛔ Untrusted author                              1   #U → @stranger
blocked:agent-soft label                         1   #S — will auto-clear at next-session backlog fetch
Blocked (body reference)                         1   #D
needs-triage / decomposition                     2   #E, #F
Awaiting refinement                              1   #R
Awaiting human review                            1   #H
Discussion                                       1   #G
Won't fix                                        1   #X
In flight (open PR)                              2   #I → PR #J, #K → PR #L
Assigned to others                               1   #M → @user
```

The full shape, **one-row mode** (skip the table):

```
/do-work session — <owner/repo>

Workable (remaining after session): 2 issues (#<a>, #<b>). Nothing skipped.
```

The full shape, **zero-row mode** (everything closed this session — clean board):

```
/do-work session — <owner/repo>

Remaining open: 0 — clean board.
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Operator queue — needs you (<N_needs_you>):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. <kind> <target> — <reason phrase> (<origin_ref>)
     → <drain command>
  2. <kind> <target> — <reason phrase> (<origin_ref>)
     → <drain command>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Config: schema validation failed at step 0.4 — rejected: <SHIPYARD_CONFIG_SCHEMA_FAILURE>; ran with built-in defaults (#367)
Plugin root: <SHIPYARD_PLUGIN_ROOT_STALE> — run git pull --ff-only before trusting this session's spec-based conclusions (#907)
Recovered from prior session: <salvaged_count> salvaged (PRs created/kept), <abandoned_count> abandoned
Cleared stale @me self-assigns (no worktree, no PR, no branch): <stale_assigns_count> (#<N>, ...)  # omit line if stale_assigns_count == 0 (issue #303)
Issues processed: N
Shipped: M (#A → PR #X [merged|green|pending], #B → PR #Y [merged|green|pending], ...)
In flight at exit: F (#C → PR #Z still pending CI after drain)
Blocked: K (#P — <reason>, #Q — <reason>)
Deferred: <Df> (#P [<defer_reason_class>] — <first sentence of reason>, #Q [<defer_reason_class>] — <first sentence of reason>, ...)
Errored: J (#R — <agent error>)
Dispatch denied (#718): <D_denied> — #<N> [<mode>] <handed back (needs-human-review) | shipped after one accuracy re-scope → PR #<M>>, ...
  Denial text: <verbatim first line of the harness denial>
Operator denied (#746): <O_denied> — <kind> <target> <handed back (agent-console) | shipped after one accuracy re-attempt>, ...
  Denial text: <verbatim first line of the harness denial>
Stalled dispatches (#838/#833): <S_stalled> — #<N> [<mode>] <non-terminal-return|harness-failed> → <resumed → PR #<M> | handed-back → PR #<M> | dropped-clean>, ...
Wasted dispatches (#529): <wasted_narrative_dispatches> non-terminal-narrative returns (~<wasted_narrative_tokens> tokens) — workers that armed a background waiter / returned a progress narrative instead of finishing synchronously; recovered via A.0.5 re-dispatch
Diversions: <D> dispatched
  fix-main-ci: <d1> (<shipped/noop/blocked breakdown, with PR #s and block reasons>)
  fix-failing-prs-batch: <d2> (<shipped/noop/blocked breakdown>)
Drain phase: exited via <reason>; <elapsed_min> min; final session_prs state — merged: <m>, blocked:ci: <c>, rebase-blocked: <r>, still pending: <p>
Drain-phase rebases: <rebased_count> succeeded (#A, #B, ...), <rebase_blocked_count> blocked (#C — <reason>, ...), <deadlocked_count> deadlocked (#E — dirty (fix-checks) + blocked-rebase (fix-rebase) this session, see #1060, ...)
Mutually-blocking PRs (#1140): <mb_pair_count> — #A ↔ #B (files: disjoint|overlap|unknown), ...
CI cost (#323):
  ci.skip_drain_rebase: <true|false> · ci.max_drain_rebases: <N|null> · ci.verify_check_failing_on_head_before_dispatch: <true|false> · ci.require_in_progress_check_to_settle: <true|false> · ci.skip_speculative_rerun: <true|false>
  Dispatches skipped (stale failure on superseded SHA): <dispatches_skipped_stale_failure> — each saved roughly one full CI suite on PRs whose failure had already been pushed past
  Dispatches deferred (in-progress check on current head): <dispatches_deferred_in_progress> — each prevented one double-push (two overlapping CI suites)
  Drain-phase rebases skipped (ci.skip_drain_rebase / ci.max_drain_rebases cap): <drain_rebases_skipped> — each saved one full CI suite on a force-push that would have re-triggered the suite
  Drain-phase rebases dispatched: <drain_rebases_dispatched> (cap: <max_drain_rebases|"none">)
  Estimated CI suites avoided this session: <dispatches_skipped_stale_failure + dispatches_deferred_in_progress + drain_rebases_skipped>
Final repo health: main:<emoji> · failing PRs (all authors): <m>
fix-main-ci flake escalations (#589): <sig1> (<attempts> fix attempts, each green-on-PR/red-on-merge), <sig2> (...)
Reaped from prior sessions: <reaped_stale> stale agent worktrees (dead-PID locks); <deferred_stale> live-PID worktrees left for the owning Claude Code instance
Cleaned up this session: <reaped_worktrees> agent worktrees, <reaped_branches> [gone] branches, <reaped_orphan_branches> orphan worktree-agent-* branch refs; <deferred_live> still-running agent worktrees deferred (next session will sweep)
Cleanup: <unreaped_worktrees> worktree(s) could not be reaped (permission denied or dirty) — run /clean_gone   ← omit this line entirely when <unreaped_worktrees> == 0 (#712)
Primary-checkout leaks (#387): <primary_leak_restores> restored to <default-branch>, <primary_leak_dirty_skips> skipped (primary was dirty — needs manual restore)
Inherited draft PRs (#1069): <inherited_draft_readied_count> readied (#<a> → PR #<a>, ...), <inherited_draft_handback_count> handed back (#<b> — <reason>, ...)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
Lifetime via /do-work: <I> issues closed, <P> PRs opened (repo-wide totals)

⚠️  --fast was used this session — skipped:
  - Backlog overview UI (step 2)
  - /refine-issues (step 3.5): <fast_skip_needs_refinement> issue(s) match a refinement source signal (unrefined this session)
  - blocked:ci sweep (step 3d.1): <fast_skip_blocked_ci> PR(s) may have recoverable CI
  - blocked:agent-soft sweep (step 3d.2 sub-sweep c): <fast_skip_blocked_agent_soft> issue(s) would auto-clear under normal session
  - legacy blocked:agent migration (step 3d.2 sub-sweep b): <fast_skip_blocked_agent_legacy> issue(s) would migrate (→ needs-human-review, or → no-label if a Blocked-by ref is open) under normal session
  - Divert checks (steps 4.5a + 4.5b): main CI status not verified; failing-PR pileup not counted

  Run a normal /shipyard:do-work session soon to pick up the deferred work.

⚠️  Cost attribution: all <total_invocations> dispatch(es) this session ran on the total-tokens-only path — input/output/cache breakdown unavailable from this harness <usage> block (#279). Reported cost is UNRELIABLE, not a lower bound — folding the whole total into the input rate both overstates it (vs. the cheaper cache-read tokens it may include) and understates it (vs. the pricier output tokens it may include), in unpredictable proportion (#1035).

⚠️  Cost attribution degraded: <degraded_attribution_count> of <total_invocations> dispatch(es) used --degraded-total-only because the harness <usage> block lacked input/output/cache breakdown (#279, #295). Reported cost for those dispatches is UNRELIABLE, not a lower bound — folding the total into the input rate both overstates and understates the real spend in unpredictable proportion (#1035).

⚠️  Unpriced model(s): <unpriced_count> model(s) this session are missing from the pricing table (<unpriced_models joined>) — their token counts are recorded but their USD cost is booked as $0.00 (#728). Reported cost is a LOWER BOUND. Fix: add them to PRICING_JQ in scripts/session-state.sh.

⚠️  Model/mode mismatch(es) (#978): <mismatch_count> of <total_invocations> dispatch(es) this session were billed against a model whose family disagrees with what models.<mode> resolves to for that mode — cost attribution may be wrong for these: <mode1> (<count1>), <mode2> (<count2>), ... . This does NOT confirm which model a dispatch actually ran on (the harness exposes no such signal) — it flags a self-reported model that disagrees with configured policy. Check `/shipyard:status` while a session is running (MODEL column) or the per-slot `.in_flight[<slot>].model` this session recorded at dispatch time.

⚠️  Auto-merge unavailable — gh token lacks `workflow` scope (#812): <workflow_scope_count> PR(s) touch .github/workflows/ and cannot auto-merge until you run this once: `gh auth refresh -h github.com -s workflow`. Affected: #<pr1>, #<pr2>, ... — every workflow-touching PR this session hit the identical block; re-arm each with `gh pr merge <M> --auto --<configured auto_merge.method, default squash>` after refreshing the token — never hardcode `--merge` (issue #989).
```

**End-of-session bucket-table rules** (match step 2's modes with one addition):

- **Source data from a fresh fetch** — `gh issue list --repo <owner/repo> --state open --limit 200 --json number,title,labels,assignees,body,author --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'`. The universe drifted since step 2; re-bucket against live state. The `--jq` projection matches step 2's so the bucket router consumes the same flattened shape on both ends. Worker-preamble §"`gh` JSON discipline" covers the convention.
- **Same two-mode rendering as step 2.** Column-width rules, row order, truncation, and the `Workable`-row-always-prints-in-table-mode rule all match.
- **`Workable`-row reason text when `<W_end> == 0`.** Pick the dominant cause: `everything shipped this session` / `everything left is blocked` / `everything left needs triage/design or refinement/review` / `everything left is in flight` / `nothing matches the workable filter` (fallback).
- Print the bucket breakdown FIRST, above the flat lines. The `Operator queue — needs you (N)` block (see its own rule below), when non-empty, prints immediately after the bucket breakdown and before the flat lines — it is the second visually-distinct element, ahead of every routine flat line, precisely so it can't be mistaken for one.

**Per-line rules** for the flat block:

- `Config:` line ([#367](https://github.com/mattsears18/shipyard/issues/367)): omit entirely unless the session-local `SHIPYARD_CONFIG_SCHEMA_FAILURE` was set at [step 0.4](../do-work/setup/00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson) (i.e. the repo had a `shipyard.config.json` that failed schema validation, so the session ran on built-in defaults). When set, print the line with `<SHIPYARD_CONFIG_SCHEMA_FAILURE>` substituted by the captured rejected-field detail (the loader's per-field stderr lines, `; `-joined). Silence is the default — a clean config load (or a repo with no config at all, which gets the separate "not shipyard-initialized" warning at step 0.4) does NOT print this line. This is the end-of-session half of the non-silent-degrade fix: the warning fired once at step 0.4, and this line re-surfaces it at exit so a user who scrolled past the startup warning still sees that their per-repo policy was ignored.
- `Plugin root:` line ([#907](https://github.com/mattsears18/shipyard/issues/907)): omit entirely unless the session-local `SHIPYARD_PLUGIN_ROOT_STALE` was set at [step 0.4](../do-work/setup/00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson) (i.e. `CLAUDE_PLUGIN_ROOT` resolved repo-local — the dogfooding case — AND the primary checkout was measurably behind `origin/<default-branch>` at that point). When set, print the line with `<SHIPYARD_PLUGIN_ROOT_STALE>` substituted by the captured `<N> commit(s) behind origin/<branch> (primary checkout at <sha>)` detail. Silence is the default — a fresh-enough primary checkout, or a consumer install where the check doesn't apply, does NOT print this line. This is a re-surfacing pattern identical to `Config:` above: the warning fired once (loudly, to stderr) at step 0.4, and this line puts it back in front of a user who scrolled past the startup output. Distinct from the always-set-but-not-printed `SHIPYARD_PLUGIN_ROOT_SHA` (recorded for post-hoc "which version of the spec ran?" answerability, per step 0.4's documentation — it doesn't get its own summary line since a fresh checkout has nothing to warn about).
- `Drain phase`: `<reason>` is one of `all PRs settled`, `max_drain_hours ceiling (<X>h)`, or `second stop signal — drain skipped`. (The old `no forward progress for 5 polls` and `120-min ceiling` reasons were replaced by the progress-based exit + `max_drain_hours` ceiling in [#374](https://github.com/mattsears18/shipyard/issues/374) — `all PRs settled` now covers every healthy exit, including the formerly-"no forward progress" case, because per-PR head-movement quiescence IS the settle signal.) The merged / blocked:ci / rebase-blocked / still-pending counts partition `session_prs`.
- `Drain-phase rebases`: omit the line entirely when all three counts (`rebased_count`, `rebase_blocked_count`, `deadlocked_count`) are zero. `<deadlocked_count>` is `(deadlocked_prs | length)` and `<rebase_blocked_count>` is `(rebase_blocked_prs | length) - deadlocked_count` — a `deadlocked_prs` member is a `rebase_blocked_prs` member too, but it's counted and listed **once**, in the `deadlocked` bucket only, not double-counted into the generic `blocked` bucket ([#1060](https://github.com/mattsears18/shipyard/issues/1060)). Omit the `<deadlocked_count> deadlocked (...)` clause entirely when `deadlocked_count == 0` — the overwhelming common case is a `blocked rebase` with no prior `dirty` history on the same PR this session, and most sessions have zero deadlocked PRs at all.
- `Mutually-blocking PRs (#1140)`: **omit entirely** when `mutually_blocking_pairs_detected` is empty — silence is the default for the overwhelming-common case (no mutually-blocking pair this session; this is a rare, two-simultaneous-repo-wide-breakages shape). When non-empty, `<mb_pair_count>` is `(mutually_blocking_pairs_detected | length)` and the list renders one `#A ↔ #B (files: <disjoint|overlap|unknown>)` entry per detected pair, `files:` reflecting the detector's `files_disjoint` verdict for that pair (see [`drain.md`'s Mutually-blocking PR detection section](./do-work/drain.md#mutually-blocking-pr-detection-drain-phase-surfacing-only--1140)). This line is purely informational — detection never changes dispatch routing, so a pair listed here also appears wherever its individual PR state (merged / `blocked:ci` / still pending) is otherwise reported; this line is the one place the *relationship* between the two is named.
- `CI cost (#323)` block: **omit entirely** when ALL of the following hold: every `ci.*` config key is at its default AND every `ci_session_counters.*` counter is `0`. The quiet-session default is silence. When the block prints, the first line surfaces the effective `ci.*` config values (read via `shipyard-config.sh get ci.<key>`) so the operator can correlate the counters with the policy that produced them — a session with `ci.skip_drain_rebase: false` and `drain_rebases_skipped: 0` doesn't render the block, but a session with `ci.skip_drain_rebase: true` and `drain_rebases_skipped: 0` still renders it (config is non-default, even if no rebases were needed). The `Estimated CI suites avoided` total is a rough lower bound, not a billing-accurate ledger — see [RATIONALE → CI-cost estimate caveat](../do-work-RATIONALE.md#end-of-session-summary--ci-cost-estimate-caveat-323) for why.
- `Dispatch denied (#718)` block: a refused dispatch call silently costs a dispatch slot if it isn't recorded here — the target quietly stops being worked with nothing else in the session's output saying why. **Omit entirely** when `dispatch_denials` is empty — silence is the default for the overwhelming-common case (the classifier refused nothing this session). When non-empty, print one entry per **target** (not per attempt — a target that was denied, accuracy-re-scoped, and then dispatched successfully is one entry with the `shipped after one accuracy re-scope` outcome). A `handed back (needs-human-review)` outcome is the one that wants operator attention: it means both permitted attempts were denied and the work now needs a human to run it (or the user to make a permission decision). The `Denial text:` sub-line carries the harness's message **verbatim** — this is the one surface it belongs on, because the summary and the on-disk HTML report are **local** artifacts only the user reads; the same text is deliberately **never** posted to a public GitHub artifact (see [dispatch-rules.md § "Dispatch denied by the harness permission classifier"](./dispatch-rules.md#dispatch-denied-by-the-harness-permission-classifier-718), matching `shipyard:worker-preamble` § "After a classifier denial"). Read from the session-local `dispatch_denials` list (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)). See [RATIONALE → Why denials are recorded](../do-work-RATIONALE.md#end-of-session-summary--why-denial-blocks-are-recorded-718-746-838) for why this line exists at all.
- `Operator denied (#746)` block: a refused operator-phase action silently costs a queue item if it isn't recorded here — it quietly drops out of `operator_queue` with nothing else in the session's output saying why. **Omit entirely** when `operator_denials` is empty — silence is the default for the overwhelming-common case (no operator action was refused this session). When non-empty, print one entry per **item** (not per attempt — an item that was denied, re-attempted with an explicit confirmation cited, and then driven successfully is one entry with the `shipped after one accuracy re-attempt` outcome). A `handed back (agent-console)` outcome means the item is now surfaced to [`/my-turn`](../my-turn.md) rather than driven. The `Denial text:` sub-line carries the harness's message **verbatim** — same local-only posture as the `Dispatch denied` block above (see [`operate/01-queue-and-authorization.md` § "Operator action denied by the harness permission classifier"](./operate/01-queue-and-authorization.md#operator-action-denied-by-the-harness-permission-classifier-746)). Read from the session-local `operator_denials` list (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)). Distinct from `Dispatch denied (#718)` — that block covers refused worker dispatch calls; this one covers refused operator-phase actions (`gh pr close`/`gh pr merge`/browser mutations) against `operator_queue` items.
- `Operator queue — needs you (N)` block ([#849](https://github.com/mattsears18/shipyard/issues/849)): the one block in this summary printed **before** the flat lines rather than folded into one — deliberately visually distinct (the `━` rule above and below it) from every deferred/dispositioned line elsewhere in the summary. See [RATIONALE → Operator queue block visual separation](../do-work-RATIONALE.md#end-of-session-summary--operator-queue-block-visual-separation-849) for why. **Source data is the union of two lists, deduplicated by `target`:** (1) any entries still in the session-local **`operator_handbacks`** ledger (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)) — items that were popped off `operator_queue` this session and handed back (security-class relabel, logged-out console, `paste-secret` tee-up, a `reply-comment` judgment call, or a second classifier denial); and (2) any items **still sitting in `operator_queue`** at end of session — this covers the cases where the drain loop never ran at all (no browser backend reachable — [`operate.md`'s Degradation section](./operate.md#degradation--no-backend-reachable) — or a `--dry-run` session), rendered with a synthetic `reason: "no-browser-backend"` / `reason: "dry-run"` respectively since no per-item append happens in either case. **Omit the block entirely** when the union is empty. Render one numbered entry per item: `<kind> <target> — <reason phrase> (<origin_ref>)` on the first line, the single interactive drain command on the indented second line. **Reason-phrase table** (keyed by the item's `reason` field): `no-browser-backend` → "no browser backend was reachable this session"; `dry-run` → "session ran with --dry-run — plan previewed, not executed"; `security-class` → "access-control mutation (changes who-can-access-what) — outside Claude's safety boundary, always a hand-back"; `logged-out` → "console session was logged out — needs manual sign-in"; `values-only-user-has` → "requires a value only you hold (secret/credential)"; `denied-by-classifier` → "operator action was refused by the permission classifier"; `judgment-call` → "needs your evaluation, not a mechanical action". **Drain-command table** (keyed by the item's current label, not its reason — `current_label` on `operator_handbacks` entries, or `agent-console` by definition for a still-queued `operator_queue` item): `needs-human-review` → `` `/shipyard:my-turn` `` (walked human-only queue — this is the security-class / judgment-call case, per [#848](https://github.com/mattsears18/shipyard/issues/848)); `agent-console` → `` `/shipyard:do-work` (foreground, interactive session) `` (`/my-turn` deliberately excludes `agent-console` from its walked queue — it's pointer-only there by design — so the operator layer itself, run interactively so the browser session is actually watched, is the correct re-entry point).
- `Stalled dispatches (#838/#833)` line: **omit entirely** when `stalled_dispatches` is empty — silence is the default for the common case (no worker stalled or was watchdog-killed this session). When non-empty, print one entry per **occurrence** (each `stalled_dispatches` entry, not deduplicated by target — a target that stalled, was resumed, and later shipped is one `resumed` entry; a target that exhausted its one-resume cap and needed crash-recovery salvage is a separate `handed-back` entry). `resumed` means the worker's own transcript/worktree was reused via `SendMessage`/a fresh same-worktree `agent()` call and (once the resume completed) shipped the given PR. `handed-back` means the resume cap was already spent (or the trigger was a genuine crash) but A.0.5's pre-reap salvage (#493/#495) still recovered committed or dirty work into the given PR. `dropped-clean` means the worktree held nothing recoverable — the slot was simply dropped and step C's next fill retried the candidate; this outcome carries no PR number. Read from the session-local `stalled_dispatches` list (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)). Distinct from `Wasted dispatches (#529)` immediately below — that line is a pure cost counter (dispatch count + tokens) for the `dropped-clean`-shaped subset; this block is the richer per-occurrence ledger covering every trigger and outcome, including the ones that recovered real PRs. See [RATIONALE → Why denials are recorded](../do-work-RATIONALE.md#end-of-session-summary--why-denial-blocks-are-recorded-718-746-838) (same rationale applies to this ledger).
- `Wasted dispatches (#529)` line: **omit entirely** when `wasted_narrative_dispatches == 0` — silence is the default for a clean session where every worker returned a terminal string. When non-zero, print it so the cost of the contract violation is visible rather than silently absorbed by the A.0.5 re-dispatch. A non-terminal narrative return (a worker that armed a `run_in_background` waiter / `Monitor` and returned a progress narrative instead of finishing synchronously — the [#529](https://github.com/mattsears18/shipyard/issues/529) failure mode) is detected at [steady-state.md step A.0.5](./steady-state.md#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing): increment `wasted_narrative_dispatches` and add the dispatch's attributed `<usage>` total (from [step A.0](./steady-state.md#a0-attribute-the-dispatchs-token-usage-mandatory--before-any-return-string-parsing)) to `wasted_narrative_tokens` whenever the crash-aware reap fires on a return that failed the terminal-prefix check AND the slot had no recoverable committed/dirty work (i.e. the dispatch produced zero output and is being fully re-dispatched). A crash-like return that *did* leave recoverable work (the A.0.5 recovery push/auto-commit path) is NOT a wasted dispatch — it produced shippable output, so don't count it. The two counters live in the session-local orchestrator state alongside the other `*_counters` maps.
- `Diversions:` block: omit entirely when `D == 0`. `Final repo health` always prints.
- `Primary-checkout leaks (#387)` line: **omit entirely** when `primary_leak_restores == 0` AND `primary_leak_dirty_skips == 0` — silence is the default for the overwhelming-common case (no harness leak this session). When either counter is non-zero, print the line so the operator sees the harness `isolation: "worktree"` leak fired and how it was handled. A non-zero `primary_leak_dirty_skips` is the one worth acting on — it means the primary checkout is still parked on a `do-work/*` branch with uncommitted changes shipyard refused to touch; the operator must `git checkout <default>` manually (and a fix-rebase for the affected PR will keep bailing until they do). Counters read from the session-local `primary_leak_counters` map (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)).
- `Inherited draft PRs (#1069)` line: **omit entirely** when `inherited_draft_prs` is empty — silence is the default (the overwhelming common case is no inherited draft this session). When non-empty, this is the one line this list is REQUIRED to always surface through — a draft PR is invisible to both the failed-PR scan (checks read `SKIPPED`) and the DIRTY-PR seed (`mergeStateStatus` reads `CLEAN`), so this is the only place in the whole session's output an inherited draft is guaranteed to appear, whether or not it was auto-readied. Split the list by `action`: entries whose `action` starts with `readied-` count toward `<inherited_draft_readied_count>` (rendered `#<N> → PR #<N>` — same PR, since the draft already existed; a `readied-manual-merge-needed` entry additionally needs a human to merge once CI settles, per the ungated-admin-direct-merge shape — call this out in the reason if it's the only readied entry) and everything else counts toward `<inherited_draft_handback_count>` (rendered `#<N> — <disposition trimmed to its reason, e.g. "gated-label" / "wip-marker" / "stale-closing-issue">`). Read from the session-local `inherited_draft_prs` list (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md#cold-orchestrator-state-structures)).
- `fix-main-ci flake escalations (#589)` line: **omit entirely** when no signature in `main_ci_fix_attempts` has `escalated == true` — silence is the default for the common case (no flake circuit breaker tripped). When at least one signature escalated, print the line so the operator sees which workflow(s) the orchestrator stopped auto-diverting and why, with the per-signature attempt count. Each escalated signature is a recommended action item: quarantine the flaky test (`test.fixme` / skip) + file a tracking issue, OR investigate CI-side. Read from the session-local `main_ci_fix_attempts` map (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)). This is the fix-main-ci analogue of surfacing `blocked:ci` PRs in the drain-phase line.
- `Deferred:` line: omit when `deferred_issues` is empty. When non-empty, render one `#N [<defer_reason_class>] — <first sentence of reason>` per entry (truncate at first sentence or 80 chars). The bracketed `defer_reason_class` is one of `external-dependency` / `human-decision-required` / `untrusted-author` / `confirmed-blocker-still-open` / `confirmed-non-shippable-as-single-PR` ([#298](https://github.com/mattsears18/shipyard/issues/298)). An entry missing this field is a spec violation — when reading from session state for the summary, default to `confirmed-non-shippable-as-single-PR` with a `[shipyard] deferred_issues entry #<N> missing defer_reason_class — defaulted at summary-render time` advisory line above the block. Per [#302](https://github.com/mattsears18/shipyard/issues/302) every entry also carries a non-empty `evidence_pointer` (mechanical citation grounding the class); entries reaching the summary with a missing/empty `evidence_pointer` are spec violations too — emit the same advisory line shape (`[shipyard] deferred_issues entry #<N> missing evidence_pointer — spec violation`) above the block. Full reason is posted as a comment on each issue.
- `--fast was used` block: omit when `--fast` was NOT passed. When `--fast` was passed, always print this block at the end of the summary — even when all four counts are zero (the user needs to know the checks didn't run). The four counts (`fast_skip_needs_refinement`, `fast_skip_blocked_ci`, `fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`) come from the cheap reads in step 2's `--fast` note. (`fast_skip_blocked_agent_hard` was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — the `blocked:agent-hard` label no longer exists.)
- `Cost attribution` block: omit when `.tokens.degraded_attribution_count` is `0` or missing — silence is the right default for sessions that ran entirely on the strict A.0 path. When non-zero, **branch on the ratio** so the operator can distinguish a structural harness gap from a mid-session degradation ([#295](https://github.com/mattsears18/shipyard/issues/295)):
  - **All-degraded (`degraded_attribution_count == total_invocations`)** — print the first banner variant (`⚠️  Cost attribution: all <N> dispatch(es) this session ran on the total-tokens-only path …`). This is the steady-state shape on harness versions whose `<usage>` block structurally never emits the input/output/cache breakdown (observed on Opus 4.7, 2026-05-23 — see [#279](https://github.com/mattsears18/shipyard/issues/279)). The framing intentionally drops the per-dispatch "X of Y degraded" framing because *every* dispatch is in the same boat; "X of X" reads as a mistake rather than a structural condition.
  - **Partial-degraded (`0 < degraded_attribution_count < total_invocations`)** — print the second banner variant (`⚠️  Cost attribution degraded: <degraded_attribution_count> of <total_invocations> …`). This is the mixed case: some dispatches landed on the strict path (breakdown available) and some didn't (e.g., a worker on a strict-path harness with one or two failing-handoff dispatches). The per-dispatch ratio is informative here because it tells the operator how much of the printed cost is precise vs. unreliable.

  `<degraded_attribution_count>` reads directly from `.tokens.degraded_attribution_count`; `<total_invocations>` is `(.tokens.per_invocation | length)`. **Neither banner claims a multiplier or a bound ([#1035](https://github.com/mattsears18/shipyard/issues/1035)).** An earlier version of this banner claimed the degraded figure was a "lower bound, real spend ≈ 1.5× printed" — that framing is wrong: folding a dispatch's entire `total_tokens` into the `--input` bucket prices real cache-read tokens (far cheaper than input) at the input rate, which *inflates* the estimate, while pricing real output tokens (several times pricier than input) at the input rate *deflates* it. The two errors don't cancel in any predictable direction, so — unlike the genuine, directional LOWER BOUND the `Unpriced model(s)` banner below reports — a degraded figure isn't reliable as a floor OR a ceiling. Say so plainly (UNRELIABLE) rather than attach a specific-sounding multiplier to a number whose error direction is unknown. See [#279](https://github.com/mattsears18/shipyard/issues/279) for the harness-side gap this banner surfaces and [#295](https://github.com/mattsears18/shipyard/issues/295) for the all-vs-partial banner split. The same `degraded_attribution_count` is persisted into the cross-session ledger by `cost-history.sh flush` (session-record projection + `--reconcile` merge), so `/shipyard:cost report` re-surfaces the identical UNRELIABLE labeling — a `[UNRELIABLE]` tag on the `Spend:` line plus a `DEGRADED COST ATTRIBUTION` advisory block, both distinct from the `[LOWER BOUND]` / `UNPRICED MODELS` pair — long after the session file is reaped.

- `Unpriced model(s)` block ([#728](https://github.com/mattsears18/shipyard/issues/728)): omit when `.tokens.unpriced_models` is empty or missing — silence is the right default, and it's the *overwhelming* common case (every model the session ran on was in the pricing table). When non-empty, print the banner: `<unpriced_count>` is `(.tokens.unpriced_models | length)` and `<unpriced_models joined>` is the array `, `-joined. `$0.00` is a legitimate value and must never double as the error sentinel — hence the explicit set rather than an inferred-from-zero heuristic. See [RATIONALE → Unpriced-model banner](../do-work-RATIONALE.md#end-of-session-summary--unpriced-model-banner-728) for why this is distinct from the `Cost attribution` banner and the repro that motivated it.

  The set is written by `session-state.sh bump-tokens` (which also warns on stderr at the moment of the miss) and persisted into the cross-session ledger by `cost-history.sh flush`, so `/shipyard:cost report` re-surfaces the same advisory long after the session file is reaped. `scripts/tests/pricing-coverage.test.sh` is the upstream guard that keeps a *shipped* model (config default or agent-shim frontmatter) from ever reaching this banner — the banner exists for models the harness picks that the repo doesn't declare.

- `Model/mode mismatch(es)` block ([#978](https://github.com/mattsears18/shipyard/issues/978)): omit when every `.tokens.per_invocation[]` entry's billed model family agrees with what `resolve-dispatch-model.sh <mode>` resolves for that entry's `mode` (entries with a null/empty `mode` or `model` are skipped — nothing to compare) — silence is the right default for a session where every mode's dispatches consistently ran on its configured tier. When at least one entry disagrees, print the banner: `<mismatch_count>` is the count of disagreeing entries, `<total_invocations>` is `(.tokens.per_invocation | length)`, and the per-mode breakdown lists each distinct mode with at least one mismatch alongside its count of mismatched entries. This is the cumulative, end-of-session view of the identical live check `session-state.sh bump-tokens` runs at write time (see that script's `cmd_bump_tokens` header comment) — a mismatch here means a `models.<mode>` override was configured but this mode's dispatches didn't consistently bill against it, which is exactly the failure that produced a confidently-wrong lower total in the [#978](https://github.com/mattsears18/shipyard/issues/978) repro (the orchestrator self-reported Sonnet cost for dispatches that had really run on Opus). Like the `Unpriced model(s)` banner immediately above, this can only ever confirm a *policy* mismatch, never ground truth — the harness exposes no signal for which model a dispatch actually ran on.

- `Auto-merge unavailable — gh token lacks workflow scope` block ([#812](https://github.com/mattsears18/shipyard/issues/812)): omit entirely when `workflow_scope_blocked_prs` is empty — silence is the default (the overwhelming common case for a session that never touches `.github/workflows/`). When non-empty, print the banner once with `<workflow_scope_count>` = `(workflow_scope_blocked_prs | length)` and the full PR list. This is the **session-level hoist** the per-PR `shipped` return deliberately avoids repeating: every PR in the list failed to auto-merge for the identical, deterministic reason (the dispatching `gh` token lacks the `workflow` OAuth scope and the PR's diff touches `.github/workflows/`), so restating the cause per PR would be noise — one banner naming every affected PR plus the one-time fix (`gh auth refresh -h github.com -s workflow`) is the whole point. Each listed PR is still OPEN, unarmed, and sitting in `session_prs` — nothing else about drain or the PR's own state changes; this banner is purely the visibility fix for a precondition the orchestrator cannot self-remediate (widening the token's own scope is a one-time human action, never something to route around). Read from the session-local [`workflow_scope_blocked_prs`](../do-work.md#orchestrator-state) list.

The lifetime line is sourced from two queries run just before printing the summary:

```bash
gh issue list --repo <owner/repo> --label shipyard --state closed --limit 1000 --json number --jq 'length'
gh pr list --repo <owner/repo> --label shipyard --state all --limit 1000 --json number --jq 'length'
```

If either query fails (e.g., the label doesn't exist yet because this is a fresh repo), default to `0`.

## Write the consolidated report to disk

After emitting the chat summary, persist the same content to a styled HTML report at `${SHIPYARD_HOME:-$HOME/.shipyard}/do-work-reports/<owner>-<repo>/<YYYY-MM-DD>-do-work-session.html`. Reports are styled HTML (not markdown) so the maintainer can read in a browser with badges, hover states, and clickable links.

**Why shipyard-home, not in-repo `.shipyard/do-work/` ([#488](https://github.com/mattsears18/shipyard/issues/488)).** `/shipyard:do-work` has no writable in-repo location for a persistent artifact — the orchestrator's worktree is force-removed at cleanup and the primary checkout is read-only + hook-blocked for the whole session. Writing to `~/.shipyard/do-work-reports/` instead sidesteps both: it's outside any git checkout, so it's never hook-blocked and survives worktree reap. Reports for every repo accumulate under one root, partitioned by `<owner>-<repo>`; `SHIPYARD_HOME` overrides the default `~/.shipyard` for tests / sandboxed runs. See [RATIONALE → Report location](../do-work-RATIONALE.md#write-the-consolidated-report-to-disk--why-shipyard-home-488) for the full comparison against `/shipyard:audit`'s in-repo location.

**Skip the write when** `shipped_count + filed_count + reaped_worktrees == 0`, or when the user drained immediately after backlog overview without shipping anything.

1. **Resolve the reports root and create the per-repo directory.** The repo slug is `<owner>/<repo>` with `/` → `-` so it's a single path segment:

   ```bash
   REPORTS_ROOT="${SHIPYARD_HOME:-$HOME/.shipyard}/do-work-reports"
   REPO_SLUG="$(echo '<owner/repo>' | tr '/' '-')"
   REPORTS_DIR="$REPORTS_ROOT/$REPO_SLUG"
   mkdir -p "$REPORTS_DIR"
   ```

   This is outside any git checkout — no `git add`, no `.gitignore` interaction, and never blocked by the worktree-isolation hook.

2. **Ensure the shared stylesheet exists at `$REPORTS_ROOT/styles.css`** (one stylesheet shared by every repo's reports). Idempotent — only write when the file does not exist (`if [ ! -f "$REPORTS_ROOT/styles.css" ]`); never clobber a user-edited version. Full CSS template lives in [`commands/audit.md`](../audit.md) → "Write the consolidated report to disk" step 2 (canonical source). Reports reference it via `../styles.css` (the report sits one level deeper, under `$REPORTS_ROOT/<owner>-<repo>/`).

3. **Compute the target path.** Base name `<YYYY-MM-DD>-do-work-session.html` (local timezone); suffix `-2`, `-3`, etc. on same-day re-runs:

   ```bash
   base="$(date +%Y-%m-%d)-do-work-session"
   path="$REPORTS_DIR/${base}.html"
   n=2
   while [ -e "$path" ]; do path="$REPORTS_DIR/${base}-${n}.html"; n=$((n+1)); done
   ```

4. **Write the report** using the `Write` tool. HTML skeleton below — populate placeholders directly:

   ```html
   <!doctype html>
   <html lang="en">
   <head>
     <meta charset="utf-8" />
     <meta name="viewport" content="width=device-width, initial-scale=1" />
     <title>/shipyard:do-work session — <owner/repo> — <YYYY-MM-DD></title>
     <link rel="stylesheet" href="../styles.css" />
   </head>
   <body>
     <main>
       <header>
         <h1>/shipyard:do-work session — <owner/repo></h1>
         <div class="meta">
           <strong>Repo:</strong> <owner/repo> ·
           <strong>Started:</strong> <ISO8601 UTC> ·
           <strong>Ended:</strong> <ISO8601 UTC> ·
           <strong>Duration:</strong> <H>h<M>m ·
           <strong>Concurrency:</strong> <--concurrency N> (soft-collision cap: <N>) ·
           <strong>PRs merged this session:</strong> <merged_count> ·
           <strong>Issues shipped this session:</strong> <shipped_count> ·
           <strong>Lifetime via /do-work:</strong> <I> issues closed, <P> PRs opened (repo-wide)
         </div>
       </header>

       <section>
         <h2>Headline numbers</h2>
         <ul>
           <li>PRs merged: <merged_count></li>
           <li>Issues shipped: <shipped_count></li>
           <li>Issues filed (shipyard improvement, see below): <filed_count></li>
           <li>Diversions dispatched: <D> (fix-main-ci: <d1>, fix-failing-prs-batch: <d2>)</li>
           <li>Drain phase: exited via <code><reason></code> in <elapsed_min> min</li>
         </ul>
       </section>

       <section>
         <h2>Backlog shape</h2>
         <table>
           <thead>
             <tr><th>Phase</th><th class="num">Workable</th><th class="num">Blocked</th><th class="num">Needs-triage</th><th class="num">In flight</th></tr>
           </thead>
           <tbody>
             <tr><td>Start</td><td class="num"><s_w></td><td class="num"><s_b></td><td class="num"><s_t></td><td class="num"><s_i></td></tr>
             <tr><td>Mid-session deltas</td><td class="num">+<m_w_added></td><td class="num">…</td><td class="num">…</td><td class="num">peak <m_i_peak>/<concurrency></td></tr>
             <tr><td>End</td><td class="num"><e_w></td><td class="num"><e_b></td><td class="num"><e_t></td><td class="num"><e_i></td></tr>
           </tbody>
         </table>
       </section>

       <section>
         <h2>What shipped</h2>
         <table>
           <thead><tr><th>Issue</th><th>PR</th><th>Title</th><th>Final state</th></tr></thead>
           <tbody>
             <tr>
               <td><a class="issue" href="https://github.com/<owner/repo>/issues/<N>"><span class="hash">#</span><N></a></td>
               <td><a class="pr-link" href="https://github.com/<owner/repo>/pull/<M>"><span class="badge pr">PR</span><span class="hash">#</span><M></a></td>
               <td><title></td>
               <td><span class="badge merged">merged</span></td>
             </tr>
             <tr>
               <td><a class="issue" href="…"><span class="hash">#</span><N></a></td>
               <td><a class="pr-link" href="…"><span class="badge pr">PR</span><span class="hash">#</span><M></a></td>
               <td><title></td>
               <td><span class="badge open">blocked:ci</span></td>
             </tr>
           </tbody>
         </table>
       </section>

       <section>
         <h2>Notable cross-PR conflicts</h2>
         <ul>
           <li><code><path></code> — touched by <k> in-flight PRs (<PR links>); resolved via <auto-rebase / manual / land-order serialization>.</li>
         </ul>
       </section>

       <section>
         <h2>Mid-session phenomena</h2>
         <ul>
           <li><anything weird worth remembering — long-running fix-checks, flake cascades, agent misbehavior, premature-termination near-misses, divert events, soft-collision cap reached></li>
         </ul>
       </section>

       <section>
         <h2>Shipyard improvement issues filed</h2>
         <table>
           <thead><tr><th>Issue</th><th>Title</th><th>Severity</th></tr></thead>
           <tbody>
             <tr>
               <td><a class="issue" href="https://github.com/mattsears18/shipyard/issues/<n>"><span class="hash">#</span><n></a></td>
               <td><title></td>
               <td><span class="badge p1">P1</span></td>
             </tr>
           </tbody>
         </table>
         <p>(Gaps in the orchestrator itself surfaced by the session — filed against <code>mattsears18/shipyard</code> per the global memory rule.)</p>
       </section>

       <section>
         <h2>User-action follow-ups</h2>
         <ul>
           <li><thing that blocks full value-delivery and needs a human — Secret Manager values, Vercel env vars, blocked:ci PRs needing review, blocked-rebase PRs surfaced by the drain, manual-gate release PRs></li>
           <li><one <li> per <code>Operator queue — needs you</code> entry (#849) — <kind> <target>: <reason phrase> → <drain command>; omit this sub-list entirely when that block was omitted from the chat summary></li>
         </ul>
       </section>

       <section>
         <h2>End-of-session cleanup</h2>
         <ul>
           <li>Reaped this session: <reaped_worktrees> agent worktrees, <reaped_branches> [gone] branches, <reaped_orphan_branches> orphan worktree-agent-* branch refs</li>
           <li>Deferred (still-running PIDs): <deferred_live></li>
           <li>Reaped from prior sessions: <reaped_stale> stale worktrees; <deferred_stale> live-PID worktrees left for the owning Claude Code instance</li>
           <li>Could NOT be reaped (permission denied or dirty): <unreaped_worktrees> — run <code>/clean_gone</code> (omit this <code>&lt;li&gt;</code> entirely when the count is 0; issue #712)</li>
           <li>Final <code>git worktree list</code> shape: <n> worktrees (primary + orchestrator + <m> agent worktrees deferred)</li>
         </ul>
       </section>
     </main>
   </body>
   </html>
   ```

   Severity badges: pick the matching CSS class (`p0` / `p1` / `p2`). Final-state badges use `merged` (green), `open` (blue — for blocked:ci / pending), `closed` (purple — for abandoned). Same-day audit reports filed via `/shipyard:audit` are sibling-linkable at relative path `../audits/<YYYY-MM-DD>-shipyard-audit.html` if the session report wants to cross-reference them.

   Omit sections that have no content (e.g. zero diversions → drop the line; no cross-PR conflicts → drop the entire "Notable cross-PR conflicts" section; no shipyard improvement issues filed → drop that section entirely). Don't pad with empty rows — empty rows are noise. The shape is "everything the chat summary said, plus context the chat summary elided for brevity." Escape interpolated user-supplied text appropriately (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;` inside attributes) — issue titles are the most likely place to forget escaping.

5. **Surface the path in chat** as the last line of your reply so the user sees where it landed. Show the resolved absolute path (the `$path` computed in step 3):

   > Report saved: `~/.shipyard/do-work-reports/<owner>-<repo>/<filename>.html`

If `${SHIPYARD_HOME:-$HOME/.shipyard}/do-work-reports/` can't be created (read-only filesystem, permissions), report the failure inline (`Report could not be saved: <reason>`) and continue — don't block the chat summary on it. The report is a side-effect, not a contract; the chat summary is the source of truth and runs unconditionally.
