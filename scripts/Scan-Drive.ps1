<#
.SYNOPSIS
  Single-pass recursive scanner for one drive root. Emits folder sizes (by depth),
  top file extensions, and top individual files as JSON.

.NOTES
  Uses raw .NET enumeration instead of Get-ChildItem -Recurse for speed on
  multi-terabyte drives. Reparse points (junctions/symlinks) are skipped to
  avoid double-counting and infinite loops.

  Known limitation: classic Windows PowerShell 5.1 path handling hits the
  260-character MAX_PATH limit on some deeply nested folders (common inside
  old backup sets). Those subtrees are recorded in SkippedSample rather than
  silently mis-measured. See README "Known limitations".
#>
param(
    [Parameter(Mandatory)] [string]$DriveRoot,
    [Parameter(Mandatory)] [string]$OutJson,
    [int]$ReportDepth = 5,
    [int]$TopFilesCount = 300
)

$ErrorActionPreference = 'SilentlyContinue'

$extTotals = @{}
$topFiles = New-Object System.Collections.Generic.List[object]
$dirReport = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$minBytes = [int64]0
$excludeNames = @('System Volume Information', '$RECYCLE.BIN', 'Recovery')

function Scan-Dir {
    param([string]$Path, [int]$Depth)

    $totalBytes = [int64]0
    $dirInfo = New-Object System.IO.DirectoryInfo($Path)

    try {
        $entries = $dirInfo.EnumerateFileSystemInfos()
    } catch {
        $skipped.Add($Path) | Out-Null
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

                $ext = $entry.Extension.ToLower()
                if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
                if (-not $extTotals.ContainsKey($ext)) { $extTotals[$ext] = @{Count=0; Bytes=[int64]0} }
                $extTotals[$ext].Count++
                $extTotals[$ext].Bytes += $sz

                if ($topFiles.Count -lt $TopFilesCount) {
                    $topFiles.Add([pscustomobject]@{Path=$entry.FullName; Bytes=$sz; LastWrite=$entry.LastWriteTime.ToString('o')})
                    if ($topFiles.Count -eq $TopFilesCount) {
                        $minBytes = ($topFiles | Measure-Object -Property Bytes -Minimum).Minimum
                    }
                } elseif ($sz -gt $minBytes) {
                    $minItem = $topFiles | Sort-Object Bytes | Select-Object -First 1
                    $topFiles.Remove($minItem) | Out-Null
                    $topFiles.Add([pscustomobject]@{Path=$entry.FullName; Bytes=$sz; LastWrite=$entry.LastWriteTime.ToString('o')})
                    $minBytes = ($topFiles | Measure-Object -Property Bytes -Minimum).Minimum
                }
            }
        }
    } catch {
        $skipped.Add("$Path (enum error)") | Out-Null
    }

    if ($Depth -le $ReportDepth) {
        $dirReport.Add([pscustomobject]@{Path=$Path; Depth=$Depth; Bytes=$totalBytes}) | Out-Null
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

$result | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath $OutJson -Encoding utf8
Write-Output "DONE $DriveRoot elapsed=$($elapsed.TotalSeconds)s total=$grandTotal skipped=$($skipped.Count)"
