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
do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"
# The dispatch prompts now live in commands/do-work/steady-state.md after
# the issue #154 split. The worker-preamble references the test counts
# against the dispatch prompts, so steady-state.md is the file under test
# for assertion (2) below.
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"

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
  assert_contains "$skill_path" "## Dependency-bootstrap check for Node-based target repos" \
    "SKILL.md covers the Node-deps bootstrap check (issue #316)"
  assert_contains "$skill_path" "package.json" \
    "SKILL.md names package.json as the Node-repo detector for the bootstrap check"
  assert_contains "$skill_path" "node_modules" \
    "SKILL.md names node_modules as the missing-dir signal for the bootstrap check"
  assert_contains "$skill_path" "ln -s ../../../node_modules node_modules" \
    "SKILL.md provides the symlink-from-primary-checkout remediation recipe"
  assert_contains "$skill_path" "npm ci" \
    "SKILL.md provides the npm ci fallback remediation"
  assert_contains "$skill_path" "cannot bootstrap node_modules" \
    "SKILL.md names the blocked: bail string for the fail-both-paths case"

  # Issue #322 — Bash-tool isolation gotcha in the worktree-reaped escape hatch.
  # The pre-#322 snippet documented a "save once, reuse" pattern that tripped
  # the very guard it was meant to enforce when run through the Bash tool:
  # each tool call spawns a fresh shell, so $WORKTREE_PATH set in one call
  # was empty in the next, the `! -d ""` check was true, and the worker
  # emitted a false-positive `reaped:` exit on its first commit. The fix
  # makes the re-derive-at-top-of-every-call pattern explicit. Removing the
  # Bash-tool-isolation callout or the re-derive recipe regresses the
  # first-commit-false-positive contract.
  assert_contains "$skill_path" "Bash-tool isolation" \
    "SKILL.md calls out Bash-tool isolation as the gotcha (issue #322)"
  assert_contains "$skill_path" "Re-derive \`WORKTREE_PATH\`" \
    "SKILL.md prescribes re-deriving WORKTREE_PATH at the top of every write-class call (issue #322)"
  assert_contains "$skill_path" "do not survive" \
    "SKILL.md explains that variables do not survive across Bash tool calls (issue #322)"
  assert_contains "$skill_path" "false-positive \`reaped:\` exit" \
    "SKILL.md names the false-positive reaped: exit failure mode (issue #322)"

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
  assert_contains "$skill_path" "Auto Mode constraint" \
    "SKILL.md names the Auto Mode constraint on the symlink path (issue #328)"
  assert_contains "$skill_path" "auto-mode classifier" \
    "SKILL.md names the auto-mode classifier as the denier (issue #328)"
  assert_contains "$skill_path" "skip the symlink entirely and go directly to \`npm ci\`" \
    "SKILL.md tells Auto Mode workers to skip the symlink and go straight to npm ci (issue #328)"
  assert_contains "$skill_path" "cp -al" \
    "SKILL.md documents cp -al hard-link copy as an alternative to the symlink (issue #328)"

  # Issue #458 — Next 16 / Turbopack constraint on the node_modules link
  # strategies. Next.js 16's Turbopack refuses a node_modules that resolves
  # outside the worktree's filesystem root, so the ../../../node_modules symlink
  # (and the cp -al hard-link copy, whose real inodes still live under the
  # primary checkout) fail with "Symlink ... points out of the filesystem root".
  # Workers on a Turbopack repo waste one tool-call turn rediscovering this
  # unless the preamble tells them to detect Turbopack/Next 16 and skip directly
  # to npm ci. The fix adds the detection snippet + constraint at the symlink
  # remediation spot. Removing these docs regresses the Turbopack-skip contract.
  assert_contains "$skill_path" "Next 16 / Turbopack constraint" \
    "SKILL.md names the Next 16 / Turbopack constraint on the link strategies (issue #458)"
  assert_contains "$skill_path" "points out of the filesystem root" \
    "SKILL.md names the Turbopack 'points out of the filesystem root' failure (issue #458)"
  assert_contains "$skill_path" "uses_turbopack" \
    "SKILL.md provides the Turbopack/Next-16 detection snippet (issue #458)"

  # Issue #418 — "Mirror new string constants into locale / parity files"
  # section. The section exists because a worker that adds a user-facing string
  # to a centralized strings module (lib/strings.ts etc.) but forgets to mirror
  # the key into every locale file the repo's parity test requires (i18n.test.ts
  # etc.) reds CI on a key-parity assertion — a recurring, self-inflicted CI
  # break that costs a fix-checks cycle each time (lightwork repro: 3× in one
  # session across PRs #1443 / #1444 / #1447). Removing the section regresses the
  # mirror-the-key-before-push contract.
  assert_contains "$skill_path" "## Mirror new string constants into locale / parity files" \
    "SKILL.md covers the locale/parity mirror check (issue #418)"
  assert_contains "$skill_path" "parity test" \
    "SKILL.md names the parity test as the CI-red trigger (issue #418)"
  assert_contains "$skill_path" "mirror the new key into every file the test requires" \
    "SKILL.md prescribes mirroring the key into every required locale/parity file (issue #418)"

  # Issue #440 — "GitHub push-protection blocking a synthetic test-fixture
  # secret" section. The section exists because a worker adding a NEW test
  # fixture with a realistic-shaped secret (to exercise a scrubber / secret-scan
  # rule) gets its push bounced by GitHub's server-side push-protection — a
  # SEPARATE scanner from .gitleaks.toml, so the fixture being gitleaks-
  # allowlisted does not exempt it (the #402 / #408 scrubber-fixture workers hit
  # exactly this). Removing the section regresses the never-click-the-unblock-URL
  # + rewrite-to-synthetic + rebuild-the-commit contract.
  assert_contains "$skill_path" "## GitHub push-protection blocking a synthetic test-fixture secret" \
    "SKILL.md covers the push-protection synthetic-fixture block (issue #440)"
  assert_contains "$skill_path" "NEVER click the server-side unblock URL" \
    "SKILL.md tells the worker never to click the push-protection unblock URL (issue #440)"
  assert_contains "$skill_path" "obviously-synthetic value that still matches the pattern under test" \
    "SKILL.md prescribes rewriting the fixture to an obviously-synthetic value (issue #440)"
  assert_contains "$skill_path" "flagged blob never enters pushed history" \
    "SKILL.md prescribes rebuilding the commit so the flagged blob never enters pushed history (issue #440)"
  assert_contains "$skill_path" "NOT the same scanner as \`.gitleaks.toml\`" \
    "SKILL.md distinguishes push-protection from the .gitleaks.toml committed-content scanner (issue #440)"

  # Issue #459 — "Husky / core.hooksPath hooks silently skipped on a missing
  # exec bit" section. The section exists because a fresh `git worktree add`
  # checks out hook files with their committed mode and runs no npm `prepare`
  # lifecycle script, so a repo whose .husky/pre-commit was committed 100644
  # (or whose hooks are provisioned only via `husky install`) ends up with
  # inert hooks — git silently skips a non-executable hook (advisory hint to
  # stderr, exit 0), so lint-staged / prettier never run and no --no-verify
  # was passed (mattsears18.com session do-work-20260601T004608Z, #170 worker).
  # Removing the section regresses the detect-and-chmod-or-npm-ci contract.
  assert_contains "$skill_path" "## Husky / \`core.hooksPath\` hooks silently skipped on a missing exec bit" \
    "SKILL.md covers the non-executable-hook silent-skip (issue #459)"
  assert_contains "$skill_path" "silently ignores a hook that isn't marked executable" \
    "SKILL.md names the git silent-skip behavior for non-executable hooks (issue #459)"
  assert_contains "$skill_path" "chmod +x" \
    "SKILL.md prescribes chmod +x on the worktree hook files as remediation (issue #459)"
  assert_contains "$skill_path" "Never reach for \`--no-verify\` as a \"workaround.\"" \
    "SKILL.md forbids --no-verify as the fix for a silently-skipped hook (issue #459)"

  # Issue #475 — "Pin the default branch in git-using test fixtures" section.
  # The section exists because a worker authoring a *.test.sh fixture that
  # `git init`s a throwaway repo and later names the default branch (e.g.
  # `git checkout main`) passes its pre-push sweep on macOS (init.defaultBranch
  # = main) but reds on CI's Ubuntu runner (init.defaultBranch = master) with
  # `pathspec 'main' did not match`. On a merged-direct-ungated repo there is no
  # PR gate to catch it, so main goes red (repro: #466 fixture → recovery #473).
  # Removing the section regresses the pin-the-branch authoring rule and the
  # GIT_CONFIG_GLOBAL=master verification recipe.
  assert_contains "$skill_path" "## Pin the default branch in git-using test fixtures" \
    "SKILL.md covers the git-fixture default-branch pin (issue #475)"
  assert_contains "$skill_path" "init.defaultBranch" \
    "SKILL.md names init.defaultBranch as the invisible host dependency (issue #475)"
  assert_contains "$skill_path" "git init -q -b main" \
    "SKILL.md prescribes pinning the fixture's initial branch with git init -b (issue #475)"
  assert_contains "$skill_path" "GIT_CONFIG_GLOBAL" \
    "SKILL.md provides the GIT_CONFIG_GLOBAL=master verification recipe (issue #475)"
  assert_contains "$skill_path" "did not match" \
    "SKILL.md names the pathspec-did-not-match CI failure (issue #475)"

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

# (2) The five dispatch prompts (in commands/do-work/steady-state.md after
# the issue #154 split) must reference the skill. We count by the canonical
# reference string the dispatch prompts use to invoke the skill.
assert_file_exists "$do_work_path" "commands/do-work.md exists"
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"

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
