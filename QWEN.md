# QWEN.md

## Project Overview

A single-file Bash utility (`movePlots.sh`) that moves completed [Chia](https://www.chia.net/) plot files (`*.plot`) from a source directory into one or more destination directories in **round-robin** order. Before each move it checks the destination filesystem's free space (via `df`); if a destination lacks room, the next is tried, and if none has room the file is left for later. Moves run as background transfers — up to `MOVE_PLOTS_PARALLEL` (default 2) concurrently — so a slow cross-filesystem copy doesn't block other plots. By default it runs as a watcher re-scanning every 15 seconds; `--once` processes what's present and waits for all in-flight transfers before exiting.

## File Layout

```
movePlots.sh   # The entire program — one bash script
README.md      # Usage docs, options, environment variables, examples
LICENSE        # MIT (Copyright 2026 Roy Park)
```

There is no build system, no dependencies beyond standard utilities (`df`, `stat`, `awk`, `mv`), and no test suite.

## Running

```bash
# Watch mode (default): keep moving plots as they complete
./movePlots.sh /path/to/source /path/dest1 /path/dest2 ...

# Single pass: move what's present now, then exit
./movePlots.sh --once /path/to/source /path/dest1 /path/dest2 ...

# Custom scan interval (seconds)
MOVE_PLOTS_INTERVAL=5 ./movePlots.sh /path/to/source /path/dest1

# More concurrent transfers (default 2)
MOVE_PLOTS_PARALLEL=4 ./movePlots.sh /path/to/source /path/dest1 /path/dest2
```

- `SOURCE_DIR` must exist; nonexistent destinations are skipped with a warning.
- Exit codes: 0 on success/help, 1 on usage errors or if no valid destination exists.

## Key Implementation Details

- **Portability constraint (important):** the script is tested on macOS with **bash 3.2** and must keep working there. Avoid bash 4+ features (associative arrays, `mapfile`, `${var,,}`, etc.).
- **BSD/GNU dual support:** `file_size()` tries BSD `stat -f%z` first, then GNU `stat -c%s`. `free_kb()` uses `df -Pk` (POSIX kilobytes) so it works on both platforms. Keep this pattern when touching stat/df calls.
- **Async transfers:** each move runs in a background subshell (`( mv ... ) &`); the parent tracks PIDs/paths in `ACTIVE_PIDS`/`ACTIVE_FILES` and reaps via `kill -0` polling because `wait -n` needs bash 4.3+ (unavailable on macOS). Each child logs its own success/failure through `log()`. The background block uses `start_transfer`'s local variables (`f`, `dest`, `bytes`) — subshells fork the shell and inherit them, so don't "fix" that by re-declaring.
- **bash 3.2 + `set -u` gotcha:** expanding an *empty* array with `"${arr[@]}"` errors as unbound before bash 4.4. Guard such expansions with a length check first (see `reap_jobs`, `is_active`).
- **Round-robin state** (`rr_index`) is in memory only; a restart resumes at the first destination. Rotation advances when a transfer *starts* (the destination is reserved up front), not when it finishes, so a failed transfer doesn't pile the next file onto the same destination. Free space is checked at start only — concurrent transfers to one volume can contend, and a loser fails and is retried later.
- **In-progress plots are ignored:** only `*.plot` files match; Chia renames `*.plot.tmp` → `.plot` on completion. Files already being transferred are skipped by later scans (`is_active`).
- **Cross-filesystem moves** (`mv`) copy then delete — slow by nature, not a bug.
- The script ends with an `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard so it can be **sourced without executing `main`** (the comment says this is so tests can stub functions). Preserve this guard if adding tests that source the file.

## Development Conventions

- Style: plain procedural bash, `set -u`, small helper functions (`log`, `usage`, `file_size`, `free_kb`, `human_size`, `reap_jobs`, `is_active`, `pending_count`, `wait_for_progress`, `start_transfer`, `scan_source`, `main`), local variables declared per function with `local`.
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

To test transfer behavior (concurrency, retries) without slow real copies, source the script and stub functions — set env vars *before* sourcing, since `INTERVAL`/`PARALLEL` are read at source time:

```bash
MOVE_PLOTS_PARALLEL=2 bash -c '
  source ./movePlots.sh          # guard prevents main from running
  mv() { sleep 3; command mv "$@"; }   # simulate slow transfers
  main --once /tmp/mp/src /tmp/mp/d1 /tmp/mp/d2
'
```

Stubbing `free_kb() { echo 0; }` exercises the no-space/retry path and confirms `--once` exits (code 1) instead of looping forever.
