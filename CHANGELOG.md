# Changelog

## 0.4.0 — WinDirStat-style treemap coloring (2026-09-21)

- **Tiles now color by file type**, not just folder category: audio, video,
  images, documents, archives, programs, game data, app data/logs (see
  `EXT_FAMILIES` in `dashboard/template.html`). `Scan-Drive.ps1` tracks,
  per reported folder, the extension that accounts for the most bytes among
  files directly in that folder (not descendants) - depth-gated to only
  folders that actually get reported, after measuring that tracking it
  unconditionally cost real time on deeply-nested drives for data that was
  then thrown away unused.
- **Cushion shading**: each tile gets a shared diagonal gradient overlay
  (light top-left, dark bottom-right) instead of a flat fill, plus tighter
  gaps and sharp corners instead of rounded ones - closer to WinDirStat's
  dense, glossy mosaic look. Labels get a dark outline so they stay legible
  against any tile color.
- **Real data-quality bug found and fixed during validation**: the first
  version trusted a folder's dominant extension unconditionally, which
  meant folders that are almost entirely subfolders - "My Music" with 346GB
  of subfolders and one stray 4KB `.xls` sitting directly in it - showed up
  colored as Documents instead of Audio, because that stray file was
  technically the "only" thing directly inside it. Caught by pulling real
  scan data and checking dominant-extension folders by hand, not by
  reasoning about the code. Fixed by sending `DominantExtBytes` alongside
  `DominantExt` and only trusting it client-side when it's over 15% of the
  folder's total size; verified on real D: and E: data that container
  folders now correctly show 0% (fall back to category) while real content
  folders (GoPro clip folders, iTunes movie folders) show 95-100%.
- **Second performance regression found and fixed during validation**: the
  first working version of per-folder extension tracking added ~20s to a
  real D: scan even beyond the live-tree cost, because it tracked every
  file's extension for every folder regardless of scan depth - including
  files many levels past `ReportDepth` whose data was never reported and
  therefore never used (D:'s iTunes Album Artwork cache alone nests 9+
  levels deep). Fixed by gating the tracking to `Depth <= ReportDepth`,
  which recovered essentially all of the added time.

## 0.3.0 — Live browser view while scanning (2026-09-21)

- **Live scanning view**: `Invoke-DriveCensus.ps1` now starts a small local
  HTTP server (`System.Net.HttpListener`) the moment scanning begins and
  opens the browser immediately, instead of only after everything finishes.
  The page polls a `/live-data` endpoint every ~1.5s and re-renders with the
  exact same `renderAll()`/treemap code the finished report uses - not a
  separate "preview" implementation that could drift out of sync.
  `Scan-Drive.ps1` gained `-LiveTree`, which tracks a running per-folder
  size (not just completed subtrees) so top-level folders visibly fill in
  during the scan instead of staying blank until their whole subtree
  finishes.
- **Treemap state survives live refreshes**: drilling into a folder while
  the view is still polling doesn't reset to the root every ~1.5s - the
  drill path is re-resolved by folder path against each freshly-fetched
  tree (falling back gracefully if a folder genuinely disappears). Validated
  with a standalone Node test covering the refresh-survives, refresh-updates,
  path-vanishes, and partial-survival cases.
- **Real performance regression found and fixed during validation**: the
  first working version of live per-folder tracking - updating every open
  ancestor folder on every single file - measured ~1.9x slower on a real
  887GB/370K-file drive (millions of extra PowerShell-level hashtable
  operations add up; PowerShell's per-operation overhead is much higher than
  compiled .NET). Fixed by moving that work off the per-file hot path
  entirely: bytes accumulate in a plain counter and only get distributed to
  the live tree at each ~1.5s flush instead of on every file. Also made the
  whole live-tree feature opt-in (`-LiveTree`) so headless/`-NoOpen` runs -
  where nothing is watching anyway - pay none of this cost.
- **Real bug found and fixed during validation**: `$liveTreeArg = if (cond)
  { @('-LiveTree') } else { @() }` hit PowerShell's single-element-array
  unrolling gotcha - an array returned from inside an if/else expression
  gets flattened to its bare scalar element on assignment. That silently
  turned `-LiveTree` into a plain string, which broke `@extraArgs` splatting
  and crashed every scan job instantly (caught via diagnostic logging that
  printed the runtime type actually received: `System.String`, not an
  array). Every live-view run failed before this fix; multiple isolated
  reproductions of the "same" logic succeeded because they built the array
  via direct assignment rather than through an if/else expression - the
  isolation was accidentally avoiding the exact construct that broke.

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
