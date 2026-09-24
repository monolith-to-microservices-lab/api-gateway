# PSScriptAnalyzer settings for scripts/. CI fails on any Warning/Error not
# excluded here - every exclusion has its reason next to it.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Operator-facing scripts: colored, human-readable tables are the point
        # (route-status, health-check). Nothing here is meant to be piped.
        'PSAvoidUsingWriteHost',
        # Switches expose an explicit, documented -DryRun instead of -WhatIf/-Confirm
        # (guards + refusals already make every change explicit).
        'PSUseShouldProcessForStateChangingFunctions',
        # Get-RoutingGuards / Get-RouteNames read better than their singular forms.
        'PSUseSingularNouns',
        # Local table helper Row "name" "value" in health-check.ps1.
        'PSAvoidUsingPositionalParameters'
    )
}
