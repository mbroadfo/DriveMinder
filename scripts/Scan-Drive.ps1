<#
.SYNOPSIS
  Single-pass recursive scanner for one drive root. Emits folder sizes (by depth),
  top file extensions, and top individual files as JSON.

.NOTES
  Uses raw .NET enumeration instead of Get-ChildItem -Recurse for speed on
  multi-terabyte drives. Reparse points (junctions/symlinks) are skipped to
  avoid double-counting and infinite loops.

  Long paths: Windows PowerShell 5.1's file APIs hit the classic 260-character
  MAX_PATH limit on deeply nested folders (common inside old backup sets).
  Rather than requiring the machine-wide LongPathsEnabled registry setting
  (a system change this tool won't make for you), every path is passed to
  .NET through the \\?\ extended-length prefix, which opts individual calls
  into long-path behavior without touching any system setting. Paths are
  stripped back to their normal display form before being recorded.
#>
param(
    [Parameter(Mandatory)] [string]$DriveRoot,
    [Parameter(Mandatory)] [string]$OutJson,
    [int]$ReportDepth = 5,
    [int]$TopFilesCount = 300,
    [string]$ProgressJson = $null,
    # Tracks a live partial folder tree for a browser watching progress -
    # skip it (default) for headless/-NoOpen runs where nothing consumes it.
    # Even the optimized version isn't free: measured ~40% slower on a real
    # 887GB drive than plain scalar-only progress reporting.
    [switch]$LiveTree
)

$ErrorActionPreference = 'SilentlyContinue'

$extTotals = @{}
$topFiles = New-Object System.Collections.Generic.List[object]
$dirReport = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$minBytes = [int64]0
$excludeNames = @('System Volume Information', '$RECYCLE.BIN', 'Recovery', 'RECYCLER')

# Progress snapshots: flushed to disk on a timer (not on every file - that
# would add real I/O overhead) so a watching process - the live browser view
# in Invoke-DriveCensus.ps1 - can show real progress without this script
# needing to be multithreaded like WinDirStat.
#
# Beyond the scalar counters, liveTotals tracks a *running* size for every
# folder currently on the call stack, not just folders whose subtree has
# fully finished. Without this, a live treemap would show nothing at the
# top level (e.g. C:\Users) until its entire subtree completed, which for
# a big folder is basically "until the scan is nearly done" - the opposite
# of a satisfying live view.
#
# The naive version of this - updating every open ancestor on every single
# file - was measured at ~1.9x slower on a real 887GB/370K-file drive (a few
# million extra PowerShell-level hashtable ops add up fast; PowerShell's
# per-operation overhead is much higher than compiled .NET). Since this data
# only feeds a *preview* - the final report always comes from the exact
# post-order $dirReport below, completely untouched by any of this - it
# doesn't need per-file precision. Bytes accumulate in a plain counter and
# only get distributed to the CURRENT ancestor chain when a flush actually
# happens (every ~1.5s, so a few hundred times total instead of millions).
# The one inaccuracy this trades in: if the scan crosses into an unrelated
# folder in the moment between the bytes being counted and the next flush,
# the live view can briefly credit them to the wrong sibling folder. That
# self-corrects the moment either folder's subtree actually finishes.
$filesScanned = 0
$bytesScanned = [int64]0
$currentPath = $DriveRoot
$pendingBytes = [int64]0
$liveTotals = @{}
$liveDepths = @{}
$pathStack = New-Object System.Collections.Generic.List[string]
$progressTimer = [System.Diagnostics.Stopwatch]::StartNew()
$lastFlushMs = -2000

function Write-ProgressSnapshot {
    param([bool]$Force = $false)
    if (-not $ProgressJson) { return }
    if (-not $Force -and ($progressTimer.ElapsedMilliseconds - $lastFlushMs) -lt 1500) { return }
    $script:lastFlushMs = $progressTimer.ElapsedMilliseconds

    $liveDirs = @()
    if ($LiveTree) {
        if ($pendingBytes -gt 0) {
            $maxIdx = if ($pathStack.Count - 1 -lt $ReportDepth) { $pathStack.Count - 1 } else { $ReportDepth }
            for ($i = 0; $i -le $maxIdx; $i++) {
                $p = $pathStack[$i]
                if (-not $liveTotals.ContainsKey($p)) { $liveTotals[$p] = [int64]0 }
                $liveTotals[$p] += $pendingBytes
            }
            $script:pendingBytes = 0
        }
        $liveDirs = foreach ($kv in $liveTotals.GetEnumerator()) {
            if ($liveDepths[$kv.Key] -le $ReportDepth) {
                [pscustomobject]@{ Path = $kv.Key; Depth = $liveDepths[$kv.Key]; Bytes = $kv.Value }
            }
        }
    }
    $snap = [pscustomobject]@{
        DriveRoot     = $DriveRoot
        FilesScanned  = $filesScanned
        BytesScanned  = $bytesScanned
        CurrentPath   = $currentPath
        ElapsedSec    = [math]::Round($progressTimer.Elapsed.TotalSeconds, 1)
        Done          = $Force
        Directories   = @($liveDirs)
    }
    try {
        $j = $snap | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::WriteAllText($ProgressJson, $j, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function ConvertTo-LongPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-LongPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Scan-Dir {
    param([string]$Path, [int]$Depth)

    $totalBytes = [int64]0
    $longPath = ConvertTo-LongPath $Path
    $displayPath = ConvertFrom-LongPath $Path
    $script:currentPath = $displayPath
    if ($LiveTree) {
        $pathStack.Add($displayPath)
        $liveDepths[$displayPath] = $Depth
    }
    # Extension breakdown of files DIRECTLY in this folder (not descendants -
    # a local hashtable, not the global ancestor-walk that turned out to be
    # expensive earlier). Lets the treemap color a folder tile by its
    # dominant file type, WinDirStat-style, instead of only by category.
    # Only tracked for folders that will actually be reported (depth <=
    # ReportDepth) - measured real time wasted computing this for folders
    # buried deeper than that (e.g. iTunes's Album Artwork cache, 9+ levels
    # deep on a real drive) that get thrown away unused.
    $trackOwnExt = $Depth -le $ReportDepth
    $ownExtBytes = @{}

    try {
        $dirInfo = New-Object System.IO.DirectoryInfo($longPath)

        try {
            $entries = $dirInfo.EnumerateFileSystemInfos()
        } catch {
            $skipped.Add("$displayPath :: $($_.Exception.GetType().Name): $($_.Exception.Message)") | Out-Null
            return 0
        }

        try {
            foreach ($entry in $entries) {
                if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($entry -is [System.IO.DirectoryInfo]) {
                    if ($excludeNames -contains $entry.Name) { continue }
                    $totalBytes += (Scan-Dir -Path $entry.FullName -Depth ($Depth + 1))
                } else {
                    $sz = $entry.Length
                    $totalBytes += $sz
                    $script:filesScanned++
                    $script:bytesScanned += $sz
                    if ($LiveTree) { $script:pendingBytes += $sz }
                    Write-ProgressSnapshot

                    $ext = $entry.Extension.ToLower()
                    if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
                    if (-not $extTotals.ContainsKey($ext)) { $extTotals[$ext] = @{Count=0; Bytes=[int64]0} }
                    $extTotals[$ext].Count++
                    $extTotals[$ext].Bytes += $sz
                    if ($trackOwnExt) {
                        if (-not $ownExtBytes.ContainsKey($ext)) { $ownExtBytes[$ext] = [int64]0 }
                        $ownExtBytes[$ext] += $sz
                    }

                    if ($topFiles.Count -lt $TopFilesCount) {
                        $topFiles.Add([pscustomobject]@{Path=(ConvertFrom-LongPath $entry.FullName); Bytes=$sz; LastWrite=$entry.LastWriteTime.ToString('o')})
                        if ($topFiles.Count -eq $TopFilesCount) {
                            $minBytes = ($topFiles | Measure-Object -Property Bytes -Minimum).Minimum
                        }
                    } elseif ($sz -gt $minBytes) {
                        $minItem = $topFiles | Sort-Object Bytes | Select-Object -First 1
                        $topFiles.Remove($minItem) | Out-Null
                        $topFiles.Add([pscustomobject]@{Path=(ConvertFrom-LongPath $entry.FullName); Bytes=$sz; LastWrite=$entry.LastWriteTime.ToString('o')})
                        $minBytes = ($topFiles | Measure-Object -Property Bytes -Minimum).Minimum
                    }
                }
            }
        } catch {
            $skipped.Add("$displayPath :: (enum error) $($_.Exception.GetType().Name): $($_.Exception.Message)") | Out-Null
        }

        if ($Depth -le $ReportDepth) {
            $domExt = $null
            $domExtBytes = [int64]0
            if ($ownExtBytes.Count -gt 0) {
                $top = $ownExtBytes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
                $domExt = $top.Key
                $domExtBytes = $top.Value
            }
            # DominantExtBytes lets the client decide whether this extension
            # is actually representative of the folder (e.g. a folder that's
            # 99% subfolders with one stray .ini file directly in it) or just
            # noise - it only means something as a fraction of Bytes (the
            # folder's full subtree total), which the client already has.
            $dirReport.Add([pscustomobject]@{Path=$displayPath; Depth=$Depth; Bytes=$totalBytes; DominantExt=$domExt; DominantExtBytes=$domExtBytes}) | Out-Null
        }

        return $totalBytes
    } finally {
        if ($LiveTree) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }
}

$start = Get-Date
$grandTotal = Scan-Dir -Path $DriveRoot -Depth 0
$elapsed = (Get-Date) - $start

$result = [pscustomobject]@{
    DriveRoot     = $DriveRoot
    ScannedAt     = (Get-Date).ToString('o')
    ElapsedSec    = [math]::Round($elapsed.TotalSeconds, 1)
    TotalBytes    = $grandTotal
    Directories   = $dirReport
    TopExtensions = ($extTotals.GetEnumerator() | ForEach-Object { [pscustomobject]@{Ext=$_.Key; Count=$_.Value.Count; Bytes=$_.Value.Bytes} } | Sort-Object Bytes -Descending | Select-Object -First 80)
    TopFiles      = ($topFiles | Sort-Object Bytes -Descending)
    SkippedCount  = $skipped.Count
    SkippedSample = ($skipped | Select-Object -First 30)
}

$json = $result | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-ProgressSnapshot -Force $true
Write-Output "DONE $DriveRoot elapsed=$($elapsed.TotalSeconds)s total=$grandTotal skipped=$($skipped.Count)"
