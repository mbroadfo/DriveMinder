<#
.SYNOPSIS
  Single-pass recursive scanner for one drive root. Emits folder sizes (by depth),
  top file extensions, top individual files, and hash-confirmed duplicate groups
  as JSON. Persists a per-drive cache so a later run can skip re-reading
  unchanged folders and never re-hashes a file whose size/mtime haven't changed.

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

  Incremental refresh: NTFS only updates a directory's own LastWriteTime when
  its IMMEDIATE entries are added/removed/renamed - never when something
  changes further down inside a child directory. So recursion never stops
  early on a cache hit - every directory is still visited and mtime-checked
  on every run. What a hit skips is specifically the expensive part -
  re-reading that one directory's own file listing (EnumerateFileSystemInfos)
  - while its child directories are still individually recursed into and
  independently re-checked. The one gap this leaves: a file edited in place
  (same name, same size, content silently overwritten) inside a directory
  whose own mtime doesn't change for any other reason. Narrow in practice
  (most editors write-to-temp-then-rename, which does bump the parent's
  mtime) - -FullRescan is the escape hatch when it matters.
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
    [switch]$LiveTree,
    # Per-drive cache of folder mtimes + a large-file index (path/size/mtime/
    # hash), used to skip re-reading unchanged folders and to never re-hash a
    # file that hasn't changed. Same directory across runs - not timestamped
    # like -OutJson - since it represents "latest known state," not history.
    [string]$CacheDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'cache'),
    # Ignore the cache entirely and do a full walk (still writes a fresh
    # cache at the end, so the NEXT normal run benefits). The manual escape
    # hatch for the narrow in-place-edit gap described above.
    [switch]$FullRescan,
    # Only files this large or bigger are indexed for duplicate hashing (and
    # therefore persisted in the file cache at all) - skips the flood of tiny
    # files that dominate count but not reclaimable space or dedup value.
    [int64]$MinHashBytes = 1048576,
    # How often the (potentially very long) hash pass saves its progress to
    # the file cache, so an interrupted run keeps the hashes computed so far
    # instead of losing all of them.
    [int]$CheckpointSeconds = 60
)

$ErrorActionPreference = 'SilentlyContinue'

$extTotals = @{}
$topFiles = New-Object System.Collections.Generic.List[object]
$dirReport = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$minBytes = [int64]0
$excludeNames = @('System Volume Information', '$RECYCLE.BIN', 'Recovery', 'RECYCLER')

# Cache write-back accumulators (see .NOTES). Rebuilt fresh every run -
# never patched onto the old cache - so anything not re-visited this run
# (deleted/renamed away) is simply absent from the new cache with no extra
# bookkeeping. $cacheStats is purely diagnostic (surfaced in the output JSON
# and the DONE line) so a run's actual reuse/hash rate is measured, not
# assumed.
$folderCacheOut = New-Object System.Collections.Generic.List[object]
$fileIndexOut = New-Object System.Collections.Generic.List[object]
$cacheStats = @{ DirsTotal = 0; DirsReused = 0; FilesIndexed = 0; FilesHashed = 0 }
$scanPhase = 'scanning'

$driveLetter = $DriveRoot.Substring(0, 1)
$folderCachePath = Join-Path $CacheDir "${driveLetter}_folders.json"
$fileCachePath = Join-Path $CacheDir "${driveLetter}_files.tsv"

# ---- load previous cache (best-effort - any failure just means every
# folder/file below misses and gets freshly scanned, same as today) ----
$cacheFolders = @{}       # display path -> cached folder row
$childrenByParent = @{}   # parent display path -> List[child display path]
if (-not $FullRescan -and (Test-Path $folderCachePath)) {
    try {
        # NOT `@(Get-Content ... | ConvertFrom-Json)` - wrapping a
        # ConvertFrom-Json PIPELINE (as opposed to an already-assigned
        # variable) in `@()` double-wraps a multi-element JSON array into a
        # single-element array containing the whole thing, silently breaking
        # every lookup below (confirmed empirically: a direct assignment from
        # the same pipeline gives the correct flat array; re-wrapping that
        # variable in @() afterward is fine - only wrapping the live pipeline
        # expression itself triggers this). `foreach` below tolerates the
        # single-cached-folder edge case fine either way, so no @() is needed.
        # Read as explicit UTF-8: the cache is written BOM-less, and Windows
        # PowerShell's Get-Content assumes the ANSI codepage without a BOM, so
        # any accented/non-ASCII folder name came back garbled ("EspaÃ±a") and
        # a cache hit then recursed into a path that doesn't exist.
        $prevRows = [System.IO.File]::ReadAllText($folderCachePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        foreach ($row in $prevRows) {
            $cacheFolders[$row.Path] = $row
            # Root's own row has no parent - never looked up as a dictionary
            # key (root is always the explicit scan entry point, never
            # discovered via someone else's child list), and a classic
            # Hashtable throws on a $null key, so it's simply skipped here.
            if ($row.Parent) {
                if (-not $childrenByParent.ContainsKey($row.Parent)) {
                    $childrenByParent[$row.Parent] = New-Object System.Collections.Generic.List[string]
                }
                $childrenByParent[$row.Parent].Add($row.Path)
            }
        }
    } catch {
        $cacheFolders = @{}
        $childrenByParent = @{}
    }
}

function Get-ParentPath {
    # A file's parent computed by trimming to the last backslash normally
    # matches a non-root folder's stored path exactly (both lack a trailing
    # backslash). The drive root is the one exception - $DriveRoot arrives
    # as "X:\" (WITH a trailing backslash) - so a loose file directly at the
    # root needs that backslash added back to match.
    param([string]$FilePath)
    $idx = $FilePath.LastIndexOf('\')
    $parent = $FilePath.Substring(0, $idx)
    if ($parent.Length -eq 2 -and $parent[1] -eq ':') { $parent += '\' }
    return $parent
}

$fileIndexByParent = @{}   # parent display path -> List[cached file row]
$fileIndexByPath = @{}     # display path -> cached file row
if (-not $FullRescan -and (Test-Path $fileCachePath)) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($fileCachePath)) {
            if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
            $parts = $line.Split("`t")
            if ($parts.Length -lt 6) { continue }
            $row = [pscustomobject]@{
                Path = $parts[0]; Bytes = [int64]$parts[1]; MTimeTicks = [int64]$parts[2]
                LastWrite = $parts[3]; PartialHash = $parts[4]; FullHash = $parts[5]
            }
            $fileIndexByPath[$row.Path] = $row
            $parent = Get-ParentPath $row.Path
            if (-not $fileIndexByParent.ContainsKey($parent)) {
                $fileIndexByParent[$parent] = New-Object System.Collections.Generic.List[object]
            }
            $fileIndexByParent[$parent].Add($row)
        }
    } catch {
        $fileIndexByParent = @{}
        $fileIndexByPath = @{}
    }
}

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
        Phase         = $scanPhase
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

# Shared by both the fresh-scan and cache-hit-reuse paths so a file counts
# toward TopFiles the same way regardless of which branch produced it.
function Add-TopFileCandidate {
    param([string]$RecPath, [int64]$RecBytes, [string]$RecLastWrite)
    if ($script:topFiles.Count -lt $TopFilesCount) {
        $script:topFiles.Add([pscustomobject]@{Path=$RecPath; Bytes=$RecBytes; LastWrite=$RecLastWrite})
        if ($script:topFiles.Count -eq $TopFilesCount) {
            $script:minBytes = ($script:topFiles | Measure-Object -Property Bytes -Minimum).Minimum
        }
    } elseif ($RecBytes -gt $script:minBytes) {
        $minItem = $script:topFiles | Sort-Object Bytes | Select-Object -First 1
        $script:topFiles.Remove($minItem) | Out-Null
        $script:topFiles.Add([pscustomobject]@{Path=$RecPath; Bytes=$RecBytes; LastWrite=$RecLastWrite})
        $script:minBytes = ($script:topFiles | Measure-Object -Property Bytes -Minimum).Minimum
    }
}

# First 64KB + last 64KB via raw .NET incremental hashing - Get-FileHash only
# hashes a whole stream start-to-EOF, there's no byte-range parameter. Cheap
# pre-filter before paying for a full-file read. $MinHashBytes defaults well
# above 2x this window, so candidates are guaranteed non-overlapping windows
# by construction (only a concern if someone configures a tiny -MinHashBytes).
function Get-PartialHash {
    param([string]$LongPath, [int64]$FileSize)
    $window = 65536
    try {
        $fs = [System.IO.File]::OpenRead($LongPath)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $buf1 = New-Object byte[] $window
            $read1 = $fs.Read($buf1, 0, $window)
            [void]$sha.TransformBlock($buf1, 0, $read1, $buf1, 0)
            $fs.Seek(-$window, [System.IO.SeekOrigin]::End) | Out-Null
            $buf2 = New-Object byte[] $window
            $read2 = $fs.Read($buf2, 0, $window)
            [void]$sha.TransformFinalBlock($buf2, 0, $read2)
            return [System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLower()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Scan-Dir {
    param([string]$Path, [int]$Depth, [string]$ParentPath = $null)

    $totalBytes = [int64]0
    $longPath = ConvertTo-LongPath $Path
    $displayPath = ConvertFrom-LongPath $Path
    $script:currentPath = $displayPath
    if ($LiveTree) {
        $pathStack.Add($displayPath)
        $liveDepths[$displayPath] = $Depth
    }
    $script:cacheStats.DirsTotal++

    # Cheap stat, no enumeration - decides whether this folder's own file
    # listing can be trusted from cache instead of re-read from disk. A
    # non-existent/inaccessible path returns a sentinel low date rather than
    # throwing, which naturally forces a miss (see .NOTES for the full
    # correctness reasoning behind why a hit never skips recursion itself).
    $curMTimeTicks = $null
    try { $curMTimeTicks = ([System.IO.Directory]::GetLastWriteTimeUtc($longPath)).Ticks } catch {}

    $cacheRow = $cacheFolders[$displayPath]
    $isHit = (-not $FullRescan) -and $cacheRow -and $curMTimeTicks -and ($cacheRow.MTimeUtc -eq $curMTimeTicks)

    $ownExtOut = @()
    $domExt = $null
    $domExtBytes = [int64]0
    # Initialized here, not in the miss branch: PowerShell reads an unassigned
    # variable from the CALLER's scope, so a cache-hit call would otherwise
    # inherit its parent's flag.
    $enumFailed = $false

    try {
        if ($isHit) {
            $script:cacheStats.DirsReused++

            $ownBytes = [int64]0
            foreach ($e in $cacheRow.OwnExt) {
                $ownBytes += $e.Bytes
                if (-not $extTotals.ContainsKey($e.Ext)) { $extTotals[$e.Ext] = @{Count=0; Bytes=[int64]0} }
                $extTotals[$e.Ext].Count += $e.Count
                $extTotals[$e.Ext].Bytes += $e.Bytes
            }
            $totalBytes += $ownBytes
            $ownExtOut = $cacheRow.OwnExt
            $domExt = $cacheRow.DominantExt
            $domExtBytes = $cacheRow.DominantExtBytes

            # This folder's own files weren't re-touched, so their cached
            # hashes (if any) stay valid - carried forward unchanged into
            # this run's TopFiles pool and file index.
            $ownFileRows = $fileIndexByParent[$displayPath]
            if ($ownFileRows) {
                foreach ($fr in $ownFileRows) {
                    $script:fileIndexOut.Add($fr)
                    Add-TopFileCandidate -RecPath $fr.Path -RecBytes $fr.Bytes -RecLastWrite $fr.LastWrite
                }
            }

            $kids = $childrenByParent[$displayPath]
            if ($kids) {
                foreach ($childPath in $kids) {
                    $totalBytes += (Scan-Dir -Path $childPath -Depth ($Depth + 1) -ParentPath $displayPath)
                }
            }
        } else {
            $dirInfo = New-Object System.IO.DirectoryInfo($longPath)

            try {
                $entries = $dirInfo.EnumerateFileSystemInfos()
            } catch {
                $skipped.Add("$displayPath :: $($_.Exception.GetType().Name): $($_.Exception.Message)") | Out-Null
                return 0
            }

            $ownExtBytes = @{}
            try {
                foreach ($entry in $entries) {
                    if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($entry -is [System.IO.DirectoryInfo]) {
                        if ($excludeNames -contains $entry.Name) { continue }
                        $totalBytes += (Scan-Dir -Path $entry.FullName -Depth ($Depth + 1) -ParentPath $displayPath)
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
                        if (-not $ownExtBytes.ContainsKey($ext)) { $ownExtBytes[$ext] = @{Count=0; Bytes=[int64]0} }
                        $ownExtBytes[$ext].Count++
                        $ownExtBytes[$ext].Bytes += $sz

                        $filePath = ConvertFrom-LongPath $entry.FullName
                        # A file with an unrepresentable timestamp (seen on a real
                        # drive: three old GIFs) reads back as $null in Windows
                        # PowerShell, and calling a method on it throws - which
                        # aborts the whole folder's enumeration. Only top-N files
                        # used to touch this; now every file does.
                        $lwt = $entry.LastWriteTime
                        $lastWriteStr = if ($lwt) { $lwt.ToString('o') } else { '' }
                        Add-TopFileCandidate -RecPath $filePath -RecBytes $sz -RecLastWrite $lastWriteStr

                        if ($sz -ge $MinHashBytes) {
                            $script:cacheStats.FilesIndexed++
                            $lwtUtc = $entry.LastWriteTimeUtc
                            $mTicks = if ($lwtUtc) { $lwtUtc.Ticks } else { [int64]0 }
                            # A per-file carry-forward even though the DIRECTORY
                            # missed - a folder going dirty for one unrelated
                            # reason (one new file added) shouldn't force every
                            # other unchanged file in it to be rehashed.
                            $prevRow = $fileIndexByPath[$filePath]
                            $partialHash = ''
                            $fullHash = ''
                            if ($prevRow -and $prevRow.Bytes -eq $sz -and $prevRow.MTimeTicks -eq $mTicks) {
                                $partialHash = $prevRow.PartialHash
                                $fullHash = $prevRow.FullHash
                            }
                            $script:fileIndexOut.Add([pscustomobject]@{Path=$filePath; Bytes=$sz; MTimeTicks=$mTicks; LastWrite=$lastWriteStr; PartialHash=$partialHash; FullHash=$fullHash})
                        }
                    }
                }
            } catch {
                $skipped.Add("$displayPath :: (enum error) $($_.Exception.GetType().Name): $($_.Exception.Message)") | Out-Null
                $enumFailed = $true
            }

            $ownExtOut = foreach ($kv in $ownExtBytes.GetEnumerator()) {
                [pscustomobject]@{Ext=$kv.Key; Count=$kv.Value.Count; Bytes=$kv.Value.Bytes}
            }
            $ownExtOut = @($ownExtOut)
            if ($ownExtOut.Count -gt 0) {
                $top = $ownExtOut | Sort-Object -Property Bytes -Descending | Select-Object -First 1
                $domExt = $top.Ext
                $domExtBytes = $top.Bytes
            }
        }

        # DominantExtBytes lets the client decide whether this extension is
        # actually representative of the folder (e.g. a folder that's 99%
        # subfolders with one stray .ini file directly in it) or just noise -
        # it only means something as a fraction of Bytes (the folder's full
        # subtree total), which the client already has. Directories[] stays
        # ReportDepth-gated exactly as before, for dashboard compatibility.
        if ($Depth -le $ReportDepth) {
            $dirReport.Add([pscustomobject]@{Path=$displayPath; Depth=$Depth; Bytes=$totalBytes; DominantExt=$domExt; DominantExtBytes=$domExtBytes}) | Out-Null
        }

        # The cache's own folder index is NOT ReportDepth-bounded - a folder
        # buried deeper than that still needs a row or it can never become a
        # hit on a later run (this is new vs. the treemap-coloring feature's
        # own OwnExt tracking, which deliberately WAS ReportDepth-gated
        # because that data was only ever used for the UI). Skipped when the
        # mtime stat itself failed (permission-denied etc.) - same as today,
        # such folders simply have no cache row and are retried fresh every run.
        # Same for a folder whose enumeration failed partway: its listing is
        # incomplete, and caching it would make every later hit silently reuse
        # the truncated result.
        if ($curMTimeTicks -and -not $enumFailed) {
            $script:folderCacheOut.Add([pscustomobject]@{
                Path = $displayPath; Parent = $ParentPath; Depth = $Depth; Bytes = $totalBytes
                MTimeUtc = $curMTimeTicks; OwnExt = $ownExtOut; DominantExt = $domExt; DominantExtBytes = $domExtBytes
            }) | Out-Null
        }

        return $totalBytes
    } finally {
        if ($LiveTree) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }
}

# Cache writes are best-effort (a failed write just means the next run falls
# back to a full rescan for this drive) and atomic: written to a .tmp file
# first, then swapped in, so a killed run leaves the previous cache intact
# rather than a half-written one. File.Replace swaps in one step when a
# destination exists - a delete-then-move would leave a window with no cache
# at all, which matters now that the file cache is rewritten repeatedly.
function Publish-CacheFile {
    param([string]$Tmp, [string]$Dest)
    # [NullString]::Value, not $null: PowerShell coerces a plain $null to ""
    # for a .NET string parameter, which Replace rejects as an empty path -
    # and the surrounding best-effort catch blocks would swallow that
    # silently, leaving the stale cache in place with no visible error.
    if (Test-Path $Dest) { [System.IO.File]::Replace($Tmp, $Dest, [NullString]::Value) }
    else { [System.IO.File]::Move($Tmp, $Dest) }
}

function Write-FolderCache {
    try {
        if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
        $folderJson = $folderCacheOut | ConvertTo-Json -Depth 6 -Compress
        $folderTmp = "$folderCachePath.tmp"
        [System.IO.File]::WriteAllText($folderTmp, $folderJson, (New-Object System.Text.UTF8Encoding($false)))
        Publish-CacheFile -Tmp $folderTmp -Dest $folderCachePath
    } catch {}
}

function Write-FileCache {
    try {
        if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
        $fileTmp = "$fileCachePath.tmp"
        $streamWriter = New-Object System.IO.StreamWriter($fileTmp, $false, (New-Object System.Text.UTF8Encoding($false)))
        try {
            $streamWriter.WriteLine('#v1')
            foreach ($r in $fileIndexOut) {
                $streamWriter.WriteLine("$($r.Path)`t$($r.Bytes)`t$($r.MTimeTicks)`t$($r.LastWrite)`t$($r.PartialHash)`t$($r.FullHash)")
            }
        } finally { $streamWriter.Dispose() }
        Publish-CacheFile -Tmp $fileTmp -Dest $fileCachePath
    } catch {}
}

# Called after each hash computed. Only the file cache changes during the
# hash pass (the folder snapshot is final once the walk ends), so that's all
# a checkpoint rewrites.
$checkpointTimer = [System.Diagnostics.Stopwatch]::StartNew()
function Save-HashCheckpoint {
    if ($checkpointTimer.ElapsedMilliseconds -lt ($CheckpointSeconds * 1000)) { return }
    $checkpointTimer.Restart()
    Write-FileCache
}

$start = Get-Date
$grandTotal = Scan-Dir -Path $DriveRoot -Depth 0 -ParentPath $null
$walkElapsed = (Get-Date) - $start

# Persist the walk's results BEFORE the hash pass, not after. Hashing can run
# far longer than the walk itself (a real ~900GB drive: a walk of a few
# minutes, then well over 20 minutes hashing) and used to be the only thing standing between the
# finished walk and the first cache write - so killing or crashing a long
# first run threw away all of it.
Write-FolderCache
Write-FileCache

# ---- staged duplicate hashing (see .NOTES in the top comment block) ----
# Stage 1 (free): group already-known sizes; any group of 2+ is a candidate.
# Stage 2 (cheap): first+last 64KB pre-filter within a size group.
# Stage 3 (definitive): full SHA-256, only for partial-hash survivors.
# Every stage skips a row that already carries a cached hash from an
# unchanged file, which is what keeps "always hash" cheap after run 1.
$scanPhase = 'hashing'
Write-ProgressSnapshot -Force $true
$hashStart = Get-Date

$bySize = @{}
foreach ($r in $fileIndexOut) {
    if (-not $bySize.ContainsKey($r.Bytes)) { $bySize[$r.Bytes] = New-Object System.Collections.Generic.List[object] }
    $bySize[$r.Bytes].Add($r)
}

foreach ($kv in $bySize.GetEnumerator()) {
    if ($kv.Value.Count -lt 2) { continue }

    foreach ($r in $kv.Value) {
        if (-not $r.PartialHash) {
            $r.PartialHash = Get-PartialHash -LongPath (ConvertTo-LongPath $r.Path) -FileSize $r.Bytes
            Write-ProgressSnapshot
            Save-HashCheckpoint
        }
    }

    $byPartial = @{}
    foreach ($r in $kv.Value) {
        if (-not $r.PartialHash) { continue }
        if (-not $byPartial.ContainsKey($r.PartialHash)) { $byPartial[$r.PartialHash] = New-Object System.Collections.Generic.List[object] }
        $byPartial[$r.PartialHash].Add($r)
    }
    foreach ($pkv in $byPartial.GetEnumerator()) {
        if ($pkv.Value.Count -lt 2) { continue }
        foreach ($r in $pkv.Value) {
            if (-not $r.FullHash) {
                try {
                    $h = Get-FileHash -LiteralPath (ConvertTo-LongPath $r.Path) -Algorithm SHA256 -ErrorAction Stop
                    $r.FullHash = $h.Hash.ToLower()
                    $script:cacheStats.FilesHashed++
                } catch {}
                Write-ProgressSnapshot
                Save-HashCheckpoint
            }
        }
    }
}
$hashElapsed = (Get-Date) - $hashStart

# Final write picks up whatever hashes landed since the last checkpoint.
Write-FileCache

$elapsed = (Get-Date) - $start

# All files that currently carry a confirmed full hash (whether hashed this
# run or reused unchanged from cache) - not just ones hashed THIS run, so
# duplicates found on a prior run don't disappear from the report on a
# cache-hit run where nothing changed. Grouping by FullHash (client-side, in
# the dashboard) turns this into duplicate clusters, the same pattern the
# existing name+size detector already uses across drives.
$hashedFiles = foreach ($r in $fileIndexOut) {
    if ($r.FullHash) { [pscustomobject]@{Path=$r.Path; Bytes=$r.Bytes; LastWrite=$r.LastWrite; FullHash=$r.FullHash} }
}

$result = [pscustomobject]@{
    DriveRoot     = $DriveRoot
    ScannedAt     = (Get-Date).ToString('o')
    ElapsedSec    = [math]::Round($elapsed.TotalSeconds, 1)
    WalkElapsedSec = [math]::Round($walkElapsed.TotalSeconds, 1)
    HashElapsedSec = [math]::Round($hashElapsed.TotalSeconds, 1)
    TotalBytes    = $grandTotal
    Directories   = $dirReport
    TopExtensions = ($extTotals.GetEnumerator() | ForEach-Object { [pscustomobject]@{Ext=$_.Key; Count=$_.Value.Count; Bytes=$_.Value.Bytes} } | Sort-Object Bytes -Descending | Select-Object -First 80)
    TopFiles      = ($topFiles | Sort-Object Bytes -Descending)
    HashedFiles   = @($hashedFiles)
    SkippedCount  = $skipped.Count
    SkippedSample = ($skipped | Select-Object -First 30)
    CacheStats    = [pscustomobject]$cacheStats
}

$json = $result | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false)))
$scanPhase = 'scanning'
Write-ProgressSnapshot -Force $true
Write-Output "DONE $DriveRoot elapsed=$($elapsed.TotalSeconds)s (walk=$($walkElapsed.TotalSeconds)s hash=$($hashElapsed.TotalSeconds)s) total=$grandTotal skipped=$($skipped.Count) dirsReused=$($cacheStats.DirsReused)/$($cacheStats.DirsTotal) filesHashed=$($cacheStats.FilesHashed)"
