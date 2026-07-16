# Fix-rebase mode (drain-phase stale-base PR)

The orchestrator dispatches this when the end-of-session [drain](../../commands/do-work/drain.md#end-of-session-drain) finds an `@me` PR in `mergeStateStatus: DIRTY` with **no failing checks** — the PR is green-or-pending but its base is stale relative to the freshly-advanced default branch, so auto-merge won't fire until it's rebased onto current default.

This is intentionally a **light-touch** mode. You are NOT fixing failing tests. You are NOT modifying the PR's scope. You are NOT touching the PR title / description / linked issue. The single goal is to take the PR's branch, rebase it onto current default, push, and return — letting CI re-run on the rebased head and auto-merge land it.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-rebase specifics.

## Inputs (from the dispatch prompt)

- PR number `#M`.
- Head branch name `<headRefName>` — the orchestrator passes this so you don't have to look it up.
- Target repo `<owner/repo>`.

## Process

1. **Land on the PR's head branch** — the harness placed you on some placeholder branch. Use the safe two-step, do NOT use `gh pr checkout` (see worker-preamble's worktree discipline rule 2):
   ```bash
   HEAD_REF=$(gh pr view <M> --repo <owner/repo> --json headRefName -q .headRefName)
   git fetch origin "$HEAD_REF"
   git switch "$HEAD_REF"
   ```

   **If `git switch` fails with "is already checked out at <path>"** — the head branch is locked in another agent worktree (typically the original issue-work worker's worktree). The orchestrator's [drain pre-dispatch head-branch reap (#370)](../../commands/do-work/drain.md#pre-dispatch-head-branch-reap-self-pid-lock-release) is supposed to release this lock before you're dispatched — it reaps any worktree holding a `self-ancestor` (our own session's PID) lock on the head branch. If you still hit the collision, the lock classified as `peer-alive` (a genuinely-live non-orchestrator process still holds it) and the orchestrator correctly declined to yank it, OR the steady-state immediate-reap from [#282](https://github.com/mattsears18/shipyard/issues/282) deferred and #370's reap also deferred. Either way, bail rather than working around it with a temporary `<head>-rebase` branch (the workaround #282 documented). Return `blocked rebase #<M>: head branch <HEAD_REF> locked in another worktree — needs manual rebase or end-of-session reap`. The drain will leave the PR alone and the next session's startup sweep clears the lock. Do NOT create a `<head>-rebase` temp branch — the artifacts can't be cleaned up cleanly, and the force-push to origin's head is the same operation regardless of which local branch holds it.

2. **Pre-flight: confirm DIRTY is still the state.** State drifts between dispatch and you starting — another merge train tick may have already auto-merged this PR, or someone may have pushed a fix that resolved the dirty state, or new check failures may have appeared:
   ```bash
   gh pr view <M> --repo <owner/repo> --json mergeStateStatus,statusCheckRollup,state
   ```
   Bail before touching anything if:
   - `state != "OPEN"` → return `noop: PR #<M> already closed/merged`.
   - `mergeStateStatus in {"CLEAN", "HAS_HOOKS", "UNSTABLE", "BLOCKED"}` and not `DIRTY` → return `noop: not dirty (mergeStateStatus=<X>)`. Auto-merge will figure it out — don't churn the branch unnecessarily.
   - **The PR has a hard check failure on the latest run of any check name** → return `blocked rebase #<M>: PR has failing checks — needs fix-checks, not rebase`. The drain will route this through the normal fix-checks dispatcher.

     **CRITICAL — use the latest-per-name projection, not the raw rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `gh pr view --json statusCheckRollup` returns the **union** of every check run for the PR's head SHA, including stale superseded runs. A naïve `.statusCheckRollup[] | select(.conclusion == "FAILURE")` walk false-positives whenever a check ran, failed, was re-triggered, and passed — the first FAILURE entry trips the bail even though the latest run is SUCCESS. De-duplicate by `name` and take the most recent entry per check (by `completedAt`, fallback `startedAt`) BEFORE checking for hard failures:

     ```bash
     fails=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '
       [.statusCheckRollup
        | group_by(.name)
        | map(sort_by(.completedAt // .startedAt // "") | last)
        | .[]
        | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
       | length')
     if [ "${fails:-0}" -gt 0 ]; then
       echo "blocked rebase #<M>: PR has failing checks — needs fix-checks, not rebase"
       exit 0
     fi
     ```

     The `group_by(.name) | map(... | last)` reduction is the load-bearing piece — it collapses N entries per check name to 1 (the most recent), so a stale FAILURE entry that's been superseded by a later SUCCESS is correctly filtered out. The `// .startedAt // ""` fallback handles in-progress checks where `completedAt` is null; the empty-string default keeps the sort stable when both timestamps are absent. Test `(.conclusion // .status)` so the predicate works for both completed runs (carry `conclusion`) and in-progress check-runs (carry only `status`).

   Only proceed when `mergeStateStatus == "DIRTY"` and there are no hard check failures **on the latest run per check name**.

3. **Fetch + rebase onto current default branch:**
   ```bash
   DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
   git fetch origin "$DEFAULT_BRANCH"
   git rebase "origin/$DEFAULT_BRANCH"
   ```

   The rebase either lands cleanly or stops on a conflict. Both paths are handled in step 4.

4. **Conflict triage.** If `git rebase` exits non-zero with conflicts, the conflict resolution policy is **trivial-or-bail**:

   - **Trivial conflicts that auto-resolve:** additive-only conflicts in shared docs / config where both sides only appended content and the merge can be reconstructed by concatenating both blocks. The canonical examples (any of these is fair game):
     - `CHANGELOG.md` — both sides added entries at the top. Take both: newer entry first (yours), then theirs, then the rest of the file. If both touched the same version's entry block, that's a non-trivial conflict — bail.
     - Append-only docs like `CLAUDE.md`, `README.md`, `E2E_TESTS.md`, `CONTRIBUTING.md` — both sides added new bullets/sections to the end (or to a non-overlapping section). Concat both, drop the conflict markers, no semantic merging required.
     - `ci.yml` shard matrix appends — both sides added an entry to an array literal. Concat the array entries, dedupe, no reordering.
     - Lockfiles (`package-lock.json` / `pnpm-lock.yaml` / `Cargo.lock` / `go.sum`) when the conflict is on dependency entries that both sides touched independently — **DO NOT manually resolve.** Instead re-run the package manager (`pnpm install` / `npm install` / `cargo update` / `go mod tidy`) inside the rebased worktree so the lockfile is regenerated against the rebased `package.json` / `Cargo.toml` / `go.mod`. If the regeneration succeeds and the result is committable, that counts as trivial; if the regeneration itself errors (incompatible peer deps, version pinning conflict, etc.) bail.
     - **Version-coordinated manifest `.version` row + CHANGELOG top-of-file entry — see [§4.6 below](#46-version-coordinated-manifest--changelog-re-number-trivial-resolution-issue-466).** On a repo with `version_coordination.enabled`, the manifest version row (e.g. `plugin.json` `.version`) would otherwise read as a "both sides edited the same JSON key with different values" conflict — which the non-trivial rules below bail on. But when that row is *coordination-managed*, the resolution is **deterministic** (take main's version, bump at the PR's release level — major/minor/patch — to the next free slot, re-number this PR's CHANGELOG heading to that slot, place newest-first), not a semantic judgment about which side is correct. §4.6 carves this exact case out of the bail rule. The carve-out is **narrow**: it applies only when *every* conflicted hunk is on the manifest `.version` row or the CHANGELOG top-of-file insert — any conflict touching source/spec content beyond those two falls back to the bail rule below.

   - **Non-trivial conflicts — bail immediately:** anything where the merge requires semantic judgment about which side's change is correct or how they should compose. Examples:
     - Both sides modified the same function body / same imports block / same type definition.
     - One side renamed a file the other side modified.
     - Both sides edited the same JSON config key with different values — **except** the version-coordinated manifest `.version` row, which §4.6 resolves deterministically. The carve-out is solely for the coordination-managed version row; every other JSON-key collision (a feature flag, a config default, a dependency pin set by hand) is still non-trivial and bails.
     - Anything involving test fixtures or snapshots where you can't tell from the diff alone which output is right.

     For any non-trivial conflict, `git rebase --abort` to restore the branch to its pre-rebase state, then return `blocked rebase #<M>: <one-line conflict description, e.g. "merge conflict in src/auth.ts — both sides modified handleLogin">`. The orchestrator will leave the PR for human rebase and the drain will continue without it.

   The instinct to "just resolve it, the conflict looks small enough" is the failure mode this rule exists to prevent. If you have to read more than the conflict markers to figure out the right resolution, it's non-trivial. Bail.

   **Resolve at the hunk level — never `git checkout --theirs/--ours <file>` on a whole file that also carries the PR's substantive change (issue [#646](https://github.com/mattsears18/shipyard/issues/646)).** A whole-file `--theirs` (take main's copy) or `--ours` (take the branch's copy) replaces the *entire* file, discarding every hunk in it — including the PR's non-conflicting substantive hunks that sit elsewhere in the same file. This is the proximate cause of #646: a conflict on a single same-line `Last reviewed` provenance line was "resolved" by taking main's whole-file copy, which also threw away the PR's substantive change (a column pin lower in the same file) that was never in conflict. Edit only the conflicted hunk(s) between the markers, leaving every other hunk intact. The one exception is §4.6's coordinated-manifest path, where gate 3 guarantees the *only* difference between the two sides is the version row — there a `git checkout --theirs "$vc_manifest"` followed by a single `jq`-set of the version row is safe precisely because there are no other hunks to lose. Outside that narrow case, a same-line conflict adjacent to a substantive change is non-trivial: bail rather than risk a whole-file take. Step 5.7's empty-diff guard is the backstop if a dropped-change resolution slips through anyway.

4.6. **Version-coordinated manifest + CHANGELOG re-number — trivial resolution (issue [#466](https://github.com/mattsears18/shipyard/issues/466)).** This is the one structured exception to step 4's "both sides edited the same JSON key ⇒ bail" rule. On a repo where `version_coordination.enabled`, every PR cuts a release by bumping a shared manifest `.version` row and prepending a `### <version>` CHANGELOG entry. When a sibling PR merges first and advances the manifest version (e.g. to `1.8.41`) while this PR still carries an earlier pre-allocated version (e.g. `1.8.38`), the rebase conflicts on **two deterministic rows**: the manifest `.version` line and the top-of-file CHANGELOG heading. The resolution is mechanical — take main's version, bump at the PR's release level (major/minor/patch) to the next free slot, re-number this PR's CHANGELOG heading to that slot, place it newest-first — and is exactly the resolution the orchestrator otherwise performs by hand. Bailing here forces a manual rebase over a pure version number; this carve-out resolves it in-dispatch instead.

   **Eligibility gate — ALL must hold, else fall back to the step 4 bail rule:**

   1. The repo opts into coordination: `version_coordination.enabled == "true"` AND `version_coordination.manifest_path` is non-empty. Read both from the merged config (re-derive `CLAUDE_PLUGIN_ROOT` first — variables don't survive across Bash tool calls):
      ```bash
      export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
      vc_enabled=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.enabled 2>/dev/null || echo "false")
      vc_manifest=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_path 2>/dev/null || echo "")
      vc_version_jq=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_version_jq 2>/dev/null || echo ".version")
      vc_changelog=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.changelog_path 2>/dev/null || echo "")
      ```
      When `vc_enabled != "true"` or `vc_manifest` is empty, this carve-out does not apply — bail per step 4.
   2. **The conflicted file set is a subset of `{manifest_path, changelog_path}`.** List the conflicted paths with `git diff --name-only --diff-filter=U` and confirm every entry is either `vc_manifest` or (when non-empty) `vc_changelog`. If ANY conflicted file is outside that two-file set — a source file, a spec markdown, a test — the conflict touches content beyond the coordinated rows: `git rebase --abort` and bail with `blocked rebase #<M>: conflict extends beyond coordinated manifest+CHANGELOG rows — needs manual rebase`.
      ```bash
      conflicted=$(git diff --name-only --diff-filter=U)
      for f in $conflicted; do
        if [ "$f" != "$vc_manifest" ] && { [ -z "$vc_changelog" ] || [ "$f" != "$vc_changelog" ]; }; then
          git rebase --abort 2>/dev/null || true
          echo "blocked rebase #<M>: conflict extends beyond coordinated manifest+CHANGELOG rows ($f) — needs manual rebase"
          exit 0
        fi
      done
      ```
   3. **Within `manifest_path`, the ONLY conflicted hunk is the version row.** A conflict on any other manifest key (a dependency, a permissions block, a description) is a real semantic conflict — abort and bail `blocked rebase #<M>: manifest conflict outside the .version row — needs manual rebase`. Inspect the conflict hunks (`git diff` on the file) and confirm the `<<<<<<<` / `=======` / `>>>>>>>` block brackets only the line carrying the version string the `vc_version_jq` expression selects.
   4. **Within `changelog_path` (when coordinated), the ONLY conflict is the top-of-file entry insert** — both sides prepended a new `### <version>` heading block at the top of the same section. A conflict deeper in the file (both sides edited the *same* existing entry's prose) is non-trivial — abort and bail `blocked rebase #<M>: CHANGELOG conflict outside the top-of-file insert — needs manual rebase`.

   **Resolution (only when all four gates hold):**

   1. **Determine the PR's release level, then compute the next free version at *that* level (bump-level-aware, issue [#673](https://github.com/mattsears18/shipyard/issues/673)).** The floor is `main`'s manifest version (the `>>>>>>>`/`theirs` side of the manifest conflict — read it directly from the rebased-onto tree). A **patch-only** bump here is a latent correctness trap: a PR pre-allocated a **major** (breaking) or **minor** (feature) release gets silently downgraded to a patch on rebase — e.g. a PR pre-allocated `3.0.0` whose main advanced to `2.4.5` must resolve to `3.0.0`, not `2.4.6`. This mirrors the same downgrade [#671](https://github.com/mattsears18/shipyard/issues/671) fixed in the dispatch-time next-available-version computation (`dispatch-rules.md`) and the A.0.5 crash-recovery bump (`steady-state.md`).

      Infer the PR's intended level from the **ground truth the PR already encodes** — the delta between its own pre-allocated version and its merge-base with main — NOT re-derived from the issue title (by rebase time the version delta is more reliable than prose). `origin/$HEAD_REF` still points at the pre-rebase head (the force-push is step 6, not yet run), so both reads are stable refs independent of the in-progress rebase state:

      ```bash
      floor=$(git show "origin/$DEFAULT_BRANCH:$vc_manifest" | jq -r "$vc_version_jq")
      pr_version=$(git show "origin/$HEAD_REF:$vc_manifest" | jq -r "$vc_version_jq")
      base_sha=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH")
      base_version=$(git show "$base_sha:$vc_manifest" | jq -r "$vc_version_jq")

      # The PR's claimed level = the highest semver component it advanced over
      # its merge-base (major wins over minor wins over patch).
      IFS='.' read -r bMAJ bMIN bPAT <<< "$base_version"
      IFS='.' read -r pMAJ pMIN pPAT <<< "$pr_version"
      if   [ "${pMAJ:-0}" -gt "${bMAJ:-0}" ]; then bump_level="major"
      elif [ "${pMIN:-0}" -gt "${bMIN:-0}" ]; then bump_level="minor"
      else bump_level="patch"; fi

      # next_free = floor bumped at the inferred level — the SAME level-aware
      # bump shape #671 landed in dispatch-rules.md (major → (X+1).0.0,
      # minor → X.(Y+1).0, patch → X.Y.(Z+1)); higher levels zero the lower
      # components per semver.
      IFS='.' read -r fMAJ fMIN fPAT <<< "$floor"
      case "$bump_level" in
        major)   next_free="$((fMAJ + 1)).0.0" ;;
        minor)   next_free="${fMAJ}.$((fMIN + 1)).0" ;;
        patch|*) next_free="${fMAJ}.${fMIN}.$((fPAT + 1))" ;;
      esac
      ```

      Use `next_free`, NOT this PR's stale pre-allocated version (which sits below the floor — that's why the rebase conflicted). (If a later sibling already claimed `next_free` and this PR would collide again, the next rebase pass re-runs this resolution against the new floor — each pass advances to the next free slot at the PR's level.) Per #671's "the floor is the hard constraint, the level is the PR's" principle, the benign edge case where the merge-base delta *over*-estimates the level (a patch PR that was pre-allocated above an in-flight minor sibling's floor at dispatch time) bumps one level too high but never below the floor and never collides — strictly safer than the downgrade this fixes.
   2. **Write the resolved manifest.** Set the `.version` row to `next_free`. Take main's side for every other key (there are none in conflict per gate 3, so a plain `git checkout --theirs "$vc_manifest"` followed by a single `jq`-set of the version row is the cleanest mechanical resolution — or hand-edit the one conflicted line to the computed value and delete the markers).
   3. **Re-number + reorder the CHANGELOG entry (when coordinated).** This PR's CHANGELOG block keeps its prose but its `### <old-version> — <date>` heading is renumbered to `### <next-free-version> — <date>`, and the block is placed **newest-first**: above main's newly-merged top entry. The result must be strictly descending by version with no out-of-order or duplicate `###` headings. (A naïve CHANGELOG "take both" concat would leave this PR's stale lower-versioned entry *below* main's — that out-of-order entry is exactly the bug the issue calls out; re-number + hoist to the top fixes it.)
   4. `git add "$vc_manifest"` (and `"$vc_changelog"` when coordinated), then `git rebase --continue`.

   After resolving, fall through to step 5 (clean-tree check) and **step 5.5 (the [#436](https://github.com/mattsears18/shipyard/issues/436) conflict-marker assertion) — which is non-negotiable here**: the version-row + CHANGELOG hand-resolution is precisely the "take both, drop the markers" shape that can leave a stray `=======` / `>>>>>>>` line behind. Step 5.5's `git grep` for surviving markers is the safety net that turns a botched re-number into a clean `blocked rebase` instead of a poisoned force-push. Do not skip it.

5. **Verify the working tree is clean after resolution.** Every conflict was either auto-resolvable or you bailed in step 4. If you got here with `git status` showing nothing staged/unstaged but the rebase didn't complete, something is off — bail with `blocked rebase #<M>: rebase ended in inconsistent state`.

   ```bash
   git status --porcelain   # must be empty
   git rev-parse HEAD       # should NOT equal origin/$DEFAULT_BRANCH (you'd have nothing to push)
   ```

   If the rebase produced zero new commits because the branch was already a fast-forward of default (rare — would mean `mergeStateStatus` was lying), return `noop: not dirty (already fast-forward)`. No push needed.

5.5. **Assert no conflict markers survived the resolution — bail if any remain (issue [#436](https://github.com/mattsears18/shipyard/issues/436)).** A `git status`-clean working tree is NOT sufficient proof that a trivial auto-resolution (step 4) actually removed every conflict marker: a "take both blocks, drop the markers" CHANGELOG concat that leaves a stray `=======` or `>>>>>>> <sha>` line still stages clean and commits clean. Before the force-push, grep the rebased tree for the anchored conflict-marker pattern and refuse to push if any line matches:

   ```bash
   if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ; then
     git rebase --abort 2>/dev/null || true
     echo "blocked rebase #<M>: conflict markers remain after resolution — needs manual rebase"
     exit 0
   fi
   ```

   The regex is exactly seven of `<` / `=` / `>` at line start followed by a space or end-of-line — the same pattern the repo's `conflict-marker-scan.sh` CI gate (and the `check-merge-conflict` pre-commit hook) use, so a worker that passes this assertion also passes the CI gate. `git grep` exits 0 (and prints the offending `file:line`) when it finds a match, so the `if` branch fires exactly when a marker survived; bail with `blocked rebase` rather than force-pushing the corruption. This is the worker-side half of issue #436's two-layer defense — the CI gate (`.github/workflows/conflict-markers.yml`) is the repo-side catch-net for any path that bypasses this assertion (a non-shipyard force-push, a manual merge), and this assertion stops a fix-rebase dispatch from being the thing that needs catching.

   The original poison-the-main incident was caught only because a *later* manual rebase inherited the markers; the green CI run that merged the corrupted CHANGELOG had no gate that greps for markers. This assertion + the CI gate close that hole from both ends.

5.6. **Assert no released CHANGELOG headings were deleted by the resolution — bail if any are missing (issue [#555](https://github.com/mattsears18/shipyard/issues/555)).** The conflict-marker assertion in step 5.5 catches *unresolved* markers; it cannot catch a *resolved-wrong* merge that silently deletes whole `### <version>` heading blocks. This is the failure mode from issue #555: PR #552 and #553 resolved their CHANGELOG conflicts correctly (no markers survived) yet both dropped released entries (`### 1.9.10` and `### 1.9.9`) from main. The loss was only noticed when a human eyeballed the file during a later manual rebase.

   Before the force-push, run the monotonicity scan to confirm every `### <version>` heading that existed on the rebase base (`origin/$DEFAULT_BRANCH`) is still present in the resolved CHANGELOG:

   ```bash
   # Re-derive CLAUDE_PLUGIN_ROOT (variables don't survive across Bash tool calls).
   CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
   scanner="${CLAUDE_PLUGIN_ROOT}/scripts/changelog-monotonicity-scan.sh"
   if [[ -f "$scanner" ]]; then
     if ! bash "$scanner" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
       git rebase --abort 2>/dev/null || true
       echo "blocked rebase #<M>: deleted released CHANGELOG heading(s) after conflict resolution — needs manual rebase (https://github.com/mattsears18/shipyard/issues/555)"
       exit 0
     fi
   fi
   ```

   This assertion is the worker-side half of issue #555's two-layer defense — the CI gate (`changelog-monotonicity-scan.sh` run against the PR head in `tests.yml`) is the repo-side catch-net for any path that bypasses this assertion. Together they mirror the #436 two-layer pattern: this assertion stops a fix-rebase dispatch from being the thing that silently drops entries; the CI gate catches anything that slips through.

   A CHANGELOG with a `changelog-monotonicity-scan: allow` directive opts out of the scan (useful for test fixtures that construct synthetic CHANGELOGs). If the scanner binary isn't present (non-shipyard repo, older plugin installation), skip silently — the CI gate is the load-bearing layer.

5.7. **Post-rebase empty-diff guard — bail if the conflict resolution dropped the PR's change (issue [#646](https://github.com/mattsears18/shipyard/issues/646)).** The conflict-marker assertion (step 5.5) catches *unresolved* markers and the monotonicity scan (step 5.6) catches deleted CHANGELOG headings — but neither catches a resolution that **silently discards the PR's entire substantive change**, collapsing the branch to an empty diff vs base. This is the silent-data-loss failure mode from issue #646: a `fix-rebase` worker resolved a same-line provenance conflict by taking main's side **wholesale** (a whole-file `--theirs`, discarding the PR's non-conflicting substantive hunk in the same file), the net diff vs base went empty, the force-push **auto-closed the PR** (GitHub auto-closes a PR whose head force-pushes to an empty-diff state), and the worker returned `rebased #<M>` (success) — so the shipped work was lost with no `blocked` signal. The #646 repro: PR #2165 (a PostHog Region-column pin) force-pushed to an empty diff, auto-closed, and its issue reverted to OPEN; the change had to be redone from scratch.

   **Before the force-push, compare the PR's net contribution vs base before and after the rebase. If it was non-empty before and is empty after, the resolution dropped the change — bail instead of pushing.** `origin/$HEAD_REF` still points at the pre-rebase head (the force-push is step 6, not yet run), so it's the pre-rebase baseline; the local rebased `HEAD` is based directly on `origin/$DEFAULT_BRANCH`, so its two-dot diff vs that base **is** the PR's net contribution:

   ```bash
   # Pre-rebase net contribution (the original head's change vs the rebased-onto base).
   PRE_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH...origin/$HEAD_REF" | wc -l | tr -d ' ')
   # Post-rebase net contribution (the rebased head's change vs the same base).
   POST_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH" HEAD | wc -l | tr -d ' ')
   if [ "${PRE_FILES:-0}" -gt 0 ] && [ "${POST_FILES:-0}" = "0" ]; then
     git rebase --abort 2>/dev/null || true
     echo "blocked rebase #<M>: rebase produced an empty diff (conflict resolution dropped the PR's change) — needs manual rebase"
     exit 0
   fi
   ```

   **Never force-push a branch whose net change vs base vanished.** Bailing leaves `origin/$HEAD_REF` and the PR untouched (the PR stays DIRTY for a human to rebase by hand) — the safe outcome whether the emptiness came from a dropped change (the data loss to prevent) or from the change having already landed on main via a sibling PR (in which case a human closes the PR cleanly rather than letting a silent force-push auto-close it). The guard is gated on `PRE_FILES > 0` so a PR that was *already* empty before the rebase doesn't false-bail. This assertion runs for **both** the conflict-resolved path and the clean-rebase path — a clean rebase whose result is empty is just as much a silent auto-close hazard. This is the worker-side root fix for #646; never resolve a conflict in a way that can produce this state in the first place (see the hunk-level resolution rule in step 4).

6. **Push the rebased branch.** This is a fast-forward-incompatible operation (rebase rewrites commit SHAs), so a force push with lease is required:
   ```bash
   git push --force-with-lease origin "$HEAD_REF"
   ```

   `--force-with-lease` (not plain `--force`) refuses the push if someone else pushed to the branch between your `git fetch` and your `git push`. That's the safety net against clobbering a concurrent author push — bail with `blocked rebase #<M>: head branch moved during rebase — retry next session` if the lease check rejects.

7. **Return one line.** No `gh pr edit`, no `gh pr merge --auto` re-call (auto-merge was already armed when the PR was opened; rebasing doesn't un-arm it), no `--watch`, and — per `shipyard:worker-preamble` § "Return-contract discipline" ([#529](https://github.com/mattsears18/shipyard/issues/529)) — no arming a `run_in_background` process / `Monitor` / background-waiter and returning a non-terminal narrative before it resolves. Run the rebase synchronously to a terminal state and return exactly one of the strings below. The drain phase's next per-poll snapshot will see the PR transition out of DIRTY:
   - `rebased #<M>` — rebase succeeded, branch was force-pushed, drain phase resumes monitoring it.
   - `noop: not dirty (<reason>)` — pre-flight (step 2) found the PR was no longer DIRTY by the time you started; reason is the actual `mergeStateStatus` or `state` value observed.
   - `blocked rebase #<M>: <reason>` — conflict was non-trivial, head branch moved under you, or some other deterministic failure. The drain will leave this PR alone for the rest of the session and surface it in the end-of-session summary as a still-DIRTY PR needing human attention.

## Hard rules

- One rebase attempt per dispatch. If the first attempt blocks, return `blocked` — do NOT retry. The drain will move on; a human (or the next session) can pick it up.
- Never `gh pr merge` manually. Auto-merge was armed when the PR was first opened (or by the orchestrator's reconcile after a fix-checks). Rebasing a green-or-pending PR is sufficient to re-arm the merge train; manual merging would skip the merge train's protection against last-second base drift.
- Never edit the PR's title, body, or labels. The PR's existing description references the original commits — a rebase preserves their content, not necessarily their SHAs, but the human-readable summary stays correct.
- Never close the linked issue from this dispatch. The PR's body already has the `Closes #N` line; merging the rebased branch closes the issue automatically.
- **Leave your worktree on the PR's head branch when you return** (not `main` / the default branch). See worker-preamble's worktree discipline rule 3.

## Don't

- **Don't resolve a non-trivial merge conflict.** The trivial-or-bail rule exists because rebase-mode dispatches happen during the drain phase, when the orchestrator is winding down and the goal is keeping the merge train moving — not authoring code. A merge conflict that requires reading more than the conflict markers is a signal that the rebase needs a human (or a fresh issue-mode dispatch in a future session). `git rebase --abort` and return `blocked rebase`. The instinct to "just figure out which side wins, it looks small" is the failure mode this rule prevents — semantic merges in a drain context don't have the test scaffolding or review attention they need to be correct.
- **Don't `gh pr merge` manually.** Auto-merge was armed when the PR was originally opened (in issue-work mode's step 6, or by the orchestrator's reconcile after a fix-checks-only dispatch). Force-pushing a rebased branch doesn't un-arm auto-merge — the next green CI run on the rebased head will trigger it. Manually calling `gh pr merge` would bypass the merge train's protection against last-second base drift; the auto path is what should resolve the PR.
- Don't `--watch` checks. Push the rebased branch, return one line, let the drain's next poll observe the state transition.
- **Don't open a `Monitor`/poll loop to watch CI to completion instead of returning ([#753](https://github.com/mattsears18/shipyard/issues/753)).** Push the rebased branch and return immediately — never start a `Monitor` sub-task or a backgrounded CI watch and wait for the rebased head to go green before returning. See `shipyard:worker-preamble` § "Return-contract discipline".
- Don't retry on `blocked rebase`. One dispatch, one rebase attempt — the drain doesn't re-dispatch within the same session.
