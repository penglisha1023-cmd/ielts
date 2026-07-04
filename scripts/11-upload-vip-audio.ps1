# =====================================================================
# 11-upload-vip-audio.ps1
#
# Uploads the 73 "IELTS Listening 虾滑VIP" audio.mp3 files to the Supabase
# Storage `audio` bucket, named <app_id>.mp3 where app_id = IdOffset + vip_id
# (default offset 88 -> app ids 89..161), matching 10-build-vip-tests.ps1.
#
# Requires the project's Supabase **secret** (service_role) key in
# .env.local at repo root:
#
#     SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxx
#
# That file is gitignored. NEVER commit the secret key.
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\11-upload-vip-audio.ps1
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

# ---- Walk source: <Source>\P[1-4]\{高频|次高频|非高频}\<id>. <title>\audio.mp3 ----
$freqNames = @('高频', '次高频', '非高频')
$folders = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4]$' } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { $_.Name -in $freqNames } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory }

$total = 0
$ok    = 0
$fail  = @()
$count = $folders.Count

foreach ($f in $folders) {
    if ($f.Name -notmatch '^(\d+)\.\s') {
        Write-Warning "Skipping (no leading number): $($f.Name)"; continue
    }
    $appId = $IdOffset + [int]$Matches[1]
    $mp3 = Join-Path $f.FullName 'audio.mp3'
    if (-not (Test-Path $mp3)) { $fail += "[$appId] missing audio.mp3 in $($f.Name)"; continue }

    $total++
    $size = (Get-Item $mp3).Length
    $url  = "$SupabaseUrl/storage/v1/object/$Bucket/$appId.mp3"
    $headers = @{
        Authorization  = "Bearer $secretKey"
        apikey         = $secretKey
        'Content-Type' = 'audio/mpeg'
        'x-upsert'     = 'true'
    }

    Write-Host ("[{0,2}/{1}] uploading app_id={2} ({3:N1} MB) ..." -f $total, $count, $appId, ($size/1MB)) -NoNewline
    try {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -InFile $mp3 -TimeoutSec 600 | Out-Null
        Write-Host ' ok' -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ' FAIL' -ForegroundColor Red
        $fail += "[$appId] $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done. $ok / $total uploaded." -ForegroundColor Cyan
if ($fail.Count) {
    Write-Host "Failures:" -ForegroundColor Yellow
    $fail | ForEach-Object { Write-Host "  $_" }
    exit 1
}
