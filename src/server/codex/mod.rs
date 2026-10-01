mod discovery;
mod process;
mod protocol;
mod rpc;

pub use discovery::{discover_installation, CodexInstallation};
pub use process::CodexConnectionMode;
pub use protocol::CodexServerInfo;

use hbb_common::{bail, ResultType};
use process::{connection_mode_order, managed_daemon_healthy, CodexProcess};
use protocol::CodexProtocol;
use rpc::JsonRpcClient;
use std::{process::ChildStdin, time::Duration};

const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(5);
const CORE_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

pub struct CodexBridge {
    protocol: CodexProtocol<ChildStdin>,
    _process: CodexProcess,
    server_info: CodexServerInfo,
    connection_mode: CodexConnectionMode,
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

    pub(crate) fn protocol_mut(&mut self) -> &mut CodexProtocol<ChildStdin> {
        &mut self.protocol
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

        Ok(Self {
            protocol,
            _process: process,
            server_info,
            connection_mode,
        })
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
}
