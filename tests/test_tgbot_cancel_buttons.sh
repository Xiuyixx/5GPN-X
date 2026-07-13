#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="${root}" python3 - <<'PY'
import importlib.util
import os

spec = importlib.util.spec_from_file_location(
    "tgbot_cancel_test", os.path.join(os.environ["ROOT"], "lib", "tgbot.py")
)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

bot.authorized = lambda uid: True
bot.answer_callback_async = lambda cb_id: None
edits = []
bot.edit = lambda cb, text, keyboard=None, mono=False: edits.append((text, keyboard))

cb = {
    "id": "callback-id",
    "from": {"id": 1},
    "message": {"chat": {"id": 10}, "message_id": 20},
}

forms = {
    "rules:set": "rules",
    "rules:add_manual": "rules",
    "rules:addset": "rules",
    "exit_add": "exits",
    "dot:domain": "dot",
    "dot:dns_remote": "dot",
    "dot:dns_local": "dot",
}

for data, section in forms.items():
    edits.clear()
    cb["data"] = data
    bot.handle_callback(cb)
    text, keyboard = edits[-1]
    assert "/cancel" not in text
    assert keyboard == [[{"text": "✖ 取消", "callback_data": "cancel:" + section}]]
    assert 10 in bot.PENDING

for section in ("rules", "exits", "dot"):
    edits.clear()
    bot.PENDING[10] = {"action": "test"}
    cb["data"] = "cancel:" + section
    bot.handle_callback(cb)
    assert 10 not in bot.PENDING
    assert edits, "cancel must render the section menu"

print("tgbot cancel buttons OK")
PY
