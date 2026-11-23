# Emulator stream: lag and "connection reset by peer" review (2026-11-17)

Investigation only. No product code, service, firewall, phone or emulator state was changed.
All times are local (MST, UTC-7); the phone and atlas clocks agree to within about 0.2 s.

## Plain-language summary

**What you were using.** The session that lagged and reset was the Google AVD `Aperture_Trial_Play35`
(the new 3080 path), not BlueStacks. No BlueStacks player was running. You had two short streams:
15:07:30-15:07:41 and 15:08:47-15:09:09. The second one ended with the reset.

**Why it lagged (what the evidence supports).**

1. **The emulator had only just started.** The AVD was launched at 15:06:43, Android reported "boot
   completed" at 15:07:27, and the stream began 3 s later. It was restored from a saved snapshot
   (quickboot), which earlier tests on this branch showed gives 17-34 fps instead of 60.
2. **Atlas was busy.** A second emulator (the dev AVD `SmartTubeModern_API36`) was running, and two
   Gradle/Kotlin build daemons started at 15:07:58 and 15:08:38, in the middle of your session.
3. **Your phone talks to atlas through the WireGuard VPN even at home.** Both are on the same Wi-Fi
   network (10.0.4.x), but the phone sends everything to the router's VPN endpoint first
   (`10.0.4.93 dev tun0 src 10.5.5.2`, MTU 1280). That adds delay and jitter to every frame and tap.
4. **The phone draws each frame the slow way.** It decodes H.264 in software and hands a full
   uncompressed picture (about 2.9 MB) to Flutter per frame. Frames the UI cannot keep up with are
   dropped without being counted, so the real on-screen frame rate is unknown.

What the phone measured while the screen was moving: 25-35 frames per second on average, typically
17-21 ms between frames, with one in ten frames arriving 45-51 ms late. That is visibly uneven.

**Why it reset.** The phone received a TCP reset on its main connection to atlas at 15:09:09.73,
30.5 s after connecting and 7 s after your last touch, while the picture was idle. The RustDesk
host process did not crash and the emulator was still running. **The exact trigger is not proven**,
because the host's own log is in a SYSTEM-only folder that this investigation could not read.
The two candidates, in order of likelihood:

- **A. Atlas closed the session itself.** You had swiped the app away and reopened it 1.2 s later.
  The new connection was attached to the old "connection manager" helper process on atlas, which
  never recorded this connection ending and is now gone. If that helper exits, the host drops the
  connection it serves (existing RustDesk behaviour on Windows).
- **B. The VPN/router path injected the reset.** Possible because every packet crosses the router's
  WireGuard and firewall.

One line of the host log settles it (see "How to confirm the reset cause").

**What to do first.**

1. Take the home traffic off the VPN hairpin (your decision; it affects away-from-home use).
2. Make a dropped connection reconnect and resume the emulator by itself instead of showing an error.
3. Read the host log once (elevated) and, if candidate A is confirmed, fix that race.
4. Keep the AVD warm and do not stream from a just-restored snapshot.
5. Measure, then replace, the phone's draw path; and stop sending a full keyframe every second.

## Evidence

### Sources

| Source | Where | Notes |
|---|---|---|
| Phone Rust log | `/storage/emulated/0/Android/data/com.carriez.flutter_hbb.mirpgtest/files/RustDesk/Logs/rs_rCURRENT.log`, `rs_r2026-11-17_15-08-37.log` | Read with `adb exec-out cat` |
| Phone logcat | `adb logcat -d` | App start/kill, touch times |
| Host user-profile logs | `%APPDATA%\RustDesk\log\cm`, `aperture-avd-start`, `aperture-avd-window` | Connection manager and AVD launch helper |
| Host service log | `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log` | **Access denied (not elevated). Not read.** |
| AVD files | `D:\Aperture\Emulators\Aperture_Trial_Play35.avd` | Timestamps only |
| Windows | Process list, event log, routes, firewall rules | Read-only |

Phone app: `com.carriez.flutter_hbb.mirpgtest` 1.8.0, updated 13:40:38. Host DLL SHA256
`5B0A5C69...6E95` matches the staged build in `task-6-report.md`. Atlas rebooted at 13:46:44;
RustDesk service PID 4976 and server PID 5904 have run since 13:47:02.

### Timeline

| Time | Event | Source |
|---|---|---|
| 15:06:37.6 | App start (pid 14585); secured LAN connection ready in 40 ms | logcat, phone log |
| 15:06:43.3 | Host starts `Aperture_Trial_Play35`; quickboot snapshot loaded (`read-snapshot.txt` 15:06:44) | `aperture-avd-start` log, AVD files |
| 15:07:27.5 | Android boot completed (`bootcompleted.ini`) | AVD files |
| 15:07:30.2 | First guest frame, 47 s after the AVD start; full-screen entered | phone log, logcat |
| 15:07:30-15:07:36 | 207 frames in 6.0 s; gap p50 17.3 ms, p90 30.9 ms, max 1068 ms | phone log |
| 15:07:36-15:07:41 | 42 frames in 5.0 s; gap p50 29 ms, p90 340 ms, max 1402 ms | phone log |
| 15:07:41.9 | Full-screen left (system bars return) after 11.7 s | logcat |
| 15:07:58, 15:08:38 | Gradle daemon and Kotlin compile daemon (JDK 21) start on atlas | process list |
| 15:08:37.9 | Host connection 461 closed normally ("closed from connection request") | cm log |
| 15:08:38.2 | App swiped away from recents ("remove task") | logcat |
| 15:08:39.1 | App restarted (pid 15241); connection 462 handed to the **same** cm process | logcat, cm log |
| 15:08:39.25 | Secured LAN connection ready in 49.6 ms | phone log |
| 15:08:47.8 | First guest frame of stream 2 | phone log |
| 15:08:47-15:08:53 | 46 frames in 5.9 s; gap p50 19.8, p90 51.3, max 2238 ms | phone log |
| 15:08:53-15:08:58 | 160 frames in 5.1 s (31 fps); gap p50 21.2, p90 45.8, max 490 ms | phone log |
| 15:08:57.2 | Phone cannot reach the ID server `10.0.4.93:21116` (hbbs down) | phone log |
| 15:08:58-15:09:04 | 135 frames in 5.5 s (25 fps); gap p50 19.2, p90 44.5, max 617 ms | phone log |
| 15:09:02.5 | Last touch on the phone | logcat |
| 15:09:04 | hbbs restarted by its watchdog (PID 8064) | process list |
| 15:09:04-15:09:09 | 10 frames, steady 506 ms apart (idle screen, likely a blinking cursor) | phone log |
| **15:09:09.73** | **`Connection closed: Connection reset by peer (os error 104)`** at `src\client.rs:5060` | phone log |
| 15:09:34.7 | App swiped away again; no reconnect was attempted in between | logcat, phone log |
| 15:09:36.7-15:09:39.0 | AVD shut down gracefully (snapshot saved) | AVD files |

Phone decode cost throughout: p50 4.7-5.8 ms, p90 8-12 ms, max 23 ms. Phone queue wait p50 0.1 ms,
max 13 ms. So neither the phone decoder nor its 12-frame queue was the bottleneck.

Caveat on `arrival_gap` maxima: the emulator feed only produces a frame when the screen changes, and
the host sends an idle refresh after 2 s. A 2.2 s maximum can therefore be a still screen, not a
stall. The percentiles during movement (p50, p90) are the reliable part. The metric needs to
separate the two (plan item 9).

### The reset: what is established

- **Which socket.** The phone's main session stream to atlas TCP 21120 (`lan_fast_path.rs`), read
  error in the client io loop. It is not the adb, scrcpy-helper or gRPC socket: those live on atlas.
- **Errno 104 is the phone's.** The phone received an RST. On Nov 14 the phone logged errno 103
  ("software caused connection abort") when its own network changed; this is different.
- **Not a host crash.** PIDs 4976/5904 date from 13:47:02. No Application Error or WER event for
  rustdesk today. (qemu crashed three times earlier today, at 00:03, 00:41 and 13:21, all before
  this session and before the reboot.)
- **Not the emulator dying.** The AVD ran until 15:09:36.
- **Not the phone's 30 s receive timeout.** That path shows a "Timeout" message box, not errno 104,
  and frames arrived until 15:09:09.3.
- **Not the host's 30 s receive timeout, as far as the code shows.** The host answers and sends
  `TestDelay` every second and the phone echoes it (`client.rs:4361`), which refreshes
  `last_recv_time` (`connection.rs:1291`). The emulator session was started by a phone request at
  about 15:08:45 and touches continued until 15:09:02.
- **Not backpressure visible on the phone.** Queue max 13 ms; no "flush" samples in the timing lines.
- **Unique circumstance.** Of all phone sessions logged since Nov 14, this is the only errno 104, and
  the only one where the app reconnected 1.2 s after the previous session ended.

### The reset: candidate A (host closed it; connection manager race)

Facts:
- `cm\RustDesk_rCURRENT.log` shows one cm process (started 15:06:37.76) serving connection 461 and
  then 462 (15:08:39.09). It logged 461's end. It logged **nothing** for 462, and no cm process
  exists now.
- When the last client is removed, the Flutter cm calls `windowManager.close()` from `onRemoveId`
  (`flutter/lib/desktop/pages/server_page.dart:80`) and exits once `closeAll()` and `gFFI.close()`
  finish (`server_page.dart:65-76`). The Rust IPC listener in that process still accepts new
  connections meanwhile.
- When the cm side of the IPC pipe goes away, the server sends itself `CmErr` and closes the peer
  connection: `connection.rs:3199-3206` then `connection.rs:990-996`
  (`on_close("connection manager error: ...")`). Dropping the socket with unread phone data makes
  Windows send RST, which the phone reports as errno 104.

Not established: why the cm lived 30 s after 462 arrived, and whether it exited by itself. The
missing log line could also be an unflushed buffer if the cm exited right after a host-initiated
close. Confidence: medium.

### The reset: candidate B (path injected it)

Facts:
- `adb shell ip route get 10.0.4.93` on the phone: `dev tun0 table 1095 src 10.5.5.2`. The phone's
  Wi-Fi address is 10.0.4.23/24, the same subnet as atlas (10.0.4.93).
- Atlas has no WireGuard interface. `10.5.5.1` answers ping from atlas in under 1 ms, as does the
  router `10.0.4.1`. So the tunnel ends on the router (or a box next to it), and every packet
  hairpins through it.
- Atlas -> phone Wi-Fi address ping (phone idle, so power-save inflates this): 23/25 replies,
  6-125 ms, average 59 ms, 8% loss.

Not established: any RST from the router. Confidence: low to medium. It stays on the list because
a stateful firewall on the forward path is the usual source of a reset that neither end intended.

### How to confirm the reset cause

Run once in an elevated PowerShell on atlas (read-only):

```powershell
Get-ChildItem 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log' -Recurse -Filter *.log |
  Select-String -Pattern '15:0[6-9]:\d\d' |
  Where-Object Line -match 'Connection closed|connection manager|Guest video|AVD|Timeout|WARN|ERROR'
```

- `#462 Connection closed: connection manager error: ...` confirms A.
- `Connection closed: Timeout` at about 15:09:39, or a socket error such as 10054 at 15:09:09,
  points to B (the host did not initiate it).
- The `Guest video (host GPU)` lines in the same output give `read_gap`, `encode` and `deliver`,
  which separate "the emulator produced few frames" from "the host or network delayed them".

## Lag sources end to end

| Stage | Fact (measured or from code) | Assessment |
|---|---|---|
| Emulator feed (gRPC `streamScreenshot`) | Fresh guest: 60 fps raw, about 52 fps through the host path, steady for 30 min (`final-fix-report.md` soak). Quickboot-restored or loaded guest: 17.5-34 fps, gaps to 4.5 s (same report; `task-6-report.md` runs 1-2: 117-122 frames/5 s) | **Main suspect today.** Stream began 3 s after boot from a snapshot |
| Host CPU | 12700K. Dev AVD running since 13:53; build daemons started 15:07:58 and 15:08:38. At 15:13 the builds used about 10 cores | Likely contributor. Not measured at the time of the session |
| Host encode | NVENC H.264, 576x1280, 60 fps cap, 4 Mbit/s, **keyframe every 60 frames (1 s)** (`guest_runtime.rs:111-116`, `avd_host_video.rs:379-390`). Encode p50 5 ms (soak). A requested keyframe **re-creates the encoder**: 126-244 ms (`avd_video.rs` `force_key`) | Encode speed is fine. The 1 s IDR makes frame sizes bursty; on-demand keyframes are slow |
| Host pacing | Newest-image-wins, minimum gap 14 ms (`min_gap`); delivers about 87% of feed frames | Minor |
| Host queue | 16 events (`GUEST_EVENT_QUEUE_SIZE`). Full queue drops dependent frames and asks for a keyframe (`GuestFrameBackpressure`). Status events use `blocking_send` and can stall the video thread | Not shown to have fired today (needs host log) |
| Transport | One TCP stream (TCP_NODELAY on both ends) carrying video, input and control, **inside WireGuard** via the router, tunnel MTU 1280. Handshake-ready times 31-50 ms over 19 sessions | Head-of-line blocking plus a VPN hop. Contributor to jitter and input delay; size not isolated |
| BlueStacks / LDPlayer | Old path: in-guest scrcpy software encoder, about 10-17 fps, gaps to 2 s (prior reports) | Not involved today. Still the worst path |
| Phone receive queue | 12 frames; overflow flushes and asks for a keyframe (`client/emulator.rs:16`) | Did not overflow today |
| Phone decode | FFmpeg software H.264, 1 thread (`ram decoder ... hwdevice NONE`, `codec thread: 1`). p50 5.5 ms, max 23 ms | Adequate at this size; no headroom for 1080p60 |
| Phone present | `use texture render: false`. Each frame: RGBA buffer -> Dart -> `decodeImageFromPixels` -> repaint (`flutter.rs:1375`, `model.dart:2112`). **A frame is dropped if Flutter has not fetched the previous one** (`flutter.rs:1380`). The logged "present 0.1 ms" is only the hand-off | **Unmeasured.** Real displayed fps and added latency unknown |
| Input | Touch travels the same TCP stream; host forwards to the in-guest helper over adb. Phone `tap_to_frame` samples today: 4, 14, 54, 115, 132 ms (n=5; measures "next frame after a tap", not causality) | Too few samples to judge |

Not done: a live measurement on the trial AVD. Atlas was running a 10-core Gradle build from the
UI worktree during this investigation, so numbers would not have been representative.

## Plan

### Quick wins

| # | Change | Expected effect | Risk | Verify |
|---|---|---|---|---|
| 1 | **Stop the VPN hairpin at home** (user decision, see open questions). Options: turn the tunnel off automatically on the home SSID; or exclude the Aperture apps from the VPN and let them use Wi-Fi at home | Lower and steadier round trip; removes the router from the video path; removes candidate B | Away-from-home access relies on the tunnel, so a blanket exclusion breaks it. Per-app exclusion needs the app to reach atlas another way when away | `adb shell ip route get 10.0.4.93` shows `dev wlan0`; "LAN connection ready" under about 15 ms; phone `arrival_gap` p90 near 20 ms on a fresh guest |
| 2 | **Read the host log once** with the command above | Turns the reset from a hypothesis into a fact | None (read-only, needs elevation) | The `#462 Connection closed` line |
| 3 | **Auto-reconnect and resume.** On an unexpected close during an emulator session, the phone reconnects (same secured LAN path) and reopens the same target, with a short "Reconnecting" overlay instead of an error | A reset becomes a 1-2 s hiccup | Must not loop on real refusals (wrong key, host stopping); cap retries | Kill the host cm process, or drop the TCP connection, mid-stream: the picture returns without user action |
| 4 | **Do not let the cm take a session down** (if A is confirmed). For an authorized connection on Windows, restart the cm on `CmErr` instead of closing; and have a closing cm refuse new IPC clients | Removes the quick-reconnect reset | Touches stock RustDesk connection code; the close-on-cm-loss rule exists for unattended-consent safety, so keep it for unauthorized connections | Swipe the app away and reopen within 2 s, ten times: no reset within the next minute |
| 5 | **Do not stream from a just-restored guest.** Keep the AVD running between sessions (or pre-start it), and hold "stream ready" until the guest has settled; prefer a real boot over a snapshot older than a few hours | 25-35 fps -> the 52-60 fps seen in the soak | More RAM held on atlas (4 GB guest); slower first start if a real boot is forced | Host log `read_gap` p50 near 17 ms in the first 10 s of a session |
| 6 | **Give the stream priority on atlas.** Raise the emulator and RustDesk server process priority during a session; avoid running a second emulator and builds while streaming | Fewer feed gaps under load | Slightly slower builds | Repeat a session with a build running: `read_gap` p90 stays under 35 ms |

### Structural

| # | Change | Expected effect | Risk | Verify |
|---|---|---|---|---|
| 7 | **Keyframes on demand, not every second.** Long GOP (or intra-refresh), and request an IDR from the live NVENC session instead of re-creating the encoder | Even frame sizes, fewer bursts on TCP; keyframe recovery in one frame time instead of 126-244 ms | A lost reference without a quick IDR freezes the picture: the on-demand path must be reliable first | Host `kbytes` p90/p50 ratio drops; refresh keyframe under 40 ms |
| 8 | **Phone present path.** First add a displayed-frame counter and decode-to-display latency to the phone timing line. Then move guest video to a texture: MediaCodec decoding straight to a Flutter `SurfaceTexture` | Removes the per-frame 2.9 MB copy and image decode, and the silent drops; lower latency | Largest change; device-specific decoder behaviour; needs a software fallback | Displayed fps equals arrival fps; decode-to-display under one frame |
| 9 | **Metrics that separate idle from stall.** Tag idle-refresh frames; log host `read_gap`/`encode`/`deliver` and phone arrival for moving periods only; send the host's 5 s summary to the phone so one log shows both ends; send a close reason before the host closes | Every future "it lagged" report is diagnosable from the phone alone | Small protocol addition | The phone log shows a host line and a close reason for each session |
| 10 | **Transport for video.** After 1 and 9: if moving-screen `arrival_gap` p90 is still far above the host's `read_gap` p90, move video (and input) to a datagram path (the repo already has KCP) with keyframe-on-loss | Removes TCP head-of-line stalls | New failure modes; needs 7 first | Phone p90 gap within about 5 ms of host p90 |
| 11 | **BlueStacks and LDPlayer on the 3080.** Capture the player window or its display on the host and encode with NVENC, keeping the in-guest helper for input only | 10-17 fps -> 50-60 fps | Window capture needs the player visible or a capturable surface; per-emulator work | Same real-guest fps test as the AVD path |

### Suggested order

2, 1, 3, 5, then 4 (if confirmed), 9, 7, 8, 6, 10, 11.

## Open questions for the user

1. **VPN at home:** is the always-on WireGuard tunnel meant to carry traffic to atlas when the phone
   is on the home Wi-Fi? Which option do you prefer: tunnel off on the home SSID, or Aperture
   excluded from the tunnel?
2. **Which emulator matters most?** Today was the AVD. If you mostly use BlueStacks, item 11 moves up.
3. **At 15:09:02**, did you tap into a text field (the picture then updated twice a second, like a
   blinking cursor)? And did anything on the phone look frozen before the error appeared?
4. **Who stopped the AVD at 15:09:36?** The phone was already disconnected. If it was another agent
   or test run, the same thing may have shut the trial AVD down in earlier sessions
   (`final-fix-report.md` notes three unexplained shutdowns).
5. **May the host log be read with elevation**, or would you rather the emulator session log be
   written somewhere readable (and summarised to the phone, item 9)?
6. **Keep the AVD running between sessions** (4 GB RAM on atlas) to avoid the 47 s start and the
   slow first minute?

## Limits of this review

- Host service log not read; the reset trigger and all host-side timing for today are inferred.
- No live measurement was taken (atlas was under build load).
- Phone on-screen frame rate is not measured anywhere today.
- The ping to the phone was taken while it was idle and overstates Wi-Fi latency under traffic.
- Nothing was changed, so no regression surface. Only this file was added.
