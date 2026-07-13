import contextlib
import importlib.util
import io
from pathlib import Path
import threading
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_add_exit_async", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

REAL_DELETE_MESSAGE = bot.delete_message
REAL_PARSE_ADD_EXIT_INPUTS = bot.parse_add_exit_inputs
REAL_OP_ADD_EXIT_BATCH = bot.op_add_exit_batch
REAL_OP_ADD_EXIT = bot.op_add_exit

CHAT_ID = 10
SECRET = "SECRET_SENTINEL"
URI = "socks5://user:%s@198.51.100.23:1080#AsyncNode" % SECRET
WARNING = "未能自动删除含凭据的消息，请手动删除上一条节点消息"


def message(message_id, text=URI):
    return {
        "chat": {"id": CHAT_ID, "type": "private"},
        "from": {"id": 1},
        "message_id": message_id,
        "text": text,
    }


class AddExitAsyncTest(unittest.TestCase):
    def setUp(self):
        bot.PENDING.clear()
        bot.authorized = lambda uid: True
        bot.exits_menu = lambda: [[{"text": "back", "callback_data": "menu:exits"}]]
        bot.parse_exit_names = lambda: []
        bot.delete_message = REAL_DELETE_MESSAGE
        bot.parse_add_exit_inputs = REAL_PARSE_ADD_EXIT_INPUTS
        bot.op_add_exit_batch = REAL_OP_ADD_EXIT_BATCH
        bot.op_add_exit = REAL_OP_ADD_EXIT

    def test_polling_returns_and_fast_second_input_is_not_imported(self):
        delete_started = threading.Event()
        release_delete = threading.Event()
        task_done = threading.Event()
        handler_returned = threading.Event()
        order = []
        delete_calls = []
        parse_calls = []
        add_calls = []
        replies = []
        item_refs = []
        real_parse = REAL_PARSE_ADD_EXIT_INPUTS

        def slow_delete(chat_id, message_id):
            delete_calls.append((chat_id, message_id))
            order.append("delete-start")
            delete_started.set()
            self.assertTrue(release_delete.wait(2))
            order.append("delete-done")
            return True

        def parse_once(payload):
            parse_calls.append(1)
            order.append("parse")
            items, err = real_parse(payload)
            item_refs.extend(items)
            return items, err

        def add_once(name, payload):
            add_calls.append((name, payload))
            order.append("add")
            return "✅ ok"

        def capture_send(chat_id, text, keyboard=None, mono=False):
            replies.append((text, keyboard))
            if text.startswith("⏳"):
                order.append("progress")
            elif text.startswith("批量添加完成"):
                order.append("final")
                task_done.set()

        bot.delete_message = slow_delete
        bot.parse_add_exit_inputs = parse_once
        bot.op_add_exit = add_once
        bot.send = capture_send
        bot.PENDING[CHAT_ID] = {"action": "add_exit_link"}

        def invoke_handler():
            bot.handle_message(message(20))
            handler_returned.set()

        caller = threading.Thread(target=invoke_handler)
        caller.start()
        self.assertTrue(delete_started.wait(2))
        self.assertTrue(handler_returned.wait(1), "handle_message blocked on deleteMessage")
        self.assertNotIn(CHAT_ID, bot.PENDING)

        bot.handle_message(message(21))
        release_delete.set()
        self.assertTrue(task_done.wait(2))
        caller.join(1)

        self.assertEqual(delete_calls, [(CHAT_ID, 20)])
        self.assertEqual(len(parse_calls), 1)
        self.assertEqual(len(add_calls), 1)
        self.assertEqual(order, ["delete-start", "delete-done", "parse", "progress", "add", "final"])
        self.assertFalse(any(WARNING in text for text, _ in replies))
        rendered = "\n".join(text for text, _ in replies)
        for secret in (URI, SECRET, "198.51.100.23"):
            self.assertNotIn(secret, rendered)
        self.assertTrue(item_refs)
        self.assertTrue(all(item["payload"] == "" and "masked" not in item for item in item_refs))

    def test_delete_failure_still_adds_and_warns(self):
        done = threading.Event()
        replies = []
        add_calls = []
        bot.delete_message = lambda chat_id, message_id: False
        bot.op_add_exit = lambda name, payload: add_calls.append(name) or "✅ ok"

        def capture_send(chat_id, text, keyboard=None, mono=False):
            replies.append(text)
            if text.startswith("批量添加完成"):
                done.set()

        bot.send = capture_send
        bot.PENDING[CHAT_ID] = {"action": "add_exit_link"}
        bot.handle_message(message(30))
        self.assertTrue(done.wait(2))
        self.assertEqual(add_calls, ["AsyncNode"])
        self.assertTrue(any(WARNING in text for text in replies))
        rendered = "\n".join(replies)
        self.assertNotIn(URI, rendered)
        self.assertNotIn(SECRET, rendered)

    def test_parse_failure_delete_outcomes_and_retry_button(self):
        for deleted in (True, False):
            with self.subTest(deleted=deleted):
                calls = []
                replies = []
                bot.delete_message = lambda chat_id, message_id: calls.append("delete") or deleted
                bot.parse_add_exit_inputs = lambda payload: (calls.append("parse") or ([], "无法识别节点。"))
                bot.op_add_exit_batch = lambda items: self.fail("batch add must not run")
                bot.send = lambda chat_id, text, keyboard=None, mono=False: replies.append((text, keyboard))

                bot.process_add_exit_message(CHAT_ID, 40, "invalid-" + SECRET)

                self.assertEqual(calls, ["delete", "parse"])
                self.assertEqual(WARNING in replies[0][0], not deleted)
                self.assertEqual(replies[0][1], bot.add_exit_retry_kb())
                self.assertNotIn(SECRET, replies[0][0])

    def test_delete_message_handles_api_failures_without_raising(self):
        responses = [
            {"ok": False, "error_code": 400, "description": "message can't be deleted"},
            {"ok": False, "error": "timeout"},
            {},
        ]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            for response in responses:
                bot.tg = lambda method, response=response, **params: response
                self.assertFalse(bot.delete_message(CHAT_ID, 50))
            bot.tg = lambda method, **params: (_ for _ in ()).throw(ValueError(SECRET))
            self.assertFalse(bot.delete_message(CHAT_ID, 51))
            self.assertFalse(bot.delete_message(CHAT_ID, None))

        logs = stderr.getvalue()
        self.assertIn("chat_id=10 message_id=50 error_code=400", logs)
        self.assertIn("description=message can't be deleted", logs)
        self.assertIn("description=timeout", logs)
        self.assertIn("description=unknown error", logs)
        self.assertIn("description=exception:ValueError", logs)
        self.assertIn("message_id=None", logs)
        self.assertNotIn(SECRET, logs)

    def test_background_exception_is_generic_and_clears_credentials(self):
        replies = []
        item = {"index": 1, "name": "node", "payload": URI, "masked": "masked"}
        bot.delete_message = lambda chat_id, message_id: True
        bot.parse_add_exit_inputs = lambda payload: ([item], "")
        bot.op_add_exit_batch = lambda items: (_ for _ in ()).throw(RuntimeError(SECRET))
        bot.send = lambda chat_id, text, keyboard=None, mono=False: replies.append(text)
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            bot.process_add_exit_message(CHAT_ID, 60, URI)

        self.assertEqual(item["payload"], "")
        self.assertNotIn("masked", item)
        self.assertTrue(any("内部错误" in text for text in replies))
        self.assertNotIn(SECRET, stderr.getvalue())
        self.assertNotIn(SECRET, "\n".join(replies))


if __name__ == "__main__":
    unittest.main()
