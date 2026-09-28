#!/usr/bin/env bash
#
# movePlots.sh - Move completed chia plot files (*.plot) from a source
# directory into a set of destination directories in round-robin order.
# Before each move, checks that the destination's filesystem has enough
# free space; if not, tries the next destination. Transfers run in the
# background so multiple plots can be moved concurrently (up to
# --parallel N at once, and at most one transfer per destination).
# Press q or Ctrl-C to quit: in-flight transfers are aborted and their
# partial files removed from the destinations.
#
# A "completed" plot is any *.plot file (chia renames *.plot.tmp to
# *.plot when plotting finishes), so in-progress plots are ignored.
#
# Usage:
#   ./movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]

set -u

INTERVAL="${MOVE_PLOTS_INTERVAL:-15}"
PARALLEL=2          # set by --parallel
KEYS_ENABLED=0      # 1 when executed with an interactive stdin (q quits)

ONCE=0
SOURCE=""
DESTS=()
VALID_DESTS=()
N=0
rr_index=0
ACTIVE_PIDS=()   # pids of in-flight transfers (parallel to ACTIVE_FILES/DESTS)
ACTIVE_FILES=()  # source paths currently being transferred
ACTIVE_DESTS=()  # destination directory each transfer is writing to

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

usage() {
  cat <<'EOF'
Usage: movePlots.sh [--once] [--parallel N] SOURCE_DIR DEST_DIR [DEST_DIR ...]

Moves completed chia plot files (*.plot) from SOURCE_DIR into the listed
destination directories in round-robin order. In-progress plots
(*.plot.tmp) are ignored. Before each move, the destination filesystem's
free space is checked; if a destination does not have enough room (or is
already receiving a transfer), the next one is tried. If no destination
is available, the file is left in place and retried later.

Moves run as background transfers so several plots can be moved at once,
but at most one transfer writes to a given destination at a time. While
running, press q to quit (Ctrl-C works too); in-flight transfers are then
aborted and any partial files removed from their destinations.

Options:
  --once         Move whatever plots are present now and exit (waits for
                 all transfers to finish) instead of watching SOURCE_DIR
                 continuously.
  --parallel N   Maximum number of concurrent transfers (default 2).
  -h, --help     Show this help.

Environment:
  MOVE_PLOTS_INTERVAL   Seconds between scans in watch mode (default 15).
EOF
}

file_size() { # bytes; BSD stat (macOS) then GNU stat
  if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi
}

free_kb() { # available kilobytes on the filesystem containing $1
  df -Pk "$1" | awk 'NR==2 {print $4}'
}

human_size() { # bytes -> human readable
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB", u, " "); i = 1; v = b
    while (v >= 1024 && i < 5) { v /= 1024; i++ }
    printf "%.1f %s", v, u[i]
  }'
}

human_duration() { # seconds -> "42s" or "3m 12s"
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  else
    printf '%sm %ss' $((s / 60)) $((s % 60))
  fi
}

# Drop finished transfers from the tracking lists. bash reaps its own
# background children, so once kill -0 fails the transfer is done and the
# child has already logged its outcome. (wait -n would be ideal but needs
# bash 4.3+, unavailable on macOS.)
reap_jobs() {
  local i pid keep_pids=() keep_files=() keep_dests=()
  [ ${#ACTIVE_PIDS[@]} -eq 0 ] && return 0
  for i in "${!ACTIVE_PIDS[@]}"; do
    pid="${ACTIVE_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      keep_pids+=("$pid")
      keep_files+=("${ACTIVE_FILES[$i]}")
      keep_dests+=("${ACTIVE_DESTS[$i]}")
    fi
  done
  if [ ${#keep_pids[@]} -gt 0 ]; then
    ACTIVE_PIDS=("${keep_pids[@]}")
    ACTIVE_FILES=("${keep_files[@]}")
    ACTIVE_DESTS=("${keep_dests[@]}")
  else
    ACTIVE_PIDS=()
    ACTIVE_FILES=()
    ACTIVE_DESTS=()
  fi
}

is_active() { # is $1 already being transferred?
  local f="$1" i
  [ ${#ACTIVE_FILES[@]} -eq 0 ] && return 1
  for i in "${!ACTIVE_FILES[@]}"; do
    [ "${ACTIVE_FILES[$i]}" = "$f" ] && return 0
  done
  return 1
}

dest_busy() { # is $1 already receiving a transfer?
  local d="$1" i
  [ ${#ACTIVE_DESTS[@]} -eq 0 ] && return 1
  for i in "${!ACTIVE_DESTS[@]}"; do
    [ "${ACTIVE_DESTS[$i]}" = "$d" ] && return 0
  done
  return 1
}

pending_count() { # *.plot files in SOURCE not already being transferred
  local f n=0
  shopt -s nullglob
  for f in "$SOURCE"/*.plot; do
    [ -f "$f" ] || continue
    is_active "$f" || n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

# Block for about one second, then reap finished transfers. When stdin is
# interactive, a keypress is read instead of sleeping and 'q' returns 1
# (quit requested). If stdin closes mid-run, fall back to plain sleeping.
poll_tick() {
  local key rc
  if [ "$KEYS_ENABLED" -eq 1 ]; then
    rc=0
    read -rsn1 -t 1 key 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      case "$key" in q|Q) return 1 ;; esac
    elif [ "$rc" -le 128 ]; then
      KEYS_ENABLED=0 # stdin closed (e.g. Ctrl-D): stop reading keys
      sleep 1
    fi
  else
    sleep 1
  fi
  reap_jobs
  return 0
}

# Background worker for one move. Logs the start (source -> destination) and,
# on success, the completion with size and duration. If mv fails, the source
# file is still in place (mv copies then deletes), so any partial file at the
# destination is ours to remove; if the source is gone the copy had completed
# and the destination file is kept.
transfer() {
  local f="$1" dest="$2" bytes="$3" base start elapsed
  base=$(basename "$f")
  log "${base}: moving to ${dest}"
  start=$(date +%s)
  if mv -- "$f" "$dest/"; then
    elapsed=$(( $(date +%s) - start ))
    log "${base}: moved to ${dest} ($(human_size "$bytes") in $(human_duration "$elapsed"))"
  else
    [ -f "$f" ] && rm -f "${dest}/${base}" 2>/dev/null
    log "Error: failed to move '$f' to '$dest'"
  fi
  return 0
}

# Kill in-flight transfers and remove their partial destination files. A
# transfer whose source file is already gone had finished copying, so its
# destination file is complete and kept.
abort_transfers() {
  local i pid f dest base n
  [ ${#ACTIVE_PIDS[@]} -eq 0 ] && return 0
  for i in "${!ACTIVE_PIDS[@]}"; do
    pid="${ACTIVE_PIDS[$i]}"
    pkill -P "$pid" 2>/dev/null || true # the mv child of the worker subshell
    kill "$pid" 2>/dev/null || true
  done
  for i in "${!ACTIVE_PIDS[@]}"; do
    pid="${ACTIVE_PIDS[$i]}"
    f="${ACTIVE_FILES[$i]}"
    dest="${ACTIVE_DESTS[$i]}"
    base=$(basename "$f")
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    if [ -f "$f" ]; then
      rm -f "${dest}/${base}" 2>/dev/null || true
      log "$(basename "$f"): transfer interrupted, partial file removed from ${dest}"
    else
      log "$(basename "$f"): finished during shutdown, kept in ${dest}"
    fi
  done
  ACTIVE_PIDS=()
  ACTIVE_FILES=()
  ACTIVE_DESTS=()
  return 0
}

# Quit handler for 'q' and for INT/TERM: abort in-flight transfers, clean
# up partial files, then exit with the given code.
on_quit() {
  local code="${1:-0}"
  log "Shutting down; aborting ${#ACTIVE_PIDS[@]} in-flight transfer(s)"
  abort_transfers
  trap - INT TERM
  exit "$code"
}

start_transfer() { # launch a background transfer for $1; returns 1 if no dest is available right now
  local f="$1" bytes size_kb i dest free pid
  bytes=$(file_size "$f") || return 1
  size_kb=$(( (bytes + 1023) / 1024 ))

  for ((i = 0; i < N; i++)); do
    dest="${VALID_DESTS[$(( (rr_index + i) % N ))]}"
    dest_busy "$dest" && continue # one transfer per destination at a time
    free=$(free_kb "$dest") || continue
    [ "$free" -lt "$size_kb" ] && continue # silently skip: not enough room
    rr_index=$(( (rr_index + i + 1) % N )) # reserve the destination up front
    transfer "$f" "$dest" "$bytes" &
    pid=$!
    ACTIVE_PIDS+=("$pid")
    ACTIVE_FILES+=("$f")
    ACTIVE_DESTS+=("$dest")
    return 0
  done

  return 1 # no destination available right now (busy or low on space): retry later
}

scan_source() { # start transfers for pending plots, up to the concurrency limit
  local f
  reap_jobs
  shopt -s nullglob
  for f in "$SOURCE"/*.plot; do
    [ -f "$f" ] || continue
    is_active "$f" && continue
    if [ ${#ACTIVE_PIDS[@]} -ge "$PARALLEL" ]; then break; fi
    start_transfer "$f" || continue # no destination available right now: not a failure
  done
  shopt -u nullglob
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --once) ONCE=1; shift ;;
      --parallel)
        if [ $# -lt 2 ]; then
          log "Error: --parallel requires a value"
          usage >&2
          exit 1
        fi
        PARALLEL="$2"; shift 2 ;;
      --parallel=*) PARALLEL="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done

  case "$PARALLEL" in
    ''|*[!0-9]*|0)
      log "Error: --parallel must be a positive integer (got '$PARALLEL')"
      usage >&2
      exit 1 ;;
  esac

  if [ $# -lt 2 ]; then
    usage >&2
    exit 1
  fi

  SOURCE="$1"; shift
  DESTS=("$@")

  if [ ! -d "$SOURCE" ]; then
    log "Error: source directory '$SOURCE' does not exist"
    exit 1
  fi

  local d before end quit_hint
  for d in "${DESTS[@]}"; do
    if [ -d "$d" ]; then
      VALID_DESTS+=("$d")
    else
      log "Warning: destination '$d' does not exist - skipping"
    fi
  done

  if [ ${#VALID_DESTS[@]} -eq 0 ]; then
    log "Error: no valid destination directories given"
    exit 1
  fi
  N=${#VALID_DESTS[@]}

  if [ "$ONCE" -eq 1 ]; then
    scan_source
    while :; do
      [ ${#ACTIVE_PIDS[@]} -eq 0 ] && break
      before=${#ACTIVE_PIDS[@]}
      poll_tick || on_quit 0 # 'q' pressed: abort transfers and exit
      [ ${#ACTIVE_PIDS[@]} -lt "$before" ] && scan_source # a slot freed
    done
    wait
    if [ "$(pending_count)" -gt 0 ]; then return 1; fi
    return 0
  fi

  quit_hint="Ctrl-C"
  [ "$KEYS_ENABLED" -eq 1 ] && quit_hint="q (or Ctrl-C)"
  log "Watching '$SOURCE' -> ${VALID_DESTS[*]} (every ${INTERVAL}s, up to ${PARALLEL} concurrent transfer(s), one per destination; press ${quit_hint} to quit)"
  while true; do
    scan_source
    end=$((SECONDS + INTERVAL))
    while [ "$SECONDS" -lt "$end" ]; do
      poll_tick || on_quit 0 # 'q' pressed: abort transfers and exit
    done
  done
}

# Run main only when executed, not when sourced (so tests can stub functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [ -t 0 ] && KEYS_ENABLED=1 # 'q' only works with an interactive stdin
  trap 'on_quit 130' INT
  trap 'on_quit 143' TERM
  main "$@"
fi
