#!/usr/bin/env bash
set -euo pipefail

# Isolates work on a powerflow/<slug> branch when on a known base branch.
# Writes nothing to disk; the orchestrator records branch info in summary.md.
# Exit codes: 0 ready | 1 error | 2 detached HEAD

TASK_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    *) echo "Usage: isolate-branch.sh --task-slug <slug>" >&2; exit 1 ;;
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

case "$CURRENT" in
  main|master|develop)
    POWERFLOW_BRANCH="powerflow/$TASK_SLUG"
    if git show-ref --verify --quiet "refs/heads/$POWERFLOW_BRANCH"; then
      echo "Error: Branch $POWERFLOW_BRANCH already exists" >&2
      exit 1
    fi
    git checkout -b "$POWERFLOW_BRANCH"
    echo "Created branch $POWERFLOW_BRANCH from $CURRENT"
    ;;
  *)
    echo "On existing branch '$CURRENT'. No isolation needed."
    ;;
esac
