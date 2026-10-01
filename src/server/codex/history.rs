use super::{
    protocol::{CodexMethod, CodexProtocol},
    rpc::RpcCallError,
};
use serde_json::{json, Value};
use std::{io::Write, time::Duration};

const DEFAULT_PAGE_SIZE: u32 = 50;
const MAX_PAGE_SIZE: u32 = 100;
const MAX_TEXT_CHARS: usize = 65_536;
const MAX_DETAIL_CHARS: usize = 16_384;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexHistoryItemKind {
    Unknown,
    UserMessage,
    AgentMessage,
    Plan,
    Reasoning,
    Command,
    FileChange,
    Tool,
    WebSearch,
    Status,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexHistoryItem {
    pub id: String,
    pub turn_id: String,
    pub kind: CodexHistoryItemKind,
    pub text: String,
    pub detail: String,
    pub status: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexHistoryPage {
    pub items: Vec<CodexHistoryItem>,
    pub next_cursor: Option<String>,
}

pub(crate) fn list_history<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    cursor: Option<&str>,
    limit: u32,
    timeout: Duration,
) -> Result<CodexHistoryPage, RpcCallError> {
    if thread_id.trim().is_empty() {
        return Err(RpcCallError::Protocol("thread id must not be empty".into()));
    }

    let limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    let mut params = json!({
        "threadId": thread_id,
        "limit": limit,
        "sortDirection": "desc"
    });
    if let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) {
        params["cursor"] = Value::String(cursor.to_owned());
    }

    let page = protocol.request(CodexMethod::ThreadItemsList, params, timeout)?;
    let entries = page.get("data").and_then(Value::as_array).ok_or_else(|| {
        RpcCallError::Protocol("thread/items/list response is missing data".into())
    })?;

    let mut items = Vec::with_capacity(entries.len());
    for entry in entries.iter().rev() {
        let Some(item) = entry.get("item") else {
            continue;
        };
        let turn_id = entry
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if let Some(item) = normalize_thread_item(item, turn_id) {
            items.push(item);
        }
    }

    Ok(CodexHistoryPage {
        items,
        next_cursor: page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

pub(crate) fn normalize_thread_item(item: &Value, turn_id: &str) -> Option<CodexHistoryItem> {
    let item_type = item.get("type")?.as_str()?;
    let id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();

    let (kind, text, detail, status) = match item_type {
        "userMessage" => (
            CodexHistoryItemKind::UserMessage,
            user_message_text(item),
            String::new(),
            String::new(),
        ),
        "agentMessage" => (
            CodexHistoryItemKind::AgentMessage,
            string_field(item, "text"),
            String::new(),
            String::new(),
        ),
        "plan" => (
            CodexHistoryItemKind::Plan,
            string_field(item, "text"),
            String::new(),
            String::new(),
        ),
        "reasoning" => (
            CodexHistoryItemKind::Reasoning,
            string_array_field(item, "summary"),
            String::new(),
            String::new(),
        ),
        "commandExecution" => (
            CodexHistoryItemKind::Command,
            string_field(item, "command"),
            item.get("exitCode")
                .and_then(Value::as_i64)
                .map(|code| format!("Exit code {code}"))
                .unwrap_or_default(),
            string_field(item, "status"),
        ),
        "fileChange" => {
            let count = item
                .get("changes")
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0);
            (
                CodexHistoryItemKind::FileChange,
                format!("{count} file change{}", if count == 1 { "" } else { "s" }),
                String::new(),
                string_field(item, "status"),
            )
        }
        "mcpToolCall" => (
            CodexHistoryItemKind::Tool,
            tool_name(item),
            String::new(),
            string_field(item, "status"),
        ),
        "dynamicToolCall" => (
            CodexHistoryItemKind::Tool,
            string_field(item, "tool"),
            String::new(),
            string_field(item, "status"),
        ),
        "functionCallOutput" => (
            CodexHistoryItemKind::Tool,
            string_field(item, "name"),
            String::new(),
            "completed".into(),
        ),
        "webSearch" => (
            CodexHistoryItemKind::WebSearch,
            string_field(item, "query"),
            String::new(),
            String::new(),
        ),
        "imageGeneration" => (
            CodexHistoryItemKind::Tool,
            "Image generation".into(),
            String::new(),
            string_field(item, "status"),
        ),
        "enteredReviewMode" => (
            CodexHistoryItemKind::Status,
            "Entered review mode".into(),
            String::new(),
            String::new(),
        ),
        "exitedReviewMode" => (
            CodexHistoryItemKind::Status,
            "Exited review mode".into(),
            String::new(),
            String::new(),
        ),
        "contextCompaction" => (
            CodexHistoryItemKind::Status,
            "Conversation compacted".into(),
            String::new(),
            String::new(),
        ),
        // Internal worker activity, local media paths, hook payloads, sleeps and
        // unknown future item types are intentionally omitted from the Android
        // read surface instead of forwarding their raw payloads.
        _ => return None,
    };

    Some(CodexHistoryItem {
        id,
        turn_id: turn_id.to_owned(),
        kind,
        text: truncate_chars(text, MAX_TEXT_CHARS),
        detail: truncate_chars(detail, MAX_DETAIL_CHARS),
        status: truncate_chars(status, 256),
    })
}

fn user_message_text(item: &Value) -> String {
    let Some(content) = item.get("content").and_then(Value::as_array) else {
        return String::new();
    };
    let mut parts = Vec::new();
    for input in content {
        match input.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(text) = input.get("text").and_then(Value::as_str) {
                    parts.push(text.to_owned());
                }
            }
            Some("mention") => {
                if let Some(name) = input.get("name").and_then(Value::as_str) {
                    parts.push(format!("@{name}"));
                }
            }
            Some("skill") => {
                if let Some(name) = input.get("name").and_then(Value::as_str) {
                    parts.push(format!("Skill: {name}"));
                }
            }
            Some("image") | Some("localImage") => parts.push("[Image]".into()),
            Some("audio") | Some("localAudio") => parts.push("[Audio]".into()),
            _ => {}
        }
    }
    parts.join("\n")
}

fn tool_name(item: &Value) -> String {
    let server = item
        .get("server")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let tool = item.get("tool").and_then(Value::as_str).unwrap_or_default();
    match (server.is_empty(), tool.is_empty()) {
        (false, false) => format!("{server} / {tool}"),
        (true, false) => tool.to_owned(),
        (false, true) => server.to_owned(),
        (true, true) => "Tool".into(),
    }
}

fn string_field(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn string_array_field(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
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
    use crate::server::codex::{protocol::CodexProtocol, rpc::JsonRpcClient};
    use std::{
        io::{Cursor, Write},
        sync::{Arc, Mutex},
    };

    #[derive(Clone, Default)]
    struct SharedWriter(Arc<Mutex<Vec<u8>>>);

    impl Write for SharedWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn paginates_newest_first_api_into_chronological_display_items() {
        let input = concat!(
            "{\"id\":1,\"result\":{\"data\":[",
            "{\"turnId\":\"turn_2\",\"item\":{\"id\":\"a2\",\"type\":\"agentMessage\",\"text\":\"new\"}},",
            "{\"turnId\":\"turn_1\",\"item\":{\"id\":\"u1\",\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"old\"}]}}",
            "],\"nextCursor\":\"older\"}}\n"
        );
        let output = SharedWriter::default();
        let written = output.clone();
        let mut protocol = CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            output,
        ));

        let page = list_history(&mut protocol, "thr_1", None, 25, Duration::from_secs(1))
            .expect("history should decode");

        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].text, "old");
        assert_eq!(page.items[1].text, "new");
        assert_eq!(page.next_cursor.as_deref(), Some("older"));
        let request = String::from_utf8(written.0.lock().unwrap().clone()).unwrap();
        assert!(request.contains("\"method\":\"thread/items/list\""));
        assert!(request.contains("\"sortDirection\":\"desc\""));
        assert!(request.contains("\"limit\":25"));
    }

    #[test]
    fn normalization_omits_paths_raw_tool_arguments_and_reasoning_content() {
        let command = json!({
            "id":"cmd_1","type":"commandExecution","command":"cargo test",
            "cwd":"C:\\secret","aggregatedOutput":"sensitive output","status":"completed","exitCode":0
        });
        let normalized = normalize_thread_item(&command, "turn_1").unwrap();
        assert_eq!(normalized.text, "cargo test");
        assert_eq!(normalized.detail, "Exit code 0");
        assert!(!normalized.text.contains("secret"));
        assert!(!normalized.detail.contains("sensitive"));

        let reasoning = json!({
            "id":"r1","type":"reasoning","summary":["Checking tests"],
            "content":["private chain of thought"]
        });
        let normalized = normalize_thread_item(&reasoning, "turn_1").unwrap();
        assert_eq!(normalized.text, "Checking tests");
        assert!(!normalized.text.contains("private chain"));

        let file_change = json!({
            "id":"f1","type":"fileChange","status":"completed",
            "changes":[{"path":"C:\\secret.txt","diff":"private diff","kind":"update"}]
        });
        let normalized = normalize_thread_item(&file_change, "turn_1").unwrap();
        assert_eq!(normalized.text, "1 file change");
        assert!(!normalized.text.contains("secret"));
    }

    #[test]
    fn user_message_replaces_local_media_paths_with_labels() {
        let item = json!({
            "id":"u1","type":"userMessage","content":[
                {"type":"text","text":"look at this"},
                {"type":"localImage","path":"C:\\Users\\me\\private.png"},
                {"type":"mention","name":"README","path":"C:\\repo\\README.md"}
            ]
        });
        let normalized = normalize_thread_item(&item, "turn_1").unwrap();

        assert_eq!(normalized.text, "look at this\n[Image]\n@README");
        assert!(!normalized.text.contains("C:\\"));
    }
}
