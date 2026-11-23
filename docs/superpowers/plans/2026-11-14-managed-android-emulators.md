# Managed Android Emulators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aperture owns headless Google Android Emulators stored in `D:\Aperture\Emulators`: list, start/stop/restart, create, clone (exact copy), rename and delete from the phone.

**Architecture:** A pure file layer (`avd_files.rs`) reads and writes AVD folders under one root. The `avd` provider lists that root, detects running instances by process and guest property, and starts emulators headless through an Aperture helper running in the signed-in user's session. Management actions travel as new host operations (string actions on `EmulatorHostRequest`), and the phone adds menu items and sheets on the existing emulator cards.

**Tech Stack:** Rust 1.75 (host, `libs/base` proto), Flutter (phone), Android SDK emulator 37.2.12 / ADB.

**Spec:** `docs/superpowers/specs/2026-11-14-managed-android-emulators-design.md`

## Global Constraints
- Root: `D:\Aperture\Emulators`, host option `aperture-avd-home` overrides it. Nothing outside the root is ever listed, started, cloned, renamed or deleted.
- Names: `[A-Za-z0-9._-]`, length 1–64, not starting with `.`; target id `avd:<name>`; display name = name with `_` → space.
- New emulator template: pixel_7, `system-images\android-35\google_apis_playstore\x86_64\`, `hw.ramSize=4096`, `hw.cpu.ncore=4`, `hw.gpu.enabled=yes`, `hw.gpu.mode=host`, `hw.keyboard=yes`, `PlayStore.enabled=true`, `disk.dataPartition.size=24G`; other keys copied from the working trial AVD's `config.ini`.
- Launch: `emulator.exe -avd <name> -no-audio` (normal window), then the helper hides that emulator's top-level windows (`ShowWindow(SW_HIDE)`; found by process `qemu-system-x86_64.exe` whose command line has `-avd <name>`, waiting up to 60 s); env `ANDROID_AVD_HOME=<root>`, `ANDROID_SDK_ROOT=<user SDK>`, run as the signed-in user through helper flag `--aperture-avd-start <name>`; no inherited handles. No user signed in → error "Sign in to Windows on atlas to start emulators".
- Start memory check: Windows available physical memory ≥ `hw.ramSize` + 2048 MB, minus the full `hw.ramSize` of every emulator started in the last 2 minutes; starts serialised by one host-wide lock. Error "Not enough free memory on atlas to start <name>".
- Free-space checks on the root's drive: create ≥ 16 GB; clone ≥ source size + 4 GB.
- "Running" = a `qemu-system-x86_64.exe` whose command line contains `-avd <name>`; clone/rename/delete require not running (and source not being cloned).
- Clone = exact copy, excluding `*.lock`, `multiinstance.lock`, `hardware-qemu.ini`, `snapshots\`, `aperture-*.log*`, `emu-launch-params.txt`; marker `<new>.avd\aperture-clone.json` = `{source, total_bytes, copied_bytes, host_pid, started}`; stale marker (`host_pid` ≠ current process) ⇒ partial folder and `.ini` deleted.
- Proto (libs/base/protos/message.proto, not hbb_common): `EmulatorHostRequest.new_name = 21` (string), `EmulatorHostRequest.window_visible = 22` (bool); `EmulatorInstance.progress_percent = 8` (uint32), `EmulatorInstance.window_visible = 9` (bool).
- Show/hide on PC: host action `avd_window` (`component`, `window_visible`) -> helper `--aperture-avd-window <name> show|hide` in the user session (`SW_SHOW` + `SetForegroundWindow`, or `SW_HIDE`); the host keeps the last state per emulator in memory, hidden after start; phone items "Show on PC" / "Hide on PC" for running `avd` emulators.
- Host actions: `avd_create`, `avd_clone`, `avd_rename`, `avd_delete`, `avd_window` (control-gated, operation identity like `emulator_shutdown`, target identity `emulator:avd:<name>`; for create `emulator:avd:<new_name>`); capability string `host.avd_manage.v1`. `emulator_shutdown` accepts `avd:<name>` and stops via the provider.
- Rust: no new dependencies; no blocking in async; no per-frame logging (AGENTS.md). Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push; installs only with the user's go-ahead.
- Rust tests: `target/headless-vdd-20261113/t.sh <log> <filter>` (single filter). Flutter tests: `cd flutter && flutter test <file>`.

## Review Focus
1. A name containing `..`, `\`, `/`, `:` or a Windows reserved name (`CON`, `NUL`) in any action → rejected before touching disk (Task 1 test `rejects_unsafe_names`).
2. Clone or delete while the emulator is running or mid-clone → refused with a clear message, disk untouched (Task 1 `clone_refuses_running_source`, Task 3 `delete_refuses_running`).
3. Host service restarts mid-clone → partial copy cleaned up on next listing, source intact (Task 1 `stale_clone_marker_is_cleaned_up`).
4. A development AVD running from `%USERPROFILE%\.android\avd` with the same name as nothing in the root → never listed (Task 2 `ignores_running_avds_outside_root`).
5. Two quick Starts with only enough memory for one → the second is refused (Task 2 `recent_starts_reserve_memory`).

---

### Task 1: AVD file layer

**Files:**
- Create: `src/server/emulator/avd_files.rs` (register `#[cfg(windows)] pub mod avd_files;` in `src/server/emulator.rs`)
- Test: same file, `#[cfg(test)] mod tests` using `std::env::temp_dir()` + nonce folders (no new crates)

**Interfaces:**
- Produces:
  - `pub fn valid_avd_name(name: &str) -> bool` (moved here from `avd.rs`; adds reserved names `CON PRN AUX NUL COM1-9 LPT1-9`, case-insensitive)
  - `pub struct AvdHome { root: PathBuf }` with `pub fn new(root: PathBuf) -> Self`, `pub fn default_root() -> PathBuf` (option `aperture-avd-home` or `D:\Aperture\Emulators`), `pub fn list(&self) -> ResultType<Vec<AvdEntry>>`
  - `pub struct AvdEntry { pub name: String, pub ram_mb: u32, pub cores: u32, pub clone: Option<CloneProgress> }`
  - `pub struct CloneProgress { pub source: String, pub total_bytes: u64, pub copied_bytes: u64, pub host_pid: u32 }` with `pub fn percent(&self) -> u32`
  - `pub fn create(&self, name: &str, template: &str) -> ResultType<()>`, `pub fn rename(&self, from: &str, to: &str) -> ResultType<()>`, `pub fn delete(&self, name: &str) -> ResultType<()>`
  - `pub fn clone_avd(&self, from: &str, to: &str, host_pid: u32, progress: impl FnMut(u64, u64)) -> ResultType<()>` (blocking; writes/updates the marker, removes it at the end, removes partial output on error)
  - `pub fn cleanup_stale_clones(&self, current_pid: u32) -> ResultType<Vec<String>>`
  - `pub const NEW_AVD_TEMPLATE: &str` (the trial's `config.ini` with Global Constraints values; `AvdId`/`avd.ini.displayname` filled from the name at write time)
  - `pub fn required_free_bytes_for_clone(&self, from: &str) -> ResultType<u64>` (source size + 4 GB)

- [ ] **Step 1: Write the failing tests**

```rust
#[test] fn rejects_unsafe_names() {
    for bad in ["", ".x", "a/b", r"a\b", "a:b", "..", "a b", "CON", "nul", "COM1", &"a".repeat(65)] {
        assert!(!valid_avd_name(bad), "{bad}");
    }
    assert!(valid_avd_name("Maple_2.copy-1"));
}
#[test] fn create_writes_a_bootable_avd() {
    let home = temp_home("create");
    home.create("Maple_2", NEW_AVD_TEMPLATE).unwrap();
    let ini = read(home.root().join("Maple_2.ini"));
    assert!(ini.contains(&format!("path={}", home.root().join("Maple_2.avd").display())));
    let cfg = read(home.root().join("Maple_2.avd").join("config.ini"));
    for line in ["hw.ramSize=4096", "hw.cpu.ncore=4", "hw.gpu.mode=host", "PlayStore.enabled=true",
                 "AvdId=Maple_2", r"image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\"] {
        assert!(cfg.lines().any(|l| l == line), "{line}");
    }
    assert!(home.create("Maple_2", NEW_AVD_TEMPLATE).is_err(), "name collision");
}
#[test] fn list_reads_ram_and_cores_and_skips_incomplete() { /* create A; write orphan B.ini without B.avd; list == [A(4096,4)] */ }
#[test] fn clone_copies_exactly_except_runtime_files() {
    // source with data/x.bin, userdata-qemu.img, snapshots/s.bin, multiinstance.lock, hardware-qemu.ini
    // after clone_avd("A","B",pid,..): B.avd has data/x.bin + userdata-qemu.img with same bytes,
    // no snapshots/, no *.lock, no hardware-qemu.ini, AvdId=B, B.ini path= B.avd, no aperture-clone.json; A unchanged
}
#[test] fn failed_clone_leaves_no_partial_copy() { /* clone into existing name → Err, no B.avd/B.ini created */ }
#[test] fn stale_clone_marker_is_cleaned_up() {
    // B.avd with aperture-clone.json host_pid=1; cleanup_stale_clones(2) == ["B"], B.avd and B.ini gone, A intact;
    // with host_pid == current it is kept and list() reports clone progress percent
}
#[test] fn rename_and_delete_stay_inside_root() {
    // rename A→C rewrites C.ini path= and AvdId=C; delete C removes C.avd + C.ini;
    // delete("../x") and rename("A","..\\x") are Err and touch nothing
}
```

- [ ] **Step 2: Run to verify RED** — `target/headless-vdd-20261113/t.sh avdfiles-red avd_files` → FAIL (module/functions missing).
- [ ] **Step 3: Implement `avd_files.rs`.** Parse `.ini` as `key=value` lines (keep unknown lines verbatim); copy with `std::fs` in 8 MB chunks, calling `progress(copied, total)` and rewriting the marker at most every 500 ms; canonicalise every target path and require it to start with the canonical root. Move `valid_avd_name` here and make `avd.rs` use it.
- [ ] **Step 4: Run to verify GREEN** — same command → all `avd_files` tests pass; then `t.sh avd-all emulator` → no regressions.
- [ ] **Step 5: Commit** — `feat(host): AVD file layer for managed emulators`.

### Task 2: Provider lists the root, starts headless in the user's session

**Files:**
- Modify: `src/server/emulator/avd.rs`
- Create: `src/server/emulator/avd_launch_windows.rs` (helper + memory check), register in `src/server/emulator.rs`
- Modify: `src/core_main.rs:174` (add `avd_launch_windows::handle_helper_args`)
- Modify: `src/server/emulator/remote_windows.rs` (inventory: `progress_percent`, state `cloning`)

**Interfaces:**
- Consumes: Task 1 `AvdHome`, `AvdEntry`, `CloneProgress`.
- Produces:
  - `pub const AVD_START_HELPER: &str = "--aperture-avd-start";`
  - `pub fn handle_helper_args(args: &[String]) -> bool` (in user session: resolve SDK `%LOCALAPPDATA%\Android\Sdk`, run `adb start-server`, spawn emulator per Global Constraints, detached)
  - `pub fn launch_in_user_session(name: &str) -> ResultType<()>` (uses `crate::platform::run_as_user(vec![AVD_START_HELPER, name])`; maps no-session to the spec's error)
  - `pub const AVD_WINDOW_HELPER: &str = "--aperture-avd-window";` and `pub fn set_window_visible(name: &str, visible: bool) -> ResultType<()>` (runs the helper as the user); helper side finds the top-level windows of that emulator's process titled `Android Emulator - <name>:<port>` or `Emulator`, hidden or not
  - `pub fn window_visible(name: &str) -> bool` (in-memory last state; `false` after start)
  - `fn memory_allows(available_mb: u64, ram_mb: u32, recent_reserved_mb: u64) -> bool` (pure)
  - `fn running_avd_names(processes: &[(String /*exe name*/, Vec<String> /*cmd*/)]) -> BTreeSet<String>` (pure)
  - `AvdProvider::detect()` now returns a provider whenever the root exists (ADB server optional; running state needs it)
  - `EmulatorState::Stopped` targets for root entries not running; cloning entries get `last_error = ""` and state string `cloning` in inventory with `progress_percent`.

- [ ] **Step 1: Write the failing tests** (in `avd.rs` / `avd_launch_windows.rs`):

```rust
#[test] fn running_names_come_from_qemu_command_lines() {
    let p = vec![("qemu-system-x86_64.exe".into(), vec!["x".into(),"-avd".into(),"Maple_1".into(),"-no-window".into()]),
                 ("emulator.exe".into(), vec!["-avd".into(),"Maple_9".into()]),
                 ("HD-Player.exe".into(), vec!["--instance".into(),"Tiramisu64".into()])];
    assert_eq!(running_avd_names(&p), BTreeSet::from(["Maple_1".to_owned()]));
}
#[test] fn ignores_running_avds_outside_root() {
    // root has Maple_1 (stopped); running set {Maple_1? no} + guest names {"DiscreetHome_API35_Test"} →
    // targets == [avd:Maple_1 Stopped]; the dev AVD never appears
}
#[test] fn memory_check_counts_requested_ram_and_margin() {
    assert!(memory_allows(6200, 4096, 0));
    assert!(!memory_allows(6000, 4096, 0));
}
#[test] fn recent_starts_reserve_memory() { assert!(!memory_allows(9000, 4096, 4096)); }
#[test] fn start_refuses_running_and_cloning() { /* provider with fakes: running Maple_1 → start Err "already running"; Maple_2 being cloned from Maple_3 → start Maple_2 Err and start Maple_3 (the source) Err "copy in progress" */ }
```

Make the provider testable by injecting process listing, guest-name probing and available memory through a small `trait AvdSystem` (production impl uses sysinfo + `adb` + `GlobalMemoryStatusEx` via sysinfo `available_memory`).

- [ ] **Step 2: RED** — `t.sh avd2-red server::emulator::avd` → FAIL.
- [ ] **Step 3: Implement.** Discovery = `AvdHome::list()` (after `cleanup_stale_clones(std::process::id())`) joined with running names → serial via existing guest probe (`ro.boot.qemu.avd_name`); `start` takes a `static START_LOCK: Mutex<Vec<(Instant, u32)>>` for recent reservations; `stop` = `adb -s <serial> emu kill` then poll process list up to 20 s; `restart` = stop + start; capabilities start/stop/restart = true. Inventory adds `progress_percent` and state `cloning` for clone entries.
- [ ] **Step 4: GREEN** — `t.sh avd2-green server::emulator::avd` then `t.sh avd2-all emulator`.
- [ ] **Step 5: (done by the controller before execution)** hidden-window start verified on atlas: RTX 3080 in use, same stream speed hidden or shown, redraws when shown. Nothing to do.
- [ ] **Step 6: Commit** — `feat(host): headless managed emulators start, stop and restart`.

### Task 3: Host operations, proto and shutdown

**Files:**
- Modify: `libs/base/protos/message.proto` (fields per Global Constraints)
- Modify: `src/server/emulator/remote.rs` (authorize + target identity + `valid_shutdown_target` accepts `avd:<valid name>`)
- Modify: `src/client/emulator_protocol.rs` (JSON → request for the four actions; `new_name`)
- Modify: `src/server/emulator/host_management.rs` (dispatch; clone runs on a `std::thread` and returns `{"ok":true,"accepted":true,"message":"Cloning…"}` immediately)
- Modify: `src/server/emulator/shutdown_windows.rs` (`avd:` → `AvdProvider::stop`)
- Modify: `src/server/emulator/remote_windows.rs` (capability `host.avd_manage.v1`)
- Modify: `src/flutter.rs:1260` (inventory JSON adds `"progress_percent"`)

**Interfaces:**
- Consumes: Task 1 `AvdHome::{create, clone_avd, rename, delete, required_free_bytes_for_clone}`, Task 2 running detection.
- Produces (JSON the phone sends): `{"action":"avd_window","component":"avd:S","window_visible":true|false}`, `{"action":"avd_create","new_name":N}`, `{"action":"avd_clone","component":"avd:S","new_name":N}`, `{"action":"avd_rename","component":"avd:S","new_name":N}`, `{"action":"avd_delete","component":"avd:S"}`, each with the usual `request_id, operation_id, session_identity, target_identity, session_generation`.

- [ ] **Step 1: Write the failing tests**

```rust
// remote.rs
#[test] fn avd_management_needs_control_and_valid_names() {
    // avd_clone component "avd:Maple_1" new_name "Maple_2": authorize(control=true) Ok, control=false Err;
    // new_name "../x" Err; component "bluestacks:Tiramisu64" Err; target identity == "emulator:avd:Maple_1"
    // avd_create target identity == "emulator:avd:Maple_2"
}
#[test] fn avd_window_needs_control_and_a_running_target() { /* authorize(control=false) Err; JSON window_visible true/false -> request.window_visible; host returns ok=false "not running" for a stopped emulator */ }
#[test] fn shutdown_accepts_android_emulator_targets() { assert!(valid_shutdown_target("avd:Maple_1")); assert!(!valid_shutdown_target("avd:../x")); }
// emulator_protocol.rs
#[test] fn parses_avd_management_requests() { /* each action JSON → EmulatorHostRequest with action/component/new_name */ }
// host_management.rs (with a temp root)
#[test] fn delete_refuses_running() { /* running set {Maple_1} → avd_delete returns ok=false, error mentions "running", folder intact */ }
#[test] fn clone_reports_not_enough_space() { /* free space fake below required → ok=false error_code "avd_clone_failed" */ }
```

- [ ] **Step 2: RED** — `t.sh ops-red emulator` → new tests fail.
- [ ] **Step 3: Implement** per Files list; host_management injects free space and running set through the Task 2 `AvdSystem` trait so tests stay offline.
- [ ] **Step 4: GREEN** — `t.sh ops-green emulator` and `t.sh ops-proto emulator_protocol`.
- [ ] **Step 5: Commit** — `feat(host): create, clone, rename and delete managed emulators`.

### Task 4: Phone model

**Files:**
- Modify: `flutter/lib/models/emulator_model.dart`
- Test: `flutter/test/emulator_model_test.dart`

**Interfaces:**
- Consumes: Task 3 JSON actions and `progress_percent`, capability `host.avd_manage.v1`.
- Produces:
  - `RemoteEmulator.progressPercent` (int, default 0); `runtimeLabel` `'cloning' => 'Cloning $progressPercent%'`
  - `bool get canManageAvds` (capability supported and control)
  - `String? avdActionBlocker(String id, String action)` → `null` or the reason shown on disabled items ('Stop it first', 'Copy in progress')
  - `RemoteEmulator.windowVisible` (bool, from `window_visible`); `Future<void> setAvdWindowVisible(String id, bool visible)`
  - `Future<void> createAvd(String name)`, `cloneAvd(String id, String name)`, `renameAvd(String id, String name)`, `deleteAvd(String id)` — all through `_beginHostOperation` / `_sendHostOperation` like `shutdownEmulator`, with a 2 s refresh timer while an operation or a `cloning` instance exists
  - `canShutdownEmulator` true for provider `avd` too
  - `String suggestAvdName(String base)` → first free of `base`, `base_2`, `base_3`…

- [ ] **Step 1: Failing tests** — `group('managed emulators', …)`: parses `progress_percent` and labels `Cloning 42%`; `cloneAvd` sends `{'action':'avd_clone','component':'avd:Maple_1','new_name':'Maple_1_copy', …}` with target identity `emulator:avd:Maple_1`; `avdActionBlocker` returns 'Stop it first' for a ready emulator's delete and `null` when stopped; actions are no-ops without the capability; `suggestAvdName('Maple')` with Maple and Maple_2 existing → `Maple_3`; `canShutdownEmulator` true for a ready `avd`.
- [ ] **Step 2: RED** — `cd flutter && flutter test test/emulator_model_test.dart --plain-name "managed emulators"` → compile/fail.
- [ ] **Step 3: Implement** in `emulator_model.dart` without reformatting the file (edit only the touched lines).
- [ ] **Step 4: GREEN** — same command passes; `flutter test test/emulator_model_test.dart` all pass.
- [ ] **Step 5: Commit** — `feat(flutter): managed emulator actions in the model`.

### Task 5: Phone screens

**Files:**
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (card menu `_EmulatorShutdownMenu` → actions per spec; "+ New" in the emulator section header; sheets)
- Create: `flutter/lib/mobile/widgets/avd_manage_sheets.dart` (`showAvdNameSheet`, `confirmAvdDelete`)
- Test: `flutter/test/avd_manage_sheets_test.dart`, `flutter/test/target_dashboard_test.dart`

**Interfaces:**
- Consumes: Task 4 model API.
- Produces: `Future<String?> showAvdNameSheet(BuildContext, {required String title, required String initialName, required String note, required bool Function(String) isTaken})`; `Future<bool> confirmAvdDelete(BuildContext, String name)`.

Copy (exact):
- New sheet title "New emulator", note "Android 15 · 4 GB · 4 cores · about 12 GB on D after setup".
- Clone sheet title "Clone <name>", initial `<name>_copy`, note "Exact copy, including Google and game sign-ins. The game will see it as the same device."
- Delete dialog "Delete <name>?" / "Permanently deletes <name> and everything in it." buttons "Cancel" / "Delete".
- Menu items: "Show on PC" / "Hide on PC" (running only, label from `windowVisible`), "Stop", "Restart", "Clone", "Rename", "Delete" (+ existing "Launch game"); disabled items show the blocker as subtitle.

- [ ] **Step 1: Failing tests** — sheet rejects invalid or taken names (Create disabled, message "Use letters, numbers, . _ -" / "Name already used"); delete dialog returns true only on "Delete"; card menu for a ready `avd` shows Stop/Restart enabled and Delete disabled with "Stop it first"; a `cloning` card shows "Cloning 42%" and no menu.
- [ ] **Step 2: RED** — `flutter test test/avd_manage_sheets_test.dart test/target_dashboard_test.dart`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: GREEN** — same; then full `flutter test` (expect all pass) and `flutter analyze` on touched files.
- [ ] **Step 5: Commit** — `feat(flutter): create, clone, rename and delete emulators from the phone`.

### Task 6: Build, install, move the trial, verify on device

**Files:** `tools/aperture-release.json` (1.6.0, versionCode 4113)

- [ ] **Step 1:** Build host DLL, Android native lib, APK (commands in the session notes); stage `target/managed-avd-20261114/deployment` and run `-ValidateOnly` → "VALIDATION PASSED".
- [ ] **Step 2: Ask the user** before installing host + phone and before moving the trial AVD.
- [ ] **Step 3:** Stop the trial; move `%USERPROFILE%\.android\avd\Aperture_Trial_Play35.avd` + `.ini` to `D:\Aperture\Emulators`, rewrite `path=`; leave the development AVDs untouched.
- [ ] **Step 4: On device:** trial listed as Stopped → Boot (window hidden on atlas) → streams; Show on PC → window appears on atlas while streaming; Hide on PC → gone, still streaming; New `Maple_2` → boots; Clone trial → progress → both run at once; Rename; Delete the test copy; development AVDs never listed. Read the timing log for both streams.
- [ ] **Step 5: Commit** — `chore: Aperture 1.6.0`.
