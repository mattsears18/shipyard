#!/usr/bin/env bash
# detect-host-git-health.sh — decide whether this host's system `git` is usable
# by the HARNESS ITSELF, before `/shipyard:do-work` pays a full setup pass
# (issue #1567).
#
# Background (issue #1567)
# ------------------------
# On macOS, when `xcode-select -p` points at `/Applications/Xcode.app` and the
# Xcode license has not been accepted, `/usr/bin/git` (the `xcrun` shim) fails
# EVERY call with `You have not agreed to the Xcode license agreements`. A shell
# caller can route around it with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`,
# so the orchestrator's own Bash-tool calls can be made to work — but Claude
# Code's own internal git calls never see that variable, and those are what
# every isolation mechanism runs on:
#
#   * `EnterWorktree` (`name:` form)  -> "Could not read the repository git
#     config to neutralize filter drivers"
#   * `EnterWorktree` (`path:` form, the #1066 recovery) -> "`git -C <repo>
#     worktree list` failed: You have not agreed to the Xcode license agreements"
#   * `Agent(isolation: "worktree")`  -> the same filter-drivers error. Every
#     mode shim declares `isolation: worktree`, so NO `Agent` dispatch shape
#     works at all.
#   * The `Workflow`-substrate alternate provisions the worktree fine with raw
#     git, but the dispatched worker's own git calls hit the same license error
#     and the worker can only return `blocked` — which stamps
#     `needs-human-review` on a perfectly workable issue.
#
# The failure is deterministic and host-wide, and it is detectable in one cheap
# call at the very top of setup. Before this script existed, it surfaced only at
# step 7 — after ~15 minutes of setup — with nothing in the spec naming the
# cause or the fix. Session `do-work-20260916T112450Z-93563`, 2026-09-16
# ~11:25-11:40 UTC, against `mattsears18/shipyard` (plugin 4.55.3), is the
# first-hand repro.
#
# Do NOT attempt to route around a failing verdict. The harness's own git calls
# cannot be fixed from a shell prefix, so every downstream isolation mechanism
# is already known dead; the only correct response is to stop the session and
# print the remediation.
#
# Two modes, so the DECISION LOGIC is unit-testable without a genuinely broken
# host — same shape as detect-ungated-admin-direct-merge.sh's and
# detect-stale-node-modules.sh's `--decide` mode. (A host that has since
# accepted its Xcode license CANNOT reproduce the failing state, which is
# precisely why the classifier must be drivable from recorded exit codes and
# stderr text rather than only from live probing.)
#
#   --decide <version_exit> <version_stderr> [<revparse_exit> <revparse_stderr>]
#       Pure classification of an already-captured probe result. No process or
#       filesystem I/O. This is what the regression test drives.
#
#   (no arguments)
#       Live mode: probes `git --version` and `git rev-parse --show-toplevel`
#       in the current directory, then classifies the same way.
#
# Live-mode probes deliberately run with DEVELOPER_DIR UNSET (`env -u`). A
# caller that has already worked around a broken host by exporting
# DEVELOPER_DIR would otherwise mask the very failure this check exists to
# find: the shell would succeed while the harness still fails. Set
# SHIPYARD_GIT_BIN to point the probe at a different git binary (the test suite
# uses this to inject a stub that reproduces the failing host).
#
# Verdicts printed to stdout as `verdict=<word>`, and what a caller does with each:
#   healthy       — git works. Proceed with setup. (exit 0)
#   not-a-repo    — git works, but the current directory is not a git working
#                   tree. NOT a host-git failure; whether that matters is the
#                   caller's business. (exit 0)
#   xcode-license — the #1567 case: git is installed but every call fails on an
#                   unaccepted Xcode license. STOP the session and print the
#                   remediation below. (exit 1)
#   git-unusable  — git fails for some other reason (not installed, broken
#                   install, PATH problem). Same posture: STOP the session; the
#                   remediation is host-specific. (exit 1)
#
# Usage: `/shipyard:do-work` setup step 0.2, before any other setup work.
set -u

EX_USAGE=64

usage() {
  echo "usage: $0" >&2
  echo "       $0 --decide <version_exit> <version_stderr> [<revparse_exit> <revparse_stderr>]" >&2
  echo "       $0 --help" >&2
  echo "note: live mode takes NO arguments — it probes git in the current directory." >&2
}

die_usage() {
  echo "USAGE_ERROR: $1"
  echo "detect-host-git-health: usage error (exit $EX_USAGE): $1" >&2
  usage
  exit "$EX_USAGE"
}

# Lowercase without bash 4's ${var,,} — this must also run under macOS's
# bundled bash 3.2.
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Does this stderr text name the unaccepted-Xcode-license failure?
#
# Matched substrings, any one of which is sufficient:
#   "agreed to the xcode license"  — the canonical `/usr/bin/git` message
#                                    ("You have not agreed to the Xcode license
#                                    agreements"), and the same text the
#                                    EnterWorktree path-form error quotes back.
#   "xcodebuild -license"          — the variant that names the remediation
#                                    command directly.
#   "xcrun: error"                 + "license"  — the shim's own wrapper form.
is_xcode_license() {
  local s
  s="$(lower "${1:-}")"
  case "$s" in
    *"agreed to the xcode license"*) return 0 ;;
    *"xcodebuild -license"*) return 0 ;;
    *"xcode license"*) return 0 ;;
  esac
  if [[ "$s" == *"xcrun: error"* && "$s" == *"license"* ]]; then
    return 0
  fi
  return 1
}

# Does this rev-parse stderr just mean "you are not inside a repo"?
is_not_a_repo() {
  local s
  s="$(lower "${1:-}")"
  case "$s" in
    *"not a git repository"*) return 0 ;;
    *"does not appear to be a git repository"*) return 0 ;;
  esac
  return 1
}

decide() {
  local version_exit="$1" version_stderr="$2"
  local revparse_exit="$3" revparse_stderr="$4"

  # `git --version` is the primary probe: it touches no repository at all, so a
  # non-zero exit can only mean the binary itself is unusable on this host.
  if [[ "$version_exit" != "0" ]]; then
    if is_xcode_license "$version_stderr"; then
      echo "xcode-license"
    else
      echo "git-unusable"
    fi
    return
  fi

  # `git --version` succeeded. A rev-parse failure is usually just "not in a
  # repo", but classify the license text first anyway — a partially-broken
  # toolchain that answers --version from a cached shim while failing every
  # repository operation is exactly the shape that wasted a full setup pass,
  # and mistaking it for "not a repo" would let the session proceed.
  if [[ "$revparse_exit" != "0" ]]; then
    if is_xcode_license "$revparse_stderr"; then
      echo "xcode-license"
      return
    fi
    if is_not_a_repo "$revparse_stderr"; then
      echo "not-a-repo"
      return
    fi
    echo "git-unusable"
    return
  fi

  echo "healthy"
}

# Print the caller-facing remediation for a failing verdict. Kept in one place
# so the spec prose and the script can never drift on the exact commands.
print_remediation() {
  local verdict="$1"
  if [[ "$verdict" == "xcode-license" ]]; then
    {
      echo "detect-host-git-health: this host's git is unusable — the Xcode license has not been accepted."
      echo "Every Claude Code isolation mechanism (EnterWorktree, Agent(isolation: \"worktree\"),"
      echo "and a dispatched worker's own git calls) runs on git and will fail. A DEVELOPER_DIR"
      echo "shell prefix does NOT fix it: the harness's own git calls never see that variable."
      echo "Fix the host, then re-run the session. Either of:"
      echo "  sudo xcodebuild -license accept"
      echo "  sudo xcode-select -s /Library/Developer/CommandLineTools"
      echo "Do not attempt to route around this (issue #1567)."
    } >&2
  else
    {
      echo "detect-host-git-health: this host's git is unusable (see the probe output above)."
      echo "Every Claude Code isolation mechanism runs on git, so no worker can be dispatched."
      echo "Fix the host's git installation, then re-run the session (issue #1567)."
    } >&2
  fi
}

emit() {
  local verdict="$1"
  echo "verdict=$verdict"
  case "$verdict" in
    healthy | not-a-repo) exit 0 ;;
    *)
      print_remediation "$verdict"
      exit 1
      ;;
  esac
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --decide)
    if [[ $# -lt 3 ]]; then
      die_usage "--decide needs at least <version_exit> <version_stderr>"
    fi
    decide "${2:-}" "${3:-}" "${4:-0}" "${5:-}"
    exit 0
    ;;
  "") ;;
  *)
    die_usage "unrecognized argument: $1"
    ;;
esac

# --- Live mode -------------------------------------------------------------
GIT_BIN="${SHIPYARD_GIT_BIN:-git}"

# `env -u DEVELOPER_DIR` is load-bearing, not hygiene: a caller that already
# worked around a broken host by exporting DEVELOPER_DIR would otherwise get a
# clean `healthy` here while the harness's own git calls still fail.
version_stderr="$(env -u DEVELOPER_DIR "$GIT_BIN" --version 2>&1 >/dev/null)"
version_exit=$?

revparse_stderr="$(env -u DEVELOPER_DIR "$GIT_BIN" rev-parse --show-toplevel 2>&1 >/dev/null)"
revparse_exit=$?

VERDICT="$(decide "$version_exit" "$version_stderr" "$revparse_exit" "$revparse_stderr")"

echo "detect-host-git-health: git --version exit=$version_exit rev-parse exit=$revparse_exit -> $VERDICT" >&2
if [[ -n "$version_stderr" ]]; then
  echo "  git --version stderr: $version_stderr" >&2
fi
if [[ -n "$revparse_stderr" ]]; then
  echo "  git rev-parse stderr: $revparse_stderr" >&2
fi

emit "$VERDICT"
