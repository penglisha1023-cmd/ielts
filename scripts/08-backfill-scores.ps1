# =====================================================================
# 08-backfill-scores.ps1
#
# Backfill the `scores` table from existing `progress` rows.
#
# Background: an earlier version of lib/supabase.js's IELTS.submitScore
# didn't include user_id when inserting into `scores`, so finished
# attempts silently failed against the RLS check. `progress` (in-progress
# answers + timer) was unaffected because upsertProgress DID set user_id.
# This script re-creates the missing score rows by grading the saved
# progress answers against each test's answerKey.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\08-backfill-scores.ps1 [-DryRun]
#
# Re-runnable: existing (user_id, test_id) score rows are kept; we only
# insert when no score row exists for that pair.
# =====================================================================

[CmdletBinding()]
param(
    [string]$SupabaseUrl = 'https://qyccvyyigtjhzunumbqf.supabase.co',
    [string]$EnvFile    = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
$repoRoot  = Split-Path -Parent $scriptDir
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env.local' }

# ---- Secret key ----
if (-not (Test-Path $EnvFile)) { Write-Host "Missing $EnvFile" -ForegroundColor Red; exit 1 }
$secretKey = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*SUPABASE_SECRET_KEY\s*=\s*(\S+)\s*$') {
        $secretKey = $Matches[1].Trim('"').Trim("'")
    }
}
if (-not $secretKey) { Write-Host "SUPABASE_SECRET_KEY not in $EnvFile" -ForegroundColor Red; exit 1 }

$ua = 'ielts-backfill/1.0'
$readHdr  = @{ apikey = $secretKey; Authorization = "Bearer $secretKey"; 'User-Agent' = $ua }
$writeHdr = @{ apikey = $secretKey; Authorization = "Bearer $secretKey"; 'Content-Type' = 'application/json; charset=utf-8'; Prefer = 'return=minimal'; 'User-Agent' = $ua }

# ---- JSON deserializer that tolerates empty-string keys ----
# (PowerShell 5.1's ConvertFrom-Json chokes on `"": "1.0"` which sneaks in
# from the playback-speed <select> being captured by collectAnswers().)
$jsSerial = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jsSerial.MaxJsonLength = 200000000

function ConvertFrom-JsonSafe([string]$text) {
    return $jsSerial.DeserializeObject($text)
}

# ---- JS object literal -> PowerShell hashtable ----
# Used to parse `answerKey: { text: { 'q1': 'diving', ... }, ... }` blocks
# directly out of each test's HTML.
function ConvertFrom-JsLiteral([string]$js) {
    # 1. Replace single-quoted strings with double-quoted.
    #    (We assume no escaped single-quote inside answer values; the seed
    #    data is all single words / letters / digits, so this is safe.)
    $json = [regex]::Replace($js, "'([^']*)'", {
        param($m)
        $inner = $m.Groups[1].Value -replace '"', '\"'
        return '"' + $inner + '"'
    })
    # 2. Quote unquoted identifier keys (text:, q1:, q27_28:, etc.)
    $json = [regex]::Replace($json, '([{,\s])([A-Za-z_][A-Za-z0-9_]*)\s*:', '$1"$2":')
    # 3. Strip trailing commas before } or ]
    $json = [regex]::Replace($json, ',(\s*[}\]])', '$1')
    return ConvertFrom-JsonSafe $json
}

function Extract-JsObject([string]$html, [string]$anchor) {
    $idx = $html.IndexOf($anchor)
    if ($idx -lt 0) { return $null }
    $start = $html.IndexOf('{', $idx)
    if ($start -lt 0) { return $null }
    $depth = 0; $inStr = $false; $strCh = $null; $escape = $false
    for ($i = $start; $i -lt $html.Length; $i++) {
        $c = $html[$i]
        if ($escape) { $escape = $false; continue }
        if ($c -eq '\') { $escape = $true; continue }
        if ($inStr) {
            if ($c -eq $strCh) { $inStr = $false }
            continue
        }
        if ($c -eq "'" -or $c -eq '"') { $inStr = $true; $strCh = $c; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $html.Substring($start, $i - $start + 1) }
        }
    }
    return $null
}

# ---- Load answer keys ----
Write-Host "Parsing answer keys..." -ForegroundColor Cyan
$listeningKeys = @{}
foreach ($file in Get-ChildItem (Join-Path $repoRoot 'tests') -Filter '*.html') {
    $id = 0
    if (-not [int]::TryParse($file.BaseName, [ref]$id)) { continue }
    $html = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $jsLit = Extract-JsObject $html 'answerKey:'
    if (-not $jsLit) { Write-Host "  [skip] tests/$($file.Name) - no answerKey" -ForegroundColor Yellow; continue }
    try {
        $listeningKeys[$id] = ConvertFrom-JsLiteral $jsLit
    } catch {
        Write-Host "  [error] tests/$($file.Name) -> $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host "  -> $($listeningKeys.Count) listening keys loaded." -ForegroundColor DarkGray

$readingKeys = @{}
if (Test-Path (Join-Path $repoRoot 'readings')) {
    foreach ($file in Get-ChildItem (Join-Path $repoRoot 'readings') -Filter '*.html') {
        $id = 0
        if (-not [int]::TryParse($file.BaseName, [ref]$id)) { continue }
        $offsetId = $id + 10000
        $html = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        $jsLit = Extract-JsObject $html 'answerKey'
        if (-not $jsLit) { Write-Host "  [skip] readings/$($file.Name) - no answerKey" -ForegroundColor Yellow; continue }
        try {
            $readingKeys[$offsetId] = ConvertFrom-JsLiteral $jsLit
        } catch {
            Write-Host "  [error] readings/$($file.Name) -> $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
Write-Host "  -> $($readingKeys.Count) reading keys loaded." -ForegroundColor DarkGray

# ---- Pull progress + existing scores ----
Write-Host "`nFetching progress rows..." -ForegroundColor Cyan
$progRaw  = (Invoke-WebRequest -Method Get -Uri "$SupabaseUrl/rest/v1/progress?select=*" -Headers $readHdr -UseBasicParsing).Content
$progress = ConvertFrom-JsonSafe $progRaw
$scoreRaw = (Invoke-WebRequest -Method Get -Uri "$SupabaseUrl/rest/v1/scores?select=user_id,test_id" -Headers $readHdr -UseBasicParsing).Content
$scoresExisting = ConvertFrom-JsonSafe $scoreRaw

$existing = @{}
foreach ($s in $scoresExisting) { $existing["$($s['user_id'])|$($s['test_id'])"] = $true }
Write-Host "  Progress: $($progress.Count) rows.  Scores already in db: $($scoresExisting.Count)." -ForegroundColor DarkGray

# ---- Grading helpers ----
function Norm($v) {
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim().ToLowerInvariant()
}

function Count-Filled-Listening($inner) {
    $n = 0
    foreach ($section in @('text','single','matching')) {
        if ($inner[$section]) {
            foreach ($k in $inner[$section].Keys) {
                if ($k -ne '' -and (Norm $inner[$section][$k]) -ne '') { $n++ }
            }
        }
    }
    if ($inner['multiple']) {
        foreach ($k in $inner['multiple'].Keys) {
            $v = $inner['multiple'][$k]
            if ($v -and @($v).Count -gt 0) { $n++ }
        }
    }
    return $n
}

function Grade-Listening($inner, $key) {
    $score = 0; $total = 0
    foreach ($section in @('text','single','matching')) {
        if ($key[$section]) {
            foreach ($qk in $key[$section].Keys) {
                $total++
                $userVal = $null
                if ($inner[$section] -and $inner[$section][$qk]) { $userVal = $inner[$section][$qk] }
                if ($userVal -and (Norm $userVal) -eq (Norm $key[$section][$qk])) { $score++ }
            }
        }
    }
    if ($key['multiple']) {
        foreach ($qk in $key['multiple'].Keys) {
            $total++
            $userArr = $null
            if ($inner['multiple'] -and $inner['multiple'][$qk]) { $userArr = @($inner['multiple'][$qk]) }
            $correctArr = @($key['multiple'][$qk])
            if ($userArr -and $userArr.Count -eq $correctArr.Count) {
                $u = ($userArr | ForEach-Object { Norm $_ }) | Sort-Object
                $c = ($correctArr | ForEach-Object { Norm $_ }) | Sort-Object
                if (($u -join '|') -eq ($c -join '|')) { $score++ }
            }
        }
    }
    return @{ score = $score; total = $total }
}

function Count-Filled-Reading($inner) {
    $n = 0
    foreach ($k in $inner.Keys) {
        if ($k -ne '' -and (Norm $inner[$k]) -ne '') { $n++ }
    }
    return $n
}

function Grade-Reading($inner, $key) {
    $score = 0; $total = 0
    foreach ($qk in $key.Keys) {
        $total++
        $userVal = $null
        if ($inner -and $inner[$qk]) { $userVal = [string]$inner[$qk] }
        # Reading uses strict, case-sensitive comparison (matches the JS `===`)
        if ($userVal -ne $null -and $userVal -eq ([string]$key[$qk])) { $score++ }
    }
    return @{ score = $score; total = $total }
}

# ---- Build score rows ----
Write-Host "`nGrading..." -ForegroundColor Cyan
$newRows = @()
$reasons = @{ alreadyScored = 0; noKey = 0; noAnswers = 0; graded = 0 }

foreach ($p in $progress) {
    $key = "$($p['user_id'])|$($p['test_id'])"
    if ($existing.ContainsKey($key)) { $reasons.alreadyScored++; continue }
    $testId = [int]$p['test_id']
    $isReading = $testId -ge 10000

    # Unwrap outer { answers: <inner> }
    $blob = $p['answers']
    $inner = $blob
    if ($blob -and $blob.ContainsKey('answers')) { $inner = $blob['answers'] }

    if ($isReading) {
        if (-not $readingKeys.ContainsKey($testId)) { $reasons.noKey++; continue }
        if ((Count-Filled-Reading $inner) -eq 0) { $reasons.noAnswers++; continue }
        $r = Grade-Reading $inner $readingKeys[$testId]
    } else {
        if (-not $listeningKeys.ContainsKey($testId)) { $reasons.noKey++; continue }
        if ((Count-Filled-Listening $inner) -eq 0) { $reasons.noAnswers++; continue }
        $r = Grade-Listening $inner $listeningKeys[$testId]
    }
    if ($r.total -le 0) { $reasons.noKey++; continue }

    $duration = 0
    if ($p['timer_secs']) { $duration = [int]$p['timer_secs'] }

    $newRows += @{
        user_id       = $p['user_id']
        test_id       = $testId
        score         = $r.score
        total         = $r.total
        duration_secs = $duration
        finished_at   = $p['updated_at']
        details       = @{ backfilled = $true; source = 'progress'; perQ = $null }
    }
    $reasons.graded++
    $shortUid = ([string]$p['user_id']).Substring(0, 8)
    Write-Host ("  user={0} test={1} -> {2}/{3}" -f $shortUid, $testId, $r.score, $r.total) -ForegroundColor DarkGray
}

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  graded:        $($reasons.graded)" -ForegroundColor Green
Write-Host "  alreadyScored: $($reasons.alreadyScored)" -ForegroundColor DarkGray
Write-Host "  noAnswers:     $($reasons.noAnswers) (student opened test but answered nothing)" -ForegroundColor DarkGray
Write-Host "  noKey:         $($reasons.noKey) (answerKey not found / unparseable)" -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "`nDry run - not inserting. Re-run without -DryRun to apply." -ForegroundColor Yellow
    return
}

if ($newRows.Count -eq 0) {
    Write-Host "`nNothing to insert." -ForegroundColor DarkGray
    return
}

Write-Host "`nInserting $($newRows.Count) rows..." -ForegroundColor Cyan
$batchSize = 100
$batches = [Math]::Ceiling($newRows.Count / [double]$batchSize)
for ($i = 0; $i -lt $batches; $i++) {
    $lo = $i * $batchSize
    $hi = [Math]::Min(($i + 1) * $batchSize - 1, $newRows.Count - 1)
    $batch = $newRows[$lo..$hi]
    $body  = $batch | ConvertTo-Json -Depth 6
    if ($batch.Count -eq 1) { $body = "[$body]" }  # ensure array shape
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Method Post -Uri "$SupabaseUrl/rest/v1/scores" -Headers $writeHdr -Body $bytes | Out-Null
    Write-Host "  Batch $($i+1)/$batches  ($($batch.Count) rows)" -ForegroundColor DarkGray
}
Write-Host "`nDone. Inserted $($newRows.Count) score rows." -ForegroundColor Green
