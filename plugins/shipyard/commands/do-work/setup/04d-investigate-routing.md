# /shipyard:do-work — Setup phase · investigate-mode candidate routing (detection-based entry)

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Route investigate-mode candidates" bullet. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why this fragment exists

[#514](https://github.com/mattsears18/shipyard/issues/514) made `needs-triage` investigate-mode's entry condition. [#556](https://github.com/mattsears18/shipyard/issues/556) routed trusted-author `needs-triage` issues to `investigate_candidates` instead of dropping them. Both were **label-only**: the sole entry signal was the presence of the `needs-triage` label.

[#1090](https://github.com/mattsears18/shipyard/issues/1090) found the label carried two incompatible meanings in practice — an inbound API from third-party bots (Sentry auto-files crash reports with it) and a human convention meaning "I haven't thought this through" — with only the first meaning actually load-bearing for investigate mode. The fix mirrors [#520](https://github.com/mattsears18/shipyard/issues/520)'s `needs-refinement` retirement: replace the persisted-label-only gate with a **live detection scan**, keep the label as a *sufficient but not required* trigger during a migration window (so the inbound Sentry pipeline never breaks even before every consuming repo upgrades), then retire the label once entry no longer depends on it. This fragment implements the detection scan. **The label was retired in [#1120](https://github.com/mattsears18/shipyard/issues/1120) — entry is now detection-only.** See "Label retirement — completed" below.

## The two signals (OR'd — either one is sufficient)

Applies only to issues that have already survived the trusted-author gate above (`author.login` in `trusted_authors`) — investigate mode never dispatches against an untrusted author's issue, regardless of which signal matched.

1. **Bot-shaped trusted author** — `author.login` matches `*[bot]` (REST shape) or `app/*` (GraphQL shape) — the same two shapes [`trusted-authors-normalize.sh`](../../../scripts/trusted-authors-normalize.sh) cross-adds for the `trust.authors` allowlist ([GH App alias normalization](./01f-gh-app-alias-normalization.md#gh-app-alias-normalization-issue-296)). Since this issue already passed the trusted-author gate, a bot-shaped login here means a bot the maintainer explicitly trusts (e.g. `app/sentry`) — not an arbitrary bot.
2. **Symptom-shaped body** — the body reads as a crash report (a stack trace, a fingerprint, an error string) rather than a fix request. Matched by a regex over common crash/stack-trace markers:

   ```bash
   SYMPTOM_REGEX='(Traceback \(most recent call last\)|Fatal error:|Unhandled( Promise)? [Rr]ejection|Exception in thread|Segmentation fault|NullPointerException|panic:|Stack trace:|sentry\.io/(organizations|issues)/|[Ff]ingerprint:[[:space:]]*[0-9a-f]{8,}|at [A-Za-z0-9_.$]+ ?\([^)]*:[0-9]+:[0-9]+\))'
   ```

   This is deliberately conservative — it matches actual stack-trace/traceback syntax, known crash-report vocabulary, and Sentry permalinks, not merely "the word error appears somewhere." A well-formed human bug report that happens to paste a stack trace as supporting evidence can still match; that's an acceptable false-positive (investigate mode still finds and fixes the root cause) rather than a security concern — the trusted-author gate above already ran, and investigate mode treats the body as untrusted *data* regardless of why it was routed here (see [`investigate.md`](../../../agents/issue-worker/investigate.md) step 2).

## The combined predicate

Run against the wide-fetch JSON from the top of step 4 (already has `number`, `body`, `author.login`):

```bash
INVESTIGATE_CANDIDATE_NUMBERS=$(echo "$fetched_issues_json" | jq --arg re "$SYMPTOM_REGEX" '
  [.[] | select(
      ((.author.login // "") | test("\\[bot\\]$|^app/"))
      or ((.body // "") | test($re; "i"))
    ) | .number]
')
```

The executable implementation is [`backlog-filter.sh`](../../../scripts/backlog-filter.sh)'s `is_investigate_signal` — that script is the single source of truth for the classification/routing decision, and the snippet above documents what it does rather than being a second copy to run.

### Overlap with the spike-shape detector — this route wins ([#1475](https://github.com/mattsears18/shipyard/issues/1475))

`investigate` is also a title prefix recognized by [`spike-shape-detect.sh`](../../../scripts/spike-shape-detect.sh), the dispatch-site detector that routes a candidate to `mode: spike`. **This route wins whenever it fires, and it wins structurally rather than by a tiebreak rule:** the divert above happens here, at step 4, and *removes* the issue from the survivor list, so a matched issue never reaches the `ready_issues` dispatch site where the spike check runs. An `investigate(x):`-titled issue that does reach that check is one this route already declined — its body isn't symptom-shaped and its author isn't bot-shaped — so it correctly routes to `mode: spike`. The two detectors read different fields on purpose: this one keys off **body and author** (a machine-filed crash report needing triage), the spike one off the **title** (a human framing an open question). Full reasoning in [`dispatch-rules.md`'s spike-shape detection block](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c).

## Config-gated routing (unchanged config surface, generalized behavior)

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
# Re-export the SHIPYARD_REPO_ROOT pin as a literal (issue #1059/#1064, #1619).
export SHIPYARD_REPO_ROOT="<primary-root literal>"
investigate_dispatch=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```

For every issue number in `INVESTIGATE_CANDIDATE_NUMBERS`:

- When `investigate_dispatch == "true"` (default): remove the issue from the main survivor list and append it to `investigate_candidates` instead. Do NOT add it to `raw_backlog`. The investigate-mode dispatch step (step 1.5 in the steady-state decision tree) drains `investigate_candidates` separately.
- When `investigate_dispatch == "false"`: drop the issue entirely. This opt-out exists for repos that prefer to triage manually.

**The drop-when-disabled policy applies uniformly to both signals** — this is a deliberate behavior change from the pre-#1090 shape, where `investigate_dispatch: false` only affected `needs-triage`-labeled issues; a bot-authored or symptom-shaped issue with no label simply fell through to `raw_backlog` as an ordinary issue-work candidate (a poor fit — issue-work assumes the body is a verified fix spec, not raw crash data). Since entry is detection-based, the opt-out is detection-based too: a maintainer who sets `investigate_dispatch: false` is saying "I don't want investigate-mode auto-driving untriaged-looking issues," and that intent should hold regardless of which signal identified the issue as untriaged-looking.

**`investigate_dispatch == "false"` is the only configuration under which a matched issue is a human item** ([#1077](https://github.com/mattsears18/shipyard/issues/1077), extended by [#1090](https://github.com/mattsears18/shipyard/issues/1090)) — under the default, a trusted-author issue matching either signal is autonomously dispatched via investigate mode and no human action is required, so [`01b`'s bucket-5 scoring](01b-backlog-overview.md#2-backlog-overview) and `/my-turn`'s survey both key off this same config value. Both of those consumers identify the bucket by **re-running the detection predicate**, not by reading a label — that indirection is what let the label be retired in #1120 without leaving either surface blind.

## Migration window — closed

This fragment implements acceptance criteria 1 and 2 of [#1090](https://github.com/mattsears18/shipyard/issues/1090) (live-detection entry; `needs-triage` accepted-but-not-required). The two items #1090 deliberately left open — retiring the label, and dispositioning the pre-existing corpus of human-applied `needs-triage` issues — were both tracked in [#1120](https://github.com/mattsears18/shipyard/issues/1120) and are **both now resolved**. See "Pre-existing corpus disposition" and "Label retirement — completed" below.

### Pre-existing corpus disposition — resolved, no code change ([#1120](https://github.com/mattsears18/shipyard/issues/1120))

#1090's own measurement found 34 of 47 all-time `needs-triage` applications in `mattsears18/lightwork` were the human "scope is still open" convention, not the Sentry bot-crash-report meaning, and flagged this as needing a disposition pass before the label could be retired.

A live re-measurement on 2026-08-08 (roughly 3.5 hours after #1090 closed) found:

| Repo | `needs-triage` open | `needs-triage` all-time (closed) |
|---|---|---|
| `mattsears18/lightwork` | **0** | 47 |
| `mattsears18/shipyard` | **0** | 1 |

All 47 historical applications in `lightwork` are already closed — there is no open corpus left to disposition. This confirms #1090's own recommended option 3 requires **no code change**: a vague/scope-still-open issue is an ordinary `/refine-issues` candidate, already caught by that command's `## Open questions` signal or its fall-through-to-`needs-human-review` branch. Nothing in this fragment (or elsewhere) needs to special-case the human "scope is still open" convention.

**If a future session finds `needs-triage`-labeled OPEN issues that are NOT bot/Sentry-shaped** (i.e., the human convention resurfaces), the correct action is still not a code change here — let `/refine-issues`' existing signal-based scan classify them. Only re-open this question if `/refine-issues` is observed to actually miss such issues in practice.

### Label retirement — completed 2026-08-15 ([#1120](https://github.com/mattsears18/shipyard/issues/1120))

`needs-triage` is **retired**. It is not an accepted investigate-mode entry signal, nothing creates or applies it, and the label object was deleted from `mattsears18/shipyard`. Investigate entry is the two detection signals above and nothing else.

**What shipped:** the label dropped from `is_investigate_signal` in [`backlog-filter.sh`](../../../scripts/backlog-filter.sh) (and from the documented predicate above); both `gh label create needs-triage` calls deleted ([`01c-label-recovery-refine.md`](./01c-label-recovery-refine.md), [`00b-parallelization-cache.md`](./00b-parallelization-cache.md)); every remaining writer re-pointed (see the RATIONALE pointer below); the `labels.needs_triage` config key and its schema property retired, following the [#1360](https://github.com/mattsears18/shipyard/issues/1360) precedent; the label object deleted.

**Under what authority.** The gate this section used to state required **both** a migration window (earliest date `2026-09-20`) and a live-usage condition. Condition 2 was satisfied — 0 open `needs-triage` issues in both `mattsears18/shipyard` and `mattsears18/lightwork`, measured 2026-08-08, re-measured 2026-08-09, re-verified 2026-08-15. Condition 1 was **waived by explicit maintainer decision** recorded on [#1120](https://github.com/mattsears18/shipyard/issues/1120#issuecomment-5302190526) (2026-08-15, `<!-- do-work-decision-resolved -->`), 36 days early: the date was a risk-tolerance judgment about unmeasurable third-party installs, not a fact a session could verify, and the maintainer accepted that risk for any external install still on a pre-#1090 shipyard. Two prior `/do-work` dispatches correctly declined to make that call themselves (2026-08-08, 2026-08-09) — declining was right absent a recorded decision.

**Consuming repos that still carry the label object** are unaffected in the only way that matters: a `needs-triage`-labeled issue is no longer *dropped* or *routed* by the label, so it lands in `raw_backlog` as an ordinary candidate — and if it is genuinely a bot/Sentry crash report it still routes to investigate mode on the bot-author or symptom-body signal. A leftover label object is inert; deleting it is optional cleanup.

Cold detail — the 43-day `#520`→`#859` window derivation, the original two-condition text, and the full writer-by-writer retirement inventory — lives in [RATIONALE → `needs-triage` retirement](../../do-work-RATIONALE.md#needs-triage-retirement-issue-1120).
