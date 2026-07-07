#!/usr/bin/env bash
# Test: the /shipyard:my-turn command file exists with proper frontmatter and
# covers every required survey dimension from issue #142.
#
# Background — issue #142: `/shipyard:do-work` handles agent-driven work; the
# user needed a human-driven counterpart that scans open PRs + issues +
# comments and surfaces items genuinely blocked on the user (not on Claude).
# Before this command, the user discovered those items by manually browsing.
#
# Issue #635 reshaped the command: instead of surfacing the single next action
# and stopping (read-only / advisory-only), `/my-turn` now WALKS the human
# through the human-only queue one item at a time, advancing to the next until
# the queue is empty. It stays human-facing and non-autonomous (no agent
# dispatch, no sharing of /do-work's worker machinery) and reuses
# /shipyard:resolve-decisions' interactive walkthrough for decision-gated
# items. Browser-completable (needs-operator) work is filtered out — that's
# /do-work --operate's job. The three-command division is: /do-work =
# autonomous code loop; /do-work --operate = code loop + browser operation;
# /my-turn = human-only interactive walkthrough.
#
# This test is the regression guard: if anyone deletes the command, removes
# the priority tiers, drops a required input source, reverts the looping
# walkthrough back to a stop-after-one-item render, or stops filtering
# browser-completable work out of the human-only queue, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/my-turn.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

cmd_path="$repo_root/plugins/shipyard/commands/my-turn.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  # Case-insensitive: spec headings often capitalize at sentence start ("Draft
  # PRs stale >7 days"), but the regression invariant is presence of the
  # concept, not exact case.
  if grep -qiF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "my-turn command regression tests (issue #142)"
echo

# (1) Command file must exist with proper YAML frontmatter.
assert_file_exists "$cmd_path" "commands/my-turn.md exists"

if [[ -f "$cmd_path" ]]; then
  # Frontmatter must declare a description so /help can surface the command.
  assert_contains "$cmd_path" "description:" \
    "command frontmatter has a description field"

  # argument-hint documents the optional --repo flag for autocomplete.
  assert_contains "$cmd_path" "argument-hint:" \
    "command frontmatter has an argument-hint field"

  # Optional --repo flag follows the convention from /do-work and /audit.
  assert_contains "$cmd_path" "--repo" \
    "command accepts an optional --repo flag"

  # The three priority tiers from issue #142 must be enumerated. These are
  # the contract that drives the ranked output the user reads.
  assert_contains "$cmd_path" "P0" \
    "command defines a P0 tier (blocking other work)"
  assert_contains "$cmd_path" "P1" \
    "command defines a P1 tier (decisions)"
  assert_contains "$cmd_path" "P2" \
    "command defines a P2 tier (housekeeping)"

  # Input sources from issue #142's "Inputs the command pulls from" section.
  # Grep by anchor phrases so the author has wording leeway.
  assert_contains "$cmd_path" "gh pr list" \
    "command pulls open PRs via gh pr list"
  assert_contains "$cmd_path" "gh issue list" \
    "command pulls open issues via gh issue list"
  assert_contains "$cmd_path" "review" \
    "command covers PR review state"
  assert_contains "$cmd_path" "blocked:ci" \
    "command surfaces blocked:ci PRs"
  assert_contains "$cmd_path" "needs-human-review" \
    "command surfaces needs-human-review-labeled issues"
  assert_contains "$cmd_path" "needs-refinement" \
    "command surfaces needs-refinement-labeled issues"
  # Issue #499: design-gated issues are dispatch-excluded by /do-work, so
  # /my-turn must surface them as a human-blocked decision item — otherwise
  # they fall through both loops and stack up with no path to a human.
  # Issue #515 folded the standalone needs-design label into needs-human-review;
  # the design-gate is now surfaced via the needs-human-review bullet (asserted
  # above), and the command documents the fold so the #499 intent is preserved.
  assert_contains "$cmd_path" "design" \
    "command surfaces design-gated issues (issue #499, via needs-human-review per #515)"
  assert_contains "$cmd_path" "draft" \
    "command surfaces stale draft PRs"

  # Human-facing / non-autonomous contract (issue #635). The load-bearing
  # distinction from /do-work --operate: /my-turn is human-paced and dispatches
  # no agents — it walks the human through items, advancing when *they* finish.
  # The only mutation it performs is the human-directed decisions record (via
  # the reused /resolve-decisions flow). It does not share /do-work's worker
  # machinery or drive the browser.
  assert_contains "$cmd_path" "human-facing" \
    "command declares it stays human-facing (#635)"
  assert_contains "$cmd_path" "non-autonomous" \
    "command declares it is non-autonomous (#635)"
  assert_contains "$cmd_path" "dispatches no agents" \
    "command does not dispatch agents or share /do-work's worker machinery (#635)"

  # Don't section is a common convention across shipyard commands — keeps
  # non-goals explicit.
  assert_contains "$cmd_path" "Don't" \
    "command has a Don't section to scope non-goals"

  # Cross-reference to /shipyard:do-work as the agent-driven counterpart.
  # The pairing is the whole point of placing this in the shipyard plugin.
  assert_contains "$cmd_path" "do-work" \
    "command cross-references /shipyard:do-work"

  # Output must include URLs (so the items are clickable) and ages (so the
  # user can see what's been waiting longest).
  assert_contains "$cmd_path" "URL" \
    "command output includes per-item URLs"
  assert_contains "$cmd_path" "age" \
    "command output includes per-item age"

  # Looping walkthrough default (issue #635): the command no longer stops after
  # one item. The default render WALKS the human through the human-only queue
  # one item at a time, advancing to the next until the queue is empty. The
  # headline item renders as a "→ Now:" directive; --all / --limit render a
  # static list-snapshot instead of walking.
  assert_contains "$cmd_path" "Walkthrough mode" \
    "command documents the looping Walkthrough default render mode (#635)"
  assert_contains "$cmd_path" "→ Now:" \
    "command renders the current item as a → Now: directive (#635)"
  assert_contains "$cmd_path" "advancing" \
    "command describes advancing to the next item, not stopping after one (#635)"
  assert_contains "$cmd_path" "Termination contract" \
    "command defines a termination contract for the advancing loop (#635)"
  assert_contains "$cmd_path" "--all" \
    "command accepts an --all flag to render a static snapshot of the queue"
  assert_contains "$cmd_path" "list-snapshot mode" \
    "command documents the opt-in list-snapshot render mode (#635)"
  # Human-only queue filter (issue #635): browser-completable / needs-operator
  # items are /do-work --operate's job and must be excluded from the walkthrough
  # queue (surfaced only via a one-line operator pointer).
  assert_contains "$cmd_path" "Human-only queue filter" \
    "command documents the human-only queue filter (#635)"
  assert_contains "$cmd_path" "do-work --operate" \
    "command points needs-operator / browser-completable work at /do-work --operate (#635)"
  assert_contains "$cmd_path" "#635" \
    "command cites issue #635 for the looping human-only walkthrough"
  # The empty-state one-liner is unchanged — it doubles as the
  # walkthrough-complete confirmation when the queue drains.
  assert_contains "$cmd_path" "Nothing on your plate" \
    "command keeps the unchanged empty-state one-liner"

  # Agent-refuse surfacing (issues #500 → #521). #500 originally split the
  # blocked:agent-hard signal by whether it was auto-clearable. #521
  # eliminated the blocked:agent-hard label entirely: a refuse now carries
  # needs-human-review (surfaced via the needs-human-review bucket) and a
  # dependency-wait carries no label (auto-cleared by the `Blocked by #N`
  # body-reference filter — nothing for /my-turn to surface). So /my-turn
  # surfaces refuses via needs-human-review and the dedicated clearable /
  # non-clearable blocked:agent-hard buckets are gone.
  assert_contains "$cmd_path" "needs-human-review" \
    "command surfaces agent refuses via the needs-human-review signal (#521)"
  assert_contains "$cmd_path" "Blocked by" \
    "command still references Blocked by #N (the dependency-wait body-ref filter)"
  assert_contains "$cmd_path" "#521" \
    "command cites issue #521 for the blocked:agent-hard elimination / refuse re-routing"

  # Third-party console deep links (issue #523): when a surfaced action's next
  # step lives in a provider console (Meta / Firebase / Vercel / App Store
  # Connect / Apple Developer / Play Console / GCP / GitHub settings), the
  # rendered directive must include a clickable deep link to the most-specific
  # reachable page, derived from identifiers already in hand, with a
  # top-level-console fallback when the specific page isn't derivable. The
  # information is already present; the feature turns it into a clickable link
  # so the user skips a manual provider-UI navigation.
  assert_contains "$cmd_path" "Third-party console deep links" \
    "command documents the third-party console deep-link section (#523)"
  assert_contains "$cmd_path" "most specific reachable page" \
    "deep-link section targets the most-specific reachable page (#523)"
  assert_contains "$cmd_path" "developers.facebook.com/apps/" \
    "deep-link table encodes the Meta App Dashboard template (#523)"
  assert_contains "$cmd_path" "console.firebase.google.com/project/" \
    "deep-link table encodes the Firebase Console template (#523)"
  assert_contains "$cmd_path" "appstoreconnect.apple.com/apps" \
    "deep-link table encodes the App Store Connect template (#523)"
  assert_contains "$cmd_path" "settings/secrets/actions" \
    "deep-link table encodes the GitHub repo Actions-secrets template (#523)"
  assert_contains "$cmd_path" "top-level" \
    "deep-link section defines a top-level-console fallback (#523)"
  assert_contains "$cmd_path" "#523" \
    "command cites issue #523 for the third-party console deep-link feature"

  # Leverage-score within-tier sort (issue #565): the old flat
  # createdAt-ascending secondary sort surfaced the *stalest* item as the sole
  # → Next: directive in single-action mode, which on a needs-human-review-
  # dominated P0 tier regularly floated an auto-undecomposable epic (the least
  # actionable item) to the top — contradicting the "highest-leverage" promise.
  # The fix sorts within each tier by a leverage score first, breaking ties by
  # age (oldest first). These assertions guard the new contract: leverage is
  # the primary within-tier key, age is the tie-breaker, and the
  # auto-undecomposable epic sinks rather than floats.
  assert_contains "$cmd_path" "leverage score" \
    "command sorts within-tier by a leverage score (#565)"
  assert_contains "$cmd_path" "tie-breaker" \
    "command keeps createdAt/age only as the within-tier tie-breaker (#565)"
  assert_contains "$cmd_path" "pure-decision" \
    "command scores pure-decision items as highest-leverage (#565)"
  assert_contains "$cmd_path" "couldn't auto-decompose:" \
    "command sinks auto-undecomposable epics to lowest leverage (#565)"
  assert_contains "$cmd_path" "#565" \
    "command cites issue #565 for the leverage-score within-tier sort"

  # Decision-gated walkthrough (issues #566 → #635): when the current
  # walkthrough item is a decision-gated needs-human-review issue (answerable
  # blocking decisions present), /my-turn walks the decisions INLINE by reusing
  # /shipyard:resolve-decisions' interactive per-decision flow and its
  # record-and-unblock mutation. #566 originally made /my-turn only *offer* a
  # read-only hand-off; #635 changed that to reusing the walkthrough inline as
  # part of the advancing loop (the one human-directed mutation /my-turn
  # performs). These assertions guard that the walkthrough exists, names +
  # links the sibling command, and reuses its flow rather than reinventing it.
  assert_contains "$cmd_path" "Decision-gated walkthrough" \
    "command documents the inline decision-gated walkthrough subsection (#635)"
  assert_contains "$cmd_path" "/shipyard:resolve-decisions" \
    "walkthrough reuses the sibling /shipyard:resolve-decisions flow (#566)"
  assert_contains "$cmd_path" "resolve-decisions.md" \
    "command links the resolve-decisions sibling command file (#566)"
  assert_contains "$cmd_path" "reuse" \
    "walkthrough reuses resolve-decisions' flow rather than reinventing it (#635)"
  assert_contains "$cmd_path" "#566" \
    "command cites issue #566 for the decision walkthrough lineage"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
