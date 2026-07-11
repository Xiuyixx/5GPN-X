#!/usr/bin/env bash
#
# exit-server-setup.sh - Turn a plain Linux VPS into a WireGuard egress "exit"
# for the proxy-gateway. Run this ON THE REMOTE VPS (as root). It installs
# WireGuard, enables NAT, and prints a ready-to-use CLIENT config block that you
# paste into the gateway with:  ./install.sh --add-exit <name> <file>
#
# Env overrides:
#   WG_PORT   WireGuard UDP listen port            (default: 51820)
#   SUBNET    /24 tunnel subnet, first 3 octets    (default: 10.66.66)
#   PUBIF     Public egress interface              (default: auto-detect)
#   PUBIP     Public IPv4 of this VPS              (default: auto-detect)
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root (sudo)"; exit 1; }

WG_PORT="${WG_PORT:-51820}"
SUBNET="${SUBNET:-10.66.66}"
WG_IF="wg-pgw"
WG_CONF="/etc/wireguard/${WG_IF}.conf"

# --- detect public interface / IP -------------------------------------------
PUBIF="${PUBIF:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -n1)}"
[[ -n "${PUBIF}" ]] || { err "Could not detect public interface; set PUBIF=..."; exit 1; }
PUBIP="${PUBIP:-$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || true)}"
[[ -n "${PUBIP}" ]] || PUBIP="$(ip -4 addr show "${PUBIF}" | grep -oP 'inet \K[\d.]+' | head -n1)"
[[ -n "${PUBIP}" ]] || { err "Could not detect public IPv4; set PUBIP=..."; exit 1; }

# --- install wireguard-tools -------------------------------------------------
if ! command -v wg >/dev/null 2>&1; then
    info "Installing wireguard-tools..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq wireguard-tools iptables
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q wireguard-tools iptables
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q wireguard-tools iptables
    else
        err "Unsupported package manager. Install wireguard-tools manually."; exit 1
    fi
fi

# --- enable forwarding -------------------------------------------------------
info "Enabling IPv4 forwarding..."
mkdir -p /etc/sysctl.d
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wg-pgw-exit.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- generate keys -----------------------------------------------------------
umask 077
mkdir -p /etc/wireguard
SRV_PRIV="$(wg genkey)"
SRV_PUB="$(printf '%s' "${SRV_PRIV}" | wg pubkey)"
CLI_PRIV="$(wg genkey)"
CLI_PUB="$(printf '%s' "${CLI_PRIV}" | wg pubkey)"

# --- write server config -----------------------------------------------------
info "Writing ${WG_CONF}..."
cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${SUBNET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SRV_PRIV}
PostUp   = iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -o ${PUBIF} -j MASQUERADE; iptables -A FORWARD -i %i -o ${PUBIF} -j ACCEPT; iptables -A FORWARD -i ${PUBIF} -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -o ${PUBIF} -j MASQUERADE; iptables -D FORWARD -i %i -o ${PUBIF} -j ACCEPT; iptables -D FORWARD -i ${PUBIF} -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT

[Peer]
# proxy-gateway client
PublicKey = ${CLI_PUB}
AllowedIPs = ${SUBNET}.2/32
EOF
chmod 600 "${WG_CONF}"

systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || {
    err "Failed to start wg-quick@${WG_IF}"; exit 1; }

# --- open firewall port (best effort) ---------------------------------------
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${WG_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

ok "Exit server is up. Public egress IP: ${PUBIP}"
echo ""
echo "=================================================================="
echo "  Paste the block below into the GATEWAY, e.g.:"
echo "    ./install.sh --add-exit <name> /path/to/this.conf"
echo "  (or run --add-exit and paste it interactively)"
echo "=================================================================="
cat <<EOF
[Interface]
PrivateKey = ${CLI_PRIV}
Address = ${SUBNET}.2/32
Table = off
MTU = 1380

[Peer]
PublicKey = ${SRV_PUB}
Endpoint = ${PUBIP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
echo "=================================================================="
warn "The client PrivateKey above is shown once. Store/transfer it securely."
