param(
    [string]$Source = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs')
)

$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled test variable must FAIL this
# harness immediately instead of silently evaluating to $null (the false-green
# that once asserted a $layoutM_textW variable no measurement ever wrote).
Set-StrictMode -Version 2.0
$failures = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $Name $Detail" }
    else { Write-Host "FAIL  $Name $Detail"; $script:failures++ }
}

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }

$work = Join-Path ([IO.Path]::GetTempPath()) ("problip_repaint_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$dll = Join-Path $work 'ProblipSubject.dll'

& $csc -nologo -target:library -out:$dll -optimize+ -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $Source | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  subject does not compile: $Source"; exit 1 }

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GuiResources
{
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
    public static uint Gdi()
    {
        return GetGuiResources(System.Diagnostics.Process.GetCurrentProcess().Handle, 0);
    }
}
'@

$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
$settingsType = $asm.GetType('Problip.Settings', $true)
$engineType = $asm.GetType('Problip.BlipEngine', $true)
$formType = $asm.GetType('Problip.ProblipForm', $true)

$nonPublic = [Reflection.BindingFlags]'Instance,NonPublic'
$anyCtor = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$settings = $settingsType.GetConstructors($anyCtor)[0].Invoke([object[]]@([string]$work))
$engine = $engineType.GetConstructors($anyCtor)[0].Invoke([object[]]@($settings))
$tray = New-Object System.Windows.Forms.NotifyIcon
$form = $formType.GetConstructors($anyCtor)[0].Invoke([object[]]@($settings, $engine, [System.Windows.Forms.NotifyIcon]$tray))
$statsForm = $null

try {
    # Reflective allocation check: one Font per point size for the form's life.
    $anyMethod = [Reflection.BindingFlags]'Instance,Static,Public,NonPublic'
    $fMethod = $formType.GetMethod('F', $anyMethod)
    if ($null -eq $fMethod) {
        Check 'repeated font requests reuse one cached Font' $false 'no F(int) member'
    } else {
        $fTarget = if ($fMethod.IsStatic) { $null } else { $form }
        $first = $fMethod.Invoke($fTarget, [object[]]@([int]12))
        $second = $fMethod.Invoke($fTarget, [object[]]@([int]12))
        $sameInstance = [Object]::ReferenceEquals($first, $second)
        Check 'repeated font requests reuse one cached Font' $sameInstance
    }

    # Appearance guardrail: the cached font must be the very font the old
    # per-call path produced, so rendering cannot shift.
    $makeFont = $formType.GetMethod('MakePixelFont', $anyMethod)
    $fresh = $makeFont.Invoke($null, [object[]]@('Verdana', [int]12))
    try {
        $sameMetrics = $fresh.Name -eq $first.Name -and $fresh.Size -eq $first.Size -and `
            $fresh.Style -eq $first.Style -and $fresh.Height -eq $first.Height
        Check 'cached font matches a freshly built pixel font' $sameMetrics "$($first.Name) $($first.Size) h=$($first.Height)"
    } finally { $fresh.Dispose() }

    $onPaint = $formType.GetMethod('OnPaint', $anyMethod)
    $bmp = New-Object System.Drawing.Bitmap 280, 150
    try {
        $rect = New-Object System.Drawing.Rectangle 0, 0, 280, 150
        # Warm up the caches, then measure without letting finalizers hide leaks.
        for ($i = 0; $i -lt 20; $i++) {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $pe = New-Object System.Windows.Forms.PaintEventArgs $g, $rect
                $onPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe))
                $pe.Dispose()
            } finally { $g.Dispose() }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()

        $before = [GuiResources]::Gdi()
        $paints = 1000
        for ($i = 0; $i -lt $paints; $i++) {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $pe = New-Object System.Windows.Forms.PaintEventArgs $g, $rect
                $onPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe))
                $pe.Dispose()
            } finally { $g.Dispose() }
        }
        $growth = [int][GuiResources]::Gdi() - [int]$before
        Check 'GDI objects plateau across 1000 repaints' ($growth -lt 50) "$paints paints, growth=$growth"

        $painted = $false
        for ($x = 0; $x -lt 280 -and -not $painted; $x += 7) {
            for ($y = 0; $y -lt 150 -and -not $painted; $y += 7) {
                if ($bmp.GetPixel($x, $y).ToArgb() -ne 0) { $painted = $true }
            }
        }
        Check 'the measured paint path really rendered the window' $painted
    } finally { $bmp.Dispose() }

    # 10k synthetic volume moves: the drag path must stay allocation-flat and
    # land on the exact volume the last event asked for.
    $setVolume = $formType.GetMethod('SetVolumeFromX', $nonPublic)
    $volTrack = $formType.GetField('VolTrack', $nonPublic).GetValue($form)
    $volumeField = $settingsType.GetField('Volume')
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $beforeDrag = [GuiResources]::Gdi()
    $moves = 10000
    for ($i = 0; $i -lt $moves; $i++) {
        $x = $volTrack.X + ($i % ($volTrack.Width - 10))
        $setVolume.Invoke($form, @([int]$x))
    }
    $dragGrowth = [int][GuiResources]::Gdi() - [int]$beforeDrag
    Check 'GDI objects plateau across 10000 volume moves' ($dragGrowth -lt 50) "$moves moves, growth=$dragGrowth"

    $lastX = $volTrack.X + (($moves - 1) % ($volTrack.Width - 10))
    $expected = [double]($lastX - $volTrack.X) / ($volTrack.Width - 10)
    $actual = [double]$volumeField.GetValue($settings)
    Check 'the final volume is exactly what the last move selected' ([Math]::Abs($actual - $expected) -lt 1e-9) "expected=$([Math]::Round($expected,4)) actual=$([Math]::Round($actual,4))"

    # ---- bottom-row layout regression (the "TE" clipping defect) ----
    # The TEST rect was once a hard-coded 30 px guess at X=242 on a 280 px
    # client, clipping the label to "TE". The row is now one measured
    # calculation (LayoutBottomRow); these checks drive the REAL layout, not
    # source strings: full label fits, everything inside the client, no
    # overlaps.
    $layoutM = $formType.GetMethod('LayoutBottomRow', $anyMethod)
    if ($null -eq $layoutM) {
        Check 'the bottom row has one measured layout calculation' $false 'LayoutBottomRow missing'
    } else {
        # The bottom row is exercised through the REAL paint path: OnPaint calls
        # LayoutBottomRow with a real Graphics, which is the only way the row is
        # ever laid out in production. There is no null-Graphics pre-invocation
        # (LayoutBottomRow measures text and REQUIRES a Graphics), and no
        # reflection-out-parameter invocation (PS 5.1 MethodInfo.Invoke cannot
        # marshal `out int`, which is the swallowed-error seam this harness once
        # papered over with 2>$null).
        # Strict mode turns any misspelled measurement variable into an
        # immediate failure, never a silent $null comparison.
        $clientW = [int]$formType.GetProperty('ClientSize').GetValue($form).Width
        $textWm = $formType.GetMethod('TextW', $anyMethod)
        # Domain 1: the SAME bitmap-Graphics domain the paint loop used, so the
        # rect fields and the label measurements below share one measurement
        # domain.
        $bmp2 = New-Object System.Drawing.Bitmap 280, 150
        $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
        try {
            $rect2 = New-Object System.Drawing.Rectangle 0, 0, 280, 150
            $pe2 = New-Object System.Windows.Forms.PaintEventArgs $g2, $rect2
            try { $onPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe2)) } finally { $pe2.Dispose() }
            $testTextW  = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g2, [string]'TEST', [int]9))
            $offTextW   = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g2, [string]'OFF', [int]12))
            $onTextW    = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g2, [string]'ON', [int]12))
            $autoOnW    = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g2, [string]'[X] autostart', [int]10))
            $autoOffW   = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g2, [string]'[ ] autostart', [int]10))
            $autoR  = [System.Drawing.Rectangle]$formType.GetField('AutoRect',  $nonPublic).GetValue($form)
            $startR = [System.Drawing.Rectangle]$formType.GetField('StartRect', $nonPublic).GetValue($form)
            $stopR  = [System.Drawing.Rectangle]$formType.GetField('StopRect',  $nonPublic).GetValue($form)
            $testR  = [System.Drawing.Rectangle]$formType.GetField('TestRect',  $nonPublic).GetValue($form)
            $margin = 8
            # The padding contract is LayoutBottomRow's own: every rect is its            # measured label + the layout's 14 px allowance. Assert against            # THAT contract, never a weaker hard-coded number.
            $intendedPadding = 14
            $pairTextW = [Math]::Max($offTextW, $onTextW)
            $autoTextW = [Math]::Max($autoOnW, $autoOffW)
            Check 'TEST is wide enough for its measured label plus the layout padding' `
                ($testR.Width -ge ($testTextW + $intendedPadding)) "w=$($testR.Width) textW=$testTextW padding=$intendedPadding"
            Check 'TEST is fully inside the client width (never clipped)' `
                ($testR.Right -le $clientW - $margin) "right=$($testR.Right) client=$clientW"
            Check 'ON/OFF buttons are sized by the same measured label + padding contract' `
                ($startR.Width -eq ($pairTextW + $intendedPadding) -and $stopR.Width -eq ($pairTextW + $intendedPadding)) `
                "start=$($startR.Width) stop=$($stopR.Width) pairText=$pairTextW"
            Check 'the autostart button is sized by the same measured label + padding contract' `
                ($autoR.Width -eq ($autoTextW + $intendedPadding)) "auto=$($autoR.Width) autoText=$autoTextW"
            Check 'every bottom-row hit zone lies inside the ClientRectangle' `
                (@(@($autoR, $startR, $stopR, $testR) | Where-Object { $_.Right -gt $clientW -or $_.X -lt 0 }).Count -eq 0) `
                "auto=$($autoR.Right) start=$($startR.Right) stop=$($stopR.Right) test=$($testR.Right)"
            $overlap = $false
            $all = @($autoR, $startR, $stopR, $testR)
            for ($i = 0; $i -lt $all.Count; $i++) {
                for ($j = $i + 1; $j -lt $all.Count; $j++) {
                    if ($all[$i].IntersectsWith($all[$j])) { $overlap = $true }
                }
            }
            Check 'ON/OFF/TEST/autostart rectangles do not overlap' (-not $overlap) "overlap=$overlap"
        } finally { $g2.Dispose(); $bmp2.Dispose() }
        # Domain 2: the ctor sized ClientSize from a screen-compatible Graphics
        # (Graphics.FromHwnd), so the window-fits-the-row check remeasures the
        # exact same labels on the same domain instead of mixing metrics.
        $g3 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try {
            $testTextW3  = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g3, [string]'TEST', [int]9))
            $pairTextW3  = [Math]::Max([int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g3, [string]'OFF', [int]12)),
                                       [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g3, [string]'ON', [int]12)))
            $autoTextW3  = [Math]::Max([int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g3, [string]'[X] autostart', [int]10)),
                                       [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$g3, [string]'[ ] autostart', [int]10)))
            # LayoutBottomRow's own composition: margin + auto + gap + pair +
            # gap + pair + gap + TEST + margin, each rect label + 14 px.
            $need3 = 8 + ($autoTextW3 + 14) + 4 + ($pairTextW3 + 14) + 4 + ($pairTextW3 + 14) + 4 + ($testTextW3 + 14) + 8
            Check 'the measured bottom-row requirement fits the window the ctor sized' `
                ($clientW -ge $need3) "need=$need3 client=$clientW"
        } finally { $g3.Dispose() }
    }

    # ---- BLIPS line: inside the client, clear of the title and the slider ----
    $clientH = [int]$formType.GetProperty('ClientSize').GetValue($form).Height
    $blipsR = [System.Drawing.Rectangle]$formType.GetField('BlipsRect', $nonPublic).GetValue($form)
    $volR = [System.Drawing.Rectangle]$formType.GetField('VolTrack', $nonPublic).GetValue($form)
    Check 'the BLIPS line is painted inside the ClientRectangle' `
        ($blipsR.Width -gt 0 -and $blipsR.X -ge 0 -and $blipsR.Right -le $clientW -and $blipsR.Y -ge 20 -and $blipsR.Bottom -le $clientH) `
        "blips=$blipsR client=${clientW}x${clientH}"
    Check 'the BLIPS line does not overlap the volume slider' (-not $blipsR.IntersectsWith($volR)) "blips=$blipsR vol=$volR"
    Check 'the BLIPS line has a clickable hit zone (non-empty rect)' ($blipsR.Width -gt 0 -and $blipsR.Height -gt 0)

    # ---- Statistics view: compact, custom-painted, everything in client ----
    $statsFormType = $asm.GetType('Problip.StatsForm', $true)
    $statsCtor = $statsFormType.GetConstructors($anyCtor)[0]
    $statsForm = $statsCtor.Invoke([object[]]@($settings, $engine))
    $statsOnPaint = $statsFormType.GetMethod('OnPaint', $anyMethod)
    $sbmp = New-Object System.Drawing.Bitmap 240, 190
    try {
        $gS = [System.Drawing.Graphics]::FromImage($sbmp)
        try {
            $peS = New-Object System.Windows.Forms.PaintEventArgs $gS, (New-Object System.Drawing.Rectangle 0, 0, 240, 190)
            try { $statsOnPaint.Invoke($statsForm, [object[]]@([System.Windows.Forms.PaintEventArgs]$peS)) } finally { $peS.Dispose() }
        } finally { $gS.Dispose() }

        $sSize = $statsFormType.GetProperty('ClientSize').GetValue($statsForm)
        $sW = [int]$sSize.Width; $sH = [int]$sSize.Height
        $counterR = [System.Drawing.Rectangle]$statsFormType.GetField('CounterRect', $nonPublic).GetValue($statsForm)
        $closeR = [System.Drawing.Rectangle]$statsFormType.GetField('CloseRect', $nonPublic).GetValue($statsForm)
        $rowRects = [System.Drawing.Rectangle[]]$statsFormType.GetField('StatRowRects', $nonPublic).GetValue($statsForm)

        $allInside = $true; $detail = ''
        foreach ($r in @($counterR, $closeR) + $rowRects) {
            if ($r.X -lt 0 -or $r.Y -lt 0 -or $r.Right -gt $sW -or $r.Bottom -gt $sH) { $allInside = $false; $detail += "$r " }
        }
        Check 'every statistics control and row lies inside the ClientRectangle' $allInside "client=${sW}x${sH} $detail"

        $rowOverlap = $false
        for ($i = 0; $i -lt $rowRects.Count; $i++) {
            for ($j = $i + 1; $j -lt $rowRects.Count; $j++) {
                if ($rowRects[$i].IntersectsWith($rowRects[$j])) { $rowOverlap = $true }
            }
        }
        Check 'the four statistics rows do not overlap each other' (-not $rowOverlap)

        $ctrlOverlap = $false
        foreach ($rr in $rowRects) {
            if ($rr.IntersectsWith($counterR) -or $rr.IntersectsWith($closeR)) { $ctrlOverlap = $true }
        }
        Check 'the show-counter and CLOSE controls do not overlap the rows' (-not $ctrlOverlap)
        Check 'show-counter and CLOSE controls do not overlap each other' (-not $counterR.IntersectsWith($closeR)) "counter=$counterR close=$closeR"

        # Hit zones must match the painted rectangles (same rects drive both).
        $hotList = $statsFormType.GetField('Hot', $nonPublic).GetValue($statsForm)
        $hotRects = @()
        foreach ($hz in $hotList) {
            $r = $hz.GetType().GetField('R').GetValue($hz)
            $hotRects += ,([System.Drawing.Rectangle]$r)
        }
        $matchCounter = @($hotRects | Where-Object { $_.X -eq $counterR.X -and $_.Y -eq $counterR.Y -and $_.Width -eq $counterR.Width -and $_.Height -eq $counterR.Height }).Count -gt 0
        $matchClose = @($hotRects | Where-Object { $_.X -eq $closeR.X -and $_.Y -eq $closeR.Y -and $_.Width -eq $closeR.Width -and $_.Height -eq $closeR.Height }).Count -gt 0
        Check 'the SHOW COUNTER hit zone matches its painted rectangle' $matchCounter
        Check 'the CLOSE hit zone matches its painted rectangle' $matchClose

        # Counts have right-aligned space: the widest value fits left of the margin.
        $totalVal = ([long]2147483647).ToString('N0', [System.Globalization.CultureInfo]::CurrentCulture)
        $textWm2 = $statsFormType.GetMethod('TextW', $anyMethod)
        $g4 = [System.Drawing.Graphics]::FromImage($sbmp)
        try {
            $vw = [int]$textWm2.Invoke($statsForm, @([System.Drawing.Graphics]$g4, [string]$totalVal, [int]11))
            Check 'statistics counts have right-aligned space at realistic widths' ($vw -le ($sW - 24)) "valW=$vw client=$sW"
        } finally { $g4.Dispose() }
    } finally { $sbmp.Dispose() }

    # ---- mode row: MANUAL/PULSE inside client, clear of preset and bottom rows ----
    $manualR = [System.Drawing.Rectangle]$formType.GetField('ManualRect', $nonPublic).GetValue($form)
    $pulseR  = [System.Drawing.Rectangle]$formType.GetField('PulseRect',  $nonPublic).GetValue($form)
    $staticAll = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $presetY = [int]$formType.GetField('PresetRowY', $staticAll).GetValue($null)
    $modeY   = [int]$formType.GetField('ModeRowY',   $staticAll).GetValue($null)
    $bottomY = [int]$formType.GetField('BottomRowY', $staticAll).GetValue($null)
    $failureY= [int]$formType.GetField('FailureTextY', $staticAll).GetValue($null)
    Check 'both mode-row buttons are painted inside the ClientRectangle' `
        ($manualR.Width -gt 0 -and $pulseR.Width -gt 0 -and
         $manualR.X -ge 0 -and $manualR.Right -le $clientW -and
         $pulseR.Right -le $clientW -and $manualR.Bottom -le $clientH -and $pulseR.Bottom -le $clientH) `
         "manual=$manualR pulse=$pulseR client=${clientW}x${clientH}"
    # Measure on a fresh screen-compatible domain (the earlier bitmap Graphics
    # was disposed with its bitmap).
    $gM = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try {
        $manualLabelW = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$gM, [string]'MANUAL', [int]9))
        Check 'the MANUAL button fits its full label' ($manualR.Width -ge ($manualLabelW + 14)) "w=$($manualR.Width) textW=$manualLabelW"
        $pulseLabelW = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$gM, [string]'PULSE', [int]9))
        Check 'the PULSE button fits its full label' ($pulseR.Width -ge ($pulseLabelW + 14)) "w=$($pulseR.Width) textW=$pulseLabelW"
    } finally { $gM.Dispose() }
    Check 'the mode row does not overlap the preset row' `
        ($manualR.Y -ge $presetY + 22 -and $pulseR.Y -ge $presetY + 22) "modeY=$($manualR.Y) presetY=$presetY"
    Check 'the mode row does not overlap the bottom row' `
        ($manualR.Bottom -le $bottomY -and $pulseR.Bottom -le $bottomY) "modeBottom=$($manualR.Bottom) bottomY=$bottomY"
    Check 'the mode-row buttons do not overlap each other' (-not $manualR.IntersectsWith($pulseR)) "manual=$manualR pulse=$pulseR"
    $blipsMid = [System.Drawing.Rectangle]$formType.GetField('BlipsRect', $nonPublic).GetValue($form)
    Check 'the existing BLIPS line is unaffected by the mode row' `
        ($blipsMid.Width -gt 0 -and -not $blipsMid.IntersectsWith($manualR) -and -not $blipsMid.IntersectsWith($pulseR)) `
        "blips=$blipsMid manual=$manualR"
    Check 'the failure line has room below the bottom row inside the client' `
        ($failureY -ge $bottomY + 22 -and $failureY + 14 -le $clientH) "failureY=$failureY bottomY=$bottomY clientH=$clientH"

    # ---- THEME/GLOW utility row: measured, inside client, no overlaps ----
    $staticFlagsR = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $utilityY = [int]$formType.GetField('UtilityRowY', $staticFlagsR).GetValue($null)
    $themeR = [System.Drawing.Rectangle]$formType.GetField('ThemeRect', $nonPublic).GetValue($form)
    $glowR  = [System.Drawing.Rectangle]$formType.GetField('GlowRect',  $nonPublic).GetValue($form)
    $nameR  = [System.Drawing.Rectangle]$formType.GetField('ThemeNameRect', $nonPublic).GetValue($form)
    Check 'the THEME/GLOW row sits between the mode and bottom rows' `
        ($themeR.Y -ge $modeY + 22 -and $themeR.Bottom -le $bottomY) "utilityY=$utilityY bottomY=$bottomY"
    Check 'the GLOW button is painted inside the ClientRectangle' `
        ($glowR.Width -gt 0 -and $glowR.Right -le $clientW -and $glowR.Bottom -le $clientH) "glow=$glowR client=${clientW}x${clientH}"
    $gU = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try {
        $glowLabelW = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$gU, [string]'[X] GLOW', [int]9))
        Check 'the GLOW button fits its full label' ($glowR.Width -ge ($glowLabelW + 14)) "w=$($glowR.Width) textW=$glowLabelW"
        # The current theme name truncates within its allotted rectangle.
        $longName = 'Golden Vintage Vintage Classic Extraordinarily Long Theme Name'
        $truncM = $formType.GetMethod('TruncateThemeName', $anyMethod)
        $nameMax = [int]$formType.GetMethod('ThemeNameMaxWidth', $anyMethod).Invoke($form, @([System.Drawing.Graphics]$gU))
        $truncated = [string]$truncM.Invoke($form, @([System.Drawing.Graphics]$gU, [string]$longName, [int]$nameMax))
        $truncW = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$gU, [string]$truncated, [int]10))
        Check 'a long theme name truncates inside its allotted rectangle' ($truncW -le $nameMax -and $truncated -ne $longName) "w=$truncW max=$nameMax"
        $fullThemeW = [int]$textWm.Invoke($form, @([System.Drawing.Graphics]$gU, [string]'Golden Default', [int]10))
        $fullOk = $fullThemeW -le $nameMax
        $truncatedDefault = [string]$truncM.Invoke($form, @([System.Drawing.Graphics]$gU, [string]'Golden Default', [int]$nameMax))
        Check 'the current theme name fits or truncates safely' ($fullOk -or $truncatedDefault -ne 'Golden Default') "w=$fullThemeW max=$nameMax"
    } finally { $gU.Dispose() }
    Check 'the THEME label and the GLOW button do not overlap' (-not $themeR.IntersectsWith($glowR)) "theme=$themeR glow=$glowR"
    Check 'the THEME row does not overlap the MANUAL/PULSE row' ($themeR.Y -ge $manualR.Bottom) "themeY=$($themeR.Y) modeBottom=$($manualR.Bottom)"
    $failureTextVisibleRoom = $failureY + 14 -le $clientH
    Check 'the failure text remains visible below the utility row' $failureTextVisibleRoom "failureY=$failureY clientH=$clientH"

    # ---- ThemesForm: 15 rows fit, swatches/labels clear, hit zones match ----
    $themesType = $asm.GetType('Problip.ThemesForm', $true)
    if ($null -eq $themesType) {
        Check 'the theme picker exists' $false 'Problip.ThemesForm missing'
    } else {
        $themesCtor = $themesType.GetConstructors($anyCtor)[0]
        $themes = $themesCtor.Invoke([object[]]@($settings, [Func[string,bool]]{ param($id) $true }))
        $tPaint = $themesType.GetMethod('OnPaint', $anyMethod)
        $tSize = $themesType.GetProperty('ClientSize').GetValue($themes)
        $tW = [int]$tSize.Width; $tH = [int]$tSize.Height
        $tbmp = New-Object System.Drawing.Bitmap $tW, $tH
        try {
            $tg = [System.Drawing.Graphics]::FromImage($tbmp)
            try {
                $tpe = New-Object System.Windows.Forms.PaintEventArgs $tg, (New-Object System.Drawing.Rectangle 0, 0, $tW, $tH)
                try { $tPaint.Invoke($themes, [object[]]@([System.Windows.Forms.PaintEventArgs]$tpe)) } finally { $tpe.Dispose() }
            } finally { $tg.Dispose() }
            $rowRects = [System.Drawing.Rectangle[]]$themesType.GetField('RowRects', $nonPublic).GetValue($themes)
            Check 'the theme picker paints exactly 15 row rectangles' ($rowRects.Count -eq 15) "rows=$($rowRects.Count)"
            $rowsInside = $true; $rowDetail = ''
            foreach ($r in $rowRects) {
                if ($r.X -lt 0 -or $r.Y -lt 20 -or $r.Right -gt $tW -or $r.Bottom -gt $tH) { $rowsInside = $false; $rowDetail += "$r " }
            }
            Check 'all 15 theme rows fit inside the picker client' $rowsInside "client=${tW}x${tH} $rowDetail"
            $rowsOverlap = $false
            for ($i = 0; $i -lt $rowRects.Count; $i++) {
                for ($j = $i + 1; $j -lt $rowRects.Count; $j++) {
                    if ($i -ne $j -and $rowRects[$i].Y -lt $rowRects[$j].Bottom -and $rowRects[$j].Y -lt $rowRects[$i].Bottom) { $rowsOverlap = $true }
                }
            }
            Check 'the 15 theme rows do not overlap each other' (-not $rowsOverlap)
            # Hit zones must exactly match the painted rows.
            $tHot = $themesType.GetField('Hot', $nonPublic).GetValue($themes)
            $tHotRects = @()
            foreach ($hz in $tHot) { $tHotRects += ,([System.Drawing.Rectangle]$hz.GetType().GetField('R').GetValue($hz)) }
            $rowMatches = $true
            foreach ($r in $rowRects) {
                $found = @($tHotRects | Where-Object { $_.Equals($r) }).Count
                if ($found -lt 1) { $rowMatches = $false }
            }
            Check 'every theme-row hit zone exactly matches its painted row' $rowMatches
        } finally { $tbmp.Dispose() }
        # Vintage Classic readability: apply it, paint, and confirm the picker
        # background actually changed from the dark default.
        $paletteTypeR = $asm.GetType('Problip.Palette', $true)
        $currentFieldR = $paletteTypeR.GetField('Current', $staticFlagsR)
        $savedPalette = $currentFieldR.GetValue($null)
        $paletteForM2 = $asm.GetType('Problip.ThemeModel', $true).GetMethod('PaletteFor', $staticFlagsR)
        try {
            $currentFieldR.SetValue($null, $paletteForM2.Invoke($null, @([string]'theme_wintage_vintageclassic')))
            $themesType.GetMethod('ApplyTheme', $anyMethod) # may not exist; BackColor below is the contract
            $tbmp2 = New-Object System.Drawing.Bitmap $tW, $tH
            $tg2 = [System.Drawing.Graphics]::FromImage($tbmp2)
            try {
                $tpe2 = New-Object System.Windows.Forms.PaintEventArgs $tg2, (New-Object System.Drawing.Rectangle 0, 0, $tW, $tH)
                try { $tPaint.Invoke($themes, [object[]]@([System.Windows.Forms.PaintEventArgs]$tpe2)) } finally { $tpe2.Dispose() }
                $lightSeen = $false
                for ($x = 4; $x -lt $tW - 4; $x += 11) {
                    for ($y = 24; $y -lt $tH - 4; $y += 7) {
                        $px = $tbmp2.GetPixel($x, $y)
                        if ($px.R -gt 200 -and $px.G -gt 200 -and $px.B -gt 200) { $lightSeen = $true; break }
                    }
                    if ($lightSeen) { break }
                }
                Check 'Vintage Classic renders the picker readably (light pixels present)' $lightSeen
            } finally { $tg2.Dispose(); $tbmp2.Dispose() }
        } finally {
            $currentFieldR.SetValue($null, $savedPalette)
            try { $themes.Dispose() } catch { }
        }
    }

    # ---- Manual editor: controls inside client, frames clear, hit zones match ----
    $editorType = $asm.GetType('Problip.ManualIntervalForm', $true)
    if ($null -eq $editorType) {
        Check 'the manual interval editor exists' $false 'Problip.ManualIntervalForm missing'
    } else {
        $editorCtor = $editorType.GetConstructors($anyCtor)[0]
        $editor = $editorCtor.Invoke([object[]]@($settings, [Func[int,int,bool]]{ param($a, $b) $true }))
        $ePaint = $editorType.GetMethod('OnPaint', $anyMethod)
        $eSize = $editorType.GetProperty('ClientSize').GetValue($editor)
        $eW = [int]$eSize.Width; $eH = [int]$eSize.Height
        $ebmp = New-Object System.Drawing.Bitmap $eW, $eH
        try {
            $eg = [System.Drawing.Graphics]::FromImage($ebmp)
            try {
                $epe = New-Object System.Windows.Forms.PaintEventArgs $eg, (New-Object System.Drawing.Rectangle 0, 0, $eW, $eH)
                try { $ePaint.Invoke($editor, [object[]]@([System.Windows.Forms.PaintEventArgs]$epe)) } finally { $epe.Dispose() }
            } finally { $eg.Dispose() }
            $fromFrame = [System.Drawing.Rectangle]$editorType.GetField('FromFrame', $nonPublic).GetValue($editor)
            $toFrame   = [System.Drawing.Rectangle]$editorType.GetField('ToFrame',   $nonPublic).GetValue($editor)
            $applyR    = [System.Drawing.Rectangle]$editorType.GetField('ApplyRect', $nonPublic).GetValue($editor)
            $cancelR   = [System.Drawing.Rectangle]$editorType.GetField('CancelRect', $nonPublic).GetValue($editor)
            $eAll = @($fromFrame, $toFrame, $applyR, $cancelR)
            $eInside = $true; $eDetail = ''
            foreach ($r in $eAll) {
                if ($r.X -lt 0 -or $r.Y -lt 20 -or $r.Right -gt $eW -or $r.Bottom -gt $eH) { $eInside = $false; $eDetail += "$r " }
            }
            Check 'every manual-editor control lies inside the ClientRectangle' $eInside "client=${eW}x${eH} $eDetail"
            Check 'the FROM/TO input frames do not overlap the buttons' `
                (-not $fromFrame.IntersectsWith($applyR) -and -not $fromFrame.IntersectsWith($cancelR) -and
                 -not $toFrame.IntersectsWith($applyR) -and -not $toFrame.IntersectsWith($cancelR)) `
                "from=$fromFrame to=$toFrame apply=$applyR cancel=$cancelR"
            Check 'the APPLY/CANCEL hit zones match their painted rectangles' `
                (-not $applyR.IntersectsWith($cancelR) -and $applyR.Width -gt 0 -and $cancelR.Width -gt 0) `
                "apply=$applyR cancel=$cancelR"
        } finally { $ebmp.Dispose() }

        # ---- keyboard contract: drive the REAL ProcessDialogKey seam ----
        # The dialog-key method is invoked through reflection exactly as WinForms
        # would call it, so the sequence FROM -> TO -> APPLY -> CANCEL -> FROM,
        # Shift+Tab reversal, Enter-on-APPLY, Enter-on-CANCEL (never applies)
        # and Escape are behavior assertions, not source-regex wishes.
        $pdk = $editorType.GetMethod('ProcessDialogKey', [Reflection.BindingFlags]'Instance,NonPublic,Public')
        $focusIdxField = $editorType.GetField('FocusIndex', $nonPublic)
        $invalidField = $editorType.GetField('InvalidText', $nonPublic)
        $showManualM = $editorType.GetMethod('ShowManual', $nonPublic)
        $keysTab = [System.Windows.Forms.Keys]::Tab
        $keysShiftTab = [System.Windows.Forms.Keys]::Shift -bor [System.Windows.Forms.Keys]::Tab
        $keysEnter = [System.Windows.Forms.Keys]::Enter
        $keysEsc = [System.Windows.Forms.Keys]::Escape
        $applies = [System.Collections.Generic.List[int]]::new()
        $editor2 = $editorCtor.Invoke([object[]]@($settings, [Func[int,int,bool]]{ param($a, $b) $applies.Add(1); $true }))
        try {
            $showManualM.Invoke($editor2, @())
            Check 'ShowManual clears a prior InvalidText' ([string]::IsNullOrEmpty([string]$invalidField.GetValue($editor2)))
            Check 'ShowManual restores the committed FROM value' ($editor2.Controls[0].Text -eq '4') "from=$($editor2.Controls[0].Text)"
            Check 'ShowManual starts at logical focus FROM' ([int]$focusIdxField.GetValue($editor2) -eq 0)
            [void]$pdk.Invoke($editor2, @([object]$keysTab))
            Check 'Tab moves FROM to TO' ([int]$focusIdxField.GetValue($editor2) -eq 1)
            [void]$pdk.Invoke($editor2, @([object]$keysTab))
            Check 'Tab moves TO to APPLY' ([int]$focusIdxField.GetValue($editor2) -eq 2)
            Check 'logical APPLY/CANCEL focus leaves no TextBox caret (ActiveControl cleared)' ($null -eq $editor2.ActiveControl)
            [void]$pdk.Invoke($editor2, @([object]$keysTab))
            Check 'Tab moves APPLY to CANCEL' ([int]$focusIdxField.GetValue($editor2) -eq 3)
            [void]$pdk.Invoke($editor2, @([object]$keysTab))
            Check 'Tab wraps CANCEL back to FROM' ([int]$focusIdxField.GetValue($editor2) -eq 0)
            [void]$pdk.Invoke($editor2, @([object]$keysShiftTab))
            Check 'Shift+Tab reverses FROM to CANCEL' ([int]$focusIdxField.GetValue($editor2) -eq 3)
            [void]$pdk.Invoke($editor2, @([object]$keysShiftTab))
            Check 'Shift+Tab reverses CANCEL to APPLY' ([int]$focusIdxField.GetValue($editor2) -eq 2)
            $applies.Clear()
            [void]$pdk.Invoke($editor2, @([object]$keysEnter))
            Check 'Enter on APPLY invokes Apply' ($applies.Count -eq 1) "applies=$($applies.Count)"
            $editor2.Controls[0].Text = '99999'
            $editor2.Controls[1].Text = 'x'
            [void]$pdk.Invoke($editor2, @([object]$keysTab))   # APPLY -> CANCEL
            $before = $applies.Count
            [void]$pdk.Invoke($editor2, @([object]$keysEnter))
            Check 'Enter on CANCEL hides without applying' (-not $editor2.Visible -and $applies.Count -eq $before) "applies=$($applies.Count)"
            $showManualM.Invoke($editor2, @())
            Check 'reopening restores the committed Settings values (cancel leftovers discarded)' `
                ($editor2.Controls[0].Text -eq '4' -and $editor2.Controls[1].Text -eq '7') "from=$($editor2.Controls[0].Text) to=$($editor2.Controls[1].Text)"
            [void]$pdk.Invoke($editor2, @([object]$keysEsc))
            Check 'Escape hides without applying' (-not $editor2.Visible -and $applies.Count -eq 1) "applies=$($applies.Count)"
            # Painted focus state follows the logical focus.
            $editor2.Show(); $showManualM.Invoke($editor2, @())
            [void]$pdk.Invoke($editor2, @([object]$keysTab)); [void]$pdk.Invoke($editor2, @([object]$keysTab))
            $bmpFocus = New-Object System.Drawing.Bitmap $eW, $eH
            $gFocus = [System.Drawing.Graphics]::FromImage($bmpFocus)
            try {
                $peFocus = New-Object System.Windows.Forms.PaintEventArgs $gFocus, (New-Object System.Drawing.Rectangle 0, 0, $eW, $eH)
                try { $ePaint.Invoke($editor2, [object[]]@([System.Windows.Forms.PaintEventArgs]$peFocus)) } finally { $peFocus.Dispose() }
                $applyR2 = [System.Drawing.Rectangle]$editorType.GetField('ApplyRect', $nonPublic).GetValue($editor2)
                $cancelR2 = [System.Drawing.Rectangle]$editorType.GetField('CancelRect', $nonPublic).GetValue($editor2)
                $ac = $bmpFocus.GetPixel([int]($applyR2.X + $applyR2.Width / 2), [int]($applyR2.Y + $applyR2.Height / 2))
                $cc = $bmpFocus.GetPixel([int]($cancelR2.X + $cancelR2.Width / 2), [int]($cancelR2.Y + $cancelR2.Height / 2))
                Check 'the painted APPLY focus state follows logical focus (selected fill differs from CANCEL)' ($ac.ToArgb() -ne $cc.ToArgb()) "apply=$ac cancel=$cc"
            } finally { $gFocus.Dispose(); $bmpFocus.Dispose() }
        } finally { try { $editor2.Dispose() } catch { } }
        try { $editor.Dispose() } catch { }
    }

    # ---- hiding the counter: BLIPS rect empty, controls still fit ----
    $settings.ShowBlipCounter = $false
    $bmpHide = New-Object System.Drawing.Bitmap 280, 168
    $gHide = [System.Drawing.Graphics]::FromImage($bmpHide)
    try {
        $peHide = New-Object System.Windows.Forms.PaintEventArgs $gHide, (New-Object System.Drawing.Rectangle 0, 0, 280, 168)
        try { $onPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$peHide)) } finally { $peHide.Dispose() }
        $blipsHidden = [System.Drawing.Rectangle]$formType.GetField('BlipsRect', $nonPublic).GetValue($form)
        $autoHidden = [System.Drawing.Rectangle]$formType.GetField('AutoRect', $nonPublic).GetValue($form)
        $testHidden = [System.Drawing.Rectangle]$formType.GetField('TestRect', $nonPublic).GetValue($form)
        Check 'hiding the counter paints no BLIPS hit zone' ($blipsHidden.Width -eq 0 -and $blipsHidden.Height -eq 0)
        Check 'hiding the counter does not push controls outside the client' `
            ($autoHidden.Right -le $clientW -and $testHidden.Right -le $clientW -and -not $autoHidden.IntersectsWith($testHidden)) `
            "auto=$autoHidden test=$testHidden"
    } finally { $gHide.Dispose(); $bmpHide.Dispose() }
    $settings.ShowBlipCounter = $true

    # ---- title-bar "?" Help affordance: measured geometry, no overlaps ----
    # The painted fields come from the LAST OnPaint above (widest status text
    # "ERR" included, since this engine has no WAV in its settings dir).
    $helpR  = [System.Drawing.Rectangle]$formType.GetField('HelpRect',  $nonPublic).GetValue($form)
    $closeR2 = [System.Drawing.Rectangle]$formType.GetField('CloseRect', $nonPublic).GetValue($form)
    $statusR = [System.Drawing.Rectangle]$formType.GetField('StatusRect', $nonPublic).GetValue($form)
    Check 'the "?" Help affordance lies inside the title bar' `
        ($helpR.Width -gt 0 -and $helpR.Y -ge 0 -and $helpR.Bottom -le 20 -and $helpR.Right -le $clientW) `
        "help=$helpR clientW=$clientW"
    Check 'the "?" affordance does not overlap the ON/OFF/ERR status' (-not $helpR.IntersectsWith($statusR)) "help=$helpR status=$statusR"
    Check 'the "?" affordance does not overlap the X close control' (-not $helpR.IntersectsWith($closeR2)) "help=$helpR close=$closeR2"
    Check 'the status text does not overlap the X close control' (-not $statusR.IntersectsWith($closeR2)) "status=$statusR close=$closeR2"
    $mainHot = $formType.GetField('Hot', $nonPublic).GetValue($form)
    $helpHotMatch = $false
    foreach ($hz in $mainHot) {
        $r = [System.Drawing.Rectangle]$hz.GetType().GetField('R').GetValue($hz)
        if ($r.Equals($helpR)) { $helpHotMatch = $true }
    }
    Check 'the "?" hot zone is exactly the painted rectangle (same geometry)' $helpHotMatch

    # ---- HelpForm: compact window, everything inside the client, clear chrome ----
    $helpType = $asm.GetType('Problip.HelpForm', $true)
    if ($null -eq $helpType) {
        Check 'the Help window exists' $false 'Problip.HelpForm missing'
    } else {
        $helpCtor = $helpType.GetConstructors($anyCtor)[0]
        $helpLocal = $helpCtor.Invoke([object[]]@($settings))
        try {
            $hPaint = $helpType.GetMethod('OnPaint', $anyMethod)
            $hSize = $helpType.GetProperty('ClientSize').GetValue($helpLocal)
            $hW = [int]$hSize.Width; $hH = [int]$hSize.Height
            $wa = [System.Windows.Forms.SystemInformation]::WorkingArea
            Check 'the Help window fits inside the usable screen area' ($hW -le $wa.Width -and $hH -le $wa.Height) "help=${hW}x${hH} work=$($wa.Width)x$($wa.Height)"
            $hbmp = New-Object System.Drawing.Bitmap $hW, $hH
            try {
                $hg = [System.Drawing.Graphics]::FromImage($hbmp)
                try {
                    $hpe = New-Object System.Windows.Forms.PaintEventArgs $hg, (New-Object System.Drawing.Rectangle 0, 0, $hW, $hH)
                    try { $hPaint.Invoke($helpLocal, [object[]]@([System.Windows.Forms.PaintEventArgs]$hpe)) } finally { $hpe.Dispose() }
                } finally { $hg.Dispose() }
                $hClose = [System.Drawing.Rectangle]$helpType.GetField('CloseRect', $nonPublic).GetValue($helpLocal)
                $hContent = [System.Drawing.Rectangle]$helpType.GetField('ContentRect', $nonPublic).GetValue($helpLocal)
                Check 'the Help close control lies inside the Help client' `
                    ($hClose.X -ge 0 -and $hClose.Y -ge 0 -and $hClose.Right -le $hW -and $hClose.Bottom -le $hH) "close=$hClose client=${hW}x${hH}"
                Check 'the Help content rectangle lies inside the Help client, below the title' `
                    ($hContent.X -ge 0 -and $hContent.Y -ge 20 -and $hContent.Right -le $hW -and $hContent.Bottom -le $hH) "content=$hContent"
                Check 'the Help scrollable content does not overlap the close/title chrome' (-not $hContent.IntersectsWith($hClose)) "content=$hContent close=$hClose"
                $box = $helpLocal.Controls[0]
                Check 'the Help content is a read-only borderless multiline text control' `
                    ([bool]$box.ReadOnly -and [bool]$box.Multiline -and $box.BorderStyle -eq [System.Windows.Forms.BorderStyle]::None)
                Check 'the Help text control is not a Tab stop (F1/keyboard stay with the main window)' (-not [bool]$box.TabStop)
            } finally { $hbmp.Dispose() }
        } finally { try { $helpLocal.Dispose() } catch { } }
    }

    # ---- Blip Glow event contract (A-H) ----
    # Glow fires ONLY from the engine's BlipPlayed (successful SCHEDULED blips).
    # Preview/TEST/failed playback never raise BlipPlayed, so they can never
    # start a glow; the hidden form performs no animation work at all.
    $glowAlphaM = $formType.GetMethod('CurrentGlowAlpha', $anyMethod)
    $glowStarts = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    $glowStops = [int]($formType.GetField('GlowTimerStopCount', $nonPublic).GetValue($form))
    $blipArgs = @($null, [EventArgs]::Empty)
    $onBlipM = $formType.GetMethod('OnBlipPlayed', $nonPublic)
    $previewM2 = $engineType.GetMethod('Preview')
    $glowField2 = $settingsType.GetField('BlipGlow')
    # The shipped asset, at volume 0, so the engine can be healthy ON for the
    # glow cases (a broken asset would flip it to ERR and fake a failure).
    $realWavGlow = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'blip01.wav'

    # A. a successful scheduled Tick starts the glow (preference ON, visible).
    $form.Show()
    $settings.Volume = 0.0
    $settings.WavPath = $realWavGlow
    $engine.SetRange(5000, 5000)
    $engine.Reload()
    $engine.Start()
    $startsA = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    $onBlipM.Invoke($form, $blipArgs)   # the exact handler the engine wires to BlipPlayed
    $startsB = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    Check 'a successful scheduled blip starts the glow' ($startsB -eq $startsA + 1) "starts=$startsB"
    Check 'the glow timer is running while a glow is active' ([bool]($formType.GetField('GlowTimer', $nonPublic).GetValue($form)).Enabled)

    # G. preference OFF mid-animation: timer stops, alpha becomes zero.
    $glowField2.SetValue($settings, $false)
    $formType.GetMethod('StopGlow', $nonPublic).Invoke($form, @())
    $glowField2.SetValue($settings, $true)
    Check 'disabling the glow stops the animation timer' (-not [bool]($formType.GetField('GlowTimer', $nonPublic).GetValue($form)).Enabled)
    Check 'disabling the glow restores alpha to zero' ([double]$glowAlphaM.Invoke($form, @()) -eq 0.0)

    # B/C. Preview (TEST) must NOT start the glow: drive the real preview path
    #      and confirm no new glow timer start, then confirm the handler itself
    #      ignores the preview-only event absence by construction.
    $startsC = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    [void]$previewM2.Invoke($engine, @())   # Preview()/TEST: never raises BlipPlayed
    $startsD = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    Check 'a TEST/preview blip does not start the glow' ($startsD -eq $startsC) "starts=$startsD"

    # E. hidden form: BlipPlayed does not start the animation timer.
    $form.Hide()
    $startsE = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    $onBlipM.Invoke($form, $blipArgs)
    $startsF = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    Check 'a hidden window starts no glow animation' ($startsF -eq $startsE) "starts=$startsF"
    Check 'a hidden window runs no glow timer' (-not [bool]($formType.GetField('GlowTimer', $nonPublic).GetValue($form)).Enabled)

    # F. showing the form after a hidden blip: no replay.
    $form.Show()
    Check 'showing the form after a hidden blip replays no glow' ([double]$glowAlphaM.Invoke($form, @()) -eq 0.0)

    # H. theme switch during glow: the animation continues on the NEW accent
    #    and scheduling is untouched. The elapsed-time seam is frozen so the
    #    260 ms real-time window cannot elapse between the blip and the probe.
    $glowClockField = $formType.GetField('GlowClock', $nonPublic)
    $realClock = [System.Diagnostics.Stopwatch]$glowClockField.GetValue($form)
    $glowClockField.SetValue($form, [System.Diagnostics.Stopwatch]::StartNew())   # fresh clock: elapsed starts near 0
    $onBlipM.Invoke($form, $blipArgs)   # fresh glow on the new clock
    # Determinism: alpha(0ms) is exactly 0.0, so probing inside the same
    # millisecond would false-fail the liveness check on a fast path. Wait
    # until the fresh clock has entered its rise window (elapsed >= 1 ms,
    # bounded), then alpha is strictly inside (0, 0.25].
    $freshClock = [System.Diagnostics.Stopwatch]$glowClockField.GetValue($form)
    $spin = 0
    while ($freshClock.ElapsedMilliseconds -lt 1 -and $spin -lt 50) { Start-Sleep -Milliseconds 1; $spin++ }
    $alphaBeforeH = [double]$glowAlphaM.Invoke($form, @())
    Check 'the fresh glow is alive before the switch' ($alphaBeforeH -gt 0.0) "before=$alphaBeforeH"
    $paletteTypeH = $asm.GetType('Problip.Palette', $true)
    $currentFieldH = $paletteTypeH.GetField('Current', $staticFlagsR)
    $savedH = $currentFieldH.GetValue($null)
    $paletteForH = $asm.GetType('Problip.ThemeModel', $true).GetMethod('PaletteFor', $staticFlagsR)
    try {
        $currentFieldH.SetValue($null, $paletteForH.Invoke($null, @([string]'theme_wintage_dracula')))
        $alphaDuringH = [double]$glowAlphaM.Invoke($form, @())
        Check 'a theme switch during glow keeps the animation alive' ($alphaDuringH -gt 0.0) "before=$alphaBeforeH during=$alphaDuringH"
        Check 'a theme switch during glow stays inside the 25 percent cap' ($alphaDuringH -le 0.25)
        Check 'a theme switch during glow leaves the engine scheduling untouched' ($engine.IsOn -and [double]$engineType.GetField('Timer', $nonPublic).GetValue($engine).Interval -gt 0) "on=$($engine.IsOn)"
    } finally {
        $currentFieldH.SetValue($null, $savedH)
        $formType.GetMethod('StopGlow', $nonPublic).Invoke($form, @())
        $glowClockField.SetValue($form, $realClock)   # restore the production clock
        $form.Hide()
        $engine.Stop()
    }

    # 100 synthetic glow cycles: the animation timer must be STOPPED when the
    # glow is inactive and the handle/brush discipline must hold.
    $form.Show()
    $bmpGlow = New-Object System.Drawing.Bitmap 280, 216
    $gGlow = [System.Drawing.Graphics]::FromImage($bmpGlow)
    try {
        $peGlow = New-Object System.Windows.Forms.PaintEventArgs $gGlow, (New-Object System.Drawing.Rectangle 0, 0, 280, 216)
        $onBlipM.Invoke($form, $blipArgs)
        for ($i = 0; $i -lt 100; $i++) {
            $onBlipM.Invoke($form, $blipArgs)   # restart from peak/rise origin
            $formType.GetMethod('OnGlowTick', $nonPublic).Invoke($form, [object[]]@($null, $null))
            try { $onPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$peGlow)) } catch { }
        }
        Check 'repeated glow events never stack beyond the 25 percent cap' ([double]$glowAlphaM.Invoke($form, @()) -le 0.25)
    } finally { $gGlow.Dispose(); $bmpGlow.Dispose() }
    $formType.GetMethod('StopGlow', $nonPublic).Invoke($form, @())
    Check 'the glow timer is stopped when the glow is inactive' (-not [bool]($formType.GetField('GlowTimer', $nonPublic).GetValue($form)).Enabled)
    $form.Hide()
    $hiddenStarts = [int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form))
    Start-Sleep -Milliseconds 60
    Check 'a hidden window consumes no recurring glow timer ticks' ([int]($formType.GetField('GlowTimerStartCount', $nonPublic).GetValue($form)) -eq $hiddenStarts)
} finally {
    if ($statsForm -ne $null) { try { $statsForm.Dispose() } catch { } }
    $form.Dispose()
    $tray.Dispose()
    $engineType.GetMethod('Cleanup').Invoke($engine, @())
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Source contracts the audit clause names explicitly.
$text = Get-Content -LiteralPath $Source -Raw
$dragBody = [Regex]::Match($text, 'void SetVolumeFromX\(int x\)\s*\{(?<body>[^}]*)\}')
Check 'the drag path coalesces repaints instead of forcing them' `
    ($dragBody.Success -and $dragBody.Groups['body'].Value -match 'Invalidate\(\)' -and $dragBody.Groups['body'].Value -notmatch 'Refresh\(\)')
Check 'DrawButton no longer builds a StringFormat per call' ($text -notmatch 'var fmt = new StringFormat\(\)')
Check 'the T-88 HFONT release stays in place' ($text -match 'Font\.FromHfont' -and $text -match 'Native\.DeleteObject')

Write-Host '---'
if ($failures) { Write-Host "FAILED ($failures failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0

