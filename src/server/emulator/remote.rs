use base::message_proto::{
    emulator_request, EmulatorRequest, EmulatorResponse, EmulatorVideoFrame,
};

pub const PROTOCOL_VERSION: u32 = 1;

pub enum GuestEvent {
    Response(EmulatorResponse),
    Frame(EmulatorVideoFrame),
}

pub fn blocks_desktop_message(message: &base::message_proto::Message) -> bool {
    use base::message_proto::{message, misc};
    match message.union.as_ref() {
        Some(
            message::Union::MouseEvent(_)
            | message::Union::PointerDeviceEvent(_)
            | message::Union::KeyEvent(_)
            | message::Union::Clipboard(_)
            | message::Union::MultiClipboards(_)
            | message::Union::ScreenshotRequest(_),
        ) => true,
        Some(message::Union::Misc(misc)) => matches!(
            misc.union.as_ref(),
            Some(
                misc::Union::SwitchDisplay(_)
                    | misc::Union::CaptureDisplays(_)
                    | misc::Union::RefreshVideo(_)
                    | misc::Union::RefreshVideoDisplay(_)
                    | misc::Union::ChangeResolution(_)
                    | misc::Union::ChangeDisplayResolution(_)
                    | misc::Union::TogglePrivacyMode(_)
                    | misc::Union::ToggleVirtualDisplay(_)
                    | misc::Union::SelectedSid(_)
                    | misc::Union::FollowCurrentDisplay(_)
                    | misc::Union::Option(_)
            )
        ),
        _ => false,
    }
}

pub fn authorize_request(
    request: &EmulatorRequest,
    authenticated_remote: bool,
    control: bool,
    active_session: Option<u64>,
) -> Result<(), &'static str> {
    use emulator_request::Union;
    if !authenticated_remote {
        return Err("Emulator access requires an authenticated remote session");
    }
    if request.protocol_version != PROTOCOL_VERSION {
        return Err("Unsupported emulator protocol version");
    }
    match request.union.as_ref() {
        Some(Union::List(_)) | Some(Union::Desktop(_)) => Ok(()),
        Some(Union::Host(host)) => match host.action.as_str() {
            "status" => Ok(()),
            "process_end" if control && host.pid > 0 => Ok(()),
            "recover" if control && host.component == "bluestacks_adb" => Ok(()),
            "process_end" | "recover" if !control => {
                Err("Host management action requires control permission")
            }
            _ => Err("Invalid host management action"),
        },
        Some(Union::Previews(previews)) => {
            if previews.target_ids.len() + previews.displays.len() > 4
                || previews.target_ids.iter().any(|id| !id.starts_with("bluestacks:") || id.len() > 128 || id.len() <= 11)
                || (!previews.enabled && (!previews.target_ids.is_empty() || !previews.displays.is_empty()))
            {
                return Err("Invalid dashboard preview subscription");
            }
            Ok(())
        }
        Some(Union::Select(selection)) => {
            if !control {
                return Err("Emulator selection requires control permission");
            }
            if selection.target_id.is_empty() || selection.target_id.len() > 128 {
                return Err("Invalid emulator target");
            }
            Ok(())
        }
        Some(Union::Navigation(navigation)) => {
            use base::message_proto::EmulatorNavigation;
            if !matches!(
                navigation.enum_value(),
                Ok(EmulatorNavigation::EmulatorBack
                    | EmulatorNavigation::EmulatorHome
                    | EmulatorNavigation::EmulatorRecents)
            ) {
                return Err("Unknown Android navigation action");
            }
            authorize_input(request.session_id, control, active_session)
        }
        Some(Union::Touch(touch)) => {
            if touch.action > 3
                || touch.width == 0
                || touch.height == 0
                || touch.width > u16::MAX as u32
                || touch.height > u16::MAX as u32
                || touch.x >= touch.width
                || touch.y >= touch.height
            {
                return Err("Invalid Android touch");
            }
            authorize_input(request.session_id, control, active_session)
        }
        Some(Union::Key(key)) => {
            if key.keycode == 0 || key.keycode > 288 {
                return Err("Unsupported Android keycode");
            }
            authorize_input(request.session_id, control, active_session)
        }
        None => Err("Empty emulator request"),
        Some(_) => Err("Unknown emulator request"),
    }
}

fn authorize_input(
    session_id: u64,
    control: bool,
    active_session: Option<u64>,
) -> Result<(), &'static str> {
    if !control {
        return Err("Android input requires control permission");
    }
    if session_id == 0 || active_session != Some(session_id) {
        return Err("Android session is no longer selected");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{EmulatorListRequest, EmulatorNavigation};

    #[test]
    fn only_authenticated_negotiated_remote_sessions_can_enumerate() {
        let mut request = EmulatorRequest {
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_list(EmulatorListRequest::new());
        assert!(authorize_request(&request, false, true, None).is_err());
        assert!(authorize_request(&request, true, false, None).is_ok());
        request.protocol_version = 0;
        assert!(authorize_request(&request, true, true, None).is_err());
    }

    #[test]
    fn guest_input_requires_control_and_matches_the_selected_session() {
        let mut request = EmulatorRequest {
            protocol_version: PROTOCOL_VERSION,
            session_id: 42,
            ..Default::default()
        };
        request.set_navigation(EmulatorNavigation::EmulatorBack);
        assert!(authorize_request(&request, true, true, Some(42)).is_ok());
        assert!(authorize_request(&request, true, false, Some(42)).is_err());
        assert!(authorize_request(&request, true, true, Some(43)).is_err());
        assert!(authorize_request(&request, true, true, None).is_err());
        request.set_navigation(EmulatorNavigation::EmulatorNavigationUnknown);
        assert!(authorize_request(&request, true, true, Some(42)).is_err());
    }

    #[test]
    fn guest_mode_blocks_windows_input_and_capture_but_keeps_chat_and_disconnect() {
        use base::message_proto::{KeyEvent, Message, Misc, MouseEvent, PointerDeviceEvent};
        let mut message = Message::new();
        message.set_mouse_event(MouseEvent::new());
        assert!(blocks_desktop_message(&message));
        message.set_key_event(KeyEvent::new());
        assert!(blocks_desktop_message(&message));
        message.set_pointer_device_event(PointerDeviceEvent::new());
        assert!(blocks_desktop_message(&message));
        let mut misc = Misc::new();
        misc.set_refresh_video(true);
        message.set_misc(misc.clone());
        assert!(blocks_desktop_message(&message));
        misc.set_close_reason("disconnect".to_owned());
        message.set_misc(misc);
        assert!(!blocks_desktop_message(&message));
    }
}
