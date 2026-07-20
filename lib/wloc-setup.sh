#!/bin/bash
# 5GPN-X WLOC (Apple network-location rewriting) install + lifecycle helpers.
#
# Sourced by install.sh. Provides: dependency install, the mitmproxy sidecar
# systemd unit (one reverse listener per Apple host), CA generation (never
# rotated on reinstall), the iOS CA .mobileconfig, idempotent sniproxy and
# mosdns wiring, and the operator ctl subcommands invoked by the Telegram bot.
#
# Design notes:
#   * mitmproxy runs in reverse mode, one listener per host, so it resolves the
#     REAL Apple upstream via its own clean resolver (never the local hijack).
#       gs-loc.apple.com    -> 127.0.0.1:9080
#       gs-loc-cn.apple.com -> 127.0.0.1:9081
#   * The sidecar binds loopback only. No public port is ever opened.
#   * Coordinate rewriting is in lib/wloc-core.py (dependency-free, unit-tested);
#     the mitmproxy addon is lib/wloc-mitm.py.
#   * WLOC defaults to DISABLED: nothing is hijacked, Apple location is direct.
#     Enabling adds the two hosts to the mosdns hijack set + starts the sidecar;
#     disabling removes the hijack (fail-open back to direct).
#
# Inspired by Loading886/Home-Location-Endpoint (MIT) and
# gibaragibara/privdns-gateway-mihomo (MIT); no code copied.

# These vars are provided by install.sh when sourced; keep safe fallbacks so the
# file also shellchecks/loads standalone.
: "${BASE_DIR:=/opt/5gpn}"
: "${CONF_DIR:=${BASE_DIR}/etc}"
: "${WWW_DIR:=${BASE_DIR}/www}"
: "${LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${IOS_PROFILE_PORT:=8111}"

WLOC_USER="5gpn-wloc"
WLOC_STATE_DIR="/var/lib/5gpn-wloc"
WLOC_MITM_CONFDIR="${WLOC_STATE_DIR}/mitmproxy"
WLOC_CONFIG="${WLOC_STATE_DIR}/wloc.json"
WLOC_PRESETS="/etc/5gpn/wloc-presets.json"
WLOC_CA_CERT="${WLOC_MITM_CONFDIR}/mitmproxy-ca-cert.pem"
WLOC_CA_PROFILE="${WWW_DIR}/wloc-ca.mobileconfig"
WLOC_MITM_PORT_A=9080   # gs-loc.apple.com
WLOC_MITM_PORT_B=9081   # gs-loc-cn.apple.com
WLOC_HOST_A="gs-loc.apple.com"
WLOC_HOST_B="gs-loc-cn.apple.com"
WLOC_MITM_VERSION_PY312="mitmproxy==11.1.3"
WLOC_MITM_VERSION_PY311="mitmproxy==11.0.2"
# Set by wloc_setup_install: 0=fully provisioned, 1=needs a follow-up --wloc-setup.
: "${WLOC_SETUP_INCOMPLETE:=0}"

wloc_info() { echo -e "[INFO] $*"; }
wloc_warn() { echo -e "[WARN] $*" >&2; }
wloc_err()  { echo -e "[ERR]  $*" >&2; }

# --------------------------------------------------------------------------- #
# Dependencies
# --------------------------------------------------------------------------- #
wloc_pick_mitm_version() {
    # mitmproxy >=11.1 requires Python >=3.12; pick a version matching the host.
    local py="${1:-python3}" major minor
    major=$("$py" -c 'import sys;print(sys.version_info[0])' 2>/dev/null || echo 3)
    minor=$("$py" -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo 11)
    if [[ "$major" -ge 3 && "$minor" -ge 12 ]]; then
        echo "$WLOC_MITM_VERSION_PY312"
    else
        echo "$WLOC_MITM_VERSION_PY311"
    fi
}

wloc_install_deps() {
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    if command -v mitmdump >/dev/null 2>&1; then
        wloc_info "mitmdump already present: $(command -v mitmdump)"
        return 0
    fi
    # Prefer a distro venv so PEP 668 (externally-managed) does not block us.
    local venv="${BASE_DIR}/wloc-venv" spec
    spec="$(wloc_pick_mitm_version "$py")"
    # Ensure venv/pip build prerequisites exist. On a brand-new host the venv
    # module or pip bootstrap may be missing; installing these first is what
    # makes the very first install.sh run reliable (previously a fresh box
    # could silently fail here and skip all of WLOC).
    if ! "$py" -c 'import venv, ensurepip' >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y python3-venv python3-pip >/dev/null 2>&1 || true
    fi
    wloc_info "Installing ${spec} into ${venv} ..."
    if [[ ! -x "${venv}/bin/python3" ]]; then
        if ! "$py" -m venv "$venv" >/dev/null 2>&1; then
            apt-get install -y python3-venv >/dev/null 2>&1 || true
            "$py" -m venv "$venv" || { wloc_err "cannot create venv for mitmproxy"; return 1; }
        fi
    fi
    "${venv}/bin/pip" install --quiet --upgrade pip wheel >/dev/null 2>&1 || true
    # pip can fail transiently on a fresh box (network / index warm-up); retry
    # a couple of times with backoff before giving up.
    local attempt rc=1
    for attempt in 1 2 3; do
        if "${venv}/bin/pip" install --quiet "$spec" >/dev/null 2>&1; then
            rc=0; break
        fi
        wloc_warn "pip install ${spec} failed (attempt ${attempt}/3); retrying..."
        sleep $(( attempt * 3 ))
    done
    if [[ "$rc" -ne 0 ]]; then
        wloc_err "pip install ${spec} failed after 3 attempts"
        return 1
    fi
    if [[ ! -x "${venv}/bin/mitmdump" ]]; then
        wloc_err "mitmdump not found after install"
        return 1
    fi
    wloc_info "mitmproxy installed: $("${venv}/bin/mitmdump" --version 2>&1 | head -1)"
    return 0
}

wloc_mitmdump_bin() {
    if [[ -x "${BASE_DIR}/wloc-venv/bin/mitmdump" ]]; then
        echo "${BASE_DIR}/wloc-venv/bin/mitmdump"
    else
        command -v mitmdump 2>/dev/null || echo "${BASE_DIR}/wloc-venv/bin/mitmdump"
    fi
}

# --------------------------------------------------------------------------- #
# User, directories, config
# --------------------------------------------------------------------------- #
wloc_ensure_user() {
    if ! id "$WLOC_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$WLOC_USER" 2>/dev/null || \
            useradd --system --no-create-home --shell /bin/false "$WLOC_USER" 2>/dev/null || true
    fi
    mkdir -p "$WLOC_MITM_CONFDIR"
    mkdir -p "$(dirname "$WLOC_PRESETS")"
    chown -R "$WLOC_USER":"$WLOC_USER" "$WLOC_STATE_DIR" 2>/dev/null || true
    chmod 700 "$WLOC_STATE_DIR" "$WLOC_MITM_CONFDIR" 2>/dev/null || true
}

wloc_ensure_config() {
    # Create a disabled default config only if none exists (idempotent).
    if [[ ! -f "$WLOC_CONFIG" ]]; then
        printf '{"enabled":false,"latitude":null,"longitude":null,"accuracy":25}' > "$WLOC_CONFIG"
    fi
    chown "$WLOC_USER":"$WLOC_USER" "$WLOC_CONFIG" 2>/dev/null || true
    chmod 600 "$WLOC_CONFIG" 2>/dev/null || true
    if [[ ! -f "$WLOC_PRESETS" ]]; then
        cat > "$WLOC_PRESETS" <<'JSON'
{
  "presets": [
    {"id": "hk_wkln", "name": "香港西九龙站", "latitude": 22.303611, "longitude": 114.165, "accuracy": 25},
    {"id": "tokyo_shibuya", "name": "东京涩谷站", "latitude": 35.658514, "longitude": 139.70133, "accuracy": 25},
    {"id": "sf_ferry", "name": "旧金山渡轮大厦", "latitude": 37.795339, "longitude": -122.393051, "accuracy": 25}
  ]
}
JSON
    fi
    chmod 644 "$WLOC_PRESETS" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# CA: generate once (never rotate), export public profile
# --------------------------------------------------------------------------- #
wloc_ensure_ca() {
    local mitm; mitm="$(wloc_mitmdump_bin)"
    if [[ -f "$WLOC_CA_CERT" ]]; then
        wloc_info "WLOC CA already present; keeping existing CA (no rotation)."
    else
        wloc_info "Generating WLOC MITM CA (first install) ..."
        # A short headless run makes mitmproxy generate its CA in confdir.
        sudo -u "$WLOC_USER" env HOME="$WLOC_STATE_DIR" timeout 15 "$mitm" \
            --set confdir="$WLOC_MITM_CONFDIR" \
            --mode reverse:https://127.0.0.1:1 --listen-host 127.0.0.1 --listen-port 0 \
            >/dev/null 2>&1 || true
        if [[ ! -f "$WLOC_CA_CERT" ]]; then
            # Fallback: run as root then fix ownership.
            timeout 15 "$mitm" --set confdir="$WLOC_MITM_CONFDIR" \
                --mode reverse:https://127.0.0.1:1 --listen-host 127.0.0.1 --listen-port 0 \
                >/dev/null 2>&1 || true
        fi
    fi
    chown -R "$WLOC_USER":"$WLOC_USER" "$WLOC_MITM_CONFDIR" 2>/dev/null || true
    chmod 700 "$WLOC_MITM_CONFDIR" 2>/dev/null || true
    # CA private key stays 600 inside confdir; only the public cert is exported.
    if [[ -f "${WLOC_MITM_CONFDIR}/mitmproxy-ca.pem" ]]; then
        chmod 600 "${WLOC_MITM_CONFDIR}/mitmproxy-ca.pem" 2>/dev/null || true
    fi
    if [[ ! -f "$WLOC_CA_CERT" ]]; then
        wloc_err "WLOC CA generation failed"
        return 1
    fi
    wloc_export_ca_profile
}

wloc_export_ca_profile() {
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    mkdir -p "$WWW_DIR"
    if [[ -f "${BASE_DIR}/bin/wloc-ca-profile.py" ]]; then
        "$py" "${BASE_DIR}/bin/wloc-ca-profile.py" "$WLOC_CA_CERT" "$WLOC_CA_PROFILE" "5GPN WLOC CA" \
            >/dev/null 2>&1 || { wloc_err "CA profile generation failed"; return 1; }
    elif [[ -f "${LIB_DIR}/wloc-ca-profile.py" ]]; then
        "$py" "${LIB_DIR}/wloc-ca-profile.py" "$WLOC_CA_CERT" "$WLOC_CA_PROFILE" "5GPN WLOC CA" \
            >/dev/null 2>&1 || { wloc_err "CA profile generation failed"; return 1; }
    else
        wloc_err "wloc-ca-profile.py not found"
        return 1
    fi
    chmod 644 "$WLOC_CA_PROFILE" 2>/dev/null || true
    # The exported profile must never contain a private key.
    if grep -q "PRIVATE KEY" "$WLOC_CA_PROFILE" 2>/dev/null; then
        wloc_err "refusing: exported CA profile contains a private key"
        rm -f "$WLOC_CA_PROFILE"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# systemd sidecar unit (two reverse listeners, loopback only)
# --------------------------------------------------------------------------- #
wloc_install_service() {
    local mitm; mitm="$(wloc_mitmdump_bin)"
    local core="${BASE_DIR}/bin/wloc-core.py"
    local addon="${BASE_DIR}/bin/wloc-mitm.py"
    cat > /etc/systemd/system/5gpn-wloc.service <<EOF
[Unit]
Description=5GPN WLOC MITM sidecar (Apple network-location rewrite, loopback only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${WLOC_USER}
Environment=HOME=${WLOC_STATE_DIR}
Environment=WLOC_CORE=${core}
Environment=WLOC_CONFIG=${WLOC_CONFIG}
ExecStart=${mitm} \\
  --mode reverse:https://${WLOC_HOST_A}@127.0.0.1:${WLOC_MITM_PORT_A} \\
  --mode reverse:https://${WLOC_HOST_B}@127.0.0.1:${WLOC_MITM_PORT_B} \\
  --set confdir=${WLOC_MITM_CONFDIR} \\
  --set connection_strategy=lazy \\
  -q -s ${addon}
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${WLOC_STATE_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

wloc_sidecar_start() { systemctl enable --now 5gpn-wloc.service >/dev/null 2>&1 || systemctl restart 5gpn-wloc.service; }
wloc_sidecar_stop()  { systemctl disable --now 5gpn-wloc.service >/dev/null 2>&1 || true; }

# --------------------------------------------------------------------------- #
# sniproxy: route the two Apple hosts to the sidecar (idempotent)
# --------------------------------------------------------------------------- #
wloc_sniproxy_apply() {
    [[ -f /etc/sniproxy.conf ]] || return 0
    python3 - /etc/sniproxy.conf "$WLOC_HOST_A" "$WLOC_MITM_PORT_A" "$WLOC_HOST_B" "$WLOC_MITM_PORT_B" <<'PYEOF'
import re, sys
path, ha, pa, hb, pb = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(path, encoding="utf-8") as f:
    txt = f.read()
begin, end = "# 5gpn-wloc-begin", "# 5gpn-wloc-end"
# Remove any previous managed block first (idempotent).
txt = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", txt, flags=re.S)
block = "%s\n    %s 127.0.0.1 %s\n    %s 127.0.0.1 %s\n    %s\n" % (
    begin,
    re.escape(ha).replace("\\", "\\\\"), pa,
    re.escape(hb).replace("\\", "\\\\"), pb,
    end,
)
# Insert our explicit host entries just inside tls_hosts, BEFORE the catch-all.
m = re.search(r"(table\s+tls_hosts\s*\{\s*\n)", txt)
if not m:
    raise SystemExit("tls_hosts table not found in sniproxy.conf")
insert_at = m.end()
txt = txt[:insert_at] + "    " + block + txt[insert_at:]
with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
PYEOF
    systemctl reload sniproxy 2>/dev/null || systemctl restart sniproxy 2>/dev/null || true
}

wloc_sniproxy_remove() {
    [[ -f /etc/sniproxy.conf ]] || return 0
    python3 - /etc/sniproxy.conf <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    txt = f.read()
begin, end = "# 5gpn-wloc-begin", "# 5gpn-wloc-end"
new = re.sub(r"[ \t]*" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", txt, flags=re.S)
if new != txt:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
PYEOF
    systemctl reload sniproxy 2>/dev/null || systemctl restart sniproxy 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# mosdns hijack toggle for the two hosts (idempotent)
# --------------------------------------------------------------------------- #
wloc_hijack_enable() {
    local extra="/etc/mosdns/gfwlist-extra-local.txt"
    [[ -d /etc/mosdns ]] || return 0
    touch "$extra"
    local changed=0 h
    for h in "$WLOC_HOST_A" "$WLOC_HOST_B"; do
        grep -qxF "$h" "$extra" || { echo "$h" >> "$extra"; changed=1; }
    done
    if [[ "$changed" == 1 ]]; then
        /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
        systemctl restart mosdns 2>/dev/null || true
    fi
}

wloc_hijack_disable() {
    local extra="/etc/mosdns/gfwlist-extra-local.txt"
    [[ -f "$extra" ]] || return 0
    local before after
    before="$(wc -l < "$extra" 2>/dev/null || echo 0)"
    grep -vxF "$WLOC_HOST_A" "$extra" 2>/dev/null | grep -vxF "$WLOC_HOST_B" > "${extra}.tmp" || true
    mv "${extra}.tmp" "$extra"
    after="$(wc -l < "$extra" 2>/dev/null || echo 0)"
    if [[ "$before" != "$after" ]]; then
        /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
        systemctl restart mosdns 2>/dev/null || true
    fi
}

# --------------------------------------------------------------------------- #
# High-level install step (called from install.sh); defaults to DISABLED.
# --------------------------------------------------------------------------- #
wloc_setup_install() {
    wloc_info "Setting up WLOC sidecar (disabled by default) ..."
    # Always install the helper scripts + user + config + service unit, even if
    # mitmproxy could not be installed. These do not depend on mitmproxy, and
    # having them present means a later `5gpn-ctl --wloc-setup` (once network is
    # healthy) only needs to fetch mitmproxy + generate the CA -- nothing else.
    wloc_ensure_user
    wloc_ensure_config
    install -m 0755 "${LIB_DIR}/wloc-core.py" "${BASE_DIR}/bin/wloc-core.py"
    install -m 0755 "${LIB_DIR}/wloc-mitm.py" "${BASE_DIR}/bin/wloc-mitm.py"
    install -m 0755 "${LIB_DIR}/wloc-ca-profile.py" "${BASE_DIR}/bin/wloc-ca-profile.py"
    if ! wloc_install_deps; then
        wloc_warn "mitmproxy not installed; WLOC left INCOMPLETE."
        wloc_warn "Re-run once network is healthy:  sudo ${BASE_DIR}/bin/5gpn-ctl --wloc-setup"
        WLOC_SETUP_INCOMPLETE=1
        return 0
    fi
    if ! wloc_ensure_ca; then
        wloc_warn "WLOC CA not ready; re-run: sudo ${BASE_DIR}/bin/5gpn-ctl --wloc-setup"
        WLOC_SETUP_INCOMPLETE=1
        wloc_install_service
        return 0
    fi
    wloc_install_service
    # Default disabled: do NOT hijack, do NOT start the sidecar. Apple location
    # stays direct until the operator enables WLOC.
    WLOC_SETUP_INCOMPLETE=0
    wloc_info "WLOC ready (disabled). Enable via Telegram bot /wloc."
}

# Post-install health probe (called from install.sh summary). Prints a single
# human-readable status line and returns 0 when WLOC is fully provisioned.
wloc_healthcheck() {
    local mitm ca ok=1 msg
    mitm="$(wloc_mitmdump_bin)"
    ca="$WLOC_CA_PROFILE"
    if [[ ! -x "$mitm" ]]; then
        msg="WLOC: mitmproxy MISSING (run: 5gpn-ctl --wloc-setup)"; ok=0
    elif [[ ! -s "$ca" ]]; then
        msg="WLOC: CA profile MISSING (run: 5gpn-ctl --wloc-setup)"; ok=0
    else
        msg="WLOC: ready (disabled by default; enable via /wloc)"
    fi
    echo "$msg"
    [[ "$ok" -eq 1 ]]
}

# --------------------------------------------------------------------------- #
# ctl subcommands (invoked by the bot through MGMT / 5gpn-ctl)
# --------------------------------------------------------------------------- #
wloc_cfg_get() {
    python3 - "$WLOC_CONFIG" "$1" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
v = d.get(sys.argv[2])
print("" if v is None else v)
PYEOF
}

wloc_ctl_status() {
    local enabled lat lon active
    enabled="$(wloc_cfg_get enabled)"
    lat="$(wloc_cfg_get latitude)"
    lon="$(wloc_cfg_get longitude)"
    active="$(systemctl is-active 5gpn-wloc.service 2>/dev/null || echo unknown)"
    echo "enabled=${enabled:-False}"
    echo "latitude=${lat}"
    echo "longitude=${lon}"
    echo "service=${active}"
    echo "ca_profile=$([[ -f "$WLOC_CA_PROFILE" ]] && echo present || echo missing)"
}

wloc_ctl_set() {
    local lat="$1" lon="$2"
    # Validate + atomically write via the core (rejects out-of-range).
    if ! python3 - "$WLOC_CONFIG" "$lat" "$lon" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wc", "/opt/5gpn/bin/wloc-core.py")
wc = importlib.util.module_from_spec(spec); spec.loader.exec_module(wc)
path, lat, lon = sys.argv[1], sys.argv[2], sys.argv[3]
if not (wc.valid_lat(lat) and wc.valid_lon(lon)):
    sys.exit(3)
cur = wc.load_config(path)
cur.update({"enabled": True, "latitude": float(lat), "longitude": float(lon)})
wc.save_config(path, cur)
PYEOF
    then
        wloc_err "invalid coordinate; keeping existing config"
        return 3
    fi
    chown "$WLOC_USER":"$WLOC_USER" "$WLOC_CONFIG" 2>/dev/null || true
    chmod 600 "$WLOC_CONFIG" 2>/dev/null || true
    wloc_ensure_ca >/dev/null 2>&1 || true
    wloc_sniproxy_apply
    wloc_hijack_enable
    wloc_sidecar_start
    echo "ok"
}

wloc_ctl_off() {
    python3 - "$WLOC_CONFIG" <<'PYEOF' || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wc", "/opt/5gpn/bin/wloc-core.py")
wc = importlib.util.module_from_spec(spec); spec.loader.exec_module(wc)
path = sys.argv[1]
cur = wc.load_config(path)
cur["enabled"] = False
wc.save_config(path, cur)
PYEOF
    chown "$WLOC_USER":"$WLOC_USER" "$WLOC_CONFIG" 2>/dev/null || true
    chmod 600 "$WLOC_CONFIG" 2>/dev/null || true
    # Remove hijack (fail-open: Apple location returns to direct) and stop MITM.
    wloc_hijack_disable
    wloc_sniproxy_remove
    wloc_sidecar_stop
    echo "ok"
}

wloc_ctl_ca_path() { echo "$WLOC_CA_PROFILE"; }

wloc_ctl_ca_url() {
    local domain=""
    [[ -f "${CONF_DIR}/.domain" ]] && domain="$(cat "${CONF_DIR}/.domain")"
    [[ -z "$domain" && -f /etc/mosdns/.domain ]] && domain="$(cat /etc/mosdns/.domain)"
    if [[ -n "$domain" ]]; then
        echo "http://${domain}:${IOS_PROFILE_PORT}/wloc-ca.mobileconfig"
    else
        echo ""
    fi
}

# --------------------------------------------------------------------------- #
# Uninstall / cleanup
# --------------------------------------------------------------------------- #
wloc_uninstall() {
    local purge="${1:-}"
    wloc_sidecar_stop
    rm -f /etc/systemd/system/5gpn-wloc.service
    systemctl daemon-reload 2>/dev/null || true
    wloc_hijack_disable
    wloc_sniproxy_remove
    rm -f "$WLOC_CA_PROFILE"
    rm -f "$WLOC_CONFIG"
    if [[ "$purge" == "purge" ]]; then
        rm -rf "$WLOC_STATE_DIR"
        userdel "$WLOC_USER" 2>/dev/null || true
        wloc_info "WLOC fully purged (CA private key removed)."
    else
        wloc_warn "WLOC CA private key kept at ${WLOC_MITM_CONFDIR} (rerun uninstall with purge to remove)."
    fi
}
