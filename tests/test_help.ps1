# Help regression: single-source content contract (required Windows sections,
# forbidden Android donor sections), HelpForm product-state immunity (opening
# and closing Help never touches scheduling/audio/statistics/glow/persistence),
# the one-reusable-instance ownership, theme-live projection through
# Program.ApplyThemeToWindows, and resource stability across 100 open/hide
# cycles and 15 theme switches. No real user INI/stats file is touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$failures = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $Name $Detail" }
    else { Write-Host "FAIL  $Name $Detail"; $script:failures++ }
}

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }

$work = Join-Path ([IO.Path]::GetTempPath()) ("problip_help_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$dll = Join-Path $work 'ProblipHelpSubject.dll'
$src = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs'

& $csc -nologo -target:library -out:$dll -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $src | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  subject does not compile: $src"; exit 1 }

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HelpGuiResources
{
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
    public static uint Gdi()
    {
        return GetGuiResources(System.Diagnostics.Process.GetCurrentProcess().Handle, 0);
    }
}
'@

$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
$stFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
$iFlags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$anyFlags = [Reflection.BindingFlags]'Instance,Static,Public,NonPublic'

try {
    # ---- 1. HelpContent.Build(): the single content source ----
    $helpContentType = $asm.GetType('Problip.HelpContent', $true)
    $buildM = $helpContentType.GetMethod('Build', $stFlags)
    if ($null -eq $buildM) {
        Check 'Help text comes from one static provider (HelpContent.Build)' $false 'HelpContent.Build missing'
    } else {
        $text = [string]$buildM.Invoke($null, @())
        Check 'Help text comes from one static provider (HelpContent.Build)' ($text.Length -gt 500) "len=$($text.Length)"

        # Required Windows sections (matches the runner spec: heading names and
        # the product words a Windows user must find).
        $required = @('QUICK START','INTERVALS','MANUAL','PULSE','TEST','VOLUME',
            'RUNNING / STARTUP','RunOnLaunch','Autostart','STATISTICS','THEMES',
            'BLIP GLOW','Glow','TROUBLESHOOTING','FAQ','ERR','blip01.wav','problip.stats.ini')
        $missing = @()
        foreach ($r in $required) { if ($text -notlike "*$r*") { $missing += $r } }
        Check 'Help covers every required Windows section' ($missing.Count -eq 0) "missing=$($missing -join ',')"

        # Forbidden Android donor content: Windows Help describes Windows
        # PROBLIP only -- no premium/store/billing/trial/developer sections.
        $forbidden = @('Premium','premium','Billing','billing','Play Store','Play store',
            'Developer Access','Developer access','Developer gesture','trial','Trial','five-minute')
        $present = @()
        foreach ($f in $forbidden) { if ($text -like "*$f*") { $present += $f } }
        Check 'Help contains no Android premium/store/trial/developer content' ($present.Count -eq 0) "found=$($present -join ',')"

        # FAQ answers present in one deterministic order.
        foreach ($q in @('Does TEST change the timer?','Does changing volume restart the timer?',
                'Does hiding BLIPS stop statistics?','Is data uploaded anywhere?')) {
            Check "FAQ answers '$q'" ($text -like "*$q*")
        }
    }

    # ---- 2. Live engine + settings in a disposable directory ----
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)
    $helpFormType = $asm.GetType('Problip.HelpForm', $true)
    $programType = $asm.GetType('Problip.Program', $true)
    $sCtor = $settingsType.GetConstructor($iFlags, $null, @([string]), $null)
    $realWav = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'blip01.wav'
    $dirLive = Join-Path $work 'live'; New-Item -ItemType Directory -Path $dirLive | Out-Null
    $s = $sCtor.Invoke(@([string]$dirLive))
    $settingsType.GetMethod('Load').Invoke($s, @()) | Out-Null
    $s.WavPath = [string]$realWav
    $s.Volume = 0.0
    $engine = $engineType.GetConstructor($iFlags, $null, @($settingsType), $null).Invoke(@($s))
    # A healthy RUNNING session: the strongest immunity baseline (Help must
    # never disturb a live schedule, only a stopped one).
    $engine.SetInterval([Enum]::Parse($asm.GetType('Problip.IntervalKind'), 'Pulse'), 0, 0)
    $engine.Start()

    $timerField = $engineType.GetField('Timer', $iFlags)
    $timer = [System.Windows.Forms.Timer]$timerField.GetValue($engine)
    $nextDueField = $engineType.GetField('NextDueMs', $iFlags)
    $phaseField = $engineType.GetField('PulseShortNext', $iFlags)
    $schedField = $engineType.GetField('ScheduledPlayCount', $iFlags)
    $previewField = $engineType.GetField('PreviewCount', $iFlags)

    function EngineState {
        return [pscustomobject]@{
            On      = [bool]$engine.IsOn
            Due     = [long]$nextDueField.GetValue($engine)
            Iv      = [double]$timer.Interval
            Phase   = [bool]$phaseField.GetValue($engine)
            Sched   = [int]$schedField.GetValue($engine)
            Preview = [int]$previewField.GetValue($engine)
            Total   = [long]$engine.Stats.Snapshot().Total
            Dirty   = [bool]$engine.Stats.Dirty
        }
    }

    # ---- 3. Opening Help touches no product state (through the real entry seam) ----
    $before = EngineState
    $helpField = $programType.GetField('_helpForm', [Reflection.BindingFlags]'Static,NonPublic')
    $showHelpM = $programType.GetMethod('ShowHelp', [Reflection.BindingFlags]'Static,NonPublic')
    if ($null -eq $showHelpM) {
        Check 'Program.ShowHelp exists as the one Help entry seam' $false 'ShowHelp missing'
        throw 'ShowHelp missing; harness cannot continue'
    }
    $showHelpM.Invoke($null, @([object]$s))
    $help = $helpField.GetValue($null)
    if ($null -eq $help) { throw 'ShowHelp produced no _helpForm' }
    $afterCtor = EngineState
    Check 'opening Help leaves the running schedule byte-for-byte unchanged' `
        ($before.On -eq $afterCtor.On -and $before.Due -eq $afterCtor.Due -and $before.Iv -eq $afterCtor.Iv -and `
         $before.Phase -eq $afterCtor.Phase -and $before.Sched -eq $afterCtor.Sched -and `
         $before.Preview -eq $afterCtor.Preview -and $before.Total -eq $afterCtor.Total) `
        "before=$($before.Due)/$($before.Iv) after=$($afterCtor.Due)/$($afterCtor.Iv)"
    Check 'opening Help flushes nothing to the statistics store' (-not $afterCtor.Dirty) "dirty=$($afterCtor.Dirty)"
    Check 'the opened Help window is visible' ([bool]$help.Visible)

    # ---- 4. One reusable instance via Program.ShowHelp ----
    $showHelpM.Invoke($null, @([object]$s))
    $second = $helpField.GetValue($null)
    Check 'repeated Help opens reuse ONE form instance' ([object]::ReferenceEquals($help, $second))
    # User close hides, never disposes (the reusable-window contract).
    $help.Close()
    Check 'closing Help hides it without disposing the instance' (-not [bool]$help.IsDisposed -and -not [bool]$help.Visible)
    $showHelpM.Invoke($null, @([object]$s))
    Check 'the hidden Help instance reopens as the same object' ([object]::ReferenceEquals($helpField.GetValue($null), $help) -and [bool]$help.Visible)

    # ---- 5. Theme switch while Help is visible: live projection, zero schedule impact ----
    $paletteType = $asm.GetType('Problip.Palette', $true)
    $currentField = $paletteType.GetField('Current', $stFlags)
    $savedPalette = $currentField.GetValue($null)
    $paletteForM = $asm.GetType('Problip.ThemeModel', $true).GetMethod('PaletteFor', $stFlags)
    $applyThemeIdM = $programType.GetMethod('ApplyThemeId', $stFlags)
    $applyThemeIdM.Invoke($null, @([object]$s, [string]'theme_classic')) | Out-Null   # deterministic start
    $bg0 = [System.Drawing.Color]$help.BackColor
    $txt0 = [System.Drawing.Color]$help.Controls[0].ForeColor
    $state0 = EngineState

    $okSwitch = $true
    foreach ($tid in @('theme_wintage_vintageclassic', 'theme_wintage_dracula', 'theme_classic')) {
        if (-not [bool]$applyThemeIdM.Invoke($null, @([object]$s, [string]$tid))) { $okSwitch = $false }
        $want = [System.Drawing.Color]$paletteForM.Invoke($null, @([string]$tid)).GetType().GetField('BG').GetValue($paletteForM.Invoke($null, @([string]$tid)))
        if ([System.Drawing.Color]$help.BackColor -ne $want) { $okSwitch = $false }
        if ([System.Drawing.Color]$help.Controls[0].BackColor -ne $want) { $okSwitch = $false }
    }
    Check 'the SAME HelpForm instance follows three theme switches live' ([object]::ReferenceEquals($helpField.GetValue($null), $help) -and $okSwitch)
    # After the tour returns to Golden Default, the projection must be EXACTLY
    # the classic palette again (background and content colors) -- live, no restart.
    $classicPal = $paletteForM.Invoke($null, @([string]'theme_classic'))
    $wantBg = [System.Drawing.Color]$classicPal.GetType().GetField('BG').GetValue($classicPal)
    $wantText = [System.Drawing.Color]$classicPal.GetType().GetField('TEXT').GetValue($classicPal)
    Check 'HelpForm background and content colors re-project the classic palette exactly' `
        ([System.Drawing.Color]$help.BackColor -eq $wantBg -and [System.Drawing.Color]$help.Controls[0].ForeColor -eq $wantText) `
        "bg=$([System.Drawing.Color]$help.BackColor) text=$([System.Drawing.Color]$help.Controls[0].ForeColor)"
    $state1 = EngineState
    Check 'three theme switches with Help visible leave scheduling untouched' `
        ($state0.On -eq $state1.On -and $state0.Due -eq $state1.Due -and $state0.Iv -eq $state1.Iv -and `
         $state0.Phase -eq $state1.Phase -and $state0.Sched -eq $state1.Sched -and $state0.Total -eq $state1.Total)
    $currentField.SetValue($null, $savedPalette)

    # ---- 6. Resource stability: 100 open/hide cycles allocate no Fonts, no GDI churn ----
    $contentFont0 = $help.Controls[0].Font
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $gdiBefore = [int][HelpGuiResources]::Gdi()
    for ($i = 0; $i -lt 100; $i++) {
        $help.Hide()
        $help.Show()
    }
    $gdiGrowth = [int][HelpGuiResources]::Gdi() - $gdiBefore
    Check '100 open/hide cycles plateau GDI objects' ($gdiGrowth -lt 50) "growth=$gdiGrowth"
    Check '100 open/hide cycles never rebuild the content Font' ([object]::ReferenceEquals($contentFont0, $help.Controls[0].Font))
    $help.Hide()

    # ---- 7. 15 theme switches while Help exists: no handle leak, still one instance ----
    $themeModelType = $asm.GetType('Problip.ThemeModel', $true)
    $allEntries = [object[]]$themeModelType.GetField('All', $stFlags).GetValue($null)
    $idOfEntry = { param($e) [string]$e.GetType().GetField('Id').GetValue($e) }
    $gdiBefore2 = [int][HelpGuiResources]::Gdi()
    $help.Show()
    foreach ($e in $allEntries) {
        [void]$applyThemeIdM.Invoke($null, @([object]$s, [string](& $idOfEntry $e)))
    }
    $gdiGrowth2 = [int][HelpGuiResources]::Gdi() - $gdiBefore2
    Check '15 theme switches with Help visible stay inside the GDI plateau' ($gdiGrowth2 -lt 50) "growth=$gdiGrowth2"
    Check '15 theme switches leave exactly the one Help instance' ([object]::ReferenceEquals($helpField.GetValue($null), $help))
    Check 'the engine is still healthy ON after every Help and theme interaction' ([bool]$engine.IsOn -and [bool]$timer.Enabled)
    $help.Hide()
    [void]$applyThemeIdM.Invoke($null, @([object]$s, [string]'theme_classic'))
    $currentField.SetValue($null, $savedPalette)
} finally {
    # Dispose the Program-owned reusable windows created above (test-scoped).
    $programType2 = $asm.GetType('Problip.Program', $true)
    foreach ($fname in @('_helpForm', '_statsForm', '_manualForm', '_themesForm')) {
        $f = $programType2.GetField($fname, [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
        if ($null -ne $f) { try { $f.Dispose() } catch { } }
    }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($failures) { Write-Host "FAILED ($failures failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
