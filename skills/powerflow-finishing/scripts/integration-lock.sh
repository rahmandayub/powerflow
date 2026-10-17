#!/usr/bin/env bash
set -euo pipefail

# Serializes Powerflow integrations: only one task may merge into the shared
# integration branch at a time. Backed by an atomic mkdir lock under
# <main-root>/.powerflow/.integration-lock/ (portable, no flock needed).
# Writes nothing outside that lock dir.
#
# Staleness is AGE-based, not PID-based: acquire/release are separate
# short-lived processes, so holder-PID liveness cannot work (the acquirer's PID
# is dead the moment acquire exits). A lock older than --stale-after seconds
# (default 1800) is stolen on acquire with a warning — a crashed integrate
# never blocks the queue forever. Prefer the `run` subcommand: it holds the
# lock for exactly the lifetime of the child command and always releases it.
#
# Usage:
#   integration-lock.sh acquire --task <slug> [--stale-after N] [--porcelain]
#   integration-lock.sh release --task <slug> [--force] [--porcelain]
#   integration-lock.sh status [--porcelain]
#   integration-lock.sh run --task <slug> [--stale-after N] -- <command...>
#
# Exit codes: 0 ok (acquired/released/free/command ok) | 1 error |
#   2 usage or not a git repo | 3 held by another task (acquire only) |
#   run exits with the child command's code (or 3 when locked).

CMD="${1:-}"
if [ -n "$CMD" ]; then shift; else CMD=""; fi
TASK=""
FORCE=false
PORCELAIN_OUT=false
STALE_AFTER=1800
RUN_ARGS=()

usage() {
  echo "Usage: integration-lock.sh (acquire --task <slug>|release --task <slug> [--force]|status|run --task <slug> -- <command...>) [--stale-after N] [--porcelain]" >&2
  exit 2
}

case "$CMD" in
  acquire|release|status|run) ;;
  *) usage ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --porcelain) PORCELAIN_OUT=true; shift ;;
    --stale-after) STALE_AFTER="${2:-}"; shift 2 ;;
    --) shift; RUN_ARGS=("$@"); break ;;
    *) usage ;;
  esac
done

if { [ "$CMD" = "acquire" ] || [ "$CMD" = "release" ] || [ "$CMD" = "run" ]; } && [ -z "$TASK" ]; then
  echo "Error: --task <slug> is required for $CMD" >&2
  exit 2
fi
if [ "$CMD" = "run" ] && [ "${#RUN_ARGS[@]}" -eq 0 ]; then
  echo "Error: run requires a command after --" >&2
  exit 2
fi
if ! [[ "$STALE_AFTER" =~ ^[0-9]+$ ]] || [ "$STALE_AFTER" -lt 1 ]; then
  echo "Error: --stale-after must be a positive integer (got '$STALE_AFTER')" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 2
fi

MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}')
if [ -z "$MAIN_ROOT" ]; then
  echo "Error: cannot resolve repository root" >&2
  exit 1
fi
LOCK_DIR="$MAIN_ROOT/.powerflow/.integration-lock"
INFO="$LOCK_DIR/info"

now_s() { date +%s; }

lock_holder() { # lock_holder -> prints "PID TASK SINCE" or fails
  local pid="" task="" since=""
  [ -f "$INFO" ] || return 1
  pid=$(grep -E '^PID=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  task=$(grep -E '^TASK=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  since=$(grep -E '^SINCE=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$pid" ] && [ -n "$task" ] && [ -n "$since" ] || return 1
  printf '%s %s %s' "$pid" "$task" "$since"
}

lock_age() { # lock_age <since> -> seconds or "unknown"
  local since="$1" now
  [[ "$since" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  now=$(now_s)
  printf '%s' "$((now - since))"
}

lock_is_stale() { # lock_is_stale <since> -> 0 when older than STALE_AFTER
  local since="$1" age
  age=$(lock_age "$since")
  [ "$age" != "unknown" ] && [ "$age" -ge "$STALE_AFTER" ]
}

do_acquire() { # do_acquire -> 0 acquired, 3 held; sets ACQUIRED_MODE
  ACQUIRED_MODE=""
  mkdir -p "$MAIN_ROOT/.powerflow"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf 'PID=%s\nTASK=%s\nSINCE=%s\n' "$$" "$TASK" "$(now_s)" > "$INFO"
    ACQUIRED_MODE="fresh"
    return 0
  fi
  local holder pid task since
  if holder=$(lock_holder); then
    # shellcheck disable=SC2086
    set -- $holder
    pid="$1"; task="$2"; since="$3"
    if lock_is_stale "$since"; then
      echo "WARNING: stealing stale integration lock (task '$task', age $(lock_age "$since")s >= ${STALE_AFTER}s)." >&2
      rm -rf "$LOCK_DIR"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'PID=%s\nTASK=%s\nSINCE=%s\n' "$$" "$TASK" "$(now_s)" > "$INFO"
        ACQUIRED_MODE="stale"
        return 0
      fi
      echo "Error: cannot acquire integration lock (race lost)." >&2
      return 1
    fi
    echo "Error: integration lock held by task '$task' (age $(lock_age "$since")s). Wait for it to finish." >&2
    return 3
  fi
  # Lock dir exists but unreadable/empty (crashed mid-acquire): reset it.
  echo "WARNING: integration lock dir exists without holder info; resetting." >&2
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf 'PID=%s\nTASK=%s\nSINCE=%s\n' "$$" "$TASK" "$(now_s)" > "$INFO"
    ACQUIRED_MODE="reset"
    return 0
  fi
  echo "Error: cannot acquire integration lock (race lost)." >&2
  return 1
}

do_release() { # do_release -> 0 released/already-free, 1 held-by-other
  local holder task
  if holder=$(lock_holder); then
    # shellcheck disable=SC2086
    set -- $holder
    task="$2"
    if [ "$task" != "$TASK" ] && [ "$FORCE" = false ]; then
      echo "Error: lock held by task '$task', not '$TASK'. Use --force to break it." >&2
      return 1
    fi
    rm -rf "$LOCK_DIR"
    echo "Integration lock released (was task '$task')." >&2
    return 0
  fi
  echo "Integration lock already free." >&2
  return 0
}

case "$CMD" in
  status)
    if HOLDER=$(lock_holder); then
      # shellcheck disable=SC2086
      set -- $HOLDER
      AGE=$(lock_age "$3")
      if lock_is_stale "$3"; then
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=stale\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\n' "$2" "$AGE"
        echo "Integration lock STALE (task '$2', age ${AGE}s). Next acquire will steal it." >&2
      else
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=held\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\n' "$2" "$AGE"
        echo "Integration lock held by task '$2' (age ${AGE}s)." >&2
      fi
    else
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=free\n'
      echo "Integration lock free." >&2
    fi
    exit 0
    ;;
  acquire)
    if do_acquire; then
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=acquired\nHOLDER_TASK=%s\n' "$TASK"
      echo "Integration lock acquired for task '$TASK'." >&2
      exit 0
    else
      CODE=$?
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=held\n'
      exit "$CODE"
    fi
    ;;
  release)
    if do_release; then
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=released\n'
      exit 0
    else
      exit 1
    fi
    ;;
  run)
    # NOTE: no `!` here — `$?` after `! cmd` is the negated status (0).
    do_acquire
    CODE=$?
    if [ "$CODE" -ne 0 ]; then
      exit "$CODE"
    fi
    echo "Integration lock acquired for task '$TASK' (run mode)." >&2
    set +e
    "${RUN_ARGS[@]}"
    CODE=$?
    set -e
    # Release only if we still hold it (a nested --force release or an
    # operator break may have removed it; never delete another task's lock).
    if HOLDER=$(lock_holder); then
      # shellcheck disable=SC2086
      set -- $HOLDER
      if [ "$2" = "$TASK" ]; then
        rm -rf "$LOCK_DIR"
        echo "Integration lock released (run mode, child exit $CODE)." >&2
      else
        echo "WARNING: lock now held by task '$2'; leaving it (run mode)." >&2
      fi
    else
      echo "WARNING: lock already gone on child exit $CODE (run mode)." >&2
    fi
    exit "$CODE"
    ;;
esac
