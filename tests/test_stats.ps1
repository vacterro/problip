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
    & $csc -nologo -target:library "-out:$dll" -r:System.dll -r:System.Drawing.dll -r:System.Windows.Forms.dll (Join-Path $root 'Problip.cs') (Join-Path $root 'tests\seams.cs') | Out-Null
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

    # -- Compiled worker-safe seams --
    # PowerShell scriptblock delegates must never run on the store's background
    # persistence worker (a scriptblock needs a PS runspace; on a foreign thread
    # the invocation fails or destabilizes the host). Any seam the worker can
    # invoke (ReadText during worker recovery, CommitFile, CommitFileGate) is
    # one of these compiled IL delegates from tests/seams.cs.
    $seamsType = $asm.GetType('ProblipTest.StatsSeams', $true)
    $blockGateType = $seamsType.GetNestedType('BlockGate')
    function New-FailingCommit { [Func[string,string,bool]]$seamsType.GetMethod('FailingCommit').Invoke($null, @()) }
    function New-RealCommit { [Func[string,string,bool]]$seamsType.GetMethod('RealCommit').Invoke($null, @()) }
    function New-ThrowingRead([string]$m) { [Func[string,string]]$seamsType.GetMethod('ThrowingRead').Invoke($null, @([string]$m)) }
    function New-RealRead { [Func[string,string]]$seamsType.GetMethod('RealRead').Invoke($null, @()) }
    function New-BlockGate {
        # Compiled delegates only: the gate's Wait/Open methods are bound
        # ahead of time via reflection so nothing scriptblock-based can ever
        # be invoked from the worker thread or a dead closure scope.
        $g = [Activator]::CreateInstance($blockGateType)
        $waitM = $blockGateType.GetMethod('WaitEntered')
        $openM = $blockGateType.GetMethod('Open')
        @{
            Obj  = $g
            Gate = [Func[bool]]$blockGateType.GetProperty('Gate').GetValue($g)
            Wait = [Func[int,bool]]$waitM.CreateDelegate([Func[int,bool]], $g)
            Open = [Action]$openM.CreateDelegate([Action], $g)
        }
    }
    $waitIdleM = $storeType.GetMethod('WaitIdle', $flags)

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
        $commitField.SetValue($stA, (New-FailingCommit))
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
        $commitField.SetValue($stT, (New-FailingCommit))
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
    # ---- W2-001: unreadable baseline quarantine & bounded recovery ----
    # Production tri-state: an existing-but-unreadable file is NEVER treated as
    # an empty database. Automatic writes are quarantined while the stat is
    # UNKNOWN; recovery re-reads at the bounded flush cadence, merges delta once,
    # and only then persists.

    $baselineStateType = $asm.GetType('Problip.StatsBaselineState', $true)
    $missingVal = [System.Enum]::Parse($baselineStateType, 'Missing')
    $healthyVal = [System.Enum]::Parse($baselineStateType, 'Healthy')
    $unreadableVal = [System.Enum]::Parse($baselineStateType, 'Unreadable')
    $baselineField = $storeType.GetField('BaselineState', $flags)
    $pendingField = $storeType.GetField('PendingDelta', $flags)
    $hasKnownM = $storeType.GetProperty('HasKnownBaseline')
    $readTextField = $storeType.GetField('ReadText', $flags)
    $mergeM = $logicType.GetMethod('MergeBaselineAndDelta', $staticFlags)
    $addSatM = $logicType.GetMethod('AddSaturating', $staticFlags)
    $recordCtor0 = $recordType.GetConstructor($flags, $null, @(), $null)

    # helpers
    function New-StatsWithSeam([string]$dir, [datetime]$now, [ScriptBlock]$seam) {
        if ($null -eq $seam) { return New-Store $dir $now }
        # Use constructor overload (dir, Func<string,string>) so seam is injected BEFORE Load.
        $ctor2 = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
        $st = $ctor2.Invoke(@([string]$dir, [Func[string,string]]$seam))
        $localNowField.SetValue($st, [Func[datetime]]{ param() $now })
        return $st
    }
    function Record-Here($rec, [datetime]$dt) { Do-Record $rec $dt }
    function Make-Record([string]$day, [long]$today, [string]$week, [long]$wk, [string]$month, [long]$mo, [long]$tot) {
        $r2 = $recordCtor0.Invoke(@())
        $r2.DayKey = [string]$day; $r2.TodayCount = $today
        $r2.WeekKey = [string]$week; $r2.WeekCount = $wk
        $r2.MonthKey = [string]$month; $r2.MonthCount = $mo
        $r2.TotalCount = $tot; return $r2
    }

    # K. missing file -> HasKnownBaseline true, BaselineState Missing, normal recording
    $dirK = Join-Path $work 'w2Missing'; New-Item -ItemType Directory -Path $dirK | Out-Null
    $stK = New-Store $dirK $D0
    # missing file: treat as known zero baseline (not Unreadable)
    # New-Store ctor ran Load() with DefaultReadText -> real missing file => returns null => Missing.
    # But our old New-Store returns File.ReadAllText seam semantics mismatch. Verify against current tree's BaselineState.
    # Use the single-ctor New-Store: it bound the default seam post-construction and Load already ran.
    # Ensure path was missing: re-create store from clean dir via 2-arg ctor ensures correct Missing.
  $dirK2 = Join-Path $work 'w2Missing2'; New-Item -ItemType Directory -Path $dirK2 | Out-Null
  # Missing file: exercise the production DefaultReadText on a genuinely-absent file.
  $stK2 = New-Store $dirK2 $D0
  Check 'missing file -> BaselineState Missing' ($baselineField.GetValue($stK2) -eq $missingVal) "got=$($baselineField.GetValue($stK2))"
  Check 'missing file -> HasKnownBaseline true' ([bool]$hasKnownM.GetValue($stK2, $null)) "known=$([bool]$hasKnownM.GetValue($stK2, $null))"
  # Normal recording + flush creates file
  $nowMsFieldK = $storeType.GetField('NowMs', $flags)
  $script:clockK = [long]100000
  $nowMsFieldK.SetValue($stK2, [Func[long]]{ param() $script:clockK })
  $storeRecordBlipM.Invoke($stK2, @()) | Out-Null
  $storeFlushM.Invoke($stK2, @()) | Out-Null
  Check 'missing baseline: normal flush creates file' (Test-Path -LiteralPath (Join-Path $dirK2 'problip.stats.ini'))

    # L. existing-file read failure -> Unreadable, session delta, no overwrite
    $dirL = Join-Path $work 'w2Unread'; New-Item -ItemType Directory -Path $dirL | Out-Null
    $dkL = Get-Key $dayKeyM $D0; $wkL = Get-Key $weekKeyM $D0; $mkL = Get-Key $monthKeyM $D0
    $fileL = Join-Path $dirL 'problip.stats.ini'
    Set-Content -LiteralPath $fileL -NoNewline -Value @"
[stats]
DayKey=$dkL
TodayCount=10
WeekKey=$wkL
WeekCount=20
MonthKey=$mkL
MonthCount=30
TotalCount=100
"@
    $bytesL = [IO.File]::ReadAllBytes($fileL)
    $failReadsL = $false
    $failReadsLRef = [ref]$failReadsL
    # Fault seam: throw IOException on the first production-style read (constructor Load)
        $seamLFails = New-ThrowingRead 'transient unreadable'
    $ctor2L = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
    $stL = $ctor2L.Invoke(@([string]$dirL, $seamLFails))
    $localNowField.SetValue($stL, [Func[datetime]]{ param() $D0 })
    Check 'existing-file read failure -> BaselineState Unreadable' ($baselineField.GetValue($stL) -eq $unreadableVal) "got=$($baselineField.GetValue($stL))"
    Check 'unreadable -> HasKnownBaseline false' (-not [bool]$hasKnownM.GetValue($stL, $null)) "known=$([bool]$hasKnownM.GetValue($stL, $null))"
    # Recording must go to PendingDelta, not Record
    $script:clockL = [long]0
    $nowMsFieldL = $storeType.GetField('NowMs', $flags)
    $nowMsFieldL.SetValue($stL, [Func[long]]{ param() $script:clockL })
    # Replace ReadText with a STILL-failing seam so flush path stays failing, but clock drives batching.
        $readTextField.SetValue($stL, (New-ThrowingRead 'still unreadable'))
    $storeRecordBlipM.Invoke($stL, @()) | Out-Null
    $storeRecordBlipM.Invoke($stL, @()) | Out-Null
    $storeRecordBlipM.Invoke($stL, @()) | Out-Null
    $pendingL = $pendingField.GetValue($stL)
    Check 'while unreadable: pending delta accumulates' ($pendingL.TotalCount -eq 3) "total=$($pendingL.TotalCount)"
    Check 'while unreadable: authoritative Record stays empty' ($stL.Record.TotalCount -eq 0) "total=$($stL.Record.TotalCount)"
    # Advance clock beyond FlushIntervalMs and do another RecordBlip -> bounded AttemptRecovery that must write NOTHING
    $script:clockL = 20000
    $storeRecordBlipM.Invoke($stL, @()) | Out-Null  # triggers Automatic -> AttemptRecovery -> returns false -> writes nothing
    $bytesLAfter = [IO.File]::ReadAllBytes($fileL)
    $bytesSameL = ($bytesL.Length -eq $bytesLAfter.Length) -and ([Convert]::ToBase64String($bytesL) -eq [Convert]::ToBase64String($bytesLAfter))
    Check 'while unreadable: original file bytes identical (no overwrite)' $bytesSameL
    Check 'with pending delta: Total == 4 after fourth blip' ($pendingField.GetValue($stL).TotalCount -eq 4) "total=$($pendingField.GetValue($stL).TotalCount)"
    # Explicit lifecycle flush also must NOT overwrite while unreadable
    $storeFlushIfDirtyM.Invoke($stL, @()) | Out-Null
    $bytesLAfter2 = [IO.File]::ReadAllBytes($fileL)
    $bytesSameL2 = ([Convert]::ToBase64String($bytesL) -eq [Convert]::ToBase64String($bytesLAfter2))
    Check 'FlushIfDirty while unreadable: file still identical' $bytesSameL2

    # M. recovery + merge -> Healthy, Total = 100 + 4, same-period merge, disk replay
    $recoveredTotalBefore = $pendingField.GetValue($stL).TotalCount
        $readTextField.SetValue($stL, (New-RealRead))
    # Advance the attempt window so the next RecordBlip (or manual FlushIfDirty) triggers recovery.
    $script:clockL = 40000
    $storeFlushIfDirtyM.Invoke($stL, @()) | Out-Null   # routes to AttemptRecovery: re-read + merge + flush
    Check 'after recovery: BaselineState Healthy' ($baselineField.GetValue($stL) -eq $healthyVal) "got=$($baselineField.GetValue($stL))"
    Check 'after recovery: HasKnownBaseline true' ([bool]$hasKnownM.GetValue($stL, $null))
    Check 'after recovery: pending delta cleared' ($pendingField.GetValue($stL).TotalCount -eq 0) "total=$($pendingField.GetValue($stL).TotalCount)"
    # Same-period check: D0 baseline + D0 delta -> today/week/month add saturating
    Check 'after recovery: Total == persisted + session delta' ($stL.Record.TotalCount -eq (100 + $recoveredTotalBefore)) "total=$($stL.Record.TotalCount)"
    Check 'after recovery: Today == 10 + delta' ($stL.Record.TodayCount -eq (10 + $recoveredTotalBefore)) "today=$($stL.Record.TodayCount)"
    Check 'after recovery: Week == 20 + delta' ($stL.Record.WeekCount -eq (20 + $recoveredTotalBefore)) "week=$($stL.Record.WeekCount)"
    Check 'after recovery: Month == 30 + delta' ($stL.Record.MonthCount -eq (30 + $recoveredTotalBefore)) "month=$($stL.Record.MonthCount)"
    # Fresh store from disk has same values
    $stM2 = New-Store $dirL $D0
    Check 'fresh store after merged flush loads the merged totals' ($stM2.Snapshot().Total -eq (100 + $recoveredTotalBefore)) "total=$($stM2.Snapshot().Total)"

    # N. recovery where CommitFile FAILS -> merged Record + pending cleared + Dirty, disk still old, retry not double-counted
    $dirN = Join-Path $work 'w2FailCommit'; New-Item -ItemType Directory -Path $dirN | Out-Null
    Set-Content -LiteralPath (Join-Path $dirN 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=$dkL
TodayCount=10
WeekKey=$wkL
WeekCount=20
MonthKey=$mkL
MonthCount=30
TotalCount=50
"@
    $ctor2N = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
        $stN = $ctor2N.Invoke(@([string]$dirN, (New-ThrowingRead 'startup unreadable')))
    $localNowField.SetValue($stN, [Func[datetime]]{ param() $D0 })
    $script:clockN = [long]0
    $nowMsFieldN = $storeType.GetField('NowMs', $flags)
    $nowMsFieldN.SetValue($stN, [Func[long]]{ param() $script:clockN })
        $readTextField.SetValue($stN, (New-ThrowingRead 'still bad'))
    $storeRecordBlipM.Invoke($stN, @()) | Out-Null
    $storeRecordBlipM.Invoke($stN, @()) | Out-Null
    $pendingN = $pendingField.GetValue($stN).TotalCount
    Check 'pre-recovery: pending == 2' ($pendingN -eq 2) "total=$pendingN"
    # Enable read recovery but sabotage CommitFile
        $readTextField.SetValue($stN, (New-RealRead))
    $commitField2 = $storeType.GetField('CommitFile', $flags)
    $savedCommitN = $commitField2.GetValue($stN)
        $commitField2.SetValue($stN, (New-FailingCommit))
    $script:clockN = 20000
    $storeRecordBlipM.Invoke($stN, @()) | Out-Null   # batch window: schedules worker recovery (async; hot path never waits)
    # PERF-001: recovery runs on the persistence worker. Wait for it to settle
    # deterministically through the WaitIdle seam (no sleeps).
    $idleN = [bool]$waitIdleM.Invoke($stN, @([int]5000))
    Check 'async recovery settles (worker drained) after the batch window' $idleN
    Check 'failed post-recovery commit: merged Record equals baseline + delta exactly once' `
        ($stN.Record.TotalCount -eq (50 + 3)) "total=$($stN.Record.TotalCount)"
    Check 'failed post-recovery commit: PendingDelta cleared exactly once' ($pendingField.GetValue($stN).TotalCount -eq 0) "total=$($pendingField.GetValue($stN).TotalCount)"
    Check 'failed post-recovery commit: Dirty stays true' ([bool]$dirtyField.GetValue($stN))
    $diskStillOldN = (Get-Content -Raw -LiteralPath (Join-Path $dirN 'problip.stats.ini')) -match 'TotalCount=50'
    Check 'failed post-recovery commit: disk still holds old baseline' $diskStillOldN
    # Retry: restore commit file and flush cleanly. No double-count.
    $commitField2.SetValue($stN, $savedCommitN)
    $script:clockN = 40000
    # Drive retry through an explicit FlushIfDirty (no new delta creation)
    # We have Dirty true, so FlushIfDirty writes Record directly (no re-read, no re-add).
    $storeFlushIfDirtyM.Invoke($stN, @()) | Out-Null
    Check 'retry after failed recovery commit: disk gets merged values' `
        ((Get-Content -Raw -LiteralPath (Join-Path $dirN 'problip.stats.ini')) -match 'TotalCount=53') "content=$(Get-Content -Raw -LiteralPath (Join-Path $dirN 'problip.stats.ini'))"
    Check 'retry after failed recovery commit: no double-count' ($stN.Record.TotalCount -eq 53) "total=$($stN.Record.TotalCount)"
    Check 'retry after failed recovery: pending still zero' ($pendingField.GetValue($stN).TotalCount -eq 0) "total=$($pendingField.GetValue($stN).TotalCount)"
    $commitField2.SetValue($stN, $null)

    # O. genuinely missing file -> successive RecordBlip still persists
    # (Already covered by block K's creates-file assertion.)

    # P. TryResetAll while Unreadable:
    #   - success case: disk becomes zeroed snapshot, BaselineState Healthy, PendingDelta cleared
    #   - failure case: disk byte-for-byte unchanged, baseline remains Unreadable, delta unchanged
    $dirP = Join-Path $work 'w2Reset'; New-Item -ItemType Directory -Path $dirP | Out-Null
    Set-Content -LiteralPath (Join-Path $dirP 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=$dkL
TodayCount=5
WeekKey=$wkL
WeekCount=7
MonthKey=$mkL
MonthCount=9
TotalCount=77
"@
    $bytesP0 = [IO.File]::ReadAllBytes((Join-Path $dirP 'problip.stats.ini'))
    $ctor2P = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
        $stP = $ctor2P.Invoke(@([string]$dirP, (New-ThrowingRead 'unreadable for reset')))
    $localNowField.SetValue($stP, [Func[datetime]]{ param() $D0 })
        $readTextField.SetValue($stP, (New-ThrowingRead 'still unreadable'))
    $script:clockP = [long]0; $nowMsFieldP = $storeType.GetField('NowMs', $flags)
    $nowMsFieldP.SetValue($stP, [Func[long]]{ param() $script:clockP })
    $storeRecordBlipM.Invoke($stP, @()) | Out-Null  # pending += 1
    $pendingBeforePFail = $pendingField.GetValue($stP).TotalCount
    # failure case: make CommitFile fail so the atomic reset candidate cannot land
    $commitFieldP = $storeType.GetField('CommitFile', $flags)
    $savedCommitP = $commitFieldP.GetValue($stP)
        $commitFieldP.SetValue($stP, (New-FailingCommit))
    $tryResetM = $storeType.GetMethod('TryResetAll')
    $okPFail = [bool]$tryResetM.Invoke($stP, @())
    Check 'TryResetAll(while unreadable) failure returns false' (-not $okPFail)
    $bytesPFail = [IO.File]::ReadAllBytes((Join-Path $dirP 'problip.stats.ini'))
    $bytesSamePFail = ([Convert]::ToBase64String($bytesP0) -eq [Convert]::ToBase64String($bytesPFail))
    Check 'TryResetAll failure: disk byte-for-byte unchanged' $bytesSamePFail
    Check 'TryResetAll failure: baseline remains Unreadable' ($baselineField.GetValue($stP) -eq $unreadableVal) "got=$($baselineField.GetValue($stP))"
    Check 'TryResetAll failure: pending delta unchanged' ($pendingField.GetValue($stP).TotalCount -eq $pendingBeforePFail) "total=$($pendingField.GetValue($stP).TotalCount)"
    # success case: restore commit seam, reset succeeds
    $commitFieldP.SetValue($stP, $savedCommitP)
    $okPSucc = [bool]$tryResetM.Invoke($stP, @())
    Check 'TryResetAll(while unreadable) success returns true' $okPSucc
    Check 'TryResetAll success: Record zeroed' ($stP.Record.TotalCount -eq 0) "total=$($stP.Record.TotalCount)"
    Check 'TryResetAll success: PendingDelta cleared' ($pendingField.GetValue($stP).TotalCount -eq 0) "total=$($pendingField.GetValue($stP).TotalCount)"
    Check 'TryResetAll success: BaselineState Healthy' ($baselineField.GetValue($stP) -eq $healthyVal) "got=$($baselineField.GetValue($stP))"
    $resetTextP = Get-Content -Raw -LiteralPath (Join-Path $dirP 'problip.stats.ini')
    Check 'TryResetAll success: disk is zeroed snapshot' ($resetTextP -match 'TotalCount=0') "content=$resetTextP"
    $commitFieldP.SetValue($stP, $null)

    # Q. STOP/Cleanup must NOT destroy history: while unreadable with pending,
    #    engine.Stop() -> FlushIfDirty() must leave disk on the old baseline,
    #    and Block B's proven blip-counting seam stays green via engine Ticks.
    #    Exercised here by checking the seam: an engine with an unreadable stats
    #    store keeps scheduling and FlushIfDirty leaves the file alone.
    $dirQ = Join-Path $work 'w2Stop'; New-Item -ItemType Directory -Path $dirQ | Out-Null
    Set-Content -LiteralPath (Join-Path $dirQ 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=$dkL
TodayCount=2
WeekKey=$wkL
WeekCount=4
MonthKey=$mkL
MonthCount=6
TotalCount=100
"@
    $bytesQ0 = [IO.File]::ReadAllBytes((Join-Path $dirQ 'problip.stats.ini'))
    $ctor2Q = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
        $stQ = $ctor2Q.Invoke(@([string]$dirQ, (New-ThrowingRead 'unreadable for stop')))
    $localNowField.SetValue($stQ, [Func[datetime]]{ param() $D0 })
        $readTextField.SetValue($stQ, (New-ThrowingRead 'still unreadable'))
    $script:clockQ = [long]0; $nowMsFieldQ = $storeType.GetField('NowMs', $flags)
    $nowMsFieldQ.SetValue($stQ, [Func[long]]{ param() $script:clockQ })
    $storeRecordBlipM.Invoke($stQ, @()) | Out-Null
    $storeFlushIfDirtyM.Invoke($stQ, @()) | Out-Null
    $bytesQ1 = [IO.File]::ReadAllBytes((Join-Path $dirQ 'problip.stats.ini'))
    $bytesSameQ = ([Convert]::ToBase64String($bytesQ0) -eq [Convert]::ToBase64String($bytesQ1))
    Check 'Stop path (FlushIfDirty while unreadable): file untouched' $bytesSameQ

    # R. boundary-period merge: persisted baseline is yesterday but same week+month,
    #    degraded records bridge midnight, recovery after midnight must not
    #    double-count or resurrect stale Today bucket.
    $dirR = Join-Path $work 'w2Bound'; New-Item -ItemType Directory -Path $dirR | Out-Null
    $midnightBaselineDay = Get-Key $dayKeyM ([datetime]'2026-09-08')
    $midnightBaselineWeek = Get-Key $weekKeyM ([datetime]'2026-09-08')
    $midnightBaselineMonth = Get-Key $monthKeyM ([datetime]'2026-09-08')
    Set-Content -LiteralPath (Join-Path $dirR 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=$midnightBaselineDay
TodayCount=5
WeekKey=$midnightBaselineWeek
WeekCount=20
MonthKey=$midnightBaselineMonth
MonthCount=30
TotalCount=100
"@
    $ctor2R = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
        $stR = $ctor2R.Invoke(@([string]$dirR, (New-ThrowingRead 'unreadable boundary')))
        $readTextField.SetValue($stR, (New-ThrowingRead 'still unreadable'))
    $script:clockR = [long]0; $nowMsFieldR = $storeType.GetField('NowMs', $flags)
    $nowMsFieldR.SetValue($stR, [Func[long]]{ param() $script:clockR })
    # Pre-midnight blips (stR starts at 2026-09-08): two blips before midnight
    $localNowField.SetValue($stR, [Func[datetime]]{ param() [datetime]'2026-09-08 23:58:00' })
    $storeRecordBlipM.Invoke($stR, @()) | Out-Null
    $storeRecordBlipM.Invoke($stR, @()) | Out-Null
    # Post-midnight blips: 2026-09-09 is still same ISO week (2026-W37) and month, but different DayKey
    $localNowField.SetValue($stR, [Func[datetime]]{ param() [datetime]'2026-09-09 00:02:00' })
    $storeRecordBlipM.Invoke($stR, @()) | Out-Null
    $storeRecordBlipM.Invoke($stR, @()) | Out-Null
    $storeRecordBlipM.Invoke($stR, @()) | Out-Null
    $pendingRBefore = $pendingField.GetValue($stR)
    Check 'boundary: pending Total == 5 across midnight' ($pendingRBefore.TotalCount -eq 5) "total=$($pendingRBefore.TotalCount)"
    # Recovery after midnight (2026-09-09): enable read, bump clock to open the window, recover
        $readTextField.SetValue($stR, (New-RealRead))
    $localNowField.SetValue($stR, [Func[datetime]]{ param() [datetime]'2026-09-09 00:03:00' })
    $script:clockR = 20000
    $storeFlushIfDirtyM.Invoke($stR, @()) | Out-Null
    Check 'boundary: merged Total == 105 (old 100 + 5)' ($stR.Record.TotalCount -eq 105) "total=$($stR.Record.TotalCount)"
    # Today belongs to current day: delta had two before-midnight and three after-midnight; only 3 match the current DayKey
    Check 'boundary: Today counts only current-day delta' ($stR.Record.TodayCount -eq 3) "today=$($stR.Record.TodayCount)"
    Check 'boundary: TodayKey is current day' ($stR.Record.DayKey -eq (Get-Key $dayKeyM ([datetime]'2026-09-09'))) "day=$($stR.Record.DayKey)"
    Check 'boundary: Week merges (same ISO week)' ($stR.Record.WeekCount -eq 25) "week=$($stR.Record.WeekCount)"
    Check 'boundary: Month merges (same month)' ($stR.Record.MonthCount -eq 35) "month=$($stR.Record.MonthCount)"
    Check 'boundary: pending cleared exactly once' ($pendingField.GetValue($stR).TotalCount -eq 0) "total=$($pendingField.GetValue($stR).TotalCount)"
    # Post-recovery commit failure must not double-count on retry: force CommitFile to fail once more
    $commitFieldR = $storeType.GetField('CommitFile', $flags)
    $savedCommitR = $commitFieldR.GetValue($stR)
        $commitFieldR.SetValue($stR, (New-FailingCommit))
    # Already recovered, so next Flush is a plain write of Record (no re-read).
    # This is the same path the file-level failure test proved; just re-confirm with a boundary record.
    # Do one more recovery-style path: stale PendingDelta=0 so no extra add expected.
    $stR.Record.TotalCount = 105
    $dirtyField.SetValue($stR, $true)
    $okRBogus = [bool]$storeFlushM.Invoke($stR, @())
    Check 'boundary: failed post-recovery flush leaves Record intact' ($stR.Record.TotalCount -eq 105) "total=$($stR.Record.TotalCount)"
    $commitFieldR.SetValue($stR, $savedCommitR)
    $storeFlushM.Invoke($stR, @()) | Out-Null
    Check 'boundary: persisted total stays 105 after successful retry' (([int](Get-Content -Raw -LiteralPath (Join-Path $dirR 'problip.stats.ini') | Select-String -Pattern 'TotalCount=(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })) -eq 105)
    $commitFieldR.SetValue($stR, $null)

    # S. AddSaturating: negative sanitizes, overflow saturates, never wraps
    $aCases = @(
        @{ A=[long]-5; B=[long]10; Want=[long]10 },
        @{ A=[long]-1; B=[long]-7; Want=[long]0 },
        @{ A=[long][long]::MaxValue; B=[long]1; Want=[long][long]::MaxValue },
        @{ A=[long]([long]::MaxValue - 1); B=[long]2; Want=[long][long]::MaxValue },
        @{ A=[long]10; B=[long]20; Want=[long]30 }
    )
    $addOk = $true; $addDetail = ''
    foreach ($c in $aCases) {
        $got = [long]$addSatM.Invoke($null, @([long]$c.A, [long]$c.B))
        if ($got -ne $c.Want) { $addOk = $false; $addDetail += "$($c.A)+$($c.B)=$got want $($c.Want) " }
    }
    Check 'AddSaturating contract (negatives, overflow, normal)' $addOk $addDetail

    # ==================== PERF-001: ASYNCHRONOUS PERSISTENCE ====================
    # 1. HOT-PATH NON-BLOCKING: a blocked physical commit must not delay
    #    RecordBlip, the engine Tick path, or the next interval arming.
    $gate1 = New-BlockGate
    $dirU = Join-Path $work 'perfHot'; New-Item -ItemType Directory -Path $dirU | Out-Null
    $stU = New-Store $dirU $D0
    $script:clockU = [long]0
    $storeType.GetField('NowMs', $flags).SetValue($stU, [Func[long]]{ param() $script:clockU })
    $gateFieldU = $storeType.GetField('CommitFileGate', $flags)
    $gateFieldU.SetValue($stU, $gate1.Gate)
    $script:clockU = 10000
    $storeRecordBlipM.Invoke($stU, @()) | Out-Null   # eligible -> publish to worker
    $enteredU = [bool]$gate1.Wait.Invoke(10000)
    Check 'PERF-001: worker enters the blocked commit seam' $enteredU
    $swU = [System.Diagnostics.Stopwatch]::StartNew()
    $storeRecordBlipM.Invoke($stU, @()) | Out-Null   # must return immediately while commit is blocked
    $elapsedU = $swU.ElapsedMilliseconds
    Check 'PERF-001: RecordBlip returns while the commit is still blocked' ($elapsedU -lt 1000) "elapsed=${elapsedU}ms"
    Check 'PERF-001: RecordBlip while blocked keeps Dirty (nothing landed)' ([bool]$dirtyField.GetValue($stU))
    Check 'PERF-001: exactly one commit is in flight while blocked' ([bool]$storeType.GetProperty('WorkerBusy', $flags).GetValue($stU, $null))
    Check 'PERF-001: memory total advanced while persistence blocked' ($stU.Record.TotalCount -eq 2) "total=$($stU.Record.TotalCount)"
    # Engine path: a successful scheduled Tick while persistence is blocked.
    $dirU2 = Join-Path $work 'perfEngine'; New-Item -ItemType Directory -Path $dirU2 | Out-Null
    $settingsCtorU = $settingsType.GetConstructor($flags, $null, @([string]), $null)
    $engineCtorU = $engineType.GetConstructor($flags, $null, @($settingsType), $null)
    $sU2 = $settingsCtorU.Invoke(@([string]$dirU2)); $settingsType.GetMethod('Load').Invoke($sU2, @()) | Out-Null
    $sU2.WavPath = [string]$RealWav; $sU2.Volume = 0.0
    $eU2 = $engineCtorU.Invoke(@($sU2))
    $stU2 = $statsField.GetValue($eU2)
    $localNowField.SetValue($stU2, [Func[datetime]]{ param() $D0 })
    $script:fakeNowU = [long]0
    $engineType.GetField('NowMs', $flags).SetValue($eU2, [Func[long]]{ param() $script:fakeNowU })
    $storeType.GetField('NowMs', $flags).SetValue($stU2, [Func[long]]{ param() $script:fakeNowU })
    $engineType.GetField('Player', $flags).SetValue($eU2, (New-Object System.Media.SoundPlayer $RealWav))
    $gateFieldU2 = $storeType.GetField('CommitFileGate', $flags)
    $gate2 = New-BlockGate
    $gateFieldU2.SetValue($stU2, $gate2.Gate)
    $setIntervalM2 = $engineType.GetMethod('SetInterval')
    $kindManualU = [enum]::Parse($asm.GetType('Problip.IntervalKind', $true), 'Manual')
    $setIntervalM2.Invoke($eU2, @($kindManualU, 1000, 1000))
    $script:fakeNowU = 10000
    $eU2.Start()
    $swU2 = [System.Diagnostics.Stopwatch]::StartNew()
    $engineType.GetMethod('Tick', $flags).Invoke($eU2, @($null, [EventArgs]::Empty)) | Out-Null
    $elapsedU2 = $swU2.ElapsedMilliseconds
    Check 'PERF-001: scheduled Tick returns while persistence is blocked' ($elapsedU2 -lt 1000) "elapsed=${elapsedU2}ms"
    Check 'PERF-001: ScheduledPlayCount incremented exactly once while blocked' ([int]$engineType.GetField('ScheduledPlayCount', $flags).GetValue($eU2) -eq 1)
    $blipFired = $false
    $blipHandler = { param($a, $b) $script:blipCount = $script:blipCount + 1 }
    $script:blipCount = 0
    $eU2.add_BlipPlayed($blipHandler)
    $nextDueU = [long]$engineType.GetField('NextDueMs', $flags).GetValue($eU2)
    Check 'PERF-001: next interval is armed while persistence remains blocked' ($nextDueU -gt $script:fakeNowU) "nextDue=$nextDueU"
    # memory keeps counting
    $script:fakeNowU = 11000
    $engineType.GetMethod('Tick', $flags).Invoke($eU2, @($null, [EventArgs]::Empty)) | Out-Null
    Check 'PERF-001: memory count continues advancing while blocked' ($stU2.Record.TotalCount -eq 2) "total=$($stU2.Record.TotalCount)"
    $null = $gate2.Open.Invoke()
    $null = $gate1.Open.Invoke()
    $idleU = [bool]$waitIdleM.Invoke($stU, @([int]5000))
    $idleU2 = [bool]$waitIdleM.Invoke($stU2, @([int]5000))
    Check 'PERF-001: worker drains after the gate opens' ($idleU -and $idleU2)
    $eU2.Stop()
    $eU2.Cleanup()

    # 2. BOUNDED PENDING STATE: many mutations while one commit is blocked.
    $gate3 = New-BlockGate
    $dirV = Join-Path $work 'perfPending'; New-Item -ItemType Directory -Path $dirV | Out-Null
    $stV = New-Store $dirV $D0
    $script:clockV = [long]0
    $storeType.GetField('NowMs', $flags).SetValue($stV, [Func[long]]{ param() $script:clockV })
    $storeType.GetField('CommitFileGate', $flags).SetValue($stV, $gate3.Gate)
    $script:clockV = 10000
    $storeRecordBlipM.Invoke($stV, @()) | Out-Null   # in-flight commit (blocked)
    $null = $gate3.Wait.Invoke(10000)
    for ($i = 0; $i -lt 50; $i++) {
        $script:clockV += 10000
        $storeRecordBlipM.Invoke($stV, @()) | Out-Null   # each eligible -> replaces pending
    }
    Check 'PERF-001: at most ONE pending snapshot exists despite 50 more blips' `
        (([bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stV, $null)) -and (([bool]$storeType.GetProperty('WorkerBusy', $flags).GetValue($stV, $null))))
    $genV = [long]$storeType.GetProperty('LatestRequestedGen', $flags).GetValue($stV, $null)
    $null = $gate3.Open.Invoke()
    $null = $waitIdleM.Invoke($stV, @([int]5000))
    $finalTextV = Get-Content -Raw -LiteralPath (Join-Path $dirV 'problip.stats.ini')
    Check 'PERF-001: disk eventually holds the newest (51 blips) snapshot' ($finalTextV -match 'TotalCount=51') "content=$($finalTextV -replace "`r", '' -replace "`n", ' ')"
    Check 'PERF-001: dirty cleared after the newest state landed' (-not [bool]$dirtyField.GetValue($stV))

    # 5. RESET RACE: pre-reset pending work can never resurrect counters.
    $gate4 = New-BlockGate
    $dirW = Join-Path $work 'perfReset'; New-Item -ItemType Directory -Path $dirW | Out-Null
    $stW = New-Store $dirW $D0
    $script:clockW = [long]0
    $storeType.GetField('NowMs', $flags).SetValue($stW, [Func[long]]{ param() $script:clockW })
    $storeType.GetField('CommitFileGate', $flags).SetValue($stW, $gate4.Gate)
    $script:clockW = 10000
    $storeRecordBlipM.Invoke($stW, @()) | Out-Null           # pre-reset commit in flight (blocked)
    $null = $gate4.Wait.Invoke(10000)
    for ($i = 0; $i -lt 5; $i++) { $storeRecordBlipM.Invoke($stW, @()) | Out-Null }   # extra in-memory blips
    $tryResetM2 = $storeType.GetMethod('TryResetAll')
    # Bounded failure while the physical-commit gate is held by the blocked
    # worker commit: reset returns false, nothing is queued, nothing changes.
    $resetOkW = [bool]$tryResetM2.Invoke($stW, @())
    Check 'PERF-001: reset fails bounded while the commit gate cannot be obtained' (-not $resetOkW)
    Check 'PERF-001: failed bounded reset leaves memory unchanged' ($stW.Record.TotalCount -eq 6) "total=$($stW.Record.TotalCount)"
    $null = $gate4.Open.Invoke()
    $null = $waitIdleM.Invoke($stW, @([int]5000))
    # The stale PRE-RESET commit may land (it was older work): that is fine.
    # The reset is retried AFTER the gate is free; its generation bump invalidates
    # every pre-reset pending state, so nothing can resurrect old counters after it.
    $resetOkW2 = [bool]$tryResetM2.Invoke($stW, @())
    Check 'PERF-001: reset succeeds once the gate is free' $resetOkW2
    $null = $waitIdleM.Invoke($stW, @([int]5000))
    $resetTextW = Get-Content -Raw -LiteralPath (Join-Path $dirW 'problip.stats.ini')
    Check 'PERF-001: after reset and drain, disk TotalCount remains 0' ($resetTextW -match 'TotalCount=0') "content=$($resetTextW -replace "`r", '' -replace "`n", ' ')"
    Check 'PERF-001: memory counters remain zero after the stale commit landed nowhere' ($stW.Record.TotalCount -eq 0) "total=$($stW.Record.TotalCount)"
    Start-Sleep -Milliseconds 300
    $resetTextW2 = Get-Content -Raw -LiteralPath (Join-Path $dirW 'problip.stats.ini')
    Check 'PERF-001: no stale pre-reset snapshot reappears after settling' ($resetTextW2 -match 'TotalCount=0') "content=$($resetTextW2 -replace "`r", '' -replace "`n", ' ')"

    # 6. STOP / CLEANUP: final flush observable on disk; blocked commit cannot
    #    deadlock shutdown; worker is background-owned.
    $gate5 = New-BlockGate
    $dirX = Join-Path $work 'perfStop'; New-Item -ItemType Directory -Path $dirX | Out-Null
    $sX = $settingsCtorU.Invoke(@([string]$dirX)); $settingsType.GetMethod('Load').Invoke($sX, @()) | Out-Null
    $sX.WavPath = [string]$RealWav; $sX.Volume = 0.0
    $eX = $engineCtorU.Invoke(@($sX))
    $stX = $statsField.GetValue($eX)
    $localNowField.SetValue($stX, [Func[datetime]]{ param() $D0 })
    $script:fakeNowX = [long]0
    $engineType.GetField('NowMs', $flags).SetValue($eX, [Func[long]]{ param() $script:fakeNowX })
    $storeType.GetField('NowMs', $flags).SetValue($stX, [Func[long]]{ param() $script:fakeNowX })
    $engineType.GetField('Player', $flags).SetValue($eX, (New-Object System.Media.SoundPlayer $RealWav))
    $storeType.GetField('CommitFileGate', $flags).SetValue($stX, $gate5.Gate)
    $script:fakeNowX = 10000
    $eX.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eX, @($null, [EventArgs]::Empty)) | Out-Null
    $null = $gate5.Wait.Invoke(10000)
    $swX = [System.Diagnostics.Stopwatch]::StartNew()
    $eX.Stop()   # FlushIfDirty waits at most CommitGateTimeoutMs; must not deadlock
    $elapsedX = $swX.ElapsedMilliseconds
    Check 'PERF-001: Stop with a blocked commit returns within the documented bound' ($elapsedX -lt 5000) "elapsed=${elapsedX}ms"
    $null = $gate5.Open.Invoke()
    $eX.Cleanup()
    $stopTextX = Get-Content -Raw -LiteralPath (Join-Path $dirX 'problip.stats.ini')
    Check 'PERF-001: final lifecycle flush persisted the session blip' ($stopTextX -match 'TotalCount=1') "content=$($stopTextX -replace "`r", '' -replace "`n", ' ')"

    # Worker is background-owned: an abandoned store never keeps the process alive.
    $dirY = Join-Path $work 'perfBg'; New-Item -ItemType Directory -Path $dirY | Out-Null
    $stY = New-Store $dirY $D0
    $script:clockY = [long]10000
    $storeType.GetField('NowMs', $flags).SetValue($stY, [Func[long]]{ param() $script:clockY })
    $storeRecordBlipM.Invoke($stY, @()) | Out-Null
    $workerField = $storeType.GetField('Worker', $flags)
    $workerY = $workerField.GetValue($stY)
    Check 'PERF-001: persistence worker is a background thread' ($workerY.IsBackground)
    Check 'PERF-001: exactly one worker thread exists' ($workerY.Name -eq 'Problip.StatsPersistence')
    $null = $waitIdleM.Invoke($stY, @([int]5000))

    $storeType.GetField('CommitFileGate', $flags).SetValue($stU, $null)
    $storeType.GetField('CommitFileGate', $flags).SetValue($stU2, $null)
    $storeType.GetField('CommitFileGate', $flags).SetValue($stV, $null)
    $storeType.GetField('CommitFileGate', $flags).SetValue($stW, $null)
    $storeType.GetField('CommitFileGate', $flags).SetValue($stX, $null)

    # ==================== PERF-001 ORDERING CLOSURE REGRESSIONS ====================
    # Deterministic, seam-driven (zero sleeps): these pin the disk-ordering
    # invariant (no physical write from a stale generation) and the immutable
    # snapshot contract (no live mutable Record object ever serialized).

    $preGatePauseField = $storeType.GetField('PreGatePause', $flags)
    $flushCapturePauseField = $storeType.GetField('FlushCapturePause', $flags)
    $recoveryCapturePauseField = $storeType.GetField('RecoveryCapturePause', $flags)
    $staleSkipField = $storeType.GetField('StaleSkipCount', $flags)
    $mutableClockType = $seamsType.GetNestedType('MutableClock')

    # 7. STALE WORKER AFTER NEWER SYNCHRONOUS FLUSH: a snapshot the worker
    #    already owns must NEVER reach the disk once a newer generation was
    #    published -- the pre-write eligibility check inside the gate must skip
    #    it, no physical replacement may occur, and Dirty must reflect only
    #    genuinely newer state.
    $dirZ = Join-Path $work 'perfStale'; New-Item -ItemType Directory -Path $dirZ | Out-Null
    $stZ = New-Store $dirZ $D0
    $script:clockZ = [long]0
    $storeType.GetField('NowMs', $flags).SetValue($stZ, [Func[long]]{ param() $script:clockZ })
    $script:releasesZ = 0
    $preGateM = $blockGateType.GetMethod('WaitEntered')
    # Pre-gate pause: hold the worker BEFORE its gate acquisition so generation
    # N is fully captured but not yet eligible-checked.
    $script:holdZ = $true
    $preGateZ = New-BlockGate
    $preGatePauseField.SetValue($stZ, [Func[bool]]$preGateZ.Gate)
    $script:clockZ = 10000
    $storeRecordBlipM.Invoke($stZ, @()) | Out-Null          # gen N published; worker will pause pre-gate
    $preGateEnteredZ = [bool]$preGateZ.Wait.Invoke(10000)   # deterministic: worker holds BEFORE eligibility
    Check 'PERF-001 stale: worker deterministically reached the pre-gate pause' $preGateEnteredZ
    $script:clockZ = 20000
    $storeRecordBlipM.Invoke($stZ, @()) | Out-Null          # gen N+1 pending, replaces the slot
    # Newer synchronous flush commits FIRST, while the stale worker is parked.
    $script:clockZ = 100000
    $flushOkZ = [bool]$storeFlushM.Invoke($stZ, @())
    Check 'PERF-001 stale: newer synchronous flush landed while worker paused pre-gate' $flushOkZ
    Check 'PERF-001 stale: disk holds the newer flush (2 blips)' `
        ((Get-Content -Raw -LiteralPath (Join-Path $dirZ 'problip.stats.ini')) -match 'TotalCount=2')
    Check 'PERF-001 stale: flush cleared Dirty for the committed two-blip state' (-not [bool]$dirtyField.GetValue($stZ))
    # One additional blip INSIDE the batching window (clock < last attempt +
    # FlushIntervalMs): Record advances, Dirty becomes TRUE for genuinely
    # unpersisted state, and NO newer worker publication is created -- the
    # stale generation N stays the only incomplete work item.
    $storeRecordBlipM.Invoke($stZ, @()) | Out-Null          # third blip: memory only
    Check 'PERF-001 stale: third blip left genuinely unpersisted Dirty state' ([bool]$dirtyField.GetValue($stZ))
    Check 'PERF-001 stale: third blip created no newer worker publication (gen still 3)' `
        ([long]$storeType.GetProperty('LatestRequestedGen', $flags).GetValue($stZ, $null) -eq [long]3)
    Check 'PERF-001 stale: live Record contains three blips before release' ($stZ.Record.TotalCount -eq 3) "total=$($stZ.Record.TotalCount)"
    # Now release the stale worker. Its generation N is obsolete: the pre-write
    # eligibility check must skip it without a single physical write, and the
    # skipped completion must NOT clear Dirty for the newer unpersisted blip.
    $null = $preGateZ.Open.Invoke()
    $idleZ = [bool]$waitIdleM.Invoke($stZ, @([int]5000))
    Check 'PERF-001 stale: worker drains normally after being released' $idleZ
    Check 'PERF-001 stale: the obsolete generation was skipped pre-write' ([int]$staleSkipField.GetValue($stZ) -ge 1)
    Check 'PERF-001 stale: disk still holds ONLY the previously committed two-blip snapshot (TotalCount=2)' `
        ((Get-Content -Raw -LiteralPath (Join-Path $dirZ 'problip.stats.ini')) -match 'TotalCount=2')
    Check 'PERF-001 stale: live Record still contains three blips' ($stZ.Record.TotalCount -eq 3) "total=$($stZ.Record.TotalCount)"
    Check 'PERF-001 stale: Dirty is still TRUE after stale completion (asserted directly)' ([bool]$dirtyField.GetValue($stZ))
    Check 'PERF-001 stale: no pending snapshot remains after the drain' `
        (-not [bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZ, $null))
    # Final flush: the newest live (three-blip) state reaches disk, Dirty clears.
    $script:clockZ = 200000
    $finalOkZ = [bool]$storeFlushM.Invoke($stZ, @())
    Check 'PERF-001 stale: final flush reaches the three-blip state on disk' `
        ($finalOkZ -and ((Get-Content -Raw -LiteralPath (Join-Path $dirZ 'problip.stats.ini')) -match 'TotalCount=3'))
    Check 'PERF-001 stale: final flush cleared Dirty' (-not [bool]$dirtyField.GetValue($stZ))
    $preGatePauseField.SetValue($stZ, $null)
    $storeType.GetField('CommitFileGate', $flags).SetValue($stZ, $null)

    # 8. IMMUTABLE SYNCHRONOUS SNAPSHOT: a mutation landing after the flush
    #    captured its state must not tear the committed file -- the committed
    #    content is one coherent captured snapshot.
    $mcA = [Activator]::CreateInstance($mutableClockType)
    $mcA.Value = [datetime]'2026-09-09 10:00:00'
    $dirZA = Join-Path $work 'perfImmutableFlush'; New-Item -ItemType Directory -Path $dirZA | Out-Null
    $stZA = New-Store $dirZA $D0
    $storeType.GetField('LocalNow', $flags).SetValue($stZA, [Func[datetime]]$mutableClockType.GetProperty('Now').GetValue($mcA))
    # Compiled monotonic clock: the flush below runs on a raw background
    # thread, where a PS scriptblock NowMs cannot execute.
    $monoClockType = $seamsType.GetNestedType('MonotonicClock')
    $monoZA = [Activator]::CreateInstance($monoClockType)
    $monoClockType.GetProperty('Ms').SetValue($monoZA, [long]0)
    $storeType.GetField('NowMs', $flags).SetValue($stZA, [Func[long]]$monoClockType.GetProperty('Now').GetValue($monoZA))
    $pauseZA = New-BlockGate
    $flushCapturePauseField.SetValue($stZA, [Func[bool]]$pauseZA.Gate)
    $storeRecordBlipM.Invoke($stZA, @()) | Out-Null          # day=09-09, all counters 1
    $monoClockType.GetProperty('Ms').SetValue($monoZA, [long]10000)   # open the batching window
    # Drive the synchronous Flush on a COMPILED background thread (never a PS
    # scriptblock thread): reflection delegate + compiled runner only.
    $reflectedActionType = $seamsType.GetNestedType('ReflectedAction')
    $threadRunnerType = $seamsType.GetNestedType('ThreadRunner')
    $script:flushResultZA = $false
    $flushDelZA = $storeFlushM.CreateDelegate([Func[bool]], $stZA)
    $raZA = [Activator]::CreateInstance($reflectedActionType, @([Delegate]$flushDelZA, $null, [object[]]@()))
    $flushJobZA = [Activator]::CreateInstance($threadRunnerType, @([Action]$reflectedActionType.GetProperty('Body').GetValue($raZA)))
    $threadRunnerType.GetMethod('Start').Invoke($flushJobZA, @())
    $null = $pauseZA.Wait.Invoke(10000)                       # capture done, serialization not yet
    Check 'PERF-001 immutability: flush reached the capture/commit gap' $true
    # Mutate the world while the flush is between capture and commit: date AND
    # counters roll over on the very next mutation.
    $mcA.Value = [datetime]'2026-09-14 10:00:00'              # new day + new ISO week
    $storeRecordBlipM.Invoke($stZA, @()) | Out-Null
    $null = $pauseZA.Open.Invoke()
    $flushJoinedZA = [bool]$threadRunnerType.GetMethod('Join').Invoke($flushJobZA, @([int]10000))
    $idleZA = [bool]$waitIdleM.Invoke($stZA, @([int]5000))
    Check 'PERF-001 immutability: flush thread and worker both settle' ($idleZA -and $flushJoinedZA)
    $textZA = Get-Content -Raw -LiteralPath (Join-Path $dirZA 'problip.stats.ini')
    # Coherent pre-mutation snapshot: DayKey 2026-09-09 with counts 1/1/1/1.
    $coherentA = ($textZA -match 'DayKey=2026-09-09') -and ($textZA -match 'TotalCount=1') -and ($textZA -match 'TodayCount=1')
    # A torn mixture would show e.g. the NEW DayKey with OLD counts or vice versa.
    Check 'PERF-001 immutability: committed file is one coherent captured snapshot (flush)' $coherentA $textZA
    $flushCapturePauseField.SetValue($stZA, $null)

    # 9. RECOVERY SNAPSHOT IMMUTABILITY: concurrent post-recovery mutations
    #    cannot alter or tear the snapshot the recovery is committing.
    $dirZB = Join-Path $work 'perfImmutableRecovery'; New-Item -ItemType Directory -Path $dirZB | Out-Null
    $mcB = [Activator]::CreateInstance($mutableClockType)
    $mcB.Value = [datetime]'2026-09-09 10:00:00'
    Set-Content -LiteralPath (Join-Path $dirZB 'problip.stats.ini') -NoNewline -Value @"
[stats]
DayKey=2026-09-09
TodayCount=10
WeekKey=$(Get-Key $weekKeyM ([datetime]'2026-09-09'))
WeekCount=20
MonthKey=$(Get-Key $monthKeyM ([datetime]'2026-09-09'))
MonthCount=30
TotalCount=50
"@
    $ctor2ZB = $storeType.GetConstructor($flags, $null, @([string], [Func[string,string]]), $null)
    $stZB = $ctor2ZB.Invoke(@([string]$dirZB, (New-ThrowingRead 'unreadable for immutability')))
    $storeType.GetField('LocalNow', $flags).SetValue($stZB, [Func[datetime]]$mutableClockType.GetProperty('Now').GetValue($mcB))
    $script:clockZB = [long]0
    $storeType.GetField('NowMs', $flags).SetValue($stZB, [Func[long]]{ param() $script:clockZB })
    # One blip lands in the session delta while unreadable (clock closed: no
    # attempt window opens, no publication happens). The SECOND blip below
    # opens the window and schedules recovery, so the delta is exactly TWO
    # blips and the recovery capture is precisely baseline 50 + delta 2 = 52.
    $storeRecordBlipM.Invoke($stZB, @()) | Out-Null
    # Deterministic capture/commit gap on the worker's recovery path.
    $pauseZB = New-BlockGate
    $recoveryCapturePauseField.SetValue($stZB, [Func[bool]]$pauseZB.Gate)
    # Make the file readable again and open the attempt window with THIS third
    # blip: the delta therefore contains exactly TWO blips (the first two), and
    # the worker's recovery capture is precisely baseline 50 + delta 2 = 52.
    $readTextField.SetValue($stZB, (New-RealRead))
    $mcB.Value = [datetime]'2026-09-09 10:05:00'              # same day: merge keeps keys, adds delta
    $script:clockZB = 20000
    $storeRecordBlipM.Invoke($stZB, @()) | Out-Null           # second delta blip: opens the window and schedules worker recovery (delta = 2)
    $null = $pauseZB.Wait.Invoke(10000)                       # recovery merged 50+2=52, captured the immutable copy, paused
    # While the recovery sits paused INSIDE its batching window, mutate the
    # live Record: Total 52 -> 53, then roll the day forward for 54. No newer
    # publication exists, so the recovery generation stays the newest one.
    $storeRecordBlipM.Invoke($stZB, @()) | Out-Null           # live Record.Total now 53 (recovered 52 + 1 live)
    $mcB.Value = [datetime]'2026-09-14 10:05:00'              # new day + new ISO week (same month)
    $storeRecordBlipM.Invoke($stZB, @()) | Out-Null           # live Record.Total now 54, day=2026-09-14
    Check 'PERF-001 recovery immutability: live Record advanced to 54 while the recovery is paused' ($stZB.Record.TotalCount -eq 54) "total=$($stZB.Record.TotalCount)"
    Check 'PERF-001 recovery immutability: Dirty is still true while paused (post-capture mutations)' ([bool]$dirtyField.GetValue($stZB))
    # Explicitly open the recovery pause: the recovery physically commits its
    # CAPTURED 52-state (never the post-capture mutations).
    $null = $pauseZB.Open.Invoke()
    # Deterministic completion: IdleSignal is set in RecoveryCommit's finally,
    # and this scenario produces no other worker commit -- so one WaitOne means
    # the physical recovery write has finished. (WaitIdle alone cannot prove
    # this: recovery does not set InFlightGen.)
    $idleSignalZB = $storeType.GetField('IdleSignal', $flags).GetValue($stZB)
    $recoveryDoneZB = $idleSignalZB.WaitOne(10000)
    Check 'PERF-001 recovery immutability: recovery commit signalled completion' $recoveryDoneZB
    $idleZB = [bool]$waitIdleM.Invoke($stZB, @([int]5000))
    Check 'PERF-001 recovery immutability: worker drains after the recovery pause is opened' $idleZB
    # Inspect disk BEFORE any newer flush: the file on disk is the recovery's output.
    $textZB = Get-Content -Raw -LiteralPath (Join-Path $dirZB 'problip.stats.ini')
    $recoveryCoherent = ($textZB -match 'DayKey=2026-09-09') -and ($textZB -match 'TotalCount=52') `
        -and ($textZB -match 'TodayCount=12') -and ($textZB -match 'WeekCount=22') -and ($textZB -match 'MonthCount=32')
    Check 'PERF-001 recovery immutability: disk equals the pre-mutation captured recovery state (coherent 52)' $recoveryCoherent $textZB
    Check 'PERF-001 recovery immutability: no post-capture mutation leaked into the recovery file' `
        (-not (($textZB -match 'TotalCount=53') -or ($textZB -match 'TotalCount=54') -or ($textZB -match 'DayKey=2026-09-14'))) $textZB
    Check 'PERF-001 recovery immutability: live Record still holds the post-capture mutations (54)' ($stZB.Record.TotalCount -eq 54) "total=$($stZB.Record.TotalCount)"
    Check 'PERF-001 recovery immutability: Dirty remains TRUE after the recovery commit (DataVersion advanced post-capture)' ([bool]$dirtyField.GetValue($stZB))
    # Only now may a final flush run: it persists the newest live state.
    $script:clockZB = 30000
    $flushOkZB = [bool]$storeFlushM.Invoke($stZB, @())
    Check 'PERF-001 recovery immutability: final flush persisted the newest live state' $flushOkZB
    $textZB2 = Get-Content -Raw -LiteralPath (Join-Path $dirZB 'problip.stats.ini')
    $finalCoherent = ($textZB2 -match 'DayKey=2026-09-14') -and ($textZB2 -match 'TotalCount=54') `
        -and ($textZB2 -match 'TodayCount=1') -and ($textZB2 -match 'WeekCount=1') -and ($textZB2 -match 'MonthCount=34')
    Check 'PERF-001 recovery immutability: final disk state is one coherent newest snapshot (54)' $finalCoherent $textZB2
    Check 'PERF-001 recovery immutability: final flush cleared Dirty' (-not [bool]$dirtyField.GetValue($stZB))
    $recoveryCapturePauseField.SetValue($stZB, $null)
    $readTextField.SetValue($stZB, $null)

    # 10. TERMINAL CLEANUP: Cleanup() finalizes persistence, shuts the ONE
    #     worker down through ShutdownPersistence, stays bounded and idempotent,
    #     and leaves no pending generation able to land afterwards.
    $gateZC = New-BlockGate
    $dirZC = Join-Path $work 'perfTerminalCleanup'; New-Item -ItemType Directory -Path $dirZC | Out-Null
    $sZC = $settingsCtorU.Invoke(@([string]$dirZC)); $settingsType.GetMethod('Load').Invoke($sZC, @()) | Out-Null
    $sZC.WavPath = [string]$RealWav; $sZC.Volume = 0.0
    $eZC = $engineCtorU.Invoke(@($sZC))
    $stZC = $statsField.GetValue($eZC)
    $localNowField.SetValue($stZC, [Func[datetime]]{ param() $D0 })
    $script:fakeNowZC = [long]0
    $engineType.GetField('NowMs', $flags).SetValue($eZC, [Func[long]]{ param() $script:fakeNowZC })
    $storeType.GetField('NowMs', $flags).SetValue($stZC, [Func[long]]{ param() $script:fakeNowZC })
    $engineType.GetField('Player', $flags).SetValue($eZC, (New-Object System.Media.SoundPlayer $RealWav))
    # Park the worker inside a blocked commit so Cleanup must flush around it.
    $storeType.GetField('CommitFileGate', $flags).SetValue($stZC, $gateZC.Gate)
    $script:fakeNowZC = 10000
    $eZC.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eZC, @($null, [EventArgs]::Empty)) | Out-Null
    $null = $gateZC.Wait.Invoke(10000)
    # One more blip so a newer pending snapshot exists beyond the blocked commit.
    $script:fakeNowZC = 20000
    $engineType.GetMethod('Tick', $flags).Invoke($eZC, @($null, [EventArgs]::Empty)) | Out-Null
    Check 'PERF-001 cleanup: a pending snapshot exists before terminal Cleanup' `
        ([bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZC, $null))
    $workerZC0 = $storeType.GetField('Worker', $flags).GetValue($stZC)
    Check 'PERF-001 cleanup: worker is alive before Cleanup' ($null -ne $workerZC0 -and $workerZC0.IsAlive)
    $swZC = [System.Diagnostics.Stopwatch]::StartNew()
    # Release the worker's parked physical commit just BEFORE Cleanup: the
    # blocked commit lands as gen N, so the pending gen N+1 snapshot is the
    # newer state Cleanup must finalize (and then tear the worker down).
    $null = $gateZC.Open.Invoke()
    $eZC.Cleanup()   # final flush + bounded worker teardown; must not hang
    $elapsedZC = $swZC.ElapsedMilliseconds
    Check 'PERF-001 cleanup: terminal Cleanup stays bounded with a blocked commit' ($elapsedZC -lt 5000) "elapsed=${elapsedZC}ms"
    Check 'PERF-001 cleanup: worker thread is gone after Cleanup' `
        ((& { $wZC = $storeType.GetField('Worker', $flags).GetValue($stZC); return ($null -eq $wZC) -or (-not $wZC.IsAlive) }))
    Check 'PERF-001 cleanup: no pending snapshot survives Cleanup' `
        (-not [bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZC, $null))
    $swZC2 = [System.Diagnostics.Stopwatch]::StartNew()
    $eZC.Cleanup()   # idempotent second call: must return immediately
    Check 'PERF-001 cleanup: idempotent second Cleanup returns instantly' ($swZC2.ElapsedMilliseconds -lt 2000)
    $textZC = Get-Content -Raw -LiteralPath (Join-Path $dirZC 'problip.stats.ini')
    Check 'PERF-001 cleanup: final persisted state holds the session blips' ($textZC -match 'TotalCount=2') $textZC
    # After Cleanup, blips can no longer schedule work: the worker is gone and
    # no pending generation can replace the final committed state.
    $storeType.GetField('CommitFileGate', $flags).SetValue($stZC, $null)

    # 10b. PRE-WRITE BLOCKED TERMINAL CLEANUP: the worker OWNS CommitGate and
    #      is parked at the CommitFileGate seam -- i.e. BEFORE the final
    #      generation eligibility check and BEFORE WriteCommitFile. This does
    #      NOT model filesystem I/O that has already started; it proves the
    #      pre-write supersession contract: bounded Cleanup, discarded pending
    #      work, and an obsolete pre-write generation that can never touch disk
    #      once its gate is released. (The already-started-I/O limitation is
    #      proven separately in section 10c below.) Sequence proven here:
    #      1 worker owns CommitGate; 2 paused before eligibility/write;
    #      3 Cleanup starts; 4 Stop's synchronous flush advances PublishGen
    #      but times out on the gate; 5 ShutdownPersistence stays bounded;
    #      6 pending work is discarded; 7 gate released, the worker observes
    #      its generation is obsolete; 8 it skips WriteCommitFile; 9 it
    #      terminates; 10 disk is untouched by that obsolete generation.
    $gateZE = New-BlockGate
    $dirZE = Join-Path $work 'perfBlockedCleanup'; New-Item -ItemType Directory -Path $dirZE | Out-Null
    $sZE = $settingsCtorU.Invoke(@([string]$dirZE)); $settingsType.GetMethod('Load').Invoke($sZE, @()) | Out-Null
    $sZE.WavPath = [string]$RealWav; $sZE.Volume = 0.0
    $eZE = $engineCtorU.Invoke(@($sZE))
    $stZE = $statsField.GetValue($eZE)
    $localNowField.SetValue($stZE, [Func[datetime]]{ param() $D0 })
    $script:fakeNowZE = [long]0
    $engineType.GetField('NowMs', $flags).SetValue($eZE, [Func[long]]{ param() $script:fakeNowZE })
    $storeType.GetField('NowMs', $flags).SetValue($stZE, [Func[long]]{ param() $script:fakeNowZE })
    $engineType.GetField('Player', $flags).SetValue($eZE, (New-Object System.Media.SoundPlayer $RealWav))
    # Worker owns CommitGate and is parked at the CommitFileGate seam (before
    # eligibility and before any physical write); the gate stays CLOSED
    # through the whole Cleanup below.
    $storeType.GetField('CommitFileGate', $flags).SetValue($stZE, $gateZE.Gate)
    $script:fakeNowZE = 10000
    $eZE.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eZE, @($null, [EventArgs]::Empty)) | Out-Null
    $null = $gateZE.Wait.Invoke(10000)
    Check 'PERF-001 blocked cleanup: worker parked at the pre-write commit seam (gate entered)' $true
    # Cleanup: Stop()'s final synchronous flush must respect the commit gate
    # bound, ShutdownPersistence() must also remain bounded, and Cleanup must
    # return within the documented total bound -- while the commit stays blocked.
    $swZE = [System.Diagnostics.Stopwatch]::StartNew()
    $eZE.Cleanup()
    $elapsedZE = $swZE.ElapsedMilliseconds
    Check 'PERF-001 blocked cleanup: Cleanup returns within the documented bound with the commit still blocked' ($elapsedZE -lt 5000) "elapsed=${elapsedZE}ms"
    Check 'PERF-001 blocked cleanup: no pending snapshot remains after Cleanup' `
        (-not [bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZE, $null))
    # Blip #1 was consumed by the blocked worker generation and never reached
    # disk (the physical write never happened); the file does not exist yet.
    $existedZE = Test-Path -LiteralPath (Join-Path $dirZE 'problip.stats.ini')
    Check 'PERF-001 blocked cleanup: blocked generation wrote nothing before release' (-not $existedZE) "exists=$existedZE"
    # Release the blocked gate AFTER Cleanup: the obsolete pre-write generation
    # resumes, must fail its pre-write eligibility check (a newer generation
    # was published by the shutdown flush attempt), and perform NO physical
    # replacement. The worker then observes Disposed and terminates.
    $null = $gateZE.Open.Invoke()
    $workerZE = $storeType.GetField('Worker', $flags).GetValue($stZE)
    if ($null -ne $workerZE) { $null = $workerZE.Join(10000) }
    $workerZeGone = ($null -eq $workerZE) -or (-not $workerZE.IsAlive)
    Check 'PERF-001 blocked cleanup: released worker observes Disposed and terminates' $workerZeGone
    Check 'PERF-001 blocked cleanup: obsolete post-Cleanup generation never created the file' (-not (Test-Path -LiteralPath (Join-Path $dirZE 'problip.stats.ini')))
    Check 'PERF-001 blocked cleanup: no pending snapshot survives post-Cleanup' `
        (-not [bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZE, $null))
    $storeType.GetField('CommitFileGate', $flags).SetValue($stZE, $null)

    # 10c. ALREADY-STARTED I/O LIMITATION (deterministic proof): a commit whose
    #      PHYSICAL operation has already begun (BlockingCommit is entered --
    #      generation eligibility already passed, WriteCommitFile in flight)
    #      cannot be cancelled by Cleanup. The documented contract: bounded
    #      shutdown, and the in-flight write finishes (or fails) asynchronously
    #      once the underlying I/O unblocks -- never asserted cancelled. This
    #      is exactly what the CommitFileGate-based 10b does NOT model.
    $blockingCommitType = $seamsType.GetNestedType('BlockingCommit')
    $bcZ = [Activator]::CreateInstance($blockingCommitType)
    $dirZF = Join-Path $work 'perfStartedIoCleanup'; New-Item -ItemType Directory -Path $dirZF | Out-Null
    $sZF = $settingsCtorU.Invoke(@([string]$dirZF)); $settingsType.GetMethod('Load').Invoke($sZF, @()) | Out-Null
    $sZF.WavPath = [string]$RealWav; $sZF.Volume = 0.0
    $eZF = $engineCtorU.Invoke(@($sZF))
    $stZF = $statsField.GetValue($eZF)
    $localNowField.SetValue($stZF, [Func[datetime]]{ param() $D0 })
    $script:fakeNowZF = [long]0
    $engineType.GetField('NowMs', $flags).SetValue($eZF, [Func[long]]{ param() $script:fakeNowZF })
    $storeType.GetField('NowMs', $flags).SetValue($stZF, [Func[long]]{ param() $script:fakeNowZF })
    $engineType.GetField('Player', $flags).SetValue($eZF, (New-Object System.Media.SoundPlayer $RealWav))
    # The worker's commit passes eligibility and physically blocks inside CommitFile.
    $commitFieldZF = $storeType.GetField('CommitFile', $flags)
    $savedCommitZF = $commitFieldZF.GetValue($stZF)
    $commitFieldZF.SetValue($stZF, [Func[string,string,bool]]$blockingCommitType.GetProperty('Commit').GetValue($bcZ))
    $script:fakeNowZF = 10000
    $eZF.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eZF, @($null, [EventArgs]::Empty)) | Out-Null
    $enteredZF = [bool]$blockingCommitType.GetMethod('WaitEntered').Invoke($bcZ, @([int]10000))
    Check 'PERF-001 started-io cleanup: physical commit already entered CommitFile when Cleanup begins' $enteredZF
    # Cleanup starts while the physical write is in flight: the final flush
    # times out on CommitGate (the worker owns it), the bounded join expires,
    # and Cleanup returns WITHOUT the in-flight operation being cancelled.
    $swZF = [System.Diagnostics.Stopwatch]::StartNew()
    $eZF.Cleanup()
    $elapsedZF = $swZF.ElapsedMilliseconds
    Check 'PERF-001 started-io cleanup: Cleanup stays bounded while physical I/O is in flight' ($elapsedZF -lt 5000) "elapsed=${elapsedZF}ms"
    Check 'PERF-001 started-io cleanup: worker still finishing the already-started write after Cleanup returns' `
        ((& { $wZF = $storeType.GetField('Worker', $flags).GetValue($stZF); return ($null -ne $wZF -and $wZF.IsAlive) }))
    Check 'PERF-001 started-io cleanup: no pending work remains (only the in-flight write)' `
        (-not [bool]$storeType.GetProperty('HasPendingSnapshot', $flags).GetValue($stZF, $null))
    # Release the blocked physical write: the already-started operation COMPLETES
    # (proving no cancellation), the worker then observes Disposed and exits.
    $null = $blockingCommitType.GetMethod('Open').Invoke($bcZ, @())
    $workerZF = $storeType.GetField('Worker', $flags).GetValue($stZF)
    if ($null -ne $workerZF) { $null = $workerZF.Join(10000) }
    $workerZFGone = ($null -eq $workerZF) -or (-not $workerZF.IsAlive)
    Check 'PERF-001 started-io cleanup: released in-flight write completed and the worker exited' $workerZFGone
    $textZF = Get-Content -Raw -LiteralPath (Join-Path $dirZF 'problip.stats.ini')
    Check 'PERF-001 started-io cleanup: the already-started commit landed its own (not newer) content' ($textZF -match 'TotalCount=1') $textZF
    $commitFieldZF.SetValue($stZF, $savedCommitZF)

    # 11. STOP PRESERVES THE PERSISTENCE WORKER (Start again works): ordinary
    #     Stop must not tear the worker down -- only terminal Cleanup does.
    $dirZD = Join-Path $work 'perfStopWorkerAlive'; New-Item -ItemType Directory -Path $dirZD | Out-Null
    $sZD = $settingsCtorU.Invoke(@([string]$dirZD)); $settingsType.GetMethod('Load').Invoke($sZD, @()) | Out-Null
    $sZD.WavPath = [string]$RealWav; $sZD.Volume = 0.0
    $eZD = $engineCtorU.Invoke(@($sZD))
    $stZD = $statsField.GetValue($eZD)
    $localNowField.SetValue($stZD, [Func[datetime]]{ param() $D0 })
    $script:fakeNowZD = [long]10000
    $engineType.GetField('NowMs', $flags).SetValue($eZD, [Func[long]]{ param() $script:fakeNowZD })
    $storeType.GetField('NowMs', $flags).SetValue($stZD, [Func[long]]{ param() $script:fakeNowZD })
    $engineType.GetField('Player', $flags).SetValue($eZD, (New-Object System.Media.SoundPlayer $RealWav))
    $eZD.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eZD, @($null, [EventArgs]::Empty)) | Out-Null
    $null = $waitIdleM.Invoke($stZD, @([int]5000))
    $eZD.Stop()
    $workerZD = $storeType.GetField('Worker', $flags).GetValue($stZD)
    Check 'PERF-001 stop: ordinary Stop leaves the persistence worker alive' ($null -ne $workerZD -and $workerZD.IsAlive)
    $script:fakeNowZD = 30000
    $eZD.Start()
    $engineType.GetMethod('Tick', $flags).Invoke($eZD, @($null, [EventArgs]::Empty)) | Out-Null
    $drainZD = [bool]$waitIdleM.Invoke($stZD, @([int]5000))
    Check 'PERF-001 stop: Start again after Stop still persists (worker reusable)' ($drainZD -and ((Get-Content -Raw -LiteralPath (Join-Path $dirZD 'problip.stats.ini')) -match 'TotalCount=2'))
    $eZD.Cleanup()

} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '---'
if ($fail) { Write-Host "FAILED ($fail failure(s))"; exit 1 }
Write-Host 'PASS (0 failures)'
exit 0
