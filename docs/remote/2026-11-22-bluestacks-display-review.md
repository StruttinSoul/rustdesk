# BlueStacks display, black flashes and KVM switching on atlas

Date: 2026-11-22
Status: **read-only investigation.** Nothing was changed on atlas: no display, driver, registry, power, BlueStacks or window change, nothing restarted. No code was changed. BlueStacks was closed during the investigation (last instance stopped 00:19), so no flash was observed live; the findings come from logs and configuration.

## Plain-language summary

**What is installed.** The "driver for no displays" is the **MikeTheTech Virtual Display Driver** (`Root\MttVDD`, version 11.30.4.434, built December 2024, files in `C:\VirtualDisplayDriver`). It was installed on 2026-11-12 at 20:07 by a Codex session ("open-aperture-please"), after RustDesk's own built-in virtual display (Amyuni `usbmmidd`) was installed automatically at 19:59 and crashed one minute later. It is not part of BlueStacks and Windows did not add it.

**How it behaves.** While the two Dell monitors are attached, the virtual screen exists but is switched off (Windows shows only the two Dells). The moment Windows loses the Dells, the virtual screen becomes the only screen. Every such hand-over is a full display re-configuration, and this driver build often crashes during it.

**KVM problems: cause found, high confidence.**
- Each time the KVM takes the monitors away, Windows reports both Dells as unplugged. One of them (the second, `UID4355`) is reported unplugged a second time about 7 seconds later. This pattern is in the log since 2026-10-21, so the KVM behaviour is older than the driver.
- Before 11-12 Windows had nothing to switch to, so little changed. Now Windows moves the whole desktop to the virtual screen and back on every switch. Windows are moved and resized to fit the virtual screen, then moved back.
- The virtual display driver crashed 20 times between 11-13 and 11-19. **17 of those 20 crashes happened within 12 seconds of the Dells disappearing.** After a crash Windows has no screen at all until the driver is restarted (by Windows, or by Aperture's watchdog).
- No crash has been logged since the reboot on 11-19 22:06, across about 20 KVM switches on 11-20. The cause of the crashes is not fixed; it may simply not have recurred yet.

**Black flashes with an emulator open: most likely cause, medium confidence.** No log records "the screen went black", so this is inferred. Three things on this PC blank the monitors, and all three are tied to emulator use:
1. **Display re-configurations.** Any change in the set of screens (virtual display crash or restart, a Dell dropping off the cable, monitors waking or sleeping) blanks every monitor for a moment. A phone session wakes the monitors when it starts and lets them go off about 10 seconds after it ends; when they go off, the second Dell drops off the bus again. One driver crash (11-19 21:23:44) happened 2 seconds after a BlueStacks instance was closed, with the Dells attached.
2. **Graphics driver errors.** The NVIDIA driver has logged errors on 11 days since 10-26, including on 11-21 at 17:48 while both emulators were running. These can show as a short black flash.
3. **One full graphics reset** on 11-21 at 23:12: screens black for about 30 seconds, both BlueStacks players lost the GPU, and Aperture's window crashed. It started 44 seconds after a phone session ended and a Dell dropped off.

Which of 1 and 2 the user is seeing needs one short test (steps below).

**BlueStacks display for streaming.** Settings are mostly sensible. The main points:
- There are **two** instances on atlas (App Player 1 and 2), not three.
- App Player 1 is set to **OpenGL**, App Player 2 to **Vulkan**.
- Both are 2340x1080 at 240 dpi, 4 CPU cores, 4 GB RAM, 60 fps allowed, high-FPS on, V-sync off.
- The game draws about 30 fps by its own choice; BlueStacks is not the limit. Aperture's stream is also capped at 30 fps and 1280 pixels wide, so today the phone gets a picture scaled up 2.3 times.
- For the planned host capture, the BlueStacks window size becomes the stream size, and the window must sit on a working screen. **That makes the virtual display and KVM behaviour above a blocker for host capture, not a side issue.**

## Recommendations, in priority order

"Approval" means it changes a system setting, driver or BlueStacks setting and must not be done without the user's go-ahead.

| # | Recommendation | Why | Approval |
|---|---|---|---|
| 1 | Run the two short tests under "Steps for the user" | Tells flash cause 1 from cause 2, and confirms the KVM sequence | No (user action only) |
| 2 | Stop Windows from seeing the monitors leave: turn on EDID emulation / "DDC keep-alive" on the KVM if it has it, or add DisplayPort EDID emulators on the two atlas ports | Removes the hand-over to the virtual screen on every switch, the window shuffling, and the trigger for 17 of 20 driver crashes. Also keeps a real screen active for host capture | Hardware / KVM setting (user) |
| 3 | Replace MttVDD 11.30.4.434 (Dec 2024) with the current Virtual Display Driver release | This build crashes on hand-over. Aperture only recovers from it (`src/headless_vdd.rs`), it does not prevent it | **Yes** (driver change) |
| 4 | Give the virtual screen the same mode as a Dell (2560x1440 @ 60) and remove the 800x600 and 1366x768 modes | Windows no longer resizes windows when the virtual screen takes over; no risk of landing on 800x600 | **Yes** (driver settings file + display mode) |
| 5 | Remove the unused Amyuni driver package (`oem33.inf`, `usbmmidd`) and stop Aperture from plugging in its own virtual display when it sees no screen | Upstream RustDesk code (`display_service.rs:1056-1063`) still installs a second virtual display when there is no screen. It did so on 11-12 and that driver crashed. Two virtual display drivers must not fight over the same moment | **Yes** (driver store) + code change |
| 6 | Update or roll back the NVIDIA driver (32.0.16.2114, 2026-10-27) and check the GPU if errors continue | Driver errors on 11 days since 10-26, one GPU "failing" removal on 11-13, one full reset on 11-21. Windows is build 26300 (pre-release branch), which adds risk | **Yes** (driver change) |
| 7 | Stream profile: raise the BlueStacks stream from 1280 px to 1920 px or more and 8 Mbit/s; keep 30 fps until the game draws more | The phone area is 2940 px wide; 1280 is scaled up 2.3x. Code/option change only (`aperture-guest-max-size`, `guest_runtime.rs:111-116`) | No system change; code/options |
| 8 | Check whether the game can draw 60: its own graphics/frame-rate setting, with BlueStacks Eco mode off | BlueStacks already allows 60. The game is the limit. Nothing above 30 is worth building until this is known | User check in the game |
| 9 | Make both instances use the same renderer, and turn off the FPS counter on App Player 2 | Different renderers make results differ between instances; the counter appears in a host-captured picture | **Yes** (BlueStacks settings) |
| 10 | For host capture: size each BlueStacks window so the Android area is at least 1920 px wide (2340x1080 fits on one Dell), and only after 2-4 are settled | Stream size follows window size; today's windows are about 990x457 | **Yes** (window size/position) |
| 11 | Optional, if flashes remain after 2-6: test with G-SYNC off for windowed apps, and with multiplane overlays (MPO) off | Known causes of black flicker with windowed GPU apps on NVIDIA; cannot be confirmed from logs | **Yes** (NVIDIA / registry setting) |

## Steps for the user

These need the user because they involve watching the screen or pressing the KVM. Note the clock time to the second each time.

1. **Flash test.** With both emulators open and no phone connected, work normally for 30 minutes. Each time the monitors flash black, write down the time and whether one or both monitors went black, and for how long. Then say so; the event logs for those seconds will show which cause it was (a Dell "surprise removed" entry, a virtual display driver entry, an `nvlddmkm` entry, or nothing).
2. **Phone session test.** With the emulators open and the monitors on, connect from the phone, wait one minute, disconnect. Note whether the monitors flash at connect or within 15 seconds after disconnect.
3. **KVM test.** Switch the KVM away, wait 30 seconds, switch back. Note the two times and what was wrong afterwards (which windows moved, wrong resolution, wrong main screen, BlueStacks position).
4. **Service log.** The Aperture service log is in a SYSTEM-only folder (`C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log`). Copying it out from an elevated prompt would let display changes be matched to sessions exactly.

## Questions for the user

1. When the monitors flash black, are you sitting at atlas with the monitors on, and is a phone connected at that moment? One monitor or both? Roughly how long (a blink, 1-2 seconds, longer)?
2. Were you pressing the KVM around 20 times between 11:17 and 16:18 on Friday 11-20? If not, those entries are the monitors dropping out by themselves, which changes the diagnosis.
3. On Saturday 11-21 at 23:11-23:13, did you see the screens go black for about half a minute, and did you touch the KVM or the monitors just before?
4. Which KVM model is it, and does it have EDID emulation? The Dells are running at 60 Hz although they offer 165 Hz; is that the KVM's limit?
5. What exactly goes wrong after a KVM switch: windows on the wrong monitor, wrong size, a black monitor, BlueStacks off-screen, or the phone showing "No displays"?
6. Do you want atlas to keep a virtual screen at all? It is needed only for the phone's Windows desktop view when no monitor is attached. The emulator stream as built today does not need it; host capture would.
7. In landscape, is the 48 dp bar on a long edge or a short edge of the phone? It decides the best Android resolution (see the table below).
8. Is the third BlueStacks instance meant to exist on atlas? Only two are configured.
9. Does the game have a frame-rate or graphics-quality setting, and what is it set to?

---

# Technical detail

## 1. Display hardware and drivers on atlas

| Item | Value | Source |
|---|---|---|
| GPU | NVIDIA GeForce RTX 3080, driver 32.0.16.2114 (621.14), dated 2026-10-27, status OK | `Win32_VideoController`, `pnputil /enum-drivers` |
| Integrated GPU | Intel UHD 770, **disabled** (problem code 22) | `Get-PnpDevice` |
| Virtual display adapter | "Virtual Display Driver", `ROOT\DISPLAY\0000`, hardware ID `Root\MttVDD`, provider MikeTheTech, 11.30.4.434 (2024-12-24), `oem34.inf`, signer SignPath Foundation, UMDF (`WUDFRd`, upper filter `IndirectKmd`), problem code 0 | `Get-PnpDeviceProperty`, driver store |
| Virtual monitor | "Generic Monitor (VDD by MTT)", `DISPLAY\MTT1337\...UID256`, present | `Get-PnpDevice`, `WmiMonitorID` |
| Leftover package | Amyuni `usbmmidd.inf` 2.0.0.1 as `oem33.inf`; no device uses it now | driver store |
| Physical monitors | 2 x Dell S2721DGF on DisplayPort (`UID4353`, `UID4355`), both 2560x1440 **@ 60 Hz**; modes up to 165 Hz are offered | `EnumDisplaySettings` |
| Windows | 11 Pro 26H2, build 26300.9974 | registry |
| Monitor off timer | 3600 s on AC; sleep never | `powercfg /q` |
| CPU / RAM | i7-12700K (20 threads), 64 GB, Hyper-V present | CIM |

**Who installed the virtual display** (`C:\Windows\INF\setupapi.dev.log`):
- 2026-11-12 19:59:42: `"C:\Program Files\RustDesk\RustDesk.exe" --server` installed `usbmmidd` from `C:\Program Files\RustDesk\usbmmidd_v2\`. This is upstream RustDesk's "no display, plug in a headless one" path.
- 20:00:18: `usbmmIdd.dll` crashed (UMDF event 10121).
- 20:07:43: `pnputil /remove-device ROOT\DISPLAY\0000`.
- 20:07:43: `"C:\Users\gregr\Documents\Codex\2026-11-12\open-aperture-please\aperture-display-driver\usbmmidd_v2\deviceinstaller64.exe" install C:\VirtualDisplayDriver\MttVDD.inf Root\MttVDD`.
- Aperture's own code never installs MttVDD. It only restarts it when it has failed: `src/headless_vdd.rs` (`pnputil /restart-device`, at most once per 60 s), called from the watchdog every 20 s and at login when there is no screen (`src/server/display_service.rs:918-956`). See `docs/remote/2026-11-13-headless-screen-recovery.md`.

**Driver settings** (`C:\VirtualDisplayDriver\vdd_settings.xml`, last written 2026-11-12 20:07): 1 monitor, bound to the RTX 3080, modes 800x600, 1366x768, 1920x1080, 2560x1440, 3840x2160, refresh rates 30/60/90/120/144/165/244, hardware cursor on, HDR off, logging off.

## 2. Current display layout

`EnumDisplayDevices` at 01:14 on 11-22, Dells attached:

| Device | Adapter | State | Mode |
|---|---|---|---|
| `\\.\DISPLAY1` | RTX 3080 | attached, primary, Dell | 2560x1440@60 at (0,0) |
| `\\.\DISPLAY2` | RTX 3080 | attached, Dell | 2560x1440@60 at (2560,0) |
| `\\.\DISPLAY3`, `4` | RTX 3080 | not attached | - |
| `\\.\DISPLAY5` | Virtual Display Driver | **not attached to the desktop**; monitor present | - |

So with the Dells present the virtual monitor is connected but inactive. `Win32_VideoController` reports 800x600@30 for the virtual adapter; that is not a live mode. The mode it takes when it becomes the only screen could not be read (see limits). `docs/remote/2026-11-13-phone-key-pairing.md` says it was set to 1920x1080@60 on 11-13.

**Not readable:** `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration` and `\Connectivity` returned "Requested registry access is not allowed" from this non-elevated session. The saved per-topology layouts (which mode the virtual screen takes alone, which screen is primary in each set) are therefore not confirmed. `powercfg /requests` also needs elevation.

## 3. What happens on a KVM switch

Evidence: `Microsoft-Windows-Kernel-PnP/Device Management`, event 1010 "surprise removed as it is reported as missing on the bus" for the two Dells. 1,148 such events since 2026-10-21.

- **Pattern per switch:** both Dells removed at T, then `UID4355` removed again at about T+7 s. Example 11-20: 13:14:54 both, 13:15:01 `UID4355`. The second Dell is therefore re-detected and lost again a few seconds into every switch, which doubles the display re-configurations.
- **Days:** heavy on weekdays (60-100 events per day), light on weekends (2-5). This fits KVM use, and it predates the virtual display (10-22 to 11-11 show the same 2:1 ratio between the two monitors).
- **Sequence now:** Dells removed -> Windows applies the "virtual screen only" layout -> desktop, taskbar and all windows move to the virtual screen and are clamped to its size -> `UID4355` reappears and disappears -> on switch-back both Dells arrive -> Windows applies the two-Dell layout and turns the virtual screen off again. Each arrow is a mode set.
- **Effect on BlueStacks:** BlueStacks stores its window per named screen (`gl_win_screen="DELL S2721DGF (2)"`, x 78 / 340, y 495 / 498, height 532 / 457). When that screen is gone the player is moved to whatever is left. The player log shows it re-running its hardware encoder probe (`ffmpeg ... h264_nvenc`) and re-enumerating devices on every display change.
- **Effect on Aperture:** if the virtual driver crashes at this moment Windows has no screen, and the phone gets "No displays" until the watchdog repair completes. With no screen and RustDesk's built-in path still active, RustDesk may also try to plug in its own Amyuni display.

**Virtual display crashes against Dell removals** (System log, UMDF 10121 `MttVDD.dll`; nearest Dell event 1010):

| Crash | Nearest Dell removal | Gap |
|---|---|---|
| 11-13 19:10:24 | 16:13:06 | none near (Dell asleep, per earlier report) |
| 11-13 22:09:30 | 22:13:38 | 4 min after |
| 11-14 22:09:26 | 22:09:21 | 5 s before |
| 11-15 21:26:49 | 21:26:49 | 0 s |
| 11-15 21:32:00 | 21:31:56 | 3 s before |
| 11-16 09:50:11 | 09:49:58 | 12 s before |
| 11-16 09:55:54 | 09:55:56 | 2 s after |
| 11-16 10:12:20 | 10:12:18 | 3 s before |
| 11-16 14:40:59 | 14:40:48 | 11 s before |
| 11-17 12:47:50 | 12:47:41 | 9 s before |
| 11-17 13:04:43 | 13:04:46 | 4 s after |
| 11-17 13:10:03 | 13:09:59 | 4 s before |
| 11-17 13:34:21 | 13:27:41 | none near |
| 11-18 13:13:12 | 13:13:15 | 3 s after |
| 11-18 15:39:19 | 15:39:15 | 4 s before |
| 11-18 16:20:13 | 16:20:21 | 7 s after |
| 11-18 22:49:24 | 22:49:20 | 4 s before |
| 11-19 00:45:15 | 00:45:12 | 4 s before |
| 11-19 00:46:20 | 00:46:08 | 12 s before |
| 11-19 21:23:44 | 22:04:11 | none near; BlueStacks instance began stopping at 21:23:42 |

17 of 20 within 12 s. Each crash is followed by event 10111 ("offline due to a user-mode driver crash, Windows will attempt to restart the device N more times") and a Device Management 1011 ("surprise removed as it was reported to be failing"). On 11-17 the retry counter fell to 2, close to the point where Windows gives up and leaves the device failed.

Since the reboot on 11-19 22:06 there are no MttVDD crash events, although 11-20 has about 20 removal sequences.

## 4. Black flashes

No Windows log records a blanking as such. What the logs do show:

**a. Phone sessions switch the monitors on and off.** Aperture holds a display-required wake lock while a remote session is open (`src/server/connection.rs:7364-7399`, `src/platform/windows.rs:3197-3233`).
- 11-21 22:54:57: burst of NVIDIA display-audio devices arriving (BlueStacks log, `WM_DEVICECHANGE 8000`); connection manager started 22:54:59. The monitors woke for the session.
- 23:11:29: session closed. 23:11:39: Dell `UID4355` "surprise removed". 23:11:41: NVIDIA display-audio removed. The monitors went off 10 s after the session ended and one Dell left the bus.
- The same arrive-then-remove pairs about 25 s apart appear at 11-20 00:18, 00:27, 00:33, 00:45 and 11-21 19:12 and 20:24 (the last matches a 5-second phone connection at 20:24:47). What opened the others is not known without the service log.

**b. GPU driver events** (`nvlddmkm`, System log, last 30 days):

| Time | Event |
|---|---|
| 10-26 (9 events), 11-05 (4), 11-15 01:51, 11-21 17:48 | 153 "Error occurred on GPUID: 100" |
| 10-26, 11-09, 11-13 14:54 | 13 "Graphics FECS Exception" |
| 11-06 02:49 | 14 + 153 "UCodeReset TDR" |
| 11-13 13:01, 13:03 | 14, and the GPU itself "surprise removed as failing"; reboot at 13:06 |
| 11-21 23:12:23 / :51 / :52 | 153 "Resetting TDR", "Reset TDR", "Restarting TDR" |

**c. The 11-21 23:12 reset, in order:** 23:11:29 phone session closed -> 23:11:39 Dell `UID4355` removed -> 23:12:11 both BlueStacks players abandon their `ffmpeg` encoder probe -> 23:12:23 GPU reset starts -> 23:12:52 GPU restarted -> 23:12:53 both Dells removed and re-added -> 23:12:54 "NVIDIA OpenGL Driver: The GPU has been disconnected" for both `hd-player.exe` -> 23:12:56 BlueStacks manager "Graphics device lost" -> 23:13:03 `RustDesk.exe` crashed in `flutter_windows.dll` (0xc0000409). The same Flutter crash is logged on 11-16 16:11.

**d. Not found:** no event 4101 (Windows "display driver stopped responding") in 30 days; no BlueStacks resolution or exclusive-fullscreen change in the player log; no HDR or VRR override in the user's DirectX settings; no MPO override (`OverlayTestMode` not set, so MPO is on). G-SYNC state is in NVIDIA's binary profile store and was not read.

**e. Aperture code that touches displays or windows.** For BlueStacks sessions: none that changes a display mode. `ChangeDisplaySettingsEx` is used only by privacy mode and by the desktop "change resolution" request (`src/server/connection.rs:5441-5479`), neither part of the emulator stream. BlueStacks is started with a normal window; nothing hides or moves it today.

**Ranking:** (1) display re-configuration from monitor/virtual-display arrivals and removals, medium confidence; (2) NVIDIA driver errors, medium-low, but they are real and independent of the virtual display; (3) G-SYNC or MPO flicker with windowed BlueStacks, unverified.

## 5. BlueStacks configuration (read from `C:\ProgramData\BlueStacks_nxt\bluestacks.conf`)

BlueStacks 5.22.285.1013, Hyper-V mode, Android 13 (`Tiramisu64`). Two instances; `MimMetaData.json` lists only these two.

| Setting | App Player 1 (`Tiramisu64`) | App Player 2 (`Tiramisu64_2`) |
|---|---|---|
| Resolution / dpi | 2340x1080 / 240 | 2340x1080 / 240 |
| Renderer / engine | `gl` (OpenGL) / `aga` | `vlcn` (Vulkan) / `aga` |
| CPU / RAM | 4 cores / 4096 MB | 4 cores / 4096 MB |
| `max_fps` / high FPS / V-sync | 60 / on / off | 60 / on / off |
| Eco mode cap | 30 | 30 |
| ASTC | hardware | hardware |
| FPS counter | off | **on** |
| Game controls | on | on |
| ADB port | 5555 | 5575 |
| Window | Dell (2), height 532 | Dell (2), height 457 |

Global: `key_controls_overlay_enabled="0"`, `prefer_dedicated_gpu="1"`, `enable_mem_dedup="1"`, `mute_all_instances="1"`, Windows GPU preference "high performance" for `HD-Player.exe`.

### Resolution against the phone

Phone: 3120x1440 px, 832x384 dp in landscape, 3.75 px per dp. The bar is 48 dp = 180 px.

| Stream area | Pixels | Aspect | Android size that fills it exactly (1080 high) |
|---|---|---|---|
| Whole screen | 3120x1440 | 2.167 | 2340x1080 (today) |
| Bar on a short edge (area 784x384 dp) | 2940x1440 | 2.042 | 2204x1080 |
| Bar on a long edge (area 832x336 dp) | 3120x1260 | 2.476 | 2674x1080 |

With today's 2340x1080 and the bar on a short edge, the picture is shown at 2940x1357 with 83 px (22 dp) of empty space split top and bottom. Changing to 2204x1080 would fill the area but changes the game's field of view and is a BlueStacks setting change (approval). It is a small gain; do it only if the bars bother.

**DPI.** 240 dpi at 1080 high gives Android a 720 dp tall screen, about twice the phone's 384 dp. Android-drawn UI (dialogs, keyboard, Play Games prompts) therefore looks about half size on the phone. A game's own UI usually scales with resolution, not dpi, so the game is likely unaffected. 320 dpi would enlarge Android UI; test on one instance first (approval).

### Frame rate

- BlueStacks allows 60 on both instances. Measured on 11-17 inside Android: 29.3 fps, typical gap 33.3 ms. That is a 30 fps game loop. BlueStacks' Eco cap is also 30, so check that Eco mode is off before concluding it is the game.
- Aperture's BlueStacks stream profile is 1280 px, **30 fps**, 4 Mbit/s, keyframe every second (`src/server/emulator/guest_runtime.rs:111-116`), and the in-Android encoder delivers about 10-17 fps with gaps up to 2 s (`docs/remote/2026-11-17-stream-reliability-review.md`).
- So today: game about 30 -> in-Android capture 10-17 -> phone. Host capture would deliver the game's 25-29 intact. 60 on the phone needs the game to draw 60 first.

### Renderer, textures, CPU and RAM

- Keep Vulkan where the game is stable on it; make both instances the same so measurements are comparable. The 11-17 host-capture measurements were described as "Vulkan renderer" for both; the configuration now says App Player 1 is OpenGL.
- ASTC "hardware" is correct for an RTX 3080. No change.
- 4 cores and 4 GB per instance on a 20-thread, 64 GB host is comfortable for two or three instances. More cores will not raise a 30 fps game cap.
- Eco mode: `docs/remote/2026-10-15-bluestacks-adaptive-eco-fps.md` is source-only and disarmed. Eco lowers the frame rate of the picture that both stream paths capture, so it must never be on for an instance being streamed.

### Overlays

`key_controls_overlay_enabled` is off globally, but the 11-17 capture still showed key-hint badges, and App Player 2 has the FPS counter on. The in-Android stream never shows these. Host capture shows everything drawn in the Android area, so they must be turned off per instance before host capture is used.

## 6. Interaction with the planned host-capture path

From `docs/remote/2026-11-17-bluestacks-host-capture-feasibility.md`: host capture uses Windows Graphics Capture of the BlueStacks top-level window, cropped to the `BlueStacksApp` child, encoded with NVENC.

- **Stream size = window size.** Today's windows give about 990x457. For a 2940 px wide phone area the Android area should be at least 1920 wide; 2340x1080 fits on one 2560x1440 Dell.
- **The window must be on an active screen.** Minimized, hidden or off-screen gives no frames. On a KVM switch the windows move to the virtual screen and are clamped to its mode; at 1920x1080 a 2340-wide window cannot fit. If the virtual driver crashes there is no screen and capture stops. So recommendations 2-4 come before host capture.
- **A GPU reset ends every capture and encoder session.** The 11-21 reset killed both players' GPU contexts. Host capture needs to survive or restart after that; today's in-Android stream is less exposed because it does not use the host GPU for capture.
- **The virtual screen as a capture home** (each instance on its own virtual monitor, captured by Desktop Duplication) is not recommended with this driver build.

## Limits of this investigation

- No flash was observed; BlueStacks was closed and the KVM was not switched.
- The Aperture service log (SYSTEM-only) and the `GraphicsDrivers` registry keys could not be read without elevation.
- Monitor arrival times are not logged by Windows; only removals are. Arrivals were inferred from the BlueStacks player log.
- G-SYNC, MPO and NVIDIA profile settings were not read.
- Whether BlueStacks Eco mode was on during the 11-17 measurements is not known.

## Checks actually run

Read-only: `Get-PnpDevice`, `Get-PnpDeviceProperty`, `pnputil /enum-drivers`, `Win32_VideoController`, `WmiMonitorID`, `EnumDisplayDevices` / `EnumDisplaySettingsEx`, `powercfg /q`, `nvidia-smi`, System and Application event logs, `Kernel-PnP/Configuration` and `Kernel-PnP/Device Management` logs, `setupapi.dev.log`, `vdd_settings.xml`, `bluestacks.conf`, `MimMetaData.json`, BlueStacks `Player.log`, Aperture user-session logs in `%APPDATA%\RustDesk\log`, and repository source and docs. No files were changed except this document.
