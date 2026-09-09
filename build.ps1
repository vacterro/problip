$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Resolve csc.exe from $env:WINDIR (Windows is not always on C:), preferring
# Framework64 and falling back to the 32-bit Framework directory.
$csc = $null
foreach ($base in @('Framework64', 'Framework')) {
    $candidate = Join-Path $env:WINDIR "Microsoft.NET\$base\v4.0.30319\csc.exe"
    if (Test-Path -LiteralPath $candidate) { $csc = $candidate; break }
}
if ($null -eq $csc) { throw "csc.exe not found under $env:WINDIR\Microsoft.NET\{Framework64,Framework}\v4.0.30319" }

& $csc -nologo -target:winexe -out:(Join-Path $root 'Problip.exe') -optimize+ `
    -win32icon:(Join-Path $root 'problip.ico') -r:System.dll -r:System.Drawing.dll `
    -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output "Built $(Join-Path $root 'Problip.exe')"
