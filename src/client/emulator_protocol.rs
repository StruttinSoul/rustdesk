use base::message_proto::{
    EmulatorDesktopRequest, EmulatorHostRequest, EmulatorKey, EmulatorListRequest,
    EmulatorNavigation, EmulatorPreviewRequest, EmulatorRequest, EmulatorSelectRequest,
    EmulatorTouch,
};

pub fn emulator_request_from_json(payload: &str) -> Option<EmulatorRequest> {
    if payload.len() > 4096 {
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
        "process_end" => request.set_host(EmulatorHostRequest {
            action: "process_end".to_owned(),
            pid: u32::try_from(value["pid"].as_u64()?).ok()?,
            ..Default::default()
        }),
        "recover" => request.set_host(EmulatorHostRequest {
            action: "recover".to_owned(),
            component: value["component"].as_str()?.to_owned(),
            ..Default::default()
        }),
        "previews" => request.set_previews(EmulatorPreviewRequest {
            enabled: value["enabled"].as_bool()?,
            target_ids: value["target_ids"].as_array()?.iter().map(|id| id.as_str().map(str::to_owned)).collect::<Option<Vec<_>>>()?,
            displays: value["displays"].as_array()?.iter().map(|id| u32::try_from(id.as_u64()?).ok()).collect::<Option<Vec<_>>>()?,
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
        let request = emulator_request_from_json(r#"{"protocol_version":1,"request_id":8,"action":"previews","enabled":true,"target_ids":["bluestacks:Tiramisu64"],"displays":[0,1]}"#);
        assert!(request.is_some(), "The dashboard must subscribe to actual guest and monitor video");
        let request = request.unwrap();
        assert!(crate::server::emulator::remote::authorize_request(&request, true, false, None).is_ok());
        assert!(crate::server::emulator::remote::authorize_request(&request, false, true, None).is_err());
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
        assert!(crate::server::emulator::remote::authorize_request(
            &status, true, false, None
        )
        .is_ok());

        let end = emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":12,"action":"process_end","pid":1234}"#,
        )
        .unwrap();
        assert!(crate::server::emulator::remote::authorize_request(
            &end, true, false, None
        )
        .is_err());
        assert!(crate::server::emulator::remote::authorize_request(
            &end, true, true, None
        )
        .is_ok());

        assert!(emulator_request_from_json(
            r#"{"protocol_version":1,"request_id":13,"action":"recover","component":"arbitrary_service"}"#
        )
        .is_none());
    }
}
