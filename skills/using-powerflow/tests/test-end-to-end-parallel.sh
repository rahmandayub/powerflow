#!/usr/bin/env bash
set -uo pipefail
# End-to-end parallel lifecycle across ALL powerflow scripts (temp repo).
# Reviewer scenario: A+B from the same base in separate worktrees (B created
# FROM INSIDE A's worktree) -> C depends on A -> integrate A -> B keeps its
# original baseline (stale, then integrates) -> combined result correct.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
INIT="$SKILLS_ROOT/powerflow-brainstorming/scripts/init-task-dir.sh"
ISOLATE="$SKILLS_ROOT/powerflow-executing/scripts/isolate-branch.sh"
LIST="$SKILLS_ROOT/using-powerflow/scripts/list-tasks.sh"
INT="$SKILLS_ROOT/powerflow-finishing/scripts/integrate-task.sh"

write_summary() { # write_summary <repo> <slug> <phase> <porcelain> [depends]
  local repo="$1" slug="$2" phase="$3" porc="$4" depends="${5:-}"
  local bb br bs tb wt
  bb=$(printf '%s' "$porc" | grep '^BASE_BRANCH=' | cut -d= -f2)
  br=$(printf '%s' "$porc" | grep '^BASE_REF=' | cut -d= -f2)
  bs=$(printf '%s' "$porc" | grep '^BASE_SHA=' | cut -d= -f2)
  tb=$(printf '%s' "$porc" | grep '^TASK_BRANCH=' | cut -d= -f2)
  wt=$(printf '%s' "$porc" | grep '^WORKTREE_PATH=' | cut -d= -f2)
  {
    printf '# Powerflow Summary — %s\n\n## Phase: %s — 2026-10-20\nDone: fixture\nNext: Finishing\n' "$slug" "$phase"
    [ -n "$depends" ] && printf -- '- Depends on: %s\n' "$depends"
    printf '\n## Git State\n- Base branch: %s\n- Base ref: %s\n- Base SHA: %s\n- Task branch: %s\n- Isolation: created — 2026-10-20\n- Worktree path: %s\n' \
      "$bb" "$br" "$bs" "$tb" "$wt"
  } > "$repo/.powerflow/$slug/summary.md"
}

write_preflight_log() { # write_preflight_log <repo> <slug> <sha>
  local log="$1/.powerflow/$2/executions/pre-integration-test-run.log"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  for tier in smoke affected full; do
    printf 'TIER: %s\nCOMMAND: make %s\nSHA: %s\nEXIT: 0\nok\n' "$tier" "$tier" "$3" >> "$log"
  done
}

TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
printf 'base\n' > "$TMP/base.txt"; git -C "$TMP" add base.txt; git -C "$TMP" commit -qm "base"
BASE_TIP=$(git -C "$TMP" rev-parse main)

# 1. Init A from main; isolate; work in A.
A_DIR=$(cd "$TMP" && bash "$INIT" --task-slug 2026-10-20-aaa 2>/dev/null)
A_SLUG=$(basename "$A_DIR")
[ "$A_SLUG" = "2026-10-20-aaa" ] && pass "e2e-a-slug" || fail "e2e-a-slug" "got $A_SLUG"
OA=$(cd "$TMP" && bash "$ISOLATE" --task-slug "$A_SLUG" --worktree-path ".worktrees/$A_SLUG" --porcelain 2>/dev/null); CODE=$?
assert_exit "e2e-a-isolate" 0 "$CODE"
WA=$(printf '%s' "$OA" | grep '^WORKTREE_PATH=' | cut -d= -f2)
printf 'a-work\n' > "$WA/a.txt"; git -C "$WA" add a.txt; git -C "$WA" commit -qm "TASK-A: work"
write_summary "$TMP" "$A_SLUG" "Executing" "$OA"
A_BASE=$(printf '%s' "$OA" | grep '^BASE_SHA=' | cut -d= -f2)

# 2. Init B FROM INSIDE A's worktree (Fix 2: metadata lands in main root),
#    isolate B from there (Fix 1: starts at base tip, inherits nothing).
B_DIR=$(cd "$WA" && bash "$INIT" --task-slug 2026-10-20-bbb 2>/dev/null); CODE=$?
assert_exit "e2e-b-init" 0 "$CODE"
[ -d "$TMP/$B_DIR" ] && pass "e2e-b-main-root" || fail "e2e-b-main-root" "B metadata not in main root"
[ ! -e "$WA/.powerflow" ] && pass "e2e-b-no-scatter" || fail "e2e-b-no-scatter" "metadata scattered into A worktree"
B_SLUG=$(basename "$B_DIR")
OB=$(cd "$WA" && bash "$ISOLATE" --task-slug "$B_SLUG" --worktree-path ".worktrees/$B_SLUG" --porcelain 2>/dev/null); CODE=$?
assert_exit "e2e-b-isolate" 0 "$CODE"
WB=$(printf '%s' "$OB" | grep '^WORKTREE_PATH=' | cut -d= -f2)
[ "$(git -C "$WB" rev-parse HEAD)" = "$BASE_TIP" ] && pass "e2e-b-base-tip" || fail "e2e-b-base-tip" "B not at base tip"
[ ! -e "$WB/a.txt" ] && pass "e2e-b-no-inherit" || fail "e2e-b-no-inherit" "B inherited A's file"
printf 'b-work\n' > "$WB/b.txt"; git -C "$WB" add b.txt; git -C "$WB" commit -qm "TASK-B: work"
write_summary "$TMP" "$B_SLUG" "Executing" "$OB"
B_BASE=$(printf '%s' "$OB" | grep '^BASE_SHA=' | cut -d= -f2)
[ "$B_BASE" = "$BASE_TIP" ] && pass "e2e-b-baseline" || fail "e2e-b-baseline" "B baseline $B_BASE != $BASE_TIP"

# 3. Registry sees both; C depends on A and is blocked (A not merged yet).
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null)
assert_contains "e2e-reg-total" "$OUT" "^TOTAL_TASKS=2$"
assert_contains "e2e-reg-holding" "$OUT" "^HOLDING_RESOURCES=2$"
C_DIR=$(cd "$TMP" && bash "$INIT" --task-slug 2026-10-20-ccc 2>/dev/null)
C_SLUG=$(basename "$C_DIR")
OC=$(cd "$TMP" && bash "$ISOLATE" --task-slug "$C_SLUG" --worktree-path ".worktrees/$C_SLUG" --porcelain 2>/dev/null)
WC=$(printf '%s' "$OC" | grep '^WORKTREE_PATH=' | cut -d= -f2)
printf 'c-work\n' > "$WC/c.txt"; git -C "$WC" add c.txt; git -C "$WC" commit -qm "TASK-C: work"
write_summary "$TMP" "$C_SLUG" "Executing" "$OC" "$A_SLUG"
(cd "$TMP" && bash "$LIST" --check-ready "$C_SLUG" --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "e2e-c-blocked" 3 "$CODE"

# 4. Integrate A (preflight + verify), record closeout -> C unblocks.
write_summary "$TMP" "$A_SLUG" "Finishing" "$OA"
write_preflight_log "$TMP" "$A_SLUG" "$(git -C "$WA" rev-parse HEAD)"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$A_SLUG" --verify-command true --offline --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "e2e-a-integrate" 0 "$CODE"
MERGE_A=$(git -C "$TMP" rev-parse main)
{
  printf -- '- Integration: merged — 2026-10-20\n- Merge SHA: %s\n- Post-merge verification: passed — 2026-10-20 (see executions/merge-verification.log)\n' "$MERGE_A"
} >> "$TMP/.powerflow/$A_SLUG/summary.md"
[ -f "$TMP/a.txt" ] && pass "e2e-a-on-main" || fail "e2e-a-on-main" "A file missing on main"
(cd "$TMP" && bash "$LIST" --check-ready "$C_SLUG" --max-parallel 9 >/dev/null 2>&1); CODE=$?
assert_exit "e2e-c-unblocked" 0 "$CODE"

# 5. B keeps its ORIGINAL baseline across resume despite the moved base.
OB2=$(cd "$TMP" && bash "$ISOLATE" --task-slug "$B_SLUG" --worktree-path ".worktrees/$B_SLUG" --porcelain 2>/dev/null); CODE=$?
assert_exit "e2e-b-resume" 0 "$CODE"
B_BASE2=$(printf '%s' "$OB2" | grep '^BASE_SHA=' | cut -d= -f2)
[ "$B_BASE2" = "$B_BASE" ] && pass "e2e-b-baseline-stable" || fail "e2e-b-baseline-stable" "B baseline moved $B_BASE -> $B_BASE2"
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null | grep -A9 "^TASK=$B_SLUG$")
assert_contains "e2e-b-stale" "$OUT" "^BASE_STATUS=stale$"

# 6. Integrate B (stale, allowed) then C; combined result correct.
write_summary "$TMP" "$B_SLUG" "Finishing" "$OB"
write_preflight_log "$TMP" "$B_SLUG" "$(git -C "$WB" rev-parse HEAD)"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$B_SLUG" --verify-command true --offline --allow-stale-base >/dev/null 2>&1); CODE=$?
assert_exit "e2e-b-integrate" 0 "$CODE"
write_summary "$TMP" "$C_SLUG" "Finishing" "$OC" "$A_SLUG"
write_preflight_log "$TMP" "$C_SLUG" "$(git -C "$WC" rev-parse HEAD)"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$C_SLUG" --verify-command true --offline --allow-stale-base >/dev/null 2>&1); CODE=$?
assert_exit "e2e-c-integrate" 0 "$CODE"
for f in a.txt b.txt c.txt base.txt; do
  [ -f "$TMP/$f" ] && pass "e2e-combined-$f" || fail "e2e-combined-$f" "$f missing in combined result"
done
[ "$(git -C "$TMP" branch --list 'powerflow/*' | wc -l)" -eq 0 ] && pass "e2e-branches-gone" || fail "e2e-branches-gone" "task branches remain"
[ "$(git -C "$TMP" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && pass "e2e-worktrees-gone" || fail "e2e-worktrees-gone" "task worktrees remain"
OUT=$(cd "$TMP" && bash "$LIST" --porcelain 2>/dev/null)
assert_contains "e2e-final-holding" "$OUT" "^HOLDING_RESOURCES=0$"
trap - EXIT; rm -rf "$TMP"

summary_of
