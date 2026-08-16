#!/usr/bin/env bash
# 5GPN-X module: rules
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

init_rules() {
    info "Initializing GFWList and ChinaList..."
    if /usr/local/bin/update-mosdns-rules.sh; then
        ok "Routing rules initialized"
    else
        warn "Rule update failed; the previous rules remain active."
    fi
}

regen_smart() {
    [[ -f "${RULES_FILE}" ]] || { err "No rules yet. Use --set-rules or --import-rules first."; exit 1; }
    [[ -f "${MIHOMO_ROUTER_GEN}" ]] || { err "Router generator missing: ${MIHOMO_ROUTER_GEN}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"; chmod 700 "${EXITS_DIR}"
    [[ -x /usr/local/bin/5gpn-apply-exit.sh ]] || setup_exit_switching >/dev/null
    ensure_mihomo || exit 1
    install_mihomo_unit
    info "Building smart mihomo config and rule providers..."
    local eff; eff="$(mktemp)"
    [[ -f "${RULES_DEFAULT}" ]] && cat "${RULES_DEFAULT}" >> "$eff"
    cat "${RULES_FILE}" >> "$eff"
    local yaml gen_err; yaml="$(exit_mihomo_conf smart)"
    if ! gen_err="$(EXITS_DIR="${EXITS_DIR}" WG_DIR="${WG_DIR}" PGW_RULESET_CACHE="${RULESET_CACHE}" \
                    PGW_POLICY_MAP="${POLICY_MAP}" \
                    python3 "${MIHOMO_ROUTER_GEN}" "$eff" 2>&1 >"${yaml}.tmp")"; then
        err "Rules error: ${gen_err}"; rm -f "${yaml}.tmp" "$eff"; exit 1
    fi
    rm -f "$eff"
    mkdir -p "${CONF_DIR}/mihomo/smart"
    if ! "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/smart" -t -f "${yaml}.tmp" >/dev/null 2>&1; then
        err "mihomo rejected the generated router config:"
        "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/smart" -t -f "${yaml}.tmp" 2>&1 | sed 's/^/    /' >&2
        rm -f "${yaml}.tmp"; exit 1
    fi
    local cur="local" type_file backup_dir had_yaml=0 had_type=0
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    type_file="$(exit_type_file smart)"
    backup_dir="$(mktemp -d)"
    if [[ -f "$yaml" ]]; then
        cp -a "$yaml" "${backup_dir}/smart.yaml"
        had_yaml=1
    fi
    if [[ -f "$type_file" ]]; then
        cp -a "$type_file" "${backup_dir}/smart.type"
        had_type=1
    fi
    install -m 600 "${yaml}.tmp" "${yaml}"; rm -f "${yaml}.tmp"
    echo router > "$type_file"
    if [[ "$cur" == "smart" ]]; then
        local apply_ok=1
        systemctl restart "5gpn-mihomo@smart.service" >/dev/null 2>&1 || apply_ok=0
        [[ $apply_ok -eq 1 ]] && systemctl is-active --quiet "5gpn-mihomo@smart.service" || apply_ok=0
        [[ $apply_ok -eq 1 ]] && exit_wait_device smart || apply_ok=0
        [[ $apply_ok -eq 1 ]] && apply_current_exit >/dev/null 2>&1 || apply_ok=0
        if [[ $apply_ok -ne 1 ]]; then
            systemctl stop "5gpn-mihomo@smart.service" >/dev/null 2>&1 || true
            if [[ $had_yaml -eq 1 ]]; then
                install -m 600 "${backup_dir}/smart.yaml" "$yaml"
            else
                rm -f "$yaml"
            fi
            if [[ $had_type -eq 1 ]]; then
                install -m 600 "${backup_dir}/smart.type" "$type_file"
            else
                rm -f "$type_file"
            fi
            local rollback_ok=1
            if [[ $had_yaml -eq 1 ]]; then
                systemctl restart "5gpn-mihomo@smart.service" >/dev/null 2>&1 || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && systemctl is-active --quiet "5gpn-mihomo@smart.service" || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && exit_wait_device smart || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && apply_current_exit >/dev/null 2>&1 || rollback_ok=0
            fi
            rm -rf "$backup_dir"
            if [[ $rollback_ok -eq 1 && $had_yaml -eq 1 ]]; then
                err "New smart config failed to start; previous working config restored"
            else
                err "New smart config failed to start; rollback could not reactivate the previous config"
            fi
            return 1
        fi
        ok "Reloaded and verified the active smart router."
    else
        info "Activate smart routing with: $0 --set-exit smart"
    fi
    rm -rf "$backup_dir"
    local n; n="$(grep -cvE '^[[:space:]]*(#|;|$)' "${RULES_FILE}" 2>/dev/null || echo 0)"
    ok "Smart router rebuilt (${n} rules)."
}

set_rules() {
    local src="${1:-}"
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"
    local tmp; tmp="$(mktemp)"
    if [[ -n "$src" && -f "$src" ]]; then
        cat "$src" > "$tmp"
    elif [[ -n "$src" ]]; then
        err "Rules file not found: $src"; rm -f "$tmp"; exit 1
    elif [[ ! -t 0 ]]; then
        cat > "$tmp"
    else
        echo "Paste routing rules for the 'smart' exit, end with Ctrl-D:"
        cat > "$tmp"
    fi
    local old old_policy; old="$(mktemp)"; old_policy="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old"
    else
        : > "$old"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_policy"
    else
        : > "$old_policy"
    fi
    install -m 644 "$tmp" "${RULES_FILE}"; rm -f "$tmp"
    init_policy_map
    if ! (regen_smart); then
        install -m 644 "$old" "${RULES_FILE}"
        install -m 644 "$old_policy" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old" "$old_policy"
        err "Rules rejected; previous rules restored"
        exit 1
    fi
    rm -f "$old" "$old_policy"
}

add_rule() {
    local rule="${1:-}" old tmp
    [[ -n "$rule" ]] || { err "Usage: $0 --add-rule <TYPE,value,policy>"; exit 1; }
    [[ "$rule" != *$'\n'* && "$rule" != *$'\r'* ]] || { err "A rule must be one line"; exit 1; }
    mkdir -p "$(dirname "${RULES_FILE}")"
    old="$(mktemp)"; tmp="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old"
    else
        : > "$old"
    fi
    { printf '%s\n' "$rule"; cat "$old"; } > "$tmp"
    install -m 644 "$tmp" "${RULES_FILE}"
    if ! (regen_smart); then
        install -m 644 "$old" "${RULES_FILE}"
        init_policy_map
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old" "$tmp"
        err "Rule rejected; previous rules restored"
        exit 1
    fi
    rm -f "$old" "$tmp"
}

add_ruleset() {
    local source="${1:-}" policy="${2:-}"
    [[ -n "$source" && -n "$policy" ]] || { err "Usage: $0 --add-ruleset <url|path> <exit|category|direct|block>"; exit 1; }
    case "$source" in
        http://*|https://*) ;;
        /*) [[ -f "$source" ]] || { err "Rule-set file not found: $source"; exit 1; } ;;
        *) err "Rule-set source must be an http(s) URL or absolute local path"; exit 1 ;;
    esac
    add_rule "RULE-SET,${source},${policy}"
}

import_rules() {
    local src="${1:-}"
    [[ -n "$src" && -f "$src" ]] || { err "Usage: $0 --import-rules <rule-list-file>"; exit 1; }
    [[ -f "${RULES_IMPORT}" ]] || { err "rule converter missing: ${RULES_IMPORT}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"
    local keep="${PGW_KEEP_CATEGORIES:-}"
    [[ -z "$keep" && -f "${KEEP_FILE}" ]] && keep="$(cat "${KEEP_FILE}" 2>/dev/null)"
    if [[ -n "$keep" ]]; then
        mkdir -p "$(dirname "${KEEP_FILE}")"; printf '%s' "$keep" > "${KEEP_FILE}"
        info "Simplifying categories — keeping: ${keep} (others -> Proxy/direct/block)"
    fi
    local direct="${PGW_DIRECT_CATEGORIES:-}"
    [[ -z "$direct" && -f "${DIRECT_FILE}" ]] && direct="$(cat "${DIRECT_FILE}" 2>/dev/null)"
    if [[ -n "$direct" ]]; then
        mkdir -p "$(dirname "${DIRECT_FILE}")"; printf '%s' "$direct" > "${DIRECT_FILE}"
        info "Forcing to direct: ${direct}"
    fi
    local old_rules old_policy
    old_rules="$(mktemp)"; old_policy="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old_rules"
    else
        : > "$old_rules"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_policy"
    else
        : > "$old_policy"
    fi
    info "Converting rule list..."
    PGW_KEEP_CATEGORIES="$keep" PGW_DIRECT_CATEGORIES="$direct" python3 "${RULES_IMPORT}" "$src" \
        2>/tmp/pgw-import.err >"${RULES_FILE}.tmp" || true
    if [[ ! -s "${RULES_FILE}.tmp" ]]; then
        err "Conversion produced no rules:"; sed 's/^/    /' /tmp/pgw-import.err >&2; rm -f "${RULES_FILE}.tmp" "$old_rules" "$old_policy"; exit 1
    fi
    install -m 644 "${RULES_FILE}.tmp" "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    grep -E '^(converted|CATEGORIES)' /tmp/pgw-import.err | sed 's/^/[INFO] /'
    init_policy_map
    info "Categories were seeded in ${POLICY_MAP} (edit on the bot or with --set-policy)."
    if ! (regen_smart); then
        install -m 644 "$old_rules" "${RULES_FILE}"
        install -m 644 "$old_policy" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old_rules" "$old_policy"
        err "Imported rules rejected; previous rules and policy restored"
        exit 1
    fi
    rm -f "$old_rules" "$old_policy"
}

init_policy_map() {
    mkdir -p "$(dirname "${POLICY_MAP}")"
    touch "${POLICY_MAP}"
    local def; def="$(list_exit_names | head -n1)"; [[ -z "$def" ]] && def="direct"
    local cat low target existing tmp; tmp="$(mktemp)"
    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        low="$(printf '%s' "$cat" | tr '[:upper:]' '[:lower:]')"
        case "$low" in direct|dir|block|reject|direct-out) continue ;; esac
        existing="$(awk -F= -v c="$cat" '$1==c{print $2; exit}' "${POLICY_MAP}")"
        if [[ -n "$existing" ]]; then
            target="$existing"
        else
            case "$low" in
                *reject*|*advert*|*hijack*|*privacy*|*广告*) target="block" ;;
                *) target="$def" ;;
            esac
        fi
        printf '%s=%s\n' "$cat" "$target" >> "$tmp"
    done < <(cat "${RULES_DEFAULT}" "${RULES_FILE}" 2>/dev/null | grep -vE '^[[:space:]]*(#|;|$)' | awk -F, '{print $NF}' | sort -u)
    sort -u "$tmp" > "${POLICY_MAP}"; rm -f "$tmp"
}

set_policy() {
    local cat="${1:-}" target="${2:-}" old
    [[ -z "$cat" || -z "$target" ]] && { err "Usage: $0 --set-policy <category> <exit|direct|block>"; exit 1; }
    case "$target" in
        direct|block) ;;
        *) exit_exists "$target" || { err "Unknown target '$target' (use an exit name, direct, or block)"; exit 1; } ;;
    esac
    mkdir -p "$(dirname "${POLICY_MAP}")"; touch "${POLICY_MAP}"
    old="$(mktemp)"; cp -a "${POLICY_MAP}" "$old"
    grep -vF "${cat}=" "${POLICY_MAP}" > "${POLICY_MAP}.tmp" 2>/dev/null || true
    mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    printf '%s=%s\n' "$cat" "$target" >> "${POLICY_MAP}"
    if ! (regen_smart); then
        install -m 644 "$old" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old"
        err "Policy rejected; previous policy restored"
        exit 1
    fi
    rm -f "$old"
    ok "Mapped category '$cat' -> $target"
}

show_policy() {
    if [[ -s "${POLICY_MAP}" ]]; then
        sort "${POLICY_MAP}"
    else
        info "No policy map yet. Import rules first: $0 --import-rules <file>"
    fi
}

del_policy() {
    local cat="${1:-}"
    [[ -z "$cat" ]] && { err "Usage: $0 --del-policy <category>"; exit 1; }
    [[ -f "${POLICY_MAP}" ]] || { err "No policy map yet."; exit 1; }
    awk -F= -v c="$cat" '$1!=c' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" && mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    ok "Removed rule group '$cat'"
    regen_smart
}

rename_policy() {
    local old="${1:-}" new="${2:-}" old_rules old_map
    [[ -z "$old" || -z "$new" ]] && { err "Usage: $0 --rename-policy <old> <new>"; exit 1; }
    [[ "$new" =~ ^[A-Za-z0-9_-]+$ || "$new" =~ [^[:ascii:]] ]] || { err "Invalid new name"; exit 1; }
    old_rules="$(mktemp)"; old_map="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old_rules"
    else
        : > "$old_rules"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_map"
    else
        : > "$old_map"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        awk -F= -v o="$old" -v n="$new" 'BEGIN{OFS="="} $1==o{$1=n} {print}' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" \
            && mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    fi
    if [[ -f "${RULES_FILE}" ]]; then
        awk -v o="$old" -v n="$new" '
            /^[[:space:]]*(#|;|$)/ { print; next }
            { k=split($0,a,","); if(a[k]==o){ a[k]=n; line=a[1]; for(i=2;i<=k;i++) line=line","a[i]; print line } else print $0 }
        ' "${RULES_FILE}" > "${RULES_FILE}.tmp" && mv "${RULES_FILE}.tmp" "${RULES_FILE}"
    fi
    if ! (regen_smart); then
        install -m 644 "$old_rules" "${RULES_FILE}"
        install -m 644 "$old_map" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old_rules" "$old_map"
        err "Rename rejected; previous rules and policy restored"
        exit 1
    fi
    rm -f "$old_rules" "$old_map"
    ok "Renamed rule group '$old' -> '$new'"
}

proxy_domain() {
    local domain="${1:-}" target="${2:-}"
    [[ -z "$domain" || -z "$target" ]] && { err "Usage: $0 --proxy-domain <domain> <exit|direct|block>"; exit 1; }
    [[ "$domain" =~ ^[a-z0-9.-]+$ && "$domain" == *.* ]] || { err "Invalid domain"; exit 1; }
    case "$target" in
        direct|block) ;;
        *) exit_exists "$target" || { err "Unknown target '$target' (exit name / direct / block)"; exit 1; } ;;
    esac
    mkdir -p "${EXITS_DIR}"; touch "${RULES_FILE}"
    local esc="${domain//./\\.}" rule="DOMAIN-SUFFIX,${domain},${target}"
    grep -vE "^DOMAIN-SUFFIX,${esc}," "${RULES_FILE}" > "${RULES_FILE}.tmp" 2>/dev/null || true
    { echo "$rule"; cat "${RULES_FILE}.tmp"; } > "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    local extra="/etc/mosdns/gfwlist-extra-local.txt"
    mkdir -p /etc/mosdns; touch "$extra"
    if [[ "$target" == "direct" ]]; then
        grep -vxF "$domain" "$extra" > "$extra.tmp" 2>/dev/null || true; mv "$extra.tmp" "$extra"
    else
        grep -qxF "$domain" "$extra" || echo "$domain" >> "$extra"
    fi
    /usr/local/bin/update-mosdns-rules.sh >/dev/null
    ok "Domain '${domain}' -> ${target}  (hijack: $([[ "$target" == direct ]] && echo off || echo on))"
    regen_smart
}

show_rules() {
    if [[ -f "${RULES_FILE}" ]]; then
        cat "${RULES_FILE}"
    else
        info "No routing rules set. Add them with: $0 --set-rules <file>"
    fi
}
