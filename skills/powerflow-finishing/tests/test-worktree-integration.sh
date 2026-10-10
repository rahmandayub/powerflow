#!/usr/bin/env bash
set -uo pipefail
# Integration fixtures for the Finishing worktree procedure (real git
# worktrees, no bats). These test the documented SKILL flow, not just the
# resolver: merge lands on the named local branch, discard saves recovery
# first and never deletes a branch out from under its worktree.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
RESOLVE="$SKILLS_ROOT/powerflow-finishing/scripts/resolve-integration-branch.sh"

# Builds a main repo with a task worktree holding powerflow/<slug>.
# Echoes "<main> <worktree>". Caller cleans up.
make_worktree_task() {
  local main wt
  main=$(make_temp_repo)
  git -C "$main" commit -q --allow-empty -m "base"
  wt="$main/.worktrees/powerflow-feature"
  git -C "$main" worktree add -q --detach "$wt" 2>/dev/null || git -C "$main" worktree add -q "$wt" -b "powerflow/feature"
  git -C "$wt" checkout -qb "powerflow/feature"
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "TASK-001: work"
  echo "$main $wt"
}

# 1. Merge from the task worktree: integration branch (main) is checked out
#    in the MAIN repo, so the merge runs THERE (git -C), landing on main —
#    never a detached checkout in the task worktree.
TMP_MAIN=""; TMP_WT=""
read -r TMP_MAIN TMP_WT < <(make_worktree_task); trap 'git -C "$TMP_MAIN" worktree remove --force "$TMP_WT" 2>/dev/null; rm -rf "$TMP_MAIN"' EXIT
OUT=$(cd "$TMP_WT" && bash "$RESOLVE" --base-ref main --porcelain 2>/dev/null); CODE=$?
assert_exit "worktree-resolve-exit" 0 "$CODE"
assert_contains "worktree-resolve-branch" "$OUT" "^INTEGRATION_BRANCH=main$"
# The task worktree CANNOT checkout main (main is checked out in $TMP_MAIN):
(cd "$TMP_WT" && git checkout -q main >/dev/null 2>&1); CODE=$?
assert_exit "worktree-checkout-refused" 128 "$CODE"
# ...so merge in the owning location instead (the documented procedure):
MAIN_ROOT=$(git -C "$TMP_WT" rev-parse --git-common-dir)/..
MAIN_ROOT=$(cd "$MAIN_ROOT" && pwd -P)
(cd "$MAIN_ROOT" && git merge -q --ff-only "powerflow/feature" >/dev/null 2>&1); CODE=$?
assert_exit "worktree-merge-exit" 0 "$CODE"
[ "$(git -C "$MAIN_ROOT" rev-parse --abbrev-ref HEAD)" = "main" ] && pass "worktree-merge-on-branch" || fail "worktree-merge-on-branch" "merge landed detached"
git -C "$MAIN_ROOT" rev-parse --verify --quiet main >/dev/null && pass "worktree-merge-target-updated" || fail "worktree-merge-target-updated" "main not updated"
git -C "$MAIN_ROOT" merge-base --is-ancestor "powerflow/feature" main && pass "worktree-merge-contains-task" || fail "worktree-merge-contains-task" "main lacks task commits"
git -C "$TMP_MAIN" worktree remove --force "$TMP_WT"
(cd "$MAIN_ROOT" && git branch -d "powerflow/feature" >/dev/null 2>&1); CODE=$?
assert_exit "worktree-branch-deleted-after-verify" 0 "$CODE"
git -C "$TMP_MAIN" worktree prune
trap - EXIT; rm -rf "$TMP_MAIN"

# 2. Discard: recovery SHA saved BEFORE anything is removed; worktree removed
#    BEFORE the branch (deleting a checked-out branch fails).
read -r TMP_MAIN TMP_WT < <(make_worktree_task); trap 'git -C "$TMP_MAIN" worktree remove --force "$TMP_WT" 2>/dev/null; rm -rf "$TMP_MAIN"' EXIT
RECOVERY_SHA=$(git -C "$TMP_WT" rev-parse HEAD)
RECOVERY_BRANCH=$(git -C "$TMP_WT" rev-parse --abbrev-ref HEAD)
[ -n "$RECOVERY_SHA" ] && [ -n "$RECOVERY_BRANCH" ] && pass "worktree-recovery-saved" || fail "worktree-recovery-saved" "no recovery state"
# Direct branch delete from the main repo while the worktree holds it: refused.
(cd "$TMP_MAIN" && git branch -D "powerflow/feature" >/dev/null 2>&1); CODE=$?
assert_exit "worktree-delete-refused" 1 "$CODE"
# Documented order: remove worktree first, then the branch.
git -C "$TMP_MAIN" worktree remove --force "$TMP_WT"
(cd "$TMP_MAIN" && git branch -D "powerflow/feature" >/dev/null 2>&1); CODE=$?
assert_exit "worktree-discard-after-remove" 0 "$CODE"
# Recovery still possible from the saved SHA.
git -C "$TMP_MAIN" branch "powerflow/feature" "$RECOVERY_SHA" >/dev/null 2>&1 && pass "worktree-recovery-works" || fail "worktree-recovery-works" "cannot recover $RECOVERY_SHA"
git -C "$TMP_MAIN" branch -D "powerflow/feature" >/dev/null 2>&1
trap - EXIT; rm -rf "$TMP_MAIN"

# 3. Resolver from INSIDE the task worktree still resolves main (shared refs).
read -r TMP_MAIN TMP_WT < <(make_worktree_task); trap 'git -C "$TMP_MAIN" worktree remove --force "$TMP_WT" 2>/dev/null; rm -rf "$TMP_MAIN"' EXIT
OUT=$(cd "$TMP_WT" && bash "$RESOLVE" --base-ref main --porcelain 2>/dev/null); CODE=$?
assert_exit "worktree-resolve-inside" 0 "$CODE"
assert_contains "worktree-resolve-inside-branch" "$OUT" "^INTEGRATION_BRANCH=main$"
trap - EXIT; git -C "$TMP_MAIN" worktree remove --force "$TMP_WT" 2>/dev/null; rm -rf "$TMP_MAIN"

summary_of
