# /shipyard:do-work — Setup phase · config-named label verification

**Setup sub-phase fragment, loaded from [`01-repo-recovery.md`](./01-repo-recovery.md)'s step-1.75 pointer — part of the ordered per-session walk, not a conditional deep-link.** Runs immediately after step 1.7's trusted-author allowlist resolution completes, right before step 2's backlog overview ([#1431](https://github.com/mattsears18/shipyard/issues/1431), splitting `01-repo-recovery.md` at this seam once it crossed the token-budget warn band — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233)). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01-repo-recovery.md`](./01-repo-recovery.md#17-resolve-trusted-author-allowlist) (step 1.7). Next: [`01b-backlog-overview.md`](./01b-backlog-overview.md) (step 2).

### 1.75 Verify config-named labels exist in the target repo ([#1359](https://github.com/mattsears18/shipyard/issues/1359))

**Load-bearing gap this closes.** Shipyard's config names every routing label BY STRING (the merged config's `labels` block — `session_stamp`, `blocked_soft`, `ci_blocked`, `needs_human_review`, `user_feedback`) and nothing verified those strings actually exist as label objects in the target repo. A consumer repo that declares no `labels` block at all inherits shipyard's built-in defaults wholesale — including names that only ever held true of shipyard's OWN repo (which happens to carry every legacy label object from its own history, so the mismatch never surfaced there). The original repro: `mattsears18/lightwork` declared no `labels` block, and two of its inherited config-named labels (`blocked:agent`, `blocked:agent-hard`) did not exist as label objects in that repo — silently, with no check anywhere in setup, dispatch, or drain ever catching it. A mislabeled/missing-label issue is invisible to **both** loops at once: `/do-work` never dispatches an agent to apply a label it can't find, and `/my-turn` filters its walked queue by label name — so an issue routed through a phantom label is unreachable by either. [#1360](https://github.com/mattsears18/shipyard/issues/1360) closed that specific instance by retiring the `blocked` / `blocked_hard` config keys and schema properties entirely — both were vestigial (nothing has applied or read either label since [#521](https://github.com/mattsears18/shipyard/issues/521)'s refuse/dependency-wait split retired the machinery that used them), so a fresh consumer repo no longer inherits a label name shipyard itself doesn't use. This check remains general-purpose for whatever `labels` keys are live now or added later.

Runs right here, immediately after step 1.7's collaborator-permission resolution above — the same "make one live label-adjacent API call" shape, and naturally before step 2's bucket pass (which reads label names off every issue). **Runs unconditionally, regardless of whether the consumer repo declared its own `labels` block** — the built-in defaults populate the block either way, so there is always a merged config to check against.

**Invocation — the target repo is POSITIONAL. There is no `--repo` flag** ([#1492](https://github.com/mattsears18/shipyard/issues/1492)). Run it exactly as written below; the literal shape is stated here rather than left to be derived from prose, following the [#1455](https://github.com/mattsears18/shipyard/issues/1455) precedent for `worktree-reap.sh triage-orphan-branches` — that precedent exists because deriving a call from surrounding prose costs a refused/no-op call per session, per mismatch:

```
"$CLAUDE_PLUGIN_ROOT/scripts/verify-config-labels.sh" <owner/repo>     # correct
"$CLAUDE_PLUGIN_ROOT/scripts/verify-config-labels.sh" --repo <owner/repo>   # WRONG — exits 64
```

`--repo` is the natural guess, because every neighbouring setup detector (`detect-ungated-admin-direct-merge.sh`, `detect-missing-workflow-scope.sh`, `detect-ci-runner-capacity.sh`) also takes `<owner/repo>` positionally while `gh` itself spells the same argument `--repo`. The script now rejects the flag form explicitly (exit `64`, `EX_USAGE`) instead of forwarding it to `gh` and misreporting the resulting failure as `INDETERMINATE` — see the `64` branch below.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_1_75_verify_labels 2>/dev/null || true
VERIFY_LABELS_OUT=$("$CLAUDE_PLUGIN_ROOT/scripts/verify-config-labels.sh" "<owner/repo>" 2>&1)
VERIFY_LABELS_STATUS=$?
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_1_75_verify_labels 2>/dev/null || true
```

[`scripts/verify-config-labels.sh`](../../../scripts/verify-config-labels.sh) is the single executable source of truth for the cross-reference — do not re-derive the comparison by hand (in particular, never substring-match a label name against the existing set; `mattsears18/lightwork`'s own label list contains near-miss names like `blocked:ci` where a substring check would silently paper over a genuinely absent `blocked:ci-old`-shaped label). It reads the merged config's `.labels` block via `shipyard-config.sh get labels` and cross-references every value against `gh label list --repo <owner/repo>`. Never blocking — this is loud advisory, not a session-ending failure. Branch on `$VERIFY_LABELS_STATUS`:

- **`0` (stdout starts `OK:`)** — every config-named label exists. No advisory needed; continue silently to step 2.
- **`1` (stdout starts `MISSING:`)** — one or more config-named labels are absent. Print the advisory **loudly** — this is the one unacceptable failure mode the issue exists to close, so never swallow it:

  ```
  [labels] <N> config-named label(s) do not exist in <owner/repo> — routing that depends on them is silently dead:
    labels.<key1>="<value1>"
    labels.<key2>="<value2>"
  ```

  (One indented line per `MISSING_LABEL:` entry in `$VERIFY_LABELS_OUT`.) Record the same detail into the session-local `SHIPYARD_LABEL_CONFIG_MISMATCH` variable (working memory, not persisted to session state — same convention as `SHIPYARD_CONFIG_SCHEMA_FAILURE` from [step 0.4](./00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson)) so [the end-of-session summary](../cleanup-summary.md#end-of-session-summary) re-surfaces it for a user who scrolled past the startup output. Do NOT auto-create the missing labels here — an arbitrary config-named string has no known-good description/color the way step 3a's fixed, hardcoded set does, and silently materializing an undescribed label is its own governance problem; naming the gap loudly is the fix this issue asks for, not papering over it.
- **`2` (stdout starts `INDETERMINATE:`)** — the check itself could not run **from a well-formed call** (a `gh label list` or `shipyard-config.sh` call failed). Treat this the same as a genuine mismatch — "couldn't verify" is not "verified clean." Print `[labels] could not verify config-named labels exist (<reason>) — see #1359` and set `SHIPYARD_LABEL_CONFIG_MISMATCH` to that same text.
- **`64` (stdout starts `USAGE_ERROR:`)** — you called the script wrong ([#1492](https://github.com/mattsears18/shipyard/issues/1492)). This is a bug in *this* invocation, not a condition of the target repo, and it is the one status that is worth retrying: **re-run once with the literal positional form above** (`"$CLAUDE_PLUGIN_ROOT/scripts/verify-config-labels.sh" "<owner/repo>"` — no `--repo`, exactly one argument) and branch on the retry's status instead. If the retry also returns `64`, stop retrying: print `[labels] could not verify config-named labels exist (verify-config-labels.sh invoked incorrectly: <reason>) — see #1492` and set `SHIPYARD_LABEL_CONFIG_MISMATCH` to that text, exactly as for `2`. Never treat `64` as a pass — a check that never ran is indistinguishable from one that never passed.

**Why `64` is not folded into `2`.** Failing open on an unreadable signal is the right default posture for a diagnostic (it matches [step 1.3](./01-repo-recovery.md)'s stated fail-safe design), but a malformed command line is not an unreadable signal — it is a bug in the invocation, and it is perfectly detectable. Before [#1492](https://github.com/mattsears18/shipyard/issues/1492) the two were conflated: `--repo <owner/repo>` bound the repo variable to the literal string `--repo` and forwarded it, producing `gh label list --repo --repo …`, whose failure surfaced as `INDETERMINATE: gh label list --repo --repo failed or returned nothing` — a caller error wearing the costume of a transient network failure, and therefore unactionable. The distinct exit code and the distinct `USAGE_ERROR:` stdout prefix are what make the retry above possible at all.

**Why a script and not inline prose.** The comparison has a sharp correctness trap (jq's `contains`/`inside` recurse into elemental substring matching for strings, so a naive inline check can silently treat an absent label as present whenever it happens to be a substring of one that does exist) — exactly the class of drift `detect-ungated-admin-direct-merge.sh` and `assert-worktree-change-present.sh` were extracted to prevent for their own conditions. One executable place for the rule; every caller invokes it rather than re-deriving it.
