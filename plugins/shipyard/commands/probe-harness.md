---
description: Re-probe shipyard's harness-behaviour claims against the installed Claude Code and report which have expired. Read-only; proposes cuts, never applies them.
---

# /probe-harness

Shipyard encodes claims about Claude Code itself — what the permission classifier
refuses, how the harness names worktrees, what it propagates into a shell. Those
claims are **versioned software behaviour**, and they rot silently: on 2026-09-30
all ten documented classifier refusals were found to run on 2.1.286, and a
hard-coded worktree prefix had left **797 orphan branch refs** behind a sweep that
reported success ([#1664](https://github.com/mattsears18/shipyard/issues/1664)).

Unlike every other question about what shipyard still needs, this one is settled by
running a command rather than by argument. That makes it the cheapest, highest-
confidence maintenance pass in the repo. Run it weekly.

**This command is read-only.** It reports and proposes. It does not edit the spec.

## Why this cannot be a script

The classifier evaluates **Bash tool calls**, not shell commands. A script runs
entirely inside one call, so it cannot observe a refusal of itself. **Each probe
must be its own `Bash` tool call** — and because a denial kills the whole call,
batching two probes means losing the second's result.

One probe per call. No exceptions.

## Step 1 — record the version

```bash
claude --version
```

Put it in the report. Every verdict below is only meaningful against it.

## Step 2 — probe the harness claims

Run each as a **separate** `Bash` call. All are read-only and touch nothing. For
each, record RAN or REFUSED.

| # | probe | documented verdict |
|---|---|---|
| 1 | `git -C "$VAR" rev-parse --short HEAD` (VAR set to a repo path) | refused — bare whole word |
| 2 | `bash "$VAR/scripts/shipyard-config.sh" --help` | refused — launcher + expansion |
| 3 | `[ -z "$V" ] && V="x"; echo "$V"` | refused — bare whole word in a test |
| 4 | `export V=$(git -C <repo> rev-parse --show-toplevel); echo "$V"` | refused — exported computed value |
| 5 | `V=$(cmd)/suffix` unquoted, then `echo` | refused |
| 6 | `V=$(cmd); export V; "$V/scripts/shipyard-config.sh" --help` | refused |
| 7 | `V=$(cmd); V="$V" "$V/scripts/shipyard-config.sh" --help` | refused — computed name in env prefix |
| 8 | `bash -c 'git -C <repo> rev-parse --short HEAD'` | refused — launcher with git operand (#1558) |
| 9 | `curl -s -m 2 -H "$(printf 'X-P: 1')" http://127.0.0.1:1/` | refused — whole-word expansion (#1605) |
| 10 | `source "$NVM_DIR/nvm.sh"` with `NVM_DIR` exported | refused |
| 11 | `echo "CLAUDE_PLUGIN_ROOT=[${CLAUDE_PLUGIN_ROOT:-<EMPTY>}]"` | **empty** — not propagated into Bash shells |
| 12 | `git worktree list --porcelain \| awk '/^worktree /{print $2}' \| xargs -n1 basename` | count the prefixes in use |

**Probe 9 targets port 1 on loopback deliberately** — connection refused, nothing
leaves the machine. **Probe 12 is the one that catches renames:** compare the live
prefix against every hard-coded glob (`grep -rn 'worktree-agent-\*\|agent-\*'
scripts/`). A matcher asserting a prefix the harness no longer uses is #1664.

## Step 3 — report

```
## Harness-claim probe — <date>, Claude Code <version>

| probe | documented | actual | verdict |
|---|---|---|---|
| …     | refused    | RAN    | **EXPIRED** |
| …     | refused    | REFUSED| current |

Expired: N of 12.
Live worktree prefix: `<prefix>`  ·  hard-coded matchers disagreeing: <list>
```

Then, for each EXPIRED claim, name the file and section carrying it.

## Step 4 — propose, don't apply

For every expired claim, the fix is **not** to re-measure it. Per
[#1665](https://github.com/mattsears18/shipyard/issues/1665): delete the
observation and keep only the response rule. "Shape X is refused" becomes "read
the refusal and reshape once." A response rule survives every version; an
observation survives none.

Open one issue listing the expired claims and the prose each one justifies. Let a
human decide. **Do not edit the spec from this command** — the 2026-09-30 pass
over-cut four times before the test suite stopped it, and three of those were
rules that read like nags and encoded real facts.

## Don't

- **Don't batch probes.** A denial ends the call; the rest of the batch is lost and
  you will record a false RAN.
- **Don't probe anything that writes.** Every probe above is read-only. A probe
  that mutates is a worse bug than the stale claim it was checking.
- **Don't treat a refusal as proof the claim is still correctly *worded*.** Probe 8
  may refuse because of a host-global command-rewriting hook (RTK) rather than the
  classifier. Report what you observed; don't infer the mechanism.
- **Don't widen a probe to make it refuse.** The point is to find out, not to
  confirm. An expired claim is the valuable result.
- **Don't skip step 12 because nothing looks broken.** #1664 was invisible for
  months precisely because a zero match reads as a clean pass.
