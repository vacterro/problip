param(
    [string]$Source = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs')
)

$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled test variable must FAIL this
# harness immediately instead of silently evaluating to $null (the false-green
# that once let a dead $plays counter stand in for a playback assertion).
Set-StrictMode -Version 2.0
$fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "PASS  $name  $detail" } else { Write-Host "FAIL  $name  $detail"; $script:fails++ }
}

# Behavioral checks for BlipEngine scheduling and lifecycle:
#   - Start() arms the FIRST timer interval from the configured range, not a
#     hard-coded 500 ms.
#   - SetRange() re-arms a running timer immediately and never starts a
#     stopped one.
#   - Cleanup() is idempotent and disposes the WinForms timer.
#   - Preview() plays once without flipping ON/OFF, without re-arming the
#     pending wait and without touching the timer.
#   - A volume reload preserves the remaining scheduled wait; an interval
#     change intentionally redraws it.
# The engine is driven through reflection against the compiled real source;
# the timer state is inspected, never slept on.

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }

$sandbox = Join-Path $env:TEMP ('problip_eng_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

# Minimal 16-bit PCM mono WAV writer: enough for BuildCache to accept.
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
    $asmPath = Join-Path $sandbox 'ProblipUnderTest.dll'
    $out = & $csc -nologo -target:library "-out:$asmPath" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $Source 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  the subject compiles  $($out -join ' ')"; exit 1 }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($asmPath))

    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $settingsType = $asm.GetType('Problip.Settings')
    $engineType = $asm.GetType('Problip.BlipEngine')
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $loadMethod = $settingsType.GetMethod('Load')

    $wav = Join-Path $sandbox 'tone.wav'
    New-Wav $wav

    $engines = @()
    $newEngine = {
        param([string]$minMs, [string]$maxMs)
        $dir = Join-Path $sandbox ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $s = $settingsCtor.Invoke(@([string]$dir))
        $loadMethod.Invoke($s, @()) | Out-Null
        $s.WavPath = $wav
        # Volume 0: the cache scales to silence, so previews and any playback
        # exercise the real code path without beeping the developer's speakers.
        $s.Volume = 0.0
        $s.MinMs = [int]$minMs
        $s.MaxMs = [int]$maxMs
        $e = $engineCtor.Invoke(@($s))
        $script:engines += $e
        return $e
    }
    $timerOf = { param($e) [System.Windows.Forms.Timer]$engineType.GetField('Timer', $flags).GetValue($e) }

    # 1. First blip timing: fixed 5s range arms exactly 5000, never 500.
    $e1 = & $newEngine 5000 5000
    $t1 = & $timerOf $e1
    $e1.Start()
    Check 'Start() arms the first blip from the fixed range (5000, not 500)' `
        ($e1.IsOn -and $t1.Interval -eq 5000) "interval=$($t1.Interval)"

    # 2. Jittered range: the armed interval lands inside [4000, 7000].
    $e2 = & $newEngine 4000 7000
    $t2 = & $timerOf $e2
    $e2.Start()
    Check 'Start() arms the first blip inside the jittered range' `
        ($t2.Interval -ge 4000 -and $t2.Interval -le 7000) "interval=$($t2.Interval)"
    Check 'the armed interval is not the old hard-coded 500 ms' ($t2.Interval -ne 500) "interval=$($t2.Interval)"

    # 3. SetRange while running: pending timer re-arms immediately.
    $e3 = & $newEngine 30000 30000
    $t3 = & $timerOf $e3
    $e3.Start()
    Check 'a long interval is armed before the change' ($t3.Interval -eq 30000) "interval=$($t3.Interval)"
    $e3.SetRange(4000, 7000)
    Check 'SetRange re-arms a running timer from the new range immediately' `
        ($e3.IsOn -and $t3.Interval -ge 4000 -and $t3.Interval -le 7000) "interval=$($t3.Interval) on=$($e3.IsOn)"

    # 4. SetRange while stopped: range changes, engine stays off.
    $e4 = & $newEngine 4000 7000
    $t4 = & $timerOf $e4
    $e4.SetRange(20000, 20000)
    Check 'SetRange while stopped does not start the engine' (-not $e4.IsOn -and -not $t4.Enabled) "on=$($e4.IsOn)"
    $e4.Start()
    Check 'the new range governs the next Start after a stopped SetRange' ($t4.Interval -eq 20000) "interval=$($t4.Interval)"

    # 5. Cleanup is idempotent and detaches the timer (Dispose + field nulled).
    #    PS5.1 cannot observe Timer.IsDisposed directly (no public member), so the
    #    observable contract is: the engine drops its timer reference and a second
    #    Cleanup neither throws nor resurrects it.
    $e5 = & $newEngine 4000 7000
    $t5 = & $timerOf $e5
    $e5.Start()
    $e5.Cleanup()
    $timerField = $engineType.GetField('Timer', $flags)
    $timerNulled = ($null -eq $timerField.GetValue($e5))
    try { $e5.Cleanup(); $secondOk = $true } catch { $secondOk = $false }
    $stillNulled = ($null -eq $timerField.GetValue($e5))
    Check 'Cleanup detaches and disposes the WinForms timer' ($timerNulled -and $stillNulled) "nulled=$timerNulled"
    Check 'Cleanup is idempotent (second call is a no-op)' $secondOk
    Check 'Cleanup leaves the engine off' (-not $e5.IsOn)

    # 6. Fresh Settings default: autostart OFF on a clean install, stored in INI.
    $freshDir = Join-Path $sandbox ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $freshDir | Out-Null
    $s6 = $settingsCtor.Invoke(@([string]$freshDir))
    $loadMethod.Invoke($s6, @()) | Out-Null
    Check 'fresh settings default autostart to OFF' (-not $s6.AutoStart) "autostart=$($s6.AutoStart)"
    $iniText = Get-Content -LiteralPath (Join-Path $freshDir 'problip.ini') -Raw
    Check 'the newly generated INI stores AutoStart=0' ($iniText -match 'AutoStart=0') $iniText.Trim()

    # 7. An existing AutoStart=1 INI keeps autostart enabled.
    $keepDir = Join-Path $sandbox ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $keepDir | Out-Null
    Set-Content -LiteralPath (Join-Path $keepDir 'problip.ini') -Value "[problip]`r`nAutoStart=1"
    $s7 = $settingsCtor.Invoke(@([string]$keepDir))
    $loadMethod.Invoke($s7, @()) | Out-Null
    Check 'an existing AutoStart=1 setting remains enabled' $s7.AutoStart "autostart=$($s7.AutoStart)"

    # 8. Autostart Run-entry check is path-aware, exercised on a throwaway
    #    registry key -- never on the real developer Run key.
    $testKey = 'Software\ProblipTest_' + [Guid]::NewGuid().ToString('N')
    $fakeExe = 'C:\nowhere\Problip.exe'
    $asType = $asm.GetType('Problip.AutoStart')
    $setM = $asType.GetMethod('Set', $staticFlags)
    $clearM = $asType.GetMethod('Clear', $staticFlags)
    $checkM = $asType.GetMethod('IsEnabled', $staticFlags)
    if ($null -eq $asType -or $null -eq $setM -or $null -eq $clearM -or $null -eq $checkM) {
        Check 'an autostart helper exists for path-aware checks' $false 'Problip.AutoStart Set/Clear/IsEnabled missing'
    } else {
        try {
            $checkM.Invoke($null, @([string]$testKey, [string]$fakeExe)) | Out-Null
        } catch { }
        $before = [bool]$checkM.Invoke($null, @([string]$testKey, [string]$fakeExe))
        $setM.Invoke($null, @([string]$testKey, [string]$fakeExe)) | Out-Null
        $enabled = [bool]$checkM.Invoke($null, @([string]$testKey, [string]$fakeExe))
        $stale = [bool]$checkM.Invoke($null, @([string]$testKey, 'C:\moved\elsewhere\Problip.exe'))
        $clearM.Invoke($null, @([string]$testKey)) | Out-Null
        $cleared = [bool]$checkM.Invoke($null, @([string]$testKey, [string]$fakeExe))
        Check 'Set writes the Run entry and IsEnabled confirms it' ($enabled -and -not $before) "before=$before enabled=$enabled"
        Check 'a stale Run entry pointing elsewhere is NOT reported enabled' (-not $stale)
        Check 'Clear removes the Run entry' (-not $cleared)
        # 8b. The mutation result is postcondition-verified: Set/Clear return
        #     whether the Run entry ACTUALLY names the requested executable (or
        #     is actually gone), not merely whether no exception was thrown.
        $setOk = [bool]$setM.Invoke($null, @([string]$testKey, [string]$fakeExe))
        $stillThere = [bool]$checkM.Invoke($null, @([string]$testKey, [string]$fakeExe))
        $clearOk = [bool]$clearM.Invoke($null, @([string]$testKey))
        $reallyGone = -not ([bool]$checkM.Invoke($null, @([string]$testKey, [string]$fakeExe)))
        Check 'Set returns the verified postcondition (true when written)' ($setOk -and $stillThere) "setOk=$setOk there=$stillThere"
        Check 'Clear returns the verified postcondition (true when gone)' ($clearOk -and $reallyGone) "clearOk=$clearOk gone=$reallyGone"
    }

    # ---- Preview and countdown preservation ----
    # The schedule is simulated, never slept on: NextDueMs is rewritten to a
    # point in the near future (as if part of the wait had elapsed), then the
    # operation under test must either preserve or intentionally redraw it.
        $previewM = $engineType.GetMethod('Preview')
        $nextDueField = $engineType.GetField('NextDueMs', $flags)
        $nowMsField = $engineType.GetField('NowMs', $flags)
        $playerField = $engineType.GetField('Player', $flags)
        # Statistics integration: the one successful-blip signal and its store.
        $statsField = $engineType.GetField('Stats', $flags)
        $statsType = $asm.GetType('Problip.BlipStatsStore', $true)
        $statsSnapM = $statsType.GetMethod('Snapshot')
        $statsLocalNowField = $statsType.GetField('LocalNow', $flags)
        $statsDay = [datetime]'2026-09-09'
        if ($null -eq $previewM -or $null -eq $nextDueField -or $null -eq $nowMsField) {
        Check 'the engine exposes Preview and schedule state' $false 'Preview/NextDueMs/NowMs missing'
    } else {
        $nowOf = { param($e) [long]$nowMsField.GetValue($e).Invoke() }

        # 9. Preview while OFF: plays through the preview path, stays OFF, the
        #    periodic timer remains stopped and never gets armed.
        $e9 = & $newEngine 4000 7000
        $t9 = & $timerOf $e9
        $ok9 = [bool]$previewM.Invoke($e9, @())
        Check 'Preview while OFF plays through the preview path' ($ok9 -and $e9.PreviewCount -eq 1) "ok=$ok9 previews=$($e9.PreviewCount)"
        Check 'Preview while OFF remains OFF' (-not $e9.IsOn) "on=$($e9.IsOn)"
        Check 'Preview while OFF leaves the timer stopped' (-not $t9.Enabled) "enabled=$($t9.Enabled)"

        # 10. Preview while ON: remains ON and the pending due time is NOT
        #     replaced by a fresh draw.
        $e10 = & $newEngine 30000 30000
        $t10 = & $timerOf $e10
        $e10.Start()
        $dueBefore = [long]$nextDueField.GetValue($e10)
        $nextDueField.SetValue($e10, [long]((& $nowOf $e10) + 5000))   # 25 s of a 30 s wait elapsed
        $dueSim = [long]$nextDueField.GetValue($e10)
        $ivBefore = [double]$t10.Interval
        $ok10 = [bool]$previewM.Invoke($e10, @())
        $dueAfter = [long]$nextDueField.GetValue($e10)
        Check 'Preview while ON plays and remains ON' ($ok10 -and $e10.IsOn -and $e10.PreviewCount -eq 1) "ok=$ok10 on=$($e10.IsOn)"
        Check 'Preview while ON keeps the timer running' ($t10.Enabled) "enabled=$($t10.Enabled)"
        Check 'Preview while ON does not replace the pending due time' ([Math]::Abs($dueAfter - $dueSim) -lt 150) "before=$dueSim after=$dueAfter"
        Check 'Preview while ON does not redraw the armed interval' ([Math]::Abs([double]$t10.Interval - $ivBefore) -lt 150) "ivBefore=$ivBefore after=$($t10.Interval)"

        # 11. Volume reload while ON preserves the remaining scheduled delay and
        #     does not take the fresh-NextDelay path (a 5000 ms remaining wait
        #     must not come back as a fresh 30000 ms draw).
        $e11 = & $newEngine 30000 30000
        $t11 = & $timerOf $e11
        $e11.Start()
        $nextDueField.SetValue($e11, [long]((& $nowOf $e11) + 5000))
        $dueSim11 = [long]$nextDueField.GetValue($e11)
        $e11.Reload()
        $dueAfter11 = [long]$nextDueField.GetValue($e11)
        Check 'a volume reload while ON stays ON' ($e11.IsOn -and $t11.Enabled) "on=$($e11.IsOn) enabled=$($t11.Enabled)"
        Check 'a volume reload while ON preserves the remaining delay' `
            ([Math]::Abs($dueAfter11 - $dueSim11) -lt 150) "before=$dueSim11 after=$dueAfter11"
        Check 'a volume reload while ON does not schedule a fresh full interval' `
            ([double]$t11.Interval -le 5150) "interval=$($t11.Interval) (fresh would be 30000)"

        # 12. Volume reload while OFF stays OFF and starts no timer.
        $e12 = & $newEngine 4000 7000
        $t12 = & $timerOf $e12
        $e12.Reload()
        Check 'a volume reload while OFF stays OFF' (-not $e12.IsOn) "on=$($e12.IsOn)"
        Check 'a volume reload while OFF does not start the timer' (-not $t12.Enabled) "enabled=$($t12.Enabled)"

        # 13. SetRange while ON STILL intentionally re-arms from the NEW range
        #     (the volume-preservation contract must not leak into interval
        #     changes). Covered by case 3 above; here the inverse direction:
        #     a long range re-draws a long wait, not the old short one.
        $e13 = & $newEngine 4000 7000
        $t13 = & $timerOf $e13
        $e13.Start()
        $e13.SetRange(30000, 30000)
        Check 'SetRange while ON re-arms from the new range (30 s, not the old wait)' `
            ($e13.IsOn -and [double]$t13.Interval -eq 30000) "interval=$($t13.Interval) on=$($e13.IsOn)"

        # 14. Start STILL draws a fresh configured interval (not a preserved one).
        $e14 = & $newEngine 30000 30000
        $t14 = & $timerOf $e14
        $nextDueField.SetValue($e14, [long]((& $nowOf $e14) + 100))   # stale schedule from an earlier session
        $e14.Start()
        Check 'Start arms a fresh configured interval, not the stale schedule' `
            ($e14.IsOn -and [double]$t14.Interval -eq 30000) "interval=$($t14.Interval) on=$($e14.IsOn)"

        # 15. A synchronous playback failure is truthful: PlayNow records the
        #     error, the engine reports broken, preview fails honestly, and a
        #     later preview after the asset recovers succeeds.
        $e15 = & $newEngine 4000 7000
        $t15 = & $timerOf $e15
        # Swap in a player whose backing file does not exist: SoundPlayer.Play
        # fails synchronously, exercising the real failure path (no mocks).
        $playerField.SetValue($e15, (New-Object System.Media.SoundPlayer (Join-Path $sandbox 'play-gone.wav')))
        $ok15 = [bool]$previewM.Invoke($e15, @())
        Check 'a synchronous playback failure reports failure' (-not $ok15) "ok=$ok15"
        Check 'a playback failure surfaces the broken/ERR state' ($e15.IsBroken -and $null -ne $e15.FailureText) "broken=$($e15.IsBroken)"
        Check 'a failed preview does not turn the engine ON' (-not $e15.IsOn -and -not $t15.Enabled) "on=$($e15.IsOn)"
        $ok15b = [bool]$previewM.Invoke($e15, @())
        Check 'a later preview after the asset recovers succeeds' ($ok15b -and -not $e15.IsBroken) "ok=$ok15b broken=$($e15.IsBroken)"

        # ---- P0 regression: the production monotonic clock ----
        # The defect: NowMs was `() => Stopwatch.StartNew().ElapsedMilliseconds`
        # -- a NEW Stopwatch per call read immediately, so production time was
        # permanently ~0, the first tick played, and every later tick was
        # suppressed (`now - LastPlayMs` never reached the interval). This
        # escaped the fake-clock tests because they replaced NowMs entirely.
        $tickM = $engineType.GetMethod('Tick', $flags)
        $playField = $engineType.GetField('Player', $flags)

        # 16. The DEFAULT production clock really advances: two reads ~40 ms
        #     apart must differ. This is the test that forbids
        #     Stopwatch.StartNew() inside NowMs from ever returning.
        $e16 = & $newEngine 4000 7000
        $t0 = [long]$nowMsField.GetValue($e16).Invoke()
        [System.Threading.Thread]::Sleep(40)
        $t1 = [long]$nowMsField.GetValue($e16).Invoke()
        Check 'the default production clock advances (t1 > t0 across ~40 ms)' ($t1 -gt $t0) "t0=$t0 t1=$t1"
        Check 'the default clock reads a plausible process uptime' ($t1 -ge 30) "t1=$t1"

        # 17. Deterministic periodic playback with the injectable clock: THREE
        #     sequential eligible ticks must each PLAY. The old failure mode
        #     (LastPlayMs stuck near zero) suppressed ticks 2..n forever, and
        #     the first version of this regression only asserted timer state --
        #     a Tick that re-armed without ever playing passed it. The oracle is
        #     now ScheduledPlayCount, incremented ONLY after a successful
        #     scheduled PlayNow() inside Tick (previews never touch it).
        #     The field is internal, so PS 5.1 dot syntax cannot see it: it is
        #     read through the same reflection flags as the other engine state.
        $scheduledField = $engineType.GetField('ScheduledPlayCount', $flags)
        if ($null -eq $scheduledField) {
            Check 'the engine exposes a scheduled-play observation seam' $false 'BlipEngine.ScheduledPlayCount missing'
        }
        $schedOf = { param($e) [int]$scheduledField.GetValue($e) }
        $e17 = & $newEngine 5000 5000
        $t17 = & $timerOf $e17
        $script:fakeNow17 = [long]1000
        $nowMsField.SetValue($e17, [Func[long]]{ param() $script:fakeNow17 })
        $e17.Start()
        $playField.SetValue($e17, (New-Object System.Media.SoundPlayer $wav))  # real playable asset, silent volume
        Check 'Start itself does not count as a scheduled play' ((& $schedOf $e17) -eq 0) "scheduled=$(if ($scheduledField) { & $schedOf $e17 } else { 'N/A' })"
        for ($i = 1; $i -le 3; $i++) {
            $script:fakeNow17 = 1000 + (5000 * $i)
            $tickM.Invoke($e17, @($null, [EventArgs]::Empty))
        }
        Check 'THREE due ticks reach exactly THREE successful scheduled plays' `
            ((& $schedOf $e17) -eq 3) "scheduled=$(if ($scheduledField) { & $schedOf $e17 } else { 'N/A' })"
        Check 'three sequential scheduled ticks each re-arm inside the range' `
            ($e17.IsOn -and [double]$t17.Interval -eq 5000) "interval=$($t17.Interval) on=$($e17.IsOn)"
        Check 'three sequential eligible ticks are never suppressed' `
            ($t17.Enabled -and $e17.IsOn) "timer=$($t17.Enabled)"
        Check 'no tick left the engine in an error state' (-not $e17.IsBroken) "broken=$($e17.IsBroken)"

        # 18. The broken-clock regression at the logic level: with the default
        #     production clock, consecutive reads NEVER collapse to a constant.
        #     (t1 > t0 in #16 is the direct oracle; this pins the mechanism --
        #     one Stopwatch lifetime -- by contract on the source.)
        $src18 = Get-Content -LiteralPath $Source -Raw
        Check 'NowMs has exactly one production Stopwatch lifetime (no per-call StartNew)' `
            ($src18 -match 'Stopwatch\.StartNew\(\);' -and $src18 -notmatch 'NowMs = \(\) => System\.Diagnostics\.Stopwatch\.StartNew\(\)')
        Check 'the clock field is a single readonly instance' `
            ($src18 -match 'readonly System\.Diagnostics\.Stopwatch Clock = System\.Diagnostics\.Stopwatch\.StartNew\(\);')

        # 19. START IDEMPOTENCY while healthy ON: clicking the already-selected
        #     ON button routes through Start(), which used to ArmTimer(NextDelay())
        #     unconditionally -- an already-active toggle that silently replaced
        #     the pending countdown with a fresh interval. The contract now:
        #     healthy ON + Start = scheduling no-op (no NextDueMs move, no
        #     interval redraw, no restart, no redundant notification).
        $e19 = & $newEngine 5000 5000
        $t19 = & $timerOf $e19
        $script:fakeNow19 = [long]1000
        $nowMsField.SetValue($e19, [Func[long]]{ param() $script:fakeNow19 })
        $e19.Start()                                                    # due = 1000+5000 = 6000
        $script:fakeNow19 = 3000                                        # partway through the wait
        $originalDue = [long]$nextDueField.GetValue($e19)
        $originalInterval = [double]$t19.Interval
        $notified19 = 0
        $handler19 = [EventHandler]{ param($o, $ea) $script:notified19++ }
        $e19.add_StateChanged($handler19)
        try { $e19.Start() } finally { $e19.remove_StateChanged($handler19) }
        Check 'Start while already healthy ON remains ON with the timer running' `
            ($e19.IsOn -and $t19.Enabled) "on=$($e19.IsOn) timer=$($t19.Enabled)"
        Check 'Start while already healthy ON does not move NextDueMs' `
            ([long]$nextDueField.GetValue($e19) -eq $originalDue) "due=$([long]$nextDueField.GetValue($e19)) original=$originalDue"
        Check 'Start while already healthy ON does not redraw Timer.Interval' `
            ([double]$t19.Interval -eq $originalInterval) "interval=$($t19.Interval) original=$originalInterval"
        Check 'Start while already healthy ON fires no redundant state notification' `
            ($notified19 -eq 0) "notified=$notified19"

        # 20. PREVIEW vs SCHEDULE, with the play oracle available: a preview
        #     immediately before the due tick must neither move the due time nor
        #     suppress that tick -- exactly one scheduled play follows.
        $e20 = & $newEngine 5000 5000
        $t20 = & $timerOf $e20
        $script:fakeNow20 = [long]1000
        $nowMsField.SetValue($e20, [Func[long]]{ param() $script:fakeNow20 })
        $e20.Start()
        $dueBefore20 = [long]$nextDueField.GetValue($e20)
        $ok20 = [bool]$previewM.Invoke($e20, @())
        $dueAfter20 = [long]$nextDueField.GetValue($e20)
        Check 'a preview right before the due tick plays through the preview path' `
            ($ok20 -and $e20.PreviewCount -eq 1) "ok=$ok20 previews=$($e20.PreviewCount)"
        Check 'a preview right before the due tick leaves the pending due unchanged' `
            ($dueAfter20 -eq $dueBefore20) "due=$dueAfter20 original=$dueBefore20"
        Check 'a preview never counts as a scheduled play' ((& $schedOf $e20) -eq 0) "scheduled=$(if ($scheduledField) { & $schedOf $e20 } else { 'N/A' })"
        $script:fakeNow20 = 1000 + 5000
        $tickM.Invoke($e20, @($null, [EventArgs]::Empty))
        Check 'the preview does not suppress the immediately following due tick' `
            ((& $schedOf $e20) -eq 1) "scheduled=$(if ($scheduledField) { & $schedOf $e20 } else { 'N/A' })"
        Check 'the post-preview tick still leaves the engine ON and armed' `
            ($e20.IsOn -and $t20.Enabled) "on=$($e20.IsOn) timer=$($t20.Enabled)"

        # ---- 21-24: the ONE successful-blip signal and its statistics ----
        # BlipPlayed is raised only after a scheduled Tick's PlayNow() succeeds.
        # Preview/TEST/failed playback never raise it; the statistics store
        # tracks the same successes, so the two must stay aligned.
        $e21 = & $newEngine 5000 5000
        $t21 = & $timerOf $e21
        $script:fakeNow21 = [long]1000
        $nowMsField.SetValue($e21, [Func[long]]{ param() $script:fakeNow21 })
        $st21 = $statsField.GetValue($e21)
        $statsLocalNowField.SetValue($st21, [Func[datetime]]{ param() $statsDay })
        $e21.Start()
        $playField.SetValue($e21, (New-Object System.Media.SoundPlayer $wav))
        $script:fired21 = 0
        $h21 = [EventHandler]{ param($o, $ea) $script:fired21++ }
        $e21.add_BlipPlayed($h21)
        $script:fakeNow21 = 6000
        $tickM.Invoke($e21, @($null, [EventArgs]::Empty))
        $e21.remove_BlipPlayed($h21)
        $snap21 = $statsSnapM.Invoke($st21, @())
        Check 'a successful scheduled tick raises BlipPlayed exactly once' ($fired21 -eq 1) "fired=$fired21"
        Check 'a successful scheduled tick increments the statistics total' ($snap21.Total -eq 1) "total=$($snap21.Total)"
        Check 'a scheduled success keeps ScheduledPlayCount and statistics aligned' `
            ((& $schedOf $e21) -eq $snap21.Total) "scheduled=$(& $schedOf $e21) total=$($snap21.Total)"

        # Preview (the TEST/tray-Test API) must not raise BlipPlayed or count.
        $script:fired22 = 0
        $h22 = [EventHandler]{ param($o, $ea) $script:fired22++ }
        $e21.add_BlipPlayed($h22)
        $ok22 = [bool]$previewM.Invoke($e21, @())
        $e21.remove_BlipPlayed($h22)
        $snap22 = $statsSnapM.Invoke($st21, @())
        Check 'Preview plays but raises no BlipPlayed' ($ok22 -and $fired22 -eq 0) "ok=$ok22 fired=$fired22"
        Check 'Preview leaves the statistics total unchanged' ($snap22.Total -eq 1) "total=$($snap22.Total)"

        # A failed scheduled playback must not raise BlipPlayed or count.
        $playerField.SetValue($e21, (New-Object System.Media.SoundPlayer (Join-Path $sandbox 'sched-gone.wav')))
        $script:fakeNow21 = 12000
        $script:fired23 = 0
        $h23 = [EventHandler]{ param($o, $ea) $script:fired23++ }
        $e21.add_BlipPlayed($h23)
        $tickM.Invoke($e21, @($null, [EventArgs]::Empty))
        $e21.remove_BlipPlayed($h23)
        $snap23 = $statsSnapM.Invoke($st21, @())
        Check 'a failed scheduled playback raises no BlipPlayed' ($fired23 -eq 0) "fired=$fired23"
        Check 'a failed scheduled playback leaves the statistics total unchanged' ($snap23.Total -eq 1) "total=$($snap23.Total)"

        # Three successful deterministic ticks: Total +3, three events.
        $e24 = & $newEngine 5000 5000
        $script:fakeNow24 = [long]1000
        $nowMsField.SetValue($e24, [Func[long]]{ param() $script:fakeNow24 })
        $st24 = $statsField.GetValue($e24)
        $statsLocalNowField.SetValue($st24, [Func[datetime]]{ param() $statsDay })
        $e24.Start()
        $playField.SetValue($e24, (New-Object System.Media.SoundPlayer $wav))
        $script:fired24 = 0
        $h24 = [EventHandler]{ param($o, $ea) $script:fired24++ }
        $e24.add_BlipPlayed($h24)
        for ($i = 1; $i -le 3; $i++) {
            $script:fakeNow24 = 1000 + (5000 * $i)
            $tickM.Invoke($e24, @($null, [EventArgs]::Empty))
        }
        $e24.remove_BlipPlayed($h24)
        $snap24 = $statsSnapM.Invoke($st24, @())
        Check 'three successful scheduled ticks increment statistics by exactly 3' `
            ($snap24.Total -eq 3) "total=$($snap24.Total)"
        Check 'BlipPlayed fires once per successful scheduled tick (three total)' ($fired24 -eq 3) "fired=$fired24"
        Check 'ScheduledPlayCount and statistics remain aligned over three ticks' `
            ((& $schedOf $e24) -eq $snap24.Total) "scheduled=$(& $schedOf $e24) total=$($snap24.Total)"
    }
} finally {
    foreach ($e in $engines) { try { $e.Cleanup() } catch { } }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    if ($testKey) {
        Remove-Item -LiteralPath ("HKCU:\$testKey") -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Source contracts the wave names explicitly: the tray menu must expose a
# Test blip action placed near Start/Stop, wired to the same Preview API, and
# the volume commit must preview exactly once on a successful release.
$menuSrc = Get-Content -LiteralPath $Source -Raw
$testIdx = $menuSrc.IndexOf('"Test blip"')
$startIdx = $menuSrc.IndexOf('"Start", null')
$stopIdx = $menuSrc.IndexOf('"Stop", null')
Check 'the tray menu exposes a Test blip action' ($testIdx -ge 0)
Check 'Test blip sits with Start/Stop in the menu' `
    ($testIdx -ge 0 -and $startIdx -gt $testIdx -and $stopIdx -gt $testIdx)
Check 'Test blip is wired to Engine.Preview()' `
    ($testIdx -ge 0 -and $menuSrc.Substring($testIdx, [Math]::Min(300, $menuSrc.Length - $testIdx)) -match 'engine\.Preview\(\)')

Write-Host '---'
if ($fails) { Write-Host "FAILED ($fails failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0

