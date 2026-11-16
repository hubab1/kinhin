import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'ci/simslim/prepare-simulator.py'
spec = importlib.util.spec_from_file_location('simulator_prepare', MODULE)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SimulatorProfileHookTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.device = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
        self.env = dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY='hubab1/utter', GITHUB_RUN_ID='123',
                        GITHUB_RUN_ATTEMPT='1', RUNNER_TEMP=str(self.root / 'job'))
        files = {'simslim': b'pinned executable', 'source-lock.json': b'{"simslim_commit":"source"}',
                 'native-ci.json': b'{"name":"test"}', 'contracts.json': json.dumps({
                     'schema': 1, 'repositories': {'hubab1/utter': {
                         'profile': 'native-ci.json', 'requires': ['widgets', 'storekit']}}}).encode()}
        for name, data in files.items():
            (self.root / name).write_bytes(data)
        (self.root / 'bundle-manifest.json').write_text(json.dumps({
            'schema': 1, 'source_commit': 'source',
            'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}))
        self.calls = []
        self.model = 'VirtualMac2,1'
        self.name = 'utter test 123-1'
        self.state = 'Shutdown'
        self.failure = None

    def execute(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == '/usr/sbin/sysctl':
            return subprocess.CompletedProcess(args, 0, self.model, '')
        if args[0] == 'xcrun':
            data = {'devices': {'runtime': [{'udid': self.device, 'name': self.name, 'state': self.state}]}}
            return subprocess.CompletedProcess(args, 0, json.dumps(data), '')
        if self.failure == args[1]:
            return subprocess.CompletedProcess(args, 33, '', 'native profile check failed')
        return subprocess.CompletedProcess(args, 0, '{}' if args[1] == 'doctor' else 'profile verified', '')

    def run_prepare(self):
        return prepare.prepare(self.device, self.root, self.env, self.execute)

    def mutators(self):
        return [c for c in self.calls if c[0] == str(self.root / 'simslim')]

    def test_owned_device_profiles_before_doctor_and_keeps_required_features_and_evidence(self):
        self.run_prepare()
        calls = self.mutators()
        self.assertEqual([c[1] for c in calls], ['on', 'doctor'])
        self.assertEqual(calls[0][-1], self.device)
        self.assertNotIn('--preserve-boot-state', calls[0])
        self.assertIn('widgets,storekit', calls[1])
        identity = json.loads((self.root / 'job/ci-simslim' / self.device / 'identity.json').read_text())
        self.assertEqual(identity['source_commit'], 'source')

    def test_physical_mac_guard_blocks_every_mutator(self):
        self.model = 'MacBookPro18,3'
        with self.assertRaisesRegex(RuntimeError, 'Tart Mac guest'):
            self.run_prepare()
        self.assertEqual(self.mutators(), [])

    def test_an_existing_or_foreign_device_is_not_reconfigured(self):
        for name, state in [('GitHub Actions iPhone', 'Shutdown'), ('utter test 123-1', 'Booted')]:
            self.name, self.state = name, state
            with self.assertRaisesRegex(RuntimeError, 'newly created'):
                self.run_prepare()
            self.assertEqual(self.mutators(), [])

    def test_tampered_profile_is_rejected_before_any_mutation(self):
        (self.root / 'native-ci.json').write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'hash mismatch'):
            self.run_prepare()
        self.assertEqual(self.mutators(), [])

    def test_apply_failure_stays_blocking_and_preserves_the_native_error(self):
        self.failure = 'on'
        with self.assertRaisesRegex(RuntimeError, 'validation failed'):
            self.run_prepare()
        self.assertEqual([c[1] for c in self.mutators()], ['on'])
        self.assertIn('native profile check failed',
                      (self.root / 'job/ci-simslim' / self.device / 'on.log').read_text())

    def test_required_feature_failure_stays_blocking(self):
        self.failure = 'doctor'
        with self.assertRaisesRegex(RuntimeError, 'validation failed'):
            self.run_prepare()
        self.assertFalse((self.root / 'job/ci-simslim' / self.device / 'identity.json').exists())


if __name__ == '__main__':
    unittest.main()
