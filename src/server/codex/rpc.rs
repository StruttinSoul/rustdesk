use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    fmt,
    io::{BufRead, BufReader, Write},
    sync::mpsc::{self, Receiver, RecvTimeoutError, TryRecvError},
    thread,
    time::Duration,
};

const MAX_PENDING_MESSAGES: usize = 512;

#[derive(Debug)]
pub(crate) enum RpcCallError {
    Io(String),
    Protocol(String),
    Remote {
        code: i64,
        message: String,
        data: Option<Value>,
    },
    Timeout,
    Disconnected,
}

impl RpcCallError {
    pub(crate) fn code(&self) -> Option<i64> {
        match self {
            Self::Remote { code, .. } => Some(*code),
            _ => None,
        }
    }

    pub(crate) fn should_reconnect(&self) -> bool {
        matches!(self, Self::Io(_) | Self::Timeout | Self::Disconnected)
    }
}

impl fmt::Display for RpcCallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(message) => write!(f, "Codex app-server I/O error: {message}"),
            Self::Protocol(message) => write!(f, "Codex app-server protocol error: {message}"),
            Self::Remote { code, message, .. } => {
                write!(f, "Codex app-server RPC error {code}: {message}")
            }
            Self::Timeout => write!(f, "Timed out waiting for Codex app-server response"),
            Self::Disconnected => write!(f, "Codex app-server stream disconnected"),
        }
    }
}

impl std::error::Error for RpcCallError {}

enum ReaderEvent {
    Message(Value),
    Error(String),
}

pub(crate) struct JsonRpcClient<W: Write> {
    writer: W,
    receiver: Receiver<ReaderEvent>,
    pending: VecDeque<Value>,
    next_request_id: u64,
}

impl<W> JsonRpcClient<W>
where
    W: Write,
{
    pub(crate) fn from_streams<R>(reader: R, writer: W) -> Self
    where
        R: std::io::Read + Send + 'static,
    {
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let reader = BufReader::new(reader);
            for line in reader.lines() {
                let line = match line {
                    Ok(line) => line,
                    Err(error) => {
                        let _ = sender.send(ReaderEvent::Error(error.to_string()));
                        return;
                    }
                };
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(&line) {
                    Ok(message) => {
                        if sender.send(ReaderEvent::Message(message)).is_err() {
                            return;
                        }
                    }
                    Err(error) => {
                        let _ = sender.send(ReaderEvent::Error(format!(
                            "invalid JSON from app-server: {error}"
                        )));
                        return;
                    }
                }
            }
        });

        Self {
            writer,
            receiver,
            pending: VecDeque::new(),
            next_request_id: 1,
        }
    }

    pub(crate) fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, RpcCallError> {
        let request_id = self.next_request_id;
        self.next_request_id = self.next_request_id.saturating_add(1);
        let request = json!({
            "id": request_id,
            "method": method,
            "params": params,
        });
        self.write_message(&request)?;

        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(RpcCallError::Timeout);
            }
            let event = match self.receiver.recv_timeout(remaining) {
                Ok(event) => event,
                Err(RecvTimeoutError::Timeout) => return Err(RpcCallError::Timeout),
                Err(RecvTimeoutError::Disconnected) => return Err(RpcCallError::Disconnected),
            };
            let message = match event {
                ReaderEvent::Message(message) => message,
                ReaderEvent::Error(message) => return Err(RpcCallError::Io(message)),
            };

            if response_id(&message) == Some(request_id) {
                if let Some(result) = message.get("result") {
                    return Ok(result.clone());
                }
                if let Some(error) = message.get("error") {
                    return Err(parse_remote_error(error));
                }
                return Err(RpcCallError::Protocol(format!(
                    "response {request_id} has neither result nor error"
                )));
            }

            self.push_pending(message);
        }
    }

    pub(crate) fn notify(
        &mut self,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), RpcCallError> {
        let message = match params {
            Some(params) => json!({"method": method, "params": params}),
            None => json!({"method": method}),
        };
        self.write_message(&message)
    }

    pub(crate) fn take_pending(&mut self) -> Vec<Value> {
        self.pending.drain(..).collect()
    }

    pub(crate) fn drain_available(&mut self) -> Result<Vec<Value>, RpcCallError> {
        let mut messages: Vec<Value> = self.pending.drain(..).collect();
        loop {
            match self.receiver.try_recv() {
                Ok(ReaderEvent::Message(message)) => messages.push(message),
                Ok(ReaderEvent::Error(message)) => return Err(RpcCallError::Io(message)),
                Err(TryRecvError::Empty) => return Ok(messages),
                Err(TryRecvError::Disconnected) if !messages.is_empty() => return Ok(messages),
                Err(TryRecvError::Disconnected) => return Err(RpcCallError::Disconnected),
            }
        }
    }

    fn write_message(&mut self, message: &Value) -> Result<(), RpcCallError> {
        let mut encoded = serde_json::to_vec(message)
            .map_err(|error| RpcCallError::Protocol(error.to_string()))?;
        encoded.push(b'\n');
        self.writer
            .write_all(&encoded)
            .and_then(|_| self.writer.flush())
            .map_err(|error| RpcCallError::Io(error.to_string()))
    }

    fn push_pending(&mut self, message: Value) {
        if self.pending.len() >= MAX_PENDING_MESSAGES {
            self.pending.pop_front();
        }
        self.pending.push_back(message);
    }
}

fn response_id(message: &Value) -> Option<u64> {
    if message.get("method").is_some() {
        return None;
    }
    message.get("id")?.as_u64()
}

fn parse_remote_error(error: &Value) -> RpcCallError {
    let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown remote error")
        .to_owned();
    let data = error.get("data").cloned();
    RpcCallError::Remote {
        code,
        message,
        data,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
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
    fn request_preserves_interleaved_notification() {
        let input = concat!(
            "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thr_1\"}}\n",
            "{\"id\":1,\"result\":{\"ok\":true}}\n"
        );
        let output = SharedWriter::default();
        let output_copy = output.clone();
        let mut client =
            JsonRpcClient::from_streams(Cursor::new(input.as_bytes().to_vec()), output);

        let result = client
            .request("thread/list", json!({"limit": 5}), Duration::from_secs(1))
            .expect("request should receive its matching response");

        assert_eq!(result, json!({"ok": true}));
        assert_eq!(
            client.take_pending(),
            vec![json!({
                "method": "thread/status/changed",
                "params": {"threadId": "thr_1"}
            })]
        );
        let written = String::from_utf8(output_copy.0.lock().unwrap().clone()).unwrap();
        assert_eq!(
            written,
            "{\"id\":1,\"method\":\"thread/list\",\"params\":{\"limit\":5}}\n"
        );
    }

    #[test]
    fn request_returns_structured_remote_error() {
        let input = "{\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n";
        let mut client = JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            SharedWriter::default(),
        );

        let error = client
            .request("turn/steer", json!({}), Duration::from_secs(1))
            .expect_err("method-not-found must be surfaced");

        assert_eq!(error.code(), Some(-32601));
        assert!(error.to_string().contains("Method not found"));
    }

    #[test]
    fn drain_available_reads_idle_notifications_without_dummy_request() {
        let input = concat!(
            "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"thr_1\"}}\n",
            "{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"hi\"}}\n"
        );
        let mut client = JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            SharedWriter::default(),
        );

        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        let messages = loop {
            let messages = client
                .drain_available()
                .expect("idle notifications should drain");
            if messages.len() == 2 {
                break messages;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "reader thread stalled"
            );
            std::thread::yield_now();
        };

        assert_eq!(messages[0]["method"], "turn/started");
        assert_eq!(messages[1]["method"], "item/agentMessage/delta");
    }

    #[test]
    fn reconnects_only_for_transport_failures() {
        assert!(RpcCallError::Io("closed".into()).should_reconnect());
        assert!(RpcCallError::Timeout.should_reconnect());
        assert!(RpcCallError::Disconnected.should_reconnect());
        assert!(!RpcCallError::Protocol("bad response".into()).should_reconnect());
        assert!(!RpcCallError::Remote {
            code: -32602,
            message: "invalid params".into(),
            data: None,
        }
        .should_reconnect());
    }
}
