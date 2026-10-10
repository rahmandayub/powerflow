#!/usr/bin/env bash
set -euo pipefail

# Creates the Powerflow task directory. Auto-prepends today's date if the slug
# lacks a YYYY-MM-DD- prefix.
# Exit codes: 0 created | 2 exists with content | 3 exists but empty (orphan)
# --no-gitignore skips all .gitignore mutation (default appends/creates .powerflow/).

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

if ! [[ "$TASK_SLUG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-.+ ]]; then
  TASK_SLUG="$(date +%F)-${TASK_SLUG}"
  echo "Date prefix auto-added: $TASK_SLUG" >&2
fi

TASK_DIR=".powerflow/$TASK_SLUG"

if [ -d "$TASK_DIR" ]; then
  if [ -n "$(ls -A "$TASK_DIR")" ]; then
    echo "[COLLISION] $TASK_DIR exists with content. Resume it or pick a new slug." >&2
    exit 2
  else
    echo "[ORPHAN] $TASK_DIR exists but is empty. Reuse it or pick a new slug." >&2
    exit 3
  fi
fi

mkdir -p "$TASK_DIR"/{context,plans,reviews,executions/diagnostics,reports}

# Ensure .powerflow/ is gitignored (unless opted out — announce either way)
if [ "$NO_GITIGNORE" = true ]; then
  echo "Skipped .gitignore handling (--no-gitignore)." >&2
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_ROOT=$(git rev-parse --show-toplevel)
  GITIGNORE="$GIT_ROOT/.gitignore"
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
