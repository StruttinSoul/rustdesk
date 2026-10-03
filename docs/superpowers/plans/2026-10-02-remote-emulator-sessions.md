# Remote emulator sessions implementation plan

**Goal:** After authenticating to a Windows PC, the Android client lists BlueStacks and LDPlayer instances and connects directly to one guest for video and input.

**Execution:** Implement inline in this chat; the user explicitly requested no agents. Preserve the pending BlueStacks Play changes. Do not publish, push, or distribute a release.

**Spec:** `docs/android-emulator-remote-architecture.md` and the user's approved instance-picker flow.

**Architecture:** Extend `libs/base/protos/message.proto` with typed, negotiated emulator messages. Keep instance resolution, guest-helper ownership, capture, and input inside `src/server/emulator/`. Reuse RustDesk's encrypted authenticated transport and H.264 decoder. Ship a matching test Android APK; the stock Android app cannot display a new picker.

## Constraints

- No BlueStacks binary, image, signature, Hyper-V, anti-cheat, or game changes.
- ADB and guest-helper sockets remain loopback-only on Windows.
- No arbitrary shell commands, executable paths, ADB serials, or forwarding destinations from remote clients.
- Discovery requires an authenticated ordinary remote session; lifecycle and input additionally require control permission.
- A connection owns only its helper process, sockets and forwarding entry. Disconnect and failed startup release them without stopping the emulator or another viewer.
- Do not reuse desktop display IDs as emulator identities or send guest input to Windows.
- Existing and old-client desktop behavior remains intact; unsupported clients do not advertise the feature.
- Pin the guest helper and verify it before execution. Retain third-party license notices in packaging.
- Success requires a tested host build, matching APK, live guest video/input, and instance isolation, not merely discovery tests.

## Work

- [x] Verify pinned guest-helper capture and control against the installed BlueStacks Android 13 runtime; record codec/dimensions and cleanup behavior.
- [x] Add bounded frame-header and control-packet adapters with malformed-length, timestamp/config-frame, and touch-coordinate tests.
- [x] Add typed discovery, selection, session-status, and Android-navigation protocol messages in `libs/base`; generate protocol bindings. Tests reject unknown IDs and unnegotiated requests.
- [x] Enumerate both providers independently, reporting unavailable-provider errors without hiding the other provider's targets. Resolve executable and serial locally on every start.
- [x] Add per-connection guest session ownership and startup/cancellation/cleanup. Test failed startup and disconnect release only owned resources.
- [x] Hook authenticated requests into `src/server/connection.rs`. Stop desktop media subscriptions before guest streaming; refuse desktop input paths while guest-selected. Test permission denial and file/terminal/camera session rejection.
- [x] Normalize H.264 configuration, keyframes and microsecond timestamps to RustDesk frames; bound video queues and reset sessions on reconnect. Mid-session guest rotation remains unverified.
- [x] Route pointer/key events and Android Back/Home/Recents through the persistent guest control socket. Preserve letterboxing/source dimensions and release touches on disconnect.
- [x] Add client responses/events through the existing Flutter common-command bridge. Add a capability-gated emulator picker with per-instance name, state, app and start/connect action.
- [x] Add Android guest-session rendering/navigation and explicit return-to-desktop/disconnect. Tests cover loading, denied selection, unsupported hosts and restored desktop behavior.
- [ ] Build Windows host and a debug/test Android APK. Validate real BlueStacks and LDPlayer, separate instances, minimized windows, reconnect and control denial. Report any device-only checks that remain unverified.

## Verification and known networking failures

Run focused new tests, the emulator regression suite, Flutter tests and analysis, then the normal Rust suite. Earlier runs before this remote-session work had failures in `test_secure_tcp_rejects_unverified_versions_before_reply`, `a_declined_udp_punch_still_replies`, and an intermittent `a_refused_channel_is_reported_once_per_reason`; an original-HEAD baseline has not been established. Do not count these as green or modify unrelated networking code.

Review every shared-file change against the disabled/unsupported-feature path before calling the feature ready.

## Current evidence

85 focused Rust tests and all153 Flutter tests passed. Analysis of new Flutter files has no issues; the existing remote page has two unchanged deprecation notices. Two independent BlueStacks instances stream guest video; cancelling one leaves the other usable. Home, Back and Recents input are verified; a streamed-coordinate touch opens the assigned MapleStory activity. Owned helper files/forwards cleaned after live tests.

Final Windows builds passed with `hwcodec,vram,flutter` and the verified guest helper/license. The final native DLL matches the packaged DLL. Portable host is running with ID373491561; keep its application open for the phone test. No system RustDesk service was installed during this work. The Windows build used a private SDK at `%LOCALAPPDATA%/MIRPG/windows-cache-sdk`, restored from FFmpeg7.1.1 and its exact matching dependency cache ABIs.

Signed ARM64 test APK is saved at `C:/Users/gregr/Downloads/MIRPG-Remote-arm64-test-2026-10-02.apk` (96,738,963bytes; SHA256 `cb43d8bcba7b16b736766217521ec490db98e6a07996d497975f32b6c5b199c5`). Separate package `com.carriez.flutter_hbb.mirpgtest`, label `MIRPG Remote (Test)`, version1.5.0/2068, minimum Android API22. APK v1/v2 signatures, ZIP alignment and all four ARM64 native libraries verified. Windows toolchain RUNPATH removed from the Android artifact using an Android-only Cargo profile override. Temporary hwcodec/libsodium build-script fixes are restored to their original bytes.

APK installation and rendered startup were verified in the second BlueStacks instance. Its translated GPU path later crashed in Flutter's raster thread; a local diagnostic launch using [Flutter's software-rendering shell argument](https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterShellArgs.html) reached the Windows host's password prompt successfully. That flag was only used for the local test; the phone APK retains normal rendering. No authentication password was entered, and the test connection was canceled. Actual phone authentication, native picker/guest video/input end-to-end, minimized/hidden windows and mid-session rotation remain unverified. Guest audio is currently disabled.

LDPlayer ADB is disabled; its usual serial resolves to BlueStacks because the port is shared. Remote path rejects disabled ADB and this provider mismatch before injecting input. LDPlayer live capture remains unverified until ADB configuration is resolved.

Complete Rust suite has five networking failures in unchanged files (474 passed,14 ignored). Two pass separately; three fail individually. Physical phone validation is the next required human step: install the test APK, connect to the PC, authenticate, then open the session menu's Emulators action.

Regression surface: shared base protocol adds negotiated messages; server connection hooks authenticate/own guest sessions and suppress desktop media/input only while selected; client I/O adds a separate guest decoder; Flutter event/model plumbing routes guest images/responses, and mobile action menu exposes picker only on supported hosts. Android metadata optionally gives test APK its own ID/label. BlueStacks provider/default-app/settings/tests preserve earlier Play work and add Android13 metadata. Existing unsupported desktop paths and emulator binaries are retained.

## Existing-file regression surface audit

- `libs/base/protos/message.proto`: additive negotiated capability/messages; no existing wire tag changed.
- `src/server/emulator.rs`: declares feature-specific modules; discovery/lifecycle providers remain intact.
- `src/server/connection.rs`: Windows-only guest ownership/authenticated request hooks, permission revocation and desktop input/media suppression during guest selection; ordinary unsupported sessions follow their existing path.
- `src/client.rs`: exports the typed UI request parser.
- `src/client/io_loop.rs`: owns a separate guest decoder, routes new messages, ignores desktop video only during a selected guest; reconnect/desktop status resets guest state.
- `src/ui_session_interface.rs`: additive typed request hook and default no-op response callback, avoiding changes to unrelated implementations.
- `src/flutter_ffi.rs`: adds an existing-common-command key; generated bridge signatures unchanged.
- `src/flutter.rs`: advertises negotiated feature in UI, maps typed responses, and releases guest-only image buffers on session changes.
- `flutter/lib/models/model.dart`: owns guest model and routes responses/RGBA using reserved guest channels; guards late desktop image completions while selected.
- `flutter/lib/mobile/pages/remote_page.dart`: capability-gated Emulators menu only.
- `flutter/android/app/build.gradle` and `AndroidManifest.xml`: explicit test-build property gives separate package/label; stock build metadata preserved.
- `build.rs`: target OS check avoids compiling Windows C++ on a Windows-to-Android cross build; normal Windows compilation retained.
- Preserved earlier Play/default-game work in `src/server/emulator/bluestacks.rs`, `flutter/lib/models/bluestacks_model.dart`, `flutter/lib/desktop/pages/desktop_setting_page.dart`, and `flutter/test/bluestacks_model_test.dart`. Remote feature only reads saved default games and adds the installed Tiramisu64 Android13 metadata.

No BlueStacks executable/image/signature, Hyper-V, game or networking baseline file changed. Inspection found one unthrottled decode warning in the new guest module; corrected using the repository logging throttle.
