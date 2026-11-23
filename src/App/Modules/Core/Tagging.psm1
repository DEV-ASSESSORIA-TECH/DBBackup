Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')

<#
Retention tags of the S3 objects (2.3). Optional, per instance:

    Storage = @{ ...; Tagging = @{ Key = 'retencao'; Default = 'padrao'; Special = @('mensal'); Jobs = @('Database') } }

Every full (non-incremental) object of a tagged job goes up with one tag
<Key>=<value>: the longest special period enabled (anual > mensal > semanal >
diario) whose current period has no confirmed object yet, otherwise Default.
A special object also covers the shorter enabled periods of the same moment
(the first full of the year is also that month's, week's and day's).
Incrementals and run logs are never tagged (their prefixes have their own
lifecycle rules). Without Storage.Tagging nothing is tagged.
The periods already covered live in <Runtime>\Tagging\<job>.json and advance
only when the object is confirmed in S3: a failed upload never leaves the
period without its special copy (at worst there are two).
#>

$script:TagPeriods = @('anual', 'mensal', 'semanal', 'diario')

function Get-DBTagPeriodKey {
    <# Identifier of the period that contains the local time, e.g. mensal -> 2026-11, semanal -> 2026-W48 (ISO week). #>
    param([string] $Period, [DateTime] $LocalTime)
    switch ($Period) {
        'anual' { return $LocalTime.ToString('yyyy', [Globalization.CultureInfo]::InvariantCulture) }
        'mensal' { return $LocalTime.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture) }
        'semanal' { return '{0}-W{1:00}' -f [Globalization.ISOWeek]::GetYear($LocalTime), [Globalization.ISOWeek]::GetWeekOfYear($LocalTime) }
        'diario' { return $LocalTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    }
    throw "Unknown tag period: $Period"
}

function Get-DBTagStatePath {
    param([Collections.IDictionary] $Configuration, [string] $Job)
    return Join-Path (Join-Path $Configuration.Paths.RuntimeRoot 'Tagging') "$Job.json"
}

function Read-DBTagState {
    <# Periods already covered by a confirmed special object, as a hashtable period -> key. #>
    param([Collections.IDictionary] $Configuration, [string] $Job)
    $path = Get-DBTagStatePath $Configuration $Job
    $periods = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $periods }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($state.SchemaVersion -ne 1 -or $state.Instance -cne $Configuration.InstanceName -or $state.Job -cne $Job) { throw 'Tagging state ownership mismatch.' }
    foreach ($property in $state.Periods.PSObject.Properties) { $periods[$property.Name] = [string] $property.Value }
    return $periods
}

function Get-DBRetentionTag {
    <#
    Tag of a full object of the job started at StartedAtUtc, or $null when the
    instance or the job does not use tags. Returns @{ Key; Value; Periods },
    Periods being what the object covers once confirmed (empty for Default).
    #>
    param([Collections.IDictionary] $Configuration, $Job, [DateTime] $StartedAtUtc)
    if (-not $Configuration.Storage.Contains('Tagging')) { return $null }
    $tagging = $Configuration.Storage.Tagging
    if (-not $tagging.Enabled) { return $null }
    if (@($tagging.Jobs).Count -and $Job.Id -cnotin @($tagging.Jobs)) { return $null }
    $local = $StartedAtUtc.ToLocalTime()
    $done = Read-DBTagState $Configuration $Job.Id
    $enabled = @($script:TagPeriods | Where-Object { $_ -in @($tagging.Special) })
    foreach ($period in $enabled) {
        $key = Get-DBTagPeriodKey $period $local
        if ($done.Contains($period) -and $done[$period] -ceq $key) { continue }
        # This object is the special copy of $period and of every shorter enabled period of the same moment.
        $covers = @{}
        foreach ($shorter in $enabled[([array]::IndexOf($enabled, $period))..($enabled.Count - 1)]) { $covers[$shorter] = Get-DBTagPeriodKey $shorter $local }
        return [pscustomobject]@{ Key = [string] $tagging.Key; Value = $period; Periods = $covers }
    }
    return [pscustomobject]@{ Key = [string] $tagging.Key; Value = [string] $tagging.Default; Periods = @{} }
}

function Save-DBTagPeriod {
    <# Records the periods covered by a confirmed special object (never moves a period backwards). #>
    param([Collections.IDictionary] $Configuration, [string] $Job, $Periods)
    $covered = @{}
    if ($Periods -is [Collections.IDictionary]) { foreach ($key in $Periods.Keys) { $covered[[string] $key] = [string] $Periods[$key] } }
    elseif ($null -ne $Periods) { foreach ($property in $Periods.PSObject.Properties) { $covered[$property.Name] = [string] $property.Value } }
    if (-not $covered.Count) { return }
    $current = Read-DBTagState $Configuration $Job
    foreach ($period in $covered.Keys) {
        if (-not $current.Contains($period) -or [string]::CompareOrdinal($covered[$period], $current[$period]) -gt 0) { $current[$period] = $covered[$period] }
    }
    $path = Get-DBTagStatePath $Configuration $Job
    Set-DBPrivateDirectory (Split-Path -Parent $path)
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{ SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job; Periods = $current } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8
        [IO.File]::Move($temp, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

Export-ModuleMember -Function Get-DBTagPeriodKey, Read-DBTagState, Get-DBRetentionTag, Save-DBTagPeriod
