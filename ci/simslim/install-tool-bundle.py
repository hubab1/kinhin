#!/usr/bin/env python3
"""Stage a pinned SimSlim tool bundle for read-only Tart sharing; no guest mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def install(binary, expected_sha256, destination):
    source = Path(__file__).resolve().parent
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination != destination.resolve() or destination.exists():
        raise RuntimeError('Tool bundle destination must be a new, unlinked directory')
    if not re.fullmatch(r'[0-9a-f]{64}', expected_sha256):
        raise RuntimeError('An explicit verified SHA-256 is mandatory')
    if binary.is_symlink() or hashlib.sha256(binary.read_bytes()).hexdigest() != expected_sha256:
        raise RuntimeError('SimSlim binary does not match the verified build')
    lock = json.loads((source / 'source-lock.json').read_text())
    version = subprocess.check_output([str(binary), '--version'], text=True, timeout=10).strip()
    if lock['simslim_commit'] not in version:
        raise RuntimeError('SimSlim version does not identify the pinned source revision')
    stage = Path(tempfile.mkdtemp(prefix='.ci-tools-', dir=destination.parent))
    try:
        shutil.copy2(binary, stage / 'simslim')
        os.chmod(stage / 'simslim', 0o755)
        files = ['native-ci.json', 'contracts.json', 'source-lock.json', 'prepare-simulator.py']
        for name in files:
            shutil.copy2(source / name, stage / name)
        manifest = {'schema': 1, 'source_commit': lock['simslim_commit'], 'version': version,
                    'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.iterdir()}}
        (stage / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        stage.rename(destination)
        return manifest
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(install(args.binary, args.sha256, args.destination)))


if __name__ == '__main__':
    main()
