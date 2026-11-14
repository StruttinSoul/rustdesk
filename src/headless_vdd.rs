//! Keeps atlas's virtual display (MikeTheTech `Root\MttVDD`) alive when it crashes while the
//! physical monitor sleeps, so a login does not get an empty display list ("No displays").

use std::time::{Duration, Instant};

pub const MTTVDD_HARDWARE_ID: &str = "Root\\MttVDD";
/// `CM_PROB_DISABLED`: the user turned the device off; never undone here.
const CM_PROB_DISABLED: u32 = 22;
pub const REPAIR_INTERVAL: Duration = Duration::from_secs(60);
pub const BACKOFF_INTERVAL: Duration = Duration::from_secs(600);
pub const BACKOFF_AFTER: u32 = 3;
pub const LOGIN_WAIT: Duration = Duration::from_secs(10);
pub const LOGIN_POLL: Duration = Duration::from_millis(500);

/// A device problem code that a restart may fix: anything but healthy (0) or user-disabled.
pub fn needs_repair(problem_code: u32) -> bool {
    problem_code != 0 && problem_code != CM_PROB_DISABLED
}

pub fn is_mttvdd_hardware_id(ids: &[String]) -> bool {
    ids.iter()
        .any(|id| id.eq_ignore_ascii_case(MTTVDD_HARDWARE_ID))
}

/// Shared by the watchdog and the login path so the driver is never restarted in a loop.
#[derive(Debug, Default)]
pub struct RepairLimiter {
    last_attempt: Option<Instant>,
    attempt_pending: bool,
    consecutive_failures: u32,
}

impl RepairLimiter {
    pub const fn new() -> Self {
        Self {
            last_attempt: None,
            attempt_pending: false,
            consecutive_failures: 0,
        }
    }

    pub fn in_backoff(&self) -> bool {
        self.consecutive_failures >= BACKOFF_AFTER
    }

    pub fn may_repair(&self, now: Instant) -> bool {
        let interval = if self.in_backoff() {
            BACKOFF_INTERVAL
        } else {
            REPAIR_INTERVAL
        };
        match self.last_attempt {
            None => true,
            Some(last) => now.saturating_duration_since(last) >= interval,
        }
    }

    pub fn attempted_within(&self, now: Instant, window: Duration) -> bool {
        self.last_attempt
            .map_or(false, |last| now.saturating_duration_since(last) < window)
    }

    pub fn record_attempt(&mut self, now: Instant) {
        self.last_attempt = Some(now);
        self.attempt_pending = true;
    }

    /// Records the device state seen at a check. Returns true exactly when this observation
    /// enters back-off, so the caller logs one warning.
    pub fn observe(&mut self, needs_repair: bool) -> bool {
        let was_backoff = self.in_backoff();
        if self.attempt_pending {
            self.attempt_pending = false;
            if needs_repair {
                self.consecutive_failures = self.consecutive_failures.saturating_add(1);
            } else {
                self.consecutive_failures = 0;
            }
        } else if !needs_repair {
            self.consecutive_failures = 0;
        }
        !was_backoff && self.in_backoff()
    }
}

/// What a repair request did; a login waits for a screen only while a repair is live.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepairOutcome {
    /// No `Root\MttVDD` node needs repair and none was restarted recently.
    NotNeeded,
    /// A restart was issued by this call.
    Issued,
    /// Another caller holds the limiter and is restarting the driver now.
    InProgress,
    /// Nothing needs repair now, but a restart finished within `LOGIN_WAIT`:
    /// the screen may still be coming up.
    Recent,
    /// The device needs repair but the limiter (interval or back-off) refused.
    Denied,
}

pub fn login_should_wait(outcome: RepairOutcome) -> bool {
    matches!(
        outcome,
        RepairOutcome::Issued | RepairOutcome::InProgress | RepairOutcome::Recent
    )
}

/// Checks `has_screen` now and every `step` until it is true or `timeout` has passed.
pub async fn wait_until(
    mut has_screen: impl FnMut() -> bool,
    timeout: Duration,
    step: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if has_screen() {
            return true;
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        hbb_common::tokio::time::sleep(step.min(deadline - now)).await;
    }
}

#[cfg(windows)]
pub use self::win::{find_mttvdd, repair_if_allowed, VddNode};

#[cfg(windows)]
mod win {
    use super::{
        is_mttvdd_hardware_id, needs_repair, RepairLimiter, RepairOutcome, BACKOFF_AFTER,
        BACKOFF_INTERVAL, LOGIN_WAIT,
    };
    use hbb_common::log;
    use std::{
        os::windows::process::CommandExt,
        path::PathBuf,
        process::{Command, ExitStatus, Stdio},
        ptr::null_mut,
        sync::{Mutex, TryLockError},
        time::{Duration, Instant},
    };
    use winapi::{
        shared::{devguid::GUID_DEVCLASS_DISPLAY, winerror::ERROR_INSUFFICIENT_BUFFER},
        um::{
            cfgmgr32::{CM_Get_DevNode_Status, CR_SUCCESS},
            errhandlingapi::GetLastError,
            handleapi::INVALID_HANDLE_VALUE,
            setupapi::{
                SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInfo, SetupDiGetClassDevsW,
                SetupDiGetDeviceInstanceIdW, SetupDiGetDeviceRegistryPropertyW, DIGCF_PRESENT,
                HDEVINFO, SPDRP_HARDWAREID, SP_DEVINFO_DATA,
            },
        },
    };

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const PNPUTIL_TIMEOUT: Duration = Duration::from_secs(30);

    /// Held for the whole repair, so a second caller sees a repair in progress and backs off.
    static LIMITER: Mutex<RepairLimiter> = Mutex::new(RepairLimiter::new());

    #[derive(Debug, Clone)]
    pub struct VddNode {
        pub instance_id: String,
        pub problem_code: u32,
    }

    /// Present display-class devices whose hardware ID is exactly `Root\MttVDD`.
    pub fn find_mttvdd() -> Vec<VddNode> {
        let set = unsafe {
            SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, null_mut(), null_mut(), DIGCF_PRESENT)
        };
        if set == INVALID_HANDLE_VALUE {
            log::debug!(
                "headless display: SetupDiGetClassDevsW failed: {}",
                std::io::Error::last_os_error()
            );
            return Vec::new();
        }
        let mut nodes = Vec::new();
        let mut index = 0;
        loop {
            let mut data: SP_DEVINFO_DATA = unsafe { std::mem::zeroed() };
            data.cbSize = std::mem::size_of::<SP_DEVINFO_DATA>() as u32;
            if unsafe { SetupDiEnumDeviceInfo(set, index, &mut data) } == 0 {
                break;
            }
            index += 1;
            if !is_mttvdd_hardware_id(&hardware_ids(set, &mut data)) {
                continue;
            }
            let Some(instance_id) = instance_id(set, &mut data) else {
                continue;
            };
            let (mut status, mut problem) = (0u32, 0u32);
            if unsafe { CM_Get_DevNode_Status(&mut status, &mut problem, data.DevInst, 0) }
                != CR_SUCCESS
            {
                log::debug!("headless display: no status for {instance_id}");
                continue;
            }
            nodes.push(VddNode {
                instance_id,
                problem_code: problem,
            });
        }
        unsafe { SetupDiDestroyDeviceInfoList(set) };
        nodes
    }

    fn hardware_ids(set: HDEVINFO, data: &mut SP_DEVINFO_DATA) -> Vec<String> {
        let mut buf = vec![0u16; 512];
        for _ in 0..2 {
            let mut required = 0u32;
            let ok = unsafe {
                SetupDiGetDeviceRegistryPropertyW(
                    set,
                    data,
                    SPDRP_HARDWAREID,
                    null_mut(),
                    buf.as_mut_ptr() as *mut u8,
                    (buf.len() * 2) as u32,
                    &mut required,
                )
            };
            if ok != 0 {
                // REG_MULTI_SZ: NUL-separated strings ending in an empty one.
                return String::from_utf16_lossy(&buf)
                    .split('\0')
                    .take_while(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect();
            }
            if unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
                break;
            }
            buf = vec![0u16; (required as usize + 1) / 2 + 1];
        }
        Vec::new()
    }

    fn instance_id(set: HDEVINFO, data: &mut SP_DEVINFO_DATA) -> Option<String> {
        let mut buf = [0u16; 512];
        let ok = unsafe {
            SetupDiGetDeviceInstanceIdW(
                set,
                data,
                buf.as_mut_ptr(),
                buf.len() as u32,
                null_mut(),
            )
        };
        if ok == 0 {
            return None;
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..len]))
    }

    /// Restarts every failed `Root\MttVDD` node when the shared limiter allows it. Blocking:
    /// call from the watchdog thread or `spawn_blocking`.
    pub fn repair_if_allowed(reason: &str) -> RepairOutcome {
        let mut limiter = match LIMITER.try_lock() {
            Ok(guard) => guard,
            Err(TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(TryLockError::WouldBlock) => return RepairOutcome::InProgress,
        };
        let broken: Vec<VddNode> = find_mttvdd()
            .into_iter()
            .filter(|n| needs_repair(n.problem_code))
            .collect();
        if limiter.observe(!broken.is_empty()) {
            log::warn!(
                "headless display: MttVDD still failed after {BACKOFF_AFTER} restarts; retrying every {} s",
                BACKOFF_INTERVAL.as_secs()
            );
        }
        let now = Instant::now();
        if broken.is_empty() {
            return if limiter.attempted_within(now, LOGIN_WAIT) {
                RepairOutcome::Recent
            } else {
                RepairOutcome::NotNeeded
            };
        }
        if !limiter.may_repair(now) {
            return RepairOutcome::Denied;
        }
        limiter.record_attempt(now);
        for node in &broken {
            restart(node, reason);
        }
        RepairOutcome::Issued
    }

    fn restart(node: &VddNode, reason: &str) {
        let pnputil = std::env::var_os("SystemRoot")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
            .join("System32")
            .join("pnputil.exe");
        let mut cmd = Command::new(pnputil);
        cmd.args(["/restart-device", node.instance_id.as_str()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        let id = &node.instance_id;
        let problem = node.problem_code;
        match run_with_timeout(cmd, PNPUTIL_TIMEOUT) {
            Ok(Some(status)) => log::info!(
                "headless display: restarted {id} (problem {problem}, {reason}): pnputil {status}"
            ),
            Ok(None) => log::info!(
                "headless display: restart of {id} (problem {problem}, {reason}) timed out after {} s",
                PNPUTIL_TIMEOUT.as_secs()
            ),
            Err(err) => log::info!(
                "headless display: could not run pnputil for {id} (problem {problem}, {reason}): {err}"
            ),
        }
    }

    /// Runs `cmd`, killing it at `timeout`. `Ok(None)` means it timed out.
    pub(super) fn run_with_timeout(
        mut cmd: Command,
        timeout: Duration,
    ) -> std::io::Result<Option<ExitStatus>> {
        let mut child = cmd.spawn()?;
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(Some(status));
            }
            if Instant::now() >= deadline {
                if let Err(err) = child.kill() {
                    log::debug!("headless display: kill after timeout failed: {err}");
                }
                // Reap it; the exit status of a killed process carries nothing useful.
                child.wait()?;
                return Ok(None);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    use super::win::run_with_timeout;
    use std::time::{Duration, Instant};

    #[test]
    fn healthy_and_disabled_are_not_repaired() {
        assert!(!needs_repair(0));
        assert!(!needs_repair(22));
        assert!(needs_repair(43));
        assert!(needs_repair(10));
    }

    #[test]
    fn hardware_id_match_is_exact_and_case_insensitive() {
        assert!(is_mttvdd_hardware_id(&["ROOT\\MTTVDD".into()]));
        assert!(is_mttvdd_hardware_id(&[
            "PCI\\X".into(),
            "Root\\MttVDD".into()
        ]));
        assert!(!is_mttvdd_hardware_id(&["Root\\MttVDD2".into()]));
        assert!(!is_mttvdd_hardware_id(&["PCI\\VEN_10DE&DEV_2206".into()]));
        assert!(!is_mttvdd_hardware_id(&[]));
    }

    #[test]
    fn one_repair_per_minute() {
        let t = Instant::now();
        let mut l = RepairLimiter::new();
        assert!(l.may_repair(t));
        l.record_attempt(t);
        assert!(!l.may_repair(t + Duration::from_secs(59)));
        assert!(l.may_repair(t + Duration::from_secs(60)));
    }

    #[test]
    fn backs_off_after_three_failed_repairs_and_recovers() {
        let mut t = Instant::now();
        let mut l = RepairLimiter::new();
        let mut entered = vec![];
        for _ in 0..3 {
            l.record_attempt(t);
            entered.push(l.observe(true));
            t += Duration::from_secs(60);
        }
        assert_eq!(entered, vec![false, false, true]);
        assert!(l.in_backoff());
        let last = t - Duration::from_secs(60);
        assert!(!l.may_repair(last + Duration::from_secs(599)));
        assert!(l.may_repair(last + Duration::from_secs(600)));
        assert!(!l.observe(false));
        assert!(!l.in_backoff());
    }

    #[test]
    fn failure_without_attempt_does_not_count() {
        let mut l = RepairLimiter::new();
        for _ in 0..5 {
            assert!(!l.observe(true));
        }
        assert!(!l.in_backoff());
    }

    #[tokio::test]
    async fn wait_until_returns_when_screen_appears_or_times_out() {
        let mut n = 0;
        assert!(
            wait_until(
                || {
                    n += 1;
                    n >= 3
                },
                Duration::from_millis(500),
                Duration::from_millis(10)
            )
            .await
        );
        assert!(!wait_until(|| false, Duration::from_millis(50), Duration::from_millis(10)).await);
    }

    #[test]
    fn login_waits_only_for_live_repairs() {
        assert!(login_should_wait(RepairOutcome::Issued));
        assert!(login_should_wait(RepairOutcome::InProgress));
        assert!(login_should_wait(RepairOutcome::Recent));
        assert!(!login_should_wait(RepairOutcome::NotNeeded));
        assert!(!login_should_wait(RepairOutcome::Denied));
    }

    #[test]
    fn recent_attempt_window() {
        let t = Instant::now();
        let mut l = RepairLimiter::new();
        assert!(!l.attempted_within(t, LOGIN_WAIT));
        l.record_attempt(t);
        assert!(l.attempted_within(t + Duration::from_secs(9), LOGIN_WAIT));
        assert!(!l.attempted_within(t + Duration::from_secs(11), LOGIN_WAIT));
    }

    #[cfg(windows)]
    #[test]
    fn run_with_timeout_kills_a_hung_process() {
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "ping -n 30 127.0.0.1 >NUL"]);
        let t = Instant::now();
        assert_eq!(run_with_timeout(c, Duration::from_millis(300)).unwrap(), None);
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[cfg(windows)]
    #[test]
    #[ignore]
    fn find_mttvdd_lists_atlas_driver() {
        // Manual on atlas (read-only): expects one node with a ROOT\DISPLAY\ instance id.
        let n = find_mttvdd();
        assert_eq!(n.len(), 1);
        assert!(n[0]
            .instance_id
            .to_ascii_uppercase()
            .starts_with("ROOT\\DISPLAY\\"));
    }
}
