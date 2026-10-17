#!/usr/bin/env bash
set -euo pipefail

# Creates the Powerflow task directory. Auto-prepends today's date+time
# (YYYY-MM-DD-HHMM, local time, no colon for filesystem safety) if the slug
# lacks a date prefix. Legacy YYYY-MM-DD- prefixes are still accepted.
# POWERFLOW_NOW=YYYY-MM-DD-HHMM overrides the clock (deterministic tests).
# Exit codes: 0 created | 2 exists with content | 3 exists but empty (orphan)
# --no-gitignore skips all .gitignore mutation (default appends/creates .powerflow/).
# Same-minute collision on an auto-prefixed slug resolves to a -02, -03, ...
# suffix; explicitly dated slugs keep exit 2/3 so resume is never hijacked.
# Stdout prints the final .powerflow/<resolved-slug> — capture it and derive
# --task-slug for isolate-branch.sh from its basename so dir and branch stay
# in sync after a -02 fallback.
#
# Metadata anchoring (multi-task): inside a git repo the directory is ALWAYS
# created under the MAIN worktree root (<main>/.powerflow/), never under the
# caller's cwd — a coordinator invoking this from inside a task worktree must
# not scatter task state across worktrees (list-tasks.sh only scans the main
# root). Stdout stays main-root-relative (.powerflow/<slug>): resolve it
# against the main root, not against cwd. The .gitignore mutation likewise
# targets the main root, so no gitignore file ever leaks into a task branch
# diff. Outside any repo, cwd is used (legacy single-dir behavior).

TASK_SLUG=""
NO_GITIGNORE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    --no-gitignore) NO_GITIGNORE=true; shift ;;
    *) echo "Usage: init-task-dir.sh --task-slug <slug> [--no-gitignore]" >&2; exit 1 ;;
  esac
done

if [ -z "$TASK_SLUG" ]; then
  echo "Error: --task-slug is required" >&2
  exit 1
fi

# Strict slug validation: reject path separators, traversal, whitespace, and
# shell-hostile characters before touching the filesystem.
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

if ! [[ "$TASK_SLUG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{4})?-.+ ]]; then
  NOW="${POWERFLOW_NOW:-$(date +%F-%H%M)}"
  TASK_SLUG="${NOW}-${TASK_SLUG}"
  echo "Date-time prefix auto-added: $TASK_SLUG" >&2
  AUTO_PREFIXED=true
else
  AUTO_PREFIXED=false
fi

# Anchor: main worktree root inside a repo (never the caller's worktree),
# else cwd. PF_BASE is the absolute metadata base; stdout stays
# main-root-relative so existing consumers ($ROOT/$OUT) keep working.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}')
  if [ -z "$MAIN_ROOT" ]; then
    MAIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || MAIN_ROOT="$PWD"
  fi
  PF_BASE="$MAIN_ROOT/.powerflow"
else
  PF_BASE="$PWD/.powerflow"
fi

TASK_DIR_ABS="$PF_BASE/$TASK_SLUG"
TASK_DIR=".powerflow/$TASK_SLUG"

if [ -d "$TASK_DIR_ABS" ]; then
  if [ -n "$(ls -A "$TASK_DIR_ABS")" ]; then
    # Same-minute collision on a just-auto-prefixed slug: find a free
    # -02/-03/... suffix instead of forcing the agent to ask the user.
    # Explicitly dated slugs still exit 2 so resume intent is preserved.
    if [ "${AUTO_PREFIXED:-false}" = true ]; then
      RESOLVED=""
      for i in $(seq 2 99); do
        CAND="${TASK_SLUG}-$(printf '%02d' "$i")"
        if [ ! -e "$PF_BASE/$CAND" ]; then
          RESOLVED="$CAND"
          break
        fi
      done
      if [ -n "$RESOLVED" ]; then
        echo "[COLLISION-RESOLVED] $TASK_DIR exists; using .powerflow/$RESOLVED instead." >&2
        TASK_SLUG="$RESOLVED"
        TASK_DIR_ABS="$PF_BASE/$TASK_SLUG"
        TASK_DIR=".powerflow/$TASK_SLUG"
      else
        echo "[COLLISION] $TASK_DIR exists with content. Resume it or pick a new slug." >&2
        exit 2
      fi
    else
      echo "[COLLISION] $TASK_DIR exists with content. Resume it or pick a new slug." >&2
      exit 2
    fi
  else
    echo "[ORPHAN] $TASK_DIR exists but is empty. Reuse it or pick a new slug." >&2
    exit 3
  fi
fi

mkdir -p "$TASK_DIR_ABS"/{context,plans,reviews,executions/diagnostics,reports}

# Ensure .powerflow/ is gitignored (unless opted out — announce either way).
# Always the MAIN root's .gitignore: writing it into a task worktree would
# leak an untracked file into the task branch diff.
if [ "$NO_GITIGNORE" = true ]; then
  echo "Skipped .gitignore handling (--no-gitignore)." >&2
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GITIGNORE="$MAIN_ROOT/.gitignore"
  if [ -f "$GITIGNORE" ]; then
    if ! grep -qxE '^\.?powerflow/?$' "$GITIGNORE" && ! grep -q '^\.powerflow/' "$GITIGNORE"; then
      printf "\n# Powerflow task directory\n.powerflow/\n" >> "$GITIGNORE"
      echo "Added .powerflow/ to $GITIGNORE" >&2
    fi
  else
    printf "# Powerflow task directory\n.powerflow/\n" > "$GITIGNORE"
    echo "Created $GITIGNORE with .powerflow/" >&2
  fi
fi

echo "$TASK_DIR"
