# Performance Monitor v1.4.0

Performance Monitor is an in-game FPS, frametime, renderer, and mod-impact diagnostic overlay for Gen1Recomp.

It is designed to show what the game is doing while you play and to capture detailed evidence when a slowdown or stutter occurs.

## Credits

- **FAFF0x** - original Performance Monitor author.
- **Ehren1337** - additional credited author listed in `manifest.json`.

Please preserve these credits when redistributing the mod.

## Requirements

- Gen1Recomp `0.1.51` or newer.
- Mod API 2.
- The mod must be installed and enabled through Gen1Recomp.

The mod requests `engine_internals` for runtime profiling and `filesystem` for saved preferences and diagnostic reports.

## Dashboard

The dashboard is normally shown in compact mode and can be expanded with F4.

### Header

The header identifies the Performance Monitor overlay. The color palette can be changed with F7.

### FPS cards

- **FPS** - current frames per second reported by LOVE.
- **LOW** - rolling 1% low FPS calculated from recent frame samples.
- **LUA** - current Lua memory usage.

### Frametime graph

- **FRAMETIME** - rolling history of individual frame times.
- **CURRENT** - the current frame time in milliseconds.
- **BOTTOM 0 ms** - the graph's bottom reference.
- **MAX 50 ms** - the graph's visible upper range. Values above 50 ms are clipped visually, but the real value remains available in the WORST card and diagnostic report.

### Engine cards

- **TEX** - texture memory reported by the renderer.
- **DRAW** - draw calls.
- **BATCH** - batched draw calls.
- **CANVAS** - canvas switches.
- **SHADER** - shader switches.
- **LOGIC** - fixed-step game logic updates per second.
- **AVG** - rolling average frame time.
- **WORST** - highest frame time in the rolling sample window.
- **STATE** - current activity: `IDLE`, `MOVING`, `TALKING`, or `BATTLE` when detected. Outside active overworld/battle activity it may show the current screen name.
- **MAP** - current map identifier.

### Diagnostic status

The status card describes the profiler state:

- **COLLECTING MOD DATA** - normal live profiling is running.
- **DIAG** - an F8 deep diagnostic capture is active.
- **REPORT FROZEN** - a completed diagnostic report is being displayed.

### Mod Performance table

The table ranks measured mod activity:

- **CPU** - exclusive measured hook/event CPU percentage.
- **STUT** - percentage of slow frames where the mod was the strongest measured contributor.
- **MAX** - worst individual measured callback time.
- **DRAW** - exclusive draw calls per second attributed to render hooks.

The monitor does not list itself as a culprit. The table can remain empty when no other enabled mod has measurable instrumented callbacks; this does not mean profiling is broken.

## Controls

- **F3 HIDE** - show or hide the overlay. The last state is remembered.
- **F4 COMPACT / EXPAND** - switch between compact and full dashboard views. Compact mode is the default and the last view is remembered.
- **F5 RELOAD** - reload mods when Gen1Recomp developer hot reload is available.
- **F6 RESET** - clear rolling live samples and restart the live profiler window.
- **F7 COLORS** - cycle through blue, purple, green, amber, and red dashboard palettes. The selected palette is remembered.
- **F8 DIAGNOSTIC** - start a 10-second deep diagnostic capture, or stop the active capture early.
- **F9 EXPORT** - export the most recent completed diagnostic report again.

On small windowed screens, the overlay automatically favors compact mode and scales to fit the available width.

## Diagnostic workflow

1. Reproduce the slowdown in the map, menu, or battle where it occurs.
2. Press **F8**.
3. Continue playing normally for up to 10 seconds.
4. The report is exported automatically when the capture completes.
5. Use **F9** to export it again if needed.

The capture records frame timing, renderer counters, game state, map, loaded mods, callback measurements, slow-frame correlation, and deep Lua samples when available.

## Exported files

The monitor writes these files to Gen1Recomp's normal LOVE save directory:

- `performance_report_latest.json` - complete machine-readable report.
- `performance_report_latest.txt` - human-readable report.
- `performance_reports/performance_report_YYYYMMDD_HHMMSS.json` - timestamped JSON archive.
- `performance_reports/performance_report_YYYYMMDD_HHMMSS.txt` - timestamped text archive.

The JSON report includes engine/game information, renderer details, loaded mod metadata, frame distributions, 1% low FPS, missed frame-budget counts, slow/severe/unattributed frames, per-mod CPU and render measurements, deep sampler attribution, slow-frame records, and a 4 Hz time series.

## Saved preferences

The following files are stored in Gen1Recomp's LOVE save directory:

- `performance_monitor_ui.txt` - remembered hidden/shown and compact/expanded state.
- `performance_monitor_theme.txt` - remembered dashboard color palette.

## Interpreting results

A high **CPU** value means the mod consumed measured Lua time in instrumented callbacks. A high **STUT** value means the mod frequently won the slow-frame correlation, not that it is proven to be the only cause. A high **WORST** value indicates an occasional callback spike.

Some slow frames may be reported as unattributed. GPU driver work, C-side engine work, and other costs cannot always be assigned reliably to a Lua mod, so the monitor intentionally leaves uncertain work unattributed rather than inventing blame.

## Privacy

Reports contain performance data, renderer/device information, game settings, and the loaded mod list. The report does not intentionally include save progress, player names, absolute save-directory paths, or filesystem mod paths.