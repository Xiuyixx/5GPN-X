#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell variables.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
gen="${root}/mihomo-exit-config.py"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

[[ -f "${gen}" ]] || fail "mihomo-exit-config.py must exist"
python3 -m py_compile "${gen}" || fail "mihomo-exit-config.py must compile"

out="$(python3 "${gen}" us 'socks5://u:p@1.2.3.4:1080')"
python3 - "$out" <<'PY'
import json, sys
c = json.loads(sys.argv[1])
assert c["tun"]["enable"] and c["tun"]["device"] == "pgw-us"
assert c["tun"]["stack"] == "gvisor"
assert c["tun"]["auto-route"] is False and c["tun"]["auto-redirect"] is False
p = c["proxies"][0]
assert p["type"] == "socks5" and p["username"] == "u" and p["password"] == "p"
assert c["rules"] == ["MATCH,out"]
assert "sniffer" not in c
PY

# Passwords are parsed from the rightmost @ and JSON-escaped verbatim.
out="$(python3 "${gen}" us 'socks5://myuser:p@ss:w/r#d?x %z@198.51.100.7:1080')"
python3 - "$out" <<'PY'
import json, sys
p = json.loads(sys.argv[1])["proxies"][0]
assert p["server"] == "198.51.100.7"
assert p["username"] == "myuser" and p["password"] == "p@ss:w/r#d?x %z"
PY
out="$(PGW_USER='bob' PGW_PASS='p@ss:w/rd#1?' python3 "${gen}" us 'socks5://1.2.3.4:1080')"
python3 - "$out" <<'PY'
import json, sys
p = json.loads(sys.argv[1])["proxies"][0]
assert p["username"] == "bob" and p["password"] == "p@ss:w/rd#1?"
PY
[[ "${install_body}" == *'PGW_USER="$px_user" PGW_PASS="$px_pass"'* ]] || fail "add_exit must pass out-of-band credentials"

ui="$(printf 'aes-256-gcm:pw' | base64)"
out="$(python3 "${gen}" hk "ss://${ui}@5.6.7.8:8388")"
python3 - "$out" <<'PY'
import json, sys
p = json.loads(sys.argv[1])["proxies"][0]
assert p["type"] == "ss" and p["cipher"] == "aes-256-gcm"
PY
out="$(python3 "${gen}" sg 'ss://2022-blake3-aes-128-gcm:GsEqQ8x6m1bF9o2k3J4mNQ==@9.9.9.9:443')"
grep -q '"cipher": "2022-blake3-aes-128-gcm"' <<<"$out" || fail "SS2022 cipher must be parsed"

out="$(python3 "${gen}" us 'socks5h://1.2.3.4:1080')"
python3 - "$out" <<'PY'
import json, sys
s = json.loads(sys.argv[1])["sniffer"]
assert s["enable"] and s["override-destination"]
PY
out="$(PGW_REMOTE_DNS=on python3 "${gen}" us 'socks5://1.2.3.4:1080')"
grep -q '"sniffer"' <<<"$out" || fail "PGW_REMOTE_DNS must enable sniffing"
[[ "${install_body}" == *'PGW_REMOTE_DNS="$px_rdns"'* ]] || fail "add_exit must pass remote DNS toggle"

for uri in \
  "trojan://pw@example.com:443?sni=example.com" \
  "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com" \
  "hysteria2://pw@example.com:443?sni=example.com" \
  "tuic://00000000-0000-0000-0000-000000000000:pw@example.com:443?sni=example.com" \
  "anytls://pw@example.com:443?sni=example.com" \
  "http://u:p@example.com:8080"; do
  out="$(python3 "${gen}" us "$uri")"
  grep -q '"server": "example.com"' <<<"$out" || fail "URI must parse server: $uri"
done
vmess_payload='eyJhZGQiOiJleGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMCIsImFpZCI6IjAiLCJuZXQiOiJ3cyIsInRscyI6InRscyIsInNuaSI6ImV4YW1wbGUuY29tIiwicGF0aCI6Ii9wIn0='
out="$(python3 "${gen}" us "vmess://${vmess_payload}")"
grep -q '"type": "vmess"' <<<"$out" || fail "vmess URI must yield a vmess proxy"
if python3 "${gen}" us 'ftp://x' >/dev/null 2>&1; then fail "generator must reject unsupported URIs"; fi

for m in 'ensure_mihomo()' 'exit_type()' 'exit_up()' 'exit_down()' 'install_mihomo_unit()' 'exit_wait_device()' 'migrate_singbox_exits()'; do
    [[ "${install_body}" == *"${m}"* ]] || fail "install.sh missing function: ${m}"
done
[[ "${install_body}" == *'MIHOMO_VERSION_DEFAULT="1.19.28"'* ]] || fail "mihomo version must be locked"
[[ "${install_body}" == *'proxy-gateway-mihomo@'* ]] || fail "mihomo systemd template missing"
[[ "${install_body}" == *'mihomo-exit-config.py'* ]] || fail "mihomo generator wiring missing"
[[ "${install_body}" == *'systemctl start "proxy-gateway-mihomo@${current}.service"'* ]] || fail "apply-exit must start mihomo"
[[ "${install_body}" == *'ip route replace default dev'* ]] || fail "exit must route through pgw device"
[[ "${install_body}" != *'SINGBOX_VERSION_DEFAULT'* ]] || fail "sing-box runtime must be removed"
[[ "${install_body}" != *'ensure_singbox()'* ]] || fail "sing-box runtime function must be removed"
[[ "${install_body}" == *'[[ $current_removed -eq 1 ]]'* ]] || fail "migration must preserve an active WireGuard exit"

echo "exit proxy types policy OK"
