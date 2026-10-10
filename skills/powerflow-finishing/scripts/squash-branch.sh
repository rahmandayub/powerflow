#!/usr/bin/env bash
set -euo pipefail

# Squashes all commits on the current branch back to the base branch.
# Base is NEVER guessed: pass --base-branch explicitly or --task-dir so the
# base is read from <task-dir>/summary.md Git State (Base ref field preferred,
# Base branch as fallback for older summaries).
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

# Base resolution: explicit flag > summary.md Git State (Base ref, then Base
# branch) > fail. Never guess. Base ref is the exact ref recorded at isolate
# time (e.g. upstream/main); the short branch name alone is ambiguous when
# remotes share branch names.
BASE_REF=""
if [ -z "$BASE_BRANCH" ] && [ -n "$TASK_DIR" ]; then
  SUMMARY="$TASK_DIR/summary.md"
  if [ -f "$SUMMARY" ]; then
    BASE_REF=$(grep -E '^[*-][[:space:]]+Base ref:' "$SUMMARY" | head -n 1 | sed -E 's/^[*-][[:space:]]+Base ref:[[:space:]]*//; s/[[:space:]]*$//') || true
    BASE_BRANCH=$(grep -E '^[*-][[:space:]]+Base branch:' "$SUMMARY" | head -n 1 | sed -E 's/^[*-][[:space:]]+Base branch:[[:space:]]*//; s/[[:space:]]*$//') || true
    if [ -n "$BASE_REF" ]; then
      echo "Base ref from $SUMMARY: $BASE_REF" >&2
    elif [ -n "$BASE_BRANCH" ]; then
      echo "Base branch from $SUMMARY: $BASE_BRANCH (no Base ref recorded)" >&2
    fi
  else
    echo "Warning: task summary not found at $SUMMARY" >&2
  fi
fi

# Unified ref resolution for BOTH entry paths (--base-branch flag and
# --task-dir summary): a remote-qualified value (upstream/main) resolves to
# that exact remote ref; a short name prefers the local branch, then the
# first remote-tracking match. Squash only needs a merge-base, so remote
# refs are fine here (unlike checkout/merge in Finishing Section 6).
resolve_base_ref() { # resolve_base_ref <value> -> echoes ref or fails
  local v="$1" found
  # Remote-qualified values (upstream/main) must hit the remote ref, never a
  # same-named local branch.
  case "$v" in
    */*)
      if git show-ref --verify --quiet "refs/remotes/$v"; then
        printf '%s' "$v"
      elif git rev-parse --verify --quiet "$v" >/dev/null; then
        printf '%s' "$v"
      else
        return 1
      fi
      return 0
      ;;
  esac
  if git show-ref --verify --quiet "refs/heads/$v"; then
    printf '%s' "$v"
  elif git show-ref --verify --quiet "refs/remotes/$v"; then
    printf '%s' "$v"
  elif git rev-parse --verify --quiet "$v" >/dev/null; then
    printf '%s' "$v"
  else
    found=$(git for-each-ref --format='%(refname:short)' "refs/remotes/*/$v" | head -n 1 || true)
    if [ -n "$found" ]; then
      echo "Note: using remote-tracking base $found" >&2
      printf '%s' "$found"
    else
      return 1
    fi
  fi
}

if [ -n "$BASE_REF" ]; then
  # Exact ref from summary wins; verify it resolves.
  RESOLVED=$(resolve_base_ref "$BASE_REF") || {
    echo "Error: base ref '$BASE_REF' not found." >&2
    exit 1
  }
  BASE_REF="$RESOLVED"
else
  if [ -z "$BASE_BRANCH" ]; then
    echo "Error: base branch ambiguous. Pass --base-branch <branch> or --task-dir <dir>." >&2
    exit 1
  fi
  # Same resolver for the explicit flag (incl. remote-qualified values).
  BASE_REF=$(resolve_base_ref "$BASE_BRANCH") || {
    echo "Error: base branch '$BASE_BRANCH' not found (no local branch or remote-tracking ref)" >&2
    exit 1
  }
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

BASE_COMMIT=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || {
  echo "Error: no merge base with $BASE_REF (pass --base-branch <branch>)" >&2
  exit 1
}

COMMIT_COUNT=$(git rev-list --count "$BASE_COMMIT"..HEAD)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "No commits found between $BASE_REF ($BASE_COMMIT) and HEAD. Nothing to squash."
  exit 0
fi

echo "Found $COMMIT_COUNT commit(s) since $BASE_REF"

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
