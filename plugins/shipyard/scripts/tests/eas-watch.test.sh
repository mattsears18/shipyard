#!/usr/bin/env bash
# Test suite for scripts/eas-watch.sh — the EAS build-status watcher
# helper backing the /shipyard:eas-watch command (issue #270).
#
# Covers:
#   - state-path / state-init: deterministic path under $SHIPYARD_HOME
#   - state-read: empty-default behaviour for both whole-file and per-project
#   - state-update: atomic write + per-project entry shape
#   - diff: first-run (no cursor → emit all), incremental (emit only newer),
#           cursor-at-head (no-op), cursor-not-found (emit everything),
#           field projection coverage (status, platform, profile, etc.)
#   - project-slug: app.json fallback when EAS CLI is absent
#   - list-builds: exit 3 when `eas` not on PATH, exit 4 when no Expo
#                  project at cwd
#
# Pure bash + jq. No real `eas` CLI required — the script's seams use
# SHIPYARD_EAS_CLI for the binary path so tests inject a stub.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/eas-watch.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../eas-watch.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'; fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"; fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    unexpectedly contained: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'; fail=$((fail+1))
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"; fail=$((fail+1))
  fi
}

mktmphome() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# --------------------------------------------------------------------------
echo "== state-path"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-path)
assert_equals "$out" "$tmphome/eas-state.json" "state-path returns \$SHIPYARD_HOME/eas-state.json"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== state-init"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" state-init
state_file="$tmphome/eas-state.json"
assert_file_exists "$state_file" "state-init creates the file under \$SHIPYARD_HOME"
content=$(cat "$state_file")
assert_contains "$content" '"version":1' "state-init writes version: 1"
assert_contains "$content" '"projects":{}' "state-init initialises empty projects map"

# Idempotent — second call doesn't clobber existing content.
SHIPYARD_HOME="$tmphome" bash "$helper" state-update --project "@me/app" --last-seen-id "build-1" >/dev/null
before=$(cat "$state_file")
SHIPYARD_HOME="$tmphome" bash "$helper" state-init
after=$(cat "$state_file")
assert_equals "$after" "$before" "state-init is idempotent — does not clobber existing content"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== state-read"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
# Read before init: returns empty-shape defaults.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read)
assert_contains "$out" '"version":1' "state-read before init returns empty default shape"
assert_contains "$out" '"projects":{}' "state-read before init returns empty projects map"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --project "@me/app")
assert_equals "$(echo "$out" | jq -c '.')" "{}" "state-read --project before init returns {}"

# After update.
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" \
  --last-seen-id "build-abc" \
  --last-checked "2026-05-23T18:00:00Z" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --project "@me/app")
assert_contains "$out" '"last_seen_id"' "state-read --project returns the entry's last_seen_id"
assert_contains "$out" '"build-abc"' "state-read --project returns the correct build id"
assert_contains "$out" '"2026-05-23T18:00:00Z"' "state-read --project preserves last_checked_at"

# Other project's entry remains empty.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --project "@me/other")
assert_equals "$(echo "$out" | jq -c '.')" "{}" "state-read --project for unknown slug returns {}"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== state-update"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" --last-seen-id "build-1" >/dev/null
state_file="$tmphome/eas-state.json"
assert_file_exists "$state_file" "state-update auto-initialises the file when missing"
content=$(cat "$state_file")
assert_contains "$content" '"build-1"' "state-update persists last_seen_id"
assert_contains "$content" '"@me/app"' "state-update keys by project slug"

# Overwrite — second update replaces the entry.
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" --last-seen-id "build-2" >/dev/null
content=$(cat "$state_file")
assert_contains "$content" '"build-2"' "state-update overwrites the existing entry"
assert_not_contains "$content" '"build-1"' "state-update replaces the previous last_seen_id"

# Second project — both entries coexist.
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/other" --last-seen-id "build-z" >/dev/null
content=$(cat "$state_file")
assert_contains "$content" '"@me/app"' "state-update preserves first project entry"
assert_contains "$content" '"@me/other"' "state-update adds second project entry"
assert_contains "$content" '"build-2"' "state-update keeps first project's last_seen_id"
assert_contains "$content" '"build-z"' "state-update writes second project's last_seen_id"

# Missing --project / --last-seen-id → usage error.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-update --project "@me/app" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "state-update without --last-seen-id exits 64"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== diff — first run (no cursor)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" state-init

builds_file="$tmphome/builds.json"
cat > "$builds_file" <<'JSON'
[
  {
    "id": "b3",
    "status": "errored",
    "platform": "ios",
    "profile": "production",
    "createdAt": "2026-05-23T18:00:00Z",
    "gitCommitHash": "abc123",
    "error": {"message": "Configure expo-updates failed"},
    "logsUrl": "https://expo.dev/accounts/me/projects/app/builds/b3"
  },
  {
    "id": "b2",
    "status": "finished",
    "platform": "android",
    "profile": "preview",
    "createdAt": "2026-05-23T17:00:00Z",
    "gitCommitHash": "def456",
    "logsUrl": "https://expo.dev/accounts/me/projects/app/builds/b2"
  },
  {
    "id": "b1",
    "status": "finished",
    "platform": "ios",
    "profile": "production",
    "createdAt": "2026-05-23T16:00:00Z",
    "gitCommitHash": "ghi789",
    "logsUrl": "https://expo.dev/accounts/me/projects/app/builds/b1"
  }
]
JSON

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" diff \
  --project "@me/app" --builds-json "$builds_file")
line_count=$(echo "$out" | wc -l | tr -d ' ')
assert_equals "$line_count" "3" "diff with no cursor emits every build (3 lines)"
assert_contains "$out" '"id":"b3"' "diff emits b3 (newest, errored)"
assert_contains "$out" '"id":"b2"' "diff emits b2"
assert_contains "$out" '"id":"b1"' "diff emits b1 (oldest)"
assert_contains "$out" '"status":"errored"' "diff projects status field"
assert_contains "$out" '"platform":"ios"' "diff projects platform field"
assert_contains "$out" '"profile":"production"' "diff projects profile field"
assert_contains "$out" '"errorMessage":"Configure expo-updates failed"' \
  "diff flattens .error.message into errorMessage"
assert_contains "$out" '"gitCommitHash":"abc123"' "diff projects gitCommitHash"
assert_contains "$out" '"logsUrl":"https://expo.dev/accounts/me/projects/app/builds/b3"' \
  "diff projects logsUrl"

# --------------------------------------------------------------------------
echo "== diff — incremental (cursor mid-list)"
# --------------------------------------------------------------------------

# Set cursor at b2 — diff should emit only b3 (newer).
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" --last-seen-id "b2" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" diff \
  --project "@me/app" --builds-json "$builds_file")
line_count=$(echo "$out" | wc -l | tr -d ' ')
assert_equals "$line_count" "1" "diff with cursor at b2 emits exactly 1 line"
assert_contains "$out" '"id":"b3"' "diff with cursor at b2 emits b3"
assert_not_contains "$out" '"id":"b2"' "diff with cursor at b2 does NOT re-emit b2"
assert_not_contains "$out" '"id":"b1"' "diff with cursor at b2 does NOT emit b1 (older than cursor)"

# --------------------------------------------------------------------------
echo "== diff — cursor at head (no new builds)"
# --------------------------------------------------------------------------

SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" --last-seen-id "b3" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" diff \
  --project "@me/app" --builds-json "$builds_file")
assert_equals "$out" "" "diff with cursor at head emits nothing (no new builds)"

# --------------------------------------------------------------------------
echo "== diff — cursor id not in list (treat as everything new)"
# --------------------------------------------------------------------------

# A stale cursor (build aged out of the --limit window) shouldn't crash —
# the safe default is to emit every build we currently see, letting the
# caller catch up.
SHIPYARD_HOME="$tmphome" bash "$helper" state-update \
  --project "@me/app" --last-seen-id "stale-build-xyz" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" diff \
  --project "@me/app" --builds-json "$builds_file")
line_count=$(echo "$out" | wc -l | tr -d ' ')
assert_equals "$line_count" "3" "diff with unknown cursor emits everything (safe default)"

# --------------------------------------------------------------------------
echo "== diff — missing --builds-json file"
# --------------------------------------------------------------------------

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" diff \
  --project "@me/app" --builds-json "/no/such/file.json" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=5" "diff with missing builds-json file exits 5"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== list-builds — \`eas\` binary not found"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
# Use a sandbox cwd that has app.json but a bogus EAS binary so the
# is_expo_project check passes and the binary check fails.
sandbox=$(mktemp -d)
echo '{"expo":{"slug":"test-app"}}' > "$sandbox/app.json"
pushd "$sandbox" >/dev/null || exit 1
out=$(SHIPYARD_HOME="$tmphome" SHIPYARD_EAS_CLI="this-binary-does-not-exist" \
  bash "$helper" list-builds 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "list-builds exits 3 when \`eas\` binary is missing"
assert_contains "$out" "not found on PATH" "list-builds error message mentions PATH"
popd >/dev/null || exit 1
rm -rf "$sandbox" "$tmphome"

# --------------------------------------------------------------------------
echo "== list-builds — not inside an Expo project"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
sandbox=$(mktemp -d)  # no app.json
pushd "$sandbox" >/dev/null || exit 1
# Use a stub eas binary so the binary-presence check passes but the
# is_expo_project check fires.
stubdir=$(mktemp -d)
cat > "$stubdir/eas" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stubdir/eas"
out=$(SHIPYARD_HOME="$tmphome" SHIPYARD_EAS_CLI="$stubdir/eas" \
  bash "$helper" list-builds 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=4" "list-builds exits 4 when not inside an Expo project"
assert_contains "$out" "not inside an Expo project" "list-builds error message names the failure"
popd >/dev/null || exit 1
rm -rf "$stubdir" "$sandbox" "$tmphome"

# --------------------------------------------------------------------------
echo "== project-slug — app.json fallback"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
sandbox=$(mktemp -d)
echo '{"expo":{"slug":"my-app"}}' > "$sandbox/app.json"
pushd "$sandbox" >/dev/null || exit 1
# No eas binary on PATH → falls back to local app.json slug.
out=$(SHIPYARD_HOME="$tmphome" SHIPYARD_EAS_CLI="no-such-binary" \
  bash "$helper" project-slug)
assert_equals "$out" "local:my-app" "project-slug falls back to local:<slug> when EAS CLI absent"
popd >/dev/null || exit 1
rm -rf "$sandbox" "$tmphome"

# project-slug with no app.json → exit 4.
tmphome=$(mktmphome)
sandbox=$(mktemp -d)
pushd "$sandbox" >/dev/null || exit 1
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" project-slug 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=4" "project-slug exits 4 when no app.json at cwd"
popd >/dev/null || exit 1
rm -rf "$sandbox" "$tmphome"

# --------------------------------------------------------------------------
echo "== usage / unknown subcommand"
# --------------------------------------------------------------------------

out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no-args invocation exits 64"
assert_contains "$out" "Usage:" "no-args invocation prints usage"

out=$(bash "$helper" not-a-real-subcommand 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

# --------------------------------------------------------------------------
echo "== summary"
# --------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
