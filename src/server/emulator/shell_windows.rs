//! Restarts the signed-in user's Windows Explorer shell (taskbar and desktop) on request
//! from the phone, for when Explorer keeps running but its taskbar is gone.

use hbb_common::{bail, log, sysinfo::System, ResultType};
use std::{
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};
use winapi::um::{
    processthreadsapi::ProcessIdToSessionId,
    winuser::{FindWindowW, IsWindow},
};

const SHELL_HELPER: &str = "--aperture-restart-shell";
const EXPLORER_EXIT_WAIT: Duration = Duration::from_secs(5);
const TASKBAR_WAIT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(250);

fn taskbar() -> Option<isize> {
    let class: Vec<u16> = "Shell_TrayWnd\0".encode_utf16().collect();
    let hwnd = unsafe { FindWindowW(class.as_ptr(), std::ptr::null()) };
    if hwnd.is_null() || unsafe { IsWindow(hwnd) } == 0 {
        None
    } else {
        Some(hwnd as isize)
    }
}

fn session_of(pid: u32) -> Option<u32> {
    let mut session = 0;
    (unsafe { ProcessIdToSessionId(pid, &mut session) } != 0).then_some(session)
}

fn session_explorers(system: &System, session: u32) -> Vec<u32> {
    system
        .processes()
        .iter()
        .filter(|(_, process)| process.name().eq_ignore_ascii_case("explorer.exe"))
        .map(|(pid, _)| pid.as_u32())
        .filter(|pid| session_of(*pid) == Some(session))
        .collect()
}

/// Ends this session's Explorer processes and starts a fresh shell. Runs as the signed-in user.
fn restart_in_this_session() -> ResultType<()> {
    let Some(session) = crate::platform::get_current_process_session_id() else {
        bail!("Could not tell which Windows session this is")
    };
    let mut system = System::new_all();
    for pid in session_explorers(&system, session) {
        if let Some(process) = system.process(hbb_common::sysinfo::Pid::from_u32(pid)) {
            if !process.kill() {
                log::warn!("Could not end explorer.exe {pid}");
            }
        }
    }
    let deadline = Instant::now() + EXPLORER_EXIT_WAIT;
    loop {
        system.refresh_processes();
        if session_explorers(&system, session).is_empty() {
            break;
        }
        if Instant::now() >= deadline {
            bail!("Windows Explorer did not close")
        }
        thread::sleep(POLL);
    }
    let windows = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    std::process::Command::new(PathBuf::from(windows).join("explorer.exe")).spawn()?;
    Ok(())
}

/// Host action: restart Explorer as the signed-in user and wait for a new taskbar.
pub fn restart() -> ResultType<String> {
    let before = taskbar();
    if crate::platform::is_root() {
        // Explorer must run as the user, never as SYSTEM.
        crate::platform::run_as_user(vec![SHELL_HELPER])?;
    } else {
        restart_in_this_session()?;
    }
    let deadline = Instant::now() + TASKBAR_WAIT;
    while Instant::now() < deadline {
        thread::sleep(POLL);
        if let Some(now) = taskbar() {
            if Some(now) != before {
                return Ok("Taskbar restarted".to_owned());
            }
        }
    }
    bail!("Windows Explorer was restarted, but the taskbar did not come back within 15 seconds")
}

pub fn handle_helper_args(args: &[String]) -> bool {
    if args.first().map(String::as_str) != Some(SHELL_HELPER) {
        return false;
    }
    let result = (|| -> ResultType<()> {
        if args.len() != 1 {
            bail!("Invalid taskbar restart helper arguments")
        }
        if crate::platform::is_root() {
            bail!("Taskbar restart helper requires the signed-in user")
        }
        restart_in_this_session()
    })();
    if let Err(error) = result {
        log::error!("Taskbar restart helper: {error}");
        std::process::exit(1);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_helper_only_claims_its_own_flag() {
        assert!(!handle_helper_args(&[]));
        assert!(!handle_helper_args(&["--server".to_owned()]));
        assert!(!handle_helper_args(&["--aperture-emulator-shutdown".to_owned()]));
    }
}
