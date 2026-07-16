$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# Firewall/tuning helpers moved to lib/host-setup.sh (sourced by install.sh).
$install = (Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8) + (Get-Content -Path (Join-Path $root "lib/host-setup.sh") -Raw -Encoding UTF8)
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing reverse proxy firewall marker: $Description ($Needle)"
    }
}

Assert-Contains $install 'ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept' 'nft TCP reverse proxy private allow'
Assert-Contains $install 'ip saddr 172.22.0.0/16 udp dport 443 accept' 'nft UDP reverse proxy private allow'
Assert-Contains $install 'tcp dport 853 meter dns_rate_dot' 'nft DoT per-IP QPS rate limit'
Assert-Contains $install 'meter dns_rate_tcp53' 'nft DNS TCP per-IP QPS rate limit'
Assert-Contains $install 'meter dns_rate_udp53' 'nft DNS UDP per-IP QPS rate limit'
Assert-Contains $install 'iptables -A INPUT -s 172.22.0.0/16 -p tcp -m multiport --dports 53,80,443 -j ACCEPT' 'iptables TCP reverse proxy + DNS private allow'
Assert-Contains $install 'iptables -A INPUT -s 172.22.0.0/16 -p udp -m multiport --dports 53,443 -j ACCEPT' 'iptables UDP DNS + reverse proxy private allow'
Assert-Contains $install 'hashlimit-name dns_dot' 'iptables DoT per-IP QPS rate limit'
Assert-Contains $install 'iptables -F INPUT' 'iptables fallback flushes stale public reverse proxy rules'
Assert-Contains $install '--comment 5gpn-cert-http' 'temporary HTTP rule is tagged'
Assert-Contains $install 'open_cert_http_port()' 'cert flow opens HTTP-01 port temporarily'
Assert-Contains $install 'restore_reverse_proxy_firewall()' 'cert flow restores reverse proxy whitelist'
Assert-Contains $install '--pre-hook /usr/local/bin/5gpn-open-cert-http.sh' 'certbot pre-hook opens port 80'
Assert-Contains $install '--post-hook /usr/local/bin/5gpn-restore-firewall.sh' 'certbot post-hook restores firewall'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/pre/10-5gpn-open-http.sh' 'automatic renew pre-hook'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/post/90-5gpn-restore-firewall.sh' 'automatic renew post-hook'
Assert-Contains $install 'Firewall configured (reverse proxy whitelist: 172.22.0.0/16)' 'firewall status message'
Assert-Contains $readme '172.22.0.0/16' 'README documents reverse proxy whitelist'
Assert-Contains $readme '80/443' 'README documents reverse proxy ports'
Assert-Contains $readme '443' 'README documents reverse proxy port'

Write-Output "reverse proxy firewall markers OK"
