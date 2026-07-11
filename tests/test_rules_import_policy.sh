#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
conv="${root}/lib/rules-import.py"
gen="${root}/lib/mihomo-router-config.py"
install_body="$(cat "${root}/install.sh")"
fail() { echo "$1" >&2; exit 1; }

[[ -f "${conv}" ]] || fail "rules-import.py must exist"
python3 -m py_compile "${conv}" || fail "rules-import.py must compile"

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
cat > "${tmp}/rules.conf" <<'S'
[Rule]
DOMAIN-SUFFIX,google.com,AI
PROCESS-NAME,/Applications/Foo.app,AI
IP-CIDR,1.2.3.0/24,"📕 小红书",no-resolve
OR,((DOMAIN,a.com), (SRC-IP,192.168.1.1), (DOMAIN-SUFFIX,b.com)),Proxy
RULE-SET,https://example.com/x.list,Netflix,"update-interval=86400"
FINAL,Proxy
S
out="$(python3 "${conv}" "${tmp}/rules.conf" 2>"${tmp}/err")"
grep -q 'PROCESS-NAME' <<<"$out" && fail "PROCESS-NAME must be dropped"
grep -q 'SRC-IP' <<<"$out" && fail "SRC-IP must be dropped"
grep -qx 'DOMAIN,a.com,Proxy' <<<"$out" || fail "OR domain member must be kept"
grep -qx 'DOMAIN-SUFFIX,b.com,Proxy' <<<"$out" || fail "OR suffix member must be kept"
grep -qx 'IP-CIDR,1.2.3.0/24,小红书' <<<"$out" || fail "modifiers/quotes/emoji must normalize"
grep -qx 'RULE-SET,https://example.com/x.list,Netflix' <<<"$out" || fail "RULE-SET must survive"
grep -qx 'FINAL,Proxy' <<<"$out" || fail "FINAL must survive"
grep -q 'CATEGORIES=' "${tmp}/err" || fail "converter must report categories"

mkdir -p "${tmp}/exits" "${tmp}/wg" "${tmp}/rs"
printf '{"proxies":[{"name":"out","type":"socks5","server":"1.1.1.1","port":1080,"udp":true}]}' > "${tmp}/exits/att.yaml"
printf 'DOMAIN-SUFFIX,openai.com,AI\nDOMAIN-SUFFIX,ad.net,Advertising\nFINAL,AI\n' > "${tmp}/rules.conf"
printf 'AI=att\nAdvertising=block\n' > "${tmp}/pm.conf"
cfg="$(EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg" PGW_RULESET_CACHE="${tmp}/rs" PGW_POLICY_MAP="${tmp}/pm.conf" python3 "${gen}" "${tmp}/rules.conf")"
python3 - "$cfg" <<'PY'
import json, sys
c = json.loads(sys.argv[1])
assert [p["name"] for p in c["proxies"]] == ["att"]
assert "DOMAIN-SUFFIX,openai.com,att" in c["rules"]
assert "DOMAIN-SUFFIX,ad.net,REJECT" in c["rules"]
assert c["rules"][-1] == "MATCH,att"
print("policy resolution OK")
PY

for m in 'import_rules()' 'set_policy()' 'regen_smart()' 'init_policy_map()' '--import-rules)' '--set-policy)'; do
    [[ "${install_body}" == *"${m}"* ]] || fail "install.sh missing: ${m}"
done
[[ "${install_body}" == *'Policy rejected; previous policy restored'* ]] || fail "set-policy must roll back on a failed rebuild"
[[ "${install_body}" == *'Rename rejected; previous rules and policy restored'* ]] || fail "rename-policy must roll back on a failed rebuild"

echo "rules import policy OK"
