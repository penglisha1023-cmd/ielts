# =====================================================================
# 13-build-new-standard.ps1
#
# Builds the NEW tests inside "IELTS Listening 虾滑" (the standard, non-VIP
# set) that are not yet on the site. The standard source is numbered
# internally 1..118; internal ids 1..88 duplicate the original hand-kept
# catalog (ids 1..88), so only folders whose internal id is >= MinInternalId
# (default 89) are treated as new.
#
# The new folders are sorted by internal id and assigned contiguous
# app ids starting at StartAppId (default 179), i.e. app ids 179.. .
# Each page uses the same self-contained "虾滑" template as the VIP set,
# so the same transforms apply (audio/image rewrite, header tidy,
# /lib/vip-test-bridge.js injection).
#
# Writes tests/<appId>.html and refreshes the NEW-STANDARD block in
# lib/catalog.js (between its BEGIN/END markers). Re-run is safe.
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\13-build-new-standard.ps1
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source        = '',
    [string]$OutDir        = '',
    [string]$CatalogPath   = '',
    [int]   $MinInternalId = 89,
    [int]   $StartAppId    = 179,
    [string]$SupabaseUrl   = 'https://qyccvyyigtjhzunumbqf.supabase.co'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $Source)      { $Source      = Join-Path $projectRoot '新题\IELTS Listening 虾滑' }
if (-not $OutDir)      { $OutDir      = Join-Path $projectRoot 'tests' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $projectRoot 'lib\catalog.js' }

if (-not (Test-Path $Source)) { throw "Source folder not found: $Source" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$audioBase = "$SupabaseUrl/storage/v1/object/public/audio"
$freqMap   = @{ '高频' = 'high'; '次高频' = 'sub'; '非高频' = 'low' }

# ---- 1. Collect the new folders (internal id >= MinInternalId) ----------
$collected = @()
$errors    = @()
$sections = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4]$' } | Sort-Object Name
foreach ($sec in $sections) {
    $tierDirs = Get-ChildItem $sec.FullName -Directory | Where-Object { $freqMap.ContainsKey($_.Name) }
    foreach ($tierDir in $tierDirs) {
        $freq = $freqMap[$tierDir.Name]
        foreach ($artDir in Get-ChildItem $tierDir.FullName -Directory) {
            if ($artDir.Name -notmatch '^(\d+)\.\s*(.+)$') {
                $errors += "Skipping (no leading number): $($artDir.FullName)"; continue
            }
            $internalId = [int]$Matches[1]
            if ($internalId -lt $MinInternalId) { continue }   # old test, already on site
            $rawTitle = $Matches[2]
            $collected += [pscustomobject]@{
                internalId = $internalId
                section    = $sec.Name
                freq       = $freq
                rawTitle   = $rawTitle
                dir        = $artDir.FullName
            }
        }
    }
}

# ---- 2. Sort by internal id, assign contiguous app ids ------------------
$collected = $collected | Sort-Object internalId
$entries = @()
$built   = 0
$appId   = $StartAppId
foreach ($item in $collected) {
    $title = $item.rawTitle -replace '^\s*P[1-4]\s+', ''
    $title = $title -replace '\s*\(VIP\)\s*', ' '
    $title = ($title -replace '\s+', ' ').Trim()

    $html = Get-ChildItem $item.dir -Filter '*.html' -File | Select-Object -First 1
    if (-not $html) { $errors += "No .html in $($item.dir)"; continue }

    # Source without an audio.mp3 is incomplete: reserve (skip) this app id so
    # the remaining tests keep their numbers, and leave a catalog gap.
    if (-not (Test-Path (Join-Path $item.dir 'audio.mp3'))) {
        $errors += "No audio.mp3 -> reserving id $appId (skipped): $($item.dir)"
        $appId++
        continue
    }

    try {
        $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))
    } catch {
        $errors += "Read failed: $($html.FullName) - $_"; continue
    }

    # ---- audio -> Supabase (JSON value + JS fallback) ----
    $audioUrl = "$audioBase/$appId.mp3"
    $content = $content -replace '"audio\.mp3"', "`"$audioUrl`""
    $content = $content -replace "'audio\.mp3'", "'$audioUrl'"

    # ---- map/diagram image -> Supabase (only when source ships one) ----
    $imgFile = Get-ChildItem $item.dir -File |
        Where-Object { $_.Name -in @('map.png', 'diagram.png') } | Select-Object -First 1
    if ($imgFile) {
        $imageUrl = "$audioBase/$appId.png"
        $content = $content -replace '"image":"(?:map|diagram)\.png"', "`"image`":`"$imageUrl`""
    }

    # ---- hide promo header (idempotent) ----
    $headTidy = @"
<style id="vip-header-tidy">
  .header h1 { display: none !important; }
  .header .meta, #ownerMeta { display: none !important; }
  .header { min-height: 0 !important; }
</style>
"@
    if ($content -notmatch 'id="vip-header-tidy"') {
        $content = $content -replace '(</head>)', "$headTidy`r`n`$1"
    }

    # ---- inject Supabase + bridge before </body> (idempotent) ----
    $injection = @"
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="/lib/config.js"></script>
<script src="/lib/supabase.js"></script>
<script>window.TEST_ID = $appId;</script>
<script src="/lib/vip-test-bridge.js"></script>
"@
    if ($content -notmatch '/lib/vip-test-bridge\.js') {
        $content = $content -replace '</body>', "$injection`r`n</body>"
    }

    $outFile = Join-Path $OutDir "$appId.html"
    [IO.File]::WriteAllText($outFile, $content, [Text.UTF8Encoding]::new($false))
    $built++

    $entries += [pscustomobject]@{ id = $appId; section = $item.section; frequency = $item.freq; title = $title; internalId = $item.internalId }
    $appId++
}

# ---- 3. Regenerate the NEW-STANDARD block inside lib/catalog.js ----------
# Rows carry a LEADING comma so the block self-separates from the entry
# that precedes it (the last VIP entry has no trailing comma).
$rows = $entries | ForEach-Object {
    $titleEscaped = ($_.title -replace '\\', '\\') -replace "'", "\'"
    $idStr   = ('{0,4}' -f $_.id)
    $secStr  = "'$($_.section)'"
    $freqStr = ("'$($_.frequency)'").PadRight(7)
    "  ,{ id: $idStr, section: $secStr, frequency: $freqStr, title: '$titleEscaped' }"
}
$block = $rows -join "`r`n"

$beginMarker = '  // ==== NEW-STANDARD BEGIN (generated by scripts/13-build-new-standard.ps1 — do not edit by hand) ===='
$endMarker   = '  // ==== NEW-STANDARD END ===='

$catalog = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$pattern = '(?s)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
$replacement = $beginMarker + "`r`n" + $block + "`r`n" + $endMarker

if ([regex]::IsMatch($catalog, $pattern)) {
    $catalog = [regex]::Replace($catalog, $pattern, { param($m) $replacement })
} else {
    throw "NEW-STANDARD markers not found in $CatalogPath — add the BEGIN/END marker block before the closing '];'."
}
[IO.File]::WriteAllText($CatalogPath, $catalog, [Text.UTF8Encoding]::new($false))

Write-Host "Built $built new standard test pages -> $OutDir" -ForegroundColor Green
if ($entries.Count) {
    $ids = ($entries | Sort-Object id | ForEach-Object { $_.id })
    Write-Host "Catalog NEW-STANDARD ids $($ids[0])..$($ids[-1]) -> $CatalogPath" -ForegroundColor Green
    $entries | Sort-Object id | ForEach-Object { Write-Host ("  {0} <- internal {1}  {2} {3}  {4}" -f $_.id, $_.internalId, $_.section, $_.frequency, $_.title) }
}
if ($errors.Count) {
    Write-Host "$($errors.Count) issue(s):" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Host "  $_" }
    exit 1
}
