use super::rpc::{JsonRpcClient, RpcCallError};
use serde_json::{json, Value};
use std::{collections::HashMap, io::Write, path::PathBuf, time::Duration};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CodexMethod {
    ThreadList,
    ThreadLoadedList,
    ThreadRead,
    ThreadResume,
    ThreadStart,
    ThreadTurnsList,
    ThreadItemsList,
    TurnStart,
    TurnSteer,
    TurnInterrupt,
}

impl CodexMethod {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::ThreadList => "thread/list",
            Self::ThreadLoadedList => "thread/loaded/list",
            Self::ThreadRead => "thread/read",
            Self::ThreadResume => "thread/resume",
            Self::ThreadStart => "thread/start",
            Self::ThreadTurnsList => "thread/turns/list",
            Self::ThreadItemsList => "thread/items/list",
            Self::TurnStart => "turn/start",
            Self::TurnSteer => "turn/steer",
            Self::TurnInterrupt => "turn/interrupt",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CapabilityState {
    Unknown,
    Available,
    Unavailable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexServerInfo {
    pub user_agent: String,
    pub codex_home: PathBuf,
    pub platform_family: String,
    pub platform_os: String,
}

pub(crate) struct CodexProtocol<W: Write> {
    rpc: JsonRpcClient<W>,
    capabilities: HashMap<CodexMethod, CapabilityState>,
}

impl<W> CodexProtocol<W>
where
    W: Write,
{
    pub(crate) fn new(rpc: JsonRpcClient<W>) -> Self {
        Self {
            rpc,
            capabilities: HashMap::new(),
        }
    }

    pub(crate) fn initialize(
        &mut self,
        timeout: Duration,
    ) -> Result<CodexServerInfo, RpcCallError> {
        let result = self.rpc.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "rustdesk-codex-bridge",
                    "title": "RustDesk Codex bridge",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": false
                }
            }),
            timeout,
        )?;
        let info = CodexServerInfo {
            user_agent: required_string(&result, "userAgent")?,
            codex_home: PathBuf::from(required_string(&result, "codexHome")?),
            platform_family: required_string(&result, "platformFamily")?,
            platform_os: required_string(&result, "platformOs")?,
        };
        self.rpc.notify("initialized", None)?;
        Ok(info)
    }

    pub(crate) fn probe_core(&mut self, timeout: Duration) -> Result<(), RpcCallError> {
        self.request(
            CodexMethod::ThreadList,
            json!({"limit": 1, "useStateDbOnly": true}),
            timeout,
        )?;
        self.request(CodexMethod::ThreadLoadedList, json!({"limit": 1}), timeout)?;
        Ok(())
    }

    pub(crate) fn request(
        &mut self,
        method: CodexMethod,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, RpcCallError> {
        match self.rpc.request(method.as_str(), params, timeout) {
            Ok(result) => {
                self.capabilities.insert(method, CapabilityState::Available);
                Ok(result)
            }
            Err(error) => {
                if error.code() == Some(-32601) {
                    self.capabilities
                        .insert(method, CapabilityState::Unavailable);
                }
                Err(error)
            }
        }
    }

    pub(crate) fn capability(&self, method: CodexMethod) -> CapabilityState {
        self.capabilities
            .get(&method)
            .copied()
            .unwrap_or(CapabilityState::Unknown)
    }

    pub(crate) fn take_pending(&mut self) -> Vec<Value> {
        self.rpc.take_pending()
    }
}

fn required_string(value: &Value, field: &str) -> Result<String, RpcCallError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            RpcCallError::Protocol(format!(
                "initialize response is missing string field '{field}'"
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex::rpc::JsonRpcClient;
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

    fn protocol_with_input(input: &str) -> CodexProtocol<SharedWriter> {
        CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.as_bytes().to_vec()),
            SharedWriter::default(),
        ))
    }

    #[test]
    fn initialize_decodes_server_identity() {
        let input = concat!(
            "{\"id\":1,\"result\":{",
            "\"userAgent\":\"Codex Desktop/0.155.1\",",
            "\"codexHome\":\"C:\\\\Users\\\\gregr\\\\.codex\",",
            "\"platformFamily\":\"windows\",",
            "\"platformOs\":\"windows\"}}\n"
        );
        let mut protocol = protocol_with_input(input);

        let info = protocol
            .initialize(Duration::from_secs(1))
            .expect("initialize response should decode");

        assert_eq!(info.user_agent, "Codex Desktop/0.155.1");
        assert_eq!(info.codex_home.to_string_lossy(), r"C:\Users\gregr\.codex");
        assert_eq!(info.platform_family, "windows");
        assert_eq!(info.platform_os, "windows");
    }

    #[test]
    fn core_read_only_probes_mark_capabilities_available() {
        let input = concat!(
            "{\"id\":1,\"result\":{\"data\":[],\"nextCursor\":null}}\n",
            "{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null}}\n"
        );
        let mut protocol = protocol_with_input(input);

        protocol
            .probe_core(Duration::from_secs(1))
            .expect("read-only probes should succeed");

        assert_eq!(
            protocol.capability(CodexMethod::ThreadList),
            CapabilityState::Available
        );
        assert_eq!(
            protocol.capability(CodexMethod::ThreadLoadedList),
            CapabilityState::Available
        );
    }

    #[test]
    fn method_not_found_downgrades_only_requested_capability() {
        let input = "{\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n";
        let mut protocol = protocol_with_input(input);

        let error = protocol
            .request(
                CodexMethod::TurnSteer,
                json!({"threadId":"thr_1"}),
                Duration::from_secs(1),
            )
            .expect_err("method-not-found should be returned");

        assert_eq!(error.code(), Some(-32601));
        assert_eq!(
            protocol.capability(CodexMethod::TurnSteer),
            CapabilityState::Unavailable
        );
        assert_eq!(
            protocol.capability(CodexMethod::TurnInterrupt),
            CapabilityState::Unknown
        );
    }

    #[test]
    fn unrelated_rpc_error_does_not_disable_capability() {
        let input = "{\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid params\"}}\n";
        let mut protocol = protocol_with_input(input);

        let error = protocol
            .request(CodexMethod::TurnSteer, json!({}), Duration::from_secs(1))
            .expect_err("invalid params should be returned");

        assert_eq!(error.code(), Some(-32602));
        assert_eq!(
            protocol.capability(CodexMethod::TurnSteer),
            CapabilityState::Unknown
        );
    }
}
