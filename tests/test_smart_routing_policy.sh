#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
gen="${root}/singbox-router-config.py"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

# --- router config generator -------------------------------------------------
[[ -f "${gen}" ]] || fail "singbox-router-config.py must exist"
python3 -m py_compile "${gen}" || fail "singbox-router-config.py must compile"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/exits" "${tmp}/rs"
printf '{"outbounds":[{"type":"socks","tag":"out","server":"1.1.1.1","server_port":1080,"version":"5"}]}' > "${tmp}/exits/us.json"
printf 'a.com\n+.b.com\nDOMAIN-SUFFIX,c.com\n' > "${tmp}/dev.list"
cat > "${tmp}/rules.conf" <<R
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,direct
RULE-SET,${tmp}/dev.list,us
GEOSITE,telegram,us
GEOIP,cn,direct
FINAL,block
R
out="$(EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" PGW_RULESET_CACHE="${tmp}/rs" python3 "${gen}" "${tmp}/rules.conf")"

python3 - "$out" <<'PY'
import json, sys
c = json.loads(sys.argv[1])
tags = [o["tag"] for o in c["outbounds"]]
assert "us" in tags and "direct" in tags and "block" in tags, "outbounds: %s" % tags
r = c["route"]
assert r["final"] == "block", "final should be block"
# first-match order preserved
assert r["rules"][0].get("domain_suffix") == ["google.com"], "order not preserved"
rstags = [x["tag"] for x in r.get("rule_set", [])]
assert any(t.startswith("geosite_") for t in rstags), "geosite rule-set missing"
assert any(t.startswith("geoip_") for t in rstags), "geoip rule-set missing"
assert any(x["type"] == "local" for x in r["rule_set"]), "local list rule-set missing"
remote = [x for x in r["rule_set"] if x["type"] == "remote"]
assert all(x.get("download_detour") == "direct" for x in remote), "remote rule-set needs download_detour=direct"
tun = c["inbounds"][0]
assert tun["sniff"] and tun.get("sniff_override_destination"), "router TUN must sniff for domains"
assert tun["interface_name"] == "pgw-smart", "router device must be pgw-smart"
print("router config OK")
PY

# local list must have been converted to a sing-box source rule-set
ls "${tmp}/rs"/*.json >/dev/null 2>&1 || fail "local list must become a source rule-set file"

# --- install.sh wiring -------------------------------------------------------
[[ "${install_body}" == *'set_rules()'* ]]   || fail "install.sh must define set_rules"
[[ "${install_body}" == *'--set-rules)'* ]]  || fail "install.sh must dispatch --set-rules"
[[ "${install_body}" == *'singbox-router-config.py'* ]] || fail "install.sh must install the router generator"
# 'smart' must be a reserved name and a sing-box-managed (router) type.
[[ "${install_body}" == *'reserved exit name'* ]] || fail "smart/local must be reserved"
[[ "${install_body}" == *'shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http|router)'* ]] || fail "router type must be brought up via sing-box"

[[ "${install_body}" == *'exit_reachable()'* ]] || fail "must have exit reachability check"
[[ "${install_body}" == *'preflight_exit()'* ]] || fail "must warn on unreachable exits when activating"
echo "smart routing policy OK"
