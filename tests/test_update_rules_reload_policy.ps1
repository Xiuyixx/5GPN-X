$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$rules = Get-Content -Path (Join-Path $root "lib/update-rules.sh") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $rules.Contains($Needle)) {
        throw "Missing update-rules reload marker: $Description ($Needle)"
    }
}

Assert-Contains 'ensure_dnsdist_active()' 'post-reload active check function'
Assert-Contains 'dnsdist is not active after reload, restarting' 'restart message after inactive reload'
Assert-Contains 'systemctl restart dnsdist' 'dnsdist restart fallback'

Write-Output "update-rules reload markers OK"
