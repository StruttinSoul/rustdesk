//! Logs when an Aperture-managed Android emulator exits without a stop from
//! Aperture (closed on the PC, ended by another program, or crashed), with
//! its exit code. Aperture's own stops log "Stopped Android Emulator".

use super::avd::launched_avd;
use hbb_common::{bail, log, ResultType};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
};

/// An exit this soon after Aperture asked for a stop is that stop.
const STOP_EXPECTED_FOR: Duration = Duration::from_secs(60);
/// How long after a launch the emulator process may take to appear.
const FIND_WAIT: Duration = Duration::from_secs(90);
const FIND_POLL: Duration = Duration::from_secs(1);
const LOG_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Debug, Default)]
struct ExitBook {
    watching: BTreeSet<String>,
    stops: BTreeMap<String, Instant>,
}

impl ExitBook {
    /// False when `name` is already watched.
    fn begin(&mut self, name: &str) -> bool {
        self.watching.insert(name.to_owned())
    }

    fn end(&mut self, name: &str) {
        self.watching.remove(name);
    }

    fn expect_stop(&mut self, name: &str, now: Instant) {
        self.stops.insert(name.to_owned(), now);
    }

    /// The warning for an exit Aperture did not ask for; None after its own stop.
    fn finish(&mut self, name: &str, exit_code: u32, now: Instant) -> Option<String> {
        self.end(name);
        let stopped = self
            .stops
            .remove(name)
            .map_or(false, |at| now.saturating_duration_since(at) <= STOP_EXPECTED_FOR);
        if stopped {
            return None;
        }
        Some(format!(
            "Android Emulator {name} exited without a stop from Aperture (exit code {exit_code:#x}): \
             closed on the PC, ended by another program, or crashed"
        ))
    }
}

fn book() -> std::sync::MutexGuard<'static, ExitBook> {
    static BOOK: OnceLock<Mutex<ExitBook>> = OnceLock::new();
    // Plain sets: a panicking holder leaves nothing half-updated.
    BOOK.get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Called before Aperture stops `name`, so its exit is not reported.
pub(super) fn expect_stop(name: &str) {
    book().expect_stop(name, Instant::now());
}

/// Watches the emulator process of `name` (running, or launched moments ago)
/// until it exits. Cheap when `name` is already watched.
pub(super) fn watch(name: &str) {
    if !book().begin(name) {
        return;
    }
    let owned = name.to_owned();
    let spawned = thread::Builder::new()
        .name("aperture-avd-exit".to_owned())
        .spawn(move || {
            let exit_code = match find_and_wait(&owned) {
                Ok(Some(code)) => code,
                Ok(None) => {
                    book().end(&owned);
                    return;
                }
                Err(error) => {
                    log::debug!("Cannot watch Android Emulator {owned}: {error}");
                    book().end(&owned);
                    return;
                }
            };
            if let Some(message) = book().finish(&owned, exit_code, Instant::now()) {
                hbb_common::throttled_log!(LOG_INTERVAL, warn, "{message}");
            }
        });
    if let Err(error) = spawned {
        book().end(name);
        log::warn!("Cannot watch Android Emulator {name}: {error}");
    }
}

/// The exit code of `name`'s emulator once it exits; None if it never ran.
fn find_and_wait(name: &str) -> ResultType<Option<u32>> {
    let deadline = Instant::now() + FIND_WAIT;
    loop {
        if let Some(pid) = emulator_pid(name) {
            return wait_exit_code(pid).map(Some);
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        thread::sleep(FIND_POLL);
    }
}

fn emulator_pid(name: &str) -> Option<u32> {
    let mut system = hbb_common::sysinfo::System::new();
    system.refresh_processes();
    system
        .processes()
        .iter()
        .find(|(_, process)| launched_avd(process.name(), process.cmd()).as_deref() == Some(name))
        .map(|(pid, _)| pid.as_u32())
}

/// Blocks until process `pid` exits and returns its exit code.
fn wait_exit_code(pid: u32) -> ResultType<u32> {
    use windows::Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0},
        System::Threading::{
            GetExitCodeProcess, OpenProcess, WaitForSingleObject, INFINITE,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
        },
    };
    // SAFETY: plain Win32 calls on a handle owned and closed here.
    let process = unsafe {
        OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
    }?;
    let result = (|| {
        if unsafe { WaitForSingleObject(process, INFINITE) } != WAIT_OBJECT_0 {
            bail!("waiting for process {pid} failed")
        }
        let mut code = 0u32;
        unsafe { GetExitCodeProcess(process, &mut code) }?;
        Ok(code)
    })();
    if let Err(error) = unsafe { CloseHandle(process) } {
        log::trace!("Emulator process handle close: {error}");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_exit_without_a_stop_is_reported_with_its_code() {
        let mut book = ExitBook::default();
        assert!(book.begin("Maple_1"));
        let message = book.finish("Maple_1", 0xC000_0005, Instant::now()).unwrap();
        assert!(message.contains("Maple_1"), "{message}");
        assert!(message.contains("0xc0000005"), "{message}");
        assert!(book.begin("Maple_1"), "a finished watch can start again");
    }

    #[test]
    fn apertures_own_stop_is_not_reported() {
        let mut book = ExitBook::default();
        let now = Instant::now();
        assert!(book.begin("Maple_1"));
        book.expect_stop("Maple_1", now);
        assert_eq!(book.finish("Maple_1", 0, now + Duration::from_secs(5)), None);
        // The expectation is used up by that exit.
        assert!(book.begin("Maple_1"));
        assert!(book.finish("Maple_1", 0, now + Duration::from_secs(6)).is_some());
    }

    #[test]
    fn a_stop_that_did_not_end_the_emulator_expires() {
        let mut book = ExitBook::default();
        let now = Instant::now();
        book.expect_stop("Maple_1", now);
        let later = now + STOP_EXPECTED_FOR + Duration::from_secs(1);
        assert!(book.finish("Maple_1", 0, later).is_some());
    }

    #[test]
    fn each_emulator_is_watched_once_at_a_time() {
        let mut book = ExitBook::default();
        assert!(book.begin("Maple_1"));
        assert!(!book.begin("Maple_1"));
        assert!(book.begin("Maple_2"));
        book.end("Maple_1");
        assert!(book.begin("Maple_1"));
    }

    /// A stand-in emulator: `cmd.exe` copied as `qemu-system-x86_64.exe`,
    /// started with `-avd <name>`, exiting with 5 after about two seconds.
    #[test]
    fn finds_an_emulator_process_by_avd_name_and_reads_its_exit_code() {
        let dir = std::env::temp_dir().join(format!("aperture-exit-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fake = dir.join(super::super::avd::QEMU_PROCESS);
        let system = std::env::var_os("SystemRoot").unwrap();
        std::fs::copy(std::path::Path::new(&system).join(r"System32\cmd.exe"), &fake).unwrap();
        let name = format!("Exit_Watch_Test_{}", std::process::id());
        let mut child = std::process::Command::new(&fake)
            .args(["/D", "/C", "ping -n 3 127.0.0.1 >nul & exit 5", "-avd", &name])
            .spawn()
            .unwrap();
        assert_eq!(find_and_wait(&name).unwrap(), Some(5));
        child.wait().unwrap();
        assert_eq!(emulator_pid(&name), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn reads_the_exit_code_of_a_process() {
        let mut child = std::process::Command::new("cmd")
            .args(["/C", "exit 7"])
            .spawn()
            .unwrap();
        assert_eq!(wait_exit_code(child.id()).unwrap(), 7);
        child.wait().unwrap();
    }
}
