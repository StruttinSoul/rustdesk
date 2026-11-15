//! Instance-scoped, non-forcing Windows shutdown. Guest capture is not blocked.
use super::{avd::AvdProvider, bluestacks::BlueStacksProvider, EmulatorProvider, EmulatorState};
use base::message_proto::EmulatorInstance;
use hbb_common::{bail, log, ResultType};
use std::{
    collections::BTreeMap,
    path::Path,
    sync::{Arc, Mutex, OnceLock},
    thread,
    time::Instant,
};
use winapi::{
    shared::{
        iprtrmib::TCP_TABLE_OWNER_PID_LISTENER,
        minwindef::{BOOL, DWORD, FILETIME},
        ntdef::HANDLE,
        tcpmib::MIB_TCPROW_OWNER_PID,
        ws2def::AF_INET,
    },
    um::{
        iphlpapi::GetExtendedTcpTable,
        winnt::{PROCESS_QUERY_LIMITED_INFORMATION, SYNCHRONIZE},
    },
};

use windows::{
    core::BSTR,
    Win32::{
        Foundation::{LPARAM, WPARAM},
        System::{
            Com::{
                CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
                COINIT_MULTITHREADED,
            },
            Variant::VARIANT,
        },
        UI::{
            Accessibility::{
                CUIAutomation, IUIAutomation, IUIAutomationInvokePattern,
                IUIAutomationLegacyIAccessiblePattern, TreeScope_Children, TreeScope_Descendants,
                UIA_ButtonControlTypeId, UIA_ControlTypePropertyId, UIA_InvokePatternId,
                UIA_LegacyIAccessiblePatternId, UIA_NamePropertyId, UIA_ProcessIdPropertyId,
            },
            WindowsAndMessaging::{PostMessageW, WM_CLOSE},
        },
    },
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    pid: u32,
    created: u64,
}
#[derive(Clone)]
enum State {
    Pending,
    Done,
    Failed(String),
}
struct Job {
    state: State,
    updated: Instant,
}
static JOBS: OnceLock<Mutex<BTreeMap<String, Arc<Mutex<Job>>>>> = OnceLock::new();
fn jobs() -> &'static Mutex<BTreeMap<String, Arc<Mutex<Job>>>> {
    JOBS.get_or_init(Default::default)
}

/// Stops a managed Android emulator through its provider (blocking).
fn stop_avd(target: &str, name: &str) -> ResultType<String> {
    let provider = AvdProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Aperture's emulator folder does not exist"))?;
    let instance = provider
        .discover()?
        .into_iter()
        .find(|item| item.stable_id == target)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("This emulator no longer exists"))?;
    if instance.state == EmulatorState::Stopped {
        return Ok("Emulator is already stopped.".to_owned());
    }
    provider.stop(&instance)?;
    log::info!("Stopped managed emulator {name} on request");
    Ok("Emulator stopped.".to_owned())
}

pub fn request(target: &str) -> ResultType<String> {
    if !super::remote::valid_shutdown_target(target) {
        bail!("Invalid emulator shutdown target")
    }
    if let Some(name) = target.strip_prefix("avd:") {
        return stop_avd(target, name);
    }
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks is not installed"))?;
    let instance = provider
        .discover()?
        .into_iter()
        .find(|item| item.stable_id == target)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("This emulator instance no longer exists"))?;
    if instance.state == EmulatorState::Stopped {
        return Ok("Emulator is already stopped.".to_owned());
    }
    let endpoint = provider.resolve_adb(&instance)?;
    let socket: std::net::SocketAddr = endpoint.serial.parse()?;
    if !socket.ip().is_loopback() {
        bail!("Shutdown requires a local emulator endpoint")
    }
    let pid = listener_owner(socket.port())?;
    let process = Process::open(pid)?;
    process.check_image(&provider.installation().player_path())?;
    let identity = process.identity()?;
    // The listener must still belong to this exact player after opening it.
    if listener_owner(socket.port())? != pid {
        bail!("Emulator changed while preparing shutdown; refresh and retry")
    }
    let mut all = jobs()
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("Shutdown state is unavailable"))?;
    all.retain(|_, job| {
        job.lock()
            .map(|j| matches!(j.state, State::Pending) || j.updated.elapsed().as_secs() < 120)
            .unwrap_or(true)
    });
    if all
        .get(target)
        .map(|job| {
            job.lock()
                .map(|j| matches!(j.state, State::Pending))
                .unwrap_or(true)
        })
        .unwrap_or(false)
    {
        bail!("This emulator is already shutting down")
    }
    if all.len() >= 64 && !all.contains_key(target) {
        bail!("Too many emulator shutdown requests")
    }
    let job = Arc::new(Mutex::new(Job {
        state: State::Pending,
        updated: Instant::now(),
    }));
    let worker = job.clone();
    let image = provider.installation().player_path();
    let worker_target = target.to_owned();
    let worker_name = instance.display_name.clone();
    thread::Builder::new()
        .name("emulator-shutdown".into())
        .spawn(move || {
            let result = close_in_user_session(&worker_target, identity, &image, &worker_name);
            if let Ok(mut state) = worker.lock() {
                state.state = match result {
                    Ok(()) => State::Done,
                    Err(error) => State::Failed(error.to_string()),
                };
                state.updated = Instant::now();
            }
        })?;
    all.insert(target.to_owned(), job);
    Ok(format!("Shutdown requested for {}.", instance.display_name))
}

pub fn annotate(instance: &mut EmulatorInstance) {
    let Ok(mut all) = jobs().lock() else { return };
    let Some(job) = all.get(&instance.target_id).cloned() else {
        return;
    };
    let Ok(state) = job.lock() else { return };
    if matches!(state.state, State::Done) {
        instance.state = "stopped".to_owned();
        instance.last_error.clear();
        all.remove(&instance.target_id);
        return;
    }
    if !matches!(state.state, State::Pending) && state.updated.elapsed().as_secs() >= 120 {
        all.remove(&instance.target_id);
        return;
    }
    match &state.state {
        State::Pending => instance.state = "stopping".to_owned(),
        State::Failed(error) => {
            instance.state = "shutdown_failed".to_owned();
            instance.last_error = format!("Could not shut down emulator: {error}");
        }
        State::Done => {}
    }
}

fn listener_owner(port: u16) -> ResultType<u32> {
    let mut bytes = 0;
    let first = unsafe {
        GetExtendedTcpTable(
            std::ptr::null_mut(),
            &mut bytes,
            0,
            AF_INET as u32,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    if first != 122 || bytes < 4 {
        bail!("Cannot identify the emulator listener ({first})")
    }
    let mut buffer = vec![0_u32; (bytes as usize + 3) / 4];
    let result = unsafe {
        GetExtendedTcpTable(
            buffer.as_mut_ptr().cast(),
            &mut bytes,
            0,
            AF_INET as u32,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    if result != 0 {
        bail!("Cannot identify the emulator listener ({result})")
    }
    let count = buffer[0] as usize;
    let row_size = std::mem::size_of::<MIB_TCPROW_OWNER_PID>();
    if count > (buffer.len() * 4 - 4) / row_size {
        bail!("Invalid emulator listener table")
    }
    let rows = unsafe {
        std::slice::from_raw_parts(buffer.as_ptr().add(1).cast::<MIB_TCPROW_OWNER_PID>(), count)
    };
    let mut owners = rows
        .iter()
        .filter(|row| u16::from_be(row.dwLocalPort as u16) == port)
        .map(|row| row.dwOwningPid)
        .collect::<Vec<_>>();
    owners.sort_unstable();
    owners.dedup();
    if owners.len() != 1 {
        bail!("The emulator is not ready for shutdown; refresh and try again")
    }
    Ok(owners[0])
}

struct Process(HANDLE);
impl Process {
    fn open(pid: u32) -> ResultType<Self> {
        let handle =
            unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, pid) };
        if handle.is_null() {
            bail!(
                "Cannot access emulator: {}",
                std::io::Error::last_os_error()
            )
        }
        Ok(Self(handle))
    }
    fn identity(&self) -> ResultType<Identity> {
        let mut times: [FILETIME; 4] = unsafe { std::mem::zeroed() };
        let ptr = times.as_mut_ptr();
        if unsafe { GetProcessTimes(self.0, ptr, ptr.add(1), ptr.add(2), ptr.add(3)) } == 0 {
            bail!("Cannot verify emulator process identity")
        }
        Ok(Identity {
            pid: unsafe { GetProcessId(self.0) },
            created: ((times[0].dwHighDateTime as u64) << 32) | times[0].dwLowDateTime as u64,
        })
    }
    fn check_image(&self, expected: &Path) -> ResultType<()> {
        let mut buffer = vec![0_u16; 32768];
        let mut length = buffer.len() as u32;
        if unsafe { QueryFullProcessImageNameW(self.0, 0, buffer.as_mut_ptr(), &mut length) } == 0 {
            bail!("Cannot verify emulator executable")
        }
        let actual = String::from_utf16(&buffer[..length as usize])?;
        let expected = expected.to_string_lossy();
        if !actual
            .trim_start_matches(r"\\?\")
            .eq_ignore_ascii_case(expected.trim_start_matches(r"\\?\"))
        {
            bail!("Shutdown target is not the installed BlueStacks player")
        }
        Ok(())
    }
    fn exited(&self, timeout: u32) -> bool {
        unsafe { WaitForSingleObject(self.0, timeout) == 0 }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

const SHUTDOWN_HELPER: &str = "--aperture-emulator-shutdown";

fn helper_identity(args: &[String]) -> ResultType<(&str, Identity)> {
    if args.len() != 4
        || args[0] != SHUTDOWN_HELPER
        || !super::remote::valid_shutdown_target(&args[1])
    {
        bail!("Invalid emulator shutdown helper arguments")
    }
    let identity = Identity {
        pid: args[2].parse()?,
        created: args[3].parse()?,
    };
    if identity.pid == 0 || identity.created == 0 {
        bail!("Invalid emulator process identity")
    }
    Ok((&args[1], identity))
}

pub fn handle_helper_args(args: &[String]) -> bool {
    if args.first().map(String::as_str) != Some(SHUTDOWN_HELPER) {
        return false;
    }
    let result = (|| -> ResultType<()> {
        let (target, identity) = helper_identity(args)?;
        if crate::platform::is_root() {
            bail!("Shutdown helper requires the signed-in user")
        }
        let provider = BlueStacksProvider::detect()?
            .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks is not installed"))?;
        let instance = provider
            .discover()?
            .into_iter()
            .find(|item| item.stable_id == target)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Emulator no longer exists"))?;
        let socket: std::net::SocketAddr = provider.resolve_adb(&instance)?.serial.parse()?;
        if !socket.ip().is_loopback() || listener_owner(socket.port())? != identity.pid {
            bail!("Emulator listener changed; shutdown cancelled")
        }
        graceful_close(
            identity,
            &provider.installation().player_path(),
            &instance.display_name,
        )
    })();
    if let Err(error) = result {
        log::error!("Emulator shutdown helper: {error}");
        eprintln!("Emulator shutdown helper: {error}");
        std::process::exit(1);
    }
    true
}

fn close_in_user_session(
    target: &str,
    identity: Identity,
    image: &Path,
    name: &str,
) -> ResultType<()> {
    if !crate::platform::is_root() {
        return graceful_close(identity, image, name);
    }
    let process = Process::open(identity.pid)?;
    if process.identity()? != identity {
        bail!("Emulator restarted; shutdown cancelled")
    }
    process.check_image(image)?;
    let target_session = crate::platform::get_session_id_of_process(identity.pid);
    if target_session.is_none()
        || target_session != crate::platform::get_current_process_session_id()
    {
        bail!("Emulator belongs to a different Windows session")
    }
    if crate::platform::is_process_running_as_system(identity.pid)? {
        return graceful_close(identity, image, name);
    }
    let pid = identity.pid.to_string();
    let created = identity.created.to_string();
    // The user-owned player must receive its normal close flow in that session.
    crate::platform::run_as_user(vec![SHUTDOWN_HELPER, target, &pid, &created])?;
    if process.exited(45_000) {
        return Ok(());
    }
    bail!("BlueStacks did not complete shutdown in the signed-in user's session; no force close was used")
}

struct ComApartment;
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

fn graceful_close(identity: Identity, image: &Path, name: &str) -> ResultType<()> {
    let process = Process::open(identity.pid)?;
    if process.identity()? != identity {
        bail!("Emulator restarted; shutdown cancelled")
    }
    process.check_image(image)?;
    let close_result = unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        let _apartment = ComApartment;
        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = automation.GetRootElement()?;
        let pid = i32::try_from(identity.pid)?;
        let owner =
            automation.CreatePropertyCondition(UIA_ProcessIdPropertyId, &VARIANT::from(pid))?;
        let named = automation
            .CreatePropertyCondition(UIA_NamePropertyId, &VARIANT::from(BSTR::from(name)))?;
        let condition = automation.CreateAndCondition(&owner, &named)?;
        let matches = root.FindAll(TreeScope_Children, &condition)?;
        if matches.Length()? != 1 {
            bail!("Cannot isolate the named emulator window; no windows were closed")
        }
        let main = matches.GetElement(0)?;
        if main.CurrentProcessId()? != pid {
            bail!("Emulator window owner changed")
        }
        let hwnd = main.CurrentNativeWindowHandle()?;
        if hwnd.0.is_null() {
            bail!("Emulator window handle is unavailable")
        }
        if process.exited(0) {
            return Ok(());
        }
        let dialog_name = format!("Close {name}");
        let dialog_named = automation.CreatePropertyCondition(
            UIA_NamePropertyId,
            &VARIANT::from(BSTR::from(dialog_name.as_str())),
        )?;
        let dialog_condition = automation.CreateAndCondition(&owner, &dialog_named)?;
        let close_name = automation
            .CreatePropertyCondition(UIA_NamePropertyId, &VARIANT::from(BSTR::from("Close")))?;
        let button_type = automation.CreatePropertyCondition(
            UIA_ControlTypePropertyId,
            &VARIANT::from(UIA_ButtonControlTypeId.0),
        )?;
        let close_condition = automation.CreateAndCondition(&close_name, &button_type)?;
        // A retry must finish an existing confirmation instead of posting Close again.
        let find_dialog = || {
            root.FindFirst(TreeScope_Children, &dialog_condition)
                .or_else(|_| main.FindFirst(TreeScope_Descendants, &dialog_condition))
        };
        if find_dialog().is_err() {
            PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0))?;
        }
        let started = Instant::now();
        loop {
            if process.exited(0) {
                return Ok(());
            }
            if let Ok(dialog) = find_dialog() {
                if dialog.CurrentProcessId()? != pid
                    || dialog.CurrentName()?.to_string() != dialog_name
                {
                    bail!("Emulator confirmation identity changed")
                }
                let buttons = dialog.FindAll(TreeScope_Descendants, &close_condition)?;
                if buttons.Length()? > 1 {
                    bail!("Cannot isolate the emulator Close button")
                }
                if buttons.Length()? == 1 {
                    let close = buttons.GetElement(0)?;
                    if close.CurrentProcessId()? != pid || process.exited(0) {
                        bail!("Emulator confirmation is stale")
                    }
                    // Qt can expose the dialog before its button is actionable.
                    if close.CurrentIsEnabled()?.as_bool() && !close.CurrentIsOffscreen()?.as_bool()
                    {
                        if let Ok(invoke) = close
                            .GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                        {
                            break invoke.Invoke();
                        }
                        if let Ok(legacy) = close
                            .GetCurrentPatternAs::<IUIAutomationLegacyIAccessiblePattern>(
                                UIA_LegacyIAccessiblePatternId,
                            )
                        {
                            break legacy.DoDefaultAction();
                        }
                    }
                }
            }
            if started.elapsed().as_secs() >= 10 {
                bail!("BlueStacks did not expose an actionable named Close confirmation; no force close was used")
            }
            thread::sleep(std::time::Duration::from_millis(100));
        }
    };
    if process.exited(15_000) {
        return Ok(());
    }
    close_result?;
    bail!("BlueStacks did not finish its native Close flow; no force close was used")
}

#[link(name = "kernel32")]
extern "system" {
    fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) -> HANDLE;
    fn CloseHandle(handle: HANDLE) -> BOOL;
    fn GetProcessId(handle: HANDLE) -> DWORD;
    fn GetProcessTimes(
        handle: HANDLE,
        creation: *mut FILETIME,
        exit: *mut FILETIME,
        kernel: *mut FILETIME,
        user: *mut FILETIME,
    ) -> BOOL;
    fn QueryFullProcessImageNameW(
        handle: HANDLE,
        flags: DWORD,
        name: *mut u16,
        size: *mut DWORD,
    ) -> BOOL;
    fn WaitForSingleObject(handle: HANDLE, millis: DWORD) -> DWORD;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shutdown_helper_requires_exact_target_and_nonzero_process_identity() {
        let args = vec![
            SHUTDOWN_HELPER.into(),
            "bluestacks:Tiramisu64".into(),
            "42".into(),
            "987654321".into(),
        ];
        assert_eq!(
            helper_identity(&args).unwrap().1,
            Identity {
                pid: 42,
                created: 987654321
            }
        );
        for index in 1..4 {
            let mut invalid = args.clone();
            invalid[index] = if index == 1 {
                "bluestacks:../other".into()
            } else {
                "0".into()
            };
            assert!(helper_identity(&invalid).is_err());
        }
        assert!(helper_identity(&args[..3]).is_err());
        assert!(!handle_helper_args(&["--server".into()]));
    }
    #[test]
    fn invalid_shutdown_targets_cannot_reach_windows_process_management() {
        for target in [
            "",
            "windows:0",
            "ldplayer:0",
            "bluestacks:../other",
            "bluestacks:",
        ] {
            assert!(request(target).is_err());
        }
    }
    #[test]
    #[ignore = "Shuts down and restarts only the explicitly approved local Player1"]
    fn approved_player_shutdown_closes_the_player_and_can_boot_again() {
        assert_eq!(
            std::env::var("APERTURE_TEST_SHUTDOWN_TARGET").as_deref(),
            Ok("bluestacks:Tiramisu64")
        );
        let provider = BlueStacksProvider::detect().unwrap().unwrap();
        let target = provider
            .discover()
            .unwrap()
            .into_iter()
            .find(|t| t.stable_id == "bluestacks:Tiramisu64")
            .unwrap();
        let result = (|| -> ResultType<()> {
            request(&target.stable_id)?;
            let started = Instant::now();
            loop {
                let job = jobs()
                    .lock()
                    .unwrap()
                    .get(&target.stable_id)
                    .cloned()
                    .unwrap();
                let state = job.lock().unwrap().state.clone();
                match state {
                    State::Done => break,
                    State::Failed(error) => bail!("{error}"),
                    State::Pending => {}
                }
                if started.elapsed().as_secs() > 60 {
                    bail!("Graceful shutdown did not finish")
                }
                thread::sleep(std::time::Duration::from_millis(100));
            }
            assert_eq!(provider.refresh(&target)?.state, EmulatorState::Stopped);
            Ok(())
        })();
        if provider
            .refresh(&target)
            .map(|state| state.state == EmulatorState::Stopped)
            .unwrap_or(false)
        {
            use std::os::windows::process::CommandExt;
            std::process::Command::new(provider.installation().player_path())
                .args(["--instance", target.provider_instance_id.as_str()])
                .creation_flags(0x08000000)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap();
        }
        result.unwrap();
    }
}
