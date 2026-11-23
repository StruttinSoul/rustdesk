use base::message_proto::DisplayInfo;
use hbb_common::{
    bail,
    sysinfo::{Pid, System},
    ResultType,
};
use serde::Serialize;
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};
use uuid::Uuid;
use winapi::{
    shared::{
        minwindef::{BOOL, DWORD, FILETIME, LPARAM, TRUE},
        windef::{HWND, RECT},
    },
    um::{
        handleapi::CloseHandle,
        processthreadsapi::{
            GetCurrentProcessId, GetProcessTimes, OpenProcess, ProcessIdToSessionId,
        },
        winnt::PROCESS_QUERY_LIMITED_INFORMATION,
        winuser::{
            BringWindowToTop, EnumWindows, GetClassNameW, GetForegroundWindow, GetWindowPlacement,
            GetWindowRect, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
            IsIconic, IsWindow, IsWindowVisible, SetForegroundWindow, ShowWindow, SW_RESTORE,
            WINDOWPLACEMENT,
        },
    },
};

const MAX_WINDOWS: usize = 100;
const MAX_TITLE_CHARS: usize = 256;
const MAX_APPLICATION_CHARS: usize = 256;
const MAX_SCOPES: usize = 32;

#[derive(Clone, Debug, Serialize)]
pub struct HostWindowInfo {
    pub id: String,
    pub title: String,
    pub application: String,
    pub monitor: usize,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub minimized: bool,
    pub can_focus: bool,
}

#[derive(Debug, Serialize)]
pub struct HostWindowList {
    pub desktop_generation: u64,
    pub windows: Vec<HostWindowInfo>,
}

#[derive(Clone, Debug)]
struct WindowRecord {
    info: HostWindowInfo,
    hwnd: isize,
    pid: u32,
    thread_id: u32,
    process_creation_time_100ns: u64,
    class_name: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WindowPickerError {
    pub code: &'static str,
    pub message: String,
}

impl WindowPickerError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DisplayFingerprint {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    online: bool,
}

#[derive(Default)]
struct ScopedWindowRegistry {
    generation: u64,
    records: HashMap<String, WindowRecord>,
    displays: Vec<DisplayFingerprint>,
    last_used: u64,
}

#[derive(Default)]
struct WindowRegistry {
    tick: u64,
    scopes: HashMap<String, ScopedWindowRegistry>,
}

static REGISTRY: OnceLock<Mutex<WindowRegistry>> = OnceLock::new();

fn registry() -> &'static Mutex<WindowRegistry> {
    REGISTRY.get_or_init(|| Mutex::new(WindowRegistry::default()))
}

#[derive(Clone, Debug)]
struct Candidate {
    hwnd: isize,
    pid: u32,
    thread_id: u32,
    title: String,
    class_name: String,
    rect: RECT,
    minimized: bool,
}

struct EnumState {
    session_id: u32,
    own_pid: u32,
    candidates: Vec<Candidate>,
}

pub fn list_windows(scope_identity: &str, scope_generation: u64) -> ResultType<HostWindowList> {
    let session_id = interactive_session_id()?;
    let scope_key = scope_key(scope_identity, scope_generation)?;

    let mut state = EnumState {
        session_id,
        own_pid: unsafe { GetCurrentProcessId() },
        candidates: Vec::new(),
    };
    let enumerated =
        unsafe { EnumWindows(Some(enum_window), &mut state as *mut EnumState as LPARAM) };
    if enumerated == 0 {
        bail!("Windows could not enumerate top-level windows");
    }

    let displays = super::super::display_service::get_sync_displays();
    let system = System::new_all();
    let mut records = HashMap::new();
    let mut windows = Vec::new();
    for candidate in state.candidates.into_iter().take(MAX_WINDOWS) {
        let Some(process_creation_time_100ns) = process_creation_time_100ns(candidate.pid) else {
            continue;
        };
        let application = system
            .process(Pid::from_u32(candidate.pid))
            .map(|process| truncate_chars(process.name().trim(), MAX_APPLICATION_CHARS))
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| format!("PID {}", candidate.pid));
        if is_system_window(&candidate.class_name, &application) {
            continue;
        }
        let Some((monitor, x, y)) = monitor_for_rect(&candidate.rect, &displays) else {
            continue;
        };
        let id = format!("win-{}", Uuid::new_v4().simple());
        let info = HostWindowInfo {
            id: id.clone(),
            title: candidate.title,
            application,
            monitor,
            x,
            y,
            width: candidate.rect.right.saturating_sub(candidate.rect.left),
            height: candidate.rect.bottom.saturating_sub(candidate.rect.top),
            minimized: candidate.minimized,
            can_focus: true,
        };
        records.insert(
            id,
            WindowRecord {
                info: info.clone(),
                hwnd: candidate.hwnd,
                pid: candidate.pid,
                thread_id: candidate.thread_id,
                process_creation_time_100ns,
                class_name: candidate.class_name,
            },
        );
        windows.push(info);
    }
    windows.sort_by(|a, b| {
        a.application
            .to_lowercase()
            .cmp(&b.application.to_lowercase())
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });

    let display_fingerprint = display_fingerprint(&displays);
    let mut registry = registry()
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("Window picker registry is unavailable"))?;
    registry.tick = registry.tick.wrapping_add(1).max(1);
    let tick = registry.tick;
    if !registry.scopes.contains_key(&scope_key) && registry.scopes.len() >= MAX_SCOPES {
        if let Some(oldest) = registry
            .scopes
            .iter()
            .min_by_key(|(_, scope)| scope.last_used)
            .map(|(key, _)| key.clone())
        {
            registry.scopes.remove(&oldest);
        }
    }
    let scope = registry.scopes.entry(scope_key).or_default();
    scope.generation = scope.generation.wrapping_add(1).max(1);
    scope.records = records;
    scope.displays = display_fingerprint;
    scope.last_used = tick;
    Ok(HostWindowList {
        desktop_generation: scope.generation,
        windows,
    })
}

pub fn focus_window(
    scope_identity: &str,
    scope_generation: u64,
    window_id: &str,
    desktop_generation: u64,
) -> Result<HostWindowInfo, WindowPickerError> {
    if !window_id.starts_with("win-") || window_id.len() > 96 || desktop_generation == 0 {
        return Err(WindowPickerError::new(
            "invalid_window_target",
            "Invalid window target",
        ));
    }
    let scope_key = scope_key(scope_identity, scope_generation).map_err(|_| {
        WindowPickerError::new(
            "window_scope_invalid",
            "Window picker session is unavailable",
        )
    })?;
    let (record, expected_displays) = {
        let registry = registry().lock().map_err(|_| {
            WindowPickerError::new(
                "window_registry_unavailable",
                "Window picker is unavailable",
            )
        })?;
        let scope = registry.scopes.get(&scope_key).ok_or_else(|| {
            WindowPickerError::new(
                "desktop_generation_changed",
                "The desktop window list expired. Refresh Windows and try again.",
            )
        })?;
        if scope.generation != desktop_generation {
            return Err(WindowPickerError::new(
                "desktop_generation_changed",
                "The desktop window list changed. Refresh Windows and try again.",
            ));
        }
        let record = scope.records.get(window_id).cloned().ok_or_else(|| {
            WindowPickerError::new(
                "window_not_current",
                "The selected window is no longer available.",
            )
        })?;
        (record, scope.displays.clone())
    };

    let hwnd = record.hwnd as HWND;
    if unsafe { IsWindow(hwnd) } == 0 {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window was closed.",
        ));
    }
    let mut pid = 0u32;
    let thread_id = unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    if pid != record.pid || thread_id != record.thread_id {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window identity changed.",
        ));
    }
    let mut session_id = u32::MAX;
    let expected_session = interactive_session_id().map_err(|_| {
        WindowPickerError::new(
            "window_session_changed",
            "The interactive Windows session is unavailable.",
        )
    })?;
    if unsafe { ProcessIdToSessionId(pid, &mut session_id) } == 0 || session_id != expected_session
    {
        return Err(WindowPickerError::new(
            "window_session_changed",
            "The selected window is no longer in the active Windows session.",
        ));
    }
    if process_creation_time_100ns(pid) != Some(record.process_creation_time_100ns) {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window process identity changed.",
        ));
    }
    let class_name = window_class_name(hwnd);
    if class_name != record.class_name {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window identity changed.",
        ));
    }
    if window_title(hwnd).as_deref() != Some(record.info.title.as_str()) {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window identity changed. Refresh Windows and try again.",
        ));
    }
    if unsafe { IsWindowVisible(hwnd) } == 0 && unsafe { IsIconic(hwnd) } == 0 {
        return Err(WindowPickerError::new(
            "window_not_current",
            "The selected window is no longer visible.",
        ));
    }

    let displays = super::super::display_service::get_sync_displays();
    if display_fingerprint(&displays) != expected_displays {
        return Err(WindowPickerError::new(
            "desktop_generation_changed",
            "The monitor layout changed. Refresh Windows and try again.",
        ));
    }

    if unsafe { IsIconic(hwnd) } != 0 {
        unsafe {
            ShowWindow(hwnd, SW_RESTORE);
        }
    }
    unsafe {
        BringWindowToTop(hwnd);
    }
    if unsafe { SetForegroundWindow(hwnd) } == 0 || unsafe { GetForegroundWindow() } != hwnd {
        return Err(WindowPickerError::new(
            "focus_denied",
            "Windows did not allow this remote session to foreground the selected window.",
        ));
    }

    let rect = window_rect(hwnd, false).ok_or_else(|| {
        WindowPickerError::new(
            "window_bounds_unavailable",
            "Windows could not read the selected window bounds.",
        )
    })?;
    let Some((monitor, x, y)) = monitor_for_rect(&rect, &displays) else {
        return Err(WindowPickerError::new(
            "window_monitor_unavailable",
            "The selected window is not on an available remote monitor.",
        ));
    };
    let title = window_title(hwnd).unwrap_or_else(|| record.info.title.clone());
    let observed = HostWindowInfo {
        id: record.info.id.clone(),
        title,
        application: record.info.application.clone(),
        monitor,
        x,
        y,
        width: rect.right.saturating_sub(rect.left),
        height: rect.bottom.saturating_sub(rect.top),
        minimized: false,
        can_focus: true,
    };
    if let Ok(mut registry) = registry().lock() {
        if let Some(scope) = registry.scopes.get_mut(&scope_key) {
            if scope.generation == desktop_generation && scope.displays == expected_displays {
                if let Some(current) = scope.records.get_mut(window_id) {
                    if same_window_identity(current, &record) {
                        current.info = observed.clone();
                    }
                }
            }
        }
    }
    Ok(observed)
}

unsafe extern "system" fn enum_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let state = &mut *(lparam as *mut EnumState);
    if state.candidates.len() >= MAX_WINDOWS * 2 {
        return TRUE;
    }
    if IsWindowVisible(hwnd) == 0 && IsIconic(hwnd) == 0 {
        return TRUE;
    }
    let mut pid: DWORD = 0;
    let thread_id = GetWindowThreadProcessId(hwnd, &mut pid);
    if pid == 0 || thread_id == 0 || pid == state.own_pid {
        return TRUE;
    }
    let mut window_session = u32::MAX;
    if ProcessIdToSessionId(pid, &mut window_session) == 0 || window_session != state.session_id {
        return TRUE;
    }
    let title_len = GetWindowTextLengthW(hwnd);
    if title_len <= 0 {
        return TRUE;
    }
    let title_capacity = (title_len as usize + 1).min(MAX_TITLE_CHARS + 1);
    let mut title = vec![0u16; title_capacity];
    let copied = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32);
    if copied <= 0 {
        return TRUE;
    }
    let title = String::from_utf16_lossy(&title[..copied as usize])
        .trim()
        .to_owned();
    if title.is_empty() {
        return TRUE;
    }
    let mut class_name = vec![0u16; 256];
    let class_len = GetClassNameW(hwnd, class_name.as_mut_ptr(), class_name.len() as i32);
    let class_name = if class_len > 0 {
        String::from_utf16_lossy(&class_name[..class_len as usize])
    } else {
        String::new()
    };
    let minimized = IsIconic(hwnd) != 0;
    let Some(rect) = window_rect(hwnd, minimized) else {
        return TRUE;
    };
    state.candidates.push(Candidate {
        hwnd: hwnd as isize,
        pid,
        thread_id,
        title,
        class_name,
        rect,
        minimized,
    });
    TRUE
}

fn same_window_identity(left: &WindowRecord, right: &WindowRecord) -> bool {
    left.hwnd == right.hwnd
        && left.pid == right.pid
        && left.thread_id == right.thread_id
        && left.process_creation_time_100ns == right.process_creation_time_100ns
        && left.class_name == right.class_name
        && left.info.title == right.info.title
}

fn interactive_session_id() -> ResultType<u32> {
    let session_id = crate::platform::get_current_session_id(true);
    if session_id == 0
        || session_id == u32::MAX
        || crate::platform::get_current_process_session_id() != Some(session_id)
    {
        bail!("No interactive Windows desktop is available");
    }
    Ok(session_id)
}

fn scope_key(scope_identity: &str, scope_generation: u64) -> ResultType<String> {
    if scope_identity.is_empty() || scope_identity.len() > 128 || scope_generation == 0 {
        bail!("Window picker session scope is invalid");
    }
    Ok(format!("{scope_identity}:{scope_generation}"))
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn display_fingerprint(displays: &[DisplayInfo]) -> Vec<DisplayFingerprint> {
    displays
        .iter()
        .map(|display| DisplayFingerprint {
            x: display.x,
            y: display.y,
            width: display.width,
            height: display.height,
            online: display.online,
        })
        .collect()
}

fn window_rect(hwnd: HWND, minimized: bool) -> Option<RECT> {
    if minimized {
        let mut placement: WINDOWPLACEMENT = unsafe { std::mem::zeroed() };
        placement.length = std::mem::size_of::<WINDOWPLACEMENT>() as u32;
        if unsafe { GetWindowPlacement(hwnd, &mut placement) } != 0 {
            let rect = placement.rcNormalPosition;
            if rect.right > rect.left && rect.bottom > rect.top {
                return Some(rect);
            }
        }
    }
    let mut rect: RECT = unsafe { std::mem::zeroed() };
    if unsafe { GetWindowRect(hwnd, &mut rect) } == 0
        || rect.right <= rect.left
        || rect.bottom <= rect.top
    {
        None
    } else {
        Some(rect)
    }
}

fn process_creation_time_100ns(pid: u32) -> Option<u64> {
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return None;
    }
    let mut creation: FILETIME = unsafe { std::mem::zeroed() };
    let mut exit: FILETIME = unsafe { std::mem::zeroed() };
    let mut kernel: FILETIME = unsafe { std::mem::zeroed() };
    let mut user: FILETIME = unsafe { std::mem::zeroed() };
    let ok = unsafe { GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user) };
    unsafe {
        CloseHandle(process);
    }
    if ok == 0 {
        return None;
    }
    Some((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
}

fn window_class_name(hwnd: HWND) -> String {
    let mut class_name = vec![0u16; 256];
    let class_len =
        unsafe { GetClassNameW(hwnd, class_name.as_mut_ptr(), class_name.len() as i32) };
    if class_len <= 0 {
        String::new()
    } else {
        String::from_utf16_lossy(&class_name[..class_len as usize])
    }
}

fn window_title(hwnd: HWND) -> Option<String> {
    let title_len = unsafe { GetWindowTextLengthW(hwnd) };
    if title_len <= 0 {
        return None;
    }
    let title_capacity = (title_len as usize + 1).min(MAX_TITLE_CHARS + 1);
    let mut title = vec![0u16; title_capacity];
    let copied = unsafe { GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32) };
    if copied <= 0 {
        None
    } else {
        let title = String::from_utf16_lossy(&title[..copied as usize])
            .trim()
            .to_owned();
        (!title.is_empty()).then_some(title)
    }
}

fn is_system_window(class_name: &str, application: &str) -> bool {
    matches!(
        class_name.to_ascii_lowercase().as_str(),
        "progman" | "workerw" | "shell_traywnd" | "shell_secondarytraywnd"
    ) || matches!(
        application.to_ascii_lowercase().as_str(),
        "dwm.exe" | "sihost.exe" | "searchhost.exe" | "startmenuexperiencehost.exe"
    )
}

fn monitor_for_rect(rect: &RECT, displays: &[DisplayInfo]) -> Option<(usize, i32, i32)> {
    let mut best: Option<(usize, i64)> = None;
    for (index, display) in displays.iter().enumerate() {
        if !display.online || display.width <= 0 || display.height <= 0 {
            continue;
        }
        let right = display.x.saturating_add(display.width);
        let bottom = display.y.saturating_add(display.height);
        let overlap_width = rect
            .right
            .min(right)
            .saturating_sub(rect.left.max(display.x));
        let overlap_height = rect
            .bottom
            .min(bottom)
            .saturating_sub(rect.top.max(display.y));
        let area = i64::from(overlap_width.max(0)) * i64::from(overlap_height.max(0));
        if area > 0 && best.map_or(true, |(_, best_area)| area > best_area) {
            best = Some((index, area));
        }
    }
    let (index, _) = best?;
    let display = &displays[index];
    Some((
        index,
        rect.left.saturating_sub(display.x),
        rect.top.saturating_sub(display.y),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(title: &str) -> WindowRecord {
        WindowRecord {
            info: HostWindowInfo {
                id: "win-test".to_owned(),
                title: title.to_owned(),
                application: "app.exe".to_owned(),
                monitor: 0,
                x: 0,
                y: 0,
                width: 640,
                height: 480,
                minimized: false,
                can_focus: true,
            },
            hwnd: 123,
            pid: 456,
            thread_id: 789,
            process_creation_time_100ns: 42,
            class_name: "TestClass".to_owned(),
        }
    }

    #[test]
    fn reused_handle_with_changed_title_is_not_same_window() {
        let original = record("Original");
        let reused = record("Replacement");
        assert!(!same_window_identity(&original, &reused));
    }

    #[test]
    fn monitor_layout_fingerprint_detects_relocation() {
        let first = vec![DisplayInfo {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            ..Default::default()
        }];
        let moved = vec![DisplayInfo {
            x: 1920,
            ..first[0].clone()
        }];
        assert_ne!(display_fingerprint(&first), display_fingerprint(&moved));
    }

    #[test]
    fn application_names_are_bounded_by_characters() {
        let value = "界".repeat(MAX_APPLICATION_CHARS + 20);
        let truncated = truncate_chars(&value, MAX_APPLICATION_CHARS);
        assert_eq!(truncated.chars().count(), MAX_APPLICATION_CHARS);
        assert!(truncated.len() > MAX_APPLICATION_CHARS);
    }

    #[test]
    fn window_scope_requires_authenticated_identity_and_generation() {
        assert!(scope_key("scope-a", 1).is_ok());
        assert!(scope_key("", 1).is_err());
        assert!(scope_key("scope-a", 0).is_err());
    }
}
