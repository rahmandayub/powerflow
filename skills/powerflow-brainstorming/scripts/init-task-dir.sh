#!/usr/bin/env bash
set -euo pipefail

# Creates the Powerflow task directory. Auto-prepends today's date if the slug
# lacks a YYYY-MM-DD- prefix.
# Exit codes: 0 created | 2 exists with content | 3 exists but empty (orphan)

TASK_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-slug) TASK_SLUG="$2"; shift 2 ;;
    *) echo "Usage: init-task-dir.sh --task-slug <slug>" >&2; exit 1 ;;
  esac
done

if [ -z "$TASK_SLUG" ]; then
  echo "Error: --task-slug is required" >&2
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
echo "$TASK_DIR"
