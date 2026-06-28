#!/bin/bash
# Tests for the HTTP control API (api-server.py + install.sh wiring).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

install_body="$(cat "${here}/install.sh")"

if [[ ! -f "${here}/api-server.py" && ! -f "${here}/webui/index.html" ]]; then
    if [[ "${install_body}" == *'setup_api()'* || "${install_body}" == *'--setup-api)'* ]]; then
        fail "API install wiring exists but api-server.py/webui are missing"
    fi
    echo "api control surface skipped (not shipped in this tree)"
    exit 0
fi

[[ -f "${here}/api-server.py" ]] || fail "api-server.py missing while API/webui files are partially present"
[[ -f "${here}/webui/index.html" ]] || fail "webui/index.html missing while API files are partially present"
api_body="$(cat "${here}/api-server.py")"

# --- api-server.py: compiles and enforces auth/TLS --------------------------
python3 -m py_compile "${here}/api-server.py" || fail "api-server.py must compile"
[[ "${api_body}" == *'hmac.compare_digest'* ]] || fail "API must compare the token in constant time"
[[ "${api_body}" == *'Authorization'* ]] || fail "API must require an Authorization header"
[[ "${api_body}" == *'load_cert_chain'* ]] || fail "API must serve TLS"
[[ "${api_body}" == *'len(TOKEN) < 16'* ]] || fail "API must refuse a missing/short token"
for ep in '/api/health' '/api/status' '/api/exits/set' '/api/exits/add' '/api/exits/del' \
          '/api/exits/check' '/api/policy' '/api/policy/del' '/api/policy/rename' \
          '/api/rules' '/api/rules/add' '/api/rules/del' '/api/rules/edit' \
          '/api/update-rules' '/api/traffic'; do
    [[ "${api_body}" == *"${ep}"* ]] || fail "API missing endpoint: ${ep}"
done
# rule-group (category) management in the ctl backend
[[ "${install_body}" == *'del_policy()'* && "${install_body}" == *'rename_policy()'* ]] || fail "ctl must support del/rename rule groups"
[[ "${install_body}" == *'--del-policy)'* && "${install_body}" == *'--rename-policy)'* ]] || fail "ctl must dispatch del/rename-policy"
[[ "${api_body}" == *'def parse_rules'* ]] || fail "API must parse rules into structured entries"
# resources (cpu/mem/disk/uptime/load) + 24h traffic collector
for fn in 'def resources' 'cpu_percent' 'statvfs' 'uptime_sec' 'def read_net_dev' 'def traffic_tick' 'def traffic_loop'; do
    [[ "${api_body}" == *"${fn}"* ]] || fail "API missing: ${fn}"
done
# exit latency (ping -> tcp fallback) + 24h history
for fn in 'def ping_ms' 'def tcp_ms' 'def measure_latency' 'def latency_tick' '/api/latency' '/api/exits/latency'; do
    [[ "${api_body}" == *"${fn}"* ]] || fail "API missing latency: ${fn}"
done
# AI assistant (bind own API -> propose plan -> manual apply)
for fn in 'def ai_plan' 'def ai_chat' 'def github_context' '/api/ai/config' '/api/ai/plan' '/api/ai/apply'; do
    [[ "${api_body}" == *"${fn}"* ]] || fail "API missing AI: ${fn}"
done
# the AI key must be stored server-side and never returned by the config GET
[[ "${api_body}" == *'"configured": bool('* ]] || fail "AI config GET must not expose the key"
# live stats / route tester / one-click proxy-domain / backup+restore
for fn in 'def live_stats' 'def route_test' 'def make_backup' 'def restore_backup' '_backup_allowed' \
          '/api/live' '/api/route/test' '/api/proxy-domain' '/api/backup' '/api/restore'; do
    [[ "${api_body}" == *"${fn}"* ]] || fail "API missing: ${fn}"
done
# restore must reject paths outside the allow-list
[[ "${api_body}" == *'".." in name.split'* ]] || fail "restore must block path traversal"
[[ "${install_body}" == *'proxy_domain()'* && "${install_body}" == *'--proxy-domain)'* ]] || fail "ctl must support --proxy-domain"
# same backend as the bot -> in sync
[[ "${api_body}" == *'proxy-gateway-ctl'* ]] || fail "API must shell out to proxy-gateway-ctl (shared backend)"
# CORS so a web page hosted elsewhere can call it
[[ "${api_body}" == *'Access-Control-Allow-Origin'* ]] || fail "API must send CORS headers"

# --- install.sh wiring ------------------------------------------------------
[[ "${install_body}" == *'setup_api()'* ]] || fail "install.sh must define setup_api"
[[ "${install_body}" == *'--setup-api)'* ]] || fail "install.sh must dispatch --setup-api"
[[ "${install_body}" == *'proxy-gateway-api.service'* ]] || fail "install.sh must define the API systemd unit"
[[ "${install_body}" == *'api.env'* ]] || fail "install.sh must write api.env"
[[ "${install_body}" == *'__TCP_PORTS__'* ]] || fail "firewall must templatize the allowed TCP ports"
[[ "${install_body}" == *'.api_port'* ]] || fail "firewall must read the API port for persistence"
[[ "${install_body}" == *'proxy-gateway-tgbot,proxy-gateway-api}'* ]] || fail "uninstall must remove the API unit"
# optional in the main install flow (opt-in, default skip)
[[ "${install_body}" == *'maybe_setup_api'* ]] || fail "install must offer the API as an optional step"
[[ "${install_body}" == *'API_SETUP'* ]] || fail "API setup must be opt-in (API_SETUP / prompt)"

# --- renew hook restarts the API (cert held in memory) ----------------------
[[ "$(cat "${here}/renew-hook.sh")" == *'proxy-gateway-api'* ]] || fail "renew hook must restart the API"

# --- web panel ships and talks to the API -----------------------------------
[[ -f "${here}/webui/index.html" ]] || fail "web panel index.html must exist"
web="$(cat "${here}/webui/index.html")"
[[ "${web}" == *'/api/status'* && "${web}" == *'Bearer'* ]] || fail "web panel must call the API with a Bearer token"
# panel: 24h traffic chart + resource bars
[[ "${web}" == *'/api/traffic'* && "${web}" == *'drawChart'* && "${web}" == *'getContext'* ]] || fail "web panel must render a traffic chart"
[[ "${web}" == *'cpu_percent'* && "${web}" == *'硬盘'* && "${web}" == *'class="tiles"'* ]] || fail "web panel must show CPU/mem/disk resource tiles"
# UniFi-style layout: sidebar nav + sections
[[ "${web}" == *'class="sidebar"'* && "${web}" == *'showSection'* && "${web}" == *'data-sec="dash"'* ]] || fail "web panel must use the sidebar/section layout"
# panel: detailed per-rule control (add one / delete one / list)
[[ "${web}" == *'/api/rules/add'* && "${web}" == *'/api/rules/del'* && "${web}" == *'renderRuleList'* ]] || fail "web panel must support per-rule add/delete"
# panel: edit a rule + create/rename/delete rule groups
[[ "${web}" == *'editRule'* && "${web}" == *'/api/rules/edit'* ]] || fail "web panel must support editing a rule"
[[ "${web}" == *'createGroup'* && "${web}" == *'renameGroup'* && "${web}" == *'delGroup'* ]] || fail "web panel must manage rule groups"
# panel: per-exit latency + 24h latency chart
[[ "${web}" == *'loadExitLatency'* && "${web}" == *'latPill'* && "${web}" == *'drawLatency'* && "${web}" == *'latChart'* ]] || fail "web panel must show exit latency + chart"
# panel: AI assistant with mandatory manual confirm
[[ "${web}" == *'aiPlan'* && "${web}" == *'aiApply'* && "${web}" == *'确认应用'* ]] || fail "web panel must have AI plan + confirm"
# panel: live dashboard + route tester + one-click + backup/restore
[[ "${web}" == *'loadLive'* && "${web}" == *'toggleAuto'* ]] || fail "web panel must have live/auto-refresh"
[[ "${web}" == *'routeTest'* && "${web}" == *'proxyDomain'* ]] || fail "web panel must have route tester + one-click proxy"
[[ "${web}" == *'backupConfig'* && "${web}" == *'restoreConfig'* ]] || fail "web panel must have backup/restore"

echo "api control surface OK"
