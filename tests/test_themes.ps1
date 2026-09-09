# Theme catalog regression: the fifteen Wintage identities, their exact donor
# palettes, normalization of legacy/unknown ids, Golden Default pixel pins and
# the light-palette readability contract. Pure model checks plus the theme
# switch's scheduling immunity; no real INI is touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "PASS  $name  $detail" } else { Write-Host "FAIL  $name  $detail"; $script:fails++ }
}

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }

$work = Join-Path ([IO.Path]::GetTempPath()) ("problip_themes_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $asmPath = Join-Path $work 'ProblipThemes.dll'
    $src = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs'
    & $csc -nologo -target:library "-out:$asmPath" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $src | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  subject does not compile: $src"; exit 1 }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($asmPath))

    $themeModel = $asm.GetType('Problip.ThemeModel', $true)
    $glowModel  = $asm.GetType('Problip.GlowModel', $true)
    $stFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $all = [object[]]$themeModel.GetField('All', $stFlags).GetValue($null)
    $byId = $themeModel.GetMethod('ById', $stFlags)
    $normalize = $themeModel.GetMethod('Normalize', $stFlags)
    $paletteFor = $themeModel.GetMethod('PaletteFor', $stFlags)
    $isLight = $themeModel.GetMethod('IsLight', $stFlags)

    function IdOf($entry) { return [string]$entry.GetType().GetField('Id').GetValue($entry) }
    function NameOf($entry) { return [string]$entry.GetType().GetField('Name').GetValue($entry) }
    function SlotOf($palette, [string]$slot) { return [System.Drawing.Color]$palette.GetType().GetField($slot).GetValue($palette) }
    function Rgb([System.Drawing.Color]$c) { return ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) }

    # A. exactly 15 theme entries, in catalog order
    Check 'the catalog holds exactly 15 theme entries' ($all.Count -eq 15) "count=$($all.Count)"
    $expectedOrder = @('theme_classic','theme_wintage_golden','theme_wintage_claudecode','theme_wintage_antigravity',
        'theme_wintage_klite','theme_wintage_freebuff','theme_wintage_codenomad','theme_wintage_fpdefault',
        'theme_wintage_goldenvintage','theme_wintage_vintagedark','theme_wintage_vintageclassic','theme_wintage_oled',
        'theme_wintage_dracula','theme_wintage_nord','theme_wintage_solarized')
    $actualOrder = @($all | ForEach-Object { IdOf $_ })
    $orderOk = $true
    for ($i = 0; $i -lt [Math]::Min($all.Count, 15); $i++) { if ($actualOrder[$i] -ne $expectedOrder[$i]) { $orderOk = $false } }
    Check 'the catalog order is the donor Themes-screen order' $orderOk ($actualOrder -join ',')

    # Display names are part of the identity contract for the picker.
    $expectedNames = @('Golden Default','Dark Golden (Win95)','Claude Code','Antigravity','K-Lite (MPC-HC)','FreeBuff',
        'CodeNomad','Default','Golden Vintage','Vintage Dark','Vintage Classic','Dark 2 (OLED)','Dracula','Nord','Solarized Dark')
    $namesOk = $true
    for ($i = 0; $i -lt $all.Count; $i++) { if ((NameOf $all[$i]) -ne $expectedNames[$i]) { $namesOk = $false } }
    Check 'the display names match the donor identities' $namesOk

    # B. every id is unique
    $dupes = @($actualOrder | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [string]$_.Name })
    Check 'every theme id is unique' ($dupes.Count -eq 0) ($dupes -join ',')

    # C. every id resolves to a complete palette (all 13 donor slots + derived ALT)
    $slots = @('BG','SURFACE','RAISED','BEVEL','BDARK','LINK','TEXT','TEXT2','MUTED','COMPARE','SUCCESS','DANGERTXT','ALT')
    $complete = $true; $detailC = ''
    foreach ($entry in $all) {
        $p = $paletteFor.Invoke($null, @((IdOf $entry)))
        if ($null -eq $p) { $complete = $false; $detailC += "$(IdOf $entry):null "; continue }
        foreach ($s in $slots) {
            $c = SlotOf $p $s
            if ($c.IsEmpty -or ($c.A -ne 255)) { $complete = $false; $detailC += "$(IdOf $entry):$s " }
        }
    }
    Check 'every theme id resolves to a complete palette' $complete $detailC

    # D. Golden Default exact RGB pins == the previous hard-coded Windows values
    $classic = $paletteFor.Invoke($null, @([string]'theme_classic'))
    $pinsD = @{
        BG = '1A1810'; SURFACE = '332E22'; RAISED = '3D372A'; BEVEL = '75663D'; BDARK = '100E08'
        LINK = 'F0D060'; TEXT = 'D4C89A'; TEXT2 = '9C9371'; MUTED = '6E674E'
        COMPARE = '14120C'; SUCCESS = '4A7A20'; DANGERTXT = 'D66464'
    }
    $okD = $true; $detailD = ''
    foreach ($k in $pinsD.Keys) {
        $actual = Rgb (SlotOf $classic $k)
        if ($actual -ne $pinsD[$k]) { $okD = $false; $detailD += "$k=$actual(want $($pinsD[$k])) " }
    }
    Check 'Golden Default pins match the pre-theme Windows values exactly' $okD $detailD
    # ALT is the deterministic Surface/Raised midpoint, never a Golden Default leftover.
    $altD = Rgb (SlotOf $classic 'ALT')
    Check 'Golden Default ALT is the derived Surface/Raised midpoint 383226' ($altD -eq '383226') "ALT=$altD"

    # E. per-theme donor pins: BG / accent (LINK) / TEXT for every Wintage theme
    $pinsE = @{
        'theme_wintage_golden'         = @('342012','D3B57A','E2CA95')
        'theme_wintage_claudecode'     = @('29241D','D1A27C','E0B997')
        'theme_wintage_antigravity'    = @('1B1F2C','7AD0D3','95DEE2')
        'theme_wintage_klite'          = @('212325','A2A5AB','B8BABF')
        'theme_wintage_freebuff'       = @('1B232B','89D37A','A0E295')
        'theme_wintage_codenomad'      = @('1C242A','9D86D1','B099DE')
        'theme_wintage_fpdefault'      = @('1A1A1A','839BB0','C0C0C0')
        'theme_wintage_goldenvintage'  = @('0F0F0F','D6BE76','C4BA9F')
        'theme_wintage_vintagedark'    = @('181818','738EA6','C0C0C0')
        'theme_wintage_vintageclassic' = @('C0C0C0','F6F6F6','000000')
        'theme_wintage_oled'           = @('000000','FFFFFF','A0A0A0')
        'theme_wintage_dracula'        = @('21222C','BD93F9','F8F8F2')
        'theme_wintage_nord'           = @('272C36','88C0D0','D8DEE9')
        'theme_wintage_solarized'      = @('002B36','51A2DB','93A1A1')
    }
    $okE = $true; $detailE = ''
    foreach ($tid in $pinsE.Keys) {
        $p = $paletteFor.Invoke($null, @([string]$tid))
        $want = $pinsE[$tid]
        $got = @((Rgb (SlotOf $p 'BG')), (Rgb (SlotOf $p 'LINK')), (Rgb (SlotOf $p 'TEXT')))
        for ($i = 0; $i -lt 3; $i++) {
            if ($got[$i] -ne $want[$i]) { $okE = $false; $detailE += "$tid[$i]=$($got[$i])want$($want[$i]) " }
        }
    }
    Check 'every Wintage theme pins BG/accent/TEXT to the donor values' $okE $detailE

    # F. legacy theme_wintage_custom normalizes to theme_classic
    $normF = $normalize.Invoke($null, @([string]'theme_wintage_custom'))
    $byF = IdOf ($byId.Invoke($null, @([string]'theme_wintage_custom')))
    Check 'theme_wintage_custom normalizes to theme_classic' ($normF -eq 'theme_classic' -and $byF -eq 'theme_classic') "norm=$normF byId=$byF"

    # G. unknown id resolves to theme_classic (never a partial theme)
    $byG = IdOf ($byId.Invoke($null, @([string]'theme_wintage_nope')))
    $byG2 = IdOf ($byId.Invoke($null, @($null)))
    Check 'an unknown id resolves to theme_classic' ($byG -eq 'theme_classic' -and $byG2 -eq 'theme_classic') "unknown=$byG null=$byG2"
    $palG = $paletteFor.Invoke($null, @([string]'garbage-id'))
    $classicBg = SlotOf $classic 'BG'
    $palGBg = SlotOf $palG 'BG'
    Check 'an unknown id resolves to the full Golden Default palette' ($palGBg.R -eq $classicBg.R -and $palGBg.G -eq $classicBg.G -and $palGBg.B -eq $classicBg.B)

    # H. Vintage Classic is the light palette: light BG, dark primary text
    $vc = $paletteFor.Invoke($null, @([string]'theme_wintage_vintageclassic'))
    $vcBg = SlotOf $vc 'BG'; $vcText = SlotOf $vc 'TEXT'
    Check 'Vintage Classic has a light background' (($vcBg.R + $vcBg.G + $vcBg.B) -gt 384) "bg=$(Rgb $vcBg)"
    Check 'Vintage Classic has dark primary text' (($vcText.R + $vcText.G + $vcText.B) -lt 128) "text=$(Rgb $vcText)"
    Check 'Vintage Classic is flagged as the one light palette' ([bool]$isLight.Invoke($null, @($byId.Invoke($null, @([string]'theme_wintage_vintageclassic')))))
    $lightCount = 0
    foreach ($entry in $all) {
        if ((IdOf $entry) -ne 'theme_wintage_vintageclassic' -and [bool]$isLight.Invoke($null, @($entry))) { $lightCount++ }
    }
    Check 'no other palette is flagged light' ($lightCount -eq 0) "lightCount=$lightCount"

    # I. OLED background is exact black
    $oled = $paletteFor.Invoke($null, @([string]'theme_wintage_oled'))
    $oBg = SlotOf $oled 'BG'
    Check 'the OLED background is exact black' ($oBg.R -eq 0 -and $oBg.G -eq 0 -and $oBg.B -eq 0 -and $oBg.A -eq 255) "bg=$(Rgb $oBg)"

    # J. selecting a theme does not touch engine interval state (immunity via
    #    the Program.ApplyThemeId transaction against a live engine). The real
    #    shipped WAV (silent volume) keeps Start() healthy, so "stays ON" is a
    #    meaningful assertion, never a broken-asset artifact.
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $sCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $realWav = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'blip01.wav'
    $dirJ = Join-Path $work 'j'; New-Item -ItemType Directory -Path $dirJ | Out-Null
    $sJ = $sCtor.Invoke(@([string]$dirJ))
    $settingsType.GetMethod('Load').Invoke($sJ, @()) | Out-Null
    $sJ.WavPath = [string]$realWav
    $sJ.Volume = 0.0
    $eJ = $engineType.GetConstructor($flags, $null, @($settingsType), $null).Invoke(@($sJ))
    $timerJ = [System.Windows.Forms.Timer]$engineType.GetField('Timer', $flags).GetValue($eJ)
    $nextDueField = $engineType.GetField('NextDueMs', $flags)
    $nowMsField = $engineType.GetField('NowMs', $flags)
    $fakeNow = [long]1000
    $nowMsField.SetValue($eJ, [Func[long]]{ param() $fakeNow })
    $eJ.Start()
    $dueJ = [long]$nextDueField.GetValue($eJ)
    $ivJ = [double]$timerJ.Interval
    $drawsJ = [int]$engineType.GetField('IntervalDrawCount', $flags).GetValue($eJ)
    $schedJ = [int]$engineType.GetField('ScheduledPlayCount', $flags).GetValue($eJ)
    $phaseJ = [bool]$engineType.GetField('PulseShortNext', $flags).GetValue($eJ)
    $programType = $asm.GetType('Problip.Program', $true)
    $applyThemeId = $programType.GetMethod('ApplyThemeId', $stFlags)
    $okJ = [bool]$applyThemeId.Invoke($null, @([object]$sJ, [string]'theme_wintage_dracula'))
    Check 'ApplyThemeId succeeds against a writable ini' ($okJ -and [string]$settingsType.GetField('ThemeId', $flags).GetValue($sJ) -eq 'theme_wintage_dracula')
    Check 'a theme switch never stops or starts the engine' ($eJ.IsOn -and $timerJ.Enabled) "on=$($eJ.IsOn) timer=$($timerJ.Enabled)"
    Check 'a theme switch does not move NextDueMs' ([long]$nextDueField.GetValue($eJ) -eq $dueJ) "due=$([long]$nextDueField.GetValue($eJ)) original=$dueJ"
    Check 'a theme switch does not redraw the pending interval' ([double]$timerJ.Interval -eq $ivJ -and [int]$engineType.GetField('IntervalDrawCount', $flags).GetValue($eJ) -eq $drawsJ)
    Check 'a theme switch plays no blip' ([int]$engineType.GetField('ScheduledPlayCount', $flags).GetValue($eJ) -eq $schedJ)
    Check 'a theme switch does not reset the PULSE phase' ([bool]$engineType.GetField('PulseShortNext', $flags).GetValue($eJ) -eq $phaseJ)

    # ---- Glow pure model ----
    $alpha = $glowModel.GetMethod('Alpha', $stFlags)
    $a0   = [double]$alpha.Invoke($null, @([int]0))
    $a1   = [double]$alpha.Invoke($null, @([int]30))
    $aPk  = [double]$alpha.Invoke($null, @([int]60))
    $aDec = [double]$alpha.Invoke($null, @([int]160))
    $aEnd = [double]$alpha.Invoke($null, @([int]260))
    $aNeg = [double]$alpha.Invoke($null, @([int]-5))
    $aFar = [double]$alpha.Invoke($null, @([int]10000))
    Check 'glow alpha at t=0 is 0' ($a0 -eq 0.0) "a=$a0"
    Check 'glow alpha rises toward the peak (a(30ms) inside (0, 0.25))' ($a1 -gt 0.0 -and $a1 -lt 0.25) "a=$a1"
    Check 'glow alpha peaks at 0.25 at 60ms' ([Math]::Abs($aPk - 0.25) -lt 0.001) "a=$aPk"
    Check 'glow alpha decays monotonically (a(160ms) inside (0, 0.25))' ($aDec -gt 0.0 -and $aDec -lt $aPk) "a=$aDec"
    Check 'glow alpha reaches 0 at t>=260ms' ($aEnd -eq 0.0 -and $aFar -eq 0.0) "a260=$aEnd aFar=$aFar"
    Check 'glow alpha never goes negative' ($aNeg -eq 0.0) "a=$aNeg"
    # shape check: rises to the 60ms peak, then decays monotonically to 0 at
    # 260ms; never below 0, never above 0.25.
    $monoOk = $true; $prev = 0.0
    for ($t = 0; $t -le 260; $t += 10) {
        $a = [double]$alpha.Invoke($null, @([int]$t))
        if ($t -le 60) {
            if ($a -lt $prev - 1e-9) { $monoOk = $false }   # rise: never falls
        } else {
            if ($a -gt $prev + 1e-9) { $monoOk = $false }   # decay: never rises
        }
        if ($a -lt 0.0 -or $a -gt 0.25) { $monoOk = $false }
        $prev = $a
    }
    Check 'glow alpha rises to the 60ms peak then decays monotonically to zero' $monoOk
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fails) { Write-Host "FAILED ($fails failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
