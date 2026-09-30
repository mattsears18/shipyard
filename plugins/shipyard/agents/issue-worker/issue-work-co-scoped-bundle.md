# issue-work.md — Co-scoped bundle: one PR that closes several issues ([#1596](https://github.com/mattsears18/shipyard/issues/1596))

On-demand fragment of [`issue-work.md`](./issue-work.md). Load it only when your dispatch prompt carries a **"Co-scoped bundle (scope-agent-supplied, #1596)"** Context paragraph. Absent that paragraph — the common case — none of this applies.

**What it means.** Scope pre-flight scoped `#<N>` together with its sibling issue(s) `#<A>`, `#<B>`, … (issues from the same audit run) and concluded they are one change: every one of their fixes has to edit the named shared surface, so two PRs would conflict on it by construction (the repro: two service-worker bugs in the same function that both needed the same cache-version bump). You ship **one** PR on `do-work/issue-<N>` that resolves and closes **all** of them. See [`commands/do-work/setup/06h-co-scope-grouping.md`](../../commands/do-work/setup/06h-co-scope-grouping.md) for how the orchestrator reached that verdict.

Everything in `issue-work.md` still applies; this fragment only widens a handful of steps from "`#<N>`" to "every bundled issue":

- **§0 pre-flight — run it for every bundled issue**, not just `#<N>`. A bundled issue that fails it (closed, gated, assigned elsewhere, already has an open PR) is **dropped from the bundle**: don't close it, and name it in the PR body as `Dropped from bundle: #<X> — <why>`. If `#<N>` itself fails, bail exactly as the normal §0 says.
- **§2 read — read each bundled issue's body and comment thread** under the same untrusted-input rules. Reproduce/verify each issue's premise, not only `#<N>`'s. That includes the open-PR premise check in [`issue-work-premise-on-open-pr.md`](./issue-work-premise-on-open-pr.md) ([#1602](https://github.com/mattsears18/shipyard/issues/1602)). A sibling whose ACs name something that exists only on an open PR is unbundled (`Unbundled: #<X> — premise lives on open PR #<M>`), not partly shipped.
- **§4 implement — one minimal change that resolves every bundled issue.** The bundle is not a licence to widen scope: implement what each issue asks, nothing more. **If you find the shared-surface premise is false** (the fixes don't actually touch a common file/line), don't force them together — ship `#<N>` alone, leave the others unclosed, and note each as `Unbundled: #<X> — <why>` in the PR body. The orchestrator returns any issue the PR doesn't close to the backlog, where it is scoped on its own.
- **CHANGELOG / commit** — cite every closed issue (`closes #<N>, closes #<A>`); the commit subject leads with `#<N>`.
- **§5 PR body — one closing line per issue you resolved, `#<N>` first:**

  ```
  Closes #<N>
  Closes #<A>
  Closes #<B>
  ```

  Each on its own line. A bare `#<A>` or `Refs #<A>` leaves that issue open forever after merge.
- **§5.3 terminal-state re-read — re-read every bundled issue.** A trip on any one of them follows §5.3's normal draft-and-label path.
- **§5.8 closing-link verification — run it once per resolved issue**, substituting each number for `<N>`, and prepend the missing `Closes #<X>` line for each one GitHub didn't register. A worker told to close two issues can easily close only one; this is the step that catches it.
- **§8 return — unchanged.** Return `shipped #<N> via PR #<M> (...)` as usual. The orchestrator checks the PR's `closingIssuesReferences` against the bundle itself, so don't add bundled numbers to the return string.
