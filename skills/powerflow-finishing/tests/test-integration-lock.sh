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

# 10. Three-process release race: acquire must not delete the lease a late
#     release parked in its aside.
#     A (aaa, TOK_A) verifies its token, then pauses before moving.
#     While it is paused, B (bbb, TOK_B) steals the backdated lease.
#     A resumes and moves B's ACTIVE lease into .rel.<A> (token mismatch),
#     then pauses again in the recovery gap. C acquires right there: it must
#     wait (exit 3) and MUST NOT delete B's parked lease during cleanup.
#     A then restores B and refuses its own release (exit 1).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
printf 'PID=1\nTASK=aaa\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$TOK_A" > "$TMP/.powerflow/.integration-lock/info"
# A: 2s pause after token check, then 4s pause after moving the dir aside.
(cd "$TMP" && POWERFLOW_TEST_PAUSE_RELEASE=2 POWERFLOW_TEST_PAUSE_RELEASE_AFTER_MOVE=4 \
  bash "$LOCK" release --task aaa --token "$TOK_A" >/dev/null 2>&1; echo "$?" > "$TMP/rel3.code") &
REL3PID=$!
sleep 0.4
# B steals the backdated lease while A is in its pre-move pause.
OUT_B=$(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 1 --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-3proc-steal" 0 "$CODE"
TOK_B=$(printf '%s' "$OUT_B" | grep '^TOKEN=' | cut -d= -f2)
[ -n "$TOK_B" ] && [ "$TOK_B" != "$TOK_A" ] && pass "lock-3proc-distinct" || fail "lock-3proc-distinct" "no new token for bbb"
# Wait until A has moved B's lease aside and is paused in the recovery gap.
MOVED=0
for _ in $(seq 1 40); do
  if grep -Rqs '^TOKEN=' "$TMP"/.powerflow/.integration-lock.rel.*/info 2>/dev/null; then MOVED=1; break; fi
  sleep 0.1
done
[ "$MOVED" -eq 1 ] && pass "lock-3proc-rel-aside" || fail "lock-3proc-rel-aside" "release aside never appeared"
# Status must not claim a plain free lock while the release is in progress.
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-3proc-status-release" "$OUT" "^RELEASE=in-progress$"
# C acquires exactly in the gap; it must wait and never delete B's lease.
(cd "$TMP" && bash "$LOCK" acquire --task ccc --stale-after 1 >/dev/null 2>&1); CODE=$?
assert_exit "lock-3proc-c-held" 3 "$CODE"
if grep -Rqs "^TOKEN=$TOK_B$" "$TMP"/.powerflow/.integration-lock.rel.*/info 2>/dev/null; then
  pass "lock-3proc-b-parked-intact"
else
  fail "lock-3proc-b-parked-intact" "acquire cleanup deleted B's parked lease"
fi
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-3proc-no-c-lease" "$OUT" "^LOCK=free$"
wait "$REL3PID"
REL3_CODE=$(cat "$TMP/rel3.code")
assert_exit "lock-3proc-a-refused" 1 "$REL3_CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-3proc-b-restored-task" "$OUT" "^HOLDER_TASK=bbb$"
assert_contains "lock-3proc-b-restored-token" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-3proc-b-hb" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-3proc-b-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-3proc-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 11. A corrupt or future-dated release intent must not lock acquisition out.
#     Intents are written atomically, so an unparseable SINCE (or a SINCE in
#     the future) means corruption/clock skew — treat it as stale and recover,
#     never as an unbounded "release in progress".
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.powerflow"
: > "$TMP/.powerflow/.integration-lock.rel.9999.intent"
(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 5 >/dev/null 2>&1); CODE=$?
assert_exit "lock-bad-intent-not-blocking" 0 "$CODE"
[ ! -e "$TMP/.powerflow/.integration-lock.rel.9999.intent" ] && pass "lock-bad-intent-cleaned" || fail "lock-bad-intent-cleaned" "malformed intent left behind"
rm -rf "$TMP/.powerflow/.integration-lock"
printf 'PID=1\nSINCE=%s\nWINDOW=999999999\nTOKEN=x\n' "$(( $(date +%s) + 100000 ))" > "$TMP/.powerflow/.integration-lock.rel.8888.intent"
(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 5 >/dev/null 2>&1); CODE=$?
assert_exit "lock-future-intent-not-blocking" 0 "$CODE"
rm -rf "$TMP"; trap - EXIT

# 12. Takeover-restore race: a takeover that moved a replacement lease (token
#     mismatch) must share the single-winner restore election. When another
#     process has just claimed $LOCK_DIR to restore that same parked lease,
#     the takeover must back off WITHOUT nesting its aside inside the new lock
#     dir, and the parked lease must stay heartbeat-able and releasable.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task old --stale-after 100 --porcelain 2>/dev/null)
TOK_OLD=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
printf 'PID=1\nTASK=old\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$TOK_OLD" > "$TMP/.powerflow/.integration-lock/info"
# A: stale takeover, paused before the rename (so B can steal) and again
# after the rename (so C can start restoring B's parked lease).
(cd "$TMP" && POWERFLOW_TEST_PAUSE_TAKEOVER_BEFORE_MOVE=2 POWERFLOW_TEST_PAUSE_TAKEOVER_AFTER_MOVE=2 \
  bash "$LOCK" acquire --task aaa --stale-after 100 >/dev/null 2>&1; echo "$?" > "$TMP/a.code") &
A_PID=$!
sleep 0.4
OUT_B=$(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 1 --porcelain 2>/dev/null); CODE=$?
assert_exit "lock-tk-steal" 0 "$CODE"
TOK_B=$(printf '%s' "$OUT_B" | grep '^TOKEN=' | cut -d= -f2)
MOVED=0
for _ in $(seq 1 40); do
  if grep -Rqs "^TOKEN=$TOK_B$" "$TMP"/.powerflow/.integration-lock.stale.*/info 2>/dev/null; then MOVED=1; break; fi
  sleep 0.1
done
[ "$MOVED" -eq 1 ] && pass "lock-tk-moved-aside" || fail "lock-tk-moved-aside" "takeover aside with B never appeared"
# C restores B from that aside; it wins the mkdir election and briefly holds
# the claim, so A reaches its own restore while $LOCK_DIR already exists.
(cd "$TMP" && POWERFLOW_TEST_PAUSE_RESTORE_AFTER_MKDIR=4 bash "$LOCK" acquire --task ccc --stale-after 100 >/dev/null 2>&1; echo "$?" > "$TMP/c.code") &
C_PID=$!
CLAIMED=0
for _ in $(seq 1 40); do
  if [ -d "$TMP/.powerflow/.integration-lock" ] && [ ! -f "$TMP/.powerflow/.integration-lock/info" ]; then CLAIMED=1; break; fi
  sleep 0.1
done
[ "$CLAIMED" -eq 1 ] && pass "lock-tk-c-claimed" || fail "lock-tk-c-claimed" "C never claimed the lock path"
wait "$A_PID"; A_CODE=$(cat "$TMP/a.code")
assert_exit "lock-tk-a-backoff" 3 "$A_CODE"
# The loser must not consume or move the parked lease it did not win.
if grep -Rqs "^TOKEN=$TOK_B$" "$TMP"/.powerflow/.integration-lock.stale.*/info 2>/dev/null; then
  pass "lock-tk-a-left-aside"
else
  fail "lock-tk-a-left-aside" "A moved a parked lease it did not win the election for"
fi
wait "$C_PID"; C_CODE=$(cat "$TMP/c.code")
assert_exit "lock-tk-c-held" 3 "$C_CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-tk-b-task" "$OUT" "^HOLDER_TASK=bbb$"
assert_contains "lock-tk-b-token" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
if [ -n "$(find "$TMP/.powerflow/.integration-lock" -maxdepth 1 -name '.integration-lock.stale.*' 2>/dev/null)" ]; then
  fail "lock-tk-no-nesting" "takeover aside nested inside the lock dir"
else
  pass "lock-tk-no-nesting"
fi
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-tk-b-hb" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-tk-b-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-tk-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 13. Restorer crash recovery: a restorer killed between winning the mkdir
#     election and moving info must not strand the lock. A fresh acquire must
#     resume the abandoned claim and restore the parked lease, without --force.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task bbb --stale-after 100 --porcelain 2>/dev/null)
TOK_B=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
# Park B's live lease exactly as a racing takeover/release move would.
mv "$TMP/.powerflow/.integration-lock" "$TMP/.powerflow/.integration-lock.stale.9999"
# C restores B, wins the mkdir election, then dies before moving info in.
# Window is 1s so the abandoned claim goes stale quickly.
(cd "$TMP" && POWERFLOW_TEST_DIE_IN_RESTORE_AFTER_MKDIR=1 POWERFLOW_RESTORE_INTENT_WINDOW=1 \
  bash "$LOCK" acquire --task ccc --stale-after 100 >/dev/null 2>&1; echo "$?" > "$TMP/c.code") &
C_PID=$!
wait "$C_PID" 2>/dev/null
CLAIMED=0
for _ in $(seq 1 40); do
  if [ -d "$TMP/.powerflow/.integration-lock" ] && [ ! -f "$TMP/.powerflow/.integration-lock/info" ]; then CLAIMED=1; break; fi
  sleep 0.1
done
[ "$CLAIMED" -eq 1 ] && pass "lock-rc-claimed" || fail "lock-rc-claimed" "restorer never claimed the lock path"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-rc-status-recovering" "$OUT" "^LOCK=recovering$"
[ -n "$(grep -Rls '^ASIDE=.integration-lock.stale.9999$' "$TMP"/.powerflow/.integration-lock.restore.*.intent 2>/dev/null)" ] && pass "lock-rc-intent-recorded" || fail "lock-rc-intent-recorded" "restore intent missing"
# A fresh acquire must resume the abandoned claim automatically.
(cd "$TMP" && bash "$LOCK" acquire --task ddd --stale-after 100 >/dev/null 2>&1); CODE=$?
assert_exit "lock-rc-auto-recovers" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-rc-b-task" "$OUT" "^HOLDER_TASK=bbb$"
assert_contains "lock-rc-b-token" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
[ ! -d "$TMP/.powerflow/.integration-lock.stale.9999" ] && pass "lock-rc-aside-consumed" || fail "lock-rc-aside-consumed" "parked aside not consumed"
if [ -n "$(find "$TMP/.powerflow/.integration-lock" -maxdepth 1 -name '.integration-lock.stale.*' 2>/dev/null)" ]; then
  fail "lock-rc-no-nesting" "aside nested inside the lock dir"
else
  pass "lock-rc-no-nesting"
fi
if ls "$TMP"/.powerflow/.integration-lock.restore.*.intent >/dev/null 2>&1; then
  fail "lock-rc-no-intent-leak" "stale restore intent left behind"
else
  pass "lock-rc-no-intent-leak"
fi
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-rc-b-hb" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-rc-b-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-rc-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

# 14. Multi-aside claim matching: a stale restore intent naming aside B (and
#     only B) must not authorize restoring aside A into the abandoned lock
#     dir. B is resumed; A stays parked until it can be restored on its own.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$LOCK" acquire --task aaa --stale-after 100 --porcelain 2>/dev/null)
TOK_A=$(printf '%s' "$OUT" | grep '^TOKEN=' | cut -d= -f2)
mv "$TMP/.powerflow/.integration-lock" "$TMP/.powerflow/.integration-lock.stale.1111"
# Fabricate a second parked live lease (bbb) directly: a real acquire would
# first restore A, which is the behavior under test.
TOK_B="tok-multi-b"
NOW=$(date +%s)
mkdir "$TMP/.powerflow/.integration-lock.stale.2222"
printf 'PID=2\nTASK=bbb\nSINCE=%s\nHEARTBEAT=%s\nTOKEN=%s\n' "$NOW" "$NOW" "$TOK_B" > "$TMP/.powerflow/.integration-lock.stale.2222/info"
# One abandoned claim naming B, plus the empty dir the dead restorer left.
printf 'PID=999\nSINCE=%s\nWINDOW=1\nTOKEN=%s\nASIDE=.integration-lock.stale.2222\n' \
  "$(( $(date +%s) - 10 ))" "$TOK_B" > "$TMP/.powerflow/.integration-lock.restore.999.intent"
mkdir "$TMP/.powerflow/.integration-lock"
(cd "$TMP" && bash "$LOCK" acquire --task ddd --stale-after 100 >/dev/null 2>&1); CODE=$?
assert_exit "lock-mi-acquire-held" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-mi-b-restored" "$OUT" "^HOLDER_TOKEN=$TOK_B$"
[ -f "$TMP/.powerflow/.integration-lock.stale.1111/info" ] \
  && grep -q "^TOKEN=$TOK_A$" "$TMP/.powerflow/.integration-lock.stale.1111/info" \
  && pass "lock-mi-a-untouched" || fail "lock-mi-a-untouched" "A was restored by a claim naming B"
[ ! -d "$TMP/.powerflow/.integration-lock.stale.2222" ] && pass "lock-mi-b-claim-consumed" || fail "lock-mi-b-claim-consumed" "B's aside was not consumed"
[ ! -f "$TMP/.powerflow/.integration-lock.restore.999.intent" ] && pass "lock-mi-b-intent-cleared" || fail "lock-mi-b-intent-cleared" "resolved claim was not removed"
# B is intact and usable.
(cd "$TMP" && bash "$LOCK" heartbeat --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-mi-b-hb" 0 "$CODE"
(cd "$TMP" && bash "$LOCK" release --task bbb --token "$TOK_B" >/dev/null 2>&1); CODE=$?
assert_exit "lock-mi-b-rel" 0 "$CODE"
# A was never lost: the next acquire restores it on its own.
(cd "$TMP" && bash "$LOCK" acquire --task eee --stale-after 100 >/dev/null 2>&1); CODE=$?
assert_exit "lock-mi-a-later-held" 3 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-mi-a-restored" "$OUT" "^HOLDER_TOKEN=$TOK_A$"
(cd "$TMP" && bash "$LOCK" release --task aaa --token "$TOK_A" >/dev/null 2>&1); CODE=$?
assert_exit "lock-mi-a-rel" 0 "$CODE"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "lock-mi-free" "$OUT" "^LOCK=free$"
rm -rf "$TMP"; trap - EXIT

summary_of
