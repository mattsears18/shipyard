#!/usr/bin/env bash
# crash-recovery-reap.sh — steady-state.md's A.0.5 "post-return worktree
# reap for crashed / narrative-non-terminal returns" (closes #358, #838,
# #833, #493, #495, #575), extracted to a script per issue #1291 (the
# deliberately-deferred follow-up to #1277/#1288/#1289).
#
# *** LOAD-BEARING CRASH-RECOVERY LOGIC — READ BEFORE EDITING ***
#
# This is the single largest and most complex compound block #1289 swept
# everywhere else in dispatch-rules.md/drain.md/inline-trivial.md/the rest
# of steady-state.md — deliberately deferred at that time (issue #1291) as
# too large and too safety-critical to rewrite in the same rushed pass as
# 17 smaller blocks. This extraction preserves the ORIGINAL block's control
# flow byte-for-byte in translation — every ordering decision, every guard,
# every recovery branch is unchanged; only the shell SHAPE changed (a
# ~360-line fenced ```bash block the harness's worktree-isolation guard
# refuses post-relocation -> a script the spec invokes as one plain
# command). Two invariants govern any future edit here:
#
#   - Never reap before inspecting. Every path below reads
#     `git rev-list --count` / `git status --porcelain` on the worktree
#     BEFORE any `git worktree remove`. A worker can stop mid-flight with a
#     fully correct, hook-validatable diff sitting uncommitted on disk;
#     reaping first destroys the only copy. See `dont.md`'s A.0.5 callout.
#   - The is_terminal gate is a no-op path, not a shortcut to skip. When
#     the caller's return text/harness status is genuinely terminal, this
#     script does NOTHING beyond printing `terminal=true` — no reap, no
#     recovery, no side effect of any kind. That's the "skip silently on
#     clean terminal returns" contract steady-state.md's prose documents.
#
# Why it's safe to force-reap on every classification including
# peer-alive: a return reaching this script is, by definition, a crash or
# a narrative-non-terminal stop (the stalled-worker resume path in
# steady-state.md's own prose — a SEPARATE, non-scripted judgment call the
# orchestrator makes BEFORE ever invoking this script — already diverted
# every resumable case away). The agent is non-recoverable; a still-alive
# subprocess holding the lock is exactly the failure mode #358 documents,
# not a signal to defer. See RATIONALE -> "A.0.5 peer-alive force-reap".
#
# Subcommand
# ----------
#
#   reap --repo <owner/repo> --slot-id <slot-id> --agent-id <agent-id>
#        --return-text <text> --harness-status <completed|failed>
#        [--slot-kind <kind>] [--slot-issue <N>] [--phase <phase>]
#
#     All arguments are literal values the orchestrator's own working
#     memory already holds (`.in_flight.<slot-id>` fields, the harness's
#     own task-notification) — this script never re-derives them from
#     session-state itself, mirroring how issue-work.md's own placeholders
#     (<N>, <owner/repo>) are filled in by whoever composes the call.
#
#     1. Runs the terminal-prefix check (case-insensitive match against
#        the six valid per-mode return prefixes: shipped/green/noop:/
#        blocked/rebased/reaped:), UNCONDITIONALLY non-terminal when
#        --harness-status is "failed" (the #833 stall-watchdog trigger) —
#        a text prefix that happens to look terminal is never trusted as a
#        real completion when the watchdog fired.
#     2. On a terminal result: prints `terminal=true` and exits 0. No
#        further action.
#     3. On a non-terminal result: derives the worktree path from
#        --agent-id, classifies its lock (worktree-reap.sh classify-lock),
#        and — only when --slot-kind is "issue" and --slot-issue is
#        non-empty and the worktree actually exists on disk — runs the
#        full pre-reap recovery (issues #493/#495/#575): detect
#        committed-but-unpushed work OR a dirty working tree, apply the
#        version-coordination bump when configured (best-effort — a
#        failed bump never blocks the push), push, create-or-reuse the PR,
#        arm auto-merge behind the ungated-admin-direct-merge detector
#        (issue #720), or defer to drain's merge lander on an ungated
#        repo.
#     4. Force-reaps the worktree unconditionally (no-lock/dead/
#        self-ancestor/peer-alive all reap here — issue #771's rationale)
#        via worktree-reap.sh's single-source-of-truth reap helper, then
#        `git worktree prune`. That reap passes
#        `--bypass-return-check` (issue #1237): worktree-reap.sh otherwise
#        refuses to reap an `agent-*` worktree without a persisted
#        `.returned_agent_ids` record proving the agent's own terminal
#        return reached the orchestrator's reconcile — a record a crashed
#        worker by definition never wrote. The bypass is hardcoded, not a
#        flag on this script's own command line, because step 2 above
#        returns early on every terminal case: EVERY reap this script
#        performs is the documented crash-recovery exception.
#     5. Prints exactly one result line to stdout so the caller's
#        SEPARATE, later verify-the-reap-happened call (issue #1274 — a
#        classifier denial of THIS call kills the whole tool call before
#        any code in it can run, so the verify has to be a genuinely
#        separate call, and shell variables don't survive across those —
#        the caller substitutes these literal values into that next call)
#        and the wasted-dispatch / stalled-dispatch bookkeeping (both of
#        which remain orchestrator in-session working memory, not
#        something a stateless script invocation can own) can parse it:
#
#          terminal=true
#        or
#          terminal=false worktree_path=<path> worktree_name=<name> \
#            classification=<classification-or-empty> lock_pid=<pid-or-empty> \
#            session_id=<sid-or-unknown> recovered_pr=<M-or-empty>
#
#     Every recovery step (version-bump, push, PR-create, auto-merge arm,
#     the reap itself) is fire-and-forget — `2>/dev/null` and/or `|| true`
#     — matching the original block's posture exactly. A failed recovery
#     step is logged (stdout, `[reconcile-A.0.5-recovery]` prefix) but
#     never aborts the reap.
#
# Testability: every `gh` invocation goes through `"$GH"` (default `gh`,
# overridable via the GH env var), matching drain-pre-dispatch-branch-reap.sh's
# convention — a test suite can stub it without a live GitHub token.
#
# Exit codes: 0 always (fire-and-forget on every path once args validate);
# 64 bad usage; 65 missing dependency (jq).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  crash-recovery-reap.sh reap --repo <owner/repo> --slot-id <slot-id>
      --agent-id <agent-id> --return-text <text>
      --harness-status <completed|failed>
      [--slot-kind <kind>] [--slot-issue <N>] [--phase <phase>]
EOF
}

require_jq "crash-recovery-reap.sh"

GH="${GH:-gh}"

# ---------------------------------------------------------------------------
# a05_version_bump — shared version-coordination bump helper (#575). Applies
# the manifest version bump + CHANGELOG stub directly into the worktree's
# working tree (file edits only — does NOT commit). The caller is
# responsible for staging and committing (dirty-worktree path folds it into
# the auto-commit; committed-but-unpushed path adds a dedicated bump
# commit).
#
# Usage: a05_version_bump "$worktree_path" "$default_branch" "$slot_issue" "$repo"
# Sets (globals, not local — the caller reads them after the call):
#   a05_bump_applied=true|false, a05_bump_version, vc_manifest, vc_changelog
# ---------------------------------------------------------------------------
a05_version_bump() {
  local wt="$1" defbr="$2" issue_num="$3" repo="$4"
  a05_bump_applied=false
  a05_bump_version=""

  # Read coordination config. Fire-and-forget: any failure -> skip.
  local vc_enabled
  vc_enabled=$("${here}/shipyard-config.sh" get version_coordination.enabled 2>/dev/null || echo "false")
  [ "$vc_enabled" != "true" ] && return 0

  vc_manifest=$("${here}/shipyard-config.sh" get version_coordination.manifest_path 2>/dev/null || echo "")
  [ -z "$vc_manifest" ] && return 0

  local vc_version_jq
  vc_version_jq=$("${here}/shipyard-config.sh" get version_coordination.manifest_version_jq 2>/dev/null || echo ".version")
  vc_changelog=$("${here}/shipyard-config.sh" get version_coordination.changelog_path 2>/dev/null || echo "")

  # Read the manifest version from origin/<default> (the floor).
  local origin_version
  origin_version=$("$GH" api "repos/${repo}/contents/${vc_manifest}?ref=${defbr}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | jq -r "$vc_version_jq" 2>/dev/null || echo "")
  if [ -z "$origin_version" ]; then
    echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (could not read origin manifest version for ${vc_manifest})"
    return 0
  fi

  # Read the manifest version from the worktree (HEAD for committed path,
  # working tree file for dirty path — reading the file directly covers both).
  local wt_version
  wt_version=$(jq -r "$vc_version_jq" "${wt}/${vc_manifest}" 2>/dev/null || echo "")
  if [ -z "$wt_version" ]; then
    echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (could not read worktree manifest version for ${vc_manifest})"
    return 0
  fi

  # Only bump when the worktree version equals the origin version — i.e.,
  # the worker never reached its own bump step. If they differ, the worker
  # already bumped (or partially bumped); don't overwrite.
  if [ "$wt_version" != "$origin_version" ]; then
    echo "[reconcile-A.0.5-recovery] version-bump: worktree already at ${wt_version} (origin=${origin_version}); skipping bump"
    return 0
  fi

  # Infer the release bump LEVEL from the recovered issue's Conventional
  # Commits signals (#671) — the same bump-type-awareness as the
  # dispatch-time next-available-version computation in dispatch-rules.md.
  # A patch-only bump stamps a semver-wrong version on a recovered PR whose
  # issue requires a major (breaking) or minor (feature) release. Best-effort:
  # a failed title/body read falls back to the patch default.
  local a05_title a05_body a05_level
  a05_title=$("$GH" issue view "$issue_num" --repo "$repo" --json title -q .title 2>/dev/null || echo "")
  a05_body=$("$GH" issue view "$issue_num" --repo "$repo" --json body -q .body 2>/dev/null || echo "")
  a05_level="patch"
  grep -qiE '^[[:space:]]*feat(\([^)]*\))?[[:space:]]*:' <<< "$a05_title" && a05_level="minor"
  if grep -qiE '^[[:space:]]*[a-z]+(\([^)]*\))?!:' <<< "$a05_title" \
     || grep -qiE 'BREAKING[ -]CHANGE|major version bump|\(X\.0\.0\)' <<< "$a05_title"$'\n'"$a05_body"; then
    a05_level="major"
  fi

  # Compute next_ver = origin_version bumped at the inferred level
  # (major -> (X+1).0.0, minor -> X.(Y+1).0, patch -> X.Y.(Z+1)).
  local vc_maj vc_min vc_pat next_ver
  IFS='.' read -r vc_maj vc_min vc_pat <<< "$origin_version"
  case "$a05_level" in
    major)   next_ver="$((vc_maj + 1)).0.0" ;;
    minor)   next_ver="${vc_maj}.$((vc_min + 1)).0" ;;
    patch|*) next_ver="${vc_maj}.${vc_min}.$((vc_pat + 1))" ;;
  esac

  # Apply the version bump to the manifest file in the worktree. Use jq to
  # rewrite the file in-place (temp-file dance for safety).
  local jq_script tmp_manifest
  jq_script="$(printf '%s = "%s"' "$vc_version_jq" "$next_ver")"
  tmp_manifest="$(mktemp)"
  if jq "$jq_script" "${wt}/${vc_manifest}" > "$tmp_manifest" 2>/dev/null && [ -s "$tmp_manifest" ]; then
    mv "$tmp_manifest" "${wt}/${vc_manifest}" 2>/dev/null || rm -f "$tmp_manifest"
  else
    rm -f "$tmp_manifest"
    echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (jq write failed for ${vc_manifest})"
    return 0
  fi

  # Prepend a minimal CHANGELOG stub (when changelog_path is configured).
  if [ -n "$vc_changelog" ] && [ -f "${wt}/${vc_changelog}" ]; then
    local today stub tmp_cl
    today=$(date -u +%Y-%m-%d)
    stub="### ${next_ver} — ${today}

Crash-recovered by orchestrator A.0.5 (#575). Worker stalled before completing release bump for issue #${issue_num}. Verify acceptance criteria are met.

"
    tmp_cl="$(mktemp)"
    if { printf '%s' "$stub"; cat "${wt}/${vc_changelog}"; } > "$tmp_cl" 2>/dev/null; then
      mv "$tmp_cl" "${wt}/${vc_changelog}" 2>/dev/null || rm -f "$tmp_cl"
    else
      rm -f "$tmp_cl"
    fi
  fi

  a05_bump_applied=true
  a05_bump_version="$next_ver"
  echo "[reconcile-A.0.5-recovery] version-bump: applied ${origin_version} → ${next_ver} to ${vc_manifest}${vc_changelog:+ and ${vc_changelog}}"
}

cmd_reap() {
  local repo="" slot_id="" agent_id="" return_text="" harness_status=""
  local slot_kind="" slot_issue="" phase="reconcile-A.0.5"

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --slot-id) slot_id="${2:-}"; shift 2 ;;
      --agent-id) agent_id="${2:-}"; shift 2 ;;
      --return-text) return_text="${2:-}"; shift 2 ;;
      --harness-status) harness_status="${2:-}"; shift 2 ;;
      --slot-kind) slot_kind="${2:-}"; shift 2 ;;
      --slot-issue) slot_issue="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      *) echo "crash-recovery-reap.sh reap: unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
  done

  if [ -z "$repo" ] || [ -z "$slot_id" ] || [ -z "$agent_id" ] || [ -z "$harness_status" ]; then
    echo "crash-recovery-reap.sh reap: --repo, --slot-id, --agent-id, and --harness-status are required" >&2
    usage >&2
    exit 64
  fi

  # Re-derive & re-export the SHIPYARD_REPO_ROOT pin from the step-0.56
  # stash (issue #1059/#1064) — the version-coordination + auto_merge.method
  # reads below would otherwise silently drop .shipyard/config.local.json
  # post-relocation. Derived from the CURRENT cwd's toplevel — the caller is
  # expected to invoke this script from the orchestrator's own worktree,
  # where the .shipyard-primary-root stash lives (same assumption the
  # original inline block made).
  local SHIPYARD_REPO_ROOT
  SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel 2>/dev/null)/.shipyard-primary-root" 2>/dev/null)
  [ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  export SHIPYARD_REPO_ROOT

  # Terminal-prefix check — case-insensitive match against the six valid
  # prefixes from the per-mode return contracts. Skipped entirely when
  # harness_status == "failed": the watchdog firing means this dispatch
  # never reached its own terminal return, so a text prefix that happens to
  # look terminal is not trusted as a real completion (#833).
  local is_terminal=false
  if [ "$harness_status" != "failed" ]; then
    case "$return_text" in
      shipped*|green*|noop:*|blocked*|rebased*|reaped:*)
        is_terminal=true
        ;;
    esac
  fi

  if [ "$is_terminal" = "true" ]; then
    echo "terminal=true"
    exit 0
  fi

  # Crash / narrative-non-terminal / harness-failed — fire the reap.
  local log_prefix
  log_prefix="${return_text:0:80}"
  echo "[reconcile-A.0.5] non-terminal stop for slot=${slot_id} agent=${agent_id} harness_status=${harness_status}: \"$log_prefix\"; firing post-return inspect-before-reap (#358/#838/#833)"

  local completed_agent_id="$agent_id"
  local wt_dir=".git/worktrees/agent-${completed_agent_id}"
  local worktree_path
  worktree_path="$(git rev-parse --show-toplevel)/.claude/worktrees/agent-${completed_agent_id}"

  local classification="" lock_pid="" recovered_pr=""

  # In-flight guard (issue #832) — NOT applicable as an exclusion here, and
  # that's intentional. Unlike the sweep-style reap sites, this script never
  # scans `.git/worktrees/agent-*` for candidates — it targets exactly ONE
  # worktree: --agent-id's own worktree, and only because THIS slot's agent
  # has already returned (even if the return itself is crash-like /
  # non-terminal). The harness's own completion notification — not
  # classify-lock's PID check — is the authoritative liveness signal here.
  if [ -d "$wt_dir" ]; then
    # Bootstrap the orchestrator PID so classify-lock can short-circuit on
    # our own session's locks (issue #263 — same pattern as A.1/B's reaps).
    export SHIPYARD_ORCHESTRATOR_PID
    SHIPYARD_ORCHESTRATOR_PID=$("${here}/session-identity.sh" detect-orchestrator-pid)

    classification=$("${here}/worktree-reap.sh" classify-lock "$wt_dir/locked")

    # Anchor on the literal `pid` keyword, not "first digit-run before a
    # close-paren" — the latter misparses a real `(pid <N> start <ctime>)`
    # lock as the ctime's trailing year (issue #1206). Same fix as
    # worktree-reap.sh's own extract_lock_pid helper.
    local lock_pid_match
    lock_pid_match=$(grep -m1 -oE '\(pid[[:space:]]+[0-9]+' "$wt_dir/locked" 2>/dev/null)
    lock_pid="${lock_pid_match//[!0-9]/}"
    [ -z "$lock_pid" ] && lock_pid="null"

    # Pre-reap recovery check (#493): before reaping, check whether the
    # crashed worker left committed work that hasn't been pushed yet. This
    # only applies to issue-work dispatches (slot_kind == "issue") since
    # those are the only ones with a named do-work/issue-<N> (or, on a split
    # dispatch, do-work/slice-<N> — issue #1562) branch and a linked issue to
    # recover against.
    if [ "$slot_kind" = "issue" ] && [ -n "$slot_issue" ] && [ -d "$worktree_path" ]; then
      local DEFAULT_BRANCH ahead_count push_ok=""
      local recovery_branch recovery_is_slice="false"
      DEFAULT_BRANCH=$("$GH" repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "main")

      # Recover onto the branch this worktree ACTUALLY holds, not a
      # hardcoded `do-work/issue-<N>` (issue #1562). Two dispatches don't
      # carry that name: a split dispatch (operator_residual /
      # verification_slice) is branched `do-work/slice-<N>` so its PR can't
      # auto-link to the issue it must not close, and issue-work.md §3's
      # worktree-name-collision fallback checks out
      # `do-work/issue-<N>-<epoch>` locally while pushing to the canonical
      # remote name. Reading HEAD covers both; the canonical name stays the
      # fallback for a detached/unreadable HEAD.
      recovery_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      case "$recovery_branch" in
        ""|HEAD)                             recovery_branch="do-work/issue-${slot_issue}" ;;
        do-work/issue-${slot_issue}-[0-9]*)  recovery_branch="do-work/issue-${slot_issue}" ;;
        do-work/slice-*)                     recovery_is_slice="true" ;;
      esac
      # Fetch so origin/<default> ref is current.
      git -C "$worktree_path" fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
      ahead_count=$(git -C "$worktree_path" rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "0")

      local a05_bump_applied="false" a05_bump_version="" vc_manifest="" vc_changelog=""

      if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        echo "[reconcile-A.0.5-recovery] slot=${slot_id} issue=#${slot_issue} has ${ahead_count} committed-but-unpushed commit(s); attempting pre-reap recovery (#493)"

        # Step 1.5: version-coordination bump (#575). The committed work may
        # not include the manifest bump (worker crashed before reaching it).
        # Apply the bump as an additional commit on top of the existing
        # commits, before pushing. Fire-and-forget: failure logs an
        # advisory and we push the PR anyway so the worker's real work
        # isn't lost.
        a05_version_bump "$worktree_path" "$DEFAULT_BRANCH" "$slot_issue" "$repo"
        if [ "$a05_bump_applied" = "true" ]; then
          git -C "$worktree_path" add "$vc_manifest" ${vc_changelog:+"$vc_changelog"} 2>/dev/null || true
          git -C "$worktree_path" commit --no-verify \
            -m "chore: release bump ${a05_bump_version} for issue #${slot_issue} (orchestrator A.0.5 recovery #575)" \
            2>/dev/null || true
        fi

        # Step 2: push the branch. Pre-commit hooks already passed (the
        # commit succeeded); this is an orchestrator-side recovery push on
        # a dead agent's branch.
        local push_out push_ok_local
        # `HEAD:refs/heads/<name>` rather than a bare local refname: in the
        # §3 collision-fallback case the local branch is
        # `do-work/issue-<N>-<epoch>` while the canonical remote name is
        # `do-work/issue-<N>`, so a bare push of the latter would fail with
        # "src refspec does not match any" (issue #1562).
        if push_out=$(git -C "$worktree_path" push origin "HEAD:refs/heads/${recovery_branch}" 2>&1); then
          push_ok_local=true
        else
          push_ok_local=false
        fi
        push_ok="$push_ok_local"
        echo "[reconcile-A.0.5-recovery] push ${recovery_branch}: ok=${push_ok} (${push_out:0:120})"

      elif [ -n "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]; then
        # Dirty-working-tree recovery (#495): the worker crashed/stalled
        # before committing, but left edits in the working tree. Stage all
        # changes and commit with --no-verify (the pre-commit gate may be
        # exactly what hung the worker; CI is the real gate for an
        # uncommitted-worktree recovery). Mirrors the #493
        # committed-but-unpushed path: auto-commit first, then fall through
        # to the shared push+PR-create+auto-merge block below.
        echo "[reconcile-A.0.5-recovery] slot=${slot_id} issue=#${slot_issue} has dirty working tree but no commits; attempting dirty-worktree auto-commit recovery (#495)"

        # Step 1.5: version-coordination bump (#575). Apply the bump to the
        # working tree files before staging so it folds into the
        # auto-commit. Fire-and-forget: failure logs an advisory; the
        # auto-commit proceeds with whatever working-tree files the worker
        # left.
        a05_version_bump "$worktree_path" "$DEFAULT_BRANCH" "$slot_issue" "$repo"

        # `${a05_bump_applied:+...}` tests for non-emptiness, not for the
        # value "true" — a05_version_bump always sets a05_bump_applied to
        # the literal string "true" or "false" (never empty), so that form
        # would emit the release-bump clause even when no bump was applied
        # (issue #1298). Build the clause explicitly instead.
        local a05_bump_suffix=""
        if [ "$a05_bump_applied" = "true" ]; then
          a05_bump_suffix=", release bump ${a05_bump_version} #575"
        fi

        git -C "$worktree_path" add -A 2>/dev/null || true
        local autocommit_out autocommit_ok autocommit_sha
        if autocommit_out=$(git -C "$worktree_path" commit --no-verify \
          -m "fix: crash-recovery auto-commit for issue #${slot_issue} (orchestrator A.0.5 #495${a05_bump_suffix})" \
          2>&1); then
          autocommit_ok=true
        else
          autocommit_ok=false
        fi
        autocommit_sha=$(git -C "$worktree_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "[reconcile-A.0.5-recovery] dirty-worktree auto-commit: ok=${autocommit_ok} sha=${autocommit_sha} (${autocommit_out:0:120})"

        if [ "$autocommit_ok" = "true" ]; then
          local push_out2 push_ok_local2
          if push_out2=$(git -C "$worktree_path" push origin "HEAD:refs/heads/${recovery_branch}" 2>&1); then
            push_ok_local2=true
          else
            push_ok_local2=false
          fi
          push_ok="$push_ok_local2"
          echo "[reconcile-A.0.5-recovery] push ${recovery_branch}: ok=${push_ok} (${push_out2:0:120})"
        else
          push_ok=false
        fi
      fi

      # Shared PR-create + auto-merge block for both committed-but-unpushed
      # (#493) and dirty-worktree auto-commit (#495) recovery paths.
      # push_ok is set by whichever branch above ran; if neither ran (no
      # committed work AND clean working tree) push_ok is unset — guard
      # with a default to avoid an unbound-variable error under set -u.
      push_ok="${push_ok:-false}"
      if [ "$push_ok" = "true" ]; then
          # Step 2: check whether an open PR already exists for this branch.
          local existing_pr
          existing_pr=$("$GH" pr list --repo "$repo" --state open \
            --head "${recovery_branch}" \
            --json number --jq '.[0].number // empty' 2>/dev/null || true)

          local pr_ok="" recovered_title recovered_body
          # A `do-work/slice-<N>` branch is a split dispatch: its PR ships a
          # partial slice and must NOT close #<N> (issue #1562). Reference the
          # issue by bare URL with no closing keyword and no bare `#<N>` token
          # anywhere in the title or body — #624's auto-promotion hazard — so
          # crash recovery can't close an issue the dispatch deliberately left
          # open. Every other recovery keeps the closing keyword unchanged.
          if [ "$recovery_is_slice" = "true" ]; then
            recovered_title="fix: crash-recovered partial slice for issue ${slot_issue}"
            recovered_body=$(printf 'Ships a partial slice of https://github.com/%s/issues/%s, which stays open.\n\n## Summary\nCrash-recovered by orchestrator A.0.5 pre-reap recovery (#493/#495) from a split dispatch (branch %s, issue #1562). Worker crashed/stalled before or after committing. Deliberately carries NO closing keyword — a human must disposition the residual on the linked issue.\n\n## Test plan\n- [ ] Verify which acceptance criteria this slice actually covers, and what residual remains\n' "$repo" "$slot_issue" "$recovery_branch")
          else
            recovered_title="fix: crash-recovered work for issue #${slot_issue}"
            recovered_body=$(printf 'Closes #%s\n\n## Summary\nCrash-recovered by orchestrator A.0.5 pre-reap recovery (#493/#495). Worker crashed/stalled before or after committing. CI is the safety net for uncommitted-worktree recoveries.\n\n## Test plan\n- [ ] Verify acceptance criteria from #%s are met\n' "$slot_issue" "$slot_issue")
          fi
          if [ -z "$existing_pr" ]; then
            # No PR yet — create one with the standard issue-work template.
            if recovered_pr=$("$GH" pr create \
              --repo "$repo" \
              --head "${recovery_branch}" \
              --label shipyard \
              --title "$recovered_title" \
              --body "$recovered_body" \
              2>/dev/null); then
              pr_ok=true
            else
              pr_ok=false
            fi
            echo "[reconcile-A.0.5-recovery] gh pr create: ok=${pr_ok} pr=${recovered_pr}"
          else
            recovered_pr="$existing_pr"
            pr_ok=true
            echo "[reconcile-A.0.5-recovery] PR #${existing_pr} already open for ${recovery_branch}; skipping create"
          fi

          if [ "$pr_ok" = "true" ] && [ -n "$recovered_pr" ]; then
            # Step 3: arm auto-merge and snapshot, exactly as step 6-7 of
            # issue-work.md. Fire-and-forget — recovery must not block reap.
            #
            # #720: gate the arm behind the ungated-merge detector. A
            # recovered PR may have been auto-committed with --no-verify
            # from a dirty worktree, so CI is the ONLY thing that ever
            # validates it. On an ungated repo --auto is not a queue — it
            # direct-merges that unvalidated diff immediately, and the
            # `2>/dev/null || true` below makes it silent. Fail-safe: an
            # unreadable verdict resolves to `ungated` (defer), never to an
            # immediate merge.
            local verdict auto_merge_method
            verdict=$(bash "${here}/detect-ungated-admin-direct-merge.sh" \
              "$repo" 2>/dev/null || echo ungated)
            # Resolve the merge method from config — never hardcode --merge
            # (#989). Repo policy, not a literal to copy verbatim.
            auto_merge_method=$("${here}/shipyard-config.sh" get auto_merge.method 2>/dev/null)
            case "$auto_merge_method" in squash|merge|rebase) ;; *) auto_merge_method=squash ;; esac
            if [ "$verdict" = "gated" ]; then
              # Capture stderr instead of discarding it (#850) — the same
              # missing-workflow-OAuth-scope block a worker's own arm can
              # hit (worker-preamble auto-merge.md step 1.1, #812) can hit
              # this reconcile-turn arm too.
              local merge_arm_err
              merge_arm_err=$("$GH" pr merge "$recovered_pr" --repo "$repo" --auto --"${auto_merge_method}" --delete-branch 2>&1 1>/dev/null) || true
              if grep -qi "without .workflow. scope" <<< "$merge_arm_err"; then
                echo "[reconcile-A.0.5-recovery] PR #${recovered_pr} auto-merge arm blocked — gh token lacks workflow scope (#850); left OPEN unarmed"
              fi
            else
              # Leave OPEN + unarmed. The caller's session_prs append hands
              # it to drain's deferred-merge lander, which merges it once
              # CI is green. Do NOT `gh pr checks --watch` here — this is
              # the reconcile hot path and a block would stall every
              # in-flight dispatch.
              echo "[reconcile-A.0.5-recovery] PR #${recovered_pr} left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
            fi
            # Snapshot state for the log line.
            local snap
            snap=$("$GH" pr view "$recovered_pr" --repo "$repo" \
              --json state,autoMergeRequest \
              --jq '{state, autoMerge: (.autoMergeRequest != null)}' 2>/dev/null || echo '{}')
            echo "[reconcile-A.0.5-recovery] PR #${recovered_pr} snapshot: ${snap}"
          fi
      fi
    fi
  fi

  # Anchor cwd to a stable directory BEFORE the reap (issue #497). The
  # harness can leak the orchestrator's Bash-tool cwd into the very
  # agent-* worktree we're about to `git worktree remove --force`; once
  # that directory is gone, EVERY subsequent bare git command in this
  # script (the prune below, any follow-up fetch/log) fails with
  # `fatal: Unable to read current working directory`. `git rev-parse
  # --show-toplevel` can't rescue it either — git resolves its own cwd
  # before reading anything, so it fails first. The fix is to `cd` away
  # from the doomed directory while cwd is STILL valid (here, before the
  # remove). Derive the anchor cwd-independently via the #477 porcelain
  # idiom — orchestrator worktree first, primary (first `worktree ` entry)
  # as fallback — so we never re-derive from the leaked cwd. `cd /` is the
  # last-resort floor (any extant dir works; the reap uses absolute paths).
  local STABLE_DIR
  STABLE_DIR=$(awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}' \
    <(git worktree list --porcelain 2>/dev/null))
  [ -z "$STABLE_DIR" ] && STABLE_DIR=$(awk '/^worktree /{print substr($0,10); exit}' \
    <(git worktree list --porcelain 2>/dev/null))
  cd "${STABLE_DIR:-/}" 2>/dev/null || cd /
  # Derive the session id cwd-independently after anchoring to STABLE_DIR.
  # Closes #548: the reap's --session-id must come from the orchestrator
  # worktree stash, not from a bare `cat .shipyard-session-id` that reads
  # from the (possibly leaked-to-agent) cwd.
  local REPO_ROOT SESSION_ID
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${here}/session-identity.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  [ -z "$SESSION_ID" ] && echo "[session-id-derive] empty — A.0.5 reap audit-log entry will lack session-id; check for #477 cwd-leak (#548)"

  # Crash-aware reap: reaps on every classification including peer-alive
  # (issue #771) — the agent is non-recoverable by definition (it crashed
  # or violated the return contract); a still-alive subprocess holding the
  # lock is exactly the failure mode #358 documents, not a signal to wait.
  # The audit-log entry records the actual classification so the override
  # is traceable.
  #
  # --bypass-return-check (issue #1237): worktree-reap.sh's reconciled-return
  # gate refuses `reap --action reaped` on an `agent-*` worktree unless this
  # session's persisted `.returned_agent_ids` records that agent's own
  # terminal return. This IS the crash path — control only reaches here on
  # the `terminal=false` branch, i.e. precisely when the worker stopped
  # WITHOUT a terminal return (crash, stall-watchdog kill, exhausted
  # resume), so steady-state.md's A.1 return-record write never ran for this
  # agent and never will. Requiring the record here would not harden
  # anything; it would break the crash recovery A.0.5 exists to provide.
  # The reason string is fixed rather than a caller-supplied flag: every
  # reap this script performs is by construction this same exception (the
  # `terminal=true` path returns early having reaped nothing), so exposing
  # it on the command line would only add a way for A.0.5 to get it wrong.
  "${here}/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "agent-${completed_agent_id}" \
    --session-id "${SESSION_ID:-unknown}" \
    --classification "$classification" \
    --lock-pid "$lock_pid" \
    --bypass-return-check "crash-recovery reap (#1237) — worker never reached a terminal return" \
    --phase "$phase" 2>/dev/null || true
  git worktree prune 2>/dev/null || true

  echo "terminal=false worktree_path=${worktree_path} worktree_name=agent-${completed_agent_id} classification=${classification} lock_pid=${lock_pid} session_id=${SESSION_ID:-unknown} recovered_pr=${recovered_pr}"
  exit 0
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  reap)
    cmd_reap "$@"
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "crash-recovery-reap.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac
