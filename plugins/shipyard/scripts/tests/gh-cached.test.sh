#!/usr/bin/env bash
# Test suite for scripts/gh-cached.sh — the session-scoped `gh` CLI cache
# wrapper added in #160.
#
# Strategy: stand up a fake `gh` binary in a per-test tmpdir, point PATH at
# it, and assert the wrapper's behavior against the recorded call count.
# The fake gh records each call to a counter file and emits deterministic
# stdout so the test can assert "served from cache" by counting actual
# invocations.
#
# Pure bash + jq (jq is already a hard dependency of the rest of shipyard's
# script set).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/gh-cached.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../gh-cached.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_dir_exists() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    dir not found: %s\n' "$path"
    fail=$((fail+1))
  fi
}

assert_file_missing() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file still present: %s\n' "$path"
    fail=$((fail+1))
  fi
}

# Spin up an isolated env: tmphome for SHIPYARD_HOME + a fake gh on PATH.
# The fake gh records each invocation to a counter file (one line per call,
# joined argv) and emits a JSON-shaped stdout that includes the call index
# so the test can distinguish "served from cache" vs "ran live".
mktmpenv() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/bin" "$d/home"
  cat > "$d/bin/gh" <<'SH'
#!/usr/bin/env bash
counter="${GH_CACHED_TEST_COUNTER:-/tmp/gh-cached-test-counter}"
mkdir -p "$(dirname "$counter")"
# Initialize counter file on first call so subsequent wc -l doesn't error.
[[ -f "$counter" ]] || : > "$counter"
n=$(wc -l < "$counter" 2>/dev/null | tr -d ' ')
n=$((n + 1))
# Record this call.
echo "$*" >> "$counter"
# Emit deterministic JSON-shaped stdout (the rest of shipyard's gh calls
# all use --json, so the fake matches that surface).
printf '{"call_index": %d, "argv": "%s"}\n' "$n" "$*"
SH
  chmod +x "$d/bin/gh"
  echo "$d"
}

count_calls() {
  local counter="$1"
  if [[ -f "$counter" ]]; then
    wc -l < "$counter" | tr -d ' '
  else
    echo 0
  fi
}

# --------------------------------------------------------------------------
echo "== usage / dispatch"
# --------------------------------------------------------------------------

# No subcommand → exit 64.
out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no subcommand exits 64"

# Unknown subcommand → exit 64.
out=$(bash "$helper" wat 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

# help text emits usage info to stderr.
out=$(bash "$helper" --help 2>&1)
assert_contains "$out" "Usage:" "--help prints usage"
assert_contains "$out" "gh-cached.sh run" "usage mentions run subcommand"
assert_contains "$out" "gh-cached.sh invalidate" "usage mentions invalidate"
assert_contains "$out" "gh-cached.sh stats" "usage mentions stats"
assert_contains "$out" "gh-cached.sh cleanup" "usage mentions cleanup"

# --------------------------------------------------------------------------
echo "== run: usage errors"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Missing --session-id.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --ttl 60 -- issue list 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "run without --session-id exits 64"

# Missing --ttl.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 -- issue list 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "run without --ttl exits 64"

# Non-numeric ttl.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl forever -- issue list 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "non-numeric --ttl exits 64"

# Missing -- before gh args.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 issue list 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "run without -- separator exits 64"

# -- with no following gh args.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 -- 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "run with -- but no gh args exits 64"

# Sanity: no fake gh calls happened from any of the above usage-error paths.
assert_equals "$(count_calls "$counter")" "0" "usage errors do not invoke gh"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== run: cache miss then hit"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# First call: cache miss → invokes gh.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 -- issue list --state open)
assert_contains "$out" '"call_index": 1' "first call returns gh stdout (call_index 1)"
assert_equals "$(count_calls "$counter")" "1" "first call invokes gh once"

# Cache file exists in the expected path layout.
shopt -s nullglob
cache_files=("$env/home/cache/s1"/*)
shopt -u nullglob
# Filter out _stats.json — the cache file is the other entry.
data_files=()
for f in "${cache_files[@]}"; do
  if [[ "$(basename "$f")" != "_stats.json" ]]; then
    data_files+=("$f")
  fi
done
assert_equals "${#data_files[@]}" "1" "one cache file created for the call"

# Second call with the same argv: cache hit, gh is NOT invoked.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 -- issue list --state open)
assert_contains "$out" '"call_index": 1' "second call serves cached stdout (still call_index 1)"
assert_equals "$(count_calls "$counter")" "1" "second call did NOT invoke gh (still 1 call total)"

# Different argv: different cache key, separate miss.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 -- pr list --state open)
assert_contains "$out" '"call_index": 2' "different argv resolves to a different cache slot"
assert_equals "$(count_calls "$counter")" "2" "second distinct call invokes gh again (2 calls total)"

# Cache directory now has 2 data files + the stats file.
shopt -s nullglob
cache_files=("$env/home/cache/s1"/*)
shopt -u nullglob
data_files=()
for f in "${cache_files[@]}"; do
  if [[ "$(basename "$f")" != "_stats.json" ]]; then
    data_files+=("$f")
  fi
done
assert_equals "${#data_files[@]}" "2" "two distinct cache files after two distinct argvs"

# Cache key is order-sensitive (we don't canonicalize).
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s1 --ttl 60 -- issue list --limit 100 --state open)
assert_contains "$out" '"call_index": 3' "swapped flag order resolves to a fresh cache slot"
assert_equals "$(count_calls "$counter")" "3" "swapped flag order invokes gh (cache is order-sensitive)"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== run: TTL expiration"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# TTL=0 means "always stale" — every call should miss.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s2 --ttl 0 -- issue list)
assert_contains "$out" '"call_index": 1' "TTL=0 first call returns gh stdout"
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s2 --ttl 0 -- issue list)
assert_contains "$out" '"call_index": 2' "TTL=0 second call also misses (cache always stale)"
assert_equals "$(count_calls "$counter")" "2" "TTL=0 invokes gh on every call"

# Hand-backdate a cache file to simulate an expired entry.
env2=$(mktmpenv)
counter2="$env2/calls.log"
GH_CACHED_TEST_COUNTER="$counter2" SHIPYARD_HOME="$env2/home" PATH="$env2/bin:$PATH" \
  bash "$helper" run --session-id s3 --ttl 3600 -- issue list >/dev/null
shopt -s nullglob
files=("$env2/home/cache/s3"/*)
shopt -u nullglob
cache_file=""
for f in "${files[@]}"; do
  if [[ "$(basename "$f")" != "_stats.json" ]]; then
    cache_file="$f"
    break
  fi
done
# Backdate the file by 2 hours (7200s). The TTL is 3600 (1h), so the file
# is now stale and the next call should miss.
touch -t "$(date -u -v -2H +%Y%m%d%H%M.%S 2>/dev/null || date -u --date='2 hours ago' +%Y%m%d%H%M.%S)" "$cache_file" 2>/dev/null || \
  touch -d "2 hours ago" "$cache_file"
out=$(GH_CACHED_TEST_COUNTER="$counter2" SHIPYARD_HOME="$env2/home" PATH="$env2/bin:$PATH" \
  bash "$helper" run --session-id s3 --ttl 3600 -- issue list)
assert_contains "$out" '"call_index": 2' "stale cache file (>TTL) misses and re-runs gh"

rm -rf "$env" "$env2"

# --------------------------------------------------------------------------
echo "== run: gh failure is not cached"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Swap in a fake gh that exits non-zero.
cat > "$env/bin/gh" <<'SH'
#!/usr/bin/env bash
counter="${GH_CACHED_TEST_COUNTER:-/tmp/gh-cached-test-counter}"
echo "$*" >> "$counter"
echo "partial output"
echo "ERR: simulated failure" >&2
exit 1
SH
chmod +x "$env/bin/gh"

# Call: gh exits 1 → wrapper exits 2, no cache file is created.
out=$(GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s4 --ttl 60 -- failing call 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=2" "failed gh call returns wrapper exit 2"
assert_contains "$out" "partial output" "failed gh call still emits stdout to caller"
# Data files (anything other than _stats.json) must NOT exist.
shopt -s nullglob
files=("$env/home/cache/s4"/*)
shopt -u nullglob
data_files=()
for f in "${files[@]}"; do
  if [[ "$(basename "$f")" != "_stats.json" ]]; then
    data_files+=("$f")
  fi
done
assert_equals "${#data_files[@]}" "0" "failed gh call does NOT create a cache file"

# Second call: again misses (no cache), again invokes gh.
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s4 --ttl 60 -- failing call >/dev/null 2>&1 || true
assert_equals "$(count_calls "$counter")" "2" "failed gh calls miss every time (never cached)"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== invalidate"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Prime the cache with two distinct calls.
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s5 --ttl 60 -- issue list >/dev/null
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s5 --ttl 60 -- pr list >/dev/null
assert_equals "$(count_calls "$counter")" "2" "primed cache with two distinct calls (2 gh invocations)"

# Without --pattern, invalidate drops every cache file but leaves stats.
SHIPYARD_HOME="$env/home" bash "$helper" invalidate --session-id s5 >/dev/null 2>&1
shopt -s nullglob
files=("$env/home/cache/s5"/*)
shopt -u nullglob
data_files=()
stats_present=0
for f in "${files[@]}"; do
  if [[ "$(basename "$f")" == "_stats.json" ]]; then
    stats_present=1
  else
    data_files+=("$f")
  fi
done
assert_equals "${#data_files[@]}" "0" "invalidate (no pattern) removes every data file"
assert_equals "$stats_present" "1" "invalidate (no pattern) preserves _stats.json"

# Reading after invalidate forces fresh gh calls.
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s5 --ttl 60 -- issue list >/dev/null
assert_equals "$(count_calls "$counter")" "3" "post-invalidate call invokes gh again"

# Idempotency: invalidate on a non-existent session is exit 0.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" invalidate --session-id never-existed 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "invalidate on missing session is idempotent (exit 0)"

# Invalidate requires --session-id.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" invalidate 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "invalidate without --session-id exits 64"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== stats"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Brand-new session: stats returns zeroed defaults.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" stats --session-id s6)
assert_contains "$out" '"hits":0' "fresh stats has 0 hits"
assert_contains "$out" '"misses":0' "fresh stats has 0 misses"
assert_contains "$out" '"invalidations":0' "fresh stats has 0 invalidations"
assert_contains "$out" '"bytes":0' "fresh stats has 0 bytes"

# Drive: 1 miss + 2 hits + 1 invalidate.
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s6 --ttl 60 -- issue list >/dev/null
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s6 --ttl 60 -- issue list >/dev/null
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s6 --ttl 60 -- issue list >/dev/null
SHIPYARD_HOME="$env/home" bash "$helper" invalidate --session-id s6 >/dev/null

stats_out=$(SHIPYARD_HOME="$env/home" bash "$helper" stats --session-id s6)
# Use jq to extract values precisely.
hits=$(printf '%s' "$stats_out" | jq -r '.hits')
misses=$(printf '%s' "$stats_out" | jq -r '.misses')
invalidations=$(printf '%s' "$stats_out" | jq -r '.invalidations')
bytes=$(printf '%s' "$stats_out" | jq -r '.bytes')
assert_equals "$hits" "2" "stats hits == 2 after 2 cache hits"
assert_equals "$misses" "1" "stats misses == 1 after the priming call"
assert_equals "$invalidations" "1" "stats invalidations == 1 after one full flush"
# bytes is non-zero (the cached response was ~40 bytes).
if [[ "$bytes" -gt 0 ]]; then
  printf '  %sPASS%s  stats bytes > 0 after a cached miss\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  stats bytes > 0 (got: %s)\n' "$RED" "$RESET" "$bytes"
  fail=$((fail+1))
fi

# Stats requires --session-id.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" stats 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "stats without --session-id exits 64"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== cleanup"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# Prime, then cleanup.
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s7 --ttl 60 -- issue list >/dev/null
assert_dir_exists "$env/home/cache/s7" "cache dir exists pre-cleanup"
SHIPYARD_HOME="$env/home" bash "$helper" cleanup --session-id s7
assert_file_missing "$env/home/cache/s7" "cache dir removed by cleanup"

# Cleanup is idempotent.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" cleanup --session-id s7 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "cleanup on missing dir is idempotent (exit 0)"

# Cleanup requires --session-id.
out=$(SHIPYARD_HOME="$env/home" bash "$helper" cleanup 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "cleanup without --session-id exits 64"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== SHIPYARD_GH_CACHE_DISABLED bypasses cache"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

# With cache disabled, every call invokes gh and no cache files are
# written.
SHIPYARD_GH_CACHE_DISABLED=1 GH_CACHED_TEST_COUNTER="$counter" \
  SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s8 --ttl 60 -- issue list >/dev/null
SHIPYARD_GH_CACHE_DISABLED=1 GH_CACHED_TEST_COUNTER="$counter" \
  SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s8 --ttl 60 -- issue list >/dev/null
assert_equals "$(count_calls "$counter")" "2" "SHIPYARD_GH_CACHE_DISABLED=1 invokes gh on every call"
assert_file_missing "$env/home/cache/s8" "disabled cache does not create any cache dir"

rm -rf "$env"

# --------------------------------------------------------------------------
echo "== atomic-write hygiene (no .tmp.<pid> stragglers)"
# --------------------------------------------------------------------------

env=$(mktmpenv)
counter="$env/calls.log"

GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s9 --ttl 60 -- issue list >/dev/null
# Stats write also goes through atomic_write — invoking it twice exercises
# both code paths (write-from-stdin and rename).
GH_CACHED_TEST_COUNTER="$counter" SHIPYARD_HOME="$env/home" PATH="$env/bin:$PATH" \
  bash "$helper" run --session-id s9 --ttl 60 -- issue list >/dev/null

# Look for any leftover .tmp.* files. None should exist after a successful
# write (the trap is the failure-path cleaner; on success the rename
# consumes the tmp).
shopt -s nullglob
leftover=("$env/home/cache/s9"/*.tmp.*)
shopt -u nullglob
assert_equals "${#leftover[@]}" "0" "no .tmp.<pid> files linger after successful writes"

rm -rf "$env"

# --------------------------------------------------------------------------
echo
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d tests passed.%s\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi
