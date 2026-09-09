$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled test variable must FAIL this
# harness immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_intervals_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

# MANUAL + PULSE interval semantics (ROLE_20260909_0607):
#   MANUAL: 1..3600 s, clamp+reorder, equal bounds = fixed, uniform random
#           between inclusive resolved bounds.
#   PULSE:  5 s short slot / fresh random 10..20 s long slot, alternating
#           forever; phase is session state reset on Start-from-OFF/Stop and on
#           mode transitions, NEVER touched by volume reload, preview or
#           statistics; Windows first-blip contract = first PULSE blip after
#           ~5 s (no Android-style 500 ms startup blip).
#   Engine: SetInterval is idempotent for the same effective config; a real
#           change while ON re-arms immediately; one WinForms Timer, one clock.
#   Stats:  with MANUAL 1..1 s and an unwritable stats target, the retry is
#           bounded by the 10 s attempt window -- never one failed disk hit per
#           blip -- and playback/statistics memory are unaffected.
# Deterministic: injected monotonic time + scripted RandomInclusive; nothing is
# slept on and no real user INI is touched.

# Minimal 16-bit PCM mono WAV writer (same shape as the engine harness).
function New-Wav([string]$path, [int]$rate = 8000, [int]$ms = 200) {
    $samples = [int]($rate * $ms / 1000)
    $dataLen = $samples * 2
    $bw = New-Object IO.BinaryWriter((New-Object IO.MemoryStream))
    $bw.Write([byte[]][char[]]'RIFF'); $bw.Write([int](36 + $dataLen)); $bw.Write([byte[]][char[]]'WAVE')
    $bw.Write([byte[]][char[]]'fmt '); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([byte[]][char[]]'data'); $bw.Write([int]$dataLen)
    for ($i = 0; $i -lt $samples; $i++) { $bw.Write([int16](2000 - ($i % 4000))) }
    $bw.Flush(); [IO.File]::WriteAllBytes($path, $bw.BaseStream.ToArray()); $bw.Close()
}

try {
    $dll = Join-Path $work 'Problip.dll'
    & $csc -nologo -target:library "-out:$dll" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Problip.cs compilation failed' }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))

    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $modelType = $asm.GetType('Problip.IntervalModel', $true)
    $statsType = $asm.GetType('Problip.BlipStatsStore', $true)
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $loadMethod = $settingsType.GetMethod('Load')
    $sanitizeM = $modelType.GetMethod('SanitizeManual', $staticFlags)
    $parseKindM = $modelType.GetMethod('ParseKind', $staticFlags)
    $setIntervalM = $engineType.GetMethod('SetInterval')
    $setRangeM = $engineType.GetMethod('SetRange')
    $tickM = $engineType.GetMethod('Tick', $flags)
    $previewM = $engineType.GetMethod('Preview')

    $timerOf = { param($e) [System.Windows.Forms.Timer]$engineType.GetField('Timer', $flags).GetValue($e) }
    $nowMsField = $engineType.GetField('NowMs', $flags)
    $nextDueField = $engineType.GetField('NextDueMs', $flags)
    $kindField = $engineType.GetField('Kind', $flags)
    $manualMinField = $engineType.GetField('ManualMinMs', $flags)
    $manualMaxField = $engineType.GetField('ManualMaxMs', $flags)
    $pulsePhaseField = $engineType.GetField('PulseShortNext', $flags)
    $randomField = $engineType.GetField('RandomInclusive', $flags)
    $playerField = $engineType.GetField('Player', $flags)
    $schedField = $engineType.GetField('ScheduledPlayCount', $flags)
    $statsField = $engineType.GetField('Stats', $flags)
    $statsNowField = $statsType.GetField('NowMs', $flags)
    $statsLocalNowField = $statsType.GetField('LocalNow', $flags)
    $statsSnapM = $statsType.GetMethod('Snapshot')
    $attemptField = $statsType.GetField('FlushAttemptCount', $flags)
    $kindManual = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Manual')
    $kindPulse = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Pulse')
    $kindRange = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Range')

    $wav = Join-Path $work 'tone.wav'
    New-Wav $wav
    $statsDay = [datetime]'2026-09-09'

    $engines = @()
    # newEngine [minMs maxMs]: fresh engine with a silent playable asset, fake
    # monotonic clock at 0 and a stats store on the same fake clock.
    $newEngine = {
        param([string]$minMs = '4000', [string]$maxMs = '7000')
        $dir = Join-Path $work ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $s = $settingsCtor.Invoke(@([string]$dir))
        $loadMethod.Invoke($s, @()) | Out-Null
        $s.WavPath = [string]$wav
        $s.Volume = 0.0
        $s.MinMs = [int]$minMs; $s.MaxMs = [int]$maxMs
        $e = $engineCtor.Invoke(@($s))
        $script:fakeNow = [long]0
        $nowMsField.SetValue($e, [Func[long]]{ param() $script:fakeNow })
        $st = $statsField.GetValue($e)
        $statsNowField.SetValue($st, [Func[long]]{ param() $script:fakeNow })
        $statsLocalNowField.SetValue($st, [Func[datetime]]{ param() $statsDay })
        $playerField.SetValue($e, (New-Object System.Media.SoundPlayer $wav))
        $script:engines += $e
        return $e
    }
    $setClock = { param($e, [long]$t) $script:fakeNow = $t }
    $schedOf = { param($e) [int]$schedField.GetValue($e) }
    $phaseOf = { param($e) [bool]$pulsePhaseField.GetValue($e) }

    # ---- MANUAL pure semantics (sanitize) ----
    $a = $sanitizeM.Invoke($null, @(4, 7))
    Check 'MANUAL 4,7 -> 4,7' ($a[0] -eq 4 -and $a[1] -eq 7) "got=$($a[0]),$($a[1])"
    $b = $sanitizeM.Invoke($null, @(10, 5))
    Check 'MANUAL 10,5 reorders -> 5,10' ($b[0] -eq 5 -and $b[1] -eq 10) "got=$($b[0]),$($b[1])"
    $c = $sanitizeM.Invoke($null, @(0, 9999))
    Check 'MANUAL 0,9999 clamps -> 1,3600' ($c[0] -eq 1 -and $c[1] -eq 3600) "got=$($c[0]),$($c[1])"

    # D. equal bounds behave as a FIXED interval (engine resolves to ms)
    $eD = & $newEngine 4000 7000
    $setIntervalM.Invoke($eD, @($kindManual, 20000, 20000))
    $tD = & $timerOf $eD
    $eD.Start()
    Check 'MANUAL 20,20 is a fixed 20-second interval' `
        ([long]$manualMinField.GetValue($eD) -eq 20000 -and [double]$tD.Interval -eq 20000) `
        "min=$([long]$manualMinField.GetValue($eD)) interval=$($tD.Interval)"

    # E. random manual result stays inside the inclusive bounds
    $eE = & $newEngine 4000 7000
    $setIntervalM.Invoke($eE, @($kindManual, 4000, 7000))
    $script:scripted = 4000
    $randomField.SetValue($eE, [Func[int,int,int]]{ param($lo, $hi) $script:scripted })
    $tE = & $timerOf $eE
    $eE.Start()
    $loOk = ([double]$tE.Interval -eq 4000)
    $script:scripted = 7000
    $tickM.Invoke($eE, @($null, [EventArgs]::Empty))
    $hiOk = ([double]$tE.Interval -eq 7000)
    Check 'MANUAL random delay stays inside the inclusive bounds (lo and hi both reachable)' `
        ($loOk -and $hiOk) "lo4000=$loOk hi7000=$hiOk"

    # ---- PULSE (F-O) ----
    # F. fresh Start: first delay = exactly 5000 (no 500 ms startup blip)
    $eF = & $newEngine 4000 7000
    $script:randCalls = 0
    $script:longVal = 15000
    $randomField.SetValue($eF, [Func[int,int,int]]{ param($lo, $hi) $script:randCalls++; $script:longVal })
    $setIntervalM.Invoke($eF, @($kindPulse, 4000, 7000))   # select Pulse while OFF
    $tF = & $timerOf $eF
    $eF.Start()
    Check 'fresh PULSE Start arms the 5-second short slot first' ([double]$tF.Interval -eq 5000) "interval=$($tF.Interval)"
    Check 'fresh PULSE Start consumed no long-slot random draw' ($script:randCalls -eq 0) "draws=$($script:randCalls)"

    # G. after the first successful Tick: next delay is the scripted long value
    $script:fakeNow = 5000
    $tickM.Invoke($eF, @($null, [EventArgs]::Empty))
    Check 'after the first PULSE tick the long slot is armed (scripted 15000)' ([double]$tF.Interval -eq 15000) "interval=$($tF.Interval)"
    Check 'the long slot drew exactly one random value' ($script:randCalls -eq 1) "draws=$($script:randCalls)"
    Check 'the first PULSE tick counts exactly one scheduled play' ((& $schedOf $eF) -eq 1) "scheduled=$(& $schedOf $eF)"

    # H. after the next Tick: back to the 5-second short slot
    $script:fakeNow = 5000 + 15000
    $tickM.Invoke($eF, @($null, [EventArgs]::Empty))
    Check 'the next PULSE tick returns to the 5-second short slot' ([double]$tF.Interval -eq 5000) "interval=$($tF.Interval)"
    Check 'the short slot consumed no new random draw' ($script:randCalls -eq 1) "draws=$($script:randCalls)"

    # I. the next long slot requests a NEW random value
    $script:longVal = 17500
    $script:fakeNow = 5000 + 15000 + 5000
    $tickM.Invoke($eF, @($null, [EventArgs]::Empty))
    Check 'the next PULSE long slot draws a FRESH random value (scripted 17500)' `
        ([double]$tF.Interval -eq 17500 -and $script:randCalls -eq 2) "interval=$($tF.Interval) draws=$($script:randCalls)"

    # J. Stop + Start: first delay resets to the 5-second short slot
    $eF.Stop()
    Check 'Stop resets the PULSE phase to the short slot' ((& $phaseOf $eF) -eq $true) "phase=$(& $phaseOf $eF)"
    $tF2 = & $timerOf $eF
    $eF.Start()
    Check 'Stop + Start begins PULSE at the short 5-second slot again' ([double]$tF2.Interval -eq 5000) "interval=$($tF2.Interval)"

    # K. switch Range -> Pulse while ON: immediately arms 5000
    $eK = & $newEngine 30000 30000
    $tK = & $timerOf $eK
    $randomField.SetValue($eK, [Func[int,int,int]]{ param($lo, $hi) 15000 })
    $eK.Start()
    Check 'a long Range wait is armed before the mode change' ([double]$tK.Interval -eq 30000) "interval=$($tK.Interval)"
    $setIntervalM.Invoke($eK, @($kindPulse, 30000, 30000))
    Check 'Range -> Pulse while ON immediately arms the 5-second short slot' `
        ($eK.IsOn -and [double]$tK.Interval -eq 5000 -and (& $phaseOf $eK) -eq $false) `
        "interval=$($tK.Interval) phase=$(& $phaseOf $eK)"

    # L. switch Pulse -> Range: immediately arms the target range
    $setRangeM.Invoke($eK, @(10000, 10000))
    Check 'Pulse -> Range while ON immediately arms the target range' `
        ([double]$tK.Interval -eq 10000 -and [long]$kindField.GetValue($eK) -eq [int]$kindRange) `
        "interval=$($tK.Interval) kind=$([int]$kindField.GetValue($eK))"

    # M. selecting the already-active Pulse again is idempotent
    $eM = & $newEngine 10000 10000
    $tM = & $timerOf $eM
    $randomField.SetValue($eM, [Func[int,int,int]]{ param($lo, $hi) $script:randCalls++; 12000 })
    $eM.Start()                                 # Range 10s armed
    $setIntervalM.Invoke($eM, @($kindPulse, 10000, 10000))   # -> Pulse, arms 5000
    $script:fakeNow = 2000
    $dueM = [long]$nextDueField.GetValue($eM)
    $phaseM = & $phaseOf $eM
    $ivM = [double]$tM.Interval
    $setIntervalM.Invoke($eM, @($kindPulse, 10000, 10000))   # same again
    Check 're-selecting the current Pulse leaves NextDueMs unchanged' ([long]$nextDueField.GetValue($eM) -eq $dueM) "due=$([long]$nextDueField.GetValue($eM)) original=$dueM"
    Check 're-selecting the current Pulse leaves the phase unchanged' ((& $phaseOf $eM) -eq $phaseM) "phase=$(& $phaseOf $eM) original=$phaseM"
    Check 're-selecting the current Pulse does not redraw the armed interval' ([double]$tM.Interval -eq $ivM) "interval=$($tM.Interval) original=$ivM"

    # N. volume reload during Pulse: absolute due preserved, phase unchanged
    $script:fakeNow = 1000
    $randBeforeN = $script:randCalls
    $dueN = [long]$nextDueField.GetValue($eM)      # pending Pulse wait (mid-slot)
    $phaseN = & $phaseOf $eM
    $eM.Reload()
    Check 'a volume reload during Pulse preserves the absolute due time' `
        ([long]$nextDueField.GetValue($eM) -eq $dueN) "due=$([long]$nextDueField.GetValue($eM)) original=$dueN"
    Check 'a volume reload during Pulse does not toggle the phase' ((& $phaseOf $eM) -eq $phaseN) "phase=$(& $phaseOf $eM)"
    # the due tick still fires into the slot that was already next
    $script:fakeNow = $dueN
    $tickM.Invoke($eM, @($null, [EventArgs]::Empty))
    # phase was False (long was next); the tick plays and arms the LONG slot
    # (scripted 12000), toggling the phase back to short-next.
    $randAfterN = $script:randCalls
    Check 'the preserved Pulse due tick still fires and re-arms the next slot' `
        ((& $schedOf $eM) -ge 1 -and [double]$tM.Interval -eq 12000 -and (& $phaseOf $eM) -eq $true -and $randAfterN -eq ($randBeforeN + 1)) `
        "scheduled=$(& $schedOf $eM) interval=$($tM.Interval) phase=$(& $phaseOf $eM) draws=$randAfterN"

    # O. preview during Pulse: due/phase/stats untouched
    $dueO = [long]$nextDueField.GetValue($eM)
    $phaseO = & $phaseOf $eM
    $schedO = & $schedOf $eM
    $stO = $statsField.GetValue($eM)
    $totalO = $statsSnapM.Invoke($stO, @()).Total
    $okO = [bool]$previewM.Invoke($eM, @())
    Check 'a preview during Pulse plays through the preview path' ($okO -and $eM.PreviewCount -ge 1) "ok=$okO"
    Check 'a preview during Pulse leaves the due time unchanged' ([long]$nextDueField.GetValue($eM) -eq $dueO) "due=$([long]$nextDueField.GetValue($eM)) original=$dueO"
    Check 'a preview during Pulse leaves the phase unchanged' ((& $phaseOf $eM) -eq $phaseO) "phase=$(& $phaseOf $eM)"
    Check 'a preview during Pulse counts no scheduled play and no statistic' `
        ((& $schedOf $eM) -eq $schedO -and $statsSnapM.Invoke($stO, @()).Total -eq $totalO) `
        "scheduled=$(& $schedOf $eM) total=$($statsSnapM.Invoke($stO, @()).Total)"

    # ---- ParseKind backward compatibility ----
    Check 'a missing/malformed IntervalKind normalizes to Range' `
        (([int]$parseKindM.Invoke($null, @('range')) -eq 0) -and
         ([int]$parseKindM.Invoke($null, @('junk')) -eq 0) -and
         ([int]$parseKindM.Invoke($null, @('')) -eq 0) -and
         ([int]$parseKindM.Invoke($null, @($null)) -eq 0))

    # ---- stats failure + 1-second MANUAL regression (the throttle fix) ----
    # An unwritable stats target + MANUAL 1..1 s: every scheduled blip must
    # still play and count in memory, while the failed disk attempts stay
    # bounded by the 10-second retry window.
    $dirF = Join-Path $work 'fastfail'; New-Item -ItemType Directory -Path $dirF | Out-Null
    $sF = $settingsCtor.Invoke(@([string]$dirF))
    $loadMethod.Invoke($sF, @()) | Out-Null
    $sF.WavPath = [string]$wav
    $sF.Volume = 0.0
    $eS = $engineCtor.Invoke(@($sF))
    $script:engines += $eS
    $script:fakeNow = 0
    $nowMsField.SetValue($eS, [Func[long]]{ param() $script:fakeNow })
    $stS = $statsField.GetValue($eS)
    # unwritable: point the store at a DIRECTORY (an INI cannot live there)
    $statsPathField = $statsType.GetField('Path', $flags)
    $statsPathField.SetValue($stS, [string](Join-Path $dirF 'blocked'))
    New-Item -ItemType Directory -Path (Join-Path $dirF 'blocked') -Force | Out-Null
    $statsNowField.SetValue($stS, [Func[long]]{ param() $script:fakeNow })
    $statsLocalNowField.SetValue($stS, [Func[datetime]]{ param() $statsDay })
    $playerField.SetValue($eS, (New-Object System.Media.SoundPlayer $wav))
    $setIntervalM.Invoke($eS, @($kindManual, 1000, 1000))
    $eS.Start()
    for ($i = 1; $i -le 12; $i++) {
        $script:fakeNow = 1000 * $i
        $tickM.Invoke($eS, @($null, [EventArgs]::Empty))
        if (-not $eS.IsOn) { break }
    }
    $snapS = $statsSnapM.Invoke($stS, @())
    $schedS = & $schedOf $eS
    Check 'unwritable stats + 1s MANUAL: 12 scheduled blips all played (engine stays ON)' `
        ($schedS -eq 12 -and $eS.IsOn) "scheduled=$schedS on=$($eS.IsOn)"
    Check 'unwritable stats + 1s MANUAL: in-memory Total reaches 12' ($snapS.Total -eq 12) "total=$($snapS.Total)"
    $attempts = [int]$attemptField.GetValue($stS)
    Check 'failed stats attempts are bounded by the 10s window, not one per blip' `
        ($attempts -ge 1 -and $attempts -le 2) "attempts=$attempts blips=12"

    # ---- theme switch scheduling immunity ----
    # A theme change is a pure visual setting: it must NOT call Start/Stop/
    # SetInterval, must NOT move NextDueMs or Pulse phase, and must NOT redraw
    # a pending interval. Proven against the real engine seams.
    $themeModelType = $asm.GetType('Problip.ThemeModel', $true)
    $paletteFieldType = $asm.GetType('Problip.Palette', $true)
    $currentField = $paletteFieldType.GetField('Current', [Reflection.BindingFlags]'Static,NonPublic,Public')
    if ($null -eq $themeModelType -or $null -eq $currentField) {
        Check 'the theme model exists for the immunity regression' $false 'ThemeModel/Palette.Current missing'
    } else {
        $paletteForM = $themeModelType.GetMethod('PaletteFor', [Reflection.BindingFlags]'Static,Public,NonPublic')
        $dracula = $paletteForM.Invoke($null, @([string]'theme_wintage_dracula'))
        $draculaBg = $dracula.GetType().GetField('BG').GetValue($dracula)  # touch to force load
        $eT = & $newEngine 5000 5000
        $tT = & $timerOf $eT
        $script:fakeNowT = [long]1000
        $nowMsField.SetValue($eT, [Func[long]]{ param() $script:fakeNowT })
        $eT.Start()
        $dueT = [long]$nextDueField.GetValue($eT)
        $ivT = [double]$tT.Interval
        $drawsT = [int]($engineType.GetField('IntervalDrawCount', $flags).GetValue($eT))
        $schedT = & $schedOf $eT
        $phaseT = (& $phaseOf $eT)
        # switch the palette the way Program.ApplyThemeId does after a save
        $currentField.SetValue($null, $dracula)
        $back = $paletteForM.Invoke($null, @([string]'theme_classic'))
        $currentField.SetValue($null, $back)
        Check 'a theme switch leaves the engine ON with the timer running' ($eT.IsOn -and $tT.Enabled) "on=$($eT.IsOn) timer=$($tT.Enabled)"
        Check 'a theme switch does not move NextDueMs' ([long]$nextDueField.GetValue($eT) -eq $dueT) "due=$([long]$nextDueField.GetValue($eT)) original=$dueT"
        Check 'a theme switch does not redraw Timer.Interval' ([double]$tT.Interval -eq $ivT) "interval=$($tT.Interval) original=$ivT"
        Check 'a theme switch draws no new interval' ([int]($engineType.GetField('IntervalDrawCount', $flags).GetValue($eT)) -eq $drawsT) "draws=$([int]($engineType.GetField('IntervalDrawCount', $flags).GetValue($eT))) original=$drawsT"
        Check 'a theme switch plays no blip and counts no statistic' ((& $schedOf $eT) -eq $schedT) "scheduled=$(& $schedOf $eT)"
        Check 'a theme switch leaves the PULSE phase untouched' ((& $phaseOf $eT) -eq $phaseT)
    }

} finally {
    foreach ($e in $engines) { try { $e.Cleanup() } catch { } }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
