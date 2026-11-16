import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'ci/simslim/install-tool-bundle.py'
spec = importlib.util.spec_from_file_location('tool_bundle', MODULE)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ToolBundleTests(unittest.TestCase):
    def setUp(self):
        area = tempfile.TemporaryDirectory()
        self.addCleanup(area.cleanup)
        self.root = Path(area.name).resolve()
        lock = json.loads((MODULE.parent / 'source-lock.json').read_text())
        self.binary = self.root / 'simslim'
        self.binary.write_text('#!/bin/sh\nprintf "simslim kinhin-ci-' + lock['simslim_commit'] + '\\n"\n')
        self.binary.chmod(0o755)
        self.digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.target = self.root / 'shared/ci-tools-v1'

    def test_exact_binary_and_all_files_are_hashed_in_published_bundle(self):
        manifest = bundle.install(self.binary, self.digest, self.target)
        for name, digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((self.target / name).read_bytes()).hexdigest(), digest)
        self.assertIn('prepare-simulator.py', manifest['files'])
        self.assertEqual(json.loads((self.target / 'bundle-manifest.json').read_text()), manifest)
        self.assertEqual(list(self.target.parent.glob('.ci-tools-*')), [])

    def test_wrong_digest_never_publishes_a_bundle(self):
        with self.assertRaisesRegex(RuntimeError, 'verified build'):
            bundle.install(self.binary, '0' * 64, self.target)
        self.assertFalse(self.target.exists())

    def test_existing_or_symlinked_bundle_is_never_replaced(self):
        bundle.install(self.binary, self.digest, self.target)
        original = (self.target / 'bundle-manifest.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'new, unlinked'):
            bundle.install(self.binary, self.digest, self.target)
        self.assertEqual((self.target / 'bundle-manifest.json').read_bytes(), original)
        link = self.root / 'linked'
        link.symlink_to(self.target, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'new, unlinked'):
            bundle.install(self.binary, self.digest, link)


if __name__ == '__main__':
    unittest.main()
