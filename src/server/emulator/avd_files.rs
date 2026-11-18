//! File layer for the Android Emulator AVDs Aperture manages on the PC.
//!
//! Every AVD lives in one root folder (`<name>.ini` next to `<name>.avd\`).
//! This module only touches that folder: no processes, ADB or network. Callers
//! check that an emulator is not running before they clone, rename or delete.

use super::avd_settings::{self, AvdSettings};
use hbb_common::{anyhow::Context, bail, config::Config, log, ResultType};
use std::{
    collections::BTreeSet,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const OPTION_AVD_HOME: &str = "aperture-avd-home";
const DEFAULT_ROOT: &str = r"D:\Aperture\Emulators";
const CLONE_MARKER: &str = "aperture-clone.json";
pub const CLONE_HEADROOM_BYTES: u64 = 4 << 30;
const COPY_CHUNK_BYTES: usize = 8 << 20;
const MARKER_INTERVAL: Duration = Duration::from_millis(500);
/// An unreadable marker no clone of this process owns is stale only once it
/// has not changed for this long (a live writer replaces it every 500 ms).
const UNREADABLE_MARKER_AGE: Duration = Duration::from_secs(120);

/// The trial AVD's `config.ini` with the values new emulators get. `AvdId` and
/// `avd.ini.displayname` are filled from the name when the AVD is written.
pub const NEW_AVD_TEMPLATE: &str = r"abi.type=x86_64
AvdId=
avd.ini.displayname=
avd.ini.encoding=UTF-8
disk.cachePartition=yes
disk.cachePartition.size=66MB
disk.systemPartition.size=0
disk.vendorPartition.size=0
environment.height=0
environment.width=0
fastboot.forceChosenSnapshotBoot=no
fastboot.forceFastBoot=yes
firstboot.bootFromDownloadableSnapshot=yes
firstboot.bootFromLocalSnapshot=yes
firstboot.saveToLocalSnapshot=yes
hw.accelerometer=yes
hw.accelerometer_uncalibrated=yes
hw.arc=false
hw.audioInput=yes
hw.audioOutput=yes
hw.battery=yes
hw.camera.back=emulated
hw.camera.back.orientation=90
hw.camera.front=none
hw.camera.front.orientation=90
hw.cpu.arch=x86_64
hw.dPad=no
hw.device.hash2=MD5:2016577e1656e8e7c2adb0fac972beea
hw.device.manufacturer=Google
hw.device.name=pixel_7
hw.display1.density=0
hw.display1.flag=0
hw.display1.height=0
hw.display1.width=0
hw.display1.xOffset=-1
hw.display1.yOffset=-1
hw.display2.density=0
hw.display2.flag=0
hw.display2.height=0
hw.display2.width=0
hw.display2.xOffset=-1
hw.display2.yOffset=-1
hw.display3.density=0
hw.display3.flag=0
hw.display3.height=0
hw.display3.width=0
hw.display3.xOffset=-1
hw.display3.yOffset=-1
hw.displayRegion.0.1.height=0
hw.displayRegion.0.1.width=0
hw.displayRegion.0.1.xOffset=-1
hw.displayRegion.0.1.yOffset=-1
hw.displayRegion.0.2.height=0
hw.displayRegion.0.2.width=0
hw.displayRegion.0.2.xOffset=-1
hw.displayRegion.0.2.yOffset=-1
hw.displayRegion.0.3.height=0
hw.displayRegion.0.3.width=0
hw.displayRegion.0.3.xOffset=-1
hw.displayRegion.0.3.yOffset=-1
hw.gltransport=pipe
hw.gltransport.asg.dataRingSize=32768
hw.gltransport.asg.writeBufferSize=1048576
hw.gltransport.asg.writeStepSize=4096
hw.gltransport.drawFlushInterval=800
hw.gps=yes
hw.gsmModem=yes
hw.gyroscope=yes
hw.hotplug_multi_display=no
hw.initialOrientation=portrait
hw.keyboard.charmap=qwerty2
hw.keyboard.lid=yes
hw.lcd.backlight=yes
hw.lcd.circular=false
hw.lcd.density=420
hw.lcd.depth=32
hw.lcd.height=2208
hw.lcd.transparent=false
hw.lcd.vsync=60
hw.lcd.width=1080
hw.mainKeys=no
hw.multi_display_window=no
hw.rotaryInput=no
hw.screen=multi-touch
hw.sdCard=yes
hw.sensor.hinge=no
hw.sensor.hinge.count=0
hw.sensor.hinge.fold_to_displayRegion.0.1_at_posture=1
hw.sensor.hinge.resizable.config=1
hw.sensor.hinge.sub_type=0
hw.sensor.hinge.type=0
hw.sensor.roll=no
hw.sensor.roll.count=0
hw.sensor.roll.resize_to_displayRegion.0.1_at_posture=6
hw.sensor.roll.resize_to_displayRegion.0.2_at_posture=6
hw.sensor.roll.resize_to_displayRegion.0.3_at_posture=6
hw.sensors.gyroscope_uncalibrated=yes
hw.sensors.heading=no
hw.sensors.heart_rate=no
hw.sensors.humidity=yes
hw.sensors.light=yes
hw.sensors.magnetic_field=yes
hw.sensors.magnetic_field_uncalibrated=yes
hw.sensors.orientation=yes
hw.sensors.pressure=yes
hw.sensors.proximity=yes
hw.sensors.rgbclight=no
hw.sensors.temperature=yes
hw.sensors.wrist_tilt=no
hw.touchpad0=no
hw.touchpad0.height=400
hw.touchpad0.width=600
hw.trackBall=no
hw.useext4=yes
image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\
kernel.newDeviceNaming=autodetect
kernel.supportsYaffs2=autodetect
runtime.network.latency=none
runtime.network.speed=full
sdcard.size=512 MB
showDeviceFrame=yes
tag.display=Google Play
tag.displaynames=Google Play
tag.id=google_apis_playstore
tag.ids=google_apis_playstore
target=android-35
test.delayAdbTillBootComplete=0
test.monitorAdb=0
test.quitAfterBootTimeOut=-1
userdata.useQcow2=no
vm.heapSize=228M
disk.dataPartition.size=24G
fastboot.forceColdBoot=no
hw.gpu.mode=host
hw.ramSize=4096
hw.cpu.ncore=4
hw.keyboard=yes
hw.gpu.enabled=yes
PlayStore.enabled=true
";

/// Plain AVD names only: no path separators, drive colons, dots-first names or
/// Windows device names (which would address a device instead of a file).
pub fn valid_avd_name(name: &str) -> bool {
    super::remote::valid_avd_name(name)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloneProgress {
    pub source: String,
    pub total_bytes: u64,
    pub copied_bytes: u64,
    pub host_pid: u32,
}

impl CloneProgress {
    pub fn percent(&self) -> u32 {
        if self.total_bytes == 0 {
            return 0;
        }
        (u128::from(self.copied_bytes) * 100 / u128::from(self.total_bytes)).min(100) as u32
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvdEntry {
    pub name: String,
    pub ram_mb: u32,
    pub cores: u32,
    pub clone: Option<CloneProgress>,
}

#[derive(Debug, Clone)]
pub struct AvdHome {
    root: PathBuf,
    /// Stale clones that could not be removed and were already logged, so the
    /// 10 s inventory scan retries them silently. Shared by clones of this value.
    unremovable: Arc<Mutex<BTreeSet<String>>>,
    /// Entries the inventory scan skips and has already logged once.
    warned: Arc<Mutex<BTreeSet<String>>>,
}

/// The value of `key=` in an ini text, if present.
fn get_key<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        (k.trim() == key).then(|| v.trim())
    })
}

/// `text` with `key=value` replaced in place (or appended). Other lines and the
/// line ending style are kept verbatim.
fn set_key(text: &str, key: &str, value: &str) -> String {
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut replaced = false;
    let mut lines: Vec<String> = text
        .lines()
        .map(|line| match line.split_once('=') {
            Some((k, _)) if !replaced && k.trim() == key => {
                replaced = true;
                format!("{key}={value}")
            }
            _ => line.to_owned(),
        })
        .collect();
    if !replaced {
        lines.push(format!("{key}={value}"));
    }
    let mut out = lines.join(eol);
    out.push_str(eol);
    out
}

/// The screen of every Aperture-managed emulator: it fills the phone's game
/// area above the in-game bar (384x784 dp) without black bars.
pub const MANAGED_SCREEN: (u32, u32) = (1080, 2208);

/// The memory, CPU cores and screen a `config.ini` gives the emulator.
fn settings_in(config: &str) -> AvdSettings {
    let number = |key: &str| Some(leading_number(get_key(config, key))).filter(|n| *n > 0);
    AvdSettings {
        ram_mb: number("hw.ramSize"),
        cores: number("hw.cpu.ncore"),
        screen: number("hw.lcd.width").zip(number("hw.lcd.height")),
    }
}

/// `config` with `settings` written in, or None if it has them already. Other
/// lines and the line endings are kept.
fn with_settings(config: &str, settings: &AvdSettings) -> Option<String> {
    let change = settings.unapplied(&settings_in(config));
    if change.is_empty() {
        return None;
    }
    let mut config = config.to_owned();
    if let Some(ram) = change.ram_mb {
        config = set_key(&config, "hw.ramSize", &ram.to_string());
    }
    if let Some(cores) = change.cores {
        config = set_key(&config, "hw.cpu.ncore", &cores.to_string());
    }
    if let Some((width, height)) = change.screen {
        config = set_key(&config, "hw.lcd.width", &width.to_string());
        config = set_key(&config, "hw.lcd.height", &height.to_string());
    }
    Some(config)
}

/// `text` without any `key=` line; other lines and the line endings are kept.
fn remove_key(text: &str, key: &str) -> String {
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut out = String::new();
    for line in text.lines() {
        if line.split_once('=').map_or(false, |(k, _)| k.trim() == key) {
            continue;
        }
        out.push_str(line);
        out.push_str(eol);
    }
    out
}

fn display_name(name: &str) -> String {
    name.replace('_', " ")
}

fn leading_number(value: Option<&str>) -> u32 {
    let digits: String = value
        .unwrap_or_default()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().unwrap_or(0)
}

/// Runtime state the emulator rebuilds, plus Aperture's own logs and markers.
fn skip_when_cloning(relative_top: &str, is_dir: bool) -> bool {
    let name = relative_top.to_ascii_lowercase();
    if is_dir {
        return name == "snapshots";
    }
    name.ends_with(".lock")
        || name == "multiinstance.lock"
        || name == "hardware-qemu.ini"
        || name == "emu-launch-params.txt"
        || name == CLONE_MARKER
        || (name.starts_with("aperture-") && name.contains(".log"))
}

struct CopyItem {
    from: PathBuf,
    to: PathBuf,
    size: u64,
}

/// Files to copy for a clone, `config.ini` first so a listing shows the sizes
/// early, and the directories to create.
fn plan_copy(src: &Path, dst: &Path) -> ResultType<(Vec<PathBuf>, Vec<CopyItem>)> {
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    let mut pending = vec![(src.to_path_buf(), dst.to_path_buf(), true)];
    while let Some((dir, target, top)) = pending.pop() {
        for entry in fs::read_dir(&dir).with_context(|| format!("read {}", dir.display()))? {
            let entry = entry?;
            let file_name = entry.file_name();
            let kind = fs::symlink_metadata(entry.path())?;
            let Some(name) = file_name.to_str() else {
                bail!("Unsupported file name in {}", dir.display());
            };
            if kind.is_dir() {
                if top && skip_when_cloning(name, true) {
                    continue;
                }
                let sub = target.join(name);
                dirs.push(sub.clone());
                pending.push((entry.path(), sub, false));
            } else if kind.is_file() {
                if top && skip_when_cloning(name, false) {
                    continue;
                }
                files.push(CopyItem {
                    from: entry.path(),
                    to: target.join(name),
                    size: kind.len(),
                });
            }
        }
    }
    files.sort_by_key(|item| item.to.file_name().map_or(true, |n| n != "config.ini"));
    Ok((dirs, files))
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn read_marker(avd_dir: &Path) -> Option<CloneProgress> {
    let raw = fs::read_to_string(avd_dir.join(CLONE_MARKER)).ok()?;
    let json: serde_json::Value = serde_json::from_str(&raw).ok()?;
    Some(CloneProgress {
        source: json.get("source")?.as_str()?.to_owned(),
        total_bytes: json.get("total_bytes")?.as_u64()?,
        copied_bytes: json.get("copied_bytes")?.as_u64()?,
        host_pid: u32::try_from(json.get("host_pid")?.as_u64()?).ok()?,
    })
}

/// Atomic replace, so a listing never reads a half-written marker.
fn write_marker(avd_dir: &Path, progress: &CloneProgress, started: u64) -> ResultType<()> {
    let json = serde_json::json!({
        "source": progress.source,
        "total_bytes": progress.total_bytes,
        "copied_bytes": progress.copied_bytes,
        "host_pid": progress.host_pid,
        "started": started,
    });
    let tmp = avd_dir.join(format!("{CLONE_MARKER}.tmp"));
    fs::write(&tmp, json.to_string())?;
    fs::rename(&tmp, avd_dir.join(CLONE_MARKER))?;
    Ok(())
}

impl AvdHome {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            unremovable: Arc::default(),
            warned: Arc::default(),
        }
    }

    /// True the first time `key` is seen, when a skipped entry is to be logged.
    fn warn_once(&self, key: String) -> bool {
        // A plain set: a panicking holder leaves nothing half-updated.
        self.warned
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(key)
    }

    #[cfg(test)]
    fn warned_entries(&self) -> Vec<String> {
        self.warned
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter()
            .cloned()
            .collect()
    }

    fn unremovable_set(&self) -> std::sync::MutexGuard<'_, BTreeSet<String>> {
        // A plain set: a panicking holder leaves nothing half-updated.
        self.unremovable
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Records a failed stale-clone removal; true only the first time, when it
    /// is to be logged.
    fn note_cleanup_failure(&self, name: &str) -> bool {
        self.unremovable_set().insert(name.to_owned())
    }

    /// Stale clones that could not be removed (still retried every scan).
    #[cfg(test)]
    fn unremovable_clones(&self) -> Vec<String> {
        self.unremovable_set().iter().cloned().collect()
    }

    pub fn default_root() -> PathBuf {
        let configured = Config::get_option(OPTION_AVD_HOME);
        let configured = configured.trim();
        PathBuf::from(if configured.is_empty() {
            DEFAULT_ROOT
        } else {
            configured
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn avd_dir(&self, name: &str) -> PathBuf {
        self.root.join(format!("{name}.avd"))
    }

    fn ini_path(&self, name: &str) -> PathBuf {
        self.root.join(format!("{name}.ini"))
    }

    fn checked_name(name: &str) -> ResultType<&str> {
        if !valid_avd_name(name) {
            bail!("Invalid emulator name");
        }
        Ok(name)
    }

    /// Fails unless an existing `path` resolves to a place inside the root
    /// (a junction or symlink out of it does not).
    fn ensure_inside(&self, path: &Path) -> ResultType<()> {
        let root = fs::canonicalize(&self.root).context("emulator folder is not available")?;
        let resolved = fs::canonicalize(path)?;
        if resolved == root || !resolved.starts_with(&root) {
            bail!("Path is outside the emulator folder");
        }
        Ok(())
    }

    /// Fails unless `<name>.ini`'s `path=` resolves to this folder's
    /// `<name>.avd`. The emulator follows `path=` (and, when that is missing,
    /// `path.rel=` under the user's `.android`), so an AVD copied in by hand may
    /// still run a development AVD elsewhere. The file is never rewritten here.
    pub fn check_ini_path(&self, name: &str) -> ResultType<()> {
        let name = Self::checked_name(name)?;
        let dir = self.avd_dir(name);
        self.ensure_inside(&dir)?;
        let text = fs::read_to_string(self.ini_path(name))
            .with_context(|| format!("Cannot read {name}.ini"))?;
        let expected = fs::canonicalize(&dir)?;
        let points_here = get_key(&text, "path")
            .filter(|path| !path.is_empty())
            .and_then(|path| fs::canonicalize(path).ok())
            .map_or(false, |actual| actual == expected);
        if !points_here {
            bail!("{name} points outside the Aperture emulator folder");
        }
        Ok(())
    }

    /// The folder of `name` when Aperture may rewrite its configuration: inside
    /// this root, and never in a `.android` folder (Android Studio's AVDs).
    fn managed_dir(&self, name: &str) -> ResultType<PathBuf> {
        let name = Self::checked_name(name)?;
        let dir = self.avd_dir(name);
        self.ensure_inside(&dir)?;
        let resolved = fs::canonicalize(&dir)?;
        if resolved
            .components()
            .any(|part| part.as_os_str().eq_ignore_ascii_case(".android"))
        {
            bail!("{name} is an Android Studio emulator; Aperture does not change it")
        }
        Ok(dir)
    }

    /// The settings chosen for `name` on the phone; a damaged choice is
    /// logged once and left out.
    fn chosen_in(&self, dir: &Path, name: &str) -> AvdSettings {
        avd_settings::load(dir).unwrap_or_else(|error| {
            if self.warn_once(format!("settings:{name}")) {
                log::warn!("Ignoring the saved settings of {name}: {error}");
            }
            AvdSettings::default()
        })
    }

    /// The settings in `name`'s `config.ini`, and the ones chosen for it.
    pub fn settings(&self, name: &str) -> ResultType<(AvdSettings, AvdSettings)> {
        let dir = self.managed_dir(name)?;
        let config = fs::read_to_string(dir.join("config.ini"))
            .with_context(|| format!("Cannot read the configuration of {name}"))?;
        Ok((settings_in(&config), self.chosen_in(&dir, name)))
    }

    /// Adds `change` to the settings chosen for `name` and returns them all.
    /// Its `config.ini` is not touched here.
    pub fn choose_settings(&self, name: &str, change: AvdSettings) -> ResultType<AvdSettings> {
        let dir = self.managed_dir(name)?;
        let chosen = self.chosen_in(&dir, name).merged(change);
        avd_settings::store(&dir, &chosen)?;
        Ok(chosen)
    }

    /// Writes the chosen settings into a stopped emulator's `config.ini`, with
    /// the managed screen when no screen was chosen. Returns what changed.
    /// Callers check it is not running.
    pub fn apply_settings(&self, name: &str) -> ResultType<Option<String>> {
        let dir = self.managed_dir(name)?;
        let path = dir.join("config.ini");
        let text = fs::read_to_string(&path)
            .with_context(|| format!("Cannot read the configuration of {name}"))?;
        let chosen = self.chosen_in(&dir, name);
        let wanted = AvdSettings {
            screen: chosen.screen.or(Some(MANAGED_SCREEN)),
            ..chosen
        };
        let before = settings_in(&text);
        let Some(updated) = with_settings(&text, &wanted) else {
            return Ok(None);
        };
        // Replaced in one step, so the emulator never reads a half-written file.
        let temp = dir.join("config.ini.aperture-tmp");
        if let Err(e) = fs::write(&temp, updated).and_then(|()| fs::rename(&temp, &path)) {
            if let Err(cleanup) = fs::remove_file(&temp) {
                log::trace!("Removing {}: {cleanup}", temp.display());
            }
            return Err(e).with_context(|| format!("Cannot change the settings of {name}"));
        }
        Ok(Some(avd_settings::describe_change(&before, &wanted.unapplied(&before))))
    }

    /// The memory `name` starts with: the chosen one, else its `config.ini`'s.
    pub fn start_ram_mb(&self, name: &str) -> ResultType<Option<u32>> {
        let dir = self.managed_dir(name)?;
        Ok(self.chosen_in(&dir, name).ram_mb)
    }

    fn exists(&self, name: &str) -> bool {
        self.avd_dir(name).exists() || self.ini_path(name).exists()
    }

    fn ini_text(&self, name: &str) -> String {
        format!(
            "avd.ini.encoding=UTF-8\npath={}\ntarget=android-35\n",
            self.avd_dir(name).display()
        )
    }

    fn rewrite_config(&self, name: &str, text: &str) -> String {
        let text = set_key(text, "AvdId", name);
        set_key(&text, "avd.ini.displayname", &display_name(name))
    }

    pub fn list(&self) -> ResultType<Vec<AvdEntry>> {
        let reader = match fs::read_dir(&self.root) {
            Ok(reader) => reader,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut entries = Vec::new();
        for item in reader {
            let path = item?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("ini") {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_avd_name(name) {
                continue;
            }
            let dir = self.avd_dir(name);
            if dir.exists() {
                if let Err(e) = self.ensure_inside(&dir) {
                    // Every inventory scan meets it again: log it once.
                    if self.warn_once(format!("list:{name}")) {
                        log::warn!("Skipping emulator {name}: {e}");
                    }
                    continue;
                }
            }
            let clone = read_marker(&dir);
            let config = fs::read_to_string(dir.join("config.ini"));
            if config.is_err() && clone.is_none() {
                continue; // incomplete: .ini without a usable folder
            }
            let config = config.unwrap_or_default();
            entries.push(AvdEntry {
                name: name.to_owned(),
                ram_mb: leading_number(get_key(&config, "hw.ramSize")),
                cores: leading_number(get_key(&config, "hw.cpu.ncore")),
                clone,
            });
        }
        entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(entries)
    }

    pub fn create(&self, name: &str, template: &str) -> ResultType<()> {
        let name = Self::checked_name(name)?;
        fs::create_dir_all(&self.root)?;
        if self.exists(name) {
            bail!("An emulator named {name} already exists");
        }
        let dir = self.avd_dir(name);
        fs::create_dir(&dir)?;
        let written = fs::write(dir.join("config.ini"), self.rewrite_config(name, template))
            .map_err(Into::into)
            .and_then(|()| fs::write(self.ini_path(name), self.ini_text(name)).map_err(Into::into));
        if let Err(e) = written {
            self.remove_quietly(name, true);
            return Err(e);
        }
        Ok(())
    }

    /// Removes a folder and `.ini` this module created, logging what it cannot.
    /// Returns whether everything was removed.
    fn remove_quietly(&self, name: &str, report: bool) -> bool {
        let mut clean = true;
        if let Err(e) = fs::remove_dir_all(self.avd_dir(name)) {
            if e.kind() != std::io::ErrorKind::NotFound {
                if report {
                    log::warn!("Cannot remove partial AVD {name}: {e}");
                }
                clean = false;
            }
        }
        if let Err(e) = fs::remove_file(self.ini_path(name)) {
            if e.kind() != std::io::ErrorKind::NotFound {
                if report {
                    log::warn!("Cannot remove partial AVD {name}.ini: {e}");
                }
                clean = false;
            }
        }
        clean
    }

    pub fn rename(&self, from: &str, to: &str) -> ResultType<()> {
        let from = Self::checked_name(from)?;
        let to = Self::checked_name(to)?;
        let (old_dir, old_ini) = (self.avd_dir(from), self.ini_path(from));
        if !old_dir.is_dir() || !old_ini.is_file() {
            bail!("Emulator {from} was not found");
        }
        if from.eq_ignore_ascii_case(to) || self.exists(to) {
            bail!("An emulator named {to} already exists");
        }
        if read_marker(&old_dir).is_some() {
            bail!("Emulator {from} is being cloned");
        }
        self.ensure_inside(&old_dir)?;
        self.ensure_inside(&old_ini)?;
        self.check_ini_path(from)?;
        let old_ini_text = fs::read_to_string(&old_ini)?;
        let new_dir = self.avd_dir(to);
        fs::rename(&old_dir, &new_dir)?;
        let finish = || -> ResultType<()> {
            let config_path = new_dir.join("config.ini");
            let config = fs::read_to_string(&config_path)?;
            fs::write(&config_path, self.rewrite_config(to, &config))?;
            let ini = set_key(&old_ini_text, "path", &new_dir.display().to_string());
            // path.rel= is resolved under the user's .android, never this folder.
            let ini = remove_key(&ini, "path.rel");
            fs::write(self.ini_path(to), ini)?;
            fs::remove_file(&old_ini)?;
            Ok(())
        };
        if let Err(e) = finish() {
            if let Err(undo) = fs::rename(&new_dir, &old_dir) {
                log::warn!("Cannot undo rename of {from}: {undo}");
            } else if let Err(undo) = fs::remove_file(self.ini_path(to)) {
                if undo.kind() != std::io::ErrorKind::NotFound {
                    log::warn!("Cannot remove {to}.ini after failed rename: {undo}");
                }
            }
            return Err(e);
        }
        Ok(())
    }

    pub fn delete(&self, name: &str) -> ResultType<()> {
        let name = Self::checked_name(name)?;
        let (dir, ini) = (self.avd_dir(name), self.ini_path(name));
        if !dir.exists() && !ini.exists() {
            bail!("Emulator {name} was not found");
        }
        if dir.exists() {
            self.ensure_inside(&dir)?;
        }
        if ini.exists() {
            self.ensure_inside(&ini)?;
        }
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        if ini.exists() {
            fs::remove_file(&ini)?;
        }
        Ok(())
    }

    /// Bytes a clone of `from` needs on the root's drive.
    pub fn required_free_bytes_for_clone(&self, from: &str) -> ResultType<u64> {
        let from = Self::checked_name(from)?;
        let dir = self.avd_dir(from);
        if !dir.is_dir() {
            bail!("Emulator {from} was not found");
        }
        let (_, files) = plan_copy(&dir, &self.avd_dir("_"))?;
        let total: u64 = files.iter().map(|f| f.size).sum();
        Ok(total.saturating_add(CLONE_HEADROOM_BYTES))
    }

    /// Exact copy of `from` as `to` (blocking). The marker in the new folder
    /// tracks progress; on any error the partial copy is removed.
    pub fn clone_avd(
        &self,
        from: &str,
        to: &str,
        host_pid: u32,
        mut progress: impl FnMut(u64, u64),
    ) -> ResultType<()> {
        let from = Self::checked_name(from)?;
        let to = Self::checked_name(to)?;
        let src = self.avd_dir(from);
        if !src.is_dir() || !self.ini_path(from).is_file() {
            bail!("Emulator {from} was not found");
        }
        if self.exists(to) {
            bail!("An emulator named {to} already exists");
        }
        if read_marker(&src).is_some() {
            bail!("Emulator {from} is being cloned");
        }
        self.ensure_inside(&src)?;
        self.check_ini_path(from)?;
        let (dirs, files) = plan_copy(&src, &self.avd_dir(to))?;
        let total: u64 = files.iter().map(|f| f.size).sum();

        fs::create_dir(self.avd_dir(to))?;
        let result = self.copy_into(from, to, host_pid, &dirs, &files, total, &mut progress);
        if let Err(e) = result {
            self.remove_quietly(to, true);
            return Err(e);
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn copy_into(
        &self,
        from: &str,
        to: &str,
        host_pid: u32,
        dirs: &[PathBuf],
        files: &[CopyItem],
        total: u64,
        progress: &mut impl FnMut(u64, u64),
    ) -> ResultType<()> {
        let dst = self.avd_dir(to);
        let started = unix_seconds();
        let mut state = CloneProgress {
            source: from.to_owned(),
            total_bytes: total,
            copied_bytes: 0,
            host_pid,
        };
        write_marker(&dst, &state, started)?;
        fs::write(self.ini_path(to), self.ini_text(to))?;
        for dir in dirs {
            fs::create_dir_all(dir)?;
        }
        let mut last_marker = Instant::now();
        let mut marker_failed = false;
        let mut buffer = vec![0u8; COPY_CHUNK_BYTES];
        for item in files {
            let is_config = item.to == dst.join("config.ini");
            if is_config {
                let config = fs::read_to_string(&item.from)?;
                fs::write(&item.to, self.rewrite_config(to, &config))?;
                state.copied_bytes += item.size;
            } else {
                let mut reader = fs::File::open(&item.from)?;
                let mut writer = fs::File::create(&item.to)?;
                loop {
                    let read = reader.read(&mut buffer)?;
                    if read == 0 {
                        break;
                    }
                    writer.write_all(&buffer[..read])?;
                    state.copied_bytes += read as u64;
                    progress(state.copied_bytes, total);
                    if last_marker.elapsed() >= MARKER_INTERVAL {
                        // Progress only: a transient sharing violation (an
                        // indexer or antivirus) must not abort the copy.
                        if let Err(e) = write_marker(&dst, &state, started) {
                            if !marker_failed {
                                log::warn!("Cannot update the progress of copying {from} to {to}: {e}");
                                marker_failed = true;
                            }
                        }
                        last_marker = Instant::now();
                    }
                }
                writer.flush()?;
            }
        }
        progress(state.copied_bytes, total);
        fs::remove_file(dst.join(CLONE_MARKER))?;
        // Left behind only by a failed marker update.
        if let Err(e) = fs::remove_file(dst.join(format!("{CLONE_MARKER}.tmp"))) {
            if e.kind() != std::io::ErrorKind::NotFound {
                log::warn!("Cannot remove the progress file of {to}: {e}");
            }
        }
        Ok(())
    }

    /// Removes clones a previous host process left unfinished; returns their
    /// names. A clone whose marker names `current_pid`, or whose lower-cased
    /// name is in `live` (copies this process is making), is still running.
    pub fn cleanup_stale_clones(
        &self,
        current_pid: u32,
        live: &BTreeSet<String>,
    ) -> ResultType<Vec<String>> {
        let reader = match fs::read_dir(&self.root) {
            Ok(reader) => reader,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut removed = Vec::new();
        let mut failing = BTreeSet::new();
        for item in reader {
            let path = item?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("avd") || !path.is_dir() {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_avd_name(name) || !path.join(CLONE_MARKER).exists() {
                continue;
            }
            if live.contains(&name.to_ascii_lowercase()) {
                continue;
            }
            match read_marker(&path) {
                Some(marker) if marker.host_pid == current_pid => continue,
                Some(_) => {}
                // Unreadable (perhaps for a moment): stale once it stops changing.
                None => {
                    let quiet = fs::metadata(path.join(CLONE_MARKER))
                        .and_then(|meta| meta.modified())
                        .ok()
                        .and_then(|modified| modified.elapsed().ok())
                        .map_or(false, |age| age >= UNREADABLE_MARKER_AGE);
                    if !quiet {
                        continue;
                    }
                }
            }
            if let Err(e) = self.ensure_inside(&path) {
                // Every inventory scan meets it again: log it once.
                if self.warn_once(format!("cleanup:{name}")) {
                    log::warn!("Skipping unfinished emulator clone {name}: {e}");
                }
                continue;
            }
            // A removal that already failed is retried without logging again.
            let reported = self.unremovable_set().contains(name);
            if !reported {
                log::info!("Removing unfinished emulator clone {name}");
            }
            if self.remove_quietly(name, !reported) {
                self.unremovable_set().remove(name);
                removed.push(name.to_owned());
            } else {
                self.note_cleanup_failure(name);
                failing.insert(name.to_owned());
            }
        }
        // Forget names that are gone or no longer stale, so a later failure logs again.
        self.unremovable_set().retain(|name| failing.contains(name));
        removed.sort();
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        path::{Path, PathBuf},
        time::{SystemTime, UNIX_EPOCH},
    };

    fn temp_home(suffix: &str) -> AvdHome {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("aperture-avd-{suffix}-{nonce}"));
        fs::create_dir_all(&root).unwrap();
        AvdHome::new(root)
    }

    fn read(path: impl AsRef<Path>) -> String {
        fs::read_to_string(path).unwrap()
    }

    fn cleanup(home: AvdHome) {
        fs::remove_dir_all(home.root()).unwrap();
    }

    fn make_source(home: &AvdHome, name: &str) -> PathBuf {
        home.create(name, NEW_AVD_TEMPLATE).unwrap();
        let dir = home.root().join(format!("{name}.avd"));
        fs::create_dir_all(dir.join("data")).unwrap();
        fs::create_dir_all(dir.join("snapshots")).unwrap();
        fs::write(dir.join("data").join("x.bin"), vec![7u8; 100_000]).unwrap();
        fs::write(dir.join("userdata-qemu.img"), vec![9u8; 50_000]).unwrap();
        fs::write(dir.join("snapshots").join("s.bin"), b"snap").unwrap();
        fs::write(dir.join("multiinstance.lock"), b"1").unwrap();
        fs::write(dir.join("userdata-qemu.img.lock"), b"1").unwrap();
        fs::write(dir.join("hardware-qemu.ini"), b"runtime").unwrap();
        fs::write(dir.join("aperture-emulator.log.1"), b"log").unwrap();
        fs::write(dir.join("emu-launch-params.txt"), b"params").unwrap();
        dir
    }

    #[test]
    fn rejects_unsafe_names() {
        for bad in [
            "", ".x", "a/b", r"a\b", "a:b", "..", "a b", "CON", "nul", "COM1", "lpt9", "Aux.txt",
            &"a".repeat(65),
        ] {
            assert!(!valid_avd_name(bad), "{bad}");
        }
        assert!(valid_avd_name("Maple_2.copy-1"));
        assert!(valid_avd_name("COM10"));
    }

    #[test]
    fn create_writes_a_bootable_avd() {
        let home = temp_home("create");
        home.create("Maple_2", NEW_AVD_TEMPLATE).unwrap();
        let ini = read(home.root().join("Maple_2.ini"));
        assert!(ini.contains(&format!("path={}", home.root().join("Maple_2.avd").display())));
        assert!(ini.lines().any(|l| l == "target=android-35"));
        let cfg = read(home.root().join("Maple_2.avd").join("config.ini"));
        for line in [
            "hw.ramSize=4096",
            "hw.cpu.ncore=4",
            "hw.gpu.mode=host",
            "PlayStore.enabled=true",
            "AvdId=Maple_2",
            "avd.ini.displayname=Maple 2",
            "hw.lcd.width=1080",
            "hw.lcd.height=2208",
            "hw.lcd.density=420",
            r"image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\",
        ] {
            assert!(cfg.lines().any(|l| l == line), "{line}");
        }
        assert!(!cfg.contains("disk.dataPartition.path"));
        assert!(home.create("Maple_2", NEW_AVD_TEMPLATE).is_err(), "name collision");
        assert!(home.create("../x", NEW_AVD_TEMPLATE).is_err());
        cleanup(home);
    }

    fn managed_screen_only() -> AvdSettings {
        AvdSettings { screen: Some(MANAGED_SCREEN), ..Default::default() }
    }

    #[test]
    fn managed_screen_rewrites_only_the_lcd_size() {
        let old = "hw.lcd.density=420
hw.lcd.height=2400
hw.lcd.vsync=60
hw.lcd.width=1080
";
        assert_eq!(
            with_settings(old, &managed_screen_only()).as_deref(),
            Some("hw.lcd.density=420
hw.lcd.height=2208
hw.lcd.vsync=60
hw.lcd.width=1080
")
        );
        let wide = "a=1
hw.lcd.width=720
hw.lcd.height=1280
b=2
";
        assert_eq!(
            with_settings(wide, &managed_screen_only()).as_deref(),
            Some("a=1
hw.lcd.width=1080
hw.lcd.height=2208
b=2
")
        );
        assert_eq!(
            with_settings("a=1
", &managed_screen_only()).as_deref(),
            Some("a=1
hw.lcd.width=1080
hw.lcd.height=2208
")
        );
        assert_eq!(with_settings("hw.lcd.width = 1080
hw.lcd.height=2208
", &managed_screen_only()), None);
    }

    #[test]
    fn ensure_managed_screen_rewrites_a_stopped_avd_once() {
        let home = temp_home("screen");
        let dir = make_source(&home, "Maple_1");
        let config = dir.join("config.ini");
        let old = read(&config).replace("hw.lcd.height=2208", "hw.lcd.height=2400");
        fs::write(&config, &old).unwrap();
        assert_eq!(
            home.apply_settings("Maple_1").unwrap().as_deref(),
            Some("screen 1080x2400 -> 1080x2208")
        );
        let new = read(&config);
        assert_eq!(new, old.replace("hw.lcd.height=2400", "hw.lcd.height=2208"));
        assert_eq!(home.apply_settings("Maple_1").unwrap(), None);
        assert_eq!(read(&config), new);
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains("tmp"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
        assert!(home.apply_settings("../x").is_err());
        cleanup(home);
    }

    #[test]
    fn chosen_settings_are_written_only_when_applied() {
        let home = temp_home("chosen");
        let dir = make_source(&home, "Maple_1");
        let config = dir.join("config.ini");
        let old = read(&config);
        let (current, chosen) = home.settings("Maple_1").unwrap();
        assert_eq!(
            current,
            AvdSettings { ram_mb: Some(4096), cores: Some(4), screen: Some((1080, 2208)) }
        );
        assert!(chosen.is_empty());
        let change = AvdSettings::requested(6144, 0, 1080, 2400).unwrap();
        home.choose_settings("Maple_1", change).unwrap();
        home.choose_settings("Maple_1", AvdSettings::requested(0, 6, 0, 0).unwrap()).unwrap();
        assert_eq!(read(&config), old, "choosing never writes config.ini");
        let (_, chosen) = home.settings("Maple_1").unwrap();
        assert_eq!(
            chosen,
            AvdSettings { ram_mb: Some(6144), cores: Some(6), screen: Some((1080, 2400)) }
        );
        assert_eq!(home.start_ram_mb("Maple_1").unwrap(), Some(6144));
        let applied = home.apply_settings("Maple_1").unwrap().unwrap();
        assert!(applied.contains("4096 -> 6144 MB"), "{applied}");
        let expected = set_key(&set_key(&set_key(&old, "hw.ramSize", "6144"), "hw.cpu.ncore", "6"), "hw.lcd.height", "2400");
        assert_eq!(read(&config), expected, "a chosen screen is kept, other lines too");
        assert_eq!(home.apply_settings("Maple_1").unwrap(), None);
        let entry = home.list().unwrap().into_iter().find(|e| e.name == "Maple_1").unwrap();
        assert_eq!((entry.ram_mb, entry.cores), (6144, 6));
        cleanup(home);
    }

    #[test]
    fn ensure_managed_screen_refuses_a_root_under_dot_android() {
        let outer = temp_home("dotandroid");
        let home = AvdHome::new(outer.root().join(".android").join("avd"));
        fs::create_dir_all(home.root()).unwrap();
        let dir = make_source(&home, "Dev_1");
        let config = dir.join("config.ini");
        let old = read(&config).replace("hw.lcd.height=2208", "hw.lcd.height=2400");
        fs::write(&config, &old).unwrap();
        assert!(home.apply_settings("Dev_1").is_err());
        assert!(home.choose_settings("Dev_1", AvdSettings::requested(2048, 0, 0, 0).unwrap()).is_err());
        assert_eq!(read(&config), old);
        assert!(!dir.join(avd_settings::SETTINGS_FILE).exists());
        cleanup(outer);
    }

    /// Run only while the trial AVD is stopped: Aperture's start does the same.
    #[test]
    #[ignore = "Rewrites the stopped Aperture_Trial_Play35 config.ini"]
    fn real_trial_gets_the_managed_screen() {
        let home = AvdHome::new(AvdHome::default_root());
        let old = home.apply_settings("Aperture_Trial_Play35").unwrap();
        eprintln!("RESULT trial screen was {old:?}");
        let config = read(home.root().join("Aperture_Trial_Play35.avd").join("config.ini"));
        assert_eq!(get_key(&config, "hw.lcd.width"), Some("1080"));
        assert_eq!(get_key(&config, "hw.lcd.height"), Some("2208"));
    }

    #[test]
    fn list_reads_ram_and_cores_and_skips_incomplete() {
        let home = temp_home("list");
        home.create("A", NEW_AVD_TEMPLATE).unwrap();
        fs::write(home.root().join("B.ini"), "target=android-35\n").unwrap();
        fs::write(home.root().join("not an avd.ini"), "x").unwrap();
        let entries = home.list().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "A");
        assert_eq!((entries[0].ram_mb, entries[0].cores), (4096, 4));
        assert!(entries[0].clone.is_none());
        cleanup(home);
    }

    #[test]
    fn clone_copies_exactly_except_runtime_files() {
        let home = temp_home("clone");
        let src = make_source(&home, "A");
        let before = read(src.join("config.ini"));
        let mut calls = Vec::new();
        home.clone_avd("A", "B", 4242, |copied, total| calls.push((copied, total)))
            .unwrap();
        let dst = home.root().join("B.avd");
        assert_eq!(fs::read(dst.join("data").join("x.bin")).unwrap(), vec![7u8; 100_000]);
        assert_eq!(fs::read(dst.join("userdata-qemu.img")).unwrap(), vec![9u8; 50_000]);
        assert!(!dst.join("snapshots").exists());
        assert!(!dst.join("multiinstance.lock").exists());
        assert!(!dst.join("userdata-qemu.img.lock").exists());
        assert!(!dst.join("hardware-qemu.ini").exists());
        assert!(!dst.join("aperture-emulator.log.1").exists());
        assert!(!dst.join("emu-launch-params.txt").exists());
        assert!(!dst.join("aperture-clone.json").exists());
        let cfg = read(dst.join("config.ini"));
        assert!(cfg.lines().any(|l| l == "AvdId=B"));
        assert!(cfg.lines().any(|l| l == "hw.ramSize=4096"));
        let ini = read(home.root().join("B.ini"));
        assert!(ini.contains(&format!("path={}", dst.display())));
        assert_eq!(read(src.join("config.ini")), before);
        assert!(src.join("snapshots").join("s.bin").exists());
        let (copied, total) = *calls.last().unwrap();
        assert_eq!(copied, total);
        assert!(total >= 150_000);
        assert_eq!(home.list().unwrap().len(), 2);
        assert!(home.required_free_bytes_for_clone("A").unwrap() >= total + (4 << 30));
        cleanup(home);
    }

    #[test]
    fn failed_clone_leaves_no_partial_copy() {
        let home = temp_home("failclone");
        make_source(&home, "A");
        // Missing source: nothing is created.
        assert!(home.clone_avd("Nope", "B", 1, |_, _| {}).is_err());
        assert!(!home.root().join("B.avd").exists());
        assert!(!home.root().join("B.ini").exists());
        // Existing target: refused, and the existing one is untouched.
        home.create("C", NEW_AVD_TEMPLATE).unwrap();
        let before = read(home.root().join("C.avd").join("config.ini"));
        assert!(home.clone_avd("A", "C", 1, |_, _| {}).is_err());
        assert_eq!(read(home.root().join("C.avd").join("config.ini")), before);
        assert!(home.clone_avd("A", "../x", 1, |_, _| {}).is_err());
        assert!(home.clone_avd("../x", "D", 1, |_, _| {}).is_err());
        cleanup(home);
    }

    #[test]
    fn unremovable_stale_clone_is_reported_once_and_retried() {
        use std::os::windows::fs::OpenOptionsExt;
        let home = temp_home("locked");
        home.create("B", NEW_AVD_TEMPLATE).unwrap();
        let dir = home.root().join("B.avd");
        fs::write(
            dir.join("aperture-clone.json"),
            r#"{"source":"A","total_bytes":200,"copied_bytes":50,"host_pid":1,"started":1}"#,
        )
        .unwrap();
        // Long untouched, so the marker counts as stale even while unreadable.
        fs::OpenOptions::new()
            .write(true)
            .open(dir.join("aperture-clone.json"))
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(600))
            .unwrap();
        // An exclusive handle on the marker keeps Windows from deleting it, so
        // every scan finds the clone stale and fails to remove it.
        let lock = fs::OpenOptions::new()
            .write(true)
            .share_mode(0)
            .open(dir.join("aperture-clone.json"))
            .unwrap();
        for _ in 0..3 {
            assert!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap().is_empty());
        }
        assert_eq!(home.unremovable_clones(), vec!["B".to_owned()]);
        assert!(home.note_cleanup_failure("C"));
        assert!(!home.note_cleanup_failure("C"));
        drop(lock);
        assert_eq!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap(), vec!["B".to_owned()]);
        assert!(home.unremovable_clones().is_empty());
    }

    #[test]
    fn stale_clone_marker_is_cleaned_up() {
        let home = temp_home("stale");
        make_source(&home, "A");
        home.create("B", NEW_AVD_TEMPLATE).unwrap();
        let marker = home.root().join("B.avd").join("aperture-clone.json");
        let json = |pid: u32| {
            format!(
                r#"{{"source":"A","total_bytes":200,"copied_bytes":50,"host_pid":{pid},"started":1}}"#
            )
        };
        fs::write(&marker, json(1)).unwrap();
        assert_eq!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap(), vec!["B".to_owned()]);
        assert!(!home.root().join("B.avd").exists());
        assert!(!home.root().join("B.ini").exists());
        assert!(home.root().join("A.avd").exists());

        home.create("B", NEW_AVD_TEMPLATE).unwrap();
        fs::write(&marker, json(2)).unwrap();
        assert!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap().is_empty());
        let entries = home.list().unwrap();
        let b = entries.iter().find(|e| e.name == "B").unwrap();
        let progress = b.clone.as_ref().unwrap();
        assert_eq!(progress.source, "A");
        assert_eq!(progress.percent(), 25);
        cleanup(home);
    }

    #[test]
    fn rename_and_delete_stay_inside_root() {
        let home = temp_home("rename");
        make_source(&home, "A");
        home.rename("A", "C").unwrap();
        assert!(!home.root().join("A.avd").exists());
        assert!(!home.root().join("A.ini").exists());
        let ini = read(home.root().join("C.ini"));
        assert!(ini.contains(&format!("path={}", home.root().join("C.avd").display())));
        let cfg = read(home.root().join("C.avd").join("config.ini"));
        assert!(cfg.lines().any(|l| l == "AvdId=C"));
        assert!(home.root().join("C.avd").join("data").join("x.bin").exists());

        assert!(home.rename("A", "D").is_err(), "missing source");
        home.create("E", NEW_AVD_TEMPLATE).unwrap();
        assert!(home.rename("C", "E").is_err(), "name collision");
        assert!(home.rename("C", r"..\x").is_err());
        assert!(home.rename("../x", "F").is_err());
        assert!(home.delete("../x").is_err());
        assert!(home.delete("Nope").is_err());
        assert!(home.root().join("C.avd").exists() && home.root().join("C.ini").exists());

        home.delete("C").unwrap();
        assert!(!home.root().join("C.avd").exists());
        assert!(!home.root().join("C.ini").exists());
        assert!(home.root().join("E.avd").exists());
        cleanup(home);
    }

    fn junction(link: &Path, target: &Path) {
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .unwrap();
        assert!(status.status.success(), "mklink failed");
    }

    fn outside_dir(suffix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("aperture-outside-{suffix}-{nonce}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn list_skips_avd_folders_that_resolve_outside_the_root() {
        let home = temp_home("listjunction");
        home.create("A", NEW_AVD_TEMPLATE).unwrap();
        let outside = outside_dir("list");
        fs::write(outside.join("config.ini"), "hw.ramSize=1
").unwrap();
        fs::write(home.root().join("X.ini"), "target=android-35
").unwrap();
        junction(&home.root().join("X.avd"), &outside);
        let names: Vec<_> = home.list().unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["A".to_owned()]);
        fs::remove_dir(home.root().join("X.avd")).unwrap();
        fs::remove_dir_all(outside).unwrap();
        cleanup(home);
    }

    #[test]
    fn clone_refuses_a_source_that_is_being_cloned() {
        let home = temp_home("clonemarker");
        make_source(&home, "A");
        fs::write(
            home.root().join("A.avd").join("aperture-clone.json"),
            r#"{"source":"Z","total_bytes":2,"copied_bytes":1,"host_pid":1,"started":1}"#,
        )
        .unwrap();
        assert!(home.clone_avd("A", "B", 1, |_, _| {}).is_err());
        assert!(!home.root().join("B.avd").exists());
        assert!(!home.root().join("B.ini").exists());
        cleanup(home);
    }

    #[test]
    fn cleanup_skips_bad_entries_and_reports_only_real_removals() {
        let home = temp_home("cleanupbad");
        let marker = r#"{"source":"A","total_bytes":2,"copied_bytes":1,"host_pid":1,"started":1}"#;
        let outside = outside_dir("cleanup");
        fs::write(outside.join("aperture-clone.json"), marker).unwrap();
        fs::write(home.root().join("B.ini"), "target=android-35
").unwrap();
        junction(&home.root().join("B.avd"), &outside);
        home.create("C", NEW_AVD_TEMPLATE).unwrap();
        fs::write(home.root().join("C.avd").join("aperture-clone.json"), marker).unwrap();
        assert_eq!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap(), vec!["C".to_owned()]);
        assert!(outside.join("aperture-clone.json").exists());
        assert!(!home.root().join("C.avd").exists());
        fs::remove_dir(home.root().join("B.avd")).unwrap();
        fs::remove_dir_all(outside).unwrap();
        cleanup(home);
    }

    #[test]
    fn clone_copy_error_removes_the_partial_copy() {
        use std::os::windows::fs::OpenOptionsExt;
        let home = temp_home("copyerror");
        let src = make_source(&home, "A");
        let image = fs::read(src.join("userdata-qemu.img")).unwrap();
        // An exclusive handle makes reading this file fail halfway through the copy.
        let lock = fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(src.join("data").join("x.bin"))
            .unwrap();
        assert!(home.clone_avd("A", "B", 1, |_, _| {}).is_err());
        drop(lock);
        assert!(!home.root().join("B.avd").exists());
        assert!(!home.root().join("B.ini").exists());
        assert_eq!(fs::read(src.join("data").join("x.bin")).unwrap(), vec![7u8; 100_000]);
        assert_eq!(fs::read(src.join("userdata-qemu.img")).unwrap(), image);
        let names: Vec<_> = home.list().unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["A".to_owned()]);
        cleanup(home);
    }

    #[test]
    fn periodic_marker_failure_does_not_abort_the_clone() {
        use std::os::windows::fs::OpenOptionsExt;
        let home = temp_home("markerfail");
        make_source(&home, "A");
        let tmp = home.root().join("B.avd").join("aperture-clone.json.tmp");
        let mut lock = None;
        // After the first chunk, the next marker update hits a sharing violation.
        let result = home.clone_avd("A", "B", 1, |_, _| {
            if lock.is_none() {
                std::thread::sleep(MARKER_INTERVAL + Duration::from_millis(100));
                lock = Some(
                    fs::OpenOptions::new()
                        .write(true)
                        .create(true)
                        .share_mode(0)
                        .open(&tmp)
                        .unwrap(),
                );
            }
        });
        assert!(lock.is_some(), "the copy never reported progress");
        drop(lock);
        result.unwrap();
        let dst = home.root().join("B.avd");
        assert_eq!(fs::read(dst.join("data").join("x.bin")).unwrap(), vec![7u8; 100_000]);
        assert!(!dst.join("aperture-clone.json").exists());
        assert!(home.list().unwrap().iter().any(|e| e.name == "B" && e.clone.is_none()));
        cleanup(home);
    }

    #[test]
    fn escaped_entries_are_logged_once() {
        let home = temp_home("warnonce");
        let outside = outside_dir("warnonce");
        fs::write(
            outside.join("aperture-clone.json"),
            r#"{"source":"A","total_bytes":2,"copied_bytes":1,"host_pid":1,"started":1}"#,
        )
        .unwrap();
        fs::write(home.root().join("X.ini"), "target=android-35\n").unwrap();
        junction(&home.root().join("X.avd"), &outside);
        for _ in 0..3 {
            assert!(home.list().unwrap().is_empty());
            assert!(home.cleanup_stale_clones(2, &BTreeSet::new()).unwrap().is_empty());
        }
        assert_eq!(
            home.warned_entries(),
            vec!["cleanup:X".to_owned(), "list:X".to_owned()]
        );
        fs::remove_dir(home.root().join("X.avd")).unwrap();
        fs::remove_dir_all(outside).unwrap();
        cleanup(home);
    }

    #[test]
    fn unreadable_marker_is_stale_only_when_old_and_not_live() {
        let home = temp_home("unreadable");
        home.create("B", NEW_AVD_TEMPLATE).unwrap();
        let marker = home.root().join("B.avd").join("aperture-clone.json");
        fs::write(&marker, "{\"source\":").unwrap();
        let none = BTreeSet::new();
        // Just written: possibly caught mid-update.
        assert!(home.cleanup_stale_clones(2, &none).unwrap().is_empty());
        let old = SystemTime::now() - Duration::from_secs(600);
        fs::OpenOptions::new()
            .write(true)
            .open(&marker)
            .unwrap()
            .set_modified(old)
            .unwrap();
        // A copy this process is making is never removed.
        let live = BTreeSet::from(["b".to_owned()]);
        assert!(home.cleanup_stale_clones(2, &live).unwrap().is_empty());
        assert!(home.root().join("B.avd").exists());
        assert_eq!(home.cleanup_stale_clones(2, &none).unwrap(), vec!["B".to_owned()]);
        assert!(!home.root().join("B.avd").exists());
        assert!(!home.root().join("B.ini").exists());
        cleanup(home);
    }
}
