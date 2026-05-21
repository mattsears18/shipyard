# /shipyard:do-work — End-of-session cleanup + summary + report

The session's wind-down trio. Runs after [drain](./drain.md) exits:

1. **End-of-session cleanup** — reap agent worktrees, prune branches, flush the cost ledger, retire the session-state file. Last step retires the orchestrator's own worktree.
2. **End-of-session summary** — bucket breakdown + flat session-result lines, printed to chat.
3. **Write the consolidated report to disk** — same content, styled HTML, saved under `.shipyard/do-work/`.

The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and the [session state file schema](../do-work.md#session-state-file); this file owns the actual cleanup-reap + summary-render + report-write semantics.

## End-of-session cleanup

Each dispatched agent created a worktree and a local branch. After auto-merge fires with `--delete-branch`, the remote branch is gone but the local branch + worktree linger. Reap them before the summary.

**Run from the orchestrator worktree** (set up in step 0.5) — NOT from the user's primary checkout. Reaping the orchestrator's own worktree happens last, after the user-facing summary prints — see step 6 below.

1. Prune stale remote refs so merged-and-deleted branches surface as `[gone]`:
   ```bash
   git fetch --prune
   ```

2. Snapshot what's about to be reaped (for the summary):
   ```bash
   git branch -v | grep '\[gone\]' || echo "(no gone branches)"
   ls -d .claude/worktrees/agent-*/ 2>/dev/null || echo "(no agent worktrees)"
   ```

3. **Reap all agent worktrees from THIS session — classify the lock-holding PID first.** Cleanup can fire while a dispatched agent is still in flight; reaping its worktree would destroy unpushed work. Run the helper [`scripts/worktree-reap.sh classify-lock <lock-file>`](../../scripts/worktree-reap.sh) against each worktree's lock file. It returns one of `no-lock` / `dead` / `self-ancestor` / `peer-alive`. Reap on the first three; defer only on `peer-alive`. The `self-ancestor` case is load-bearing: the Claude Code harness writes the **orchestrator's** PID into every dispatched agent's lock file (lock content is literally `claude agent <agent-id> (pid <orchestrator-pid>)`), so at end-of-session cleanup the lock PID is alive by definition — it's the process running cleanup. A strict liveness check would defer every worktree the orchestrator itself owns (see [issue #138](https://github.com/mattsears18/claude-plugins/issues/138)). `self-ancestor` means the lock PID is in our own process ancestor chain — not a peer agent, just the orchestrator about to retire its own worktree. Safe to reap. See [RATIONALE → Liveness check at shutdown](../do-work-RATIONALE.md#end-of-session-cleanup--why-the-orchestrator-worktree-is-reaped-last):

   ```bash
   cd "$(git rev-parse --show-toplevel)"
   reaped_worktrees=0
   deferred_live=0
   for wt_dir in .git/worktrees/agent-*; do
     [ -d "$wt_dir" ] || continue
     name=$(basename "$wt_dir")
     worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
     [ -z "$worktree_path" ] && continue

     classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
       classify-lock "$wt_dir/locked")

     if [ "$classification" = "peer-alive" ]; then
       # Lock PID is alive AND not in our ancestor chain — a genuine peer
       # (another Claude Code instance's orchestrator, or a still-running
       # dispatched agent whose return hasn't been processed yet). Yanking
       # its worktree out from under it destroys in-flight or unpushed
       # work product. Defer.
       deferred_live=$((deferred_live + 1))
       continue
     fi

     # no-lock / dead / self-ancestor — safe to reap.
     git worktree unlock "$worktree_path" 2>/dev/null
     if git worktree remove --force "$worktree_path" 2>/dev/null; then
       reaped_worktrees=$((reaped_worktrees + 1))
     fi
   done
   git worktree prune
   ```

4. **Reap `[gone]` branches.** Worktrees that were attached to merged-then-deleted branches are already gone (step 3 cleared them); now delete the orphaned local branch refs. The `[gone]` upstream marker is what makes this safe — only branches whose remote was deleted post-merge match. Open / blocked / in-flight PRs still have live remotes, so they're untouched:

   ```bash
   reaped_branches=0
   git branch -v | grep '\[gone\]' | sed 's/^[+* ]//' | awk '{print $1}' | while read branch; do
     git branch -D "$branch" 2>/dev/null && reaped_branches=$((reaped_branches + 1))
   done
   ```

5. Final consistency pass — drop any worktrees whose checkout directory was deleted out from under git:
   ```bash
   git worktree prune
   ```

Record `<reaped_worktrees>`, `<reaped_branches>`, and `<deferred_live>`; pipe them into the summary alongside `<reaped_stale>` and `<deferred_stale>` from step 3b. A non-zero `<deferred_live>` is a signal worth surfacing — it means an agent was still running when end-of-session cleanup fired (termination declared too early). The worktree survives so the next session's step 3b sweep can finish reaping once the PID is actually dead.

6. **Reap the orchestrator's own worktree — last, after the summary prints.** The orchestrator worktree (`.claude/worktrees/orchestrator-<session-id>`) is still around because the orchestrator was running inside it. After the [End-of-session summary](#end-of-session-summary) prints — and only then; you can't remove the worktree you're still cwd'd into — jump back to the user's primary checkout (read-only at this point), then unlock + force-remove:

   ```bash
   # Capture both paths BEFORE we move
   ORCH_WT_ABS="$(git -C "<repo-root>/.claude/worktrees/orchestrator-<session-id>" rev-parse --show-toplevel)"
   PRIMARY_ABS="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"  # first entry = primary

   cd "$PRIMARY_ABS"
   git worktree unlock "$ORCH_WT_ABS" 2>/dev/null
   git worktree remove --force "$ORCH_WT_ABS" 2>/dev/null
   git worktree prune
   ```

   `git worktree remove` only modifies shared `.git/worktrees/` metadata — the primary's HEAD never moves. If the remove fails (e.g., uncommitted orchestrator edits — itself a bug), surface that in the summary as `orchestrator worktree NOT reaped: <reason>` and leave it for next session's step 3b sweep.

7. **Flush the session's token data to the persistent cross-session ledger** — before the session file is deleted, append its rolled-up record to `~/.shipyard/cost-history.jsonl` so it survives into the next session's reports ([issue #163](https://github.com/mattsears18/claude-plugins/issues/163)):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "<session-id>"
   ```

   The `flush` subcommand is idempotent (a session id that already appears in the ledger is silently skipped) and exits 0 with no output when the session file is missing — same don't-gate-exit posture as `session-state.sh cleanup`. The two ledger files (`cost-history.jsonl`, `cost-history-issues.jsonl`) are read by `/shipyard:cost report` to produce cross-session usage reports. **Order matters: flush before cleanup**, otherwise the data we want to persist is already gone.

8. **Remove the session state file** — close out the durable mirror from [step 1.5](./setup.md#15-initialise-the-session-state-file):

   ```bash
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
blocked:agent label                              3   #A, #B, #C
Blocked (body reference)                         1   #D
needs-triage / needs-design                      2   #E, #F
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

Recovered from prior session: <salvaged_count> salvaged (PRs created/kept), <abandoned_count> abandoned
Advisory: <A> labeled+assigned issues with no worktree and no PR (#<N>, ...)  # omit line if A == 0
Issues processed: N
Shipped: M (#A → PR #X [merged|green|pending], #B → PR #Y [merged|green|pending], ...)
In flight at exit: F (#C → PR #Z still pending CI after drain)
Blocked: K (#P — <reason>, #Q — <reason>)
Deferred: <Df> (#P — <first sentence of reason>, #Q — <first sentence of reason>, ...)
Errored: J (#R — <agent error>)
Diversions: <D> dispatched
  fix-main-ci: <d1> (<shipped/noop/blocked breakdown, with PR #s and block reasons>)
  fix-failing-prs-batch: <d2> (<shipped/noop/blocked breakdown>)
Drain phase: exited via <reason>; <elapsed_min> min; final session_prs state — merged: <m>, blocked:ci: <c>, rebase-blocked: <r>, still pending: <p>
Drain-phase rebases: <rebased_count> succeeded (#A, #B, ...), <rebase_blocked_count> blocked (#C — <reason>, ...)
Final repo health: main:<emoji> · failing PRs (all authors): <m>
Reaped from prior sessions: <reaped_stale> stale agent worktrees (dead-PID locks); <deferred_stale> live-PID worktrees left for the owning Claude Code instance
Cleaned up this session: <reaped_worktrees> agent worktrees, <reaped_branches> [gone] branches; <deferred_live> still-running agent worktrees deferred (next session will sweep)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
Lifetime via /do-work: <I> issues closed, <P> PRs opened (repo-wide totals)
```

**End-of-session bucket-table rules** (match step 2's modes with one addition):

- **Source data from a fresh fetch** — `gh issue list --repo <owner/repo> --state open --limit 200 --json number,title,labels,assignees,body,author`. The universe drifted since step 2; re-bucket against live state.
- **Same two-mode rendering as step 2.** Column-width rules, row order, truncation, and the `Workable`-row-always-prints-in-table-mode rule all match.
- **`Workable`-row reason text when `<W_end> == 0`.** Pick the dominant cause: `everything shipped this session` / `everything left is blocked` / `everything left needs triage/design or refinement/review` / `everything left is in flight` / `nothing matches the workable filter` (fallback).
- Print the bucket breakdown FIRST, above the flat lines.

**Per-line rules** for the flat block:

- `Drain phase`: `<reason>` is one of `all PRs settled`, `no forward progress for 5 polls`, `120-min ceiling`, or `second stop signal — drain skipped`. The merged / blocked:ci / rebase-blocked / still-pending counts partition `session_prs`.
- `Drain-phase rebases`: omit the line entirely when both counts are zero.
- `Diversions:` block: omit entirely when `D == 0`. `Final repo health` always prints.
- `Deferred:` line: omit when `deferred_issues` is empty. When non-empty, render one `#N — <first sentence of reason>` per entry (truncate at first sentence or 80 chars). Full reason is posted as a comment on each issue.

The lifetime line is sourced from two queries run just before printing the summary:

```bash
gh issue list --repo <owner/repo> --label shipyard --state closed --limit 1000 --json number --jq 'length'
gh pr list --repo <owner/repo> --label shipyard --state all --limit 1000 --json number --jq 'length'
```

If either query fails (e.g., the label doesn't exist yet because this is a fresh repo), default to `0`.

## Write the consolidated report to disk

After emitting the chat summary, persist the same content to `./.shipyard/do-work/<YYYY-MM-DD>-do-work-session.html`. Mirrors the `/shipyard:audit` report-writer ([commands/audit.md](../audit.md) → "Write the consolidated report to disk") — `/shipyard:audit` writes to `.shipyard/audits/`, `/shipyard:do-work` writes to `.shipyard/do-work/`. Reports are styled HTML (not markdown) so the maintainer can read in a browser with badges, hover states, and clickable links.

**Skip the write when** `shipped_count + filed_count + reaped_worktrees == 0`, or when the user drained immediately after backlog overview without shipping anything.

1. **Create the directory:** `mkdir -p .shipyard/do-work`. Do NOT `git add` and do NOT amend `.gitignore`. The host repo decides whether to track `.shipyard/`.

2. **Ensure the shared stylesheet exists at `.shipyard/styles.css`.** Idempotent — only write when the file does not exist (`if [ ! -f .shipyard/styles.css ]`); never clobber a user-edited version. Full CSS template lives in [`commands/audit.md`](../audit.md) → "Write the consolidated report to disk" step 2 (canonical source). Reports reference it via `../styles.css`.

3. **Compute the target path.** Base name `<YYYY-MM-DD>-do-work-session.html` (local timezone); suffix `-2`, `-3`, etc. on same-day re-runs:

   ```bash
   base="$(date +%Y-%m-%d)-do-work-session"
   path=".shipyard/do-work/${base}.html"
   n=2
   while [ -e "$path" ]; do path=".shipyard/do-work/${base}-${n}.html"; n=$((n+1)); done
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
               <td><a class="issue" href="https://github.com/mattsears18/claude-plugins/issues/<n>"><span class="hash">#</span><n></a></td>
               <td><title></td>
               <td><span class="badge p1">P1</span></td>
             </tr>
           </tbody>
         </table>
         <p>(Gaps in the orchestrator itself surfaced by the session — filed against <code>mattsears18/claude-plugins</code> per the global memory rule.)</p>
       </section>

       <section>
         <h2>User-action follow-ups</h2>
         <ul>
           <li><thing that blocks full value-delivery and needs a human — Secret Manager values, Vercel env vars, blocked:ci PRs needing review, blocked-rebase PRs surfaced by the drain, manual-gate release PRs></li>
         </ul>
       </section>

       <section>
         <h2>End-of-session cleanup</h2>
         <ul>
           <li>Reaped this session: <reaped_worktrees> agent worktrees, <reaped_branches> [gone] branches</li>
           <li>Deferred (still-running PIDs): <deferred_live></li>
           <li>Reaped from prior sessions: <reaped_stale> stale worktrees; <deferred_stale> live-PID worktrees left for the owning Claude Code instance</li>
           <li>Final <code>git worktree list</code> shape: <n> worktrees (primary + orchestrator + <m> agent worktrees deferred)</li>
         </ul>
       </section>
     </main>
   </body>
   </html>
   ```

   Severity badges: pick the matching CSS class (`p0` / `p1` / `p2`). Final-state badges use `merged` (green), `open` (blue — for blocked:ci / pending), `closed` (purple — for abandoned). Same-day audit reports filed via `/shipyard:audit` are sibling-linkable at relative path `../audits/<YYYY-MM-DD>-shipyard-audit.html` if the session report wants to cross-reference them.

   Omit sections that have no content (e.g. zero diversions → drop the line; no cross-PR conflicts → drop the entire "Notable cross-PR conflicts" section; no shipyard improvement issues filed → drop that section entirely). Don't pad with empty rows — empty rows are noise. The shape is "everything the chat summary said, plus context the chat summary elided for brevity." Escape interpolated user-supplied text appropriately (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;` inside attributes) — issue titles are the most likely place to forget escaping.

5. **Surface the path in chat** as the last line of your reply so the user sees where it landed:

   > Report saved: `.shipyard/do-work/<filename>.html`

If the orchestrator's working directory isn't a git repo or `.shipyard/` can't be created (read-only filesystem, permissions), report the failure inline (`Report could not be saved: <reason>`) and continue — don't block the chat summary on it. The report is a side-effect, not a contract; the chat summary is the source of truth and runs unconditionally.
