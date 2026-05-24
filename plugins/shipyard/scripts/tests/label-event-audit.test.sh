#!/usr/bin/env bash
# Test: the label-event-audit GitHub Actions workflow exists and encodes the
# tier-based revert/comment logic from issue #140.
#
# Background — issue #140: `/shipyard:do-work` uses GitHub labels as routing
# hints, but does not verify who applied or removed each label. The trusted-
# author check at dispatch time (step 1.7 / step 2 bucket 0.5 / step 4 filter)
# blocks the primary attack — a rogue triager applying `shipyard` to a
# stranger's issue still gets filtered for not being authored by a trusted
# user. But the rogue-triager surface still allows:
#
#   1. Routing-bomb / denial-of-service via mass `shipyard` application.
#   2. Premature `needs-human-review` removal (confusing for maintainers).
#   3. `blocked:ci` tampering that resets the 3-attempt counter.
#   4. Audit-trail gap on routing-label changes.
#
# This workflow is the belt-and-suspenders defense: on every `labeled` /
# `unlabeled` event from an actor NOT in `.shipyard/trusted-authors.txt`, it
# either reverts the change (Tier A — security-sensitive labels) or posts an
# alert comment (Tier B — routing-only labels). Trusted actors are no-ops.
#
# This test guards the structural invariants of the workflow file so any
# future edit that drops a tier-A label, removes the trigger, or skips the
# revert logic fails the gate.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/label-event-audit.test.sh

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

workflow_path="$repo_root/.github/workflows/label-event-audit.yml"
do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"

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

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    forbidden but found in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "label-event-audit workflow regression tests (issue #140)"
echo

# (1) Workflow file exists.
assert_file_exists "$workflow_path" ".github/workflows/label-event-audit.yml exists"

if [[ -f "$workflow_path" ]]; then
  # (2) Triggers — fires on issue + PR label events.
  assert_contains "$workflow_path" "issues:" \
    "Triggers on issues events"
  assert_contains "$workflow_path" "pull_request_target:" \
    "Triggers on pull_request_target (so workflow runs with repo permissions, not PR's)"
  assert_contains "$workflow_path" "labeled" \
    "Subscribes to labeled event type"
  assert_contains "$workflow_path" "unlabeled" \
    "Subscribes to unlabeled event type"

  # (3) Permissions — needs issues + pull-requests write to comment / revert.
  assert_contains "$workflow_path" "issues: write" \
    "Has issues: write permission (needed to comment and revert)"
  assert_contains "$workflow_path" "pull-requests: write" \
    "Has pull-requests: write permission (needed to comment and revert PR labels)"

  # (4) Reads .shipyard/trusted-authors.txt and lowercases comparison.
  assert_contains "$workflow_path" ".shipyard/trusted-authors.txt" \
    "References .shipyard/trusted-authors.txt for the trusted set"
  assert_contains "$workflow_path" "tr 'A-Z' 'a-z'" \
    "Lowercase-normalizes actor login for case-insensitive comparison"

  # (5) Falls back to collaborators API when the file is missing — matches
  # do-work.md step 1.7 resolution order.
  assert_contains "$workflow_path" "collaborators" \
    "Falls back to collaborators API when override file missing"

  # (5b) GH App alias expansion (issue #296). The allowlist resolution
  # must cross-add `<name>[bot]` ↔ `app/<name>` so an entry matches
  # regardless of which GitHub-API shape the comparison value carries.
  # Mirrors the orchestrator-side
  # plugins/shipyard/scripts/trusted-authors-normalize.sh helper.
  assert_contains "$workflow_path" "expand_aliases" \
    "Defines expand_aliases helper for #296 alias cross-add"
  assert_contains "$workflow_path" '[bot]' \
    "expand_aliases helper handles the [bot] suffix shape"
  assert_contains "$workflow_path" 'app/' \
    "expand_aliases helper handles the app/ prefix shape"

  # (6) Tier A labels (security-sensitive) — must include all three.
  # We grep for the labels as standalone tokens in the case branches.
  assert_contains "$workflow_path" "shipyard" \
    "Tier A includes 'shipyard' label"
  assert_contains "$workflow_path" "blocked:ci" \
    "Tier A includes 'blocked:ci' label"
  assert_contains "$workflow_path" "needs-human-review" \
    "Tier A includes 'needs-human-review' label"

  # (7) Tier B labels (routing-only, alert-only) — at least the ones called
  # out in the acceptance criteria. Per #300, blocked:agent split into
  # -hard / -soft / (legacy) — all three are Tier B (the soft/hard split
  # is a routing signal, not a security boundary).
  assert_contains "$workflow_path" "needs-refinement" \
    "Tier B includes 'needs-refinement' label"
  assert_contains "$workflow_path" "wontfix" \
    "Tier B includes 'wontfix' label"
  assert_contains "$workflow_path" "blocked:agent" \
    "Tier B includes legacy 'blocked:agent' label (pre-#300 migration)"
  assert_contains "$workflow_path" "blocked:agent-hard" \
    "Tier B includes 'blocked:agent-hard' label (#300)"
  assert_contains "$workflow_path" "blocked:agent-soft" \
    "Tier B includes 'blocked:agent-soft' label (#300)"

  # (8) Reverts tier A — must use both `--add-label` (on unlabeled events)
  # and `--remove-label` (on labeled events) to undo the actor's change.
  assert_contains "$workflow_path" "--add-label" \
    "Workflow uses --add-label to revert tier-A unlabel events"
  assert_contains "$workflow_path" "--remove-label" \
    "Workflow uses --remove-label to revert tier-A label events"

  # (9) Posts a comment tagging the maintainer.
  assert_contains "$workflow_path" "@mattsears18" \
    "Comments tag @mattsears18 to surface the audit event"

  # (10) Security-injection guards — event-supplied values must be passed
  # through env vars, not interpolated into run: blocks directly. The
  # convention these workflows follow (see secret-scan.yml,
  # external-author-gate.yml).
  assert_contains "$workflow_path" "AUTHOR: \${{ github.actor }}" \
    "Actor login is passed through env, not interpolated into run:"
  assert_contains "$workflow_path" "LABEL_NAME: \${{ github.event.label.name }}" \
    "Label name is passed through env, not interpolated into run:"

  # (11) Actions are pinned by SHA, not by floating tag (supply-chain).
  # actions/checkout is the only action we pin; matches secret-scan.yml's
  # pinning convention.
  assert_contains "$workflow_path" "actions/checkout@" \
    "Uses actions/checkout"
  # Crude SHA-pinning check: look for a 40-char hex SHA in the action ref.
  if grep -E 'actions/checkout@[0-9a-f]{40}' "$workflow_path" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "actions/checkout is pinned by full SHA (not a floating tag)"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "actions/checkout is NOT pinned by full SHA (must pin by 40-char SHA per repo convention)"
    fail=$((fail+1))
  fi

  # (12) Bot actors are skipped — matches external-author-gate.yml convention.
  # The github-actions[bot] itself adds labels (when the external-author-gate
  # adds needs-human-review), so we must not infinite-loop on our own events.
  assert_contains "$workflow_path" "Bot" \
    "Skips Bot-typed actors to avoid recursive triggering"

  # (13) Forbid the workflow_injection footgun — running with $\{\{ github.event.label.name \}\}
  # directly inside a run: block. Run blocks must use env-passed vars only.
  assert_not_contains "$workflow_path" "echo \"\${{ github.event.label.name }}\"" \
    "Does not echo event-supplied label name directly into run: (injection-safe)"
fi

# (14) do-work.md mentions the workflow as defense-in-depth (acceptance
# criterion 6: "One-line addition to commands/do-work.md").
assert_file_exists "$do_work_path" "commands/do-work.md exists"
if [[ -f "$do_work_path" ]]; then
  assert_contains "$do_work_path" "label-event-audit" \
    "do-work.md references label-event-audit workflow as defense-in-depth"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
