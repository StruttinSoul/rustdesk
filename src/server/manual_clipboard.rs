use base::message_proto::{
    ClipboardFormat, ManualClipboardDirection, ManualClipboardRequest, ManualClipboardResponse,
    MultiClipboards,
};

pub const MAX_MANUAL_CLIPBOARD_BYTES: usize = 1024 * 1024;

pub fn extract_text_clipboard(clipboards: MultiClipboards) -> Result<String, String> {
    let clipboard = clipboards
        .clipboards
        .into_iter()
        .find(|clipboard| clipboard.format.enum_value() == Ok(ClipboardFormat::Text))
        .ok_or_else(|| "Host clipboard does not contain text".to_owned())?;
    let content = if clipboard.compress {
        hbb_common::compress::decompress_with_limit(&clipboard.content, MAX_MANUAL_CLIPBOARD_BYTES)
            .map_err(|error| format!("Host clipboard text is invalid or too large: {error}"))?
    } else {
        if clipboard.content.len() > MAX_MANUAL_CLIPBOARD_BYTES {
            return Err("Host clipboard text exceeds the manual transfer limit".to_owned());
        }
        clipboard.content.to_vec()
    };
    String::from_utf8(content).map_err(|_| "Host clipboard text is not valid UTF-8".to_owned())
}

#[cfg(target_os = "windows")]
fn direct_read_host_text() -> Result<String, String> {
    crate::clipboard::check_clipboard_cm_with_force(true)
        .map_err(|error| error.to_string())
        .and_then(extract_text_clipboard)
}

#[cfg(target_os = "windows")]
fn direct_write_host_text(text: &str) -> Result<(), String> {
    crate::clipboard::set_text_clipboard_with_owner_sync(
        text,
        crate::clipboard::ClipboardSide::Host,
    )
    .map_err(|error| error.to_string())
}

#[cfg(target_os = "windows")]
fn request_cm_clipboard(request: crate::ipc::Data) -> Result<crate::ipc::Data, String> {
    use crate::ipc::{ClipboardFile, Data};
    use hbb_common::tokio::runtime::Runtime;

    let runtime = Runtime::new().map_err(|error| error.to_string())?;
    let mut stream = runtime
        .block_on(crate::ipc::connect(500, "_cm"))
        .map_err(|error| error.to_string())?;
    runtime
        .block_on(stream.send(&request))
        .map_err(|error| error.to_string())?;
    loop {
        match runtime
            .block_on(stream.next_timeout(1500))
            .map_err(|error| error.to_string())?
        {
            Some(Data::ClipboardFile(ClipboardFile::MonitorReady)) => continue,
            Some(response) => return Ok(response),
            None => return Err("Clipboard connection manager did not respond".to_owned()),
        }
    }
}

#[cfg(target_os = "windows")]
pub fn read_host_text() -> Result<String, String> {
    if crate::common::is_server() && crate::platform::is_root() {
        return match request_cm_clipboard(crate::ipc::Data::ManualClipboardRead)? {
            crate::ipc::Data::ManualClipboardReadResult(result) => result,
            _ => Err("Unexpected clipboard read response".to_owned()),
        };
    }
    direct_read_host_text()
}

#[cfg(target_os = "windows")]
pub fn write_host_text(text: &str) -> Result<(), String> {
    if crate::common::is_server() && crate::platform::is_root() {
        return match request_cm_clipboard(crate::ipc::Data::ManualClipboardWrite(text.to_owned()))?
        {
            crate::ipc::Data::ManualClipboardWriteResult(result) => result,
            _ => Err("Unexpected clipboard write response".to_owned()),
        };
    }
    direct_write_host_text(text)
}

/// Manual clipboard permission is intentionally independent from view-only.
/// View-only suppresses input, while clipboard has its own negotiated policy.
pub fn manual_clipboard_allowed(clipboard_enabled: bool, _view_only: bool) -> bool {
    clipboard_enabled
}

pub fn handle_manual_clipboard_request_with<R, W>(
    request: ManualClipboardRequest,
    clipboard_allowed: bool,
    mut read_host_text: R,
    mut write_host_text: W,
) -> ManualClipboardResponse
where
    R: FnMut() -> Result<String, String>,
    W: FnMut(&str) -> Result<(), String>,
{
    let mut response = ManualClipboardResponse {
        request_id: request.request_id.clone(),
        direction: request.direction,
        target_identity: request.target_identity.clone(),
        ..Default::default()
    };

    if !clipboard_allowed {
        response.error_code = "clipboard_permission_denied".to_owned();
        response.error = "Clipboard permission is disabled for this session".to_owned();
        return response;
    }

    let direction = request.direction.enum_value_or_default();
    if direction == ManualClipboardDirection::ManualClipboardUnknown {
        response.error_code = "clipboard_direction_invalid".to_owned();
        response.error = "Manual clipboard direction is invalid".to_owned();
        return response;
    }
    response.accepted = true;

    match direction {
        ManualClipboardDirection::ManualClipboardPhoneToHost => {
            if request.text.as_bytes().len() > MAX_MANUAL_CLIPBOARD_BYTES {
                response.error_code = "clipboard_text_too_large".to_owned();
                response.error = "Clipboard text exceeds the manual transfer limit".to_owned();
                return response;
            }
            match write_host_text(&request.text) {
                Ok(()) => response.applied = true,
                Err(error) => {
                    response.error_code = "clipboard_write_failed".to_owned();
                    response.error = error;
                }
            }
        }
        ManualClipboardDirection::ManualClipboardHostToPhone => match read_host_text() {
            Ok(text) if text.as_bytes().len() <= MAX_MANUAL_CLIPBOARD_BYTES => {
                response.text = text;
                response.applied = true;
            }
            Ok(_) => {
                response.error_code = "clipboard_text_too_large".to_owned();
                response.error = "Clipboard text exceeds the manual transfer limit".to_owned();
            }
            Err(error) => {
                response.error_code = "clipboard_read_failed".to_owned();
                response.error = error;
            }
        },
        ManualClipboardDirection::ManualClipboardUnknown => unreachable!(),
    }

    response
}
