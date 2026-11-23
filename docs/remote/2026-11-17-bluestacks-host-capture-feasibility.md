# BlueStacks host capture (RTX 3080) feasibility

Date: 2026-11-17
Status: **investigation and throwaway measurement only** — no product code, no commits. Measured on atlas against the user's two running BlueStacks instances.

## Plain-language summary

**Yes, it is feasible, and it should be clearly smoother — but the gain is capped by the game, not by the PC.**

- Windows can hand Aperture the BlueStacks window's picture directly (Windows Graphics Capture). Aperture then encodes it on the RTX 3080 with the encoder it already has. In the test, every frame the game drew reached the encoder: **25–29 fps, typical gap 33 ms, worst gap 84–150 ms** in normal play, against today's ~10–17 fps with gaps up to 2 s.
- The game itself only draws about **23–29 frames per second** on these instances right now (measured inside Android, and BlueStacks' own counter showed 23–28). Host capture delivers exactly that and cannot exceed it. 50–60 fps would need the game to render 60; that was not available to test.
- The cost on the PC is small: about 1 ms per frame to fetch the picture, 5–16 % of one CPU core per stream, and 1–2 % of the GPU's encoder for three streams at once.
- **The catch is hiding.** A minimized BlueStacks window gives no picture at all. So does a truly hidden one, and one moved fully off the screen. Hiding has to be done a different way: keep the window "open" but fully transparent. That worked in a 6-second test at full frame rate. It needs a proper trial before it is relied on.
- BlueStacks' own on-screen extras (key hints such as Q/W/Space, the FPS counter) are part of the window picture and would appear on the phone unless turned off in BlueStacks.

**Effort: M.** The encoder, session loop, input, fallback and frame delivery from the Google-emulator host path are already kept in the tree (`host_video.rs`, `host_video_session.rs`); the new work is one capture source plus the hide/show handling.

One thing went wrong during testing and is reported under [Test side effects](#test-side-effects): BlueStacks App Player 2's window is no longer at its original position.

## What was measured

Setup: BlueStacks 5.22, two instances running `com.nexon.ma` (2340x1080, 240 dpi, Vulkan renderer). App Player 2 visible at 1024x491 (Android area 990x457); App Player 1 minimized. Capture tool: a scratch Rust program using the `windows-capture` 1.5.0 crate (Windows Graphics Capture, BGRA, no cursor, no border), cropping to the Android area and reading pixels back to RAM, as `HostEncoder` needs. Encoder for the pipe test: `h264_nvenc` (preset p1, low-latency tune, CBR 4 Mbps) through the ffmpeg binary that ships with BlueStacks.

"Unique fps" counts frames whose pixels differ from the previous one.

| Test (App Player 2 unless noted) | Result |
|---|---|
| Visible window, 15 s | 25.0 fps, all unique. Gaps p50 33.8 / p90 52.4 / p99 99.8 / max 150.7 ms. Readback p50 1.5 / p90 2.5 ms |
| Capture vs Android's own frame times, same 4.5 s | Host: 29.1 fps, gaps p50 33.3 / p90 50.6 / max 83.9 ms. Android (`dumpsys SurfaceFlinger --latency`): 29.3 fps, p50 33.3 / p90 50.0 / max 83.3 ms. **Capture drops nothing and adds no gaps** |
| Fully covered by another always-on-top window, 5 s | 23.1 unique fps, max gap 134 ms. Occlusion does not matter |
| Minimized (App Player 1, already minimized) | **0 frames.** Android kept rendering at 28.5 fps while minimized, but the window receives nothing |
| `SW_HIDE` (4 s, then restored) | **Capture cannot start** ("Failed to convert item to GraphicsCaptureItem") |
| Moved fully off-screen (4 s, then restored) | **1 frame, then nothing** |
| Moved so only 4 px remain on a monitor (5 s) | Frames arrive (27.9 fps) but only 12.3 unique fps with one 1.5 s stall. Inconclusive and hacky; not recommended |
| Fully transparent (`WS_EX_LAYERED`, alpha 0), 6 s, then restored | **27.3 unique fps, gaps p50 33.5 / p90 50.5 / max 83.8 ms.** Captured image is the full game picture |
| Child window `BlueStacksApp` as the capture target | Not capturable; only the top-level window is |
| Window enlarged so the Android area is 1280x591, 5 s | 27.8 fps, max gap 133 ms, readback p50 0.6 / p90 1.8 / max 4.5 ms |
| Live capture → NVENC, 15 s | 337 frames captured, 337 encoded, 3.81 Mbps. 22.5 fps in that window (the game hitched: 333 and 667 ms gaps, multiples of Android's 16.7 ms tick). NVENC utilisation 1 % |
| NVENC throughput from a raw dump (990x456) | 225 frames in 0.62 s wall time including start-up: under 2.8 ms per frame, including BGRA→YUV on the CPU |
| **Three capture + NVENC pipelines at once**, 12 s | 24.6 / 24.3 / 24.3 fps each, same gaps on all three (p50 33.5, p90 65, max 248 ms — the game's own hitch). GPU 16 %, encoder 2 %, 3 NVENC sessions. CPU 12–16 % of one core per pipeline including the pipe write |

Capture CPU without the pipe was 5–16 % of one core across runs.

**Not measured:**
- **Latency.** The capture timestamps came out 13–14 ms *ahead* of the clock at delivery, so they cannot be used as a latency figure. Nothing suggests more than one compositor frame, but that is not a measurement.
- **Above 30 fps.** No 60 fps content was on screen. The Google-emulator host path measured 50–60 fps through the same encoder; the capture side at 60 is untested.
- **Three separate instances.** Only two were running and one was minimized, so the three-way test captured the same window three times. It proves three capture sessions and three NVENC sessions coexist; it does not load three BlueStacks renderers.
- **A virtual display, pre-login, and the lock screen** (see below).

## 1. Frame sources

| Source | Verdict | Why |
|---|---|---|
| **Windows Graphics Capture of the HD-Player top-level window** | **Use this** | Per window, works when covered, the border-off setting was accepted (not checked by eye), delivers every game frame, ~1 ms readback. Fails when minimized, hidden or fully off-screen |
| DXGI Desktop Duplication on a dedicated or virtual monitor | Fallback only | Captures a whole monitor, so each instance must sit unobscured on its own (virtual) monitor. The Virtual Display Driver is installed but inactive while real monitors are attached; turning it on is a system change and was not tested. No advantage over window capture |
| BlueStacks' own recorder | No | `ffmpeg_command_template.txt` shows it is `gdigrab` of a screen rectangle: needs the window visible and uncovered, and is CPU capture |
| BlueStacks streaming (`agora_rtc_sdk.dll`, `libagora_screen_capture_extension.dll`), `HD-VNC.exe`, `video_enc.dll` | No | Proprietary and undocumented; no public interface. Not investigated further |
| Shared textures | None found | HD-Player presents its Vulkan output into the child window `BlueStacksApp`; nothing is exported |

**Cropping the chrome.** No guessing needed. The top-level window has a child of class `BlueStacksApp` whose rectangle is exactly the Android screen. Crop = child rectangle minus the top-level window's frame bounds: here offset (1, 33), size 990x456 after rounding to even. The title bar and the right-hand sidebar fall outside it. Verified by saved images.

**BlueStacks overlays are inside that rectangle.** The captured image shows the key-hint badges (Q, W, E, Tab, Space, Del) and the FPS counter (`enable_fps_display="1"` on App Player 2). The in-Android stream never showed these. They would need to be turned off in BlueStacks, or accepted.

**Stream resolution follows the window size**, not the Android resolution: a 990-wide window gives a 990-wide stream. A 1280 long side needs the Android area to be at least 1280 wide.

**How the code shows and hides BlueStacks today.** It does not. `bluestacks.rs` starts `HD-Player.exe --instance <id>` with a normal window; only the pre-login boot path (`boot_windows.rs::launch_minimized`) starts it minimized (`SW_SHOWMINNOACTIVE`). "Show/Hide on PC" existed only for the Google emulator (`avd_window` in `host_management.rs`, `ShowWindow(SW_HIDE/SW_SHOW)`), and is being removed with it. Both existing techniques — minimize and `SW_HIDE` — produce **zero frames** for window capture.

## 2. Best candidate and the measurement

Window capture of the top-level window, cropped to the `BlueStacksApp` child, read back to RAM, fed to `HostEncoder`. Numbers are in the table above. The scratch tool and outputs are in:

`C:\Users\gregr\AppData\Local\Temp\claude\47ce7e92dc5b7241\61a1e1b7-a213-44a4-bc15-d0a8c4664a44\scratchpad\bluestacks-capture\`

- `wgcprobe\src\main.rs` — the probe (fps, gap percentiles, readback time, CPU, optional raw frames on stdout)
- `win.ps1` — window state reader and the brief reversible state changes
- `out\` — saved crops (`inst2_crop.png`, `inst2_alpha0.png`, `inst2_1280.png`, …), encoded samples, raw result lines
- `cargo-home\` — downloaded crates

Per-frame budget at this size: readback ~1 ms + convert and encode under 3 ms. At 1280 long side the existing 4–8 ms encode figure applies. Either way it is far inside a 16.7 ms frame.

## 3. Rotation, several instances, hidden windows

**Rotation and size changes.** BlueStacks rotates and reshapes its own window, so the captured picture is already upright: the `upright_rgba` step and the ADB `RotationWatcher` are not needed for this source. A change shows up as a new child-rectangle size; the source should then deliver the new size and the session should rebuild the encoder, as it does today on rotation. Not exercised live — no instance rotated during the test, and Tiramisu64_3 (the 1080x1920 portrait instance) was not running.

**Several instances.** Three simultaneous capture + NVENC pipelines ran without affecting each other, at 2 % encoder load. `EncoderBudget` (6 encoders, previews limited to 4) is enough for 3 full-screen streams plus previews. The driver accepted 3 concurrent sessions in the test; its actual session limit was not probed. Previews could stay on the in-Android path to save slots.

**Hidden windows — the main design constraint.**

| State | Window capture |
|---|---|
| Visible, even fully covered | Works |
| Fully transparent (alpha 0) | Works (6 s test) |
| Minimized | No frames |
| `SW_HIDE` | Cannot start |
| Fully off-screen | No frames |
| On a virtual monitor | Should work (it is an ordinary on-screen window there); **not tested** |

So "hidden" must mean: window restored (not minimized), made fully transparent, and — untested additions — click-through (`WS_EX_TRANSPARENT`) and off the taskbar and Alt-Tab (`WS_EX_TOOLWINDOW`). "Show on PC" removes those styles. The transparent test confirmed frames keep flowing; it did not confirm by screenshot that nothing was visible on the monitor, and the two extra styles were not applied.

Consequences:
- The pre-login boot path launches minimized. For host capture it must un-minimize without activating and apply the transparent state instead.
- If the user minimizes a shown window while the phone is streaming, frames stop. The session must detect this (no frames, `IsIconic`) and either restore-and-hide the window or fall back to the in-Android video.
- **Do not resize the window from outside.** Enlarging worked, but shrinking it back produced a window 65 535 px tall for a few seconds (see side effects). Use whatever size the window has; if 1280 is wanted, it has to come from BlueStacks' own window-size setting, not `SetWindowPos`.

## 4. Verdict

**Feasible. Recommended, with the in-Android stream kept as the automatic fallback.**

**Expected result.** The phone gets every frame the game draws: about 25–30 fps today on this game, with gaps of 33–50 ms typical and 80–250 ms when the game itself hitches — versus ~10–17 fps and gaps up to 2 s. Removing the software encoder from Android's 4 virtual CPUs (the game alone uses 76–92 % of one) may also raise the game's own frame rate; that is an expectation, not a measurement. 50–60 fps is possible only if the game renders it.

**Effort: M.**

**Risks.**
1. **Hiding by transparency is the load-bearing trick** and has had one 6-second test. Unknowns: stability over hours, behaviour across BlueStacks updates, click-through and taskbar styles, whether BlueStacks resets the styles.
2. **Capture before sign-in or on the lock screen is untested.** The capturing process must run in the user's desktop session. The fallback covers this.
3. **BlueStacks overlays and pop-ups** (key hints, FPS counter, BlueStacks dialogs) appear in the stream.
4. **Resolution depends on the PC window size.**
5. **Minimize by the user** silently stops frames unless handled.
6. A new dependency (`windows-capture`, or the same API through the `windows` 0.61 crate the project already uses).

### Recommended design

Add one `HostScreenSource` implementation for BlueStacks in `src/server/emulator/` (the trait already exists in `host_video_session.rs`). It finds the instance's HD-Player top-level window by process and title, finds its `BlueStacksApp` child, starts a Windows Graphics Capture session on the top-level window with cursor and border off, and for each frame crops to the child rectangle, rounds to even, converts BGRA to the RGBA `HostImage` and sends it on the channel. A frame-size change is passed through as a new image size. No frames for a few seconds, a closed capture item, or a minimized window ends the source with an `Err`, which the session already treats as "fall back to in-Android video".

Everything downstream stays as built for the Google emulator: `HostEncoder` and `EncoderBudget` encode on NVENC, `host_video_session::run` runs the control-only helper for input, the recovery watchdog, liveness and key-frame resets, and `FrameSender` in `remote_windows.rs` emits the same `EmulatorVideoFrame` messages. The phone needs no change. Skip the rotation watcher and `upright_rgba` for this source, since the window is already upright; keep reading `wm size` for touch mapping.

Add a BlueStacks "Show/Hide on PC" in the BlueStacks provider: hide = restore without activating, then layered alpha 0 plus click-through and tool-window styles; show = remove them. Record the original styles and placement so show restores them exactly. Change the pre-login launch from minimized to this hidden state once it is proven. Never resize or move the window.

Roll out behind an option, full-screen sessions first, previews left on the in-Android path. Before building, run a longer manual trial of the transparent state (an hour, with click-through and tool-window styles, across a BlueStacks restart) because the whole design rests on it.

### What the Google-emulator removal must keep

Already kept in the working tree at the time of writing, and all needed:

- `src/server/emulator/host_video.rs` — `HostEncoder`, `EncoderBudget`/`EncoderSlot`, `HostImage`, `even_size`, `orient_rgba`, `quality_for`, `force_key`, and its tests. `upright_rgba` is not needed by BlueStacks but is harmless.
- `src/server/emulator/host_video_session.rs` — `HostScreenSource`, `HostSession`, `HostAttempt` (with `Fallback`), `run`, `host_video_loop`, `HostSettings`, `Liveness`. The `RotationWatcher` can go later.
- In `remote_windows.rs`: `FrameSender`, `GuestGeometry`, `input_loop`, `spawn_recovery_watchdog`, `VideoReset::Host`, `display_touch_space`, and the call site that tries the host path and falls back.
- `GuestHelper::connect_control_only` and `GuestStreamProfile::for_host_video` in `guest_runtime.rs`.
- The `scrap` `hwcodec` feature and `HwRamEncoder` in the build.
- The `window_visible` field and a show/hide host request in the protocol and Flutter UI (the `avd_window` request can be renamed rather than deleted).

## Open questions for the user

1. Is a transparent-but-open BlueStacks window acceptable as "hidden"? It stays in memory as a normal window; with the extra styles it should not appear on the taskbar or take clicks, but that part is untested.
2. May I run a longer trial of that hidden state on one instance (about an hour, including a BlueStacks restart)?
3. Should the BlueStacks key hints and FPS counter be turned off, or is seeing them on the phone fine?
4. The stream will be as sharp as the PC window is large (990 px wide today). Is that enough, or should the instances' BlueStacks window size be raised so the Android area is at least 1280 wide?
5. Is the game set to 30 fps on purpose? If it can run at 60, the stream can too.
6. Must streaming work before Windows sign-in or while locked? If so that needs its own test; until then those cases use the in-Android stream.

## Test side effects

The brief state changes were made on BlueStacks App Player 2 only, each for 4–6 seconds: moved off-screen, moved to the screen edge, hidden with `SW_HIDE`, made transparent, and resized once. Styles, visibility and size were restored and verified (1024x491, styles `0x96030000` / `0x0`, visible, not minimized).

Two things did not go cleanly:

- **Position was not restored.** The window started at (1185, 786) and is now at (1102, 385). It moved several times between my calls while I was not touching it, and it was the foreground window, so either someone was dragging it or BlueStacks was re-placing it. I stopped moving it rather than fight that. It may need dragging back.
- **The shrink back from the resize test misbehaved.** For roughly three seconds the window was 1024 px wide and 65 535, then 32 767 px tall, before a second resize call returned it to 1024x491. The game stayed running.

A topmost grey cover window was also shown over the instance for 9 seconds for the occlusion test, and took focus briefly. App Player 1 was not touched. No ADB writes were made; `bluestacks.conf` was only read and its window keys for App Player 2 are unchanged.
