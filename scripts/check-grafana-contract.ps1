#requires -Version 7.2
<#
.SYNOPSIS
Confere o produtor de backups contra o contrato do repositorio grafana.

.DESCRIPTION
O contrato (contracts/prometheus/backup.yml) fica no repositorio que o consome:
DEV-ASSESSORIA-TECH/grafana. Os testes unitarios usam uma copia fixada
(tests/fixtures/backup-contract.json) para rodar sem rede; este script garante
que a copia e o produtor (Monitoring.psm1) acompanham a main do grafana:

1. metric_help do contrato = metricHelp da copia fixada (e a versao);
2. metric_help do contrato = HELP publicado pelo Monitoring.psm1;
3. regra de identificadores (service, backup_id) igual a do contrato.

Roda na CI em todo push/PR e uma vez por semana (contrato alterado no grafana
sem mudanca aqui). Sem dependencias: le o YAML pelo formato do bloco.
#>
[CmdletBinding()]
param(
    [string]$ContractPath,
    [string]$Ref = 'main'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if ($ContractPath) {
    $text = Get-Content -LiteralPath $ContractPath -Raw
} else {
    $url = "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/grafana/$Ref/contracts/prometheus/backup.yml"
    $text = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
}
$lines = $text -split "`r?`n"

function ConvertFrom-YamlScalar([string]$Value) {
    $scalar = $Value.Trim()
    if ($scalar.Length -ge 2 -and $scalar[0] -eq "'" -and $scalar[-1] -eq "'") { return $scalar.Substring(1, $scalar.Length - 2).Replace("''", "'") }
    if ($scalar.Length -ge 2 -and $scalar[0] -eq '"' -and $scalar[-1] -eq '"') { return $scalar.Substring(1, $scalar.Length - 2) }
    return $scalar
}

$contractVersion = ($lines | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1) -replace '^version:\s*', ''
$upstream = [ordered]@{}
$inBlock = $false
foreach ($line in $lines) {
    if ($line -match '^metric_help:\s*$') { $inBlock = $true; continue }
    if ($inBlock -and $line -match '^\S') { break }
    if ($inBlock -and $line -match '^\s+(backup_[a-z0-9_]+):\s+(.+)$') { $upstream[$Matches[1]] = ConvertFrom-YamlScalar $Matches[2] }
}
if ($upstream.Count -eq 0) { throw 'metric_help nao encontrado no contrato.' }

$failures = [System.Collections.Generic.List[string]]::new()
function Compare-Help([string]$Label, [System.Collections.IDictionary]$Actual) {
    foreach ($name in $upstream.Keys) {
        if (-not $Actual.Contains($name)) { $failures.Add("${Label}: falta $name (contrato: '$($upstream[$name])')"); continue }
        if ($Actual[$name] -cne $upstream[$name]) { $failures.Add("${Label}: HELP de $name difere (contrato: '$($upstream[$name])', aqui: '$($Actual[$name])')") }
    }
    foreach ($name in $Actual.Keys) {
        if (-not $upstream.Contains($name)) { $failures.Add("${Label}: $name nao esta no contrato") }
    }
}

# 1. Copia fixada usada pelos testes unitarios.
$fixture = Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/backup-contract.json') -Raw | ConvertFrom-Json -AsHashtable
Compare-Help 'tests/fixtures/backup-contract.json' $fixture.metricHelp
if ($fixture.version -ne $contractVersion) {
    $failures.Add("tests/fixtures/backup-contract.json: versao $($fixture.version), contrato $contractVersion")
}

# 2. HELP publicado pelo produtor (lido do codigo, sem carregar o modulo).
$module = Join-Path $root 'src/App/Modules/Core/Monitoring.psm1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$null)
$assignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$script:MetricHelp' }, $true)
if (-not $assignment) { throw '$script:MetricHelp nao encontrado em Monitoring.psm1.' }
$produced = [ordered]@{}
$hash = $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
foreach ($pair in $hash.KeyValuePairs) { $produced[$pair.Item1.Extent.Text.Trim("'", '"')] = $pair.Item2.Extent.Text.Trim().Trim("'") }
Compare-Help 'Monitoring.psm1' $produced

# 3. Identificadores service/backup_id.
$contractRule = [regex]::Match($text, "service e backup_id seguem '([^']+)'").Groups[1].Value
$producerRule = [regex]::Match((Get-Content -LiteralPath $module -Raw), '\$script:IdentifierPattern\s*=\s*''([^'']+)''').Groups[1].Value
if (-not $contractRule) { $failures.Add('contrato: regra de service/backup_id nao encontrada') }
elseif ($contractRule -cne $producerRule) { $failures.Add("Monitoring.psm1: IdentifierPattern '$producerRule' difere do contrato '$contractRule'") }

if ($failures.Count) {
    foreach ($failure in $failures) { Write-Output "::error::$failure" }
    throw "Produtor diverge do contrato de backups v$contractVersion ($($failures.Count) diferenca(s))."
}
Write-Output "ok: produtor confere com o contrato de backups v$contractVersion ($($upstream.Count) metricas)."
