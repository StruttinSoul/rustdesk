# Managed Android Emulators in Aperture — design (2026-11-14)

## Why
The user plays the same game on **several accounts at once**. Google's Android Emulator (AVD) works well through Aperture (running-only provider, commit b52d24dfa: listed, 60 FPS stream, ~35–60 ms tap-to-frame on atlas). They now want Aperture to own these emulators the way it owns BlueStacks instances: run them headless, start/stop/restart them from the phone, and create, clone, rename and delete them, without touching atlas.

## Goals
- Aperture's emulators live in **`D:\Aperture\Emulators`** (user's choice of D drive; folder name is my call). Aperture lists and manages **only** emulators in that folder.
- **Headless by default, switchable live:** emulators start with their window hidden on atlas, and the phone can **Show on PC / Hide on PC** at any time without restarting (user request, added after approval).
- **Full control from the phone:** Start, Stop, Restart per emulator; several can run at once.
- **Create** a new emulator: Android 15 with Play Store, **4 GB RAM, 4 CPU cores** (user's defaults).
- **Clone** an emulator: an **exact copy** (user chose A): installed apps, Google sign-in, game login, settings. The copy gets its own name.
- **Rename** and **Delete** (delete asks for confirmation; it is permanent).
- Streaming, previews and input keep working as today (60 FPS, timing logs).

## Non-goals
- Changing BlueStacks or LDPlayer behaviour.
- Giving clones a new device identity or signing accounts out (user chose an exact copy; see Risks).
- Per-emulator RAM/CPU editing from the phone (defaults only; may come later).
- Running emulators while nobody is signed in to Windows on atlas.
- Other Android versions, device profiles or system images.

## Anti-goals (failure even if it "works")
- Aperture lists, starts, clones or deletes any emulator outside `D:\Aperture\Emulators` (the user's development AVDs in `%USERPROFILE%\.android\avd` — DiscreetHome, Marquee TV, NewLauncher TV, SmartTube, Tally — must never appear or be touched).
- An emulator launched by Aperture inherits the host service's sockets and takes Aperture offline (the BlueStacks HD-Player bug).
- A clone or delete corrupts or removes the wrong emulator, or a running emulator's disk is copied mid-write.
- Starting more emulators than atlas can hold makes the whole PC (and BlueStacks) unusable.

## Constraints (from the current system)
- The host runs as **SYSTEM**; the Android SDK and emulator are the signed-in user's (`%LOCALAPPDATA%\Android\Sdk` of the active user; `crate::platform::get_active_user_home()`), emulator 37.2.12, WHPX.
- System image `system-images;android-35;google_apis_playstore;x86_64` is installed.
- The emulator caps vCPUs at **6** on atlas (measured: `hw.cpu.ncore=8` became 6).
- One emulator takes **~12 GB** on disk once the game is installed; D has **118 GB free** (~8–10 emulators).
- Atlas has 64 GB RAM; with BlueStacks (8 GB) and the trial AVD (8 GB) running, ~13 GB was free.
- AVDs are found through `ANDROID_AVD_HOME`; each AVD is `<name>.ini` (with `path=`) plus `<name>.avd\` (with `config.ini`). Emulator lock files stop the same AVD running twice.
- Running instances are matched by the guest property `ro.boot.qemu.avd_name` (works under SYSTEM; no console token).
- Existing pieces to reuse: the `avd` provider (`src/server/emulator/avd.rs`), `EmulatorProvider::{start, stop, restart}`, the phone's **Boot** on stopped cards (selection with `start_if_stopped`), host operations (`EmulatorHostRequest.action` + `component`, ack/operation identity), `run_as_user` helper-flag pattern (as in `shell_windows.rs`), and the 60 FPS AVD stream profile.
- Rust 1.75; no new dependencies expected. Project rules in AGENTS.md (no blocking in async, throttled logging, explicit errors).

## Approaches
- **Chosen: Aperture's host drives Google's emulator tools directly, with emulators launched in the user's Windows session.** Start = `emulator -avd <name>` (normal window, hidden right after it appears) with `ANDROID_AVD_HOME=D:\Aperture\Emulators`, launched through an Aperture helper running as the signed-in user; stop = ADB `emu kill`; create = write the AVD files from a template; clone = copy the folder and rename; delete/rename = file operations. Keeps the RTX 3080 (host GPU) and avoids the socket-inheritance bug.
- Rejected: launching emulators as the SYSTEM service — would work at the sign-in screen, but the GPU is normally unavailable in session 0 (software graphics) and the emulator would inherit the service's sockets.
- Rejected: `avdmanager` for create — needs Java on atlas and adds nothing over a template.
- Rejected: the emulator's gRPC control channel — ADB already covers start/stop and is what Aperture uses.

## Design

### Host
**Location and discovery**
- Root: `D:\Aperture\Emulators` (host option `aperture-avd-home`, default that path; created on first use).
- The `avd` provider lists every `<name>.ini` in the root whose `<name>.avd\config.ini` exists → targets `avd:<name>`, state **Stopped** unless a running instance reports that `ro.boot.qemu.avd_name` (then Booting/Ready as today). Running AVDs not in the root are ignored (closes the gap where the running-only provider listed any AVD).
- Names: `[A-Za-z0-9._-]`, ≤ 64, not starting with `.` (existing `valid_avd_name`). Display name = name with `_` → space.

**Start / restart**
- `start`: refuse if already running or locked; check free RAM ≥ the AVD's `hw.ramSize` + 2 GB (else a clear error: "Not enough free memory on atlas to start <name>"). Then run the Aperture executable as the signed-in user with a helper flag (e.g. `--aperture-avd-start <name>`), which sets `ANDROID_AVD_HOME` and `ANDROID_SDK_ROOT` and spawns `emulator.exe -avd <name> -no-audio` detached (no inherited handles), waits up to 60 s for the emulator's top-level windows (process `qemu-system-x86_64.exe` with `-avd <name>`; titles `Android Emulator - <name>:<port>` and `Emulator`), and hides them (`ShowWindow SW_HIDE`).

**Show / hide on PC** - host operation `avd_window` (`component`, `window_visible`): runs the helper `--aperture-avd-window <name> show|hide` in the user's session, which finds that emulator's top-level windows by process and calls `ShowWindow` (`SW_SHOW` + bring to front, or `SW_HIDE`). The host remembers the last state per emulator (hidden after start) and reports it as `EmulatorInstance.window_visible`. Closing a shown window on atlas stops the emulator, as usual.

*Verified on atlas (2026-11-14, throwaway AVD):* `-no-window` and `-qt-hide-window` create no main window, so they cannot be shown later. A normal start whose windows are hidden with `SW_HIDE` keeps rendering on the RTX 3080, streams at the same speed hidden or shown (tap-to-frame 74-131 ms, frame gap 41-49 ms on a 2-core test AVD in both states), and redraws correctly when shown again. If nobody is signed in, fail with "Sign in to Windows on atlas to start emulators".
- The existing selection path (`start_if_stopped`, 90 s boot wait) then streams it — the phone's **Boot** button works unchanged.
- `stop`: `adb -s <serial> emu kill`, wait up to 20 s for it to leave `adb devices`.
- `restart`: stop, wait, start.
- Capabilities: start/stop/restart = true.

**Create / clone / rename / delete** — new host operations (control-gated, same operation identity/ack as `emulator_shutdown`), `component` = `avd:<name>`, plus a new `EmulatorHostRequest` field `new_name` (libs/base proto, not hbb_common):
- `avd_create` (`new_name`): write `<new_name>.ini` (`path=` absolute D path) and `<new_name>.avd\config.ini` from a template: pixel_7, android-35 google_apis_playstore x86_64, `hw.ramSize=4096`, `hw.cpu.ncore=4`, `hw.gpu.enabled=yes`, `hw.gpu.mode=host`, `hw.keyboard=yes`, `PlayStore.enabled=true`, `disk.dataPartition.size=24G`. Requires ≥ 16 GB free on D.
- `avd_clone` (`component` source, `new_name`): source must be **stopped**; requires free space ≥ source size + 4 GB. Copy `<src>.avd` to `<new>.avd` excluding lock files (`*.lock`, `multiinstance.lock`), `hardware-qemu.ini`, `snapshots\`, launch logs; write `<new>.ini` with the new `path=`; set `AvdId`/`avd.ini.displayname` in the copy's `config.ini` to the new name. Runs as a background task; the operation reports progress/finished/failed through the existing host-operation status, and the copy shows as "Cloning…" until done. A failed clone removes its partial folder.
- `avd_rename` (`component`, `new_name`): stopped only; rename folder + `.ini`, rewrite `path=` and `AvdId`.
- `avd_delete` (`component`): stopped only; removes `<name>.avd` and `<name>.ini`. Only inside the root (path checked after canonicalisation).
- All operations reject names outside the rules, targets outside the root, and collisions with existing names.

**Moving the trial emulator**: a one-time move of `Aperture_Trial_Play35` from `%USERPROFILE%\.android\avd` to the root (stopped first), keeping its 6 cores / 8 GB. Done by the builder at install time with the user's go-ahead, not by product code.

### Phone
- Emulator cards for `avd` instances get **Start** (existing Boot), **Stop**, **Restart**, **Show on PC / Hide on PC** (running only) (overflow menu), and **Clone / Rename / Delete** (overflow; disabled with a reason while running).
- A **New emulator** action in the emulator list header opens a sheet: name field (pre-filled e.g. `Maple_2`), shows "Android 15 · 4 GB · 4 cores · about 12 GB on D after setup", Create.
- Clone opens the same sheet with the name pre-filled `<source>_copy`, and a note: "Exact copy, including Google and game sign-ins. The game will see it as the same device."
- Delete asks to type or confirm the name: "Permanently deletes <name> and everything in it."
- Long operations (clone) show progress on the card and survive leaving the screen.
- Shutdown capability extends to `avd` (`canShutdownEmulator`), using `stop`.

Sketch (emulator list):
```
Emulators                         [+ New]
┌ Maple 1   Android Emulator · Ready   [Open] [⋮] ┐   ⋮ = Show on PC · Stop · Restart · Clone · Rename · Delete
┌ Maple 2   Android Emulator · Stopped [Boot] [⋮] ┐
┌ Maple 3   Cloning… 42%                          ┐
┌ Tiramisu64_3   BlueStacks · Ready    [Open] [⋮] ┐
```

### Decisions settled after the builder check (my calls)
1. **Clone progress / "Cloning…" state:** the clone worker writes a marker `<new>.avd\aperture-clone.json` (`{source, total_bytes, copied_bytes, host_pid, started}`) and updates it as it copies. Discovery lists such a folder as state `cloning` with progress; `EmulatorInstance` gets a new field `progress_percent` (libs/base proto). The phone already re-fetches the list (10 s; 2 s while an operation is pending), so progress needs no new call. The marker is removed when the copy completes; a marker whose `host_pid` is no longer the running host (service restarted mid-clone) marks a failed clone: discovery deletes that partial folder and its `.ini`.
2. **ADB server:** there is one ADB server on `127.0.0.1:5037` shared by all users; the host already finds and talks to it as SYSTEM (`running_adb_server`, used by the current provider). Before launching an emulator the user-session helper runs `adb start-server` from the user's SDK so the server exists; emulators register with it on their own. `stop` and discovery keep using it.
3. **"Running" is decided by processes, not lock files:** an AVD counts as running when a `qemu-system-x86_64.exe` process's command line contains `-avd <name>` (sysinfo, visible to SYSTEM); the guest property then maps it to its ADB serial for Booting/Ready. Clone, rename and delete require no such process. Lock files are ignored for decisions (they can be stale after a crash) and are excluded from clones.
4. **Template:** the `config.ini` keys are taken from the working trial AVD (including `image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\`, `tag.id=google_apis_playstore`, `abi.type=x86_64`, `hw.device.name=pixel_7`, `hw.device.manufacturer=Google`, `hw.lcd.*` of pixel_7), with RAM/CPU/name changed. The emulator creates `userdata-qemu.img` from the system image on first boot; images are qcow2 and grow on use, so `24G` is a ceiling, not an allocation.
5. **RAM check:** "free" = Windows available physical memory. Starts are serialised by one host-wide lock, and an emulator started in the last 2 minutes still counts its full `hw.ramSize` against the check (it has not allocated yet). No separate cap on the number of emulators; memory decides.
6. **Outside the root:** AVDs outside `D:\Aperture\Emulators` are invisible, running or not. The trial emulator appears again once moved into the root (same name, so the phone keeps its `avd:Aperture_Trial_Play35` id).
7. **While cloning:** the new copy's card shows progress and allows nothing else; its source cannot be started, renamed or deleted until the copy finishes (the copy reads its disk).

## Risks
- **Exact copies share the device identity** (Android ID, Google services ID). The game or Google may treat copies as one device; the user accepted this. Signing each copy into a different account is manual.
- **Hidden window**: the window may flash on atlas for a few seconds at start before it is hidden. Verified: rendering stays on the RTX 3080 while hidden.
- **Disk**: ~12 GB per emulator; D fits ~8–10. Space checks prevent half-written clones.
- **Memory**: several 4 GB emulators plus BlueStacks; the start-time RAM check prevents overcommit.

## Verification
- Unit tests: AVD file parsing/writing (template, clone rewrite of `path=`/`AvdId`), name and root-path validation (incl. `..`, other folders, collisions), discovery listing stopped + running, start refusals (already running, low RAM, no signed-in user), proto/authorisation for the new host actions.
- Flutter tests: card actions per state, New/Clone/Delete sheets, disabled reasons while running, progress state.
- On atlas (with the user's go-ahead for installs): create → boot headless → stream; clone a stopped emulator → both run at once → stream each; rename; delete; development AVDs on C never appear.

## Left to the builder
- Exact helper-flag name and how the helper passes the emulator's exit/errors back (log is enough).
- Template details beyond those listed (skin, `hw.lcd.density`), and the RAM-check margin if 2 GB proves wrong.
- How clone progress is measured (bytes copied / total).
- Card/menu layout details within the existing dashboard style.
