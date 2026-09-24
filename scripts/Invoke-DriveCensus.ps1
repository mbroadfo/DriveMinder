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

.EXAMPLE
  .\Invoke-DriveCensus.ps1 -DriveLetters D -FullRescan
      Ignores any existing cache for D: and does a full walk, same as every
      run did before caching existed. Rebuilds a fresh cache either way.
#>
param(
    [string[]]$DriveLetters,
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'output'),
    [switch]$NoOpen,
    # Passed through to each per-drive Scan-Drive.ps1 job - see its own
    # .NOTES for what the cache does and the one gap it leaves.
    [string]$CacheDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'cache'),
    [switch]$FullRescan,
    [int64]$MinHashBytes = 1048576
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

function Get-FreeLocalPort {
    param([int]$Start = 8787, [int]$MaxTries = 30)
    for ($p = $Start; $p -lt ($Start + $MaxTries); $p++) {
        try {
            $probe = New-Object System.Net.HttpListener
            $probe.Prefixes.Add("http://127.0.0.1:$p/")
            $probe.Start()
            $probe.Stop()
            return $p
        } catch { continue }
    }
    return $null
}

Write-Host "DriveMinder: scanning $($DriveLetters -join ', ')..." -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$runDir = Join-Path $OutputDir $timestamp
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

# The rich per-folder live tree (needed for the browser's live treemap) has
# a real cost - measured ~40% slower on a real 887GB drive than plain
# scalar progress - so only pay it when something will actually be watching.
# -NoOpen means nobody will.
$wantLiveView = -not $NoOpen

$progressFiles = @{}
# Not `$x = if (...) { @(...) } else { @() }` - PowerShell unrolls a
# single-element array returned from an if/else expression down to its bare
# scalar element when it's captured by assignment (a classic, easy-to-miss
# gotcha). That turned '-LiveTree' into a plain string here, which silently
# broke `@extraArgs` splatting below and crashed every scan job instantly
# (caught by running with diagnostic logging: extraArgs came through typed
# as System.String, not an array). Building the array via a plain += avoids
# the unrolling entirely.
$extraArgs = @()
if ($wantLiveView) { $extraArgs += '-LiveTree' }
$extraArgs += '-CacheDir'
$extraArgs += $CacheDir
$extraArgs += '-MinHashBytes'
$extraArgs += $MinHashBytes
if ($FullRescan) { $extraArgs += '-FullRescan' }

$jobs = foreach ($d in $DriveLetters) {
    $outJson = Join-Path $runDir "scan_$d.json"
    $progJson = Join-Path $runDir "progress_$d.json"
    $progressFiles[$d] = $progJson
    Start-Job -Name "scan_$d" -ArgumentList $scanScript, $d, $outJson, $progJson, $extraArgs -ScriptBlock {
        param($script, $letter, $out, $prog, $extraArgs)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -DriveRoot "$letter`:\" -OutJson $out -ProgressJson $prog @extraArgs
    }
}

# ---- live browser view: same dashboard page, fed by a poll endpoint instead
# of a one-time static payload, so it can be watched while scanning runs ----
$liveJob = $null
$livePort = $null
if ($wantLiveView) {
    $livePort = Get-FreeLocalPort
    if ($livePort) {
        $liveJob = Start-Job -Name 'liveserver' -ArgumentList $livePort, $runDir, $DriveLetters, $templatePath -ScriptBlock {
            param($port, $runDir, $driveLetters, $templatePath)

            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            # Serve the template with its sample-data placeholder untouched -
            # the page's own JS treats an empty drives[] as "poll /live-data"
            # instead of "render this once and stop", so this exact same file
            # doubles as both the live view and (once statically re-rendered
            # by the parent script at the end) the final report.
            # Explicit -Encoding UTF8 on every read below: everything this tool
            # writes is BOM-less UTF-8, and Windows PowerShell's Get-Content
            # otherwise assumes the ANSI codepage, garbling non-ASCII text
            # (em dashes in the dashboard, accented folder names in scan data).
            $templateText = Get-Content $templatePath -Raw -Encoding UTF8

            function Get-LiveDrives {
                $result = @()
                foreach ($d in $driveLetters) {
                    $outJson = Join-Path $runDir "scan_$d.json"
                    $progJson = Join-Path $runDir "progress_$d.json"
                    $vol = Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue | Select-Object -First 1
                    $scanObj = $null
                    if (Test-Path $outJson) {
                        try { $scanObj = Get-Content $outJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
                        if ($scanObj) { $scanObj | Add-Member -NotePropertyName Done -NotePropertyValue $true -Force }
                    }
                    if (-not $scanObj -and (Test-Path $progJson)) {
                        try {
                            $p = Get-Content $progJson -Raw -Encoding UTF8 | ConvertFrom-Json
                            $scanObj = [pscustomobject]@{
                                DriveRoot     = $p.DriveRoot
                                TotalBytes    = $p.BytesScanned
                                Directories   = @($p.Directories)
                                TopExtensions = @()
                                TopFiles      = @()
                                SkippedCount  = 0
                                SkippedSample = @()
                                ElapsedSec    = $p.ElapsedSec
                                Done          = $false
                            }
                        } catch {}
                    }
                    if ($scanObj) {
                        $result += [pscustomobject]@{
                            letter     = $d
                            label      = if ($vol) { $vol.FileSystemLabel } else { '' }
                            totalBytes = if ($vol) { [int64]$vol.Size } else { $null }
                            freeBytes  = if ($vol) { [int64]$vol.SizeRemaining } else { $null }
                            scan       = $scanObj
                        }
                    }
                }
                return $result
            }

            while ($listener.IsListening) {
                try { $ctx = $listener.GetContext() } catch { break }
                $req = $ctx.Request
                $res = $ctx.Response
                try {
                    if ($req.Url.AbsolutePath -eq '/live-data') {
                        $payload = [pscustomobject]@{ generatedAt = (Get-Date).ToString('o'); machine = $env:COMPUTERNAME; drives = @(Get-LiveDrives) }
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
                        $res.ContentType = 'application/json'
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($templateText)
                        $res.ContentType = 'text/html; charset=utf-8'
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                } catch {
                } finally {
                    $res.OutputStream.Close()
                }
            }
        }
        Start-Sleep -Milliseconds 300
        Write-Host "Live scan view: http://127.0.0.1:$livePort/" -ForegroundColor Cyan
        Start-Process "http://127.0.0.1:$livePort/"
    } else {
        Write-Warning "Could not find a free local port for the live scan view - continuing without it."
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
    $scanRaw = Get-Content $scanFile -Raw -Encoding UTF8
    # Scan-Drive.ps1's own output has no Done field - that's only ever added
    # by the live server's Get-LiveDrives when a poll catches a finished scan.
    # Without setting it here too, every FINISHED static report rendered
    # `scanning = true` forever (renderAll checks `d.scan.Done`), showing a
    # permanent "Scanning..." badge and "still scanning" footer text on a
    # report that was actually 100% complete - caught by actually opening a
    # real generated report instead of only reading the template's client
    # logic, which never surfaced it since it reads correctly in isolation.
    $scanObj = $scanRaw | ConvertFrom-Json
    $scanObj | Add-Member -NotePropertyName Done -NotePropertyValue $true -Force
    if ($scanObj.CacheStats) {
        $cs = $scanObj.CacheStats
        Write-Host "  $d`: dirs reused $($cs.DirsReused)/$($cs.DirsTotal), files hashed $($cs.FilesHashed) (walk $($scanObj.WalkElapsedSec)s, hash $($scanObj.HashElapsedSec)s)" -ForegroundColor DarkGray
    }
    $drives += [pscustomobject]@{
        letter     = $d
        label      = if ($vol) { $vol.FileSystemLabel } else { '' }
        totalBytes = if ($vol) { [int64]$vol.Size } else { $null }
        freeBytes  = if ($vol) { [int64]$vol.SizeRemaining } else { $null }
        scan       = $scanObj
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
$template = Get-Content $templatePath -Raw -Encoding UTF8
$startTok = '/*__DRIVEMINDER_DATA_START__*/'
$endTok = '/*__DRIVEMINDER_DATA_END__*/'
$startIdx = $template.IndexOf($startTok)
$endIdx = $template.IndexOf($endTok)
if ($startIdx -lt 0 -or $endIdx -lt 0) { throw "dashboard\template.html is missing the DRIVEMINDER_DATA placeholder markers" }
$html = $template.Substring(0, $startIdx) + $payloadJson + $template.Substring($endIdx + $endTok.Length)

$reportPath = Join-Path $runDir 'DriveMinder-Report.html'
[System.IO.File]::WriteAllText($reportPath, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Report written to: $reportPath" -ForegroundColor Green

if ($liveJob) {
    # The already-open browser tab keeps whatever it last polled (which, by
    # now, is the complete final data - same shape either way) even after
    # this stops responding; it just can't be refreshed anymore. That's why
    # the static file below still gets written regardless.
    Stop-Job -Job $liveJob -ErrorAction SilentlyContinue
    Remove-Job -Job $liveJob -Force -ErrorAction SilentlyContinue
} elseif (-not $NoOpen) {
    Start-Process $reportPath
}
