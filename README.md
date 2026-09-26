# movePlots.sh

A bash script that moves completed [Chia](https://www.chia.net/) plot files from a source directory into one or more destination directories in **round-robin** order, checking free disk space before each move.

## How it works

- Scans the source directory for completed plots (`*.plot` files). In-progress plots (`*.plot.tmp`) are ignored — Chia renames them to `.plot` only when plotting finishes.
- Distributes plots across the destination directories in round-robin fashion: each file starts at the current rotation position, and after a successful move the rotation advances past the destination used, so plots spread evenly.
- Before moving a file, it compares the file size against the available space on the destination's filesystem (via `df`). If the destination does not have enough room, the next destination is tried. If **no** destination has room, the file is left in place and retried on the next scan.
- By default it runs as a watcher, re-scanning every 15 seconds so it can keep up with an active plotter.

## Requirements

- Bash (tested on macOS with bash 3.2; also works with Linux/GNU bash)
- Standard utilities: `df`, `stat`, `awk`, `mv`

## Usage

```bash
./movePlots.sh [--once] SOURCE_DIR DEST_DIR [DEST_DIR ...]
```

| Argument | Description |
| --- | --- |
| `SOURCE_DIR` | Directory where new plots are created (e.g. the plotter's output dir). Must exist. |
| `DEST_DIR ...` | One or more destination directories to distribute plots across. Nonexistent destinations are skipped with a warning. |

### Options

| Option | Description |
| --- | --- |
| `--once` | Move whatever plots are present now and exit, instead of watching continuously. |
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
```

### Sample output

```
2026-09-25 23:00:05 Watching '/Volumes/Plotter/plots' -> /Volumes/Storage1/plots /Volumes/Storage2/plots (every 15s; Ctrl-C to stop)
2026-09-25 23:00:05 Scan: 0 plot(s) moved, 0 failure(s)
2026-09-25 23:00:20 plot-k32-2026-09-25-...-abc123.plot: moved to /Volumes/Storage1/plots (107.3 GB)
2026-09-25 23:00:20 Scan: 1 plot(s) moved, 0 failure(s)
```

If a destination is nearly full you will see the fallback in action:

```
plot-k32-...-def456.plot: /Volumes/Storage1/plots has only 50.2 GB free, needs 107.3 GB - trying next destination
plot-k32-...-def456.plot: moved to /Volumes/Storage2/plots (107.3 GB)
```

## Notes

- The round-robin position is kept in memory only; restarting the script resumes at the first destination.
- `mv` across different filesystems copies then deletes, so moves take as long as a copy of the plot would.
- Run it in a persistent terminal session or under `tmux`/`screen` (or set up a launchd/systemd unit) to keep watch mode alive.

## License

[MIT](LICENSE)
