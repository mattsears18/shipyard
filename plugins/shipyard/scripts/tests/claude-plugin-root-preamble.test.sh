#!/usr/bin/env bash
# Test: every bash code block in the /shipyard:do-work phase files that
# references ${CLAUDE_PLUGIN_ROOT} also carries the canonical idempotent
# fallback-export preamble as its first non-blank line.
#
# Background — issue #354: $CLAUDE_PLUGIN_ROOT expands to the empty string
# inside the Bash-tool subprocess shells the orchestrator uses. The very
# first templated invocation of /shipyard:do-work (setup.md step 0.4's
# `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists`) therefore
# evaluates as `/scripts/shipyard-config.sh` and exits 127. Every subsequent
# script invocation in setup / steady-state / drain / cleanup-summary /
# inline-trivial would fail the same way.
#
# The fix is an idempotent preamble at the top of every bash snippet:
#
#   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"
#
# Semantics:
#   - When the harness DOES set $CLAUDE_PLUGIN_ROOT, the `${VAR:-default}`
#     short-circuits and the export is a no-op.
#   - When the harness does NOT set it (the observed steady-state for every
#     Bash-tool call inside this orchestrator), the fallback PROBES in order:
#       1. repo-local `<repo>/plugins/shipyard` IF it actually carries a
#          `scripts/` dir (the dogfooding case — shipyard's own checkout);
#       2. else the marketplace install `$HOME/.claude/plugins/marketplaces/
#          */plugins/shipyard` (the consumer-install case — issue #417, where
#          a marketplace-installed shipyard runs against a repo that has no
#          repo-local plugins/shipyard, so the old bare repo-local fallback
#          resolved to a non-existent path and every helper call exited 127);
#       3. else the repo-local path anyway (preserves a meaningful path for
#          error messaging when neither layer resolves).
#
# This test is the regression guard: if anyone adds a new bash block that
# uses ${CLAUDE_PLUGIN_ROOT} without the preamble at its top, the test
# fails. Existing blocks were swept by the issue #354 PR; new ones (or
# any block whose preamble got moved / removed) regress here.
#
# Scope — explicitly the do-work orchestrator phase files. NOT version.md,
# eas-watch.md, or status.md: those are different surfaces with different
# rationales (version.md wants the *installed* plugin path, not the repo
# checkout; eas-watch.md runs in an Expo project where the repo's
# plugins/shipyard doesn't exist; status.md is invoked by the user, not
# templated into orchestrator output).
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/claude-plugin-root-preamble.test.sh

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

# Files in scope — the do-work orchestrator phase files. Each templated
# bash block in these files runs in a fresh Bash-tool subprocess shell, so
# the harness-env-var quirk applies to every one of them.
FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/setup.md"
  "$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
  "$repo_root/plugins/shipyard/commands/do-work/drain.md"
  "$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
  "$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"
)

# The canonical preamble line. Anchored against literal text so any
# substitution (e.g. swapping the fallback path) trips this test.
# shellcheck disable=SC2016
EXPECTED_PREAMBLE='export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else M=$(ls -d "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard 2>/dev/null | head -1); echo "${M:-$R/plugins/shipyard}"; fi)}"'

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass+1))
}

assert_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail+1))
}

echo "claude-plugin-root preamble regression tests (issue #354)"
echo

# (1) Every file under test must exist. A missing file is a different
# class of regression (rename without test update) but still a failure.
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    assert_pass "$f exists"
  else
    assert_fail "$f exists (missing)"
  fi
done

# (2) The canonical preamble is documented in setup.md step 0.3, so any
# reader of the spec can find the rationale for the pattern in one place.
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup.md"
if [[ -f "$SETUP_MD" ]]; then
  if grep -qF "### 0.3 \`CLAUDE_PLUGIN_ROOT\` re-export preamble" "$SETUP_MD"; then
    assert_pass "setup.md documents step 0.3 (preamble rationale)"
  else
    assert_fail "setup.md documents step 0.3 (preamble rationale)"
  fi

  if grep -qF "$EXPECTED_PREAMBLE" "$SETUP_MD"; then
    assert_pass "setup.md contains the canonical preamble line"
  else
    assert_fail "setup.md contains the canonical preamble line"
  fi
fi

# (3) Walk every bash code block in every file under test. For each block
# that references ${CLAUDE_PLUGIN_ROOT}, assert the first non-blank line
# after the opening fence is the canonical preamble.
#
# Walking is done by an awk one-liner that emits one line per offending
# block: "<file>:<line-of-opening-fence>:<first-non-blank-line>".
walk_blocks() {
  local file="$1"
  awk -v file="$file" -v expected="$EXPECTED_PREAMBLE" '
    BEGIN { in_block = 0 }

    # opening bash fence (any indent)
    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      first_line = ""
      first_line_num = 0
      has_ref = 0
      next
    }

    # closing fence
    /^[ \t]*```[ \t]*$/ {
      if (in_block && has_ref) {
        # Strip indent for comparison — preamble may be indented to match
        # the fence indent (e.g. inside a numbered list item).
        stripped = first_line
        sub(/^[ \t]+/, "", stripped)
        if (stripped != expected) {
          # Emit: file:block_start_line:first_line_num:literal-first-line
          printf "%s|%d|%d|%s\n", file, block_start, first_line_num, first_line
        }
      }
      in_block = 0
      next
    }

    # inside a block
    in_block {
      if (/\$\{CLAUDE_PLUGIN_ROOT\}/) {
        has_ref = 1
      }
      # capture the first non-blank line for the preamble check
      if (first_line == "" && /[^ \t]/) {
        first_line = $0
        first_line_num = NR
      }
    }
  ' "$file"
}

offending_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS='|' read -r file fence_line first_line_num first_line; do
    offending_blocks=$((offending_blocks + 1))
    assert_fail "$file: bash block at line $fence_line uses \${CLAUDE_PLUGIN_ROOT} but first non-blank line (L$first_line_num) is not the canonical preamble"
    printf '         expected: %s\n' "$EXPECTED_PREAMBLE"
    printf '         got:      %s\n' "$first_line"
  done < <(walk_blocks "$f")
done

if (( offending_blocks == 0 )); then
  # Count the blocks that DID pass for an informational line.
  total_blocks=0
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # count bash blocks containing ${CLAUDE_PLUGIN_ROOT}
    count=$(awk '
      /^[ \t]*```bash[ \t]*$/ { in_block = 1; has_ref = 0; next }
      /^[ \t]*```[ \t]*$/ { if (in_block && has_ref) print "x"; in_block = 0; next }
      in_block && /\$\{CLAUDE_PLUGIN_ROOT\}/ { has_ref = 1 }
    ' "$f" | wc -l | tr -d ' ')
    total_blocks=$((total_blocks + count))
  done
  assert_pass "all $total_blocks bash blocks using \${CLAUDE_PLUGIN_ROOT} carry the canonical preamble"
fi

# (4) Sanity check — the preamble itself must actually work. Run it in a
# clean shell and confirm $CLAUDE_PLUGIN_ROOT resolves to a path that
# contains the helper scripts. This is the runtime contract the docs
# encode; if the path computation regresses (e.g. someone changes
# "plugins/shipyard" to "plugin/shipyard"), this catches it.
sanity_dir=$(env -i HOME="$HOME" PATH="$PATH" bash -c "
  cd '$repo_root'
  $EXPECTED_PREAMBLE
  echo \"\$CLAUDE_PLUGIN_ROOT\"
")
if [[ -d "$sanity_dir" && -x "$sanity_dir/scripts/shipyard-config.sh" ]]; then
  assert_pass "preamble resolves to a directory containing scripts/shipyard-config.sh"
else
  assert_fail "preamble resolves to a directory containing scripts/shipyard-config.sh (got '$sanity_dir')"
fi

# (5) Consumer-install sanity check (issue #417). Simulate a marketplace
# install running against a repo with NO repo-local plugins/shipyard: the
# old bare `$(git rev-parse --show-toplevel)/plugins/shipyard` fallback
# resolved to a non-existent path and every helper call exited 127. The
# new probe must fall through to the marketplace install path.
#
# Build a throwaway sandbox: a fake $HOME containing a marketplace tree,
# and a fake consumer git repo with no plugins/shipyard dir. Then run the
# preamble with cd into the consumer repo and confirm it resolves to the
# marketplace path (not the missing repo-local one).
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-417)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  fake_mp="$fake_home/.claude/plugins/marketplaces/shipyard/plugins/shipyard"
  mkdir -p "$fake_mp/scripts"
  # the probe only checks for the scripts/ dir on the repo-local branch and
  # returns the marketplace path verbatim, so an empty marketplace dir is
  # enough to prove the fall-through.
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  consumer_dir=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$consumer_dir" == "$fake_mp" ]]; then
    assert_pass "preamble falls through to marketplace install when repo has no plugins/shipyard (issue #417)"
  else
    assert_fail "preamble falls through to marketplace install when repo has no plugins/shipyard (got '$consumer_dir', expected '$fake_mp')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for consumer-install sanity check"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
