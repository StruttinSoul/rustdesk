# Aperture UI Phase 2: one theme, one shell (phone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the Studio theme once at the phone app root and give the phone one shell: connected tabs Play / Screens / PC (the PC tab absorbs the session menu and ends the session), a monitors-only Screens tab, a monitor view without its top bar, a Computers page that is a single atlas hero card, Chat reached from Share, and Settings regrouped without losing a row.

**Architecture:** The Studio palette, theme builder and shared widgets move to `flutter/lib/common/widgets/studio_theme.dart` (the mobile file re-exports it) and `main.dart` applies them at the root for Android/iOS only; desktop keeps `MyTheme`. New stateless widgets (`PcTabBody`, `ScreensTabBody`, `TargetSwitcherGrid`, `ComputerHeroCard`, `AddComputerSection`, `ShareChatButton`, trust sheet) and pure helpers (`ConnectAttemptTracker`, `buildMobileSettingsSections`, `mobileRootTabs`, `shouldOfferPairing`) take strings through an injected `tr` so tests pump them without the native bridge; pages wire them. The RustDesk connect, password and 2FA dialog chain is not replaced. No protocol, Rust or package changes.

**Tech Stack:** Flutter 3.24.5 (Dart 3.5), Material 3 Studio theme, `settings_ui` 2.x (existing), `flutter_test`. Lang keys in `src/lang/*.rs` (data only).

**Spec:** `docs/superpowers/specs/2026-11-16-aperture-ui-redesign.md` (§1 navigation model, §3.1, §3.5, §3.7, §3.8, §4, §5 Phase 2, §7 Q2/Q7). Visual reference: `docs/superpowers/specs/mockups/2026-11-16-aperture-ui-redesign.html` frames 2a, 2b, 2c. Conventions follow `docs/superpowers/plans/2026-11-16-aperture-ui-phase1.md`.

## Global Constraints

- Work only in `flutter/lib/main.dart`, `flutter/lib/common/widgets/studio_theme.dart` (new), `flutter/lib/mobile/`, `flutter/lib/models/emulator_model.dart` (`listError` only, Task 5), `flutter/lib/models/model.dart` (`FfiModel.lastConnectionError` only, Task 7), `flutter/lib/models/chat_model.dart` (one navigation-bar check, Task 8), `flutter/test/`, `src/lang/*.rs` (keys only, Task 10) and `tools/aperture-release.json` (Task 10). No Rust logic, no `libs/hbb_common` change, no new pubspec dependency, no wire-protocol change.
- **Desktop is untouched:** `apertureAppTheme(..., mobile: false)` returns `MyTheme.lightTheme`/`darkTheme` unchanged (identical object); desktop widgets that duplicate Studio hex values are Phase 3.
- Tests: run from `flutter/` with `C:/DevTools/flutter-3.24.5/bin/flutter.bat test <file>` (on PATH as `flutter`). Analyzer: `flutter analyze <touched files>` adds no new issues. Step 0 of Task 1 records the suite baseline (Phase 1 ended at 525/0).
- **Strings:** every new or reworded user-visible string goes through translate. Widgets that tests pump take `final String Function(String) tr` defaulting to the global `translate`; tests pass `tr: fakeTr` (`flutter/test/support/fake_translate.dart`). Keys are sentence case and are the English text; one `{}` placeholder per string, written `tr('Couldn\'t connect to {$name}')`. PC/emulator names and PC messages are never keys. Exception, stated once: RustDesk msgbox texts shown on the hero card are already translate keys and are passed through `tr`, exactly as `msgBox` does.
- Keys are added once, in Task 10, per `docs/agents/LOCALIZATION.md`: append to `template.rs` and every `src/lang/*.rs` with `""`; `it.rs` always `""`; no `en.rs` entry when key == English; skip keys already in `template.rs`.
- Vocabulary (spec §3.1): Emulator; Start; Open; Stop; Reconnect (replaces "Retry preview"); Show on PC / Hide on PC; states Live, Starting, Stopped, Stopping, Copying n%, Problem; tabs **Play**, **Screens**, **PC** (replaces Tools). "Dashboard", "Targets", "Attention", "Needs attention", "Connecting" (as a monitor state) leave the phone UI.
- Studio values: 8 dp rhythm, 16 dp page margin, radii 12/16/24, min touch target 48 dp; over video always the dark palette (`MirpgStudioPalette.dark`); names `titleMedium`, state `labelMedium` w600, never below 12 sp; destructive `MirpgRemoteTheme.destructiveFill` / `palette.error` text.
- Decisions binding from spec §7: **Q2** press back twice to leave a game (unchanged, game only; the monitor view keeps single back to its tab); **Q7** the phone connects only to atlas: Computers is one hero card for the last-used PC, no list and no "Other computers"; the ID field sits under a collapsed "Add another computer".
- **Connect flow:** the Computers page only ever calls the existing `connect(context, id)`. It never calls `gFFI.start`, never suppresses `dialogManager.showLoading`, and never replaces `enterPasswordDialog`, `wrongPasswordDialog`, `enter2FaDialog`, `showWaitAcceptDialog` or `msgBox`. Those dialogs keep their behaviour and pick up the root theme.
- **End session stays reachable after every task:** Task 3 adds it to the PC tab in the same commit that removes the app-bar "⋮"; no task removes the PC tab row.
- **Settings:** every existing row and option key stays, shown under exactly the conditions it is shown today; Task 9 only regroups (pinned by test).
- **Monitor view:** gestures, live keyboard, shortcut presets, thumbwheel, right/middle-click arming, dock preference and `MonitorControlPreferences` storage are unchanged (spec §4); Task 6 changes chrome only.
- **Entry points:** auto-connect to the last PC (`HomePage.initState`), deep links (`listenUniLinks()` in the `_ConnectionPageState` constructor), the legacy `RemotePage` for non-Aperture peers and the fallback `EmulatorPage` picker keep working; share-this-phone (Share tab), chat (from Share), 2FA and trusted devices (Settings › Security) stay reachable.
- **Regression surface — spec §4 "What stays", verbatim:**
  - **Input paths:** emulator touch/multi-touch mapping (`mapEmulatorTouch`, pointer cancel on geometry change, focus loss and background), hardware-key mapping, the text composer and its send/restore logic, Android Back/Home/Recents; all monitor gestures, live keyboard, shortcut presets, thumbwheel, right/middle-click arming, Ctrl+Alt+Del, restart taskbar, clipboard transfer, window focus.
  - **Session safety:** control gated on `keyboard && !viewOnly`, on foreground and view focus, and on a fresh guest frame; input released on background and permission loss; monitor liveness checks.
  - **Recovery:** automatic reconnect limits (two attempts, only for a guest that was live, only in the foreground), the 120 s start timeout, the 25 s list timeout, preview acknowledgement and the 8 s frame-age rule.
  - **Protocol:** every `emulator-request` action and field (`list`, `select`, `desktop`, `previews`, `avd_*`, `emulator_shutdown`), capability checks (`host.avd_manage.v1`, `host.emulator_shutdown.v1`, others), operation identity and acknowledgement, the four-preview limit, stopped emulators never taking a preview slot.
  - **Management rules:** name validation and reserved names, "Stop it first" and "Copy in progress" blockers, confirmations before Stop and Delete, defaults (Android 15, 4 GB, 4 cores, `D:\Aperture\Emulators`).
  - **Presentation:** orientation follows the guest, immersive mode while streaming, per-monitor preferences stored under the existing keys, quality profile storage, System/Light/Dark preference.
  - **Entry points:** auto-connect to the last PC, deep links, the fallback `EmulatorPage` picker for PCs without the dashboard feature (copy fixes only), the legacy remote page for non-Aperture peers.
  - **Inherited features:** files, terminal, share-this-phone, 2FA, trusted devices, address book, all settings keys, all existing translation keys and the hand-maintained Italian file.
  - **PC:** host service, ID/password board logic, tray/minimise behaviour, the connection manager's permission toggles, pairing list and removal.
- Do not install on the phone, run adb, push, or open a PR. Task 10 builds the APK and stops.
- The app must build and keep working after every task; commit each task separately on `feature/aperture-ui-phase2` (worktree `C:/Programming Projects/MIRPG/rustdesk-emulator-remote-ui`).

## Review Focus

1. **Cancel is not a failure:** cancelling the "Connecting…" dialog, or the password dialog, returns to Computers with a plain Connect button; only a connection error shows "Couldn't connect to atlas" with its reason, and a later success clears it (Task 7 tracker tests).
2. **No last-used PC** (fresh install, cleared history): Computers shows the ID field open under "Add a computer" and no empty hero card (Task 7).
3. **End session in every connected state:** the PC tab shows End session even in a view-only session and when the PC offers none of System/Files/PowerShell (Task 3).
4. **View only after the top bar is gone:** a monitor in local view-only mode still says so on screen, without covering the toolbar (Task 6).
5. **Changing Appearance while connected:** System/Light/Dark re-themes the open dashboard at once (no per-page wrapper holding the old brightness), and inherited dialogs stay readable in both modes (Task 2).

---

## File map

| File | Responsibility | Task |
|---|---|---|
| `flutter/lib/common/widgets/studio_theme.dart` (new) | palette, `MirpgRemoteTheme`, `MirpgSurface`, `MirpgSectionHeader`, `MirpgStatusChip`, `MirpgStatusTone`; `apertureAppTheme` | 1, 2 |
| `flutter/lib/mobile/widgets/mirpg_remote_theme.dart` | re-export only | 1 |
| `flutter/lib/main.dart` | root theme via `apertureAppTheme` | 2 |
| `flutter/lib/mobile/pages/home_page.dart` | no wrapper; tabs Computers/Share/Settings; `openChat` | 2, 8 |
| `flutter/lib/mobile/pages/emulator_page.dart` | no wrapper | 2 |
| `flutter/lib/mobile/pages/target_dashboard_page.dart` | no wrappers; PC tab wiring; pairing; Screens tab; switcher grid | 2–5 |
| `flutter/lib/mobile/widgets/pc_tab.dart` (new) | `PcTabBody` | 3 |
| `flutter/lib/mobile/widgets/trust_phone_sheet.dart` (new) | pairing keys, `shouldOfferPairing`, `showTrustPhoneSheet` | 4 |
| `flutter/lib/mobile/widgets/screens_tab.dart` (new) | `ScreensTabBody`, `ScreensTabCard`, `TargetSwitcherGrid`, `screensPreviewDisplays` | 5 |
| `flutter/lib/models/emulator_model.dart` | `listError` | 5 |
| `flutter/lib/mobile/widgets/monitor_control_view.dart` | chrome: no top bar, Exit, panel header and session tiles, view-only chip, dark palette | 6 |
| `flutter/lib/mobile/widgets/computers_hero.dart` (new) | `ConnectAttemptTracker`, `ComputerHeroData`, `ComputerHeroCard`, `AddComputerSection` | 7 |
| `flutter/lib/mobile/pages/connection_page.dart`, `remote_page.dart`; `flutter/lib/models/model.dart` | hero wiring; tracker hooks; `lastConnectionError` | 7 |
| `flutter/lib/mobile/widgets/share_chat_button.dart` (new); `mobile/pages/server_page.dart`; `models/chat_model.dart` | Chat from Share; broken `BottomNavigationBar` casts | 8 |
| `flutter/lib/mobile/widgets/settings_layout.dart` (new); `mobile/pages/settings_page.dart` | grouped settings | 9 |
| `src/lang/*.rs`, `tools/aperture-release.json` | keys; 1.8.0 / 4115 | 10 |

---

### Task 1: Studio theme moves to `common/`

**Files:**
- Create: `flutter/lib/common/widgets/studio_theme.dart` (the whole current content of `mirpg_remote_theme.dart`, unchanged)
- Modify: `flutter/lib/mobile/widgets/mirpg_remote_theme.dart` → one line `export '../../common/widgets/studio_theme.dart';`
- Test: `flutter/test/studio_theme_test.dart` (new); `flutter/test/mirpg_remote_theme_test.dart` stays as is

**Interfaces:**
- Produces: the same public names as today (`MirpgStudioPalette`, `MirpgRemoteTheme`, `MirpgSurface`, `MirpgSectionHeader`, `MirpgStatusChip`, `MirpgStatusTone`) importable from `package:flutter_hbb/common/widgets/studio_theme.dart`; no renames, so no import churn.

- [ ] **Step 0: Record the baseline.** From `flutter/`: `flutter test`. Put the pass/fail counts in this task's commit message.
- [ ] **Step 1: Write the failing tests** in `studio_theme_test.dart`:

```dart
import 'package:flutter_hbb/common/widgets/studio_theme.dart' as common;
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart' as mobile;

test('common and mobile imports name the same palette', () {
  expect(identical(common.MirpgStudioPalette.dark, mobile.MirpgStudioPalette.dark), isTrue);
  expect(common.MirpgRemoteTheme.destructiveFill, const Color(0xFFB43E43));
});
test('building Studio over Studio changes nothing', () {
  for (final base in [ThemeData.light(), ThemeData.dark()]) {
    final once = common.MirpgRemoteTheme.build(base);
    final twice = common.MirpgRemoteTheme.build(once);
    expect(twice.colorScheme, once.colorScheme);
    expect(twice.scaffoldBackgroundColor, once.scaffoldBackgroundColor);
    expect(twice.textTheme.titleMedium?.fontSize, 18);
    expect(twice.dialogTheme.backgroundColor, once.dialogTheme.backgroundColor);
  }
});
test('the shared theme file does not depend on mobile code', () {
  expect(File('lib/common/widgets/studio_theme.dart').readAsStringSync(), isNot(contains('mobile/')));
});
```
- [ ] **Step 2: Run** `flutter test test/studio_theme_test.dart` — Expected: compile FAIL (file missing).
- [ ] **Step 3: Implement** the move (`git mv` then recreate the mobile file as the export, so history follows the content).
- [ ] **Step 4: Run** `flutter test test/studio_theme_test.dart test/mirpg_remote_theme_test.dart test/emulator_tile_test.dart` — Expected: PASS. `flutter analyze lib/common/widgets/studio_theme.dart lib/mobile/widgets/mirpg_remote_theme.dart` — no issues.
- [ ] **Step 5: Commit** `refactor(phone): Studio theme lives in common/`.

---

### Task 2: Studio at the phone app root; per-page wrappers removed

**Files:**
- Modify: `flutter/lib/common/widgets/studio_theme.dart` (add `apertureAppTheme`), `flutter/lib/main.dart:503-505`, `flutter/lib/mobile/pages/home_page.dart:77-115` (drop `Theme(...)`), `flutter/lib/mobile/pages/emulator_page.dart:865-866`, `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_showQualityConnection` :464-495, `build` :1306, :1326, :1355/:1413, `_openSettings` :1551-1561)
- Create: `flutter/test/support/visual_capture.dart`
- Test: `flutter/test/studio_root_theme_test.dart` (new), `flutter/test/studio_inherited_surfaces_test.dart` (new)

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `ThemeData apertureAppTheme(ThemeData rustDeskTheme, {required bool mobile})` — `mobile` → `MirpgRemoteTheme.build(rustDeskTheme)` (RustDesk's `ColorThemeExtension`/`TabbarTheme` extensions preserved); otherwise returns `rustDeskTheme` itself.
  - `Future<void> captureSurface(WidgetTester tester, Finder boundary, String name)` (test support) — when the environment variable `APERTURE_VISUAL_OUT` is set, renders the nearest `RepaintBoundary` of `boundary` to `$APERTURE_VISUAL_OUT/$name.png` inside `tester.runAsync`; otherwise does nothing.
- main.dart: `theme: apertureAppTheme(MyTheme.lightTheme, mobile: isAndroid || isIOS)`, `darkTheme: apertureAppTheme(MyTheme.darkTheme, mobile: isAndroid || isIOS)`; `themeMode` unchanged (`MyTheme.currentThemeMode()`), so `Get.changeThemeMode` keeps working.
- Pages: `Theme.of(context)` replaces each local `studioTheme`; `_showQualityConnection` keeps `backgroundColor: Theme.of(context).colorScheme.surface`. After this task `MirpgRemoteTheme.build(` appears in `lib/` only inside `studio_theme.dart`.
- Known visual surface (for the review and Task 10's on-device list): RustDesk dialogs (`CustomAlertDialog`, `msgBox`, password/2FA, wait-accept), the settings list, the Share page, the legacy `RemotePage` and its overlays, bot toasts. Literal `MyTheme.accent` icons inside `common/widgets/dialog.dart` stay (Phase 4).

- [ ] **Step 1: Write the failing tests.**

`studio_root_theme_test.dart` (imports `package:flutter_hbb/common.dart` for `MyTheme`, `ColorThemeExtension`, `TabbarTheme`):
- `phone root gets Studio over RustDesk's theme`: for (MyTheme.lightTheme, light palette) and (MyTheme.darkTheme, dark palette): `useMaterial3` isTrue, `scaffoldBackgroundColor == palette.background`, `colorScheme.primary == palette.accent`, `extension<ColorThemeExtension>()` and `extension<TabbarTheme>()` isNotNull.
- `desktop keeps RustDesk's theme untouched`: `identical(apertureAppTheme(MyTheme.lightTheme, mobile: false), MyTheme.lightTheme)` isTrue (same for dark).
- `changing appearance re-themes a page at once`: pump `MaterialApp(theme: apertureAppTheme(MyTheme.lightTheme, mobile: true), darkTheme: apertureAppTheme(MyTheme.darkTheme, mobile: true), themeMode: ThemeMode.dark, home: Builder(builder: (c) { seen = MirpgStudioPalette.of(c); return const SizedBox(); }))` → `seen == MirpgStudioPalette.dark`; pump again with `ThemeMode.light` and `pumpAndSettle` → `seen == MirpgStudioPalette.light`.

`studio_inherited_surfaces_test.dart` (visual-check guard; each case pumped in light and dark at 360×640 and again at 1.3 text scale, inside a `RepaintBoundary`, then `captureSurface(tester, find.byType(RepaintBoundary).first, '<case>-<mode>')`). Contrast helper: `double contrast(Color a, Color b)` = `(max(La, Lb) + 0.05) / (min + 0.05)` with `computeLuminance()`.
- `inherited dialog uses the Studio surface and readable text`: `CustomAlertDialog(title: Text('Password Required'), content: Column(children: [TextField(obscureText: true, decoration: InputDecoration(labelText: 'Password')), CheckboxListTile(value: true, onChanged: (_) {}, title: Text('Remember password'))]), actions: [TextButton(onPressed: () {}, child: Text('Cancel')), TextButton(onPressed: () {}, child: Text('OK'))])` (the composition `_connectDialog` builds; `dialogButton` is not used because it calls the native `translate`) → no exception; the `Material` under `AlertDialog` has `color == palette.raised`; `contrast(DefaultTextStyle of 'Password Required' color, palette.raised) >= 4.5`; `contrast(theme.textButtonTheme.style!.foregroundColor!.resolve({})!, palette.raised) >= 3.0`; entering `secret` keeps `EditableText.obscureText` true.
- `inherited settings list stays usable`: `SettingsList(sections: [SettingsSection(title: Text('Network'), tiles: [SettingsTile.switchTile(initialValue: true, onToggle: (v) => toggled.add(v), title: Text('Use WebSocket')), SettingsTile(title: Text('Language'), onPressed: (_) => taps++)])])` → no exception; tap the `Switch` → `toggled == [false]`; tap `Language` → `taps == 1`.
- `snack bars, sheets and menus use Studio shapes`: a `SnackBar` shown via `ScaffoldMessenger`, a `showModalBottomSheet` and a `PopupMenuButton` opened in turn → `SnackBar` `Material.color == palette.raised`, bottom sheet `Material.color == palette.raised`, popup `Material.color == palette.raised`; no exception.

- [ ] **Step 2: Run** `flutter test test/studio_root_theme_test.dart test/studio_inherited_surfaces_test.dart` — Expected: compile FAIL (`apertureAppTheme`, `captureSurface` missing).
- [ ] **Step 3: Implement** `apertureAppTheme`, `captureSurface`, the `main.dart` wiring and the wrapper removals listed above.
- [ ] **Step 4: Run** the two files plus `test/mirpg_remote_theme_test.dart test/home_page_shell_test.dart test/target_dashboard_test.dart test/play_tab_test.dart test/startup_checklist_test.dart` — Expected: PASS. `rg -n "MirpgRemoteTheme\.build\(" flutter/lib` — only `studio_theme.dart`. `flutter analyze` on the touched files — no new issues.
- [ ] **Step 5: Visual check.** `$env:APERTURE_VISUAL_OUT='<session scratchpad>\phase2-visual'; flutter test test/studio_inherited_surfaces_test.dart` and open every PNG: dialog surface, button and field colours, switch and section colours, both modes (test fonts draw text as boxes; judge colour, shape and overflow only). Record anything that looks wrong as a finding for the reviewer; do not commit the PNGs.
- [ ] **Step 6: Commit** `feat(phone): Studio theme at the app root`.

---

### Task 3: PC tab, End session and the connected shell

**Files:**
- Create: `flutter/lib/mobile/widgets/pc_tab.dart`
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_ConnectedPcSection.tools` → `pc`; `_toolsBody` :1647-1714 replaced; `build` app bar :1416-1505, `bottomNavigationBar` :1520-1545; `_showSessionStillConnected` :1563-1571; `ConnectedPcTabBar` :2477-2521; delete `_ConnectedPcSessionAction` and `ConnectedPcSessionMenu` :2523-2629)
- Test: `flutter/test/pc_tab_test.dart` (new), `flutter/test/target_dashboard_test.dart`

**Interfaces:**
- Consumes: Task 2 (root theme), `SessionStatusButton(compact:)` (Phase 1).
- Produces:
  - `class PcTabBody extends StatelessWidget { const PcTabBody({super.key, this.onSystem, this.onFiles, this.onPowerShell, required this.onQuality, this.onPrivacy, this.pairingState = '', this.onTrustPhone, this.onForgetPairing, required this.onSettings, required this.onEndSession, this.tr = translate}); }` — all callbacks `VoidCallback`; `pairingState` is `'paired' | 'can-pair' | 'unavailable' | ''`.
  - `ConnectedPcTabBar` destinations `Play`, `Screens` (tr), `PC` (tr, `Icons.computer_outlined` / `Icons.computer_rounded`).
- `PcTabBody` (mockup 2b), a `ListView` with 16 dp margin, `MirpgSurface` groups, 56 dp `ListTile`s with chevrons:
  - `This PC` (header only when a row below exists): `System and processes` / `PC status, processes and host controls` (onSystem), `Files` / `Browse and transfer files` (onFiles), `PowerShell` / `Open the authenticated remote terminal` (onPowerShell) — a row exists only when its callback is non-null.
  - `Connection`: `Quality and connection` / `Direct or relay route, latency and stream health`; `Privacy and host controls` (only with onPrivacy); trust row — `paired`: title `This phone is trusted`, subtitle `Connects without a password`, trailing `TextButton(tr('Forget'))` → onForgetPairing; `can-pair`: `Trust this phone` / `Connect without a password at home` → onTrustPhone; otherwise no row.
  - `App`: `Appearance and settings` / `System, light or dark mode and more`.
  - then a divider and `End session` (`Icons.logout`, icon and text `palette.error`, no chevron), always present and last.
- Dashboard wiring:
  - App bar: title is the host name on Play, Screens and PC (subtitle = tab name on Screens/PC); actions = `SessionStatusButton(compact: width < 480)` on every tab and sub-page, plus the existing refresh buttons (Screens until Task 5, System). No `ConnectedPcSessionMenu` anywhere.
  - PC tab rows: System/Files/PowerShell → `_openToolsSection(...)` (existing availability checks); Quality → `_showQualityConnection`; Privacy → `showPrivacyControlsSheet`; trust → `_trustThisPhone` / `_forgetPairing`; settings → `_openSettings`; End session → `clientClose(widget.ffi.sessionId, widget.ffi)` (unchanged confirmation).
  - Sub-pages (System, Files, PowerShell) stay in the `IndexedStack` so the terminal and file sessions survive leaving and returning (deliberate: spec says "pushed pages"; this looks the same — back arrow, no tab bar — without disposing them). `bottomNavigationBar: null` on sub-pages; the back arrow and system back return to `pc` (existing `handleConnectedPcWorkspaceBack`).
  - `_showSessionStillConnected` text: `Session still connected. End it from the PC tab.`
- Deferred Phase 1 items closed here: Play app-bar "⋮" removed; End session moved to the PC tab; "Manage Jarvis"-style subtitle gone (host name in the title).

- [ ] **Step 1: Write the failing tests** in `pc_tab_test.dart` (`tr: fakeTr`, dark Studio theme, 360×800):
  - `PC tab groups rows and ends with a red End session`: all callbacks set → top-left `dy` strictly increasing for `This PC`, `System and processes`, `Files`, `PowerShell`, `Connection`, `Quality and connection`, `Privacy and host controls`, `App`, `Appearance and settings`, `End session`; `tester.widget<Text>(find.text('End session')).style!.color == MirpgStudioPalette.dark.error`.
  - `End session stays when the PC offers no tools` (Review Focus 3): `onSystem/onFiles/onPowerShell/onPrivacy` null → `This PC`, `System and processes`, `Files`, `PowerShell`, `Privacy and host controls` find nothing; `End session` found and tapping it → `ends == 1`.
  - `each row runs only its own action`: tap each row once → every counter 1, `ends == 0` until `End session` is tapped.
  - `trust row follows the pairing state`: `''` and `'unavailable'` → no `Trust this phone`, no `This phone is trusted`; `'can-pair'` → tap `Trust this phone` → `trusts == 1`; `'paired'` → `Connects without a password` found, tap `Forget` → `forgets == 1`.
  - `PC tab fits 360 dp at 1.3 text scale`: no exception; `await tester.scrollUntilVisible(find.text('End session'), 100)` then it is hit-testable.

  In `target_dashboard_test.dart`: the four `ConnectedPcTabBar` tests expect `Play`, `Screens`, `PC` (no `Tools`); delete `connected PC session menu exposes settings and explicit end` (its four actions are covered by `pc_tab_test.dart`); the two `handleConnectedPcWorkspaceBack` tests stay.
- [ ] **Step 2: Run** `flutter test test/pc_tab_test.dart test/target_dashboard_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** `pc_tab.dart`, the tab bar labels and the dashboard wiring above.
- [ ] **Step 4: Run** the same command plus `test/play_tab_test.dart` — Expected: PASS. `rg -n "ConnectedPcSessionMenu|Session menu|'Tools'|Workspace tools" flutter/lib flutter/test` — no matches. `flutter analyze` on the two lib files — no new issues.
- [ ] **Step 5: Commit** `feat(phone): PC tab with End session replaces the session menu`.

---

### Task 4: One-time pairing prompt and the trusted flag

**Files:**
- Create: `flutter/lib/mobile/widgets/trust_phone_sheet.dart`
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_refreshPairingState` :261-272, `_forgetPairing` :291-297, `_pairResultChanged` :299-313, `_dashboard` :1153, new `_maybeOfferPairing`)
- Test: `flutter/test/trust_phone_sheet_test.dart` (new)

**Interfaces:**
- Consumes: `PcTabBody.pairingState` (Task 3).
- Produces (Task 7 reads `pairedFlagKey`):
  - `String pairPromptedKey(String peerId) => 'aperture-pair-prompted:$peerId';`
  - `String pairedFlagKey(String peerId) => 'aperture-paired:$peerId';`
  - `bool shouldOfferPairing({required String pairingState, required String promptedFlag})` — true only for `pairingState == 'can-pair' && promptedFlag != 'Y'`.
  - `Future<bool?> showTrustPhoneSheet(BuildContext context, {required String hostName, String Function(String) tr = translate})` — bottom sheet: title `Trust this phone on {hostName}?`, body `Next time it connects without a password.`, `FilledButton(tr('Trust'))` → `true`, `TextButton(tr('Not now'))` → `false`, dismiss → `null`.
- Dashboard: both keys go through `bind.getLocalFlutterOption` / `setLocalFlutterOption` with `widget.ffi.id`. `_refreshPairingState` writes `pairedFlagKey` = `Y` for `paired`, `N` for `can-pair` (leaves it for `unavailable`/errors), then calls `_maybeOfferPairing()`. `_maybeOfferPairing()`: returns unless `mounted`, `_fullscreen == null` and `shouldOfferPairing(...)`; writes `pairPromptedKey` = `Y` **before** showing the sheet (one-time even if the app is killed); on `true` → `_trustThisPhone()`. `_dashboard()` calls `_maybeOfferPairing()` so a prompt deferred during a game appears on return. `_pairResultChanged` snackbar copy goes through `translate` (`This phone connects without a password at home`, `Pairing failed`) and on success writes the paired flag `Y`; `_forgetPairing` writes `N`.

- [ ] **Step 1: Write the failing tests** (`tr: fakeTr`):

```dart
test('the prompt is offered once, only when the PC can pair', () {
  expect(shouldOfferPairing(pairingState: 'can-pair', promptedFlag: ''), isTrue);
  expect(shouldOfferPairing(pairingState: 'can-pair', promptedFlag: 'Y'), isFalse);
  for (final s in ['', 'paired', 'unavailable']) {
    expect(shouldOfferPairing(pairingState: s, promptedFlag: ''), isFalse, reason: s);
  }
});
test('keys are per PC', () {
  expect(pairPromptedKey('123'), 'aperture-pair-prompted:123');
  expect(pairedFlagKey('123'), 'aperture-paired:123');
});
```
  Widget tests: `sheet names the PC and returns the choice` — open from a button: `Trust this phone on atlas?` and `Next time it connects without a password.` found; tap `Trust` → `true`; reopen, tap `Not now` → `false`; reopen, `tester.tapAt(const Offset(10, 10))` → `null`. `sheet fits 360 dp at 1.3 text scale` — no exception.
- [ ] **Step 2: Run** `flutter test test/trust_phone_sheet_test.dart` — Expected: compile FAIL.
- [ ] **Step 3: Implement** the sheet file and the dashboard wiring.
- [ ] **Step 4: Run** the same plus `test/pc_tab_test.dart test/target_dashboard_test.dart` — Expected: PASS; analyzer clean on touched files.
- [ ] **Step 5: Commit** `feat(phone): offer to trust this phone once after a password login`.

---

### Task 5: Screens tab shows monitors only; list errors only on Play; switcher grid

**Files:**
- Create: `flutter/lib/mobile/widgets/screens_tab.dart`
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_ScreenFilter` :48 deleted; `_devicesBody` :1716-1921 → `_screensBody`; `_subscribe` screens branch :608-640; `_monitorCard` :1924-1963; `_guestRow` :1966-1980 deleted; `_choose` :1210-1268; `_homeBody` :1621-1623; `TargetSwitcherCards` :2643-2677 and `TargetScreenRow` :2681-2787 deleted; `TargetPreviewCard` :2790+; Screens refresh button :1474-1483 deleted), `flutter/lib/models/emulator_model.dart` (`refresh` :606-621, `_send` :558-572, inventory response :1903-1905)
- Test: `flutter/test/screens_tab_test.dart` (new), `flutter/test/target_dashboard_test.dart`, `flutter/test/emulator_model_test.dart`

**Interfaces:**
- Consumes: Task 3 shell.
- Produces:
  - `EmulatorModel.listError` (`String`, default `''`): set to `The PC did not return its emulator list. Refresh to try again.` by the 25 s timeout, to the joined `provider_errors` of an inventory response, and to `failure.toString()` when `_send` fails for a payload whose `action` is `list`; cleared at the start of `refresh()`. Every existing write to `error` stays.
  - `TargetPreviewCard({super.key, required this.name, this.detail = '', required this.live, this.image, this.error = '', this.onOpen, this.onRetry, this.onWindows, this.tr = translate})` — monitors only (`type` param dropped). State badge: `Live` (good) / `Waiting for preview` (warning) / `Problem` (error, with `error` as a 2-line cause); `FilledButton(tr('Reconnect'))` → onRetry while not live; footer `name` (`titleMedium`) + `detail` (`bodySmall`, e.g. `2560 × 1440`), `OutlinedButton.icon(Icons.web_asset_outlined, tr('Windows'))` when onWindows non-null, `FilledButton(tr('Open'))` → onOpen.
  - `class ScreensTabCard { const ScreensTabCard({required this.aspectRatio, required this.child}); }` — `aspectRatio` = display width / height clamped to `[1.0, 2.4]`.
  - `class ScreensTabBody extends StatelessWidget { const ScreensTabBody({super.key, required this.cards, required this.hostName, this.scrollController, this.tr = translate}); }` — header `PC screens`; one card per row, 16 dp margins, 12 dp spacing, card height `width / aspectRatio + 64`; no filter; empty → `MirpgSurface` `No screens from {hostName} yet`.
  - `List<int> screensPreviewDisplays({required int monitorCount, required int firstVisibleIndex})` — indices `>= firstVisibleIndex` ascending, then lower ones descending; at most 4.
  - `class TargetSwitcherGrid extends StatelessWidget { const TargetSwitcherGrid({super.key, required this.cards, this.controller}); }` — `GridView`, 2 columns in portrait, 4 when width > height, spacing 12, `childAspectRatio` 0.75.
- Dashboard: Screens builds one `TargetPreviewCard` per `pi.displays` entry (`detail` = `'${d.width} × ${d.height}'`, `onWindows` → `_monitorWindows(index)`, `onRetry` → resubscribe) inside `ScreensTabBody`; `_subscribe` on Screens sends `displays = screensPreviewDisplays(monitorCount, firstVisibleIndex: floor(scrollOffset / cardExtent))`, `guestIds = []`. `_choose` keeps its order (monitors first, the current kind when opened from a monitor) but shows a `TargetSwitcherGrid`; preview slots = the first 4 entries from the grid's first visible index that are monitors or non-stopped, non-shutting-down emulators (replaces `_chooserStart` paging; "Swipe for more views" goes). Play's list card reads `model.listError` (replaces the `guestFailures.containsValue(model.error)` filter).
- Deferred Phase 1 items closed here: Screens tab list-failure feedback (the Screens tab no longer shows emulators, so the list error belongs to Play alone); list-error card showing non-list `model.error`; monitor-card labels untranslated and in old vocabulary.

- [ ] **Step 1: Write the failing tests.**

`emulator_model_test.dart` (use `handleResponse` and the widget-tester clock as the existing `listRequestedAt` and 120 s tests do):
  - `list error is kept apart from start and stream errors`: `refresh()`, `pump(25 s)` → `listError == 'The PC did not return its emulator list. Refresh to try again.'`; a fresh model: `connect('avd:Main')`, `pump(120 s)` → `error == 'Took too long to start. Try again, or go back.'` and `listError == ''`.
  - `provider errors are list errors and clear on the next refresh`: inventory response with `provider_errors: ['BlueStacks is not installed']` → `listError == 'BlueStacks is not installed'`; `refresh()` → `listError == ''`.
  - `a failed list send is a list error`: `commandSender` throws `StateError('offline')` for `action == 'list'` → after `refresh()` and a pump, `listError` contains `offline`.

`screens_tab_test.dart` (`tr: fakeTr`, 412×915 unless stated):
```dart
test('screens previews start at the first visible monitor', () {
  expect(screensPreviewDisplays(monitorCount: 3, firstVisibleIndex: 0), [0, 1, 2]);
  expect(screensPreviewDisplays(monitorCount: 6, firstVisibleIndex: 3), [3, 4, 5, 2]);
  expect(screensPreviewDisplays(monitorCount: 0, firstVisibleIndex: 0), isEmpty);
});
```
  - `Screens shows one full-width card per monitor and no filter`: three `ScreensTabCard(aspectRatio: 16 / 9, child: ColoredBox(key: ValueKey('m$i')))` → each child width `412 - 32`; `dy` order m0 < m1 < m2; `PC screens` found; `Android`, `All (` find nothing.
  - `no monitors yet names the PC`: `cards: []` → `No screens from atlas yet`.
  - `monitor card offers Reconnect only while not live`: `live: true` → `Reconnect` nothing, `Live` found; `live: false, onRetry` → `Waiting for preview`, tap `Reconnect` → `retries == 1`; `error: 'Capture failed'` → `Problem` and `Capture failed`.
  - `monitor card opens and shows Windows`: tap `Windows` → `windows == 1`; tap `Open` → `opens == 1`; `onWindows: null` → `Windows` nothing; `detail: '2560 × 1440'` found.
  - `monitor card words go through translate`: `tr: (k) => '[$k]'`, `live: true` → `[Live]` and `[Open]` found.
  - `switcher grid uses two columns in portrait and four in landscape`: six keyed boxes; at 412×915 cards 0 and 1 share a `dy` and card 2 is below them; at 915×412 cards 0–3 share one `dy` and card 4 is below them.
  - `monitor card fits a 230×145 chooser cell at 1.3 text scale` (migrated from `preview failure remains usable in a compact chooser at large font size`): no exception, `Reconnect` found.

`target_dashboard_test.dart`: delete `monitor row offers Retry preview only while not live` and the old chooser-cell test (migrated above); update `monitor cards expose Open` and any `TargetPreviewCard(type: ...)` call to the new signature.
- [ ] **Step 2: Run** `flutter test test/screens_tab_test.dart test/emulator_model_test.dart test/target_dashboard_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** `listError`, `screens_tab.dart`, the new `TargetPreviewCard` and the dashboard wiring.
- [ ] **Step 4: Run** the same plus `test/play_tab_test.dart test/emulator_tile_test.dart` — Expected: PASS. `rg -n "_ScreenFilter|TargetSwitcherCards|TargetScreenRow|Swipe for more views|Retry preview|Needs attention|'Attention'|Show Android screens" flutter/lib/mobile` — no matches. Analyzer clean.
- [ ] **Step 5: Commit** `feat(phone): Screens tab shows PC monitors; list errors stay on Play`.

---

### Task 6: Monitor view without the top bar

**Files:**
- Modify: `flutter/lib/mobile/widgets/monitor_control_view.dart` (`_controlTile` :1662, `_controlsPanel` :1712-1778, `_toolbarButton` :1785, `_handleSessionAction`/`_menuItem`/`_sessionMenu` :1794-1844 deleted, `_sessionTopBar` :1846-1910 deleted, `_footerControl` :1912, `_sessionToolbar` :1973-2001, `_thumbwheel`, `_modeBadge`, `_sessionRail`, `build` :2096-2168, `_remoteViewport`, `_MonitorSessionAction` :2299 deleted)
- Test: `flutter/test/monitor_control_view_test.dart`

**Interfaces:**
- Consumes: Task 1 palette.
- Produces: `MonitorControlView` gains `final String Function(String) tr` (default `translate`); every existing parameter keeps its name and meaning. Keys: `ValueKey('monitor-toolbar')` on the bottom toolbar, `ValueKey('monitor-view-only-chip')`, `ValueKey('monitor-panel-header')`.
- Chrome (spec §3.5):
  - Bottom toolbar, in order: `Exit` (`Icons.grid_view_rounded`, tooltip and label `Exit`, `onDashboard`), `Fit view`, `Readable view`, `Keyboard`, `Controls`, `Switch view` (label `Switch`, replaces `Targets`). Landscape rail layout: left rail Exit / Fit / Readable / Switch view; right rail Keyboard / Controls (the "⋮" is gone). The rail-vs-bar choice uses `(height - 68)` for the bar layout (was `- 124`, which counted the 56 dp top bar).
  - Controls panel: header row `'${w} × ${h} · $_viewLabel'` (`labelMedium`, key above); then the existing tiles unchanged, then `Clipboard` (`Icons.content_copy_outlined`, onClipboard), `Windows` (`Icons.web_asset_outlined`, onWindows), `Quality` (tooltip `Quality and connection`, `Icons.network_check`, onSessionStatus) — each only when its callback is non-null — and `Hide toolbar` (`Icons.keyboard_arrow_down_rounded`; sets `_toolbarVisible = false`, closes the panel, emits preferences). Tapping a session tile closes the panel first.
  - `widget.localViewOnly` → `MirpgStatusChip(label: tr('View only'), tone: warning, onDarkSurface: true)` positioned top-centre, 8 dp below the safe area, inside the viewport stack, `IgnorePointer`.
  - Colours: `const _p = MirpgStudioPalette.dark;` replaces every `MirpgRemoteTheme.<colour>` and `Colors.white/white70/white38` (disabled = `_p.textSecondary.withOpacity(0.38)`), so a light app still gets dark chrome over the video. The image's own black background stays `Colors.black`.

- [ ] **Step 1: Write the failing tests.** Extend the `show` helper with `desktopSize`, `clipboard`, `windows`, `quality`, `localViewOnly`, `theme` parameters and `tr: fakeTr`.
  - Update `Fit uses the available screen at $size with controls visible`: tooltip list `Exit`, `Fit view`, `Readable view`, `Keyboard`, `Controls`, `Switch view` (drop `Dashboard`, `Session controls`); add `find.byKey(const ValueKey('monitor-top-bar'))` findsNothing; in portrait `getCenter(byTooltip('Exit')).dx < getCenter(byTooltip('Fit view')).dx`.
  - `the picture gains the old top bar's height`: 384×832, `desktopSize: Size(1080, 1920)` → `frame.height` closeTo `832 - getSize(find.byKey(ValueKey('monitor-toolbar'))).height` (±0.5).
  - `session actions live in the Controls panel`: open Controls, tap `Clipboard` → `clipboards == 1` and the panel is closed; reopen, `Windows` → 1; reopen, `byTooltip('Quality and connection')` → 1; `find.byTooltip('Session controls')` nothing.
  - `Controls header shows resolution and view`: `find.text('3840 × 2160 · Fit')` within `monitor-panel-header`.
  - `Hide toolbar from Controls, then show it again`: tap `Hide toolbar` → `changes.last.toolbarVisible` isFalse and `byTooltip('Keyboard')` nothing; tap `Show toolbar` → visible again.
  - `view only stays visible without the top bar` (Review Focus 4): `localViewOnly: true` → chip found with text `View only`; its rect does not overlap the toolbar rect; `localViewOnly: false` → chip nothing.
  - `chrome over the picture stays dark in a light app`: `theme: MirpgRemoteTheme.build(ThemeData.light())` → `Material` ancestor of `monitor-toolbar` has `color == MirpgStudioPalette.dark.background`; `monitor-controls-panel` color `== MirpgStudioPalette.dark.surface`.
  - `Controls lists labelled actions and runs Ctrl+Alt+Del`: tap `Exit` instead of `Dashboard`.
  - `typing keeps the PC visible` group: the `topBar` finder becomes the toolbar key; rename `typing hides the top bar...` → `typing hides the toolbar and keeps the picture size` and `closing the keyboard restores the top bar` → `closing the keyboard restores the toolbar`; assertions otherwise unchanged.
  - All gesture, keyboard, shortcut, thumbwheel, dock, orientation and reset tests stay unchanged and must pass.
- [ ] **Step 2: Run** `flutter test test/monitor_control_view_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** the chrome changes above.
- [ ] **Step 4: Run** `flutter test test/monitor_control_view_test.dart test/monitor_live_keyboard_test.dart test/monitor_key_sender_test.dart test/remote_conformance/window_picker_test.dart test/remote_conformance/clipboard_transfer_test.dart test/target_dashboard_test.dart` — Expected: PASS. `rg -n "MirpgRemoteTheme\.(background|surface|raised|textPrimary|textSecondary|accent|outline|divider|error|warning)\b|Colors\.white" flutter/lib/mobile/widgets/monitor_control_view.dart` — no matches. Analyzer clean.
- [ ] **Step 5: Commit** `feat(phone): monitor view drops its top bar; session actions in Controls`.

---

### Task 7: Computers page is the atlas hero card

**Files:**
- Create: `flutter/lib/mobile/widgets/computers_hero.dart`
- Modify: `flutter/lib/mobile/pages/connection_page.dart` (`build` :81-126, `initState` :63-79; the constructor's `listenUniLinks()` and both `Get.put` calls stay), `flutter/lib/mobile/pages/remote_page.dart` (`initState` :97-111, `dispose` :148-158, `_openDashboardWhenReady` :203-208), `flutter/lib/models/model.dart` (`FfiModel.handleMsgBox` :939-946)
- Test: `flutter/test/computers_hero_test.dart` (new), `flutter/test/home_page_shell_test.dart`

**Interfaces:**
- Consumes: `pairedFlagKey` (Task 4).
- Produces:
  - `enum ConnectPhase { idle, connecting, failed }`
  - `class ConnectAttempt { const ConnectAttempt({this.phase = ConnectPhase.idle, this.peerId = '', this.reason = ''}); final ConnectPhase phase; final String peerId; final String reason; }`
  - `class ConnectAttemptTracker extends ValueNotifier<ConnectAttempt> { ConnectAttemptTracker() : super(const ConnectAttempt()); static final ConnectAttemptTracker shared = ConnectAttemptTracker(); void started(String peerId); void authenticated(String peerId); void ended(String peerId, {required bool authenticated, required String reason}); }` — `started` → connecting; `authenticated` → idle; `ended` → idle when `authenticated` or `reason` is empty (Cancel on "Connecting…" or the password dialog), else failed with `reason`; `authenticated`/`ended` for a `peerId` other than the current attempt's are ignored.
  - `String FfiModel.lastConnectionError` (default `''`): set to `text` in `handleMsgBox` when `title == 'Connection Error'` or `type` contains `error`; no other behaviour changes.
  - `class ComputerHeroData { const ComputerHeroData({required this.id, required this.name, this.online, this.trusted = false}); final String id; final String name; final bool? online; final bool trusted; }` — `name` = peer alias, else hostname, else `formatID(id)`.
  - `class ComputerHeroCard extends StatelessWidget { const ComputerHeroCard({super.key, required this.data, required this.attempt, required this.onConnect, this.tr = translate}); }`
  - `class AddComputerSection extends StatelessWidget { const AddComputerSection({super.key, required this.hasHero, required this.expanded, required this.onExpandedChanged, required this.idField, required this.onSavedComputers, this.tr = translate}); }` — `onExpandedChanged: ValueChanged<bool>`, `onSavedComputers: VoidCallback`.
- Card (mockup 2c, Q7 variant): `MirpgSurface`, `Icons.desktop_windows_outlined` + `name` (`titleMedium`, 2 lines) + status chip (`online == true` → `Online` good; `false` → `Offline` neutral; `null` → none); line `Trusted · connects without password` when `trusted`; full-width `FilledButton` — idle: `Connect`; connecting (attempt for this id): disabled, small ring + `Connecting…`; failed (attempt for this id): error-coloured `Couldn't connect to {name}`, then `tr(reason)` (`bodySmall`, 3 lines), then `FilledButton(tr('Try again'))`. Attempts for another id render as idle.
- Section: `hasHero` → a 56 dp row `Add another computer` with a chevron, collapsed by default; when expanded shows `idField` and a row `Saved computers` (`Icons.bookmarks_outlined`). `!hasHero` → title `Add a computer`, always expanded, no chevron.
- Page: `ListView` with 16 dp margins: the update banner (unchanged), the hero (only when `bind.mainGetLastRemoteId()` is non-empty), then `AddComputerSection(idField: _buildRemoteIDTextField())`. Peer data from `_allPeersLoader` (call `getAllPeers()` once the last id is known, then `queryOnlines([peer])`); `trusted` = `bind.getLocalFlutterOption(k: pairedFlagKey(id)) == 'Y'`; the card listens to `ConnectAttemptTracker.shared`. `onConnect` → `connect(context, id)`. `Saved computers` pushes `Scaffold(appBar: AppBar(title: Text(translate('Saved computers'))), body: PeerTabPage())` so saved/recent PCs and the address book stay reachable (spec §4) while the list leaves the page (Q7). `PeerTabPage` is otherwise not built.
- RemotePage hooks (three lines, no other change): `initState` before `gFFI.start` — `gFFI.ffiModel.lastConnectionError = ''; ConnectAttemptTracker.shared.started(widget.id);`; `_openDashboardWhenReady` first line — `if (gFFI.ffiModel.authenticatedPeer) ConnectAttemptTracker.shared.authenticated(widget.id);`; `dispose` first line — `ConnectAttemptTracker.shared.ended(widget.id, authenticated: gFFI.ffiModel.authenticatedPeer || _dashboardOpened, reason: gFFI.ffiModel.lastConnectionError);`.
- Deliberate deviation (spec §3.7 "Connecting… with Cancel instead of the generic RustDesk dialog"): `connect()` pushes `RemotePage`, which owns the session and every connect dialog, so the card cannot be visible while connecting. The card shows `Connecting…` only for an attempt in flight (it guards a double tap when returning early) and the RustDesk "Connecting…" dialog keeps Cancel. Replacing that dialog means moving session start out of `RemotePage`; that is a user decision, not part of this plan.

- [ ] **Step 1: Write the failing tests** in `computers_hero_test.dart` (`tr: fakeTr`, dark Studio theme, 360×800):

```dart
test('cancelling the connect or password dialog is not a failure', () {
  final t = ConnectAttemptTracker()..started('1');
  t.ended('1', authenticated: false, reason: '');
  expect(t.value.phase, ConnectPhase.idle);
});
test('a connection error keeps its reason for the card', () {
  final t = ConnectAttemptTracker()..started('1');
  t.ended('1', authenticated: false, reason: 'Remote desktop is offline');
  expect((t.value.phase, t.value.peerId, t.value.reason), (ConnectPhase.failed, '1', 'Remote desktop is offline'));
});
test('an older page closing does not overwrite a newer attempt', () {
  final t = ConnectAttemptTracker()..started('1')..started('2');
  t.ended('1', authenticated: false, reason: 'x');
  expect((t.value.phase, t.value.peerId), (ConnectPhase.connecting, '2'));
});
test('reaching the PC clears an earlier failure', () {
  final t = ConnectAttemptTracker()..started('1');
  t.ended('1', authenticated: false, reason: 'x');
  t..started('1')..authenticated('1');
  expect(t.value.phase, ConnectPhase.idle);
  t.ended('1', authenticated: true, reason: 'Connection reset');
  expect(t.value.phase, ConnectPhase.idle);
});
```
  Widget tests:
  - `idle card names the PC, its state and one Connect`: `ComputerHeroData(id: '1', name: 'atlas', online: true, trusted: true)` → `atlas`, `Online`, `Trusted · connects without password`; tap `Connect` → `connects == 1`.
  - `offline is stated and unknown is not`: `online: false` → `Offline`; `online: null` → neither `Online` nor `Offline`.
  - `connecting disables the button`: attempt `connecting` for `'1'` → `Connecting…` found; the `FilledButton.onPressed` is null; tapping → `connects == 0`.
  - `failure puts the reason under the title and offers Try again` (Review Focus 1): attempt failed `'1'`, reason `Remote desktop is offline` → `Couldn't connect to atlas` `dy` < reason `dy`; tap `Try again` → `connects == 1`.
  - `a failure for another PC does not show`: failed attempt for `'2'` → `Connect` found, `Couldn't connect to atlas` nothing.
  - `Add another computer starts collapsed`: `hasHero: true, expanded: false, idField: const TextField(key: ValueKey('id'))` → `ValueKey('id')` nothing; tap `Add another computer` → `expandedChanges == [true]`; with `expanded: true` → id field found, tap `Saved computers` → `saved == 1`.
  - `without a last PC the ID field is open` (Review Focus 2): `hasHero: false, expanded: false` → `Add a computer` and `ValueKey('id')` found; `Add another computer` nothing; no chevron icon (`Icons.expand_more` nothing).
  - `hero fits 360 dp at 1.3 text scale with a long name and reason`: name `atlas-gaming-workstation-upstairs`, reason 120 characters → no exception.
  `home_page_shell_test.dart`: `remote root is named Computers` stays.
- [ ] **Step 2: Run** `flutter test test/computers_hero_test.dart` — Expected: compile FAIL.
- [ ] **Step 3: Implement** `computers_hero.dart`, the page, the three RemotePage lines and `lastConnectionError`.
- [ ] **Step 4: Run** the same plus `test/home_page_shell_test.dart test/autocomplete_peer_merge_test.dart` — Expected: PASS. `rg -n "Other computers|Your computers|Connect to a computer" flutter/lib/mobile` — no matches. `git diff -- flutter/lib/mobile/pages/remote_page.dart flutter/lib/models/model.dart` shows only the lines named above. Analyzer clean.
- [ ] **Step 5: Commit** `feat(phone): Computers leads with the last PC as one card`.

---

### Task 8: Chat leaves the tab bar and opens from Share

**Files:**
- Create: `flutter/lib/mobile/widgets/share_chat_button.dart`
- Modify: `flutter/lib/mobile/pages/home_page.dart` (`isChatPageCurrentTab` :35-37, `initPages` :62-74, `build` tab handler :101-111, `appTitle` :118-161 chat branch → `MobileChatTitle`), `flutter/lib/mobile/pages/server_page.dart` (`appBarActions` :26-29, client card chat button :690-703), `flutter/lib/models/chat_model.dart` (`showChatIconOverlay` :155-161)
- Test: `flutter/test/home_page_shell_test.dart`, `flutter/test/share_chat_button_test.dart` (new)

**Interfaces:**
- Produces:
  - `enum MobileRootTab { computers, share, settings }` and `List<MobileRootTab> mobileRootTabs({required bool android, required bool incomingOnly, required bool outgoingOnly})` — `computers` unless incomingOnly; `share` when `android && !outgoingOnly`; `settings` always. `initPages` maps these to `ConnectionPage`, `ServerPage`, `SettingsPage`.
  - `Future<void> HomePageState.openChat({MessageKey? key})` — `changeCurrentKey(key)` when given; hides the chat icon/window overlays and clears unread (the code now in the tab handler :104-109); sets `_chatOpen = true`; pushes `MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const MobileChatTitle()), body: ChatPage(type: ChatPageType.mobileMain)))`; on pop `_chatOpen = false`.
  - `bool get isChatPageCurrentTab => _chatOpen;` (name kept; `chat_model.dart:425` reads it).
  - `class MobileChatTitle extends StatelessWidget` — the current chat branch of `appTitle()`; `appTitle()` keeps only the page-title branch.
  - `class ShareChatButton extends StatelessWidget { const ShareChatButton({super.key, required this.unread, required this.onPressed, this.tr = translate}); final int unread; final VoidCallback onPressed; }` — `IconButton(tooltip: tr('Chat'), icon: Icons.chat_bubble_outline)` with a count badge when `unread > 0`.
- Share: `ServerPage.appBarActions` = `[Obx(() => ShareChatButton(unread: gFFI.chatModel.mobileUnreadSum.value, onPressed: () => HomePage.homeKey.currentState?.openChat())), ...existing]`. The client card's chat button (:697-701, today a cast to `BottomNavigationBar` that throws since the Studio `NavigationBar`) calls `HomePage.homeKey.currentState?.openChat(key: MessageKey(client.peerId, client.id))`.
- `chat_model.dart:155-161`: replace the `BottomNavigationBar` cast with `if (HomePage.homeKey.currentState?.isChatPageCurrentTab == true) return;` (desktop has no `HomePage` state, so it is unaffected).

- [ ] **Step 1: Write the failing tests.**

```dart
test('Chat is never a root tab', () {
  expect(mobileRootTabs(android: true, incomingOnly: false, outgoingOnly: false),
      [MobileRootTab.computers, MobileRootTab.share, MobileRootTab.settings]);
  expect(mobileRootTabs(android: true, incomingOnly: false, outgoingOnly: true),
      [MobileRootTab.computers, MobileRootTab.settings]);
  expect(mobileRootTabs(android: true, incomingOnly: true, outgoingOnly: false),
      [MobileRootTab.share, MobileRootTab.settings]);
  expect(mobileRootTabs(android: false, incomingOnly: false, outgoingOnly: false),
      [MobileRootTab.computers, MobileRootTab.settings]);
});
```
  `home_page_shell_test.dart`: the two navigation-bar tests use three fake pages `Computers`, `Share`, `Settings`; tapping `Share` → `selected == 1`; `Chat` findsNothing.
  `share_chat_button_test.dart` (`tr: fakeTr`): `unread: 3` → tooltip `Chat`, text `3`, tap → `opens == 1`; `unread: 0` → no `0` text; 48 dp minimum size.
- [ ] **Step 2: Run** `flutter test test/home_page_shell_test.dart test/share_chat_button_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** the helpers, `openChat`, `MobileChatTitle`, the Share wiring and the `chat_model.dart` check.
- [ ] **Step 4: Run** the same command — Expected: PASS. `rg -n "as BottomNavigationBar" flutter/lib` — no matches. Analyzer clean on touched files.
- [ ] **Step 5: Commit** `feat(phone): Chat opens from Share instead of a tab`.

---

### Task 9: Settings regrouped, every row kept

**Files:**
- Create: `flutter/lib/mobile/widgets/settings_layout.dart`
- Modify: `flutter/lib/mobile/pages/settings_page.dart` (`build` :280-1050: tiles keyed by row id; `defaultDisplaySection` :1063-1078 becomes the `display-settings` tile; new `_networkExpanded` state)
- Test: `flutter/test/settings_layout_test.dart` (new)

**Interfaces:**
- Produces:
  - `enum SettingsGroup { account, appearance, displayDefaults, sharing, security, network, recording, about }` with titles (keys) `Account`, `Appearance`, `Display defaults`, `Sharing this phone`, `Security`, `Network`, `Recording`, `About Aperture`.
  - `const Map<SettingsGroup, List<String>> kMobileSettingsLayout` (row ids, in order):
    - account: `account`
    - appearance: `appearance`, `language`
    - displayDefaults: `display-settings`, `hwcodec`, `keep-awake-outgoing`, `note-at-conn-end`, `terminal-extra-keys`
    - sharing: `background-service`, `start-on-boot`, `floating-window`, `keep-screen-on`, `deny-lan-discovery`, `ip-whitelisting`, `id-whitelisting`, `adaptive-bitrate`, `enable-recording-session`, `direct-ip-access`, `auto-disconnect`
    - security: `2fa`, `telegram-bot`, `trusted-devices`, `manage-trusted-devices`
    - network: `id-relay-server`, `proxy`, `deploy`, `websocket`, `insecure-tls-fallback`, `disable-udp`, `tcp-punch`, `udp-punch`, `ipv6-punch`, `webrtc`
    - recording: `auto-record-incoming`, `auto-record-outgoing`, `recording-directory`
    - about: `version`, `build-date`, `fingerprint`, `my-id`, `privacy-statement`, `built-on-rustdesk` (new, non-interactive `SettingsTile(title: Text(tr('Built on RustDesk')))`)
  - `List<AbstractSettingsSection> buildMobileSettingsSections({required Map<String, AbstractSettingsTile> rows, required bool networkExpanded, required VoidCallback onToggleNetwork, String Function(String) tr = translate})` — groups in enum order, rows in layout order, groups with no present row skipped; the network group starts with a toggle tile `Advanced` (description `Server, proxy and connection options`, trailing `Icons.expand_more`/`expand_less`) and lists its rows only when `networkExpanded`; any row id missing from the layout is appended in a final section `Other` so nothing disappears.
- settings_page: `customClientSection` stays first, before the grouped sections. Each existing tile is put into `rows` under exactly the condition that showed it before — its own condition **and** its old section's condition: `2fa`/`telegram-bot`/`trusted-devices`/`manage-trusted-devices`, the seven share-screen rows and the five enhancement rows need `isAndroid && !disabledSettings && !outgoingOnly && !hideSecuritySettings`; `hwcodec` and the recording rows need `isAndroid`; `display-settings` needs `!bind.isIncomingOnly()`; `account` needs `!bind.isDisableAccount()`; rows of the old "Settings" and "About" sections keep their own conditions. Option keys, getters and setters are untouched. `_networkExpanded` defaults to false.

- [ ] **Step 1: Write the failing tests** in `settings_layout_test.dart` (rows are `SettingsTile(title: Text(id))`; pump `SettingsList(sections: buildMobileSettingsSections(..., tr: fakeTr))` under the dark Studio theme):

```dart
const prePhase2Rows = [
  'account', 'appearance', 'language', 'display-settings', 'hwcodec', 'keep-awake-outgoing',
  'note-at-conn-end', 'terminal-extra-keys', 'background-service', 'start-on-boot', 'floating-window',
  'keep-screen-on', 'deny-lan-discovery', 'ip-whitelisting', 'id-whitelisting', 'adaptive-bitrate',
  'enable-recording-session', 'direct-ip-access', 'auto-disconnect', '2fa', 'telegram-bot',
  'trusted-devices', 'manage-trusted-devices', 'id-relay-server', 'proxy', 'deploy', 'websocket',
  'insecure-tls-fallback', 'disable-udp', 'tcp-punch', 'udp-punch', 'ipv6-punch', 'webrtc',
  'auto-record-incoming', 'auto-record-outgoing', 'recording-directory', 'version', 'build-date',
  'fingerprint', 'my-id', 'privacy-statement',
];
test('every row from before Phase 2 has exactly one place', () {
  final placed = kMobileSettingsLayout.values.expand((ids) => ids).toList();
  for (final id in prePhase2Rows) {
    expect(placed.where((p) => p == id).length, 1, reason: id);
  }
  expect(placed.toSet().difference(prePhase2Rows.toSet()), {'built-on-rustdesk'});
});
```
  - `groups follow the spec order and skip empty ones`: all ids, expanded → section titles in `dy` order `Account`, `Appearance`, `Display defaults`, `Sharing this phone`, `Security`, `Network`, `Recording`, `About Aperture`; only `appearance` + `version` → two sections.
  - `network rows stay folded until Advanced is opened`: collapsed → `Advanced` found, `websocket` and `id-relay-server` nothing; tap `Advanced` → `toggles == 1`; expanded → the ten network ids in layout order (`dy`).
  - `a row the layout does not know is still shown`: `rows` plus `mystery` → `Other` and `mystery` found.
  - `rows that are absent stay absent`: `rows` without `terminal-extra-keys` → not found, `Display defaults` still shown with its other rows.
  - `settings fit 360 dp at 1.3 text scale`: all rows, expanded → no exception.
- [ ] **Step 2: Run** `flutter test test/settings_layout_test.dart` — Expected: compile FAIL.
- [ ] **Step 3: Implement** the layout file and the `settings_page.dart` keyed build.
- [ ] **Step 4: Run** the same plus `test/studio_inherited_surfaces_test.dart` — Expected: PASS. Cross-check that no tile was dropped: `git diff -- flutter/lib/mobile/pages/settings_page.dart | rg "^-.*(SettingsTile|kOption)"` — every removed line reappears as an added line (moved, not deleted). Analyzer clean.
- [ ] **Step 5: Commit** `feat(phone): settings grouped by purpose; network options folded`.

---

### Task 10: Translation keys, full verification and release build

**Files:**
- Modify: `src/lang/template.rs` and every other `src/lang/*.rs` (append only), `tools/aperture-release.json`

**Interfaces:**
- Consumes: every `tr(...)`/`translate(...)` key added in Tasks 3–9.
- Produces: keys in all language files; version `1.8.0` / `4115`; an APK under `target/aperture-release-1.8.0/`.

Keys (skip any already in `template.rs`; `Connect`, `Connection`, `Chat`, `Security`, `Network`, `Other`, `Exit`, and Phase 1's `PC`, `Live`, `Problem`, `Reconnect`, `Try again`, `Waiting for preview`, `PC screens`, `View only`, `Open` exist):
`Screens`, `This PC`, `System and processes`, `PC status, processes and host controls`, `Files`, `Browse and transfer files`, `PowerShell`, `Open the authenticated remote terminal`, `Quality and connection`, `Direct or relay route, latency and stream health`, `Privacy and host controls`, `This phone is trusted`, `Connects without a password`, `Forget`, `Trust this phone`, `Connect without a password at home`, `App`, `Appearance and settings`, `System, light or dark mode and more`, `End session`, `Session still connected. End it from the PC tab.`, `Trust this phone on {}?`, `Next time it connects without a password.`, `Trust`, `Not now`, `This phone connects without a password at home`, `Pairing failed`, `Windows`, `No screens from {} yet`, `Switch view`, `Switch`, `Clipboard`, `Quality`, `Hide toolbar`, `Online`, `Offline`, `Trusted · connects without password`, `Connecting…`, `Couldn't connect to {}`, `Add another computer`, `Add a computer`, `Saved computers`, `Appearance`, `Display defaults`, `Sharing this phone`, `Advanced`, `Server, proxy and connection options`, `About Aperture`, `Built on RustDesk`.

- [ ] **Step 1: Cross-check the list against the code.** `git diff 6c62a977c..HEAD -- flutter/lib | rg -o "(tr|translate)\((['\"]).*?\2"` — every literal key is in the list above or already in `template.rs`; add any that is not.
- [ ] **Step 2: Append the keys** with a throwaway script in the session scratchpad (not committed), exactly as Phase 1 Task 9 Step 2: insert `        ("<key>", ""),` before each file's closing `].iter().cloned().collect();`, escaping `"` and `\`, after making sure the previous last entry ends with a comma; `it.rs` gets `""`; `en.rs` untouched.
- [ ] **Step 3: Verify the lang diff.** `git diff --stat -- src/lang` lists every lang file except `en.rs`; `git diff -- src/lang | rg '^-[^-]'` shows only previous last entries gaining a trailing comma; `git diff -- src/lang/it.rs | rg '^\+' | rg -v '""\),$|^\+\+\+'` is empty.
- [ ] **Step 4: Full Flutter verification.** From `flutter/`: `flutter test` — Expected: the Task 1 baseline plus the new tests, minus the tests this plan deletes (Task 3 session-menu test; Task 5 row and chooser-cell tests, migrated), no failures. `flutter analyze lib/mobile lib/models lib/common/widgets/studio_theme.dart lib/main.dart` — no new issues against the baseline. `rg -n "MirpgRemoteTheme\.build\(|ConnectedPcSessionMenu|as BottomNavigationBar|_ScreenFilter|'Tools'" flutter/lib` — only `studio_theme.dart` for the first pattern, nothing else.
- [ ] **Step 5: Bump the version.** `tools/aperture-release.json`: `"version": "1.8.0"`, `"versionCode": 4115` (other fields unchanged).
- [ ] **Step 6: Confirm the native library can be reused.** Phase 2 changes no Rust; `git diff --stat 6c62a977c HEAD -- src libs Cargo.toml` shows only `src/lang/*.rs`, whose new entries are all `""` (untranslated keys fall back to the key text in the shipped library), so **no native rebuild is required**; translations arrive with the next native rebuild. Hash without building: `(Get-FileHash 'flutter\android\app\src\main\jniLibs\arm64-v8a\librustdesk.so' -Algorithm SHA256).Hash` in the checkout that builds the APK, and compare with `lib/arm64-v8a/librustdesk.so` inside `target\aperture-release-1.7.0\Aperture-1.7.0-android-arm64.apk` (read with `[IO.Compression.ZipFile]::OpenRead`; 1.7.0 shipped `663D8026…8FDB`). If they differ, stop and ask.
- [ ] **Step 7: Build the APK and stop.** The APK is built from a checkout with the staged jniLibs: this worktree after copying the gitignored `flutter/android/app/src/main/jniLibs/`, the Gradle wrapper and the `libs/hbb_common` working files from the main checkout (main checkout unmodified), as for 1.7.0. In PowerShell from that checkout's root, with `JAVA_HOME=C:\Program Files\Java\jdk-17` and Rust 1.75 / `~/.cargo/bin` on PATH:

```powershell
./tools/build_aperture_release.ps1 -NativeLibrarySha256 <hash from Step 6>
```
Expected: `Release APK: ...\target\aperture-release-1.8.0\Aperture-1.8.0-android-arm64.apk`, its SHA256, and `package: name='com.carriez.flutter_hbb.mirpgtest' versionCode='4115' versionName='1.8.0'`. **Do not install or run adb.** Report the APK path and hash and ask for the go-ahead to install, together with this on-device check list for after install: password and 2FA dialogs, wrong-password retry, "Connecting…" Cancel and an offline error (then the hero card's reason), the Share page and Chat from Share, the settings list in light and dark, the legacy remote page on a non-Aperture peer, the monitor view (Exit, Controls session tiles, view-only chip), the PC tab (End session, Files/PowerShell back, terminal still open on return), the pairing prompt once.
- [ ] **Step 8: Commit** `chore: Aperture 1.8.0 (one theme, one shell)` with `src/lang/*.rs` and `tools/aperture-release.json`.

---

## Self-review notes

- Spec coverage: §5 Phase 2 rows — palette move + re-export → Task 1; Studio at the root, wrappers removed → Task 2; Play/Screens/PC, PC tab absorbs the session menu, System/Files/PowerShell as back-arrow pages → Task 3; Screens monitors only, switcher grid → Task 5; monitor view top bar, exit in toolbar, session items into Controls, palette lookups → Task 6; Computers hero, ID field at the bottom, inline failure, Chat out of the tab bar, pairing prompt → Tasks 4, 7, 8; settings regrouping → Task 9. §3.8 status pill on every tab, real host name → Task 3. §5 risk list (M3 dialogs and settings list, the three tests named, password/2FA not bypassed) → Task 2, Global Constraints, Tasks 3/6/8.
- Phase 1 ledger items picked up: Screens tab list-failure feedback and list card showing non-list `model.error` (Task 5, `listError`); monitor-card labels untranslated / old vocabulary (Task 5); End session to the PC tab and Play app-bar "⋮" removal (Task 3). Out of scope (Phase 1 surfaces, not touched here): label sheet counter and zero-width characters, "Setting up…" placeholder lingering, header `0/0 running`, Rename/Clone enabled on a Starting tile, rail chip 40 dp height, "+" sheet stale states, `_dashboard()` skipping a refresh while a list is in flight, Show on PC without a control check, switch placeholder without an exit, legacy picker formatting.
- Deliberate deviations: sub-pages stay in the `IndexedStack` instead of being pushed (keeps terminal and file sessions alive; same look); the hero card does not replace the RustDesk "Connecting…" dialog (see Task 7); "Saved computers" keeps the address book and saved PCs one level down although Q7 removes the list from the page; the Account group stays first (the spec's group list does not mention it); Chat keeps the `isChatPageCurrentTab` name so `chat_model.dart:425` is unchanged; the monitor view keeps single back to its tab (Q2 is game-only).
- Found while planning: `server_page.dart:697` and `chat_model.dart:156` cast the navigation bar widget to `BottomNavigationBar`, which throws since the Studio `NavigationBar` replaced it; Task 8 removes both casts.
