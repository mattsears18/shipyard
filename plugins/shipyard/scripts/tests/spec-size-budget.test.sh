#!/usr/bin/env bash
# Test: per-file byte-size ceiling on the ALWAYS-loaded issue-work worker
# spec — issue #980.
#
# Background
# ----------
# Every `mode: issue-work` dispatch unconditionally reads three files before
# it looks at a single line of the repo it's working on:
#
#   agents/issue-worker/issue-work.md   the full step-by-step worker spec
#   skills/worker-preamble/SKILL.md     the shared worktree/return-contract rules
#   agents/issue-worker.md              the thin mode router
#
# #980 measured this "mandatory floor" at 187 KB (~53k tokens) and found it
# had grown 2.3x since 1.9.4 with nothing in the release process budgeting
# for the growth — each individually-reasonable addition compounded
# silently. The fix for the *existing* bloat was a one-time thin-router
# split of issue-work.md's rare/opt-in sections (§5.85, §5.9, §6.5, §6.6)
# into on-demand fragments loaded only when their trigger condition fires
# (mirroring the worker-preamble fragment split from #617/#808).
#
# That one-time cut doesn't stop the NEXT 2.3x drift. This suite is the
# durable fix #980 asked for: a per-file ceiling on the always-loaded
# files, checked in CI, so a future addition that meaningfully grows one of
# these files fails the build instead of silently compounding. Ceilings
# carry ~10-12% headroom over the size at the time this suite was added
# (2026-07-31, right after the #980 split) — enough for normal editing, not
# enough to silently re-absorb a whole section's worth of prose.
#
# Raising a ceiling is a valid fix when growth is deliberate and reviewed —
# just bump the number in this file and say why in the PR. The point isn't
# "these files may never grow," it's "growth is a decision someone makes on
# purpose," per #980's ask.
#
# issue-work.md's ceiling was raised 112000 -> 116000 by #986 (2026-07-31):
# a new §6.7 deferred-slice disposition shape (mirroring §6.5/§6.6's already-
# budgeted stub pattern) needed touchpoints at five spots — Inputs, a second
# §5 non-closing exception, a fifth §5.85 leak-verification trigger shape,
# the §6.7 stub itself, a step-8 return line, and a Don't bullet — all
# genuinely necessary for a worker to find and use the new on-demand
# fragment (issue-work-deferred-slice-dispatch.md, itself uncapped). Trimmed
# every addition to the terseness of the existing #851/#852 stubs first;
# what's left is the deliberate, reviewed growth this ceiling exists to
# gate, not silent compounding.
#
# issue-work.md's ceiling was raised 116000 -> 120000 by #1088 (2026-08-07):
# a new mandatory (not opt-in-gated) §4.45 self-check — never disable a
# committed security/supply-chain control to make CI pass — needed
# touchpoints at four spots: the §4.45 section itself, a step-6 pointer run
# before either trust branch, a step-8 return line for the new
# `auto-merge: unarmed — policy-override` outcome, and a Don't bullet.
# Because the check applies on every dispatch (unlike §6.5/§6.6/§6.7, which
# open with "skip unless this Context paragraph is present"), it couldn't be
# reduced to a trigger-and-pointer stub the way those were — the rule itself
# has to be inline for a worker to internalize it during implementation, not
# just discoverable when a rare condition fires. The repro and the narrow
# override carve-out moved to issue-work-RATIONALE.md (uncapped); what's
# left here is already trimmed to the terseness of the #851/#852/#986 stubs.
#
# skills/worker-preamble/SKILL.md's ceiling was LOWERED 68000 -> 57000 by
# #1012 (2026-07-31), the follow-on tail to #980/#1011: the same thin-core +
# on-demand-fragments pattern applied to issue-work.md by #1011 was applied
# to SKILL.md itself. Six rare/opt-in sections moved out to new or existing
# fragments — Never `git stash`'s mechanism + unavoidable-stash procedure
# (git-stash-prohibition.md), the broad-process-kill repro + host-detection
# check (process-kill-detail.md), the step-0/mid-session cwd-check's
# pre-#826 fallback form (consolidated once instead of duplicated twice,
# assert-worktree-cwd-fallback.md), the harness's 600s auto-background
# re-block pattern (folded into the existing ci-pitfalls.md, fixing a
# cross-reference from fix-checks-only.md that already assumed it lived
# there), and the background-process-cleanup mechanism table
# (stop-background-processes.md) — with trigger-and-pointer stubs left
# behind so no anchor reference broke and no rule lost reachability. Actual
# size dropped 61394 -> ~51555 bytes (-16%); the new ceiling carries the
# same ~10-12% headroom convention as every other row in this file.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 57000 -> 58000 by
# #1088 (2026-08-07): a new "Never disable a committed security or
# supply-chain control" prohibition, always-loaded so it reaches all seven
# worker modes per the originating issue's own ask — the reason it can't be
# pushed to an on-demand fragment the way most growth here is. Trimmed twice
# (once to the terseness of the "Never `--no-verify`" section immediately
# above it, once more after that still didn't fit) before touching this
# ceiling at all; the repro and full mechanism live in auto-merge.md and
# issue-work-RATIONALE.md (both uncapped), not duplicated here.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 58000 -> 59000 by
# #1113 (2026-08-07): a new "Auto-backgrounded verification must be awaited
# to a terminal result" bullet, sited directly next to the #1054
# commit-before-yield invariant it's the same family as ("don't yield in a
# state the orchestrator can't act on") — five workers in one session ended
# their dispatch on a non-terminal narrative ("I'll resume once it reports
# back") instead of awaiting an auto-backgrounded test run, and a prompt-
# level instruction telling a worker not to do this was not sufficient (one
# worker did it anyway with that exact instruction in its own dispatch
# prompt) — so the rule has to live in the always-loaded contract every mode
# reads, not per-dispatch prose. Kept to one bullet, matching the terseness
# of its four siblings in the same list; the repro detail (which issues, what
# the workers actually returned) stays in issue #1113 rather than duplicated
# here.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 59000 -> 60000 by
# #1135 (2026-08-08), a follow-up to #1115's declined `verifying` token: the
# "Auto-backgrounded verification must be awaited" bullet (#1113, above)
# told a worker to bail with `blocked:` when it genuinely can't finish
# verification within budget, but named no canonical phrase — so
# steady-state.md's Reason -> class table had nothing reliable to match,
# and such a bail fell through to the table's conservative `refuse` default
# (needs-human-review) instead of the `soft` (blocked:agent-soft,
# auto-retried next session) treatment it actually deserves — an
# environmental/transient condition, not a human judgment call. Extended
# the existing sentence in place (no new heading) to name the canonical
# phrase `verification did not complete within budget`; the file was
# already 22 bytes under the prior ceiling, so even this one-sentence
# extension needed the bump.
#
# skills/worker-preamble/SKILL.md did NOT need a ceiling raise for #1166
# (2026-08-09) — the new "Never create a credential" section (569 bytes) fit
# inside the ~864 bytes of headroom left after #1135's last raise.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 60000 -> 61000 by
# #1220 (2026-08-11): a new "File-path form" bullet in "Return-contract
# discipline" states the expected path form (repo-relative, never
# worktree- or primary-checkout-absolute) for any file paths a worker
# names in its return — always-loaded because the ambiguity it closes
# (a correct worker's return reading identically to an actual primary-
# checkout isolation violation) can arise on any dispatch, in any mode,
# not behind a rare/opt-in condition a fragment stub could gate on.
# Trimmed twice (once to the terseness of the "Never create a credential"
# section, once more after that still didn't fit) before touching this
# ceiling; the file had only 39 bytes of headroom left after #1135's raise,
# so even the trimmed ~700-byte bullet needed the bump.
#
# issue-work.md's ceiling was raised 120000 -> 121000 by #1166 (2026-08-09):
# a P0 security-boundary fix — a worker minted a live GCP service-account key
# to work around a missing credential rather than handing back — added a
# "Never create a credential" prohibition to the always-loaded
# skills/worker-preamble/SKILL.md core, plus a one-line Don't-section mirror
# in every per-mode file (this one included) so the prohibition is
# discoverable directly in the worker's own spec, not only via a skill
# cross-reference. issue-work.md was already 60 bytes under its prior
# ceiling; the new bullet needed the bump.
#
# issue-work.md's ceiling was raised 121000 -> 123000 by #1248 (2026-08-11):
# the backlog.self_assign config option (defaulting false) gates the
# self-assignment step in step 1 of every dispatch — a ~300-byte
# CLAUDE_PLUGIN_ROOT + SHIPYARD_REPO_ROOT preamble is now required before the
# bash block that reads the config (same preamble pattern already used in
# dispatch-rules.md, inline-trivial.md, and worker-preamble fragments), so
# the step can execute reliably. The preamble is load-bearing for the new
# feature and cannot be reasonably shortened without compromising the
# multi-layer config resolution it performs.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 61000 -> 62000 by
# #1240 (2026-08-11): a new fragments-table row for milestone-prohibition.md
# (the worker-side half of shipyard:update-roadmap's orchestrator-only
# boundary — a worker must never create/rename/renumber/reassign a
# milestone) needed adding to the always-loaded fragments index. The file
# had only 28 bytes of headroom left after #1220's last raise, so even the
# row's terseness-trimmed shape (three trims, down from a fuller
# trigger/scope description) needed the bump.
#
# issue-work.md's ceiling was raised 123000 -> 126000 by #1258 (2026-08-11):
# step 3 ("Sync + branch") was prose-only, sandwiched between "read the
# issue" and "implement" with no concrete gate — a worker with the entire
# spec in context still drifted straight past the `git checkout -B` and
# implemented on the harness's placeholder branch. The fix adds a short
# load-bearing framing paragraph to step 3 plus a structural checkpoint at
# the start of step 4 (its first action, immediately before the first
# Edit/Write) that invokes the new scripts/assert-branch-switched.sh
# predicate and hard-stops on anything but a `match` verdict — mirroring how
# scripts/assert-worktree-cwd.sh backs the step-0 cwd fail-fast. A one-line
# Don't-list mirror was added for discoverability. All three additions were
# trimmed once already; the checkpoint's bash block still needs its own full
# CLAUDE_PLUGIN_ROOT preamble line per claude-plugin-root-preamble.test.sh's
# convention (a `${CLAUDE_PLUGIN_ROOT}`-using block must carry the preamble
# in the same or an immediately preceding block — a prose "reuse the value
# already resolved" note doesn't satisfy that scanner), which is most of
# this raise's headroom.
#
# # issue-work.md's ceiling was raised 126000 -> 128000 by #1334 (2026-08-13):
# #1258's fix put the branch-checkout *check* at the start of step 4, but a
# worker can still slip past a check it never reaches on its own — #1334's
# repro is exactly that (a worker committed onto the harness placeholder
# branch, self-corrected, but nothing structural stopped it). The fix is a
# new step 0.6 that runs step 3's checkout immediately after step 0.5,
# before self-assign or reading the issue, closing the drift window rather
# than only detecting it afterward — plus reframing paragraphs at step 3,
# step 4, and the Don't-list bullet to point at the new earlier checkpoint
# instead of describing step 4's check as "the actual enforcement." A
# PreToolUse hook (mirroring enforce-worktree-isolation.sh) was considered
# and rejected again here, for the same reason #1270 rejected it plus a
# wider one: the Edit/Write/Bash PreToolUse payload carries no signal
# distinguishing a `/do-work` worker's isolated worktree from any other
# `Agent`-tool `isolation: "worktree"` dispatch (a pattern this repo's own
# CLAUDE.md recommends broadly for delegated work, not just do-work) — both
# land on an identical `worktree-agent-<id>` branch, so a hook blocking
# Edit/Write while on that branch would false-positive-block every generic
# isolated-agent task that legitimately never renames its branch, not just
# unrelated one-off worktree tasks as #1270 already flagged.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 62000 -> 63000 by
# #1335 (2026-08-13): the Return-contract discipline bullet list gained a new
# "exactly one terminal disposition line per return" rule — a worker return
# carrying two mutually-exclusive terminal disposition lines (a fabricated
# one, a narrated self-correction, then the honest one) is reconciled by
# whichever prefix the orchestrator's parser matches first, since nothing in
# the contract previously said a return must resolve to a single terminal
# line. The file had only 18 bytes of headroom left after #1240's last
# raise, so even the trimmed-once bullet (repro detail deliberately left out
# — it already lives in fix-checks-only.md's own copy of the rule and in
# do-work-RATIONALE.md) needed the bump.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 63000 -> 66000 by
# #1395 (2026-08-15): a new always-loaded core section telling a worker that
# ADDS an executable script to record its git exec bit
# (`git update-index --chmod=+x`, verified with `git ls-files -s` -> 100755).
# It has to be core, not an on-demand fragment: the whole failure mode is
# that the worker doesn't know the rule exists, so a fragment nobody loads
# would be inert. The section also carries the discriminator against
# node-bootstrap.md's OPPOSITE `chmod +x`-locally-only guidance for a
# pre-existing hook file (#459) — without it the two rules read as
# contradictory, which is why the rule couldn't be a one-liner. The file had
# only 110 bytes of headroom after #1335's raise, so the bump is the whole
# section's cost; 66000 (not 65000) leaves real headroom rather than 47 bytes.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 66000 -> 67000 by
# #1511 (2026-08-21): the "Never `--no-verify`" section's closing sentence
# asserted that the plugin manifest's `permissions.deny` block enforced the
# prohibition at the harness level. `permissions` is not among the documented
# `plugin.json` fields and the documented permission rule sources name no
# plugin-manifest tier, so the sentence was describing an unverified
# mechanism as a live one — the "documented but unenforced" shape #1506 was
# filed about for `git stash`. Replacing it costs more bytes than deleting
# it, because the correction has to do three things a one-liner can't: name
# the `refuse-hook-bypass-flag.sh` hook that IS the enforcement, record the
# manifest block's status as unverified rather than asserting it inert (the
# binary-reading evidence is strong but stops short of conclusive — an
# interactive `/permissions` check is still owed), and call out that
# `git push -n` is `--dry-run`, so a reader doesn't infer the hook refuses
# it. It stays in the always-loaded core for the same reason the rule above
# it does: every mode reads this section, and a worker reaching for a bypass
# flag is not going to detour into a fragment first. The file had 73 bytes
# of headroom after the edit; 67000 restores real headroom rather than none.
#
# issue-work.md's ceiling was raised 128000 -> 130000 by #1490 (2026-08-21):
# a fifth §5.5 decision-comment trigger (plus its routing-table row) telling
# a worker that narrows its own scope to honor an `Off-limits: <path>` line
# to report the narrowing as a divergence on both the PR and the issue. It
# can't be an on-demand fragment behind a trigger stub the way §6.5/§6.6/
# §6.7 are: the whole failure mode is that the narrowing feels routine, so a
# worker never recognizes a trigger condition to go load anything — the
# #1490 repro's worker reported its narrowing correctly and *unprompted*,
# which is exactly the luck this rule exists to stop depending on. It also
# can't fold into item 4 ("side-effect accepted or punted"), because the
# distinguishing instruction is behavioral, not just reportorial: honor the
# line as written, never work around it or inspect the peer's worktree to
# test whether the collision is real. The orchestrator-side half of the fix
# (never widen a peer's claimed_paths to a directory) lives in
# dispatch-rules.md and dont.md, both uncapped; the repro detail lives there
# too rather than here. The bullet was trimmed once to the terseness of the
# four existing items before the raise; the file had 0 bytes of headroom
# after #1334's raise, so even the trimmed bullet needed the bump.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 67000 -> 68000 by
# #1519 (2026-08-24): a new always-loaded "Never irreversibly mutate live
# external state — hand it back" section, plus its on-demand fragment's row
# in the fragment index. A worker deleted a Vercel Production env var while
# its own fix PR was still open — contradicting an explicit sequencing rule
# in that repo's CLAUDE.md — and justified the deviation only afterwards, in
# its return string. The rule cannot live behind a fragment stub alone: it
# has to be in context at the moment the worker forms the intent to run the
# command, and there is no trigger condition a stub could gate on (the whole
# failure mode is that the action feels justified). The section is trimmed
# to the terseness of the neighbouring "Never create a credential" rule and
# defers the taxonomy, carve-outs, and worked hand-back string to
# irreversible-external-action.md; the file had ~1073 bytes of headroom left
# after #1240's raise, and the section plus the index row needed the bump.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 68000 -> 69000 by
# #1558 (2026-09-17): a short always-loaded "Plain `git` refused as 'runs
# <launcher> with a git command among its operands'" section, plus its
# fragment's index row. On a host with a command-rewriting PreToolUse hook
# (RTK), every isolated worker had plain git calls refused and rediscovered
# the /usr/bin/git workaround on its own, at a cost of wasted tool calls on
# every dispatch. A fragment alone only helps a worker that already knows to
# look for it, so the one-line fix sits in the core where every worker sees
# it before its first refusal. The file had ~440 bytes of headroom after #1519's raise, and the
# trimmed section plus the row needed the bump. The detail lives in
# launcher-git-refusal.md.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 69000 -> 70000 by
# #1566 (2026-09-17): a short always-loaded "Invoke a helper script by
# direct exec — never `bash <script>`" section. This is the sibling of the
# #1558 raise directly above and lands for the same reason: it is a refusal
# every worker meets on its FIRST helper-script call, so a fragment alone
# only helps a worker that already knows to go looking. The two refusals are
# distinct (a launcher the host inserts vs. one the caller writes) and
# neither fix resolves the other, so a worker that hits one is likely to hit
# the other and needs both rules in front of it. The section was already
# trimmed once to fit — the measurement table, both carve-outs, and the
# scanner rationale all live in dont.md § "The launcher rule (#1566)" and
# do-work-RATIONALE.md rather than here. The file had ~378 bytes of overage
# against the old ceiling after that trim.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 70000 -> 72000 by
# #1554 (2026-09-17): a short always-loaded "Fan-out into your own worktree —
# verification does not delegate" section, plus its fragment's index row
# (~1470 bytes together, after trimming the section twice). It sits in the
# core rather than fragment-only because the trigger is a decision the worker
# makes, not an error it hits: a worker that has already decided to fan out
# has no reason to go looking for a fragment about fan-out, and the rules
# only bind subagents whose prompts were written with them in hand — i.e.
# they have to be in context BEFORE the dispatch, not after the first bad
# report. Everything that can be deferred already is: the lightwork #4666
# repro, the seven-point contract, the dispatch-prompt template, and the
# when-not-to-fan-out guidance all live in fan-out-verification.md
# (uncapped). The raise is 2000 rather than 1000 deliberately — 71000 would
# have left 154 bytes, the zero-margin state the #1562 note below warns the
# next editor about; 72000 restores ~1150 bytes of ordinary editing room.
#
# issue-work.md was NOT raised for #1519 (2026-08-24) — its one-line Don't-
# section mirror (the same shape #1166 added for "Never create a credential",
# repeated across all seven per-mode files) landed it at EXACTLY 130000
# bytes, i.e. zero headroom against the current ceiling. Noted here so the
# next editor of that file knows a red from this suite is expected on any
# addition, not a mystery: trim first, and raise only with a reason.
#
# issue-work.md's ceiling was raised 130000 -> 131000 by #1562 (2026-09-17):
# with the file at EXACTLY 130000 (the note above), any edit reds this suite,
# so this raise is the "trim first, then raise with a reason" path that note
# prescribes. The trim happened first and is why the cost is only ~272 bytes:
# the *explanation* of why a split dispatch is branched `do-work/slice-<N>`
# rather than `do-work/issue-<N>` lives in the orchestrator's conditional
# Context paragraph (dispatch-rules.md's split-dispatch branch-name
# augmentation) and in the on-demand issue-work-parent-epic-leak.md fragment
# — both reach the worker exactly when they apply — so the always-loaded
# spec carries only what it cannot omit: §3 can no longer hardcode
# `REMOTE_BRANCH="do-work/issue-<N>"` (it would contradict the dispatched
# branch and re-introduce the auto-link #893 documented), and §0's
# duplicate-PR cross-check has to match both shapes or it goes blind to a
# split dispatch's leftover PR. 131000 (not 130500) restores real headroom
# instead of the zero-byte margin that made this raise necessary.
#
# This file became the SOLE owner of these ceiling assertions by #1177
# (2026-08-09): commit-before-yield-1054.test.sh and
# detect-ci-gate-narrowing.test.sh had each grown their own mirrored copy of
# a subset of these same literals (with their own drifting raise-history
# comments), and the two copies had already gone out of sync once — the
# issue-work.md ceiling was raised to 121000 here but commit-before-
# yield-1054.test.sh's mirror still read 120000, costing a full fix-checks
# dispatch to diagnose on a P0 security PR. Both mirrors were pure defensive
# duplication (neither suite's own subject — the #1054 commit-before-yield
# invariant's content, the #1139 gate-narrowing pointer's content — has
# anything to do with file size) and were removed rather than reconciled via
# a shared constant: this suite already runs in the same CI job as every
# other `*.test.sh` on every PR (tests.yml's glob discovery), so there was
# never a coverage gap to fill, only a second place for the number to drift.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/spec-size-budget.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/../.." && pwd)"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_under_budget() {
  local file="$1"
  local ceiling="$2"
  local label="$3"

  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$file"
    fail=$((fail+1))
    return
  fi

  local size
  size=$(wc -c < "$file" | tr -d ' ')

  if (( size <= ceiling )); then
    printf '  %sPASS%s  %s (%d bytes, ceiling %d)\n' "$GREEN" "$RESET" "$label" "$size" "$ceiling"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    %d bytes exceeds the %d-byte ceiling (issue #980 — mandatory-load worker spec)\n' "$size" "$ceiling"
    printf '    this file loads on EVERY issue-work dispatch, unconditionally\n'
    printf '    fix: split the growth into an on-demand fragment (see issue-work-*.md for the pattern),\n'
    printf '         or if the growth is deliberate and reviewed, raise the ceiling in this test and say why\n'
    fail=$((fail+1))
  fi
}

echo "== always-loaded issue-work worker spec — per-file size budget (#980)"

assert_under_budget \
  "$plugin_root/agents/issue-worker/issue-work.md" \
  131000 \
  "agents/issue-worker/issue-work.md"

assert_under_budget \
  "$plugin_root/skills/worker-preamble/SKILL.md" \
  72000 \
  "skills/worker-preamble/SKILL.md"

assert_under_budget \
  "$plugin_root/agents/issue-worker.md" \
  12000 \
  "agents/issue-worker.md (mode router)"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
