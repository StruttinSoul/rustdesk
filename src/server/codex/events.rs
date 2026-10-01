use super::{
    history::{normalize_thread_item, CodexHistoryItemKind},
    threads::{parse_status, CodexThreadStatus},
};
use serde_json::Value;

const MAX_EVENT_TEXT_CHARS: usize = 16_384;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexEventKind {
    ThreadState,
    ItemStarted,
    ItemUpdated,
    ItemCompleted,
    TurnStarted,
    TurnCompleted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexEvent {
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub kind: CodexEventKind,
    pub state: Option<CodexThreadStatus>,
    pub history_kind: Option<CodexHistoryItemKind>,
    pub text: String,
    pub status: String,
}

pub(crate) fn normalize_notification(message: &Value) -> Option<CodexEvent> {
    let method = message.get("method")?.as_str()?;
    let params = message.get("params")?;
    match method {
        "thread/status/changed" => Some(CodexEvent {
            thread_id: string_field(params, "threadId"),
            turn_id: String::new(),
            item_id: String::new(),
            kind: CodexEventKind::ThreadState,
            state: params.get("status").map(parse_status),
            history_kind: None,
            text: String::new(),
            status: status_text(params.get("status")),
        }),
        "turn/started" => turn_event(params, CodexEventKind::TurnStarted, false),
        "turn/completed" => turn_event(params, CodexEventKind::TurnCompleted, true),
        "item/started" => item_event(params, CodexEventKind::ItemStarted),
        "item/completed" => item_event(params, CodexEventKind::ItemCompleted),
        "item/agentMessage/delta" => delta_event(params, CodexHistoryItemKind::AgentMessage),
        "item/commandExecution/outputDelta" => delta_event(params, CodexHistoryItemKind::Command),
        "item/fileChange/outputDelta" => Some(CodexEvent {
            thread_id: string_field(params, "threadId"),
            turn_id: string_field(params, "turnId"),
            item_id: string_field(params, "itemId"),
            kind: CodexEventKind::ItemUpdated,
            state: None,
            history_kind: Some(CodexHistoryItemKind::FileChange),
            text: String::new(),
            status: "updated".into(),
        }),
        "item/fileChange/patchUpdated" => Some(CodexEvent {
            thread_id: string_field(params, "threadId"),
            turn_id: string_field(params, "turnId"),
            item_id: string_field(params, "itemId"),
            kind: CodexEventKind::ItemUpdated,
            state: None,
            history_kind: Some(CodexHistoryItemKind::FileChange),
            text: String::new(),
            status: params
                .get("changes")
                .and_then(Value::as_array)
                .map(|changes| {
                    format!(
                        "{} change{}",
                        changes.len(),
                        if changes.len() == 1 { "" } else { "s" }
                    )
                })
                .unwrap_or_else(|| "updated".into()),
        }),
        _ => None,
    }
}

fn turn_event(params: &Value, kind: CodexEventKind, completed: bool) -> Option<CodexEvent> {
    let turn = params.get("turn")?;
    let status = string_field(turn, "status");
    let state = if completed {
        if turn.get("error").is_some_and(|error| !error.is_null())
            || matches!(status.as_str(), "failed" | "interrupted")
        {
            Some(CodexThreadStatus::Failed)
        } else {
            Some(CodexThreadStatus::Idle)
        }
    } else {
        Some(CodexThreadStatus::Working)
    };
    Some(CodexEvent {
        thread_id: string_field(params, "threadId"),
        turn_id: string_field(turn, "id"),
        item_id: String::new(),
        kind,
        state,
        history_kind: None,
        text: String::new(),
        status,
    })
}

fn item_event(params: &Value, kind: CodexEventKind) -> Option<CodexEvent> {
    let thread_id = string_field(params, "threadId");
    let turn_id = string_field(params, "turnId");
    let item = normalize_thread_item(params.get("item")?, &turn_id)?;
    Some(CodexEvent {
        thread_id,
        turn_id,
        item_id: item.id,
        kind,
        state: None,
        history_kind: Some(item.kind),
        text: item.text,
        status: item.status,
    })
}

fn delta_event(params: &Value, history_kind: CodexHistoryItemKind) -> Option<CodexEvent> {
    Some(CodexEvent {
        thread_id: string_field(params, "threadId"),
        turn_id: string_field(params, "turnId"),
        item_id: string_field(params, "itemId"),
        kind: CodexEventKind::ItemUpdated,
        state: None,
        history_kind: Some(history_kind),
        text: truncate_chars(string_field(params, "delta"), MAX_EVENT_TEXT_CHARS),
        status: String::new(),
    })
}

fn status_text(status: Option<&Value>) -> String {
    status
        .and_then(|status| status.get("type"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn string_field(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn truncate_chars(value: String, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value;
    }
    value.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalizes_status_and_agent_delta() {
        let state = normalize_notification(&json!({
            "method":"thread/status/changed",
            "params":{"threadId":"thr_1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}
        }))
        .unwrap();
        assert_eq!(state.state, Some(CodexThreadStatus::WaitingForApproval));

        let delta = normalize_notification(&json!({
            "method":"item/agentMessage/delta",
            "params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"hello"}
        }))
        .unwrap();
        assert_eq!(delta.history_kind, Some(CodexHistoryItemKind::AgentMessage));
        assert_eq!(delta.text, "hello");
    }

    #[test]
    fn file_change_events_do_not_expose_paths_or_diffs() {
        let event = normalize_notification(&json!({
            "method":"item/fileChange/patchUpdated",
            "params":{
                "threadId":"thr_1","turnId":"turn_1","itemId":"file_1",
                "changes":[{"path":"C:\\secret.txt","diff":"secret diff","kind":"update"}]
            }
        }))
        .unwrap();
        assert_eq!(event.status, "1 change");
        assert!(event.text.is_empty());
    }

    #[test]
    fn unknown_notifications_are_not_forwarded() {
        assert!(normalize_notification(&json!({
            "method":"some/future/private/event","params":{"token":"secret"}
        }))
        .is_none());
    }
}
