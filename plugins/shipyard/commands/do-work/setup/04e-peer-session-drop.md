# /shipyard:do-work — Setup phase · peer-claimed backlog drop

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Drop peer-claimed issues/PRs" bullet. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why this fragment exists ([#1204](https://github.com/mattsears18/shipyard/issues/1204))

Nothing in setup, dispatch, or drain previously looked for a peer `/shipyard:do-work` session on the same repo. Two sessions started ~13 minutes apart both fetched the same backlog, ranked it identically (ranking is deterministic), and both dispatched a worker against the **same issue** at the same time — one opened and merged a PR while the other's worker kept implementing against an issue that had already closed. Each duplicate dispatch costs a full worker run for nothing. Self-assign (step 1) is not a lock against this: both sessions assign as the *same* `gh`-authenticated user, so the "don't work issues assigned to other users" check sees its own login and passes.

## The check (setup step 1.65)

[`01-repo-recovery.md`'s step 1.65](./01-repo-recovery.md#165-detect-live-peer-sessions-on-this-repo-1204) runs [`scripts/detect-peer-sessions.sh`](../../../scripts/detect-peer-sessions.sh) once, at setup, against `$SHIPYARD_HOME/sessions/*.json` — the same directory [step 1.6](./01-repo-recovery.md#16-reap-orphan-session-files-cost-ledger-recovery)'s orphan-file sweep already globs, walked here for the opposite purpose (finding LIVE peers, not stale ones). A session file counts as a live peer when its mtime is within the freshness window (default 30 minutes — the same floor step 1.6 already uses to decide staleness, not a new threshold) AND its `.repo` field matches this repo. The script prints one `peer: <id> claimed=<N,N,...>` line per live peer plus a `summary: peers=<P> claimed_targets=<N,N,...>` line — the deduped union of every live peer's `.in_flight[].target` set. Step 1.65 writes the result through as `.peer_sessions = { count, claimed_targets, checked_at }` in the session-state file and holds it for the rest of the session (same posture as `trusted_authors` and `operator=` — resolved once at startup, never re-resolved mid-session).

**Blind spot — sessions without a session file ([#1606](https://github.com/mattsears18/shipyard/issues/1606)).** This check reads only `$SHIPYARD_HOME/sessions/*.json`, so a peer that doesn't write one (a plain Claude Code session dispatching its own `shipyard:issue-worker` agents) always counts as `peers=0`. The tool-agnostic backstop is the per-dispatch [remote in-flight-claim guard](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) (`scripts/remote-claim-check.sh`), which checks the remote for an open PR or freshly pushed branch on the issue immediately before each dispatch.

## The drop (here, in step 4)

After the wide fetch, drop any candidate issue whose number appears in `.peer_sessions.claimed_targets`:

```bash
CANDIDATE_NUMBER="<candidate issue number from the fetched list>"
if printf '%s\n' "${PEER_CLAIMED_TARGETS:-}" | tr ',' '\n' | grep -qx "$CANDIDATE_NUMBER"; then
  # drop — a live peer session already has this issue/PR in its own
  # in_flight set; dispatching against it duplicates that peer's work.
  continue
fi
```

`PEER_CLAIMED_TARGETS` is `.peer_sessions.claimed_targets` read back from session state (or held from step 1.65's own output in the same setup pass). This is the highest-value half of the fix — it directly prevents the #1201-style duplicate dispatch — and is intentionally the *only* new drop rule: it excludes a peer's already-claimed targets from `raw_backlog`, it does not touch anything else about how the backlog is ranked or fetched.

## Fully-overlapping peer: warn-and-continue, not halt-and-ask

When a live peer's claimed set happens to cover most or all of this session's would-be `raw_backlog` (a realistic case precisely *because* ranking is deterministic — two sessions on a quiet backlog tend to converge on the same top candidates), the remaining, unclaimed backlog is dispatched normally; if nothing remains, the session proceeds exactly as it does on any other empty-backlog turn (idle-proof invariant line, eventual drain) — it does **not** halt and ask the user to confirm before continuing.

This resolves an apparent tension in [`dont.md`](../dont.md): the orphan-triage line ("If you suspect a parallel session, ask the user") and the standing "don't ask the user 'should I keep working?'" rule pull in opposite directions on a plain reading. They don't actually conflict once scoped by what's at stake. Orphan triage's ask-the-user rule guards a **destructive, irreversible** action — reaping (removing) a worktree that might belong to a live sibling — where a wrong autonomous guess destroys real work. Backlog-claim exclusion is the opposite shape: it is **advisory and reversible** — worst case, the exclusion is overly conservative for one session and the skipped candidate is picked up next session (or by this session once the peer's claim ages out). Halting an entire session to ask "should I proceed?" over a reversible, cost-saving filter is exactly the pattern the "don't ask, keep working" rule and [#531](https://github.com/mattsears18/shipyard/issues/531)'s "attempt-then-escalate, never escalate-without-attempting" rule both forbid. Continuing on the unclaimed remainder — or idling normally when none remains — is therefore the correct default, and it is the one this fragment implements.
