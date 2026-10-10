#!/usr/bin/env bash
set -euo pipefail

# Squashes all commits on the current branch back to the base branch.
# Base is NEVER guessed: pass --base-branch explicitly or --task-dir so the
# base is read from <task-dir>/summary.md Git State (Base branch field).
# Usage:
#   squash-branch.sh --message "feat(task): summary" (--base-branch <branch> | --task-dir <dir>) [--allow-dirty]
#   squash-branch.sh --uncommitted (--base-branch <branch> | --task-dir <dir>) [--allow-dirty]
#
# Exit codes: 0 success / nothing to do | 1 usage, unknown ref, no merge-base,
#   or ambiguous base | 2 detached HEAD | 4 dirty working tree

MESSAGE=""
UNCOMMITTED=false
BASE_BRANCH=""
TASK_DIR=""
ALLOW_DIRTY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) MESSAGE="$2"; shift 2 ;;
    --uncommitted) UNCOMMITTED=true; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --task-dir) TASK_DIR="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    *) echo "Usage: squash-branch.sh [--message <msg>|--uncommitted] [--base-branch <branch>|--task-dir <dir>] [--allow-dirty]" >&2; exit 1 ;;
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

# Detached HEAD guard — refuse before any base logic.
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "WARNING: Detached HEAD at $(git rev-parse --short HEAD). Refusing to squash without a branch." >&2
  exit 2
fi

# Base resolution: explicit flag > summary.md Git State > fail. Never guess.
if [ -z "$BASE_BRANCH" ] && [ -n "$TASK_DIR" ]; then
  SUMMARY="$TASK_DIR/summary.md"
  if [ -f "$SUMMARY" ]; then
    BASE_BRANCH=$(grep -E '^[*-][[:space:]]+Base branch:' "$SUMMARY" | head -n 1 | sed -E 's/^[*-][[:space:]]+Base branch:[[:space:]]*//; s/[[:space:]]*$//') || true
    if [ -n "$BASE_BRANCH" ]; then
      echo "Base branch from $SUMMARY: $BASE_BRANCH" >&2
    fi
  else
    echo "Warning: task summary not found at $SUMMARY" >&2
  fi
fi

if [ -z "$BASE_BRANCH" ]; then
  echo "Error: base branch ambiguous. Pass --base-branch <branch> or --task-dir <dir>." >&2
  exit 1
fi

# Verify the base ref exists locally or on origin.
if git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
  :
elif git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
  echo "Note: using remote-tracking base origin/$BASE_BRANCH" >&2
else
  echo "Error: base branch '$BASE_BRANCH' not found (no refs/heads/$BASE_BRANCH or refs/remotes/origin/$BASE_BRANCH)" >&2
  exit 1
fi

# Dirty-tree guard — tracked staged/unstaged changes block the reset.
# git reset --soft keeps index+worktree: staged changes WOULD join the squash
# commit, unstaged changes stay unstaged. Both make the result unpredictable.
PORCELAIN=$(git status --porcelain)
TRACKED_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -v '^??' | grep -v '^ *$' || true)
UNTRACKED=$(printf '%s\n' "$PORCELAIN" | grep '^??' || true)
STAGED=$(git diff --cached --name-only || true)

if [ -n "$TRACKED_DIRTY" ]; then
  if [ "$ALLOW_DIRTY" = true ]; then
    echo "WARNING: proceeding with dirty tree (--allow-dirty)." >&2
    if [ -n "$STAGED" ]; then
      echo "WARNING: staged changes WILL be included in the squash commit:" >&2
      printf '%s\n' "$STAGED" >&2
    fi
  else
    echo "Error: dirty working tree. Commit, stash, or re-run with --allow-dirty." >&2
    if [ -n "$STAGED" ]; then
      echo "Staged changes (would join the squash commit):" >&2
      printf '%s\n' "$STAGED" >&2
    fi
    echo "--- git status --short ---" >&2
    printf '%s\n' "$PORCELAIN" >&2
    exit 4
  fi
elif [ -n "$UNTRACKED" ]; then
  echo "Note: untracked files present (not included in squash):" >&2
  printf '%s\n' "$UNTRACKED" >&2
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

PRE_SQUASH_HEAD=$(git rev-parse HEAD)
echo "Pre-squash HEAD: $PRE_SQUASH_HEAD" >&2
echo "Recover with: git reset --soft $PRE_SQUASH_HEAD" >&2

git reset --soft "$BASE_COMMIT"

if [ "$UNCOMMITTED" = true ]; then
  echo "Changes are now staged as uncommitted changes."
else
  git commit -m "$MESSAGE"
  echo "Commits successfully squashed into a single commit."
fi
