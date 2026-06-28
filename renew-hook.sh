#!/bin/bash
# Let's Encrypt renewal hook - copy certs to dnsdist-readable location and reload
set -e

# Find the most recently updated live directory
LIVE_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d | grep -v "^/etc/letsencrypt/live$" | head -n1)
if [[ -z "$LIVE_DIR" ]]; then
    echo "[!] No certificate live directory found"
    exit 1
fi

mkdir -p /etc/dnsdist/certs
cp "${LIVE_DIR}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
cp "${LIVE_DIR}/privkey.pem" /etc/dnsdist/certs/privkey.pem
chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
chmod 640 /etc/dnsdist/certs/*.pem

if systemctl is-active --quiet dnsdist; then
    systemctl restart dnsdist   # dnsdist can't hot-reload (SIGHUP exits it); restart applies the new cert
fi
