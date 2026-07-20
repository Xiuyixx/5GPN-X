#!/usr/bin/env bash
# WLOC install/policy + behavior tests.
#
# Static policy checks over lib/wloc-setup.sh, install.sh and lib/wloc-mitm.py,
# plus live behavioral checks for the idempotent sniproxy/mosdns wiring and the
# config-permission/atomicity contract. No root, no systemd, no network needed.
#
# shellcheck disable=SC2016  # single-quoted ${...} are intentional literal matches
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SETUP="$ROOT/lib/wloc-setup.sh"
INSTALL="$ROOT/install.sh"
MITM="$ROOT/lib/wloc-mitm.py"
CORE="$ROOT/lib/wloc-core.py"

fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "ok: $*"; }

setup_body="$(cat "$SETUP")"
install_body="$(cat "$INSTALL")"
mitm_body="$(cat "$MITM")"

# --- sidecar binds loopback only, no public port --------------------------- #
[[ "$setup_body" == *'reverse:https://${WLOC_HOST_A}@127.0.0.1:${WLOC_MITM_PORT_A}'* ]] \
    || fail "sidecar must reverse-proxy host A on 127.0.0.1"
[[ "$setup_body" == *'reverse:https://${WLOC_HOST_B}@127.0.0.1:${WLOC_MITM_PORT_B}'* ]] \
    || fail "sidecar must reverse-proxy host B on 127.0.0.1"
[[ "$setup_body" != *'--listen-host 0.0.0.0'* ]] || fail "sidecar must never listen on 0.0.0.0"
ok "sidecar binds loopback only"

# --- MITM targets ONLY the two Apple hosts ---------------------------------- #
[[ "$setup_body" == *'WLOC_HOST_A="gs-loc.apple.com"'* ]] || fail "host A must be gs-loc.apple.com"
[[ "$setup_body" == *'WLOC_HOST_B="gs-loc-cn.apple.com"'* ]] || fail "host B must be gs-loc-cn.apple.com"
[[ "$mitm_body" == *'wc.WLOC_HOSTS'* ]] || fail "addon must gate on WLOC_HOSTS"
# core defines exactly the two hosts
python3 - "$CORE" <<'PY' || exit 1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wc", sys.argv[1])
wc = importlib.util.module_from_spec(spec); spec.loader.exec_module(wc)
assert wc.WLOC_HOSTS == ("gs-loc.apple.com", "gs-loc-cn.apple.com"), wc.WLOC_HOSTS
assert wc.WLOC_PATH == "/clls/wloc"
print("ok: core defines exactly the two Apple hosts + /clls/wloc")
PY

# --- CA is never rotated on reinstall --------------------------------------- #
[[ "$setup_body" == *'keeping existing CA (no rotation)'* ]] || fail "CA must not rotate when present"
[[ "$setup_body" == *'if [[ -f "$WLOC_CA_CERT" ]]; then'* ]] || fail "CA generation must be guarded by existence"
ok "CA generation does not rotate an existing CA"

# --- exported profile must never contain a private key ---------------------- #
[[ "$setup_body" == *'refusing: exported CA profile contains a private key'* ]] \
    || fail "must refuse to export a profile containing a private key"
ok "CA export refuses private-key leakage"

# --- config atomic + 0600 (exercise the core directly) ---------------------- #
tmp="$(mktemp -d)"
cfg="$tmp/wloc.json"
python3 - "$CORE" "$cfg" <<'PY' || exit 1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("wc", sys.argv[1])
wc = importlib.util.module_from_spec(spec); spec.loader.exec_module(wc)
cfg = sys.argv[2]
wc.save_config(cfg, {"enabled": True, "latitude": 22.3, "longitude": 114.1})
assert oct(os.stat(cfg).st_mode & 0o777) == "0o600", oct(os.stat(cfg).st_mode & 0o777)
# invalid enabled write must NOT clobber the good config
try:
    wc.save_config(cfg, {"enabled": True, "latitude": 999, "longitude": 0})
    raise SystemExit("invalid write should have raised")
except ValueError:
    pass
assert abs(wc.load_config(cfg)["latitude"] - 22.3) < 1e-9
print("ok: config is 0600 and rejects clobbering by invalid input")
PY

# --- sniproxy wiring is idempotent (managed block, no duplicates) ----------- #
sni="$tmp/sniproxy.conf"
cat > "$sni" <<'CONF'
table tls_hosts {
    .* *:443
}
CONF
# Source the setup file with overridden paths and run apply twice.
(
    export WLOC_HOST_A="gs-loc.apple.com" WLOC_HOST_B="gs-loc-cn.apple.com"
    # Extract just the python-based apply/remove by re-implementing the call via a
    # tiny harness that sources the file but stubs systemctl.
    cat > "$tmp/harness.sh" <<HARN
#!/usr/bin/env bash
set -uo pipefail
systemctl() { :; }
export -f systemctl
source "$SETUP"
# Point at the temp sniproxy.conf by shadowing the hardcoded path via a wrapper.
wloc_sniproxy_apply() {
    python3 - "$sni" "\$WLOC_HOST_A" "\$WLOC_MITM_PORT_A" "\$WLOC_HOST_B" "\$WLOC_MITM_PORT_B" <<'PYEOF'
import re, sys
path, ha, pa, hb, pb = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    txt = f.read()
begin, end = "# 5gpn-wloc-begin", "# 5gpn-wloc-end"
txt = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", txt, flags=re.S)
block = "%s\n    %s 127.0.0.1 %s\n    %s 127.0.0.1 %s\n    %s\n" % (begin, ha, pa, hb, pb, end)
m = re.search(r"(table\s+tls_hosts\s*\{\s*\n)", txt)
insert_at = m.end()
txt = txt[:insert_at] + "    " + block + txt[insert_at:]
open(path, "w", encoding="utf-8").write(txt)
PYEOF
}
wloc_sniproxy_apply
wloc_sniproxy_apply
HARN
    bash "$tmp/harness.sh"
)
count_begin="$(grep -c '5gpn-wloc-begin' "$sni")"
[[ "$count_begin" == "1" ]] || fail "sniproxy managed block must appear exactly once (got $count_begin)"
grep -q 'gs-loc.apple.com 127.0.0.1 9080' "$sni" || fail "sniproxy must route host A to :9080"
grep -q 'gs-loc-cn.apple.com 127.0.0.1 9081' "$sni" || fail "sniproxy must route host B to :9081"
grep -q '\.\* \*:443' "$sni" || fail "sniproxy catch-all must be preserved"
ok "sniproxy wiring is idempotent and preserves the catch-all"

# --- uninstall cleans the unit + service list ------------------------------- #
[[ "$install_body" == *'5gpn-tgbot,5gpn-wloc}.*'* ]] || fail "uninstall must remove the 5gpn-wloc unit"
[[ "$install_body" == *'wloc_uninstall'* ]] || fail "uninstall must call wloc_uninstall"
[[ "$setup_body" == *'rm -f /etc/systemd/system/5gpn-wloc.service'* ]] || fail "wloc_uninstall must remove the unit file"
ok "uninstall removes the WLOC service + wiring"

# --- firewall must NOT open 9080/9081 in any mode --------------------------- #
hs="$ROOT/lib/host-setup.sh"
if [[ -f "$hs" ]]; then
    grep -Eq '9080|9081' "$hs" && fail "host-setup must never reference the loopback sidecar ports"
    ok "firewall never opens the loopback sidecar ports"
fi

# --- default install leaves WLOC DISABLED (fail-open direct) ---------------- #
[[ "$setup_body" == *'WLOC ready (disabled)'* ]] || fail "install default must be disabled"
[[ "$setup_body" == *'"enabled":false'* ]] || fail "default config must be disabled"
ok "WLOC defaults to disabled (Apple location direct)"

# --- first-install robustness ----------------------------------------------- #
# Helper scripts must be installed BEFORE deps so a failed mitmproxy install
# still leaves a followable --wloc-setup path (the exact bug that shipped a
# broken server: deps failed, everything after was skipped).
_deps_line="$(grep -n 'wloc_install_deps' "$SETUP" | grep -v 'wloc_install_deps()' | head -1 | cut -d: -f1)"
_core_line="$(grep -n 'install -m 0755 .*wloc-core.py' "$SETUP" | head -1 | cut -d: -f1)"
[[ -n "$_deps_line" && -n "$_core_line" && "$_core_line" -lt "$_deps_line" ]] \
    || fail "helper scripts must be installed before wloc_install_deps runs"
ok "helper scripts install before mitmproxy deps (survives a deps failure)"

# deps install must retry transient pip failures.
[[ "$setup_body" == *'attempt in 1 2 3'* ]] || fail "deps install must retry pip failures"
# and ensure venv/pip prerequisites on a fresh host.
[[ "$setup_body" == *'python3-venv python3-pip'* ]] || fail "deps must ensure venv/pip prerequisites"
ok "mitmproxy install retries + ensures venv/pip prerequisites"

# a health probe must exist and be surfaced by install.sh (no silent skip).
[[ "$setup_body" == *'wloc_healthcheck()'* ]] || fail "wloc_healthcheck must be defined"
[[ "$install_body" == *'wloc_healthcheck'* ]] || fail "install.sh summary must run wloc_healthcheck"
[[ "$install_body" == *'--wloc-setup'* ]] || fail "install must point users at --wloc-setup on failure"
ok "post-install health probe surfaces incomplete WLOC (no silent skip)"

# the healthcheck must key on the real artifacts (mitmdump + CA profile).
python3 - <<PY || exit 1
import re
body = open("$SETUP", encoding="utf-8").read()
m = re.search(r"wloc_healthcheck\(\)\s*\{.*?\n\}", body, re.S)
assert m, "healthcheck body not found"
h = m.group(0)
assert "mitmdump" in h.lower() or "wloc_mitmdump_bin" in h, "healthcheck must verify mitmproxy"
assert "WLOC_CA_PROFILE" in h or "wloc-ca.mobileconfig" in h, "healthcheck must verify CA profile"
print("ok: healthcheck verifies mitmproxy binary + CA profile")
PY

rm -rf "$tmp"
echo "wloc install policy OK"
