# Pointer-free touch control for the phone's Windows view — 2026-10-25

## Request

The phone's Windows remote view felt clunky (mouse, keyboard, toolbar, zoom/pan). The user asked for no steerable mouse pointer: touch where you want, pinch to zoom. Two-finger drag pans when zoomed and scrolls at Fit. The trackpad-style Mouse mode is removed entirely.

## Changes (Flutter only; no Rust, native DLL or service change)

- `flutter/lib/mobile/widgets/monitor_control_view.dart`: the touch handling now runs on a raw `Listener`.
  - Tap clicks at the finger. A second quick tap reuses the first position, because Windows only counts a double-click within a few pixels.
  - A one-finger drag holds the left button. Touch-and-hold or a two-finger tap right-clicks.
  - Pinch zooms and pans together. A two-finger drag pans when zoomed and scrolls when not. Fingers report one at a time, so the gesture is classified from each finger's own movement.
  - Scrolling on Windows hosts is pixel-smooth with momentum; other hosts fall back to whole notches (18 px each).
  - The thumbwheel appears automatically when zoomed. The minimap is kept.
  - Taps in the black bars are ignored. A touch ring shows where the finger is.
  - Removed: Mouse mode, the cursor overlay, Precision, cursor offset, double-tap-hold, drag lock, the floating mouse buttons, and the Input/Display panels.
  - New Controls panel: a labelled grid with right- and middle-click for the next tap, zoom, orientation, scroll wheel, view only, dock side, Ctrl+Alt+Del, Gestures and Reset.
  - Old saved preferences parse safely, and the retired keys are ignored.
- `flutter/lib/mobile/widgets/monitor_live_keyboard.dart` (new): live typing. A hidden field is diffed against a sentinel, so the phone keyboard types into Windows as you go.
  - The extra-keys bar replaces the bottom toolbar while typing. It has Esc and Tab; sticky Ctrl/Alt/Shift/Win (tap once for the next key, twice to lock); arrows and Del with auto-repeat; Home, End, PgUp and PgDn; F1–F12 behind Fn; the user's shortcut presets; and Compose, which opens the existing type-then-Send sheet.
  - Hardware and IME key events are kept from reaching the session's KeyboardListener a second time.
- `flutter/lib/mobile/pages/target_dashboard_page.dart`: pointer moves and wheel bursts are coalesced in the input queue, latest wins, and close when any other action is queued.
  - Smooth scroll uses the existing `trackpad` wheel message, which Windows applies in raw WHEEL_DELTA units. Windows peers only.
  - Live typing uses `sessionInputString`, a 12 ms key tap (`tapHidKey` holds the queue for 100 ms), and the existing held-key tracking, so release-on-exit still works.
  - The soft keyboard is toggled through the existing `enable_soft_keyboard` method.

Pre-change copies of the three edited files are in `target/remote-input-20261025/before/`.

## Validation

No Flutter/Dart SDK was reachable from the agent environments, so **no analyzer, test or build was run**. All changed Dart files parse cleanly with the tree-sitter Dart grammar, as do the originals. Every private identifier resolves to a declaration.

Tests were rewritten or added: `flutter/test/monitor_control_view_test.dart` (touch behaviour; the MonitorKeyboardPanel tests are kept verbatim) and `flutter/test/monitor_live_keyboard_test.dart`. To run them:

    cd flutter
    flutter analyze --no-pub lib/mobile/widgets/monitor_control_view.dart lib/mobile/widgets/monitor_live_keyboard.dart lib/mobile/pages/target_dashboard_page.dart
    flutter test test/monitor_control_view_test.dart test/monitor_live_keyboard_test.dart test/target_dashboard_test.dart

Not built, signed or installed. Phone behaviour is unverified: IME diffing across Gboard/Samsung keyboards, smooth-scroll feel, and gesture thresholds.

## Later the same session

- Ran on Atlas with Flutter 3.24.5: `flutter analyze` reported no issues, and 79 tests passed across the monitor view, live keyboard, target dashboard, theme and emulator input suites.
- Fixed two Settings problems found in the installed window: buttons, checkboxes and radios now use Aperture cobalt (`aperture_settings_frame.dart`), and the About card is restyled and titled About Aperture (`desktop_setting_page.dart`). The RustDesk copyright and licence text are kept.
  - Settings frame tests pass, the analyzer shows only pre-existing info-level notes, and the Windows release build succeeded.
  - Installed `app.so` A06C0417…7197602 with user UAC approval. The receipt is `target/settings-polish-20261025/installation-result.json`: native DLL unchanged, service Running before and after. A backup of the previous `app.so` (BDD04591…) is in `installed-backup/`. The installed window was checked visually.
- Phone APK: `tools/aperture-release.json` is bumped to 1.5.3/4106 (the earlier 1.5.2/4105 build was never installed and has different contents). The signed build stopped before compiling because `%LOCALAPPDATA%/Aperture/signing/aperture-release-certificate.pem` is missing on this Windows account. The release key and DPAPI password may also be unusable here. Nothing was built or installed on the phone.
- Phone: Aperture Test (side-by-side ID `com.carriez.flutter_hbb.aperturetest`, local debug-key signature) built with `-PapertureSideBySide=true` and installed on the SM-S938W over paired wireless adb; the release-signed `mirpgtest` app was left untouched. The APK is published as GitHub prerelease `aperture-test-touch-20261025` on StruttinSoul/rustdesk, using the user's gh login with their approval.
- User request: drag should move the screen, like OSLink. One-finger drag now pans the view. Touch-and-hold, then drag, holds the left button; touch-and-hold, then lift, right-clicks. A two-finger drag always scrolls. The thumbwheel shows only when turned on. Analyze is clean and 69 tests pass. The rebuilt APK (SHA-256 98838fb6…344d49f3) is installed on the phone and has replaced the release asset.
