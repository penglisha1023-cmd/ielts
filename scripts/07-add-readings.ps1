# =====================================================================
# 07-add-readings.ps1
#
# APPEND-ONLY reading adder. Unlike 06-build-readings.ps1 (which regenerates
# the whole catalog from the full source tree), this takes a SMALL staging
# tree containing only NEW articles and:
#   - injects the Morandi theme + /lib/reading-bridge.js + window.READING_ID
#     (identical to 06-build) and writes ../readings/<id>.html
#   - APPENDS the new rows to lib/reading-catalog.js *without* touching the
#     existing entries (so a stale/partial local source can't wipe the live
#     catalog).
#
# Use when importing a few new readings (e.g. produced by 06b) on a machine
# whose full reading source tree is out of date.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\07-add-readings.ps1 -SourceTree <stagingTree>
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceTree,
    [string]$OutDir      = '',
    [string]$CatalogPath = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $OutDir)      { $OutDir      = Join-Path $projectRoot 'readings' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $projectRoot 'lib\reading-catalog.js' }

if (-not (Test-Path $SourceTree)) { throw "Staging tree not found: $SourceTree" }
if (-not (Test-Path $OutDir))     { throw "readings/ not found: $OutDir" }
if (-not (Test-Path $CatalogPath)){ throw "catalog not found: $CatalogPath" }

# existing catalog ids (never overwrite one)
$catalog = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$existingIds = @{}
foreach ($mm in [regex]::Matches($catalog, 'id:\s*(\d+)')) { $existingIds[[int]$mm.Groups[1].Value] = $true }

$themeCss = @'
<style id="morandi-reading-theme">
  body { background:#ebe4d9 !important; }
  #left, #right, .pane { background:#f7f1e7 !important; }
  #right { background:#ebe4d9 !important; }
  #divider { background:#d7cdbe !important; }
  h2, h3, h4, .group h4 { color:#3d362e !important; }
  h3 { color:#748a7a !important; }
  .group { background:#f7f1e7 !important; border-color:#d7cdbe !important; }
  .group ol li, .group p { color:#3d362e !important; }
  .headings { background:#ebe4d9 !important; }
  button { background:#f7f1e7 !important; border-color:#d7cdbe !important; color:#3d362e !important; }
  button:hover { background:#ebe4d9 !important; }
  .btn-primary { background:#8fa394 !important; color:#fff !important; border-color:#8fa394 !important; }
  .btn-primary:hover { background:#748a7a !important; }
  .btn-danger { background:#b58575 !important; color:#fff !important; border-color:#b58575 !important; }
  .hl { background:#d8c1ac !important; }
  .note { background:#c8d2dc !important; }
  #timer { background:#f7f1e7 !important; border-color:#d7cdbe !important; color:#748a7a !important; }
  th { background:#ebe4d9 !important; color:#3d362e !important; }
  th, td { border-color:#d7cdbe !important; }
</style>
'@

$freqDirs = Get-ChildItem $SourceTree -Directory | Where-Object { $_.Name -match '^P[1-3](高频|次高频)$' }
if (-not $freqDirs) { throw "No P{1-3}{高频|次高频} folders under $SourceTree" }

$new = @()
$errors = @()
foreach ($dir in $freqDirs) {
    if ($dir.Name -notmatch '^P([1-3])(高频|次高频)$') { continue }
    $section = "P$($Matches[1])"
    $freq    = if ($Matches[2] -eq '高频') { 'high' } else { 'sub' }
    foreach ($html in Get-ChildItem $dir.FullName -Filter '*.html' -File) {
        if ($html.BaseName -notmatch '^(\d+)\.\s*(?:P[1-3]\s*-\s*)?(.+)$') {
            $errors += "Skipping (no leading number): $($html.FullName)"; continue
        }
        $id    = [int]$Matches[1]
        $title = ($Matches[2]).Trim()
        if ($existingIds.ContainsKey($id)) {
            $errors += "id $id already in catalog — skipped (append-only won't overwrite)"; continue
        }

        $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))
        if ($content -notmatch 'id="morandi-reading-theme"') {
            $content = $content -replace '(</head>)', "$themeCss`r`n`$1"
        }
        $injection = @"
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="/lib/config.js"></script>
<script src="/lib/supabase.js"></script>
<script>window.READING_ID = $id;</script>
<script src="/lib/reading-bridge.js"></script>
"@
        if ($content -notmatch '/lib/reading-bridge\.js') {
            $content = $content -replace '</body>', "$injection`r`n</body>"
        }
        [IO.File]::WriteAllText((Join-Path $OutDir "$id.html"), $content, [Text.UTF8Encoding]::new($false))
        $new += [pscustomobject]@{ id = $id; section = $section; frequency = $freq; title = $title }
    }
}

if (-not $new.Count) { throw "No new readings to add." }

# ---- append rows to catalog (leading-comma, before closing '];') ------
$rows = $new | Sort-Object id | ForEach-Object {
    $titleEscaped = ($_.title -replace "\\","\\\\") -replace "'","\'"
    $idStr   = ('{0,4}' -f $_.id)
    $secStr  = "'$($_.section)'"
    $freqStr = ("'$($_.frequency)'").PadRight(7)
    "  ,{ id: $idStr, section: $secStr, frequency: $freqStr, title: '$titleEscaped' }"
}
$block = ($rows -join "`r`n")
# insert before the final '];'
$idx = $catalog.LastIndexOf('];')
if ($idx -lt 0) { throw "closing '];' not found in $CatalogPath" }
$catalog = $catalog.Substring(0, $idx) + $block + "`r`n" + $catalog.Substring($idx)
[IO.File]::WriteAllText($CatalogPath, $catalog, [Text.UTF8Encoding]::new($false))

Write-Host "Added $($new.Count) reading(s):" -ForegroundColor Green
$new | Sort-Object id | ForEach-Object { Write-Host ("  {0}  {1} {2}  {3}" -f $_.id, $_.section, $_.frequency, $_.title) }
if ($errors.Count) { Write-Host "Notes:" -ForegroundColor Yellow; $errors | ForEach-Object { Write-Host "  $_" } }
