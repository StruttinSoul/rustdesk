//! Runs Aperture's Android emulators in the signed-in user's Windows session
//! and shows or hides their windows on the PC.
//!
//! The host service runs as SYSTEM, so it starts this executable as the user
//! with a helper flag. The helper starts the emulator with a normal window and
//! hides that window as soon as it appears: an emulator started without a
//! window (`-no-window`) could never be shown later.

use super::{
    avd::{launched_avd, QEMU_PROCESS},
    avd_files::{valid_avd_name, AvdHome},
};
use hbb_common::{bail, log, sysinfo::System, ResultType};
use std::{
    collections::{BTreeMap, BTreeSet},
    os::windows::{ffi::OsStrExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
};
use winapi::{
    shared::{
        minwindef::{BOOL, LPARAM, TRUE},
        windef::HWND,
    },
    um::winuser::{
        EnumWindows, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic,
        IsWindowVisible, SetForegroundWindow, ShowWindow, SW_HIDE, SW_RESTORE, SW_SHOW,
    },
};
use windows::{core::PCWSTR, Win32::Storage::FileSystem::GetDiskFreeSpaceExW};

pub const AVD_START_HELPER: &str = "--aperture-avd-start";
pub const AVD_WINDOW_HELPER: &str = "--aperture-avd-window";
const SIGN_IN: &str = "Sign in to Windows on atlas to start emulators";
const MAIN_TITLE_PREFIX: &str = "Android Emulator - ";
/// The emulator's tool bar, a second top-level window of the same process.
const TOOLBAR_TITLE: &str = "Emulator";
const WINDOW_WAIT: Duration = Duration::from_secs(60);
/// After the main window, keep hiding late windows (the tool bar) this long.
const LATE_WINDOW_WAIT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(250);
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

fn window_states() -> &'static Mutex<BTreeMap<String, bool>> {
    static STATES: OnceLock<Mutex<BTreeMap<String, bool>>> = OnceLock::new();
    STATES.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn remember_window(name: &str, visible: bool) {
    // A plain map: a panicking holder leaves nothing half-updated.
    let mut states = window_states()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if visible {
        states.insert(name.to_owned(), true);
    } else {
        states.remove(name);
    }
}

/// Whether the emulator's window was last shown on the PC; hidden after start.
pub fn window_visible(name: &str) -> bool {
    window_states()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(name)
        .copied()
        .unwrap_or(false)
}

/// Windows' available physical memory in MB.
pub(super) fn available_memory_mb() -> u64 {
    let mut system = System::new();
    system.refresh_memory();
    system.available_memory() / (1024 * 1024)
}

/// Free bytes for this user on the drive of `path` (or of its nearest
/// existing parent, for a folder not created yet).
pub(super) fn free_disk_bytes(path: &Path) -> ResultType<u64> {
    let Some(existing) = path.ancestors().find(|ancestor| ancestor.exists()) else {
        bail!("{} is not on an available drive", path.display())
    };
    let wide: Vec<u16> = existing
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let mut free = 0u64;
    unsafe { GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut free), None, None) }?;
    Ok(free)
}

fn helper_error(action: &str, error: hbb_common::anyhow::Error) -> hbb_common::anyhow::Error {
    // run_as_user fails with "no process explorer.exe" when nobody is signed in.
    if error.to_string().contains("no process") {
        hbb_common::anyhow::anyhow!(SIGN_IN)
    } else {
        hbb_common::anyhow::anyhow!("Could not {action} in the signed-in user's session: {error}")
    }
}

/// Runs this executable with helper `args` as the signed-in user. Without
/// SYSTEM rights (a manual run) this process already is the user.
fn run_helper(action: &str, args: &[&str]) -> ResultType<()> {
    if crate::platform::is_root() {
        if crate::platform::get_active_user_home().is_none() {
            bail!(SIGN_IN)
        }
        // run_as_user joins arguments with spaces, unquoted.
        let quoted: Vec<String> = args
            .iter()
            .map(|arg| {
                if arg.contains(' ') {
                    format!("\"{arg}\"")
                } else {
                    arg.to_string()
                }
            })
            .collect();
        crate::platform::run_as_user(quoted.iter().map(String::as_str).collect())
            .map_err(|error| helper_error(action, error))?;
    } else {
        Command::new(std::env::current_exe()?)
            .args(args)
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
    }
    Ok(())
}

/// Starts `name` from Aperture's emulator folder in the signed-in user's
/// session; the helper hides its window once it appears.
pub fn launch_in_user_session(name: &str) -> ResultType<()> {
    if !valid_avd_name(name) {
        bail!("Invalid emulator name")
    }
    let root = AvdHome::default_root();
    let Some(root_arg) = root.to_str().filter(|root| !root.contains('"')) else {
        bail!("The emulator folder path is not supported: {}", root.display())
    };
    if crate::platform::is_root() {
        let Some(home) = crate::platform::get_active_user_home() else {
            bail!(SIGN_IN)
        };
        let sdk = home.join(r"AppData\Local\Android\Sdk");
        if !sdk.join(r"emulator\emulator.exe").is_file() {
            bail!(
                "The Android Emulator is not installed for the signed-in Windows user ({})",
                sdk.display()
            )
        }
    }
    run_helper(&format!("start {name}"), &[AVD_START_HELPER, name, root_arg])?;
    remember_window(name, false);
    Ok(())
}

/// Shows (and brings to the front) or hides `name`'s window on the PC.
pub fn set_window_visible(name: &str, visible: bool) -> ResultType<()> {
    if !valid_avd_name(name) {
        bail!("Invalid emulator name")
    }
    let (action, arg) = if visible {
        (format!("show {name}"), "show")
    } else {
        (format!("hide {name}"), "hide")
    };
    if crate::platform::is_root() {
        run_helper(&action, &[AVD_WINDOW_HELPER, name, arg])?;
    } else {
        set_windows_here(name, visible)?;
    }
    remember_window(name, visible);
    Ok(())
}

fn parse_start_args(args: &[String]) -> ResultType<(&str, PathBuf)> {
    let [name, root] = args else {
        bail!("Invalid emulator start helper arguments")
    };
    if !valid_avd_name(name) {
        bail!("Invalid emulator name")
    }
    let root = PathBuf::from(root);
    if !root.is_absolute() {
        bail!("The emulator folder must be an absolute path")
    }
    Ok((name.as_str(), root))
}

fn parse_window_args(args: &[String]) -> ResultType<(&str, bool)> {
    let [name, action] = args else {
        bail!("Invalid emulator window helper arguments")
    };
    if !valid_avd_name(name) {
        bail!("Invalid emulator name")
    }
    match action.as_str() {
        "show" => Ok((name.as_str(), true)),
        "hide" => Ok((name.as_str(), false)),
        _ => bail!("Emulator window action must be show or hide"),
    }
}

/// Handles `--aperture-avd-start <name> <root>` and
/// `--aperture-avd-window <name> show|hide`, run as the signed-in user.
pub fn handle_helper_args(args: &[String]) -> bool {
    let result = match args.first().map(String::as_str) {
        Some(AVD_START_HELPER) => in_user_session()
            .and_then(|_| parse_start_args(&args[1..]))
            .and_then(|(name, root)| start_here(name, &root)),
        Some(AVD_WINDOW_HELPER) => in_user_session()
            .and_then(|_| parse_window_args(&args[1..]))
            .and_then(|(name, visible)| set_windows_here(name, visible)),
        _ => return false,
    };
    if let Err(error) = result {
        log::error!("Android Emulator helper: {error}");
        std::process::exit(1);
    }
    true
}

fn in_user_session() -> ResultType<()> {
    if crate::platform::is_root() {
        bail!("The Android Emulator helper must run as the signed-in user")
    }
    Ok(())
}

/// The user's SDK, the one Android Studio installs.
fn user_sdk() -> ResultType<PathBuf> {
    let Some(local) = std::env::var_os("LOCALAPPDATA") else {
        bail!("LOCALAPPDATA is not set")
    };
    Ok(PathBuf::from(local).join("Android").join("Sdk"))
}

fn start_here(name: &str, root: &Path) -> ResultType<()> {
    let sdk = user_sdk()?;
    let emulator = sdk.join("emulator").join("emulator.exe");
    if !emulator.is_file() {
        bail!("The Android Emulator is not installed in {}", sdk.display())
    }
    // Emulators register with the default ADB server, which the host uses.
    let adb = sdk.join("platform-tools").join("adb.exe");
    match Command::new(&adb)
        .arg("start-server")
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .and_then(|child| wait_or_kill(child, START_SERVER_WAIT))
    {
        Ok(status) if status.success() => {}
        Ok(status) => log::warn!("adb start-server exited with {status}"),
        Err(error) => log::warn!("Could not run {}: {error}", adb.display()),
    }
    let mut child = Command::new(&emulator)
        .args(["-avd", name, "-no-audio"])
        .env("ANDROID_AVD_HOME", root)
        .env("ANDROID_SDK_ROOT", &sdk)
        .current_dir(sdk.join("emulator"))
        .creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    log::info!("Started the Android Emulator for {name}");
    hide_new_windows(name, &mut child)
}

/// `adb start-server` replies within seconds; a stuck ADB server must not
/// hold the emulator's start.
const START_SERVER_WAIT: Duration = Duration::from_secs(10);

/// Waits up to `limit` for `child` to exit, killing it after that.
fn wait_or_kill(mut child: Child, limit: Duration) -> std::io::Result<std::process::ExitStatus> {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if started.elapsed() >= limit {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("no reply within {} s", limit.as_secs()),
            ));
        }
        thread::sleep(Duration::from_millis(50));
    }
}

/// Hides the emulator's windows as they appear: the main window, then for a
/// few seconds any late one such as the tool bar.
fn hide_new_windows(name: &str, child: &mut Child) -> ResultType<()> {
    let deadline = Instant::now() + WINDOW_WAIT;
    let mut main_seen: Option<Instant> = None;
    loop {
        let windows = emulator_windows(name)?;
        for (hwnd, _) in &windows {
            let hwnd = *hwnd as HWND;
            if unsafe { IsWindowVisible(hwnd) } != 0 {
                unsafe { ShowWindow(hwnd, SW_HIDE) };
            }
        }
        if main_seen.is_none() && windows.iter().any(|(_, title)| is_main_window(title, name)) {
            main_seen = Some(Instant::now());
        }
        match main_seen {
            Some(seen) if seen.elapsed() >= LATE_WINDOW_WAIT => {
                log::info!("Hid the Android Emulator window of {name}");
                return Ok(());
            }
            Some(_) => {}
            None => {
                if let Some(status) = child.try_wait()? {
                    if !status.success() {
                        bail!("The Android Emulator for {name} exited at start ({status})")
                    }
                }
                if Instant::now() >= deadline {
                    bail!("{name} showed no window within 60 seconds to hide")
                }
            }
        }
        thread::sleep(POLL);
    }
}

fn set_windows_here(name: &str, visible: bool) -> ResultType<()> {
    let windows = emulator_windows(name)?;
    if windows.is_empty() {
        bail!("{name} has no window on the PC")
    }
    for (hwnd, _) in &windows {
        let hwnd = *hwnd as HWND;
        unsafe {
            if visible {
                ShowWindow(hwnd, SW_SHOW);
                if IsIconic(hwnd) != 0 {
                    ShowWindow(hwnd, SW_RESTORE);
                }
            } else {
                ShowWindow(hwnd, SW_HIDE);
            }
        }
    }
    if visible {
        if let Some((hwnd, _)) = windows.iter().find(|(_, title)| is_main_window(title, name)) {
            // Windows may refuse the focus change; the window is shown either way.
            if unsafe { SetForegroundWindow(*hwnd as HWND) } == 0 {
                log::info!("Windows kept another window in front of {name}");
            }
        }
    }
    Ok(())
}

/// `Android Emulator - <name>:<port>`.
fn is_main_window(title: &str, name: &str) -> bool {
    title
        .strip_prefix(MAIN_TITLE_PREFIX)
        .and_then(|rest| rest.strip_prefix(name))
        .map_or(false, |rest| rest.starts_with(':'))
}

/// A top-level window of `name`'s emulator process that Aperture hides or shows.
fn is_emulator_window(title: &str, name: &str) -> bool {
    title == TOOLBAR_TITLE || is_main_window(title, name)
}

struct WindowSearch {
    pids: BTreeSet<u32>,
    windows: Vec<(isize, String)>,
}

unsafe extern "system" fn collect_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let search = &mut *(lparam as *mut WindowSearch);
    let mut pid = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if search.pids.contains(&pid) {
        let length = GetWindowTextLengthW(hwnd).max(0) as usize;
        let mut title = vec![0u16; length + 1];
        let copied = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32).max(0) as usize;
        search
            .windows
            .push((hwnd as isize, String::from_utf16_lossy(&title[..copied.min(length)])));
    }
    TRUE
}

/// The top-level windows, hidden or not, of the emulator process running `name`.
fn emulator_windows(name: &str) -> ResultType<Vec<(isize, String)>> {
    let mut system = System::new();
    system.refresh_processes();
    let pids: BTreeSet<u32> = system
        .processes()
        .iter()
        .filter(|(_, process)| {
            launched_avd(process.name(), process.cmd()).as_deref() == Some(name)
        })
        .map(|(pid, _)| pid.as_u32())
        .collect();
    if pids.is_empty() {
        return Ok(Vec::new());
    }
    let mut search = WindowSearch {
        pids,
        windows: Vec::new(),
    };
    if unsafe { EnumWindows(Some(collect_window), &mut search as *mut WindowSearch as LPARAM) }
        == 0
    {
        bail!("Windows could not list the {QEMU_PROCESS} windows of {name}")
    }
    search
        .windows
        .retain(|(_, title)| is_emulator_window(title, name));
    Ok(search.windows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stuck_adb_start_server_is_killed_at_its_limit() {
        let child = Command::new("ping")
            .args(["-n", "30", "127.0.0.1"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let started = Instant::now();
        let error = wait_or_kill(child, Duration::from_millis(300)).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
        let quick = Command::new("cmd")
            .args(["/C", "exit 0"])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .unwrap();
        assert!(wait_or_kill(quick, Duration::from_secs(10)).unwrap().success());
    }

    #[test]
    fn helpers_claim_only_their_own_flags() {
        assert!(!handle_helper_args(&[]));
        assert!(!handle_helper_args(&["--aperture-restart-shell".to_owned()]));
        assert_eq!(AVD_START_HELPER, "--aperture-avd-start");
        assert_eq!(AVD_WINDOW_HELPER, "--aperture-avd-window");
    }

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn start_helper_needs_a_valid_name_and_an_absolute_root() {
        let good = args(&["Maple_1", r"D:\Aperture\Emulators"]);
        let (name, root) = parse_start_args(&good).unwrap();
        assert_eq!(name, "Maple_1");
        assert_eq!(root, PathBuf::from(r"D:\Aperture\Emulators"));
        for bad in [
            args(&["Maple_1"]),
            args(&["../x", r"D:\Aperture\Emulators"]),
            args(&["Maple_1", r"Emulators"]),
            args(&["Maple_1", r"D:\Aperture\Emulators", "extra"]),
        ] {
            assert!(parse_start_args(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn window_helper_shows_or_hides() {
        assert_eq!(parse_window_args(&args(&["Maple_1", "show"])).unwrap(), ("Maple_1", true));
        assert_eq!(parse_window_args(&args(&["Maple_1", "hide"])).unwrap(), ("Maple_1", false));
        for bad in [args(&["Maple_1"]), args(&["Maple_1", "toggle"]), args(&["a b", "show"])] {
            assert!(parse_window_args(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn matches_only_this_emulators_windows() {
        assert!(is_emulator_window("Android Emulator - Maple_1:5554", "Maple_1"));
        assert!(is_main_window("Android Emulator - Maple_1:5554", "Maple_1"));
        assert!(is_emulator_window("Emulator", "Maple_1"));
        assert!(!is_main_window("Emulator", "Maple_1"));
        assert!(!is_emulator_window("Android Emulator - Maple_10:5556", "Maple_1"));
        assert!(!is_emulator_window("Extended controls", "Maple_1"));
    }

    #[test]
    fn windows_are_hidden_until_shown() {
        assert!(!window_visible("Never_Started_Test"));
        remember_window("Shown_Test", true);
        assert!(window_visible("Shown_Test"));
        remember_window("Shown_Test", false);
        assert!(!window_visible("Shown_Test"));
    }

    #[test]
    fn reads_free_space_of_an_existing_ancestor() {
        let missing = std::env::temp_dir().join("aperture-avd-missing").join("deeper");
        assert!(free_disk_bytes(&missing).unwrap() > 0);
    }
}
