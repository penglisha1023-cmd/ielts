# =====================================================================
# 15-add-standard-extras.ps1
#
# Second standard-listening batch, delivered as per-test .zip files under
# "新题\IELTS Listening  3" (canonical numbering 1..112; internal 1..88 ==
# site ids 1..88). Adds the tests whose internal id is NOT yet on the site,
# using an EXPLICIT internal->app_id map so the already-deployed 179..195
# never shift:
#
#   internal 107 -> app 190  (fills the gap left last batch: it now ships audio)
#   internal 93,94,97,98,99,102,105,108,109,111,112 -> app 196..206
#
# Each test zip contains "<n>. <title>/{<n>. <title>.html, audio.mp3, ...}".
# Pages get the same transforms as the VIP/standard builder (audio/image ->
# Supabase, promo-header hidden via #vip-header-tidy, /lib/vip-test-bridge.js).
# Audio/images are uploaded to the Supabase `audio` bucket, and a
# STANDARD-BATCH2 block is written between its markers in lib/catalog.js.
#
# Requires SUPABASE_SECRET_KEY in .env.local (gitignored). Re-run is safe.
#   powershell -ExecutionPolicy Bypass -File .\scripts\15-add-standard-extras.ps1
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source      = '',
    [string]$OutDir      = '',
    [string]$CatalogPath = '',
    [string]$EnvFile     = '',
    [string]$SupabaseUrl = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$Bucket      = 'audio'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $Source)      { $Source      = Join-Path $projectRoot '新题\IELTS Listening  3' }
if (-not $OutDir)      { $OutDir      = Join-Path $projectRoot 'tests' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $projectRoot 'lib\catalog.js' }
if (-not $EnvFile)     { $EnvFile     = Join-Path $projectRoot '.env.local' }

if (-not (Test-Path $Source)) { throw "Source folder not found: $Source" }

# ---- explicit internal -> app_id map (this batch only) ----------------
# Array of pairs (NOT an OrderedDictionary: indexing an OrderedDictionary by an
# integer key returns the element at that POSITION, not the mapped value).
$map = @(
    @{ internal = 107; app = 190 }
    @{ internal = 93;  app = 196 }
    @{ internal = 94;  app = 197 }
    @{ internal = 97;  app = 198 }
    @{ internal = 98;  app = 199 }
    @{ internal = 99;  app = 200 }
    @{ internal = 102; app = 201 }
    @{ internal = 105; app = 202 }
    @{ internal = 108; app = 203 }
    @{ internal = 109; app = 204 }
    @{ internal = 111; app = 205 }
    @{ internal = 112; app = 206 }
)

# ---- secret key ------------------------------------------------------
if (-not (Test-Path $EnvFile)) { throw "Missing $EnvFile" }
$secretKey = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*SUPABASE_SECRET_KEY\s*=\s*(\S+)\s*$') { $secretKey = $Matches[1].Trim('"').Trim("'") }
}
if (-not $secretKey) { throw "SUPABASE_SECRET_KEY not found in $EnvFile" }

$audioBase = "$SupabaseUrl/storage/v1/object/public/audio"
$freqMap   = @{ '高频' = 'high'; '次高频' = 'sub'; '非高频' = 'low' }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("xh_batch2_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

$entries = @()
$errors  = @()

function Send-File([string]$LocalPath, [int]$AppId, [string]$Ext, [string]$ContentType) {
    $url = "$SupabaseUrl/storage/v1/object/$Bucket/$AppId.$Ext"
    $headers = @{ Authorization = "Bearer $script:secretKey"; apikey = $script:secretKey; 'Content-Type' = $ContentType; 'x-upsert' = 'true' }
    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -InFile $LocalPath -TimeoutSec 600 | Out-Null
}

foreach ($pair in $map) {
    $internal = [int]$pair.internal
    $appId    = [int]$pair.app

    # locate the zip anywhere under Source whose name starts "<internal>. "
    $zip = Get-ChildItem $Source -Recurse -File -Filter '*.zip' |
        Where-Object { $_.Name -match ('^' + [regex]::Escape("$internal") + '\.\s') } | Select-Object -First 1
    if (-not $zip) { $errors += "internal $internal -> no zip"; continue }

    # section from the P# ancestor, freq from the tier ancestor
    $rel = $zip.FullName.Substring($Source.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'
    $section = ($parts | Where-Object { $_ -match '^P[1-4]$' } | Select-Object -First 1)
    $tier    = ($parts | Where-Object { $freqMap.ContainsKey($_) } | Select-Object -First 1)
    if (-not $section -or -not $tier) { $errors += "internal $internal -> cannot resolve section/tier from '$rel'"; continue }
    $freq = $freqMap[$tier]

    # extract
    $dest = Join-Path $tmpRoot "$internal"
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
    $artDir = Get-ChildItem $dest -Directory | Select-Object -First 1
    if (-not $artDir) { $artDir = Get-Item $dest }

    $html = Get-ChildItem $artDir.FullName -Recurse -File -Filter '*.html' | Select-Object -First 1
    if (-not $html) { $errors += "internal $internal -> no html in zip"; continue }
    $mp3 = Get-ChildItem $artDir.FullName -Recurse -File -Filter 'audio.mp3' | Select-Object -First 1
    if (-not $mp3) { $errors += "internal $internal -> no audio.mp3 in zip"; continue }

    # title: folder name without "<n>. " and "P# " prefix
    $rawTitle = $artDir.Name -replace '^\s*\d+\.\s*', ''
    $title = $rawTitle -replace '^\s*P[1-4]\s+', ''
    $title = ($title -replace '\s+', ' ').Trim()

    $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))

    # audio -> Supabase
    $audioUrl = "$audioBase/$appId.mp3"
    $content = $content -replace '"audio\.mp3"', "`"$audioUrl`""
    $content = $content -replace "'audio\.mp3'", "'$audioUrl'"

    # map/diagram image -> Supabase (only if present)
    $img = Get-ChildItem $artDir.FullName -Recurse -File | Where-Object { $_.Name -in @('map.png','diagram.png') } | Select-Object -First 1
    if ($img) {
        $content = $content -replace '"image":"(?:map|diagram)\.png"', "`"image`":`"$audioBase/$appId.png`""
    }

    # hide promo header / ad watermark (idempotent)
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

    # inject Supabase + bridge (idempotent)
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

    [IO.File]::WriteAllText((Join-Path $OutDir "$appId.html"), $content, [Text.UTF8Encoding]::new($false))

    # upload media
    Send-File $mp3.FullName $appId 'mp3' 'audio/mpeg'
    if ($img) { Send-File $img.FullName $appId 'png' 'image/png' }

    Write-Host ("built+uploaded app {0} <- internal {1}  {2} {3}  {4}" -f $appId, $internal, $section, $freq, $title) -ForegroundColor Green
    $entries += [pscustomobject]@{ id = $appId; section = $section; frequency = $freq; title = $title }
}

# ---- catalog: STANDARD-BATCH2 block (leading-comma rows) ---------------
$rows = $entries | Sort-Object id | ForEach-Object {
    $titleEscaped = ($_.title -replace '\\', '\\') -replace "'", "\'"
    $idStr   = ('{0,4}' -f $_.id)
    $secStr  = "'$($_.section)'"
    $freqStr = ("'$($_.frequency)'").PadRight(7)
    "  ,{ id: $idStr, section: $secStr, frequency: $freqStr, title: '$titleEscaped' }"
}
$block = $rows -join "`r`n"

$beginMarker = '  // ==== STANDARD-BATCH2 BEGIN (generated by scripts/15-add-standard-extras.ps1 — do not edit by hand) ===='
$endMarker   = '  // ==== STANDARD-BATCH2 END ===='

$catalog = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$pattern = '(?s)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
$replacement = $beginMarker + "`r`n" + $block + "`r`n" + $endMarker
if ([regex]::IsMatch($catalog, $pattern)) {
    $catalog = [regex]::Replace($catalog, $pattern, { param($m) $replacement })
} else {
    throw "STANDARD-BATCH2 markers not found in $CatalogPath — add the BEGIN/END marker block before the closing '];'."
}
[IO.File]::WriteAllText($CatalogPath, $catalog, [Text.UTF8Encoding]::new($false))

Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. $($entries.Count) test(s) built + uploaded + catalogued." -ForegroundColor Cyan
if ($errors.Count) {
    Write-Host "Issues:" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Host "  $_" }
    exit 1
}
