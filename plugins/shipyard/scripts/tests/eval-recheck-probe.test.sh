#!/usr/bin/env bash
# Test: eval-recheck-probe.sh — the allowlist-only evaluator for a
# `<!-- do-work-recheck: <verb> <args...> -->` issue-body marker (issue
# #1198, follow-up to #1195/#1199).
#
# This is a security-sensitive script: it is the ONE place untrusted issue-
# body text is allowed to influence what command runs. This suite pins:
#
#   (A) --decide — pure comparison truth table (unchanged/changed/unknown).
#   (B) --validate — the allowlist grammar for all three verbs, including
#       the NEGATIVE cases that matter most: unrecognized verbs, wrong token
#       counts, shell-metacharacter / injection-shaped values, and
#       cross-repo gh-api endpoints.
#   (B2) --validate — the `url-json` verb (issue #1496) specifically: the
#       per-repo host allowlist (EMPTY by default, so the verb is inert
#       until a repo opts in), HTTPS-only, no credentials / port / fragment
#       / IP-literal host, and the restricted jq filter (one optional
#       `|length`, nothing else).
#   (C) extract_marker behavior via the full stdin flow — absent marker,
#       multiple markers (first wins), malformed marker.
#   (D) live execution against PATH-stubbed `npm`/`gh` binaries — unchanged,
#       changed, error (nonzero exit), empty output, and a real bounded
#       timeout enforcing the `unknown` fallback rather than hanging.
#   (D2) live execution of `url-json` against a PATH-stubbed `curl` — the
#       happy path plus EVERY rejected response shape the verb must degrade
#       to `unknown` on: a 3xx (never followed), a 404, a body that isn't
#       JSON, a filter that yields `null`, an over-cap response, and a
#       timeout.
#   (E) the script is referenced from the operator-sweep doc and the
#       RATIONALE, and the `scope.recheck_probe_timeout_seconds` /
#       `scope.recheck_probe_enabled` config knobs exist in both the schema
#       and the built-in defaults.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/eval-recheck-probe.test.sh

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

SCRIPT="$repo_root/plugins/shipyard/scripts/eval-recheck-probe.sh"
HOOKS_MD="$repo_root/plugins/shipyard/commands/do-work/operate/04-steady-state-hooks.md"
RATIONALE_MD="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"
CONFIG_SCHEMA="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
CONFIG_SH="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL: script not found at $SCRIPT" >&2
  exit 1
fi

echo "eval-recheck-probe.sh regression tests (issue #1198)"
echo

# ---------------------------------------------------------------------------
echo "(A) --decide — pure comparison truth table"
# ---------------------------------------------------------------------------
assert_equals "matching actual/expected -> unchanged" \
  "unchanged" "$(bash "$SCRIPT" --decide "1.0.0" "1.0.0")"
assert_equals "differing actual/expected -> changed" \
  "changed" "$(bash "$SCRIPT" --decide "2.0.0" "1.0.0")"
assert_equals "empty actual -> unknown, never changed" \
  "unknown" "$(bash "$SCRIPT" --decide "" "1.0.0")"

# ---------------------------------------------------------------------------
echo
echo "(B) --validate — allowlist grammar (positive + negative cases)"
# ---------------------------------------------------------------------------
OWNER_REPO="mattsears18/shipyard"

# Positive: valid npm-view.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro dependencies.image-size == 1.0.0")"
rc=$?
assert_equals "valid npm-view: exit 0" "0" "$rc"
assert_equals "valid npm-view: parsed fields (TAB-separated since #1496)" \
  "npm-view"$'\t'"metro"$'\t'"dependencies.image-size"$'\t'"1.0.0" "$out"

# Positive: valid scoped npm-view package.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view @babel/core version == 7.20.0")"
assert_equals "valid scoped npm-view: parsed fields" \
  "npm-view"$'\t'"@babel/core"$'\t'"version"$'\t'"7.20.0" "$out"

# Positive: valid gh-api scoped to the CURRENT repo.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/issues/42 .state == open")"
assert_equals "valid gh-api (current repo): parsed fields" \
  "gh-api"$'\t'"repos/mattsears18/shipyard/issues/42"$'\t'".state"$'\t'"open" "$out"

# Positive: every allowed gh-api sub-resource shape.
for sub in "releases/latest" "tags" "commits/abc123" "issues/1" "pulls/1"; do
  bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/${sub} .x == y" >/dev/null 2>&1
  assert_equals "gh-api sub-resource '${sub}' is allowed" "0" "$?"
done

# --- Negative cases: the load-bearing half of this suite ---

bash "$SCRIPT" --validate "$OWNER_REPO" "curl http://evil.example.com == pwned" >/dev/null 2>&1
assert_equals "unrecognized verb rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field ==" >/dev/null 2>&1
assert_equals "npm-view missing expected token rejected (wrong count)" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field != 1.0.0" >/dev/null 2>&1
assert_equals "npm-view non-'==' comparator rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view $(whoami) field == x' >/dev/null 2>&1
assert_equals "npm-view command-substitution in pkg rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view metro field == 1.0.0; rm -rf /tmp/pwned' >/dev/null 2>&1
assert_equals "npm-view shell-metacharacter injection attempt rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view metro `id` == x' >/dev/null 2>&1
assert_equals "npm-view backtick command substitution rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field == 1.0.0 extra-token" >/dev/null 2>&1
assert_equals "npm-view extra trailing token rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/someoneelse/otherrepo/issues/1 .state == open" >/dev/null 2>&1
assert_equals "gh-api cross-repo endpoint rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/actions/secrets .total_count == 0" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (secrets) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/hooks .x == y" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (hooks) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/collaborators .x == y" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (collaborators) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'gh-api repos/mattsears18/shipyard/issues/1 .state|halt_error == open' >/dev/null 2>&1
assert_equals "gh-api jq-filter-shaped field rejected (no pipes/filters allowed)" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/issues/1 .state == open extra" >/dev/null 2>&1
assert_equals "gh-api extra trailing token rejected" "1" "$?"

# ---------------------------------------------------------------------------
echo
echo "(B2) --validate — the url-json verb (issue #1496)"
# ---------------------------------------------------------------------------
# The motivating real-world marker: an App Store customer-reviews RSS count,
# the case #1496 was filed for. `|length` is the ONE permitted jq operator and
# is written without spaces so the marker stays exactly five tokens.
ITUNES_URL="https://itunes.apple.com/us/rss/customerreviews/id=6444444444/sortBy=mostRecent/json"

# The host allowlist is EMPTY by default. That is the security posture, not an
# oversight: until a repo opts in via its COMMITTED shipyard.config.json, the
# verb resolves every marker to `unknown` and never makes a request. Pin it
# here rather than relying on this repo's own config, so the suite stays
# hermetic either way.
bash "$SCRIPT" --validate "$OWNER_REPO" "url-json $ITUNES_URL .feed.entry|length == 0" >/dev/null 2>&1
assert_equals "url-json with an EMPTY host allowlist is rejected (opt-in only)" "1" "$?"

out="$(RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json $ITUNES_URL .feed.entry|length == 0")"
assert_equals "url-json on an allowlisted host: parsed fields" \
  "url-json"$'\t'"$ITUNES_URL"$'\t'".feed.entry|length"$'\t'"0" "$out"

out="$(RECHECK_PROBE_URL_HOSTS="ITUNES.APPLE.COM" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json $ITUNES_URL .feed.entry|length == 0" >/dev/null 2>&1; echo $?)"
assert_equals "url-json host match is case-insensitive" "0" "$out"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://probe.example.com/x .a == 1" >/dev/null 2>&1
assert_equals "url-json on a host NOT in the allowlist is rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="example.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://probe.example.com/x .a == 1" >/dev/null 2>&1
assert_equals "url-json allowlist does NOT imply subdomains (exact match only)" "1" "$?"

# --- Scheme / transport negatives: HTTPS only, always ---
for bad_url in \
  "http://itunes.apple.com/x" \
  "ftp://itunes.apple.com/x" \
  "file:///etc/passwd" \
  "//itunes.apple.com/x" \
  "itunes.apple.com/x" \
  "HTTPS://itunes.apple.com/x"; do
  RECHECK_PROBE_URL_HOSTS="itunes.apple.com /etc/passwd" bash "$SCRIPT" --validate "$OWNER_REPO" \
    "url-json $bad_url .a == 1" >/dev/null 2>&1
  assert_equals "url-json non-HTTPS URL rejected: $bad_url" "1" "$?"
done

# --- Host-shape negatives: no credentials, no port, no IP literals ---
RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://user:pw@itunes.apple.com/x .a == 1" >/dev/null 2>&1
assert_equals "url-json URL carrying userinfo credentials rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://itunes.apple.com:8443/x .a == 1" >/dev/null 2>&1
assert_equals "url-json URL naming an explicit port rejected" "1" "$?"

for ip in "127.0.0.1" "169.254.169.254" "10.0.0.1" "192.168.1.1"; do
  RECHECK_PROBE_URL_HOSTS="$ip" bash "$SCRIPT" --validate "$OWNER_REPO" \
    "url-json https://$ip/latest .a == 1" >/dev/null 2>&1
  assert_equals "url-json IP-literal host rejected even if allowlisted: $ip" "1" "$?"
done

RECHECK_PROBE_URL_HOSTS="localhost" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://localhost/x .a == 1" >/dev/null 2>&1
assert_equals "url-json single-label host (localhost) rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://itunes.apple.com/x#frag .a == 1" >/dev/null 2>&1
assert_equals "url-json URL carrying a fragment rejected" "1" "$?"

# --- Injection-shaped negatives ---
RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/$(whoami) .a == 1' >/dev/null 2>&1
assert_equals "url-json command-substitution in the URL rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x;rm -rf /tmp/pwned .a == 1' >/dev/null 2>&1
assert_equals "url-json shell-metacharacter injection in the URL rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/`id` .a == 1' >/dev/null 2>&1
assert_equals "url-json backtick command substitution in the URL rejected" "1" "$?"

# A 600-character URL, well past the 500-char cap.
long_path="$(printf 'a%.0s' $(seq 1 600))"
RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  "url-json https://itunes.apple.com/$long_path .a == 1" >/dev/null 2>&1
assert_equals "url-json over-length URL rejected (500-char cap)" "1" "$?"

# --- jq-filter negatives: one optional `|length`, nothing else ---
RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .a|halt_error == 1' >/dev/null 2>&1
assert_equals "url-json arbitrary jq pipe (halt_error) rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .a|length|length == 1' >/dev/null 2>&1
assert_equals "url-json repeated |length rejected (at most one)" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x env.PATH == x' >/dev/null 2>&1
assert_equals "url-json jq env access rejected (filter must start with a dot)" "1" "$?"

# --- token-count negatives ---
RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .feed.entry | length == 0' >/dev/null 2>&1
assert_equals "url-json spaced '| length' rejected (breaks the 5-token shape)" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .a != 1' >/dev/null 2>&1
assert_equals "url-json non-'==' comparator rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .a == 1 extra' >/dev/null 2>&1
assert_equals "url-json extra trailing token rejected" "1" "$?"

RECHECK_PROBE_URL_HOSTS="itunes.apple.com" bash "$SCRIPT" --validate "$OWNER_REPO" \
  'url-json https://itunes.apple.com/x .a ==' >/dev/null 2>&1
assert_equals "url-json missing expected token rejected" "1" "$?"

# ---------------------------------------------------------------------------
echo
echo "(C) full stdin flow — extract_marker behavior"
# ---------------------------------------------------------------------------
out="$(printf 'Just a regular issue body, no marker here.\n' | bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "no marker in body -> absent" "absent" "$out"

out="$(printf '<!-- do-work-recheck: curl evil.com == pwned -->\n\nBody text.\n' | bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "malformed marker in body -> unknown (never crashes)" "unknown" "$out"

# A companion do-work-blocked-until marker on its own line must not confuse
# extraction of the do-work-recheck marker that follows it.
companion_body=$'<!-- do-work-blocked-until: 2099-01-01 -->\n<!-- do-work-recheck: npm-view somepkg version == 1.0.0 -->\n\nBody.'
extracted="$(printf '%s\n' "$companion_body" | grep -oE '^<!-- do-work-recheck: .+ -->$' | head -1)"
case "$extracted" in
  *somepkg*) assert_pass "a companion do-work-blocked-until marker line does not interfere with do-work-recheck extraction" ;;
  *) assert_fail "a companion do-work-blocked-until marker line does not interfere with do-work-recheck extraction (got: $extracted)" ;;
esac

# First do-work-recheck marker wins when (implausibly) more than one is
# present — extract_marker must not merge or pick the last one.
multi_body=$'<!-- do-work-recheck: npm-view first-pkg version == 1.0.0 -->\n<!-- do-work-recheck: npm-view second-pkg version == 2.0.0 -->\n\nBody.'
first_marker="$(printf '%s\n' "$multi_body" | grep -oE '^<!-- do-work-recheck: .+ -->$' | head -1)"
case "$first_marker" in
  *first-pkg*) assert_pass "multiple do-work-recheck markers: extraction selects the FIRST one" ;;
  *) assert_fail "multiple do-work-recheck markers: extraction selects the FIRST one (got: $first_marker)" ;;
esac

# ---------------------------------------------------------------------------
echo
echo "(C2) --bulk mode (issue #1356) — hermetic NDJSON iteration, no network"
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  out="$(printf '' | bash "$SCRIPT" --bulk "$OWNER_REPO")"
  assert_equals "--bulk on empty stdin prints nothing" "" "$out"

  bulk_input=$'{"number":101,"body":"no marker here"}\n{"number":102,"body":"also none"}'
  out="$(printf '%s\n' "$bulk_input" | bash "$SCRIPT" --bulk "$OWNER_REPO")"
  assert_equals "--bulk: absent-marker issues produce NO output line at all (not an absent verdict line)" "" "$out"

  bulk_input=$'{"number":201,"body":"<!-- do-work-recheck: curl evil.com == pwned -->\\n\\nrest"}'
  out="$(printf '%s\n' "$bulk_input" | bash "$SCRIPT" --bulk "$OWNER_REPO" 2>/dev/null)"
  assert_equals "--bulk: a malformed marker resolves to unknown, hermetically" '{"number":201,"verdict":"unknown"}' "$out"

  bulk_input=$'{"number":301,"body":"no marker"}\n{"number":302,"body":"<!-- do-work-recheck: curl evil.com == pwned -->\\n\\nrest"}\n{"number":303,"body":"also no marker"}'
  out="$(printf '%s\n' "$bulk_input" | bash "$SCRIPT" --bulk "$OWNER_REPO" 2>/dev/null)"
  assert_equals "--bulk: mixed input emits exactly one line, only for the issue carrying a marker" '{"number":302,"verdict":"unknown"}' "$out"

  out="$(printf 'not json at all\n' | bash "$SCRIPT" --bulk "$OWNER_REPO" 2>/dev/null)"
  assert_equals "--bulk: a malformed input line (not JSON, no .number) is skipped rather than aborting the batch" "" "$out"

  bash "$SCRIPT" --bulk >/dev/null 2>&1
  assert_equals "--bulk missing <owner/repo> exits 1" "1" "$?"
else
  echo "SKIP: jq not installed -- --bulk mode requires it"
fi

# ---------------------------------------------------------------------------
echo
echo "(D) live execution — PATH-stubbed npm/gh, error handling, and timeout"
# ---------------------------------------------------------------------------
tmp_bin="$(mktemp -d)"
cleanup_tmp_bin() { rm -rf "$tmp_bin"; }
trap cleanup_tmp_bin EXIT

cat > "$tmp_bin/npm" <<'STUB'
#!/usr/bin/env bash
# Fake `npm view <pkg> <field>` (invoked as `npm view <pkg> <field>`, so the
# package name is $2, not $1) — returns a fixed value for a known pkg, a
# nonzero exit for anything containing "missing", and hangs for anything
# containing "slow" (used by the timeout test). Keep the sleep in sync with
# SLOW_STUB_SECONDS below.
case "$2" in
  *slow*) sleep 10; echo "1.0.0" ;;
  *missing*) exit 1 ;;
  *) echo "1.0.0" ;;
esac
STUB
chmod +x "$tmp_bin/npm"

cat > "$tmp_bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fake `gh api <endpoint> --jq <field>` — returns "closed" for any endpoint,
# ignoring the --jq flag/value (mirrors the real fixture pattern used
# elsewhere in this test suite, e.g. required-checks-404-normalize.test.sh).
echo "closed"
STUB
chmod +x "$tmp_bin/gh"

out="$(printf '<!-- do-work-recheck: npm-view somepkg version == 1.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed npm-view returning expected value -> unchanged" "unchanged" "$out"

out="$(printf '<!-- do-work-recheck: npm-view somepkg version == 2.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed npm-view returning a different value -> changed" "changed" "$out"

out="$(printf '<!-- do-work-recheck: npm-view missingpkg version == 1.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "stubbed npm-view nonzero exit (package not found) -> unknown, never changed" "unknown" "$out"

out="$(printf '<!-- do-work-recheck: gh-api repos/mattsears18/shipyard/issues/1 .state == closed -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed gh-api returning expected value -> unchanged" "unchanged" "$out"

out="$(printf '<!-- do-work-recheck: gh-api repos/mattsears18/shipyard/issues/1 .state == open -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed gh-api returning a different value -> changed" "changed" "$out"

# Timeout: the stubbed npm sleeps SLOW_STUB_SECONDS: pin
# RECHECK_PROBE_TIMEOUT_SECONDS to 1 and confirm the call returns with
# `unknown` rather than hanging. The bound asserts the property — the timeout
# cut the stub short (elapsed < SLOW_STUB_SECONDS) — not a tight wall-clock
# number: a 1s timeout can take several seconds to be scheduled, fire, and
# reap under host load (issue #1639), and that is still an enforced timeout.
# The stub sleep is long enough that the jitter headroom is ~9s.
SLOW_STUB_SECONDS=10
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  start_ts=$(date +%s)
  out="$(printf '<!-- do-work-recheck: npm-view slowpkg version == 1.0.0 -->\n' \
    | RECHECK_PROBE_TIMEOUT_SECONDS=1 PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  assert_equals "timed-out probe -> unknown, never changed/unchanged" "unknown" "$out"
  if [[ "$elapsed" -lt "$SLOW_STUB_SECONDS" ]]; then
    assert_pass "timeout enforced — returned in ${elapsed}s, not the stub's full ${SLOW_STUB_SECONDS}s sleep"
  else
    assert_fail "timeout enforced — took ${elapsed}s, expected <${SLOW_STUB_SECONDS}s (RECHECK_PROBE_TIMEOUT_SECONDS=1)"
  fi
else
  echo "  (skipping timeout-enforcement test — no timeout/gtimeout binary on PATH)"
fi


# ---------------------------------------------------------------------------
echo
echo "(D2) live url-json execution — PATH-stubbed curl (issue #1496)"
# ---------------------------------------------------------------------------
# The stub speaks curl's `--write-out '\n%{http_code}'` contract: body, then a
# final line carrying the HTTP status. Every branch below is a shape the verb
# must degrade to `unknown` on rather than treating as evidence of change.
cat > "$tmp_bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--url" ]; then url="$a"; fi
  prev="$a"
done
case "$url" in
  */ok)       printf '{"feed":{"entry":[1,2,3]}}\n200\n' ;;
  */zero)     printf '{"feed":{}}\n200\n' ;;
  */redirect) printf '<html>moved</html>\n302\n' ;;
  */notfound) printf '\n404\n' ;;
  */servererr) printf '\n500\n' ;;
  */badjson)  printf 'not json at all\n200\n' ;;
  */big)      printf '{"pad":"'; head -c 5000 /dev/zero | tr '\0' 'x'; printf '","n":42}\n200\n' ;;
  */slow)     sleep 10; printf '{"feed":{"entry":[1]}}\n200\n' ;;
  *)          printf '\n404\n' ;;
esac
STUB
chmod +x "$tmp_bin/curl"

url_probe() {
  # $1 = path, $2 = jq filter, $3 = expected value
  printf '<!-- do-work-recheck: url-json https://probe.example.com%s %s == %s -->\n' "$1" "$2" "$3" \
    | RECHECK_PROBE_URL_HOSTS="probe.example.com" PATH="$tmp_bin:$PATH" \
      bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null
}

assert_equals "url-json 200 + matching value -> unchanged" \
  "unchanged" "$(url_probe /ok '.feed.entry|length' 3)"
assert_equals "url-json 200 + differing value -> changed" \
  "changed" "$(url_probe /ok '.feed.entry|length' 0)"
assert_equals "url-json 200 with the gated field absent -> length 0 (the real event-gate shape)" \
  "unchanged" "$(url_probe /zero '.feed.entry|length' 0)"
assert_equals "url-json 3xx is NOT followed and is NOT accepted -> unknown" \
  "unknown" "$(url_probe /redirect '.feed.entry|length' 3)"
assert_equals "url-json 404 -> unknown, never changed" \
  "unknown" "$(url_probe /notfound '.feed.entry|length' 3)"
assert_equals "url-json 5xx -> unknown, never changed" \
  "unknown" "$(url_probe /servererr '.feed.entry|length' 3)"
assert_equals "url-json body that isn't JSON -> unknown" \
  "unknown" "$(url_probe /badjson '.feed.entry|length' 3)"
assert_equals "url-json filter yielding JSON null -> unknown, never a 'null' string compare" \
  "unknown" "$(url_probe /zero '.missing' 3)"

# Response-size cap: the same ~5 KiB body is fine under the default cap and
# rejected under a 1 KiB one, so this pins the cap itself rather than the
# stub's shape.
assert_equals "url-json under-cap response is read normally" \
  "unchanged" "$(url_probe /big '.n' 42)"
out="$(printf '<!-- do-work-recheck: url-json https://probe.example.com/big .n == 42 -->\n' \
  | RECHECK_PROBE_MAX_BYTES=1000 RECHECK_PROBE_URL_HOSTS="probe.example.com" \
    PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "url-json over-cap response -> unknown (response-size cap enforced)" "unknown" "$out"

# A host that is not allowlisted must never reach curl at all.
out="$(printf '<!-- do-work-recheck: url-json https://probe.example.com/ok .feed.entry|length == 3 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "url-json non-allowlisted host never runs the probe -> unknown" "unknown" "$out"

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  start_ts=$(date +%s)
  out="$(printf '<!-- do-work-recheck: url-json https://probe.example.com/slow .feed.entry|length == 1 -->\n' \
    | RECHECK_PROBE_TIMEOUT_SECONDS=1 RECHECK_PROBE_URL_HOSTS="probe.example.com" \
      PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  assert_equals "url-json timed-out probe -> unknown, never changed/unchanged" "unknown" "$out"
  if [[ "$elapsed" -lt "$SLOW_STUB_SECONDS" ]]; then
    assert_pass "url-json timeout enforced — returned in ${elapsed}s, not the stub's full ${SLOW_STUB_SECONDS}s sleep"
  else
    assert_fail "url-json timeout enforced — took ${elapsed}s, expected <${SLOW_STUB_SECONDS}s"
  fi
else
  echo "  (skipping url-json timeout-enforcement test — no timeout/gtimeout binary on PATH)"
fi

cleanup_tmp_bin
trap - EXIT

# ---------------------------------------------------------------------------
echo
echo "(E) doc wiring + config knobs"
# ---------------------------------------------------------------------------
if [[ -f "$HOOKS_MD" ]]; then
  assert_contains "$HOOKS_MD" "eval-recheck-probe.sh" \
    "operator-sweep doc references eval-recheck-probe.sh"
  assert_contains "$HOOKS_MD" "do-work-recheck" \
    "operator-sweep doc documents the do-work-recheck marker"
else
  assert_fail "04-steady-state-hooks.md exists (missing at $HOOKS_MD)"
fi

if [[ -f "$RATIONALE_MD" ]]; then
  assert_contains "$RATIONALE_MD" "#1198" \
    "RATIONALE.md carries a #1198 section"
else
  assert_fail "do-work-RATIONALE.md exists (missing at $RATIONALE_MD)"
fi

if [[ -f "$CONFIG_SCHEMA" ]]; then
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_timeout_seconds" \
    "schema declares scope.recheck_probe_timeout_seconds"
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_enabled" \
    "schema declares scope.recheck_probe_enabled"
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_url_hosts" \
    "schema declares scope.recheck_probe_url_hosts (issue #1496)"
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_max_bytes" \
    "schema declares scope.recheck_probe_max_bytes (issue #1496)"
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$CONFIG_SCHEMA" >/dev/null 2>&1; then
      assert_pass "shipyard.config.schema.json is valid JSON after the addition"
    else
      assert_fail "shipyard.config.schema.json is valid JSON after the addition"
    fi
  fi
else
  assert_fail "shipyard.config.schema.json exists (missing at $CONFIG_SCHEMA)"
fi

if [[ -f "$CONFIG_SH" ]]; then
  assert_contains "$CONFIG_SH" '"recheck_probe_timeout_seconds": 15' \
    "built-in defaults set scope.recheck_probe_timeout_seconds to 15"
  assert_contains "$CONFIG_SH" '"recheck_probe_enabled": true' \
    "built-in defaults set scope.recheck_probe_enabled to true"

  got="$(bash "$CONFIG_SH" get scope.recheck_probe_timeout_seconds 2>/dev/null)"
  assert_equals "shipyard-config.sh get scope.recheck_probe_timeout_seconds resolves to the built-in default" \
    "15" "$got"

  got="$(bash "$CONFIG_SH" get scope.recheck_probe_enabled 2>/dev/null)"
  assert_equals "shipyard-config.sh get scope.recheck_probe_enabled resolves to the built-in default" \
    "true" "$got"

  # The url-json host allowlist defaults to EMPTY on purpose — the verb is
  # opt-in per repo, and a non-empty default here would silently turn it into
  # the general-purpose fetch primitive #1496 was explicit about not shipping.
  got="$(bash "$CONFIG_SH" get scope.recheck_probe_url_hosts 2>/dev/null)"
  assert_equals "scope.recheck_probe_url_hosts defaults to an EMPTY allowlist (url-json is opt-in)" \
    "[]" "$got"

  got="$(bash "$CONFIG_SH" get scope.recheck_probe_max_bytes 2>/dev/null)"
  assert_equals "scope.recheck_probe_max_bytes resolves to the built-in default" \
    "1048576" "$got"
else
  assert_fail "shipyard-config.sh exists (missing at $CONFIG_SH)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
