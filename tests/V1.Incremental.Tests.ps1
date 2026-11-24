BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    foreach ($name in 'Configuration','Runtime','Schedule','Artifacts','Incremental','ConfigSync') { Import-Module "$script:Repo/src/App/Modules/Core/$name.psm1" -Force }
    Import-Module "$script:Repo/src/App/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1" -Force

    function New-TestBundle {
        <# A confirmed Completed bundle of job 'dominio' with the given role and times. #>
        param([string] $Root, [string] $Name, [string] $Role, [DateTime] $RecoveryPoint, [Nullable[DateTime]] $Base, [string] $RunId = ([guid]::NewGuid().ToString('N')))
        $bundle = Join-Path $Root "dominio/$Name"
        $null = New-Item -ItemType Directory $bundle -Force
        Set-Content -LiteralPath (Join-Path $bundle "$Name.7z.age") -Value 'x' -NoNewline
        $state = @{ SchemaVersion = 1; Instance = 'acme'; Job = 'dominio'; RunId = $RunId; Role = $Role; LocalStatus = 'SUCCESS'
            RecoveryPointUtc = $RecoveryPoint.ToUniversalTime().ToString('o'); FileName = "$Name.7z.age"; SizeBytes = 1; Sha256 = 'x'
            RemotePath = "s3:b/dominio/$Name.7z.age"; Transport = 'CONFIRMED' }
        if ($null -ne $Base) { $state.BaseRecoveryPointUtc = ([DateTime] $Base).ToUniversalTime().ToString('o') }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bundle 'state.json')
        return $bundle
    }
}

Describe 'Server environment (ambiente.psd1)' {
    It 'merges built-in, environment and instance values in that order and derives dbbackup from the SQL Anywhere folder' {
        $environment = @{ SchemaVersion = 1; Tools = @{ SevenZip = 'C:\env\7z.exe'; SqlAnywhere = 'C:\Program Files\SQL Anywhere 17\Tools' }
            Retention = @{ CompletedDays = 10 }; Monitoring = @{ TextfileDirectory = 'C:\alloy' } }
        $configuration = @{ Tools = @{ SevenZip = 'C:\instance\7z.exe' }; Monitoring = @{ Enabled = $false } }
        Merge-DBEnvironment $configuration $environment
        $configuration.Tools.SevenZip | Should -Be 'C:\instance\7z.exe'
        $configuration.Tools.DbBackup | Should -Be (Join-Path 'C:\Program Files\SQL Anywhere 17\Tools' 'dbbackup.exe')
        $configuration.Tools.Contains('SqlAnywhere') | Should -BeFalse
        $configuration.Retention.CompletedDays | Should -Be 10
        $configuration.Retention.LogDays | Should -Be 30
        $configuration.Archive.CompressionLevel | Should -Be 5
        $configuration.Monitoring.TextfileDirectory | Should -Be 'C:\alloy'
    }
    It 'reads an instance without Tools when the environment beside Instances has them' {
        $root = Join-Path $TestDrive 'env'
        $instance = Join-Path $root 'Instances/acme'
        $null = New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        $text = (Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME') -replace '(?s)    Tools = @\{.*?\n    \}\n', ''
        Set-Content (Join-Path $instance 'config.psd1') $text
        Set-Content (Join-Path $root 'ambiente.psd1') "@{ SchemaVersion = 1; Tools = @{ Rclone = 'C:\env\rclone.exe'; SevenZip = 'C:\env\7z.exe'; Age = 'C:\env\age.exe'; MySql = 'C:\env\mysql.exe'; MySqlDump = 'C:\env\mysqldump.exe' } }"
        $c = Read-DBConfiguration (Join-Path $instance 'config.psd1')
        $c.Tools.Rclone | Should -Match 'rclone\.exe$'
        $c.EnvironmentPath | Should -Be (Join-Path $root 'ambiente.psd1')
    }
}

Describe 'Incremental schedule' {
    BeforeAll {
        $script:Config = @{ InstanceName = 'acme'
            Jobs = @([pscustomobject]@{ Id = 'dominio'; Incremental = $true }, [pscustomobject]@{ Id = 'seven'; Incremental = $false })
            Schedule = @{ Tasks = @(
                @{ Name = 'completo'; Jobs = @('dominio','seven'); At = '19:00' }
                @{ Name = 'incremental'; Jobs = @('dominio'); At = @('09:00','12:00','15:00','18:00'); Mode = 'Incremental' }) } }
    }
    It 'passes -Mode Incremental to the task and computes the next run per mode' {
        $tasks = @(Get-DBScheduleTask $script:Config)
        $tasks[1].Mode | Should -Be 'Incremental'
        $definition = Get-DBTaskDefinition -Task $tasks[1] -PwshPath 'pwsh.exe' -ScriptPath 'C:\DBBackup\App\Backup.ps1' -WorkingDirectory 'C:\DBBackup' -ConfigPath 'C:\DBBackup\Instances\acme\config.psd1'
        $definition.Arguments | Should -Match '-Job dominio -Mode Incremental$'
        (Get-DBTaskDefinition -Task $tasks[0] -PwshPath 'pwsh.exe' -ScriptPath 'b.ps1' -WorkingDirectory 'C:\' -ConfigPath 'c.psd1').Arguments | Should -Not -Match 'Mode'
        $after = [DateTime]::new(2026, 11, 19, 12, 30, 0)
        Get-DBScheduleNextRun -Tasks $tasks -Job 'dominio' -After $after -Mode Incremental | Should -Be ([DateTime]::new(2026, 11, 19, 15, 0, 0))
        Get-DBScheduleNextRun -Tasks $tasks -Job 'dominio' -After $after | Should -Be ([DateTime]::new(2026, 11, 19, 19, 0, 0))
    }
    It 'refuses two tasks firing in the same minute and accepts one minute apart' {
        $jobs = @([pscustomobject]@{ Id = 'database'; Incremental = $false }, [pscustomobject]@{ Id = 'fiscal'; Incremental = $false })
        $same = @{ InstanceName = 'acme'; Jobs = $jobs; Schedule = @{ Tasks = @(
            @{ Name = 'a'; Jobs = @('database'); At = @('12:00', '19:00') }
            @{ Name = 'b'; Jobs = @('fiscal'); At = @('12:00', '18:30') }) } }
        { Get-DBScheduleTask $same } | Should -Throw "*mesmo horario (12:00)*'12:01'*"
        $same.Schedule.Tasks[1].At = @('12:01', '18:30')
        @(Get-DBScheduleTask $same).Count | Should -Be 2
        $weekly = @{ InstanceName = 'acme'; Jobs = $jobs; Schedule = @{ Tasks = @(
            @{ Name = 'a'; Jobs = @('database'); At = '03:00'; Frequency = 'Weekly'; Days = @('Saturday') }
            @{ Name = 'b'; Jobs = @('fiscal'); At = '03:00'; Frequency = 'Weekly'; Days = @('Sunday') }) } }
        @(Get-DBScheduleTask $weekly).Count | Should -Be 2
    }
    It 'refuses an incremental task for a job without Incremental.Enabled' {
        $bad = @{ InstanceName = 'acme'; Jobs = $script:Config.Jobs; Schedule = @{ Tasks = @(@{ Name = 'inc'; Jobs = @('seven'); At = '09:00'; Mode = 'Incremental' }) } }
        { Get-DBScheduleTask $bad } | Should -Throw '*Incremental.Enabled*'
    }
}

Describe 'SQL Anywhere incremental provider' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory $script:Root
        $options = Join-Path $script:Root 'connection.options'
        Set-Content $options '-c "UID=''backup'';PWD=''test-secret'';SERVER=''srv'';DBN=''demo''"'
        $script:C = @{ Tools = @{ DbBackup = 'dbbackup.exe' } }
        $script:R = [pscustomobject]@{ RunId = 'r1'; Work = (Join-Path $script:Root 'work') }
        $script:J = [pscustomobject]@{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'demo'; CredentialFile = $options; Incremental = $true }
        Mock Set-Acl {} -ModuleName Runtime
        Mock Invoke-DBTool {
            param($Executable, $Arguments)
            if ($Executable -eq 'dbbackup.exe') {
                if ($Arguments -notcontains '-t') { Set-Content (Join-Path $Arguments[-1] 'demo.db') 'db' }
                Set-Content (Join-Path $Arguments[-1] 'demo.log') 'log'
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ModuleName SQLAnywhere
    }
    It 'renames the production log (-r) on the full of an incremental job' {
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Packages[0].Role | Should -Be 'FULL'
        $r.Metadata.ProductionLogRename | Should -BeTrue
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter { $Executable -eq 'dbbackup.exe' -and $Arguments[1] -eq '-r' -and $Arguments -notcontains '-x' }
    }
    It 'copies only the current log (-t) since the base on an incremental' {
        $base = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-18T22:00:00.0000000Z' }
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base
        $r.Packages[0].Role | Should -Be 'INCREMENTAL'
        $r.Metadata.BaseRunId | Should -Be 'base1'
        $r.Metadata.LogFiles | Should -Be @('demo.log')
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter { $Executable -eq 'dbbackup.exe' -and $Arguments[1] -eq '-t' -and $Arguments -notcontains '-r' }
    }
    It 'reads the production log folder from the localized dbping table' {
        $bin = Join-Path $script:Root 'bin'
        $null = New-Item -ItemType Directory $bin
        foreach ($name in 'dbbackup.exe', 'dbping.exe') { Set-Content (Join-Path $bin $name) 'x' }
        $configuration = @{ Tools = @{ DbBackup = (Join-Path $bin 'dbbackup.exe') } }
        $output = "SQL Anywhere - Utilitario de ping de servidor Versao 17.0.11.8360`r`nTipo       Propriedade                  Valor`r`n---------  ----------------          ------------------------------`r`nBanco de dados   LogName                   C:\Contabil\Dados\contabil.log`r`nO acesso ao banco de dados atraves do ping obteve exito.`r`n"
        Mock Invoke-DBTool { [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' } } -ModuleName SQLAnywhere
        Get-DBSqlAnywhereLogDirectory -Configuration $configuration -OptionsPath 'x.options' | Should -Be 'C:\Contabil\Dados'
        Mock Invoke-DBTool { [pscustomobject]@{ ExitCode = 0; StdOut = "LogName: D:\Db\Logs\demo.LOG`n"; StdErr = '' } } -ModuleName SQLAnywhere
        Get-DBSqlAnywhereLogDirectory -Configuration $configuration -OptionsPath 'x.options' | Should -Be 'D:\Db\Logs'
    }
    It 'refuses an incremental without a base' {
        { Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental } | Should -Throw '*base*'
    }
}

Describe 'Log chain of the incrementals (foreign backup)' {
    BeforeAll {
        # Real dbtran output (pt-BR) of a copied contabil.log, plus the English wording.
        $script:TranPt = "SQL Anywhere - Utilitario de conversao de registro Versao 17.0.11.8360`r`nO registro de transacoes `"C:\TI\Temp\dbcheck\incr\contabil.log`" inicia no deslocamento 013487586443`r`nLinha do tempo GUID atual: 9bb0cac0-d332-42d7-905d-55995f701e91`r`nHora de criacao UTC da linha do tempo atual: 2023-11-20 19:55:23.523787+00:00`r`nRegistro GUID de transacao atual: 00000000-0000-0000-0000-000000000000`r`n 100% terminado`r`nO registro de transacoes termina no deslocamento 013487702224`r`n"
        $script:TranEn = "Transaction log `"demo.log`" starts at offset 0000917328`nTransaction log ends at offset 0000918118`n"
    }
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $bin = Join-Path $script:Root 'bin'
        $null = New-Item -ItemType Directory $bin -Force
        foreach ($name in 'dbbackup.exe', 'dbtran.exe') { Set-Content (Join-Path $bin $name) 'x' }
        $options = Join-Path $script:Root 'connection.options'
        Set-Content $options '-c "UID=''backup'';PWD=''test-secret'';SERVER=''srv'';DBN=''demo''"'
        $script:C = @{ Tools = @{ DbBackup = (Join-Path $bin 'dbbackup.exe') } }
        $script:R = [pscustomobject]@{ RunId = 'r1'; Work = (Join-Path $script:Root 'work') }
        $script:J = [pscustomobject]@{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'demo'; CredentialFile = $options; Incremental = $true }
        $script:Tran = $script:TranPt
        $script:TranExit = 0
        Mock Set-Acl {} -ModuleName Runtime
        Mock Invoke-DBTool {
            param($Executable, $Arguments)
            if ($Executable -like '*dbbackup.exe') {
                if ($Arguments -notcontains '-t') { Set-Content (Join-Path $Arguments[-1] 'demo.db') 'db' }
                Set-Content (Join-Path $Arguments[-1] 'demo.log') 'log'
                return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            if ($Executable -like '*dbtran.exe') {
                # The translated SQL is written to the private folder of the run.
                Set-Content $Arguments[-1] 'insert into segredo values (1)'
                return [pscustomobject]@{ ExitCode = $script:TranExit; StdOut = $script:Tran; StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
        } -ModuleName SQLAnywhere
    }
    It 'reads the start and end offsets from localized or English dbtran output' {
        $pt = ConvertFrom-DBTranOutput $script:TranPt
        $pt.Start | Should -Be '13487586443'
        $pt.End | Should -Be '13487702224'
        $en = ConvertFrom-DBTranOutput $script:TranEn
        "$($en.Start)-$($en.End)" | Should -Be '917328-918118'
        ConvertFrom-DBTranOutput "Registro GUID de transacao atual: 00000000-0000-0000-0000-000000000000`nO registro de transacoes termina no deslocamento 013487702224" | Should -BeNullOrEmpty
        ConvertFrom-DBTranOutput '' | Should -BeNullOrEmpty
    }
    It 'records where the log of the full ends and deletes the translated SQL' {
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Status | Should -Be 'SUCCESS'
        $r.Metadata.LogEndOffset | Should -Be '13487702224'
        $r.Errors | Should -BeNullOrEmpty
        @(Get-ChildItem $script:R.Work -Recurse -Filter '*.sql').Count | Should -Be 0
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter { $Executable -like '*dbtran.exe' -and $Arguments[1] -like '*demo.log' -and $Arguments[1] -like "$($script:R.Work)*" }
    }
    It 'accepts an incremental whose log starts where the base ended' {
        $base = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-24T22:00:00.0000000Z'; LogEndOffset = '013487586443' }
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base
        $r.Status | Should -Be 'SUCCESS'
        $r.Metadata.LogChain | Should -Be 'VERIFIED'
        $r.Metadata.LogStartOffset | Should -Be '13487586443'
    }
    It 'discards the incremental when the log was restarted outside DBBackup' {
        $base = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-24T22:00:00.0000000Z'; LogEndOffset = '13400000000' }
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base
        $r.Status | Should -Be 'CHAIN_BROKEN'
        $r.Packages.Count | Should -Be 0
        $r.Errors[0] | Should -Match 'ends at offset 13400000000, current log starts at 13487586443'
        Test-Path (Join-Path $script:R.Work 'dominio') | Should -BeFalse
    }
    It 'asks for a full when the log cannot be read and only warns without dbtran or base offset' {
        $base = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-24T22:00:00.0000000Z'; LogEndOffset = '13487586443' }
        $script:TranExit = 7
        (Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base).Status | Should -Be 'CHAIN_UNVERIFIED'
        $script:TranExit = 0
        $old = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-24T22:00:00.0000000Z' }
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $old
        $r.Status | Should -Be 'SUCCESS'
        $r.Metadata.LogChain | Should -Be 'UNVERIFIED'
        $r.Errors[0] | Should -Match 'without log offset'
        Remove-Item (Join-Path (Split-Path $script:C.Tools.DbBackup) 'dbtran.exe')
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base
        $r.Status | Should -Be 'SUCCESS'
        $r.Errors[0] | Should -Match 'dbtran.exe not found'
    }
    It 'keeps the offset in the base and reads bases written before 2.4' {
        $c = @{ InstanceName = 'acme'; Paths = @{ RuntimeRoot = (Join-Path $script:Root 'Runtime') } }
        Save-DBIncrementalBase -Configuration $c -Job 'dominio' -RunId 'r1' -RecoveryPointUtc ([DateTime]::UtcNow) -LogDirectory 'C:\Db' -LogEndOffset '13487702224'
        (Read-DBIncrementalBase $c 'dominio').LogEndOffset | Should -Be '13487702224'
        Save-DBIncrementalBase -Configuration $c -Job 'dominio' -RunId 'r1' -RecoveryPointUtc ([DateTime]::UtcNow) -LogDirectory 'C:\Db'
        (Read-DBIncrementalBase $c 'dominio').LogEndOffset | Should -BeNullOrEmpty
        $path = Get-DBIncrementalBasePath $c 'dominio'
        $legacy = Get-Content $path -Raw | ConvertFrom-Json
        $legacy.PSObject.Properties.Remove('LogEndOffset')
        $legacy | ConvertTo-Json | Set-Content $path
        (Read-DBIncrementalBase $c 'dominio').LogEndOffset | Should -BeNullOrEmpty
    }
}

Describe 'Runner after a foreign backup cut the log' {
    BeforeAll {
        foreach ($name in 'Observation', 'Capacity', 'Runner') { Import-Module "$script:Repo/src/App/Modules/Core/$name.psm1" -Force }
        Import-Module "$script:Repo/src/App/Modules/Providers/Providers.psm1" -Force
    }
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $instance = Join-Path $script:Root 'acme'
        $null = New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        Set-Content (Join-Path $instance 'Secrets/dominio.options') '-c "UID=''backup'';PWD=''x'';SERVER=''srv'';DBN=''demo''"'
        $text = Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME' -Tools @{ DbBackup = 'C:\SA\dbbackup.exe' }
        $text = $text.Replace('Jobs = @(', "Jobs = @(@{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'demo'; CredentialFile = 'Secrets/dominio.options'; RemoteRoot = 's3:bucket/ACME'; Incremental = @{ Enabled = `$true } }, ")
        $script:Config = Join-Path $instance 'config.psd1'
        Set-Content $script:Config $text
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Published = [Collections.Generic.List[string]]::new()
        Mock Set-Acl {} -ModuleName Runtime
        Mock Write-Error {} -ModuleName Runner
        Mock Assert-DBBackupDependency {} -ModuleName Runner
        Mock Assert-DBFreeSpace {} -ModuleName Runner
        Mock Remove-DBExpired {} -ModuleName Runner
        Mock Publish-DBLog {} -ModuleName Runner
        Mock Publish-DBPackage {} -ModuleName Runner
        Mock Remove-DBRenamedLog { @() } -ModuleName Runner
        Mock Publish-DBJobMonitoring { $script:Published.Add("$Mode=$Status"); $true } -ModuleName Runner
        Mock Invoke-DBProvider {
            $script:Calls.Add($Mode)
            $now = [DateTime]::UtcNow
            if ($Mode -eq 'Incremental') {
                return [pscustomobject]@{ Status = 'CHAIN_BROKEN'; Packages = @(); Errors = @('Log chain restarted outside DBBackup.'); StartedAtUtc = $now; FinishedAtUtc = $now; Metadata = @{} }
            }
            [pscustomobject]@{ Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $TestDrive; ContentsOnly = $true }); Errors = @()
                StartedAtUtc = $now; FinishedAtUtc = $now; Metadata = @{ ProductionLogDirectory = 'C:\Db'; LogEndOffset = '13500000000' } }
        } -ModuleName Runner
    }
    It 'runs a full at once, records the new base and ends degraded with the log series degraded' {
        $c = Read-DBConfiguration $script:Config
        Save-DBIncrementalBase -Configuration $c -Job 'dominio' -RunId 'old' -RecoveryPointUtc ([DateTime]::UtcNow.AddHours(-20)) -LogDirectory 'C:\Db' -LogEndOffset '13400000000'
        Invoke-DBBackup -ConfigPath $script:Config -Job 'dominio' -Mode Incremental | Should -Be 5
        $script:Calls -join ',' | Should -Be 'Incremental,Full'
        $script:Published -join ',' | Should -Be 'Full=SUCCESS,Incremental=DEGRADED'
        $base = Read-DBIncrementalBase $c 'dominio'
        $base.BaseRunId | Should -Not -Be 'old'
        $base.LogEndOffset | Should -Be '13500000000'
        $log = Get-Content (Get-ChildItem (Join-Path (Split-Path $script:Config) 'Logs') -Filter '*.log' -Recurse | Select-Object -First 1).FullName -Raw
        $log | Should -Match 'Log chain restarted outside DBBackup'
        $log | Should -Match 'cadeia do log reiniciada fora do DBBackup'
    }
}

Describe 'Incremental retention and renamed logs' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $completed = Join-Path $script:Root 'Completed'
        $logs = Join-Path $script:Root 'Logs'
        $null = New-Item -ItemType Directory $completed, $logs, (Join-Path $script:Root 'Runtime') -Force
        $script:C = @{ InstanceName = 'acme'; Jobs = @([pscustomobject]@{ Id = 'dominio'; KeepRenamedLogDays = 3 })
            Retention = @{ CompletedDays = 7; LogDays = 30 }
            Paths = @{ CompletedRoot = $completed; LogRoot = $logs; RuntimeRoot = (Join-Path $script:Root 'Runtime') } }
        $script:R = [pscustomobject]@{ Completed = $completed; LogPath = (Join-Path $logs 'run.log') }
        Mock Set-Acl {} -ModuleName Runtime
    }
    It 'drops incrementals whose base is older than the previous full and keeps the last day' {
        $now = [DateTime]::UtcNow
        $full2 = $now.AddDays(-2); $full1 = $now.AddDays(-1); $full0 = $now.AddHours(-1)
        foreach ($f in @(@('f2', $full2), @('f1', $full1), @('f0', $full0))) { $null = New-TestBundle $script:C.Paths.CompletedRoot $f[0] 'FULL' $f[1] $null }
        $old = New-TestBundle $script:C.Paths.CompletedRoot 'i-old' 'INCREMENTAL' $full2.AddHours(4) $full2
        $kept = New-TestBundle $script:C.Paths.CompletedRoot 'i-kept' 'INCREMENTAL' $full1.AddHours(4) $full1
        Remove-DBExpired -Configuration $script:C -Runtime $script:R
        $old | Should -Not -Exist
        $kept | Should -Exist
        @(Get-ChildItem (Join-Path $script:C.Paths.CompletedRoot 'dominio') -Directory).Count | Should -Be 4
    }
    It 'removes nothing new when only one full exists' {
        $now = [DateTime]::UtcNow
        $null = New-TestBundle $script:C.Paths.CompletedRoot 'f0' 'FULL' $now.AddDays(-1) $null
        $inc = New-TestBundle $script:C.Paths.CompletedRoot 'i0' 'INCREMENTAL' $now $now.AddDays(-2)
        Remove-DBExpired -Configuration $script:C -Runtime $script:R
        $inc | Should -Exist
    }
    It 'removes renamed production logs only after the base full is confirmed and older than the limit' {
        $dbFolder = Join-Path $script:Root 'Dados'
        $null = New-Item -ItemType Directory $dbFolder
        foreach ($name in '261110AA.log', '261118AB.log', 'contabil.log') { Set-Content (Join-Path $dbFolder $name) 'x' }
        (Get-Item (Join-Path $dbFolder '261110AA.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
        (Get-Item (Join-Path $dbFolder 'contabil.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
        $baseTime = [DateTime]::UtcNow.AddHours(-2)
        Save-DBIncrementalBase -Configuration $script:C -Job 'dominio' -RunId 'base1' -RecoveryPointUtc $baseTime -LogDirectory $dbFolder
        @(Remove-DBRenamedLog -Configuration $script:C -Job $script:C.Jobs[0]).Count | Should -Be 0
        $null = New-TestBundle $script:C.Paths.CompletedRoot 'base' 'FULL' $baseTime $null -RunId 'base1'
        @(Remove-DBRenamedLog -Configuration $script:C -Job $script:C.Jobs[0]) | Should -Be @('261110AA.log')
        Join-Path $dbFolder '261118AB.log' | Should -Exist
        Join-Path $dbFolder 'contabil.log' | Should -Exist
    }
}

Describe 'Versioned configurations' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $instance = Join-Path $script:Root 'Instances/acme'
        $null = New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        Set-Content (Join-Path $instance 'config.psd1') (Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME')
        Set-Content (Join-Path $script:Root 'ambiente.psd1') "@{ SchemaVersion = 1 }"
    }
    It 'exports ambiente.psd1 and the instance configs but never Secrets' {
        Set-Content (Join-Path $script:Root 'Instances/acme/Secrets/rclone.conf') 'secret_access_key = x'
        $result = Export-DBVersionedConfiguration -InstallRoot $script:Root -Destination (Join-Path $script:Root 'out') -ServerName 'srv-a'
        @($result.Files) | Should -Be @('ambiente.psd1', 'acme/config.psd1')
        @(Get-ChildItem (Join-Path $script:Root 'out') -Recurse -File).Name | Should -Not -Contain 'rclone.conf'
        { Assert-DBNoSecretText "-c `"UID=a;PWD=b`"" 'x' } | Should -Throw '*segredo*'
    }
    It 'installs changed files keeping .anterior and rolls everything back when one is invalid' {
        $config = Join-Path $script:Root 'Instances/acme/config.psd1'
        $original = Get-Content $config -Raw
        $changed = $original.Replace("CompletedDays = 7", "CompletedDays = 9")
        $changes = @(Compare-DBVersionedFile -InstallRoot $script:Root -Remote @([pscustomobject]@{ Relative = 'acme/config.psd1'; Text = $changed }))
        $changes.Count | Should -Be 1
        ($changes[0].Diff -join "`n") | Should -Match 'CompletedDays = 9'
        Install-DBVersionedFile -InstallRoot $script:Root -Changes $changes | Should -Be 'acme'
        (Get-Content $config -Raw) | Should -Match 'CompletedDays = 9'
        "$config.anterior" | Should -Exist
        $bad = @(Compare-DBVersionedFile -InstallRoot $script:Root -Remote @(
            [pscustomobject]@{ Relative = 'acme/config.psd1'; Text = $original }
            [pscustomobject]@{ Relative = 'ambiente.psd1'; Text = '@{ SchemaVersion = 99 }' }))
        { Install-DBVersionedFile -InstallRoot $script:Root -Changes $bad } | Should -Throw '*nada foi alterado*'
        (Get-Content $config -Raw) | Should -Match 'CompletedDays = 9'
        (Get-Content (Join-Path $script:Root 'ambiente.psd1') -Raw).Trim() | Should -Be '@{ SchemaVersion = 1 }'
    }
    It 'accepts only ambiente.psd1 and instance config.psd1 files' {
        { Get-DBVersionedLocalPath $script:Root 'acme/Secrets/rclone.conf' } | Should -Throw
        { Get-DBVersionedLocalPath $script:Root '../x/config.psd1' } | Should -Throw
    }
}
