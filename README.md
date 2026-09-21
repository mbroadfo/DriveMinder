# DriveMinder

A local, no-install disk-space dashboard for Windows PCs. Scans every fixed/removable
drive, categorizes what it finds (personal data, apps & OS, games, backups, caches),
and generates a self-contained HTML report with ranked, specific cleanup suggestions.

Nothing is ever deleted automatically — DriveMinder only reports and suggests.

## Why

Tools like WinDirStat show you *where* your space went, but not *what kind* of data
it is or *what's safe to remove*. DriveMinder adds a categorization and
opportunity-detection layer on top of a fast full-disk scan, so you can tell junk
from backups from your actual data at a glance.

## Quick start

```powershell
cd scripts
.\Invoke-DriveCensus.ps1
```

This scans every local fixed/removable drive in parallel, opens a **live view**
in your browser that fills in while scanning runs (the same treemap you'll get
in the final report, just fed by a poll endpoint instead of a finished file),
then writes the finished `DriveMinder-Report.html` to `output\<timestamp>\`
once everything's done.

Options:

```powershell
# Scan specific drives only
.\Invoke-DriveCensus.ps1 -DriveLetters C,D

# Don't open a browser at all - headless/scripted use, console progress only
.\Invoke-DriveCensus.ps1 -NoOpen
```

## How it works

- **`scripts/Scan-Drive.ps1`** — single-pass recursive scanner for one drive.
  Uses raw .NET file enumeration (not `Get-ChildItem -Recurse`) so it's fast
  enough for multi-terabyte drives. Records folder sizes by depth, top file
  extensions, and the largest individual files. With `-LiveTree`, also tracks
  a running per-folder size total (not just completed subtrees) so a live
  viewer can show top-level folders filling in instead of staying at zero
  until their entire subtree finishes - opt-in because it costs real time
  (see "Live scanning" below), so headless/`-NoOpen` runs skip it.
- **`scripts/Invoke-DriveCensus.ps1`** — orchestrator. Discovers drives, runs
  `Scan-Drive.ps1` for each one in parallel background jobs, starts a small
  local HTTP server (`System.Net.HttpListener`, built into .NET - no new
  install) for the live view, then renders `dashboard/template.html` with
  the final combined results injected as JSON once every drive finishes.
- **`dashboard/template.html`** — the report itself. All categorization and
  cleanup-opportunity logic lives here, in client-side JS, operating on the
  raw scan JSON. Keeping the "smart" part in one JS file (rather than
  PowerShell) makes it easy to extend without touching the scanner. The
  exact same `renderAll()` function draws both the finished static report
  (data injected once) and the live view (same function, called every ~1.5s
  with freshly polled data) - they can't drift apart because they're not
  two implementations of the same thing, they're one.

### Live scanning

A live view opens automatically (unless `-NoOpen`) and fills in while
scanning runs, using the same treemap as the finished report - top-level
folders show real partial totals climbing, not just a blank space until
their whole subtree finishes. Drilling into a folder survives the view
refreshing under you (it re-resolves your position by path each poll rather
than resetting to the root).

This has a real, measured cost: tracking the live per-folder tree was ~1.9x
slower on a real 887GB/370K-file drive in its naive form, and even after
moving the expensive part off the per-file hot path (bytes now accumulate in
a plain counter and only get distributed to the live tree at each ~1.5s
flush, not on every single file), it's still slower than a plain scan. That
cost is opt-in: `-LiveTree` is only passed to the scanner when something
will actually be watching, so `-NoOpen` runs stay at full speed. The
live-preview totals can be briefly approximate right at the moment scanning
crosses from one folder into an unrelated one (bytes counted in the gap
between flushes get credited to whichever folder is active when the flush
happens) - this only affects what the live view shows in the moment; the
final report always comes from the exact, unaffected post-order accounting
that was already there.

### Categorization

Folders are tagged by name/path pattern into: personal data, documents,
downloads, backups/archives, apps & OS, games, caches/leftovers, or other.
Large or ambiguous top-level folders (e.g. `Users\<name>`) are automatically
drilled into one level deeper rather than left as one big blob — see
`buildFolderBreakdown()` in the template.

### Cleanup opportunities (current heuristics)

- Drives running low on free space
- Windows upgrade leftover folders (`$Windows.~WS`, `Windows.old`)
- Large files untouched for 2+ years
- Files with matching name + size found in more than one place (a cheap
  duplicate signal — see roadmap for real hash-based detection)
- Drives that are mostly backup/archive data (flagged for awareness, not as junk)
- Oversized Downloads folders

## Known limitations

- **Permission-restricted folders** (e.g. `Access is denied` on a folder with
  ACLs from another user profile or backup tool) are recorded in
  `SkippedSample` with the actual exception, rather than silently
  mis-measured. There's no safe generic fix for this — DriveMinder reports
  what it can't read rather than guessing, so a drive's true usage can be
  undercounted when this happens on a large subtree.
- **Long paths**: fixed as of v0.2.0 — every path goes through the `\\?\`
  extended-length prefix, so the classic 260-character MAX_PATH limit no
  longer causes silent gaps. (Validated against a real ~260-character path
  that failed before the fix and succeeds after it.)
- **Duplicate detection is name+size only** — a real feature needs content
  hashing (see roadmap).
- Windows-only. The scan relies on drive letters, `Win32_LogicalDisk`, and
  Windows-specific folder conventions (`AppData`, `Program Files`, etc).

## Roadmap

- [x] Long-path-safe scanning (`\\?\` prefix) — v0.2.0
- [x] Treemap visualization with click-to-drill — v0.2.0
- [x] Live console progress while scanning (files/bytes/current folder) — v0.2.0
- [x] Live browser view (same treemap, filling in while scanning runs) — v0.3.0
- [ ] Extension-colored treemap tiles with legend-linked highlighting
      (the WinDirStat-style "click `.mp3` in the legend, every mp3 block
      lights up" interaction — needs file-level, not folder-level, tiles)
- [ ] Real duplicate-file detection (content hashing, not just name+size)
- [ ] Backup retention strategy — suggest what to keep/prune across
      generations of backups (e.g. the Quicken `.qdf-backup` pattern, nested
      full-drive backup sets)
- [ ] File investigation view — search/filter/drill into any folder from
      the report instead of only seeing the top N
- [ ] Chat interface to ask questions about a scan ("what's using space on
      D: that I haven't touched since 2020?")
- [ ] Optional actual cleanup actions, gated behind explicit per-item confirmation

## Privacy

Scan output (`output/`) contains real file paths and folder names from your
PC and is **git-ignored** — it never gets committed or pushed. Only the tool
code itself is version-controlled.
