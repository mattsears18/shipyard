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
# Issue #1045 — the "Adding a NEW dependency" rule moved out of node-bootstrap.md
# into a standalone, non-worker-preamble skill (reachable outside worker
# dispatch, broadened past package-manager manifests). It lives at
# plugins/shipyard/skills/adding-dependencies/SKILL.md, a sibling of
# worker-preamble, not a fragment inside wp_dir.
adding_dependencies_path="$repo_root/plugins/shipyard/skills/adding-dependencies/SKILL.md"
ci_pitfalls_path="$wp_dir/ci-pitfalls.md"
commit_hygiene_path="$wp_dir/commit-hygiene.md"
# Issue #808 (Finding 2) — three more rarely-hit sections moved out of
# SKILL.md into on-demand fragments: classifier-denial.md, native-background-
# subagent.md, and gh-json-discipline.md (the latter owns only the field-
# scoping cookbook — the one-sentence rule itself stays in SKILL.md).
classifier_denial_path="$wp_dir/classifier-denial.md"
native_background_subagent_path="$wp_dir/native-background-subagent.md"
gh_json_discipline_path="$wp_dir/gh-json-discipline.md"
# Issue #895 — a new fragment documenting the Edit/Write bg-isolation write
# guard (a probe distinct from the step-0 cwd fail-fast).
write_probe_path="$wp_dir/write-probe.md"
# Issue #981 — Auto Mode's compound-command classifier can refuse the #829
# re-block loop itself in a worktree-isolated session; the reproduced
# refusal shapes and the Monitor-based fallback live in this fragment,
# pointed at from SKILL.md's #829 section rather than inlined there (keeps
# the always-loaded core under the #617 line-budget).
# Issue #1012 — the follow-on tail to #980/#1011: SKILL.md itself got the
# same thin-core + on-demand-fragments treatment #1011 applied to
# issue-work.md. Four new fragments; the #829 section moved into the
# existing ci-pitfalls.md fragment rather than a fifth new file (fixing a
# dangling fix-checks-only.md cross-reference that already assumed it lived
# there).
git_stash_prohibition_path="$wp_dir/git-stash-prohibition.md"
process_kill_detail_path="$wp_dir/process-kill-detail.md"
assert_worktree_cwd_fallback_path="$wp_dir/assert-worktree-cwd-fallback.md"
stop_background_processes_path="$wp_dir/stop-background-processes.md"
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

# Extended-regex sibling of assert_count_at_most, needed where a fixed-string
# needle would also match the fix's own explanatory prose (issue #979's
# regression guard quotes the refused shape inline as documentation — a
# plain -F substring match can't tell "here's the shape that's refused" prose
# apart from an actual, still-refused runnable heredoc).
assert_count_at_most_regex() {
  local file="$1"
  local pattern="$2"
  local max="$3"
  local label="$4"
  local count
  count=$(grep -cE -- "$pattern" "$file" 2>/dev/null | head -n 1)
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
  assert_file_exists "$classifier_denial_path" "worker-preamble fragment classifier-denial.md exists (issue #808)"
  assert_file_exists "$native_background_subagent_path" "worker-preamble fragment native-background-subagent.md exists (issue #808)"
  assert_file_exists "$gh_json_discipline_path" "worker-preamble fragment gh-json-discipline.md exists (issue #808)"
assert_file_exists "$write_probe_path" "worker-preamble fragment write-probe.md exists (issue #895)"
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
  assert_contains "$skill_path" "(./classifier-denial.md)" \
    "SKILL.md fragment-index links classifier-denial.md (issue #808)"
  assert_contains "$skill_path" "(./native-background-subagent.md)" \
    "SKILL.md fragment-index links native-background-subagent.md (issue #808)"
  assert_contains "$skill_path" "(./gh-json-discipline.md)" \
    "SKILL.md fragment-index links gh-json-discipline.md (issue #808)"
assert_contains "$skill_path" "(./write-probe.md)" \
    "SKILL.md fragment-index links write-probe.md (issue #895)"
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

  # Issue #895 — the step-0 cwd fail-fast section must point at the new
  # write-probe fragment, and the fragment itself must carry the blocked:
  # return string and both observed harness error signatures, or a worker
  # loses the fast-fail path and burns a full dispatch discovering the
  # write-block at its final commit.
  assert_contains "$skill_path" "does NOT confirm \`Edit\`/\`Write\` will actually succeed" \
    "SKILL.md's step-0 section warns a passing cwd check doesn't guarantee Edit/Write works (issue #895)"
  assert_contains "$write_probe_path" "## Write-capability probe" \
    "write-probe.md covers the Write-capability probe section (issue #895)"
  assert_contains "$write_probe_path" "parent bg session hasn't isolated yet" \
    "write-probe.md names the parent-not-isolated harness error signature (issue #895)"
  assert_contains "$write_probe_path" "This session is now isolated in" \
    "write-probe.md names the parent-isolated redirect-to-orchestrator-worktree harness error signature (issue #895)"
  assert_contains "$write_probe_path" "blocked: workflow-substrate dispatch cannot write files" \
    "write-probe.md names the blocked: return string for a confirmed write-block (issue #895)"

  # Issue #158 — `gh` JSON discipline convention section. The one-sentence
  # rule stays in SKILL.md (issue #808 split); the field-scoping cookbook
  # (which subcommands take --json <fields>, the common-projections table)
  # moved to gh-json-discipline.md. Removing either half regresses the
  # per-call token-cost contract.
  assert_contains "$skill_path" "## \`gh\` JSON discipline" \
    "SKILL.md covers the gh JSON discipline convention (issue #158)"
  assert_contains "$skill_path" "--jq" \
    "SKILL.md names the --jq projection flag"
  assert_contains "$gh_json_discipline_path" "--json <fields>" \
    "gh-json-discipline.md names the --json <fields> pattern (issue #808)"

  # Issue #808 (Finding 2) — "After a classifier denial" and "Native
  # background-subagent auto-PR reconciliation" moved out of SKILL.md
  # entirely (heading and all), matching the full-move pattern already used
  # by reaped-escape-hatch.md. Assert each fragment owns its section heading
  # and a load-bearing content marker, so a future edit can't silently drop
  # the section during a merge/rebase.
  assert_contains "$classifier_denial_path" "## After a classifier denial" \
    "classifier-denial.md covers the After a classifier denial section (issue #808)"
  assert_contains "$classifier_denial_path" "blocked: classifier denied" \
    "classifier-denial.md names the blocked: classifier denied return string (issue #808)"
  assert_contains "$native_background_subagent_path" "## Native background-subagent auto-PR reconciliation" \
    "native-background-subagent.md covers the Native background-subagent section (issue #808)"
  assert_contains "$native_background_subagent_path" "auto-commits, pushes its own branch, and opens a draft pull request" \
    "native-background-subagent.md names the harness-native auto-PR behavior (issue #808)"

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

  # Issue #694 / #1045 — introduce a NEW dependency at the latest stable
  # version, with the peer/SDK carve-out. A worker that adds a package pinned
  # to a training-data-remembered stale version starts the dep behind and it
  # only drifts further (the observed multi-major debt + shipped native crash
  # on lightwork, and the #1045 recurrence — 30 more major-version Dependabot
  # PRs after #694 landed, including manifest classes the original rule never
  # covered). As of #1045 this rule lives in the standalone
  # `shipyard:adding-dependencies` skill, not node-bootstrap.md — assert
  # against that file instead. The skill must establish latest-stable-by-
  # default, the unconditional peer/SDK carve-out (framework-required version
  # instead), the expo install preference for Expo repos, recording the
  # version in the PR body, and introduction-only scope. Removing any of
  # these regresses the introduction-time-version-debt contract.
  assert_contains "$adding_dependencies_path" "# Adding a NEW dependency — research the current version first" \
    "adding-dependencies/SKILL.md covers introducing a new dependency at latest stable (issue #694 / #1045)"
  assert_contains "$adding_dependencies_path" "npm install <pkg>@latest" \
    "adding-dependencies/SKILL.md names the latest-stable installer for a new dep (issue #694)"
  assert_contains "$adding_dependencies_path" "Record the resolved version in the PR body" \
    "adding-dependencies/SKILL.md requires recording the resolved version in the PR body (issue #694)"
  assert_contains "$adding_dependencies_path" "load-bearing carve-out" \
    "adding-dependencies/SKILL.md names the peer/SDK load-bearing carve-out (issue #694)"
  assert_contains "$adding_dependencies_path" "npx expo install <pkg>" \
    "adding-dependencies/SKILL.md prefers expo install for Expo repos (issue #694)"
  assert_contains "$adding_dependencies_path" "new_dep_version" \
    "adding-dependencies/SKILL.md references the dependencies.new_dep_version config knob (issue #694)"
  assert_contains "$adding_dependencies_path" "introduction only" \
    "adding-dependencies/SKILL.md scopes the rule to dependency introduction, not upgrades (issue #694)"
  assert_contains "$node_bootstrap_path" "shipyard:adding-dependencies" \
    "node-bootstrap.md keeps a short hot-path pointer to the relocated skill (issue #1045)"

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

  # Issue #829 — "A foreground call the harness auto-backgrounds past 600s"
  # section. The section exists because the Bash tool's own 600s foreground
  # cap silently moves an overrunning command to the background and hands
  # control back — putting a worker that was correctly blocking on a long
  # test run into the exact state the #529 rule forbids, through no choice of
  # its own. Without this section a worker reads its own situation as a #529
  # breach and improvises a non-compliant workaround (a narrative return, a
  # bare sleep-then-tail retry, or reaching for Monitor because the harness's
  # own guard text suggests it). The section must: (1) name the state as
  # sanctioned rather than a violation, (2) prescribe the re-block
  # until-loop pattern verbatim, (3) name the three anti-patterns explicitly,
  # and (4) note the optional pre-split caveat without treating runtime
  # estimation as reliable. Removing any of the four regresses the
  # sanctioned-re-block contract #829 exists to close.
  #
  # Issue #1012 moved the full section (heading and all) out of SKILL.md and
  # into the existing ci-pitfalls.md fragment — the same full-move pattern
  # #808 already used for classifier-denial.md / native-background-subagent.md
  # — fixing a dangling cross-reference from fix-checks-only.md that already
  # assumed the content lived in ci-pitfalls.md. SKILL.md keeps a short
  # trigger-and-pointer stub (heading + the sanctioned-not-a-breach framing);
  # the load-bearing detail below now lives in the fragment.
  assert_contains "$skill_path" \
    "## A foreground call the harness auto-backgrounds past 600s" \
    "SKILL.md covers the harness-auto-backgrounded-600s-call section heading (issue #829)"
  assert_contains "$skill_path" "sanctioned harness behavior, not a #529 breach" \
    "SKILL.md names the auto-backgrounded state as sanctioned, not a #529 breach (issue #829)"
  assert_contains "$skill_path" "ci-pitfalls.md" \
    "SKILL.md's #829 stub points at ci-pitfalls.md (issue #1012)"
  assert_contains "$ci_pitfalls_path" \
    "## A foreground call the harness auto-backgrounds past 600s" \
    "ci-pitfalls.md covers the harness-auto-backgrounded-600s-call section (issue #1012)"
  # shellcheck disable=SC2016
  # Literal grep needle — the re-block pattern is matched verbatim, not expanded.
  assert_contains "$ci_pitfalls_path" \
    'until [ -s "<output-file>" ]; do sleep 15; done; cat "<output-file>"' \
    "ci-pitfalls.md prescribes the verbatim re-block until-loop pattern (issue #829)"
  assert_contains "$ci_pitfalls_path" 'Do NOT return a narrative status ("tests are still running, I' \
    "ci-pitfalls.md's anti-pattern list forbids a narrative status return (issue #829)"
  assert_contains "$ci_pitfalls_path" "Do NOT re-run the command from scratch" \
    "ci-pitfalls.md's anti-pattern list forbids re-running the command from scratch (issue #829)"
  # shellcheck disable=SC2016
  # Literal grep needle — the backtick-quoted `Monitor` is matched verbatim, not expanded.
  assert_contains "$ci_pitfalls_path" 'Do NOT reach for `Monitor` merely because the harness' \
    "ci-pitfalls.md's anti-pattern list forbids reaching for Monitor merely because the harness guard suggests it (issue #829)"
  assert_contains "$ci_pitfalls_path" "host contention" \
    "ci-pitfalls.md names host contention as the reason runtime is unpredictable (issue #829)"
  assert_contains "$ci_pitfalls_path" "worker-side" \
    "ci-pitfalls.md frames the #829 section as the worker-side half of the #829/#838 pair"

  # Issue #981 — the #829 re-block loop (the `until [ -s ... ]` pattern above)
  # is itself a compound shell command, and Auto Mode's compound-command
  # classifier can refuse it in a worktree-isolated session even though it's
  # read-only — reproduced in three shapes against a live GitHub Actions
  # polling loop in mattsears18/lightwork#3199. ci-pitfalls.md (formerly
  # fragment (kept out of the always-loaded core to preserve the #617 line
  # budget); the fragment itself must (1) name the refusal explicitly so a
  # future worker doesn't spend turns rediscovering it, and (2) prescribe the
  # actually-working fallback: arm a `Monitor` with the identical polling
  # command, while still never ending the turn on its notification,
  # preserving #529/#813/#753. Removing either half regresses the #981 fix:
  # dropping (1) reintroduces the token-burning rediscovery the issue
  # reported; dropping (2) leaves a worker with no working escape hatch once
  # the classifier refuses the primary pattern.
  # shellcheck disable=SC2016
  # Literal grep needle — the command-substitution shape is matched verbatim, not expanded.
  # shellcheck disable=SC2016
  # Literal grep needle — the command-substitution condition is matched verbatim, not expanded.

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

  # Issue #845 — "Never `git stash`" section. `git stash` is repo-global
  # (refs/stash lives in the shared .git-common-dir, not per-worktree), so
  # concurrent workers in separate worktrees can pop each other's stashed
  # changes. Repro: session do-work-20260723T124144Z-66736 on
  # mattsears18/lightwork — the worker on issue #2887 popped a stash entry
  # that turned out to contain a DIFFERENT, still-running worker's (issue
  # #2878) in-progress test file; it was only caught because that worker
  # happened to diff the post-stash state. This is worse than the
  # worktree-reap hazard in #838/#841: no completion notification to
  # inspect, no leftover directory to recover from. The section must:
  # (1) forbid git stash by default and name the refs/stash mechanism,
  # (2) require the isolating push -m + apply-by-matched-ref shape and
  # forbid a bare pop, (3) give dirty-worktree guidance at step 0. Removing
  # any of the three regresses the cross-worker stash-collision contract.
  # Issue #1012 split this section: the core prohibition + dirty-worktree
  # guidance stay in SKILL.md (fires on every dispatch's step 0); the
  # mechanism explanation and the one safe unavoidable-stash procedure moved
  # to git-stash-prohibition.md (fires only if a worker is actually about to
  # stash — rare, since the core rule alone is the correct default).
  assert_contains "$skill_path" \
    "## Never \`git stash\` — \`refs/stash\` is repo-global, not per-worktree" \
    "SKILL.md covers the Never git stash section (issue #845)"
  assert_contains "$skill_path" "([#845](https://github.com/mattsears18/shipyard/issues/845))" \
    "SKILL.md's git-stash section cites issue #845"
  assert_contains "$skill_path" "Forbidden by default" \
    "SKILL.md states git stash is forbidden by default for workers (issue #845)"
  assert_contains "$skill_path" "refs/stash" \
    "SKILL.md names refs/stash as the shared-storage mechanism (issue #845)"
  assert_contains "$skill_path" "git-stash-prohibition.md" \
    "SKILL.md's git-stash section points at git-stash-prohibition.md (issue #1012)"
  assert_contains "$skill_path" "Dirty-worktree guidance at step 0" \
    "SKILL.md gives dirty-worktree guidance at step 0 (issue #845)"
  assert_contains "$skill_path" "may belong to a live peer" \
    "SKILL.md warns pre-existing worktree changes may belong to a live peer (issue #845)"
  assert_contains "$skill_path" "never a blanket \`git stash\`, \`git clean -fd\`, or \`git restore .\`" \
    "SKILL.md forbids blanket stash/clean/restore of unexpected worktree state (issue #845)"
  assert_contains "$skill_path" "the \`git stash\` prohibition" \
    "SKILL.md's thin-core summary names the git-stash prohibition as an always-loaded rule (issue #845)"

  assert_contains "$git_stash_prohibition_path" "git-common-dir" \
    "git-stash-prohibition.md ties the git-stash rationale to the shared git-common-dir (issue #845)"
  assert_contains "$git_stash_prohibition_path" "one shared LIFO stack visible to and mutable by" \
    "git-stash-prohibition.md explains the stash stack is shared across every concurrent worker (issue #845)"
  # shellcheck disable=SC2016
  # Literal grep needle — the shell snippet is matched verbatim, not expanded.
  assert_contains "$git_stash_prohibition_path" 'git stash push -u -m "<agent-id-or-issue-N>: <reason>"' \
    "git-stash-prohibition.md prescribes the isolating git stash push -u -m form (issue #1224)"
  assert_contains "$git_stash_prohibition_path" "A bare \`git stash pop\` always takes \`stash@{0}\`" \
    "git-stash-prohibition.md forbids bare git stash pop and names the stash@{0} mechanism (issue #845)"
  assert_contains "$git_stash_prohibition_path" "apply by SHA, not pop" \
    "git-stash-prohibition.md prescribes apply-then-drop by matched SHA, not pop (issue #1224)"
  assert_contains "$git_stash_prohibition_path" "\`apply\`-then-\`drop\` by matched SHA/tag is the only safe shape" \
    "git-stash-prohibition.md states apply-then-drop by matched SHA/tag is the only safe shape (issue #1224)"
  assert_contains "$skill_path" "there is always a substitute" \
    "SKILL.md pairs the git-stash prohibition with a concrete substitute (issue #1224)"
  assert_contains "$skill_path" 'git commit -m "wip: <why>"' \
    "SKILL.md leads with the WIP-commit substitute for shelving changes (issue #1224)"
  assert_contains "$git_stash_prohibition_path" "WIP commit" \
    "git-stash-prohibition.md's substitute section leads with a WIP commit (issue #1224)"

  # Issue #1506 — the third recorded instance of a worker reaching for a bare
  # stash, after two documentation-only fixes (#1345 made the prohibition
  # explicit, #1224 supplied the substitute). That worker named the correct
  # substitute unprompted in its own return and still reached for stash, so
  # the failure is a reflex outrunning a recalled rule, not missing
  # knowledge — a fourth documentation edit was not expected to work. The
  # prohibition is now backed by hooks/refuse-unsafe-git-stash.sh (registered
  # under the Bash matcher; hooks-json.test.sh guards the registration, and
  # refuse-unsafe-git-stash.test.sh guards the decision rules). Both specs
  # must (1) say the rule is mechanically enforced and name the hook, and
  # (2) state that the sanctioned tagged form is deliberately still
  # reachable — a guard that also blocked `git stash push -u -m "<tag>"`
  # would break the documented escape hatch, which is worse than the status
  # quo. git-stash-prohibition.md additionally records WHY this is a hook and
  # not a permissions.deny pattern, so a future editor doesn't "simplify" it
  # back into a pattern that cannot express the carve-out.
  assert_contains "$skill_path" "Mechanically enforced, not merely documented" \
    "SKILL.md states the git-stash prohibition is mechanically enforced (issue #1506)"
  assert_contains "$skill_path" "refuse-unsafe-git-stash.sh" \
    "SKILL.md names the enforcing hook (issue #1506)"
  assert_contains "$skill_path" 'git stash push -u -m "<tag>"` procedure stays reachable' \
    "SKILL.md states the sanctioned tagged form stays reachable (issue #1506)"
  assert_contains "$skill_path" "no negation operator" \
    "SKILL.md explains why a deny pattern cannot express the carve-out (issue #1506)"
  assert_contains "$git_stash_prohibition_path" \
    "## Mechanical enforcement — the \`refuse-unsafe-git-stash.sh\` hook" \
    "git-stash-prohibition.md carries the mechanical-enforcement section (issue #1506)"
  assert_contains "$git_stash_prohibition_path" \
    "([#1506](https://github.com/mattsears18/shipyard/issues/1506))" \
    "git-stash-prohibition.md's enforcement section cites issue #1506"
  assert_contains "$git_stash_prohibition_path" "Still permitted, in full" \
    "git-stash-prohibition.md states the sanctioned procedure is still permitted (issue #1506)"
  assert_contains "$git_stash_prohibition_path" "The Bash rule matcher has no negation" \
    "git-stash-prohibition.md records why a deny pattern cannot express the carve-out (issue #1506)"
  assert_contains "$git_stash_prohibition_path" "command-rewriting \`PreToolUse\` hook" \
    "git-stash-prohibition.md records the command-rewrite laundering hazard (issue #1506)"
  assert_contains "$git_stash_prohibition_path" "What it deliberately does not cover" \
    "git-stash-prohibition.md documents the hook's gaps rather than overclaiming (issue #1506)"

  # Issue #1511 — the "Never `--no-verify`" section used to close by asserting
  # that the plugin manifest's `permissions.deny` block enforced the rule at
  # the harness level. `permissions` is not among the documented `plugin.json`
  # fields and the documented permission rule sources name no plugin-manifest
  # tier, so the section was describing an unverified mechanism as a live one
  # — the same "documented but unenforced" shape #1506 fixed for `git stash`.
  # The prohibition is now backed by hooks/refuse-hook-bypass-flag.sh
  # (registered under the Bash matcher; hooks-json.test.sh guards the
  # registration, refuse-hook-bypass-flag.test.sh guards the decision rules).
  # The section must (1) name the hook as the enforcement, (2) mark the
  # manifest block's status as UNVERIFIED rather than asserting either that it
  # works or that it is inert — the binary-reading evidence is strong but an
  # interactive `/permissions` check is still owed, and #1511 deliberately
  # stops short of calling it conclusive — and (3) say `git push -n` stays
  # allowed, so nobody infers the hook refuses `--dry-run` on the strength of
  # `-n` being `--no-verify` on commit.
  assert_contains "$skill_path" "refuse-hook-bypass-flag.sh" \
    "SKILL.md names the hook that enforces the --no-verify prohibition (issue #1511)"
  assert_contains "$skill_path" "**The hook is the enforcement.**" \
    "SKILL.md names the hook, not the manifest block, as the enforcement (issue #1511)"
  assert_contains "$skill_path" "that claim is **unverified**" \
    "SKILL.md marks the permissions.deny block's status as unverified, not inert (issue #1511)"
  assert_contains "$skill_path" "no plugin-manifest tier" \
    "SKILL.md records why the manifest block cannot be relied on (issue #1511)"
  assert_contains "$skill_path" "which is \`--dry-run\`, not \`--no-verify\`" \
    "SKILL.md states git push -n stays reachable (issue #1511)"
  assert_count_at_most "$skill_path" \
    "enforces this at the harness level" 0 \
    "SKILL.md no longer asserts harness-level manifest enforcement (issue #1511)"

  # Issue #751 — "Never run a broad process kill" split the same way: the
  # core prohibition + PID-tracking rule + hook-enforcement note stay in
  # SKILL.md; the reproduced repro narrative and the cheap CI-executor
  # host-detection check moved to process-kill-detail.md.
  assert_contains "$skill_path" \
    "## Never run a broad process kill" \
    "SKILL.md covers the broad-process-kill prohibition (issue #751)"
  assert_contains "$skill_path" "Track the PID of any process you spawn yourself" \
    "SKILL.md prescribes tracking your own spawned PIDs (issue #751)"
  assert_contains "$skill_path" "process-kill-detail.md" \
    "SKILL.md's process-kill section points at process-kill-detail.md (issue #1012)"
  assert_contains "$process_kill_detail_path" \
    "a worker ran \`pkill -9 -f \"playwright test\"\` during local cleanup" \
    "process-kill-detail.md carries the reproduced repro (issue #751)"
  assert_contains "$process_kill_detail_path" \
    "actions-runner" \
    "process-kill-detail.md carries the CI-executor host-detection check (issue #751)"

  # Issue #1012 — the pre-#826 fallback for the step-0 / mid-session cwd
  # checks (when scripts/assert-worktree-cwd.sh can't be located or run)
  # was duplicated across both SKILL.md sections; consolidated into one
  # fragment referenced from both.
  assert_count_at_least "$skill_path" "assert-worktree-cwd-fallback.md" 2 \
    "SKILL.md points at assert-worktree-cwd-fallback.md from both the step-0 and mid-session sections (issue #1012)"
  assert_contains "$assert_worktree_cwd_fallback_path" \
    'git rev-parse --git-common-dir' \
    "assert-worktree-cwd-fallback.md carries the step-0 fallback form"
  # shellcheck disable=SC2016
  # Literal grep needle — $WORKTREE_PATH is matched verbatim, not expanded.
  assert_contains "$assert_worktree_cwd_fallback_path" \
    'git -C "$WORKTREE_PATH" rev-parse --git-common-dir' \
    "assert-worktree-cwd-fallback.md carries the mid-session -C-anchored fallback form"

  # Issue #297/#1012 — "Stop background processes before returning" full
  # mechanism table moved to stop-background-processes.md; SKILL.md keeps a
  # short stub naming the same load-bearing markers the pre-existing #297
  # assertions above already check against skill_path (TaskStop, KillShell,
  # run_in_background, Monitor all still present in the stub), plus a
  # pointer to the fragment for the full per-tool-family table.
  assert_contains "$skill_path" "stop-background-processes.md" \
    "SKILL.md's background-process cleanup stub points at stop-background-processes.md (issue #1012)"
  assert_contains "$stop_background_processes_path" \
    "| \`Monitor\` sub-task (any subscription) | \`TaskStop\`" \
    "stop-background-processes.md carries the per-tool-family stop mechanism table"
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

# (1d) Issue #812 — a `gh pr merge --auto` failure caused by a missing
# `workflow` OAuth scope must be detected and named distinctly from the
# generic `unavailable — needs manual merge` bucket, at every layer: the
# worker-preamble fragment that detects it, the issue-work per-mode spec
# that documents the return string, the JSON schema that validates the
# structured return, and the .js workflow script's inline copy of that
# schema (schema-drift parity between the two is covered separately by
# dispatch-substrate-cutover-790.test.sh; this suite only asserts each file
# individually knows about the new value).
if [[ -f "$auto_merge_path" ]]; then
  assert_contains "$auto_merge_path" 'without .workflow. scope' \
    "auto-merge.md step 1.1 matches the GraphQL 'without \`workflow\` scope' error signature (issue #812)"
  assert_contains "$auto_merge_path" "auto-merge: unavailable — gh token lacks workflow scope" \
    "auto-merge.md names the distinct workflow-scope-blocked suffix (issue #812)"
  assert_contains "$auto_merge_path" "deterministic, session-wide precondition" \
    "auto-merge.md explains why the workflow-scope cause is session-wide, not per-PR (issue #812)"
fi

if [[ -f "$issue_work_path" ]]; then
  assert_contains "$issue_work_path" "auto-merge: unavailable — gh token lacks workflow scope" \
    "issue-work.md §8 documents the distinct workflow-scope-blocked return string (issue #812)"
  assert_contains "$issue_work_path" "gh auth refresh -h github.com -s workflow" \
    "issue-work.md names the exact one-time remediation command (issue #812)"
fi

worker_schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
workflow_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
assert_contains "$worker_schema_path" "unavailable-workflow-scope" \
  "worker-return.schema.json's auto_merge enum carries unavailable-workflow-scope (issue #812)"
assert_contains "$workflow_js_path" "unavailable-workflow-scope" \
  "do-work-dispatch.workflow.js's inline auto_merge enum carries unavailable-workflow-scope (issue #812)"

# (1e) Orchestrator-side session-level hoist: a distinct list in orchestrator
# state, a reconcile-time append, and a once-per-session (not once-per-PR)
# end-of-session banner — the whole point of #812's suggested fix #2.
do_work_state_path="$repo_root/plugins/shipyard/commands/do-work.md"
cleanup_summary_path="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
assert_contains "$do_work_state_path" "workflow_scope_blocked_prs" \
  "do-work.md orchestrator-state documents workflow_scope_blocked_prs (issue #812)"
if [[ -f "$steady_state_hot_path" ]]; then
  assert_contains "$steady_state_hot_path" "workflow_scope_blocked_prs" \
    "steady-state.md's A.1 shipped-handler appends to workflow_scope_blocked_prs (issue #812)"
fi
assert_contains "$cleanup_summary_path" "workflow_scope_blocked_prs" \
  "cleanup-summary.md's end-of-session summary reads workflow_scope_blocked_prs (issue #812)"
assert_contains "$cleanup_summary_path" "gh auth refresh -h github.com -s workflow" \
  "cleanup-summary.md's banner names the one-time remediation command (issue #812)"
assert_contains "$cleanup_summary_path" "omit entirely when \`workflow_scope_blocked_prs\` is empty" \
  "cleanup-summary.md's banner is silent by default — only prints when the list is non-empty (issue #812)"

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

# Issue #979 — issue-work.md §5 prescribed a `gh pr create --body "$(cat
# <<'EOF' ... EOF)"` shape that the worktree-isolation Bash guard refuses as
# "too complex to verify that it stays inside the worktree" — the spec's own
# documented command was unrunnable by the workers it's written for.
# Reproduced twice against real dispatches (mattsears18/lightwork #3200 and
# #3333) and a third time live during this fix's own authoring. The fix:
# a new body-file-convention.md fragment documents a sanctioned
# `--body-file` + worktree-root-dotdir scratch-location convention (kept
# out of the always-loaded core to preserve the #617 300-line budget),
# SKILL.md's core carries a short pointer at it, and every per-mode spec
# that previously inlined a heredoc `--body` now points at it instead.
#
# The scratch location is a worktree-root dotdir (`$WORKTREE_PATH/.shipyard-
# scratch/`), NOT `$(git rev-parse --git-dir)` — an earlier draft of this fix
# used the per-worktree git directory, on the theory that it's categorically
# outside the working tree git tracks. That theory doesn't survive contact
# with the `Write` tool: `enforce-edit-scope.sh` checks the target path
# against the worktree ROOT (`.claude/worktrees/agent-<id>/`), and the
# per-worktree git-dir lives OUTSIDE that root (under the primary checkout's
# `.git/worktrees/<name>/`) — so a `Write` call there is rejected by that
# hook, confirmed by testing it directly during this fix's own authoring.
# The corrected design uses a dotdir INSIDE the worktree root (the same
# precedent write-probe.md's `.shipyard-write-probe` already relies on) and
# an explicit `rm -rf` cleanup step, since (unlike the git-dir) this
# location DOES show up in `git status --porcelain` until removed.
#
# Regression guard below: (a) SKILL.md points at the fragment, (b) the
# fragment carries the corrected convention, and (c) no per-mode spec still
# contains the refused heredoc-in-command-substitution shape.
body_file_convention_path="$wp_dir/body-file-convention.md"
assert_file_exists "$body_file_convention_path" "worker-preamble fragment body-file-convention.md exists (issue #979)"
assert_contains "$skill_path" \
  "refused by the worktree-isolation \`Bash\` guard" \
  "SKILL.md's PR-creation contract names the heredoc --body refusal (issue #979)"
# Expect ≥2 references: the PR-creation-contract pointer plus the
# fragment-index table row.
assert_count_at_least "$skill_path" "(./body-file-convention.md)" 2 \
  "SKILL.md references body-file-convention.md from both the PR-creation contract and the fragment index (issue #979)"
# shellcheck disable=SC2016
# Literal grep needle — the scratch path is matched verbatim, not expanded.
assert_contains "$body_file_convention_path" \
  '$WORKTREE_PATH/.shipyard-scratch' \
  "body-file-convention.md names the worktree-root dotdir scratch location (issue #979)"
assert_contains "$body_file_convention_path" \
  "enforce-edit-scope.sh" \
  "body-file-convention.md explains why /tmp is rejected by the sibling edit-scope hook (issue #979)"
assert_contains "$body_file_convention_path" \
  "rejected by that hook" \
  "body-file-convention.md documents that the per-worktree git-dir is ALSO rejected by Write's edit-scope hook (issue #979)"
# Issue #1347 superseded the original #979 "prescribes explicit cleanup"
# expectation — see the #1347 regression guard below, which asserts the
# opposite (no mode runs `rm -rf` anymore).

# Issue #1058 — .shipyard-scratch/ promoted from a --body-file-payload-only
# convention to the single sanctioned general-purpose worker scratch dir
# (helper scripts, loop input files, redirect targets, command output), made
# git-invisible via a self-ignoring .gitignore seed step (so the mandated
# `rm -rf` cleanup — permission-denied on some hosts per issue #1061 — is
# downgraded to best-effort/non-blocking rather than load-bearing), and
# enforce-edit-scope.sh's BLOCK message updated to redirect a worker reaching
# for /tmp at the sanctioned destination instead of a dead end. Regression
# guard below: (a) SKILL.md carries the scratch-dir convention as a hot rule
# (not buried in an on-demand-only fragment), (b) body-file-convention.md
# documents the general-purpose scope, the .gitignore self-ignoring seed step,
# carries the #1058 decomposition guidance, and (d) enforce-edit-scope.sh's
# BLOCK message names .shipyard-scratch/ — kept consistent with the docs
# above rather than drifting into a second, undocumented convention.
assert_contains "$skill_path" \
  "Scratch directory" \
  "SKILL.md's always-loaded core carries the scratch-directory convention as a hot rule (issue #1058)"
assert_contains "$skill_path" \
  "self-ignoring" \
  "SKILL.md's scratch-directory hot rule mentions the self-ignoring .gitignore seed (issue #1058)"
assert_contains "$body_file_convention_path" \
  "general-purpose" \
  "body-file-convention.md documents .shipyard-scratch/ as the general-purpose scratch dir, not body-file-payload-only (issue #1058)"
# shellcheck disable=SC2016
# Literal grep needle — the seed-file path is matched verbatim, not expanded.
assert_contains "$body_file_convention_path" \
  '$WORKTREE_PATH/.shipyard-scratch/.gitignore' \
  "body-file-convention.md prescribes seeding .shipyard-scratch/.gitignore as the first artifact (issue #1058)"
assert_contains "$body_file_convention_path" \
  "best-effort" \
  "body-file-convention.md's historical note names the #1058 best-effort/non-blocking downgrade it superseded (issue #1058)"

# Issue #1347 — the #1058 best-effort `rm -rf` downgrade above still had
# every mode ATTEMPT the removal, and that attempt was itself getting denied
# by the permission classifier on a majority of real dispatches (two workers
# in one `mattsears18/lightwork` session both hit it), costing each denied
# worker a wasted turn explaining why the harmless leftover was fine. The
# fix: stop attempting the removal entirely rather than make it succeed more
# often — the self-ignoring `.gitignore` seed from #1058 already guarantees
# a clean `git status` on its own, so the `rm -rf` was pure redundancy.
# Regression guard below: (a) body-file-convention.md documents "no cleanup"
# as authoritative and states a leftover scratch dir is never a `blocked:`
# reason, and (b) no per-mode spec or shared fragment still instructs
# `rm -rf "$WORKTREE_PATH/.shipyard-scratch"` as a literal command to run.
assert_contains "$body_file_convention_path" \
  "Cleanup — none needed" \
  "body-file-convention.md's Cleanup section documents that no removal is attempted (issue #1347)"
assert_contains "$body_file_convention_path" \
  "Do not run \`rm -rf" \
  "body-file-convention.md explicitly instructs against running rm -rf (issue #1347)"
assert_contains "$body_file_convention_path" \
  "as a reason to return \`blocked:\`" \
  "body-file-convention.md states a leftover scratch dir is never a blocked: reason (issue #1347)"

# shellcheck disable=SC2016
# Literal grep needle — asserting the discouraged $PWD shape is named, not expanded.

enforce_edit_scope_hook_path="$repo_root/plugins/shipyard/hooks/enforce-edit-scope.sh"
if [[ -f "$enforce_edit_scope_hook_path" ]]; then
  assert_contains "$enforce_edit_scope_hook_path" \
    ".shipyard-scratch/" \
    "enforce-edit-scope.sh's BLOCK message names .shipyard-scratch/ as the sanctioned scratch destination (issue #1058)"
  # The /tmp block itself must not be relaxed — the hook still has no carve-out
  # for /tmp or any other out-of-worktree path; only the message changed.
  assert_contains "$enforce_edit_scope_hook_path" \
    "OUTSIDE your isolated worktree" \
    "enforce-edit-scope.sh's out-of-worktree BLOCK is unchanged — no /tmp carve-out was added (issue #1058)"
fi

for mode_file in issue-work fix-main-ci fix-failing-prs-batch investigate spike; do
  mode_path="$repo_root/plugins/shipyard/agents/issue-worker/${mode_file}.md"
  if [[ -f "$mode_path" ]]; then
    assert_contains "$mode_path" "#979" \
      "${mode_file}.md references issue #979's --body-file fix"
    assert_contains "$mode_path" "--body-file" \
      "${mode_file}.md prescribes --body-file instead of a heredoc"
    # shellcheck disable=SC2016
    # Literal grep needle — the scratch path is matched verbatim, not expanded.
    assert_contains "$mode_path" '$WORKTREE_PATH/.shipyard-scratch' \
      "${mode_file}.md uses the worktree-root dotdir scratch location"
    # Issue #1347 — a literal `rm -rf "$WORKTREE_PATH/.shipyard-scratch"`
    # cleanup call was itself getting denied by the permission classifier on
    # a majority of dispatches; the fix was to stop instructing it at all
    # rather than make the denial less frequent. Regression guard: no mode
    # file reintroduces the literal removal command.
    # shellcheck disable=SC2016
    # Literal grep needle — asserting the dropped cleanup call is ABSENT.
    assert_count_at_most "$mode_path" "rm -rf \"\$WORKTREE_PATH/.shipyard-scratch\"" 0 \
      "${mode_file}.md no longer instructs an rm -rf cleanup of the scratch dir (issue #1347)"
    # Regression guard: the corrected design abandoned the per-worktree
    # git-dir location (Write's enforce-edit-scope.sh hook rejects it) — a
    # mode file that reintroduced it would be silently unrunnable again.
    # shellcheck disable=SC2016
    # Literal grep needle — asserting the rejected shape is ABSENT, not expanded.
    assert_count_at_most "$mode_path" '$(git rev-parse --git-dir)/shipyard-scratch' 0 \
      "${mode_file}.md does not use the rejected per-worktree git-dir scratch location"
    # A real (still-refused) heredoc opener ends its line right after the
    # <<EOF / <<'EOF' delimiter (bash requires the delimiter be the last
    # token on the line); this fix's own explanatory prose quotes the same
    # substring but always trails it with more text ("... EOF)"` is
    # refused"), so anchoring on end-of-line distinguishes the two.
    assert_count_at_most_regex "$mode_path" \
      '"\$\(cat <<.?EOF.?$' 0 \
      "${mode_file}.md no longer contains the refused heredoc --body shape"
  fi
done

assert_contains "$reaped_path" "#979" \
  "reaped-escape-hatch.md's incremental-posting example references issue #979"
assert_contains "$reaped_path" "--body-file" \
  "reaped-escape-hatch.md's incremental-posting example uses --body-file"
# shellcheck disable=SC2016
# Literal grep needle — the scratch path is matched verbatim, not expanded.
assert_contains "$reaped_path" '$WORKTREE_PATH/.shipyard-scratch' \
  "reaped-escape-hatch.md's incremental-posting example uses the worktree-root dotdir scratch location"
# shellcheck disable=SC2016
# Literal grep needle — asserting the dropped cleanup call is ABSENT (#1347).
assert_count_at_most "$reaped_path" "rm -rf \"\$WORKTREE_PATH/.shipyard-scratch\"" 0 \
  "reaped-escape-hatch.md's incremental-posting example no longer instructs an rm -rf cleanup (issue #1347)"

# Issue #1004 — the same heredoc-in-command-substitution shape #979 fixed
# across the mode-shim worker files also existed in three standalone,
# human-invoked slash commands (not worker dispatches, but not guaranteed to
# run outside a worktree-isolated cwd either — e.g. /my-turn reuses
# resolve-decisions.md's flow inline in the same session as an active
# /shipyard:do-work run). Converted to the same --body-file + scratch-file
# pattern; guard against regression the same way the mode-file loop above does.
for cmd_file in file-issue resolve-decisions eas-watch; do
  cmd_path="$repo_root/plugins/shipyard/commands/${cmd_file}.md"
  if [[ -f "$cmd_path" ]]; then
    assert_contains "$cmd_path" "#1004" \
      "${cmd_file}.md references issue #1004's --body-file fix"
    assert_contains "$cmd_path" "--body-file" \
      "${cmd_file}.md prescribes --body-file instead of a heredoc"
    assert_contains "$cmd_path" ".shipyard-scratch" \
      "${cmd_file}.md uses a .shipyard-scratch scratch location"
    assert_contains "$cmd_path" "rm -rf" \
      "${cmd_file}.md cleans up the scratch dir after use"
    # Same real-heredoc-opener regression guard as the mode-file loop above.
    assert_count_at_most_regex "$cmd_path" \
      '"\$\(cat <<.?EOF.?$' 0 \
      "${cmd_file}.md no longer contains the refused heredoc --body shape"
  fi
done

# Issue #1088 — never disable a committed security/supply-chain control to
# make a red check pass, and never arm auto-merge on a PR that did anyway.
# The prohibition lives in the always-loaded SKILL.md core (reaches all seven
# modes); the pre-arm backstop lives in the shared auto-merge.md fragment;
# issue-work.md carries the implementation-time self-check (§4.45), the
# step-6 pointer, the step-8 return line, and a "Don't" bullet.
issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"

assert_contains "$skill_path" "## Never disable a committed security or supply-chain control" \
  "SKILL.md carries the #1088 prohibition as an always-loaded core section"
assert_contains "$skill_path" "min-release-age" \
  "SKILL.md's #1088 prohibition names the .npmrc min-release-age instance from the repro"
assert_contains "$skill_path" "must NOT arm auto-merge" \
  "SKILL.md's #1088 prohibition states the no-arm backstop"

assert_contains "$auto_merge_path" "0.3." \
  "auto-merge.md carries the #1088 pre-arm policy-override check as step 0.3"
assert_contains "$auto_merge_path" "unarmed-policy-override" \
  "auto-merge.md's pre-arm check names the structured auto_merge value"
assert_contains "$auto_merge_path" "needs-human-review" \
  "auto-merge.md's pre-arm check labels the PR needs-human-review"

assert_contains "$issue_work_path" "### 4.45 Never disable a committed security or supply-chain control" \
  "issue-work.md carries the §4.45 implementation-time self-check"
assert_contains "$issue_work_path" "blocked #<N> at implement:" \
  "issue-work.md's §4.45 documents the blocked-return shape"
assert_contains "$issue_work_path" "run the policy-override check" \
  "issue-work.md step 6 points at the auto-merge.md pre-arm check before either trust branch"
assert_contains "$issue_work_path" "auto-merge: unarmed — policy-override: <control>" \
  "issue-work.md step 8 documents the policy-override return line"
assert_contains "$issue_work_path" "Don't disable a committed security/supply-chain control" \
  "issue-work.md's Don't section warns against the #1088 failure mode"

assert_contains "$schema_path" "unarmed-policy-override" \
  "worker-return.schema.json's auto_merge enum carries unarmed-policy-override"
assert_contains "$schema_path" '"policy_override"' \
  "worker-return.schema.json declares the policy_override field"

# Issue #1113 — a worker whose verification run gets auto-backgrounded by the
# harness must poll it to a terminal result and return one of its mode's
# documented strings, never end its turn on a non-terminal narrative
# ("waiting on the suite", "I'll resume once it reports back"). The rule
# lives in the always-loaded SKILL.md core, sited next to the #1054
# commit-before-yield invariant (same family: "don't yield in a state the
# orchestrator can't act on"). issue-work.md carries the companion P2
# verification-scope guidance — prefer targeted suites plus at most one full
# sweep, rather than defaulting to the whole battery for a small change.
assert_contains "$skill_path" \
  "Auto-backgrounded verification must be awaited to a terminal result" \
  "SKILL.md carries the #1113 auto-backgrounded-verification rule as an always-loaded core bullet"
assert_contains "$skill_path" "#1113" \
  "SKILL.md's #1113 bullet cites the originating issue"
assert_contains "$skill_path" "never narrated past" \
  "SKILL.md's #1113 bullet states the never-narrate-past rule"
assert_contains "$skill_path" "only an explicit orchestrator \`SendMessage\` restarts it" \
  "SKILL.md's #1113 bullet states the worker does not resume automatically"

assert_contains "$issue_work_path" \
  "Prefer targeted suites over the full discovered set once the suite count is large enough to risk the foreground time budget" \
  "issue-work.md §4 carries the #1113 P2 verification-scope guidance"
assert_contains "$issue_work_path" "**at most one** full sweep" \
  "issue-work.md's #1113 guidance caps a full sweep at one, on top of the targeted minimum"

# Issue #1111 — workers routinely ended their turn waiting on a background
# job THEY THEMSELVES launched (a Monitor-tracked commit, a background
# verification wait), returning narrative prose instead of a terminal
# string. Observed five times in one session across issue-work and
# fix-checks-only, including the SAME worker doing it twice in a row on the
# same PR — once, then again immediately after an A.0.5 resume that had
# already told it to stop waiting on the specific thing it was resumed for.
# That finding is the residual gap #1054/#1113 didn't close: the resume
# message stopped the worker re-subscribing to ITS OLD wait but said nothing
# about arming a NEW one for a later step. Fix: strengthen the canned
# resume-message template (steady-state.md, shared across all seven modes'
# A.0.5 resume path) to forbid backgrounding anything for the rest of the
# dispatch, and reinforce fix-checks-only.md's `pending` return as a
# success-shaped terminal, not something to keep watching after you've
# earned it.
fix_checks_only_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"

assert_contains "$steady_state_hot_path" \
  "This applies for the REST of this" \
  "steady-state.md's canned resume template forbids backgrounding anything for the rest of the dispatch (#1111)"
assert_contains "$steady_state_hot_path" "#1111" \
  "steady-state.md's resume-template strengthening cites the originating issue"
assert_contains "$steady_state_hot_path" \
  "re-backgrounding a different operation and stalling a second time on" \
  "steady-state.md documents the #1111 same-worker-twice-in-a-row finding"

assert_contains "$fix_checks_only_path" \
  "\`pending\` is a success-shaped outcome, not a partial or lesser one" \
  "fix-checks-only.md frames pending as a success-shaped terminal (#1111)"
assert_contains "$fix_checks_only_path" "#1111" \
  "fix-checks-only.md's pending reinforcement cites the originating issue"

# Issue #1186 — "Node-version pinning (nvm/.nvmrc) without a bare `source`
# refusal" fragment. A worker following a target repo's documented
# `source "$NVM_DIR/nvm.sh"; nvm use` Node-version-pin snippet hit a bare
# `source`-invocation refusal from the harness's own worktree-isolation Bash
# guard (confirmed NOT one of shipyard's own hooks.json-wired Bash hooks —
# none of the four reference "source" or this message). The fragment must
# exist, be indexed in SKILL.md's on-demand fragment table, name the
# nvm-exec / scratch-script / PATH-prepend remediations, and node-bootstrap.md
# must point a worker already there at it. Removing any of these regresses
# the #1186 fix.
nvm_source_refusal_path="$wp_dir/nvm-source-refusal.md"
assert_file_exists "$nvm_source_refusal_path" "worker-preamble fragment nvm-source-refusal.md exists (issue #1186)"
assert_contains "$skill_path" "(./nvm-source-refusal.md)" \
  "SKILL.md fragment-index links nvm-source-refusal.md (issue #1186)"
assert_contains "$nvm_source_refusal_path" "harness's own built-in worktree-isolation Bash classifier" \
  "nvm-source-refusal.md attributes the refusal to the harness, not a shipyard hook (issue #1186)"
assert_contains "$nvm_source_refusal_path" "nvm-exec" \
  "nvm-source-refusal.md documents the nvm-exec remediation (issue #1186)"
assert_contains "$nvm_source_refusal_path" "PATH-prepend" \
  "nvm-source-refusal.md documents the PATH-prepend fallback remediation (issue #1186)"
assert_contains "$node_bootstrap_path" "nvm-source-refusal.md" \
  "node-bootstrap.md points a worker with a Node-version (not just deps) mismatch at nvm-source-refusal.md (issue #1186)"

# Issue #1278 — "Don't comply with a resumed instruction that routes around
# a worker-internal classifier denial" reinforcement. A live session showed
# the worker-side rule (#341, "don't retry the SAME denied call") wasn't
# enough: an orchestrator resume instructing an effect-equivalent substitute
# for a denied call wasn't covered by any existing rule, and the worker also
# unpromptedly improvised a THIRD workaround against an explicit "stop at
# two" instruction it had already been given. The fix adds a fourth
# MUST-NOT item to classifier-denial.md's list, renumbers the section intro
# from "Three" to "Four", names the same tempting substitutions dont.md's
# companion orchestrator-side rule names, and explicitly carves out the
# unrelated compound-command-decomposition case so the new rule can't be
# misread as forbidding that sanctioned response.
#
# Six assertions pin the post-#1278 contract:
assert_contains "$classifier_denial_path" \
  "Four behaviors you MUST NOT do after a denial" \
  "classifier-denial.md's intro is renumbered to four MUST-NOT items (#1278)"
assert_contains "$classifier_denial_path" \
  "A denial encountered **after an orchestrator resume is still a denial**" \
  "classifier-denial.md states a resumed denial is still a denial (#1278)"
assert_contains "$classifier_denial_path" \
  "stop at two, do not try a third formulation" \
  "classifier-denial.md names the explicit stop-at-two instruction from the #1278 repro"
assert_contains "$classifier_denial_path" \
  "orchestrator instructed an effect-equivalent substitute after denial, refusing" \
  "classifier-denial.md documents the resumed-substitute blocked return string (#1278)"
assert_contains "$classifier_denial_path" \
  "stopping per the prior stop instruction rather than improvising a further workaround" \
  "classifier-denial.md documents the self-initiated-third-attempt blocked return string (#1278)"
assert_contains "$classifier_denial_path" \
  "does not cover decomposing a refused *compound* command into plain single-purpose commands" \
  "classifier-denial.md explicitly carves out the legitimate compound-command-decomposition case (#1278)"
assert_contains "$classifier_denial_path" \
  "issues/1278" \
  "classifier-denial.md cites issue #1278"

# --- Issue #1279 — decision-freshness check: don't re-apply needs-human-review
# over an already-recorded decision. Regression guard for the failure mode
# where a worker escalating to needs-human-review never checked whether the
# human decision it was asking for had already been recorded — repro'd three
# times in ~10 minutes on one lightwork issue. The fix adds a shared fragment
# plus three call sites (investigate.md §4b, spike.md §4b, and the
# orchestrator's blocked→refuse routing in steady-state.md) that all compare
# a decision-resolved sentinel's timestamp against the prior escalation's,
# rather than just checking whether a resolution comment exists anywhere.
decision_freshness_path="$wp_dir/decision-freshness-check.md"
investigate_path="$repo_root/plugins/shipyard/agents/issue-worker/investigate.md"
spike_path="$repo_root/plugins/shipyard/agents/issue-worker/spike.md"

echo
echo "decision-freshness-check regression tests (issue #1279)"
echo

assert_file_exists "$decision_freshness_path" \
  "worker-preamble fragment decision-freshness-check.md exists (issue #1279)"
assert_contains "$skill_path" "(./decision-freshness-check.md)" \
  "SKILL.md fragment-index links decision-freshness-check.md (issue #1279)"

if [[ -f "$decision_freshness_path" ]]; then
  assert_contains "$decision_freshness_path" \
    "ordering check, not a keyword-match" \
    "decision-freshness-check.md frames the rule as ordering, not keyword-matching"
  assert_contains "$decision_freshness_path" \
    "shipyard-resolve-decisions" \
    "decision-freshness-check.md recognizes the shipyard-resolve-decisions sentinel"
  assert_contains "$decision_freshness_path" \
    "do-work-decision-resolved" \
    "decision-freshness-check.md recognizes the do-work-decision-resolved sentinel"
  assert_contains "$decision_freshness_path" \
    "Guard the other direction" \
    "decision-freshness-check.md documents the non-suppression direction (a stale decision must not block a new escalation)"

  # Issue #1557 — a PARTIAL /resolve-decisions run posts the SAME sentinel
  # but deliberately leaves the gate on. Matching it as a full resolution
  # would suppress a gate the maintainer explicitly chose to keep.
  assert_contains "$decision_freshness_path" \
    'contains("## Decisions resolved (partial")' \
    "decision-freshness-check.md excludes a partial resolve-decisions comment from latest_decision (#1557)"
  assert_contains "$decision_freshness_path" \
    "PARTIAL \`/resolve-decisions\` run is not a recorded decision" \
    "decision-freshness-check.md documents the partial-run carve-out (#1557)"
  # The orchestrator-side scope-preflight call site anchors on the `labeled`
  # timeline event; anchoring on `unlabeled` made the #962 guard inert.
  # shellcheck disable=SC2016
  # Backticks/asterisks are literal markdown punctuation in the needle.
  assert_contains "$decision_freshness_path" \
    'must be the **`labeled`** event, never `unlabeled`' \
    "decision-freshness-check.md records the scope-preflight labeled-not-unlabeled anchor (#1557)"
fi

# investigate.md §4b must run the freshness check BEFORE applying the label,
# and must document the new no-relabel return-string variant.
if [[ -f "$investigate_path" ]]; then
  assert_contains "$investigate_path" \
    "do-work-investigation-disposition" \
    "investigate.md's freshness check compares against its own escalation marker"
  assert_contains "$investigate_path" \
    "sorts after" \
    "investigate.md documents the ordering comparison in prose"
  assert_contains "$investigate_path" \
    "investigated+needs-human-review #<N> (decision already recorded, gate not re-applied)" \
    "investigate.md documents the decision-already-recorded return-string variant"
  # Ordering assertion: the freshness-check block must appear in the file
  # BEFORE the unconditional label-apply line, not after — a check added
  # after the label was already applied would be too late to matter.
  freshness_line=$(grep -n "latest_escalation=\$(printf" "$investigate_path" | head -n 1 | cut -d: -f1)
  apply_line=$(grep -n 'gh issue edit <N> --repo <owner/repo> --add-label needs-human-review' "$investigate_path" | head -n 1 | cut -d: -f1)
  if [[ -n "$freshness_line" && -n "$apply_line" && "$freshness_line" -lt "$apply_line" ]]; then
    printf '  %sPASS%s  investigate.md freshness check runs before the label-apply call\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  investigate.md freshness check runs before the label-apply call\n' "$RED" "$RESET"
    fail=$((fail+1))
  fi
fi

# spike.md §4b — structurally identical to investigate.md's §4b.
if [[ -f "$spike_path" ]]; then
  assert_contains "$spike_path" \
    "do-work-investigation-disposition" \
    "spike.md's freshness check compares against its own escalation marker"
  assert_contains "$spike_path" \
    "sorts after" \
    "spike.md documents the ordering comparison in prose"
  assert_contains "$spike_path" \
    "spiked+needs-human-review #<N> (decision already recorded, gate not re-applied)" \
    "spike.md documents the decision-already-recorded return-string variant"
  freshness_line=$(grep -n "latest_escalation=\$(printf" "$spike_path" | head -n 1 | cut -d: -f1)
  apply_line=$(grep -n 'gh issue edit <N> --repo <owner/repo> --add-label needs-human-review' "$spike_path" | head -n 1 | cut -d: -f1)
  if [[ -n "$freshness_line" && -n "$apply_line" && "$freshness_line" -lt "$apply_line" ]]; then
    printf '  %sPASS%s  spike.md freshness check runs before the label-apply call\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  spike.md freshness check runs before the label-apply call\n' "$RED" "$RESET"
    fail=$((fail+1))
  fi
fi

# steady-state.md's orchestrator-side blocked→refuse routing — the central
# choke point every mode's refuse-class bail funnels through. Must compare
# against its OWN escalation marker (do-work-agent-refuse), and must
# document both new investigate+/spiked+ return-string handling entries.
if [[ -f "$steady_state_hot_path" ]]; then
  assert_contains "$steady_state_hot_path" \
    "do-work-agent-refuse" \
    "steady-state.md's refuse branch still carries its provenance marker"
  assert_contains "$steady_state_hot_path" \
    "investigated+needs-human-review #<N> (decision already recorded, gate not re-applied)" \
    "steady-state.md documents investigate-mode's decision-already-recorded reconcile handling"
  assert_contains "$steady_state_hot_path" \
    "spiked+needs-human-review #<N> (decision already recorded, gate not re-applied)" \
    "steady-state.md documents spike-mode's decision-already-recorded reconcile handling"
fi

# The refuse-vs-soft classification (including the #1279 decision-freshness
# timestamp comparison) was extracted from steady-state.md to
# classify-blocked-bail.sh, issue #1289 — assert against the script now, not
# the removed inline prose.
classify_blocked_bail_path="$repo_root/plugins/shipyard/scripts/classify-blocked-bail.sh"
assert_file_exists "$classify_blocked_bail_path" "scripts/classify-blocked-bail.sh exists"
if [[ -f "$classify_blocked_bail_path" ]]; then
  assert_contains "$classify_blocked_bail_path" \
    "latest_decision" \
    "classify-blocked-bail.sh's refuse branch computes a latest_decision timestamp"
  assert_contains "$classify_blocked_bail_path" \
    "NOT re-applying" \
    "classify-blocked-bail.sh documents the not-re-applying comment body"
  # Guard against regressing to a keyword-match: the check must compare
  # TWO timestamps (latest_escalation vs latest_decision), not merely test
  # whether a decision comment exists at all.
  # shellcheck disable=SC2016  # literal needle — must NOT expand $latest_decision/$latest_escalation
  assert_contains "$classify_blocked_bail_path" \
    '[ "$latest_decision" \> "$latest_escalation" ]' \
    "classify-blocked-bail.sh's freshness check is a timestamp comparison, not a bare existence check"
fi

# Issue #1395 — a worker that ADDS a new executable script must record its
# git exec bit itself. The rule lives in the always-loaded SKILL.md core (an
# on-demand fragment would be inert: the failure mode is not knowing the rule
# exists), and node-bootstrap.md's OPPOSITE `chmod +x`-locally-only guidance
# for a PRE-EXISTING hook file (#459) carries the reciprocal discriminator so
# the two never read as contradictory.
assert_contains "$skill_path" \
  "## Adding a new executable script — record the git exec bit yourself" \
  "SKILL.md carries the #1395 exec-bit rule as an always-loaded core section"
assert_contains "$skill_path" "git update-index --chmod=+x <path>" \
  "SKILL.md's #1395 rule names the index-recording command, not a bare chmod"
assert_contains "$skill_path" "git ls-files -s <path>" \
  "SKILL.md's #1395 rule names the pre-push self-check that reads what CI reads"
assert_contains "$skill_path" "100755" \
  "SKILL.md's #1395 rule states the expected git mode"
assert_contains "$skill_path" "asserts against the **git index**, not the filesystem" \
  "SKILL.md's #1395 rule explains why a pre-staging local suite run passes honestly"
assert_contains "$skill_path" "complementary, not contradictory" \
  "SKILL.md's #1395 rule carries the discriminator against node-bootstrap.md's chmod guidance"
assert_contains "$node_bootstrap_path" \
  "it is NOT the rule for a script your own change is adding" \
  "node-bootstrap.md's #459 chmod guidance carries the reciprocal #1395 discriminator"
assert_contains "$node_bootstrap_path" \
  "Adding a new executable script — record the git exec bit yourself" \
  "node-bootstrap.md points at SKILL.md's #1395 section by name"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
