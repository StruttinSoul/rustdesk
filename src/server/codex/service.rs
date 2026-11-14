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
        CodexWorkspace as BridgeWorkspace,
    };
    use crate::server::connection::Sender;
    use base::message_proto::{
        codex_control_request, codex_control_response, codex_read_request, codex_read_response,
        CodexApprovalDecision, CodexApprovalKind, CodexApprovalListResponse, CodexApprovalRequest,
        CodexApprovalResolved, CodexArtifactInfo, CodexArtifactListResponse, CodexControlAction,
        CodexControlCapabilities, CodexControlRequest, CodexControlResponse, CodexControlResult,
        CodexError, CodexEvent, CodexEventKind, CodexHistoryItem, CodexHistoryKind,
        CodexReadRequest, CodexReadResponse, CodexReviewTextResponse, CodexState,
        CodexTaskChangeInfo, CodexTaskChangeListResponse, CodexThreadHistoryResponse,
        CodexThreadInfo, CodexThreadListResponse, CodexWorkspaceInfo, CodexWorkspaceListResponse,
        Message,
    };
    use hbb_common::{log, tokio::time::Instant as TokioInstant};
    use sha2::{Digest, Sha256};
    use std::{
        collections::{HashMap, HashSet, VecDeque},
        sync::{mpsc, Arc, OnceLock},
        thread,
        time::Duration,
    };

    const POLL_INTERVAL: Duration = Duration::from_millis(50);
    const MAX_REQUEST_ID_BYTES: usize = 128;
    const MAX_THREAD_ID_BYTES: usize = 256;
    const MAX_TURN_ID_BYTES: usize = 256;
    const MAX_APPROVAL_ID_BYTES: usize = 256;
    const MAX_ITEM_ID_BYTES: usize = 256;
    const MAX_CURSOR_BYTES: usize = 4096;
    const MAX_INPUT_BYTES: usize = 131_072;
    const MAX_OPERATION_ID_BYTES: usize = 128;
    const MAX_SESSION_IDENTITY_BYTES: usize = 128;
    const MAX_TARGET_IDENTITY_BYTES: usize = 512;
    const MAX_WORKSPACE_ID_BYTES: usize = 256;
    const MAX_REVIEW_ID_BYTES: usize = 256;
    const MAX_WORKSPACE_PAGE_SIZE: usize = 100;
    const MAX_QUEUED_TURNS_PER_THREAD: usize = 32;
    const MAX_QUEUED_TURNS_TOTAL: usize = 128;
    const CONTROL_REPLAY_LIMIT: usize = 64;
    const COMPLETED_TURN_LIMIT: usize = 512;

    fn paginate_workspaces(
        workspaces: Vec<BridgeWorkspace>,
        cursor: &str,
        requested_limit: u32,
    ) -> Result<(Vec<BridgeWorkspace>, String), &'static str> {
        let snapshot = workspace_snapshot_id(&workspaces);
        let offset = if cursor.is_empty() {
            0usize
        } else {
            let mut parts = cursor.split(':');
            let prefix = parts.next();
            let cursor_snapshot = parts.next();
            let offset = parts.next();
            if prefix != Some("workspace") || parts.next().is_some() {
                return Err("Codex workspace cursor is invalid");
            }
            if cursor_snapshot != Some(snapshot.as_str()) {
                return Err("Codex workspace cursor is stale");
            }
            offset
                .and_then(|value| value.parse::<usize>().ok())
                .ok_or("Codex workspace cursor is invalid")?
        };
        if offset > workspaces.len() {
            return Err("Codex workspace cursor is stale");
        }
        let limit = if requested_limit == 0 {
            50
        } else {
            requested_limit as usize
        }
        .min(MAX_WORKSPACE_PAGE_SIZE);
        let end = offset.saturating_add(limit).min(workspaces.len());
        let next_cursor = if end < workspaces.len() {
            format!("workspace:{snapshot}:{end}")
        } else {
            String::new()
        };
        Ok((workspaces[offset..end].to_vec(), next_cursor))
    }

    fn workspace_snapshot_id(workspaces: &[BridgeWorkspace]) -> String {
        const OFFSET: u64 = 0xcbf29ce484222325;
        const PRIME: u64 = 0x100000001b3;
        let mut hash = OFFSET;
        for workspace in workspaces {
            for field in [
                workspace.id.as_str(),
                workspace.name.as_str(),
                workspace.path.as_str(),
                workspace.status.as_str(),
                if workspace.accessible { "1" } else { "0" },
            ] {
                for byte in field.as_bytes() {
                    hash ^= u64::from(*byte);
                    hash = hash.wrapping_mul(PRIME);
                }
                hash ^= 0xff;
                hash = hash.wrapping_mul(PRIME);
            }
        }
        format!("{hash:016x}")
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct CodexOperationKey {
        operation_id: String,
        session_identity: String,
        target_identity: String,
        session_generation: u64,
        action: String,
        payload_fingerprint: String,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct CodexConnectionScope {
        session_identity: String,
        session_generation: u64,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum ConnectionScopeUpdate {
        Invalid,
        Stale,
        Established,
        Unchanged,
        Changed,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct CodexApprovalBinding {
        connection_id: i32,
        session_identity: String,
        session_generation: u64,
        thread_id: String,
        turn_id: String,
        item_id: String,
        kind: BridgeApprovalKind,
    }

    impl CodexApprovalBinding {
        fn new(
            connection_id: i32,
            session_identity: &str,
            session_generation: u64,
            approval: &BridgeApproval,
        ) -> Self {
            Self {
                connection_id,
                session_identity: session_identity.to_owned(),
                session_generation,
                thread_id: approval.thread_id.clone(),
                turn_id: approval.turn_id.clone(),
                item_id: approval.item_id.clone(),
                kind: approval.kind,
            }
        }

        fn matches(
            &self,
            connection_id: i32,
            session_identity: &str,
            session_generation: u64,
            approval: &BridgeApproval,
        ) -> bool {
            self.connection_id == connection_id
                && self.session_identity == session_identity
                && self.session_generation == session_generation
                && self.thread_id == approval.thread_id
                && self.turn_id == approval.turn_id
                && self.item_id == approval.item_id
                && self.kind == approval.kind
        }
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct QueuedCodexTurn {
        connection_id: i32,
        session_identity: String,
        session_generation: u64,
        thread_id: String,
        operation_id: String,
        text: String,
    }

    #[derive(Default)]
    struct CompletedTurnTracker {
        keys: HashSet<(String, String)>,
        order: VecDeque<(String, String)>,
    }

    impl CompletedTurnTracker {
        fn contains(&self, thread_id: &str, turn_id: &str) -> bool {
            self.keys
                .contains(&(thread_id.to_owned(), turn_id.to_owned()))
        }

        fn remember(&mut self, thread_id: &str, turn_id: &str) {
            let key = (thread_id.to_owned(), turn_id.to_owned());
            if !self.keys.insert(key.clone()) {
                return;
            }
            self.order.push_back(key);
            while self.order.len() > COMPLETED_TURN_LIMIT {
                if let Some(oldest) = self.order.pop_front() {
                    self.keys.remove(&oldest);
                }
            }
        }
    }

    fn require_active_turn(
        active_turns: &HashMap<String, String>,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<(), &'static str> {
        match active_turns.get(thread_id) {
            Some(active) if active == turn_id => Ok(()),
            Some(_) => Err("Codex active turn changed; refresh before controlling it"),
            None => Err("Codex task has no active turn"),
        }
    }

    fn complete_active_turn(
        active_turns: &mut HashMap<String, String>,
        thread_id: &str,
        turn_id: &str,
    ) -> bool {
        if active_turns
            .get(thread_id)
            .is_some_and(|active| active == turn_id)
        {
            active_turns.remove(thread_id);
            true
        } else {
            false
        }
    }

    fn remember_started_turn(
        active_turns: &mut HashMap<String, String>,
        thread_id: &str,
        turn_id: &str,
    ) -> bool {
        match active_turns.get(thread_id) {
            Some(active) if active != turn_id => false,
            Some(_) => true,
            None => {
                active_turns.insert(thread_id.to_owned(), turn_id.to_owned());
                true
            }
        }
    }

    fn queued_turn_count(queued_turns: &HashMap<String, VecDeque<QueuedCodexTurn>>) -> usize {
        queued_turns.values().map(VecDeque::len).sum()
    }

    fn pop_next_queued_turn(
        thread_id: &str,
        owner: Option<i32>,
        connection_scopes: &HashMap<i32, CodexConnectionScope>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
    ) -> Option<QueuedCodexTurn> {
        loop {
            let next = queued_turns
                .get_mut(thread_id)
                .and_then(VecDeque::pop_front);
            let Some(next) = next else {
                queued_turns.remove(thread_id);
                return None;
            };
            let scope_matches = connection_scopes
                .get(&next.connection_id)
                .is_some_and(|scope| {
                    scope.session_identity == next.session_identity
                        && scope.session_generation == next.session_generation
                });
            if owner == Some(next.connection_id) && next.thread_id == thread_id && scope_matches {
                return Some(next);
            }
        }
    }

    fn drop_connection_runtime_state(
        connection_id: i32,
        thread_owners: &HashMap<String, i32>,
        active_turns: &mut HashMap<String, String>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
    ) {
        let owned_threads = thread_owners
            .iter()
            .filter_map(|(thread_id, owner)| (*owner == connection_id).then(|| thread_id.clone()))
            .collect::<Vec<_>>();
        for thread_id in owned_threads {
            active_turns.remove(&thread_id);
            queued_turns.remove(&thread_id);
        }
        queued_turns.retain(|_, queue| {
            queue.retain(|queued| queued.connection_id != connection_id);
            !queue.is_empty()
        });
    }

    fn bind_approval_to_scope(
        bindings: &mut HashMap<String, CodexApprovalBinding>,
        approval: &BridgeApproval,
        connection_id: i32,
        session_identity: &str,
        session_generation: u64,
    ) {
        bindings.entry(approval.id.clone()).or_insert_with(|| {
            CodexApprovalBinding::new(
                connection_id,
                session_identity,
                session_generation,
                approval,
            )
        });
    }

    fn remember_connection_scope(
        scopes: &mut HashMap<i32, CodexConnectionScope>,
        connection_id: i32,
        session_identity: &str,
        session_generation: u64,
    ) -> ConnectionScopeUpdate {
        if session_identity.is_empty() || session_generation == 0 {
            return ConnectionScopeUpdate::Invalid;
        }
        let next = CodexConnectionScope {
            session_identity: session_identity.to_owned(),
            session_generation,
        };
        match scopes.get(&connection_id) {
            None => {
                scopes.insert(connection_id, next);
                ConnectionScopeUpdate::Established
            }
            Some(current) if current == &next => ConnectionScopeUpdate::Unchanged,
            Some(current)
                if session_generation < current.session_generation
                    || (session_generation == current.session_generation
                        && session_identity != current.session_identity) =>
            {
                ConnectionScopeUpdate::Stale
            }
            Some(_) => {
                scopes.insert(connection_id, next);
                ConnectionScopeUpdate::Changed
            }
        }
    }

    fn invalidate_connection_state(
        connection_id: i32,
        bridge: &mut Option<CodexBridge>,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &mut HashMap<String, i32>,
        approval_bindings: &mut HashMap<String, CodexApprovalBinding>,
        active_turns: &mut HashMap<String, String>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
        control_replays: &mut HashMap<i32, CodexControlReplay>,
    ) {
        let owned_threads = thread_owners
            .iter()
            .filter_map(|(thread_id, owner)| (*owner == connection_id).then(|| thread_id.clone()))
            .collect::<Vec<_>>();
        remove_connection(subscribers, connection_id);
        drop_connection_runtime_state(connection_id, thread_owners, active_turns, queued_turns);
        if let Some(active) = bridge.as_mut() {
            for thread_id in &owned_threads {
                active.clear_review_for_thread(thread_id);
            }
        }
        approval_bindings.retain(|_, binding| binding.connection_id != connection_id);
        release_thread_owners(thread_owners, connection_id);
        control_replays.remove(&connection_id);
    }

    enum ReplayLookup {
        Miss,
        Replay(CodexControlResponse),
        Conflict,
    }

    #[derive(Default)]
    struct CodexControlReplay {
        completed: VecDeque<(CodexOperationKey, CodexControlResponse)>,
    }

    impl CodexControlReplay {
        fn lookup(&self, key: &CodexOperationKey, request_id: &str) -> ReplayLookup {
            let Some((existing, response)) = self
                .completed
                .iter()
                .find(|(existing, _)| existing.operation_id == key.operation_id)
            else {
                return ReplayLookup::Miss;
            };
            if existing != key {
                return ReplayLookup::Conflict;
            }
            let mut replayed = response.clone();
            replayed.request_id = request_id.to_owned();
            ReplayLookup::Replay(replayed)
        }

        fn record(&mut self, key: CodexOperationKey, response: CodexControlResponse) {
            self.completed.push_back((key, response));
            while self.completed.len() > CONTROL_REPLAY_LIMIT {
                self.completed.pop_front();
            }
        }
    }

    enum ServiceCommand {
        Read {
            connection_id: i32,
            request: CodexReadRequest,
            reply: Sender,
            operation_identity: String,
            operation_generation: u64,
        },
        Control {
            connection_id: i32,
            request: CodexControlRequest,
            reply: Sender,
            control_allowed: bool,
            operation_identity: String,
            operation_generation: u64,
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
        operation_identity: String,
        operation_generation: u64,
    ) {
        let command = ServiceCommand::Read {
            connection_id,
            request,
            reply: reply.clone(),
            operation_identity,
            operation_generation,
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
        control_allowed: bool,
        operation_identity: String,
        operation_generation: u64,
    ) {
        let rejected_request = request.clone();
        let command = ServiceCommand::Control {
            connection_id,
            request,
            reply: reply.clone(),
            control_allowed,
            operation_identity,
            operation_generation,
        };
        if service().sender.send(command).is_err() {
            send_scoped_control_error(
                &reply,
                &rejected_request,
                false,
                "service_unavailable",
                "Codex control service is unavailable",
                "",
            );
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
        let mut control_replays: HashMap<i32, CodexControlReplay> = HashMap::new();
        let mut thread_owners: HashMap<String, i32> = HashMap::new();
        let mut connection_scopes: HashMap<i32, CodexConnectionScope> = HashMap::new();
        let mut approval_bindings: HashMap<String, CodexApprovalBinding> = HashMap::new();
        let mut active_turns: HashMap<String, String> = HashMap::new();
        let mut queued_turns: HashMap<String, VecDeque<QueuedCodexTurn>> = HashMap::new();
        let mut completed_turns = CompletedTurnTracker::default();

        loop {
            match receiver.recv_timeout(POLL_INTERVAL) {
                Ok(ServiceCommand::Read {
                    connection_id,
                    request,
                    reply,
                    operation_identity,
                    operation_generation,
                }) => {
                    let scope_update = remember_connection_scope(
                        &mut connection_scopes,
                        connection_id,
                        &operation_identity,
                        operation_generation,
                    );
                    match scope_update {
                        ConnectionScopeUpdate::Changed => {
                            invalidate_connection_state(
                                connection_id,
                                &mut bridge,
                                &mut subscribers,
                                &mut thread_owners,
                                &mut approval_bindings,
                                &mut active_turns,
                                &mut queued_turns,
                                &mut control_replays,
                            );
                        }
                        ConnectionScopeUpdate::Invalid => {
                            invalidate_connection_state(
                                connection_id,
                                &mut bridge,
                                &mut subscribers,
                                &mut thread_owners,
                                &mut approval_bindings,
                                &mut active_turns,
                                &mut queued_turns,
                                &mut control_replays,
                            );
                            connection_scopes.remove(&connection_id);
                            send_error(
                                &reply,
                                &request.request_id,
                                "Codex remote session identity is unavailable",
                                "",
                            );
                            continue;
                        }
                        ConnectionScopeUpdate::Stale => {
                            send_error(
                                &reply,
                                &request.request_id,
                                "Codex remote session is stale; refresh the connection",
                                "",
                            );
                            continue;
                        }
                        ConnectionScopeUpdate::Established | ConnectionScopeUpdate::Unchanged => {}
                    }
                    handle_request(
                        connection_id,
                        request,
                        reply,
                        operation_identity,
                        operation_generation,
                        &mut bridge,
                        &mut codex_version,
                        &mut subscribers,
                        &thread_owners,
                        &approval_bindings,
                    )
                }
                Ok(ServiceCommand::Control {
                    connection_id,
                    request,
                    reply,
                    control_allowed,
                    operation_identity,
                    operation_generation,
                }) => {
                    let scope_update = remember_connection_scope(
                        &mut connection_scopes,
                        connection_id,
                        &operation_identity,
                        operation_generation,
                    );
                    match scope_update {
                        ConnectionScopeUpdate::Changed => {
                            invalidate_connection_state(
                                connection_id,
                                &mut bridge,
                                &mut subscribers,
                                &mut thread_owners,
                                &mut approval_bindings,
                                &mut active_turns,
                                &mut queued_turns,
                                &mut control_replays,
                            );
                        }
                        ConnectionScopeUpdate::Invalid => {
                            invalidate_connection_state(
                                connection_id,
                                &mut bridge,
                                &mut subscribers,
                                &mut thread_owners,
                                &mut approval_bindings,
                                &mut active_turns,
                                &mut queued_turns,
                                &mut control_replays,
                            );
                            connection_scopes.remove(&connection_id);
                            send_scoped_control_error(
                                &reply,
                                &request,
                                false,
                                "session_mismatch",
                                "Codex remote session identity is unavailable",
                                "",
                            );
                            continue;
                        }
                        ConnectionScopeUpdate::Stale => {
                            send_scoped_control_error(
                                &reply,
                                &request,
                                false,
                                "session_mismatch",
                                "Codex remote session is stale; refresh the connection",
                                "",
                            );
                            continue;
                        }
                        ConnectionScopeUpdate::Established | ConnectionScopeUpdate::Unchanged => {}
                    }
                    handle_control_request(
                        connection_id,
                        request,
                        reply,
                        control_allowed,
                        operation_identity,
                        operation_generation,
                        &mut bridge,
                        &mut codex_version,
                        &mut subscribers,
                        &mut thread_owners,
                        &mut approval_bindings,
                        &mut active_turns,
                        &mut queued_turns,
                        control_replays.entry(connection_id).or_default(),
                    )
                }
                Ok(ServiceCommand::Disconnect(connection_id)) => {
                    invalidate_connection_state(
                        connection_id,
                        &mut bridge,
                        &mut subscribers,
                        &mut thread_owners,
                        &mut approval_bindings,
                        &mut active_turns,
                        &mut queued_turns,
                        &mut control_replays,
                    );
                    connection_scopes.remove(&connection_id);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }

            drain_and_broadcast(
                &mut bridge,
                &mut subscribers,
                &mut thread_owners,
                &connection_scopes,
                &mut approval_bindings,
                &mut active_turns,
                &mut queued_turns,
                &mut completed_turns,
            );
        }
    }

    fn handle_request(
        connection_id: i32,
        request: CodexReadRequest,
        reply: Sender,
        operation_identity: String,
        operation_generation: u64,
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &HashMap<String, i32>,
        approval_bindings: &HashMap<String, CodexApprovalBinding>,
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
                                .map(|thread| {
                                    let owned = thread_owners
                                        .get(&thread.id)
                                        .is_some_and(|owner| *owner == connection_id);
                                    CodexThreadInfo {
                                        id: thread.id,
                                        title: thread.name.unwrap_or_default(),
                                        project: String::new(),
                                        originator: thread.originator.unwrap_or_default(),
                                        updated_at: thread.updated_at,
                                        state: map_thread_state_for_connection(
                                            thread.status,
                                            owned,
                                        )
                                        .into(),
                                        ..Default::default()
                                    }
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
                                    queue_turn: control.start_turn,
                                    ..Default::default()
                                },
                            ),
                            capabilities: vec![
                                "codex.operation.identity.v1".to_owned(),
                                "codex.operation.ack.v1".to_owned(),
                                "codex.workspaces.v1".to_owned(),
                                "codex.queue.v1".to_owned(),
                                "codex.queue.reconcile.v1".to_owned(),
                                "codex.review.v1".to_owned(),
                            ],
                            operation_session_identity: operation_identity.clone(),
                            operation_generation,
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
                if let Err(error) = require_thread_owner(thread_owners, &thread_id, connection_id) {
                    send_error(&reply, &request_id, error, &thread_id);
                    return;
                }
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
                                            .filter(|approval| {
                                                approval_bindings.get(&approval.id).is_some_and(
                                                    |binding| {
                                                        binding.matches(
                                                            connection_id,
                                                            &operation_identity,
                                                            operation_generation,
                                                            approval,
                                                        )
                                                    },
                                                )
                                            })
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
            Some(codex_read_request::Union::ListWorkspaces(list)) => {
                if list.cursor.len() > MAX_CURSOR_BYTES {
                    send_error(
                        &reply,
                        &request_id,
                        "Codex workspace cursor is too long",
                        "",
                    );
                    return;
                }
                let result =
                    with_bridge_read(bridge, codex_version, |bridge| bridge.list_workspaces());
                match result {
                    Ok(workspaces) => {
                        match paginate_workspaces(workspaces, &list.cursor, list.limit) {
                            Ok((workspaces, next_cursor)) => {
                                send_response(
                                    &reply,
                                    CodexReadResponse {
                                        request_id,
                                        union: Some(codex_read_response::Union::WorkspaceList(
                                            CodexWorkspaceListResponse {
                                                workspaces: workspaces
                                                    .into_iter()
                                                    .map(|workspace| CodexWorkspaceInfo {
                                                        id: workspace.id,
                                                        name: workspace.name,
                                                        path: workspace.path,
                                                        accessible: workspace.accessible,
                                                        status: workspace.status,
                                                        ..Default::default()
                                                    })
                                                    .collect(),
                                                next_cursor,
                                                ..Default::default()
                                            },
                                        )),
                                        ..Default::default()
                                    },
                                );
                            }
                            Err(error) => send_error(&reply, &request_id, error, ""),
                        }
                    }
                    Err(error) => send_error(&reply, &request_id, &error, ""),
                }
            }
            Some(codex_read_request::Union::ListTaskChanges(list)) => {
                if let Err(error) = validate_thread_id(&list.thread_id) {
                    send_error(&reply, &request_id, error, &list.thread_id);
                    return;
                }
                if list.cursor.len() > MAX_CURSOR_BYTES {
                    send_error(
                        &reply,
                        &request_id,
                        "Codex review cursor is too long",
                        &list.thread_id,
                    );
                    return;
                }
                let thread_id = list.thread_id;
                if let Err(error) = require_thread_owner(thread_owners, &thread_id, connection_id) {
                    send_error(&reply, &request_id, error, &thread_id);
                    return;
                }
                let cursor = (!list.cursor.is_empty()).then_some(list.cursor.as_str());
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    bridge.task_changes(&thread_id, cursor, list.limit)
                });
                match result {
                    Ok(page) => {
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::TaskChangeList(
                                    CodexTaskChangeListResponse {
                                        thread_id,
                                        changes: page
                                            .items
                                            .into_iter()
                                            .map(|change| CodexTaskChangeInfo {
                                                change_id: change.id,
                                                artifact_id: change.artifact_id,
                                                path: change.path,
                                                kind: change.kind,
                                                binary: change.binary,
                                                large: change.large,
                                                size_bytes: change.size_bytes,
                                                diff_available: change.diff_available,
                                                fallback_reason: change.fallback_reason,
                                                ..Default::default()
                                            })
                                            .collect(),
                                        next_cursor: page.next_cursor.unwrap_or_default(),
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
            Some(codex_read_request::Union::ReadTaskDiff(read)) => {
                if let Err(error) = validate_thread_id(&read.thread_id) {
                    send_error(&reply, &request_id, error, &read.thread_id);
                    return;
                }
                if let Err(error) = validate_review_id(&read.change_id, "change") {
                    send_error(&reply, &request_id, error, &read.thread_id);
                    return;
                }
                let thread_id = read.thread_id;
                if let Err(error) = require_thread_owner(thread_owners, &thread_id, connection_id) {
                    send_error(&reply, &request_id, error, &thread_id);
                    return;
                }
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    bridge.task_diff(&thread_id, &read.change_id, read.offset, read.limit)
                });
                match result {
                    Ok(page) => {
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::TaskDiff(
                                    CodexReviewTextResponse {
                                        thread_id,
                                        id: page.id,
                                        text: page.text,
                                        offset: page.offset,
                                        next_offset: page.next_offset,
                                        complete: page.complete,
                                        fallback_reason: page.fallback_reason,
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
            Some(codex_read_request::Union::ListArtifacts(list)) => {
                if let Err(error) = validate_thread_id(&list.thread_id) {
                    send_error(&reply, &request_id, error, &list.thread_id);
                    return;
                }
                if list.cursor.len() > MAX_CURSOR_BYTES {
                    send_error(
                        &reply,
                        &request_id,
                        "Codex artifact cursor is too long",
                        &list.thread_id,
                    );
                    return;
                }
                let thread_id = list.thread_id;
                if let Err(error) = require_thread_owner(thread_owners, &thread_id, connection_id) {
                    send_error(&reply, &request_id, error, &thread_id);
                    return;
                }
                let cursor = (!list.cursor.is_empty()).then_some(list.cursor.as_str());
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    bridge.artifacts(&thread_id, cursor, list.limit)
                });
                match result {
                    Ok(page) => {
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::ArtifactList(
                                    CodexArtifactListResponse {
                                        thread_id,
                                        artifacts: page
                                            .items
                                            .into_iter()
                                            .map(|artifact| CodexArtifactInfo {
                                                artifact_id: artifact.id,
                                                path: artifact.path,
                                                size_bytes: artifact.size_bytes,
                                                binary: artifact.binary,
                                                large: artifact.large,
                                                readable: artifact.readable,
                                                fallback_reason: artifact.fallback_reason,
                                                ..Default::default()
                                            })
                                            .collect(),
                                        next_cursor: page.next_cursor.unwrap_or_default(),
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
            Some(codex_read_request::Union::ReadArtifact(read)) => {
                if let Err(error) = validate_thread_id(&read.thread_id) {
                    send_error(&reply, &request_id, error, &read.thread_id);
                    return;
                }
                if let Err(error) = validate_review_id(&read.artifact_id, "artifact") {
                    send_error(&reply, &request_id, error, &read.thread_id);
                    return;
                }
                let thread_id = read.thread_id;
                if let Err(error) = require_thread_owner(thread_owners, &thread_id, connection_id) {
                    send_error(&reply, &request_id, error, &thread_id);
                    return;
                }
                let result = with_bridge_read(bridge, codex_version, |bridge| {
                    bridge.artifact(&thread_id, &read.artifact_id, read.offset, read.limit)
                });
                match result {
                    Ok(page) => {
                        send_response(
                            &reply,
                            CodexReadResponse {
                                request_id,
                                union: Some(codex_read_response::Union::Artifact(
                                    CodexReviewTextResponse {
                                        thread_id,
                                        id: page.id,
                                        text: page.text,
                                        offset: page.offset,
                                        next_offset: page.next_offset,
                                        complete: page.complete,
                                        fallback_reason: page.fallback_reason,
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

    fn control_action_name(request: &CodexControlRequest) -> &'static str {
        match request.union.as_ref() {
            Some(codex_control_request::Union::ResumeThread(_)) => "resume_thread",
            Some(codex_control_request::Union::StartThread(_)) => "start_thread",
            Some(codex_control_request::Union::StartTurn(_)) => "start_turn",
            Some(codex_control_request::Union::SteerTurn(_)) => "steer_turn",
            Some(codex_control_request::Union::QueueTurn(_)) => "queue_turn",
            Some(codex_control_request::Union::InterruptTurn(_)) => "interrupt_turn",
            Some(codex_control_request::Union::RespondApproval(_)) => "respond_approval",
            Some(codex_control_request::Union::OpenWindowsApp(_)) => "open_windows_app",
            _ => "unknown",
        }
    }

    fn control_target_identity(request: &CodexControlRequest) -> Result<String, &'static str> {
        match request.union.as_ref() {
            Some(codex_control_request::Union::ResumeThread(resume)) => {
                Ok(format!("thread:{}", resume.thread_id))
            }
            Some(codex_control_request::Union::StartThread(start)) => {
                let workspace = if !start.workspace_id.is_empty() {
                    start.workspace_id.as_str()
                } else if !start.workspace_thread_id.is_empty() {
                    start.workspace_thread_id.as_str()
                } else {
                    "missing"
                };
                Ok(format!("workspace:{workspace}"))
            }
            Some(codex_control_request::Union::StartTurn(start)) => {
                Ok(format!("thread:{}/turn:new", start.thread_id))
            }
            Some(codex_control_request::Union::SteerTurn(steer)) => {
                Ok(format!("thread:{}/turn:{}", steer.thread_id, steer.turn_id))
            }
            Some(codex_control_request::Union::QueueTurn(queue)) => Ok(format!(
                "thread:{}/turn:{}/queue",
                queue.thread_id, queue.turn_id
            )),
            Some(codex_control_request::Union::InterruptTurn(interrupt)) => Ok(format!(
                "thread:{}/turn:{}",
                interrupt.thread_id, interrupt.turn_id
            )),
            Some(codex_control_request::Union::RespondApproval(approval)) => {
                let decision = match approval.decision.enum_value_or_default() {
                    CodexApprovalDecision::CodexApprovalApprove => "approve",
                    CodexApprovalDecision::CodexApprovalDeny => "deny",
                    CodexApprovalDecision::CodexApprovalDecisionUnknown => "unknown",
                };
                Ok(format!(
                    "approval:{}/thread:{}/turn:{}/item:{}/decision:{}",
                    approval.approval_id,
                    approval.thread_id,
                    approval.turn_id,
                    approval.item_id,
                    decision
                ))
            }
            Some(codex_control_request::Union::OpenWindowsApp(_)) => {
                Err("Windows app handoff does not use the mutation contract")
            }
            None => Err("Codex control request is empty"),
            Some(_) => Err("Unsupported Codex control request type"),
        }
    }

    fn hash_control_field(hasher: &mut Sha256, value: &str) {
        hasher.update((value.len() as u64).to_le_bytes());
        hasher.update(value.as_bytes());
    }

    fn control_payload_fingerprint(request: &CodexControlRequest) -> Result<String, &'static str> {
        let mut hasher = Sha256::new();
        hash_control_field(&mut hasher, control_action_name(request));
        match request.union.as_ref() {
            Some(codex_control_request::Union::ResumeThread(resume)) => {
                hash_control_field(&mut hasher, &resume.thread_id);
            }
            Some(codex_control_request::Union::StartThread(start)) => {
                hash_control_field(&mut hasher, &start.workspace_id);
                hash_control_field(&mut hasher, &start.workspace_thread_id);
            }
            Some(codex_control_request::Union::StartTurn(start)) => {
                hash_control_field(&mut hasher, &start.thread_id);
                hash_control_field(&mut hasher, &start.text);
            }
            Some(codex_control_request::Union::SteerTurn(steer)) => {
                hash_control_field(&mut hasher, &steer.thread_id);
                hash_control_field(&mut hasher, &steer.turn_id);
                hash_control_field(&mut hasher, &steer.text);
            }
            Some(codex_control_request::Union::QueueTurn(queue)) => {
                hash_control_field(&mut hasher, &queue.thread_id);
                hash_control_field(&mut hasher, &queue.turn_id);
                hash_control_field(&mut hasher, &queue.text);
            }
            Some(codex_control_request::Union::InterruptTurn(interrupt)) => {
                hash_control_field(&mut hasher, &interrupt.thread_id);
                hash_control_field(&mut hasher, &interrupt.turn_id);
            }
            Some(codex_control_request::Union::RespondApproval(approval)) => {
                hash_control_field(&mut hasher, &approval.approval_id);
                hash_control_field(&mut hasher, &approval.thread_id);
                hash_control_field(&mut hasher, &approval.turn_id);
                hash_control_field(&mut hasher, &approval.item_id);
                hash_control_field(&mut hasher, &approval.decision.value().to_string());
            }
            Some(codex_control_request::Union::OpenWindowsApp(open)) => {
                hash_control_field(&mut hasher, &open.thread_id);
            }
            None => return Err("Codex control request is empty"),
            Some(_) => return Err("Unsupported Codex control request type"),
        }
        Ok(format!("{:x}", hasher.finalize()))
    }

    fn authorize_control_operation(
        request: &CodexControlRequest,
        control_allowed: bool,
        expected_session_identity: &str,
        expected_generation: u64,
    ) -> Result<CodexOperationKey, (&'static str, &'static str)> {
        if !control_allowed {
            return Err((
                "permission_denied",
                "Codex control requires remote control permission",
            ));
        }
        if expected_session_identity.is_empty()
            || expected_session_identity.len() > MAX_SESSION_IDENTITY_BYTES
            || expected_generation == 0
            || request.operation_id.is_empty()
            || request.operation_id.len() > MAX_OPERATION_ID_BYTES
            || request.session_identity != expected_session_identity
            || request.session_identity.len() > MAX_SESSION_IDENTITY_BYTES
            || request.session_generation != expected_generation
            || request.target_identity.is_empty()
            || request.target_identity.len() > MAX_TARGET_IDENTITY_BYTES
        {
            return Err((
                "session_mismatch",
                "Codex operation identity does not match this remote session",
            ));
        }
        let expected_target = control_target_identity(request).map_err(|_| {
            (
                "unsupported_action",
                "Unsupported Codex control request type",
            )
        })?;
        if request.target_identity != expected_target {
            return Err((
                "target_mismatch",
                "Codex operation target does not match the requested action",
            ));
        }
        let payload_fingerprint = control_payload_fingerprint(request).map_err(|_| {
            (
                "unsupported_action",
                "Unsupported Codex control request type",
            )
        })?;
        Ok(CodexOperationKey {
            operation_id: request.operation_id.clone(),
            session_identity: request.session_identity.clone(),
            target_identity: request.target_identity.clone(),
            session_generation: request.session_generation,
            action: control_action_name(request).to_owned(),
            payload_fingerprint,
        })
    }

    fn handle_control_request(
        connection_id: i32,
        request: CodexControlRequest,
        reply: Sender,
        control_allowed: bool,
        operation_identity: String,
        operation_generation: u64,
        bridge: &mut Option<CodexBridge>,
        codex_version: &mut String,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &mut HashMap<String, i32>,
        approval_bindings: &mut HashMap<String, CodexApprovalBinding>,
        active_turns: &mut HashMap<String, String>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
        replay: &mut CodexControlReplay,
    ) {
        let request_id = request.request_id.clone();
        if request_id.len() > MAX_REQUEST_ID_BYTES {
            send_scoped_control_error(
                &reply,
                &request,
                false,
                "invalid_request",
                "Codex request id is too long",
                "",
            );
            return;
        }

        if let Some(codex_control_request::Union::OpenWindowsApp(open)) = request.union.as_ref() {
            if !open.thread_id.is_empty() {
                if let Err(error) = validate_thread_id(&open.thread_id) {
                    send_control_error(&reply, &request_id, error, &open.thread_id);
                    return;
                }
            }
            let thread_id = open.thread_id.clone();
            match windows_app::open_windows_app() {
                Ok(()) => {
                    send_control_response(
                        &reply,
                        CodexControlResponse {
                            request_id,
                            accepted: true,
                            applied: true,
                            union: Some(codex_control_response::Union::Result(control_result(
                                CodexControlAction::CodexControlWindowsAppOpened,
                                thread_id,
                                String::new(),
                                CodexState::CodexReady,
                            ))),
                            ..Default::default()
                        },
                    );
                }
                Err(error) => {
                    send_control_error(&reply, &request_id, &error, &thread_id);
                }
            };
            return;
        }

        let operation_key = match authorize_control_operation(
            &request,
            control_allowed,
            &operation_identity,
            operation_generation,
        ) {
            Ok(key) => key,
            Err((error_code, message)) => {
                send_scoped_control_error(&reply, &request, false, error_code, message, "");
                return;
            }
        };

        match replay.lookup(&operation_key, &request_id) {
            ReplayLookup::Replay(response) => {
                send_control_response(&reply, response);
                return;
            }
            ReplayLookup::Conflict => {
                send_scoped_control_error(
                    &reply,
                    &request,
                    false,
                    "operation_conflict",
                    "Operation id already belongs to a different Codex operation",
                    "",
                );
                return;
            }
            ReplayLookup::Miss => {}
        }

        let result = match request.union.clone() {
            Some(codex_control_request::Union::ResumeThread(resume)) => {
                if let Err(error) = validate_thread_id(&resume.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &resume.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    ensure_thread_claim_available(thread_owners, &resume.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &resume.thread_id,
                    );
                    return;
                }
                let thread_id = resume.thread_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.resume_thread(&thread_id)
                })
                .map(|outcome| {
                    thread_owners.insert(outcome.thread_id.clone(), connection_id);
                    if outcome.turn_id.is_empty() {
                        active_turns.remove(&outcome.thread_id);
                    } else {
                        active_turns.insert(outcome.thread_id.clone(), outcome.turn_id.clone());
                    }
                    let mut result = control_result(
                        CodexControlAction::CodexControlThreadResumed,
                        outcome.thread_id.clone(),
                        outcome.turn_id,
                        map_state(outcome.status),
                    );
                    result.queued_operation_ids = queued_turns
                        .get(&outcome.thread_id)
                        .map(|queued| {
                            queued
                                .iter()
                                .filter(|item| {
                                    item.connection_id == connection_id
                                        && item.session_identity == operation_identity
                                        && item.session_generation == operation_generation
                                })
                                .map(|item| item.operation_id.clone())
                                .collect()
                        })
                        .unwrap_or_default();
                    result
                })
                .map_err(|error| (error, thread_id, "resume_failed"))
            }
            Some(codex_control_request::Union::StartThread(start)) => {
                if start.workspace_id.len() > MAX_WORKSPACE_ID_BYTES {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_workspace",
                        "Codex workspace id is too long",
                        "",
                    );
                    return;
                }
                if !start.workspace_thread_id.is_empty() {
                    if let Err(error) = validate_thread_id(&start.workspace_thread_id) {
                        send_scoped_control_error(
                            &reply,
                            &request,
                            false,
                            "invalid_thread",
                            error,
                            &start.workspace_thread_id,
                        );
                        return;
                    }
                }
                if start.workspace_id.is_empty() && start.workspace_thread_id.is_empty() {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "missing_workspace",
                        "Choose an approved Codex workspace before starting a task",
                        "",
                    );
                    return;
                }
                let workspace_id = start.workspace_id;
                let workspace_thread_id = start.workspace_thread_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    if !workspace_id.is_empty() {
                        bridge.start_thread(&workspace_id)
                    } else {
                        bridge.start_thread_from_workspace_thread(&workspace_thread_id)
                    }
                })
                .map(|outcome| {
                    thread_owners.insert(outcome.thread_id.clone(), connection_id);
                    if outcome.turn_id.is_empty() {
                        active_turns.remove(&outcome.thread_id);
                    } else {
                        active_turns.insert(outcome.thread_id.clone(), outcome.turn_id.clone());
                    }
                    control_result(
                        CodexControlAction::CodexControlThreadStarted,
                        outcome.thread_id,
                        outcome.turn_id,
                        map_state(outcome.status),
                    )
                })
                .map_err(|error| {
                    (
                        error,
                        if workspace_id.is_empty() {
                            workspace_thread_id
                        } else {
                            workspace_id
                        },
                        "start_thread_failed",
                    )
                })
            }
            Some(codex_control_request::Union::StartTurn(start)) => {
                if let Err(error) = validate_thread_id(&start.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &start.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_thread_owner(thread_owners, &start.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &start.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_input(&start.text) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_input",
                        error,
                        &start.thread_id,
                    );
                    return;
                }
                if active_turns.contains_key(&start.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "turn_conflict",
                        "This Codex task already has an active turn",
                        &start.thread_id,
                    );
                    return;
                }
                let thread_id = start.thread_id;
                let text = start.text;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.start_turn(&thread_id, &text)
                })
                .map(|outcome| {
                    active_turns.insert(outcome.thread_id.clone(), outcome.turn_id.clone());
                    control_result(
                        CodexControlAction::CodexControlTurnStarted,
                        outcome.thread_id,
                        outcome.turn_id,
                        CodexState::CodexWorking,
                    )
                })
                .map_err(|error| (error, thread_id, "start_turn_failed"))
            }
            Some(codex_control_request::Union::SteerTurn(steer)) => {
                if let Err(error) = validate_thread_id(&steer.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &steer.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_thread_owner(thread_owners, &steer.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &steer.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_turn_id(&steer.turn_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_turn",
                        error,
                        &steer.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_input(&steer.text) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_input",
                        error,
                        &steer.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_active_turn(active_turns, &steer.thread_id, &steer.turn_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "turn_mismatch",
                        error,
                        &steer.thread_id,
                    );
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
                .map_err(|error| (error, thread_id, "steer_failed"))
            }
            Some(codex_control_request::Union::QueueTurn(queue)) => {
                if let Err(error) = validate_thread_id(&queue.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &queue.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_thread_owner(thread_owners, &queue.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &queue.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_turn_id(&queue.turn_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_turn",
                        error,
                        &queue.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_input(&queue.text) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_input",
                        error,
                        &queue.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_active_turn(active_turns, &queue.thread_id, &queue.turn_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "turn_mismatch",
                        error,
                        &queue.thread_id,
                    );
                    return;
                }
                if !bridge
                    .as_ref()
                    .is_some_and(|active| active.control_support().start_turn)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "unsupported_action",
                        "This Codex runtime cannot start queued turns",
                        &queue.thread_id,
                    );
                    return;
                }
                let thread_id = queue.thread_id;
                let turn_id = queue.turn_id;
                let session_identity = request.session_identity.clone();
                let session_generation = request.session_generation;
                if queued_turn_count(queued_turns) >= MAX_QUEUED_TURNS_TOTAL {
                    Err((
                        "Codex queue capacity is reached; wait for an instruction to start".into(),
                        thread_id,
                        "queue_full",
                    ))
                } else if queued_turns
                    .get(&thread_id)
                    .is_some_and(|pending| pending.len() >= MAX_QUEUED_TURNS_PER_THREAD)
                {
                    Err((
                        "Codex queue is full; wait for an instruction to start".into(),
                        thread_id,
                        "queue_full",
                    ))
                } else {
                    let pending = queued_turns.entry(thread_id.clone()).or_default();
                    pending.push_back(QueuedCodexTurn {
                        connection_id,
                        session_identity,
                        session_generation,
                        thread_id: thread_id.clone(),
                        operation_id: request.operation_id.clone(),
                        text: queue.text,
                    });
                    Ok(control_result(
                        CodexControlAction::CodexControlTurnQueued,
                        thread_id,
                        turn_id,
                        CodexState::CodexWorking,
                    ))
                }
            }
            Some(codex_control_request::Union::InterruptTurn(interrupt)) => {
                if let Err(error) = validate_thread_id(&interrupt.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &interrupt.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_thread_owner(thread_owners, &interrupt.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &interrupt.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_turn_id(&interrupt.turn_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_turn",
                        error,
                        &interrupt.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_active_turn(active_turns, &interrupt.thread_id, &interrupt.turn_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "turn_mismatch",
                        error,
                        &interrupt.thread_id,
                    );
                    return;
                }
                let thread_id = interrupt.thread_id;
                let turn_id = interrupt.turn_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.interrupt_turn(&thread_id, &turn_id)
                })
                .map(|()| {
                    queued_turns.remove(&thread_id);
                    control_result(
                        CodexControlAction::CodexControlTurnInterrupted,
                        thread_id.clone(),
                        turn_id,
                        CodexState::CodexInterrupting,
                    )
                })
                .map_err(|error| (error, thread_id, "interrupt_failed"))
            }
            Some(codex_control_request::Union::RespondApproval(approval)) => {
                if let Err(error) = validate_approval_id(&approval.approval_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_approval",
                        error,
                        &approval.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_thread_id(&approval.thread_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_thread",
                        error,
                        &approval.thread_id,
                    );
                    return;
                }
                if let Err(error) =
                    require_thread_owner(thread_owners, &approval.thread_id, connection_id)
                {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "thread_owner_mismatch",
                        error,
                        &approval.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_turn_id(&approval.turn_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_turn",
                        error,
                        &approval.thread_id,
                    );
                    return;
                }
                if let Err(error) = validate_item_id(&approval.item_id) {
                    send_scoped_control_error(
                        &reply,
                        &request,
                        false,
                        "invalid_approval",
                        error,
                        &approval.thread_id,
                    );
                    return;
                }
                let decision = match approval.decision.enum_value_or_default() {
                    CodexApprovalDecision::CodexApprovalApprove => BridgeApprovalDecision::Approve,
                    CodexApprovalDecision::CodexApprovalDeny => BridgeApprovalDecision::Deny,
                    CodexApprovalDecision::CodexApprovalDecisionUnknown => {
                        send_scoped_control_error(
                            &reply,
                            &request,
                            false,
                            "invalid_approval",
                            "Codex approval decision is required",
                            &approval.thread_id,
                        );
                        return;
                    }
                };
                if let Some(active) = bridge.as_ref() {
                    let authoritative = active
                        .pending_approvals(&approval.thread_id)
                        .into_iter()
                        .find(|candidate| candidate.id == approval.approval_id);
                    let approval_matches = authoritative.as_ref().map_or(false, |candidate| {
                        candidate.actionable
                            && candidate.turn_id == approval.turn_id
                            && candidate.item_id == approval.item_id
                            && approval_bindings
                                .get(&approval.approval_id)
                                .is_some_and(|binding| {
                                    binding.matches(
                                        connection_id,
                                        &request.session_identity,
                                        request.session_generation,
                                        candidate,
                                    )
                                })
                    });
                    if !approval_matches {
                        send_scoped_control_error(
                            &reply,
                            &request,
                            false,
                            "approval_identity_mismatch",
                            "Codex approval is stale or no longer matches the active request",
                            &approval.thread_id,
                        );
                        return;
                    }
                }
                let approval_id = approval.approval_id;
                let thread_id = approval.thread_id;
                let turn_id = approval.turn_id;
                with_bridge_mutation(bridge, codex_version, |bridge| {
                    bridge.respond_to_approval(&approval_id, &thread_id, &turn_id, decision)
                })
                .map(|resolved| {
                    approval_bindings.remove(&approval_id);
                    broadcast_approval_resolved(subscribers, &resolved, connection_id);
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
                .map_err(|error| (error, thread_id, "approval_failed"))
            }
            None => {
                send_scoped_control_error(
                    &reply,
                    &request,
                    false,
                    "invalid_request",
                    "Codex control request is empty",
                    "",
                );
                return;
            }
            Some(_) => {
                send_scoped_control_error(
                    &reply,
                    &request,
                    false,
                    "unsupported_action",
                    "Unsupported Codex control request type",
                    "",
                );
                return;
            }
        };

        let response = match result {
            Ok(result) => CodexControlResponse {
                request_id,
                operation_id: request.operation_id.clone(),
                session_identity: request.session_identity.clone(),
                target_identity: request.target_identity.clone(),
                session_generation: request.session_generation,
                accepted: true,
                applied: true,
                union: Some(codex_control_response::Union::Result(result)),
                ..Default::default()
            },
            Err((error, thread_id, error_code)) => {
                if bridge.is_none() {
                    thread_owners.clear();
                    approval_bindings.clear();
                    active_turns.clear();
                    queued_turns.clear();
                    broadcast_disconnected(subscribers);
                }
                CodexControlResponse {
                    request_id,
                    operation_id: request.operation_id.clone(),
                    session_identity: request.session_identity.clone(),
                    target_identity: request.target_identity.clone(),
                    session_generation: request.session_generation,
                    accepted: true,
                    applied: false,
                    error_code: error_code.to_owned(),
                    union: Some(codex_control_response::Union::Error(CodexError {
                        thread_id,
                        message: error,
                        ..Default::default()
                    })),
                    ..Default::default()
                }
            }
        };
        replay.record(operation_key, response.clone());
        send_control_response(&reply, response);
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
        thread_owners: &mut HashMap<String, i32>,
        connection_scopes: &HashMap<i32, CodexConnectionScope>,
        approval_bindings: &mut HashMap<String, CodexApprovalBinding>,
        active_turns: &mut HashMap<String, String>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
        completed_turns: &mut CompletedTurnTracker,
    ) {
        let Some(active) = bridge.as_mut() else {
            return;
        };

        match active.drain_updates() {
            Ok(updates) => {
                for update in updates {
                    match update {
                        CodexBridgeUpdate::Event(event) => {
                            let thread_id = event.thread_id.clone();
                            let turn_id = event.turn_id.clone();
                            let turn_completed = event.kind == BridgeEventKind::TurnCompleted;
                            let mut completed_active_turn = false;
                            if event.kind == BridgeEventKind::TurnStarted
                                && !thread_id.is_empty()
                                && !turn_id.is_empty()
                            {
                                if completed_turns.contains(&thread_id, &turn_id) {
                                    continue;
                                }
                                if !remember_started_turn(active_turns, &thread_id, &turn_id) {
                                    continue;
                                }
                            }
                            if turn_completed && !thread_id.is_empty() && !turn_id.is_empty() {
                                completed_turns.remember(&thread_id, &turn_id);
                                approval_bindings.retain(|_, binding| {
                                    binding.thread_id != thread_id || binding.turn_id != turn_id
                                });
                                completed_active_turn =
                                    complete_active_turn(active_turns, &thread_id, &turn_id);
                            }
                            broadcast_event_to_owner(subscribers, thread_owners, event);
                            if completed_active_turn {
                                start_next_queued_turn(
                                    active,
                                    &thread_id,
                                    subscribers,
                                    thread_owners,
                                    connection_scopes,
                                    active_turns,
                                    queued_turns,
                                );
                            }
                        }
                        CodexBridgeUpdate::ApprovalRequested(approval) => {
                            let Some(owner) = thread_owners.get(&approval.thread_id).copied()
                            else {
                                continue;
                            };
                            let Some(scope) = connection_scopes.get(&owner) else {
                                continue;
                            };
                            bind_approval_to_scope(
                                approval_bindings,
                                &approval,
                                owner,
                                &scope.session_identity,
                                scope.session_generation,
                            );
                            if !approval_bindings.get(&approval.id).is_some_and(|binding| {
                                binding.matches(
                                    owner,
                                    &scope.session_identity,
                                    scope.session_generation,
                                    &approval,
                                )
                            }) {
                                continue;
                            }
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
                            targets.retain(|connection_id, sender| {
                                *connection_id == owner && send_response(sender, response.clone())
                            });
                        }
                    }
                }
            }
            Err(error) => {
                log::debug!("Codex event stream disconnected: {error}");
                *bridge = None;
                thread_owners.clear();
                approval_bindings.clear();
                active_turns.clear();
                queued_turns.clear();
                broadcast_disconnected(subscribers);
            }
        }
    }

    fn start_next_queued_turn(
        active: &mut CodexBridge,
        thread_id: &str,
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &HashMap<String, i32>,
        connection_scopes: &HashMap<i32, CodexConnectionScope>,
        active_turns: &mut HashMap<String, String>,
        queued_turns: &mut HashMap<String, VecDeque<QueuedCodexTurn>>,
    ) {
        let owner = thread_owners.get(thread_id).copied();
        loop {
            let next = pop_next_queued_turn(thread_id, owner, connection_scopes, queued_turns);
            let Some(next) = next else {
                return;
            };

            match active.start_turn(thread_id, &next.text) {
                Ok(outcome) => {
                    active_turns.insert(outcome.thread_id.clone(), outcome.turn_id.clone());
                    if queued_turns.get(thread_id).is_some_and(VecDeque::is_empty) {
                        queued_turns.remove(thread_id);
                    }
                    broadcast_event_to_owner_with_operation(
                        subscribers,
                        thread_owners,
                        BridgeEvent {
                            thread_id: outcome.thread_id,
                            turn_id: outcome.turn_id,
                            item_id: String::new(),
                            kind: BridgeEventKind::TurnStarted,
                            state: Some(CodexThreadStatus::Working),
                            history_kind: None,
                            text: String::new(),
                            status: "queuedStart".into(),
                        },
                        &next.operation_id,
                    );
                    return;
                }
                Err(error) => {
                    active_turns.remove(thread_id);
                    queued_turns.remove(thread_id);
                    broadcast_thread_error(
                        subscribers,
                        thread_owners,
                        thread_id,
                        "queue_cleared",
                        &format!(
                            "Queued Codex instruction could not start: {}",
                            public_rpc_error(&error)
                        ),
                    );
                    return;
                }
            }
        }
    }

    fn broadcast_event_to_owner(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &HashMap<String, i32>,
        event: BridgeEvent,
    ) {
        broadcast_event_to_owner_with_operation(subscribers, thread_owners, event, "");
    }

    fn broadcast_event_to_owner_with_operation(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &HashMap<String, i32>,
        event: BridgeEvent,
        operation_id: &str,
    ) {
        let Some(owner) = thread_owners.get(&event.thread_id).copied() else {
            return;
        };
        let Some(targets) = subscribers.get_mut(&event.thread_id) else {
            return;
        };
        let response = event_response_with_operation(event, operation_id);
        targets.retain(|connection_id, sender| {
            *connection_id == owner && send_response(sender, response.clone())
        });
    }

    fn broadcast_thread_error(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        thread_owners: &HashMap<String, i32>,
        thread_id: &str,
        error_code: &str,
        message: &str,
    ) {
        let Some(owner) = thread_owners.get(thread_id).copied() else {
            return;
        };
        let Some(targets) = subscribers.get_mut(thread_id) else {
            return;
        };
        let response = CodexReadResponse {
            request_id: String::new(),
            union: Some(codex_read_response::Union::Error(CodexError {
                thread_id: thread_id.to_owned(),
                message: message.to_owned(),
                error_code: error_code.to_owned(),
                ..Default::default()
            })),
            ..Default::default()
        };
        targets.retain(|connection_id, sender| {
            *connection_id == owner && send_response(sender, response.clone())
        });
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
        event_response_with_operation(event, "")
    }

    fn event_response_with_operation(event: BridgeEvent, operation_id: &str) -> CodexReadResponse {
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
                operation_id: operation_id.to_owned(),
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
            working_directory: approval.working_directory,
            scope: approval.scope,
            started_at_ms: approval.started_at_ms,
            actionable: approval.actionable,
            ..Default::default()
        }
    }

    fn broadcast_approval_resolved(
        subscribers: &mut HashMap<String, HashMap<i32, Sender>>,
        resolved: &BridgeResolvedApproval,
        owner_connection_id: i32,
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
        targets.retain(|connection_id, sender| {
            *connection_id == owner_connection_id && send_response(sender, response.clone())
        });
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

    fn send_scoped_control_error(
        reply: &Sender,
        request: &CodexControlRequest,
        accepted: bool,
        error_code: &str,
        message: &str,
        thread_id: &str,
    ) {
        send_control_response(
            reply,
            CodexControlResponse {
                request_id: request.request_id.clone(),
                operation_id: request.operation_id.clone(),
                session_identity: request.session_identity.clone(),
                target_identity: request.target_identity.clone(),
                session_generation: request.session_generation,
                accepted,
                applied: false,
                error_code: error_code.to_owned(),
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

    fn ensure_thread_claim_available(
        owners: &HashMap<String, i32>,
        thread_id: &str,
        connection_id: i32,
    ) -> Result<(), &'static str> {
        match owners.get(thread_id) {
            None => Ok(()),
            Some(owner) if *owner == connection_id => Ok(()),
            Some(_) => Err("Codex task belongs to a different remote runtime"),
        }
    }

    fn claim_thread_owner(
        owners: &mut HashMap<String, i32>,
        thread_id: &str,
        connection_id: i32,
    ) -> Result<(), &'static str> {
        ensure_thread_claim_available(owners, thread_id, connection_id)?;
        owners.insert(thread_id.to_owned(), connection_id);
        Ok(())
    }

    fn require_thread_owner(
        owners: &HashMap<String, i32>,
        thread_id: &str,
        connection_id: i32,
    ) -> Result<(), &'static str> {
        match owners.get(thread_id) {
            Some(owner) if *owner == connection_id => Ok(()),
            Some(_) => Err("Codex task belongs to a different remote runtime"),
            None => Err("Codex task is not owned by this remote runtime"),
        }
    }

    fn release_thread_owners(owners: &mut HashMap<String, i32>, connection_id: i32) {
        owners.retain(|_, owner| *owner != connection_id);
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

    fn validate_review_id(id: &str, kind: &str) -> Result<(), &'static str> {
        if id.is_empty() {
            Err(if kind == "change" {
                "Codex change id is required"
            } else {
                "Codex artifact id is required"
            })
        } else if id.len() > MAX_REVIEW_ID_BYTES {
            Err(if kind == "change" {
                "Codex change id is too long"
            } else {
                "Codex artifact id is too long"
            })
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

    fn validate_item_id(item_id: &str) -> Result<(), &'static str> {
        if item_id.is_empty() {
            Err("Codex approval item id is required")
        } else if item_id.len() > MAX_ITEM_ID_BYTES {
            Err("Codex approval item id is too long")
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

    fn map_thread_state_for_connection(status: CodexThreadStatus, owned: bool) -> CodexState {
        if owned {
            map_state(status)
        } else {
            CodexState::CodexResumable
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
        use base::message_proto::{CodexRespondApprovalRequest, CodexStartTurnRequest};
        use hbb_common::protobuf::Message as _;

        fn scoped_start_turn_request() -> CodexControlRequest {
            let mut request = CodexControlRequest {
                request_id: "request-1".into(),
                operation_id: "operation-1".into(),
                session_identity: "scope-1".into(),
                target_identity: "thread:thr_1/turn:new".into(),
                session_generation: 4,
                ..Default::default()
            };
            request.set_start_turn(CodexStartTurnRequest {
                thread_id: "thr_1".into(),
                text: "continue".into(),
                ..Default::default()
            });
            request
        }

        fn workspace(id: &str, path: &str) -> BridgeWorkspace {
            BridgeWorkspace {
                id: id.into(),
                name: id.into(),
                path: path.into(),
                accessible: true,
                status: "Available".into(),
            }
        }

        #[test]
        fn workspace_pagination_rejects_changed_snapshot() {
            let first = vec![workspace("ws_1", r"C:\one"), workspace("ws_2", r"C:\two")];
            let (page, cursor) =
                paginate_workspaces(first, "", 1).expect("first workspace page should succeed");
            assert_eq!(page.len(), 1);
            assert!(!cursor.is_empty());

            let changed = vec![workspace("ws_1", r"C:\one"), workspace("ws_3", r"C:\three")];
            assert_eq!(
                paginate_workspaces(changed, &cursor, 1),
                Err("Codex workspace cursor is stale")
            );
        }

        #[test]
        fn workspace_pagination_cursor_is_bounded_and_ordered() {
            let all = vec![
                workspace("ws_1", r"C:\one"),
                workspace("ws_2", r"C:\two"),
                workspace("ws_3", r"C:\three"),
            ];
            let (first, cursor) =
                paginate_workspaces(all.clone(), "", 2).expect("first page should succeed");
            assert_eq!(
                first
                    .iter()
                    .map(|item| item.id.as_str())
                    .collect::<Vec<_>>(),
                vec!["ws_1", "ws_2"]
            );
            let (second, next) = paginate_workspaces(all, &cursor, 2)
                .expect("second page with matching snapshot should succeed");
            assert_eq!(
                second
                    .iter()
                    .map(|item| item.id.as_str())
                    .collect::<Vec<_>>(),
                vec!["ws_3"]
            );
            assert!(next.is_empty());
        }

        #[test]
        fn codex_mutation_requires_host_control_and_current_session_scope() {
            let request = scoped_start_turn_request();
            assert_eq!(
                authorize_control_operation(&request, false, "scope-1", 4),
                Err((
                    "permission_denied",
                    "Codex control requires remote control permission"
                ))
            );

            let mut forged = request.clone();
            forged.session_identity = "scope-other".into();
            assert_eq!(
                authorize_control_operation(&forged, true, "scope-1", 4),
                Err((
                    "session_mismatch",
                    "Codex operation identity does not match this remote session"
                ))
            );

            let mut stale = request.clone();
            stale.session_generation = 3;
            assert_eq!(
                authorize_control_operation(&stale, true, "scope-1", 4),
                Err((
                    "session_mismatch",
                    "Codex operation identity does not match this remote session"
                ))
            );
        }

        #[test]
        fn codex_thread_ownership_is_connection_scoped_and_released() {
            let mut owners = HashMap::new();
            assert_eq!(claim_thread_owner(&mut owners, "thr_1", 11), Ok(()));
            assert_eq!(require_thread_owner(&owners, "thr_1", 11), Ok(()));
            assert_eq!(
                require_thread_owner(&owners, "thr_1", 22),
                Err("Codex task belongs to a different remote runtime")
            );
            assert_eq!(
                claim_thread_owner(&mut owners, "thr_1", 22),
                Err("Codex task belongs to a different remote runtime")
            );

            release_thread_owners(&mut owners, 11);
            assert_eq!(claim_thread_owner(&mut owners, "thr_1", 22), Ok(()));
            assert_eq!(require_thread_owner(&owners, "thr_1", 22), Ok(()));
        }

        #[test]
        fn stale_completion_cannot_release_a_newer_active_turn() {
            let mut active_turns = HashMap::from([("thr_1".to_owned(), "turn_2".to_owned())]);

            assert!(!complete_active_turn(&mut active_turns, "thr_1", "turn_1"));
            assert_eq!(
                active_turns.get("thr_1").map(String::as_str),
                Some("turn_2")
            );

            assert!(complete_active_turn(&mut active_turns, "thr_1", "turn_2"));
            assert!(!active_turns.contains_key("thr_1"));
        }

        #[test]
        fn stale_started_turn_cannot_replace_a_newer_active_turn() {
            let mut active_turns = HashMap::from([("thr_1".to_owned(), "turn_2".to_owned())]);

            assert!(!remember_started_turn(&mut active_turns, "thr_1", "turn_1"));
            assert_eq!(
                active_turns.get("thr_1").map(String::as_str),
                Some("turn_2")
            );
            assert!(remember_started_turn(&mut active_turns, "thr_1", "turn_2"));
        }

        #[test]
        fn steer_wrong_turn_is_rejected_before_native_control() {
            let active_turns = HashMap::from([("thr_1".to_owned(), "turn_current".to_owned())]);

            assert!(require_active_turn(&active_turns, "thr_1", "turn_current").is_ok());
            assert_eq!(
                require_active_turn(&active_turns, "thr_1", "turn_stale"),
                Err("Codex active turn changed; refresh before controlling it")
            );
        }

        #[test]
        fn completed_turn_tracker_blocks_late_started_event() {
            let mut completed = CompletedTurnTracker::default();
            completed.remember("thr_1", "turn_1");

            assert!(completed.contains("thr_1", "turn_1"));
            assert!(!completed.contains("thr_1", "turn_2"));
        }

        #[test]
        fn connection_scope_change_is_distinguished_from_first_or_repeat_scope() {
            let mut scopes = HashMap::new();
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "scope-1", 4),
                ConnectionScopeUpdate::Established
            );
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "scope-1", 4),
                ConnectionScopeUpdate::Unchanged
            );
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "scope-2", 5),
                ConnectionScopeUpdate::Changed
            );
            assert_eq!(
                scopes.get(&11),
                Some(&CodexConnectionScope {
                    session_identity: "scope-2".into(),
                    session_generation: 5,
                })
            );
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "scope-old", 4),
                ConnectionScopeUpdate::Stale
            );
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "scope-other", 5),
                ConnectionScopeUpdate::Stale
            );
            assert_eq!(
                scopes.get(&11),
                Some(&CodexConnectionScope {
                    session_identity: "scope-2".into(),
                    session_generation: 5,
                })
            );
            assert_eq!(
                remember_connection_scope(&mut scopes, 11, "", 0),
                ConnectionScopeUpdate::Invalid
            );
            assert_eq!(
                scopes.get(&11),
                Some(&CodexConnectionScope {
                    session_identity: "scope-2".into(),
                    session_generation: 5,
                })
            );
        }

        #[test]
        fn invalidating_connection_scope_drops_owned_runtime_state() {
            let mut bridge = None;
            let mut subscribers = HashMap::new();
            let mut owners = HashMap::from([("thr_1".to_owned(), 11)]);
            let approval = BridgeApproval {
                id: "approval_1".into(),
                thread_id: "thr_1".into(),
                turn_id: "turn_1".into(),
                item_id: "item_1".into(),
                kind: BridgeApprovalKind::Command,
                title: "Approval".into(),
                summary: String::new(),
                reason: String::new(),
                working_directory: String::new(),
                scope: String::new(),
                started_at_ms: 1,
                actionable: true,
            };
            let mut approval_bindings = HashMap::from([(
                approval.id.clone(),
                CodexApprovalBinding::new(11, "scope-1", 4, &approval),
            )]);
            let mut active_turns = HashMap::from([("thr_1".to_owned(), "turn_1".to_owned())]);
            let mut queued_turns = HashMap::from([(
                "thr_1".to_owned(),
                VecDeque::from([QueuedCodexTurn {
                    connection_id: 11,
                    session_identity: "scope-1".into(),
                    session_generation: 4,
                    thread_id: "thr_1".into(),
                    operation_id: "op-next".into(),
                    text: "next".into(),
                }]),
            )]);
            let mut replays = HashMap::from([(11, CodexControlReplay::default())]);

            invalidate_connection_state(
                11,
                &mut bridge,
                &mut subscribers,
                &mut owners,
                &mut approval_bindings,
                &mut active_turns,
                &mut queued_turns,
                &mut replays,
            );

            assert!(owners.is_empty());
            assert!(approval_bindings.is_empty());
            assert!(active_turns.is_empty());
            assert!(queued_turns.is_empty());
            assert!(!replays.contains_key(&11));
        }

        #[test]
        fn queued_turns_are_fifo_and_bound_to_the_original_session_scope() {
            let mut scopes = HashMap::from([(
                11,
                CodexConnectionScope {
                    session_identity: "scope-1".into(),
                    session_generation: 4,
                },
            )]);
            let queued = |text: &str| QueuedCodexTurn {
                connection_id: 11,
                session_identity: "scope-1".into(),
                session_generation: 4,
                thread_id: "thr_1".into(),
                operation_id: format!("op-{text}"),
                text: text.into(),
            };
            let mut queues = HashMap::from([(
                "thr_1".to_owned(),
                VecDeque::from([queued("first"), queued("second")]),
            )]);
            assert_eq!(queued_turn_count(&queues), 2);

            let first = pop_next_queued_turn("thr_1", Some(11), &scopes, &mut queues)
                .expect("first queued turn should be eligible");
            assert_eq!(first.text, "first");
            assert_eq!(queued_turn_count(&queues), 1);

            scopes.get_mut(&11).unwrap().session_generation = 5;
            assert!(pop_next_queued_turn("thr_1", Some(11), &scopes, &mut queues).is_none());
            assert_eq!(queued_turn_count(&queues), 0);
            assert!(!queues.contains_key("thr_1"));
        }

        #[test]
        fn approval_wrong_runtime_rejected() {
            let approval = BridgeApproval {
                id: "approval_1".into(),
                thread_id: "thr_1".into(),
                turn_id: "turn_1".into(),
                item_id: "item_1".into(),
                kind: BridgeApprovalKind::Command,
                title: "Command approval".into(),
                summary: "cargo test".into(),
                reason: String::new(),
                working_directory: String::new(),
                scope: String::new(),
                started_at_ms: 1,
                actionable: true,
            };
            let binding = CodexApprovalBinding::new(11, "scope-1", 4, &approval);

            assert!(binding.matches(11, "scope-1", 4, &approval));
            assert!(!binding.matches(22, "scope-1", 4, &approval));
            assert!(!binding.matches(11, "scope-2", 4, &approval));
            assert!(!binding.matches(11, "scope-1", 5, &approval));
        }

        #[test]
        fn expired_approval_not_replayed() {
            let approval = BridgeApproval {
                id: "approval_1".into(),
                thread_id: "thr_1".into(),
                turn_id: "turn_1".into(),
                item_id: "item_1".into(),
                kind: BridgeApprovalKind::FileChange,
                title: "File change approval".into(),
                summary: "Codex wants to apply file changes.".into(),
                reason: String::new(),
                working_directory: String::new(),
                scope: "C:\\repo".into(),
                started_at_ms: 1,
                actionable: true,
            };
            let mut bindings = HashMap::new();

            bind_approval_to_scope(&mut bindings, &approval, 11, "scope-1", 4);
            bind_approval_to_scope(&mut bindings, &approval, 11, "scope-1", 5);

            let binding = bindings
                .get(&approval.id)
                .expect("first approval binding should be retained");
            assert!(binding.matches(11, "scope-1", 4, &approval));
            assert!(!binding.matches(11, "scope-1", 5, &approval));
        }

        #[test]
        fn codex_mutation_target_is_bound_to_the_exact_action() {
            let request = scoped_start_turn_request();
            let key = authorize_control_operation(&request, true, "scope-1", 4)
                .expect("matching operation should be authorized");
            assert_eq!(key.target_identity, "thread:thr_1/turn:new");
            assert_eq!(key.action, "start_turn");

            let mut forged = request;
            forged.target_identity = "thread:thr_2/turn:new".into();
            assert_eq!(
                authorize_control_operation(&forged, true, "scope-1", 4),
                Err((
                    "target_mismatch",
                    "Codex operation target does not match the requested action"
                ))
            );
        }

        #[test]
        fn exact_duplicate_codex_operation_replays_but_reuse_is_rejected() {
            let request = scoped_start_turn_request();
            let key = authorize_control_operation(&request, true, "scope-1", 4).unwrap();
            let mut replay = CodexControlReplay::default();
            replay.record(
                key.clone(),
                CodexControlResponse {
                    request_id: "request-1".into(),
                    operation_id: key.operation_id.clone(),
                    session_identity: key.session_identity.clone(),
                    target_identity: key.target_identity.clone(),
                    session_generation: key.session_generation,
                    accepted: true,
                    applied: true,
                    ..Default::default()
                },
            );

            match replay.lookup(&key, "request-2") {
                ReplayLookup::Replay(response) => {
                    assert_eq!(response.request_id, "request-2");
                    assert!(response.accepted);
                    assert!(response.applied);
                }
                _ => panic!("exact duplicate should replay the cached result"),
            }

            let mut changed_payload = request.clone();
            if let Some(codex_control_request::Union::StartTurn(start)) =
                changed_payload.union.as_mut()
            {
                start.text = "different instruction".into();
            }
            let changed_payload_key =
                authorize_control_operation(&changed_payload, true, "scope-1", 4).unwrap();
            assert_eq!(changed_payload_key.target_identity, key.target_identity);
            assert_ne!(
                changed_payload_key.payload_fingerprint,
                key.payload_fingerprint
            );
            assert!(matches!(
                replay.lookup(&changed_payload_key, "request-payload"),
                ReplayLookup::Conflict
            ));

            let mut changed = key;
            changed.target_identity = "thread:thr_2/turn:new".into();
            assert!(matches!(
                replay.lookup(&changed, "request-3"),
                ReplayLookup::Conflict
            ));
        }

        #[test]
        fn approval_operation_binds_item_turn_and_decision() {
            let mut request = CodexControlRequest {
                request_id: "approval-request".into(),
                operation_id: "approval-operation".into(),
                session_identity: "scope-1".into(),
                target_identity:
                    "approval:approval_1/thread:thr_1/turn:turn_1/item:item_1/decision:approve"
                        .into(),
                session_generation: 4,
                ..Default::default()
            };
            request.set_respond_approval(CodexRespondApprovalRequest {
                approval_id: "approval_1".into(),
                thread_id: "thr_1".into(),
                turn_id: "turn_1".into(),
                item_id: "item_1".into(),
                decision: CodexApprovalDecision::CodexApprovalApprove.into(),
                ..Default::default()
            });

            let key = authorize_control_operation(&request, true, "scope-1", 4).unwrap();
            assert_eq!(key.target_identity, request.target_identity);

            if let Some(codex_control_request::Union::RespondApproval(approval)) =
                request.union.as_mut()
            {
                approval.item_id = "item_other".into();
            }
            assert_eq!(
                authorize_control_operation(&request, true, "scope-1", 4),
                Err((
                    "target_mismatch",
                    "Codex operation target does not match the requested action"
                ))
            );
        }

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
            assert_eq!(
                map_thread_state_for_connection(CodexThreadStatus::Working, false),
                CodexState::CodexResumable
            );
            assert_eq!(
                map_thread_state_for_connection(CodexThreadStatus::Working, true),
                CodexState::CodexWorking
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
            assert!(event.operation_id.is_empty());
        }

        #[test]
        fn queued_start_event_carries_exact_queue_operation_id() {
            let response = event_response_with_operation(
                BridgeEvent {
                    thread_id: "thr_1".into(),
                    turn_id: "turn_2".into(),
                    item_id: String::new(),
                    kind: BridgeEventKind::TurnStarted,
                    state: Some(CodexThreadStatus::Working),
                    history_kind: None,
                    text: String::new(),
                    status: "queuedStart".into(),
                },
                "operation-queue-1",
            );

            let Some(codex_read_response::Union::Event(event)) = response.union else {
                panic!("expected queued-start event response")
            };
            assert_eq!(event.operation_id, "operation-queue-1");
            assert_eq!(event.status, "queuedStart");
        }
    }
}

#[cfg(target_os = "windows")]
pub(crate) use windows::{disconnect_client, submit_control_request, submit_read_request};
