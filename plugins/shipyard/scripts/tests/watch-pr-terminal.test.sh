#!/usr/bin/env bash
# Test: scripts/watch-pr-terminal.sh — poll a single PR to a terminal state
# (merged / closed / failing-check / timeout / error) and emit exactly one
# stdout line describing it (issue #1326).
#
# Background
# ----------
# drain.md's end-of-session drain is specified as a poll loop, but a poll
# loop can't be expressed as an inline post-relocation Bash command (see
# dont.md's "Post-relocation Bash blocks must be plain, single-purpose
# commands", issue #1277) — the worktree-isolation guard refuses a `while`/
# `for` loop wrapping `gh`/`git` calls, and its own remedy ("break it into
# plain, separate commands") doesn't work for an unbounded poll. This script
# is the extract-to-a-script fix for the single-PR watch case: the loop lives
# once, in this file, and every caller invokes it as ONE plain command.
#
# This test exercises the script directly against a fully mocked `gh`
# binary on PATH — no network, no real repo. Run with:
#
#   bash plugins/shipyard/scripts/tests/watch-pr-terminal.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../watch-pr-terminal.sh"

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
DRAIN_MD="$repo_root/plugins/shipyard/commands/do-work/drain.md"

echo "watch-pr-terminal.sh tests (issue #1326)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$label (got [$actual])"
  else
    bad "$label (expected [$expected], got [$actual])"
  fi
}

assert_contains_line() {
  local label="$1" haystack="$2" needle="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    ok "$label"
  else
    bad "$label"
    printf '    expected stdout to contain: %s\n    got: %s\n' "$needle" "$haystack"
  fi
}

# Matches the stdout line's fixed structure while tolerating the `elapsed=Ns`
# field varying by a second or two (process-spawn overhead across the gh/jq
# calls this test's fake `gh` and the real `jq` binary both add) — an exact
# string match on `elapsed=0s` is a flaky assertion on a loaded CI runner.
assert_matches() {
  local label="$1" expected_pattern="$2" actual="$3"
  if [[ "$actual" =~ $expected_pattern ]]; then
    ok "$label (got [$actual])"
  else
    bad "$label (expected to match [$expected_pattern], got [$actual])"
  fi
}

# ---------------------------------------------------------------------------
# (A) --help — prints usage, exit 0 (issue #1550: --help is a correct,
# intentional invocation, distinct from the `error` exit 4 every other usage
# failure below uses), no gh/jq required.
# ---------------------------------------------------------------------------
echo "(A) --help"
help_out="$(PATH="/usr/bin:/bin" bash "$script" --help 2>&1)"
help_exit=$?
assert_equals "--help exit code" "0" "$help_exit"
assert_contains_line "--help documents --pr/--repo as required" "$help_out" "--pr <N>"

PATH="/usr/bin:/bin" bash "$script" -h >/dev/null 2>&1
h_exit=$?
assert_equals "-h exit code" "0" "$h_exit"
echo

# ---------------------------------------------------------------------------
# (B) Usage errors — missing/invalid arguments never touch gh at all.
# ---------------------------------------------------------------------------
echo "(B) usage errors (no PATH tools needed — argument parsing fails first)"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo 2>&1)"
code=$?
assert_equals "missing --pr: exit code" "4" "$code"
assert_contains_line "missing --pr: names the missing flag" "$out" "--pr and --repo are both required"

out="$(PATH="/usr/bin:/bin" bash "$script" --pr 12 2>&1)"
code=$?
assert_equals "missing --repo: exit code" "4" "$code"

out="$(PATH="/usr/bin:/bin" bash "$script" --pr abc --repo owner/repo 2>&1)"
code=$?
assert_equals "non-numeric --pr: exit code" "4" "$code"
assert_contains_line "non-numeric --pr: diagnostic names the bad value" "$out" "must be a positive integer"

out="$(PATH="/usr/bin:/bin" bash "$script" --pr 12 --repo owner/repo --interval nope 2>&1)"
code=$?
assert_equals "non-numeric --interval: exit code" "4" "$code"

out="$(PATH="/usr/bin:/bin" bash "$script" --pr 12 --repo owner/repo --max-wait -1 2>&1)"
code=$?
assert_equals "negative --max-wait: exit code" "4" "$code"
echo

# ---------------------------------------------------------------------------
# (C) gh CLI missing from PATH -> error terminal state, not a crash.
#
# A hardcoded "/usr/bin:/bin" here is not portable: some environments (e.g.
# GitHub Actions' hosted Ubuntu runner image) ship `gh` pre-installed at
# /usr/bin/gh, so a PATH of "/usr/bin:/bin" would still resolve `gh` and the
# script would never hit its "not found" branch at all — a false FAIL that
# has nothing to do with the script's actual (correct) `command -v gh`
# check. Build the test PATH from the REAL $PATH with every directory that
# actually contains a `gh` executable filtered out, so standard utilities
# (bash, coreutils, etc.) stay reachable but `gh` specifically never
# resolves, regardless of which directory this host happens to install it
# in. Critically, capture the absolute path to bash BEFORE filtering PATH
# (on CI, bash and gh are co-located in /usr/bin, so filtering by gh name
# would drop bash too). Invoke bash via its absolute path with the narrowed
# PATH only in the child's environment.
# ---------------------------------------------------------------------------
echo "(C) gh CLI not on PATH"
bash_path="$(command -v bash)"
emptybin="$(mktemp -d)"
no_gh_path="$emptybin"
IFS=':' read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -n "$d" && -x "$d/gh" ]] && continue
  no_gh_path="$no_gh_path:$d"
done
out="$(PATH="$no_gh_path" "$bash_path" "$script" --pr 5 --repo owner/repo 2>&1)"
code=$?
rm -rf "$emptybin"
assert_equals "gh missing: exit code" "4" "$code"
assert_contains_line "gh missing: stdout names the reason" "$out" "watch-pr-terminal: error pr=5 repo=owner/repo reason=\"gh CLI not found on PATH\""
echo

# ---------------------------------------------------------------------------
# Helper: build a fake `gh` on a throwaway PATH directory that always
# returns a fixed `gh pr view` JSON payload.
# ---------------------------------------------------------------------------
make_fake_gh() {
  local dir="$1" json="$2"
  cat > "$dir/gh" <<FAKEGH
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  cat <<'PRJSON'
$json
PRJSON
  exit 0
fi
exit 1
FAKEGH
  chmod +x "$dir/gh"
}

# ---------------------------------------------------------------------------
# (D) Merged state -> exit 0, one "merged" line.
# ---------------------------------------------------------------------------
echo "(D) merged state"
fakebin="$(mktemp -d)"
make_fake_gh "$fakebin" '{"state":"MERGED","statusCheckRollup":[]}'
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 42 --repo owner/repo --interval 1 --max-wait 5 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "merged: exit code" "0" "$code"
assert_matches "merged: stdout" '^watch-pr-terminal: merged pr=42 repo=owner/repo elapsed=[0-9]+s$' "$out"
echo

# ---------------------------------------------------------------------------
# (E) Closed (not merged) state -> exit 3.
# ---------------------------------------------------------------------------
echo "(E) closed (not merged) state"
fakebin="$(mktemp -d)"
make_fake_gh "$fakebin" '{"state":"CLOSED","statusCheckRollup":[]}'
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 43 --repo owner/repo --interval 1 --max-wait 5 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "closed: exit code" "3" "$code"
assert_matches "closed: stdout" '^watch-pr-terminal: closed pr=43 repo=owner/repo elapsed=[0-9]+s$' "$out"
echo

# ---------------------------------------------------------------------------
# (F) Failing check -> exit 2, and the latest-per-check-name dedup correctly
#     ignores a stale FAILURE superseded by a later SUCCESS on the SAME
#     check name (mirrors drain.md's own R_new/D_dirty_red rollup dedup,
#     issue #333) while still catching a genuinely-latest failure on a
#     DIFFERENT check.
# ---------------------------------------------------------------------------
echo "(F) failing check (with a stale-superseded entry that must NOT trip it)"
fakebin="$(mktemp -d)"
make_fake_gh "$fakebin" '{"state":"OPEN","statusCheckRollup":[
  {"name":"Unit Tests","conclusion":"FAILURE","completedAt":"2026-08-13T00:00:00Z"},
  {"name":"Unit Tests","conclusion":"SUCCESS","completedAt":"2026-08-13T00:01:00Z"},
  {"name":"Lint","conclusion":"FAILURE","completedAt":"2026-08-13T00:00:00Z"}
]}'
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 44 --repo owner/repo --interval 1 --max-wait 5 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "failing: exit code" "2" "$code"
assert_contains_line "failing: reports the still-failing check (Lint), not the superseded one" "$out" 'check="Lint"'
if grep -qF 'check="Unit Tests"' <<<"$out"; then
  bad "failing: does NOT report the stale-superseded check as failing"
else
  ok "failing: does NOT report the stale-superseded check as failing"
fi
echo

# ---------------------------------------------------------------------------
# (G) An all-green rollup with a still-OPEN PR never trips "failing".
# ---------------------------------------------------------------------------
echo "(G) all-green rollup, still open -> times out, never reports failing"
fakebin="$(mktemp -d)"
make_fake_gh "$fakebin" '{"state":"OPEN","statusCheckRollup":[{"name":"Unit Tests","conclusion":"SUCCESS","completedAt":"2026-08-13T00:00:00Z"}]}'
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 45 --repo owner/repo --interval 1 --max-wait 0 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "all-green-open: exit code (timeout, not failing)" "1" "$code"
assert_matches "all-green-open: stdout" '^watch-pr-terminal: timeout pr=45 repo=owner/repo elapsed=[0-9]+s max_wait=0s$' "$out"
echo

# ---------------------------------------------------------------------------
# (H) Timeout — max-wait 0 forces exactly one poll then a timeout line.
# ---------------------------------------------------------------------------
echo "(H) timeout (max-wait 0 — exactly one poll, no real sleep)"
fakebin="$(mktemp -d)"
make_fake_gh "$fakebin" '{"state":"OPEN","statusCheckRollup":[]}'
start_ts=$(date +%s)
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 46 --repo owner/repo --interval 60 --max-wait 0 2>/dev/null)"
code=$?
end_ts=$(date +%s)
rm -rf "$fakebin"
assert_equals "timeout: exit code" "1" "$code"
assert_matches "timeout: stdout" '^watch-pr-terminal: timeout pr=46 repo=owner/repo elapsed=[0-9]+s max_wait=0s$' "$out"
elapsed_wall=$((end_ts - start_ts))
if [[ "$elapsed_wall" -lt 5 ]]; then
  ok "timeout: returned quickly ($elapsed_wall s) — never slept despite --interval 60"
else
  bad "timeout: took ${elapsed_wall}s — should return near-instantly with max-wait 0"
fi
echo

# ---------------------------------------------------------------------------
# (I) gh transient failure then recovery — a single failed poll is retried,
#     not treated as terminal.
# ---------------------------------------------------------------------------
echo "(I) gh fails once, then succeeds — retried, not fatal"
fakebin="$(mktemp -d)"
counter_file="$fakebin/count"
echo 0 > "$counter_file"
cat > "$fakebin/gh" <<FAKEGH
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  n=\$(cat "$counter_file")
  n=\$((n + 1))
  echo "\$n" > "$counter_file"
  if [[ "\$n" -eq 1 ]]; then
    echo "transient network error" >&2
    exit 1
  fi
  echo '{"state":"MERGED","statusCheckRollup":[]}'
  exit 0
fi
exit 1
FAKEGH
chmod +x "$fakebin/gh"
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 47 --repo owner/repo --interval 0 --max-wait 5 2>/dev/null)"
code=$?
attempts="$(cat "$counter_file")"
rm -rf "$fakebin"
assert_equals "transient-then-recover: exit code" "0" "$code"
assert_matches "transient-then-recover: stdout" '^watch-pr-terminal: merged pr=47 repo=owner/repo elapsed=[0-9]+s$' "$out"
assert_equals "transient-then-recover: gh was called twice (1 failure + 1 success)" "2" "$attempts"
echo

# ---------------------------------------------------------------------------
# (J) gh fails 3 consecutive times -> error terminal state, not an infinite
#     retry.
# ---------------------------------------------------------------------------
echo "(J) gh fails 3 consecutive times -> error, bounded retries"
fakebin="$(mktemp -d)"
cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "persistent failure" >&2
  exit 1
fi
exit 1
FAKEGH
chmod +x "$fakebin/gh"
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --pr 48 --repo owner/repo --interval 0 --max-wait 5 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "persistent failure: exit code" "4" "$code"
assert_contains_line "persistent failure: stdout names the retry count" "$out" "gh pr view failed 3 consecutive times"
echo

# ---------------------------------------------------------------------------
# (K) drain.md — the "Worktree-safe polling pattern" section exists, points
#     at this script as the preferred path, states the loop-can't-be-inline
#     rule, cross-references dont.md and the harness isolation docs, and
#     explicitly rejects an out-of-worktree scratch location.
# ---------------------------------------------------------------------------
echo "(K) drain.md — worktree-safe polling pattern section"
if [[ -f "$DRAIN_MD" ]]; then
  ok "drain.md exists"
  assert_contains_line "drain.md has a 'Worktree-safe polling pattern' heading" \
    "$(cat "$DRAIN_MD")" "Worktree-safe polling pattern"
  assert_contains_line "drain.md points at watch-pr-terminal.sh as the preferred helper" \
    "$(cat "$DRAIN_MD")" "watch-pr-terminal.sh"
  assert_contains_line "drain.md cross-references dont.md's compound-block rule" \
    "$(cat "$DRAIN_MD")" "dont.md#post-relocation-bash-command-shape--measurements-retired-2026-09-30"
  assert_contains_line "drain.md cross-references the harness command-shape docs" \
    "$(cat "$DRAIN_MD")" "code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation"
  assert_contains_line "drain.md states the worktree-local scratch convention (not the job/session temp dir)" \
    "$(cat "$DRAIN_MD")" ".shipyard-scratch-"

  # Ordering: the new heading must appear before "### Pre-dispatch head-branch reap"
  # (i.e. it's foundational guidance introduced ahead of the mechanics that use it).
  section_line="$(grep -n '^### Worktree-safe polling pattern' "$DRAIN_MD" | head -1 | cut -d: -f1)"
  reap_line="$(grep -n '^### Pre-dispatch head-branch reap' "$DRAIN_MD" | head -1 | cut -d: -f1)"
  if [[ -n "$section_line" && -n "$reap_line" && "$section_line" -lt "$reap_line" ]]; then
    ok "worktree-safe polling pattern section precedes Pre-dispatch head-branch reap (line $section_line < $reap_line)"
  else
    bad "worktree-safe polling pattern section precedes Pre-dispatch head-branch reap (section=$section_line, reap=$reap_line)"
  fi
else
  bad "drain.md exists (missing at $DRAIN_MD)"
fi
echo

# ---------------------------------------------------------------------------
echo "----------------------------------------"
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  %s test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %s test(s) failed (%s passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
fi
