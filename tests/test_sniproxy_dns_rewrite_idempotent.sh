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

mkdir -p "${tmp}/etc/mosdns" "${tmp}/opt/etc"
cat > "${tmp}/sniproxy.conf" <<'EOF'
user pxout
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 9.9.9.9
    mode ipv4_only
}

listener 80 {
    proto http
}
EOF
cat > "${tmp}/update-mosdns-rules.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/update-mosdns-rules.sh"

script="${tmp}/install-wrapper.sh"
# install.sh sources lib/host-setup.sh relative to its own directory.
ln -s "${root}/lib" "${tmp}/lib"
sed \
  -e "s#/etc/sniproxy.conf#${tmp}/sniproxy.conf#g" \
  -e "s#/etc/mosdns#${tmp}/etc/mosdns#g" \
  -e "s#/opt/proxy-gateway/etc#${tmp}/opt/etc#g" \
  -e "s#/usr/local/bin/update-mosdns-rules.sh#${tmp}/update-mosdns-rules.sh#g" \
  "${root}/install.sh" > "${script}"
chmod +x "${script}"

# G5PNX_BOOTSTRAPPED prevents the wrapper (which lives outside the repo and has
# no lib/) from re-execing a freshly downloaded install.sh: that pristine copy
# would ignore every sed-redirected path above and write to the REAL host
# config (/etc/mosdns, systemctl restart mosdns, ...).
export G5PNX_BOOTSTRAPPED=1
PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns \
  "1.1.1.1 8.8.8.8 9.9.9.9" \
  "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29"
PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns \
  "1.1.1.1 8.8.8.8 9.9.9.9" \
  "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29"

grep -q 'nameserver 1.1.1.1' "${tmp}/sniproxy.conf" || { echo "sniproxy remote DNS missing" >&2; exit 1; }
grep -q 'nameserver 8.8.8.8' "${tmp}/sniproxy.conf" || { echo "sniproxy secondary remote DNS missing" >&2; exit 1; }
grep -q 'mode ipv4_only' "${tmp}/sniproxy.conf" || { echo "sniproxy ipv4_only missing" >&2; exit 1; }
[[ "$(grep -c '^resolver {$' "${tmp}/sniproxy.conf")" -eq 1 ]] || { echo "resolver block duplicated" >&2; exit 1; }

echo "sniproxy DNS rewrite idempotency OK"
