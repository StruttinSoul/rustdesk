use super::CodexInstallation;
use hbb_common::{bail, ResultType};
use std::{
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const HEALTH_TIMEOUT: Duration = Duration::from_secs(3);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(25);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexConnectionMode {
    ManagedProxy,
    DirectStdio,
}

impl CodexConnectionMode {
    fn args(self) -> &'static [&'static str] {
        match self {
            Self::ManagedProxy => &["app-server", "proxy"],
            Self::DirectStdio => &["app-server", "--listen", "stdio://"],
        }
    }
}

pub(crate) fn connection_mode_order(managed_daemon_healthy: bool) -> Vec<CodexConnectionMode> {
    if managed_daemon_healthy {
        vec![
            CodexConnectionMode::ManagedProxy,
            CodexConnectionMode::DirectStdio,
        ]
    } else {
        vec![CodexConnectionMode::DirectStdio]
    }
}

pub(crate) fn managed_daemon_healthy(installation: &CodexInstallation) -> bool {
    bounded_command_success(
        &installation.executable,
        &["app-server", "daemon", "version"],
        HEALTH_TIMEOUT,
    )
    .unwrap_or(false)
}

pub(crate) struct CodexProcess {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: Option<ChildStdout>,
    mode: CodexConnectionMode,
}

impl CodexProcess {
    pub(crate) fn start(
        installation: &CodexInstallation,
        mode: CodexConnectionMode,
    ) -> ResultType<Self> {
        let mut child = Command::new(&installation.executable)
            .args(mode.args())
            .env("CODEX_HOME", &installation.codex_home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        if stdin.is_none() || stdout.is_none() {
            terminate_child(&mut child);
            bail!("Failed to open Codex app-server stdio pipes")
        }
        Ok(Self {
            child,
            stdin,
            stdout,
            mode,
        })
    }

    pub(crate) fn mode(&self) -> CodexConnectionMode {
        self.mode
    }

    pub(crate) fn take_streams(&mut self) -> ResultType<(ChildStdout, ChildStdin)> {
        let stdout = self
            .stdout
            .take()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Codex app-server stdout already taken"))?;
        let stdin = self
            .stdin
            .take()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Codex app-server stdin already taken"))?;
        Ok((stdout, stdin))
    }
}

impl Drop for CodexProcess {
    fn drop(&mut self) {
        terminate_child(&mut self.child);
    }
}

fn bounded_command_success(
    executable: &std::path::Path,
    args: &[&str],
    timeout: Duration,
) -> ResultType<bool> {
    let mut child = Command::new(executable)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let started_at = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status.success());
        }
        if started_at.elapsed() >= timeout {
            terminate_child(&mut child);
            return Ok(false);
        }
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
}

fn terminate_child(child: &mut Child) {
    match child.try_wait() {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_proxy_precedes_direct_stdio_when_daemon_is_healthy() {
        assert_eq!(
            connection_mode_order(true),
            vec![
                CodexConnectionMode::ManagedProxy,
                CodexConnectionMode::DirectStdio,
            ]
        );
    }

    #[test]
    fn direct_stdio_is_only_mode_when_daemon_is_unavailable() {
        assert_eq!(
            connection_mode_order(false),
            vec![CodexConnectionMode::DirectStdio]
        );
    }

    #[test]
    fn connection_modes_use_supported_cli_arguments() {
        assert_eq!(
            CodexConnectionMode::ManagedProxy.args(),
            &["app-server", "proxy"]
        );
        assert_eq!(
            CodexConnectionMode::DirectStdio.args(),
            &["app-server", "--listen", "stdio://"]
        );
    }

    #[test]
    fn terminate_child_reaps_running_process() {
        let mut child = Command::new("cmd")
            .args(["/C", "ping 127.0.0.1 -n 30 >NUL"])
            .spawn()
            .expect("test process should start");

        terminate_child(&mut child);

        assert!(child
            .try_wait()
            .expect("test process status should be readable")
            .is_some());
    }
}
