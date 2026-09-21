# Changelog

## 0.1.0 — Initial prototype (2026-09-21)

- `scripts/Scan-Drive.ps1`: single-pass recursive drive scanner (folder sizes
  by depth, top extensions, top files), built to handle multi-terabyte drives
  in a reasonable time.
- `scripts/Invoke-DriveCensus.ps1`: orchestrator that discovers local drives,
  scans them in parallel, and renders the HTML report.
- `dashboard/template.html`: self-contained report with drive capacity view,
  generic rule-based categorization, and a first set of cleanup-opportunity
  detectors (low space, Windows upgrade leftovers, stale large files,
  name+size duplicate signal, backup-heavy drives, oversized Downloads).
- Proven against a real 5-drive, ~6TB Windows machine during development
  (one system drive, two ~1TB internal drives, one secondary internal drive,
  one 3.7TB external backup drive).
