$ErrorActionPreference = 'Stop'
# Bounded real-runtime smoke for the MANUAL/PULSE wave (ROLE_20260909_0607 §31).
# Disposable copies under %TEMP%, volume 0.00 (silent, real playback path).
# The stats TotalCount is flushed at most once per 10 s (bounded batching), so
# it is a LOWER-BOUND blip oracle: it proves scheduled playback happened and
# that the app stays alive. Per-blip cadence (2-4 s MANUAL gaps, PULSE 5 /
# 10-20 alternation) is proven deterministically by tests\test_intervals.ps1
# with injected clocks. Nothing interactive is clicked here: tray/TEST/volume
# interactions stay a user smoke.
$root = 'V:\___VAC\__K\__CODE\_PY\_PROBLIP'
$smoke = Join-Path $env:TEMP ('problip_smoke_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $smoke | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

function New-Copy([string]$name, [string]$ini) {
    $dir = Join-Path $smoke $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'Problip.exe') -Destination (Join-Path $dir 'Problip.exe')
    Copy-Item -LiteralPath (Join-Path $root 'blip01.wav') -Destination (Join-Path $dir 'blip01.wav')
    Copy-Item -LiteralPath (Join-Path $root 'problip.ico') -Destination (Join-Path $dir 'problip.ico')
    Set-Content -LiteralPath (Join-Path $dir 'problip.ini') -Value $ini -NoNewline
    return $dir
}

function Read-Total([string]$dir) {
    # The stats file is replaced atomically while the app runs; a read can hit
    # the swap. Missing file = 0 (no flush yet), not an error.
    try {
        $t = Get-Content -LiteralPath (Join-Path $dir 'problip.stats.ini') -Raw -ErrorAction Stop
        if ($t -match 'TotalCount=(\d+)') { return [long]$Matches[1] }
        return [long]0
    } catch { return [long]0 }
}

function Run-Smoke([string]$dir, [int]$seconds, [double]$sampleSec) {
    $p = Start-Process -FilePath (Join-Path $dir 'Problip.exe') -WorkingDirectory $dir -PassThru
    $samples = New-Object System.Collections.Generic.List[object]
    $t0 = [DateTime]::UtcNow
    $deadline = $t0.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds ([int]($sampleSec * 1000))
        $total = Read-Total $dir
        $alive = -not $p.HasExited
        $tsec = [Math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1)
        $samples.Add([pscustomobject]@{ T = $tsec; Total = $total; Alive = $alive })
    }
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    [void]$p.WaitForExit(3000)
    return $samples.ToArray()
}

try {
    Write-Host "smoke root: $smoke"

    # ---- 1-3: STATS FAILURE SAFETY with MANUAL 1..1 ----
    $d1 = New-Copy 'statsfail' "[problip]`r`nVolume=0.00`r`nRunOnLaunch=1`r`nIntervalKind=manual`r`nManualFromSec=1`r`nManualToSec=1"
    # make the stats destination unwritable: problip.stats.ini is a DIRECTORY
    New-Item -ItemType Directory -Path (Join-Path $d1 'problip.stats.ini') -Force | Out-Null
    $p1 = Start-Process -FilePath (Join-Path $d1 'Problip.exe') -WorkingDirectory $d1 -PassThru
    Start-Sleep -Seconds 14
    $alive = -not $p1.HasExited
    if (-not $p1.HasExited) { try { $p1.Kill() } catch { } }
    [void]$p1.WaitForExit(3000)
    Check '1s MANUAL with an unwritable stats target: the app stays alive 14s' $alive "alive=$alive"
    Check '1s MANUAL with an unwritable stats target: no temp snapshot left behind' `
        (-not (Test-Path -LiteralPath (Join-Path $d1 'problip.stats.ini.tmp'))) "tmp leftover"
    Check 'the blocked stats target was never replaced by a file' `
        ((Get-Item -LiteralPath (Join-Path $d1 'problip.stats.ini')).PSIsContainer)

    # ---- 4-6: MANUAL 2..4 scheduled playback + persistence ----
    $d2 = New-Copy 'manual' "[problip]`r`nVolume=0.00`r`nRunOnLaunch=1`r`nIntervalKind=manual`r`nManualFromSec=2`r`nManualToSec=4"
    $s2 = Run-Smoke $d2 16 1.0
    Check 'MANUAL 2-4: app alive through the whole 16 s window' (@($s2 | Where-Object { -not $_.Alive }).Count -eq 0) "dead=$(@($s2 | Where-Object { -not $_.Alive }).Count)"
    $final2 = ($s2 | Select-Object -Last 1).Total
    # 16 s at 2-4 s blips -> 4-8 blips; the 10 s flush grid makes the flushed
    # total a lower bound.
    Check 'MANUAL 2-4: scheduled blips counted (lower bound through the flush grid)' ($final2 -ge 3) "total=$final2"
    $ini2 = Get-Content -LiteralPath (Join-Path $d2 'problip.ini') -Raw
    Check 'MANUAL 2-4: persisted ini still manual 2/4 after the run' `
        ($ini2 -match 'IntervalKind=manual' -and $ini2 -match 'ManualFromSec=2' -and $ini2 -match 'ManualToSec=4') $ini2.Trim()

    # ---- 7-8: a 10/5 ini normalizes on load (5/10) and runs ----
    $d3 = New-Copy 'manualnorm' "[problip]`r`nVolume=0.00`r`nRunOnLaunch=1`r`nIntervalKind=manual`r`nManualFromSec=10`r`nManualToSec=5"
    $s3 = Run-Smoke $d3 25 1.0
    Check 'a 10/5 manual ini: app runs (normalization on load)' (@($s3 | Where-Object { -not $_.Alive }).Count -eq 0) "dead=$(@($s3 | Where-Object { -not $_.Alive }).Count)"
    # normalized bounds are 5..10 s random: 25 s holds 2-5 blips
    $final3 = ($s3 | Select-Object -Last 1).Total
    Check 'a 10/5 manual ini (normalized 5/10): at least two scheduled blips in 25 s' ($final3 -ge 2) "total=$final3"

    # ---- 9-12: PULSE ----
    $d4 = New-Copy 'pulse' "[problip]`r`nVolume=0.00`r`nRunOnLaunch=1`r`nIntervalKind=pulse"
    $s4 = Run-Smoke $d4 50 1.0
    Check 'PULSE: app alive through the whole 50 s window' (@($s4 | Where-Object { -not $_.Alive }).Count -eq 0) "dead=$(@($s4 | Where-Object { -not $_.Alive }).Count)"
    $final4 = ($s4 | Select-Object -Last 1).Total
    Check 'PULSE: at least two scheduled blips in 50 s' ($final4 -ge 2) "total=$final4"
    # The first flush happens at the SECOND RecordBlip (the first blip at ~5 s
    # leaves NowMs-0 < 10000, so no flush): the first counted snapshot must
    # appear by ~26 s and hold both the 5 s blip and the first long blip.
    $firstNonZero = @($s4 | Where-Object { $_.Total -ge 1 } | Select-Object -First 1)
    Check 'PULSE: first counted flush lands by ~26 s holding the 5 s short-slot start' `
        ($firstNonZero.Count -gt 0 -and $firstNonZero[0].T -le 26 -and $firstNonZero[0].Total -eq 2) `
        "firstCountedAt=$($firstNonZero[0].T) total=$($firstNonZero[0].Total)"
    $ini4 = Get-Content -LiteralPath (Join-Path $d4 'problip.ini') -Raw
    Check 'PULSE: persisted ini still pulse after the run' ($ini4 -match 'IntervalKind=pulse') $ini4.Trim()

    Write-Host '---'
    Write-Host "samples MANUAL 2-4: $(($s2 | ForEach-Object { "$($_.T)s=$($_.Total)" }) -join ' ')"
    Write-Host "samples MANUAL 10/5: $(($s3 | ForEach-Object { "$($_.T)s=$($_.Total)" }) -join ' ')"
    Write-Host "samples PULSE:      $(($s4 | ForEach-Object { "$($_.T)s=$($_.Total)" }) -join ' ')"
} finally {
    Get-Process -Name 'Problip' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$smoke*" } | ForEach-Object { try { $_.Kill() } catch { } }
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $smoke) { Remove-Item -LiteralPath $smoke -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($fail) { Write-Host "SMOKE FAILED ($fail failure(s))"; exit 1 }
Write-Host 'SMOKE PASS (0 failures)'
exit 0
