#!/usr/bin/env bash
set -euo pipefail

# Isolates work on a powerflow/<slug> branch when on a known base branch.
# Writes nothing to disk; the orchestrator records branch info in summary.md
# Git State (use --porcelain for machine-readable INTEGRATION_BASE/BASE_SHA/...).
#
# Three distinct fields (never conflated):
#   INTEGRATION_BASE — the branch work merges back into (the --porcelain
#     BASE_BRANCH for backward compat). Explicit --base-branch, else the
#     upstream of the current branch, else the repo default (origin/HEAD or
#     main/master), else FAIL asking for an explicit choice.
#   TASK_BASE_SHA — merge-base(INTEGRATION_BASE, HEAD) at isolate time: the
#     baseline the diff-scope check measures against (--porcelain BASE_SHA
#     for backward compat).
#   TASK_BRANCH — powerflow/<slug> when created, else the current branch.
#
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

# --base-branch names the INTEGRATION target (may differ from current branch).
# Empty means: resolve from upstream, else repo default, else fail.
if [ -n "$BASE_BRANCH_OVERRIDE" ]; then
  INTEGRATION_BASE="$BASE_BRANCH_OVERRIDE"
else
  INTEGRATION_BASE=""
  # 1. Upstream of the current branch (e.g. feature/foo tracking origin/main).
  UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -n "$UPSTREAM" ]; then
    # Strip remote prefix: origin/main -> main.
    INTEGRATION_BASE=$(printf '%s' "$UPSTREAM" | sed -E 's|^[^/]+/||')
  fi
  # 2. Repo default: origin/HEAD target, else main/master if present.
  if [ -z "$INTEGRATION_BASE" ]; then
    ORIGIN_HEAD=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed -E 's|^origin/||' || true)
    if [ -n "$ORIGIN_HEAD" ]; then
      INTEGRATION_BASE="$ORIGIN_HEAD"
    elif git show-ref --verify --quiet refs/heads/main; then
      INTEGRATION_BASE="main"
    elif git show-ref --verify --quiet refs/heads/master; then
      INTEGRATION_BASE="master"
    fi
  fi
  if [ -z "$INTEGRATION_BASE" ]; then
    echo "Error: cannot determine integration base (no upstream, no origin/HEAD, no main/master)." >&2
    echo "Re-run with an explicit --base-branch <branch>." >&2
    exit 1
  fi
fi

# The integration base must exist locally or as a remote-tracking ref.
if ! git show-ref --verify --quiet "refs/heads/$INTEGRATION_BASE" \
  && ! git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION_BASE"; then
  echo "Error: integration base '$INTEGRATION_BASE' not found (no refs/heads/$INTEGRATION_BASE or refs/remotes/origin/$INTEGRATION_BASE)" >&2
  exit 1
fi

# Check if current branch should be isolated to a powerflow/<slug> branch.
# The allowlist is only an isolate-vs-reuse heuristic for the CURRENT branch;
# it never decides the integration base.
SHOULD_ISOLATE=false
DECISION_SOURCE="allowlist"
if [ -n "$BASE_BRANCH_OVERRIDE" ]; then
  # Explicit base given: isolate unless already on the task branch itself.
  if [ "$CURRENT" != "powerflow/$TASK_SLUG" ]; then
    SHOULD_ISOLATE=true
    DECISION_SOURCE="--base-branch"
  fi
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

# Baseline: merge-base of integration target and HEAD at isolate time.
# (On a fresh base branch this equals HEAD; on an existing feature branch it
# is the fork point — never HEAD itself, so the diff-scope check stays sound.)
BASE_REF="$INTEGRATION_BASE"
if ! git show-ref --verify --quiet "refs/heads/$INTEGRATION_BASE" \
  && git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION_BASE"; then
  BASE_REF="origin/$INTEGRATION_BASE"
fi
BASE_SHA=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || {
  echo "Error: no merge base between HEAD and $BASE_REF — wrong integration base?" >&2
  exit 1
}

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
  echo "BASE_BRANCH=$INTEGRATION_BASE"
  echo "BASE_SHA=$BASE_SHA"
  echo "TASK_BRANCH=$TASK_BRANCH"
  echo "ACTION=$ACTION"
fi
