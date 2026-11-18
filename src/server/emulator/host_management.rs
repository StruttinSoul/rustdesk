use super::{bluestacks, guest_runtime};
use base::message_proto::{EmulatorHostRequest, EmulatorHostResponse, EmulatorResponse};
use hbb_common::{
    bail,
    sysinfo::{Pid, System, MINIMUM_CPU_UPDATE_INTERVAL},
    ResultType,
};
use serde::Serialize;
use std::{
    cmp::Ordering,
    sync::{Arc, Mutex, OnceLock, RwLock},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const WATCHDOG_INTERVAL: Duration = Duration::from_secs(20);
const PROCESS_LIMIT: usize = 200;
/// Free space a new emulator needs on the emulator folder's drive.
const AVD_CREATE_MIN_FREE_BYTES: u64 = 16 << 30;

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
    start_time_secs: u64,
    creation_time_100ns: u64,
    name: String,
    cpu_percent: Option<f32>,
    memory_bytes: u64,
    executable: String,
    can_end: bool,
}

#[derive(Debug, Serialize)]
struct HostSnapshot {
    schema: u32,
    sampled_at_ms: u64,
    source: String,
    cpu_percent: Option<f32>,
    cpu_name: String,
    logical_cpus: Option<usize>,
    memory_used_bytes: Option<u64>,
    memory_total_bytes: Option<u64>,
    uptime_secs: u64,
    processes: Vec<HostProcess>,
    watchdog: WatchdogState,
}

static WATCHDOG: OnceLock<Arc<RwLock<WatchdogState>>> = OnceLock::new();
static HOST_SYSTEM: OnceLock<Mutex<HostSystemSampler>> = OnceLock::new();

struct HostSystemSampler {
    system: System,
    last_cpu_refresh: Instant,
}

impl HostSystemSampler {
    fn new() -> Self {
        Self {
            system: System::new_all(),
            last_cpu_refresh: Instant::now(),
        }
    }

    fn refresh(&mut self) -> bool {
        let now = Instant::now();
        let cpu_sample_ready =
            now.duration_since(self.last_cpu_refresh) >= MINIMUM_CPU_UPDATE_INTERVAL;
        self.system.refresh_cpu();
        self.last_cpu_refresh = now;
        self.system.refresh_memory();
        self.system.refresh_processes();
        cpu_sample_ready
    }
}

fn host_system() -> &'static Mutex<HostSystemSampler> {
    HOST_SYSTEM.get_or_init(|| Mutex::new(HostSystemSampler::new()))
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
                // Here, not in `probe_watchdog`, so UI health queries never restart the driver.
                #[cfg(windows)]
                crate::headless_vdd::repair_if_allowed("watchdog");
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
    handle_request_scoped(request_id, request, "legacy-local", 1)
}

pub fn handle_request_scoped(
    request_id: u64,
    request: &EmulatorHostRequest,
    operation_session_identity: &str,
    operation_generation: u64,
) -> EmulatorResponse {
    let value = match request.action.as_str() {
        "status" => match snapshot() {
            Ok(snapshot) => serde_json::json!({"ok": true, "snapshot": snapshot}),
            Err(error) => serde_json::json!({"ok": false, "error": error.to_string()}),
        },
        "windows_list" => match super::window_picker::list_windows(
            operation_session_identity,
            operation_generation,
        ) {
            Ok(list) => serde_json::json!({
                "ok": true,
                "desktop_generation": list.desktop_generation,
                "windows": list.windows,
            }),
            Err(error) => serde_json::json!({
                "ok": false,
                "accepted": true,
                "error_code": "window_list_failed",
                "error": error.to_string(),
            }),
        },
        "phone_workspace_support" => {
            serde_json::json!({
                "ok": true,
                "phone_workspace": super::phone_workspace::query_support(),
            })
        }
        "gateway_status" => serde_json::json!({
            "ok": true,
            "gateway": super::gateway_management::status(),
        }),
        "gateway_setup_open" => gateway_mutation_result(
            super::gateway_management::open_setup(&request.operation_id),
            "gateway_setup_open_failed",
        ),
        "gateway_imdb_set_enabled" => gateway_mutation_result(
            super::gateway_management::set_imdb_enabled(
                &request.operation_id,
                request.gateway_enabled,
            ),
            "gateway_imdb_setting_failed",
        ),
        "gateway_imdb_refresh" => gateway_mutation_result(
            super::gateway_management::refresh_imdb(&request.operation_id),
            "gateway_imdb_refresh_failed",
        ),
        "gateway_restart" => gateway_mutation_result(
            super::gateway_management::restart(
                &request.operation_id,
                &request.gateway_expected_process_identity,
                request.gateway_active_sessions_known,
                request.gateway_confirmed_active_sessions,
            ),
            "gateway_restart_failed",
        ),
        "phone_workspace_begin" => {
            let profile = super::phone_workspace::PhoneWorkspaceProfile {
                width: request.display_width,
                height: request.display_height,
                orientation: request.display_orientation.clone(),
                dpi: request.display_dpi,
            };
            match super::phone_workspace::begin(profile) {
                Ok((session, reused)) => serde_json::json!({
                    "ok": true,
                    "accepted": true,
                    "message": if reused {
                        "Reconnected to the existing Phone Workspace display"
                    } else {
                        "Phone Workspace display created"
                    },
                    "reused": reused,
                    "phone_workspace_session": session,
                    "phone_workspace": super::phone_workspace::query_support(),
                }),
                Err(error) => serde_json::json!({
                    "ok": false,
                    "accepted": true,
                    "error_code": "phone_workspace_begin_failed",
                    "error": error.to_string(),
                    "phone_workspace": super::phone_workspace::query_support(),
                }),
            }
        }
        "phone_workspace_end" => match super::phone_workspace::end(&request.owned_display_id) {
            Ok(message) => serde_json::json!({
                "ok": true,
                "accepted": true,
                "message": message,
                "phone_workspace": super::phone_workspace::query_support(),
            }),
            Err(error) => serde_json::json!({
                "ok": false,
                "accepted": true,
                "error_code": "phone_workspace_cleanup_failed",
                "error": error.to_string(),
                "phone_workspace": super::phone_workspace::query_support(),
            }),
        },
        "window_focus" => match super::window_picker::focus_window(
            operation_session_identity,
            operation_generation,
            &request.window_id,
            request.desktop_generation,
        ) {
            Ok(window) => serde_json::json!({
                "ok": true,
                "accepted": true,
                "message": "Window focused",
                "window_focus": window,
                "desktop_generation": request.desktop_generation,
            }),
            Err(error) => serde_json::json!({
                "ok": false,
                "accepted": true,
                "error_code": error.code,
                "error": error.message,
                "desktop_generation": request.desktop_generation,
            }),
        },
        "process_end" => mutation_result(
            end_process(
                request.pid,
                request.process_start_time_secs,
                request.process_creation_time_100ns,
            ),
            "process_end_failed",
        ),
        "avd_create" | "avd_clone" | "avd_rename" | "avd_delete" | "avd_window"
        | "avd_settings_get" | "avd_settings_set" => avd_value(
            request,
            &super::avd::AvdProvider::for_management(),
        ),
        "emulator_reboot" => match super::emulator_power::reboot(&request.component) {
            Ok(message) => serde_json::json!({"ok": true, "accepted": true, "message": message}),
            Err(error) => avd_failure("emulator_reboot_failed", error),
        },
        "emulator_shutdown" => match super::shutdown_windows::request(&request.component) {
            Ok(message) => serde_json::json!({"ok": true, "accepted": true, "message": message}),
            Err(error) => serde_json::json!({"ok": false, "accepted": true, "error_code": "emulator_shutdown_failed", "error": error.to_string()}),
        },
        "shell_restart" => match super::shell_windows::restart() {
            Ok(message) => serde_json::json!({"ok": true, "accepted": true, "message": message}),
            Err(error) => serde_json::json!({"ok": false, "accepted": true, "error_code": "shell_restart_failed", "error": error.to_string()}),
        },
        "recover" => mutation_result(
            recover_component(&request.component),
            "recover_component_failed",
        ),
        _ => serde_json::json!({
            "ok": false,
            "accepted": false,
            "error_code": "unsupported_action",
            "error": "Unknown host management action"
        }),
    };
    host_response(request_id, request, value)
}

fn avd_failure(code: &'static str, error: impl std::fmt::Display) -> serde_json::Value {
    serde_json::json!({"ok": false, "accepted": true, "error_code": code, "error": error.to_string()})
}

fn avd_name(component: &str) -> ResultType<&str> {
    match component.strip_prefix("avd:") {
        Some(name) if super::avd_files::valid_avd_name(name) => Ok(name),
        _ => bail!("Invalid emulator"),
    }
}

fn gigabytes(bytes: u64) -> u64 {
    bytes.div_ceil(1 << 30)
}

fn avd_create(request: &EmulatorHostRequest, provider: &super::avd::AvdProvider) -> ResultType<String> {
    let name = request.new_name.as_str();
    if !super::avd_files::valid_avd_name(name) {
        bail!("Invalid emulator name")
    }
    provider.exclusive(None, Some(name), || {
        let free = provider.free_disk_bytes()?;
        if free < AVD_CREATE_MIN_FREE_BYTES {
            bail!(
                "Not enough free space on the PC to create an emulator: {} GB needed, {} GB free",
                gigabytes(AVD_CREATE_MIN_FREE_BYTES),
                free >> 30
            )
        }
        provider.home().create(name, super::avd_files::NEW_AVD_TEMPLATE)
    })?;
    hbb_common::log::info!("Created managed emulator {name}");
    Ok(format!("Created {name}"))
}

fn avd_clone(request: &EmulatorHostRequest, provider: &super::avd::AvdProvider) -> ResultType<String> {
    let source = avd_name(&request.component)?;
    let target = request.new_name.as_str();
    if !super::avd_files::valid_avd_name(target) {
        bail!("Invalid emulator name")
    }
    // Held until the copy ends: start, rename and delete of both names are
    // refused, and its remaining bytes count against the free space. The space
    // check (next to other copies in progress) is part of it.
    let reservation = provider.begin_clone(source, target)?;
    let home = provider.home().clone();
    let (from, to) = (source.to_owned(), target.to_owned());
    thread::Builder::new()
        .name("aperture-avd-clone".to_owned())
        .spawn(move || {
            // The inventory reads progress from the clone's marker file.
            let copied = home.clone_avd(&from, &to, std::process::id(), |copied, total| {
                reservation.progress(copied, total)
            });
            match copied {
                Ok(()) => hbb_common::log::info!("Copied managed emulator {from} to {to}"),
                Err(error) => {
                    hbb_common::log::warn!("Copying managed emulator {from} to {to} failed: {error}");
                    // Shown on the source's card, since the copy's card is gone.
                    reservation.fail(&error.to_string());
                }
            }
        })?;
    Ok("Cloning\u{2026}".to_owned())
}

/// Saves the settings an `avd_settings_set` asks for; with `avd_restart` a
/// running emulator is stopped and started again with them.
fn avd_settings_set(
    request: &EmulatorHostRequest,
    provider: &super::avd::AvdProvider,
) -> ResultType<String> {
    let name = avd_name(&request.component)?;
    let change = super::avd_settings::AvdSettings::requested(
        request.avd_ram_mb,
        request.avd_cpu_cores,
        request.avd_screen_width,
        request.avd_screen_height,
    )?;
    if !provider.save_settings(name, change)? {
        return Ok(format!("Saved the settings of {name}"));
    }
    if !request.avd_restart {
        return Ok(format!("Saved; {name} uses them from its next start"));
    }
    if let Err(error) = provider.restart_in_background(name) {
        bail!("Saved the settings of {name} for its next start, but did not restart it: {error}")
    }
    Ok(format!("Restarting {name} with the new settings"))
}

/// Runs one managed-emulator action against `provider`.
fn avd_value(request: &EmulatorHostRequest, provider: &super::avd::AvdProvider) -> serde_json::Value {
    let ok = |message: String| serde_json::json!({"ok": true, "accepted": true, "message": message});
    match request.action.as_str() {
        "avd_create" => match avd_create(request, provider) {
            Ok(message) => ok(message),
            Err(error) => avd_failure("avd_create_failed", error),
        },
        "avd_clone" => match avd_clone(request, provider) {
            Ok(message) => ok(message),
            Err(error) => avd_failure("avd_clone_failed", error),
        },
        "avd_rename" => match avd_name(&request.component).and_then(|name| {
            provider.exclusive(Some(name), Some(&request.new_name), || {
                provider.home().rename(name, &request.new_name)
            })?;
            Ok(format!("Renamed {name} to {}", request.new_name))
        }) {
            Ok(message) => ok(message),
            Err(error) => avd_failure("avd_rename_failed", error),
        },
        "avd_delete" => match avd_name(&request.component).and_then(|name| {
            provider.exclusive(Some(name), None, || provider.home().delete(name))?;
            Ok(format!("Deleted {name}"))
        }) {
            Ok(message) => ok(message),
            Err(error) => avd_failure("avd_delete_failed", error),
        },
        "avd_window" => match avd_name(&request.component)
            .and_then(|name| provider.set_window_visible(name, request.window_visible))
        {
            Ok(()) => ok(if request.window_visible {
                "Emulator window shown on the PC".to_owned()
            } else {
                "Emulator window hidden on the PC".to_owned()
            }),
            Err(error) => avd_failure("avd_window_failed", error),
        },
        "avd_settings_get" => match avd_name(&request.component).and_then(|name| provider.settings(name)) {
            Ok((current, pending, running)) => serde_json::json!({
                "ok": true,
                "avd_settings": {
                    "current": current.to_json(),
                    "pending": pending.to_json(),
                    "running": running,
                },
            }),
            Err(error) => avd_failure("avd_settings_failed", error),
        },
        "avd_settings_set" => match avd_settings_set(request, provider) {
            Ok(message) => ok(message),
            Err(error) => avd_failure("avd_settings_failed", error),
        },
        _ => avd_failure("unsupported_action", "Unknown host management action"),
    }
}

fn mutation_result(result: ResultType<String>, error_code: &'static str) -> serde_json::Value {
    match result {
        Ok(message) => match snapshot() {
            Ok(snapshot) => {
                serde_json::json!({
                    "ok": true,
                    "accepted": true,
                    "message": message,
                    "snapshot": snapshot
                })
            }
            Err(error) => serde_json::json!({
                "ok": true,
                "accepted": true,
                "message": message,
                "observation_error_code": "host_snapshot_failed",
                "observation_error": error.to_string()
            }),
        },
        Err(error) => serde_json::json!({
            "ok": false,
            "accepted": true,
            "error_code": error_code,
            "error": error.to_string()
        }),
    }
}

fn gateway_mutation_result(
    result: Result<String, super::gateway_management::GatewayOperationError>,
    error_code: &'static str,
) -> serde_json::Value {
    match result {
        Ok(message) => serde_json::json!({
            "ok": true,
            "accepted": true,
            "message": message,
        }),
        Err(error) => serde_json::json!({
            "ok": false,
            "accepted": true,
            "error_code": error_code,
            "error": error.message,
            "outcome_unknown": error.outcome_unknown,
        }),
    }
}

fn host_response(
    request_id: u64,
    request: &EmulatorHostRequest,
    mut value: serde_json::Value,
) -> EmulatorResponse {
    if request.action != "status" && !request.operation_id.is_empty() {
        if let Some(payload) = value.as_object_mut() {
            let state = if payload.get("ok").and_then(|value| value.as_bool()) == Some(true) {
                "applied"
            } else {
                "failed"
            };
            payload.insert("state".to_owned(), serde_json::json!(state));
            payload.insert(
                "operation_id".to_owned(),
                serde_json::json!(request.operation_id),
            );
            payload.insert(
                "session_identity".to_owned(),
                serde_json::json!(request.session_identity),
            );
            payload.insert(
                "target_identity".to_owned(),
                serde_json::json!(request.target_identity),
            );
            payload.insert(
                "session_generation".to_owned(),
                serde_json::json!(request.session_generation),
            );
        }
    }
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
    let mut sampler = host_system()
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("Host system sampler is unavailable"))?;
    let cpu_sample_ready = sampler.refresh();
    let system = &sampler.system;
    let logical_cpus = (!system.cpus().is_empty()).then_some(system.cpus().len());
    let cpu_percent = if cpu_sample_ready {
        logical_cpus.and_then(|logical_cpus| {
            let value =
                system.cpus().iter().map(|cpu| cpu.cpu_usage()).sum::<f32>() / logical_cpus as f32;
            value.is_finite().then_some(value.clamp(0.0, 100.0))
        })
    } else {
        None
    };
    let cpu_name = system
        .cpus()
        .first()
        .map(|cpu| cpu.brand().trim().to_owned())
        .unwrap_or_default();
    let memory_total_bytes = system.total_memory();
    let memory_used_bytes = system.used_memory();
    let memory_total_bytes = (memory_total_bytes > 0).then_some(memory_total_bytes);
    let memory_used_bytes = memory_total_bytes
        .filter(|total| memory_used_bytes <= *total)
        .map(|_| memory_used_bytes);
    let mut processes = system
        .processes()
        .values()
        .map(|process| {
            let pid = process.pid().as_u32();
            let creation_time_100ns = process_creation_time_100ns(pid).unwrap_or_default();
            HostProcess {
                pid,
                start_time_secs: process.start_time(),
                creation_time_100ns,
                name: process.name().to_owned(),
                memory_bytes: process.memory(),
                executable: process.exe().to_string_lossy().into_owned(),
                can_end: creation_time_100ns > 0
                    && process_can_end(pid, process.name(), process.exe()),
                // sysinfo reports a process relative to one logical CPU. Normalize
                // to the same 0-100 whole-machine denominator used above once the
                // sampler has had enough time to produce a meaningful delta.
                cpu_percent: if cpu_sample_ready {
                    logical_cpus.and_then(|logical_cpus| {
                        let value = process.cpu_usage() / logical_cpus as f32;
                        value.is_finite().then_some(value.clamp(0.0, 100.0))
                    })
                } else {
                    None
                },
            }
        })
        .collect::<Vec<_>>();
    processes.sort_by(|left, right| {
        match (left.cpu_percent, right.cpu_percent) {
            (Some(left_cpu), Some(right_cpu)) => {
                right_cpu.partial_cmp(&left_cpu).unwrap_or(Ordering::Equal)
            }
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        }
        .then_with(|| right.memory_bytes.cmp(&left.memory_bytes))
    });
    processes.truncate(PROCESS_LIMIT);
    let watchdog = WATCHDOG
        .get()
        .and_then(|state| state.read().ok().map(|state| state.clone()))
        .unwrap_or_else(|| probe_watchdog(false));
    Ok(HostSnapshot {
        schema: 3,
        sampled_at_ms: now_ms(),
        source: "windows_sysinfo".to_owned(),
        cpu_percent,
        cpu_name,
        logical_cpus,
        memory_used_bytes,
        memory_total_bytes,
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

fn validate_process_start_time(actual: u64, expected: u64) -> ResultType<()> {
    if expected == 0 {
        bail!("Process identity is missing; refresh System before trying again")
    }
    if actual != expected {
        bail!("Process identity changed; refresh System before trying again")
    }
    Ok(())
}

fn validate_process_creation_time(actual: u64, expected: u64) -> ResultType<()> {
    if expected == 0 {
        bail!("Process identity is missing; refresh System before trying again")
    }
    if actual != expected {
        bail!("Process identity changed; refresh System before trying again")
    }
    Ok(())
}

fn end_process(
    pid: u32,
    expected_start_time_secs: u64,
    expected_creation_time_100ns: u64,
) -> ResultType<String> {
    if pid == 0 {
        bail!("Invalid process id")
    }
    if expected_creation_time_100ns == 0 {
        bail!("Process identity is missing; refresh System before trying again")
    }
    let system = System::new_all();
    let process = system
        .process(Pid::from_u32(pid))
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Process {pid} is no longer running"))?;
    validate_process_start_time(process.start_time(), expected_start_time_secs)?;
    if !process_can_end(pid, process.name(), process.exe()) {
        bail!("This Windows process is protected from remote termination")
    }
    let name = process.name().to_owned();
    terminate_process_exact(pid, expected_creation_time_100ns).map_err(|error| {
        hbb_common::anyhow::anyhow!("Windows refused to end {name} ({pid}): {error}")
    })?;
    Ok(format!("Ended {name} ({pid})"))
}

#[cfg(target_os = "windows")]
pub(super) fn process_creation_time_100ns(pid: u32) -> Option<u64> {
    use windows::Win32::{
        Foundation::{CloseHandle, FILETIME},
        System::Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
    };

    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    let result =
        unsafe { GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user) };
    let _ = unsafe { CloseHandle(process) };
    result.ok()?;
    Some((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
}

#[cfg(not(target_os = "windows"))]
pub(super) fn process_creation_time_100ns(_pid: u32) -> Option<u64> {
    None
}

#[cfg(target_os = "windows")]
fn terminate_process_exact(pid: u32, expected_creation_time_100ns: u64) -> ResultType<()> {
    use windows::Win32::{
        Foundation::{CloseHandle, FILETIME},
        System::Threading::{
            GetProcessTimes, OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            PROCESS_TERMINATE,
        },
    };

    let process = unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
            false,
            pid,
        )
    }
    .map_err(|error| hbb_common::anyhow::anyhow!("{error}"))?;
    let result = (|| {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        unsafe { GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user) }
            .map_err(|error| hbb_common::anyhow::anyhow!("{error}"))?;
        let actual = (u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime);
        validate_process_creation_time(actual, expected_creation_time_100ns)?;
        unsafe { TerminateProcess(process, 1) }
            .map_err(|error| hbb_common::anyhow::anyhow!("{error}"))?;
        Ok(())
    })();
    let _ = unsafe { CloseHandle(process) };
    result
}

#[cfg(not(target_os = "windows"))]
fn terminate_process_exact(_pid: u32, _expected_creation_time_100ns: u64) -> ResultType<()> {
    bail!("Exact process termination is only available on Windows")
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

    fn avd_request(action: &str, component: &str, new_name: &str) -> EmulatorHostRequest {
        EmulatorHostRequest {
            action: action.to_owned(),
            component: component.to_owned(),
            new_name: new_name.to_owned(),
            ..Default::default()
        }
    }

    fn avd_provider(
        root: &super::super::avd::tests::TempRoot,
        system: &Arc<super::super::avd::tests::FakeSystem>,
    ) -> super::super::avd::AvdProvider {
        super::super::avd::AvdProvider::for_test(
            super::super::avd_files::AvdHome::new(root.0.clone()),
            system.clone(),
        )
    }

    #[test]
    fn delete_refuses_running() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-delete");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", None);
        let provider = avd_provider(&root, &system);
        let value = avd_value(&avd_request("avd_delete", "avd:Maple_1", ""), &provider);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("running"), "{value}");
        assert!(root.0.join("Maple_1.avd").is_dir());
        // Stopped: it goes.
        let idle = FakeSystem::new(64_000);
        let value = avd_value(&avd_request("avd_delete", "avd:Maple_1", ""), &avd_provider(&root, &idle));
        assert_eq!(value["ok"], true, "{value}");
        assert!(!root.0.join("Maple_1.avd").exists());
    }

    fn avd_target(name: &str) -> super::super::EmulatorTarget {
        super::super::EmulatorTarget::new(
            super::super::ProviderId::new("avd"),
            format!("avd:{name}"),
            name,
            name,
        )
    }

    #[test]
    fn avd_settings_are_reported_and_saved() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-settings");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5554"));
        let provider = avd_provider(&root, &system);
        let mut set = avd_request("avd_settings_set", "avd:Maple_1", "");
        set.avd_ram_mb = 6144;
        set.avd_screen_width = 1080;
        set.avd_screen_height = 2400;
        let value = avd_value(&set, &provider);
        assert_eq!(value["ok"], true, "{value}");
        assert!(value["message"].as_str().unwrap().contains("next start"), "{value}");
        let value = avd_value(&avd_request("avd_settings_get", "avd:Maple_1", ""), &provider);
        assert_eq!(value["ok"], true, "{value}");
        let settings = &value["avd_settings"];
        assert_eq!(settings["running"], true);
        assert_eq!(
            settings["current"],
            serde_json::json!({"ram_mb": 4096, "cpu_cores": 4, "screen_width": 1080, "screen_height": 2208})
        );
        assert_eq!(
            settings["pending"],
            serde_json::json!({"ram_mb": 6144, "screen_width": 1080, "screen_height": 2400})
        );
        set.avd_ram_mb = 5000;
        let value = avd_value(&set, &provider);
        assert_eq!(value["ok"], false, "{value}");
        assert_eq!(value["error_code"], "avd_settings_failed");
        let value = avd_value(&avd_request("avd_settings_get", "avd:Missing", ""), &provider);
        assert_eq!(value["ok"], false, "{value}");
    }

    #[test]
    fn a_restart_that_cannot_run_says_the_settings_were_saved() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-restart-refused");
        create(&root, "Maple_Hr");
        let system = FakeSystem::new(3_000);
        system.run("Maple_Hr", Some("emulator-5564"));
        let provider = avd_provider(&root, &system);
        let mut set = avd_request("avd_settings_set", "avd:Maple_Hr", "");
        set.avd_ram_mb = 8192;
        set.avd_restart = true;
        let value = avd_value(&set, &provider);
        assert_eq!(value["ok"], false, "{value}");
        let error = value["error"].as_str().unwrap();
        assert!(error.starts_with("Saved the settings of Maple_Hr"), "{error}");
        assert!(error.contains("memory"), "{error}");
        let value = avd_value(&avd_request("avd_settings_get", "avd:Maple_Hr", ""), &provider);
        assert_eq!(value["avd_settings"]["pending"]["ram_mb"], 8192, "{value}");
    }

    #[test]
    fn management_is_refused_right_after_a_start() {
        use super::super::{avd::tests::{create, temp_root, FakeSystem}, EmulatorProvider};
        let root = temp_root("host-after-start");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        // Launched, but qemu is not in the process list yet.
        provider.start(&avd_target("Maple_1")).unwrap();
        for request in [
            avd_request("avd_delete", "avd:Maple_1", ""),
            avd_request("avd_rename", "avd:Maple_1", "Maple_9"),
            avd_request("avd_clone", "avd:Maple_1", "Maple_9"),
        ] {
            let value = avd_value(&request, &provider);
            assert_eq!(value["ok"], false, "{value}");
        }
        assert!(root.0.join("Maple_1.avd").is_dir());
        assert!(!root.0.join("Maple_9.avd").exists());
    }

    #[test]
    fn a_clone_in_progress_reserves_source_and_destination() {
        use super::super::{avd::tests::{create, temp_root, FakeSystem}, EmulatorProvider};
        let root = temp_root("host-clone-reserve");
        create(&root, "Maple_1");
        create(&root, "Maple_3");
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        let guard = provider.begin_clone("Maple_1", "Maple_2").unwrap();
        assert!(provider.start(&avd_target("Maple_1")).is_err());
        assert!(provider.begin_clone("Maple_1", "Maple_4").is_err());
        for request in [
            avd_request("avd_rename", "avd:Maple_1", "Maple_9"),
            avd_request("avd_delete", "avd:Maple_1", ""),
            avd_request("avd_rename", "avd:Maple_3", "Maple_2"),
            avd_request("avd_create", "", "Maple_2"),
        ] {
            let value = avd_value(&request, &provider);
            assert_eq!(value["ok"], false, "{value}");
            assert!(value["error"].as_str().unwrap().contains("copied"), "{value}");
        }
        assert!(root.0.join("Maple_1.avd").is_dir());
        drop(guard);
        provider.start(&avd_target("Maple_1")).unwrap();
        let value = avd_value(&avd_request("avd_delete", "avd:Maple_3", ""), &provider);
        assert_eq!(value["ok"], true, "{value}");
    }

    #[test]
    fn rename_and_window_refuse_a_wrong_state() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-rename");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        let mut window = avd_request("avd_window", "avd:Maple_1", "");
        window.window_visible = true;
        let value = avd_value(&window, &provider);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("not running"), "{value}");
        assert_eq!(value["error_code"], "avd_window_failed");
        let value = avd_value(&avd_request("avd_rename", "avd:Maple_1", "Maple_9"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        assert!(root.0.join("Maple_9.avd").is_dir());
        system.run("Maple_9", None);
        let value = avd_value(&avd_request("avd_rename", "avd:Maple_9", "Maple_1"), &provider);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("running"), "{value}");
    }

    #[test]
    fn create_needs_free_space_and_a_new_name() {
        use super::super::avd::tests::{temp_root, FakeSystem};
        let root = temp_root("host-create");
        let system = FakeSystem::new(64_000);
        system.set_free_bytes(AVD_CREATE_MIN_FREE_BYTES - 1);
        let provider = avd_provider(&root, &system);
        let value = avd_value(&avd_request("avd_create", "", "Maple_2"), &provider);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error_code"], "avd_create_failed");
        assert!(!root.0.join("Maple_2.avd").exists());
        system.set_free_bytes(AVD_CREATE_MIN_FREE_BYTES);
        let value = avd_value(&avd_request("avd_create", "", "Maple_2"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        assert!(root.0.join("Maple_2.avd").is_dir());
        let again = avd_value(&avd_request("avd_create", "", "maple_2"), &provider);
        assert_eq!(again["ok"], false);
    }

    #[test]
    fn clone_reports_not_enough_space() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-clone-space");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.set_free_bytes(1024);
        let provider = avd_provider(&root, &system);
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_1", "Maple_2"), &provider);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error_code"], "avd_clone_failed");
        assert!(value["error"].as_str().unwrap().contains("space"), "{value}");
        assert!(!root.0.join("Maple_2.avd").exists());
    }

    #[test]
    fn clone_is_accepted_immediately_and_finishes_in_the_background() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-clone-run");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_1", "Maple_2"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        assert_eq!(value["accepted"], true);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let done = provider
                .home()
                .list()
                .unwrap()
                .iter()
                .any(|entry| entry.name == "Maple_2" && entry.clone.is_none());
            if done {
                break;
            }
            assert!(Instant::now() < deadline, "clone did not finish");
            thread::sleep(Duration::from_millis(50));
        }
        // A running source is refused.
        system.run("Maple_1", None);
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_1", "Maple_3"), &provider);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("running"), "{value}");
    }

    /// Waits until `done` holds, polling the provider for up to 10 s.
    fn wait_for(mut done: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done() {
            assert!(Instant::now() < deadline, "timed out");
            thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn space_checks_count_the_rest_of_clones_in_progress() {
        use super::super::avd::tests::{create, temp_root, FakeSystem};
        let root = temp_root("host-clone-pending");
        create(&root, "Maple_1");
        create(&root, "Maple_5");
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        let required = provider.home().required_free_bytes_for_clone("Maple_1").unwrap();
        let size = required - (4 << 30);
        // Enough for one copy of Maple_1, not for that plus a second copy.
        system.set_free_bytes(required + size / 2);
        let first = provider.begin_clone("Maple_1", "Maple_2").unwrap();
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_5", "Maple_6"), &provider);
        assert_eq!(value["ok"], false, "{value}");
        assert!(value["error"].as_str().unwrap().contains("space"), "{value}");
        system.set_free_bytes(AVD_CREATE_MIN_FREE_BYTES + size / 2);
        let value = avd_value(&avd_request("avd_create", "", "Maple_7"), &provider);
        assert_eq!(value["ok"], false, "{value}");
        assert!(value["error"].as_str().unwrap().contains("space"), "{value}");
        assert!(!root.0.join("Maple_6.avd").exists() && !root.0.join("Maple_7.avd").exists());
        // Once the first copy is over, both fit again.
        drop(first);
        let value = avd_value(&avd_request("avd_create", "", "Maple_7"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        system.set_free_bytes(required + size / 2);
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_5", "Maple_6"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        wait_for(|| {
            provider
                .home()
                .list()
                .unwrap()
                .iter()
                .any(|entry| entry.name == "Maple_6" && entry.clone.is_none())
        });
    }

    #[test]
    fn a_failed_clone_is_reported_on_the_source_card() {
        use super::super::{avd::tests::{create, temp_root, FakeSystem}, EmulatorProvider};
        use std::os::windows::fs::OpenOptionsExt;
        let root = temp_root("host-clone-fail");
        create(&root, "Maple_1");
        let image = root.0.join("Maple_1.avd").join("userdata-qemu.img");
        std::fs::write(&image, vec![1u8; 4096]).unwrap();
        // Unreadable while this handle is open: the copy fails after it was accepted.
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&image)
            .unwrap();
        let system = FakeSystem::new(64_000);
        let provider = avd_provider(&root, &system);
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_1", "Maple_2"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        let mut error = String::new();
        wait_for(|| {
            let targets = provider.discover().unwrap();
            error = targets
                .iter()
                .find(|target| target.provider_instance_id == "Maple_1")
                .and_then(|target| target.last_error.clone())
                .unwrap_or_default();
            !error.is_empty()
        });
        drop(lock);
        assert!(error.starts_with("Copy to Maple_2 failed: "), "{error}");
        assert!(!root.0.join("Maple_2.avd").exists() && !root.0.join("Maple_2.ini").exists());
        let targets = provider.discover().unwrap();
        assert!(targets.iter().all(|target| target.provider_instance_id != "Maple_2"));
        // A new copy of the same source clears the old failure.
        let value = avd_value(&avd_request("avd_clone", "avd:Maple_1", "Maple_3"), &provider);
        assert_eq!(value["ok"], true, "{value}");
        wait_for(|| {
            provider
                .home()
                .list()
                .unwrap()
                .iter()
                .any(|entry| entry.name == "Maple_3" && entry.clone.is_none())
        });
        let targets = provider.discover().unwrap();
        let source = targets
            .iter()
            .find(|target| target.provider_instance_id == "Maple_1")
            .unwrap();
        assert_eq!(source.last_error, None);
    }

    #[test]
    fn failed_host_mutation_ack_preserves_operation_identity() {
        let request = EmulatorHostRequest {
            action: "unsupported".to_owned(),
            operation_id: "op-ack".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "component:test".to_owned(),
            session_generation: 7,
            ..Default::default()
        };

        let response = handle_request(44, &request);
        let host = match response.union {
            Some(base::message_proto::emulator_response::Union::Host(host)) => host,
            _ => panic!("Expected host response"),
        };
        let value: serde_json::Value = serde_json::from_str(&host.json).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["accepted"], false);
        assert_eq!(value["state"], "failed");
        assert_eq!(value["error_code"], "unsupported_action");
        assert_eq!(value["operation_id"], "op-ack");
        assert_eq!(value["session_identity"], "scope-a");
        assert_eq!(value["target_identity"], "component:test");
        assert_eq!(value["session_generation"], 7);
    }

    #[test]
    fn accepted_host_mutation_can_still_fail_to_apply() {
        let request = EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: 0,
            process_start_time_secs: 1,
            operation_id: "op-accepted".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "process:0".to_owned(),
            session_generation: 7,
            ..Default::default()
        };

        let response = handle_request(45, &request);
        let host = match response.union {
            Some(base::message_proto::emulator_response::Union::Host(host)) => host,
            _ => panic!("Expected host response"),
        };
        let value: serde_json::Value = serde_json::from_str(&host.json).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["accepted"], true);
        assert_eq!(value["state"], "failed");
        assert_eq!(value["error_code"], "process_end_failed");
    }

    #[test]
    fn gateway_mutation_projects_unknown_outcome_to_wire() {
        let value = gateway_mutation_result(
            Err(super::super::gateway_management::GatewayOperationError {
                message: "Gateway response was lost.".to_owned(),
                outcome_unknown: true,
            }),
            "gateway_restart_failed",
        );

        assert_eq!(value["ok"], false);
        assert_eq!(value["accepted"], true);
        assert_eq!(value["outcome_unknown"], true);
        assert_eq!(value["error_code"], "gateway_restart_failed");
        assert_eq!(value["error"], "Gateway response was lost.");
    }

    #[test]
    fn host_metrics_reuse_the_same_system_sampler() {
        assert!(std::ptr::eq(host_system(), host_system()));
    }

    #[test]
    fn pid_reuse_rejected() {
        validate_process_start_time(1234, 1234).expect("matching process identity");
        let error = validate_process_start_time(1235, 1234)
            .expect_err("a recycled pid must not preserve the old process identity");
        assert!(error.to_string().contains("Process identity changed"));
        validate_process_creation_time(987654321, 987654321)
            .expect("matching native creation identity");
        let error = validate_process_creation_time(987654322, 987654321)
            .expect_err("a recycled pid must not preserve the native creation identity");
        assert!(error.to_string().contains("Process identity changed"));
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
    #[test]
    fn windows_list_is_not_treated_as_an_unknown_host_action() {
        let request = EmulatorHostRequest {
            action: "windows_list".to_owned(),
            ..Default::default()
        };
        let response = handle_request(77, &request);
        let host = match response.union {
            Some(base::message_proto::emulator_response::Union::Host(host)) => host,
            _ => panic!("Expected host response"),
        };
        let value: serde_json::Value = serde_json::from_str(&host.json).unwrap();
        assert_ne!(
            value["error_code"].as_str(),
            Some("unsupported_action"),
            "WP9 window enumeration must have a real host handler"
        );
    }
}
