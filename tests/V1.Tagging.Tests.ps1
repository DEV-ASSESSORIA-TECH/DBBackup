BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    foreach ($name in 'Configuration', 'Runtime', 'Storage', 'Tagging') { Import-Module "$script:Repo/src/App/Modules/Core/$name.psm1" -Force }

    function New-TagConfig([hashtable] $Tagging) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory (Join-Path $root 'Runtime') -Force
        $storage = @{ ConfigPath = 'x'; Destination = 's3' }
        if ($null -ne $Tagging) { $storage.Tagging = $Tagging }
        return @{ InstanceName = 'acme'; Storage = $storage; Paths = @{ RuntimeRoot = (Join-Path $root 'Runtime') } }
    }
    $script:Job = [pscustomobject]@{ Id = 'Database' }
}

Describe 'Storage.Tagging configuration' {
    It 'is optional and validates keys, values and jobs' {
        $path = Join-Path $TestDrive 'cfg/config.psd1'
        $null = New-Item -ItemType Directory (Split-Path $path) -Force
        $text = Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME'
        Set-Content $path $text
        (Read-DBConfiguration $path).Storage.Contains('Tagging') | Should -BeFalse
        $with = { param($literal) Set-Content $path ($text.Replace("Destination = 's3' }", "Destination = 's3'; Tagging = $literal }")) }
        & $with "@{ Special = @('mensal') }"
        $t = (Read-DBConfiguration $path).Storage.Tagging
        $t.Key | Should -Be 'retencao'
        $t.Default | Should -Be 'padrao'
        $t.Enabled | Should -BeTrue
        & $with "@{ Special = @('quinzenal') }"
        { Read-DBConfiguration $path } | Should -Throw '*Special accepts*'
        & $with "@{ Default = 'mensal' }"
        { Read-DBConfiguration $path } | Should -Throw '*cannot be a special value*'
        & $with "@{ Jobs = @('nada') }"
        { Read-DBConfiguration $path } | Should -Throw '*unknown job: nada*'
        & $with "@{ Chave = 'x' }"
        { Read-DBConfiguration $path } | Should -Throw '*Unknown Storage.Tagging key*'
    }
}

Describe 'Retention tag of each full' {
    BeforeEach { Mock Set-Acl {} -ModuleName Runtime }
    It 'tags nothing without Storage.Tagging or for a job left out' {
        Get-DBRetentionTag (New-TagConfig $null) $script:Job ([DateTime]::UtcNow) | Should -BeNullOrEmpty
        Get-DBRetentionTag (New-TagConfig @{ Enabled = $true; Key = 'retencao'; Default = 'padrao'; Special = @(); Jobs = @('outro') }) $script:Job ([DateTime]::UtcNow) | Should -BeNullOrEmpty
        Get-DBRetentionTag (New-TagConfig @{ Enabled = $false; Key = 'retencao'; Default = 'padrao'; Special = @('mensal'); Jobs = @() }) $script:Job ([DateTime]::UtcNow) | Should -BeNullOrEmpty
    }
    It 'gives the first confirmed full of the month the special tag and the others the default' {
        $c = New-TagConfig @{ Enabled = $true; Key = 'retencao'; Default = 'padrao'; Special = @('mensal'); Jobs = @() }
        $first = Get-DBRetentionTag $c $script:Job ([DateTime]::new(2026, 12, 1, 22, 0, 0, [DateTimeKind]::Utc))
        "$($first.Key)=$($first.Value)" | Should -Be 'retencao=mensal'
        # Not confirmed yet (upload failed): the next full is still the monthly one.
        (Get-DBRetentionTag $c $script:Job ([DateTime]::new(2026, 12, 2, 22, 0, 0, [DateTimeKind]::Utc))).Value | Should -Be 'mensal'
        Save-DBTagPeriod $c 'Database' $first.Periods
        (Get-DBRetentionTag $c $script:Job ([DateTime]::new(2026, 12, 2, 22, 0, 0, [DateTimeKind]::Utc))).Value | Should -Be 'padrao'
        (Get-DBRetentionTag $c $script:Job ([DateTime]::new(2027, 1, 3, 22, 0, 0, [DateTimeKind]::Utc))).Value | Should -Be 'mensal'
    }
    It 'uses the longest period first and lets it cover the shorter ones' {
        $c = New-TagConfig @{ Enabled = $true; Key = 'retencao'; Default = 'padrao'; Special = @('diario', 'semanal', 'mensal', 'anual'); Jobs = @() }
        $at = [DateTime]::new(2027, 1, 5, 15, 0, 0, [DateTimeKind]::Utc)
        $tag = Get-DBRetentionTag $c $script:Job $at
        $tag.Value | Should -Be 'anual'
        @($tag.Periods.Keys | Sort-Object) | Should -Be @('anual', 'diario', 'mensal', 'semanal')
        $tag.Periods.semanal | Should -Be (Get-DBTagPeriodKey 'semanal' $at.ToLocalTime())
        Save-DBTagPeriod $c 'Database' $tag.Periods
        (Get-DBRetentionTag $c $script:Job $at.AddHours(3)).Value | Should -Be 'padrao'
        (Get-DBRetentionTag $c $script:Job $at.AddDays(1)).Value | Should -Be 'diario'
        (Get-DBRetentionTag $c $script:Job $at.AddDays(7)).Value | Should -Be 'semanal'
        (Get-DBRetentionTag $c $script:Job $at.AddDays(31)).Value | Should -Be 'mensal'
    }
    It 'names ISO weeks' {
        Get-DBTagPeriodKey 'semanal' ([DateTime]::new(2026, 11, 23)) | Should -Be '2026-W48'
        Get-DBTagPeriodKey 'semanal' ([DateTime]::new(2027, 1, 1)) | Should -Be '2026-W53'
    }
}

Describe 'Tag on upload' {
    It 'sends X-Amz-Tagging only when a tag is given and rejects unsafe tags' {
        $file = Join-Path $TestDrive 'payload.bin'
        Set-Content $file 'x' -NoNewline
        $conf = Join-Path $TestDrive 'rclone.conf'
        Set-Content $conf '[s3]'
        Mock Invoke-Rclone {
            param($Arguments)
            if ($Arguments[0] -eq 'lsjson') { return [pscustomobject]@{ ExitCode = 0; StdOut = '[{"Name":"payload.bin","Size":1}]'; StdErr = '' } }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ModuleName Storage
        $null = Send-DBBackupFile -RclonePath 'rclone.exe' -ConfigPath $conf -LocalPath $file -RemotePath 's3:b/p/payload.bin' -Tagging 'retencao=mensal'
        Should -Invoke Invoke-Rclone -ModuleName Storage -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'copyto' -and ($Arguments -join '|') -like '*|--header-upload|X-Amz-Tagging: retencao=mensal*' }
        $null = Send-DBBackupFile -RclonePath 'rclone.exe' -ConfigPath $conf -LocalPath $file -RemotePath 's3:b/p/payload.bin'
        Should -Invoke Invoke-Rclone -ModuleName Storage -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'copyto' -and $Arguments -notcontains '--header-upload' }
        { Send-DBBackupFile -RclonePath 'rclone.exe' -ConfigPath $conf -LocalPath $file -RemotePath 's3:b/p/payload.bin' -Tagging 'a=b&c=d' } | Should -Throw '*Invalid object tag*'
    }
}
