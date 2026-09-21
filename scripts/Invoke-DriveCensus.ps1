<#
.SYNOPSIS
  DriveMinder orchestrator: discovers local drives, scans each in parallel,
  and renders a self-contained HTML dashboard.

.EXAMPLE
  .\Invoke-DriveCensus.ps1
      Scans every fixed/removable drive and opens the resulting dashboard.

.EXAMPLE
  .\Invoke-DriveCensus.ps1 -DriveLetters C,D -NoOpen
      Scans only C: and D:, writes the report without opening a browser.
#>
param(
    [string[]]$DriveLetters,
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'output'),
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scanScript = Join-Path $PSScriptRoot 'Scan-Drive.ps1'
$templatePath = Join-Path $root 'dashboard\template.html'

if (-not (Test-Path $scanScript)) { throw "Scan-Drive.ps1 not found at $scanScript" }
if (-not (Test-Path $templatePath)) { throw "dashboard\template.html not found at $templatePath" }

if ($DriveLetters) {
    # Accept "C,D", "C, D", or separate -DriveLetters C D tokens - all normalize
    # to single letters. (A bare comma-joined string arrives as ONE element
    # when this script is invoked via `powershell -File`, since that comma
    # is never parsed as PowerShell's array operator in that context.)
    $DriveLetters = $DriveLetters |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().TrimEnd(':') } |
        Where-Object { $_ -match '^[A-Za-z]$' }
}

if (-not $DriveLetters) {
    # DriveType 2 = removable, 3 = fixed local disk. Excludes 4 (network) and 5 (CD/DVD).
    $vols = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3 }
    $DriveLetters = $vols | ForEach-Object { $_.DeviceID.TrimEnd(':') } | Sort-Object
}

if (-not $DriveLetters) { throw "No fixed or removable drives found to scan." }

Write-Host "DriveMinder: scanning $($DriveLetters -join ', ')..." -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$runDir = Join-Path $OutputDir $timestamp
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$progressFiles = @{}
$jobs = foreach ($d in $DriveLetters) {
    $outJson = Join-Path $runDir "scan_$d.json"
    $progJson = Join-Path $runDir "progress_$d.json"
    $progressFiles[$d] = $progJson
    Start-Job -Name "scan_$d" -ArgumentList $scanScript, $d, $outJson, $progJson -ScriptBlock {
        param($script, $letter, $out, $prog)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -DriveRoot "$letter`:\" -OutJson $out -ProgressJson $prog
    }
}

Write-Host "Waiting for $($jobs.Count) scan job(s) to finish (this can take a few minutes on large drives)..."

# Poll each job's progress snapshot rather than blocking silently - not the
# live animated treemap WinDirStat shows (that needs a browser-side live
# view, which is a bigger future feature), but enough to see it's actually
# working and roughly how far along each drive is.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($jobs | Where-Object { $_.State -eq 'Running' }) {
    Start-Sleep -Milliseconds 2000
    $parts = foreach ($d in $DriveLetters) {
        $pf = $progressFiles[$d]
        if (Test-Path $pf) {
            try {
                $p = Get-Content $pf -Raw | ConvertFrom-Json
                $gb = [math]::Round($p.BytesScanned / 1GB, 1)
                "$d`:$($p.FilesScanned.ToString('N0'))f/${gb}GB"
            } catch { "$d`:starting" }
        } else { "$d`:starting" }
    }
    Write-Host ("  [{0,4:N0}s] {1}" -f $sw.Elapsed.TotalSeconds, ($parts -join '  ')) -ForegroundColor DarkGray
}

foreach ($j in $jobs) {
    Receive-Job -Job $j | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
$jobs | Remove-Job

# ---- gather per-drive capacity + scan payload ----
$drives = @()
foreach ($d in $DriveLetters) {
    $scanFile = Join-Path $runDir "scan_$d.json"
    if (-not (Test-Path $scanFile)) {
        Write-Warning "No scan output for $d`: (job may have failed) - skipping"
        continue
    }
    # -First 1 defends against Get-Volume's -DriveLetter accepting [char[]] and
    # silently matching more than one volume if $d were ever anything but a
    # single clean letter.
    $vol = Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue | Select-Object -First 1
    $scanRaw = Get-Content $scanFile -Raw
    $drives += [pscustomobject]@{
        letter     = $d
        label      = if ($vol) { $vol.FileSystemLabel } else { '' }
        totalBytes = if ($vol) { [int64]$vol.Size } else { $null }
        freeBytes  = if ($vol) { [int64]$vol.SizeRemaining } else { $null }
        scan       = ($scanRaw | ConvertFrom-Json)   # re-hydrate; re-serialized below alongside metadata
    }
}

if (-not $drives) { throw "No successful scans to report on." }

$payload = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    machine     = $env:COMPUTERNAME
    drives      = $drives
}
$payloadJson = $payload | ConvertTo-Json -Depth 8 -Compress

# ---- render dashboard from template ----
# Splice out everything between the start/end markers (including the
# template's own fallback sample data) and drop in the real payload as plain
# concatenation - NOT [regex]::Replace with the payload as the replacement
# string, since .NET regex treats "$" specially there and real folder names
# in this data legitimately contain "$" (e.g. "$Windows.~WS").
$template = Get-Content $templatePath -Raw
$startTok = '/*__DRIVEMINDER_DATA_START__*/'
$endTok = '/*__DRIVEMINDER_DATA_END__*/'
$startIdx = $template.IndexOf($startTok)
$endIdx = $template.IndexOf($endTok)
if ($startIdx -lt 0 -or $endIdx -lt 0) { throw "dashboard\template.html is missing the DRIVEMINDER_DATA placeholder markers" }
$html = $template.Substring(0, $startIdx) + $payloadJson + $template.Substring($endIdx + $endTok.Length)

$reportPath = Join-Path $runDir 'DriveMinder-Report.html'
[System.IO.File]::WriteAllText($reportPath, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Report written to: $reportPath" -ForegroundColor Green

if (-not $NoOpen) {
    Start-Process $reportPath
}
