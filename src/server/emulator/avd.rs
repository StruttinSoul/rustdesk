//! Google Android Emulator (AVD) instances that Aperture manages in its
//! emulator folder (`avd_files`).
//!
//! Every AVD in the folder is listed, stopped or running. Starting runs the
//! emulator in the signed-in user's session with its window hidden
//! (`avd_launch_windows`); stopping goes through ADB. AVDs outside the folder
//! are never listed, even while they run.

use super::{
    avd_files::{valid_avd_name, AvdEntry, AvdHome, CLONE_HEADROOM_BYTES},
    avd_launch_windows,
    guest_runtime::{adb_command, adb_devices},
    AdbEndpoint, EmulatorCapabilities, EmulatorProvider, EmulatorRuntimeState, EmulatorState,
    EmulatorTarget, ProviderId,
};
use hbb_common::{bail, log, ResultType};
use std::{
    collections::BTreeSet,
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
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
/// How long a stop waits for the emulator process to exit (spec: 20 s).
const STOP_WAIT: Duration = Duration::from_secs(20);
const STOP_POLL: Duration = Duration::from_millis(500);
/// How long the console `kill` gets before Android is powered off instead,
/// and only if the guest is still online in ADB: saving the boot snapshot on
/// exit can keep the process alive well after the guest has left.
const POWER_OFF_GRACE: Duration = Duration::from_secs(10);
/// How long the source of a failed copy shows why it failed.
const CLONE_FAILURE_SHOWN: Duration = Duration::from_secs(120);

/// A start that still counts against free memory: when, which AVD, its RAM.
type StartReservation = (Instant, String, u32);

/// Host-wide: starts are serialised and recent starts reserve their RAM.
static START_LOCK: Mutex<Vec<StartReservation>> = Mutex::new(Vec::new());

/// A copy this host process is making.
struct InFlightClone {
    /// Lower-cased source and destination names.
    source: String,
    to: String,
    /// Bytes still to be written, counted against the drive's free space.
    remaining: Arc<AtomicU64>,
}

/// A copy that failed, shown on its source for a while.
struct CloneFailure {
    at: Instant,
    source: String,
    message: String,
}

/// Copies in progress and recent failures. In-progress copies are only added
/// while the start lock is held to check, so a start or a management action
/// never slips in between a clone's checks and its marker file.
pub(crate) struct CloneBook {
    in_flight: Vec<InFlightClone>,
    failures: Vec<CloneFailure>,
}

impl CloneBook {
    const fn new() -> Self {
        Self {
            in_flight: Vec::new(),
            failures: Vec::new(),
        }
    }

    fn reserves(&self, name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        self.in_flight
            .iter()
            .any(|clone| clone.source == name || clone.to == name)
    }

    fn pending_bytes(&self) -> u64 {
        self.in_flight
            .iter()
            .map(|clone| clone.remaining.load(Ordering::Relaxed))
            .fold(0, u64::saturating_add)
    }
}

static CLONING: Mutex<CloneBook> = Mutex::new(CloneBook::new());

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
    /// Asks the emulator behind `serial` to quit through its console.
    fn kill(&self, serial: &str) -> ResultType<()>;
    /// Powers Android off, which ends the emulator too.
    fn power_off(&self, serial: &str) -> ResultType<()>;
    /// Reports when `name`'s emulator exits without a stop from Aperture;
    /// `launched` when Aperture has just started it.
    fn watch_exit(&self, _name: &str, _launched: bool) {}
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
        // The console may refuse this SYSTEM client (no auth token) with
        // output that cannot be told from success; `stop` checks the outcome.
        if let Err(error) = adb_command(&adb, serial, &["emu", "kill"]) {
            log::info!("Emulator console kill of {serial} failed: {error}");
        }
        Ok(())
    }

    fn power_off(&self, serial: &str) -> ResultType<()> {
        let Some(adb) = super::remote_windows::running_adb_server() else {
            bail!("ADB is not running on the PC")
        };
        adb_command(&adb, serial, &["shell", "reboot", "-p"]).map(|_| ())
    }

    fn watch_exit(&self, name: &str, launched: bool) {
        super::avd_exit_watch::watch(name, launched)
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
    cloning: &'static Mutex<CloneBook>,
    /// How long after `emu kill` a guest still online in ADB is powered off.
    kill_grace: Duration,
}

/// Holds the source and destination of a clone against start, rename, delete
/// and create, and its remaining bytes against the free space, until dropped
/// (when the copy ends, however it ends).
pub struct CloneReservation {
    book: &'static Mutex<CloneBook>,
    source: String,
    to: String,
    remaining: Arc<AtomicU64>,
}

impl CloneReservation {
    fn book(&self) -> std::sync::MutexGuard<'_, CloneBook> {
        // Plain lists: a panicking holder leaves nothing half-updated.
        self.book.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Progress of the copy: what is left no longer counts as free space.
    pub fn progress(&self, copied: u64, total: u64) {
        self.remaining
            .store(total.saturating_sub(copied), Ordering::Relaxed);
    }

    /// Records why the copy failed; its source shows it for a while.
    pub fn fail(&self, error: &str) {
        let message = format!("Copy to {} failed: {error}", self.to);
        let mut book = self.book();
        book.failures.retain(|failure| failure.source != self.source);
        book.failures.push(CloneFailure {
            at: Instant::now(),
            source: self.source.clone(),
            message,
        });
    }
}

impl Drop for CloneReservation {
    fn drop(&mut self) {
        let remaining = self.remaining.clone();
        self.book()
            .in_flight
            .retain(|clone| !Arc::ptr_eq(&clone.remaining, &remaining));
    }
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
            cloning: &CLONING,
            kill_grace: POWER_OFF_GRACE,
        }))
    }

    /// The provider for management (create, clone, rename, delete) even when
    /// the folder does not exist yet; creating the first emulator makes it.
    pub fn for_management() -> Self {
        Self {
            home: AvdHome::new(AvdHome::default_root()),
            system: Arc::new(HostSystem),
            starts: &START_LOCK,
            cloning: &CLONING,
            kill_grace: POWER_OFF_GRACE,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(home: AvdHome, system: Arc<dyn AvdSystem>) -> Self {
        Self {
            home,
            system,
            starts: Box::leak(Box::new(Mutex::new(Vec::new()))),
            cloning: Box::leak(Box::new(Mutex::new(CloneBook::new()))),
            kill_grace: Duration::from_millis(50),
        }
    }

    pub fn home(&self) -> &AvdHome {
        &self.home
    }

    fn clone_book(&self) -> std::sync::MutexGuard<'_, CloneBook> {
        // Plain lists: a panicking holder leaves nothing half-updated.
        self.cloning.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn check_not_cloning(&self, name: &str) -> ResultType<()> {
        if self.clone_book().reserves(name) {
            bail!("{name} is being copied; wait for the copy in progress to finish")
        }
        Ok(())
    }

    /// Fails unless `name` exists and nothing uses it: not running, not just
    /// started (qemu may not be listed yet), not being copied, not a clone source.
    fn check_idle(&self, starts: &[StartReservation], name: &str) -> ResultType<()> {
        let (instance, others) = self.instance(name)?;
        if instance.running {
            bail!("{name} is running; stop it first")
        }
        if starts
            .iter()
            .any(|(at, started, _)| started == name && at.elapsed() < START_RESERVATION)
        {
            bail!("{name} was just started and is running; stop it first")
        }
        if instance.entry.clone.is_some()
            || others
                .iter()
                .any(|other| other.entry.clone.as_ref().map_or(false, |c| c.source == name))
        {
            bail!("{name} is being copied; wait for the copy in progress to finish")
        }
        self.check_not_cloning(name)
    }

    /// Runs a create, rename or delete while no start can begin and nothing
    /// uses `name` (which must be idle) or `other` (not being copied).
    pub fn exclusive<T>(
        &self,
        name: Option<&str>,
        other: Option<&str>,
        action: impl FnOnce() -> ResultType<T>,
    ) -> ResultType<T> {
        let starts = self.reservations();
        if let Some(name) = name {
            self.check_idle(&starts, name)?;
        }
        if let Some(other) = other {
            self.check_not_cloning(other)?;
        }
        action()
    }

    /// Reserves `source` and `to` for a clone about to run. Refused unless
    /// `source` is idle and the drive has room for it next to the copies in
    /// progress; the reservation lasts until the result is dropped.
    pub fn begin_clone(&self, source: &str, to: &str) -> ResultType<CloneReservation> {
        let starts = self.reservations();
        self.check_idle(&starts, source)?;
        self.home.check_ini_path(source)?;
        self.check_not_cloning(to)?;
        if self.home.list()?.iter().any(|entry| entry.name.eq_ignore_ascii_case(to)) {
            bail!("An emulator named {to} already exists")
        }
        let required = self.home.required_free_bytes_for_clone(source)?;
        let free = self.free_disk_bytes()?;
        if free < required {
            bail!(
                "Not enough free space on the PC to copy {source}: {} GB needed, {} GB free",
                required.div_ceil(1 << 30),
                free >> 30
            )
        }
        let remaining = Arc::new(AtomicU64::new(
            required.saturating_sub(CLONE_HEADROOM_BYTES),
        ));
        let mut book = self.clone_book();
        book.failures.retain(|failure| failure.source != source);
        book.in_flight.push(InFlightClone {
            source: source.to_ascii_lowercase(),
            to: to.to_ascii_lowercase(),
            remaining: remaining.clone(),
        });
        Ok(CloneReservation {
            book: self.cloning,
            source: source.to_owned(),
            to: to.to_owned(),
            remaining,
        })
    }

    /// Shows or hides the window of a running emulator on the PC.
    pub fn set_window_visible(&self, name: &str, visible: bool) -> ResultType<()> {
        let (instance, _) = self.instance(name)?;
        if !instance.running {
            bail!("{name} is not running")
        }
        avd_launch_windows::set_window_visible(name, visible)
    }

    /// Free space on the emulator folder's drive, less what the copies in
    /// progress are still to write.
    pub fn free_disk_bytes(&self) -> ResultType<u64> {
        let free = self.system.free_disk_bytes(self.home.root())?;
        Ok(free.saturating_sub(self.clone_book().pending_bytes()))
    }

    /// The recent copy failure of `name`, if any.
    fn clone_failure(&self, name: &str) -> Option<String> {
        let mut book = self.clone_book();
        book.failures
            .retain(|failure| failure.at.elapsed() < CLONE_FAILURE_SHOWN);
        book.failures
            .iter()
            .find(|failure| failure.source == name)
            .map(|failure| failure.message.clone())
    }

    fn instances(&self) -> ResultType<Vec<Instance>> {
        let live: BTreeSet<String> = self
            .clone_book()
            .in_flight
            .iter()
            .map(|clone| clone.to.clone())
            .collect();
        // Clones a previous host process left unfinished are removed (and logged) here.
        self.home.cleanup_stale_clones(std::process::id(), &live)?;
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
                let is_running = guest.is_some() || running.contains(&entry.name);
                if is_running {
                    self.system.watch_exit(&entry.name, false);
                }
                Instance {
                    running: is_running,
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

    /// Whether the guest behind `serial` is still online in ADB; None when
    /// ADB cannot tell right now.
    fn guest_online(&self, name: &str, serial: &str) -> Option<bool> {
        match self.system.guests() {
            Ok(guests) => Some(
                guests
                    .iter()
                    .any(|(online, probe)| online == serial && probe.name == name),
            ),
            Err(error) => {
                log::trace!("Android Emulator guests unavailable: {error}");
                None
            }
        }
    }

    /// After `emu kill`: waits up to `STOP_WAIT` for the emulator process to
    /// exit. Android is powered off only when the guest is still online in ADB
    /// after the grace, never once it has left (the emulator is then busy
    /// saving its state and exiting).
    fn wait_after_kill(&self, name: &str, serial: &str) -> ResultType<()> {
        let started = Instant::now();
        let poll = STOP_POLL.min(self.kill_grace);
        // Decided once: powered off, or seen leaving ADB.
        let mut settled = false;
        loop {
            if !running_avd_names(&self.system.processes()).contains(name) {
                return Ok(());
            }
            let elapsed = started.elapsed();
            if elapsed >= STOP_WAIT {
                bail!("{name} did not stop within 20 seconds")
            }
            if !settled && elapsed >= self.kill_grace {
                match self.guest_online(name, serial) {
                    Some(true) => {
                        // The console kill did nothing (typically refused for
                        // lack of the user's console token).
                        log::info!(
                            "Android Emulator {name} ignored the console kill; powering it off"
                        );
                        self.system.power_off(serial)?;
                        settled = true;
                    }
                    Some(false) => settled = true,
                    None => {}
                }
            }
            thread::sleep(poll);
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
        let mut targets: Vec<EmulatorTarget> = self.instances()?.iter().map(to_target).collect();
        for target in &mut targets {
            if target.progress_percent.is_none() {
                if let Some(message) = self.clone_failure(&target.provider_instance_id) {
                    target.last_error = Some(message);
                }
            }
        }
        Ok(targets)
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
        self.check_not_cloning(name)?;
        self.home.check_ini_path(name)?;
        starts.retain(|(at, _, _)| at.elapsed() < START_RESERVATION);
        let reserved = starts.iter().map(|(_, _, mb)| u64::from(*mb)).sum();
        let ram_mb = match instance.entry.ram_mb {
            0 => DEFAULT_RAM_MB,
            ram_mb => ram_mb,
        };
        if !memory_allows(self.system.available_memory_mb(), ram_mb, reserved) {
            bail!("Not enough free memory on atlas to start {name}")
        }
        if let Some(old) = self.home.ensure_managed_screen(name)? {
            let (width, height) = super::avd_files::MANAGED_SCREEN;
            log::info!("Changed the screen of {name} from {old} to {width}x{height}");
        }
        self.system.launch(name)?;
        self.system.watch_exit(name, true);
        starts.push((Instant::now(), name.to_owned(), ram_mb));
        log::info!("Started Android Emulator {name} ({ram_mb} MB)");
        Ok(())
    }

    fn stop(&self, target: &EmulatorTarget) -> ResultType<()> {
        let name = target.provider_instance_id.as_str();
        let serial = self.serial(target)?;
        super::avd_exit_watch::expect_stop(name);
        self.system.kill(&serial)?;
        self.wait_after_kill(name, &serial)?;
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
pub(crate) mod tests {
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

    pub(crate) struct FakeSystem {
        processes: Mutex<Vec<(String, Vec<String>)>>,
        guests: Mutex<Vec<(String, Probe)>>,
        memory_mb: u64,
        launched: Mutex<Vec<String>>,
        killed: Mutex<Vec<String>>,
        powered_off: Mutex<Vec<String>>,
        /// `emu kill` reports success but the emulator keeps running.
        kill_ignored: bool,
        /// `emu kill` works: the guest leaves ADB at once, the process this much later.
        kill_linger: Option<Duration>,
        /// Emulators that left ADB and whose process ends at the given time.
        exits: Mutex<Vec<(String, Instant)>>,
        free_bytes: Mutex<u64>,
    }

    impl FakeSystem {
        pub(crate) fn new(memory_mb: u64) -> Arc<Self> {
            Arc::new(Self {
                processes: Mutex::new(Vec::new()),
                guests: Mutex::new(Vec::new()),
                memory_mb,
                launched: Mutex::new(Vec::new()),
                killed: Mutex::new(Vec::new()),
                powered_off: Mutex::new(Vec::new()),
                kill_ignored: false,
                kill_linger: None,
                exits: Mutex::new(Vec::new()),
                free_bytes: Mutex::new(u64::MAX),
            })
        }

        fn lingering_after_kill(memory_mb: u64, linger: Duration) -> Arc<Self> {
            let mut system = Arc::try_unwrap(Self::new(memory_mb)).ok().unwrap();
            system.kill_linger = Some(linger);
            Arc::new(system)
        }

        fn ignoring_kill(memory_mb: u64) -> Arc<Self> {
            let mut system = Arc::try_unwrap(Self::new(memory_mb)).ok().unwrap();
            system.kill_ignored = true;
            Arc::new(system)
        }

        pub(crate) fn set_free_bytes(&self, bytes: u64) {
            *self.free_bytes.lock().unwrap() = bytes;
        }

        fn end(&self, serial: &str) {
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
        }

        pub(crate) fn run(&self, name: &str, serial: Option<&str>) {
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
            let due: Vec<String> = self
                .exits
                .lock()
                .unwrap()
                .iter()
                .filter(|(_, at)| Instant::now() >= *at)
                .map(|(name, _)| name.clone())
                .collect();
            let mut processes = self.processes.lock().unwrap();
            processes.retain(|(_, cmd)| !due.iter().any(|name| cmd.contains(name)));
            processes.clone()
        }
        fn guests(&self) -> ResultType<Vec<(String, Probe)>> {
            Ok(self.guests.lock().unwrap().clone())
        }
        fn available_memory_mb(&self) -> u64 {
            self.memory_mb
        }
        fn free_disk_bytes(&self, _path: &Path) -> ResultType<u64> {
            Ok(*self.free_bytes.lock().unwrap())
        }
        fn launch(&self, name: &str) -> ResultType<()> {
            self.launched.lock().unwrap().push(name.to_owned());
            Ok(())
        }
        fn kill(&self, serial: &str) -> ResultType<()> {
            self.killed.lock().unwrap().push(serial.to_owned());
            if let Some(linger) = self.kill_linger {
                let mut guests = self.guests.lock().unwrap();
                let at = Instant::now() + linger;
                for (_, probe) in guests.iter().filter(|(s, _)| s == serial) {
                    self.exits.lock().unwrap().push((probe.name.clone(), at));
                }
                guests.retain(|(s, _)| s != serial);
            } else if !self.kill_ignored {
                self.end(serial);
            }
            Ok(())
        }
        fn power_off(&self, serial: &str) -> ResultType<()> {
            self.powered_off.lock().unwrap().push(serial.to_owned());
            self.end(serial);
            Ok(())
        }
    }

    pub(crate) struct TempRoot(pub(crate) PathBuf);

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    pub(crate) fn temp_root(suffix: &str) -> TempRoot {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("aperture-avd2-{suffix}-{nonce}"));
        std::fs::create_dir_all(&root).unwrap();
        TempRoot(root)
    }

    fn provider(root: &TempRoot, system: &Arc<FakeSystem>) -> AvdProvider {
        AvdProvider::for_test(AvdHome::new(root.0.clone()), system.clone())
    }

    pub(crate) fn create(root: &TempRoot, name: &str) {
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
    fn start_gives_an_old_avd_the_managed_screen() {
        let root = temp_root("screen");
        create(&root, "Maple_1");
        let config = root.0.join("Maple_1.avd").join("config.ini");
        let old = std::fs::read_to_string(&config)
            .unwrap()
            .replace("hw.lcd.height=2208", "hw.lcd.height=2400");
        std::fs::write(&config, &old).unwrap();
        let system = FakeSystem::new(64_000);
        let provider = provider(&root, &system);
        provider.start(&target("Maple_1")).unwrap();
        let new = std::fs::read_to_string(&config).unwrap();
        assert!(new.lines().any(|l| l == "hw.lcd.height=2208"), "{new}");
        assert!(new.lines().any(|l| l == "hw.lcd.width=1080"), "{new}");
        assert_eq!(*system.launched.lock().unwrap(), vec!["Maple_1"]);
    }

    #[test]
    fn a_running_avd_keeps_its_config() {
        let root = temp_root("screen-running");
        create(&root, "Maple_1");
        let config = root.0.join("Maple_1.avd").join("config.ini");
        let old = std::fs::read_to_string(&config)
            .unwrap()
            .replace("hw.lcd.height=2208", "hw.lcd.height=2400");
        std::fs::write(&config, &old).unwrap();
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5556"));
        assert!(provider(&root, &system).start(&target("Maple_1")).is_err());
        assert_eq!(std::fs::read_to_string(&config).unwrap(), old);
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
    fn stop_powers_off_when_the_console_kill_leaves_the_emulator_running() {
        let root = temp_root("fallback");
        create(&root, "Maple_1");
        let system = FakeSystem::ignoring_kill(64_000);
        system.run("Maple_1", Some("emulator-5554"));
        let provider = provider(&root, &system);
        provider.stop(&target("Maple_1")).unwrap();
        assert_eq!(*system.killed.lock().unwrap(), vec!["emulator-5554"]);
        assert_eq!(*system.powered_off.lock().unwrap(), vec!["emulator-5554"]);
    }

    #[test]
    fn stop_does_not_power_off_when_the_console_kill_worked() {
        let root = temp_root("nofallback");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        system.run("Maple_1", Some("emulator-5554"));
        provider(&root, &system).stop(&target("Maple_1")).unwrap();
        assert!(system.powered_off.lock().unwrap().is_empty());
    }

    #[test]
    fn stop_waits_for_a_guest_that_left_adb_without_powering_it_off() {
        let root = temp_root("linger");
        create(&root, "Maple_1");
        // Saving state on exit: the guest leaves ADB, qemu ends 400 ms later.
        let system = FakeSystem::lingering_after_kill(64_000, Duration::from_millis(400));
        system.run("Maple_1", Some("emulator-5554"));
        provider(&root, &system).stop(&target("Maple_1")).unwrap();
        assert_eq!(*system.killed.lock().unwrap(), vec!["emulator-5554"]);
        assert!(system.powered_off.lock().unwrap().is_empty());
        assert!(system.processes().is_empty());
    }

    #[test]
    fn an_unreadable_marker_of_a_live_clone_is_kept() {
        let root = temp_root("livemarker");
        create(&root, "Maple_1");
        let system = FakeSystem::new(64_000);
        let provider = provider(&root, &system);
        let _guard = provider.begin_clone("Maple_1", "Maple_2").unwrap();
        let dir = root.0.join("Maple_2.avd");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(root.0.join("Maple_2.ini"), "path=x\n").unwrap();
        // Caught mid-replace or unreadable for a moment: still this process's copy.
        std::fs::write(dir.join("aperture-clone.json"), "{\"source\":").unwrap();
        provider.discover().unwrap();
        assert!(dir.join("aperture-clone.json").is_file());
        assert!(root.0.join("Maple_2.ini").is_file());
    }

    fn ini_pointing_at(root: &TempRoot, name: &str, avd_dir: &Path) -> String {
        let text = format!(
            "avd.ini.encoding=UTF-8\npath={}\npath.rel=avd\\{name}.avd\ntarget=android-35\n",
            avd_dir.display()
        );
        std::fs::write(root.0.join(format!("{name}.ini")), &text).unwrap();
        text
    }

    #[test]
    fn an_ini_pointing_outside_the_folder_is_refused() {
        let root = temp_root("inipath");
        create(&root, "Maple_1");
        // Copied in with Explorer, still pointing at a development AVD.
        let elsewhere = temp_root("inipath-dev");
        std::fs::create_dir_all(elsewhere.0.join("Maple_1.avd")).unwrap();
        let text = ini_pointing_at(&root, "Maple_1", &elsewhere.0.join("Maple_1.avd"));
        let ini = root.0.join("Maple_1.ini");
        let system = FakeSystem::new(64_000);
        let provider = provider(&root, &system);
        let error = provider.start(&target("Maple_1")).unwrap_err().to_string();
        assert!(error.contains("Maple_1 points outside the Aperture emulator folder"), "{error}");
        assert!(system.launched.lock().unwrap().is_empty());
        let error = provider.begin_clone("Maple_1", "Maple_2").err().unwrap().to_string();
        assert!(error.contains("points outside"), "{error}");
        assert!(provider.home().clone_avd("Maple_1", "Maple_2", 1, |_, _| {}).is_err());
        assert!(!root.0.join("Maple_2.avd").exists() && !root.0.join("Maple_2.ini").exists());
        assert!(provider.home().rename("Maple_1", "Maple_3").is_err());
        assert!(root.0.join("Maple_1.avd").is_dir() && !root.0.join("Maple_3.avd").exists());
        assert_eq!(std::fs::read_to_string(&ini).unwrap(), text, "the user's file is untouched");
        // No path= at all: the emulator would fall back to path.rel under .android.
        std::fs::write(&ini, "path.rel=avd\\Maple_1.avd\ntarget=android-35\n").unwrap();
        assert!(provider.start(&target("Maple_1")).is_err());
        assert!(system.launched.lock().unwrap().is_empty());
        // Delete removes only the folder's own files.
        provider.home().delete("Maple_1").unwrap();
        assert!(elsewhere.0.join("Maple_1.avd").is_dir());
    }

    #[test]
    fn created_cloned_and_renamed_emulators_point_into_the_folder() {
        let root = temp_root("inipath-ok");
        create(&root, "Maple_1");
        // As Android Studio writes it: path.rel resolves under the user's .android.
        ini_pointing_at(&root, "Maple_1", &root.0.join("Maple_1.avd"));
        let system = FakeSystem::new(64_000);
        let provider = provider(&root, &system);
        provider.home().clone_avd("Maple_1", "Maple_2", 1, |_, _| {}).unwrap();
        provider.home().rename("Maple_1", "Maple_3").unwrap();
        for name in ["Maple_2", "Maple_3"] {
            provider.start(&target(name)).unwrap();
            let ini = std::fs::read_to_string(root.0.join(format!("{name}.ini"))).unwrap();
            assert!(!ini.contains("path.rel"), "{name}: {ini}");
        }
        assert_eq!(*system.launched.lock().unwrap(), vec!["Maple_2", "Maple_3"]);
    }

    #[test]
    fn managed_emulators_can_be_started_stopped_and_restarted() {
        let root = temp_root("caps");
        let system = FakeSystem::new(64_000);
        let capabilities = provider(&root, &system).capabilities(&target("x"));
        assert!(capabilities.adb && capabilities.start && capabilities.stop && capabilities.restart);
    }
}
