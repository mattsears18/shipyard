#!/usr/bin/env bash
# report-plugin-error.sh — automatically file (or comment on) a GitHub issue when
# a skill/agent in this plugin appears to have failed during a user's session.
#
# Invoked by hooks/hooks.json on PostToolUse(Task|Agent) and SubagentStop. Reads
# the hook payload from stdin as JSON. Opt-in only — exits 0 if
# SHIPYARD_AUTOREPORT is not set to "1".
#
# This script is the entire reporting pipeline. The hook is a one-line shim;
# putting the logic here keeps it shell-script-testable (see
# scripts/tests/report-plugin-error.test.sh).
#
# Pipeline (when enabled):
#
#   1. Detect failure signal in the payload (explicit error field, exit code,
#      "blocked:" / "Error:" / "failed:" markers in the agent output).
#   2. Extract metadata: skill/agent name, invocation prompt, error excerpt,
#      transcript path, environment info.
#   3. Scrub secrets (API key patterns, $HOME paths, common token shapes).
#   4. Build a signature (skill/agent name + normalized error). Search the
#      auto-reported open issues for a match. If found, add a comment instead
#      of opening a duplicate.
#   5. Otherwise, file a new issue with the standard auto-report body
#      (sections: What happened / Skill-Agent / Reproduction / Error details /
#      Environment / Transcript excerpt / Recommendations).
#
# Environment variables:
#
#   SHIPYARD_AUTOREPORT      — must be "1" to enable. Default: off.
#   SHIPYARD_AUTOREPORT_REPO — target repo (owner/repo). Default:
#                                    mattsears18/shipyard.
#   SHIPYARD_AUTOREPORT_DRY  — when "1", print the would-be issue to
#                                    stdout instead of calling gh. Used by the
#                                    test suite and for local development.
#
# Exit codes:
#
#   0 — nothing to do (opt-out, no failure detected, dedup'd, or dry-run).
#       Anything else means we hit an unexpected error in the helper itself.
#       We never propagate a non-zero exit back to the hook — failing to file
#       an auto-report must not break the user's session.

set -u

# Belt-and-braces — never propagate failure to the caller. The hook also
# discards stderr, but defense in depth is worth one trap.
trap 'exit 0' ERR

# Read the JSON payload from stdin (the hook pipes it through unchanged).
payload=$(cat)

# --------------------------------------------------------------------------
# Opt-in gate
# --------------------------------------------------------------------------
if [[ "${SHIPYARD_AUTOREPORT:-}" != "1" ]]; then
  exit 0
fi

target_repo="${SHIPYARD_AUTOREPORT_REPO:-mattsears18/shipyard}"
dry_run="${SHIPYARD_AUTOREPORT_DRY:-0}"

# --------------------------------------------------------------------------
# Python helpers are stored as bash variables so we can run them via
# `python3 -c "$VAR"` while leaving the function's stdin available for the
# pipeline data. The pitfall to avoid: `python3 - <<'PY'` would redirect the
# function's stdin to the heredoc, losing the piped JSON payload.
# Single-quoted heredoc delimiter ('PY') preserves backslashes/dollars/quotes
# literally inside the python source.
# --------------------------------------------------------------------------

PY_DETECT_FAILURE=$(cat <<'PY'
import json, sys

raw = sys.stdin.read() or "{}"
try:
    d = json.loads(raw)
except Exception:
    print("no"); sys.exit(0)

tr = d.get("tool_response") or {}
if isinstance(tr, dict):
    if tr.get("is_error") is True:
        print("yes"); sys.exit(0)
    if tr.get("error"):
        print("yes"); sys.exit(0)
    if tr.get("stderr"):
        print("yes"); sys.exit(0)

if d.get("error") is True:
    print("yes"); sys.exit(0)

def collect(o, out):
    if isinstance(o, str):
        out.append(o)
    elif isinstance(o, list):
        for x in o:
            collect(x, out)
    elif isinstance(o, dict):
        for v in o.values():
            collect(v, out)

parts = []
collect(tr, parts)
collect(d.get("tool_input"), parts)
text = "\n".join(parts).lower()

markers = [
    "blocked:", "blocked at",
    "traceback (most recent call last)",
    "uncaughtexception",
    "fatal:",
    "error: ", "errno",
    "command not found",
    "permission denied",
    "this didn't work", "that did not work", "doesn't work",
    "is broken",
]
if any(m in text for m in markers):
    print("yes"); sys.exit(0)

print("no")
PY
)

PY_EXTRACT_FIELD=$(cat <<'PY'
import json, os, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
path = os.environ.get("EXTRACT_PATH", "").lstrip(".")
cur = d
for seg in path.split("."):
    if isinstance(cur, dict):
        cur = cur.get(seg)
    else:
        cur = None
    if cur is None:
        break
if isinstance(cur, (dict, list)):
    sys.stdout.write(json.dumps(cur))
elif cur is not None:
    sys.stdout.write(str(cur))
PY
)

PY_SCRUB=$(cat <<'PY'
import os, re, sys

s = sys.stdin.read()
home = os.environ.get("HOME_FOR_SCRUB", "")
if home and home not in ("/", ""):
    s = s.replace(home, "~")

patterns = [
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"), "<REDACTED_GH_TOKEN>"),
    (re.compile(r"sk-ant-[A-Za-z0-9\-_]{20,}"), "<REDACTED_ANTHROPIC_KEY>"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "<REDACTED_OPENAI_KEY>"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "<REDACTED_AWS_ACCESS_KEY>"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9\-_.=]{16,}"), "Bearer <REDACTED>"),
    (re.compile(r"(?i)authorization:\s*\S+"), "Authorization: <REDACTED>"),
    (re.compile(r"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+"), "<REDACTED_EMAIL>"),
    (re.compile(r"\b[A-Fa-f0-9]{40,}\b"), "<REDACTED_HEX>"),
]
for pat, repl in patterns:
    s = pat.sub(repl, s)

sys.stdout.write(s)
PY
)

PY_TRUNCATE=$(cat <<'PY'
import os, sys
m = int(os.environ.get("MAX_CHARS", "2000"))
s = sys.stdin.read()
if len(s) <= m:
    sys.stdout.write(s)
else:
    sys.stdout.write(s[:m] + f"\n\n... [truncated, {len(s)} chars total]")
PY
)

PY_NORMALIZE_ERROR=$(cat <<'PY'
import re, sys
s = sys.stdin.read().lower()
s = re.sub(r"\s+", " ", s)
s = re.sub(r"\d+", "N", s)
s = re.sub(r"[^a-z N]+", " ", s)
s = re.sub(r"\s+", " ", s).strip()
sys.stdout.write(s[:80])
PY
)

PY_EXTRACT_ERROR_TEXT=$(cat <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw); sys.exit(0)
parts = []
if isinstance(d, dict):
    for k in ("error", "stderr", "stdout", "content", "output"):
        v = d.get(k)
        if isinstance(v, str):
            parts.append(v)
        elif isinstance(v, list):
            for x in v:
                if isinstance(x, str):
                    parts.append(x)
                elif isinstance(x, dict) and "text" in x:
                    parts.append(x["text"])
elif isinstance(d, list):
    for x in d:
        if isinstance(x, str):
            parts.append(x)
        elif isinstance(x, dict) and "text" in x:
            parts.append(x["text"])
sys.stdout.write("\n".join(parts) or raw)
PY
)

PY_BUILD_DRYRUN=$(cat <<'PY'
import json, os, sys
print(json.dumps({
    "title": os.environ["TITLE"],
    "body": os.environ["BODY"],
    "labels": ["auto-reported", "bug"],
    "signature": os.environ["SIGNATURE"],
    "who": os.environ["WHO"],
}))
PY
)

PY_PICK_FIRST_NUMBER=$(cat <<'PY'
import json, sys
try:
    d = json.loads(sys.stdin.read() or "[]")
except Exception:
    d = []
print(d[0]["number"] if d else "")
PY
)

# Tiny convenience wrappers — each runs a python program with stdin from a
# bash pipeline. Exported helpers all read from stdin and write to stdout.
detect_failure() { python3 -c "$PY_DETECT_FAILURE"; }
extract_field() { EXTRACT_PATH="$1" python3 -c "$PY_EXTRACT_FIELD"; }
scrub() { HOME_FOR_SCRUB="${HOME:-/Users/nobody}" python3 -c "$PY_SCRUB"; }
truncate_text() { MAX_CHARS="${1:-2000}" python3 -c "$PY_TRUNCATE"; }
normalize_error() { python3 -c "$PY_NORMALIZE_ERROR"; }
extract_error_text() { python3 -c "$PY_EXTRACT_ERROR_TEXT"; }

# --------------------------------------------------------------------------
# Main pipeline.
# --------------------------------------------------------------------------

failed=$(printf '%s' "$payload" | detect_failure)
if [[ "$failed" != "yes" ]]; then
  exit 0
fi

# Extract identifying metadata. Multiple possible shapes — PostToolUse with the
# Task/Agent tool, or SubagentStop with a transcript path.
hook_event=$(printf '%s' "$payload" | extract_field ".hook_event_name")
tool_name=$(printf '%s' "$payload" | extract_field ".tool_name")
subagent_type=$(printf '%s' "$payload" | extract_field ".tool_input.subagent_type")
skill_name=$(printf '%s' "$payload" | extract_field ".tool_input.skill")
invocation_prompt=$(printf '%s' "$payload" | extract_field ".tool_input.prompt")
tool_description=$(printf '%s' "$payload" | extract_field ".tool_input.description")
transcript_path=$(printf '%s' "$payload" | extract_field ".transcript_path")
tool_response_raw=$(printf '%s' "$payload" | extract_field ".tool_response")

# Identifier — prefer subagent_type, fall back to skill, then tool_name.
who="${subagent_type:-${skill_name:-${tool_name:-unknown}}}"

# Only act on shipyard-namespaced skills/agents — we don't want to file
# issues against this repo for failures unrelated to our plugin.
case "$who" in
  shipyard:*|shipyard/*) ;;
  *)
    # Filter is intentional: false negatives are fine, false positives waste
    # maintainer time.
    exit 0
    ;;
esac

# Error excerpt — concatenate the failure-bearing fields, scrub, truncate.
error_excerpt_raw=$(printf '%s' "$tool_response_raw" | extract_error_text)
error_excerpt=$(printf '%s' "$error_excerpt_raw" | scrub | truncate_text 2000)

invocation_prompt=$(printf '%s' "$invocation_prompt" | scrub | truncate_text 1000)
tool_description=$(printf '%s' "$tool_description" | scrub)

# Transcript excerpt — last ~80 lines of the transcript, scrubbed + truncated.
transcript_excerpt=""
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
  transcript_excerpt=$(tail -n 80 "$transcript_path" 2>/dev/null | scrub | truncate_text 3000)
fi

# Signature for de-dup.
normalized_error=$(printf '%s' "$error_excerpt" | normalize_error)
signature="autoreport-key=${who}::${normalized_error}"

# Environment fingerprint.
os_name=$(uname -s 2>/dev/null || echo unknown)
os_release=$(uname -r 2>/dev/null || echo unknown)
shell_name=$(basename "${SHELL:-unknown}")
cc_version="${CLAUDE_CODE_VERSION:-unknown}"
cc_model="${CLAUDE_MODEL:-${ANTHROPIC_MODEL:-unknown}}"
session_kind="${CLAUDE_SESSION_KIND:-local}"

# Short error summary for the title — first non-empty line, trimmed.
error_summary=$(printf '%s' "$error_excerpt" \
  | sed -E 's/^[[:space:]]+//' \
  | grep -E -m1 '\S' 2>/dev/null || true)
error_summary=${error_summary:0:80}
[[ -z "$error_summary" ]] && error_summary="failure detected"

title="[auto] ${who} failed: ${error_summary}"

# --------------------------------------------------------------------------
# Build the issue body (template per issue #22).
# --------------------------------------------------------------------------
body=$(cat <<EOF
## What happened

A skill/agent from the \`shipyard\` plugin appears to have failed during a Claude Code session. This issue was filed automatically by \`scripts/report-plugin-error.sh\` (see \`SHIPYARD_AUTOREPORT\` in the plugin README).

## Skill/Agent

- **Name:** \`${who}\`
- **Hook event:** \`${hook_event:-unknown}\`
- **Tool:** \`${tool_name:-unknown}\`

## Reproduction

Invoked with:

\`\`\`
${tool_description:-(no description provided)}
\`\`\`

Prompt excerpt:

\`\`\`
${invocation_prompt:-(no prompt captured)}
\`\`\`

## Error details

\`\`\`
${error_excerpt}
\`\`\`

## Environment

- **OS:** ${os_name} ${os_release}
- **Shell:** ${shell_name}
- **Claude Code version:** ${cc_version}
- **Model:** ${cc_model}
- **Session kind:** ${session_kind}

## Transcript excerpt

<details>
<summary>Last lines of the agent transcript</summary>

\`\`\`
${transcript_excerpt:-(transcript not available)}
\`\`\`

</details>

## Recommendations for improvement

These are pattern-level suggestions, not bespoke fixes — a maintainer should still confirm before acting.

- Add explicit input validation around the failing entry point so the error surfaces with a clearer message.
- Wrap the failing tool call in a retry or fallback path if the failure looks transient.
- Capture the failing arguments in the skill/agent's own error output so future repros don't need a transcript.
- If the failure is a recurring user-confusion signal (rather than code), update the skill description / examples in \`SKILL.md\` to steer the model away from this path.

<!-- ${signature} -->
EOF
)

# --------------------------------------------------------------------------
# Dry-run short-circuit — emit a single JSON object for the test harness.
# --------------------------------------------------------------------------
if [[ "$dry_run" == "1" ]]; then
  TITLE="$title" BODY="$body" SIGNATURE="$signature" WHO="$who" \
    python3 -c "$PY_BUILD_DRYRUN"
  exit 0
fi

# --------------------------------------------------------------------------
# De-dup search → comment-or-file.
# --------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  # No gh available; we're done. We never break the user's session.
  exit 0
fi

# Search OPEN auto-reported issues for one whose body carries the same
# signature. gh's --search syntax supports `in:body`.
existing_num=$(gh issue list --repo "$target_repo" \
  --state open \
  --label auto-reported \
  --search "in:body \"${signature}\"" \
  --json number \
  --limit 5 2>/dev/null \
  | python3 -c "$PY_PICK_FIRST_NUMBER" 2>/dev/null || true)

if [[ -n "$existing_num" ]]; then
  comment_body=$(cat <<EOF
Another occurrence reported by \`report-plugin-error.sh\`.

**Skill/Agent:** \`${who}\`
**When:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

\`\`\`
$(printf '%s' "$error_excerpt" | head -c 800)
\`\`\`

<!-- ${signature} -->
EOF
)
  gh issue comment "$existing_num" --repo "$target_repo" --body "$comment_body" >/dev/null 2>&1 || true
  exit 0
fi

# Otherwise: file a fresh issue.
gh issue create --repo "$target_repo" \
  --title "$title" \
  --label "auto-reported" \
  --label "bug" \
  --body "$body" >/dev/null 2>&1 || true

exit 0
