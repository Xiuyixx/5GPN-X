$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$templatePath = Join-Path $root "dnsdist.conf.template"
$template = Get-Content -Path $templatePath -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $template.Contains($Needle)) {
        throw "Missing policy marker: $Description ($Needle)"
    }
}

Assert-Contains 'MaxQPSIPRule(10000)' 'per-IP QPS limit raised to 10000'
Assert-Contains 'setACL({"0.0.0.0/0", "::/0"})' 'global dnsdist ACL allows DoT clients before rule-level filtering'
Assert-Contains 'privateClientRule = makeRule({"172.22.0.0/16"})' 'private source network rule'
Assert-Contains 'nonPrivateClientRule = NotRule(privateClientRule)' 'non-private source rule'
Assert-Contains 'AndRule({nonPrivateClientRule, DSTPortRule(53)})' 'DNS/53 whitelist drop condition'
Assert-Contains 'addAction(QTypeRule(DNSQType.AAAA), RCodeAction(DNSRCode.NOERROR))' 'global IPv4-only AAAA NODATA response'
Assert-Contains 'AndRule({privateClientRule, LuaRule(function(dq) return gfwList:check(dq.qname) end), QTypeRule(DNSQType.A)})' 'private-client GFW A spoof'
Assert-Contains 'AndRule({privateClientRule, QTypeRule(DNSQType.A)}), SpoofAction(serverIP)' 'private-client default overseas A spoof'
Assert-Contains 'everything else enters the gateway and is sent through the selected exit' 'private-client default overseas proxy rationale'
Assert-Contains '__REMOTE_DNS_SERVERS__' 'remote DNS pool placeholder'
Assert-Contains 'AndRule({privateClientRule, AllRule()})' 'private clients keep a fallback remote pool for non-A queries'
Assert-Contains 'AndRule({nonPrivateClientRule, AllRule()})' 'non-private clients default to remote pool'
Assert-Contains 'PoolAction("remote")' 'remote pool action'
Assert-Contains 'local neutralECSv4 = "0.0.0.0/0"' 'neutral overseas IPv4 ECS'
Assert-Contains 'local neutralECSv6 = "::/0"' 'neutral overseas IPv6 ECS'
Assert-Contains 'AndRule({privateClientRule, AllRule()}), SetECSAction(neutralECSv4, neutralECSv6)' 'private overseas neutral ECS'
Assert-Contains 'AndRule({nonPrivateClientRule, AllRule()}), SetECSAction(neutralECSv4, neutralECSv6)' 'public overseas neutral ECS'
Assert-Contains 'AndRule({privateClientRule, AllRule()}), SetECSOverrideAction(true)' 'private overseas ECS override'
Assert-Contains 'AndRule({nonPrivateClientRule, AllRule()}), SetECSOverrideAction(true)' 'public overseas ECS override'
Assert-Contains 'remoteCache' 'remote cache is configured'

Write-Output "dnsdist policy markers OK"
