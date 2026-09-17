On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "On-demand fragments"). Load this whenever your mode is about to apply — or cause the orchestrator to apply — `needs-human-review` as an escalation, so you don't bounce an issue back to a human for a question they already answered.

## The failure this closes (#1279)

A worker escalating an issue to `needs-human-review` never checked whether the human decision it was about to ask for had already been recorded. `/shipyard:my-turn` (or `/shipyard:resolve-decisions`) resolves a gated issue by posting a `<!-- shipyard-resolve-decisions -->` (or a maintainer's own `<!-- do-work-decision-resolved -->`) comment and clearing the label. A later pass — a fresh worker dispatch, or the orchestrator classifying a fresh `blocked:` return — re-derived the pre-decision state from the body and the *older* escalation comment, concurred with that stale escalation, and re-applied the gate. Observed three times in ~10 minutes on one issue in the wild ([lightwork#3838](https://github.com/mattsears18/lightwork/issues/3838)), twice after a comment on the thread had already explained the race.

**This is an ordering check, not a keyword-match ("does a resolution comment exist anywhere in this issue's history").** The load-bearing question is *"was a decision recorded AFTER the last time this exact escalation fired?"* — not "does a resolution comment exist somewhere in the thread." See "Guard the other direction" below for why the distinction matters.

## The two sentinels are already unified — don't invent a third

`<!-- shipyard-resolve-decisions -->` (posted automatically by `/shipyard:resolve-decisions` and by `/shipyard:my-turn`'s reused decision-gated walkthrough) and `<!-- do-work-decision-resolved -->` (the hand-written convention documented in this repo's `CLAUDE.md` § "Decision-resolved sentinel", for a maintainer who records a decision by hand) record **the same fact — a human answered the blocking question — through two different call paths.** `commands/do-work/setup/06-scope-preflight.md`'s freshness check (Signal B, added for issue [#962](https://github.com/mattsears18/shipyard/issues/962)) already treats them identically; this fragment reuses that same equivalence rather than adding a third marker. Always check for both.

## A PARTIAL `/resolve-decisions` run is not a recorded decision ([#1557](https://github.com/mattsears18/shipyard/issues/1557))

`/shipyard:resolve-decisions` posts the **same `<!-- shipyard-resolve-decisions -->` sentinel** when the maintainer skipped a decision or halted the walkthrough — headed `## Decisions resolved (partial — N of M)`, and deliberately **without** removing the gate label, because some blocking decision is still open. A bare sentinel match therefore over-fires: it reads a partial run as a full resolution and suppresses a gate the maintainer explicitly chose to keep.

Exclude it. The discriminator is the partial heading, so the `latest_decision` selector below carries `(.body | contains("## Decisions resolved (partial")) | not`. A partial comment is still useful context — it names which decisions remain — but it must not set `decision_already_recorded=true`.

## The check

Requires the issue's `comments` array (`body`, `createdAt`) — every call site listed below already has this in context from its own step-0/step-1 issue fetch; no extra `gh` call is needed unless your mode fetched comments long enough ago that a re-fetch is cheap insurance.

```bash
# $ESCALATION_MARKER_JQ selects THIS call site's own prior-escalation comment
# shape — see the per-call-site table below. It must match only a comment
# THIS SAME escalation mechanism posts, not any needs-human-review comment
# from a different provenance (scope-preflight, external-author-gate, etc.)
# — those are different questions with their own freshness handling.
latest_escalation=$(printf '%s' "$COMMENTS_JSON" | jq -r "
  [.[] | select(.body | $ESCALATION_MARKER_JQ)]
  | sort_by(.createdAt) | last.createdAt // empty")

if [ -z "$latest_escalation" ]; then
  # No prior escalation of this kind exists yet — this would be a first-time
  # escalation, not a re-escalation. The ordering check doesn't apply here;
  # proceed normally. (The ordinary "read the comment thread before acting"
  # rule each mode's own step 0/2 already carries remains the first line of
  # defense against escalating over a decision this pass simply failed to
  # read — this fragment is a backstop for the *repeat* case specifically.)
  decision_already_recorded=false
else
  # The `contains(...) | not` clause drops a PARTIAL /resolve-decisions run,
  # which carries the same sentinel but left the gate deliberately on (#1557).
  latest_decision=$(printf '%s' "$COMMENTS_JSON" | jq -r '
    [.[] | select((.body | startswith("<!-- shipyard-resolve-decisions -->")
                         or startswith("<!-- do-work-decision-resolved -->"))
                  and ((.body | contains("## Decisions resolved (partial")) | not))]
    | sort_by(.createdAt) | last.createdAt // empty')

  if [ -n "$latest_decision" ] && [ "$latest_decision" \> "$latest_escalation" ]; then
    decision_already_recorded=true
  else
    decision_already_recorded=false
  fi
fi
```

ISO-8601 UTC timestamps (`YYYY-MM-DDTHH:MM:SSZ`, what `createdAt` is) compare correctly with plain string `>` — no date parsing needed.

## When `decision_already_recorded=true`

1. **Do not apply (or re-apply) `needs-human-review`.**
2. Post one comment (via the `Write` + `--body-file` pattern — a heredoc `$(cat <<EOF ... EOF)` is refused, per `shipyard:worker-preamble` § "Scratch directory") naming the decision comment so a human skimming the thread doesn't have to reconstruct the race from timestamps: *"Not re-applying `needs-human-review` — a decision was already recorded after the prior escalation (see `<decision-comment-url-or-timestamp>`)."*
3. Leave the issue **without the gate label.** Don't try to implement against the decision from inside this check — that's this mode's normal step 2 comment-reading job on its *next* dispatch, not a special case to improvise here. The point of this fragment is narrowly to stop the re-gate loop; the next dispatch (this session's own retry, or a fresh session) reads the comment thread per its own mode's step 0/2 rule and acts on the recorded decision directly.

## Guard the other direction — a stale decision must not suppress a genuinely new escalation

If `latest_decision` exists but predates `latest_escalation` (or there is no prior escalation at all), the check must **not** trip — proceed with the escalation normally. An issue can legitimately need human input twice, for two different reasons; the *timestamp ordering* relative to the specific prior escalation is what tells the two apart, not the mere presence of some decision comment somewhere in the thread. A bare "a resolution comment exists" check would wrongly suppress a second, unrelated escalation on the same issue.

## Per-call-site escalation markers

| Call site | `$ESCALATION_MARKER_JQ` (this site's own prior-escalation comment shape) |
|---|---|
| `commands/do-work/steady-state.md`'s blocked→refuse routing | `startswith("<!-- do-work-agent-refuse -->")` |
| `agents/issue-worker/investigate.md` § 4b | `startswith("<!-- do-work-investigation-disposition -->")` |
| `agents/issue-worker/spike.md` § 4b | `startswith("<!-- do-work-investigation-disposition -->")` (shared marker — investigate.md and spike.md's 4b are structurally identical and share one provenance marker per issue [#1091](https://github.com/mattsears18/shipyard/issues/1091)) |

**The orchestrator-side scope-preflight defer path is the fourth call site, and it anchors on a timeline event rather than a comment marker.** [`06c-scope-handling-ui.md`'s Recording-path step 3.5](../../commands/do-work/setup/06c-scope-handling-ui.md) compares `RESOLUTION_AT` against the last `labeled` event for `needs-human-review` — equivalent in spirit to a comment-marker anchor (step 4 applies that label immediately after posting the class diagnosis comment), and it must be the **`labeled`** event, never `unlabeled`: `/resolve-decisions` posts its comment *before* clearing the gate, so a genuine resolution is always seconds older than the unlabel event it caused ([#1557](https://github.com/mattsears18/shipyard/issues/1557)). Whichever anchor a site uses, the question is the same — *did a decision land after the escalation this pass is about to repeat?*

Each call site's own marker is what makes the check specific to *that mechanism's* prior escalation — comparing against a needs-human-review comment from an unrelated provenance (e.g. the external-author-trust gate, or a scope-preflight diagnosis) would compare apples to oranges. If a mode gains a new needs-human-review escalation path in the future, give it its own marker (or reuse an existing one only if the two paths are asking the same class of question) and add a row here.
