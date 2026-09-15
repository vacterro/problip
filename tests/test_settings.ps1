$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled variable must FAIL the harness
# immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
# The shipped asset, so engine-based cases exercise a loadable sound instead of
# a missing one.
$RealWav = Join-Path $root 'blip01.wav'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_settings_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

try {
    $dll = Join-Path $work 'Problip.dll'
    # The test-only Settings subclass is compiled together with the subject so
    # its Save() can fail chosen keys on demand -- the production Settings stays
    # untouched and the override lives only in the harness.
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
    $type = $asm.GetType('Problip.Settings', $true)
    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $ctor = $type.GetConstructor($flags, $null, @([string]), $null)
    $failCtor = $asm.GetType('Problip.FailSettings', $true).GetConstructor($flags, $null, @([string]), $null)
    $save = $type.GetMethod('Save')
    $dir = Join-Path $work 'state'; New-Item -ItemType Directory -Path $dir | Out-Null

    function New-Set([hashtable]$kv) {
        $d = Join-Path $work ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        if ($kv) {
            $sb = New-Object Text.StringBuilder("[problip]`r`n")
            foreach ($k in $kv.Keys) { [void]$sb.AppendLine("$k=$($kv[$k])") }
            Set-Content -LiteralPath (Join-Path $d 'problip.ini') -Value $sb.ToString() -NoNewline
        }
        $s = $ctor.Invoke(@([string]$d))
        $s.Load()
        return $s
    }

    # Canonical defaults pulled from the constants: tests bind to the real source.
    $defaults = @{
        Volume = ([double]$type.GetField('DefaultVolume', [Reflection.BindingFlags]'Public,Static').GetValue($null))
        MinMs  = ([int]$type.GetField('DefaultMinMs',   [Reflection.BindingFlags]'Public,Static').GetValue($null))
        MaxMs  = ([int]$type.GetField('DefaultMaxMs',   [Reflection.BindingFlags]'Public,Static').GetValue($null))
    }

    # 1. ordinary valid round trip
    $r = New-Set @{ Volume='0.42'; MinMs='1234'; MaxMs='5678'; AutoStart='0' }
    Check 'settings load/save round-trip' `
        ($r.Volume -eq 0.42 -and $r.MinMs -eq 1234 -and $r.MaxMs -eq 5678 -and -not $r.AutoStart) `
        "Volume=$($r.Volume) MinMs=$($r.MinMs) MaxMs=$($r.MaxMs) AutoStart=$($r.AutoStart)"

    # 2. invalid strings fall back to intentional defaults (not TryParse zeros)
    $r = New-Set @{ Volume='abc'; MinMs='notanumber'; MaxMs='xyz' }
    Check 'invalid Volume string -> default 0.05' ($r.Volume -eq $defaults.Volume) "Volume=$($r.Volume)"
    Check 'invalid MinMs string -> default' ($r.MinMs -eq $defaults.MinMs) "MinMs=$($r.MinMs)"
    Check 'invalid MaxMs string -> default' ($r.MaxMs -eq $defaults.MaxMs) "MaxMs=$($r.MaxMs)"

    # 3. negative Volume clamps to 0; above 1 clamps to 1; only negatives via out-of-range go to default
    $r = New-Set @{ Volume='-0.5' }
    Check 'negative Volume clamps to 0' ($r.Volume -eq 0.0) "Volume=$($r.Volume)"
    $r = New-Set @{ Volume='1.5' }
    Check 'Volume above 1.0 clamps to 1.0' ($r.Volume -eq 1.0) "Volume=$($r.Volume)"

    # 4. values above the ms ceiling clamp into range
    $r = New-Set @{ MinMs='90000'; MaxMs='100000' }
    Check 'MinMs above ceiling clamps into range' ($r.MinMs -ge 1000 -and $r.MinMs -le 60000) "MinMs=$($r.MinMs)"
    Check 'MaxMs above ceiling clamps into range' ($r.MaxMs -ge 1000 -and $r.MaxMs -le 60000) "MaxMs=$($r.MaxMs)"
    Check 'the Min<=Max invariant holds after both-above-max' ($r.MinMs -le $r.MaxMs)

    # 5. Min > Max normalizes (MaxMs collapses to MinMs so the range is valid)
    $r = New-Set @{ MinMs='6000'; MaxMs='2000' }
    Check 'Min > Max normalizes into a valid range' `
        ($r.MinMs -le $r.MaxMs -and $r.MinMs -ge 1000 -and $r.MaxMs -le 60000) `
        "MinMs=$($r.MinMs) MaxMs=$($r.MaxMs)"

    # 6. settings always satisfy the canonical invariants
    $r = New-Set @{ Volume='-3'; MinMs='0'; MaxMs='-9'; AutoStart='junk' }
    Check 'every Load() result satisfies the canonical invariants' `
        ($r.Volume -ge 0.0 -and $r.Volume -le 1.0 -and
         $r.MinMs -ge 1000 -and $r.MinMs -le 60000 -and
         $r.MaxMs -ge 1000 -and $r.MaxMs -le 60000 -and
         $r.MinMs -le $r.MaxMs) `
        "Volume=$($r.Volume) MinMs=$($r.MinMs) MaxMs=$($r.MaxMs) AutoStart=$($r.AutoStart)"

    # 7. a failed INI write is observable, not silently swallowed. IniPath
    #    pointed at a DIRECTORY makes WritePrivateProfileString fail without
    #    touching any real user state; Save must surface that as IOException.
    $ro = $ctor.Invoke(@([string](Join-Path $work 'ro')))
    $ro.IniPath = $work   # a directory: cannot be an INI file
    $threw = $false
    try { $ro.Save('Volume', '0.5') } catch [IO.IOException] { $threw = $true }
    Check 'a failed settings write throws IOException (detectable)' $threw

    # 8. a read-only location must not break Load(): defaults stay in memory
    #    and startup does not crash over an unwritable INI.
    $ro2 = $ctor.Invoke(@([string]$work))
    $ro2.IniPath = $work   # directory again: Load()'s fresh-write cannot land
    $loaded = $true
    try { $ro2.Load() } catch { $loaded = $false }
    Check 'Load() survives an unwritable INI location' $loaded
    Check 'Load() still produces valid defaults from an unwritable location' `
        ($ro2.Volume -ge 0.0 -and $ro2.Volume -le 1.0 -and $ro2.MinMs -le $ro2.MaxMs) `
        "Volume=$($ro2.Volume) MinMs=$($ro2.MinMs) MaxMs=$($ro2.MaxMs)"

    # ---- 9-13: user-triggered persistence failures must visibly revert ----
    # A failing Save is simulated by a Settings subclass compiled together with
    # the subject, whose Save throws on chosen keys; the form-level rollback
    # behavior is exercised through the real ProblipForm methods, with the error
    # sink swapped in for the MessageBox.
    Add-Type -AssemblyName System.Windows.Forms
    $formType = $asm.GetType('Problip.ProblipForm', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $endDrag = $formType.GetMethod('EndVolumeDrag', $flags)
    $applyRange = $formType.GetMethod('ApplyRange', $flags)
    $toggleAuto = $formType.GetMethod('ToggleAutostart', $flags)
    $setVolume = $formType.GetMethod('SetVolumeFromX', $flags)
    $startDrag = $formType.GetMethod('StartVolumeDrag', $flags)
    $autoStartKeyField = $formType.GetField('AutoStartKeyPath', $flags)
    $sinkField = $formType.GetField('SettingsErrorSink', $flags)
    $volTrackField = $formType.GetField('VolTrack', $flags)
    $autoStartEnabled = $formType.GetMethod('AutoStartEnabled', $flags)

    function New-FailSettings([string]$dir, [string[]]$failKeys, [hashtable]$kv) {
        $s = $failCtor.Invoke(@([string]$dir))
        $s.FailKeys = [System.Collections.Generic.List[string]]$failKeys
        if ($kv) {
            $sb = New-Object Text.StringBuilder("[problip]`r`n")
            foreach ($k in $kv.Keys) { [void]$sb.AppendLine("$k=$($kv[$k])") }
            Set-Content -LiteralPath (Join-Path $dir 'problip.ini') -Value $sb.ToString() -NoNewline
        }
        $s.Load()
        # W2-002: interval transactions no longer route through Save(); they use
        # the IntervalWrite candidate seam. Bridge FailKeys onto that seam so
        # the same key-based fault injection keeps working for interval cases.
        if ($failKeys -and $failKeys.Count -gt 0) {
            $fk = [System.Collections.Generic.List[string]]$failKeys
            $iwField = $type.GetField('IntervalWrite', $flags)
            $origIW = $iwField.GetValue($s)
            $wrap = { param($path, $key, $val)
                if ($fk.Contains($key)) { return $false }
                return $origIW.Invoke($path, $key, $val) }.GetNewClosure()
            $iwField.SetValue($s, [Func[string,string,string,bool]]$wrap)
        }
        return $s
    }

    function New-FormFor($settings) {
        # A disposable registry key stands in for the real Run key, so the
        # autostart toggles never touch the developer's machine state.
        $engine = $engineType.GetConstructors($flags)[0].Invoke(@($settings))
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $form = $formType.GetConstructors($flags)[0].Invoke([object[]]@($settings, $engine, [System.Windows.Forms.NotifyIcon]$tray))
        $key = 'Software\ProblipTest_' + [Guid]::NewGuid().ToString('N')
        $autoStartKeyField.SetValue($form, [string]$key)
        $script:forms += $form; $script:trays += $tray; $script:engines += $engine; $script:regKeys += $key
        return $form
    }

    $script:forms = @(); $script:trays = @(); $script:engines = @(); $script:regKeys = @()

    # 9. failed volume commit restores the previous committed volume
    $dir9 = Join-Path $work 'v9'; New-Item -ItemType Directory -Path $dir9 | Out-Null
    $s9 = New-FailSettings $dir9 @('Volume') @{ Volume='0.20' }
    $f9 = New-FormFor $s9
    $notices = [System.Collections.Generic.List[string]]::new()
    $sink9 = [System.Action[string]]{ param($k) $notices.Add($k) }
    $sinkField.SetValue($f9, $sink9)
    $volTrackField.SetValue($f9, (New-Object System.Drawing.Rectangle 36, 34, 168, 12))
    $startDrag.Invoke($f9, @())
    $setVolume.Invoke($f9, @(200))   # far right of the track -> ~1.0
    $endDrag.Invoke($f9, @())
    Check 'a failed volume commit restores the previous committed volume' `
        ([Math]::Abs($s9.Volume - 0.20) -lt 1e-9) "Volume=$($s9.Volume)"
    Check 'a failed volume commit reports the failure exactly once' ($notices.Count -eq 1 -and $notices[0] -eq 'volume') "notices=$($notices -join ',')"
    $eng9 = $script:engines[-1]
    Check 'a failed volume commit does NOT preview the rejected value' ($eng9.PreviewCount -eq 0) "previews=$($eng9.PreviewCount)"

    # 9b. a successful volume commit rebuilds the cache at the new volume and
    #     previews exactly once
    $dir9b = Join-Path $work 'v9b'; New-Item -ItemType Directory -Path $dir9b | Out-Null
    $s9b = New-FailSettings $dir9b @() @{ Volume='0.20' }
    $s9b.WavPath = [string]$RealWav
    $f9b = New-FormFor $s9b
    $sinkField.SetValue($f9b, ([System.Action[string]]{ param($k) }))
    $volTrackField.SetValue($f9b, (New-Object System.Drawing.Rectangle 36, 34, 168, 12))
    $startDrag.Invoke($f9b, @())
    $setVolume.Invoke($f9b, @(200))   # -> ~1.0
    $endDrag.Invoke($f9b, @())
    $eng9b = $script:engines[-1]
    $cache9b = $engineType.GetField('CachePath', $flags).GetValue($eng9b)
    Check 'a successful volume commit keeps the committed volume' ([Math]::Abs($s9b.Volume - 1.0) -lt 1e-9) "Volume=$($s9b.Volume)"
    Check 'a successful volume commit requests exactly one preview' ($eng9b.PreviewCount -eq 1) "previews=$($eng9b.PreviewCount)"
    Check 'a successful volume commit rebuilds the cache' ($null -ne $cache9b -and (Test-Path -LiteralPath $cache9b)) "cache=$cache9b"

    # 9c. the commit path preserves the periodic countdown: a reload while ON
    #     must NOT redraw the pending due time
    $dir9c = Join-Path $work 'v9c'; New-Item -ItemType Directory -Path $dir9c | Out-Null
    $s9c = New-FailSettings $dir9c @() @{ Volume='0.20'; MinMs='30000'; MaxMs='30000' }
    $s9c.WavPath = [string]$RealWav
    $f9c = New-FormFor $s9c
    $sinkField.SetValue($f9c, ([System.Action[string]]{ param($k) }))
    $volTrackField.SetValue($f9c, (New-Object System.Drawing.Rectangle 36, 34, 168, 12))
    $startDrag.Invoke($f9c, @())
    $setVolume.Invoke($f9c, @(200))
    $eng9c = $script:engines[-1]
            $eng9c.Start()
            $nextDueField = $engineType.GetField('NextDueMs', $flags)
            $nowMsField = $engineType.GetField('NowMs', $flags)
            $nextDueField.SetValue($eng9c, [long]$nowMsField.GetValue($eng9c).Invoke() + 5000)
    $dueBefore9c = [long]$nextDueField.GetValue($eng9c)
    $endDrag.Invoke($f9c, @())
    $dueAfter9c = [long]$nextDueField.GetValue($eng9c)
    Check 'a successful volume commit while ON preserves the pending countdown' `
        ([Math]::Abs($dueAfter9c - $dueBefore9c) -lt 150) "before=$dueBefore9c after=$dueAfter9c"
    Check 'a successful volume commit while ON stays ON' ($eng9c.IsOn) "on=$($eng9c.IsOn)"

    # 10. failed interval commit leaves the old range active
    $dir10 = Join-Path $work 'v10'; New-Item -ItemType Directory -Path $dir10 | Out-Null
    $s10 = New-FailSettings $dir10 @('MinMs') @{ MinMs='4000'; MaxMs='7000' }
    $f10 = New-FormFor $s10
    $notices10 = [System.Collections.Generic.List[string]]::new()
    $sink10 = [System.Action[string]]{ param($k) $notices10.Add($k) }
    $sinkField.SetValue($f10, $sink10)
    $applyRange.Invoke($f10, @(10000, 15000))
    Check 'a failed interval commit keeps the old Settings range' ($s10.MinMs -eq 4000 -and $s10.MaxMs -eq 7000) "MinMs=$($s10.MinMs) MaxMs=$($s10.MaxMs)"
    $eng10 = $script:engines[-1]
    Check 'a failed interval commit keeps the old engine range' ($eng10.MinMs -eq 4000 -and $eng10.MaxMs -eq 7000) "engine=$($eng10.MinMs)-$($eng10.MaxMs)"
    Check 'a failed interval commit reports the failure' ($notices10.Count -eq 1 -and $notices10[0] -eq 'interval') "notices=$($notices10 -join ',')"

    # 11. partial MinMs/MaxMs commit attempts rollback and reports failure
    $dir11 = Join-Path $work 'v11'; New-Item -ItemType Directory -Path $dir11 | Out-Null
    $s11 = New-FailSettings $dir11 @('MaxMs') @{ MinMs='4000'; MaxMs='7000' }
    $f11 = New-FormFor $s11
    $notices11 = [System.Collections.Generic.List[string]]::new()
    $sink11 = [System.Action[string]]{ param($k) $notices11.Add($k) }
    $sinkField.SetValue($f11, $sink11)
    $applyRange.Invoke($f11, @(5000, 5000))
    Check 'a partial interval commit restores the old Settings range' ($s11.MinMs -eq 4000 -and $s11.MaxMs -eq 7000) "MinMs=$($s11.MinMs) MaxMs=$($s11.MaxMs)"
    Check 'a partial interval commit reports the failure' ($notices11.Count -eq 1 -and $notices11[0] -eq 'interval') "notices=$($notices11 -join ',')"
    $ini11 = Get-Content -LiteralPath (Join-Path $dir11 'problip.ini') -Raw
    Check 'a partial interval commit rolls the first key back to its old value' ($ini11 -match 'MinMs=4000') $ini11.Trim()

    # 12. failed autostart INI commit restores S.AutoStart
    $dir12 = Join-Path $work 'v12'; New-Item -ItemType Directory -Path $dir12 | Out-Null
    $s12 = New-FailSettings $dir12 @('AutoStart') @{ AutoStart='0' }
    $f12 = New-FormFor $s12
    $notices12 = [System.Collections.Generic.List[string]]::new()
    $sink12 = [System.Action[string]]{ param($k) $notices12.Add($k) }
    $sinkField.SetValue($f12, $sink12)
    $before12 = [bool]$autoStartEnabled.Invoke($f12, @())
    $toggleAuto.Invoke($f12, @())
    Check 'a failed autostart commit restores S.AutoStart in memory' (-not $s12.AutoStart) "AutoStart=$($s12.AutoStart)"
    Check 'a failed autostart commit reports the failure' ($notices12.Count -eq 1) "notices=$($notices12 -join ',')"
    $after12 = [bool]$autoStartEnabled.Invoke($f12, @())
    Check 'a failed autostart commit leaves the registry rolled back' ($after12 -eq $before12) "before=$before12 after=$after12"

    # 13. a successful interval commit moves both Settings and engine range
    $dir13 = Join-Path $work 'v13'; New-Item -ItemType Directory -Path $dir13 | Out-Null
    $s13 = New-FailSettings $dir13 @() @{ MinMs='4000'; MaxMs='7000' }
    $f13 = New-FormFor $s13
    $notices13 = [System.Collections.Generic.List[string]]::new()
    $sink13 = [System.Action[string]]{ param($k) $notices13.Add($k) }
    $sinkField.SetValue($f13, $sink13)
    $applyRange.Invoke($f13, @(10000, 15000))
    Check 'a successful interval commit updates the Settings range' ($s13.MinMs -eq 10000 -and $s13.MaxMs -eq 15000) "MinMs=$($s13.MinMs) MaxMs=$($s13.MaxMs)"
    $ini13 = Get-Content -LiteralPath (Join-Path $dir13 'problip.ini') -Raw
    Check 'a successful interval commit persists both keys' ($ini13 -match 'MinMs=10000' -and $ini13 -match 'MaxMs=15000') $ini13.Trim()
    Check 'a successful interval commit reports nothing' ($notices13.Count -eq 0) "notices=$($notices13 -join ',')"

    # ---- 14-24: interval mode (Range / Manual / Pulse) ----
    # Kind + bounds are new persisted state. Old INIs must stay Range with their
    # existing MinMs/MaxMs; malformed values normalize; every mode round-trips;
    # a failed multi-key interval save restores the previous configuration and
    # leaves the INI/session/UI on the mode it rejected.
    $modelType = $asm.GetType('Problip.IntervalModel', $true)
    if ($null -eq $modelType) { Check 'the interval model exists' $false 'Problip.IntervalModel missing' }
    $applyManual = $formType.GetMethod('ApplyManual', $flags)
    $applyPulse = $formType.GetMethod('ApplyPulse', $flags)
    $kindField = $type.GetField('Kind', $flags)
    $fromField = $type.GetField('ManualFromSec', $flags)
    $toField = $type.GetField('ManualToSec', $flags)
    $engineKindField = $engineType.GetField('Kind', $flags)
    $kindRange = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Range')
    $kindManual = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Manual')
    $kindPulse = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Pulse')
    $iniOf = { param($d) Get-Content -LiteralPath (Join-Path $d 'problip.ini') -Raw }

    # 14. an old INI without IntervalKind stays Range with its own timings
    $s14 = New-Set @{ MinMs='10000'; MaxMs='10000' }
    Check 'an old INI without IntervalKind stays Range' ($kindField.GetValue($s14) -eq $kindRange) "kind=$($kindField.GetValue($s14))"
    Check 'an old INI keeps its own MinMs/MaxMs authoritative' ($s14.MinMs -eq 10000 -and $s14.MaxMs -eq 10000) "Min=$($s14.MinMs) Max=$($s14.MaxMs)"

    # 15. malformed IntervalKind normalizes to Range
    $s15 = New-Set @{ IntervalKind='bogus'; MinMs='15000'; MaxMs='15000' }
    Check 'a malformed IntervalKind normalizes to Range' ($kindField.GetValue($s15) -eq $kindRange) "kind=$($kindField.GetValue($s15))"

    # 16. fresh defaults: ManualFromSec=4 / ManualToSec=7
    $s16 = New-Set $null
    Check 'fresh settings default ManualFromSec to 4' ([int]$fromField.GetValue($s16) -eq 4) "from=$([int]$fromField.GetValue($s16))"
    Check 'fresh settings default ManualToSec to 7' ([int]$toField.GetValue($s16) -eq 7) "to=$([int]$toField.GetValue($s16))"
    $ini16 = & $iniOf (Join-Path $work ([System.IO.Path]::GetFileName($s16.Dir)))
    Check 'the fresh INI stores 4/7 for the manual bounds' `
        ($ini16 -match 'ManualFromSec=4' -and $ini16 -match 'ManualToSec=7') $ini16.Trim()

    # 17. malformed manual bounds fall back to 4/7
    $s17 = New-Set @{ IntervalKind='manual'; ManualFromSec='x'; ManualToSec='y' }
    Check 'malformed manual bounds fall back to 4/7' `
        ([int]$fromField.GetValue($s17) -eq 4 -and [int]$toField.GetValue($s17) -eq 7) `
        "from=$([int]$fromField.GetValue($s17)) to=$([int]$toField.GetValue($s17))"

    # 18. persisted 10/5 normalizes to 5/10
    $s18 = New-Set @{ IntervalKind='manual'; ManualFromSec='10'; ManualToSec='5' }
    Check 'a persisted 10/5 manual range normalizes to 5/10' `
        ([int]$fromField.GetValue($s18) -eq 5 -and [int]$toField.GetValue($s18) -eq 10) `
        "from=$([int]$fromField.GetValue($s18)) to=$([int]$toField.GetValue($s18))"

    # 19. clamp 0/9999 -> 1/3600
    $s19 = New-Set @{ IntervalKind='manual'; ManualFromSec='0'; ManualToSec='9999' }
    Check 'manual bounds clamp into 1..3600' `
        ([int]$fromField.GetValue($s19) -eq 1 -and [int]$toField.GetValue($s19) -eq 3600) `
        "from=$([int]$fromField.GetValue($s19)) to=$([int]$toField.GetValue($s19))"

    # 20. Range round trip (kind + both ms keys)
    $r20 = New-Set @{ IntervalKind='pulse'; MinMs='20000'; MaxMs='20000' }
    $f20 = New-FormFor $r20
    $sinkField.SetValue($f20, ([System.Action[string]]{ param($k) }))
    $applyRange.Invoke($f20, @(10000, 15000))
    Check 'a Range selection persists kind + both ms keys' `
        (($kindField.GetValue($r20) -eq $kindRange) -and (( & $iniOf $r20.Dir) -match 'IntervalKind=range') -and (( & $iniOf $r20.Dir) -match 'MinMs=10000') -and (( & $iniOf $r20.Dir) -match 'MaxMs=15000')) `
        ("kind=$($kindField.GetValue($r20)) " + (& $iniOf $r20.Dir).Trim())
    $eng20 = $script:engines[-1]
    Check 'a Range selection moves the engine to Range with the new bounds' `
        (($engineKindField.GetValue($eng20) -eq $kindRange) -and $eng20.MinMs -eq 10000 -and $eng20.MaxMs -eq 15000) `
        "engineKind=$($engineKindField.GetValue($eng20)) min=$($eng20.MinMs) max=$($eng20.MaxMs)"

    # 21. Manual round trip
    $r21 = New-Set @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000'; ManualFromSec='4'; ManualToSec='7' }
    $f21 = New-FormFor $r21
    $sinkField.SetValue($f21, ([System.Action[string]]{ param($k) }))
    [void]$applyManual.Invoke($f21, @(2, 4))
    Check 'a Manual APPLY persists the manual bounds and the kind' `
        (($kindField.GetValue($r21) -eq $kindManual) -and (( & $iniOf $r21.Dir) -match 'ManualFromSec=2') -and (( & $iniOf $r21.Dir) -match 'ManualToSec=4') -and (( & $iniOf $r21.Dir) -match 'IntervalKind=manual')) `
        ("kind=$($kindField.GetValue($r21)) " + (& $iniOf $r21.Dir).Trim())
    $eng21 = $script:engines[-1]
    $manualMinF = $engineType.GetField('ManualMinMs', $flags)
    Check 'a Manual APPLY resolves the bounds to milliseconds on the engine' `
        (($engineKindField.GetValue($eng21) -eq $kindManual) -and ([int]$manualMinF.GetValue($eng21)) -eq 2000) `
        "engineKind=$($engineKindField.GetValue($eng21)) min=$([int]$manualMinF.GetValue($eng21))"
    Check 'a Manual APPLY leaves the ordinary Range bounds untouched' ($r21.MinMs -eq 4000 -and $r21.MaxMs -eq 7000) "Min=$($r21.MinMs) Max=$($r21.MaxMs)"

    # 22. Pulse round trip
    $r22 = New-Set @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000' }
    $f22 = New-FormFor $r22
    $sinkField.SetValue($f22, ([System.Action[string]]{ param($k) }))
    $applyPulse.Invoke($f22, @())
    Check 'a Pulse selection persists only the kind' (($kindField.GetValue($r22) -eq $kindPulse) -and (( & $iniOf $r22.Dir) -match 'IntervalKind=pulse'))`
        ("kind=$($kindField.GetValue($r22)) " + (& $iniOf $r22.Dir).Trim())
    $eng22 = $script:engines[-1]
    Check 'a Pulse selection moves the engine to Pulse' (($engineKindField.GetValue($eng22) -eq $kindPulse)) "engineKind=$($engineKindField.GetValue($eng22))"
    Check 'a Pulse selection leaves the ordinary Range bounds intact' `
        (( & $iniOf $r22.Dir) -match 'MinMs=4000' -and ( & $iniOf $r22.Dir) -match 'MaxMs=7000') (& $iniOf $r22.Dir).Trim()

    # 23. a failed Manual multi-key save restores the previous configuration
    $dir23 = Join-Path $work 'v23'; New-Item -ItemType Directory -Path $dir23 | Out-Null
    $s23 = New-FailSettings $dir23 @('ManualToSec') @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000'; ManualFromSec='4'; ManualToSec='7' }
    $f23 = New-FormFor $s23
    $notices23 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($f23, ([System.Action[string]]{ param($k) $notices23.Add($k) }))
    $ok23 = [bool]$applyManual.Invoke($f23, @(60, 90))
    Check 'a failed Manual save reports failure and keeps the previous mode' `
        (-not $ok23 -and ($kindField.GetValue($s23) -eq $kindRange) -and $notices23.Count -eq 1) `
        "ok=$ok23 kind=$($kindField.GetValue($s23)) notices=$($notices23 -join ',')"
    Check 'a failed Manual save restores the previous manual bounds' `
        ([int]$fromField.GetValue($s23) -eq 4 -and [int]$toField.GetValue($s23) -eq 7) `
        "from=$([int]$fromField.GetValue($s23)) to=$([int]$toField.GetValue($s23))"
    $ini23 = & $iniOf $dir23
    Check 'a failed Manual save restores the already-written key' ($ini23 -match 'ManualFromSec=4') $ini23.Trim()
    $eng23 = $script:engines[-1]
    Check 'a failed Manual save leaves the engine on the previous configuration' `
        (($engineKindField.GetValue($eng23) -eq $kindRange) -and $eng23.MinMs -eq 4000 -and $eng23.MaxMs -eq 7000) `
        "engineKind=$($engineKindField.GetValue($eng23)) min=$($eng23.MinMs) max=$($eng23.MaxMs)"

    # 24. a failed Range-mode save / failed Pulse selection leave state intact
    $dir24 = Join-Path $work 'v24'; New-Item -ItemType Directory -Path $dir24 | Out-Null
    $s24 = New-FailSettings $dir24 @('MaxMs') @{ IntervalKind='pulse'; MinMs='4000'; MaxMs='7000' }
    $f24 = New-FormFor $s24
    $notices24 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($f24, ([System.Action[string]]{ param($k) $notices24.Add($k) }))
    $applyRange.Invoke($f24, @(30000, 30000))
    Check 'a failed Range-mode save keeps the previous mode and bounds' `
        (($kindField.GetValue($s24) -eq $kindPulse) -and $s24.MinMs -eq 4000 -and $s24.MaxMs -eq 7000 -and $notices24.Count -eq 1) `
        "kind=$($kindField.GetValue($s24)) Min=$($s24.MinMs) Max=$($s24.MaxMs)"
    $eng24 = $script:engines[-1]
    Check 'a failed Range-mode save leaves the engine unchanged' `
        (($engineKindField.GetValue($eng24) -eq $kindPulse) -and $eng24.MinMs -eq 4000 -and $eng24.MaxMs -eq 7000) `
        "engineKind=$($engineKindField.GetValue($eng24))"

    $dir25 = Join-Path $work 'v25'; New-Item -ItemType Directory -Path $dir25 | Out-Null
    $s25 = New-FailSettings $dir25 @('IntervalKind') @{ IntervalKind='range'; MinMs='10000'; MaxMs='10000' }
    $f25 = New-FormFor $s25
    $notices25 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($f25, ([System.Action[string]]{ param($k) $notices25.Add($k) }))
    $applyPulse.Invoke($f25, @())
    Check 'a failed Pulse selection leaves the previous mode active' `
        (($kindField.GetValue($s25) -eq $kindRange) -and $notices25.Count -eq 1) `
        "kind=$($kindField.GetValue($s25)) notices=$($notices25 -join ',')"
    $eng25 = $script:engines[-1]
    Check 'a failed Pulse selection leaves the previous schedule active' `
        (($engineKindField.GetValue($eng25) -eq $kindRange) -and $eng25.MinMs -eq 10000) `
        "engineKind=$($engineKindField.GetValue($eng25)) min=$($eng25.MinMs)"

    # ---- 26-35: theme + glow preferences ----
    # ThemeId: absent/unknown/legacy all resolve to theme_classic; every valid
    # id round-trips. BlipGlow: absent/malformed default true, only exact "0"
    # is off. Failed saves keep the previous value active (persist-first
    # transaction), and a failed save never moves the global palette.
    $themeModelType2 = $asm.GetType('Problip.ThemeModel', $true)
    $themeById = $themeModelType2.GetMethod('ById', [Reflection.BindingFlags]'Static,Public,NonPublic')
    $themeAll = [object[]]$themeModelType2.GetField('All', [Reflection.BindingFlags]'Static,Public,NonPublic').GetValue($null)
    $paletteType2 = $asm.GetType('Problip.Palette', $true)
    $currentField2 = $paletteType2.GetField('Current', [Reflection.BindingFlags]'Static,NonPublic,Public')
    $themeIdField = $type.GetField('ThemeId', $flags)
    $glowField = $type.GetField('BlipGlow', $flags)
    $classicId = 'theme_classic'

    # 26. absent ThemeId => theme_classic
    $s26 = New-Set @{ Volume='0.10' }
    Check 'an absent ThemeId resolves to theme_classic' ($themeIdField.GetValue($s26) -eq $classicId) "theme=$($themeIdField.GetValue($s26))"

    # 27. unknown ThemeId => theme_classic (never a partial theme)
    $s27 = New-Set @{ ThemeId='theme_wintage_nope' }
    Check 'an unknown ThemeId resolves to theme_classic' ($themeIdField.GetValue($s27) -eq $classicId) "theme=$($themeIdField.GetValue($s27))"

    # 28. legacy theme_wintage_custom => theme_classic
    $s28 = New-Set @{ ThemeId='theme_wintage_custom' }
    Check 'the legacy theme_wintage_custom resolves to theme_classic' ($themeIdField.GetValue($s28) -eq $classicId) "theme=$($themeIdField.GetValue($s28))"

    # 29. every valid ThemeId round-trips
    $allOk29 = $true; $detail29 = ''
    foreach ($entry in $themeAll) {
        $eid = $entry.GetType().GetField('Id').GetValue($entry)
        $s29 = New-Set @{ ThemeId=[string]$eid }
        if ($themeIdField.GetValue($s29) -ne $eid) { $allOk29 = $false; $detail29 += "$eid->$($themeIdField.GetValue($s29)) " }
    }
    Check 'every valid ThemeId round-trips through Load()' $allOk29 $detail29

    # 30. absent BlipGlow => true; exact 0 => false; 1 => true; malformed => true
    $s30a = New-Set @{ Volume='0.5' }
    Check 'an absent BlipGlow defaults to ON' ([bool]$glowField.GetValue($s30a) -eq $true) "glow=$($glowField.GetValue($s30a))"
    $s30b = New-Set @{ BlipGlow='0' }
    Check 'BlipGlow=0 turns the glow OFF' ([bool]$glowField.GetValue($s30b) -eq $false) "glow=$($glowField.GetValue($s30b))"
    $s30c = New-Set @{ BlipGlow='1' }
    Check 'BlipGlow=1 keeps the glow ON' ([bool]$glowField.GetValue($s30c) -eq $true)
    $s30d = New-Set @{ BlipGlow='garbage' }
    Check 'a malformed BlipGlow defaults to ON' ([bool]$glowField.GetValue($s30d) -eq $true) "glow=$($glowField.GetValue($s30d))"

    # 31. failed ThemeId save: previous theme + palette stay active
    $dir31 = Join-Path $work 't31'; New-Item -ItemType Directory -Path $dir31 | Out-Null
    $s31 = New-FailSettings $dir31 @('ThemeId') @{ ThemeId='theme_classic' }
    $f31 = New-FormFor $s31
    $notices31 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($f31, ([System.Action[string]]{ param($k) $notices31.Add($k) }))
    $toggleGlowM = $formType.GetMethod('ToggleGlow', $flags)
    $applyThemeIdM = $asm.GetType('Problip.Program', $true).GetMethod('ApplyThemeId', [Reflection.BindingFlags]'Static,NonPublic,Public')
    if ($null -eq $applyThemeIdM) {
        Check 'the Program.ApplyThemeId transaction seam exists' $false 'not found'
    } else {
        $beforePalette = $currentField2.GetValue($null)
        $ok31 = [bool]$applyThemeIdM.Invoke($null, @([object]$s31, [string]'theme_wintage_dracula'))
        Check 'a failed ThemeId save reports failure and keeps the previous theme' `
            (-not $ok31 -and $themeIdField.GetValue($s31) -eq $classicId) "ok=$ok31 theme=$($themeIdField.GetValue($s31))"
        Check 'a failed ThemeId save leaves the previous palette active' ([object]::ReferenceEquals($beforePalette, $currentField2.GetValue($null)))
    }

    # 32. failed BlipGlow save: previous preference stays active
    $dir32 = Join-Path $work 't32'; New-Item -ItemType Directory -Path $dir32 | Out-Null
    $s32 = New-FailSettings $dir32 @('BlipGlow') @{ BlipGlow='1' }
    $f32 = New-FormFor $s32
    $notices32 = [System.Collections.Generic.List[string]]::new()
    $sinkField.SetValue($f32, ([System.Action[string]]{ param($k) $notices32.Add($k) }))
    $toggleGlowM.Invoke($f32, @())
    Check 'a failed BlipGlow save reports failure and keeps the previous preference' `
        (([bool]$glowField.GetValue($s32) -eq $true) -and $notices32.Count -eq 1) "glow=$($glowField.GetValue($s32)) notices=$($notices32 -join ',')"

    # 33. successful theme save: ThemeId + palette move together
    $dir33 = Join-Path $work 't33'; New-Item -ItemType Directory -Path $dir33 | Out-Null
    $s33 = New-FailSettings $dir33 @() @{ ThemeId='theme_classic' }
    $f33 = New-FormFor $s33
    $sinkField.SetValue($f33, ([System.Action[string]]{ param($k) }))
    $restore33 = $currentField2.GetValue($null)
    $ok33 = [bool]$applyThemeIdM.Invoke($null, @([object]$s33, [string]'theme_wintage_nord'))
    Check 'a successful theme save persists the id and moves Settings.ThemeId' `
        ($ok33 -and $themeIdField.GetValue($s33) -eq 'theme_wintage_nord') "ok=$ok33 theme=$($themeIdField.GetValue($s33))"
    $ini33 = Get-Content -LiteralPath (Join-Path $dir33 'problip.ini') -Raw
    Check 'a successful theme save writes ThemeId to the ini' ($ini33 -match 'ThemeId=theme_wintage_nord') $ini33.Trim()
    $palette33 = $currentField2.GetValue($null)
    $nordBg = $palette33.GetType().GetField('BG').GetValue($palette33)
    Check 'a successful theme save switches Palette.Current to the new palette' ($nordBg.R -eq 0x27 -and $nordBg.G -eq 0x2C -and $nordBg.B -eq 0x36) "bg=$nordBg"
    $currentField2.SetValue($null, $restore33)

    # 34. successful glow toggle persists and applies
    $dir34 = Join-Path $work 't34'; New-Item -ItemType Directory -Path $dir34 | Out-Null
    $s34 = New-FailSettings $dir34 @() @{ BlipGlow='1' }
    $f34 = New-FormFor $s34
    $sinkField.SetValue($f34, ([System.Action[string]]{ param($k) }))
    $toggleGlowM.Invoke($f34, @())
    Check 'a successful glow toggle persists BlipGlow=0 and applies it' `
        (([bool]$glowField.GetValue($s34) -eq $false)) "glow=$($glowField.GetValue($s34))"
    $ini34 = Get-Content -LiteralPath (Join-Path $dir34 'problip.ini') -Raw
    Check 'the glow toggle wrote BlipGlow=0 to the ini' ($ini34 -match 'BlipGlow=0') $ini34.Trim()

    # 35. fresh-install INI carries the new default keys
    $fresh35 = Join-Path $work 't35'; New-Item -ItemType Directory -Path $fresh35 | Out-Null
    $s35 = $ctor.Invoke(@([string]$fresh35))
    $s35.Load()
    $ini35 = Get-Content -LiteralPath (Join-Path $fresh35 'problip.ini') -Raw
    Check 'a fresh INI stores ThemeId=theme_classic and BlipGlow=1' `
        ($ini35 -match 'ThemeId=theme_classic' -and $ini35 -match 'BlipGlow=1') $ini35.Trim()

    # ---- W2-002: failure-atomic interval transaction ----
    # SaveIntervalState is no longer rollback-based: a sibling candidate is
    # prepared, verified, and atomically committed. Every failure point must
    # leave the ORIGINAL problip.ini byte-for-byte unchanged, produce no temp
    # artifact, and preserve Settings/Engine/scheduling state exactly.
    $intervalWriteF = $type.GetField('IntervalWrite', $flags)
    $commitIntF = $type.GetField('CommitIntervalFile', $flags)
    $saveIntervalM = $type.GetMethod('SaveIntervalState')
    $tempOf = { param($d) Join-Path $d 'problip.ini.interval.tmp' }
    $origIW = $intervalWriteF.GetValue($ctor.Invoke(@([string]$work)))   # default production delegate

    # A helper that runs one interval transaction with an injected fault and
    # asserts the full W2-002 postcondition set.
    function Test-AtomicFailure([string]$name, [string[]]$failKeys, [bool]$failCommit, [hashtable]$seed, [scriptblock]$apply, [ref]$retRef) {
        $d = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        if ($seed) {
            $sb = New-Object Text.StringBuilder("[problip]`r`n")
            foreach ($k in $seed.Keys) { [void]$sb.AppendLine("$k=$($seed[$k])") }
            Set-Content -LiteralPath (Join-Path $d 'problip.ini') -Value $sb.ToString() -NoNewline
        }
        $s = $ctor.Invoke(@([string]$d)); $s.Load()
        $iniPath = Join-Path $d 'problip.ini'
        $bytesBefore = if (Test-Path -LiteralPath $iniPath) { [IO.File]::ReadAllBytes($iniPath) } else { $null }
        # inject preparation fault(s)
        if ($failKeys) {
            $fkList = [System.Collections.Generic.List[string]]$failKeys
            $defIW = $intervalWriteF.GetValue($s)
            $w = { param($path, $key, $val)
                if ($fkList.Contains($key)) { return $false }
                return $defIW.Invoke($path, $key, $val) }.GetNewClosure()
            $intervalWriteF.SetValue($s, [Func[string,string,string,bool]]$w)
        }
        # inject commit fault
        if ($failCommit) {
            $commitIntF.SetValue($s, [Func[string,string,bool]]{ param($t, $p)
                try { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } } catch { }
                return $false })
        }
        $ret = [bool]$apply.Invoke($s)
        $retRef.Value = $ret
        $bytesAfter = if (Test-Path -LiteralPath $iniPath) { [IO.File]::ReadAllBytes($iniPath) } else { $null }
        $sameBytes = if ($null -eq $bytesBefore) { ($null -eq $bytesAfter -or $bytesAfter.Length -eq 0 -and $bytesBefore -eq $null) } else { ([Convert]::ToBase64String($bytesBefore) -eq [Convert]::ToBase64String($bytesAfter)) }
        # missing original file case: byte equality is "still does not exist"
        if ($null -eq $bytesBefore) { $sameBytes = -not (Test-Path -LiteralPath $iniPath) }
        $tmpGone = -not (Test-Path -LiteralPath (& $tempOf $d))
        return @{ SameBytes = $sameBytes; TmpGone = $tmpGone; Dir = $d; S = $s }
    }

    # RANGE failure matrix (A: first key, B: middle key, C: last key, D: commit)
    $rangeNext = {
        param($s)
        $kvType = [System.Collections.Generic.KeyValuePair[string,string]]
        $next = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'range'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('MinMs', '10000'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('MaxMs', '15000')
        )
        $prev = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'range'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('MinMs', '4000'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('MaxMs', '7000')
        )
        return $s.SaveIntervalState($next, $prev)
    }
    foreach ($case in @(
        @{ N='A'; Keys=@('IntervalKind'); Commit=$false },
        @{ N='B'; Keys=@('MinMs');     Commit=$false },
        @{ N='C'; Keys=@('MaxMs');     Commit=$false },
        @{ N='D'; Keys=$null;          Commit=$true }
    )) {
        $retRef = [ref]$false
        $r = Test-AtomicFailure "range-$($case.N)" $case.Keys $case.Commit @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000' } $rangeNext $retRef
        Check "W2-002 range $($case.N): rejected transaction returns false" (-not $retRef.Value)
        Check "W2-002 range $($case.N): original INI byte-for-byte unchanged" $r.SameBytes
        Check "W2-002 range $($case.N): no temp artifact survives" $r.TmpGone
        Check "W2-002 range $($case.N): Settings unchanged" ($r.S.MinMs -eq 4000 -and $r.S.MaxMs -eq 7000) "min=$($r.S.MinMs) max=$($r.S.MaxMs)"
    }

    # Restart after rejected transaction: fresh Settings.Load must see the OLD interval.
    $retRefR = [ref]$false
    $rR = Test-AtomicFailure 'range-restart' @('MaxMs') $false @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000' } $rangeNext $retRefR
    $sFresh = $ctor.Invoke(@([string]$rR.Dir)); $sFresh.Load()
    Check 'W2-002 restart after rejected range: fresh Load keeps the old interval' `
        ($sFresh.MinMs -eq 4000 -and $sFresh.MaxMs -eq 7000 -and $sFresh.Kind -eq $kindRange) `
        "min=$($sFresh.MinMs) max=$($sFresh.MaxMs) kind=$($sFresh.Kind)"

    # MANUAL failure matrix (E/F/G/H)
    $manualNext = {
        param($s)
        $next = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualFromSec', '60'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualToSec', '90'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'manual')
        )
        $prev = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualFromSec', '4'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualToSec', '7'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'range')
        )
        return $s.SaveIntervalState($next, $prev)
    }
    foreach ($case in @(
        @{ N='E'; Keys=@('ManualFromSec'); Commit=$false },
        @{ N='F'; Keys=@('ManualToSec');   Commit=$false },
        @{ N='G'; Keys=@('IntervalKind');  Commit=$false },
        @{ N='H'; Keys=$null;              Commit=$true }
    )) {
        $retRefM = [ref]$false
        $rM = Test-AtomicFailure "manual-$($case.N)" $case.Keys $case.Commit @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000'; ManualFromSec='4'; ManualToSec='7' } $manualNext $retRefM
        Check "W2-002 manual $($case.N): rejected transaction returns false" (-not $retRefM.Value)
        Check "W2-002 manual $($case.N): original INI byte-for-byte unchanged" $rM.SameBytes
        Check "W2-002 manual $($case.N): no temp artifact survives" $rM.TmpGone
    }
    # Restart after rejected manual transaction: no new ManualFromSec + old kind.
    $retRefM2 = [ref]$false
    $rM2 = Test-AtomicFailure 'manual-restart' @('ManualToSec') $false @{ IntervalKind='range'; MinMs='4000'; MaxMs='7000'; ManualFromSec='4'; ManualToSec='7' } $manualNext $retRefM2
    $sM2 = $ctor.Invoke(@([string]$rM2.Dir)); $sM2.Load()
    Check 'W2-002 restart after rejected manual: fresh Load keeps the old bounds and kind' `
        ([int]$fromField.GetValue($sM2) -eq 4 -and [int]$toField.GetValue($sM2) -eq 7 -and $sM2.Kind -eq $kindRange) `
        "from=$([int]$fromField.GetValue($sM2)) to=$([int]$toField.GetValue($sM2)) kind=$($sM2.Kind)"

    # Candidate verification failure: write claims success but readback does not
    # contain the expected value. Inject a lying IntervalWrite that reports true
    # but writes a different value.
    $dV = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dV | Out-Null
    Set-Content -LiteralPath (Join-Path $dV 'problip.ini') -NoNewline -Value "[problip]`r`nIntervalKind=range`r`nMinMs=4000`r`nMaxMs=7000`r`n"
    $sV = $ctor.Invoke(@([string]$dV)); $sV.Load()
    $bytesV0 = [IO.File]::ReadAllBytes((Join-Path $dV 'problip.ini'))
    $realIW = $intervalWriteF.GetValue($sV)
    $intervalWriteF.SetValue($sV, [Func[string,string,string,bool]]{ param($path, $key, $val)
        if ($key -eq 'MaxMs') { return $true }   # lie: claims success, writes nothing
        return $realIW.Invoke($path, $key, $val) }.GetNewClosure())
    $retV = [bool]$rangeNext.Invoke($sV)
    $bytesV1 = [IO.File]::ReadAllBytes((Join-Path $dV 'problip.ini'))
    Check 'W2-002 candidate verification failure returns false' (-not $retV)
    Check 'W2-002 candidate verification failure leaves original unchanged' ([Convert]::ToBase64String($bytesV0) -eq [Convert]::ToBase64String($bytesV1))
    Check 'W2-002 candidate verification failure cleans the temp' (-not (Test-Path -LiteralPath (& $tempOf $dV)))

    # Successful RANGE restart: 4..7 -> 10..15, fresh Load sees exactly that.
    $dS = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dS | Out-Null
    Set-Content -LiteralPath (Join-Path $dS 'problip.ini') -NoNewline -Value "[problip]`r`nIntervalKind=range`r`nMinMs=4000`r`nMaxMs=7000`r`n"
    $sS = $ctor.Invoke(@([string]$dS)); $sS.Load()
    $retS = [bool]$rangeNext.Invoke($sS)
    Check 'W2-002 successful range transaction returns true' $retS
    Check 'W2-002 successful range transaction leaves no temp' (-not (Test-Path -LiteralPath (& $tempOf $dS)))
    $sS2 = $ctor.Invoke(@([string]$dS)); $sS2.Load()
    Check 'W2-002 successful range restart: fresh Load sees 10000/15000 Range' `
        ($sS2.Kind -eq $kindRange -and $sS2.MinMs -eq 10000 -and $sS2.MaxMs -eq 15000) `
        "kind=$($sS2.Kind) min=$($sS2.MinMs) max=$($sS2.MaxMs)"

    # Successful MANUAL restart: 5..10, fresh Load sees exactly that.
    $dM = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dM | Out-Null
    $sMn = $ctor.Invoke(@([string]$dM)); $sMn.Load()
    $manualNext510 = {
        param($s)
        $next = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualFromSec', '5'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualToSec', '10'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'manual')
        )
        $prev = @(
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualFromSec', '4'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('ManualToSec', '7'),
            [System.Collections.Generic.KeyValuePair[string,string]]::new('IntervalKind', 'range')
        )
        return $s.SaveIntervalState($next, $prev)
    }
    $retMn = [bool]$manualNext510.Invoke($sMn)
    Check 'W2-002 successful manual transaction returns true' $retMn
    $sMn2 = $ctor.Invoke(@([string]$dM)); $sMn2.Load()
    Check 'W2-002 successful manual restart: fresh Load sees Manual 5/10' `
        ($sMn2.Kind -eq $kindManual -and [int]$fromField.GetValue($sMn2) -eq 5 -and [int]$toField.GetValue($sMn2) -eq 10) `
        "kind=$($sMn2.Kind) from=$([int]$fromField.GetValue($sMn2)) to=$([int]$toField.GetValue($sMn2))"

    # Unrelated settings survive a successful interval commit.
    $dU = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dU | Out-Null
    Set-Content -LiteralPath (Join-Path $dU 'problip.ini') -NoNewline -Value ("[problip]`r`nVolume=0.37`r`nAutoStart=1`r`nRunOnLaunch=0`r`nShowBlipCounter=0`r`n" +
        "StatsEnabled=0`r`nThemeId=theme_wintage_dracula`r`nBlipGlow=0`r`nAlwaysOnTop=0`r`nIntervalKind=range`r`nMinMs=4000`r`nMaxMs=7000`r`n")
    $sU = $ctor.Invoke(@([string]$dU)); $sU.Load()
    $retU = [bool]$rangeNext.Invoke($sU)
    Check 'W2-002 unrelated-settings transaction succeeds' $retU
    $sU2 = $ctor.Invoke(@([string]$dU)); $sU2.Load()
    Check 'W2-002 unrelated settings survive the interval commit' `
        ($sU2.Volume -eq 0.37 -and $sU2.AutoStart -and -not $sU2.RunOnLaunch -and -not $sU2.ShowBlipCounter -and
         -not $sU2.StatsEnabled -and -not $sU2.BlipGlow -and -not $sU2.AlwaysOnTop -and
         $themeIdField.GetValue($sU2) -eq 'theme_wintage_dracula') `
        "vol=$($sU2.Volume) auto=$($sU2.AutoStart) run=$($sU2.RunOnLaunch) cnt=$($sU2.ShowBlipCounter) stats=$($sU2.StatsEnabled) glow=$($sU2.BlipGlow) top=$($sU2.AlwaysOnTop) theme=$($themeIdField.GetValue($sU2))"
    Check 'W2-002 the committed interval itself took effect' ($sU2.MinMs -eq 10000 -and $sU2.MaxMs -eq 15000)

    # Stale temp cleanup: a seeded stale candidate must not contaminate or survive.
    $dT = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dT | Out-Null
    Set-Content -LiteralPath (Join-Path $dT 'problip.ini') -NoNewline -Value "[problip]`r`nIntervalKind=range`r`nMinMs=4000`r`nMaxMs=7000`r`n"
    Set-Content -LiteralPath (Join-Path $dT 'problip.ini.interval.tmp') -NoNewline -Value "[problip]`r`nIntervalKind=bogus`r`nMinMs=1`r`n"
    $sT = $ctor.Invoke(@([string]$dT)); $sT.Load()
    $retT = [bool]$rangeNext.Invoke($sT)
    Check 'W2-002 a stale temp does not block or contaminate a successful transaction' $retT
    $sT2 = $ctor.Invoke(@([string]$dT)); $sT2.Load()
    Check 'W2-002 the stale temp was replaced by the new commit' ($sT2.MinMs -eq 10000 -and $sT2.MaxMs -eq 15000)
    Check 'W2-002 successful commit leaves no temp behind' (-not (Test-Path -LiteralPath (& $tempOf $dT)))

    # Missing INI: SaveIntervalState must work without a pre-existing file.
    $dX = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dX | Out-Null
    $sX = $ctor.Invoke(@([string]$dX)); $sX.Load()   # Load's fresh-install writes create it; use a truly raw dir
    # For a genuinely missing INI (no fresh-install writes), point IniPath at a not-yet-created file.
    $dX2 = Join-Path $work ('w2_' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dX2 | Out-Null
    $sX2 = $ctor.Invoke(@([string]$dX2))
    $iniPathX2 = Join-Path $dX2 'problip.ini'
    $retX = [bool]$rangeNext.Invoke($sX2)
    Check 'W2-002 transaction succeeds with a missing INI (File.Move path)' $retX
    Check 'W2-002 the missing-INI transaction created the file with the interval' `
        ((Get-Content -Raw -LiteralPath $iniPathX2) -match 'MinMs=10000' -and (Get-Content -Raw -LiteralPath $iniPathX2) -match 'IntervalKind=range') `
        "content=$((Get-Content -Raw -LiteralPath $iniPathX2) -replace "`r",'')"
    Check 'W2-002 the missing-INI transaction leaves no temp' (-not (Test-Path -LiteralPath (& $tempOf $dX2)))

    # Read-only directory: user-facing behavior preserved.
    $roD = Join-Path $work 'w2_ro'; New-Item -ItemType Directory -Path $roD | Out-Null
    Set-Content -LiteralPath (Join-Path $roD 'problip.ini') -NoNewline -Value "[problip]`r`nIntervalKind=range`r`nMinMs=4000`r`nMaxMs=7000`r`n"
    $roS = $ctor.Invoke(@([string]$roD)); $roS.Load()
    $roBytes0 = [IO.File]::ReadAllBytes((Join-Path $roD 'problip.ini'))
    # Make the directory read-only for new-file creation (temp staging fails).
    $acl = Get-Acl $roD
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule([Environment]::UserName, 'CreateDirectories,CreateFiles,Write', 'None', 'None', 'Deny')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $roD -AclObject $acl
    try {
        $roRet = [bool]$rangeNext.Invoke($roS)
        $roBytes1 = [IO.File]::ReadAllBytes((Join-Path $roD 'problip.ini'))
        Check 'W2-002 read-only directory: transaction returns false' (-not $roRet)
        Check 'W2-002 read-only directory: original INI unchanged' ([Convert]::ToBase64String($roBytes0) -eq [Convert]::ToBase64String($roBytes1))
        Check 'W2-002 read-only directory: no temp created' (-not (Test-Path -LiteralPath (& $tempOf $roD)))
        Check 'W2-002 read-only directory: Settings keep the old interval' ($roS.MinMs -eq 4000 -and $roS.MaxMs -eq 7000)
    } finally {
        # lift the deny so cleanup can remove the tree
        $acl2 = Get-Acl $roD
        $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule([Environment]::UserName, 'CreateDirectories,CreateFiles,Write', 'None', 'None', 'Deny')
        $acl2.RemoveAccessRule($rule2) | Out-Null
        Set-Acl -Path $roD -AclObject $acl2
    }

    foreach ($k in $script:regKeys) { Remove-Item -LiteralPath "HKCU:\$k" -Recurse -Force -ErrorAction SilentlyContinue }
} finally {
    foreach ($f in $script:forms) { try { $f.Dispose() } catch { } }
    foreach ($t in $script:trays) { try { $t.Dispose() } catch { } }
    foreach ($e in $script:engines) { try { $e.Cleanup() } catch { } }
    foreach ($k in $script:regKeys) { Remove-Item -LiteralPath "HKCU:\$k" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
