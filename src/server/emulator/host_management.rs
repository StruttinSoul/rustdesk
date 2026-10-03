use super::{bluestacks, guest_runtime};
use base::message_proto::{EmulatorHostRequest, EmulatorHostResponse, EmulatorResponse};
use hbb_common::{
    bail,
    sysinfo::{Pid, System},
    ResultType,
};
use serde::Serialize;
use std::{
    cmp::Ordering,
    sync::{Arc, Mutex, OnceLock, RwLock},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const WATCHDOG_INTERVAL: Duration = Duration::from_secs(20);
const PROCESS_LIMIT: usize = 200;

#[derive(Clone, Debug, Default, Serialize)]
struct ComponentHealth {
    id: String,
    label: String,
    state: String,
    detail: String,
    recoverable: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
struct WatchdogState {
    running: bool,
    last_check_ms: u64,
    last_recovery_ms: u64,
    components: Vec<ComponentHealth>,
}

#[derive(Debug, Serialize)]
struct HostProcess {
    pid: u32,
    name: String,
    cpu_percent: f32,
    memory_bytes: u64,
    executable: String,
    can_end: bool,
}

#[derive(Debug, Serialize)]
struct HostSnapshot {
    schema: u32,
    cpu_percent: f32,
    cpu_name: String,
    logical_cpus: usize,
    memory_used_bytes: u64,
    memory_total_bytes: u64,
    uptime_secs: u64,
    processes: Vec<HostProcess>,
    watchdog: WatchdogState,
}

static WATCHDOG: OnceLock<Arc<RwLock<WatchdogState>>> = OnceLock::new();
static HOST_SYSTEM: OnceLock<Mutex<System>> = OnceLock::new();

fn host_system() -> &'static Mutex<System> {
    HOST_SYSTEM.get_or_init(|| Mutex::new(System::new_all()))
}

pub fn ensure_watchdog_started() {
    WATCHDOG.get_or_init(|| {
        let state = Arc::new(RwLock::new(WatchdogState {
            running: true,
            ..Default::default()
        }));
        let worker_state = state.clone();
        if let Err(error) = thread::Builder::new()
            .name("mirpg-host-watchdog".to_owned())
            .spawn(move || loop {
                let next = probe_watchdog(true);
                if let Ok(mut current) = worker_state.write() {
                    *current = next;
                }
                thread::sleep(WATCHDOG_INTERVAL);
            })
        {
            hbb_common::log::warn!("Failed to start MIRPG host watchdog: {error}");
            if let Ok(mut current) = state.write() {
                current.running = false;
            }
        }
        state
    });
}

pub fn handle_request(request_id: u64, request: &EmulatorHostRequest) -> EmulatorResponse {
    let result = match request.action.as_str() {
        "status" => snapshot().map(|snapshot| (String::new(), snapshot)),
        "process_end" => end_process(request.pid)
            .and_then(|message| snapshot().map(|snapshot| (message, snapshot))),
        "recover" => recover_component(&request.component)
            .and_then(|message| snapshot().map(|snapshot| (message, snapshot))),
        _ => Err(hbb_common::anyhow::anyhow!(
            "Unknown host management action"
        )),
    };
    match result {
        Ok((message, snapshot)) => host_response(
            request_id,
            serde_json::json!({"ok": true, "message": message, "snapshot": snapshot}),
        ),
        Err(error) => host_response(
            request_id,
            serde_json::json!({"ok": false, "error": error.to_string()}),
        ),
    }
}

fn host_response(request_id: u64, value: serde_json::Value) -> EmulatorResponse {
    let mut response = super::remote_windows::response(request_id);
    response.set_host(EmulatorHostResponse {
        json: serde_json::to_string(&value).unwrap_or_else(|error| {
            format!(r#"{{"ok":false,"error":"Host response serialization failed: {error}"}}"#)
        }),
        ..Default::default()
    });
    response
}

fn snapshot() -> ResultType<HostSnapshot> {
    ensure_watchdog_started();
    let mut system = host_system()
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("Host system sampler is unavailable"))?;
    system.refresh_cpu();
    system.refresh_memory();
    system.refresh_processes();
    let cpu_percent = system.cpus().iter().map(|cpu| cpu.cpu_usage()).sum::<f32>()
        / system.cpus().len().max(1) as f32;
    let cpu_name = system
        .cpus()
        .first()
        .map(|cpu| cpu.brand().trim().to_owned())
        .unwrap_or_default();
    let mut processes = system
        .processes()
        .values()
        .map(|process| HostProcess {
            pid: process.pid().as_u32(),
            name: process.name().to_owned(),
            cpu_percent: process.cpu_usage(),
            memory_bytes: process.memory(),
            executable: process.exe().to_string_lossy().into_owned(),
            can_end: process_can_end(process.pid().as_u32(), process.name(), process.exe()),
        })
        .collect::<Vec<_>>();
    processes.sort_by(|left, right| {
        right
            .cpu_percent
            .partial_cmp(&left.cpu_percent)
            .unwrap_or(Ordering::Equal)
            .then_with(|| right.memory_bytes.cmp(&left.memory_bytes))
    });
    processes.truncate(PROCESS_LIMIT);
    let watchdog = WATCHDOG
        .get()
        .and_then(|state| state.read().ok().map(|state| state.clone()))
        .unwrap_or_else(|| probe_watchdog(false));
    Ok(HostSnapshot {
        schema: 1,
        cpu_percent,
        cpu_name,
        logical_cpus: system.cpus().len(),
        memory_used_bytes: system.used_memory(),
        memory_total_bytes: system.total_memory(),
        uptime_secs: system.uptime(),
        processes,
        watchdog,
    })
}

fn process_can_end(pid: u32, name: &str, executable: &std::path::Path) -> bool {
    if pid <= 4 || pid == std::process::id() {
        return false;
    }
    let name = name.to_ascii_lowercase();
    if [
        "system",
        "registry",
        "smss.exe",
        "csrss.exe",
        "wininit.exe",
        "services.exe",
        "lsass.exe",
        "winlogon.exe",
        "svchost.exe",
        "fontdrvhost.exe",
        "dwm.exe",
    ]
    .contains(&name.as_str())
    {
        return false;
    }
    if let Some(windows) = std::env::var_os("WINDIR") {
        let system32 = std::path::PathBuf::from(windows).join("System32");
        if executable.starts_with(system32) {
            return false;
        }
    }
    true
}

fn end_process(pid: u32) -> ResultType<String> {
    if pid == 0 {
        bail!("Invalid process id")
    }
    let system = System::new_all();
    let process = system
        .process(Pid::from_u32(pid))
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Process {pid} is no longer running"))?;
    if !process_can_end(pid, process.name(), process.exe()) {
        bail!("This Windows process is protected from remote termination")
    }
    let name = process.name().to_owned();
    if !process.kill() {
        bail!("Windows refused to end {name} ({pid})")
    }
    Ok(format!("Ended {name} ({pid})"))
}

fn recover_component(component: &str) -> ResultType<String> {
    match component {
        "bluestacks_adb" => {
            let healthy = bluestacks::recover_adb_connections()?;
            if let Some(state) = WATCHDOG.get() {
                if let Ok(mut state) = state.write() {
                    state.last_recovery_ms = now_ms();
                }
            }
            Ok(format!("Reconnected {healthy} BlueStacks ADB instance(s)"))
        }
        _ => bail!("This component does not expose a safe recovery action"),
    }
}

fn rustdesk_host_health(installed: bool, service_running: bool) -> ComponentHealth {
    let (state, detail) = if installed && service_running {
        ("healthy", "Installed Windows service is running")
    } else if installed {
        ("unhealthy", "Installed Windows service is not running")
    } else {
        (
            "idle",
            "Portable host is running; install RustDesk for pre-login and UAC access",
        )
    };
    ComponentHealth {
        id: "rustdesk".to_owned(),
        label: "RustDesk host".to_owned(),
        state: state.to_owned(),
        detail: detail.to_owned(),
        recoverable: false,
    }
}

fn probe_watchdog(auto_recover: bool) -> WatchdogState {
    let mut components = vec![rustdesk_host_health(
        crate::platform::is_installed(),
        crate::platform::is_self_service_running(),
    )];
    components.push(match guest_runtime::helper_path() {
        Ok(path) => ComponentHealth {
            id: "guest_helper".to_owned(),
            label: "Android guest helper".to_owned(),
            state: "healthy".to_owned(),
            detail: path.to_string_lossy().into_owned(),
            recoverable: false,
        },
        Err(error) => ComponentHealth {
            id: "guest_helper".to_owned(),
            label: "Android guest helper".to_owned(),
            state: "unhealthy".to_owned(),
            detail: error.to_string(),
            recoverable: false,
        },
    });
    components.push(ComponentHealth {
        id: "codex".to_owned(),
        label: "Codex".to_owned(),
        state: if crate::server::codex::is_available() {
            "healthy"
        } else {
            "unavailable"
        }
        .to_owned(),
        detail: if crate::server::codex::is_available() {
            "Codex installation detected"
        } else {
            "Codex is not available on this Windows host"
        }
        .to_owned(),
        recoverable: false,
    });
    let adb = match bluestacks::watchdog_adb_health() {
        Ok((0, _)) => ComponentHealth {
            id: "bluestacks_adb".to_owned(),
            label: "BlueStacks ADB".to_owned(),
            state: "idle".to_owned(),
            detail: "No running ADB-enabled BlueStacks instances".to_owned(),
            recoverable: true,
        },
        Ok((expected, healthy)) if expected == healthy => ComponentHealth {
            id: "bluestacks_adb".to_owned(),
            label: "BlueStacks ADB".to_owned(),
            state: "healthy".to_owned(),
            detail: format!("{healthy}/{expected} running instance(s) reachable"),
            recoverable: true,
        },
        Ok((expected, healthy)) => {
            if auto_recover && can_recover_user_session() {
                let _ = bluestacks::recover_adb_connections();
            }
            ComponentHealth {
                id: "bluestacks_adb".to_owned(),
                label: "BlueStacks ADB".to_owned(),
                state: "unhealthy".to_owned(),
                detail: format!("{healthy}/{expected} running instance(s) reachable"),
                recoverable: true,
            }
        }
        Err(error) => ComponentHealth {
            id: "bluestacks_adb".to_owned(),
            label: "BlueStacks ADB".to_owned(),
            state: "unhealthy".to_owned(),
            detail: error.to_string(),
            recoverable: true,
        },
    };
    components.push(adb);
    WatchdogState {
        running: true,
        last_check_ms: now_ms(),
        last_recovery_ms: WATCHDOG
            .get()
            .and_then(|state| state.read().ok().map(|state| state.last_recovery_ms))
            .unwrap_or_default(),
        components,
    }
}

fn can_recover_user_session() -> bool {
    let console = crate::platform::get_current_session_id(false);
    console != 0
        && console != u32::MAX
        && crate::platform::get_current_process_session_id() == Some(console)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_metrics_reuse_the_same_system_sampler() {
        assert!(std::ptr::eq(host_system(), host_system()));
    }

    #[test]
    fn rustdesk_health_distinguishes_service_and_portable_hosts() {
        let running = rustdesk_host_health(true, true);
        assert_eq!(running.state, "healthy");
        assert!(running.detail.contains("service is running"));

        let stopped = rustdesk_host_health(true, false);
        assert_eq!(stopped.state, "unhealthy");
        assert!(stopped.detail.contains("service is not running"));

        let portable = rustdesk_host_health(false, false);
        assert_eq!(portable.state, "idle");
        assert!(portable.detail.contains("Portable host"));
    }

    #[test]
    fn protects_core_windows_processes_and_current_process() {
        assert!(!process_can_end(4, "System", std::path::Path::new("")));
        assert!(!process_can_end(
            std::process::id(),
            "rustdesk.exe",
            std::path::Path::new("")
        ));
        assert!(!process_can_end(400, "lsass.exe", std::path::Path::new("")));
        assert!(process_can_end(
            4000,
            "notepad.exe",
            std::path::Path::new("C:\\Apps\\notepad.exe")
        ));
    }
}
