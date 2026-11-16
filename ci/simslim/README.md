# Simulator profile for the dual-Mac experiment

This is an unactivated candidate. Keep the complete Xcode image and simulator
runtime. The profile preserves widgets, Screen Time, Siri/speech, StoreKit,
keychain/iCloud, Photos, web, search, connectivity and app services. It disables
unused PIM, Health/Home, telemetry and MDM daemons, with explicit exceptions for
DeviceCheck, diagnostic extensions and managed assets. Required services stay
subject to the normal unit and UI tests.

The upstream memory estimates describe iOS 26.5 and are not additive. They do
not establish a saving for this device's iOS 27.1 runtime. Measure both guest
memory and complete workflow duration before choosing a permanent 6 GiB limit.

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
