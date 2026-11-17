import importlib.util
import json
from pathlib import Path
import platform
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('slot_prepare', Path(__file__).with_name('prepare-tart-cache-slots.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


@unittest.skipUnless(platform.system() == 'Darwin', 'Real APFS clonefile test requires macOS')
class CacheSlotPreparationTests(unittest.TestCase):
    def setUp(self):
        area = tempfile.TemporaryDirectory()
        self.addCleanup(area.cleanup)
        self.root = Path(area.name).resolve()
        self.source = self.root / 'base/p-test'
        self.source.mkdir(parents=True)
        for entry in prepare.SHARED.values():
            (self.source / entry['path']).mkdir()
        (self.source / 'build.db').write_text('original build state')
        self.target = self.root / 'slots/p-test'

    def seed(self):
        stage = prepare.seed_slots(self.source, self.target, 'p-test')
        self.addCleanup(lambda: shutil.rmtree(stage) if stage.exists() else None)
        return stage

    def test_real_apfs_clones_keep_writes_independent_and_exclude_shared_directories(self):
        stage = self.seed()
        first, second = stage / 'slot-0/build.db', stage / 'slot-1/build.db'
        self.assertNotEqual(first.stat().st_ino, (self.source / 'build.db').stat().st_ino)
        first.write_text('compiler A state')
        self.assertEqual(second.read_text(), 'original build state')
        self.assertEqual((self.source / 'build.db').read_text(), 'original build state')
        self.assertFalse((stage / 'slot-0/ci-storage-v1').exists())
        manifest = json.loads((stage / 'manifest.json').read_text())
        self.assertNotIn('kinhin-ci-tools', manifest['sharedDirectories'])

    def test_simulator_tools_are_an_explicit_read_only_opt_in(self):
        (self.source / 'ci-tools-v1').mkdir()
        stage = prepare.seed_slots(self.source, self.target, 'p-test',
                                   shared={**prepare.SHARED, **prepare.SIMULATOR_TOOLS})
        self.addCleanup(lambda: shutil.rmtree(stage) if stage.exists() else None)
        manifest = json.loads((stage / 'manifest.json').read_text())
        self.assertTrue(manifest['sharedDirectories']['kinhin-ci-tools']['readOnly'])
        self.assertFalse((stage / 'slot-0/ci-tools-v1').exists())

    def test_unused_tool_bundles_are_not_copied_into_writable_private_slots(self):
        (self.source / 'ci-tools-v1').mkdir()
        (self.source / 'ci-tools-v1/simslim').write_text('pinned tool')
        stage = self.seed()
        self.assertFalse((stage / 'slot-0/ci-tools-v1').exists())
        self.assertFalse((stage / 'slot-1/ci-tools-v1').exists())

    def test_absolute_links_to_the_seed_become_slot_relative_links(self):
        (self.source / 'current').symlink_to(self.source / 'build.db')
        stage = self.seed()
        linked = stage / 'slot-0/current'
        self.assertFalse(Path(linked.readlink()).is_absolute())
        (stage / 'slot-0/build.db').write_text('private')
        self.assertEqual(linked.read_text(), 'private')
        self.assertEqual((self.source / 'build.db').read_text(), 'original build state')

    def test_escaping_relative_links_fail_without_publishing_or_leaving_staging(self):
        (self.source / 'escape').symlink_to('../../elsewhere')
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            self.seed()
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.iterdir()), [])

    def test_existing_slot_scope_is_never_overwritten(self):
        self.target.mkdir(parents=True)
        (self.target / 'keep').write_text('active products')
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.seed()
        self.assertEqual((self.target / 'keep').read_text(), 'active products')


class OfflineInventoryTests(unittest.TestCase):
    def check(self, tart=None, containers=None, images=None, status=None):
        fixtures = [json.dumps(status if status is not None else {
            'daemonRunning': True, 'running': False, 'fleet': {'records': []}}).encode(),
            json.dumps(tart if tart is not None else [{'Name': 'base', 'State': 'stopped', 'Running': False}]).encode(),
            json.dumps(containers if containers is not None else []).encode(),
            plistlib.dumps({'images': images or []})]
        with patch.object(prepare.subprocess, 'check_output', side_effect=fixtures):
            prepare.require_stopped(Path('/host/cache'))

    def test_stopped_empty_fleet_and_unattached_seed_pass(self):
        self.check()

    def test_incomplete_fleet_status_fails_closed(self):
        with self.assertRaises(RuntimeError):
            self.check(status={'daemonRunning': True, 'running': False})

    def test_running_suspended_and_unknown_tart_state_are_protected(self):
        for entry in [{'Name': 'base', 'State': 'suspended'}, {'Name': 'base'},
                      {'Name': 'base', 'State': 'stopped', 'Running': True},
                      {'Name': 'kinhin-1794800000-aaaa1111', 'State': 'stopped'}]:
            with self.subTest(entry=entry), self.assertRaises(RuntimeError):
                self.check(tart=[entry])

    def test_unknown_container_state_is_protected(self):
        with self.assertRaises(RuntimeError):
            self.check(containers=[{'id': 'other'}])

    def test_attached_seed_sparsebundle_is_protected(self):
        with self.assertRaisesRegex(RuntimeError, 'still attached'):
            self.check(images=[{'image-path': '/host/cache/native/utter.sparsebundle'}])


if __name__ == '__main__':
    unittest.main()
