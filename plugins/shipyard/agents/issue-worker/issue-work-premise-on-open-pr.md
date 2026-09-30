# issue-work.md — An early premise is not a stale one: acceptance criteria that name an open PR's tree ([#1602](https://github.com/mattsears18/shipyard/issues/1602))

On-demand fragment of [`issue-work.md`](./issue-work.md). Load it from §2 when an acceptance criterion names a path or symbol you cannot find on the default branch, and from §4 before you file a follow-up issue that describes what your own PR creates.

## The failure it prevents

A worker files a follow-up that describes the tree **as it will be once its own PR merges** ("remove the `ALLOWED_NESTED_DUPLICATES` entry", "reuse the constant in `scripts/lib/organization-photo-cache-control.js`"). The follow-up enters the ready pool at once, and the next dispatch picks it up against a default branch where that premise is not true **yet**. The next worker sees a name that "doesn't exist" and concludes the issue is stale. That conclusion is wrong: the premise is **early**. Each of the three moves it leads to is bad:

1. **Implementing against the open PR's shape** means referencing a symbol that does not exist on the default branch. The result is broken.
2. **Re-implementing the sibling PR's half** gives a certain conflict, and two PRs claiming the same change.
3. **Shipping only the half that fits the default branch** is the worst of the three, because it can be silently wrong. The two PRs can touch disjoint files, so neither goes dirty. The sibling can then merge on checks run against a stale base, and the default branch goes red on a required check with nothing pointing at the cause.

## §2 — check open PRs before you call an AC stale

When an acceptance criterion names a path or symbol missing from `origin/<default>`, run the detector before you decide anything. Run it as a plain command from your worktree:

Reuse the `CLAUDE_PLUGIN_ROOT` you resolved at step 0. The `:-` fallback in the first line does nothing when that value is already set. Run each line below as its own plain command:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"$CLAUDE_PLUGIN_ROOT/scripts/detect-premise-on-open-pr.sh" --repo <owner/repo> --issue <N> --base "origin/<default>"
```

- **`verdict=premise-on-open-pr prs=<M>[,…]`**: at least one named path or symbol exists only on those open PRs. Read each `hit` line and confirm that the token is load-bearing for an AC, not an incidental mention. If it is, **do not implement any part of the issue**. Outcome 3 above is precisely the "achievable half". Return:

  > `blocked #<N> at premise-check: premise lives on an open PR — Blocked by #<M> (<token>)`

  Name every such PR, as `Blocked by #<M>, #<K>`. The orchestrator's [bail classifier](../../scripts/classify-blocked-bail.sh) routes this as a **dependency-wait**. Because the blocker is a pull request, it writes the self-clearing `<!-- do-work-blocked-by-prs: M -->` first-line marker ([#1429](https://github.com/mattsears18/shipyard/issues/1429)), not a label. The issue re-enters the pool, with no human involved, the moment every named PR merges or closes.
- **`verdict=clear`**: nothing named is on an open PR. The token really is stale, a typo, or prose. Continue with §2's normal premise verification.
- **Exit 2 / `verdict=indeterminate`**: the detector could not decide. Never read that as clear. Look for the token by hand with `gh pr list --state open --json number,files` for a path, or `gh pr diff <M>` for a symbol, before you treat the premise as stale. If you still cannot tell, return `blocked #<N> at premise-check: cannot verify whether <token> lives on an open PR`.
- **A hit on a PR that already closes `#<N>`** was caught by §0 before you got here. Pass `--exclude-pr <M>` for any PR you have deliberately ruled out, and name each one in your return.

**Co-scoped bundle ([#1596](https://github.com/mattsears18/shipyard/issues/1596)).** Run the detector for every bundled issue (use `--issue <A>`), not only `#<N>`. A bundled sibling with a load-bearing hit is **unbundled**, not partly shipped: leave it unclosed and add `Unbundled: #<A> — premise lives on open PR #<M>` to the PR body. If `#<N>` itself hits, bail as above.

## §4 — filing a follow-up that describes your own PR's tree

Sometimes a follow-up's acceptance criteria only make sense once **your** PR merges: they name a file, symbol, allowlist entry or pointer that your diff introduces. You know this because you are writing both sides. In that case:

1. **File it after `gh pr create`**, so your PR number exists.
2. **Make the body's very first line** `<!-- do-work-blocked-by-prs: <your PR number> -->`, with nothing before it. `backlog-filter.sh classify` reads **line 1 only**. It keeps the issue out of dispatch while that PR is open, and re-admits it as soon as the PR merges or closes. This is the same marker, with the same lifecycle, that scope pre-flight's `blocked-by-in-flight-pr` defer writes.
3. Say in the body, in prose, that the ACs describe the tree after your PR merges, so a human reader sees why the issue is waiting.

Skip the marker for a follow-up whose ACs hold on the default branch today. The marker is only for "not yet true", never for "related to".
