# =====================================================================
# 01-build-tests.ps1
#
# Reads each of the 88 source IELTS HTML files and writes a transformed
# copy to ../public/tests/<id>.html with:
#   1. audio.mp3  → Supabase Storage URL
#   2. window.App = App  exposed before the closing IIFE
#   3. <script> block injected before </body> that loads the Supabase
#      client + test-bridge so progress / score / notes sync to the cloud
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\scripts\01-build-tests.ps1
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source       = 'D:\共享文件夹\桌面\雅思英语听力\网页应用版',
    [string]$AudioSource  = 'D:\共享文件夹\桌面\IELTS Listening',
    [string]$OutDir       = '',
    [string]$SupabaseUrl  = 'https://qyccvyyigtjhzunumbqf.supabase.co'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding        = [Text.UTF8Encoding]::new($false)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $scriptDir) 'tests' }

# Canonical id->title map from the audio source folder (IELTS Listening).
# Used to recover the correct id when the html source has typos in its
# leading number (e.g. two "11. ..." html files exist).
$idByTitle = @{}
if (Test-Path $AudioSource) {
    Get-ChildItem $AudioSource -Directory | Where-Object { $_.Name -match '^P[1-4]$' } | ForEach-Object {
        Get-ChildItem $_.FullName -Directory | ForEach-Object {
            Get-ChildItem $_.FullName -Directory | ForEach-Object {
                if ($_.Name -match '^(\d+)\.\s*(.+)$') {
                    $key = ($Matches[2]).Trim().ToLowerInvariant()
                    $idByTitle[$key] = [int]$Matches[1]
                }
            }
        }
    }
}

if (-not (Test-Path $Source)) { throw "Source folder not found: $Source" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$audioBase = "$SupabaseUrl/storage/v1/object/public/audio"
$count = 0
$errors = @()

# Walk: <Source>/P[1-4](高频|非高频)/<id>. <title>.html
$freqDirs = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4](高频|非高频)$' }
$htmlFiles = $freqDirs | ForEach-Object { Get-ChildItem $_.FullName -Filter '*.html' -File }

foreach ($html in $htmlFiles) {
    if ($html.BaseName -notmatch '^(\d+)\.\s*(.*)$') {
        Write-Warning "Skipping (no leading number): $($html.Name)"; continue
    }
    $rawId  = [int]$Matches[1]
    $title  = ($Matches[2]).Trim().ToLowerInvariant()
    # Prefer canonical id from audio source map; fall back to filename number.
    $id = if ($idByTitle.ContainsKey($title)) { $idByTitle[$title] } else { $rawId }

    try {
        $content = [IO.File]::ReadAllText($html.FullName, [Text.UTF8Encoding]::new($false))
    } catch {
        $errors += "Read failed: $($html.FullName) - $_"; continue
    }

    # 1. Replace audio.mp3 → Supabase URL
    $audioUrl = "$audioBase/$id.mp3"
    $content = $content -replace 'src="audio\.mp3"', "src=`"$audioUrl`""

    # 2. Expose App on window before the closing IIFE (`}());`)
    if ($content -notmatch 'window\.App\s*=\s*App') {
        $content = $content -replace '(\r?\n)\}\(\)\);', "`$1window.App = App;`$1}());"
    }

    # 3. Inject Supabase + bridge scripts before </body>
    $injection = @"
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="/lib/config.js"></script>
<script src="/lib/supabase.js"></script>
<script>window.TEST_ID = $id;</script>
<script src="/lib/test-bridge.js"></script>
"@

    if ($content -notmatch '/lib/test-bridge\.js') {
        $content = $content -replace '</body>', "$injection`r`n</body>"
    }

    $outFile = Join-Path $OutDir "$id.html"
    [IO.File]::WriteAllText($outFile, $content, [Text.UTF8Encoding]::new($false))
    $count++
}

Write-Host "Built $count test pages → $OutDir" -ForegroundColor Green
if ($errors.Count) {
    Write-Host "$($errors.Count) error(s):" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Host "  $_" }
    exit 1
}
