$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled variable must FAIL the harness
# immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$RealWav = Join-Path $root 'blip01.wav'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_runstate_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

# Runtime truth + remembered run preference (ROLE_20260908_2150 wave):
#   - a scheduled playback failure stops periodic scheduling and surfaces ERR
#     (never a fake healthy ON), with no new interval armed;
#   - an explicit Start after the asset is repaired recovers to ON;
#   - a failed Preview while ON is a health transition: ERR + timer stopped,
#     and the remembered RunOnLaunch preference is NOT rewritten to 0;
#   - StateChanged fires on meaningful transitions, not harmless ticks;
#   - RunOnLaunch defaults true (old INIs keep current behavior), round-trips,
#     is honored at startup, and is independent of AutoStart;
#   - Start/Stop commands persist the preference when writable and still apply
#     for the session when the INI is unwritable (reported, not rolled back);
#   - the volume-reload re-arm consumes rebuild time from the ABSOLUTE due
#     time (simulated 1000 ms rebuild -> ~4000 ms re-armed, never 5000).
# Deterministic throughout: the fake clock + BuildDelaySim seam replaces real
# sleeping; no test touches the real user's INI.

try {
    $dll = Join-Path $work 'Problip.dll'
    $failSrc = Join-Path $work 'FailSettings.cs'
    Set-Content -LiteralPath $failSrc -Value @'
using System.Collections.Generic;
namespace Problip {
    class FailSettings : Settings {
        public List<string> FailKeys;
        public FailSettings(string dir) : base(dir) { FailKeys = new List<string>(); }
        public override void Save(string key, string val) {
            if (FailKeys != null && FailKeys.Contains(key))
                throw new System.IO.IOException("simulated write failure: " + key);
            base.Save(key, val);
        }
    }
}
'@
    & $csc -nologo -target:library "-out:$dll" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs') $failSrc | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Problip.cs compilation failed' }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))

    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $runStateType = $asm.GetType('Problip.RunState', $true)
    $formType = $asm.GetType('Problip.ProblipForm', $true)
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $failCtor = $asm.GetType('Problip.FailSettings', $true).GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $loadMethod = $settingsType.GetMethod('Load')
    $applyLaunch = $runStateType.GetMethod('ApplyLaunch')
    $requestStart = $runStateType.GetMethod('RequestStart')
    $requestStop = $runStateType.GetMethod('RequestStop')
    $sinkField = $runStateType.GetField('PersistenceErrorSink', $staticFlags)
    $tickMethod = $engineType.GetMethod('Tick', $flags)
    $timerOf = { param($e) [System.Windows.Forms.Timer]$engineType.GetField('Timer', $flags).GetValue($e) }
    $nowMsField = $engineType.GetField('NowMs', $flags)
    $stallField = $engineType.GetField('BuildDelaySim', $flags)
    $nextDueField = $engineType.GetField('NextDueMs', $flags)
    $playerField = $engineType.GetField('Player', $flags)

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

    $engines = @()
    $newEngine = {
        param([string]$wav, [string]$minMs = '4000', [string]$maxMs = '7000', [System.Collections.Generic.List[string]]$failKeys = $null)
        $dir = Join-Path $work ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        if ($failKeys -ne $null) { $s = $failCtor.Invoke(@([string]$dir)); $s.FailKeys = $failKeys }
        else { $s = $settingsCtor.Invoke(@([string]$dir)) }
        $loadMethod.Invoke($s, @()) | Out-Null   # real flow: Load() writes the fresh INI
        $s.WavPath = [string]$wav
        $s.Volume = 0.0   # scaled cache is silence: real code path, no audible output
        $s.MinMs = [int]$minMs; $s.MaxMs = [int]$maxMs
        $e = $engineCtor.Invoke(@($s))
        $script:engines += $e
        return @{ S = $s; E = $e; Dir = $dir }
    }
    $goodWav = Join-Path $work 'good.wav'
    New-Wav $goodWav

    # ---- §17: scheduled playback failure must leave ON ----
    # A. The engine is ON with a healthy schedule; the player is swapped for one
    #    whose backing file is gone (SoundPlayer.Play fails synchronously). One
    #    Tick: no re-arm, timer stopped, no healthy ON claim, ERR observable.
    $rA = & $newEngine $goodWav 5000 5000
    $eA = $rA.E; $tA = & $timerOf $eA
    $eA.Start()
    $dueA = [long]$nextDueField.GetValue($eA)
    $playerField.SetValue($eA, (New-Object System.Media.SoundPlayer (Join-Path $work 'tick-gone.wav')))
    $tickMethod.Invoke($eA, @($null, [EventArgs]::Empty))
    Check 'a scheduled playback failure leaves the engine not-ON' (-not $eA.IsOn) "on=$($eA.IsOn)"
    Check 'a scheduled playback failure stops the periodic timer' (-not $tA.Enabled) "timer=$($tA.Enabled)"
    Check 'a scheduled playback failure surfaces ERR (Player unavailable + reason)' `
        ($eA.IsBroken -and $null -ne $eA.FailureText) "broken=$($eA.IsBroken) failure=$($eA.FailureText)"
    Check 'a scheduled playback failure arms no new interval' `
        ([long]$nextDueField.GetValue($eA) -eq $dueA) "due unchanged: $dueA"

    # B. The asset is repaired; one explicit Start recovers to ON with a timer.
    $eA2 = $rA.E; $tA2 = & $timerOf $eA2
    $eA2.Start()
    Check 'a later Start after the repair recovers to ON' `
        ($eA2.IsOn -and -not $eA2.IsBroken -and $tA2.Enabled) "on=$($eA2.IsOn) broken=$($eA2.IsBroken) timer=$($tA2.Enabled)"
    Check 'the recovered timer is armed inside the range' `
        ([double]$tA2.Interval -ge 5000 -and [double]$tA2.Interval -le 5000) "interval=$($tA2.Interval)"

    # C. A failed Preview while ON: ERR, timer not left running, and the
    #    remembered run preference is NOT changed by a health failure.
    $rC = & $newEngine $goodWav 30000 30000
    $eC = $rC.E; $tC = & $timerOf $eC; $sC = $rC.S
    $eC.Start()
    $playerField.SetValue($eC, (New-Object System.Media.SoundPlayer (Join-Path $work 'preview-gone.wav')))
    $okC = [bool]$engineType.GetMethod('Preview').Invoke($eC, @())
    Check 'a failed Preview while ON reports failure' (-not $okC) "ok=$okC"
    Check 'a failed Preview while ON surfaces ERR' ($eC.IsBroken -and -not $eC.IsOn) "broken=$($eC.IsBroken) on=$($eC.IsOn)"
    Check 'a failed Preview while ON does not leave the timer pretending to run' (-not $tC.Enabled) "timer=$($tC.Enabled)"
    $iniC = Get-Content -LiteralPath (Join-Path $rC.Dir 'problip.ini') -Raw
    Check 'a failed Preview does not rewrite the run preference to 0' `
        (($sC.RunOnLaunch -eq $true) -and ($iniC -match 'RunOnLaunch=1')) "pref=$($sC.RunOnLaunch)"

    # D. StateChanged: fires on meaningful transitions, silent on harmless ticks.
    $rD = & $newEngine $goodWav 5000 5000
    $eD = $rD.E; $tD = & $timerOf $eD
    $fired = 0
    $handler = [EventHandler]{ param($o, $ea) $script:fired++ }
    $eD.add_StateChanged($handler)
    $eD.Start()                                                        # OFF -> ON
    $afterStart = $fired
    $tickMethod.Invoke($eD, @($null, [EventArgs]::Empty))              # healthy tick: nothing observable
    $afterTick = $fired
    # The 300 ms play debounce is gone (intervals are >= 1 s and WinForms
    # never re-enters Tick); the swapped-in dead player is exercised directly.
    $playerField.SetValue($eD, (New-Object System.Media.SoundPlayer (Join-Path $work 'state-gone.wav')))
    $tickMethod.Invoke($eD, @($null, [EventArgs]::Empty))              # scheduled failure: ON -> ERR
    $afterFail = $fired
    $eD.Stop()                                                          # ERR -> OFF (no transition to ON)
    $afterStop = $fired
    Check 'StateChanged fires on a successful Start' ($afterStart -eq 1) "fired=$afterStart"
    Check 'StateChanged stays silent on a harmless healthy tick' ($afterTick -eq $afterStart) "fired=$afterTick"
    Check 'StateChanged fires on a scheduled playback failure without a UI click' ($afterFail -eq $afterStart + 1) "fired=$afterFail"
    Check 'StateChanged fires on Stop' ($afterStop -eq $afterFail + 1) "fired=$afterStop"
    $eD.remove_StateChanged($handler)

    # ---- §18: remembered run preference ----
    # A. Fresh settings: default true, and the fresh INI writes RunOnLaunch=1.
    $dirA2 = Join-Path $work 'fresh'; New-Item -ItemType Directory -Path $dirA2 | Out-Null
    $sFresh = $settingsCtor.Invoke(@([string]$dirA2))
    $loadMethod.Invoke($sFresh, @()) | Out-Null
    Check 'fresh settings default RunOnLaunch to true' ($sFresh.RunOnLaunch -eq $true) "pref=$($sFresh.RunOnLaunch)"
    $iniFresh = Get-Content -LiteralPath (Join-Path $dirA2 'problip.ini') -Raw
    Check 'the fresh INI stores RunOnLaunch=1' ($iniFresh -match 'RunOnLaunch=1') $iniFresh.Trim()

    # B. An old INI without the key keeps current behavior: ON.
    $dirB = Join-Path $work 'old'; New-Item -ItemType Directory -Path $dirB | Out-Null
    Set-Content -LiteralPath (Join-Path $dirB 'problip.ini') -Value "[problip]`r`nVolume=0.10`r`nAutoStart=0"
    $sOld = $settingsCtor.Invoke(@([string]$dirB))
    $loadMethod.Invoke($sOld, @()) | Out-Null
    Check 'an old INI without RunOnLaunch defaults to true' ($sOld.RunOnLaunch -eq $true) "pref=$($sOld.RunOnLaunch)"

    # B2. A malformed value also keeps the ON default.
    $dirB2 = Join-Path $work 'junk'; New-Item -ItemType Directory -Path $dirB2 | Out-Null
    Set-Content -LiteralPath (Join-Path $dirB2 'problip.ini') -Value "[problip]`r`nRunOnLaunch=junk"
    $sJunk = $settingsCtor.Invoke(@([string]$dirB2))
    $loadMethod.Invoke($sJunk, @()) | Out-Null
    Check 'a malformed RunOnLaunch value defaults to true' ($sJunk.RunOnLaunch -eq $true) "pref=$($sJunk.RunOnLaunch)"

    # C. RunOnLaunch=0 round trip: persisted 0 reloads as false.
    $dirC2 = Join-Path $work 'zero'; New-Item -ItemType Directory -Path $dirC2 | Out-Null
    Set-Content -LiteralPath (Join-Path $dirC2 'problip.ini') -Value "[problip]`r`nRunOnLaunch=0"
    $sZero = $settingsCtor.Invoke(@([string]$dirC2))
    $loadMethod.Invoke($sZero, @()) | Out-Null
    Check 'RunOnLaunch=0 round-trips to false' ($sZero.RunOnLaunch -eq $false) "pref=$($sZero.RunOnLaunch)"

    # D/E. Startup projection drives the exact ApplyLaunch branch Main uses.
    $rD2 = & $newEngine $goodWav
    $rD2.S.RunOnLaunch = $false
    $applyLaunch.Invoke($null, @($rD2.S, $rD2.E)) | Out-Null
    $tD2 = & $timerOf $rD2.E
    Check 'startup projection: RunOnLaunch=0 keeps the engine OFF' `
        (-not $rD2.E.IsOn -and -not $tD2.Enabled) "on=$($rD2.E.IsOn) timer=$($tD2.Enabled)"
    Check 'a paused launch still previews and opens settings' `
        ([bool]$engineType.GetMethod('Preview').Invoke($rD2.E, @()) -and -not $rD2.E.IsOn) "on=$($rD2.E.IsOn)"
    $rE = & $newEngine $goodWav
    $applyLaunch.Invoke($null, @($rE.S, $rE.E)) | Out-Null
    Check 'startup projection: RunOnLaunch=1 attempts Start' `
        ($rE.E.IsOn -and (& $timerOf $rE.E).Enabled) "on=$($rE.E.IsOn)"

    # F. AutoStart and RunOnLaunch are independent (all four states are legal).
    $combos = @(
        @{ AutoStart = '1'; RunOnLaunch = '1' },
        @{ AutoStart = '1'; RunOnLaunch = '0' },
        @{ AutoStart = '0'; RunOnLaunch = '1' },
        @{ AutoStart = '0'; RunOnLaunch = '0' }
    )
    $comboOk = $true
    foreach ($c in $combos) {
        $d = Join-Path $work ('combo_' + $c.AutoStart + $c.RunOnLaunch)
        New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'problip.ini') -Value "[problip]`r`nAutoStart=$($c.AutoStart)`r`nRunOnLaunch=$($c.RunOnLaunch)"
        $s = $settingsCtor.Invoke(@([string]$d))
        $loadMethod.Invoke($s, @()) | Out-Null
        if ($s.AutoStart -ne ($c.AutoStart -eq '1') -or $s.RunOnLaunch -ne ($c.RunOnLaunch -eq '1')) { $comboOk = $false }
    }
    Check 'AutoStart and RunOnLaunch load independently across all four combinations' $comboOk

    # G. User Stop via the shared command seam: stops immediately and persists 0.
    $rG = & $newEngine $goodWav
    $eG = $rG.E; $sG = $rG.S
    $eG.Start()
    $noticesG = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($null, [System.Action[string]]{ param($m) $noticesG.Add($m) })
    $requestStop.Invoke($null, @($sG, $eG))
    Check 'a user Stop stops the engine immediately' (-not $eG.IsOn -and -not (& $timerOf $eG).Enabled) "on=$($eG.IsOn)"
    Check 'a user Stop persists RunOnLaunch=0 when writable' `
        (($sG.RunOnLaunch -eq $false) -and ((Get-Content -LiteralPath (Join-Path $rG.Dir 'problip.ini') -Raw) -match 'RunOnLaunch=0')) "pref=$($sG.RunOnLaunch)"
    Check 'a user Stop on a writable INI reports nothing' ($noticesG.Count -eq 0) "notices=$($noticesG.Count)"

    # H. User Start via the seam: starts and persists 1.
    $rH = & $newEngine $goodWav
    $eH = $rH.E; $sH = $rH.S
    $noticesH = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($null, [System.Action[string]]{ param($m) $noticesH.Add($m) })
    $requestStart.Invoke($null, @($sH, $eH))
    Check 'a user Start starts the engine' ($eH.IsOn -and (& $timerOf $eH).Enabled) "on=$($eH.IsOn)"
    Check 'a user Start persists RunOnLaunch=1 when writable' `
        (($sH.RunOnLaunch -eq $true) -and ((Get-Content -LiteralPath (Join-Path $rH.Dir 'problip.ini') -Raw) -match 'RunOnLaunch=1')) "pref=$($sH.RunOnLaunch)"
    Check 'a user Start on a writable INI reports nothing' ($noticesH.Count -eq 0) "notices=$($noticesH.Count)"

    # H2. Start is a recovery attempt on a broken asset: ERR, never fake ON,
    #     and the preference is still remembered as the user's ON intent.
    $rH2 = & $newEngine (Join-Path $work 'still-broken.wav')
    $eH2 = $rH2.E; $sH2 = $rH2.S
    $sinkField.SetValue($null, [System.Action[string]]{ param($m) })
    $requestStart.Invoke($null, @($sH2, $eH2))
    Check 'a user Start on a broken asset lands in ERR, not fake ON' `
        ($eH2.IsBroken -and -not $eH2.IsOn -and -not (& $timerOf $eH2).Enabled) "broken=$($eH2.IsBroken) on=$($eH2.IsOn)"
    Check 'a user Start on a broken asset still remembers the ON intent' `
        (($sH2.RunOnLaunch -eq $true) -and ((Get-Content -LiteralPath (Join-Path $rH2.Dir 'problip.ini') -Raw) -match 'RunOnLaunch=1')) "pref=$($sH2.RunOnLaunch)"

    # H3. Start IDEMPOTENCY through the shared command seam: RequestStart while
    #     already healthy ON persists the preference but must NOT move the
    #     pending cadence -- the engine-level no-op makes the ON button (always
    #     an active hot zone) safe to re-click mid-wait.
    $rH3 = & $newEngine $goodWav 5000 5000
    $eH3 = $rH3.E; $sH3 = $rH3.S
    $script:fakeNowH3 = [long]($nowMsField.GetValue($eH3).Invoke())
    $nowMsField.SetValue($eH3, [Func[long]]{ param() $script:fakeNowH3 })
    $eH3.Start()                                                 # due = now + 5000
    $script:fakeNowH3 = $script:fakeNowH3 + 2000                 # partway through the wait
    $dueBeforeH3 = [long]$nextDueField.GetValue($eH3)
    $ivBeforeH3 = [double](& $timerOf $eH3).Interval
    $noticesH3 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($null, [System.Action[string]]{ param($m) $noticesH3.Add($m) })
    $requestStart.Invoke($null, @($sH3, $eH3))
    Check 'RequestStart while already ON stays ON with the timer running' `
        ($eH3.IsOn -and (& $timerOf $eH3).Enabled) "on=$($eH3.IsOn)"
    Check 'RequestStart while already ON does not move the due schedule' `
        ([long]$nextDueField.GetValue($eH3) -eq $dueBeforeH3) "due=$([long]$nextDueField.GetValue($eH3)) original=$dueBeforeH3"
    Check 'RequestStart while already ON does not redraw the armed interval' `
        ([double](& $timerOf $eH3).Interval -eq $ivBeforeH3) "interval=$((& $timerOf $eH3).Interval) original=$ivBeforeH3"
    Check 'RequestStart while already ON persists RunOnLaunch=1 when writable' `
        (($sH3.RunOnLaunch -eq $true) -and ((Get-Content -LiteralPath (Join-Path $rH3.Dir 'problip.ini') -Raw) -match 'RunOnLaunch=1')) "pref=$($sH3.RunOnLaunch)"
    Check 'RequestStart while already ON reports nothing on a writable INI' ($noticesH3.Count -eq 0) "notices=$($noticesH3.Count)"
    # ERR recovery is untouched by the idempotency rule: a Start on a broken
    # engine must still attempt the rebuild and land ON when repaired.
    $rH4 = & $newEngine (Join-Path $work 'idem-broken.wav') 5000 5000
    $eH4 = $rH4.E
    $requestStart.Invoke($null, @($rH4.S, $eH4))
    Check 'RequestStart on a broken asset still lands in ERR (no fake ON)' `
        ($eH4.IsBroken -and -not $eH4.IsOn) "broken=$($eH4.IsBroken) on=$($eH4.IsOn)"
    Copy-Item -LiteralPath $goodWav -Destination (Join-Path $work 'idem-broken.wav') -Force
    $requestStart.Invoke($null, @($rH4.S, $eH4))
    Check 'RequestStart after the WAV repair still recovers to ON with a fresh interval' `
        ($eH4.IsOn -and -not $eH4.IsBroken -and (& $timerOf $eH4).Enabled) "on=$($eH4.IsOn) broken=$($eH4.IsBroken)"

    # I. Persistence failure: the session action STILL applies, the field
    #    carries the session intent, the failure is observable, no crash.
    $rI = & $newEngine $goodWav -failKeys ([System.Collections.Generic.List[string]]@('RunOnLaunch'))
    $eI = $rI.E; $sI = $rI.S
    $eI.Start()
    $noticesI = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($null, [System.Action[string]]{ param($m) $noticesI.Add($m) })
    $requestStop.Invoke($null, @($sI, $eI))
    Check 'a failed-persist Stop still stops the engine for this session' `
        (-not $eI.IsOn -and -not (& $timerOf $eI).Enabled) "on=$($eI.IsOn)"
    Check 'the preference field carries the session OFF intent after a failed persist' ($sI.RunOnLaunch -eq $false) "pref=$($sI.RunOnLaunch)"
    Check 'a failed-persist Stop is observable through the error sink' ($noticesI.Count -eq 1 -and $noticesI[0] -match 'OFF') "notices=$($noticesI -join ' | ')"
    $requestStart.Invoke($null, @($sI, $eI))
    Check 'a failed-persist Start still starts the engine for this session' ($eI.IsOn) "on=$($eI.IsOn)"
    Check 'the preference field carries the session ON intent after a failed persist' ($sI.RunOnLaunch -eq $true) "pref=$($sI.RunOnLaunch)"
    Check 'a failed-persist Start is observable through the error sink' ($noticesI.Count -eq 2 -and $noticesI[1] -match 'ON') "notices=$($noticesI -join ' | ')"

    # ---- §19: exact-due reload — the rebuild consumes countdown time ----
    # Deterministic: fake clock now=T; due=T+5000; the simulated rebuild
    # advances the fake clock by 1000; the re-armed wait must be 4000 (the
    # ORIGINAL absolute due time is kept), never 5000.
    $rR = & $newEngine $goodWav 30000 30000
    $eR = $rR.E; $tR = & $timerOf $eR
    $eR.Start()
    $script:fakeNow = [long]($nowMsField.GetValue($eR).Invoke())
    $nowMsField.SetValue($eR, [Func[long]]{ param() $script:fakeNow })
    $dueR = $script:fakeNow + 5000
    $nextDueField.SetValue($eR, [long]$dueR)
    $stallField.SetValue($eR, [Action]{ param() $script:fakeNow += 1000 })
    $eR.Reload()
    $ivR = [double]$tR.Interval
    $dueAfterR = [long]$nextDueField.GetValue($eR)
    Check 'the re-armed wait consumes the simulated rebuild time (4000, not 5000)' `
        ($ivR -ge 3900 -and $ivR -le 4100) "interval=$ivR (5000 would mean the rebuild extended the wait)"
    Check 'the reload keeps the ORIGINAL absolute due time' `
        ($dueAfterR -eq $dueR) "due=$dueAfterR expected=$dueR"
    Check 'the reload while ON stays ON with a running timer' ($eR.IsOn -and $tR.Enabled) "on=$($eR.IsOn) timer=$($tR.Enabled)"

    # A slow rebuild never schedules past the old due point: fake clock at
    # T+1000, remaining 4000 -> armed NextDue = T+1000+4000 = T+5000 exactly.
    $stallField.SetValue($eR, $null)
    $nowMsField.SetValue($eR, $nowMsField.GetValue($eR))  # keep the fake for the rest of this engine's life

    # ---- source contracts the wave names explicitly ----
    $src = Get-Content -LiteralPath (Join-Path $root 'Problip.cs') -Raw
    Check 'Program gates startup on the remembered preference via RunState' `
        ($src -match 'RunState\.ApplyLaunch\(s, engine\)' -and $src -match 'if \(s\.RunOnLaunch\) engine\.Start\(\);')
    Check 'the tray holds Start/Stop references and follows runtime state' `
        ($src -match 'miStart\.Enabled' -and $src -match 'miStop\.Enabled' -and $src -match 'engine\.StateChanged \+=')
    Check 'the tray caption is the explicit ON/OFF/ERR state' `
        ($src -match '"problip — " \+ StateText')
    Check 'the settings ON/OFF buttons reflect actual state (ERR selects neither)' `
        ($src -match 'DrawButton\(g, sr, "ON", runOn\)' -and $src -match 'DrawButton\(g, pr, "OFF", !Engine\.IsBroken && !Engine\.IsOn\)')
    Check 'both UI surfaces share one Start/Stop command seam' `
        ($src -match 'RunState\.RequestStart\(S, Engine\)' -and $src -match 'RunState\.RequestStop\(S, Engine\)' -and
         $src -match 'RunState\.RequestStart\(s, engine\)' -and $src -match 'RunState\.RequestStop\(s, engine\)')
    Check 'the reload arms from the captured due time, not a pre-build remaining' `
        ($src -match 'long due = NextDueMs;' -and $src -match 'long remaining = due - NowMs\(\);')
} finally {
    foreach ($r in $engines) { try { $r.E.Cleanup() } catch { } }
    try { $sinkField.SetValue($null, $null) } catch { }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
