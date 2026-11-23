# Android guest lag — 2026-10-15

## Confirmed behavior and cause

On Galaxy SM-S938W, MIRPG test2095 repeatedly stalled while controlling BlueStacks App Player3. The guest helper was already using its active1280px,30 FPS,4Mbps profile. The3 FPS preview mode was not responsible.

Phone logs repeatedly recreated H264 decoders. Protected Windows service logs showed guest transport queue saturation predominantly every10 seconds. TargetDashboardPage refreshed inventory every10 seconds even in fullscreen. On the host, on_emulator_request awaited the blocking inventory job inside the same connection loop that drains guest video events. The host event channel held only two events, so discovery interrupted delivery and triggered keyframe recovery.

## Phone correction: installed test2096

Periodic inventory now runs only outside fullscreen or while the target chooser is open. Initial discovery, dashboard/chooser polling, reconnect handling, stream recovery, input mapping and background presentation pacing retain their existing behavior. Only target_dashboard_page.dart changed between installed2095 and2096.

73 existing dashboard, pacing and monitor widget tests passed. Focused Dart analysis found no issues. Initial packageRelease failed without a detailed cause; retry with stacktrace succeeded. local.properties restored byte-for-byte. Release signing identity matches2095;16KB alignment passed; native JNI hash remains F3AA44D1238C704648B01EC12F496753F1256DF666568EEEDE6194F3F770CB00.

User explicitly approved installation/testing. Installed4096/1.5.0-test2096 and verified pulled installed APK SHA256:8BA997E722F3121546285CB2A17CDADF0955E16FB54EFC110237E7A0CAC281CB. Artifact/provenance: target/lag-local-20261015/. Saved direct Jarvis connection retained. Chooser open/return exercised; guest continued rendering.

## Measurements and limits

| Sample | Source game median / p95 / max | Phone compositor median / p95 / max |
|---|---|---|
|2095, about18–20s|16.67 /33.33 /83.33ms|33.29 /66.58 /532.72ms|
|2096,38.28s|16.67 /50 /150ms|33.29 /91.54 /274.63ms|

Compositor timestamps include UI activity, not just decoded video. The game load changed between samples; these are observations, not a controlled FPS improvement comparison. Phone H264 decoder creation count remained5 before/after the38.28s2096 sample. Later host saturation at00:54:03 and00:55:04 establishes residual burst sensitivity. Phone thread snapshot did not show a saturated decoder/UI core. LAN ping:25/25 replies,0% loss,3.695/6.047/10.118ms min/avg/max; this is network RTT, not input-to-picture latency.

A later pre-install sample named test2095 recorded a transition to the phone home screen and is invalid for video performance. Do not use its120 FPS result. Temporary raw logs and screenshots contain user content and remain outside tracked docs. Relevant files: %TEMP%/mirpg-lag-baseline-stats.json, mirpg-lag-test2096-stats.json, mirpg-lag-host-summary.txt, mirpg-lag-{phone,test2096-start,test2096-end}.log. Repeatable capture script: target/lag-local-20261015/measure-cadence.ps1; verify guest view before/after every run. Do not benchmark while compiling native code.

## Native burst correction — installed and live-checked

The original two-slot channel cannot preserve a six-frame burst representing200ms of30 FPS scheduling jitter. New regression exercises the real GuestFrameBackpressure::deliver path and verifies every frame remains ordered without encoder reset. It failed at the original capacity with: A short frame burst must not reset the guest encoder.

Production change increases bounded host event capacity to8, matching the existing client burst budget. Shared constant in src/server/emulator/remote.rs; channel uses it in src/server/connection.rs; regression in remote_windows.rs. Existing sustained-overflow keyframe recovery is unchanged. No new protocol, logging, dependency or guest-game changes.

Native verification: green burst regression passed, existing host overflow recovery passed, four client guest_video_ tests passed (six total). Green test compile2m11s. Normal optimized release DLL built4m26s; target/lag-host-local-20261015/windows/librustdesk.dll, SHA256 B98AF5540E0D82912F7137999ED827506EBB8748F9B7BB7C06D3E3AAB68C4802. Provenance in adjacent manifest.json. Log %TEMP%/mirpg-lag-windows-native.log. User explicitly approved updating the running host and testing. Updater scaffold target/lag-host-local-20261015/deployment/update-host.ps1 uses the existing full-backup/rollback procedure, copies only the native DLL and leaves RuntimeBroker helper alone; source manifest/DLL hashes, installed pre-update DLL hash and service path validated. Host deployed2026-10-15T08:24:39Z. Installed DLL SHA256 matches staged build; service Running/Automatic, PID42152. Full previous runtime backup: %LOCALAPPDATA%/MIRPG/host-backups/lag-host-20261015-2e3e7434b9114aeeb6eb887b8fbfe6f0; backup DLL hash matches previous5716B06856066D2BFDA72735B59AFB03596EE855A90131601E2F231D1ED84753. All22 recorded source hashes still match. Post-host live checks completed06:56-07:06 using the newly supplied Galaxy endpoint<lan-ip>:42385. Direct Jarvis connection restored, Player3 booted through MIRPG, Windows view and return to Android passed. Detailed motion results below. No further deployment was performed.

Avoid fully optimized release unit-test builds (historically27m57s). Focused tests reuse release dependencies with --config profile.release.package.rustdesk.opt-level=0 --config profile.release.package.rustdesk.codegen-units=16; red build took2m16s. These overrides must not be used for deployable DLL. Use features flutter,hwcodec,vram, VCPKG_ROOT=%LOCALAPPDATA%/MIRPG/windows-cache-sdk and LIBCLANG_PATH=C:/vcpkg/downloads/tools/clang/clang-15.0.6/bin. No worktree/history changes. Before-copies: %TEMP%/mirpg-lag-20261015-before/.
## Final live acceptance, 06:56–07:06 America/Vancouver

Reconnected Galaxy SM-S938W at<lan-ip>:42385; installed4096/test2096 confirmed. Host DLL still B98AF5540E0D82912F7137999ED827506EBB8748F9B7BB7C06D3E3AAB68C4802, service Running/Automatic. BlueStacks3 had stopped; booted through MIRPG. Windows was locked; its lock-screen image streamed successfully without entering credentials. Player3 game required sign-in, so no account, consent or game actions were taken. Used Android Settings app list for reversible scrolling; no settings were changed.

The final source-correlated sample lasted24.5 seconds on the phone:735 compositor frames,29.96 FPS, median33.29ms, p95 41.62ms, maximum166.45ms; four intervals exceeded100ms. Guest source:58.02 FPS, median/p95 16.67ms, one783ms maximum gap. Samples overlap but are not aligned input-to-picture measurements. Phone H264 decoder creation count remained2 throughout motion tests; filtered host logs had no new guest transport saturation/decode/input/session warnings since reconnect. Planned decoder starts during later target changes are expected and excluded from recovery counts.

Windows→Player3 switching passed; Windows full-height side controls and Android whole-image fit retained. A phone direct-touch swipe moved the Android list after return. No native builds ran during these measurements. Artifact manifests record acceptance and the precise statistics. Raw screenshots/logs remain temporary.

Diagnostic limits: the first short Settings page mostly stopped redrawing and cannot establish steady FPS. A later app-list phone-only sample was valid but its guest counter was missing because the shell expanded the dollar sign in Settings$ManageApplicationsActivity. Corrected escaping, verified nonzero source timestamps, and repeated the final correlated sample. The script's foreground check also uses dumpsys window (the windows-only subcommand omitted mCurrentFocus on this phone). Keep these corrections in target/lag-local-20261015/measure-cadence.ps1.

Remaining limits: source/game workload differs from earlier2095, so no controlled improvement percentage or input latency claim. Gameplay benchmark still needs the user's game sign-in. Static guest pages can trigger the existing four-second waiting-for-live-frame input guard because the source stops emitting unchanged images; this predates these two fixes and was not weakened. That liveness behavior is a separate reliability follow-up, not evidence of a new queue overflow.