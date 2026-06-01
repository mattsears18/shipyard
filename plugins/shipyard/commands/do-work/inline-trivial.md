# /shipyard:do-work — Inline trivial issues (skip worker dispatch)

A dispatch-time fast path that lets the orchestrator handle very small issues **inline** — open the file, make the edit, commit, push, create the PR, arm auto-merge — without paying the ~13k-token cost of dispatching a full `shipyard:issue-worker` agent. Reads from [`shipyard.config.json`](../../../../CLAUDE.md#configuration-shipyardconfigjson--layered-overrides) under the `inline_trivial` key; default OFF.

Loaded on demand from [`steady-state.md`](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c)'s step 3a (the `ready_issues` branch's eligibility check). The thin entry [`commands/do-work.md`](../do-work.md) stays in context across every phase for the [orchestrator-state struct list](../do-work.md#orchestrator-state); this file owns only the inline-eligibility heuristic and the inline-execution mechanics.

Tracking issue: [#156](https://github.com/mattsears18/shipyard/issues/156). Part of [perf umbrella #152](https://github.com/mattsears18/shipyard/issues/152) — Phase 1.

## When does the inline fast path fire?

Only inside [step 3](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) of the dispatch decision tree (the `ready_issues` branch), as sub-step **3a** evaluated for the candidate **after** collision rules clear but **before** the normal `shipyard:issue-worker` `Agent` tool call.

The fast path is gated on **all** of the following being true:

1. **Config opt-in.** `inline_trivial.enabled == true` from the merged 4-layer config (built-in defaults → `~/.shipyard/config.json` → `<repo>/shipyard.config.json` → `<repo>/.shipyard/config.local.json`). Default: `false` — the fast path is opt-in per repo. The session reads the value once at setup time (it's part of the [setup step 0.4 config load](./setup.md#04-load-shipyard-config)) and caches it in orchestrator-state for the dispatch loop to consume.
2. **Trusted author.** `originating_author_trust == "trusted"` (computed per step 3's [Author-trust computation](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c)). Inline-trivial is **never** eligible for external-author issues — the dispatch-side auto-merge gate from [issue-work step 6](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) is the load-bearing defense against prompt-injection riding auto-merge to `main`, and inline execution would have to re-implement the gate identically. Sidestepping that risk by hard-coding "trusted only" is the conservative call. (Future: revisit if telemetry shows enough external-trivial volume to justify the duplicated gate.)
3. **No label disqualifies.** The candidate carries **none** of:
   - `needs-design`, `needs-triage`, `needs-human-review`, `needs-refinement` — these signal the issue isn't ready for any worker, inline or dispatched.
   - `user-feedback` — these go through the [extra-scrutiny preamble](./steady-state.md#dispatch-rules-used-by-step-7-and-step-c) (must reproduce before fixing); inline can't reproduce.
   - `shipyard:no-inline` — explicit human override forcing normal dispatch. The label is read as plain text, no comment needed. (Reverse of the `shipyard:inline-eligible` override below.)
4. **Body is tiny.** `len(body) <= max_body_chars` (config default: `200`). Markdown is **not** stripped before measuring — a 200-char body that's mostly markdown overhead is too dense to be "tiny" in practice.
5. **No headings.** No line in the body starts with `#` (any heading level). A heading implies the body has structure (`## Acceptance`, `## Open questions`, multi-section spec), and the inline path doesn't reason about structure.
6. **No long code fences.** No ` ``` ` block in the body has more than 10 lines between fences. A code fence longer than 10 lines is a snippet to drop somewhere, not a one-line edit.
7. **Pattern match.** **One** of the following pattern rules matches (case-insensitive on the body, exact on labels and paths):

   | Pattern | Match rule | Example body keywords / signals |
   |---|---|---|
   | **typo** | body mentions `typo` OR `misspelling` OR `rename` AND references a specific file path (matched via `\b[\w./-]+\.\w{1,5}\b` — file with extension) | "typo: 'recieve' → 'receive' in `README.md` line 42" |
   | **dep-bump** | title matches `^(chore\(deps\):|bump\b)` (Dependabot-style or human-style) | "chore(deps): bump zod from 3.22 to 3.23" |
   | **doc-only** | every file path mentioned in the body matches `^docs/.*\.md$` OR `^[\w-]+\.md$` (root `.md` files like `README.md`, `CHANGELOG.md`, `CLAUDE.md`) | "fix link in `docs/setup.md`" |
   | **comment-only** | title contains `add comment` OR `clarify comment` OR `code comment` | "add comment explaining the retry loop in `auth.ts`" |
   | **config-tweak** | every file path in the body matches `^\.github/.*\.yml$` OR `^\.vscode/.*\.json$` OR `^package\.json$` with `dependencies` / `devDependencies` only (no `scripts`, no `overrides`) | "bump `eslint-plugin-jest` in `package.json` devDependencies" |

   Patterns are evaluated in the order above; first match wins. Multiple-match cases (e.g., a typo in a doc file) don't combine — the first pattern that matches dictates the inline-execution branch.

If **any** of (1)–(7) fails, the candidate is **not inline-eligible** — fall through to the normal step-3 dispatch (the full `shipyard:issue-worker` `Agent` tool call). No comment posted, no label changed; the candidate just goes through the slow path like any other.

### Explicit overrides (optional)

Two labels short-circuit the heuristic for humans who already know which path they want:

- **`shipyard:inline-eligible`** — humans pre-applying this label override the pattern-match (rule 7) and the body-length / heading / code-fence checks (rules 4–6). Rules 1–3 still apply: config must be enabled, author must be trusted, and disqualifying labels still disqualify. Useful for testing the inline path or nudging it for issues whose body shape doesn't fit a pattern but whose work is genuinely trivial.
- **`shipyard:no-inline`** — humans pre-applying this label force normal dispatch even for issues that would otherwise pass all 7 rules. Listed in rule 3's disqualifying-labels set. Useful for issues that *look* trivial (e.g., a one-line config tweak) but where the human knows there's hidden complexity (e.g., the config has cascading effects the dispatched worker should investigate properly).

Neither label is auto-applied by shipyard — both are human signals.

## Execution mechanics — inline-eligible candidate

When a candidate passes all 7 rules, dispatch the inline path instead of an `Agent` tool call:

### A. Self-assign and stamp the session label

Same as the normal dispatch path, **before** the first file write:

```bash
gh issue edit <N> --repo <owner/repo> --add-assignee @me --add-label shipyard
```

The self-assign is the soft lock against parallel `/do-work` instances; the `shipyard` label is the session stamp. Both must succeed before any branch or file write — if either errors, abort to worker (see [Abort-to-worker fallback](#abort-to-worker-fallback) below).

### B. Create the work branch

In the orchestrator's existing worktree (the same `agent-<session-id>` worktree the dispatched workers normally use):

```bash
git fetch origin <default-branch>
git switch -c do-work/issue-<N> origin/<default-branch>
```

The branch name matches the worker-dispatched path (`do-work/issue-<N>`) so the PR's head branch is indistinguishable from a dispatched-worker PR. If the branch already exists locally or on the remote, abort to worker (the issue was already attempted — let the worker's pre-flight handle the recovery).

### C. Apply the edit

Branch by which pattern matched in rule 7:

- **typo** — open the named file, find the misspelling (the body's `'wrong' → 'right'` form is the canonical pattern), apply the exact substitution via the `Edit` tool. Verify the substitution happened exactly once unless the body specifies a count.
- **dep-bump** — open `package.json`, locate the named dependency, update the version range as specified in the title (e.g., `3.22` → `3.23`). Update `package-lock.json` via `npm install --package-lock-only` (no fetch, no full install — just regenerate the lockfile against the new range). If `npm install --package-lock-only` errors or modifies more than the bumped dep's transitive closure, abort to worker.
- **doc-only** — open the named markdown file(s), apply the edit as described in the body. Markdown link fixes (`[text](broken-url)` → `[text](correct-url)`) and one-line wording tweaks are the typical shape.
- **comment-only** — open the named source file, locate the function / block the body references, add the comment as a JSDoc / docstring / `//` comment. Don't touch any logic — if the edit would change a non-comment line, abort to worker.
- **config-tweak** — open the named config file(s), apply the edit. For `.github/*.yml` and `.vscode/*.json`, validate the file still parses (`yq` / `jq` or equivalent) after the edit; for `package.json`, validate via `node -e "JSON.parse(require('fs').readFileSync('package.json'))"`.

After the edit, run minimal verification:

- A linter is configured for the file's extension (e.g., `.eslintrc` exists for `.ts/.tsx/.js`, `.prettierrc` for any text file)? Run the linter scoped to the changed file(s) only — never the full repo. If lint errors are introduced, abort to worker.
- No full test suite, no full build. The inline path is for changes too small to need either; if either would meaningfully validate the change, the change isn't inline-eligible.

### D. Commit, push, open the PR

```bash
git add <changed-files>
git commit -m "<commit-message>"
git push -u origin do-work/issue-<N>

gh pr create --repo <owner/repo> --label shipyard \
  --title "<pr-title>" \
  --body "<pr-body-with-closes-line>"
```

Commit message: subject line matches the issue title (or a clean truncation if the issue title has long context). PR title: same shape as worker-produced PRs (e.g., `fix(docs): typo in README — recieve → receive (closes #N)`). PR body MUST include `Closes #<N>` on its own line (case-insensitive) so the issue auto-closes on merge — same contract as worker-produced PRs. Include a one-line tag at the bottom of the body: `Opened via inline-trivial fast path (skipped worker dispatch — see #156).` — makes the inline-vs-dispatched provenance visible to reviewers.

### E. Arm auto-merge

Same as the worker-dispatched path's [issue-work step 6](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust). Since rule 2 of the eligibility check guarantees `originating_author_trust == "trusted"`, only the trusted branch applies:

```bash
gh pr merge <pr-num> --repo <owner/repo> --auto --merge --delete-branch
```

Then re-snapshot `state` and `autoMergeRequest` per the [worker-preamble auto-merge categorization](../../skills/worker-preamble/SKILL.md#auto-merge--snapshot-and-return-pattern) (issue [#340](https://github.com/mattsears18/shipyard/issues/340)) — `gh` silently direct-merges on repos with `allow_auto_merge: false` when the dispatching user has admin permissions, so categorize the actual outcome from the post-call state, not from the merge call's exit status alone. The base outcomes — `enabled`, `merged-direct`, and `unavailable` — surface in the inline-path summary the same way they surface in the worker-path return string. **Refine `merged-direct` → `merged-direct-ungated` using step F's check-rollup snapshot** (issue [#457](https://github.com/mattsears18/shipyard/issues/457)): if the PR direct-merged while its checks were still `pending`/`failing` (a repo with no required status checks), it landed ungated and may yet flip `main` red — surface it as `merged-direct-ungated` and treat it as a [trigger-1 unconditional refresh](./steady-state.md#d-periodic-refresh) so the main-CI divert watches the merge commit. If `merged-direct` (green-gated) or `unavailable`, log it for the end-of-session summary and continue.

### F. Reconcile in-line (no `Agent` notification to wait on)

Inline execution has no agent return to reconcile in [step A](./steady-state.md#a-reconcile-the-return) — the orchestrator IS the worker for this slot. Perform the reconcile actions inline:

- Append `<M>` to `session_prs`.
- Take a single check-rollup snapshot (`gh pr view <M> --json statusCheckRollup,mergeStateStatus`) — record the `checks: green|pending|failing` state for the cost-tracking comment.
- Post the cost-tracking comment via the same [edit-or-create flow as `shipped` returns](./steady-state.md#a-reconcile-the-return). Use the helper:
  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
  "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read-tokens \
    --session-id "<session-id>" --pr <M> --format comment --mode inline
  ```
  The `--mode inline` flag stamps the comment body with `mode=inline` instead of `mode=<worker-mode>` — telemetry needs to distinguish inline-shipped from worker-shipped PRs for the [abort rate metric](#telemetry).
- The slot is **already free** the moment inline execution returns — no `in_flight` entry was ever created, no `claimed_paths` were ever claimed. Skip step B's release. The next dispatch tick proceeds normally.

The invariant line for the inline-dispatch turn reflects `dispatched_this_turn=1` (the inline ship counts as a dispatch — a PR went out) and `state=written` (the cost-tracking write-through happened normally).

## Abort-to-worker fallback

When **any** step in §A–E fails — self-assign 404s, branch already exists, the edit modifies more lines than expected, the linter reports a new error, `npm install --package-lock-only` modifies non-bumped deps, `gh pr create` rejects the request, etc. — abort the inline path and fall through to normal worker dispatch.

**Abort cleanup (in order):**

1. Revert any local file changes the inline attempt made (`git reset --hard origin/<default-branch>` from the inline branch; if the branch was already pushed, leave the remote branch — the worker's pre-flight will pick it up and rebase / push-force as needed).
2. Delete the local branch if it was created (`git switch <orchestrator-default-branch>` then `git branch -D do-work/issue-<N>`).
3. Don't remove the self-assign or the `shipyard` label — they're correct for the worker dispatch that follows.
4. Log to the session summary: `[inline-trivial] abort #<N> at step <A|B|C|D|E>: <reason>; dispatched worker instead.`
5. Dispatch the worker via the normal step-3 path (the same `Agent` tool call that would have fired if the inline check had returned ineligible).

**Important:** the abort is **per-candidate**, not per-session. A single abort doesn't disable inline-trivial for the session — the next inline-eligible candidate gets evaluated normally. If the **per-session abort rate** exceeds 30% (computed across all candidates that entered the inline branch this session), the heuristic is too aggressive — log a session-end advisory recommending tightening rule 7's patterns or lowering `max_body_chars`. The orchestrator does NOT disable inline-trivial mid-session on a high abort rate; the human reads the advisory and adjusts config for the next session.

## Telemetry

Inline execution writes to the same [cost-tracking ledger](../do-work.md#cost-tracking-write-through) as worker-dispatched issues, with one extra field on each inline-ship entry: `mode: "inline"` (vs `mode: "issue-work"` for the worker-dispatched path). The session-end summary surfaces:

- Count of inline-eligible vs dispatched workers (per session).
- Cost-per-issue comparison: inline mode vs full-worker mode, computed from the cost ledger's `mode` rollup.
- Abort rate: `<inline-aborted> / <inline-attempted>`. The session-end advisory fires when this exceeds 30%.

`/shipyard:cost report --by-mode` exposes the same rollup across sessions for tuning the heuristic over multiple runs.

## Don't

- **Don't run the inline path on external-author issues.** Rule 2 hard-codes "trusted only" specifically to keep the [auto-merge gate](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) out of inline scope. If telemetry later justifies an external-author inline branch, it goes through a separate eligibility tree with the gate explicitly re-implemented — not a relaxation of this rule.
- **Don't expand the patterns to "anything small."** Rule 7's pattern set is intentionally narrow. A candidate that doesn't fit one of the five named patterns is a candidate the orchestrator can't reason about safely without dispatching a worker. The fix for "this kind of trivial change isn't supported" is to add a sixth pattern with its own execution branch in §C, not to weaken rule 7 into a general-purpose "small change" check.
- **Don't run the full test suite or full build.** The inline path is for changes too small to need either. If a change actually wants a test run to validate, dispatch a worker — the worker's TDD step is the right place for that work.
- **Don't try to recover from a mid-execution failure inline.** Any failure in §A–E aborts to worker. The orchestrator's context isn't designed to hold the "I tried X, got Y, now retry with Z" loop a worker handles natively.
- **Don't skip the cost-tracking comment.** Inline shipping must show up on the PR with the same sentinel comment the worker-dispatched path posts — otherwise cost reports double-count by missing the inline volume and the human can't audit which PRs took which path.
- **Don't run inline-trivial during the drain phase.** The [end-of-session drain](./drain.md#end-of-session-drain) is post-dispatch — no new issue work starts during drain. Inline-trivial is purely a steady-state phenomenon.
