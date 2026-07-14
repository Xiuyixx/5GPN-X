$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installPath = Join-Path $root "install.sh"
# Firewall/tuning helpers moved to lib/host-setup.sh (sourced by install.sh).
$install = (Get-Content -Path $installPath -Raw -Encoding UTF8) + (Get-Content -Path (Join-Path $root "lib/host-setup.sh") -Raw -Encoding UTF8)

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $install.Contains($Needle)) {
        throw "Missing tuning marker: $Description ($Needle)"
    }
}

Assert-Contains 'net.core.default_qdisc=fq' 'fq queue discipline'
# sysctl heavy values are now scaled by profile; assert the templated line and
# the standard-profile (large) values, plus the low-memory shrink.
Assert-Contains 'net.core.somaxconn=${sy_somaxconn}' 'templated accept backlog'
Assert-Contains 'sy_somaxconn=10240000' 'standard-profile large accept backlog'
Assert-Contains 'sy_somaxconn=4096' 'low-memory shrink of accept backlog'
Assert-Contains 'net.ipv4.tcp_fastopen=1027' 'aggressive TCP fast open'
Assert-Contains 'net.ipv4.tcp_rmem=8192 65536 ${sy_buf_max}' 'templated TCP receive buffer'
Assert-Contains 'net.ipv4.tcp_wmem=8192 131072 ${sy_buf_max}' 'templated TCP send buffer'
Assert-Contains 'sy_buf_max=134217728' 'standard-profile large TCP buffers'
Assert-Contains 'net.netfilter.nf_conntrack_max=${sy_conntrack_max}' 'templated conntrack table'
Assert-Contains 'sy_conntrack_max=10240000' 'standard-profile large conntrack table'
Assert-Contains 'disable-transparent-huge-pages.service' 'THP disable service'
Assert-Contains 'SystemMaxUse=384M' 'journald bounded disk usage'

Write-Output "install tuning markers OK"
