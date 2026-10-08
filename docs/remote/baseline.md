# MIRPG Remote WP0 Baseline

Generated 2026-10-05 America/Vancouver. WP0 records evidence only and does not change application behavior.

## Repository snapshot

- Repository: C:\Programming Projects\MIRPG\rustdesk-emulator-remote
- Branch: feature/android-emulator-remote
- HEAD: 59221185a99cf555fcee552114fb5589c66a15b8
- Upstream: origin/feature/android-emulator-remote; ahead by 9 at inventory.
- Origin: https://github.com/StruttinSoul/rustdesk.git
- Audited handoff commit: 448501369ae567677091fe37615f0a5c499f5094
- Current inventory before WP0 docs: 15 modified tracked files, no untracked files, no active Cargo/Flutter/Gradle build.
- No modified file was reset, stashed, cleaned or overwritten.
- git diff 448501...HEAD changes 17 committed paths with 4009 insertions and 331 deletions.
- src/common.rs, src/kcp_stream.rs and src/rendezvous_mediator.rs have no diff from the audited handoff commit.

### Preserved dirty-work SHA-256

flutter/lib/mobile/pages/connection_page.dart 596EE00DEC6464CFBF35FCA4CDB262380252FA3A303B9CD2398B77E4B788F4BE
flutter/lib/mobile/pages/emulator_page.dart 4CEB981C227E1B91741A977198C31A3AB3DEA821BD858B26475DD80ADFABA04C
flutter/lib/mobile/pages/file_manager_page.dart DD93C230506128AC37A87B3302455CBD6653EE57671B3AFD264266A8FB152535
flutter/lib/mobile/pages/home_page.dart F62B34685F79476D40310B896C7F87D95E82E09548C0BF157C65198124D21716
flutter/lib/mobile/pages/host_management_page.dart ED6C30BA1CD06986066CEEB3A392461EFB30F13801347F836D83E406782370AE
flutter/lib/mobile/pages/target_dashboard_page.dart 9722B300CEB49620FAA070E69A8D159637B82460B7D2B25DB17EF7BC2FD08F39
flutter/lib/mobile/pages/terminal_page.dart B4D07390E5FBE975D3CBB91EFF87A736428990A06698D8A85CB4BC2891887FD6
flutter/lib/mobile/widgets/mirpg_remote_theme.dart AA35BDB4CB13EFF9D572F53820A4D1B3592ACD1159D70645B95805BFD06D80A7
flutter/lib/mobile/widgets/session_quality_panel.dart 82B82197355427492714523DDC3EE854773FDF8F0A208C4F2ED7259551AA1829
flutter/test/codex_model_test.dart 3E9905E464C6DC0DE17DCA38557EA8965C887C8DC17F4CAEA6A9265ABD9615F9
flutter/test/codex_page_test.dart C0900B9A417A31624B6DAFF2BAD328F350A6CB5BFF3B9B28F0F93EDA70B79EB2
flutter/test/mirpg_remote_theme_test.dart CD3E6E53CFF8E309A0667BA2120AB623B46A33B50C40E31BCFCE66DA0F985F99
flutter/test/target_dashboard_test.dart 9544DA676A7685B0E059C1F1ECCB493A1034719DC1E7044C2072125C2D1318EE
src/client/emulator.rs EC56940A92FD065AFB5857F12BF40E6A95809252BF66F76C453747E760C00F2D
src/client/io_loop.rs 2355ADF531F377C11722EB95986A7DBF756A57997EE4198900869D0F2F81EAF2

The dirty Codex model/page tests preserve the test-first fix for the misleading Resume state. The dirty BlueStacks decoder work is also preserved. Its three focused guest_video regressions passed previously; a new Android native build is still required before that Rust change reaches the phone.

## References

Located: completion plan, original CODEX_HANDOFF, MIRPG-Remote-Visual-Kit.zip, and its 40-state screen-index.

Not found anywhere under the authorized C:\Programming Projects\MIRPG project/attachment tree:
- rustdesk-audit-matrix.json
- CODEX_GATEWAY_MANAGEMENT.md
- CODEX_GATEWAY_PROVIDER_PLAN.md

No missing-file content is invented. The completion plan standalone interaction contract remains authoritative and Gateway stays mandatory.

## Toolchain and commands

Observed locally:
- rustc 1.75.0
- cargo 1.75.0
- Java 21.0.12
- C:\LLVM-15.0.6\bin\libclang.dll present
- Android NDK 28.2.13676358 present
- flutter\android\local.properties points to C:\flutter-3.24.5; Flutter is not on this shell PATH.
- Feature CI pins Rust 1.75, Flutter 3.24.5, LLVM 15.0.6, cargo-ndk 3.1.2, NDK r28c and vcpkg commit 9e593bb18ea69cc5095e012465dcd675a822ed0d.

Rust test environment:
    $env:VCPKG_ROOT='C:\vcpkg'
    $env:LIBCLANG_PATH='C:\LLVM-15.0.6\bin'

Focused guest-video:
    cargo test --lib guest_video_ -- --nocapture

Historical failure reproduction:
    cargo test --lib EXACT_TEST -- --nocapture --test-threads=1

Focused Flutter CI set:
    cd flutter
    C:\flutter-3.24.5\bin\flutter.bat pub get
    C:\flutter-3.24.5\bin\flutter.bat test test/target_dashboard_test.dart test/emulator_model_test.dart test/monitor_control_view_test.dart test/codex_page_test.dart test/bluestacks_model_test.dart

Windows feature build:
    python3 .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
    .\tools\prepare_guest_helper.ps1 -DestinationDirectory .\MIRPG-Remote-Windows-x64

Android CI path:
    ./flutter/build_android_deps.sh arm64-v8a
    ./flutter/ndk_arm64.sh
    copy target/aarch64-linux-android/release/liblibrustdesk.so to flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
    flutter build apk --release --target-platform android-arm64 --split-per-abi

Previously used local native command:
    cargo ndk --platform 21 --target aarch64-linux-android build --locked --release --features flutter,hwcodec

The previous native build was user-aborted; artifacts must be revalidated before packaging.

## Five historical Rust failures

1. common::tests::test_secure_tcp_rejects_unverified_versions_before_reply
   Reproduced: replied to missing_signature, required=false.
   Classification: pre-existing test-harness false positive at the assertion boundary. Production key_exchange rejects the missing signed parameters before constructing/sending its key exchange. The test equates next_timeout(...).is_none() with no reply even though Stream::next_timeout returns Option<Result>; a connection close/error is Some(Err) and is counted as a reply.

2. rendezvous_mediator::tests::a_declined_udp_punch_still_replies
   Reproduced: timeout waiting for the hbbs reply.
   Classification: pre-existing UDP helper/test-path defect, not a general UDP prerequisite failure. Plain UDP loopback passes. The failing path is new_direct_udp_for plus the UDP-only test endpoint; no relevant source changed since the audited commit. The exact helper path remains the defect boundary rather than being mislabeled as a LAN outage or current regression.

3. kcp_stream::tests::test_kcp_io_treats_socket_errors_as_loss
4. kcp_stream::tests::test_kcp_stream_close_delivers_all_frames
5. kcp_stream::tests::test_kcp_stream_loopback_roundtrip_and_close
   Reproduced: each fails in establish() with connect over loopback: Connect timeout.
   Classification: pre-existing RustDesk KcpStream socket-pump/integration handshake defect on this Windows baseline. Plain UDP and connected-UDP loopback pass. The pinned kcp-sys direct endpoint test endpoint::tests::test_peer_silent_for_stays_fresh_while_idle passes with LIBCLANG_PATH configured. These three product tests fail before their test-specific assertions.

The first direct kcp-sys build attempt without LIBCLANG_PATH failed in bindgen discovery; that was an environment prerequisite for the dependency checkout, not one of the five product baseline failures.

Pre-existing means not introduced by the current MIRPG redesign/latency work; these failures remain tracked defects.

## Source/test map

- App shell: connection_page.dart, home_page.dart, target_dashboard_page.dart, mirpg_remote_theme.dart; home_page_shell_test, theme test, dashboard test.
- Windows view/input: monitor_control_view.dart, monitor_session_continuity.dart, target_dashboard_page.dart; monitor_control_view_test and dashboard tests.
- Quality: session_quality_panel.dart and continuity model; quality_monitor_transport_test.
- BlueStacks: emulator_page/model, bluestacks_model, src/client/emulator.rs, src/server/emulator; emulator/bluestacks model tests and Rust guest_video tests.
- System: host_management_page/model and server host_management seam; WP8 freshness/process tests required.
- Files: file_manager_page plus inherited transfer machinery; WP7 tests required.
- Shell: terminal page/model/service/helper and existing terminal tests; WP6 safe-paste tests required.
- Codex: codex page/model and src/server/codex; Flutter and Rust Codex tests, with WP3/WP4 acknowledgment/ownership/approval work remaining.
- Clipboard: src/clipboard.rs and server clipboard service; WP6 directional clipboard work remaining.
- Window picker: Windows platform seam exists; dedicated typed route remains unverified for WP9.
- Privacy: privacy_mode and Windows platform seams; WP11 capability/ack/recovery work remains.
- Phone Workspace: virtual_display_manager and display_service candidates; WP10 owned lifecycle remains unverified.
- Gateway: no RustDesk integration found; WP15 must inspect and reuse C:\Users\gregr\MarqueeGatewayRuntime.

Ledger status partial_candidate means useful machinery exists but the full placement, gesture, state, accessibility, failure and recovery gate has not passed. No row is marked complete from source presence alone.
