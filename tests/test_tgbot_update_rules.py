import importlib.util
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot", root / "lib" / "tgbot.py")
tgbot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tgbot)


class UpdateRulesTextTest(unittest.TestCase):
    def test_chinalist_label_has_no_mojibake(self):
        def fake_run2(argv, timeout=None, **kwargs):
            if argv[-1] == "--update-rules":
                return True, "GFWList: 123\nChinaList: 456\n"
            raise AssertionError("unexpected command: %r" % (argv,))

        tgbot.run2 = fake_run2
        tgbot._is_active = lambda unit: "inactive"

        result = tgbot.op_update_rules()
        self.assertEqual(
            result,
            "✅ <b>规则已更新</b>\n• GFWList：123 域名\n• ChinaList：456 域名",
        )
        self.assertNotIn("�", result)


if __name__ == "__main__":
    unittest.main()
