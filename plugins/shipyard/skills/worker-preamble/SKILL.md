---
name: worker-preamble
description: Shared worktree-discipline + dispatch-contract preamble for every `/shipyard:do-work` worker mode (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate). Dispatch prompts in `commands/do-work.md` reference this skill instead of inlining the same preamble per mode — one source of truth for worktree isolation rules, return-contract scaffolding, and the `--label shipyard` requirement. This thin core keeps the universally-needed hot rules; rarely-hit reference material lives in on-demand fragments alongside this file. Closes [#107](https://github.com/mattsears18/shipyard/issues/107), split into core + fragments by [#617](https://github.com/mattsears18/shipyard/issues/617).
---

# Worker preamble (every `/shipyard:do-work` mode)

The contract every dispatched worker — regardless of mode — operates under. The orchestrator's per-mode dispatch prompts in `commands/do-work.md` reference this skill by name (`shipyard:worker-preamble`) instead of repeating the language verbatim. Mode-specific rules (branch naming, return strings, scope-expansion rules) stay in the per-mode dispatch prompt and in the dispatched agent's per-mode file (`agents/issue-worker/<mode>.md` — loaded by the thin entry router `agents/issue-worker.md` from the `mode:` field). This file owns only the shared ground rules.

**This `SKILL.md` is a thin always-loaded core.** It carries the rules every worker mode needs on every dispatch: worktree-isolation discipline, the broad-process-kill prohibition, the step-0 cwd fail-fast, the mid-session cwd anchoring rule, the `--label shipyard` PR-creation contract, the return-contract scaffolding, the background-process-cleanup rule, the `--no-verify` prohibition, and the one-sentence `gh` JSON discipline rule. The rarely-hit reference material — the auto-merge / snapshot categorization, the worktree-reaped escape hatch, the Node dependency-bootstrap and hook/test silent-pass guards, the CI/push pitfalls, the escape-symlink commit hygiene, the classifier-denial posture, the native background-subagent auto-PR reconciliation, and the `gh` JSON field-scoping cookbook — lives in **on-demand fragments** in this same directory, loaded only by the worker modes that need them. See [On-demand fragments](#on-demand-fragments) below for the index. The split (issue [#617](https://github.com/mattsears18/shipyard/issues/617), extended to these three sections by [#808](https://github.com/mattsears18/shipyard/issues/808)) preserves every rule's semantics and reachability — it only changes whether a rule is loaded eagerly (here) or on demand (a fragment) — so no worker mode loses access to a rule it relies on.

## Worktree discipline (load-bearing)

You belong to an **isolated git worktree**. The user's primary checkout lives at a different path and is strictly off-limits.

**Rule 0 — anchor to your worktree before anything else ([#791](https://github.com/mattsears18/shipyard/issues/791)).** Your cwd is **not** guaranteed to start there. `/shipyard:do-work` dispatches every `mode:`-driven worker through the **`Workflow` substrate**, whose `agent()` primitive has no isolation option — so the orchestrator pre-provisions your worktree with `git worktree add` and your dispatch prompt's **first instruction is an explicit `cd` into that path**, followed by the [step-0 fail-fast verification](#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) below. Run that anchor block verbatim, before any other tool call, and stop if it reports `blocked:`. Two consequences:

- If your prompt names a worktree path, `cd` there **first** — the "never `cd`" rule below governs every move *after* the anchor, never the anchor itself.
- If your prompt is a `Workflow` dispatch that names **no** worktree path, that is a caller bug, not something to work around: return `blocked` with stage `worktree-anchor` rather than operating from an unpinned cwd. (An `Agent`-tool dispatch carrying `isolation: "worktree"` — how `shipyard:verify-worker` is still dispatched — arrives already cwd-pinned by the harness, so there is nothing to anchor; the step-0 verification still applies.)

Then three rules, no exceptions:

1. **Never `cd` outside your worktree** once anchored. Your tools (Bash, Edit, Read, Write) inherit cwd from your worktree. The moment you `cd` to anything else — including the user's primary checkout path — subsequent git/gh commands operate on whatever git directory is at that path, which can silently corrupt the user's checkout.
2. **Never use `gh pr checkout <M>`.** That command resolves to the cwd at call time and switches whatever working tree is there. If your cwd has drifted (or the harness mis-set it), `gh pr checkout` will move the user's primary HEAD without warning. Always use `git fetch origin <branch>` followed by `git switch <branch>` — those operate on the cwd's git context predictably and won't escape it.
3. **Never `git switch` to the repo's default branch (`main` / `master` / etc.) when your work is done.** The global "switch back to main when local work is done" rule is for the user's *primary* checkout, not your isolated worktree. Parking your worktree on `[main]` locks the user's primary out of `git switch main` (git enforces one-worktree-per-branch). Leave your worktree on your work branch — the orchestrator's cleanup phase handles the rest.

## Never run a broad process kill ([#751](https://github.com/mattsears18/shipyard/issues/751))

**Never run `pkill`, `killall`, `kill -9` against a name/pattern, or any "kill everything matching X" command.** A pattern-based kill cannot distinguish "processes I spawned this session" from "processes something else on this host spawned" — and on a repo whose CI runs on **self-hosted runners installed on the same physical host you're working on**, that "something else" can be an in-flight CI run. The worker's own Playwright/Metro/emulator processes and the runner's CI processes run as the same user, on the same host, often from paths under the same repo root, with identical names — so a pattern match hits both indiscriminately. Killing CI this way is a silent violation of the "never cancel an in-progress CI run" operating principle: the worker never touches a CI surface, never sees a cancellation notice, and has no way to know it just destroyed a run — possibly a *different* PR's, or `main`'s.

The failure mode is fully reproduced, not hypothetical: a worker ran `pkill -9 -f "playwright test"` during local cleanup on a repo running three self-hosted macOS runners on the maintainer's own Mac. The pattern matched the runner's in-flight CI processes and killed two E2E shards of the very PR the worker was trying to get green (issue [#751](https://github.com/mattsears18/shipyard/issues/751)).

**Track the PID of any process you spawn yourself, and kill only that PID** — `kill <pid>` (or `kill -9 <pid>`), never a name/pattern match. If you cannot establish that a PID belongs to a process you spawned this session, leave it alone and note the leftover process in your return string rather than guessing.

**A cheap check tells you whether this host is also a CI executor** — worth running before any local process cleanup if you're unsure:

```bash
# Signal 1: the repo has self-hosted runners registered at all.
gh api "repos/<owner>/<repo>/actions/runners" --jq '.total_count' 2>/dev/null

# Signal 2: a runner agent installed under this user's home directory — the
# strongest local signal that THIS host executes CI.
find "$HOME" -maxdepth 3 \( -iname 'actions-runner*' -o -iname 'runner-homes' \) 2>/dev/null | head -1
```

If either signal is non-empty/non-zero, treat every process on the host as potentially CI's, not just your own, and never reach for a pattern-based kill.

**This is mechanically enforced, not just documented.** The `refuse-broad-process-kill.sh` `PreToolUse` hook blocks any `Bash` call containing `pkill`, `killall`, or a `kill` invocation fed PIDs from a pattern lookup (`kill $(pgrep ...)`, `kill $(ps ... | grep ...)`) — the same "stick vs carrot" pairing `enforce-worktree-isolation.sh` and `enforce-edit-scope.sh` already use for their respective prose rules. There is no bypass flag; if you genuinely need to end a process you can't isolate to a known PID, return `blocked:` rather than routing around the hook.

## Step-0 cwd fail-fast — assert you're actually in your worktree ([#486](https://github.com/mattsears18/shipyard/issues/486))

The three rules above assume your working directory **is** the isolated worktree. Neither dispatch shape guarantees that on its own: under the `Workflow` substrate your cwd starts wherever the runtime left it and only Rule 0's `cd` puts you in the worktree (a `cd` can silently land somewhere unexpected — a stale path, a reaped directory); under an `Agent`-tool `isolation: "worktree"` dispatch the cwd is set by the **Claude Code harness**, not by shipyard, and can land **pinned to the PRIMARY checkout root** instead of the created worktree. When either happens, every git-mutating command you run targets the user's primary checkout, and on any repo with the global `enforce-worktree.sh` PreToolUse hook installed (the exact environment shipyard's worktree-isolation contract assumes) the hook hard-blocks your `git commit` as *"targets the PRIMARY checkout."* **The verification below is the same either way — run it once, first thing, in every mode and under either shape.**

**This is the [#486](https://github.com/mattsears18/shipyard/issues/486) failure mode, and it is catastrophic when undetected:** the worker runs the *entire* task — implements the fix, validates it, stages the diff — and only dies at the **final `git commit`**, after burning its whole run (the #486 repro: ~94 min of Opus on a single dispatch). The orchestrator can't rescue the staged work either (its own session may share the mispinned cwd; `EnterWorktree` refuses a subagent cwd override), so the validated work is recoverable only by a human-run commit out-of-band.

**Why shipyard can't fix the root cause.** The cwd is set by the harness's dispatch machinery, not by anything in this repo — shipyard cannot force an `isolation: "worktree"` dispatch's process cwd to the created worktree, nor pin the orchestrator session's cwd to its `orchestrator-<session-id>` worktree. Those are AC items (1) and (2) of [#486](https://github.com/mattsears18/shipyard/issues/486), and they are **harness-level, out of shipyard's control**. (The `Workflow` substrate has the mirror-image problem — no isolation primitive at all — which shipyard *does* close, by pre-provisioning the worktree orchestrator-side and making Rule 0's `cd` the worker's first instruction. The verification below is what proves that `cd` landed.) The in-repo mitigation is the same in both cases: **fail fast at step 0** so a mispinned dispatch returns immediately instead of after a full wasted run — this guard, plus a regression test, are the shipyard-implementable slice.

**The check — run these as three separate, plain `Bash` calls, not one compound script ([#802](https://github.com/mattsears18/shipyard/issues/802)).** The worktree-isolation guard refuses a single call built from command substitutions, `cd` subshells, and an inline `if` — exactly the shape a one-shot version of this check takes, and exactly the shape this section used to prescribe. Issue each command below as its **own** `Bash` tool call; do not paste them together and chain them with `&&`, a subshell, or an `if` — that compound shape is what gets refused:

```bash
git rev-parse --show-toplevel
```

```bash
git rev-parse --git-dir
```

```bash
git rev-parse --git-common-dir
```

Call the three outputs `TOPLEVEL`, `GIT_DIR`, and `COMMON_DIR` in your own reasoning — there's no shell variable to assign, since each call is independent. **Compare `GIT_DIR` and `COMMON_DIR` yourself, by reading the two outputs — don't script the comparison.** A linked worktree has a *separate* per-worktree git dir (`<common>/worktrees/<name>`) distinct from the common dir, so the two outputs differ there. The PRIMARY checkout has git-dir == git-common-dir (both resolve to the same `.git`) — that equality is the load-bearing signal: true **only** for a primary checkout and false for every linked worktree, regardless of where under the tree the cwd sits, so it catches the mispin without hard-coding the primary's absolute path or assuming a `.claude/worktrees/` layout.

If `GIT_DIR` and `COMMON_DIR` are the same path, this cwd is a primary checkout, NOT an isolated worktree — the dispatch-isolation cwd override is wrong. Stop here and return, verbatim (substituting your actual `TOPLEVEL`):

> `blocked: dispatch-isolation cwd override is wrong — my cwd (<TOPLEVEL>) is a PRIMARY checkout, not an isolated worktree. An isolation: "worktree" dispatch was pinned to the primary checkout root (see #486). Every git-mutating command here would target the user's primary checkout and the enforce-worktree hook will block my final commit. Failing fast at step 0 instead of burning the full run. Re-dispatch required.`

If `GIT_DIR` and `COMMON_DIR` differ, this cwd is a correctly-isolated worktree — proceed with the dispatch normally; the check is a no-op on the healthy path.

**Return `blocked:`, not `reaped:`.** The mispin is a deterministic property of *this* dispatch's cwd — re-running the identical dispatch could land the same wrong cwd, so it is not the retryable-infrastructure-noise case `reaped:` is reserved for. `blocked:` is correct: the orchestrator's reconcile classifies it as a refuse and applies `needs-human-review` (per [#521](https://github.com/mattsears18/shipyard/issues/521)), surfacing the harness-level misroute for a human (or a future harness fix) rather than silently re-enqueueing a dispatch that may misfire the same way. **This guard runs in every worker mode** — the catastrophic-wasted-run failure mode is identical whether the dispatch was issue-work, fix-checks-only, fix-rebase, fix-main-ci, or fix-failing-prs-batch, so it lives in the shared preamble rather than per-mode.

**When NOT to fire.** A correctly-pinned dispatch (cwd under `.claude/worktrees/agent-*` or `orchestrator-*`) has git-dir ≠ git-common-dir and sails through — the guard is a no-op on the normal path, three cheap `git rev-parse` reads. Running outside any orchestrated session (a human invoking a worker spec by hand in the primary checkout for testing) would trip it, which is correct: a worker spec is not meant to mutate the primary checkout.

## Mid-session cwd anchoring — the step-0 check is not a per-call guarantee ([#748](https://github.com/mattsears18/shipyard/issues/748))

The step-0 fail-fast above only asserts your cwd is correct **once, at the start of the dispatch**. [#748](https://github.com/mattsears18/shipyard/issues/748) found a narrower, recurring variant of the same failure mode: in a session where step-0 passed cleanly, plain relative-path `Bash` calls **later in the same dispatch** intermittently executed against the PRIMARY checkout instead of the worktree — with no `cd` ever issued by the worker. `pwd` and `git rev-parse --show-toplevel`, when explicitly queried, always correctly reported the worktree; the drift was invisible to those checks and only showed up as inconsistent *output* from ordinary relative-path commands (a test run alternating between the edited file's result and the original file's, mid-session, across separate `Bash` calls). If you see something that looks like a stale file or a phantom regression — an assertion count, a diff, a file's contents that don't match what you just edited — suspect cwd drift before assuming a code bug; the #748 repro burned real session time chasing the flip as test flakiness before finding the cause.

**Why shipyard can't fix the root cause.** This is the Bash tool's own cwd-persistence contract (documented as "cwd persists between calls") not holding for a subset of calls within a single `isolation: "worktree"` dispatch — the same class of harness-level gap as [#486](https://github.com/mattsears18/shipyard/issues/486)'s AC items 1/2. Shipyard's mitigation is defensive anchoring in the worker's own commands, not a fix for the underlying drift.

**Mandatory — anchor every mutating command to an explicit, re-verified worktree path.** Cache `WORKTREE_PATH` once your cwd is confirmed valid (step-0, or the reaped-escape-hatch re-derivation), then re-derive **and** re-verify it immediately before any `git add` / `git commit` / `git push`, any `gh` mutation whose scope depends on local git state (`gh pr create` and similar), or any file-destructive operation (`rm`, `mv`, an overwrite by relative or absolute path) — never trust a bare relative-path command in that slot to still be anchored to the worktree, even if it was moments ago. **Run each step below as its own plain, separate `Bash` call** — do not chain them with `&&`, a subshell, or an inline `if`; that compound shape is what the worktree-isolation guard refuses ([#802](https://github.com/mattsears18/shipyard/issues/802)). Shell variables also don't survive across separate `Bash` calls, so substitute the literal value each call returns into the next rather than trusting a live shell variable to carry over — the `$WORKTREE_PATH` notation below is documentation shorthand for "the literal path the first call returned," not a variable that persists:

```bash
git rev-parse --show-toplevel
```

That output is your `WORKTREE_PATH`. Re-verify it hasn't drifted, using that literal path in place of `$WORKTREE_PATH`:

```bash
git -C "$WORKTREE_PATH" rev-parse --git-dir
```

```bash
git -C "$WORKTREE_PATH" rev-parse --git-common-dir
```

Compare the two outputs by inspection, exactly as in step-0. If they're the same path (or `WORKTREE_PATH` came back empty), your cwd anchor has drifted mid-session — stop and return, verbatim:

> `blocked: cwd anchor drifted mid-session — my cwd is no longer the isolated worktree immediately before a mutating command (see #748). Refusing to run it against a possibly-wrong git context.`

If they differ, the anchor holds — proceed, anchoring explicitly rather than relying on ambient cwd:

```bash
git -C "$WORKTREE_PATH" add <specific paths>
git -C "$WORKTREE_PATH" commit -m "..."
git -C "$WORKTREE_PATH" push -u origin <branch>
```

(Each line above is also its own plain, single-purpose `Bash` call — none of them chain, subshell, or branch, so none trip the guard.)

For `gh` subcommands that don't take a `-C`-equivalent local-path flag (most accept `--repo <owner/repo>` for the *remote* target, but still read local git state relative to cwd — e.g. to resolve the current branch for `gh pr create`), wrap the call in an explicit `cd "$WORKTREE_PATH" && gh ...` rather than issuing it bare. This is the same re-derive-before-write discipline `shipyard:worker-preamble` § "Worktree-reaped escape hatch" already applies before every git/gh write (fragment [`reaped-escape-hatch.md`](./reaped-escape-hatch.md)) — this section generalizes it from "is my worktree still there" to "is my cwd still anchored to it," and makes the anchoring itself explicit (`-C`/absolute-path) rather than trusting the ambient cwd even after re-verifying it.

**Recommended, not mandatory — anchor read-only commands too when practical.** A misrouted *read* (a stale test run, a `wc -l` against the wrong copy) can't corrupt anything, but it can burn your whole diagnostic budget chasing a phantom bug, as #748's repro did. Prefer `git -C "$WORKTREE_PATH" diff`, absolute paths for file reads, and explicit `cd "$WORKTREE_PATH" &&` prefixes on test-runner invocations where it's cheap to do so — but don't block progress re-deriving and re-verifying before every single read the way the mandatory check above does before a write.

**Why the mandatory/recommended split.** A misrouted read-only call wastes time and is recoverable — re-run it. A misrouted mutating call against the user's primary checkout is silent, irreversible corruption of their real working tree, and nothing else in the stack catches it: the `enforce-worktree.sh` PreToolUse hook that blocks a `git commit` targeting the PRIMARY checkout only fires when the hook's own cwd detection is itself correct, which is exactly the assumption #748 shows can intermittently fail. Re-verifying immediately before every mutating call is cheap insurance against an outcome that has no undo.

## PR-creation contract

When opening a PR from any worker mode, every call **MUST** include:

```bash
gh pr create --repo <owner/repo> --label shipyard ...
```

The `shipyard` label is the orchestrator's session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it; omitting it makes the PR invisible to the orchestrator's own state machine. Add other mode-specific labels (e.g. `needs-human-review` for external-trust PRs) **alongside** `shipyard`, never as a replacement.

For issue-work mode the PR body MUST include a **closing keyword** — `Closes #<N>` (or `Fixes`/`Resolves #<N>`), case-insensitive, on its own line — so the issue auto-closes on merge. A **bare reference** (`Refs #<N>`, `Related to #<N>`, plain `#<N>`) does NOT register a closing link and leaves the issue OPEN forever after merge; the bare forms are reserved for *additional, non-resolving* issue mentions only. Repo-local "don't auto-close" conventions govern incidental references — they do NOT exempt the dispatched issue's resolving PR, which is the intended-close case (see `agents/issue-worker/issue-work.md` § "5. Commit + push + PR" and § "5.8 Post-PR-create closing-link verification" — issue [#481](https://github.com/mattsears18/shipyard/issues/481)). For synthetic diverts (fix-main-ci, fix-failing-prs-batch) there is no issue to close — omit the `Closes` line.

**After `gh pr create` returns**, arm auto-merge and snapshot the check/merge state per the **[`auto-merge.md`](./auto-merge.md)** fragment (`worker-preamble § "Auto-merge + snapshot-and-return pattern"`). That fragment carries the ungated admin-direct-merge pre-check, the `enabled` / `gated-manual` / `merged-direct` / `merged-direct-ungated` / `unavailable` categorization, and the no-`--watch` rule (with its two exceptions). `gated-manual` and `merged-direct` are NOT interchangeable even though both can leave a PR at `state: MERGED` with no armed queue — `gated-manual` is the worker's own checks-watch-then-merge (the correct outcome on an ungated repo shape); `merged-direct` is `gh pr merge --auto` silently falling through to an immediate merge (a detector misprediction). Conflating them erases a regression signal (issue [#734](https://github.com/mattsears18/shipyard/issues/734)). Load the fragment before opening a PR.

## Return-contract discipline

Your return is the orchestrator's only signal of outcome. **Return the shape your dispatch asks for ([#791](https://github.com/mattsears18/shipyard/issues/791)):**

- **A `Workflow`-substrate dispatch (every `mode:`-driven worker) asks for a STRUCTURED result** validated against [`schemas/worker-return.schema.json`](../../schemas/worker-return.schema.json) — `{mode, outcome, issue, pr, auto_merge, checks, disposition, blocked_reason, blocked_stage, last_push, summary}`. Your prompt states the required shape; validation happens at the stage boundary, so a malformed or ambiguous return **fails loudly there** instead of being re-parsed from prose. The per-mode file's terminal strings are the *vocabulary* your structured fields encode (`shipped` / `green` / `rebased` / `noop` / `blocked` / `reaped` / `disposition`, plus the same qualifiers the free-text suffixes carry) — the orchestrator translates them back into that free-text vocabulary before reconcile, so the two are 1:1. Read the per-mode file for which outcomes are legal in your mode; read your prompt for the exact field shape.
- **A plain-prose dispatch asks for the free-text terminal string** the per-mode file documents (`shipped #<N> via PR #<M> (auto-merge: …, checks: …)`, `blocked: <reason>`, `reaped: …`). This is what `shipyard:verify-worker` and hand dispatches of a mode shim use.

Either way, **the terminal return must be your last message, must be terminal, and must map onto one of your mode's documented outcomes.** These five universal rules apply to both shapes:

- **Run all work synchronously to a terminal state — NEVER arm a background process and return ([#529](https://github.com/mattsears18/shipyard/issues/529)).** **You are forbidden from suspending yourself awaiting a `Monitor` / background-process notification for any result you need in order to finish ([#813](https://github.com/mattsears18/shipyard/issues/813)).** Backgrounding is for work you will not wait on — anything you DO need the result of before you can commit, push, or return must run in the **foreground**. Concretely: you must NOT arm a `Bash` call with `run_in_background: true`, a `Monitor` sub-task, a `TaskCreate` background-waiter, or any other process that resolves *after* your turn ends, and then return before it resolves. Doing so is a contract violation with a specific, costly failure mode: the harness treats the assistant message ending your turn as a `status: completed` **even though the work is not done** — no commit, no pushed branch, no PR, a half-finished edit set — so the orchestrator records the dispatch as complete while the actual work is stranded mid-flight, and **the notification you were waiting for can never arrive** (the harness only re-wakes a task that has a *live foreground* call outstanding; a task that went idle waiting on a background child has already ended). The orchestrator's crash-aware reap + re-dispatch (A.0.5) recovers it, but at the full token cost of a wasted dispatch. Two confirmed repros, same shape: the #529 repro burned ~145k tokens for zero output (a worker armed a background test-waiter against #522 and returned *"I have a background waiter armed … I'll wait for that notification"* — a non-terminal narrative — leaving #522 OPEN with no PR and 0 commits in its worktree); the #813 repro burned ~331k tokens on a worker that finished a *complete and correct* working tree (one `git commit` away from shipping) and then returned *"I'm now waiting for the Monitor task to notify me that the full test suite … has completed. Once it reports green, I'll proceed to: 1. Remove the scratch … 2. Stage and commit … 3. Push … 4. Open a PR …"* — a numbered future-tense plan describing work it never did, because the wait it was describing could never resolve. If you need to wait on a long-running command (a test suite, CI), **block your own turn on a foreground call** (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism; see `worker-preamble § "Heartbeat emission around long-running commands"` in [`ci-pitfalls.md`](./ci-pitfalls.md) for keeping a silent foreground command watchdog-safe) until you have a terminal string to return. The terminal string is emitted *after* the work reaches its real end state, never *instead of* finishing it. (This composes with — but is distinct from — the "Stop background processes before returning" section below: that section covers cleaning up a process you legitimately spawned mid-turn; this rule forbids using a backgrounded process *as your wait mechanism* and returning a non-terminal narrative in its place.)
- **Don't open your own `Monitor`/poll loop to watch CI to completion instead of returning ([#753](https://github.com/mattsears18/shipyard/issues/753)).** Watching a PR's or `main`'s CI run through to a terminal state is the **orchestrator's** job — its per-iteration PR triage and main-CI watch already reconcile every open PR far more cheaply than a per-worker loop. Once you've pushed your change (and armed auto-merge, where the mode calls for it), **return the mode's terminal string immediately** from a one-shot snapshot — do NOT start a `Monitor` sub-task, background a `gh run watch` / `gh pr checks --watch`, or otherwise build a poll loop to sit and wait for CI to settle before returning. The #753 repro is the concrete anti-pattern to avoid: a `fix-main-ci` worker re-ran main's failed jobs, then spun up *"a clean Monitor polling the CI rerun every 60s"* and sat there for ~300k tokens across two re-fires without ever returning a terminal string; a separate issue-work worker rebased, pushed, and returned *"CI is still running … the background waiter will notify me… Waiting"* instead of a terminal string. Both duplicated the orchestrator's own watch at per-worker model cost and stranded their dispatch slot until killed. The only sanctioned CI-watch loop is a **foreground, blocking** `gh pr checks <M> --watch` call in the specific mode/branch that documents it as its job (fix-checks-only's fix-loop; the issue-work / fix-main-ci ungated-admin-direct-merge branch) — that blocks your own turn synchronously, self-heartbeats, and can't outlive your return the way a `Monitor` or backgrounded watch can.
- **Your terminal state is reached from LOCAL gates + PR-opened + auto-merge-armed — never gate the commit / push / PR-open on a CI result ([#707](https://github.com/mattsears18/shipyard/issues/707)).** The decision to commit, push, and open the PR is made from *local* verification only — typecheck, lint, and the relevant unit suite run **synchronously in the foreground** (issue-work [§4.6](../../agents/issue-worker/issue-work.md)). The PR's *remote CI checks* are **not** a precondition for committing: never treat "wait for CI to confirm" as a step that must complete before you commit, and never end the turn with fully-implemented but uncommitted work because a background CI-watch hasn't reported yet. CI confirmation is the **orchestrator's** job — its per-iteration PR triage reconciles every open PR and dispatches a fix-checks-only worker against any that go red — so the worker's job ends at *"local gates green, PR opened, auto-merge armed."* The post-PR check-rollup read (worker-preamble § "Auto-merge + snapshot-and-return pattern" step 2 — fragment [`auto-merge.md`](./auto-merge.md)) is a **one-shot snapshot** for the return string, never a wait. This is distinct from the #529 rule above: #529 forbids using a backgrounded process *as your wait mechanism*; #707 forbids treating CI confirmation *as a commit precondition at all*. The #707 repro: on a CI-congested host (self-hosted runners draining a deep queue) a worker finished its full implementation, verified it locally, spawned a background CI-watch, and then **stalled with the work uncommitted on disk** — returning *"I'll wait for the background waiter to report completion before proceeding to commit"* — because it treated CI confirmation as a precondition for committing; the background watch could not report within the turn, so nothing ever committed. **If you do spawn a background CI-watch at all (you generally shouldn't), run it fire-and-forget or skip it — never *wait* on it before committing or returning.** The one exception is **fix-checks-only** (and the issue-work step-0.5 ungated-admin-direct-merge wait): those modes DO block on `gh pr checks <M> --watch` because re-driving / gating an existing PR's CI *is* their job — that exception is documented in `auto-merge.md` and does not license gating a *fresh commit* on CI in any other mode.
- **No narrative status updates.** Strings like `"waiting for monitor"`, `"shard 2 still running"`, `"unit tests pass, awaiting E2E"`, `"routine progress"`, `"I'll wait for that notification"` are contract violations — the agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging stale state (and, per the rule above, a narrative emitted while a backgrounded process is still in flight strands the work as incomplete-but-reported-complete). Either return one of the documented terminal strings, or keep the foreground bash call alive (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism) until you have one to return.
- **The `blocked` outcome is always available.** If you hit a real blocker before push (ambiguous scope, can't reproduce, conflict needs human judgment, 3-attempt fix-loop cap hit, a missing `worktreePath`), return it and exit — as `{"outcome": "blocked", "blocked_reason": "<reason>", "blocked_stage": "<stage>"}` under the structured shape, or `blocked: <reason>` under the free-text shape. Don't burn the session on one issue.

## Stop background processes before returning

If your worker spawned anything that lives **outside** the foreground tool-call lifecycle — a `Monitor` sub-task watching CI, a `Bash` call with `run_in_background: true` (e.g. a long-tail `gh pr checks --watch` you backgrounded so you could keep working in parallel), a `TaskCreate` sub-Agent — **stop it explicitly before you emit your terminal return string**. These processes belong to your session's background pool, not your "main turn," so the harness does not auto-reap them when your final assistant message lands. Each one will keep firing notifications (`<result>Still waiting (check 8)...</result>`, `<result>All historical background tasks have completed...</result>`) for the rest of its internal max-runtime (Monitors: 15–60 min; backgrounded bash: until the command exits or the shell is killed), and **every notification re-invokes the orchestrator for a no-op turn** because the parent agent is the wake target for everything spawned underneath it. The lightwork session that filed [#297](https://github.com/mattsears18/shipyard/issues/297) accumulated 50+ stale wake events across two fix-checks-worker dispatches that left their Monitor sub-tasks running after returning.

Apply this rule on **every** termination path — clean `green` / `shipped` / `rebased` / `noop:` returns, `blocked: <reason>` bails, and even the `reaped: ...` escape hatch (see [`reaped-escape-hatch.md`](./reaped-escape-hatch.md)). The notification leak is independent of whether the worker succeeded; what matters is that the worker spawned something whose lifetime exceeds its turn.

Mechanism per tool family:

| What you spawned | How to stop it before returning |
|---|---|
| `Monitor` sub-task (any subscription) | `TaskStop` against the task id you got back from `TaskCreate` / `Monitor` |
| `Bash` with `run_in_background: true` | `KillShell` against the shell id from the background-call's response (or `BashOutput` if you need the final exit code first, then `KillShell`) |
| `TaskCreate` sub-Agent that's still running | `TaskStop` against its task id |
| Foreground `Bash` (no `run_in_background:`) — e.g. `gh pr checks <M> --watch` | **Nothing** — foreground bash blocks your turn until it exits, so it can't outlive the return |

If you never spawned any of the above, this section is a no-op — the foreground-only path (the default) is already clean. The rule is "if you spawned it, you stop it"; it is NOT "always call TaskStop defensively at the end of every dispatch."

If `TaskStop` / `KillShell` errors (the process already exited on its own, the id was wrong, etc.), log an advisory and continue — the goal is best-effort cleanup, not blocking your return on a stop call that races against a process that was already done.

## Never `--no-verify`

You are forbidden from passing `--no-verify`, `--no-gpg-sign`, `--no-commit-hooks`, or any other flag that bypasses commit hooks, even if you believe the hook failure is environmental, unrelated to your changes, or a false positive. If a pre-commit hook fails:

1. Try to fix the underlying cause within scope (your changes' code).
2. If the cause is outside scope, return `blocked: pre-commit hook <NAME> failed for reason <X>` so the orchestrator can decide.
3. NEVER bypass. Not even "just this once."

Same rule for `git push --no-verify`. Same rule for any hook-bypass flag. The plugin's `permissions.deny` block in `plugin.json` enforces this at the harness level, but the rule applies even if the deny pattern is somehow bypassed.

## `gh` JSON discipline

Every `gh` call whose output you'll read MUST scope the response to the fields you actually consume — the default output is ~30 fields per issue / ~50 fields per PR, most of which the worker never reads, and each unused field is wasted tool-result tokens that ride in your context for the rest of the session.

See [`gh-json-discipline.md`](./gh-json-discipline.md) for the field-scoping cookbook — which subcommands take `--json`/`--jq`, the two-pattern terseness spectrum, the common-projections table, and the default-mode / piping anti-patterns.

## On-demand fragments

The rarely-hit reference material lives in fragments in this directory (`plugins/shipyard/skills/worker-preamble/`). They are NOT loaded by default — load a fragment only when your mode's flow reaches the situation it covers. The per-mode specs under `agents/issue-worker/<mode>.md` and the dispatch templates in `commands/do-work/` cite the relevant fragments by name; when in doubt, load the fragment the per-mode file points at. Every section title is preserved verbatim from the pre-split `SKILL.md`, so a `worker-preamble § "<Section>"` citation resolves to the fragment that now owns that section.

| Fragment | Sections it owns | Load it when | Modes that need it |
|---|---|---|---|
| [`auto-merge.md`](./auto-merge.md) | Auto-merge + snapshot-and-return pattern | You opened a PR and need to arm auto-merge + categorize the check/merge outcome (including the ungated admin-direct pre-check and the `merged-direct-ungated` refinement). | issue-work, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate (fixable path); fix-checks-only for the snapshot categorization |
| [`reaped-escape-hatch.md`](./reaped-escape-hatch.md) | Worktree-reaped escape hatch; Incremental progress posting (investigation-heavy work) | Before any git/gh **write** (re-derive `WORKTREE_PATH`); investigation-heavy modes post findings before the first write. | All modes (every mode writes); incremental-posting especially issue-work, fix-checks-only, investigate |
| [`node-bootstrap.md`](./node-bootstrap.md) | Dependency-bootstrap check for Node-based target repos; Adding a NEW dependency — default to the latest stable version; Root-owned commit hooks in a non-workspace monorepo; Husky / `core.hooksPath` hooks silently skipped on a missing exec bit; Test-runner silent-pass when the target repo ignores worktree paths | Running the **target repo's** local tests / pre-push hooks before pushing, OR introducing a new dependency, against a Node-based or self-hosting target repo. | All modes that push to a Node/self-hosting target repo (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate) |
| [`ci-pitfalls.md`](./ci-pitfalls.md) | An absence-assertion that observed nothing is not a pass; Heartbeat emission around long-running commands; Mirror new string constants into locale / parity files; Pin the default branch in git-using test fixtures; GitHub push-protection blocking a synthetic test-fixture secret | **Verifying a CI result** (any "assert nothing failed" check — see the [`assert-ci-green.sh`](../../scripts/assert-ci-green.sh) helper), running long silent commands (CI babysitting, full local suites), adding user-facing strings, authoring git-using shell fixtures, or adding secret-shaped fixtures. | any mode that verifies CI (vacuous-pass guard); fix-checks-only / fix-main-ci / fix-failing-prs-batch (heartbeat); any mode authoring strings / git fixtures / secret fixtures |
| [`commit-hygiene.md`](./commit-hygiene.md) | Pre-commit hygiene — escape symlinks | You created the `node_modules → ../../../node_modules` bootstrap symlink and must keep it out of a commit. | Any mode that ran the `node-bootstrap.md` symlink remediation |
| [`classifier-denial.md`](./classifier-denial.md) | After a classifier denial | Auto Mode (or another harness-side classifier) denies a tool call. Fires only on a denial — most dispatches never load it. | Any mode, whenever a denial occurs |
| [`native-background-subagent.md`](./native-background-subagent.md) | Native background-subagent auto-PR reconciliation | Hand-dispatching a mode shim via the `Agent` tool with `isolation: "worktree"` (e.g. `shipyard:verify-worker`), or diagnosing a stray unlabeled draft PR on a canonical `do-work/issue-<N>` branch. Self-declares a no-op on the happy path and, post-[#791](https://github.com/mattsears18/shipyard/issues/791), narrows to non-`Workflow` dispatches — which is no `/do-work` mode. | `shipyard:verify-worker`; any hand dispatch of a mode shim via the `Agent` tool |
| [`gh-json-discipline.md`](./gh-json-discipline.md) | `gh` JSON discipline — field-scoping cookbook | You're writing a `gh` call and want the exact `--json`/`--jq` flag shape rather than re-deriving it. The one-sentence rule itself stays in the always-loaded core. | Any mode that calls `gh` (optional reference — the core rule alone satisfies the citation) |

## What this skill does NOT cover

Mode-specific scope intentionally lives in the per-mode dispatch prompt and the agent's own spec:

- **Branch naming** (`do-work/issue-<N>`, `do-work/fix-main-ci-<short-sha>`, `do-work/fix-pr-pileup-<timestamp>`, or the PR's existing head branch for fix-checks/fix-rebase) — set by the dispatching prompt.
- **Return-string vocabulary** (`shipped #<N> via PR #<M>`, `green #<M>`, `rebased #<M>`, `shipped main-ci-fix via PR #<M>`, etc.) — set by the dispatching prompt and validated by the orchestrator's step A reconcile.
- **Fix-loop attempt caps** (3 for fix-checks-only, 1 for fix-rebase, 1 for fix-main-ci / fix-failing-prs-batch) — set in each per-mode file under `agents/issue-worker/`.
- **Trivial-conflict-or-bail policy** for fix-rebase — set in `agents/issue-worker/fix-rebase.md`.
- **Author-trust → auto-merge gating** for issue-work — passed through as `originating_author_trust` in the dispatching prompt and consumed by `agents/issue-worker/issue-work.md`'s step 6. When the field is **absent** from the dispatch prompt, the worker does NOT hard-default to `external`: it resolves the issue author's collaborator permission live (`repos/{owner}/{repo}/collaborators/{author}/permission` — `admin`/`maintain`/`write` ⇒ trusted, anything else including a non-collaborator's `read`/`none` or an API error ⇒ external), so owner-authored issues on solo repos still auto-merge while genuinely untrusted authors still gate (issue [#599](https://github.com/mattsears18/shipyard/issues/599)). The full fallback lives in issue-work step 6.

When in doubt, the per-mode prompt overrides this skill where they disagree — but the rules above are deliberately universal and shouldn't conflict.
