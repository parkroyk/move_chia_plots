#!/usr/bin/env bash
#
# movePlots.sh - Move completed chia plot files (*.plot) from a source
# directory into a set of destination directories in round-robin order.
# Before each move, checks that the destination's filesystem has enough
# free space; if not, tries the next destination.
#
# A "completed" plot is any *.plot file (chia renames *.plot.tmp to
# *.plot when plotting finishes), so in-progress plots are ignored.
#
# Usage:
#   ./movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]

set -u

INTERVAL="${MOVE_PLOTS_INTERVAL:-15}"
ONCE=0
SOURCE=""
DESTS=()
VALID_DESTS=()
N=0
rr_index=0

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

usage() {
  cat <<'EOF'
Usage: movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]

Moves completed chia plot files (*.plot) from SOURCE_DIR into the listed
destination directories in round-robin order. In-progress plots
(*.plot.tmp) are ignored. Before each move, the destination filesystem's
free space is checked; if a destination does not have enough room, the
next one is tried. If no destination has room, the file is left in place
and retried on the next scan.

Options:
  --once   Move whatever plots are present now and exit, instead of
           watching SOURCE_DIR continuously.
  -h       Show this help.

Environment:
  MOVE_PLOTS_INTERVAL  Seconds between scans in watch mode (default 15).
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

move_plot() {
  local f="$1" bytes size_kb i dest free
  bytes=$(file_size "$f") || return 1
  size_kb=$(( (bytes + 1023) / 1024 ))

  for ((i = 0; i < N; i++)); do
    dest="${VALID_DESTS[$(( (rr_index + i) % N ))]}"
    free=$(free_kb "$dest") || continue
    if [ "$free" -lt "$size_kb" ]; then
      log "$(basename "$f"): ${dest} has only $(human_size $((free * 1024))) free, needs $(human_size "$bytes") - trying next destination"
      continue
    fi
    if mv -- "$f" "$dest/"; then
      rr_index=$(( (rr_index + i + 1) % N )) # next file starts after the one used
      log "$(basename "$f"): moved to ${dest} ($(human_size "$bytes"))"
      return 0
    fi
    log "Error: failed to move '$f' to '$dest'"
    return 1
  done

  log "$(basename "$f"): no destination has enough space ($(human_size "$bytes")); will retry"
  return 1
}

scan_source() {
  local f moved=0 failed=0
  shopt -s nullglob
  for f in "$SOURCE"/*.plot; do
    [ -f "$f" ] || continue
    if move_plot "$f"; then
      moved=$((moved + 1))
    else
      failed=1
    fi
  done
  shopt -u nullglob
  log "Scan: $moved plot(s) moved, $failed failure(s)"
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
    return $?
  fi

  log "Watching '$SOURCE' -> ${VALID_DESTS[*]} (every ${INTERVAL}s; Ctrl-C to stop)"
  while true; do
    scan_source
    sleep "$INTERVAL"
  done
}

# Run main only when executed, not when sourced (so tests can stub functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
