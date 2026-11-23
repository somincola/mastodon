import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

CUSTOM = Path(__file__).resolve().parents[1]

# Never execute the generated remote commands. Inspect them and simulate their
# results, so this suite needs no SSH key, sudo, Docker, systemd, or network.
FAKE_SSH = r'''
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

assert Path(sys.argv[0]).name == 'ssh', 'Unexpected external command'
args = sys.argv[1:]
command = args[-1]
root = Path(os.environ['MOCK_ROOT'])
scenario = os.environ['MOCK_SCENARIO']
stdin = b'' if '-n' in args else sys.stdin.buffer.read()
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps({'command': command, 'stdin_bytes': len(stdin)}) + '\n')
assert '-T' in args
assert 'BatchMode=yes' in args and 'IdentitiesOnly=yes' in args
assert 'StrictHostKeyChecking=yes' in args and 'HostKeyAlias=mastodon-production' in args
assert args[-2] == 'admin@example.invalid'
assert command.startswith('sudo -n ')
subprocess.run(['/bin/bash', '-n', '-c', command], check=True)
tokens = shlex.split(command)

if '/usr/bin/mkdir' in tokens:
    assert tokens == ['sudo', '-n', '/usr/bin/mkdir', '-m', '700', '--',
                      '/opt/mastodon/automation/42593798270-2']
    if scenario == 'existing_run':
        sys.exit(1)
elif '/usr/bin/tee' in tokens:
    assert '-n' not in args, 'Uploads need stdin'
    name = 'deploy-latest.sh' if 'deploy-latest.sh' in command else 'verify-running.rb'
    assert stdin == (root / '.custom' / name).read_bytes()
    if scenario == 'upload_failure' and name == 'deploy-latest.sh':
        sys.exit(255)
    if scenario == 'checksum_failure' and name == 'deploy-latest.sh':
        stdin += b'corrupt upload\n'
    (root / ('uploaded-' + name)).write_bytes(stdin)
elif '/usr/bin/chmod' in tokens:
    assert tokens[3:5] == ['600', '--']
elif '/usr/bin/sha256sum' in tokens:
    assert '-n' not in args and tokens[-2:] == ['-c', '-']
    for line in stdin.decode().splitlines():
        digest, path = line.split('  ', 1)
        actual = hashlib.sha256((root / ('uploaded-' + Path(path).name)).read_bytes()).hexdigest()
        if digest != actual:
            sys.exit(1)
elif '/usr/bin/systemd-run' in tokens:
    for token in ['--uid=root', '--unit=mastodon-deploy-42593798270-2',
                  '--property=Type=exec', '--property=Restart=no',
                  '--property=WorkingDirectory=/opt/mastodon', '--property=UMask=0077',
                  '--property=StandardOutput=append:/opt/mastodon/automation/42593798270-2/output.log',
                  '--property=StandardError=inherit', 'HOME=/root', 'LANG=C.UTF-8']:
        assert token in tokens, token
    assert not any(token in tokens for token in ['--scope', '--pty', '--wait', '--collect'])
    assert tokens[-4:] == ['v4.7.5', 'sha256:' + 'a' * 64, 'sha256:' + 'b' * 64,
                           '/opt/mastodon/automation/42593798270-2']
    if scenario == 'start_failure':
        sys.exit(1)
    (root / 'started').touch()
elif '/bin/bash' in tokens and '-s' in tokens:
    assert (root / 'started').exists()
    assert '-n' not in args, 'Status script needs stdin'
    assert b'systemctl is-failed' in stdin
    subprocess.run(['/bin/bash', '-n'], input=stdin, check=True)
    counter = root / 'status-count'
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if scenario == 'lost_connection' or (scenario == 'connection_recovery' and count < 3):
        sys.exit(255)
    if scenario == 'phase_change' and count == 1:
        print('preflight')
    else:
        print('EXIT=17' if scenario == 'deploy_failure' else 'EXIT=0')
elif '/bin/bash' in tokens and tokens[-2] == '-n':
    pass
else:
    raise AssertionError('Unexpected SSH command: ' + command)
'''


class RemoteTransportTests(unittest.TestCase):
    def run_transport(self, scenario='success', overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.custom').mkdir()
            (root / 'bin').mkdir()
            for name in ('deploy-latest.sh', 'verify-running.rb'):
                (root / '.custom' / name).write_bytes((CUSTOM / name).read_bytes())
            # Deliberately not a real host key or private key. SSH is intercepted.
            (root / '.custom/server-host-key.pub').write_text('ssh-ed25519 FAKE_TEST_KEY\n')
            for name in ('ssh', 'scp', 'sudo', 'docker', 'systemd-run', 'curl'):
                command = root / 'bin' / name
                command.write_text('#!' + sys.executable + '\n' + FAKE_SSH)
                command.chmod(0o755)
            sleep = root / 'bin/sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            env = {
                **os.environ,
                'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                'MOCK_ROOT': str(root), 'MOCK_SCENARIO': scenario,
                'TARGET_VERSION': 'v4.7.5',
                'EXPECTED_WEB_DIGEST': 'sha256:' + 'a' * 64,
                'EXPECTED_STREAMING_DIGEST': 'sha256:' + 'b' * 64,
                'SERVER_HOST': 'example.invalid', 'SERVER_USER': 'admin', 'SERVER_PORT': '22',
                'SERVER_SSH_KEY': 'FAKE_TEST_KEY_NOT_A_REAL_PRIVATE_KEY',
                'GITHUB_RUN_ID': '42593798270', 'GITHUB_RUN_ATTEMPT': '2',
            }
            env.update(overrides or {})
            result = subprocess.run(['bash', str(CUSTOM / 'remote-deploy.sh')], cwd=root,
                                    env=env, capture_output=True, text=True, timeout=15)
            calls = root / 'calls.jsonl'
            records = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            count = root / 'status-count'
            return result, (root / 'started').exists(), records, int(count.read_text()) if count.exists() else 0

    def test_success_checks_uploads_and_waits_for_verified_exit(self):
        result, started, records, count = self.run_transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(started)
        self.assertEqual(len(records), 8)
        self.assertEqual(count, 1)
        self.assertIn('Deployment verified: v4.7.5', result.stdout)
        self.assertNotIn('FAKE_TEST_KEY', result.stdout + result.stderr)

    def test_failures_before_start_never_launch_deployment(self):
        for scenario, code in [('existing_run', 1), ('upload_failure', 255),
                               ('checksum_failure', 1), ('start_failure', 1)]:
            with self.subTest(scenario=scenario):
                result, started, _, count = self.run_transport(scenario)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertFalse(started)
                self.assertEqual(count, 0)
                if scenario == 'start_failure':
                    self.assertIn('start was not confirmed', result.stderr)

    def test_remote_failure_is_not_reported_as_success(self):
        result, started, _, _ = self.run_transport('deploy_failure')
        self.assertTrue(started)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Deployment failed (EXIT=17)', result.stderr)

    def test_phase_changes_continue_polling(self):
        result, _, _, count = self.run_transport('phase_change')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)
        self.assertIn('Deployment phase: preflight', result.stdout)

    def test_temporary_connection_failures_recover(self):
        result, _, _, count = self.run_transport('connection_recovery')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 3)

    def test_three_status_failures_do_not_restart_server_job(self):
        result, started, records, count = self.run_transport('lost_connection')
        self.assertTrue(started)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(count, 3)
        self.assertEqual(sum('/usr/bin/systemd-run' in call['command'] for call in records), 1)
        self.assertIn('job may still be running', result.stderr)

    def test_invalid_inputs_are_rejected_before_connecting(self):
        for name, value in [('TARGET_VERSION', 'v4.7.5;id'), ('EXPECTED_WEB_DIGEST', 'bad'),
                            ('SERVER_USER', 'admin;id'), ('SERVER_HOST', 'host;id'),
                            ('SERVER_PORT', '22;id'), ('GITHUB_RUN_ATTEMPT', '../other')]:
            with self.subTest(name=name):
                result, started, records, _ = self.run_transport(overrides={name: value})
                self.assertEqual(result.returncode, 2)
                self.assertFalse(started)
                self.assertEqual(records, [])


class RemoteStatusTests(unittest.TestCase):
    def test_actual_status_script_handles_exit_phase_empty_and_failed_service(self):
        script = (CUSTOM / 'remote-deploy.sh').read_text().split("<<'STATUS'\n", 1)[1].split('\nSTATUS\n', 1)[0]
        cases = [('0\n', None, False, 'EXIT=0'), ('7\n', None, False, 'EXIT=7'),
                 ('', 'complete', False, 'complete'), (None, 'preflight', False, 'preflight'),
                 (None, None, True, 'EXIT=1'), (None, None, False, 'starting')]
        for exit_code, phase, failed, expected in cases:
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    if exit_code is not None:
                        (root / 'exit-code').write_text(exit_code)
                    if phase is not None:
                        (root / 'phase').write_text(phase)
                    systemctl = root / 'systemctl'
                    systemctl.write_text('#!/bin/sh\nexit ' + ('0' if failed else '1') + '\n')
                    systemctl.chmod(0o755)
                    # Replace only the external systemctl adapter; execute the real status shell.
                    isolated = script.replace('/usr/bin/systemctl', shlex.quote(str(systemctl)))
                    result = subprocess.run(['bash', '-s', '--', str(root), 'test-unit'],
                                            input=isolated, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)


class DeploymentExitCodeTests(unittest.TestCase):
    def test_exit_trap_publishes_complete_code_atomically_and_preserves_status(self):
        source = (CUSTOM / 'deploy-latest.sh').read_text()
        function = 'finish() {\n' + source.split('finish() {\n', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        for code in (0, 17):
            with self.subTest(code=code):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / 'bin').mkdir()
                    mv = root / 'bin/mv'
                    mv.write_text('#!' + sys.executable + '\n' + '''
import os
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
assert source.name == 'exit-code.new' and destination.name == 'exit-code'
assert source.parent == destination.parent
assert not destination.exists(), 'Final status must not exist before atomic publication'
assert source.read_text() == os.environ['EXPECTED_EXIT'] + '\\n'
os.replace(source, destination)
(destination.parent / 'atomic-publication-checked').touch()
''')
                    mv.chmod(0o755)
                    env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                           'EXPECTED_EXIT': str(code)}
                    script = 'set -euo pipefail\nrun_dir=$1\n' + function + 'trap finish EXIT\nexit "$2"\n'
                    result = subprocess.run(['bash', '-s', '--', str(root), str(code)], input=script,
                                            env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual((root / 'exit-code').read_text(), str(code) + '\n')
                    self.assertTrue((root / 'atomic-publication-checked').exists())
                    self.assertFalse((root / 'exit-code.new').exists())
