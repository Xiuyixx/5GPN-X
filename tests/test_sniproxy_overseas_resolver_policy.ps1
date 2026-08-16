$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installSources = @("install.sh", "lib/common.sh", "lib/dns.sh", "lib/cert.sh", "lib/services.sh", "lib/exits.sh", "lib/rules.sh", "lib/uninstall.sh")
$install = ($installSources | ForEach-Object { Get-Content -Path (Join-Path $root $_) -Raw -Encoding UTF8 }) -join "`n"
$sniproxy = Get-Content -Path (Join-Path $root "lib/sniproxy.conf") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing sniproxy overseas resolver marker: $Description ($Needle)"
    }
}

$mainInstallMatch = [regex]::Match($install, '(?s)main_install\(\) \{.*?\n\}')
if (-not $mainInstallMatch.Success) {
    throw "main_install function not found"
}

$mainInstall = $mainInstallMatch.Value
$configureIndex = $mainInstall.IndexOf("configure_dns_upstreams")
$servicesIndex = $mainInstall.IndexOf('run_install_step "部署代理与 DNS 服务"')

if ($configureIndex -lt 0 -or $servicesIndex -lt 0 -or $configureIndex -gt $servicesIndex) {
    throw "configure_dns_upstreams must run before install_sniproxy so sniproxy resolver uses custom remote DNS"
}

$servicesStageMatch = [regex]::Match($install, '(?s)install_stage_services\(\) \{.*?\n\}')
if (-not $servicesStageMatch.Success -or -not $servicesStageMatch.Value.Contains("install_sniproxy")) {
    throw "install_stage_services must install sniproxy"
}

Assert-Contains $sniproxy 'resolver {' 'resolver stanza'
Assert-Contains $sniproxy '__SNIPROXY_NAMESERVERS__' 'sniproxy DNS placeholder'
Assert-Contains $sniproxy 'mode ipv4_only' 'sniproxy forced IPv4 mode'
Assert-Contains $install 'render_sniproxy_dns' 'installer renders sniproxy resolver'
Assert-Contains $install 'REMOTE_DNS' 'installer accepts remote DNS variable'
Assert-Contains $install '/etc/mosdns/.sniproxy_dns' 'installer saves sniproxy DNS config'
Assert-Contains $install '__SNIPROXY_NAMESERVERS__' 'installer replaces sniproxy DNS placeholder'
Assert-Contains $readme 'sniproxy' 'README documents sniproxy'
Assert-Contains $readme '/etc/sniproxy.conf' 'README documents reverse proxy DNS config'
Assert-Contains $readme 'ipv4_only' 'README documents IPv4-only sniproxy resolver'

Write-Output "sniproxy overseas resolver markers OK"
