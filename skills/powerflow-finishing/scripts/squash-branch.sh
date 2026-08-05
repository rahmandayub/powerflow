#!/usr/bin/env bash
set -euo pipefail

# Squashes all commits on the current branch back to the base branch.
# Usage:
#   squash-branch.sh --message "feat(task): summary" [--base-branch <branch>]
#   squash-branch.sh --uncommitted [--base-branch <branch>]

MESSAGE=""
UNCOMMITTED=false
BASE_BRANCH="main"

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

BASE_COMMIT=$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null) || {
  echo "Error: no merge base with $BASE_BRANCH (pass --base-branch)" >&2
  exit 1
}

echo "Found $(git rev-list --count "$BASE_COMMIT"..HEAD) commit(s) since $BASE_BRANCH"

git reset --soft "$BASE_COMMIT"

if [ "$UNCOMMITTED" = true ]; then
  echo "Changes are now staged as uncommitted changes."
else
  git commit -m "$MESSAGE"
  echo "Commits successfully squashed into a single commit."
fi
