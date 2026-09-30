#!/usr/bin/env bash
# Test: every relative #anchor link in plugins/shipyard/**/*.md (+ root
# CLAUDE.md) resolves to a real heading in its target file — issue #866.
#
# Background
# ----------
# The `/do-work` phase docs cross-reference each other's subsections
# constantly, and every one of those links is a hand-maintained string that
# has to track its target heading's exact GitHub-rendered anchor slug.
# Nothing mechanically enforced that they stayed in sync, so anchors rotted
# silently every time a heading was renamed, split, or moved to a different
# file: issue #411 fixed 13 of these on 2026-05-31, and #866 found a fresh
# batch (the issue's own count of 6 turned out to be stale by the time this
# suite landed — see the checker's real-tree run at the bottom, which is the
# actual regression guard). Two throwaway Python GitHub-slug verifiers were
# independently written by two different workers in the same session that
# produced #866, which is the concrete signal this needed to be committed
# once instead of reinvented per PR.
#
# `check-anchor-links.mjs` does the checking; this suite proves the slug
# algorithm is correct against real repo headings (including two bugs found
# and fixed while building it — an intraword-underscore false-positive and
# a placeholder-collision bug that spliced the literal string "undefined"
# into a slug), proves the fenced-code / bold-lead-in / explicit-<a-id>
# edge cases behave as documented, proves a genuinely broken anchor is
# caught, and finally runs the checker against the real
# `plugins/shipyard/**` + root `CLAUDE.md` tree so the whole class of drift
# this issue fixed can't silently regress.
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/anchor-links-866.test.sh

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

checker="$repo_root/plugins/shipyard/scripts/check-anchor-links.mjs"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify anchor links" >&2
  exit 1
fi

if [[ -f "$checker" ]]; then
  assert_pass "check-anchor-links.mjs exists"
else
  assert_fail "check-anchor-links.mjs exists"
  echo "FAIL: cannot continue without the checker" >&2
  exit 1
fi

if node --check "$checker" >/tmp/anchor-links-syntax-check.$$ 2>&1; then
  assert_pass "checker has valid syntax (node --check)"
else
  assert_fail "checker has valid syntax (node --check)"
  cat /tmp/anchor-links-syntax-check.$$
fi
rm -f /tmp/anchor-links-syntax-check.$$

tmp="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Assert the checker exits 0 (no broken anchors found).
assert_ok() {
  local dir="$1" label="$2" out rc
  out=$(node "$checker" "$dir" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    checker reported a break where none was expected:\n'
    printf '    %s\n' "$out"
  fi
}

# Assert the checker exits 1 (a broken anchor found), optionally requiring
# the diagnostic output to mention a specific substring.
assert_broken() {
  local dir="$1" label="$2" expect="${3:-}" out rc
  out=$(node "$checker" "$dir" 2>&1); rc=$?
  if [[ $rc -ne 1 ]]; then
    assert_fail "$label"
    printf '    expected exit 1 (broken anchor found), got exit %s:\n' "$rc"
    printf '    %s\n' "$out"
    return
  fi
  if [[ -n "$expect" ]] && ! grep -qF -- "$expect" <<<"$out"; then
    assert_fail "$label"
    printf '    expected the diagnostic to mention: %s\n    got:\n    %s\n' "$expect" "$out"
    return
  fi
  assert_pass "$label"
}

# ==========================================================================
echo "== (A) usage errors"

out=$(node "$checker" 2>&1); rc=$?
if [[ $rc -eq 2 ]]; then
  assert_pass "no arguments -> exit 2 (usage error)"
else
  assert_fail "no arguments -> exit 2 (usage error), got $rc"
fi

out=$(node "$checker" "$tmp/does-not-exist" 2>&1); rc=$?
if [[ $rc -eq 2 ]]; then
  assert_pass "nonexistent path -> exit 2 (usage error)"
else
  assert_fail "nonexistent path -> exit 2 (usage error), got $rc"
fi

# ==========================================================================
echo "== (B) GitHub slug algorithm — real repro cases from #866"

# Case 2 from #866: a heading with backtick code spans and an em-dash. The
# WORKED EXAMPLE in check-anchor-links.mjs's own header comment traces this
# by hand — this fixture proves the code matches that trace.
mkdir -p "$tmp/b1"
cat > "$tmp/b1/drain.md" <<'EOF'
# Drain

#### 5.b — Re-validate `scope-agent` and `cached-diagnosis` entries

Body text.
EOF
cat > "$tmp/b1/caller.md" <<'EOF'
# Caller

See [5.b's re-validation](drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries).
EOF
assert_ok "$tmp/b1" "em-dash + code-span heading slug matches GitHub's real anchor (issue #866 case 2)"

# The SAME fixture with the stale (pre-drift) anchor must be caught broken.
mkdir -p "$tmp/b2"
cp "$tmp/b1/drain.md" "$tmp/b2/drain.md"
cat > "$tmp/b2/caller.md" <<'EOF'
# Caller

See [5.b's re-validation](drain.md#5b--re-validate-scope-agent-entries).
EOF
assert_broken "$tmp/b2" "a stale anchor missing the heading's later growth is caught" "does not match any heading"

# ==========================================================================
echo "== (C) regression: intraword underscore is not emphasis (CommonMark rule)"

# A heading with a BARE snake_case identifier (no backticks) must NOT have
# its underscores stripped as italic markers — this is the literal repro
# from docs/design/do-work-rationale.md's real heading
# "why ci skip_speculative_rerun does not disable the flake path".
mkdir -p "$tmp/c1"
cat > "$tmp/c1/target.md" <<'EOF'
# Target

## Dispatch rules — why ci skip_speculative_rerun does not disable the flake path
EOF
cat > "$tmp/c1/caller.md" <<'EOF'
# Caller

[link](target.md#dispatch-rules--why-ci-skip_speculative_rerun-does-not-disable-the-flake-path)
EOF
assert_ok "$tmp/c1" "bare snake_case identifier in heading text keeps its underscores (not mangled as italic)"

# A GENUINE italic word (surrounded by whitespace, not embedded in an
# identifier) must still be stripped — the underscore fix must not
# overcorrect into never stripping emphasis at all.
mkdir -p "$tmp/c2"
cat > "$tmp/c2/target.md" <<'EOF'
# Target

### 2. Exactly ONE re-dispatch is permitted — and only as a *correction*
EOF
cat > "$tmp/c2/caller.md" <<'EOF'
# Caller

[link](target.md#2-exactly-one-re-dispatch-is-permitted--and-only-as-a-correction)
EOF
assert_ok "$tmp/c2" "genuine italic emphasis (*correction*) is still stripped from the slug"

# ==========================================================================
echo "== (D) regression: placeholder-collision bug (literal \"undefined\" in slug)"

# The literal repro from plugins/shipyard/commands/do-work/dispatch-rules.md
# real heading "Dispatch rules (used by step 7 and step C)" — an earlier
# version of the checker's code-span placeholder was a bare number
# surrounded by spaces, which collided with "step 7" in real heading prose
# and spliced the string "undefined" into the computed slug.
mkdir -p "$tmp/d1"
cat > "$tmp/d1/target.md" <<'EOF'
# Target

## Dispatch rules (used by step 7 and step C)
EOF
cat > "$tmp/d1/caller.md" <<'EOF'
# Caller

[link](target.md#dispatch-rules-used-by-step-7-and-step-c)
EOF
assert_ok "$tmp/d1" "a heading containing a bare number-in-spaces (\"step 7\") does not leak \"undefined\" into the slug"

# A link that WOULD have matched the buggy "...stepundefinedand-step-c"
# slug must now correctly report broken, not silently pass.
mkdir -p "$tmp/d2"
cp "$tmp/d1/target.md" "$tmp/d2/target.md"
cat > "$tmp/d2/caller.md" <<'EOF'
# Caller

[link](target.md#dispatch-rules-used-by-stepundefinedand-step-c)
EOF
assert_broken "$tmp/d2" "the pre-fix buggy slug (containing literal 'undefined') is correctly rejected" "does not match any heading"

# ==========================================================================
echo "== (E) bold/italic list-item lead-ins are NOT headings (issue #866 cases 1 and 4)"

# A bold numbered-list lead-in styled like a subsection is NOT promoted to
# a real heading by GitHub — a link at its would-be slug must report broken
# rather than silently resolving because the text is visually present.
mkdir -p "$tmp/e1"
cat > "$tmp/e1/target.md" <<'EOF'
# Target

4.6. **Version-coordinated manifest re-number — trivial resolution.** Prose here.
EOF
cat > "$tmp/e1/caller.md" <<'EOF'
# Caller

[§4.6](target.md#46-version-coordinated-manifest-re-number--trivial-resolution)
EOF
assert_broken "$tmp/e1" "a bold list-item lead-in is never mistaken for a real heading" "does not match any heading"

# ==========================================================================
echo "== (F) explicit <a id=\"...\"> / <a name=\"...\"> anchors are honored"

# GitHub renders raw HTML in markdown, so an explicit id attribute is a
# real link-fragment target even with no corresponding heading — this repo
# uses the pattern deliberately (CLAUDE.md's agent-console, my-turn.md's
# operator-pointer-line) to hang a stable anchor off a bold lead-in.
mkdir -p "$tmp/f1"
cat > "$tmp/f1/target.md" <<'EOF'
# Target

- <a id="agent-console"></a>`agent-console` — an operator-action gate.
EOF
cat > "$tmp/f1/caller.md" <<'EOF'
# Caller

[the gate](target.md#agent-console)
EOF
assert_ok "$tmp/f1" "explicit <a id=\"...\"> anchor is honored as a valid link target"

# ==========================================================================
echo "== (G) fenced code blocks are skipped entirely — both as heading source and link source"

# A '#' at the start of a line INSIDE a fenced code block (a bash comment)
# must never be mistaken for a real ATX heading, and link-shaped text
# INSIDE a fence (illustrative example syntax) must never be mistaken for
# a real link to validate.
mkdir -p "$tmp/g1"
cat > "$tmp/g1/target.md" <<'EOF'
# Target

## Real heading

```bash
# Not a heading — this is a bash comment inside a fence.
echo "example: [fake link](#nonexistent-anchor-inside-a-fence)"
```
EOF
cat > "$tmp/g1/caller.md" <<'EOF'
# Caller

[real link](target.md#real-heading)
EOF
assert_ok "$tmp/g1" "a '#' comment and a link-shaped example inside a fenced code block are both ignored"

# ==========================================================================
echo "== (H) duplicate headings get GitHub's -1/-2/... suffix"

mkdir -p "$tmp/h1"
cat > "$tmp/h1/target.md" <<'EOF'
# Target

## Overview

Some text.

## Overview

More text, second occurrence.
EOF
cat > "$tmp/h1/caller.md" <<'EOF'
# Caller

[first](target.md#overview)
[second](target.md#overview-1)
EOF
assert_ok "$tmp/h1" "a repeated heading's second occurrence resolves to the -1 suffix"

# ==========================================================================
echo "== (I) missing-file vs missing-anchor are reported as distinct classes"

mkdir -p "$tmp/i1"
cat > "$tmp/i1/caller.md" <<'EOF'
# Caller

[gone](does-not-exist.md#anywhere)
EOF
assert_broken "$tmp/i1" "a link to a nonexistent target file is reported as missing-file, not missing-anchor" "does not exist"

# ==========================================================================
echo "== (J) same-file anchors (no path portion) are checked too"

mkdir -p "$tmp/j1"
cat > "$tmp/j1/solo.md" <<'EOF'
# Solo

## Section one

[bad self-link](#section-two-does-not-exist)
EOF
assert_broken "$tmp/j1" "a same-file #anchor link with no matching heading is caught" "does not match any heading"

# ==========================================================================
echo "== (K) real repo — the actual regression guard for issue #866"

# This is the check that matters: every #anchor link under the real
# plugins/shipyard/**/*.md tree plus the root CLAUDE.md must resolve. All
# 6 anchors #866 reported (plus every other break the mechanical resolver
# found beyond the issue's own stale count) were fixed in the same PR that
# added this suite.
real_out=$(node "$checker" "$repo_root/plugins/shipyard" "$repo_root/CLAUDE.md" 2>&1)
real_rc=$?
if [[ $real_rc -eq 0 ]]; then
  assert_pass "real plugins/shipyard/**/*.md + root CLAUDE.md tree has 0 broken anchor links"
else
  assert_fail "real plugins/shipyard/**/*.md + root CLAUDE.md tree has 0 broken anchor links"
  printf '    %s\n' "$real_out"
fi

# ==========================================================================
echo ""
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
