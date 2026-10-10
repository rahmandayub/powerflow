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

# 2. On feature branch -> reused, no checkout
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" checkout -qb my-feature
OUT=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat2 --porcelain 2>/dev/null); CODE=$?
assert_exit "isolate-reuse-exit" 0 "$CODE"
assert_contains "isolate-reuse-branch" "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" "^my-feature$"
assert_contains "isolate-reuse-action" "$OUT" "^ACTION=reused$"
rm -rf "$TMP"; trap - EXIT

# 3a. --base-branch match -> ok; 3b. mismatch -> exit 1
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
