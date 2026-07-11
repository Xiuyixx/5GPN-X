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
        throw "Missing DNS performance marker: $Description ($Needle)"
    }
}

Assert-Contains 'setServerPolicy(leastOutstanding)' 'least outstanding server policy'
Assert-Contains 'sessionTickets=true' 'DoT TLS session tickets'
Assert-Contains 'sessionTimeout=3600' 'DoT TLS session timeout'
Assert-Contains 'newPacketCache(__PACKET_CACHE_SIZE__' 'parametrised packet cache'
Assert-Contains 'minTTL=300' 'higher minimum cache TTL'
Assert-Contains 'temporaryFailureTTL=60' 'temporary failure cache TTL'
Assert-Contains 'staleTTL=300' 'stale cache TTL'

Write-Output "DNS performance markers OK"
