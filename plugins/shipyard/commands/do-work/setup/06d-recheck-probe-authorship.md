# /shipyard:do-work — Step 6, deferred entries 4c: automated `do-work-recheck` probe authorship

Deep-linked from [`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) step 4c — read this file only when you reach that pointer, not as part of the ordered per-session walk.

## Why this exists

[#1198](https://github.com/mattsears18/shipyard/issues/1198) shipped `scripts/eval-recheck-probe.sh` — an allowlist-only evaluator for a human-authored `<!-- do-work-recheck: <verb> <args...> -->` body marker that lets the proactive operator sweep test a blocking condition mechanically instead of only waiting out the `<!-- do-work-blocked-until: YYYY-MM-DD -->` calendar gate [#1195](https://github.com/mattsears18/shipyard/issues/1195) added for `time-gated` (and, once [#1199](https://github.com/mattsears18/shipyard/issues/1199) landed, `external-dependency`) defers. That slice deliberately left the marker human-authored only. This step ([#1201](https://github.com/mattsears18/shipyard/issues/1201)) is the automated write-time half: it lets the scope agent's own `evidence_pointer` optionally seed the marker when the blocking condition is mechanically checkable.

**Widened beyond `external-dependency` ([#1356](https://github.com/mattsears18/shipyard/issues/1356)).** The original slice scoped this step to `external-dependency` only, reasoning that `time-gated` "has no upstream fact to probe, only a date." In practice a scope agent (or a human hand-authoring the `Time-gate:` evidence) sometimes reaches for `time-gated` precisely because the real blocking condition is an unforecastable EVENT rather than a genuine calendar constraint — a still-open cooldown with a known lapse instant is a true time gate, but "once real users leave written store reviews" or "once an Expo SDK bump moves metro" are events wearing a placeholder date, and forcing them through `external-dependency` just to get a probe is an artificial classification tax. This step now fires for either class whenever the `evidence_pointer` happens to carry a recognized probe hint — see "Marker-syntax distinction" below for what pairing the two markers actually changes about how the issue is re-evaluated.

## Trigger

Runs immediately after [step 4a/4b](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)'s calendar marker write, and **only** when both hold:

- `$DEFER_REASON_CLASS` is `external-dependency` OR `time-gated` (issue [#1356](https://github.com/mattsears18/shipyard/issues/1356) — any defer class that wrote a `do-work-blocked-until` marker at step 4a/4b can optionally carry a companion probe; no other class writes that marker, so no other class reaches this step).
- The merged-config knob `scope.recheck_probe_enabled` is `true` (the default — same knob the read side checks; skip this step entirely when it's `false`, since a marker written while the read side is disabled would sit dead).

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
export SHIPYARD_REPO_ROOT="<primary-root literal>"
RECHECK_ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get scope.recheck_probe_enabled 2>/dev/null || echo true)
if { [ "$DEFER_REASON_CLASS" != "external-dependency" ] && [ "$DEFER_REASON_CLASS" != "time-gated" ]; } || [ "$RECHECK_ENABLED" != "true" ]; then
  : # not applicable — skip this step entirely, calendar-only behavior unchanged
fi
```

## Marker-syntax distinction — what `do-work-blocked-until` alone vs. paired with `do-work-recheck` means ([#1356](https://github.com/mattsears18/shipyard/issues/1356))

- **`do-work-blocked-until: <date>` alone is a TIME gate — the date IS the constraint.** Once `today >= date`, the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog)'s `classify` admits the issue unconditionally — no probe, no re-diagnosis, self-clearing exactly as before this issue.
- **`do-work-blocked-until` PAIRED with a `do-work-recheck: <verb> <args...> == <expected>` marker is an EVENT gate — the probe verdict is the constraint, not the calendar.** `classify` (via the [`--probe-verdicts`](../../../scripts/backlog-filter.sh) precompute step, `eval-probes`) admits the issue ONLY when the probe reports `changed`; `unchanged`/`unknown` keeps dropping the issue as `event-gated` REGARDLESS of whether the calendar date has already elapsed. The date, for an event gate, is a documentation artifact only (a maintainer-legible "roughly when we expect to check again," per the diagnosis comment step 2 above) — it never actually admits the issue on its own once a probe marker is present. This is what closes the churn loop #1356 documents: a placeholder date elapsing no longer silently re-admits an issue whose real blocking condition hasn't changed, and no fresh date is ever invented to keep re-parking it — the same marker pair, and the same live probe re-evaluated on every classify pass, is the entire mechanism.
- **No-cheap-probe case.** When the blocking condition is a genuine unforecastable event but no `npm-view`/`gh-api`/`url-json` probe can mechanically test it (`eval-recheck-probe.sh`'s allowlist is deliberately narrow — see its own header comment; and `url-json` reaches only hosts the repo has already allowlisted in its committed `scope.recheck_probe_url_hosts`, empty by default), do NOT invent one. Write `do-work-blocked-until` alone, with a deliberately distant date (weeks-to-months out, not a plausible-looking near-term guess) so the issue reads as a genuine park rather than an active near-term recheck, and say so plainly in the diagnosis comment (`Blocked until: <date> — no mechanical probe available; re-diagnose manually once the condition is believed to have changed`). This is an honest degrade, not a failure: a human (or a future, wider probe allowlist) can always shorten the date or add a probe later. Re-litigating from scratch on every date lapse is the status quo this class already accepted before #1356 — the fix here is only for the case a probe genuinely exists and was going unused.

## Recognized structured shape — and why it's this narrow

The scope agent optionally appends a trailing clause to `evidence_pointer`, per the hint documented on the [`external-dependency` class](06-scope-preflight.md#6-initial-scope-pre-flight):

```
Recheck probe: <verb> <args...>
```

where `<verb> <args...>` is **exactly** the marker-body grammar `eval-recheck-probe.sh` already accepts (`npm-view <pkg> <field> == <expected>`, `gh-api repos/<owner>/<repo>/<endpoint> <jq-field> == <expected>`, or — since [#1496](https://github.com/mattsears18/shipyard/issues/1496) — `url-json <https-url> <jq-filter> == <expected>`, whose host must already appear in the repo's committed `scope.recheck_probe_url_hosts` array). This deliberately asks the scope agent to speak the validator's own grammar directly, rather than inventing a second, looser prefix vocabulary (e.g. free-text "Package X pinned pending Y") that this step would then have to translate into the marker grammar by hand. **That translation step is exactly the second construction path the issue calls out as the risk to avoid** — a hand-rolled translator could produce a plausible-looking but wrong probe (right shape, wrong semantics) that passes its own logic but never matches the real condition. Requiring the scope agent to emit the target grammar directly means this step's only job is extraction + validation, never construction-from-a-different-shape.

## Steps

1. **Extract the clause.** `evidence_pointer` is a single string already held from earlier in the Recording path. Take everything after the LAST occurrence of the literal substring `Recheck probe: ` (case-sensitive) to the end of the string. If the substring isn't present, **stop here — skip silently**, exactly as if this step never ran. Do not log a warning; an absent clause is the common case (most `external-dependency` defers have no single-command test), not an error.

2. **Validate against the shared evaluator — never construct the marker text by hand.**

   ```bash
   export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
   # (re-derived here — variables don't survive across Bash tool calls)
   PROBE_CLAUSE="<extracted text after 'Recheck probe: '>"
   # shellcheck disable=SC2086 — word-splitting on whitespace is exactly what
   # the validator expects (it tokenizes the same way internally); the clause
   # was extracted from evidence_pointer, itself derived from untrusted issue
   # body text, so this MUST go through --validate before anything downstream
   # ever treats it as a real command.
   PARSED=$("$CLAUDE_PLUGIN_ROOT/scripts/eval-recheck-probe.sh" --validate "<owner/repo>" $PROBE_CLAUSE)
   VALIDATE_STATUS=$?
   ```

   `--validate` is hermetic (no network, no `gh`/`npm` call) and is the exact same grammar the read side (`operate/04-steady-state-hooks.md`) re-checks on every evaluation — reusing it here means "can this marker ever be written" and "is this marker safe to evaluate" stay the same predicate, so the two paths can't drift apart.

   - **Non-zero exit (`invalid`)** — the clause didn't match either grammar (wrong verb, wrong token count, a field/expected value outside the allowlisted character classes, or a `gh-api` endpoint naming a different `<owner>/<repo>` than this invocation's — cross-repo probing is rejected by the validator itself, not by anything in this step). **Skip silently** — do not post a comment, do not log a WARNING (this is an optional hint that didn't pan out, not a failure of a required action). A single quiet log line is fine: `[scope-preflight] #<N> evidence_pointer carried an unvalidated Recheck probe clause — skipping do-work-recheck marker write (falling through to calendar-only)`.
   - **Zero exit** — `$PARSED` is `<verb>\t<arg1>\t<arg2>\t<expected>` (TAB-separated as of [#1496](https://github.com/mattsears18/shipyard/issues/1496) — the `url-json` verb's jq filter may itself contain a `|`, and no validated field can ever contain whitespace), where each field individually already passed its own regex inside the validator. Proceed to step 3.

3. **Reconstruct the canonical marker text from the validated fields only — never from the raw clause.** This is the load-bearing safety property: the text written into the issue body is built exclusively from the four pipe-delimited fields the validator itself extracted and regex-checked, not from the untrusted `evidence_pointer` substring verbatim (which could carry incidental extra whitespace or formatting the validator's tokenizer happened to tolerate but a byte-for-byte copy would preserve).

   ```bash
   IFS=$'\t' read -r V A1 A2 EXP <<<"$PARSED"
   MARKER_LINE="<!-- do-work-recheck: $V $A1 $A2 == $EXP -->"
   ```

4. **Write it into the issue body, idempotently — NEVER prepended above the just-written `do-work-blocked-until` marker ([#1356](https://github.com/mattsears18/shipyard/issues/1356)).** Re-fetch the body fresh (step 4a/4b already mutated it in a separate call; don't trust an in-memory copy across tool calls). `do-work-blocked-until`'s line-1 "position discipline" ([#1168](https://github.com/mattsears18/shipyard/issues/1168)) is load-bearing for `classify`'s `time_gate_future` check — a naive unconditional prepend of `$MARKER_LINE` above the current body would push the marker step 4a/4b just wrote from line 1 to a later line, silently breaking the calendar gate (the marker stops matching, the issue reads as never-blocked, `classify` admits it immediately regardless of the date). Insert the recheck marker as the SECOND line instead — immediately after the first line, whenever the first line is itself a `do-work-blocked-until` marker — so the calendar marker never leaves line 1:

   ```bash
   CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
   if echo "$CURRENT_BODY" | grep -q '<!-- do-work-recheck:'; then
     # A marker already exists (e.g. a re-diagnosis produced an updated probe).
     # Replace it in place rather than stacking a second one. Idempotent: if
     # the clause is unchanged, this is a no-op edit. In-place replacement
     # never moves any other line, so this branch has no ordering concern.
     NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s|<!-- do-work-recheck: .+ -->|$MARKER_LINE|")
   elif echo "$CURRENT_BODY" | head -1 | grep -q '<!-- do-work-blocked-until:'; then
     # The current first line IS the calendar marker (the expected case,
     # since step 4a/4b always runs immediately before this step) — insert
     # the recheck marker as line 2, keeping the calendar marker on line 1.
     FIRST_LINE=$(echo "$CURRENT_BODY" | head -1)
     REST_BODY=$(echo "$CURRENT_BODY" | tail -n +2)
     NEW_BODY="$FIRST_LINE
$MARKER_LINE
$REST_BODY"
   else
     # Defensive fallback only — step 4a/4b should always have already put
     # the calendar marker on line 1 before this step ever runs. If it
     # somehow didn't, prepending here is safe (there is no line-1
     # do-work-blocked-until marker to displace).
     NEW_BODY="$MARKER_LINE

$CURRENT_BODY"
   fi
   if [ "$NEW_BODY" != "$CURRENT_BODY" ]; then
     gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
   fi
   if ! gh issue view <N> --repo <owner/repo> --json body --jq '.body' | grep -q '<!-- do-work-recheck:'; then
     echo "[scope-preflight] WARNING: #<N> do-work-recheck marker did not land — falling back to calendar-only re-check"
   fi
   # Belt-and-suspenders: confirm the calendar marker is STILL on line 1
   # after this write (catches a future edit to this step reintroducing the
   # #1356 ordering bug, not just a normal write failure).
   if ! gh issue view <N> --repo <owner/repo> --json body --jq '.body' | head -1 | grep -q '<!-- do-work-blocked-until:'; then
     echo "[scope-preflight] WARNING: #<N> do-work-blocked-until marker no longer on line 1 after the do-work-recheck write — the calendar gate is now silently broken for this issue"
   fi
   ```

   The read-back warning here mirrors step 4b's own — but note the asymmetry: a failed *write* is worth a WARNING (something that should have landed didn't), while an *unvalidated clause* in step 2 is not (it was never going to land — that's the correct, safe outcome for a scope agent's plausible-but-wrong guess).

## Fail-safe posture (same asymmetry as `eval-recheck-probe.sh` itself)

Every failure mode in this step degrades toward **"no marker written, calendar-only behavior unchanged"** — never toward fabricating or force-fitting a marker. A missing clause, an invalid clause, a validator that can't run (missing script, unexpected error) — all of them fall through to skip. This mirrors the read side's own `unknown`-never-`changed` posture: under-triggering here costs nothing beyond the pre-#1198 status quo (the issue stays calendar-gated); over-triggering — writing a marker that looks plausible but tests the wrong thing — would be worse, because a human skimming the issue body could mistake it for a verified, working check. When in doubt, this step does nothing.
