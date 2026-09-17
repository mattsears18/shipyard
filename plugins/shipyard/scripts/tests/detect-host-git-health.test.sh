#!/usr/bin/env bash
# Test suite for scripts/detect-host-git-health.sh (issue #1567).
#
# Covers the setup-time host-git preflight this script backs: classify whether
# this host's system `git` is usable by the HARNESS ITSELF, so `/shipyard:do-work`
# stops at step 0.2 instead of discovering at step 7 that no worker can be
# dispatched.
#
# The failing host state (macOS + `xcode-select -p` pointing at Xcode.app + an
# unaccepted Xcode license) CANNOT be reproduced on a host that has since
# accepted the license, and accepting/unaccepting it is a `sudo` host mutation
# no test may perform. So the suite drives the classifier two ways, neither of
# which needs a genuinely broken host:
#
#   1. `--decide` — pure classification of recorded (exit code, stderr) pairs,
#      using the verbatim error text captured in #1567's repro.
#   2. Live mode against a STUBBED git binary (SHIPYARD_GIT_BIN), which
#      reproduces the failing host's observable behavior exactly: non-zero exit
#      plus the license message on stderr.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-host-git-health.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../detect-host-git-health.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    bad "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
  fi
}

# The verbatim message `/usr/bin/git` emits on a host whose Xcode license has
# not been accepted (#1567's repro).
LICENSE_ERR="You have not agreed to the Xcode license agreements. You must agree to both license agreements below in order to use Xcode."
# The shape the EnterWorktree path-form recovery surfaced it in.
WORKTREE_LIST_ERR="\`git -C /Users/x/code/shipyard worktree list\` failed: You have not agreed to the Xcode license agreements"
# The shape the xcrun shim wraps it in.
XCRUN_ERR="xcrun: error: Failed to locate 'git'. Agreeing to the Xcode/iOS license requires admin privileges."

echo "detect-host-git-health: host-git preflight classifier (issue #1567)"
echo

# --- 1. --decide: pure classification -------------------------------------
echo "1. --decide classification"

assert_equals "$(bash "$helper" --decide 0 "" 0 "")" "healthy" \
  "both probes succeed -> healthy"

assert_equals "$(bash "$helper" --decide 1 "$LICENSE_ERR")" "xcode-license" \
  "git --version fails with the verbatim license message -> xcode-license"

assert_equals "$(bash "$helper" --decide 69 "$XCRUN_ERR")" "xcode-license" \
  "xcrun shim wrapper form -> xcode-license"

assert_equals "$(bash "$helper" --decide 0 "" 128 "$WORKTREE_LIST_ERR")" "xcode-license" \
  "--version ok but a repo op fails on the license -> xcode-license (NOT not-a-repo)"

assert_equals "$(bash "$helper" --decide 0 "" 128 "fatal: not a git repository (or any of the parent directories): .git")" "not-a-repo" \
  "--version ok, rev-parse says not a repo -> not-a-repo"

assert_equals "$(bash "$helper" --decide 127 "bash: git: command not found")" "git-unusable" \
  "git missing entirely -> git-unusable"

assert_equals "$(bash "$helper" --decide 0 "" 128 "fatal: detected dubious ownership in repository")" "git-unusable" \
  "--version ok, rev-parse fails for an unclassified reason -> git-unusable"

# Case-insensitivity: the message's capitalization must not be load-bearing.
assert_equals "$(bash "$helper" --decide 1 "you have not AGREED TO THE XCODE LICENSE agreements")" "xcode-license" \
  "license detection is case-insensitive"

echo

# --- 2. Exit codes ---------------------------------------------------------
echo "2. exit codes"

rc="$(bash "$helper" --decide 0 "" 0 "" >/dev/null 2>&1; echo $?)"
assert_equals "$rc" "0" "--decide itself always exits 0 (it is a classifier, not a gate)"

# The gate semantics live in live mode, exercised in section 3.

echo

# --- 3. Live mode against a stubbed git ------------------------------------
echo "3. live mode with a stubbed git (SHIPYARD_GIT_BIN)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stub that reproduces the broken host: every invocation fails with the
# license message on stderr, exactly as /usr/bin/git does there.
broken_git="$work/broken-git"
cat > "$broken_git" <<FIXTURE
#!/usr/bin/env bash
echo "$LICENSE_ERR" >&2
exit 69
FIXTURE
chmod +x "$broken_git"

out="$(SHIPYARD_GIT_BIN="$broken_git" bash "$helper" 2>/dev/null)"
rc=$?
assert_equals "$out" "verdict=xcode-license" "broken-host stub -> verdict=xcode-license on stdout"
assert_equals "$rc" "1" "broken-host stub -> exit 1 (a gate, not an advisory)"

err="$(SHIPYARD_GIT_BIN="$broken_git" bash "$helper" 2>&1 >/dev/null)"
assert_contains "$err" "sudo xcodebuild -license accept" \
  "remediation names \`sudo xcodebuild -license accept\`"
assert_contains "$err" "sudo xcode-select -s /Library/Developer/CommandLineTools" \
  "remediation names the xcode-select alternative"
assert_contains "$err" "DEVELOPER_DIR" \
  "remediation explains why a DEVELOPER_DIR shell prefix does not fix it"
assert_contains "$err" "#1567" \
  "remediation cites the issue"

# A stub that works: proves the gate is not trivially red.
ok_git="$work/ok-git"
cat > "$ok_git" <<'FIXTURE'
#!/usr/bin/env bash
case "$1" in
  --version) echo "git version 2.99.0"; exit 0 ;;
  rev-parse) echo "/tmp/some/repo"; exit 0 ;;
esac
exit 0
FIXTURE
chmod +x "$ok_git"

out_ok="$(SHIPYARD_GIT_BIN="$ok_git" bash "$helper" 2>/dev/null)"
rc_ok=$?
assert_equals "$out_ok" "verdict=healthy" "working stub -> verdict=healthy"
assert_equals "$rc_ok" "0" "working stub -> exit 0"

# A stub that is missing entirely (bad path) must not be laundered as healthy.
out_missing="$(SHIPYARD_GIT_BIN="$work/does-not-exist" bash "$helper" 2>/dev/null)"
rc_missing=$?
assert_equals "$out_missing" "verdict=git-unusable" "nonexistent git binary -> verdict=git-unusable"
assert_equals "$rc_missing" "1" "nonexistent git binary -> exit 1"

echo

# --- 4. DEVELOPER_DIR must not mask the failure ----------------------------
echo "4. DEVELOPER_DIR masking"

# The whole point of the preflight: an orchestrator that already worked around
# a broken host by exporting DEVELOPER_DIR must still get the failing verdict,
# because the HARNESS's own git calls never see that variable. The stub records
# whether DEVELOPER_DIR reached it.
recorder="$work/recorder-git"
cat > "$recorder" <<FIXTURE
#!/usr/bin/env bash
if [[ -n "\${DEVELOPER_DIR:-}" ]]; then
  echo "DEVELOPER_DIR_LEAKED=\$DEVELOPER_DIR" >> "$work/leak.log"
  # A "workaround-ed" git succeeds when DEVELOPER_DIR is set...
  exit 0
fi
# ...and fails the way the real broken host does when it is not.
echo "$LICENSE_ERR" >&2
exit 69
FIXTURE
chmod +x "$recorder"

out_mask="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools SHIPYARD_GIT_BIN="$recorder" bash "$helper" 2>/dev/null)"
assert_equals "$out_mask" "verdict=xcode-license" \
  "an exported DEVELOPER_DIR does NOT mask the broken host (probe runs with env -u)"

if [[ -f "$work/leak.log" ]]; then
  bad "DEVELOPER_DIR leaked into the probe: $(cat "$work/leak.log")"
else
  ok "DEVELOPER_DIR never reached the probed git binary"
fi

echo

# --- 5. Usage / help contract ---------------------------------------------
echo "5. usage + help"

rc_help="$(bash "$helper" --help </dev/null >/dev/null 2>&1; echo $?)"
assert_equals "$rc_help" "0" "--help exits 0 (#1550 convention)"

rc_h="$(bash "$helper" -h </dev/null >/dev/null 2>&1; echo $?)"
assert_equals "$rc_h" "0" "-h exits 0 (#1550 convention)"

usage_out="$(bash "$helper" --help </dev/null 2>&1)"
assert_contains "$usage_out" "--decide" "usage() documents --decide"

bogus_out="$(bash "$helper" --repo mattsears18/shipyard </dev/null 2>/dev/null)"
rc_bogus="$(bash "$helper" --repo mattsears18/shipyard </dev/null >/dev/null 2>&1; echo $?)"
assert_contains "$bogus_out" "USAGE_ERROR:" "an unrecognized flag reports USAGE_ERROR on stdout"
assert_equals "$rc_bogus" "64" "an unrecognized flag exits 64 (EX_USAGE)"

rc_short="$(bash "$helper" --decide 1 </dev/null >/dev/null 2>&1; echo $?)"
assert_equals "$rc_short" "64" "--decide with too few arguments exits 64"

echo

# --- 6. Spec wiring --------------------------------------------------------
echo "6. spec wiring"

# Content reads scan ACROSS setup/*.md rather than pinning today's fragment
# filename (scripts/setup-fragment-content-scan.sh, #1453) — a future
# router/fragment split could relocate step 0.2 into a different fragment, and
# an assertion pinned to `00-config-worktree.md` would then break in CI with no
# local warning.
setup_dir="${here}/../../commands/do-work/setup"
if [[ ! -d "$setup_dir" ]]; then
  bad "setup fragment dir not found at $setup_dir"
else
  setup_corpus="$(cat "$setup_dir"/*.md)"
  assert_contains "$setup_corpus" "detect-host-git-health.sh" \
    "a setup fragment invokes the preflight script"
  assert_contains "$setup_corpus" "### 0.2 " \
    "a setup fragment carries a step 0.2 heading"
  assert_contains "$setup_corpus" "sudo xcodebuild -license accept" \
    "setup prose names the remediation command"
  assert_contains "$setup_corpus" "sudo xcode-select -s /Library/Developer/CommandLineTools" \
    "setup prose names the xcode-select alternative"

  # The preflight must run BEFORE the CLAUDE_PLUGIN_ROOT re-export preamble
  # (step 0.3) and the opt-in check (step 0.4) — the whole point is that it is
  # the FIRST thing setup does, before any cost is paid. Find whichever
  # fragment owns each heading, then compare their positions within that
  # fragment when they share one.
  owner_02="$(grep -l '^### 0\.2 ' "$setup_dir"/*.md 2>/dev/null | head -1)"
  owner_03="$(grep -l '^### 0\.3 ' "$setup_dir"/*.md 2>/dev/null | head -1)"
  if [[ -z "$owner_02" ]]; then
    bad "no setup fragment owns the '### 0.2 ' heading"
  elif [[ -z "$owner_03" ]]; then
    bad "no setup fragment owns the '### 0.3 ' heading"
  elif [[ "$owner_02" != "$owner_03" ]]; then
    # Split across fragments: setup.md's routing table orders them, so
    # co-location is no longer the thing to assert.
    ok "steps 0.2 and 0.3 live in different setup fragments — ordering is the router's job"
  else
    line_02="$(grep -n '^### 0\.2 ' "$owner_02" | head -1 | cut -d: -f1)"
    line_03="$(grep -n '^### 0\.3 ' "$owner_03" | head -1 | cut -d: -f1)"
    if [[ -n "$line_02" && -n "$line_03" && "$line_02" -lt "$line_03" ]]; then
      ok "step 0.2 is ordered before step 0.3 in $(basename "$owner_02")"
    else
      bad "step 0.2 must precede step 0.3 (got 0.2 at line '${line_02:-none}', 0.3 at line '${line_03:-none}')"
    fi
  fi
fi

# setup.md is the ROUTER, not a setup/*.md fragment — reading it by name is
# exactly what #1453's scanner prescribes as the alternative to a hardcoded
# fragment read, so this one is deliberate.
router="${here}/../../commands/do-work/setup.md"
if [[ ! -f "$router" ]]; then
  bad "router not found at $router"
else
  assert_contains "$(cat "$router")" "0.2" \
    "setup.md's router row advertises the new first step"
fi

echo
echo "-----------------------------------------"

# --- NEGATIVE CONTROL ------------------------------------------------------
# A classifier that returned "healthy" for the broken host would make every
# assertion above vacuous. Plant that mutant and prove the suite catches it.
mutant="$work/mutant.sh"
sed 's/^      echo "xcode-license"$/      echo "healthy"/' "$helper" > "$mutant"
mutant_verdict="$(bash "$mutant" --decide 1 "$LICENSE_ERR" 2>/dev/null)"
if [[ "$mutant_verdict" != "xcode-license" ]]; then
  ok "negative control: a classifier mutated to mis-report the broken host is caught (got '$mutant_verdict')"
else
  bad "negative control: the planted mutant still returned xcode-license — the sed target drifted, so this suite may be trivially passing"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
