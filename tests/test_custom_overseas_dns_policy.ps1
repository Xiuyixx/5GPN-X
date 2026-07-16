$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$template = Get-Content -Path (Join-Path $root "lib/mosdns.yaml.template") -Raw -Encoding UTF8
$rules = Get-Content -Path (Join-Path $root "lib/update-rules.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing custom DNS marker: $Description ($Needle)"
    }
}

Assert-Contains $install 'DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")' 'default remote overseas DNS pool'
Assert-Contains $install 'DEFAULT_LOCAL_DNS=("101.226.4.6" "218.30.118.6" "180.76.76.76" "119.29.29.29")' 'default local China DNS race pool'
Assert-Contains $install 'configure_dns_upstreams()' 'installer DNS function'
Assert-Contains $install 'REMOTE_DNS' 'installer remote DNS variable'
Assert-Contains $install 'LOCAL_DNS' 'installer local DNS variable'
Assert-Contains $install '/etc/mosdns/.remote_dns' 'installer saves remote DNS config'
Assert-Contains $install '/etc/mosdns/.local_dns' 'installer saves local DNS config'
Assert-Contains $template '__REMOTE_PRIMARY_UPSTREAMS__' 'mosdns remote primary placeholder'
Assert-Contains $template '__REMOTE_SECONDARY_UPSTREAMS__' 'mosdns remote fallback placeholder'
Assert-Contains $template '__LOCAL_PRIMARY_UPSTREAMS__' 'mosdns local primary placeholder'
Assert-Contains $template '__LOCAL_SECONDARY_UPSTREAMS__' 'mosdns local fallback placeholder'
Assert-Contains $rules '.remote_dns' 'rule updater reads saved remote DNS config'
Assert-Contains $rules '__REMOTE_PRIMARY_UPSTREAMS__' 'rule updater replaces remote primary placeholder'
Assert-Contains $rules 'next((item for item in fallbacks if item != items[0])' 'single custom upstream gets an independent fallback'
Assert-Contains $install 'parsed.scheme not in {"https", "tls", "udp", "tcp"}' 'encrypted upstream URL validation'
Assert-Contains $readme 'REMOTE_DNS' 'README documents remote DNS variable'
Assert-Contains $readme 'LOCAL_DNS' 'README documents local DNS variable'
Assert-Contains $readme 'DNS_UPSTREAMS' 'README documents legacy DNS alias'

Write-Output "custom DNS markers OK"
