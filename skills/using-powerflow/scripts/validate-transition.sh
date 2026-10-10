#!/usr/bin/env bash
set -euo pipefail

# Validates Powerflow phase transitions deterministically.
# Usage:
#   validate-transition.sh --task-dir <dir> --from planning --to executing
#   validate-transition.sh --task-dir <dir> --from executing --to finishing
#
# Checks are grep/diff/SHA based, not semantic: verdict vocabulary, AC-ID
# linkage, diff-containment in Scope, tested-SHA equality, base from summary.md.
# Small tasks: no review files / no ledger by design — the scope-check note is
# checked instead. Classification comes from context/brief.md ([OVERRIDE BY USER]
# honored).
#
# Exit codes: 0 all checks pass | 1 gate FAIL | 2 usage, missing task dir,
#   not a git repo, or unreadable summary.md
# Output: stdout gets one CHECK <name>: PASS|FAIL line per check plus a final
#   RESULT line; stderr gets remediation hints.

TASK_DIR=""
FROM=""
TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir) TASK_DIR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    *) echo "Usage: validate-transition.sh --task-dir <dir> --from planning|executing --to executing|finishing" >&2; exit 2 ;;
  esac
done

if [ -z "$TASK_DIR" ] || [ -z "$FROM" ] || [ -z "$TO" ]; then
  echo "Usage: validate-transition.sh --task-dir <dir> --from planning|executing --to executing|finishing" >&2
  exit 2
fi

if [ ! -d "$TASK_DIR" ]; then
  echo "Error: task dir not found: $TASK_DIR" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 2
fi

SUMMARY="$TASK_DIR/summary.md"
if [ ! -f "$SUMMARY" ]; then
  echo "Error: summary.md not found at $SUMMARY" >&2
  exit 2
fi

FAIL_COUNT=0
check() { # check <name> <0|1> [hint]
  if [ "$2" -eq 0 ]; then
    echo "CHECK $1: PASS"
  else
    echo "CHECK $1: FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ -n "${3:-}" ]; then
      echo "  Hint: $3" >&2
    fi
  fi
}

# --- shared helpers ----------------------------------------------------------

# Classification: Small if brief states "Classification: Small" (any marker style),
# else Big. Template headers like "Classification (Small/Big ...)" have no colon
# and never match.
CLASS="Big"
BRIEF="$TASK_DIR/context/brief.md"
if [ -f "$BRIEF" ]; then
  if grep -Ei 'classification[^:]*:[[:space:]]*[*_]*small\b' "$BRIEF" >/dev/null; then
    CLASS="Small"
  fi
fi

git_state_field() { # git_state_field <label>
  grep -E "^[*-][[:space:]]+$1:" "$SUMMARY" | head -n 1 | sed -E "s/^[*-][[:space:]]+$1:[[:space:]]*//; s/[[:space:]]*$//" || true
}

BASE_BRANCH=$(git_state_field "Base branch")
BASE_SHA=$(git_state_field "Base SHA")
TASK_BRANCH=$(git_state_field "Task branch")

# Verdict token, case-sensitive: prefers a "Verdict:"-prefixed line
# ("## Verdict: ACCEPTED") and falls back to the last bare token ("- APPROVED").
# Lowercase "approved" never matches. Grep-based, not semantic.
last_verdict() { # last_verdict <file>
  local v
  v=$(grep -Ei 'verdict[[:space:]]*:' "$1" 2>/dev/null | grep -Eo '\b(APPROVED|REVISE AND RESUBMIT|BLOCKED|ACCEPTED|SEND BACK|ESCALATE)\b' | tail -n 1 || true)
  if [ -z "$v" ]; then
    v=$(grep -Eo '\b(APPROVED|REVISE AND RESUBMIT|BLOCKED|ACCEPTED|SEND BACK|ESCALATE)\b' "$1" 2>/dev/null | tail -n 1 || true)
  fi
  printf '%s' "$v"
}

# --- gate: planning -> executing ---------------------------------------------

gate_planning_executing() {
  PLAN="$TASK_DIR/plans/plan-final.md"
  if [ -f "$PLAN" ]; then
    HAS_SCOPE=$(grep -Eq '^[#*-]*[[:space:]]*Scope' "$PLAN" && echo yes || echo no)
    HAS_MNC=$(grep -Eq 'Must Not Change' "$PLAN" && echo yes || echo no)
    HAS_AC_HDR=$(grep -Eq 'Acceptance Criteria' "$PLAN" && echo yes || echo no)
    HAS_OOS=$(grep -Eq 'Out of Scope' "$PLAN" && echo yes || echo no)
    HAS_AC_ID=$(grep -Eq 'AC-[0-9]+' "$PLAN" && echo yes || echo no)
    if [ "$HAS_SCOPE" = yes ] && [ "$HAS_MNC" = yes ] && [ "$HAS_AC_HDR" = yes ] && [ "$HAS_OOS" = yes ] && [ "$HAS_AC_ID" = yes ]; then
      check "plan-final-contract" 0
    else
      check "plan-final-contract" 1 "plan-final.md must contain Scope, Must Not Change, Acceptance Criteria, Out of Scope headers and at least one AC-00X id"
    fi
  else
    check "plan-final-contract" 1 "plans/plan-final.md not found"
  fi

  REVIEW="$TASK_DIR/reviews/plan-review.md"
  if [ -f "$REVIEW" ]; then
    V=$(last_verdict "$REVIEW")
    if [ "$V" = "APPROVED" ]; then
      check "review-verdict" 0
    else
      check "review-verdict" 1 "last plan-review verdict must be exactly APPROVED (found: '${V:-none}'; note: lowercase 'approved' does not count)"
    fi
  elif [ "$CLASS" = "Small" ]; then
    check "review-verdict" 0
  else
    check "review-verdict" 1 "Big task requires reviews/plan-review.md with APPROVED"
  fi

  if [ -f "$BRIEF" ]; then
    if grep -Eq 'Complexity:[[:space:]]*(Low|High)' "$BRIEF" && grep -Eq 'Risk:[[:space:]]*(Low|High)' "$BRIEF"; then
      check "brief-complexity-risk" 0
    else
      check "brief-complexity-risk" 1 "brief.md must state Complexity: Low/High and Risk: Low/High lines"
    fi
  else
    check "brief-complexity-risk" 1 "context/brief.md not found"
  fi

  SC="$TASK_DIR/reports/scope-change.md"
  if [ -f "$SC" ] && grep -Eq 'User decision:[[:space:]]*pending' "$SC"; then
    check "scope-change-pending" 1 "scope-change.md has User decision: pending — resolve before transitioning"
  else
    check "scope-change-pending" 0
  fi

  if [ -n "$BASE_BRANCH" ] && [ -n "$BASE_SHA" ]; then
    check "git-state" 0
  else
    check "git-state" 1 "summary.md Git State must record Base branch and Base SHA (run isolate-branch.sh --porcelain)"
  fi
}

# --- gate: executing -> finishing --------------------------------------------

plan_ac_ids() { # prints AC-001 style ids, one per line, sorted unique
  grep -Eo 'AC-[0-9]+' "$TASK_DIR/plans/plan-final.md" 2>/dev/null | sort -u || true
}

ledger_has_ac() { # ledger_has_ac <AC-ID> -> 0 if id appears with PASS|FAIL + evidence
  local id="$1"
  local ledger="$TASK_DIR/executions/verification-ledger.md"
  local note="$TASK_DIR/scope-check.txt"
  if [ -f "$ledger" ] && grep -E "$id.*(PASS|FAIL)" "$ledger" | grep -Eq 'file:|log:|[A-Za-z0-9_./-]+:[0-9]+'; then
    return 0
  fi
  if [ -f "$note" ] && grep -E "$id.*(PASS|FAIL)" "$note" | grep -Eq 'file:|log:|[A-Za-z0-9_./-]+:[0-9]+'; then
    return 0
  fi
  return 1
}

approved_extra_paths() { # prints paths from approved scope-change entries
  # Template "Requested change" section holds +/- path bullets; parse only after
  # a "User decision: approved" line so pending/rejected requests never pass.
  local sc="$TASK_DIR/reports/scope-change.md"
  if [ -f "$sc" ] && grep -Eq 'User decision:[[:space:]]*approved' "$sc"; then
    awk '/Requested change/{flag=1; next} /AC impact/{flag=0} flag' "$sc" \
      | grep -Eo '^[[:space:]]*[+-][[:space:]]+[A-Za-z0-9_./-]+' \
      | sed -E 's/^[[:space:]]*[+-][[:space:]]+//' || true
  fi
}

plan_scope_paths() { # prints scope bullet paths from plan-final.md
  awk '/^[#*-]*[[:space:]]*Scope/{flag=1; next} /^[#*-]*[[:space:]]*(Must Not Change|Acceptance Criteria|Out of Scope)/{flag=0} flag' \
    "$TASK_DIR/plans/plan-final.md" 2>/dev/null | grep -Eo '^[[:space:]]*[-*][[:space:]]+[A-Za-z0-9_./-]+' | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' || true
}

plan_mnc_text() { # prints Must-Not-Change section text
  awk '/Must Not Change/{flag=1; next} /Out of Scope/{flag=0} flag' \
    "$TASK_DIR/plans/plan-final.md" 2>/dev/null || true
}

gate_executing_finishing() {
  REVIEW="$TASK_DIR/reviews/implementation-review.md"
  if [ -f "$REVIEW" ]; then
    V=$(last_verdict "$REVIEW")
    if [ "$V" = "ACCEPTED" ]; then
      check "review-verdict" 0
    else
      check "review-verdict" 1 "last implementation-review verdict must be exactly ACCEPTED (found: '${V:-none}')"
    fi
  elif [ "$CLASS" = "Small" ]; then
    check "review-verdict" 0
  else
    check "review-verdict" 1 "Big task requires reviews/implementation-review.md with ACCEPTED"
  fi

  MISSING_AC=""
  for id in $(plan_ac_ids); do
    if ! ledger_has_ac "$id"; then
      MISSING_AC="$MISSING_AC $id"
    fi
  done
  if [ -z "$(plan_ac_ids)" ]; then
    check "ac-evidence" 1 "no AC-00X ids found in plan-final.md"
  elif [ -z "$MISSING_AC" ]; then
    check "ac-evidence" 0
  else
    check "ac-evidence" 1 "AC ids without PASS|FAIL + evidence in verification-ledger.md (or scope-check.txt):$MISSING_AC"
  fi

  if [ -z "$BASE_SHA" ] || [ -z "$BASE_BRANCH" ]; then
    check "diff-scope" 1 "summary.md Git State must record Base branch and Base SHA"
  else
    if ! git merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
      check "diff-scope" 1 "Base SHA $BASE_SHA is not an ancestor of HEAD — wrong base or rebased branch"
    else
      DIFF_FILES=$(git diff --name-only "$BASE_SHA"...HEAD 2>/dev/null || true)
      SCOPE=$(plan_scope_paths)
      EXTRA=$(approved_extra_paths)
      MNC=$(plan_mnc_text)
      LEAK=""
      MNC_HIT=""
      for f in $DIFF_FILES; do
        IN_SCOPE=1
        for s in $SCOPE $EXTRA; do
          # prefix match: scope entry covers the file or its directory
          if [ "$f" = "$s" ] || [[ "$f" == "$s"/* ]] || [[ "$s" == "$f"/* ]]; then
            IN_SCOPE=0
            break
          fi
        done
        if [ "$IN_SCOPE" -eq 1 ]; then
          LEAK="$LEAK $f"
        fi
        if [ -n "$MNC" ] && printf '%s\n' "$MNC" | grep -Eq "(^|[^A-Za-z0-9_./-])$(printf '%s' "$f" | sed 's/\./\\./g')([^A-Za-z0-9_./-]|$)"; then
          MNC_HIT="$MNC_HIT $f"
        fi
      done
      if [ -n "$MNC_HIT" ]; then
        check "diff-scope" 1 "changed files touch Must Not Change:$MNC_HIT"
      elif [ -n "$LEAK" ]; then
        check "diff-scope" 1 "changed files outside Scope (no approved scope-change):$LEAK"
      else
        check "diff-scope" 0
      fi
    fi
  fi

  TESTED_SHA=""
  TIER3_PASS=1
  LOG="$TASK_DIR/executions/pre-integration-test-run.log"
  if [ -f "$LOG" ]; then
    # SHA and EXIT of the LAST full-tier block (log may hold several runs).
    TESTED_SHA=$(awk '/^TIER:/{cur=$2} cur=="full" && /^SHA:/{sha=$2} END{print sha}' "$LOG" || true)
    LAST_EXIT=$(awk '/^TIER:/{cur=$2} cur=="full" && /^EXIT:/{e=$2} END{print e}' "$LOG" || true)
    if [ "${LAST_EXIT:-}" = "0" ]; then
      TIER3_PASS=0
    fi
  fi
  if [ -z "$TESTED_SHA" ]; then
    LEDGER="$TASK_DIR/executions/verification-ledger.md"
    if [ -f "$LEDGER" ]; then
      TESTED_SHA=$(grep -Eo 'Tested SHA:[[:space:]]*[0-9a-f]{7,40}' "$LEDGER" | tail -n 1 | grep -Eo '[0-9a-f]{7,40}' || true)
    fi
  fi
  HEAD_SHA=$(git rev-parse HEAD)
  if [ -z "$TESTED_SHA" ]; then
    check "tested-sha" 1 "no SHA: line in a TIER: full block of pre-integration-test-run.log (or Tested SHA: in ledger) — re-run tests at current HEAD"
  elif [ "$TIER3_PASS" -ne 0 ]; then
    check "tested-sha" 1 "last TIER: full block did not pass (EXIT != 0) — fix failures before integrating"
  elif [ "$TESTED_SHA" = "$HEAD_SHA" ] || [[ "$HEAD_SHA" == "$TESTED_SHA"* ]]; then
    check "tested-sha" 0
  else
    check "tested-sha" 1 "tested SHA $TESTED_SHA != HEAD $HEAD_SHA — evidence is stale, re-run tests"
  fi

  if [ -z "$BASE_BRANCH" ] || [ -z "$BASE_SHA" ] || [ -z "$TASK_BRANCH" ]; then
    check "git-state" 1 "summary.md Git State must record Base branch, Base SHA, Task branch"
  else
    if [ "$TASK_BRANCH" != "HEAD" ] && ! git show-ref --verify --quiet "refs/heads/$TASK_BRANCH"; then
      check "git-state" 1 "task branch $TASK_BRANCH no longer exists — it may have been deleted before verification"
    else
      check "git-state" 0
    fi
  fi

  PORCELAIN=$(git status --porcelain)
  TRACKED_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -v '^??' | grep -v '^ *$' || true)
  if [ -n "$TRACKED_DIRTY" ]; then
    check "clean-tree" 1 "working tree has tracked changes — commit or stash before integrating"
  else
    check "clean-tree" 0
  fi
}

# --- dispatch ----------------------------------------------------------------

if [ "$FROM" = "planning" ] && [ "$TO" = "executing" ]; then
  gate_planning_executing
elif [ "$FROM" = "executing" ] && [ "$TO" = "finishing" ]; then
  gate_executing_finishing
else
  echo "Error: unsupported transition --from $FROM --to $TO" >&2
  exit 2
fi

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL ($FAIL_COUNT check(s) failed)"
  exit 1
fi
