#!/usr/bin/env bash
set -uo pipefail
# Fixture tests for validate-transition.sh (temp repos + fixture task dirs, no bats).
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=helpers.sh
source "$HERE/helpers.sh"
VALIDATE="$HERE/../scripts/validate-transition.sh"

# Builds a temp repo + task dir that PASSES both gates (Big task).
# Echoes "<repo> <taskdir>". Caller must be on the task branch with clean tree.
make_passing_task() {
  local repo task kind
  repo=$(make_temp_repo)
  task="$repo/.powerflow/2026-01-01-demo"
  mkdir -p "$task"/{context,plans,reviews,executions,reports}
  git -C "$repo" checkout -qb "powerflow/demo"
  printf 'print("hi")\n' > "$repo/src_app.py"
  git -C "$repo" add src_app.py
  git -C "$repo" commit -q -m "TASK-001: add app"
  local base_sha head_sha
  base_sha=$(git -C "$repo" merge-base HEAD main)
  head_sha=$(git -C "$repo" rev-parse HEAD)
  kind="${1:-Big}"
  if [ "$kind" = "Small" ]; then
    printf '# Brief\n\nComplexity: Low\n\nRisk: Low\n\nClassification: Small\n' > "$task/context/brief.md"
  else
    printf '# Brief\n\nComplexity: High\n\nRisk: High\n\nClassification: Big\n' > "$task/context/brief.md"
    printf '# Plan review\n\n## Verdict: APPROVED\n' > "$task/reviews/plan-review.md"
  fi
  cat > "$task/plans/plan-final.md" <<EOF
# Plan

## Scope
- src_app.py

## Must Not Change
- README.md

## Acceptance Criteria
- AC-001: app prints hi
- AC-002: exit code is zero

## Out of Scope
- docs/
EOF
  if [ "$kind" != "Small" ]; then
    printf '# Impl review\n\n## Verdict: ACCEPTED\n' > "$task/reviews/implementation-review.md"
    cat > "$task/executions/verification-ledger.md" <<EOF
# Ledger
Files: src_app.py
AC-001 PASS src_app.py:1
AC-002 PASS log:2026-01-01T00:00:01Z exit 0
Tested SHA: $head_sha
Verdict: ACCEPTED
EOF
  else
    printf 'AC-001 PASS src_app.py:1\nAC-002 PASS log:2026-01-01T00:00:01Z\n' > "$task/scope-check.txt"
  fi
  cat > "$task/executions/pre-integration-test-run.log" <<EOF
TIER: smoke
COMMAND: python3 -c "import ast; ast.parse(open('src_app.py').read())"
SHA: $head_sha
EXIT: 0
ok
TIER: affected
COMMAND: python3 -m pytest tests/ -q
SHA: $head_sha
EXIT: 0
ok
TIER: full
COMMAND: python3 -m pytest -q
SHA: $head_sha
EXIT: 0
ok
EOF
  cat > "$task/summary.md" <<EOF
# Powerflow Summary — demo

## Phase: Executing — 2026-01-01
Done: implemented
Output: $task/plans/plan-final.md
User decisions: 2026-01-01: chose approach A (reason: simplest)
Next: Finishing

## Git State
- Base branch: main
- Base ref: main
- Base SHA: $base_sha
- Task branch: powerflow/demo
- Isolation: created — 2026-01-01
EOF
  echo "$repo $task"
}

run_gate() { # run_gate <repo> <task> <from> <to> -> prints output, echoes exit via $?
  (cd "$1" && bash "$VALIDATE" --task-dir "$2" --from "$3" --to "$4" 2>stderr.txt); CODE=$?
  cat stderr.txt >> /dev/null 2>&1 || true
  return "$CODE"
}

# 1. P->E positive (Big) -> exit 0
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing >/dev/null 2>&1); CODE=$?
assert_exit "validator-pe-positive" 0 "$CODE"
# 2. E->F positive (Big) -> exit 0
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-ef-positive" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 3. Lowercase 'approved' -> FAIL review-verdict
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf '# Plan review\n\n## Verdict: approved\n' > "$TASK/reviews/plan-review.md"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing 2>/dev/null); CODE=$?
assert_exit "validator-lowercase-verdict" 1 "$CODE"
assert_contains "validator-lowercase-check" "$OUT" "CHECK review-verdict: FAIL"
rm -rf "$REPO"; trap - EXIT

# 4. Missing review for Big -> FAIL
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
rm "$TASK/reviews/plan-review.md"
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing >/dev/null 2>&1); CODE=$?
assert_exit "validator-missing-review-big" 1 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 4b. Planning gate: latest request approved but NOT amended/reviewed -> FAIL
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra.py
Requested change:
+ extra.py
AC impact: none
User decision: approved 2026-01-01 go ahead
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing 2>/dev/null); CODE=$?
assert_exit "validator-planning-incomplete" 1 "$CODE"
assert_contains "validator-planning-incomplete-check" "$OUT" "CHECK scope-change-pending: FAIL"
rm -rf "$REPO"; trap - EXIT

# 4c. Planning gate: latest request with unparseable decision -> FAIL
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: vague idea
Evidence: src_app.py:1
Requested change:
+ extra.py
AC impact: none
User decision: maybe later
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing 2>/dev/null); CODE=$?
assert_exit "validator-planning-unparseable" 1 "$CODE"
assert_contains "validator-planning-unparseable-check" "$OUT" "CHECK scope-change-pending: FAIL"
rm -rf "$REPO"; trap - EXIT

# 4d. Git State with Base ref pointing at a missing ref -> FAIL diff-scope.
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
sed -i 's/^- Base ref: .*$/\- Base ref: upstream\/main/' "$TASK/summary.md"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-base-ref-missing" 1 "$CODE"
assert_contains "validator-base-ref-missing-check" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 5. Small task: no review files, scope-check.txt evidence -> both gates pass
read -r REPO TASK < <(make_passing_task Small); trap 'rm -rf "$REPO"' EXIT
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing >/dev/null 2>&1); CODE=$?
assert_exit "validator-small-pe" 0 "$CODE"
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-small-ef" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 6. One AC missing from ledger -> FAIL ac-evidence
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'AC-001 PASS src_app.py:1\n' > "$TASK/executions/verification-ledger.md"
printf 'Tested SHA: %s\n' "$(git -C "$REPO" rev-parse HEAD)" >> "$TASK/executions/verification-ledger.md"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-missing-ac" 1 "$CODE"
assert_contains "validator-missing-ac-check" "$OUT" "CHECK ac-evidence: FAIL"
rm -rf "$REPO"; trap - EXIT

# 7a. Out-of-scope diff without approval -> FAIL diff-scope
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-leak" 1 "$CODE"
assert_contains "validator-scope-leak-check" "$OUT" "CHECK diff-scope: FAIL"
# 7b. Same leak WITH complete approved scope-change (Request ID + amendment + re-review) -> PASS
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Added extra_leak.py (reason: needed helper, scope-change SC-001).
EOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-scope-change-approved" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 8. Stale SHA (new commit after tests) -> gate passes, PREFLIGHT fails tiers
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf '# touch\n' >> "$REPO/src_app.py"
git -C "$REPO" commit -qam "TASK-004: touch"
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-stale-sha-gate" 0 "$CODE"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-stale-sha" 1 "$CODE"
assert_contains "validator-stale-sha-check" "$OUT" "CHECK preflight-tier1: FAIL"
rm -rf "$REPO"; trap - EXIT

# 9. Tier 3 EXIT != 0 -> gate passes, PREFLIGHT fails tier3 even when SHA matches
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
sed -i '0,/^EXIT: 0$/s//EXIT: 1/' "$TASK/executions/pre-integration-test-run.log"
# ensure the failing EXIT is in the full block:
python3 - "$TASK/executions/pre-integration-test-run.log" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out, cur = [], None
for ln in lines:
    if ln.startswith('TIER:'):
        cur = ln.split(':')[1].strip()
    if ln.startswith('EXIT:') and cur == 'full':
        ln = 'EXIT: 1\n'
    out.append(ln)
open(p, 'w').writelines(out)
PYEOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-tier3-fail-gate" 0 "$CODE"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-tier3-fail" 1 "$CODE"
assert_contains "validator-tier3-fail-check" "$OUT" "CHECK preflight-tier3: FAIL"
rm -rf "$REPO"; trap - EXIT

# 10. Missing Git State -> FAIL (both gates)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
python3 - "$TASK/summary.md" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out = [ln for ln in lines if not ln.startswith('## Git State') and not ln.startswith('- Base') and not ln.startswith('- Task') and not ln.startswith('- Isolation')]
open(p, 'w').writelines(out)
PYEOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing >/dev/null 2>&1); CODE=$?
assert_exit "validator-no-gitstate-pe" 1 "$CODE"
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-no-gitstate-ef" 1 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 11. E->F gate passes WITHOUT any test log (no deadlock on first entry)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
rm "$TASK/executions/pre-integration-test-run.log"
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-ef-no-log" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 12. AC FAIL line does NOT satisfy ac-evidence (negative test)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
HEADSHA=$(git -C "$REPO" rev-parse HEAD)
cat > "$TASK/executions/verification-ledger.md" <<EOF
# Ledger
Files: src_app.py
AC-001 FAIL src_app.py:1
AC-002 PASS src_app.py:1
Tested SHA: $HEADSHA
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-ac-fail" 1 "$CODE"
assert_contains "validator-ac-fail-check" "$OUT" "CHECK ac-evidence: FAIL"
rm -rf "$REPO"; trap - EXIT

# 13. Approved scope-change WITHOUT re-review/amendment -> FAIL scope-change-complete
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-incomplete" 1 "$CODE"
assert_contains "validator-scope-incomplete-check" "$OUT" "CHECK scope-change-complete: FAIL"
rm -rf "$REPO"; trap - EXIT

# 14. Stale decision: old approved SC-001 + new pending SC-002 -> pending wins (FAIL)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: old
Evidence: src_app.py:1
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 old
Re-review: implementation-review.md ACCEPTED

## Request SC-002 — 2026-01-02
Trigger: new
Evidence: src_app.py:2
Requested change:
+ another.py
AC impact: none
User decision: pending
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-stale" 1 "$CODE"
assert_contains "validator-scope-stale-check" "$OUT" "CHECK scope-change-complete: FAIL"
rm -rf "$REPO"; trap - EXIT

# 15. '-' removal bullets never widen scope (leak still FAILs diff-scope)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: cleanup
Evidence: src_app.py:1
Requested change:
- extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Removed extra_leak.py (reason: cleanup, scope-change SC-001).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-removal" 1 "$CODE"
assert_contains "validator-scope-removal-check" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 16. Mid-flight escalation: summary.md Classification Big overrides brief Small
read -r REPO TASK < <(make_passing_task Small); trap 'rm -rf "$REPO"' EXIT
rm "$TASK/scope-check.txt"
cat > "$TASK/executions/verification-ledger.md" <<EOF
# Ledger
Files: src_app.py
AC-001 PASS src_app.py:1
AC-002 PASS src_app.py:1
Tested SHA: $(git -C "$REPO" rev-parse HEAD)
EOF
printf '\nClassification: Big (mid-flight escalation 2026-01-02: risk rose)\n' >> "$TASK/summary.md"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-escalation" 1 "$CODE"
assert_contains "validator-escalation-check" "$OUT" "CHECK review-verdict: FAIL"
rm -rf "$REPO"; trap - EXIT

# 17. Preflight: no log -> FAIL all tier checks
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
rm "$TASK/executions/pre-integration-test-run.log"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-no-log" 1 "$CODE"
assert_contains "validator-preflight-t1" "$OUT" "CHECK preflight-tier1: FAIL"
assert_contains "validator-preflight-t3" "$OUT" "CHECK preflight-tier3: FAIL"
rm -rf "$REPO"; trap - EXIT

# 18. Preflight: full log at HEAD -> PASS
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight >/dev/null 2>&1); CODE=$?
assert_exit "validator-preflight-pass" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 19. Preflight: stale SHA (new commit) -> FAIL tier checks
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf '# touch\n' >> "$REPO/src_app.py"
git -C "$REPO" commit -qam "TASK-004: touch"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-stale" 1 "$CODE"
assert_contains "validator-preflight-stale-t1" "$OUT" "CHECK preflight-tier1: FAIL"
rm -rf "$REPO"; trap - EXIT

# 20. Preflight: Small + Tier3 waiver (Tier 1+2 at HEAD) -> PASS tier3
read -r REPO TASK < <(make_passing_task Small); trap 'rm -rf "$REPO"' EXIT
python3 - "$TASK/executions/pre-integration-test-run.log" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out, cur, skip = [], None, False
for ln in lines:
    if ln.startswith('TIER:'):
        cur = ln.split(':')[1].strip()
        skip = (cur == 'full')
    if not skip:
        out.append(ln)
open(p, 'w').writelines(out)
PYEOF
cat > "$TASK/reports/tier3-waiver.md" <<EOF
# Tier 3 waiver — 2026-01-01
User decision: 2026-01-01 waive Tier 3 full suite (reason: trivial one-file change, Tier 1+2 green).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-waiver" 0 "$CODE"
assert_contains "validator-preflight-waiver-t3" "$OUT" "CHECK preflight-tier3: PASS"
rm -rf "$REPO"; trap - EXIT

# 20b. Waiver WITHOUT parenthesized reason -> FAIL tier3
read -r REPO TASK < <(make_passing_task Small); trap 'rm -rf "$REPO"' EXIT
python3 - "$TASK/executions/pre-integration-test-run.log" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out, cur, skip = [], None, False
for ln in lines:
    if ln.startswith('TIER:'):
        cur = ln.split(':')[1].strip()
        skip = (cur == 'full')
    if not skip:
        out.append(ln)
open(p, 'w').writelines(out)
PYEOF
cat > "$TASK/reports/tier3-waiver.md" <<EOF
# Tier 3 waiver — 2026-01-01
User decision: 2026-01-01 waive Tier 3 full suite.
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-waiver-noreason" 1 "$CODE"
assert_contains "validator-preflight-waiver-noreason-t3" "$OUT" "CHECK preflight-tier3: FAIL"
rm -rf "$REPO"; trap - EXIT

# 20c. Waiver WITHOUT date/user-decision line -> FAIL tier3
read -r REPO TASK < <(make_passing_task Small); trap 'rm -rf "$REPO"' EXIT
python3 - "$TASK/executions/pre-integration-test-run.log" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out, cur, skip = [], None, False
for ln in lines:
    if ln.startswith('TIER:'):
        cur = ln.split(':')[1].strip()
        skip = (cur == 'full')
    if not skip:
        out.append(ln)
open(p, 'w').writelines(out)
PYEOF
cat > "$TASK/reports/tier3-waiver.md" <<EOF
# Tier 3 waiver
Skipping full suite (reason: in a hurry).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-waiver-nodate" 1 "$CODE"
assert_contains "validator-preflight-waiver-nodate-t3" "$OUT" "CHECK preflight-tier3: FAIL"
rm -rf "$REPO"; trap - EXIT

# 20d. Preflight on the WRONG branch (not the recorded Task branch) -> FAIL
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" checkout -q main
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-wrong-branch" 1 "$CODE"
assert_contains "validator-preflight-wrong-branch-check" "$OUT" "CHECK preflight-task-branch: FAIL"
rm -rf "$REPO"; trap - EXIT

# 21. Preflight: Big + Tier3 waiver file -> still FAIL (waivers are Small-only)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
python3 - "$TASK/executions/pre-integration-test-run.log" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out, cur, skip = [], None, False
for ln in lines:
    if ln.startswith('TIER:'):
        cur = ln.split(':')[1].strip()
        skip = (cur == 'full')
    if not skip:
        out.append(ln)
open(p, 'w').writelines(out)
PYEOF
cat > "$TASK/reports/tier3-waiver.md" <<EOF
# Tier 3 waiver — 2026-01-01
User decision: 2026-01-01 waive Tier 3 full suite (reason: in a hurry).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --preflight 2>/dev/null); CODE=$?
assert_exit "validator-preflight-big-nowaiver" 1 "$CODE"
assert_contains "validator-preflight-big-nowaiver-t3" "$OUT" "CHECK preflight-tier3: FAIL"
rm -rf "$REPO"; trap - EXIT

# 22. Complete approved scope-change (Request ID + amendment + ACCEPTED re-review) -> PASS
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-01-01

## Request SC-001 — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Added extra_leak.py (reason: needed helper, scope-change SC-001).
EOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-scope-complete" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 23. OLD approved SC-001 does NOT cover the diff when LATEST SC-002 is pending
#     (only the latest completed request widens scope)
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
Re-review: implementation-review.md ACCEPTED

## Request SC-002 — 2026-01-02
Trigger: second helper
Evidence: src_app.py:2 needs another.py
Requested change:
+ another.py
AC impact: none
User decision: pending
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Added extra_leak.py (reason: needed helper, scope-change SC-001).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-old-approved" 1 "$CODE"
assert_contains "validator-scope-old-approved-scope" "$OUT" "CHECK scope-change-complete: FAIL"
assert_contains "validator-scope-old-approved-diff" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 24. Amendment naming the WRONG request ID does not complete SC-002
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: old helper
Evidence: src_app.py:1 needs old.py
Requested change:
+ old.py
AC impact: none
User decision: approved 2026-01-01 old
Re-review: implementation-review.md ACCEPTED

## Request SC-002 — 2026-01-02
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-02 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Added old.py (reason: old helper, scope-change SC-001).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-wrong-amend" 1 "$CODE"
assert_contains "validator-scope-wrong-amend-scope" "$OUT" "CHECK scope-change-complete: FAIL"
assert_contains "validator-scope-wrong-amend-diff" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 25. Two completed requests: latest SC-002 approved+amended+reviewed -> PASS
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: old helper
Evidence: src_app.py:1 needs old.py
Requested change:
+ old.py
AC impact: none
User decision: approved 2026-01-01 old
Re-review: implementation-review.md ACCEPTED

## Request SC-002 — 2026-01-02
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-02 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-01-01 (SC-001)
Added old.py (reason: old helper, scope-change SC-001).

## Amendment — 2026-01-02 (SC-002)
Added extra_leak.py (reason: needed helper, scope-change SC-002).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-two-complete" 0 "$CODE"
assert_contains "validator-scope-two-complete-diff" "$OUT" "CHECK diff-scope: PASS"
rm -rf "$REPO"; trap - EXIT

# 26. Partial amendment: SC-003 approves TWO paths, amendment names ID + ONE
#     path only -> scope-change-complete FAILs; the unamended path still leaks.
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'approved\n' > "$REPO/approved_helper.py"
printf 'unreviewed\n' > "$REPO/unreviewed_helper.py"
git -C "$REPO" add approved_helper.py unreviewed_helper.py
git -C "$REPO" commit -q -m "TASK-003: helpers"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-10-10

## Request SC-003 — 2026-10-10
Trigger: need helpers
Evidence: src_app.py:1 needs approved_helper.py and unreviewed_helper.py
Requested change:
+ approved_helper.py
+ unreviewed_helper.py
AC impact: none
User decision: approved 2026-10-10 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-10-10 (SC-003)
Added approved_helper.py (reason: need helpers, scope-change SC-003).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>&1); CODE=$?
assert_exit "validator-scope-partial-amend" 1 "$CODE"
assert_contains "validator-scope-partial-amend-scope" "$OUT" "CHECK scope-change-complete: FAIL"
assert_contains "validator-scope-partial-amend-names-path" "$OUT" "unreviewed_helper.py"
assert_contains "validator-scope-partial-amend-diff" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 27. Stale re-review: ACCEPTED then SEND BACK in the same block -> FAIL.
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf 'oops\n' > "$REPO/extra_leak.py"
git -C "$REPO" add extra_leak.py
git -C "$REPO" commit -q -m "TASK-003: leak"
NEWSHA=$(git -C "$REPO" rev-parse HEAD)
sed -i "s/^SHA: .*$/SHA: $NEWSHA/; s/^Tested SHA: .*$/Tested SHA: $NEWSHA/" "$TASK/executions/pre-integration-test-run.log" "$TASK/executions/verification-ledger.md"
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes — 2026-10-10

## Request SC-004 — 2026-10-10
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-10-10 go ahead
Re-review: implementation-review.md ACCEPTED
Re-review: implementation-review.md SEND BACK
EOF
cat >> "$TASK/plans/plan-final.md" <<EOF

## Amendment — 2026-10-10 (SC-004)
Added extra_leak.py (reason: needed helper, scope-change SC-004).
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-scope-stale-rereview" 1 "$CODE"
assert_contains "validator-scope-stale-rereview-scope" "$OUT" "CHECK scope-change-complete: FAIL"
assert_contains "validator-scope-stale-rereview-diff" "$OUT" "CHECK diff-scope: FAIL"
rm -rf "$REPO"; trap - EXIT

# 28. Planning gate: stale pending in OLD request superseded by newer approved
#     -> planning->executing PASSES (latest-block rule everywhere).
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: old idea
Evidence: src_app.py:1
Requested change:
+ old.py
AC impact: none
User decision: pending

## Request SC-002 — 2026-01-02
Trigger: rejected idea
Evidence: src_app.py:2
Requested change:
+ another.py
AC impact: none
User decision: rejected
EOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing >/dev/null 2>&1); CODE=$?
assert_exit "validator-planning-stale-pending" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 29. Planning gate: LATEST request pending -> still FAILs.
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope changes

## Request SC-001 — 2026-01-01
Trigger: old idea
Evidence: src_app.py:1
Requested change:
+ old.py
AC impact: none
User decision: approved 2026-01-01 old
Re-review: implementation-review.md ACCEPTED

## Request SC-002 — 2026-01-02
Trigger: new idea
Evidence: src_app.py:2
Requested change:
+ another.py
AC impact: none
User decision: pending
EOF
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from planning --to executing 2>/dev/null); CODE=$?
assert_exit "validator-planning-latest-pending" 1 "$CODE"
assert_contains "validator-planning-latest-pending-check" "$OUT" "CHECK scope-change-pending: FAIL"
rm -rf "$REPO"; trap - EXIT

summary_of
