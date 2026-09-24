#Requires -Version 5.1
<#
.SYNOPSIS
Integration tests: the REAL gateway image + config + scripts against controlled
stub upstreams, in an isolated compose project (api-gateway-it) on its own
network and ports. Safe to run while the lab and the real gateway are up.

  proxy 18088 | admin 127.0.0.1:18089 | status 127.0.0.1:18090 | exporter 127.0.0.1:19542
  network api-gateway-it | routing state .it-state/ (fresh on every run)

.EXAMPLE
.\scripts\test-integration.ps1
.EXAMPLE
.\scripts\test-integration.ps1 -KeepRunning -PytestArgs '-k rate_limit'
#>
[CmdletBinding()]
param(
    [switch]$KeepRunning,
    [string]$PytestArgs = '',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = 'api-gateway-it'
$env:GATEWAY_NETWORK = 'api-gateway-it'
$env:GATEWAY_PROXY_PORT = '18088'
$env:GATEWAY_ADMIN_PORT = '18089'
$env:GATEWAY_STATUS_PORT = '18090'
$env:GATEWAY_EXPORTER_PORT = '19542'
$env:GATEWAY_STATE_DIR = '.it-state'
$env:GATEWAY_PROXY_URL = 'http://localhost:18088'
$env:GATEWAY_ADMIN_URL = 'http://127.0.0.1:18089'
$env:GATEWAY_STATUS_URL = 'http://127.0.0.1:18090'
$env:GATEWAY_EXPORTER_URL = 'http://127.0.0.1:19542'
$env:GATEWAY_COMPOSE_PROJECT = $project
$compose = @('compose', '-p', $project, '-f', 'docker-compose.yml', '-f', 'tests/integration/docker-compose.it.yml')

Push-Location $root
# Native tools (docker) write progress to stderr; with 'Stop', Windows
# PowerShell 5.1 would turn a redirected stderr line into a terminating error.
# Exit codes are checked explicitly instead.
$ErrorActionPreference = 'Continue'
$code = 1
try {
    & docker network inspect $env:GATEWAY_NETWORK *> $null
    if ($LASTEXITCODE -ne 0) { & docker network create $env:GATEWAY_NETWORK 2>&1 | Out-Null }

    # Fresh routing state: the gateway must boot the committed default.
    $state = Join-Path $root '.it-state'
    if (Test-Path $state) { Remove-Item -Recurse -Force $state }
    New-Item -ItemType Directory -Path $state | Out-Null

    & docker @compose up -d --build --wait 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }

    & $Python -m pytest tests/integration -o addopts='' -v --junitxml=junit-integration.xml @($PytestArgs -split ' ' | Where-Object { $_ })
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        & docker @compose logs --no-color --tail 200 > integration-containers.log 2>&1
        Write-Host 'Container logs: integration-containers.log'
    }
}
finally {
    if (-not $KeepRunning) {
        & docker @compose down --remove-orphans 2>&1 | ForEach-Object { "$_" }
        & docker network rm $env:GATEWAY_NETWORK *> $null
    }
    Pop-Location
}
exit $code
