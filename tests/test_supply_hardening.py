"""Supply-chain regressions: no real package installs or network requests."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SupplyHardeningTests(unittest.TestCase):
    def run_shell(self, body):
        return subprocess.run(["bash", "-c", body], text=True, capture_output=True)

    def test_go_bad_digest_never_extracts(self):
        result = self.run_shell(f'''
source "{ROOT}/lib/services.sh"
info() {{ :; }}; ok() {{ :; }}; warn() {{ :; }}; err() {{ echo "$*" >&2; }}
PKG_MGR=none
command() {{ if [[ "$*" == '-v go' ]]; then return 1; fi; builtin command "$@"; }}
uname() {{ echo x86_64; }}
wget() {{ printf corrupt > "${{@: -1}}"; }}
tar() {{ echo UNSAFE_EXTRACTION; return 99; }}
rm() {{ if [[ "$*" == *'/usr/local/go'* ]]; then echo UNSAFE_DELETE; else command rm "$@"; fi; }}
install_deps
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertNotIn("UNSAFE", result.stdout)

    def test_broken_certbot_never_invokes_pip(self):
        result = self.run_shell(f'''
source "{ROOT}/lib/services.sh"
info() {{ :; }}; ok() {{ :; }}; warn() {{ :; }}; err() {{ echo "$*" >&2; }}
PKG_MGR=none
go() {{ echo version; }}
certbot() {{ return 1; }}
pip3() {{ echo UNSAFE_PIP; }}
install_deps
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("system package manager", result.stderr)
        self.assertNotIn("UNSAFE_PIP", result.stdout)

    def test_quick_requires_commit_and_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "data"
            marker.write_text("keep")
            launcher = Path(tmp) / "bootstrap.sh"
            launcher.write_text("set -euo pipefail\n" + (ROOT / "install.sh").read_text().split("bootstrap_install() (\n", 1)[1].split("\n)\n", 1)[0].replace('RUNTIME_DIR="/opt/5gpn"', f'RUNTIME_DIR="{tmp}/runtime"'))
            env = dict(os.environ, PGW_SRC_DIR=tmp, PGW_COMMIT="invalid")
            result = subprocess.run(["bash", str(launcher)], env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "keep")
            env["PGW_COMMIT"] = "a" * 40
            result = subprocess.run(["bash", str(launcher)], env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "keep")

    def test_sniproxy_bootstrap_initializes_autotools_macros(self):
        text = (ROOT / "lib/services.sh").read_text()
        marker = '[[ "$(git rev-parse HEAD)" == "$sniproxy_commit" ]]'
        start = text.index(marker)
        block = text[start:text.index('make -j', start)]
        self.assertIn('rm -rf autom4te.cache', block)
        self.assertIn('rm -f aclocal.m4 configure config.log config.status', block)
        self.assertIn('libtoolize --install --copy --force', block)
        self.assertIn('aclocal --install --force -I m4', block)

    def test_sniproxy_fetch_failure_never_builds(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "sniproxy"
            src.mkdir()
            (src / "autogen.sh").write_text('#!/bin/sh\necho UNSAFE_BUILD\n')
            (src / "autogen.sh").chmod(0o755)
            result = self.run_shell(f'''
source "{ROOT}/lib/services.sh"
info() {{ :; }}; ok() {{ :; }}; warn() {{ :; }}; err() {{ echo "$*" >&2; }}
ensure_proxy_user() {{ :; }}
command() {{ if [[ "$*" == '-v sniproxy' ]]; then return 1; fi; builtin command "$@"; }}
SRC_DIR="{tmp}"
git() {{ return 1; }}
make() {{ echo UNSAFE_BUILD; }}
install_sniproxy
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("UNSAFE_BUILD", result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
