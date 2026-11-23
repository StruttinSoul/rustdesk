# Remote View Keyboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every key from the phone's remote-view keyboard reach Windows, and keep the PC visible while typing.

**Architecture:** A small `MonitorKeySender` turns the strip's existing `onKey` / `onKeyState` callbacks into named-key events (`bind.sessionInputKey`) that carry the held Ctrl/Alt/Shift/Win as flags, replacing the `flutter_key` route that drops them. `MonitorControlView` stops shrinking the picture for the keyboard: while typing it hides its bars, overlays the key strip at the keyboard's top edge and pans so the last tap stays visible. The strip's compose button becomes a Shortcuts button.

**Tech Stack:** Flutter (Dart) phone app only; no Rust or host change.

**Spec:** `docs/superpowers/specs/2026-11-14-monitor-keyboard-design.md`

## Global Constraints

- No type-then-send box anywhere in the live keyboard path.
- Phone app only: no change to `src/`, `libs/` or the Windows host.
- Plain typing with no modifier held keeps using `sessionInputString` (unchanged).
- Modifier states keep their current cycle: Off → Once → Locked → Off; Once releases after the next key.
- Desktop client UI and the emulator (guest) view are untouched.
- Run Flutter tests from `flutter/`: `flutter test <file>`; analyzer: `flutter analyze <files>` must report no new issues in touched files.
- Do not run `dart format` on files you did not otherwise change; format only touched files (`emulator_model.dart`, `target_dashboard_page.dart` are not formatted today; keep their diffs minimal and do not reformat them).

## Review Focus

1. Modifier held while the session closes, the keyboard is dismissed by system Back, or the app is backgrounded: Windows must not be left with Ctrl/Alt/Shift/Win stuck down. (Task 1 `releaseAll`, Task 2 wiring.)
2. Win tapped alone (Once, then released with no other key): Start menu should open — a down then up of `Meta` with nothing between. (Task 1 test.)
3. Uppercase letter typed on Gboard while Ctrl is held (Ctrl+Shift+T style): one event with ctrl and shift both set. (Task 1 test.)
4. Tap near the bottom of the desktop while typing: the picture must be allowed to scroll above the keyboard even though that is beyond the normal pan limit. (Task 3 test.)
5. Rotating the phone or the keyboard height changing while open: pan recomputes, picture size stays at its pre-keyboard scale. (Task 3 test.)

---

### Task 1: Named-key sender

**Files:**
- Create: `flutter/lib/mobile/widgets/monitor_key_sender.dart`
- Test: `flutter/test/monitor_key_sender_test.dart`

**Interfaces:**
- Produces:
  - `typedef MonitorNamedKeySink = void Function(String name, {required bool down, required bool press, required bool alt, required bool ctrl, required bool shift, required bool command});`
  - `String? monitorKeyName(PhysicalKeyboardKey key)` — `escape→VK_ESCAPE`, `tab→VK_TAB`, `enter/numpadEnter→VK_RETURN`, `backspace→VK_BACK`, `delete→VK_DELETE`, `insert→VK_INSERT`, `home→VK_HOME`, `end→VK_END`, `pageUp→VK_PRIOR`, `pageDown→VK_NEXT`, arrows→`VK_LEFT/VK_UP/VK_RIGHT/VK_DOWN`, `space→VK_SPACE`, `f1…f12→VK_F1…VK_F12`, `controlLeft/Right→VK_CONTROL`, `altLeft/Right→VK_MENU`, `shiftLeft/Right→VK_SHIFT`, `metaLeft/Right→Meta`, letters `keyA…keyZ`→`'a'…'z'`, digits `digit0…digit9`→`'0'…'9'`; anything else `null`.
  - `class MonitorKeySender { MonitorKeySender(MonitorNamedKeySink sink); void tap(PhysicalKeyboardKey key); void setState(PhysicalKeyboardKey key, bool down); void releaseAll(); bool get hasHeld; }`
    - `tap`: one event `press: true, down: false` with the current held flags; unknown keys ignored.
    - `setState(modifier, true)`: if not already held, add to held and send `down: true, press: false` with flags that include it; `setState(modifier, false)`: if held, remove and send `down: false, press: false` with flags without it. Non-modifier keys: down sends `down: true`, up sends `down: false`, tracked in the same held set. Duplicates ignored.
    - Flags: `ctrl` = any held control key, `alt` = alt, `shift` = shift, `command` = meta.
    - `releaseAll`: sends an up for every held key (reverse order), clears.

- [ ] **Step 1: Write the failing tests** in `monitor_key_sender_test.dart`, recording sink calls as `(name, down, press, alt, ctrl, shift, command)`:
  - `maps strip keys to named keys`: `monitorKeyName(escape)=='VK_ESCAPE'`, `arrowLeft=='VK_LEFT'`, `pageDown=='VK_NEXT'`, `metaLeft=='Meta'`, `keyC=='c'`, `digit7=='7'`, `f5=='VK_F5'`, `PhysicalKeyboardKey.audioVolumeUp == null`.
  - `Ctrl then C sends c with ctrl`: `setState(controlLeft,true); tap(keyC)` → calls `[('VK_CONTROL',true,false,F,T,F,F), ('c',false,true,F,T,F,F)]`.
  - `Ctrl and Shift both apply`: `setState(controlLeft,true); setState(shiftLeft,true); tap(keyT)` → last call `('t',false,true,F,T,T,F)`.
  - `Win alone is a down then up`: `setState(metaLeft,true); setState(metaLeft,false)` → `[('Meta',true,false,F,F,F,T), ('Meta',false,false,F,F,F,F)]`.
  - `Backspace and Enter are named`: `tap(backspace)`, `tap(enter)` → names `VK_BACK`, `VK_RETURN`, `press: true`.
  - `releaseAll lifts every held key`: hold ctrl+alt, `releaseAll()` → two `down:false` calls (alt then ctrl), `hasHeld == false`.
  - `duplicate down is ignored`: two `setState(controlLeft,true)` → one call.

- [ ] **Step 2: Run** `flutter test test/monitor_key_sender_test.dart` — Expected: FAIL (file/types missing).
- [ ] **Step 3: Implement** `monitor_key_sender.dart` per the Interfaces block.
- [ ] **Step 4: Run** `flutter test test/monitor_key_sender_test.dart` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(flutter): named-key sender for the remote keyboard`.

### Task 2: Send remote-view keys through the named-key sender

**Files:**
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_monitorTapKey` ~1851, `_monitorKeyState` ~1859, the `MonitorKeyboardPanel` `onKey`/`onKeyState` in `_monitorKeyboard` ~1894–1946, `_releaseMonitorInput` ~1985–1995, field `_monitorHeldKeys`)

**Interfaces:**
- Consumes: `MonitorKeySender`, `MonitorNamedKeySink` (Task 1).
- Produces: nothing new for later tasks.

- [ ] **Step 1:** Add a `late final MonitorKeySender _monitorKeys` whose sink calls `bind.sessionInputKey(sessionId: widget.ffi.sessionId, name:…, down:…, press:…, alt:…, ctrl:…, shift:…, command:…)`.
- [ ] **Step 2:** `_monitorTapKey(key, index)`: keep the `_canControlMonitor` guard, then `_monitorKeys.tap(key)` (drop the 12 ms down/up).
- [ ] **Step 3:** `_monitorKeyState(key, down, index)` and the panel's `onKeyState`: keep their guards, then `_monitorKeys.setState(key, down)`. Remove `_monitorHeldKeys`; the panel's `onKey` uses the same path as `_monitorTapKey`.
- [ ] **Step 4:** `_releaseMonitorInput`: replace the `_monitorHeldKeys` loop with `_monitorKeys.releaseAll()`.
- [ ] **Step 5:** Verify no `kKeyFlutterKey` use remains in this file: `grep -n kKeyFlutterKey lib/mobile/pages/target_dashboard_page.dart` — Expected: no output. Run `flutter analyze lib/mobile/pages/target_dashboard_page.dart` — Expected: no issues. Run `flutter test test/monitor_control_view_test.dart test/monitor_key_sender_test.dart` — Expected: all pass.
- [ ] **Step 6: Commit** `fix(flutter): remote keyboard keys reach Windows`.

### Task 3: Keyboard overlays the picture and the view follows the last tap

**Files:**
- Modify: `flutter/lib/mobile/widgets/monitor_control_view.dart` (`build` ~2007–2063, `_remoteViewport`, `_limitOffset` ~973, `_sessionTopBar` ~1758)
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_monitor` Scaffold ~1515: `resizeToAvoidBottomInset: false`)
- Test: `flutter/test/monitor_control_view_test.dart`

**Interfaces:**
- Produces: top-level `double monitorKeyboardPanDy({required double offsetDy, required double scale, required double tapDesktopY, required double visibleHeight, double margin = 24})` — returns the new `offset.dy` so the tap's screen y (`offsetDy + tapDesktopY * scale`) lies within `[margin, visibleHeight - margin]`; unchanged when it already does.

- [ ] **Step 1: Write the failing tests** in `monitor_control_view_test.dart` (open the live keyboard via the Keyboard toolbar button with `onTextInput`, `onKeyTap`, `onKeyState` provided; simulate the phone keyboard with `tester.view.viewInsets = FakeViewPadding(bottom: 300)`):
  - `pan keeps a low tap above the keyboard`: `monitorKeyboardPanDy(offsetDy: 0, scale: 1, tapDesktopY: 500, visibleHeight: 300) == 300 - 24 - 500`.
  - `pan leaves a visible tap alone`: `monitorKeyboardPanDy(offsetDy: 0, scale: 1, tapDesktopY: 100, visibleHeight: 300) == 0`.
  - `pan brings a tap above the top back down`: `monitorKeyboardPanDy(offsetDy: -400, scale: 1, tapDesktopY: 100, visibleHeight: 300) == 24 - 100`.
  - `typing hides the top bar and keeps the picture size`: record `tester.getSize(frame)` before; open keyboard with insets → `find.byKey(ValueKey('monitor-top-bar'))` findsNothing and frame size unchanged.
  - `key strip sits on the phone keyboard`: with insets 300, the bottom of `MonitorLiveKeyboardBar` equals surface height − 300.
  - `tap near the bottom scrolls above the keyboard`: tap at the bottom 10% of the surface with the keyboard open → the tapped desktop point's screen y < surface height − 300 − strip height.
  - `keyboard height change re-pans without rescaling`: change insets 300 → 200 → frame size unchanged and last tap still above the strip.
  - `closing the keyboard restores the top bar`.
- [ ] **Step 2: Run** `flutter test test/monitor_control_view_test.dart` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement**:
  - `ValueKey('monitor-top-bar')` on `_sessionTopBar`'s `Material`.
  - In `build`, when the live keyboard is open: no top bar, no side rails, no bottom toolbar; `_remoteViewport()` fills the box; `_liveKeyboardBar()` in a `Positioned(left: 0, right: 0, bottom: MediaQuery.viewInsetsOf(context).bottom)` over it.
  - Keep `_fit`/`_zoom` from before opening (the viewport is not resized by the keyboard because the page Scaffold no longer resizes).
  - Track `_keyboardReserve` (insets bottom + strip height, measured after layout). `_limitOffset` lets `dy` go down to `_viewport.height - _keyboardReserve - height` while the keyboard is open.
  - On keyboard open, on each tap while open, and when insets change: `_offset = Offset(_offset.dx, monitorKeyboardPanDy(offsetDy: _offset.dy, scale: _scale, tapDesktopY: _pointer.dy, visibleHeight: _viewport.height - _keyboardReserve))`, then `_limitOffset()`. A one-finger drag while open is kept until the next tap.
  - Page `_monitor` Scaffold: `resizeToAvoidBottomInset: false`.
- [ ] **Step 4: Run** `flutter test test/monitor_control_view_test.dart` — Expected: all pass (existing 41 plus new).
- [ ] **Step 5: Commit** `feat(flutter): keyboard overlays the remote view and follows the last tap`.

### Task 4: Shortcuts button replaces compose

**Files:**
- Modify: `flutter/lib/mobile/widgets/monitor_live_keyboard.dart` (`onCompose` → `onShortcuts`, button ~578: tooltip `'Shortcuts'`, icon `Icons.bolt_outlined`)
- Modify: `flutter/lib/mobile/widgets/monitor_control_view.dart` (extract `_showShortcutSettings` from `_MonitorKeyboardPanelState` ~603 into top-level `Future<void> showMonitorShortcutSettings(BuildContext context, {required List<MonitorShortcutPreset> shortcuts, required ValueChanged<List<MonitorShortcutPreset>> onChanged})`; the panel calls it; `_compose` is removed and `_liveKeyboardBar` passes `onShortcuts` that opens it with `_shortcuts` and saves through `_emitPreferences`)
- Test: `flutter/test/monitor_control_view_test.dart`

- [ ] **Step 1: Write the failing tests**:
  - `live keyboard has no compose button`: open live keyboard → `find.byTooltip('Compose text')` findsNothing.
  - `Shortcuts opens shortcut presets and saves edits`: tap `find.byTooltip('Shortcuts')` → `find.text('Shortcut presets')` findsOneWidget; reset or reorder one preset → `onPreferencesChanged` received the new shortcut list.
- [ ] **Step 2: Run** `flutter test test/monitor_control_view_test.dart` — Expected: new tests FAIL.
- [ ] **Step 3: Implement** per Files.
- [ ] **Step 4: Run** `flutter test test/monitor_control_view_test.dart test/monitor_key_sender_test.dart` and `flutter analyze` on the touched files — Expected: all pass, no issues.
- [ ] **Step 5: Commit** `feat(flutter): Shortcuts replaces compose on the remote keyboard`.

### Task 5: Build and check on the phone

- [ ] **Step 1:** Bump `tools/aperture-release.json` to `1.5.7` / `4110`; build with `tools/build_aperture_release.ps1 -NativeLibrarySha256 <current jniLibs hash>` (Rust 1.75 and `~/.cargo/bin` on PATH, `JAVA_HOME=C:\Program Files\Java\jdk-17`). The native library is unchanged from 1.5.6.
- [ ] **Step 2:** With the user's go-ahead, install on the phone and check against atlas in landscape: Ctrl+C / Ctrl+V in Notepad, Alt+Tab, Win alone opens Start, arrows, Backspace, Enter, Esc; the PC stays visible above the strip while typing; Shortcuts opens presets.
- [ ] **Step 3: Commit** `chore: Aperture 1.5.7`.
