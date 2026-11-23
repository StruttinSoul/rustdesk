# Android Emulator Remote — Architecture Audit

Date: 2026-10-01

## Goal

Keep one Windows computer as one RustDesk peer while allowing a connected client to select a first-class target within that peer:

```text
Windows PC
├── Desktop
└── Android Emulators
    ├── LDPlayer — Main
    └── BlueStacks — Farming 1
```

The emulator path must control the Android guest directly. Window capture/cropping is not the primary architecture.

## Existing RustDesk seams

### Host and session lifecycle

- `src/core_main.rs::core_main` routes service/server startup.
- `src/server.rs::Server`, `create_tcp_connection`, and `identity_handshake` own host connection establishment.
- `src/server/connection.rs::SessionKey` and `Session` identify controller sessions today, but do not identify a controlled sub-target.

The new design should add target identity alongside the connection/session model without changing the peer identity.

### Media service boundaries

- `src/server/service.rs::Service` / `Subscriber` provide reusable fan-out.
- `src/server/video_service.rs::VideoSource`, `create_capturer`, and the existing `Box<dyn TraitCapturer>` seam already decouple capture from downstream encode/QoS/transport.
- `src/server/audio_service.rs` ultimately emits the existing audio protocol messages, but source selection is more host-specific than video.
- `src/server/input_service.rs` is currently tied to host keyboard/mouse injection and needs an explicit target-specific input sink.

The useful abstraction is therefore above capture/input, not a replacement transport stack.

### Clipboard, Windows service, privileges, privacy, and displays

- Clipboard transport is implemented through the existing clipboard modules and permissions (`src/clipboard.rs`, `src/clipboard_file.rs`, and session permission paths). Emulator clipboard support should reuse that permission model and translate only at the selected target boundary; it must not create a second clipboard authorization system or log clipboard contents.
- Windows service/process boundaries live primarily in `src/platform/windows.rs`, `src/ipc.rs`, `src/server/portable_service.rs`, and server startup. Emulator lifecycle/control must remain inside authenticated RustDesk server/session processes and existing IPC trust boundaries rather than introducing a privileged side channel.
- Desktop privacy mode is separate from ordinary capture/input. Emulator sessions should remain independent of desktop privacy behavior where possible, while preserving Windows lock/session boundaries and never weakening OS security to keep an emulator reachable.
- Display enumeration and monitor selection are desktop concerns in `src/server/display_service.rs` and related option/session handling. Emulator targets should expose guest dimensions/orientation and must not masquerade as synthetic Windows monitors. Physical monitor changes, monitor power-off, desktop privacy mode, Windows lock, minimized/hidden emulator windows, and display reconfiguration belong in the emulator integration matrix.

### Protocol and compatibility

`libs/base/protos/message.proto` already uses additive optional fields and capability negotiation. Existing structures relevant to this work include:

- `LoginRequest`
- `Features`
- `PeerInfo`
- `SupportedEncoding`
- `SupportedDecoding`
- `OptionMessage`
- `Misc`
- `Message`

The compatible direction is:

- optional target capability advertisement
- optional target enumeration/state/lifecycle messages
- optional selected `target_id`
- old clients omit `target_id` and continue to receive the normal desktop
- updated clients connected to old hosts receive no emulator capability and behave exactly as today

Existing version/capability behavior is spread across login/version parsing, `Features`, `PeerInfo`, encoding/decoding capability fields, and option messages. Emulator negotiation should follow the same pattern: advertise support explicitly, keep new fields optional, and gate target-specific messages on negotiated support.

Desktop display selection remains the existing path. Target selection is a separate optional concept so legacy display IDs keep their current meaning. Unknown or unsupported emulator messages must follow the same safe optional-message/version-aware behavior used elsewhere and must never change the active desktop session implicitly.

Protocol extensions belong in `libs/base`; `libs/hbb_common` is a shared submodule and should not be modified for client-only additions without a clear server-wide requirement.

### Flutter/mobile controller

- Rust session creation: `src/flutter.rs::session_add` / `session_start_`
- Rust-to-Dart events: `src/flutter_ffi.rs::EventToUI`
- Dart session model: `flutter/lib/models/model.dart`
- Input model: `flutter/lib/models/input_model.dart`
- Mobile remote page: `flutter/lib/mobile/pages/remote_page.dart`
- Touch gesture path: `flutter/lib/common/widgets/remote_input.dart`

The existing renderer and touch stack can remain the core remote-view UI. Emulator selection, lifecycle, and status sit above session startup; emulator input is routed to a guest input sink on the host.

The Android audit also covers the interaction layers around that page:

- touch/gesture handling and mouse-mode behavior in the remote input widgets/models
- soft-keyboard and hardware-keyboard event paths through the session/input model
- orientation and source-size updates used by renderer/input coordinate transforms
- fullscreen/immersive presentation in the mobile remote page/navigation shell
- Flutter/Android lifecycle handling around pause/resume/reconnect
- responsive layout behavior used by phone and tablet remote pages

The emulator UI should reuse these paths. Target-specific additions are target selection, lifecycle actions/status, guest navigation controls, and guest orientation metadata.

## Proposed target boundary

```text
Authenticated RustDesk connection
          │
          ▼
   RemoteTargetRegistry
          │
          ├── DesktopTarget
          │     ├── normal screen capture
          │     ├── normal audio
          │     └── host input injection
          │
          └── EmulatorTarget
                ├── EmulatorProvider
                ├── guest video source
                ├── guest audio source (when available)
                ├── guest input sink
                └── lifecycle/status/readiness
```

The generic registry owns stable target identity, capabilities, state, and lookup. Provider-specific discovery and lifecycle stay behind provider implementations.

## Provider boundary

V1 providers:

- `LdPlayerProvider`
- `BlueStacksProvider`

Both resolve to the same normalized model and guest session interfaces. Provider code may differ internally for installation discovery, instance metadata, lifecycle, and ADB mapping, but those differences must not leak into protocol, Flutter rendering, video transport, or input transport.

LDPlayer is the first implementation target because the locally installed 9.2.0.1 release exposes dedicated instance-management commands including `list2`, `runninglist`, `isrunning`, lifecycle commands, and instance-scoped ADB support.

## Normalized state

The shared state model must distinguish at least:

```text
Stopped
Starting
Booting
Ready
Connecting
Connected
Stopping
Restarting
AdbOffline
Unresponsive
StreamError
Error
Unknown
```

State derives from multiple signals:

1. provider inventory
2. Windows process state
3. ADB discovery/state
4. Android readiness, including `sys.boot_completed`
5. active video/control channel

A provider process by itself is insufficient evidence of Android readiness.

## ADB boundary

ADB is a local host-to-guest bridge. RustDesk remains the remote network transport.

Requirements:

- bind/use local emulator ADB only
- never expose emulator ADB to the public network as part of this feature
- map endpoints to stable provider instance identity
- handle ADB restart/offline/stale-device cases
- re-resolve mapping after emulator restart or provider port changes
- validate target/provider identifiers before lifecycle or control actions

## Direct guest video

RustDesk already has an encoded H.264/H.265 wire representation:

```text
VideoFrame
  h264s / h265s
    EncodedVideoFrame
      data
      key
      pts
```

The preferred emulator path is:

```text
Android guest encoder
       │
       ▼
guest stream adapter
       │
       ├── normalize Annex-B framing
       ├── cache/inject SPS/PPS or VPS/SPS/PPS
       ├── mark random-access frames correctly
       └── rescale PTS to monotonic milliseconds
       │
       ▼
existing RustDesk VideoFrame transport
       │
       ▼
existing client decode/render path
```

This makes encoded passthrough technically viable and avoids a mandatory Windows decode/re-encode cycle.

The clean integration point is in `src/server/video_service.rs`, beside the existing capture+encoder path and above `send_video_frame`. Codec negotiation must be widened so a codec is eligible when all viewers can decode it and either a RustDesk encoder or the selected direct guest source can provide it.

Refresh/resync must request a guest keyframe plus parameter sets rather than restarting a RustDesk encoder.

For the first prototype, prefer low-latency guest encoding without B-frames.

The existing RustDesk video stack supports VP8/VP9 as well as H.264/H.265. VP8/VP9 continue to use the normal RustDesk capture/encode path; direct emulator passthrough should initially target H.264 and optionally H.265 because Android guest encoders and the current wire packet types map naturally to those codecs.

Hardware acceleration is currently negotiated around RustDesk host encoder/decoder capabilities. Direct guest passthrough changes the source side: codec eligibility should mean every viewer can decode the codec and either a local RustDesk encoder or the selected guest source can supply it. Existing bitrate/FPS QoS (`src/server/video_qos/` and the video service) should remain the viewer-feedback/pacing authority, while the emulator source adapter translates requested bitrate/FPS/keyframe changes into guest-encoder controls where supported.

Android clients already receive codec-specific video frames through the Rust bridge and decoder path. The first implementation should preserve those decoder expectations, including keyframe signalling, monotonic timestamps, codec parameter sets, rotation metadata/state, and recovery after stream discontinuity. Android hardware-decoder optimization can remain a later improvement if the existing decode/render path is functionally correct.

## Direct guest input

The client already converts touch into RustDesk pointer events. On the host, route those events through a target-specific input interface:

```text
client touch/keyboard
      │
      ▼
RustDesk input protocol
      │
      ▼
selected target InputSink
      ├── DesktopInputSink
      └── AndroidGuestInputSink
```

The Android guest sink should use a persistent low-latency control channel when feasible. Repeated `adb shell input ...` process spawning is acceptable for diagnostics/fallbacks, not the normal interactive path.

Coordinate conversion belongs in shared target/session code and must account for viewport, letterboxing, source dimensions, and rotation before guest injection.

## Windows service and privacy behavior

RustDesk's Windows service launches per-session server processes and communicates over existing IPC. Emulator control should stay within those authenticated server/session boundaries.

Desktop privacy mode remains desktop-specific. Emulator guest sessions should not weaken Windows lock/privacy/security behavior. The eventual integration test matrix must explicitly cover minimized/hidden emulator windows, physical monitor changes, desktop privacy mode, and a locked Windows session.

## Testing seams

Existing useful test surfaces include:

- session/security: `src/server/connection.rs`
- display: `src/server/display_service.rs`
- input: `src/server/input_service.rs`
- audio: `src/server/audio_service.rs`
- IPC: `src/ipc.rs`
- Windows service helpers: `src/platform/windows.rs`
- video QoS: `src/server/video_qos/`
- lower-level capture: `libs/scrap/`
- Flutter tests: `flutter/test/`

Phase A test-location audit:

- Rust unit tests: inline `#[cfg(test)]` modules across `src/` plus subsystem tests such as `src/server/video_qos/tests/`
- protocol tests: compatibility assertions live with protocol/session code in `libs/base` and `src/server/connection.rs`; new target negotiation tests should be added beside those seams
- integration-style tests: networking/session/port-forward/server tests in `src/client.rs`, `src/server/connection.rs`, `src/server/port_forward_mux.rs`, `src/rendezvous_mediator.rs`, and related modules
- Flutter tests: `flutter/test/`
- Android-specific validation: Flutter/mobile tests plus the Android matrix in `.github/workflows/flutter-build.yml`; emulator/device behavior will need targeted integration coverage because there is no comprehensive dedicated Android instrumentation suite for this feature
- Windows-specific tests: `src/platform/windows.rs`, `src/ipc.rs`, `src/server/portable_service.rs`, privacy/input areas, plus the Windows build matrix in `.github/workflows/flutter-build.yml`
- CI pipelines: `.github/workflows/flutter-build.yml`, `.github/workflows/flutter-ci.yml`, and `.github/workflows/bridge.yml`

New shared target/provider logic should be isolated enough for deterministic unit tests without requiring an installed emulator.

## Maintenance direction

Keep the fork mergeable by isolating emulator support in new modules and small integration seams. Avoid provider-name conditionals in generic RustDesk code.

Expected upstream synchronization:

```powershell
git fetch upstream
git switch master
git merge --ff-only upstream/master
git push origin master
git switch feature/android-emulator-remote
git rebase master
```

Feature work should remain on `feature/android-emulator-remote`.
