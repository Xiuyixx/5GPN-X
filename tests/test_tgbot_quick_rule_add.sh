#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="${root}" python3 - <<'PY'
import importlib.util
import os

spec = importlib.util.spec_from_file_location(
    "tgbot_rules_quickadd_test", os.path.join(os.environ["ROOT"], "lib", "tgbot.py")
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

cb["data"] = "rules:add"
bot.handle_callback(cb)
text, keyboard = edits[-1]
assert "快捷类型" in text
assert any(row[0]["callback_data"] == "raddt:DOMAIN" for row in keyboard[:-2])
assert keyboard[-2][0]["callback_data"] == "rules:add_manual"

edits.clear()
cb["data"] = "raddt:GEOIP"
bot.handle_callback(cb)
assert bot.PENDING[10]["action"] == "rules_add_value"
assert bot.PENDING[10]["rule_type"] == "GEOIP"
assert "已选择类型：<code>GEOIP</code>" in edits[-1][0]

assert bot.validate_rule_value("IP-CIDR", "1.2.3.0/24") == ""
assert "无效" in bot.validate_rule_value("IP-CIDR", "1.2.3.999/24")
assert bot.validate_rule_value("GEOSITE", "telegram") == ""

print("tgbot quick rule add OK")
PY
