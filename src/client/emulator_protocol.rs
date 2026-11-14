use base::message_proto::{
    EmulatorDesktopRequest, EmulatorHostRequest, EmulatorKey, EmulatorListRequest,
    EmulatorNavigation, EmulatorPreviewRequest, EmulatorRequest, EmulatorSelectRequest,
    EmulatorText, EmulatorTouch,
};

const MAX_EMULATOR_REQUEST_BYTES: usize = 32 * 1024;

fn host_operation_identity(
    value: &serde_json::Value,
    expected_target: &str,
) -> Option<(String, String, String, u64)> {
    let operation_id = value["operation_id"].as_str()?;
    let session_identity = value["session_identity"].as_str()?;
    let target_identity = value["target_identity"].as_str()?;
    let session_generation = value["session_generation"].as_u64()?;
    if operation_id.is_empty()
        || operation_id.len() > 128
        || session_identity.is_empty()
        || session_identity.len() > 128
        || target_identity.len() > 160
        || target_identity != expected_target
        || session_generation == 0
    {
        return None;
    }
    Some((
        operation_id.to_owned(),
        session_identity.to_owned(),
        target_identity.to_owned(),
        session_generation,
    ))
}

pub fn emulator_request_from_json(payload: &str) -> Option<EmulatorRequest> {
    if payload.len() > MAX_EMULATOR_REQUEST_BYTES {
        return None;
    }
    let value: serde_json::Value = serde_json::from_str(payload).ok()?;
    if value["protocol_version"].as_u64()? != 1 {
        return None;
    }
    let request_id = value["request_id"].as_u64()?;
    if request_id == 0 || request_id > 0x001fffffffffffff {
        return None;
    }
    let mut request = EmulatorRequest {
        request_id,
        protocol_version: 1,
        session_id: value["session_id"].as_u64().unwrap_or_default(),
        ..Default::default()
    };
    match value["action"].as_str()? {
        "list" => request.set_list(EmulatorListRequest::new()),
        "select" => request.set_select(EmulatorSelectRequest {
            target_id: value["target_id"].as_str()?.to_owned(),
            start_if_stopped: value["start_if_stopped"].as_bool().unwrap_or(false),
            launch_default_app: value["launch_default_app"].as_bool().unwrap_or(false),
            ..Default::default()
        }),
        "desktop" => request.set_desktop(EmulatorDesktopRequest::new()),
        "host_status" => request.set_host(EmulatorHostRequest {
            action: "status".to_owned(),
            ..Default::default()
        }),
        "gateway_status" => request.set_host(EmulatorHostRequest {
            action: "gateway_status".to_owned(),
            ..Default::default()
        }),
        "gateway_setup_open" => {
            let target = "gateway:setup";
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, target)?;
            request.set_host(EmulatorHostRequest {
                action: "gateway_setup_open".to_owned(),
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "gateway_imdb_set_enabled" => {
            let target = "gateway:imdb";
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, target)?;
            request.set_host(EmulatorHostRequest {
                action: "gateway_imdb_set_enabled".to_owned(),
                gateway_enabled: value["enabled"].as_bool()?,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "gateway_imdb_refresh" => {
            let target = "gateway:imdb";
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, target)?;
            request.set_host(EmulatorHostRequest {
                action: "gateway_imdb_refresh".to_owned(),
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "gateway_restart" => {
            let expected = value["expected_process_identity"].as_str()?.to_owned();
            if expected.is_empty() || expected.len() > 128 || !expected.starts_with("gateway:") {
                return None;
            }
            let target = format!("gateway:restart:{expected}");
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "gateway_restart".to_owned(),
                gateway_expected_process_identity: expected,
                gateway_confirmed_active_sessions: u32::try_from(
                    value["confirmed_active_sessions"].as_u64().unwrap_or_default(),
                )
                .ok()?,
                gateway_active_sessions_known: value["active_sessions_known"]
                    .as_bool()
                    .unwrap_or(false),
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "windows_list" => request.set_host(EmulatorHostRequest {
            action: "windows_list".to_owned(),
            ..Default::default()
        }),
        "phone_workspace_support" => request.set_host(EmulatorHostRequest {
            action: "phone_workspace_support".to_owned(),
            ..Default::default()
        }),
        "phone_workspace_begin" => {
            let display_width = u32::try_from(value["display_width"].as_u64()?).ok()?;
            let display_height = u32::try_from(value["display_height"].as_u64()?).ok()?;
            let display_dpi = u32::try_from(value["display_dpi"].as_u64().unwrap_or(0)).ok()?;
            let display_orientation = value["display_orientation"].as_str()?.to_owned();
            let target = format!(
                "phone-workspace:new:{display_width}x{display_height}:{display_orientation}:{display_dpi}"
            );
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "phone_workspace_begin".to_owned(),
                display_width,
                display_height,
                display_dpi,
                display_orientation,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "phone_workspace_end" => {
            let owned_display_id = value["owned_display_id"].as_str()?.to_owned();
            if !owned_display_id.starts_with("phone-workspace-") || owned_display_id.len() > 128 {
                return None;
            }
            let target = format!("phone-workspace:{owned_display_id}");
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "phone_workspace_end".to_owned(),
                owned_display_id,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "window_focus" => {
            let window_id = value["window_id"].as_str()?.to_owned();
            let desktop_generation = value["desktop_generation"].as_u64()?;
            if !window_id.starts_with("win-") || window_id.len() > 96 || desktop_generation == 0 {
                return None;
            }
            let target = format!("window:{window_id}:{desktop_generation}");
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "window_focus".to_owned(),
                window_id,
                desktop_generation,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "process_end" => {
            let pid = u32::try_from(value["pid"].as_u64()?).ok()?;
            let process_start_time_secs = value["process_start_time_secs"].as_u64()?;
            let process_creation_time_100ns = value["process_creation_time_100ns"].as_u64()?;
            if process_start_time_secs == 0 || process_creation_time_100ns == 0 {
                return None;
            }
            let target = format!("process:{pid}:{process_creation_time_100ns}");
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "process_end".to_owned(),
                pid,
                process_start_time_secs,
                process_creation_time_100ns,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "recover" => {
            let component = value["component"].as_str()?.to_owned();
            let target = format!("component:{component}");
            let (operation_id, session_identity, target_identity, session_generation) =
                host_operation_identity(&value, &target)?;
            request.set_host(EmulatorHostRequest {
                action: "recover".to_owned(),
                component,
                operation_id,
                session_identity,
                target_identity,
                session_generation,
                ..Default::default()
            });
        }
        "previews" => request.set_previews(EmulatorPreviewRequest {
            enabled: value["enabled"].as_bool()?,
            target_ids: value["target_ids"]
                .as_array()?
                .iter()
                .map(|id| id.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()?,
            displays: value["displays"]
                .as_array()?
                .iter()
                .map(|id| u32::try_from(id.as_u64()?).ok())
                .collect::<Option<Vec<_>>>()?,
            ..Default::default()
        }),
        "navigation" => request.set_navigation(match value["navigation"].as_str()? {
            "back" => EmulatorNavigation::EmulatorBack,
            "home" => EmulatorNavigation::EmulatorHome,
            "recents" => EmulatorNavigation::EmulatorRecents,
            _ => return None,
        }),
        "key" => request.set_key(EmulatorKey {
            keycode: u32::try_from(value["keycode"].as_u64()?).ok()?,
            down: value["down"].as_bool()?,
            ..Default::default()
        }),
        "text" => request.set_text(EmulatorText {
            text: value["text"].as_str()?.to_owned(),
            ..Default::default()
        }),
        "touch" => request.set_touch(EmulatorTouch {
            action: u32::try_from(value["touch_action"].as_u64()?).ok()?,
            pointer_id: value["pointer_id"].as_u64()?,
            x: u32::try_from(value["x"].as_u64()?).ok()?,
            y: u32::try_from(value["y"].as_u64()?).ok()?,
            width: u32::try_from(value["width"].as_u64()?).ok()?,
            height: u32::try_from(value["height"].as_u64()?).ok()?,
            ..Default::default()
        }),
        _ => return None,
    }
    crate::server::emulator::remote::authorize_request(
        &request,
        true,
        true,
        Some(request.session_id),
    )
    .ok()?;
    Some(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{emulator_request, EmulatorNavigation};

    #[test]
    fn dashboard_previews_are_bounded_view_only_subscriptions() {
        let request = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":8,"action":"previews","enabled":true,"target_ids":["bluestacks:Tiramisu64"],"displays":[0,1]}"#,
        );
        assert!(
            request.is_some(),
            "The dashboard must subscribe to actual guest and monitor video"
        );
        let request = request.unwrap();
        assert!(
            crate::server::emulator::remote::authorize_request(&request, true, false, None).is_ok()
        );
        assert!(
            crate::server::emulator::remote::authorize_request(&request, false, true, None)
                .is_err()
        );
        assert!(emulator_request_from_json(r#"{"protocol_version":1,"request_id":9,"action":"previews","enabled":true,"target_ids":["ldplayer:0"],"displays":[]}"#).is_none());
        assert!(emulator_request_from_json(r#"{"protocol_version":1,"request_id":9,"action":"previews","enabled":true,"target_ids":[],"displays":[0,1,2,3,4]}"#).is_none());
    }

    #[test]
    fn builds_typed_selection_and_session_bound_navigation() {
        let request = emulator_request_from_json(r#"{"protocol_version":1,"request_id":3,"action":"select","target_id":"bluestacks:Tiramisu64","start_if_stopped":true}"#).unwrap();
        assert_eq!(request.protocol_version, 1);
        assert!(
            matches!(request.union, Some(emulator_request::Union::Select(selection)) if selection.target_id == "bluestacks:Tiramisu64" && selection.start_if_stopped)
        );
        let request = emulator_request_from_json(r#"{"protocol_version":1,"request_id":4,"session_id":42,"action":"navigation","navigation":"back"}"#).unwrap();
        assert_eq!(request.session_id, 42);
        assert!(
            matches!(request.union, Some(emulator_request::Union::Navigation(navigation)) if navigation.enum_value_or_default() == EmulatorNavigation::EmulatorBack)
        );

        let request = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":5,"session_id":42,"action":"text","text":"Café 中文 👋🏽"}"#,
        )
        .unwrap();
        assert!(
            matches!(request.union, Some(emulator_request::Union::Text(text)) if text.text == "Café 中文 👋🏽")
        );
    }

    #[test]
    fn rejects_unknown_commands_unnegotiated_requests_and_unbound_input() {
        for payload in [
            r#"{"protocol_version":1,"request_id":1,"action":"shell","command":"rm -rf /"}"#,
            r#"{"request_id":1,"action":"list"}"#,
            r#"{"protocol_version":1,"request_id":1,"action":"navigation","navigation":"home"}"#,
        ] {
            assert!(emulator_request_from_json(payload).is_none());
        }
    }

    #[test]
    fn host_management_is_bounded_and_control_gated() {
        let status = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":11,"action":"host_status"}"#,
        )
        .unwrap();
        assert!(
            crate::server::emulator::remote::authorize_request(&status, true, false, None).is_ok()
        );

        assert!(
            emulator_request_from_json(
                r#"{"protocol_version":1,"request_id":12,"action":"process_end","pid":1234}"#,
            )
            .is_none(),
            "A mutation without negotiated operation identity must not be sent"
        );

        assert!(emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":12,"action":"process_end","pid":1234,"process_start_time_secs":55,"process_creation_time_100ns":990055,"operation_id":"op-12","session_identity":"scope-a","target_identity":"process:9999:990055","session_generation":4}"#,
        )
        .is_none(), "A forged target identity must be rejected before it reaches the host");

        let process = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":14,"action":"process_end","pid":1234,"process_start_time_secs":55,"process_creation_time_100ns":990055,"operation_id":"op-14","session_identity":"scope-a","target_identity":"process:1234:990055","session_generation":4}"#,
        )
        .expect("exact process identity should parse");
        assert!(
            crate::server::emulator::remote::authorize_request(&process, true, true, None).is_ok()
        );

        assert!(emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":13,"action":"recover","component":"arbitrary_service"}"#
        )
        .is_none());
    }
    #[test]
    fn window_picker_list_request_is_typed_and_view_only_safe() {
        let request = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":31,"action":"windows_list"}"#,
        )
        .expect("window enumeration should use the bounded host-management request path");

        assert!(matches!(
            request.union,
            Some(emulator_request::Union::Host(ref host)) if host.action == "windows_list"
        ));
        assert!(
            crate::server::emulator::remote::authorize_request(&request, true, false, None).is_ok(),
            "listing windows is read-only and must remain usable in view-only sessions"
        );
    }

    #[test]
    fn gateway_status_is_typed_and_view_only_safe() {
        let request = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":34,"action":"gateway_status"}"#,
        )
        .expect("Gateway status should use the bounded host-management request path");

        assert!(matches!(
            request.union,
            Some(emulator_request::Union::Host(ref host)) if host.action == "gateway_status"
        ));
        assert!(
            crate::server::emulator::remote::authorize_request(&request, true, false, None).is_ok(),
            "Gateway status is read-only and must remain usable in view-only sessions"
        );
    }

    #[test]
    fn gateway_mutations_are_control_gated_and_identity_bound() {
        for payload in [
            r#"{"protocol_version":1,"request_id":35,"action":"gateway_setup_open","operation_id":"op-35","session_identity":"scope-gateway","target_identity":"gateway:setup","session_generation":4}"#,
            r#"{"protocol_version":1,"request_id":36,"action":"gateway_imdb_set_enabled","enabled":false,"operation_id":"op-36","session_identity":"scope-gateway","target_identity":"gateway:imdb","session_generation":4}"#,
            r#"{"protocol_version":1,"request_id":37,"action":"gateway_imdb_refresh","operation_id":"op-37","session_identity":"scope-gateway","target_identity":"gateway:imdb","session_generation":4}"#,
            r#"{"protocol_version":1,"request_id":38,"action":"gateway_restart","expected_process_identity":"gateway:4242:100","confirmed_active_sessions":1,"active_sessions_known":true,"operation_id":"op-38","session_identity":"scope-gateway","target_identity":"gateway:restart:gateway:4242:100","session_generation":4}"#,
        ] {
            let request = emulator_request_from_json(payload).expect("valid Gateway mutation should parse");
            assert!(
                crate::server::emulator::remote::authorize_request(&request, true, true, None)
                    .is_ok()
            );
            assert!(
                crate::server::emulator::remote::authorize_request(&request, true, false, None)
                    .is_err()
            );
            assert!(
                crate::server::emulator::remote::authorize_host_operation(
                    &request,
                    "scope-gateway",
                    4
                )
                .is_ok()
            );
        }

        assert!(emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":39,"action":"gateway_restart","expected_process_identity":"gateway:4242:100","operation_id":"op-39","session_identity":"scope-gateway","target_identity":"gateway:restart:gateway:9999:100","session_generation":4}"#
        )
        .is_none());
    }

    #[test]
    fn window_focus_is_control_gated_and_operation_bound() {
        let request = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":32,"action":"window_focus","window_id":"win-opaque-a","desktop_generation":7,"operation_id":"op-32","session_identity":"scope-window","target_identity":"window:win-opaque-a:7","session_generation":4}"#,
        )
        .expect("opaque window focus should parse as a typed host mutation");

        assert!(matches!(
            request.union,
            Some(emulator_request::Union::Host(ref host)) if host.action == "window_focus"
        ));
        assert!(
            crate::server::emulator::remote::authorize_request(&request, true, true, None).is_ok()
        );
        assert!(
            crate::server::emulator::remote::authorize_request(&request, true, false, None)
                .is_err(),
            "focus changes host foreground state and requires control permission"
        );
        assert!(crate::server::emulator::remote::authorize_host_operation(
            &request,
            "scope-window",
            4
        )
        .is_ok());

        let forged = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":33,"action":"window_focus","window_id":"win-opaque-a","desktop_generation":7,"operation_id":"op-33","session_identity":"scope-window","target_identity":"window:win-other:7","session_generation":4}"#,
        );
        assert!(
            forged.is_none(),
            "a forged opaque target identity must be rejected"
        );
    }

    #[test]
    fn phone_workspace_support_is_read_only_and_mutations_are_operation_bound() {
        let support = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":41,"action":"phone_workspace_support"}"#,
        )
        .expect("support query should use the bounded host-management path");
        assert!(
            crate::server::emulator::remote::authorize_request(&support, true, false, None).is_ok()
        );

        let begin = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":42,"action":"phone_workspace_begin","display_width":1080,"display_height":2400,"display_dpi":0,"display_orientation":"portrait","operation_id":"op-42","session_identity":"scope-phone","target_identity":"phone-workspace:new:1080x2400:portrait:0","session_generation":4}"#,
        )
        .expect("a valid owned-display request should parse");
        assert!(
            crate::server::emulator::remote::authorize_request(&begin, true, true, None).is_ok()
        );
        assert!(
            crate::server::emulator::remote::authorize_request(&begin, true, false, None).is_err(),
            "creating a display changes host state and requires control permission"
        );
        assert!(crate::server::emulator::remote::authorize_host_operation(
            &begin,
            "scope-phone",
            4
        )
        .is_ok());

        assert!(
            emulator_request_from_json(
                r#"{"protocol_version":1,"request_id":43,"action":"phone_workspace_begin","display_width":1080,"display_height":2400,"display_dpi":420,"display_orientation":"portrait","operation_id":"op-43","session_identity":"scope-phone","target_identity":"phone-workspace:new:1080x2400:portrait:420","session_generation":4}"#,
            )
            .is_none(),
            "unsupported custom DPI must fail before dispatch"
        );
        assert!(
            emulator_request_from_json(
                r#"{"protocol_version":1,"request_id":44,"action":"phone_workspace_begin","display_width":1080,"display_height":2400,"display_dpi":0,"display_orientation":"portrait","operation_id":"op-44","session_identity":"scope-phone","target_identity":"phone-workspace:new:2400x1080:landscape:0","session_generation":4}"#,
            )
            .is_none(),
            "a forged display profile target identity must fail before dispatch"
        );

        let end = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":45,"action":"phone_workspace_end","owned_display_id":"phone-workspace-abc","operation_id":"op-45","session_identity":"scope-phone","target_identity":"phone-workspace:phone-workspace-abc","session_generation":4}"#,
        )
        .expect("owned cleanup should parse with an exact display identity");
        assert!(
            crate::server::emulator::remote::authorize_host_operation(&end, "scope-phone", 4)
                .is_ok()
        );
    }
}
