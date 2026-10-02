use super::rpc::{RpcCallError, RpcServerRequest};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const MAX_COMMAND_CHARS: usize = 4096;
const MAX_REASON_CHARS: usize = 2048;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexApprovalKind {
    Command,
    FileChange,
    Permissions,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexApprovalDecision {
    Approve,
    Deny,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexApproval {
    pub id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub kind: CodexApprovalKind,
    pub title: String,
    pub summary: String,
    pub reason: String,
    pub started_at_ms: i64,
    pub actionable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexResolvedApproval {
    pub id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub decision: CodexApprovalDecision,
}

struct PendingApproval {
    public: CodexApproval,
    rpc_id: Value,
    response_kind: ResponseKind,
    response_attempted: bool,
}

#[derive(Clone, Copy)]
enum ResponseKind {
    Decision,
    UnsupportedPermissions,
}

pub(crate) struct PendingApprovalResponse {
    pub rpc_id: Value,
    pub result: Value,
    pub resolved: CodexResolvedApproval,
}

#[derive(Default)]
pub(crate) struct PendingApprovals {
    entries: HashMap<String, PendingApproval>,
}

impl PendingApprovals {
    pub(crate) fn register(
        &mut self,
        request: RpcServerRequest,
        owned_threads: &HashSet<String>,
    ) -> Option<CodexApproval> {
        if let Some(existing) = self
            .entries
            .values()
            .find(|entry| entry.rpc_id == request.id)
        {
            return Some(existing.public.clone());
        }

        let params = &request.params;
        let thread_id = required_string(params, "threadId")?;
        if !owned_threads.contains(&thread_id) {
            return None;
        }
        let turn_id = required_string(params, "turnId")?;
        let item_id = required_string(params, "itemId")?;
        let started_at_ms = params
            .get("startedAtMs")
            .and_then(Value::as_i64)
            .unwrap_or_default();

        let (kind, title, summary, reason, actionable, response_kind) =
            match request.method.as_str() {
                "item/commandExecution/requestApproval" => (
                    CodexApprovalKind::Command,
                    "Command approval".to_owned(),
                    sanitize_public_text(
                        params
                            .get("command")
                            .and_then(Value::as_str)
                            .unwrap_or("Command execution requested"),
                        MAX_COMMAND_CHARS,
                    ),
                    sanitize_public_text(
                        params
                            .get("reason")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                        MAX_REASON_CHARS,
                    ),
                    true,
                    ResponseKind::Decision,
                ),
                "item/fileChange/requestApproval" => (
                    CodexApprovalKind::FileChange,
                    "File change approval".to_owned(),
                    "Codex wants to apply file changes.".to_owned(),
                    sanitize_public_text(
                        params
                            .get("reason")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                        MAX_REASON_CHARS,
                    ),
                    true,
                    ResponseKind::Decision,
                ),
                "item/permissions/requestApproval" => (
                    CodexApprovalKind::Permissions,
                    "Permission approval".to_owned(),
                    "This permission request must be handled on Windows.".to_owned(),
                    sanitize_public_text(
                        params
                            .get("reason")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                        MAX_REASON_CHARS,
                    ),
                    false,
                    ResponseKind::UnsupportedPermissions,
                ),
                _ => return None,
            };

        let id = format!("codex-approval-{}", Uuid::new_v4());
        let public = CodexApproval {
            id: id.clone(),
            thread_id,
            turn_id,
            item_id,
            kind,
            title,
            summary,
            reason,
            started_at_ms,
            actionable,
        };
        self.entries.insert(
            id,
            PendingApproval {
                public: public.clone(),
                rpc_id: request.id,
                response_kind,
                response_attempted: false,
            },
        );
        Some(public)
    }

    pub(crate) fn for_thread(&self, thread_id: &str) -> Vec<CodexApproval> {
        let mut approvals = self
            .entries
            .values()
            .filter(|entry| entry.public.thread_id == thread_id)
            .map(|entry| entry.public.clone())
            .collect::<Vec<_>>();
        approvals.sort_by_key(|approval| approval.started_at_ms);
        approvals
    }

    pub(crate) fn begin_response(
        &mut self,
        approval_id: &str,
        thread_id: &str,
        turn_id: &str,
        decision: CodexApprovalDecision,
    ) -> Result<PendingApprovalResponse, RpcCallError> {
        let Some(entry) = self.entries.get(approval_id) else {
            return Err(RpcCallError::Protocol(
                "Codex approval is stale or already resolved".into(),
            ));
        };
        if entry.public.thread_id != thread_id || entry.public.turn_id != turn_id {
            return Err(RpcCallError::Protocol(
                "Codex approval identity does not match the active request".into(),
            ));
        }
        if matches!(entry.response_kind, ResponseKind::UnsupportedPermissions) {
            return Err(RpcCallError::Protocol(
                "Codex permission approval is not supported remotely".into(),
            ));
        }
        if entry.response_attempted {
            return Err(RpcCallError::Protocol(
                "Codex approval response outcome is unknown and cannot be retried".into(),
            ));
        }

        let entry = self
            .entries
            .get_mut(approval_id)
            .expect("approval checked above");
        entry.response_attempted = true;
        entry.public.actionable = false;
        let decision_value = match decision {
            CodexApprovalDecision::Approve => "accept",
            CodexApprovalDecision::Deny => "decline",
        };
        Ok(PendingApprovalResponse {
            rpc_id: entry.rpc_id.clone(),
            result: json!({"decision": decision_value}),
            resolved: CodexResolvedApproval {
                id: entry.public.id.clone(),
                thread_id: entry.public.thread_id.clone(),
                turn_id: entry.public.turn_id.clone(),
                decision,
            },
        })
    }

    pub(crate) fn complete_response(&mut self, approval_id: &str) {
        self.entries.remove(approval_id);
    }

    pub(crate) fn remove_for_turn(&mut self, thread_id: &str, turn_id: &str) {
        self.entries.retain(|_, entry| {
            entry.public.thread_id != thread_id || entry.public.turn_id != turn_id
        });
    }
}

fn required_string(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)?
        .as_str()
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn sanitize_public_text(value: &str, max_chars: usize) -> String {
    redact_windows_paths(&truncate(value, max_chars))
}

fn redact_windows_paths(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = String::with_capacity(value.len());
    let mut cursor = 0;
    let mut index = 0;

    while index < bytes.len() {
        let boundary = index == 0
            || bytes[index - 1].is_ascii_whitespace()
            || matches!(bytes[index - 1], b'\'' | b'"' | b'=' | b'(' | b'[' | b'{');
        let drive_path = boundary
            && index + 2 < bytes.len()
            && bytes[index].is_ascii_alphabetic()
            && bytes[index + 1] == b':'
            && matches!(bytes[index + 2], b'\\' | b'/');
        let unc_path = boundary
            && index + 1 < bytes.len()
            && bytes[index] == b'\\'
            && bytes[index + 1] == b'\\';

        if !drive_path && !unc_path {
            index += value[index..]
                .chars()
                .next()
                .map(char::len_utf8)
                .unwrap_or(1);
            continue;
        }

        output.push_str(&value[cursor..index]);
        output.push_str("<local-path>");

        let quote = if index > 0 && matches!(bytes[index - 1], b'\'' | b'"') {
            Some(bytes[index - 1])
        } else {
            None
        };
        let mut end = index;
        while end < bytes.len() {
            let byte = bytes[end];
            if quote.is_some_and(|quote| byte == quote)
                || (quote.is_none()
                    && (byte.is_ascii_whitespace()
                        || matches!(byte, b'\'' | b'"' | b';' | b'|' | b'&' | b'<' | b'>')))
            {
                break;
            }
            end += 1;
        }
        cursor = end;
        index = end;
    }

    output.push_str(&value[cursor..]);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned() -> HashSet<String> {
        HashSet::from(["thr_1".to_owned()])
    }

    #[test]
    fn command_approval_exposes_command_but_not_local_paths_or_raw_policy_data() {
        let mut approvals = PendingApprovals::default();
        let approval = approvals
            .register(
                RpcServerRequest {
                    id: json!(91),
                    method: "item/commandExecution/requestApproval".into(),
                    params: json!({
                        "threadId":"thr_1","turnId":"turn_1","itemId":"item_1","startedAtMs":123,
                        "command":"powershell -File \"C:\\Users\\private\\My Script.ps1\" -Arg C:\\secret\\input.txt",
                        "cwd":"C:\\Users\\private\\repo",
                        "reason":"Run tests from C:\\Users\\private\\repo",
                        "proposedExecpolicyAmendment":["secret-policy"]
                    }),
                },
                &owned(),
            )
            .expect("supported command approval should normalize");

        assert_eq!(approval.kind, CodexApprovalKind::Command);
        assert_eq!(
            approval.summary,
            "powershell -File \"<local-path>\" -Arg <local-path>"
        );
        assert_eq!(approval.reason, "Run tests from <local-path>");
        let public = format!("{approval:?}");
        assert!(!public.contains("Users\\private"));
        assert!(!public.contains("secret\\input"));
        assert!(!public.contains("secret-policy"));
    }

    #[test]
    fn file_change_approval_never_exposes_grant_root_or_diff_content() {
        let mut approvals = PendingApprovals::default();
        let approval = approvals
            .register(
                RpcServerRequest {
                    id: json!(92),
                    method: "item/fileChange/requestApproval".into(),
                    params: json!({
                        "threadId":"thr_1","turnId":"turn_1","itemId":"item_2","startedAtMs":124,
                        "grantRoot":"C:\\secret-root","reason":"Apply generated changes from \\\\private-server\\share\\repo","diff":"private diff"
                    }),
                },
                &owned(),
            )
            .expect("supported file approval should normalize");

        assert_eq!(approval.kind, CodexApprovalKind::FileChange);
        assert_eq!(approval.reason, "Apply generated changes from <local-path>");
        let public = format!("{approval:?}");
        assert!(!public.contains("secret-root"));
        assert!(!public.contains("private-server"));
        assert!(!public.contains("private diff"));
    }

    #[test]
    fn response_is_one_shot_and_bound_to_thread_and_turn() {
        let mut approvals = PendingApprovals::default();
        let approval = approvals
            .register(
                RpcServerRequest {
                    id: json!(93),
                    method: "item/commandExecution/requestApproval".into(),
                    params: json!({"threadId":"thr_1","turnId":"turn_1","itemId":"item_3","startedAtMs":125,"command":"cargo test"}),
                },
                &owned(),
            )
            .unwrap();

        assert!(approvals
            .begin_response(
                &approval.id,
                "thr_wrong",
                "turn_1",
                CodexApprovalDecision::Approve
            )
            .is_err());
        assert!(approvals
            .begin_response(
                &approval.id,
                "thr_1",
                "turn_wrong",
                CodexApprovalDecision::Approve
            )
            .is_err());

        let response = approvals
            .begin_response(
                &approval.id,
                "thr_1",
                "turn_1",
                CodexApprovalDecision::Approve,
            )
            .expect("matching approval should be consumable once");
        assert_eq!(response.rpc_id, json!(93));
        assert_eq!(response.result, json!({"decision":"accept"}));
        let pending = approvals.for_thread("thr_1");
        assert_eq!(pending.len(), 1);
        assert!(!pending[0].actionable);
        assert!(approvals
            .begin_response(&approval.id, "thr_1", "turn_1", CodexApprovalDecision::Deny)
            .is_err());
        approvals.complete_response(&approval.id);
        assert!(approvals.for_thread("thr_1").is_empty());
    }

    #[test]
    fn deny_maps_to_decline_response() {
        let mut approvals = PendingApprovals::default();
        let approval = approvals
            .register(
                RpcServerRequest {
                    id: json!(101),
                    method: "item/commandExecution/requestApproval".into(),
                    params: json!({
                        "threadId":"thr_1","turnId":"turn_1","itemId":"item_101",
                        "startedAtMs":101,"command":"cargo test"
                    }),
                },
                &owned(),
            )
            .unwrap();

        let response = approvals
            .begin_response(&approval.id, "thr_1", "turn_1", CodexApprovalDecision::Deny)
            .expect("matching approval should support denial");

        assert_eq!(response.rpc_id, json!(101));
        assert_eq!(response.result, json!({"decision":"decline"}));
        assert_eq!(response.resolved.decision, CodexApprovalDecision::Deny);
    }

    #[test]
    fn permissions_approval_is_visible_but_not_actionable() {
        let mut approvals = PendingApprovals::default();
        let approval = approvals
            .register(
                RpcServerRequest {
                    id: json!(94),
                    method: "item/permissions/requestApproval".into(),
                    params: json!({
                        "threadId":"thr_1","turnId":"turn_1","itemId":"item_4","startedAtMs":126,
                        "cwd":"C:\\private","permissions":{"network":{"enabled":true}}
                    }),
                },
                &owned(),
            )
            .unwrap();
        assert_eq!(approval.kind, CodexApprovalKind::Permissions);
        assert!(!approval.actionable);
        assert!(approvals
            .begin_response(
                &approval.id,
                "thr_1",
                "turn_1",
                CodexApprovalDecision::Approve
            )
            .is_err());
    }

    #[test]
    fn duplicate_server_request_id_reuses_existing_approval() {
        let mut approvals = PendingApprovals::default();
        let request = RpcServerRequest {
            id: json!(100),
            method: "item/commandExecution/requestApproval".into(),
            params: json!({
                "threadId":"thr_1","turnId":"turn_1","itemId":"item_100",
                "startedAtMs":100,"command":"cargo test"
            }),
        };

        let first = approvals.register(request.clone(), &owned()).unwrap();
        let second = approvals.register(request, &owned()).unwrap();

        assert_eq!(first, second);
        assert_eq!(approvals.for_thread("thr_1").len(), 1);
    }

    #[test]
    fn completed_turn_removes_every_pending_approval_for_that_turn() {
        let mut approvals = PendingApprovals::default();
        for (rpc_id, turn_id) in [(95, "turn_1"), (96, "turn_1"), (97, "turn_2")] {
            approvals
                .register(
                    RpcServerRequest {
                        id: json!(rpc_id),
                        method: "item/commandExecution/requestApproval".into(),
                        params: json!({
                            "threadId":"thr_1","turnId":turn_id,"itemId":format!("item_{rpc_id}"),
                            "startedAtMs":rpc_id,"command":"cargo test"
                        }),
                    },
                    &owned(),
                )
                .unwrap();
        }

        approvals.remove_for_turn("thr_1", "turn_1");

        let remaining = approvals.for_thread("thr_1");
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].turn_id, "turn_2");
    }

    #[test]
    fn approval_tokens_are_opaque_and_unique() {
        let mut approvals = PendingApprovals::default();
        let first = approvals
            .register(
                RpcServerRequest {
                    id: json!(98),
                    method: "item/commandExecution/requestApproval".into(),
                    params: json!({"threadId":"thr_1","turnId":"turn_1","itemId":"item_98","startedAtMs":98,"command":"cargo test"}),
                },
                &owned(),
            )
            .unwrap();
        let second = approvals
            .register(
                RpcServerRequest {
                    id: json!(99),
                    method: "item/commandExecution/requestApproval".into(),
                    params: json!({"threadId":"thr_1","turnId":"turn_1","itemId":"item_99","startedAtMs":99,"command":"cargo test"}),
                },
                &owned(),
            )
            .unwrap();

        assert!(first.id.starts_with("codex-approval-"));
        assert_ne!(first.id, second.id);
        assert!(!first.id.ends_with("98"));
        assert!(!second.id.ends_with("99"));
    }
}
