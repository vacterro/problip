$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_ownership_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

try {
    $probeSource = Join-Path $work 'OwnershipProbe.cs'
    $probe = Join-Path $work 'OwnershipProbe.exe'
    Set-Content -LiteralPath $probeSource -Value @'
using System;
using System.IO;
using System.Threading;
namespace Problip {
    static class OwnershipProbe {
        public static int Main(string[] args) {
            try {
                if (args[0] == "name") {
                    Console.WriteLine(PersistenceOwnership.NameForDirectory(args[1]));
                    return 0;
                }
                if (args[0] == "invalid") {
                    PersistenceOwnership invalid;
                    return PersistenceOwnership.TryAcquire(null, out invalid) ? 0 : 2;
                }
                PersistenceOwnership ownership;
                if (!PersistenceOwnership.TryAcquire(args[1], out ownership)) return 2;
                using (ownership) {
                    if (args[2] != "-") File.WriteAllText(args[2], "ready");
                    if (args[3] != "-") File.AppendAllText(args[3], args[4] + Environment.NewLine);
                    Thread.Sleep(Int32.Parse(args[5]));
                }
                return 0;
            } catch (Exception ex) {
                Console.Error.WriteLine(ex);
                return 1;
            }
        }
    }
}
'@
    & $csc -nologo -target:exe "-out:$probe" -main:Problip.OwnershipProbe -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs') $probeSource | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ownership probe compilation failed' }

    $dirA = Join-Path $work 'portable-a'
    $dirB = Join-Path $work 'portable-b'
    New-Item -ItemType Directory -Path $dirA, $dirB | Out-Null

    function Probe-Name([string]$dir) {
        $value = (& $probe name $dir 2>&1 | ForEach-Object { "$_" }) -join ''
        if ($LASTEXITCODE -ne 0) { throw "name probe failed: $value" }
        return $value.Trim()
    }
    function Start-Owner([string]$dir, [string]$ready, [string]$mutation, [string]$tag, [int]$holdMs) {
        if (Test-Path -LiteralPath $ready) { Remove-Item -LiteralPath $ready -Force }
        $p = Start-Process -FilePath $probe -ArgumentList @('acquire', $dir, $ready, $mutation, $tag, "$holdMs") -PassThru -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $ready) -and -not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path -LiteralPath $ready)) {
            if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
            $exit = if ($p.HasExited) { $p.ExitCode } else { 'running' }
            $p.Dispose()
            throw "owner failed to become ready, exit=$exit"
        }
        return $p
    }
    function Run-Acquire([string]$dir, [string]$mutation, [string]$tag) {
        & $probe acquire $dir '-' $mutation $tag 0 | Out-Null
        return $LASTEXITCODE
    }

    $name = Probe-Name $dirA
    $equivalent = Probe-Name (Join-Path $dirA '.')
    $trailing = Probe-Name ($dirA + [IO.Path]::DirectorySeparatorChar)
    $caseOnly = Probe-Name $dirA.ToUpperInvariant()
    $other = Probe-Name $dirB
    $secondRun = Probe-Name $dirA
    $normalized = [IO.Path]::GetFullPath($dirA).ToUpperInvariant()
    Check 'equivalent path forms have one ownership name' ($name -eq $equivalent)
    Check 'case-only path variation has one ownership name' ($name -eq $caseOnly)
    Check 'trailing separator variation has one ownership name' ($name -eq $trailing)
    Check 'different persistence directories have different ownership names' ($name -ne $other)
    Check 'ownership name uses Global namespace' $name.StartsWith('Global\') $name
    Check 'ownership name excludes raw persistence path' (-not $name.Contains($normalized))
    Check 'ownership name is deterministic across processes' ($name -eq $secondRun)
    Check 'ownership name has fixed SHA-256 shape' ($name -match '^Global\\Problip\.Persistence\.[0-9A-F]{64}$') $name

    $readyA = Join-Path $work 'ready-a'
    $writes = Join-Path $work 'writes.txt'
    $ownerA = Start-Owner $dirA $readyA $writes 'owner-a' 5000
    try {
        $sameExit = Run-Acquire $dirA $writes 'contender-a'
        Check 'same-directory second process cannot acquire' ($sameExit -eq 2) "exit=$sameExit"
        $differentExit = Run-Acquire $dirB $writes 'owner-b'
        Check 'different portable directory acquires concurrently' ($differentExit -eq 0) "exit=$differentExit"
        $written = @(Get-Content -LiteralPath $writes)
        Check 'blocked process never reaches mutation seam' ($written -notcontains 'contender-a') ($written -join ',')
        Check 'both independent owners reach mutation seam' ($written -contains 'owner-a' -and $written -contains 'owner-b') ($written -join ',')
    } finally {
        if (-not $ownerA.HasExited) { $ownerA.Kill() }
        $ownerA.WaitForExit()
        $ownerA.Dispose()
    }

    $readyNormal = Join-Path $work 'ready-normal'
    $normal = Start-Owner $dirA $readyNormal '-' 'normal' 250
    $normal.WaitForExit()
    $normalExit = $normal.ExitCode
    $normal.Dispose()
    $afterNormal = Run-Acquire $dirA $writes 'after-normal'
    Check 'normal owner exits successfully' ($normalExit -eq 0) "exit=$normalExit"
    Check 'ownership releases after normal exit' ($afterNormal -eq 0) "exit=$afterNormal"

    $readyKilled = Join-Path $work 'ready-killed'
    $killed = Start-Owner $dirA $readyKilled '-' 'killed' 30000
    $killed.Kill()
    $killed.WaitForExit()
    $killed.Dispose()
    $afterKill = Run-Acquire $dirA $writes 'after-kill'
    Check 'abnormal owner termination permits recovery' ($afterKill -eq 0) "exit=$afterKill"

    $written = @(Get-Content -LiteralPath $writes)
    Check 'writer may mutate after prior owner exits' ($written -contains 'after-normal' -and $written -contains 'after-kill') ($written -join ',')
    & $probe invalid | Out-Null
    $invalidExit = $LASTEXITCODE
    Check 'invalid ownership directory fails closed' ($invalidExit -eq 2) "exit=$invalidExit"
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
