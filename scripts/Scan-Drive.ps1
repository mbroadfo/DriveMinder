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
    [string]$ProgressJson = $null
)

$ErrorActionPreference = 'SilentlyContinue'

$extTotals = @{}
$topFiles = New-Object System.Collections.Generic.List[object]
$dirReport = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$minBytes = [int64]0
$excludeNames = @('System Volume Information', '$RECYCLE.BIN', 'Recovery', 'RECYCLER')

# Progress snapshots: cheap counters flushed to disk on a timer (not on every
# file - that would add real I/O overhead) so a watching process can show
# live "X files / Y GB scanned, currently in <folder>" without needing this
# script to be multithreaded like WinDirStat.
$filesScanned = 0
$bytesScanned = [int64]0
$currentPath = $DriveRoot
$progressTimer = [System.Diagnostics.Stopwatch]::StartNew()
$lastFlushMs = -1000

function Write-ProgressSnapshot {
    param([bool]$Force = $false)
    if (-not $ProgressJson) { return }
    if (-not $Force -and ($progressTimer.ElapsedMilliseconds - $lastFlushMs) -lt 400) { return }
    $script:lastFlushMs = $progressTimer.ElapsedMilliseconds
    $snap = [pscustomobject]@{
        DriveRoot     = $DriveRoot
        FilesScanned  = $filesScanned
        BytesScanned  = $bytesScanned
        CurrentPath   = $currentPath
        ElapsedSec    = [math]::Round($progressTimer.Elapsed.TotalSeconds, 1)
        Done          = $Force
    }
    try {
        $j = $snap | ConvertTo-Json -Compress
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
                Write-ProgressSnapshot

                $ext = $entry.Extension.ToLower()
                if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
                if (-not $extTotals.ContainsKey($ext)) { $extTotals[$ext] = @{Count=0; Bytes=[int64]0} }
                $extTotals[$ext].Count++
                $extTotals[$ext].Bytes += $sz

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
        $dirReport.Add([pscustomobject]@{Path=$displayPath; Depth=$Depth; Bytes=$totalBytes}) | Out-Null
    }

    return $totalBytes
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
