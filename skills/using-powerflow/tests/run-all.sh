#!/usr/bin/env bash
set -euo pipefail
# Runs all Powerflow fixture test suites. Exit non-zero on any failure.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
FAILED=0

run_suite() {
  echo "=== $1 ==="
  if bash "$2"; then
    :
  else
    FAILED=1
  fi
  echo
}

run_suite "init-task-dir" "$SKILLS_ROOT/powerflow-brainstorming/tests/test-init-task-dir.sh"
run_suite "isolate-branch" "$SKILLS_ROOT/powerflow-executing/tests/test-isolate-branch.sh"
run_suite "squash-branch" "$SKILLS_ROOT/powerflow-finishing/tests/test-squash-branch.sh"
run_suite "validate-transition" "$SKILLS_ROOT/using-powerflow/tests/test-validate-transition.sh"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
else
  echo "SOME SUITES FAILED"
  exit 1
fi
