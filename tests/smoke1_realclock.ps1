# Smoke layer 1: drive the REAL compiled Problip.exe binary under its REAL
# production clock (no fake NowMs, no debugger). Engine-only: touches no user
# INI, no Run key, no tray, no audio output (volume 0).
$ErrorActionPreference = 'Stop'
$root = 'V:\___VAC\__K\__CODE\_PY\_PROBLIP'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { Write-Host "PASS  $n  $d" } else { Write-Host "FAIL  $n  $d"; $script:fails++ }
}

$sandbox = Join-Path $env:TEMP ('problip_smoke1_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

$asm = [Reflection.Assembly]::LoadFile((Join-Path $root 'Problip.exe'))
$flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$st = $asm.GetType('Problip.Settings')
$et = $asm.GetType('Problip.BlipEngine')
$ft = $asm.GetType('Problip.ProblipForm')
$sCtor = $st.GetConstructor($flags, $null, @([string]), $null)
$eCtor = $et.GetConstructor($flags, $null, @($st), $null)
$fCtor = $ft.GetConstructor($flags, $null, @($st, $et, [System.Windows.Forms.NotifyIcon]), $null)
$nextDue = $et.GetField('NextDueMs', $flags)
$schedF  = $et.GetField('ScheduledPlayCount', $flags)
$nowF    = $et.GetField('NowMs', $flags)

# Volume 0: real playback path, silent. Fixed 5 s interval for the tick replay.
$s = $sCtor.Invoke(@([string]$sandbox))
$s.WavPath = [string](Join-Path $root 'blip01.wav')
$s.Volume = 0.0
$s.MinMs = 5000
$s.MaxMs = 5000
$eng = $eCtor.Invoke(@($s))
$timer = [System.Windows.Forms.Timer]$et.GetField('Timer', $flags).GetValue($eng)
$realNow = { param($e) [long]$nowF.GetValue($e).Invoke() }

# --- Start idempotency under the REAL production clock ---
$eng.Start()
$due0 = [long]$nextDue.GetValue($eng)
$iv0 = [double]$timer.Interval
Check 'real EXE: Start is ON with the timer armed' ($eng.IsOn -and $timer.Enabled) "on=$($eng.IsOn) iv=$iv0"
$now0 = & $realNow $eng
Check 'real EXE: the first blip is due one full interval out' (($due0 - $now0) -ge 4900 -and ($due0 - $now0) -le 5010) "due-now=$($due0 - $now0)"

Start-Sleep -Milliseconds 150    # real time passes; the real Stopwatch advances
$eng.Start()                     # the already-ON Start path
$due1 = [long]$nextDue.GetValue($eng)
$iv1 = [double]$timer.Interval
Check 'real EXE + REAL CLOCK: Start while already ON does not move NextDueMs' ($due1 -eq $due0) "due=$due1 original=$due0"
Check 'real EXE + REAL CLOCK: Start while already ON does not redraw the interval' ($iv1 -eq $iv0) "iv=$iv1 original=$iv0"
Check 'real EXE: still ON after the redundant Start' ($eng.IsOn -and $timer.Enabled) "on=$($eng.IsOn)"

# --- Three sequential ticks under the REAL production clock (the exact
#     production replay of the old broken-clock defect) ---
$tick = $et.GetMethod('Tick', $flags)
for ($i = 1; $i -le 3; $i++) {
    Start-Sleep -Milliseconds 5050          # real clock reaches the due point
    $tick.Invoke($eng, @($null, [EventArgs]::Empty))
    $c = [int]$schedF.GetValue($eng)
    Check "real EXE + REAL CLOCK: scheduled tick $i really played" ($c -eq $i) "scheduled=$c"
}
Check 'real EXE: still ON with the 5 s cadence intact after three plays' `
    ($eng.IsOn -and [double]$timer.Interval -eq 5000 -and $timer.Enabled) "iv=$($timer.Interval) on=$($eng.IsOn)"

# --- Preview immediately before the next due tick ---
$dueBefore = [long]$nextDue.GetValue($eng)
$okP = $eng.Preview()
$dueAfter = [long]$nextDue.GetValue($eng)
Check 'real EXE: TEST preview plays without moving the cadence' `
    ($okP -and $dueAfter -eq $dueBefore -and $eng.PreviewCount -eq 1 -and [int]$schedF.GetValue($eng) -eq 3) `
    "due=$dueAfter orig=$dueBefore previews=$($eng.PreviewCount) scheduled=$([int]$schedF.GetValue($eng))"
Start-Sleep -Milliseconds 5050
$tick.Invoke($eng, @($null, [EventArgs]::Empty))
Check 'real EXE: the due tick after a preview still plays (count 4)' ([int]$schedF.GetValue($eng) -eq 4) "scheduled=$([int]$schedF.GetValue($eng))"

# --- Tray caption: the real EXE must decode the UTF-8 em dash correctly ---
$em = [string][char]0x2014
$want = 'problip ' + $em + ' ON'
Check 'real EXE: tray caption reports "problip — ON" intact' ($eng.TrayCaption -eq $want) "tray=$($eng.TrayCaption)"

# --- Screenshot the real form (the whole TEST label must be rendered) ---
$tray = New-Object System.Windows.Forms.NotifyIcon
$form = $fCtor.Invoke(@($s, $eng, [System.Windows.Forms.NotifyIcon]$tray))
$form.Show()
for ($i = 0; $i -lt 8; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinCap {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static System.Drawing.Bitmap Capture(IntPtr hwnd) {
        RECT r; GetWindowRect(hwnd, out r);
        int w = r.R - r.L, h = r.B - r.T;
        if (w <= 0 || h <= 0) return null;
        System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(w, h);
        using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            try { PrintWindow(hwnd, hdc, 2); } finally { g.ReleaseHdc(hdc); }
        }
        return bmp;
    }
}
'@ -ReferencedAssemblies System.Drawing
$png = Join-Path $root '.freebuff\smoke_TEST_label.png'
$bmp = [WinCap]::Capture($form.Handle)
if ($bmp) { $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() }
Check 'real EXE: the real settings window was captured for the TEST-label check' (Test-Path $png) "png=$png"

# Pixel check on the capture: the TEST label is drawn in Palette.TEXT over the
# RAISED button fill, inside the bottom-right row. TestRect is in CLIENT
# coordinates; the capture is the WINDOW rect, so shift by the frame offset.
$tr = $ft.GetField('TestRect', $flags).GetValue($form)
$clOrigin = $form.PointToScreen([System.Drawing.Point]::Empty)
$winRect = New-Object WinCap+RECT
[WinCap]::GetWindowRect($form.Handle, [ref]$winRect) | Out-Null
$offX = $clOrigin.X - $winRect.L
$offY = $clOrigin.Y - $winRect.T
# Palette.TEXT is D4C89A; TEXT2 (9C9371) is dimmer. The old defect rendered
# only the clipped prefix "TE", so the honest oracle is: glyph pixels exist in
# the RIGHT HALF of the rect too, not merely somewhere in it.
$textPixels = 0
$rightHalf = 0
if ($bmp2 = [System.Drawing.Bitmap]::FromFile($png)) {
    $midX = $tr.X + $offX + [int]($tr.Width / 2)
    for ($x = $tr.X + $offX + 2; $x -lt $tr.Right + $offX - 2; $x++) {
        for ($y = $tr.Y + $offY + 2; $y -lt $tr.Bottom + $offY - 2; $y++) {
            $px = $bmp2.GetPixel([Math]::Min($x, $bmp2.Width - 1), [Math]::Min($y, $bmp2.Height - 1))
            if ($px.R -gt 180 -and $px.G -gt 170 -and $px.B -gt 130) {
                $textPixels++
                if ($x -ge $midX) { $rightHalf++ }
            }
        }
    }
    $bmp2.Dispose()
}
Check 'real EXE: TEST label glyphs render across the whole rect (full TEST, never clipped to TE)' `
    ($textPixels -ge 20 -and $rightHalf -ge 1) "textPixels=$textPixels rightHalf=$rightHalf png=$png"

$form.Hide(); $form.Dispose(); $tray.Dispose()
$eng.Cleanup()
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '---'
if ($fails) { Write-Host "SMOKE1 FAILED ($fails failure(s))"; exit 1 }
Write-Host 'SMOKE1 PASS (0 failures)'
exit 0
