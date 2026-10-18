#!/usr/bin/env bash
set -euo pipefail

# Serializes Powerflow integrations: only one task may merge into the shared
# integration branch at a time. Backed by an atomic mkdir lock under
# <main-root>/.powerflow/.integration-lock/ (portable, no flock needed).
# Writes nothing outside that lock dir.
#
# The lock is a TOKEN lease refreshed by heartbeat, not a plain timestamp:
# acquire/release are separate short-lived processes, so holder-PID liveness
# cannot work (the acquirer's PID is dead the moment acquire exits). Instead
# each acquire mints a unique TOKEN, the live owner refreshes HEARTBEAT
# ("integration-lock.sh heartbeat" or the `run`/`integrate-task.sh` loops),
# and only a lease with no refresh for --stale-after seconds (default 1800)
# is stolen — a >30-minute integration is never mistaken for a crash while
# its heartbeat runs. A crashed owner stops heartbeating, so the queue still
# recovers. Takeover is decided by ONE atomic step (renaming the stale lock
# dir aside): exactly one concurrent thief wins; losers re-read and back off.
# Owners prove ownership by TOKEN — a heartbeat or release that finds another
# token never touches the lease, and an integrator that loses its token must
# stop before any further shared mutation (see integrate-task.sh). Prefer the
# `run` subcommand: it holds the lock for exactly the lifetime of the child
# command (with heartbeat) and always releases it.
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

new_token() { # new_token -> unique owner identity for one acquire
  # $$ + epoch + $RANDOM: unique per acquire on this host without date %N
  # (not portable to BSD date). Recorded in the lease; owners prove
  # ownership by token, never by PID (PIDs of acquire processes are
  # short-lived) — so a late heartbeat can never be mistaken for the owner.
  printf '%s-%s-%s' "$$" "$(date +%s)" "$RANDOM"
}

lock_holder() { # lock_holder -> prints "PID TASK SINCE HEARTBEAT TOKEN" or fails
  # HEARTBEAT/TOKEN are empty for leases written before they existed;
  # callers must read them as ${4:-}/${5:-} and fall back to SINCE.
  local pid="" task="" since="" hb="" tok=""
  [ -f "$INFO" ] || return 1
  pid=$(grep -E '^PID=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  task=$(grep -E '^TASK=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  since=$(grep -E '^SINCE=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  hb=$(grep -E '^HEARTBEAT=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  tok=$(grep -E '^TOKEN=' "$INFO" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$pid" ] && [ -n "$task" ] && [ -n "$since" ] || return 1
  printf '%s %s %s %s %s' "$pid" "$task" "$since" "$hb" "$tok"
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

write_info() { # write_info <pid> <task> <since> <token> — atomic via tmp+mv
  local tmp
  tmp=$(mktemp "$LOCK_DIR/.tmp.XXXXXX" 2>/dev/null) || return 1
  printf 'PID=%s\nTASK=%s\nSINCE=%s\nHEARTBEAT=%s\nTOKEN=%s\n' "$1" "$2" "$3" "$(now_s)" "$4" > "$tmp"
  mv -f "$tmp" "$INFO"
}

read_info_at() { # read_info_at <infofile> -> "PID TASK SINCE HEARTBEAT TOKEN" or fails
  local f="$1" pid="" task="" since="" hb="" tok=""
  [ -f "$f" ] || return 1
  pid=$(grep -E '^PID=' "$f" 2>/dev/null | cut -d= -f2 || true)
  task=$(grep -E '^TASK=' "$f" 2>/dev/null | cut -d= -f2 || true)
  since=$(grep -E '^SINCE=' "$f" 2>/dev/null | cut -d= -f2 || true)
  hb=$(grep -E '^HEARTBEAT=' "$f" 2>/dev/null | cut -d= -f2 || true)
  tok=$(grep -E '^TOKEN=' "$f" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$pid" ] && [ -n "$task" ] && [ -n "$since" ] || return 1
  printf '%s %s %s %s %s' "$pid" "$task" "$since" "$hb" "$tok"
}

do_acquire() { # do_acquire -> 0 acquired, 3 held; sets ACQUIRED_MODE/ACQUIRED_TOKEN
  # Takeover is decided by ONE atomic step: renaming the observed-stale lock
  # dir aside. Exactly one concurrent thief wins the rename; losers re-read
  # and back off. A late heartbeat from the old owner writes into the
  # detached aside dir — never into the new lease.
  #
  # Staleness is evaluated on data read BEFORE the rename, but the rename
  # moves WHATEVER exists at rename time — so after winning, the mover MUST
  # verify the aside copy still carries the observed token. If a full steal
  # cycle by someone else slipped into the microsecond gap, the aside holds
  # THEIR live lease: put it back and back off instead of destroying it.
  #
  # Ambiguity rule: an existing-but-unreadable lock dir is NEVER reset
  # blindly (a takeover may be in flight — resetting deleted a live lock in
  # testing). Only mkdir-winners write; mkdir is attempted solely when the
  # dir is believed absent (initial try, post-own-rename, adopted orphan).
  # Unsettled states retry briefly, then report held; a genuinely orphaned
  # dir needs an operator `release --force`.
  ACQUIRED_MODE=""
  ACQUIRED_TOKEN=""
  mkdir -p "$MAIN_ROOT/.powerflow"
  # Discard takeovers orphaned by a crash between rename and cleanup. Asides
  # are never read back, so deleting them cannot affect a live lease.
  rm -rf "$MAIN_ROOT"/.powerflow/.integration-lock.stale.* 2>/dev/null || true
  local attempt holder pid task since hb tok eff aside moved_tokens
  local absent_seen=0
  for attempt in 1 2 3 4 5 6 7 8; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Dir was absent: free lock (or a takeover gap someone must fill).
      # A takeover gap is filled ONLY here or via adopt below — never by
      # resetting an existing dir.
      ACQUIRED_TOKEN=$(new_token)
      if write_info "$$" "$TASK" "$(now_s)" "$ACQUIRED_TOKEN"; then
        ACQUIRED_MODE="fresh"
        return 0
      fi
      rmdir "$LOCK_DIR" 2>/dev/null || true
      echo "Error: cannot write lock info." >&2
      return 1
    fi
    if holder=$(lock_holder); then
      absent_seen=0
      # shellcheck disable=SC2086
      set -- $holder
      pid="$1"; task="$2"; since="$3"; hb="${4:-}"; tok="${5:-}"
      eff=$(freshest_ts "$since" "$hb")
      if ! lock_is_stale "$since" "$hb"; then
        echo "Error: integration lock held by task '$task' (last refresh $(lock_age "$eff")s ago). Wait for it to finish." >&2
        return 3
      fi
      echo "WARNING: stealing stale integration lock (task '$task', no refresh for $(lock_age "$eff")s >= ${STALE_AFTER}s)." >&2
      aside="$MAIN_ROOT/.powerflow/.integration-lock.stale.$$"
      rm -rf "$aside" 2>/dev/null || true
      if ! mv "$LOCK_DIR" "$aside" 2>/dev/null; then
        # Rename lost: another thief is mid-takeover, or the owner is
        # writing. Re-read on the next attempt instead of deciding now.
        sleep 0.2
        continue
      fi
      # Verify-after-move: the rename moves whatever exists NOW, but our
      # stale verdict came from an EARLIER read. If a full steal cycle by
      # someone else slipped into the gap, the aside holds THEIR live
      # lease — put it back untouched and back off.
      moved_tokens=""
      if moved_holder=$(read_info_at "$aside/info"); then
        # shellcheck disable=SC2086
        set -- $moved_holder
        moved_tokens="${5:-}"
      fi
      if [ -n "$tok" ] && [ "$moved_tokens" != "$tok" ]; then
        echo "WARNING: takeover raced a replacement (aside token mismatch) — restoring and backing off." >&2
        # Restore only onto an absent target: moving the aside INSIDE a live
        # third-party dir would strand it (their top-level info stays
        # intact, so they keep working — but don't do that on purpose).
        if [ ! -e "$LOCK_DIR" ] && mv "$aside" "$LOCK_DIR" 2>/dev/null; then
          echo "Error: integration lock changed hands during takeover; backing off." >&2
          return 3
        fi
        # Restore failed (third party created the dir meanwhile): the aside
        # may hold their live lease — leave it for pre-clean; their own
        # token gates protect them. Never delete it here.
        echo "Error: integration lock changed hands during takeover; backing off." >&2
        return 3
      fi
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        ACQUIRED_TOKEN=$(new_token)
        if write_info "$$" "$TASK" "$(now_s)" "$ACQUIRED_TOKEN"; then
          rm -rf "$aside" || true
          ACQUIRED_MODE="stale"
          return 0
        fi
        rmdir "$LOCK_DIR" 2>/dev/null || true
        echo "Error: cannot write lock info." >&2
        return 1
      fi
      # Our rename won but the fresh mkdir lost: a new arrival's initial
      # mkdir landed in the gap and legitimately holds a fresh lease (they
      # found no dir). Our aside copy is the verified-stale lease — drop
      # it and re-read instead of guessing.
      rm -rf "$aside" || true
      sleep 0.2
      continue
    fi
    if [ -e "$LOCK_DIR" ]; then
      # Dir exists but info unreadable (mid-write/mid-takeover): wait out
      # the transient, never reset blindly.
      absent_seen=0
      sleep 0.2
      continue
    fi
    # Dir absent and unreadable: a takeover is in flight (winner between
    # rename and re-create). Adopt the orphaned aside ONLY if exactly one
    # exists and it still verifies stale right now — the atomic mv-back
    # elects a single adopter.
    absent_seen=$((absent_seen + 1))
    if [ "$absent_seen" -ge 3 ]; then
      aside=$(adopt_stale_aside) && {
        ACQUIRED_TOKEN=$(new_token)
        if write_info "$$" "$TASK" "$(now_s)" "$ACQUIRED_TOKEN"; then
          ACQUIRED_MODE="stale-adopted"
          return 0
        fi
        echo "Error: cannot write lock info." >&2
        return 1
      }
    fi
    sleep 0.2
  done
  echo "Error: integration lock unsettled after retries — treating as held. If no integrator is running, an operator may 'release --force'." >&2
  return 3
}

adopt_stale_aside() { # adopt_stale_aside -> prints adopted dir, or fails
  # Single-orphan adoption: exactly one stale aside whose lease still
  # verifies stale NOW is moved back as the lock dir (atomic election —
  # concurrent adopters: one wins). Caller rewrites it as its own lease.
  local asides aside info_holder since hb
  asides=$(printf '%s\n' "$MAIN_ROOT"/.powerflow/.integration-lock.stale.* 2>/dev/null | grep -v '\*' || true)
  [ -n "$asides" ] || return 1
  [ "$(printf '%s\n' "$asides" | wc -l)" -eq 1 ] || return 1
  aside="$asides"
  info_holder=$(read_info_at "$aside/info") || return 1
  # shellcheck disable=SC2086
  set -- $info_holder
  since="$3"; hb="${4:-}"
  lock_is_stale "$since" "$hb" || return 1
  # Adopt only onto an absent target (never move the orphan INSIDE a live
  # dir — that would strand it with no top-level info). Residual microsecond
  # race here fails LOUD (unreadable lock → everyone reports held) rather
  # than admitting two owners.
  [ -e "$LOCK_DIR" ] && return 1
  mv "$aside" "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s' "$LOCK_DIR"
}

do_heartbeat() { # do_heartbeat -> 0 refreshed, 1 held-by-other/gone
  # Refreshes the lease ONLY when this task still owns it — the token is
  # preserved, and another task's lease is never clobbered (e.g. after a
  # legitimate steal). A heartbeat racing a takeover either lands in the
  # detached aside dir (harmless) or fails — both surface as non-zero, which
  # the owner must treat as lease loss, never ignore.
  local holder task since hb pid tok
  holder=$(lock_holder) || { echo "Error: no integration lock to refresh." >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $holder
  pid="$1"; task="$2"; since="$3"; hb="${4:-}"; tok="${5:-}"
  if [ "$task" != "$TASK" ]; then
    echo "Error: lock held by task '$task', not '$TASK' — not refreshing." >&2
    return 1
  fi
  write_info "$pid" "$task" "$since" "$tok" || { echo "Error: cannot refresh lock." >&2; return 1; }
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
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=stale\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\nHOLDER_TOKEN=%s\n' "$2" "$AGE" "${5:-}"
        echo "Integration lock STALE (task '$2', no refresh for ${AGE}s). Next acquire will steal it." >&2
      else
        [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=held\nHOLDER_TASK=%s\nHOLDER_AGE_S=%s\nHOLDER_TOKEN=%s\n' "$2" "$AGE" "${5:-}"
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
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=acquired\nHOLDER_TASK=%s\nTOKEN=%s\n' "$TASK" "$ACQUIRED_TOKEN"
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
