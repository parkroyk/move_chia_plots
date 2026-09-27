#!/usr/bin/env bash
#
# movePlots.sh - Move completed chia plot files (*.plot) from a source
# directory into a set of destination directories in round-robin order.
# Before each move, checks that the destination's filesystem has enough
# free space; if not, tries the next destination. Transfers run in the
# background so multiple plots can be moved concurrently (up to
# MOVE_PLOTS_PARALLEL at once).
#
# A "completed" plot is any *.plot file (chia renames *.plot.tmp to
# *.plot when plotting finishes), so in-progress plots are ignored.
#
# Usage:
#   ./movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]

set -u

INTERVAL="${MOVE_PLOTS_INTERVAL:-15}"
PARALLEL="${MOVE_PLOTS_PARALLEL:-2}"
case "$PARALLEL" in ''|*[!0-9]*|0) PARALLEL=2 ;; esac

ONCE=0
SOURCE=""
DESTS=()
VALID_DESTS=()
N=0
rr_index=0
ACTIVE_PIDS=()   # pids of in-flight transfers (parallel to ACTIVE_FILES)
ACTIVE_FILES=()  # source paths currently being transferred
LAST_STARTED=0   # transfers launched by the most recent scan

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

usage() {
  cat <<'EOF'
Usage: movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]

Moves completed chia plot files (*.plot) from SOURCE_DIR into the listed
destination directories in round-robin order. In-progress plots
(*.plot.tmp) are ignored. Before each move, the destination filesystem's
free space is checked; if a destination does not have enough room, the
next one is tried. If no destination has room, the file is left in place
and retried later.

Moves run as background transfers so several plots can be moved at once.

Options:
  --once   Move whatever plots are present now and exit (waits for all
           transfers to finish) instead of watching SOURCE_DIR continuously.
  -h       Show this help.

Environment:
  MOVE_PLOTS_INTERVAL   Seconds between scans in watch mode (default 15).
  MOVE_PLOTS_PARALLEL   Maximum number of concurrent transfers (default 2).
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

# Drop finished transfers from the tracking lists. bash reaps its own
# background children, so once kill -0 fails the transfer is done and the
# child has already logged its outcome. (wait -n would be ideal but needs
# bash 4.3+, unavailable on macOS.)
reap_jobs() {
  local i pid keep_pids=() keep_files=()
  [ ${#ACTIVE_PIDS[@]} -eq 0 ] && return 0
  for i in "${!ACTIVE_PIDS[@]}"; do
    pid="${ACTIVE_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      keep_pids+=("$pid")
      keep_files+=("${ACTIVE_FILES[$i]}")
    fi
  done
  if [ ${#keep_pids[@]} -gt 0 ]; then
    ACTIVE_PIDS=("${keep_pids[@]}")
    ACTIVE_FILES=("${keep_files[@]}")
  else
    ACTIVE_PIDS=()
    ACTIVE_FILES=()
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

# Sleep one poll tick, then reap. Returns 0 if at least one transfer finished.
wait_for_progress() {
  local before=${#ACTIVE_PIDS[@]}
  sleep 1
  reap_jobs
  [ ${#ACTIVE_PIDS[@]} -lt "$before" ]
}

start_transfer() { # launch a background mv for $1; returns 1 if no dest had room
  local f="$1" bytes size_kb i dest free pid
  bytes=$(file_size "$f") || return 1
  size_kb=$(( (bytes + 1023) / 1024 ))

  for ((i = 0; i < N; i++)); do
    dest="${VALID_DESTS[$(( (rr_index + i) % N ))]}"
    free=$(free_kb "$dest") || continue
    if [ "$free" -lt "$size_kb" ]; then
      log "$(basename "$f"): ${dest} has only $(human_size $((free * 1024))) free, needs $(human_size "$bytes") - trying next destination"
      continue
    fi
    rr_index=$(( (rr_index + i + 1) % N )) # reserve the destination up front
    (
      if mv -- "$f" "$dest/"; then
        log "$(basename "$f"): moved to ${dest} ($(human_size "$bytes"))"
      else
        log "Error: failed to move '$f' to '$dest'"
      fi
    ) &
    pid=$!
    ACTIVE_PIDS+=("$pid")
    ACTIVE_FILES+=("$f")
    return 0
  done

  log "$(basename "$f"): no destination has enough space ($(human_size "$bytes")); will retry"
  return 1
}

scan_source() { # start transfers for pending plots, up to the concurrency limit
  local f failed=0 quiet="${1:-}"
  LAST_STARTED=0
  reap_jobs
  shopt -s nullglob
  for f in "$SOURCE"/*.plot; do
    [ -f "$f" ] || continue
    is_active "$f" && continue
    if [ ${#ACTIVE_PIDS[@]} -ge "$PARALLEL" ]; then break; fi
    if start_transfer "$f"; then
      LAST_STARTED=$((LAST_STARTED + 1))
    else
      failed=1
    fi
  done
  shopt -u nullglob
  # With "quiet" (used by --once polling), skip no-op summaries.
  if [ -z "$quiet" ] || [ "$LAST_STARTED" -gt 0 ] || [ "$failed" -gt 0 ]; then
    log "Scan: $LAST_STARTED transfer(s) started, ${#ACTIVE_PIDS[@]} in flight, $failed failure(s)"
  fi
  return $failed
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --once) ONCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done

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

  local d
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
      wait_for_progress || continue # slots still full: keep waiting
      scan_source quiet             # a slot freed: start more pending plots
    done
    wait
    if [ "$(pending_count)" -gt 0 ]; then return 1; fi
    return 0
  fi

  log "Watching '$SOURCE' -> ${VALID_DESTS[*]} (every ${INTERVAL}s, up to ${PARALLEL} concurrent transfer(s); Ctrl-C to stop)"
  while true; do
    scan_source
    sleep "$INTERVAL"
  done
}

# Run main only when executed, not when sourced (so tests can stub functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
