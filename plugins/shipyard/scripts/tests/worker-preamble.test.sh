#!/usr/bin/env bash
# Test: the worker-preamble skill exists and each of the five dispatch prompt
# templates in commands/do-work.md references it instead of inlining the
# worktree-discipline preamble verbatim.
#
# Background — issue #107: do-work.md previously duplicated the same ~600-char
# worktree-discipline preamble across all five dispatch prompt templates
# (fix-main-ci, fix-failing-prs-batch, fix-checks-only, fix-rebase, issue-work).
# When the preamble drifted in one place and not the others, the agent that
# silently inherited stale rules could move the user's primary checkout's HEAD
# via `gh pr checkout` or park a worktree on `[main]`. The DRY refactor lifts
# the shared preamble into a skill that every dispatch prompt loads by name.
#
# This test is the regression guard: if anyone reintroduces the duplicated
# verbatim preamble (or removes the skill), the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/worker-preamble.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
# Issue #617 — the 85KB SKILL.md was split into a thin always-loaded core
# (SKILL.md) + on-demand fragments alongside it. Rarely-hit reference sections
# moved into fragment files; the assertions below read each section's strings
# from whichever file now owns it. The fragment paths:
wp_dir="$repo_root/plugins/shipyard/skills/worker-preamble"
auto_merge_path="$wp_dir/auto-merge.md"
reaped_path="$wp_dir/reaped-escape-hatch.md"
node_bootstrap_path="$wp_dir/node-bootstrap.md"
ci_pitfalls_path="$wp_dir/ci-pitfalls.md"
commit_hygiene_path="$wp_dir/commit-hygiene.md"
do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"
# The dispatch prompts live in the steady-state phase after the issue #154
# split, and the divert/fix-checks/issue-work prompt templates moved again into
# commands/do-work/dispatch-rules.md when the consulted-not-executed Dispatch
# rules block was extracted from steady-state.md (issue #616). The worker-
# preamble reference count and the no-inlined-sentence regression guard both
# target the dispatch prompts, so concatenate the steady-state hot path + the
# dispatch-rules reference so assertion (2) below sees every dispatch prompt
# regardless of which file it now lives in.
steady_state_hot_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state_path="$(mktemp -t worker-preamble-steady-concat.XXXXXX)"
cat "$steady_state_hot_path" "$dispatch_rules_path" > "$steady_state_path" 2>/dev/null
trap 'rm -f "$steady_state_path"' EXIT

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
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_count_at_least() {
  local file="$1"
  local needle="$2"
  local min="$3"
  local label="$4"
  local count
  count=$(grep -cF -- "$needle" "$file" 2>/dev/null | head -n 1)
  count=${count:-0}
  if (( count >= min )); then
    printf '  %sPASS%s  %s (found %d occurrences, expected ≥ %d)\n' \
      "$GREEN" "$RESET" "$label" "$count" "$min"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %d occurrences, expected ≥ %d)\n' \
      "$RED" "$RESET" "$label" "$count" "$min"
    fail=$((fail+1))
  fi
}

assert_count_at_most() {
  local file="$1"
  local needle="$2"
  local max="$3"
  local label="$4"
  local count
  count=$(grep -cF -- "$needle" "$file" 2>/dev/null | head -n 1)
  count=${count:-0}
  if (( count <= max )); then
    printf '  %sPASS%s  %s (found %d occurrences, expected ≤ %d)\n' \
      "$GREEN" "$RESET" "$label" "$count" "$max"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %d occurrences, expected ≤ %d)\n' \
      "$RED" "$RESET" "$label" "$count" "$max"
    fail=$((fail+1))
  fi
}

echo "worker-preamble skill regression tests (issue #107)"
echo

# (1) Skill file must exist with proper YAML frontmatter.
assert_file_exists "$skill_path" "worker-preamble SKILL.md exists"

if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "name: worker-preamble" \
    "SKILL.md frontmatter declares name: worker-preamble"
  assert_contains "$skill_path" "description:" \
    "SKILL.md frontmatter has a description field"

  # Issue #617 — the on-demand fragments must exist alongside SKILL.md, and
  # SKILL.md's fragment-index must point at each one so a worker can find the
  # section it needs. Removing a fragment (or its index row) regresses the
  # split — a worker mode would lose access to the rule the fragment owns.
  assert_file_exists "$auto_merge_path" "worker-preamble fragment auto-merge.md exists (issue #617)"
  assert_file_exists "$reaped_path" "worker-preamble fragment reaped-escape-hatch.md exists (issue #617)"
  assert_file_exists "$node_bootstrap_path" "worker-preamble fragment node-bootstrap.md exists (issue #617)"
  assert_file_exists "$ci_pitfalls_path" "worker-preamble fragment ci-pitfalls.md exists (issue #617)"
  assert_file_exists "$commit_hygiene_path" "worker-preamble fragment commit-hygiene.md exists (issue #617)"
  assert_contains "$skill_path" "## On-demand fragments" \
    "SKILL.md has an On-demand fragments index section (issue #617)"
  assert_contains "$skill_path" "(./auto-merge.md)" \
    "SKILL.md fragment-index links auto-merge.md (issue #617)"
  assert_contains "$skill_path" "(./reaped-escape-hatch.md)" \
    "SKILL.md fragment-index links reaped-escape-hatch.md (issue #617)"
  assert_contains "$skill_path" "(./node-bootstrap.md)" \
    "SKILL.md fragment-index links node-bootstrap.md (issue #617)"
  assert_contains "$skill_path" "(./ci-pitfalls.md)" \
    "SKILL.md fragment-index links ci-pitfalls.md (issue #617)"
  assert_contains "$skill_path" "(./commit-hygiene.md)" \
    "SKILL.md fragment-index links commit-hygiene.md (issue #617)"
  # The thin core must stay thin: SKILL.md is the always-loaded file, so its
  # line count is the per-dispatch context tax #617 set out to cut. Assert it
  # stays well under half the pre-split ~593 lines.
  skill_lines=$(wc -l < "$skill_path" | tr -d ' ')
  if (( skill_lines < 300 )); then
    printf '  %sPASS%s  SKILL.md thin core stays under 300 lines (%d) (issue #617)\n' \
      "$GREEN" "$RESET" "$skill_lines"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  SKILL.md thin core grew past 300 lines (%d) (issue #617)\n' \
      "$RED" "$RESET" "$skill_lines"
    fail=$((fail+1))
  fi

  # Skill must enumerate the four load-bearing rules verbatim so any single
  # reader sees the full contract without bouncing between docs.
  assert_contains "$skill_path" "isolated git worktree" \
    "SKILL.md covers the isolated-worktree rule"
  assert_contains "$skill_path" "gh pr checkout" \
    "SKILL.md covers the no-gh-pr-checkout rule"
  assert_contains "$skill_path" "git switch" \
    "SKILL.md covers the no-git-switch-to-default rule"
  assert_contains "$skill_path" "--label shipyard" \
    "SKILL.md covers the shipyard label requirement"

  # Issue #158 — `gh` JSON discipline convention section.
  # The convention exists so every worker mode consistently scopes
  # `gh ... --json` responses to the fields it actually consumes; removing
  # the section regresses the per-call token-cost contract.
  assert_contains "$skill_path" "## \`gh\` JSON discipline" \
    "SKILL.md covers the gh JSON discipline convention (issue #158)"
  assert_contains "$skill_path" "--json <fields>" \
    "SKILL.md names the --json <fields> pattern"
  assert_contains "$skill_path" "--jq" \
    "SKILL.md names the --jq projection flag"

  # Issue #297 — "Stop background processes before returning" section.
  # The section exists so workers don't leak Monitor sub-tasks /
  # run_in_background bash calls past their terminal return, which would
  # otherwise re-invoke the orchestrator for a no-op turn every time the
  # leaked process emits a status notification (lightwork repro: 50+ stale
  # wake events across two fix-checks-worker dispatches). Removing the
  # section regresses the notification-leak contract.
  assert_contains "$skill_path" "## Stop background processes before returning" \
    "SKILL.md covers the background-process cleanup rule (issue #297)"
  assert_contains "$skill_path" "TaskStop" \
    "SKILL.md names TaskStop as the Monitor / sub-Agent stop mechanism"
  assert_contains "$skill_path" "KillShell" \
    "SKILL.md names KillShell as the background-Bash stop mechanism"
  assert_contains "$skill_path" "run_in_background" \
    "SKILL.md names run_in_background: true as a leak source"
  assert_contains "$skill_path" "Monitor" \
    "SKILL.md names Monitor as a leak source"

  # Issue #316 — "Dependency-bootstrap check for Node-based target repos"
  # section. The section exists because the harness creates agent worktrees
  # via `git worktree add` without installing npm deps, so any Node-based
  # target repo whose pre-push hook shells out to node_modules/.bin/<tool>
  # silently passes when node_modules is missing — turning the local-test
  # discipline into a no-op. Removing the section regresses the silent-pass
  # contract; removing the symlink remediation path regresses the
  # cheapest-recovery contract (worker would jump straight to the 30-90s
  # `npm ci` path or, worse, skip the check entirely).
  assert_contains "$node_bootstrap_path" "## Dependency-bootstrap check for Node-based target repos" \
    "node-bootstrap.md covers the Node-deps bootstrap check (issue #316)"
  assert_contains "$node_bootstrap_path" "package.json" \
    "node-bootstrap.md names package.json as the Node-repo detector for the bootstrap check"
  assert_contains "$node_bootstrap_path" "node_modules" \
    "node-bootstrap.md names node_modules as the missing-dir signal for the bootstrap check"
  assert_contains "$node_bootstrap_path" "ln -s ../../../node_modules node_modules" \
    "node-bootstrap.md provides the symlink-from-primary-checkout remediation recipe"
  assert_contains "$node_bootstrap_path" "npm ci" \
    "node-bootstrap.md provides the npm ci fallback remediation"
  assert_contains "$node_bootstrap_path" "cannot bootstrap node_modules" \
    "node-bootstrap.md names the blocked: bail string for the fail-both-paths case"

  # Issue #694 — introduce a NEW dependency at the latest stable version, with
  # the peer/SDK carve-out. A worker that adds a package pinned to a
  # training-data-remembered stale version starts the dep behind and it only
  # drifts further (the observed multi-major debt + shipped native crash on
  # lightwork). The section establishes latest-stable-by-default, the
  # unconditional peer/SDK carve-out (framework-required version instead), the
  # expo install preference for Expo repos, recording the version in the PR
  # body, and introduction-only scope. Removing any of these regresses the
  # introduction-time-version-debt contract.
  assert_contains "$node_bootstrap_path" "## Adding a NEW dependency — default to the latest stable version" \
    "node-bootstrap.md covers introducing a new dependency at latest stable (issue #694)"
  assert_contains "$node_bootstrap_path" "npm install <pkg>@latest" \
    "node-bootstrap.md names the latest-stable installer for a new dep (issue #694)"
  assert_contains "$node_bootstrap_path" "Record the resolved version in the PR body" \
    "node-bootstrap.md requires recording the resolved version in the PR body (issue #694)"
  assert_contains "$node_bootstrap_path" "load-bearing carve-out" \
    "node-bootstrap.md names the peer/SDK load-bearing carve-out (issue #694)"
  assert_contains "$node_bootstrap_path" "npx expo install <pkg>" \
    "node-bootstrap.md prefers expo install for Expo repos (issue #694)"
  assert_contains "$node_bootstrap_path" "new_dep_version" \
    "node-bootstrap.md references the dependencies.new_dep_version config knob (issue #694)"
  assert_contains "$node_bootstrap_path" "introduction only" \
    "node-bootstrap.md scopes the rule to dependency introduction, not upgrades (issue #694)"

  # Issue #708 — "Nested non-hoisted packages need their own install before
  # their gates" section. The section exists because the documented root + app
  # `npm ci` is insufficient for a nested, non-hoisted package (a Firebase
  # `functions/`, some monorepo service dirs) whose test/build suite resolves
  # its own deps from its own node_modules — neither install creates that
  # nested node_modules, so the nested suite fails module resolution until the
  # worker also `npm ci`s inside the nested package (lightwork functions repro,
  # session_01Hs4CqGT53F6kwVasHiyLnH). The section must carry the cheapest
  # heuristic (install the nested pkg your diff touches), the bounded-search
  # scope (not a full-tree sweep), the distinct-from-#680 note (nested test
  # suite vs root commit hook), and the generic (non-hardcoded-path) framing.
  # Removing any of these regresses the nested-non-hoisted-install contract.
  assert_contains "$node_bootstrap_path" "## Nested non-hoisted packages need their own install before their gates" \
    "node-bootstrap.md covers the nested non-hoisted package install rule (issue #708)"
  assert_contains "$node_bootstrap_path" "([#708](https://github.com/mattsears18/shipyard/issues/708))" \
    "node-bootstrap.md's nested-package section cites issue #708"
  assert_contains "$node_bootstrap_path" "\`npm ci\` there before running that package's gates" \
    "node-bootstrap.md gives the cheapest heuristic: npm ci in the touched nested dir before its gates (issue #708)"
  assert_contains "$node_bootstrap_path" "Bounded search, not a full sweep" \
    "node-bootstrap.md bounds the nested-package detection to a bounded search, not a full-tree sweep (issue #708)"
  assert_contains "$node_bootstrap_path" "Distinct from the root-husky/commit-hook install gap" \
    "node-bootstrap.md marks the nested-package rule distinct from the #680 root-commit-hook gap (issue #708)"
  assert_contains "$node_bootstrap_path" "Don't hardcode a specific repo's paths" \
    "node-bootstrap.md keeps the nested-package rule generic, not hardcoded to a repo's paths (issue #708)"

  # Issue #322 — Bash-tool isolation gotcha in the worktree-reaped escape hatch.
  # The pre-#322 snippet documented a "save once, reuse" pattern that tripped
  # the very guard it was meant to enforce when run through the Bash tool:
  # each tool call spawns a fresh shell, so $WORKTREE_PATH set in one call
  # was empty in the next, the `! -d ""` check was true, and the worker
  # emitted a false-positive `reaped:` exit on its first commit. The fix
  # makes the re-derive-at-top-of-every-call pattern explicit. Removing the
  # Bash-tool-isolation callout or the re-derive recipe regresses the
  # first-commit-false-positive contract.
  assert_contains "$reaped_path" "Bash-tool isolation" \
    "reaped-escape-hatch.md calls out Bash-tool isolation as the gotcha (issue #322)"
  assert_contains "$reaped_path" "Re-derive \`WORKTREE_PATH\`" \
    "reaped-escape-hatch.md prescribes re-deriving WORKTREE_PATH at the top of every write-class call (issue #322)"
  assert_contains "$reaped_path" "do not survive" \
    "reaped-escape-hatch.md explains that variables do not survive across Bash tool calls (issue #322)"
  assert_contains "$reaped_path" "false-positive \`reaped:\` exit" \
    "reaped-escape-hatch.md names the false-positive reaped: exit failure mode (issue #322)"

  # Issue #328 — Auto Mode constraint on node_modules symlink remediation.
  # The symlink path (ln -s ../../../node_modules) is denied by the Auto Mode
  # classifier because it creates a writable link to a directory outside the
  # worktree's scope. Workers running under Auto Mode waste one tool-call turn
  # discovering this denial unless the preamble tells them to skip directly to
  # npm ci. The fix adds an Auto Mode caveat at the exact spot where the symlink
  # recipe lives, so a worker reading the remediation list sees the constraint
  # without bouncing between sections. It also documents cp -al as a hard-link
  # copy alternative that the classifier should allow. Removing these docs
  # regresses the Auto-Mode-symlink-denial contract.
  assert_contains "$node_bootstrap_path" "Auto Mode constraint" \
    "node-bootstrap.md names the Auto Mode constraint on the symlink path (issue #328)"
  assert_contains "$node_bootstrap_path" "auto-mode classifier" \
    "node-bootstrap.md names the auto-mode classifier as the denier (issue #328)"
  assert_contains "$node_bootstrap_path" "skip the symlink entirely and go directly to \`npm ci\`" \
    "node-bootstrap.md tells Auto Mode workers to skip the symlink and go straight to npm ci (issue #328)"
  assert_contains "$node_bootstrap_path" "cp -al" \
    "node-bootstrap.md documents cp -al hard-link copy as an alternative to the symlink (issue #328)"

  # Issue #458 — Next 16 / Turbopack constraint on the node_modules link
  # strategies. Next.js 16's Turbopack refuses a node_modules that resolves
  # outside the worktree's filesystem root, so the ../../../node_modules symlink
  # (and the cp -al hard-link copy, whose real inodes still live under the
  # primary checkout) fail with "Symlink ... points out of the filesystem root".
  # Workers on a Turbopack repo waste one tool-call turn rediscovering this
  # unless the preamble tells them to detect Turbopack/Next 16 and skip directly
  # to npm ci. The fix adds the detection snippet + constraint at the symlink
  # remediation spot. Removing these docs regresses the Turbopack-skip contract.
  assert_contains "$node_bootstrap_path" "Next 16 / Turbopack constraint" \
    "node-bootstrap.md names the Next 16 / Turbopack constraint on the link strategies (issue #458)"
  assert_contains "$node_bootstrap_path" "points out of the filesystem root" \
    "node-bootstrap.md names the Turbopack 'points out of the filesystem root' failure (issue #458)"
  assert_contains "$node_bootstrap_path" "uses_turbopack" \
    "node-bootstrap.md provides the Turbopack/Next-16 detection snippet (issue #458)"

  # Issue #418 — "Mirror new string constants into locale / parity files"
  # section. The section exists because a worker that adds a user-facing string
  # to a centralized strings module (lib/strings.ts etc.) but forgets to mirror
  # the key into every locale file the repo's parity test requires (i18n.test.ts
  # etc.) reds CI on a key-parity assertion — a recurring, self-inflicted CI
  # break that costs a fix-checks cycle each time (lightwork repro: 3× in one
  # session across PRs #1443 / #1444 / #1447). Removing the section regresses the
  # mirror-the-key-before-push contract.
  assert_contains "$ci_pitfalls_path" "## Mirror new string constants into locale / parity files" \
    "ci-pitfalls.md covers the locale/parity mirror check (issue #418)"
  assert_contains "$ci_pitfalls_path" "parity test" \
    "ci-pitfalls.md names the parity test as the CI-red trigger (issue #418)"
  assert_contains "$ci_pitfalls_path" "mirror the new key into every file the test requires" \
    "ci-pitfalls.md prescribes mirroring the key into every required locale/parity file (issue #418)"

  # Issue #440 — "GitHub push-protection blocking a synthetic test-fixture
  # secret" section. The section exists because a worker adding a NEW test
  # fixture with a realistic-shaped secret (to exercise a scrubber / secret-scan
  # rule) gets its push bounced by GitHub's server-side push-protection — a
  # SEPARATE scanner from .gitleaks.toml, so the fixture being gitleaks-
  # allowlisted does not exempt it (the #402 / #408 scrubber-fixture workers hit
  # exactly this). Removing the section regresses the never-click-the-unblock-URL
  # + rewrite-to-synthetic + rebuild-the-commit contract.
  assert_contains "$ci_pitfalls_path" "## GitHub push-protection blocking a synthetic test-fixture secret" \
    "ci-pitfalls.md covers the push-protection synthetic-fixture block (issue #440)"
  assert_contains "$ci_pitfalls_path" "NEVER click the server-side unblock URL" \
    "ci-pitfalls.md tells the worker never to click the push-protection unblock URL (issue #440)"
  assert_contains "$ci_pitfalls_path" "obviously-synthetic value that still matches the pattern under test" \
    "ci-pitfalls.md prescribes rewriting the fixture to an obviously-synthetic value (issue #440)"
  assert_contains "$ci_pitfalls_path" "flagged blob never enters pushed history" \
    "ci-pitfalls.md prescribes rebuilding the commit so the flagged blob never enters pushed history (issue #440)"
  assert_contains "$ci_pitfalls_path" "NOT the same scanner as \`.gitleaks.toml\`" \
    "ci-pitfalls.md distinguishes push-protection from the .gitleaks.toml committed-content scanner (issue #440)"

  # Issue #459 — "Husky / core.hooksPath hooks silently skipped on a missing
  # exec bit" section. The section exists because a fresh `git worktree add`
  # checks out hook files with their committed mode and runs no npm `prepare`
  # lifecycle script, so a repo whose .husky/pre-commit was committed 100644
  # (or whose hooks are provisioned only via `husky install`) ends up with
  # inert hooks — git silently skips a non-executable hook (advisory hint to
  # stderr, exit 0), so lint-staged / prettier never run and no --no-verify
  # was passed (mattsears18.com session do-work-20260601T004608Z, #170 worker).
  # Removing the section regresses the detect-and-chmod-or-npm-ci contract.
  assert_contains "$node_bootstrap_path" "## Husky / \`core.hooksPath\` hooks silently skipped on a missing exec bit" \
    "node-bootstrap.md covers the non-executable-hook silent-skip (issue #459)"
  assert_contains "$node_bootstrap_path" "silently ignores a hook that isn't marked executable" \
    "node-bootstrap.md names the git silent-skip behavior for non-executable hooks (issue #459)"
  assert_contains "$node_bootstrap_path" "chmod +x" \
    "node-bootstrap.md prescribes chmod +x on the worktree hook files as remediation (issue #459)"
  assert_contains "$node_bootstrap_path" "Never reach for \`--no-verify\` as a \"workaround.\"" \
    "node-bootstrap.md forbids --no-verify as the fix for a silently-skipped hook (issue #459)"

  # Issue #475 — "Pin the default branch in git-using test fixtures" section.
  # The section exists because a worker authoring a *.test.sh fixture that
  # `git init`s a throwaway repo and later names the default branch (e.g.
  # `git checkout main`) passes its pre-push sweep on macOS (init.defaultBranch
  # = main) but reds on CI's Ubuntu runner (init.defaultBranch = master) with
  # `pathspec 'main' did not match`. On a merged-direct-ungated repo there is no
  # PR gate to catch it, so main goes red (repro: #466 fixture → recovery #473).
  # Removing the section regresses the pin-the-branch authoring rule and the
  # GIT_CONFIG_GLOBAL=master verification recipe.
  assert_contains "$ci_pitfalls_path" "## Pin the default branch in git-using test fixtures" \
    "ci-pitfalls.md covers the git-fixture default-branch pin (issue #475)"
  assert_contains "$ci_pitfalls_path" "init.defaultBranch" \
    "ci-pitfalls.md names init.defaultBranch as the invisible host dependency (issue #475)"
  assert_contains "$ci_pitfalls_path" "git init -q -b main" \
    "ci-pitfalls.md prescribes pinning the fixture's initial branch with git init -b (issue #475)"
  assert_contains "$ci_pitfalls_path" "GIT_CONFIG_GLOBAL" \
    "ci-pitfalls.md provides the GIT_CONFIG_GLOBAL=master verification recipe (issue #475)"
  assert_contains "$ci_pitfalls_path" "did not match" \
    "ci-pitfalls.md names the pathspec-did-not-match CI failure (issue #475)"

  # Issue #486 — "Step-0 cwd fail-fast" section. The section exists because
  # an `isolation: "worktree"` dispatch can land with its process cwd pinned
  # to the PRIMARY checkout root instead of the created worktree (a harness-
  # level misroute shipyard can't fix at the source — AC items (1)/(2) of
  # #486 are out of shipyard's control). When that happens every git-mutating
  # command targets the primary checkout and the enforce-worktree hook blocks
  # the worker's final commit — but only after the worker has burned its whole
  # run (the repro: ~94 min of Opus dying at the final `git commit`). The
  # in-repo mitigation is a step-0 pre-flight assertion that fails fast with a
  # clear "dispatch-isolation cwd override is wrong" message instead of running
  # the full task and dying at commit. Removing the section (or the git-dir ==
  # git-common-dir primary-checkout detection that backs it) regresses the
  # fail-fast contract.
  assert_contains "$skill_path" "## Step-0 cwd fail-fast" \
    "SKILL.md covers the step-0 cwd fail-fast guard (issue #486)"
  assert_contains "$skill_path" "dispatch-isolation cwd override is wrong" \
    "SKILL.md emits the 'dispatch-isolation cwd override is wrong' bail message (issue #486)"
  assert_contains "$skill_path" "git rev-parse --git-common-dir" \
    "SKILL.md uses git-common-dir to detect a primary checkout vs a linked worktree (issue #486)"
  assert_contains "$skill_path" "git-dir == git-common-dir" \
    "SKILL.md names the git-dir == git-common-dir primary-checkout signal (issue #486)"
  assert_contains "$skill_path" "pinned to the PRIMARY checkout" \
    "SKILL.md names the cwd-pinned-to-primary failure mode (issue #486)"
  assert_contains "$skill_path" "This guard runs in every worker mode" \
    "SKILL.md states the cwd fail-fast runs in every worker mode (issue #486)"

  # Issue #748 — "Mid-session cwd anchoring" section. The step-0 fail-fast
  # above (#486) only asserts the cwd is correct once, at dispatch start —
  # #748 found plain relative-path Bash calls intermittently resolving
  # against the PRIMARY checkout LATER in the same dispatch, with no `cd`
  # ever issued and step-0 having passed cleanly. The mitigation is
  # anchoring every mutating command to an explicit, re-verified
  # WORKTREE_PATH rather than trusting ambient cwd — mandatory before a
  # write (git add/commit/push, gh pr create, file-destructive ops),
  # recommended for reads. Removing the section (or its re-verify pattern)
  # regresses the mid-session drift guard #748 exists to close.
  assert_contains "$skill_path" "## Mid-session cwd anchoring" \
    "SKILL.md covers the mid-session cwd anchoring guard (issue #748)"
  assert_contains "$skill_path" "not a per-call guarantee" \
    "SKILL.md frames step-0 as a one-shot, not a per-call, guarantee (issue #748)"
  assert_contains "$skill_path" "WORKTREE_PATH" \
    "SKILL.md names WORKTREE_PATH as the explicit anchor variable (issue #748)"
  assert_contains "$skill_path" "cwd anchor drifted mid-session" \
    "SKILL.md emits the 'cwd anchor drifted mid-session' bail message (issue #748)"
  assert_contains "$skill_path" "Mandatory — anchor every mutating command" \
    "SKILL.md makes anchoring mandatory before mutating commands (issue #748)"
  assert_contains "$skill_path" "Recommended, not mandatory — anchor read-only commands" \
    "SKILL.md makes anchoring recommended (not mandatory) for read-only commands (issue #748)"
  # shellcheck disable=SC2016
  # Literal grep needle — $WORKTREE_PATH is matched verbatim in the spec, not expanded.
  assert_contains "$skill_path" 'git -C "$WORKTREE_PATH"' \
    "SKILL.md prescribes git -C \"\$WORKTREE_PATH\" as the explicit anchoring pattern (issue #748)"

  # Issue #529 — "Run all work synchronously — NEVER arm a background process
  # and return" clause in the Return-contract discipline section. The clause
  # exists because a worker that arms a run_in_background waiter / Monitor and
  # returns a non-terminal progress narrative trips the harness into a
  # `status: completed` while the actual work is stranded (no commit, no PR) —
  # the orchestrator's A.0.5 re-dispatch recovers it but at full token cost
  # (the #529 repro burned ~145k tokens for zero output on #522). Removing the
  # clause regresses the run-synchronously-to-a-terminal-state contract.
  assert_contains "$skill_path" "NEVER arm a background process and return" \
    "SKILL.md forbids arming a background process and returning (issue #529)"
  assert_contains "$skill_path" "run_in_background" \
    "SKILL.md names run_in_background as a forbidden wait-then-return mechanism (issue #529)"
  assert_contains "$skill_path" "stranded mid-flight" \
    "SKILL.md names the stranded-work failure mode for a non-terminal return (issue #529)"
  assert_contains "$skill_path" "block your own turn on a foreground call" \
    "SKILL.md prescribes blocking on a foreground call as the correct wait mechanism (issue #529)"

  # Issue #598 — "wait for the PR's own checks before admin-direct-merge
  # instead of merging ungated" clause in the Auto-merge + snapshot-and-return
  # pattern (step 0.5). The clause exists because on a repo where the
  # dispatcher is admin, allow_auto_merge is false, and the base branch has no
  # required status checks, `gh pr merge --auto --merge` silently direct-merges
  # *immediately* — landing the PR before its own CI completes (ungated). The
  # pre-existing merged-direct-ungated advisory (#457) is only a post-hoc
  # signal; #598 adds a *pre-merge* gate that detects the ungated config before
  # arming the merge and waits for the PR's checks to settle, merging only when
  # green (a red PR is handed back so the orchestrator dispatches fix-checks).
  # The merged-direct-ungated advisory + fix-main-ci divert remain as the
  # defense-in-depth backstop. Repro: PR #596 admin-direct-merged ungated,
  # reddened main on a decompose-epic.test.sh assertion, cost PR #597 + a
  # ~9-minute red-main window to fix forward. Removing the step-0.5 clause
  # regresses the wait-before-ungated-merge contract.
  assert_contains "$auto_merge_path" "wait for the PR's own checks before merging instead of merging ungated" \
    "auto-merge.md prescribes waiting for the PR's own checks before the ungated admin-direct merge (issue #598)"
  assert_contains "$auto_merge_path" "ungated admin-direct path" \
    "auto-merge.md names the ungated admin-direct-merge path the wait guards (issue #598)"
  assert_contains "$auto_merge_path" "NO required status checks (so a direct merge fires before CI completes)" \
    "auto-merge.md names the three-part ungated-config detection: allow_auto_merge false + admin + no required checks (issue #598)"
  assert_contains "$auto_merge_path" "REQUIRED_CHECKS == 0" \
    "auto-merge.md keys the wait on a zero-required-checks reading (issue #598)"
  assert_contains "$auto_merge_path" "the merge gate the repo lacks must be re-created by the worker" \
    "auto-merge.md explains the wait re-creates the merge gate the repo's ruleset lacks (issue #598)"
  assert_contains "$auto_merge_path" "defense-in-depth backstop" \
    "auto-merge.md keeps merged-direct-ungated as the defense-in-depth backstop for residual cases (issue #598)"

  # Issue #602 — the step-0.5 pre-merge wait must fire on BOTH ungated shapes,
  # not just the #438 shape. PR #600 shipped the #598 wait keyed only on
  # `ALLOW_AUTO_MERGE == false` (the #438 shape), so on `mattsears18/shipyard`
  # (admin + zero required checks + allow_auto_merge=TRUE — the #465 shape) the
  # gate was skipped and every issue-work PR still admin-direct-merged ungated
  # (PRs #600/#601 both landed merged-direct-ungated with checks pending). #602
  # extends §0.5's detection to mirror setup.md §1.3's two-shape logic: fire when
  # admin AND (allow_auto_merge==false OR zero required checks) — i.e. the #465
  # shape fires REGARDLESS of allow_auto_merge. The skip is preserved only when
  # required checks ARE configured OR a real auto-merge queue forms. Removing the
  # two-shape extension regresses the dogfood repo back to ungated merges.
  assert_contains "$auto_merge_path" "There are **two distinct shapes** that put the PR on the ungated admin-direct path" \
    "auto-merge.md §0.5 detects both ungated shapes (#438 and #465), not just the #438 shape (issue #602)"
  assert_contains "$auto_merge_path" "Shape 2 (#465), which fires *regardless of \`ALLOW_AUTO_MERGE\`*:" \
    "auto-merge.md §0.5 fires the wait on the #465 shape (admin + zero required checks) regardless of allow_auto_merge (issue #602)"
  # shellcheck disable=SC2016
  # Single-quoted on purpose: this needle is the LITERAL shell text of the
  # two-shape OR fire-condition in auto-merge.md — `$ALLOW_AUTO_MERGE`/`$REQUIRED_CHECKS`
  # must NOT expand; we are asserting the doc contains that exact source line.
  assert_contains "$auto_merge_path" '[ "$ALLOW_AUTO_MERGE" = "false" ] || [ "$REQUIRED_CHECKS" = "0" ]' \
    "auto-merge.md §0.5 fire-condition is the two-shape OR mirroring setup.md §1.3 (issue #602)"
  assert_contains "$auto_merge_path" "Do NOT skip on \`ALLOW_AUTO_MERGE == true\` alone" \
    "auto-merge.md §0.5 skip is preserved only when required checks configured OR queue forms, not on allow_auto_merge==true alone (issue #602)"

  # Issue #707 — "terminal state is LOCAL gates + PR-opened + auto-merge-armed;
  # never gate the commit / push / PR-open on a CI result" rule in the
  # Return-contract discipline section. The rule exists because a worker on a
  # CI-congested host finished its full implementation, verified it locally,
  # spawned a background CI-watch, and then STALLED with the work uncommitted
  # on disk — treating "wait for CI to confirm" as a precondition for committing
  # (returning "I'll wait for the background waiter … before proceeding to
  # commit"), so nothing ever committed. This is DISTINCT from #529 (which
  # forbids using a backgrounded process as the wait mechanism); #707 forbids
  # treating CI confirmation as a commit precondition AT ALL. Removing the rule
  # (or the one-shot-snapshot-not-a-wait strengthening in auto-merge.md step 2)
  # regresses the never-gate-the-commit-on-CI contract.
  assert_contains "$skill_path" "never gate the commit / push / PR-open on a CI result" \
    "SKILL.md forbids gating the commit/push/PR-open on a CI result (issue #707)"
  assert_contains "$skill_path" "([#707](https://github.com/mattsears18/shipyard/issues/707))" \
    "SKILL.md's terminal-state rule cites issue #707"
  assert_contains "$skill_path" "CI confirmation is the **orchestrator's** job" \
    "SKILL.md names CI confirmation as the orchestrator's job, not the worker's (issue #707)"
  assert_contains "$skill_path" "one-shot snapshot" \
    "SKILL.md names the post-PR check-rollup read a one-shot snapshot, never a wait (issue #707)"
  assert_contains "$skill_path" "run it fire-and-forget or skip it — never *wait* on it" \
    "SKILL.md strengthens the do-not-watch guidance to do-not-wait fire-and-forget-or-skip (issue #707)"
  assert_contains "$auto_merge_path" "one-shot read for the return string, never a wait" \
    "auto-merge.md step 2 frames the check-rollup snapshot as a one-shot read, never a wait (issue #707)"
  assert_contains "$auto_merge_path" "[#707](https://github.com/mattsears18/shipyard/issues/707)" \
    "auto-merge.md step 2 cites issue #707 for the never-wait-on-CI rule"
fi

# (1b) Each per-mode spec's return section must reference the #529
# synchronous-return clause so a worker reading only its own per-mode file
# still sees the prohibition.
for mode_file in issue-work fix-checks-only fix-rebase fix-main-ci fix-failing-prs-batch; do
  mode_path="$repo_root/plugins/shipyard/agents/issue-worker/${mode_file}.md"
  assert_file_exists "$mode_path" "per-mode spec ${mode_file}.md exists"
  if [[ -f "$mode_path" ]]; then
    assert_contains "$mode_path" "#529" \
      "${mode_file}.md return section references the #529 synchronous-return clause"
  fi
done

# (1c) issue-work.md — the mode with the #707 repro — must reference the
# never-gate-commit-on-CI rule in both its §7 snapshot step and its §8 return
# section, so a worker reading only the issue-work file still sees the
# prohibition (and the strengthened do-not-watch → do-not-wait guidance).
issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
if [[ -f "$issue_work_path" ]]; then
  assert_contains "$issue_work_path" "do not *wait* on a background CI-watch either ([#707]" \
    "issue-work.md §7 strengthens do-not-watch to do-not-wait, citing #707"
  assert_contains "$issue_work_path" "CI confirmation is NOT a precondition for returning ([#707]" \
    "issue-work.md §8 return section states CI confirmation is not a precondition for returning (issue #707)"
fi

# (2) The five dispatch prompts (in commands/do-work/steady-state.md after
# the issue #154 split) must reference the skill. We count by the canonical
# reference string the dispatch prompts use to invoke the skill.
assert_file_exists "$do_work_path" "commands/do-work.md exists"
assert_file_exists "$steady_state_hot_path" "commands/do-work/steady-state.md exists"

if [[ -f "$steady_state_path" ]]; then
  # The five dispatch prompts should reference the skill — expect ≥5 references.
  assert_count_at_least "$steady_state_path" "shipyard:worker-preamble" 5 \
    "steady-state.md references the worker-preamble skill in ≥5 places (one per dispatch prompt)"

  # Regression guard: the verbatim "never \`cd\` outside it, never use \`gh pr
  # checkout\`" sentence must not be duplicated inside dispatch prompts
  # anymore. The orchestrator's own worktree-discipline preamble lives in
  # commands/do-work/setup.md step 0.5 (a single inline copy); the Don't
  # rule lives in commands/do-work/dont.md (another). Five+ inline copies
  # in any one file would mean the refactor regressed.
  assert_count_at_most "$steady_state_path" \
    "never \`cd\` outside it, never use \`gh pr checkout\`" 2 \
    "steady-state.md dispatch prompts no longer inline the full worktree-discipline sentence"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
