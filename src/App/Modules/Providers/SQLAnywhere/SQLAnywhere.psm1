Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Core/Process.psm1')
Import-Module (Join-Path $PSScriptRoot '../../Core/Runtime.psm1')

function Read-DBSqlConnection {
    param([string] $Path)
    $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
    # One connection option only; no nested response files, output redirects,
    # server-side backup, log rotation, truncation, or arbitrary utility flags.
    if ($text -notmatch '\A-c\s+"([^"\r\n]+)"\z') { throw 'SQL options must contain exactly -c "<connection>" on one line.' }
    $builder = [Data.Common.DbConnectionStringBuilder]::new()
    try { $builder.set_ConnectionString($Matches[1]) }
    catch { throw 'SQL connection string could not be parsed.' }
    $values = @{}
    foreach ($key in $builder.Keys) {
        if ($key.ToUpperInvariant() -notin @('UID','PWD','HOST','DBN','SERVER','ENG','CHARSET')) { throw "Unsupported SQL connection parameter: $key" }
        $value = [string] $builder[$key]
        if ($value -match '["\r\n]') { throw 'SQL connection values cannot contain double quotes or newlines.' }
        $values[$key.ToUpperInvariant()] = $value
    }
    foreach ($key in @('UID','PWD','DBN')) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($values[$key])) { throw "SQL connection parameter is required: $key" }
    }
    # HOST for TCP/IP; SERVER (or its alias ENG) alone for a local server
    # reached through shared memory.
    if (-not @('HOST','SERVER','ENG' | Where-Object { $values.ContainsKey($_) -and -not [string]::IsNullOrWhiteSpace($values[$_]) }).Count) {
        throw 'SQL connection requires HOST or SERVER (ENG).'
    }
    return $values
}

function ConvertTo-DBSqlConnection {
    param([Collections.IDictionary] $Values)
    return (($Values.Keys | Sort-Object | ForEach-Object {
        '{0}=''{1}''' -f $_, ([string] $Values[$_]).Replace("'", "''")
    }) -join ';')
}

function Write-DBSqlOption {
    param([string] $Path, [Collections.IDictionary] $Values)
    $connection = ConvertTo-DBSqlConnection $Values
    # Quote the response-file argument using the Windows command-line rules.
    $quoted = '"' + [regex]::Replace($connection, '(\\*)"', '$1$1\"') + '"'
    [IO.File]::WriteAllText($Path, "-c $quoted", [Text.UTF8Encoding]::new($false))
}

function ConvertTo-DBSafeToolOutput {
    <# Native output for diagnostics: the password is removed literally and by pattern, then truncated. #>
    param([AllowNull()][string] $Text, [AllowNull()][string] $Secret, [int] $MaxLength = 2000)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if (-not [string]::IsNullOrEmpty($Secret)) { $Text = $Text.Replace($Secret, '[REDACTED]') }
    $Text = (Protect-DBMessage $Text).Trim()
    if ($Text.Length -gt $MaxLength) { $Text = $Text.Substring(0, $MaxLength) + '...' }
    return $Text
}

function Get-DBSqlAnywhereSizeEstimate {
    <#
    Best-effort size of the database file (FileSize pages x PageSize) read with
    dbping -d -pd FileSize,PageSize. Used only on the first run of a job, before
    the capacity history exists. Returns $null when dbping is absent, fails or
    its output is not understood; the run then checks only ReserveBytes.
    #>
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    if ($null -eq $Runtime) { return $null }
    $dbping = Join-Path (Split-Path -Parent $Configuration.Tools.DbBackup) 'dbping.exe'
    if (-not (Test-Path -LiteralPath $dbping -PathType Leaf)) { return $null }
    $connection = Read-DBSqlConnection $Job.CredentialFile
    # Never start a database just to measure it.
    $connection.ASTART = 'NO'
    # Transient credentials live in the private Work directory of this run.
    $options = Join-Path $Runtime.Work "dbping-$([guid]::NewGuid().ToString('N')).options"
    try {
        Write-DBSqlOption $options $connection
        $probe = Invoke-DBTool -Executable $dbping -Arguments @('-d', '-pd', 'FileSize,PageSize', "@$options") -TimeoutSeconds 60
        if ($probe.ExitCode -ne 0) { return $null }
        $text = "$($probe.StdOut)`n$($probe.StdErr)"
        $pages = [regex]::Match($text, '(?im)\bFileSize\b[^\d\r\n]*(\d+)')
        $pageSize = [regex]::Match($text, '(?im)\bPageSize\b[^\d\r\n]*(\d+)')
        if (-not $pages.Success -or -not $pageSize.Success) { return $null }
        return [long] $pages.Groups[1].Value * [long] $pageSize.Groups[1].Value
    }
    finally { if (Test-Path -LiteralPath $options) { Remove-Item -LiteralPath $options -Force } }
}

function Get-DBSqlAnywhereLogDirectory {
    <#
    Folder of the production transaction log (dbping -d -pd LogName), where
    dbbackup -r leaves the renamed logs (AAMMDDxx.log). $null when unknown.
    #>
    param([Collections.IDictionary] $Configuration, [string] $OptionsPath)
    $folder = [IO.Path]::GetDirectoryName([string] $Configuration.Tools.DbBackup)
    if (-not $folder) { return $null }
    $dbping = Join-Path $folder 'dbping.exe'
    if (-not (Test-Path -LiteralPath $dbping -PathType Leaf)) { return $null }
    try {
        $probe = Invoke-DBTool -Executable $dbping -Arguments @('-d', '-pd', 'LogName', "@$OptionsPath") -TimeoutSeconds 60
        if ($probe.ExitCode -ne 0) { return $null }
        # Localized table ("Banco de dados   LogName   C:\Dados\contabil.log") or "LogName: <path>".
        $match = [regex]::Match([string] $probe.StdOut, '(?im)\bLogName\b[\s:=]+(?<path>(?:[A-Za-z]:|\\\\)[^\r\n]*?\.log)\s*$')
        if (-not $match.Success) { return $null }
        $path = $match.Groups['path'].Value
        return $path.Substring(0, $path.LastIndexOfAny([char[]] @('\', '/')))
    }
    catch { return $null }
}

function ConvertFrom-DBTranOutput {
    <#
    Start and end offsets of a transaction log read from the dbtran messages,
    in any language: the line that ends the log ("...ends at offset N",
    "...termina no deslocamento N") gives End; the first other line ending in
    an offset gives Start. Offsets are digit strings without leading zeros.
    $null when the output is not understood.
    #>
    param([AllowNull()][string] $Text)
    $start = $null
    $end = $null
    foreach ($line in ([string] $Text) -split '\r?\n') {
        # A space before the number: GUIDs (-000000000000), versions and times never match.
        $match = [regex]::Match($line, '\s(?<n>\d{6,})\s*\.?\s*$')
        if (-not $match.Success) { continue }
        $value = $match.Groups['n'].Value.TrimStart('0')
        if (-not $value) { $value = '0' }
        if ($line -match '(?i)\b(ends?|termina|finaliza)\b') { $end = $value }
        elseif ($line -match '(?i)relativ') { continue }
        elseif ($null -eq $start) { $start = $value }
    }
    if ($null -eq $start -or $null -eq $end -or [decimal] $start -gt [decimal] $end) { return $null }
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Read-DBSqlAnywhereLogOffset {
    <#
    Offsets of a transaction log COPIED to Work (never the production one),
    read with dbtran. The translated SQL holds data: it goes to the private
    folder of the run and is deleted right away. Throws when unreadable.
    #>
    param([string] $DbTran, [string] $LogPath, [string] $PrivateDirectory, [double] $TimeoutSeconds = 3600)
    $sql = Join-Path $PrivateDirectory "dbtran-$([guid]::NewGuid().ToString('N')).sql"
    try {
        $run = Invoke-DBTool -Executable $DbTran -Arguments @('-y', $LogPath, $sql) -TimeoutSeconds $TimeoutSeconds
        if ($run.ExitCode -ne 0) { throw "dbtran failed (exit $($run.ExitCode)). $(ConvertTo-DBSafeToolOutput -Text "$($run.StdOut) $($run.StdErr)" -MaxLength 500)".Trim() }
        $offsets = ConvertFrom-DBTranOutput "$($run.StdOut)`n$($run.StdErr)"
        if ($null -eq $offsets) { throw 'dbtran output not understood (log start and end offsets).' }
        return $offsets
    }
    finally { if (Test-Path -LiteralPath $sql) { Remove-Item -LiteralPath $sql -Force } }
}

function Invoke-DBSqlAnywhere {
    <#
    Mode Full: database and log (dbbackup). For a job with Incremental.Enabled
    the full also renames and restarts the production log (-r), so it becomes
    the base of the day's incrementals. Mode Incremental: only the current
    log (-t, no rename): cumulative since the base full. Base = state of the
    base full (BaseRunId, BaseRecoveryPointUtc, LogEndOffset) given by the runner.
    Log chain (2.4, needs dbtran.exe beside dbbackup.exe): the full records
    where its copied log ends; the incremental checks that its copied log
    starts there. Another offset means a backup outside DBBackup truncated or
    renamed the production log: the copy is discarded and Status is
    CHAIN_BROKEN (the runner takes a full right away). An unreadable log with
    a known base offset gives CHAIN_UNVERIFIED (full for safety).
    #>
    param([Collections.IDictionary] $Configuration, $Job, $Runtime, [ValidateSet('Full','Incremental')][string] $Mode = 'Full', $Base)
    $started = [DateTime]::UtcNow
    $connection = Read-DBSqlConnection $Job.CredentialFile
    if ($connection.DBN -cne $Job.Database) { throw "Job $($Job.Id): SQL DBN must match the job Database." }
    $secretRoot = Join-Path $Runtime.Work '_secrets'
    Set-DBPrivateDirectory $secretRoot
    $root = Join-Path $Runtime.Work $Job.Id
    $null = New-Item -ItemType Directory -Path $root -Force
    $backupOptions = Join-Path $secretRoot 'backup.options'
    try {
        $connection.ASTART = 'NO'
        Write-DBSqlOption $backupOptions $connection
        # Default dbbackup copies ALL files. Never -x, -xo, -n or -s; -r only
        # for the full of an incremental job, -t only for the incremental.
        $incrementalJob = [bool] ($Job.PSObject.Properties['Incremental'] -and $Job.Incremental)
        if ($Mode -eq 'Incremental' -and (-not $incrementalJob -or $null -eq $Base)) { throw "Job $($Job.Id): incremental requires Incremental.Enabled and a base full." }
        $flags = switch ($Mode) { 'Incremental' { @('-t') } default { if ($incrementalJob) { @('-r') } else { @() } } }
        $logDirectory = $null
        if ($incrementalJob) { $logDirectory = Get-DBSqlAnywhereLogDirectory -Configuration $Configuration -OptionsPath $backupOptions }
        $timeout = if ($Configuration.Contains('Execution')) { $Configuration.Execution.ToolTimeoutSeconds } else { 21600 }
        $backup = Invoke-DBTool -Executable $Configuration.Tools.DbBackup -Arguments (@("@$backupOptions") + $flags + @($root)) -TimeoutSeconds $timeout
        if ($backup.ExitCode -ne 0) {
            $detail = ConvertTo-DBSafeToolOutput -Text ("$($backup.StdOut) $($backup.StdErr)") -Secret $connection.PWD
            throw "SQL Anywhere backup failed (exit $($backup.ExitCode)). $detail".Trim()
        }
        # The main database plus any dbspaces are .db files; at least one log.
        $dbs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.db')
        $logs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.log')
        if ($Mode -eq 'Incremental') {
            if ($logs.Count -lt 1 -or $dbs.Count -gt 0) { throw 'Expected only the transaction .log in the incremental backup.' }
        }
        elseif ($dbs.Count -lt 1 -or $logs.Count -lt 1) { throw 'Expected at least one .db and one transaction .log in the copied backup.' }
        foreach ($file in @($dbs) + @($logs)) {
            if ($file.Length -eq 0) { throw 'SQL Anywhere produced an empty database or log file.' }
        }
        $warnings = @()
        $offsets = $null
        $offsetError = $null
        if ($incrementalJob) {
            $toolFolder = [IO.Path]::GetDirectoryName([string] $Configuration.Tools.DbBackup)
            $dbtran = if ($toolFolder) { Join-Path $toolFolder 'dbtran.exe' } else { $null }
            if (-not $dbtran -or -not (Test-Path -LiteralPath $dbtran -PathType Leaf)) { $warnings += "dbtran.exe not found beside dbbackup.exe: log chain not verified." }
            elseif ($logs.Count -ne 1) { $warnings += "$($logs.Count) logs copied: log chain not verified." }
            else {
                try { $offsets = Read-DBSqlAnywhereLogOffset -DbTran $dbtran -LogPath $logs[0].FullName -PrivateDirectory $secretRoot -TimeoutSeconds $timeout }
                catch { $offsetError = Protect-DBMessage $_.Exception.Message }
            }
        }
        $chain = 'UNVERIFIED'
        if ($Mode -eq 'Incremental') {
            $expected = if ($Base.PSObject.Properties['LogEndOffset'] -and $Base.LogEndOffset) { ([string] $Base.LogEndOffset).TrimStart('0') } else { $null }
            if ($null -ne $expected -and -not $expected) { $expected = '0' }
            if (-not $expected) { $warnings += 'Base full without log offset (taken before 2.4 or without dbtran): log chain not verified until the next full.' }
            elseif ($null -ne $offsets -and $offsets.Start -cne $expected) {
                # The copy would not apply on top of the base: never publish it.
                Remove-Item -LiteralPath $root -Recurse -Force
                return [pscustomobject]@{
                    Status = 'CHAIN_BROKEN'; Packages = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
                    Errors = @("Log chain restarted outside DBBackup: base $($Base.BaseRunId) ends at offset $expected, current log starts at $($offsets.Start). The incremental was discarded.")
                    Metadata = @{ ExpectedLogStartOffset = $expected; FoundLogStartOffset = $offsets.Start }
                }
            }
            elseif ($null -ne $offsets) { $chain = 'VERIFIED' }
            elseif ($offsetError) {
                Remove-Item -LiteralPath $root -Recurse -Force
                return [pscustomobject]@{
                    Status = 'CHAIN_UNVERIFIED'; Packages = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
                    Errors = @("Log chain could not be checked ($offsetError). The incremental was discarded.")
                    Metadata = @{ ExpectedLogStartOffset = $expected }
                }
            }
        }
        elseif ($offsetError) { $warnings += "Log end offset not read ($offsetError): the incrementals of this base will not be verified." }
        $metadata = @{
            Strategy = $(if ($Mode -eq 'Incremental') { 'native-cumulative-transaction-log' } else { 'native-full-database-and-log' }); Database = $Job.Database
            Kind = $(if ($Mode -eq 'Incremental') { 'INCREMENTAL' } else { 'FULL' })
            Validation = 'native-exit-code-and-nonempty-files'; RecoveryValidation = 'external-not-performed'
            ProductionLogRename = ($Mode -eq 'Full' -and $incrementalJob); ProductionLogTruncate = $false
            DatabaseFiles = @($dbs | ForEach-Object Name); LogFiles = @($logs | ForEach-Object Name)
        }
        if ($logDirectory) { $metadata.ProductionLogDirectory = $logDirectory }
        if ($Mode -eq 'Incremental') { $metadata.BaseRunId = [string] $Base.BaseRunId; $metadata.BaseRecoveryPointUtc = [string] $Base.BaseRecoveryPointUtc; $metadata.LogChain = $chain }
        if ($null -ne $offsets) { $metadata.LogStartOffset = $offsets.Start; $metadata.LogEndOffset = $offsets.End }
        [pscustomobject]@{
            Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = $metadata.Kind; SourcePath = $root; ContentsOnly = $true })
            Errors = $warnings; StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
            Metadata = $metadata
        }
    }
    finally {
        # Removes the credential file and its private directory; a run killed
        # before this point is cleaned by the next run (Clear-DBStaleRuntime).
        if (Test-Path -LiteralPath $secretRoot) { Remove-Item -LiteralPath $secretRoot -Recurse -Force -ErrorAction Stop }
    }
}
Export-ModuleMember -Function ConvertFrom-DBTranOutput, Read-DBSqlAnywhereLogOffset, Get-DBSqlAnywhereLogDirectory, Read-DBSqlConnection, Write-DBSqlOption, ConvertTo-DBSafeToolOutput, Get-DBSqlAnywhereSizeEstimate, Invoke-DBSqlAnywhere
