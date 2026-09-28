# QWEN.md

## Project Overview

A single-file Bash utility (`movePlots.sh`) that moves completed [Chia](https://www.chia.net/) plot files (`*.plot`) from a source directory into one or more destination directories in **round-robin** order. Before each move it checks the destination filesystem's free space (via `df`); if a destination lacks room, the next is tried, and if none has room the file is left for later. Moves run as background transfers — up to `--parallel N` (default 2) concurrently, at most one per destination — so a slow cross-filesystem copy doesn't block other plots. Each transfer logs its start (source -> destination) and completion with size and duration; a destination without enough room is skipped silently (not a failure). Pressing `q` or Ctrl-C aborts in-flight transfers and removes their partial files from the destinations. By default it runs as a watcher re-scanning every 15 seconds; `--once` processes what's present and waits for all in-flight transfers before exiting.

## File Layout

```
movePlots.sh   # The entire program — one bash script
README.md      # Usage docs, options, environment variables, examples
LICENSE        # MIT (Copyright 2026 Roy Park)
```

There is no build system, no dependencies beyond standard utilities (`df`, `stat`, `awk`, `mv`, `pkill`), and no test suite.

## Running

```bash
# Watch mode (default): keep moving plots as they complete
./movePlots.sh /path/to/source /path/dest1 /path/dest2 ...

# Single pass: move what's present now, then exit
./movePlots.sh --once /path/to/source /path/dest1 /path/dest2 ...

# Custom scan interval (seconds)
MOVE_PLOTS_INTERVAL=5 ./movePlots.sh /path/to/source /path/dest1

# More concurrent transfers (default 2; at most one per destination)
./movePlots.sh --parallel 4 /path/to/source /path/dest1 /path/dest2
```

- `SOURCE_DIR` must exist; nonexistent destinations are skipped with a warning.
- Exit codes: 0 on success/help or a clean `q` quit, 1 on usage errors or if no valid destination exists, 130/143 when interrupted by Ctrl-C/TERM (after partial files are cleaned up).

## Key Implementation Details

- **Portability constraint (important):** the script is tested on macOS with **bash 3.2** and must keep working there. Avoid bash 4+ features (associative arrays, `mapfile`, `${var,,}`, etc.).
- **BSD/GNU dual support:** `file_size()` tries BSD `stat -f%z` first, then GNU `stat -c%s`. `free_kb()` uses `df -Pk` (POSIX kilobytes) so it works on both platforms. Keep this pattern when touching stat/df calls.
- **Async transfers:** each move runs in a backgrounded `transfer()` worker; the parent tracks PIDs/paths/destinations in `ACTIVE_PIDS`/`ACTIVE_FILES`/`ACTIVE_DESTS` and reaps via `kill -0` polling because `wait -n` needs bash 4.3+ (unavailable on macOS). The worker logs its own success/failure through `log()`; if `mv` fails while the source still exists it removes the partial destination file. On quit (`q`/Ctrl-C), `abort_transfers` kills each worker with `pkill -P` + `kill` — killing only the worker subshell would orphan its `mv` child — then removes partials for transfers whose source file is still present (source gone = copy completed, keep it).
- **bash 3.2 + `set -u` gotcha:** expanding an *empty* array with `"${arr[@]}"` errors as unbound before bash 4.4. Guard such expansions with a length check first (see `reap_jobs`, `is_active`).
- **Round-robin state** (`rr_index`) is in memory only; a restart resumes at the first destination. Rotation advances when a transfer *starts* (the destination is reserved up front), not when it finishes, so a failed transfer doesn't pile the next file onto the same destination. A destination with an in-flight transfer is skipped (one transfer per destination). Free space is checked at start only — if two destinations share a filesystem they can still contend, and a loser fails and is retried later.
- **In-progress plots are ignored:** only `*.plot` files match; Chia renames `*.plot.tmp` → `.plot` on completion. Files already being transferred are skipped by later scans (`is_active`).
- **Cross-filesystem moves** (`mv`) copy then delete — slow by nature, not a bug.
- The script ends with an `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard so it can be **sourced without executing `main`** (the comment says this is so tests can stub functions). Preserve this guard if adding tests that source the file.

## Development Conventions

- Style: plain procedural bash, `set -u`, small helper functions (`log`, `usage`, `file_size`, `free_kb`, `human_size`, `human_duration`, `reap_jobs`, `is_active`, `dest_busy`, `pending_count`, `poll_tick`, `transfer`, `abort_transfers`, `on_quit`, `start_transfer`, `scan_source`, `main`), local variables declared per function with `local`.
- All user-facing output goes through `log()` which prepends a timestamp.
- Keep the README in sync when changing flags, environment variables, or behavior — it documents the CLI contract (options table, examples, sample output).
- Commit messages: descriptive sentence case naming files and purpose (e.g., "Initial commit: movePlots.sh with README and MIT license").

## Verification

There is no test harness. To verify changes: run `bash -n movePlots.sh` for syntax, then exercise the script against temp directories, e.g.:

```bash
bash -n movePlots.sh
mkdir -p /tmp/mp/src /tmp/mp/d1 /tmp/mp/d2
touch /tmp/mp/src/a.plot /tmp/mp/src/b.plot /tmp/mp/src/c.tmp
./movePlots.sh --once /tmp/mp/src /tmp/mp/d1 /tmp/mp/d2
```

To test transfer behavior (concurrency, retries) without slow real copies, source the script and stub functions — set env vars *before* sourcing, since `INTERVAL` is read at source time. The stub must accept the `--` that `transfer()` passes to `mv`:

```bash
bash -c '
  source ./movePlots.sh          # guard prevents main from running
  mv() { [ "$1" = "--" ] && shift; sleep 3; command mv -- "$@"; }   # simulate slow transfers
  main --once --parallel 2 /tmp/mp/src /tmp/mp/d1 /tmp/mp/d2
'
```

Stubbing `free_kb() { echo 0; }` exercises the silent no-space skip and confirms `--once` exits (code 1) instead of looping forever. To test quit/cleanup, stub `mv` so it writes a partial destination file first (`dd if=/dev/zero of="$dst/$base" bs=1k count=8`) and stalls, then send `kill -TERM` to the script's PID — SIGINT can't be trapped when the script is backgrounded from a non-interactive shell — and verify the partial is removed while the source stays put.
