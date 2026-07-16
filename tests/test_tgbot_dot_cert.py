import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_dot_cert", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


class DotCertStatusTest(unittest.TestCase):
    def test_dot_status_shows_certificate_days_left(self):
        bot._read_file = lambda path: {"/etc/mosdns/.domain": "dns.example.com",
                                       "/etc/mosdns/.remote_dns": "8.8.8.8",
                                       "/etc/mosdns/.local_dns": "223.5.5.5"}.get(path)
        bot._cert_expiry = lambda path=None: (29, "2026-08-11")
        text = bot.op_dot_status()
        self.assertIn("证书剩余：<code>29 天</code>（到期：2026-08-11）", text)

    def test_cert_status_line_warns_when_expiring_or_missing(self):
        bot._cert_expiry = lambda path=None: (7, "2026-07-20")
        self.assertIn("建议尽快续期", bot._cert_status_line())
        bot._cert_expiry = lambda path=None: (-3, "2026-07-10")
        self.assertIn("已过期 3 天", bot._cert_status_line())
        bot._cert_expiry = lambda path=None: (None, None)
        self.assertIn("未找到证书", bot._cert_status_line())

    def test_dns_upstream_parser_accepts_encrypted_urls(self):
        value = bot._dns_arg(
            "https://1.1.1.1/dns-query, udp://8.8.8.8:53 "
            "tls://1.0.0.1:853 tcp://9.9.9.9:53"
        )
        self.assertEqual(
            value,
            "https://1.1.1.1/dns-query udp://8.8.8.8:53 "
            "tls://1.0.0.1:853 tcp://9.9.9.9:53",
        )

    def test_dns_upstream_parser_rejects_unsafe_or_malformed_urls(self):
        self.assertEqual(bot._dns_arg("https://example.com/dns-query"), "")
        self.assertEqual(bot._dns_arg("https://1.1.1.1/wrong-path"), "")
        self.assertEqual(bot._dns_arg("file://1.1.1.1/dns-query"), "")

    def test_cert_expiry_parses_real_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert = Path(tmp) / "fullchain.pem"
            key = Path(tmp) / "key.pem"
            gen = subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(key), "-out", str(cert), "-days", "90",
                 "-subj", "/CN=dns.example.com"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if gen.returncode != 0:
                self.skipTest("openssl unavailable")
            days, date = bot._cert_expiry(str(cert))
            self.assertIn(days, (89, 90))
            self.assertRegex(date, r"^\d{4}-\d{2}-\d{2}$")

    def test_cert_expiry_missing_file_returns_none(self):
        self.assertEqual(bot._cert_expiry("/nonexistent/cert.pem"), (None, None))


if __name__ == "__main__":
    unittest.main()
