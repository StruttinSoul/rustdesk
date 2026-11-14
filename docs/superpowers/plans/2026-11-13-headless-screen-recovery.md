# Headless Screen Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Atlas restarts a crashed MikeTheTech virtual display (`Root\MttVDD`) from its watchdog, and a login that finds no screen waits up to 10 s for that repair instead of sending an empty display list.

**Architecture:** One new module `src/headless_vdd.rs`: pure decision/rate-limit logic (all platforms, unit-tested) plus a Windows-only device layer (SetupAPI enumeration by hardware ID, `CM_Get_DevNode_Status`, restart via `pnputil /restart-device`). A process-wide limiter is shared by the watchdog loop (`src/server/emulator/host_management.rs`) and the login path (`update_get_sync_displays_on_login` in `src/server/display_service.rs`), both in the `--server` process.

**Tech Stack:** Rust 1.75.0, `winapi` 0.3 (`setupapi`, `cfgmgr32` features already enabled), Tokio (already running).

**Spec:** `docs/superpowers/specs/2026-11-13-headless-screen-recovery-design.md`

## Global Constraints

- Rust 1.75.0 toolchain; no new dependencies; no `hbb_common` changes.
- Only devices whose hardware ID equals `Root\MttVDD` (case-insensitive, exact) are ever restarted.
- Repair only when the problem code is non-zero and not `CM_PROB_DISABLED` (22). Problem code 0 = healthy.
- At most one repair per 60 s; after 3 consecutive repairs that leave the device failed at the next check, at most one per 600 s until a check finds it healthy.
- Login wait: only when `Display::all()` is empty AND a `Root\MttVDD` device needs repair; poll every 500 ms, up to 10 s; otherwise behaviour is unchanged.
- Never block an async task: device enumeration and `pnputil` run in the watchdog thread or `tokio::task::spawn_blocking`.
- Logging: one `info` per repair attempt with its result, one `warn` when entering back-off; nothing per healthy pass.
- Focused test recipe: `cargo test --release --lib --features flutter,hwcodec,vram --config profile.release.package.rustdesk.opt-level=0 --config profile.release.package.rustdesk.codegen-units=16 --no-fail-fast <filter>`

## Review Focus

- A `pnputil` that hangs: the call must time out (30 s) and count as a failed attempt, not wedge the watchdog or a login. Covered by Task 2's timeout helper test.
- The device disappears between enumeration and restart: restart error is logged once and counts as an attempt; no panic. Covered in Task 2 by error-path handling (manual check).
- A login while the watchdog is mid-repair: the login must not start a second restart (limiter denies) but still waits for the screen. Covered by Task 1 limiter test + Task 3 wiring.
- Disabled-by-user driver (code 22) with no screen: no restart, no 10 s wait. Covered by Task 1 `needs_repair` test and Task 3's condition.
- A healthy host with screens: zero added latency at login. Covered by Task 3 condition (displays non-empty short-circuits).

---

### Task 1: Decision and rate-limit logic

**Files:**
- Create: `src/headless_vdd.rs` (register `pub mod headless_vdd;` in `src/lib.rs` beside `virtual_display_manager`)

**Interfaces:**
- Produces:
  - `pub const MTTVDD_HARDWARE_ID: &str = "Root\\MttVDD";`
  - `pub fn needs_repair(problem_code: u32) -> bool`
  - `pub fn is_mttvdd_hardware_id(ids: &[String]) -> bool` (true if any entry equals `MTTVDD_HARDWARE_ID` ignoring ASCII case)
  - `pub struct RepairLimiter` with `pub fn new() -> Self`, `pub fn may_repair(&self, now: Instant) -> bool`, `pub fn record_attempt(&mut self, now: Instant)`, `pub fn observe(&mut self, needs_repair: bool) -> bool` (returns true exactly when this observation enters back-off, so the caller logs the one warn), `pub fn in_backoff(&self) -> bool`.
  - `pub async fn wait_until(has_screen: impl FnMut() -> bool, timeout: Duration, step: Duration) -> bool`
  - Constants `REPAIR_INTERVAL = 60 s`, `BACKOFF_INTERVAL = 600 s`, `BACKOFF_AFTER = 3`, `LOGIN_WAIT = 10 s`, `LOGIN_POLL = 500 ms`.

Limiter semantics: `record_attempt` stores the time and marks an attempt pending. `observe(x)`: if an attempt is pending, clear it and `consecutive += 1` when `x` is true, else reset to 0; if none is pending and `x` is false, reset to 0. Back-off is `consecutive >= BACKOFF_AFTER`; the interval used by `may_repair` is `BACKOFF_INTERVAL` in back-off, else `REPAIR_INTERVAL`.

- [ ] **Step 1: Write the failing tests** (`#[cfg(test)] mod tests` in the same file)

```rust
#[test] fn healthy_and_disabled_are_not_repaired() {
    assert!(!needs_repair(0)); assert!(!needs_repair(22));
    assert!(needs_repair(43)); assert!(needs_repair(10));
}
#[test] fn hardware_id_match_is_exact_and_case_insensitive() {
    assert!(is_mttvdd_hardware_id(&["ROOT\\MTTVDD".into()]));
    assert!(is_mttvdd_hardware_id(&["PCI\\X".into(), "Root\\MttVDD".into()]));
    assert!(!is_mttvdd_hardware_id(&["Root\\MttVDD2".into()]));
    assert!(!is_mttvdd_hardware_id(&["PCI\\VEN_10DE&DEV_2206".into()]));
    assert!(!is_mttvdd_hardware_id(&[]));
}
#[test] fn one_repair_per_minute() {
    let t = Instant::now(); let mut l = RepairLimiter::new();
    assert!(l.may_repair(t)); l.record_attempt(t);
    assert!(!l.may_repair(t + Duration::from_secs(59)));
    assert!(l.may_repair(t + Duration::from_secs(60)));
}
#[test] fn backs_off_after_three_failed_repairs_and_recovers() {
    let mut t = Instant::now(); let mut l = RepairLimiter::new();
    let mut entered = vec![];
    for _ in 0..3 { l.record_attempt(t); entered.push(l.observe(true)); t += Duration::from_secs(60); }
    assert_eq!(entered, vec![false, false, true]); assert!(l.in_backoff());
    let last = t - Duration::from_secs(60);
    assert!(!l.may_repair(last + Duration::from_secs(599)));
    assert!(l.may_repair(last + Duration::from_secs(600)));
    assert!(!l.observe(false)); assert!(!l.in_backoff());
}
#[test] fn failure_without_attempt_does_not_count() {
    let mut l = RepairLimiter::new();
    for _ in 0..5 { assert!(!l.observe(true)); }
    assert!(!l.in_backoff());
}
#[tokio::test] async fn wait_until_returns_when_screen_appears_or_times_out() {
    let mut n = 0;
    assert!(wait_until(|| { n += 1; n >= 3 }, Duration::from_millis(500), Duration::from_millis(10)).await);
    assert!(!wait_until(|| false, Duration::from_millis(50), Duration::from_millis(10)).await);
}
```

- [ ] **Step 2: Run** `<recipe> headless_vdd` — expected: compile failure (items not defined).
- [ ] **Step 3: Implement the items above** in `src/headless_vdd.rs`. `wait_until` checks first, then sleeps `step` with `tokio::time::sleep` until `timeout` elapses, checking once more at the end.
- [ ] **Step 4: Run** `<recipe> headless_vdd` — expected: 6 passed.
- [ ] **Step 5: No commit** (tree is uncommitted by the user's rule); snapshot the diff into the workspace instead.

### Task 2: Windows device layer and repair entry points

**Files:**
- Modify: `src/headless_vdd.rs` (add `#[cfg(windows)]` section)

**Interfaces:**
- Consumes: Task 1 items.
- Produces:
  - `#[cfg(windows)] pub struct VddNode { pub instance_id: String, pub problem_code: u32 }`
  - `#[cfg(windows)] pub fn find_mttvdd() -> Vec<VddNode>` — `SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, null, null, DIGCF_PRESENT)`, `SPDRP_HARDWAREID` (REG_MULTI_SZ → `Vec<String>`), `is_mttvdd_hardware_id`, `CM_Get_DevNode_Status`, `SetupDiGetDeviceInstanceIdW`; destroy the info list on every path. Errors are logged at `debug` and yield an empty list.
  - `#[cfg(windows)] pub fn any_needs_repair() -> bool`
  - `#[cfg(windows)] pub fn repair_if_allowed(reason: &str) -> bool` — locks a `static LIMITER: Mutex<RepairLimiter>` (poisoned lock: recover with `into_inner`), calls `observe` with the current state (logging the back-off warn when it returns true), returns false unless a node needs repair and `may_repair(now)`; then `record_attempt(now)`, runs `pnputil.exe /restart-device <instance_id>` for each node needing repair (full path `%SystemRoot%\System32\pnputil.exe`, `CREATE_NO_WINDOW`), logs one `info` line with `reason`, instance ID and exit status, returns true if a restart was issued.
  - `#[cfg(windows)] fn run_with_timeout(cmd: std::process::Command, timeout: Duration) -> std::io::Result<Option<std::process::ExitStatus>>` — spawn, poll `try_wait` every 100 ms, kill and return `Ok(None)` at timeout (30 s for pnputil).

- [ ] **Step 1: Write the failing test** for the timeout helper (Windows only):

```rust
#[cfg(windows)] #[test] fn run_with_timeout_kills_a_hung_process() {
    let mut c = std::process::Command::new("cmd"); c.args(["/C", "ping -n 30 127.0.0.1 >NUL"]);
    let t = Instant::now();
    assert_eq!(run_with_timeout(c, Duration::from_millis(300)).unwrap(), None);
    assert!(t.elapsed() < Duration::from_secs(5));
}
#[cfg(windows)] #[test] #[ignore] fn find_mttvdd_lists_atlas_driver() {
    // Manual on atlas: expects one node with a ROOT\DISPLAY\ instance id.
    let n = find_mttvdd(); assert_eq!(n.len(), 1); assert!(n[0].instance_id.to_ascii_uppercase().starts_with("ROOT\\DISPLAY\\"));
}
```

- [ ] **Step 2: Run** `<recipe> headless_vdd` — expected: compile failure.
- [ ] **Step 3: Implement** the items above. Reuse the SetupAPI pattern from `src/virtual_display_manager.rs` `windows::get_display_drivers` (do not modify that function).
- [ ] **Step 4: Run** `<recipe> headless_vdd` — expected: 7 passed, 1 ignored. Then run the ignored test once on atlas: `<recipe> find_mttvdd_lists_atlas_driver -- --ignored` — expected: pass (read-only).
- [ ] **Step 5: Snapshot the diff** (no commit).

### Task 3: Wire into the watchdog and the login path

**Files:**
- Modify: `src/server/emulator/host_management.rs` (watchdog loop in `ensure_watchdog_started`, after `probe_watchdog(true)`)
- Modify: `src/server/display_service.rs` (`update_get_sync_displays_on_login`, Windows branch)

**Interfaces:**
- Consumes: `crate::headless_vdd::{repair_if_allowed, any_needs_repair, wait_until, LOGIN_WAIT, LOGIN_POLL}`.

- [ ] **Step 1: Watchdog:** in the loop, `#[cfg(windows)] { crate::headless_vdd::repair_if_allowed("watchdog"); }` each pass (20 s interval already). Not in `probe_watchdog`, so UI health queries never trigger a restart.
- [ ] **Step 2: Login:** in `update_get_sync_displays_on_login`, Windows branch, after `try_get_displays_add_amyuni_headless()`: if the list is empty, run `spawn_blocking(|| any_needs_repair() .then(|| repair_if_allowed("login")))`; if the device needed repair (whether this call restarted it or the limiter denied because one is in progress), `wait_until(|| Display::all().map(|d| !d.is_empty()).unwrap_or(false), LOGIN_WAIT, LOGIN_POLL).await`, then recompute the list with `try_get_displays_add_amyuni_headless()`. Non-empty list: no new calls at all.
- [ ] **Step 3: Build and run focused suites:** `<recipe> headless_vdd`, `<recipe> emulator` (167 expected), `<recipe> lan` (28), `<recipe> aperture_` (14). Expected: all pass, no new warnings in touched files.
- [ ] **Step 4: Release DLL:** `cargo build --release --lib --features flutter,hwcodec,vram`; record SHA256; copy to `target/headless-vdd-20261113/artifacts/`.
- [ ] **Step 5: Session note** `docs/remote/2026-11-13-headless-screen-recovery.md`: what changed, checks, DLL hash, install and device test pending the user's go-ahead.
