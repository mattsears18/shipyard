#!/usr/bin/env bash
# Test: production-class operator actions are batched into one confirmation,
# stop as a class after the first denial, and name the permission-rule
# remedy; /my-turn offers to run a decided prod mutation inline.
#
# Background — issue #1563: maintainer-decided prod mutations (enable PITR,
# create scheduler jobs, additive backfills) were drained one at a time. The
# first was denied as "Modify Shared Resources", after which the classifier
# grew stricter and denied even read-only calls ("Production Reads"). Every
# item became a hand-back with no hint of the allow rule that would unblock
# the next session, and the maintainer had to walk /my-turn twice for the
# same item.
#
# This guard pins the four parts of the fix so a later edit can't silently
# drop one of them.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/operator-prod-class-gate-1563.test.sh

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

cmd_dir="$repo_root/plugins/shipyard/commands"
queue_path="$cmd_dir/do-work/operate/01-queue-and-authorization.md"
playbooks_path="$cmd_dir/do-work/operate/02-execution-and-playbooks.md"
dont_path="$cmd_dir/do-work/operate/05-dont.md"
state_path="$cmd_dir/do-work/orchestrator-state-reference.md"
summary_path="$cmd_dir/do-work/cleanup-summary.md"
myturn_path="$cmd_dir/my-turn.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

anchor='production-class-console-actions--one-batched-confirmation-then-stop-the-class-after-a-denial-1563'

echo ""
echo "Test: production-class operator gate (#1563 regression guard)"
echo ""

echo "1. Batch before the first attempt"
assert_contains "$queue_path" \
  "### Production-class console actions — one batched confirmation, then stop the class after a denial" \
  "queue file carries the production-class gate section"
assert_contains "$queue_path" \
  "Run all of these now?" \
  "attended sessions get one batched AskUserQuestion"
assert_contains "$queue_path" \
  "**attempt none of them.**" \
  "unattended sessions attempt nothing and hand back"
assert_contains "$queue_path" \
  'reason: "prod-class-unattended"' \
  "unattended hand-back carries its own reason"
assert_contains "$queue_path" \
  "never *whether* one may be" \
  "the gate does not widen what may be attempted (delete/widen stays a hand-back)"

echo ""
echo "2. Stop the class after the first denial"
assert_contains "$queue_path" "**\`Modify Shared Resources\`**" "class-stop keys off Modify Shared Resources"
assert_contains "$queue_path" "**\`Production Reads\`**" "class-stop keys off Production Reads"
assert_contains "$queue_path" "including **reads** of a prod resource" "class-stop covers prod reads too"
assert_contains "$queue_path" 'reason: "prod-class-stopped"' "stopped hand-back carries its own reason"
assert_contains "$queue_path" "The stop is scoped to the class, not the session." "non-prod items keep draining"

echo ""
echo "3. Name the permission-rule remedy"
assert_contains "$queue_path" 'Bash(gcloud firestore:*)' "queue file names a concrete allow rule"
assert_contains "$queue_path" "Never add the rule yourself." "the agent never edits permission settings"
assert_contains "$summary_path" "Remedy: allow <rule>" "end-of-session summary renders the remedy"
assert_contains "$summary_path" "\`prod-class-stopped\` →" "summary reason-phrase table covers prod-class-stopped"
assert_contains "$summary_path" "\`prod-class-unattended\` →" "summary reason-phrase table covers prod-class-unattended"

echo ""
echo "Wiring into the rest of the operator layer"
assert_contains "$playbooks_path" "$anchor" "console-action playbook routes through the gate"
assert_contains "$dont_path" "$anchor" "operator Don't list references the gate"
assert_contains "$state_path" '"prod-class-unattended" | "prod-class-stopped"' "operator_handbacks enum carries both new reasons"
assert_contains "$state_path" "prod_class_stopped" "state reference documents the class-stop flag"

echo ""
echo "4. /my-turn offers to run a decided prod mutation inline"
assert_contains "$myturn_path" \
  "**Decisions whose implementation is a production mutation — offer to run it here**" \
  "/my-turn Phase 2 carries the inline-run offer"
assert_contains "$myturn_path" "**Run them now**" "the offer has a run-now option"
assert_contains "$myturn_path" "is never run here, even with the maintainer present" \
  "delete/widen changes stay hand-backs in /my-turn too"
assert_contains "$myturn_path" "$anchor" "/my-turn links the operator gate"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d checks passed.%s\n\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi
