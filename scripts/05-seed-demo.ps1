# =====================================================================
# 05-seed-demo.ps1
#
# Seeds the most recently registered user's account with realistic
# demo data (35 unique tests completed, 37 attempts, 8 notes) so the
# home dashboard / leaderboard / scores / notes pages all look
# populated for screenshots.
#
# Idempotent: deletes existing scores/notes/progress for that user
# before inserting, so re-running gives a clean slate.
#
# Reads SUPABASE_SECRET_KEY from .env.local. Run from repo root:
#   powershell -ExecutionPolicy Bypass -File .\scripts\05-seed-demo.ps1
# =====================================================================

[CmdletBinding()]
param(
    [string]$SupabaseUrl = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$EnvFile    = '',
    [string]$Email      = ''   # optional: target a specific email; otherwise uses most recent user
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $EnvFile) { $EnvFile = Join-Path (Split-Path -Parent $scriptDir) '.env.local' }

if (-not (Test-Path $EnvFile)) {
    Write-Host "Missing $EnvFile" -ForegroundColor Red; exit 1
}
$secretKey = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*SUPABASE_SECRET_KEY\s*=\s*(\S+)\s*$') {
        $secretKey = $Matches[1].Trim('"').Trim("'")
    }
}
if (-not $secretKey) { Write-Host "SUPABASE_SECRET_KEY not in $EnvFile" -ForegroundColor Red; exit 1 }

# Supabase rejects secret-key requests with browser-like User-Agent.
$ua = 'ielts-seed/1.0'
$adminHeaders = @{ apikey = $secretKey; Authorization = "Bearer $secretKey"; 'User-Agent' = $ua }
$writeHeaders = @{ apikey = $secretKey; Authorization = "Bearer $secretKey"; 'Content-Type' = 'application/json; charset=utf-8'; Prefer = 'return=minimal'; 'User-Agent' = $ua }

# ---- Find target user ----
$listUrl = "$SupabaseUrl/auth/v1/admin/users?per_page=50"
$resp = Invoke-RestMethod -Method Get -Uri $listUrl -Headers $adminHeaders
$users = $resp.users
if (-not $users -or $users.Count -eq 0) { Write-Host "No users found in this project." -ForegroundColor Red; exit 1 }

$user = $null
if ($Email) {
    $user = $users | Where-Object { $_.email -eq $Email } | Select-Object -First 1
    if (-not $user) { Write-Host "User with email $Email not found." -ForegroundColor Red; exit 1 }
} else {
    $user = $users | Sort-Object created_at -Descending | Select-Object -First 1
}
[string]$uid = $user.id
Write-Host "Target user: $($user.email)  ($uid)" -ForegroundColor Cyan

# ---- Wipe prior data for this user ----
foreach ($table in @('scores','notes','progress')) {
    $u = "$SupabaseUrl/rest/v1/$table" + '?user_id=eq.' + $uid
    Write-Host "DELETE $u" -ForegroundColor DarkGray
    try {
        $resp = Invoke-WebRequest -Method Delete -Uri $u -Headers $writeHeaders -UseBasicParsing
        Write-Host "  -> $($resp.StatusCode)" -ForegroundColor DarkGray
    } catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { '?' }
        $body = if ($_.Exception.Response) { (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } else { $_.ToString() }
        Write-Host "  -> $code : $body" -ForegroundColor Red
        throw
    }
}
Write-Host "Cleared existing scores/notes/progress for this user." -ForegroundColor DarkGray

# ---- Build score rows (id, score, dur, days_ago) ----
$now = Get-Date
$scoreSeed = @(
    # Week 1: a few first attempts at 8 or 9 (will be re-done for 10 later)
    @{id=1;  s=8;  d=1820; ago=22}, @{id=17; s=9;  d=1780; ago=21},
    @{id=32; s=10; d=1700; ago=21}, @{id=34; s=10; d=1680; ago=20},
    @{id=3;  s=9;  d=1750; ago=20}, @{id=10; s=10; d=1640; ago=19},
    @{id=13; s=10; d=1690; ago=19}, @{id=26; s=8;  d=1830; ago=18},
    # Week 2: mostly perfect, occasional 9
    @{id=41; s=10; d=1620; ago=17}, @{id=50; s=10; d=1640; ago=16},
    @{id=55; s=10; d=1660; ago=16}, @{id=64; s=10; d=1610; ago=15},
    @{id=68; s=10; d=1600; ago=15}, @{id=29; s=10; d=1620; ago=14},
    @{id=16; s=10; d=1640; ago=14}, @{id=40; s=10; d=1610; ago=13},
    @{id=27; s=9;  d=1700; ago=13}, @{id=39; s=9;  d=1720; ago=12},
    @{id=48; s=10; d=1620; ago=12}, @{id=75; s=9;  d=1740; ago=11},
    # Week 3: full perfect run
    @{id=80; s=10; d=1580; ago=10}, @{id=83; s=10; d=1600; ago=10},
    @{id=73; s=10; d=1620; ago=9},  @{id=70; s=10; d=1590; ago=9},
    @{id=24; s=10; d=1610; ago=8},  @{id=30; s=10; d=1600; ago=8},
    @{id=33; s=10; d=1580; ago=7},  @{id=45; s=10; d=1550; ago=7},
    @{id=53; s=10; d=1620; ago=6},  @{id=65; s=10; d=1590; ago=6},
    @{id=74; s=10; d=1600; ago=5},  @{id=87; s=9;  d=1670; ago=5},
    # Recent re-attempts: nail the previously-imperfect ones
    @{id=1;  s=10; d=1500; ago=4},  @{id=17; s=10; d=1480; ago=3},
    @{id=26; s=9;  d=1620; ago=2},  @{id=84; s=10; d=1530; ago=1},
    @{id=86; s=10; d=1560; ago=1}
)
# Realistic time-of-day: weighted toward evenings (the times most students
# actually practice). Pool repeats hot hours so they get picked more often.
$hourPool = @(19,19,19,20,20,20,20,21,21,21,21,22,22, 14,15,15,16,16,17, 9,10, 23)
$rand = New-Object Random

function Get-RealisticUtc([datetime]$base, [int]$daysAgo) {
    $h = $hourPool | Get-Random
    $m = $rand.Next(0, 60)
    $s = $rand.Next(0, 60)
    return $base.Date.AddDays(-$daysAgo).AddHours($h).AddMinutes($m).AddSeconds($s).ToUniversalTime().ToString('o')
}

$scoreRows = $scoreSeed | ForEach-Object {
    @{
        user_id       = $uid
        test_id       = $_.id
        score         = $_.s
        total         = 10
        duration_secs = $_.d
        finished_at   = Get-RealisticUtc $now $_.ago
    }
}
$body = $scoreRows | ConvertTo-Json -Depth 4
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
Invoke-RestMethod -Method Post -Uri "$SupabaseUrl/rest/v1/scores" -Headers $writeHeaders -Body $bytes | Out-Null
Write-Host "Inserted $($scoreRows.Count) score rows." -ForegroundColor Green

# ---- Notes ----
$noteSeed = @(
    @{id=1;  hid='demo_h1'; quote='jungle near the beach';                 text='高频地理词,jungle ≠ forest';                              ago=20},
    @{id=17; hid='demo_h2'; quote='birthday party arrangement';            text='听到 arrangement 立刻反应到流程类信息';                  ago=18},
    @{id=32; hid='demo_h3'; quote='warranty period of two years';          text='warranty = 保修;别和 warranty period 搞混';              ago=15},
    @{id=41; hid='demo_h4'; quote='hot air balloon trip';                  text='主题词记笔记 - balloon /bəˈluːn/';                       ago=12},
    @{id=64; hid='demo_h5'; quote='temporary patient record form';         text='医学场景 - patient record form 高频出现';                ago=10},
    @{id=80; hid='demo_h6'; quote='driver support service hotline';        text='support 后面紧跟 hotline / line / number';              ago=7},
    @{id=30; hid='demo_h7'; quote='dolphin intelligence research';         text='P4 学术词:cognitive ability, problem-solving';          ago=6},
    @{id=84; hid='demo_h8'; quote='Ingmar Bergman directed many films';    text='人名拼写要熟 - Ingmar Bergman /ˈɪŋmɑːr ˈbɛrɡmən/';      ago=1}
)
$noteRows = $noteSeed | ForEach-Object {
    @{
        user_id    = $uid
        test_id    = $_.id
        hid        = $_.hid
        quote      = $_.quote
        note_text  = $_.text
        updated_at = Get-RealisticUtc $now $_.ago
    }
}
$body2 = $noteRows | ConvertTo-Json -Depth 4
$bytes2 = [Text.Encoding]::UTF8.GetBytes($body2)
Invoke-RestMethod -Method Post -Uri "$SupabaseUrl/rest/v1/notes" -Headers $writeHeaders -Body $bytes2 | Out-Null
Write-Host "Inserted $($noteRows.Count) notes." -ForegroundColor Green

Write-Host ""
Write-Host "Done. Refresh https://ielts.dnladvisory.com to see populated dashboard." -ForegroundColor Cyan
