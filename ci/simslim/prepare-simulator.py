#!/usr/bin/env python3
"""Apply the pinned CI profile only to this job's freshly owned VM simulator."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def prepare(device, tools=None, environment=None, execute=None):
    env = os.environ if environment is None else environment
    run = subprocess.run if execute is None else execute
    root = Path(__file__).resolve().parent if tools is None else tools.resolve()
    if env.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Simulator profiling is restricted to GitHub CI jobs')
    model = run(['/usr/sbin/sysctl', '-n', 'hw.model'], check=True, capture_output=True, text=True).stdout.strip()
    if not model.startswith('VirtualMac'):
        raise RuntimeError('Simulator profiling requires a Tart Mac guest')
    if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', device):
        raise RuntimeError('Expected the newly created simulator UUID')
    for key in ['GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT']:
        if not re.fullmatch(r'[0-9]+', env.get(key, '')):
            raise RuntimeError('Missing CI run identity')
    manifest = json.loads((root / 'bundle-manifest.json').read_text())
    if manifest.get('schema') != 1:
        raise RuntimeError('Unsupported pinned simulator tool bundle')
    for name, expected in manifest['files'].items():
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or name in ['.', '..']:
            raise RuntimeError('Invalid tool bundle filename')
        path = root / name
        if path != path.resolve() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Pinned simulator tool bundle hash mismatch: ' + name)
    for name in ['simslim', 'source-lock.json', 'contracts.json', 'native-ci.json']:
        if name not in manifest['files']:
            raise RuntimeError('Pinned tool bundle is incomplete: ' + name)
    source = json.loads((root / 'source-lock.json').read_text())
    if source['simslim_commit'] != manifest.get('source_commit'):
        raise RuntimeError('Simulator source provenance differs from the pinned bundle')
    repo = env.get('GITHUB_REPOSITORY', '')
    contracts = json.loads((root / 'contracts.json').read_text())
    if contracts.get('schema') != 1 or repo.lower() not in contracts['repositories']:
        raise RuntimeError('No simulator capability contract for this repository')
    contract = contracts['repositories'][repo.lower()]
    if contract['profile'] not in manifest['files'] or not contract['requires']:
        raise RuntimeError('A pinned profile and nonempty required-feature list are mandatory')
    if any(not re.fullmatch(r'[a-z0-9-]+', f) for f in contract['requires']):
        raise RuntimeError('Invalid required simulator feature')
    expected_name = repo.rsplit('/', 1)[-1] + ' test ' + env['GITHUB_RUN_ID'] + '-' + env['GITHUB_RUN_ATTEMPT']
    inventory = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                               check=True, capture_output=True, text=True).stdout)
    owned = [d for devices in inventory['devices'].values() for d in devices
             if d.get('udid') == device and d.get('name') == expected_name]
    if len(owned) != 1 or owned[0].get('state') != 'Shutdown':
        raise RuntimeError('Only this job\'s newly created, unbooted simulator may be profiled')
    evidence = Path(env['RUNNER_TEMP']).resolve() / 'ci-simslim' / device
    evidence.mkdir(parents=True, exist_ok=True)
    binary = str(root / 'simslim')
    commands = [
        ('on.log', [binary, 'on', '--profile', str(root / contract['profile']), device], 300),
        ('doctor.json', [binary, 'doctor', '--json', '--requires', ','.join(contract['requires']), device], 60),
    ]
    for name, arguments, timeout in commands:
        result = run(arguments, capture_output=True, text=True, timeout=timeout)
        (evidence / name).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('Simulator profile validation failed; see ' + str(evidence / name))
        if name.endswith('.json'):
            json.loads(result.stdout)
    identity = {'repository': repo, 'run': env['GITHUB_RUN_ID'], 'attempt': env['GITHUB_RUN_ATTEMPT'],
                'device': device, 'profile': contract['profile'], 'source_commit': manifest['source_commit'],
                'required_features': contract['requires']}
    (evidence / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    print('Simulator profile ready; required daemons verified before native tests: ' + str(evidence))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: prepare-simulator.py NEWLY_CREATED_UUID')
    prepare(sys.argv[1])
