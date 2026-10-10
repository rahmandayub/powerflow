#!/usr/bin/env bash
set -euo pipefail

# Resolves the LOCAL integration branch for a Powerflow merge/discard op.
# A remote-tracking Base ref (origin/main, upstream/main) must NEVER be
# checked out directly: that detaches HEAD, and the merge would land on a
# nameless checkout instead of the integration branch (losing the result when
# the task branch is deleted).
#
# Usage:
#   resolve-integration-branch.sh (--base-ref <ref> [--base-branch <name>] | --task-dir <dir>)
#
# Rules (in order):
#   1. If the ref resolves to a LOCAL branch, that branch is the answer.
#   2. If it is a remote-tracking ref <remote>/<branch> and a local <branch>
#      exists tracking that same remote ref, the local branch is the answer.
#   3. If it is a remote-tracking ref and no local branch tracks it, FAIL
#      (exit 3): the orchestrator must create or choose a local integration
#      branch explicitly (or stop and ask the user). Never auto-create.
#   4. Otherwise FAIL (exit 1): unknown ref.
#
# Output with --porcelain: INTEGRATION_BRANCH=<local branch> (stdout).
# Human explanation goes to stderr. Exit codes: 0 resolved | 1 usage/unknown
# ref | 2 unreadable summary | 3 remote ref without a local tracking branch.

BASE_REF_ARG=""
BASE_BRANCH_ARG=""
TASK_DIR=""
PORCELAIN_OUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-ref) BASE_REF_ARG="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH_ARG="$2"; shift 2 ;;
    --task-dir) TASK_DIR="$2"; shift 2 ;;
    --porcelain) PORCELAIN_OUT=true; shift ;;
    *) echo "Usage: resolve-integration-branch.sh (--base-ref <ref> [--base-branch <name>] | --task-dir <dir>) [--porcelain]" >&2; exit 1 ;;
  esac
done

BASE_REF="$BASE_REF_ARG"
BASE_BRANCH="$BASE_BRANCH_ARG"
if [ -z "$BASE_REF" ] && [ -n "$TASK_DIR" ]; then
  SUMMARY="$TASK_DIR/summary.md"
  if [ ! -f "$SUMMARY" ]; then
    echo "Error: summary.md not found at $SUMMARY" >&2
    exit 2
  fi
  BASE_REF=$(grep -E '^[*-][[:space:]]+Base ref:' "$SUMMARY" | head -n 1 | sed -E 's/^[*-][[:space:]]+Base ref:[[:space:]]*//; s/[[:space:]]*$//') || true
  BASE_BRANCH=$(grep -E '^[*-][[:space:]]+Base branch:' "$SUMMARY" | head -n 1 | sed -E 's/^[*-][[:space:]]+Base branch:[[:space:]]*//; s/[[:space:]]*$//') || true
fi

if [ -z "$BASE_REF" ]; then
  # No recorded ref (old summary): the short branch name is the ref.
  BASE_REF="$BASE_BRANCH"
fi
if [ -z "$BASE_REF" ]; then
  echo "Error: no base ref. Pass --base-ref <ref> or --task-dir <dir>." >&2
  exit 1
fi

# 1. Ref names a local branch directly.
if git show-ref --verify --quiet "refs/heads/$BASE_REF"; then
  RESULT="$BASE_REF"
  echo "Integration branch: $RESULT (Base ref is a local branch)" >&2
# 2/3. Remote-tracking ref <remote>/<branch>: need a LOCAL branch for it.
elif git show-ref --verify --quiet "refs/remotes/$BASE_REF"; then
  SHORT=$(printf '%s' "$BASE_REF" | sed -E 's|^[^/]+/||')
  TRACKING_LOCAL=""
  # A local branch tracking exactly this remote ref?
  while IFS= read -r lb; do
    UP=$(git rev-parse --abbrev-ref --symbolic-full-name "$lb@{u}" 2>/dev/null || true)
    if [ "$UP" = "$BASE_REF" ]; then
      TRACKING_LOCAL="$lb"
      break
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
  if [ -n "$TRACKING_LOCAL" ]; then
    RESULT="$TRACKING_LOCAL"
    echo "Integration branch: $RESULT (tracks $BASE_REF)" >&2
  elif git show-ref --verify --quiet "refs/heads/$SHORT" && [ -z "$BASE_BRANCH_ARG" ]; then
    # A same-named local branch exists but tracks something else (or
    # nothing): ambiguous — refuse rather than merge into the wrong line.
    echo "Error: Base ref $BASE_REF has no local tracking branch, and local '$SHORT' does not track it." >&2
    echo "Create one (git checkout -b <name> --track $BASE_REF) or choose the integration branch explicitly." >&2
    exit 3
  else
    echo "Error: Base ref $BASE_REF is remote-tracking with no local branch tracking it." >&2
    echo "Create one (git checkout -b <name> --track $BASE_REF) or choose the integration branch explicitly." >&2
    exit 3
  fi
else
  echo "Error: base ref '$BASE_REF' not found (no local branch or remote-tracking ref)." >&2
  exit 1
fi

if [ "$PORCELAIN_OUT" = true ]; then
  echo "INTEGRATION_BRANCH=$RESULT"
fi
