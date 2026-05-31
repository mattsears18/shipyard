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
fi

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
