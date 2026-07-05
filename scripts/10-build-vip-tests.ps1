# =====================================================================
# 10-build-vip-tests.ps1
#
# Builds the "IELTS Listening 虾滑VIP" set (73 newer, self-contained test
# pages) into ../tests/<app_id>.html and refreshes the generated VIP block
# in ../lib/catalog.js.
#
# The VIP source is numbered 1..73 internally, which collides with the
# original 88 tests, so each VIP test is given app_id = IdOffset + vip_id
# (default offset 88 -> app ids 89..161).
#
# Per page it:
#   1. Rewrites the audio reference (JSON "audio":"audio.mp3" + the JS
#      fallback) to the Supabase Storage URL for <app_id>.mp3.
#   2. Injects the Supabase client + /lib/vip-test-bridge.js before </body>
#      (window.App already exists in the VIP template, so it is not touched).
#
# Frequency tiers:  高频 -> high,  次高频 -> sub,  非高频 -> low
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\10-build-vip-tests.ps1
# Re-run is safe (idempotent): pages are overwritten and the catalog VIP
# block is regenerated between its markers.
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source      = '',
    [string]$OutDir      = '',
    [string]$CatalogPath = '',
    [int]   $IdOffset    = 88,
    [string]$SupabaseUrl = 'https://qyccvyyigtjhzunumbqf.supabase.co'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $Source)      { $Source      = Join-Path $projectRoot 'IELTS Listening 虾滑VIP' }
if (-not $OutDir)      { $OutDir      = Join-Path $projectRoot 'tests' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $projectRoot 'lib\catalog.js' }

if (-not (Test-Path $Source)) { throw "Source folder not found: $Source" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$audioBase = "$SupabaseUrl/storage/v1/object/public/audio"
$freqMap   = @{ '高频' = 'high'; '次高频' = 'sub'; '非高频' = 'low' }

$entries = @()
$errors  = @()
$built   = 0
$seen    = @{}

# Walk: <Source>\P[1-4]\{高频|次高频|非高频}\<id>. <title>\<id>. <title>.html
$sections = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4]$' } | Sort-Object Name
foreach ($sec in $sections) {
    $tierDirs = Get-ChildItem $sec.FullName -Directory | Where-Object { $freqMap.ContainsKey($_.Name) }
    foreach ($tierDir in $tierDirs) {
        $freq = $freqMap[$tierDir.Name]
        foreach ($artDir in Get-ChildItem $tierDir.FullName -Directory) {
            if ($artDir.Name -notmatch '^(\d+)\.\s*(.+)$') {
                $errors += "Skipping (no leading number): $($artDir.FullName)"; continue
            }
            $vipId = [int]$Matches[1]
            $rawTitle = $Matches[2]
            $appId = $IdOffset + $vipId

            if ($seen.ContainsKey($appId)) {
                $errors += "Duplicate vip id $vipId (app $appId): $($artDir.FullName)"; continue
            }
            $seen[$appId] = $true

            $html = Get-ChildItem $artDir.FullName -Filter '*.html' -File | Select-Object -First 1
            if (-not $html) { $errors += "No .html in $($artDir.FullName)"; continue }

            # ---- Clean title: drop "P# " section prefix and the "(VIP)" tag ----
            $title = $rawTitle -replace '^\s*P[1-4]\s+', ''
            $title = $title -replace '\s*\(VIP\)\s*', ' '
            $title = ($title -replace '\s+', ' ').Trim()

            try {
                $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))
            } catch {
                $errors += "Read failed: $($html.FullName) - $_"; continue
            }

            # ---- 1. Point audio at Supabase (JSON value + JS fallback) ----
            $audioUrl = "$audioBase/$appId.mp3"
            $content = $content -replace '"audio\.mp3"', "`"$audioUrl`""
            $content = $content -replace "'audio\.mp3'", "'$audioUrl'"

            # ---- 1a. Point map/diagram image at Supabase (uploaded by
            #          12-upload-vip-images.ps1 as <appId>.png). The source
            #          references a bare "image":"map.png" / "diagram.png" that
            #          does not exist on the deployed site. Only rewrite when the
            #          source folder actually ships an image. ----
            $imgFile = Get-ChildItem $artDir.FullName -File |
                Where-Object { $_.Name -in @('map.png', 'diagram.png') } | Select-Object -First 1
            if ($imgFile) {
                $imageUrl = "$audioBase/$appId.png"
                $content = $content -replace '"image":"(?:map|diagram)\.png"', "`"image`":`"$imageUrl`""
            }

            # ---- 1b. Hide the source's promo header (title + owner/ad line);
            #          keep the Text Size / Color button. Idempotent. ----
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

            # ---- 2. Inject Supabase + VIP bridge before </body> (idempotent) ----
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

            $entries += [pscustomobject]@{ id = $appId; section = $sec.Name; frequency = $freq; title = $title }
        }
    }
}

# ---- 3. Regenerate the VIP block inside lib/catalog.js -----------------
$sorted = $entries | Sort-Object id
$rows = $sorted | ForEach-Object {
    $titleEscaped = ($_.title -replace '\\', '\\') -replace "'", "\'"
    $idStr   = ('{0,4}' -f $_.id)
    $secStr  = "'$($_.section)'"
    $freqStr = ("'$($_.frequency)'").PadRight(7)
    "  { id: $idStr, section: $secStr, frequency: $freqStr, title: '$titleEscaped' }"
}
$block = $rows -join ",`r`n"

$beginMarker = '  // ==== VIP-LISTENING BEGIN (generated by scripts/10-build-vip-tests.ps1 — do not edit by hand) ===='
$endMarker   = '  // ==== VIP-LISTENING END ===='

$catalog = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$pattern = '(?s)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
$replacement = $beginMarker + "`r`n" + $block + "`r`n" + $endMarker

if ([regex]::IsMatch($catalog, $pattern)) {
    $catalog = [regex]::Replace($catalog, $pattern, { param($m) $replacement })
} else {
    throw "VIP markers not found in $CatalogPath — add the BEGIN/END marker block before the closing '];'."
}
[IO.File]::WriteAllText($CatalogPath, $catalog, [Text.UTF8Encoding]::new($false))

Write-Host "Built $built VIP test pages -> $OutDir" -ForegroundColor Green
Write-Host "Wrote $($sorted.Count) VIP catalog entries (ids $($sorted[0].id)..$($sorted[-1].id)) -> $CatalogPath" -ForegroundColor Green
if ($errors.Count) {
    Write-Host "$($errors.Count) issue(s):" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Host "  $_" }
    exit 1
}
