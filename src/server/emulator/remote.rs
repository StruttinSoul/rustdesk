use base::message_proto::{
    emulator_request, EmulatorRequest, EmulatorResponse, EmulatorVideoFrame,
};
use std::collections::VecDeque;

pub const PROTOCOL_VERSION: u32 = 1;

pub enum GuestEvent {
    Response(EmulatorResponse),
    Frame(EmulatorVideoFrame),
}

const HOST_OPERATION_REPLAY_LIMIT: usize = 64;

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostOperationKey {
    operation_id: String,
    session_identity: String,
    target_identity: String,
    session_generation: u64,
    action: String,
}

impl HostOperationKey {
    fn from_host(host: &base::message_proto::EmulatorHostRequest) -> Self {
        Self {
            operation_id: host.operation_id.clone(),
            session_identity: host.session_identity.clone(),
            target_identity: host.target_identity.clone(),
            session_generation: host.session_generation,
            action: host.action.clone(),
        }
    }
}

#[derive(Default)]
pub struct HostOperationReplay {
    completed: VecDeque<(HostOperationKey, EmulatorResponse)>,
}

impl HostOperationReplay {
    pub async fn apply<F, Fut>(
        &mut self,
        host: &base::message_proto::EmulatorHostRequest,
        request_id: u64,
        action: F,
    ) -> EmulatorResponse
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = EmulatorResponse>,
    {
        if !host.operation_id.is_empty() {
            let key = HostOperationKey::from_host(host);
            if let Some((existing, response)) = self
                .completed
                .iter()
                .find(|(existing, _)| existing.operation_id == host.operation_id)
            {
                if existing != &key {
                    let mut rejected = EmulatorResponse {
                        request_id,
                        protocol_version: PROTOCOL_VERSION,
                        ..Default::default()
                    };
                    rejected.set_error(
                        "Operation id already belongs to a different host operation".to_owned(),
                    );
                    return rejected;
                }
                let mut replayed = response.clone();
                replayed.request_id = request_id;
                return replayed;
            }
        }

        let response = action().await;
        if !host.operation_id.is_empty() {
            self.completed
                .push_back((HostOperationKey::from_host(host), response.clone()));
            while self.completed.len() > HOST_OPERATION_REPLAY_LIMIT {
                self.completed.pop_front();
            }
        }
        response
    }
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
        Some(Union::RefreshVideo(_)) if request.session_id != 0 => Ok(()),
        Some(Union::Host(host)) => match host.action.as_str() {
            "status" | "windows_list" | "phone_workspace_support" | "gateway_status" => Ok(()),
            "process_end"
                if control
                    && host.pid > 0
                    && host.process_start_time_secs > 0
                    && host.process_creation_time_100ns > 0 =>
            {
                Ok(())
            }
            "recover" if control && host.component == "bluestacks_adb" => Ok(()),
            "window_focus"
                if control
                    && host.window_id.starts_with("win-")
                    && host.window_id.len() <= 96
                    && host.desktop_generation > 0 =>
            {
                Ok(())
            }
            "phone_workspace_begin"
                if control
                    && (720..=3840).contains(&host.display_width)
                    && (720..=3840).contains(&host.display_height)
                    && host.display_dpi == 0
                    && matches!(host.display_orientation.as_str(), "portrait" | "landscape") =>
            {
                Ok(())
            }
            "phone_workspace_end"
                if control
                    && host.owned_display_id.starts_with("phone-workspace-")
                    && host.owned_display_id.len() <= 128 =>
            {
                Ok(())
            }
            "gateway_setup_open" | "gateway_imdb_set_enabled" | "gateway_imdb_refresh"
                if control => Ok(()),
            "gateway_restart"
                if control
                    && host.gateway_expected_process_identity.starts_with("gateway:")
                    && host.gateway_expected_process_identity.len() <= 128 => Ok(()),
            "process_end"
            | "recover"
            | "window_focus"
            | "phone_workspace_begin"
            | "phone_workspace_end"
            | "gateway_setup_open"
            | "gateway_imdb_set_enabled"
            | "gateway_imdb_refresh"
            | "gateway_restart"
                if !control =>
            {
                Err("Host management action requires control permission")
            }
            _ => Err("Invalid host management action"),
        },
        Some(Union::Previews(previews)) => {
            if previews.target_ids.len() + previews.displays.len() > 4
                || previews
                    .target_ids
                    .iter()
                    .any(|id| !id.starts_with("bluestacks:") || id.len() > 128 || id.len() <= 11)
                || (!previews.enabled
                    && (!previews.target_ids.is_empty() || !previews.displays.is_empty()))
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
        Some(Union::Text(text)) => {
            if text.text.is_empty()
                || text.text.as_bytes().len() > super::MAX_TEXT_BYTES
            {
                return Err("Invalid Android text");
            }
            authorize_input(request.session_id, control, active_session)
        }
        None => Err("Empty emulator request"),
        Some(_) => Err("Unknown emulator request"),
    }
}

pub fn authorize_host_operation(
    request: &EmulatorRequest,
    expected_session_identity: &str,
    expected_generation: u64,
) -> Result<(), &'static str> {
    let Some(emulator_request::Union::Host(host)) = request.union.as_ref() else {
        return Ok(());
    };
    if matches!(
        host.action.as_str(),
        "status" | "windows_list" | "phone_workspace_support" | "gateway_status"
    ) {
        return Ok(());
    }
    if !matches!(
        host.action.as_str(),
        "process_end"
            | "recover"
            | "window_focus"
            | "phone_workspace_begin"
            | "phone_workspace_end"
            | "gateway_setup_open"
            | "gateway_imdb_set_enabled"
            | "gateway_imdb_refresh"
            | "gateway_restart"
    ) {
        return Err("Invalid host management action");
    }
    if expected_session_identity.is_empty()
        || expected_session_identity.len() > 128
        || expected_generation == 0
        || host.operation_id.is_empty()
        || host.operation_id.len() > 128
        || host.session_identity != expected_session_identity
        || host.session_identity.len() > 128
        || host.session_generation != expected_generation
        || host.target_identity.len() > 160
    {
        return Err("Host operation identity does not match this remote session");
    }
    let expected_target = match host.action.as_str() {
        "process_end" => format!("process:{}:{}", host.pid, host.process_creation_time_100ns),
        "recover" => format!("component:{}", host.component),
        "window_focus" => format!("window:{}:{}", host.window_id, host.desktop_generation),
        "phone_workspace_begin" => format!(
            "phone-workspace:new:{}x{}:{}:{}",
            host.display_width, host.display_height, host.display_orientation, host.display_dpi
        ),
        "phone_workspace_end" => format!("phone-workspace:{}", host.owned_display_id),
        "gateway_setup_open" => "gateway:setup".to_owned(),
        "gateway_imdb_set_enabled" | "gateway_imdb_refresh" => "gateway:imdb".to_owned(),
        "gateway_restart" => format!(
            "gateway:restart:{}",
            host.gateway_expected_process_identity
        ),
        _ => return Err("Invalid host management action"),
    };
    if host.target_identity != expected_target {
        return Err("Host operation target does not match the requested action");
    }
    Ok(())
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
    use base::message_proto::{
        EmulatorHostRequest, EmulatorListRequest, EmulatorNavigation, EmulatorVideoRefreshRequest,
    };

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

        request.set_text(base::message_proto::EmulatorText {
            text: "Café 中文 👋🏽".to_owned(),
            ..Default::default()
        });
        assert!(authorize_request(&request, true, true, Some(42)).is_ok());
        request.set_text(base::message_proto::EmulatorText::new());
        assert!(authorize_request(&request, true, true, Some(42)).is_err());
        request.set_text(base::message_proto::EmulatorText {
            text: "a".repeat(4097),
            ..Default::default()
        });
        assert!(authorize_request(&request, true, true, Some(42)).is_err());
    }

    #[test]
    fn guest_video_refresh_requires_authentication_and_a_session_identity() {
        let mut request = EmulatorRequest {
            protocol_version: PROTOCOL_VERSION,
            session_id: 42,
            ..Default::default()
        };
        request.set_refresh_video(EmulatorVideoRefreshRequest::new());
        assert!(authorize_request(&request, true, false, None).is_ok());
        assert!(authorize_request(&request, false, true, Some(42)).is_err());
        request.session_id = 0;
        assert!(authorize_request(&request, true, true, Some(42)).is_err());
    }

    #[test]
    fn host_mutations_are_bound_to_connection_scope_generation_and_target() {
        let mut request = EmulatorRequest {
            request_id: 91,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_host(EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: 1234,
            process_start_time_secs: 55,
            process_creation_time_100ns: 990055,
            operation_id: "op-91".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "process:1234:990055".to_owned(),
            session_generation: 4,
            ..Default::default()
        });

        assert!(authorize_host_operation(&request, "scope-a", 4).is_ok());

        let mut forged_scope = request.clone();
        if let Some(emulator_request::Union::Host(host)) = forged_scope.union.as_mut() {
            host.session_identity = "scope-other".to_owned();
        }
        assert!(authorize_host_operation(&forged_scope, "scope-a", 4).is_err());

        let mut stale_generation = request.clone();
        if let Some(emulator_request::Union::Host(host)) = stale_generation.union.as_mut() {
            host.session_generation = 3;
        }
        assert!(authorize_host_operation(&stale_generation, "scope-a", 4).is_err());

        let mut forged_target = request.clone();
        if let Some(emulator_request::Union::Host(host)) = forged_target.union.as_mut() {
            host.target_identity = "process:9999:990055".to_owned();
        }
        assert!(authorize_host_operation(&forged_target, "scope-a", 4).is_err());
    }

    #[test]
    fn host_permission_denial_survives_ui_toggle() {
        let mut request = EmulatorRequest {
            request_id: 92,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_host(EmulatorHostRequest {
            action: "recover".to_owned(),
            component: "bluestacks_adb".to_owned(),
            operation_id: "op-92".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "component:bluestacks_adb".to_owned(),
            session_generation: 4,
            ..Default::default()
        });

        assert!(authorize_host_operation(&request, "scope-a", 4).is_ok());
        assert!(authorize_request(&request, true, false, None).is_err());
        assert!(authorize_request(&request, true, true, None).is_ok());
    }

    #[test]
    fn forged_target_rejected() {
        let mut request = EmulatorRequest {
            request_id: 93,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_host(EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: 1234,
            process_start_time_secs: 55,
            process_creation_time_100ns: 990055,
            operation_id: "op-93".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "process:9999:990055".to_owned(),
            session_generation: 4,
            ..Default::default()
        });

        assert!(authorize_host_operation(&request, "scope-a", 4).is_err());
    }

    #[hbb_common::tokio::test]
    async fn duplicate_host_operation_replays_response_without_reapplying() {
        let mut replay = HostOperationReplay::default();
        let mut applied = 0;
        let host = EmulatorHostRequest {
            action: "recover".to_owned(),
            component: "bluestacks_adb".to_owned(),
            operation_id: "op-dedupe".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "component:bluestacks_adb".to_owned(),
            session_generation: 4,
            ..Default::default()
        };

        let first = replay
            .apply(&host, 1, || async {
                applied += 1;
                let mut response = EmulatorResponse {
                    request_id: 1,
                    protocol_version: PROTOCOL_VERSION,
                    ..Default::default()
                };
                response.set_error("first".to_owned());
                response
            })
            .await;
        assert_eq!(applied, 1);
        assert_eq!(first.request_id, 1);

        let replayed = replay
            .apply(&host, 2, || async {
                applied += 1;
                let mut response = EmulatorResponse {
                    request_id: 2,
                    protocol_version: PROTOCOL_VERSION,
                    ..Default::default()
                };
                response.set_error("second".to_owned());
                response
            })
            .await;
        assert_eq!(applied, 1, "A retried mutation must not run twice");
        assert_eq!(
            replayed.request_id, 2,
            "Replay must correlate to the retry request"
        );
    }

    #[hbb_common::tokio::test]
    async fn reused_operation_id_cannot_change_target_or_action() {
        let mut replay = HostOperationReplay::default();
        let mut applied = 0;
        let first_host = EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: 1234,
            process_start_time_secs: 55,
            process_creation_time_100ns: 990055,
            operation_id: "op-bound".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "process:1234:990055".to_owned(),
            session_generation: 4,
            ..Default::default()
        };
        let first = replay
            .apply(&first_host, 10, || async {
                applied += 1;
                let mut response = EmulatorResponse {
                    request_id: 10,
                    protocol_version: PROTOCOL_VERSION,
                    ..Default::default()
                };
                response.set_error("first".to_owned());
                response
            })
            .await;
        assert_eq!(applied, 1);
        assert_eq!(first.request_id, 10);

        let forged = EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: 9999,
            process_start_time_secs: 66,
            process_creation_time_100ns: 990066,
            operation_id: "op-bound".to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: "process:9999:990066".to_owned(),
            session_generation: 4,
            ..Default::default()
        };
        let rejected = replay
            .apply(&forged, 11, || async {
                applied += 1;
                let mut response = EmulatorResponse {
                    request_id: 11,
                    protocol_version: PROTOCOL_VERSION,
                    ..Default::default()
                };
                response.set_error("forged execution".to_owned());
                response
            })
            .await;

        assert_eq!(
            applied, 1,
            "An operation id is permanently bound to its first target"
        );
        assert!(matches!(
            rejected.union,
            Some(base::message_proto::emulator_response::Union::Error(error))
                if error.contains("different host operation")
        ));
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
