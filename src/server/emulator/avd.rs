//! Google Android Emulator (AVD) instances, listed while they are running.
//!
//! Starting and stopping stay on the PC: the provider only finds emulators the
//! default ADB server already sees and hands their serial to the guest stream.

use super::{
    guest_runtime::{adb_command, adb_devices},
    AdbEndpoint, EmulatorCapabilities, EmulatorProvider, EmulatorRuntimeState, EmulatorState,
    EmulatorTarget, ProviderId,
};
use hbb_common::{bail, log, ResultType};
use std::path::PathBuf;

const PROVIDER_ID: &str = "avd";
const MAX_AVD_NAME_LEN: usize = 64;
const PC_ONLY: &str = "Start and stop the Android Emulator on the PC";

/// Online `emulator-N` serials from `adb devices` output.
fn parse_emulator_serials(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(|line| {
            let (serial, state) = line.trim().split_once(char::is_whitespace)?;
            (serial.starts_with("emulator-") && state.trim() == "device")
                .then(|| serial.to_owned())
        })
        .collect()
}

/// One getprop call: AVD name, boot completed, Android version. Read from the
/// guest rather than the emulator console, which needs the PC user's console
/// token that the SYSTEM service does not have.
const PROBE_COMMAND: &str =
    "getprop ro.boot.qemu.avd_name; getprop sys.boot_completed; getprop ro.build.version.release";

struct Probe {
    name: String,
    booted: bool,
    android_version: Option<String>,
}

/// The probe for a Google emulator; None for anything without a valid AVD
/// name (BlueStacks or LDPlayer behind an emulator-N alias).
fn parse_probe(output: &str) -> Option<Probe> {
    let mut lines = output.lines().map(str::trim);
    let name = lines.next().filter(|name| valid_avd_name(name))?;
    let booted = lines.next() == Some("1");
    let android_version = lines
        .next()
        .filter(|version| !version.is_empty())
        .map(str::to_owned);
    Some(Probe {
        name: name.to_owned(),
        booted,
        android_version,
    })
}

fn valid_avd_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_AVD_NAME_LEN
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn stable_id(name: &str) -> String {
    format!("{PROVIDER_ID}:{name}")
}

fn display_name(name: &str) -> String {
    name.replace('_', " ")
}

struct RunningAvd {
    name: String,
    serial: String,
    booted: bool,
    android_version: Option<String>,
}

pub struct AvdProvider {
    adb: PathBuf,
}

impl AvdProvider {
    /// Present only while a default ADB server is running.
    pub fn detect() -> ResultType<Option<Self>> {
        Ok(super::remote_windows::running_adb_server().map(|adb| Self { adb }))
    }

    fn running(&self) -> ResultType<Vec<RunningAvd>> {
        let mut found = Vec::new();
        for serial in parse_emulator_serials(&adb_devices(&self.adb)?) {
            let probe = match adb_command(&self.adb, &serial, &["shell", PROBE_COMMAND]) {
                Ok(output) => parse_probe(&output),
                Err(error) => {
                    log::trace!("Android Emulator probe of {serial} failed: {error}");
                    None
                }
            };
            // Skip non-AVD aliases and a second copy of the same AVD (its id
            // would collide with the first).
            let Some(probe) = probe else { continue };
            if found.iter().any(|avd: &RunningAvd| avd.name == probe.name) {
                continue;
            }
            found.push(RunningAvd {
                name: probe.name,
                serial,
                booted: probe.booted,
                android_version: probe.android_version,
            });
        }
        Ok(found)
    }

    fn find(&self, target: &EmulatorTarget) -> ResultType<RunningAvd> {
        match self
            .running()?
            .into_iter()
            .find(|avd| avd.name == target.provider_instance_id)
        {
            Some(avd) => Ok(avd),
            None => bail!("This Android Emulator is not running; start it on the PC"),
        }
    }
}

fn state(avd: &RunningAvd) -> EmulatorState {
    if avd.booted {
        EmulatorState::Ready
    } else {
        EmulatorState::Booting
    }
}

impl EmulatorProvider for AvdProvider {
    fn provider_id(&self) -> ProviderId {
        ProviderId::new(PROVIDER_ID)
    }

    fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
        Ok(self
            .running()?
            .into_iter()
            .map(|avd| {
                let mut target = EmulatorTarget::new(
                    ProviderId::new(PROVIDER_ID),
                    stable_id(&avd.name),
                    avd.name.clone(),
                    display_name(&avd.name),
                );
                target.state = state(&avd);
                target.android_version = avd.android_version.clone();
                target.adb_endpoint = Some(AdbEndpoint::new(avd.serial.clone()));
                target
            })
            .collect())
    }

    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
        let avd = self.find(target)?;
        Ok(EmulatorRuntimeState {
            state: state(&avd),
            adb_endpoint: Some(AdbEndpoint::new(avd.serial)),
            ..Default::default()
        })
    }

    fn start(&self, _target: &EmulatorTarget) -> ResultType<()> {
        bail!(PC_ONLY)
    }

    fn stop(&self, _target: &EmulatorTarget) -> ResultType<()> {
        bail!(PC_ONLY)
    }

    fn restart(&self, _target: &EmulatorTarget) -> ResultType<()> {
        bail!(PC_ONLY)
    }

    fn resolve_adb(&self, target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
        Ok(AdbEndpoint::new(self.find(target)?.serial))
    }

    fn capabilities(&self, _target: &EmulatorTarget) -> EmulatorCapabilities {
        EmulatorCapabilities {
            adb: true,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_only_online_emulator_serials() {
        let output = "List of devices attached\r\n10.0.4.114:5555\tdevice\r\n\
            127.0.0.1:5585\tdevice\r\nemulator-5554\tdevice\r\n\
            emulator-5556\toffline\r\nemulator-5558\tunauthorized\r\n\r\n";
        assert_eq!(parse_emulator_serials(output), vec!["emulator-5554"]);
        assert!(parse_emulator_serials("List of devices attached\r\n\r\n").is_empty());
    }

    #[test]
    fn reads_the_avd_name_boot_state_and_version() {
        let probe = parse_probe("Aperture_Trial_Play35\r\n1\r\n15\r\n").unwrap();
        assert_eq!(probe.name, "Aperture_Trial_Play35");
        assert!(probe.booted);
        assert_eq!(probe.android_version.as_deref(), Some("15"));
        let booting = parse_probe("Pixel_7\r\n\r\n\r\n").unwrap();
        assert!(!booting.booted);
        assert_eq!(booting.android_version, None);
    }

    #[test]
    fn skips_devices_that_are_not_valid_avds() {
        // BlueStacks/LDPlayer aliases have no AVD name property.
        assert!(parse_probe("\r\n1\r\n13\r\n").is_none());
        assert!(parse_probe("").is_none());
        assert!(parse_probe("../evil\r\n1\r\n15\r\n").is_none());
        assert!(parse_probe("has:colon\r\n1\r\n15\r\n").is_none());
    }

    #[test]
    fn accepts_only_plain_avd_names() {
        assert!(valid_avd_name("Pixel_7_API-35.1"));
        assert!(!valid_avd_name(""));
        assert!(!valid_avd_name("a b"));
        assert!(!valid_avd_name("a/b"));
        assert!(!valid_avd_name(&"a".repeat(MAX_AVD_NAME_LEN + 1)));
    }

    #[test]
    fn names_targets_by_avd() {
        assert_eq!(stable_id("Aperture_Trial_Play35"), "avd:Aperture_Trial_Play35");
        assert_eq!(display_name("Aperture_Trial_Play35"), "Aperture Trial Play35");
    }

    #[test]
    fn start_and_stop_point_to_the_pc() {
        let provider = AvdProvider {
            adb: PathBuf::from("adb.exe"),
        };
        let target = EmulatorTarget::new(ProviderId::new(PROVIDER_ID), "avd:x", "x", "x");
        for result in [
            provider.start(&target),
            provider.stop(&target),
            provider.restart(&target),
        ] {
            assert!(result.unwrap_err().to_string().contains("on the PC"));
        }
        assert!(provider.capabilities(&target).adb);
        assert!(!provider.capabilities(&target).start);
    }
}
