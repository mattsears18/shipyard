# /do-work Graceful Shutdown & Hard-Kill Recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/do-work` shutdownable: a typed keyword drains in-flight agents and exits cleanly, and a hard-killed session can be recovered safely on the next run via orphan-worktree triage. Adds a permanent `do-work` label to every issue picked up and PR opened for audit + reporting.

**Architecture:** All changes are prompt-engineering edits to two markdown files — `plugins/app-audits/commands/do-work.md` (the orchestrator) and `plugins/app-audits/agents/issue-worker.md` (the worker). No new code, no new data files. Recovery leverages git's own bookkeeping via a deterministic branch-naming convention (`do-work/issue-<N>`), so `git worktree list` + GitHub state are the only sources of truth. Soft drain is a flag the orchestrator sets when it sees a stop keyword in a user message.

**Tech Stack:** Markdown (orchestrator + agent prompts), `gh` CLI, `git` CLI. No code is added.

**Spec:** [`docs/superpowers/specs/2026-05-17-do-work-graceful-shutdown-design.md`](../specs/2026-05-17-do-work-graceful-shutdown-design.md)

**Verification strategy:** Because the deliverable is prompt text, there are no executable tests. Each task ends with a *scenario trace* — read the section you just edited and walk through the named scenario aloud, confirming the doc would tell the orchestrator (or agent) to do the right thing at every step. The final task (Task 6) traces both end-to-end scenarios through the fully assembled doc.

---

## File Structure

Two files are touched, both pre-existing:

- **Modify**: `plugins/app-audits/commands/do-work.md` — five surgical edits (new Setup Step 2, mandate branch + label in dispatch, new Soft Drain section, drain guards in Steady-state Steps C/D, updates to Termination/Summary/Don't).
- **Modify**: `plugins/app-audits/agents/issue-worker.md` — three small edits (preamble note about orchestrator-provided branch name, Step 3 branch-name honoring, Step 5 `--label do-work` on PR create).

No file creation. No directory restructuring.

---

## Task 1: Insert Setup Step 2 (orphan triage + label creation)

**Files:**
- Modify: `plugins/app-audits/commands/do-work.md` (insert new Step 2 after current "### 1. Resolve repo + user" at ~line 31; renumber subsequent steps 2→3, 3→4, 4→5, 5→6)

This is the largest single edit. We're adding orphan recovery to the front of the Setup phase, plus idempotent label creation. Existing Step 2/3/4/5 get renumbered to 3/4/5/6, and three cross-references in the doc need to be updated to match.

- [ ] **Step 1.1: Re-read current Setup section for context**

Run: `Read plugins/app-audits/commands/do-work.md` (lines 29-95)
Confirm: the current numbering is 1 (Resolve repo + user), 2 (Fetch + rank backlog), 3 (Snapshot failing PRs), 4 (Initial scope pre-flight), 5 (Initial pool fill).

- [ ] **Step 1.2: Insert new Step 2 between current Step 1 and Step 2**

Use `Edit` with `old_string` matching the boundary between the two existing steps. After current Step 1's contents (ending with `Cache both for the session.`), and before the existing `### 2. Fetch + rank the backlog`, insert:

```markdown
### 2. Recover from prior session + ensure label exists

Two short pre-flight tasks before fetching the backlog. Both use `<owner/repo>` and the gh-authenticated user from step 1.

**2a. Ensure the `do-work` label exists** (idempotent — succeeds whether it's already there or not):

```bash
gh label create do-work --repo <owner/repo> --description "Worked on by /do-work" --color 5319E7 2>/dev/null || true
```

**2b. Orphan worktree triage** — scan for `do-work/*` worktrees left behind by a prior killed session:

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, inspect its worktree state and act according to the table below. Track `salvaged_count` (worktrees that produced or kept an open PR) and `abandoned_count` (worktrees removed) — both default to 0 and feed into the end-of-session summary.

For each branch, find its worktree path with `git worktree list | grep "\[<branch>\]"` and `cd` into it (or use `git -C <path>`).

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 3). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `gh pr create --repo <owner/repo> --fill --label do-work` then `gh pr merge <M> --repo <owner/repo> --auto --squash --delete-branch`. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `gh pr create --repo <owner/repo> --fill --label do-work` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup`. If any check is `FAILURE` / `ERROR` / `TIMED_OUT` → push `{number: <M>, ...}` onto `failed_prs` (it'll be picked up by the dispatch rules' fix-checks-only path). Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | Standard end-of-session cleanup handles it later. Leave for now. |

If `git worktree list` returns no `do-work/*` branches, this step is a no-op and both counters stay at 0.

**Inconsistency log (advisory)** — also run a one-line label cross-check:

```bash
gh issue list --repo <owner/repo> --label do-work --assignee @me --state open --search '-linked:pr' --json number
```

Any results here that DON'T correspond to a `do-work/*` worktree on disk are "dispatched but agent died before its first commit" cases. Log them in the session summary as an advisory line — don't auto-act on them in v1.
```

- [ ] **Step 1.3: Renumber current Step 2 → 3, Step 3 → 4, Step 4 → 5, Step 5 → 6**

Four `Edit` calls, one per heading:

- `### 2. Fetch + rank the backlog` → `### 3. Fetch + rank the backlog`
- `### 3. Snapshot failing PRs` → `### 4. Snapshot failing PRs`
- `### 4. Initial scope pre-flight` → `### 5. Initial scope pre-flight`
- `### 5. Initial pool fill` → `### 6. Initial pool fill`

- [ ] **Step 1.4: Update three cross-references in the body of the doc**

Search for "step-2", "step-3", "step 5" in the body and fix:

- Line ~75 (`step-3 failing-PR snapshot` in the end-of-session drain section) → `step-4 failing-PR snapshot`. Re-grep to confirm only one occurrence in the file before replacing.
- Line ~127 (`step-2 backlog fetch` in periodic refresh / Step D) → `step-3 backlog fetch`.
- Line ~127 (`step-3 query` in periodic refresh / Step D's Failed-PR scan) → `step-4 query`.
- Line ~132 (`Dispatch rules (used by step 5 and step C)` heading) → `Dispatch rules (used by step 6 and step C)`.

Use grep to find them all precisely before editing:

```bash
grep -n "step-[0-9]\|step [0-9]" plugins/app-audits/commands/do-work.md
```

Update each in turn. Avoid replace_all — the surrounding context matters.

- [ ] **Step 1.5: Verify section ordering and cross-references**

Run: `grep -n "^### " plugins/app-audits/commands/do-work.md | head -20`
Expected: Setup section shows `### 1. Resolve repo + user`, `### 2. Recover from prior session + ensure label exists`, `### 3. Fetch + rank the backlog`, `### 4. Snapshot failing PRs`, `### 5. Initial scope pre-flight`, `### 6. Initial pool fill` in that order.

Run: `grep -n "step-[0-9]\|step [0-9]" plugins/app-audits/commands/do-work.md`
Expected: every numbered cross-reference now matches the new numbering.

- [ ] **Step 1.6: Scenario trace — "killed session left an orphan with committed-pushed work and a red PR"**

Mentally walk this scenario through the new Step 2:

1. Previous session: dispatched issue #42 → worktree at `worktrees/do-work-issue-42/` → branch `do-work/issue-42` → agent committed + pushed + opened PR #100 → user killed session.
2. CI then went red on PR #100.
3. Fresh `/do-work` starts. Step 1 resolves repo. Step 2 runs.
4. Trace: `git worktree list` returns `do-work/issue-42`. Inspect: commits exist, branch pushed, `gh pr list --head do-work/issue-42` returns PR #100. `statusCheckRollup` shows `FAILURE`. → push `{number: 100}` onto `failed_prs`. `salvaged_count++`.
5. Step 3 fetches the backlog (issue #42 is excluded by `-linked:pr`). Step 4 separately snapshots failing PRs and finds PR #100 again — deduped against `failed_prs` because the orphan-triage entry is already there.
6. Initial pool fill picks up PR #100 via the fix-checks-only path.

Confirm: the doc as written would lead the orchestrator through these exact steps. If any step is fuzzy in the doc, fix the wording inline before committing.

- [ ] **Step 1.7: Commit**

```bash
git add plugins/app-audits/commands/do-work.md
git commit -m "feat(app-audits): /do-work setup-time orphan triage + do-work label"
```

---

## Task 2: Mandate branch name + `do-work` label in dispatch

**Files:**
- Modify: `plugins/app-audits/commands/do-work.md` (dispatch rules section, ~lines 145-149)

The dispatch flow already self-assigns the issue. We add `--add-label do-work` to that call, and add two lines to the issue-work prompt template instructing the agent to use the deterministic branch name and to label the PR.

- [ ] **Step 2.1: Re-read dispatch rules section**

Run: `Read plugins/app-audits/commands/do-work.md` (lines 132-160)
Confirm: the issue-work dispatch rule contains the line `gh issue edit <N> --add-assignee @me` and the prompt template at the bottom of that rule.

- [ ] **Step 2.2: Add `--add-label do-work` to the self-assign call**

Use `Edit` to change:

```
self-assign the issue first (`gh issue edit <N> --add-assignee @me`) **before** dispatching, to soft-lock against parallel `/do-work` instances.
```

to:

```
self-assign the issue first (`gh issue edit <N> --add-assignee @me --add-label do-work`) **before** dispatching, to soft-lock against parallel `/do-work` instances and stamp the audit label.
```

- [ ] **Step 2.3: Append branch-name + PR-label mandates to the issue-work prompt template**

Locate the issue-work prompt template (currently a `> Work issue #<N> ...` blockquote). Use `Edit` to append two new sentences before the final period of the existing template — keep the original prompt intact, just add to it.

Old string (the blockquote ending):
```
> Work issue #<N> in `<owner/repo>` to completion. You are already self-assigned. Open a PR that closes the issue, enable auto-merge, snapshot the current check state, and return — **do not `--watch` CI**. The orchestrator handles failed-check recovery on a periodic refresh. Use TDD when adding new behavior. If you hit a blocker before push (ambiguous scope, can't reproduce, etc.), return with `blocked: <reason>` — don't burn the session on one issue.
```

New string:
```
> Work issue #<N> in `<owner/repo>` to completion. You are already self-assigned. Create your branch as `do-work/issue-<N>` — do not use any other name. Open a PR that closes the issue and pass `--label do-work` to `gh pr create`. Enable auto-merge, snapshot the current check state, and return — **do not `--watch` CI**. The orchestrator handles failed-check recovery on a periodic refresh. Use TDD when adding new behavior. If you hit a blocker before push (ambiguous scope, can't reproduce, etc.), return with `blocked: <reason>` — don't burn the session on one issue.
```

- [ ] **Step 2.4: Scenario trace — "fresh issue picked up by dispatch"**

Mentally walk through:

1. Issue #99 is at the head of `ready_issues`. A slot opens.
2. Trace: rule 2 fires. The doc tells the orchestrator to call `gh issue edit 99 --add-assignee @me --add-label do-work`.
3. Then it dispatches an `issue-worker` agent with the prompt that mandates branch `do-work/issue-99` and `--label do-work` on PR create.
4. Agent ships PR #X with both the label and the branch name. On next run, orphan triage would correctly identify worktree #99 if killed mid-session.

Confirm the doc supports each step.

- [ ] **Step 2.5: Commit**

```bash
git add plugins/app-audits/commands/do-work.md
git commit -m "feat(app-audits): /do-work dispatches with deterministic branch + label"
```

---

## Task 3: Update `issue-worker.md` for branch name + PR label

**Files:**
- Modify: `plugins/app-audits/agents/issue-worker.md` (preamble at ~line 6, Step 3 at ~lines 94-103, Step 5 at ~lines 119-131)

The agent must (a) honor the orchestrator-provided branch name verbatim — no more inventing a slug — and (b) pass `--label do-work` to `gh pr create`.

- [ ] **Step 3.1: Re-read issue-worker.md preamble, Step 3, and Step 5**

Run: `Read plugins/app-audits/agents/issue-worker.md` (full file is short enough)
Confirm: Step 3 currently invents a slug-based branch name; Step 5 doesn't currently pass `--label`.

- [ ] **Step 3.2: Add preamble note about orchestrator-provided branch name**

Use `Edit` to change:

```
You are an issue-closing agent. You take one issue, ship one PR, get it auto-merging, and return. You operate in the main working directory, not a worktree, unless the orchestrator says otherwise.
```

to:

```
You are an issue-closing agent. You take one issue, ship one PR, get it auto-merging, and return. You operate in the main working directory, not a worktree, unless the orchestrator says otherwise.

When the orchestrator's dispatch prompt specifies a branch name (e.g., `do-work/issue-<N>`), use that exact name. Do not invent a slug. The orchestrator relies on the convention for cross-session orphan recovery.
```

- [ ] **Step 3.3: Update Step 3 (Sync + branch) to honor the provided name**

Use `Edit` to change the Step 3 block. Old string:

```
### 3. Sync + branch

```bash
git fetch origin
# Use the repo's default branch, not assumed 'main'
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git checkout -B issue/<N>-<short-slug> origin/$DEFAULT_BRANCH
```

Slug: kebab-case derivative of the title, ≤40 chars.
```

New string:

```
### 3. Sync + branch

```bash
git fetch origin
# Use the repo's default branch, not assumed 'main'
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git checkout -B do-work/issue-<N> origin/$DEFAULT_BRANCH
```

Branch name comes from the orchestrator's dispatch prompt and must be exactly `do-work/issue-<N>`. The deterministic name lets the orchestrator's next-session orphan triage find your worktree if this session is killed.
```

- [ ] **Step 3.4: Update Step 5's `gh pr create` to include `--label do-work`**

Use `Edit` to change:

```
gh pr create --repo <owner/repo> \
  --title "<conventional commit title>" \
  --body "$(cat <<'EOF'
Closes #<N>

## Summary
<2-3 sentences>

## Test plan
- [ ] <how the acceptance criteria are verified>
EOF
)"
```

to:

```
gh pr create --repo <owner/repo> \
  --label do-work \
  --title "<conventional commit title>" \
  --body "$(cat <<'EOF'
Closes #<N>

## Summary
<2-3 sentences>

## Test plan
- [ ] <how the acceptance criteria are verified>
EOF
)"
```

- [ ] **Step 3.5: Also update Step 5's `git push` and references in the preceding text**

In Step 5, change `git push -u origin issue/<N>-<slug>` to `git push -u origin do-work/issue-<N>`. Use `Edit` with enough surrounding context (e.g., `git add <specific paths>` line above + the commit line) so the replacement is unambiguous.

- [ ] **Step 3.6: Scenario trace — "agent receives dispatch and ships PR"**

Mentally walk through:

1. Agent's prompt says: "Work issue #99 ... Create your branch as `do-work/issue-99`... pass `--label do-work` to `gh pr create`."
2. Agent reads the preamble note: orchestrator-provided branch must be honored.
3. Step 3 of the agent's own process: branches as `do-work/issue-99`.
4. Step 5: pushes to `do-work/issue-99`, opens PR with `--label do-work`.
5. PR auto-merges with `--delete-branch`. After merge, branch is `[gone]` upstream. Next session's orphan triage classifies and reaps cleanly.

Confirm the agent doc supports each step.

- [ ] **Step 3.7: Commit**

```bash
git add plugins/app-audits/agents/issue-worker.md
git commit -m "feat(app-audits): issue-worker honors orchestrator branch name + labels PR"
```

---

## Task 4: Add Soft Drain section + drain guards in steady state

**Files:**
- Modify: `plugins/app-audits/commands/do-work.md` (insert new `## Soft drain` section between current `## Steady state (event-driven)` and `## Termination`; add one-line guards to Step C and Step D of steady state)

- [ ] **Step 4.1: Re-read steady state section**

Run: `Read plugins/app-audits/commands/do-work.md` (lines 95-160 in current state, will be different post-Task-1 due to renumber)
Confirm: Step C (Dispatch a replacement) and Step D (Periodic refresh) exist as-described.

- [ ] **Step 4.2: Add drain guard to Step C**

Find the Step C block (`### C. Dispatch a replacement (if work remains)`). Use `Edit` to prepend a guard sentence to the body. Old:

```
### C. Dispatch a replacement (if work remains)

Apply the **dispatch rules** to pick the next job. If a job is dispatched, the slot is filled again immediately. If no compatible job exists (e.g., backlog dry, or every remaining candidate collides with what's still in flight), leave the slot empty — the next completion will trigger another attempt.
```

New:

```
### C. Dispatch a replacement (if work remains)

**If `draining = true`, skip dispatch — the slot stays empty until in-flight empties and the loop terminates.** Otherwise, apply the **dispatch rules** to pick the next job. If a job is dispatched, the slot is filled again immediately. If no compatible job exists (e.g., backlog dry, or every remaining candidate collides with what's still in flight), leave the slot empty — the next completion will trigger another attempt.
```

- [ ] **Step 4.3: Add drain guard to Step D**

Find the Step D block (`### D. Periodic refresh`). Use `Edit` to prepend a guard sentence. Old:

```
### D. Periodic refresh

Every `--concurrency` completions (a full pool's worth), refresh queues in the background:
```

New:

```
### D. Periodic refresh

**Skip during drain — refresh is pointless when no new work will be dispatched.** Otherwise, every `--concurrency` completions (a full pool's worth), refresh queues in the background:
```

- [ ] **Step 4.4: Insert the new `## Soft drain` section before `## Termination`**

Use `Edit` to insert this between the steady-state block and the termination block. Old string is the boundary (last paragraph of steady state + `## Termination` heading):

```
The refresh runs in the same turn as the completion handler — it's a quick burst of read-only `gh` calls plus optional parallel scope dispatches. It does **not** delay the replacement dispatch in step C.

## Dispatch rules (used by step 6 and step C)
```

Wait — `## Dispatch rules` is between steady-state and termination, not at the boundary. The Soft drain section should go between `## Dispatch rules` and `## Termination`. Re-anchor:

Old string (the boundary between Dispatch rules and Termination):

```
Dispatch is via **background agents**: `run_in_background: true`, `isolation: "worktree"`. The harness will notify you on completion — that drives the next iteration of the steady-state loop.

## Termination
```

New string:

```
Dispatch is via **background agents**: `run_in_background: true`, `isolation: "worktree"`. The harness will notify you on completion — that drives the next iteration of the steady-state loop.

## Soft drain

The orchestrator wakes on two kinds of events: agent-completion notifications and new user messages. On user-message turns only, evaluate the new message body — if its entire **trimmed** body matches one of these trigger phrases (case-insensitive, full body only — never as a substring), drain mode is engaged:

- `stop`
- `drain`
- `/do-work stop`

Substring matching is deliberately avoided. Phrases like "don't stop yet" or "I'll drain it later" do not trigger.

**On first trigger:**

1. Acknowledge in chat: *"Draining: N in flight, no new dispatches. Will exit when they finish or settle."* (replace N with the current `in_flight` count).
2. Set `draining = true` in your mental state (or TodoWrite — your call).
3. Steady-state Step A (reconcile) and Step B (release slot) continue normally — in-flight agents must still be properly recorded as they complete.
4. Steady-state Step C (dispatch) and Step D (periodic refresh) become no-ops while `draining = true` (the guards added above handle this).
5. When `in_flight` empties → run the end-of-session drain (CI pending poll, max 15 min) → end-of-session cleanup → end-of-session summary → exit.

**Second trigger** — typing a stop phrase again while already draining — skips the CI pending-poll phase and exits immediately after cleanup. Useful when CI is slow and the user wants out.

**Why this is safe:** agents commit at logical milestones (TDD test → commit, implementation → commit) and PRs are opened with `--auto`. Letting an in-flight agent finish naturally never loses work. Killing it mid-edit could.

## Termination
```

- [ ] **Step 4.5: Scenario trace — "user types 'stop' with 3 agents in flight"**

Mentally walk through:

1. Orchestrator is parked, 3 agents running.
2. User types `stop` and presses enter. Harness delivers it as a new user message turn.
3. Orchestrator's next turn evaluates the message → trigger matched. Sets `draining = true`. Acknowledges in chat.
4. Time passes. Agent 1 completes. Step A reconciles it. Step B releases slot 1. Step C sees `draining = true` and skips. Slot stays empty.
5. Agent 2 completes. Same flow.
6. Agent 3 completes. `in_flight` is now empty. Soft drain section says: run end-of-session drain → cleanup → summary → exit.

Confirm the doc supports each step.

- [ ] **Step 4.6: Scenario trace — "user types 'stop' twice"**

1. After first trigger, orchestrator is draining. 2 in-flight agents.
2. User types `stop` again. Harness delivers another message turn.
3. Soft drain section's "second trigger" rule fires → skip CI pending-poll phase → exit immediately after cleanup (after current in-flight finishes).

Confirm.

- [ ] **Step 4.7: Commit**

```bash
git add plugins/app-audits/commands/do-work.md
git commit -m "feat(app-audits): /do-work graceful drain via 'stop' / 'drain' keyword"
```

---

## Task 5: Update Termination, End-of-session summary, and Don't sections

**Files:**
- Modify: `plugins/app-audits/commands/do-work.md` (Termination at ~line 161, End-of-session summary at ~line 221, Don't section at ~line 235)

- [ ] **Step 5.1: Update Termination to acknowledge drain-mode termination**

Find the Termination section. Use `Edit` to append a paragraph after the bullet list. Old:

```
## Termination

The loop ends when **all of** the following are true at the same time:

- `in_flight` is empty (no agents running),
- `failed_prs` is empty,
- `ready_issues` is empty,
- `raw_backlog` is empty AND a fresh step-3 fetch returns zero new candidates.

Run end-of-session drain → cleanup → summary.
```

New:

```
## Termination

The loop ends when **all of** the following are true at the same time:

- `in_flight` is empty (no agents running),
- `failed_prs` is empty,
- `ready_issues` is empty,
- `raw_backlog` is empty AND a fresh step-3 fetch returns zero new candidates.

**Drain-mode termination**: when `draining = true` (see [Soft drain](#soft-drain)), the loop ends as soon as `in_flight` empties — the other queues are left untouched. The next session will rebuild them.

Run end-of-session drain → cleanup → summary.
```

(Note: the cross-reference to `step-3 fetch` already reflects the post-Task-1 renumber. If you see `step-2 fetch` here, Task 1 step 1.4 was incomplete — fix it.)

- [ ] **Step 5.2: Update End-of-session summary template**

Find the summary template. Use `Edit` to add two new lines — `Recovered from prior session` near the top, `Lifetime via /do-work` at the bottom. Old:

```
```
/do-work session:
Issues processed: N
Shipped: M (#A → PR #X [merged|green|pending], #B → PR #Y [merged|green|pending], ...)
In flight at exit: F (#C → PR #Z still pending CI after drain)
Blocked: K (#P — <reason>, #Q — <reason>)
Errored: J (#R — <agent error>)
Cleaned up: <W> worktrees, <B> branches (merged + remote-deleted)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
```
```

New:

```
```
/do-work session:
Recovered from prior session: <salvaged_count> salvaged → PRs, <abandoned_count> abandoned
Issues processed: N
Shipped: M (#A → PR #X [merged|green|pending], #B → PR #Y [merged|green|pending], ...)
In flight at exit: F (#C → PR #Z still pending CI after drain)
Blocked: K (#P — <reason>, #Q — <reason>)
Errored: J (#R — <agent error>)
Cleaned up: <W> worktrees, <B> branches (merged + remote-deleted)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
Lifetime via /do-work: <I> issues closed, <P> PRs opened (repo-wide totals)
```

The lifetime line is sourced from two queries run just before printing the summary:

```bash
gh issue list --repo <owner/repo> --label do-work --state closed --limit 1000 --json number --jq 'length'
gh pr list --repo <owner/repo> --label do-work --state all --limit 1000 --json number --jq 'length'
```

If either query fails (e.g., the label doesn't exist yet because this is a fresh repo), default to `0`.
```

- [ ] **Step 5.3: Add three new "Don't" rules**

Append to the Don't section. Use `Edit` to add three new bullets at the end of the existing list:

Old (final two existing bullets, used for anchor):

```
- Don't run end-of-session cleanup from inside a worktree — `git worktree remove` on your own checkout fails. Always run from the repo's primary working tree.
- Don't cleanup branches by name or pattern — only by `[gone]` upstream. Anything else risks reaping open or blocked PRs the orchestrator didn't author.
```

New (same two bullets, plus three new ones appended):

```
- Don't run end-of-session cleanup from inside a worktree — `git worktree remove` on your own checkout fails. Always run from the repo's primary working tree.
- Don't cleanup branches by name or pattern — only by `[gone]` upstream. Anything else risks reaping open or blocked PRs the orchestrator didn't author.
- Don't claim a worktree whose branch doesn't match `do-work/*` during orphan triage. That branch is not yours — it could be a developer's WIP.
- Don't run orphan triage while another `/do-work` session may be active on the same repo. Triage is idempotent but parallel salvage on the same orphan wastes work and may produce confusing PR comments. If you suspect a parallel session, ask the user before triaging.
- Don't remove the `do-work` label on block, abandon, or any other outcome. It is write-once. Adding `blocked` / `ci-blocked` alongside it is how block state is signaled — they coexist.
```

- [ ] **Step 5.4: Verify the full Don't list**

Run: `grep -c "^- Don't" plugins/app-audits/commands/do-work.md`
Expected: the count went up by exactly 3 from the pre-edit value.

- [ ] **Step 5.5: Commit**

```bash
git add plugins/app-audits/commands/do-work.md
git commit -m "feat(app-audits): /do-work summary + termination + Don't updates for drain/recovery"
```

---

## Task 6: Final scenario verification + consistency pass

**Files:**
- Read-only review of both modified files; small inline fixes if anything's inconsistent.

This task has no commit unless verification surfaces issues.

- [ ] **Step 6.1: Read both files end-to-end**

Run: `Read plugins/app-audits/commands/do-work.md` (full file)
Run: `Read plugins/app-audits/agents/issue-worker.md` (full file)

- [ ] **Step 6.2: End-to-end scenario A — Hard-kill recovery**

Initial state: A prior session was hard-killed. On disk:
- `worktrees/do-work-issue-42/` with `do-work/issue-42` branch — committed and pushed; PR #100 open with failing CI checks.
- `worktrees/do-work-issue-43/` with `do-work/issue-43` branch — uncommitted edits only, no commits.
- `worktrees/do-work-issue-44/` with `do-work/issue-44` branch — committed but not pushed (1 commit ahead, no remote).
- One issue (#45) self-assigned to @me with `do-work` label but no worktree (agent crashed before its first commit).

Walk through `/do-work` from scratch and confirm the doc would drive the orchestrator to:

1. Setup Step 1: resolve repo + user.
2. Setup Step 2a: idempotent `gh label create do-work ...` succeeds (label already exists).
3. Setup Step 2b: discover three `do-work/*` worktrees.
4. Classify #42: pushed + PR open + failing → push onto `failed_prs`. `salvaged_count = 1`.
5. Classify #43: uncommitted only → remove worktree, unassign issue. `abandoned_count = 1`.
6. Classify #44: committed not pushed → push → no PR exists → `gh pr create --label do-work --fill` → `gh pr merge --auto --squash --delete-branch`. `salvaged_count = 2`.
7. Inconsistency log query finds #45 (labeled + assigned + no PR + no worktree) → log advisory, no auto-action.
8. Setup Step 3: backlog fetch — #43 reappears (now unassigned).
9. Setup Step 4: failing-PR snapshot — finds PR #100 (already in `failed_prs` from step 2b; dedupe to one entry).
10. Setup Step 5/6: scope pre-flight + initial pool fill — first slot goes to PR #100 (fix-checks-only); remaining slots dispatch from `ready_issues`.
11. Steady state proceeds normally.
12. End-of-session summary shows: `Recovered from prior session: 2 salvaged → PRs, 1 abandoned` plus the inconsistency advisory line.

If any step in this scenario is unclear from the doc, fix the doc inline. If everything is clear, no edit needed.

- [ ] **Step 6.3: End-to-end scenario B — Soft drain mid-session**

Initial state: orchestrator running with `--concurrency 3`. All 3 slots active on issues #50, #51, #52. `ready_issues` has 8 more candidates. `failed_prs` has 1 PR (#60).

User types `stop` and hits enter.

Walk through and confirm:

1. Next orchestrator turn fires from the new user message. Soft drain trigger matched (`stop` is the full trimmed body).
2. Orchestrator acknowledges in chat: "Draining: 3 in flight, no new dispatches. Will exit when they finish or settle."
3. Sets `draining = true`.
4. Time passes. Agent on #50 completes (`shipped`). Step A reconciles. Step B releases slot. Step C guard fires → no dispatch. Slot empty.
5. Agent on #51 completes (`blocked`). Step A reconciles → adds `blocked` label. Step B releases slot. Step C no-op.
6. Agent on #52 completes (`shipped`). Step A reconciles. Step B releases. Step C no-op. `in_flight` empty.
7. Soft drain section's terminal flow: end-of-session drain (CI pending poll, max 15 min) → cleanup → summary → exit.
8. PR #60 was never picked up because dispatch was skipped — that's correct, the next session will see it on its own failing-PR snapshot.
9. Summary includes `Lifetime via /do-work: ...` line.

Confirm.

- [ ] **Step 6.4: End-to-end scenario C — Cooperative kill (drain interrupted by Ctrl+C)**

Initial state: drain in progress, 1 agent still in-flight. User loses patience and hits Ctrl+C instead of typing `stop` again.

Walk through and confirm:

1. Session dies. Background agent may or may not be still running (harness behavior).
2. Next `/do-work` invocation. Setup Step 2 runs orphan triage. The mid-drain agent's worktree (if it had committed work) → salvaged. Otherwise → abandoned. Either way, no work is silently lost.

Confirm the doc supports this path through Step 2's classification table.

- [ ] **Step 6.5: Type-consistency / naming-consistency check**

Grep for known names that must match:

```bash
grep -n "do-work/issue\|do-work/fix\|do-work[^-/]" plugins/app-audits/commands/do-work.md plugins/app-audits/agents/issue-worker.md
```

Confirm:
- The branch name is `do-work/issue-<N>` everywhere (never `do-work-issue-N` or `do-work/<N>`).
- The label is `do-work` everywhere (never `do_work` or `doWork`).
- Cross-reference numbering matches (Setup steps 1-6).

```bash
grep -n "step-[0-9]\|step [0-9]" plugins/app-audits/commands/do-work.md
```

Confirm every cross-reference is internally consistent.

- [ ] **Step 6.6: If anything was inconsistent, fix inline and commit**

Only if Step 6.5 or 6.2-6.4 surfaced issues:

```bash
git add plugins/app-audits/commands/do-work.md plugins/app-audits/agents/issue-worker.md
git commit -m "fix(app-audits): tighten /do-work shutdown doc for consistency"
```

Otherwise, no commit. The plan is complete.

---

## Self-review notes

**Spec coverage:** Every section of the spec maps to at least one task —
- Shared foundation: deterministic branch naming → Tasks 2, 3
- Shared foundation: `do-work` label → Tasks 1, 2, 3, 5
- Mechanism 1: soft drain → Task 4
- Mechanism 2: orphan triage → Task 1
- Touchpoints in `do-work.md` → Tasks 1, 2, 4, 5
- Touchpoints in `issue-worker.md` → Task 3
- Edge cases → covered implicitly via Task 6 scenario traces
- Testability → Task 6

**Placeholder scan:** No TBDs, no "implement appropriate X", no abstract "handle errors" without specifics. Every exact `old_string` / `new_string` for edits is included verbatim. Every `gh` and `git` command is fully specified.

**Type consistency:** Branch name is `do-work/issue-<N>` everywhere. Label is `do-work` everywhere. `salvaged_count` and `abandoned_count` are introduced in Task 1 and consumed in Task 5 with matching names.

**Granularity:** Each step is a single concrete action (one `Edit` call, one `grep`, one mental trace, one commit). No step bundles multiple unrelated edits.

**Risk areas worth flagging to the executor:**
- The renumber in Task 1 (current step 5 → 6) is the most error-prone change because cross-references can be missed. Step 1.4 lists them all; if a grep at Step 1.5 surfaces an unfamiliar reference, stop and verify before continuing.
- The `awk` discovery command in Step 1.2 depends on `git worktree list --porcelain` output format. If the repo is using a very old git, the format may differ — verify with a manual `git worktree list --porcelain` on the actual target repo before relying on it.
