# /shipyard:do-work — Setup phase · GH App alias normalization

**Setup sub-phase fragment, loaded from [`01-repo-recovery.md`](./01-repo-recovery.md)'s step-1.7 pointer — part of the ordered per-session walk, not a conditional deep-link.** Runs as part of step 1.7's trusted-author allowlist resolution, immediately after the resolution-order logic determines `trusted_authors` ([#1431](https://github.com/mattsears18/shipyard/issues/1431), splitting `01-repo-recovery.md` at this seam once it crossed the token-budget warn band — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233)). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01-repo-recovery.md`](./01-repo-recovery.md#17-resolve-trusted-author-allowlist) (step 1.7, resolution order + output). Next: [`01e-verify-config-labels.md`](./01e-verify-config-labels.md) (step 1.75).

#### GH App alias normalization (issue #296)

GitHub returns **two different login shapes** for the same GH App account depending on which API the caller hits:

- **REST** (e.g. `/repos/.../issues/N/events`) returns the legacy-style login: `sentry[bot]`.
- **GraphQL Bot/App actor objects** (what `gh issue list --json author` and `gh issue view --json author` return) expose: `app/sentry`.

The two strings have nothing in common after lowercasing, which silently broke bot-author trust before [#296](https://github.com/mattsears18/shipyard/issues/296) — see [RATIONALE → GH App alias normalization](../../../../../docs/design/do-work-rationale.md#gh-app-alias-normalization--why-it-was-needed-296) for the failure story. The fix is alias normalization at allowlist-load time. The helper `$CLAUDE_PLUGIN_ROOT/scripts/trusted-authors-normalize.sh` reads the cleaned set and, for every `<name>[bot]` or `app/<name>` entry, **adds the other shape** to the set. So a file with `sentry[bot]` produces `{sentry[bot], app/sentry}`; a file with `app/sentry` produces `{app/sentry, sentry[bot]}`. Either form matches the GraphQL `author.login` value the orchestrator compares against. Human logins (no `[bot]` suffix, no `app/` prefix) pass through unchanged.

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
# Branch 1 (override file present) — read + normalize in one pipeline:
allowlist_file=".shipyard/trusted-authors.txt"
trusted_authors=$(
  {
    cat "$allowlist_file"
    printf '%s\n' "<owner>"   # repo owner is implicitly trusted
  } | "$CLAUDE_PLUGIN_ROOT/scripts/trusted-authors-normalize.sh"
)

# The advisory log SHOULD report which aliases were applied so the
# maintainer knows the normalization fired (issue #296 acceptance criterion):
"$CLAUDE_PLUGIN_ROOT/scripts/trusted-authors-normalize.sh" \
  --report-aliases "$allowlist_file" | while IFS= read -r line; do
  [ -z "$line" ] || echo "$line"
done
```

The helper is idempotent — running it on a set that already contains both forms produces the same set. The cross-alias is one-directional in the sense that the *content* is preserved (no shape is rewritten) — both shapes coexist after normalization.

The same normalization runs inside the GitHub Actions workflow that resolves the allowlist with the file-based pipeline (`.github/workflows/label-event-audit.yml`) — it inlines the alias-cross-add as a `sed` pipeline (workflows can't reach into the shipyard plugin's scripts dir from a consumer repo). (`.github/workflows/intake-refinement-gate.yml` previously inlined the same pipeline but was retired in [#520](https://github.com/mattsears18/shipyard/issues/520) when the refinement gate was eliminated.) The orchestrator-side helper and the workflow-side inlining are kept in sync by the `trusted-authors-normalize.test.sh` test suite plus a workflow-side smoke pattern (any change to the alias logic in one place must change it in both).

**Protect the override file with CODEOWNERS.** Because the file IS the security boundary, repos that adopt `/shipyard:do-work` should add a `.github/CODEOWNERS` rule naming the maintainer(s) for `.shipyard/trusted-authors.txt` **and** enable "Require review from Code Owners" in branch protection on the default branch — otherwise anyone with `write` access can extend the allowlist via a single PR with no maintainer in the loop. This repo's own CODEOWNERS setup is not currently a compliant reference example — see [RATIONALE → CODEOWNERS enforcement gap](../../../../../docs/design/do-work-rationale.md#step-17--codeowners-enforcement-gap-on-this-repo-867) before copying it as one.

**Output.** A single advisory line goes into the session log right after resolution:

- `[trusted-authors] loaded <K> author(s) from .shipyard/trusted-authors.txt`, or
- `[trusted-authors] loaded <K> collaborator(s) from repos/<owner/repo>/collaborators API`, or
- `[trusted-authors] fallback to repo owner only — <reason for API failure>`.

The count `<K>` is the **post-normalization** size — it includes both the alias expansions from [GH App alias normalization](#gh-app-alias-normalization-issue-296) and the implicitly-trusted repo owner. The advisory is one line — not a block, not a list of logins — so the startup output stays scannable.

When any GH-App aliases were added (one or more `<bot>[bot]` ↔ `app/<bot>` cross-adds fired), emit one additional `[trusted-authors] alias: <input> -> <added>` line per alias on the line immediately following the main advisory. Sourced from `trusted-authors-normalize.sh --report-aliases` so the maintainer can verify which form was matched. Skip when no aliases were needed (the typical human-only repo case) — silence is the right default.
