#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for isolate-branch.sh (temp repos, no bats).
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
ISOLATE="$SKILLS_ROOT/powerflow-executing/scripts/isolate-branch.sh"

# 1. On main -> creates powerflow/<slug>, --porcelain emits state
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
BASE_SHA_BEFORE=$(git -C "$TMP" rev-parse HEAD)
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat1 --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-create-exit" 0 "$CODE"
assert_contains "isolate-created-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^powerflow/feat1$"
assert_contains "isolate-porcelain-base" "$OUT" "^BASE_BRANCH=main$"
assert_contains "isolate-porcelain-action" "$OUT" "^ACTION=created$"
PORC_SHA=$(printf '%s' "$OUT" | grep '^BASE_SHA=' | cut -d= -f2)
[ "$PORC_SHA" = "$BASE_SHA_BEFORE" ] && pass "isolate-porcelain-sha" || fail "isolate-porcelain-sha" "BASE_SHA=$PORC_SHA expected $BASE_SHA_BEFORE"
rm -rf "$TMP"; trap - EXIT

# 2. On feature branch -> reused; BASE_BRANCH resolves to repo default (main),
#    NOT the feature branch; BASE_SHA is the merge-base (fork point).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb my-feature
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2 --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-reuse-exit" 0 "$CODE"
assert_contains "isolate-reuse-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^my-feature$"
assert_contains "isolate-reuse-action" "$OUT" "^ACTION=reused$"
assert_contains "isolate-reuse-base" "$OUT" "^BASE_BRANCH=main$"
assert_contains "isolate-reuse-task" "$OUT" "^TASK_BRANCH=my-feature$"
rm -rf "$TMP"; trap - EXIT

# 2b. Feature branch with extra commits: BASE_SHA is the fork point, not HEAD.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
FORK_SHA=$(git -C "$TMP" rev-parse HEAD)
git -C "$TMP" checkout -qb feature/customer-search
commit_file "$TMP" c.txt "1" "feat: search wip"
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2b --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-fork-exit" 0 "$CODE"
PORC_SHA=$(printf '%s' "$OUT" | grep '^BASE_SHA=' | cut -d= -f2)
[ "$PORC_SHA" = "$FORK_SHA" ] && pass "isolate-fork-sha" || fail "isolate-fork-sha" "BASE_SHA=$PORC_SHA expected fork $FORK_SHA"
assert_contains "isolate-fork-base" "$OUT" "^BASE_BRANCH=main$"
rm -rf "$TMP"; trap - EXIT

# 2c. Explicit --base-branch differing from current branch is allowed.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb my-feature
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2c --base-branch main --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-explicit-base-exit" 0 "$CODE"
assert_contains "isolate-explicit-base" "$OUT" "^BASE_BRANCH=main$"
assert_contains "isolate-explicit-task" "$OUT" "^TASK_BRANCH=powerflow/feat2c$"
assert_contains "isolate-explicit-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^powerflow/feat2c$"
rm -rf "$TMP"; trap - EXIT

# 2d. Unknown --base-branch -> exit 1.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug feat2d --base-branch nope >/dev/null 2>&1); CODE=$?
assert_exit "isolate-unknown-base" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 2e. Self-upstream (feature tracking origin/itself) is NOT an integration
#     target: falls back to repo default (main), task branch stays the feature.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb feature/example
git -C "$TMP" update-ref refs/remotes/origin/feature/example refs/heads/feature/example
git -C "$TMP" branch --set-upstream-to=refs/remotes/origin/feature/example 2>/dev/null
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2e --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-self-upstream-exit" 0 "$CODE"
assert_contains "isolate-self-upstream-base" "$OUT" "^BASE_BRANCH=main$"
assert_contains "isolate-self-upstream-task" "$OUT" "^TASK_BRANCH=feature/example$"
assert_contains "isolate-self-upstream-action" "$OUT" "^ACTION=reused$"
assert_not_contains "isolate-self-upstream-noconflate" "$OUT" "^BASE_BRANCH=feature/example$"
rm -rf "$TMP"; trap - EXIT

# 2f. Explicit --base-branch equal to current branch ISOLATES (no self-merge:
#     task branch becomes powerflow/<slug>, base stays the named branch).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb my-feature
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2f --base-branch my-feature --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-self-base" 0 "$CODE"
assert_contains "isolate-self-base-task" "$OUT" "^TASK_BRANCH=powerflow/feat2f$"
assert_contains "isolate-self-base-base" "$OUT" "^BASE_BRANCH=my-feature$"
rm -rf "$TMP"; trap - EXIT

# 2g. Reused branch whose resolved base EQUALS itself -> exit 1 (self-merge guard).
#     Simplest deterministic case: branch 'solo' with upstream origin/solo and
#     no main/master/origin/HEAD left.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb solo
git -C "$TMP" update-ref refs/remotes/origin/solo refs/heads/solo
git -C "$TMP" branch --set-upstream-to=refs/remotes/origin/solo 2>/dev/null
git -C "$TMP" branch -D main
(cd "$TMP" && bash "$ISOLATE" --task-slug feat2g >/dev/null 2>&1); CODE=$?
assert_exit "isolate-self-merge-guard" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 2h. Multi-remote: origin/main and upstream/main diverge; branch tracking
#     upstream/main resolves BASE to upstream's main (fork point), not local's.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb work
git -C "$TMP" update-ref refs/remotes/origin/main refs/heads/main
# upstream/main points at a different commit than origin/main:
git -C "$TMP" commit -q --allow-empty -m "upstream-only"
git -C "$TMP" update-ref refs/remotes/upstream/main HEAD
git -C "$TMP" reset -q --hard refs/remotes/origin/main
git -C "$TMP" branch --set-upstream-to=refs/remotes/upstream/main 2>/dev/null
UPSTREAM_MAIN_SHA=$(git -C "$TMP" rev-parse refs/remotes/upstream/main)
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2h --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-multiremote-exit" 0 "$CODE"
assert_contains "isolate-multiremote-base" "$OUT" "^BASE_BRANCH=main$"
PORC_SHA=$(printf '%s' "$OUT" | grep '^BASE_SHA=' | cut -d= -f2)
FORK=$(git -C "$TMP" merge-base HEAD refs/remotes/upstream/main)
[ "$PORC_SHA" = "$FORK" ] && pass "isolate-multiremote-sha" || fail "isolate-multiremote-sha" "BASE_SHA=$PORC_SHA expected fork $FORK with upstream/main"
[ "$PORC_SHA" != "$UPSTREAM_MAIN_SHA" ] && pass "isolate-multiremote-not-upstream-head" || fail "isolate-multiremote-not-upstream-head" "BASE_SHA must be the fork point, not upstream/main HEAD"
rm -rf "$TMP"; trap - EXIT

# 3a. --base-branch match -> ok; 3b. unknown base -> exit 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug f3 --base-branch main >/dev/null 2>&1); CODE=$?
assert_exit "isolate-override-match" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug f3 --base-branch develop >/dev/null 2>&1); CODE=$?
assert_exit "isolate-override-mismatch" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 4. --force on feature branch creates isolation but still respects dirty
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb my-feature
(cd "$TMP" && bash "$ISOLATE" --task-slug f4 --force >/dev/null 2>&1); CODE=$?
assert_exit "isolate-force" 0 "$CODE"
assert_contains "isolate-force-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^powerflow/f4$"
rm -rf "$TMP"; trap - EXIT

# 5. Existing powerflow/<slug> -> exit 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug dup >/dev/null 2>&1)
git -C "$TMP" checkout -q main
(cd "$TMP" && bash "$ISOLATE" --task-slug dup >/dev/null 2>&1); CODE=$?
assert_exit "isolate-existing" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 6. Detached -> exit 2
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
SHA=$(git -C "$TMP" rev-parse HEAD)
git -C "$TMP" checkout -q "$SHA"
(cd "$TMP" && bash "$ISOLATE" --task-slug det >/dev/null 2>&1); CODE=$?
assert_exit "isolate-detached" 2 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 7. Dirty -> exit 4, branch unchanged; --allow-dirty proceeds
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
printf 'dirty' > "$TMP/tracked.txt"
git -C "$TMP" add tracked.txt
(cd "$TMP" && bash "$ISOLATE" --task-slug dirty1 >/dev/null 2>&1); CODE=$?
assert_exit "isolate-dirty" 4 "$CODE"
assert_contains "isolate-dirty-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^main$"
(cd "$TMP" && bash "$ISOLATE" --task-slug dirty1 --allow-dirty >/dev/null 2>&1); CODE=$?
assert_exit "isolate-allow-dirty" 0 "$CODE"
assert_contains "isolate-allow-dirty-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^powerflow/dirty1$"
rm -rf "$TMP"; trap - EXIT

summary_of
