# Canonical regression entrypoint: discovers EVERY tests/test_*.ps1 harness
# deterministically, runs each, reports one summary, exits non-zero on any
# failure. Discovery is the point: an explicit list once let test_runstate.ps1
# exist without being registered, so a whole runtime-state wave shipped as a
# false-green "6/6 PASS" that never ran its own harness. A new test_*.ps1 is
# now automatically part of the suite; it cannot silently escape the runner.
$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$harnesses = @(Get-ChildItem -LiteralPath $testsDir -Filter 'test_*.ps1' -File |
    Sort-Object -Property Name |
    ForEach-Object { $_.Name })
if ($harnesses.Count -eq 0) {
    Write-Host 'FAIL  no test_*.ps1 harnesses found'
    exit 1
}

$results = @()
foreach ($h in $harnesses) {
    $path = Join-Path $testsDir $h
    Write-Host "=== $h ==="
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "FAIL  harness missing: $path"
        $results += [pscustomobject]@{ Name = $h; Exit = 1 }
        continue
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $path
    $results += [pscustomobject]@{ Name = $h; Exit = $LASTEXITCODE }
}

Write-Host ''
Write-Host '=== SUMMARY ==='
foreach ($r in $results) {
    $status = if ($r.Exit -eq 0) { 'PASS' } else { 'FAIL' }
    Write-Host ("{0}  {1}" -f $status, $r.Name)
}
$failed = @($results | Where-Object { $_.Exit -ne 0 }).Count
if ($failed -gt 0) { Write-Host "FAILED ($failed of $($results.Count) harness(es))"; exit 1 }
Write-Host "ALL PASS ($($results.Count) harness(es))"
exit 0
