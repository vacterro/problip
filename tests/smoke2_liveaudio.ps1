# Smoke layer 2: the REAL launched Problip.exe, audible, observed through the
# Windows audio peak meter (WASAPI IAudioMeterInformation on the default render
# device). Records the wall-clock times of scheduled blips for the 5 s cadence.
# The real problip.ini is backed up and restored byte-for-byte; the temp INI
# carries AutoStart=1 to match the pre-existing Run entry, so the app's boot
# projection rewrites the identical value (no registry churn).
$ErrorActionPreference = 'Stop'
$root = 'V:\___VAC\__K\__CODE\_PY\_PROBLIP'
Add-Type -AssemblyName System

$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { Write-Host "PASS  $n  $d" } else { Write-Host "FAIL  $n  $d"; $script:fails++ }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PeakWrap {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int NotImpl0();
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        float GetPeakValue();
    }
    public static class Meter {
        public static object Create() {
            IEnumerator e = null;
            var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            IMMDevice dev;
            int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);   // eRender, eMultimedia
            if (hr != 0) throw new Exception("GetDefaultAudioEndpoint hr=0x" + hr.ToString("X"));
            Guid iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
            object o;
            hr = dev.Activate(ref iid, 1, IntPtr.Zero, out o);    // CLSCTX_ALL
            if (hr != 0) throw new Exception("Activate hr=0x" + hr.ToString("X"));
            return o;
        }
    }
}
'@
$meter = [PeakWrap.Meter]::Create()

# Pre-flight: the meter pipeline itself must see sound. One audible blip from
# the shipped asset through the normal SoundPlayer path.
Add-Type -AssemblyName System.Media
$pre = New-Object System.Media.SoundPlayer (Join-Path $root 'blip01.wav')
$peakMax = 0.0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$pre.Play()
while ($sw.ElapsedMilliseconds -lt 900) {
    $v = (([PeakWrap.IAudioMeterInformation]$meter).GetPeakValue())
    if ($v -gt $peakMax) { $peakMax = $v }
    Start-Sleep -Milliseconds 25
}
$pre.Stop()
$threshold = 0.01
Check 'the peak meter hears a known-good sound (pipeline sanity)' ($peakMax -gt $threshold) "peakMax=$peakMax"

# Back up the real INI byte-for-byte and stage the 5 s smoke configuration.
$iniPath = Join-Path $root 'problip.ini'
$bakPath = Join-Path $root '.freebuff\problip.ini.smokebak'
Copy-Item -LiteralPath $iniPath -Destination $bakPath -Force
$hashBefore = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
Set-Content -LiteralPath $iniPath -Value "[problip]`r`nVolume=0.5`r`nMinMs=5000`r`nMaxMs=5000`r`nAutoStart=1`r`nRunOnLaunch=1" -Encoding ASCII
Write-Host "staged smoke INI (Volume=0.5, Min=Max=5000); real INI backed up"

$runBefore = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Problip' -ErrorAction SilentlyContinue).Problip
Write-Host "Run key before: $runBefore"

# Launch the real app; ON comes from RunOnLaunch=1 at startup (no TEST press).
$app = Start-Process -FilePath (Join-Path $root 'Problip.exe') -PassThru
$sw.Restart()
while (-not (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 50 }
Start-Sleep -Milliseconds 300      # startup cost before the engine arms
$t0 = [DateTime]::Now
Write-Host ("app launched, t0 = {0:HH:mm:ss.fff} (PID {1})" -f $t0, $app.Id)

# Observe >= 17 s of the render peak; record rising edges (scheduled blips).
$edges = [System.Collections.Generic.List[double]]::new()
$above = $false
$sw.Restart()
$lastEdge = -1000.0
while ($sw.ElapsedMilliseconds -lt 22000) {
    $v = 0.0
    try { $v = ([PeakWrap.IAudioMeterInformation]$meter).GetPeakValue() } catch { }
    if ($v -gt $threshold -and -not $above) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        if (($t - $lastEdge) -gt 0.6) { $edges.Add($t); $lastEdge = $t }
    }
    $above = ($v -gt $threshold)
    Start-Sleep -Milliseconds 25
}
$alive = $null -ne (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)
Check 'the real app stayed alive through the observation window' $alive "alive=$alive"

$blips = @($edges | Where-Object { $_ -ge 1.0 })
Check 'at least three scheduled blips were audible' ($blips.Count -ge 3) "edges(s after t0)=$($edges -join ', ')"
Write-Host ("scheduled blip times (s after t0): " + (($blips | ForEach-Object { [Math]::Round($_, 2) }) -join ', '))
if ($blips.Count -ge 2) {
    $d = for ($i = 1; $i -lt $blips.Count; $i++) { [Math]::Round($blips[$i] - $blips[$i - 1], 2) }
    Write-Host ("cadence deltas (s): " + ($d -join ', '))
}

Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# Restore the real INI byte-for-byte and confirm.
Copy-Item -LiteralPath $bakPath -Destination $iniPath -Force
$hashAfter = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
Check 'the real problip.ini was restored byte-for-byte' ($hashBefore -eq $hashAfter) "hash=$hashAfter"
$runAfter = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Problip' -ErrorAction SilentlyContinue).Problip
Check 'the HKCU Run entry survived the smoke unchanged' ("$runBefore" -eq "$runAfter") "before=$runBefore after=$runAfter"
$left = Get-Process -Name Problip -ErrorAction SilentlyContinue
Check 'no Problip process remains after the smoke' ($null -eq $left) "left=$($left.Id)"

Write-Host '---'
if ($fails) { Write-Host "SMOKE2 FAILED ($fails failure(s))"; exit 1 }
Write-Host 'SMOKE2 PASS (0 failures)'
exit 0
