//! Reboot from the phone: Android restarts inside a running emulator
//! (`adb -s <serial> reboot`) while the emulator process keeps running, so the
//! stream and previews come back through their usual reconnect paths.

use super::{EmulatorProvider, EmulatorState, EmulatorTarget};
use hbb_common::{bail, log, ResultType};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

/// Recent reboots by ADB serial, so a stream of that emulator ends at once
/// (its input helper dies with Android) even without a rotation watcher.
static REBOOTS: Mutex<Vec<(String, Instant)>> = Mutex::new(Vec::new());
const REBOOT_KEPT: Duration = Duration::from_secs(300);

fn note_reboot(serial: &str) {
    let mut reboots = REBOOTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    reboots.retain(|(noted, at)| noted != serial && at.elapsed() < REBOOT_KEPT);
    reboots.push((serial.to_owned(), Instant::now()));
}

/// Whether Aperture rebooted Android behind `serial` after `since`.
pub(super) fn rebooted_after(serial: &str, since: Instant) -> bool {
    REBOOTS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .iter()
        .any(|(noted, at)| noted == serial && *at > since)
}

/// Reboots Android in the running emulator `component` (`bluestacks:<instance>`).
pub fn reboot(component: &str) -> ResultType<String> {
    if !super::remote::valid_shutdown_target(component) {
        bail!("Invalid emulator")
    }
    let (provider, target) = super::remote_windows::find_target(component)?;
    let adb = super::remote_windows::adb_path()?;
    reboot_target(provider.as_ref(), &target, |serial, args| {
        super::guest_runtime::adb_command(&adb, serial, args)
    })
}

fn reboot_target(
    provider: &dyn EmulatorProvider,
    target: &EmulatorTarget,
    mut adb: impl FnMut(&str, &[&str]) -> ResultType<String>,
) -> ResultType<String> {
    let name = &target.display_name;
    if matches!(target.state, EmulatorState::Stopped | EmulatorState::Stopping) {
        bail!("{name} is not running")
    }
    let serial = provider.resolve_adb(target)?.serial;
    if serial.starts_with("127.0.0.1:") {
        // As a session start does: a network serial needs an ADB connection first.
        if let Err(error) = adb(&serial, &["connect", &serial]) {
            log::trace!("ADB connect to {serial} before reboot: {error}");
        }
    }
    adb(&serial, &["reboot"])?;
    note_reboot(&serial);
    log::info!("Rebooting Android in {name} ({}) on request", target.stable_id);
    Ok(format!("Restarting Android in {name}\u{2026}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::{AdbEndpoint, EmulatorCapabilities, EmulatorRuntimeState, ProviderId};

    struct OneTarget(EmulatorTarget);

    impl EmulatorProvider for OneTarget {
        fn provider_id(&self) -> ProviderId {
            self.0.provider.clone()
        }
        fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
            Ok(vec![self.0.clone()])
        }
        fn refresh(&self, _target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
            Ok(EmulatorRuntimeState::default())
        }
        fn start(&self, _target: &EmulatorTarget) -> ResultType<()> {
            bail!("a reboot never starts an emulator")
        }
        fn stop(&self, _target: &EmulatorTarget) -> ResultType<()> {
            bail!("a reboot never stops an emulator")
        }
        fn restart(&self, _target: &EmulatorTarget) -> ResultType<()> {
            bail!("a reboot never restarts the emulator process")
        }
        fn resolve_adb(&self, _target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
            Ok(AdbEndpoint::new("127.0.0.1:5555"))
        }
        fn capabilities(&self, _target: &EmulatorTarget) -> EmulatorCapabilities {
            EmulatorCapabilities::default()
        }
    }

    fn bluestacks(state: EmulatorState) -> OneTarget {
        let mut target = EmulatorTarget::new(
            ProviderId::new("bluestacks"),
            "bluestacks:Pie64",
            "Pie64",
            "Pie64",
        );
        target.state = state;
        OneTarget(target)
    }

    #[test]
    fn a_running_bluestacks_reboots_android_through_its_adb_endpoint() {
        let provider = bluestacks(EmulatorState::Ready);
        let mut calls = Vec::new();
        let message = reboot_target(&provider, &provider.0, |serial, args| {
            calls.push(format!("{serial} {}", args.join(" ")));
            Ok(String::new())
        })
        .unwrap();
        assert_eq!(calls, ["127.0.0.1:5555 connect 127.0.0.1:5555", "127.0.0.1:5555 reboot"]);
        assert!(message.contains("Pie64"), "{message}");
    }

    #[test]
    fn sessions_of_the_rebooted_serial_are_told() {
        let before = std::time::Instant::now();
        let provider = bluestacks(EmulatorState::Ready);
        reboot_target(&provider, &provider.0, |_, _| Ok(String::new())).unwrap();
        assert!(rebooted_after("127.0.0.1:5555", before));
        assert!(!rebooted_after("emulator-5554", before));
        assert!(!rebooted_after("127.0.0.1:5555", std::time::Instant::now()));
    }

    #[test]
    fn a_stopped_emulator_is_not_rebooted() {
        for state in [EmulatorState::Stopped, EmulatorState::Stopping] {
            let provider = bluestacks(state);
            let mut calls = 0;
            let error = reboot_target(&provider, &provider.0, |_, _| {
                calls += 1;
                Ok(String::new())
            })
            .unwrap_err();
            assert!(error.to_string().contains("not running"), "{error}");
            assert_eq!(calls, 0);
        }
    }
}
