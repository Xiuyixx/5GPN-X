#!/usr/bin/env python3
"""WLOC bot behavior tests for lib/tgbot.py.

Verifies: /wloc and the menu:wloc button reach the same page; preset selection;
manual coordinate entry (valid + invalid); cancel; restore-real-location;
unauthorized users are blocked; and the CA control never leaks a private key.

Run: python3 tests/test_wloc_bot.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BOT = os.path.join(HERE, "..", "lib", "tgbot.py")

spec = importlib.util.spec_from_file_location("tgbot", BOT)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("FAIL:", msg)
    else:
        print("ok:", msg)


# --- deterministic stubs ---------------------------------------------------- #
edits = []          # (text, keyboard) from edit()
async_calls = []    # (text_fn, keyboard) from edit_async()
console = []         # (text, keyboard/kb_fn) from reanchor/console
mgmt_calls = []      # captured MGMT argv

bot.answer_callback_async = lambda cb_id: None
bot.background = lambda fn, *a, **k: None  # never spawn threads in tests
bot.edit = lambda cb, text, keyboard=None, mono=False: edits.append((text, keyboard))
bot.edit_async = lambda cb, text_fn, keyboard=None, mono=False: async_calls.append((text_fn, keyboard))
bot.delete_message = lambda *a, **k: True
bot.send = lambda *a, **k: 111


def _reanchor(chat_id, text, keyboard=None, mono=False):
    console.append((text, keyboard))
    return 222


def _console_async(chat_id, text_fn, keyboard=None, mono=False, keyboard_fn=None, message_id=None):
    console.append((text_fn, keyboard if keyboard is not None else keyboard_fn))


def _upsert(chat_id, text, keyboard=None, mono=False, message_id=None):
    console.append((text, keyboard))
    return message_id or 333


bot.reanchor_console = _reanchor
bot.console_async = _console_async
bot.upsert_console = _upsert


def fake_run2(argv, timeout=120, inp=None):
    mgmt_calls.append(argv)
    if "--wloc-status" in argv:
        return True, "enabled=False\nlatitude=\nlongitude=\nservice=inactive\nca_profile=present"
    if "--wloc-set" in argv:
        return True, "ok"
    if "--wloc-off" in argv:
        return True, "ok"
    if "--wloc-ca-url" in argv:
        return True, "http://dns.example.com:8111/wloc-ca.mobileconfig"
    return True, ""


bot.run2 = fake_run2
bot.authorized = lambda uid: uid == 1

# Point presets at a temp fixture so preset behavior is deterministic.
import json  # noqa: E402
import tempfile  # noqa: E402
_pfd, _ppath = tempfile.mkstemp(suffix=".json")
with os.fdopen(_pfd, "w", encoding="utf-8") as _pf:
    json.dump({"presets": [
        {"id": "t1", "name": "测试地点", "latitude": 22.303611, "longitude": 114.165, "accuracy": 25},
        {"id": "bad", "name": "x", "latitude": 999, "longitude": 0},
    ]}, _pf, ensure_ascii=False)
bot.WLOC_PRESETS_PATH = _ppath

CB = {"id": "c", "from": {"id": 1}, "message": {"chat": {"id": 1}, "message_id": 9}}


def cb(data, uid=1):
    edits.clear()
    async_calls.clear()
    console.clear()
    mgmt_calls.clear()
    c = dict(CB)
    c["from"] = {"id": uid}
    c["data"] = data
    bot.handle_callback(c)


def msg(text, uid=1):
    edits.clear()
    async_calls.clear()
    console.clear()
    mgmt_calls.clear()
    bot.handle_message({"chat": {"id": 1}, "from": {"id": uid}, "message_id": 5, "text": text})


# --- /wloc and menu:wloc reach the same page -------------------------------- #
cb("menu:wloc")
menu_kb = async_calls[-1][1] if async_calls else None
check(menu_kb == bot.wloc_menu(), "menu:wloc renders wloc_menu()")

msg("/wloc")
slash_kb = None
for _, kb in console:
    if kb == bot.wloc_menu():
        slash_kb = kb
check(slash_kb == bot.wloc_menu(), "/wloc renders the same wloc_menu()")

# --- preset selection triggers a set with that preset's coords -------------- #
presets = bot._wloc_presets()
check(len(presets) >= 1, "at least one preset is available")
check(all(p["id"] != "bad" for p in presets), "invalid preset (out-of-range) is ignored")
if presets:
    pid = presets[0]["id"]
    cb("wloc:preset:" + pid)
    # edit_async lambda calls op_wloc_set(lat,lon) -> run2 --wloc-set
    if async_calls:
        async_calls[-1][0]()  # invoke the deferred text_fn
    set_call = next((a for a in mgmt_calls if "--wloc-set" in a), None)
    check(set_call is not None, "preset selection calls --wloc-set")

# --- manual input: valid coordinate ----------------------------------------- #
cb("wloc:input")
check(bot.PENDING.get(1, {}).get("action") == "wloc_input", "wloc:input arms manual entry")
msg("22.303611,114.165")
set_call = next((a for a in mgmt_calls if "--wloc-set" in a), None)
# console_async defers op_wloc_set; invoke it
if set_call is None:
    for text_or_fn, _ in console:
        if callable(text_or_fn):
            text_or_fn()
    set_call = next((a for a in mgmt_calls if "--wloc-set" in a), None)
check(set_call is not None, "valid manual coordinate calls --wloc-set")
check(1 not in bot.PENDING, "valid manual coordinate clears PENDING")

# --- manual input: invalid coordinate keeps PENDING, no set ----------------- #
cb("wloc:input")
msg("999,0")
set_call = next((a for a in mgmt_calls if "--wloc-set" in a), None)
check(set_call is None, "invalid coordinate never calls --wloc-set")
check(bot.PENDING.get(1, {}).get("action") == "wloc_input", "invalid coordinate keeps PENDING armed")

# --- cancel clears the flow ------------------------------------------------- #
cb("cancel:wloc")
check(1 not in bot.PENDING, "cancel:wloc clears PENDING")

# --- restore real location -------------------------------------------------- #
cb("wloc:off")
if async_calls:
    async_calls[-1][0]()
off_call = next((a for a in mgmt_calls if "--wloc-off" in a), None)
check(off_call is not None, "wloc:off calls --wloc-off")

# --- unauthorized user is blocked ------------------------------------------- #
blocked = {"answered": False}
bot.tg = lambda method, **kw: blocked.__setitem__("answered", method == "answerCallbackQuery") or {"ok": True}
cb("menu:wloc", uid=999)
check(not any("--wloc" in a for a in mgmt_calls), "unauthorized user triggers no WLOC MGMT call")

# --- CA text never contains a private key ----------------------------------- #
ca_text = bot.op_wloc_ca_text()
check("PRIVATE KEY" not in ca_text, "CA control never shows a private key")
check("wloc-ca.mobileconfig" in ca_text, "CA control shows the profile URL")

if FAILS:
    print("\n%d test(s) failed" % len(FAILS))
    sys.exit(1)
print("\nall wloc-bot tests passed")
