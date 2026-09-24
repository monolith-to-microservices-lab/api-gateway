#Requires -Version 5.1
<#
.SYNOPSIS
Routes /users to user-service. Default scope = Reads (GET): writes stay on the monolith.

.DESCRIPTION
-Scope Reads  GET/HEAD /users... -> user-service; POST/PUT/PATCH/DELETE stay on the monolith.
-Scope All    also sends WRITES to user-service. That is a WRITE CUTOVER: rows created there
              are NOT synced back to the monolith (still the source of truth). Refused unless
              -AcceptWriteDivergence is given. Use only in a controlled test.

.EXAMPLE
.\scripts\route-users-to-service.ps1
.EXAMPLE
.\scripts\route-users-to-service.ps1 -Scope All -AcceptWriteDivergence -AcceptIncompatibility -Reason "controlled write-cutover test"
#>
[CmdletBinding()]
param(
    [ValidateSet('Reads', 'All')] [string]$Scope = 'Reads',
    [string]$Reason = '',
    [switch]$AcceptWriteDivergence,
    [switch]$AcceptIncompatibility,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force
Set-DomainRoute -Domain users -Scope $Scope -Target service -Reason $Reason `
    -AcceptWriteDivergence:$AcceptWriteDivergence -AcceptIncompatibility:$AcceptIncompatibility -DryRun:$DryRun
