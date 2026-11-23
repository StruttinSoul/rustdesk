# Aperture integration removal — 2026-10-20

User requested removal of Codex and related app work. This removes the integration from Aperture, leaving standalone tools, personal histories, unrelated dirty work and remote-access functionality in place.

## Source changes

- Removed mobile Codex navigation, task overview, conversation/review/workspace UI, model and FFI event plumbing.
- Removed task notifications, notification settings/persistence wiring, notification deep-link routing and Android notification handler.
- Removed Windows app-server discovery, service/process/RPC/approval/history/workspace/review modules, host status component, request dispatch, session ownership state and client response handling.
- Removed dedicated tests, feature architecture/plans and five dedicated PNG design exports. Removed the obsolete CI test reference. Updated active acceptance records; mixed historical designs/specifications remain as historical records.
- Removed feature protocol messages and capability. Reserved Features field4 and Message fields34–37 and their names; all remaining numbers stay unchanged. No submodule change.
- Prepared local version1.5.2/4105, preserving application ID and signing identity.

## Verification and delivery

Final local builds and artifact verification passed. No automated tests, phone interaction, installation, publication or Git history changes performed for this task.

Targeted Flutter analysis after correcting deletion boundaries: zero errors; one pre-existing unused dart:math import and28 informational diagnostics. The command returns1 because of existing diagnostics. Initial failed checks caught adjacent emulator/clipboard request methods and dashboard shell included in the deletion; exact originals were restored and the deletion narrowed before the current checks.

Whole-app Flutter analysis: zero errors, five warnings and237 informational diagnostics (242 total; exit1). Existing diagnostics remain; Windows warning-message comparison with the previous build found no new messages.

- Final Windows release build: exit0,12m32s. `target/remove-codex-20261020/windows/librustdesk.dll`; SHA256 `D7B8A4AA64687603552131F61592F7C8C803FA404242C7CA6327F1B1072C5CD4`.
- Android native release build: exit0,9m49s. JNI SHA256 `24762392CDF22FC2F69B65349174CE8C7225434F425A9724D1304719F7268EC0`. Temporary dependency build scripts restored to exact original SHA256 values.
- Signed APK build: exit0,4m17s. `target/remove-codex-20261020/android/Aperture-1.5.2-android-arm64.apk`; SHA256 `2722be955925042010c294598150ae2ae9807886c3d51a4bcec956618cb0f92e`. Package/version4105, Aperture branding, release debuggability, targetSDK36, pinned release certificate and signing lineage checks passed.
- Embedded JNI/C++ hashes match the built inputs; all packaged ARM64 ELF load segments support16KiB alignment; ZIP alignment verified. No dedicated integration asset remains in the APK.
-351 application source/build-input hashes verified unchanged. Generated `src/version.rs` is intentionally regenerated per native target by `build.rs`/`hbb_common::gen_version`; its Cargo version and timestamp were validated and recorded separately rather than treated as a stable input.
-56 before-copy hashes verified. Git index, branch, HEAD and all unrelated tracked diff blocks match the starting state. Final source/task diff reviewed; no unrelated refactors or formatting changes.

Exact before-copies, manifests, original dirty/index patches, task-only diff, verification script and build logs are in `target/remove-codex-20261020`. Installed1.5.1 and public1.5.0 remain unchanged. Device/runtime acceptance remains unverified for this removal. Installing or publishing this candidate needs current-task authorization under AGENTS.md; none was requested or performed.

The affected existing paths are connected-PC navigation/session setup, optional host-health reporting, notification routing and protocol dispatch. Remote video/input, authentication, LAN/WAN routing, emulator focus/shutdown fixes and signing are outside the change.
