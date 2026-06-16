---
description: Research, refine, and file a dispatch-ready GitHub issue against the current repo using shipyard's filing conventions (Conventional Commits title, P0/P1/P2 severity, label discovery, duplicate search). Inspects the codebase so the issue lands ready for /do-work — never starts the work. Pass --quick to skip research and file a thin issue.
argument-hint: [--quick] <free-form issue description>
---

# /shipyard:file-issue

The named entry point for filing a well-formed, **dispatch-ready** issue against the current repo. Takes a free-form description, searches for related/duplicate issues, **researches the codebase** so the issue is concrete, **refines it to dispatch-readiness** (so the next `/shipyard:do-work` session can pick it up as-is), and files it with `gh issue create` — handing off to the [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) skill (for title-prefix conventions, label discovery, duplicate search, and the body template) and [`shipyard:audit-rubrics`](../skills/audit-rubrics/SKILL.md) (for the P0/P1/P2 severity assignment).

This is the codified version of the interactive **"file an issue — <description>"** workflow: search → research → refine → file, stopping short of any implementation. It gives interactive users a discoverable, named action that always routes through the filing conventions *and* produces an issue `/do-work` can act on, instead of relying on Claude to opportunistically notice "file an issue about X" and reproduce the routine by hand. Auditors already invoke the filing skill directly, and `/shipyard:do-work` workers file follow-up issues from inside their own dispatches — this command is for the human-in-the-loop case.

**This command files only. It never starts the work** — no branch, no PR, no code edits. Producing a dispatch-ready issue is the deliverable; implementing it is a separate `/shipyard:do-work` session.

Pass **`--quick`** to skip the research + refinement passes and file a thin issue straight from the description (the original fast-path behavior) — useful when you just want to dump a thought into the tracker and let `/do-work`'s own scope-preflight refine it later.

## When to use

- You want to file an issue without remembering the shipyard label conventions, the Conventional Commits title prefix rules, or the body template.
- You'd otherwise type "file an issue about X" and hope Claude picks up the skill — this command makes the routing explicit.
- You want the issue to land **ready for `/do-work`** — researched against the actual codebase, with concrete acceptance criteria — rather than a vague stub a human has to refine later.
- You're already at the terminal with a thought and want to dump it into the tracker without context-switching to the GitHub UI (use `--quick` if you don't want the research pass).

Not the right surface when:

- An auditor or `/shipyard:do-work` worker is filing the issue — those agents invoke the filing skill directly inside their own dispatches.
- You need the audit-key idempotency contract (HTML-comment fingerprint for re-run dedup). That contract is for autonomous audits; the human-driven case here can skip the fingerprint when the description doesn't naturally fit one of the audit dimensions.
- You want the work *done*, not just filed. This command stops at a dispatch-ready issue — run `/shipyard:do-work` to implement it.

## Args

`$ARGUMENTS` is the free-form issue topic — a one-liner, a paragraph, or a multi-line description — optionally preceded by the `--quick` flag.

- **`--quick`** (optional, leading flag): skip the codebase research pass and the dispatch-readiness refinement; draft and file a thin issue straight from the description. Strip the flag from `$ARGUMENTS` before treating the rest as the description.
- Everything else after `/shipyard:file-issue` (and after `--quick`, if present) is the description.

```bash
/shipyard:file-issue make /do-work faster when there are no open issues
/shipyard:file-issue /audit security keeps re-filing the same Firebase Storage finding even after the existing issue is closed
/shipyard:file-issue --quick the cost report's --by-issue grouping silently drops issues that were touched in multiple modes
```

## Implementation (what the assistant does when this command runs)

The assistant's job: search for duplicates, **research the codebase**, **refine the issue to dispatch-readiness**, and file it via the filing-github-issues conventions — without starting any implementation. Concretely:

### 1. Resolve the target repo

Resolve the current repo from the cwd's git remote, **not from a hardcoded value**. The user might be running this from inside any repo that has shipyard installed.

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
```

**Refuse gracefully** if either of the following is true — return a clear single-line error and exit cleanly, do NOT prompt the user to enter a repo manually:

- Not inside a git repo (the `gh repo view` call errors with "not a git repository" or `git rev-parse --show-toplevel` fails).
- The current git repo has no GitHub remote configured (the `gh repo view` call errors with "no default remote" or "not a github repository").

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
  echo "/shipyard:file-issue must run inside a git repo with a GitHub remote configured."
  exit 1
}
```

Also parse a leading **`--quick`** flag off `$ARGUMENTS`: if the first token is `--quick`, set quick-mode and strip it, treating the remainder as the description. In quick mode, skip steps 5 (research) and 7 (refine to dispatch-ready) and file a thin issue straight from the description.

### 2. Load the filing-github-issues skill

The skill at [`plugins/shipyard/skills/filing-github-issues/SKILL.md`](../skills/filing-github-issues/SKILL.md) owns:

- Conventional-commit title prefix rules (`fix(<scope>):`, `feat(<scope>):`, `docs(<scope>):`, etc.)
- Label discovery (`gh label list`, apply existing labels; don't create new ones autonomously)
- Duplicate search before filing (so the human doesn't accidentally file a second copy of an open issue)
- Body template (`## Finding` / `## Why it matters` / `## Suggested approach` / `## Acceptance criteria`)
- The `gh issue create` HEREDOC pattern

Read that skill's rules and follow them. **Don't duplicate the rules into this command body** — the skill is the single source of truth; this command is the entry point.

### 3. Load the audit-rubrics skill for severity assignment

The skill at [`plugins/shipyard/skills/audit-rubrics/SKILL.md`](../skills/audit-rubrics/SKILL.md) defines the P0/P1/P2 severity buckets:

- **P0** — broken / unusable / security / release-blocker
- **P1** — significant friction or risk, must ship this cycle
- **P2** — polish or moderate risk, normal planned work

Pick the appropriate severity based on the user's description and apply the matching label (the labels `P0`, `P1`, `P2` already exist in `mattsears18/shipyard` and in other shipyard-using repos that have run `/shipyard:init`). When in doubt, default to **P2** — the user can re-label after the fact, and over-flagging a tracker as P0 erodes the priority signal.

### 4. Search for related / duplicate issues

Before investing in research or drafting, run the duplicate-search pass the filing skill describes — look for open issues whose title or body materially overlaps with the user's description. If a strong match exists, surface it to the user with the URL and ask whether to file anyway or skip. Don't auto-skip — the human is the final judge of "is this the same thing?" since their description may carry context the existing issue doesn't.

```bash
# Adapt the search terms from the user's description
gh issue list --repo "$REPO" --state open --search '<key terms>' --json number,title,url --limit 10
```

### 5. Research the codebase (skip in `--quick` mode)

This is what makes the filed issue **dispatch-ready** rather than a vague stub. Before drafting, investigate the actual code/config the description touches so the issue cites ground truth, not assumptions:

- **Locate the relevant surface** — grep/read the files, commands, scripts, or config the description implicates. Name them by path.
- **Confirm current behavior** — read the code well enough to describe what actually happens today (the bug's mechanism, the missing feature's absence), and verify the premise of the request still holds. Freshly read every artifact you'll cite — per the filing skill's "Verify before you file" gate, don't file claims you didn't confirm this session.
- **Sketch a plausible implementation path** — identify which file(s) would change and roughly how, enough to make the issue actionable. You are NOT implementing — just scoping.
- **Note constraints** — adjacent behavior that must not regress, related issues/PRs (reference only issue numbers you verified this session), config or release implications.

Keep this proportionate to the issue's size — a one-line config fix needs a quick grep; a cross-cutting change needs more. The goal is an issue a `/do-work` worker can pick up without a human refinement round-trip.

### 6. Draft the title and body

Fold the research findings into the draft:

- **Title**: pick the right Conventional Commits prefix + scope from the filing-github-issues skill's table, then describe the defect or ask concretely. The title should read as something an end user could understand — these titles often become public release notes via release-please.
- **Body**: use the filing-github-issues body template. `## Finding` states the problem with the **concrete evidence from step 5** (file paths, current behavior) — not just a paraphrase of the description; `## Why it matters` is one sentence on the impact; `## Suggested approach` names the implementation path the research surfaced (which files, roughly how); `## Acceptance criteria` is a verifiable checklist (see step 7). In `--quick` mode there's no research to fold in — `## Finding` paraphrases the description and `## Suggested approach` is included only if the description named one.

**Skip the `<!-- audit-key=... -->` HTML comment** for this command's filings. The audit-key contract exists to give autonomous re-runs idempotent dedup behavior — humans filing one-off issues via this command don't benefit from it, and inventing audit-keys for human-filed issues would dilute the namespace audit re-runs depend on.

### 7. Refine to dispatch-readiness (skip in `--quick` mode)

The default goal is an issue `/shipyard:do-work` can pick up **as-is**. Before filing, check:

- **Concrete, verifiable acceptance criteria** — each box is something a worker can objectively check off (and, where relevant, a regression guard for adjacent behavior the research flagged). Vague criteria ("make it better") mean the issue isn't ready.
- **No gate label by default.** A dispatch-ready issue must NOT carry `needs-triage` or `needs-human-review` — those labels exclude it from `/do-work`'s dispatch fetch. Do not apply them when the research produced a concrete, actionable issue.
- **Gate only when genuinely not ready.** If — after the research pass — the work truly can't be made dispatch-ready (it hinges on a product/design decision, depends on an external party, or is epic-sized and needs decomposition), then apply the appropriate gate label and **state the reason in the issue body and your return summary**. This is the exception, not the default; prefer resolving the ambiguity during research over punting it to a gate label. See the repo's label conventions (`needs-human-review` for human-decision/epic/external-dependency; `needs-triage` as the transitional parking label) before choosing.

### 8. File the issue

Ensure the `shipyard` provenance label exists first (idempotent — never errors if already present), then file using the HEREDOC pattern from the filing skill with `--label shipyard` included:

```bash
# Ensure the shipyard provenance label exists before filing.
gh label create shipyard --repo "$REPO" \
  --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true

Include any gate label from step 7 (`--label needs-human-review` / `--label needs-triage`) **only** in the exception case where the research showed the issue can't be made dispatch-ready — otherwise omit gate labels so the issue stays dispatchable:

```bash
issue_url=$(gh issue create --repo "$REPO" \
  --label shipyard \
  --label "<P0|P1|P2>" \
  --label "<other applicable labels from gh label list>" \
  --title "<conventional-commit title>" \
  --body "$(cat <<'EOF'
## Finding

<the problem, with concrete evidence from the research pass — file paths, current behavior>

## Why it matters

<one-sentence impact>

## Suggested approach

<the implementation path the research surfaced — which file(s), roughly how>

## Acceptance criteria

- [ ] <verifiable outcome>
- [ ] <regression guard for adjacent behavior, if the research flagged any>
EOF
)")
```

### 9. Return the issue URL

`gh issue create` prints the URL of the newly-filed issue on success. Print it back to the user as the last line of the response, prefixed with nothing — just the URL on its own line, so terminals render it as a clickable hyperlink. If a gate label was applied (the exception case), say so and why:

```
Filed as <P1>: <conventional-commit title>
https://github.com/mattsears18/shipyard/issues/218
```

## Refuse gracefully

The command must produce a clear single-line error and exit cleanly (not crash, not stack-trace) if any of the following preconditions fails:

- **Not in a git repo.** `gh repo view` (or `git rev-parse --show-toplevel`) errors. Return: `/shipyard:file-issue must run inside a git repo with a GitHub remote configured.`
- **No GitHub remote configured.** `gh repo view --json nameWithOwner` returns empty / errors. Return: `/shipyard:file-issue must run inside a git repo with a GitHub remote configured.`
- **`gh` not authenticated.** `gh auth status` errors. Return: `/shipyard:file-issue requires gh to be authenticated — run \`gh auth login\` and retry.`
- **Empty `$ARGUMENTS`.** The user typed `/shipyard:file-issue` with no description. Return: `/shipyard:file-issue requires an issue description — usage: /shipyard:file-issue <free-form description>`

Do NOT prompt the user to enter values interactively for these failure modes — the command is a one-shot entry point, not a multi-turn wizard. If the preconditions aren't met, the user is better served by a clear error and the chance to fix the environment than by an interactive prompt that's easy to misread.

## Related

- [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) — title prefix conventions, label discovery, duplicate search, body templates, the `gh issue create` HEREDOC pattern.
- [`shipyard:audit-rubrics`](../skills/audit-rubrics/SKILL.md) — P0/P1/P2 severity buckets, grouping rules, what NOT to file.
- [`/shipyard:audit`](./audit.md) — autonomous audit dispatch. Each auditor invokes the filing skill directly inside its own dispatch.
- [`/shipyard:my-turn`](./my-turn.md) — survey what's blocked on **you** across PRs and issues. Pairs with this command — file what you notice, then read what needs your attention.

## Don't

- **Don't hardcode the target repo.** Resolve from `gh repo view` in the cwd. The command should work in any repo where shipyard is installed and `gh` is authenticated.
- **Don't create new labels autonomously.** The filing-github-issues skill's "don't auto-create labels" rule applies — use existing labels via `gh label list`, and if a label the user's description naturally maps to doesn't exist, mention it in the return summary so the user can decide whether to add the label (and re-file with it) themselves.
- **Don't add an `audit-key` HTML comment.** That contract is for autonomous re-runs of the audit family — human-filed issues from this command shouldn't claim audit-key fingerprints.
- **Don't prompt for missing args interactively.** If `$ARGUMENTS` is empty or the preconditions fail, return a clear error and exit. The command is a one-shot.
- **Don't file the issue without running the duplicate search first.** The skill mandates it; this command must respect it. If a strong duplicate is found, surface it and let the user decide.
- **Don't start the work.** This command files only — no branch, no PR, no code edits, no implementation. Producing a dispatch-ready issue is the entire deliverable; `/shipyard:do-work` does the implementation.
- **Don't apply a gate label by default.** A researched, dispatch-ready issue must not carry `needs-triage` or `needs-human-review` — those exclude it from `/do-work`. Apply a gate label only in the exception case where the research showed the work genuinely can't be made ready, and state the reason. Prefer resolving ambiguity during the research pass over punting it to a gate.
- **Don't skip the research pass** unless the user passed `--quick`. The dispatch-ready outcome depends on the issue citing real codebase ground truth — file claims you freshly confirmed this session, never assumptions.
- **Do apply the `shipyard` label** — it is the provenance stamp on every artifact shipyard creates (issues AND PRs, per [#573](https://github.com/mattsears18/shipyard/issues/573)). Use the ensure-then-label pattern: run `gh label create shipyard --repo "$REPO" --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true` before the `gh issue create` call, then pass `--label shipyard` on the create. See the `shipyard:filing-github-issues` skill's "shipyard provenance label" section for the full pattern including the verify step.
