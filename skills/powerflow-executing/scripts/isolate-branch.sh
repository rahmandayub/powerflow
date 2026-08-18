#!/usr/bin/env bash
set -euo pipefail

# Isolates work on a powerflow/<slug> branch when on a known base branch.
# Writes nothing to disk; the orchestrator records branch info in summary.md.
# Exit codes: 0 ready | 1 error | 2 detached HEAD

FORCE=false
BASE_BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) echo "Usage: isolate-branch.sh --task-slug <slug> [--base-branch <branch>] [--force]" >&2; exit 1 ;;
  esac
done

if [ -z "$TASK_SLUG" ]; then
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

# Check if current branch should be isolated to a powerflow/<slug> branch
SHOULD_ISOLATE=false
if [ -n "$BASE_BRANCH_OVERRIDE" ] && [ "$CURRENT" = "$BASE_BRANCH_OVERRIDE" ]; then
  SHOULD_ISOLATE=true
elif [ "$FORCE" = true ]; then
  SHOULD_ISOLATE=true
else
  case "$CURRENT" in
    main|master|develop|dev|staging|trunk|release/*)
      SHOULD_ISOLATE=true
      ;;
    *)
      SHOULD_ISOLATE=false
      ;;
  esac
fi

if [ "$SHOULD_ISOLATE" = true ]; then
  POWERFLOW_BRANCH="powerflow/$TASK_SLUG"
  if git show-ref --verify --quiet "refs/heads/$POWERFLOW_BRANCH"; then
    echo "Error: Branch $POWERFLOW_BRANCH already exists" >&2
    exit 1
  fi
  git checkout -b "$POWERFLOW_BRANCH"
  echo "Created branch $POWERFLOW_BRANCH from $CURRENT"
else
  echo "On existing branch '$CURRENT'. No isolation needed."
fi
