mod approvals;
mod control;
mod discovery;
mod events;
mod history;
mod process;
mod protocol;
mod rpc;
mod service;
mod threads;
#[cfg(target_os = "windows")]
mod windows_app;

pub use approvals::{
    CodexApproval, CodexApprovalDecision, CodexApprovalKind, CodexResolvedApproval,
};
pub use discovery::{discover_installation, CodexInstallation};
pub use events::{CodexEvent, CodexEventKind};
pub use history::{CodexHistoryItem, CodexHistoryItemKind, CodexHistoryPage};
pub use process::CodexConnectionMode;
pub use protocol::CodexServerInfo;
pub use service::is_available;
pub use threads::{CodexThreadStatus, CodexThreadSummary};

#[cfg(target_os = "windows")]
pub(crate) use service::{disconnect_client, submit_control_request, submit_read_request};

use hbb_common::{bail, ResultType};
use process::{connection_mode_order, managed_daemon_healthy, CodexProcess};
use protocol::CodexProtocol;
use rpc::JsonRpcClient;
use std::{collections::HashSet, process::ChildStdin, time::Duration};

const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(5);
const CORE_PROBE_TIMEOUT: Duration = Duration::from_secs(5);
const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);

pub struct CodexBridge {
    protocol: CodexProtocol<ChildStdin>,
    _process: CodexProcess,
    server_info: CodexServerInfo,
    connection_mode: CodexConnectionMode,
    owned_threads: HashSet<String>,
    approvals: approvals::PendingApprovals,
}

pub(crate) enum CodexBridgeUpdate {
    Event(CodexEvent),
    ApprovalRequested(CodexApproval),
}

impl CodexBridge {
    pub fn connect(installation: &CodexInstallation) -> ResultType<Self> {
        let modes = connection_mode_order(managed_daemon_healthy(installation));
        match first_successful_mode(modes, |mode| Self::connect_mode(installation, mode)) {
            Ok(bridge) => Ok(bridge),
            Err(errors) => {
                let details = errors
                    .into_iter()
                    .map(|(mode, error)| format!("{mode:?}: {error}"))
                    .collect::<Vec<_>>()
                    .join("; ");
                bail!("Unable to connect to Codex app-server: {details}")
            }
        }
    }

    pub fn server_info(&self) -> &CodexServerInfo {
        &self.server_info
    }

    pub fn connection_mode(&self) -> CodexConnectionMode {
        self.connection_mode
    }

    pub(crate) fn list_threads(&mut self) -> Result<Vec<CodexThreadSummary>, rpc::RpcCallError> {
        let mut threads = threads::list_threads(&mut self.protocol, Duration::from_secs(10))?;
        for thread in &mut threads {
            if !self.owned_threads.contains(&thread.id) {
                // A fresh app-server can see persisted threads created by Codex Desktop,
                // but it does not own Desktop's live runtime. Require an explicit native
                // resume before RustDesk presents a thread as controllable.
                thread.status = CodexThreadStatus::Resumable;
            }
        }
        Ok(threads)
    }

    pub(crate) fn control_support(&self) -> control::CodexControlSupport {
        control::support(&self.protocol)
    }

    pub(crate) fn resume_thread(
        &mut self,
        thread_id: &str,
    ) -> Result<control::CodexControlOutcome, rpc::RpcCallError> {
        let outcome = control::resume_thread(&mut self.protocol, thread_id, CONTROL_TIMEOUT)?;
        self.owned_threads.insert(outcome.thread_id.clone());
        Ok(outcome)
    }

    pub(crate) fn start_thread(
        &mut self,
        workspace_thread_id: Option<&str>,
    ) -> Result<control::CodexControlOutcome, rpc::RpcCallError> {
        let workspace = match workspace_thread_id {
            Some(thread_id) => Some(control::workspace_for_thread(
                &mut self.protocol,
                thread_id,
                CONTROL_TIMEOUT,
            )?),
            None => None,
        };
        let outcome =
            control::start_thread(&mut self.protocol, workspace.as_deref(), CONTROL_TIMEOUT)?;
        self.owned_threads.insert(outcome.thread_id.clone());
        Ok(outcome)
    }

    pub(crate) fn start_turn(
        &mut self,
        thread_id: &str,
        text: &str,
    ) -> Result<control::CodexControlOutcome, rpc::RpcCallError> {
        self.require_owned_thread(thread_id)?;
        control::start_turn(&mut self.protocol, thread_id, text, CONTROL_TIMEOUT)
    }

    pub(crate) fn steer_turn(
        &mut self,
        thread_id: &str,
        turn_id: &str,
        text: &str,
    ) -> Result<control::CodexControlOutcome, rpc::RpcCallError> {
        self.require_owned_thread(thread_id)?;
        control::steer_turn(
            &mut self.protocol,
            thread_id,
            turn_id,
            text,
            CONTROL_TIMEOUT,
        )
    }

    pub(crate) fn interrupt_turn(
        &mut self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<(), rpc::RpcCallError> {
        self.require_owned_thread(thread_id)?;
        control::interrupt_turn(&mut self.protocol, thread_id, turn_id, CONTROL_TIMEOUT)
    }

    pub(crate) fn pending_approvals(&self, thread_id: &str) -> Vec<CodexApproval> {
        self.approvals.for_thread(thread_id)
    }

    pub(crate) fn respond_to_approval(
        &mut self,
        approval_id: &str,
        thread_id: &str,
        turn_id: &str,
        decision: CodexApprovalDecision,
    ) -> Result<CodexResolvedApproval, rpc::RpcCallError> {
        self.require_owned_thread(thread_id)?;
        let response = self
            .approvals
            .begin_response(approval_id, thread_id, turn_id, decision)?;
        self.protocol
            .respond_server_request(response.rpc_id, response.result)?;
        self.approvals.complete_response(approval_id);
        Ok(response.resolved)
    }

    fn require_owned_thread(&self, thread_id: &str) -> Result<(), rpc::RpcCallError> {
        require_owned_thread_id(&self.owned_threads, thread_id)
    }

    pub(crate) fn thread_history(
        &mut self,
        thread_id: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CodexHistoryPage, rpc::RpcCallError> {
        history::list_history(
            &mut self.protocol,
            thread_id,
            cursor,
            limit,
            Duration::from_secs(10),
        )
    }

    pub(crate) fn drain_updates(&mut self) -> Result<Vec<CodexBridgeUpdate>, rpc::RpcCallError> {
        let mut updates = Vec::new();
        for message in self.protocol.drain_available()? {
            if let Some(request) = rpc::server_request(&message) {
                if let Some(approval) = self.approvals.register(request, &self.owned_threads) {
                    updates.push(CodexBridgeUpdate::ApprovalRequested(approval));
                }
                continue;
            }
            if let Some(event) = events::normalize_notification(&message) {
                if event.kind == CodexEventKind::TurnCompleted && !event.turn_id.is_empty() {
                    self.approvals
                        .remove_for_turn(&event.thread_id, &event.turn_id);
                }
                updates.push(CodexBridgeUpdate::Event(event));
            }
        }
        Ok(updates)
    }

    pub(crate) fn drain_events(&mut self) -> Result<Vec<CodexEvent>, rpc::RpcCallError> {
        Ok(self
            .drain_updates()?
            .into_iter()
            .filter_map(|update| match update {
                CodexBridgeUpdate::Event(event) => Some(event),
                CodexBridgeUpdate::ApprovalRequested(_) => None,
            })
            .collect())
    }

    fn connect_mode(
        installation: &CodexInstallation,
        mode: CodexConnectionMode,
    ) -> Result<Self, String> {
        let mut process =
            CodexProcess::start(installation, mode).map_err(|error| error.to_string())?;
        let connection_mode = process.mode();
        let (stdout, stdin) = process.take_streams().map_err(|error| error.to_string())?;
        let rpc = JsonRpcClient::from_streams(stdout, stdin);
        let mut protocol = CodexProtocol::new(rpc);
        let server_info = protocol
            .initialize(INITIALIZE_TIMEOUT)
            .map_err(|error| error.to_string())?;
        if !server_info.platform_family.eq_ignore_ascii_case("windows")
            || !server_info.platform_os.eq_ignore_ascii_case("windows")
        {
            return Err(format!(
                "unsupported Codex platform {}/{}",
                server_info.platform_family, server_info.platform_os
            ));
        }
        protocol
            .probe_core(CORE_PROBE_TIMEOUT)
            .map_err(|error| error.to_string())?;
        protocol
            .probe_control(CORE_PROBE_TIMEOUT)
            .map_err(|error| error.to_string())?;

        Ok(Self {
            protocol,
            _process: process,
            server_info,
            connection_mode,
            owned_threads: HashSet::new(),
            approvals: approvals::PendingApprovals::default(),
        })
    }
}

fn require_owned_thread_id(
    owned_threads: &HashSet<String>,
    thread_id: &str,
) -> Result<(), rpc::RpcCallError> {
    if owned_threads.contains(thread_id) {
        Ok(())
    } else {
        Err(rpc::RpcCallError::Protocol(
            "Codex thread is stored but is not attached to the RustDesk native runtime; resume it natively first".into(),
        ))
    }
}

fn first_successful_mode<T, E, F>(
    modes: Vec<CodexConnectionMode>,
    mut attempt: F,
) -> Result<T, Vec<(CodexConnectionMode, E)>>
where
    F: FnMut(CodexConnectionMode) -> Result<T, E>,
{
    let mut errors = Vec::new();
    for mode in modes {
        match attempt(mode) {
            Ok(value) => return Ok(value),
            Err(error) => errors.push((mode, error)),
        }
    }
    Err(errors)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{thread, time::Instant};

    #[test]
    fn connection_attempts_fall_back_to_direct_stdio() {
        let modes = vec![
            CodexConnectionMode::ManagedProxy,
            CodexConnectionMode::DirectStdio,
        ];
        let mut attempted = Vec::new();

        let result = first_successful_mode(modes, |mode| {
            attempted.push(mode);
            match mode {
                CodexConnectionMode::ManagedProxy => Err("proxy unavailable"),
                CodexConnectionMode::DirectStdio => Ok("connected"),
            }
        });

        assert_eq!(result, Ok("connected"));
        assert_eq!(
            attempted,
            vec![
                CodexConnectionMode::ManagedProxy,
                CodexConnectionMode::DirectStdio
            ]
        );
    }

    #[test]
    fn persisted_threads_require_explicit_native_ownership_before_control() {
        let mut owned = HashSet::new();
        let error = require_owned_thread_id(&owned, "thr_desktop")
            .expect_err("persisted Desktop thread must not be treated as bridge-owned");
        assert!(error.to_string().contains("resume it natively first"));

        owned.insert("thr_desktop".to_owned());
        assert!(require_owned_thread_id(&owned, "thr_desktop").is_ok());
    }

    #[test]
    #[ignore = "requires a local Codex installation, authenticated user session, and creates a disposable thread"]
    fn codex_local_control_smoke() {
        let installation = discover_installation()
            .expect("local Codex discovery should run")
            .expect("Codex must be installed for this ignored test");
        let mut bridge =
            CodexBridge::connect(&installation).expect("local Codex bridge should connect");
        let support = bridge.control_support();
        assert!(support.start_thread, "thread/start must be available");
        assert!(support.start_turn, "turn/start must be available");
        assert!(support.interrupt_turn, "turn/interrupt must be available");

        let thread_outcome = bridge
            .start_thread(None)
            .expect("fresh disposable Codex thread should start");
        assert!(!thread_outcome.thread_id.is_empty());

        let turn_outcome = bridge
            .start_turn(
                &thread_outcome.thread_id,
                "Run this harmless shell command and wait for it to finish before replying: powershell -NoProfile -Command \"Start-Sleep -Seconds 15\". Do not inspect or modify files.",
            )
            .expect("disposable Codex turn should start");
        let turn_id = turn_outcome.turn_id;
        assert!(!turn_id.is_empty());

        let activation_deadline = Instant::now() + Duration::from_secs(10);
        let mut active = false;
        while Instant::now() < activation_deadline && !active {
            for event in bridge
                .drain_events()
                .expect("Codex live events should remain readable")
            {
                if event.thread_id == thread_outcome.thread_id
                    && event.turn_id == turn_id
                    && event.kind == CodexEventKind::TurnStarted
                {
                    active = true;
                    break;
                }
            }
            if !active {
                thread::sleep(Duration::from_millis(50));
            }
        }
        assert!(active, "turn/started event was not observed");

        bridge
            .interrupt_turn(&thread_outcome.thread_id, &turn_id)
            .expect("active disposable turn should interrupt");

        let deadline = Instant::now() + Duration::from_secs(20);
        let mut interrupted = false;
        while Instant::now() < deadline && !interrupted {
            for event in bridge
                .drain_events()
                .expect("Codex live events should remain readable")
            {
                if event.thread_id == thread_outcome.thread_id
                    && event.turn_id == turn_id
                    && event.kind == CodexEventKind::TurnCompleted
                    && event.status == "interrupted"
                {
                    interrupted = true;
                    break;
                }
            }
            if !interrupted {
                thread::sleep(Duration::from_millis(50));
            }
        }

        assert!(
            interrupted,
            "interrupted turn completion event was not observed"
        );
    }

    #[test]
    #[ignore = "requires a local Codex installation and authenticated user session; creates an ephemeral approval-gated turn"]
    fn codex_local_approval_smoke() {
        let installation = discover_installation()
            .expect("local Codex discovery should run")
            .expect("Codex must be installed for this ignored test");
        let mut bridge =
            CodexBridge::connect(&installation).expect("local Codex bridge should connect");

        let result = bridge
            .protocol
            .request(
                protocol::CodexMethod::ThreadStart,
                json!({
                    "ephemeral": true,
                    "approvalPolicy": "untrusted",
                    "approvalsReviewer": "user"
                }),
                CONTROL_TIMEOUT,
            )
            .expect("ephemeral approval smoke thread should start");
        let thread_id = result
            .get("thread")
            .and_then(|thread| thread.get("id"))
            .and_then(serde_json::Value::as_str)
            .expect("thread/start should return a thread id")
            .to_owned();
        assert_eq!(result.get("approvalPolicy"), Some(&json!("untrusted")));
        assert_eq!(result.get("approvalsReviewer"), Some(&json!("user")));
        bridge.owned_threads.insert(thread_id.clone());

        let turn = bridge
            .start_turn(
                &thread_id,
                "Run exactly this harmless command once, wait for it to finish, then reply with its output: powershell -NoProfile -Command \"Write-Output checkpoint5-approval-smoke\". Do not inspect or modify files.",
            )
            .expect("approval smoke turn should start");
        let turn_id = turn.turn_id;

        let approval_deadline = Instant::now() + Duration::from_secs(45);
        let mut observed = Vec::new();
        let approval = loop {
            let mut found = None;
            for update in bridge
                .drain_updates()
                .expect("Codex approval events should remain readable")
            {
                match update {
                    CodexBridgeUpdate::ApprovalRequested(approval) => {
                        observed.push(format!("approval:{:?}", approval.kind));
                        if approval.thread_id == thread_id && approval.turn_id == turn_id {
                            found = Some(approval);
                            break;
                        }
                    }
                    CodexBridgeUpdate::Event(event) => observed.push(format!(
                        "event:{:?}:{}:{}",
                        event.kind, event.status, event.turn_id
                    )),
                }
            }
            if let Some(approval) = found {
                break approval;
            }
            if Instant::now() >= approval_deadline {
                panic!("harmless command approval was not observed; updates={observed:?}");
            }
            thread::sleep(Duration::from_millis(50));
        };

        assert_eq!(approval.kind, CodexApprovalKind::Command);
        assert!(approval.actionable);
        assert_eq!(bridge.pending_approvals(&thread_id).len(), 1);

        let resolved = bridge
            .respond_to_approval(
                &approval.id,
                &thread_id,
                &turn_id,
                CodexApprovalDecision::Approve,
            )
            .expect("harmless command approval should be accepted");
        assert_eq!(resolved.id, approval.id);
        assert_eq!(resolved.decision, CodexApprovalDecision::Approve);
        assert!(bridge.pending_approvals(&thread_id).is_empty());

        let completion_deadline = Instant::now() + Duration::from_secs(60);
        let mut completed = false;
        while Instant::now() < completion_deadline && !completed {
            for update in bridge
                .drain_updates()
                .expect("Codex events should remain readable after approval")
            {
                if let CodexBridgeUpdate::Event(event) = update {
                    if event.thread_id == thread_id
                        && event.turn_id == turn_id
                        && event.kind == CodexEventKind::TurnCompleted
                    {
                        assert_ne!(event.status, "failed", "approved turn failed");
                        completed = true;
                        break;
                    }
                }
            }
            if !completed {
                thread::sleep(Duration::from_millis(50));
            }
        }

        assert!(completed, "approved turn did not continue to completion");
    }
}
