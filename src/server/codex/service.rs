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
        rpc::RpcCallError, CodexBridge, CodexEvent as BridgeEvent,
        CodexEventKind as BridgeEventKind, CodexHistoryItemKind as BridgeHistoryKind,
        CodexThreadStatus,
    };
    use crate::server::connection::Sender;
    use base::message_proto::{
        codex_read_request, codex_read_response, CodexError, CodexEvent, CodexEventKind,
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
    const MAX_CURSOR_BYTES: usize = 4096;

    enum ServiceCommand {
        Read {
            connection_id: i32,
            request: CodexReadRequest,
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
                let result = with_bridge(bridge, codex_version, |bridge| bridge.list_threads());
                match result {
                    Ok(threads) => {
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
                let result = with_bridge(bridge, codex_version, |bridge| {
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
            None => send_error(&reply, &request_id, "Codex read request is empty", ""),
            Some(_) => send_error(
                &reply,
                &request_id,
                "Unsupported Codex read request type",
                "",
            ),
        }
    }

    fn with_bridge<T>(
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        mut operation: impl FnMut(&mut CodexBridge) -> Result<T, RpcCallError>,
    ) -> Result<T, String> {
        let mut last_error = String::new();
        for _ in 0..2 {
            if bridge.is_none() {
                match super::super::discover_installation() {
                    Ok(Some(installation)) => match CodexBridge::connect(&installation) {
                        Ok(connected) => {
                            *codex_version = installation.version;
                            *bridge = Some(connected);
                        }
                        Err(error) => {
                            last_error = error.to_string();
                            continue;
                        }
                    },
                    Ok(None) => return Err("Codex is not installed for this Windows user".into()),
                    Err(error) => return Err(error.to_string()),
                }
            }

            let Some(active) = bridge.as_mut() else {
                continue;
            };
            match operation(active) {
                Ok(result) => return Ok(result),
                Err(error) => {
                    last_error = error.to_string();
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

    fn drain_and_broadcast(
        bridge: &mut Option<CodexBridge>,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
    ) {
        if subscribers.is_empty() {
            return;
        }
        let Some(active) = bridge.as_mut() else {
            return;
        };

        match active.drain_events() {
            Ok(events) => {
                for event in events {
                    let Some(targets) = subscribers.get_mut(&event.thread_id) else {
                        continue;
                    };
                    let response = event_response(event);
                    targets.retain(|_, sender| send_response(sender, response.clone()));
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

    fn send_response(reply: &Sender, response: CodexReadResponse) -> bool {
        let mut message = Message::new();
        message.set_codex_read_response(response);
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
pub(crate) use windows::{disconnect_client, submit_read_request};
