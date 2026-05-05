# =====================================================================
# 02-upload-audio.ps1
#
# Uploads all 88 audio.mp3 files to the Supabase Storage `audio` bucket,
# named <id>.mp3 (where <id> is the leading number from the source folder).
#
# Requires the project's Supabase **secret** (service_role) key. Set it
# in a local file `.env.local` at repo root:
#
#     SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxx
#
# That file is gitignored. NEVER commit the secret key.
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\02-upload-audio.ps1
#
# Re-run is safe: it overwrites existing files (upsert).
# =====================================================================

[CmdletBinding()]
param(
    [string]$Source       = 'D:\共享文件夹\桌面\IELTS Listening',
    [string]$SupabaseUrl  = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$Bucket       = 'audio',
    [string]$EnvFile      = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $scriptDir) '.env.local' }

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

# ---- Walk source folders ---------------------------------------------
$folders = Get-ChildItem $Source -Directory | Where-Object { $_.Name -match '^P[1-4]$' } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { $_.Name -in @('高频', '非高频') } |
    ForEach-Object { Get-ChildItem $_.FullName -Directory }

$total = 0
$ok    = 0
$fail  = @()

foreach ($f in $folders) {
    if ($f.Name -notmatch '^(\d+)\.\s') {
        Write-Warning "Skipping (no leading number): $($f.Name)"; continue
    }
    $id = [int]$Matches[1]
    $mp3 = Join-Path $f.FullName 'audio.mp3'
    if (-not (Test-Path $mp3)) { $fail += "[$id] missing audio.mp3 in $($f.Name)"; continue }

    $total++
    $size = (Get-Item $mp3).Length
    $url  = "$SupabaseUrl/storage/v1/object/$Bucket/$id.mp3"
    $headers = @{
        Authorization   = "Bearer $secretKey"
        apikey          = $secretKey
        'Content-Type'  = 'audio/mpeg'
        'x-upsert'      = 'true'
    }

    Write-Host ("[{0,2}/88] uploading id={1} ({2:N1} MB) ..." -f $total, $id, ($size/1MB)) -NoNewline
    try {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -InFile $mp3 -TimeoutSec 600 | Out-Null
        Write-Host ' ok' -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ' FAIL' -ForegroundColor Red
        $fail += "[$id] $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done. $ok / $total uploaded." -ForegroundColor Cyan
if ($fail.Count) {
    Write-Host "Failures:" -ForegroundColor Yellow
    $fail | ForEach-Object { Write-Host "  $_" }
    exit 1
}
