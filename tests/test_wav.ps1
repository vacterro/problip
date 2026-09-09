param(
    [string]$Source = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'Problip.cs'),
    # The shipped asset, resolved from the repository so pointing $Source at an
    # older revision still exercises the same good input.
    [string]$RealWav = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'blip01.wav')
)

$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled variable must FAIL the harness
# immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "PASS  $name  $detail" } else { Write-Host "FAIL  $name  $detail"; $script:fails++ }
}

# WAV contract checks for BlipEngine.ParseWav (the single authoritative parser
# that validates AND describes the file). Every malformed case runs inside a
# PowerShell Job with a timeout so a zero-step loop regression reads as FAIL, not
# as a hung session.
#   - 4-bit / bps=0 input is rejected quickly and never hangs.
#   - unsupported format tag (float / compressed) is rejected.
#   - truncated/malformed chunk lengths are rejected.
#   - the DECLARED RIFF size is the container: chunks past it are ignored, a
#     container smaller than its chunks is rejected, and a container larger than
#     the physical file is rejected.
#   - fmt must precede data; an odd chunk's pad byte must lie inside the container.
#   - the shipped 16-bit PCM blip01.wav still loads.
# The test drives the real parser via reflection, not a re-implementation.

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }

$sandbox = Join-Path $env:TEMP ('problip_wav_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

function New-Fmt([int]$tag, [int]$channels, [int]$rate, [int]$bits, [int]$blockAlignOverride = -1, [int]$byteRateOverride = -1) {
    $block = if ($blockAlignOverride -ge 0) { $blockAlignOverride } else { $channels * [math]::Max(1, [int]($bits / 8)) }
    $byteRate = if ($byteRateOverride -ge 0) { $byteRateOverride } else { $rate * $block }
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $w.Write([int16]$tag); $w.Write([int16]$channels); $w.Write([int]$rate)
    $w.Write([int]$byteRate); $w.Write([int16]$block); $w.Write([int16]$bits)
    $w.Flush(); $b = $ms.ToArray(); $w.Close(); return $b
}
function New-Wav([int]$tag, [int]$bits, [byte[]]$samples, [int]$chunkLenOverride = -1, [switch]$truncated,
                 [int]$channels = 1, [int]$rate = 8000, [int]$blockAlignOverride = -1, [int]$byteRateOverride = -1,
                 [int]$riffSizeOverride = -1, [switch]$oddPad, [switch]$riffExcludesPad,
                 [switch]$dataFirst, [switch]$doubleFmt) {
    $body = New-Object IO.MemoryStream
    $bbw = New-Object IO.BinaryWriter($body)
    $bbw.Write([byte[]][char[]]'WAVE')
    $fmtBytes = [byte[]](New-Fmt $tag $channels $rate $bits $blockAlignOverride $byteRateOverride)
    if ($dataFirst) {
        $bbw.Write([byte[]][char[]]'data')
        $bbw.Write([int]$samples.Length); $bbw.Write($samples)
        $bbw.Write([byte[]][char[]]'fmt '); $bbw.Write([int]16); $bbw.Write($fmtBytes)
    } else {
        if ($doubleFmt) { $bbw.Write([byte[]][char[]]'fmt '); $bbw.Write([int]16); $bbw.Write($fmtBytes) }
        $bbw.Write([byte[]][char[]]'fmt '); $bbw.Write([int]16); $bbw.Write($fmtBytes)
        $bbw.Write([byte[]][char[]]'data')
        if ($truncated) { $bbw.Write([int]($samples.Length * 16)); $bbw.Write($samples) }
        elseif ($chunkLenOverride -ge 0) { $bbw.Write([int]$chunkLenOverride); $bbw.Write($samples) }
        else { $bbw.Write([int]$samples.Length); $bbw.Write($samples) }
        if ($oddPad) { $bbw.Write([byte]0) }  # physical pad byte after an odd data chunk
    }
    $bbw.Flush(); $payload = $body.ToArray(); $bbw.Close()
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([byte[]][char[]]'RIFF')
    if ($riffSizeOverride -ge 0) { $size = $riffSizeOverride }
    elseif ($riffExcludesPad -and $oddPad) { $size = $payload.Length - 1 }
    else { $size = $payload.Length }
    $bw.Write([int]$size); $bw.Write($payload)
    $bw.Flush(); $b = $ms.ToArray(); $bw.Close(); return $b
}

try {
    $asmPath = Join-Path $sandbox 'ProblipUnderTest.dll'
    $out = & $csc -nologo -target:library "-out:$asmPath" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll $Source 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  the subject compiles  $($out -join ' ')"; exit 1 }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($asmPath))

    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $settingsType = $asm.GetType('Problip.Settings')
    $engineType = $asm.GetType('Problip.BlipEngine')
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $loadMethod = $settingsType.GetMethod('Load')
    $parseWav = $engineType.GetMethod('ParseWav', $staticFlags)
    $scaleWav = $engineType.GetMethod('ScaleWav', $flags)

    # 156 bytes divides evenly by 1/2/3/4 so every bit depth keeps whole frames.
    $samplesEven = [byte[]](0..155 | ForEach-Object { [byte]($_ % 251) })

    # Run ParseWav for one payload inside a job so a zero-step loop
    # cannot hang the runner: the job gets 10 s, then it is a FAIL.
    # On success the job reports the parsed WavInfo fields, so the regression
    # can pin the exact DataStart/DataLength/BitsPerSample the scaler consumes.
    $probe = {
        param($asmPath, $payloadPath)
        [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($asmPath)) | Out-Null
        $flags = [Reflection.BindingFlags]'Static,Public,NonPublic'
        $st = ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetType('Problip.BlipEngine') } | Select-Object -First 1).GetType('Problip.BlipEngine')
        $rm = $st.GetMethod('ParseWav', $flags)
        $payload = [IO.File]::ReadAllBytes($payloadPath)
        try {
            $wi = $rm.Invoke($null, @(, $payload))
            'ACCEPT|bits=' + $wi.BitsPerSample + ' start=' + $wi.DataStart + ' len=' + $wi.DataLength + `
                ' ch=' + $wi.Channels + ' rate=' + $wi.SampleRate + ' ba=' + $wi.BlockAlign
        }
        catch { 'REJECT:' + $_.Exception.InnerException.Message } 
    }

    function Probe-Case([string]$name, [byte[]]$payload, [string]$expectPattern, [int]$timeoutSec = 10) {
        $payloadPath = Join-Path $sandbox ('case_' + [Guid]::NewGuid().ToString('N') + '.bin')
        [IO.File]::WriteAllBytes($payloadPath, $payload)
        $job = Start-Job -ScriptBlock $probe -ArgumentList $asmPath, $payloadPath
        try {
            $done = Wait-Job -Job $job -Timeout $timeoutSec
            if (-not $done) { Check $name $false "TIMED OUT after ${timeoutSec}s -- scaling loop may have hung"; return }
            $result = Receive-Job -Job $job
            Check $name ($result -like $expectPattern) "got=[$result] expect=[$expectPattern]"
        } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }

    Probe-Case 'a 4-bit WAV is rejected quickly, never scaled or hung' (New-Wav 1 4 $samplesEven) 'REJECT:*'
    Probe-Case 'a float (tag 3) WAV is rejected as unsupported encoding' (New-Wav 3 32 $samplesEven) 'REJECT:unsupported WAV encoding*'
    Probe-Case 'an IMA-ADPCM (tag 17) WAV is rejected as unsupported encoding' (New-Wav 17 4 $samplesEven) 'REJECT:unsupported WAV encoding*'
    Probe-Case 'an unsupported 12-bit PCM WAV is rejected' (New-Wav 1 12 $samplesEven) 'REJECT:unsupported bits per sample*'
    Probe-Case 'a truncated chunk length is rejected' (New-Wav 1 16 $samplesEven -truncated) 'REJECT:*'
    Probe-Case 'an oversized chunk length is rejected' (New-Wav 1 16 $samplesEven 0x7FFFFFFF) 'REJECT:*'
    Probe-Case 'valid 16-bit PCM passes the parser' (New-Wav 1 16 $samplesEven) 'ACCEPT|*'
    Probe-Case 'valid 8-bit PCM passes the parser' (New-Wav 1 8 $samplesEven) 'ACCEPT|*'
    Probe-Case 'valid 24-bit PCM passes the parser' (New-Wav 1 24 $samplesEven) 'ACCEPT|*'
    Probe-Case 'valid 32-bit PCM passes the parser' (New-Wav 1 32 $samplesEven) 'ACCEPT|*'
    Probe-Case 'a shipped-format stereo 44100 16-bit WAV passes the parser' `
        (New-Wav 1 16 $samplesEven -channels 2 -rate 44100) 'ACCEPT|*'
    Probe-Case 'a too-small blockAlign is rejected' `
        (New-Wav 1 16 $samplesEven -channels 2 -blockAlignOverride 2) 'REJECT:invalid WAV chunk layout*'
    Probe-Case 'a too-large blockAlign is rejected' `
        (New-Wav 1 16 $samplesEven -channels 2 -blockAlignOverride 8) 'REJECT:invalid WAV chunk layout*'
    Probe-Case 'a zero sample rate is rejected' `
        (New-Wav 1 16 $samplesEven -rate 0) 'REJECT:invalid WAV chunk layout*'
    Probe-Case 'an inconsistent byteRate is rejected' `
        (New-Wav 1 16 $samplesEven -channels 2 -rate 8000 -byteRateOverride 31000) 'REJECT:invalid WAV chunk layout*'
    Probe-Case 'an incomplete PCM frame in data is rejected' `
        (New-Wav 1 16 $samplesEven 155) 'REJECT:invalid WAV chunk layout*'

    # RIFF declared-container bounds: the size field at bytes 4..7 is authoritative.
    Probe-Case 'the parser returns the exact WavInfo the scaler consumes' `
        (New-Wav 1 16 $samplesEven) 'ACCEPT|bits=16 start=44 len=156 ch=1 rate=8000 ba=2'
    Probe-Case 'a RIFF size that cannot hold the WAVE form type is rejected' `
        (New-Wav 1 16 $samplesEven -riffSizeOverride 3) 'REJECT:invalid RIFF container size*'
    Probe-Case 'a RIFF size declaring a container smaller than the fmt/data chunks is rejected' `
        (New-Wav 1 16 $samplesEven -riffSizeOverride 30) 'REJECT:*'
    Probe-Case 'a RIFF size declaring a container larger than the physical file is rejected' `
        (New-Wav 1 16 $samplesEven -riffSizeOverride 100000) 'REJECT:RIFF size exceeds the physical file*'
    Probe-Case 'required chunks exactly fitting the declared RIFF container are accepted' `
        (New-Wav 1 16 $samplesEven) 'ACCEPT|*'
    Probe-Case 'physical bytes after the declared RIFF end are ignored, never parsed as chunks' `
        ([byte[]]((New-Wav 1 16 $samplesEven) + (0..15 | ForEach-Object { [byte]0xAB }))) 'ACCEPT|*'
    # Odd data chunk: the required pad byte must lie inside the declared container.
    # 8-bit PCM frames are 1 byte wide, so an odd data length is a whole number of
    # frames and the oddness is purely the chunk padding question.
    $samplesOdd = [byte[]](0..156 | ForEach-Object { [byte]($_ % 251) })
    Probe-Case 'an odd data chunk with its pad byte inside the RIFF container is accepted' `
        (New-Wav 1 8 $samplesOdd -oddPad) 'ACCEPT|*'
    Probe-Case 'an odd chunk whose required pad byte lies outside the RIFF container is rejected' `
        (New-Wav 1 8 $samplesOdd -oddPad -riffExcludesPad) 'REJECT:WAV chunk padding lies outside the RIFF container*'
    # Chunk order contract: fmt before data, one fmt.
    Probe-Case 'a data chunk before fmt is rejected, not accidentally accepted' `
        (New-Wav 1 16 $samplesEven -dataFirst) 'REJECT:data chunk before fmt chunk*'
    Probe-Case 'a duplicate fmt chunk is rejected' `
        (New-Wav 1 16 $samplesEven -doubleFmt) 'REJECT:multiple fmt chunks*'

    # The shipped asset still loads end-to-end through the real engine.
    if (Test-Path -LiteralPath $RealWav) {
        $dir = Join-Path $sandbox ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $s = $settingsCtor.Invoke(@([string]$dir))
        $loadMethod.Invoke($s, @()) | Out-Null
        $s.WavPath = [string]$RealWav
        $e = $engineCtor.Invoke(@($s))
        try {
            $e.Start()
            Check 'the shipped 16-bit blip01.wav still loads successfully' `
                (-not $e.IsBroken -and $e.IsOn -and $null -eq $e.FailureText) `
                "broken=$($e.IsBroken) on=$($e.IsOn) failure=$($e.FailureText)"
        } finally { try { $e.Cleanup() } catch { } }
    } else {
        Check 'the shipped 16-bit blip01.wav still loads successfully' $false "not found at $RealWav"
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# Source-contract checks: one authoritative parser, and ScaleWav must not carry a
# second independent chunk scanner (the original drift risk the refactor closed).
$text = Get-Content -LiteralPath $Source -Raw
Check 'one authoritative parser: ParseWav(byte[] b) exists' ($text -match 'static WavInfo ParseWav\(byte\[\] b\)')
Check 'the old RequireWav split is gone' ($text -notmatch '\bRequireWav\(')
$scaleStart = $text.IndexOf('byte[] ScaleWav(byte[] b, WavInfo info, double gain)')
$nextMethod = $text.IndexOf('int NextDelay()', $scaleStart)
$scaleBody = if ($scaleStart -ge 0 -and $nextMethod -ge 0) { $text.Substring($scaleStart, $nextMethod - $scaleStart) } else { '' }
Check 'ScaleWav carries no second chunk scanner (no while loop)' ($scaleBody -notmatch '\bwhile\b')
Check 'ScaleWav carries no second chunk scanner (no chunk-id decode)' ($scaleBody -notmatch 'GetString')

Write-Host '---'
if ($fails) { Write-Host "FAILED ($fails failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0

