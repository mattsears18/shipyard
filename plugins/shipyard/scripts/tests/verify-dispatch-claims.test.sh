#!/usr/bin/env bash
# Test: scripts/verify-dispatch-claims.sh — the composition-time gate that
# re-resolves a dispatch prompt's claims about another PR's/issue's live state
# and refuses the dispatch on a contradiction (issue #1553).
#
# The `--scan` / `--decide` halves are pure and fixture-driven. The live gate
# mode is exercised against a stubbed `gh` on PATH (the same technique
# gh-batch.test.sh uses), so this suite is hermetic — no network, no real repo.
#
# Fixture note: the repro prompt below is #1553's own, verbatim in shape — the
# false "whose fix **has merged** (PR #4662 ...)" line composed against
# `mattsears18/lightwork` while PR #4662 was still OPEN.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/verify-dispatch-claims.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../verify-dispatch-claims.sh"

echo "verify-dispatch-claims.sh tests (issue #1553)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# --- stub `gh` ------------------------------------------------------------
# Convention: PR numbers 4662 (OPEN) / 4700 (MERGED) / 4701 (CLOSED); issue
# numbers 4661 (CLOSED) / 4663 (OPEN). Anything else is unresolvable, which
# is how a deleted / wrong-repo referent behaves.
stub_bin="$tmproot/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
kind="${1:-}"
sub="${2:-}"
num="${3:-}"
[ "$sub" = "view" ] || exit 1
case "$kind:$num" in
  pr:4662) echo "OPEN" ;;
  pr:4700) echo "MERGED" ;;
  pr:4701) echo "CLOSED" ;;
  issue:4661) echo "CLOSED" ;;
  issue:4663) echo "OPEN" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

# --- fixtures -------------------------------------------------------------
repro="$tmproot/repro.md"
cat > "$repro" <<'EOF'
**`mode: issue-work`** — Work issue #4663 in `mattsears18/lightwork` to completion.

Context: this issue is the follow-up to #4661, whose fix **has merged** (PR #4662 → `apps/lightwork/eslint.config.js`, confirmed by reading the merged state).

Return values: `shipped #4663 via PR #<M>` ([#1390](https://github.com/mattsears18/shipyard/issues/1390)).
EOF

clean="$tmproot/clean.md"
cat > "$clean" <<'EOF'
**`mode: issue-work`** — Work issue #4663 in `mattsears18/lightwork` to completion.

Context: PR #4700 has merged, so `main` already carries the shared helper.
EOF

hedged="$tmproot/hedged.md"
cat > "$hedged" <<'EOF'
**`mode: issue-work`** — Work issue #4663 in `mattsears18/lightwork`.

PR #4662 should have merged by the time you start; verify with `gh pr view 4662 --json state,mergedAt` before assuming `main` has the fix.
EOF

content="$tmproot/content.md"
cat > "$content" <<'EOF'
There is no literal fetch command in `setup/04-backlog-divert.md` — the worker must construct one.
EOF

grounded="$tmproot/grounded.md"
cat > "$grounded" <<'EOF'
There is no literal fetch command in `setup/04-backlog-divert.md` (grounded: grep -n "gh issue list" setup/04-backlog-divert.md → no match).
EOF

unresolvable="$tmproot/unresolvable.md"
cat > "$unresolvable" <<'EOF'
Context: PR #9999 has merged, so `main` already carries the fix.
EOF

# --- (1) --scan on #1553's repro prompt -----------------------------------
out="$(bash "$script" --scan "$repro" 4663 2>/dev/null)"
if grep -qF "kind=merged line=3 ref=4662" <<<"$out"; then
  ok "--scan finds the merged claim and attaches PR #4662 to it"
else
  bad "--scan missed the #4662 merged claim; got: $out"
fi
if grep -qF "ref=4661" <<<"$out"; then
  ok "--scan also surfaces the same line's #4661 referent (typed later, by probe)"
else
  bad "--scan dropped #4661 from the claim line; got: $out"
fi

# --- (2) --self excludes the dispatched issue's own number ----------------
if grep -qF "ref=4663" <<<"$out"; then
  bad "--self 4663 did not exclude the dispatched issue's own number; got: $out"
else
  ok "--self excludes the dispatched issue's own number"
fi

# --- (3) a markdown citation link is never treated as a claim referent ----
# Line 5 carries `([#1390](https://...))` next to no claim keyword at all, and
# the link form is stripped before referent extraction regardless.
if grep -qF "ref=1390" <<<"$out"; then
  bad "--scan treated the [#1390](url) citation link as a claim referent"
else
  ok "markdown citation links are stripped before referent extraction"
fi

# --- (4) hedged lines are never reported (#1062's own prescribed rewrite) --
out="$(bash "$script" --scan "$hedged" 4663 2>/dev/null)"
if [[ "$out" == "none" ]]; then
  ok "#1062's conditional rewrite ('should have merged … verify with') scans clean"
else
  bad "hedged line was reported as a claim; got: $out"
fi

# --- (5) --decide truth table ---------------------------------------------
decide_case() {
  local kind="$1" probe="$2" want="$3"
  local got
  got="$(bash "$script" --decide "$kind" "$probe" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    ok "--decide $kind $probe -> $want"
  else
    bad "--decide $kind $probe -> got '$got', want '$want'"
  fi
}
decide_case merged pr:MERGED    ok
decide_case merged pr:OPEN      contradicted
decide_case merged pr:CLOSED    contradicted
decide_case merged issue:OPEN   n/a
decide_case merged unknown      indeterminate
decide_case closed issue:CLOSED ok
decide_case closed issue:OPEN   contradicted
decide_case closed pr:MERGED    ok
decide_case closed unknown      indeterminate
decide_case content anything    contradicted

# --- (6) live gate: the repro prompt is REFUSED ---------------------------
out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork --self 4663 "$repro" 2>/dev/null)"
code=$?
if [[ "$code" -eq 1 ]]; then
  ok "#1553 repro 1 prompt: exit 1 (refused)"
else
  bad "#1553 repro 1 prompt: got exit=$code (expected 1); out=$out"
fi
if grep -qF "CONTRADICTED: line 3 claims #4662 merged" <<<"$out"; then
  ok "refusal names the contradicted PR, the line, and the claim kind"
else
  bad "refusal did not name the #4662 contradiction; got: $out"
fi
if grep -qF "live state is pr:OPEN" <<<"$out"; then
  ok "refusal reports the LIVE state that contradicts the claim"
else
  bad "refusal omitted the live state; got: $out"
fi
if grep -qF "Rewrite conditionally per #1062" <<<"$out"; then
  ok "refusal hands back #1062's conditional rewrite"
else
  bad "refusal omitted the conditional rewrite; got: $out"
fi
# The same line's #4661 is an ISSUE, and a merge claim cannot attach to an
# issue — it must be silently skipped, not reported as a second contradiction.
if grep -qF "#4661" <<<"$out"; then
  bad "a merge claim was wrongly evaluated against issue #4661; got: $out"
else
  ok "a merge claim against an issue referent is skipped (n/a), not reported"
fi

# --- (7) live gate: a TRUE claim passes -----------------------------------
out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork --self 4663 "$clean" 2>/dev/null)"
code=$?
if [[ "$code" -eq 0 && "$out" == OK:* ]]; then
  ok "a genuinely-merged claim (PR #4700) passes: exit 0, OK"
else
  bad "true claim: got exit=$code out='$out' (expected 0 + OK:)"
fi

# --- (8) live gate: unresolvable referent FAILS CLOSED at exit 2 ----------
out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork "$unresolvable" 2>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "INDETERMINATE:" <<<"$out"; then
  ok "unresolvable referent: exit 2 + INDETERMINATE (fails closed)"
else
  bad "unresolvable referent: got exit=$code out='$out' (expected 2 + INDETERMINATE)"
fi

# --- (9) content claim: flagged UNGROUNDED, and suppressed once grounded --
out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork "$content" 2>/dev/null)"
code=$?
if [[ "$code" -eq 1 ]] && grep -qF "UNGROUNDED: line 1" <<<"$out"; then
  ok "spec-content claim is flagged UNGROUNDED and refuses (exit 1)"
else
  bad "content claim: got exit=$code out='$out' (expected 1 + UNGROUNDED)"
fi
if grep -qF 'setup/04-backlog-divert.md' <<<"$out"; then
  ok "UNGROUNDED line names the file path the claim is about"
else
  bad "UNGROUNDED line omitted the path; got: $out"
fi

out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork "$grounded" 2>/dev/null)"
code=$?
if [[ "$code" -eq 0 ]]; then
  ok "an inline '(grounded: <cmd>)' citation suppresses the content claim"
else
  bad "grounded content claim: got exit=$code out='$out' (expected 0)"
fi

# --- (10) a prompt with no claims at all ----------------------------------
noclaims="$tmproot/noclaims.md"
cat > "$noclaims" <<'EOF'
**`mode: issue-work`** — Work issue #4663 in `mattsears18/lightwork` to completion.
Branch: `do-work/issue-4663`. Open a PR that closes the issue.
EOF
out="$(PATH="$stub_bin:$PATH" bash "$script" --repo mattsears18/lightwork --self 4663 "$noclaims" 2>/dev/null)"
code=$?
if [[ "$code" -eq 0 && "$out" == "OK: no checkable state or content claims detected" ]]; then
  ok "an ordinary claim-free dispatch prompt passes untouched"
else
  bad "claim-free prompt: got exit=$code out='$out' (expected 0 + the no-claims OK line)"
fi

# --- (11) missing prompt file fails closed at exit 2 ----------------------
out="$(bash "$script" --repo mattsears18/lightwork "$tmproot/nope.md" 2>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "INDETERMINATE: prompt file not found" <<<"$out"; then
  ok "missing prompt file: exit 2 + INDETERMINATE (fails closed)"
else
  bad "missing prompt file: got exit=$code out='$out' (expected 2)"
fi

# --- (12) usage errors exit 64; -h/--help exits 0 (issue #1550) -----------
bash "$script" >/dev/null 2>&1
code=$?
if [[ "$code" -eq 64 ]]; then
  ok "no arguments: exit 64"
else
  bad "no arguments: got exit=$code (expected 64)"
fi

out_stderr="$(bash "$script" --help 2>&1 1>/dev/null)"
code=$?
if [[ "$code" -eq 0 ]] && grep -qF "verify-dispatch-claims.sh" <<<"$out_stderr$(bash "$script" --help 2>/dev/null)"; then
  ok "--help exits 0 and prints usage"
else
  bad "--help: got exit=$code (expected 0 + usage text)"
fi

bash "$script" -h >/dev/null 2>&1
code=$?
if [[ "$code" -eq 0 ]]; then
  ok "-h exits 0"
else
  bad "-h: got exit=$code (expected 0)"
fi

# --- (13) the orchestrator spec actually wires this script in -------------
dispatch_rules="$here/../../commands/do-work/dispatch-rules.md"
if grep -qF "verify-dispatch-claims.sh" "$dispatch_rules"; then
  ok "dispatch-rules.md wires the gate in at the composition site"
else
  bad "dispatch-rules.md does not reference verify-dispatch-claims.sh"
fi
if grep -qF "1553" "$dispatch_rules"; then
  ok "dispatch-rules.md cites issue #1553 for the gate's provenance"
else
  bad "dispatch-rules.md does not cite #1553"
fi

# --- (14) shellcheck-clean -------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$script" >"$tmproot/shellcheck.out" 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported issues: $(cat "$tmproot/shellcheck.out")"
  fi
else
  echo "  (shellcheck not installed locally — skipping; CI's shellcheck.yml still gates this)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
