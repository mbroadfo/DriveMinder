# Changelog

## 0.2.0 — Long-path fix + treemap (2026-09-21)

- **Long-path scanning fix**: every path now goes through the `\\?\`
  extended-length prefix instead of requiring the machine-wide
  `LongPathsEnabled` registry setting. Validated directly against a real
  263-character path that failed before the fix (`Could not find a part of
  the path`) and succeeds after it. On a real rescan of the 3.7TB backup
  drive used during development, unreadable items dropped from 8 to 3 - the
  remaining 3 are genuine `Access is denied` permission errors, now reported
  with the actual exception instead of a generic failure, so path-length and
  permission problems are no longer indistinguishable.
- **Treemap visualization**: `dashboard/template.html` now builds a real
  parent/child folder tree from the scan data and lays it out with the
  squarified-treemap algorithm (Bruls/Huizing/van Wijk). Click a tile to
  drill into its subfolders, breadcrumb to go back up. Validated two ways:
  a standalone Node.js test of the tree-building and layout math (area
  conservation, in-bounds rects, correct parent/child nesting, overflow
  bucketing) against synthetic fixtures, and again against a real 927GB
  drive's scan output (confirmed `My Movies` and `Insta360\Camera01` appear
  with correct byte counts and drill correctly).
- **Critical bug fix - the report was never actually loading real data.**
  `Invoke-DriveCensus.ps1` did `$template.Replace('/*__DRIVEMINDER_DATA__*/', $payloadJson)`,
  which only swaps the comment token and leaves the template's fallback
  sample object (`{"generatedAt":null,"machine":"(sample)","drives":[]}`)
  sitting immediately after it. Every report generated before this fix -
  including the one in the 0.1.0 commit - rendered
  `const PAYLOAD = {realData...}{"generatedAt":null,...};`: two adjacent
  object literals with no operator between them, a JavaScript syntax error
  that would have made the dashboard fail to load in a real browser. Never
  caught earlier because nothing had actually opened a generated report in
  a browser yet. Fixed by switching to start/end marker splicing (plain
  string concatenation, not `[regex]::Replace` with the payload as the
  replacement string - `.NET` treats `$` specially there, and real folder
  names in this data legitimately contain `$`, e.g. `$Windows.~WS`).
  Validated by extracting the `<script>` block from a real generated report
  and running `node --check` on it: fails on the pre-fix report, passes
  after the fix.
- **Live progress while scanning**: `Scan-Drive.ps1` now flushes a small
  progress snapshot (files scanned, bytes scanned, current folder) to disk
  on a timer, and `Invoke-DriveCensus.ps1` polls it every 2s while waiting
  on the background jobs. Not WinDirStat's live animated treemap (that
  needs a browser-side live view, tracked as a future item) but no longer
  silent for the several minutes a big drive takes. Validated by polling
  the progress file directly mid-scan and confirming files/bytes climb and
  the current-folder path changes between reads.
- **Bug fixes found while validating**:
  - `Invoke-DriveCensus.ps1 -DriveLetters C,D` (comma-joined, no spaces)
    silently became a single malformed drive token when invoked via
    `powershell -File`, which then made `Get-Volume` return multiple
    volumes and crash on an array-to-int64 cast. Fixed by normalizing/
    splitting drive-letter input and hardening the volume lookup.
  - `Out-File -Encoding utf8` in Windows PowerShell 5.1 writes a UTF-8 BOM,
    which breaks strict JSON parsers (caught via Node's `JSON.parse`).
    Both the scan JSON and the rendered report now write BOM-less UTF-8
    via `System.Text.UTF8Encoding($false)`.

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
