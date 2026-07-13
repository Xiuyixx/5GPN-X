import importlib.util
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_console", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

CHAT_ID = 99

REAL = {name: getattr(bot, name) for name in (
    "delete_message", "parse_add_exit_inputs", "op_add_exit_batch",
    "exits_menu", "process_add_exit_message", "background",
)}


class FakeApi:
    """Record Telegram API calls; sendMessage allocates increasing message ids."""

    def __init__(self, edit_ok=True):
        self.calls = []
        self.edit_ok = edit_ok
        self.next_mid = 100

    def __call__(self, method, **params):
        self.calls.append((method, params))
        if method == "sendMessage":
            self.next_mid += 1
            return {"ok": True, "result": {"message_id": self.next_mid}}
        if method == "editMessageText":
            if self.edit_ok:
                return {"ok": True, "result": {}}
            return {"ok": False, "error_code": 400,
                    "description": "Bad Request: message to edit not found"}
        return {"ok": True, "result": {}}

    def named(self, method):
        return [p for m, p in self.calls if m == method]


def tg_message(text, message_id=500):
    return {
        "chat": {"id": CHAT_ID, "type": "private"},
        "from": {"id": 1},
        "message_id": message_id,
        "text": text,
    }


def tg_callback(data, message_id=300):
    return {
        "id": "cb1",
        "from": {"id": 1},
        "data": data,
        "message": {"chat": {"id": CHAT_ID}, "message_id": message_id},
    }


class ConsoleMessageTest(unittest.TestCase):
    def setUp(self):
        bot.PENDING.clear()
        bot.CONSOLE.clear()
        bot.BUSY.clear()
        for name, fn in REAL.items():
            setattr(bot, name, fn)
        bot.authorized = lambda uid: True
        bot.answer_callback_async = lambda cb_id: None
        self.api = FakeApi()
        bot.tg = self.api

    def test_menu_first_sends_then_edits_same_console_message(self):
        bot.handle_message(tg_message("/menu"))
        self.assertEqual(len(self.api.named("sendMessage")), 1)
        self.assertEqual(bot.CONSOLE[CHAT_ID], 101)

        bot.handle_message(tg_message("/menu"))
        edits = self.api.named("editMessageText")
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0]["message_id"], 101)
        self.assertEqual(len(self.api.named("sendMessage")), 1,
                         "second /menu must edit the console, not send again")
        self.assertEqual(bot.CONSOLE[CHAT_ID], 101)

    def test_callback_menu_still_edits_and_tracks_console(self):
        bot.handle_callback(tg_callback("menu:main", message_id=300))
        edits = self.api.named("editMessageText")
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0]["message_id"], 300)
        self.assertEqual(self.api.named("sendMessage"), [])
        self.assertEqual(bot.CONSOLE[CHAT_ID], 300)

    def test_pending_input_edits_prompt_message_without_new_messages(self):
        deletions = []
        bot.delete_message = lambda chat_id, message_id: deletions.append(message_id) or True
        bot.parse_add_exit_inputs = lambda payload: (
            [{"index": 1, "name": "node", "payload": payload, "masked": "node"}], "")
        bot.op_add_exit_batch = lambda items: "批量添加完成：成功 1 / 共 1"
        bot.exits_menu = lambda: [[{"text": "back", "callback_data": "menu:exits"}]]

        bot.process_add_exit_message(CHAT_ID, 501, "socks5://u:p@1.2.3.4:1080#node",
                                     prompt_mid=300)

        self.assertEqual(deletions, [501], "node-link input must be deleted")
        edits = self.api.named("editMessageText")
        self.assertEqual([e["message_id"] for e in edits], [300, 300],
                         "processing + result must edit the same prompt message")
        self.assertIn("⏳", edits[0]["text"])
        self.assertIn("批量添加完成", edits[1]["text"])
        self.assertEqual(self.api.named("sendMessage"), [],
                         "flow must not send extra progress/result messages")

    def test_handle_message_passes_prompt_mid_to_add_exit_flow(self):
        captured = {}

        def fake_process(chat_id, message_id, payload, prompt_mid=None):
            captured.update(chat_id=chat_id, message_id=message_id,
                            payload=payload, prompt_mid=prompt_mid)

        bot.process_add_exit_message = fake_process
        bot.background = lambda fn, *args: fn(*args)
        bot.PENDING[CHAT_ID] = {"action": "add_exit_link", "prompt_mid": 300}
        bot.handle_message(tg_message("ss://payload", message_id=502))
        self.assertEqual(captured["prompt_mid"], 300)
        self.assertEqual(captured["message_id"], 502)
        self.assertNotIn(CHAT_ID, bot.PENDING)

    def test_edit_failure_falls_back_to_send_and_updates_console(self):
        self.api.edit_ok = False
        bot.CONSOLE[CHAT_ID] = 42
        mid = bot.upsert_console(CHAT_ID, "hello", keyboard=None)
        self.assertEqual(len(self.api.named("editMessageText")), 1)
        self.assertEqual(len(self.api.named("sendMessage")), 1)
        self.assertEqual(mid, 101)
        self.assertEqual(bot.CONSOLE[CHAT_ID], 101)

    def test_not_modified_is_quiet_success(self):
        bot.tg = lambda method, **params: {
            "ok": False, "error_code": 400,
            "description": "Bad Request: message is not modified"}
        self.assertTrue(bot.edit_message(CHAT_ID, 7, "same text"))
        mid = bot.upsert_console(CHAT_ID, "same text", message_id=7)
        self.assertEqual(mid, 7)
        self.assertEqual(bot.CONSOLE[CHAT_ID], 7)


if __name__ == "__main__":
    unittest.main()
