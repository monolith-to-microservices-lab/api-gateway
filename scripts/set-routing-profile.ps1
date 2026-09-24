#Requires -Version 5.1
<#
.SYNOPSIS
Applies one of the versioned routing profiles in routing/profiles/ (the "modes").

.EXAMPLE
.\scripts\set-routing-profile.ps1 -List
.EXAMPLE
.\scripts\set-routing-profile.ps1 -Name mode-2r-users-reads-service -Reason "reads-first on users"
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Apply', Position = 0)] [string]$Name,
    [Parameter(ParameterSetName = 'Apply')] [string]$Reason = '',
    [Parameter(ParameterSetName = 'Apply')] [switch]$AcceptWriteDivergence,
    [Parameter(ParameterSetName = 'Apply')] [switch]$AcceptIncompatibility,
    [Parameter(ParameterSetName = 'Apply')] [switch]$DryRun,
    [Parameter(Mandatory, ParameterSetName = 'List')] [switch]$List
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force

if ($List) {
    foreach ($n in Get-RoutingProfileNames) {
        $p = Get-RoutingProfile $n
        $flags = @(@(Get-RoutingGuards $p.Routes) | ForEach-Object { $_.Flag } | Sort-Object -Unique)
        $needs = ''
        if ($flags.Count -gt 0) { $needs = "  [needs: $($flags -join ', ')]" }
        Write-Host ('{0,-30} {1}{2}' -f $n, (($p.Routes.Keys | ForEach-Object { "$_=$($p.Routes[$_])" }) -join ' '), $needs)
        Write-Host ('{0,-30} {1}' -f '', $p.Description) -ForegroundColor DarkGray
    }
    return
}

$p = Get-RoutingProfile $Name
Set-GatewayRouting -State $p.Routes -Reason $Reason -AcceptWriteDivergence:$AcceptWriteDivergence `
    -AcceptIncompatibility:$AcceptIncompatibility -DryRun:$DryRun
