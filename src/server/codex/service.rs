use super::discovery;

pub fn is_available() -> bool {
    #[cfg(target_os = "windows")]
    {
        discovery::installation_present()
    }
    #[cfg(not(target_os = "windows"))]
    {
        false
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use super::super::{
        rpc::RpcCallError, windows_app, CodexApproval as BridgeApproval,
        CodexApprovalDecision as BridgeApprovalDecision, CodexApprovalKind as BridgeApprovalKind,
        CodexBridge, CodexBridgeUpdate, CodexEvent as BridgeEvent,
        CodexEventKind as BridgeEventKind, CodexHistoryItemKind as BridgeHistoryKind,
        CodexResolvedApproval as BridgeResolvedApproval, CodexThreadStatus,
    };
    use crate::server::connection::Sender;
    use base::message_proto::{
        codex_control_request, codex_control_response, codex_read_request, codex_read_response,
        CodexApprovalDecision, CodexApprovalKind, CodexApprovalListResponse, CodexApprovalRequest,
        CodexApprovalResolved, CodexControlAction, CodexControlCapabilities, CodexControlRequest,
        CodexControlResponse, CodexControlResult, CodexError, CodexEvent, CodexEventKind,
        CodexHistoryItem, CodexHistoryKind, CodexReadRequest, CodexReadResponse, CodexState,
        CodexThreadHistoryResponse, CodexThreadInfo, CodexThreadListResponse, Message,
    };
    use hbb_common::{log, tokio::time::Instant as TokioInstant};
    use std::{
        collections::HashMap,
        sync::{mpsc, Arc, OnceLock},
        thread,
        time::Duration,
    };

    const POLL_INTERVAL: Duration = Duration::from_millis(50);
    const MAX_REQUEST_ID_BYTES: usize = 128;
    const MAX_THREAD_ID_BYTES: usize = 256;
    const MAX_TURN_ID_BYTES: usize = 256;
    const MAX_APPROVAL_ID_BYTES: usize = 256;
    const MAX_CURSOR_BYTES: usize = 4096;
    const MAX_INPUT_BYTES: usize = 131_072;

    enum ServiceCommand {
        Read {
            connection_id: i32,
            request: CodexReadRequest,
            reply: Sender,
        },
        Control {
            connection_id: i32,
            request: CodexControlRequest,
            reply: Sender,
        },
        Disconnect(i32),
    }

    struct ServiceHandle {
        sender: mpsc::Sender<ServiceCommand>,
    }

    static SERVICE: OnceLock<ServiceHandle> = OnceLock::new();

    pub(crate) fn submit_read_request(
        connection_id: i32,
        request: CodexReadRequest,
        reply: Sender,
    ) {
        let command = ServiceCommand::Read {
            connection_id,
            request,
            reply: reply.clone(),
        };
        if service().sender.send(command).is_err() {
            send_error(&reply, "", "Codex read service is unavailable", "");
        }
    }

    pub(crate) fn disconnect_client(connection_id: i32) {
        if let Some(service) = SERVICE.get() {
            let _ = service
                .sender
                .send(ServiceCommand::Disconnect(connection_id));
        }
    }

    pub(crate) fn submit_control_request(
        connection_id: i32,
        request: CodexControlRequest,
        reply: Sender,
    ) {
        let command = ServiceCommand::Control {
            connection_id,
            request,
            reply: reply.clone(),
        };
        if service().sender.send(command).is_err() {
            send_control_error(&reply, "", "Codex control service is unavailable", "");
        }
    }

    fn service() -> &'static ServiceHandle {
        SERVICE.get_or_init(|| {
            let (sender, receiver) = mpsc::channel();
            thread::Builder::new()
                .name("codex-read-service".into())
                .spawn(move || worker_loop(receiver))
                .expect("failed to start Codex read service worker");
            ServiceHandle { sender }
        })
    }

    fn worker_loop(receiver: mpsc::Receiver<ServiceCommand>) {
        let mut bridge: Option<CodexBridge> = None;
        let mut codex_version = String::new();
        let mut subscribers: HashMap<String, HashMap<i32, Sender>> = HashMap::new();

        loop {
            match receiver.recv_timeout(POLL_INTERVAL) {
                Ok(ServiceCommand::Read {
                    connection_id,
                    request,
                    reply,
                }) => handle_request(
                    connection_id,
                    request,
                    reply,
                    &mut bridge,
                    &mut codex_version,
                    &mut subscribers,
                ),
                Ok(ServiceCommand::Control {
                    connection_id,
                    request,
                    reply,
                }) => handle_control_request(
                    connection_id,
                    request,
                    reply,
                    &mut bridge,
                    &mut codex_version,
                    &mut subscribers,
                ),
                Ok(ServiceCommand::Disconnect(connection_id)) => {
                    remove_connection(&mut subscribers, connection_id)
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }

            drain_and_broadcast(&mut bridge, &mut subscribers);
        }
    }

    fn handle_request(
        connection_id: i32,
        request: CodexReadRequest,
        reply: Sender,
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
    ) {
        let request_id = request.request_id.clone();
        if request_id.len() > MAX_REQUEST_ID_BYTES {
            send_error(&reply, &request_id, "Codex request id is too long", "");
            return;
        }

        match request.union {
            Some(codex_read_request::Union::ListThreads(_)) => {
                let result =
                    with_bridge_read(bridge, codex_version, |bridge| bridge.list_threads());
                match result {
                    Ok(threads) => {
                        let control = bridge
                            .as_ref()
                            .map(|bridge| bridge.control_support())
                            .unwrap_or_default();
                        let response = CodexThreadListResponse {
                            threads: threads
                                .into_iter()
                                .map(|thread| CodexThreadInfo {
                                    id: thread.id,
                                    title: thread.name.unwrap_or_default(),
                                    project: String::new(),
                                    originator: thread.originator.unwrap_or_default(),
                                    updated_at: thread.updated_at,
                                    state: map_state(thread.status).into(),
                                    ..Default::default()
                                })
                                .collect(),
                            service_state: CodexState::CodexReady.into(),
                            codex_version: codex_version.clone(),
                            control: hbb_common::protobuf::MessageField::some(
                                CodexControlCapabilities {
                                    resume_thread: control.resume_thread,
                                    start_thread: control.start_thread,
                                    start_turn: control.start_turn,
                                    steer_turn: control.steer_turn,
                                    interrupt_turn: control.interrupt_turn,
                                    approvals: true,
                                    open_windows_app: true,
                                    ..Default::default()
                                },
                            ),
                            ..Default::default()
                        };
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::ThreadList(response)),
                                ..Default::default()
                            },
                        );
                    }
                    Err(error) => send_error(&reply, &request_id, &error, ""),
                }
            }
            Some(codex_read_request::Union::ThreadHistory(history)) => {
                if let Err(error) = validate_thread_id(&history.thread_id) {
                    send_error(&reply, &request_id, error, &history.thread_id);
                    return;
                }
                if history.cursor.len() > MAX_CURSOR_BYTES {
                    send_error(
                        &reply,
                        &request_id,
                        "Codex history cursor is too long",
                        &history.thread_id,
                    );
                    return;
                }
                let thread_id = history.thread_id.clone();
                let cursor = (!history.cursor.is_empty()).then_some(history.cursor.as_str());
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    bridge.thread_history(&thread_id, cursor, history.limit)
                });
                match result {
                    Ok(page) => {
                        let response = CodexThreadHistoryResponse {
                            thread_id,
                            items: page
                                .items
                                .into_iter()
                                .map(|item| CodexHistoryItem {
                                    id: item.id,
                                    turn_id: item.turn_id,
                                    kind: map_history_kind(item.kind).into(),
                                    text: item.text,
                                    detail: item.detail,
                                    status: item.status,
                                    ..Default::default()
                                })
                                .collect(),
                            next_cursor: page.next_cursor.unwrap_or_default(),
                            ..Default::default()
                        };
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::ThreadHistory(response)),
                                ..Default::default()
                            },
                        );
                    }
                    Err(error) => send_error(&reply, &request_id, &error, &thread_id),
                }
            }
            Some(codex_read_request::Union::EventSubscription(subscription)) => {
                if let Err(error) = validate_thread_id(&subscription.thread_id) {
                    send_error(&reply, &request_id, error, &subscription.thread_id);
                    return;
                }
                if subscription.subscribe {
                    subscribers
                        .entry(subscription.thread_id)
                        .or_default()
                        .insert(connection_id, reply);
                } else if let Some(thread_subscribers) =
                    subscribers.get_mut(&subscription.thread_id)
                {
                    thread_subscribers.remove(&connection_id);
                    if thread_subscribers.is_empty() {
                        subscribers.remove(&subscription.thread_id);
                    }
                }
            }
            Some(codex_read_request::Union::ListApprovals(list)) => {
                if let Err(error) = validate_thread_id(&list.thread_id) {
                    send_error(&reply, &request_id, error, &list.thread_id);
                    return;
                }
                let thread_id = list.thread_id;
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    Ok(bridge.pending_approvals(&thread_id))
                });
                match result {
                    Ok(approvals) => {
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::ApprovalList(
                                    CodexApprovalListResponse {
                                        thread_id,
                                        approvals: approvals
                                            .into_iter()
                                            .map(approval_message)
                                            .collect(),
                                        ..Default::default()
                                    },
                                )),
                                ..Default::default()
                            },
                        );
                    }
                    Err(error) => send_error(&reply, &request_id, &error, &thread_id),
                }
            }
            None => send_error(&reply, &request_id, "Codex read request is empty", ""),
            Some(_) => send_error(
                &reply,
                &request_id,
                "Unsupported Codex read request type",
                "",
            ),
        }
    }

    fn handle_control_request(
        _connection_id: i32,
        request: CodexControlRequest,
        reply: Sender,
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
    ) {
        let request_id = request.request_id.clone();
        if request_id.len() > MAX_REQUEST_ID_BYTES {
            send_control_error(&reply, &request_id, "Codex request id is too long", "");
            return;
        }

        let result = match request.union {
            Some(codex_control_request::Union::ResumeThread(resume)) => {
                if let Err(error) = validate_thread_id(&resume.thread_id) {
                    send_control_error(&reply, &request_id, error, &resume.thread_id);
                    return;
                }
                let thread_id = resume.thread_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.resume_thread(&thread_id)
                })
                .map(|outcome| {
                    control_result(
                        CodexControlAction::CodexControlThreadResumed,
                        outcome.thread_id,
                        outcome.turn_id,
                        map_state(outcome.status),
                    )
                })
                .map_err(|error| (error, thread_id))
            }
            Some(codex_control_request::Union::StartThread(start)) => {
                if !start.workspace_thread_id.is_empty() {
                    if let Err(error) = validate_thread_id(&start.workspace_thread_id) {
                        send_control_error(&reply, &request_id, error, &start.workspace_thread_id);
                        return;
                    }
                }
                let workspace_thread_id = start.workspace_thread_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.start_thread(
                        (!workspace_thread_id.is_empty()).then_some(workspace_thread_id.as_str()),
                    )
                })
                .map(|outcome| {
                    control_result(
                        CodexControlAction::CodexControlThreadStarted,
                        outcome.thread_id,
                        outcome.turn_id,
                        map_state(outcome.status),
                    )
                })
                .map_err(|error| (error, workspace_thread_id))
            }
            Some(codex_control_request::Union::StartTurn(start)) => {
                if let Err(error) = validate_thread_id(&start.thread_id) {
                    send_control_error(&reply, &request_id, error, &start.thread_id);
                    return;
                }
                if let Err(error) = validate_input(&start.text) {
                    send_control_error(&reply, &request_id, error, &start.thread_id);
                    return;
                }
                let thread_id = start.thread_id;
                let text = start.text;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.start_turn(&thread_id, &text)
                })
                .map(|outcome| {
                    control_result(
                        CodexControlAction::CodexControlTurnStarted,
                        outcome.thread_id,
                        outcome.turn_id,
                        CodexState::CodexWorking,
                    )
                })
                .map_err(|error| (error, thread_id))
            }
            Some(codex_control_request::Union::SteerTurn(steer)) => {
                if let Err(error) = validate_thread_id(&steer.thread_id) {
                    send_control_error(&reply, &request_id, error, &steer.thread_id);
                    return;
                }
                if let Err(error) = validate_turn_id(&steer.turn_id) {
                    send_control_error(&reply, &request_id, error, &steer.thread_id);
                    return;
                }
                if let Err(error) = validate_input(&steer.text) {
                    send_control_error(&reply, &request_id, error, &steer.thread_id);
                    return;
                }
                let thread_id = steer.thread_id;
                let turn_id = steer.turn_id;
                let text = steer.text;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.steer_turn(&thread_id, &turn_id, &text)
                })
                .map(|outcome| {
                    control_result(
                        CodexControlAction::CodexControlTurnSteered,
                        outcome.thread_id,
                        outcome.turn_id,
                        CodexState::CodexWorking,
                    )
                })
                .map_err(|error| (error, thread_id))
            }
            Some(codex_control_request::Union::InterruptTurn(interrupt)) => {
                if let Err(error) = validate_thread_id(&interrupt.thread_id) {
                    send_control_error(&reply, &request_id, error, &interrupt.thread_id);
                    return;
                }
                if let Err(error) = validate_turn_id(&interrupt.turn_id) {
                    send_control_error(&reply, &request_id, error, &interrupt.thread_id);
                    return;
                }
                let thread_id = interrupt.thread_id;
                let turn_id = interrupt.turn_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.interrupt_turn(&thread_id, &turn_id)
                })
                .map(|()| {
                    control_result(
                        CodexControlAction::CodexControlTurnInterrupted,
                        thread_id.clone(),
                        turn_id,
                        CodexState::CodexInterrupting,
                    )
                })
                .map_err(|error| (error, thread_id))
            }
            Some(codex_control_request::Union::RespondApproval(approval)) => {
                if let Err(error) = validate_approval_id(&approval.approval_id) {
                    send_control_error(&reply, &request_id, error, &approval.thread_id);
                    return;
                }
                if let Err(error) = validate_thread_id(&approval.thread_id) {
                    send_control_error(&reply, &request_id, error, &approval.thread_id);
                    return;
                }
                if let Err(error) = validate_turn_id(&approval.turn_id) {
                    send_control_error(&reply, &request_id, error, &approval.thread_id);
                    return;
                }
                let decision = match approval.decision.enum_value_or_default() {
                    CodexApprovalDecision::CodexApprovalApprove => BridgeApprovalDecision::Approve,
                    CodexApprovalDecision::CodexApprovalDeny => BridgeApprovalDecision::Deny,
                    CodexApprovalDecision::CodexApprovalDecisionUnknown => {
                        send_control_error(
                            &reply,
                            &request_id,
                            "Codex approval decision is required",
                            &approval.thread_id,
                        );
                        return;
                    }
                };
                let approval_id = approval.approval_id;
                let thread_id = approval.thread_id;
                let turn_id = approval.turn_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.respond_to_approval(&approval_id, &thread_id, &turn_id, decision)
                })
                .map(|resolved| {
                    broadcast_approval_resolved(subscribers, &resolved);
                    control_result(
                        match decision {
                            BridgeApprovalDecision::Approve => {
                                CodexControlAction::CodexControlApprovalApproved
                            }
                            BridgeApprovalDecision::Deny => {
                                CodexControlAction::CodexControlApprovalDenied
                            }
                        },
                        resolved.thread_id,
                        resolved.turn_id,
                        CodexState::CodexWorking,
                    )
                })
                .map_err(|error| (error, thread_id))
            }
            Some(codex_control_request::Union::OpenWindowsApp(open)) => {
                if !open.thread_id.is_empty() {
                    if let Err(error) = validate_thread_id(&open.thread_id) {
                        send_control_error(&reply, &request_id, error, &open.thread_id);
                        return;
                    }
                }
                let thread_id = open.thread_id;
                windows_app::open_windows_app()
                    .map(|()| {
                        control_result(
                            CodexControlAction::CodexControlWindowsAppOpened,
                            thread_id.clone(),
                            String::new(),
                            CodexState::CodexReady,
                        )
                    })
                    .map_err(|error| (error, thread_id))
            }
            None => {
                send_control_error(&reply, &request_id, "Codex control request is empty", "");
                return;
            }
            Some(_) => {
                send_control_error(
                    &reply,
                    &request_id,
                    "Unsupported Codex control request type",
                    "",
                );
                return;
            }
        };

        match result {
            Ok(result) => {
                send_control_response(
                    &reply,
                    CodexControlResponse {
                        request_id,
                        union: Some(codex_control_response::Union::Result(result)),
                        ..Default::default()
                    },
                );
            }
            Err((error, thread_id)) => {
                if bridge.is_none() {
                    broadcast_disconnected(subscribers);
                }
                send_control_error(&reply, &request_id, &error, &thread_id);
            }
        }
    }

    fn with_bridge_read<T>(
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        mut operation: impl FnMut(&mut CodexBridge) -> Result<T, RpcCallError>,
    ) -> Result<T, String> {
        let mut last_error = String::new();
        for _ in 0..2 {
            if bridge.is_none() {
                if let Err(error) = connect_bridge(bridge, codex_version) {
                    last_error = error;
                    continue;
                }
            }

            let Some(active) = bridge.as_mut() else {
                continue;
            };
            match operation(active) {
                Ok(result) => return Ok(result),
                Err(error) => {
                    last_error = public_rpc_error(&error);
                    if error.should_reconnect() {
                        *bridge = None;
                    } else {
                        return Err(last_error);
                    }
                }
            }
        }
        if last_error.is_empty() {
            last_error = "Codex app-server is unavailable".into();
        }
        Err(last_error)
    }

    fn with_bridge_mutation<T>(
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        operation: impl FnOnce(&mut CodexBridge) -> Result<T, RpcCallError>,
    ) -> Result<T, String> {
        if bridge.is_none() {
            connect_bridge(bridge, codex_version)?;
        }
        let Some(active) = bridge.as_mut() else {
            return Err("Codex app-server is unavailable".into());
        };
        let result = operation(active);
        finish_mutation_once(bridge, result)
    }

    fn finish_mutation_once<B, T>(
        bridge: &mut Option<B>,
        result: Result<T, RpcCallError>,
    ) -> Result<T, String> {
        match result {
            Ok(result) => Ok(result),
            Err(error) => {
                let reconnect = error.should_reconnect();
                let message = public_rpc_error(&error);
                if reconnect {
                    // Never retry a mutating request. The write may have reached Codex even
                    // when the response transport failed, so retrying could duplicate work.
                    *bridge = None;
                }
                Err(message)
            }
        }
    }

    fn connect_bridge(
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
    ) -> Result<(), String> {
        match super::super::discover_installation() {
            Ok(Some(installation)) => match CodexBridge::connect(&installation) {
                Ok(connected) => {
                    *codex_version = installation.version;
                    *bridge = Some(connected);
                    Ok(())
                }
                Err(_) => Err("Unable to connect to the Codex app-server".into()),
            },
            Ok(None) => Err("Codex is not installed for this Windows user".into()),
            Err(_) => Err("Unable to discover the local Codex installation".into()),
        }
    }

    fn public_rpc_error(error: &RpcCallError) -> String {
        match error {
            RpcCallError::Io(_) => "Codex app-server I/O failed".into(),
            RpcCallError::Protocol(_) => "Codex app-server returned an unexpected response".into(),
            RpcCallError::Remote { code, .. } => {
                format!("Codex app-server rejected the request (RPC {code})")
            }
            RpcCallError::Timeout => "Timed out waiting for Codex app-server response".into(),
            RpcCallError::Disconnected => "Codex app-server stream disconnected".into(),
        }
    }

    fn drain_and_broadcast(
        bridge: &mut Option<CodexBridge>,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
    ) {
        let Some(active) = bridge.as_mut() else {
            return;
        };

        match active.drain_updates() {
            Ok(updates) => {
                for update in updates {
                    match update {
                        CodexBridgeUpdate::Event(event) => {
                            let Some(targets) = subscribers.get_mut(&event.thread_id) else {
                                continue;
                            };
                            let response = event_response(event);
                            targets.retain(|_, sender| send_response(sender, response.clone()));
                        }
                        CodexBridgeUpdate::ApprovalRequested(approval) => {
                            let Some(targets) = subscribers.get_mut(&approval.thread_id) else {
                                continue;
                            };
                            let response = CodexReadResponse {
                                request_id: String::new(),
                                union: Some(codex_read_response::Union::Approval(
                                    approval_message(approval),
                                )),
                                ..Default::default()
                            };
                            targets.retain(|_, sender| send_response(sender, response.clone()));
                        }
                    }
                }
            }
            Err(error) => {
                log::debug!("Codex event stream disconnected: {error}");
                *bridge = None;
                broadcast_disconnected(subscribers);
            }
        }
    }

    fn broadcast_disconnected(subscribers: &mut HashMap<String, HashMap<i32, Sender>>) {
        subscribers.retain(|thread_id, targets| {
            let response = CodexReadResponse {
                request_id: String::new(),
                union: Some(codex_read_response::Union::Event(CodexEvent {
                    thread_id: thread_id.clone(),
                    kind: CodexEventKind::CodexEventThreadState.into(),
                    state: CodexState::CodexDisconnected.into(),
                    status: "disconnected".into(),
                    ..Default::default()
                })),
                ..Default::default()
            };
            targets.retain(|_, sender| send_response(sender, response.clone()));
            !targets.is_empty()
        });
    }

    fn event_response(event: BridgeEvent) -> CodexReadResponse {
        CodexReadResponse {
            request_id: String::new(),
            union: Some(codex_read_response::Union::Event(CodexEvent {
                thread_id: event.thread_id,
                turn_id: event.turn_id,
                item_id: event.item_id,
                kind: map_event_kind(event.kind).into(),
                state: event
                    .state
                    .map(map_state)
                    .unwrap_or(CodexState::CodexUnavailable)
                    .into(),
                history_kind: event
                    .history_kind
                    .map(map_history_kind)
                    .unwrap_or(CodexHistoryKind::CodexHistoryUnknown)
                    .into(),
                text: event.text,
                status: event.status,
                ..Default::default()
            })),
            ..Default::default()
        }
    }

    fn approval_message(approval: BridgeApproval) -> CodexApprovalRequest {
        CodexApprovalRequest {
            approval_id: approval.id,
            thread_id: approval.thread_id,
            turn_id: approval.turn_id,
            item_id: approval.item_id,
            kind: match approval.kind {
                BridgeApprovalKind::Command => CodexApprovalKind::CodexApprovalCommand,
                BridgeApprovalKind::FileChange => CodexApprovalKind::CodexApprovalFileChange,
                BridgeApprovalKind::Permissions => CodexApprovalKind::CodexApprovalPermissions,
            }
            .into(),
            title: approval.title,
            summary: approval.summary,
            reason: approval.reason,
            started_at_ms: approval.started_at_ms,
            actionable: approval.actionable,
            ..Default::default()
        }
    }

    fn broadcast_approval_resolved(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        resolved: &BridgeResolvedApproval,
    ) {
        let Some(targets) = subscribers.get_mut(&resolved.thread_id) else {
            return;
        };
        let response = CodexReadResponse {
            request_id: String::new(),
            union: Some(codex_read_response::Union::ApprovalResolved(
                CodexApprovalResolved {
                    approval_id: resolved.id.clone(),
                    thread_id: resolved.thread_id.clone(),
                    turn_id: resolved.turn_id.clone(),
                    decision: match resolved.decision {
                        BridgeApprovalDecision::Approve => {
                            CodexApprovalDecision::CodexApprovalApprove
                        }
                        BridgeApprovalDecision::Deny => CodexApprovalDecision::CodexApprovalDeny,
                    }
                    .into(),
                    ..Default::default()
                },
            )),
            ..Default::default()
        };
        targets.retain(|_, sender| send_response(sender, response.clone()));
    }

    fn send_error(reply: &Sender, request_id: &str, message: &str, thread_id: &str) {
        let response = CodexReadResponse {
            request_id: request_id.to_owned(),
            union: Some(codex_read_response::Union::Error(CodexError {
                thread_id: thread_id.to_owned(),
                message: message.to_owned(),
                ..Default::default()
            })),
            ..Default::default()
        };
        let _ = send_response(reply, response);
    }

    fn send_control_error(reply: &Sender, request_id: &str, message: &str, thread_id: &str) {
        send_control_response(
            reply,
            CodexControlResponse {
                request_id: request_id.to_owned(),
                union: Some(codex_control_response::Union::Error(CodexError {
                    thread_id: thread_id.to_owned(),
                    message: message.to_owned(),
                    ..Default::default()
                })),
                ..Default::default()
            },
        );
    }

    fn control_result(
        action: CodexControlAction,
        thread_id: String,
        turn_id: String,
        state: CodexState,
    ) -> CodexControlResult {
        CodexControlResult {
            action: action.into(),
            thread_id,
            turn_id,
            state: state.into(),
            ..Default::default()
        }
    }

    fn send_response(reply: &Sender, response: CodexReadResponse) -> bool {
        let mut message = Message::new();
        message.set_codex_read_response(response);
        reply.send((TokioInstant::now(), Arc::new(message))).is_ok()
    }

    fn send_control_response(reply: &Sender, response: CodexControlResponse) -> bool {
        let mut message = Message::new();
        message.set_codex_control_response(response);
        reply.send((TokioInstant::now(), Arc::new(message))).is_ok()
    }

    fn remove_connection(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        connection_id: i32,
    ) {
        subscribers.retain(|_, targets| {
            targets.remove(&connection_id);
            !targets.is_empty()
        });
    }

    fn validate_thread_id(thread_id: &str) -> Result<(), &'static str> {
        if thread_id.is_empty() {
            Err("Codex thread id is required")
        } else if thread_id.len() > MAX_THREAD_ID_BYTES {
            Err("Codex thread id is too long")
        } else {
            Ok(())
        }
    }

    fn validate_turn_id(turn_id: &str) -> Result<(), &'static str> {
        if turn_id.is_empty() {
            Err("Codex turn id is required")
        } else if turn_id.len() > MAX_TURN_ID_BYTES {
            Err("Codex turn id is too long")
        } else {
            Ok(())
        }
    }

    fn validate_approval_id(approval_id: &str) -> Result<(), &'static str> {
        if approval_id.is_empty() {
            Err("Codex approval id is required")
        } else if approval_id.len() > MAX_APPROVAL_ID_BYTES {
            Err("Codex approval id is too long")
        } else {
            Ok(())
        }
    }

    fn validate_input(text: &str) -> Result<(), &'static str> {
        if text.trim().is_empty() {
            Err("Codex input is required")
        } else if text.len() > MAX_INPUT_BYTES {
            Err("Codex input is too long")
        } else {
            Ok(())
        }
    }

    fn map_state(status: CodexThreadStatus) -> CodexState {
        match status {
            CodexThreadStatus::Resumable => CodexState::CodexResumable,
            CodexThreadStatus::Idle => CodexState::CodexIdle,
            CodexThreadStatus::Working => CodexState::CodexWorking,
            CodexThreadStatus::WaitingForApproval => CodexState::CodexWaitingForApproval,
            CodexThreadStatus::WaitingForInput => CodexState::CodexWaitingForInput,
            CodexThreadStatus::Failed => CodexState::CodexFailed,
            CodexThreadStatus::Unknown => CodexState::CodexReady,
        }
    }

    fn map_history_kind(kind: BridgeHistoryKind) -> CodexHistoryKind {
        match kind {
            BridgeHistoryKind::Unknown => CodexHistoryKind::CodexHistoryUnknown,
            BridgeHistoryKind::UserMessage => CodexHistoryKind::CodexHistoryUserMessage,
            BridgeHistoryKind::AgentMessage => CodexHistoryKind::CodexHistoryAgentMessage,
            BridgeHistoryKind::Plan => CodexHistoryKind::CodexHistoryPlan,
            BridgeHistoryKind::Reasoning => CodexHistoryKind::CodexHistoryReasoning,
            BridgeHistoryKind::Command => CodexHistoryKind::CodexHistoryCommand,
            BridgeHistoryKind::FileChange => CodexHistoryKind::CodexHistoryFileChange,
            BridgeHistoryKind::Tool => CodexHistoryKind::CodexHistoryTool,
            BridgeHistoryKind::WebSearch => CodexHistoryKind::CodexHistoryWebSearch,
            BridgeHistoryKind::Status => CodexHistoryKind::CodexHistoryStatus,
        }
    }

    fn map_event_kind(kind: BridgeEventKind) -> CodexEventKind {
        match kind {
            BridgeEventKind::ThreadState => CodexEventKind::CodexEventThreadState,
            BridgeEventKind::ItemStarted => CodexEventKind::CodexEventItemStarted,
            BridgeEventKind::ItemUpdated => CodexEventKind::CodexEventItemUpdated,
            BridgeEventKind::ItemCompleted => CodexEventKind::CodexEventItemCompleted,
            BridgeEventKind::TurnStarted => CodexEventKind::CodexEventTurnStarted,
            BridgeEventKind::TurnCompleted => CodexEventKind::CodexEventTurnCompleted,
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use hbb_common::protobuf::Message as _;

        #[test]
        fn rejects_empty_and_oversized_thread_ids() {
            assert_eq!(validate_thread_id(""), Err("Codex thread id is required"));
            assert_eq!(
                validate_thread_id(&"x".repeat(MAX_THREAD_ID_BYTES + 1)),
                Err("Codex thread id is too long")
            );
            assert!(validate_thread_id("thr_123").is_ok());
        }

        #[test]
        fn rejects_empty_and_oversized_turn_ids_and_inputs() {
            assert_eq!(validate_turn_id(""), Err("Codex turn id is required"));
            assert_eq!(
                validate_turn_id(&"x".repeat(MAX_TURN_ID_BYTES + 1)),
                Err("Codex turn id is too long")
            );
            assert!(validate_turn_id("turn_123").is_ok());

            assert_eq!(validate_input("  \n"), Err("Codex input is required"));
            assert_eq!(
                validate_input(&"x".repeat(MAX_INPUT_BYTES + 1)),
                Err("Codex input is too long")
            );
            assert!(validate_input("continue checkpoint 4").is_ok());
        }

        #[test]
        fn windows_app_handoff_request_round_trips_with_optional_thread_id() {
            let mut request = CodexControlRequest::new();
            request.request_id = "handoff-1".into();
            request.set_open_windows_app(base::message_proto::CodexOpenWindowsAppRequest {
                thread_id: "thr_desktop".into(),
                ..Default::default()
            });

            let bytes = request
                .write_to_bytes()
                .expect("handoff request should serialize");
            let decoded = CodexControlRequest::parse_from_bytes(&bytes)
                .expect("handoff request should deserialize");

            assert_eq!(decoded.request_id, "handoff-1");
            let Some(codex_control_request::Union::OpenWindowsApp(open)) = decoded.union else {
                panic!("expected Windows app handoff request");
            };
            assert_eq!(open.thread_id, "thr_desktop");
        }

        #[test]
        fn transport_failure_drops_bridge_after_exactly_one_mutation_attempt() {
            let mut bridge = Some(());
            let mut calls = 0;
            let result = {
                let active = bridge.as_mut().expect("test bridge should exist");
                let operation_result: Result<(), RpcCallError> = {
                    let _ = active;
                    calls += 1;
                    Err(RpcCallError::Disconnected)
                };
                finish_mutation_once(&mut bridge, operation_result)
            };

            assert_eq!(calls, 1);
            assert!(bridge.is_none());
            assert!(result
                .expect_err("transport failure should be surfaced")
                .contains("disconnected"));
        }

        #[test]
        fn protocol_failure_keeps_bridge_without_retrying_mutation() {
            let mut bridge = Some(());
            let mut calls = 0;
            let result = {
                let active = bridge.as_mut().expect("test bridge should exist");
                let operation_result: Result<(), RpcCallError> = {
                    let _ = active;
                    calls += 1;
                    Err(RpcCallError::Protocol("bad control response".into()))
                };
                finish_mutation_once(&mut bridge, operation_result)
            };

            assert_eq!(calls, 1);
            assert!(bridge.is_some());
            assert_eq!(
                result.expect_err("protocol failure should be surfaced"),
                "Codex app-server returned an unexpected response"
            );
        }

        #[test]
        fn public_rpc_errors_do_not_expose_remote_message_or_data() {
            let error = RpcCallError::Remote {
                code: -32600,
                message: r"failed under C:\Users\private\repo".into(),
                data: Some(serde_json::json!({"token": "secret"})),
            };

            let public = public_rpc_error(&error);
            assert_eq!(public, "Codex app-server rejected the request (RPC -32600)");
            assert!(!public.contains("Users"));
            assert!(!public.contains("secret"));
        }

        #[test]
        fn bridge_states_map_to_public_protocol_states() {
            assert_eq!(
                map_state(CodexThreadStatus::WaitingForApproval),
                CodexState::CodexWaitingForApproval
            );
            assert_eq!(
                map_state(CodexThreadStatus::Resumable),
                CodexState::CodexResumable
            );
            assert_eq!(
                map_state(CodexThreadStatus::Unknown),
                CodexState::CodexReady
            );
        }

        #[test]
        fn event_mapping_preserves_only_normalized_fields() {
            let response = event_response(BridgeEvent {
                thread_id: "thr_1".into(),
                turn_id: "turn_1".into(),
                item_id: "item_1".into(),
                kind: BridgeEventKind::ItemUpdated,
                state: None,
                history_kind: Some(BridgeHistoryKind::AgentMessage),
                text: "safe delta".into(),
                status: String::new(),
            });

            let Some(codex_read_response::Union::Event(event)) = response.union else {
                panic!("expected event response")
            };
            assert_eq!(event.thread_id, "thr_1");
            assert_eq!(event.text, "safe delta");
            assert_eq!(
                event.history_kind.enum_value(),
                Ok(CodexHistoryKind::CodexHistoryAgentMessage)
            );
        }
    }
}

#[cfg(target_os = "windows")]
pub(crate) use windows::{disconnect_client, submit_control_request, submit_read_request};
