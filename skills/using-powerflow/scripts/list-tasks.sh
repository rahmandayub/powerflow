#!/usr/bin/env bash
set -euo pipefail

# Derived multi-task registry for Powerflow (read-only, writes nothing).
#
# Scans <main-root>/.powerflow/*/summary.md, reconciles each task with live
# git state (git worktree list + branch refs), evaluates depends_on readiness,
# and reports concurrency slots. There is no stored registry file: summary.md
# stays the per-task source of truth; this script computes the index on demand.
# Run it from anywhere inside the repo (main checkout or any task worktree) —
# the scan always targets the MAIN root's .powerflow/ (task state is gitignored
# and lives only there, never inside task worktrees).
#
# Declaring a dependency: add one line to summary.md (usually at Planning):
#   - Depends on: <slug-a>, <slug-b>
# Slugs are .powerflow/ dir basenames (date prefix included). Missing line,
# or a value of None/-/n/a, means independent. A dependency counts as complete
# when its summary reports ## Phase: Finishing (integration decision recorded).
#
# READINESS semantics: per-task DEPS_READY covers dependencies only. Whether a
# task may actually start also needs SLOT_AVAILABLE (global). --check-ready
# combines both into OVERALL. This gate never replaces the phase gates in
# validate-transition.sh — run those as usual.
#
# Usage:
#   list-tasks.sh [--porcelain] [--max-parallel N]
#   list-tasks.sh --check-ready <slug> [--porcelain] [--max-parallel N]
#
# --max-parallel defaults to $POWERFLOW_MAX_PARALLEL, else 2.
#
# Exit codes: 0 ok (check-ready: OVERALL ready) | 1 error |
#   2 usage, not a git repo, or task not found | 3 blocked (check-ready only)

PORCELAIN_OUT=false
CHECK_SLUG=""
MAX_PARALLEL="${POWERFLOW_MAX_PARALLEL:-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --porcelain) PORCELAIN_OUT=true; shift ;;
    --check-ready) CHECK_SLUG="${2:-}"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="${2:-}"; shift 2 ;;
    *) echo "Usage: list-tasks.sh [--porcelain] [--max-parallel N] | list-tasks.sh --check-ready <slug> [--porcelain] [--max-parallel N]" >&2; exit 2 ;;
  esac
done

if [ -n "$CHECK_SLUG" ]; then
  if [[ "$CHECK_SLUG" == *"/"* ]] || [[ "$CHECK_SLUG" == *".."* ]]; then
    echo "Error: invalid slug '$CHECK_SLUG'" >&2
    exit 2
  fi
fi

if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [ "$MAX_PARALLEL" -lt 1 ]; then
  echo "Error: --max-parallel must be a positive integer (got '$MAX_PARALLEL')" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 2
fi

# Main root = first worktree listed (stable from main checkout and from any
# linked worktree, unlike --show-toplevel which returns the current wt).
MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}')
if [ -z "$MAIN_ROOT" ]; then
  echo "Error: cannot resolve repository root (git worktree list failed)" >&2
  exit 1
fi
PF_DIR="$MAIN_ROOT/.powerflow"

field_of() { # field_of <summary> <label> -> value or empty
  grep -Ei -m1 "^[*-][[:space:]]+$2:" "$1" 2>/dev/null \
    | sed -E "s/^[*-][[:space:]]+$2:[[:space:]]*//I; s/[[:space:]]*$//" || true
}

phase_of() { # phase_of <summary> -> Brainstorming|Planning|...|unknown
  local line ph
  line=$(grep -Ei -m1 '^## Phase:' "$1" 2>/dev/null || true)
  if [ -z "$line" ]; then
    printf 'unknown'
    return 0
  fi
  ph=$(printf '%s' "$line" | sed -E 's/^## Phase:[[:space:]]*([A-Za-z]+).*/\1/I')
  case "$ph" in
    Brainstorming|Planning|Executing|Debugging|Finishing) printf '%s' "$ph" ;;
    *) printf 'unknown' ;;
  esac
}

dep_complete() { # dep_complete <slug> -> 0 if that task reached Finishing
  local dep_summary dep_phase
  dep_summary="$PF_DIR/$1/summary.md"
  [ -f "$dep_summary" ] || return 1
  dep_phase=$(phase_of "$dep_summary")
  [ "$dep_phase" = "Finishing" ]
}

# Per-task globals set by describe_task:
D_PHASE=""; D_BRANCH=""; D_WT_PATH=""; D_BASE_REF=""; D_BASE_SHA=""
D_DEPENDS=""; D_WT_STATUS=""; D_BRANCH_STATUS=""; D_BASE_STATUS=""
D_BLOCKED_BY=""; D_DEPS_READY=""; D_HOLDS=""

describe_task() { # describe_task <slug> — sets D_* vars
  local slug="$1" summary raw dep norm blocked holds
  summary="$PF_DIR/$slug/summary.md"
  D_PHASE="unknown"; D_BRANCH=""; D_WT_PATH=""
  D_BASE_REF=""; D_BASE_SHA=""; D_DEPENDS="none"
  D_WT_STATUS="in-place"; D_BRANCH_STATUS="none"; D_BASE_STATUS="none"
  D_BLOCKED_BY="none"; D_DEPS_READY="no"; D_HOLDS="no"

  if [ ! -f "$summary" ]; then
    D_BLOCKED_BY="missing-summary"
    return 0
  fi

  D_PHASE=$(phase_of "$summary")
  D_BRANCH=$(field_of "$summary" "Task branch")
  D_WT_PATH=$(field_of "$summary" "Worktree path")
  D_BASE_REF=$(field_of "$summary" "Base ref")
  [ -n "$D_BASE_REF" ] || D_BASE_REF=$(field_of "$summary" "Base branch")
  D_BASE_SHA=$(field_of "$summary" "Base SHA")

  # Worktree reconciliation (recorded path vs live registration).
  if [ -n "$D_WT_PATH" ]; then
    if git worktree list --porcelain 2>/dev/null | grep -qx "worktree $D_WT_PATH"; then
      D_WT_STATUS="active"
    else
      D_WT_STATUS="missing"
    fi
  else
    D_WT_STATUS="in-place"
  fi

  # Branch reconciliation.
  if [ -n "$D_BRANCH" ] && [ "$D_BRANCH" != "HEAD" ]; then
    if git show-ref --verify --quiet "refs/heads/$D_BRANCH" 2>/dev/null; then
      D_BRANCH_STATUS="exists"
    else
      D_BRANCH_STATUS="missing"
    fi
  fi

  # Base freshness (advisory for the Tahap 3 integration queue).
  if [ -n "$D_BASE_SHA" ] && [ -n "$D_BASE_REF" ]; then
    local base_head
    if ! git cat-file -e "${D_BASE_SHA}^{commit}" 2>/dev/null; then
      D_BASE_STATUS="unknown"
    else
      base_head=$(git rev-parse --verify --quiet "$D_BASE_REF" 2>/dev/null || true)
      if [ -z "$base_head" ]; then
        D_BASE_STATUS="unknown"
      elif [ "$D_BASE_SHA" = "$base_head" ]; then
        D_BASE_STATUS="current"
      elif git merge-base --is-ancestor "$D_BASE_SHA" "$base_head" 2>/dev/null; then
        D_BASE_STATUS="stale"
      else
        D_BASE_STATUS="diverged"
      fi
    fi
  fi

  # Dependency evaluation.
  raw=$(field_of "$summary" "Depends on")
  if [ -z "$raw" ]; then
    D_DEPENDS="none"
    D_DEPS_READY="yes"
    D_BLOCKED_BY="none"
  else
    norm=$(printf '%s' "$raw" | tr ',' ' ')
    case "$norm" in
      [Nn][Oo][Nn][Ee]|"-"|"[Nn]/[Aa]"|"n/a"|"N/A") norm="" ;;
    esac
    if [ -z "$(printf '%s' "$norm" | tr -d '[:space:]')" ]; then
      D_DEPENDS="none"
      D_DEPS_READY="yes"
      D_BLOCKED_BY="none"
    else
      D_DEPENDS=$(printf '%s' "$norm" | tr -s '[:space:]' ',' | sed -E 's/^,+//; s/,+$//; s/,+/,/g')
      blocked=""
      for dep in $(printf '%s' "$norm"); do
        if [ "$dep" = "$slug" ]; then
          blocked="${blocked:+$blocked,}$dep"
        elif [ ! -d "$PF_DIR/$dep" ]; then
          blocked="${blocked:+$blocked,}$dep"
        elif ! dep_complete "$dep"; then
          blocked="${blocked:+$blocked,}$dep"
        fi
      done
      if [ -z "$blocked" ]; then
        D_DEPS_READY="yes"
        D_BLOCKED_BY="none"
      else
        D_DEPS_READY="no"
        D_BLOCKED_BY="$blocked"
      fi
    fi
  fi

  # Resource holder: occupies a concurrency slot while it owns a live
  # worktree or an existing branch.
  holds="no"
  if [ "$D_WT_STATUS" = "active" ] || [ "$D_BRANCH_STATUS" = "exists" ]; then
    holds="yes"
  fi
  D_HOLDS="$holds"
}

# Collect slugs (sorted basenames of .powerflow/*/).
SLUGS=""
if [ -d "$PF_DIR" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && SLUGS="${SLUGS:+$SLUGS
}$(basename "$d")"
  done < <(for d in "$PF_DIR"/*/; do [ -d "$d" ] && printf '%s\n' "$d"; done | sort)
fi
TOTAL=0
[ -z "$SLUGS" ] || TOTAL=$(printf '%s\n' "$SLUGS" | grep -c . || true)

if [ -n "$CHECK_SLUG" ]; then
  if ! printf '%s\n' "$SLUGS" | grep -qx "$CHECK_SLUG"; then
    echo "Error: task '$CHECK_SLUG' not found under $PF_DIR" >&2
    exit 2
  fi
fi

# Holding counts are computed on demand via holding_count() below
# (describe_task uses D_* globals; no caching — N is small).

holding_count() { # holding_count [exclude-slug] -> number
  local excl="${1:-}" n=0 s
  [ -z "$SLUGS" ] && { printf '0'; return 0; }
  while IFS= read -r s; do
    [ -n "$excl" ] && [ "$s" = "$excl" ] && continue
    describe_task "$s"
    [ "$D_HOLDS" = "yes" ] && n=$((n + 1))
  done < <(printf '%s\n' "$SLUGS")
  printf '%s' "$n"
}

print_task_porcelain() { # print_task_porcelain <slug>
  local s="$1"
  describe_task "$s"
  printf 'TASK=%s\n' "$s"
  printf 'PHASE=%s\n' "$D_PHASE"
  printf 'TASK_BRANCH=%s\n' "${D_BRANCH:-none}"
  printf 'WORKTREE_PATH=%s\n' "${D_WT_PATH:-none}"
  printf 'WT_STATUS=%s\n' "$D_WT_STATUS"
  printf 'BRANCH_STATUS=%s\n' "$D_BRANCH_STATUS"
  printf 'BASE_STATUS=%s\n' "$D_BASE_STATUS"
  printf 'DEPENDS_ON=%s\n' "$D_DEPENDS"
  printf 'BLOCKED_BY=%s\n' "$D_BLOCKED_BY"
  printf 'DEPS_READY=%s\n' "$D_DEPS_READY"
}

if [ -n "$CHECK_SLUG" ]; then
  HOLDING=$(holding_count "$CHECK_SLUG")
  describe_task "$CHECK_SLUG"
  SELF_HOLDS="$D_HOLDS"
  if [ "$HOLDING" -ge "$MAX_PARALLEL" ]; then
    SLOT="no"
  else
    SLOT="yes"
  fi
  OVERALL="ready"
  REASON="none"
  if [ "$D_DEPS_READY" = "no" ]; then
    OVERALL="blocked"
    REASON="deps:$D_BLOCKED_BY"
  fi
  if [ "$SLOT" = "no" ]; then
    OVERALL="blocked"
    if [ "$REASON" = "none" ]; then
      REASON="slots:full ($HOLDING>=$MAX_PARALLEL)"
    else
      REASON="$REASON; slots:full ($HOLDING>=$MAX_PARALLEL)"
    fi
  fi
  if [ "$D_PHASE" = "unknown" ] && [ "$D_BLOCKED_BY" = "missing-summary" ]; then
    OVERALL="blocked"
    REASON="missing-summary (no summary.md yet — finish Brainstorming first)"
  fi

  if [ "$PORCELAIN_OUT" = true ]; then
    print_task_porcelain "$CHECK_SLUG"
    printf 'MAX_PARALLEL=%s\n' "$MAX_PARALLEL"
    printf 'HOLDING_RESOURCES=%s\n' "$((HOLDING + $([ "$SELF_HOLDS" = "yes" ] && printf '1' || printf '0')))"
    printf 'SLOT_AVAILABLE=%s\n' "$SLOT"
    printf 'OVERALL=%s\n' "$OVERALL"
    printf 'BLOCK_REASON=%s\n' "$REASON"
  else
    printf 'Task: %s\n' "$CHECK_SLUG"
    printf '  Phase: %s | Branch: %s (%s) | Worktree: %s\n' \
      "$D_PHASE" "${D_BRANCH:-none}" "$D_BRANCH_STATUS" "${D_WT_PATH:-in-place} [$D_WT_STATUS]"
    printf '  Depends on: %s | Blocked by: %s | Deps ready: %s\n' \
      "$D_DEPENDS" "$D_BLOCKED_BY" "$D_DEPS_READY"
    printf '  Slots: holding %s (max %s) -> available: %s\n' "$HOLDING" "$MAX_PARALLEL" "$SLOT"
    printf '  OVERALL: %s' "$OVERALL"
    [ "$REASON" != "none" ] && printf ' (%s)' "$REASON"
    printf '\n'
  fi
  if [ "$OVERALL" = "ready" ]; then
    exit 0
  else
    exit 3
  fi
fi

# List mode.
HOLDING=$(holding_count)
if [ "$HOLDING" -ge "$MAX_PARALLEL" ]; then
  SLOT_ALL="no"
else
  SLOT_ALL="yes"
fi

if [ "$PORCELAIN_OUT" = true ]; then
  if [ -n "$SLUGS" ]; then
    while IFS= read -r s; do
      print_task_porcelain "$s"
      printf '\n'
    done < <(printf '%s\n' "$SLUGS")
  fi
  printf 'TOTAL_TASKS=%s\n' "$TOTAL"
  printf 'HOLDING_RESOURCES=%s\n' "$HOLDING"
  printf 'MAX_PARALLEL=%s\n' "$MAX_PARALLEL"
  printf 'SLOT_AVAILABLE=%s\n' "$SLOT_ALL"
else
  if [ "$TOTAL" -eq 0 ]; then
    printf 'No Powerflow tasks under %s.\n' "$PF_DIR"
  else
    printf '%-38s %-12s %-26s %-9s %-9s %-8s %s\n' "SLUG" "PHASE" "BRANCH" "WT" "BASE" "DEPS" "READY"
    while IFS= read -r s; do
      describe_task "$s"
      short_branch="${D_BRANCH:-none}"
      if [ ${#short_branch} -gt 26 ]; then
        short_branch="...${short_branch: -23}"
      fi
      if [ "$D_DEPS_READY" = "yes" ]; then
        ready="ready"
      else
        ready="blocked"
      fi
      printf '%-38s %-12s %-26s %-9s %-9s %-8s %s\n' \
        "$s" "$D_PHASE" "$short_branch" "$D_WT_STATUS" "$D_BASE_STATUS" "$D_DEPENDS" "$ready"
    done < <(printf '%s\n' "$SLUGS")
  fi
  printf 'Tasks: %s total, %s holding worktree/branch; slots: max %s -> available: %s\n' \
    "$TOTAL" "$HOLDING" "$MAX_PARALLEL" "$SLOT_ALL"
fi
exit 0
