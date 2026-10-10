#!/usr/bin/env bash
set -euo pipefail

# Resolves the LOCAL integration branch for a Powerflow merge/discard op.
# A remote-tracking Base ref (origin/main, upstream/main) must NEVER be
# checked out directly: that detaches HEAD, and the merge would land on a
# nameless checkout instead of the integration branch (losing the result when
# the task branch is deleted).
#
# Usage:
#   resolve-integration-branch.sh (--base-ref <ref> | --task-dir <dir>)
# (--base-branch is accepted but ignored, for backward compat.)
#
# Rules (in order):
#   1. If the ref is REMOTE-QUALIFIED (<remote>/<branch>) and
#      refs/remotes/<ref> exists, the REMOTE identity wins: a local branch
#      that merely shares the slash-name (legal in Git) must never shadow
#      it. Answer = the local branch tracking that exact remote ref, else
#      FAIL (exit 3).
#   2. If the ref names a LOCAL branch (short name, no remote match), that
#      branch is the answer.
#   3. If it is a remote-tracking ref with no local branch tracking it, FAIL
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
    *) echo "Usage: resolve-integration-branch.sh (--base-ref <ref> | --task-dir <dir>) [--porcelain]" >&2; exit 1 ;;
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

# Remote identity first: a remote-qualified Base ref (upstream/main) must
# resolve via refs/remotes/ BEFORE any same-named local branch is even
# considered — a local branch literally named "upstream/main" is legal in Git
# and must never shadow the recorded remote source.
if git show-ref --verify --quiet "refs/remotes/$BASE_REF"; then
  # Canonical remote ref (ambiguity-proof: a same-named local branch makes
  # short forms ambiguous, so compare full refnames). Guard against empty
  # output: rev-parse may exit 0 with nothing on ambiguous names.
  WANT=$(git rev-parse --symbolic-full-name "$BASE_REF" 2>/dev/null || true)
  if [ -z "$WANT" ]; then
    WANT="refs/remotes/$BASE_REF"
  fi
  TRACKING_LOCAL=""
  # A local branch tracking exactly this remote ref? Use full refnames on
  # both sides (short upstream names are ambiguous under collisions), and
  # skip branches without an upstream (empty UP must never equal WANT).
  while IFS= read -r lb; do
    UP=$(git rev-parse --symbolic-full-name "$lb@{u}" 2>/dev/null || true)
    if [ -n "$UP" ] && [ "$UP" = "$WANT" ]; then
      TRACKING_LOCAL="$lb"
      break
    fi
  done < <(git for-each-ref --format='%(refname)' refs/heads/ | sed -E 's|^refs/heads/||')
  if [ -n "$TRACKING_LOCAL" ]; then
    RESULT="$TRACKING_LOCAL"
    echo "Integration branch: $RESULT (tracks $BASE_REF)" >&2
  else
    SHORT=$(printf '%s' "$BASE_REF" | sed -E 's|^[^/]+/||')
    if git show-ref --verify --quiet "refs/heads/$SHORT"; then
      echo "Error: Base ref $BASE_REF is remote-tracking with no local branch tracking it (local '$SHORT' does not track it)." >&2
    else
      echo "Error: Base ref $BASE_REF is remote-tracking with no local branch tracking it." >&2
    fi
    echo "Create one (git checkout -b <name> --track $BASE_REF) or choose the integration branch explicitly." >&2
    exit 3
  fi
# Short ref naming a local branch directly.
elif git show-ref --verify --quiet "refs/heads/$BASE_REF"; then
  RESULT="$BASE_REF"
  echo "Integration branch: $RESULT (Base ref is a local branch)" >&2
else
  echo "Error: base ref '$BASE_REF' not found (no local branch or remote-tracking ref)." >&2
  exit 1
fi

if [ "$PORCELAIN_OUT" = true ]; then
  echo "INTEGRATION_BRANCH=$RESULT"
fi
