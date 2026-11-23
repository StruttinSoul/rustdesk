# Aperture UI Phase 1: emulator and game flow (phone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the connected phone Home a "Play" grid of every emulator with one state vocabulary, a bottom-sheet action menu, a phone-side label per emulator, a visible startup checklist and failure screen, and an in-game play rail with account chips, a name banner and double-back.

**Architecture:** A pure state function (`emulatorUiState`) and a local label store sit in `flutter/lib/models/`. New stateless widgets (`EmulatorTile`, `EmulatorRow`, `EmulatorActionSheet`, `PlayTabBody`, `StartupChecklist`, `PlayRail`) live in `flutter/lib/mobile/widgets/` and take every string through an injected `tr` so they can be pumped in tests without the native bridge. `TargetDashboardPage` builds view-models from `EmulatorModel` and wires callbacks; `EmulatorPage` gains the rail, checklist and back handling. No protocol, Rust logic or package changes.

**Tech Stack:** Flutter 3.24.5 (Dart 3.5), Material 3 Studio theme (`MirpgRemoteTheme`), `flutter_test`. Lang keys in `src/lang/*.rs` (data only).

**Spec:** `docs/superpowers/specs/2026-11-16-aperture-ui-redesign.md` (§3.1–3.4, §3.6, §4, §5 Phase 1, §7). Visual reference: `docs/superpowers/specs/mockups/2026-11-16-aperture-ui-redesign.html` frames 1a, 1a′, 1b, 1c, 1d, 1e, 1f, 1f′, 1g, 1g′.

## Global Constraints

- Work only in `flutter/lib/mobile/`, `flutter/lib/models/`, `flutter/test/`, `src/lang/*.rs` (keys only, Task 9) and `tools/aperture-release.json` (Task 9). No Rust logic, no `libs/hbb_common` change, no new pubspec dependency, no wire-protocol change.
- Tests: run from `flutter/` with the repo's SDK, `C:/DevTools/flutter-3.24.5/bin/flutter.bat test <file>` (on PATH as `flutter`). Analyzer: `flutter analyze <touched files>` must add no new issues.
- **Strings:** every new or reworded user-visible string goes through translate. Widgets that tests pump take `final String Function(String) tr` defaulting to the global `translate` (pattern: `ApertureHostPanel.translate`); pages call `translate()` directly. Tests pass `tr: fakeTr` from `flutter/test/support/fake_translate.dart` (Task 1). Keys are sentence case and are the English text. A value goes in a single `{}` placeholder, written in Dart as `tr('Couldn\'t start {$name}')` (translate supports one placeholder per string). PC messages and emulator names are never passed to `tr` as keys.
- Keys are added once, in Task 9, per `docs/agents/LOCALIZATION.md`: append to `template.rs` and every `src/lang/*.rs` with `""`; `it.rs` always `""` (hand-maintained Italian, never edit existing entries); no `en.rs` entry when key == English text; skip keys already present in `template.rs`.
- Vocabulary (spec §3.1, only these words): Emulator; Start; Open; Stop; Reconnect; Show on PC / Hide on PC; states Live, Starting, Stopped, Stopping, Copying n%, Problem; grid tab **Play**.
- Studio values: 8 dp rhythm, 16 dp page margin, radii 12/16/24, min touch target 48 dp (`MirpgRemoteTheme` constants); over video always the dark palette (`MirpgStatusChip(onDarkSurface: true)`); names `titleMedium`, state `labelMedium` w600, never below 12 sp. Destructive fill `#B43E43` (new `MirpgRemoteTheme.destructiveFill`).
- Decisions binding from spec §7: start one, go back, start the next (no new PC action); press back twice to leave a game; 4 emulators, portrait and landscape both first-class; phone-side label per emulator stored locally, shown on tiles, chips and banner, emulator name stays the secondary line; tap just opens, "Open and launch game" is a separate sheet row.
- Preserve working remote-control paths: `mapEmulatorTouch`, multi-touch, key and text paths are not changed; `didChangeMetrics` pointer cancel stays.
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
- Do not install on the phone, run adb, push, or open a PR. Task 9 builds the APK and stops; installing needs the user's go-ahead.
- The app must build and keep working after every task; commit each task separately on `feature/android-emulator-remote` (or a branch cut from it).

## Review Focus

1. **Leaving the startup screen before the next list refresh:** the tile must read "Starting", not "Stopped", so a second tap does not look like a fresh start (pinned in Task 1 `startRequested` row, wired in Task 5).
2. **Label input edge cases:** whitespace-only clears the label; 200-character or emoji labels are cut to 32 user-perceived characters without splitting an emoji; `{`/`}` are removed so translate's placeholder never captures label text (Task 2).
3. **Label identity across management:** rename moves the label to the new id, delete clears it, and a new emulator re-using a deleted name does not inherit the old label (Task 2 store tests, Task 5 wiring).
4. **Rail flicker near the fit threshold:** small viewport changes (system bars, IME, 1–15 dp) must not toggle docked/collapsed (Task 7 hysteresis test).
5. **Rapid switching:** a second chip tap while a switch is connecting is ignored, and a switch to an emulator with no cached frame shows the name on black without errors (Task 7 tests).

---

## File map

| File | Responsibility | Task |
|---|---|---|
| `flutter/lib/models/emulator_model.dart` | add `EmulatorUiWord`, `EmulatorUiState`, `EmulatorUiFlags`, `emulatorUiState()` next to `runtimeLabel` | 1 |
| `flutter/test/support/fake_translate.dart` (new) | `fakeTr` mirroring the Rust untranslated fallback | 1 |
| `flutter/lib/models/emulator_labels.dart` (new) | `EmulatorLabelStore`, `normalizeEmulatorLabel` | 2 |
| `flutter/lib/mobile/widgets/avd_manage_sheets.dart` | label sheet, New/Clone sheet with label field, Delete dialog copy + red | 2 |
| `flutter/lib/mobile/widgets/mirpg_remote_theme.dart` | `MirpgRemoteTheme.destructiveFill` | 2 |
| `flutter/lib/mobile/widgets/emulator_tile.dart` (new) | `EmulatorTileData`, `EmulatorTile`, `EmulatorRow`, `EmulatorStateBadge`, `emulatorStateTone` | 3 |
| `flutter/lib/mobile/widgets/emulator_action_sheet.dart` (new) | `EmulatorActionSheet`, `showEmulatorActionSheet` | 4 |
| `flutter/lib/mobile/widgets/play_tab.dart` (new) | `PlayTabBody`, `playTabPreviewIds` | 5 |
| `flutter/lib/mobile/pages/target_dashboard_page.dart` | wiring: Play grid, previews, labels, sheets, rail callbacks, retire guest card branches | 2, 5, 7, 8 |
| `flutter/lib/mobile/widgets/session_quality_panel.dart` | `SessionStatusButton.compact`; drop "RustDesk" from profile copy | 5, 8 |
| `flutter/lib/mobile/widgets/startup_checklist.dart` (new) | `StartupChecklist`, `SwitchPlaceholder`, `startupStepIndex`, `formatElapsed` | 6 |
| `flutter/lib/mobile/widgets/play_rail.dart` (new) | `PlayRailPlacement`, `playRailPlacement`, `PlayAccount`, `PlayRail`, `NameBannerController`, `GuestNameBanner` | 7 |
| `flutter/lib/mobile/pages/emulator_page.dart` | checklist/failure/placeholder states, rail in `GuestControlStage`, banner, `DoubleBackGuard`, copy fixes | 6, 7, 8 |
| `src/lang/*.rs`, `tools/aperture-release.json` | keys; 1.7.0 / 4114 | 9 |

---

### Task 1: Emulator UI state mapping

**Files:**
- Modify: `flutter/lib/models/emulator_model.dart` (after `class RemoteEmulator`, ~line 112)
- Create: `flutter/test/support/fake_translate.dart`
- Test: `flutter/test/emulator_ui_state_test.dart` (new)

**Interfaces:**
- Produces:
  - `enum EmulatorUiWord { live, starting, stopped, stopping, copying, problem }`
  - `class EmulatorUiState { const EmulatorUiState(this.word, this.label, {this.causeKey = '', this.pcMessage = ''}); final EmulatorUiWord word; final String label; final String causeKey; final String pcMessage; bool get canOpen; bool get hasCause; }` — `label` and `causeKey` are translate keys (label may carry one `{value}`); `pcMessage` is the PC's text, shown verbatim and preferred over `causeKey`. `canOpen` is false for `stopping` and `copying`.
  - `class EmulatorUiFlags { const EmulatorUiFlags({this.frameCurrent = false, this.shuttingDown = false, this.startRequested = false, this.guestFailure = ''}); }`
  - `EmulatorUiState emulatorUiState(RemoteEmulator instance, {RemotePreview? preview, EmulatorUiFlags flags = const EmulatorUiFlags()})`
  - `String fakeTr(String key)` (test support)

State mapping (first matching row wins; tone is applied in Task 3 by `emulatorStateTone`):

| # | Condition | word | label | tone | cause |
|---|---|---|---|---|---|
| 1 | `flags.shuttingDown` or `state == 'stopping'` | stopping | `Stopping` | neutral | – |
| 2 | `state == 'shutdown_failed'` | problem | `Problem` | error | pcMessage `instance.error`, else causeKey `Couldn't stop` |
| 3 | `state == 'cloning'` | copying | `Copying {p}%`, p = `progressPercent.clamp(0, 100)` | neutral | – |
| 4 | `flags.guestFailure` non-empty or `preview?.state == 'failed'` | problem | `Problem` | error | pcMessage `preview.error` if non-empty, else `guestFailure`; causeKey `Stream stopped` |
| 5 | `state == 'stopped'` and `flags.startRequested` | starting | `Starting` | warning | – |
| 6 | `state == 'stopped'` | stopped | `Stopped` | neutral | pcMessage `instance.error` (e.g. a failed copy) |
| 7 | `state` is `booting` or `starting` | starting | `Starting` | warning | – |
| 8 | `state == 'adb_offline'` | problem | `Problem` | error | causeKey `Android not responding`, pcMessage `instance.error` |
| 9 | `state` is `ready`/`running`, `preview?.state == 'streaming'`, `!flags.frameCurrent` | problem | `Problem` | error | causeKey `Stream stopped` |
| 10 | `state` is `ready`/`running` | live | `Live` | good | – (a running emulator without a preview slot still reads Live, spec §3.2) |
| 11 | anything else | problem | `Problem` | error | causeKey `Status unavailable`, pcMessage `instance.error` |

- [ ] **Step 0: Record the baseline.** From `flutter/`: `flutter test` (whole suite). Write the pass/fail counts and any pre-existing failures into the task's commit message; later tasks compare against it.

- [ ] **Step 1: Write the failing tests** in `flutter/test/emulator_ui_state_test.dart`, one `test()` per table row plus:

```dart
RemoteEmulator emu(String state, {String error = '', int progress = 0}) => RemoteEmulator(
    id: 'avd:Main', name: 'Main', provider: 'avd', state: state, error: error, progressPercent: progress);

test('stopping wins over every other signal', () {
  final s = emulatorUiState(emu('running'), flags: const EmulatorUiFlags(shuttingDown: true, guestFailure: 'x'));
  expect(s.word, EmulatorUiWord.stopping);
  expect(s.canOpen, isFalse);
});
test('copying clamps the percentage', () {
  expect(emulatorUiState(emu('cloning', progress: 140)).label, 'Copying {100}%');
  expect(fakeTr(emulatorUiState(emu('cloning', progress: 42)).label), 'Copying 42%');
});
test('start requested before the list refreshes reads Starting', () {
  final s = emulatorUiState(emu('stopped'), flags: const EmulatorUiFlags(startRequested: true));
  expect(s.word, EmulatorUiWord.starting);
});
test('a failed start on a stopped emulator is a Problem with the PC message', () {
  final s = emulatorUiState(emu('stopped'), flags: const EmulatorUiFlags(guestFailure: 'Boot timed out'));
  expect((s.word, s.pcMessage, s.causeKey), (EmulatorUiWord.problem, 'Boot timed out', 'Stream stopped'));
});
test('running without a preview slot is Live', () {
  expect(emulatorUiState(emu('running')).word, EmulatorUiWord.live);
});
test('stalled preview is a Problem, current frame is Live', () {
  const p = RemotePreview('avd:Main', 7, 'streaming', 1080, 1920, '');
  expect(emulatorUiState(emu('running'), preview: p).word, EmulatorUiWord.problem);
  expect(emulatorUiState(emu('running'), preview: p, flags: const EmulatorUiFlags(frameCurrent: true)).word, EmulatorUiWord.live);
});
test('unknown state never reads Unknown', () {
  final s = emulatorUiState(emu(''));
  expect((s.word, s.causeKey), (EmulatorUiWord.problem, 'Status unavailable'));
});
```
Rows 2, 6, 7 (`booting` and `starting`), 8 get one test each asserting `word`, `label`, `causeKey`, `pcMessage`.

`flutter/test/support/fake_translate.dart`:

```dart
/// Mirrors the Rust fallback for an untranslated key: `{value}` becomes value.
String fakeTr(String key) => key.replaceFirstMapped(RegExp(r'\{(.*?)\}'), (m) => m[1]!);
```

- [ ] **Step 2: Run** `flutter test test/emulator_ui_state_test.dart` — Expected: compile FAIL (`emulatorUiState` undefined).
- [ ] **Step 3: Implement** the four declarations in `emulator_model.dart` as a pure function with a `switch`/`if` chain in the table's order. Leave `runtimeLabel` in place (used by the legacy picker until Task 8).
- [ ] **Step 4: Run** the same command — Expected: PASS. Then `flutter test test/emulator_model_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone): one emulator state mapping for every surface`.

---

### Task 2: Phone-side labels and management sheets

**Files:**
- Create: `flutter/lib/models/emulator_labels.dart`
- Modify: `flutter/lib/mobile/widgets/avd_manage_sheets.dart`, `flutter/lib/mobile/widgets/mirpg_remote_theme.dart` (add `static const destructiveFill = Color(0xFFB43E43);` to `MirpgRemoteTheme`), `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_newAvd`, `_cloneAvd`, `_renameAvd`, `_deleteAvd`, `_toggleAvdWindow`, `_reportAvdResult`, `showEmulatorShutdownConfirmation`, state init)
- Test: `flutter/test/emulator_labels_test.dart` (new), `flutter/test/avd_manage_sheets_test.dart`, `flutter/test/emulator_shutdown_test.dart`

**Interfaces:**
- Consumes: `fakeTr` (Task 1).
- Produces:
  - `const kEmulatorLabelMaxLength = 32;`
  - `String normalizeEmulatorLabel(String raw)` — trim, collapse runs of whitespace to one space, remove `{`, `}` and control characters, cut to 32 `characters` (grapheme clusters, via `package:flutter/widgets.dart`'s `characters`).
  - `class EmulatorLabelStore extends ChangeNotifier { EmulatorLabelStore({required String peerId, required String Function(String key) read, required Future<void> Function(String key, String value) write}); static String storageKey(String peerId, String emulatorId) => 'aperture-emulator-label:$peerId:$emulatorId'; String labelFor(String emulatorId); String displayName(String emulatorId, String emulatorName); Future<void> setLabel(String emulatorId, String label); Future<void> clearLabel(String emulatorId); Future<void> moveLabel(String fromId, String toId); }` — reads lazily and caches; `setLabel` normalizes and writes `''` to clear; notifies on change.
  - `Future<String?> showEmulatorLabelSheet(BuildContext context, {required String emulatorName, required String currentLabel, String Function(String) tr = translate})` — returns the normalized label (`''` = cleared) or null if dismissed.
  - `typedef AvdCreateResult = ({String name, String label});`
  - `Future<AvdCreateResult?> showAvdCreateSheet(BuildContext context, {required String title, required String initialName, required String note, required bool Function(String) isTaken, String confirmLabel = 'Create', String Function(String) tr = translate})` — the existing `_AvdNameSheet` with a `withLabel` flag adding an optional "Label (optional)" field and helper "Shown on this phone only". `showAvdNameSheet` keeps its signature (Rename).
  - `confirmAvdDelete(BuildContext, String name, {String Function(String) tr = translate})` and `showEmulatorShutdownConfirmation(BuildContext, String name, {String Function(String) tr = translate})` with new copy.
- Copy: Delete — title `Delete {name}?`, body `Deletes {name} and everything in it, including the game sign-in. This can't be undone.`, buttons Cancel / Delete (filled, `destructiveFill`, white label). Stop — title `Stop {name}?`, body `Apps running in it will close.`, buttons Cancel / Stop (filled, `destructiveFill`). Label sheet — title `Label for {emulatorName}`, field label `Label`, buttons `Clear label` (text, only when a label exists), Cancel, `Save`.
- Dashboard wiring: `late final EmulatorLabelStore _labels = EmulatorLabelStore(peerId: widget.ffi.id, read: (k) => bind.getLocalFlutterOption(k: k), write: (k, v) => bind.setLocalFlutterOption(k: k, v: v));` listened to with `setState`. New and Clone use `showAvdCreateSheet`; on `ok`: New → `_labels.setLabel('avd:$name', label)`, Clone → `_labels.setLabel('avd:$newName', label)`; Rename ok → `moveLabel(oldId, 'avd:$newName')`; Delete ok → `clearLabel(id)`. `_reportAvdResult(result, {required String success})` shows the PC's message on failure (unchanged) and on success a 2 s snackbar: `Created {name}`, `Copied to {name}`, `Renamed to {name}`, `Deleted {name}`, `Shown on the PC` / `Hidden on the PC`. New also shows `Setting up {name} on the PC` immediately after the sheet closes. Confirmation dialogs receive the display name; when a label is set it is `"$label ($emulatorName)"`.

- [ ] **Step 1: Write the failing tests.**

`emulator_labels_test.dart`:

```dart
EmulatorLabelStore store(Map<String, String> disk) => EmulatorLabelStore(
    peerId: '123', read: (k) => disk[k] ?? '', write: (k, v) async => disk[k] = v);

test('normalize trims, collapses, strips braces and control characters', () {
  expect(normalizeEmulatorLabel('  Alt  {EU}\n '), 'Alt EU');
  expect(normalizeEmulatorLabel('   '), '');
});
test('normalize cuts to 32 characters without splitting an emoji', () {
  final out = normalizeEmulatorLabel('👍🏽' * 40);
  expect(out.characters.length, 32);
  expect(out, '👍🏽' * 32);
});
test('label is stored per PC and emulator and shown instead of the name', () async {
  final disk = <String, String>{};
  final s = store(disk);
  await s.setLabel('avd:Maple_1', 'Main');
  expect(disk[EmulatorLabelStore.storageKey('123', 'avd:Maple_1')], 'Main');
  expect(s.displayName('avd:Maple_1', 'Maple_1'), 'Main');
  expect(s.displayName('avd:Maple_2', 'Maple_2'), 'Maple_2');
});
test('rename moves the label and delete clears it', () async {
  final disk = <String, String>{};
  final s = store(disk);
  await s.setLabel('avd:A', 'Main');
  await s.moveLabel('avd:A', 'avd:B');
  expect((s.labelFor('avd:A'), s.labelFor('avd:B')), ('', 'Main'));
  await s.clearLabel('avd:B');
  expect(store(disk).labelFor('avd:B'), '', reason: 'a re-created emulator must not inherit it');
});
test('whitespace-only label clears', () async {
  final s = store({});
  await s.setLabel('avd:A', 'Main');
  await s.setLabel('avd:A', '  ');
  expect(s.labelFor('avd:A'), '');
});
```
Widget tests (same file): `label sheet returns the normalized label, Clear label returns empty, dismiss returns null` — pump a button opening `showEmulatorLabelSheet(..., tr: fakeTr)`, enter `' Alt 1 (EU) '`, tap `Save` → result `'Alt 1 (EU)'`; reopen with `currentLabel: 'Main'`, tap `Clear label` → `''`; reopen, tap outside → `null`.

`avd_manage_sheets_test.dart`: keep the five existing tests; update `delete dialog returns true only on Delete` to pass `tr: fakeTr` and expect body `Deletes Phone 2 and everything in it, including the game sign-in. This can't be undone.` and `tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).style!.backgroundColor!.resolve({})` == `MirpgRemoteTheme.destructiveFill`. Add `create sheet returns name and optional label` (enter name `Alt_2`, label `' Main '` → `(name: 'Alt_2', label: 'Main')`; with label left empty → `label: ''`) and `create sheet keeps name validation with a label` (invalid name disables Create even with a label).

`emulator_shutdown_test.dart`: `shutdown confirmation ... the named instance` now passes `tr: fakeTr`, expects title `Stop Player 1?`, body `Apps running in it will close.` and taps `Stop` / `Cancel`.

- [ ] **Step 2: Run** `flutter test test/emulator_labels_test.dart test/avd_manage_sheets_test.dart test/emulator_shutdown_test.dart` — Expected: FAIL (new symbols missing; old dialog copy).
- [ ] **Step 3: Implement** the store, normalization, sheets, dialog copy and the dashboard wiring listed above.
- [ ] **Step 4: Run** the same command — Expected: PASS (the compact/row shutdown tests that tap `Shut down emulator` in a popup still pass: the popup text is unchanged until Task 8).
- [ ] **Step 5: Commit** `feat(phone): local emulator labels and clearer manage dialogs`.

---

### Task 3: EmulatorTile, EmulatorRow and the state badge

**Files:**
- Create: `flutter/lib/mobile/widgets/emulator_tile.dart`
- Test: `flutter/test/emulator_tile_test.dart` (new)

**Interfaces:**
- Consumes: `EmulatorUiState`, `EmulatorUiWord` (Task 1); `fakeTr`.
- Produces:
  - `MirpgStatusTone emulatorStateTone(EmulatorUiWord word)` — live→good, starting→warning, problem→error, stopped/stopping/copying→neutral.
  - `class EmulatorStateBadge extends StatelessWidget { const EmulatorStateBadge({super.key, required this.state, this.onDarkSurface = true, this.tr = translate}); }` — `MirpgStatusChip(label: tr(state.label), tone: emulatorStateTone(state.word), icon: live ? Icons.circle : null)`.
  - `class EmulatorTileData { const EmulatorTileData({required this.id, required this.title, this.secondary = '', required this.state, this.image, this.windowVisible = false, this.placeholder = false}); }` — `title` is the label or name; `secondary` is the emulator name when a label is set, else `''`; `placeholder` draws the "Setting up…" tile.
  - `class EmulatorTile extends StatelessWidget { const EmulatorTile({super.key, required this.data, this.onOpen, this.onMore, this.tr = translate}); }`
  - `class EmulatorRow extends StatelessWidget { const EmulatorRow({super.key, required this.data, this.onOpen, this.onMore, this.tr = translate}); }`
- Tile layout (mockup 1a/1a′): preview area `AspectRatio(3/4)` when height is unbounded, `Expanded` when bounded; `RawImage(fit: BoxFit.contain)` on black; badge bottom-left; "PC" flag (`Icons.desktop_windows_outlined` + `tr('PC')`) bottom-right when `windowVisible`; centre content by word — stopped: `FilledButton.icon(▶, tr('Start'))` calling `onOpen`, plus `pcMessage` note; problem: cause line (pcMessage or `tr(causeKey)`, 2 lines) and `FilledButton(tr('Reconnect'))` calling `onOpen`; copying: `LinearProgressIndicator(value: p/100)`; starting: small progress ring; placeholder: dashed outline, `tr('Setting up…')`, no badge, no actions. Name bar: title `titleMedium` `maxLines: 2`, secondary `bodySmall` 1 line, `IconButton(Icons.more_vert, tooltip: tr('More {$title} actions'))` calling `onMore`. Whole tile `InkWell(onTap: onOpen, onLongPress: onMore)`. Row: 76×62 thumbnail, title, word/cause line coloured by tone, `⋮`, and a trailing `IconButton` whose tooltip is `Start` (stopped), `Reconnect` (problem) or `Open` (live/starting), absent for stopping/copying/placeholder.

- [ ] **Step 1: Write the failing tests** in `emulator_tile_test.dart` (all pump with `tr: fakeTr`, theme `MirpgRemoteTheme.build(ThemeData.dark())` unless stated):

```dart
const live = EmulatorUiState(EmulatorUiWord.live, 'Live');
const stopped = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');
const problem = EmulatorUiState(EmulatorUiWord.problem, 'Problem', causeKey: 'Stream stopped');

test('every word has one fixed tone', () {
  expect({for (final w in EmulatorUiWord.values) w: emulatorStateTone(w)}, {
    EmulatorUiWord.live: MirpgStatusTone.good, EmulatorUiWord.starting: MirpgStatusTone.warning,
    EmulatorUiWord.stopped: MirpgStatusTone.neutral, EmulatorUiWord.stopping: MirpgStatusTone.neutral,
    EmulatorUiWord.copying: MirpgStatusTone.neutral, EmulatorUiWord.problem: MirpgStatusTone.error});
});
```
- `stopped tile starts only from an explicit tap`: 158×290 tile; `opens == 0` after pump; tap `Start` → `opens == 1`; `find.text('Live')` findsNothing.
- `tile shows a two-line name without truncation at phone grid width`: width 158, title `BlueStacks App Player 3`; `tester.renderObject<RenderParagraph>(find.text(title)).didExceedMaxLines` isFalse.
- `labelled tile shows the label and the emulator name`: title `Main`, secondary `Maple_1` → both `findsOneWidget`.
- `problem tile shows its cause and Reconnect`: `Stream stopped` and `Reconnect` found; tap `Reconnect` → `opens == 1`; a `pcMessage: 'Boot timed out'` variant shows `Boot timed out` and not `Stream stopped`.
- `copying tile shows the percentage and no Start`: label `Copying {42}%` → `Copying 42%` found; `Start` findsNothing; `LinearProgressIndicator.value == 0.42`.
- `PC flag only when the window is shown`: `windowVisible: false` → `find.text('PC')` nothing; `true` → one.
- `long-press and the more button both ask for the action sheet`: `onMore` count 2 after `longPress(find.byType(EmulatorTile))` and tap `byTooltip('More Main actions')`.
- `placeholder tile has no actions`: `Setting up…` found, `byTooltip(... actions)` nothing, tap → `opens == 0`.
- `tiles fit at 1.3 text scale in light and dark`: for both bases, a 2×2 `GridView` at 360×800 with `mainAxisExtent: 158 * 4 / 3 + 1.3 * 64`, four tiles (live, stopped, problem, copying) → `tester.takeException()` isNull.
- `row offers the same primary action as the tile`: rows for stopped/problem/live → tooltips `Start`, `Reconnect`, `Open` each tap `onOpen` once; stopping row has none of them.

- [ ] **Step 2: Run** `flutter test test/emulator_tile_test.dart` — Expected: compile FAIL.
- [ ] **Step 3: Implement** `emulator_tile.dart` as specified.
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone): EmulatorTile and EmulatorRow with one state badge`.

---

### Task 4: Emulator action sheet

**Files:**
- Create: `flutter/lib/mobile/widgets/emulator_action_sheet.dart`
- Test: `flutter/test/emulator_action_sheet_test.dart` (new)

**Interfaces:**
- Consumes: `EmulatorUiState` (1), `EmulatorStateBadge` (3), `AvdCardActions` (existing data class in `target_dashboard_page.dart`; move it to this file and re-export it from `target_dashboard_page.dart` with `export '../widgets/emulator_action_sheet.dart' show AvdCardActions;` so existing imports still compile; `menuEntries`/`select` stay until Task 8).
- Produces:
  - `class EmulatorActionSheet extends StatelessWidget { const EmulatorActionSheet({super.key, required this.title, required this.subtitle, required this.state, required this.stopped, this.onOpen, this.openBlocker, this.onLaunchGame, this.onStop, required this.onLabel, this.avd, this.shuttingDown = false, this.tr = translate}); }`
  - `Future<void> showEmulatorActionSheet(BuildContext context, EmulatorActionSheet sheet)` — `showModalBottomSheet(showDragHandle: true, useSafeArea: true)`; each row pops the sheet first, then calls its action (dialogs open from the page context).
- Rows (56 dp `ListTile`s, icon + text, disabled rows show their blocker as subtitle), in this order:
  1. `Start` (stopped) or `Open` — `onOpen`; disabled with `openBlocker` subtitle when `onOpen == null`.
  2. `Open and launch game` — only when `onLaunchGame != null`.
  3. `Show on PC` / `Hide on PC` — only when `avd?.running == true && avd.onToggleWindow != null`.
  4. `Stop` — when not stopped and (`avd?.onStop` or `onStop`) is set; disabled while `shuttingDown`.
  5. divider; `Label` — always (`onLabel`, enabled in view-only too).
  6. `Clone`, `Rename`, `Delete` — only when `avd != null`; disabled with `tr(avd.blocker)` subtitle when `blocker != null`; while copying (`avd.cloningLabel != null`) all three are disabled with `Copy in progress`. `Delete` is last, text and icon in `palette.error`.
- Header: `title` (`titleMedium`), then `subtitle` (e.g. `Maple_1 · Android Emulator · Android 15`) and `EmulatorStateBadge(onDarkSurface: false)`. BlueStacks: no `avd` → rows 1, 2, 4, 5 only.

- [ ] **Step 1: Write the failing tests** (pump `EmulatorActionSheet` inside `showEmulatorActionSheet` from a button; `tr: fakeTr`). Migrate the four scenarios of the `managed emulator menu` group from `target_dashboard_test.dart`, keeping their names with `sheet` in place of `$label`:
  - `running avd sheet offers Stop and a blocked Delete`: `Show on PC` found, `Hide on PC` not, `Stop it first` ×3, `tester.widget<ListTile>(find.widgetWithText(ListTile, 'Stop')).enabled` isTrue, Delete tile `enabled` isFalse; tapping `Show on PC` closes the sheet (`find.byType(EmulatorActionSheet)` nothing) and `toggles == 1`; reopen, tap `Stop` → `stops == 1`.
  - `stopped avd sheet can clone, rename and delete`: rows `Start` present, `Stop`/`Show on PC`/`Hide on PC` absent; tapping each of Clone, Rename, Delete in turn → `calls == ['clone', 'rename', 'delete']`.
  - `visible window avd sheet offers Hide on PC`.
  - `copying avd sheet blocks management and keeps Label`: `Copy in progress` ×3, `Label` enabled.
  - `bluestacks sheet shows Open, Launch game, Stop and Label only`: no Clone/Rename/Delete/Show on PC.
  - `Delete is the last row and red`: the last `ListTile` in the sheet has text `Delete`; its `Text` colour == `MirpgStudioPalette.dark.error`.
  - `view-only sheet disables Open with the reason but keeps Label`: `onOpen: null, openBlocker: "atlas hasn't granted control"` → Open tile disabled with that subtitle; `Label` tap → `labels == 1`.
  - `sheet is usable at 1.75 text scale`: no exception; `Stop` tappable.

- [ ] **Step 2: Run** `flutter test test/emulator_action_sheet_test.dart test/target_dashboard_test.dart` — Expected: new file FAILS to compile; dashboard tests still pass.
- [ ] **Step 3: Implement** the sheet and move `AvdCardActions` (re-export as above).
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone): emulator action sheet replaces the card popup`.

---

### Task 5: Play tab

**Files:**
- Create: `flutter/lib/mobile/widgets/play_tab.dart`
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_homeBody` replaced, `_subscribe`, `_card` split, `_open`, `_choose`, `_devicesBody` Android group, `build` app bar/FAB, `ConnectedPcTabBar`), `flutter/lib/mobile/widgets/session_quality_panel.dart` (`SessionStatusButton`)
- Test: `flutter/test/play_tab_test.dart` (new), `flutter/test/target_dashboard_test.dart`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `List<String> playTabPreviewIds(List<RemoteEmulator> guests, {required int firstVisibleIndex, bool Function(String id)? shuttingDown, String? activeId})` — candidates are guests whose `state` is not `stopped`, `stopping` or `cloning`, not shutting down, not `activeId`; order: indices `>= firstVisibleIndex` ascending, then indices below it descending; take 4.
  - `class PlayTabBody extends StatelessWidget { const PlayTabBody({super.key, required this.tiles, required this.hostName, required this.firstLoad, required this.listError, required this.monitorCount, required this.onRefresh, required this.onRetryList, required this.onOpen, required this.onMore, this.onOpenScreens, this.onNew, this.scrollController, this.tr = translate}); }` — `tiles: List<EmulatorTileData>`, `onRefresh: Future<void> Function()`, `onOpen`/`onMore: void Function(String id)`.
  - `SessionStatusButton({..., this.compact = false})` — compact drops the leading icon and uses 8 dp horizontal padding.
  - `ConnectedPcTabBar` first destination label `Play` (icons `Icons.sports_esports_outlined` / `_rounded`).
  - Dashboard: `Map<String, DateTime> _startRequested` (set in `_open` for a guest whose state is `stopped`, removed when the listed state is no longer `stopped` or after 120 s); `Map<String, String> _settingUp` (id → display name, added when New is confirmed, removed when the id is listed or the create result is not ok); `EmulatorTileData _guestTile(_Target)`; `Future<void> _showEmulatorActions(_Target)`; `Future<void> _editLabel(_Target)`; `ScrollController _playScroll`.
- `PlayTabBody` layout (mockup 1a), inside `RefreshIndicator(onRefresh)` with `AlwaysScrollableScrollPhysics`:
  - header `tr('Emulators') · tr('{running/total} running')` where running counts live+starting; omitted while `firstLoad`.
  - `listError` non-empty → inline `MirpgSurface` card: `Couldn't get the emulator list from {hostName}`, `listError` as the second line, `Try again` → `onRetryList`. This replaces the page banner (no other place shows the list error).
  - `firstLoad` → four skeleton tiles (no centre spinner). Empty and not loading → card `No emulators on {hostName} yet`, filled `New emulator` (when `onNew` non-null), line `BlueStacks instances appear here when BlueStacks is installed.`
  - grid: `SliverGrid` 2 columns, spacing 12, page margin 16, `mainAxisExtent = tileWidth * 4 / 3 + textScaler.scale(64)`; tiles in the given order; `onOpen` passed only when `data.state.canOpen && !data.placeholder`.
  - `monitorCount > 0` → section `PC screens` and one row `Monitor 1 · 2 · 3` (numbers 1..monitorCount) with a chevron, calling `onOpenScreens`.
  - bottom padding 88 so the FAB never covers the last row.
- Dashboard behaviour:
  - Play app bar: title = `pi.hostname` (fallback `Your PC`), no subtitle, `SessionStatusButton(compact: width < 480)` always shown, Play has no refresh button (pull to refresh), `ConnectedPcSessionMenu` stays until Phase 2 (End session must stay reachable).
  - `floatingActionButton`: `FloatingActionButton.extended(icon: Icon(Icons.add), label: Text(translate('New')))` on Play when `model.canManageAvds && keyboard && !viewOnly`.
  - `_subscribe` on Play: `displays` empty; `guestIds = playTabPreviewIds(guests, firstVisibleIndex: 2 * floor(max(0, _playScroll.offset - 36) / rowExtent), shuttingDown: model.isEmulatorShuttingDown, activeId: _fullscreen?.id)`, `rowExtent` from the grid's last layout. Screens tab and chooser keep their current selection.
  - Tile `onOpen(id)`: view-only (`!keyboard || viewOnly`) → snackbar `{hostName} hasn't granted control`; else `_open(target)` (unchanged `model.connecting` guard). `onMore(id)` → `_showEmulatorActions`.
  - `_guestTile` builds `EmulatorUiFlags(frameCurrent: <existing guestFrameCurrent>, shuttingDown: model.isEmulatorShuttingDown(id), startRequested: _startRequested.containsKey(id), guestFailure: model.guestFailures[id] ?? '')` and `title/secondary` from `_labels`.
  - `_showEmulatorActions` builds `EmulatorActionSheet` from the same inputs `_card` uses today for `AvdCardActions`, BlueStacks shutdown and launch game; `onLabel` → `_editLabel` → `showEmulatorLabelSheet` → `_labels.setLabel`.
  - Screens tab Android group: `EmulatorRow` with the same callbacks; header `Emulators · n`, no subtitle. Chooser `_choose`: guests render `EmulatorTile` (bounded height), monitors keep `TargetPreviewCard`.
  - `_homeBody`'s "Continue working", "Android instances", "VIEW ALL", "Retry discovery" banner and "BlueStacks instances" footer are removed.

- [ ] **Step 1: Write the failing tests** in `play_tab_test.dart`:

```dart
RemoteEmulator g(int i, String state) => RemoteEmulator(id: 'avd:E$i', name: 'E$i', provider: 'avd', state: state);

test('four running emulators all get previews in grid order', () {
  expect(playTabPreviewIds([for (var i = 0; i < 4; i++) g(i, 'running')], firstVisibleIndex: 0),
      ['avd:E0', 'avd:E1', 'avd:E2', 'avd:E3']);
});
test('stopped, stopping, copying and shutting-down emulators never take a slot', () {
  final guests = [g(0, 'stopped'), g(1, 'running'), g(2, 'cloning'), g(3, 'stopping'), g(4, 'running')];
  expect(playTabPreviewIds(guests, firstVisibleIndex: 0, shuttingDown: (id) => id == 'avd:E4'), ['avd:E1']);
});
test('with more than four running the ones nearest the viewport top win', () {
  final six = [for (var i = 0; i < 6; i++) g(i, 'running')];
  expect(playTabPreviewIds(six, firstVisibleIndex: 2), ['avd:E2', 'avd:E3', 'avd:E4', 'avd:E5']);
  expect(playTabPreviewIds(six, firstVisibleIndex: 4), ['avd:E4', 'avd:E5', 'avd:E3', 'avd:E2']);
});
```
Widget tests (360×800, `tr: fakeTr`):
  - `first load shows four skeleton tiles and no spinner`: `firstLoad: true, tiles: []` → `find.byKey(const ValueKey('play-skeleton'))` ×4, `CircularProgressIndicator` nothing.
  - `empty list offers New emulator and names the PC`: `No emulators on atlas yet`, `BlueStacks instances appear here when BlueStacks is installed.`; tap `New emulator` → `news == 1`; with `onNew: null` the button is absent.
  - `list error is an inline card with Try again`: `Couldn't get the emulator list from atlas` and the detail line; tap `Try again` → `retries == 1`.
  - `tiles keep the given order and header counts running`: four tiles A (live), B (stopped), C (starting), D (live) → `Emulators · 3/4 running`; `tester.getTopLeft(find.text('A')).dy < getTopLeft('C').dy` and `getTopLeft('A').dx < getTopLeft('B').dx`.
  - `copying tile is not openable from the grid`: tapping it → `opens` empty; tapping a live tile → `opens == ['avd:A']`.
  - `PC screens row opens the Screens tab`: `monitorCount: 3` → `Monitor 1 · 2 · 3`; tap → `screens == 1`; `monitorCount: 0` → `PC screens` nothing.
  - `pull to refresh calls onRefresh`: `tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000)` then `pumpAndSettle` → `refreshes == 1`.
  - `grid fits four tiles with long names at 1.3 text scale`: no exception.

  In `target_dashboard_test.dart`: the three tab-bar tests expect `Play` instead of `Home`; add `compact status button fits 360 dp at 1.3 text scale` (pump `SessionStatusButton(compact: true, direct: true, data: <fresh 3 ms data as in the existing diagnostics test>)` in a 120 dp wide box → no exception, `find.textContaining('Direct')` found).

- [ ] **Step 2: Run** `flutter test test/play_tab_test.dart test/target_dashboard_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** `play_tab.dart`, `SessionStatusButton.compact`, the tab label, and the dashboard wiring above.
- [ ] **Step 4: Run** `flutter test test/play_tab_test.dart test/target_dashboard_test.dart test/emulator_shutdown_test.dart test/home_page_shell_test.dart` — Expected: PASS. `flutter analyze lib/mobile/pages/target_dashboard_page.dart lib/mobile/widgets/play_tab.dart` — no new issues.
- [ ] **Step 5: Commit** `feat(phone): Play tab shows every emulator as a tile`.

---

### Task 6: Startup checklist, failure screen and switch placeholder

**Files:**
- Create: `flutter/lib/mobile/widgets/startup_checklist.dart`
- Modify: `flutter/lib/mobile/pages/emulator_page.dart` (`EmulatorPage` params, `build`, `_guest`, `_changed`, `_startupLabel` removed, `bottomNavigationBar` removed), `flutter/lib/mobile/pages/target_dashboard_page.dart` (`_open`, `_dashboard`, `dispose`, `build` passes new params)
- Test: `flutter/test/startup_checklist_test.dart` (new)

**Interfaces:**
- Consumes: `EmulatorLabelStore.displayName` (2), `emulatorProviderLabel` (existing).
- Produces:
  - `int startupStepIndex(String phase, {required bool alreadyRunning})` — `requesting`/`boot_requested`/`''` → 0 (2 when `alreadyRunning`), `starting_android` → 1, `waiting_screen` → 2, `stream_ready` → 3.
  - `String formatElapsed(Duration d)` — `m:ss` (`0:41`, `1:05`, `12:00`).
  - `class StartupChecklist extends StatelessWidget { const StartupChecklist({super.key, required this.name, required this.providerLabel, required this.currentStep, this.failedStep, required this.elapsed, this.failureTitle = '', this.failureMessage = '', this.retryNote = '', required this.onBack, this.onTryAgain, this.onShowOnPc, this.tr = translate}); }`
  - `class SwitchPlaceholder extends StatelessWidget { const SwitchPlaceholder({super.key, this.frame, required this.name}); }` — black, `frame` dimmed to 40 % with `BoxFit.contain`, name `titleMedium` dark palette, 2 dp `LinearProgressIndicator` at the top.
  - `EmulatorPage` new params: `final String Function(String targetId)? nameFor; final ui.Image? switchFrame; final Future<void> Function()? onShowOnPc;`
- Checklist (mockup 1c/1d): name `headlineSmall`, provider line, four rows `Start requested`, `Starting Android`, `Starting the screen`, `Live` marked done (✓ good), current (animated ring warning), failed (✕ error), pending (○); elapsed `formatElapsed(elapsed) · tr('usually under a minute')`, at `elapsed >= 60 s` `tr('Taking longer than usual')`. Normal: `FilledButton(tr('Back to emulators'))` full width at the bottom, `TextButton(tr('Show on PC'))` when `onShowOnPc != null`. Failure (`failedStep != null`): `failureTitle` + `failureMessage` + `retryNote`; `FilledButton(tr('Try again'))` (`onTryAgain`), then text buttons `Back to emulators`, `Show on PC`; elapsed line hidden. No Android Back/Home/Recents anywhere.
- EmulatorPage (dashboard mode only; the legacy picker path keeps its app bar):
  - no `AppBar` at all and no `bottomNavigationBar` (also removed in legacy mode, where it was always disabled).
  - When `!model.streaming`: show `StartupChecklist` if `model.error.isNotEmpty`, or the target was not `readyForReconnect` when it was selected (`_openedRunning`, captured when `model.targetId` changes), or `startupPhase` is `boot_requested`/`starting_android`; otherwise `SwitchPlaceholder(frame: widget.switchFrame, name: name)`.
  - `_lastStartupStep` tracks `startupStepIndex` for every phase except `failed`; `failedStep = _guestWasLive ? 3 : _lastStartupStep`. `failureTitle` = `Lost the screen for {name}` when `_guestWasLive`, else `Couldn't start {name}`; `failureMessage = model.error`.
  - `retryNote` while `_guestReconnectTimer != null`: `Trying again in 1 s (1 of 2)` when `_guestReconnectAttempts == 0`, else `Trying again in 3 s (2 of 2)` (the delays of `guestAutoReconnectDelay`).
  - Elapsed: a `Stopwatch` reset when `model.targetId` changes or `startupPhase` becomes `requesting`; a 1 s `Timer.periodic` runs only while the checklist is visible; both stopped in `dispose`.
  - `onBack` → existing `_back()` (dashboard `_dashboard()` sends `desktop`; the PC keeps booting, spec §7 Q1). `onTryAgain` → existing `_reconnectGuest`.
- Dashboard: in `_open` for a guest, `_switchFrame?.dispose(); _switchFrame = <current preview image for the target>?.clone();` before `_subscribe()` (preview images are disposed when no longer retained); dispose it when `model.streaming` turns true, in `_dashboard`, and in `dispose`. Pass `nameFor: (id) => _labels.displayName(id, <instance name>)`, `switchFrame`, and `onShowOnPc` only for an AVD with `model.canManageAvds && !windowVisible` (calls `_toggleAvdWindow`).

- [ ] **Step 1: Write the failing tests** in `startup_checklist_test.dart` (`tr: fakeTr`, dark theme, 412×915):

```dart
test('phases map to the four steps', () {
  expect([for (final p in ['', 'requesting', 'boot_requested', 'starting_android', 'waiting_screen', 'stream_ready'])
      startupStepIndex(p, alreadyRunning: false)], [0, 0, 0, 1, 2, 3]);
  expect(startupStepIndex('requesting', alreadyRunning: true), 2);
});
test('elapsed is m:ss', () {
  expect([formatElapsed(const Duration(seconds: 41)), formatElapsed(const Duration(seconds: 65)),
      formatElapsed(const Duration(minutes: 12))], ['0:41', '1:05', '12:00']);
});
```
  - `checklist marks done, current and pending steps`: `currentStep: 2` → `find.byKey(const ValueKey('step-done-0'))`, `step-done-1`, `step-current-2`, `step-pending-3` each found.
  - `hint changes after a minute`: `elapsed: 41 s` → `0:41 · usually under a minute`; `elapsed: 61 s` → `Taking longer than usual`.
  - `Back to emulators is the bottom primary action and there are no Android keys`: `FilledButton` with `Back to emulators`, its rect bottom > 0.8 × screen height; `find.byTooltip('Home')`, `find.text('Recents')` nothing; tap → `backs == 1`.
  - `Show on PC only when offered`: absent with `onShowOnPc: null`; present and tappable otherwise.
  - `failure marks the failed step and puts the PC message second`: `failedStep: 1, failureTitle: "Couldn't start {Alt-2}", failureMessage: 'ADB did not answer'` → `step-failed-1` found, `Couldn't start Alt-2` above `ADB did not answer` (dy order), `Try again` tap → `retries == 1`, elapsed text absent.
  - `retry note shows only while armed`: `retryNote: 'Trying again in 3 s (2 of 2)'` found; empty → no `Trying again` text.
  - `switch placeholder shows the name on black without a frame`: `SwitchPlaceholder(name: 'Alt-1')` → `Alt-1` and `LinearProgressIndicator` found, `RawImage` nothing, no exception.

- [ ] **Step 2: Run** `flutter test test/startup_checklist_test.dart` — Expected: compile FAIL.
- [ ] **Step 3: Implement** the widget file and the `EmulatorPage`/dashboard changes above.
- [ ] **Step 4: Run** `flutter test test/startup_checklist_test.dart test/guest_control_stage_test.dart test/emulator_input_test.dart test/target_dashboard_test.dart` — Expected: PASS. `flutter analyze lib/mobile/pages/emulator_page.dart lib/mobile/widgets/startup_checklist.dart` — no new issues.
- [ ] **Step 5: Commit** `feat(phone): startup checklist and failure screen for emulators`.

---

### Task 7: Play rail, account chips, switching and name banner

**Files:**
- Create: `flutter/lib/mobile/widgets/play_rail.dart`
- Modify: `flutter/lib/mobile/pages/emulator_page.dart` (`GuestControlStage`, `_guest`, `_guestControls` → rail, `_touch`, `_changed`), `flutter/lib/mobile/pages/target_dashboard_page.dart` (`build` passes rail inputs; `_switchTo`, `_previousGuestId`, `_chooseEmulator`)
- Test: `flutter/test/play_rail_test.dart` (new), `flutter/test/guest_control_stage_test.dart`

**Interfaces:**
- Consumes: `EmulatorUiWord` (1), `EmulatorTile` (3), `showEmulatorActionSheet` (4), `nameFor`/`switchFrame` (6).
- Produces:
  - `enum PlayRailPlacement { bottom, side, collapsed }`; `const kPlayRailAccountsHeight = 40.0, kPlayRailKeysHeight = 48.0, kPlayRailBottomHeight = 88.0, kPlayRailSideWidth = 72.0, kPlayRailHysteresis = 16.0;`
  - `PlayRailPlacement playRailPlacement({required Size viewport, required int guestWidth, required int guestHeight, PlayRailPlacement? previous})` — algorithm below.
  - `class PlayAccount { const PlayAccount({required this.id, required this.label, required this.word}); }`
  - `class PlayRail extends StatelessWidget { const PlayRail({super.key, required this.accounts, required this.currentId, required this.axis, required this.onSelect, this.onShowAll, required this.onGrid, this.onGridLongPress, this.onType, this.onNavigate, this.switching = false, this.tr = translate}); }` — `onSelect: ValueChanged<String>`, `onNavigate: ValueChanged<String>?` with `'back' | 'home' | 'recents'`.
  - `class NameBannerController extends ChangeNotifier { NameBannerController({this.hold = const Duration(seconds: 2)}); String get text; bool get visible; void show(String text); void dispose(); }` and `class GuestNameBanner extends StatelessWidget { const GuestNameBanner({super.key, required this.controller}); }` (top-centre, `IgnorePointer`, dark `MirpgStatusChip`, `AnimatedOpacity` 300 ms).
  - `GuestControlStage` new optional params: `PlayRailPlacement placement = PlayRailPlacement.collapsed`, `Widget? composer`, `VoidCallback? onDoubleTapToggle`. Existing `video`, `controls` (now the rail), `controlsVisible`, `onToggleControls` keep their names.
  - `EmulatorPage` new params: `List<PlayAccount> accounts = const []`, `Future<void> Function(String targetId)? onSelectTarget`, `Future<void> Function()? onPreviousTarget`, `VoidCallback? onCurrentActions`; existing `onSwitch` now opens the emulator grid sheet ("+").
- Placement algorithm (hysteresis keeps the previous docked placement until its spare space drops more than 16 dp below the need):

```dart
final frame = containedGuestFrame(viewportWidth: viewport.width, viewportHeight: viewport.height,
    guestWidth: guestWidth, guestHeight: guestHeight);
if (frame == null) return PlayRailPlacement.collapsed;
final spareH = viewport.height - frame.height, spareW = viewport.width - frame.width;
double need(PlayRailPlacement p, double base) => p == previous ? base - kPlayRailHysteresis : base;
if (spareH >= need(PlayRailPlacement.bottom, kPlayRailBottomHeight)) return PlayRailPlacement.bottom;
if (spareW >= need(PlayRailPlacement.side, kPlayRailSideWidth)) return PlayRailPlacement.side;
return PlayRailPlacement.collapsed;
```
- `GuestControlStage` layouts: `composer != null` → `Column(Expanded(video + button when collapsed), composer)` (rail hidden); `bottom` → `Column(Expanded(video), SizedBox(height: 88, child: controls))`, no round button; `side` → `Row(Expanded(video), SizedBox(width: 72, child: controls))`, no round button; `collapsed` → `Stack(video, round button; if controlsVisible: Positioned(left: 0, right: 0, bottom: 0, child: controls))` so the video keeps its size (no geometry change). When `onDoubleTapToggle != null` the round `IconButton` is wrapped in `GestureDetector(onDoubleTap: onDoubleTapToggle)`.
- `PlayRail` (mockups 1e, 1f, 1f′): horizontal = accounts row (40 dp, horizontally scrolling chips, then `+` with tooltip `Show all emulators`) over keys row (48 dp: ▦ `Icons.grid_view_rounded` tooltip `Emulators`, ⌨ tooltip `Type text`, ◁ `Back`, ○ `Home`, □ `Recents`); vertical = the same items stacked in a 72 dp column. Chip: account label + state dot coloured by `emulatorStateTone`; the current chip is filled (`palette.accent` 0.24) and has `Semantics(selected: true)`; tapping the current chip does nothing; all chips are disabled while `switching`. Opaque background `MirpgStudioPalette.dark.background` so rail taps never reach the video `Listener`.
- EmulatorPage wiring: placement is computed in `_guest`'s `LayoutBuilder` from the `SafeArea` size and stored in `_railPlacement` (dashboard mode only; legacy mode always `collapsed` with the existing `_guestControls`). In `collapsed`, `_guestControlsVisible` starts false; a pointer-down on the video (`_touch` action 0) hides the overlay rail while still delivering the touch. ▦ → `_back()`; long-press ▦ → `onCurrentActions`; ⌨ → `_openTextComposer`; keys → `model.navigation` (unchanged gating `canGuestControl && model.streaming && !_returning`). `switching: model.connecting`. Banner: `_banner.show('${name} · ${tr('Live')}')` the first time `model.streaming` is true for a `(targetId, guestSessionId)` pair; `GuestNameBanner` sits above the existing view-only/reconnecting chip.
- Dashboard: `accounts` = guests whose `emulatorUiState` word is `live` or `starting`, plus the current target, in grid order, labels from `_labels`. `_switchTo(id)`: ignore if `model.connecting` or `id == _fullscreen?.id`; set `_previousGuestId = _fullscreen?.id`; `await _open(target)`. `onPreviousTarget` non-null only when `_previousGuestId` is still listed and not stopped. `onSwitch: _chooseEmulator` — a bottom sheet with a 2-column `EmulatorTile` grid of all emulators (tap opens via `_switchTo`, a stopped one starts). `onCurrentActions` → `_showEmulatorActions(_fullscreen!)`.

- [ ] **Step 1: Write the failing tests** in `play_rail_test.dart`:

```dart
test('portrait 9:16 game on a 19.5:9 phone docks the rail at the bottom', () {
  expect(playRailPlacement(viewport: const Size(412, 915), guestWidth: 1080, guestHeight: 1920), PlayRailPlacement.bottom);
});
test('landscape 16:9 game docks the rail on the short edge', () {
  expect(playRailPlacement(viewport: const Size(915, 412), guestWidth: 1920, guestHeight: 1080), PlayRailPlacement.side);
});
test('a game that fills the screen collapses the rail', () {
  expect(playRailPlacement(viewport: const Size(915, 412), guestWidth: 2400, guestHeight: 1080), PlayRailPlacement.collapsed);
});
test('small viewport changes near the threshold do not flip the rail', () {
  // 9:16 guest, width 412: frame height 732.4; bottom needs 88 dp of spare height.
  expect(playRailPlacement(viewport: const Size(412, 821), guestWidth: 1080, guestHeight: 1920), PlayRailPlacement.bottom);
  expect(playRailPlacement(viewport: const Size(412, 810), guestWidth: 1080, guestHeight: 1920, previous: PlayRailPlacement.bottom), PlayRailPlacement.bottom);
  expect(playRailPlacement(viewport: const Size(412, 810), guestWidth: 1080, guestHeight: 1920), isNot(PlayRailPlacement.bottom));
  expect(playRailPlacement(viewport: const Size(412, 800), guestWidth: 1080, guestHeight: 1920, previous: PlayRailPlacement.bottom), isNot(PlayRailPlacement.bottom));
});
testWidgets('banner shows for two seconds then hides', (tester) async {
  final c = NameBannerController()..show('Alt-1 · Live');
  addTearDown(c.dispose);
  expect((c.visible, c.text), (true, 'Alt-1 · Live'));
  await tester.pump(const Duration(milliseconds: 1999));
  expect(c.visible, isTrue);
  await tester.pump(const Duration(milliseconds: 2));
  expect(c.visible, isFalse);
});
```
(`fake_async` is not a declared dependency; use the widget tester's fake clock as above.)
  Widget tests (`tr: fakeTr`):
  - `chips follow grid order and mark the current account`: accounts Main (live), Alt-1 (live), Alt-2 (starting), `currentId: 'avd:Main'` → x order Main < Alt-1 < Alt-2; `tester.getSemantics(find.text('Main'))` has `isSelected`; tap `Alt-1` → `selected == ['avd:Alt-1']`; tap `Main` → still one call.
  - `chips are disabled while a switch is connecting`: `switching: true`, tap `Alt-1` → `selected` empty.
  - `plus opens the full list and keys keep their actions`: tap `byTooltip('Show all emulators')` → `all == 1`; tap `Back`, `Home`, `Recents` → `nav == ['back', 'home', 'recents']`; long-press `byTooltip('Emulators')` → `actions == 1`, tap it → `grid == 1`.
  - `vertical rail fits 72 dp wide at 412 dp tall with four accounts`: no exception.
  - `banner widget fades out`: pump `GuestNameBanner`, `controller.show('Alt-1 · Live')`, pump → text found with opacity 1; `pump(2 s)` + `pump(300 ms)` → `AnimatedOpacity.opacity == 0`.

  In `guest_control_stage_test.dart`:
  - Rewrite `phone-shaped guest fills $size with movable controls` for `collapsed`: after `Show controls`, `video.size == size` (overlay, no shrink), controls rect `bottom == size.height`; tapping `Guest Home` still leaves `touches` empty; all other assertions unchanged.
  - Add `docked bottom rail sits under the video without a toggle button`: 412×915, `placement: bottom` → `video.bottom == controls.top`, `controls.height == 88`, `byTooltip('Show controls')` nothing, a tap at the centre of the contained frame maps to the guest centre (as in the existing test).
  - Add `side rail sits beside the video`: 915×412, `placement: side` → `video.right == controls.left`, `controls.width == 72`.
  - Add `double tap on the round button jumps without toggling`: `onDoubleTapToggle` set; `tap` + `pump(kDoubleTapMinTime)` + `tap` + `pumpAndSettle` → `doubles == 1`, `toggles == 0`; a single `tap` + `pump(kDoubleTapTimeout)` → `toggles == 1`.
  - Update `landscape IME keeps guest visible above compact composer` to pass the composer via `composer:`; assertions unchanged.

- [ ] **Step 2: Run** `flutter test test/play_rail_test.dart test/guest_control_stage_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** `play_rail.dart`, the `GuestControlStage` placements and the `EmulatorPage`/dashboard wiring above.
- [ ] **Step 4: Run** `flutter test test/play_rail_test.dart test/guest_control_stage_test.dart test/emulator_input_test.dart test/startup_checklist_test.dart test/target_dashboard_test.dart test/remote_conformance/input_liveness_test.dart` — Expected: PASS. `flutter analyze` on the three touched files — no new issues.
- [ ] **Step 5: Commit** `feat(phone): play rail with account chips and name banner`.

---

### Task 8: Double-back, vocabulary and retiring the old emulator cards

**Files:**
- Modify: `flutter/lib/mobile/pages/emulator_page.dart` (PopScope, warning chip, legacy picker copy), `flutter/lib/mobile/pages/target_dashboard_page.dart` (`TargetPreviewCard` and `TargetScreenRow` become monitor-only; delete `_EmulatorShutdownMenu`; `_toolsBody` subtitle; `_devicesBody` empty text), `flutter/lib/mobile/widgets/emulator_action_sheet.dart` (delete `AvdCardActions.menuEntries`/`select`), `flutter/lib/mobile/widgets/session_quality_panel.dart` (profile copy)
- Test: `flutter/test/emulator_page_back_test.dart` (new), `flutter/test/target_dashboard_test.dart`, `flutter/test/emulator_shutdown_test.dart`

**Interfaces:**
- Consumes: `PlayRailPlacement` (7), `EmulatorTile`/`EmulatorRow` (3), `EmulatorActionSheet` (4).
- Produces: `class DoubleBackGuard { DoubleBackGuard({this.window = const Duration(seconds: 2)}); bool press(DateTime now); void reset(); }` in `emulator_page.dart` — `press` returns true (leave) only for a second press within `window` of the first; a press after the window starts a new pair.
- Back in a game (dashboard mode, `model.streaming`): if the text composer is open, close it and stay; else if `!_doubleBack.press(DateTime.now())`, show a 2 s snackbar `Back again to leave the game` and, when `_railPlacement == collapsed`, set `_guestControlsVisible = true`; else `_back()`. Back on the checklist, failure or placeholder screen: `_back()` at once. Legacy mode unchanged.
- Warning chip copy: `!canControl` → `'$name · ${tr('View only')}'`; frame not fresh → `'$name · ${tr('Reconnecting…')}'`.
- Vocabulary (spec V3/V4, Phase 1 surfaces): legacy picker — header `Emulators`, subtitle `Choose an emulator to view and control.`, empty `No emulators found on this PC. Start one on the PC, then refresh.`, buttons `Start` / `Open`, status chip from `emulatorUiState(instance)` word + tone; `_toolsBody` subtitle `Manage {hostName} without leaving your connection.`; Screens empty text `Refresh after a PC screen or emulator becomes available.`; quality profile descriptions drop "RustDesk " (e.g. `Uses Balanced quality for an adaptive everyday profile.`) — this file stays literal-only until Phase 4 because its widgets are pumped without `tr`.
- `TargetPreviewCard` keeps only `name, type, live, image, error, onOpen, onRetry` (monitors); `TargetScreenRow` keeps only `name, type, live, image, error, onOpen` (monitors). Emulators reach no code path that uses them after Task 5.

- [ ] **Step 1: Write the failing tests.**

`emulator_page_back_test.dart`:

```dart
test('second back within two seconds leaves', () {
  final g = DoubleBackGuard();
  final t0 = DateTime(2026, 11, 16, 12);
  expect(g.press(t0), isFalse);
  expect(g.press(t0.add(const Duration(milliseconds: 1900))), isTrue);
});
test('a back after the window starts over', () {
  final g = DoubleBackGuard();
  final t0 = DateTime(2026, 11, 16, 12);
  expect(g.press(t0), isFalse);
  expect(g.press(t0.add(const Duration(milliseconds: 2100))), isFalse);
  expect(g.press(t0.add(const Duration(milliseconds: 2500))), isTrue);
});
test('reset forgets the first press', () {
  final g = DoubleBackGuard()..press(DateTime(2026));
  g.reset();
  expect(g.press(DateTime(2026).add(const Duration(milliseconds: 500))), isFalse);
});
```
Test migrations (same names, new targets, so §4 coverage is kept):
  - `target_dashboard_test.dart`: `stopped cards boot only after an explicit tap` and `launch game is a separate emulator action` move to `emulator_tile_test.dart`/`emulator_action_sheet_test.dart` style (tile `Start`; sheet `Open and launch game` calls launch, not open) under the names `stopped tiles start only after an explicit tap` and `launch game is a separate emulator action`; `running target cards expose explicit Open and Resume actions` becomes `monitor cards expose Open` (Windows only); `closed guest stays visible ... with Reconnect` and `disconnected preview fits compact cards with large text` become `EmulatorTile` problem-state tests (`Problem`, `Stream stopped`, `Reconnect`, 230×145 and 360×260 at 1.4 text scale with no exception); `Studio screen rows keep boot, open and game actions accessible` uses `TargetScreenRow` for the monitor and `EmulatorRow` + sheet for the emulator (`Start`, `More BlueStacks App Player 3 actions` → `Open and launch game`); `switcher cards ... both rotations` uses one `TargetPreviewCard` and one `EmulatorTile`; the `managed emulator menu` group is deleted (migrated in Task 4); `Studio Home emulator cards avoid overlap at high text scale` targets `EmulatorTile`.
  - `emulator_shutdown_test.dart`: the row/compact shutdown tests open the sheet from `EmulatorRow`/`EmulatorTile` (`More Player 1 actions`), tap `Stop`, expect `shutdowns == 1`, `opens == 0`; `stopped targets do not offer shutdown` asserts no `Stop` row for a stopped BlueStacks sheet and no `More Target actions` on a `TargetPreviewCard`; `shutdown pending blocks reopening` uses a stopping tile (`Stopping` found, tap → `actions == 0`); large-text test uses the sheet at 1.75.
  - `grep -rn "Boot\|Resume\|Shut down emulator\|BlueStacks instances\|Android instances\|Manage Jarvis\|Waiting for a usable preview\|Tap to control" flutter/lib/mobile` returns nothing except comments.

- [ ] **Step 2: Run** `flutter test test/emulator_page_back_test.dart test/target_dashboard_test.dart test/emulator_shutdown_test.dart` — Expected: FAIL (guard missing; migrated tests reference removed params or new widgets).
- [ ] **Step 3: Implement** the guard and back handling, the copy changes, and the monitor-only card trims.
- [ ] **Step 4: Run** the same command plus `test/emulator_tile_test.dart test/emulator_action_sheet_test.dart test/monitor_control_view_test.dart`, and the `grep` above — Expected: PASS / no matches.
- [ ] **Step 5: Commit** `feat(phone): double back to leave a game; one vocabulary for emulators`.

---

### Task 9: Translation keys, full verification and release build

**Files:**
- Modify: `src/lang/template.rs` and the other 53 `src/lang/*.rs` files (append only), `tools/aperture-release.json`

**Interfaces:**
- Consumes: every `tr(...)`/`translate(...)` key added in Tasks 2–8.
- Produces: keys present in all language files; version `1.7.0` / `4114`; a signed APK under `target/aperture-release-1.7.0/`.

Keys (sentence case; `{}` = the single placeholder; skip any already in `template.rs` — `Start`, `Stop`, `Open`, `Delete`, `Rename`, `Cancel`, `Reconnect`, `Home`, `Back` exist):
`Live`, `Starting`, `Stopped`, `Stopping`, `Copying {}%`, `Problem`, `Stream stopped`, `Android not responding`, `Couldn't stop`, `Status unavailable`, `Label`, `Label (optional)`, `Label for {}`, `Shown on this phone only`, `Save`, `Clear label`, `Delete {}?`, `Deletes {} and everything in it, including the game sign-in. This can't be undone.`, `Stop {}?`, `Apps running in it will close.`, `Created {}`, `Copied to {}`, `Renamed to {}`, `Deleted {}`, `Setting up {} on the PC`, `Shown on the PC`, `Hidden on the PC`, `PC`, `More {} actions`, `Setting up…`, `Open and launch game`, `Show on PC`, `Hide on PC`, `Stop it first`, `Copy in progress`, `Clone`, `Play`, `Emulators`, `{} running`, `PC screens`, `Monitor`, `New`, `New emulator`, `No emulators on {} yet`, `BlueStacks instances appear here when BlueStacks is installed.`, `Couldn't get the emulator list from {}`, `Try again`, `{} hasn't granted control`, `Start requested`, `Starting Android`, `Starting the screen`, `usually under a minute`, `Taking longer than usual`, `Back to emulators`, `Couldn't start {}`, `Lost the screen for {}`, `Trying again in 1 s (1 of 2)`, `Trying again in 3 s (2 of 2)`, `Show all emulators`, `Type text`, `Recents`, `Back again to leave the game`, `View only`, `Reconnecting…`, `Emulators`, `Choose an emulator to view and control.`, `No emulators found on this PC. Start one on the PC, then refresh.`, `Manage {} without leaving your connection.`, `Refresh after a PC screen or emulator becomes available.`.

- [ ] **Step 1: Cross-check the list against the code.** `git diff <Task-1 base>..HEAD -- flutter/lib | rg -o "(tr|translate)\((['\"]).*?\2"` — every literal key appears in the list above; add any that do not.
- [ ] **Step 2: Append the keys** with a throwaway script kept in the session scratchpad (not committed): for `template.rs` and each other `src/lang/*.rs`, insert `        ("<key>", ""),` lines before the closing `].iter().cloned().collect();`, escaping `"` and `\`, after making sure the previous last entry ends with a comma. `it.rs` gets `""` like the rest; no existing entry in any file changes; `en.rs` is not touched.
- [ ] **Step 3: Verify.** `git diff --stat -- src/lang` shows 54 files, additions only (`git diff -- src/lang | rg '^-[^-]'` is empty). `git diff -- src/lang/it.rs | rg '^\+' | rg -v '""\),$|^\+\+\+'` is empty. Rust compile check of the lang module is not run here (no native rebuild in this task); the entries are plain tuples identical in form to the existing ones.
- [ ] **Step 4: Full Flutter verification.** From `flutter/`: `flutter test` — Expected: the Task 1 baseline count plus the new tests, no new failures. `flutter analyze lib/mobile lib/models` — no new issues against the baseline.
- [ ] **Step 5: Bump the version.** `tools/aperture-release.json`: `"version": "1.7.0"`, `"versionCode": 4114` (other fields unchanged).
- [ ] **Step 6: Confirm the native library can be reused.** Phase 1 changes no Rust logic, and every Rust change since 1.6.0 (`git diff --stat 046bf9ea4 HEAD -- src libs Cargo.toml`) is in `#[cfg(windows)]` modules or `[target.'cfg(target_os = "windows")'.dependencies]`, so the staged `flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so` (15 Nov 08:14, shipped in 1.6.0) is still the Android library. The new lang entries are all `""`, so the old library renders them identically (untranslated keys fall back to the key text). **No native rebuild is required;** translations take effect at the next native rebuild. Hash it without building: `(Get-FileHash 'flutter\android\app\src\main\jniLibs\arm64-v8a\librustdesk.so' -Algorithm SHA256).Hash`, and compare with the library inside `target\aperture-release-1.6.0\Aperture-1.6.0-android-arm64.apk` (`lib/arm64-v8a/librustdesk.so`, read with `[IO.Compression.ZipFile]::OpenRead`). If they differ, stop and ask (Gradle stripping can change the packaged bytes; do not guess).
- [ ] **Step 7: Build the APK and stop.** In PowerShell from the repo root, with `JAVA_HOME=C:\Program Files\Java\jdk-17` and Rust 1.75 / `~/.cargo/bin` on PATH (as for 1.5.7–1.6.0):

```powershell
./tools/build_aperture_release.ps1 -NativeLibrarySha256 <hash from Step 6>
```
Expected: `Release APK: ...\target\aperture-release-1.7.0\Aperture-1.7.0-android-arm64.apk`, its SHA256, and `package: name='com.carriez.flutter_hbb.mirpgtest' versionCode='4114' versionName='1.7.0'`. The script refuses to overwrite an existing APK and restores `local.properties` itself. **Do not install or run adb**; report the APK path and hash and ask the user for the go-ahead to install.
- [ ] **Step 8: Commit** `chore: Aperture 1.7.0 (Play tab, play rail, labels)` with `src/lang/*.rs` and `tools/aperture-release.json`.

---

## Self-review notes

- Spec coverage: §3.1 vocabulary/components → Tasks 1, 3, 4, 8; §3.2 Play tab (grid, order, 3:4, four previews, tap rules, Start, sheet, New + placeholder, pull to refresh, status pill, states, view-only, per-tile failure) → Tasks 3, 5; §3.3 rail, fit rule, chips, `+`, two-tap switch, double-tap previous, switch placeholder, banner, keys row, long-press ▦, double-back, warning chip → Tasks 6, 7, 8; §3.4 checklist, elapsed + 60 s hint, no disabled keys, Back to emulators, Show on PC, failure, visible auto-retry, failure on tile → Tasks 1, 6; §3.6 sheet, rules, New/Clone/Rename/Delete/Stop wording, success snackbars, Label → Tasks 2, 4, 5; §7 decisions → Global Constraints; §5 Phase 1 tests list → Tasks 2–8.
- Deliberate deviations: the Play app-bar "⋮" stays until Phase 2 so End session stays reachable; the landscape expanded rail uses the same two-row overlay instead of mockup 1f′'s merged 56 dp bar; Copying uses the neutral tone (no accent tone exists in `MirpgStatusTone`); a Starting tile shows no phase or timer after the user leaves (the phone only knows the phase of the selected emulator); two-value strings are reworded to one placeholder (`Setting up {} on the PC`, `{} running` with `2/4`).
