#!/usr/bin/env python3
"""Compare stock and native-ci simulator idle footprint in a disposable CI VM."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time


def run(arguments, timeout=300):
    return subprocess.check_output(arguments, text=True, timeout=timeout).strip()


def production_configuration(runtimes, types, inventory):
    matches = [(runtime_id, device) for runtime_id, devices in inventory['devices'].items()
               for device in devices if device.get('name') == 'GitHub Actions iPhone']
    if len(matches) != 1:
        raise RuntimeError('Expected one production GitHub Actions iPhone template')
    runtime_id, template = matches[0]
    runtime = next((r for r in runtimes if r['identifier'] == runtime_id and r.get('isAvailable')), None)
    device_type = next((d for d in types if d['identifier'] == template.get('deviceTypeIdentifier')), None)
    if runtime is None or device_type is None:
        raise RuntimeError('The production simulator runtime and device type must be available')
    return runtime, device_type


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=Path('/Volumes/My Shared Files/kinhin-ci-tools'))
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--settle-seconds', type=int, default=60)
    args = parser.parse_args()
    if args.pairs < 2 or args.settle_seconds < 30:
        raise RuntimeError('Use at least two pairs and 30 seconds of equal settling')
    if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.machine() != 'arm64':
        raise RuntimeError('Run only in a disposable ARM64 GitHub CI VM')
    if not run(['/usr/sbin/sysctl', '-n', 'hw.model']).startswith('VirtualMac'):
        raise RuntimeError('Refusing to change simulators on the physical host')
    source = Path(__file__).resolve().parent
    manifest = json.loads((args.tools / 'bundle-manifest.json').read_text())
    for name in ['simslim', 'native-ci.json', 'contracts.json', 'source-lock.json']:
        if hashlib.sha256((args.tools / name).read_bytes()).hexdigest() != manifest['files'][name]:
            raise RuntimeError('Pinned tool bundle hash mismatch: ' + name)
    for name in ['native-ci.json', 'contracts.json', 'source-lock.json']:
        if (args.tools / name).read_bytes() != (source / name).read_bytes():
            raise RuntimeError('Benchmark must use the deployed capability-preserving profile: ' + name)
    spec = importlib.util.spec_from_file_location('simulator_prepare', source / 'prepare-simulator.py')
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)
    runtimes = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
    types = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))['devicetypes']
    inventory = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    runtime, device_type = production_configuration(runtimes, types, inventory)
    binary = str(args.tools / 'simslim')
    contracts = json.loads((source / 'contracts.json').read_text())['repositories']
    required = sorted({feature for contract in contracts.values() for feature in contract['requires']})
    data = dict(schema=1, purpose='paired-idle-simulator-footprint',
                source_commit=manifest['source_commit'], profile=json.loads((source / 'native-ci.json').read_text()),
                runtime=runtime, device_type=device_type, xcode=run(['xcodebuild', '-version']),
                guest_memory_bytes=int(run(['/usr/sbin/sysctl', '-n', 'hw.memsize'])),
                pairs=args.pairs, settle_seconds=args.settle_seconds, samples_per_trial=5,
                sample_interval_seconds=5, trials=[], succeeded=False,
                scope='Idle simulator process-tree phys_footprint; not Xcode build or UI-test peak RAM')
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = args.output.with_suffix('.pending')
        temporary.write_text(json.dumps(data, indent=2) + '\n')
        temporary.replace(args.output)

    save()
    name = os.environ['GITHUB_REPOSITORY'].rsplit('/', 1)[-1] + ' test ' + os.environ['GITHUB_RUN_ID'] + '-' + os.environ['GITHUB_RUN_ATTEMPT']

    def trial(condition, pair):
        device = run(['xcrun', 'simctl', 'create', name, device_type['identifier'], runtime['identifier']])
        started = time.monotonic()
        entry = dict(pair=pair, condition=condition, device=device,
                     started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), samples=[])
        data['trials'].append(entry)
        save()
        try:
            if condition == 'native-ci':
                hook.prepare(device, args.tools)
            else:
                run(['xcrun', 'simctl', 'boot', device])
            run(['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=600)
            entry['prepare_and_boot_seconds'] = round(time.monotonic() - started, 2)
            entry['doctor'] = json.loads(run([binary, 'doctor', '--json', '--requires', ','.join(required), device]))
            time.sleep(args.settle_seconds)
            for index in range(5):
                measurement = json.loads(run([binary, 'measure', '--json', device], timeout=60))
                if measurement['bytes'] <= 0 or measurement['processes'] <= 0:
                    raise RuntimeError('Invalid simulator measurement')
                entry['samples'].append(dict(index=index, measurement=measurement,
                    guest_vm_stat=run(['/usr/bin/vm_stat']),
                    guest_swap=run(['/usr/sbin/sysctl', 'vm.swapusage'])))
                save()
                if index < 4:
                    time.sleep(5)
            entry['median_bytes'] = statistics.median(s['measurement']['bytes'] for s in entry['samples'])
            entry['median_processes'] = statistics.median(s['measurement']['processes'] for s in entry['samples'])
            print(json.dumps({k: entry[k] for k in ['pair', 'condition', 'median_bytes', 'median_processes', 'prepare_and_boot_seconds']}), flush=True)
        finally:
            # Only the UUID created by this invocation is ever stopped or deleted.
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
            run(['xcrun', 'simctl', 'delete', device], timeout=60)
            entry['deleted'] = True
            save()

    # Prime runtime initialization equally before collecting either condition.
    trial('stock', 'warmup-excluded')
    for pair in range(args.pairs):
        order = ['stock', 'native-ci'] if pair % 2 == 0 else ['native-ci', 'stock']
        for condition in order:
            trial(condition, pair)
    medians = {condition: statistics.median(t['median_bytes'] for t in data['trials']
                if t['condition'] == condition and t['pair'] != 'warmup-excluded')
               for condition in ['stock', 'native-ci']}
    data['summary'] = dict(median_bytes=medians,
        saving_bytes=medians['stock'] - medians['native-ci'],
        saving_percent=round(100 * (1 - medians['native-ci'] / medians['stock']), 2))
    data['succeeded'] = True
    save()
    print(json.dumps(data['summary']), flush=True)


if __name__ == '__main__':
    main()
