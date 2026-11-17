# Android Emulator Video From the Host (RTX 3080) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream managed Google Android Emulators (AVDs) to the phone from the emulator's own gRPC screen feed, encoded with NVENC on atlas. The in-Android scrcpy helper is kept for input only.

**Architecture:**
- **Discovery and feed.** A new Windows-only module finds the emulator's gRPC port and token from its `pid_<pid>.ini`. It streams RGBA frames with `streamScreenshot` over a minimal `h2` gRPC client running on its own thread.
- **Encode and deliver.** A second module encodes those frames with `HwRamEncoder`. `run_session` in `remote_windows.rs` delivers them as today's `EmulatorVideoFrame`s.
- **Input.** It goes through a control-only helper (`video=false`).
- **Fallback.** It drops to the current helper-video path if the host path produces no frame within 5 s.

**Tech Stack:** Rust 1.75, `h2` 0.4 over `hbb_common::tokio`, `protobuf` 3.7 `CodedInputStream`/`CodedOutputStream` for the few messages, `scrap::hwcodec::HwRamEncoder` and `scrap::convert_to_yuv`, `hbb_common::sysinfo`.

**Spec:** `docs/superpowers/specs/2026-11-16-avd-host-capture-design.md`

## Global Constraints

- Provider `avd` only. BlueStacks, LDPlayer and the other providers keep today's path byte-for-byte.
- No phone, Flutter or protocol change. Frames are the same `EmulatorVideoFrame { session_id, data, key, pts }`, with the same `waiting_screen` → `stream_ready` phases.
- **Feed connection:**
  - Connect to the feed only at `127.0.0.1`.
  - Send `authorization: Bearer <token>`.
  - Never launch with `-grpc`, and never change how AVDs launch.
- **Token handling:**
  - Never log, store, send or display the gRPC token.
  - Its `Debug` impl prints `<redacted>`.
- **Discovery file:** accept a `pid_<pid>.ini` only for the PID of the running `qemu-system-x86_64.exe` whose command line has `-avd <name>`. Never pick "the newest" file.
- **Stream size:** long side = `GuestStreamProfile::fullscreen().max_size` (option range 720–1920, default 1280) for full screen, and 360 for previews. Aspect is preserved and both dimensions are even.
- **Frame-rate cap:** 60 for full screen, 30 for previews.
- **Bitrate:** the existing `GUEST_BIT_RATE_OPTION` value (default 4 000 000 bps). Previews use 350 000 bps.
- **Keyframes:**
  - The first frame is a keyframe.
  - Any `ResetVideo` re-encodes the last image as a keyframe.
  - While frames flow, a keyframe comes at least every `keyframe_interval_secs` (default 1 s).
- **NVENC budget:**
  - At most **6** host-path encoders at once.
  - Previews may take one only while fewer than **4** are in use, which keeps 2 for full screen.
  - If an encoder can't be created, the stream falls back.
- **Startup and drops:**
  - The host path must deliver its first frame within **5 s** of subscribing, or that session falls back to today's helper-video path. It logs one `warn` naming the reason.
  - After `stream_ready`, one silent reconnect is allowed (re-read the ini, re-subscribe, keyframe). A second failure fails the session as today.
- **Input:**
  - Taps, multi-touch, keys, text and Back/Home/Recents behave exactly as today.
  - If the helper rejects touches with `video=false`, try the remedies in order:
    1. map coordinates to the size it expects (Task 1 decides);
    2. keep the helper video on at long side 360 / 15 fps and discard it;
    3. **stop and report back.**
  - Never switch to gRPC input.
- **Threads and runtimes:** the feed runs on its own std thread with its own current-thread Tokio runtime. Never `block_on` inside async code, never hold locks across `.await`, and never `std::thread::sleep` in a Tokio task.
- **Logging:** no debug-or-higher logging per frame or per packet. Use `trace` or `hbb_common::throttled_log!`.
- **Real-guest tests:**
  - They are `#[ignore]` and use only Aperture-managed AVDs in `D:\Aperture\Emulators` (for example `Aperture_Trial_Play35`).
  - Never use the dev AVDs in `%USERPROFILE%\.android\avd`.
  - Never drive the phone over adb.
- **Out of scope here:** commits are allowed on this branch, but no push, install, deploy or firewall change. Task 6 stops before installing.
- **Focused test recipe (`FOCUSED <filter>`):**

  ```bash
  cargo test --release --lib --features flutter,hwcodec,vram --config profile.release.package.rustdesk.opt-level=0 --config profile.release.package.rustdesk.codegen-units=16 --no-fail-fast <filter>
  ```

  Run it in bash with:

  ```bash
  export VCPKG_ROOT="$LOCALAPPDATA/MIRPG/windows-cache-sdk" LIBCLANG_PATH="C:/DevTools/vcpkg/downloads/tools/clang/clang-15.0.6/bin" PATH="$USERPROFILE/.rustup/toolchains/1.75.0-x86_64-pc-windows-msvc/bin:$PATH"
  ```

  Add `-- --ignored` for real-guest or real-GPU tests.

## Review Focus

1. **Emulator image is bottom-up.** The proto says rows are "bottom up". The phone must see an upright picture, and Task 4's `orient_rgba` test pins the flip. Task 3's real test records whether the feed is actually bottom-up and logs it as a ruling.
2. **Odd image size from the feed** (e.g. 1080×2400 scaled to 577×1280). Crop to even dimensions, never pad garbage, and keep touch mapping exact. Pinned by `even_crop_drops_last_column_and_row`.
3. **Rotation mid-stream.** The image size flips, so the phone gets a new `waiting_screen` and then a keyframe at the new size, and touches map to the rotated display. Pinned by `size_change_starts_a_new_geometry` and `display_space_follows_orientation`.
4. **Wrong, stale or missing discovery file** (emulator restarted, token rotated, file from another PID). It falls back within 5 s with a warn line and never uses another process's file. Pinned by `discovery_rejects_other_pid_files` and `unauthenticated_feed_is_an_error`.
5. **Static screen for minutes.** The stream stays alive, the phone refreshes get a keyframe, and there's no fallback or failure. Pinned by `reset_video_reencodes_last_image_as_key` and the idle check in Task 5's real test.

---

### Task 1: Control-only helper and touch space (gate)

Settles the spec's "prove first" risk before anything else is built.

**Files:**
- Modify: `src/server/emulator/guest_runtime.rs`
  - `GuestHelper` gains a control-only connect.
  - `connect_with_options` accepts a `video: bool`.
  - Real-guest test added at the end of `mod tests`.

**Interfaces:**
- Produces:
  - `GuestHelper::connect_control_only(adb: &Path, serial: &str, helper: &Path) -> ResultType<GuestHelper>`. It passes `video=false`, and the first and only socket is control, so there's no codec header to read. `read_packet()` on it returns `Err("Guest video socket is not connected")`.
  - `GuestHelper::connect_input_with_discarded_video(adb, serial, helper) -> ResultType<GuestHelper>` (remedy 2). Video is on at `max_size=360`, `max_fps=15`, and the caller must keep draining `read_packet()`. Write this only if Task 1's probe shows remedy 1 fails.
  - A ledger ruling, `Task 1: Ruling: helper control-only touch space = <display|none>`, which Task 5 consumes.

- [ ] **Step 1: Write the ignored real-guest probe `real_local_guest_control_only_touch_space`.**
  - Connect with `connect_control_only` to the running `Aperture_Trial_Play35` (its serial from `adb devices`, e.g. `emulator-5554`).
  - Read the display size with `adb shell wm size`.
  - Write a down/up `touch_packet` at the display centre, with width/height = the **display size**.
  - Repeat with width/height = half the display size (a feed-sized space).
  - Assert the display-size tap is delivered at the centre pixel, and record what happened to the half-size one. Check delivery through `adb shell dumpsys input` (the most recent `MotionEvent` coordinates) or through the helper's log with `log_level=debug` ("Ignore touch event").

- [ ] **Step 2: Run it and see it fail to compile** (no `connect_control_only` yet).

  Run: `FOCUSED real_local_guest_control_only_touch_space -- --ignored`

  Expected: compile error `no function or associated item named connect_control_only`.

- [ ] **Step 3: Implement `connect_control_only`.**
  - Add `video=false` to the helper args.
  - Connect one socket.
  - Set write timeout 1 s and `nodelay`.
  - Keep the same 15 s startup loop, cleanup, checksum and loopback checks.

- [ ] **Step 4: Run the probe.**

  Run: `FOCUSED real_local_guest_control_only_touch_space -- --ignored`

  Expected: PASS, with the display-size tap at the centre. Record the ledger ruling.
  - If display-size touches are ignored too, implement remedy 2 and make the probe prove a tap lands in its 360 space.
  - If both fail, **stop and report back to the user.**

- [ ] **Step 5: Run the existing helper tests and see them stay green.**

  Run: `FOCUSED emulator::guest_runtime`

  Expected: all non-ignored tests pass.

- [ ] **Step 6: Commit** `feat(host): control-only guest helper for AVD input`.

---

### Task 2: Feed discovery and gRPC wire format (pure)

**Files:**
- Create: `src/server/emulator/avd_feed.rs` (`#[cfg(windows)] pub mod avd_feed;` in `src/server/emulator.rs`).

**Interfaces:**
- Produces:
  - `pub struct FeedEndpoint { pub port: u16, pub token: FeedToken }` and `pub struct FeedToken(String)`.
    - `FeedToken`'s `Debug` prints `<redacted>`, and it has `fn bearer(&self) -> String`.
  - `pub fn parse_running_ini(text: &str) -> ResultType<FeedEndpoint>`. It needs `grpc.port` (1–65535) and a non-empty `grpc.token`; the error text never contains the token.
  - `pub fn discovery_paths(pid: u32, temp_dirs: &[PathBuf]) -> Vec<PathBuf>` returns `<temp>\avd\running\pid_<pid>.ini` for each dir, in order.
  - `pub fn find_emulator_pid(processes: &[(u32, String, Vec<String>)], avd: &str) -> Option<u32>` uses `avd::launched_avd` to match the name.
  - `pub fn discover(avd: &str) -> ResultType<FeedEndpoint>` does the real work.
    - It lists processes with `hbb_common::sysinfo`.
    - Its temp dirs are the emulator process's `TEMP` from `process.environ()`, then `crate::platform::get_active_user_home()\AppData\Local\Temp`.
    - It reads the first existing file.
  - `pub fn encode_image_format(width: u32, height: u32) -> Vec<u8>` encodes `ImageFormat { format: RGBA8888 (1), width, height }` with fields 1, 3 and 4.
  - `pub struct FeedImage { pub width: u32, pub height: u32, pub rotation: u32, pub seq: u32, pub pixels: Vec<u8> }` and `pub fn decode_image(bytes: &[u8]) -> ResultType<FeedImage>`.
    - It reads `Image.format` (1) → `ImageFormat.width` (3), `height` (4) and `rotation` (2) → `Rotation.rotation` (1).
    - It reads `Image.image` (4) and `seq` (5), and skips unknown fields.
  - `pub fn grpc_frame(message: &[u8]) -> Vec<u8>`: a 5-byte prefix of `0` plus the length as big-endian u32.
  - `pub struct GrpcDeframer` with `fn push(&mut self, bytes: &[u8]) -> ResultType<Vec<Vec<u8>>>`. It rejects the compressed flag and messages over 64 MiB.

- [ ] **Step 1: Write the failing tests in `avd_feed.rs` `mod tests`.**
  - `parses_port_and_token`:
    - `"grpc.port=8554\ngrpc.token=abc\n"` gives port `8554` and bearer `"Bearer abc"`.
    - `format!("{:?}", endpoint)` doesn't contain `abc`.
  - `missing_token_is_an_error_without_secrets`: a file with only `grpc.port=8554` gives an error.
  - `discovery_rejects_other_pid_files`: `discovery_paths(42, &[dir])` gives exactly `[dir\avd\running\pid_42.ini]`.
  - `finds_the_qemu_pid_for_an_avd`:
    - Processes `(7, "emulator.exe", ["-avd","Maple_1"])` and `(9, "qemu-system-x86_64.exe", ["-avd","Maple_1"])` give `Some(9)`.
    - `"Other"` gives `None`.
  - `image_format_round_trips_known_bytes`: `encode_image_format(1280,1280) == [0x08,0x01,0x18,0x80,0x0a,0x20,0x80,0x0a]`.
  - `decodes_image_fields_and_skips_unknown`: hand-built bytes for `Image{format{width 4,height 2,rotation{rotation 1}}, image [1..=32], seq 3, field 6 = 99}` give `FeedImage{4,2,1,3,..}`.
  - `deframer_splits_across_chunks`:
    - Two frames fed in three arbitrary chunks give both messages, in order.
    - A compressed flag of `1` gives an error.

- [ ] **Step 2: Run them and see them fail.**

  Run: `FOCUSED emulator::avd_feed`

  Expected: compile errors for the missing items.

- [ ] **Step 3: Implement the items above.**
  - Encode and decode with `protobuf::CodedOutputStream`/`CodedInputStream`, which the crate already depends on through `hbb_common`.
  - Don't vendor or generate the whole `.proto`.

- [ ] **Step 4: Run them and see them pass.**

  Run: `FOCUSED emulator::avd_feed`

  Expected: 7 passed.

- [ ] **Step 5: Commit** `feat(host): discover the AVD screen feed and its gRPC wire format`.

---

### Task 3: gRPC screen-feed client

**Files:**
- Modify: `Cargo.toml` to add `h2 = "0.4"`. If it doesn't resolve on 1.75, pin versions with `cargo update -p <crate> --precise`, and record each pin as a ruling.
- Modify: `src/server/emulator/avd_feed.rs`.

**Interfaces:**
- Consumes: Task 2's `FeedEndpoint`, `encode_image_format`, `grpc_frame`, `GrpcDeframer`, `decode_image`.
- Produces:
  - `pub struct ScreenFeed`, whose `Drop` cancels the stream and joins its thread.
  - `pub fn ScreenFeed::start(endpoint: FeedEndpoint, width: u32, height: u32) -> ResultType<(ScreenFeed, std::sync::mpsc::Receiver<ResultType<FeedImage>>)>`.
    - It spawns the std thread `emulator-feed` with a current-thread Tokio runtime.
    - It speaks prior-knowledge HTTP/2 over `TcpStream::connect(("127.0.0.1", port))` and sends a `POST` to `/android.emulation.control.EmulatorController/streamScreenshot`.
    - Headers: `content-type: application/grpc`, `te: trailers`, `authorization: <bearer>`.
    - It sets the initial stream and connection window to 32 MiB and releases capacity as data is consumed.
  - The channel is `sync_channel(1)` and latest-wins: if the receiver is behind, the older image is dropped.
  - A `grpc-status` other than 0, a connection loss or an HTTP/2 error is sent as one `Err` with the gRPC status code and message (never headers), and then the thread ends.

- [ ] **Step 1: Write the ignored real-guest tests.**
  - `real_feed_streams_moving_screen_near_sixty_fps`:
    - `discover("Aperture_Trial_Play35")`, then `ScreenFeed::start(e, 1280, 1280)`.
    - Keep the screen moving with `adb -s <serial> shell input swipe` in a background thread for 8 s.
    - Assert at least 400 images, a long side of 1280, and `pixels.len() == w*h*4`.
    - Write to the ledger whether row 0 is the top or the bottom of the screen. Check it with a known top bar: the status bar's bright pixels in a dark theme, or save the frame as PNG to the workspace and look at it.
  - `unauthenticated_feed_is_an_error`: a real port with token `"wrong"` gives `Err` containing `UNAUTHENTICATED` or code 16 within 2 s.

- [ ] **Step 2: Run them and see them fail to compile.**

  Run: `FOCUSED real_feed -- --ignored`

  Expected: compile error for `ScreenFeed`.

- [ ] **Step 3: Implement `ScreenFeed`.**

- [ ] **Step 4: Run them and see them pass.**

  Run: `FOCUSED avd_feed -- --include-ignored`

  Expected: Task 2's 7 plus these 2 pass. The fps line in the output is about 60.

- [ ] **Step 5: Commit** `feat(host): stream the AVD screen over its local gRPC feed`.

---

### Task 4: NVENC host encoder

**Files:**
- Create: `src/server/emulator/avd_video.rs` (`#[cfg(windows)] pub mod avd_video;`).

**Interfaces:**
- Consumes: Task 2's `FeedImage`.
- Produces:
  - `pub fn stream_box(long_side: u32) -> (u32, u32)` returns `(long_side, long_side)`. The feed keeps aspect inside the box.
  - `pub fn even_size(width: u32, height: u32) -> (u32, u32)` rounds each dimension down to even.
  - `pub fn orient_rgba(image: &FeedImage, bottom_up: bool) -> Vec<u8>` crops to `even_size` and flips rows when `bottom_up`. Task 3's ledger ruling sets the `BOTTOM_UP` const.
  - `pub struct EncoderBudget` is a global counter.
    - `pub fn try_acquire(preview: bool) -> Option<EncoderSlot>`. Limit 6; previews only while in-use < 4.
    - `EncoderSlot` releases on `Drop`.
  - `pub struct HostEncoder` holds the slot, a `scrap::hwcodec::HwRamEncoder`, the last oriented image, and a frame counter.
    - `pub fn new(width: u32, height: u32, bit_rate: u32, keyframe_frames: usize, preview: bool) -> ResultType<HostEncoder>`.
      - It fails with "No hardware H.264 encoder" when `HwRamEncoder::try_get(CodecFormat::H264)` is `None`, and with "Hardware encoder budget is full" when there's no slot.
      - Quality ratio = `bit_rate / 1000 / HwRamEncoder::calc_bitrate(w, h, 1.0, true)`, so the config's bitrate lands on the option value. `keyframe_interval = Some(keyframe_frames)`.
    - `pub fn encode(&mut self, rgba: Vec<u8>, pts_ms: i64) -> ResultType<Vec<EncodedHostFrame>>`.
      - It converts with `scrap::convert_to_yuv`, using a `PixelBuffer` for RGBA with the encoder's `yuvfmt()`.
      - It keeps `rgba` as the last image.
    - `pub fn force_key(&mut self) -> ResultType<Vec<EncodedHostFrame>>` re-creates the encoder (same slot) and re-encodes the last image, so the result's first frame has `key == true`. It returns `Ok(vec![])` if there's no last image yet.
  - `pub struct EncodedHostFrame { pub data: Vec<u8>, pub key: bool, pub pts: i64 }`.

- [ ] **Step 1: Write the failing tests.**
  - `even_crop_drops_last_column_and_row`: `even_size(577, 1281) == (576, 1280)`. `orient_rgba` on a 3×3 image gives 2×2×4 bytes, made of the top-left 2×2 pixels.
  - `orient_rgba_flips_bottom_up_rows`: a 2×2 image with distinct rows comes back with its rows swapped when `bottom_up`, and unchanged otherwise.
  - `budget_keeps_two_for_fullscreen`:
    - With 4 full-screen slots held, `try_acquire(true)` is `None` and `try_acquire(false)` is `Some`.
    - With 6 held, both are `None`.
    - Dropping one frees it.
    - Run serially or behind a test-only reset, since the counter is global.
  - `real_nvenc_first_frame_is_key_with_sps` (ignored):
    - `HostEncoder::new(576, 1280, 4_000_000, 60, false)` and a grey frame give a first frame with `key` set, whose data contains NAL type 7 (SPS) before type 5.
  - `reset_video_reencodes_last_image_as_key` (ignored): after 10 frames, `force_key()` returns frames whose first is `key`.

- [ ] **Step 2: Run them and see them fail.**

  Run: `FOCUSED emulator::avd_video`

  Expected: compile errors.

- [ ] **Step 3: Implement the items above.**

- [ ] **Step 4: Run them and see them pass.**

  Run: `FOCUSED emulator::avd_video -- --include-ignored`

  Expected: 5 passed on atlas.

- [ ] **Step 5: Commit** `feat(host): encode AVD feed frames with the hardware H.264 encoder`.

---

### Task 5: Wire the host path into the guest session

**Files:**
- Modify: `src/server/emulator/remote_windows.rs`:
  - `run_session`, from the helper connect (around line 621) to the end of the read loop.
  - `input_loop`.
  - The `GuestGeometry` touch mapping.
  - Tests.

**Interfaces:**
- Consumes:
  - Task 1's `connect_control_only` and its touch-space ruling.
  - Task 2's `discover`.
  - Task 3's `ScreenFeed`.
  - Task 4's `HostEncoder`, `stream_box`, `orient_rgba` and `BOTTOM_UP`.
- Produces (all private to `remote_windows.rs`):
  - `enum VideoReset { Helper, Host(Arc<AtomicBool>) }`. `input_loop` takes it, and its `ResetVideo` arm writes control 17 for `Helper` and sets the flag for `Host`.
  - `GuestGeometry` gains `touch_space: (u16, u16)`. It equals `(width, height)` on the helper path. On the host path it's the display size, swapped when `width > height`.
    - `touch_packet` is written with `touch_space`, and `x, y` scaled by `touch_space / (width, height)` (rounded, clamped to `touch_space - 1`).
    - The stale-geometry check still compares against `(width, height)`.
  - The `HostEncoder` is created with `keyframe_frames = keyframe_interval_secs × fps cap`, so 60 for full screen at the default and 30 for previews. Its bit rate is the profile's `bit_rate`.
  - `fn host_video_loop(...) -> ResultType<HostOutcome>`, where `enum HostOutcome { Cancelled, NoFirstFrame(String) }`.
    - It runs discover → start the feed (`stream_box`) → for each image: orient, then a geometry check.
    - On a geometry check (size change or first frame), it calls `begin_stream` and sends the `waiting_screen` phase as `VideoPacket::Session` does today.
    - Then it caps fps by dropping images sooner than `1000/fps − 2` ms after the last encode, encodes, marks ready, sends `stream_ready` once per geometry, and delivers through the existing `GuestFrameBackpressure` and timing window.
    - When the reset flag is set, it calls `force_key()` and delivers.
    - After `stream_ready`, a feed `Err` triggers one reconnect (re-discover, restart the feed, `force_key` on the next image). A second `Err` returns `Err`, which fails the session as today.
  - `run_session` order for provider `avd`:
    - **Full screen:** connect the control-only helper (or remedy 2 per Task 1) and start `input_loop` with `VideoReset::Host`. Then `host_video_loop`. On `NoFirstFrame(reason)`, log `warn!("AVD host video unavailable, using in-Android video: {reason}")`, tear down that helper, and continue with today's code from `connect_android_emulator` unchanged.
    - **Preview:** `host_video_loop` with no helper. On `NoFirstFrame`, use today's `connect_preview` path.
    - The idle-refresh watchdog and the 10 s recovery watchdog are kept. On the host path their `ResetVideo` reaches the flag through the input channel.

- [ ] **Step 1: Write the failing unit tests.**
  - `host_touch_maps_feed_space_to_display_space`: geometry 576×1280 with `touch_space` 1080×2400 turns touch (288, 640) into a packet carrying x 540, y 1200, w 1080, h 2400 (decode with the existing packet layout).
  - `display_space_follows_orientation`: the display (1080, 2400) with a feed of 1280×576 gives `touch_space` (2400, 1080).
  - `host_reset_sets_flag_instead_of_writing_control`: `input_loop` with `VideoReset::Host(flag)` given `ResetVideo` sets the flag and writes 0 bytes to the socket. Use the existing loopback-socket pattern from `video_refresh_writes_scrcpy_reset_video_control_message`.
  - `size_change_starts_a_new_geometry`: `begin_stream(576,1280)` and then `begin_stream(1280,576)` return `true` both times and bump the generation.
  - `real_local_avd_streams_from_host_near_sixty_fps` (ignored):
    - A `GuestSession::start` on `Aperture_Trial_Play35` with a moving screen gives a `stream_ready` within 10 s, then at least 250 frames in 5 s, the first `key`.
    - After 5 s of a still screen, `refresh_video()` produces a key frame within 1 s.
    - A tap through `input()` lands (as Task 1 checked).
  - `blocked_feed_falls_back_to_in_android_video` (ignored): with `discover` made to fail (a test hook that overrides the AVD name to one with no ini), the session still reaches `stream_ready` through the helper path within 25 s, and the log has the warn line.

- [ ] **Step 2: Run them and see them fail.**

  Run: `FOCUSED emulator::remote_windows`

  Expected: compile errors for the new items, and the existing tests unaffected.

- [ ] **Step 3: Implement the items above.**

- [ ] **Step 4: Run them and see them pass.**

  Run: `FOCUSED emulator::remote_windows`, then `FOCUSED real_local_avd -- --ignored`, then `FOCUSED blocked_feed -- --ignored`.

  Expected: all pass, and the existing non-ignored `remote_windows` tests stay green.

- [ ] **Step 5: Run the whole emulator suite and see it pass.**

  Run: `FOCUSED emulator::`

  Expected: no failures.

- [ ] **Step 6: Commit** `feat(host): stream managed Android emulators from the host GPU`.

---

### Task 6: Build and stage the host update (stop before install)

**Files:** none in the repo. Staging goes in `target/avd-host-capture-20261116/deployment/`.

- [ ] **Step 1: Build the DLL** with `cargo build --release --lib --features flutter,hwcodec,vram`, using the bash env from Global Constraints. Expected: `Finished`.
- [ ] **Step 2: Stage it.**
  - Copy `Update-ApertureHostDll.ps1`, the README and the `.cmd` files from `target/managed-avd-20261114/deployment/`.
  - Write `host-update.json` with the new DLL SHA-256, `installRoot` `C:\Program Files\RustDesk` and `serviceName` `RustDesk`.
  - Run the script with `-ValidateOnly`. Expected: validation passes.
- [ ] **Step 3: Stop.** Report the staged path and the hash, and ask the user for the go-ahead to install on atlas. The install and the phone check (smooth game, taps, typing, nav keys, Show/Hide while streaming, two AVDs at once) happen only after that go-ahead.
