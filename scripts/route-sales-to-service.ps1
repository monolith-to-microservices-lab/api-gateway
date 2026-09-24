#Requires -Version 5.1
<#
.SYNOPSIS
Routes /sales to sales-service. Default scope = Reads (GET): writes stay on the monolith.

.DESCRIPTION
sales-service is KNOWN INCOMPATIBLE with the monolith's sales API (no user_name field, which the
frontend renders; GET /sales paginated to 100 by default; POST does not check the user exists) -
see docs/api-compatibility-matrix.md. Any sales route switch therefore needs -AcceptIncompatibility.
-Scope All is also a WRITE CUTOVER (no sync back to the monolith) and needs -AcceptWriteDivergence.

.EXAMPLE
.\scripts\route-sales-to-service.ps1 -AcceptIncompatibility -Reason "demo: sales reads from sales-service"
#>
[CmdletBinding()]
param(
    [ValidateSet('Reads', 'All')] [string]$Scope = 'Reads',
    [string]$Reason = '',
    [switch]$AcceptIncompatibility,
    [switch]$AcceptWriteDivergence,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force
Set-DomainRoute -Domain sales -Scope $Scope -Target service -Reason $Reason `
    -AcceptWriteDivergence:$AcceptWriteDivergence -AcceptIncompatibility:$AcceptIncompatibility -DryRun:$DryRun
