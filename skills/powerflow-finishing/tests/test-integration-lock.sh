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
#    release by holder (with its token) frees. Tokenless release is usage.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-acquire-exit" 0 "$CODE"
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
(cd "$TMP" && bash "$LOCK" acquire --task bbb >/dev/null 2>&1); CODE=$?
assert_exit "lock-held-refused" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-status-held" "$OUT" "^LOCK=held$"
assert_contains "lock-status-holder" "$OUT" "^HOLDER_TASK=aaa$"
(cd "$TMP" && bash "$LOCK" release --task bbb --token bogus >/dev/null 2>&1); CODE=$?
assert_exit "lock-release-wrong" 1 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task aaa >/dev/null 2>&1); CODE=$?
assert_exit "lock-release-no-token" 2 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task aaa --token "$TOK_A" >/dev/null 2>&1); CODE=$?
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

# 4b. Heartbeat: owner refresh (task+token) resets staleness; anything else
#     is refused without touching the lease. Legacy info files without
#     HEARTBEAT/TOKEN fall back to SINCE.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
printf 'PID=1\nTASK=aaa\nSINCE=1\nTOKEN=%s\n' "$TOK_A" > "$TMP/.powerflow/.integration-lock/info"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-legacy-stale" "$OUT" "^LOCK=stale$"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa >/dev/null 2>&1); CODE=$?
assert_exit "lock-heartbeat-no-token" 2 "$CODE"
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_A" >/dev/null 2>&1); CODE=$?
assert_exit "lock-heartbeat-wrong" 1 "$CODE"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token bogus >/dev/null 2>&1); CODE=$?
assert_exit "lock-heartbeat-bad-token" 1 "$CODE"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token "$TOK_A" >/dev/null 2>&1); CODE=$?
assert_exit "lock-heartbeat-exit" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" acquire --task ccc --stale-after 100 >/dev/null 2>&1); CODE=$?
assert_exit "lock-heartbeat-protects" 3 "$CODE"
[ -f "$TMP/.powerflow/.integration-lock/heartbeat.$TOK_A" ] && grep -Eq '^[0-9]+$' "$TMP/.powerflow/.integration-lock/heartbeat.$TOK_A" && pass "lock-heartbeat-recorded" || fail "lock-heartbeat-recorded" "no heartbeat file recorded for token"
[ "$(grep '^TOKEN=' "$TMP/.powerflow/.integration-lock/info" | cut -d= -f2)" = "$TOK_A" ] && pass "lock-heartbeat-token-stable" || fail "lock-heartbeat-token-stable" "heartbeat rotated the token"
rm -rf "$TMP"; trap - EXIT

# 4d. SAME-SLUG takeover: old owner (token A, task aaa) stalls, a re-queued
#     run under the SAME slug steals with token B. The old owner's heartbeat
#     and release must both fail; the new lease stays intact.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
printf 'PID=1\nTASK=aaa\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$TOK_A" > "$TMP/.powerflow/.integration-lock/info"
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-sameslug-steal" 0 "$CODE"
TOK_B=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
[ -n "$TOK_B" ] && [ "$TOK_B" != "$TOK_A" ] && pass "lock-sameslug-distinct" || fail "lock-sameslug-distinct" "re-acquire did not mint a new token"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token "$TOK_A" >/dev/null 2>&1); CODE=$?
assert_exit "lock-sameslug-hb-refused" 1 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task aaa --token "$TOK_A" >/dev/null 2>&1); CODE=$?
assert_exit "lock-sameslug-rel-refused" 1 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-sameslug-intact" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-sameslug-hb-ok" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task aaa --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-sameslug-rel-ok" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-sameslug-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 4c. Run mode outlives --stale-after: heartbeat keeps a slow child locked.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && POWERFLOW_HEARTBEAT_INTERVAL=1 bash "$LOCK" run --task slow --stale-after 2 -- sleep 4 >/dev/null 2>&1) &
RUNPID=$!
sleep 3
(cd "$TMP" && bash "$LOCK" acquire --task thief --stale-after 2 >/dev/null 2>&1); CODE=$?
assert_exit "lock-run-slow-held" 3 "$CODE"
wait "$RUNPID"; CODE=$?
assert_exit "lock-run-slow-done" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-run-slow-free" "$OUT" "^LOCK=free$"
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

# 6. Token ownership: acquire mints a token, heartbeat preserves it, and a
#    heartbeat for a task that lost the lease refuses instead of clobbering.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-token-acquire" 0 "$CODE"
TOK1=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
[ -n "$TOK1" ] && pass "lock-token-minted" || fail "lock-token-minted" "no TOKEN in acquire porcelain"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token "$TOK1" >/dev/null 2>&1); CODE=$?
assert_exit "lock-token-hb" 0 "$CODE"
TOK2=$(grep '^TOKEN=' "$TMP/.powerflow/.integration-lock/info" | cut -d= -f2)
[ "$TOK2" = "$TOK1" ] && pass "lock-token-stable" || fail "lock-token-stable" "heartbeat changed token $TOK1 -> $TOK2"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-token-status" "$OUT" "^HOLDER_TOKEN=$TOK1$"
# Simulate a steal without rename (direct rewrite, as a racing writer would):
# the old owner's heartbeat must refuse, and the lease must stay intact.
printf 'PID=9\nTASK=bbb\nSINCE=%s\nHEARTBEAT=%s\nTOKEN=tok-bbb\n' "$(date +%s)" "$(date +%s)" > "$TMP/.powerflow/.integration-lock/info"
(cd "$TMP" && bash "$LOCK" heartbeat --task aaa --token "$TOK1" >/dev/null 2>&1); CODE=$?
assert_exit "lock-token-hb-refused" 1 "$CODE"
[ "$(grep '^TASK=' "$TMP/.powerflow/.integration-lock/info" | cut -d= -f2)" = "bbb" ] && pass "lock-token-no-clobber" || fail "lock-token-no-clobber" "heartbeat overwrote another lease"
rm -rf "$TMP"; trap - EXIT

# 7. Concurrent steal storm: N simultaneous thieves elect EXACTLY one winner.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.powerflow/.integration-lock"
printf 'PID=1\nTASK=old\nSINCE=1\nHEARTBEAT=1\nTOKEN=tok-old\n' > "$TMP/.powerflow/.integration-lock/info"
rm -f "$TMP/race.out"
for i in 1 2 3 4 5 6; do
  (cd "$TMP" && bash "$LOCK" acquire --task "thief$i" --stale-after 100 >/dev/null 2>&1; echo "$? thief$i" >> "$TMP/race.out") &
done
wait
[ "$(grep -c '^0 ' "$TMP/race.out")" -eq 1 ] && pass "lock-storm-single-winner" || fail "lock-storm-single-winner" "$(cat "$TMP/race.out" | tr '\n' ' ')"
[ "$(grep -c '^3 ' "$TMP/race.out")" -eq 5 ] && pass "lock-storm-losers-backoff" || fail "lock-storm-losers-backoff" "losers did not all get exit 3"
ls "$TMP/.powerflow/" | grep -q stale && fail "lock-storm-leftovers" "stale aside dirs remain" || pass "lock-storm-leftovers"
rm -rf "$TMP"; trap - EXIT

# 8. Controlled Heartbeat Race: takeover during heartbeat pause.
#    Old owner aaa (TOK_A) pauses right after token verification.
#    Meanwhile, the lease is stolen by bbb (TOK_B).
#    When the old heartbeat resumes, it MUST detect lease loss (exit 1),
#    and MUST NOT overwrite bbb's info or heartbeat.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
# Backdate to make it stealable once takeover arrives
printf 'PID=1\nTASK=aaa\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$TOK_A" > "$TMP/.powerflow/.integration-lock/info"
# Start heartbeat with 2s pause after token verification
(cd "$TMP" && POWERFLOW_TEST_PAUSE_HEARTBEAT=2 bash "$LOCK" heartbeat --task aaa --token "$TOK_A" >/dev/null 2>&1; echo "$?" > "$TMP/hb.code") &
HBPID=$!
# Wait briefly for heartbeat to enter its pause (after token verification)
sleep 0.4
# Takeover by bbb
OUT_B=$(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 1 --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-hb-race-steal" 0 "$CODE"
TOK_B=$(printf '%s' "$OUT_B" | grep '^TOKEN=' | cut -d= -f2)
[ -n "$TOK_B" ] && [ "$TOK_B" != "$TOK_A" ] && pass "lock-hb-race-tok-diff" || fail "lock-hb-race-tok-diff" "no new token for bbb"
wait "$HBPID"
HB_CODE=$(cat "$TMP/hb.code")
assert_exit "lock-hb-race-fail" 1 "$HB_CODE"
# Verify bbb's lease was NOT corrupted by aaa's heartbeat
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-hb-race-b-task" "$OUT" "^HOLDER_TASK=bbb$"
assert_contains "lock-hb-race-b-token" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
[ "$(grep '^TASK=' "$TMP/.powerflow/.integration-lock/info" | cut -d= -f2)" = "bbb" ] && pass "lock-hb-race-info-intact" || fail "lock-hb-race-info-intact" "aaa heartbeat overwrote bbb info"
[ ! -f "$TMP/.powerflow/.integration-lock/heartbeat.$TOK_A" ] && pass "lock-hb-race-no-stray-hb" || fail "lock-hb-race-no-stray-hb" "stray heartbeat file left behind"
# bbb can still heartbeat and release cleanly
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-hb-race-b-hb" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-hb-race-b-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-hb-race-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 9. Controlled Release Race: takeover during release pause.
#    Old owner aaa (TOK_A) pauses right after token verification.
#    Meanwhile, the lease is stolen by bbb (TOK_B).
#    When the old release resumes, verify-after-move MUST detect the mismatch,
#    restore bbb's lease untouched, and exit with code 1.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
# Backdate to make it stealable
printf 'PID=1\nTASK=aaa\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$TOK_A" > "$TMP/.powerflow/.integration-lock/info"
# Start release with 2s pause after token verification
(cd "$TMP" && POWERFLOW_TEST_PAUSE_RELEASE=2 bash "$LOCK" release --task aaa --token "$TOK_A" >/dev/null 2>&1; echo "$?" > "$TMP/rel.code") &
RELPID=$!
# Wait briefly for release to enter its pause (after token verification)
sleep 0.4
# Takeover by bbb
OUT_B=$(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 1 --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-rel-race-steal" 0 "$CODE"
TOK_B=$(printf '%s' "$OUT_B" | grep '^TOKEN=' | cut -d= -f2)
[ -n "$TOK_B" ] && [ "$TOK_B" != "$TOK_A" ] && pass "lock-rel-race-tok-diff" || fail "lock-rel-race-tok-diff" "no new token for bbb"
wait "$RELPID"
REL_CODE=$(cat "$TMP/rel.code")
assert_exit "lock-rel-race-fail" 1 "$REL_CODE"
# Verify bbb's lease was restored and NOT deleted
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-rel-race-b-task" "$OUT" "^HOLDER_TASK=bbb$"
assert_contains "lock-rel-race-b-token" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
[ "$(grep '^TASK=' "$TMP/.powerflow/.integration-lock/info" | cut -d= -f2)" = "bbb" ] && pass "lock-rel-race-info-intact" || fail "lock-rel-race-info-intact" "bbb info missing or corrupted"
# bbb can still release its own lease
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-rel-race-b-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-rel-race-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

summary_of
