#!/usr/bin/env python3
"""Prepare two copy-on-write Tart caches while the fleet is stopped."""
import argparse
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

SHARED = {'kinhin-ci-storage': {'path': 'ci-storage-v1', 'readOnly': False},
          'kinhin-ci-tools': {'path': 'ci-tools-v1', 'readOnly': True}}


def unlinked(path):
    if not path.is_absolute() or path != path.resolve():
        raise RuntimeError('Cache paths must be absolute without symlink ancestors')


def clone_regular(source, target):
    # Unlike a copying API, this syscall cannot fall back to a full copy.
    if platform.system() != 'Darwin':
        raise RuntimeError('APFS cache preparation requires macOS')
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    if clone(os.fsencode(source), os.fsencode(target), 0):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(source))


def clone_tree(source, target, scope_root, shared):
    info = source.lstat()
    if stat.S_ISLNK(info.st_mode):
        value = os.readlink(source)
        resolved = source.resolve()
        if resolved.is_relative_to(scope_root):
            relative = resolved.relative_to(scope_root)
            for name, entry in shared.items():
                if relative.parts and relative.parts[0] == entry['path']:
                    value = str(Path('/Volumes/My Shared Files') / name / Path(*relative.parts[1:]))
                    break
            else:
                if Path(value).is_absolute():
                    value = os.path.relpath(resolved, source.parent)
        elif not Path(value).is_absolute():
            raise RuntimeError('A relative cache symlink escapes its scope: ' + str(source))
        elif resolved.is_relative_to(scope_root.parent):
            raise RuntimeError('A cache symlink points into another host cache scope: ' + str(source))
        target.symlink_to(value)
    elif stat.S_ISDIR(info.st_mode):
        target.mkdir()
        for child in source.iterdir():
            clone_tree(child, target / child.name, scope_root, shared)
        shutil.copystat(source, target, follow_symlinks=False)
    elif stat.S_ISREG(info.st_mode):
        clone_regular(source, target)
    else:
        raise RuntimeError('Unsupported special file in cache: ' + str(source))


def seed_slots(source, target, scope, shared=SHARED):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', scope):
        raise RuntimeError('Invalid project cache scope')
    unlinked(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    unlinked(target)
    if target.exists():
        raise RuntimeError('Prepared cache scope already exists; refusing to replace its data')
    for entry in shared.values():
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', entry['path']):
            raise RuntimeError('Invalid shared cache path')
        unlinked(source / entry['path'])
        if not (source / entry['path']).is_dir():
            raise RuntimeError('Prepare the shared storage and pinned tools first')
    if source.is_relative_to(target.parent) or target.parent.is_relative_to(source):
        raise RuntimeError('The cache source and slot root must be separate')
    stage = Path(tempfile.mkdtemp(prefix='.' + scope + '-preparing-', dir=target.parent))
    try:
        excluded = {entry['path'] for entry in shared.values()}
        for index in range(2):
            slot = stage / ('slot-' + str(index))
            slot.mkdir(mode=0o700)
            for child in source.iterdir():
                if child.name not in excluded:
                    clone_tree(child, slot / child.name, source, shared)
        manifest = {'schema': 1, 'scope': scope, 'slots': 2, 'sharedDirectories': shared,
                    'seededAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        return stage
    except BaseException:
        shutil.rmtree(stage)
        raise


def require_stopped(source=None):
    def read(*args):
        return json.loads(subprocess.check_output(args, timeout=30))
    status = read('kinhin', 'status', '--json')
    if (status.get('daemonRunning') is not True or status.get('running') is not False
            or not isinstance(status.get('fleet', {}).get('records'), list)
            or status['fleet']['records']):
        raise RuntimeError('Stop the fleet after all jobs finish before preparing cache slots')
    guests = read('tart', 'list', '--format', 'json')
    if not isinstance(guests, list):
        raise RuntimeError('Unknown Tart inventory format')
    for guest in guests:
        name = guest.get('Name', guest.get('name'))
        state = guest.get('State', guest.get('state'))
        if not isinstance(name, str) or state != 'stopped' or guest.get('Running', False) is not False:
            raise RuntimeError('A Tart image is running, suspended or has an unknown state')
        if re.fullmatch(r'kinhin-\d{9,11}-[0-9a-f]{4,8}', name):
            raise RuntimeError('A Tart runner still exists')
    containers = read('container', 'list', '--format', 'json')
    if not isinstance(containers, list) or any(
            v.get('status', {}).get('state') != 'stopped' for v in containers):
        raise RuntimeError('A Linux guest still runs or has unknown state')
    if source is not None:
        attachments = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist'], timeout=30))
        for image in attachments.get('images', []):
            path = image.get('image-path')
            if not isinstance(path, str):
                raise RuntimeError('Cannot identify an attached host disk image')
            if Path(path).resolve().is_relative_to(source):
                raise RuntimeError('A seed cache disk image is still attached on the host')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope', required=True)
    parser.add_argument('--support-dir', type=Path,
                        default=Path.home() / 'Library/Application Support/Kinhin')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', args.scope):
        parser.error('Invalid project cache scope')
    support = args.support_dir
    unlinked(support)
    root = support / 'runner-cache-slots'
    root.mkdir(exist_ok=True)
    with (root / '.prepare-lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require_stopped(support / 'toolchain-cache' / args.scope)
        if shutil.disk_usage(root).free < 20 * 1024 ** 3:
            raise RuntimeError('Keep at least 20 GiB free before preparing caches')
        target = root / args.scope
        stage = seed_slots(support / 'toolchain-cache' / args.scope, target, args.scope)
        try:
            require_stopped(support / 'toolchain-cache' / args.scope)  # Refuse publication if someone resumed during the copy.
            stage.rename(target)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
        print(json.dumps({'scope': args.scope, 'slots': 2, 'root': str(target)}))


if __name__ == '__main__':
    main()
