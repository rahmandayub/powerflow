#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for list-tasks.sh (temp repos, no bats).
# Covers Tahap 2 multi-task registry: derived scan, worktree/branch
# reconciliation, depends_on block/unblock, concurrency slots.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
LIST="$SKILLS_ROOT/using-powerflow/scripts/list-tasks.sh"
ISOLATE="$SKILLS_ROOT/powerflow-executing/scripts/isolate-branch.sh"

# Writes a minimal summary.md for a task dir. Args:
#   write_summary <repo> <slug> <phase> [<depends>] [<porcelain-out-file>]
# When <porcelain-out-file> (isolate --porcelain stdout) is given, its Git
# State is recorded; otherwise the task has no branch/worktree yet.
write_summary() {
  local repo="$1" slug="$2" phase="$3" depends="${4:-}" porc="${5:-}"
  local dir="$repo/.powerflow/$slug" base_branch="" base_ref="" base_sha=""
  local task_branch="" isolation="" wt_path=""
  mkdir -p "$dir"
  if [ -n "$porc" ]; then
    base_branch=$(printf '%s' "$porc" | grep '^BASE_BRANCH=' | cut -d= -f2)
    base_ref=$(printf '%s' "$porc" | grep '^BASE_REF=' | cut -d= -f2)
    base_sha=$(printf '%s' "$porc" | grep '^BASE_SHA=' | cut -d= -f2)
    task_branch=$(printf '%s' "$porc" | grep '^TASK_BRANCH=' | cut -d= -f2)
    wt_path=$(printf '%s' "$porc" | grep '^WORKTREE_PATH=' | cut -d= -f2)
    isolation="created — 2026-10-17"
  fi
  {
    printf '# Powerflow Summary — %s\n\n' "$slug"
    printf '## Phase: %s — 2026-10-17\nDone: test fixture\nNext: Finishing\n' "$phase"
    [ -n "$depends" ] && printf 'User decisions: none\n- Depends on: %s\n' "$depends"
    printf '\n## Git State\n'
    [ -n "$base_branch" ] && printf -- '- Base branch: %s\n' "$base_branch"
    [ -n "$base_ref" ] && printf -- '- Base ref: %s\n' "$base_ref"
    [ -n "$base_sha" ] && printf -- '- Base SHA: %s\n' "$base_sha"
    [ -n "$task_branch" ] && printf -- '- Task branch: %s\n' "$task_branch"
    [ -n "$isolation" ] && printf -- '- Isolation: %s\n' "$isolation"
    [ -n "$wt_path" ] && printf -- '- Worktree path: %s\n' "$wt_path"
  } > "$dir/summary.md"
}

porc_value() { # porc_value <porcelain> <key>
  printf '%s' "$1" | grep "^$2=" | cut -d= -f2
}

# 1. Empty registry: no .powerflow at all.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null); CODE=$?
assert_exit "list-empty-exit" 0 "$CODE"
assert_contains "list-empty-total" "$OUT" "^TOTAL_TASKS=0$"
assert_contains "list-empty-slot" "$OUT" "^SLOT_AVAILABLE=yes$"
rm -rf "$TMP"; trap - EXIT

# 2. Two independent worktree tasks: active, current, holding 2 slots.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
O2=$(cd "$TMP" && bash "$ISOLATE" --task-slug bbb --worktree-path .worktrees/bbb --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
write_summary "$TMP" "2026-10-17-bbb" "Executing" "" "$O2"
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null); CODE=$?
assert_exit "list-two-exit" 0 "$CODE"
assert_contains "list-two-total" "$OUT" "^TOTAL_TASKS=2$"
assert_contains "list-two-holding" "$OUT" "^HOLDING_RESOURCES=2$"
assert_contains "list-two-slot-full" "$OUT" "^SLOT_AVAILABLE=no$"
assert_contains "list-two-wt-active" "$(printf '%s' "$OUT" | grep -c '^WT_STATUS=active$')" "^2$"
assert_contains "list-two-base-current" "$(printf '%s' "$OUT" | grep -c '^BASE_STATUS=current$')" "^2$"
assert_contains "list-two-deps-ready" "$(printf '%s' "$OUT" | grep -c '^DEPS_READY=yes$')" "^2$"
HUMAN=$(cd "$TMP" && bash "$LIST" 2>/dev/null)
assert_contains "list-two-human" "$HUMAN" "2026-10-17-aaa"
rm -rf "$TMP"; trap - EXIT

# 3. Slots: third task blocked at max 2, ready at max 3 and via env override.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
O2=$(cd "$TMP" && bash "$ISOLATE" --task-slug bbb --worktree-path .worktrees/bbb --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
write_summary "$TMP" "2026-10-17-bbb" "Executing" "" "$O2"
write_summary "$TMP" "2026-10-17-ccc" "Planning"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc >/dev/null 2>&1); CODE=$?
assert_exit "list-slots-blocked" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --porcelain 2>/dev/null || true)
assert_contains "list-slots-reason" "$OUT" "^BLOCK_REASON=slots:full"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 3 >/dev/null 2>&1); CODE=$?
assert_exit "list-slots-flag" 0 "$CODE"
(cd "$TMP" && POWERFLOW_MAX_PARALLEL=3 bash "$LIST" --check-ready 2026-10-17-ccc >/dev/null 2>&1); CODE=$?
assert_exit "list-slots-env" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 4. Self check is fair: a task holding a worktree is not blocked by its own slot.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
O2=$(cd "$TMP" && bash "$ISOLATE" --task-slug bbb --worktree-path .worktrees/bbb --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
write_summary "$TMP" "2026-10-17-bbb" "Executing" "" "$O2"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-aaa >/dev/null 2>&1); CODE=$?
assert_exit "list-slots-self-resume" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5. Dependency block/unblock: ccc waits for aaa until Finishing.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
write_summary "$TMP" "2026-10-17-ccc" "Planning" "2026-10-17-aaa"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-deps-blocked" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --porcelain --max-parallel 9 2>/dev/null || true)
assert_contains "list-deps-blocked-by" "$OUT" "^BLOCKED_BY=2026-10-17-aaa$"
assert_contains "list-deps-overall" "$OUT" "^OVERALL=blocked$"
write_summary "$TMP" "2026-10-17-aaa" "Finishing" "" "$O1"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-deps-unblocked" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 6. Unknown dep, self dep, and None value.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
write_summary "$TMP" "2026-10-17-ccc" "Planning" "2026-10-17-ghost"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-deps-unknown" 3 "$CODE"
write_summary "$TMP" "2026-10-17-ccc" "Planning" "2026-10-17-ccc"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-deps-self" 3 "$CODE"
write_summary "$TMP" "2026-10-17-ccc" "Planning" "None"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-ccc --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-deps-none-value" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 7. Missing summary, unknown slug, bad max-parallel.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.powerflow/2026-10-17-orphan"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-orphan --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "list-missing-summary" 3 "$CODE"
(cd "$TMP" && bash "$LIST" --check-ready 2026-10-17-nope >/dev/null 2>&1); CODE=$?
assert_exit "list-unknown-slug" 2 "$CODE"
(cd "$TMP" && bash "$LIST" --max-parallel 0 >/dev/null 2>&1); CODE=$?
assert_exit "list-bad-max" 2 "$CODE"
(cd "$TMP" && bash "$LIST" --bogus-flag >/dev/null 2>&1); CODE=$?
assert_exit "list-bad-flag" 2 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 8. Missing worktree reconciled (removed out-of-band): branch still held.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
WT=$(porc_value "$O1" "WORKTREE_PATH")
git -C "$TMP" worktree remove --force "$WT"
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null)
assert_contains "list-wt-missing" "$OUT" "^WT_STATUS=missing$"
assert_contains "list-branch-still-held" "$OUT" "^BRANCH_STATUS=exists$"
assert_contains "list-still-holding" "$OUT" "^HOLDING_RESOURCES=1$"
rm -rf "$TMP"; trap - EXIT

# 9. Stale base: main advances after isolation.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
commit_file "$TMP" advance.txt "2" "advance base"
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null)
assert_contains "list-base-stale" "$OUT" "^BASE_STATUS=stale$"
rm -rf "$TMP"; trap - EXIT

# 10. Runs from inside a task worktree: still scans the main .powerflow/.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
O1=$(cd "$TMP" && bash "$ISOLATE" --task-slug aaa --worktree-path .worktrees/aaa --porcelain 2>/dev/null)
write_summary "$TMP" "2026-10-17-aaa" "Executing" "" "$O1"
WT=$(porc_value "$O1" "WORKTREE_PATH")
OUT=$(cd "$WT" && bash "$LIST" --porcelain 2>/dev/null); CODE=$?
assert_exit "list-from-worktree-exit" 0 "$CODE"
assert_contains "list-from-worktree-total" "$OUT" "^TOTAL_TASKS=1$"
assert_contains "list-from-worktree-task" "$OUT" "^TASK=2026-10-17-aaa$"
trap - EXIT; git -C "$TMP" worktree remove --force "$WT" 2>/dev/null; rm -rf "$TMP"

summary_of
