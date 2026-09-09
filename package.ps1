# Builds the release, then packs exactly the runtime files into dist/ and
# produces a clean ZIP. problip.ini is user state and is never packaged.
# Mandatory inputs: a missing required runtime asset aborts packaging with a
# non-zero exit -- no formally valid ZIP without the files the app needs.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

& (Join-Path $root 'build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'build failed; nothing packaged' }

$files = @('Problip.exe', 'blip01.wav', 'problip.ico', 'README.md')
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $f))) {
        Write-Error "missing mandatory release input: $f -- packaging aborted"
        exit 1
    }
}

$dist = Join-Path $root 'dist'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $dist $f)
}

$zip = Join-Path $dist 'problip-portable.zip'
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip -Force
Write-Output "Packaged $zip"

# Fail the package if user state or dev files leaked into it.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipNames = [IO.Compression.ZipFile]::OpenRead($zip).Entries.Name
if ($zipNames -contains 'problip.ini') { throw 'ZIP contains problip.ini (user state must never ship)' }
$unexpected = @($zipNames | Where-Object { $files -notcontains $_ })
if ($unexpected.Count) { throw "ZIP contains unexpected entries: $($unexpected -join ', ')" }
Write-Output "ZIP entries: $($zipNames -join ', ')"
