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
import base64
import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote, urlparse
import urllib.request

TOKEN = os.environ.get("TG_BOT_TOKEN", "").strip()
ADMIN_IDS = {
    int(x) for x in re.split(r"[,\s]+", os.environ.get("TG_ADMIN_IDS", "").strip()) if x
}
MGMT = os.environ.get("MGMT", "/opt/proxy-gateway/bin/proxy-gateway-ctl")
API = "https://api.telegram.org/bot%s/" % TOKEN

# Services the bot may tail. Order matters for display only.
SERVICES = [
    "mosdns",
    "sniproxy",
    "wa-shim",
    "quic-proxy",
    "proxy-gateway-ios-profile",
    "proxy-gateway-tgbot",
]
RESTART_SERVICES = [
    "mosdns",
    "sniproxy",
    "wa-shim",
    "quic-proxy",
    "proxy-gateway-ios-profile.socket",
]
EXIT_NAME_RE = re.compile(r"^(local|[\w\-\u4e00-\u9fff]{1,16})$", re.UNICODE)
EXIT_ADD_NAME_RE = re.compile(r"^[\w\-\u4e00-\u9fff]{1,16}$", re.UNICODE)  # 'local' is reserved
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")
DNS_LIST_RE = re.compile(r"^[0-9A-Fa-f:.,\s]+$")
DNS_UPSTREAM_SCHEMES = {"https", "tls", "udp", "tcp"}
WWW_DIR = "/opt/proxy-gateway/www"

# Per-chat conversational state for multi-step flows (e.g. add-exit).
PENDING = {}
BUSY = set()
# Per-chat "console" message: menus, progress and results are edited into this
# single bubble instead of sending a new message every time.
CONSOLE = {}
LAST_FAILED_DOT_DOMAIN = {}
PROXY_URI_RE = re.compile(r"^(ss|vmess|trojan|vless|hysteria2|hy2|tuic|anytls|socks5h|socks5|socks|http|https)://", re.I)
SUPPORTED_EXIT_LINKS = "ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://"


# --------------------------------------------------------------------------- #
# Telegram API
# --------------------------------------------------------------------------- #
_TG_LOCAL = threading.local()
_BG_EXECUTOR = ThreadPoolExecutor(max_workers=6, thread_name_prefix="pgw-bg")
_CALLBACK_EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="pgw-callback")
_EXIT_WRITE_LOCK = threading.Lock()
_TG_API_TIMEOUT = 12
_TG_POLL_TIMEOUT = 35
_TG_API_IDLE_SECONDS = 25


def _tg_slot(method):
    return "poll" if method == "getUpdates" else "api"


def _close_tg_conn(slot):
    conn = getattr(_TG_LOCAL, slot + "_conn", None)
    try:
        if conn:
            conn.close()
    except Exception:
        pass
    setattr(_TG_LOCAL, slot + "_conn", None)
    setattr(_TG_LOCAL, slot + "_last_used", 0.0)


def _configure_tg_socket(conn, timeout):
    """Keep long polls alive through short-idle NATs and bound API stalls."""
    conn.timeout = timeout
    sock = getattr(conn, "sock", None)
    if sock is None:
        return
    try:
        sock.settimeout(timeout)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        for name, value in (("TCP_KEEPIDLE", 15), ("TCP_KEEPINTVL", 5), ("TCP_KEEPCNT", 3)):
            option = getattr(socket, name, None)
            if option is not None:
                sock.setsockopt(socket.IPPROTO_TCP, option, value)
    except OSError:
        pass


def tg(method, **params):
    data = json.dumps(params).encode("utf-8")
    path = "/bot%s/%s" % (TOKEN, method)
    headers = {"Content-Type": "application/json", "Connection": "keep-alive"}
    slot = _tg_slot(method)
    timeout = _TG_POLL_TIMEOUT if slot == "poll" else _TG_API_TIMEOUT
    conn = getattr(_TG_LOCAL, slot + "_conn", None)
    last_used = getattr(_TG_LOCAL, slot + "_last_used", 0.0)
    if slot == "api" and conn is not None and time.monotonic() - last_used > _TG_API_IDLE_SECONDS:
        _close_tg_conn(slot)
    for attempt in (0, 1):
        try:
            conn = getattr(_TG_LOCAL, slot + "_conn", None)
            if conn is None:
                conn = http.client.HTTPSConnection("api.telegram.org", timeout=timeout)
                setattr(_TG_LOCAL, slot + "_conn", conn)
            _configure_tg_socket(conn, timeout)
            conn.request("POST", path, data, headers)
            _configure_tg_socket(conn, timeout)
            raw = conn.getresponse().read()
            setattr(_TG_LOCAL, slot + "_last_used", time.monotonic())
            return json.loads(raw.decode("utf-8")) if raw else {}
        except Exception as e:
            try:
                conn = getattr(_TG_LOCAL, slot + "_conn", None)
                if conn:
                    conn.close()
            except Exception:
                pass
            setattr(_TG_LOCAL, slot + "_conn", None)
            setattr(_TG_LOCAL, slot + "_last_used", 0.0)
            if attempt:
                return {"ok": False, "error": str(e)}


def background(fn, *args):
    def go():
        try:
            fn(*args)
        except Exception as e:
            print("[err] background task: %s" % e, file=sys.stderr)

    _BG_EXECUTOR.submit(go)


def answer_callback_async(cb_id):
    def go():
        tg("answerCallbackQuery", callback_query_id=cb_id)

    _CALLBACK_EXECUTOR.submit(go)


def send(chat_id, text, keyboard=None, mono=False):
    # mono=True: paginate raw command output across one or more monospace
    # messages (escaped + wrapped per chunk, so HTML never splits mid-tag).
    # Returns the message_id of the last message sent (None if unavailable).
    if mono:
        text = (text or "").strip() or "(no output)"
        chunks = [text[i : i + 3500] for i in range(0, len(text), 3500)] or [""]
        wrapped = ["<pre>" + html.escape(c) + "</pre>" for c in chunks]
    else:
        wrapped = list(_chunks(text, 3900))
    last = len(wrapped) - 1
    last_mid = None
    for i, chunk in enumerate(wrapped):
        params = {
            "chat_id": chat_id,
            "text": chunk,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }
        if keyboard is not None and i == last:
            params["reply_markup"] = {"inline_keyboard": keyboard}
        r = tg("sendMessage", **params)
        if isinstance(r, dict) and r.get("ok"):
            mid = (r.get("result") or {}).get("message_id")
            if mid is not None:
                last_mid = mid
    return last_mid


def delete_message(chat_id, message_id):
    if message_id is None:
        print("[warn] deleteMessage failed chat_id=%s message_id=None error_code=- description=missing message_id"
              % chat_id, file=sys.stderr)
        return False
    try:
        response = tg("deleteMessage", chat_id=chat_id, message_id=message_id)
    except Exception as e:
        response = {"ok": False, "error": "exception:%s" % type(e).__name__}
    if isinstance(response, dict) and response.get("ok"):
        return True
    if isinstance(response, dict):
        error_code = response.get("error_code", "-")
        description = response.get("description") or response.get("error") or "unknown error"
    else:
        error_code = "-"
        description = "malformed response"
    description = " ".join(str(description).split())[:500]
    print("[warn] deleteMessage failed chat_id=%s message_id=%s error_code=%s description=%s"
          % (chat_id, message_id, error_code, description), file=sys.stderr)
    return False


def _chunks(text, size):
    if not text:
        yield ""
        return
    for i in range(0, len(text), size):
        yield text[i : i + size]


def edit_message(chat_id, message_id, text, keyboard=None, mono=False):
    """editMessageText without a callback_query. Returns True when the message
    now shows the requested content ("message is not modified" counts as
    success and is ignored quietly)."""
    if chat_id is None or message_id is None:
        return False
    if mono:
        text = "<pre>" + html.escape(((text or "").strip() or "(no output)")[:3800]) + "</pre>"
    params = {
        "chat_id": chat_id, "message_id": message_id, "text": (text or "")[:4096],
        "parse_mode": "HTML", "disable_web_page_preview": True,
    }
    if keyboard is not None:
        params["reply_markup"] = {"inline_keyboard": keyboard}
    try:
        r = tg("editMessageText", **params)
    except Exception as e:
        print("[warn] editMessageText failed chat_id=%s message_id=%s error=%s"
              % (chat_id, message_id, type(e).__name__), file=sys.stderr)
        return False
    if isinstance(r, dict) and r.get("ok"):
        return True
    return "not modified" in str(r)


def upsert_console(chat_id, text, keyboard=None, mono=False, message_id=None):
    """Update the per-chat console message in place; fall back to a new
    message only when editing is impossible (deleted / too old / media).
    Returns the message_id that now shows the content."""
    mid = message_id if message_id is not None else CONSOLE.get(chat_id)
    if mid is not None and edit_message(chat_id, mid, text, keyboard, mono):
        CONSOLE[chat_id] = mid
        return mid
    new_mid = send(chat_id, text, keyboard, mono)
    if new_mid is not None:
        CONSOLE[chat_id] = new_mid
    return new_mid


def console_async(chat_id, text_fn, keyboard=None, mono=False, keyboard_fn=None, message_id=None):
    """Run text_fn in the background, then edit the result into the console
    message (no extra "processing"/"result" message pair)."""
    mid = message_id if message_id is not None else CONSOLE.get(chat_id)

    def go():
        text = text_fn()
        kb = keyboard_fn() if keyboard_fn else keyboard
        upsert_console(chat_id, text, kb, mono, message_id=mid)

    background(go)


def reanchor_console(chat_id, text, keyboard=None, mono=False):
    """Slash commands must always be visible: send a fresh console message at
    the bottom of the chat and drop the old one (editing an old/cleared
    message would look like the bot did not respond). Returns the new
    console message_id."""
    old = CONSOLE.pop(chat_id, None)
    new_mid = send(chat_id, text, keyboard, mono)
    if new_mid is not None:
        CONSOLE[chat_id] = new_mid
        if old is not None and old != new_mid:
            background(delete_message, chat_id, old)
    return new_mid


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
    if r.get("ok"):
        CONSOLE[chat_id] = mid
        return
    if "not modified" in str(r):
        CONSOLE[chat_id] = mid
        return  # nothing to do
    # original may be a photo / too old / gone -> delete it and post a fresh
    # message so the user doesn't see an orphaned media bubble above the menu.
    # text is already HTML-formatted when mono=True; pass mono=False so send()
    # does not double-escape it.
    if mid is not None:
        delete_message(chat_id, mid)
    new_mid = send(chat_id, text, keyboard if keyboard else None, mono=False)
    if new_mid is not None:
        CONSOLE[chat_id] = new_mid


def _busy_key_from_cb(cb):
    msg = cb.get("message", {})
    chat_id = msg.get("chat", {}).get("id")
    mid = msg.get("message_id")
    return (chat_id, mid)


def edit_async(cb, text_fn, keyboard=None, mono=False):
    key = _busy_key_from_cb(cb)

    def go():
        try:
            edit(cb, text_fn(), keyboard, mono)
        finally:
            BUSY.discard(key)

    BUSY.add(key)
    background(go)


def edit_ios_async(cb, chat_id):
    key = _busy_key_from_cb(cb)

    def go():
        try:
            res = op_ios_send_inline(cb)
            if res:
                edit(cb, res, back_kb("menu:main"))
        finally:
            BUSY.discard(key)

    BUSY.add(key)
    background(go)


def back_kb(target="menu:main", label="« 返回"):
    return [[{"text": label, "callback_data": target}]]


def cancel_kb(section):
    return [[{"text": "✖ 取消", "callback_data": "cancel:" + section}]]


def add_exit_retry_kb():
    return [[{"text": "➕ 重新添加", "callback_data": "exit_add"}],
            [{"text": "« 返回", "callback_data": "menu:exits"}]]


def status_kb():
    return [[{"text": "🔄 刷新", "callback_data": "act:status_refresh"}],
            [{"text": "« 返回", "callback_data": "menu:main"}]]


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
    except Exception as e:
        # Rare: TG API rejects the photo upload (size, format, transient 5xx).
        # The caller falls back to a text-only URL reply, but without this
        # log we'd have zero forensic trail for "why did the QR disappear?".
        print("[warn] send_photo failed: %s" % e, file=sys.stderr)
        return False


def edit_message_media(cb, photo_path, caption="", keyboard=None):
    """Replace the callback message content with a photo in-place using
    editMessageMedia (multipart upload). Keeps the QR inside the same bubble
    instead of sending a separate photo message."""
    msg = cb.get("message", {})
    chat_id = msg.get("chat", {}).get("id")
    mid = msg.get("message_id")
    if chat_id is None or mid is None:
        return False
    try:
        with open(photo_path, "rb") as f:
            photo_data = f.read()
    except OSError:
        return False
    boundary = "----pgwEditMedia9c4e7d"

    def _field(name, val):
        return ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                % (boundary, name, val)).encode("utf-8")

    media_obj = {"type": "photo", "media": "attach://photo"}
    if caption:
        media_obj["caption"] = caption
        media_obj["parse_mode"] = "HTML"
    body = _field("chat_id", str(chat_id))
    body += _field("message_id", str(mid))
    body += _field("media", json.dumps(media_obj))
    if keyboard is not None:
        body += _field("reply_markup", json.dumps({"inline_keyboard": keyboard}))
    body += ("--%s\r\nContent-Disposition: form-data; name=\"photo\"; "
             "filename=\"qr.png\"\r\nContent-Type: image/png\r\n\r\n" % boundary).encode("utf-8")
    body += photo_data + b"\r\n" + ("--%s--\r\n" % boundary).encode("utf-8")
    req = urllib.request.Request(
        API + "editMessageMedia", data=body,
        headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            r = json.loads(resp.read().decode("utf-8"))
            if r.get("ok"):
                CONSOLE[chat_id] = mid
                return True
    except Exception as e:
        print("[warn] editMessageMedia failed: %s" % e, file=sys.stderr)
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


def validate_mgmt_path():
    if not os.path.isabs(MGMT) or not os.path.isfile(MGMT):
        print("MGMT must be an absolute path to the management script: %s" % MGMT,
              file=sys.stderr)
        sys.exit(1)


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
    lines = [line.strip() for line in _strip_ansi(out).splitlines() if line.strip()]
    errs = [line for line in lines if re.search(r"\[!\]|\[ERR\]|error|fail|invalid|拒绝|失败", line, re.I)]
    picked = (errs or lines)[-n:]
    text = "\n".join(picked)
    return (text[:600] + "…") if len(text) > 600 else text


def _tail_output(out, n=20, limit=1800):
    lines = [line.rstrip() for line in _strip_ansi(out).splitlines() if line.strip()]
    text = "\n".join(lines[-n:]) or "(no output)"
    return (text[-limit:] + "…") if len(text) > limit else text


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
    ("mosdns", "mosdns"),
    ("sniproxy", "sniproxy"),
    ("quic-proxy", "quic-proxy"),
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

    domain = _read_file("/etc/mosdns/.domain") or _read_file("/opt/proxy-gateway/etc/.domain")
    if domain:
        lines.append("🔗 域名：<code>%s</code>" % html.escape(domain))

    cs = _read_file("/etc/mosdns/.cache_size")
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


def op_rename_exit(old_name, new_name):
    if not EXIT_ADD_NAME_RE.match(old_name) or old_name in ("local", "smart"):
        return "原出口名无效。"
    if not EXIT_ADD_NAME_RE.match(new_name) or new_name in ("local", "smart"):
        return "新出口名无效（需 1-16 位字母/数字/中文/_/-，且不能为 local/smart）。"
    if old_name == new_name:
        return "新旧名称相同，无需重命名。"
    ok, out = run2(["bash", MGMT, "--rename-exit", old_name, new_name], timeout=180)
    if ok:
        return "✅ 出口 <b>%s</b> 已重命名为 <b>%s</b>" % (html.escape(old_name), html.escape(new_name))
    return "❌ <b>重命名失败</b>\n%s" % html.escape(_reason(out))


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


def exits_overview_text():
    cur = _read_file("/opt/proxy-gateway/etc/current-exit") or "local"
    if cur == "local":
        desc = "本机直出"
    else:
        desc = _read_file("/etc/proxy-gateway/exits/%s.type" % cur) or "?"
    ip = _exit_ip()
    if ip:
        ip_line = "🌍 出口 IP：<code>%s</code>" % html.escape(ip)
    else:
        ip_line = "🌍 出口 IP：<i>探测失败</i>"
    return ("🌐 当前出口：<b>%s</b>（%s）\n%s\n\n"
            "选择要切换到的出口，或添加/删除："
            % (html.escape(cur), html.escape(desc), ip_line))


def op_add_exit(name, payload):
    if not EXIT_ADD_NAME_RE.match(name) or name == "local":
        return "出口名无效（需 1-16 位字母/数字/中文/_/-，且不能为 local）。"
    text = (payload or "").strip()
    is_uri = bool(PROXY_URI_RE.match(text))
    is_wg = "[Interface]" in payload and "[Peer]" in payload
    if not is_uri and not is_wg:
        return ("无法识别。请发送一段 WireGuard 配置（含 [Interface]/[Peer]），"
                "或一个 ss:// / vmess:// / trojan:// / vless:// / hysteria2:// / tuic:// / anytls:// / socks5:// / http:// URI。")
    ok, out = run2(["bash", MGMT, "--add-exit", name], inp=payload, timeout=180)
    if ok:
        m = re.search(r"type:\s*(\w+)", out)
        return ("✅ 出口 <b>%s</b> 已添加（%s）\n在「🌐 出口」里点它即可切换。"
                % (html.escape(name), m.group(1) if m else "?"))
    return "❌ <b>添加失败</b>\n%s" % html.escape(_reason(out))


def mask_uri_secret(uri):
    text = (uri or "").strip()
    if not text:
        return ""
    try:
        if text.lower().startswith("vmess://"):
            return "vmess://***"
        parsed = urlparse(text)
        if not parsed.scheme:
            return text[:24] + ("…" if len(text) > 24 else "")
        host = parsed.hostname or "?"
        port = ":%s" % parsed.port if parsed.port else ""
        label = "%s://%s%s" % (parsed.scheme, host, port)
        if parsed.fragment:
            label += "#" + parsed.fragment[:12]
        return label
    except Exception:
        return text[:24] + ("…" if len(text) > 24 else "")


def _normalize_batch_add_line(line):
    raw = (line or "").strip()
    if not raw:
        return "", "", ""
    parts = raw.split(None, 1)
    if len(parts) == 2 and EXIT_ADD_NAME_RE.match(parts[0]) and parts[0] != "local" and PROXY_URI_RE.match(parts[1].strip()):
        return parts[0], parts[1].strip(), raw
    return "", raw, raw


def parse_add_exit_inputs(payload):
    lines = [(line or "").strip() for line in (payload or "").splitlines()]
    lines = [line for line in lines if line]
    if not lines:
        return [], "请直接粘贴一条或多条节点链接，每行一条。"
    items = []
    for index, line in enumerate(lines, 1):
        explicit_name, config_text, raw = _normalize_batch_add_line(line)
        if "[Interface]" in config_text and "[Peer]" in config_text:
            return [], "第 %d 行是 WireGuard 配置。Bot 批量添加仅支持 URI；WireGuard 请改用命令行指定名称添加。" % index
        name, config, err = parse_add_exit_input(raw)
        if explicit_name:
            name = explicit_name
            config = config_text
            err = ""
        if err:
            return [], "第 %d 行：%s" % (index, err)
        items.append({"index": index, "name": name, "payload": config.strip(), "masked": mask_uri_secret(config)})
    return items, ""


def op_add_exit_batch(items):
    if not items:
        return "没有可添加的出口。"

    try:
        results = []
        with _EXIT_WRITE_LOCK:
            reserved = set(parse_exit_names())
            assigned = set()
            for item in items:
                requested = item["name"]
                final = requested
                if final in reserved or final in assigned:
                    base = clean_exit_name(requested)
                    final = ""
                    if base:
                        for i in range(2, 100):
                            suffix = "-%d" % i
                            cand = (base[:16 - len(suffix)] + suffix).strip("-_")
                            if cand and cand not in reserved and cand not in assigned and EXIT_ADD_NAME_RE.match(cand):
                                final = cand
                                break
                    if not final:
                        results.append("❌ %d. <b>%s</b>：无法生成不冲突的名称" % (item["index"], html.escape(requested)))
                        continue
                assigned.add(final)
                item["final_name"] = final

            for item in items:
                final = item.get("final_name")
                if not final:
                    continue
                text = op_add_exit(final, item["payload"])
                item["payload"] = ""
                if text.startswith("✅"):
                    if final != item["name"]:
                        results.append("✅ %d. <b>%s</b>（由 %s 自动去重）" % (
                            item["index"], html.escape(final), html.escape(item["name"])))
                    else:
                        results.append("✅ %d. <b>%s</b>" % (item["index"], html.escape(final)))
                    reserved.add(final)
                else:
                    results.append("❌ %d. <b>%s</b>：添加失败，请检查服务日志" % (
                        item["index"], html.escape(final)))

        ok_count = sum(1 for line in results if line.startswith("✅"))
        fail_count = sum(1 for line in results if line.startswith("❌"))
        head = "批量添加完成：✅ %d，❌ %d" % (ok_count, fail_count)
        return head + "\n" + "\n".join(results)
    finally:
        for item in items:
            item["payload"] = ""
            item.pop("masked", None)


def b64decode_text(s):
    pad = "=" * (-len(s) % 4)
    for dec in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return dec(s + pad).decode("utf-8")
        except Exception:
            continue
    return ""


def clean_exit_name(name):
    name = unquote(name or "").strip()
    name = re.sub(r"[^\w\-\u4e00-\u9fff]+", "-", name, flags=re.UNICODE).strip("-_")
    name = name[:16]
    if not name or name == "local" or not EXIT_ADD_NAME_RE.match(name):
        return ""
    return name


def unique_exit_name(name):
    base = clean_exit_name(name)
    if not base:
        return ""
    existing = set(parse_exit_names())
    if base not in existing:
        return base
    for i in range(2, 100):
        suffix = "-%d" % i
        cand = (base[:16 - len(suffix)] + suffix).strip("-_")
        if cand and cand not in existing and EXIT_ADD_NAME_RE.match(cand):
            return cand
    return ""


def exit_name_from_uri(uri):
    if uri.lower().startswith("vmess://"):
        try:
            data = json.loads(b64decode_text(uri[len("vmess://"):].strip()))
        except Exception:
            data = {}
        return unique_exit_name(data.get("ps") or "")
    try:
        return unique_exit_name(urlparse(uri).fragment)
    except Exception:
        return ""


def parse_add_exit_input(payload):
    config = (payload or "").strip()
    if not config:
        return "", "", "请直接粘贴一条节点链接，或发送 <code>出口名 链接</code>。"
    first = config.splitlines()[0].strip()
    parts = first.split(None, 1)
    if len(parts) == 2 and EXIT_ADD_NAME_RE.match(parts[0]) and parts[0] != "local" and PROXY_URI_RE.match(parts[1].strip()):
        return parts[0], config.replace(first, parts[1].strip(), 1), ""
    if "[Interface]" in config and "[Peer]" in config:
        return "", "", "WireGuard 配置本身没有节点名称。请改用命令行指定出口名添加。"
    if not PROXY_URI_RE.match(first):
        return "", "", "无法识别。请直接粘贴支持的节点链接：<code>%s</code>，或整段 WireGuard 配置。" % SUPPORTED_EXIT_LINKS
    name = exit_name_from_uri(first)
    if not name:
        return "", "", "这条节点链接没有可用名称。请改用：<code>出口名 链接</code>。"
    return name, config, ""


RULE_TYPES = [
    "DOMAIN",
    "DOMAIN-SUFFIX",
    "DOMAIN-KEYWORD",
    "GEOSITE",
    "GEOIP",
    "IP-CIDR",
]
# Beginner-friendly Chinese button labels; callback_data keeps the raw type.
RULE_TYPE_LABELS = {
    "DOMAIN": "精确域名（DOMAIN）",
    "DOMAIN-SUFFIX": "域名及子域名（DOMAIN-SUFFIX）",
    "DOMAIN-KEYWORD": "域名关键词（DOMAIN-KEYWORD）",
    "GEOSITE": "网站分类（GEOSITE）",
    "GEOIP": "IP 归属地（GEOIP）",
    "IP-CIDR": "IP 网段（IP-CIDR）",
}


def rule_type_menu():
    rows = []
    for value in RULE_TYPES:
        rows.append([{"text": RULE_TYPE_LABELS.get(value, value),
                      "callback_data": "raddt:%s" % value}])
    rows.append([{"text": "⌨️ 手工完整规则", "callback_data": "rules:add_manual"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:rules"}])
    return rows


def _rule_target_buttons(prefix):
    rows, row = [], []
    for target in _targets():
        row.append({"text": target, "callback_data": "%s:%s" % (prefix, target)})
        if len(row) == 3:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([{"text": "🌍 直连", "callback_data": "%s:direct" % prefix},
                 {"text": "🚫 拒绝", "callback_data": "%s:block" % prefix}])
    rows.append([{"text": "« 返回", "callback_data": "rules:add"}])
    return rows


def validate_rule_value(rule_type, value):
    value = (value or "").strip()
    if not value:
        return "匹配值不能为空。"
    if rule_type in ("DOMAIN", "DOMAIN-SUFFIX"):
        if not DOMAIN_RE.match(value):
            return "域名格式无效。"
    elif rule_type == "DOMAIN-KEYWORD":
        if any(ch in value for ch in "\r\n,"):
            return "DOMAIN-KEYWORD 不能包含逗号或换行。"
    elif rule_type in ("GEOSITE", "GEOIP"):
        if not re.match(r"^[A-Za-z0-9._:-]+$", value):
            return "%s 名称无效。" % rule_type
    elif rule_type == "IP-CIDR":
        try:
            ipaddress.ip_network(value, strict=False)
        except ValueError:
            return "IP-CIDR 格式无效。"
    return ""


def rule_value_prompt(rule_type):
    hints = {
        "DOMAIN": "精确匹配一个域名（不含子域名）。\n示例：<code>openai.com</code>",
        "DOMAIN-SUFFIX": "匹配该域名及其所有子域名。\n示例：<code>google.com</code>",
        "DOMAIN-KEYWORD": "域名中包含该关键词即匹配。\n示例：<code>netflix</code>",
        "GEOSITE": "按 GeoSite 网站分类匹配（如 telegram、netflix）。\n示例：<code>telegram</code>",
        "GEOIP": "按目标 IP 的归属地区匹配（国家/地区代码）。\n示例：<code>cn</code>",
        "IP-CIDR": "匹配目标 IP 网段（CIDR 格式）。\n示例：<code>1.2.3.0/24</code>",
    }
    return ("➕ <b>添加规则</b>\n\n"
            "已选择类型：<code>%s</code>\n"
            "请发送匹配值。\n\n%s" % (html.escape(rule_type), hints.get(rule_type, "")))


def op_del_exit(name):
    if not EXIT_ADD_NAME_RE.match(name) or name in ("local", "smart"):
        return "出口名无效（不能删除 local/smart）。"
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
    # Also refresh mihomo smart routing rule-sets (re-download remote rule-sets)
    smart_active = _is_active("proxy-gateway-mihomo@smart.service") == "active"
    if smart_active:
        run2(["systemctl", "restart", "proxy-gateway-mihomo@smart.service"], timeout=60)
        parts.append("• 远程规则集已刷新（mihomo 重载）")
    return "\n".join(parts)


def op_renew_cert():
    ok, out = run2(["bash", MGMT, "--renew-cert"], timeout=600)
    if ok:
        return "✅ <b>证书已续期</b>并重载 mosdns"
    return "❌ <b>证书续期失败</b>\n<pre>%s</pre>" % html.escape(_tail_output(out))


DOT_CERT_PATH = "/etc/mosdns/certs/fullchain.pem"


def _cert_expiry(path=DOT_CERT_PATH):
    """Return (days_left, 'YYYY-MM-DD') for the DoT certificate, or (None, None)."""
    if not os.path.exists(path):
        return None, None
    ok, out = run2(["openssl", "x509", "-noout", "-enddate", "-in", path], timeout=10)
    if not ok or "notAfter=" not in out:
        return None, None
    raw = out.split("notAfter=", 1)[1].strip()
    try:
        expires = datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        return None, None
    days = (expires - datetime.now(timezone.utc)).days
    return days, expires.strftime("%Y-%m-%d")


def _cert_status_line():
    days, date = _cert_expiry()
    if days is None:
        return "证书剩余：<code>未知（未找到证书）</code>"
    if days < 0:
        return "证书剩余：⚠️ <b>已过期 %d 天</b>（到期：%s）" % (-days, date)
    if days <= 14:
        return "证书剩余：⚠️ <b>%d 天</b>（到期：%s，建议尽快续期）" % (days, date)
    return "证书剩余：<code>%d 天</code>（到期：%s）" % (days, date)


def op_dot_status():
    domain = _read_file("/etc/mosdns/.domain") or _read_file("/opt/proxy-gateway/etc/.domain") or "未设置"
    remote_dns = (_read_file("/etc/mosdns/.remote_dns") or
                  _read_file("/etc/mosdns/.overseas_dns") or "?")
    local_dns = (_read_file("/etc/mosdns/.local_dns") or "?")
    lines = [
        "🔐 <b>DoT 管理</b>",
        "当前域名：<code>%s</code>" % html.escape(domain),
    ]
    lines.extend([
        "国际 DNS：<code>%s</code>" % html.escape(remote_dns),
        "国内 DNS：<code>%s</code>" % html.escape(local_dns),
        _cert_status_line(),
    ])
    return "\n".join(lines)


def op_set_dot_domain(domain):
    domain = (domain or "").strip().lower().rstrip(".")
    if not DOMAIN_RE.match(domain):
        return ("域名格式无效。请发送类似 <code>dns.example.com</code> 的完整域名。", None)
    ok, out = run2(["bash", MGMT, "--set-dot-domain", domain], timeout=900)
    if ok:
        return (("✅ <b>DoT 域名已更新</b>\n"
                 "当前域名：<code>%s</code>\n"
                 "证书已签发并重载 mosdns。iOS 用户请重新生成二维码。" % html.escape(domain)), None)
    text = ("❌ <b>DoT 域名更新失败</b>\n%s\n\n"
            "如果你确认域名已经解析到本机，也可以强制更换域名。\n"
            "注意：强制更换会跳过本次证书签发，DoT 客户端可能因为证书不匹配暂时无法连接；修好 80 端口/certbot 问题后请再点续期证书。" %
            html.escape(_reason(out)))
    return (text, domain)


def op_force_set_dot_domain(domain):
    domain = (domain or "").strip().lower().rstrip(".")
    if not DOMAIN_RE.match(domain):
        return "域名格式无效。"
    ok, out = run2(["bash", MGMT, "--set-dot-domain-force", domain], timeout=600)
    if ok:
        return ("⚠️ <b>DoT 域名已强制更换</b>\n"
                "当前域名：<code>%s</code>\n"
                "本次没有签发新证书。请排查端口 80 / certbot 后，再点 <b>续期证书</b>。" % html.escape(domain))
    return "❌ <b>强制更换域名失败</b>\n%s" % html.escape(_reason(out))


def force_dot_domain_kb():
    return [
        [{"text": "⚠️ 仍要强制更换域名", "callback_data": "dot:force_domain"}],
        [{"text": "« 返回", "callback_data": "menu:dot"}],
    ]


def _dns_arg(text):
    value = (text or "").strip()
    if not value:
        return ""
    items = value.replace(",", " ").split()
    for item in items:
        if "://" not in item:
            if not DNS_LIST_RE.fullmatch(item):
                return ""
            continue
        try:
            parsed = urlparse(item)
            ipaddress.ip_address(parsed.hostname or "")
            port = parsed.port
        except (ValueError, TypeError):
            return ""
        if (parsed.scheme not in DNS_UPSTREAM_SCHEMES or parsed.username or
                parsed.password or parsed.query or parsed.fragment or
                (port is not None and not 1 <= port <= 65535)):
            return ""
        if parsed.scheme == "https":
            if parsed.path != "/dns-query":
                return ""
        elif parsed.path not in ("", "/"):
            return ""
    return " ".join(items)


def current_remote_dns():
    return (_read_file("/etc/mosdns/.remote_dns") or
            _read_file("/etc/mosdns/.overseas_dns") or "?")


def current_local_dns():
    return _read_file("/etc/mosdns/.local_dns") or "?"


def op_set_dns(kind, text):
    dns = _dns_arg(text)
    if not dns:
        return ("DNS 格式无效。支持 IP[:端口]，或 https://IP/dns-query、"
                "tls://IP:853、udp://IP:53、tcp://IP:53；多个地址用空格或逗号分隔。")
    if kind == "remote":
        remote_dns = dns
        local_dns = current_local_dns()
    elif kind == "local":
        remote_dns = current_remote_dns()
        local_dns = dns
    else:
        return "DNS 类型无效。"
    if remote_dns == "?" or local_dns == "?":
        return "当前 DNS 配置不完整，请先在服务器上执行一次 --set-dns。"
    cmd = ["bash", MGMT, "--set-dns", remote_dns, local_dns]
    ok, out = run2(cmd, timeout=600)
    if ok:
        label = "国际 DNS" if kind == "remote" else "国内 DNS"
        return "✅ <b>%s 已更新</b>\n<code>%s</code>" % (label, html.escape(dns))
    return "❌ <b>DNS 上游更新失败</b>\n%s" % html.escape(_reason(out))


def op_restart_services():
    results = []
    failed = False
    for svc in RESTART_SERVICES:
        run2(["systemctl", "restart", svc], timeout=60)
        state = _is_active(svc)
        ok = state in ("active", "listening")
        failed = failed or not ok
        label = svc[:-len(".socket")] if svc.endswith(".socket") else svc
        results.append(("✅" if ok else "❌") + " " + html.escape(label) + "（%s）" % html.escape(state))
    head = "❌ <b>部分服务重启异常</b>" if failed else "✅ <b>服务已重启</b>"
    return head + "\n" + "\n".join(results)


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
    entries = [(i, line) for i, line in enumerate(lines)
               if line.strip() and not line.strip().startswith(("#", ";"))]
    return lines, entries


def op_show_rules():
    _, entries = _rule_entries()
    if not entries:
        return "（还没有分流规则）\n用「✏️ 规则设置」粘贴一份，或「➕ 添加规则」逐条添加。"
    body = "\n".join("%d. %s" % (i + 1, e[1].strip()) for i, e in enumerate(entries))
    return "📋 <b>当前分流规则</b>（%d 条）：\n<pre>%s</pre>" % (len(entries), html.escape(body))


def _ruleset_entries():
    """Return (all file lines, [(line_index, text)] for RULE-SET lines only)."""
    txt = _read_file(RULES_PATH)
    lines = txt.splitlines() if txt else []
    entries = [(i, line) for i, line in enumerate(lines)
               if line.strip().upper().startswith("RULE-SET,")]
    return lines, entries


def _plain_rule_entries():
    """Return effective rules excluding RULE-SET entries managed separately."""
    lines, entries = _rule_entries()
    return lines, [(i, line) for i, line in entries
                   if not line.strip().upper().startswith("RULE-SET,")]


def op_show_rulesets():
    _, entries = _ruleset_entries()
    if not entries:
        return "（还没有规则集）\n用「➕ 添加规则集」添加远程或本地规则集。"
    body = []
    for i, (_, line) in enumerate(entries):
        parts = line.strip().split(",", 2)
        if len(parts) >= 3:
            url = parts[1].strip()
            target = parts[2].strip()
            # shorten long URLs for display
            short_url = url if len(url) <= 50 else url[:47] + "…"
            body.append("%d. %s → <b>%s</b>" % (i + 1, html.escape(short_url), html.escape(target)))
        else:
            body.append("%d. %s" % (i + 1, html.escape(line.strip())))
    return "📚 <b>当前规则集</b>（%d 个）：\n%s" % (len(entries), "\n".join(body))


def _entry_token(text):
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()[:10]


def _delete_entry(entries_fn, index, token, empty_text):
    lines, entries = entries_fn()
    if not entries:
        return empty_text
    if index < 0 or index >= len(entries) or _entry_token(entries[index][1]) != token:
        return "规则列表已经变化，请返回后重新打开删除列表。"
    drop = entries[index][0]
    return op_set_rules("\n".join(line for i, line in enumerate(lines) if i != drop) + "\n")


def op_del_ruleset_button(index, token):
    return _delete_entry(_ruleset_entries, index, token, "当前没有规则集可删除。")


def op_set_rules(text):
    if not (text or "").strip():
        return "规则不能为空。"
    # Always goes through --set-rules, so mihomo validates before commit.
    ok, out = run2(["bash", MGMT, "--set-rules"], inp=text, timeout=180)
    if ok:
        m = re.search(r"\((\d+) rules\)", out)
        return ("✅ <b>分流规则已更新</b>（%s 条）\n用「⚡ 启用分流」或在 🌐 出口 选 smart 生效。"
                % (m.group(1) if m else "?"))
    return "❌ <b>规则设置失败</b>\n%s" % html.escape(_reason(out))


def op_add_rule(line):
    line = (line or "").strip()
    if not line:
        return "规则不能为空。"
    txt = _read_file(RULES_PATH)
    newtext = (txt.rstrip("\n") + "\n" + line + "\n") if txt.strip() else (line + "\n")
    return op_set_rules(newtext)


def op_add_ruleset(text):
    parts = (text or "").strip().split(None, 1)
    if len(parts) != 2:
        return "请发送：<code>规则集URL 目标</code>，目标可为出口名、分类、direct 或 block。"
    source, target = parts
    if not re.match(r"^https?://\S+$", source):
        return "规则集必须是 http(s) URL。"
    if not target.strip() or any(ch in target for ch in "\r\n,"):
        return "规则集目标无效。"
    ok, out = run2(["bash", MGMT, "--add-ruleset", source, target.strip()], timeout=600)
    if ok:
        return "✅ <b>规则集已添加</b>\n<code>%s</code> → <b>%s</b>" % (
            html.escape(source), html.escape(target.strip()))
    return "❌ <b>规则集添加失败</b>\n%s" % html.escape(_reason(out))


def op_del_rule_button(index, token):
    return _delete_entry(_plain_rule_entries, index, token, "当前没有规则可删除。")


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


def _format_check_exit_row(name, endpoint, state):
    mapping = {"UP": "✅", "DOWN": "❌", "N/A": "➖", "N/A?": "➖", "n/a": "➖"}
    mark = mapping.get(state.upper() if state else "", "➖")
    detail = "<code>%s</code>" % html.escape(endpoint) if endpoint and endpoint != "-" else "<i>n/a</i>"
    return "%s <b>%s</b>  %s" % (mark, html.escape(name), detail)


def parse_check_exits_output(out):
    rows = []
    for raw in _strip_ansi(out).splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = re.split(r"\s{2,}", line)
        if len(parts) >= 3:
            name = parts[0].strip()
            endpoint = parts[1].strip() or "-"
            state = parts[2].strip()
        else:
            parts = line.split()
            if len(parts) < 2:
                continue
            name = parts[0]
            state = parts[-1]
            endpoint = " ".join(parts[1:-1]).strip() or "-"
        rows.append((name, endpoint if endpoint != "?" else "-", state))
    return rows


def op_check_exits():
    ok, out = run2(["bash", MGMT, "--check-exits"], timeout=60)
    out = out.strip()
    if not out:
        return "（没有可检查的出口）"
    items = parse_check_exits_output(out)
    if not items:
        if ok:
            return "（没有可检查的出口）"
        return "❌ <b>出口检查失败</b>\n%s" % html.escape(_reason(out))
    bad = any(state.upper() == "DOWN" for _, _, state in items)
    lines = ["🩺 <b>出口节点连通性</b>%s" % ("　⚠️ 有节点不可达！" if bad else "")]
    lines.extend(_format_check_exit_row(name, endpoint, state) for name, endpoint, state in items)
    return "\n".join(lines)


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
                if os.path.islink(os.path.join("/etc/wireguard", f)):
                    continue  # runtime iface aliases for Unicode names
                seen.add(f[len("pgw-") : -len(".conf")])
    except OSError:
        pass
    names.extend(sorted(seen))
    return names


def op_ios_send(chat_id):
    """Send the iOS profile QR as an image (with the URL as caption)."""
    domain = _read_file("/etc/mosdns/.domain") or _read_file("/opt/proxy-gateway/etc/.domain")
    if domain:
        url = "http://%s:8111/ios-dot.mobileconfig" % domain
    else:
        url = _read_file(os.path.join(WWW_DIR, "ios-profile-url.txt"))
    if not url:
        return "未找到 iOS 描述文件地址,先在服务器上 `--ios` 生成。"
    cap = ("📱 <b>iOS DoT 描述文件</b>\n扫码安装(仅蜂窝网启用):\n<code>%s</code>" % html.escape(url))
    fd, png = tempfile.mkstemp(prefix="pgw-ios-qr-", suffix=".png")
    os.close(fd)
    try:
        ok, _ = run2(["qrencode", "-o", png, "-s", "8", "-m", "2", url], timeout=15)
        if ok and send_photo(chat_id, png, cap):
            return None  # delivered as a photo
    finally:
        try:
            os.unlink(png)
        except OSError:
            pass
    # fallback: just the URL (text)
    return cap


def op_ios_send_inline(cb):
    """Edit the callback message in-place to show the iOS QR code.
    Returns an error string on failure, or None on success."""
    domain = _read_file("/etc/mosdns/.domain") or _read_file("/opt/proxy-gateway/etc/.domain")
    if domain:
        url = "http://%s:8111/ios-dot.mobileconfig" % domain
    else:
        url = _read_file(os.path.join(WWW_DIR, "ios-profile-url.txt"))
    if not url:
        return "未找到 iOS 描述文件地址,先在服务器上 `--ios` 生成。"
    cap = ("📱 <b>iOS DoT 描述文件</b>\n扫码安装(仅蜂窝网启用):\n<code>%s</code>" % html.escape(url))
    fd, png = tempfile.mkstemp(prefix="pgw-ios-qr-", suffix=".png")
    os.close(fd)
    try:
        ok, _ = run2(["qrencode", "-o", png, "-s", "8", "-m", "2", url], timeout=15)
        if ok and edit_message_media(cb, png, cap, back_kb("menu:main")):
            return None  # success: edited in-place
    finally:
        try:
            os.unlink(png)
        except OSError:
            pass
    # fallback: just the URL as text
    return cap


# --------------------------------------------------------------------------- #
# Keyboards
# --------------------------------------------------------------------------- #
def main_menu():
    return [
        [{"text": "📊 状态", "callback_data": "act:status"},
         {"text": "🌐 出口管理", "callback_data": "menu:exits"}],
        [{"text": "📑 分流管理", "callback_data": "menu:rules"},
         {"text": "🔐 DoT 管理", "callback_data": "menu:dot"}],
        [{"text": "♻️ 重启服务", "callback_data": "act:restart"},
         {"text": "📜 日志", "callback_data": "menu:logs"}],
        [{"text": "📱 iOS 二维码", "callback_data": "act:ios"}],
    ]


def rules_menu():
    return [
        [{"text": "📋 规则列表", "callback_data": "rules:show"},
         {"text": "📚 规则集", "callback_data": "rules:showrs"},
         {"text": "✏️ 规则设置", "callback_data": "rules:set"}],
        [{"text": "➕ 添加规则", "callback_data": "rules:add"},
         {"text": "🗑 删除规则", "callback_data": "menu:rules_del"}],
        [{"text": "➕ 添加规则集", "callback_data": "rules:addset"},
         {"text": "🗑 删规则集", "callback_data": "menu:rulesets_del"}],
        [{"text": "🎯 分类→出口映射", "callback_data": "menu:policy"}],
        [{"text": "🔄 更新规则", "callback_data": "act:update_rules"},
         {"text": "⚡ 启用分流", "callback_data": "rules:enable"}],
        [{"text": "« 返回", "callback_data": "menu:main"}],
    ]


def _short_button_text(text, limit=48):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def rules_del_menu():
    rows = []
    _, entries = _plain_rule_entries()
    for index, (_, line) in enumerate(entries):
        label = _short_button_text(line.strip())
        data = "ruledel:%d:%s" % (index, _entry_token(line))
        rows.append([{"text": "🗑 " + label, "callback_data": data}])
    if not rows:
        rows.append([{"text": "（没有可删除的规则）", "callback_data": "menu:rules"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:rules"}])
    return rows


def rulesets_del_menu():
    rows = []
    _, entries = _ruleset_entries()
    for index, (_, line) in enumerate(entries):
        parts = line.strip().split(",", 2)
        if len(parts) == 3:
            source = parts[1].strip()
            target = parts[2].strip()
            parsed = urlparse(source)
            name = os.path.basename(parsed.path.rstrip("/")) or parsed.netloc or source
            label = "%s → %s" % (name, target)
        else:
            label = line.strip()
        data = "rulesetdel:%d:%s" % (index, _entry_token(line))
        rows.append([{"text": "🗑 " + _short_button_text(label), "callback_data": data}])
    if not rows:
        rows.append([{"text": "（没有可删除的规则集）", "callback_data": "menu:rules"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:rules"}])
    return rows


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
            rows.append(row)
            row = []
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
                 {"text": "✏️ 重命名", "callback_data": "menu:exits_rename"}])
    rows.append([{"text": "🗑 删除出口", "callback_data": "menu:exits_del"}])
    rows.append([{"text": "🩺 检查出口连通性", "callback_data": "exits:check"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:main"}])
    return rows


def exits_del_menu():
    rows = []
    for name in parse_exit_names():
        if name in ("local", "smart"):
            continue
        rows.append([{"text": "🗑 " + name, "callback_data": "exitdel:" + name}])
    if not rows:
        rows.append([{"text": "(没有可删除的出口)", "callback_data": "menu:exits"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:exits"}])
    return rows


def exits_rename_menu():
    rows = []
    for name in parse_exit_names():
        if name in ("local", "smart"):
            continue
        rows.append([{"text": "✏️ " + name, "callback_data": "exitren:" + name}])
    if not rows:
        rows.append([{"text": "(没有可重命名的出口)", "callback_data": "menu:exits"}])
    rows.append([{"text": "« 返回", "callback_data": "menu:exits"}])
    return rows


def dot_menu():
    return [
        [{"text": "🌐 更改域名", "callback_data": "dot:domain"}],
        [{"text": "🌍 更改国际 DNS", "callback_data": "dot:dns_remote"}],
        [{"text": "🇨🇳 更改国内 DNS", "callback_data": "dot:dns_local"}],
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


def process_add_exit_message(chat_id, message_id, payload, prompt_mid=None):
    items = []
    try:
        deleted = delete_message(chat_id, message_id)
        delete_warning = ("\n\n⚠️ 未能自动删除含凭据的消息，请手动删除上一条节点消息。"
                          if not deleted else "")
        items, err = parse_add_exit_inputs(payload)
        payload = ""
        if err:
            upsert_console(chat_id, err + delete_warning, add_exit_retry_kb(),
                           message_id=prompt_mid)
            return
        prompt_mid = upsert_console(
            chat_id, "⏳ 正在后台添加 %d 个出口…%s" % (len(items), delete_warning),
            message_id=prompt_mid)
        result = op_add_exit_batch(items)
        upsert_console(chat_id, result, exits_menu(), message_id=prompt_mid)
    except Exception:
        print("[err] add-exit background task failed chat_id=%s message_id=%s"
              % (chat_id, message_id), file=sys.stderr)
        try:
            upsert_console(chat_id, "❌ 添加出口时发生内部错误，请重新进入添加流程。",
                           add_exit_retry_kb(), message_id=prompt_mid)
        except Exception:
            print("[err] add-exit failure notification failed chat_id=%s message_id=%s"
                  % (chat_id, message_id), file=sys.stderr)
    finally:
        payload = ""
        for item in items:
            item["payload"] = ""
            item.pop("masked", None)
        items.clear()


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
        reanchor_console(chat_id, "已取消。选择一个操作：", main_menu())
        return

    # A slash command always aborts any in-progress flow.
    if text.startswith("/"):
        PENDING.pop(chat_id, None)
        if text.startswith(("/start", "/menu")):
            reanchor_console(chat_id, "<b>proxy-gateway 控制台</b>\n选择一个操作：", main_menu())
        elif text.startswith("/status"):
            mid = reanchor_console(chat_id, "⏳ 正在获取运行状态…")
            console_async(chat_id, op_status, keyboard_fn=status_kb, message_id=mid)
        elif text.startswith("/exits"):
            mid = reanchor_console(chat_id, "⏳ 正在获取当前出口信息…")
            console_async(chat_id, exits_overview_text, keyboard_fn=exits_menu, message_id=mid)
        elif text.startswith("/rules"):
            reanchor_console(chat_id, "📑 <b>分流管理</b>：按域名分流到不同出口 / 直连 / 拒绝。", rules_menu())
        else:
            send(chat_id, "未知命令。发送 /menu 打开操作面板。")
        return

    # Conversational flows (e.g. adding an exit).
    state = PENDING.get(chat_id)
    if state and state.get("action") == "add_exit_link":
        payload = msg.get("text") or ""
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        background(process_add_exit_message, chat_id, msg.get("message_id"), payload, prompt_mid)
        msg["text"] = ""
        payload = ""
        text = ""
        return
    if state and state.get("action") == "rename_exit":
        old_name = state.get("old") or ""
        new_name = text
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在重命名出口 <b>%s</b>…" % html.escape(old_name),
                             message_id=prompt_mid)
        console_async(chat_id, lambda: op_rename_exit(old_name, new_name),
                      keyboard_fn=exits_menu, message_id=mid)
        return
    if state and state.get("action") == "rules_set":
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        rules_text = msg.get("text") or ""
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在校验并应用规则…", message_id=prompt_mid)
        console_async(chat_id, lambda: op_set_rules(rules_text), rules_menu(), message_id=mid)
        return
    if state and state.get("action") == "rules_add_value":
        rule_type = state.get("rule_type") or ""
        prompt_mid = state.get("prompt_mid")
        background(delete_message, chat_id, msg.get("message_id"))
        err = validate_rule_value(rule_type, text)
        if err:
            state["prompt_mid"] = upsert_console(chat_id, err, cancel_kb("rules"),
                                                 message_id=prompt_mid)
            return
        mid = upsert_console(
            chat_id,
            "请选择目标：<code>%s,%s,?</code>" % (html.escape(rule_type), html.escape(text.strip())),
            _rule_target_buttons("raddo"), message_id=prompt_mid)
        PENDING[chat_id] = {"action": "rules_add_target", "rule_type": rule_type,
                            "rule_value": text.strip(), "prompt_mid": mid}
        return
    if state and state.get("action") == "rules_add":
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        rule_line = text
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在添加规则…", message_id=prompt_mid)
        console_async(chat_id, lambda: op_add_rule(rule_line), rules_menu(), message_id=mid)
        return
    if state and state.get("action") == "rules_addset":
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        ruleset_text = text
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在校验并添加规则集…", message_id=prompt_mid)
        console_async(chat_id, lambda: op_add_ruleset(ruleset_text), rules_menu(), message_id=mid)
        return
    if state and state.get("action") == "dot_domain":
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        domain_text = text
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在校验域名 A 记录并签发证书，可能需要 1-2 分钟…",
                             message_id=prompt_mid)
        def do_set_dot_domain():
            result, failed_domain = op_set_dot_domain(domain_text)
            if failed_domain:
                LAST_FAILED_DOT_DOMAIN[chat_id] = failed_domain
                upsert_console(chat_id, result, force_dot_domain_kb(), message_id=mid)
            else:
                LAST_FAILED_DOT_DOMAIN.pop(chat_id, None)
                upsert_console(chat_id, result, dot_menu(), message_id=mid)

        background(do_set_dot_domain)
        return
    if state and state.get("action") in ("dot_dns_remote", "dot_dns_local"):
        prompt_mid = state.get("prompt_mid")
        PENDING.pop(chat_id, None)
        dns_text = text
        kind = "remote" if state.get("action") == "dot_dns_remote" else "local"
        background(delete_message, chat_id, msg.get("message_id"))
        mid = upsert_console(chat_id, "⏳ 正在更新 DNS 上游并重载 mosdns/sniproxy…",
                             message_id=prompt_mid)
        console_async(chat_id, lambda: op_set_dns(kind, dns_text), dot_menu(), message_id=mid)
        return

    send(chat_id, "未知命令。发送 /menu 打开操作面板。")


def handle_callback(cb):
    uid = cb.get("from", {}).get("id")
    chat_id = cb["message"]["chat"]["id"]
    data = cb.get("data", "")
    cb_id = cb["id"]
    cb_mid = cb.get("message", {}).get("message_id")

    if not authorized(uid):
        tg("answerCallbackQuery", callback_query_id=cb_id, text="⛔ 未授权", show_alert=True)
        return

    if _busy_key_from_cb(cb) in BUSY:
        tg("answerCallbackQuery", callback_query_id=cb_id, text="正在处理上一项操作，请稍候…", show_alert=False)
        return

    # Stop the button spinner without adding another Telegram round-trip before the edit.
    answer_callback_async(cb_id)

    # ---- navigation (edit the same bubble) ----
    if data == "cancel:rules":
        PENDING.pop(chat_id, None)
        edit(cb, "📑 <b>分流管理</b>\n选择一个操作：", rules_menu())
    elif data == "cancel:exits":
        PENDING.pop(chat_id, None)
        edit(cb, "🌐 <b>出口管理</b>\n选择一个操作：", exits_menu())
    elif data == "cancel:dot":
        PENDING.pop(chat_id, None)
        edit(cb, op_dot_status(), dot_menu())
    elif data == "menu:main":
        PENDING.pop(chat_id, None)
        edit(cb, "选择一个操作：", main_menu())
    elif data == "menu:rules":
        edit(cb, "📑 <b>分流管理</b>：按域名把代理流量分到不同出口 / 直连 / 拒绝。", rules_menu())
    elif data == "menu:rules_del":
        edit(cb, "选择要删除的规则：", rules_del_menu())
    elif data == "menu:rulesets_del":
        edit(cb, "选择要删除的规则集：", rulesets_del_menu())
    elif data == "menu:policy":
        edit(cb, "🎯 <b>分类 → 出口</b> 映射（点一个分类来修改目标）：", policy_menu())
    elif data == "menu:exits":
        edit(cb, "⏳ 正在获取当前出口信息…")
        edit_async(cb, exits_overview_text, keyboard=exits_menu())
    elif data == "menu:exits_rename":
        edit(cb, "选择要重命名的出口：", exits_rename_menu())
    elif data == "menu:exits_del":
        edit(cb, "选择要删除的出口：", exits_del_menu())
    elif data == "menu:dot":
        edit(cb, op_dot_status(), dot_menu())
    elif data == "menu:logs":
        edit(cb, "选择要查看日志的服务：", services_menu("logs"))

    # ---- conversational starts (edit prompt into the same bubble) ----
    elif data == "rules:set":
        PENDING[chat_id] = {"action": "rules_set", "prompt_mid": cb_mid}
        edit(cb,
             "✏️ <b>规则设置</b>\n\n"
             "粘贴完整的分流规则（将替换当前所有规则，首行优先匹配）。\n\n"
             "格式：<code>类型,匹配值,出口</code>\n"
             "出口：出口名 / <code>direct</code>（直连）/ <code>block</code>（拦截）\n\n"
             "示例：\n"
             "<pre>DOMAIN-SUFFIX,google.com,us\n"
             "GEOSITE,netflix,us\n"
             "GEOIP,cn,direct\n"
             "FINAL,us</pre>",
             cancel_kb("rules"))
    elif data == "rules:add":
        edit(cb,
             "➕ <b>添加规则</b>\n\n"
             "选择一种快捷类型，或继续使用手工完整规则入口。",
             rule_type_menu())
    elif data == "rules:add_manual":
        PENDING[chat_id] = {"action": "rules_add", "prompt_mid": cb_mid}
        edit(cb,
             "➕ <b>添加规则</b>\n\n"
             "发送一条规则，将追加到现有规则末尾。\n\n"
             "格式：<code>类型,匹配值,出口</code>\n"
             "示例：<code>DOMAIN-SUFFIX,youtube.com,us</code>\n\n"
             "常用类型：DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / GEOSITE / GEOIP / IP-CIDR",
             cancel_kb("rules"))
    elif data.startswith("raddt:"):
        rule_type = data.split(":", 1)[1]
        if rule_type not in RULE_TYPES:
            edit(cb, "规则类型无效，请重新选择。", rule_type_menu())
        else:
            PENDING[chat_id] = {"action": "rules_add_value", "rule_type": rule_type,
                                "prompt_mid": cb_mid}
            edit(cb, rule_value_prompt(rule_type), cancel_kb("rules"))
    elif data.startswith("raddo:"):
        state = PENDING.get(chat_id) or {}
        parts = data.split(":", 1)
        target = parts[1] if len(parts) == 2 else ""
        rule_type = state.get("rule_type") or ""
        value = state.get("rule_value") or ""
        valid_targets = set(_targets()) | {"direct", "block"}
        if state.get("action") != "rules_add_target" or not rule_type or not value:
            edit(cb, "规则输入已过期，请重新开始。", rule_type_menu())
        elif target not in valid_targets:
            edit(cb, "目标已变化，请重新选择。", _rule_target_buttons("raddo"))
        else:
            PENDING.pop(chat_id, None)
            line = "%s,%s,%s" % (rule_type, value, target)
            edit(cb, "⏳ 正在添加规则 <code>%s</code>…" % html.escape(line))
            edit_async(cb, lambda: op_add_rule(line), back_kb("menu:rules"))
    elif data == "rules:addset":
        PENDING[chat_id] = {"action": "rules_addset", "prompt_mid": cb_mid}
        edit(cb,
             "➕ <b>添加规则集</b>\n\n"
             "发送规则集 URL 和目标出口，用空格分隔。\n\n"
             "格式：<code>URL 出口</code>\n"
             "示例：<code>https://example.com/openai.mrs us</code>\n\n"
             "支持格式：mihomo <code>.mrs</code>、Clash YAML、纯文本规则集\n"
             "目标：出口名 / 分类 / <code>direct</code> / <code>block</code>\n\n"
             "添加后点「🔄 更新规则」可立即拉取生效。",
             cancel_kb("rules"))
    elif data == "exit_add":
        PENDING[chat_id] = {"action": "add_exit_link", "prompt_mid": cb_mid}
        edit(cb,
             "➕ <b>添加出口</b>\n\n"
             "直接发送一条或多条节点链接，每行一条；我会优先使用链接里的节点名称作为出口名。\n\n"
             "支持：<code>%s</code>\n\n"
             "链接没有名称时，也可以发 <code>出口名 链接</code> 指定名称；同名会自动去重。\n\n"
             "🔐 为避免凭据留在聊天记录中，进入此步骤后，你发送的下一条消息会在读取后尝试自动删除；"
             "即使解析失败也会删除。删除失败时会提醒你手动处理。" % SUPPORTED_EXIT_LINKS,
             cancel_kb("exits"))
    elif data.startswith("exitren:"):
        name = data[len("exitren:"):]
        if name in ("local", "smart") or not EXIT_ADD_NAME_RE.match(name):
            edit(cb, "出口已变化，请重新打开。", exits_rename_menu())
        else:
            PENDING[chat_id] = {"action": "rename_exit", "old": name, "prompt_mid": cb_mid}
            edit(cb,
                 "✏️ <b>重命名出口</b>\n\n"
                 "当前出口：<b>%s</b>\n"
                 "请发送新的名称。" % html.escape(name),
                 cancel_kb("exits"))
    elif data == "dot:domain":
        PENDING[chat_id] = {"action": "dot_domain", "prompt_mid": cb_mid}
        edit(cb,
             "🌐 <b>更改 DoT 域名</b>\n\n"
             "发送新的完整域名。\n"
             "示例：<code>dns.example.com</code>\n\n"
             "域名 A 记录必须已经指向本机公网 IP，否则不会修改当前配置。",
             cancel_kb("dot"))
    elif data == "dot:dns_remote":
        PENDING[chat_id] = {"action": "dot_dns_remote", "prompt_mid": cb_mid}
        edit(cb,
             "🌍 <b>更改国际 DNS</b>\n\n"
             "发送新的 DNS 地址，多个地址用空格或逗号分隔。\n\n"
             "示例：<pre>1.1.1.1 8.8.8.8</pre>",
             cancel_kb("dot"))
    elif data == "dot:dns_local":
        PENDING[chat_id] = {"action": "dot_dns_local", "prompt_mid": cb_mid}
        edit(cb,
             "🇨🇳 <b>更改国内 DNS</b>\n\n"
             "发送新的 DNS 地址，多个地址用空格或逗号分隔。\n\n"
             "示例：<pre>223.5.5.5 119.29.29.29</pre>",
             cancel_kb("dot"))
    elif data == "dot:force_domain":
        domain = LAST_FAILED_DOT_DOMAIN.get(chat_id)
        if not domain:
            edit(cb, "没有可强制更换的域名，请重新点更改域名。", dot_menu())
        else:
            edit(cb, "⏳ 正在强制更换 DoT 域名为 <code>%s</code>…" % html.escape(domain))
            def do_force_domain():
                result = op_force_set_dot_domain(domain)
                if "已强制更换" in result:
                    LAST_FAILED_DOT_DOMAIN.pop(chat_id, None)
                return result

            edit_async(cb, do_force_domain, dot_menu())

    # ---- views ----
    elif data == "rules:show":
        edit(cb, op_show_rules(), back_kb("menu:rules"))
    elif data == "rules:showrs":
        edit(cb, op_show_rulesets(), back_kb("menu:rules"))
    elif data == "act:status":
        edit(cb, "⏳ 正在获取运行状态…")
        edit_async(cb, op_status, status_kb())
    elif data == "act:status_refresh":
        edit(cb, "⏳ 正在刷新状态…")
        edit_async(cb, op_status, status_kb())
    elif data.startswith("logs:"):
        svc = data[len("logs:"):]
        edit(cb, "📜 正在取 <b>%s</b> 日志…" % html.escape(svc))
        edit_async(cb, lambda: op_logs(svc), back_kb("menu:logs"), mono=True)
    elif data == "exits:check":
        edit(cb, "⏳ 正在检查出口连通性…")
        edit_async(cb, op_check_exits, back_kb("menu:exits"))
    elif data.startswith("ruledel:"):
        try:
            _, raw_index, token = data.split(":", 2)
            index = int(raw_index)
        except (ValueError, IndexError):
            edit(cb, "删除按钮无效，请重新打开规则列表。", back_kb("menu:rules_del"))
        else:
            edit(cb, "⏳ 正在删除规则并校验配置…")
            edit_async(cb, lambda: op_del_rule_button(index, token), back_kb("menu:rules_del"))
    elif data.startswith("rulesetdel:"):
        try:
            _, raw_index, token = data.split(":", 2)
            index = int(raw_index)
        except (ValueError, IndexError):
            edit(cb, "删除按钮无效，请重新打开规则集列表。", back_kb("menu:rulesets_del"))
        else:
            edit(cb, "⏳ 正在删除规则集并校验配置…")
            edit_async(cb, lambda: op_del_ruleset_button(index, token), back_kb("menu:rulesets_del"))

    # ---- actions (⏳ then result, all in one bubble) ----
    elif data == "act:update_rules":
        edit(cb, "⏳ 正在更新规则，请稍候…")
        edit_async(cb, op_update_rules, back_kb("menu:rules"))
    elif data == "act:renew":
        edit(cb, "⏳ 正在续期证书，请稍候…")
        edit_async(cb, op_renew_cert, back_kb("menu:main"))
    elif data == "act:restart":
        edit(cb, "⏳ 正在重启服务…")
        edit_async(cb, op_restart_services, back_kb("menu:main"))
    elif data == "rules:enable":
        edit(cb, "⏳ 正在启用智能分流…")
        edit_async(cb, lambda: op_set_exit("smart"), back_kb("menu:rules"))
    elif data.startswith("exit:"):
        name = data[len("exit:"):]
        edit(cb, "⏳ 正在切换出口到 <b>%s</b>…" % html.escape(name))
        edit_async(cb, lambda: op_set_exit(name), back_kb("menu:exits"))
    elif data.startswith("exitdel:"):
        name = data[len("exitdel:"):]
        edit(cb, "⏳ 正在删除出口 <b>%s</b>…" % html.escape(name))
        edit_async(cb, lambda: op_del_exit(name), back_kb("menu:exits"))
    elif data == "act:ios":
        edit(cb, "⏳ 正在生成 iOS 二维码…")
        edit_ios_async(cb, chat_id)
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
            edit_async(cb, lambda: op_set_policy(cat, target), back_kb("menu:policy"))
        else:
            edit(cb, "分类已变化，请重新打开。", policy_menu())
    else:
        edit(cb, "未知操作。", back_kb("menu:main"))


# Quick command menu (the Telegram "Menu" button / typing "/"), Chinese labels.
BOT_COMMANDS = [
    ("menu", "打开操作面板"),
    ("status", "查看运行状态"),
    ("exits", "出口管理（切换/添加/删除）"),
    ("rules", "分流管理"),
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
    validate_mgmt_path()
    if not ADMIN_IDS:
        print("[warn] TG_ADMIN_IDS is empty; no one can operate. Use /id to find yours.",
              file=sys.stderr)

    set_commands()
    print("proxy-gateway tgbot started; admins=%s" % sorted(ADMIN_IDS), file=sys.stderr)
    offset = None
    while True:
        # Stay below common 30s idle TCP timeouts so the next update does not
        # wait for a stale long-poll socket to fail first.
        params = {"timeout": 25}
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
