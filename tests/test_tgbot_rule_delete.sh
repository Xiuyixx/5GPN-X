#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="${root}" python3 - <<'PY'
import importlib.util
import os
import tempfile

spec = importlib.util.spec_from_file_location(
    "tgbot_rule_delete_test", os.path.join(os.environ["ROOT"], "tgbot.py")
)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

with tempfile.TemporaryDirectory() as tmp:
    bot.RULES_PATH = os.path.join(tmp, "rules.conf")
    first = "DOMAIN-SUFFIX,example.com,direct"
    ruleset = "RULE-SET,https://example.com/openai.mrs,proxy"
    second = "FINAL,proxy"
    open(bot.RULES_PATH, "w", encoding="utf-8").write(
        "\n".join((first, ruleset, second)) + "\n"
    )

    rule_menu = bot.rules_del_menu()
    rule_callbacks = [row[0]["callback_data"] for row in rule_menu[:-1]]
    assert len(rule_callbacks) == 2
    assert all(value.startswith("ruledel:") for value in rule_callbacks)

    ruleset_menu = bot.rulesets_del_menu()
    ruleset_callbacks = [row[0]["callback_data"] for row in ruleset_menu[:-1]]
    assert len(ruleset_callbacks) == 1
    assert ruleset_callbacks[0].startswith("rulesetdel:")
    assert "openai.mrs" in ruleset_menu[0][0]["text"]

    applied = []
    bot.op_set_rules = lambda text: applied.append(text) or "ok"
    _, raw_index, token = rule_callbacks[0].split(":", 2)
    assert bot.op_del_rule_button(int(raw_index), token) == "ok"
    assert first not in applied[-1]
    assert ruleset in applied[-1] and second in applied[-1]

    assert "已经变化" in bot.op_del_rule_button(int(raw_index), "bad-token")

    _, raw_index, token = ruleset_callbacks[0].split(":", 2)
    assert bot.op_del_ruleset_button(int(raw_index), token) == "ok"
    assert ruleset not in applied[-1]
    assert first in applied[-1] and second in applied[-1]

print("tgbot rule delete buttons OK")
PY
