#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin"
cat > "${tmp}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/systemctl"

mkdir -p "${tmp}/etc/dnsdist" "${tmp}/opt/etc" "${tmp}/systemd"
cat > "${tmp}/sniproxy.conf" <<'EOF'
user pxout
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 22.22.22.22
    mode ipv4_only
}

listener 80 {
    proto http
}
EOF
cat > "${tmp}/update-dnsdist-rules.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/update-dnsdist-rules.sh"

script="${tmp}/install-wrapper.sh"
sed \
  -e "s#/etc/sniproxy.conf#${tmp}/sniproxy.conf#g" \
  -e "s#/etc/dnsdist#${tmp}/etc/dnsdist#g" \
  -e "s#/opt/proxy-gateway/etc#${tmp}/opt/etc#g" \
  -e "s#/etc/systemd/system/china-dns-race-proxy.service#${tmp}/systemd/china-dns-race-proxy.service#g" \
  -e "s#/usr/local/bin/update-dnsdist-rules.sh#${tmp}/update-dnsdist-rules.sh#g" \
  "${root}/install.sh" > "${script}"
chmod +x "${script}"

PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns "22.22.22.22" "223.5.5.5"
PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns "22.22.22.22" "223.5.5.5"

grep -q 'nameserver 22.22.22.22' "${tmp}/sniproxy.conf" || { echo "sniproxy DNS missing" >&2; exit 1; }
grep -q 'mode ipv4_only' "${tmp}/sniproxy.conf" || { echo "sniproxy ipv4_only missing" >&2; exit 1; }
[[ "$(grep -c '^resolver {$' "${tmp}/sniproxy.conf")" -eq 1 ]] || { echo "resolver block duplicated" >&2; exit 1; }

echo "sniproxy DNS rewrite idempotency OK"
