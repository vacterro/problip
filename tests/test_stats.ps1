$ErrorActionPreference = 'Stop'
# Strict mode is the typo oracle: a misspelled test variable must FAIL this
# harness immediately instead of silently evaluating to $null.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$RealWav = Join-Path $root 'blip01.wav'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'csc.ps1')
$csc = Find-Csc
if ($null -eq $csc) { Write-Host "FAIL  csc.exe not found under $env:WINDIR"; exit 1 }
$work = Join-Path $env:TEMP ('problip_stats_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS  $n $d" } else { Write-Host "FAIL  $n $d"; $script:fail++ } }

# Pure successful-blip statistics + isolated persistence. Exercises the REAL
# compiled classes (no reimplementation in the test):
#   - period keys: local day, ISO-8601 week-year, local month
#   - lazy rollover: stale periods read 0 before the first blip of the period
#   - saturating counters: negatives sanitize to 0, long.MaxValue saturates
#   - Total never resets
#   - separate problip.stats.ini store; failure never throws, dirty is retained
#   - normal Stop flushes pending statistics
# The wall clock is injected (LocalNow), never slept on. Disposable temp dirs only.

try {
    $dll = Join-Path $work 'Problip.dll'
    & $csc -nologo -target:library "-out:$dll" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Problip.cs compilation failed' }
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))

    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $logicType = $asm.GetType('Problip.BlipStatsLogic', $true)
    $recordType = $asm.GetType('Problip.BlipStatsRecord', $true)
    $snapType = $asm.GetType('Problip.BlipStatsSnapshot', $true)
    $storeType = $asm.GetType('Problip.BlipStatsStore', $true)
    $settingsType = $asm.GetType('Problip.Settings', $true)
    $engineType = $asm.GetType('Problip.BlipEngine', $true)

    $dayKeyM = $logicType.GetMethod('DayKey', $staticFlags)
    $monthKeyM = $logicType.GetMethod('MonthKey', $staticFlags)
    $weekKeyM = $logicType.GetMethod('WeekKey', $staticFlags)
    $incM = $logicType.GetMethod('IncrementSaturating', $staticFlags)
    $sanM = $logicType.GetMethod('Sanitize', $staticFlags)
    $recordM = $logicType.GetMethod('Record', $staticFlags)
    $snapshotM = $logicType.GetMethod('Snapshot', $staticFlags)

    $recordCtor = $recordType.GetConstructor($flags, $null, @(), $null)
    $storeCtor = $storeType.GetConstructor($flags, $null, @([string]), $null)
    $storeSnapM = $storeType.GetMethod('Snapshot')
    $storeRecordBlipM = $storeType.GetMethod('RecordBlip')
    $storeFlushM = $storeType.GetMethod('Flush')
    $storeFlushIfDirtyM = $storeType.GetMethod('FlushIfDirty')
    $pathField = $storeType.GetField('Path', $flags)
    $localNowField = $storeType.GetField('LocalNow', $flags)
    $nowMsFieldStore = $storeType.GetField('NowMs', $flags)
    $dirtyField = $storeType.GetField('Dirty', $flags)

    function New-Record { $recordCtor.Invoke(@()) }
    function Do-Record($rec, [datetime]$dt) { $recordM.Invoke($null, [object[]]@($rec, $dt)) | Out-Null }
    function Do-Snapshot($rec, [datetime]$dt) { $snapshotM.Invoke($null, [object[]]@($rec, $dt)) }
    function Get-Key($m, [datetime]$dt) { [string]$m.Invoke($null, [object[]]@($dt)) }
    function New-Store([string]$dir, [datetime]$now) {
        $st = $storeCtor.Invoke(@([string]$dir))
        # GetNewClosure captures $now by value; a plain scriptblock would read
        # the (long gone) function scope at invocation time.
        $fn = { param() $now }.GetNewClosure()
        $localNowField.SetValue($st, [Func[datetime]]$fn)
        return $st
    }

    $D0 = [datetime]'2026-09-09'   # Wednesday, ISO 2026-W37
    $D1 = [datetime]'2026-09-10'   # next day, same week/month
    $D2 = [datetime]'2026-09-14'   # next ISO week (Monday), same month
    $D3 = [datetime]'2026-10-01'   # next month

    # A. first successful blip
    $r = New-Record; Do-Record $r $D0
    $s = Do-Snapshot $r $D0
    Check 'A first blip: Today=Week=Month=Total=1' `
        ($s.Today -eq 1 -and $s.Week -eq 1 -and $s.Month -eq 1 -and $s.Total -eq 1) `
        "T=$($s.Today) W=$($s.Week) M=$($s.Month) Tot=$($s.Total)"

    # B. another blip same day -> all four increment
    Do-Record $r $D0
    $s = Do-Snapshot $r $D0
    Check 'B same-day blip increments all four counters' `
        ($s.Today -eq 2 -and $s.Week -eq 2 -and $s.Month -eq 2 -and $s.Total -eq 2) `
        "T=$($s.Today) W=$($s.Week) M=$($s.Month) Tot=$($s.Total)"

    # C. next local day, same ISO week/month
    Do-Record $r $D1
    $s = Do-Snapshot $r $D1
    Check 'C next day: Today resets to 1, Week/Month/Total continue' `
        ($s.Today -eq 1 -and $s.Week -eq 3 -and $s.Month -eq 3 -and $s.Total -eq 3) `
        "T=$($s.Today) W=$($s.Week) M=$($s.Month) Tot=$($s.Total)"

    # D. next ISO week -> Week resets to 1
    Do-Record $r $D2
    $s = Do-Snapshot $r $D2
    Check 'D next ISO week: Week resets to 1, others continue' `
        ($s.Week -eq 1 -and $s.Today -eq 1 -and $s.Month -eq 4 -and $s.Total -eq 4) `
        "T=$($s.Today) W=$($s.Week) M=$($s.Month) Tot=$($s.Total)"

    # E. next month -> Month resets to 1
    Do-Record $r $D3
    $s = Do-Snapshot $r $D3
    Check 'E next month: Month resets to 1, Total continues' `
        ($s.Month -eq 1 -and $s.Today -eq 1 -and $s.Total -eq 5) `
        "T=$($s.Today) W=$($s.Week) M=$($s.Month) Tot=$($s.Total)"

    # F. snapshot after midnight BEFORE the first new blip: stale Today reads 0
    $rf = New-Record
    Do-Record $rf $D0; Do-Record $rf $D0; Do-Record $rf $D0; Do-Record $rf $D0; Do-Record $rf $D0
    $sf = Do-Snapshot $rf $D1   # next day, no new blip yet
    Check 'F snapshot after midnight before the first blip shows Today=0' `
        ($sf.Today -eq 0 -and $sf.Week -eq 5 -and $sf.Month -eq 5 -and $sf.Total -eq 5) `
        "T=$($sf.Today) W=$($sf.Week) M=$($sf.Month) Tot=$($sf.Total)"

    # G. ISO week-year boundary correctness
    $isoCases = @(
        @{ D = '2021-01-01'; W = '2020-W53' },
        @{ D = '2021-01-04'; W = '2021-W01' },
        @{ D = '2022-01-01'; W = '2021-W52' },
        @{ D = '2022-01-03'; W = '2022-W01' },
        @{ D = '2019-12-30'; W = '2020-W01' },
        @{ D = '2016-01-01'; W = '2015-W53' },
        @{ D = '2016-01-04'; W = '2016-W01' },
        @{ D = '2026-09-09'; W = '2026-W37' }
    )
    $isoOk = $true; $isoDetail = ''
    foreach ($c in $isoCases) {
        $got = Get-Key $weekKeyM ([datetime]$c.D)
        if ($got -ne $c.W) { $isoOk = $false; $isoDetail += "$($c.D):$got!=$($c.W) " }
    }
    Check 'G ISO week-year is correct around New Year boundaries' $isoOk $isoDetail

    # H. negative persisted counters sanitize to zero
    $rh = New-Record
    $rh.DayKey = Get-Key $dayKeyM $D0
    $rh.WeekKey = Get-Key $weekKeyM $D0
    $rh.MonthKey = Get-Key $monthKeyM $D0
    $rh.TodayCount = -5; $rh.WeekCount = -1; $rh.MonthCount = -3; $rh.TotalCount = -9
    $sh = Do-Snapshot $rh $D0
    Check 'H negative persisted counters sanitize to zero' `
        ($sh.Today -eq 0 -and $sh.Week -eq 0 -and $sh.Month -eq 0 -and $sh.Total -eq 0) `
        "T=$($sh.Today) W=$($sh.Week) M=$($sh.Month) Tot=$($sh.Total)"
    Check 'H IncrementSaturating normalizes a negative before incrementing' `
        (([long]$incM.Invoke($null, @([long]-5)) -eq 1) -and ([long]$incM.Invoke($null, @([long]-1)) -eq 1))
    Check 'H Sanitize maps negatives to zero' ([long]$sanM.Invoke($null, @([long]-7)) -eq 0)

    # I. long.MaxValue saturates (no wraparound)
    $maxInc = [long]$incM.Invoke($null, @([long][long]::MaxValue))
    $nearInc = [long]$incM.Invoke($null, @([long]([long]::MaxValue - 1)))
    Check 'I IncrementSaturating saturates at long.MaxValue' `
        ($maxInc -eq [long]::MaxValue -and $nearInc -eq [long]::MaxValue) "max=$maxInc near=$nearInc"
    $ri = New-Record
    $ri.DayKey = Get-Key $dayKeyM $D0; $ri.WeekKey = Get-Key $weekKeyM $D0; $ri.MonthKey = Get-Key $monthKeyM $D0
    $ri.TotalCount = [long]::MaxValue
    Do-Record $ri $D0
    Check 'I a saturating record never wraps Total negative' `
        ($ri.TotalCount -eq [long]::MaxValue) "total=$($ri.TotalCount)"

    # J. Total never rolls over across many periods
    $rj = New-Record
    foreach ($d in @('2026-09-09', '2026-09-10', '2026-09-14', '2026-10-01', '2027-01-01')) {
        Do-Record $rj ([datetime]$d)
    }
    $sj = Do-Snapshot $rj ([datetime]'2027-01-01')
    Check 'J Total never rolls over across period changes' ($sj.Total -eq 5) "total=$($sj.Total)"

    # ---- Persistence ----
    # Round-trip through a real store.
    $dir1 = Join-Path $work 's1'; New-Item -ItemType Directory -Path $dir1 | Out-Null
    $st1 = New-Store $dir1 $D0
    $storeRecordBlipM.Invoke($st1, @()) | Out-Null
    $storeRecordBlipM.Invoke($st1, @()) | Out-Null
    $flushOk = [bool]$storeFlushM.Invoke($st1, @())
    $statsPath = Join-Path $dir1 'problip.stats.ini'
    Check 'stats flush lands and writes problip.stats.ini' ($flushOk -and (Test-Path -LiteralPath $statsPath)) "flush=$flushOk path=$statsPath"
    $st1b = New-Store $dir1 $D0
    $sb = $storeSnapM.Invoke($st1b, @())
    Check 'stats round-trip reloads the persisted counters' ($sb.Total -eq 2 -and $sb.Today -eq 2) "T=$($sb.Today) Tot=$($sb.Total)"

    # Malformed / negative persisted counts sanitize on load.
    $dir2 = Join-Path $work 's2'; New-Item -ItemType Directory -Path $dir2 | Out-Null
    $dk = Get-Key $dayKeyM $D0; $wk = Get-Key $weekKeyM $D0; $mk = Get-Key $monthKeyM $D0
    Set-Content -LiteralPath (Join-Path $dir2 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=$dk
TodayCount=-5
WeekKey=$wk
WeekCount=notanumber
MonthKey=$mk
MonthCount=-3
TotalCount=-9
"@
    $st2 = New-Store $dir2 $D0
    $s2 = $storeSnapM.Invoke($st2, @())
    Check 'malformed/negative persisted stats sanitize on load' `
        ($s2.Today -eq 0 -and $s2.Week -eq 0 -and $s2.Month -eq 0 -and $s2.Total -eq 0) `
        "T=$($s2.Today) W=$($s2.Week) M=$($s2.Month) Tot=$($s2.Total)"

    # Stale period keys read 0 before any new-period blip.
    $dir3 = Join-Path $work 's3'; New-Item -ItemType Directory -Path $dir3 | Out-Null
    Set-Content -LiteralPath (Join-Path $dir3 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=2000-01-01
TodayCount=99
WeekKey=2000-W01
WeekCount=99
MonthKey=2000-01
MonthCount=99
TotalCount=99
"@
    $st3 = New-Store $dir3 $D0
    $s3 = $storeSnapM.Invoke($st3, @())
    Check 'stale period snapshot reads 0 while Total is preserved' `
        ($s3.Today -eq 0 -and $s3.Week -eq 0 -and $s3.Month -eq 0 -and $s3.Total -eq 99) `
        "T=$($s3.Today) W=$($s3.Week) M=$($s3.Month) Tot=$($s3.Total)"

    # Persistence failure: never throws, retains dirty, later retry persists newest.
    $st4 = New-Store (Join-Path $work 's4') $D0
    New-Item -ItemType Directory -Path (Join-Path $work 's4dir') -Force | Out-Null
    $pathField.SetValue($st4, [string](Join-Path $work 's4dir'))   # a directory: cannot be an INI
    $threw = $false
    $badFlush = $true
    try { $badFlush = [bool]$storeFlushM.Invoke($st4, @()) } catch { $threw = $true }
    $storeRecordBlipM.Invoke($st4, @()) | Out-Null
    Check 'a failed stats flush returns false and never throws' (-not $threw -and -not $badFlush) "threw=$threw flush=$badFlush"
    Check 'a failed stats flush retains dirty in-memory state' ([bool]$dirtyField.GetValue($st4))
    $st4.Record.TotalCount = 7
    $retryPath = Join-Path $work 's4-retry.stats.ini'
    $pathField.SetValue($st4, [string]$retryPath)
    $retryOk = [bool]$storeFlushM.Invoke($st4, @())
    # Read the retry file back through a fresh store pointed at it.
    $st4b = $storeCtor.Invoke(@([string]$work))
    $pathField.SetValue($st4b, [string]$retryPath)
    $localNowField.SetValue($st4b, [Func[datetime]]{ param() $D0 })
    $storeType.GetMethod('Load', $flags).Invoke($st4b, @()) | Out-Null
    $s4 = $storeSnapM.Invoke($st4b, @())
    Check 'a later writable retry persists the newest snapshot' `
        ($retryOk -and $s4.Total -eq 7 -and -not ([bool]$dirtyField.GetValue($st4))) "retry=$retryOk total=$($s4.Total)"

    # Normal Stop flushes pending statistics.
    $dir5 = Join-Path $work 's5'; New-Item -ItemType Directory -Path $dir5 | Out-Null
    $settingsCtor = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtor = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $s5 = $settingsCtor.Invoke(@([string]$dir5))
    $settingsType.GetMethod('Load').Invoke($s5, @()) | Out-Null
    $s5.WavPath = [string]$RealWav
    $s5.Volume = 0.0
    $e5 = $engineCtor.Invoke(@($s5))
    $statsField = $engineType.GetField('Stats', $flags)
    $st5 = $statsField.GetValue($e5)
    $localNowField.SetValue($st5, [Func[datetime]]{ param() $D0 })
    # Freeze the batching clock so RecordBlip marks dirty but does NOT auto-flush.
    $nowMsFieldStore.SetValue($st5, [Func[long]]{ param() [long]0 })
    $engineType.GetField('NowMs', $flags).SetValue($e5, [Func[long]]{ param() [long]0 })
    $e5.Start()
    $tickM = $engineType.GetMethod('Tick', $flags)
    $tickM.Invoke($e5, @($null, [EventArgs]::Empty)) | Out-Null
    $statsPath5 = Join-Path $dir5 'problip.stats.ini'
    $beforeStop = Test-Path -LiteralPath $statsPath5
    $e5.Stop()
    $afterStop = Test-Path -LiteralPath $statsPath5
    Check 'a normal Stop flushes pending statistics to disk' (-not $beforeStop -and $afterStop) "before=$beforeStop after=$afterStop"
    $e5.Cleanup()

    # ---- ATOMIC SNAPSHOT COMMIT ----
    # The old Flush() wrote seven keys one Win32 call at a time; a failure
    # midway persisted a hybrid (new DayKey, old TodayCount) and next launch
    # presented yesterday's count as today's. The whole [stats] section now
    # commits as one file replacement: a failed replacement must leave the
    # previous COMPLETE snapshot on disk, never half of the new one.
    $commitField = $storeType.GetField('CommitFile', $flags)
    $attemptCountField = $storeType.GetField('FlushAttemptCount', $flags)
    $tempPath = Join-Path $dir1 'problip.stats.ini.tmp'
    $fileText = Get-Content -LiteralPath $statsPath -Raw
    Check 'the committed snapshot is one complete [stats] section' `
        ($fileText -match '(?m)^\[stats\]\r?$' -and $fileText -match 'DayKey=' -and $fileText -match 'TotalCount=2') `
        ($fileText -replace "`r", "" -replace "`n", " | ")
    $stA = New-Store $dir1 $D0
    $stA.Record.TodayCount = 3
    $stA.Record.TotalCount = 7
    $dirtyField.SetValue($stA, $true)   # as if RecordBlip had marked the newest snapshot
    $origCommit = $commitField.GetValue($stA)
    $commitField.SetValue($stA, [Func[string,string,bool]]{ param($t, $p) return $false })
    $failOk = [bool]$storeFlushM.Invoke($stA, @())
    Check 'a failed atomic commit returns false' (-not $failOk)
    Check 'a failed atomic commit retains the dirty snapshot for retry' ([bool]$dirtyField.GetValue($stA))
    Check 'a failed atomic commit leaves the previous COMPLETE snapshot on disk' `
        ((Get-Content -LiteralPath $statsPath -Raw) -eq $fileText) "file unchanged"
    Check 'a failed atomic commit leaves no temporary file behind' (-not (Test-Path -LiteralPath $tempPath)) "tmp=$tempPath"
    # Remove the failure: the next flush persists the NEWEST snapshot, whole.
    $commitField.SetValue($stA, $origCommit)
    $okA = [bool]$storeFlushM.Invoke($stA, @())
    $newText = Get-Content -LiteralPath $statsPath -Raw
    Check 'the retry after a failed commit persists the newest complete snapshot' `
        ($okA -and $newText -match 'TodayCount=3' -and $newText -match 'TotalCount=7' -and -not ([bool]$dirtyField.GetValue($stA))) `
        ($newText -replace "`r", "" -replace "`n", " | ")
    Check 'a failed flush must not mix old and new state (no hybrid snapshot)' `
        (-not (($newText -match 'TodayCount=2') -or ($newText -match 'TotalCount=2')))
    Check 'no temporary snapshot file survives a successful flush' (-not (Test-Path -LiteralPath $tempPath))

    # ---- BOUNDED FAILED-FLUSH RETRY (the attempt window) ----
    # The old contract advanced the batching window only on SUCCESS, so a
    # permanently unwritable stats path retried on every blip. The window now
    # advances on every ATTEMPT.
    $stT = New-Store (Join-Path $work 'st') $D0
    New-Item -ItemType Directory -Path (Join-Path $work 'st') -Force | Out-Null
    $script:statClock = [long]0
    $statsNowT = $storeType.GetField('NowMs', $flags)
    $statsNowT.SetValue($stT, [Func[long]]{ param() $script:statClock })
    $commitField.SetValue($stT, [Func[string,string,bool]]{ param($t, $p) return $false })
    $storeRecordBlipM.Invoke($stT, @()) | Out-Null   # t=0: 0-0 < 10000 -> no attempt
    $n0 = [int]$attemptCountField.GetValue($stT)
    $script:statClock = 10000
    $storeRecordBlipM.Invoke($stT, @()) | Out-Null   # failed automatic attempt #1
    $n1 = [int]$attemptCountField.GetValue($stT)
    $script:statClock = 11000
    $storeRecordBlipM.Invoke($stT, @()) | Out-Null   # inside the window: NO attempt
    $n2 = [int]$attemptCountField.GetValue($stT)
    $script:statClock = 15000
    $storeRecordBlipM.Invoke($stT, @()) | Out-Null   # still inside: NO attempt
    $n3 = [int]$attemptCountField.GetValue($stT)
    $script:statClock = 20000
    $storeRecordBlipM.Invoke($stT, @()) | Out-Null   # window elapsed: attempt #2
    $n4 = [int]$attemptCountField.GetValue($stT)
    Check 'the first blip inside a fresh window performs no flush attempt' ($n0 -eq 0) "attempts=$n0"
    Check 't=10000 performs the first failed automatic attempt' ($n1 -eq 1) "attempts=$n1"
    Check 't=11000 does NOT retry the failed flush' ($n2 -eq 1) "attempts=$n2"
    Check 't=15000 still does NOT retry' ($n3 -eq 1) "attempts=$n3"
    Check 't=20000+ retries exactly once (window elapsed)' ($n4 -eq 2) "attempts=$n4"
    $storeFlushIfDirtyM.Invoke($stT, @()) | Out-Null   # Stop/exit: forced attempt
    $n5 = [int]$attemptCountField.GetValue($stT)
    Check 'an explicit lifecycle flush forces one immediate attempt regardless of the window' ($n5 -eq 3) "attempts=$n5"
    Check 'a failed flush keeps Dirty true through every bounded retry' ([bool]$dirtyField.GetValue($stT))
    $commitField.SetValue($stT, $null)

    # ---- managed [stats] reader tolerance ----
    $dirP = Join-Path $work 'sP'; New-Item -ItemType Directory -Path $dirP | Out-Null
    Set-Content -LiteralPath (Join-Path $dirP 'problip.stats.ini') -NoNewline -Value @"
[other]
TotalCount=999
[stats]
DayKey=$dk
TodayCount=5 ; inline comment kept out of the value
WeekKey=$wk
WeekCount=abc
MonthKey=$mk
MonthCount=6
TotalCount=7
"@
    $stP = New-Store $dirP $D0
    $sP = $storeSnapM.Invoke($stP, @())
    Check 'the managed reader takes keys only from the [stats] section' ($sP.Total -eq 7) "total=$($sP.Total)"
    Check 'the managed reader trims one inline comment and keeps the value' ($sP.Today -eq 5) "today=$($sP.Today)"
    Check 'the managed reader sanitizes malformed counts to zero' ($sP.Week -eq 0) "week=$($sP.Week)"
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
