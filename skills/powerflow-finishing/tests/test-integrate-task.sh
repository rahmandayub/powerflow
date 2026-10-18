#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for integrate-task.sh (temp repos, no bats).
# Covers Tahap 3 coordinated integration: serialized verified merge with
# cleanup on success, and state-preserving failures (verify/stale/conflict).
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$SKILLS_ROOT/using-powerflow/tests/helpers.sh"
INT="$SKILLS_ROOT/powerflow-finishing/scripts/integrate-task.sh"
ISOLATE="$SKILLS_ROOT/powerflow-executing/scripts/isolate-branch.sh"
LOCK="$SKILLS_ROOT/powerflow-finishing/scripts/integration-lock.sh"

# Builds a temp repo with one isolated worktree task holding a commit.
# Echoes "<repo> <slug> <worktree>". Caller writes summary, then cleans up.
make_integ_task() {
  local repo slug wt o
  repo=$(make_temp_repo)
  slug="2026-10-17-feat"
  o=$(cd "$repo" && bash "$ISOLATE" --task-slug feat --worktree-path .worktrees/feat --porcelain 2>/dev/null)
  wt=$(printf '%s' "$o" | grep '^WORKTREE_PATH=' | cut -d= -f2)
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "TASK-001: work"
  mkdir -p "$repo/.powerflow/$slug"
  {
    printf '# Powerflow Summary — %s\n\n## Phase: Finishing — 2026-10-17\nDone: ready\nNext: done\n\n## Git State\n' "$slug"
    printf '%s\n' "$o" | grep -E '^(BASE_BRANCH|BASE_REF|BASE_SHA|TASK_BRANCH)=' \
      | sed -E 's/^BASE_BRANCH=/- Base branch: /; s/^BASE_REF=/- Base ref: /; s/^BASE_SHA=/- Base SHA: /; s/^TASK_BRANCH=/- Task branch: /'
    printf -- '- Isolation: created — 2026-10-17\n- Worktree path: %s\n' "$wt"
  } > "$repo/.powerflow/$slug/summary.md"
  # Passing preflight evidence at the task HEAD (Tier 1+2+3 PASS), so the
  # integrate preflight gate is satisfied unless a test removes it.
  write_preflight_log "$repo" "$slug" "$(git -C "$wt" rev-parse HEAD)"
  echo "$repo $slug $wt"
}

# Fabricates a passing pre-integration log for <sha> (all three tiers PASS).
write_preflight_log() { # write_preflight_log <repo> <slug> <sha>
  local log="$1/.powerflow/$2/executions/pre-integration-test-run.log"
  mkdir -p "$(dirname "$log")"
  for tier in smoke affected full; do
    {
      printf 'TIER: %s\nCOMMAND: make %s\nSHA: %s\nEXIT: 0\n' "$tier" "$tier" "$3"
      printf 'ok\n'
    } >> "$log"
  done
}

# 1. Happy path: merge + verify + worktree/branch cleanup, porcelain + log.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
OUT=$(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline --porcelain 2>/dev/null); CODE=$?
assert_exit "integ-ok-exit" 0 "$CODE"
assert_contains "integ-ok-verify" "$OUT" "^VERIFY=passed$"
assert_contains "integ-ok-cleanup" "$OUT" "^CLEANUP=done$"
assert_contains "integ-ok-branch" "$OUT" "^INTEGRATION_BRANCH=main$"
[ -f "$TMP/work.txt" ] && pass "integ-ok-merged" || fail "integ-ok-merged" "task file missing on main"
[ "$(git -C "$TMP" branch --list 'powerflow/*' | wc -l)" -eq 0 ] && pass "integ-ok-branch-gone" || fail "integ-ok-branch-gone" "task branch remains"
[ ! -e "$WT" ] && pass "integ-ok-wt-gone" || fail "integ-ok-wt-gone" "task worktree remains"
[ "$(git -C "$TMP" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && pass "integ-ok-wt-pruned" || fail "integ-ok-wt-pruned" "stale worktree registration"
grep -Eq '^COMMAND: true$' "$TMP/.powerflow/$SLUG/executions/merge-verification.log" && pass "integ-ok-log-cmd" || fail "integ-ok-log-cmd" "no COMMAND block in merge log"
grep -Eq '^EXIT: 0$' "$TMP/.powerflow/$SLUG/executions/merge-verification.log" && pass "integ-ok-log-exit" || fail "integ-ok-log-exit" "no EXIT block in merge log"
OUT=$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null)
assert_contains "integ-ok-lock-free" "$OUT" "^LOCK=free$"
trap - EXIT; rm -rf "$TMP"

# 1b. Relative --task-dir resolves against the MAIN root even when invoked
#     from inside the task worktree itself.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
(cd "$WT" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-wt-cwd-exit" 0 "$CODE"
[ -f "$TMP/work.txt" ] && pass "integ-wt-cwd-merged" || fail "integ-wt-cwd-merged" "merge missing when run from worktree cwd"
trap - EXIT; rm -rf "$TMP"

# 1c. Slow integration outlives --stale-after: heartbeat holds the lock, a
#     rival acquire is refused mid-run, and the merge still completes.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && POWERFLOW_HEARTBEAT_INTERVAL=1 bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command "sleep 5" --offline --stale-after 2 >/dev/null 2>&1) &
INTPID=$!
sleep 3
(cd "$TMP" && bash "$LOCK" acquire --task thief --stale-after 2 >/dev/null 2>&1); CODE=$?
assert_exit "integ-slow-locked" 3 "$CODE"
wait "$INTPID"; CODE=$?
assert_exit "integ-slow-done" 0 "$CODE"
[ "$(git -C "$TMP" branch --list 'powerflow/*' | wc -l)" -eq 0 ] && pass "integ-slow-cleaned" || fail "integ-slow-cleaned" "slow integration did not finish cleanup"
trap - EXIT; rm -rf "$TMP"

# 1d. Lease lost pre-merge aborts with exit 6: heartbeat silenced, lease
#     backdated + stolen during the pre-merge pause — no merge happens, all
#     state is kept, and the thief's lock survives our exit (trap release
#     never deletes another owner's lease).
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
BEFORE=$(git -C "$TMP" rev-parse main)
(cd "$TMP" && POWERFLOW_HEARTBEAT_INTERVAL=3600 POWERFLOW_PRE_MERGE_PAUSE=4 bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline --stale-after 2 >/dev/null 2>&1) &
INTPID=$!
sleep 1
INFO="$TMP/.powerflow/.integration-lock/info"
TOK_OURS=$(grep '^TOKEN=' "$INFO" | cut -d= -f2)
printf 'PID=%s\nTASK=%s\nSINCE=1\nHEARTBEAT=1\nTOKEN=%s\n' "$$" "$SLUG" "$TOK_OURS" > "$INFO"
(cd "$TMP" && bash "$LOCK" acquire --task thief --stale-after 2 >/dev/null 2>&1); CODE=$?
assert_exit "integ-steal-setup" 0 "$CODE"
wait "$INTPID"; CODE=$?
assert_exit "integ-leaselost-exit" 6 "$CODE"
[ "$(git -C "$TMP" rev-parse main)" = "$BEFORE" ] && pass "integ-leaselost-untouched" || fail "integ-leaselost-untouched" "main moved despite lost lease"
git -C "$TMP" show-ref --verify --quiet refs/heads/powerflow/feat && pass "integ-leaselost-branch" || fail "integ-leaselost-branch" "task branch touched after lease loss"
[ -d "$WT" ] && pass "integ-leaselost-wt" || fail "integ-leaselost-wt" "task worktree touched after lease loss"
[ "$(cd "$TMP" && bash "$LOCK" status --porcelain 2>/dev/null | grep '^HOLDER_TASK=' | cut -d= -f2)" = "thief" ] && pass "integ-leaselost-thief-holds" || fail "integ-leaselost-thief-holds" "thief lock disturbed by our exit"
trap - EXIT; rm -rf "$TMP"

# 2. Usage guards: no verify command, missing task dir, missing summary.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$INT" --task-dir .powerflow/nope --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-no-summary" 2 "$CODE"
mkdir -p "$TMP/.powerflow/empty"
(cd "$TMP" && bash "$INT" --task-dir .powerflow/empty --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-empty-dir" 2 "$CODE"
(cd "$TMP" && bash "$INT" --task-dir .powerflow/empty --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-no-verify" 2 "$CODE"
trap - EXIT; rm -rf "$TMP"

# 3. Verify failure (exit 5): merge landed but branch+worktree KEPT.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command false --offline --porcelain >/dev/null 2>&1); CODE=$?
assert_exit "integ-verifyfail-exit" 5 "$CODE"
git -C "$TMP" show-ref --verify --quiet refs/heads/powerflow/feat && pass "integ-verifyfail-branch" || fail "integ-verifyfail-branch" "task branch deleted despite failure"
[ -d "$WT" ] && pass "integ-verifyfail-wt" || fail "integ-verifyfail-wt" "task worktree deleted despite failure"
grep -Eq '^EXIT: 1$' "$TMP/.powerflow/$SLUG/executions/merge-verification.log" && pass "integ-verifyfail-log" || fail "integ-verifyfail-log" "failure not logged"
trap - EXIT; rm -rf "$TMP"

# 4. Stale base refused (exit 4); --allow-stale-base proceeds.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
commit_file "$TMP" advance.txt "2" "advance base"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-stale-refused" 4 "$CODE"
git -C "$TMP" show-ref --verify --quiet refs/heads/powerflow/feat && pass "integ-stale-kept" || fail "integ-stale-kept" "task branch touched on refusal"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline --allow-stale-base >/dev/null 2>&1); CODE=$?
assert_exit "integ-stale-allowed" 0 "$CODE"
[ -f "$TMP/work.txt" ] && pass "integ-stale-merged" || fail "integ-stale-merged" "allowed merge missing file"
trap - EXIT; rm -rf "$TMP"

# 5. Merge conflict (exit 4): aborted, all state kept.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
printf 'base\n' > "$TMP/f.txt"; git -C "$TMP" add f.txt; git -C "$TMP" commit -qm "init file"
O=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat --worktree-path .worktrees/feat --porcelain 2>/dev/null)
WT=$(printf '%s' "$O" | grep '^WORKTREE_PATH=' | cut -d= -f2)
printf 'task\n' > "$WT/f.txt"; git -C "$WT" add f.txt; git -C "$WT" commit -qm "task edit"
printf 'main\n' > "$TMP/f.txt"; git -C "$TMP" add f.txt; git -C "$TMP" commit -qm "main edit"
mkdir -p "$TMP/.powerflow/2026-10-17-feat"
{
  printf '# Powerflow Summary — 2026-10-17-feat\n\n## Phase: Finishing — 2026-10-17\nDone: ready\nNext: done\n\n## Git State\n'
  printf '%s\n' "$O" | grep -E '^(BASE_BRANCH|BASE_REF|BASE_SHA|TASK_BRANCH)=' \
    | sed -E 's/^BASE_BRANCH=/- Base branch: /; s/^BASE_REF=/- Base ref: /; s/^BASE_SHA=/- Base SHA: /; s/^TASK_BRANCH=/- Task branch: /'
  printf -- '- Isolation: created — 2026-10-17\n- Worktree path: %s\n' "$WT"
} > "$TMP/.powerflow/2026-10-17-feat/summary.md"
write_preflight_log "$TMP" "2026-10-17-feat" "$(git -C "$WT" rev-parse HEAD)"
(cd "$TMP" && bash "$INT" --task-dir .powerflow/2026-10-17-feat --verify-command true --offline --allow-stale-base >/dev/null 2>&1); CODE=$?
assert_exit "integ-conflict-exit" 4 "$CODE"
git -C "$TMP" show-ref --verify --quiet refs/heads/powerflow/feat && pass "integ-conflict-branch" || fail "integ-conflict-branch" "task branch lost on conflict"
[ -z "$(git -C "$TMP" status --porcelain | grep -v '^??' | grep -v '^ *$' || true)" ] && pass "integ-conflict-clean" || fail "integ-conflict-clean" "aborted merge left tracked dirt"
trap - EXIT; rm -rf "$TMP"

# 6. Locked queue (exit 3): no merge attempted; works after release.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
BEFORE=$(git -C "$TMP" rev-parse main)
(cd "$TMP" && bash "$LOCK" acquire --task other >/dev/null 2>&1)
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-locked-exit" 3 "$CODE"
[ "$(git -C "$TMP" rev-parse main)" = "$BEFORE" ] && pass "integ-locked-untouched" || fail "integ-locked-untouched" "main moved while locked"
(cd "$TMP" && bash "$LOCK" release --task other >/dev/null 2>&1)
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-after-release" 0 "$CODE"
trap - EXIT; rm -rf "$TMP"

# 7. Overlap advisory: base file touched by both sides is reported, merge still gated by verify.
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
seq 1 10 | sed 's/^/line/' > "$TMP/shared.txt"; git -C "$TMP" add shared.txt; git -C "$TMP" commit -qm "init shared"
O=$(cd "$TMP" && bash "$ISOLATE" --task-slug feat --worktree-path .worktrees/feat --porcelain 2>/dev/null)
WT=$(printf '%s' "$O" | grep '^WORKTREE_PATH=' | cut -d= -f2)
sed -i '1s/.*/task-line/' "$WT/shared.txt"; git -C "$WT" add shared.txt; git -C "$WT" commit -qm "task touches shared (top)"
sed -i '10s/.*/base-line/' "$TMP/shared.txt"; git -C "$TMP" add shared.txt; git -C "$TMP" commit -qm "base touches shared (bottom)"
mkdir -p "$TMP/.powerflow/2026-10-17-feat"
{
  printf '# Powerflow Summary — 2026-10-17-feat\n\n## Phase: Finishing — 2026-10-17\nDone: ready\nNext: done\n\n## Git State\n'
  printf '%s\n' "$O" | grep -E '^(BASE_BRANCH|BASE_REF|BASE_SHA|TASK_BRANCH)=' \
    | sed -E 's/^BASE_BRANCH=/- Base branch: /; s/^BASE_REF=/- Base ref: /; s/^BASE_SHA=/- Base SHA: /; s/^TASK_BRANCH=/- Task branch: /'
  printf -- '- Isolation: created — 2026-10-17\n- Worktree path: %s\n' "$WT"
} > "$TMP/.powerflow/2026-10-17-feat/summary.md"
write_preflight_log "$TMP" "2026-10-17-feat" "$(git -C "$WT" rev-parse HEAD)"
ERR=$(cd "$TMP" && bash "$INT" --task-dir .powerflow/2026-10-17-feat --verify-command true --offline --allow-stale-base 2>&1 >/dev/null); CODE=$?
assert_exit "integ-overlap-exit" 0 "$CODE"
printf '%s' "$ERR" | grep -Eq 'shared\.txt' && pass "integ-overlap-warned" || fail "integ-overlap-warned" "overlap file not reported"
grep -Eq '^OVERLAP: .*shared\.txt' "$TMP/.powerflow/2026-10-17-feat/executions/merge-verification.log" && pass "integ-overlap-logged" || fail "integ-overlap-logged" "overlap not in merge log"
trap - EXIT; rm -rf "$TMP"

# 8. Preflight evidence gate: no log (exit 4), stale log (exit 4),
#    --skip-preflight bypasses explicitly.
read -r TMP SLUG WT < <(make_integ_task); trap 'rm -rf "$TMP"' EXIT
rm "$TMP/.powerflow/$SLUG/executions/pre-integration-test-run.log"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-preflight-missing" 4 "$CODE"
git -C "$TMP" show-ref --verify --quiet refs/heads/powerflow/feat && pass "integ-preflight-kept" || fail "integ-preflight-kept" "branch touched on preflight refusal"
printf 'more\n' >> "$WT/work.txt"; git -C "$WT" add work.txt; git -C "$WT" commit -qm "TASK-002: more"
write_preflight_log "$TMP" "$SLUG" "$(git -C "$TMP" rev-parse main)"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-preflight-stale-sha" 4 "$CODE"
(cd "$TMP" && bash "$INT" --task-dir ".powerflow/$SLUG" --verify-command true --offline --skip-preflight >/dev/null 2>&1); CODE=$?
assert_exit "integ-preflight-skipped" 0 "$CODE"
[ -f "$TMP/work.txt" ] && pass "integ-preflight-skipped-merged" || fail "integ-preflight-skipped-merged" "skip-preflight merge missing"
trap - EXIT; rm -rf "$TMP"

# 9. Legacy branch mode (no worktree): preflight runs in the current checkout
#    only when it holds the task branch; elsewhere it refuses without
#    --skip-preflight (no silent bypass).
TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug 2026-10-17-leg --porcelain >/dev/null 2>&1)
printf 'leg\n' > "$TMP/leg.txt"; git -C "$TMP" add leg.txt; git -C "$TMP" commit -qm "TASK-LEG: work"
LEG_HEAD=$(git -C "$TMP" rev-parse HEAD)
BASE_SHA_LEG=$(git -C "$TMP" merge-base HEAD main)
mkdir -p "$TMP/.powerflow/2026-10-17-leg"
{
  printf '# Powerflow Summary — 2026-10-17-leg\n\n## Phase: Finishing — 2026-10-17\nDone: ready\nNext: done\n\n## Git State\n'
  printf -- '- Base branch: main\n- Base ref: main\n- Base SHA: %s\n- Task branch: powerflow/2026-10-17-leg\n- Isolation: reused — 2026-10-17\n' "$BASE_SHA_LEG"
} > "$TMP/.powerflow/2026-10-17-leg/summary.md"
write_preflight_log "$TMP" "2026-10-17-leg" "$LEG_HEAD"
(cd "$TMP" && bash "$INT" --task-dir .powerflow/2026-10-17-leg --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-branchmode-ok" 0 "$CODE"
[ "$(git -C "$TMP" rev-parse --abbrev-ref HEAD)" = "main" ] && [ -f "$TMP/leg.txt" ] && pass "integ-branchmode-merged" || fail "integ-branchmode-merged" "branch-mode merge missing"
trap - EXIT; rm -rf "$TMP"

TMP=$(make_temp_repo); trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && bash "$ISOLATE" --task-slug 2026-10-17-leg --porcelain >/dev/null 2>&1)
printf 'leg\n' > "$TMP/leg.txt"; git -C "$TMP" add leg.txt; git -C "$TMP" commit -qm "TASK-LEG: work"
LEG_HEAD=$(git -C "$TMP" rev-parse HEAD)
BASE_SHA_LEG=$(git -C "$TMP" merge-base HEAD main)
mkdir -p "$TMP/.powerflow/2026-10-17-leg"
{
  printf '# Powerflow Summary — 2026-10-17-leg\n\n## Phase: Finishing — 2026-10-17\nDone: ready\nNext: done\n\n## Git State\n'
  printf -- '- Base branch: main\n- Base ref: main\n- Base SHA: %s\n- Task branch: powerflow/2026-10-17-leg\n- Isolation: reused — 2026-10-17\n' "$BASE_SHA_LEG"
} > "$TMP/.powerflow/2026-10-17-leg/summary.md"
write_preflight_log "$TMP" "2026-10-17-leg" "$LEG_HEAD"
git -C "$TMP" checkout -q main
(cd "$TMP" && bash "$INT" --task-dir .powerflow/2026-10-17-leg --verify-command true --offline >/dev/null 2>&1); CODE=$?
assert_exit "integ-branchmode-refused" 4 "$CODE"
(cd "$TMP" && bash "$INT" --task-dir .powerflow/2026-10-17-leg --verify-command true --offline --skip-preflight >/dev/null 2>&1); CODE=$?
assert_exit "integ-branchmode-skip" 0 "$CODE"
[ -f "$TMP/leg.txt" ] && pass "integ-branchmode-skip-merged" || fail "integ-branchmode-skip-merged" "skip merge missing"
trap - EXIT; rm -rf "$TMP"

summary_of
