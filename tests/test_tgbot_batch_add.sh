#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="${root}" python3 - <<'PY'
import importlib.util
import os

spec = importlib.util.spec_from_file_location(
    "tgbot_batch_test", os.path.join(os.environ["ROOT"], "lib", "tgbot.py")
)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

bot.parse_exit_names = lambda: ["local", "hk"]
items, err = bot.parse_add_exit_inputs(
    "hk ss://YWVzLTI1Ni1nY206cGFzc0AxLjIuMy40OjgzODg=#TagA\n"
    "ss://YWVzLTI1Ni1nY206cGFzc0A1LjYuNy44OjgzODg=#TagA\n"
    "ss://YWVzLTI1Ni1nY206cGFzc0A5LjkuOS45OjgzODg=#TagB\n"
)
assert not err, err
assert [item["name"] for item in items] == ["hk", "TagA", "TagB"]

calls = []
bot.op_add_exit = lambda name, payload: calls.append((name, payload)) or ("✅ ok" if name != "TagB" else "❌ fail\nreason")
text = bot.op_add_exit_batch(items)
assert "✅ 1. <b>hk-2</b>（由 hk 自动去重）" in text
assert "✅ 2. <b>TagA</b>" in text
assert "❌ 3. <b>TagB</b>：" in text
assert calls[0][0] == "hk-2"
assert calls[1][0] == "TagA"
assert calls[2][0] == "TagB"
assert "1.2.3.4" not in text and "5.6.7.8" not in text and "9.9.9.9" not in text

print("tgbot batch add OK")
PY
