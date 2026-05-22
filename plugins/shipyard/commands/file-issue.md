---
description: File a well-formed GitHub issue against the current repo using shipyard's filing conventions (Conventional Commits title, P0/P1/P2 severity, label discovery, duplicate search). Thin entry point — loads the `shipyard:filing-github-issues` skill and asks Claude to draft + file.
argument-hint: <free-form issue description>
---

# /shipyard:file-issue

One-keystroke entry point for filing a well-formed issue against the current repo. Takes a free-form description, hands off to the [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) skill (for title-prefix conventions, label discovery, duplicate search, and the body template) plus [`shipyard:audit-rubrics`](../skills/audit-rubrics/SKILL.md) (for the P0/P1/P2 severity assignment), and files the issue with `gh issue create`.

This command is purely a **UX convenience for the human-in-the-loop case** — auditors already invoke the filing skill directly, and `/shipyard:do-work` workers file follow-up issues from inside their own dispatches. The point here is to give interactive users a discoverable, named action that always routes through the filing conventions instead of relying on Claude to opportunistically notice "file an issue about X" and pick up the skill.

## When to use

- You want to file an issue without remembering the shipyard label conventions, the Conventional Commits title prefix rules, or the body template.
- You'd otherwise type "file an issue about X" and hope Claude picks up the skill — this command makes the routing explicit.
- You're already at the terminal with a thought and want to dump it into the tracker without context-switching to the GitHub UI.

Not the right surface when:

- An auditor or `/shipyard:do-work` worker is filing the issue — those agents invoke the filing skill directly inside their own dispatches.
- You need the audit-key idempotency contract (HTML-comment fingerprint for re-run dedup). That contract is for autonomous audits; the human-driven case here can skip the fingerprint when the description doesn't naturally fit one of the audit dimensions.

## Args

`$ARGUMENTS` is the free-form issue topic — a one-liner, a paragraph, or a multi-line description. Everything after `/shipyard:file-issue` is the description; there are no flags.

```bash
/shipyard:file-issue make /do-work faster when there are no open issues
/shipyard:file-issue /audit security keeps re-filing the same Firebase Storage finding even after the existing issue is closed
/shipyard:file-issue the cost report's --by-issue grouping silently drops issues that were touched in multiple modes
```

## Implementation (what the assistant does when this command runs)

The command is a thin entry point. The assistant's job is to load the filing-github-issues skill and draft + file an issue using its conventions. Concretely:

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

### 4. Draft the title and body

From the user's free-form description:

- **Title**: pick the right Conventional Commits prefix + scope from the filing-github-issues skill's table, then describe the defect or ask concretely. The title should read as something an end user could understand — these titles often become public release notes via release-please.
- **Body**: use the filing-github-issues body template. The `## Finding` section quotes / paraphrases the user's description; `## Why it matters` is one sentence on the impact; `## Suggested approach` is included only if the user's description named one or the implementation path is obvious; `## Acceptance criteria` is a verifiable checklist.

**Skip the `<!-- audit-key=... -->` HTML comment** for this command's filings. The audit-key contract exists to give autonomous re-runs idempotent dedup behavior — humans filing one-off issues via this command don't benefit from it, and inventing audit-keys for human-filed issues would dilute the namespace audit re-runs depend on.

### 5. Run the duplicate search

Before filing, run the duplicate-search pass the filing skill describes — look for open issues whose title or body materially overlaps with the proposed filing. If a strong match exists, surface it to the user with the URL and ask whether to file anyway or skip. Don't auto-skip — the human is the final judge of "is this the same finding?" since their description may carry context the existing issue doesn't.

```bash
# Adapt the search terms from the proposed title
gh issue list --repo "$REPO" --state open --search '<key terms from title>' --json number,title,url --limit 10
```

### 6. File the issue

Use the HEREDOC pattern from the filing skill:

```bash
gh issue create --repo "$REPO" \
  --label "<P0|P1|P2>" \
  --label "<other applicable labels from gh label list>" \
  --title "<conventional-commit title>" \
  --body "$(cat <<'EOF'
## Finding

<paraphrase / quote of the user's description>

## Why it matters

<one-sentence impact>

## Suggested approach

<optional — only if the user named one or it's obvious>

## Acceptance criteria

- [ ] <verifiable outcome>
EOF
)"
```

### 7. Return the issue URL

`gh issue create` prints the URL of the newly-filed issue on success. Print it back to the user as the last line of the response, prefixed with nothing — just the URL on its own line, so terminals render it as a clickable hyperlink:

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
- **Don't apply the `shipyard` label.** That label is the orchestrator's session stamp on PRs it produces — it belongs on `/do-work`-opened PRs, not on issues filed via this command.
