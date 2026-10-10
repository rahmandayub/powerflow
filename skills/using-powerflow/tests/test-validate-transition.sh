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
# 7b. Same leak WITH approved scope-change covering it -> PASS
cat > "$TASK/reports/scope-change.md" <<EOF
# Scope change request — 2026-01-01
Trigger: needed helper
Evidence: src_app.py:1 needs extra_leak.py
Requested change:
+ extra_leak.py
AC impact: none
User decision: approved 2026-01-01 go ahead
Re-review: implementation-review.md ACCEPTED
EOF
(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing >/dev/null 2>&1); CODE=$?
assert_exit "validator-scope-change-approved" 0 "$CODE"
rm -rf "$REPO"; trap - EXIT

# 8. Stale SHA (new commit after tests) -> FAIL tested-sha
read -r REPO TASK < <(make_passing_task Big); trap 'rm -rf "$REPO"' EXIT
printf '# touch\n' >> "$REPO/src_app.py"
git -C "$REPO" commit -qam "TASK-004: touch"
OUT=$(cd "$REPO" && bash "$VALIDATE" --task-dir "$TASK" --from executing --to finishing 2>/dev/null); CODE=$?
assert_exit "validator-stale-sha" 1 "$CODE"
assert_contains "validator-stale-sha-check" "$OUT" "CHECK tested-sha: FAIL"
rm -rf "$REPO"; trap - EXIT

# 9. Tier 3 EXIT != 0 -> FAIL tested-sha even when SHA matches
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
assert_exit "validator-tier3-fail" 1 "$CODE"
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

summary_of
