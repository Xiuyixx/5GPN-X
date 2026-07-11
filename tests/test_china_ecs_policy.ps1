$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$templatePath = Join-Path $root "lib/dnsdist.conf.template"
$template = Get-Content -Path $templatePath -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $template.Contains($Needle)) {
        throw "Missing China ECS marker: $Description ($Needle)"
    }
}

Assert-Contains 'local chinaECS = "139.226.48.0/24"' 'China ECS subnet constant'
Assert-Contains 'useClientSubnet=true' 'ECS forwarding enabled on China upstreams'
Assert-Contains 'SetECSOverrideAction(true)' 'forced ECS override for ChinaList queries'
Assert-Contains 'SetECSAction(chinaECS)' 'fixed ECS subnet for ChinaList queries'

Write-Output "China ECS markers OK"
