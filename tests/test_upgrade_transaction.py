"""Hermetic upgrade behavior through the real run_install_step convention.

Production literals are redirected in temporary source copies before sourcing;
network/build/service boundaries are mocked, not the transaction or renderer.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UNITS = ('mosdns', 'sniproxy', 'quic-proxy', 'wa-shim', '5gpn-tgbot', '5gpn-mihomo@smart')


class UpgradeTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fs = self.root / 'fs'
        self.source = self.root / 'source'
        self.source.mkdir()
        shutil.copytree(ROOT / 'lib', self.source / 'lib')
        script = (ROOT / 'install.sh').read_text().split('\ncase "${1:-}" in\n')[0]
        (self.source / 'install.sh').write_text(script)
        # Every production absolute filesystem prefix in sourced scripts is
        # redirected. /proc is read-only FD introspection used by routing_lock.
        for p in [self.source / 'install.sh', *self.source.glob('lib/*')]:
            if p.suffix not in ('.sh', '.py', '.template'):
                continue
            text = p.read_text()
            for prefix in ('/opt/', '/etc/', '/var/', '/usr/local/', '/run/lock/'):
                text = text.replace(prefix, str(self.fs) + prefix)
            p.write_text(text)
        self.bin = self.root / 'mockbin'
        self.bin.mkdir()
        self.put('/etc/mosdns/.remote_dns', '1.1.1.1\n')
        self.put('/etc/mosdns/.local_dns', '119.29.29.29\n')
        for f in ('config.yaml', 'config.yaml.template', 'gfwlist.txt', 'chinalist.txt',
                  'override-direct.txt', 'override-proxy.txt', 'override-block.txt'):
            self.put('/etc/mosdns/' + f, 'old-' + f + '\n')
        self.put('/etc/mosdns/domain-overrides.conf', 'example.org=proxy\n')
        self.put('/etc/mosdns/.public_ip', '192.0.2.1\n')
        self.put('/etc/sysctl.d/99-5gpn.conf',
                 '# Proxy Gateway Optimizations (profile: performance)\n'
                 'net.netfilter.nf_conntrack_tcp_timeout_established=30\n')
        self.put('/etc/5gpn/rules.conf', 'DOMAIN-SUFFIX,example.org,direct\n')
        self.put('/etc/5gpn/rules-default.conf', 'old-default\n')
        # A complete existing installation maps all shipped default categories.
        categories = {line.rsplit(',', 1)[-1].strip() for line in
                      (ROOT / 'lib/rules-default.conf').read_text().splitlines()
                      if line and not line.startswith('#')}
        self.put('/etc/5gpn/policy-map.conf',
                 ''.join(f'{category}=direct\n' for category in sorted(categories)))
        self.put('/etc/5gpn/exits/smart.yaml', 'old-smart\n')
        self.put('/etc/5gpn/exits/smart.type', 'router\n')
        self.put('/etc/5gpn/rulesets/existing', 'old-cache\n')
        self.put('/opt/5gpn/etc/current-exit', 'smart\n')
        self.put('/opt/5gpn/etc/mihomo/smart/runtime', 'old-runtime\n')
        self.put('/opt/5gpn/bin/quic-proxy', 'old-binary\n', 0o755)
        self.put('/opt/5gpn/bin/mihomo', '#!/bin/bash\n[[ "$FAIL" != smart_validation ]]\n', 0o755)
        self.put('/var/lib/5gpn-quic/remote-dns', 'old-dns\n')
        self.put('/usr/local/bin/mosdns', '#!/bin/bash\n[[ "$FAIL" != renderer ]]\n', 0o755)
        self.put('/usr/local/bin/update-mosdns-rules.sh', 'old-updater\n', 0o755)
        self.put('/etc/systemd/system/quic-proxy.service', 'old-unit\n')
        self.put('/etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh', 'old-hook\n')
        self.state = self.root / 'states'
        self.state.mkdir()
        for i, unit in enumerate(UNITS):
            (self.state / unit).write_text('active' if i % 2 == 0 else 'inactive')
            (self.state / (unit + '.enabled')).write_text('enabled' if i < 3 else 'disabled')
        self.mock('systemctl', '''#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$TEST_ROOT/events"
unit="${*: -1}"; unit="${unit%.service}"
case "$1" in
 is-active) [[ "$(cat "$TEST_ROOT/states/$unit")" == active ]];;
 is-enabled) [[ "$(cat "$TEST_ROOT/states/$unit.enabled")" == enabled ]];;
 restart)
   if [[ "$FAIL" == restart && ! -f "$TEST_ROOT/failed" ]]; then
     touch "$TEST_ROOT/failed"; echo inactive > "$TEST_ROOT/states/$unit"; exit 1
   fi
   echo -n active > "$TEST_ROOT/states/$unit";;
 daemon-reload|cat) :;;
 *) echo "unexpected service mutation $*" >&2; exit 97;;
esac
''')
        self.mock('go', '''#!/bin/bash
set -eu
# A distinct open-file description must fail to acquire the parent's lock.
if flock -n "$PGW_ROUTING_LOCK_FILE" -c true; then exit 98; fi
echo held >> "$TEST_ROOT/lock-proof"
[[ "$FAIL" != build ]] || exit 31
printf 'new-quic\n' > quic-proxy
''')
        self.kernel = self.root / 'kernel-timeout'
        self.kernel.write_text('30')
        self.mock('sysctl', '''#!/bin/bash
set -eu
key=net.netfilter.nf_conntrack_tcp_timeout_established
case "$1" in
 -n)
   [[ "$2" == "$key" ]]
   [[ "$FAIL" != sysctl_read ]] || exit 32
   cat "$TEST_ROOT/kernel-timeout";;
 -w)
   [[ "$2" == "$key="* ]]
   echo "sysctl $*" >> "$TEST_ROOT/events"
   if [[ "$2" == "$key=86400" ]]; then
     [[ "$FAIL" != sysctl_write ]] || exit 33
     [[ "$FAIL" != sysctl_verify ]] || exit 0
   fi
   printf '%s' "${2#*=}" > "$TEST_ROOT/kernel-timeout";;
 *) exit 99;;
esac
''')
        for command in ('curl', 'wget', 'useradd', 'iptables', 'ip'):
            self.mock(command, '#!/bin/bash\necho forbidden >&2\nexit 99\n')
        self.env = dict(os.environ, TEST_ROOT=str(self.root), FAIL='',
                        PGW_ROUTING_LOCK_FILE=str(self.root / 'routing.lock'),
                        PATH=f'{self.bin}:{self.fs}/usr/local/bin:' + os.environ['PATH'],
                        TMPDIR=str(self.root / 'tmp'))
        (self.root / 'tmp').mkdir()
        self.runner = self.source / 'runner.sh'
        self.runner.write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
SCRIPT_PATH="$SCRIPT_DIR/install.sh"
INSTALL_LOG="$TEST_ROOT/upgrade.log"
# Never run download/install helpers or any interactive routing apply helper.
install_mosdns_binary() { printf 'new-mosdns\\n' > "${TEST_ROOT}/fs/usr/local/bin/mosdns"; }
regen_smart() { echo forbidden-regen >&2; exit 99; }
init_install_log
run_install_step upgrade upgrade_code
printf 'completed\\n'
''')

    def put(self, path, text, mode=0o640):
        p = self.fs / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def mock(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def restore_mosdns_mock(self):
        self.put('/usr/local/bin/mosdns', '#!/bin/bash\n[[ "$FAIL" != renderer ]]\n', 0o755)

    def snapshot(self):
        return {str(p.relative_to(self.fs)): (p.read_bytes(), p.stat().st_mode & 0o777)
                for p in self.fs.rglob('*') if p.is_file()}

    def states(self):
        return {p.name: p.read_text() for p in self.state.iterdir()}

    def run_upgrade(self, fail=''):
        self.env['FAIL'] = fail
        result = subprocess.run(['bash', str(self.runner)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        log = self.root / 'upgrade.log'
        self.detail = result.stderr + (log.read_text() if log.exists() else '')
        # No leaked lock after success or rollback.
        self.assertEqual(subprocess.run(['flock', '-n', self.env['PGW_ROUTING_LOCK_FILE'],
                                         '-c', 'true']).returncode, 0)
        return result

    def assert_rollback(self, fail):
        before, states = self.snapshot(), self.states()
        kernel_before = self.kernel.read_text()
        result = self.run_upgrade(fail)
        self.assertNotEqual(result.returncode, 0, self.detail)
        self.assertNotIn('completed', result.stdout)
        self.assertNotIn('unbound variable', self.detail)
        self.assertEqual(before, self.snapshot(), self.detail)
        self.assertEqual(states, self.states(), self.detail)
        self.assertEqual(kernel_before, self.kernel.read_text(), self.detail)
        self.assertFalse(list(self.fs.glob('opt/5gpn/.upgrade-*')))

    def test_renderer_failure_rolls_back_through_actual_step(self):
        self.assert_rollback('renderer')

    def test_build_failure_rolls_back_and_cleans_build_directory(self):
        self.assert_rollback('build')
        self.assertIn('stage=quic-build exit=31', self.detail)
        self.assertEqual((self.root / 'lock-proof').read_text(), 'held\n')
        # Offline rendering must not restart mosdns before the rest of the
        # upgrade transaction succeeds; rollback performs the only recovery
        # restart for a failure after publication.
        events = (self.root / 'events').read_text().splitlines()
        self.assertEqual(sum(line == 'restart mosdns.service' for line in events), 1)

    def test_restart_failure_restores_files_and_active_disabled_services(self):
        self.assert_rollback('restart')

    def test_smart_validation_failure_restores_runtime_and_cache(self):
        self.assert_rollback('smart_validation')

    def test_invalid_offline_rule_cache_reports_failure_and_rolls_back(self):
        (self.fs / 'etc/5gpn/rules.conf').unlink()
        self.put('/etc/mosdns/.remote_dns', '22.22.22.22\n')
        self.put('/etc/mosdns/.local_dns', '101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29\n')
        self.put('/etc/mosdns/gfwlist.txt', '')
        self.put('/etc/mosdns/chinalist.txt', 'example.cn\n')
        before = self.snapshot()
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0, self.detail)
        self.assertIn('Offline GFWList cache is missing or invalid', self.detail)
        self.assertIn('stage=offline-dns exit=1', self.detail)
        self.assertEqual(before, self.snapshot(), self.detail)
        # Rollback restarts the services that were active before the
        # transaction, even when validation failed before publication.
        self.assertIn('restart mosdns.service',
                      (self.root / 'events').read_text() if (self.root / 'events').exists() else '')

    def test_invalid_dns_preflight_never_changes_managed_files(self):
        for name in ('.remote_dns', '.local_dns'):
            with self.subTest(name=name):
                path = self.fs / 'etc/mosdns' / name
                old = path.read_text()
                path.write_text('https://dns.example/dns-query\n')
                before = self.snapshot()
                result = self.run_upgrade()
                self.assertNotEqual(result.returncode, 0, self.detail)
                self.assertIn('stage=dns-preflight exit=1', self.detail)
                self.assertEqual(before, self.snapshot())
                self.assertFalse((self.root / 'events').exists())
                self.assertFalse(list(self.fs.glob('opt/5gpn/.upgrade-*')))
                path.write_text(old)

    def test_success_preserves_stopped_enabled_and_active_disabled_states(self):
        states = self.states()
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, self.detail)
        self.assertEqual(states, self.states())
        self.assertIn('completed', result.stdout)
        self.assertEqual(self.kernel.read_text(), '86400')
        self.assertEqual((self.root / 'lock-proof').read_text(), 'held\n')
        events = (self.root / 'events').read_text()
        for unit in ('sniproxy', 'wa-shim', '5gpn-mihomo@smart'):
            self.assertNotIn('restart ' + unit + '.service', events)
        self.assertIn('restart 5gpn-tgbot.service', events)
        self.assertEqual([line for line in events.splitlines() if line.startswith('restart mosdns')],
                         ['restart mosdns.service'])
        self.assertEqual((self.fs / 'var/lib/5gpn-quic/remote-dns').read_text(), '1.1.1.1\n')
        self.assertIn('net.netfilter.nf_conntrack_tcp_timeout_established=86400',
                      (self.fs / 'etc/sysctl.d/99-5gpn.conf').read_text())
        self.assertFalse(list(self.fs.glob('opt/5gpn/.upgrade-*')))

    def test_sysctl_read_failure_restores_files(self):
        self.assert_rollback('sysctl_read')

    def test_sysctl_write_failure_restores_files_and_kernel(self):
        self.assert_rollback('sysctl_write')

    def test_sysctl_readback_mismatch_restores_files_and_kernel(self):
        self.assert_rollback('sysctl_verify')

    def test_new_file_with_stale_kernel_is_repaired_and_idempotent(self):
        p = self.fs / 'etc/sysctl.d/99-5gpn.conf'
        p.write_text(p.read_text().replace('=30', '=86400'))
        for _ in range(2):
            self.restore_mosdns_mock()
            result = self.run_upgrade()
            self.assertEqual(result.returncode, 0, self.detail)
            self.assertEqual(self.kernel.read_text(), '86400')
        events = (self.root / 'events').read_text()
        self.assertEqual(events.count('sysctl -w '), 1)

    def test_custom_file_and_non_project_profiles_are_preserved(self):
        for profile, value, explicit in (
                ('performance', '3600', ''), ('essential', '30', ''),
                ('custom', '30', ''), ('performance', '30', 'essential')):
            with self.subTest(profile=profile, value=value, explicit=explicit):
                data = ('# Proxy Gateway Optimizations (profile: ' + profile + ')\n'
                        'net.netfilter.nf_conntrack_tcp_timeout_established=' + value + '\n')
                p = self.put('/etc/sysctl.d/99-5gpn.conf', data)
                self.kernel.write_text('30')
                self.env['PGW_TUNING'] = explicit
                self.restore_mosdns_mock()
                result = self.run_upgrade()
                self.assertEqual(result.returncode, 0, self.detail)
                self.assertEqual(p.read_text(), data)
                self.assertEqual(self.kernel.read_text(), '30')

    def test_custom_runtime_is_not_lowered_or_overwritten(self):
        for value in ('3600', '432000'):
            with self.subTest(value=value):
                self.put('/etc/sysctl.d/99-5gpn.conf',
                         '# Proxy Gateway Optimizations (profile: performance)\n'
                         'net.netfilter.nf_conntrack_tcp_timeout_established=30\n')
                self.kernel.write_text(value)
                self.restore_mosdns_mock()
                result = self.run_upgrade()
                self.assertEqual(result.returncode, 0, self.detail)
                self.assertEqual(self.kernel.read_text(), value)
                self.assertIn('=30\n', (self.fs / 'etc/sysctl.d/99-5gpn.conf').read_text())

    def test_active_smart_upgrade_does_not_apply_routes_or_migrate_legacy_units(self):
        (self.state / '5gpn-mihomo@smart').write_text('active')
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, self.detail)
        events = (self.root / 'events').read_text()
        self.assertEqual(events.count('restart 5gpn-mihomo@smart.service'), 1)
        self.assertNotIn('singbox', events)
        self.assertEqual((self.fs / 'opt/5gpn/etc/current-exit').read_text(), 'smart\n')


if __name__ == '__main__':
    unittest.main()
