#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
bot="${root}/tgbot.py"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

# --- bot exists and is valid Python -----------------------------------------
[[ -f "${bot}" ]] || fail "tgbot.py must exist"
python3 -m py_compile "${bot}" || fail "tgbot.py must compile"
bot_body="$(cat "${bot}")"

# --- authorization must gate every operation --------------------------------
[[ "${bot_body}" == *'ADMIN_IDS'* ]] || fail "tgbot.py must read an admin allowlist"
[[ "${bot_body}" == *'def authorized('* ]] || fail "tgbot.py must define an authorization check"
[[ "${bot_body}" == *'if not authorized('* ]] || fail "tgbot.py must enforce authorization"

# --- never run a shell on user input ----------------------------------------
[[ "${bot_body}" != *'shell=True'* ]] || fail "tgbot.py must never use shell=True"
[[ "${bot_body}" != *'os.system'* ]] || fail "tgbot.py must never use os.system"

# --- Telegram button interactions should stay responsive ---------------------
[[ "${bot_body}" == *'http.client.HTTPSConnection("api.telegram.org"'* ]] || fail "tgbot.py must reuse a keep-alive Telegram HTTPS connection"
[[ "${bot_body}" == *'def answer_callback_async('* ]] || fail "tgbot.py must answer callbacks asynchronously"
[[ "${bot_body}" == *'threading.Thread(target=go, daemon=True).start()'* ]] || fail "callback answers must run in a daemon thread"
[[ "${bot_body}" == *'answer_callback_async(cb_id)'* ]] || fail "authorized callback handling must not block on answerCallbackQuery"
[[ "${bot_body}" == *'_TG_LOCAL = threading.local()'* ]] || fail "tgbot.py must use per-thread Telegram API connections"
[[ "${bot_body}" == *'def edit_async('* ]] || fail "tgbot.py must run long callback operations asynchronously"
[[ "${bot_body}" == *'def send_async('* ]] || fail "tgbot.py must run long message operations asynchronously"
[[ "${bot_body}" == *'BUSY = set()'* ]] || fail "tgbot.py must prevent concurrent long operations on one menu message"
[[ "${bot_body}" == *'deleteMyCommands'* ]] || fail "tgbot.py must clear stale Telegram command scopes on startup"
[[ "${bot_body}" == *'{"type": "all_private_chats"}'* ]] || fail "tgbot.py must register commands for private chats scope"
[[ "${bot_body}" == *'setMyCommands'* ]] || fail "tgbot.py must register Telegram slash commands on startup"

# --- user-supplied values must be validated ---------------------------------
[[ "${bot_body}" == *'EXIT_NAME_RE'* ]] || fail "tgbot.py must validate exit names"
[[ "${bot_body}" == *'if svc not in SERVICES'* ]] || fail "tgbot.py must validate service names against an allowlist"
[[ "${bot_body}" == *'DOMAIN_RE'* ]] || fail "tgbot.py must validate custom DoT domains"
[[ "${bot_body}" == *'DNS_LIST_RE'* ]] || fail "tgbot.py must validate custom DNS upstreams"
[[ "${bot_body}" == *'def dot_menu('* ]] || fail "tgbot.py must expose a DoT management submenu"
[[ "${bot_body}" == *'--set-dot-domain'* ]] || fail "tgbot.py must call the fixed DoT domain management command"
[[ "${bot_body}" == *'--set-dns'* ]] || fail "tgbot.py must call the fixed DNS management command"
[[ "${bot_body}" != *'最多发送三行：private、public、sniproxy'* ]] || fail "tgbot.py DNS flow should use one unified DNS input"
[[ "${bot_body}" == *'url = "http://%s:8111/ios-dot.mobileconfig" % domain'* ]] || fail "tgbot.py iOS QR must prefer the current DoT domain over cached URL files"

# --- install wiring ---------------------------------------------------------
[[ "${install_body}" == *'setup_tgbot()'* ]] || fail "install.sh must define setup_tgbot"
[[ "${install_body}" == *'--setup-tgbot)'* ]] || fail "install.sh must dispatch --setup-tgbot"
[[ "${install_body}" == *'set_dot_domain()'* ]] || fail "install.sh must define set_dot_domain"
[[ "${install_body}" == *'resolve_domain_a_records()'* ]] || fail "install.sh must use a shared robust domain resolver"
[[ "${install_body}" == *'domain_resolves_to_public_ip()'* ]] || fail "install.sh must accept any matching A record from multiple resolver paths"
[[ "${install_body}" == *'getent ahostsv4'* ]] || fail "install.sh domain verification must fall back to system resolver"
[[ "${install_body}" != *'dig +short A "$new_domain" @1.1.1.1'* ]] || fail "set_dot_domain must not depend on a single public resolver"
[[ "${install_body}" == *'set_custom_dns()'* ]] || fail "install.sh must define set_custom_dns"
[[ "${install_body}" == *'--set-dot-domain)'* ]] || fail "install.sh must dispatch --set-dot-domain"
[[ "${install_body}" == *'--set-dns)'* ]] || fail "install.sh must dispatch --set-dns"
[[ "${install_body}" == *'DNS_UPSTREAMS'* ]] || fail "install.sh must support unified DNS_UPSTREAMS"
[[ "${install_body}" == *'DNS 设置 [1.1.1.1,8.8.8.8,9.9.9.9]'* ]] || fail "install.sh must present unified DNS setup wording"
[[ "${install_body}" == *'info "DNS 设置: $PRIVATE_OVERSEAS_DNS"'* ]] || fail "install.sh must report unified DNS setup cleanly"
[[ "${install_body}" != *'info "DNS upstreams:'* ]] || fail "install.sh must not use the old DNS upstreams wording"
[[ "${install_body}" != *'Private overseas DNS upstreams'* ]] || fail "install.sh must not prompt for three DNS lists interactively"
[[ "${install_body}" != *'Public overseas DNS upstreams'* ]] || fail "install.sh must not prompt for three DNS lists interactively"
[[ "${install_body}" != *'sniproxy resolver upstreams'* ]] || fail "install.sh must not prompt for three DNS lists interactively"
[[ "${install_body}" == *'EnvironmentFile='* ]] || fail "tgbot service must load its token from an EnvironmentFile"
[[ "${install_body}" == *'chmod 600 "${CONF_DIR}/tgbot.env"'* ]] || fail "tgbot.env must be chmod 600 (token secrecy)"
[[ "${install_body}" == *'proxy-gateway-tgbot.service'* ]] || fail "install.sh must create the tgbot systemd service"

# --- token must be optional: no token => skip, not fail ----------------------
[[ "${install_body}" == *'跳过 tgbot'* ]] || fail "install.sh must skip tgbot when no token is provided"

# --- uninstall must remove the bot ------------------------------------------
[[ "${install_body}" == *'proxy-gateway-tgbot}.*'* ]] || fail "uninstall must remove the tgbot service unit"

echo "tgbot policy OK"
