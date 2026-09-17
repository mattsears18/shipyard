On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Never run a broad process kill"). Load this only if you're weighing whether a broad kill is safe, or want the concrete repro behind the prohibition — the core rule in `SKILL.md` (track your own PID, never a name/pattern match) is enough for the common case, and the `refuse-broad-process-kill.sh` hook enforces it mechanically regardless.

## The repro

The failure mode is fully reproduced, not hypothetical: a worker ran `pkill -9 -f "playwright test"` during local cleanup on a repo running three self-hosted macOS runners on the maintainer's own Mac. The pattern matched the runner's in-flight CI processes and killed two E2E shards of the very PR the worker was trying to get green (issue [#751](https://github.com/mattsears18/shipyard/issues/751)).

The worker's own Playwright/Metro/emulator processes and the runner's CI processes run as the same user, on the same host, often from paths under the same repo root, with identical names — so a pattern match hits both indiscriminately. Killing CI this way is a silent violation of the "never cancel an in-progress CI run" operating principle: the worker never touches a CI surface, never sees a cancellation notice, and has no way to know it just destroyed a run — possibly a *different* PR's, or `main`'s.

## A cheap check tells you whether this host is also a CI executor

Worth running before any local process cleanup if you're unsure:

```bash
# Signal 1: the repo has self-hosted runners registered at all.
gh api "repos/<owner>/<repo>/actions/runners" --jq '.total_count' 2>/dev/null

# Signal 2: a runner agent installed under this user's home directory — the
# strongest local signal that THIS host executes CI. `-print -quit` stops at
# the first hit rather than piping to `head -1`: a pipe spanning a shell
# command boundary is refused by the worktree-isolation guard (dont.md's
# post-relocation rule).
find "$HOME" -maxdepth 3 \( -iname 'actions-runner*' -o -iname 'runner-homes' \) -print -quit 2>/dev/null
```

If either signal is non-empty/non-zero, treat every process on the host as potentially CI's, not just your own, and never reach for a pattern-based kill.
