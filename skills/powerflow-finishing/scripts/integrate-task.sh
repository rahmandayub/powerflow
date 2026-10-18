#!/usr/bin/env bash
set -euo pipefail

# Coordinated single-task integration for Powerflow (Tahap 3).
#
# Merges ONE task branch into the integration branch under the integration
# lock (see integration-lock.sh), so parallel tasks can never merge
# concurrently. Every merge is followed by caller-provided verification run on
# the MERGED result — a task that passed tests in its own worktree is NOT
# assumed safe once combined. On any failure the task branch AND worktree are
# kept for recovery; cleanup happens only after verification passes.
#
# Flow: acquire lock (lease TOKEN) -> heartbeat lease for the whole run ->
# pre-checks -> preflight evidence gate -> resolve integration branch ->
# locate the owning worktree (<loc>) -> assert lease -> sync (ff-only pull)
# -> stale/diverged gate -> overlap advisory -> assert lease -> merge ->
# verify -> cleanup worktree+branch (task-owned resources, ungated) ->
# release.
#
# Losing the lease aborts with exit 6 BEFORE any further shared mutation
# (sync pull, merge) — a failed heartbeat is recorded, never swallowed, and
# the live token is re-verified at each gate. Cleanup touches only
# task-owned resources, so it stays safe to finish after post-merge work.
#
# The orchestrator records decisions in summary.md (this script writes nothing
# there); the script appends machine-readable verification blocks to
# <task-dir>/executions/merge-verification.log.
#
# Usage:
#   integrate-task.sh --task-dir <dir> --verify-command <cmd> [--verify-command <cmd2>...]
#     [--allow-stale-base] [--offline] [--skip-preflight] [--stale-after N] [--porcelain]
#
#   Before merging, the Finishing preflight gate (validate-transition.sh
#   --preflight: Tier 1+2 PASS at the task HEAD, Tier 3 or a Small-task
#   waiver, clean tree, on the task branch) must pass inside the task
#   worktree — --verify-command alone (e.g. `true`) proves nothing about the
#   pre-merge evidence. --skip-preflight bypasses this explicitly and logs it.
#   --verify-command runs in <loc> after the merge (Tier 1 smoke, Tier 2
#     affected, Tier 3 full — pass each as a separate flag, in order).
#     At least one is required: merging without verification is refused.
#   --allow-stale-base merges even when the integration branch advanced past
#     the task's Base SHA (default: refuse with rebase instructions).
#   --offline skips the ff-only pull (explicit decision; the default tries it
#     whenever the integration branch has an upstream and refuses to continue
#     silently when the pull fails or no upstream exists).
#
# Exit codes: 0 integrated+verified | 1 error (incl. cleanup-after-merge
#   failure — the merge itself is recorded) | 2 usage, not a git repo, or
#   unreadable summary | 3 integration lock held | 4 needs attention
#   (preflight evidence, stale/diverged base, no-upstream sync, merge
#   conflict — all state kept) | 5 post-merge verification FAILED (merged
#   result kept in place for fix-forward or guarded reset — branch and
#   worktree are NOT deleted) | 6 integration lease lost mid-run (aborted
#   before further shared mutation — all state kept, re-queue the task).

TASK_DIR=""
ALLOW_STALE_BASE=false
OFFLINE=false
PORCELAIN_OUT=false
SKIP_PREFLIGHT=false
STALE_AFTER=1800
VERIFY_CMDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir) TASK_DIR="${2:-}"; shift 2 ;;
    --verify-command) VERIFY_CMDS+=("${2:-}"); shift 2 ;;
    --allow-stale-base) ALLOW_STALE_BASE=true; shift ;;
    --offline) OFFLINE=true; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    --stale-after) STALE_AFTER="${2:-}"; shift 2 ;;
    --porcelain) PORCELAIN_OUT=true; shift ;;
    *) echo "Usage: integrate-task.sh --task-dir <dir> --verify-command <cmd> [...] [--allow-stale-base] [--offline] [--skip-preflight] [--stale-after N] [--porcelain]" >&2; exit 2 ;;
  esac
done

[ -n "$TASK_DIR" ] || { echo "Error: --task-dir is required" >&2; exit 2; }
[ "${#VERIFY_CMDS[@]}" -gt 0 ] || { echo "Error: at least one --verify-command is required (unverified merges are refused)" >&2; exit 2; }
if ! [[ "$STALE_AFTER" =~ ^[0-9]+$ ]] || [ "$STALE_AFTER" -lt 1 ]; then
  echo "Error: --stale-after must be a positive integer" >&2; exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 2
fi

# Resolve script dir (for sibling scripts) without depending on $PATH.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCK_SH="$SCRIPT_DIR/integration-lock.sh"
RESOLVE_SH="$SCRIPT_DIR/resolve-integration-branch.sh"

# Task metadata lives in the MAIN root's .powerflow/ (see init-task-dir.sh):
# a relative --task-dir resolves against the main root, never against the
# caller's cwd — finishing from inside a task worktree with
# --task-dir .powerflow/<slug> must find the same summary.md.
MAIN_ROOT_EARLY=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}')
[ -n "$MAIN_ROOT_EARLY" ] || { echo "Error: cannot resolve repository root" >&2; exit 1; }
case "$TASK_DIR" in
  /*) TASK_DIR_ABS=$(realpath -m "$TASK_DIR") ;;
  *) TASK_DIR_ABS=$(realpath -m "$MAIN_ROOT_EARLY/$TASK_DIR") ;;
esac
SUMMARY="$TASK_DIR_ABS/summary.md"
[ -f "$SUMMARY" ] || { echo "Error: summary.md not found at $SUMMARY" >&2; exit 2; }
TASK_SLUG=$(basename "$TASK_DIR_ABS")
# Executions dir up front: the lease-loss flag must be writable from the
# moment the heartbeat starts (long before the merge log is opened).
mkdir -p "$TASK_DIR_ABS/executions"

field_of() { # field_of <label> -> value or empty (reads $SUMMARY)
  grep -Ei -m1 "^[*-][[:space:]]+$1:" "$SUMMARY" 2>/dev/null \
    | sed -E "s/^[*-][[:space:]]+$1:[[:space:]]*//I; s/[[:space:]]*$//" || true
}

BASE_BRANCH=$(field_of "Base branch")
BASE_REF=$(field_of "Base ref")
[ -n "$BASE_REF" ] || BASE_REF="$BASE_BRANCH"
BASE_SHA=$(field_of "Base SHA")
TASK_BRANCH=$(field_of "Task branch")
WT_PATH=$(field_of "Worktree path")

[ -n "$BASE_REF" ] || { echo "Error: summary.md Git State has no Base ref/branch — cannot integrate" >&2; exit 2; }
[ -n "$BASE_SHA" ] || { echo "Error: summary.md Git State has no Base SHA — cannot integrate" >&2; exit 2; }
[ -n "$TASK_BRANCH" ] || { echo "Error: summary.md Git State has no Task branch — cannot integrate" >&2; exit 2; }

if ! git show-ref --verify --quiet "refs/heads/$TASK_BRANCH" 2>/dev/null; then
  echo "Error: task branch $TASK_BRANCH no longer exists — nothing to integrate" >&2
  exit 1
fi

MAIN_ROOT="$MAIN_ROOT_EARLY"

# --- acquire the integration lock (released by trap) ---------------------------
# A heartbeat refreshes the lease for the whole run: even a >STALE_AFTER
# integration is never mistaken for a crash while this process lives. A real
# crash stops the heartbeat, so the queue still recovers via steal.
HEART_PID_INT=""
stop_integrate_heartbeat() {
  if [ -n "$HEART_PID_INT" ]; then
    kill "$HEART_PID_INT" 2>/dev/null || true
    wait "$HEART_PID_INT" 2>/dev/null || true
    HEART_PID_INT=""
  fi
}
LOCK_HELD=false
LEASE_TOKEN=""
release_lock() {
  stop_integrate_heartbeat
  if [ "$LOCK_HELD" = true ]; then
    # Token-scoped release: if our lease was stolen (even by a re-queued run
    # under the SAME slug), the token mismatch refuses — the trap can never
    # delete the new owner's lease.
    if [ -n "$LEASE_TOKEN" ]; then
      bash "$LOCK_SH" release --task "$TASK_SLUG" --token "$LEASE_TOKEN" >/dev/null 2>&1 || true
    fi
    LOCK_HELD=false
  fi
}
trap release_lock EXIT
heartbeat_every() {
  local want="${POWERFLOW_HEARTBEAT_INTERVAL:-60}" third
  [[ "$want" =~ ^[0-9]+$ ]] && [ "$want" -ge 1 ] || want=60
  third=$((STALE_AFTER / 3))
  [ "$third" -lt 1 ] && third=1
  [ "$want" -lt "$third" ] && printf '%s' "$want" || printf '%s' "$third"
}
# NOTE: no `!` here — `$?` after `! cmd` is the negated status (always 0).
# Stdout (porcelain) is captured for the lease TOKEN; human messages on
# stderr flow through untouched.
ACQ_OUT=$(bash "$LOCK_SH" acquire --task "$TASK_SLUG" --stale-after "$STALE_AFTER" --porcelain)
CODE=$?
if [ "$CODE" -ne 0 ]; then
  LOCK_HELD=false
  trap - EXIT
  exit "$CODE"  # 3 held, 1 race/error
fi
LEASE_TOKEN=$(printf '%s' "$ACQ_OUT" | grep '^TOKEN=' | cut -d= -f2 || true)
[ -n "$LEASE_TOKEN" ] || fail "acquire succeeded but returned no lease token — refusing to proceed without ownership proof"
LOCK_HELD=true
# Lease-loss detection: the heartbeat NEVER swallows failures — any failed
# refresh plants LEASE_LOST, and assert_lease re-verifies the live token
# before every shared mutation (sync pull, merge). Losing the lease aborts
# with exit 6 (state kept, re-queue) instead of merging blind.
LEASE_LOST="$TASK_DIR_ABS/executions/.lease-lost"
rm -f "$LEASE_LOST"
EVERY=$(heartbeat_every)
( while true; do
    sleep "$EVERY"
    bash "$LOCK_SH" heartbeat --task "$TASK_SLUG" --token "$LEASE_TOKEN" >/dev/null 2>&1 || touch "$LEASE_LOST"
  done ) &
HEART_PID_INT=$!

assert_lease() { # assert_lease <what> — exit 6 unless OUR token still holds
  local cur=""
  if [ -f "$LEASE_LOST" ]; then
    echo "Error: integration lease lost (heartbeat failed) before $1 — another integrator may hold the queue. All state kept; re-queue this task." >&2
    exit 6
  fi
  cur=$(bash "$LOCK_SH" status --porcelain 2>/dev/null | grep '^HOLDER_TOKEN=' | cut -d= -f2 || true)
  if [ "$cur" != "$LEASE_TOKEN" ]; then
    echo "Error: integration lease lost before $1 (holder token changed) — another integrator may hold the queue. All state kept; re-queue this task." >&2
    exit 6
  fi
}

fail() { echo "Error: $1" >&2; exit "${2:-1}"; }

# --- task worktree pre-check: must be clean and on the task branch -------------
WT_ACTIVE=false
if [ -n "$WT_PATH" ]; then
  if git worktree list --porcelain 2>/dev/null | grep -qx "worktree $WT_PATH"; then
    WT_ACTIVE=true
    WT_BRANCH=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
    [ "$WT_BRANCH" = "$TASK_BRANCH" ] || fail "task worktree $WT_PATH is on '$WT_BRANCH', not task branch '$TASK_BRANCH'"
    WT_DIRTY=$(git -C "$WT_PATH" status --porcelain 2>/dev/null | grep -v '^??' | grep -v '^ *$' || true)
    [ -z "$WT_DIRTY" ] || fail "task worktree $WT_PATH has uncommitted tracked changes — commit or stash before integrating"
  else
    echo "Note: recorded worktree $WT_PATH is not registered (removed out-of-band?); integrating from branch $TASK_BRANCH directly." >&2
  fi
fi
TASK_HEAD=$(git rev-parse --verify --quiet "$TASK_BRANCH") || fail "cannot resolve task branch $TASK_BRANCH"

# --- pre-integration evidence gate: the task must have passed the Finishing
# preflight (Tier 1+2 at HEAD, Tier 3 or Small-waiver, clean tree, on the task
# branch) BEFORE it may enter the shared branch. Runs in the task worktree so
# HEAD/SHA checks evaluate the task checkout, not the caller's. Legacy
# branch-mode tasks without a live worktree run it in the CURRENT checkout —
# but only when that checkout actually holds the task branch (the validator
# re-checks branch and cleanliness itself). Anything else refuses: evidence
# that cannot be verified stops the queue, and only --skip-preflight proceeds
# explicitly (logged).
VALIDATE_SH="$SCRIPT_DIR/../../using-powerflow/scripts/validate-transition.sh"
run_preflight_in() { # run_preflight_in <dir> — exit 4 unless the gate passes
  PREFLIGHT_OUT=$(cd "$1" && bash "$VALIDATE_SH" --task-dir "$TASK_DIR_ABS" --preflight 2>&1) || {
    echo "Error: pre-integration preflight FAILED for $TASK_BRANCH at $TASK_HEAD — run the missing tiers (or record a Tier 3 waiver for Small tasks) before queueing:" >&2
    printf '%s\n' "$PREFLIGHT_OUT" >&2
    exit 4
  }
  echo "Preflight passed for $TASK_BRANCH at ${TASK_HEAD:0:7}." >&2
}
if [ "$SKIP_PREFLIGHT" = true ]; then
  echo "WARNING: --skip-preflight given; pre-integration evidence NOT checked." >&2
elif [ "$WT_ACTIVE" = true ]; then
  run_preflight_in "$WT_PATH"
else
  HERE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
  if [ "$HERE_BRANCH" = "$TASK_BRANCH" ]; then
    echo "Note: no live task worktree; running preflight in current checkout ($HERE_BRANCH)." >&2
    run_preflight_in "$PWD"
  else
    echo "Error: no live task worktree and current checkout is on '$HERE_BRANCH', not task branch '$TASK_BRANCH' — preflight evidence cannot be verified." >&2
    echo "Re-run from the task checkout, or pass --skip-preflight to proceed explicitly (logged)." >&2
    exit 4
  fi
fi

# --- resolve integration branch + locate owning worktree (<loc>) ----------------
INTEGRATION_BRANCH=$(bash "$RESOLVE_SH" --task-dir "$TASK_DIR_ABS" --porcelain 2>/dev/null | grep '^INTEGRATION_BRANCH=' | cut -d= -f2 || true)
[ -n "$INTEGRATION_BRANCH" ] || fail "cannot resolve integration branch (see resolve-integration-branch.sh output above)"
[ "$TASK_BRANCH" != "$INTEGRATION_BRANCH" ] || fail "task branch equals integration branch ($TASK_BRANCH) — nothing to merge"

LOC=""
OWNER_CANDIDATE=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) OWNER_CANDIDATE="${line#worktree }" ;;
    "branch refs/heads/$INTEGRATION_BRANCH")
      LOC="$OWNER_CANDIDATE" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
if [ -n "$LOC" ]; then
  git -C "$LOC" symbolic-ref -q HEAD >/dev/null 2>&1 || fail "owning worktree $LOC is detached — cannot sync/merge there"
  [ "$(git -C "$LOC" rev-parse --abbrev-ref HEAD)" = "$INTEGRATION_BRANCH" ] || fail "owning worktree $LOC is not on $INTEGRATION_BRANCH"
  echo "Integration location: $LOC (owns $INTEGRATION_BRANCH)." >&2
else
  LOC="$MAIN_ROOT"
  echo "Integration branch $INTEGRATION_BRANCH checked out nowhere; taking it in $LOC." >&2
  git -C "$LOC" checkout -q "$INTEGRATION_BRANCH" 2>/dev/null || fail "cannot checkout $INTEGRATION_BRANCH in $LOC"
  git -C "$LOC" symbolic-ref -q HEAD >/dev/null 2>&1 || fail "detached HEAD after checkout in $LOC"
fi

# --- sync the integration branch ------------------------------------------------
assert_lease "syncing the integration branch"
if [ "$OFFLINE" = true ]; then
  echo "Note: offline mode — skipping pull (explicit decision)." >&2
else
  if git -C "$LOC" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git -C "$LOC" pull --ff-only >&2 || fail "pull --ff-only failed in $LOC (divergence, conflicts, or unreachable remote) — resolve it and re-run; never merging onto a stale/unknown base silently" 4
  else
    fail "integration branch $INTEGRATION_BRANCH has no upstream — pass --offline to merge without syncing (record that decision in summary.md) or set an upstream first" 4
  fi
fi
INT_HEAD_BEFORE=$(git -C "$LOC" rev-parse HEAD)

# --- stale / diverged gate -------------------------------------------------------
if [ "$BASE_SHA" = "$INT_HEAD_BEFORE" ]; then
  echo "Base current: $INTEGRATION_BRANCH is at the task's Base SHA (${BASE_SHA:0:7})." >&2
elif git merge-base --is-ancestor "$BASE_SHA" "$INT_HEAD_BEFORE" 2>/dev/null; then
  if [ "$ALLOW_STALE_BASE" = true ]; then
    echo "WARNING: stale base — $INTEGRATION_BRANCH advanced past Base SHA ${BASE_SHA:0:7}; merging anyway (--allow-stale-base)." >&2
  else
    echo "Error: stale base — $INTEGRATION_BRANCH advanced past Base SHA ${BASE_SHA:0:7}." >&2
    echo "Rebase the task onto $INTEGRATION_BRANCH, re-verify, then re-run — or pass --allow-stale-base to merge now (the post-merge verification below still gates)." >&2
    exit 4
  fi
else
  echo "Error: diverged base — Base SHA ${BASE_SHA:0:7} is not an ancestor of $INTEGRATION_BRANCH ($INT_HEAD_BEFORE). Rebase required." >&2
  exit 4
fi

# --- overlap advisory: semantic-conflict hint (informational; verify gates) -------
TASK_FILES=$(git diff --name-only "$BASE_SHA" "$TASK_HEAD" 2>/dev/null || true)
ADV_FILES=$(git diff --name-only "$BASE_SHA" "$INT_HEAD_BEFORE" 2>/dev/null || true)
OVERLAP="none"
if [ -n "$TASK_FILES" ] && [ -n "$ADV_FILES" ]; then
  OVERLAP=$(comm -12 <(printf '%s\n' $TASK_FILES | sort -u) <(printf '%s\n' $ADV_FILES | sort -u) | tr '\n' ' ' || true)
  OVERLAP=$(printf '%s' "$OVERLAP" | sed -E 's/ +$//')
  [ -z "$OVERLAP" ] && OVERLAP="none"
fi
if [ "$OVERLAP" != "none" ]; then
  echo "WARNING: semantic-overlap — files touched by BOTH this task and the advanced base: $OVERLAP" >&2
  echo "They merged textually; the verification below must prove the combination." >&2
fi

# --- merge -----------------------------------------------------------------------
# POWERFLOW_PRE_MERGE_PAUSE (seconds, default 0) stalls here before the
# lease gate — a TEST seam so lease-loss timing is deterministic (the
# suite silences the heartbeat and steals mid-pause). Never set it in
# real runs; it only widens the steal window.
if [[ "${POWERFLOW_PRE_MERGE_PAUSE:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_PRE_MERGE_PAUSE:-0}" -gt 0 ]; then
  sleep "$POWERFLOW_PRE_MERGE_PAUSE"
fi
# Final ownership check immediately before the shared mutation: even with
# heartbeats, a steal in the preceding gap must stop us HERE, not during.
assert_lease "merging into the integration branch"
MERGED_VIA=""
if git -C "$LOC" merge --ff-only "$TASK_BRANCH" >/dev/null 2>&1; then
  MERGED_VIA="ff-only"
  echo "Merged $TASK_BRANCH into $INTEGRATION_BRANCH (fast-forward)." >&2
else
  if git -C "$LOC" merge -m "Merge $TASK_BRANCH into $INTEGRATION_BRANCH" "$TASK_BRANCH" >&2; then
    MERGED_VIA="merge-commit"
    echo "Merged $TASK_BRANCH into $INTEGRATION_BRANCH (merge commit)." >&2
  else
    git -C "$LOC" merge --abort >/dev/null 2>&1 || true
    echo "Error: merge conflict merging $TASK_BRANCH into $INTEGRATION_BRANCH — merge aborted, all state kept." >&2
    echo "Recovery: task branch $TASK_BRANCH at $TASK_HEAD still intact; resolve in the task worktree and re-run." >&2
    exit 4
  fi
fi
MERGE_SHA=$(git -C "$LOC" rev-parse HEAD)

# --- verify the MERGED result (tiers in order; first red stops) -------------------
LOG_DIR="$TASK_DIR_ABS/executions"
mkdir -p "$LOG_DIR"
MERGE_LOG="$LOG_DIR/merge-verification.log"
{
  printf 'INTEGRATION: %s -> %s (%s)\n' "$TASK_BRANCH" "$INTEGRATION_BRANCH" "$MERGED_VIA"
  printf 'BASE_SHA: %s\nINT_HEAD_BEFORE: %s\nOVERLAP: %s\n' "$BASE_SHA" "$INT_HEAD_BEFORE" "$OVERLAP"
} >> "$MERGE_LOG"
VERIFY_OK=true
for cmd in "${VERIFY_CMDS[@]}"; do
  echo "Verifying merged result in $LOC: $cmd" >&2
  # Run without a pipeline so CMD_CODE is exactly the command's exit
  # (not the tail's); keep only the tail for the log.
  CMD_TMP=$(mktemp)
  set +e
  (cd "$LOC" && bash -c "$cmd" >"$CMD_TMP" 2>&1)
  CMD_CODE=$?
  set -e
  CMD_OUT=$(tail -n 40 "$CMD_TMP")
  rm -f "$CMD_TMP"
  {
    printf 'COMMAND: %s\nSHA: %s\nEXIT: %s\n' "$cmd" "$MERGE_SHA" "$CMD_CODE"
    printf '%s\n' "$CMD_OUT"
  } >> "$MERGE_LOG"
  if [ "$CMD_CODE" -ne 0 ]; then
    VERIFY_OK=false
    echo "Error: post-merge verification FAILED (exit $CMD_CODE): $cmd" >&2
    echo "Merged result kept in place at $MERGE_SHA — branch and worktree NOT deleted." >&2
    echo "Recovery: fix forward in $LOC, or undo ONLY if the integration branch" >&2
    echo "is untouched since this merge (the lock is released now, so others may" >&2
    echo "have committed since — resetting then would delete their commits):" >&2
    echo "  test \"\$(git -C \"$LOC\" rev-parse HEAD)\" = \"$MERGE_SHA\" && \\" >&2
    echo "    git -C \"$LOC\" reset --hard $INT_HEAD_BEFORE ||" >&2
    echo "    echo 'HEAD moved since the merge — do NOT reset; fix forward or revert the task commits individually'" >&2
    echo "Task recovery ref: git branch $TASK_BRANCH $TASK_HEAD" >&2
    if [ "$PORCELAIN_OUT" = true ]; then
      printf 'INTEGRATION_BRANCH=%s\nMERGE_SHA=%s\nVERIFY=failed\nOVERLAP=%s\n' "$INTEGRATION_BRANCH" "$MERGE_SHA" "$OVERLAP"
    fi
    exit 5
  fi
  echo "Verify passed: $cmd" >&2
done

# --- cleanup: worktree first (a held branch cannot be deleted), then branch -----
if [ "$WT_ACTIVE" = true ]; then
  git -C "$MAIN_ROOT" worktree remove "$WT_PATH" >&2 || {
    echo "Error: merge+verify SUCCEEDED ($MERGE_SHA) but worktree removal failed for $WT_PATH." >&2
    echo "Remove it manually (git worktree remove $WT_PATH), then: git branch -d $TASK_BRANCH" >&2
    if [ "$PORCELAIN_OUT" = true ]; then
      printf 'INTEGRATION_BRANCH=%s\nMERGE_SHA=%s\nVERIFY=passed\nOVERLAP=%s\nCLEANUP=worktree-failed\n' "$INTEGRATION_BRANCH" "$MERGE_SHA" "$OVERLAP"
    fi
    exit 1
  }
  git -C "$MAIN_ROOT" worktree prune >&2 || true
  echo "Removed task worktree $WT_PATH." >&2
fi
if git -C "$MAIN_ROOT" branch -d "$TASK_BRANCH" >/dev/null 2>&1; then
  echo "Deleted task branch $TASK_BRANCH." >&2
else
  # Non-ancestor (e.g. squashed history): -D with an explicit note.
  git -C "$MAIN_ROOT" branch -D "$TASK_BRANCH" >/dev/null 2>&1 || {
    echo "Error: merge+verify SUCCEEDED ($MERGE_SHA) but branch deletion failed for $TASK_BRANCH." >&2
    echo "Recovery ref still valid: git branch $TASK_BRANCH $TASK_HEAD" >&2
    if [ "$PORCELAIN_OUT" = true ]; then
      printf 'INTEGRATION_BRANCH=%s\nMERGE_SHA=%s\nVERIFY=passed\nOVERLAP=%s\nCLEANUP=branch-failed\n' "$INTEGRATION_BRANCH" "$MERGE_SHA" "$OVERLAP"
    fi
    exit 1
  }
  echo "Deleted task branch $TASK_BRANCH (-D, was non-ancestor — e.g. squashed)." >&2
fi

if [ "$PORCELAIN_OUT" = true ]; then
  printf 'INTEGRATION_BRANCH=%s\nMERGE_SHA=%s\nVERIFY=passed\nOVERLAP=%s\nCLEANUP=done\n' "$INTEGRATION_BRANCH" "$MERGE_SHA" "$OVERLAP"
fi
echo "Integrated $TASK_BRANCH into $INTEGRATION_BRANCH at $MERGE_SHA (verified)." >&2
# Dependents unblock ONLY on this explicit closeout record (list-tasks.sh
# dep_complete): the orchestrator must append it to summary.md — entering
# Finishing alone never satisfies a dependency.
TODAY=$(date +%F)
{
  echo "--- record in summary.md (required to unblock dependents) ---"
  echo "- Integration: merged — $TODAY"
  echo "- Merge SHA: $MERGE_SHA"
  echo "- Post-merge verification: passed — $TODAY (${#VERIFY_CMDS[@]} command(s) on merged result; see executions/merge-verification.log)"
} >&2
exit 0
