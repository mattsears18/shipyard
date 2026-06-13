#!/usr/bin/env bash
# Test: the auditing-authenticated-surfaces skill exists with correct
# frontmatter and the four reusable rules, and the two live-URL auditors that
# tour signed-in surfaces (web-ux, a11y) reference it.
#
# Background — issue #567: the live-URL auditors carried only a thin
# "optionally: test credentials for authenticated surfaces" line and told the
# agent to type the email/password into the browser MCP itself — an unsafe and
# unreliable model. The reusable knowledge for doing it correctly (login
# harness that never echoes secrets, pre-provisioned account, the SPA
# IndexedDB/localStorage storageState gotcha, assert-on-a-protected-route) lived
# only in a consumer repo's CLAUDE.md, so every login-walled audit re-derived
# it. #567 lifts that kernel into a shared skill and wires the two auditors to
# it.
#
# This test is the regression guard: if anyone removes the skill, drops one of
# the four rules, breaks the frontmatter, or removes an auditor's reference,
# the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/auditing-authenticated-surfaces.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/auditing-authenticated-surfaces/SKILL.md"
web_ux_path="$repo_root/plugins/shipyard/agents/web-ux-auditor.md"
a11y_path="$repo_root/plugins/shipyard/agents/a11y-auditor.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "auditing-authenticated-surfaces skill regression tests (issue #567)"
echo

# (1) Skill file must exist with proper YAML frontmatter.
assert_file_exists "$skill_path" "auditing-authenticated-surfaces SKILL.md exists"

if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "name: auditing-authenticated-surfaces" \
    "SKILL.md frontmatter declares name: auditing-authenticated-surfaces"
  assert_contains "$skill_path" "description:" \
    "SKILL.md frontmatter has a description field"
  # The description must trigger on authenticated / login-walled surfaces so the
  # skill is discoverable from the auditor that needs it.
  if grep -m1 '^description:' "$skill_path" | grep -qiE 'authenticated|login-walled|signed-in|login wall'; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "SKILL.md description triggers on authenticated/login-walled surfaces"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "SKILL.md description triggers on authenticated/login-walled surfaces"
    fail=$((fail+1))
  fi

  # The four reusable rules must each be present so a single reader sees the
  # full contract.

  # Rule 1 — auditors must not self-authenticate by typing secrets; use a login
  # harness that reads creds from a gitignored env file and never echoes them,
  # capturing artifacts for the auditor to judge.
  assert_contains "$skill_path" "login harness" \
    "SKILL.md rule 1: names the login-harness pattern"
  assert_contains "$skill_path" "gitignored env file" \
    "SKILL.md rule 1: harness reads creds from a gitignored env file"
  assert_contains "$skill_path" "never echo" \
    "SKILL.md rule 1: harness never echoes the secret"
  assert_contains "$skill_path" "axe-core" \
    "SKILL.md rule 1: harness captures axe-core artifacts for the auditor to judge"

  # Rule 2 — a fresh signup can't reach authenticated surfaces; require a
  # pre-provisioned account.
  assert_contains "$skill_path" "fresh signup" \
    "SKILL.md rule 2: a fresh signup can't reach authenticated surfaces"
  assert_contains "$skill_path" "pre-provisioned account" \
    "SKILL.md rule 2: require a pre-provisioned account"

  # Rule 3 — SPA session gotcha: many SPA auth SDKs (Firebase Web SDK) store the
  # token in IndexedDB/localStorage which Playwright storageState does NOT
  # serialize, so log in and tour within ONE live context.
  assert_contains "$skill_path" "storageState" \
    "SKILL.md rule 3: names the Playwright storageState gotcha"
  assert_contains "$skill_path" "IndexedDB" \
    "SKILL.md rule 3: names IndexedDB as the un-serialized token store"
  assert_contains "$skill_path" "Firebase" \
    "SKILL.md rule 3: names Firebase Web SDK as the common SPA auth SDK"
  assert_contains "$skill_path" "ONE live context" \
    "SKILL.md rule 3: prescribes logging in and touring within ONE live context"

  # Rule 4 — assert on a protected route that 302s when unauthenticated, not on
  # `/` (which renders the public marketing view when logged out).
  assert_contains "$skill_path" "protected route" \
    "SKILL.md rule 4: assert on a protected route"
  assert_contains "$skill_path" "302" \
    "SKILL.md rule 4: the protected route 302s when unauthenticated"
  assert_contains "$skill_path" "marketing view" \
    "SKILL.md rule 4: / renders the public marketing view when logged out"
fi

# (2) The two live-URL auditors that tour signed-in surfaces must reference the
# skill by its canonical invocation name.
assert_file_exists "$web_ux_path" "web-ux-auditor.md exists"
assert_file_exists "$a11y_path" "a11y-auditor.md exists"

if [[ -f "$web_ux_path" ]]; then
  assert_contains "$web_ux_path" "shipyard:auditing-authenticated-surfaces" \
    "web-ux-auditor.md references the auditing-authenticated-surfaces skill"
fi
if [[ -f "$a11y_path" ]]; then
  assert_contains "$a11y_path" "shipyard:auditing-authenticated-surfaces" \
    "a11y-auditor.md references the auditing-authenticated-surfaces skill"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
