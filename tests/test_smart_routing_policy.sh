#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
gen="${root}/lib/mihomo-router-config.py"
install_body="$(cat "${install}")"
fail() { echo "$1" >&2; exit 1; }

[[ -f "${gen}" ]] || fail "mihomo-router-config.py must exist"
python3 -m py_compile "${gen}" || fail "mihomo-router-config.py must compile"

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/exits" "${tmp}/rs" "${tmp}/wg"
printf '{"proxies":[{"name":"out","type":"socks5","server":"1.1.1.1","port":1080,"udp":true}]}' > "${tmp}/exits/us.yaml"
printf 'a.com\n+.b.com\nDOMAIN-SUFFIX,c.com\n' > "${tmp}/dev.list"
cat > "${tmp}/rules.conf" <<R
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,direct
RULE-SET,${tmp}/dev.list,us
RULE-SET,https://example.com/remote.list,us
RULE-SET,https://example.com/ambiguous.yaml#domain,us
GEOSITE,telegram,us
GEOIP,cn,direct
FINAL,block
R
out="$(EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" PGW_RULESET_CACHE="${tmp}/rs" python3 "${gen}" "${tmp}/rules.conf")"
python3 - "$out" <<'PY'
import json, sys
c = json.loads(sys.argv[1])
assert [p["name"] for p in c["proxies"]] == ["us"]
assert c["tun"]["device"] == "pgw-smart" and c["tun"]["auto-route"] is False
assert c["sniffer"]["enable"] and c["sniffer"]["override-destination"]
assert c["rules"][0] == "DOMAIN-SUFFIX,google.com,us", "order not preserved"
assert c["rules"][-1] == "MATCH,REJECT"
providers = c["rule-providers"]
assert any(k.startswith("geosite_") and v["format"] == "mrs" and v["behavior"] == "domain" for k,v in providers.items())
assert any(k.startswith("geoip_") and v["format"] == "mrs" and v["behavior"] == "ipcidr" for k,v in providers.items())
assert any(v["type"] == "file" and v["behavior"] == "classical" for v in providers.values())
assert any(v["type"] == "http" and v["format"] == "text" and v["interval"] == 86400 for v in providers.values())
assert any(v["type"] == "http" and v["format"] == "yaml" and v["behavior"] == "domain" for v in providers.values())
PY
ls "${tmp}/rs"/*.json >/dev/null 2>&1 || fail "local list must be cached as a classical provider"

printf 'RULE-SET,https://example.com/old.srs,us\n' > "${tmp}/bad.conf"
if EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" python3 "${gen}" "${tmp}/bad.conf" >/dev/null 2>&1; then
    fail "sing-box .srs must be rejected with a migration error"
fi
printf 'not-a-real-mrs' > "${tmp}/geoip-local.mrs"
printf 'RULE-SET,%s/geoip-local.mrs#ipcidr,us\n' "${tmp}" > "${tmp}/local-mrs.conf"
out="$(EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" PGW_RULESET_CACHE="${tmp}/rs" python3 "${gen}" "${tmp}/local-mrs.conf")"
grep -q '"behavior": "ipcidr"' <<<"$out" || fail "local .mrs must honor #ipcidr"
printf 'DOMAIN-SUFFIX,example.com,typo-exit\n' > "${tmp}/bad.conf"
if EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" python3 "${gen}" "${tmp}/bad.conf" >/dev/null 2>&1; then
    fail "unknown rule targets must not silently fall back to direct"
fi

[[ "${install_body}" == *'set_rules()'* && "${install_body}" == *'add_rule()'* && "${install_body}" == *'add_ruleset()'* ]] || fail "rule management functions missing"
[[ "${install_body}" == *'--set-rules)'* && "${install_body}" == *'--add-rule)'* && "${install_body}" == *'--add-ruleset)'* ]] || fail "rule dispatch missing"
[[ "${install_body}" == *'mihomo-router-config.py'* ]] || fail "mihomo router generator wiring missing"
[[ "${install_body}" == *'systemctl restart "5gpn-mihomo@smart.service"'* ]] || fail "smart must reload through mihomo"
[[ "${install_body}" == *'Rules rejected; previous rules restored'* ]] || fail "set-rules must roll back invalid input"
[[ "${install_body}" == *'reserved exit name'* ]] || fail "smart/local must be reserved"
[[ "${install_body}" == *'exit_reachable()'* && "${install_body}" == *'preflight_exit()'* ]] || fail "exit preflight missing"

echo "smart routing policy OK"
