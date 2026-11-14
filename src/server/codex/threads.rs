use super::{
    protocol::{CodexMethod, CodexProtocol},
    rpc::RpcCallError,
};
use serde_json::{json, Value};
use std::{collections::HashSet, io::Write, time::Duration};

const THREAD_PAGE_SIZE: u32 = 100;
const MAX_THREAD_PAGES: usize = 100;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexThreadStatus {
    Resumable,
    Idle,
    Working,
    WaitingForApproval,
    WaitingForInput,
    Failed,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexThreadSummary {
    pub id: String,
    pub name: Option<String>,
    pub originator: Option<String>,
    pub updated_at: i64,
    pub status: CodexThreadStatus,
    pub(crate) workspace_path: Option<String>,
}

pub(crate) fn list_threads<W: Write>(
    protocol: &mut CodexProtocol<W>,
    timeout: Duration,
) -> Result<Vec<CodexThreadSummary>, RpcCallError> {
    let mut threads = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();

    for _ in 0..MAX_THREAD_PAGES {
        let mut params = json!({
            "limit": THREAD_PAGE_SIZE,
            "archived": false,
            "useStateDbOnly": true
        });
        if let Some(cursor) = cursor.as_deref() {
            params["cursor"] = Value::String(cursor.to_owned());
        }

        let page = protocol.request(CodexMethod::ThreadList, params, timeout)?;
        let data = page
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| RpcCallError::Protocol("thread/list response is missing data".into()))?;

        for thread in data {
            if is_internal_thread(thread) {
                continue;
            }
            threads.push(parse_thread(thread)?);
        }

        cursor = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let Some(next_cursor) = cursor.as_ref() else {
            return Ok(threads);
        };
        if !seen_cursors.insert(next_cursor.clone()) {
            return Err(RpcCallError::Protocol(
                "thread/list returned a repeated pagination cursor".into(),
            ));
        }
    }

    Err(RpcCallError::Protocol(format!(
        "thread/list exceeded {MAX_THREAD_PAGES} pages"
    )))
}

fn parse_thread(value: &Value) -> Result<CodexThreadSummary, RpcCallError> {
    Ok(CodexThreadSummary {
        id: required_string(value, "id")?,
        name: optional_string(value, "name"),
        originator: optional_string(value, "originator"),
        updated_at: value
            .get("updatedAt")
            .and_then(Value::as_i64)
            .ok_or_else(|| {
                RpcCallError::Protocol("thread entry is missing integer updatedAt".into())
            })?,
        status: value
            .get("status")
            .map(parse_status)
            .unwrap_or(CodexThreadStatus::Unknown),
        workspace_path: optional_string(value, "cwd"),
    })
}

fn required_string(value: &Value, field: &str) -> Result<String, RpcCallError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            RpcCallError::Protocol(format!("thread entry is missing string field '{field}'"))
        })
}

fn optional_string(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn is_internal_thread(value: &Value) -> bool {
    value
        .get("parentThreadId")
        .is_some_and(|value| !value.is_null())
        || value.get("agentRole").is_some_and(|value| !value.is_null())
        || value
            .get("source")
            .and_then(|source| source.get("subAgent"))
            .is_some()
}

pub(crate) fn parse_status(status: &Value) -> CodexThreadStatus {
    match status.get("type").and_then(Value::as_str) {
        Some("notLoaded") => CodexThreadStatus::Resumable,
        Some("idle") => CodexThreadStatus::Idle,
        Some("systemError") => CodexThreadStatus::Failed,
        Some("active") => {
            let flags = status
                .get("activeFlags")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if flags
                .iter()
                .any(|flag| flag.as_str() == Some("waitingOnApproval"))
            {
                CodexThreadStatus::WaitingForApproval
            } else if flags
                .iter()
                .any(|flag| flag.as_str() == Some("waitingOnUserInput"))
            {
                CodexThreadStatus::WaitingForInput
            } else {
                CodexThreadStatus::Working
            }
        }
        _ => CodexThreadStatus::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex::{
        protocol::CodexProtocol, rpc::JsonRpcClient, CodexBridge, CodexThreadStatus,
    };
    use std::{
        io::{Cursor, Write},
        sync::{Arc, Mutex},
        time::Duration,
    };

    #[derive(Clone, Default)]
    struct SharedWriter(Arc<Mutex<Vec<u8>>>);

    impl Write for SharedWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .map_err(|_| std::io::ErrorKind::Other)?
                .extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn paginates_filters_workers_and_maps_status() {
        let input = concat!(
            "{\"id\":1,\"result\":{\"data\":[",
            "{\"id\":\"thr_main\",\"name\":\"Main\",\"cwd\":\"C:\\\\work\",",
            "\"source\":\"vscode\",\"originator\":\"Codex Desktop\",",
            "\"parentThreadId\":null,\"agentRole\":null,\"updatedAt\":100,",
            "\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\"]}},",
            "{\"id\":\"thr_worker\",\"name\":\"Worker\",\"cwd\":\"C:\\\\work\",",
            "\"source\":\"appServer\",\"originator\":null,",
            "\"parentThreadId\":\"thr_main\",\"agentRole\":\"worker\",\"updatedAt\":101,",
            "\"status\":{\"type\":\"idle\"}}],\"nextCursor\":\"page2\"}}\n",
            "{\"id\":2,\"result\":{\"data\":[",
            "{\"id\":\"thr_idle\",\"name\":null,\"cwd\":\"D:\\\\repo\",",
            "\"source\":{\"custom\":\"desktop-plugin\"},\"originator\":\"Codex Desktop\",",
            "\"parentThreadId\":null,\"agentRole\":null,\"updatedAt\":200,",
            "\"status\":{\"type\":\"idle\"}}],\"nextCursor\":null}}\n"
        );
        let client = JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            SharedWriter::default(),
        );
        let mut protocol = CodexProtocol::new(client);

        let threads = list_threads(&mut protocol, Duration::from_secs(1))
            .expect("thread pages should decode");

        assert_eq!(threads.len(), 2);
        assert_eq!(threads[0].id, "thr_main");
        assert_eq!(threads[0].workspace_path.as_deref(), Some("C:\\work"));
        assert_eq!(threads[0].status, CodexThreadStatus::WaitingForApproval);
        assert_eq!(threads[1].id, "thr_idle");
        assert_eq!(threads[1].workspace_path.as_deref(), Some("D:\\repo"));
        assert_eq!(threads[1].status, CodexThreadStatus::Idle);
    }

    #[test]
    fn maps_runtime_status_variants() {
        assert_eq!(
            parse_status(&serde_json::json!({"type":"notLoaded"})),
            CodexThreadStatus::Resumable
        );
        assert_eq!(
            parse_status(&serde_json::json!({"type":"active","activeFlags":[]})),
            CodexThreadStatus::Working
        );
        assert_eq!(
            parse_status(&serde_json::json!({
                "type":"active",
                "activeFlags":["waitingOnUserInput"]
            })),
            CodexThreadStatus::WaitingForInput
        );
        assert_eq!(
            parse_status(&serde_json::json!({"type":"systemError"})),
            CodexThreadStatus::Failed
        );
    }

    #[test]
    fn subagent_source_is_filtered_even_without_parent_metadata() {
        let thread = serde_json::json!({
            "id":"thr_sub",
            "name":"Reviewer",
            "cwd":"C:\\work",
            "source":{"subAgent":{"type":"review"}},
            "originator":null,
            "parentThreadId":null,
            "agentRole":null,
            "updatedAt":300,
            "status":{"type":"idle"}
        });

        assert!(is_internal_thread(&thread));
    }

    #[test]
    fn public_summary_does_not_require_persisted_path_or_source_metadata() {
        let thread = serde_json::json!({
            "id":"thr_public",
            "name":"Public thread",
            "originator":"Codex Desktop",
            "parentThreadId":null,
            "agentRole":null,
            "updatedAt":400,
            "status":{"type":"idle"}
        });

        let summary = parse_thread(&thread).expect("public summary should decode");

        assert_eq!(summary.id, "thr_public");
        assert_eq!(summary.name.as_deref(), Some("Public thread"));
        assert_eq!(summary.workspace_path, None);
        assert_eq!(summary.status, CodexThreadStatus::Idle);
    }

    #[test]
    #[ignore = "requires a local Codex installation and user session"]
    fn codex_local_thread_enumeration() {
        let installation = crate::server::codex::discover_installation()
            .expect("local Codex discovery should run")
            .expect("Codex must be installed for this ignored test");
        let mut bridge = CodexBridge::connect(&installation)
            .expect("local Codex app-server bridge should connect");

        let threads = bridge
            .list_threads()
            .expect("local Codex threads should enumerate");

        assert!(!threads.is_empty());
        println!("enumerated {} top-level Codex threads", threads.len());
    }
}
