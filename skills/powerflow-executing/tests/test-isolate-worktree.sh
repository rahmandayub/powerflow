#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for isolate-branch.sh --worktree-path mode (temp repos, no bats).
# Covers Tahap 1 worktree-first execution: isolated checkout per task, current
# branch untouched, resume after disconnect, parallel tasks, explicit base SHA.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
ISOLATE="$SKILLS_ROOT/powerflow-executing/scripts/isolate-branch.sh"

# 1. Worktree create: branch made in worktree, main checkout untouched.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
BASE_SHA_BEFORE=$(git -C "$TMP" rev-parse HEAD)
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug wt1 --worktree-path .worktrees/wt1 --porcelain 2>/dev/null); CODE=$?
assert_exit "worktree-create-exit" 0 "$CODE"
assert_contains "worktree-create-main-untouched" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^main$"
assert_contains "worktree-create-task" "$OUT" "^TASK_BRANCH=powerflow/wt1$"
assert_contains "worktree-create-action" "$OUT" "^ACTION=created$"
WT_PATH=$(printf '%s' "$OUT" | grep '^WORKTREE_PATH=' | cut -d= -f2)
[ -n "$WT_PATH" ] && pass "worktree-create-path-emitted" || fail "worktree-create-path-emitted" "no WORKTREE_PATH in porcelain"
assert_contains "worktree-create-wt-branch" "$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD)" "^powerflow/wt1$"
PORC_SHA=$(printf '%s' "$OUT" | grep '^BASE_SHA=' | cut -d= -f2)
[ "$PORC_SHA" = "$BASE_SHA_BEFORE" ] && pass "worktree-create-sha" || fail "worktree-create-sha" "BASE_SHA=$PORC_SHA expected $BASE_SHA_BEFORE"
rm -rf "$TMP"; trap - EXIT

# 2. Parallel: two worktrees from the same base, independent files.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug wta --worktree-path .worktrees/wta --porcelain >/dev/null 2>&1)
(cd "$TMP" && bash "$ISOLATE" --task-slug wtb --worktree-path .worktrees/wtb --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "worktree-parallel-exit" 0 "$CODE"
WTA="$TMP/.worktrees/wta"; WTB="$TMP/.worktrees/wtb"
printf 'a' > "$WTA/a.txt"; printf 'b' > "$WTB/b.txt"
[ -f "$WTA/a.txt" ] && [ ! -f "$WTA/b.txt" ] && pass "worktree-parallel-isolated-a" || fail "worktree-parallel-isolated-a" "wta leaked"
[ -f "$WTB/b.txt" ] && [ ! -f "$WTB/a.txt" ] && pass "worktree-parallel-isolated-b" || fail "worktree-parallel-isolated-b" "wtb leaked"
assert_contains "worktree-parallel-main" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^main$"
[ "$(git -C "$WTA" rev-parse --abbrev-ref HEAD)" = "powerflow/wta" ] && pass "worktree-parallel-branch-a" || fail "worktree-parallel-branch-a" "wrong branch in wta"
[ "$(git -C "$WTB" rev-parse --abbrev-ref HEAD)" = "powerflow/wtb" ] && pass "worktree-parallel-branch-b" || fail "worktree-parallel-branch-b" "wrong branch in wtb"
rm -rf "$TMP"; trap - EXIT

# 3. Resume: same slug+path reuses the worktree (session reconnect).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug wtr --worktree-path .worktrees/wtr --porcelain >/dev/null 2>&1)
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug wtr --worktree-path .worktrees/wtr --porcelain 2>/dev/null); CODE=$?
assert_exit "worktree-resume-exit" 0 "$CODE"
assert_contains "worktree-resume-action" "$OUT" "^ACTION=reused$"
assert_contains "worktree-resume-task" "$OUT" "^TASK_BRANCH=powerflow/wtr$"
rm -rf "$TMP"; trap - EXIT

# 4. Dirty tree in main does NOT block worktree creation (stays behind).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
printf 'dirty' > "$TMP/tracked.txt"
git -C "$TMP" add tracked.txt
(cd "$TMP" && bash "$ISOLATE" --task-slug wtd --worktree-path .worktrees/wtd --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "worktree-dirty-exit" 0 "$CODE"
[ -z "$(git -C "$TMP/.worktrees/wtd" status --porcelain | grep -v '^??' | grep -v '^ *$' || true)" ] && pass "worktree-dirty-clean" || fail "worktree-dirty-clean" "new worktree not clean"
rm -rf "$TMP"; trap - EXIT

# 5. Explicit --base-sha pins the start point (dependent-task foundation).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
PINNED=$(git -C "$TMP" rev-parse HEAD)
commit_file "$TMP" advance.txt "2" "advance main"
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug wtp --worktree-path .worktrees/wtp --base-sha "$PINNED" --porcelain 2>/dev/null); CODE=$?
assert_exit "worktree-pin-exit" 0 "$CODE"
assert_contains "worktree-pin-sha" "$OUT" "^BASE_SHA=$PINNED$"
[ "$(git -C "$TMP/.worktrees/wtp" rev-parse HEAD)" = "$PINNED" ] && pass "worktree-pin-head" || fail "worktree-pin-head" "worktree not at pinned SHA"
(cd "$TMP" && bash "$ISOLATE" --task-slug wtp-bad --worktree-path .worktrees/bad --base-sha deadbeef >/dev/null 2>&1); CODE=$?
assert_exit "worktree-pin-badsha" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 6. Collisions: existing branch with a DIFFERENT path, occupied path, bad slug.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug wtc --worktree-path .worktrees/wtc --porcelain >/dev/null 2>&1)
(cd "$TMP" && bash "$ISOLATE" --task-slug wtc --worktree-path .worktrees/other --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "worktree-collision-branch" 1 "$CODE"
mkdir -p "$TMP/.worktrees/occupied"
(cd "$TMP" && bash "$ISOLATE" --task-slug wtnew --worktree-path .worktrees/occupied --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "worktree-collision-path" 1 "$CODE"
(cd "$TMP" && bash "$ISOLATE" --task-slug '../evil' --worktree-path .worktrees/evil >/dev/null 2>&1); CODE=$?
assert_exit "worktree-bad-slug" 1 "$CODE"
(cd "$TMP" && bash "$ISOLATE" --task-slug wtesc --worktree-path .powerflow/evil >/dev/null 2>&1); CODE=$?
assert_exit "worktree-escape-state" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

summary_of
