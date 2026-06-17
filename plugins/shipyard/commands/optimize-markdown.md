---
description: Audit the repo's runtime-loaded markdown for context bloat (files near the read limit, inline provenance, duplicated conventions, hot-path/reference interleaving), apply the safe mechanical optimizations, and open a PR. Files a dispatch-ready issue for the restructuring too risky to auto-apply.
argument-hint: [--repo owner/repo] [--threshold KB] [--dry-run] [--issue-only]
---

# /optimize-markdown

In a Claude Code plugin (or any repo where markdown files are loaded into an agent's context — command prompts, agent prompts, skills, `CLAUDE.md`, `AGENTS.md`), **the markdown _is_ the runtime**. When those files bloat they cost tokens and latency on every invocation, and once a single file crosses the **256KB `Read` limit** the agent can no longer read its own instructions in one call — it silently falls back to reading a prefix and may act on an incomplete contract.

This command audits that surface, applies the **safe, behavior-preserving** optimizations, and opens a PR — and files a **dispatch-ready issue** for the larger restructuring that shouldn't be auto-applied. It is the codified, repeatable version of the manual "review every markdown file for bloat + progressive-disclosure wins" pass.

It is **generic** — it works in any repo with shipyard installed by discovering which markdown is loaded at runtime and detecting the repo's existing conventions, then applying shipyard-aware heuristics when it recognizes them (do-work phase-routing, `worker-preamble`, a `*-RATIONALE.md` provenance sink, the 256KB limit).

## When to use

- A plugin/agent repo's prompt files have bloated and you want them trimmed and split without hand-auditing each one.
- A runtime-loaded markdown file is at or over the 256KB `Read` limit (or approaching it) and needs a thin-router + on-demand-sub-file split.
- You want a periodic, repeatable "context hygiene" pass you can run on a cron or before a release.

Not the right surface when:

- You only want to *find and report* the bloat without changing anything — pass `--dry-run`.
- You only want an issue filed for a human/`/do-work` to act on later — pass `--issue-only` (this is what [`/shipyard:file-issue`](./file-issue.md) does for the one-off case; `--issue-only` here reuses the same filing conventions but with the full markdown sweep pre-run).
- The bloat is in *prose docs nobody loads at runtime* (a `docs/` essay, a blog post). This command targets **runtime-loaded** context; pure human docs are out of scope unless they're a relocation *destination* (e.g. a `*-RATIONALE.md` sink).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): target repo. Default: resolve from the cwd via `gh repo view --json nameWithOwner -q .nameWithOwner`. **Refuse gracefully** (single-line error, no interactive prompt) if not in a git repo or there's no GitHub remote — mirror [`/shipyard:file-issue`](./file-issue.md)'s refusal gate.
- **--threshold KB** (optional, default `240`): the size at which a runtime-loaded markdown file is flagged as over-budget. Default `240` leaves headroom under the 256KB `Read` limit. A file *over* the limit is always P0-flagged regardless of this value.
- **--dry-run** (optional): run the full audit and print the ranked report, but make no edits, open no PR, and file no issue. Use to preview.
- **--issue-only** (optional): run the audit and file a single dispatch-ready issue for **all** findings (safe + risky) instead of opening a PR. Use when you'd rather let `/do-work` or a human apply everything.

## What counts as "runtime-loaded" markdown

Discover the surfaces an agent actually loads — don't audit every `.md` in the tree. The default discovery set (adapt to the repo's layout):

- **Command prompts** — `*/commands/**/*.md` (and the on-demand phase/sub-files they route to).
- **Agent prompts** — `*/agents/**/*.md`.
- **Skills** — `**/skills/**/SKILL.md` and the fragments they load.
- **Always-resident instruction files** — `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` at every level (these load on *every* turn, so bloat here is the most expensive).

**Excluded by default:** `node_modules/`, `.git/`, `.claude/worktrees/` (worktree copies double-count), `CHANGELOG.md` (append-only, never loaded at runtime, growth is expected), and human-only docs under `docs/` / `README.md` / `CONTRIBUTING.md` — *unless* they're a relocation destination.

## Implementation (what the assistant does when this command runs)

### 1. Resolve repo + parse flags

Resolve the target repo from `gh repo view` (refuse gracefully on failure — see Args). Parse `--threshold`, `--dry-run`, `--issue-only`.

### 2. Measure the runtime-loaded surface

Enumerate the discovery set (above) and measure bytes per file, excluding the default-excluded paths:

```bash
find . -name '*.md' \
  -not -path './node_modules/*' -not -path './.git/*' -not -path './.claude/worktrees/*' \
  \( -path '*/commands/*' -o -path '*/agents/*' -o -path '*/skills/*' -o -name 'CLAUDE.md' -o -name 'AGENTS.md' \) \
  -printf '%s\t%p\n' | sort -rn
```

Flag every file **≥ `--threshold`** (default 240KB) and, separately, every file **> 256KB** (the hard `Read` limit — these are correctness risks, not just bloat).

### 3. Map the loading model

Before proposing splits, understand *how* the repo loads these files so the optimization follows the existing convention rather than inventing a new one. Dispatch an `Explore` agent (keep the noisy sweep out of the main context) to answer:

- Which files are loaded **eagerly** (every invocation / every turn — e.g. `CLAUDE.md`, a command's always-resident header) vs **on-demand** (a phase file, a per-mode agent file, a skill fragment)? Eager bloat is the most expensive — weight it higher.
- Does the repo already use a **thin-router + on-demand-sub-file** pattern (e.g. a phase-routing table that loads `commands/<cmd>/<phase>.md`)? If so, *extend that exact pattern* for new splits — match its routing-table format and load-instruction prose.
- Is there a **provenance/rationale sink** (a `*-RATIONALE.md` or `docs/` file explicitly marked "the agent never loads this")? That's the destination for relocated historical narrative.

### 4. Detect the bloat classes

For each over-budget or often-loaded file, classify findings (cite `path:line` ranges):

1. **Over the read limit** — file > 256KB. The agent can't read it in one call. **Always** a split candidate.
2. **Inline historical provenance** — issue/PR parentheticals (`(#519 folded X into Y)`, `eliminated in #521`, `re-keyed by #NNN`) woven into instruction prose the agent doesn't need at execution time. Measure density (refs per line). The agent needs *current behavior*; the "why" belongs in the rationale sink behind a single anchor link.
3. **Duplicated conventions** — the same taxonomy/policy (label semantics, naming rules, config shape) restated across many files when one canonical source already exists (e.g. `CLAUDE.md`). Runtime restatements collapse to a one-line pointer to the canonical section.
4. **Hot-path / reference interleaving** — a frequently-loaded file that bundles rarely-hit reference material (lookup tables, edge-case playbooks, defensive rationale) with the hot lifecycle steps. The reference can split into an on-demand fragment the few callers that need it load explicitly.

### 5. Partition findings: SAFE-to-auto-apply vs RISKY

This is the load-bearing judgment. Be conservative — when unsure, classify RISKY and file it rather than auto-applying.

**SAFE (goes in the PR)** — behavior-preserving, mechanically verifiable:
- Relocating an inline provenance parenthetical to the rationale sink, leaving an anchor link, when the surrounding instruction text is unchanged.
- Collapsing a duplicated convention restatement to a pointer at the canonical section, when the canonical section already says the same thing (verify it does — don't drop a restatement that carries detail the canonical source lacks).
- Splitting a file along a **seam the repo's existing router already supports**, when every load reference can be mechanically updated and re-verified.

**RISKY (goes in a filed issue, not the PR)** — anything that could change agent behavior or needs design judgment:
- Inventing a *new* router/loading convention the repo doesn't already have.
- Splitting a file where the seams are unclear or steps are interdependent (risk of an agent loading a fragment that references state from a sibling it didn't load).
- Rewriting/condensing instruction *semantics* (not just relocating provenance) — paraphrasing risks dropping a load-bearing nuance.
- Any change where you can't mechanically prove every moved cross-reference still resolves.

If `--issue-only`, treat **all** findings as "to be filed" and skip to step 8's filing path.

### 6. Apply the safe optimizations (skip on `--dry-run` / `--issue-only`)

Work in an isolated worktree (per the global worktree rule). Apply only the SAFE set from step 5. After editing:

- **Re-resolve every moved reference.** For each relocated provenance anchor, collapsed convention pointer, and split-out fragment, grep the repo to confirm the link target exists and every loader that referenced the old location now points at the new one. A dangling load reference is a behavior regression — treat it as a hard failure, not a warning.
- **Confirm no file the agent must read in one call exceeds the limit** after the split.
- **Run the repo's existing test suite** (`*.test.sh`, `npm test`, whatever the repo uses). Do not claim the optimization is safe without green tests — verify before completion. If tests fail, fix or revert the offending transform — never ship red.

### 7. Open the PR (skip on `--dry-run` / `--issue-only`)

Follow the repo's PR conventions and the [`filing-github-issues`](../skills/filing-github-issues/SKILL.md) provenance rule:

- Ensure the `shipyard` label exists (`gh label create shipyard --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true`) and apply it to the PR.
- One concern per commit (per the global git rules): provenance relocation, convention dedup, and each file split are logically distinct — split them.
- PR body: a short summary of the bloat measured (before/after bytes for each touched file), the exact transforms applied, and the verification evidence (reference-resolution grep results + test output). Cross-link the filed issue from step 8 for the RISKY remainder.
- **Cut a release** if this repo follows the shipyard release process (version bump + CHANGELOG entry) — see [`CLAUDE.md`'s Release process](../../../CLAUDE.md#release-process).

### 8. File a dispatch-ready issue for the RISKY remainder

For findings classified RISKY in step 5 (or *all* findings under `--issue-only`), file **one** dispatch-ready issue via the [`filing-github-issues`](../skills/filing-github-issues/SKILL.md) conventions and the [`audit-rubrics`](../skills/audit-rubrics/SKILL.md) severity buckets — exactly as [`/shipyard:file-issue`](./file-issue.md) does:

- Conventional Commits title (`refactor(<scope>): …`), `shipyard` + `P0|P1|P2` labels, no gate label by default.
- `## Finding` cites the measured sizes and `path:line` evidence; `## Suggested approach` names the specific splits/relocations and the existing router pattern to follow; `## Acceptance criteria` is a verifiable checklist (no file over the threshold, every moved reference resolves, tests pass).
- Search for duplicates first (`gh issue list --search …`); if a strong match exists, surface it and link rather than double-filing.

### 9. Return a summary

Print, as the last lines:

- The over-budget files and their sizes (flag any over the 256KB limit explicitly).
- What the PR changed (with before/after bytes) and its URL — or, on `--dry-run`, the report only.
- The filed issue URL for the RISKY remainder (or, on `--issue-only`, the single issue covering everything).

## Refuse gracefully

Single-line error + clean exit (no interactive prompt, no stack trace) if: not in a git repo / no GitHub remote (`/optimize-markdown must run inside a git repo with a GitHub remote configured.`), or `gh` is unauthenticated (`/optimize-markdown requires gh to be authenticated — run \`gh auth login\` and retry.`).

## Don't

- **Don't audit markdown nobody loads at runtime.** `CHANGELOG.md` growth is expected; a `docs/` essay isn't context bloat. Target the loaded surface (step 2's discovery set) unless a human-doc file is a relocation *destination*.
- **Don't invent a new loading convention.** If the repo already has a router pattern, extend it verbatim. If it doesn't, that's a RISKY finding to file — not something to auto-introduce.
- **Don't paraphrase instruction semantics to save bytes.** Relocating provenance and collapsing genuine duplication is safe; condensing the actual contract risks dropping a load-bearing nuance — file it as RISKY instead.
- **Don't ship a split with a dangling load reference.** Every moved target must resolve; prove it with a grep before opening the PR. A broken on-demand load is a silent behavior regression.
- **Don't claim safety without green tests.** Run the repo's suite after editing; never ship red.
- **Don't bundle the safe PR and the risky issue into one giant autonomous PR.** The whole point of the split is that the risky restructuring gets human/`/do-work` eyes — keep the PR to the mechanically-safe set.

## Related

- [`/shipyard:file-issue`](./file-issue.md) — file a single dispatch-ready issue (the one-off case; `--issue-only` here is the markdown-sweep-backed version).
- [`/shipyard:audit docs`](./audit.md) — audits documentation *rot* (drift, broken links, stale TODOs) rather than *size/loading* bloat. Complementary: `docs` checks correctness, `optimize-markdown` checks context cost.
- [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) — title/label/duplicate-search/body conventions reused by the issue-filing path.
- [`shipyard:audit-rubrics`](../skills/audit-rubrics/SKILL.md) — P0/P1/P2 severity buckets.
