# Built-in emulator feasibility study

Date: 2026-11-14
Status: **research only** — nothing was installed, launched, downloaded, or changed. No emulator was booted and no ADB command was sent to a running instance.

## Recommendation

**Do not replace BlueStacks now, and do not build or ship our own emulator.** Keep BlueStacks as the production provider and harden it.

If independence from BlueStacks is wanted, the only path worth a trial is **Aperture managing Google's Android Emulator (AVD) as a third provider**. It is a small, low-risk experiment because the SDK emulator is already installed on this host and Aperture's guest pipeline already accepts its ADB serials. Whether it can actually replace BlueStacks depends on one thing this study could not check: **whether `com.nexon.ma` installs, starts, and stays logged in on a Play Store AVD**. That is a 1–2 hour manual test and should be done before any code is written.

A **spare physical Android phone** is the fallback if the game ever starts blocking emulators. It is the only option that gives real device integrity.

## How Aperture talks to an emulator today

Verified by reading the source.

| Concern | Mechanism | Where |
|---|---|---|
| Discovery, lifecycle | Provider reads the vendor's own config and process list, launches `HD-Player.exe --instance <id>` (BlueStacks) or `ldconsole` (LDPlayer) | `src/server/emulator/bluestacks.rs`, `ldplayer.rs` |
| Guest bridge | Local ADB only. Serial must be `127.0.0.1:<port>` or `emulator-<even port ≥ 5554>` | `guest_runtime.rs::is_local_emulator` |
| Video | A pinned, SHA-256-checked **scrcpy server v4.0** is pushed into the guest. Its H.264 stream is forwarded as-is in RustDesk `VideoFrame`s (no Windows capture, no re-encode). Default 1280 px, 30 FPS, 4 Mbps; preview 360 px | `guest_runtime.rs`, `guest_protocol.rs` |
| Input | scrcpy control socket: touch packets, clipboard-paste text, video reset | `guest_protocol.rs` |
| Audio | Not streamed (`audio=false`) | `guest_runtime.rs` |
| Window capture | Not used for emulators. `window_picker.rs` is a separate desktop feature | — |

So Aperture is **not** tied to the BlueStacks window. It needs the emulator only as an Android guest reachable over local ADB.

### What a provider must offer

The contract is the `EmulatorProvider` trait in `src/server/emulator.rs`: `discover`, `refresh`, `start`, `stop`, `restart`, `resolve_adb`, `capabilities`. In practice a candidate needs:

1. A stable instance identity that survives restarts (not a PID or port).
2. Scriptable start/stop and a readable running state.
3. A local ADB endpoint, with `sys.boot_completed` readable.
4. Android 5+ with a working H.264 `MediaCodec` encoder for scrcpy (software is acceptable at 1280 px/30 FPS).
5. Ability to run with no visible window, on a headless virtual display, ideally before Windows sign-in.

Two caveats on effort: provider construction is hard-wired in `remote_windows.rs` (two `detect()` calls, not a generic registry), and a large share of the 14k lines in `src/server/emulator/` is BlueStacks-specific management (cleanup journal, app cache, default app, pre-login boot, Eco FPS). A new provider gets streaming and input almost for free, but none of that management layer.

## Host facts observed (read-only)

| Item | Finding |
|---|---|
| CPU / RAM | i7-12700K, 64 GB |
| GPU | RTX 3080 OK; Intel UHD 770 in error state; Virtual Display Driver present |
| Hypervisor | Running. Hyper-V and Virtual Machine Platform enabled; WSL2 with Docker Desktop and Ubuntu |
| BlueStacks | 5.22.285.1013, three Android 13 instances (`Tiramisu64*`), Vulkan renderer, 4 vCPU / 4 GB, ABI list `x86,x64,arm,arm64`, one `HD-Player` running |
| Game | `com.nexon.ma` (MapleStory : Idle RPG) per the instance app cache |
| Android SDK | Emulator 37.2.12 installed; `emulator -accel-check` reports "WHPX is installed and usable" |
| AVDs | Six exist (TV and test profiles). One uses the `android-35 google_apis_playstore x86_64` image, but with `PlayStore.enabled=no` |
| Play image ABIs | `x86_64, arm64-v8a` via `libndk_translation`; **32-bit ABI list is empty** |
| Other emulators | No LDPlayer at `C:\LDPlayer`, no MuMu, MEmu, Genymotion, WSA, or Google Play Games found at default paths |

Two things to note. The Windows optional feature `HypervisorPlatform` reads as disabled while the emulator reports WHPX usable; I did not resolve that discrepancy. And BlueStacks is already running on Hyper-V here, so a second Hyper-V-based emulator can coexist with it in principle — coexistence under load is untested.

## Options

### Summary

| Option | Verdict | Effort | Main blocker |
|---|---|---|---|
| A. Aperture-managed Google Android Emulator (AVD) | **Trial candidate** | M | Game compatibility unverified; licence is developer-use only |
| B. Our own AOSP/QEMU emulator | **Reject** | XL | No Google Play, no licensed ARM translation, permanent maintenance |
| C. Windows Subsystem for Android | **Reject** | — | Discontinued |
| C2. Google Play Games on PC | Not a provider | L | No ADB; window capture only; game listing unconfirmed |
| D. LDPlayer / MuMu / MEmu / Genymotion | Swap, not "built in" | S–M each | Same dependency class as BlueStacks |
| E. Waydroid / redroid in WSL2 or a VM | **Reject** | L–XL | No practical NVIDIA acceleration; GMS not certified |
| F. Real Android device | **Fallback** | S–M | Needs hardware; one device per instance |

### A. Aperture manages Google's Android Emulator

**What it means.** Aperture does not embed an emulator. It creates or adopts an AVD, launches `emulator.exe -avd <name> -no-window -gpu host -port <n>`, and attaches the existing scrcpy pipeline to `emulator-<n>`.

**Fit with Aperture.** Very good. `-no-window` is documented for hosts "that have no display", access is through ADB or the console, and ports are deterministic (console/ADB pairs from 5554, up to 64 instances). The serial format is already accepted by `is_local_emulator`. Discovery is `emulator -list-avds` plus the `.ini` files; stop is the console `kill` command or `adb emu kill`. The emulator's gRPC endpoint (`-grpc <port>`, screenshot stream, touch, WebRTC) exists in the installed build but is not needed and is described upstream as experimental.

**Hypervisor.** Google recommends WHPX on Windows, and the alternative AEHD driver is being retired on 31 December 2026 and requires Hyper-V off. WHPX is the right match for this host.

**GPU.** `-gpu host` uses the host GPU and is the documented fastest mode. Headless rendering on the RTX 3080 with the virtual display driver, and behaviour when launched before sign-in, are **unverified**. Expect lower game performance than BlueStacks: the SDK emulator is tuned for app testing, not games, and its graphics translation layer has known game incompatibilities.

**Game compatibility — the open risk.**
- *Google Play*: only `google_apis_playstore` images include the Play Store. They are locked user builds (no root), which is fine for scrcpy.
- *ARM*: the local API 35 Play image translates `arm64-v8a` only. BlueStacks advertises 32-bit ARM as well. If the game ships only ARM libraries it should still load under translation, but with a performance cost; a 32-bit-only dependency would not load. I did not inspect the game's APK.
- *Play Integrity*: Google documents that an emulator yields an **empty device verdict**. `MEETS_VIRTUAL_INTEGRITY` is reserved for Google Play Games on PC. A game that enforces device integrity will refuse an AVD. BlueStacks is in the same position and the game runs there, which suggests enforcement is not strict today — an inference, not a finding.
- *Emulator detection*: an AVD announces itself plainly (goldfish/ranchu hardware, `sdk_gphone` model). Commercial emulators invest in looking like retail devices and are often tolerated or allow-listed by publishers; the stock AVD is not. Nexon titles commonly ship their own client protection. **This is the most likely failure point and cannot be predicted from documentation.**

**Licensing.** The emulator binary is open source. The system images are not: the SDK licence grants use "solely to develop applications" and forbids redistribution, and Google's ARM-translation announcement limits it to development and debugging. Consequences: Aperture must never bundle or download images on the user's behalf without the SDK licence prompt, and using an AVD as a daily gaming device sits outside the stated purpose of the licence. For a single personal host that is a judgement call for the owner; it rules out shipping this as a product feature.

**Multi-instance.** One AVD per account, each with its own port pair. `-read-only` clones cannot save state, so they are unsuitable for game accounts.

**Maintenance.** Low for the emulator (Google updates it), moderate for us: emulator updates change flags (the `emulator` CLI is now marked deprecated in favour of a new `android emulator` command), and each image update is a new compatibility test.

**Effort: M.** Roughly a `ldplayer.rs`-sized provider (~1,400 lines there), plus generalising provider construction, plus tests. Pre-login boot would be additional and uncertain.

### B. Ship our own AOSP/QEMU emulator — rejected

A self-built AOSP image has **no Google Play services** (GMS requires a licensed, certified device), so no Play Store install, no Google sign-in, and no Play Integrity verdict at all. ARM translation (`libndk_translation`, `libhoudini`) is proprietary and not redistributable. On top of that come graphics passthrough for Windows, monthly security merges, and yearly Android rebases. This is what BlueStacks and LDPlayer employ teams to do. **XL effort for a strictly worse result.**

### C. Windows Subsystem for Android — rejected

Microsoft's documentation is archived and states that from 5 March 2025 WSA and the Amazon Appstore are no longer available in the Microsoft Store. It never included Google Play, and Microsoft documented that it had no anti-cheat provisions. Community builds with added GMS are unsupported and unlicensed. Not a foundation.

### C2. Google Play Games on PC — not a provider

It is Google's own Hyper-V-based Android runtime and the only emulator that receives a passing (virtual) integrity verdict. But the consumer app exposes no ADB, runs one catalogue game per window, and has no instance management, so Aperture could only reach it through desktop window capture and injected mouse input — the architecture the design doc explicitly rejects. I also could not confirm that this game is in its catalogue (one third-party page claims it; no Nexon or Google source found). Worth knowing about as an official PC route, not as an Aperture target.

### D. Other commercial emulators — a swap, not a replacement

These already fit the provider interface (LDPlayer has one). They trade one closed vendor for another and keep every drawback that motivates the question: adware and telemetry to suppress, undocumented config, breaking updates.

| Emulator | Notes |
|---|---|
| LDPlayer | Provider exists. Documented CLI (`ldconsole`). Hyper-V compatibility arrived in 2026 builds according to press coverage; sources disagree on the exact version. Not found installed at the default path |
| MuMu Player | Has a manager CLI and ADB. The official FAQ I found (2021) says to disable Hyper-V; newer builds may differ — unverified. Disabling Hyper-V would break WSL2/Docker on this host |
| MEmu | ADB and a CLI exist; historically VirtualBox-based with the same Hyper-V concern. Not researched further |
| Genymotion | Developer product, paid for non-personal use, no Play Store or ARM translation out of the box. Poor fit for games |

Useful only as a **contingency**: if BlueStacks breaks, reviving the LDPlayer provider is S effort.

### E. Waydroid / redroid in WSL2 or a Linux VM — rejected

Both are container-based Android that view well through scrcpy, and redroid images include `libndk_translation`. The problems are on this specific host:

- **GPU**: Waydroid supports Mesa drivers only; with NVIDIA it falls back to software rendering, and the community NVIDIA workaround is fragile. redroid defaults to software rendering and its docs do not claim NVIDIA support. WSL2 exposes the GPU through a paravirtual interface that neither project targets. Expect CPU rendering.
- **Kernel**: both need the `binder` module; redroid's docs do not mention WSL2. A custom WSL2 kernel or a separate Hyper-V Linux VM (with no GPU passthrough on a single-GPU desktop) would be required.
- **Google Play**: GApps are added unofficially; the device is uncertified and must be manually registered with Google, and integrity verdicts fail.

High effort, worst graphics performance, weakest game compatibility.

### F. Stream a real Android device — fallback

A spare phone on USB, driven by the same scrcpy server. Native ARM, real GPU, and genuine `MEETS_DEVICE_INTEGRITY`, so it is immune to emulator blocking. scrcpy supports USB and TCP/IP connections through ADB.

Costs: hardware per instance, battery and heat management for an always-on idle game, and no vendor "start/stop" (the provider would wake the device and launch the app). Aperture change: `is_local_emulator` currently rejects non-loopback serials on purpose, so a deliberate, narrowly scoped "USB device" provider would be needed — **S–M effort**. The Aperture phone client could of course run the game itself; this option only makes sense for the always-on, automation-driven setup.

## Should BlueStacks be replaced?

**Not on current evidence.** Reasons:

1. **It works, and the game publisher's ecosystem expects it.** BlueStacks advertises this exact title. Every alternative carries a real chance of the game refusing to run.
2. **Aperture already bypasses BlueStacks' weak points.** Video and input go straight to the guest. The remaining BlueStacks surface is launch, config, and bloat suppression, and that code is already written and tested.
3. **"Built in" is not achievable in the literal sense.** No option lets Aperture ship an Android runtime with Google Play. The best case is Aperture *managing* an emulator that Google or a vendor distributes.
4. **Other sessions depend on it.** The game bridge, the ADB port layout (5555/5575/5585), and the solver screenshots are built around these instances. A migration moves the game account data and re-validates all of that.

The honest gain from an AVD would be: no adware or telemetry, documented CLI, deterministic ports, true headless mode, and a vendor that will not disappear. The honest cost: unknown game compatibility, likely lower frame rate, and a licence that does not cover this use.

## Phased plan

**Phase 0 — compatibility spike (manual, about 1–2 hours, no code).**
Create a new Play Store AVD (Pixel profile, API 34 or 35), sign in with a **throwaway Google account**, install the game, and check: installs from Play, gets past the title screen, creates a guest character, survives 30 minutes, frame rate acceptable. Then repeat launched with `-no-window -gpu host` and attach stock scrcpy. Do not use the main game account until this passes; I cannot rule out account action for running on an unrecognised emulator.

- **Fails** → stop. Record the result here and stay on BlueStacks.
- **Passes** → Phase 1.

**Phase 1 — AVD provider behind the existing trait (M).**
New `android_emulator.rs`: discovery from `emulator -list-avds` and AVD `.ini` files, fixed port per AVD, headless launch, console stop, readiness via `sys.boot_completed`. Replace the two hard-coded `detect()` calls in `remote_windows.rs` with registry-driven construction. Aperture must locate an existing SDK and never fetch images itself. Unit tests against fixture directories, as the other providers do.

**Phase 2 — soak in parallel (2–4 weeks).**
Run one secondary account on the AVD next to BlueStacks. Watch for disconnects, Play Services prompts, emulator updates, and CPU/GPU cost against a BlueStacks instance.

**Phase 3 — decide.**
Migrate only if Phase 2 is clean and the game bridge has been pointed at the new serial. Keep BlueStacks installed as rollback for at least one game update cycle.

**In parallel, regardless of outcome — harden the BlueStacks provider (S each).**
- Finish the outstanding cold-boot acceptance test in `docs/prelogin-bluestacks-probe.md`.
- Pin and record the BlueStacks version; alert on version change, since the cleanup profile must be re-applied after updates.
- Resolve the static-screen liveness follow-up noted in `2026-10-15-android-lag.md`.
- Keep the LDPlayer provider compiling as the contingency vendor.

## What I could not verify

- Whether `com.nexon.ma` installs or runs on an AVD, and which native ABIs its APK contains.
- Whether the game or Nexon's protection calls Play Integrity or detects stock emulators, and Nexon's policy on emulator use. No official Nexon statement was found.
- Whether the game is offered on Google Play Games on PC.
- Headless `-gpu host` behaviour on the RTX 3080 with the virtual display, before sign-in, or under the LocalSystem service context.
- AVD game performance relative to BlueStacks, and stability of both running together under WHPX.
- scrcpy v4.0 H.264 encoding on current AVD images (expected to work; not run).
- Current Hyper-V support in MuMu and the exact LDPlayer version that added it.
- The `HypervisorPlatform` feature state versus the emulator's "WHPX usable" report.

## Sources

- Android Emulator command line (`-no-window`, `-port`, `-gpu`, `-accel`): https://developer.android.com/studio/run/emulator-commandline
- Emulator acceleration (WHPX recommended, AEHD sunset 2026-12-31, GPU modes): https://developer.android.com/studio/run/emulator-acceleration
- Play Integrity verdicts (empty verdict for emulators, `MEETS_VIRTUAL_INTEGRITY`): https://developer.android.com/google/play/integrity/verdicts
- Integrity on Google Play Games on PC: https://developer.android.com/games/playgames/integrity
- Android SDK licence (clauses 3.1, 3.4, 3.5): https://developer.android.com/studio/terms
- ARM translation in emulator images and its usage restriction: https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html
- Emulator gRPC definition: https://android.googlesource.com/platform/tools/base/+/studio-master-dev/emulator/proto/emulator_controller.proto
- WSA discontinuation (archived): https://learn.microsoft.com/en-us/windows/android/wsa/
- Waydroid and NVIDIA: https://github.com/waydroid/waydroid/discussions/1619 and https://wiki.archlinux.org/title/Waydroid
- redroid README (binder, GPU modes, native bridge, scrcpy): https://github.com/remote-android/redroid-doc
- scrcpy connection modes: https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md
- BlueStacks page for the game: https://www.bluestacks.com/apps/casual/maplestory-idle-rpg-on-pc.html
- MuMu Hyper-V FAQ (2021): https://mumuglobal.com/20210618/35327_943026.html
- LDPlayer Hyper-V coverage: https://www.pocketgamer.com/features/ldplayer-android-14-update/
- LDPlayer CLI: https://www.ldplayer.net/support/introduction-to-ldplayer-command-line-interface.html
- Local observations: `emulator -help`, `emulator -accel-check`, `emulator -list-avds`, AVD `config.ini`, system-image `build.prop`, `bluestacks.conf`, BlueStacks `AppCache.json`.
