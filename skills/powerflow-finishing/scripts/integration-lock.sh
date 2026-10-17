#!/usr/bin/env bash
set -euo pipefail

# Serializes Powerflow integrations: only one task may merge into the shared
# integration branch at a time. Backed by an atomic mkdir lock under
# <main-root>/.powerflow/.integration-lock/ (portable, no flock needed).
# Writes nothing outside that lock dir.
#
# The lock is a LEASE refreshed by heartbeat, not a plain timestamp:
# acquire/release are separate short-lived processes, so holder-PID liveness
# cannot work (the acquirer's PID is dead the moment acquire exits). Instead
# the live owner refreshes HEARTBEAT ("integration-lock.sh heartbeat" or the
# `run`/`integrate-task.sh` loops) and only a lease with no refresh for
# --stale-after seconds (default 1800) is stolen — a >30-minute integration
# is never mistaken for a crash while its heartbeat runs. A crashed owner
# stops heartbeating, so the queue still recovers. Prefer the `run`
# subcommand: it holds the lock for exactly the lifetime of the child command
# (with heartbeat) and always releases it.
#
# Usage:
#   integration-lock.sh acquire --task <slug> [--stale-after N] [--porcelain]
#   integration-lock.sh release --task <slug> [--force] [--porcelain]
#   integration-lock.sh heartbeat --task <slug> [--porcelain]
#   integration-lock.sh status [--porcelain]
#   integration-lock.sh run --task <slug> [--stale-after N] -- <command...>
#
# Exit codes: 0 ok (acquired/released/refreshed/free/command ok) | 1 error |
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
  echo "Usage: integration-lock.sh (acquire --task <slug>|release --task <slug> [--force]|heartbeat --task <slug>|status|run --task <slug> -- <command...>) [--stale-after N] [--porcelain]" >&2
  exit 2
}

case "$CMD" in
  acquire|release|heartbeat|status|run) ;;
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

if { [ "$CMD" = "acquire" ] || [ "$CMD" = "release" ] || [ "$CMD" = "heartbeat" ] || [ "$CMD" = "run" ]; } && [ -z "$TASK" ]; then
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

lock_holder() { # lock_holder -> prints "PID TASK SINCE HEARTBEAT" or fails
  # HEARTBEAT is empty for leases written before heartbeat existed; callers
  # must read it as ${4:-} and fall back to SINCE.
  local pid="" task="" since="" hb=""
  [ -f "$INFO" ] || return 1
  pid=$(grep -E '^PID=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  task=$(grep -E '^TASK=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  since=$(grep -E '^SINCE=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  hb=$(grep -E '^HEARTBEAT=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$pid" ] && [ -n "$task" ] && [ -n "$since" ] || return 1
  printf '%s %s %s %s' "$pid" "$task" "$since" "$hb"
}

freshest_ts() { # freshest_ts <since> [heartbeat] -> newest numeric ts or "unknown"
  local since="${1:-}" hb="${2:-}" best=""
  [[ "$since" =~ ^[0-9]+$ ]] && best="$since"
  if [[ "$hb" =~ ^[0-9]+$ ]] && { [ -z "$best" ] || [ "$hb" -gt "$best" ]; }; then
    best="$hb"
  fi
  [ -n "$best" ] && printf '%s' "$best" || printf 'unknown'
}

lock_age() { # lock_age <effective-ts> -> seconds or "unknown"
  local ts="$1" now
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  now=$(now_s)
  printf '%s' "$((now - ts))"
}

lock_is_stale() { # lock_is_stale <since> [heartbeat] -> 0 when lease expired
  # A live owner refreshes HEARTBEAT continuously, so only a lease with NO
  # refresh for STALE_AFTER seconds is stolen — a long integration is never
  # mistaken for a crash while its heartbeat runs.
  local eff age
  eff=$(freshest_ts "${1:-}" "${2:-}")
  age=$(lock_age "$eff")
  [ "$age" != "unknown" ] && [ "$age" -ge "$STALE_AFTER" ]
}

write_info() { # write_info <pid> <task> <since> — atomic via tmp+mv
  local tmp
  tmp=$(mktemp "$LOCK_DIR/.tmp.XXXXXX" 2>/dev/null) || return 1
  printf 'PID=%s\nTASK=%s\nSINCE=%s\nHEARTBEAT=%s\n' "$1" "$2" "$3" "$(now_s)" > "$tmp"
  mv -f "$tmp" "$INFO"
}

do_acquire() { # do_acquire -> 0 acquired, 3 held; sets ACQUIRED_MODE
  ACQUIRED_MODE=""
  mkdir -p "$MAIN_ROOT/.powerflow"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    write_info "$$" "$TASK" "$(now_s)" || { rm -rf "$LOCK_DIR"; echo "Error: cannot write lock info." >&2; return 1; }
    ACQUIRED_MODE="fresh"
    return 0
  fi
  local holder pid task since hb eff
  if holder=$(lock_holder); then
    # shellcheck disable=SC2086
    set -- $holder
    pid="$1"; task="$2"; since="$3"; hb="${4:-}"
    eff=$(freshest_ts "$since" "$hb")
    if lock_is_stale "$since" "$hb"; then
      echo "WARNING: stealing stale integration lock (task '$task', no refresh for $(lock_age "$eff")s >= ${STALE_AFTER}s)." >&2
      rm -rf "$LOCK_DIR"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_info "$$" "$TASK" "$(now_s)" || { rm -rf "$LOCK_DIR"; echo "Error: cannot write lock info." >&2; return 1; }
        ACQUIRED_MODE="stale"
        return 0
      fi
      echo "Error: cannot acquire integration lock (race lost)." >&2
      return 1
    fi
    echo "Error: integration lock held by task '$task' (last refresh $(lock_age "$eff")s ago). Wait for it to finish." >&2
    return 3
  fi
  # Lock dir exists but unreadable/empty (crashed mid-acquire): reset it.
  echo "WARNING: integration lock dir exists without holder info; resetting." >&2
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    write_info "$$" "$TASK" "$(now_s)" || { rm -rf "$LOCK_DIR"; echo "Error: cannot write lock info." >&2; return 1; }
    ACQUIRED_MODE="reset"
    return 0
  fi
  echo "Error: cannot acquire integration lock (race lost)." >&2
  return 1
}

do_heartbeat() { # do_heartbeat -> 0 refreshed, 1 held-by-other/gone
  # Refreshes the lease ONLY when this task still owns it — never clobbers
  # another task's lock (e.g. after a legitimate steal).
  local holder task since hb pid
  holder=$(lock_holder) || { echo "Error: no integration lock to refresh." >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $holder
  pid="$1"; task="$2"; since="$3"; hb="${4:-}"
  if [ "$task" != "$TASK" ]; then
    echo "Error: lock held by task '$task', not '$TASK' — not refreshing." >&2
    return 1
  fi
  write_info "$pid" "$task" "$since" || { echo "Error: cannot refresh lock." >&2; return 1; }
  return 0
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

heartbeat_every() { # heartbeat_every -> seconds between refreshes
  # Well below the steal threshold so a live owner is never mistaken for a
  # crash; overridable via POWERFLOW_HEARTBEAT_INTERVAL (tests use seconds).
  local want="${POWERFLOW_HEARTBEAT_INTERVAL:-60}" third
  [[ "$want" =~ ^[0-9]+$ ]] && [ "$want" -ge 1 ] || want=60
  third=$((STALE_AFTER / 3))
  [ "$third" -lt 1 ] && third=1
  [ "$want" -lt "$third" ] && printf '%s' "$want" || printf '%s' "$third"
}

HEART_PID=""
start_heartbeat_loop() { # start_heartbeat_loop <task> — refreshes until stopped
  local hb_task="$1" every
  every=$(heartbeat_every)
  ( while true; do
      sleep "$every"
      bash "$0" heartbeat --task "$hb_task" >/dev/null 2>&1 || true
    done ) &
  HEART_PID=$!
}

stop_heartbeat_loop() {
  if [ -n "$HEART_PID" ]; then
    kill "$HEART_PID" 2>/dev/null || true
    wait "$HEART_PID" 2>/dev/null || true
    HEART_PID=""
  fi
}

case "$CMD" in
  status)
    if HOLDER=$(lock_holder); then
      # shellcheck disable=SC2086
      set -- $HOLDER
      EFF=$(freshest_ts "$3" "${4:-}")
      AGE=$(lock_age "$EFF")
      if lock_is_stale "$3" "${4:-}"; then
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=stale\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\n' "$2" "$AGE"
        echo "Integration lock STALE (task '$2', no refresh for ${AGE}s). Next acquire will steal it." >&2
      else
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=held\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\n' "$2" "$AGE"
        echo "Integration lock held by task '$2' (last refresh ${AGE}s ago)." >&2
      fi
    else
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=free\n'
      echo "Integration lock free." >&2
    fi
    exit 0
    ;;
  heartbeat)
    if do_heartbeat; then
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=refreshed\nHOLDER_TASK=%s\n' "$TASK"
      echo "Integration lock refreshed for task '$TASK'." >&2
      exit 0
    else
      exit 1
    fi
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
    start_heartbeat_loop "$TASK"
    set +e
    "${RUN_ARGS[@]}"
    CODE=$?
    set -e
    stop_heartbeat_loop
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
