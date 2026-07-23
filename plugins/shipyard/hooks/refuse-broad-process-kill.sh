#!/usr/bin/env bash
# PreToolUse hook — refuses any `Bash` invocation that kills processes by
# name/pattern instead of by a specific, known PID.
#
# Motivation (#751): a `/shipyard:do-work` worker ran
# `pkill -9 -f "playwright test"` to clean up what it believed were its own
# leftover local processes. The target repo's GitHub Actions ran on
# self-hosted runners installed on the SAME physical host the agent was
# working on. Nothing in the worker's context distinguishes "processes I
# spawned" from "processes the self-hosted runner spawned" — both run as the
# same user, on the same host, often from paths under the same repo root, and
# with identical process names (`playwright`, `node`, `metro`, an emulator).
# The pattern-based kill matched the runner's in-flight CI processes and
# killed two E2E shards of the very PR the worker was trying to get green —
# a silent, un-attributed violation of the "never cancel an in-progress CI
# run" operating principle, committed by a worker that never touched a CI
# surface and had no way to know it was cancelling anything.
#
# `shipyard:worker-preamble`'s "Never run a broad process kill" section (the
# hot core, not a fragment — this is a destructive-action guard at the same
# tier as the worktree-isolation rules) tells the worker not to do this. This
# hook is the load-bearing enforcement — the same "stick vs carrot" pairing
# `enforce-worktree-isolation.sh` and `enforce-edit-scope.sh` already use for
# their respective prose rules. Prose alone did not prevent the #751 repro.
#
# Decision rules (ANY holds to BLOCK):
#
#   1. Tool name is `Bash`.
#   2. The command string contains a token-boundary-matched `pkill`
#      invocation (any arguments) — pkill ALWAYS targets processes by
#      name/pattern, so there is no safe form of it for a worker to use.
#   3. OR the command string contains a token-boundary-matched `killall`
#      invocation (any arguments) — same rationale as pkill.
#   4. OR the command string contains a token-boundary-matched `kill`
#      invocation used together with a process-pattern lookup (`pgrep`, or a
#      `ps` piped through `grep`) — the classic "look up PIDs matching a name,
#      then kill them" two-step that reintroduces the same hazard as pkill
#      without using the `pkill` binary itself. EXCEPTION (#804): a `kill`
#      invocation whose signal argument is explicitly `0` (`kill -0`,
#      `kill -s 0`, `kill -n 0`) sends no signal at all — POSIX defines
#      signal 0 as a permission-and-existence check — so it cannot terminate
#      anything and does not count as a "kill" for this rule. Only a
#      non-zero-signal `kill` combined with a pattern lookup still blocks.
#
# What is NOT blocked: `kill <pid>` (or `kill -9 <pid>`, `kill -TERM <pid>`)
# against a literal, specific PID — that's the safe form the worker-preamble
# section tells workers to use instead (track the PID of a process you
# yourself spawned, kill only that PID). Also not blocked (#804): `kill -0`
# / `kill -s 0` / `kill -n 0` against any PID, even when combined with a
# process-pattern lookup elsewhere in the same command — signal 0 is a
# liveness/permission probe, not a termination signal, and this idiom is
# shipyard's own documented `is-active` primitive
# (`scripts/session-state.sh`).
#
# False-positive note: this hook cannot verify that a `kill <pid>` PID
# actually belongs to a process the worker spawned — it only distinguishes
# "kill by pattern" (always unsafe on a self-hosted-runner host) from "kill by
# literal PID" (the worker's own responsibility to get right). Same posture
# as `refuse-escape-symlink-commit.sh`: a heuristic, not a full analysis, with
# an accepted false-positive/negative cost documented rather than perfectly
# resolved.
#
# Defensive defaults: malformed JSON, missing fields — fall through to exit 0
# rather than block. A buggy hook that blocked every Bash call would be far
# worse than one that occasionally misses a broad kill.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block, exit 0
# otherwise. Never propagate other errors. No bypass flag.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)

# Bail early on empty input.
if [[ -z "$input" ]]; then
  exit 0
fi

# Parse + decide with python3 — same dependency as the companion hooks.
# Outputs one of:
#   ALLOW
#   BLOCK\t<reason-tag>\t<matched-fragment>
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

if not cmd:
    print("ALLOW")
    sys.exit(0)

def in_quotes(text, idx):
    # True if position idx is inside a balanced single- or double-quote pair
    # starting before idx. Simple counter: backslash escapes the next char.
    # Doesn't handle shell parameter expansion. Conservative: when in doubt
    # returns False so we still inspect (safe-side default) — matches the
    # posture of refuse-escape-symlink-commit.sh.
    sq = 0
    dq = 0
    i = 0
    while i < idx:
        c = text[i]
        if c == chr(92) and i + 1 < len(text):  # backslash escapes next char
            i += 2
            continue
        if c == chr(39) and dq == 0:  # single quote
            sq = 1 - sq
        elif c == chr(34) and sq == 0:  # double quote
            dq = 1 - dq
        i += 1
    return sq == 1 or dq == 1

def real_matches(pattern):
    return [m for m in pattern.finditer(cmd) if not in_quotes(cmd, m.start())]

# Signal-zero exemption for rule 4 (#804): `kill -0`, `kill -s 0`, `kill -n 0`
# send NO signal — POSIX defines signal 0 as a permission-and-existence check
# only — so a `kill` invocation using it cannot terminate anything, and a
# liveness probe against a literal PID (shipyard's own
# `scripts/session-state.sh` `is-active` uses exactly this idiom) should not
# combine with a pattern lookup elsewhere in the same command to trigger rule
# 4. Narrow and deliberate: only the explicit signal-0 spellings match here.
# Any other signal (numeric, symbolic, or the default SIGTERM when no signal
# flag is given) is NOT exempted, so `kill -9 $(pgrep ...)` still blocks.
signal_zero_re = re.compile(r'^\s+(-0\b|-s\s*0\b|-n\s*0\b)')

def is_signal_zero_kill(end_pos):
    # Inspect what immediately follows a matched `kill` token (its putative
    # signal argument) without needing full shell-argument parsing — a fixed
    # lookahead window is enough for the `-0` / `-s 0` / `-n 0` spellings.
    tail = cmd[end_pos:end_pos + 20]
    return signal_zero_re.match(tail) is not None

# Token-boundary match: not preceded/followed by an identifier character or
# hyphen, so `pkill` doesn't match inside `mypkillwrapper`, and a path like
# `./scripts/pkill-helper.sh` still matches (the boundary chars are `/` and
# `-`, neither of which is in the excluded class after the token) — accepted,
# same conservative-inspection posture as the sibling hooks.
pkill_re = re.compile(r'(?<![A-Za-z0-9_])pkill(?![A-Za-z0-9_])')
killall_re = re.compile(r'(?<![A-Za-z0-9_])killall(?![A-Za-z0-9_])')
kill_re = re.compile(r'(?<![A-Za-z0-9_])kill(?![A-Za-z0-9_])')
pgrep_re = re.compile(r'(?<![A-Za-z0-9_])pgrep(?![A-Za-z0-9_])')
ps_grep_re = re.compile(r'(?<![A-Za-z0-9_])ps\b[^|;&\n]*\|\s*[A-Za-z0-9_./ -]*\bgrep\b')

pkill_hits = real_matches(pkill_re)
if pkill_hits:
    print("BLOCK\tpkill\tpkill")
    sys.exit(0)

killall_hits = real_matches(killall_re)
if killall_hits:
    print("BLOCK\tkillall\tkillall")
    sys.exit(0)

kill_hits = real_matches(kill_re)
if kill_hits:
    # Drop signal-zero kill invocations before checking rule 4 — see
    # is_signal_zero_kill above (#804). A command containing ONLY signal-zero
    # kills alongside a pattern lookup (e.g. `kill -0 $PID && ps | grep foo`)
    # no longer matches; a command with at least one non-zero-signal kill
    # still does.
    non_zero_kill_hits = [m for m in kill_hits if not is_signal_zero_kill(m.end())]
    if non_zero_kill_hits:
        pgrep_hits = real_matches(pgrep_re)
        ps_grep_hits = real_matches(ps_grep_re)
        if pgrep_hits or ps_grep_hits:
            print("BLOCK\tkill+pattern-lookup\tkill combined with pgrep/ps|grep")
            sys.exit(0)

print("ALLOW")
PY
)

decision=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null || true)

if [[ "${decision%%$'\t'*}" != "BLOCK" ]]; then
  exit 0
fi

reason_tag=$(printf '%s' "$decision" | cut -f2)

cat >&2 <<EOF
BLOCKED by shipyard/hooks/refuse-broad-process-kill.sh.

You attempted a broad, pattern-based process kill (matched: ${reason_tag}).

Nothing in a worker's context distinguishes "processes I spawned" from
"processes a self-hosted CI runner spawned" — both can run as the same user,
on the same host, under identical process names (playwright, node, metro, an
emulator). A pattern-based kill (\`pkill\`, \`killall\`, or \`kill\` fed PIDs
looked up via \`pgrep\`/\`ps | grep\`) cannot tell them apart. On a repo whose
CI runs on self-hosted runners on this same host, this class of command can
silently cancel in-flight CI — another PR's, or main's — without you ever
touching a CI surface. See issue #751 for the original repro (a worker's
\`pkill -9 -f "playwright test"\` killed two E2E shards of its own PR's CI).

Fix:
  1. Track the PID of any process YOU spawn this session (the Bash tool's
     background-call response includes it, or capture \$! immediately after
     backgrounding a foreground command).
  2. Kill only that specific PID:  kill <pid>   (or kill -9 <pid>)
  3. If you cannot establish that a PID is yours, leave it alone — note the
     leftover process in your return string rather than guessing.

If you genuinely need a broad kill (rare, and a strong signal to re-think the
approach), return \`blocked:\` so a human can decide. This hook intentionally
has no bypass flag.
EOF

exit 2
