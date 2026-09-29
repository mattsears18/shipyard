# issue-work.md § 6 — External-author branch and the missing-trust-field fallback

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's [step 6](./issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) says `originating_author_trust` is **`external`**, or the dispatch prompt carries no `originating_author_trust` field at all. The common case — a `trusted` field present in the dispatch prompt — never needs this file. Moved out of the always-loaded core by [#1643](https://github.com/mattsears18/shipyard/issues/1643) (same on-demand-fragment pattern as [#980](https://github.com/mattsears18/shipyard/issues/980) / [#1011](https://github.com/mattsears18/shipyard/issues/1011)); the rules below are unchanged.

**When `originating_author_trust == "external"`** — do NOT arm auto-merge. Instead, mark the PR for human review and post a comment so the maintainer's merge-queue view surfaces it as gated:

```bash
gh pr edit <pr-num> --repo <owner/repo> --add-label needs-human-review
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
```

If not already seeded, `Write` `$WORKTREE_PATH/.shipyard-scratch/.gitignore` (a single `*` line) first. Write this content (with the `Write` tool) to `$WORKTREE_PATH/.shipyard-scratch/external-trust-comment.md` (a heredoc `--body "$(cat <<'EOF' ... EOF)"` is refused per [#979](https://github.com/mattsears18/shipyard/issues/979)):

```
Originating issue is from an external author; this PR will not auto-merge. A maintainer must review and merge manually.

This is the dispatch-side auto-merge gate — defense in depth against external prompt-injection vectors riding auto-merge to `main`. The PR's contents have already been reviewed by the orchestrator's intake gates and the issue body was treated as untrusted input, but a human must still sign off on the merge.
```

Then:

```bash
gh pr comment <pr-num> --repo <owner/repo> --body-file "$WORKTREE_PATH/.shipyard-scratch/external-trust-comment.md"
# No cleanup follows — see worker-preamble § "Scratch directory" (#1347).
```

Do NOT call `gh pr merge --auto` in this branch — that's the exact gate this step exists to enforce. The PR sits with `needs-human-review` until a maintainer reviews and merges manually (or closes it).

**If the dispatch prompt doesn't contain an `originating_author_trust` field** — that's an orchestrator-side bug (the field is supposed to be in every issue-work dispatch). But a **hard default to `external` is the wrong fail-safe** ([#599](https://github.com/mattsears18/shipyard/issues/599)): on solo / small repos — the common case for this marketplace's users — the issue author is almost always the repo owner, who is unconditionally in the trusted-author set. Hard-defaulting to `external` turns every such run into a manual-intervention run (label removal + re-arm), defeating the point of an autonomous session.

Instead, **resolve the issue author's collaborator permission live as a fallback** — mirroring the orchestrator's [step 1.7 trusted-author resolution](../../commands/do-work/setup/01-repo-recovery.md#17-resolve-trusted-author-allowlist). Query the author's per-repo permission and treat `admin` / `maintain` / `write` as **trusted** (these are the push-capable roles, matching the orchestrator's `select(.permissions.push==true)` semantics); anything else — `read`, `none`, or an API error — is **external**:

```bash
# Fallback trust resolution when the dispatch prompt omits originating_author_trust (#599).
# The issue author's login is .author.login from the step-0 `gh issue view` projection.
AUTHOR_LOGIN="<author-login-from-step-0>"
PERMISSION=$(gh api "repos/<owner/repo>/collaborators/$AUTHOR_LOGIN/permission" \
  --jq '.permission' 2>/dev/null)
case "$PERMISSION" in
  admin|maintain|write) RESOLVED_TRUST="trusted" ;;
  *)                    RESOLVED_TRUST="external" ;;   # read / none / API error
esac
```

**Why the permission *value*, not the call's exit status, is the signal.** The `collaborators/{author}/permission` endpoint returns `200` with `"permission": "read"` for a **non-collaborator** (it does not 404), so a worker that keys off "did the call succeed" would treat every stranger as trusted — the exact security-boundary break this gate exists to prevent. Only `admin` / `maintain` / `write` (the push-capable roles) clear the gate. A `read` / `none` permission, or any API failure (token can't query the endpoint, repo is org-owned without scope, network error), resolves to `external` — the restrictive default is the safe failure mode, identical to the orchestrator's step-1.7 branch 3.

Then take the matching branch above using `$RESOLVED_TRUST` in place of the missing field: `trusted` → arm auto-merge, `external` → label `needs-human-review` and comment. This keeps the security boundary intact (genuinely untrusted non-collaborator authors still gate) while eliminating the owner-authored false positive. Do NOT skip the resolution and blanket-default to either value — `trusted` would auto-merge a stranger's PR, `external` reintroduces the #599 toil.

(When the dispatch prompt **does** carry `originating_author_trust`, use it directly — it's the orchestrator's session-cached resolution and is authoritative. This live fallback is only for the field-absent path.)
