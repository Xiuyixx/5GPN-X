import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class ReliabilityTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('reliable_bot', Path(__file__).resolve().parents[1] / 'lib/tgbot.py')
        self.bot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bot)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bot._STATE_PATH = self.temp.name + '/state.json'
        self.bot.tg = lambda *a, **kw: self.fail('Unexpected Telegram API')

    def test_invalid_admin_ids_warn_without_import_failure(self):
        stream = io.StringIO()
        with contextlib.redirect_stderr(stream):
            self.assertEqual(self.bot._parse_admin_ids('1,invalid 2'), {1, 2})
        self.assertIn('TG_ADMIN_IDS', stream.getvalue())

    def test_crash_after_write_leaves_marker_and_restart_does_not_replay(self):
        bot = self.bot
        writes = []
        def crash(msg):
            writes.append(1)
            raise SystemExit('simulated power loss')
        bot.handle_message = crash
        update = {'update_id': 42, 'message': {'text': 'SECRET'}}
        with self.assertRaises(SystemExit):
            bot._dispatch_update(update)
        raw = Path(bot._STATE_PATH).read_text()
        self.assertNotIn('SECRET', raw)
        self.assertIn('42', json.loads(raw)['pending'])
        stream = io.StringIO()
        with contextlib.redirect_stderr(stream):
            self.assertEqual(bot._load_offset(), 43)
        self.assertIn('unfinished', stream.getvalue())
        bot._dispatch_update(update)
        self.assertEqual(writes, [1])

    def test_acceptance_persistence_failure_prevents_write(self):
        bot = self.bot
        bot.handle_message = lambda msg: self.fail('must not perform side effect')
        with patch.object(bot, '_write_offset_state', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                bot._dispatch_update({'update_id': 5, 'message': {}})

    def test_corrupt_state_strict_startup_refuses_replay(self):
        Path(self.bot._STATE_PATH).write_text('{broken')
        with self.assertRaisesRegex(RuntimeError, 'refusing unsafe replay'):
            self.bot._load_offset(strict=True)

    def test_background_marker_lives_until_task_finishes(self):
        bot = self.bot
        jobs = []
        bot._BG_EXECUTOR.submit = jobs.append
        bot.handle_message = lambda msg: bot.background(lambda: None)
        bot._dispatch_update({'update_id': 6, 'message': {}})
        self.assertEqual(json.loads(Path(bot._STATE_PATH).read_text())['pending'], {'6': 1})
        jobs.pop()()
        self.assertEqual(json.loads(Path(bot._STATE_PATH).read_text())['pending'], {})

    def test_console_task_failure_renders_error_and_finishes_update(self):
        bot = self.bot
        jobs = []
        renders = []
        bot._BG_EXECUTOR.submit = jobs.append
        bot.upsert_console = lambda *args, **kwargs: renders.append(args)
        bot.handle_message = lambda msg: bot.console_async(
            1, lambda: (_ for _ in ()).throw(RuntimeError("hidden")))
        bot._dispatch_update({'update_id': 7, 'message': {}})
        self.assertEqual(json.loads(Path(bot._STATE_PATH).read_text())['pending'], {'7': 1})
        jobs.pop()()
        self.assertEqual(json.loads(Path(bot._STATE_PATH).read_text())['pending'], {})
        self.assertIn("操作失败", renders[0][1])

    def test_callback_task_failure_renders_error_and_releases_busy(self):
        bot = self.bot
        jobs = []
        renders = []
        bot.background = lambda fn, *args: jobs.append(lambda: fn(*args))
        bot.edit = lambda cb, text, *args: renders.append(text)
        cb = {'message': {'chat': {'id': 1}, 'message_id': 7}}
        bot.edit_async(cb, lambda: (_ for _ in ()).throw(RuntimeError("hidden")))
        self.assertIn((1, 7), bot.BUSY)
        jobs.pop()()
        self.assertNotIn((1, 7), bot.BUSY)
        self.assertIn("操作失败", renders[0])

    def test_old_edit_executes_write_but_does_not_replace_new_menu(self):
        bot = self.bot
        jobs, writes, renders = [], [], []
        bot.background = lambda fn, *args: jobs.append(lambda: fn(*args))
        bot.edit = lambda *args: renders.append(args)
        cb = {'message': {'chat': {'id': 1}, 'message_id': 7}}
        bot.edit_async(cb, lambda: writes.append(1) or 'old')
        bot._bump_chat_generation(1)
        jobs.pop()()
        self.assertEqual(writes, [1])
        self.assertEqual(renders, [])

    def test_old_console_result_is_suppressed_after_computation(self):
        bot = self.bot
        jobs, writes = [], []
        bot.background = lambda fn, *args: jobs.append(lambda: fn(*args))
        bot.console_async(1, lambda: writes.append(1) or 'old')
        bot._bump_chat_generation(1)
        jobs.pop()()
        self.assertEqual(writes, [1])


if __name__ == '__main__':
    unittest.main()
