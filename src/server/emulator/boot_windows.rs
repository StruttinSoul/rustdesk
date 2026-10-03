use super::{bluestacks::BlueStacksProvider, EmulatorProvider, EmulatorState, EmulatorTarget};
use hbb_common::{bail, log, ResultType};
use serde_derive::{Deserialize, Serialize};
use std::{
    collections::BTreeSet, fs, io, os::windows::ffi::OsStrExt, path::Path, thread, time::Duration,
};
use winapi::um::{
    handleapi::CloseHandle,
    processthreadsapi::{CreateProcessW, PROCESS_INFORMATION, STARTUPINFOW},
    winbase::STARTF_USESHOWWINDOW,
    winuser::SW_SHOWMINNOACTIVE,
};
use winreg::{
    enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY},
    RegKey,
};

const REGISTRY_KEY: &str = r"SOFTWARE\MIRPG\EmulatorBoot";

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootSelection {
    version: u32,
    enabled: bool,
    instances: Vec<String>,
}

impl BootSelection {
    fn parse(source: &str) -> ResultType<Self> {
        let selection: Self = serde_json::from_str(source)?;
        if selection.version != 1
            || selection.instances.len() > 8
            || (selection.enabled && selection.instances.is_empty())
        {
            bail!("Unsupported or empty BlueStacks boot selection");
        }
        let mut ids = BTreeSet::new();
        for id in &selection.instances {
            if id.is_empty()
                || id.len() > 128
                || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                || !ids.insert(id)
            {
                bail!("Invalid or duplicate BlueStacks boot instance");
            }
        }
        Ok(selection)
    }

    fn pending<'a>(&self, targets: &'a [EmulatorTarget]) -> ResultType<Vec<&'a EmulatorTarget>> {
        let mut pending = Vec::new();
        if !self.enabled {
            return Ok(pending);
        }
        for id in &self.instances {
            let target = targets
                .iter()
                .find(|target| target.provider_instance_id == *id)
                .ok_or_else(|| {
                    hbb_common::anyhow::anyhow!(
                        "Selected BlueStacks instance '{id}' was not discovered"
                    )
                })?;
            if target.state == EmulatorState::Stopped {
                pending.push(target);
            }
        }
        Ok(pending)
    }
}

pub fn start_if_configured() {
    if !crate::platform::is_root() || !crate::platform::is_installed() {
        return;
    }
    let console = crate::platform::get_current_session_id(false);
    if console == 0
        || console == u32::MAX
        || crate::platform::get_current_process_session_id() != Some(console)
    {
        return;
    }
    // A portable or development host must never activate privileged startup.
    let (_, _, _, installed_exe) = crate::platform::get_install_info();
    let Some(current_exe) = std::env::current_exe()
        .ok()
        .and_then(|path| path.canonicalize().ok())
    else {
        return;
    };
    if Some(current_exe) != Path::new(&installed_exe).canonicalize().ok() {
        return;
    }
    let selection = match read_selection() {
        Ok(Some(selection)) if selection.enabled => selection,
        Ok(_) => return,
        Err(err) => {
            log::error!("BlueStacks boot selection rejected: {err}");
            return;
        }
    };
    if let Err(err) = thread::Builder::new()
        .name("bluestacks-boot-probe".into())
        .spawn(move || {
            // Give the auto-started virtualization driver time to initialize without blocking the host.
            thread::sleep(Duration::from_secs(15));
            match read_selection() {
                Ok(Some(current))
                    if current.enabled && current.instances == selection.instances => {}
                Ok(_) => {
                    log::info!("BlueStacks boot probe cancelled after configuration changed");
                    return;
                }
                Err(err) => {
                    log::error!("BlueStacks boot probe cancelled: {err}");
                    return;
                }
            }
            let result = run_probe(&selection);
            let report = match result {
                Ok(outcomes) => {
                    serde_json::json!({"version":1,"session":console,"outcomes":outcomes,
                "note":"Process launch is not proof of Android boot or pre-login video/control"})
                }
                Err(err) => {
                    log::error!("BlueStacks pre-login probe failed: {err}");
                    serde_json::json!({"version":1,"session":console,"error":err.to_string()})
                }
            };
            if let Err(err) = write_report(&report) {
                log::error!("Could not save BlueStacks boot report: {err}");
            }
        })
    {
        log::error!("Could not start BlueStacks boot probe: {err}");
    }
}

fn read_selection() -> ResultType<Option<BootSelection>> {
    let key = match RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(REGISTRY_KEY, KEY_READ | KEY_WOW64_64KEY)
    {
        Ok(key) => key,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    Ok(Some(BootSelection::parse(
        &key.get_value::<String, _>("Selection")?,
    )?))
}

fn run_probe(selection: &BootSelection) -> ResultType<Vec<serde_json::Value>> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Official BlueStacks installation not found"))?;
    let targets = provider.discover()?;
    selection.pending(&targets)?;
    let mut outcomes = Vec::new();
    for id in &selection.instances {
        // Re-enumerate immediately before each launch so an already-starting instance is left alone.
        let current = provider.discover()?;
        let target = current
            .iter()
            .find(|target| target.provider_instance_id == *id)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks instance '{id}' disappeared"))?;
        let outcome = if target.state == EmulatorState::Stopped {
            match launch_minimized(&provider.installation().player_path(), id) {
                Ok(pid) => {
                    log::info!(
                        "BlueStacks boot probe launched '{id}', pid {pid}, minimized requested"
                    );
                    serde_json::json!({"instance":id,"result":"launch_requested","pid":pid})
                }
                Err(err) => {
                    log::error!("BlueStacks boot launch '{id}' failed: {err}");
                    serde_json::json!({"instance":id,"result":"failed","error":err.to_string()})
                }
            }
        } else {
            log::info!(
                "BlueStacks boot probe left '{id}' alone: {:?}",
                target.state
            );
            serde_json::json!({"instance":id,"result":"left_alone","state":format!("{:?}",target.state)})
        };
        outcomes.push(outcome);
    }
    Ok(outcomes)
}

fn launch_minimized(player: &Path, id: &str) -> ResultType<u32> {
    let executable: Vec<u16> = player.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut command: Vec<u16> = format!("\"{}\" --instance {id}", player.display())
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut desktop: Vec<u16> = "winsta0\\default".encode_utf16().chain(Some(0)).collect();
    // The installed service host already owns the console token. Use its default desktop, never session 0 or Winlogon.
    unsafe {
        let mut startup: STARTUPINFOW = std::mem::zeroed();
        let mut process: PROCESS_INFORMATION = std::mem::zeroed();
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        startup.lpDesktop = desktop.as_mut_ptr();
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_SHOWMINNOACTIVE as u16;
        if CreateProcessW(
            executable.as_ptr(),
            command.as_mut_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            0,
            std::ptr::null_mut(),
            std::ptr::null(),
            &mut startup,
            &mut process,
        ) == 0
        {
            return Err(io::Error::last_os_error().into());
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        Ok(process.dwProcessId)
    }
}

fn write_report(report: &serde_json::Value) -> ResultType<()> {
    let root = std::env::var_os("ProgramData")
        .ok_or_else(|| hbb_common::anyhow::anyhow!("ProgramData is unavailable"))?;
    // Setup creates this administrator-owned directory; do not create it under a user-controlled parent here.
    fs::write(
        Path::new(&root).join("MIRPG-EmulatorBoot/last-run.json"),
        serde_json::to_vec_pretty(report)?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::emulator::ProviderId;

    fn target(id: &str, state: EmulatorState) -> EmulatorTarget {
        let mut target = EmulatorTarget::new(
            ProviderId::new("bluestacks"),
            format!("bluestacks:{id}"),
            id,
            id,
        );
        target.state = state;
        target
    }

    #[test]
    fn boot_selection_starts_only_selected_stopped_instances() {
        let settings = BootSelection::parse(
            r#"{"version":1,"enabled":true,"instances":["Tiramisu64","Tiramisu64_2"]}"#,
        )
        .unwrap();
        let targets = [
            target("Tiramisu64", EmulatorState::Ready),
            target("Tiramisu64_2", EmulatorState::Stopped),
            target("Other", EmulatorState::Stopped),
        ];
        let pending = settings.pending(&targets).unwrap();
        assert_eq!(
            pending
                .iter()
                .map(|target| target.provider_instance_id.as_str())
                .collect::<Vec<_>>(),
            vec!["Tiramisu64_2"]
        );
    }

    #[test]
    fn boot_selection_fails_closed_for_unknown_or_unsafe_requests() {
        for source in [
            r#"{"version":2,"enabled":true,"instances":["Tiramisu64"]}"#,
            r#"{"version":1,"enabled":true,"instances":["../Other"]}"#,
            r#"{"version":1,"enabled":true,"instances":["Tiramisu64"],"command":"other.exe"}"#,
        ] {
            assert!(BootSelection::parse(source).is_err());
        }
        let settings =
            BootSelection::parse(r#"{"version":1,"enabled":true,"instances":["Missing"]}"#)
                .unwrap();
        assert!(settings
            .pending(&[target("Tiramisu64", EmulatorState::Stopped)])
            .is_err());
        let disabled =
            BootSelection::parse(r#"{"version":1,"enabled":false,"instances":[]}"#).unwrap();
        assert!(disabled
            .pending(&[target("Tiramisu64", EmulatorState::Stopped)])
            .unwrap()
            .is_empty());
    }
}
