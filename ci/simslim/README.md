# Simulator profile for native CI

This is an optional workflow tool for disposable Remind and Utter CI guests. Cache
preparation omits its mount by default; `scripts/prepare-tart-cache-slots.py
--simulator-tools` opts into it when preparing a new scope offline. Existing scopes
require an explicit offline manifest change. Keep the complete Xcode image and simulator
runtime. The profile preserves widgets, Screen Time, Siri/speech, StoreKit,
keychain/iCloud, Photos, web, search, connectivity and app services. It disables
unused PIM, Health/Home, telemetry and MDM daemons, with explicit exceptions for
DeviceCheck, diagnostic extensions and managed assets. Required services stay
subject to the normal unit and UI tests.

SimSlim is a separate pinned simulator tool, applied by a workflow hook. It does
not require changes to Kinhin's scheduler or a reduced macOS image. It leaves the
VM's 6 GiB configuration unchanged; its potential benefit is more memory available
to the app and test runner inside that VM. It does not reduce macOS, Xcode compiler,
or macOS UI-test memory. The conservative profile disables only unused PIM,
Health/Home, telemetry and management services, so the project's aggressive default
profile savings cannot be applied to this setup.

The upstream memory estimates describe iOS 26.5 and are not additive. They do
not establish a saving for this device's actual CI simulator runtime. Run `python3
ci/simslim/benchmark.py --output /path/to/result.json` inside a disposable CI VM.
The benchmark excludes one stock warmup, alternates stock/profile order across
three fresh-device pairs using the production `GitHub Actions iPhone` template's
runtime and device type, settles every boot for 60 seconds and records five
process-tree `phys_footprint` samples, process counts, guest memory/swap state,
capability checks and preparation time. It always deletes only the device it
created. Idle simulator savings do not establish peak workflow RAM or throughput;
retain the 6 GiB limit and blocking UI suites until workload measurements justify
a change. Stop applying this profile if its measured savings do not justify its
startup overhead and maintenance cost.

Build the pinned Darwin ARM64 CLI from `source-lock.json`. Share the binary,
profile and contracts read-only into the guest as `kinhin-ci-tools`. A synchronous
hook must apply the profile after each owned `simctl create`, before its first
boot. SimSlim's `on` performs the initial boot and verification itself; do not
request a preserve/shutdown cycle before the workflow's boot check. Run `doctor`
with the repository's nonempty required-feature list. Its daemon checks complement
the native suites; they do not replace functional UI assertions.

Activation also requires prepared single-writer Tart cache slots, the shared
diagnostic mount, full fork build/tests and serial ThreadSanitizer checks. Keep
warm/idle pools at zero and permit only one Linux slot, scaled to zero during
the paired Mac experiment. No release or publication is part of this experiment.
