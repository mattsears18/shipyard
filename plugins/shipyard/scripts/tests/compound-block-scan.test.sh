#!/usr/bin/env bash
# Test: the post-relocation compound-block gate (issue #1277).
#
# Background — issue #1277: #1181 decomposed ONE post-relocation compound
# shape (the `CLAUDE_PLUGIN_ROOT` preamble) after the worktree-isolation
# guard refused it ("this command is too complex to verify that it stays
# inside the worktree"). Every OTHER post-relocation multi-statement block
# in the orchestrator spec was still templated the same refused way —
# scripts/compound-block-scan.sh is the cheap structural guard this issue's
# fix introduced: a scanner that flags a fenced ```bash block containing an
# unquoted shell pipe (spanning a tool boundary) or a for/while loop wrapping
# gh/git calls, mirroring the fence-balance-scan.sh / conflict-marker-scan.sh
# family.
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/compound-block-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/compound-block-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

echo "compound-block-scan gate regression tests (issue #1277)"
echo

# (1) The scanner exists.
assert_file_exists "$scanner" "scripts/compound-block-scan.sh exists"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) A block with only plain sequential statements — no loop, no pipe —
# passes clean, even with several lines and command substitutions.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
# Heading

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
ME_LOGIN=$(gh api user --jq '.login')
INVESTIGATE_DISPATCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```
FIXTURE
if bash "$scanner" "$clean_md" >/dev/null 2>&1; then
  ok "scanner exits 0 on a block of plain sequential statements"
else
  bad "scanner FALSE-POSITIVED on a block of plain sequential statements"
fi

# (3) A for-loop wrapping a gh call is flagged.
loop_md="$work/loop.md"
cat > "$loop_md" <<'FIXTURE'
```bash
for pr in $session_prs; do
  gh pr view "$pr" --repo <owner/repo>
done
```
FIXTURE
if bash "$scanner" "$loop_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a for-loop wrapping a gh call (exited 0)"
else
  out="$(bash "$scanner" "$loop_md" 2>&1)"
  if [[ "$out" == *"for/while-loop-wraps-gh-or-git"* ]]; then
    ok "scanner detects a for-loop wrapping a gh call"
  else
    bad "scanner exited non-zero but did not name the for/while-loop shape"
  fi
fi

# (4) A while-loop wrapping a git call is flagged.
while_md="$work/while.md"
cat > "$while_md" <<'FIXTURE'
```bash
while [ -n "$x" ]; do
  git branch -D "$x"
done
```
FIXTURE
if bash "$scanner" "$while_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a while-loop wrapping a git call (exited 0)"
else
  ok "scanner detects a while-loop wrapping a git call"
fi

# (5) A pipe spanning a shell command boundary (echo | jq) is flagged.
pipe_md="$work/pipe.md"
cat > "$pipe_md" <<'FIXTURE'
```bash
failing_pr_count_all=$(echo "$failing_pr_numbers" | jq 'length')
```
FIXTURE
if bash "$scanner" "$pipe_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect an echo | jq pipe (exited 0)"
else
  out="$(bash "$scanner" "$pipe_md" 2>&1)"
  if [[ "$out" == *"unquoted-pipe"* ]]; then
    ok "scanner detects an echo | jq pipe"
  else
    bad "scanner exited non-zero but did not name the unquoted-pipe shape"
  fi
fi

# (6) A pipe INSIDE a quoted --jq filter (jq's own `|` operator) is NOT
# flagged — this is the false-positive case the quote-stripping exists to
# avoid, and it is the single most common shape in the real corpus.
jqfilter_md="$work/jqfilter.md"
cat > "$jqfilter_md" <<'FIXTURE'
```bash
gh pr list --repo <owner/repo> --json number,statusCheckRollup \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE"))]
    | length > 0) | .number]'
```
FIXTURE
if bash "$scanner" "$jqfilter_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag a pipe inside a quoted --jq filter"
else
  bad "scanner FALSE-POSITIVED on a pipe inside a quoted --jq filter"
fi

# (7) A case statement's pattern-alternation `|` (word|word) form) is NOT
# flagged, including the single-line `case ... in pattern) action ;; esac`
# idiom this corpus uses for merge-method / retry-count validation.
case_md="$work/case.md"
cat > "$case_md" <<'FIXTURE'
```bash
case "$AUTO_MERGE_METHOD" in squash|merge|rebase) ;; *) AUTO_MERGE_METHOD=squash ;; esac
case "$PRUNE_WINDOW_DAYS" in ''|*[!0-9]*) PRUNE_WINDOW_DAYS=90 ;; esac
```
FIXTURE
if bash "$scanner" "$case_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag a case statement's pattern-alternation pipe"
else
  bad "scanner FALSE-POSITIVED on a case statement's pattern-alternation pipe"
fi

# (8) An apostrophe inside a `#` comment (a contraction like "it's") does
# NOT desync the quote-stripper and swallow real code on a later line —
# the false positive this scanner's own #1277 development hit and fixed.
comment_md="$work/comment.md"
cat > "$comment_md" <<'FIXTURE'
```bash
# The fix's merge commit — main's current HEAD, now that it's green.
fix_commit_sha=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.sha')
CLASSIFIED=$("${CLAUDE_PLUGIN_ROOT}/scripts/backlog-filter.sh" classify --me "$ME_LOGIN" < input.json > output.json)
```
FIXTURE
if bash "$scanner" "$comment_md" >/dev/null 2>&1; then
  ok "scanner does NOT desync on apostrophes inside a # comment"
else
  bad "scanner FALSE-POSITIVED after apostrophes inside a # comment (quote-stripper desync)"
fi

# (9) An explicit `<!-- compound-block-scan: allow -->` directive immediately
# before a fence exempts that one block, even though it contains a real
# for-loop-wraps-gh shape — for the rare case a block intentionally shows
# the refused shape as a documented bad example.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- compound-block-scan: allow -->
```bash
for pr in $session_prs; do
  gh pr view "$pr" --repo <owner/repo>
done
```
FIXTURE
if bash "$scanner" "$allow_md" >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  bad "an allow directive should have exempted the following block"
fi

# (10) A directory argument is walked... actually the scanner takes explicit
# file paths only (no directory-walk) — confirm a nonexistent path errors
# with usage exit code 2, not a silent pass.
if bash "$scanner" "$work/does-not-exist.md" >/dev/null 2>&1; then
  bad "scanner should error (not silently pass) on a nonexistent file"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    ok "scanner exits 2 on a nonexistent file argument"
  else
    bad "scanner exited $rc (expected 2) on a nonexistent file argument"
  fi
fi

# (11) Regression: the real repo's setup/04-backlog-divert.md — the file
# this issue's own fix swept clean — stays clean. A future edit that
# reintroduces a compound shape there fails this assertion.
real_target="$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
if [[ -f "$real_target" ]]; then
  if bash "$scanner" "$real_target" >/dev/null 2>&1; then
    ok "scanner reports setup/04-backlog-divert.md as clean of the known-refused compound shapes"
  else
    bad "scanner found a compound shape in setup/04-backlog-divert.md — see script output for the offending block"
  fi
fi

# (12) Regression: the built-in FILES list (no args) also reports clean,
# exercising the default (no-args) invocation path end-to-end.
if bash "$scanner" >/dev/null 2>&1; then
  ok "scanner's built-in FILES list (default invocation, no args) reports clean"
else
  bad "scanner's built-in FILES list (default invocation, no args) found a compound shape"
fi

# (13) Regression (issue #1289): dispatch-rules.md / drain.md /
# inline-trivial.md / steady-state.md — the four files #1289 swept 17 of
# their 18 flagged blocks from — stay clean. A future edit that
# reintroduces a compound shape in any of them fails this assertion.
# steady-state.md's one deliberately-deferred block (issue #1291) is exempt
# via its own `<!-- compound-block-scan: allow -->` marker, so this
# assertion still expects a clean exit for the file as a whole.
for f in dispatch-rules.md drain.md inline-trivial.md steady-state.md; do
  target="$repo_root/plugins/shipyard/commands/do-work/$f"
  if [[ -f "$target" ]]; then
    if bash "$scanner" "$target" >/dev/null 2>&1; then
      ok "scanner reports $f as clean of the known-refused compound shapes (#1289)"
    else
      bad "scanner found a compound shape in $f — see script output for the offending block"
    fi
  fi
done

# (14) Regression: the built-in FILES list now includes all six swept
# files (setup/04-backlog-divert.md + the four from #1289 + #1471's
# setup/00-config-worktree.md) — count-based proxy so a future accidental
# removal from FILES is caught even though the scanner's own output doesn't
# name which files it scanned.
# shellcheck disable=SC2016  # literal grep needle — matched verbatim in the script, not expanded
files_count=$(grep -cE '^\s*"\$repo_root/plugins/shipyard/commands/do-work/' "$scanner" 2>/dev/null || echo 0)
if [[ "$files_count" -ge 6 ]]; then
  ok "scanner's built-in FILES array lists at least 6 files (found $files_count)"
else
  bad "scanner's built-in FILES array lists fewer than 6 files (found $files_count) — #1289's or #1471's additions may have regressed"
fi

# (15) Regression: steady-state.md's formerly-deferred A.0.5 block (issue
# #1291) has been extracted to scripts/crash-recovery-reap.sh, and the
# `<!-- compound-block-scan: allow -->` marker that exempted it has been
# removed — steady-state.md is now clean on its own merits, the same as
# the other three #1289 files (test 13 already covers that). This
# assertion guards the OTHER direction: a future edit must not reintroduce
# the marker as a shortcut around a NEW compound shape rather than fixing
# it. If this ever legitimately needs re-exempting, update this assertion
# alongside the marker, not silently.
steady_state_real="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
crash_recovery_reap_real="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
if [[ -f "$steady_state_real" ]]; then
  if grep -qF -- '<!-- compound-block-scan: allow -->' "$steady_state_real"; then
    bad "steady-state.md still carries a compound-block-scan allow marker — #1291's extraction should have removed it entirely (no exemption should remain)"
  else
    ok "steady-state.md carries no compound-block-scan allow marker — #1291's A.0.5 extraction removed the exemption entirely"
  fi
  if grep -qF -- 'issues/1291' "$steady_state_real"; then
    ok "steady-state.md cites the #1291 extraction near its (now-extracted) A.0.5 block"
  else
    bad "steady-state.md does not cite issue #1291 near its A.0.5 block"
  fi
fi
if [[ -f "$crash_recovery_reap_real" ]]; then
  ok "scripts/crash-recovery-reap.sh exists — the #1291 extraction target for A.0.5's crash-recovery reap logic"
else
  bad "scripts/crash-recovery-reap.sh is missing — #1291's A.0.5 extraction target should exist"
fi

# (16) Issue #1471's new third shape: an UNQUOTED command substitution with
# a literal path suffix glued on is flagged. Measured refused in a live
# isolated worktree, with quoting as the only toggled variable.
unquoted_suffix_md="$work/unquoted-suffix.md"
cat > "$unquoted_suffix_md" <<'FIXTURE'
```bash
CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel)/plugins/shipyard
export CLAUDE_PLUGIN_ROOT
```
FIXTURE
if bash "$scanner" "$unquoted_suffix_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect an unquoted command substitution with a glued path suffix (exited 0)"
else
  out="$(bash "$scanner" "$unquoted_suffix_md" 2>&1)"
  if [[ "$out" == *"unquoted-substitution-path-suffix"* ]]; then
    ok "scanner detects an unquoted command substitution with a glued path suffix (#1471)"
  else
    bad "scanner exited non-zero but did not name the unquoted-substitution-path-suffix shape"
  fi
fi

# (17) The QUOTED spelling of the exact same line is NOT flagged — this is
# the measured-correct form and the one the fix writes into the specs. If
# this ever starts failing, the scanner is telling authors to rewrite a
# shape that demonstrably runs.
quoted_suffix_md="$work/quoted-suffix.md"
cat > "$quoted_suffix_md" <<'FIXTURE'
```bash
CLAUDE_PLUGIN_ROOT="$(git rev-parse --show-toplevel)/plugins/shipyard"
export CLAUDE_PLUGIN_ROOT
```
FIXTURE
if bash "$scanner" "$quoted_suffix_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag the quoted spelling of the same substitution (#1471)"
else
  bad "scanner FALSE-POSITIVED on the quoted (measured-correct) substitution spelling"
fi

# (18) Arithmetic expansion is NOT command substitution and must never be
# flagged by the new shape, even when a slash follows it — same carve-out
# command-substitution-scan.sh carries.
arith_md="$work/arith.md"
cat > "$arith_md" <<'FIXTURE'
```bash
kb=$(( (bytes + 1023) / 1024 ))
half=$((total / 2))
```
FIXTURE
if bash "$scanner" "$arith_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag arithmetic expansion containing a slash (#1471)"
else
  bad "scanner FALSE-POSITIVED on arithmetic expansion containing a slash"
fi

# (19) Regression (issue #1471): setup/00-config-worktree.md — newly added
# to the built-in FILES list — reports clean. Its two genuinely
# PRE-relocation blocks (step 0.4's opt-in check and step 0.5's raw
# `git worktree add` fallback, both run from the user's primary checkout
# before isolation exists) carry explicit allow markers; every other block
# in the file is post-relocation and must stay clean on its own merits.
#
# CONTENT READS BELOW SCAN ACROSS setup/*.md rather than pinning a fragment
# filename, per scripts/setup-fragment-content-scan.sh (#1453) — a future
# router/fragment split could relocate either block, and an assertion pinned
# to today's filename would break in CI with no local warning. Passing the
# file path to the SCANNER is not a content read and stays file-specific.
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"
config_worktree_real="$setup_dir/00-config-worktree.md"

extract_setup_bash_blocks() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; next }
    /^[[:space:]]*```[[:space:]]*$/     { inb = 0; next }
    inb { print }
  ' "$setup_dir"/*.md
}

if [[ -f "$config_worktree_real" ]]; then
  if bash "$scanner" "$config_worktree_real" >/dev/null 2>&1; then
    ok "scanner reports setup/00-config-worktree.md as clean (#1471)"
  else
    bad "scanner found a compound shape in setup/00-config-worktree.md — see script output for the offending block"
  fi
fi

# Exactly two allow markers across the whole setup/ fragment set — the two
# pre-relocation blocks #1471 exempted. A third would mean someone reached
# for an exemption as a shortcut around a real refused shape.
marker_count=$(grep -hcF -- '<!-- compound-block-scan: allow -->' "$setup_dir"/*.md 2>/dev/null | awk '{t += $1} END {print t + 0}')
if [[ "$marker_count" -eq 2 ]]; then
  ok "setup/*.md carries exactly 2 compound-block-scan allow markers — the two pre-relocation blocks (#1471)"
else
  bad "setup/*.md carries $marker_count compound-block-scan allow markers (expected 2) — a new exemption must not be added as a shortcut around a real refused shape"
fi

# (20) Regression (issue #1471): the two blocks the issue reported as
# refused on live main must no longer reference an unresolvable shell
# variable inside a fenced bash block, and the literal-substituted
# replacements must still be present.
#
# The negative needle is matched against fenced-block content only: both
# files legitimately DISCUSS these shapes in prose (04-backlog-divert.md
# explains why the literal replaced the variable), and a whole-file grep
# would fail on the documentation of the fix itself.

# No setup block may pass the gh login as a shell variable — this is the
# single argument whose substitution flipped the measured verdict.
# shellcheck disable=SC2016  # literal needle — matched verbatim in the spec, not expanded
if extract_setup_bash_blocks | grep -qF -- '--me "$ME_LOGIN"'; then
  bad "a setup/*.md fenced block still passes the gh login as a shell variable — the measured refusal trigger (#1471)"
else
  ok "no setup/*.md fenced block passes the gh login as a shell variable (#1471)"
fi

if grep -qlF -- 'bash <plugin-root literal>/scripts/classify-backlog.sh run' "$setup_dir"/*.md 2>/dev/null; then
  ok "setup/*.md carries the literal-substituted classify invocation (#1471)"
else
  bad "setup/*.md no longer carries the literal-substituted classify invocation — #1471's fix may have regressed"
fi

if grep -qlF -- '<resolved CLAUDE_PLUGIN_ROOT literal>/.claude-plugin/plugin.json' "$setup_dir"/*.md 2>/dev/null; then
  ok "setup/*.md reads the plugin version via the substituted literal (#1471)"
else
  bad "setup/*.md no longer reads the plugin version via a substituted literal — #1471's fix may have regressed"
fi

# The step-0.5 read-back specifically must not re-read the plugin root into
# a shell variable. This one assertion CANNOT scan across setup/*.md: the
# two-statement stash read is the correct, measured-to-run convention for
# every OTHER post-relocation block, and a corpus-wide scan would flag those
# legitimate uses. Pinned to the fragment that owns step 0.5, deliberately.
# setup-fragment-content-scan: allow
if [[ -f "$config_worktree_real" ]]; then
  # shellcheck disable=SC2016  # literal needle — matched verbatim in the spec, not expanded
  if awk '/^[[:space:]]*```bash[[:space:]]*$/ { inb = 1; next } /^[[:space:]]*```[[:space:]]*$/ { inb = 0; next } inb { print }' "$config_worktree_real" | grep -qF -- 'CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root'; then
    bad "setup/00-config-worktree.md still reads the plugin root back into a shell variable inside a fenced block — the refused step-0.5 shape (#1471)"
  else
    ok "setup/00-config-worktree.md substitutes the plugin-root literal in its fenced blocks (#1471)"
  fi
fi

# (#1561) An `update --set` value carrying a non-empty JSON object literal
# is refused post-relocation; the scanner flags it, single- or multi-line.
objlit_md="$work/objlit.md"
cat > "$objlit_md" <<'FIXTURE'
```bash
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update --session-id "<sid>" \
  --set '.in_flight = {"slot-1": {kind: "issue", target: "#4823"}}'
```
FIXTURE
if bash "$scanner" "$objlit_md" 2>/dev/null | grep -q 'object-literal-in-set'; then
  ok "scanner flags a single-line object literal in a --set value (#1561)"
else
  bad "scanner MISSED a single-line object literal in a --set value (#1561)"
fi

objlit_multi_md="$work/objlit-multi.md"
cat > "$objlit_multi_md" <<'FIXTURE'
```bash
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update --session-id "<sid>" \
  --set ".paused_on_environment = {
    reason: \"$reason\"
  }"
```
FIXTURE
if bash "$scanner" "$objlit_multi_md" 2>/dev/null | grep -q 'object-literal-in-set'; then
  ok "scanner flags a multi-line object literal in a --set value (#1561)"
else
  bad "scanner MISSED a multi-line object literal in a --set value (#1561)"
fi

# The sanctioned shapes pass: an empty literal, per-field path assignments
# (including a ${VAR:-default} value), --set-file, and set-slot.
objlit_ok_md="$work/objlit-ok.md"
cat > "$objlit_ok_md" <<'FIXTURE'
```bash
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" update --session-id "<sid>" \
  --set '.in_flight = {}' \
  --set ".paused_on_environment.resume_probe_multiplier = ${multiplier:-5}" \
  --set-file "<worktree>/.shipyard-scratch/expr.jq"
"$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" set-slot --session-id "<sid>" \
  --slot-id "slot-1" --kind issue --target "#4823"
```
FIXTURE
if bash "$scanner" "$objlit_ok_md" >/dev/null 2>&1; then
  ok "scanner passes empty literals, per-field assignments, --set-file and set-slot (#1561)"
else
  bad "scanner FALSE-POSITIVED on a sanctioned --set shape (#1561)"
fi

# The helper subcommands the fix directs callers to actually exist.
state_helper="$repo_root/plugins/shipyard/scripts/session-state.sh"
if grep -qE '^[[:space:]]+set-slot\)' "$state_helper" &&
   grep -qE '^[[:space:]]+release-slot\)' "$state_helper" &&
   grep -qF -- '--set-file)' "$state_helper"; then
  ok "session-state.sh exposes set-slot, release-slot and update --set-file (#1561)"
else
  bad "session-state.sh is missing set-slot / release-slot / --set-file (#1561)"
fi

# (21) Regression (issue #1579): skills/worker-preamble/*.md — the first
# worker-facing family admitted to the built-in FILES list — is clean of all
# four shapes, and is admitted by GLOB so a newly-added fragment is covered
# the moment it lands. Three assertions, each guarding a different way the
# admission could silently rot.
wp_dir="$repo_root/plugins/shipyard/skills/worker-preamble"

# (a) The whole directory scans clean. This is the assertion that fails if a
# future edit reintroduces a pipe or a gh/git-wrapping loop into a fragment.
if [[ -d "$wp_dir" ]]; then
  if bash "$scanner" "$wp_dir"/*.md >/dev/null 2>&1; then
    ok "scanner reports every skills/worker-preamble/*.md fragment as clean (#1579)"
  else
    bad "scanner found a compound shape in skills/worker-preamble/*.md — see script output for the offending block"
  fi
fi

# (b) The glob admission is still wired into FILES. Test (14)'s count proxy
# is scoped to commands/do-work/ paths and cannot see this one, so without
# this assertion the whole directory could drop off FILES while the scanner
# still reported "all scanned file(s) clean" over the remaining list.
# shellcheck disable=SC2016  # literal grep needle — matched verbatim in the script, not expanded
if grep -qF -- '"$repo_root/plugins/shipyard/skills/worker-preamble"/*.md' "$scanner"; then
  ok "scanner's built-in FILES list still admits skills/worker-preamble/*.md by glob (#1579)"
else
  bad "scanner no longer admits skills/worker-preamble/*.md — #1579's coverage ratchet has regressed"
fi

# (c) No allow markers in the directory. Every fragment there is
# post-relocation by construction, so an exemption could only ever be a
# shortcut around a real refused shape rather than a genuine
# pre-relocation carve-out like setup/*.md's two.
if [[ -d "$wp_dir" ]]; then
  wp_marker_count=$(grep -hcF -- '<!-- compound-block-scan: allow -->' "$wp_dir"/*.md 2>/dev/null | awk '{t += $1} END {print t + 0}')
  if [[ "$wp_marker_count" -eq 0 ]]; then
    ok "skills/worker-preamble/*.md carries no compound-block-scan allow markers (#1579)"
  else
    bad "skills/worker-preamble/*.md carries $wp_marker_count allow marker(s) — every fragment there is post-relocation, so an exemption can only be a shortcut around a real refused shape"
  fi
fi

# (22) Regression (issue #1590): agents/issue-worker/*.md — the second and
# last worker-facing family admitted to the built-in FILES list — is clean of
# all four shapes, and is admitted by GLOB so a per-mode file or fragment added
# later is covered the moment it lands. Three assertions, each guarding a
# different way the admission could silently rot. Mirrors #1579's trio for
# skills/worker-preamble/*.md.
iw_dir="$repo_root/plugins/shipyard/agents/issue-worker"

# (a) The whole directory scans clean. This is the assertion that fails if a
# future edit reintroduces a pipe or a gh/git-wrapping loop into a per-mode
# spec — fix-rebase.md most of all, which carried 16 of the 39 findings #1590
# swept, including both loop findings.
if [[ -d "$iw_dir" ]]; then
  if bash "$scanner" "$iw_dir"/*.md >/dev/null 2>&1; then
    ok "scanner reports every agents/issue-worker/*.md spec as clean (#1590)"
  else
    bad "scanner found a compound shape in agents/issue-worker/*.md — see script output for the offending block"
  fi
fi

# (b) The glob admission is still wired into FILES. Test (14)'s count proxy is
# scoped to commands/do-work/ paths and cannot see this one, so without this
# assertion the whole directory could drop off FILES while the scanner still
# reported "all scanned file(s) clean" over the remaining list.
# shellcheck disable=SC2016  # literal grep needle — matched verbatim in the script, not expanded
if grep -qF -- '"$repo_root/plugins/shipyard/agents/issue-worker"/*.md' "$scanner"; then
  ok "scanner's built-in FILES list still admits agents/issue-worker/*.md by glob (#1590)"
else
  bad "scanner no longer admits agents/issue-worker/*.md — #1590's coverage ratchet has regressed"
fi

# (c) No allow markers in the directory. Every executable spec there is
# post-relocation by construction, so an exemption could only ever be a
# shortcut around a real refused shape. The one file that could legitimately
# want an exemption some day — issue-work-RATIONALE.md, which quotes worked
# examples — carries no ```bash fences at all today, so the scanner is inert on
# it. If that changes, this assertion failing is the intended prompt to revisit
# the scanner's own admission comment, not to quietly relax the rule.
if [[ -d "$iw_dir" ]]; then
  iw_marker_count=$(grep -hcF -- '<!-- compound-block-scan: allow -->' "$iw_dir"/*.md 2>/dev/null | awk '{t += $1} END {print t + 0}')
  if [[ "$iw_marker_count" -eq 0 ]]; then
    ok "agents/issue-worker/*.md carries no compound-block-scan allow markers (#1590)"
  else
    bad "agents/issue-worker/*.md carries $iw_marker_count allow marker(s) — every executable spec there is post-relocation, so an exemption can only be a shortcut around a real refused shape"
  fi
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
