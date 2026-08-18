#!/usr/bin/env bash
set -euo pipefail

# Squashes all commits on the current branch back to the base branch.
# Usage:
#   squash-branch.sh --message "feat(task): summary" [--base-branch <branch>]
#   squash-branch.sh --uncommitted [--base-branch <branch>]

MESSAGE=""
UNCOMMITTED=false
BASE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) MESSAGE="$2"; shift 2 ;;
    --uncommitted) UNCOMMITTED=true; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    *) echo "Usage: squash-branch.sh [--message <msg>|--uncommitted] [--base-branch <branch>]" >&2; exit 1 ;;
  esac
done

if [ "$UNCOMMITTED" = false ] && [ -z "$MESSAGE" ]; then
  echo "Error: --message is required for squash mode (or use --uncommitted)" >&2
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
  echo "Error: Not in a git repository" >&2
  exit 1
}

# Auto-detect base branch if not explicitly provided
if [ -z "$BASE_BRANCH" ]; then
  for candidate in main master develop dev trunk; do
    if [ "$CURRENT_BRANCH" != "$candidate" ] && git show-ref --verify --quiet "refs/heads/$candidate"; then
      BASE_BRANCH="$candidate"
      echo "Auto-detected base branch: $BASE_BRANCH" >&2
      break
    fi
  done
fi

if [ -z "$BASE_BRANCH" ]; then
  echo "Error: Could not auto-detect base branch. Please specify --base-branch <branch>." >&2
  exit 1
fi

BASE_COMMIT=$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null) || {
  echo "Error: no merge base with $BASE_BRANCH (pass --base-branch <branch>)" >&2
  exit 1
}

COMMIT_COUNT=$(git rev-list --count "$BASE_COMMIT"..HEAD)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "No commits found between $BASE_BRANCH ($BASE_COMMIT) and HEAD. Nothing to squash."
  exit 0
fi

echo "Found $COMMIT_COUNT commit(s) since $BASE_BRANCH"

git reset --soft "$BASE_COMMIT"

if [ "$UNCOMMITTED" = true ]; then
  echo "Changes are now staged as uncommitted changes."
else
  git commit -m "$MESSAGE"
  echo "Commits successfully squashed into a single commit."
fi
