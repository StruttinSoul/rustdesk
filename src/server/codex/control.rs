use super::{
    protocol::{CapabilityState, CodexMethod, CodexProtocol},
    rpc::RpcCallError,
    threads::{parse_status, CodexThreadStatus},
};
use serde_json::{json, Value};
use std::{io::Write, time::Duration};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct CodexControlSupport {
    pub resume_thread: bool,
    pub start_thread: bool,
    pub start_turn: bool,
    pub steer_turn: bool,
    pub interrupt_turn: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexControlOutcome {
    pub thread_id: String,
    pub turn_id: String,
    pub status: CodexThreadStatus,
}

pub(crate) fn support<W: Write>(protocol: &CodexProtocol<W>) -> CodexControlSupport {
    let available = |method| protocol.capability(method) == CapabilityState::Available;
    CodexControlSupport {
        resume_thread: available(CodexMethod::ThreadResume),
        start_thread: available(CodexMethod::ThreadStart),
        start_turn: available(CodexMethod::TurnStart),
        steer_turn: available(CodexMethod::TurnSteer),
        interrupt_turn: available(CodexMethod::TurnInterrupt),
    }
}

pub(crate) fn workspace_for_thread<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    timeout: Duration,
) -> Result<String, RpcCallError> {
    let result = protocol.request(
        CodexMethod::ThreadRead,
        json!({"threadId": thread_id, "includeTurns": false}),
        timeout,
    )?;
    let thread = required_object(&result, "thread", "thread/read response")?;
    required_string(thread, "cwd", "thread/read response thread")
}

pub(crate) fn resume_thread<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    timeout: Duration,
) -> Result<CodexControlOutcome, RpcCallError> {
    let result = protocol.request(
        CodexMethod::ThreadResume,
        json!({"threadId": thread_id}),
        timeout,
    )?;
    parse_thread_outcome(&result, "thread/resume response")
}

pub(crate) fn start_thread<W: Write>(
    protocol: &mut CodexProtocol<W>,
    cwd: Option<&str>,
    timeout: Duration,
) -> Result<CodexControlOutcome, RpcCallError> {
    let params = cwd.map_or_else(|| json!({}), |cwd| json!({"cwd": cwd}));
    let result = protocol.request(CodexMethod::ThreadStart, params, timeout)?;
    parse_thread_outcome(&result, "thread/start response")
}

pub(crate) fn start_turn<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    text: &str,
    timeout: Duration,
) -> Result<CodexControlOutcome, RpcCallError> {
    let result = protocol.request(
        CodexMethod::TurnStart,
        json!({
            "threadId": thread_id,
            "input": [{"type": "text", "text": text}]
        }),
        timeout,
    )?;
    let turn = required_object(&result, "turn", "turn/start response")?;
    Ok(CodexControlOutcome {
        thread_id: thread_id.to_owned(),
        turn_id: required_string(turn, "id", "turn/start response turn")?,
        status: CodexThreadStatus::Working,
    })
}

pub(crate) fn steer_turn<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    turn_id: &str,
    text: &str,
    timeout: Duration,
) -> Result<CodexControlOutcome, RpcCallError> {
    let result = protocol.request(
        CodexMethod::TurnSteer,
        json!({
            "threadId": thread_id,
            "expectedTurnId": turn_id,
            "input": [{"type": "text", "text": text}]
        }),
        timeout,
    )?;
    Ok(CodexControlOutcome {
        thread_id: thread_id.to_owned(),
        turn_id: required_string(&result, "turnId", "turn/steer response")?,
        status: CodexThreadStatus::Working,
    })
}

pub(crate) fn interrupt_turn<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    turn_id: &str,
    timeout: Duration,
) -> Result<(), RpcCallError> {
    protocol.request(
        CodexMethod::TurnInterrupt,
        json!({"threadId": thread_id, "turnId": turn_id}),
        timeout,
    )?;
    Ok(())
}

fn parse_thread_outcome(
    result: &Value,
    context: &str,
) -> Result<CodexControlOutcome, RpcCallError> {
    let thread = required_object(result, "thread", context)?;
    let thread_id = required_string(thread, "id", context)?;
    let status = thread
        .get("status")
        .map(parse_status)
        .unwrap_or(CodexThreadStatus::Unknown);
    let turn_id = thread
        .get("turns")
        .and_then(Value::as_array)
        .and_then(|turns| {
            turns.iter().rev().find_map(|turn| {
                (turn.get("status").and_then(Value::as_str) == Some("inProgress"))
                    .then(|| turn.get("id").and_then(Value::as_str))
                    .flatten()
            })
        })
        .unwrap_or_default()
        .to_owned();
    Ok(CodexControlOutcome {
        thread_id,
        turn_id,
        status,
    })
}

fn required_object<'a>(
    value: &'a Value,
    field: &str,
    context: &str,
) -> Result<&'a Value, RpcCallError> {
    value
        .get(field)
        .filter(|value| value.is_object())
        .ok_or_else(|| {
            RpcCallError::Protocol(format!("{context} is missing object field '{field}'"))
        })
}

fn required_string(value: &Value, field: &str, context: &str) -> Result<String, RpcCallError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            RpcCallError::Protocol(format!("{context} is missing string field '{field}'"))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex::rpc::JsonRpcClient;
    use std::{
        io::{Cursor, Write},
        sync::{Arc, Mutex},
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

    fn protocol_with_input(input: &str) -> CodexProtocol<SharedWriter> {
        CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            SharedWriter::default(),
        ))
    }

    #[test]
    fn start_and_steer_send_only_text_inputs() {
        let input = concat!(
            "{\"id\":1,\"result\":{\"turn\":{\"id\":\"turn_1\",\"items\":[],\"status\":\"inProgress\"}}}\n",
            "{\"id\":2,\"result\":{\"turnId\":\"turn_1\"}}\n"
        );
        let writer = SharedWriter::default();
        let mut protocol = CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            writer.clone(),
        ));

        start_turn(&mut protocol, "thr_1", "hello", Duration::from_secs(1)).unwrap();
        steer_turn(
            &mut protocol,
            "thr_1",
            "turn_1",
            "change direction",
            Duration::from_secs(1),
        )
        .unwrap();

        let output = String::from_utf8(writer.0.lock().unwrap().clone()).unwrap();
        assert!(output.contains("\"method\":\"turn/start\""));
        assert!(output.contains("\"method\":\"turn/steer\""));
        assert!(output.contains("\"type\":\"text\""));
        assert!(!output.contains("localImage"));
        assert!(!output.contains("localAudio"));
    }

    #[test]
    fn resume_parses_active_turn_without_exposing_thread_metadata() {
        let input = "{\"id\":1,\"result\":{\"thread\":{\"id\":\"thr_1\",\"cwd\":\"C:\\\\private\",\"status\":{\"type\":\"active\",\"activeFlags\":[]},\"turns\":[{\"id\":\"turn_1\",\"status\":\"inProgress\",\"items\":[]}]}}}\n";
        let mut protocol = protocol_with_input(input);

        let outcome = resume_thread(&mut protocol, "thr_1", Duration::from_secs(1)).unwrap();

        assert_eq!(outcome.thread_id, "thr_1");
        assert_eq!(outcome.turn_id, "turn_1");
        assert_eq!(outcome.status, CodexThreadStatus::Working);
    }

    #[test]
    fn resume_start_and_interrupt_use_typed_minimal_rpc_payloads() {
        let input = concat!(
            "{\"id\":1,\"result\":{\"thread\":{\"id\":\"thr_1\",\"status\":{\"type\":\"idle\"},\"turns\":[]}}}\n",
            "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thr_2\",\"status\":{\"type\":\"idle\"},\"turns\":[]}}}\n",
            "{\"id\":3,\"result\":{}}\n"
        );
        let writer = SharedWriter::default();
        let mut protocol = CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            writer.clone(),
        ));

        resume_thread(&mut protocol, "thr_1", Duration::from_secs(1)).unwrap();
        start_thread(
            &mut protocol,
            Some("C:\\Programming Projects\\MIRPG"),
            Duration::from_secs(1),
        )
        .unwrap();
        interrupt_turn(&mut protocol, "thr_2", "turn_2", Duration::from_secs(1)).unwrap();

        let output = String::from_utf8(writer.0.lock().unwrap().clone()).unwrap();
        assert!(output.contains("\"method\":\"thread/resume\""));
        assert!(output.contains("\"threadId\":\"thr_1\""));
        assert!(output.contains("\"method\":\"thread/start\""));
        assert!(output.contains("\"cwd\":\"C:\\\\Programming Projects\\\\MIRPG\""));
        assert!(output.contains("\"method\":\"turn/interrupt\""));
        assert!(output.contains("\"turnId\":\"turn_2\""));
        assert!(!output.contains("workspace_thread_id"));
    }
}
