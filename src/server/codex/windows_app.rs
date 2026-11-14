use std::{
    thread,
    time::{Duration, Instant},
};
use windows::{
    core::{w, BOOL, PCWSTR, PWSTR},
    Win32::{
        Foundation::{CloseHandle, HWND, LPARAM},
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::{
            Shell::ShellExecuteW,
            WindowsAndMessaging::{
                BringWindowToTop, EnumWindows, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
                SetForegroundWindow, ShowWindow, SW_RESTORE, SW_SHOWNORMAL,
            },
        },
    },
};

const WINDOW_APPEAR_TIMEOUT: Duration = Duration::from_secs(5);
const WINDOW_APPEAR_POLL: Duration = Duration::from_millis(50);

pub(crate) fn open_windows_app() -> Result<(), String> {
    if let Some(hwnd) = find_codex_desktop_window() {
        return activate_window(hwnd);
    }

    launch_codex_desktop()?;
    let deadline = Instant::now() + WINDOW_APPEAR_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(hwnd) = find_codex_desktop_window() {
            return activate_window(hwnd);
        }
        thread::sleep(WINDOW_APPEAR_POLL);
    }

    Err("Codex Desktop was launched, but its window did not appear".into())
}

pub(crate) fn is_codex_desktop_image_path(path: &str) -> bool {
    let normalized = path.replace('/', "\\").to_ascii_lowercase();
    normalized.contains(r"\windowsapps\openai.codex_") && normalized.ends_with(r"\app\chatgpt.exe")
}

fn find_codex_desktop_window() -> Option<HWND> {
    unsafe extern "system" fn enum_window(hwnd: HWND, state: LPARAM) -> BOOL {
        if !unsafe { IsWindowVisible(hwnd) }.as_bool() && !unsafe { IsIconic(hwnd) }.as_bool() {
            return true.into();
        }

        let mut process_id = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut process_id)) };
        if process_id == 0 {
            return true.into();
        }

        if let Some(path) = process_image_path(process_id) {
            if is_codex_desktop_image_path(&path) {
                let matches = unsafe { &mut *(state.0 as *mut Vec<HWND>) };
                matches.push(hwnd);
            }
        }
        true.into()
    }

    let mut matches = Vec::<HWND>::new();
    let state = LPARAM((&mut matches as *mut Vec<HWND>) as isize);
    if unsafe { EnumWindows(Some(enum_window), state) }.is_err() {
        return None;
    }
    matches.into_iter().next()
}

fn process_image_path(process_id: u32) -> Option<String> {
    let process =
        unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id) }.ok()?;
    let mut buffer = vec![0u16; 32_768];
    let mut size = buffer.len() as u32;
    let result = unsafe {
        QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buffer.as_mut_ptr()),
            &mut size,
        )
    };
    let _ = unsafe { CloseHandle(process) };
    result.ok()?;
    String::from_utf16(&buffer[..size as usize]).ok()
}

fn launch_codex_desktop() -> Result<(), String> {
    let result = unsafe {
        ShellExecuteW(
            None,
            PCWSTR::null(),
            w!(r"shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    let code = result.0 as isize;
    if code <= 32 {
        return Err(format!(
            "Windows could not launch Codex Desktop (ShellExecute code {code})"
        ));
    }
    Ok(())
}

fn activate_window(hwnd: HWND) -> Result<(), String> {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = BringWindowToTop(hwnd);
        // Windows deliberately restricts focus stealing. A denied foreground
        // request still counts as a successful handoff once the official
        // Codex window has been found and restored.
        let _ = SetForegroundWindow(hwnd);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{is_codex_desktop_image_path, open_windows_app};

    #[test]
    fn identifies_only_official_packaged_codex_desktop_processes() {
        assert!(is_codex_desktop_image_path(
            r"C:\Program Files\WindowsApps\OpenAI.Codex_26.928.4866.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe"
        ));
        assert!(!is_codex_desktop_image_path(
            r"C:\Users\greg\AppData\Local\Programs\Codex Web GPT\Codex Web GPT.exe"
        ));
        assert!(!is_codex_desktop_image_path(
            r"C:\Users\greg\AppData\Local\Programs\OpenAI\ChatGPT\ChatGPT.exe"
        ));
    }

    #[test]
    #[ignore = "foregrounds the locally installed Codex Desktop window"]
    fn codex_windows_app_handoff_smoke() {
        open_windows_app().expect("installed Codex Desktop should be foregrounded");
    }
}
