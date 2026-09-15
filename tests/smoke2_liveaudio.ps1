# Smoke layer 2: the REAL launched Problip.exe, audible, observed through the
# Windows audio peak meter (WASAPI IAudioMeterInformation on the default render
# device). Records the wall-clock times of scheduled blips for the 5 s cadence.
#
# SAFETY CONTRACT (PERF-001):
#   - The HKCU Run value named Problip is captured (presence + exact string)
#     BEFORE anything is staged, and restored EXACTLY afterward:
#       originally present -> exact original value restored
#       originally absent  -> value absent again
#   - The INI is staged with AutoStart chosen to MINIMIZE projection changes
#     (StartupCommands.ProjectAtStartup: AutoStart=1 -> RegSet,
#      AutoStart=0 -> RegClear):
#       Run value originally exists  -> AutoStart=1 (RegSet onto an existing
#                                        key; value may temporarily differ;
#                                        restored exactly in cleanup)
#       Run value originally absent  -> AutoStart=0 (RegClear of an absent
#                                        key: no-op)
#     The original Run value is NOT assumed to equal the current exe path.
#   - Every externally visible mutation (staged INI, HKCU Run, launched
#     process, backup artifact) is undone by one guaranteed cleanup that runs
#     on success, assertion failure, or exception. The ORIGINAL failure is
#     preserved and rethrown only AFTER cleanup completes; a cleanup failure
#     itself counts as a smoke failure.
#
# DETERMINISTIC CLEANUP REGRESSION (fault-injection mode): passing the
# explicit switch -InjectBodyFault makes the main body throw a deterministic
# terminating error right after staging (before the app is launched). The
# smoke then proves cleanup restored EVERY postcondition (INI hash, HKCU Run
# presence/value, no launched process, no backup artifact, no accumulated
# cleanup failure) and exits 0 if -- and only if -- that full
# cleanup-on-body-failure regression holds. Fault mode is entered ONLY through
# the switch: no ambient TEMP sentinel exists, so stale leftover state can
# never silently change which test a normal run executes.
param(
    # The ONLY way to enter the deterministic body-fault regression mode.
    [switch]$InjectBodyFault
)
$ErrorActionPreference = 'Stop'
$root = 'V:\___VAC\__K\__CODE\_PY\_PROBLIP'
Add-Type -AssemblyName System

$script:fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { Write-Host "PASS  $n  $d" } else { Write-Host "FAIL  $n  $d"; $script:fails++ }
}

Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
namespace PeakWrap {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        // Every method here keeps the NATIVE HRESULT return; each carries
        // [PreserveSig] so the CLR performs NO HRESULT-to-exception translation
        // and the manual `hr != 0` checks below are the single, internally
        // consistent error convention. No dummy slots: the real
        // EnumAudioEndpoints is declared (collection handed out as a raw
        // IUnknown-classed pointer; the harness never dereferences it), so the
        // vtable stays native-aligned.
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        // NATIVE IMMDevice: IID D666063F-1587-4E43-81F1-B948E807363F (the old
        // 0BD7A1BE-... GUID is IMMDeviceCollection's, which QI rejects), and
        // the vtable after IUnknown is, in order:
        //   1. Activate  2. OpenPropertyStore  3. GetId  4. GetState.
        // All four keep the native HRESULT shape with [PreserveSig], matching
        // the explicit hr checks in Meter.Create.
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, [MarshalAs(UnmanagedType.IUnknown)] out object ppPropertyStore);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        [PreserveSig] int GetState(out int pdwState);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        // Deliberate second convention, NOT a hybrid: GetPeakValue uses CLR
        // HRESULT-to-exception translation (managed float return, no
        // [PreserveSig]) so a failed peak read throws in Peak() instead of
        // returning an uninterpreted int. This interface's methods are never
        // hr-checked manually.
        float GetPeakValue();
    }
    public static class Meter {
        // CLSCTX_ALL must contain ALL FOUR normal COM activation contexts:
        //   CLSCTX_INPROC_SERVER  = 0x1
        //   CLSCTX_INPROC_HANDLER = 0x2
        //   CLSCTX_LOCAL_SERVER   = 0x4
        //   CLSCTX_REMOTE_SERVER  = 0x10
        // Named constants, not a magic number; the expression is 0x1 | 0x2 |
        // 0x4 | 0x10 = 0x17 = decimal 23. CLSCTX_INPROC_SERVER (1) alone is
        // NOT the documented activation context for MMDevice API objects,
        // which live out-of-process in the audio service.
        public const int CLSCTX_INPROC_SERVER = 0x1;
        public const int CLSCTX_INPROC_HANDLER = 0x2;
        public const int CLSCTX_LOCAL_SERVER = 0x4;
        public const int CLSCTX_REMOTE_SERVER = 0x10;
        public const int CLSCTX_ALL =
            CLSCTX_INPROC_SERVER |
            CLSCTX_INPROC_HANDLER |
            CLSCTX_LOCAL_SERVER |
            CLSCTX_REMOTE_SERVER;   // 0x17 = decimal 23
        public static object Create() {
            var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            IMMDevice dev;
            int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);   // eRender, eMultimedia
            if (hr != 0 || dev == null) throw new Exception("GetDefaultAudioEndpoint hr=0x" + hr.ToString("X"));
            Guid iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
            object o;
            hr = dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o);
            if (hr != 0 || o == null) throw new Exception("Activate hr=0x" + hr.ToString("X"));
            return o;
        }
        // Read one normalized render peak through the compiled interface type
        // (avoids PowerShell-side interface casts entirely).
        public static float Peak(object meter) { return ((IAudioMeterInformation)meter).GetPeakValue(); }
    }
}
'@
$meter = [PeakWrap.Meter]::Create()
Write-Host "WASAPI meter ready: MMDeviceEnumerator created, GetDefaultAudioEndpoint + IMMDevice.Activate succeeded (PreserveSig hr checks passed, dwClsCtx=CLSCTX_ALL)"

# Pre-flight: the meter pipeline itself must see sound. One audible blip from
# the shipped asset through the normal SoundPlayer path. (System.Media.SoundPlayer
# lives in System.dll, which is always loaded in Windows PowerShell 5.1; there
# is no separate 'System.Media' assembly to Add-Type.)
$pre = New-Object System.Media.SoundPlayer (Join-Path $root 'blip01.wav')
$peakMax = 0.0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$pre.Play()
while ($sw.ElapsedMilliseconds -lt 900) {
    $v = [PeakWrap.Meter]::Peak($meter)
    if ($v -gt $peakMax) { $peakMax = $v }
    Start-Sleep -Milliseconds 5
}
$pre.Stop()
$threshold = 0.01
Check 'the peak meter hears a known-good sound (pipeline sanity)' ($peakMax -gt $threshold) "peakMax=$peakMax"

# ---------------------------------------------------------------------------
# GUARANTEED-CLEANUP REGION. Everything from here on mutates external state;
# the catch/finally below restore ALL of it no matter how the body exits.
# ---------------------------------------------------------------------------
$iniPath = Join-Path $root 'problip.ini'
# Back up into a guaranteed-existing temp location we own; never depend on
# .freebuff existing. The backup artifact is removed by cleanup.
$bakPath = Join-Path ([System.IO.Path]::GetTempPath()) ("problip.ini.smokebak." + [Guid]::NewGuid().ToString('N'))
$iniBackup = $false
$hashBefore = $null

# Run-key capture BEFORE any staging (TARGET A): state, not assumption.
$runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runProp = Get-ItemProperty -Path $runPath -Name 'Problip' -ErrorAction SilentlyContinue
$runExists = ($null -ne $runProp) -and ($runProp.PSObject.Properties.Name -contains 'Problip')
$runValue = if ($runExists) { [string]$runProp.Problip } else { $null }
Write-Host ("Run key before: " + $(if ($runExists) { $runValue } else { '<absent>' }))

# Stage AutoStart to MINIMIZE the boot projection's registry effect.
$stagedAutoStart = if ($runExists) { 1 } else { 0 }

# Deterministic body-fault injection (see header): explicit switch ONLY.
$bodyFault = [bool]$InjectBodyFault

# Same-copy ownership conflict (PERF-001 TARGET E): persistence ownership is
# directory-scoped. If THIS exact portable copy (same full exe path) is
# already running, it owns this directory's persistence and the freshly
# launched instance would exit immediately after staging. Detect that BEFORE
# any external mutation and SKIP -- never kill or fail because of it, and
# never treat a Problip process from ANOTHER directory as a conflict.
$exePath = Join-Path $root 'Problip.exe'
$sameCopy = @(Get-Process -Name Problip -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath })
if ($sameCopy.Count -gt 0) {
    Write-Host ("SKIP  smoke2: this portable copy already owns its persistence mutex (PID(s) {0}); no user state was staged" -f (($sameCopy | ForEach-Object { $_.Id }) -join ', '))
    exit 0
}

# Capture unrelated pre-existing Problip PIDs (other portable copies) so the
# final postcondition can prove they were left untouched (TARGET D).
$preExistingProcs = @(Get-Process -Name Problip -ErrorAction SilentlyContinue)
Write-Host ("unrelated pre-existing Problip processes (must remain untouched): " + $(if ($preExistingProcs.Count) { ($preExistingProcs | ForEach-Object { $_.Id }) -join ', ' } else { '<none>' }))

$app = $null
$bodyError = $null
try {
    # Back up the real INI byte-for-byte and stage the 5 s smoke configuration.
    Copy-Item -LiteralPath $iniPath -Destination $bakPath -Force
    $iniBackup = $true
    $hashBefore = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath $iniPath -Value "[problip]`r`nVolume=0.5`r`nMinMs=5000`r`nMaxMs=5000`r`nAutoStart=$stagedAutoStart`r`nRunOnLaunch=1" -Encoding ASCII
    Write-Host "staged smoke INI (Volume=0.5, Min=Max=5000, AutoStart=$stagedAutoStart); real INI backed up to temp"

    if ($bodyFault) {
        throw "deterministic body-fault injection: main smoke body aborted right after staging"
    }

    # Launch the real app; ON comes from RunOnLaunch=1 at startup (no TEST press).
    # BOUNDED startup observation (TARGET C): Start-Process -PassThru hands us
    # the Process object directly -- no unbounded Get-Process spin. Fail fast
    # if the process exits during startup or is not observable within the
    # documented startup bound (5 s).
    $app = Start-Process -FilePath (Join-Path $root 'Problip.exe') -PassThru
    $startupBoundMs = 5000
    # WaitForExit(ms) returns TRUE only if the process already EXITED within
    # the bound; false means it is still running (the success case). Either
    # way the wait is bounded -- this can never spin forever.
    if ($app.WaitForExit($startupBoundMs)) {
        throw "launched Problip exited during startup (exit code $($app.ExitCode))"
    }
    Start-Sleep -Milliseconds 300      # startup cost before the engine arms
    if ($app.HasExited) { throw "launched Problip exited during startup" }
    $t0 = [DateTime]::Now
    Write-Host ("app launched, t0 = {0:HH:mm:ss.fff} (PID {1})" -f $t0, $app.Id)

    # Observe >= 17 s of the render peak; record rising edges (scheduled blips).
    # The shipped blip01.wav is stereo 44.1 kHz 16-bit with a 11760-byte data
    # chunk (~66.7 ms long -- measured, not guessed) and the WASAPI meter
    # aggregates per ~10 ms device period, so the poll MUST be well below the
    # blip length: 5 ms for both the preflight and this observation loop keeps
    # every meter period sampled without relying on any timing luck.
    $edges = [System.Collections.Generic.List[double]]::new()
    $above = $false
    $sw.Restart()
    $lastEdge = -1000.0
    while ($sw.ElapsedMilliseconds -lt 22000) {
        if ($app.HasExited) { Write-Host 'launched Problip exited mid-observation'; break }
        $v = 0.0
        try { $v = [PeakWrap.Meter]::Peak($meter) } catch { }
        if ($v -gt $threshold -and -not $above) {
            $t = $sw.ElapsedMilliseconds / 1000.0
            if (($t - $lastEdge) -gt 0.6) { $edges.Add($t); $lastEdge = $t }
        }
        $above = ($v -gt $threshold)
        Start-Sleep -Milliseconds 5
    }
    $alive = -not $app.HasExited
    Check 'the real app stayed alive through the observation window' $alive "alive=$alive"

    $blips = @($edges | Where-Object { $_ -ge 1.0 })
    Check 'at least three scheduled blips were audible' ($blips.Count -ge 3) "edges(s after t0)=$($edges -join ', ')"
    Write-Host ("scheduled blip times (s after t0): " + (($blips | ForEach-Object { [Math]::Round($_, 2) }) -join ', '))
    # Cadence compatibility: the default render meter hears EVERY system
    # sound, not just Problip, so raw deltas contain foreign noise edges.
    # Extract the subsequence of edges spaced like the staged 5 s interval
    # (Min=Max=5000 -> deltas must land inside a tolerance window) and check
    # it carries the scheduled cadence. A greedy chain walk from each start
    # edge picks, after each member, the FIRST edge inside the window, so
    # noise edges between scheduled blips never break the chain.
    $cadenceOk = $false
    $bestChain = @()
    $tolLo = 4.2; $tolHi = 5.8
    for ($s = 0; $s -lt $blips.Count; $s++) {
        $chain = @($blips[$s]); $cur = $blips[$s]
        for ($i = $s + 1; $i -lt $blips.Count; $i++) {
            $d = $blips[$i] - $cur
            if ($d -ge $tolLo -and $d -le $tolHi) { $chain += $blips[$i]; $cur = $blips[$i] }
        }
        if ($chain.Count -gt $bestChain.Count) { $bestChain = $chain }
    }
    $cadenceOk = ($bestChain.Count -ge 3)
    $deltas = for ($i = 1; $i -lt $bestChain.Count; $i++) { [Math]::Round($bestChain[$i] - $bestChain[$i - 1], 2) }
    Check 'cadence deltas are compatible with the staged 5-second interval' $cadenceOk "chain(s)=$($bestChain | ForEach-Object { [Math]::Round($_, 2) }) deltas=$($deltas -join ', ')"
    if ($blips.Count -ge 2) {
        $d = for ($i = 1; $i -lt $blips.Count; $i++) { [Math]::Round($blips[$i] - $blips[$i - 1], 2) }
        Write-Host ("raw cadence deltas incl. system-audio noise (s): " + ($d -join ', '))
    }
}
catch {
    # Preserve the ORIGINAL failure; cleanup runs first (finally), and the
    # rethrow below happens only after cleanup has fully completed.
    $bodyError = $_
}
finally {
    # ---- GUARANTEED CLEANUP: success, assertion failure, or exception. ----
    # Steps are independent: one step failing must not skip the rest. A
    # cleanup failure counts as a smoke failure.
    $cleanupOk = $true
    $cleanupMsg = @()

    # 1. Terminate ONLY the process this smoke launched (the PassThru object;
    #    never a global Get-Process -Name sweep).
    if ($null -ne $app) {
        try {
            $app.Refresh()
            if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit(3000) | Out-Null }
        } catch {
            $cleanupOk = $false; $cleanupMsg += "process kill: $($_.Exception.Message)"
        }
    }

    # 2. Restore the original INI byte-for-byte.
    try {
        if ($iniBackup) { Copy-Item -LiteralPath $bakPath -Destination $iniPath -Force }
    } catch {
        $cleanupOk = $false; $cleanupMsg += "INI restore: $($_.Exception.Message)"
    }

    # 3. Restore the EXACT original HKCU Run state (TARGET A postcondition).
    try {
        if ($runExists) {
            Set-ItemProperty -Path $runPath -Name 'Problip' -Value $runValue -Type String
        } else {
            Remove-ItemProperty -Path $runPath -Name 'Problip' -ErrorAction SilentlyContinue
        }
    } catch {
        $cleanupOk = $false; $cleanupMsg += "Run-key restore: $($_.Exception.Message)"
    }

    # 4. Remove the temporary backup artifact.
    try {
        if (Test-Path -LiteralPath $bakPath) { Remove-Item -LiteralPath $bakPath -Force }
    } catch {
        $cleanupOk = $false; $cleanupMsg += "backup removal: $($_.Exception.Message)"
    }

    # 5. Verify the postconditions; a silent mismatch is a cleanup failure.
    try {
        $hashAfter = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
        if ($null -ne $hashBefore -and $hashBefore -ne $hashAfter) {
            $cleanupOk = $false; $cleanupMsg += 'INI hash mismatch after restore'
        }
        $runAfterProp = Get-ItemProperty -Path $runPath -Name 'Problip' -ErrorAction SilentlyContinue
        $runAfterExists = ($null -ne $runAfterProp) -and ($runAfterProp.PSObject.Properties.Name -contains 'Problip')
        if ($runAfterExists -ne $runExists -or ($runExists -and "$($runAfterProp.Problip)" -ne "$runValue")) {
            $cleanupOk = $false; $cleanupMsg += 'Run key not restored exactly'
        }
        if (Test-Path -LiteralPath $bakPath) { $cleanupOk = $false; $cleanupMsg += "temporary backup remains: $bakPath" }
    } catch {
        $cleanupOk = $false; $cleanupMsg += "postcondition verify: $($_.Exception.Message)"
    }

    if ($cleanupOk) {
        Write-Host 'cleanup completed: process stopped, INI restored byte-for-byte, HKCU Run restored exactly, no backup artifact remains'
    } else {
        Write-Host ("FAIL  cleanup itself failed: " + ($cleanupMsg -join '; '))
        $script:fails++
    }
}

# In fault-injection mode the body failure was the regression trigger itself:
# verify cleanup-on-body-failure held and exit on THAT evidence. In normal
# mode, rethrow the original failure now that cleanup has fully completed.
if ($null -ne $bodyError) {
    if ($bodyFault) {
        # The injected body failure itself is EXPECTED. The regression passes
        # only if EVERY cleanup postcondition holds -- success can never rest
        # on the INI hash alone, and "0 failures" must never be printed while
        # $script:fails is nonzero.
        $faultOk = $true
        $faultMsg = @()
        if (-not $cleanupOk) { $faultOk = $false; $faultMsg += 'cleanup reported failure' }
        try {
            $hashFault = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
            if ($null -eq $hashBefore -or $hashBefore -ne $hashFault) { $faultOk = $false; $faultMsg += 'INI hash not restored' }
        } catch { $faultOk = $false; $faultMsg += "INI hash verify: $($_.Exception.Message)" }
        try {
            $runFaultProp = Get-ItemProperty -Path $runPath -Name 'Problip' -ErrorAction SilentlyContinue
            $runFaultExists = ($null -ne $runFaultProp) -and ($runFaultProp.PSObject.Properties.Name -contains 'Problip')
            if ($runFaultExists -ne $runExists -or ($runExists -and "$($runFaultProp.Problip)" -ne "$runValue")) { $faultOk = $false; $faultMsg += 'HKCU Run not restored exactly' }
        } catch { $faultOk = $false; $faultMsg += "Run-key verify: $($_.Exception.Message)" }
        if ($null -ne $app) {
            try {
                $app.Refresh()
                if (-not $app.HasExited -or $null -ne (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) { $faultOk = $false; $faultMsg += "launched PID $($app.Id) still alive" }
            } catch { $faultOk = $false; $faultMsg += "process verify: $($_.Exception.Message)" }
        }
        if (Test-Path -LiteralPath $bakPath) { $faultOk = $false; $faultMsg += "temporary backup remains: $bakPath" }
        if ($script:fails -ne 0) { $faultOk = $false; $faultMsg += "accumulated failures: $script:fails" }
        Check 'deterministic body-fault path: ALL cleanup postconditions restored (INI, Run key, process, backup, no accumulated failure)' $faultOk ($faultMsg -join '; ')
        Write-Host 'body-fault regression observed: original failure was preserved through cleanup'
        if (-not $faultOk -or $script:fails -ne 0) { Write-Host "SMOKE2 FAILED (cleanup-on-body-failure regression, $script:fails failure(s))"; exit 1 }
        Write-Host 'SMOKE2 PASS (cleanup-on-body-failure regression: all cleanup postconditions restored)'
        exit 0
    }
    throw $bodyError
}

# Post-cleanup, post-restore verification (normal successful path).
$hashAfter = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
Check 'the real problip.ini was restored byte-for-byte' ($hashBefore -eq $hashAfter) "hash=$hashAfter"
$runAfterProp = Get-ItemProperty -Path $runPath -Name 'Problip' -ErrorAction SilentlyContinue
$runAfterExists = ($null -ne $runAfterProp) -and ($runAfterProp.PSObject.Properties.Name -contains 'Problip')
$runExact = if ($runExists) { $runAfterExists -and ("$($runAfterProp.Problip)" -eq "$runValue") } else { -not $runAfterExists }
Check 'the original HKCU Run presence/value was restored exactly' $runExact "before=$(if ($runExists) { $runValue } else { '<absent>' }) after=$(if ($runAfterExists) { $runAfterProp.Problip } else { '<absent>' })"
# Prove ONLY that the PID this smoke launched is gone. A Problip process from
# another directory is a legitimate portable instance and must never be
# killed, failed on, or treated as a smoke leftover (PERF-001 TARGET D).
$smokePidGone = $true
if ($null -ne $app) {
    $smokePidGone = $app.HasExited -and ($null -eq (Get-Process -Id $app.Id -ErrorAction SilentlyContinue))
}
Check 'the PID this smoke launched is no longer alive' $smokePidGone "pid=$(if ($null -ne $app) { $app.Id } else { '<not launched>' })"
$missing = @($preExistingProcs | Where-Object { $null -eq (Get-Process -Id $_.Id -ErrorAction SilentlyContinue) })
Check 'unrelated pre-existing Problip processes remain untouched' ($missing.Count -eq 0) ("missing=" + $(if ($missing.Count) { ($missing | ForEach-Object { $_.Id }) -join ', ' } else { '<none>' }))
Check 'no temporary backup artifact remains' (-not (Test-Path -LiteralPath $bakPath)) "path=$bakPath"

Write-Host '---'
if ($fails) { Write-Host "SMOKE2 FAILED ($fails failure(s))"; exit 1 }
Write-Host 'SMOKE2 PASS (0 failures)'
exit 0
