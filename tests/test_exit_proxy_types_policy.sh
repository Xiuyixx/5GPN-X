#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
gen="${root}/singbox-exit-config.py"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

# --- URI -> sing-box config generator ---------------------------------------
[[ -f "${gen}" ]] || fail "singbox-exit-config.py must exist"
python3 -m py_compile "${gen}" || fail "singbox-exit-config.py must compile"

# Default TUN stack must be gvisor — the "system" stack does not forward on
# many kernels (caused silent exit failure in testing).
grep -q '"stack": "gvisor"' <<<"$(python3 "${gen}" us 'socks5://1.2.3.4:1080')" \
    || fail "default TUN stack must be gvisor"
# sing-box restart recreates the TUN and drops the table-100 route; the unit
# must re-apply it on (re)start.
[[ "${install_body}" == *'ExecStartPost=-/usr/local/bin/proxy-gateway-apply-exit.sh'* ]] \
    || fail "singbox unit must re-apply the exit route on (re)start"

[[ "${install_body}" == *'SINGBOX_VERSION_DEFAULT="1.12.25"'* ]] || fail "sing-box default version must be locked to 1.12.25"
[[ "${install_body}" == *'ver="${SINGBOX_VERSION:-${SINGBOX_VERSION_DEFAULT}}"'* ]] || fail "ensure_singbox must use the locked default unless explicitly overridden"
[[ "${install_body}" == *'systemctl start "proxy-gateway-singbox@${name}.service"'* ]] || fail "set-exit must start an existing sing-box exit without restarting its new TUN"
[[ "${install_body}" == *'ip link show up "$iface"'* ]] || fail "set-exit must wait for the exit device to be UP before routing"
[[ "${install_body}" == *'ip link show up "${iface}"'* ]] || fail "apply-exit helper must wait for the exit device to be UP before routing"
[[ "${install_body}" == *"device is not up"* ]] || fail "apply-exit helper must fail clearly if the exit device is still down"

# socks5 with auth
out="$(python3 "${gen}" us 'socks5://u:p@1.2.3.4:1080')"
grep -q '"type": "socks"' <<<"$out"        || fail "socks5 URI must yield a socks outbound"
grep -q '"username": "u"' <<<"$out"         || fail "socks5 URI auth must set username"
grep -q '"password": "p"' <<<"$out"         || fail "socks5 URI auth must set password"
grep -q '"interface_name": "pgw-us"' <<<"$out" || fail "TUN device must be pgw-<name>"

# socks5 single-line password with special chars (@ : / # ? % space) verbatim.
out="$(python3 "${gen}" us 'socks5://myuser:p@ss:w/r#d?x %z@198.51.100.7:1080')"
grep -q '"server": "198.51.100.7"' <<<"$out"      || fail "must parse host:port from the rightmost @"
grep -q '"username": "myuser"' <<<"$out"          || fail "username = up to first colon"
grep -Fq '"password": "p@ss:w/r#d?x %z"' <<<"$out" || fail "single-line special-char password must be literal"

# socks5 out-of-band credentials (special chars, no URL-encoding) must win.
out="$(PGW_USER='bob' PGW_PASS='p@ss:w/rd#1?' python3 "${gen}" us 'socks5://1.2.3.4:1080')"
grep -q '"username": "bob"' <<<"$out"        || fail "PGW_USER must set the socks username"
grep -Fq '"password": "p@ss:w/rd#1?"' <<<"$out" || fail "PGW_PASS must set a special-char password verbatim"
# install.sh must extract user:/pass: lines and pass them to the generator.
[[ "${install_body}" == *'PGW_USER="$px_user" PGW_PASS="$px_pass"'* ]] || fail "add_exit must pass out-of-band socks creds to the generator"

# shadowsocks SIP002
ui="$(printf 'aes-256-gcm:pw' | base64)"
out="$(python3 "${gen}" hk "ss://${ui}@5.6.7.8:8388")"
grep -q '"type": "shadowsocks"' <<<"$out"  || fail "ss URI must yield a shadowsocks outbound"
grep -q '"method": "aes-256-gcm"' <<<"$out" || fail "ss method must be parsed"

# Shadowsocks 2022 (plaintext method:password userinfo)
out="$(python3 "${gen}" sg 'ss://2022-blake3-aes-128-gcm:GsEqQ8x6m1bF9o2k3J4mNQ==@9.9.9.9:443')"
grep -q '"method": "2022-blake3-aes-128-gcm"' <<<"$out" || fail "SS2022 method must be parsed"

# socks5 (default) must NOT sniff; socks5h (remote DNS) must sniff+override.
out="$(python3 "${gen}" us 'socks5://1.2.3.4:1080')"
grep -q '"sniff": false' <<<"$out"          || fail "socks5 must use local DNS (no sniff)"
out="$(python3 "${gen}" us 'socks5h://1.2.3.4:1080')"
grep -q '"sniff": true' <<<"$out"           || fail "socks5h must enable sniff (remote DNS)"
grep -q '"sniff_override_destination": true' <<<"$out" || fail "socks5h must override destination with the sniffed domain"
# remote-dns toggle via env must also work (e.g. for ss).
out="$(PGW_REMOTE_DNS=on python3 "${gen}" us 'socks5://1.2.3.4:1080')"
grep -q '"sniff": true' <<<"$out"           || fail "PGW_REMOTE_DNS must enable remote DNS"
# install.sh must detect socks5h and pass the remote-dns toggle to the generator.
[[ "${install_body}" == *'socks5h://'* ]]   || fail "add_exit must recognise socks5h URIs"
[[ "${install_body}" == *'PGW_REMOTE_DNS="$px_rdns"'* ]] || fail "add_exit must pass the remote-dns toggle to the generator"

# additional proxy schemes
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
grep -q '"type": "vmess"' <<<"$out" || fail "vmess URI must yield a vmess outbound"

# unsupported scheme must error
if python3 "${gen}" us 'ftp://x' >/dev/null 2>&1; then fail "generator must reject unsupported URIs"; fi

# --- install.sh wiring -------------------------------------------------------
for m in 'ensure_singbox()' 'exit_type()' 'exit_up()' 'exit_down()' 'install_singbox_unit()' 'exit_wait_device()'; do
    [[ "${install_body}" == *"${m}"* ]] || fail "install.sh missing function: ${m}"
done
[[ "${install_body}" == *'proxy-gateway-singbox@'* ]] || fail "install.sh must define the sing-box systemd template"
[[ "${install_body}" == *'singbox-exit-config.py'* ]] || fail "install.sh must install the URI config generator"
# add_exit must branch on a proxy URI vs WireGuard (whole-line grab so passwords
# may contain special chars / spaces).
[[ "${install_body}" == *"grep -iE '^[[:space:]]*(ss|vmess|trojan|vless|hysteria2|hy2|tuic|anytls|socks5h|socks5|socks|http|https)://"* ]] || fail "add_exit must detect socks/ss URIs"
# apply-exit helper must be type-aware (start sing-box for socks/ss exits).
[[ "${install_body}" == *'proxy-gateway-singbox@${current}.service'* ]] || fail "apply-exit helper must start sing-box for socks/ss exits"
# routing layer unchanged: still routes via the pgw-<name> device.
[[ "${install_body}" == *'ip route replace default dev'* ]] || fail "exit must still route via the pgw device"

echo "exit proxy types policy OK"
