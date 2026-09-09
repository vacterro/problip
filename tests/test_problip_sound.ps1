param(
    [string]$Source = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs'),
    # The shipped asset, resolved from the repository rather than from $Source, so
    # pointing $Source at a checked-out older revision still exercises the same
    # good input instead of failing on a missing fixture.
    [string]$RealWav = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'blip01.wav')
)

$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled variable must FAIL the harness
# immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0

# Behavioural check for Problip's sound-asset failure state.
#
# The defect: BuildCache() collapsed every load failure to `Player = null` with
# nothing recorded, Tick() returned early on a null player, and Start() set
# Enabled = true regardless -- so a missing or corrupt blip01.wav was a silent
# no-op while the window reported the engine as ON.
#
# The engine is driven directly against a freshly compiled copy of the real
# source, so this exercises BlipEngine itself rather than a restatement of it.
# Nothing is played and no tray icon is created.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_problip_sound.ps1
# Exit: 0 = all PASS, 1 = failures.

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) {
    # Never a silent pass: the whole harness is a compile-and-drive oracle,
    # so a missing compiler means the subject was NOT verified.
    Write-Host "FAIL  csc.exe not found under $env:WINDIR -- cannot compile the subject"
    exit 1
}
$sandbox = Join-Path $env:TEMP ('problip_snd_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

$fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "PASS  $name  $detail" } else { Write-Host "FAIL  $name  $detail"; $script:fails++ }
}

$engines = @()

try {
    $asmPath = Join-Path $sandbox 'ProblipUnderTest.exe'
    $out = & $csc -nologo -target:winexe "-out:$asmPath" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $Source 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL  the subject compiles  $($out -join ' ')"
        exit 1
    }

    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($asmPath))
    $settingsType = $asm.GetType('Problip.Settings')
    $engineType = $asm.GetType('Problip.BlipEngine')
    Check 'the engine exposes a failure state' `
        ($null -ne $engineType.GetProperty('IsBroken') -and $null -ne $engineType.GetProperty('FailureText')) ''

    # Settings and BlipEngine are internal, so Activator's default binder cannot
    # see their constructors; resolve each one explicitly, once.
    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $loadMethod = $settingsType.GetMethod('Load')
    $wavField = $settingsType.GetField('WavPath')
    $real = $RealWav

    # Each case gets its own directory, because Settings reads and writes
    # problip.ini next to whatever directory it is handed.
    $newEngine = {
        param([string]$wav)
        $dir = Join-Path $sandbox ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $s = $settingsCtor.Invoke(@([string]$dir))
        $loadMethod.Invoke($s, @()) | Out-Null
        $wavField.SetValue($s, [string]$wav)
        $engineCtor.Invoke(@($s))
    }

    # 1. A missing asset.
    $missing = Join-Path $sandbox 'no-such-file.wav'
    $e1 = & $newEngine $missing
    $engines += $e1
    $e1.Start()
Check 'a missing WAV reports broken, not running' `
        ($e1.IsBroken -and -not $e1.IsOn) "broken=$($e1.IsBroken) on=$($e1.IsOn)"
    Check 'a missing WAV names the asset that failed' `
        ($e1.FailureText -like '*no-such-file.wav*') "failure=$($e1.FailureText)"
    # The tray contract is the explicit run state; the em dash is built from
    # [char]0x2014 so this ANSI-encoded harness compares equal against the
    # UTF-8-compiled subject's caption.
    $errCaption = 'problip ' + [char]0x2014 + ' ERR'
    Check 'the tray caption reports the explicit ERR state' `
        ($e1.TrayCaption -eq $errCaption -and $e1.TrayCaption.Length -le 63) `
        "tray=$($e1.TrayCaption)"

    # 2. A corrupt asset: a real file that is not a playable WAV.
    $corrupt = Join-Path $sandbox 'corrupt.wav'
    [IO.File]::WriteAllBytes($corrupt, [byte[]](1..600 | ForEach-Object { [byte]($_ % 251) }))
    $e2 = & $newEngine $corrupt
    $engines += $e2
    $e2.Start()
    Check 'a corrupt WAV reports broken, not running' `
        ($e2.IsBroken -and -not $e2.IsOn) "broken=$($e2.IsBroken) on=$($e2.IsOn)"
    Check 'a corrupt WAV explains why' `
        ($null -ne $e2.FailureText -and $e2.FailureText -like '*corrupt.wav*') "failure=$($e2.FailureText)"

    # 3. The shipped asset still works and reports no failure.
    if (Test-Path -LiteralPath $real) {
        $e3 = & $newEngine $real
        $engines += $e3
        $e3.Start()
        Check 'the shipped WAV loads and reports running' `
            (-not $e3.IsBroken -and $e3.IsOn -and $null -eq $e3.FailureText) `
            "broken=$($e3.IsBroken) on=$($e3.IsOn) tray=$($e3.TrayCaption)"
    } else {
        Check 'the shipped WAV loads and reports running' $false "blip01.wav not found at $real"
    }

    # 4. Fixing the asset and pressing ON recovers without a restart.
    if (Test-Path -LiteralPath $real) {
        $fixable = Join-Path $sandbox 'fixable.wav'
        [IO.File]::WriteAllBytes($fixable, [byte[]](1..600 | ForEach-Object { [byte]($_ % 251) }))
        $e4 = & $newEngine $fixable
        $engines += $e4
        $e4.Start()
        $wasBroken = $e4.IsBroken
        Copy-Item -LiteralPath $real -Destination $fixable -Force
        $e4.Start()
        Check 'a repaired asset recovers on the next ON' `
            ($wasBroken -and -not $e4.IsBroken -and $e4.IsOn) `
            "was_broken=$wasBroken now_broken=$($e4.IsBroken) on=$($e4.IsOn)"
    } else {
        Check 'a repaired asset recovers on the next ON' $false "blip01.wav not found at $real"
    }

    # ---- Preview against a failing asset ----
    # Preview must be honest: a missing or corrupt WAV cannot preview, never
    # flips the engine ON, and recovery happens through the same path ON uses.
    $previewM = $engineType.GetMethod('Preview')

    # 5. Missing asset: Preview fails truthfully and stays OFF.
    $e5 = & $newEngine (Join-Path $sandbox 'preview-gone.wav')
    $engines += $e5
    $ok5 = $false
    try { $ok5 = [bool]$previewM.Invoke($e5, @()) } catch { }
    Check 'a missing WAV cannot preview (truthful failure)' (-not $ok5) "ok=$ok5"
    Check 'a failed preview never turns the engine ON' (-not $e5.IsOn) "on=$($e5.IsOn)"
    Check 'a failed preview names the asset in the failure state' ($e5.FailureText -like '*preview-gone.wav*') "failure=$($e5.FailureText)"

    # 6. Corrupt asset: Preview fails truthfully, stays OFF.
    $corrupt2 = Join-Path $sandbox 'preview-corrupt.wav'
    [IO.File]::WriteAllBytes($corrupt2, [byte[]](1..600 | ForEach-Object { [byte]($_ % 251) }))
    $e6 = & $newEngine $corrupt2
    $engines += $e6
    $ok6 = $false
    try { $ok6 = [bool]$previewM.Invoke($e6, @()) } catch { }
    Check 'a corrupt WAV cannot preview (truthful failure)' (-not $ok6 -and -not $e6.IsOn) "ok=$ok6 on=$($e6.IsOn)"

    # 7. Recovery: repairing the asset lets Preview succeed while staying OFF.
    if (Test-Path -LiteralPath $real) {
        Copy-Item -LiteralPath $real -Destination $corrupt2 -Force
        $ok7 = $false
        try { $ok7 = [bool]$previewM.Invoke($e6, @()) } catch { }
        Check 'a repaired WAV previews successfully without a restart' ($ok7 -and -not $e6.IsBroken) "ok=$ok7 broken=$($e6.IsBroken)"
        Check 'a successful preview still leaves the engine OFF' (-not $e6.IsOn) "on=$($e6.IsOn)"
    } else {
        Check 'a repaired WAV previews successfully without a restart' $false "blip01.wav not found at $real"
    }
} finally {
    foreach ($e in $engines) { try { $e.Cleanup() } catch { } }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '---'
if ($fails) { Write-Host "FAILED ($fails failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0

