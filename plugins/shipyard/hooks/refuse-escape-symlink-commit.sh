#!/usr/bin/env bash
# PreToolUse hook — refuses any `git commit` Bash invocation whose staged file
# set contains a symlink whose target escapes the worktree (absolute path, or
# contains `..` segments).
#
# Motivation (#351): the worker-preamble's dependency-bootstrap step instructs
# Node-based workers to create a `node_modules → ../../../node_modules`
# symlink so the worktree can run `node_modules/.bin/<tool>` via the primary
# checkout's installed deps. The relative target resolves correctly from
# inside the worker's worktree (`/path/to/primary/.claude/worktrees/agent-<id>/
# node_modules` → `/path/to/primary/node_modules`), so the symlink "works"
# locally. But if the worker stages the symlink into a commit (via `git add -A`,
# a misclick, or a path matching a directory whose contents happen to include
# the symlink), the relative target becomes dangling on any other checkout:
#
#   - Downstream consumers who cherry-pick the commit see a `node_modules`
#     symlink pointing to a path that doesn't exist on their machine.
#   - `npm ci` writes a real node_modules into the dangling target — a
#     side-effect on whatever parent directory the target resolves to.
#   - Pre-commit hooks that need `node_modules/.bin/<tool>` see the symlink
#     shadowing the real install and fail in confusing ways.
#
# Repro session: re-landing mattsears18/lightwork#1125's work on a new branch
# (#1270) cherry-picked commit 804b26a from `do-work/issue-1124` and inherited
# the dangling symlink. The salvage commit `e5fca33 fix(repo): remove stray
# node_modules symlink from cherry-pick` had to clean it up.
#
# This hook is the load-bearing safety net. The worker-preamble skill telling
# the model "don't stage the bootstrap symlink" is necessary but not sufficient;
# this hook makes the omission impossible to ship — same shape of bug as the
# `enforce-worktree-isolation.sh` and `enforce-edit-scope.sh` hooks already
# enforce against parallel failure modes.
#
# Decision rules (ALL must hold to BLOCK):
#
#   1. Tool name is `Bash`.
#   2. The command string contains a token-boundary-matched `git commit`
#      invocation. The boundary check rules out:
#        - `git commit-tree` (different command)
#        - `git committed` / `echo committed` (substring match)
#        - `grep -r "git commit"` (quoted needle in another command)
#      and matches:
#        - `git commit -m ...`
#        - `git commit -am ...`
#        - `... && git commit ...`
#        - multi-line scripts with `git commit` on its own line
#        - heredoc-supplied commit messages (issue-work.md's canonical pattern)
#   3. The hook's `cwd` is a valid git working tree.
#   4. `git diff --cached --name-only --diff-filter=AM` produces at least one
#      path that is a symlink in the working tree AND whose target either:
#        - starts with `/` (absolute path), or
#        - contains a literal `..` path segment (escapes via parent dir).
#
# False-positive note: an intra-repo symlink with `../` in the target (e.g.
# `b/foo-link → ../a/foo.txt`) is also caught. That's accepted because (a)
# intra-repo symlinks with `..` are rare in practice and (b) the worker can
# unstage the symlink and the maintainer can land it manually on the rare
# occasion the false-positive fires. The cost of an extra manual confirmation
# is much lower than the cost of shipping a dangling-on-downstream symlink.
#
# Defensive defaults: malformed JSON, missing fields, non-git cwd — all fall
# through to exit 0 rather than block. A buggy hook that blocked every Bash
# call would be far worse than one that occasionally misses an escape symlink.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block, exit 0
# otherwise. Never propagate other errors.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)

# Bail early on empty input.
if [[ -z "$input" ]]; then
  exit 0
fi

# Parse the payload with python3 — same dependency as the companion hooks.
# Outputs one of:
#   ALLOW                                — pass-through
#   INSPECT\t<cwd>\t<command>            — needs symlink check in <cwd>
PY_DECIDE=$(cat <<'PY'
import json, re, sys

raw = sys.stdin.read() or ""
try:
    d = json.loads(raw)
except Exception:
    print("ALLOW")
    sys.exit(0)

if (d.get("tool_name") or "") != "Bash":
    print("ALLOW")
    sys.exit(0)

tool_input = d.get("tool_input") or {}
cmd = tool_input.get("command") or ""
cwd = d.get("cwd") or ""

if not cmd or not cwd:
    print("ALLOW")
    sys.exit(0)

# Token-boundary match for `git commit`. The character classes around the
# tokens rule out:
#   - `git commit-tree` (the trailing `-` is not in [\s$])
#   - `git committed` / `committed` (the trailing letter is not in [\s$])
#   - `xgit commit` (the leading `x` is not in [\s^])
# and match all the forms listed in the hook header.
#
# Note re: quoted-needle false-positives (`grep -r "git commit"`): we can't
# easily distinguish a quoted needle from a real invocation without a real
# shell parser, so we accept the false-positive cost. In practice, a grep
# matching `git commit` won't have staged escape-symlinks, so the inspection
# in step 2 returns ALLOW anyway. The worst case is one extra `git diff
# --cached` per false-positive — negligible.
#
# But specifically: a `grep -r 'git commit' docs/` shouldn't trigger an
# inspection at all because the literal `git commit` is inside single quotes
# and the user clearly isn't running a commit. To stay conservative, we ALSO
# check that the matched invocation isn't entirely inside a balanced single-
# or double-quote pair starting before it. This is a heuristic, not a full
# shell parse; it catches the common case.
#
# Final regex: `(?<![A-Za-z0-9_-])git[\s]+commit(?![A-Za-z0-9_-])`
# Plus the quote heuristic implemented separately.

pattern = re.compile(r'(?<![A-Za-z0-9_-])git[\s]+commit(?![A-Za-z0-9_-])')

def in_quotes(text, idx):
    # True if position idx is inside a balanced single- or double-quote pair
    # starting before idx. Simple counter: backslash escapes the next char.
    # Doesn't handle shell parameter expansion. Conservative: when in doubt
    # returns False so we INSPECT (safe-side default).
    sq = 0  # single-quote depth
    dq = 0  # double-quote depth
    i = 0
    while i < idx:
        c = text[i]
        if c == chr(92) and i + 1 < len(text):  # chr(92) is backslash
            i += 2
            continue
        if c == chr(39) and dq == 0:  # chr(39) is apostrophe
            sq = 1 - sq
        elif c == chr(34) and sq == 0:  # chr(34) is double quote
            dq = 1 - dq
        i += 1
    return sq == 1 or dq == 1

real_invocations = [
    m for m in pattern.finditer(cmd)
    if not in_quotes(cmd, m.start())
]

if not real_invocations:
    print("ALLOW")
    sys.exit(0)

# Emit cwd and command so the bash side can run the inspection. Tabs as
# separators are fine because cwd shouldn't contain tabs (and if it does, the
# inspection step will likely fail and we'll fall through to ALLOW anyway).
print(f"INSPECT\t{cwd}")
PY
)

decision=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null || true)

case "${decision%%$'\t'*}" in
  INSPECT)
    cwd="${decision#*$'\t'}"
    ;;
  *)
    exit 0
    ;;
esac

# Validate cwd is a real git working tree. If `git rev-parse` fails (not a
# repo, missing `.git`, permissions), fall through to ALLOW — the `git commit`
# itself will fail with a clearer error, and false-blocking on a corrupt cwd
# would be worse than letting the original command error.
if ! ( cd "$cwd" && git rev-parse --show-toplevel >/dev/null 2>&1 ); then
  exit 0
fi

# Enumerate staged paths (added or modified) and find any whose index mode
# is `120000` (symlink) AND whose target string is "escape" — absolute, or
# contains a `..` path segment.
#
# Implementation note (why this is python, not pure shell): bash's
# `read -r -d ''` against process substitution from an `awk -v ORS='\0'`
# pipeline doesn't work cleanly on macOS — BSD awk doesn't reliably emit
# NULs via ORS, and `$(...)` capture strips trailing NULs. The python
# subshell does the whole walk in-process: list staged paths, query the
# index, classify targets, emit escapes as a `\n`-delimited list.
#
# The escape definition matches what would land in a commit: a literal
# `..` segment in the target makes the symlink dangle on any checkout
# whose path-from-target-anchor doesn't resolve to the same place. An
# absolute target is always wrong (hard-coded to the worker's host).
escapes=$(
  cwd="$cwd" python3 <<'PY' 2>/dev/null || true
import os, subprocess, sys

cwd = os.environ.get("cwd", "")
if not cwd:
    sys.exit(0)

def git(*args):
    return subprocess.run(
        ("git",) + args, cwd=cwd, capture_output=True, check=False,
    )

# 1. Staged paths (added or modified), NUL-delimited.
r = git("diff", "--cached", "--name-only", "--diff-filter=AM", "-z")
if r.returncode != 0:
    sys.exit(0)
paths = [p for p in r.stdout.split(b"\x00") if p]

# 2. For each staged path, query the index for mode + oid. ls-files --stage
#    output: "<mode> <oid> <stage>\t<path>\0" (with -z).
escapes = []
for p in paths:
    r = git("ls-files", "--stage", "-z", "--", p)
    if r.returncode != 0:
        continue
    rec = r.stdout.rstrip(b"\x00").decode("utf-8", errors="replace")
    if "\t" not in rec:
        continue
    meta, path = rec.split("\t", 1)
    parts = meta.split(" ")
    if len(parts) < 3:
        continue
    mode, oid = parts[0], parts[1]
    if mode != "120000":
        continue

    # 3. Read the symlink target. Prefer the index blob (always accurate,
    #    even if the worktree symlink was deleted after staging). Fall back
    #    to readlink against the worktree only if cat-file fails.
    r2 = git("cat-file", "-p", oid)
    if r2.returncode == 0 and r2.stdout:
        target = r2.stdout.decode("utf-8", errors="replace")
    else:
        full = os.path.join(cwd, path)
        try:
            target = os.readlink(full)
        except OSError:
            continue
    if not target:
        continue

    # 4. Escape check. Absolute target OR any path segment equal to "..".
    is_escape = False
    if target.startswith("/"):
        is_escape = True
    else:
        for seg in target.split("/"):
            if seg == "..":
                is_escape = True
                break

    if is_escape:
        escapes.append(f"{path} -> {target}")

if escapes:
    print("\n".join(escapes))
PY
)

if [[ -z "$escapes" ]]; then
  exit 0
fi

cat >&2 <<EOF
BLOCKED by shipyard/hooks/refuse-escape-symlink-commit.sh.

You attempted to commit one or more symlinks whose target escapes the worktree
(absolute path, or contains \`..\` segments):

$(printf '%s' "$escapes" | sed 's/^/  /')

These are almost always worker-bootstrap artifacts — e.g. the
\`node_modules → ../../../node_modules\` symlink that the worker-preamble's
dependency-bootstrap step creates so the worktree can run
\`node_modules/.bin/<tool>\` from the primary checkout's installed deps. The
symlink works from inside YOUR worktree (the relative target resolves to a
real directory), but becomes dangling on any other checkout — downstream
consumers who cherry-pick the commit get a symlink pointing to a path that
doesn't exist on their machine, \`npm ci\` writes a real node_modules into the
dangling target, and pre-commit hooks shadowed by the symlink fail in
confusing ways. See issue #351 for the original repro.

Fix:
  1. Unstage the symlink:    git restore --staged <path>
  2. Optionally remove it:   rm <path>
  3. Re-run \`git commit\`.

If you need the symlink locally for the worker's lifetime but DON'T want it
shipped, add it to the per-worktree exclude file (NOT the repo \`.gitignore\`,
which would be a public spec change):

  echo node_modules >> .git/info/exclude

If you genuinely need to commit an escape symlink (rare — and a strong signal
to re-think the design), return \`blocked:\` so a human can decide. This hook
intentionally has no bypass flag.
EOF

exit 2
