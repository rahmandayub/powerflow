#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for integration-lock.sh (temp repos, no bats).
# Covers Tahap 3 serialization: acquire/release/status, held refusal,
# age-based stale stealing, and run-mode lifetime + exit passthrough.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
LOCK="$SKILLS_ROOT/powerflow-finishing/scripts/integration-lock.sh"

# 1. Status free on a fresh repo; usage errors.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-status-free-exit" 0 "$CODE"
assert_contains "lock-status-free" "$OUT" "^LOCK=free$"
(cd "$TMP" && bash "$LOCK" bogus >/dev/null 2>&1); CODE=$?
assert_exit "lock-bad-cmd" 2 "$CODE"
(cd "$TMP" && bash "$LOCK" acquire >/dev/null 2>&1); CODE=$?
assert_exit "lock-acquire-no-task" 2 "$CODE"
(cd "$TMP" && bash "$LOCK" run --task aaa >/dev/null 2>&1); CODE=$?
assert_exit "lock-run-no-cmd" 2 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 2. Acquire -> held for others (exit 3) -> release by other refused ->
#    release by holder frees.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$LOCK" acquire --task aaa >/dev/null 2>&1); CODE=$?
assert_exit "lock-acquire-exit" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" acquire --task bbb >/dev/null 2>&1); CODE=$?
assert_exit "lock-held-refused" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-status-held" "$OUT" "^LOCK=held$"
assert_contains "lock-status-holder" "$OUT" "^HOLDER_TASK=aaa$"
(cd "$TMP" && bash "$LOCK" release --task bbb >/dev/null 2>&1); CODE=$?
assert_exit "lock-release-wrong" 1 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task aaa >/dev/null 2>&1); CODE=$?
assert_exit "lock-release-exit" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-status-free-again" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 3. Stale lock (age beyond --stale-after) is stolen with a warning.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$LOCK" acquire --task old >/dev/null 2>&1)
printf 'PID=1\nTASK=old\nSINCE=1\n' > "$TMP/.powerflow/.integration-lock/info"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-stale-status" "$OUT" "^LOCK=stale$"
(cd "$TMP" && bash "$LOCK" acquire --task new >/dev/null 2>&1); CODE=$?
assert_exit "lock-steal-exit" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-steal-holder" "$OUT" "^HOLDER_TASK=new$"
rm -rf "$TMP"; trap - EXIT

# 4. Fresh lock is NOT stolen even with a tiny pid trick; --stale-after honored.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$LOCK" acquire --task aaa >/dev/null 2>&1)
(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 999999 >/dev/null 2>&1); CODE=$?
assert_exit "lock-fresh-kept" 3 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 5. Run mode: holds during child, releases after, passes child exit code.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$LOCK" run --task aaa -- bash -c 'echo child-ok' >/dev/null 2>&1); CODE=$?
assert_exit "lock-run-exit" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-run-released" "$OUT" "^LOCK=free$"
(cd "$TMP" && bash "$LOCK" run --task aaa -- bash -c 'exit 7' >/dev/null 2>&1); CODE=$?
assert_exit "lock-run-passthrough" 7 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-run-released-fail" "$OUT" "^LOCK=free$"
# Run while held -> 3, child never runs.
(cd "$TMP" && bash "$LOCK" acquire --task other >/dev/null 2>&1)
(cd "$TMP" && bash "$LOCK" run --task aaa -- bash -c 'touch SHOULD_NOT_EXIST' >/dev/null 2>&1); CODE=$?
assert_exit "lock-run-held" 3 "$CODE"
[ ! -e "$TMP/SHOULD_NOT_EXIST" ] && pass "lock-run-child-skipped" || fail "lock-run-child-skipped" "child ran while locked"
rm -rf "$TMP"; trap - EXIT

summary_of
