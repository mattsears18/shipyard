#!/usr/bin/env bash
# Test: the do-work spec routes "external-service setup that needs a credential
# the user hasn't provisioned yet" away from autonomously committing dead config
# and toward the operator handoff (`needs-operator`), at three layers.
#
# Background — issue #628: a user asked shipyard to work through their backlog,
# one ticket being "set up Sentry". Because they manage infra with Terraform,
# a worker wrote the Terraform autonomously and it deployed config with no
# functioning values — the user hadn't even created a Sentry account, so there
# was no DSN to set. The committed config was structurally dead.
#
# The category is "work with a human-shaped hole in the middle": shipyard can
# write the code around a credential, but the credential itself (a Sentry DSN,
# a Stripe key, a service account) can't be written, inferred, or fabricated
# until a human provisions the external service. That is structurally different
# from normal code work, and must NOT be committed with a placeholder.
#
# The fix has three load-bearing layers, all asserted here:
#   1. Worker-side guard (issue-work.md §4.4): before commit, a not-yet-
#      provisioned required credential makes the worker bail
#      `external provisioning required — ...` instead of committing dead config.
#   2. Orchestrator routing (steady-state.md bail table): that bail string maps
#      to the `needs-operator` label (an operator action), NOT needs-human-review.
#   3. Scope-preflight carve-out (06-scope-preflight.md): the default-to-slicing
#      bias does NOT apply to external-service setup — defer `external-dependency`
#      (→ needs-operator) with a provisioning checklist in the diagnosis comment.
#
# This test is the regression guard: if any of those three layers regress, the
# provisioning-gated issue silently reverts to "commit dead config" or lands in
# the wrong queue.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/external-provisioning-guard.test.sh

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

issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
scope_preflight_path="$repo_root/plugins/shipyard/commands/do-work/setup/06-scope-preflight.md"
operate_path="$repo_root/plugins/shipyard/commands/do-work/operate.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1" before="$2" after="$3" label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"; fail=$((fail+1)); return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"; fail=$((fail+1)); return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ %d, after @ %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker first; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"; fail=$((fail+1))
  fi
}

echo "external-provisioning guard regression tests (issue #628)"
echo

# --- Layer 1: worker-side guard (issue-work.md §4.4) ---
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"
if [[ -f "$issue_work_path" ]]; then
  assert_contains "$issue_work_path" "### 4.4 External-provisioning guard" \
    "issue-work.md adds §4.4 External-provisioning guard"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/628" \
    "issue-work.md links to originating issue #628"
  assert_contains "$issue_work_path" "blocked: external provisioning required" \
    "issue-work.md defines the canonical bail string"
  assert_contains "$issue_work_path" "must never be fabricated" \
    "issue-work.md forbids fabricating the credential value"
  # The guard must be narrow — it explicitly does NOT fire on already-provisioned
  # references or inert variable declarations, or it would block legitimate work.
  assert_contains "$issue_work_path" "does **not** fire" \
    "issue-work.md scopes the guard narrowly (does not over-trigger)"
  assert_contains "$issue_work_path" "already-provisioned" \
    "issue-work.md exempts already-provisioned credentials"
  # §4.4 must sit before §4.5 (the empty-diff guard) — the provisioning check
  # is a pre-commit gate, and placeholder config is a NON-empty diff that the
  # empty-diff guard would wave through.
  assert_section_ordering "$issue_work_path" \
    "### 4.4 External-provisioning guard" \
    "### 4.5 Pre-PR-create diff sanity check" \
    "§4.4 lands before §4.5 empty-diff guard"
fi

# --- Layer 2: orchestrator routing (steady-state.md bail table → needs-operator) ---
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"
if [[ -f "$steady_state_path" ]]; then
  assert_contains "$steady_state_path" "external provisioning required" \
    "steady-state.md recognizes the provisioning bail string"
  # It routes to needs-operator (operator action), NOT needs-human-review.
  assert_contains "$steady_state_path" 'grep -qi "external provisioning required"' \
    "steady-state.md classifies the bail before the refuse default"
  assert_contains "$steady_state_path" '--add-label "needs-operator"' \
    "steady-state.md applies the needs-operator label to the provisioning bail"
  assert_contains "$steady_state_path" "Why a provisioning bail routes to" \
    "steady-state.md documents the needs-operator routing rationale"
fi

# --- Layer 3: scope-preflight carve-out (06-scope-preflight.md) ---
assert_file_exists "$scope_preflight_path" "commands/do-work/setup/06-scope-preflight.md exists"
if [[ -f "$scope_preflight_path" ]]; then
  assert_contains "$scope_preflight_path" "Provisioning carve-out" \
    "scope-preflight names the provisioning carve-out against the slicing bias"
  assert_contains "$scope_preflight_path" "Sentry account + DSN provisioning pending" \
    "scope-preflight gives the Sentry external-dependency evidence example"
  assert_contains "$scope_preflight_path" "What to provision" \
    "scope-preflight renders a provisioning checklist in the diagnosis comment"
fi

# --- Operator-layer wiring: --operate recognizes the bail as browser-completable ---
assert_file_exists "$operate_path" "commands/do-work/operate.md exists"
if [[ -f "$operate_path" ]]; then
  assert_contains "$operate_path" "external provisioning required" \
    "operate.md enqueues the provisioning bail as an operator handback"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
