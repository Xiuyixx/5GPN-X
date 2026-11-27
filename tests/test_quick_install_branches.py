"""Execute launcher with isolated paths and fake git/installer, never deploy."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
OLD = "b" * 40


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.runtime = self.base / "runtime"
        self.source = self.base / "source"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.launcher = self.base / "quick.sh"
        text = "set -euo pipefail\n" + (ROOT / "install.sh").read_text().split("bootstrap_install() (\n", 1)[1].split("\n)\n", 1)[0]
        text = text.replace('RUNTIME_DIR="/opt/5gpn"', f'RUNTIME_DIR="{self.runtime}"')
        # Root check only is disabled for non-root CI; actual operations mocked.
        text = text.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
        self.launcher.write_text(text)
        git = self.bin / "git"
        git.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$TEST_BASE/git.calls"
case "$*" in
  ls-remote*)
    [[ "${FAIL_REF:-0}" != 1 ]] || exit 1
    [[ "${EMPTY_REF:-0}" != 1 ]] || exit 0
    printf '%s refs/heads/main\\n' "$TEST_SHA";;
  clone*) mkdir -p "${@: -1}/.git"; cp "$TEST_BASE/fixture.sh" "${@: -1}/install.sh";;
  *status*) [[ "${DIRTY:-0}" != 1 ]] || printf ' M install.sh\\n';;
  *rev-parse*) echo "$TEST_SHA";;
esac
''')
        git.chmod(0o755)
        (self.base / "fixture.sh").write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$TEST_BASE/install.calls"
if [[ -t 0 ]]; then echo tty >> "$TEST_BASE/input"; else cat > "$TEST_BASE/input"; fi
exit "${FAIL_INSTALL:-0}"
''')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        PGW_SRC_DIR=str(self.source), TEST_BASE=str(self.base), TEST_SHA=SHA)
        self.env.pop("PGW_COMMIT", None)

    def run_launcher(self, *args, **env):
        return subprocess.run(["bash", str(self.launcher), *args], input="payload\n",
                              text=True, capture_output=True, start_new_session=True,
                              env=dict(self.env, **env), timeout=15)

    def legacy(self):
        (self.runtime / "etc").mkdir(parents=True)
        (self.runtime / "etc/.domain").write_text("saved.example.org\n")

    def test_fresh_and_current(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "install.calls").read_text(), "\n")
        self.assertEqual((self.base / "input").read_text(), "payload\n")
        self.assertEqual((self.runtime / ".installed-commit").read_text().strip(), SHA)
        result = self.run_launcher()
        self.assertIn("无需升级", result.stdout)
        self.assertEqual((self.base / "install.calls").read_text(), "\n")

    def test_legacy_non_git_and_old(self):
        self.legacy()
        for marker in (None, OLD):
            if marker:
                (self.runtime / ".installed-commit").write_text(marker)
            result = self.run_launcher()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "install.calls").read_text(), "\n--upgrade\n")
        self.assertEqual((self.runtime / "etc/.domain").read_text(), "saved.example.org\n")
        self.assertFalse((self.runtime / ".git").exists())
        self.assertEqual((self.base / "input").read_text(), "")

    def test_incomplete_first_install_retries_fresh_flow(self):
        (self.runtime / "etc").mkdir(parents=True)
        (self.runtime / "etc/.domain").write_text("saved.example.org\n")
        (self.runtime / ".install-attempt").write_text("mode=install\n")
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "install.calls").read_text(), "\n")
        self.assertEqual((self.base / "input").read_text(), "payload\n")

    def test_failure_preserves_marker_and_retry(self):
        self.legacy()
        (self.runtime / ".installed-commit").write_text(OLD)
        result = self.run_launcher(FAIL_INSTALL="9")
        self.assertEqual(result.returncode, 9)
        self.assertEqual((self.runtime / ".installed-commit").read_text(), OLD)
        self.assertTrue((self.runtime / ".install-attempt").exists())
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertFalse((self.runtime / ".install-attempt").exists())

    def test_network_and_empty_resolution(self):
        for env in ({"FAIL_REF": "1"}, {"EMPTY_REF": "1"}):
            result = self.run_launcher(**env)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.runtime.exists())
            self.assertFalse(self.source.exists())

    def test_status_offline_preserves_stdin(self):
        (self.runtime / "bin").mkdir(parents=True)
        (self.runtime / "bin/5gpn-ctl").write_text((self.base / "fixture.sh").read_text())
        result = self.run_launcher("--status", FAIL_REF="1")
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.base / "git.calls").exists())
        self.assertEqual((self.base / "input").read_text(), "payload\n")
        self.assertFalse((self.runtime / ".installed-commit").exists())

    def test_dirty_checkout_is_archived_before_clean_checkout(self):
        self.source.mkdir()
        (self.source / ".git").mkdir()
        (self.source / "manual-edit.txt").write_text("keep me\\n")
        result = self.run_launcher(DIRTY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.source / "install.sh").read_text(), (self.base / "fixture.sh").read_text())
        backups = list(self.base.glob("source.backup-*/source"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "manual-edit.txt").read_text(), "keep me\\n")
        self.assertTrue((backups[0] / ".git").is_dir())

    def test_non_git_source_is_archived_before_clean_checkout(self):
        self.source.mkdir()
        (self.source / "manual-edit.txt").write_text("keep me\\n")
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.source / "install.sh").read_text(),
                         (self.base / "fixture.sh").read_text())
        backups = list(self.base.glob("source.backup-*/source"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "manual-edit.txt").read_text(), "keep me\\n")

    def test_checkout_alone_is_fresh(self):
        (self.source / ".git").mkdir(parents=True)
        (self.source / "install.sh").write_text((self.base / "fixture.sh").read_text())
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual((self.base / "install.calls").read_text(), "\n")

    def test_pipe_uses_controlling_tty(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", "-c", f"printf payload | bash {self.launcher}"], self.env)
        try:
            while True:
                ready, _, _ = select.select([fd], [], [], 15)
                self.assertTrue(ready, "PTY launcher timed out")
                try:
                    if not os.read(fd, 8192):
                        break
                except OSError:
                    break
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0)
        finally:
            os.close(fd)
        self.assertEqual((self.base / "input").read_text(), "tty\n")


if __name__ == "__main__":
    unittest.main()
