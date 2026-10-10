#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for squash-branch.sh (temp repos, no bats).
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
SQUASH="$SKILLS_ROOT/powerflow-finishing/scripts/squash-branch.sh"

# 1. Happy squash: 3 micro-commits -> 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/x"
commit_file "$TMP" a.txt "1" "TASK-001: one"
commit_file "$TMP" b.txt "2" "TASK-002: two"
commit_file "$TMP" c.txt "3" "TASK-003: three"
OUT=$(cd "$TMP" && bash "$SQUASH" --message "feat(x): done" --base-branch main 2>err.txt); CODE=$?
assert_exit "squash-happy-exit" 0 "$CODE"
COUNT=$(git -C "$TMP" rev-list --count "$(git -C "$TMP" merge-base HEAD main)"..HEAD)
[ "$COUNT" -eq 1 ] && pass "squash-happy-count" || fail "squash-happy-count" "count=$COUNT"
assert_contains "squash-happy-breadcrumb" "$(cat "$TMP/err.txt")" "Pre-squash HEAD:"
rm -rf "$TMP"; trap - EXIT

# 2. --uncommitted leaves staged-but-uncommitted state
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/y"
commit_file "$TMP" a.txt "1" "TASK-001: one"
commit_file "$TMP" b.txt "2" "TASK-002: two"
OUT=$(cd "$TMP" && bash "$SQUASH" --uncommitted --base-branch main 2>/dev/null); CODE=$?
assert_exit "squash-uncommitted-exit" 0 "$CODE"
STAGED=$(git -C "$TMP" diff --cached --name-only | tr '\n' ' ')
assert_contains "squash-uncommitted-staged" "$STAGED" "a.txt"
assert_contains "squash-uncommitted-staged2" "$STAGED" "b.txt"
rm -rf "$TMP"; trap - EXIT

# 3. Zero commits -> exit 0 no-op
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main 2>/dev/null); CODE=$?
assert_exit "squash-zero-exit" 0 "$CODE"
assert_contains "squash-zero-msg" "$OUT" "Nothing to squash"
rm -rf "$TMP"; trap - EXIT

# 4. Missing --message without --uncommitted -> exit 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/z"
commit_file "$TMP" a.txt "1" "TASK-001: one"
(cd "$TMP" && bash "$SQUASH" --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "squash-no-message" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5. Ambiguous base: main + develop both exist, no flag -> exit 1 (no guessing)
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" branch develop
git -C "$TMP" checkout -qb "powerflow/amb"
commit_file "$TMP" a.txt "1" "TASK-001: one"
(cd "$TMP" && bash "$SQUASH" --message "x" >/dev/null 2>&1); CODE=$?
assert_exit "squash-ambiguous-refused" 1 "$CODE"
OUT=$(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch develop 2>/dev/null); CODE=$?
assert_exit "squash-explicit-develop" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 6a. Dirty tree, unstaged variant -> exit 4, HEAD unchanged
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/d1"
commit_file "$TMP" a.txt "1" "TASK-001: one"
BEFORE=$(git -C "$TMP" rev-parse HEAD)
printf 'dirty' > "$TMP/a.txt"
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>err.txt); CODE=$?
assert_exit "squash-dirty-unstaged" 4 "$CODE"
AFTER=$(git -C "$TMP" rev-parse HEAD)
[ "$BEFORE" = "$AFTER" ] && pass "squash-dirty-head-unchanged" || fail "squash-dirty-head-unchanged" "HEAD moved"
rm -rf "$TMP"; trap - EXIT

# 6b. Dirty tree, staged variant -> exit 4 (+ --allow-dirty proceeds with warning)
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/d2"
commit_file "$TMP" a.txt "1" "TASK-001: one"
printf 'staged-extra' > "$TMP/extra.txt"
git -C "$TMP" add extra.txt
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>err.txt); CODE=$?
assert_exit "squash-dirty-staged" 4 "$CODE"
assert_contains "squash-dirty-staged-msg" "$(cat "$TMP/err.txt")" "would join the squash commit"
OUT=$(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main --allow-dirty 2>err2.txt); CODE=$?
assert_exit "squash-allow-dirty" 0 "$CODE"
assert_contains "squash-allow-dirty-warn" "$(cat "$TMP/err2.txt")" "WILL be included"
rm -rf "$TMP"; trap - EXIT

# 6c. Untracked files alone do not block
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/d3"
commit_file "$TMP" a.txt "1" "TASK-001: one"
printf 'untracked' > "$TMP/notes.txt"
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "squash-untracked-ok" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 7. Detached HEAD -> exit 2, no reset
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
commit_file "$TMP" a.txt "1" "TASK-001: one"
SHA=$(git -C "$TMP" rev-parse HEAD)
git -C "$TMP" checkout -q "$SHA"
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "squash-detached" 2 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 8. No merge-base (orphan branch) -> exit 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -q --orphan orphan1
commit_file "$TMP" o.txt "o" "orphan commit"
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "squash-no-merge-base" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 9. --task-dir reads base from summary.md Git State
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/td"
commit_file "$TMP" a.txt "1" "TASK-001: one"
mkdir -p "$TMP/task"
printf '# Powerflow Summary\n\n## Git State\n- Base branch: main\n- Base SHA: x\n- Task branch: powerflow/td\n' > "$TMP/task/summary.md"
(cd "$TMP" && bash "$SQUASH" --message "x" --task-dir task >/dev/null 2>&1); CODE=$?
assert_exit "squash-task-dir" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 10. Remote-tracking-only base: local branch deleted, origin/main used
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/rt"
commit_file "$TMP" a.txt "1" "TASK-001: one"
# Simulate a clone where the base exists only as origin/main:
git -C "$TMP" update-ref refs/remotes/origin/main refs/heads/main
git -C "$TMP" branch -D main
(cd "$TMP" && bash "$SQUASH" --message "x" --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "squash-remote-base" 0 "$CODE"
COUNT=$(git -C "$TMP" rev-list --count "$(git -C "$TMP" merge-base HEAD origin/main)"..HEAD)
[ "$COUNT" -eq 1 ] && pass "squash-remote-count" || fail "squash-remote-count" "count=$COUNT"
rm -rf "$TMP"; trap - EXIT

# 11. --task-dir prefers Base ref over Base branch: summary records
#     Base branch main + Base ref upstream/main where upstream/main is NEWER.
#     Squash must use upstream/main (1 commit), not stale local main (2).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" checkout -qb tmp-up
commit_file "$TMP" u.txt "upstream" "upstream commit"
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" checkout -q main
git -C "$TMP" branch -D tmp-up
git -C "$TMP" checkout -qb "powerflow/td2" refs/remotes/upstream/main
commit_file "$TMP" a.txt "1" "TASK-001: one"
mkdir -p "$TMP/task"
printf '# Powerflow Summary\n\n## Git State\n- Base branch: main\n- Base ref: upstream/main\n- Base SHA: x\n- Task branch: powerflow/td2\n' > "$TMP/task/summary.md"
(cd "$TMP" && bash "$SQUASH" --message "x" --task-dir task >/dev/null 2>&1); CODE=$?
assert_exit "squash-base-ref" 0 "$CODE"
COUNT=$(git -C "$TMP" rev-list --count "$(git -C "$TMP" merge-base HEAD refs/remotes/upstream/main)"..HEAD)
[ "$COUNT" -eq 1 ] && pass "squash-base-ref-count" || fail "squash-base-ref-count" "count=$COUNT (must squash to upstream/main, not stale main)"
rm -rf "$TMP"; trap - EXIT

# 12. --task-dir with unknown Base ref -> exit 1 (never silently fall back).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb "powerflow/td3"
commit_file "$TMP" a.txt "1" "TASK-001: one"
mkdir -p "$TMP/task"
printf '# Powerflow Summary\n\n## Git State\n- Base branch: main\n- Base ref: upstream/main\n- Base SHA: x\n- Task branch: powerflow/td3\n' > "$TMP/task/summary.md"
(cd "$TMP" && bash "$SQUASH" --message "x" --task-dir task >/dev/null 2>&1); CODE=$?
assert_exit "squash-base-ref-unknown" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

summary_of
