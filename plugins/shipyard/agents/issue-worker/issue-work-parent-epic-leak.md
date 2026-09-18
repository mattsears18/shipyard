# issue-work.md § 5.85 — Post-PR-create non-close parent/epic leak verification

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's §5.85 stub says the trigger condition is met — see [#980](https://github.com/mattsears18/shipyard/issues/980) for why this content moved out of the always-loaded core.

Closes [#624](https://github.com/mattsears18/shipyard/issues/624) — the **silent-epic-close** failure mode, the inverse of §5.8's stuck-open. This guard is the *enforcement* of the bare-URL-phrasing guidance in [§5](./issue-work.md#5-commit--push--pr); §5.8 asserts the dispatched issue `#<N>` *is* a closing reference, this step asserts a "do NOT close" issue `#<E>` is *not*.

**When this step applies.** Whenever this PR must reference — but NOT close — some issue `#<E>` on merge. Five shapes trigger it: (1) a **parent/epic relationship** named in the dispatch prompt or issue body — phrasing like *"do NOT close #<E>"*, *"reference but don't close #<E>"*, *"Part of #<E>"* / *"Parent epic #<E>"*; (2) **`#<E>` is the dispatched issue itself**, when you're opening a *secondary/auxiliary* PR that ships partial or adjacent value without resolving the dispatch — e.g. a `blocked`-shaped investigation outcome where you additionally shipped a valuable but non-resolving docs/runbook change (the [#893](https://github.com/mattsears18/shipyard/issues/893) repro); (3) **a scope-preflight operator-slice split dispatch** ([#851](https://github.com/mattsears18/shipyard/issues/851)) — the dispatch prompt's Context block carries an "Operator residual" paragraph (set when [scope-preflight's operator-slice carve-out](../../commands/do-work/setup/06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851) found a phase-1 code slice inside an otherwise-`agent-console`/security-flavored `needs-human-review` candidate); (4) **a disposition change on the SAME PR that opened as `#<N>`'s own resolving PR** ([#1001](https://github.com/mattsears18/shipyard/issues/1001)) — §5.8 already confirmed `#<N>` registered a real closing link (not merely at risk of one), and a later finding in the same dispatch — most often a post-open validation/landing-gate check whose result disproves the issue's premise — determines the PR must NOT close `#<N>` after all; (5) **a worker-recognized deferred-slice split dispatch** ([#986](https://github.com/mattsears18/shipyard/issues/986)) — mid-implementation you recognize the [§6.7](./issue-work.md#67-deferred-slice-disposition-hand-back-an-autonomously-workable-residual-to-a-new-issue-keep-the-issue-open-986) shape: a session-scoped, dispatch-level file-ownership constraint in your Context block (not set by any scope-preflight carve-out) blocked part of the issue's acceptance criteria, and the deferred remainder needs no human. Shapes (3) and (5) are both special cases of shape (2) — `#<N>`, the dispatched issue itself, is the protected issue, because this PR ships only a completable slice and a residual still remains on the SAME issue; treat either exactly like shape (2) below, then continue to §6.5 ([`issue-work-split-dispatch.md`](./issue-work-split-dispatch.md)) or §6.7 ([`issue-work-deferred-slice-dispatch.md`](./issue-work-deferred-slice-dispatch.md)) respectively after auto-merge is armed. The two differ only in where the residual goes: (3) hands it to a human/operator via a gate label on `#<N>`; (5) hands it to a brand-new, ungated follow-up issue and leaves `#<N>` unlabeled. Shape (4) is different in kind from (1)–(3) and (5): those all *prevent* a leak from ever registering; shape (4) *retracts* a closing link that already registered correctly, per §5's normal flow, before the disqualifying finding arrived. Collect every such `#<E>` into a set of *protected issues*. If no non-close relationship is in scope (the common case — most PRs are the single resolving PR for their dispatched issue), **skip this step entirely**; it's a no-op. This step never applies to the dispatched issue's own *resolving* PR — that one is supposed to close `#<N>` via `Closes #<N>` per §5, and shapes (3), (4), and (5) are explicitly the exceptions: under (3) and (5) this PR was never that issue's resolving PR to begin with; under (4) it *was*, until the disqualifying finding arrived mid-dispatch.

**Prevention — never name a protected-issue-referencing PR's branch `do-work/issue-<E>` (or any `issue-<E>`-shaped variant).** [#893](https://github.com/mattsears18/shipyard/issues/893) isolated a *branch-naming* hazard distinct from the body/commit-text hazard below: GitHub's own "Create a branch" UI auto-links a branch literally named `do-work/issue-<E>` to issue `#<E>`, and in the repro that link registered in `closingIssuesReferences` **independent of the PR body or commit-message text** — it survived a full body rewrite, a commit-message rewrite + force-push, and even a close+reopen, and only cleared once the PR was abandoned for a fresh, neutrally-named branch. If you already know before opening the PR that it must not close `#<E>`, don't give its branch an `issue-<E>`-shaped name even when `<E>` happens to be the number you were dispatched against — pick a neutral name instead (e.g. `docs/<short-topic>`), off the default branch. This sidesteps the remediation loop below entirely; it's cheaper than recovering from the leak. **When the orchestrator already knows the dispatch is a split** — the candidate carried `operator_residual` or `verification_slice` — it now hands you a neutral `do-work/slice-<N>` branch up front and says so in a Context paragraph ([#1562](https://github.com/mattsears18/shipyard/issues/1562)); take that name verbatim and don't rename it. The two shapes that reach this file with a canonical `do-work/issue-<E>` name anyway are a parent/epic reference (`<E>` ≠ your dispatched `<N>`, so your own branch name is not the vector) and the mid-implementation deferred-slice split ([#986](https://github.com/mattsears18/shipyard/issues/986)), which nothing predicts at dispatch time — that one still needs the tiered remediation below.

**Prevention — never let a closing-keyword-shaped word share a line with the reference, even to negate it ([#990](https://github.com/mattsears18/shipyard/issues/990)).** The bare-URL form (§5's prevention, above) stops a `#<E>` *token* from auto-promoting, but it does NOT stop GitHub's parser from matching a closing-keyword-shaped word (`close(s|d)?`, `fix(es|ed)?`, `resolve(s|d)?`) that appears in the same sentence or line as the URL — including a sentence that's explicitly *negating* the close, like *"This PR does NOT close `<URL>`"*. The parser has no negation awareness: that sentence still registers `#<E>` as a closing reference. Don't write around this with careful phrasing — keep any closing-keyword-shaped word off the line that carries the reference entirely (a separate sentence, or a neutral synonym like "addresses"/"references"/"tracks"). This is a *different* leak vector from the bare-`#<E>`-token one the URL form fixes, so a body that's already "clean" in the token sense can still leak this way — treat the check below as covering both.

**The mechanism the remediation loop guards.** GitHub can promote a bare `#<E>` token (in the PR body, a squashed-commit message, or a CHANGELOG entry that rides the merge) into `closingIssuesReferences` even with no closing keyword — so the merge auto-closes the protected issue. The same is true of a closing-keyword-shaped word sharing a line with an already-URL-form reference (above). The §5 prevention is to phrase the reference as a bare URL AND keep keyword-shaped words off its line; this step verifies the prevention took and, if it leaked, escalates through three remediation tiers.

**Verification staleness — a single `closingIssuesReferences` read taken right after `gh pr create` can be stale, and the failure direction it produces is the dangerous one ([#982](https://github.com/mattsears18/shipyard/issues/982)).** GitHub computes `closingIssuesReferences` by parsing the PR body/commits *after* the PR object itself exists, so the very first read can come back empty even though the link registers moments later — a repro read the field as clean seconds after `gh pr create`, only for the protected issue to close on merge anyway. Because this is a **false negative** — the check reports "clean" when it isn't — it's worse than a false positive: a worker that trusts one immediate empty read and arms auto-merge never gets a second chance before the merge silently closes the protected issue. Two changes address this, both implemented by the `check_closing_ref` helper used throughout the verification below:

1. **Never trust a single read taken immediately after `gh pr create` (or after a `gh pr edit` / `git push --force-with-lease` remediation).** Re-read a few seconds later and require two consecutive reads to agree before trusting an empty ("not leaked") result — a leak that shows up on *either* read counts as leaked, since a transient `true` is real evidence the link registered even if a later read goes back to `false`.
2. **Query `closingIssuesReferences` directly via `gh api graphql`, not `gh pr view --json`.** `gh pr view --json closingIssuesReferences` resolves through the same underlying GraphQL field, but routing through `gh pr view`'s own object-resolution path adds a layer between you and the raw API response; querying directly removes that layer and gives a query you can re-run byte-for-byte to compare consecutive reads. Use this in place of `gh pr view --json closingIssuesReferences` for every epic check below.

**Why this doesn't also change §5.8's own dispatched-issue check.** §5.8 verifies the *opposite* direction — that the PR's own issue `#<N>` DOES register as a closing reference — and its corrective action on a "false" read is to prepend an explicit `Closes #<N>` line, which is idempotent and harmless to over-apply. A stale-false read there just costs one redundant, safe edit, not a silent wrong outcome; §5.8 runs on *every* PR this worker opens, so paying this check's ~5-10s retry cost there would tax the common case to guard a low-severity failure. §5.85 only runs when a protected issue is genuinely in scope, and a stale-false read there arms auto-merge on a leak with no corrective action at all — that asymmetry is why the retry-and-direct-query treatment belongs here and not in §5.8.

```bash
# Direct-GraphQL, stale-read-resistant check for whether issue <E> is present
# in PR <pr>'s closingIssuesReferences (#982). Reads twice, a few seconds
# apart, and treats a leak surfacing on EITHER read as real — the field is
# computed asynchronously after PR create/edit, so a single immediate read
# can come back empty (a false negative) even when the link registers
# moments later.
check_closing_ref() {
  local pr="$1" repo="$2" epic="$3"
  local owner="${repo%%/*}" name="${repo##*/}"
  local query='
    query($owner: String!, $name: String!, $num: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $num) {
          closingIssuesReferences(first: 50) { nodes { number } }
        }
      }
    }'
  local jq_expr="[.data.repository.pullRequest.closingIssuesReferences.nodes[].number] | index($epic) != null"
  local first second
  first=$(gh api graphql -f query="$query" -F owner="$owner" -F name="$name" -F num="$pr" --jq "$jq_expr")
  sleep 5
  second=$(gh api graphql -f query="$query" -F owner="$owner" -F name="$name" -F num="$pr" --jq "$jq_expr")
  if [ "$first" = "true" ] || [ "$second" = "true" ]; then
    echo "true"
  else
    echo "false"
  fi
}
```

**After `gh pr create` and before arming auto-merge in [§6](./issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust)**, for each protected issue `#<E>` assert it is absent from the PR's `closingIssuesReferences`. If it leaked, run the tiers below **in order and don't stop early** — the [#893](https://github.com/mattsears18/shipyard/issues/893) repro showed a leak surviving a single body-rewrite-and-reverify (what an earlier version of this step stopped at) as well as a follow-up commit-message rewrite, so a worker that re-verifies once and declares victory, or that gives up after one rewrite and jumps straight to `needs-human-review`, is not exercising the full documented recovery path:

```bash
# Re-derive WORKTREE_PATH per worker-preamble § "Worktree-reaped escape hatch".
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
CURRENT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ ! -d "$WORKTREE_PATH" ] || [ "$CURRENT_TOPLEVEL" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --abbrev=12 --format='%h' 2>/dev/null)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi

# <E> is each protected issue number collected above. Run this block per issue.
CURRENT_PR=<pr-num>
LEAKED=$(check_closing_ref "$CURRENT_PR" <owner/repo> <E>)

# --- Tier 1: rewrite the PR body to bare-URL form, AND strip any
# closing-keyword-shaped word sharing a line with the reference (#990 —
# GitHub's parser matches the keyword adjacent to a reference with no
# negation awareness, so "does NOT close <URL>" still registers a closing
# link; a body already using the URL form is not "clean" just because it
# has no bare #<E> token). ---
if [ "$LEAKED" = "true" ]; then
  CURRENT_BODY=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json body --jq '.body')
  # Replace bare #<E> tokens with the full-URL form (which does NOT auto-close).
  # Herestring, not `printf … | sed` — a pipe spanning a shell command boundary
  # is refused by the worktree-isolation guard (dont.md's post-relocation rule).
  PATCHED_BODY=$(sed -E "s@#<E>@https://github.com/<owner>/<repo>/issues/<E>@g" <<< "$CURRENT_BODY")

  # Flag any line that carries the reference AND a closing-keyword-shaped
  # word — including negated phrasing, which the parser treats identically
  # to an unnegated one. This is a manual-rewrite trigger, not something to
  # sed blindly: rewrite each flagged line by hand to drop the keyword
  # entirely (move the caveat to a separate sentence, or use a neutral
  # synonym like "addresses"/"references"/"tracks"), THEN re-run this tier's
  # patch with the corrected body.
  # Two plain commands staged through a file, not `printf | grep | grep` — a
  # pipe spanning a shell command boundary is refused by the worktree-isolation
  # guard, while a command's own input/output redirection is not (dont.md's
  # post-relocation rule). `.shipyard-scratch/` is the sanctioned worker scratch
  # dir; seed its self-ignoring `.gitignore` first if you have not already
  # (worker-preamble § "Scratch directory").
  grep -niE "(#<E>([^0-9]|\$)|issues/<E>([^0-9]|\$))" <<< "$PATCHED_BODY" \
    > "$WORKTREE_PATH/.shipyard-scratch/epic-ref-lines.txt"
  grep -iE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b' \
    "$WORKTREE_PATH/.shipyard-scratch/epic-ref-lines.txt"
  # ^ if this prints anything, hand-edit PATCHED_BODY to remove the
  # keyword-shaped word from each flagged line before the `gh pr edit` below.

  gh pr edit "$CURRENT_PR" --repo <owner/repo> --body "$PATCHED_BODY"

  LEAKED=$(check_closing_ref "$CURRENT_PR" <owner/repo> <E>)
fi

# --- Tier 2: also rewrite the HEAD commit message. A bare #<E> token riding
# in a squashed-commit message is a SEPARATE vector from the body — a
# body-only rewrite can leave this one untouched. ---
if [ "$LEAKED" = "true" ]; then
  CURRENT_MSG=$(git log -1 --format='%B')
  # Herestrings again, for the same reason as tier 1's body rewrite.
  if grep -qE "#<E>([^0-9]|\$)" <<< "$CURRENT_MSG"; then
    PATCHED_MSG=$(sed -E "s@#<E>@https://github.com/<owner>/<repo>/issues/<E>@g" <<< "$CURRENT_MSG")
    git commit --amend -m "$PATCHED_MSG"
    git push --force-with-lease origin "HEAD:refs/heads/${REMOTE_BRANCH:-do-work/issue-<N>}"
  fi

  LEAKED=$(check_closing_ref "$CURRENT_PR" <owner/repo> <E>)
fi

# --- Tier 3: escape hatch — abandon this branch/PR and reopen from a NEUTRAL
# branch name. Before concluding the branch name is at fault, re-run tier 1's
# keyword-adjacency grep (#990) against the current body — "confirmed-clean"
# means BOTH no bare #<E> token AND no closing-keyword-shaped word (even
# negated) sharing a line with the reference. If the leak survives tiers 1+2
# with a body and commit message that are genuinely clean by BOTH tests, the
# branch name is one known cause (#893) — not the only possible one — and no
# further body/commit edit on THIS branch is expected to clear it, so don't
# loop tiers 1/2 again; move straight to a fresh branch. ---
if [ "$LEAKED" = "true" ]; then
  gh pr close "$CURRENT_PR" --repo <owner/repo> \
    --comment "Closing — closingIssuesReferences kept registering #<E> even with a confirmed-clean body and commit message (#893). Reopening from a neutrally-named branch to clear the leaked link."

  NEUTRAL_STAMP=$(date +%s)
  NEUTRAL_BRANCH="docs/issue-<N>-followup-$NEUTRAL_STAMP"
  git checkout -B "$NEUTRAL_BRANCH" "origin/$DEFAULT_BRANCH"
  git cherry-pick <original-commit-sha>   # or recreate the same file changes directly
  git push -u origin "$NEUTRAL_BRANCH"

  gh pr create --repo <owner/repo> --head "$NEUTRAL_BRANCH" --label shipyard \
    --title "<same title>" --body "$PATCHED_BODY"

  CURRENT_PR=$(gh pr list --repo <owner/repo> --head "$NEUTRAL_BRANCH" --json number --jq '.[0].number')
  LEAKED=$(check_closing_ref "$CURRENT_PR" <owner/repo> <E>)
fi

# If the protected issue is already CLOSED (e.g. an admin ungated direct-merge
# fired before this check ran, or an earlier tier's PR merged before you
# closed it), reopen it — regardless of which tier finally cleared LEAKED.
EPIC_STATE=$(gh issue view <E> --repo <owner/repo> --json state --jq '.state')
if [ "$EPIC_STATE" = "CLOSED" ]; then
  gh issue reopen <E> --repo <owner/repo> \
    --comment "Reopened: a PR auto-closed this issue via a leaked closing reference (#624 / #893). It was meant to *reference* this issue, not close it."
fi

if [ "$LEAKED" = "true" ]; then
  echo "blocked #<N> at parent-epic-leak-verify: even a fresh, neutrally-named branch still registers #<E> as a closing reference — manual triage required (PR: <url>)"
  gh pr edit "$CURRENT_PR" --repo <owner/repo> --add-label needs-human-review || true
  exit 0
fi
```

**Why bare URL rather than deleting the mention.** The reference is *wanted* — the PR legitimately should link the protected issue for traceability; it just must not *close* it. The bare-URL form (`https://github.com/<owner>/<repo>/issues/<E>`) renders a clickable link that GitHub does NOT promote into `closingIssuesReferences`, so it keeps the traceability while dropping the closing semantics. Don't strip the reference entirely.

**Why tier 3 (a fresh branch) can succeed when tiers 1–2 (rewriting the existing branch) don't.** Tiers 1 and 2 fix every *text*-based vector — the body and the commit message — but the [#893](https://github.com/mattsears18/shipyard/issues/893) repro's confirmed-clean body (`gh pr view --json body --jq '.body | test("#<E>")'` → `false`) and confirmed-clean commit message still left `closingIssuesReferences` populated, which points at the **branch name itself** as a third, independent vector not covered by rewriting either text field. Abandoning the branch — not just editing its content — is the only thing that cleared the link in the repro; a fourth or fifth rewrite attempt on the same branch is not expected to do better than the first two.

**Don't jump to the branch-name conclusion without first re-checking for the keyword-adjacency hazard ([#990](https://github.com/mattsears18/shipyard/issues/990)).** The `.body | test("#<E>")` check above only proves the bare-token vector is clean — it says nothing about a closing-keyword-shaped word sharing a line with an already-URL-form reference (a later repro found exactly this: a body reading *"This PR does NOT close `<URL>`"* kept leaking through a token-only "clean" check). Before attributing a surviving leak to the branch name and paying tier 3's cost, re-run tier 1's keyword-adjacency grep against the current body and commit message; only treat the body/commit message as genuinely clean, and the branch name as the likely cause, once both the token check AND the keyword-adjacency grep come back empty.

**Why reopen on already-merged.** On a repo where an admin direct-merge can fire before this check runs (the `merged-direct-ungated` path), the merge may have already closed the protected issue by the time you verify — regardless of which tier you're in when that happens. Reopening `#<E>` restores it so it isn't orphaned and `/my-turn` keeps surfacing it if further review is needed. The body/branch remediation still matters even post-merge — it stops a *future* re-merge or backport from re-closing it.

## Shape (4) — retracting an already-live closing link ([#1001](https://github.com/mattsears18/shipyard/issues/1001))

Shapes (1)–(3) and (5) run this procedure to *prevent* a closing link from ever registering. Shape (4) is the inverse starting condition: `#<N>` already registered as a real closing link via §5.8's normal, correct flow, and a later finding in the same dispatch — most often a post-open validation/landing-gate check disproving the issue's premise — determined the link must come out. **Run the exact same procedure above, with `#<E> = #<N>`.** The script doesn't distinguish where the protected issue number came from; nothing about it needs to change for shape (4) or shape (5).

**There is no direct mutation to unlink a PR from an issue.** [#1001](https://github.com/mattsears18/shipyard/issues/1001) checked GitHub's GraphQL schema directly (`gh api graphql -f query='{ __schema { mutationType { fields { name } } } }'`) for anything `unlinkPullRequestFromIssue`-shaped. It does not exist — `removeSubIssue` and `unlinkProjectV2FromRepository`/`unlinkProjectV2FromTeam` are the nearest-sounding fields, and none of them touch `closingIssuesReferences`. `closingIssuesReferences` is a **derived, read-only** field GitHub recomputes from parsing PR body/commit text and the linked-branch relationship — there is no stored edge to mutate directly, only text to change and let GitHub re-parse. The three-tier escalation above (rewrite body → rewrite commit message → abandon the branch) is not a workaround pending a "real" API — it *is* the API, because there isn't a more direct one.

**A body rewrite alone usually — not reliably — clears the link within seconds; verify, don't assume.** [#1001](https://github.com/mattsears18/shipyard/issues/1001)'s investigation ran a live create → register → rewrite → verify test on this repo (three scratch PRs against a scratch issue, all closed and cleaned up afterward — [PR #1019](https://github.com/mattsears18/shipyard/pull/1019), [#1020](https://github.com/mattsears18/shipyard/pull/1020), [#1021](https://github.com/mattsears18/shipyard/pull/1021)). A PR opened with `Closes #<N>` registers the link immediately; rewriting the body to a clean bare-URL reference (tier 1, no closing-keyword-shaped word sharing the line) reliably cleared it within ~10 seconds in every trial — including when the rewrite used the exact negated phrasing (*"does NOT close it"*) that [#990](https://github.com/mattsears18/shipyard/issues/990) already documents as hazardous. This is a narrower result than [#1001](https://github.com/mattsears18/shipyard/issues/1001)'s own filed repro, which reported the link surviving *several minutes* past a similarly-phrased edit on a different repo (`mattsears18/lightwork`) — that repro's rewrite also used the negated same-line phrasing #990 flags, so its surviving link is consistent with the already-documented #990 keyword-adjacency hazard rather than proof of a strictly one-way mechanism. **The takeaway is not "a body rewrite is reliable" or "a body rewrite is useless" — it's that GitHub does not contractually bound the recompute window, so a worker must never trust a single post-edit read.** Always re-verify with `check_closing_ref`'s two-read pattern (tier 1's own re-verify step already does this) and escalate through tiers 2 and 3 exactly as documented above if the link persists — the same discipline this fragment already applies to leak *prevention* applies identically to leak *retraction*.

**A closing keyword confined to a commit message (never appearing in the PR body) did not register in the pre-merge `closingIssuesReferences` read, in this repo's testing — but tier 2 still matters.** One of the [#1001](https://github.com/mattsears18/shipyard/issues/1001) trials pushed a commit whose message contained `closes #<N>` with a PR body that never mentioned the issue by any closing-keyword-shaped phrasing; `closingIssuesReferences` stayed empty on both an immediate read and a 10-second-later read. GitHub doesn't document the exact resolution logic behind this field, so treat this as an observation, not a guarantee: it's consistent with the field reflecting only the PR description pre-merge, with per-commit closing keywords evaluated separately at actual merge time for merge strategies that land individual commits unchanged (a rebase merge, unlike a squash merge, which discards individual commit messages in favor of one synthesized message). Tier 2's commit-message rewrite therefore stays in the escalation ladder as precautionary defense-in-depth for non-squash merge strategies — `check_closing_ref`'s pre-merge read cannot validate whether a leftover commit-message keyword will fire at merge time, so don't skip tier 2 just because the pre-merge check came back clean after tier 1.

This step runs **after** §5.8 (the dispatched-issue closing-link verification) and **before** §6 arms auto-merge, so a protected issue can never ride an armed auto-merge to a silent close. It runs unconditionally regardless of `originating_author_trust` whenever a protected issue is in scope.

Once this fragment's procedure completes (leak cleared, or escalated to `needs-human-review`), return to [`issue-work.md`](./issue-work.md) and continue at §5.9 (or §6 if §5.9 doesn't apply).
