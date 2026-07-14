"""End-to-end simulation of every 分流管理 (rules management) interaction.

Drives the real handle_callback / handle_message code paths with a fake
Telegram API and a fake MGMT backend, asserting every button and input flow
responds in the console message without raising.
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_rules_flows", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

CHAT_ID = 77
RULES = "DOMAIN-SUFFIX,google.com,us\nRULE-SET,https://example.com/ai.mrs,us\nFINAL,us\n"
POLICY = "openai=us\nnetflix=direct\n"


class FakeApi:
    def __init__(self):
        self.calls = []
        self.next_mid = 200

    def __call__(self, method, **params):
        self.calls.append((method, params))
        if method == "sendMessage":
            self.next_mid += 1
            return {"ok": True, "result": {"message_id": self.next_mid}}
        return {"ok": True, "result": {}}

    def last_text(self):
        for method, params in reversed(self.calls):
            if method in ("editMessageText", "sendMessage"):
                return params.get("text", "")
        return ""


class RulesFlowsTest(unittest.TestCase):
    def setUp(self):
        bot.PENDING.clear()
        bot.CONSOLE.clear()
        bot.BUSY.clear()
        bot.authorized = lambda uid: True
        bot.answer_callback_async = lambda cb_id: None
        bot.background = lambda fn, *args: fn(*args)  # run async paths inline
        bot.delete_message = lambda chat_id, message_id: True
        self.api = FakeApi()
        bot.tg = self.api
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        rules = Path(self.tmp.name) / "rules.conf"
        policy = Path(self.tmp.name) / "policy-map.conf"
        rules.write_text(RULES, encoding="utf-8")
        policy.write_text(POLICY, encoding="utf-8")
        bot.RULES_PATH = str(rules)
        bot.POLICY_PATH = str(policy)
        self.mgmt_calls = []

        def fake_run2(argv, timeout=120, inp=None):
            self.mgmt_calls.append(list(argv))
            if "--update-rules" in argv:
                return True, "GFWList: 111\nChinaList: 222\n"
            return True, "OK"

        bot.run2 = fake_run2
        bot._is_active = lambda unit: "inactive"
        bot.parse_exit_names = lambda: ["local", "us", "hk"]

    def cb(self, data, message_id=300):
        callback = {"id": "cb", "from": {"id": 1}, "data": data,
                    "message": {"chat": {"id": CHAT_ID}, "message_id": message_id}}
        bot.handle_callback(callback)
        return self.api.last_text()

    def msg(self, text, message_id=400):
        bot.handle_message({"chat": {"id": CHAT_ID, "type": "private"},
                            "from": {"id": 1}, "message_id": message_id, "text": text})
        return self.api.last_text()

    def test_rules_menu_and_views(self):
        self.assertIn("分流管理", self.cb("menu:rules"))
        self.assertIn("DOMAIN-SUFFIX,google.com,us", self.cb("rules:show"))
        shown = self.cb("rules:showrs")
        self.assertIn("example.com/ai.mrs", shown)

    def test_set_rules_flow(self):
        self.assertIn("规则设置", self.cb("rules:set"))
        self.assertEqual(bot.PENDING[CHAT_ID]["action"], "rules_set")
        result = self.msg("DOMAIN-SUFFIX,x.com,us\nFINAL,us")
        self.assertTrue(self.mgmt_calls and "--set-rules" in self.mgmt_calls[-1])
        self.assertNotIn(CHAT_ID, bot.PENDING)
        self.assertTrue(result)

    def test_quick_add_rule_flow(self):
        self.cb("rules:add")
        self.assertIn("已选择类型", self.cb("raddt:DOMAIN-SUFFIX"))
        self.assertIn("请选择目标", self.msg("youtube.com"))
        self.assertEqual(bot.PENDING[CHAT_ID]["action"], "rules_add_target")
        self.cb("raddo:us")
        self.assertTrue(any("--set-rules" in c for c in self.mgmt_calls[-1]))
        self.assertNotIn(CHAT_ID, bot.PENDING)

    def test_quick_add_rejects_bad_value_then_recovers(self):
        self.cb("rules:add")
        self.cb("raddt:IP-CIDR")
        self.assertIn("无效", self.msg("999.999.0.0/24"))
        self.assertEqual(bot.PENDING[CHAT_ID]["action"], "rules_add_value")
        self.assertIn("请选择目标", self.msg("10.1.0.0/16"))

    def test_manual_add_rule_flow(self):
        self.cb("rules:add_manual")
        self.assertEqual(bot.PENDING[CHAT_ID]["action"], "rules_add")
        self.msg("DOMAIN,openai.com,us")
        self.assertTrue(any("--set-rules" in c for c in self.mgmt_calls[-1]))

    def test_delete_rule_buttons(self):
        menu = bot.rules_del_menu()
        buttons = [b for row in menu for b in row if b["callback_data"].startswith("ruledel:")]
        self.assertEqual(len(buttons), 2)  # RULE-SET line managed separately
        self.cb(buttons[0]["callback_data"])
        self.assertTrue(any("--set-rules" in c or "--del-rule" in c for c in self.mgmt_calls[-1]))

    def test_add_and_delete_ruleset_flow(self):
        self.cb("rules:addset")
        self.assertEqual(bot.PENDING[CHAT_ID]["action"], "rules_addset")
        self.msg("https://example.com/openai.mrs us")
        self.assertTrue(self.mgmt_calls)
        menu = bot.rulesets_del_menu()
        buttons = [b for row in menu for b in row if b["callback_data"].startswith("rulesetdel:")]
        self.assertEqual(len(buttons), 1)
        self.cb(buttons[0]["callback_data"])

    def test_policy_mapping_flow(self):
        text = self.cb("menu:policy")
        self.assertIn("分类", text)
        self.assertIn("openai", self.cb("pol:0"))
        self.cb("ps:0:hk")
        self.assertTrue(any("--set-policy" in c for c in self.mgmt_calls[-1]))

    def test_update_rules_and_enable_smart(self):
        result = self.cb("act:update_rules")
        self.assertIn("GFWList：111", result)
        self.cb("rules:enable")
        self.assertIn(["bash", bot.MGMT, "--set-exit", "smart"], self.mgmt_calls)

    def test_cancel_returns_to_rules_menu(self):
        self.cb("rules:set")
        self.assertIn("分流管理", self.cb("cancel:rules"))
        self.assertNotIn(CHAT_ID, bot.PENDING)


if __name__ == "__main__":
    unittest.main()
