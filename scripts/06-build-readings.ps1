# =====================================================================
# 06-build-readings.ps1
#
# 1. Walks <Source>\阅读\P{1,2,3}{高频,次高频}\<id>. P{n} - <title>.html and:
#      - injects window.READING_ID
#      - injects /lib/reading-bridge.js + supabase client
#      - injects the shared Morandi theme override
#    Writes to ../readings/<id>.html.
#
# 2. Regenerates ../lib/reading-catalog.js based on the source folders.
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\scripts\06-build-readings.ps1
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source = 'D:\共享文件夹\桌面\雅思英语听力\网页应用版\阅读',
    [string]$OutDir = '',
    [string]$CatalogPath = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $OutDir)      { $OutDir      = Join-Path $projectRoot 'readings' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $projectRoot 'lib\reading-catalog.js' }

if (-not (Test-Path $Source)) { throw "Source folder not found: $Source" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Walk: <Source>\P{1,2,3}{高频,次高频}\<id>. P{n} - <title>.html
$freqDirs = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-3](高频|次高频)$' }
if (-not $freqDirs) { throw "No P{1-3}{高频|次高频} folders found under $Source" }

$entries = @()
$errors  = @()
$built   = 0

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

        try {
            $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))
        } catch {
            $errors += "Read failed: $($html.FullName) - $_"; continue
        }

        # ---- 1. Inject Morandi theme override into <head> (idempotent) ----
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
        if ($content -notmatch 'id="morandi-reading-theme"') {
            $content = $content -replace '(</head>)', "$themeCss`r`n`$1"
        }

        # ---- 2. Inject Supabase + bridge before </body> (idempotent) ----
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

        $outFile = Join-Path $OutDir "$id.html"
        [IO.File]::WriteAllText($outFile, $content, [Text.UTF8Encoding]::new($false))
        $built++

        $entries += [pscustomobject]@{
            id        = $id
            section   = $section
            frequency = $freq
            title     = $title
        }
    }
}

# ---- 3. Regenerate lib/reading-catalog.js ----
$sorted = $entries | Sort-Object id
$rows = $sorted | ForEach-Object {
    $titleEscaped = ($_.title -replace "\\","\\\\") -replace "'","\'"
    $idStr   = ('{0,4}' -f $_.id)
    $secStr  = "'$($_.section)'"
    $freqStr = "'$($_.frequency)'"
    $padFreq = $freqStr.PadRight(7)
    "  { id: $idStr, section: $secStr, frequency: $padFreq, title: '$titleEscaped' }"
}
$catalog = @"
// ===================================================================
// Static catalog of IELTS reading articles (P1/P2/P3 × 高频/次高频).
// id = leading number from the source filename (PDF list ID).
// frequency: 'high' = 高频, 'sub' = 次高频
// Generated by scripts/06-build-readings.ps1.
// ===================================================================
window.READING_CATALOG = [
$($rows -join ",`r`n")
];
"@

$catalogDir = Split-Path -Parent $CatalogPath
if (-not (Test-Path $catalogDir)) { New-Item -ItemType Directory -Path $catalogDir | Out-Null }
[IO.File]::WriteAllText($CatalogPath, $catalog, [Text.UTF8Encoding]::new($false))

Write-Host "Built $built reading pages → $OutDir" -ForegroundColor Green
Write-Host "Wrote catalog ($($sorted.Count) entries) → $CatalogPath" -ForegroundColor Green
if ($errors.Count) {
    Write-Host "$($errors.Count) issue(s):" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Host "  $_" }
}
