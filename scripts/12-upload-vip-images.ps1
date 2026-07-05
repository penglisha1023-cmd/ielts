# =====================================================================
# 12-upload-vip-images.ps1
#
# Uploads the "IELTS Listening 虾滑VIP" map/diagram images (map.png or
# diagram.png sitting next to each test's HTML) to the Supabase Storage
# `audio` bucket, named <app_id>.png where app_id = IdOffset + vip_id
# (default offset 88 -> app ids 89..161), matching 10-build-vip-tests.ps1.
#
# The source pages reference the image as "image":"map.png" (a bare
# relative path that does not exist on the deployed site); 10-build-vip-tests.ps1
# rewrites that to this bucket URL so the P2 map / P3 diagram questions
# actually show a picture.
#
# Requires the project's Supabase **secret** (service_role) key in
# .env.local at repo root:
#     SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxx
# That file is gitignored. NEVER commit the secret key.
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\12-upload-vip-images.ps1
#
# Re-run is safe: it overwrites existing files (upsert).
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source      = '',
    [string]$SupabaseUrl = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$Bucket      = 'audio',
    [int]   $IdOffset    = 88,
    [string]$EnvFile     = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $EnvFile) { $EnvFile = Join-Path $projectRoot '.env.local' }
if (-not $Source)  { $Source  = Join-Path $projectRoot 'IELTS Listening 虾滑VIP' }

# ---- Load secret key from .env.local ---------------------------------
if (-not (Test-Path $EnvFile)) {
    Write-Host "Missing $EnvFile" -ForegroundColor Red
    Write-Host "Create it with the Supabase service_role key (NEVER commit):"
    Write-Host "    SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxxxxxxxxxxxxx"
    exit 1
}
$secretKey = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*SUPABASE_SECRET_KEY\s*=\s*(\S+)\s*$') {
        $secretKey = $Matches[1].Trim('"').Trim("'")
    }
}
if (-not $secretKey) {
    Write-Host "SUPABASE_SECRET_KEY not found in $EnvFile" -ForegroundColor Red
    exit 1
}

# ---- Walk source: <Source>\P[1-4]\{高频|次高频|非高频}\<id>. <title>\{map,diagram}.png ----
$freqNames = @('高频', '次高频', '非高频')
$folders = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4]$' } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { $_.Name -in $freqNames } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory }

$total = 0
$ok    = 0
$fail  = @()

foreach ($f in $folders) {
    if ($f.Name -notmatch '^(\d+)\.\s') { continue }
    $appId = $IdOffset + [int]$Matches[1]

    # find the image next to the HTML (map.png preferred, else diagram.png)
    $img = Get-ChildItem $f.FullName -File | Where-Object { $_.Name -in @('map.png', 'diagram.png') } | Select-Object -First 1
    if (-not $img) { continue }  # this test has no image group; skip silently

    $total++
    $size = $img.Length
    $url  = "$SupabaseUrl/storage/v1/object/$Bucket/$appId.png"
    $headers = @{
        Authorization  = "Bearer $secretKey"
        apikey         = $secretKey
        'Content-Type' = 'image/png'
        'x-upsert'     = 'true'
    }

    Write-Host ("[{0,2}] uploading app_id={1} <- {2} ({3:N0} KB) ..." -f $total, $appId, $img.Name, ($size/1KB)) -NoNewline
    try {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -InFile $img.FullName -TimeoutSec 300 | Out-Null
        Write-Host ' ok' -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ' FAIL' -ForegroundColor Red
        $fail += "[$appId] $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done. $ok / $total images uploaded." -ForegroundColor Cyan
if ($fail.Count) {
    Write-Host "Failures:" -ForegroundColor Yellow
    $fail | ForEach-Object { Write-Host "  $_" }
    exit 1
}
