# =====================================================================
# 06a-organize-reading-source.ps1
#
# One-time migration: takes the raw HTML files from
#   <ReadingRoot>\网页版 -高频次高频\P{1,2,3}\<title>.html
# and reorganizes them into the canonical source structure
#   <ReadingRoot>\P{1,2,3}{高频|次高频}\<id>. P{n} - <title>.html
#
# Frequency is inferred by matching the HTML title against the PDFs in
#   <ReadingRoot>\3月高频次高频篇章\P{n} {高频|次高频}\*.pdf
# Unmatched files default to 次高频 (per user direction).
#
# ID = the leading number from the matched PDF when found; otherwise a
# fresh ID is assigned in the 900-999 range (to keep them visually
# distinct from the canonical PDF IDs and away from listening 1-88).
#
# Idempotent: if a target file already exists it is skipped.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\scripts\06a-organize-reading-source.ps1
# Optional: -DryRun to preview without moving anything.
# =====================================================================

[CmdletBinding()]
param(
    [string]$ReadingRoot = 'D:\共享文件夹\桌面\雅思英语听力\网页应用版\阅读',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$webSrc = Join-Path $ReadingRoot '网页版 -高频次高频'
$pdfSrc = Join-Path $ReadingRoot '3月高频次高频篇章'

if (-not (Test-Path $webSrc)) { throw "Web source folder not found: $webSrc" }
if (-not (Test-Path $pdfSrc)) { throw "PDF source folder not found: $pdfSrc" }

function Normalize([string]$s) {
    $s = $s.ToLowerInvariant()
    # Normalize curly quotes / dashes
    $s = $s -replace "[‘’`']", "'"
    $s = $s -replace '[“”"]', '"'
    $s = $s -replace '[–—−]', '-'
    # Drop Chinese / CJK characters first (they pollute parens / suffixes)
    $s = [regex]::Replace($s, '[　-鿿＀-￯]+', ' ')
    # Drop bracketed/parenthesised qualifiers e.g. "(仅原文无题)" or "(1115纸笔)"
    $s = [regex]::Replace($s, '[\(（][^\)）]*[\)）]', ' ')
    $s = [regex]::Replace($s, '[\[【][^\]】]*[\]】]', ' ')
    # Now strip leading "<num>. P[1-4] - " or just "<num>. "
    $s = [regex]::Replace($s, '^\s*\d+\.\s*p[1-4]\s*[-–]\s*', '')
    $s = [regex]::Replace($s, '^\s*\d+\.\s*',                '')
    $s = [regex]::Replace($s, '^p[1-4]\s*[-–]\s*',           '')
    # Collapse to canonical: keep [a-z0-9 ' -]
    $s = [regex]::Replace($s, "[^a-z0-9' -]+", ' ')
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    return $s
}

# ---- Build classification map from PDFs ----
$pdfMap = @{}
$pdfDirs = Get-ChildItem $pdfSrc -Directory | Where-Object { $_.Name -match '^P[1-3]\s+(高频|次高频)$' }
foreach ($d in $pdfDirs) {
    if ($d.Name -notmatch '^P([1-3])\s+(高频|次高频)$') { continue }
    $section = "P$($Matches[1])"
    $freq    = if ($Matches[2] -eq '高频') { 'high' } else { 'sub' }
    Get-ChildItem $d.FullName -Filter '*.pdf' -File | ForEach-Object {
        if ($_.BaseName -notmatch '^(\d+)\.') { return }
        $pdfId  = [int]$Matches[1]
        $key    = Normalize $_.BaseName
        if ($key -and -not $pdfMap.ContainsKey($key)) {
            $pdfMap[$key] = @{ id = $pdfId; section = $section; freq = $freq; raw = $_.BaseName }
        }
    }
}

Write-Host "Indexed $($pdfMap.Count) PDFs into 高频/次高频 map" -ForegroundColor Cyan

# ---- Also index the 非高频次高频 folder for ID recovery (frequency forced to 次高频) ----
$nonHighDir = Join-Path $ReadingRoot '3月非高频次高频篇章'
$fallbackPdfMap = @{}
if (Test-Path $nonHighDir) {
    Get-ChildItem $nonHighDir -Filter '*.pdf' -File | ForEach-Object {
        if ($_.BaseName -notmatch '^(\d+)\.\s*P([1-3])') { return }
        $pdfId   = [int]$Matches[1]
        $section = "P$($Matches[2])"
        $key     = Normalize $_.BaseName
        if ($key -and -not $fallbackPdfMap.ContainsKey($key)) {
            $fallbackPdfMap[$key] = @{ id = $pdfId; section = $section; freq = 'sub'; raw = $_.BaseName }
        }
    }
    Write-Host "Indexed $($fallbackPdfMap.Count) fallback PDFs from 非高频次高频篇章" -ForegroundColor Cyan
}

# ---- Track existing assigned IDs so we don't reuse them for fallbacks ----
$usedIds = New-Object 'System.Collections.Generic.HashSet[int]'
$pdfMap.Values         | ForEach-Object { [void]$usedIds.Add($_.id) }
$fallbackPdfMap.Values | ForEach-Object { [void]$usedIds.Add($_.id) }
$nextFallbackId = 900

# ---- Walk web HTML sources ----
$webDirs = Get-ChildItem $webSrc -Directory | Where-Object { $_.Name -match '^P[1-3]$' }
$moved      = 0
$skippedSame = 0
$unmatched   = @()
$mismatch    = @()

foreach ($wd in $webDirs) {
    $webSection = $wd.Name  # P1 / P2 / P3
    foreach ($html in Get-ChildItem $wd.FullName -Filter '*.html' -File) {
        $titleRaw = $html.BaseName
        $key      = Normalize $titleRaw

        # Exact match against primary map, then fuzzy (prefix-either-way).
        function FuzzyLookup($k, $map) {
            if ($map.ContainsKey($k)) { return $map[$k] }
            foreach ($entry in $map.GetEnumerator()) {
                # Either direction can be a prefix (handles "Wood" PDF vs longer HTML,
                # and "Tasmania's Museum… MONA" PDF vs shorter HTML).
                if ($k.StartsWith($entry.Key + ' ') -or $entry.Key.StartsWith($k + ' ')) {
                    return $entry.Value
                }
            }
            return $null
        }

        $hit = FuzzyLookup $key $pdfMap
        if ($hit) {
            $section = $hit.section
            $freq    = $hit.freq
            $id      = $hit.id
            if ($section -ne $webSection) {
                $mismatch += "Section mismatch: web='$webSection' pdf='$section' title='$titleRaw'"
                # Trust the PDF folder for classification (user said names should correspond).
            }
        } else {
            $fallbackHit = FuzzyLookup $key $fallbackPdfMap
            if ($fallbackHit) {
                $section = $fallbackHit.section
                $freq    = 'sub'
                $id      = $fallbackHit.id
                $unmatched += "Recovered from 非高频次高频 (→ $section 次高频, id=$id): $titleRaw"
            } else {
                $section = $webSection
                $freq    = 'sub'   # default to 次高频 per user
                while ($usedIds.Contains($nextFallbackId)) { $nextFallbackId++ }
                $id = $nextFallbackId
                [void]$usedIds.Add($id)
                $nextFallbackId++
                $unmatched += "Truly unmatched (→ $section 次高频, id=$id, fallback): $titleRaw"
            }
        }

        $freqFolder = if ($freq -eq 'high') { '高频' } else { '次高频' }
        $destDir    = Join-Path $ReadingRoot "$section$freqFolder"
        if (-not (Test-Path $destDir)) {
            if ($DryRun) { Write-Host "[dryrun] mkdir $destDir" -ForegroundColor DarkGray }
            else { New-Item -ItemType Directory -Path $destDir | Out-Null }
        }

        # Clean up the title for the new filename: drop illegal chars
        $safeTitle = $titleRaw -replace '[\\/:*?"<>|]', '_'
        $destName  = "$id. $section - $safeTitle.html"
        $destPath  = Join-Path $destDir $destName

        if (Test-Path $destPath) {
            $skippedSame++
            continue
        }

        if ($DryRun) {
            Write-Host "[dryrun] $($html.FullName)  →  $destPath" -ForegroundColor DarkGray
        } else {
            Move-Item -LiteralPath $html.FullName -Destination $destPath
        }
        $moved++
    }
}

Write-Host ""
Write-Host "Moved      : $moved" -ForegroundColor Green
Write-Host "Already in : $skippedSame  (target existed, skipped)" -ForegroundColor DarkGray
Write-Host "Unmatched  : $($unmatched.Count)  (defaulted to 次高频)" -ForegroundColor Yellow
if ($unmatched) { $unmatched | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
if ($mismatch) {
    Write-Host "Section mismatches (PDF wins):" -ForegroundColor Yellow
    $mismatch | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

# Clean up now-empty web source folders (only if not dry run and no html left)
if (-not $DryRun) {
    foreach ($wd in $webDirs) {
        if (-not (Get-ChildItem $wd.FullName -File)) {
            Remove-Item -LiteralPath $wd.FullName -Recurse -Force
            Write-Host "Removed empty source: $($wd.FullName)" -ForegroundColor DarkGray
        }
    }
    if (Test-Path $webSrc) {
        if (-not (Get-ChildItem $webSrc)) {
            Remove-Item -LiteralPath $webSrc -Recurse -Force
            Write-Host "Removed empty source root: $webSrc" -ForegroundColor DarkGray
        }
    }
}
