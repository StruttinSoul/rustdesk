//! Keeps an authorized session alive when its connection manager (cm) process
//! goes away under it, for example a cm that was already closing when a quick
//! reconnect attached to it. Every way the PC user ends or denies a session is
//! an IPC message (`Close`, permission switches, the accept/deny answer) and is
//! handled before this; only the loss of the cm process itself reaches here.

use hbb_common::{bail, log, sleep, ResultType};
use std::time::{Duration, Instant};

/// How long a lost cm gets to come back before the session is closed.
pub(super) const RESTORE_TIMEOUT: Duration = Duration::from_secs(10);
/// A cm that keeps dying is not restored more than this often.
const RESTORE_WINDOW: Duration = Duration::from_secs(60);
const MAX_RESTORES_PER_WINDOW: usize = 3;
/// Prefix of the `CmErr` sent when a restore did not get a cm in time.
pub(super) const RESTORE_FAILED: &str = "connection manager could not be restored";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CmLoss {
    /// End the session, as before this module existed.
    Close,
    /// Start or reconnect to a cm and register the session with it again.
    Restore,
}

#[derive(Debug, Default)]
pub(super) struct CmRecovery {
    restores: Vec<Instant>,
}

impl CmRecovery {
    /// What to do about `CmErr(error)` (never "expected") on a connection.
    pub(super) fn on_cm_error(&mut self, error: &str, authorized: bool, now: Instant) -> CmLoss {
        if !authorized || error.starts_with(RESTORE_FAILED) {
            return CmLoss::Close;
        }
        self.restores
            .retain(|at| now.saturating_duration_since(*at) < RESTORE_WINDOW);
        if self.restores.len() >= MAX_RESTORES_PER_WINDOW {
            return CmLoss::Close;
        }
        self.restores.push(now);
        CmLoss::Restore
    }
}

/// Waits until a cm accepts IPC, starting one in the signed-in user's session
/// if none answers, for at most `RESTORE_TIMEOUT`.
pub(super) async fn wait_for_cm() -> ResultType<()> {
    let deadline = Instant::now() + RESTORE_TIMEOUT;
    let mut started = false;
    loop {
        // A probe without a login is ignored by the cm.
        if crate::ipc::connect(1000, "_cm").await.is_ok() {
            return Ok(());
        }
        if !started {
            start_cm()?;
            started = true;
        }
        if Instant::now() >= deadline {
            bail!(
                "{RESTORE_FAILED}: none answered within {} s",
                RESTORE_TIMEOUT.as_secs()
            )
        }
        sleep(0.3).await;
    }
}

fn start_cm() -> ResultType<()> {
    let args = vec!["--cm"];
    let child = if crate::platform::is_root() {
        match crate::platform::run_as_user(args) {
            Ok(child) => child,
            Err(error) => bail!("{RESTORE_FAILED}: {error}"),
        }
    } else {
        Some(crate::run_me(args)?)
    };
    if let Some(child) = child {
        super::CHILD_PROCESS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(child);
    }
    log::info!("Started a connection manager to restore a session");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const RESET: &str = "reset by the peer";

    #[test]
    fn unauthorized_connections_close_as_before() {
        let mut recovery = CmRecovery::default();
        assert_eq!(recovery.on_cm_error(RESET, false, Instant::now()), CmLoss::Close);
    }

    #[test]
    fn an_authorized_session_survives_a_lost_cm() {
        let mut recovery = CmRecovery::default();
        assert_eq!(recovery.on_cm_error(RESET, true, Instant::now()), CmLoss::Restore);
    }

    #[test]
    fn a_failed_restore_closes_the_session() {
        let mut recovery = CmRecovery::default();
        let now = Instant::now();
        assert_eq!(recovery.on_cm_error(RESET, true, now), CmLoss::Restore);
        let failed = format!("{RESTORE_FAILED}: none answered within 10 s");
        assert_eq!(recovery.on_cm_error(&failed, true, now), CmLoss::Close);
    }

    #[test]
    fn a_cm_that_keeps_dying_is_restored_only_a_few_times_a_minute() {
        let mut recovery = CmRecovery::default();
        let start = Instant::now();
        for i in 0..MAX_RESTORES_PER_WINDOW as u64 {
            let at = start + Duration::from_secs(i);
            assert_eq!(recovery.on_cm_error(RESET, true, at), CmLoss::Restore, "loss {i}");
        }
        let next = start + Duration::from_secs(MAX_RESTORES_PER_WINDOW as u64);
        assert_eq!(recovery.on_cm_error(RESET, true, next), CmLoss::Close);
        let later = start + RESTORE_WINDOW + Duration::from_secs(MAX_RESTORES_PER_WINDOW as u64);
        assert_eq!(recovery.on_cm_error(RESET, true, later), CmLoss::Restore);
    }
}
