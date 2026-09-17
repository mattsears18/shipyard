# Worker-preamble fragment — Pre-commit hygiene

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode created the `node_modules → ../../../node_modules` bootstrap symlink (see [`node-bootstrap.md`](./node-bootstrap.md)) and must avoid staging it into a commit, **or** when you're about to open a PR and any commit on your branch used a scratch/`wip:` subject. The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "Pre-commit hygiene — escape symlinks"` / `§ "Final commit subject — Conventional Commits compliant, even on a single-commit PR"`).

## Pre-commit hygiene — escape symlinks

A companion failure mode to the dependency-bootstrap symlink ([#351](https://github.com/mattsears18/shipyard/issues/351)): the worker creates `node_modules → ../../../node_modules` per the bootstrap rules (see [`node-bootstrap.md`](./node-bootstrap.md)), then accidentally stages it into a commit via a stray `git add -A`, a misclick on `git add node_modules`, or path globbing that happens to include the symlink. The committed `120000` symlink mode rides into the commit and stays dangerous forever — when a downstream consumer cherry-picks the commit onto a different checkout depth, `../../../node_modules` resolves to a different (or non-existent) path. The salvage cost is a follow-up `fix(repo): remove stray node_modules symlink from cherry-pick` commit on the receiving end; the prevention cost is zero if you follow the symlink-creation hygiene in the dependency-bootstrap fragment.

The `refuse-escape-symlink-commit.sh` hook (registered as PreToolUse → Bash in `hooks.json`) is the load-bearing enforcement. It refuses any Bash `git commit` invocation whose staged file set includes a symlink whose target either starts with `/` or contains a literal `..` path segment. The hook's stderr explains the failure mode and the fix; do NOT bypass it.

If you genuinely need to commit a symlink with `../` in the target (rare — and a strong signal to re-think the design), return `blocked:` so a human can decide. The hook intentionally has no bypass flag, paralleling the no-`--no-verify` rule for commit hooks.

## Final commit subject — Conventional Commits compliant, even on a single-commit PR ([#1410](https://github.com/mattsears18/shipyard/issues/1410))

**GitHub's squash-merge default uses the sole commit's subject when a PR has exactly one commit — the PR title is only used as the squash-message default when the PR has two or more commits.** A worker that writes a correct, Conventional-Commits-compliant PR title but leaves a throwaway commit subject unamended ships that throwaway subject to `main` verbatim, because the PR title was never actually consulted at merge time. Every visible surface looks right up to the moment of merge — the PR title is correct, auto-merge is armed, CI is green — and the defect only shows up in `git log` on `main` afterward, by which point it's unfixable without a history rewrite the branch ruleset forbids.

**Concrete repro:** PR [#1408](https://github.com/mattsears18/shipyard/pull/1408) had the fully-compliant title `fix(scripts): shipped-immediate-branch-reap.sh reported reaped=true on a failed removal (closes #1404)`. Its single commit was subject-prefixed `wip:`. On squash-merge, `main` got `wip: fix false-success reaped=true in shipped-immediate-branch-reap.sh (#1404) (#1408)` instead — a subject that parses as none of `major`/`minor`/`patch` under this repo's Conventional-Commits-driven release tooling, and that no existing CI check (`conflict-markers`, `gitleaks`, the test suites, `shellcheck`) inspects.

**The rule:** the **final** commit subject — whatever is on `HEAD` the moment you run `gh pr create` — must independently satisfy the same Conventional Commits grammar (`<type>(<scope>): <description>`) as your PR title, regardless of what the PR title says. Don't rely on "the PR title is correct" as a substitute for checking the commit(s) that will actually ship.

**If you used a scratch/`wip:` commit at any point** — the sanctioned worktree-local substitute for `git stash`, see [`git-stash-prohibition.md`](./git-stash-prohibition.md) — that subject is fine as a *transient, local* convenience and must never be what ships. Before your `git push` / `gh pr create` (issue-work.md's [§5](../../agents/issue-worker/issue-work.md#5-commit--push--pr), or the analogous commit point in any other mode), fix it:

- **Single commit on the branch:** `git commit --amend -m "<final Conventional Commits subject>"`.
- **Multiple commits, only the last is a scratch subject:** amend that one the same way.
- **Multiple commits where the whole set should ship as one:** squash them (interactive rebase, or `git reset --soft` to the branch point + a fresh `git commit`) into a single compliant commit — this also sidesteps the single-commit-squash-message hazard entirely for future edits, since a compliant final commit is safe regardless of how many commits preceded it.

Verify before pushing: `git log -1 --format=%s` should read as a valid Conventional Commits subject on its own, with no `wip:`/scratch prefix — not "the PR title looks right."

**Or check the whole branch mechanically ([#1412](https://github.com/mattsears18/shipyard/issues/1412)).** [`scripts/commit-subject-scan.sh`](../../scripts/commit-subject-scan.sh) is the executable counterpart to the prose rule above — it walks every subject in `<base>..HEAD`, asserts each matches the Conventional Commits grammar, and applies exactly the carve-out this section describes: a `wip:` prefix is tolerated on a non-final commit but never on the final (squash-merge) one. Run it yourself before `git push` / `gh pr create` rather than eyeballing `git log`:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"$CLAUDE_PLUGIN_ROOT/scripts/commit-subject-scan.sh" "origin/$DEFAULT_BRANCH"
```

Exit 0 → every subject conforms, push. Exit 1 → it prints each offending `<sha>  <subject>` and why; amend or squash per the three cases above, then re-run. Exit 2 → usage/environment error (not in a work tree, unresolvable base ref) — fix the invocation; never read a 2 as a pass.
