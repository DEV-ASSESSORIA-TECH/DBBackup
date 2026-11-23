Set-StrictMode -Version Latest

function Protect-DBMessage {
    param([AllowNull()][string] $Message)
    if ($null -eq $Message) { return '' }
    return (($Message -replace '(?i)((?:password|pwd|secret_access_key|access_key_id)\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^;\s]+)', '$1[REDACTED]') -replace '[\r\n]+', ' ')
}

function Test-DBPrivateAccess {
    param([Parameter(Mandatory)][string] $Path)
    if (-not $IsWindows) { return $true }
    # Effective rules, inherited ones included (a child of a private instance
    # directory is private); SIDs avoid name translation of orphaned accounts.
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544')) { return $false }
    }
    return $true
}

function Set-DBPrivateDirectory {
    <#
    Default: create the directory when missing and protect only what was created;
    an existing directory is never rewritten by a backup run.
    -Enforce (setup): an existing directory must already be private or be empty.
    -Force (setup): the directory belongs to DBBackup (instance/Secrets) and is
    always made private.
    #>
    param([Parameter(Mandatory)][string] $Path, [switch] $Enforce, [switch] $Force)
    $existed = Test-Path -LiteralPath $Path
    if ($existed -and -not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Path is not a directory: $Path" }
    $null = New-Item -ItemType Directory -Path $Path -Force
    if (-not $IsWindows) { return }
    if ($existed -and -not $Force) {
        if (-not $Enforce) { return }
        if (Test-DBPrivateAccess $Path) { return }
        if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -gt 0) {
            throw "Existing directory is not private and is not empty; refusing to replace its permissions: $Path. Use a dedicated directory for DBBackup state."
        }
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-DBLogPath {
    <# Logs\<instance>\yyyy-MM-dd_HH-mm-ss.log in local time; -2, -3... if taken. #>
    param([string] $LogRoot)
    $stamp = [DateTime]::Now.ToString('yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    # The file is created here (CreateNew), so two runs starting in the same
    # second (one waiting for the other) never share a log.
    for ($n = 1; $n -lt 1000; $n++) {
        $path = if ($n -eq 1) { Join-Path $LogRoot "$stamp.log" } else { Join-Path $LogRoot "$stamp-$n.log" }
        try { [IO.File]::Open($path, 'CreateNew', 'Write', 'ReadWrite').Dispose(); return $path }
        catch [IO.IOException] { if (-not (Test-Path -LiteralPath $path)) { throw } }
    }
    throw 'Could not allocate a unique log name.'
}

function Read-DBLockHolder {
    <# Who holds the instance lock (DBBackup.lock.json, written by the holder); $null when unknown. #>
    param([string] $RuntimeRoot)
    $path = Join-Path $RuntimeRoot 'DBBackup.lock.json'
    try { if (Test-Path -LiteralPath $path -PathType Leaf) { return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } }
    catch { Write-Verbose "Lock holder unreadable: $($_.Exception.Message)" }
    return $null
}

function Format-DBLockHolder {
    param($Holder)
    if ($null -eq $Holder) { return 'outra execucao desta instancia' }
    $started = try { ([DateTime] $Holder.StartedAt).ToString('HH:mm') } catch { '?' }
    return "a execucao $($Holder.RunId) (jobs $(@($Holder.Jobs) -join ', '), modo $($Holder.Mode), iniciada $started)"
}

function New-DBRuntime {
    <#
    Takes the instance lock. When another run holds it, waits up to
    LockWaitSeconds (polling every PollSeconds) and logs the wait in this
    run's log. Returns the runtime, or an object with Busy = $true and the log
    path when the lock was not obtained in time. While waiting, the run holds
    Runtime\DBBackup.wait.<id> open, so the updater sees it as running.
    #>
    param([Collections.IDictionary] $Configuration, [double] $LockWaitSeconds = 0, [double] $PollSeconds = 30,
        [string[]] $Jobs = @(), [string] $Mode = 'Full')
    # Runtime holds plaintext work and pending bundles: private. Completed
    # (encrypted bundles) and Logs (sanitized) are operator folders and keep
    # the permissions inherited from the installation.
    Set-DBPrivateDirectory $Configuration.Paths.RuntimeRoot
    foreach ($path in @($Configuration.Paths.CompletedRoot, $Configuration.Paths.LogRoot)) { $null = New-Item -ItemType Directory -Path $path -Force }
    $runtime = $Configuration.Paths.RuntimeRoot
    foreach ($name in @('Pending', 'Work', 'Staging')) { Set-DBPrivateDirectory (Join-Path $runtime $name) }
    $id = [guid]::NewGuid().ToString('N')
    $logPath = New-DBLogPath $Configuration.Paths.LogRoot
    $lockPath = Join-Path $runtime 'DBBackup.lock'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lock = $null
    $wait = $null
    $waitPath = Join-Path $runtime "DBBackup.wait.$id"
    try {
        while ($null -eq $lock) {
            try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] {
                $holder = Read-DBLockHolder $runtime
                if ($watch.Elapsed.TotalSeconds -ge $LockWaitSeconds) {
                    if ($LockWaitSeconds -gt 0) { Write-DBLog $logPath 'Lock' "Desistindo: $(Format-DBLockHolder $holder) ocupou a instancia por mais de $([Math]::Round($LockWaitSeconds / 60)) min (Execution.LockWaitMinutes)." 'ERROR' }
                    return [pscustomobject]@{ Busy = $true; LogPath = $logPath; Holder = $holder; WaitedSeconds = $watch.Elapsed.TotalSeconds }
                }
                if ($null -eq $wait) {
                    $wait = [IO.File]::Open($waitPath, 'OpenOrCreate', 'ReadWrite', 'None')
                    Write-DBLog $logPath 'Lock' "Aguardando $(Format-DBLockHolder $holder) terminar (jobs desta execucao: $($Jobs -join ', '); espera maxima $([Math]::Round($LockWaitSeconds / 60)) min)." 'WARN'
                }
                Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Max(1, $LockWaitSeconds - $watch.Elapsed.TotalSeconds)))
            }
        }
        if ($null -ne $wait) { Write-DBLog $logPath 'Lock' "Lock obtido apos $([Math]::Round($watch.Elapsed.TotalMinutes)) min de espera." }
    }
    finally {
        if ($null -ne $wait) { $wait.Dispose(); Remove-Item -LiteralPath $waitPath -Force -ErrorAction SilentlyContinue }
    }
    $work = Join-Path $runtime "Work/$id"
    try {
        # Holder description for runs that wait (the lock itself cannot be read).
        @{ RunId = $id; Jobs = @($Jobs); Mode = $Mode; StartedAt = [DateTime]::Now.ToString('o'); ProcessId = $PID } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'DBBackup.lock.json') -Encoding utf8
        Set-DBPrivateDirectory $work
        return [pscustomobject]@{
            Busy = $false; RunId = $id; Lock = $lock; Work = $work
            Pending = Join-Path $runtime 'Pending'; Staging = Join-Path $runtime 'Staging'
            Completed = $Configuration.Paths.CompletedRoot
            LogPath = $logPath; WaitedSeconds = $watch.Elapsed.TotalSeconds
        }
    }
    catch { $lock.Dispose(); throw }
}

# Process-wide switch (like the tool deadline): the menu backup option shows each
# log line in its window; scheduled runs only write the file.
$script:ConsoleLogKey = 'DBBackup.ConsoleLog'

function Set-DBConsoleLog {
    param([bool] $Enabled)
    [AppDomain]::CurrentDomain.SetData($script:ConsoleLogKey, $Enabled)
}

function Write-DBLog {
    param([string] $Path, [string] $Stage, [string] $Message, [ValidateSet('INFO','WARN','ERROR')][string] $Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Stage, (Protect-DBMessage $Message)
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    if ([AppDomain]::CurrentDomain.GetData($script:ConsoleLogKey) -eq $true) { $line | Out-Host }
}

function Clear-DBStaleRuntime {
    <#
    Runs while the instance lock is held, so no other run of this instance can
    own Work or Staging content. Removes plaintext payloads and transient
    credentials left by interrupted runs. Only generated names are removed;
    Pending (complete encrypted bundles awaiting upload) is never touched.
    #>
    param([Parameter(Mandatory)] $Runtime)
    $removed = @()
    $skipped = @()
    $targets = @(
        @{ Root = (Split-Path -Parent $Runtime.Work); Pattern = '^[a-f0-9]{32}$' }
        # 2.0 names start with the local timestamp; DBBackup_* covers 1.x leftovers.
        @{ Root = $Runtime.Staging; Pattern = '^(DBBackup_[A-Za-z0-9_-]+|\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Za-z0-9_-]+)$' }
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target.Root -PathType Container)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $target.Root -Force -ErrorAction Stop)) {
            if ($item.FullName -eq $Runtime.Work) { continue }
            if (-not $item.PSIsContainer -or $item.Name -cnotmatch $target.Pattern -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $skipped += $item.FullName
                continue
            }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $removed += $item.FullName
        }
    }
    [pscustomobject]@{ Removed = $removed; Skipped = $skipped }
}

function Close-DBRuntime {
    param($Runtime)
    try {
        if (Test-Path -LiteralPath $Runtime.Work) {
            # Work is an exact generated GUID directory, never a configured root.
            if ((Split-Path -Leaf $Runtime.Work) -cne $Runtime.RunId -or $Runtime.RunId -notmatch '^[a-f0-9]{32}$') { throw 'Unsafe work path.' }
            Remove-Item -LiteralPath $Runtime.Work -Recurse -Force -ErrorAction Stop
        }
    }
    finally {
        $holder = Join-Path (Split-Path -Parent (Split-Path -Parent $Runtime.Work)) 'DBBackup.lock.json'
        Remove-Item -LiteralPath $holder -Force -ErrorAction SilentlyContinue
        $Runtime.Lock.Dispose()
    }
}

Export-ModuleMember -Function Read-DBLockHolder, Set-DBConsoleLog, Protect-DBMessage, Test-DBPrivateAccess, Set-DBPrivateDirectory, New-DBRuntime, Write-DBLog, Clear-DBStaleRuntime, Close-DBRuntime
