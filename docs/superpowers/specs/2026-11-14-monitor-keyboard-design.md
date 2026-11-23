# Remote view keyboard: working keys and a visible PC — design (2026-11-14)

## Why
Typing into Windows from the phone's remote view (Monitor view in `target_dashboard_page.dart` / `monitor_control_view.dart`) has two problems the user reported:

1. **Ctrl, Alt and the other strip keys do nothing.** Cause: every key the live keyboard strip sends (Ctrl, Alt, Shift, Win, Esc, Tab, arrows, Del, Home, End, shortcut letters) and the Backspace/Enter that Gboard produces go through `inputModel.newKeyboardMode(kKeyFlutterKey, hid, …)`. On the native side `"flutter_key"` reaches `_handle_key_flutter_simulation` (`src/ui_session_interface.rs`), which only maps volume mute/up/down and power and drops everything else. Only plain text (sent with `sessionInputString`) reaches Windows.
2. **In landscape the keyboard covers the whole screen.** The remote picture is shrunk to fit above the "Desktop" header, the key strip and Gboard; in landscape that leaves no picture at all, so the user types blind.

## Goals
- Every strip key and Gboard's Backspace/Enter reach Windows. Ctrl/Alt/Shift/Win combine with the next key (letter from Gboard or strip key), e.g. Ctrl then C copies.
- While typing, the PC stays visible around the place being typed into.

## Non-goals / anti-goals
- **No type-then-send box** (user's decision). Keystrokes keep going to Windows as typed.
- No custom replacement for Gboard; the phone keyboard stays.
- No change on the PC (host) side; phone app only.
- Desktop (Windows client) UI and the emulator (guest) view are untouched.

## Approaches considered
- **Keys:** one sensible way — send keys by name with the held modifiers attached to each event (`inputModel.inputKey(name, alt:, ctrl:, shift:, command:)`, legacy key mode), as upstream RustDesk's mobile remote page does. The alternative, teaching the `flutter_key` route every key, would change shared native code for something the named-key path already does.
- **Layout (user chose A):**
  - **A. Keyboard covers the picture; the view pans to where you type.** Header hides while typing; picture keeps its zoom and scrolls so the last tapped spot sits just above the key strip. What most remote apps do (Jump Desktop, Splashtop).
  - B. Keep shrinking but hide the header and zoom into the tapped area. Rejected: in landscape the space left is a thin strip.

## Design
### Keys
- Strip and Gboard special keys are sent with `inputKey` using the client's named keys (`VK_ESCAPE`, `VK_TAB`, `VK_LEFT`/`UP`/`RIGHT`/`DOWN`, `VK_DELETE`, `VK_HOME`, `VK_END`, `VK_PRIOR`/`VK_NEXT`, `VK_BACK`, `VK_RETURN`, `VK_F1`–`VK_F12`, `VK_INSERT`) and single characters for letters/digits/symbols; Win alone is `Meta`.
- Held modifiers (the strip's existing Off → Once → Locked states) are sent as their own key down/up events and are also carried as the `ctrl`/`alt`/`shift`/`command` flags on every key event, so the PC never drops them. The real down/up is what lets Win alone open Start and a held Alt keep the Alt+Tab switcher open. With Shift alone, characters are sent already shifted (US layout), because the PC types characters as text, which ignores a held Shift. "Once" releases after the next key; "Locked" stays until tapped again.
- Plain typing without any modifier held keeps using `sessionInputString` (unchanged; it works today).
- Shortcut presets (Ctrl+C, Alt+Tab …) are sent the same way.
- Releasing everything on close/disconnect keeps working (no stuck modifiers on Windows).

### Layout (A)
- While the live keyboard is open: the "Desktop" header is hidden; the remote picture is **not** resized for the keyboard. The key strip and Gboard overlay its lower part.
- The view pans so the point the user last tapped on the PC is just above the key strip (with a small margin). If the user drags the picture while typing, their position wins until the next tap.
- Closing the keyboard restores the header and the previous view.
- Portrait gets the same behaviour.

### Strip
- The compose button (opens the old panel with a type-then-send Text tab) is removed. **My call:** that panel is also where shortcut presets are edited, so the button is replaced by a **Shortcuts** button that opens only the shortcut settings.

## Verification
- Widget tests: Ctrl then a Gboard letter sends one key event with ctrl set; Esc/arrows/Del send named keys; Gboard Backspace/Enter send `VK_BACK`/`VK_RETURN`; Once releases after one key, Locked persists; header hidden and picture size unchanged while the keyboard is open; view pans to keep the last tap above the strip.
- On the phone against atlas: Ctrl+C / Ctrl+V in Notepad, Alt+Tab, Win (Start opens), arrows, Backspace, Enter, and the PC visible while typing in landscape.

## Left to the builder
- Exact pan margin and animation; how the visible area above the keyboard is measured (`viewInsets` plus strip height).
- Where the named-key mapping lives (a small pure function is preferred so it can be unit-tested).
