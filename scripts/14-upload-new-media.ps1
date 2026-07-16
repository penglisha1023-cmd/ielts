# =====================================================================
# 14-upload-new-media.ps1
#
# Uploads ONLY the newly-added listening media to Supabase Storage
# (bucket `audio`), leaving the already-uploaded 1..161 objects untouched:
#
#   * New VIP set   : "IELTS Listening 虾滑VIP" internal ids 74..90
#                     -> app_id = VipIdOffset + internal (162..178).
#                     audio.mp3 -> <app_id>.mp3, map/diagram.png -> <app_id>.png
#   * New standard  : "IELTS Listening 虾滑" internal ids >= StdMinInternalId
#                     -> app_id assigned by ascending internal id starting at
#                     StdStartAppId (179..195), matching 13-build-new-standard.ps1.
#
# Requires the Supabase service_role key in .env.local at repo root:
#     SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxx
# (gitignored — NEVER commit).
#
# Run from PowerShell (cwd = repo root):
#   powershell -ExecutionPolicy Bypass -File .\scripts\14-upload-new-media.ps1
#
# Re-run is safe (upsert).
# =====================================================================

[CmdletBinding()]
param(
    [string]$SupabaseUrl      = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$Bucket           = 'audio',
    [string]$EnvFile          = '',
    [string]$VipSource        = '',
    [int]   $VipIdOffset      = 88,
    [int]   $VipMinAppId      = 162,
    [string]$StdSource        = '',
    [int]   $StdMinInternalId = 89,
    [int]   $StdStartAppId    = 179
)

$ErrorActionPreference = 'Stop'

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $EnvFile)   { $EnvFile   = Join-Path $projectRoot '.env.local' }
if (-not $VipSource) { $VipSource = Join-Path $projectRoot 'IELTS Listening 虾滑VIP' }
if (-not $StdSource) { $StdSource = Join-Path $projectRoot 'IELTS Listening 虾滑' }

# ---- secret key ------------------------------------------------------
if (-not (Test-Path $EnvFile)) { Write-Host "Missing $EnvFile" -ForegroundColor Red; exit 1 }
$secretKey = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*SUPABASE_SECRET_KEY\s*=\s*(\S+)\s*$') { $secretKey = $Matches[1].Trim('"').Trim("'") }
}
if (-not $secretKey) { Write-Host "SUPABASE_SECRET_KEY not found in $EnvFile" -ForegroundColor Red; exit 1 }

$ok   = 0
$fail = @()

function Send-File([string]$LocalPath, [int]$AppId, [string]$Ext, [string]$ContentType) {
    $url = "$SupabaseUrl/storage/v1/object/$Bucket/$AppId.$Ext"
    $headers = @{
        Authorization  = "Bearer $script:secretKey"
        apikey         = $script:secretKey
        'Content-Type' = $ContentType
        'x-upsert'     = 'true'
    }
    $size = (Get-Item $LocalPath).Length
    Write-Host ("  uploading {0}.{1} ({2:N1} KB) ..." -f $AppId, $Ext, ($size/1KB)) -NoNewline
    try {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -InFile $LocalPath -TimeoutSec 600 | Out-Null
        Write-Host ' ok' -ForegroundColor Green
        $script:ok++
    } catch {
        Write-Host ' FAIL' -ForegroundColor Red
        $script:fail += "[$AppId.$Ext] $($_.Exception.Message)"
    }
}

function Get-ArtDirs([string]$Root) {
    Get-ChildItem $Root -Directory | Where-Object { $_.Name -match '^P[1-4]$' } |
        ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        ForEach-Object { Get-ChildItem $_.FullName -Directory }
}

# ---- New VIP: app_id = offset + internal, only >= VipMinAppId ---------
Write-Host "== New VIP media ($VipSource) ==" -ForegroundColor Cyan
foreach ($d in Get-ArtDirs $VipSource) {
    if ($d.Name -notmatch '^(\d+)\.\s') { continue }
    $appId = $VipIdOffset + [int]$Matches[1]
    if ($appId -lt $VipMinAppId) { continue }
    $mp3 = Join-Path $d.FullName 'audio.mp3'
    if (Test-Path $mp3) { Send-File $mp3 $appId 'mp3' 'audio/mpeg' } else { $fail += "[$appId] missing audio.mp3" }
    $img = Get-ChildItem $d.FullName -File | Where-Object { $_.Name -in @('map.png','diagram.png') } | Select-Object -First 1
    if ($img) { Send-File $img.FullName $appId 'png' 'image/png' }
}

# ---- New standard: sort internal>=Min ascending, assign from StartAppId ----
Write-Host "== New standard media ($StdSource) ==" -ForegroundColor Cyan
$stdNew = @()
foreach ($d in Get-ArtDirs $StdSource) {
    if ($d.Name -notmatch '^(\d+)\.\s') { continue }
    $internal = [int]$Matches[1]
    if ($internal -lt $StdMinInternalId) { continue }
    $stdNew += [pscustomobject]@{ internal = $internal; dir = $d.FullName }
}
$appId = $StdStartAppId
foreach ($item in ($stdNew | Sort-Object internal)) {
    $mp3 = Join-Path $item.dir 'audio.mp3'
    if (Test-Path $mp3) { Send-File $mp3 $appId 'mp3' 'audio/mpeg' } else { $fail += "[$appId] missing audio.mp3 (internal $($item.internal))" }
    $img = Get-ChildItem $item.dir -File | Where-Object { $_.Name -in @('map.png','diagram.png') } | Select-Object -First 1
    if ($img) { Send-File $img.FullName $appId 'png' 'image/png' }
    $appId++
}

Write-Host ""
Write-Host "Done. $ok object(s) uploaded." -ForegroundColor Cyan
if ($fail.Count) {
    Write-Host "Failures:" -ForegroundColor Yellow
    $fail | ForEach-Object { Write-Host "  $_" }
    exit 1
}
