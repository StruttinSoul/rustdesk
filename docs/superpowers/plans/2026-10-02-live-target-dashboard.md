# Live Target Dashboard Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Execution remains inline without agents at the user's explicit request.

**Goal:** Live BlueStacks and PC monitor cards, authenticated startup reconnection, and fullscreen target switching with controls outside the image.

**Architecture:** Extend the existing emulator messages with bounded preview subscriptions and preview status metadata. Connection-owned guest previews coexist with desktop capture; target-keyed client image slots feed the dashboard and chooser. Ordinary sessions retain their existing paths.

**Tech Stack:** Rust, additive protobuf messages, Flutter/Dart, existing scrcpy helper and RustDesk monitor capture.

**Spec:** `docs/superpowers/specs/2026-10-02-live-target-dashboard-design.md`

## Global Constraints

- No BlueStacks/game binary changes, security weakening, or shared ADB server shutdown.
- Inline work; no agents or further design approval prompts, per user instruction.
- Preserve existing edits and feature-off behavior; keep shared hooks thin.
- Real video previews, four exposed preview cards initially, selected full-quality stream.
- Authentication and current input permissions remain authoritative; preview streams are view-only.
- Public publishing is outside this implementation; produce matching local artifacts.

## Review Focus

- Late frames/status after switching must not repaint the new target.
- Preview enumeration must never boot stopped instances or grant input.
- Monitor input must retain each display's global coordinates after guest switching.
- Route creation after authentication must occur once, and failed reconnect must remain cancellable.
- Background/closed dashboard must release preview capture and image resources.

### Task 1: Preview protocol and host lifecycle

**Files:** `libs/base/protos/message.proto`, `src/client/emulator_protocol.rs`, `src/server/emulator/{remote,connection,remote_windows,guest_runtime}.rs`, thin hooks in `src/server/connection.rs`.

**Interfaces:** `EmulatorPreviewRequest { enabled, target_ids, displays }`; status `preview`; inventory `dashboard`; `GuestSession::start_preview`; `GuestHelper::connect_preview`; bounded connection-owned preview map.

- [x] Add/run failing typed subscription authorization test: view-only authenticated requests accepted; unknown provider and oversized lists rejected. Existing authorization checks still reject preview input.
- [x] Implement additive protocol parsing, capability advertisement, owned 360p/6 FPS preview helpers, lifecycle cleanup, and concurrent monitor subscription handling.
- [x] Verify focused Windows Rust emulator tests, including existing decoder/capture tests.

### Task 2: Independent client decoders and images

**Files:** `src/client/{emulator,io_loop}.rs`, `src/flutter.rs`, `flutter/lib/models/{emulator_model,model}.dart`.

**Interfaces:** Preview statuses indexed by target/session; `EmulatorModel.setPreviews`, `previewForChannel`, `dashboardActive`; dashboard images keyed by video channel/display.

- [x] Add/run failing Flutter model tests: independent preview statuses, stale closed preview ignored, desktop return retains dashboard inventory.
- [x] Route each preview to a bounded decoder/image slot, preserve legacy selected decoder, and allow monitor frames only while dashboard is enabled.
- [x] Run focused Rust/Flutter tests and analyze touched Dart files.

### Task 3: Dashboard, rails, and startup

**Files:** new `flutter/lib/mobile/pages/target_dashboard_page.dart`; `emulator_page.dart`, `remote_page.dart`, `home_page.dart`; focused dashboard widget/model tests.

**Interfaces:** Authenticated remote page opens dashboard once; dashboard chooses guest or display; left chooser remains in session; guest page uses reserved side rails.

- [x] Verify selected routing and fitted touch bounds in model tests; add Boot-action and compact-card widget tests. Review BlueStacks-only filtering inline.
- [x] Build live cards, explicit Boot/Open, target chooser, monitor input with existing session input APIs, orientation/insets, preview pause/cleanup, Direct/Relay label, last-PC reconnect.
- [x] Verify Flutter tests/analyzer, build Windows/Android artifacts, inspect the final change surface and correct in-scope defects.

### Task 4: Delivery and runtime checks

- [x] Back up and update the local host artifact only after successful builds.
- [x] Build a signed test-upgrade APK and matching source archive with checksums.
- [x] Install to the previously authorized phone if its ADB endpoint remains available; otherwise preserve the APK and report the exact missing connection information.
- [x] Record host/phone checks and remaining unverified cases; no unsupported completion claims.

## Execution ledger

2026-10-02: User approved the written-spec continuation and explicitly instructed no further approval prompts. Work stays in the existing feature checkout because prior uncommitted integration and working build caches are required. No agents or unrelated changes are included. Review is performed inline under the user's no-agent instruction. Product code commits will not sweep the pre-existing uncommitted work into new commits.

Verification: 88 focused Rust emulator tests passed (8 ignored), plus the new native frame-buffer lifetime regression. Twelve Flutter model/widget tests passed. Analysis of six touched Dart files reports only 13 existing informational diagnostics. Inline inspection corrected late retained-preview statuses, compact-card overflow, published-buffer lifetime, saved monitor restore interference, monitor updates during guest viewing, removed-monitor orientation bounds, and view-only input guards.

Delivery uses an optimized release APK signed with the existing test identity through the explicit mirpgTestApk build option. Ordinary production release signing is preserved. The user supplied the new phone connection endpoint 10.0.4.60:42111; pairing is already valid.

Build/delivery evidence: Windows and Android native release builds passed; the updated Windows library loads and is deployed with a verified backup at `%LOCALAPPDATA%/MIRPG/host-backups/live-dashboard-4cf30d19a8b2483a956ced4f1c51ed79`. Host ID remains 373491561. Both running BlueStacks endpoints produced 89 H.264 packets at 360x202 in concurrent view-only probes; the owned helpers removed their forwards afterward. The optimized ARM64 APK has version code 2070, matches the installed test signing certificate, and contains the exact newly built native library. Gradle release build passed. Temporary dependency patches and local.properties were restored.

Artifacts: `C:/Users/gregr/Downloads/MIRPG-Remote-live-dashboard-test-2026-10-02/`, containing the APK, matching 1,002-file source archive, and SHA256SUMS.txt. APK SHA256: `e09ca9d16341cce0712c15247d0978a683972c54d3312debfea00bf3bc9e80a4`. Source SHA256: `ad10cc5680056103508b8195920a6c86517397a3b172f378b47eb2ad8eee9dd4`.

Samsung's AppVerificationDialog delayed the fully uploaded installation. Verification subsequently completed and ADB reported Success; installed version 2070 was confirmed. No security settings were changed. The app launched without matched crash/decode errors, reconnected and authenticated to jarvis, and displayed both BlueStacks cards plus a live Windows-monitor card. The Direct label is confirmed by the host's established TCP connection from 10.0.4.93 to 10.0.4.60. A later phone capture shows fullscreen MapleStory in landscape with the left switcher/dashboard controls and right Back/Home/Recents rail outside the game. Remaining physical checks are switching through every monitor/guest, monitor hotplug, stopped-instance Boot, background cleanup under prolonged use, and long-session latency/stability; the implemented mechanisms and focused tests do not imply those unobserved scenarios were tested.

Regression-surface audit (inline review, no agents): existing shared files touched are message.proto (additive capability/subscription fields), server/connection.rs (connection-owned preview state and thin stream/PeerInfo exceptions), client/io_loop.rs (owned preview decoder state), flutter.rs (serialization and safe pixel-buffer lifetime), model.dart (independent dashboard images, authenticated-peer state, saved-monitor guard), mobile remote_page.dart/home_page.dart (authenticated dashboard route and one-shot last-PC reconnect), and Android app/build.gradle (explicit test-only release signing). Existing emulator feature modules received their preview/control/UI implementation. No changes were made to BlueStacks binaries, cleanup policy, Codex bridge, ordinary production signing, or unrelated pre-existing edits in this task. Ordinary unsupported-host and non-dashboard session paths keep their existing guards.
