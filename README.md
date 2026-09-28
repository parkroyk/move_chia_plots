# movePlots.sh

A bash script that moves completed [Chia](https://www.chia.net/) plot files from a source directory into one or more destination directories in **round-robin** order, checking free disk space before each move. Transfers run in the background so multiple plots can be moved concurrently — up to `--parallel N` at once (default 2), with at most one transfer per destination. Pressing `q` (or Ctrl-C) aborts in-flight transfers and removes their partial files from the destinations.

## How it works

- Scans the source directory for completed plots (`*.plot` files). In-progress plots (`*.plot.tmp`) are ignored — Chia renames them to `.plot` only when plotting finishes.
- Distributes plots across the destination directories in round-robin fashion: each transfer starts at the current rotation position, and the rotation advances past the chosen destination as soon as the transfer is launched, so plots spread evenly.
- Transfers run as background jobs: up to `--parallel N` (default 2) plots are moved concurrently, so a slow cross-filesystem copy does not block other completed plots. At most one transfer writes to a given destination at a time, so effective concurrency is the smaller of `--parallel` and the number of destinations. Files already being transferred are skipped by later scans.
- Each transfer logs its start (`name.plot: moving to DEST`) and, on completion, the size and how long it took (`name.plot: moved to DEST (SIZE in TIME)`).
- Before launching a transfer, it compares the file size against the available space on the destination's filesystem (via `df`). A destination without enough room — or already receiving a transfer — is silently skipped; if **no** destination is available, the file is left in place and retried later.
- By default it runs as a watcher, re-scanning every 15 seconds so it can keep up with an active plotter. `--once` waits for all in-flight transfers to finish before exiting.
- Press `q` (in an interactive terminal) or Ctrl-C to stop. In-flight transfers are aborted and any partially copied files are removed from their destinations; moves that had already completed are kept. Interrupted plots stay in the source directory and are picked up on the next run.

## Requirements

- Bash (tested on macOS with bash 3.2; also works with Linux/GNU bash)
- Standard utilities: `df`, `stat`, `awk`, `mv`, `pkill`

## Usage

```bash
./movePlots.sh [--once] [--parallel N] SOURCE_DIR DEST_DIR [DEST_DIR ...]
```

| Argument | Description |
| --- | --- |
| `SOURCE_DIR` | Directory where new plots are created (e.g. the plotter's output dir). Must exist. |
| `DEST_DIR ...` | One or more destination directories to distribute plots across. Nonexistent destinations are skipped with a warning. |

### Options

| Option | Description |
| --- | --- |
| `--once` | Move whatever plots are present now and exit (waiting for all transfers to finish), instead of watching continuously. |
| `--parallel N` | Maximum number of concurrent transfers (default: `2`). At most one transfer writes to a given destination at a time. |
| `-h`, `--help` | Show usage information. |

### Environment variables

| Variable | Description |
| --- | --- |
| `MOVE_PLOTS_INTERVAL` | Seconds between scans in watch mode (default: `15`). |

## Examples

```bash
# Watch mode: keep moving plots as they complete (run in a terminal or tmux session)
./movePlots.sh /Volumes/Plotter/plots /Volumes/Storage1/plots /Volumes/Storage2/plots /Volumes/Storage3/plots

# Single pass: move everything currently in the source dir, then exit
./movePlots.sh --once /Volumes/Plotter/plots /Volumes/Storage1/plots /Volumes/Storage2/plots

# Faster scan interval (every 5 seconds)
MOVE_PLOTS_INTERVAL=5 ./movePlots.sh /Volumes/Plotter/plots /Volumes/Storage1/plots /Volumes/Storage2/plots

# Move up to 4 plots concurrently (still at most one per destination)
./movePlots.sh --parallel 4 /Volumes/Plotter/plots /Volumes/Storage1/plots /Volumes/Storage2/plots /Volumes/Storage3/plots
```

### Sample output

```
2026-09-25 23:00:05 Watching '/Volumes/Plotter/plots' -> /Volumes/Storage1/plots /Volumes/Storage2/plots (every 15s, up to 2 concurrent transfer(s), one per destination; press q (or Ctrl-C) to quit)
2026-09-25 23:00:20 plot-k32-2026-09-25-...-abc123.plot: moving to /Volumes/Storage1/plots
2026-09-25 23:00:20 plot-k32-2026-09-25-...-def456.plot: moving to /Volumes/Storage2/plots
2026-09-25 23:01:42 plot-k32-2026-09-25-...-abc123.plot: moved to /Volumes/Storage1/plots (107.3 GB in 82s)
2026-09-25 23:01:58 plot-k32-2026-09-25-...-def456.plot: moved to /Volumes/Storage2/plots (107.3 GB in 98s)
```

If a destination is nearly full it is skipped silently — the plot simply lands on the next one:

```
plot-k32-...-def456.plot: moving to /Volumes/Storage2/plots
plot-k32-...-def456.plot: moved to /Volumes/Storage2/plots (107.3 GB in 98s)
```

If you press `q` while a move is in flight, the partial copy is removed and the plot stays in the source directory for the next run:

```
2026-09-25 23:05:12 Shutting down; aborting 1 in-flight transfer(s)
2026-09-25 23:05:12 plot-k32-...-abc123.plot: transfer interrupted, partial file removed from /Volumes/Storage1/plots
```

## Notes

- The round-robin position is kept in memory only; restarting the script resumes at the first destination. It advances when a transfer *starts*, so a failed transfer does not pile the next file onto the same destination.
- Free space is checked when a transfer starts. Because only one transfer writes to a given destination at a time, contention can only happen if two destination directories share a filesystem: both may pass the check before either completes, and if one then runs out of space it fails (its partial file is removed) and is retried later.
- On `q`/Ctrl-C the script kills in-flight transfers and removes their partially copied files from the destinations. A transfer whose source file is already gone had finished copying, so its destination file is kept. Interrupted plots remain in the source directory and are moved on the next run.
- `mv` across different filesystems copies then deletes, so moves take as long as a copy of the plot would — running them concurrently is what keeps watch mode up with an active plotter.
- Run it in a persistent terminal session or under `tmux`/`screen` (or set up a launchd/systemd unit) to keep watch mode alive.

## License

[MIT](LICENSE)
