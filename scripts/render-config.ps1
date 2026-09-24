#Requires -Version 5.1
<#
.SYNOPSIS
Renders kong/kong.template.yml for one routing profile (no gateway needed).

.EXAMPLE
.\scripts\render-config.ps1 -Name mode-1-all-monolith -OutFile kong\kong.default.yml
Regenerates the committed default config after editing the template.

.EXAMPLE
.\scripts\render-config.ps1 -Name mode-2r-users-reads-service
Prints the rendered YAML to stdout.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Name,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force

$routing = Get-RoutingProfile $Name
$config = ConvertTo-KongDeclarativeConfig $routing.Routes
if ($OutFile) {
    if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location) $OutFile }
    Write-Utf8FileAtomic ([System.IO.Path]::GetFullPath($OutFile)) $config
    Write-Host "Rendered $Name -> $OutFile"
}
else {
    $config
}
