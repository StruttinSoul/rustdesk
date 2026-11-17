# Android Emulator video from the host (RTX 3080) — design

Date: 2026-11-16. Status: draft for approval.

## Intent

Aperture streams managed Google Android Emulators (AVDs) to the phone so the user can play
one game on several accounts at once. Today the picture is encoded **inside Android** by the
scrcpy helper. The emulator's Android image has only software encoders (`c2.android.*`,
`OMX.google.*`), so a moving screen reaches the phone at about 10–17 fps with gaps of up to
2 s. It feels slow.

The finished picture already exists on atlas, because the RTX 3080 renders it
(`hw.gpu.mode=host`). This change has Aperture take those frames on atlas and encode them with
the 3080's own H.264 encoder (NVENC), the same way it already streams the desktop. It removes
the bottleneck instead of working around it.

## Evidence (throwaway spike, 2026-11-16)

The emulator's built-in gRPC controller (`EmulatorController.streamScreenshot`) was measured on
atlas against the running `Aperture_Trial_Play35`:

| Case | Result |
|---|---|
| RGB888 576×1280, plain gRPC bytes, moving screen | 59.8 fps, p99 gap 35 ms |
| Same with the MMAP transport | 60.0 fps, max gap 25 ms |
| RGB888 1080×2400 | 58.9 fps |
| Emulator window hidden (Aperture's normal state) | 60.1 fps |
| Static screen | ~0.5 fps: frames are sent only when the screen changes |
| Emulator host CPU while feeding | ~6% |

The controller is on by default in every emulator, listens on `127.0.0.1` only, and requires a
per-launch bearer token. It writes its port and token to a discovery file,
`%LOCALAPPDATA%\Temp\avd\running\pid_<emulator pid>.ini` (`grpc.port`, `grpc.token`) in the
profile of the user who launched it. Without the token the call is rejected
(`UNAUTHENTICATED`); with it, `streamScreenshot` and `sendTouch` both worked. No restart and no
extra launch flag are needed.

## Goals

- A moving AVD screen reaches the phone at close to 60 fps when the screen moves. "Slow"
  means frame rate and gaps, not resolution.
- The phone app is unchanged: it keeps receiving the same H.264 `EmulatorVideoFrame` messages,
  status phases (`waiting_screen`, `stream_ready`) and dimensions it receives today.
- Taps, multi-touch, keyboard, text, Back/Home/Recents work exactly as today.
- Show/Hide on PC keeps working while streaming; hidden is the normal state.
- Several AVDs stream at the same time, each independently, as today.

## Non-goals

- BlueStacks, LDPlayer and other providers. They keep today's path untouched.
- Moving input to gRPC (approach B below). Possible later if taps still feel slow.
- Audio.
- Any phone-side or protocol change.
- Changing how AVDs are launched (no `-grpc` flag, no new launch options).

## Anti-goals (failure even if it "works")

- Opening the emulator controller to anything beyond atlas itself, or running it without its
  token. Launching with `-grpc <port>` makes it unauthenticated on all interfaces; never do that.
- Writing the gRPC token to logs, the phone, config or any file.
- Breaking taps or keyboard to get the faster video.
- A stream that fails and leaves the phone spinning with no fallback.
- Unthrottled per-frame logging (project rule).

## Constraints

- Windows host only (atlas: Windows 11, RTX 3080). The code lives in `src/server/emulator/`
  next to `remote_windows.rs` and `guest_runtime.rs`.
- Rust toolchain 1.75; builds with `--features flutter,hwcodec,vram`.
- No `protoc` on the build machine. The repo already generates protobuf code with the pure-Rust
  `protobuf-codegen` 3.7 (`libs/hbb_common/build.rs`). There is no `tonic`, `prost` or `h2` in
  `Cargo.lock` today.
- Tokio is already running in the server. The current guest session runs on its own std thread
  (`emulator-guest`). Never nest a runtime or `block_on` inside async code (project rule).
- The emulator runs in the logged-on user's session, launched by
  `RustDesk.exe --aperture-avd-start`. The Aperture server process that streams does not
  necessarily run as that user, so "my own `%LOCALAPPDATA%`" is not the right place to look.
- Encoding uses the existing `scrap::hwcodec::HwRamEncoder` (NVENC from system memory), chosen
  through the existing `HwCodecConfig` availability check.

## Approaches considered

| Approach | Tradeoff | Decision |
|---|---|---|
| **A. Emulator feed for video, keep today's input path** | Removes the video bottleneck; input code is untouched. The in-Android helper still runs, for input only. | **Picked by the user.** |
| B. Feed for video and input (`sendTouch`/`sendKey`) | Nothing inside Android, maybe faster taps, but multi-touch, text and nav keys need rebuilding. Higher risk. | Deferred. |
| Capture the emulator window on screen | Windows can't capture a hidden window, so it would break Show/Hide. | Dropped. |

## Design (approach A)

### Video path

For a session whose provider is `avd`, on atlas:

1. **Find the feed.** Map the target AVD to its running emulator process (the code already
   finds AVD processes by command line in `avd.rs`). Read `grpc.port` and `grpc.token` from that
   process's `pid_<pid>.ini` in the profile of the user who owns the process. Accept only if the
   file's PID matches the process; never pick "the newest" file. Connect only to `127.0.0.1`.
2. **Stream frames.** Call `streamScreenshot` with `RGB888` at the stream size over **plain gRPC
   bytes**. MMAP is not used: plain bytes held 60 fps in the spike, and MMAP would need a file
   that both the server and the user's emulator can open.
3. **Size.** Use today's settings for the stream: long side = the existing `max_size` option
   (default 1280, range 720–1920), aspect preserved, even dimensions. The phone's previews keep
   their small size (long side 360).
4. **Encode.** Convert RGB → the encoder's YUV layout (NV12/I420, from `yuvfmt()`) and encode
   H.264 with `HwRamEncoder`. Bitrate = the existing `GUEST_BIT_RATE_OPTION` (default 4 Mbps);
   frame-rate cap 60 for full screen and 30 for previews, as today.
5. **Deliver.** Emit the same `EmulatorVideoFrame { session_id, data, key, pts }` through the
   existing `GuestFrameBackpressure`, with the same `waiting_screen` → `stream_ready` phases and
   the same `frame_timing` log line ("Guest video (host)"), so the phone and the existing tests'
   expectations don't change.

### Keyframes and a still screen

The feed sends nothing while the screen is still. The phone and the existing watchdog expect to
be able to get a fresh picture:

- The first frame of a stream is a keyframe that the phone can decode on its own.
- A video refresh request from the phone (`refresh_video`) or from the existing idle-refresh
  probe re-encodes the **last received image** as a keyframe, instead of sending scrcpy's
  reset-video control message.
- Keyframes also come at the existing keyframe interval option (default every 1 s) while frames
  are flowing.
- The existing 10 s "no current frame" watchdog still applies, measured on the feed.

### Rotation

When the emulator's screen changes orientation, the feed's image size changes. The session then
starts a new stream geometry exactly as today's `VideoPacket::Session` does (`begin_stream`, a
`waiting_screen` phase, then a keyframe at the new size), so the phone handles it the same way.

### Input (unchanged path)

The in-Android helper still starts, but **without video** (scrcpy `video=false`, control on).
`input_loop` keeps writing the same control messages. Touch coordinates must stay in the space
the helper expects:

- **Risk to settle first:** with video off, the scrcpy server may map touches against the device
  display size instead of a video size, or may refuse touches whose reported screen size it
  doesn't recognise. The builder proves which on the real guest before building the rest, and
  maps coordinates accordingly (for example, scale from the feed size to the display size the
  helper reports or expects).
- Multi-touch release on disconnect, held-key release and rotation handling keep today's tests
  green.

### Fallback

If any part of the host path fails before the first frame — no discovery file, token rejected,
connection refused, no hardware H.264 encoder available, or no frame within the startup
window — the session falls back to today's in-Android video path for that session, and logs one
`warn` line saying why (never the token). If the feed breaks mid-stream, the session fails as
today's does (status `EmulatorFailed` with a reason), and the phone's reconnect starts a new
session, which tries the host path again. No new phone UI.

### Previews

The phone's small live previews for AVDs use the same host path at preview size, since they
suffer from the same software encoder. Previews never receive input, so they skip the helper
entirely on the host path.

## Decisions settled after the builder check (designer's calls)

- **Which account reads the discovery file.** On atlas the Aperture server process that streams
  runs as SYSTEM, started by the RustDesk service. SYSTEM can read the emulator owner's
  `%LOCALAPPDATA%`, so no relay through the user-session helper is needed. The builder confirms
  this on atlas first. If it turns out false, stop and report back; don't invent a relay.
- **If the helper won't take touches with `video=false`.** Touch accuracy wins over guest CPU.
  Try these in order:
  1. Map coordinates to whatever size the helper expects.
  2. Keep the helper's video on at the smallest profile (long side 360, 15 fps) and throw those
     frames away.
  3. If neither works, stop and report back. Don't switch to approach B without the user.
- **NVENC session budget.** GeForce drivers cap how many NVENC sessions can run at once (8 on
  current drivers). The desktop stream may hold one.
  - Full-screen AVD streams get priority.
  - A preview uses NVENC only while sessions are spare; otherwise it uses today's in-Android
    path.
  - If a full-screen stream can't create an encoder, it falls back as described under Fallback.
    The warn line names the reason.
- **Startup and liveness.** On subscribe the feed sends the current picture, and the spike got
  frames on a still screen too. So the host path counts as up once the first frame arrives
  within **5 s** of subscribing; otherwise it falls back.
  - Once streaming, a still screen is healthy. The 10 s watchdog checks that the feed is still
    connected, not that frames keep coming.
  - Idle and refresh keyframes come from the last image.
- **Rotation.** Request the size by long side. On an orientation change, re-subscribe at the new
  width and height. A brief re-subscribe per rotation is acceptable.
- **Mid-stream hiccup.** If the feed breaks after `stream_ready`, reconnect silently once
  (re-read the discovery file, re-subscribe, send a keyframe). Only a second failure fails the
  session. Fallback to in-Android video happens only before the first frame, per session.

## Verification the user cares about

- On atlas, the "Guest video (host)" timing line for a moving AVD screen shows a typical read
  gap near 17 ms (≈60 fps), against ~60–100 ms today.
- On the phone: the game feels smooth; taps, typing and Back/Home/Recents work; Show/Hide on PC
  doesn't interrupt the stream; two AVDs stream at once.
- Pulling the plug on the feed (e.g. a blocked port in a test) falls back to today's stream
  rather than spinning.

## Left to the builder

- The gRPC client: generate the few `emulator_controller.proto` messages with the existing
  `protobuf-codegen` (vendor the `.proto` from the SDK's `emulator\lib\`), and pick a minimal
  HTTP/2 transport that builds on Rust 1.75 without `protoc` (for example `h2` with hand-written
  gRPC framing, or `tonic` with pre-generated code). Keep added dependencies minimal.
- How the server finds the owning user's profile path for a process.
- Threading: how the async gRPC stream feeds the session's std thread without blocking Tokio.
- The RGB → YUV conversion routine (the `scrap` convert helpers / libyuv already exist).
- How to force a keyframe with `HwRamEncoder` (option, or re-create the encoder).
- Unit-test seams: discovery-file parsing, PID matching, stream sizing, fallback decision,
  keyframe-on-refresh. Real-guest tests stay `#[ignore]` like `captures_real_local_guest`.
