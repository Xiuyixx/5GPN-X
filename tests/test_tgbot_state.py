import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

root = Path(__file__).resolve().parents[1]


class OffsetStateTest(unittest.TestCase):
    """Regression tests for tgbot getUpdates offset persistence."""

    @classmethod
    def setUpClass(cls):
        cls.tmpdir = tempfile.TemporaryDirectory()
        cls.state_file = os.path.join(cls.tmpdir.name, "sub", "tgbot-state.json")
        os.makedirs(os.path.dirname(cls.state_file), exist_ok=True)
        # _STATE_PATH is read from the environment at module import time.
        os.environ["TG_STATE_FILE"] = cls.state_file
        spec = importlib.util.spec_from_file_location("tgbot_state", root / "lib" / "tgbot.py")
        cls.bot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.bot)

    @classmethod
    def tearDownClass(cls):
        cls.tmpdir.cleanup()

    def test_no_state_file_returns_none(self):
        self.assertIsNone(self.bot._load_offset())

    def test_save_then_load_returns_next_offset(self):
        self.bot._save_offset(42)
        self.assertEqual(self.bot._load_offset(), 43)

    def test_overwrite_updates_offset(self):
        self.bot._save_offset(42)
        self.bot._save_offset(50)
        self.assertEqual(self.bot._load_offset(), 51)

    def test_corrupt_state_returns_none(self):
        with open(self.state_file, "w", encoding="utf-8") as f:
            f.write("{not valid json")
        self.assertIsNone(self.bot._load_offset())

    def test_save_creates_parent_dirs(self):
        nested = os.path.join(self.tmpdir.name, "a", "b", "state.json")
        self.bot._STATE_PATH = nested
        self.bot._save_offset(7)
        self.assertTrue(os.path.isfile(nested))
        self.assertEqual(self.bot._load_offset(), 8)
        self.bot._STATE_PATH = self.state_file

    def test_state_file_owner_only_permissions(self):
        if os.name == "nt":
            self.skipTest("POSIX permission bits are not enforced on Windows")
        self.bot._save_offset(1)
        mode = os.stat(self.state_file).st_mode & 0o777
        self.assertEqual(mode, 0o600)


if __name__ == "__main__":
    unittest.main()
