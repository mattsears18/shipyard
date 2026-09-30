#!/usr/bin/env bash
# Test: re-validating an issue's SELF-DECLARED "out of scope for an agent"
# claim instead of trusting it (issue #1491).
#
# Background
# ----------
# Session `do-work-20260820T024447Z-51928` against `mattsears18/lightwork`:
# two issues declared in their own bodies that the `.github/workflows/` half
# of their work was "out of scope for an autonomous `/shipyard:do-work`
# worker" and handed it to a human. Both premises were FALSE at dispatch time
# — the dispatching `gh` token carried the `workflow` OAuth scope. Four more
# issues in the same backlog were shaped by the same assumption. Taken at face
# value each would have shipped half a feature and filed a spurious
# `agent-console` hand-back for work the agent could do itself, which is
# invisible in every summary because a hand-back looks like a legitimate
# outcome.
#
# This suite pins four things:
#
#   (A) DECISION LOGIC — detect-stale-agent-limitation.sh's
#       `--decide <claim> <capability>` truth table. Pure (no network I/O),
#       driven directly, the same shape workflow-scope-preflight-818.test.sh
#       drives detect-missing-workflow-scope.sh --decide.
#
#   (B) BODY SCAN — the two-part match (an agent-limitation phrasing AND a
#       probeable capability anchor, in the SAME paragraph) that keeps this
#       narrow rather than a general-purpose "second-guess the issue author"
#       heuristic. Every positive case is paired with a near-miss negative so
#       the scanner is proven to discriminate rather than trivially fire.
#
#   (C) PROBE INDEPENDENCE — the probe must NOT delegate to
#       detect-missing-workflow-scope.sh, whose `warn`/`silent` vocabulary
#       conflates "has the scope" with "lacks it but no session signal" and
#       therefore structurally cannot answer this question. The probe is
#       tri-state (`has`/`lacks`/`unknown`) precisely so "can't tell" stays
#       distinct from "lacks".
#
#   (D) DOC CONTRACT — setup/06-scope-preflight.md runs the check and
#       documents all four verdicts; setup/06b-scope-carveouts.md rejects the
#       body's self-declared limitation as an `evidence_pointer`; and
#       dispatch-rules.md's stale-agent-limitation augmentation is rendered by
#       the workflow-substrate builder too (not waived).
#
# Pure bash. Run with:
#   bash plugins/shipyard/scripts/tests/stale-agent-limitation-1491.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-stale-agent-limitation.sh"
# Scanned across every setup/*.md fragment rather than pinned to one hardcoded
# path — a router/fragment split can silently relocate a step's content out of
# the file that holds it today (issue #1453, enforced by
# setup-fragment-content-scan.sh).
SETUP_DIR="$repo_root/plugins/shipyard/commands/do-work/setup"
DISPATCH_MD="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

assert_contains_in_setup() {
  local needle="$1" label="$2"
  if grep -qFl -- "$needle" "$SETUP_DIR"/*.md 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find (in any setup/*.md fragment): %s\n' "$needle"
  fi
}

# decide <claim> <capability> <expected> <label>
assert_decide() {
  local got
  got="$(bash "$DETECTOR" --decide "$1" "$2" 2>/dev/null)"
  if [[ "$got" == "$3" ]]; then
    assert_pass "$4 (claim=$1 capability=$2 => $got)"
  else
    assert_fail "$4 (claim=$1 capability=$2 => expected [$3], got [$got])"
  fi
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# write_fixture <name> — reads the body from stdin, echoes the path.
write_fixture() {
  local path="$TMPDIR_TEST/$1"
  cat > "$path"
  printf '%s' "$path"
}

# assert_scan <fixture-path> <fires:yes|no> <label>
assert_scan() {
  local got
  got="$(bash "$DETECTOR" --scan "$1" 2>/dev/null)"
  if [[ "$2" == "yes" ]]; then
    if [[ "$got" == class=workflow-scope\ * ]]; then
      assert_pass "$3"
    else
      assert_fail "$3 (expected a workflow-scope hit, got [$got])"
    fi
  else
    if [[ "$got" == "none" ]]; then
      assert_pass "$3"
    else
      assert_fail "$3 (expected [none], got [$got])"
    fi
  fi
}

echo "self-declared agent-limitation re-validation regression tests (issue #1491)"
echo

# ---------------------------------------------------------------------------
# (A) Decision truth table.
# ---------------------------------------------------------------------------
echo "(A) detect-stale-agent-limitation.sh — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-stale-agent-limitation.sh exists"
  if [[ -x "$DETECTOR" ]]; then
    assert_pass "detect-stale-agent-limitation.sh is executable"
  else
    assert_fail "detect-stale-agent-limitation.sh is executable"
  fi

  # The whole point of the issue: body says the agent can't, session says it can.
  assert_decide 1 has stale \
    "self-declared limitation + capability present => stale (the #1491 repro)"

  # The premise still holds — no correction to make. Explicitly NOT a defer.
  assert_decide 1 lacks upheld \
    "self-declared limitation + capability absent => upheld (no-op, never a defer)"

  # Never synthesize a correction from an unresolvable probe.
  assert_decide 1 unknown indeterminate \
    "self-declared limitation + unresolvable capability => indeterminate"

  # No claim in the body at all — the common case.
  assert_decide 0 has no-claim \
    "no self-declared limitation => no-claim even when the capability is present"
  assert_decide 0 lacks no-claim \
    "no self-declared limitation => no-claim when the capability is absent"
else
  assert_fail "detect-stale-agent-limitation.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Body scan — the narrow two-part match. Each positive is paired with a
#     near-miss negative so a scanner that fired on everything (or matched
#     nothing) would fail here rather than pass vacuously.
# ---------------------------------------------------------------------------
echo "(B) body scan — agent-limitation phrasing AND a probeable capability anchor"
if [[ -f "$DETECTOR" ]]; then
  f_repro="$(write_fixture repro.md <<'EOF'
## What happened

`.github/workflows/**` is out of scope for an autonomous `/shipyard:do-work` worker in this repo. #4225 landed the `lighthouserc.cjs` half, so the workflow edit is handed back here.
EOF
)"
  assert_scan "$f_repro" yes \
    "fires on the #4255 repro shape (out-of-scope-for-a-worker + .github/workflows)"

  f_handedback="$(write_fixture handed-back.md <<'EOF'
The key-file half is scoped for an agent; the `.github/workflows/deploy.yml` wiring is handed back for a human to do.
EOF
)"
  assert_scan "$f_handedback" yes \
    "fires on the #4176 'handed back' shape"

  f_requires_human="$(write_fixture requires-human.md <<'EOF'
Editing `.github/workflows/release.yml` requires a human — an agent cannot do it.
EOF
)"
  assert_scan "$f_requires_human" yes \
    "fires on 'requires a human' / 'an agent cannot' phrasing"

  # NEGATIVE 1 — an ordinary body with no self-declared limitation at all.
  f_plain="$(write_fixture plain.md <<'EOF'
The lighthouse budget threshold in `lighthouserc.cjs` is wrong. Fix it.
EOF
)"
  assert_scan "$f_plain" no \
    "does NOT fire on an ordinary body with no self-declared limitation"

  # NEGATIVE 2 — Detector 1 case 3: the workflow edit IS the deliverable, with
  # no limitation claim anywhere. Nothing to re-validate.
  f_deliverable="$(write_fixture deliverable.md <<'EOF'
Rewrite the `on:` triggers across `.github/workflows/tests.yml` and `.github/workflows/shellcheck.yml`.
EOF
)"
  assert_scan "$f_deliverable" no \
    "does NOT fire on a plain workflow-deliverable body (no limitation claim)"

  # NEGATIVE 3 — a limitation claim about something this script cannot probe.
  # Without a probeable capability there is no premise to re-derive, so firing
  # here would be exactly the general-purpose second-guessing this must not be.
  f_unprobeable="$(write_fixture unprobeable.md <<'EOF'
Choosing the new pricing tier requires a human — an agent cannot make that call.
EOF
)"
  assert_scan "$f_unprobeable" no \
    "does NOT fire on a limitation claim with no probeable capability anchor"

  # NEGATIVE 4 — both halves present but in DIFFERENT paragraphs. The
  # same-paragraph requirement is what keeps the match a real claim about the
  # named capability rather than two unrelated sentences co-occurring.
  f_split="$(write_fixture split.md <<'EOF'
Picking the rollout window requires a human.

Unrelated context about the release process.

Separately, `.github/workflows/tests.yml` gained a concurrency group last week.
EOF
)"
  assert_scan "$f_split" no \
    "does NOT fire when the limitation phrasing and the capability anchor are in different paragraphs"

  # NEGATIVE 5 — "out of scope" about the ISSUE's scope, not the AGENT's
  # capability. The phrasing list deliberately requires worker/agent framing.
  f_issue_scope="$(write_fixture issue-scope.md <<'EOF'
Rewriting `.github/workflows/tests.yml` end-to-end is out of scope for this issue; only the concurrency group changes here.
EOF
)"
  assert_scan "$f_issue_scope" no \
    "does NOT fire on a plain issue-scope statement that names no agent limitation"

  # TOLERATED OVER-FIRE — a meta-issue that merely QUOTES the shape (issue
  # #1491's own body) still fires. Documented and deliberate: the only action
  # is one advisory sentence, so the asymmetry runs the opposite way from
  # Detector 2's. Pinned so a future "add a meta-mention guard" change has to
  # update the spec's own claim rather than silently contradict it.
  f_meta="$(write_fixture meta.md <<'EOF'
Two issues in that backlog had, in their own bodies, declared part of their work out of scope for an autonomous worker: `.github/workflows/**` was handed back to a human even though the token carried the scope.
EOF
)"
  assert_scan "$f_meta" yes \
    "fires on a meta-issue quoting the shape (documented, tolerated over-fire — advisory-only action)"
fi
echo

# ---------------------------------------------------------------------------
# (C) Probe independence + live-mode fail-safe.
# ---------------------------------------------------------------------------
echo "(C) probe independence — tri-state, and never delegated to the conflating detector"
if [[ -f "$DETECTOR" ]]; then
  # The forbidden delegation. detect-missing-workflow-scope.sh's `silent`
  # conflates "has the scope" with "lacks it but no session signal", so
  # calling it here would reintroduce the exact ambiguity this check exists
  # to resolve — 06-scope-preflight.md's Detector 1 note says so explicitly.
  if grep -q 'detect-missing-workflow-scope.sh' "$DETECTOR"; then
    if grep -qE '^[^#]*detect-missing-workflow-scope\.sh' "$DETECTOR"; then
      assert_fail "detect-stale-agent-limitation.sh does not INVOKE detect-missing-workflow-scope.sh"
    else
      assert_pass "detect-stale-agent-limitation.sh only mentions detect-missing-workflow-scope.sh in comments, never invokes it"
    fi
  else
    assert_pass "detect-stale-agent-limitation.sh does not reference detect-missing-workflow-scope.sh at all"
  fi

  # Tri-state is the whole reason this probe exists separately.
  for verdict in has lacks unknown; do
    if grep -qF "echo \"$verdict\"" "$DETECTOR"; then
      assert_pass "probe can return the tri-state verdict '$verdict'"
    else
      assert_fail "probe can return the tri-state verdict '$verdict'"
    fi
  done

  # An unknown capability class must resolve toward the no-op, never guess.
  got="$(bash "$DETECTOR" --probe not-a-real-class 2>/dev/null)"
  if [[ "$got" == "unknown" ]]; then
    assert_pass "--probe on an unrecognized class => unknown (never a guess)"
  else
    assert_fail "--probe on an unrecognized class => unknown (got [$got])"
  fi

  # Fail-safe: no argument, and a missing file, both resolve to the no-op
  # verdict with exit 0. An advisory check must never fail its caller.
  got="$(bash "$DETECTOR" 2>/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 && "$got" == verdict=no-claim* ]]; then
    assert_pass "no argument => exits 0 with verdict=no-claim (fail-safe, not a hard error)"
  else
    assert_fail "no argument => exits 0 with verdict=no-claim (got rc=$rc, output=[$got])"
  fi

  got="$(bash "$DETECTOR" "$TMPDIR_TEST/does-not-exist.md" 2>/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 && "$got" == verdict=no-claim* ]]; then
    assert_pass "missing body file => exits 0 with verdict=no-claim"
  else
    assert_fail "missing body file => exits 0 with verdict=no-claim (got rc=$rc, output=[$got])"
  fi

  # Live mode emits the parseable one-line contract the spec's verdict table
  # keys on.
  got="$(bash "$DETECTOR" "$f_repro" 2>/dev/null)"
  if [[ "$got" == verdict=*\ class=workflow-scope\ capability=*\ phrase=* ]]; then
    assert_pass "live mode emits the documented 'verdict=... class=... capability=... phrase=...' line"
  else
    assert_fail "live mode emits the documented verdict line (got [$got])"
  fi
fi
echo

# ---------------------------------------------------------------------------
# (D) Doc contract.
# ---------------------------------------------------------------------------
echo "(D) doc contract — setup step 6, the carve-outs file, and the dispatch augmentation"
if [[ -d "$SETUP_DIR" ]]; then
  assert_contains_in_setup 'detect-stale-agent-limitation.sh' \
    "setup/*.md invokes the detector script"

  # Every verdict in the action table, keyed on its own row text rather than
  # the bare token — a bare `stale`/`upheld` would match incidental prose.
  assert_contains_in_setup 'the body declares no agent limitation this check can probe' \
    "setup/*.md documents the 'no-claim' verdict"
  assert_contains_in_setup 'live session state says it can' \
    "setup/*.md documents the 'stale' verdict"
  assert_contains_in_setup 'claim about the capability still holds' \
    "setup/*.md documents the 'upheld' verdict"
  assert_contains_in_setup 'the capability could not be established' \
    "setup/*.md documents the 'indeterminate' verdict"

  # The load-bearing prohibition: the conflating detector must not be
  # substituted for this probe.
  assert_contains_in_setup 'Do NOT substitute' \
    "setup/*.md forbids substituting detect-missing-workflow-scope.sh for this probe"
  assert_contains_in_setup 'structurally cannot answer' \
    "setup/*.md states WHY that substitution is wrong (the silent-verdict conflation)"

  # Advisory-only is what licenses the tolerated over-fire in (B).
  assert_contains_in_setup 'gates no dispatch, produces no defer' \
    "setup/*.md states the check is advisory — gates nothing, defers nothing"

  # `upheld` is explicitly NOT a defer reason.
  assert_contains_in_setup 'is a no-op, not a defer' \
    "setup/*.md states an 'upheld' verdict is still not a defer reason"

  # Narrowness is a stated contract, not an accident of the current regex.
  assert_contains_in_setup 'general-purpose "second-guess the issue author" heuristic' \
    "setup/*.md pins the narrowness contract (never a general-purpose second-guessing heuristic)"

  assert_contains_in_setup 'self-declared limitation on the agent' \
    "setup/*.md rejects the body's self-declared limitation as an evidence_pointer"
  assert_contains_in_setup 'Self-declared agent-limitation carve-out' \
    "setup/*.md carries the scoping-agent prompt instruction for this carve-out"
else
  assert_fail "commands/do-work/setup/ exists (missing at $SETUP_DIR)"
fi

if [[ -f "$DISPATCH_MD" ]]; then
  assert_contains "$DISPATCH_MD" 'Stale-agent-limitation augmentation' \
    "dispatch-rules.md carries the stale-agent-limitation augmentation"
  assert_contains "$DISPATCH_MD" 'Stale premise in the issue body (orchestrator-verified, #1491):' \
    "dispatch-rules.md's augmentation blockquote carries the worker-facing anchor phrase"
  assert_contains "$DISPATCH_MD" 'the dispatching gh token carries the workflow OAuth scope' \
    "dispatch-rules.md pins the fixed per-class correction string (not free-form orchestrator prose)"
else
  assert_fail "dispatch-rules.md exists (missing at $DISPATCH_MD)"
fi

echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
