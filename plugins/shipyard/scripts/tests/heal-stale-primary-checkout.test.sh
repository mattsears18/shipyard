#!/usr/bin/env bash
# Test: scripts/heal-stale-primary-checkout.sh — setup step 0.41's staleness
# GATE (issue #1386).
#
# Two halves, both load-bearing:
#
#   (A) The SCRIPT's own behavior against real git fixtures — every verdict
#       (fresh / healed / dirty-refuse / branch-refuse / attempt-refuse /
#       heal-failed / error), plus the two invariants that make the write
#       safe: it only ever fast-forwards, and it never touches a dirty tree
#       or a primary parked off the default branch.
#
#   (B) The SPEC's wiring — that `00-config-worktree.md` still carries the
#       step-0.41 pointer and that `00i-staleness-gate.md` still invokes the
#       script and enumerates every verdict. A gate documented as "warn and
#       continue" is the exact bug #1386 closes, so a silent downgrade back
#       to advisory prose must red the build even though the script itself
#       would still pass (A).
#
# Pure bash + git, no network, no external deps. Run with:
#
#   bash plugins/shipyard/scripts/tests/heal-stale-primary-checkout.test.sh

# setup-fragment-content-scan: allow-file
# This suite's checks against $router verify the 00-config-worktree.md
# POINTER wiring to its own purpose-built fragment (00i-staleness-gate.md,
# created specifically to house step 0.41) — router-pointer-correctness and
# a fragment's own canonical content, not generic step content that could
# drift to an unrelated file on a future split (issue #1453).
set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../heal-stale-primary-checkout.sh"
router="$here/../../commands/do-work/setup/00-config-worktree.md"
spec="$here/../../commands/do-work/setup/00i-staleness-gate.md"

echo "heal-stale-primary-checkout.sh tests (issue #1386)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

# --- field extraction helper ----------------------------------------------
field() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# --- fixture builder -------------------------------------------------------
# Builds an "upstream" bare repo plus a clone standing in for the user's
# PRIMARY checkout, then advances upstream by N commits so the clone is
# measurably behind. Pin the default branch (worker-preamble § "Pin the
# default branch in git-using test fixtures", issue #475) so the fixture is
# deterministic regardless of the host's init.defaultBranch.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# Sets the global FIXTURE_PRIMARY rather than echoing the path: a command
# substitution would run this in a subshell (losing the counter) and would
# also swallow git's own stdout into the "path" it returned.
FIXTURE_PRIMARY=""
fixture_n=0
make_fixture() {
  # $1 = number of commits to advance upstream by (0 = clone stays fresh)
  local ahead="$1"
  fixture_n=$((fixture_n+1))
  local root="$tmproot/f$fixture_n"
  local up="$root/upstream"
  mkdir -p "$root"

  {
    git init -q -b main "$up"
    (
      cd "$up" || exit 1
      git config user.email test@example.com
      git config user.name 'Test User'
      echo seed > seed.txt
      git add seed.txt
      git commit -q -m seed
    )

    git clone -q -b main "$up" "$root/primary"
    (
      cd "$root/primary" || exit 1
      git config user.email test@example.com
      git config user.name 'Test User'
    )

    local i
    for (( i = 0; i < ahead; i++ )); do
      (
        cd "$up" || exit 1
        echo "advance $i" >> seed.txt
        git commit -q -am "advance $i"
      )
    done
  } >/dev/null 2>&1

  FIXTURE_PRIMARY="$root/primary"
}

# --- (1) fresh: primary not behind ----------------------------------------
make_fixture 0; p="$FIXTURE_PRIMARY"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "fresh" && "$code" -eq 0 ]]; then
  ok "not behind: verdict=fresh, exit=0"
else
  bad "not behind: got verdict='$(field verdict "$out")' exit=$code (expected fresh/0)"
fi

# --- (2) healed: behind + clean + on default branch ------------------------
make_fixture 3; p="$FIXTURE_PRIMARY"
before="$(git -C "$p" rev-parse HEAD)"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
after="$(git -C "$p" rev-parse HEAD)"
if [[ "$(field verdict "$out")" == "healed" && "$code" -eq 0 ]]; then
  ok "behind + clean + on default: verdict=healed, exit=0"
else
  bad "behind + clean: got verdict='$(field verdict "$out")' exit=$code (expected healed/0)"
fi
if [[ "$(field behind_before "$out")" == "3" && "$(field behind_after "$out")" == "0" ]]; then
  ok "healed: behind_before=3 -> behind_after=0"
else
  bad "healed: got behind_before='$(field behind_before "$out")' behind_after='$(field behind_after "$out")'"
fi
if [[ "$before" != "$after" && "$after" == "$(git -C "$p" rev-parse origin/main)" ]]; then
  ok "healed: primary HEAD actually advanced to origin/main"
else
  bad "healed: primary HEAD did not advance to origin/main"
fi
# The fast-forward must produce NO merge commit — a lossless linear advance.
if [[ -z "$(git -C "$p" rev-list --merges "$before..$after")" ]]; then
  ok "healed: fast-forward only (no merge commit created)"
else
  bad "healed: a merge commit was created — the write was not a fast-forward"
fi
if grep -q "restart setup from step 0.3" <<<"$(field reason "$out")"; then
  ok "healed: reason instructs the caller to restart setup from step 0.3"
else
  bad "healed: reason does not name the restart-from-0.3 contract"
fi

# --- (3) dirty-refuse: behind + uncommitted changes -----------------------
make_fixture 2; p="$FIXTURE_PRIMARY"
echo "local edit" >> "$p/seed.txt"
before="$(git -C "$p" rev-parse HEAD)"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "dirty-refuse" && "$code" -eq 1 ]]; then
  ok "behind + dirty tree: verdict=dirty-refuse, exit=1"
else
  bad "behind + dirty: got verdict='$(field verdict "$out")' exit=$code (expected dirty-refuse/1)"
fi
if [[ "$(git -C "$p" rev-parse HEAD)" == "$before" ]] && grep -q "local edit" "$p/seed.txt"; then
  ok "dirty-refuse: primary HEAD unmoved and the uncommitted edit survives"
else
  bad "dirty-refuse: the primary checkout was modified despite the refusal"
fi
if grep -q "pull --ff-only" <<<"$(field reason "$out")"; then
  ok "dirty-refuse: reason names the actionable 'git pull --ff-only' remedy"
else
  bad "dirty-refuse: reason does not name 'git pull --ff-only'"
fi

# --- (3b) staged-only tracked change still refuses (#1616) ---------------
# The #1616 split narrows the dirty predicate to TRACKED modifications — it
# must still catch a staged-but-uncommitted edit, not only a worktree one.
make_fixture 2; p="$FIXTURE_PRIMARY"
echo "staged edit" >> "$p/seed.txt"
git -C "$p" add seed.txt
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "dirty-refuse" && "$code" -eq 1 ]]; then
  ok "behind + staged tracked change: verdict=dirty-refuse, exit=1"
else
  bad "behind + staged change: got verdict='$(field verdict "$out")' exit=$code (expected dirty-refuse/1)"
fi

# --- (3c) untracked-only tree heals (#1616) --------------------------------
# Untracked tool artifacts (.codex/, AGENTS.md, ...) cannot be lost by a
# fast-forward, so they must not trip dirty-refuse.
make_fixture 2; p="$FIXTURE_PRIMARY"
mkdir -p "$p/.codex"
echo "tool scratch" > "$p/.codex/state"
echo "agent notes" > "$p/AGENTS.md"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "healed" && "$code" -eq 0 ]]; then
  ok "behind + untracked-only tree: verdict=healed, exit=0"
else
  bad "behind + untracked-only: got verdict='$(field verdict "$out")' exit=$code (expected healed/0)"
fi
if [[ "$(git -C "$p" rev-parse HEAD)" == "$(git -C "$p" rev-parse origin/main)" ]]; then
  ok "untracked-only heal: primary HEAD advanced to origin/main"
else
  bad "untracked-only heal: primary HEAD did not advance to origin/main"
fi
if grep -q "tool scratch" "$p/.codex/state" 2>/dev/null && grep -q "agent notes" "$p/AGENTS.md" 2>/dev/null; then
  ok "untracked-only heal: the untracked files survive byte-for-byte"
else
  bad "untracked-only heal: an untracked file was lost or modified"
fi

# --- (3d) untracked path the incoming commits would add: heal-failed ------
# git must refuse the fast-forward rather than overwrite the untracked file;
# the script surfaces that as heal-failed, never a clobber.
make_fixture 0; p="$FIXTURE_PRIMARY"
up="$(dirname "$p")/upstream"
(
  cd "$up" || exit 1
  echo "upstream version" > incoming.txt
  git add incoming.txt
  git commit -q -m "add incoming.txt"
) >/dev/null 2>&1
git -C "$p" fetch -q origin >/dev/null 2>&1
echo "my local untracked copy" > "$p/incoming.txt"
before="$(git -C "$p" rev-parse HEAD)"
out="$(bash "$script" run --primary "$p" --default-branch main --no-fetch)"
code=$?
if [[ "$(field verdict "$out")" == "heal-failed" && "$code" -eq 2 ]]; then
  ok "behind + colliding untracked path: verdict=heal-failed, exit=2"
else
  bad "behind + colliding untracked: got verdict='$(field verdict "$out")' exit=$code (expected heal-failed/2)"
fi
if [[ "$(git -C "$p" rev-parse HEAD)" == "$before" ]] \
   && [[ "$(cat "$p/incoming.txt")" == "my local untracked copy" ]]; then
  ok "colliding untracked: HEAD unmoved and the untracked file was not clobbered"
else
  bad "colliding untracked: the primary was modified or the untracked file clobbered"
fi
if grep -q "untracked file" <<<"$(field reason "$out")"; then
  ok "colliding untracked: reason names the untracked-file collision"
else
  bad "colliding untracked: reason does not name the untracked collision: $(field reason "$out")"
fi

# --- (4) branch-refuse: behind + parked on a feature branch ---------------
make_fixture 2; p="$FIXTURE_PRIMARY"
git -C "$p" checkout -q -b my-feature
before="$(git -C "$p" rev-parse HEAD)"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "branch-refuse" && "$code" -eq 1 ]]; then
  ok "behind + off default branch: verdict=branch-refuse, exit=1"
else
  bad "behind + feature branch: got verdict='$(field verdict "$out")' exit=$code (expected branch-refuse/1)"
fi
if [[ "$(git -C "$p" symbolic-ref --short -q HEAD)" == "my-feature" \
      && "$(git -C "$p" rev-parse HEAD)" == "$before" ]]; then
  ok "branch-refuse: the user's HEAD and branch are left untouched"
else
  bad "branch-refuse: the primary's HEAD or branch moved despite the refusal"
fi

# --- (5) heal-failed: behind + clean, but a local commit blocks the ff ----
make_fixture 2; p="$FIXTURE_PRIMARY"
(
  cd "$p" || exit 1
  echo diverged > local-only.txt
  git add local-only.txt
  git commit -q -m "local-only commit"
)
before="$(git -C "$p" rev-parse HEAD)"
out="$(bash "$script" run --primary "$p" --default-branch main)"
code=$?
if [[ "$(field verdict "$out")" == "heal-failed" && "$code" -eq 2 ]]; then
  ok "behind + diverged: verdict=heal-failed, exit=2 (never a merge commit)"
else
  bad "behind + diverged: got verdict='$(field verdict "$out")' exit=$code (expected heal-failed/2)"
fi
if [[ "$(git -C "$p" rev-parse HEAD)" == "$before" ]]; then
  ok "heal-failed: the primary's local commit was not clobbered"
else
  bad "heal-failed: the primary's HEAD moved despite the failed fast-forward"
fi

# --- (6) attempt-refuse: the restart loop is capped ------------------------
make_fixture 2; p="$FIXTURE_PRIMARY"
out="$(bash "$script" run --primary "$p" --default-branch main --attempt 2 --max-attempts 2)"
code=$?
if [[ "$(field verdict "$out")" == "attempt-refuse" && "$code" -eq 1 ]]; then
  ok "attempt at the cap: verdict=attempt-refuse, exit=1 (restart loop bounded)"
else
  bad "attempt at cap: got verdict='$(field verdict "$out")' exit=$code (expected attempt-refuse/1)"
fi
# ...and the cap must not fire below it.
out="$(bash "$script" run --primary "$p" --default-branch main --attempt 1 --max-attempts 2)"
if [[ "$(field verdict "$out")" == "healed" ]]; then
  ok "attempt below the cap: still heals"
else
  bad "attempt below cap: got verdict='$(field verdict "$out")' (expected healed)"
fi

# --- (7) error: not a git checkout ----------------------------------------
non_git="$tmproot/not-a-repo"
mkdir -p "$non_git"
out="$(bash "$script" run --primary "$non_git" --default-branch main 2>/dev/null)"
code=$?
if [[ "$(field verdict "$out")" == "error" && "$code" -eq 3 ]]; then
  ok "non-git primary path: verdict=error, exit=3"
else
  bad "non-git primary: got verdict='$(field verdict "$out")' exit=$code (expected error/3)"
fi

# --- (8) error: no remote-tracking ref for the named default branch -------
make_fixture 0; p="$FIXTURE_PRIMARY"
out="$(bash "$script" run --primary "$p" --default-branch nonexistent-branch --no-fetch 2>/dev/null)"
code=$?
if [[ "$(field verdict "$out")" == "error" && "$code" -eq 3 ]]; then
  ok "unresolvable origin/<branch>: verdict=error, exit=3 (never silently 'fresh')"
else
  bad "unresolvable ref: got verdict='$(field verdict "$out")' exit=$code (expected error/3)"
fi

# --- (9) usage errors ------------------------------------------------------
bash "$script" run --primary "$p" >/dev/null 2>&1
if [[ $? -eq 64 ]]; then
  ok "missing --default-branch: exit=64 (bad usage)"
else
  bad "missing --default-branch: expected exit 64"
fi
bash "$script" bogus-subcommand >/dev/null 2>&1
if [[ $? -eq 64 ]]; then
  ok "unknown subcommand: exit=64"
else
  bad "unknown subcommand: expected exit 64"
fi

# --- (10) every emitted verdict is a documented one ------------------------
# Guards against a new verdict landing in the script without the spec's
# branch table (checked in B below) growing a matching row.
declare -a known=(fresh healed dirty-refuse branch-refuse attempt-refuse heal-failed error)
emitted="$(grep -oE 'emit "[a-z-]+"' "$script" | sed 's/emit "//; s/"//' | sort -u)"
unknown=""
while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  found=0
  for k in "${known[@]}"; do [[ "$v" == "$k" ]] && found=1; done
  (( found == 0 )) && unknown="$unknown $v"
done <<<"$emitted"
if [[ -z "$unknown" ]]; then
  ok "script emits only the 7 documented verdicts"
else
  bad "script emits undocumented verdict(s):$unknown — add them to the spec's branch table"
fi

# --- (11) the write is narrow: no stash / clean / reset --hard / checkout --
# The whole safety argument for touching the primary checkout is that the
# ONLY write is a fast-forward. Anything else would silently widen the
# `dont.md` carve-out.
forbidden=0
while IFS= read -r pattern; do
  if grep -qE "$pattern" "$script"; then
    bad "script contains a forbidden primary-checkout write: $pattern"
    forbidden=1
  fi
done <<'EOF'
git -C "\$PRIMARY_CHECKOUT" stash
git -C "\$PRIMARY_CHECKOUT" clean
git -C "\$PRIMARY_CHECKOUT" reset
git -C "\$PRIMARY_CHECKOUT" checkout
EOF
(( forbidden == 0 )) && ok "script's only primary-checkout write is the fast-forward (no stash/clean/reset/checkout)"

# ===========================================================================
# (B) Spec wiring — the gate must stay a GATE
# ===========================================================================
echo
echo "  spec wiring (00i-staleness-gate.md + 00-config-worktree.md pointer)"

# The step-0.41 POINTER must survive in 00-config-worktree.md: that file is
# the one every session reads at step 0.4, so a pointer lost there makes the
# gate unreachable no matter how correct the fragment is.
if [[ ! -f "$router" ]]; then
  bad "router file missing: $router"
else
  if grep -qE '^### 0\.41 ' "$router"; then
    ok "00-config-worktree.md carries the '### 0.41' step heading"
  else
    bad "00-config-worktree.md lost its '### 0.41' heading — the gate is unreachable"
  fi
  if grep -qF '00i-staleness-gate.md' "$router"; then
    ok "00-config-worktree.md points at 00i-staleness-gate.md"
  else
    bad "00-config-worktree.md no longer points at the 00i fragment"
  fi
  # The pointer must sit BETWEEN 0.4 and 0.42 — the gate has to fire before
  # any of the recovery steps it supersedes.
  l4=$(grep -nE '^### 0\.4 ' "$router" | head -1 | cut -d: -f1)
  l41=$(grep -nE '^### 0\.41 ' "$router" | head -1 | cut -d: -f1)
  l42=$(grep -nE '^### 0\.42 ' "$router" | head -1 | cut -d: -f1)
  if [[ -n "$l4" && -n "$l41" && -n "$l42" ]] && (( l4 < l41 && l41 < l42 )); then
    ok "step 0.41 is ordered between 0.4 and 0.42"
  else
    bad "step 0.41 is not ordered between 0.4 and 0.42 (0.4=$l4 0.41=$l41 0.42=$l42)"
  fi
fi

if [[ ! -f "$spec" ]]; then
  bad "spec file missing: $spec"
else
  if grep -qE '^### 0\.41 ' "$spec"; then
    ok "fragment carries the '### 0.41' step heading"
  else
    bad "fragment lost its '### 0.41' step heading — the gate has no anchor"
  fi

  if grep -q 'heal-stale-primary-checkout.sh' "$spec"; then
    ok "fragment invokes heal-stale-primary-checkout.sh"
  else
    bad "fragment no longer invokes heal-stale-primary-checkout.sh"
  fi

  # The gate's whole point: staleness must STOP the session, not warn.
  if grep -qF 'STOP. Do not continue setup' "$spec"; then
    ok "fragment's refusal branch is a hard stop, not an advisory"
  else
    bad "fragment's refusal branch no longer says STOP — #1386's warn-and-continue bug is back"
  fi

  if grep -qF 'restart setup from [step 0.3]' "$spec"; then
    ok "fragment's healed branch restarts setup from step 0.3"
  else
    bad "fragment's healed branch no longer restarts from step 0.3 (stale context would survive the heal)"
  fi

  missing=""
  for v in dirty-refuse branch-refuse attempt-refuse heal-failed error healed fresh; do
    grep -qF "$v" "$spec" || missing="$missing $v"
  done
  if [[ -z "$missing" ]]; then
    ok "fragment enumerates all 7 verdicts"
  else
    bad "fragment does not enumerate verdict(s):$missing"
  fi

  # #1386's second damage path must stay in the acceptance surface.
  if grep -qF 'SHIPYARD_REPO_ROOT' "$spec" && grep -qF '#1059' "$spec"; then
    ok "fragment's 0.41 rationale covers the SHIPYARD_REPO_ROOT / stale-config damage path"
  else
    bad "fragment lost the stale-config (#1059 pin) damage path from 0.41's rationale"
  fi
fi

# --- (12) shellcheck-clean -------------------------------------------------
echo
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$script" >/tmp/heal-stale-shellcheck.$$ 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported issues: $(cat "/tmp/heal-stale-shellcheck.$$")"
  fi
  rm -f "/tmp/heal-stale-shellcheck.$$"
else
  echo "  (shellcheck not installed locally — skipping; CI's shellcheck.yml still gates this)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
