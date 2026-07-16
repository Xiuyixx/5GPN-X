$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installPath = Join-Path $root "install.sh"
$install = Get-Content -Path $installPath -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing iOS profile marker: $Description ($Needle)"
    }
}

Assert-Contains $install 'IOS_PROFILE_PORT=8111' 'iOS profile HTTP port'
Assert-Contains $install '-ios          Regenerate iOS DoT profile and QR code' 'short iOS profile CLI help'
Assert-Contains $install '-ios)' 'short iOS profile CLI dispatch'
Assert-Contains $install 'generate_ios_profile()' 'iOS profile generator function'
Assert-Contains $install 'com.apple.dnsSettings.managed' 'managed DNS settings payload'
Assert-Contains $install '<key>DNSProtocol</key>' 'DNS protocol key'
Assert-Contains $install '<string>TLS</string>' 'DoT protocol value'
Assert-Contains $install '<string>Cellular</string>' 'cellular on-demand rule'
Assert-Contains $install '<string>WiFi</string>' 'Wi-Fi on-demand rule'
Assert-Contains $install '5gpn-ios-profile.socket' 'socket-activated profile server'
Assert-Contains $install 'Accept=yes' 'inetd-style per-connection responder'
Assert-Contains $install 'qrencode -t ANSIUTF8' 'terminal QR generation'
Assert-Contains $readme ':8111/ios-dot.mobileconfig' 'README iOS install URL'
Assert-Contains $readme './install.sh -ios' 'README iOS QR command'

Write-Output "iOS profile markers OK"
