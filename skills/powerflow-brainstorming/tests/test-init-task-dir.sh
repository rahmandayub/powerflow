#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for init-task-dir.sh (temp repos, no bats).
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
INIT="$SKILLS_ROOT/powerflow-brainstorming/scripts/init-task-dir.sh"

# 1. Bare slug gets date prefix; dated slug preserved; subdirs exist
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$INIT" --task-slug myslug 2>/dev/null); CODE=$?
assert_exit "init-create-exit" 0 "$CODE"
DIRNAME=$(basename "$OUT")
printf '%s' "$DIRNAME" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-myslug$' && pass "init-date-prefix" || fail "init-date-prefix" "got $DIRNAME"
for d in context plans reviews executions/diagnostics reports; do
  [ -d "$TMP/$OUT/$d" ] && pass "init-subdir-$d" || fail "init-subdir-$d" "missing $OUT/$d"
done
OUT2=$(cd "$TMP" && bash "$INIT" --task-slug 2026-01-02-fixed 2>/dev/null); CODE=$?
assert_exit "init-dated-exit" 0 "$CODE"
[ "$OUT2" = ".powerflow/2026-01-02-fixed" ] && pass "init-dated-preserved" || fail "init-dated-preserved" "got $OUT2"
rm -rf "$TMP"; trap - EXIT

# 2. Collision with content -> exit 2; empty orphan -> exit 3
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$INIT" --task-slug 2026-01-03-dup >/dev/null 2>&1)
printf 'x' > "$TMP/.powerflow/2026-01-03-dup/file.txt"
(cd "$TMP" && bash "$INIT" --task-slug 2026-01-03-dup >/dev/null 2>&1); CODE=$?
assert_exit "init-collision" 2 "$CODE"
mkdir -p "$TMP/.powerflow/2026-01-04-empty"
(cd "$TMP" && bash "$INIT" --task-slug 2026-01-04-empty >/dev/null 2>&1); CODE=$?
assert_exit "init-orphan" 3 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 3. Default .gitignore create + append announces
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
ERR=$(cd "$TMP" && bash "$INIT" --task-slug 2026-01-05-g1 2>&1 >/dev/null)
assert_contains "init-gitignore-created" "$ERR" "Created"
grep -Eq '^\.powerflow/$' "$TMP/.gitignore" && pass "init-gitignore-content" || fail "init-gitignore-content" "missing .powerflow/ line"
printf '# existing\nnode_modules/\n' > "$TMP/.gitignore"
ERR=$(cd "$TMP" && bash "$INIT" --task-slug 2026-01-06-g2 2>&1 >/dev/null)
assert_contains "init-gitignore-appended" "$ERR" "Added .powerflow/"
grep -Eq '^node_modules/$' "$TMP/.gitignore" && pass "init-gitignore-kept" || fail "init-gitignore-kept" "existing lines lost"
rm -rf "$TMP"; trap - EXIT

# 4. --no-gitignore leaves .gitignore byte-identical
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
printf '# existing\nnode_modules/\n' > "$TMP/.gitignore"
BEFORE=$(md5sum "$TMP/.gitignore" | cut -d' ' -f1)
(cd "$TMP" && bash "$INIT" --task-slug 2026-01-07-nog --no-gitignore >/dev/null 2>&1); CODE=$?
assert_exit "init-nogitignore-exit" 0 "$CODE"
AFTER=$(md5sum "$TMP/.gitignore" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && pass "init-nogitignore-identical" || fail "init-nogitignore-identical" ".gitignore mutated"
rm -rf "$TMP"; trap - EXIT

# 5. Missing --task-slug -> exit 1
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$INIT" >/dev/null 2>&1); CODE=$?
assert_exit "init-missing-slug" 1 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 6. Path traversal / separator / hostile slugs rejected (exit 1), nothing created
for BAD in "../evil" "a/b" ".." "a b" "a;b" "a|b" "a&b" 'a$b' 'a`b`' "-lead" ".lead"; do
  TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
  (cd "$TMP" && bash "$INIT" --task-slug "$BAD" >/dev/null 2>&1); CODE=$?
  assert_exit "init-reject-$BAD" 1 "$CODE"
  [ -d "$TMP/.powerflow" ] && fail "init-reject-$BAD-nodir" ".powerflow/ was created for bad slug" || pass "init-reject-$BAD-nodir"
  rm -rf "$TMP"; trap - EXIT
done

summary_of
