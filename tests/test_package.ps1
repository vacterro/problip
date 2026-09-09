param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition))
)

$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled variable must FAIL the harness
# immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

# Packaging contract checks. Positive: the real repository packages into a ZIP
# containing exactly the intended runtime files and none of the forbidden user/
# dev state. Negative: staging a copy without blip01.wav must make packaging
# FAIL with no valid-looking ZIP left behind. The real repository is never
# mutated -- the negative case runs from a disposable copy.

Add-Type -AssemblyName System.IO.Compression.FileSystem
$mandatory = @('Problip.exe', 'blip01.wav', 'problip.ico', 'README.md')
$forbidden = @('problip.ini', 'problip.stats.ini', 'Problip.cs', 'package.ps1', 'build.ps1', '_AUDAPACK_MANIFEST.json', 'problip.example.ini')

# 1. Positive: package the real repository.
& (Join-Path $RepoRoot 'package.ps1') | Out-Null
$exit = $LASTEXITCODE
Check 'packaging the real repository succeeds' ($exit -eq 0) "exit=$exit"

$zip = Join-Path $RepoRoot 'dist\problip-portable.zip'
Check 'the release ZIP exists' (Test-Path -LiteralPath $zip)
if (Test-Path -LiteralPath $zip) {
    $names = [IO.Compression.ZipFile]::OpenRead($zip).Entries.Name
    foreach ($m in $mandatory) { Check "ZIP contains $m" ($names -contains $m) }
    foreach ($f in $forbidden) { Check "ZIP does NOT contain $f" ($names -notcontains $f) }
    $unexpected = @($names | Where-Object { $mandatory -notcontains $_ })
    Check 'ZIP contains nothing beyond the mandatory release files' ($unexpected.Count -eq 0) "unexpected=$($unexpected -join ', ')"
}

# 2. Negative: a staged copy missing blip01.wav must fail closed, leaving no
#    plausible release ZIP. The real repository and its assets stay untouched.
$stage = Join-Path $env:TEMP ('problip_pkg_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    # Stage only what packaging needs to reach the asset check: build.ps1,
    # package.ps1, Problip.cs, problip.ico, README.md -- deliberately NO wav.
    foreach ($f in @('build.ps1', 'package.ps1', 'Problip.cs', 'problip.ico', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination (Join-Path $stage $f)
    }
    $out = $null
    try {
        # 2>&1 turns the child's stderr into ErrorRecords under EAP=Stop; the
        # catch keeps the runner alive so the CHECK below can see the exit code.
        $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'package.ps1') 2>&1 | ForEach-Object { "$_" })
    } catch { $out = @($_.Exception.Message) }
    $negExit = $LASTEXITCODE
    Check 'packaging without blip01.wav fails (non-zero exit)' ($negExit -ne 0) "exit=$negExit out=$($out -join ' | ')"
    $stageZip = Join-Path $stage 'dist\problip-portable.zip'
    Check 'no valid-looking ZIP is produced without the mandatory asset' (-not (Test-Path -LiteralPath $stageZip))
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
