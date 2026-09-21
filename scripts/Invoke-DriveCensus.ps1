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

$jobs = foreach ($d in $DriveLetters) {
    $outJson = Join-Path $runDir "scan_$d.json"
    Start-Job -Name "scan_$d" -ArgumentList $scanScript, $d, $outJson -ScriptBlock {
        param($script, $letter, $out)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -DriveRoot "$letter`:\" -OutJson $out
    }
}

Write-Host "Waiting for $($jobs.Count) scan job(s) to finish (this can take a few minutes on large drives)..."
$jobs | Wait-Job | Out-Null
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
    $vol = Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue
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
$template = Get-Content $templatePath -Raw
$html = $template.Replace('/*__DRIVEMINDER_DATA__*/', $payloadJson)

$reportPath = Join-Path $runDir 'DriveMinder-Report.html'
$html | Out-File -FilePath $reportPath -Encoding utf8

Write-Host "Report written to: $reportPath" -ForegroundColor Green

if (-not $NoOpen) {
    Start-Process $reportPath
}
