# Shared compiler discovery: csc.exe resolved from $env:WINDIR (Windows is not
# always on C:), preferring Framework64 with a Framework fallback. Returns
# $null when neither exists; callers must fail their harness explicitly.
function Find-Csc {
    foreach ($base in 'Framework64', 'Framework') {
        $c = Join-Path $env:WINDIR "Microsoft.NET\$base\v4.0.30319\csc.exe"
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}
