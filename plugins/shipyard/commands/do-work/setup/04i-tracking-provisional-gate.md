# /shipyard:do-work — Setup phase · `tracking`'s provisional-gate justification requirement

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Drop issues carrying any of the dispatch-gate labels" bullet, specifically the `tracking` member of that set. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why `tracking` needs its own rule ([#1364](https://github.com/mattsears18/shipyard/issues/1364))

The other four labels in the drop-label set — `blocked:ci`, `wontfix`, `discussion`, `needs-human-review` — are settled, intentional gates with a stated, permanent owner in [`backlog-ownership.md`](./backlog-ownership.md#ownership-table). Label presence alone is sufficient justification for those: a human (or a documented automated path) applied the label deliberately, so seeing it is enough to drop the issue.

`tracking` is different. It's documented in that same ownership table as a *defensive* gate ([#1081](https://github.com/mattsears18/shipyard/issues/1081)) against the label object never being fully migrated to `needs-human-review` — not a settled routing decision on its own. A `tracking` label can be stale, leftover from a workflow that predates the migration, with no live content in the issue body actually requiring human judgment. Dropping every `tracking`-labeled issue on label presence alone, the same way the other four are dropped, risks silently parking workable issues that happen to still carry the old label.

## The rule, stated once

**`tracking` alone is a PROVISIONAL member of the drop-label set, and a provisional gate may not fire on label presence alone.**

The script's `has_tracking_justification()` requires at least one recognized human-owned signal before it will drop the issue on `tracking` grounds. In precedence order:

| # | Signal | Source | Evidence pointer |
|---|---|---|---|
| 1 | a populated **GitHub sub-issue graph** | structured GitHub state ([#1556](https://github.com/mattsears18/shipyard/issues/1556)) | `4 sub-issues (#4698, #4699, #4700, #4701); 1 open` |
| 2 | a `Decision required` heading | body prose ([#1364](https://github.com/mattsears18/shipyard/issues/1364)) | `Decision-required heading in body` |
| 3 | an `Options` heading | body prose (#1364) | `Options heading in body` |
| 4 | a `Blocked by #N` reference | body prose (#1364) | `Blocked by #88 reference in body` |
| 5 | a **task-list of issue references** (`- [ ] #123`, or the same line carrying a full issue URL) | body prose (#1556) | `Task-list issue reference #11 in body` |

### Why the sub-issue graph ranks first ([#1556](https://github.com/mattsears18/shipyard/issues/1556))

`tracking`'s own definition — in both [`backlog-ownership.md`](./backlog-ownership.md#ownership-table)'s table and a consuming repo's `CLAUDE.md` — is *"parent epic/strategy, decomposed into sub-issues — tracking only, not directly workable."* An issue with a populated sub-issue graph is therefore the **definitional** case for the label, and it was precisely the case the original (signal 2–4) list could not see, because the sub-issue relationship is **structured GitHub state, not body prose**. The result was inverted: a correctly decomposed epic surfaced as `tracking-unjustified` while an issue that merely happened to carry the word "Options" in a heading passed clean. The #1556 repro (`mattsears18/lightwork#4688`, a four-phase epic with sub-issues #4698–#4701) flipped from `tracking-unjustified` to an evidenced gate after a one-line `Blocked by #4701` body edit that changed nothing about the issue's actual nature — the tell that the signal list, not the issue, was what was wrong.

Signal 5 ranks **last** deliberately: it is the pre-sub-issues way of expressing the same decomposition (still common in older epics), and putting it below signals 2–4 means adding it cannot change the `evidence_pointer` any pre-#1556 match already emitted.

### How the structured signal reaches a pure classifier

`backlog-filter.sh classify` is a pure function with no network I/O of its own (see that script's own "Design note" header) — so signal 1's read happens in a separate producer subcommand, exactly like `eval-probes` / `eval-pr-collision`:

```bash
backlog-filter.sh sub-issues --repo <owner/repo> < wide-fetch-issues.json
# -> {"4688":[{"number":4698,"state":"CLOSED"}, ...]}
```

It is **pre-filtered to `tracking`-labeled issues only**, so cost is near zero on a normal backlog — the `tracking` set is typically tiny, and a backlog with none in it makes no network call at all. `classify-backlog.sh run` wires the producer and the resulting `classify --sub-issues <json>` flag together; no caller has to run the two halves by hand.

**Fail-safe, in the same direction the gate already fails.** Any unusable read — the API erroring, `subIssues` unavailable on this GitHub deployment, a malformed response, an *empty* sub-issue array — contributes **no key**, which makes `has_tracking_justification()` fall through to signals 2–5, i.e. exactly the pre-#1556 behavior. An inconclusive read can only ever surface the gate as `tracking-unjustified`; it can never fabricate a justification.

## The two verdict shapes this produces

- **Justified** — at least one signal matched. The script emits the plain `{"verdict":"gate","reason":"tracking","evidence_pointer":"<matched signal>"}` shape, identical in structure to the other four settled gates.
- **Unjustified** — no signal matched. The issue is still dropped (a `tracking` label is a strong enough prior that a false-negative auto-dispatch is the worse failure mode — re-dispatching a genuinely-tracking issue as workable code work is worse than parking a stale one), but the script emits `{"verdict":"gate","reason":"tracking-unjustified"}` instead — a distinct, greppable reason with no fabricated `evidence_pointer`. The drop is **surfaced, not silently indistinguishable from every other justified gate**.

[`04f-completion-ledger.md`](./04f-completion-ledger.md#the-bucket-taxonomy)'s census renders `tracking-unjustified` issues as their own sub-line under the Human-gated bucket rather than folding them into the flat count — so a session with a pile of unjustified `tracking` drops is visible in the summary, not averaged away.
