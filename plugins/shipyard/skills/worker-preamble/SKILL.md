---
name: worker-preamble
description: Shared worktree-discipline + dispatch-contract preamble for every `/shipyard:do-work` worker mode (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch). Dispatch prompts in `commands/do-work.md` reference this skill instead of inlining the same ~600-char preamble five times — one source of truth for worktree isolation rules, return-contract scaffolding, and the `--label shipyard` requirement. Closes [#107](https://github.com/mattsears18/shipyard/issues/107).
---

# Worker preamble (every `/shipyard:do-work` mode)

The contract every dispatched worker — regardless of mode — operates under. The orchestrator's per-mode dispatch prompts in `commands/do-work.md` reference this skill by name (`shipyard:worker-preamble`) instead of repeating the language verbatim. Mode-specific rules (branch naming, return strings, scope-expansion rules) stay in the per-mode dispatch prompt and in the dispatched agent's per-mode file (`agents/issue-worker/<mode>.md` — loaded by the thin entry router `agents/issue-worker.md` from the `mode:` field). This file owns only the shared ground rules.

## Worktree discipline (load-bearing)

You are running inside an **isolated git worktree**. Your initial working directory is the worktree path; the user's primary checkout lives at a different path and is strictly off-limits.

Three rules, no exceptions:

1. **Never `cd` outside your worktree.** Your tools (Bash, Edit, Read, Write) inherit cwd from your worktree. The moment you `cd` to anything else — including the user's primary checkout path — subsequent git/gh commands operate on whatever git directory is at that path, which can silently corrupt the user's checkout.
2. **Never use `gh pr checkout <M>`.** That command resolves to the cwd at call time and switches whatever working tree is there. If your cwd has drifted (or the harness mis-set it), `gh pr checkout` will move the user's primary HEAD without warning. Always use `git fetch origin <branch>` followed by `git switch <branch>` — those operate on the cwd's git context predictably and won't escape it.
3. **Never `git switch` to the repo's default branch (`main` / `master` / etc.) when your work is done.** The global "switch back to main when local work is done" rule is for the user's *primary* checkout, not your isolated worktree. Parking your worktree on `[main]` locks the user's primary out of `git switch main` (git enforces one-worktree-per-branch). Leave your worktree on your work branch — the orchestrator's cleanup phase handles the rest.

## PR-creation contract

When opening a PR from any worker mode, every call **MUST** include:

```bash
gh pr create --repo <owner/repo> --label shipyard ...
```

The `shipyard` label is the orchestrator's session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it; omitting it makes the PR invisible to the orchestrator's own state machine. Add other mode-specific labels (e.g. `needs-human-review` for external-trust PRs) **alongside** `shipyard`, never as a replacement.

For issue-work mode the PR body MUST include `Closes #<N>` (case-insensitive, on its own line) so the issue auto-closes on merge. For synthetic diverts (fix-main-ci, fix-failing-prs-batch) there is no issue to close — omit the `Closes` line.

## Auto-merge + snapshot-and-return pattern

After `gh pr create` returns:

1. Arm auto-merge:
   ```bash
   gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
   ```
   If the call errors because auto-merge isn't enabled at the repo level, **don't try to enable it** — that's a repo-config decision. Capture the error to a local variable but proceed to step 1.5 below — the call's exit status alone is NOT a reliable signal of the actual merge outcome (see issue [#340](https://github.com/mattsears18/shipyard/issues/340)).

1.5. **Re-snapshot the PR's actual state before categorizing the auto-merge outcome.** Closes [#340](https://github.com/mattsears18/shipyard/issues/340) — `gh pr merge --auto` does NOT always error when `allow_auto_merge: false` is set at the repo level. When the dispatching user has admin permissions on a repo with auto-merge disabled, `gh` **silently falls through to a direct merge**: the PR lands immediately (if CI is green) or queues for merge (if pending). The call returns exit 0, `autoMergeRequest` is `null` because no auto-merge was armed, and a worker that decides the auto-merge outcome from the call's exit status alone returns `auto-merge: unavailable — needs manual merge` even when the PR is already `state: MERGED`. Repro: 5 PRs in a 26-PR session against `mattsears18/mattsears18.com` (`allow_auto_merge: false`) all returned `unavailable` despite landing as MERGED.

   The right check is to read both `state` and `autoMergeRequest` directly:

   ```bash
   gh pr view <pr-num> --repo <owner/repo> --json state,autoMergeRequest \
     --jq '{state, autoMerge: (.autoMergeRequest != null)}'
   ```

   Categorize into one of three `auto-merge:` values for the return-string suffix:
   - `.autoMerge == true` → **`auto-merge: enabled`** (queued; auto-merge armed and waiting on checks)
   - `.state == "MERGED"` → **`auto-merge: merged-direct`** (gh silently direct-merged because the repo has `allow_auto_merge: false` but the dispatching user has admin permissions; PR is already landed)
   - Otherwise (`.state == "OPEN"` AND `.autoMerge == false`) → **`auto-merge: unavailable — needs manual merge`** (the call genuinely failed and no merge happened)

   The `merged-direct` distinction is informational, not behavioral: the orchestrator's step A reconcile parses `shipped #<N> via PR #<M>` and the `(auto-merge: ..., checks: ...)` suffix is purely for human-readable summaries and friction-surfacing — but the distinction matters for end-of-session summaries (a `merged-direct` PR shouldn't be surfaced to the user as "needs manual merge" friction when it's already landed).

2. Snapshot the current check-rollup state with a single `gh pr view <M> --json statusCheckRollup,mergeStateStatus`. Don't `--watch` CI in any mode except **fix-checks-only**. The orchestrator's per-iteration PR triage owns failure recovery on a periodic refresh; blocking on `--watch` would tie up your agent and its concurrency slot for the full CI duration (often 5–20 min) for no gain. **Categorize the latest run per check name** (issue [#333](https://github.com/mattsears18/shipyard/issues/333) — `statusCheckRollup` returns every check run for the head SHA, including superseded runs; a stale FAILURE entry from an earlier run that's since been re-triggered and now passes would otherwise mis-categorize a `green` rollup as `failing`):

   ```bash
   gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus --jq '
     {mergeStateStatus: .mergeStateStatus,
      checks: [.statusCheckRollup
               | group_by(.name)
               | map(sort_by(.completedAt // .startedAt // "") | last)
               | .[] | {name, conclusion: (.conclusion // null), status: (.status // null)}]}'
   ```

   Then categorize the `checks` array:
   - All entries `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup, no checks configured) → `checks: green`.
   - Any entry `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → `checks: failing`.
   - Otherwise (`QUEUED` / `IN_PROGRESS` / `PENDING`) → `checks: pending` (the normal case right after push).

   The `group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last)` reduction is load-bearing — it collapses N entries per check name to 1 (the most recent), so a stale FAILURE entry that's been superseded by a later SUCCESS doesn't trip the `failing` categorization. The `(.conclusion // .status)` test pattern is what the orchestrator's reconcile path uses too; using it here keeps the worker's snapshot categorization and the orchestrator's trust-but-verify spot-check in sync.

   **Note:** if step 1.5 categorized as `merged-direct`, the PR is already on the default branch and the rollup snapshot reflects the post-merge head SHA's checks (typically all green by definition — the merge wouldn't have landed otherwise). The categorization above still applies; expect `checks: green` in the normal case.

3. Return one line in the mode-specific format the dispatching prompt specifies.

**Exception — fix-checks-only mode.** That mode is the one place you DO block on `gh pr checks <M> --watch --interval 30`, because resolving a known-failing PR is the agent's entire job. See `agents/issue-worker/fix-checks-only.md` for the full fix-loop semantics. Returning `green #<M>` from fix-checks-only mode is a load-bearing claim — the rollup must be fully `SUCCESS` at the moment of return, not "pushed and queued."

## Return-contract discipline

Every worker mode's last line is the orchestrator's only signal of outcome. The valid terminal strings are mode-specific (see the dispatching prompt for the exact set), but two universal rules apply:

- **No narrative status updates.** Strings like `"waiting for monitor"`, `"shard 2 still running"`, `"unit tests pass, awaiting E2E"`, `"routine progress"` are contract violations — the agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging stale state. Either return one of the documented terminal strings, or keep the foreground bash call alive (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism) until you have one to return.
- **`blocked: <reason>` is always available.** If you hit a real blocker before push (ambiguous scope, can't reproduce, conflict needs human judgment, 3-attempt fix-loop cap hit), return `blocked: <reason>` and exit. Don't burn the session on one issue.

## Heartbeat emission around long-running commands

The Claude Code harness runs a **stream watchdog** over each worker dispatch: if the worker emits no stream output (stdout/stderr) for ~600s, the harness concludes the agent has stalled, kills it, and the orchestrator gets back `status: failed / summary: Agent stalled: no progress for 600s (stream watchdog did not recover)`. The killed worker leaves an agent worktree behind for the next session's startup sweep to reap, and the failure path emits no `usage` block, so the burned tokens aren't attributed to any per-PR bucket (issue [#372](https://github.com/mattsears18/shipyard/issues/372) — observed in a `mattsears18/lightwork` drain-phase `fix-checks-worker` dispatch killed mid-`Web E2E Tests` shard).

The watchdog is correct for foregrounded LLM work — 600s of genuine silence from the model *is* a stall. It misfires on worker modes (especially **fix-checks-only**, which is the canonical victim because its whole job is babysitting CI) that shell out to commands which legitimately run for 5–15 minutes with **no intervening stream output**:

- `npm ci` / `npm install` against a cold cache,
- `gh run view <run-id> --log-failed > /tmp/log` (the redirect swallows all output — the watchdog sees zero stream bytes for the whole download),
- a test suite run that buffers output (`npm run test:e2e:web`, `npx lhci autorun`, `pytest -q`),
- `gh pr checks <M> --watch --interval 30` parked on a long E2E shard.

The watchdog keys on **stream output**, not on tool-call boundaries — a single Bash tool call that runs silently for 600s trips it even though the agent is making real progress. **The fix is to keep stream output flowing while a long-running command is in flight.** Three patterns, in order of preference:

1. **Don't redirect long-running command output to a file.** The single biggest offender is `... > /tmp/log` on a slow command — the redirect is exactly what starves the watchdog. Let the command stream to the terminal and `tee` if you also need the file:
   ```bash
   # BAD — silent for the whole download, trips the watchdog on a big failed-log fetch.
   gh run view "$run_id" --repo "$repo" --log-failed > /tmp/failed.log
   # GOOD — output streams to stdout (feeds the watchdog) AND lands in the file.
   gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tee /tmp/failed.log
   ```
2. **Prefer the streaming/progress form of the command.** `npm ci` already prints progress to stderr by default — do NOT silence it with `--silent` / `--quiet` / `> /dev/null` on the path where the watchdog is a risk. `gh pr checks <M> --watch --interval 30` emits a status table on every interval tick, so it self-heartbeats and never needs wrapping (this is why the fix-checks-only fix-loop is watchdog-safe as written). For a test runner that buffers, pass its line-reporter / non-quiet flag (`jest --verbose`, `pytest -v`, `vitest --reporter=verbose`) so each test result is a stream write.
3. **Wrap a genuinely-silent unavoidable command in a heartbeat loop.** When a command *must* run silently for minutes (a compile step with no progress output, a vendor CLI that only prints on completion), background it and emit a heartbeat line on an interval until it exits. The heartbeat lines are the stream output the watchdog needs:
   ```bash
   # Run the silent command in the background, emit a heartbeat every 60s until it finishes.
   slow_silent_command > /tmp/out.log 2>&1 &
   cmd_pid=$!
   while kill -0 "$cmd_pid" 2>/dev/null; do
     echo "[heartbeat] $(date -u +%H:%M:%S) — still running slow_silent_command (pid $cmd_pid)"
     sleep 60
   done
   wait "$cmd_pid"   # propagate the real exit status
   ```
   The `[heartbeat]` prefix is a convention, not a parsed sentinel — its only job is to be a stream write the watchdog can see. Keep the interval comfortably under the watchdog window (60s against a ~600s watchdog leaves a 10× margin); don't tighten it to the point of log spam.

**Scope.** This applies to *every* worker mode, but the high-risk surface is fix-checks-only (CI babysitting on E2E/Lighthouse-heavy repos) and fix-main-ci / fix-failing-prs-batch (which run the target repo's full test suite locally). issue-work workers usually checkpoint at natural tool-call boundaries often enough to self-heartbeat; the rule still applies if you run a long silent build or test step. **Do NOT** add busy-work `echo`s to *fast* commands — the heartbeat pattern is reserved for commands that can plausibly exceed the watchdog window with no natural output. Reflexive heartbeating everywhere is log noise that costs context tokens for no liveness benefit.

> **Not implementable from this repo: a tunable watchdog threshold.** Issue [#372](https://github.com/mattsears18/shipyard/issues/372) also floated a per-mode `stall_seconds` config knob (e.g. `workers.fix_checks_only.stall_seconds = 1200`). The 600s watchdog lives in the Claude Code **harness**, not in shipyard — shipyard can't read, raise, or disable it from a config file, so a config key would be an unenforceable no-op. The heartbeat contract above is the in-repo lever that actually moves the failure mode: it keeps the existing watchdog from firing rather than trying to change a threshold shipyard doesn't own.

## Stop background processes before returning

If your worker spawned anything that lives **outside** the foreground tool-call lifecycle — a `Monitor` sub-task watching CI, a `Bash` call with `run_in_background: true` (e.g. a long-tail `gh pr checks --watch` you backgrounded so you could keep working in parallel), a `TaskCreate` sub-Agent — **stop it explicitly before you emit your terminal return string**. These processes belong to your session's background pool, not your "main turn," so the harness does not auto-reap them when your final assistant message lands. Each one will keep firing notifications (`<result>Still waiting (check 8)...</result>`, `<result>All historical background tasks have completed...</result>`) for the rest of its internal max-runtime (Monitors: 15–60 min; backgrounded bash: until the command exits or the shell is killed), and **every notification re-invokes the orchestrator for a no-op turn** because the parent agent is the wake target for everything spawned underneath it. The lightwork session that filed [#297](https://github.com/mattsears18/shipyard/issues/297) accumulated 50+ stale wake events across two fix-checks-worker dispatches that left their Monitor sub-tasks running after returning.

Apply this rule on **every** termination path — clean `green` / `shipped` / `rebased` / `noop:` returns, `blocked: <reason>` bails, and even the `reaped: ...` escape hatch from the next section. The notification leak is independent of whether the worker succeeded; what matters is that the worker spawned something whose lifetime exceeds its turn.

Mechanism per tool family:

| What you spawned | How to stop it before returning |
|---|---|
| `Monitor` sub-task (any subscription) | `TaskStop` against the task id you got back from `TaskCreate` / `Monitor` |
| `Bash` with `run_in_background: true` | `KillShell` against the shell id from the background-call's response (or `BashOutput` if you need the final exit code first, then `KillShell`) |
| `TaskCreate` sub-Agent that's still running | `TaskStop` against its task id |
| Foreground `Bash` (no `run_in_background:`) — e.g. `gh pr checks <M> --watch` | **Nothing** — foreground bash blocks your turn until it exits, so it can't outlive the return |

If you never spawned any of the above, this section is a no-op — the foreground-only path (the default) is already clean. The rule is "if you spawned it, you stop it"; it is NOT "always call TaskStop defensively at the end of every dispatch."

If `TaskStop` / `KillShell` errors (the process already exited on its own, the id was wrong, etc.), log an advisory and continue — the goal is best-effort cleanup, not blocking your return on a stop call that races against a process that was already done.

## Worktree-reaped escape hatch

The orchestrator's end-of-session cleanup reaps `.claude/worktrees/agent-*` directories. It liveness-checks the lock-holding PID before reaping, but defense in depth: an agent whose worktree IS reaped mid-run must NOT silently fall through to operating in the primary checkout.

**Bash-tool isolation — the gotcha that makes the naïve pattern wrong.** Each `Bash` tool call spawns a fresh shell. Variables you set in one call (including `export`-ed ones) **do not survive** into the next call — the harness does not share shell state across invocations. A pattern that reads "save once at session start, check before each write" works fine in an interactive terminal but trips the very guard it's meant to enforce when run through the Bash tool: the first write-class call after some intervening read-only calls finds `$WORKTREE_PATH` empty, the `! -d ""` check is true, and the worker emits a false-positive `reaped:` exit on its first commit ([#322](https://github.com/mattsears18/shipyard/issues/322)).

**Re-derive `WORKTREE_PATH` at the top of every write-class Bash call.** One extra line per call, no cross-call state assumption. Apply before every `git commit`, `git push`, `gh pr create`, `gh pr merge`, `gh issue edit`, `gh pr edit`, `gh pr comment`, `gh issue comment`, and any other call that mutates the repo or the GitHub-side state:

```bash
# Top of every write-class Bash call — re-derive inside the call, don't rely on prior state.
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ ! -d "$WORKTREE_PATH" ] || [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --format='%H' 2>/dev/null | head -c 12)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi
# ... actual write call here, e.g.:
# git commit -m "..."
```

The re-derivation is cheap (a single `git rev-parse` against the cwd) and self-correcting: if your cwd is still inside the worktree, `WORKTREE_PATH` resolves to the same path the orchestrator handed you; if the worktree has been reaped, `git rev-parse` errors and `WORKTREE_PATH` is empty, which the `! -d "$WORKTREE_PATH"` check catches. The second arm of the OR (`git rev-parse --show-toplevel != $WORKTREE_PATH`) is the redundant-but-cheap belt to the suspenders — if `cd` ever drifted to a sibling worktree or the primary checkout, the toplevel won't match the just-derived path and the same `reaped:` bail fires.

**Why not "save once, reuse via `export`."** The Bash tool does not run your calls inside a persistent shell session — there's no parent process whose environment survives across tool-result boundaries. `export WORKTREE_PATH=...` in call N does not make `$WORKTREE_PATH` readable in call N+1. The same constraint applies to `set -o`, `cd`, shell aliases, and shopt — every Bash tool call is hermetic. Re-deriving at the top of each write-class call is the only pattern that holds across the tool's actual isolation semantics. (For read-only calls — `git log`, `gh issue view`, `gh pr list`, etc. — you can skip the guard; the cost of a misread is wasted tokens, not a corrupt write.)

The `reaped:` prefix is load-bearing and intentionally distinct from `blocked:`: the orchestrator's step A reconcile parses it as a **retryable** outcome — it re-enqueues the issue for a fresh dispatch rather than applying the `blocked:agent` label. The `blocked:` prefix is reserved for deterministic failures (ambiguous scope, cannot reproduce) where retrying would produce the same result; a mid-run reap is external-infrastructure noise, not a worker logic failure. Do NOT try to `cd` to a different worktree, recreate your worktree, or operate in the primary checkout — exit immediately.

## Incremental progress posting (investigation-heavy work)

For workers whose job involves a multi-step investigation before any commit lands (scope pre-flight analysis, diagnostic investigation, fix-checks root-cause search), a worktree reap mid-run destroys the findings before they can be communicated. To prevent silent value loss, **post investigation findings to the originating issue before attempting any git/gh write**:

```bash
# After reaching a diagnostic conclusion but BEFORE git commit / git push / gh pr create:
gh issue comment <N> --repo <owner/repo> --body "$(cat <<'EOF'
<!-- shipyard-worker-progress -->
**Investigation finding (pre-push):** <your diagnostic summary here — file paths, line numbers, root cause, rejected hypotheses>

This comment is posted before the final push so findings survive a mid-run worktree reap.
EOF
)"
```

**When to post a progress comment.** Post one if BOTH are true:
1. You have produced a concrete finding that isn't yet in the remote (uncommitted work, diagnostic conclusion, scope decision).
2. The finding would be permanently lost if your worktree were reaped in the next 30 seconds.

**What the comment should contain.** Exactly what the orchestrator would have had to transcribe manually if your run was interrupted: file paths, line numbers, rejected alternatives, root-cause hypothesis. Not a progress update ("working on it") — findings only.

**When NOT to post.** If you're about to push a commit that encodes the finding, the commit is the durable record — skip the comment. If the issue is a typo-fix and there are no intermediate findings, skip. The goal is to prevent loss, not to narrate every step.

The `<!-- shipyard-worker-progress -->` sentinel lets the orchestrator identify and summarize these comments without re-reading the entire thread.

## Dependency-bootstrap check for Node-based target repos

The Claude Code harness creates your agent worktree with `git worktree add` and nothing else — it does NOT install npm dependencies, does NOT symlink `node_modules` from the primary checkout, and does NOT run `npm ci`. For most target repos this is fine (Python, Go, plain shell, docs-only). For **Node-based target repos** it's a silent test-correctness gap, because:

- The repo's pre-push / pre-commit hooks usually shell out to locally-installed binaries via `node_modules/.bin/<tool>` (jest, prettier, eslint, firebase, etc.).
- When `node_modules/` is missing, those shell-outs hit `ENOENT` at the `execFileSync` level. A naive hook script that wraps the call in a try/catch and treats "no output" or "non-numeric exit status" as success will **silently pass** instead of failing loudly. The lightwork project's `scripts/test.js` does exactly this — `--passWithNoTests` semantics get applied to a missing-binary spawn-failure and the push proceeds with zero tests actually run. ([#316](https://github.com/mattsears18/shipyard/issues/316)).
- Net effect: your worker thinks it ran the project's test suite locally, when in fact it ran nothing. The code lands and CI catches the regression — except now you've burned an iteration on a problem your local-test discipline was supposed to catch.

**The check.** Before your first `git push`, if the target repo ships a `package.json` AND your worktree has no `node_modules/`, treat it as a setup-incomplete state — not a "this repo has no deps" state:

```bash
# Run this once near the top of step 4 (implement) — before you write code, before
# you run tests, definitely before you push.
if [ -f package.json ] && [ ! -d node_modules ]; then
  echo "worker-preamble: package.json present but node_modules missing — Node deps not bootstrapped" >&2
  # Try the cheap recovery paths in order. See remediation section below.
fi
```

The check is a one-liner; the remediation is the substantive part.

**Remediation, in order of preference:**

1. **Symlink from the primary checkout.** Cheapest, fastest, and works for almost all tooling (jest, eslint, prettier, firebase CLI). The primary checkout's `node_modules/` is at a deterministic path relative to your worktree — `.claude/worktrees/agent-<id>/` lives inside `<primary-checkout>/.claude/worktrees/`, so the primary's `node_modules` is exactly `../../../node_modules` from your worktree root:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     ln -s ../../../node_modules node_modules
     # Also add to the per-worktree exclude so the symlink can NEVER be
     # implicitly staged into a commit (issue #351 — see the "Pre-commit
     # hygiene" section below for the salvage cost when it leaks). The
     # per-worktree `.git/info/exclude` is the canonical git mechanism for
     # "ignore this in this checkout only" — it doesn't pollute the repo's
     # `.gitignore` (which would be a public spec change).
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```
   Native modules built against the host Node version need rebuild for native modules to load — acceptable trade-off since shipyard already requires the primary checkout to be on a compatible Node version. The symlink only persists for the worktree's lifetime; the orchestrator's reap doesn't touch the primary checkout's `node_modules/`.

   **Auto Mode constraint.** In Auto Mode the symlink step is typically denied by the auto-mode classifier with a message like: *"Symlinking the parent repo's `node_modules` into the worktree creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* If you are running under Auto Mode, **skip the symlink entirely and go directly to `npm ci` (path 2 below)** — attempting the `ln -s` first wastes one tool-call turn on a denial that is predictable. Observed in `/shipyard:do-work` session against `mattsears18/lightwork` on 2026-05-24 ([#328](https://github.com/mattsears18/shipyard/issues/328)).

   **Alternative — `cp -al` (hard-link copy).** A hard-link copy doesn't create a cross-directory writable link, so the auto-mode classifier should allow it. Same disk semantics as a symlink (files are not duplicated byte-for-byte), but each file is independently owned by the worktree. Caveat: hard links only work within the same filesystem, which is normally satisfied when the worktree and primary checkout share the same mount. Use as an alternative when `ln -s` is denied and `npm ci` is too slow:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     cp -al ../../../node_modules node_modules
     # Same gitignore-via-info/exclude hygiene as the symlink path — the
     # hard-link tree shouldn't leak into a commit either.
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```

2. **Fall back to `npm ci`.** Most correct, slowest (30–90s typical). Use when the symlink path doesn't exist (worktree was created somewhere unusual), when running under Auto Mode (see constraint above), or when a previous attempt with the symlink hit native-module loader errors:
   ```bash
   npm ci --no-audit --no-fund --prefer-offline
   ```

3. **Bail with `blocked:` if both paths fail.** Don't push a Node-repo change whose local tests didn't actually run — the silent-pass failure is exactly the gap this check exists to close. Return `blocked: cannot bootstrap node_modules — symlink target missing AND npm ci failed (<reason>)` and let the orchestrator pick a different issue.

**When NOT to run the check.** Don't run it for non-Node repos (no `package.json`), don't run it inside a sub-directory of a monorepo unless that sub-dir has its own `package.json` (the root's deps may satisfy the sub-dir's tooling), and don't run it for documentation-only changes to a Node repo (no tests to skip silently if your diff is `*.md` files).

**Why this lives in the preamble and not per-mode.** Every dispatched worker (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch) eventually runs `git push` against the target repo. The silent-test-skip failure mode is identical across modes. One check in the shared preamble beats five copy-pasted recipes in the per-mode files.

## Test-runner silent-pass when the target repo ignores worktree paths

A second silent-pass failure mode, distinct from the missing-`node_modules` case above ([#369](https://github.com/mattsears18/shipyard/issues/369)). Here `node_modules` is fully present and the binaries resolve fine — but the target repo's test config **ignores the worker's own worktree path**, so the runner silently skips every test the worker just wrote.

**Mechanism.** A repo that runs `/shipyard:do-work` against itself commonly adds `/.claude/worktrees/` to its test runner's path-ignore list (jest `testPathIgnorePatterns`, vitest `exclude`, pytest `norecursedirs`, mocha `--ignore`) so the **primary** checkout's test runner doesn't sweep into agent worktrees during local dev. That pattern is correct for the primary use case but **wrong** for the worker use case: when the worker (or its pre-push hook) runs the suite *from inside* `.claude/worktrees/agent-*/`, the runner computes the absolute path of every test file — which now begins with `.../.claude/worktrees/agent-*/...` — and the ignore pattern matches the worker's own files. The runner reports "No tests found" / "0 tests", the hook treats that as a pass, and the push proceeds with zero tests actually run. The lightwork repro: `jest.config.js` with `testPathIgnorePatterns: ['/node_modules/', '/functions/', '/.claude/worktrees/']` silently skipped a worker's new `__tests__/chunk-load-recovery.test.ts` while reporting code 0 (session `do-work-20260528T015557Z-14129`, [`lightwork#1362`](https://github.com/mattsears18/lightwork/pull/1362)).

**The signal.** When you run the target repo's test suite (or read your pre-push hook's output) and see a **zero-tests-found pass** — `No tests found`, `0 tests`, `0 passed`, `--passWithNoTests` firing — against a diff that **does** add or modify test files, do NOT treat it as a green local run. A zero-test pass on a test-touching diff is the silent-pass tell.

**The recovery, in order:**

1. **Re-run with the worktree-ignore entry stripped.** If the repo's config ignores `/.claude/worktrees/`, re-run the suite with the *other* ignore entries preserved but the worktree entry dropped, so the runner sees your worktree's tests. Jest takes repeatable `--testPathIgnorePatterns` flags that **replace** the config value, so pass the surviving entries explicitly:
   ```bash
   # jest: replace the config's ignore list, keeping everything EXCEPT /.claude/worktrees/
   npx jest --testPathIgnorePatterns='/node_modules/' --testPathIgnorePatterns='/functions/'
   ```
   The vitest / pytest / mocha equivalents differ (`vitest --exclude`, pytest `--override-ini`, mocha `--ignore`) — the principle is the same: override the config so the runner stops ignoring your own worktree. Confirm the re-run now reports a non-zero test count before trusting it.

2. **Bail loudly if you can't override.** If the runner has no clean override (or the override still reports zero tests), do NOT let the push ride the silent pass. Return:
   ```
   blocked: pre-push test runner silently passed — target repo's test config ignores worktree paths, local tests did not run
   ```
   This is option 3 from [#369](https://github.com/mattsears18/shipyard/issues/369): the smallest-signal response. It doesn't second-guess the target repo's config; it just refuses to launder a zero-test pass into a "tests pass locally" claim. CI will run the tests from a fresh (non-worktree) checkout, but bailing here saves the wasted iteration the orchestrator otherwise pays for.

**When NOT to worry about this.** Documentation-only diffs (no test files touched) legitimately produce a zero-test pass — that's not the failure mode. The tell is specifically a zero-test pass on a diff that *added or changed* test files. And the override (step 1) is only needed when the config actually ignores `/.claude/worktrees/`; most repos don't, and their runner finds your tests normally.

## Mirror new string constants into locale / parity files

A recurring, self-inflicted CI red ([#418](https://github.com/mattsears18/shipyard/issues/418)): you add a user-facing string to a centralized strings module (e.g. `lib/strings.ts`, `src/i18n/keys.ts`, a `messages.ts` constant bag), open the PR, and CI goes red on a **parity test** that asserts every string key has a matching entry in every locale file. The repo's local pre-push hook didn't catch it (the parity test isn't always wired into the pre-push suite), so the break only surfaces in CI — costing a fix-checks cycle to add the one missing key. Repro: a single `mattsears18/lightwork` session (`do-work-20260531T113301Z-98771`) tripped this 3× across PRs #1443 / #1444 / #1447 — each added a `Strings.*` leaf in `lib/strings.ts` but forgot the matching key in `locales/en.json`, reddening the repo's `i18n.test.ts` parity test.

**The class is general** even though the trigger is repo-specific: many repos lock down a "centralized strings ↔ locale-file parity" invariant with a test. The shapes vary —

- i18n locale parity: `locales/en.json`, `locales/*.json`, `lang/*.yml`, a `messages/` dir — the test asserts the key set matches across every locale.
- Enum / constant ↔ lookup-table parity: a string-constant enum whose every member must have a row in a display-name map, a color map, an icon map.
- Snapshot / fixture parity: a generated `*.snap` or golden fixture that enumerates the full key set.

**The check.** Before opening the PR, if your diff **adds a key to a centralized string / constant module**, grep for a parity or locale test (`i18n.test.*`, `*parity*`, `locales/`, `messages/`, `lang/`, a `*.snap` enumerating keys) and **mirror the new key into every file the test requires** — the locale JSON, the display-name map, the fixture — in the same PR. The cheapest signal is to run the repo's full test suite locally (not just the pre-push subset) once after adding a string; if a parity test reds, add the missing mirror entry before you push. When the repo ships only a stub / placeholder value convention for non-default locales (common — translators fill them in later), mirror the key with the default-locale value or the repo's documented placeholder, not a blank.

**When NOT to worry about this.** Diffs that don't touch a centralized string / constant module (pure logic, config, docs) can't trip a key-parity test — skip the check. And if the repo has no parity test (the grep comes up empty), there's nothing to mirror; don't invent locale files the repo doesn't have.

## Pre-commit hygiene — escape symlinks

A companion failure mode to the dependency-bootstrap symlink ([#351](https://github.com/mattsears18/shipyard/issues/351)): the worker creates `node_modules → ../../../node_modules` per the bootstrap rules above, then accidentally stages it into a commit via a stray `git add -A`, a misclick on `git add node_modules`, or path globbing that happens to include the symlink. The committed `120000` symlink mode rides into the commit and stays dangerous forever — when a downstream consumer cherry-picks the commit onto a different checkout depth, `../../../node_modules` resolves to a different (or non-existent) path. The salvage cost is a follow-up `fix(repo): remove stray node_modules symlink from cherry-pick` commit on the receiving end; the prevention cost is zero if you follow the symlink-creation hygiene above.

The `refuse-escape-symlink-commit.sh` hook (registered as PreToolUse → Bash in `hooks.json`) is the load-bearing enforcement. It refuses any Bash `git commit` invocation whose staged file set includes a symlink whose target either starts with `/` or contains a literal `..` path segment. The hook's stderr explains the failure mode and the fix; do NOT bypass it.

If you genuinely need to commit a symlink with `../` in the target (rare — and a strong signal to re-think the design), return `blocked:` so a human can decide. The hook intentionally has no bypass flag, paralleling the no-`--no-verify` rule for commit hooks.

## Never `--no-verify`

You are forbidden from passing `--no-verify`, `--no-gpg-sign`, `--no-commit-hooks`, or any other flag that bypasses commit hooks, even if you believe the hook failure is environmental, unrelated to your changes, or a false positive. If a pre-commit hook fails:

1. Try to fix the underlying cause within scope (your changes' code).
2. If the cause is outside scope, return `blocked: pre-commit hook <NAME> failed for reason <X>` so the orchestrator can decide.
3. NEVER bypass. Not even "just this once."

Same rule for `git push --no-verify`. Same rule for any hook-bypass flag. The plugin's `permissions.deny` block in `plugin.json` enforces this at the harness level, but the rule applies even if the deny pattern is somehow bypassed.

## After a classifier denial

Auto Mode (and other harness-side classifiers) sometimes deny a tool call — an Edit, a Write, a Bash, an `npm install`, a symlink — with a reason like *"...creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* The denial is a hard boundary enforced by the harness, not a suggestion you can argue past. The correct posture is to treat the denial as a deterministic failure for **this** dispatch and let a human decide whether to re-authorize, change the classifier policy, or redirect the work.

**Three behaviors you MUST NOT do after a denial, even when you believe the denial was wrong:**

1. **Do NOT post a comment to any public GitHub artifact** (issue comment, PR description, PR comment, PR review) that summarizes, reframes, paraphrases, fabricates, or explains the classifier's reasoning. Classifier denials are between the worker and the harness; surfacing them to public-facing channels creates a content-integrity attack surface — even when well-intentioned, a public-facing comment fabricating *why* the classifier denied something is a side-channel that a future worker, reviewer, or scraper could read as authoritative. The harness's classifier reasoning is not yours to relay.
2. **Do NOT attempt to file a follow-up issue arguing the denial was wrong.** "The classifier was overly strict, please relax the policy" is not a worker decision; it's a maintainer decision. If you genuinely believe a denial pattern is misclassified at the policy level, the right surface is `mattsears18/shipyard` issues filed by the *user* after they see your `blocked:` return, not a self-filed escalation from inside the dispatch.
3. **Do NOT retry the same denied call through a workaround** — a different tool, a renamed file, a Base64-encoded payload, a shell-out that produces the same effect via a different syscall, or any other "I'll just do it a different way" strategy. Classifier policy targets *effects*, not tool names; routing around the deny is treated as the same policy violation. If the first attempt was denied, the second through any synonym is denied too.

**The correct response to a classifier denial is one foreground call: return.**

> `blocked: classifier denied <one-line description of what was denied>`

That's it. No comment, no follow-up issue, no creative retry. The `blocked:` return is the orchestrator's signal that the dispatch hit a deterministic boundary; step A reconcile will tag the issue `blocked:agent` and the user can decide what to do next. The one-line description should name the operation (e.g., "Edit to .claude/settings.json", "symlink ../../../node_modules to ./node_modules", "npm install firebase-tools") so the maintainer can pattern-match the denial without reading the full transcript — but **do not include the classifier's prose reasoning** (paraphrased or verbatim) in the return string. The orchestrator captures it in the transcript record on its own.

**Why this is in the preamble.** A classifier-denial event is observably frustrating — the worker has a plan, sees the denial, and reaches for the next thing on the "ways to make this work" list. The next thing is often a content-integrity violation (posting to explain the denial) or a policy-bypass violation (retrying through a different surface). Both have been observed in the wild — issue [#341](https://github.com/mattsears18/shipyard/issues/341) documents a 2026-05-25 session where a worker attempted to post a fabricated explanation of the classifier's reasoning to a public GitHub issue after three denied Edit/Write attempts; the second-order classifier caught the comment-post too, so no harmful content landed, but the *intent* to escalate is the gap. This section closes that gap by naming the failure mode up front so the worker doesn't have to derive the correct response under the cognitive load of a denial.

## `gh` JSON discipline

Every `gh` call whose output you'll read MUST scope the response to the fields you actually consume. The default output is ~30 fields per issue / ~50 fields per PR — most of which the worker never reads. Each unused field is wasted tool-result tokens that ride in your context for the rest of the session.

The rule applies to **every read-shape `gh` subcommand**:

- `gh issue view / list`, `gh pr view / list`, `gh run list / view` — pass `--json <fields>`. Pick the smallest field set that satisfies the immediate read.
- `gh api <path>` — pass `--jq '<expr>'` to project the response inline. Same effect as piping to `jq`, one less subprocess.
- `gh repo view` — pass `--json <fields> -q <expr>` when reading (e.g. `--json defaultBranchRef -q .defaultBranchRef.name`).

Mutation-shape subcommands — `gh issue close`, `gh issue comment`, `gh issue edit`, `gh pr comment`, `gh pr edit`, `gh pr merge`, `gh pr create`, `gh label create` — are exempt: their output is small (usually empty or a single URL on success) and there's no field to scope.

**Two patterns, in increasing terseness:**

```bash
# Good — field-scoped, jq projection done client-side after the call returns.
gh pr view 142 --repo <owner/repo> --json statusCheckRollup,mergeStateStatus
# (your jq runs against the small JSON returned)

# Better — field-scoped AND inline-projected, so the response itself is already the shape you want.
gh pr view 142 --repo <owner/repo> \
  --json statusCheckRollup,mergeStateStatus \
  -q '{mergeable: .mergeStateStatus, checks: [.statusCheckRollup[] | {name, conclusion}]}'
```

Prefer the inline `-q` form when the projection is a stable shape. Drop to the field-scoped-only form when the caller does multiple independent projections on the same response (worth the extra fields to avoid a second `gh` round-trip).

**Common projections worth remembering:**

| Need | Pattern |
|---|---|
| PR's check rollup (pass/fail/pending) | `gh pr view <M> --json statusCheckRollup,mergeStateStatus` |
| PR's head branch (for `git switch`) | `gh pr view <M> --json headRefName -q .headRefName` |
| Default branch | `gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name` |
| Issue body + labels + comments (issue-work step 0) | `gh issue view <N> --json state,assignees,labels,body,title,comments,author` |
| List PRs awaiting review with status fields | `gh pr list --json number,title,statusCheckRollup,mergeStateStatus,headRefName,labels` |
| Count something via gh + jq | `... --json number --jq 'length'` (NOT `... --json number | jq 'length'`) |

**Don't go default-mode.** A bare `gh issue list` / `gh pr list` / `gh pr view` (no `--json`) returns the full default projection in human-readable form — fine for an interactive terminal, expensive when piped into agent context. The rule applies even for "I just need to know if it exists" — use `--json number --jq 'length'` (or `--json id -q .id`) and let the response be a single integer / string.

**Don't pipe `gh ... --json` into a separate `jq`** when `--jq` (the gh-internal flag) would do the same projection. The piped form forks a second process and serializes the full JSON across a pipe before jq filters it; `--jq` filters server-side on the gh-CLI side of the boundary, so the agent's stdout block already arrives projected. The token savings are downstream of that — a smaller stdout block carries fewer tokens into the next tool-result. (Two-step pipes are still fine when you need `jq` features `gh --jq` doesn't expose — `--slurp`, multi-input, advanced output formatting.)

## What this skill does NOT cover

Mode-specific scope intentionally lives in the per-mode dispatch prompt and the agent's own spec:

- **Branch naming** (`do-work/issue-<N>`, `do-work/fix-main-ci-<short-sha>`, `do-work/fix-pr-pileup-<timestamp>`, or the PR's existing head branch for fix-checks/fix-rebase) — set by the dispatching prompt.
- **Return-string vocabulary** (`shipped #<N> via PR #<M>`, `green #<M>`, `rebased #<M>`, `shipped main-ci-fix via PR #<M>`, etc.) — set by the dispatching prompt and validated by the orchestrator's step A reconcile.
- **Fix-loop attempt caps** (3 for fix-checks-only, 1 for fix-rebase, 1 for fix-main-ci / fix-failing-prs-batch) — set in each per-mode file under `agents/issue-worker/`.
- **Trivial-conflict-or-bail policy** for fix-rebase — set in `agents/issue-worker/fix-rebase.md`.
- **Author-trust → auto-merge gating** for issue-work — passed through as `originating_author_trust` in the dispatching prompt and consumed by `agents/issue-worker/issue-work.md`'s step 6.

When in doubt, the per-mode prompt overrides this skill where they disagree — but the rules above are deliberately universal and shouldn't conflict.
