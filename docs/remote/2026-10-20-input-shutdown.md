# Emulator input and shutdown candidate — 2026-10-20

## Report and evidence

The user reports that emulator touch and keys sometimes stop responding while video continues, and switching views restores input. The shutdown prompt screenshot shows the exact title `Close BlueStacks App Player 1` and the `Cancel` / `Close` buttons. The existing selectors already match those words; a title mismatch is not established.

No running BlueStacks instance or Galaxy debugging connection was available for live inspection. Read-only Windows window inventory also found no BlueStacks window. Historical helper logs contain no new current-session shutdown failure. The earlier user instruction forbids tests; no tests, synthetic input, game actions or emulator starts/stops were performed. Subsequent explicit installation approval and its receipt are recorded below; no new publication occurred. The following are source-level weaknesses and corrections, not a proven live root cause or accepted end-to-end fix.

## Changes

- `flutter/lib/mobile/pages/emulator_page.dart`: a real pointer-down can restore the canvas keyboard focus and a stale view-focus flag. Recovery requires an actually resumed Flutter lifecycle, host control permission and a fresh guest frame. Old held input is released first. Existing frame, geometry, view-only and background restrictions remain effective.
- `src/server/emulator/remote_windows.rs`: capture generation changes release both keys and touches, preventing held keys from surviving a capture reset.
- `src/server/emulator/shutdown_windows.rs`: retry an already open exact confirmation rather than send another WM_CLOSE. Poll for the uniquely named Close button to become visible, enabled and actionable for up to ten seconds. Use its UI Automation Invoke action or supported legacy accessibility default action. Target PID/process creation identity, executable and exact dialog title are retained. No force termination, keyboard/coordinate click, arbitrary-dialog handling or global BlueStacks setting changes.
- `tools/aperture-release.json`: local candidate version1.5.1 / code4104, using the established production key and update lineage. The public1.5.0 release is unchanged.

## Validation

Flutter source analysis: `flutter analyze --no-pub lib/mobile/pages/emulator_page.dart`, exit0, no issues (87.4sec). This is analysis, not a runtime test.

Optimized Windows build: exit0, completed7m09sec with existing warnings. Staged AMD64 DLL SHA256 `DA25B20B18DB565A56A3AAAFFB8D32DB9CC3AE2EE9E9ADFF5B62D39B85DAB8E5`; embedded new confirmation error string verified. Existing installed DLL remains `025E78D0E606FF155EAF802AF42674A52E5D95E9CEDB1AB9FAD9A556475DBFB3`.

Signed APK: `target/input-shutdown-20261020/android/Aperture-1.5.1-android-arm64.apk`, version1.5.1/code4104, SHA256 `76de559a9cdabddbd9133b8fb876050a52d8c547d89cf932eb27f6c738ed4a53`. Build and signature/package/SDK36/16KiB ZIP checks passed. ELF payload inspection confirms ARM64 and16KiB-compatible native load alignment. Flutter application payload changed; JNI/Flutter runtime/C++ payloads match1.5.0. Production signer/lineage retained. All48 recorded source hashes match.

Artifacts, exact before-copies, task-only diffs and receipts are under `target/input-shutdown-20261020`. A DLL-only updater is staged under `deployment/` with pinned old/new hashes and a unique planned verified-backup/rollback path. Offline hashes and script syntax checked; service preflight is deferred to an approved elevated update. No updater or app install was executed, no new backup is claimed created, and no builds remain active. Deployment approval and the current Galaxy endpoint have been requested. These checks cannot prove the intermittent phone problem is resolved.

## Remaining

Current deployment approval and Galaxy Wireless debugging address are required to install the candidate. Do not run tests or confirm the live shutdown dialog under the retained no-tests instruction. If the behavior continues after an approved installation, collect narrowly scoped focus state / UIA-pattern evidence when the user authorizes diagnostics; do not layer more speculative fixes or weaken input safety.

## Approved installation and security warning

User explicitly approved both installations without tests and supplied Galaxy10.0.4.230:39177. Verified SM-S938W/R3CY50B0TRL; adb install -r succeeded and package metadata confirms4104/1.5.1. No app launch, data clear or tests. Windows update completed18:24:30Z2026-10-20; DLL matches DA25B20B...5DAB8E5, service Running PID42068,97 backups verified and96 other installed files unchanged. Backup and receipts are recorded in the current recovery checkpoint and stage/deployment/installed-verification.json.

The user's new screenshot shows Samsung App protection explicitly identifying Aperture1.5.1 as malware. Exact detection family/cause is not exposed. Do not classify it as a confirmed false positive, bypass the security prompt, or claim the new signing key cleared it. [McAfee confirms Samsung App protection is powered by McAfee](https://www.mcafee.com/en-us/consumer-support/policy/legal.html). The [official classification review form](https://www.mcafee.com/en-us/consumer-support/dispute-detection-allowlisting.html) accepts the installer plus extracted contents for analysis. A65.7MB local review ZIP and request text are prepared under stage/mcafee-review, excluding user screenshots/logs/settings and private keys. User authorized submission and supplied contact details. The agent filled the form, but the in-app attachment/tab failed before submission. User then explicitly reported “I submitted it.” Submission is recorded as user-reported, with no known case number or vendor verdict; duplicate agent submission was stopped. Await the vendor response. See stage/mcafee-review/submission-status.json.
