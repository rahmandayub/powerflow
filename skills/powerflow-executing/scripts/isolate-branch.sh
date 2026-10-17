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
#
# Worktree mode (--worktree-path <path> [--base-sha <sha>]):
#   Creates an isolated worktree holding powerflow/<slug> instead of switching
#   the current checkout. The current branch is left untouched, so N tasks can
#   run in parallel from the same base. Porcelain additionally emits
#   WORKTREE_PATH=<absolute path>.
#   - Dirty tree in the current checkout does NOT block: the new worktree is
#     clean by construction; uncommitted changes stay behind (noted on stderr).
#   - Detached HEAD does NOT block either: the worktree is created from HEAD
#     (or --base-sha when given) plus the resolved integration base.
#   - Re-running with the same slug+path while that worktree already holds the
#     task branch resumes (ACTION=reused); any other collision is exit 1.

FORCE=false
BASE_BRANCH_OVERRIDE=""
ALLOW_DIRTY=false
PORCELAIN_OUT=false
WORKTREE_PATH_ARG=""
BASE_SHA_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --base-sha) BASE_SHA_OVERRIDE="$2"; shift 2 ;;
    --worktree-path) WORKTREE_PATH_ARG="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --porcelain) PORCELAIN_OUT=true; shift ;;
    *) echo "Usage: isolate-branch.sh --task-slug <slug> [--base-branch <branch>] [--base-sha <sha>] [--worktree-path <path>] [--force] [--allow-dirty] [--porcelain]" >&2; exit 1 ;;
  esac
done

if [ -z "${TASK_SLUG:-}" ]; then
  echo "Error: --task-slug is required" >&2
  exit 1
fi

# Slug validation (mirrors init-task-dir.sh): the slug becomes powerflow/<slug>
# and --worktree-path defaults derive from it, so reject traversal and
# shell-hostile characters before touching git state.
if [[ "$TASK_SLUG" == *"/"* ]] || [[ "$TASK_SLUG" == *\\* ]] \
  || [[ "$TASK_SLUG" == *".."* ]] || [[ "$TASK_SLUG" =~ [[:space:]] ]] \
  || [[ "$TASK_SLUG" =~ [\'\"\;\|\&\$\`\(\)\!\*\?\<\>] ]]; then
  echo "Error: invalid --task-slug '$TASK_SLUG' (no /, \\\\, .., whitespace, or shell metacharacters)" >&2
  exit 1
fi
if [[ "$TASK_SLUG" == -* ]] || [[ "$TASK_SLUG" == .* ]]; then
  echo "Error: invalid --task-slug '$TASK_SLUG' (must not start with - or .)" >&2
  exit 1
fi

if [ -n "$WORKTREE_PATH_ARG" ] && [ -n "$BASE_SHA_OVERRIDE" ]; then
  if ! git cat-file -e "${BASE_SHA_OVERRIDE}^{commit}" 2>/dev/null; then
    echo "Error: --base-sha '$BASE_SHA_OVERRIDE' is not an existing commit" >&2
    exit 1
  fi
fi

WORKTREE_MODE=false
if [ -n "$WORKTREE_PATH_ARG" ]; then
  WORKTREE_MODE=true
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
  echo "Error: Not in a git repository" >&2
  exit 1
}

if [ "$WORKTREE_MODE" = false ]; then
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
fi

# --base-branch names the INTEGRATION target (may differ from current branch).
# Empty means: resolve from upstream, else repo default, else fail.
# Remote identity is preserved end-to-end: BASE_REF keeps the full
# <remote>/<branch> form when the base comes from an upstream or exists only
# as a remote-tracking ref, so BASE_SHA is always computed from the exact ref
# chosen (critical with multiple remotes whose branches share a name).
# --porcelain emits the short BASE_BRANCH (summary.md "Base branch", kept for
# compat) plus the exact BASE_REF (summary.md "Base ref", e.g. upstream/main).
# Downstream tools (squash, Finishing) must prefer Base ref: the short name
# alone is ambiguous when remotes share branch names.
if [ -n "$BASE_BRANCH_OVERRIDE" ]; then
  INTEGRATION_BASE="$BASE_BRANCH_OVERRIDE"
  BASE_REF="$BASE_BRANCH_OVERRIDE"
else
  INTEGRATION_BASE=""
  BASE_REF=""
  # 1. Upstream of the current branch, kept as full ref (e.g. upstream/main).
  UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -n "$UPSTREAM" ]; then
    UPSTREAM_SHORT=$(printf '%s' "$UPSTREAM" | sed -E 's|^[^/]+/||')
    if [ "$UPSTREAM_SHORT" = "$CURRENT" ]; then
      echo "Note: upstream $UPSTREAM tracks this branch itself - not an integration target; falling back to repo default." >&2
    else
      INTEGRATION_BASE="$UPSTREAM_SHORT"
      BASE_REF="$UPSTREAM"
    fi
  fi
  # 2. Repo default: origin/HEAD target, else main/master if present.
  if [ -z "$INTEGRATION_BASE" ]; then
    ORIGIN_HEAD=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed -E 's|^origin/||' || true)
    if [ -n "$ORIGIN_HEAD" ]; then
      INTEGRATION_BASE="$ORIGIN_HEAD"
      BASE_REF="origin/$ORIGIN_HEAD"
    elif git show-ref --verify --quiet refs/heads/main; then
      INTEGRATION_BASE="main"
      BASE_REF="main"
    elif git show-ref --verify --quiet refs/heads/master; then
      INTEGRATION_BASE="master"
      BASE_REF="master"
    fi
  fi
  if [ -z "$INTEGRATION_BASE" ]; then
    echo "Error: cannot determine integration base (no upstream, no origin/HEAD, no main/master)." >&2
    echo "Re-run with an explicit --base-branch <branch>." >&2
    exit 1
  fi
fi

# The integration base must exist: as the exact ref, locally, or on any remote.
if git show-ref --verify --quiet "refs/heads/$INTEGRATION_BASE"; then
  if [ -z "${BASE_REF:-}" ]; then
    BASE_REF="$INTEGRATION_BASE"
  fi
elif [ -n "${BASE_REF:-}" ] && git show-ref --verify --quiet "refs/remotes/$BASE_REF"; then
  :
elif git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION_BASE"; then
  BASE_REF="origin/$INTEGRATION_BASE"
else
  echo "Error: integration base '$INTEGRATION_BASE' not found (no local branch or remote-tracking ref)" >&2
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
# BASE_REF already holds the exact ref resolved above; BASE_SHA comes from it.
# With --base-sha the baseline is explicit (the worktree starts exactly there).
if [ -n "$BASE_SHA_OVERRIDE" ]; then
  BASE_SHA="$BASE_SHA_OVERRIDE"
else
  BASE_SHA=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || {
    echo "Error: no merge base between HEAD and $BASE_REF — wrong integration base?" >&2
    exit 1
  }
fi

# --- worktree mode: isolated checkout per task, current branch untouched ------
if [ "$WORKTREE_MODE" = true ]; then
  POWERFLOW_BRANCH="powerflow/$TASK_SLUG"

  # Main repo root = first worktree listed (stable in main checkout and in any
  # linked worktree, unlike --show-toplevel which returns the current wt).
  MAIN_ROOT=$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
  if [ -z "$MAIN_ROOT" ]; then
    MAIN_ROOT=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/..
    MAIN_ROOT=$(cd "$MAIN_ROOT" 2>/dev/null && pwd -P) || {
      echo "Error: cannot resolve repository root for worktree placement" >&2
      exit 1
    }
  fi

  # Resolve the worktree path: .worktrees/<x> and worktrees/<x> are relative to
  # the main root (so every parallel agent agrees); anything else is relative
  # to the caller's cwd. realpath -m canonicalises without requiring existence.
  case "$WORKTREE_PATH_ARG" in
    /*) ABS_WT=$(realpath -m "$WORKTREE_PATH_ARG") ;;
    .worktrees/*|worktrees/*|./.worktrees/*|./worktrees/*)
      CLEAN=${WORKTREE_PATH_ARG#./}
      ABS_WT=$(realpath -m "$MAIN_ROOT/$CLEAN") ;;
    *) ABS_WT=$(realpath -m "$PWD/$WORKTREE_PATH_ARG") ;;
  esac

  # Safety: never take the repo root itself, .git internals, or task state.
  if [ "$ABS_WT" = "$MAIN_ROOT" ]; then
    echo "Error: worktree path must not be the repository root" >&2
    exit 1
  fi
  case "$ABS_WT" in
    "$MAIN_ROOT/.git"|"$MAIN_ROOT/.git/"*) echo "Error: worktree path must not be inside .git" >&2; exit 1 ;;
    "$MAIN_ROOT/.powerflow"|"$MAIN_ROOT/.powerflow/"*) echo "Error: worktree path must not be inside .powerflow/" >&2; exit 1 ;;
  esac

  # Resume: same path already registered AND already on the task branch.
  if git worktree list --porcelain | grep -qx "worktree $ABS_WT"; then
    WT_BRANCH=$(git -C "$ABS_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
    if [ "$WT_BRANCH" = "$POWERFLOW_BRANCH" ]; then
      echo "Reusing worktree $ABS_WT on $POWERFLOW_BRANCH (resume)." >&2
      TASK_BRANCH="$POWERFLOW_BRANCH"
      ACTION="reused"
      if [ "$PORCELAIN_OUT" = true ]; then
        echo "BASE_BRANCH=$INTEGRATION_BASE"
        echo "BASE_REF=$BASE_REF"
        echo "BASE_SHA=$BASE_SHA"
        echo "TASK_BRANCH=$TASK_BRANCH"
        echo "ACTION=$ACTION"
        echo "WORKTREE_PATH=$ABS_WT"
      fi
      exit 0
    fi
    echo "Error: worktree path $ABS_WT already registered for another branch ($WT_BRANCH)" >&2
    exit 1
  fi
  if [ -e "$ABS_WT" ]; then
    echo "Error: worktree path $ABS_WT already exists on disk" >&2
    exit 1
  fi
  if git show-ref --verify --quiet "refs/heads/$POWERFLOW_BRANCH"; then
    echo "Error: Branch $POWERFLOW_BRANCH already exists" >&2
    exit 1
  fi

  # Start point mirrors branch mode (HEAD) unless --base-sha pins it.
  # Uncommitted changes in the current checkout stay behind by design.
  if [ -n "$BASE_SHA_OVERRIDE" ]; then
    START_POINT="$BASE_SHA_OVERRIDE"
  else
    START_POINT=$(git rev-parse HEAD) || {
      echo "Error: cannot resolve HEAD as worktree start point" >&2
      exit 1
    }
    PORCELAIN_DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' | grep -v '^ *$' || true)
    if [ -n "$PORCELAIN_DIRTY" ]; then
      echo "Note: dirty tree in current checkout stays behind; new worktree starts clean at ${START_POINT:0:7}." >&2
    fi
  fi

  if ! git worktree add -b "$POWERFLOW_BRANCH" "$ABS_WT" "$START_POINT" >&2; then
    echo "Error: failed to create worktree at $ABS_WT" >&2
    exit 1
  fi
  echo "Created worktree $ABS_WT on $POWERFLOW_BRANCH from ${START_POINT:0:7} (base $INTEGRATION_BASE @ ${BASE_SHA:0:7})" >&2
  TASK_BRANCH="$POWERFLOW_BRANCH"
  ACTION="created"
  if [ "$PORCELAIN_OUT" = true ]; then
    echo "BASE_BRANCH=$INTEGRATION_BASE"
    echo "BASE_REF=$BASE_REF"
    echo "BASE_SHA=$BASE_SHA"
    echo "TASK_BRANCH=$TASK_BRANCH"
    echo "ACTION=$ACTION"
    echo "WORKTREE_PATH=$ABS_WT"
  fi
  exit 0
fi

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
  # Reused branch: continuing directly on existing work. Guard against a
  # self-merge recording (base == task branch would make BASE_SHA == HEAD
  # and the diff-scope check vacuous).
  if [ "$INTEGRATION_BASE" = "$CURRENT" ]; then
    echo "Error: integration base '$INTEGRATION_BASE' is the current branch itself — continuing here would record a self-merge baseline." >&2
    echo "Pass the real merge target explicitly: --base-branch <branch>." >&2
    exit 1
  fi
  echo "On existing branch '$CURRENT'. No isolation needed."
  echo "Continuing directly on '$CURRENT': it is the TASK branch; the recorded Base branch stays the integration target." >&2
  TASK_BRANCH="$CURRENT"
  ACTION="reused"
fi

if [ "$PORCELAIN_OUT" = true ]; then
  echo "BASE_BRANCH=$INTEGRATION_BASE"
  echo "BASE_REF=$BASE_REF"
  echo "BASE_SHA=$BASE_SHA"
  echo "TASK_BRANCH=$TASK_BRANCH"
  echo "ACTION=$ACTION"
fi
