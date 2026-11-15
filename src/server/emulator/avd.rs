//! Google Android Emulator (AVD) instances that Aperture manages in its
//! emulator folder (`avd_files`).
//!
//! Every AVD in the folder is listed, stopped or running. Starting runs the
//! emulator in the signed-in user's session with its window hidden
//! (`avd_launch_windows`); stopping goes through ADB. AVDs outside the folder
//! are never listed, even while they run.

use super::{
    avd_files::{valid_avd_name, AvdEntry, AvdHome},
    avd_launch_windows,
    guest_runtime::{adb_command, adb_devices},
    AdbEndpoint, EmulatorCapabilities, EmulatorProvider, EmulatorRuntimeState, EmulatorState,
    EmulatorTarget, ProviderId,
};
use hbb_common::{bail, log, ResultType};
use std::{
    collections::BTreeSet,
    path::Path,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

const PROVIDER_ID: &str = "avd";
pub(super) const QEMU_PROCESS: &str = "qemu-system-x86_64.exe";
const MEMORY_MARGIN_MB: u64 = 2048;
/// An emulator started this recently has not allocated its RAM yet.
const START_RESERVATION: Duration = Duration::from_secs(120);
/// The emulator's own default when an AVD names no `hw.ramSize`.
const DEFAULT_RAM_MB: u32 = 2048;
const STOP_WAIT: Duration = Duration::from_secs(20);
const STOP_POLL: Duration = Duration::from_millis(500);

/// A start that still counts against free memory: when, which AVD, its RAM.
type StartReservation = (Instant, String, u32);

/// Host-wide: starts are serialised and recent starts reserve their RAM.
static START_LOCK: Mutex<Vec<StartReservation>> = Mutex::new(Vec::new());

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

#[derive(Clone, Debug)]
pub(crate) struct Probe {
    pub(crate) name: String,
    pub(crate) booted: bool,
    pub(crate) android_version: Option<String>,
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

/// The AVD a process runs: `qemu-system-x86_64.exe ... -avd <name>`. The
/// `emulator.exe` launcher is not the emulator and is ignored.
pub(super) fn launched_avd(exe: &str, cmd: &[String]) -> Option<String> {
    if !exe.eq_ignore_ascii_case(QEMU_PROCESS) {
        return None;
    }
    cmd.windows(2)
        .find(|pair| pair[0] == "-avd" && valid_avd_name(&pair[1]))
        .map(|pair| pair[1].clone())
}

/// Names of the AVDs with a running emulator process.
fn running_avd_names(processes: &[(String, Vec<String>)]) -> BTreeSet<String> {
    processes
        .iter()
        .filter_map(|(exe, cmd)| launched_avd(exe, cmd))
        .collect()
}

/// Windows' available memory covers the AVD's RAM, a margin for the rest of
/// the PC, and the RAM of emulators started too recently to have taken theirs.
fn memory_allows(available_mb: u64, ram_mb: u32, recent_reserved_mb: u64) -> bool {
    available_mb
        >= u64::from(ram_mb)
            .saturating_add(MEMORY_MARGIN_MB)
            .saturating_add(recent_reserved_mb)
}

fn stable_id(name: &str) -> String {
    format!("{PROVIDER_ID}:{name}")
}

fn display_name(name: &str) -> String {
    name.replace('_', " ")
}

/// What the provider needs from the PC; faked in tests.
pub(crate) trait AvdSystem: Send + Sync {
    /// Executable name and command line of every process.
    fn processes(&self) -> Vec<(String, Vec<String>)>;
    /// Serial and probe of each online Google emulator on the default ADB server.
    fn guests(&self) -> ResultType<Vec<(String, Probe)>>;
    fn available_memory_mb(&self) -> u64;
    fn free_disk_bytes(&self, path: &Path) -> ResultType<u64>;
    /// Starts the emulator in the signed-in user's session.
    fn launch(&self, name: &str) -> ResultType<()>;
    /// Asks the emulator behind `serial` to quit.
    fn kill(&self, serial: &str) -> ResultType<()>;
}

/// The real PC: sysinfo processes, the default ADB server, Windows memory.
struct HostSystem;

impl AvdSystem for HostSystem {
    fn processes(&self) -> Vec<(String, Vec<String>)> {
        // Processes only: new_all() also queries disks, networks and components.
        let mut system = hbb_common::sysinfo::System::new();
        system.refresh_processes();
        system
            .processes()
            .values()
            .map(|process| (process.name().to_owned(), process.cmd().to_vec()))
            .collect()
    }

    fn guests(&self) -> ResultType<Vec<(String, Probe)>> {
        let Some(adb) = super::remote_windows::running_adb_server() else {
            return Ok(Vec::new());
        };
        let mut found = Vec::new();
        for serial in parse_emulator_serials(&adb_devices(&adb)?) {
            match adb_command(&adb, &serial, &["shell", PROBE_COMMAND]) {
                Ok(output) => {
                    if let Some(probe) = parse_probe(&output) {
                        found.push((serial, probe));
                    }
                }
                Err(error) => log::trace!("Android Emulator probe of {serial} failed: {error}"),
            }
        }
        Ok(found)
    }

    fn available_memory_mb(&self) -> u64 {
        avd_launch_windows::available_memory_mb()
    }

    fn free_disk_bytes(&self, path: &Path) -> ResultType<u64> {
        avd_launch_windows::free_disk_bytes(path)
    }

    fn launch(&self, name: &str) -> ResultType<()> {
        avd_launch_windows::launch_in_user_session(name)
    }

    fn kill(&self, serial: &str) -> ResultType<()> {
        let Some(adb) = super::remote_windows::running_adb_server() else {
            bail!("ADB is not running on the PC")
        };
        // `emu kill` goes through the emulator console, which can refuse an
        // unauthenticated client; then power Android off, which ends the
        // emulator too.
        let console = adb_command(&adb, serial, &["emu", "kill"]);
        match &console {
            Ok(output) if !output.trim_start().starts_with("KO") => return Ok(()),
            Ok(output) => log::info!("Emulator console refused kill for {serial}: {}", output.trim()),
            Err(error) => log::info!("Emulator console kill of {serial} failed: {error}"),
        }
        adb_command(&adb, serial, &["shell", "reboot", "-p"]).map(|_| ())
    }
}

/// One AVD in the folder with what is running of it.
struct Instance {
    entry: AvdEntry,
    running: bool,
    guest: Option<(String, Probe)>,
}

pub struct AvdProvider {
    home: AvdHome,
    system: Arc<dyn AvdSystem>,
    starts: &'static Mutex<Vec<StartReservation>>,
}

impl AvdProvider {
    /// Present whenever Aperture's emulator folder exists; running emulators
    /// also need the default ADB server for their state.
    pub fn detect() -> ResultType<Option<Self>> {
        let root = AvdHome::default_root();
        if !root.is_dir() {
            return Ok(None);
        }
        Ok(Some(Self {
            home: AvdHome::new(root),
            system: Arc::new(HostSystem),
            starts: &START_LOCK,
        }))
    }

    pub fn home(&self) -> &AvdHome {
        &self.home
    }

    pub fn free_disk_bytes(&self) -> ResultType<u64> {
        self.system.free_disk_bytes(self.home.root())
    }

    fn instances(&self) -> ResultType<Vec<Instance>> {
        // Clones a previous host process left unfinished are removed (and logged) here.
        self.home.cleanup_stale_clones(std::process::id())?;
        let entries = self.home.list()?;
        let running = running_avd_names(&self.system.processes());
        let mut guests = match self.system.guests() {
            Ok(guests) => guests,
            Err(error) => {
                log::trace!("Android Emulator guests unavailable: {error}");
                Vec::new()
            }
        };
        Ok(entries
            .into_iter()
            .map(|entry| {
                // The first guest per name wins; a second copy would share its id.
                let guest = guests
                    .iter()
                    .position(|(_, probe)| probe.name == entry.name)
                    .map(|index| guests.remove(index));
                Instance {
                    running: guest.is_some() || running.contains(&entry.name),
                    guest,
                    entry,
                }
            })
            .collect())
    }

    fn instance(&self, name: &str) -> ResultType<(Instance, Vec<Instance>)> {
        let mut all = self.instances()?;
        match all.iter().position(|instance| instance.entry.name == name) {
            Some(index) => Ok((all.remove(index), all)),
            None => bail!("{name} is not in Aperture's emulator folder"),
        }
    }

    fn serial(&self, target: &EmulatorTarget) -> ResultType<String> {
        let name = target.provider_instance_id.as_str();
        let (instance, _) = self.instance(name)?;
        if instance.entry.clone.is_some() {
            bail!("{name} is still being copied")
        }
        match instance.guest {
            Some((serial, _)) => Ok(serial),
            None if instance.running => bail!("{name} is still starting"),
            None => bail!("{name} is not running"),
        }
    }

    fn reservations(&self) -> std::sync::MutexGuard<'_, Vec<StartReservation>> {
        // The list holds no invariant a panicking holder could break.
        self.starts.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn state(instance: &Instance) -> EmulatorState {
    match &instance.guest {
        Some((_, probe)) if probe.booted => EmulatorState::Ready,
        Some(_) => EmulatorState::Booting,
        None if instance.running => EmulatorState::Starting,
        None => EmulatorState::Stopped,
    }
}

fn to_target(instance: &Instance) -> EmulatorTarget {
    let name = &instance.entry.name;
    let mut target = EmulatorTarget::new(
        ProviderId::new(PROVIDER_ID),
        stable_id(name),
        name.clone(),
        display_name(name),
    );
    if let Some(clone) = &instance.entry.clone {
        target.progress_percent = Some(clone.percent());
        return target;
    }
    target.state = state(instance);
    if let Some((serial, probe)) = &instance.guest {
        target.android_version = probe.android_version.clone();
        target.adb_endpoint = Some(AdbEndpoint::new(serial.clone()));
    }
    target
}

impl EmulatorProvider for AvdProvider {
    fn provider_id(&self) -> ProviderId {
        ProviderId::new(PROVIDER_ID)
    }

    fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
        Ok(self.instances()?.iter().map(to_target).collect())
    }

    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
        let (instance, _) = self.instance(&target.provider_instance_id)?;
        let target = to_target(&instance);
        Ok(EmulatorRuntimeState {
            state: target.state,
            adb_endpoint: target.adb_endpoint,
            ..Default::default()
        })
    }

    fn start(&self, target: &EmulatorTarget) -> ResultType<()> {
        let name = target.provider_instance_id.as_str();
        // Held through the launch so two starts never pass the checks together.
        let mut starts = self.reservations();
        let (instance, others) = self.instance(name)?;
        if instance.entry.clone.is_some() {
            bail!("{name} is still being copied; wait for the copy in progress to finish")
        }
        if others
            .iter()
            .any(|other| other.entry.clone.as_ref().map_or(false, |c| c.source == name))
        {
            bail!("{name} is being copied; wait for the copy in progress to finish")
        }
        if instance.running {
            bail!("{name} is already running")
        }
        starts.retain(|(at, _, _)| at.elapsed() < START_RESERVATION);
        let reserved = starts.iter().map(|(_, _, mb)| u64::from(*mb)).sum();
        let ram_mb = match instance.entry.ram_mb {
            0 => DEFAULT_RAM_MB,
            ram_mb => ram_mb,
        };
        if !memory_allows(self.system.available_memory_mb(), ram_mb, reserved) {
            bail!("Not enough free memory on atlas to start {name}")
        }
        self.system.launch(name)?;
        starts.push((Instant::now(), name.to_owned(), ram_mb));
        log::info!("Started Android Emulator {name} ({ram_mb} MB)");
        Ok(())
    }

    fn stop(&self, target: &EmulatorTarget) -> ResultType<()> {
        let name = target.provider_instance_id.as_str();
        let serial = self.serial(target)?;
        self.system.kill(&serial)?;
        let deadline = Instant::now() + STOP_WAIT;
        while running_avd_names(&self.system.processes()).contains(name) {
            if Instant::now() >= deadline {
                bail!("{name} did not stop within 20 seconds")
            }
            thread::sleep(STOP_POLL);
        }
        // Its RAM is free again, so a restart need not wait out the reservation.
        self.reservations().retain(|(_, started, _)| started != name);
        log::info!("Stopped Android Emulator {name}");
        Ok(())
    }

    fn restart(&self, target: &EmulatorTarget) -> ResultType<()> {
        let (instance, _) = self.instance(&target.provider_instance_id)?;
        if instance.running {
            self.stop(target)?;
        }
        self.start(target)
    }

    fn resolve_adb(&self, target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
        Ok(AdbEndpoint::new(self.serial(target)?))
    }

    fn capabilities(&self, _target: &EmulatorTarget) -> EmulatorCapabilities {
        EmulatorCapabilities {
            start: true,
            stop: true,
            restart: true,
            adb: true,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::emulator::avd_files::NEW_AVD_TEMPLATE;
    use std::path::PathBuf;

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
        assert!(!valid_avd_name(&"a".repeat(65)));
    }

    #[test]
    fn names_targets_by_avd() {
        assert_eq!(stable_id("Aperture_Trial_Play35"), "avd:Aperture_Trial_Play35");
        assert_eq!(display_name("Aperture_Trial_Play35"), "Aperture Trial Play35");
    }

    #[test]
    fn running_names_come_from_qemu_command_lines() {
        let p = vec![
            (
                "qemu-system-x86_64.exe".into(),
                vec!["x".into(), "-avd".into(), "Maple_1".into(), "-no-window".into()],
            ),
            ("emulator.exe".into(), vec!["-avd".into(), "Maple_9".into()]),
            (
                "HD-Player.exe".into(),
                vec!["--instance".into(), "Tiramisu64".into()],
            ),
        ];
        assert_eq!(running_avd_names(&p), BTreeSet::from(["Maple_1".to_owned()]));
    }

    #[test]
    fn memory_check_counts_requested_ram_and_margin() {
        assert!(memory_allows(6200, 4096, 0));
        assert!(!memory_allows(6000, 4096, 0));
    }

    #[test]
    fn recent_starts_reserve_memory() {
        assert!(!memory_allows(9000, 4096, 4096));
    }

    struct FakeSystem {
        processes: Mutex<Vec<(String, Vec<String>)>>,
        guests: Mutex<Vec<(String, Probe)>>,
        memory_mb: u64,
        launched: Mutex<Vec<String>>,
        killed: Mutex<Vec<String>>,
    }

    impl FakeSystem {
        fn new(memory_mb: u64) -> Arc<Self> {
            Arc::new(Self {
                processes: Mutex::new(Vec::new()),
                guests: Mutex::new(Vec::new()),
                memory_mb,
                launched: Mutex::new(Vec::new()),
                killed: Mutex::new(Vec::new()),
            })
        }

        fn run(&self, name: &str, serial: Option<&str>) {
            self.processes.lock().unwrap().push((
                QEMU_PROCESS.to_owned(),
                vec!["qemu".into(), "-avd".into(), name.into()],
            ));
            if let Some(serial) = serial {
                self.guests.lock().unwrap().push((
                    serial.to_owned(),
                    Probe {
                        name: name.to_owned(),
                        booted: true,
                        android_version: Some("15".to_owned()),
                    },
                ));
            }
        }
    }

    impl AvdSystem for FakeSystem {
        fn processes(&self) -> Vec<(String, Vec<String>)> {
            self.processes.lock().unwrap().clone()
        }
        fn guests(&self) -> ResultType<Vec<(String, Probe)>> {
            Ok(self.guests.lock().unwrap().clone())
        }
        fn available_memory_mb(&self) -> u64 {
            self.memory_mb
        }
        fn free_disk_bytes(&self, _path: &Path) -> ResultType<u64> {
            Ok(u64::MAX)
        }
        fn launch(&self, name: &str) -> ResultType<()> {
            self.launched.lock().unwrap().push(name.to_owned());
            Ok(())
        }
        fn kill(&self, serial: &str) -> ResultType<()> {
            self.killed.lock().unwrap().push(serial.to_owned());
            let mut guests = self.guests.lock().unwrap();
            let names: Vec<String> = guests
                .iter()
                .filter(|(s, _)| s == serial)
                .map(|(_, probe)| probe.name.clone())
                .collect();
            guests.retain(|(s, _)| s != serial);
            self.processes
                .lock()
                .unwrap()
                .retain(|(_, cmd)| !names.iter().any(|name| cmd.contains(name)));
            Ok(())
        }
    }

    struct TempRoot(PathBuf);

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn temp_root(suffix: &str) -> TempRoot {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("aperture-avd2-{suffix}-{nonce}"));
        std::fs::create_dir_all(&root).unwrap();
        TempRoot(root)
    }

    fn provider(root: &TempRoot, system: &Arc<FakeSystem>) -> AvdProvider {
        AvdProvider {
            home: AvdHome::new(root.0.clone()),
            system: system.clone(),
            starts: Box::leak(Box::new(Mutex::new(Vec::new()))),
        }
    }

    fn create(root: &TempRoot, name: &str) {
        AvdHome::new(root.0.clone())
            .create(name, NEW_AVD_TEMPLATE)
            .unwrap();
    }

    /// A clone of `source` into `name` that this host process is copying.
    fn cloning(root: &TempRoot, name: &str, source: &str) {
        let dir = root.0.join(format!("{name}.avd"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(root.0.join(format!("{name}.ini")), "path=x\n").unwrap();
        let marker = format!(
            r#"{{"source":"{source}","total_bytes":100,"copied_bytes":42,"host_pid":{},"started":0}}"#,
            std::process::id()
        );
        std::fs::write(dir.join("aperture-clone.json"), marker).unwrap();
    }

    fn target(name: &str) -> EmulatorTarget {
        EmulatorTarget::new(ProviderId::new(PROVIDER_ID), stable_id(name), name, name)
    }

    #[test]
    fn ignores_running_avds_outside_root() {
        let root = temp_root("outside");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.run("DiscreetHome_API35_Test", Some("emulator-5554"));
        let targets = provider(&root, &system).discover().unwrap();
        let ids: Vec<(String, EmulatorState)> = targets
            .iter()
            .map(|target| (target.stable_id.clone(), target.state))
            .collect();
        assert_eq!(ids, vec![("avd:Maple_1".to_owned(), EmulatorState::Stopped)]);
    }

    #[test]
    fn lists_stopped_running_starting_and_cloning_emulators() {
        let root = temp_root("list");
        for name in ["Maple_1", "Maple_3", "Maple_4"] {
            create(&root, name);
        }
        cloning(&root, "Maple_2", "Maple_3");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5556"));
        system.run("Maple_4", None);
        let targets = provider(&root, &system).discover().unwrap();
        let by_name = |name: &str| {
            targets
                .iter()
                .find(|target| target.provider_instance_id == name)
                .unwrap()
        };
        let ready = by_name("Maple_1");
        assert_eq!(ready.state, EmulatorState::Ready);
        assert_eq!(ready.display_name, "Maple 1");
        assert_eq!(ready.android_version.as_deref(), Some("15"));
        assert_eq!(ready.adb_endpoint, Some(AdbEndpoint::new("emulator-5556")));
        let copy = by_name("Maple_2");
        assert_eq!(copy.progress_percent, Some(42));
        assert_eq!(copy.last_error, None);
        assert_eq!(by_name("Maple_3").state, EmulatorState::Stopped);
        assert_eq!(by_name("Maple_4").state, EmulatorState::Starting);
        assert_eq!(by_name("Maple_4").adb_endpoint, None);
        assert_eq!(targets.len(), 4);
    }

    #[test]
    fn start_refuses_running_and_cloning() {
        let root = temp_root("refuse");
        for name in ["Maple_1", "Maple_3"] {
            create(&root, name);
        }
        cloning(&root, "Maple_2", "Maple_3");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5554"));
        let provider = provider(&root, &system);
        let error = provider.start(&target("Maple_1")).unwrap_err().to_string();
        assert!(error.contains("already running"), "{error}");
        let error = provider.start(&target("Maple_2")).unwrap_err().to_string();
        assert!(error.contains("copy in progress"), "{error}");
        let error = provider.start(&target("Maple_3")).unwrap_err().to_string();
        assert!(error.contains("copy in progress"), "{error}");
        let error = provider.start(&target("Elsewhere")).unwrap_err().to_string();
        assert!(error.contains("emulator folder"), "{error}");
        assert!(system.launched.lock().unwrap().is_empty());
    }

    #[test]
    fn second_start_without_memory_for_both_is_refused() {
        let root = temp_root("memory");
        for name in ["Maple_1", "Maple_2"] {
            create(&root, name);
        }
        let system = FakeSystem::new(7_000);
        let provider = provider(&root, &system);
        provider.start(&target("Maple_1")).unwrap();
        let error = provider.start(&target("Maple_2")).unwrap_err().to_string();
        assert_eq!(error, "Not enough free memory on atlas to start Maple_2");
        assert_eq!(*system.launched.lock().unwrap(), vec!["Maple_1"]);
    }

    #[test]
    fn stop_kills_through_adb_and_restart_starts_again() {
        let root = temp_root("stop");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5554"));
        let provider = provider(&root, &system);
        provider.stop(&target("Maple_1")).unwrap();
        assert_eq!(*system.killed.lock().unwrap(), vec!["emulator-5554"]);
        let error = provider.stop(&target("Maple_1")).unwrap_err().to_string();
        assert!(error.contains("not running"), "{error}");

        system.run("Maple_1", Some("emulator-5556"));
        provider.restart(&target("Maple_1")).unwrap();
        assert_eq!(
            *system.killed.lock().unwrap(),
            vec!["emulator-5554", "emulator-5556"]
        );
        assert_eq!(*system.launched.lock().unwrap(), vec!["Maple_1"]);
    }

    #[test]
    fn managed_emulators_can_be_started_stopped_and_restarted() {
        let root = temp_root("caps");
        let system = FakeSystem::new(64_000);
        let capabilities = provider(&root, &system).capabilities(&target("x"));
        assert!(capabilities.adb && capabilities.start && capabilities.stop && capabilities.restart);
    }
}
