# Changelog

## 1.3.0

- Added automatic diagnostic export when an F8 capture finishes.
- Added F9 to re-export the frozen report.
- Added `performance_report_latest.json` for easy sharing.
- Added matching human-readable `performance_report_latest.txt`.
- Added timestamped report archives under `performance_reports/`.
- Added engine/game/LÖVE/OS/renderer/window metadata.
- Added exact loaded-mod versions, priorities, dependencies and load order.
- Added full F8 frame-time series and diagnostic-specific frame distribution:
  median, P95, P99, worst, 1% low and missed 16.67 ms budget.
- Added detailed slow-frame records with direct/deep contributors, state/map and
  render counters.
- Added 4 Hz capture time series for FPS, Logic/s, memory and renderer workload.
- Added logic-step totals for the diagnostic interval.
- Added machine-readable report schema (`gen1recomp-performance-report`, v1).
- Added `filesystem` permission for report export.
- Report intentionally excludes player/save progress and absolute paths.

## 1.2.0

- Added slow-frame correlation and deep Lua diagnostics.
- Added HIGH/MED/LOW fluidity-impact verdicts.
- Added direct render-work attribution and explicit unattributed slow frames.

## 1.1.0

- Added per-mod exclusive hook/event CPU profiling.

## 1.0.0

- Initial FPS/frame-time/renderer/memory monitor.
