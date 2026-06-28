#!/usr/bin/env python3
"""
proxy-gateway Telegram control bot.

Stdlib-only (urllib) long-polling bot that drives the proxy-gateway management
commands and systemd services from Telegram, using inline-keyboard buttons.

Security model:
  * Bot token is read from the environment (systemd EnvironmentFile, root-only).
  * Only chat IDs listed in TG_ADMIN_IDS may run operations; everyone else is
    ignored (except /id, which only reveals the caller's own numeric id).
  * Every operation maps to a fixed argv list. User-supplied values (exit name,
    service name) are validated against strict allowlists/regex and are NEVER
    interpolated into a shell.

Environment:
  TG_BOT_TOKEN   Telegram bot token (required)
  TG_ADMIN_IDS   Comma/space separated numeric chat IDs allowed to operate
  MGMT           Path to the management script (default below)
"""

import html
import http.client
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request

TOKEN = os.environ.get("TG_BOT_TOKEN", "").strip()
ADMIN_IDS = {
    int(x) for x in re.split(r"[,\s]+", os.environ.get("TG_ADMIN_IDS", "").strip()) if x
}
MGMT = os.environ.get("MGMT", "/opt/proxy-gateway/bin/proxy-gateway-ctl")
API = "https://api.telegram.org/bot%s/" % TOKEN

# Services the bot may restart / tail. Order matters for display only.
SERVICES = [
    "dnsdist",
    "sniproxy",
    "quic-proxy",
    "china-dns-race-proxy",
    "proxy-gateway-ios-profile",
    "proxy-gateway-tgbot",
]
EXIT_NAME_RE = re.compile(r"^(local|[\w\-\u4e00-\u9fff]{1,16})$", re.UNICODE)
EXIT_ADD_NAME_RE = re.compile(r"^[\w\-\u4e00-\u9fff]{1,16}$", re.UNICODE)  # 'local' is reserved
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")
DNS_LIST_RE = re.compile(r"^[0-9A-Fa-f:.,\s]+$")
WWW_DIR = "/opt/proxy-gateway/www"

# Per-chat conversational state for multi-step flows (e.g. add-exit).
PENDING = {}


# --------------------------------------------------------------------------- #
# Telegram API
# --------------------------------------------------------------------------- #
_TG_CONN = None


def tg(method, **params):
    global _TG_CONN
    data = json.dumps(params).encode("utf-8")
    path = "/bot%s/%s" % (TOKEN, method)
    headers = {"Content-Type": "application/json", "Connection": "keep-alive"}
    for attempt in (0, 1):
        try:
            if _TG_CONN is None:
                _TG_CONN = http.client.HTTPSConnection("api.telegram.org", timeout=70)
            _TG_CONN.request("POST", path, data, headers)
            raw = _TG_CONN.getresponse().read()
            return json.loads(raw.decode("utf-8")) if raw else {}
        except Exception as e:
            try:
                if _TG_CONN:
                    _TG_CONN.close()
            except Exception:
                pass
            _TG_CONN = None
            if attempt:
                return {"ok": False, "error": str(e)}


def answer_callback_async(cb_id):
    def go():
        data = json.dumps({"callback_query_id": cb_id}).encode("utf-8")
        req = urllib.request.Request(
            API + "answerCallbackQuery",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=20):
                pass
        except Exception:
            pass

    threading.Thread(target=go, daemon=True).start()


def send(chat_id, text, keyboard=None, mono=False):
    # mono=True: paginate raw command output across one or more monospace
    # messages (escaped + wrapped per chunk, so HTML never splits mid-tag).
    if mono:
        text = (text or "").strip() or "(no output)"
        chunks = [text[i : i + 3500] for i in range(0, len(text), 3500)] or [""]
        wrapped = ["<pre>" + html.escape(c) + "</pre>" for c in chunks]
    else:
        wrapped = list(_chunks(text, 3900))
    last = len(wrapped) - 1
    for i, chunk in enumerate(wrapped):
        params = {
            "chat_id": chat_id,
            "text": chunk,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }
        if keyboard is not None and i == last:
            params["reply_markup"] = {"inline_keyboard": keyboard}
        tg("sendMessage", **params)


def _chunks(text, size):
    if not text:
        yield ""
        return
    for i in range(0, len(text), size):
        yield text[i : i + size]


def edit(cb, text, keyboard=None, mono=False):
    """Edit the message the button belongs to (keeps everything in one bubble).
    Falls back to a new message if the edit can't be applied."""
    msg = cb.get("message", {})
    chat_id = msg.get("chat", {}).get("id")
    mid = msg.get("message_id")
    if mono:
        text = "<pre>" + html.escape(((text or "").strip() or "(no output)")[:3800]) + "</pre>"
    params = {
        "chat_id": chat_id, "message_id": mid, "text": (text or "")[:4096],
        "parse_mode": "HTML", "disable_web_page_preview": True,
    }
    if keyboard is not None:
        params["reply_markup"] = {"inline_keyboard": keyboard}
    r = tg("editMessageText", **params)
    if not r.get("ok"):
        desc = str(r)
        if "not modified" in desc:
            return  # nothing to do
        # original may be a photo / too old / gone -> post a fresh message
        # text is already HTML-formatted when mono=True; pass mono=False so send()
        # does not double-escape it.
        send(chat_id, text, keyboard if keyboard else None, mono=False)


def back_kb(target="menu:main", label="« 返回"):
    return [[{"text": label, "callback_data": target}]]


def send_photo(chat_id, path, caption=""):
    """Upload a local image via multipart/form-data (sendPhoto)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    boundary = "----pgwQRboundary8f3a2b"

    def _field(name, val):
        return ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                % (boundary, name, val)).encode("utf-8")

    body = _field("chat_id", str(chat_id))
    if caption:
        body += _field("caption", caption) + _field("parse_mode", "HTML")
    body += ("--%s\r\nContent-Disposition: form-data; name=\"photo\"; "
             "filename=\"qr.png\"\r\nContent-Type: image/png\r\n\r\n" % boundary).encode("utf-8")
    body += data + b"\r\n" + ("--%s--\r\n" % boundary).encode("utf-8")
    req = urllib.request.Request(
        API + "sendPhoto", data=body,
        headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8")).get("ok", False)
    except Exception:
        return False


def pre(text):
    """Wrap command output in a monospace HTML block, safely escaped."""
    text = text.strip() or "(no output)"
    if len(text) > 3500:
        text = text[:3500] + "\n... (truncated)"
    return "<pre>" + html.escape(text) + "</pre>"


# --------------------------------------------------------------------------- #
# Operations (fixed argv, no shell)
# --------------------------------------------------------------------------- #
def run(argv, timeout=120, inp=None):
    try:
        p = subprocess.run(
            argv,
            input=inp,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        out = p.stdout or ""
        if p.returncode != 0:
            out += "\n[exit code %d]" % p.returncode
        return out
    except subprocess.TimeoutExpired:
        return "[timeout after %ds]" % timeout
    except FileNotFoundError:
        return "[command not found: %s]" % argv[0]
    except Exception as e:  # pragma: no cover
        return "[error: %s]" % e


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(s):
    return _ANSI_RE.sub("", s or "")


def run2(argv, timeout=120, inp=None):
    """Run a command; return (ok, stripped_output)."""
    try:
        p = subprocess.run(argv, input=inp, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout)
        return p.returncode == 0, _strip_ansi(p.stdout or "")
    except subprocess.TimeoutExpired:
        return False, "执行超时（%ds）" % timeout
    except FileNotFoundError:
        return False, "命令不存在：%s" % argv[0]
    except Exception as e:  # pragma: no cover
        return False, "错误：%s" % e


def _reason(out, n=4):
    """A short, human-readable reason from command output (for failures)."""
    lines = [l.strip() for l in _strip_ansi(out).splitlines() if l.strip()]
    errs = [l for l in lines if re.search(r"\[!\]|\[ERR\]|error|fail|invalid|拒绝|失败", l, re.I)]
    picked = (errs or lines)[-n:]
    text = "\n".join(picked)
    return (text[:600] + "…") if len(text) > 600 else text


def _exit_ip():
    """Best-effort: the public egress IP as seen through the active exit."""
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://ipinfo.io/ip"):
        ok, out = run2(["sudo", "-u", "pxout", "curl", "-4", "-s", "--max-time", "10", url],
                       timeout=14)
        out = (out or "").strip()
        if ok and re.match(r"^[0-9.]+$", out):
            return out
    return ""


# (unit, friendly label) shown on the status card.
STATUS_ITEMS = [
    ("dnsdist", "dnsdist"),
    ("sniproxy", "sniproxy"),
    ("quic-proxy", "quic-proxy"),
    ("china-dns-race-proxy", "china-dns-race"),
    ("proxy-gateway-ios-profile.socket", "iOS 描述文件"),
    ("proxy-gateway-tgbot", "Telegram Bot"),
]


def _read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _parse_env(path):
    d = {}
    for line in _read_file(path).splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def _is_active(unit):
    try:
        p = subprocess.run(["systemctl", "is-active", unit],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=10)
        return p.stdout.strip()
    except Exception:
        return "unknown"


# --------------------------------------------------------------------------- #
# Live server metrics (read from /proc, sampled over a short interval)
# --------------------------------------------------------------------------- #
def _read_int(path, default=0):
    try:
        return int(_read_file(path))
    except (ValueError, OSError):
        return default


def _cpu_idle_total():
    try:
        vals = list(map(int, open("/proc/stat").readline().split()[1:]))
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)  # idle + iowait
        return idle, sum(vals)
    except Exception:
        return 0, 0


def _default_iface():
    try:
        for line in open("/proc/net/route").readlines()[1:]:
            p = line.split()
            if p[1] == "00000000" and (int(p[3], 16) & 0x2):  # default + RTF_GATEWAY
                return p[0]
    except Exception:
        pass
    return None


def _iface_bytes(iface):
    if not iface:
        return 0, 0
    try:
        for line in open("/proc/net/dev"):
            if ":" in line:
                name, rest = line.split(":", 1)
                if name.strip() == iface:
                    f = rest.split()
                    return int(f[0]), int(f[8])  # rx, tx bytes
    except Exception:
        pass
    return 0, 0


def _established():
    n = 0
    for p in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            for line in open(p).readlines()[1:]:
                if line.split()[3] == "01":  # ESTABLISHED
                    n += 1
        except Exception:
            pass
    return n


def _fmt_bytes(n):
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return ("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit))
        n /= 1024
    return "%.1fP" % n


def system_metrics():
    idle0, tot0 = _cpu_idle_total()
    iface = _default_iface()
    rx0, tx0 = _iface_bytes(iface)
    time.sleep(0.7)
    idle1, tot1 = _cpu_idle_total()
    rx1, tx1 = _iface_bytes(iface)

    dtot = (tot1 - tot0) or 1
    cpu = max(0, min(100, round(100 * (1 - (idle1 - idle0) / dtot))))
    rx_rate = max(0, (rx1 - rx0) / 0.7)
    tx_rate = max(0, (tx1 - tx0) / 0.7)

    load = " ".join(_read_file("/proc/loadavg").split()[:3]) or "?"
    cores = os.cpu_count() or 1

    mi = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":")
            mi[k.strip()] = int(v.split()[0])  # kB
    except Exception:
        pass
    mt, ma = mi.get("MemTotal", 0) // 1024, mi.get("MemAvailable", 0) // 1024
    mu = mt - ma
    st, sf = mi.get("SwapTotal", 0) // 1024, mi.get("SwapFree", 0) // 1024
    su = st - sf

    dused = dtotal = 0
    try:
        sv = os.statvfs("/")
        dtotal = sv.f_blocks * sv.f_frsize
        dused = dtotal - sv.f_bavail * sv.f_frsize
    except Exception:
        pass

    conn = _read_int("/proc/sys/net/netfilter/nf_conntrack_count", -1)
    est = _established()
    try:
        up_h = int(float(_read_file("/proc/uptime").split()[0]) // 3600)
    except Exception:
        up_h = 0

    def pct(u, t):
        return round(100 * u / t) if t else 0

    out = ["━━━━━━━━━━", "🖥 <b>服务器</b>"]
    out.append("⏱ 运行 %d 小时" % up_h)
    out.append("🧮 CPU %d%%（load %s · %d核）" % (cpu, load, cores))
    swap = ("　Swap %d/%d MB" % (su, st)) if st else ""
    out.append("🧠 内存 %d/%d MB（%d%%）%s" % (mu, mt, pct(mu, mt), swap))
    if dtotal:
        out.append("🗄 磁盘 %s/%s（%d%%）" % (_fmt_bytes(dused), _fmt_bytes(dtotal), pct(dused, dtotal)))
    conn_s = ("%d" % conn) if conn >= 0 else "n/a"
    out.append("🔌 连接 conntrack %s · 活跃 %d" % (conn_s, est))
    out.append("🌐 流量 ↓%s/s ↑%s/s（累计 ↓%s ↑%s）"
               % (_fmt_bytes(rx_rate), _fmt_bytes(tx_rate), _fmt_bytes(rx1), _fmt_bytes(tx1)))
    return "\n".join(out)


def op_status():
    """A compact, human-readable status card (no raw shell output)."""
    lines = ["<b>📊 Proxy Gateway 状态</b>", ""]
    down = []
    for unit, label in STATUS_ITEMS:
        ok = _is_active(unit) == "active"
        lines.append(("✅ " if ok else "❌ ") + html.escape(label))
        if not ok:
            down.append(label)
    lines.append("")

    cur = _read_file("/opt/proxy-gateway/etc/current-exit") or "local"
    if cur == "local":
        lines.append("🌐 出口：<b>local</b>（本机直出）")
    else:
        t = _read_file("/etc/proxy-gateway/exits/%s.type" % cur) or "?"
        lines.append("🌐 出口：<b>%s</b>（%s）" % (html.escape(cur), html.escape(t)))

    domain = _read_file("/etc/dnsdist/.domain") or _read_file("/opt/proxy-gateway/etc/.domain")
    if domain:
        lines.append("🔗 域名：<code>%s</code>" % html.escape(domain))

    cs = _read_file("/etc/dnsdist/.cache_size")
    if cs.isdigit():
        prof = "低内存" if int(cs) <= 50000 else "标准"
        lines.append("💾 内存档：%s" % prof)

    if down:
        lines += ["", "⚠️ 异常：%s（用 📜 日志查看）" % html.escape("、".join(down))]

    try:
        lines += ["", system_metrics()]
    except Exception as e:  # metrics must never break the status card
        lines += ["", "（服务器指标获取失败：%s）" % html.escape(str(e))]
    return "\n".join(lines)


def op_set_exit(name):
    if not EXIT_NAME_RE.match(name):
        return "出口名无效。"
    ok, out = run2(["bash", MGMT, "--set-exit", name], timeout=60)
    if not ok:
        return "❌ <b>切换失败</b>\n%s" % html.escape(_reason(out))
    if name == "local":
        return "✅ 已切回 <b>local</b>（本机直出）"
    t = _read_file("/etc/proxy-gateway/exits/%s.type" % name) or "?"
    ip = _exit_ip()
    if ip:
        tail = "\n🌍 出口 IP：<code>%s</code>" % html.escape(ip)
    else:
        tail = "\n⚠️ 出口 IP 探测未成功（仅探测失败，不一定代表不通）。如访问异常，用「🩺 检查出口连通性」确认节点。"
    return "✅ 已切换到 <b>%s</b>（%s）%s" % (html.escape(name), html.escape(t), tail)


def op_add_exit(name, payload):
    if not EXIT_ADD_NAME_RE.match(name) or name == "local":
        return "出口名无效（需 1-11 位小写字母/数字，且不能为 local）。"
    text = (payload or "").strip()
    is_uri = bool(re.match(r"^(ss|socks5h|socks5|socks)://", text, re.I))
    is_wg = "[Interface]" in payload and "[Peer]" in payload
    if not is_uri and not is_wg:
        return ("无法识别。请发送一段 WireGuard 配置（含 [Interface]/[Peer]），"
                "或一个 socks5://... / ss://... 的 URI。")
    ok, out = run2(["bash", MGMT, "--add-exit", name], inp=payload, timeout=180)
    if ok:
        m = re.search(r"type:\s*(\w+)", out)
        return ("✅ 出口 <b>%s</b> 已添加（%s）\n在「🌐 出口」里点它即可切换。"
                % (html.escape(name), m.group(1) if m else "?"))
    return "❌ <b>添加失败</b>\n%s" % html.escape(_reason(out))


def op_del_exit(name):
    if not EXIT_ADD_NAME_RE.match(name) or name == "local":
        return "出口名无效（不能删除 local）。"
    ok, out = run2(["bash", MGMT, "--del-exit", name], timeout=30)
    if ok:
        return "✅ 出口 <b>%s</b> 已删除" % html.escape(name)
    return "❌ <b>删除失败</b>\n%s" % html.escape(_reason(out))


def op_update_rules():
    ok, out = run2(["bash", MGMT, "--update-rules"], timeout=600)
    if not ok:
        return "❌ <b>规则更新失败</b>\n%s" % html.escape(_reason(out))
    parts = ["✅ <b>规则已更新</b>"]
    gfw = re.search(r"GFWList:\s*(\d+)", out)
    cn = re.search(r"ChinaList:\s*(\d+)", out)
    if gfw:
        parts.append("• GFWList：%s 域名" % gfw.group(1))
    if cn:
        parts.append("• ChinaList：%s 域名" % cn.group(1))
    return "\n".join(parts)


def op_renew_cert():
    ok, out = run2(["bash", MGMT, "--renew-cert"], timeout=600)
    if ok:
        return "✅ <b>证书已续期</b>并重载 dnsdist"
    return "❌ <b>证书续期失败</b>\n%s" % html.escape(_reason(out))


def op_dot_status():
    domain = _read_file("/etc/dnsdist/.domain") or _read_file("/opt/proxy-gateway/etc/.domain") or "未设置"
    private_dns = (_read_file("/etc/dnsdist/.overseas_private_dns") or
                   _read_file("/etc/dnsdist/.overseas_dns") or "?")
    public_dns = _read_file("/etc/dnsdist/.overseas_public_dns") or "?"
    sniproxy_dns = (_read_file("/opt/proxy-gateway/etc/.sniproxy_dns") or
                    _read_file("/etc/dnsdist/.sniproxy_dns") or "?")
    return ("🔐 <b>DoT 管理</b>\n"
            "域名：<code>%s</code>\n"
            "私网 DoT 海外 DNS：<code>%s</code>\n"
            "公网 DoT 海外 DNS：<code>%s</code>\n"
            "sniproxy DNS：<code>%s</code>"
            % (html.escape(domain), html.escape(private_dns), html.escape(public_dns), html.escape(sniproxy_dns)))


def op_set_dot_domain(domain):
    domain = (domain or "").strip().lower().rstrip(".")
    if not DOMAIN_RE.match(domain):
        return "域名格式无效。请发送类似 <code>dns.example.com</code> 的完整域名。"
    ok, out = run2(["bash", MGMT, "--set-dot-domain", domain], timeout=900)
    if ok:
        return ("✅ <b>DoT 域名已更新</b>\n"
                "当前域名：<code>%s</code>\n"
                "证书已签发并重载 dnsdist。iOS 用户请重新生成二维码。" % html.escape(domain))
    return "❌ <b>DoT 域名更新失败</b>\n%s" % html.escape(_reason(out))


def _dns_arg(text):
    value = (text or "").strip()
    if not value or not DNS_LIST_RE.match(value):
        return ""
    return " ".join(value.replace(",", " ").split())


def op_set_dns(text):
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    if not lines:
        return "DNS 不能为空。"
    if len(lines) > 1:
        return "只需要发送一行 DNS，上游会同步用于私网 DoT、公网 DoT 和 sniproxy。"
    private_dns = _dns_arg(lines[0])
    if not private_dns:
        return "DNS 格式无效。只支持 IPv4/IPv6 地址，多个地址用空格或逗号分隔。"
    ok, out = run2(["bash", MGMT, "--set-dns", private_dns], timeout=600)
    if ok:
        return ("✅ <b>DNS 上游已更新</b>\n"
                "已同步用于私网 DoT、公网 DoT 和 sniproxy：\n"
                "<code>%s</code>" % html.escape(private_dns))
    return "❌ <b>DNS 上游更新失败</b>\n%s" % html.escape(_reason(out))


def op_restart(svc):
    if svc not in SERVICES:
        return "未知服务。"
    target = svc + ".socket" if svc == "proxy-gateway-ios-profile" else svc
    run2(["systemctl", "restart", target], timeout=60)
    state = _is_active(target)
    icon = "✅" if state in ("active", "listening") else "❌"
    return "%s <b>%s</b> 已重启（%s）" % (icon, html.escape(svc), state)


def op_logs(svc):
    # Logs are the one place where the raw content IS the requested result.
    if svc not in SERVICES:
        return "未知服务。"
    return _strip_ansi(run(
        ["journalctl", "-u", svc, "-n", "30", "--no-pager", "-o", "short-iso"],
        timeout=30,
    ))


# --------------------------------------------------------------------------- #
# Smart-routing rules (the 'smart' exit)
# --------------------------------------------------------------------------- #
RULES_PATH = "/etc/proxy-gateway/rules.conf"


def _rule_entries():
    """(all file lines, [(line_index, text)] for effective rules)."""
    txt = _read_file(RULES_PATH)
    lines = txt.splitlines() if txt else []
    entries = [(i, l) for i, l in enumerate(lines)
               if l.strip() and not l.strip().startswith(("#", ";"))]
    return lines, entries


def op_show_rules():
    _, entries = _rule_entries()
    if not entries:
        return "（还没有分流规则）\n用「✏️ 设置规则」粘贴一份，或「➕ 添加一条」。"
    body = "\n".join("%d. %s" % (i + 1, e[1].strip()) for i, e in enumerate(entries))
    return "🧭 <b>当前分流规则</b>（%d 条）：\n<pre>%s</pre>" % (len(entries), html.escape(body))


def op_set_rules(text):
    if not (text or "").strip():
        return "规则不能为空。"
    # Always goes through --set-rules, so sing-box validates before it takes effect.
    ok, out = run2(["bash", MGMT, "--set-rules"], inp=text, timeout=180)
    if ok:
        m = re.search(r"\((\d+) rules\)", out)
        return ("✅ <b>分流规则已更新</b>（%s 条）\n用「⚡ 启用智能分流」或在 🌐 出口 选 smart 生效。"
                % (m.group(1) if m else "?"))
    return "❌ <b>规则设置失败</b>\n%s" % html.escape(_reason(out))


def op_add_rule(line):
    line = (line or "").strip()
    if not line:
        return "规则不能为空。"
    txt = _read_file(RULES_PATH)
    newtext = (txt.rstrip("\n") + "\n" + line + "\n") if txt.strip() else (line + "\n")
    return op_set_rules(newtext)


def op_del_rule(num):
    try:
        n = int(str(num).strip())
    except ValueError:
        return "请发送要删除的规则序号（数字）。"
    lines, entries = _rule_entries()
    if not entries:
        return "当前没有规则可删除。"
    if n < 1 or n > len(entries):
        return "序号超出范围（1-%d）。" % len(entries)
    drop = entries[n - 1][0]
    return op_set_rules("\n".join(l for i, l in enumerate(lines) if i != drop) + "\n")


# --------------------------------------------------------------------------- #
# Category -> exit policy map
# --------------------------------------------------------------------------- #
POLICY_PATH = "/etc/proxy-gateway/policy-map.conf"


def _policy_map():
    out = []
    for line in _read_file(POLICY_PATH).splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out.append((k.strip(), v.strip()))
    return out


def op_set_policy(cat, target):
    # Rebuilds the router (may fetch/compile rule-sets) — give it room.
    ok, out = run2(["bash", MGMT, "--set-policy", cat, target], timeout=600)
    if ok:
        return "✅ <b>%s</b> → <b>%s</b>，分流已重建。" % (html.escape(cat), html.escape(target))
    return "❌ <b>映射失败</b>\n%s" % html.escape(_reason(out))


def _targets():
    return [n for n in parse_exit_names() if n != "local"]


def op_check_exits():
    ok, out = run2(["bash", MGMT, "--check-exits"], timeout=60)
    out = out.strip()
    if not out:
        return "（没有可检查的出口）"
    bad = "DOWN" in out
    head = "🩺 <b>出口节点连通性</b>%s\n" % ("　⚠️ 有节点不可达！" if bad else "")
    return head + "<pre>" + html.escape(out) + "</pre>"


def parse_exit_names():
    names = ["local"]
    seen = set()
    try:
        for f in sorted(os.listdir("/etc/proxy-gateway/exits")):
            if f.endswith(".type"):
                seen.add(f[: -len(".type")])
    except OSError:
        pass
    try:
        for f in sorted(os.listdir("/etc/wireguard")):
            if f.startswith("pgw-") and f.endswith(".conf"):
                seen.add(f[len("pgw-") : -len(".conf")])
    except OSError:
        pass
    names.extend(sorted(seen))
    return names


def op_ios_send(chat_id):
    """Send the iOS profile QR as an image (with the URL as caption)."""
    url = _read_file(os.path.join(WWW_DIR, "ios-profile-url.txt"))
    if not url:
        domain = _read_file("/etc/dnsdist/.domain") or _read_file("/opt/proxy-gateway/etc/.domain")
        if domain:
            url = "http://%s:8111/ios-dot.mobileconfig" % domain
    if not url:
        return "未找到 iOS 描述文件地址,先在服务器上 `--ios` 生成。"
    cap = ("📱 <b>iOS DoT 描述文件</b>\n扫码安装(仅蜂窝网启用):\n<code>%s</code>" % html.escape(url))
    png = "/tmp/pgw-ios-qr.png"
    ok, _ = run2(["qrencode", "-o", png, "-s", "8", "-m", "2", url], timeout=15)
    if ok and send_photo(chat_id, png, cap):
        return None  # delivered as a photo
    # fallback: just the URL (text)
    return cap


# --------------------------------------------------------------------------- #
# Keyboards
# --------------------------------------------------------------------------- #
def main_menu():
    return [
        [{"text": "📊 状态", "callback_data": "act:status"},
         {"text": "🌐 出口", "callback_data": "menu:exits"}],
        [{"text": "🧭 智能分流", "callback_data": "menu:rules"},
         {"text": "🔄 更新规则", "callback_data": "act:update_rules"}],
        [{"text": "🔐 DoT 管理", "callback_data": "menu:dot"},
         {"text": "♻️ 重启服务", "callback_data": "menu:restart"}],
        [{"text": "📜 日志", "callback_data": "menu:logs"},
         {"text": "📱 iOS 二维码", "callback_data": "act:ios"}],
    ]


def rules_menu():
    return [
        [{"text": "🎯 分类→出口映射", "callback_data": "menu:policy"}],
        [{"text": "📋 查看规则", "callback_data": "rules:show"},
         {"text": "✏️ 设置规则", "callback_data": "rules:set"}],
        [{"text": "➕ 添加一条", "callback_data": "rules:add"},
         {"text": "🗑 删除一条", "callback_data": "rules:del"}],
        [{"text": "⚡ 启用智能分流", "callback_data": "rules:enable"}],
        [{"text": "« 返回", "callback_data": "menu:main"}],
    ]


def policy_menu():
    rows = []
    pm = _policy_map()
    if not pm:
        rows.append([{"text": "（还没有分类，先在服务器 --import-rules）", "callback_data": "menu:rules"}])
    for i, (cat, tgt) in enumerate(pm):
        rows.append([{"text": "%s → %s" % (cat, tgt), "callback_data": "pol:%d" % i}])
    rows.append([{"text": "« 返回", "callback_data": "menu:rules"}])
    return rows


def policy_targets_menu(idx):
    rows, row = [], []
    for e in _targets():
        row.append({"text": e, "callback_data": "ps:%d:%s" % (idx, e)})
        if len(row) == 3:
            rows.append(row); row = []
    if row:
        rows.append(row)
    rows.append([{"text": "🌍 直连", "callback_data": "ps:%d:direct" % idx},
                 {"text": "🚫 拒绝", "callback_data": "ps:%d:block" % idx}])
    rows.append([{"text": "« 返回", "callback_data": "menu:policy"}])
    return rows


def exits_menu():
    rows = []
    for name in parse_exit_names():
        rows.append([{"text": "➡ " + name, "callback_data": "exit:" + name}])
    rows.append([{"text": "➕ 添加出口", "callback_data": "exit_add"},
                 {"text": "🗑 删除出口", "callback_data": "menu:exits_del"}])
    rows.append([{"text": "🩺 检查出口连通性", "callback_data": "exits:check"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:main"}])
    return rows


def exits_del_menu():
    rows = []
    for name in parse_exit_names():
        if name == "local":
            continue
        rows.append([{"text": "🗑 " + name, "callback_data": "exitdel:" + name}])
    if not rows:
        rows.append([{"text": "(没有可删除的出口)", "callback_data": "menu:exits"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:exits"}])
    return rows


def dot_menu():
    return [
        [{"text": "🌐 更改域名", "callback_data": "dot:domain"}],
        [{"text": "🧭 更改 DNS", "callback_data": "dot:dns"}],
        [{"text": "🔄 续期证书", "callback_data": "act:renew"}],
        [{"text": "« 返回", "callback_data": "menu:main"}],
    ]


def services_menu(prefix):
    rows = [[{"text": s, "callback_data": "%s:%s" % (prefix, s)}] for s in SERVICES]
    rows.append([{"text": "« 返回", "callback_data": "menu:main"}])
    return rows


# --------------------------------------------------------------------------- #
# Update handling
# --------------------------------------------------------------------------- #
def authorized(uid):
    return uid in ADMIN_IDS


def handle_message(msg):
    chat_id = msg["chat"]["id"]
    uid = msg.get("from", {}).get("id")
    text = (msg.get("text") or "").strip()

    # /id is always allowed: it only reveals the caller's own numeric id,
    # which is needed to bootstrap TG_ADMIN_IDS.
    if text.startswith("/id"):
        send(chat_id, "你的 Telegram 数字 ID: <code>%d</code>" % uid)
        return

    if not authorized(uid):
        send(chat_id, "⛔ 未授权。把你的 ID 加入 TG_ADMIN_IDS 后重试。")
        return

    if text == "/cancel":
        PENDING.pop(chat_id, None)
        send(chat_id, "已取消。", main_menu())
        return

    # A slash command always aborts any in-progress flow.
    if text.startswith("/"):
        PENDING.pop(chat_id, None)
        if text.startswith(("/start", "/menu")):
            send(chat_id, "<b>proxy-gateway 控制台</b>\n选择一个操作：", main_menu())
        elif text.startswith("/status"):
            send(chat_id, op_status())
        elif text.startswith("/exits"):
            send(chat_id, "选择要切换到的出口：", exits_menu())
        elif text.startswith("/rules"):
            send(chat_id, "🧭 <b>智能分流</b>：按域名分流到不同出口 / 直连 / 拒绝。", rules_menu())
        else:
            send(chat_id, "未知命令。发送 /menu 打开操作面板。")
        return

    # Conversational flows (e.g. adding an exit).
    state = PENDING.get(chat_id)
    if state and state.get("action") == "add_exit_name":
        name = text.strip()
        if not EXIT_ADD_NAME_RE.match(name) or name == "local":
            send(chat_id, "名字无效。请用 1-11 位小写字母/数字（不能是 local）。再发一次，或 /cancel：")
            return
        PENDING[chat_id] = {"action": "add_exit_config", "name": name}
        # NOTE: this message contains literal '%' — inject the name by
        # concatenation, NOT %-formatting, or Python treats '%' as a conversion.
        send(chat_id,
             "✅ 出口名：<b>" + html.escape(name) + "</b>\n\n"
             "🔗 <b>导入链接</b>\n"
             "请把出口配置粘贴到聊天框，我会自动识别类型。\n"
             "⚠️ 配置里可能包含密钥/密码，会经 Telegram 传输。\n\n"

             "<b>支持格式</b>\n\n"
             "1️⃣ <b>SOCKS5</b>\n"
             "• 无鉴权：<code>socks5://host:端口</code>\n"
             "• 账号密码：<code>socks5://用户:密码@host:端口</code>\n"
             "• 远程 DNS：把 <code>socks5://</code> 换成 <code>socks5h://</code>\n\n"

             "2️⃣ <b>Shadowsocks / SS2022</b>\n"
             "• 标准格式：<code>ss://加密方式:密码@host:端口</code>\n"
             "• SS2022：<code>ss://2022-blake3-aes-128-gcm:密码@host:端口</code>\n"
             "• 机场/客户端分享的 <code>ss://</code> 链接可直接整条粘贴\n\n"

             "3️⃣ <b>WireGuard</b>\n"
             "• 粘贴整段配置，需包含 <code>[Interface]</code> 和 <code>[Peer]</code>\n"
             "• 可用 <code>exit-server-setup.sh</code> 生成\n\n"

             "<b>密码含特殊字符怎么办？</b>\n"
             "如果密码里有 <code>@ : / # ? % 空格</code>，通常直接原样粘贴即可。\n"
             "只有账号本身也包含冒号时，才建议改用多行写法：\n"
             "<code>socks5://host:端口\nuser: 账号\npass: 密码\nremote-dns: on</code>\n\n"

             "发送 /cancel 取消。")
        return
    if state and state.get("action") == "add_exit_config":
        config = msg.get("text") or ""
        name = state["name"]
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在添加出口 <b>%s</b>…" % html.escape(name))
        send(chat_id, op_add_exit(name, config), exits_menu())
        return
    if state and state.get("action") == "rules_set":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在校验并应用规则…")
        send(chat_id, op_set_rules(msg.get("text") or ""), rules_menu())
        return
    if state and state.get("action") == "rules_add":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在添加规则…")
        send(chat_id, op_add_rule(text), rules_menu())
        return
    if state and state.get("action") == "rules_del":
        PENDING.pop(chat_id, None)
        send(chat_id, op_del_rule(text), rules_menu())
        return
    if state and state.get("action") == "dot_domain":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在校验域名 A 记录并签发证书，可能需要 1-2 分钟…")
        send(chat_id, op_set_dot_domain(text), dot_menu())
        return
    if state and state.get("action") == "dot_dns":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在更新 DNS 上游并重载 dnsdist/sniproxy…")
        send(chat_id, op_set_dns(text), dot_menu())
        return

    send(chat_id, "未知命令。发送 /menu 打开操作面板。")


def handle_callback(cb):
    uid = cb.get("from", {}).get("id")
    chat_id = cb["message"]["chat"]["id"]
    data = cb.get("data", "")
    cb_id = cb["id"]

    if not authorized(uid):
        tg("answerCallbackQuery", callback_query_id=cb_id, text="⛔ 未授权", show_alert=True)
        return

    # Stop the button spinner without adding another Telegram round-trip before the edit.
    answer_callback_async(cb_id)

    # ---- navigation (edit the same bubble) ----
    if data == "menu:main":
        PENDING.pop(chat_id, None)
        edit(cb, "选择一个操作：", main_menu())
    elif data == "menu:rules":
        edit(cb, "🧭 <b>智能分流</b>：按域名把代理流量分到不同出口 / 直连 / 拒绝。", rules_menu())
    elif data == "menu:policy":
        edit(cb, "🎯 <b>分类 → 出口</b> 映射（点一个分类来修改目标）：", policy_menu())
    elif data == "menu:exits":
        edit(cb, "选择要切换到的出口，或添加/删除：", exits_menu())
    elif data == "menu:exits_del":
        edit(cb, "选择要删除的出口：", exits_del_menu())
    elif data == "menu:dot":
        edit(cb, op_dot_status(), dot_menu())
    elif data == "menu:restart":
        edit(cb, "选择要重启的服务：", services_menu("restart"))
    elif data == "menu:logs":
        edit(cb, "选择要查看日志的服务：", services_menu("logs"))

    # ---- conversational starts (edit prompt into the same bubble) ----
    elif data == "rules:set":
        PENDING[chat_id] = {"action": "rules_set"}
        edit(cb,
             "粘贴<b>整份</b>分流规则（首行优先）。示例：\n"
             "<pre>DOMAIN-SUFFIX,google.com,att\nGEOSITE,netflix,att\n"
             "GEOIP,cn,direct\nFINAL,att</pre>\n"
             "策略：出口名 / <code>direct</code> / <code>block</code>。\n发送 /cancel 取消。")
    elif data == "rules:add":
        PENDING[chat_id] = {"action": "rules_add"}
        edit(cb, "发送要追加的<b>一条</b>规则，例如：\n<code>DOMAIN-SUFFIX,youtube.com,att</code>\n发送 /cancel 取消。")
    elif data == "rules:del":
        PENDING[chat_id] = {"action": "rules_del"}
        edit(cb, op_show_rules() + "\n\n发送要删除的<b>序号</b>，或 /cancel 取消。")
    elif data == "exit_add":
        PENDING[chat_id] = {"action": "add_exit_name"}
        edit(cb, "添加出口：先发一个名字（1-11 位小写字母/数字，如 us / jp / hk）。\n发送 /cancel 取消。")
    elif data == "dot:domain":
        PENDING[chat_id] = {"action": "dot_domain"}
        edit(cb,
             "发送新的 DoT 域名，例如：\n"
             "<code>dns.example.com</code>\n\n"
             "要求：该域名 A 记录必须已经指向本机公网 IP，否则不会修改当前配置。\n"
             "发送 /cancel 取消。")
    elif data == "dot:dns":
        PENDING[chat_id] = {"action": "dot_dns"}
        edit(cb,
             "发送新的 DNS 上游。\n\n"
             "只需要发送一行，多个 DNS 用空格或逗号分隔。\n"
             "这组 DNS 会同时用于私网 DoT、公网 DoT 和 sniproxy。\n\n"
             "示例：\n<pre>1.1.1.1 8.8.8.8 9.9.9.9</pre>\n"
             "发送 /cancel 取消。")

    # ---- views ----
    elif data == "rules:show":
        edit(cb, op_show_rules(), back_kb("menu:rules"))
    elif data == "act:status":
        edit(cb, op_status(), back_kb("menu:main"))
    elif data.startswith("logs:"):
        svc = data[len("logs:"):]
        edit(cb, "📜 正在取 <b>%s</b> 日志…" % html.escape(svc))
        edit(cb, op_logs(svc), back_kb("menu:logs"), mono=True)
    elif data == "exits:check":
        edit(cb, "⏳ 正在检查出口连通性…")
        edit(cb, op_check_exits(), back_kb("menu:exits"))

    # ---- actions (⏳ then result, all in one bubble) ----
    elif data == "act:update_rules":
        edit(cb, "⏳ 正在更新规则，请稍候…")
        edit(cb, op_update_rules(), back_kb("menu:main"))
    elif data == "act:renew":
        edit(cb, "⏳ 正在续期证书，请稍候…")
        edit(cb, op_renew_cert(), back_kb("menu:main"))
    elif data == "rules:enable":
        edit(cb, "⏳ 正在启用智能分流…")
        edit(cb, op_set_exit("smart"), back_kb("menu:rules"))
    elif data.startswith("exit:"):
        name = data[len("exit:"):]
        edit(cb, "⏳ 正在切换出口到 <b>%s</b>…" % html.escape(name))
        edit(cb, op_set_exit(name), back_kb("menu:exits"))
    elif data.startswith("exitdel:"):
        name = data[len("exitdel:"):]
        edit(cb, "⏳ 正在删除出口 <b>%s</b>…" % html.escape(name))
        edit(cb, op_del_exit(name), back_kb("menu:exits"))
    elif data.startswith("restart:"):
        svc = data[len("restart:"):]
        edit(cb, "⏳ 正在重启 <b>%s</b>…" % html.escape(svc))
        edit(cb, op_restart(svc), back_kb("menu:restart"))
    elif data == "act:ios":
        edit(cb, "⏳ 正在生成 iOS 二维码…")
        res = op_ios_send(chat_id)
        if res:                       # photo failed -> show URL text
            edit(cb, res, back_kb("menu:main"))
        else:
            edit(cb, "📱 iOS 描述文件二维码已发送 ↓\n\n选择一个操作：", main_menu())
    elif data.startswith("pol:"):
        try:
            idx = int(data.split(":")[1])
        except (ValueError, IndexError):
            idx = -1
        pm = _policy_map()
        if 0 <= idx < len(pm):
            edit(cb, "把分类 <b>%s</b>（现为 %s）路由到哪里？"
                 % (html.escape(pm[idx][0]), html.escape(pm[idx][1])), policy_targets_menu(idx))
        else:
            edit(cb, "分类已变化，请重新打开。", policy_menu())
    elif data.startswith("ps:"):
        parts = data.split(":", 2)
        pm = _policy_map()
        try:
            idx, target = int(parts[1]), parts[2]
        except (ValueError, IndexError):
            idx, target = -1, ""
        if 0 <= idx < len(pm):
            cat = pm[idx][0]
            edit(cb, "⏳ 正在设置 <b>%s</b> → <b>%s</b> 并重建分流（可能较久）…"
                 % (html.escape(cat), html.escape(target)))
            edit(cb, op_set_policy(cat, target), back_kb("menu:policy"))
        else:
            edit(cb, "分类已变化，请重新打开。", policy_menu())
    else:
        edit(cb, "未知操作。", back_kb("menu:main"))


# Quick command menu (the Telegram "Menu" button / typing "/"), Chinese labels.
BOT_COMMANDS = [
    ("menu", "打开操作面板"),
    ("status", "查看运行状态"),
    ("exits", "出口管理（切换/添加/删除）"),
    ("rules", "智能分流规则"),
    ("cancel", "取消当前操作"),
    ("id", "获取我的 Telegram ID"),
]


def set_commands():
    """Register the Chinese quick-command menu and enable the Menu button."""
    commands = [{"command": c, "description": d} for c, d in BOT_COMMANDS]

    # Old projects may have left narrower scopes (especially all_private_chats)
    # with only /start and /cancel, which Telegram prefers over the default
    # scope in the command menu. Clear common stale scopes, then register the
    # current command set for both default and private chats so fresh installs
    # reliably show the full menu.
    for scope in (
        None,
        {"type": "all_private_chats"},
        {"type": "all_group_chats"},
        {"type": "all_chat_administrators"},
    ):
        params = {}
        if scope is not None:
            params["scope"] = scope
        r = tg("deleteMyCommands", **params)
        if not r.get("ok"):
            print("[warn] deleteMyCommands failed for %s: %s" % (scope or "default", r), file=sys.stderr)

    for scope in (
        None,
        {"type": "all_private_chats"},
    ):
        params = {"commands": commands}
        if scope is not None:
            params["scope"] = scope
        r = tg("setMyCommands", **params)
        if not r.get("ok"):
            print("[warn] setMyCommands failed for %s: %s" % (scope or "default", r), file=sys.stderr)

    # Make the input-box button show the command menu.
    tg("setChatMenuButton", menu_button={"type": "commands"})


# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
def main():
    if not TOKEN:
        print("TG_BOT_TOKEN is not set", file=sys.stderr)
        sys.exit(1)
    if not ADMIN_IDS:
        print("[warn] TG_ADMIN_IDS is empty; no one can operate. Use /id to find yours.",
              file=sys.stderr)

    set_commands()
    print("proxy-gateway tgbot started; admins=%s" % sorted(ADMIN_IDS), file=sys.stderr)
    offset = None
    while True:
        params = {"timeout": 50}
        if offset is not None:
            params["offset"] = offset
        resp = tg("getUpdates", **params)
        if not resp.get("ok"):
            time.sleep(3)
            continue
        for upd in resp.get("result", []):
            offset = upd["update_id"] + 1
            try:
                if "message" in upd:
                    handle_message(upd["message"])
                elif "callback_query" in upd:
                    handle_callback(upd["callback_query"])
            except Exception as e:  # never let one bad update kill the loop
                print("[err] handling update: %s" % e, file=sys.stderr)


if __name__ == "__main__":
    main()
