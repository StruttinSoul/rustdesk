# Aperture UI redesign: review and proposal

Date: 2026-11-16
Status: proposal for review. No code has been changed.
Scope: the Flutter UI in `flutter/lib/mobile/`, `flutter/lib/desktop/` and `flutter/lib/common/`. The Sciter UI in `src/ui/` is deprecated and out of scope.

How this was produced: by reading the code and five phone screenshots (`s1s.png`, `s2s.png`, `s5s.png` show Aperture; `s3s`, `s4s`, `s6s` show other apps and were not used). Nothing was built or run, so layout claims about pixels come from the code and the screenshots, not from a live device. Line numbers refer to the working tree on `feature/android-emulator-remote` on this date.

Who it is for: one person who runs several Android emulators (Google AVDs, sometimes BlueStacks) on the Windows PC "atlas" to play one game on several accounts, and drives them from an Android phone. The goals every decision is measured against:

- G1 fast switching between several game accounts
- G2 state readable at a glance
- G3 one-handed use
- G4 fewest taps from app launch into a game
- G5 clear feedback while an emulator starts or fails

---

## 1. Direction in one page

**Recommendation: make Aperture an emulator-first remote with one design language ("Studio") and one navigation model, and treat everything inherited from RustDesk as secondary surfaces that get re-skinned, not redesigned.**

Three decisions carry the whole proposal:

1. **The connected Home is the emulator grid.** Every emulator is on the first screen, in a stable order, with a live preview when running and a plain state word. PC monitors shrink to one row. Today Home leads with "Monitor 1" and shows two of four emulators.
2. **Switching accounts happens inside the game, in two taps, with the account name always visible.** A two-row "play rail" sits in the letterbox under the game: one row of account chips, one row of Android keys. Today switching takes four taps through a hidden button and a paged sheet, and nothing on screen says which account is live.
3. **One theme, one vocabulary, one component set across phone and PC.** The Studio palette already exists (`MirpgStudioPalette`) but is applied per page, duplicated as hex literals on desktop, and fights the Material 2 `MyTheme` underneath. Lift it into `common/`, apply it once at the app root, and fix the words ("emulator", "Start", "Stop", "Open") everywhere.

What this deliberately does not do: change the wire protocol, touch Rust, add packages, or rebuild the RustDesk settings, address book, file manager or terminal. Those keep their behaviour and inherit the theme.

### Navigation model (phone)

```
Launch ──auto-connect to last PC──▶ CONNECTED WORKSPACE (bottom tabs)
                                     ├─ Play     emulator grid + PC screens row   (was Home)
                                     ├─ Screens  PC monitors, windows             (was Screens)
                                     └─ PC       system, files, PowerShell,       (was Tools)
                                                 quality, settings, end session
   tap a tile ▶ FULL-SCREEN TARGET (emulator stream or PC monitor)
                 └─ play rail / monitor toolbar: switch target, keys, exit
Not connected ▶ COMPUTERS (ID field + saved PCs)  ·  Share  ·  Settings
```

Rules that apply on every screen:

- **Back never tears down a session by surprise.** Back from a full-screen target returns to the grid; back on the grid shows the existing "still connected" snackbar; ending the session is an explicit item.
- **Primary actions sit in the bottom third.** App bars carry titles and status only.
- **Long-press and the "⋮" button open the same bottom sheet.** No popup menus anchored at the top-right of small cards.
- **State is a word plus a colour, from one list:** Live, Starting, Stopped, Stopping, Copying n%, Problem.

### Navigation model (PC)

The PC is a host first. The 460x560 host panel stays as the main window; "Connect" and "Settings" stay as tabs that expand the window. The only structural addition is an **Emulators** settings page that replaces the BlueStacks-only tab, so the PC shows the same list and the same words as the phone.

---

## 2. Review

Problems are ranked within each area. Each cites a file and line or a screenshot, and the goal it hurts.

### 2.1 Navigation and information architecture

| # | Problem | Evidence | Goal |
|---|---|---|---|
| N1 | **Home hides half the emulators.** Home shows one monitor card first ("Continue working"), then at most two emulator cards; the rest are behind "VIEW ALL". | `target_dashboard_page.dart:1091`, `:1140` (`math.min(guests.length, 2)`); `s2s.png` shows two cards and the footer "4 BlueStacks instances" | G1, G2, G4 |
| N2 | **Switching accounts while playing takes four taps and a full reconnect screen.** Controls are hidden by default; the path is drag-button, "Switch view" icon, paged sheet, card. The sheet lists monitors first, two targets per page, so with 3 monitors the first emulator is on page 2. | `emulator_page.dart:206` (`_guestControlsVisible = false`), `:959-967`; `target_dashboard_page.dart:157-163` (order), `:731`, `:751` | G1, G3 |
| N3 | **Nothing says which account you are playing.** The name chip is drawn only when control is lost or the frame is stale. With identical games on four accounts this is the easiest mistake to make. | `emulator_page.dart:870-892` | G1, G2 |
| N4 | **Only one emulator can be started at a time, and starting one locks the list.** Start is the same call as open; while it runs, every other tile's open action is null. Starting four accounts means four waits in sequence. | `target_dashboard_page.dart:578-599`, `:1567`; `emulator_model.dart:528-556` | G4, G5 |
| N5 | **Three tab bars with different meanings.** Disconnected: Computers / Chat / Share / Settings. Connected: Home / Screens / Tools, where "Tools" leads to System, Files, PowerShell with a back arrow in the app bar while the tab bar stays. The connected dashboard is pushed on top of the legacy RustDesk remote page, which still exists underneath. | `home_page.dart:62-75`; `target_dashboard_page.dart:32-39`, `:883-915`; `remote_page.dart:203-219` | G2 |
| N6 | **Session actions are split across four places:** app-bar "⋮", Tools list, the monitor toolbar "⋮", and the in-game controls. "Quality & connection" appears in three of them; "End session" in one. | `target_dashboard_page.dart:975-990`, `:1208-1222`; `monitor_control_view.dart:1823-1843` | G3 |
| N7 | **The legacy emulator picker is a second, weaker emulator UI.** It has no previews and no management, and is shown when the PC lacks the dashboard feature. | `emulator_page.dart:671-793`; `remote_page.dart:765-769` | G2 |
| N8 | **Emulators cannot be managed on the PC itself.** Desktop settings has a "BlueStacks" tab only; create, clone, rename and delete for AVDs exist only on the phone. | `desktop_setting_page.dart:55-64`, `:216-220` | consistency |

### 2.2 Visual system and wording

| # | Problem | Evidence | Goal |
|---|---|---|---|
| V1 | **Two theme systems.** The app root uses `MyTheme` (Material 2, RustDesk blue `#0071FF`); Studio (Material 3, periwinkle/cobalt) is wrapped around individual pages with `Theme(data: MirpgRemoteTheme.build(...))`. Dialogs, snackbars and routes that are not wrapped fall back to the old look. | `common.dart:375`, `:473`; `mirpg_remote_theme.dart:195`; `main.dart:366`; wrappers at `home_page.dart:79`, `emulator_page.dart:598`, `target_dashboard_page.dart:800`, `:1029` | G2 |
| V2 | **The palette is copy-pasted.** Desktop Aperture widgets repeat the Studio hex values as literals because the palette lives under `mobile/widgets/`. Full-screen views use the "legacy" dark-only constants plus `Colors.white`/`white38`. | `aperture_host_panel.dart:33-38`; `aperture_settings_frame.dart:20-31`; `mirpg_remote_theme.dart:71-82`; `monitor_control_view.dart` (15 literals), `emulator_page.dart:101-109` | maintainability |
| V3 | **One state has many names.** The same running emulator can read "Connecting" (chip), "Waiting for a usable preview" (subtitle, truncated to "Waiting for p…" in `s2s.png`), "Live", "Tap to control". Actions are "Boot", "Resume", "Open", "Reconnect"; stopping is "Stop" for AVDs and "Shut down emulator" for BlueStacks. | `target_dashboard_page.dart:2421`, `:2800`, `:2860-2865`, `:2353`, `:2529`; `emulator_model.dart:104-111` | G2, G5 |
| V4 | **Wrong product words on screen.** "BlueStacks instances" labels AVDs; "Manage Jarvis" names a PC that is not this one; RustDesk appears in settings and the quality sheet. | `target_dashboard_page.dart:1159`, `:1167`, `:1228`, `:1428`, `:1459`; `emulator_page.dart:677`, `:689`; `settings_page.dart:561`, `:1150`; `session_quality_panel.dart:23-27`, `:297` | G2 |
| V5 | **Account names are cut off.** Two-up cards show "BlueStacks App P…" twice in `s2s.png`; the one label that distinguishes accounts is unreadable. | `s2s.png`; `target_dashboard_page.dart:2815-2819` | G1, G2 |
| V6 | **Card component has three layouts chosen by width breakpoints** (narrow, compact, wide) with different captions and buttons in each, so the same emulator looks different on Home, in Screens and in the switcher. | `target_dashboard_page.dart:2378` (`TargetScreenRow`), `:2549` (`TargetPreviewCard`), `:2794-2890` | G2 |
| V7 | **New Aperture screens are English literals; inherited screens use `translate()`.** 0 `translate` calls in `target_dashboard_page.dart`, `emulator_page.dart`, `monitor_control_view.dart`, `host_management_page.dart`. | counted with grep | localisation |

### 2.3 Phone screens

| # | Problem | Evidence | Goal |
|---|---|---|---|
| M1 | **Startup is a spinner and one sentence on an empty page.** No step count, no elapsed time, no indication of what a normal wait is. A disabled Back/Home/Recents bar is shown for an Android that is not there yet. The only way out is the top-left arrow. | `s5s.png`; `emulator_page.dart:643-657`, `:808-822`, `:1108-1121` | G5, G3 |
| M2 | **Failure is raw text with desktop wording.** After 120 s the message is "Return to the desktop or reconnect"; the buttons are "Return to desktop" and "Reconnect emulator". A failed connect also sets the global error, which Home shows as a banner whose button says "Retry discovery" and refreshes the list instead of retrying the emulator. | `emulator_model.dart:542-546`; `emulator_page.dart:829-846`; `target_dashboard_page.dart:1067-1084` | G5 |
| M3 | **Opening and switching flash an app bar.** The scaffold shows an app bar whenever the stream is not live, so each open and each switch jumps from immersive black to a titled page and back. | `emulator_page.dart:608-639` | G1 |
| M4 | **The phone's back gesture leaves the game.** In the stream, system back calls `_back`, which returns to the dashboard. An accidental edge swipe during play drops the stream and costs a reconnect. | `emulator_page.dart:384-396`, `:600-604` | G1, G3 |
| M5 | **Management is behind a small "⋮" on each card and one "New" text button on the Screens tab.** Success is silent; creating an emulator (about 12 GB) gives no progress entry point from Home. Delete is confirmed by a normal filled button. | `target_dashboard_page.dart:620-625`, `:1430-1436`, `:2304-2376`; `avd_manage_sheets.dart:35-51` | G2, G5 |
| M6 | **Show/Hide on PC is not visible as state.** `windowVisible` is only reflected in the menu item's wording. | `target_dashboard_page.dart:2350-2352`; `emulator_model.dart:99` | G2 |
| M7 | **Connection quality is hidden on a phone.** The "Direct · 3 ms" button is shown only at width >= 480 dp, so in portrait the user has only the small "Direct connection" subtitle. | `target_dashboard_page.dart:951`; compare `s1s.png` and `s2s.png` | G2 |
| M8 | **Previews are spent on the wrong targets.** The PC allows four previews; Home uses one for a monitor and two for emulators. | `target_dashboard_page.dart:518-553`; `src/server/emulator/remote.rs:259` (read only) | G2 |
| M9 | **Monitor view has a top bar and a dockable bottom toolbar and a 12-tile controls panel.** It works, but the top bar spends 56 dp on the word "Desktop" and the resolution, and exit is at the top-left. | `monitor_control_view.dart:1711-1778`, `:1845-1907` | G3 |
| M10 | **Computers page spends the first screen on an ID field** the user fills once, above the saved PCs. Mitigated by auto-connect to the last PC on launch. | `connection_page.dart:86-122`; `home_page.dart:49-58` | G4 |
| M11 | **Settings is the RustDesk list unchanged:** about 40 rows, network transport toggles at the top, appearance buried, "About RustDesk". | `settings_page.dart:698-1060` | G2 |

### 2.4 PC screens

| # | Problem | Evidence |
|---|---|---|
| D1 | **Host panel says nothing about emulators or connected phones.** It shows ID, password, service status and "Minimize". For this user the useful facts are "which phone is connected" and "which emulators are running/hidden". | `aperture_host_panel.dart:42-118` |
| D2 | **"BlueStacks" settings tab is the only emulator surface**, and paired phones are under Security. | `desktop_setting_page.dart:216-220`, `:4323` |
| D3 | **Three visual generations coexist:** Studio host panel and settings frame, RustDesk Material 2 content inside the frame, and the untouched connection manager, remote toolbar and file manager using `MyTheme.accent`. | `desktop/pages/server_page.dart` (12 `MyTheme` uses), `desktop/widgets/remote_toolbar.dart`, `desktop/pages/file_manager_page.dart` (25) |
| D4 | **Window resizes on every tab change** between 460x560 and 900x650, which moves content under the pointer. | `desktop_tab_page.dart` diff: `tabController.onSelected` |

---

## 3. Redesign

### 3.1 Design language ("Studio")

Keep the existing palette values; they are already tuned for both modes. Change where they live and how they are applied.

| Token | Dark | Light | Use |
|---|---|---|---|
| background | `#101923` | `#F5F7FA` | page |
| surface | `#1C2938` | `#FFFFFF` | cards, sheets |
| raised | `#26374A` | `#FFFFFF` | inputs, thumbnails |
| accent | `#A4BCFF` | `#2855CC` | selection, links |
| action fill | `#3361D8` | `#2855CC` | filled buttons (white label) |
| good / warning / error | `#70D8B0` / `#FFE0A6` / `#FFB4AB` | `#0C795D` / `#835314` / `#B43E43` | state |
| destructive fill | `#B43E43` | `#B43E43` | Delete, Stop confirmations |

- Spacing 8 dp rhythm, 16 dp page margin, radii 12 (controls) / 16 (cards) / 24 (sheets), minimum touch target 48 dp. These constants already exist in `MirpgRemoteTheme`.
- Over video, always the dark palette (as `MirpgStatusChip.onDarkSurface` already does).
- Type: the platform font, Material 3 scale. Names use `titleMedium`, state uses `labelMedium` weight 600, never below 12 sp.

**Vocabulary (the only words allowed for these things):**

| Thing | Word | Replaces |
|---|---|---|
| a guest | Emulator | Android instance, BlueStacks instance, view, target |
| start it | Start | Boot |
| view and control it | Open | Resume, Tap to control |
| stop it | Stop | Shut down emulator |
| retry a stream | Reconnect | Retry preview |
| PC window | Show on PC / Hide on PC | (unchanged) |
| states | Live, Starting, Stopped, Stopping, Copying n%, Problem | Connecting, Waiting for a usable preview, Attention, Stalled, Disconnected, Unknown, ADB offline |
| the grid tab | Play | Home |
| the PC tab | PC | Tools |

"Problem" always carries one line of cause underneath ("Stream stopped", "Android not responding", or the PC's own message).

**Components (one each, used everywhere):**

- `EmulatorTile` (grid) and `EmulatorRow` (compact list) replace the three layouts of `TargetPreviewCard` for emulators. Monitors keep `TargetScreenRow`.
- `StateBadge` = the existing `MirpgStatusChip` with a fixed mapping from state to tone.
- `ActionSheet` = a bottom sheet of full-width rows with icons; destructive rows last and red.
- `PlayRail` (in-game) and the existing monitor toolbar share one button style.

### 3.2 Phone: Play tab (connected Home)

```
┌──────────────────────────────────────────┐
│ ◧ atlas                     ● Direct 3ms │  title = PC name; status pill always shown
├──────────────────────────────────────────┤
│ Emulators · 2 of 4 running               │
│ ┌──────────────────┐ ┌──────────────────┐│
│ │                  │ │                  ││
│ │   live preview   │ │   live preview   ││
│ │                  │ │                  ││
│ │ ● Live      ▣ PC │ │ ● Live           ││  ▣ PC = window shown on the PC
│ ├──────────────────┤ ├──────────────────┤│
│ │ Main            ⋮│ │ Alt-1           ⋮││  full name, 2 lines allowed
│ └──────────────────┘ └──────────────────┘│
│ ┌──────────────────┐ ┌──────────────────┐│
│ │   ◔ Starting     │ │                  ││
│ │   Android ready, │ │      ▶ Start     ││
│ │   starting screen│ │                  ││
│ │   0:41           │ │   Stopped        ││
│ ├──────────────────┤ ├──────────────────┤│
│ │ Alt-2           ⋮│ │ Alt-3           ⋮││
│ └──────────────────┘ └──────────────────┘│
│                                          │
│ PC screens                               │
│ ┌──────────────────────────────────────┐ │
│ │ ▭ Monitor 1 · 2 · 3              ›   │ │  one row; opens Screens tab
│ └──────────────────────────────────────┘ │
│                          ┌─────────────┐ │
│                          │ ＋ New      │ │  extended FAB, thumb side
│                          └─────────────┘ │
├──────────────────────────────────────────┤
│    ▣ Play        ▭ Screens       ⚙ PC    │
└──────────────────────────────────────────┘
```

Layout and behaviour:

- **Two-column grid of all emulators**, in the PC's list order. Order never changes with state, so each account keeps its position (muscle memory beats "running first").
- Tile preview area is 3:4 with `BoxFit.contain`, so portrait and landscape games both read.
- **All four preview slots go to running emulators** in this tab (no monitor preview). If more than four are running, the four nearest the top of the viewport are live, the rest show their last frame with "Live" still stated from the PC's state.
- **Tap a tile:** Live opens it; Stopped starts and opens it; Starting opens the startup screen; Problem opens it and reconnects.
- **Tap "▶ Start"** on a stopped tile is the same as tapping the tile. See 3.4 for starting several.
- **Long-press a tile, or tap "⋮":** the emulator action sheet (3.6).
- **"＋ New":** the existing name sheet, then a placeholder tile "Setting up…" until the PC lists the emulator (see open question Q4).
- **Pull to refresh** replaces the app-bar refresh button. The 10 s background refresh stays.
- **Status pill** (Direct/Relay and latency) is always shown, in compact form on narrow widths; tapping it opens the existing Quality sheet.
- The app-bar "⋮" is removed from this tab; its items move to the PC tab (3.8).

States:

- **Loading (first list):** four skeleton tiles; no spinner in the centre.
- **Empty:** one card, "No emulators on atlas yet", with a filled "New emulator" button and a line "BlueStacks instances appear here when BlueStacks is installed."
- **List failed:** inline card "Couldn't get the emulator list from atlas" with "Try again". This is the only place the list error appears.
- **View-only session:** tiles are visible with previews; tapping shows a snackbar "atlas hasn't granted control" (today the tap is silently disabled).
- **One emulator's failure** shows on its tile (Problem + cause + "Reconnect" in place of Start), not as a page banner.

### 3.3 Phone: in-game view and switching accounts

```
Portrait game (9:16) on a 19.5:9 phone        Landscape game
┌────────────────────────────┐                ┌───────────────────────────────────────┬────┐
│                            │                │                                       │Main│
│                            │                │                                       │ ●  │
│                            │                │               GAME                    │Alt1│
│           GAME             │                │                                       │ ●  │
│     (whole image, no       │                │                                       │Alt2│
│        overlays)           │                │                                       │ ◔  │
│                            │                │                                       │ ▦  │
│                            │                │                                       │ ⌨  │
│                            │                │                                       │ ◁  │
├────────────────────────────┤                │                                       │ ○  │
│ ●Main  ●Alt-1  ◔Alt-2  ＋  │ accounts row   │                                       │ □  │
│ ▦     ⌨         ◁   ○   □ │ keys row        └───────────────────────────────────────┴────┘
└────────────────────────────┘                 rail on the short edge, collapsible to a dot
```

- **The play rail is on by default when it fits in the letterbox.** A 9:16 game on a 19.5:9 phone leaves roughly 150 dp of black; the rail needs 88 dp (40 dp accounts row + 48 dp keys row). `GuestControlStage` already lays controls outside the image, so the game is not covered or shrunk in that case.
- **When it does not fit** (the game fills the screen), the rail collapses to the existing draggable round button. Tapping it shows the rail over the bottom edge until the next touch on the game.
- **Accounts row:** one chip per emulator that is Live or Starting, in grid order, current one filled. A chip is a name and a state dot; **no live thumbnails** here, because previews of other emulators while playing would take encoder time and bandwidth from the 60 fps stream. "＋" opens the full list (the grid as a sheet) to start a stopped one.
- **Tap a chip:** switch to that account. Two taps at most (one if the rail is docked). **Double-tap the round button** when collapsed: jump to the previously played account (A to B and back).
- **During a switch** the screen stays black-immersive: the last preview frame of the target (if the phone has one) is shown dimmed with the name and a thin progress bar. No app bar, no layout jump. The same treatment is used on first open from the grid.
- **On every open and switch** a name banner ("Alt-1 · Live") shows at the top for 2 s, then fades. The current chip in the rail is the permanent answer to "which account is this".
- **Keys row:** ▦ back to the grid, ⌨ type text (existing composer), ◁ ○ □ Android Back/Home/Recents. Long-press ▦ opens the action sheet for the current emulator (Show/Hide on PC, Stop).
- **Phone back gesture:** first back shows a snackbar "Back again to leave the game" and (if collapsed) reveals the rail; a second back within 2 s returns to the grid. This removes accidental exits without trapping the user. (Alternative in Q2.)
- **Lost control or stale frame:** the existing warning chip stays, with the same wording rules ("Alt-1 · View only", "Alt-1 · Reconnecting…").
- The touch, multi-touch, key and text paths are not changed.

### 3.4 Phone: starting an emulator

```
┌────────────────────────────┐
│                            │
│          Alt-2             │
│     Android Emulator       │
│                            │
│   ✓  Start requested       │
│   ✓  Starting Android      │
│   ◔  Starting the screen   │   current step animates
│   ○  Live                  │
│                            │
│   0:41 · usually under a   │
│   minute                   │
│                            │
│                            │
│ ┌────────────────────────┐ │
│ │  Back to emulators     │ │   primary, bottom; start keeps going on the PC
│ └────────────────────────┘ │
│      Show on PC            │   text button (AVD only)
└────────────────────────────┘
```

- Four fixed steps mapped from the existing phases: `requesting`/`boot_requested`, `starting_android`, `waiting_screen`, `stream_ready`. An emulator that is already running skips to step 3.
- Elapsed time counts up. After 60 s the hint changes to "Taking longer than usual"; the 120 s timeout stays as it is.
- **No disabled Android keys.** The bar at `emulator_page.dart:643-657` is removed from this state.
- **"Back to emulators" leaves the emulator starting** and returns to the grid, where its tile shows "Starting". From there the user can tap another stopped tile. This is how several accounts are started close together without a new protocol action. It depends on the PC continuing to start an emulator after the phone deselects it; see Q1.
- The stream opens by itself when step 4 is reached, as today.

**Failure:**

```
┌────────────────────────────┐
│          Alt-2             │
│                            │
│   ✓  Start requested       │
│   ✕  Starting Android      │
│                            │
│   Couldn't start Alt-2     │
│   <message from atlas>     │
│   Trying again in 3 s (1 of 2)   ← only while auto-retry is armed
│                            │
│ ┌────────────────────────┐ │
│ │  Try again             │ │
│ └────────────────────────┘ │
│   Back to emulators        │
│   Show on PC               │
└────────────────────────────┘
```

- The failed step is marked, so the user sees where it stopped.
- The title is always "Couldn't start <name>" or "Lost the screen for <name>"; the PC's message is the second line, not the headline.
- The existing automatic retry (two attempts, 1 s then 3 s, only for a guest that was live) is kept and made visible.
- The failure is also written on the tile in the grid, and nowhere else.

### 3.5 Phone: Screens tab and monitor view

- **Screens tab:** PC monitors only, as large preview cards (one per row), with "Windows" (the existing window picker) on each. The All/Windows/Android filter is removed because emulators live on Play.
- **Monitor view:** keep `MonitorControlView`, its gestures, keyboard, shortcuts, thumbwheel and dock preference unchanged. Two changes only:
  - Remove the 56 dp top bar. Its "Dashboard" exit moves to the first slot of the bottom toolbar (same ▦ icon as the play rail); resolution and view mode move into the controls panel header; "View only" stays as the floating chip.
  - The toolbar "⋮" items (Clipboard, Windows, Quality) become tiles in the existing controls panel, so there is one place for everything.
- The switcher sheet (`_choose`) lists the current kind first (monitors when on a monitor, emulators when in a game) in a two-column grid instead of two per page.

### 3.6 Phone: managing emulators

Action sheet (long-press or "⋮" on a tile):

```
┌──────────────────────────────────────────┐
│               ────                       │
│ Alt-1                                    │
│ Android Emulator · Android 15 · ● Live   │
│──────────────────────────────────────────│
│ ▶  Open                                  │
│ »  Open and launch game                  │  only when a default game is known
│ ▣  Show on PC            (or Hide on PC) │
│ ■  Stop                                  │
│──────────────────────────────────────────│
│ ⧉  Clone            Stop it first        │  disabled rows say why (existing blocker text)
│ ✎  Rename           Stop it first        │
│ ✕  Delete           Stop it first        │  red
└──────────────────────────────────────────┘
```

- Same items, same enablement rules and same blocker text as `AvdCardActions` today; only the container changes from a popup menu to a bottom sheet. BlueStacks emulators show Open, Launch game and Stop only.
- **New emulator:** unchanged name sheet and note ("Android 15 · 4 GB · 4 cores · about 12 GB on D after setup"), opened from the "＋ New" button. After confirm, a snackbar "Setting up Alt-4 on atlas" and a placeholder tile.
- **Clone:** unchanged sheet; the tile shows "Copying n%" as it does today (the PC already reports the percentage).
- **Rename:** unchanged.
- **Delete:** the dialog gets a red filled button and names what is lost: "Deletes Alt-1 and everything in it, including the game sign-in. This can't be undone." No type-to-confirm; the emulator must already be stopped, which is a sufficient speed bump.
- **Stop:** keeps its confirmation; wording "Stop Alt-1? Apps running in it will close."
- **Success feedback:** a short snackbar for every completed action ("Renamed to Alt-1b"), since silence is hard to tell from failure. Failures keep the PC's message.

### 3.7 Phone: not connected

```
┌──────────────────────────────────────────┐
│ Computers                                │
├──────────────────────────────────────────┤
│ ┌──────────────────────────────────────┐ │
│ │ ▭ atlas                    ● Online  │ │  last-used PC as a hero card
│ │ Trusted · connects without password  │ │
│ │ ┌──────────────────────────────────┐ │ │
│ │ │            Connect               │ │ │
│ │ └──────────────────────────────────┘ │ │
│ └──────────────────────────────────────┘ │
│ Other computers                          │
│  (existing saved / recent / discovered)  │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ Computer ID                       →  │ │  ID field at the bottom, above the tabs
│ └──────────────────────────────────────┘ │
├──────────────────────────────────────────┤
│  ▭ Computers    ⇪ Share    ⚙ Settings    │
└──────────────────────────────────────────┘
```

- Auto-connect to the last PC on launch stays; this page is what the user sees when that fails or after "End session", so it leads with the same PC and one button.
- The ID field moves below the list, into thumb reach. `PeerTabPage` is reused as is.
- **Connecting:** the hero card shows "Connecting to atlas…" with Cancel, instead of the generic RustDesk dialog. **Failure:** the card shows the reason and "Try again".
- **Chat** leaves the tab bar (it is for incoming sessions to the phone) and is reached from Share. Share and Settings keep their content.
- **Pairing:** after the first password login on the home network, a one-time bottom sheet offers "Trust this phone on atlas? Next time it connects without a password." Today this is an item in the "⋮" menu that the user has to find (`target_dashboard_page.dart:2215-2223`). "Forget pairing" stays in the PC tab.

### 3.8 Phone: PC tab and Settings

```
┌──────────────────────────────────────────┐
│ atlas                       ● Direct 3ms │
├──────────────────────────────────────────┤
│ This PC                                  │
│  System and processes                 ›  │
│  Files                                ›  │
│  PowerShell                           ›  │
│ Connection                               │
│  Quality and connection               ›  │
│  Privacy and host controls            ›  │
│  This phone is trusted · Forget       ›  │
│ App                                      │
│  Appearance and settings              ›  │
│──────────────────────────────────────────│
│  End session                             │  red, last
└──────────────────────────────────────────┘
```

- This is the single home for everything that is in the app-bar "⋮" and the Tools list today. The subtitle uses the real host name (fixes "Manage Jarvis").
- System, Files and PowerShell open as pushed pages with a normal back arrow; the tab bar hides while inside them.
- **Settings:** keep every existing RustDesk row and its key. Reorder into Appearance (theme, language), Display defaults, Sharing this phone, Security (2FA, trusted devices), Network (collapsed "Advanced" group: ID/relay server, proxy, WebSocket, UDP, hole punching, IPv6, WebRTC), Recording, About Aperture ("Built on RustDesk" as a line, as desktop already does).

### 3.9 PC: host window

```
┌───────────────────────────────────────────────┐
│ ◧ Aperture                                 ⚙ │
│                                               │
│ atlas                         ● Ready         │
│ ID 123 456 789    Password ••••••  [new] [show]│
│───────────────────────────────────────────────│
│ Connected                                     │
│  Phone · Direct · 12 min                      │   empty: "No phone connected"
│───────────────────────────────────────────────│
│ Emulators · 2 of 4 running            Manage  │
│  ● Main     Live       Hidden    [Show]       │
│  ● Alt-1    Live       Shown     [Hide]       │
│  ◔ Alt-2    Starting                          │
│  ○ Alt-3    Stopped              [Start]      │
│───────────────────────────────────────────────│
│  Connect to another PC          [ Minimize ]  │
└───────────────────────────────────────────────┘
```

- Adds two read-mostly sections to the existing `ApertureHostPanel`: who is connected, and the emulator list with Show/Hide and Start. Same words and state colours as the phone.
- "Manage" opens Settings at the Emulators page.
- The window keeps one size per mode but stops resizing when switching between Connect and Settings (both 900x650); it only shrinks when returning to the host panel.

### 3.10 PC: Settings, Emulators page, and the rest

- **Settings frame:** keep `ApertureSettingsFrame`. Rename the "BlueStacks" page to **Emulators**: a table of all emulators (name, type, state, PC window, storage path `D:\Aperture\Emulators`) with New, Clone, Rename, Delete, Start, Stop, Show/Hide, and the existing BlueStacks options beneath as a sub-section. Add **Phones** as its own page (moved out of Security) listing paired phones with Remove.
- **Connection manager (incoming session window), remote window toolbar, file manager, terminal, address book:** behaviour untouched. They pick up Studio colours, radii and button styles from the root theme; replace `MyTheme.accent` literals where they produce RustDesk blue.
- **Connect tab:** unchanged layout, Studio theme.

---

## 4. What stays

Behaviour that must keep working exactly as it does now:

- **Input paths:** emulator touch/multi-touch mapping (`mapEmulatorTouch`, pointer cancel on geometry change, focus loss and background), hardware-key mapping, the text composer and its send/restore logic, Android Back/Home/Recents; all monitor gestures, live keyboard, shortcut presets, thumbwheel, right/middle-click arming, Ctrl+Alt+Del, restart taskbar, clipboard transfer, window focus.
- **Session safety:** control gated on `keyboard && !viewOnly`, on foreground and view focus, and on a fresh guest frame; input released on background and permission loss; monitor liveness checks.
- **Recovery:** automatic reconnect limits (two attempts, only for a guest that was live, only in the foreground), the 120 s start timeout, the 25 s list timeout, preview acknowledgement and the 8 s frame-age rule.
- **Protocol:** every `emulator-request` action and field (`list`, `select`, `desktop`, `previews`, `avd_*`, `emulator_shutdown`), capability checks (`host.avd_manage.v1`, `host.emulator_shutdown.v1`, others), operation identity and acknowledgement, the four-preview limit, stopped emulators never taking a preview slot.
- **Management rules:** name validation and reserved names, "Stop it first" and "Copy in progress" blockers, confirmations before Stop and Delete, defaults (Android 15, 4 GB, 4 cores, `D:\Aperture\Emulators`).
- **Presentation:** orientation follows the guest, immersive mode while streaming, per-monitor preferences stored under the existing keys, quality profile storage, System/Light/Dark preference.
- **Entry points:** auto-connect to the last PC, deep links, the fallback `EmulatorPage` picker for PCs without the dashboard feature (copy fixes only), the legacy remote page for non-Aperture peers.
- **Inherited features:** files, terminal, share-this-phone, 2FA, trusted devices, address book, all settings keys, all existing translation keys and the hand-maintained Italian file.
- **PC:** host service, ID/password board logic, tray/minimise behaviour, the connection manager's permission toggles, pairing list and removal.

---

## 5. Implementation outline

All phases are Flutter-only unless marked. No new packages. Each phase can ship on its own.

### Phase 1 - Emulator and game flow (phone)

| Change | Files | Notes |
|---|---|---|
| Play tab: grid, PC screens row, New button, per-tile errors, pull to refresh | `mobile/pages/target_dashboard_page.dart` (`_homeBody`, `_subscribe`, `_card`) | Preview selection changes from "1 monitor + 2 guests" to "up to 4 running guests" on this tab |
| `EmulatorTile`, `EmulatorRow`, `EmulatorActionSheet`, state mapping | new `mobile/widgets/emulator_tile.dart`, `mobile/widgets/emulator_action_sheet.dart` | Extract from `TargetPreviewCard` / `AvdCardActions`; keep `AvdCardActions` as the data class so its tests still apply |
| One function for state: `emulatorUiState(instance, preview, flags)` returning word, tone, cause | `models/emulator_model.dart` (pure function next to `runtimeLabel`) | Replaces the label logic duplicated at `target_dashboard_page.dart:2415-2440`, `:2590-2615`, `:2830-2866` |
| Play rail with account chips, name banner, switch placeholder, double-back | `mobile/pages/emulator_page.dart` (`GuestControlStage`, `_guestControls`, `_guest`, `build`, `PopScope`) | `EmulatorPage` gains `runningTargets` and `onSelectTarget(id)` callbacks supplied by the dashboard; `_open` is reused |
| Startup stepper and failure screen; remove disabled keys bar | `mobile/pages/emulator_page.dart` (`_guest`, `_startupLabel`, `bottomNavigationBar`) | Uses existing `startupPhase`, `error`, `_guestReconnectTimer`; elapsed time is a local `Stopwatch` |
| Delete/Stop dialog wording and destructive style; success snackbars | `mobile/widgets/avd_manage_sheets.dart`, `_reportAvdResult` | |
| Vocabulary and wrong-name fixes | the files in V3/V4 | |
| Tests | `flutter/test/target_dashboard_test.dart` (26 cases), `guest_control_stage_test.dart`, `emulator_shutdown_test.dart`, `avd_manage_sheets_test.dart` | Expect to rewrite finders that match old strings ("Boot", "Resume", "Shut down emulator") and card layout; add tests for state mapping, rail fit rule, double-back |

Size: about 900-1,200 changed lines, most of it moving card code out of the 2,966-line dashboard file. Largest single phase.

Risks:
- **Rail fit rule** must be computed from guest and viewport aspect, with hysteresis, or the rail will flicker when the keyboard or system bars change the viewport. Pointer mapping must be re-checked with the rail docked (`didChangeMetrics` already cancels input).
- **Switch placeholder** depends on a cached frame for the target; when there is none, show the name on black.
- **Start-and-leave** depends on Q1.
- **String changes** break tests that match text; update them in the same change.

### Phase 2 - One theme, one shell (phone)

| Change | Files |
|---|---|
| Move palette, theme builder and `MirpgSurface`/`MirpgSectionHeader`/`MirpgStatusChip` to `common/widgets/studio_theme.dart`; keep `mirpg_remote_theme.dart` as a re-export so imports do not churn | `common/`, `mobile/widgets/mirpg_remote_theme.dart` |
| Apply Studio at the mobile app root instead of per page; remove the per-page `Theme(...)` wrappers | `main.dart`, `home_page.dart`, `emulator_page.dart`, `target_dashboard_page.dart` |
| Tabs become Play / Screens / PC; PC tab absorbs the session menu; System/Files/PowerShell become pushed pages | `target_dashboard_page.dart` (`_ConnectedPcSection`, `ConnectedPcTabBar`, `ConnectedPcSessionMenu`, `_toolsBody`) |
| Screens tab: monitors only; switcher sheet as a grid | `target_dashboard_page.dart` (`_devicesBody`, `_choose`, `TargetSwitcherCards`) |
| Monitor view: remove top bar, exit in toolbar, session items into the controls panel; replace legacy colour constants with palette lookups | `mobile/widgets/monitor_control_view.dart` |
| Computers page: hero card, ID field at bottom, inline connecting/failure; Chat out of the tab bar; pairing prompt | `mobile/pages/connection_page.dart`, `home_page.dart`, `target_dashboard_page.dart` (`_refreshPairingState`) |
| Settings regrouping | `mobile/pages/settings_page.dart` |

Size: about 700-900 lines. Risks: switching the root theme to Material 3 changes inherited RustDesk dialogs (`common/widgets/dialog.dart`) and the settings list; they need a visual pass. `home_page_shell_test.dart`, `mirpg_remote_theme_test.dart` and `monitor_control_view_test.dart` will need updates. The inline connecting state must not bypass the existing password and 2FA dialogs.

### Phase 3 - PC host and settings

| Change | Files |
|---|---|
| Host panel: connected-phones and emulators sections | `desktop/widgets/aperture_host_panel.dart`, `desktop/pages/desktop_home_page.dart` |
| Settings: Emulators page (replaces BlueStacks tab), Phones page | `desktop/pages/desktop_setting_page.dart` (`SettingsTabKey`, `_BlueStacksSettings`, paired-phones widget at `:4323`) |
| Use the shared palette instead of literals | `aperture_host_panel.dart`, `aperture_settings_frame.dart` |
| Stable window size between Connect and Settings | `desktop/pages/desktop_tab_page.dart` |

Size: about 500-700 lines of Flutter. **Needs Rust:** a local way for the PC's own UI to list and manage emulators (the phone goes through the session protocol; the PC window has no session). That is a small bridge over the existing host functions in `src/server/emulator/`, and must be scheduled with whoever owns those files. Without it, Phase 3 can still ship the panel's "Connected" section, the Phones page and the theme work.

### Phase 4 - Inherited desktop surfaces and localisation

| Change | Files |
|---|---|
| Apply Studio at the desktop root; replace `MyTheme.accent` where it shows RustDesk blue | `common.dart` (`MyTheme.lightTheme`/`darkTheme`), `desktop/pages/server_page.dart`, `desktop/widgets/remote_toolbar.dart`, `desktop/widgets/tabbar_widget.dart`, `desktop/widgets/button.dart`, `desktop/pages/file_manager_page.dart` |
| Move Aperture strings to `translate()` keys | all Aperture pages; `src/lang/*.rs` per `docs/agents/LOCALIZATION.md` (sentence-case keys, append to `template.rs` and every language file, `""` in `it.rs`) |

Size: theme about 300-400 lines across many files; localisation is mechanical but touches every language file (roughly 150-200 new keys). Risk: desktop regressions are spread thinly across many inherited screens; do it last and review screen by screen. Until Phase 4, new strings stay as English literals in sentence case so each becomes its own key unchanged.

---

## 6. Open questions

Only those whose answers change the design.

- **Q1. Does an emulator keep starting on the PC after the phone leaves its startup screen?** The "start one, go back, start the next" flow in 3.4 assumes yes (leaving sends `desktop`, which deselects). If the PC cancels the start, starting several accounts needs a new "start without opening" action on the PC (Rust), and until then the startup screen should say "Stay here until it's live".
- **Q2. What should the phone's back gesture do inside a game?** Proposed: double-back to leave. The alternative is "back sends Android Back to the game" with exit only on the rail, which suits games that use Back heavily but removes the system exit.
- **Q3. How many emulators run at once, and are the games portrait or landscape?** The grid, the four-preview budget and the docked rail are tuned for up to about six emulators and portrait games. With eight or more, or mostly landscape games, the grid should be three columns of smaller tiles and the rail should default to the collapsed button.
- **Q4. Do you want a per-account label separate from the emulator's name?** Emulator names allow only letters, digits, `.`, `_`, `-`. If accounts should read as "Main", "Alt 1 (EU)", a phone-side label (stored locally, shown on tiles and chips) is a small addition; if the emulator name is enough, nothing is needed. Related: whether the PC lists an emulator while it is being created, which decides if the "Setting up…" tile is real or a phone-side placeholder.
- **Q5. Should opening an emulator also launch the game?** A default game exists only where the PC reports `defaultPackage`. If the answer is "always", tap becomes "Open and launch game" and plain Open moves to the sheet.
- **Q6. Is the PC ever used to connect out, or only as a host?** If only a host, the "Connect" tab and address book on the PC can be removed from the main path and Phase 4 shrinks considerably.
- **Q7. Is the phone used to connect to any PC other than atlas?** If not, the Computers page can drop the list entirely and be a single card with the ID field under "Add another computer".

## 7. Decisions (user, 2026-11-16)

The user approved the redesign direction and answered the open questions:

| Question | Decision | Effect on the design |
|---|---|---|
| Q1 Start several in a row | **Start one, go back, start the next** (as proposed). Verified in code: the PC launches the emulator as its own process (`avd_launch_windows.rs`), and leaving the startup screen only cancels the phone's session, so the emulator keeps booting. | 3.4 stands; no new PC action needed. |
| Q2 Back gesture in a game | **Press back twice to leave** (as proposed). | 3.3 stands. |
| Q3 How many at once | **4 emulators.** Orientation not stated, so portrait and landscape both stay first-class. | Grid and four-preview budget fit exactly; rail docks in portrait letterbox and collapses to the button in landscape (3.3). |
| Q4 Own label per account | **Yes.** A phone-side label per emulator, stored locally on the phone, shown on tiles, chips and the name banner; the emulator name stays as the secondary line and is what the PC sees. | Add "Label" to the action sheet (3.6) and a label field in the New/Clone sheets; Phase 1 scope. |
| Q5 Tap opens and launches the game | **No: tap just opens.** Launching the game stays a separate action. | 3.6 stands ("Open and launch game" in the sheet). |
| Q6 Atlas connects out | **No, atlas is only a host.** | Phase 4: remove the Connect tab/address book from atlas's main path (keep reachable from Settings for recovery); Phase 4 shrinks. |
| Q7 Phone connects to other PCs | **No, only atlas.** | 3.7: Computers page becomes the single atlas hero card; the list and "Other computers" go; the ID field moves under "Add another computer" (collapsed). |
