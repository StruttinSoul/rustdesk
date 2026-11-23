# Aperture improvement review — 2026-11-14

Read-only review of branch `feature/android-emulator-remote` at `48ef7d9b1` (Aperture 1.5.7). Nothing was changed, built, installed or run. Evidence is code (`file:line`), the docs in `docs/remote/`, and the diagnostic outputs already in `target/` from today's sessions. Each finding says what was verified and what was not.

## Top 5

| # | Finding | Size | Confidence |
|---|---|---|---|
| 1 | The ID server (hbbs/hbbr) runs as SYSTEM and shares Aperture's config folder. It rewrote `RustDesk.toml`; this, not two Aperture processes, is the most likely cause of atlas's ID reverting. It can happen again. | S | High (mechanism), medium (hbbs internals) |
| 2 | BlueStacks and adb are started as SYSTEM children of the service with handle inheritance on. Fixing the launch call removes the blocked home path after a service restart and stops emulators running as SYSTEM. | S | High |
| 3 | The home path gives each address one 250 ms try. Away from home (mobile data + WireGuard) it will often miss, so the connection falls back to the ID server, which is the least reliable part. | S | Medium |
| 4 | The phone decodes all video in software on one thread, copies every frame as raw pixels into Flutter, and rebuilds the whole control view per frame. | S now, L for the real fix | High (code and phone log) |
| 5 | Failures are silent: home-path listener down, ID changed, virtual display failed and ID server down are not shown anywhere on the phone, and the logs that would show them are buried in noise. | S–M | High |

## Quick wins (each under an hour or two of work)

- Launch HD-Player through `platform::run_exe_in_cur_session` (finding 2).
- Pin atlas's ID and log loudly when it changes (finding 1, Aperture-side guard).
- Retry the last known address with a longer timeout; try it first (finding 3).
- Log the listener bind failure once per state change, not once per second (finding 5).
- Stop the posts to `http://10.0.4.93:21114` (finding 9).
- Carry held Ctrl/Alt/Shift/Win on mouse events (finding 7).
- Move only the picture under the per-frame rebuild; use `FilterQuality.low` (finding 4a).
- Replace "Manage Jarvis…" with the connected PC's name (finding 18).
- Add `flutter/android/build/` to `.gitignore`; back up the 17 unpushed commits (finding 8).
- Add a post-deploy check to the host update script: 21120 listening, ID unchanged (finding 16).

---

## Findings in rank order

### 1. Network / reliability — hbbs and hbbr share Aperture's config folder and rewrote its identity file

**Evidence**
- `target/own-id-server-20261114/isolate-id-server.ps1:1-2` states it: hbbs "as SYSTEM … uses the Aperture service's own config folder … and rewrote RustDesk.toml". `isolate-result.txt` records `RustDesk.toml lastwrite 2026-11-14T11:31:43`, during the first hbbs starts.
- `target/own-id-server-20261114/watchdog-id-server.ps1:13-22`: both tasks were then put **back to SYSTEM** ("NetworkService never got to listening"). Only the database moved (`DB_URL`). So hbbs and hbbr still load `LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml` and `RustDesk2.toml` on every start, and the watchdog restarts hbbs after each 10054.
- The file on disk was last written by old code. `diag2.txt` and `isolate-result.txt` show `enc_id` with a 40-character value (quotes included). This fork always writes the newer nonce format (`libs/hbb_common/src/password_security.rs:212-228`, added upstream 2026-05-26), which gives about 72 characters for a 9–10 digit ID. 40 characters is the older format. Aperture cannot have written it.
- What old code does when it cannot read `enc_id`: `Config::load` declares the ID invalid and regenerates it from the MAC address (`libs/hbb_common/src/config.rs:609-650`, `1046-1069`), then stores the file. The MAC-derived ID is deterministic; on atlas it is the old `373491561` (the server log of 2026-10-21 shows `id updated from 373491561 to 1984606088`, `target/shell-restart-20261114/diag4.txt`).
- The 2026-10-21 change itself has a plain cause: atlas was moved to a new Windows install that day (`docs/remote/2026-10-21-windows-tools.md`), so the MAC-derived ID met a different machine UUID on RustDesk's public server (`UUID_MISMATCH`, `src/rendezvous_mediator.rs:1287-1298`).

**Not verified:** hbbs 1.1.16's source (which hbb_common revision it carries); the service folder itself (needs admin). The "two Aperture processes" theory was checked: the session-0 service loop (`src/platform/windows.rs:665-816`) calls no config setter, so it is unlikely.

**Effect:** the running service kept `1984606088` in memory; the file said `373491561`. The next service restart loaded the old ID and the phone lost the PC. It will repeat whenever Aperture next writes a new-format `enc_id` (any ID change), because hbbs restarts several times a day. `password`, `salt` and `RustDesk2.toml` (trusted phones, `aperture-secure-lan`, server key) are exposed to the same whole-file rewrite by an older schema.

**Fix**
1. Isolate the ID server: run hbbs/hbbr under a dedicated local account (not SYSTEM) with rights only on `C:\ProgramData\Aperture\id-server`, or move them off Windows (also removes the 10054 problem, finding 17). Find out why the NetworkService attempt never listened before retrying it.
2. Aperture-side guard (small, in `src/`, not in hbb_common): keep a pinned ID in an option; at server start, if `Config::get_id()` differs, restore it and log at error level. The own ID server has no competing registrations, so a pinned ID always registers.
3. Longer term: the Windows app still identifies as "RustDesk" (config folder, pipe `\\.\pipe\RustDesk\query`, `C:\Program Files\RustDesk`). Any RustDesk-derived program run as SYSTEM collides with it. Renaming is L and needs a migration.

**Size:** S (1 and 2). **Confidence:** high that hbbs rewrote the file and that the mechanism exists; medium on the exact hbbs code path.

### 2. Reliability / security — emulators and adb are started as SYSTEM children with handle inheritance

**Evidence**
- `src/server/emulator/bluestacks.rs:2708` and `:2746` start HD-Player with `std::process::Command` from the `--server` process, which runs as SYSTEM (`diag2.txt`: "start --server with user SYSTEM"). Rust's `Command` always passes `bInheritHandles = TRUE`.
- Tokio 1.44.2 uses mio 1.0.3 (`Cargo.lock:4771`, `8555`). mio 1.0.3 creates sockets with plain `socket()` (inheritable); mio 1.2.1 added `WSA_FLAG_NO_HANDLE_INHERIT` (its changelog, PR 1946). So every Tokio socket in the service, including the 21120 listener (`src/lan.rs:374`) and live phone connections, is inherited by each child.
- `diag-offline.txt`: after today's restart the new service logged `os error 10048` once per second until HD-Player (PID 11780) was closed with an elevated script (`close-bluestacks.txt`).
- A safe launcher already exists: `platform::run_exe_in_cur_session` (`src/platform/windows.rs:875`) runs as the signed-in user through `CreateProcessAsUserW` with inheritance off (`src/platform/windows.cc:264`). `boot_windows.rs:205` also passes 0.
- adb is spawned the same way (`guest_runtime.rs:163`, `:304`; `bluestacks.rs:1699`). adb leaves a long-lived server process. Whether it holds the socket was not checked.

**Effect:** home path dead after every service restart or host update until BlueStacks exits; BlueStacks and its children run with full machine rights and cannot be closed from the user's Task Manager; a phone connection may not close cleanly while a child still holds a copy of its socket (not verified).

**Fix:** start HD-Player with `run_exe_in_cur_session` at both call sites. (The third `Command::new(player_path)` at `shutdown_windows.rs:575` is test code.) As a second layer, `cargo update -p mio@1.0.3 --precise 1.2.4` (MSRV 1.71, Rust here is 1.75) so sockets are not inheritable at all. Keep short-lived console helpers as they are once mio is updated.

**Size:** S. **Confidence:** high.

### 3. Network — the home path is too impatient away from home and drops the best address first

**Evidence** (`src/client/lan_fast_path.rs`)
- `:17-20`: 250 ms per candidate, 750 ms total; `:250`: TCP connect timeout 200 ms.
- `:135`: each address is tried once (`attempted.insert`). After one timeout the loop only sleeps until the budget ends.
- `:229-237`: discovered addresses are taken first (sorted, up to 3); the last verified address is appended and then cut off by `truncate` when three are already present.
- `race_lan` (`:261`) already runs both routes side by side after the head start, so a longer home-path attempt costs nothing when the ID-server route wins.
- `docs/remote/2026-11-14-own-id-server.md` notes two one-off connect failures over the tunnel on 21120 and 21116.

**Effect:** on mobile data the first packet after idle often needs a radio wake-up and a WireGuard handshake, so 200–250 ms is easily missed. The session then depends on hbbs, which is down for up to 2 minutes after each 10054. Password-free login works only on the 21120 listener, so it is lost at the same time. Not measured on the phone; the timing argument is from code.

**Fix:** try the last verified address first; after the fast pass, retry it with a 1.5–2 s timeout inside a 3–4 s budget; try candidates concurrently. Keep the 250 ms head start for the normal route.

**Size:** S. **Confidence:** medium (logic verified, real RTT unmeasured).

### 4. Performance — phone video is software-decoded on one thread, then copied and repainted the expensive way

**Evidence**
- Android never gets a hardware decoder: `HwCodecConfig::get()` fills only `ram_encode` (`libs/scrap/src/common/hwcodec.rs:537-600`), so `HwRamDecoder::try_get` falls back to ffmpeg software (`:313-346`). Phone log `target/connect-speed-20261114/after.log`: `try create … name: "hevc" … AV_HWDEVICE_TYPE_NONE … priority: 3` and `cpu num: 8 … available memory: 2G, codec thread: 1`.
- One thread because of `res = min(res, memory / 2)` (`libs/scrap/src/common/codec.rs:1000`); Android reports about 2 GB available.
- The emulator view uses the same decoder (`src/client/emulator.rs:39`).
- Each frame is converted to BGRA and handed to Dart; `decodeImageFromPixels` uploads it again (`flutter/lib/models/model.dart:2070-2165`). 1920×1080 is 8.3 MB per frame, 2560×1440 is 14.7 MB.
- The whole `MonitorControlView` is rebuilt per frame: it sits inside `AnimatedBuilder(animation: imageModel)` (`flutter/lib/mobile/pages/target_dashboard_page.dart:1543-1630`) and takes the image as a prop. It is drawn with `FilterQuality.medium` (`monitor_control_view.dart:2218-2221`).
- A MediaCodec decoder exists but is not built: `libs/scrap/src/common/mediacodec.rs`, feature `mediacodec`; Android builds use `flutter,hwcodec` (`tools/build_android_native_windows.ps1:111`).

**Effect:** heat and battery drain, a ceiling on frame rate (60 fps at 1440p is unlikely), and decoder backlogs like those in `docs/remote/2026-10-15-android-lag.md`. Not measured in this review.

**Fix, in steps**
- a. (S) Listen to `imageModel` only around the `RawImage`; add a `RepaintBoundary`; use `FilterQuality.low`.
- b. (S, experiment) Prefer H264 on the phone at home and compare decode time and battery; software H264 is cheaper than HEVC and bandwidth is not the limit on LAN.
- c. (S) On Android do not let the memory heuristic force one thread; and have NVENC emit several slices so slice threading can help. Measure before keeping.
- d. (L) Hardware decode through MediaCodec to a Flutter texture. This is the real fix and removes the per-frame copy.

**Size:** S for a–c, L for d. **Confidence:** high on the facts, medium on how much each step gains.

### 5. Observability — the important failures are invisible, and the logs are noisy

**Evidence**
- Listener bind failure is logged at debug level every second with no state exposed (`src/lan.rs:380`; `diag-offline.txt` shows the one-per-second lines). This also breaks the project rule on unthrottled logging in loops.
- Host health has three components only: `rustdesk`, `guest_helper`, `bluestacks_adb` (`src/server/emulator/host_management.rs:629-686`). Nothing reports the 21120 listener, the virtual display driver, the ID server, or the host's current ID.
- An ID change is one info line (`config.rs:1282`).

**Effect:** today's three incidents (blocked home path, ID revert, missing taskbar) each needed an admin shell and log reading to diagnose. From the phone they all look like "cannot connect" or "slow connect".

**Fix:** log listener state once per change at warn; add health components `home_path` (listening or the bind error), `virtual_display` (reuse `headless_vdd` status), `id_server` (TCP 21116 listening) and show the host ID in the System page. Show "home path" or "ID server route" as a visible label in Quality & connection (the route is already known in `lan_fast_path::start`).

**Size:** S–M. **Confidence:** high.

### 6. Network — remove the ID server from the critical path by pinning the host key at pairing

**Evidence:** the home path only accepts an identity signed by the ID server key and bound to the numeric ID (`lan_fast_path.rs:169-183`, `remember_verified_peer` `:185-197`). A fresh install, a changed ID or a changed server key all need hbbs to be up. `docs/remote/2026-11-14-own-id-server.md` lists this under limits.

**Effect:** hbbs on Windows is the weakest part, yet first connection and recovery after any identity change depend on it.

**Fix:** during "Trust this phone" (already limited to an authenticated, encrypted password session) send the host's signing public key to the phone and store it with the last address. Let the home path accept a host that proves that pinned key, without an hbbs signature and without relying on the numeric ID. Needs a short design and a security review.

**Size:** M. **Confidence:** medium (design proposal).

### 7. User control — Ctrl+click releases the held modifier

**Evidence:** `MonitorKeySender` keeps its own held list (`flutter/lib/mobile/widgets/monitor_key_sender.dart:104-158`), but mouse events take their modifiers from `inputModel.ctrl/alt/shift/command` (`flutter/lib/models/input_model.dart:1114-1118`), which stay false. On mouse-down the host releases any modifier not named in the event (`src/server/input_service.rs:1296`, `fix_modifier` `:1036-1050`).

**Fix:** mirror the held set into the four `inputModel` flags in `_monitorKeyState` and clear them in `releaseAll`. Phone-only.

For the other two keyboard leftovers: clear the strip whenever input is reset or blocked (`_releaseMonitorInput` already exists) and on a timeout shorter than the host's 360 s key release (`input_service.rs:1027`); after the Shortcuts sheet closes, call `enable_soft_keyboard` and refocus the hidden text field instead of `_monitorFocus` (`target_dashboard_page.dart:1943-1946`).

**Size:** S each. **Confidence:** high for Ctrl+click, medium for the other two.

### 8. Maintainability — a month of work and all ops scripts exist only on atlas

**Evidence:** `git status -sb`: 17 commits ahead of `origin`; the last commit on origin is dated 2026-10-11. The ID server setup, watchdog and host update scripts are under `/target`, which is ignored (`.gitignore:2`); `target/` is 6.4 GB and a `cargo clean` removes them. atlas was rebuilt once already (2026-10-21) and the signing key password was lost then (`docs/remote/aperture-releases.md`).

**Fix:** move `Update-ApertureHostDll.ps1`, the ID server setup and watchdog scripts into `tools/aperture-host/` and track them. Back up the branch somewhere off atlas. Note that origin is a fork of a public repository and the docs contain internal addresses and a device serial, so a private mirror or a git bundle on another disk is safer than a push. Keep the offline backup of the signing key the release doc asks for.

**Size:** S. **Confidence:** high.

### 9. Observability — atlas keeps posting to an API server that does not exist

**Evidence:** `get_api_server_` derives `http://10.0.4.93:21114` from the custom ID server (`src/common.rs:1148-1168`). `diag2.txt` shows sysinfo, heartbeat and audit posts failing, each followed by an 18 s "TCP proxy fallback" wait.

**Fix:** return an empty API server when no `api-server` option is set, next to the existing Aperture switch `software_update_check_allowed` in `common.rs` (account sign-in is already disabled, commit `36d9f6c08`). Avoid the builtin `register-device=N` route: it also changes the `RegisterPk` message (`rendezvous_mediator.rs:1279`).

**Size:** S. **Confidence:** high.

### 10. Reliability — the 21120 accept loop blocks a Tokio worker every second

**Evidence:** `serve_secure` calls `default_net::get_default_interface()` on every loop pass (`src/lan.rs:367`). On Windows that runs `GetAdaptersAddresses` and `SendARP` (default-net 0.14.1, `src/interface/windows.rs:38`, `:63`); `SendARP` can block for seconds when the gateway does not answer. No connection is accepted meanwhile.

**Fix:** do the lookup in `spawn_blocking`, and only every 10 s or after a bind or accept error.

**Size:** S. **Confidence:** high (code), low–medium on user-visible impact.

### 11. Performance / UI — the emulator stream profile is fixed and has no control on the phone

**Evidence:** `GuestStreamProfile::FULLSCREEN` is 1280 px, 30 fps, 4 Mbps, a keyframe every second (`src/server/emulator/guest_runtime.rs:31-37`). Host options `aperture-guest-max-size/fps/bit-rate/keyframe-interval` exist (`:17-20`, `:52-70`) but nothing in `flutter/lib` sets them.

**Effect:** the game is scaled down to 1280 px and back up on a 3120×1440 phone. A keyframe each second spends bitrate that a TCP stream does not need, since recovery already requests one.

**Fix:** make the profile a per-session request from the phone's Quality sheet for the emulator view: Sharp (1920 px, 8 Mbps), Smooth (60 fps), Saver. Raise the default keyframe interval to 5–10 s after a check on stream recovery.

**Size:** S–M. **Confidence:** high (code), medium on the visual gain.

### 12. UI / control — the monitor view has no frame-rate or resolution choice

**Evidence:** the quality sheet maps to three RustDesk presets only (`flutter/lib/mobile/widgets/session_quality_panel.dart:7-42`). Resolution change exists only in the stock page (`flutter/lib/mobile/pages/remote_page.dart:1502-1520`).

**Effect:** Windows is shown at 16:9 (1920×1080 headless) on a 19.5:9 screen, with bars and small text; frame rate stays at the default.

**Fix:** add "60 fps" (custom quality plus `custom-fps`) and a resolution list from `pi.resolutions` with a "Match phone" entry. Add a phone-shaped mode (for example 2340×1080) to the MttVDD mode list on atlas. Do the 60 fps option after finding 4 is measured.

**Size:** S–M. **Confidence:** medium (depends on the driver's mode list).

### 13. UI — the connected-PC dashboard keeps a bottom bar in landscape

**Evidence:** `NavigationBar` is used for every orientation (`target_dashboard_page.dart:2020-2043`); the page allows all orientations (`:191`).

**Effect:** in landscape the header and bottom bar take roughly a third of the height. Not checked on the device.

**Fix:** use a `NavigationRail` when width exceeds height.

**Size:** S–M. **Confidence:** medium.

### 14. Performance (host) — full system scans for small questions

**Evidence:** `sysinfo::System::new_all()` runs for each instance list (`src/server/emulator/bluestacks.rs:2667`), for each adb lookup (`remote_windows.rs:176`) and in several other places (`bluestacks.rs:1529`, `1770`; `host_management.rs:523`; `ldplayer.rs:746`). The dashboard refreshes the list every 10 s (`target_dashboard_page.dart:176`).

**Fix:** `System::new()` plus a process-only refresh; cache the adb path.

**Size:** S. **Confidence:** medium (cost not measured).

### 15. User control — one-tap recovery for a headless host

**Evidence:** host actions are `process_end`, `emulator_shutdown`, `shell_restart`, `recover` for adb (`host_management.rs:254-285`). There is no action to restart the Aperture service, the virtual display driver, the ID server, or the PC. The stock "restart remote device" is only in `common/widgets/toolbar.dart:531`, which the Aperture pages do not use. PowerShell is available, but typing commands on a phone is slow.

**Fix:** add confirmed actions to the System page: restart virtual display (reuse `headless_vdd` repair), restart ID server, restart Aperture service, restart PC. Use the existing operation-identity contract.

**Size:** M. **Confidence:** high that they are missing.

### 16. Release process — the host update script does not check the things that broke today

**Evidence:** `target/shell-restart-20261114/deployment/Update-ApertureHostDll.ps1` (1161 lines) has backup and rollback but no check for 21120 or the host ID.

**Fix:** after the restart, fail the deploy if nothing owned by the new `--server` listens on 21120 within 30 s or if `--get-id` differs from before.

**Size:** S. **Confidence:** high.

### 17. Network — hbbs on Windows

**Evidence:** `diag3.txt` and the own-ID-server doc: listeners drop after UDP error 10054; one start took 84 s inside a SQLite pragma; `hbbs.log` and `hbbr.log` grow without rotation (`>>`).

**Fix:** best is to make it non-critical (findings 3 and 6). Otherwise run hbbs on Linux (WSL2, a container or another box), or build it from source with `SIO_UDP_CONNRESET` turned off. Rotate the two logs.

**Size:** M. **Confidence:** medium.

### 18. UI — stale names in phone text

**Evidence:** "Manage Jarvis without leaving your connection." (`target_dashboard_page.dart:1165`); quality descriptions say "RustDesk" (`session_quality_panel.dart:23-27`, `:297`).

**Fix:** use `pi.hostname`; say "Aperture" or drop the product name.

**Size:** S. **Confidence:** high.

### 19. Security — the phone's device key is included in Android backups

**Evidence:** no `allowBackup` or backup rules in `flutter/android/app/src/main/AndroidManifest.xml`; already listed as a known limit in `docs/remote/2026-11-13-phone-key-pairing.md`.

**Fix:** exclude the config files from backup, or set `allowBackup="false"`.

**Size:** S. **Confidence:** high.

### 20. Tests — Rust tests are not in CI, and CI has not seen the last 17 commits

**Evidence:** `.github/workflows/mirpg-feature-ci.yml` runs focused Flutter tests and builds only; the Rust suites named in the docs (emulator 167, lan 28, `aperture_` 14) are run by hand.

**Fix:** add a job for those focused Rust tests with the opt-level override from `docs/remote/2026-10-15-android-lag.md`.

**Size:** M. **Confidence:** high.

## Smaller notes

- Config writes are write-temp-then-rename with no retry (confy `do_store`). A failed rename leaves the temp file and only logs an error. One such orphan is in the user's folder: `C:\Users\gregr\AppData\Roaming\RustDesk\config\RustDesk.45876_ThreadId(22)_…` (2026-10-22). Check the service folder for the same.
- A share-sheet target ("Share to Aperture") would make phone-to-PC file sending one step; the manifest has no `ACTION_SEND` filter. M, optional.
- `printer service init failed` is logged at error on every start (`diag2.txt`); harmless noise.

## Not verified, worth a look

- Whether game sound reaches the phone in the emulator view: the helper runs with `audio=false` (`guest_runtime.rs:176`); the normal host audio service may still carry it.
- Which encoder path atlas uses on the virtual display. The hwcodec config lists a second adapter LUID (`diag2.txt`), probably the virtual display adapter; texture encoding may fall back to the slower RAM path there.
- Whether the MttVDD driver has a newer build than 2024-12.
- Actual round-trip times on mobile data (finding 3) and decode times on the phone (finding 4).

## Checks run

None beyond reading files, `git log/diff/status` and existing logs under `target/`. No tests were run.
