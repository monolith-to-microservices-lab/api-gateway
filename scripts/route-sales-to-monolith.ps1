#Requires -Version 5.1
<#
.SYNOPSIS
Routes /sales back to the monolith (rollback). Default scope = All (reads AND writes).

.DESCRIPTION
Always allowed - the monolith is the source of truth. If sales WRITES were on the microservice,
the rows written there are NOT in the monolith: a route rollback does not reconcile data
(see docs/route-rollback-runbook.md). The script warns when that is the case.

.EXAMPLE
.\scripts\route-sales-to-monolith.ps1
.EXAMPLE
.\scripts\route-sales-to-monolith.ps1 -Scope Reads -Reason "p95 regression on the service"
#>
[CmdletBinding()]
param(
    [ValidateSet('Reads', 'Writes', 'All')] [string]$Scope = 'All',
    [string]$Reason = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force
Set-DomainRoute -Domain sales -Scope $Scope -Target monolith -Reason $Reason -DryRun:$DryRun
