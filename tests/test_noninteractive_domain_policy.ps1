$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installPath = Join-Path $root "install.sh"
$installSources = @("install.sh", "lib/common.sh", "lib/dns.sh", "lib/cert.sh", "lib/services.sh", "lib/exits.sh", "lib/rules.sh", "lib/uninstall.sh")
$install = ($installSources | ForEach-Object { Get-Content -Path (Join-Path $root $_) -Raw -Encoding UTF8 }) -join "`n"

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $install.Contains($Needle)) {
        throw "Missing noninteractive domain marker: $Description ($Needle)"
    }
}

function Assert-NotContains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if ($install.Contains($Needle)) {
        throw "Unexpected marker still present: $Description ($Needle)"
    }
}

# A DOMAIN env var must still skip the interactive prompt and persist the domain.
Assert-Contains 'Using pre-configured domain: $DOMAIN' 'preconfigured domain path'
Assert-Contains 'echo "$DOMAIN" > "${CONF_DIR}/.domain"' 'preconfigured domain persistence'
# Non-interactive installs without DOMAIN must fail fast instead of hanging on a read.
Assert-Contains 'Set the DOMAIN environment variable' 'noninteractive missing-domain guard'
# The custom-domain flow must verify the operator's own A record.
Assert-Contains 'validate_domain_dns' 'automatic custom-domain DNS verification'
Assert-NotContains 'collect_domain_dns_confirmation' 'redundant A-record confirmation prompt'
Assert-Contains '--keep-until-expiring' 'certificate reuse mode'
Assert-Contains '已存在证书，跳过签发。' 'existing certificate reuse'

# The ClouDNS public free-domain flow must be fully removed.
Assert-NotContains 'cloudns.net' 'ClouDNS API endpoint'
Assert-NotContains 'CLOUDNS_FREE_TLDS' 'ClouDNS free TLD list'
Assert-NotContains 'register_domain_cloudns' 'ClouDNS registration function'

Write-Output "noninteractive domain markers OK"
