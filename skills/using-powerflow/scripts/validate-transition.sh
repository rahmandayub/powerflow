#!/usr/bin/env bash
set -euo pipefail

# Validates Powerflow phase transitions deterministically.
# Usage:
#   validate-transition.sh --task-dir <dir> --from planning --to executing
#   validate-transition.sh --task-dir <dir> --from executing --to finishing
#   validate-transition.sh --task-dir <dir> --preflight
#
# The executing->finishing gate checks contract, review, scope, and git state
# only — it must PASS before any test log exists. The --preflight mode runs
# later, immediately before a destructive integration op (merge/discard): it
# requires Tier 1+2 PASS at HEAD plus Tier 3 PASS at HEAD, unless a Tier 3
# waiver file exists (Small tasks only, Tier 1+2 still required at HEAD).
#
# Checks are grep/diff/SHA based, not semantic: verdict vocabulary, AC-ID
# linkage, diff-containment in Scope, tested-SHA equality, base from summary.md.
# Small tasks: no review files / no ledger by design — the scope-check note is
# checked instead. Classification comes from summary.md when it records a
# "Classification: Small|Big" line (mid-flight escalation), else from
# context/brief.md ([OVERRIDE BY USER] honored).
#
# Scope-change protocol: the file holds one block per request, each headed by
# "## Request <ID>" (e.g. "## Request SC-001 — 2026-01-01"). Only the LATEST
# request block counts. An approved request covers out-of-scope diffs only
# with its own '+' (addition) paths, an Amendment section in plan-final.md
# naming that request ID and its paths, and a "Re-review: ... ACCEPTED" line
# inside the same request block. Older approved requests never widen scope
# for newer diffs. Only AC lines with PASS count as evidence.
#
# Exit codes: 0 all checks pass | 1 gate FAIL | 2 usage, missing task dir,
#   not a git repo, or unreadable summary.md
# Output: stdout gets one CHECK <name>: PASS|FAIL line per check plus a final
#   RESULT line; stderr gets remediation hints.

TASK_DIR=""
FROM=""
TO=""
PREFLIGHT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir) TASK_DIR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --preflight) PREFLIGHT=true; shift ;;
    *) echo "Usage: validate-transition.sh --task-dir <dir> --from planning|executing --to executing|finishing | validate-transition.sh --task-dir <dir> --preflight" >&2; exit 2 ;;
  esac
done

if [ -z "$TASK_DIR" ]; then
  echo "Usage: validate-transition.sh --task-dir <dir> --from planning|executing --to executing|finishing | validate-transition.sh --task-dir <dir> --preflight" >&2
  exit 2
fi

if [ "$PREFLIGHT" = true ]; then
  if [ -n "$FROM" ] || [ -n "$TO" ]; then
    echo "Error: --preflight does not take --from/--to" >&2
    exit 2
  fi
elif [ -z "$FROM" ] || [ -z "$TO" ]; then
  echo "Usage: validate-transition.sh --task-dir <dir> --from planning|executing --to executing|finishing | validate-transition.sh --task-dir <dir> --preflight" >&2
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

# Classification: Small if the CURRENT classification says Small, else Big.
# Source of truth is summary.md (mid-flight escalation writes
# "Classification: Big" there); falls back to context/brief.md for tasks that
# never escalated. Template headers like "Classification (Small/Big ...)" have
# no colon and never match.
CLASS="Big"
BRIEF="$TASK_DIR/context/brief.md"
class_line() { # class_line <file> -> prints Small|Big or nothing
  grep -Ei 'classification[^:]*:[[:space:]]*[*_]*[a-z]+' "$1" 2>/dev/null \
    | grep -Eio 'classification[^:]*:[[:space:]]*[*_]*(small|big)\b' \
    | tail -n 1 | grep -Eo '(small|big)\b' -i || true
}
SUMMARY_CLASS=$(class_line "$SUMMARY")
if [ -n "$SUMMARY_CLASS" ]; then
  if printf '%s' "$SUMMARY_CLASS" | grep -Eqi '^small$'; then
    CLASS="Small"
  fi
elif [ -f "$BRIEF" ]; then
  if printf '%s' "$(class_line "$BRIEF")" | grep -Eqi '^small$'; then
    CLASS="Small"
  fi
fi

git_state_field() { # git_state_field <label>
  grep -E "^[*-][[:space:]]+$1:" "$SUMMARY" | head -n 1 | sed -E "s/^[*-][[:space:]]+$1:[[:space:]]*//; s/[[:space:]]*$//" || true
}

BASE_BRANCH=$(git_state_field "Base branch")
BASE_REF_STATE=$(git_state_field "Base ref")
BASE_SHA=$(git_state_field "Base SHA")
TASK_BRANCH=$(git_state_field "Task branch")
# Effective base ref for ancestry/diff checks: the exact recorded ref when
# present (e.g. upstream/main), else the short branch name (older summaries).
if [ -n "$BASE_REF_STATE" ]; then
  BASE_REF="$BASE_REF_STATE"
else
  BASE_REF="$BASE_BRANCH"
fi

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
  if [ -f "$SC" ]; then
    # Full shared policy: the planning gate must not let an incomplete
    # approval through only to fail at the end of implementation.
    SC_STATUS=$(scope_change_policy)
    case "$SC_STATUS" in
      ok-none|ok-rejected|ok-complete)
        check "scope-change-pending" 0
        ;;
      fail-pending)
        check "scope-change-pending" 1 "scope-change.md latest request User decision is pending — resolve before transitioning"
        ;;
      fail-unparseable)
        check "scope-change-pending" 1 "scope-change.md latest request has no parseable User decision (pending|approved|rejected) — resolve before transitioning"
        ;;
      fail-rereview|fail-amendment|fail-paths:*)
        check "scope-change-pending" 1 "scope-change.md latest request approved but protocol incomplete ($SC_STATUS) — amend the plan and re-run the reviewer before transitioning"
        ;;
    esac
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

ledger_has_ac() { # ledger_has_ac <AC-ID> -> 0 if id appears with PASS + evidence
  # Only PASS counts: a FAIL line proves the criterion was tested and failed,
  # not that it is satisfied.
  local id="$1"
  local ledger="$TASK_DIR/executions/verification-ledger.md"
  local note="$TASK_DIR/scope-check.txt"
  if [ -f "$ledger" ] && grep -E "$id[^0-9].*PASS" "$ledger" | grep -Eq 'file:|log:|[A-Za-z0-9_./-]+:[0-9]+'; then
    return 0
  fi
  if [ -f "$note" ] && grep -E "$id[^0-9].*PASS" "$note" | grep -Eq 'file:|log:|[A-Za-z0-9_./-]+:[0-9]+'; then
    return 0
  fi
  return 1
}

scope_change_latest_block() { # prints the LATEST "## Request ..." block of scope-change.md
  # Request blocks start at a "## Request <id>" heading and run to the next
  # "## Request " heading or EOF. Files without any such heading are legacy:
  # the whole file is treated as one block.
  local sc="$TASK_DIR/reports/scope-change.md"
  [ -f "$sc" ] || return 1
  if ! grep -Eq '^## Request ' "$sc"; then
    cat "$sc"
    return 0
  fi
  awk '
    /^## Request / { if (buf != "") last = buf; buf = ""; in_req = 1; }
    in_req { buf = buf $0 "\n"; }
    END { if (buf != "") last = buf; printf "%s", last; }
  ' "$sc"
}

scope_change_latest_id() { # prints the latest request ID (e.g. SC-001), or empty for legacy files
  grep -E '^## Request ' "$TASK_DIR/reports/scope-change.md" 2>/dev/null \
    | tail -n 1 | grep -Eo 'SC-[0-9]+' | head -n 1 || true
}

scope_change_latest_decision() { # prints the LATEST request's "User decision:" value, lowercased
  scope_change_latest_block 2>/dev/null \
    | grep -Ei 'user decision[[:space:]]*:' \
    | tail -n 1 | grep -Eo '(approved|pending|rejected)\b' -i | tr '[:upper:]' '[:lower:]' || true
}

# Shared scope-change policy for BOTH gates (planning->executing and
# executing->finishing): evaluates the LATEST request block and echoes one of:
#   ok-none      (no scope-change.md)
#   ok-rejected  (latest decision rejected)
#   ok-complete  (latest approved + amended + re-reviewed ACCEPTED)
#   fail-pending | fail-unparseable | fail-rereview | fail-amendment | fail-paths:<...>
scope_change_policy() {
  local sc="$TASK_DIR/reports/scope-change.md"
  if [ ! -f "$sc" ]; then
    echo "ok-none"
    return 0
  fi
  local decision req_id
  decision=$(scope_change_latest_decision)
  req_id=$(scope_change_latest_id)
  if [ -n "$req_id" ]; then
    WHAT="request $req_id"
  else
    WHAT="latest request"
  fi
  if [ "$decision" = "pending" ]; then
    echo "fail-pending"
  elif [ "$decision" = "rejected" ]; then
    echo "ok-rejected"
  elif [ "$decision" = "approved" ]; then
    local paths
    paths=$(scope_change_latest_block | awk '/Requested change/{flag=1; next} /AC impact/{flag=0} flag' | grep -Eo '^[[:space:]]*\+[[:space:]]+[A-Za-z0-9_./-]+' | sed -E 's/^[[:space:]]*\+[[:space:]]+//' || true)
    if ! scope_change_rereview_accepted; then
      echo "fail-rereview"
    elif ! plan_amendment_names "$req_id" "$paths"; then
      echo "fail-amendment"
    else
      local unamended
      # shellcheck disable=SC2086
      unamended=$(comm -23 <(printf '%s\n' $paths | sort -u) <(amended_paths_only "$req_id" $paths | sort -u) || true)
      if [ -n "$unamended" ]; then
        printf 'fail-paths:%s' "$(printf ' %s' $unamended)"
      else
        echo "ok-complete"
      fi
    fi
  else
    echo "fail-unparseable"
  fi
}

scope_change_blocks() { # prints "## Request ..." start line numbers, one per line
  grep -n '^## Request ' "$TASK_DIR/reports/scope-change.md" 2>/dev/null | cut -d: -f1 || true
}

scope_change_block_at() { # scope_change_block_at <start-line> <end-line|''> -> block text
  local from="$1" to="$2" file="$TASK_DIR/reports/scope-change.md"
  if [ -n "$to" ]; then
    sed -n "${from},$((to - 1))p" "$file"
  else
    sed -n "${from},\$p" "$file"
  fi
}

block_decision() { # block_decision <block-text> -> approved|pending|rejected|''
  printf '%s' "$1" | grep -Ei 'user decision[[:space:]]*:' \
    | tail -n 1 | grep -Eo '(approved|pending|rejected)\b' -i | tr '[:upper:]' '[:lower:]' || true
}

block_rereview_accepted() { # 0 if the block's LATEST Re-review line says ACCEPTED
  local verdict
  verdict=$(printf '%s' "$1" | grep -Ei 're-review[[:space:]]*:' \
    | grep -Eo '\b(ACCEPTED|SEND BACK)\b' | tail -n 1 || true)
  [ "$verdict" = "ACCEPTED" ]
}

scope_change_rereview_accepted() { # 0 if the LATEST block's LATEST Re-review line says ACCEPTED
  block_rereview_accepted "$(scope_change_latest_block 2>/dev/null)"
}

block_plus_paths() { # block_plus_paths <block-text> -> '+' paths, one per line
  printf '%s' "$1" \
    | awk '/Requested change/{flag=1; next} /AC impact/{flag=0} flag' \
    | grep -Eo '^[[:space:]]*\+[[:space:]]+[A-Za-z0-9_./-]+' \
    | sed -E 's/^[[:space:]]*\+[[:space:]]+//' || true
}

block_id() { # block_id <block-text> -> SC-00X or empty
  printf '%s' "$1" | head -n 1 | grep -Eo 'SC-[0-9]+' | head -n 1 || true
}

# 0 if the given request block is COMPLETED: approved + amended (ID/paths) +
# latest Re-review ACCEPTED. Prints its amended '+' paths on success.
block_completed_paths() { # block_completed_paths <block-text> -> covered paths
  local block="$1" decision req_id paths
  decision=$(block_decision "$block")
  [ "$decision" = "approved" ] || return 1
  block_rereview_accepted "$block" || return 1
  req_id=$(block_id "$block")
  paths=$(block_plus_paths "$block")
  [ -n "$paths" ] || return 1
  plan_amendment_names "$req_id" "$paths" || return 1
  # shellcheck disable=SC2086
  amended_paths_only "$req_id" $paths
}

amendment_text() { # prints the Amendment section(s) for the request: from an Amendment heading naming the ID to the next heading (or EOF); all Amendment sections if legacy
  local req_id="$1"
  local plan="$TASK_DIR/plans/plan-final.md"
  [ -f "$plan" ] || return 0
  if [ -n "$req_id" ]; then
    awk -v id="$req_id" '
      /^#/ { if (in_sec) exit; if (tolower($0) ~ /amendment/ && index($0, id)) in_sec = 1; next }
      in_sec { print }
    ' "$plan" || true
  else
    awk '
      /^#/ { if (tolower($0) ~ /amendment/) in_sec = 1; else in_sec = 0; next }
      in_sec { print }
    ' "$plan" || true
  fi
}

plan_amendment_names() { # 0 if plan-final.md amends the given request: names its ID, or (legacy) its paths
  local req_id="$1" req_paths="$2"
  local plan="$TASK_DIR/plans/plan-final.md"
  grep -Eqi 'amendment' "$plan" 2>/dev/null || return 1
  if [ -n "$req_id" ]; then
    grep -Ei 'amendment' "$plan" 2>/dev/null | grep -Eq "$req_id" && return 0
    return 1
  fi
  # Legacy files have no Request ID: the amendment must name at least one of
  # the request's '+' paths.
  local p
  for p in $req_paths; do
    if grep -Ei 'amendment' "$plan" 2>/dev/null | grep -Eq "(^|[^A-Za-z0-9_./-])$(printf '%s' "$p" | sed 's/\./\\./g')([^A-Za-z0-9_./-]|$)"; then
      return 0
    fi
  done
  return 1
}

# Prints the subset of req_paths actually named in the amendment text.
# For ID requests: amendment must name the ID AND each covered path.
# For legacy: amendment must name each covered path.
amended_paths_only() { # amended_paths_only <req_id> <req_paths...> -> covered paths, one per line
  local req_id="$1"; shift
  local text p
  text=$(amendment_text "$req_id")
  [ -n "$text" ] || return 0
  for p in "$@"; do
    if printf '%s\n' "$text" | grep -Eq "(^|[^A-Za-z0-9_./-])$(printf '%s' "$p" | sed 's/\./\\./g')([^A-Za-z0-9_./-]|$)"; then
      printf '%s\n' "$p"
    fi
  done
}

approved_extra_paths() { # prints CUMULATIVE '+' paths from ALL completed requests
  # Effective scope is cumulative: every request block that is completed
  # (approved + amended + latest Re-review ACCEPTED) contributes its amended
  # '+' paths. The LATEST block's own completeness is enforced separately by
  # scope_change_policy(): a pending/incomplete latest request still blocks
  # the transition, but it never revokes paths completed by earlier requests.
  # '-' bullets are removals and never widen the allowed diff.
  local sc="$TASK_DIR/reports/scope-change.md"
  [ -f "$sc" ] || return 0
  if ! grep -Eq '^## Request ' "$sc"; then
    # Legacy file without Request IDs: treat as a single block.
    block_completed_paths "$(cat "$sc")" || return 0
    return 0
  fi
  local starts start next block
  starts=$(scope_change_blocks)
  for start in $starts; do
    next=$(printf '%s\n' "$starts" | awk -v s="$start" '$1 > s { print $1; exit }')
    block=$(scope_change_block_at "$start" "$next")
    block_completed_paths "$block" || true
  done | sort -u
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
    check "ac-evidence" 1 "AC ids without PASS + evidence in verification-ledger.md (or scope-check.txt):$MISSING_AC"
  fi

  # Scope-change protocol completion via the shared policy: only the LATEST
  # "## Request" block counts; older approved requests never widen scope.
  SC_FILE="$TASK_DIR/reports/scope-change.md"
  if [ -f "$SC_FILE" ]; then
    LATEST_ID=$(scope_change_latest_id)
    if [ -n "$LATEST_ID" ]; then
      LATEST_WHAT="request $LATEST_ID"
    else
      LATEST_WHAT="latest request"
    fi
    SC_STATUS=$(scope_change_policy)
    case "$SC_STATUS" in
      ok-none|ok-rejected|ok-complete)
        check "scope-change-complete" 0
        ;;
      fail-pending)
        check "scope-change-complete" 1 "scope-change.md $LATEST_WHAT User decision is pending — resolve before transitioning"
        ;;
      fail-unparseable)
        check "scope-change-complete" 1 "scope-change.md $LATEST_WHAT has no parseable User decision (pending|approved|rejected) — resolve before transitioning"
        ;;
      fail-rereview)
        check "scope-change-complete" 1 "scope-change $LATEST_WHAT approved but its latest Re-review verdict is not ACCEPTED — re-run the reviewer before transitioning"
        ;;
      fail-amendment)
        if [ -n "$LATEST_ID" ]; then
          check "scope-change-complete" 1 "scope-change $LATEST_WHAT approved but plan-final.md has no Amendment naming $LATEST_ID — amend the plan before transitioning"
        else
          check "scope-change-complete" 1 "scope-change approved but plan-final.md has no Amendment naming its paths — amend the plan before transitioning"
        fi
        ;;
      fail-paths:*)
        MISSING=${SC_STATUS#fail-paths:}
        check "scope-change-complete" 1 "scope-change $LATEST_WHAT amendment omits approved paths:$MISSING — amend every path before transitioning"
        ;;
    esac
  else
    check "scope-change-complete" 0
  fi

  if [ -z "$BASE_SHA" ] || [ -z "$BASE_REF" ]; then
    check "diff-scope" 1 "summary.md Git State must record Base branch (or Base ref) and Base SHA"
  else
    if ! git merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
      check "diff-scope" 1 "Base SHA $BASE_SHA is not an ancestor of HEAD — wrong base or rebased branch"
    elif ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
      check "diff-scope" 1 "Base ref '$BASE_REF' not found in this repo — fetch the integration remote or fix Git State"
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

  # NOTE: no tested-sha check here by design. The pre-integration test log is
  # written AFTER this gate (Finishing Section 2); requiring it here deadlocks
  # first entry into Finishing. Run --preflight before merge/discard instead.

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

# --- preflight: immediately before a destructive integration op ---------------
# Requires Tier 1+2 PASS at HEAD plus Tier 3 PASS at HEAD, unless a Tier 3
# waiver file exists. Waivers are Small-task only: <task-dir>/reports/
# tier3-waiver.md must record the user decision verbatim with a date and a
# reason; Tier 1+2 are never waivable. Big tasks always need Tier 3.

tier_pass_at_head() { # tier_pass_at_head <tier> <head-sha> -> 0 if last block passed at HEAD
  local tier="$1" head="$2" log="$TASK_DIR/executions/pre-integration-test-run.log"
  [ -f "$log" ] || return 1
  local last
  last=$(awk -v t="$tier" '
    /^TIER:/ { cur=$2; sha=""; ex="" }
    cur==t && /^SHA:/ { sha=$2 }
    cur==t && /^EXIT:/ { ex=$2 }
    cur==t && /^EXIT:/ { last_sha=sha; last_ex=ex }
    END { if (last_sha != "") print last_sha " " last_ex }
  ' "$log" || true)
  [ -n "$last" ] || return 1
  local lsha lexit
  lsha=$(printf '%s' "$last" | cut -d' ' -f1)
  lexit=$(printf '%s' "$last" | cut -d' ' -f2)
  [ "$lexit" = "0" ] || return 1
  [ "$lsha" = "$head" ] || [[ "$head" == "$lsha"* ]]
}

tier3_waived() { # 0 if a valid Small-task Tier 3 waiver exists
  # Strict shape: a "User decision:" line carrying a YYYY-MM-DD date, a
  # waiver verb, a Tier 3 reference, AND a parenthesized reason. A bare
  # "waive tier 3" with no date or no reason does not count.
  local w="$TASK_DIR/reports/tier3-waiver.md"
  [ -f "$w" ] || return 1
  [ "$CLASS" = "Small" ] || return 1
  grep -Ei 'user decision[[:space:]]*:' "$w" | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}' || return 1
  grep -Eqi 'waiv' "$w" || return 1
  grep -Eqi 'tier ?3|full suite|full' "$w" || return 1
  grep -Eq '\([^)]*(reason|because|rational|justif)' "$w"
}

gate_preflight() {
  HEAD_SHA=$(git rev-parse HEAD)

  if tier_pass_at_head "smoke" "$HEAD_SHA"; then
    check "preflight-tier1" 0
  else
    check "preflight-tier1" 1 "no passing TIER: smoke block at HEAD $HEAD_SHA in pre-integration-test-run.log — run Tier 1 first"
  fi

  if tier_pass_at_head "affected" "$HEAD_SHA"; then
    check "preflight-tier2" 0
  else
    check "preflight-tier2" 1 "no passing TIER: affected block at HEAD $HEAD_SHA in pre-integration-test-run.log — run Tier 2 first"
  fi

  if tier_pass_at_head "full" "$HEAD_SHA"; then
    check "preflight-tier3" 0
  elif tier3_waived; then
    check "preflight-tier3" 0
  else
    if [ "$CLASS" = "Small" ]; then
      check "preflight-tier3" 1 "no passing TIER: full block at HEAD $HEAD_SHA — run Tier 3, or record a dated waiver in reports/tier3-waiver.md (Small only; Tier 1+2 still required)"
    else
      check "preflight-tier3" 1 "no passing TIER: full block at HEAD $HEAD_SHA — run Tier 3 (Big tasks cannot waive it)"
    fi
  fi

  PORCELAIN=$(git status --porcelain)
  TRACKED_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -v '^??' | grep -v '^ *$' || true)
  if [ -n "$TRACKED_DIRTY" ]; then
    check "preflight-clean-tree" 1 "working tree has tracked changes — commit or stash before integrating"
  else
    check "preflight-clean-tree" 0
  fi

  if git symbolic-ref -q HEAD >/dev/null 2>&1; then
    check "preflight-on-branch" 0
  else
    check "preflight-on-branch" 1 "detached HEAD at $(git rev-parse --short HEAD) — use the Detached HEAD menu"
  fi

  # The branch being integrated must be the recorded task branch: integrating
  # from any other checkout would test one ref and merge another.
  if [ -z "$TASK_BRANCH" ]; then
    check "preflight-task-branch" 1 "summary.md Git State must record Task branch"
  else
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "$CURRENT_BRANCH" = "$TASK_BRANCH" ]; then
      check "preflight-task-branch" 0
    elif [ "$TASK_BRANCH" = "HEAD" ]; then
      check "preflight-task-branch" 0
    else
      check "preflight-task-branch" 1 "on branch '$CURRENT_BRANCH' but Task branch is '$TASK_BRANCH' — checkout the task branch before integrating"
    fi
  fi
}

# --- dispatch ----------------------------------------------------------------

if [ "$PREFLIGHT" = true ]; then
  gate_preflight
elif [ "$FROM" = "planning" ] && [ "$TO" = "executing" ]; then
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
