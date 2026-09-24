#Requires -Version 5.1
<#
.SYNOPSIS
Emergency rollback: every route (users + sales, reads + writes) back to the monolith.

.DESCRIPTION
Applies mode-1-all-monolith, the same state Kong boots with by default. Always allowed.
Routing only - it does not move or reconcile data written to a microservice during a
write cutover (see docs/route-rollback-runbook.md).

.EXAMPLE
.\scripts\rollback-all-to-monolith.ps1 -Reason "INC-42 5xx on user-service"
#>
[CmdletBinding()]
param([string]$Reason = 'rollback-all-to-monolith', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force
Set-GatewayRouting -State (Get-DefaultRoutingState) -Reason $Reason -DryRun:$DryRun
