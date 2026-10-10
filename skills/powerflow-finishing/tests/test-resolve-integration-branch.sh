#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for resolve-integration-branch.sh (temp repos, no bats).
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
RESOLVE="$SKILLS_ROOT/powerflow-finishing/scripts/resolve-integration-branch.sh"

# 1. Local Base ref -> itself.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$RESOLVE" --base-ref main --porcelain 2>/dev/null); CODE=$?
assert_exit "resolve-local-exit" 0 "$CODE"
assert_contains "resolve-local-branch" "$OUT" "^INTEGRATION_BRANCH=main$"
rm -rf "$TMP"; trap - EXIT

# 2. Remote-tracking ref WITH a local branch tracking it -> that branch.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" checkout -qb tmp-up
printf 'u' > "$TMP/u.txt"; git -C "$TMP" add u.txt; git -C "$TMP" commit -qm up
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" checkout -q main
git -C "$TMP" branch -D tmp-up
git -C "$TMP" checkout -qb my-main refs/remotes/upstream/main
git -C "$TMP" branch --set-upstream-to=upstream/main 2>/dev/null
git -C "$TMP" checkout -q main
OUT=$(cd "$TMP" && bash "$RESOLVE" --base-ref upstream/main --porcelain 2>/dev/null); CODE=$?
assert_exit "resolve-tracking-exit" 0 "$CODE"
assert_contains "resolve-tracking-branch" "$OUT" "^INTEGRATION_BRANCH=my-main$"
rm -rf "$TMP"; trap - EXIT

# 3. Remote-tracking ref with NO local tracking branch -> exit 3 (never detach).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" update-ref refs/remotes/upstream/main refs/heads/main
OUT=$(cd "$TMP" && bash "$RESOLVE" --base-ref upstream/main --porcelain 2>/dev/null); CODE=$?
assert_exit "resolve-no-local" 3 "$CODE"
assert_not_contains "resolve-no-detach" "$OUT" "INTEGRATION_BRANCH"
rm -rf "$TMP"; trap - EXIT

# 4. Same-named local branch NOT tracking the remote ref -> exit 3 (ambiguous).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add origin /dev/null
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" update-ref refs/remotes/origin/main refs/heads/main
git -C "$TMP" checkout -qb tmp-up
printf 'u' > "$TMP/u.txt"; git -C "$TMP" add u.txt; git -C "$TMP" commit -qm up
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" checkout -q main
git -C "$TMP" branch -D tmp-up
# Local main tracks origin/main, NOT upstream/main:
git -C "$TMP" branch --set-upstream-to=origin/main 2>/dev/null
(cd "$TMP" && bash "$RESOLVE" --base-ref upstream/main --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "resolve-ambiguous" 3 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5. Unknown ref -> exit 1.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$RESOLVE" --base-ref nope/main >/dev/null 2>&1); CODE=$?
assert_exit "resolve-unknown" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5b. Name collision: local branch literally named "upstream/main" PLUS a
#     remote-tracking upstream/main at a DIFFERENT commit. Remote identity
#     wins: with no local branch tracking the remote ref -> exit 3 (never
#     pick the slash-named local branch).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" checkout -qb tmp-up
printf 'u' > "$TMP/u.txt"; git -C "$TMP" add u.txt; git -C "$TMP" commit -qm up
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" checkout -q main
git -C "$TMP" branch -D tmp-up
git -C "$TMP" checkout -qb upstream/main
printf 'local' > "$TMP/local.txt"; git -C "$TMP" add local.txt; git -C "$TMP" commit -qm local-slash
git -C "$TMP" checkout -q main
(cd "$TMP" && bash "$RESOLVE" --base-ref upstream/main --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "resolve-collision-refused" 3 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5c. Same collision, but a local branch tracks the remote ref -> that branch
#     wins over the slash-named local branch.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" remote add upstream /dev/null
git -C "$TMP" checkout -qb tmp-up
printf 'u' > "$TMP/u.txt"; git -C "$TMP" add u.txt; git -C "$TMP" commit -qm up
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" checkout -q main
git -C "$TMP" branch -D tmp-up
git -C "$TMP" checkout -qb upstream/main
printf 'local' > "$TMP/local.txt"; git -C "$TMP" add local.txt; git -C "$TMP" commit -qm local-slash
git -C "$TMP" checkout -qb my-main refs/remotes/upstream/main
git -C "$TMP" branch --set-upstream-to=upstream/main 2>/dev/null
git -C "$TMP" checkout -q main
OUT=$(cd "$TMP" && bash "$RESOLVE" --base-ref upstream/main --porcelain 2>/dev/null); CODE=$?
assert_exit "resolve-collision-tracking" 0 "$CODE"
assert_contains "resolve-collision-branch" "$OUT" "^INTEGRATION_BRANCH=my-main$"
rm -rf "$TMP"; trap - EXIT

# 6. --task-dir reads Base ref from summary.md.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/task"
printf '# S\n\n## Git State\n- Base branch: main\n- Base ref: main\n- Base SHA: x\n- Task branch: powerflow/t\n' > "$TMP/task/summary.md"
OUT=$(cd "$TMP" && bash "$RESOLVE" --task-dir task --porcelain 2>/dev/null); CODE=$?
assert_exit "resolve-taskdir-exit" 0 "$CODE"
assert_contains "resolve-taskdir-branch" "$OUT" "^INTEGRATION_BRANCH=main$"
rm -rf "$TMP"; trap - EXIT

# 7. Missing summary.md -> exit 2.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$RESOLVE" --task-dir nope >/dev/null 2>&1); CODE=$?
assert_exit "resolve-no-summary" 2 "$CODE"
rm -rf "$TMP"; trap - EXIT

summary_of
