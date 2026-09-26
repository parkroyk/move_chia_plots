# QWEN.md

## Project Overview

A single-file Bash utility (`movePlots.sh`) that moves completed [Chia](https://www.chia.net/) plot files (`*.plot`) from a source directory into one or more destination directories in **round-robin** order. Before each move it checks the destination filesystem's free space (via `df`); if a destination lacks room, the next is tried, and if none has room the file is left for the next scan. By default it runs as a watcher re-scanning every 15 seconds to keep up with an active plotter.

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
```

- `SOURCE_DIR` must exist; nonexistent destinations are skipped with a warning.
- Exit codes: 0 on success/help, 1 on usage errors or if no valid destination exists.

## Key Implementation Details

- **Portability constraint (important):** the script is tested on macOS with **bash 3.2** and must keep working there. Avoid bash 4+ features (associative arrays, `mapfile`, `${var,,}`, etc.).
- **BSD/GNU dual support:** `file_size()` tries BSD `stat -f%z` first, then GNU `stat -c%s`. `free_kb()` uses `df -Pk` (POSIX kilobytes) so it works on both platforms. Keep this pattern when touching stat/df calls.
- **Round-robin state** (`rr_index`) is in memory only; a restart resumes at the first destination. After a successful move, rotation advances *past* the destination used.
- **In-progress plots are ignored:** only `*.plot` files match; Chia renames `*.plot.tmp` → `.plot` on completion.
- **Cross-filesystem moves** (`mv`) copy then delete — slow by nature, not a bug.
- The script ends with an `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard so it can be **sourced without executing `main`** (the comment says this is so tests can stub functions). Preserve this guard if adding tests that source the file.

## Development Conventions

- Style: plain procedural bash, `set -u`, small helper functions (`log`, `usage`, `file_size`, `free_kb`, `human_size`, `move_plot`, `scan_source`, `main`), local variables declared per function with `local`.
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
