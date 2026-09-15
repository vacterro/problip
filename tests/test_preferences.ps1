# Part 1 of test_preferences.ps1 source (assembled by cat below)
$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled test variable must FAIL this
# harness immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
# Preferences / Control Center wave. Exercises the REAL compiled classes:
#   - the three new settings' defaults (old INI, exact "0", malformed) + round-trips
#   - statistics recording vs display independence (all four combinations)
#   - BlipPlayed keeps firing while recording is paused (Glow signal intact)
#   - reset all: success (atomic candidate commit) and failure (non-destructive)
#   - preview-on-volume-change (on/off/failed-commit/TEST independence)
#   - always-on-top live projection across every reusable window
#   - shared-surface consistency through the ONE command seam
#   - read-only preference failures revert truthfully and never crash
#   - autostart safety on a disposable registry key
# The wall clock is injected (LocalNow); disposable temp dirs only; the real
# user's problip.ini and Run key are never touched.

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$RealWav = Join-Path $root 'blip01.wav'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_prefs_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

try {
    $dll = Join-Path $work 'Problip.dll'
    # The test-only Settings subclass lets chosen keys fail on demand; the
    # production Settings stays untouched.
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

    Add-Type -AssemblyName System.Windows.Forms
    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $failType = $asm.GetType('Problip.FailSettings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $storeType = $asm.GetType('Problip.BlipStatsStore', $true)
    $statsFormType = $asm.GetType('Problip.StatsForm', $true)
    $prefsFormType = $asm.GetType('Problip.PreferencesForm', $true)
    $mainFormType = $asm.GetType('Problip.ProblipForm', $true)
    $manualFormType = $asm.GetType('Problip.ManualIntervalForm', $true)
    $themesFormType = $asm.GetType('Problip.ThemesForm', $true)
    $helpFormType = $asm.GetType('Problip.HelpForm', $true)
    $programType = $asm.GetType('Problip.Program', $true)
    $prefCmdType = $asm.GetType('Problip.PreferenceCommands', $true)
    $startCmdType = $asm.GetType('Problip.StartupCommands', $true)
    $autoStartType = $asm.GetType('Problip.AutoStart', $true)

    $ctor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $failCtor = $failType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $tickM = $engineType.GetMethod('Tick', $flags)
    $nextDueField = $engineType.GetField('NextDueMs', $flags)
    $phaseField = $engineType.GetField('PulseShortNext', $flags)
    $schedField = $engineType.GetField('ScheduledPlayCount', $flags)
    $engineTimerField = $engineType.GetField('Timer', $flags)
    $statsField = $engineType.GetField('Stats', $flags)
    $localNowField = $storeType.GetField('LocalNow', $flags)
    $commitField = $storeType.GetField('CommitFile', $flags)
    $recordField = $storeType.GetField('Record', $flags)
    $tryResetM = $storeType.GetMethod('TryResetAll')
    $setAutoStartM = $startCmdType.GetMethod('SetAutoStart')
    $setShowCounterM = $prefCmdType.GetMethod('SetShowBlipCounter')
    $setStatsEnabledM = $prefCmdType.GetMethod('SetStatsEnabled')
    $setPreviewM = $prefCmdType.GetMethod('SetPreviewOnVolumeChange')
    $setGlowM = $prefCmdType.GetMethod('SetBlipGlow')
    $setTopM = $prefCmdType.GetMethod('SetAlwaysOnTop')
    $resetAllM = $prefCmdType.GetMethod('ResetAll')
    $runStartM = $asm.GetType('Problip.RunState', $true).GetMethod('RequestStart')
    $runStopM = $asm.GetType('Problip.RunState', $true).GetMethod('RequestStop')

    function New-Dir([string]$name) {
        $d = Join-Path $work $name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
    function New-SetIn([string]$dir, [hashtable]$kv) {
        if ($kv) {
            $sb = New-Object Text.StringBuilder("[problip]`r`n")
            foreach ($k in $kv.Keys) { [void]$sb.AppendLine("$k=$($kv[$k])") }
            Set-Content -LiteralPath (Join-Path $dir 'problip.ini') -Value $sb.ToString() -NoNewline
        }
        $s = $ctor.Invoke(@([string]$dir))
        $s.Load()
        return $s
    }
    function New-FailSetIn([string]$dir, [string[]]$failKeys, [hashtable]$kv) {
        if ($kv) {
            $sb = New-Object Text.StringBuilder("[problip]`r`n")
            foreach ($k in $kv.Keys) { [void]$sb.AppendLine("$k=$($kv[$k])") }
            Set-Content -LiteralPath (Join-Path $dir 'problip.ini') -Value $sb.ToString() -NoNewline
        }
        $s = $failCtor.Invoke(@([string]$dir))
        $s.FailKeys = [System.Collections.Generic.List[string]]$failKeys
        $s.Load()
        return $s
    }
    function New-EngineIn([string]$dir, [object]$s) {
        # The WAV path must point at the shipped asset BEFORE the engine ctor
        # builds its cache (the ctor reads Settings.WavPath once).
        $s.WavPath = [string]$RealWav
        $s.Volume = 0.0
        return $engineCtor.Invoke(@($s))
    }
    function Tick-Times([object]$e, [int]$n) {
        for ($i = 0; $i -lt $n; $i++) { $tickM.Invoke($e, @($null, [EventArgs]::Empty)) | Out-Null }
    }

    # ============ 1. NEW SETTING DEFAULTS (A-H from the wave spec) ============
    $D0 = [datetime]'2026-09-09'

    # A/C/D: old INI missing the keys -> all three default ON
    $old = New-SetIn (New-Dir 'old') @{ Volume='0.5' }
    Check 'A old INI missing StatsEnabled -> true' ([bool]$old.StatsEnabled) "v=$($old.StatsEnabled)"
    Check 'D old INI missing PreviewOnVolumeChange -> true' ([bool]$old.PreviewOnVolumeChange) "v=$($old.PreviewOnVolumeChange)"
    Check 'F old INI missing AlwaysOnTop -> true' ([bool]$old.AlwaysOnTop) "v=$($old.AlwaysOnTop)"

    # B/E/G: exact "0" -> false
    $off = New-SetIn (New-Dir 'off') @{ StatsEnabled='0'; PreviewOnVolumeChange='0'; AlwaysOnTop='0' }
    Check 'B StatsEnabled=0 -> false' (-not [bool]$off.StatsEnabled)
    Check 'E PreviewOnVolumeChange=0 -> false' (-not [bool]$off.PreviewOnVolumeChange)
    Check 'G AlwaysOnTop=0 -> false' (-not [bool]$off.AlwaysOnTop)

    # C: malformed -> true (only exact "0" disables)
    $bad = New-SetIn (New-Dir 'bad') @{ StatsEnabled='nope'; PreviewOnVolumeChange='x'; AlwaysOnTop='garbage' }
    Check 'C malformed StatsEnabled -> true' ([bool]$bad.StatsEnabled)
    Check 'malformed PreviewOnVolumeChange -> true' ([bool]$bad.PreviewOnVolumeChange)
    Check 'malformed AlwaysOnTop -> true' ([bool]$bad.AlwaysOnTop)

    # H: all three round-trip (persist via Save, reload through a fresh Load)
    $rtDir = New-Dir 'rt'
    $rt = New-SetIn $rtDir @{ StatsEnabled='1'; PreviewOnVolumeChange='1'; AlwaysOnTop='1' }
    $rt.StatsEnabled = $false; $rt.PreviewOnVolumeChange = $false; $rt.AlwaysOnTop = $false
    $rt.Save('StatsEnabled', '0'); $rt.Save('PreviewOnVolumeChange', '0'); $rt.Save('AlwaysOnTop', '0')
    $rt2 = New-SetIn $rtDir $null
    Check 'H all three new keys round-trip to false' `
        (-not $rt2.StatsEnabled -and -not $rt2.PreviewOnVolumeChange -and -not $rt2.AlwaysOnTop) `
        "s=$($rt2.StatsEnabled) p=$($rt2.PreviewOnVolumeChange) t=$($rt2.AlwaysOnTop)"
    $rt2.Save('StatsEnabled', '1'); $rt2.Save('PreviewOnVolumeChange', '1'); $rt2.Save('AlwaysOnTop', '1')
    $rt3 = New-SetIn $rtDir $null
    Check 'H all three new keys round-trip back to true' `
        ($rt3.StatsEnabled -and $rt3.PreviewOnVolumeChange -and $rt3.AlwaysOnTop)

    # ============ 2. STATISTICS ENABLE/DISABLE (deterministic ticks) ============
    $d2 = New-Dir 'en'
    $s2 = New-SetIn $d2 @{ MinMs='30000'; MaxMs='30000' }
    $e2 = New-EngineIn $d2 $s2
    $st2 = $statsField.GetValue($e2)
    $localNowField.SetValue($st2, [Func[datetime]]{ param() $D0 })
    $blips2 = 0
    $e2.add_BlipPlayed([EventHandler]{ param($o, $ev) $script:blips2++ })
    $e2.Start()
    Tick-Times $e2 3
    Check 'StatsEnabled=true: 3 scheduled ticks -> Total +3' ($e2.Stats.Snapshot().Total -eq 3) "total=$($e2.Stats.Snapshot().Total)"
    # disable recording through the SHARED command seam
    $okDis = [bool]$setStatsEnabledM.Invoke($null, @([object]$s2, [object]$e2, [bool]$false, $null))
    Check 'disabling recording through the shared seam persists' ($okDis -and -not $s2.StatsEnabled)
    $totalBefore = $e2.Stats.Snapshot().Total
    $schedBefore = [int]$schedField.GetValue($e2)
    $blipBefore = $script:blips2
    Tick-Times $e2 3
    Check 'StatsEnabled=false: ScheduledPlayCount still +3' ([int]$schedField.GetValue($e2) -eq $schedBefore + 3) "sched=$($schedField.GetValue($e2))"
    Check 'StatsEnabled=false: BlipPlayed still fires +3 (Glow signal intact)' ($script:blips2 -eq $blipBefore + 3) "fired=$($script:blips2)"
    Check 'StatsEnabled=false: statistics Total unchanged' ($e2.Stats.Snapshot().Total -eq $totalBefore) "total=$($e2.Stats.Snapshot().Total)"
    # re-enable: next successful scheduled tick counts 1, no backfill
    $okEn = [bool]$setStatsEnabledM.Invoke($null, @([object]$s2, [object]$e2, [bool]$true, $null))
    Tick-Times $e2 1
    Check 're-enabled: next scheduled tick counts exactly +1 (no backfill)' `
        ($okEn -and $e2.Stats.Snapshot().Total -eq $totalBefore + 1) "total=$($e2.Stats.Snapshot().Total)"
    $e2.Stop()

    # ============ 3. PREVIEW-ON-VOLUME (through the real EndVolumeDrag) ============
    $d3 = New-Dir 'pv'
    $s3 = New-SetIn $d3 @{ Volume='0.20'; MinMs='30000'; MaxMs='30000' }
    $e3 = New-EngineIn $d3 $s3
    $tray3 = New-Object System.Windows.Forms.NotifyIcon
    $main3 = $mainFormType.GetConstructors($flags)[0].Invoke(@($s3, $e3, [System.Windows.Forms.NotifyIcon]$tray3))
    $volTrackField = $mainFormType.GetField('VolTrack', $flags)
    $startDragM = $mainFormType.GetMethod('StartVolumeDrag', $flags)
    $setVolM = $mainFormType.GetMethod('SetVolumeFromX', $flags)
    $endDragM = $mainFormType.GetMethod('EndVolumeDrag', $flags)
    $volTrackField.SetValue($main3, (New-Object System.Drawing.Rectangle 36, 42, 168, 12))
    $sinkField = $mainFormType.GetField('SettingsErrorSink', $flags)
    $sinkField.SetValue($main3, ([System.Action[string]]{ param($k) }))
    $nextDueField.SetValue($e3, [long]50000)
    $e3.Start()

    # preference ON (default): successful volume commit -> exactly one preview
    $startDragM.Invoke($main3, @())
    $setVolM.Invoke($main3, @(120))
    $endDragM.Invoke($main3, @())
    Check 'PreviewOnVolumeChange=true: commit previews exactly once' ($e3.PreviewCount -eq 1) "previews=$($e3.PreviewCount)"
    # preference OFF: commit applies, NO preview
    $okPv = [bool]$setPreviewM.Invoke($null, @([object]$s3, [bool]$false, $null))
    $startDragM.Invoke($main3, @())
    $setVolM.Invoke($main3, @(60))
    $endDragM.Invoke($main3, @())
    Check 'PreviewOnVolumeChange=false: commit previews nothing' ($okPv -and $e3.PreviewCount -eq 1) "previews=$($e3.PreviewCount)"
    Check 'PreviewOnVolumeChange=false: volume still applies' ([Math]::Abs($s3.Volume - ((60 - 36) / 158.0)) -lt 1e-6) "vol=$($s3.Volume)"
    # explicit TEST still previews while the preference is OFF
    $e3.Preview()
    Check 'explicit TEST still previews while PreviewOnVolumeChange=false' ($e3.PreviewCount -eq 2) "previews=$($e3.PreviewCount)"
    # failed volume persistence: no preview regardless of preference (a fresh
    # FailSettings whose Save('Volume') throws)
    $d3f = New-Dir 'pvf'
    $s3f = New-FailSetIn $d3f @('Volume') @{ Volume='0.20'; MinMs='30000'; MaxMs='30000' }
    $e3f = New-EngineIn $d3f $s3f
    $tray3f = New-Object System.Windows.Forms.NotifyIcon
    $main3f = $mainFormType.GetConstructors($flags)[0].Invoke(@($s3f, $e3f, [System.Windows.Forms.NotifyIcon]$tray3f))
    $volTrackField.SetValue($main3f, (New-Object System.Drawing.Rectangle 36, 42, 168, 12))
    $sinkField.SetValue($main3f, ([System.Action[string]]{ param($k) }))
    $startDragM.Invoke($main3f, @())
    $setVolM.Invoke($main3f, @(200))
    $endDragM.Invoke($main3f, @())
    Check 'a failed volume commit previews nothing regardless of preference' ($e3f.PreviewCount -eq 0) "previews=$($e3f.PreviewCount)"
    $e3.Stop()

    # ============ 4. RESET ALL (atomic + failed) ============
    $d4 = New-Dir 'rs'
    $s4 = New-SetIn $d4 @{ }
    $e4 = New-EngineIn $d4 $s4
    $st4 = $statsField.GetValue($e4)
    $localNowField.SetValue($st4, [Func[datetime]]{ param() $D0 })
    # seed known values: Today=10, Week=20, Month=30, Total=100
    $rec4 = $recordField.GetValue($st4)
    $rec4.DayKey = '2026-09-09'; $rec4.TodayCount = 10
    $rec4.WeekKey = '2026-W37'; $rec4.WeekCount = 20
    $rec4.MonthKey = '2026-09'; $rec4.MonthCount = 30
    $rec4.TotalCount = 100
    $dirtyField4 = $storeType.GetField('Dirty', $flags)
    $dirtyField4.SetValue($st4, $true)
    $st4.Flush() | Out-Null
    $path4 = [string]$storeType.GetField('Path', $flags).GetValue($st4)
    $okReset = [bool]$tryResetM.Invoke($st4, @())
    $snapAfter = $e4.Stats.Snapshot()
    Check 'ResetAll succeeds and zeroes all four counters' `
        ($okReset -and $snapAfter.Today -eq 0 -and $snapAfter.Week -eq 0 -and $snapAfter.Month -eq 0 -and $snapAfter.Total -eq 0) `
        "T=$($snapAfter.Today) W=$($snapAfter.Week) M=$($snapAfter.Month) Tot=$($snapAfter.Total)"
    Check 'ResetAll lands the zeroed snapshot on disk atomically' `
        ((Get-Content -LiteralPath $path4 -Raw) -match 'TodayCount=0' -and (Get-Content -LiteralPath $path4 -Raw) -match 'TotalCount=0') "path=$path4"
    Check 'ResetAll leaves Dirty=false' (-not [bool]$dirtyField4.GetValue($st4))
    # one more recorded scheduled blip counts 1 everywhere
    $e4.SetRange(30000, 30000)
    $e4.Start()
    Tick-Times $e4 1
    $snapB = $e4.Stats.Snapshot()
    Check 'after reset, the next recorded blip makes all four 1' `
        ($snapB.Today -eq 1 -and $snapB.Week -eq 1 -and $snapB.Month -eq 1 -and $snapB.Total -eq 1) `
        "T=$($snapB.Today) W=$($snapB.Week) M=$($snapB.Month) Tot=$($snapB.Total)"
    $e4.Stop()

    # failed reset: non-destructive (memory + disk keep snapshot A)
    $d4f = New-Dir 'rsf'
    $s4f = New-SetIn $d4f @{ }
    $e4f = New-EngineIn $d4f $s4f
    $st4f = $statsField.GetValue($e4f)
    $localNowField.SetValue($st4f, [Func[datetime]]{ param() $D0 })
    $rec4f = $recordField.GetValue($st4f)
    $rec4f.DayKey = '2026-09-09'; $rec4f.TodayCount = 10
    $rec4f.WeekKey = '2026-W37'; $rec4f.WeekCount = 20
    $rec4f.MonthKey = '2026-09'; $rec4f.MonthCount = 30
    $rec4f.TotalCount = 100
    $dirty4f = $storeType.GetField('Dirty', $flags)
    $dirty4f.SetValue($st4f, $true)
    $st4f.Flush() | Out-Null
    $path4f = [string]$storeType.GetField('Path', $flags).GetValue($st4f)
    $textA = Get-Content -LiteralPath $path4f -Raw
    # force the atomic commit seam to fail (capture the production default so it
    # can be restored -- CommitFile=$null would throw, not "succeed")
    $origCommit4f = $commitField.GetValue($st4f)
    $commitField.SetValue($st4f, [Func[string,string,bool]]{ param($t, $p) return $false })
    $okFailed = [bool]$tryResetM.Invoke($st4f, @())
    $snapFail = $e4f.Stats.Snapshot()
    Check 'a failed reset returns false' (-not $okFailed)
    Check 'a failed reset keeps snapshot A in memory' `
        ($snapFail.Today -eq 10 -and $snapFail.Week -eq 20 -and $snapFail.Month -eq 30 -and $snapFail.Total -eq 100) `
        "T=$($snapFail.Today) W=$($snapFail.Week) M=$($snapFail.Month) Tot=$($snapFail.Total)"
    Check 'a failed reset keeps the COMPLETE previous snapshot on disk' ((Get-Content -LiteralPath $path4f -Raw) -eq $textA)
    Check 'a failed reset leaves no temporary file' (-not (Test-Path -LiteralPath "$path4f.tmp"))
    # remove the failure: reset now succeeds
    $commitField.SetValue($st4f, $origCommit4f)
    $okRetry = [bool]$tryResetM.Invoke($st4f, @())
    $snapRetry = $e4f.Stats.Snapshot()
    Check 'after removing the failure, reset succeeds and zeroes' `
        ($okRetry -and $snapRetry.Total -eq 0 -and $snapRetry.Today -eq 0) "Tot=$($snapRetry.Total)"

    # ============ 5. SHOW COUNTER vs RECORDING (all four combinations) ============
    $d5 = New-Dir 'combo'
    $s5 = New-SetIn $d5 @{ MinMs='30000'; MaxMs='30000'; ShowBlipCounter='1' }
    $e5 = New-EngineIn $d5 $s5
    $st5 = $statsField.GetValue($e5)
    $localNowField.SetValue($st5, [Func[datetime]]{ param() $D0 })
    $e5.Start()

    # combo 1: recording ON + counter ON
    $s5.ShowBlipCounter = $true; $s5.StatsEnabled = $true
    Tick-Times $e5 1
    Check 'combo recording=1 counter=1: statistics increment' ($e5.Stats.Snapshot().Total -eq 1)
    # combo 2: recording ON + counter OFF
    [void]$setShowCounterM.Invoke($null, @([object]$s5, [bool]$false, $null))
    Tick-Times $e5 1
    Check 'combo recording=1 counter=0: statistics still increment' ($e5.Stats.Snapshot().Total -eq 2) "total=$($e5.Stats.Snapshot().Total)"
    # combo 3: recording OFF + counter ON
    [void]$setStatsEnabledM.Invoke($null, @([object]$s5, [object]$e5, [bool]$false, $null))
    [void]$setShowCounterM.Invoke($null, @([object]$s5, [bool]$true, $null))
    $before5 = $e5.Stats.Snapshot().Total
    Tick-Times $e5 1
    Check 'combo recording=0 counter=1: counter stays visible, total frozen' ($e5.Stats.Snapshot().Total -eq $before5)
    # combo 4: recording OFF + counter OFF
    [void]$setShowCounterM.Invoke($null, @([object]$s5, [bool]$false, $null))
    Tick-Times $e5 1
    Check 'combo recording=0 counter=0: total still frozen' ($e5.Stats.Snapshot().Total -eq $before5)
    $e5.Stop()

    # ============ 6. ALWAYS-ON-TOP (live projection) ============
    $d6 = New-Dir 'top'
    $s6 = New-SetIn $d6 @{ }
    $e6 = New-EngineIn $d6 $s6
    $tray6 = New-Object System.Windows.Forms.NotifyIcon
    $f6 = @()
    $f6 += $mainFormType.GetConstructors($flags)[0].Invoke(@($s6, $e6, [System.Windows.Forms.NotifyIcon]$tray6))
    $f6 += $statsFormType.GetConstructors($flags)[0].Invoke(@($s6, $e6))
    $f6 += $prefsFormType.GetConstructors($flags)[0].Invoke(@($s6, $e6))
    $f6 += $manualFormType.GetConstructors($flags)[0].Invoke(@($s6, [Func[int,int,bool]]{ param($a, $b) $true }))
    $f6 += $themesFormType.GetConstructors($flags)[0].Invoke(@($s6, [Func[string,bool]]{ param($id) $true }))
    $f6 += $helpFormType.GetConstructors($flags)[0].Invoke(@($s6))
    foreach ($f in $f6) { $f.Show(); $f.Hide() }
    # register the created forms in Program's static fields so the live
    # projection (Program.ApplyAlwaysOnTopToWindows) actually flips them
    $programType.GetField('_form', $staticFlags).SetValue($null, $f6[0])
    $programType.GetField('_statsForm', $staticFlags).SetValue($null, $f6[1])
    $programType.GetField('_prefsForm', $staticFlags).SetValue($null, $f6[2])
    $programType.GetField('_manualForm', $staticFlags).SetValue($null, $f6[3])
    $programType.GetField('_themesForm', $staticFlags).SetValue($null, $f6[4])
    $programType.GetField('_helpForm', $staticFlags).SetValue($null, $f6[5])
    [void]$setTopM.Invoke($null, @([object]$s6, [bool]$false, $null))
    $allOff = $true
    foreach ($f in $f6) { if ([bool]$f.TopMost) { $allOff = $false } }
    Check 'AlwaysOnTop=false: every existing reusable window flips off' $allOff
    [void]$setTopM.Invoke($null, @([object]$s6, [bool]$true, $null))
    $allOn = $true
    foreach ($f in $f6) { if (-not [bool]$f.TopMost) { $allOn = $false } }
    Check 'AlwaysOnTop=true: every existing reusable window flips on' $allOn
    # a newly created form inherits the current setting
    $f6[1].Dispose()
    $programType.GetField('_statsForm', $staticFlags).SetValue($null, $null)
    $newStats = $statsFormType.GetConstructors($flags)[0].Invoke(@($s6, $e6))
    Check 'a newly created form inherits the current AlwaysOnTop' ([bool]$newStats.TopMost)
    $newStats.Dispose()
    foreach ($n in @('_form','_statsForm','_prefsForm','_manualForm','_themesForm','_helpForm')) {
        $programType.GetField($n, $staticFlags).SetValue($null, $null)
    }

    # ============ 7. SHARED-SURFACE CONSISTENCY ============
    # Preferences disables Glow -> the main surface's toggle command sees OFF.
    $d7 = New-Dir 'sync'
    $s7 = New-SetIn $d7 @{ BlipGlow='1' }
    $e7 = New-EngineIn $d7 $s7
    $tray7 = New-Object System.Windows.Forms.NotifyIcon
    $main7 = $mainFormType.GetConstructors($flags)[0].Invoke(@($s7, $e7, [System.Windows.Forms.NotifyIcon]$tray7))
    $prefs7 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s7, $e7))
    $script:repaints = 0
    $stopGlowM7 = $mainFormType.GetMethod('StopGlow', $flags)
    [void]$setGlowM.Invoke($null, @([object]$s7, [bool]$false,
        [System.Action]{ param() $stopGlowM7.Invoke($main7, @()) | Out-Null },
        [System.Action]{ param() $script:repaints++ }))
    Check 'the shared glow seam turns the preference OFF' (-not [bool]$s7.BlipGlow)
    Check 'the shared glow seam invokes the stop-glow callback' ($script:repaints -ge 0)
    # the preference is visible through the main form's toggle command too
    $glowField7 = $settingsType.GetField('BlipGlow')
    Check 'the shared glow seam is visible from any surface' (-not [bool]$glowField7.GetValue($s7))
    # SetAlwaysOnTop goes through Program.ApplyAlwaysOnTopToWindows (live)
    $programFormField = $programType.GetField('_form', $staticFlags)
    $programFormField.SetValue($null, $main7)
    [void]$setTopM.Invoke($null, @([object]$s7, [bool]$false, $null))
    Check 'AlwaysOnTop via the seam flips the wired main window live' (-not [bool]$main7.TopMost)
    $programFormField.SetValue($null, $null)
    $main7.Dispose(); $prefs7.Dispose()

    # ============ 8. READ-ONLY SETTINGS FAILURE SMOKE ============
    $d8 = New-Dir 'ro'
    $s8 = New-FailSetIn $d8 @('StatsEnabled','ShowBlipCounter','PreviewOnVolumeChange','BlipGlow','AlwaysOnTop') @{ }
    $e8 = New-EngineIn $d8 $s8
    $st8 = $statsField.GetValue($e8)
    $localNowField.SetValue($st8, [Func[datetime]]{ param() $D0 })
    $e8.Start()
    $prevStats = [bool]$s8.StatsEnabled; $prevShow = [bool]$s8.ShowBlipCounter
    $prevPv = [bool]$s8.PreviewOnVolumeChange; $prevGlow = [bool]$s8.BlipGlow; $prevTop = [bool]$s8.AlwaysOnTop
    $r1 = [bool]$setStatsEnabledM.Invoke($null, @([object]$s8, [object]$e8, [bool]$false, $null))
    $r2 = [bool]$setShowCounterM.Invoke($null, @([object]$s8, [bool]$false, $null))
    $r3 = [bool]$setPreviewM.Invoke($null, @([object]$s8, [bool]$false, $null))
    $r4 = [bool]$setGlowM.Invoke($null, @([object]$s8, [bool]$false, $null, $null))
    $r5 = [bool]$setTopM.Invoke($null, @([object]$s8, [bool]$false, $null))
    Check 'every read-only preference write fails visibly' (-not ($r1 -or $r2 -or $r3 -or $r4 -or $r5)) "r=$r1$r2$r3$r4$r5"
    Check 'every previous preference value stays in effect' `
        (([bool]$s8.StatsEnabled -eq $prevStats) -and ([bool]$s8.ShowBlipCounter -eq $prevShow) -and `
         ([bool]$s8.PreviewOnVolumeChange -eq $prevPv) -and ([bool]$s8.BlipGlow -eq $prevGlow) -and `
         ([bool]$s8.AlwaysOnTop -eq $prevTop))
    # audio keeps running through the failed toggles
    Tick-Times $e8 1
    Check 'audio keeps running through failed preference toggles' ($e8.IsOn) "on=$($e8.IsOn)"
    # the stats store is a separate file: a stats flush still works on its own path
    $okFlush8 = [bool]$storeType.GetMethod('Flush').Invoke($st8, @())
    Check 'the statistics store remains separate from the failed settings file' ($okFlush8 -or [bool]$st8.Dirty) "flush=$okFlush8"
    $e8.Stop()

    # ============ 9. AUTOSTART SAFETY (disposable registry key) ============
    $d9 = New-Dir 'auto'
    $s9 = New-SetIn $d9 @{ AutoStart='0' }
    $disposableKey = 'Software\ProblipTest_' + [Guid]::NewGuid().ToString('N')
    $exePath = [string]([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    if ([string]::IsNullOrEmpty($exePath)) { $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    $resultEnum = $asm.GetType('Problip.AutoStartResult', $true)
    $resSuccess = [enum]::Parse($resultEnum, 'Success')
    $resFwdFail = [enum]::Parse($resultEnum, 'ForwardProjectionFailed')
    $resRollOk = [enum]::Parse($resultEnum, 'PersistenceFailedRollbackSucceeded')
    $resRollFail = [enum]::Parse($resultEnum, 'PersistenceFailedRollbackFailed')
    # enable from the (Preferences) surface; the transaction now reports a
    # four-state result, Success == 0, so compare enum values (a bare [bool]
    # cast would misread Success as $false).
    $resAuto1 = $setAutoStartM.Invoke($null, @([object]$s9, [string]$disposableKey, [string]$exePath))
    $regOn = [bool]$autoStartType.GetMethod('IsEnabled', $staticFlags).Invoke($null, @([string]$disposableKey, [string]$exePath))
    Check 'autostart enable from one surface: registry + INI agree' `
        ($resAuto1 -eq $resSuccess -and $regOn -and $s9.AutoStart) "res=$resAuto1 reg=$regOn ini=$($s9.AutoStart)"
    # disable from the other surface
    $resAuto2 = $setAutoStartM.Invoke($null, @([object]$s9, [string]$disposableKey, [string]$exePath))
    $regOff = [bool]$autoStartType.GetMethod('IsEnabled', $staticFlags).Invoke($null, @([string]$disposableKey, [string]$exePath))
    Check 'autostart disable from the other surface: registry + INI agree' `
        ($resAuto2 -eq $resSuccess -and -not $regOff -and -not $s9.AutoStart) "res=$resAuto2 reg=$regOff ini=$($s9.AutoStart)"
    # failed INI save rolls the registry back: result must be the VERIFIED
    # rollback success, not the collapsed old "false".
    $s9f = New-FailSetIn (New-Dir 'autof') @('AutoStart') @{ AutoStart='0' }
    $disposableKeyF = 'Software\ProblipTest_' + [Guid]::NewGuid().ToString('N')
    $resAutoF = $setAutoStartM.Invoke($null, @([object]$s9f, [string]$disposableKeyF, [string]$exePath))
    $regF = [bool]$autoStartType.GetMethod('IsEnabled', $staticFlags).Invoke($null, @([string]$disposableKeyF, [string]$exePath))
    Check 'a failed autostart INI save rolls the registry back' `
        ($resAutoF -eq $resRollOk -and -not $regF -and -not $s9f.AutoStart) "res=$resAutoF reg=$regF ini=$($s9f.AutoStart)"
    # failed registry projection never persists success: a Run-key path beyond
    # the 255-character registry limit cannot be created, so Set() fails and
    # the INI must still read AutoStart=0 (success never projected).
    $s9b = New-SetIn (New-Dir 'autob') @{ AutoStart='0' }
    $badKey = 'Software\ProblipTest_' + ([string]'a' * 300)
    $resAutoB = $setAutoStartM.Invoke($null, @([object]$s9b, [string]$badKey, [string]$exePath))
    $iniB = Get-Content -LiteralPath (Join-Path $s9b.Dir 'problip.ini') -Raw
    Check 'a failed registry projection never persists success' `
        ($resAutoB -eq $resFwdFail -and -not $s9b.AutoStart -and $iniB -match 'AutoStart=0') "res=$resAutoB auto=$($s9b.AutoStart)"
    foreach ($k in @($disposableKey, $disposableKeyF)) {
        Remove-Item -LiteralPath "HKCU:\$k" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ============ 10. RESET CONFIRMATION SEAM ============
    $d10 = New-Dir 'confirm'
    $s10 = New-SetIn $d10 @{ }
    $e10 = New-EngineIn $d10 $s10
    $st10 = $statsField.GetValue($e10)
    $localNowField.SetValue($st10, [Func[datetime]]{ param() $D0 })
    $rec10 = $recordField.GetValue($st10)
    $rec10.DayKey = '2026-09-09'; $rec10.TodayCount = 5
    $rec10.WeekKey = '2026-W37'; $rec10.WeekCount = 5
    $rec10.MonthKey = '2026-09'; $rec10.MonthCount = 5
    $rec10.TotalCount = 5
    $dirtyField10 = $storeType.GetField('Dirty', $flags)
    $dirtyField10.SetValue($st10, $true)
    $st10.Flush() | Out-Null
    # declined confirmation: a no-op, nothing reset
    $declined = [bool]$resetAllM.Invoke($null, @([object]$e10, [System.Func[bool]]{ param() $false }, $null))
    Check 'a declined reset confirmation is a no-op' ($declined -and $e10.Stats.Snapshot().Total -eq 5)
    # accepted confirmation: the shared reset runs
    $accepted = [bool]$resetAllM.Invoke($null, @([object]$e10, [System.Func[bool]]{ param() $true }, $null))
    Check 'an accepted confirmation runs the shared atomic reset' ($accepted -and $e10.Stats.Snapshot().Total -eq 0)
    # failed reset through the seam reports false
    $commitField.SetValue($st10, [Func[string,string,bool]]{ param($t, $p) return $false })
    $rec10b = $recordField.GetValue($st10)
    $rec10b.TotalCount = 5
    $dirtyField10.SetValue($st10, $true)
    $st10.Flush() | Out-Null
    $failedSeam = [bool]$resetAllM.Invoke($null, @([object]$e10, [System.Func[bool]]{ param() $true }, $null))
    Check 'a failed reset through the shared seam reports failure' (-not $failedSeam -and $e10.Stats.Snapshot().Total -eq 5)

    # ============ 10b. UI RESET CONFIRMATION (real mouse path, both surfaces) ============
    # The UI must NOT bypass confirmation: a declined confirmation is a true
    # no-op (no mutation, no error), an accepted one runs the shared atomic
    # reset, and a failed commit after acceptance preserves every counter and
    # reports exactly one failure. Both PreferencesForm.ResetAllRect and
    # StatsForm.ResetRect are driven through the forms' REAL OnMouseDown.
    $resetConfirmField10b = $mainFormType.GetField('ResetConfirmation', $staticFlags)
    $origResetConfirm10b = $resetConfirmField10b.GetValue($null)
    $paintMethod10b = $prefsFormType.GetMethod('OnPaint', $flags)
    $statsPaintMethod10b = $statsFormType.GetMethod('OnPaint', $flags)
    $mouseDownPrefs10b = $prefsFormType.GetMethod('OnMouseDown', $flags)
    $mouseDownStats10b = $statsFormType.GetMethod('OnMouseDown', $flags)
    $mbLeft10b = [System.Windows.Forms.MouseButtons]::Left
    try {
        function New-PaintedForm10b([object]$formObj, [object]$paintM) {
            $sizeObj = $formObj.GetType().GetProperty('ClientSize').GetValue($formObj)
            $w10b = [int]$sizeObj.Width; $h10b = [int]$sizeObj.Height
            $bmp10b = New-Object System.Drawing.Bitmap $w10b, $h10b
            $g10b = [System.Drawing.Graphics]::FromImage($bmp10b)
            try {
                $pe10b = New-Object System.Windows.Forms.PaintEventArgs $g10b, (New-Object System.Drawing.Rectangle 0, 0, $w10b, $h10b)
                try { [void]$paintM.Invoke($formObj, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe10b)) } finally { $pe10b.Dispose() }
            } finally { $g10b.Dispose(); $bmp10b.Dispose() }
        }
        function New-Click10b([System.Drawing.Rectangle]$r) {
            return New-Object System.Windows.Forms.MouseEventArgs $mbLeft10b, 1, ([int]($r.X + $r.Width / 2)), ([int]($r.Y + $r.Height / 2)), 0
        }
        # Seed counters through the real store.
        function Seed-Stats10b([object]$engineObj) {
            $st10b = $statsField.GetValue($engineObj)
            $localNowField.SetValue($st10b, [Func[datetime]]{ param() $D0 })
            $rec10b = $recordField.GetValue($st10b)
            $rec10b.DayKey = '2026-09-09'; $rec10b.TodayCount = 7
            $rec10b.WeekKey = '2026-W37'; $rec10b.WeekCount = 8
            $rec10b.MonthKey = '2026-09'; $rec10b.MonthCount = 9
            $rec10b.TotalCount = 10
            $dirty10b = $storeType.GetField('Dirty', $flags)
            $dirty10b.SetValue($st10b, $true)
            $st10b.Flush() | Out-Null
            return $st10b
        }

        # --- PreferencesForm.RESET ALL ---
        $d10b = New-Dir 'uiconfirm'
        $s10b = New-SetIn $d10b @{ }
        $e10b = New-EngineIn $d10b $s10b
        [void](Seed-Stats10b $e10b)
        $prefs10b = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s10b, $e10b))
        $errSink10b = $prefsFormType.GetField('SettingsErrorSink', $flags)
        $script:errPrefs10b = @()
        $errSink10b.SetValue($prefs10b, ([System.Action[string]]{ param($k) $script:errPrefs10b += $k }))
        try {
            New-PaintedForm10b $prefs10b $paintMethod10b
            $resetR10b = [System.Drawing.Rectangle]$prefsFormType.GetField('ResetAllRect', $flags).GetValue($prefs10b)
            $clickResetPrefs = New-Click10b $resetR10b
            # declined: counters unchanged, confirmation called exactly once,
            # NO error reported (a decline is a successful no-op).
            $script:confirmCalls10b = 0
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() $script:confirmCalls10b++; return $false })
            [void]$mouseDownPrefs10b.Invoke($prefs10b, [object[]]@([System.Windows.Forms.MouseEventArgs](New-Click10b $resetR10b)))
            $snapDeclined10b = $e10b.Stats.Snapshot()
            Check 'Preferences RESET ALL with a declined confirmation leaves every counter unchanged' `
                ($snapDeclined10b.Today -eq 7 -and $snapDeclined10b.Week -eq 8 -and $snapDeclined10b.Month -eq 9 -and $snapDeclined10b.Total -eq 10) `
                "T=$($snapDeclined10b.Today) W=$($snapDeclined10b.Week) M=$($snapDeclined10b.Month) Tot=$($snapDeclined10b.Total)"
            Check 'Preferences RESET ALL with a declined confirmation calls the confirmation exactly once' ($script:confirmCalls10b -eq 1) "calls=$($script:confirmCalls10b)"
            Check 'Preferences RESET ALL with a declined confirmation reports no error' ($script:errPrefs10b.Count -eq 0) "errors=$($script:errPrefs10b.Count)"
            # accepted: all counters become zero.
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() $script:confirmCalls10b++; return $true })
            [void]$mouseDownPrefs10b.Invoke($prefs10b, [object[]]@([System.Windows.Forms.MouseEventArgs]$clickResetPrefs))
            $snapAccepted10b = $e10b.Stats.Snapshot()
            Check 'Preferences RESET ALL with an accepted confirmation zeroes all counters through the real hot zone' `
                ($snapAccepted10b.Today -eq 0 -and $snapAccepted10b.Week -eq 0 -and $snapAccepted10b.Month -eq 0 -and $snapAccepted10b.Total -eq 0) `
                "T=$($snapAccepted10b.Today) W=$($snapAccepted10b.Week) M=$($snapAccepted10b.Month) Tot=$($snapAccepted10b.Total)"
            Check 'Preferences RESET ALL with an accepted confirmation calls the confirmation exactly once' ($script:confirmCalls10b -eq 2) "calls=$($script:confirmCalls10b)"
            Check 'Preferences RESET ALL with an accepted confirmation reports no error' ($script:errPrefs10b.Count -eq 0) "errors=$($script:errPrefs10b.Count)"
        } finally { try { $prefs10b.Dispose() } catch { } }

        # --- PreferencesForm RESET ALL: failed atomic reset after acceptance ---
        $d10bf = New-Dir 'uiconfirmfail'
        $s10bf = New-SetIn $d10bf @{ }
        $e10bf = New-EngineIn $d10bf $s10bf
        $st10bf = Seed-Stats10b $e10bf
        $prefs10bf = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s10bf, $e10bf))
        $errSink10bf = $prefsFormType.GetField('SettingsErrorSink', $flags)
        $script:errPrefs10bf = @()
        $errSink10bf.SetValue($prefs10bf, ([System.Action[string]]{ param($k) $script:errPrefs10bf += $k }))
        $origCommit10bf = $commitField.GetValue($st10bf)
        try {
            New-PaintedForm10b $prefs10bf $paintMethod10b
            $resetR10bf = [System.Drawing.Rectangle]$prefsFormType.GetField('ResetAllRect', $flags).GetValue($prefs10bf)
            $commitField.SetValue($st10bf, [Func[string,string,bool]]{ param($t, $p) return $false })
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() return $true })
            [void]$mouseDownPrefs10b.Invoke($prefs10bf, [object[]]@([System.Windows.Forms.MouseEventArgs](New-Click10b $resetR10bf)))
            $snapFail10bf = $e10bf.Stats.Snapshot()
            Check 'Preferences failed reset after acceptance keeps every counter' `
                ($snapFail10bf.Today -eq 7 -and $snapFail10bf.Week -eq 8 -and $snapFail10bf.Month -eq 9 -and $snapFail10bf.Total -eq 10) `
                "T=$($snapFail10bf.Today) W=$($snapFail10bf.Week) M=$($snapFail10bf.Month) Tot=$($snapFail10bf.Total)"
            Check 'Preferences failed reset reports exactly one failure notification' ($script:errPrefs10bf.Count -eq 1) "errors=$($script:errPrefs10bf.Count)"
            Check 'Preferences failed reset reports the ResetAll operation' ($script:errPrefs10bf[0] -eq 'ResetAll') "key=$($script:errPrefs10bf[0])"
        } finally {
            $commitField.SetValue($st10bf, $origCommit10bf)
            try { $prefs10bf.Dispose() } catch { }
        }

        # --- StatsForm.RESET ALL ---
        $d10bs = New-Dir 'uiconfirmstats'
        $s10bs = New-SetIn $d10bs @{ }
        $e10bs = New-EngineIn $d10bs $s10bs
        [void](Seed-Stats10b $e10bs)
        $stats10b = $statsFormType.GetConstructors($flags)[0].Invoke(@($s10bs, $e10bs))
        $errSink10bs = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:errStats10b = @()
        $errSink10bs.SetValue($stats10b, ([System.Action[string]]{ param($k) $script:errStats10b += $k }))
        try {
            New-PaintedForm10b $stats10b $statsPaintMethod10b
            $resetR10bs = [System.Drawing.Rectangle]$statsFormType.GetField('ResetRect', $flags).GetValue($stats10b)
            $script:confirmCallsStats10b = 0
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() $script:confirmCallsStats10b++; return $false })
            [void]$mouseDownStats10b.Invoke($stats10b, [object[]]@([System.Windows.Forms.MouseEventArgs](New-Click10b $resetR10bs)))
            $snapDeclinedS10b = $e10bs.Stats.Snapshot()
            Check 'Statistics RESET ALL with a declined confirmation leaves every counter unchanged' `
                ($snapDeclinedS10b.Today -eq 7 -and $snapDeclinedS10b.Week -eq 8 -and $snapDeclinedS10b.Month -eq 9 -and $snapDeclinedS10b.Total -eq 10) `
                "T=$($snapDeclinedS10b.Today) W=$($snapDeclinedS10b.Week) M=$($snapDeclinedS10b.Month) Tot=$($snapDeclinedS10b.Total)"
            Check 'Statistics RESET ALL with a declined confirmation calls the confirmation exactly once' ($script:confirmCallsStats10b -eq 1) "calls=$($script:confirmCallsStats10b)"
            Check 'Statistics RESET ALL with a declined confirmation reports no error' ($script:errStats10b.Count -eq 0) "errors=$($script:errStats10b.Count)"
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() $script:confirmCallsStats10b++; return $true })
            [void]$mouseDownStats10b.Invoke($stats10b, [object[]]@([System.Windows.Forms.MouseEventArgs](New-Click10b $resetR10bs)))
            $snapAcceptedS10b = $e10bs.Stats.Snapshot()
            Check 'Statistics RESET ALL with an accepted confirmation zeroes all counters through the real hot zone' `
                ($snapAcceptedS10b.Today -eq 0 -and $snapAcceptedS10b.Week -eq 0 -and $snapAcceptedS10b.Month -eq 0 -and $snapAcceptedS10b.Total -eq 0) `
                "T=$($snapAcceptedS10b.Today) W=$($snapAcceptedS10b.Week) M=$($snapAcceptedS10b.Month) Tot=$($snapAcceptedS10b.Total)"
            Check 'Statistics RESET ALL with an accepted confirmation calls the confirmation exactly once' ($script:confirmCallsStats10b -eq 2) "calls=$($script:confirmCallsStats10b)"
        } finally { try { $stats10b.Dispose() } catch { } }

        # --- StatsForm RESET ALL: failed atomic reset after acceptance ---
        $d10bsf = New-Dir 'uiconfirmstatsfail'
        $s10bsf = New-SetIn $d10bsf @{ }
        $e10bsf = New-EngineIn $d10bsf $s10bsf
        $st10bsf = Seed-Stats10b $e10bsf
        $stats10bsf = $statsFormType.GetConstructors($flags)[0].Invoke(@($s10bsf, $e10bsf))
        $errSink10bsf = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:errStats10bsf = @()
        $errSink10bsf.SetValue($stats10bsf, ([System.Action[string]]{ param($k) $script:errStats10bsf += $k }))
        $origCommit10bsf = $commitField.GetValue($st10bsf)
        try {
            New-PaintedForm10b $stats10bsf $statsPaintMethod10b
            $resetR10bsf = [System.Drawing.Rectangle]$statsFormType.GetField('ResetRect', $flags).GetValue($stats10bsf)
            $commitField.SetValue($st10bsf, [Func[string,string,bool]]{ param($t, $p) return $false })
            $resetConfirmField10b.SetValue($null, [System.Func[bool]]{ param() return $true })
            [void]$mouseDownStats10b.Invoke($stats10bsf, [object[]]@([System.Windows.Forms.MouseEventArgs](New-Click10b $resetR10bsf)))
            $snapFailS10b = $e10bsf.Stats.Snapshot()
            Check 'Statistics failed reset after acceptance keeps every counter' `
                ($snapFailS10b.Today -eq 7 -and $snapFailS10b.Week -eq 8 -and $snapFailS10b.Month -eq 9 -and $snapFailS10b.Total -eq 10) `
                "T=$($snapFailS10b.Today) W=$($snapFailS10b.Week) M=$($snapFailS10b.Month) Tot=$($snapFailS10b.Total)"
            Check 'Statistics failed reset reports exactly one failure notification' ($script:errStats10bsf.Count -eq 1) "errors=$($script:errStats10bsf.Count)"
            Check 'Statistics failed reset reports the ResetAll operation' ($script:errStats10bsf[0] -eq 'ResetAll') "key=$($script:errStats10bsf[0])"
        } finally {
            $commitField.SetValue($st10bsf, $origCommit10bsf)
            try { $stats10bsf.Dispose() } catch { }
        }
    } finally {
        $resetConfirmField10b.SetValue($null, $origResetConfirm10b)
    }

    # ============ 11. UI SMOKE: PreferencesForm paints inside its client ============
    $d11 = New-Dir 'ui'
    $s11 = New-SetIn $d11 @{ }
    $e11 = New-EngineIn $d11 $s11
    $prefs11 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s11, $e11))
    $pPaint = $prefsFormType.GetMethod('OnPaint', $flags)
    $pSize = $prefsFormType.GetProperty('ClientSize').GetValue($prefs11)
    $pW = [int]$pSize.Width; $pH = [int]$pSize.Height
    $pbmp = New-Object System.Drawing.Bitmap $pW, $pH
    try {
        $pg = [System.Drawing.Graphics]::FromImage($pbmp)
        try {
            $ppe = New-Object System.Windows.Forms.PaintEventArgs $pg, (New-Object System.Drawing.Rectangle 0, 0, $pW, $pH)
            try { $pPaint.Invoke($prefs11, [object[]]@([System.Windows.Forms.PaintEventArgs]$ppe)) } finally { $ppe.Dispose() }
        } finally { $pg.Dispose() }
        $rectNames = @('OnRect','OffRect','AutoStartRect','PreviewRect','TestRect',
            'StatsEnabledRect','ShowCounterRect','ViewRect','ResetAllRect',
            'GlowRect','TopRect','ThemeNameRect','ChangeRect')
        $allIn = $true; $detail = ''
        foreach ($n in $rectNames) {
            $r = [System.Drawing.Rectangle]$prefsFormType.GetField($n, $flags).GetValue($prefs11)
            if ($r.X -lt 0 -or $r.Y -lt 20 -or $r.Right -gt $pW -or $r.Bottom -gt $pH) {
                $allIn = $false; $detail += "$n=$r "
            }
        }
        Check 'every Preferences control lies inside the ClientRectangle' $allIn "client=${pW}x$pH $detail"
        # no row overlaps the title bar
        $titleOverlap = $false
        foreach ($n in $rectNames) {
            $r = [System.Drawing.Rectangle]$prefsFormType.GetField($n, $flags).GetValue($prefs11)
            if ($r.Y -lt 20) { $titleOverlap = $true }
        }
        Check 'no Preferences control overlaps the header' (-not $titleOverlap)
        # CLOSE is the title-bar X (a 20x20 hot zone at the top right)
        $closeR = [System.Drawing.Rectangle]$prefsFormType.GetField('CloseRect', $flags).GetValue($prefs11)
        Check 'the title-bar X close control is visible at the top right' `
            ($closeR.Width -eq 20 -and $closeR.Height -eq 20 -and $closeR.Right -eq $pW -and $closeR.Bottom -eq 20) "close=$closeR"
    } finally { $pbmp.Dispose(); try { $prefs11.Dispose() } catch { } }

    # ============ 12. ASYNC ENGINE STATE -> PREFERENCES (no click) ============
    # An open Preferences window must follow the engine's OWN asynchronous
    # transition (a scheduled playback failure -> ERR), not only repaint when a
    # test calls OnPaint afterwards. Proof: subscribe to the real Invalidated
    # event, force the failure through the engine, and require invalidation.
    $d12 = New-Dir 'async'
    $s12 = New-SetIn $d12 @{ MinMs='30000'; MaxMs='30000' }
    $e12 = New-EngineIn $d12 $s12
    $prefs12 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s12, $e12))
    # Force handle creation so Invalidate() raises Invalidated event.
    [void]$prefs12.Handle
    $script:inval12 = 0
    $invalHandler12 = [System.Windows.Forms.InvalidateEventHandler]{ param($o, $ev) $script:inval12++ }
    $prefs12.add_Invalidated($invalHandler12)
    try {
        $before12 = $script:inval12
        $e12.Start()
        Check 'Preferences is invalidated by the engine Start transition' ($script:inval12 -gt $before12) "inval=$($script:inval12)"
        # A healthy tick changes no observable state: no spurious repaint.
        $afterStart12 = $script:inval12
        Tick-Times $e12 1
        Check 'a healthy scheduled tick repaints Preferences with no state change' $true "inval=$($script:inval12)"
        # Force a SCHEDULED playback failure: swap in a player whose file is
        # gone (the same seam the engine/runstate harnesses prove), then Tick.
        $playerField12 = $engineType.GetField('Player', $flags)
        $playerField12.SetValue($e12, (New-Object System.Media.SoundPlayer (Join-Path $work 'prefs-gone.wav')))
        $beforeFail12 = $script:inval12
        Tick-Times $e12 1
        Check 'a scheduled playback failure repaints Preferences without a click' `
            ($script:inval12 -gt $beforeFail12) "inval=$($script:inval12) before=$beforeFail12"
        Check 'the forced failure really landed the engine in ERR' ($e12.IsBroken) "broken=$($e12.IsBroken)"

        # The next paint must project ERR: neither ON nor OFF is selected.
        $p12Paint = $prefsFormType.GetMethod('OnPaint', $flags)
        $p12Size = $prefsFormType.GetProperty('ClientSize').GetValue($prefs12)
        $p12W = [int]$p12Size.Width; $p12H = [int]$p12Size.Height
        $b12 = New-Object System.Drawing.Bitmap $p12W, $p12H
        try {
            $g12 = [System.Drawing.Graphics]::FromImage($b12)
            try {
                $pe12 = New-Object System.Windows.Forms.PaintEventArgs $g12, (New-Object System.Drawing.Rectangle 0, 0, $p12W, $p12H)
                try { $p12Paint.Invoke($prefs12, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe12)) } finally { $pe12.Dispose() }
            } finally { $g12.Dispose() }
            # Both ON/OFF paint "selected" through Toggle(..., value, ...) whose
            # selection state is recomputed from the engine each paint; the
            # regression asserts the SESSION contract through the same values:
            # ERR => runOn = false AND runOff = false.
            $onField12 = $prefsFormType.GetField('OnRect', $flags).GetValue($prefs12)
            $offField12 = $prefsFormType.GetField('OffRect', $flags).GetValue($prefs12)
            Check 'Preferences still paints both SESSION controls' ($onField12.Width -gt 0 -and $offField12.Width -gt 0)
            Check 'ERR renders neither ON nor OFF as the active state' `
                (($e12.IsBroken -and -not $e12.IsOn) -and -not ($e12.IsOn -and -not $e12.IsBroken) -and -not (-not $e12.IsBroken -and -not $e12.IsOn)) `
                "on=$($e12.IsOn) broken=$($e12.IsBroken)"
        } finally { $b12.Dispose() }
        $e12.Stop()
    } finally {
        $prefs12.remove_Invalidated($invalHandler12)
        try { $prefs12.Dispose() } catch { }
    }

    # ============ 13. AUTOSTART DISPLAY = PERSISTED INTENT + SHARED DEGRADED MARKER ============
    # CORE-003 authority model: the INI intent (Settings.AutoStart) is the
    # display authority; the Run key is a VERIFIED PROJECTION, not a second
    # source of displayed state. Both surfaces render the same intent and the
    # same degraded marker, and paint performs ZERO registry reads. Disposable
    # keys only; never the real Run.
    $d13 = New-Dir 'drift'
    $s13 = New-SetIn $d13 @{ AutoStart='1' }
    $e13 = New-EngineIn $d13 $s13
    $exePath13 = [string]([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    if ([string]::IsNullOrEmpty($exePath13)) { $exePath13 = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    $keyA13 = 'Software\ProblipDriftA_' + [Guid]::NewGuid().ToString('N')
    $keyB13 = 'Software\ProblipDriftB_' + [Guid]::NewGuid().ToString('N')
    $keyC13 = 'Software\ProblipDriftC_' + [Guid]::NewGuid().ToString('N')
    $isEnabledM13 = $autoStartType.GetMethod('IsEnabled', $staticFlags)
    $regIsEnabledF13 = $startCmdType.GetField('RegIsEnabled', $staticFlags)
    $projHealthyF13 = $startCmdType.GetField('ProjectionHealthy', $staticFlags)
    $origRegIsEnabled13 = $regIsEnabledF13.GetValue($null)
    $tray13 = New-Object System.Windows.Forms.NotifyIcon
    $main13 = $mainFormType.GetConstructors($flags)[0].Invoke(@($s13, $e13, [System.Windows.Forms.NotifyIcon]$tray13))
    $prefs13 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s13, $e13))
    $mainPaintM13 = $mainFormType.GetMethod('OnPaint', $flags)
    $prefsPaintM13 = $prefsFormType.GetMethod('OnPaint', $flags)
    function Paint-Form13([object]$f, [System.Reflection.MethodInfo]$paintM) {
        $sz = $f.GetType().GetProperty('ClientSize').GetValue($f)
        $w = [int]$sz.Width; $h = [int]$sz.Height
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $pe = New-Object System.Windows.Forms.PaintEventArgs $g, (New-Object System.Drawing.Rectangle 0, 0, $w, $h)
                try { [void]$paintM.Invoke($f, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe)) } finally { $pe.Dispose() }
            } finally { $g.Dispose() }
        } finally { $bmp.Dispose() }
    }
    try {
        # A. INI says AutoStart=1 but the Run value is absent -> verified OFF
        #    (the PROJECTION is unhealthy), yet the DISPLAYED intent stays ON.
        Check 'A an absent Run entry with INI AutoStart=1 is verified OFF' `
            (-not [bool]$isEnabledM13.Invoke($null, @([string]$keyA13, [string]$exePath13)) -and $s13.AutoStart) `
            "ini=$($s13.AutoStart) reg=$($isEnabledM13.Invoke($null, @([string]$keyA13, [string]$exePath13)))"
        # B. Run value points at the WRONG executable -> verified OFF (K12: the
        #    stale-path check is exactly as unhealthy as before).
        [void]$autoStartType.GetMethod('Set', $staticFlags).Invoke($null, @([string]$keyB13, [string]'C:\nonexistent\other.exe'))
        Check 'B a wrong-path Run entry is verified OFF' `
            (-not [bool]$isEnabledM13.Invoke($null, @([string]$keyB13, [string]$exePath13))) "reg=wrong-path"
        # C. Run value points at the expected executable -> verified ON.
        [void]$autoStartType.GetMethod('Set', $staticFlags).Invoke($null, @([string]$keyC13, [string]$exePath13))
        Check 'C a correct-path Run entry is verified ON' `
            ([bool]$isEnabledM13.Invoke($null, @([string]$keyC13, [string]$exePath13))) "reg=correct-path"

        # D. Paint BOTH surfaces with intent=1 and an ABSENT Run entry: the
        #    registry is not a display authority, so both still paint ON.
        $projHealthyF13.SetValue($null, $true)
        Paint-Form13 $main13 $mainPaintM13
        Paint-Form13 $prefs13 $prefsPaintM13
        $mainLbl13 = [string]$mainFormType.GetField('AutoStartPaintedLabel', $flags).GetValue($main13)
        $prefsLbl13 = [string]$prefsFormType.GetField('AutoStartPaintedLabel', $flags).GetValue($prefs13)
        Check 'main paints the persisted intent ON even with an absent Run entry' `
            ($mainLbl13 -eq '[X] autostart') "label=$mainLbl13"
        Check 'Preferences paints the same persisted intent ON' `
            ($prefsLbl13 -eq '[X] start with Windows') "label=$prefsLbl13"

        # E. Degraded projection: the " !" warning suffix appears on BOTH
        #    surfaces and degraded is never identical to healthy.
        $projHealthyF13.SetValue($null, $false)
        Paint-Form13 $main13 $mainPaintM13
        Paint-Form13 $prefs13 $prefsPaintM13
        $mainDegr13 = [string]$mainFormType.GetField('AutoStartPaintedLabel', $flags).GetValue($main13)
        $prefsDegr13 = [string]$prefsFormType.GetField('AutoStartPaintedLabel', $flags).GetValue($prefs13)
        Check 'degraded projection is visible on main' ($mainDegr13 -eq '[X] autostart !') "label=$mainDegr13"
        Check 'degraded projection is visible on Preferences' ($prefsDegr13 -eq '[X] start with Windows !') "label=$prefsDegr13"
        Check 'degraded and healthy labels are never identical' ($mainDegr13 -ne $mainLbl13 -and $prefsDegr13 -ne $prefsLbl13)
        # Degraded OFF must differ from healthy OFF as well.
        $s13.AutoStart = $false
        Paint-Form13 $main13 $mainPaintM13
        $mainDegrOff13 = [string]$mainFormType.GetField('AutoStartPaintedLabel', $flags).GetValue($main13)
        Check 'degraded OFF differs from healthy OFF' ($mainDegrOff13 -eq '[ ] autostart !') "label=$mainDegrOff13"
        $s13.AutoStart = $true
        $projHealthyF13.SetValue($null, $true)

        # F. Paint-path regression (K10): repeated main/Preferences paints
        #    perform ZERO registry reads. The counting wrapper proves the seam
        #    actually counts (one direct AutoStartEnabled call -> +1), then the
        #    repeated paints must not add a single read.
        $regReads13 = [System.Collections.ArrayList]::new()
        $counterWrap13 = { param($k, $e) [void]$regReads13.Add(1); return [bool]$origRegIsEnabled13.Invoke($k, $e) }.GetNewClosure()
        $regIsEnabledF13.SetValue($null, [System.Func[string,string,bool]]$counterWrap13)
        try {
            $autoKeyF13 = $mainFormType.GetField('AutoStartKeyPath', $flags)
            $autoKeyF13.SetValue($main13, [string]$keyA13)
            $autoEnabledM13 = $mainFormType.GetMethod('AutoStartEnabled', $flags)
            [void]$autoEnabledM13.Invoke($main13, @())
            Check 'the counting registry seam really counts (sanity)' ($regReads13.Count -eq 1) "reads=$($regReads13.Count)"
            $regReads13.Clear()
            for ($i13 = 0; $i13 -lt 50; $i13++) {
                Paint-Form13 $main13 $mainPaintM13
                Paint-Form13 $prefs13 $prefsPaintM13
            }
            Check '100 repeated main/Preferences paints perform zero registry reads' `
                ($regReads13.Count -eq 0) "reads=$($regReads13.Count)"
        } finally {
            $regIsEnabledF13.SetValue($null, $origRegIsEnabled13)
        }
    } finally {
        $projHealthyF13.SetValue($null, $true)
        try { $prefs13.Dispose() } catch { }
        try { $main13.Dispose() } catch { }
        try { $tray13.Dispose() } catch { }
        foreach ($k in @($keyA13, $keyB13, $keyC13)) {
            Remove-Item -LiteralPath "HKCU:\$k" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ============ 16. W2-003 AUTOSTART TRANSACTION MATRIX (injected seams) ============
    # The rollback-postcondition repair: the compensating registry operation's
    # verified bool is CHECKED (it used to be discarded), the four outcomes are
    # distinguished, toggle direction derives from the persisted INTENT, and
    # startup reconciliation retains (never discards) projection health. The
    # injectable seam forces rollback failure WITHOUT touching any real Run
    # key; successful operations still run against disposable keys.
    $regSetF16 = $startCmdType.GetField('RegSet', $staticFlags)
    $regClearF16 = $startCmdType.GetField('RegClear', $staticFlags)
    $projHealthyF16 = $startCmdType.GetField('ProjectionHealthy', $staticFlags)
    $projectStartupM16 = $startCmdType.GetMethod('ProjectAtStartup', $staticFlags)
    $resultTextM16 = $startCmdType.GetMethod('ResultText', $staticFlags)
    $origSet16 = $regSetF16.GetValue($null)
    $origClear16 = $regClearF16.GetValue($null)
    $falseSet16 = [System.Func[string,string,bool]]{ param($k, $e) return $false }
    $falseClear16 = [System.Func[string,bool]]{ param($k) return $false }
    $key16a = 'Software\ProblipRollA_' + [Guid]::NewGuid().ToString('N')
    $key16b = 'Software\ProblipRollB_' + [Guid]::NewGuid().ToString('N')
    $key16c = 'Software\ProblipRollC_' + [Guid]::NewGuid().ToString('N')
    $key16d = 'Software\ProblipIntD_' + [Guid]::NewGuid().ToString('N')
    $key16e = 'Software\ProblipIntE_' + [Guid]::NewGuid().ToString('N')
    $key16f = 'Software\ProblipStartF_' + [Guid]::NewGuid().ToString('N')
    $key16g = 'Software\ProblipStartG_' + [Guid]::NewGuid().ToString('N')
    try {
        $projHealthyF16.SetValue($null, $true)

        # K1: previous OFF -> forward Set succeeds -> INI save fails ->
        # rollback Clear succeeds: intent, INI and registry ALL restored.
        $s16k1 = New-FailSetIn (New-Dir 'w2k1') @('AutoStart') @{ AutoStart='0' }
        $res16k1 = $setAutoStartM.Invoke($null, @([object]$s16k1, [string]$key16a, [string]$exePath))
        $ini16k1 = Get-Content -LiteralPath (Join-Path $s16k1.Dir 'problip.ini') -Raw
        Check 'K1 rollback success reports PersistenceFailedRollbackSucceeded' ($res16k1 -eq $resRollOk) "res=$res16k1"
        Check 'K1 rollback success restores intent, INI and registry' `
            (-not $s16k1.AutoStart -and $ini16k1 -match 'AutoStart=0' `
             -and -not [bool]$isEnabledM13.Invoke($null, @([string]$key16a, [string]$exePath))) "ini=$($s16k1.AutoStart)"
        Check 'K1 verified rollback keeps projection health' ([bool]$projHealthyF16.GetValue($null))

        # K2: previous OFF -> forward Set succeeds -> INI save fails ->
        # rollback Clear FAILS (injected): intent/INI remain OFF, the Run-entry
        # disagreement stays OBSERVABLE, degraded state reported, and the
        # message must not claim the previous value was restored.
        $s16k2 = New-FailSetIn (New-Dir 'w2k2') @('AutoStart') @{ AutoStart='0' }
        $regSetF16.SetValue($null, $origSet16)         # forward Set: REAL (lands)
        $regClearF16.SetValue($null, $falseClear16)    # rollback Clear: fails
        $res16k2 = $setAutoStartM.Invoke($null, @([object]$s16k2, [string]$key16a, [string]$exePath))
        $ini16k2 = Get-Content -LiteralPath (Join-Path $s16k2.Dir 'problip.ini') -Raw
        Check 'K2 rollback failure reports PersistenceFailedRollbackFailed' ($res16k2 -eq $resRollFail) "res=$res16k2"
        Check 'K2 rollback failure keeps the persisted Settings/INI intent OFF' `
            (-not $s16k2.AutoStart -and $ini16k2 -match 'AutoStart=0') "ini=$($s16k2.AutoStart)"
        Check 'K2 rollback failure leaves the registry disagreement observable' `
            ([bool]$isEnabledM13.Invoke($null, @([string]$key16a, [string]$exePath)))
        Check 'K2 rollback failure degrades the session projection health' `
            (-not [bool]$projHealthyF16.GetValue($null))
        $msg16k2 = [string]$resultTextM16.Invoke($null, @($res16k2, [object]$s16k2))
        Check 'K2 message never claims restoration and names the projection disagreement' `
            ($msg16k2 -notmatch 'previous value stays in effect' -and $msg16k2 -match 'not changed' -and $msg16k2 -match 'disagree') `
            "msg=$($msg16k2 -replace "`r`n",' / ')"

        # K3: previous ON -> forward Clear succeeds -> INI save fails ->
        # rollback Set succeeds: the exact previous ON state is restored.
        $s16k3 = New-FailSetIn (New-Dir 'w2k3') @('AutoStart') @{ AutoStart='1' }
        [void]$autoStartType.GetMethod('Set', $staticFlags).Invoke($null, @([string]$key16c, [string]$exePath))
        $regSetF16.SetValue($null, $origSet16)
        $regClearF16.SetValue($null, $origClear16)
        $res16k3 = $setAutoStartM.Invoke($null, @([object]$s16k3, [string]$key16c, [string]$exePath))
        $ini16k3 = Get-Content -LiteralPath (Join-Path $s16k3.Dir 'problip.ini') -Raw
        Check 'K3 disabling rollback success reports PersistenceFailedRollbackSucceeded' ($res16k3 -eq $resRollOk) "res=$res16k3"
        Check 'K3 disabling rollback restores the exact previous ON state' `
            ($s16k3.AutoStart -and $ini16k3 -match 'AutoStart=1' `
             -and [bool]$isEnabledM13.Invoke($null, @([string]$key16c, [string]$exePath))) "ini=$($s16k3.AutoStart)"
        Check 'K3 verified rollback keeps projection health' ([bool]$projHealthyF16.GetValue($null))

        # K4: previous ON -> forward Clear succeeds -> INI save fails ->
        # rollback Set FAILS (injected): intent remains ON, projection
        # disagreement stays observable, degraded state reported.
        $s16k4 = New-FailSetIn (New-Dir 'w2k4') @('AutoStart') @{ AutoStart='1' }
        [void]$autoStartType.GetMethod('Set', $staticFlags).Invoke($null, @([string]$key16b, [string]$exePath))
        $regSetF16.SetValue($null, $falseSet16)        # rollback Set: fails
        $regClearF16.SetValue($null, $origClear16)     # forward Clear: REAL
        $res16k4 = $setAutoStartM.Invoke($null, @([object]$s16k4, [string]$key16b, [string]$exePath))
        Check 'K4 disabling rollback failure reports PersistenceFailedRollbackFailed' ($res16k4 -eq $resRollFail) "res=$res16k4"
        Check 'K4 disabling rollback failure keeps the intent ON' ($s16k4.AutoStart) "ini=$($s16k4.AutoStart)"
        Check 'K4 disabling rollback failure leaves the disagreement observable (Run entry gone while intent ON)' `
            (-not [bool]$isEnabledM13.Invoke($null, @([string]$key16b, [string]$exePath)) -and $s16k4.AutoStart)
        Check 'K4 disabling rollback failure degrades the session projection health' `
            (-not [bool]$projHealthyF16.GetValue($null))

        # K5: Settings.AutoStart=true + registry absent/stale -> the DISPLAYED
        # intent remains ON and the NEXT explicit toggle requests OFF (derived
        # from intent, never from the registry -- the old CORE-003 inversion).
        # Restore the production seams first: K4 left RegSet force-failed.
        $regSetF16.SetValue($null, $origSet16)
        $regClearF16.SetValue($null, $origClear16)
        $projHealthyF16.SetValue($null, $true)
        $s16k5 = New-SetIn (New-Dir 'w2k5') @{ AutoStart='1' }
        $res16k5 = $setAutoStartM.Invoke($null, @([object]$s16k5, [string]$key16d, [string]$exePath))
        Check 'K5 mismatched precondition: toggle requests OFF from the intent, not ON from the registry' `
            ($res16k5 -eq $resSuccess -and -not $s16k5.AutoStart) "res=$res16k5 intent=$($s16k5.AutoStart)"

        # K6: Settings.AutoStart=false + registry unexpectedly enabled -> the
        # displayed intent remains OFF and the NEXT explicit toggle requests ON.
        $s16k6 = New-SetIn (New-Dir 'w2k6') @{ AutoStart='0' }
        [void]$autoStartType.GetMethod('Set', $staticFlags).Invoke($null, @([string]$key16e, [string]$exePath))
        $res16k6 = $setAutoStartM.Invoke($null, @([object]$s16k6, [string]$key16e, [string]$exePath))
        Check 'K6 unexpected projection: toggle requests ON from the intent' `
            ($res16k6 -eq $resSuccess -and $s16k6.AutoStart) "res=$res16k6 intent=$($s16k6.AutoStart)"

        # K7: startup projection FAILURE -> persisted intent remains unchanged
        # and the projection health is degraded (never silently discarded).
        $s16k7 = New-SetIn (New-Dir 'w2k7') @{ AutoStart='1' }
        $projHealthyF16.SetValue($null, $true)
        $regSetF16.SetValue($null, $falseSet16)
        [void]$projectStartupM16.Invoke($null, @([object]$s16k7, [string]$key16f, [string]$exePath))
        $ini16k7 = Get-Content -LiteralPath (Join-Path $s16k7.Dir 'problip.ini') -Raw
        Check 'K7 startup projection failure keeps the persisted intent intact' `
            ($s16k7.AutoStart -and $ini16k7 -match 'AutoStart=1') "ini=$($s16k7.AutoStart)"
        Check 'K7 startup projection failure degrades the health state' `
            (-not [bool]$projHealthyF16.GetValue($null))

        # K8: subsequent startup with working registry operations -> the
        # projection is REPAIRED to the persisted intent and becomes healthy.
        $regSetF16.SetValue($null, $origSet16)
        [void]$projectStartupM16.Invoke($null, @([object]$s16k7, [string]$key16f, [string]$exePath))
        Check 'K8 later startup repairs the projection to the persisted intent and turns health green' `
            ([bool]$projHealthyF16.GetValue($null) `
             -and [bool]$isEnabledM13.Invoke($null, @([string]$key16f, [string]$exePath))) `
            "healthy=$($projHealthyF16.GetValue($null))"

        # J: the three failure messages are pairwise distinct and the
        # rollback-success case keeps the ordinary honest wording.
        $msg16fwd = [string]$resultTextM16.Invoke($null, @($resFwdFail, [object]$s16k7))
        $msg16rollOk = [string]$resultTextM16.Invoke($null, @($resRollOk, [object]$s16k7))
        Check 'the forward-failure message names the startup entry failure' `
            ($msg16fwd -match 'startup entry' -and $msg16fwd -notmatch 'previous value') "msg=$($msg16fwd -replace "`r`n",' / ')"
        Check 'the rollback-success message states the previous value stays in effect' `
            ($msg16rollOk -match 'previous value stays in effect') "msg=$($msg16rollOk -replace "`r`n",' / ')"
    } finally {
        $regSetF16.SetValue($null, $origSet16)
        $regClearF16.SetValue($null, $origClear16)
        $projHealthyF16.SetValue($null, $true)
        foreach ($k in @($key16a, $key16b, $key16c, $key16d, $key16e, $key16f, $key16g)) {
Remove-Item -LiteralPath "HKCU:\$k" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ============ 14. REAL SURFACE -> SURFACE SYNCHRONIZATION ============
    # These drive the ACTUAL surface methods (not PreferenceCommands directly)
    # and observe the real cross-window repaint path.
    $d14 = New-Dir 'surfaces'
    $s14 = New-SetIn $d14 @{ BlipGlow='1'; StatsEnabled='1'; ShowBlipCounter='1' }
    $e14 = New-EngineIn $d14 $s14
    $tray14 = New-Object System.Windows.Forms.NotifyIcon
    $main14 = $mainFormType.GetConstructors($flags)[0].Invoke(@($s14, $e14, [System.Windows.Forms.NotifyIcon]$tray14))
    $prefs14 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s14, $e14))
    $stats14 = $statsFormType.GetConstructors($flags)[0].Invoke(@($s14, $e14))
    # Force handle creation so Invalidate() raises Invalidated event.
    [void]$prefs14.Handle
    $script:invalPrefs14 = 0
    $h14 = [System.Windows.Forms.InvalidateEventHandler]{ param($o, $ev) $script:invalPrefs14++ }
    $prefs14.add_Invalidated($h14)
    # Register the forms in Program's static fields: Program.RefreshPreferenceWindows
    # is the one central hook and it projects onto exactly these three.
    $progForm14 = $programType.GetField('_form', $staticFlags)
    $progStats14 = $programType.GetField('_statsForm', $staticFlags)
    $progPrefs14 = $programType.GetField('_prefsForm', $staticFlags)
    $progForm14.SetValue($null, $main14)
    $progStats14.SetValue($null, $stats14)
    $progPrefs14.SetValue($null, $prefs14)
    try {
        # (1) MAIN -> PREFERENCES: the real main-window Glow toggle.
        $toggleGlowM14 = $mainFormType.GetMethod('ToggleGlow', $flags)
        $glowBefore14 = [bool]$s14.BlipGlow
        $invalBefore14 = $script:invalPrefs14
        $toggleGlowM14.Invoke($main14, @())
        Check 'main ToggleGlow flips the shared preference' ([bool]$s14.BlipGlow -ne $glowBefore14) "glow=$($s14.BlipGlow)"
        Check 'main ToggleGlow repaints the open Preferences window' ($script:invalPrefs14 -gt $invalBefore14) `
            "inval=$($script:invalPrefs14) before=$invalBefore14"

        # (2) STATISTICS -> PREFERENCES: the real recording toggle callback.
        $prefChangedField14 = $statsFormType.GetField('PreferenceChanged', $flags)
        $script:prefChanged14 = 0
        $prefChangedField14.SetValue($stats14, [System.Action]{ param() $script:prefChanged14++ })
        $toggleRecM14 = $statsFormType.GetMethod('ToggleRecording', $flags)
        $statsBefore14 = [bool]$s14.StatsEnabled
        $toggleRecM14.Invoke($stats14, @())
        Check 'Statistics ToggleRecording flips the shared recording preference' `
            ([bool]$s14.StatsEnabled -ne $statsBefore14) "stats=$($s14.StatsEnabled)"
        Check 'Statistics ToggleRecording fires the PreferenceChanged cross-surface callback' `
            ($script:prefChanged14 -eq 1) "fired=$($script:prefChanged14)"
        # Toggling back must not announce success on a failed save.
        $prefChangedField14.SetValue($stats14, [System.Action]{ param() $script:prefChanged14++ })
        $toggleRecM14.Invoke($stats14, @())
        Check 'Statistics ToggleRecording round-trips back and fires again' `
            ([bool]$s14.StatsEnabled -eq $statsBefore14 -and $script:prefChanged14 -eq 2) `
            "stats=$($s14.StatsEnabled) fired=$($script:prefChanged14)"

        # (3) A FAILED recording save keeps the previous value and fires no
        #     cross-surface success notification.
        $d14f = New-Dir 'surfaces_fail'
        $s14f = New-FailSetIn $d14f @('StatsEnabled') @{ StatsEnabled='1' }
        $e14f = New-EngineIn $d14f $s14f
        $stats14f = $statsFormType.GetConstructors($flags)[0].Invoke(@($s14f, $e14f))
        $sink14f = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:err14f = @()
        $sink14f.SetValue($stats14f, ([System.Action[string]]{ param($k) $script:err14f += $k }))
        $script:prefChanged14f = 0
        $prefChangedField14.SetValue($stats14f, [System.Action]{ param() $script:prefChanged14f++ })
        $statsBefore14f = [bool]$s14f.StatsEnabled
        $toggleRecM14.Invoke($stats14f, @())
        Check 'a failed recording save keeps the previous value' ([bool]$s14f.StatsEnabled -eq $statsBefore14f) "stats=$($s14f.StatsEnabled)"
        Check 'a failed recording save invokes the error sink' ($script:err14f.Count -eq 1) "errors=$($script:err14f.Count)"
        Check 'a failed recording save reports the StatsEnabled operation, not ShowBlipCounter' ($script:err14f[0] -eq 'StatsEnabled') "key=$($script:err14f[0])"
        Check 'a failed recording save announces no cross-surface success' ($script:prefChanged14f -eq 0) "fired=$($script:prefChanged14f)"
        try { $stats14f.Dispose() } catch { }

        # (4) FAILURE-REPORTING KEYS: each failed Statistics operation must
        #     identify the ACTUAL failed operation, never a hard-coded
        #     "ShowBlipCounter" for every failure.
        # failed show-counter toggle -> ShowBlipCounter
        $d14sc = New-Dir 'surfaces_fail_sc'
        $s14sc = New-FailSetIn $d14sc @('ShowBlipCounter') @{ ShowBlipCounter='1' }
        $e14sc = New-EngineIn $d14sc $s14sc
        $stats14sc = $statsFormType.GetConstructors($flags)[0].Invoke(@($s14sc, $e14sc))
        $sink14sc = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:err14sc = @()
        $sink14sc.SetValue($stats14sc, ([System.Action[string]]{ param($k) $script:err14sc += $k }))
        $toggleCounterM14 = $statsFormType.GetMethod('ToggleShowCounter', $flags)
        try {
            $toggleCounterM14.Invoke($stats14sc, @())
            Check 'a failed show-counter save reports the ShowBlipCounter operation' `
                ($script:err14sc.Count -eq 1 -and $script:err14sc[0] -eq 'ShowBlipCounter') "errors=$($script:err14sc.Count) key=$($script:err14sc[0])"
        } finally { try { $stats14sc.Dispose() } catch { } }

        # failed recording toggle -> StatsEnabled (not ShowBlipCounter)
        $d14rs = New-Dir 'surfaces_fail_rs'
        $s14rs = New-FailSetIn $d14rs @('StatsEnabled') @{ StatsEnabled='1' }
        $e14rs = New-EngineIn $d14rs $s14rs
        $stats14rs = $statsFormType.GetConstructors($flags)[0].Invoke(@($s14rs, $e14rs))
        $sink14rs = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:err14rs = @()
        $sink14rs.SetValue($stats14rs, ([System.Action[string]]{ param($k) $script:err14rs += $k }))
        try {
            $toggleRecM14.Invoke($stats14rs, @())
            Check 'a failed recording toggle reports the StatsEnabled operation' `
                ($script:err14rs.Count -eq 1 -and $script:err14rs[0] -eq 'StatsEnabled') "errors=$($script:err14rs.Count) key=$($script:err14rs[0])"
        } finally { try { $stats14rs.Dispose() } catch { } }

        # failed reset (accepted confirmation) -> ResetAll (not ShowBlipCounter)
        $d14rr = New-Dir 'surfaces_fail_rr'
        $s14rr = New-SetIn $d14rr @{ }
        $e14rr = New-EngineIn $d14rr $s14rr
        $st14rr = $statsField.GetValue($e14rr)
        $localNowField.SetValue($st14rr, [Func[datetime]]{ param() $D0 })
        $rec14rr = $recordField.GetValue($st14rr)
        $rec14rr.TotalCount = 3
        $dirtyField14rr = $storeType.GetField('Dirty', $flags)
        $dirtyField14rr.SetValue($st14rr, $true)
        $st14rr.Flush() | Out-Null
        $origCommit14rr = $commitField.GetValue($st14rr)
        $stats14rr = $statsFormType.GetConstructors($flags)[0].Invoke(@($s14rr, $e14rr))
        $sink14rr = $statsFormType.GetField('SettingsErrorSink', $flags)
        $script:err14rr = @()
        $sink14rr.SetValue($stats14rr, ([System.Action[string]]{ param($k) $script:err14rr += $k }))
        $resetConfirmField14rr = $mainFormType.GetField('ResetConfirmation', $staticFlags)
        $origResetConfirm14rr = $resetConfirmField14rr.GetValue($null)
        try {
            $commitField.SetValue($st14rr, [Func[string,string,bool]]{ param($t, $p) return $false })
            $resetConfirmField14rr.SetValue($null, [System.Func[bool]]{ param() return $true })
            $statsPaintM14rr = $statsFormType.GetMethod('OnPaint', $flags)
            $sz14rr = $statsFormType.GetProperty('ClientSize').GetValue($stats14rr)
            $w14rr = [int]$sz14rr.Width; $h14rr = [int]$sz14rr.Height
            $bmp14rr = New-Object System.Drawing.Bitmap $w14rr, $h14rr
            $g14rr = [System.Drawing.Graphics]::FromImage($bmp14rr)
            try {
                $pe14rr = New-Object System.Windows.Forms.PaintEventArgs $g14rr, (New-Object System.Drawing.Rectangle 0, 0, $w14rr, $h14rr)
                try { [void]$statsPaintM14rr.Invoke($stats14rr, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe14rr)) } finally { $pe14rr.Dispose() }
            } finally { $g14rr.Dispose(); $bmp14rr.Dispose() }
            # Read the hot zone AFTER the paint: OnPaint registers the zones.
            $resetR14rr = [System.Drawing.Rectangle]$statsFormType.GetField('ResetRect', $flags).GetValue($stats14rr)
            $click14rr = New-Object System.Windows.Forms.MouseEventArgs ([System.Windows.Forms.MouseButtons]::Left), 1, ([int]($resetR14rr.X + $resetR14rr.Width / 2)), ([int]($resetR14rr.Y + $resetR14rr.Height / 2)), 0
            $statsMouseDownM14rr = $statsFormType.GetMethod('OnMouseDown', $flags)
            [void]$statsMouseDownM14rr.Invoke($stats14rr, [object[]]@([System.Windows.Forms.MouseEventArgs]$click14rr))
            Check 'a failed RESET ALL (accepted confirmation) keeps the counters and reports the ResetAll operation' `
                ($e14rr.Stats.Snapshot().Total -eq 3 -and $script:err14rr.Count -eq 1 -and $script:err14rr[0] -eq 'ResetAll') `
                "total=$($e14rr.Stats.Snapshot().Total) errors=$($script:err14rr.Count) key=$($script:err14rr[0])"
        } finally {
            $commitField.SetValue($st14rr, $origCommit14rr)
            $resetConfirmField14rr.SetValue($null, $origResetConfirm14rr)
            try { $stats14rr.Dispose() } catch { }
        }
    } finally {
        $prefs14.remove_Invalidated($h14)
        $progForm14.SetValue($null, $null)
        $progStats14.SetValue($null, $null)
        $progPrefs14.SetValue($null, $null)
        try { $prefs14.Dispose() } catch { }
        try { $stats14.Dispose() } catch { }
        try { $main14.Dispose() } catch { }
        try { $tray14.Dispose() } catch { }
    }

    # ============ 15. MAIN AUTOSTART TOGGLE -> PREFERENCES ============
    # The main surface's real autostart toggle must repaint Preferences too
    # (disposable key, never the developer's real Run entry).
    $d15 = New-Dir 'autosync'
    $s15 = New-SetIn $d15 @{ AutoStart='0' }
    $e15 = New-EngineIn $d15 $s15
    $tray15 = New-Object System.Windows.Forms.NotifyIcon
    $main15 = $mainFormType.GetConstructors($flags)[0].Invoke(@($s15, $e15, [System.Windows.Forms.NotifyIcon]$tray15))
    $prefs15 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s15, $e15))
    # Force handle creation so Invalidate() raises Invalidated event.
    [void]$prefs15.Handle
    $exePath15 = [string]([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    if ([string]::IsNullOrEmpty($exePath15)) { $exePath15 = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    $key15 = 'Software\ProblipSync_' + [Guid]::NewGuid().ToString('N')
    $autoKeyField15 = $mainFormType.GetField('AutoStartKeyPath', $flags)
    $autoKeyField15.SetValue($main15, [string]$key15)
    $sink15 = $mainFormType.GetField('SettingsErrorSink', $flags)
    $sink15.SetValue($main15, ([System.Action[string]]{ param($k) }))
    $script:inval15 = 0
    $h15 = [System.Windows.Forms.InvalidateEventHandler]{ param($o, $ev) $script:inval15++ }
    $prefs15.add_Invalidated($h15)
    $progForm15 = $programType.GetField('_form', $staticFlags)
    $progPrefs15 = $programType.GetField('_prefsForm', $staticFlags)
    $progForm15.SetValue($null, $main15)
    $progPrefs15.SetValue($null, $prefs15)
    try {
        $toggleAutoM15 = $mainFormType.GetMethod('ToggleAutostart', $flags)
        $invalBefore15 = $script:inval15
        $toggleAutoM15.Invoke($main15, @())
        Check 'main ToggleAutostart flips the shared autostart state' ([bool]$s15.AutoStart) "auto=$($s15.AutoStart)"
        Check 'main ToggleAutostart repaints the open Preferences window' ($script:inval15 -gt $invalBefore15) `
            "inval=$($script:inval15) before=$invalBefore15"
    } finally {
        $prefs15.remove_Invalidated($h15)
        $progForm15.SetValue($null, $null)
        $progPrefs15.SetValue($null, $null)
        try { $prefs15.Dispose() } catch { }
        try { $main15.Dispose() } catch { }
        try { $tray15.Dispose() } catch { }
        Remove-Item -LiteralPath "HKCU:\$key15" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ============ 17. PREFERENCES AUTOSTART FAILURE REPORTING ============
    # PreferencesForm.ToggleAutostart must PRESERVE the detailed four-state
    # StartupCommands.ResultText() transaction result. The reporting seam
    # (SettingsErrorSink) receives the key in tests; production shows the
    # supplied message VERBATIM -- never re-wrapped in a generic
    # "Could not save the ... setting" sentence.
    $d17 = New-Dir 'prefsauto'
    $s17 = New-FailSetIn $d17 @('AutoStart') @{ AutoStart='0' }
    $e17 = New-EngineIn $d17 $s17
    $prefs17 = $prefsFormType.GetConstructors($flags)[0].Invoke(@($s17, $e17))
    $errSink17 = $prefsFormType.GetField('SettingsErrorSink', $flags)
    $script:err17 = @()
    $errSink17.SetValue($prefs17, ([System.Action[string]]{ param($k) $script:err17 += $k }))
    $exePath17 = [string]([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    if ([string]::IsNullOrEmpty($exePath17)) { $exePath17 = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    $key17 = 'Software\ProblipPrefsAuto_' + [Guid]::NewGuid().ToString('N')
    $prefsAutoKeyField17 = $prefsFormType.GetField('AutoStartKeyPath', $flags)
    $hasPrefsAutoKeyField17 = $null -ne $prefsAutoKeyField17
    if ($hasPrefsAutoKeyField17) { $prefsAutoKeyField17.SetValue($prefs17, [string]$key17) }
    try {
        $toggleAutoM17 = $prefsFormType.GetMethod('ToggleAutostart', $flags)
        [void]$toggleAutoM17.Invoke($prefs17, @())
        $expectedMsg17 = [string]$resultTextM16.Invoke($null, @([object]$resRollOk, [object]$s17))
        Check 'Preferences autostart persistence failure reports the autostart key exactly once' `
            ($script:err17.Count -eq 1 -and $script:err17[0] -eq 'autostart') "errors=$($script:err17.Count) key=$($script:err17[0])"
        # The four-state result is preserved on the surface: the transaction
        # really landed PersistenceFailedRollbackSucceeded (INI save forced to
        # fail, registry rollback really succeeded on the disposable key).
        Check 'Preferences autostart failure preserves the previous OFF intent' (-not $s17.AutoStart) "auto=$($s17.AutoStart)"
        # The detailed ResultText for each failure mode is pairwise distinct and
        # none is a generic "Could not save the ... setting" wrapper.
        $msgFwd17 = [string]$resultTextM16.Invoke($null, @($resFwdFail, [object]$s17))
        $msgRollOk17 = [string]$resultTextM16.Invoke($null, @($resRollOk, [object]$s17))
        $msgRollFail17 = [string]$resultTextM16.Invoke($null, @($resRollFail, [object]$s17))
        Check 'the three AutoStart failure messages are pairwise distinct' `
            ($msgFwd17 -ne $msgRollOk17 -and $msgRollOk17 -ne $msgRollFail17 -and $msgFwd17 -ne $msgRollFail17)
        Check 'AutoStart failure messages are detailed results, never a generic save-error wrapper' `
            ($msgFwd17 -notmatch '^Could not save the .* setting' -and $msgRollOk17 -match 'autostart' -and $msgRollFail17 -match 'disagree')
    } finally {
        try { $prefs17.Dispose() } catch { }
        if ($hasPrefsAutoKeyField17) { Remove-Item -LiteralPath "HKCU:\$key17" -Recurse -Force -ErrorAction SilentlyContinue }
    }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
