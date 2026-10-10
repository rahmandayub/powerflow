#!/usr/bin/env bash
set -euo pipefail

# Isolates work on a powerflow/<slug> branch when on a known base branch.
# Writes nothing to disk; the orchestrator records branch info in summary.md
# Git State (use --porcelain for machine-readable BASE_BRANCH/BASE_SHA/...).
# This script never guesses a base: --base-branch must equal the current branch
# or it is an error; the hardcoded list is only an isolate-vs-reuse heuristic.
# Exit codes: 0 ready | 1 error | 2 detached HEAD | 4 dirty working tree

FORCE=false
BASE_BRANCH_OVERRIDE=""
ALLOW_DIRTY=false
PORCELAIN_OUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --porcelain) PORCELAIN_OUT=true; shift ;;
    *) echo "Usage: isolate-branch.sh --task-slug <slug> [--base-branch <branch>] [--force] [--allow-dirty] [--porcelain]" >&2; exit 1 ;;
  esac
done

if [ -z "${TASK_SLUG:-}" ]; then
  echo "Error: --task-slug is required" >&2
  exit 1
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
  echo "Error: Not in a git repository" >&2
  exit 1
}

if [ -z "$CURRENT" ] || [ "$CURRENT" = "HEAD" ]; then
  echo "WARNING: Detached HEAD at $(git rev-parse --short HEAD)" >&2
  exit 2
fi

# Dirty-tree guard: tracked staged/unstaged changes block branch creation.
PORCELAIN=$(git status --porcelain)
TRACKED_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -v '^??' | grep -v '^ *$' || true)
if [ -n "$TRACKED_DIRTY" ]; then
  if [ "$ALLOW_DIRTY" = true ]; then
    echo "WARNING: proceeding with dirty tree (--allow-dirty)." >&2
  else
    echo "Error: dirty working tree. Commit, stash, or re-run with --allow-dirty." >&2
    echo "--- git status --short ---" >&2
    printf '%s\n' "$PORCELAIN" >&2
    exit 4
  fi
fi

# --base-branch override must name the branch we are actually on.
if [ -n "$BASE_BRANCH_OVERRIDE" ] && [ "$BASE_BRANCH_OVERRIDE" != "$CURRENT" ]; then
  echo "Error: --base-branch '$BASE_BRANCH_OVERRIDE' does not match current branch '$CURRENT'" >&2
  exit 1
fi

# Check if current branch should be isolated to a powerflow/<slug> branch
SHOULD_ISOLATE=false
DECISION_SOURCE="allowlist"
if [ -n "$BASE_BRANCH_OVERRIDE" ] && [ "$CURRENT" = "$BASE_BRANCH_OVERRIDE" ]; then
  SHOULD_ISOLATE=true
  DECISION_SOURCE="--base-branch"
elif [ "$FORCE" = true ]; then
  SHOULD_ISOLATE=true
  DECISION_SOURCE="--force"
else
  case "$CURRENT" in
    main|master|develop|dev|staging|trunk|release/*)
      SHOULD_ISOLATE=true
      DECISION_SOURCE="allowlist"
      ;;
    *)
      SHOULD_ISOLATE=false
      ;;
  esac
fi

BASE_SHA=$(git rev-parse HEAD)

if [ "$SHOULD_ISOLATE" = true ]; then
  POWERFLOW_BRANCH="powerflow/$TASK_SLUG"
  if git show-ref --verify --quiet "refs/heads/$POWERFLOW_BRANCH"; then
    echo "Error: Branch $POWERFLOW_BRANCH already exists" >&2
    exit 1
  fi
  git checkout -b "$POWERFLOW_BRANCH"
  echo "Created branch $POWERFLOW_BRANCH from $CURRENT (decision: $DECISION_SOURCE)" >&2
  TASK_BRANCH="$POWERFLOW_BRANCH"
  ACTION="created"
else
  echo "On existing branch '$CURRENT'. No isolation needed."
  TASK_BRANCH="$CURRENT"
  ACTION="reused"
fi

if [ "$PORCELAIN_OUT" = true ]; then
  echo "BASE_BRANCH=$CURRENT"
  echo "BASE_SHA=$BASE_SHA"
  echo "TASK_BRANCH=$TASK_BRANCH"
  echo "ACTION=$ACTION"
fi
