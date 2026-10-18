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
# Check-then-act safety:
# 1. Heartbeat updates a token-scoped file (heartbeat.<token>), NEVER
#    rewriting ownership metadata (info) through the shared path. Even if a
#    heartbeat pauses after reading the lease, it cannot overwrite a replacement
#    lease's metadata, nor refresh another lease's staleness.
# 2. Release uses verify-after-move: the lock dir is atomically renamed
#    aside first, and its token is verified before deletion. If takeover slipped
#    in during a pause, the replacement lease is restored unharmed and release
#    is refused with exit 1.
# 3. Release asides are not blind garbage. A release publishes an intent
#    (SINCE + its own WINDOW + expected TOKEN) BEFORE moving the lock dir, and
#    acquire never rm -rf's .rel.*/.stale.* wholesale. While an intent is
#    fresh (within the RELEASER's window, not the acquirer's; the window is
#    capped and an unparseable/future SINCE counts as stale, so an intent can
#    never pin the lock forever), acquire waits instead of filling the
#    recovery gap; when an aside parks a lease that is still fresh, acquire
#    restores it (mkdir election + move) rather than deleting it. Only stale
#    intents/asides are cleaned, so a third acquirer can no longer delete a
#    replacement lease displaced by a late release, while a release that truly
#    dies still recovers after --stale-after.
# 4. A restore claim is itself recoverable. restore_aside() publishes a restore
#    intent (SINCE + WINDOW + parked TOKEN + ASIDE) BEFORE its mkdir election
#    and moves info last. If the winner dies between mkdir and the info move,
#    $LOCK_DIR is left empty with a soon-stale intent; the next restorer sees
#    no fresh claim and RESUMES the abandoned one by moving the parked lease in
#    (never blindly deleting an info-less dir, which could be a paused
#    restorer). A claim authorizes ONLY the aside and TOKEN it names, so an
#    unrelated stale claim can never move a different parked lease into the
#    abandoned dir. Intent filenames carry a unique invocation identity, ensuring
#    that PID reuse cannot delete or clobber preexisting claims. A crash cannot
#    strand the queue, and claims cannot cross.
#
# Architectural boundary:
# A time-bounded lease with expiration (--stale-after) cannot provide
# absolute mutual exclusion against arbitrary process pauses (e.g. SIGSTOP,
# VM freeze, or multi-minute GC pauses) that resume execution immediately
# after the final pre-mutation lease verification. Absolute exclusion
# against arbitrary pauses requires fencing tokens enforced by the target
# resource (e.g. storage/git server rejecting writes with older epochs) or
# a non-expiring lock (which sacrifices automatic crash recovery).
# Stale lease stealing is a conscious design trade-off for unattended crash
# recovery in a portable, serverless filesystem environment.
#
# Usage:
#   integration-lock.sh acquire --task <slug> [--stale-after N] [--porcelain]
#   integration-lock.sh release --task <slug> --token <tok> [--porcelain]
#     (--force instead of --token: explicit operator break, skips the check)
#   integration-lock.sh heartbeat --task <slug> --token <tok> [--porcelain]
#   integration-lock.sh status [--porcelain]
#   integration-lock.sh run --task <slug> [--stale-after N] -- <command...>
#
# Ownership is proven by TOKEN, never by slug alone: the token minted at
# acquire must accompany every heartbeat and (non-force) release. A stale
# integrator returning for the SAME slug with an old token can neither
# refresh nor delete the new lease — slug match alone proves nothing, since
# a re-queued task legitimately re-acquires under its own slug.
#
# Exit codes: 0 ok (acquired/released/refreshed/free/command ok) | 1 error
#   (incl. token mismatch) | 2 usage or not a git repo |
#   3 held by another task (acquire only) |
#   run exits with the child command's code (or 3 when locked).

CMD="${1:-}"
if [ -n "$CMD" ]; then shift; else CMD=""; fi
TASK=""
TOKEN_REQ=""
FORCE=false
PORCELAIN_OUT=false
STALE_AFTER=1800
RUN_ARGS=()

usage() {
  echo "Usage: integration-lock.sh (acquire --task <slug>|release --task <slug> (--token <tok>|--force)|heartbeat --task <slug> --token <tok>|status|run --task <slug> -- <command...>) [--stale-after N] [--porcelain]" >&2
  exit 2
}

case "$CMD" in
  acquire|release|heartbeat|status|run) ;;
  *) usage ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --token) TOKEN_REQ="${2:-}"; shift 2 ;;
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
if [ "$CMD" = "heartbeat" ] && [ -z "$TOKEN_REQ" ]; then
  echo "Error: --token <tok> is required for heartbeat (ownership is proven by token, not slug)" >&2
  exit 2
fi
if [ "$CMD" = "release" ] && [ "$FORCE" = false ] && [ -z "$TOKEN_REQ" ]; then
  echo "Error: --token <tok> is required for release (or --force for an explicit operator break)" >&2
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

read_info_at() { # read_info_at <infofile> -> "PID TASK SINCE HEARTBEAT TOKEN" or fails
  # Same `-` anchoring as lock_holder: absent trailing fields must not
  # shift positions (see above).
  # Heartbeat is read first from the token-scoped file (heartbeat.<token>)
  # in the lock dir, falling back to HEARTBEAT in info for legacy leases/tests.
  local f="$1" pid="" task="" since="" hb="" tok="" dir=""
  [ -f "$f" ] || return 1
  pid=$(grep -E '^PID=' "$f" 2>/dev/null | cut -d= -f2 || true)
  task=$(grep -E '^TASK=' "$f" 2>/dev/null | cut -d= -f2 || true)
  since=$(grep -E '^SINCE=' "$f" 2>/dev/null | cut -d= -f2 || true)
  tok=$(grep -E '^TOKEN=' "$f" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$pid" ] && [ -n "$task" ] && [ -n "$since" ] || return 1
  dir=$(dirname "$f")
  if [ -n "$tok" ] && [ "$tok" != "-" ] && [ -f "$dir/heartbeat.$tok" ]; then
    hb=$(cat "$dir/heartbeat.$tok" 2>/dev/null || true)
  fi
  if [ -z "$hb" ]; then
    hb=$(grep -E '^HEARTBEAT=' "$f" 2>/dev/null | cut -d= -f2 || true)
  fi
  printf '%s %s %s %s %s' "$pid" "$task" "$since" "${hb:--}" "${tok:--}"
}

lock_holder() { # lock_holder -> prints "PID TASK SINCE HEARTBEAT TOKEN" or fails
  # Fields are space-joined and positionally parsed, so absent trailing
  # fields MUST NOT shift positions: missing HEARTBEAT/TOKEN (leases written
  # before they existed) print as `-`. Consumers treat `-` as unknown:
  # freshest_ts falls back to SINCE, and a `-` token never equals a real
  # ownership token (a tokenless legacy lease can only be taken by steal or
  # operator --force, never refreshed/released by token).
  read_info_at "$INFO"
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
  # Info holds immutable ownership metadata for the lease directory.
  # Heartbeat timestamps are written to heartbeat.<token>, never rewriting info.
  local tmp
  tmp=$(mktemp "$LOCK_DIR/.tmp.XXXXXX" 2>/dev/null) || return 1
  printf 'PID=%s\nTASK=%s\nSINCE=%s\nHEARTBEAT=%s\nTOKEN=%s\n' "$1" "$2" "$3" "$3" "$4" > "$tmp"
  mv -f "$tmp" "$INFO"
}

REL_PREFIX="$MAIN_ROOT/.powerflow/.integration-lock.rel"
STALE_PREFIX="$MAIN_ROOT/.powerflow/.integration-lock.stale"

intent_field() { # intent_field <file> <KEY>
  grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2 || true
}

INTENT_MAX_WINDOW=86400 # cap: an intent may not pin the lock longer than a day

intent_is_fresh() { # intent_is_fresh <intentfile> -> 0 while release is live
  # The releaser records its own WINDOW (its --stale-after): an intent stays
  # authoritative for as long as that release's lease model would, independent
  # of the acquirer's own --stale-after. The window is capped, and a future
  # SINCE (clock skew) is clamped, so no intent can block acquisition forever.
  local ts window age now
  ts=$(intent_field "$1" SINCE)
  # Intents are written atomically, so a visible one always carries a numeric
  # SINCE. An unparseable or future SINCE (corruption, clock skew) is stale,
  # not "fresh forever": recover_asides then cleans it, and any lease it names
  # is still judged on its own freshness before deletion.
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  now=$(now_s)
  [ "$ts" -le "$now" ] || return 1
  window=$(intent_field "$1" WINDOW)
  [[ "$window" =~ ^[0-9]+$ ]] && [ "$window" -ge 1 ] || window="$STALE_AFTER"
  [ "$window" -le "$INTENT_MAX_WINDOW" ] || window="$INTENT_MAX_WINDOW"
  age=$(( now - ts ))
  [ "$age" -lt "$window" ]
}

has_fresh_intent() { # 0 when some release intent is still authoritative
  local intent
  for intent in "$REL_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    intent_is_fresh "$intent" && return 0
  done
  return 1
}

RESTORE_PREFIX="$MAIN_ROOT/.powerflow/.integration-lock.restore"

restore_intent_window() { # seconds a restore claim stays authoritative
  # A restore is a short filesystem move, so it gets its own small window
  # (overridable for tests) rather than a full lease window; a crashed
  # restorer must not strand the queue for --stale-after seconds.
  local w="${POWERFLOW_RESTORE_INTENT_WINDOW:-60}"
  [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -ge 1 ] || w=60
  [ "$w" -le "$INTENT_MAX_WINDOW" ] || w="$INTENT_MAX_WINDOW"
  printf '%s' "$w"
}

has_fresh_restore_intent() { # 0 when a restore claim is still active
  local intent
  for intent in "$RESTORE_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    intent_is_fresh "$intent" && return 0
  done
  return 1
}

stale_restore_intent_for() { # <aside> <token> -> prints a matching stale claim
  # A restore claim authorizes resuming ONLY the exact parked lease it named:
  # same ASIDE basename and same parked TOKEN. A stale claim for another aside
  # (or another token in the same aside) proves nothing about this one.
  local aside="$1" tok="$2" intent itok
  for intent in "$RESTORE_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    intent_is_fresh "$intent" && continue
    [ "$(intent_field "$intent" ASIDE)" = "${aside##*/}" ] || continue
    itok=$(intent_field "$intent" TOKEN)
    [ "${itok:--}" = "${tok:--}" ] || continue
    printf '%s' "$intent"
    return 0
  done
  return 1
}

remove_stale_restore_claims_for() { # <aside> <token> — drop resolved claims only
  local aside="$1" tok="$2" intent itok
  for intent in "$RESTORE_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    [ "$(intent_field "$intent" ASIDE)" = "${aside##*/}" ] || continue
    itok=$(intent_field "$intent" TOKEN)
    [ "${itok:--}" = "${tok:--}" ] || continue
    intent_is_fresh "$intent" && continue
    rm -f "$intent" 2>/dev/null || true
  done
}

move_aside_into_lock() { # <aside> <target> -> 0 moved, info last
  local aside="$1" target="$2" entry
  [ -d "$aside" ] && [ -f "$aside/info" ] || return 1
  for entry in "$aside"/* "$aside"/.[!.]* "$aside"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$(basename "$entry")" = "info" ] && continue
    mv -f "$entry" "$target"/ 2>/dev/null || true
  done
  mv -f "$aside/info" "$target/info" 2>/dev/null || return 1
  rmdir "$aside" 2>/dev/null || true
  return 0
}

restore_aside() { # restore_aside <aside> -> 0 restored into the lock path
  # Single-winner restore without a non-portable rename-if-absent: mkdir is
  # the election for the lock path (acquirers seeing an existing-but-unreadable
  # dir wait, they never reset it), then the parked lease is moved back. info
  # is moved last so a half-restored dir is never mistaken for a valid lease.
  #
  # The claim is itself recoverable: a restore intent is published BEFORE the
  # mkdir, so a restorer killed between mkdir and the info move leaves behind
  # an empty $LOCK_DIR plus a (soon stale) intent. The next restorer can then
  # tell an abandoned partial claim from an active one — same stale-versus-live
  # discipline as release intents — and resume it instead of stalling forever.
  local aside="$1" entry tok ri ri_tmp ri_id
  [ -d "$aside" ] && [ -f "$aside/info" ] || return 1
  tok=$(intent_field "$aside/info" TOKEN)
  ri_id="$$.$(now_s).$RANDOM"
  ri="$RESTORE_PREFIX.$ri_id.intent"
  ri_tmp="$MAIN_ROOT/.powerflow/.restore-intent.$ri_id"
  rm -f "$ri_tmp" 2>/dev/null || true
  if ! printf 'PID=%s\nSINCE=%s\nWINDOW=%s\nTOKEN=%s\nASIDE=%s\n' \
        "$$" "$(now_s)" "$(restore_intent_window)" "${tok:--}" "${aside##*/}" > "$ri_tmp" \
     || ! mv -f "$ri_tmp" "$ri" 2>/dev/null; then
    rm -f "$ri_tmp" 2>/dev/null || true
    return 1
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    # Test seam: hold the claim after winning the mkdir election, so a test can
    # verify another restorer backs off instead of nesting its aside inside.
    if [[ "${POWERFLOW_TEST_PAUSE_RESTORE_AFTER_MKDIR:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_RESTORE_AFTER_MKDIR:-0}" -gt 0 ]; then
      sleep "$POWERFLOW_TEST_PAUSE_RESTORE_AFTER_MKDIR"
    fi
    if [ "${POWERFLOW_TEST_DIE_IN_RESTORE_AFTER_MKDIR:-0}" = "1" ]; then
      # Simulate a restorer crash after winning the election, before info is
      # moved: leave the empty claim and our restore intent behind.
      exit 99
    fi
    if move_aside_into_lock "$aside" "$LOCK_DIR"; then
      rm -f "$ri" 2>/dev/null || true
      remove_stale_restore_claims_for "$aside" "$tok"
      return 0
    fi
    # info move failed: roll back so the parked lease stays intact in the aside.
    for entry in "$LOCK_DIR"/* "$LOCK_DIR"/.[!.]* "$LOCK_DIR"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      mv -f "$entry" "$aside"/ 2>/dev/null || true
    done
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rm -f "$ri" 2>/dev/null || true
    return 1
  fi

  # Lost the election. Drop our own claim before judging the others.
  rm -f "$ri" 2>/dev/null || true
  # A real lease already owns the path: someone else completed a restore.
  [ -f "$LOCK_DIR/info" ] && return 1
  # Another restorer is mid-restore or merely paused: wait for it.
  has_fresh_restore_intent && return 1
  # No active claim, but $LOCK_DIR is empty. A restorer may have died after
  # winning the mkdir. Resume ONLY if an abandoned claim names THIS aside and
  # THIS token — an unrelated stale claim must not authorize moving another
  # lease into the abandoned dir.
  if stale_restore_intent_for "$aside" "$tok" >/dev/null \
     && move_aside_into_lock "$aside" "$LOCK_DIR"; then
    remove_stale_restore_claims_for "$aside" "$tok"
    return 0
  fi
  return 1
}

recover_asides() { # recover_asides -> 0 clear, 3 release/restore in progress or live lease parked
  # Never blind-delete an aside: it may be the active workspace of a paused
  # release. Fresh release intents block acquisition; fresh leases parked in
  # an aside are restored, not deleted; only stale artifacts are discarded.
  # A restore that died mid-claim is resumed by restore_aside (see below).
  local intent aside holder since hb tok expected force blocked=0
  # 1. Intent with no aside: crash/pause before the move. Fresh => release is
  #    still in flight; stale => drop the intent and continue.
  for intent in "$REL_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    aside="${intent%.intent}"
    [ -d "$aside" ] && continue
    if intent_is_fresh "$intent"; then
      echo "WARNING: release in progress (${aside##*/}) — waiting." >&2
      return 3
    fi
    rm -f "$intent" 2>/dev/null || true
  done

  # 2. Release asides. A fresh intent means the releaser is still working;
  #    deleting here is the three-process race (a third acquirer deleting the
  #    replacement lease parked by a late release). With a stale intent (or
  #    none) recovery applies: finish an intended release, restore a live
  #    displaced lease, discard a stale one.
  for aside in "$REL_PREFIX".*; do
    [ -d "$aside" ] || continue
    intent="$aside.intent"
    if [ -f "$intent" ] && intent_is_fresh "$intent"; then
      echo "WARNING: release in progress (${aside##*/}) — waiting." >&2
      return 3
    fi
    expected=""; force=""
    if [ -f "$intent" ]; then
      expected=$(intent_field "$intent" TOKEN)
      force=$(intent_field "$intent" FORCE)
    fi
    if holder=$(read_info_at "$aside/info"); then
      # shellcheck disable=SC2086
      set -- $holder
      since="$3"; hb="${4:-}"; tok="${5:-}"
      if ! lock_is_stale "$since" "$hb"; then
        # A live lease is parked here. If the abandoned intent names it, the
        # owner asked to release it; otherwise a late release displaced a
        # replacement lease, which must be restored.
        if [ -n "$expected" ] && [ "$expected" != "-" ] && [ "$tok" = "$expected" ]; then
          rm -rf "$aside" 2>/dev/null || true
          rm -f "$intent" 2>/dev/null || true
          continue
        fi
        if [ "$force" = "true" ]; then
          rm -rf "$aside" 2>/dev/null || true
          rm -f "$intent" 2>/dev/null || true
          continue
        fi
        if restore_aside "$aside"; then
          rm -f "$intent" 2>/dev/null || true
          echo "WARNING: restored live lease (task '$2') parked in release aside." >&2
        else
          echo "Error: live lease (task '$2') is parked in release aside ${aside##*/}; treating lock as held." >&2
        fi
        blocked=1
        continue
      fi
    fi
    rm -rf "$aside" 2>/dev/null || true
    rm -f "$intent" 2>/dev/null || true
  done

  # 3. Takeover asides normally hold a verified-stale lease, but a raced
  #    takeover can park a live replacement lease here. Same rule.
  for aside in "$STALE_PREFIX".*; do
    [ -d "$aside" ] || continue
    if holder=$(read_info_at "$aside/info"); then
      # shellcheck disable=SC2086
      set -- $holder
      since="$3"; hb="${4:-}"
      if ! lock_is_stale "$since" "$hb"; then
        if restore_aside "$aside"; then
          echo "WARNING: restored live lease (task '$2') parked in takeover aside." >&2
        else
          echo "Error: live lease (task '$2') is parked in takeover aside ${aside##*/}; treating lock as held." >&2
        fi
        blocked=1
        continue
      fi
    fi
    rm -rf "$aside" 2>/dev/null || true
  done

  # 4. Drop restore intents whose parked aside is gone or whose restore was
  #    superseded by a valid lease, so abandoned claims cannot pile up. A
  #    stale intent whose aside is still parked and unresolved is left for
  #    restore_aside to resume.
  for intent in "$RESTORE_PREFIX".*.intent; do
    [ -f "$intent" ] || continue
    intent_is_fresh "$intent" && continue
    aside=$(intent_field "$intent" ASIDE)
    if [ -n "$aside" ] && [ -d "$MAIN_ROOT/.powerflow/$aside" ] && [ ! -f "$LOCK_DIR/info" ]; then
      continue
    fi
    rm -f "$intent" 2>/dev/null || true
  done
  # Keep scanning past a blocked aside so a later aside with a matching
  # abandoned claim can still make progress; report held if any remained.
  [ "$blocked" -eq 0 ] || return 3
  return 0
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
  # dir is believed absent (initial try, post-own-rename, post-recovery).
  # Unsettled states retry briefly, then report held; a genuinely orphaned
  # dir needs an operator `release --force`.
  ACQUIRED_MODE=""
  ACQUIRED_TOKEN=""
  mkdir -p "$MAIN_ROOT/.powerflow"
  local attempt holder pid task since hb tok eff aside moved_tokens
  for attempt in 1 2 3 4 5 6 7 8; do
    # Recover asides left by a crashed takeover/release. A fresh release
    # intent makes us wait instead of creating a lock in the recovery gap; a
    # fresh lease parked in an aside is restored, never deleted.
    if ! recover_asides; then
      sleep 0.2
      continue
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Dir was absent: free lock (or a takeover/restore gap someone must
      # fill). mkdir is the only election; an existing dir is never reset.
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
      # Test seam: pause after the stale verdict, before the rename, so a test
      # can let a second thief install a replacement lease in between.
      if [[ "${POWERFLOW_TEST_PAUSE_TAKEOVER_BEFORE_MOVE:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_TAKEOVER_BEFORE_MOVE:-0}" -gt 0 ]; then
        sleep "$POWERFLOW_TEST_PAUSE_TAKEOVER_BEFORE_MOVE"
      fi
      aside="$MAIN_ROOT/.powerflow/.integration-lock.stale.$$.$(now_s).$RANDOM"
      rm -rf "$aside" 2>/dev/null || true
      if ! mv "$LOCK_DIR" "$aside" 2>/dev/null; then
        # Rename lost: another thief is mid-takeover, or the owner is
        # writing. Re-read on the next attempt instead of deciding now.
        sleep 0.2
        continue
      fi
      # Test seam: pause after the rename, before verification, so a test can
      # race a concurrent restore of the parked lease.
      if [[ "${POWERFLOW_TEST_PAUSE_TAKEOVER_AFTER_MOVE:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_TAKEOVER_AFTER_MOVE:-0}" -gt 0 ]; then
        sleep "$POWERFLOW_TEST_PAUSE_TAKEOVER_AFTER_MOVE"
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
        # Hand the displaced lease to the SAME single-winner restore used by
        # release and acquire recovery: mkdir elects who owns $LOCK_DIR, so a
        # check-then-move can never nest our aside INSIDE a replacement lock
        # dir another process just created. The loser leaves the aside
        # parked for recover_asides instead of touching it.
        if ! restore_aside "$aside"; then
          echo "WARNING: displaced lease left parked in ${aside##*/} for recovery." >&2
        fi
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
      # Dir exists but info unreadable (mid-write/mid-takeover/mid-restore):
      # wait out the transient, never reset blindly.
      sleep 0.2
      continue
    fi
    # Dir absent with no readable info: a takeover or restore is in flight.
    # The next iteration's recover_asides + mkdir settles it — a stale aside
    # is cleaned and a live parked lease is restored — so just wait.
    sleep 0.2
  done
  echo "Error: integration lock unsettled after retries — treating as held. If no integrator is running, an operator may 'release --force'." >&2
  return 3
}

do_heartbeat() { # do_heartbeat -> 0 refreshed, 1 mismatch/gone
  # Refreshes the lease ONLY when task AND token both match the live lease —
  # a returning stale owner with the same slug but an old token is refused,
  # and another owner's lease is never clobbered (e.g. after a legitimate
  # steal). The token is preserved across refreshes.
  #
  # Check-then-act safety:
  # The heartbeat timestamp is written ONLY to a token-scoped file
  # (heartbeat.$TOKEN), NEVER rewriting info (the lease ownership metadata).
  # Even if delayed or paused, it cannot overwrite a replacement lease's
  # PID/TASK/TOKEN metadata. After writing, verify-after-write confirms our
  # lease is still active in $LOCK_DIR; if replaced during the write, the
  # stray file is cleaned up and exit 1 is returned so the caller detects
  # lease loss.
  local holder task since hb pid tok
  holder=$(lock_holder) || { echo "Error: no integration lock to refresh." >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $holder
  pid="$1"; task="$2"; since="$3"; hb="${4:-}"; tok="${5:-}"
  if [ "$task" != "$TASK" ] || [ "$tok" != "$TOKEN_REQ" ]; then
    echo "Error: lease owned by task '$task' (token ${tok:-none}) — heartbeat token does not match; not refreshing." >&2
    return 1
  fi

  # Test seam: inject pause right after token check to verify takeover race protection
  if [[ "${POWERFLOW_TEST_PAUSE_HEARTBEAT:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_HEARTBEAT:-0}" -gt 0 ]; then
    sleep "$POWERFLOW_TEST_PAUSE_HEARTBEAT"
  fi

  local tmp now
  now=$(now_s)
  tmp=$(mktemp "$LOCK_DIR/.hb.XXXXXX" 2>/dev/null) || { echo "Error: cannot refresh lock." >&2; return 1; }
  printf '%s\n' "$now" > "$tmp"
  if ! mv -f "$tmp" "$LOCK_DIR/heartbeat.$TOKEN_REQ" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "Error: cannot refresh lock (lease moved or unavailable)." >&2
    return 1
  fi

  # Verify-after-write: confirm our lease is still the active one in $LOCK_DIR.
  local verify_holder verify_task verify_tok
  if verify_holder=$(lock_holder); then
    # shellcheck disable=SC2086
    set -- $verify_holder
    verify_task="$2"; verify_tok="${5:-}"
    if [ "$verify_task" = "$TASK" ] && [ "$verify_tok" = "$TOKEN_REQ" ]; then
      return 0
    fi
  fi

  # Lease was replaced or removed while writing!
  rm -f "$LOCK_DIR/heartbeat.$TOKEN_REQ" 2>/dev/null || true
  echo "Error: integration lock changed hands during heartbeat; lease lost." >&2
  return 1
}

do_release() { # do_release -> 0 released/already-free, 1 mismatch
  # Deletes the lease ONLY when task AND token both match — unless --force
  # (explicit operator break, which skips the token check). A stale owner
  # returning for the same slug with an old token can never delete the new
  # lease via a trap release.
  #
  # Check-then-act safety:
  # Uses verify-after-move: instead of check-then-delete on the shared path
  # (which races against a concurrent takeover replacing the lease between
  # check and deletion), the lock dir is atomically renamed aside first.
  # If the moved lease's token does not match, it is restored and release
  # is refused with exit 1 without harming the replacement lease.
  #
  # The release intent is published BEFORE the rename. It tells concurrent
  # acquires that this aside is an active release workspace: they wait while
  # it is fresh instead of filling the gap or cleaning the aside, and only a
  # stale intent is recovered as a crashed release.
  local holder task tok
  if [ "$FORCE" = false ]; then
    if ! holder=$(lock_holder); then
      echo "Integration lock already free." >&2
      return 0
    fi
    # shellcheck disable=SC2086
    set -- $holder
    task="$2"; tok="${5:-}"
    if [ "$task" != "$TASK" ] || [ "$tok" != "$TOKEN_REQ" ]; then
      echo "Error: lease owned by task '$task' (token ${tok:-none}) — release token does not match. Use --force to break it." >&2
      return 1
    fi
  fi

  # Test seam: inject pause right after token check to verify takeover race protection
  if [[ "${POWERFLOW_TEST_PAUSE_RELEASE:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_RELEASE:-0}" -gt 0 ]; then
    sleep "$POWERFLOW_TEST_PAUSE_RELEASE"
  fi

  local rel_id rel_aside rel_intent rel_intent_tmp
  rel_id="$$.$(now_s).$RANDOM"
  rel_aside="$REL_PREFIX.$rel_id"
  rel_intent="$rel_aside.intent"
  rel_intent_tmp="$MAIN_ROOT/.powerflow/.rel-intent.$rel_id"
  rm -f "$rel_intent_tmp" 2>/dev/null || true

  # Publish the intent BEFORE moving: concurrent acquires must see that this
  # aside is an active release workspace, not an orphan to clean. Written via
  # tmp+mv so readers never observe a partial record.
  if ! printf 'PID=%s\nSINCE=%s\nWINDOW=%s\nTOKEN=%s\nFORCE=%s\n' "$$" "$(now_s)" "$STALE_AFTER" "${TOKEN_REQ:--}" "$FORCE" > "$rel_intent_tmp" \
     || ! mv -f "$rel_intent_tmp" "$rel_intent" 2>/dev/null; then
    rm -f "$rel_intent_tmp" 2>/dev/null || true
    echo "Error: cannot record release intent." >&2
    return 1
  fi

  if ! mv "$LOCK_DIR" "$rel_aside" 2>/dev/null; then
    # Could not move: either already freed, or another process moved it.
    rm -f "$rel_intent" 2>/dev/null || true
    if [ ! -e "$LOCK_DIR" ]; then
      echo "Integration lock already free." >&2
      return 0
    fi
    echo "Error: integration lock unsettled during release." >&2
    return 1
  fi

  # Test seam: pause after the move, before token verification, so a test can
  # run a concurrent acquire exactly in the recovery gap.
  if [[ "${POWERFLOW_TEST_PAUSE_RELEASE_AFTER_MOVE:-0}" =~ ^[0-9]+$ ]] && [ "${POWERFLOW_TEST_PAUSE_RELEASE_AFTER_MOVE:-0}" -gt 0 ]; then
    sleep "$POWERFLOW_TEST_PAUSE_RELEASE_AFTER_MOVE"
  fi

  # Verify-after-move: check what was actually moved aside
  if [ "$FORCE" = false ]; then
    local moved_holder moved_task moved_tok
    if moved_holder=$(read_info_at "$rel_aside/info"); then
      # shellcheck disable=SC2086
      set -- $moved_holder
      moved_task="$2"; moved_tok="${5:-}"
      if [ "$moved_task" != "$TASK" ] || [ "$moved_tok" != "$TOKEN_REQ" ]; then
        echo "WARNING: release raced a replacement lease — restoring and refusing release." >&2
        if restore_aside "$rel_aside"; then
          echo "Error: lease owned by task '$moved_task' (token ${moved_tok:-none}) — release token does not match. Use --force to break it." >&2
        else
          echo "Error: cannot restore displaced lease; left parked in ${rel_aside##*/}. Use --force to break it." >&2
        fi
        rm -f "$rel_intent" 2>/dev/null || true
        return 1
      fi
    else
      # Info unreadable in the moved dir: never delete what we cannot verify.
      echo "Error: cannot verify lease in releasing dir; left parked in ${rel_aside##*/}." >&2
      rm -f "$rel_intent" 2>/dev/null || true
      return 1
    fi
  fi

  # Complete the release: drop the aside first, then the intent. A crash in
  # between leaves a fresh intent with no aside, which acquire waits out (it
  # times out like any stale lease) rather than risking a live lease.
  rm -rf "$rel_aside"
  rm -f "$rel_intent" 2>/dev/null || true
  echo "Integration lock released (was task '$TASK')." >&2
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
start_heartbeat_loop() { # start_heartbeat_loop <task> <token> — refreshes until stopped
  local hb_task="$1" hb_token="$2" every
  every=$(heartbeat_every)
  ( while true; do
      sleep "$every"
      bash "$0" heartbeat --task "$hb_task" --token "$hb_token" >/dev/null 2>&1 || true
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
    elif [ -e "$LOCK_DIR" ]; then
      # The lock path exists but has no readable lease: a restore claimed it
      # (mkdir election) and has not moved info in yet, or a restorer died mid-
      # claim. Never report a plain free lock while acquire would wait here.
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=recovering\n'
      echo "Integration lock path exists without lease metadata; a restore is in progress or pending recovery." >&2
    elif has_fresh_intent; then
      # The lock dir is absent because a release moved it aside and is still
      # working (or paused). Do not report a plain free lock while acquire
      # would wait for that release to finish.
      [ "$PORCELAIN_OUT" = true ] && printf 'LOCK=free\nRELEASE=in-progress\n'
      echo "Integration lock free but a release is in progress; acquire will wait." >&2
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
    start_heartbeat_loop "$TASK" "$ACQUIRED_TOKEN"
    set +e
    "${RUN_ARGS[@]}"
    CODE=$?
    set -e
    stop_heartbeat_loop
    # Release only if OUR token still holds it (a nested --force release, a
    # steal, or an operator break may have replaced it; never delete another
    # lease — not even one under the same task slug).
    # Uses verify-after-move via do_release:
    TOKEN_REQ="$ACQUIRED_TOKEN"
    if do_release >/dev/null 2>&1; then
      echo "Integration lock released (run mode, child exit $CODE)." >&2
    else
      echo "WARNING: lease now owned by another task or changed hands; leaving it (run mode)." >&2
    fi
    exit "$CODE"
    ;;
esac
