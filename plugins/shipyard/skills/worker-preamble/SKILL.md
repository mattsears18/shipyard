---
name: worker-preamble
description: Shared worktree-discipline + dispatch-contract preamble for every `/shipyard:do-work` worker mode (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate). Dispatch prompts in `commands/do-work.md` reference this skill instead of inlining the same preamble per mode — one source of truth for worktree isolation rules, return-contract scaffolding, and the `--label shipyard` requirement. This thin core keeps the universally-needed hot rules; rarely-hit reference material lives in on-demand fragments alongside this file. Closes [#107](https://github.com/mattsears18/shipyard/issues/107), split into core + fragments by [#617](https://github.com/mattsears18/shipyard/issues/617).
---

# Worker preamble (every `/shipyard:do-work` mode)

The contract every dispatched worker — regardless of mode — operates under. The orchestrator's per-mode dispatch prompts in `commands/do-work.md` reference this skill by name (`shipyard:worker-preamble`) instead of repeating the language verbatim. Mode-specific rules (branch naming, return strings, scope-expansion rules) stay in the per-mode dispatch prompt and in the dispatched agent's per-mode file (`agents/issue-worker/<mode>.md` — loaded by the thin entry router `agents/issue-worker.md` from the `mode:` field). This file owns only the shared ground rules.

**This `SKILL.md` is a thin always-loaded core.** It carries the rules every worker mode needs on every dispatch: worktree-isolation discipline, the step-0 cwd fail-fast, the `--label shipyard` PR-creation contract, the return-contract scaffolding, the background-process-cleanup rule, the `--no-verify` prohibition, the classifier-denial posture, and the `gh` JSON discipline. The rarely-hit reference material — the auto-merge / snapshot categorization, the worktree-reaped escape hatch, the Node dependency-bootstrap and hook/test silent-pass guards, the CI/push pitfalls, the escape-symlink commit hygiene — lives in **on-demand fragments** in this same directory, loaded only by the worker modes that need them. See [On-demand fragments](#on-demand-fragments) below for the index. The split (issue [#617](https://github.com/mattsears18/shipyard/issues/617)) preserves every rule's semantics and reachability — it only changes whether a rule is loaded eagerly (here) or on demand (a fragment) — so no worker mode loses access to a rule it relies on.

## Worktree discipline (load-bearing)

You are running inside an **isolated git worktree**. Your initial working directory is the worktree path; the user's primary checkout lives at a different path and is strictly off-limits.

Three rules, no exceptions:

1. **Never `cd` outside your worktree.** Your tools (Bash, Edit, Read, Write) inherit cwd from your worktree. The moment you `cd` to anything else — including the user's primary checkout path — subsequent git/gh commands operate on whatever git directory is at that path, which can silently corrupt the user's checkout.
2. **Never use `gh pr checkout <M>`.** That command resolves to the cwd at call time and switches whatever working tree is there. If your cwd has drifted (or the harness mis-set it), `gh pr checkout` will move the user's primary HEAD without warning. Always use `git fetch origin <branch>` followed by `git switch <branch>` — those operate on the cwd's git context predictably and won't escape it.
3. **Never `git switch` to the repo's default branch (`main` / `master` / etc.) when your work is done.** The global "switch back to main when local work is done" rule is for the user's *primary* checkout, not your isolated worktree. Parking your worktree on `[main]` locks the user's primary out of `git switch main` (git enforces one-worktree-per-branch). Leave your worktree on your work branch — the orchestrator's cleanup phase handles the rest.

## Step-0 cwd fail-fast — assert you're actually in your worktree ([#486](https://github.com/mattsears18/shipyard/issues/486))

The three rules above assume your initial working directory **is** the isolated worktree. That assumption is normally true — but it is set by the **Claude Code harness**, not by shipyard, and an `isolation: "worktree"` dispatch can land with its process cwd **pinned to the PRIMARY checkout root** instead of the created worktree. When that happens, every git-mutating command you run targets the user's primary checkout, and on any repo with the global `enforce-worktree.sh` PreToolUse hook installed (the exact environment shipyard's worktree-isolation contract assumes) the hook hard-blocks your `git commit` as *"targets the PRIMARY checkout."*

**This is the [#486](https://github.com/mattsears18/shipyard/issues/486) failure mode, and it is catastrophic when undetected:** the worker runs the *entire* task — implements the fix, validates it, stages the diff — and only dies at the **final `git commit`**, after burning its whole run (the #486 repro: ~94 min of Opus on a single dispatch). The orchestrator can't rescue the staged work either (its own session may share the mispinned cwd; `EnterWorktree` refuses a subagent cwd override), so the validated work is recoverable only by a human-run commit out-of-band.

**Why shipyard can't fix the root cause.** The cwd is set by the harness's dispatch machinery, not by anything in this repo — shipyard cannot force an `isolation: "worktree"` dispatch's process cwd to the created worktree, nor pin the orchestrator session's cwd to its `orchestrator-<session-id>` worktree. Those are AC items (1) and (2) of [#486](https://github.com/mattsears18/shipyard/issues/486), and they are **harness-level, out of shipyard's control**. The in-repo mitigation is to **fail fast at step 0** so a mispinned dispatch returns immediately instead of after a full wasted run — this guard, plus a regression test, are the shipyard-implementable slice.

**The check — run it once, first thing, before any task work.** Compare your worktree toplevel against the repo's known worktree-vs-primary shape. A shipyard-orchestrated dispatch's cwd, when correct, resolves to a path under `.claude/worktrees/` (the worker's `agent-*` worktree or the orchestrator's `orchestrator-*` worktree). When the cwd is mispinned to primary, `git rev-parse --show-toplevel` resolves to the primary checkout root — which is the **parent** of `.claude/worktrees/`, and which `git rev-parse --git-common-dir` reveals because a linked worktree's `.git` is a *file* pointing at `<primary>/.git/worktrees/<name>`, whereas the primary's `.git` is a directory:

```bash
# Step-0 cwd fail-fast (#486). Run before implementing anything.
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"

# A linked worktree has a *separate* per-worktree git dir
# (<common>/worktrees/<name>) distinct from the common dir. The PRIMARY
# checkout has git-dir == git-common-dir. If they're equal, this cwd is a
# primary checkout, NOT an isolated worktree — the dispatch-isolation cwd
# override is wrong.
if [ -n "$TOPLEVEL" ] && [ "$(cd "$GIT_DIR" 2>/dev/null && pwd -P)" = "$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" ]; then
  echo "blocked: dispatch-isolation cwd override is wrong — my cwd ($TOPLEVEL) is a PRIMARY checkout, not an isolated worktree. An isolation: \"worktree\" dispatch was pinned to the primary checkout root (see #486). Every git-mutating command here would target the user's primary checkout and the enforce-worktree hook will block my final commit. Failing fast at step 0 instead of burning the full run. Re-dispatch required."
  exit 0
fi
```

The `git-dir == git-common-dir` equality is the load-bearing signal: it is true **only** for a primary checkout and false for every linked worktree, regardless of where under the tree the cwd sits, so it catches the mispin without hard-coding the primary's absolute path or assuming a `.claude/worktrees/` layout. (For an extra belt: a correct dispatch's toplevel contains `/.claude/worktrees/` — but the git-dir equality is the canonical test and the one the regression guard asserts.)

**Return `blocked:`, not `reaped:`.** The mispin is a deterministic property of *this* dispatch's cwd — re-running the identical dispatch could land the same wrong cwd, so it is not the retryable-infrastructure-noise case `reaped:` is reserved for. `blocked:` is correct: the orchestrator's reconcile classifies it as a refuse and applies `needs-human-review` (per [#521](https://github.com/mattsears18/shipyard/issues/521)), surfacing the harness-level misroute for a human (or a future harness fix) rather than silently re-enqueueing a dispatch that may misfire the same way. **This guard runs in every worker mode** — the catastrophic-wasted-run failure mode is identical whether the dispatch was issue-work, fix-checks-only, fix-rebase, fix-main-ci, or fix-failing-prs-batch, so it lives in the shared preamble rather than per-mode.

**When NOT to fire.** A correctly-pinned dispatch (cwd under `.claude/worktrees/agent-*` or `orchestrator-*`) has git-dir ≠ git-common-dir and sails through — the guard is a no-op on the normal path, one cheap `git rev-parse` pair. Running outside any orchestrated session (a human invoking a worker spec by hand in the primary checkout for testing) would trip it, which is correct: a worker spec is not meant to mutate the primary checkout.

## PR-creation contract

When opening a PR from any worker mode, every call **MUST** include:

```bash
gh pr create --repo <owner/repo> --label shipyard ...
```

The `shipyard` label is the orchestrator's session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it; omitting it makes the PR invisible to the orchestrator's own state machine. Add other mode-specific labels (e.g. `needs-human-review` for external-trust PRs) **alongside** `shipyard`, never as a replacement.

For issue-work mode the PR body MUST include a **closing keyword** — `Closes #<N>` (or `Fixes`/`Resolves #<N>`), case-insensitive, on its own line — so the issue auto-closes on merge. A **bare reference** (`Refs #<N>`, `Related to #<N>`, plain `#<N>`) does NOT register a closing link and leaves the issue OPEN forever after merge; the bare forms are reserved for *additional, non-resolving* issue mentions only. Repo-local "don't auto-close" conventions govern incidental references — they do NOT exempt the dispatched issue's resolving PR, which is the intended-close case (see `agents/issue-worker/issue-work.md` § "5. Commit + push + PR" and § "5.8 Post-PR-create closing-link verification" — issue [#481](https://github.com/mattsears18/shipyard/issues/481)). For synthetic diverts (fix-main-ci, fix-failing-prs-batch) there is no issue to close — omit the `Closes` line.

**After `gh pr create` returns**, arm auto-merge and snapshot the check/merge state per the **[`auto-merge.md`](./auto-merge.md)** fragment (`worker-preamble § "Auto-merge + snapshot-and-return pattern"`). That fragment carries the ungated admin-direct-merge pre-check, the `enabled` / `merged-direct` / `merged-direct-ungated` / `unavailable` categorization, and the no-`--watch` rule (with its two exceptions). Load it before opening a PR.

## Return-contract discipline

Every worker mode's last line is the orchestrator's only signal of outcome. The valid terminal strings are mode-specific (see the dispatching prompt for the exact set), but three universal rules apply:

- **Run all work synchronously to a terminal state — NEVER arm a background process and return ([#529](https://github.com/mattsears18/shipyard/issues/529)).** You must NOT arm a `Bash` call with `run_in_background: true`, a `Monitor` sub-task, a `TaskCreate` background-waiter, or any other process that resolves *after* your turn ends, and then return before it resolves. Doing so is a contract violation with a specific, costly failure mode: the harness treats the assistant message ending your turn as a `status: completed` **even though the work is not done** — no commit, no pushed branch, no PR, a half-finished edit set — so the orchestrator records the dispatch as complete while the actual work is stranded mid-flight. The orchestrator's crash-aware reap + re-dispatch (A.0.5) recovers it, but at the full token cost of a wasted dispatch (the #529 repro burned ~145k tokens for zero output: a worker armed a background test-waiter against #522 and returned *"I have a background waiter armed … I'll wait for that notification"* — a non-terminal narrative — leaving #522 OPEN with no PR and 0 commits in its worktree). If you need to wait on a long-running command (a test suite, CI), **block your own turn on a foreground call** (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism; see `worker-preamble § "Heartbeat emission around long-running commands"` in [`ci-pitfalls.md`](./ci-pitfalls.md) for keeping a silent foreground command watchdog-safe) until you have a terminal string to return. The terminal string is emitted *after* the work reaches its real end state, never *instead of* finishing it. (This composes with — but is distinct from — the "Stop background processes before returning" section below: that section covers cleaning up a process you legitimately spawned mid-turn; this rule forbids using a backgrounded process *as your wait mechanism* and returning a non-terminal narrative in its place.)
- **No narrative status updates.** Strings like `"waiting for monitor"`, `"shard 2 still running"`, `"unit tests pass, awaiting E2E"`, `"routine progress"`, `"I'll wait for that notification"` are contract violations — the agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging stale state (and, per the rule above, a narrative emitted while a backgrounded process is still in flight strands the work as incomplete-but-reported-complete). Either return one of the documented terminal strings, or keep the foreground bash call alive (fix-checks-only's `gh pr checks <M> --watch` is the canonical mechanism) until you have one to return.
- **`blocked: <reason>` is always available.** If you hit a real blocker before push (ambiguous scope, can't reproduce, conflict needs human judgment, 3-attempt fix-loop cap hit), return `blocked: <reason>` and exit. Don't burn the session on one issue.

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

## After a classifier denial

Auto Mode (and other harness-side classifiers) sometimes deny a tool call — an Edit, a Write, a Bash, an `npm install`, a symlink — with a reason like *"...creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* The denial is a hard boundary enforced by the harness, not a suggestion you can argue past. The correct posture is to treat the denial as a deterministic failure for **this** dispatch and let a human decide whether to re-authorize, change the classifier policy, or redirect the work.

**Three behaviors you MUST NOT do after a denial, even when you believe the denial was wrong:**

1. **Do NOT post a comment to any public GitHub artifact** (issue comment, PR description, PR comment, PR review) that summarizes, reframes, paraphrases, fabricates, or explains the classifier's reasoning. Classifier denials are between the worker and the harness; surfacing them to public-facing channels creates a content-integrity attack surface — even when well-intentioned, a public-facing comment fabricating *why* the classifier denied something is a side-channel that a future worker, reviewer, or scraper could read as authoritative. The harness's classifier reasoning is not yours to relay.
2. **Do NOT attempt to file a follow-up issue arguing the denial was wrong.** "The classifier was overly strict, please relax the policy" is not a worker decision; it's a maintainer decision. If you genuinely believe a denial pattern is misclassified at the policy level, the right surface is `mattsears18/shipyard` issues filed by the *user* after they see your `blocked:` return, not a self-filed escalation from inside the dispatch.
3. **Do NOT retry the same denied call through a workaround** — a different tool, a renamed file, a Base64-encoded payload, a shell-out that produces the same effect via a different syscall, or any other "I'll just do it a different way" strategy. Classifier policy targets *effects*, not tool names; routing around the deny is treated as the same policy violation. If the first attempt was denied, the second through any synonym is denied too.

**The correct response to a classifier denial is one foreground call: return.**

> `blocked: classifier denied <one-line description of what was denied>`

That's it. No comment, no follow-up issue, no creative retry. The `blocked:` return is the orchestrator's signal that the dispatch hit a deterministic boundary; step A reconcile will classify it as a refuse and apply `needs-human-review` (per [#521](https://github.com/mattsears18/shipyard/issues/521)) and the user can decide what to do next. The one-line description should name the operation (e.g., "Edit to .claude/settings.json", "symlink ../../../node_modules to ./node_modules", "npm install firebase-tools") so the maintainer can pattern-match the denial without reading the full transcript — but **do not include the classifier's prose reasoning** (paraphrased or verbatim) in the return string. The orchestrator captures it in the transcript record on its own.

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

## On-demand fragments

The rarely-hit reference material lives in fragments in this directory (`plugins/shipyard/skills/worker-preamble/`). They are NOT loaded by default — load a fragment only when your mode's flow reaches the situation it covers. The per-mode specs under `agents/issue-worker/<mode>.md` and the dispatch templates in `commands/do-work/` cite the relevant fragments by name; when in doubt, load the fragment the per-mode file points at. Every section title is preserved verbatim from the pre-split `SKILL.md`, so a `worker-preamble § "<Section>"` citation resolves to the fragment that now owns that section.

| Fragment | Sections it owns | Load it when | Modes that need it |
|---|---|---|---|
| [`auto-merge.md`](./auto-merge.md) | Auto-merge + snapshot-and-return pattern | You opened a PR and need to arm auto-merge + categorize the check/merge outcome (including the ungated admin-direct pre-check and the `merged-direct-ungated` refinement). | issue-work, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate (fixable path); fix-checks-only for the snapshot categorization |
| [`reaped-escape-hatch.md`](./reaped-escape-hatch.md) | Worktree-reaped escape hatch; Incremental progress posting (investigation-heavy work) | Before any git/gh **write** (re-derive `WORKTREE_PATH`); investigation-heavy modes post findings before the first write. | All modes (every mode writes); incremental-posting especially issue-work, fix-checks-only, investigate |
| [`node-bootstrap.md`](./node-bootstrap.md) | Dependency-bootstrap check for Node-based target repos; Adding a NEW dependency — default to the latest stable version; Root-owned commit hooks in a non-workspace monorepo; Husky / `core.hooksPath` hooks silently skipped on a missing exec bit; Test-runner silent-pass when the target repo ignores worktree paths | Running the **target repo's** local tests / pre-push hooks before pushing, OR introducing a new dependency, against a Node-based or self-hosting target repo. | All modes that push to a Node/self-hosting target repo (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate) |
| [`ci-pitfalls.md`](./ci-pitfalls.md) | Heartbeat emission around long-running commands; Mirror new string constants into locale / parity files; Pin the default branch in git-using test fixtures; GitHub push-protection blocking a synthetic test-fixture secret | Running long silent commands (CI babysitting, full local suites), adding user-facing strings, authoring git-using shell fixtures, or adding secret-shaped fixtures. | fix-checks-only / fix-main-ci / fix-failing-prs-batch (heartbeat); any mode authoring strings / git fixtures / secret fixtures |
| [`commit-hygiene.md`](./commit-hygiene.md) | Pre-commit hygiene — escape symlinks | You created the `node_modules → ../../../node_modules` bootstrap symlink and must keep it out of a commit. | Any mode that ran the `node-bootstrap.md` symlink remediation |

## What this skill does NOT cover

Mode-specific scope intentionally lives in the per-mode dispatch prompt and the agent's own spec:

- **Branch naming** (`do-work/issue-<N>`, `do-work/fix-main-ci-<short-sha>`, `do-work/fix-pr-pileup-<timestamp>`, or the PR's existing head branch for fix-checks/fix-rebase) — set by the dispatching prompt.
- **Return-string vocabulary** (`shipped #<N> via PR #<M>`, `green #<M>`, `rebased #<M>`, `shipped main-ci-fix via PR #<M>`, etc.) — set by the dispatching prompt and validated by the orchestrator's step A reconcile.
- **Fix-loop attempt caps** (3 for fix-checks-only, 1 for fix-rebase, 1 for fix-main-ci / fix-failing-prs-batch) — set in each per-mode file under `agents/issue-worker/`.
- **Trivial-conflict-or-bail policy** for fix-rebase — set in `agents/issue-worker/fix-rebase.md`.
- **Author-trust → auto-merge gating** for issue-work — passed through as `originating_author_trust` in the dispatching prompt and consumed by `agents/issue-worker/issue-work.md`'s step 6. When the field is **absent** from the dispatch prompt, the worker does NOT hard-default to `external`: it resolves the issue author's collaborator permission live (`repos/{owner}/{repo}/collaborators/{author}/permission` — `admin`/`maintain`/`write` ⇒ trusted, anything else including a non-collaborator's `read`/`none` or an API error ⇒ external), so owner-authored issues on solo repos still auto-merge while genuinely untrusted authors still gate (issue [#599](https://github.com/mattsears18/shipyard/issues/599)). The full fallback lives in issue-work step 6.

When in doubt, the per-mode prompt overrides this skill where they disagree — but the rules above are deliberately universal and shouldn't conflict.
