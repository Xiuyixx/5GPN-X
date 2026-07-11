$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$template = Get-Content -Path (Join-Path $root "lib/dnsdist.conf.template") -Raw -Encoding UTF8
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

Assert-Contains $install 'DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8")' 'default remote DNS array'
Assert-Contains $install 'DEFAULT_LOCAL_DNS=("223.5.5.5" "119.29.29.29")' 'default local DNS array'
Assert-Contains $install 'configure_dns_upstreams()' 'installer DNS function'
Assert-Contains $install 'REMOTE_DNS' 'installer remote DNS variable'
Assert-Contains $install 'LOCAL_DNS' 'installer local DNS variable'
Assert-Contains $install '/etc/dnsdist/.remote_dns' 'installer saves remote DNS config'
Assert-Contains $install '/etc/dnsdist/.local_dns' 'installer saves local DNS config'
Assert-Contains $install 'china-dns-race-proxy -l 127.0.0.1:5301 -upstreams' 'installer passes local DNS to China DNS race proxy'
Assert-Contains $template '__REMOTE_DNS_SERVERS__' 'dnsdist remote server placeholder'
Assert-Contains $rules '.remote_dns' 'rule updater reads saved remote DNS config'
Assert-Contains $rules '__REMOTE_DNS_SERVERS__' 'rule updater replaces remote placeholder'
Assert-Contains $rules 'useClientSubnet=true' 'remote upstreams can receive neutral ECS'
Assert-Contains $readme 'REMOTE_DNS' 'README documents remote DNS variable'
Assert-Contains $readme 'LOCAL_DNS' 'README documents local DNS variable'
Assert-Contains $readme 'DNS_UPSTREAMS' 'README documents legacy DNS alias'

Write-Output "custom DNS markers OK"
