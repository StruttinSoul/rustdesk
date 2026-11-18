use super::guest_protocol::{read_video_packet, VideoPacket, HELPER_SHA256, HELPER_VERSION};
use hbb_common::{bail, config::Config, log, ResultType};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fmt, fs,
    io::Read,
    net::{Shutdown, SocketAddr, TcpStream},
    ops::RangeInclusive,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Mutex, MutexGuard},
    thread,
    time::{Duration, Instant},
};

pub const SCRCPY_CONTROL_RESET_VIDEO: u8 = 17;

/// A Windows job whose processes are killed when its handle closes. Held
/// for the life of this process, it ends a session's long-lived `adb`
/// clients (and so their guest shells) even when this process dies
/// abruptly, which Windows does not do for child processes by itself.
pub(super) struct KillOnCloseJob(windows::Win32::Foundation::HANDLE);

// The handle is an owned kernel object handle, usable from any thread.
unsafe impl Send for KillOnCloseJob {}
unsafe impl Sync for KillOnCloseJob {}

impl KillOnCloseJob {
    pub(super) fn new() -> ResultType<Self> {
        use windows::Win32::System::JobObjects::{
            CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK,
        };
        // SAFETY: plain Win32 calls; the handle is owned by `Self` from here.
        let job = Self(unsafe { CreateJobObjectW(None, windows::core::PCWSTR::null()) }?);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        // Only the processes assigned here: anything they start (such as an
        // adb server) is not tied to this process.
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        // SAFETY: `limits` is a valid JOBOBJECT_EXTENDED_LIMIT_INFORMATION of
        // the size passed.
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        }?;
        Ok(job)
    }

    pub(super) fn assign(&self, child: &Child) -> ResultType<()> {
        use std::os::windows::io::AsRawHandle;
        let process = windows::Win32::Foundation::HANDLE(child.as_raw_handle());
        // SAFETY: both handles are valid for the duration of the call.
        unsafe { windows::Win32::System::JobObjects::AssignProcessToJobObject(self.0, process) }?;
        Ok(())
    }
}

impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        // SAFETY: the handle is owned and closed once.
        if let Err(error) = unsafe { windows::Win32::Foundation::CloseHandle(self.0) } {
            log::trace!("Session job close: {error}");
        }
    }
}

/// Ties a session's long-lived `adb` child to this process's lifetime. On
/// failure the child still runs (and is still ended by its owner on drop).
pub(super) fn bind_to_process_lifetime(child: &Child) {
    static JOB: std::sync::OnceLock<Option<KillOnCloseJob>> = std::sync::OnceLock::new();
    let job = JOB.get_or_init(|| match KillOnCloseJob::new() {
        Ok(job) => Some(job),
        Err(error) => {
            log::warn!("Cannot create the session process job: {error}");
            None
        }
    });
    if let Some(job) = job {
        if let Err(error) = job.assign(child) {
            hbb_common::throttled_log!(
                Duration::from_secs(60),
                warn,
                "Cannot tie an adb process to this process's lifetime: {error}"
            );
        }
    }
}

const GUEST_MAX_SIZE_OPTION: &str = "aperture-guest-max-size";
const GUEST_MAX_FPS_OPTION: &str = "aperture-guest-max-fps";
const GUEST_BIT_RATE_OPTION: &str = "aperture-guest-bit-rate";
const GUEST_KEYFRAME_INTERVAL_OPTION: &str = "aperture-guest-keyframe-interval";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct GuestStreamProfile {
    max_size: u32,
    max_fps: u32,
    bit_rate: u32,
    keyframe_interval_secs: u32,
}

impl GuestStreamProfile {
    const FULLSCREEN: Self = Self {
        max_size: 1280,
        max_fps: 30,
        bit_rate: 4_000_000,
        keyframe_interval_secs: 1,
    };

    fn preview() -> Self {
        Self {
            max_size: 360,
            max_fps: 30,
            bit_rate: 350_000,
            keyframe_interval_secs: 1,
        }
    }

    fn fullscreen() -> Self {
        Self::fullscreen_from_options(Config::get_option)
    }

    /// The Android Emulator's software encoder drops to about a third of any
    /// frame cap below its 60 Hz screen (30 -> ~10 fps), so it streams at 60.
    fn uncapped_fps(self) -> Self {
        Self {
            max_fps: 60,
            ..self
        }
    }

    fn fullscreen_from_options(option: impl Fn(&str) -> String) -> Self {
        let default = Self::FULLSCREEN;
        Self {
            max_size: option_in_range(
                &option(GUEST_MAX_SIZE_OPTION),
                720..=1920,
                default.max_size,
            ),
            max_fps: option_in_range(&option(GUEST_MAX_FPS_OPTION), 15..=60, default.max_fps),
            bit_rate: option_in_range(
                &option(GUEST_BIT_RATE_OPTION),
                1_000_000..=16_000_000,
                default.bit_rate,
            ),
            keyframe_interval_secs: option_in_range(
                &option(GUEST_KEYFRAME_INTERVAL_OPTION),
                1..=10,
                default.keyframe_interval_secs,
            ),
        }
    }

    /// The profile of a host-encoded Android Emulator stream: the preview
    /// profile, or the full-screen one at the emulator's 60 Hz.
    pub(super) fn for_android_emulator(preview: bool) -> Self {
        if preview {
            Self::preview()
        } else {
            Self::fullscreen().uncapped_fps()
        }
    }

    pub(super) fn max_size(&self) -> u32 {
        self.max_size
    }

    pub(super) fn max_fps(&self) -> u32 {
        self.max_fps
    }

    pub(super) fn bit_rate(&self) -> u32 {
        self.bit_rate
    }

    pub(super) fn keyframe_interval_secs(&self) -> u32 {
        self.keyframe_interval_secs
    }

    fn scrcpy_args(&self) -> [String; 4] {
        [
            format!("max_size={}", self.max_size),
            format!("max_fps={}", self.max_fps),
            format!("video_bit_rate={}", self.bit_rate),
            format!(
                "video_codec_options=i-frame-interval:int={}",
                self.keyframe_interval_secs
            ),
        ]
    }
}

fn option_in_range(value: &str, range: RangeInclusive<u32>, default: u32) -> u32 {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return default;
    }
    match value.parse::<u32>() {
        Ok(parsed) if range.contains(&parsed) => parsed,
        _ => default,
    }
}

pub struct GuestHelper {
    video: Option<TcpStream>,
    control: Option<TcpStream>,
    child: Option<Child>,
    adb: PathBuf,
    serial: String,
    jar: String,
    port: Option<u16>,
}

impl GuestHelper {
    pub fn connect(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, false, false, true)
    }

    /// Full-screen stream for Google's Android Emulator (see `uncapped_fps`).
    pub fn connect_android_emulator(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, false, true, true)
    }

    pub fn connect_preview(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, true, false, true)
    }

    /// Input only: the helper runs with `video=false`, so the first (and only)
    /// socket is control and there is no codec header (scrcpy's dummy byte proves it is live).
    pub fn connect_control_only(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, false, false, false)
    }

    fn connect_with_options(
        adb: &Path,
        serial: &str,
        helper: &Path,
        preview: bool,
        uncapped_fps: bool,
        video: bool,
    ) -> ResultType<Self> {
        if !is_local_emulator(serial) {
            bail!("Guest helper requires a local emulator ADB endpoint")
        }
        if hex::encode(Sha256::digest(fs::read(helper)?)) != HELPER_SHA256 {
            bail!("Guest helper checksum does not match the pinned release")
        }
        let id = uuid::Uuid::new_v4();
        let bytes = id.as_bytes();
        let scid = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) & 0x7fffffff;
        let mut session = Self {
            video: None,
            control: None,
            child: None,
            adb: adb.to_owned(),
            serial: serial.to_owned(),
            jar: format!("/data/local/tmp/mirpg-scrcpy-{id}.jar"),
            port: None,
        };
        let helper_string = helper.to_string_lossy();
        session.adb(&["push", &helper_string, &session.jar])?;
        let socket = format!("localabstract:scrcpy_{scid:08x}");
        let port = session
            .adb(&["forward", "tcp:0", &socket])?
            .trim()
            .parse::<u16>()?;
        if port == 0 {
            bail!("ADB returned an invalid forwarding port")
        }
        session.port = Some(port);
        let classpath = format!("CLASSPATH={}", session.jar);
        let scid_arg = format!("scid={scid:08x}");
        let profile = match (preview, uncapped_fps) {
            (true, _) => GuestStreamProfile::preview(),
            (false, true) => GuestStreamProfile::fullscreen().uncapped_fps(),
            (false, false) => GuestStreamProfile::fullscreen(),
        };
        if !preview && profile != GuestStreamProfile::FULLSCREEN {
            log::debug!("Guest fullscreen stream profile: {profile:?}");
        }
        let [max_size_arg, max_fps_arg, bit_rate_arg, codec_options_arg] = profile.scrcpy_args();
        let video_arg = format!("video={video}");
        // Without a video socket there is no codec header to prove the tunnel
        // reaches a live server (an ADB forward accepts before the server
        // listens), so control-only asks for scrcpy's dummy byte instead.
        let dummy_byte_arg = format!("send_dummy_byte={}", !video);
        session.child = Some(
            Command::new(adb)
                .creation_flags(0x08000000)
                .args([
                    "-s",
                    serial,
                    "shell",
                    &classpath,
                    "app_process",
                    "/",
                    "com.genymobile.scrcpy.Server",
                    HELPER_VERSION,
                    &scid_arg,
                    "tunnel_forward=true",
                    "audio=false",
                    &video_arg,
                    "video_codec=h264",
                    "send_device_meta=false",
                    &dummy_byte_arg,
                    "clipboard_autosync=false",
                    "power_on=false",
                    "cleanup=false",
                    "log_level=warn",
                    &max_size_arg,
                    &max_fps_arg,
                    &bit_rate_arg,
                    &codec_options_arg,
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?,
        );
        if let Some(child) = session.child.as_ref() {
            bind_to_process_lifetime(child);
        }
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let started = Instant::now();
        loop {
            let attempt = || -> ResultType<(Option<TcpStream>, TcpStream)> {
                let video_socket = if video {
                    let mut socket = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
                    socket.set_read_timeout(Some(Duration::from_secs(2)))?;
                    Some(socket)
                } else {
                    None
                };
                let mut control = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
                if !video {
                    control.set_read_timeout(Some(Duration::from_secs(2)))?;
                    let mut dummy = [0; 1];
                    control.read_exact(&mut dummy)?;
                    control.set_read_timeout(None)?;
                }
                control.set_write_timeout(Some(Duration::from_secs(1)))?;
                control.set_nodelay(true)?;
                let video_socket = match video_socket {
                    Some(mut socket) => {
                        let mut codec = [0; 4];
                        socket.read_exact(&mut codec)?;
                        if &codec != b"h264" {
                            bail!("Guest helper did not select H.264")
                        }
                        socket.set_read_timeout(None)?;
                        Some(socket)
                    }
                    None => None,
                };
                Ok((video_socket, control))
            };
            match attempt() {
                Ok((video, control)) => {
                    session.video = video;
                    session.control = Some(control);
                    log::debug!("Started owned guest helper {id} on {serial}");
                    return Ok(session);
                }
                Err(error) => {
                    let exited = match session.child.as_mut() {
                        Some(child) => child.try_wait()?.is_some(),
                        None => true,
                    };
                    if exited || started.elapsed() >= Duration::from_secs(15) {
                        bail!("Guest helper startup failed: {error}")
                    }
                    thread::sleep(Duration::from_millis(150));
                }
            }
        }
    }

    pub fn read_packet(&mut self) -> ResultType<VideoPacket> {
        match self.video.as_mut() {
            Some(video) => Ok(read_video_packet(video)?),
            None => bail!("Guest video socket is not connected"),
        }
    }

    pub fn control_socket(&self) -> ResultType<TcpStream> {
        match self.control.as_ref() {
            Some(control) => Ok(control.try_clone()?),
            None => bail!("Guest control socket is not connected"),
        }
    }

    pub fn cancellation_socket(&self) -> ResultType<TcpStream> {
        match self.video.as_ref() {
            Some(video) => Ok(video.try_clone()?),
            None => bail!("Guest video socket is not connected"),
        }
    }

    fn adb(&self, args: &[&str]) -> ResultType<String> {
        adb_command(&self.adb, &self.serial, args)
    }
}

pub fn helper_path() -> ResultType<PathBuf> {
    let executable = std::env::current_exe()?;
    let bundled = executable
        .parent()
        .map(|parent| parent.join("guest-helper").join("scrcpy-server-v4.0"));
    let cached = std::env::var_os("LOCALAPPDATA")
        .map(|root| PathBuf::from(root).join("MIRPG/guest-helper/scrcpy-4.0/scrcpy-server-v4.0"));
    bundled
        .into_iter()
        .chain(cached)
        .find(|path| path.is_file())
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Pinned Android guest helper is not installed"))
}

pub(super) fn is_default_adb_server(command: &[String]) -> bool {
    command
        .iter()
        .any(|arg| arg.eq_ignore_ascii_case("fork-server"))
        && command.windows(2).any(|args| {
            args[0] == "-L"
                && matches!(
                    args[1].as_str(),
                    "tcp:5037" | "tcp:localhost:5037" | "tcp:127.0.0.1:5037"
                )
        })
}

fn is_local_emulator(serial: &str) -> bool {
    if let Some(port) = serial.strip_prefix("emulator-") {
        return port
            .parse::<u16>()
            .map(|port| port >= 5554 && port % 2 == 0)
            .unwrap_or(false);
    }
    serial
        .parse::<SocketAddr>()
        .map(|address| {
            address.ip() == std::net::IpAddr::from([127, 0, 0, 1]) && address.port() != 0
        })
        .unwrap_or(false)
}

pub(super) fn adb_command(adb: &Path, serial: &str, args: &[&str]) -> ResultType<String> {
    adb_command_within(adb, serial, args, ADB_TIMEOUT)
}

/// Longest wait for one short adb command; it is killed after that.
const ADB_TIMEOUT: Duration = Duration::from_secs(15);
/// Guest commands that time out this many times in a row mark the guest as
/// not answering.
const JAM_TIMEOUTS: u32 = 2;
/// While a guest is not answering, at most one command per this period goes
/// through to see whether it is back; the others fail at once instead of
/// piling up more hung adb clients on its transport.
const JAM_PROBE_EVERY: Duration = Duration::from_secs(10);

/// Android behind an ADB serial did not answer in time.
#[derive(Debug)]
pub(super) struct GuestNotAnswering {
    pub(super) waited: Option<Duration>,
}

impl fmt::Display for GuestNotAnswering {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Android isn't answering on the PC")?;
        match self.waited {
            Some(waited) => write!(f, " (ADB gave no reply within {} s)", waited.as_secs())?,
            None => f.write_str(" (ADB is not replying)")?,
        }
        f.write_str(". Wait a moment and open it again, or restart the emulator.")
    }
}

impl std::error::Error for GuestNotAnswering {}

pub(super) fn is_not_answering(error: &hbb_common::anyhow::Error) -> bool {
    error.downcast_ref::<GuestNotAnswering>().is_some()
}

/// Recent guest-command timeouts of one serial.
#[derive(Default)]
struct AdbHealth {
    timeouts: u32,
    last_probe: Option<Instant>,
    /// A probe admitted while jammed has not finished yet.
    probing: bool,
}

impl AdbHealth {
    fn jammed(&self) -> bool {
        self.timeouts >= JAM_TIMEOUTS
    }

    /// Whether a guest command may run now.
    fn admit(&mut self, now: Instant) -> bool {
        if !self.jammed() {
            return true;
        }
        if !self.probing
            && self
                .last_probe
                .map_or(true, |probe| now.saturating_duration_since(probe) >= JAM_PROBE_EVERY)
        {
            self.last_probe = Some(now);
            self.probing = true;
            return true;
        }
        false
    }

    /// A timed-out command counts as the latest probe.
    fn record(&mut self, timed_out: bool, now: Instant) {
        if timed_out {
            self.timeouts = self.timeouts.saturating_add(1);
            self.last_probe = Some(now);
            self.probing = false;
        } else {
            *self = Self::default();
        }
    }
}

static ADB_HEALTH: Mutex<BTreeMap<String, AdbHealth>> = Mutex::new(BTreeMap::new());

fn adb_health() -> MutexGuard<'static, BTreeMap<String, AdbHealth>> {
    // Counters only: a panicking holder leaves nothing half-updated.
    ADB_HEALTH.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Whether Android behind `serial` has stopped answering ADB.
pub(super) fn is_jammed(serial: &str) -> bool {
    adb_health().get(serial).map_or(false, AdbHealth::jammed)
}

/// Commands served by Android's adbd (rather than by the ADB server or the
/// emulator console), which hang when the guest or its transport is stuck.
fn reaches_guest(args: &[&str]) -> bool {
    matches!(args.first(), Some(&"shell") | Some(&"push") | Some(&"reboot"))
}

/// `adb_command` with its own time limit.
pub(super) fn adb_command_within(
    adb: &Path,
    serial: &str,
    args: &[&str],
    limit: Duration,
) -> ResultType<String> {
    if !is_local_emulator(serial) {
        bail!("ADB requires a local emulator endpoint")
    }
    if !reaches_guest(args) {
        return run_adb_within(adb, &[&["-s", serial], args].concat(), limit);
    }
    if !adb_health()
        .entry(serial.to_owned())
        .or_default()
        .admit(Instant::now())
    {
        return Err(GuestNotAnswering { waited: None }.into());
    }
    let result = run_adb_within(adb, &[&["-s", serial], args].concat(), limit);
    let timed_out = result.as_ref().err().map_or(false, is_not_answering);
    let mut health = adb_health();
    let entry = health.entry(serial.to_owned()).or_default();
    let was_jammed = entry.jammed();
    entry.record(timed_out, Instant::now());
    if entry.jammed() && !was_jammed {
        log::warn!("Android behind {serial} is not answering ADB; holding further commands");
    } else if was_jammed && !entry.jammed() {
        log::info!("Android behind {serial} answers ADB again");
    }
    result
}

/// `adb devices` on the default server.
pub(super) fn adb_devices(adb: &Path) -> ResultType<String> {
    run_adb_within(adb, &["devices"], Duration::from_secs(5))
}

fn run_adb_within(adb: &Path, args: &[&str], limit: Duration) -> ResultType<String> {
    let mut child = Command::new(adb)
        .creation_flags(0x08000000)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let mut stdout = String::new();
            let mut stderr = String::new();
            if let Some(pipe) = child.stdout.take() {
                pipe.take(16384).read_to_string(&mut stdout)?;
            }
            if let Some(pipe) = child.stderr.take() {
                pipe.take(16384).read_to_string(&mut stderr)?;
            }
            if !status.success() {
                bail!("Guest ADB command failed: {}", stderr.trim())
            }
            return Ok(stdout);
        }
        if started.elapsed() > limit {
            child.kill()?;
            let _ = child.wait()?;
            return Err(GuestNotAnswering {
                waited: Some(limit),
            }
            .into());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

impl Drop for GuestHelper {
    fn drop(&mut self) {
        for socket in [self.video.take(), self.control.take()]
            .into_iter()
            .flatten()
        {
            if let Err(error) = socket.shutdown(Shutdown::Both) {
                log::trace!("Guest socket shutdown: {error}");
            }
        }
        if let Some(mut child) = self.child.take() {
            let started = Instant::now();
            while started.elapsed() < Duration::from_secs(3) {
                match child.try_wait() {
                    Ok(Some(_)) => break,
                    Ok(None) => thread::sleep(Duration::from_millis(50)),
                    Err(error) => {
                        log::warn!("Guest helper exit check failed: {error}");
                        break;
                    }
                }
            }
            if matches!(child.try_wait(), Ok(None)) {
                if let Err(error) = child.kill().and_then(|_| child.wait()) {
                    log::warn!("Owned guest ADB child cleanup failed: {error}");
                }
            }
        }
        if let Some(port) = self.port.take() {
            if let Err(error) = self.adb(&["forward", "--remove", &format!("tcp:{port}")]) {
                log::warn!("Owned guest forward cleanup failed: {error}");
            }
        }
        if let Err(error) = self.adb(&["shell", "rm", "-f", &self.jar]) {
            log::warn!("Owned guest helper file cleanup failed: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hung_adb_client_is_killed_at_its_limit_and_reports_android_not_answering() {
        // `ping` stands in for an adb client whose guest never answers.
        let started = Instant::now();
        let error = run_adb_within(
            Path::new("ping"),
            &["-n", "30", "127.0.0.1"],
            Duration::from_millis(300),
        )
        .unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
        assert!(is_not_answering(&error), "{error}");
        assert!(error.to_string().starts_with("Android isn't answering on the PC"), "{error}");
    }

    #[test]
    fn two_timeouts_in_a_row_hold_guest_commands_but_let_a_probe_through() {
        let mut health = AdbHealth::default();
        let start = Instant::now();
        health.record(true, start);
        assert!(!health.jammed());
        assert!(health.admit(start));
        health.record(true, start);
        assert!(health.jammed());
        // Held until a period after the last timeout, then one probe at a time.
        assert!(!health.admit(start));
        assert!(!health.admit(start + JAM_PROBE_EVERY - Duration::from_millis(1)));
        let probe = start + JAM_PROBE_EVERY;
        assert!(health.admit(probe));
        assert!(!health.admit(probe + Duration::from_secs(1)));
        // Still running a whole period later (its limit is longer): no second probe.
        assert!(!health.admit(probe + JAM_PROBE_EVERY + Duration::from_secs(1)));
        // The probe timed out too: held for another period.
        let late = probe + Duration::from_secs(8);
        health.record(true, late);
        assert!(!health.admit(late + JAM_PROBE_EVERY - Duration::from_millis(1)));
        assert!(health.admit(late + JAM_PROBE_EVERY));
        // An answer ends it.
        health.record(false, late);
        assert!(!health.jammed());
        assert!(health.admit(late));
        assert!(health.admit(late));
        // A success between timeouts starts the count again.
        health.record(true, late);
        health.record(false, late);
        health.record(true, late);
        assert!(!health.jammed());
    }

    #[test]
    fn a_jammed_serial_fails_guest_commands_at_once_but_not_console_commands() {
        let serial = "emulator-5998";
        {
            let mut health = adb_health();
            let entry = health.entry(serial.to_owned()).or_default();
            entry.record(true, Instant::now());
            entry.record(true, Instant::now());
        }
        assert!(is_jammed(serial));
        // A missing adb.exe would fail to spawn: failing with "not answering"
        // proves the command never ran.
        let missing = Path::new(r"C:\no\such\adb.exe");
        let started = Instant::now();
        let error = adb_command(missing, serial, &["shell", "getprop"]).unwrap_err();
        assert!(is_not_answering(&error), "{error}");
        let error = adb_command(missing, serial, &["push", "a", "b"]).unwrap_err();
        assert!(is_not_answering(&error), "{error}");
        let error = adb_command(missing, serial, &["reboot"]).unwrap_err();
        assert!(is_not_answering(&error), "{error}");
        assert!(started.elapsed() < Duration::from_millis(500));
        // The emulator console (stop) is not held.
        let error = adb_command(missing, serial, &["emu", "kill"]).unwrap_err();
        assert!(!is_not_answering(&error), "{error}");
        adb_health().remove(serial);
    }

    #[test]
    fn closing_the_session_job_kills_its_processes() {
        let job = KillOnCloseJob::new().unwrap();
        let mut child = Command::new("ping")
            .creation_flags(0x08000000)
            .args(["-n", "30", "127.0.0.1"])
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        job.assign(&child).unwrap();
        thread::sleep(Duration::from_millis(200));
        assert!(child.try_wait().unwrap().is_none(), "ping ended early");
        drop(job);
        let closed = Instant::now();
        while child.try_wait().unwrap().is_none() {
            assert!(
                closed.elapsed() < Duration::from_secs(2),
                "the process outlived its job"
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
    use std::io::Write;

    #[test]
    fn selects_the_emulator_adb_server_instead_of_the_phone_pairing_server() {
        let command = |socket: &str| {
            ["adb", "-L", socket, "fork-server", "server"]
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        assert!(is_default_adb_server(&command("tcp:5037")));
        assert!(!is_default_adb_server(&command("tcp:5038")));
        assert!(!is_default_adb_server(&["adb".into(), "devices".into()]));
    }

    #[test]
    fn rejects_non_loopback_guest_before_executing_adb() {
        let error = match GuestHelper::connect(
            Path::new("missing-adb"),
            "10.0.4.59:5555",
            Path::new("missing-helper"),
        ) {
            Ok(_) => panic!("Non-loopback guest must be rejected"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("local emulator"), "{error}");
    }

    #[test]
    fn rejects_unsigned_helper_before_executing_adb() {
        let path = std::env::temp_dir().join(format!("mirpg-helper-test-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"unverified helper").unwrap();
        let result = GuestHelper::connect(Path::new("missing-adb"), "127.0.0.1:5555", &path);
        std::fs::remove_file(path).unwrap();
        let error = match result {
            Ok(_) => panic!("Unverified helper must be rejected"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("checksum"), "{error}");
    }

    fn fullscreen_profile_from(pairs: &[(&str, &str)]) -> GuestStreamProfile {
        GuestStreamProfile::fullscreen_from_options(|key| {
            pairs
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| (*value).to_owned())
                .unwrap_or_default()
        })
    }

    #[test]
    fn android_emulator_streams_at_sixty_fps() {
        // Below 60 the Android Emulator's software encoder falls to ~10 fps.
        let configured = fullscreen_profile_from(&[(GUEST_MAX_FPS_OPTION, "30")]);
        assert_eq!(
            configured.uncapped_fps(),
            GuestStreamProfile {
                max_fps: 60,
                ..configured
            }
        );
        assert_eq!(GuestStreamProfile::FULLSCREEN.max_fps, 30);
    }

    #[test]
    fn fullscreen_profile_defaults_match_the_previous_fixed_values() {
        let profile = fullscreen_profile_from(&[]);
        assert_eq!(
            (
                profile.max_size,
                profile.max_fps,
                profile.bit_rate,
                profile.keyframe_interval_secs
            ),
            (1280, 30, 4_000_000, 1)
        );
        let preview = GuestStreamProfile::preview();
        assert_eq!(
            (
                preview.max_size,
                preview.max_fps,
                preview.bit_rate,
                preview.keyframe_interval_secs
            ),
            (360, 30, 350_000, 1)
        );
    }

    #[test]
    fn fullscreen_profile_applies_valid_overrides_per_field() {
        let all = fullscreen_profile_from(&[
            ("aperture-guest-max-size", "1920"),
            ("aperture-guest-max-fps", "60"),
            ("aperture-guest-bit-rate", "16000000"),
            ("aperture-guest-keyframe-interval", "10"),
        ]);
        assert_eq!(
            all,
            GuestStreamProfile {
                max_size: 1920,
                max_fps: 60,
                bit_rate: 16_000_000,
                keyframe_interval_secs: 10,
            }
        );
        let low = fullscreen_profile_from(&[
            ("aperture-guest-max-size", "720"),
            ("aperture-guest-max-fps", "15"),
            ("aperture-guest-bit-rate", "1000000"),
        ]);
        assert_eq!(
            low,
            GuestStreamProfile {
                max_size: 720,
                max_fps: 15,
                bit_rate: 1_000_000,
                keyframe_interval_secs: 1,
            }
        );
        let one = fullscreen_profile_from(&[("aperture-guest-max-fps", "60")]);
        assert_eq!(
            one,
            GuestStreamProfile {
                max_fps: 60,
                ..GuestStreamProfile::FULLSCREEN
            }
        );
    }

    #[test]
    fn fullscreen_profile_rejects_invalid_values_per_field() {
        let cases: [(&str, &str); 14] = [
            ("aperture-guest-max-size", ""),
            ("aperture-guest-max-size", "big"),
            ("aperture-guest-max-size", "-1280"),
            ("aperture-guest-max-size", "0"),
            ("aperture-guest-max-size", "719"),
            ("aperture-guest-max-size", "1921"),
            ("aperture-guest-max-fps", "14"),
            ("aperture-guest-max-fps", "61"),
            ("aperture-guest-max-fps", "+30"),
            ("aperture-guest-bit-rate", "999999"),
            ("aperture-guest-bit-rate", "16000001"),
            ("aperture-guest-bit-rate", "99999999999999999999"),
            ("aperture-guest-keyframe-interval", "0"),
            ("aperture-guest-keyframe-interval", "11"),
        ];
        for case in cases {
            assert_eq!(
                fullscreen_profile_from(&[case]),
                GuestStreamProfile::FULLSCREEN,
                "{case:?}"
            );
        }
        let mixed = fullscreen_profile_from(&[
            ("aperture-guest-max-size", "1600"),
            ("aperture-guest-max-fps", "120"),
            ("aperture-guest-bit-rate", "8000000"),
            ("aperture-guest-keyframe-interval", "2.5"),
        ]);
        assert_eq!(
            mixed,
            GuestStreamProfile {
                max_size: 1600,
                bit_rate: 8_000_000,
                ..GuestStreamProfile::FULLSCREEN
            }
        );
    }

    #[test]
    fn default_profiles_format_the_previous_scrcpy_arguments() {
        assert_eq!(
            fullscreen_profile_from(&[]).scrcpy_args(),
            [
                "max_size=1280",
                "max_fps=30",
                "video_bit_rate=4000000",
                "video_codec_options=i-frame-interval:int=1",
            ]
        );
        assert_eq!(
            GuestStreamProfile::preview().scrcpy_args(),
            [
                "max_size=360",
                "max_fps=30",
                "video_bit_rate=350000",
                "video_codec_options=i-frame-interval:int=1",
            ]
        );
    }

    #[test]
    #[ignore = "Runs the verified helper in an explicitly selected local Android guest"]
    fn captures_real_local_guest() {
        let adb = PathBuf::from(std::env::var("MIRPG_TEST_ADB").expect("Set MIRPG_TEST_ADB"));
        let serial = std::env::var("MIRPG_TEST_GUEST_SERIAL").expect("Set MIRPG_TEST_GUEST_SERIAL");
        let mut helper = GuestHelper::connect(&adb, &serial, &helper_path().unwrap()).unwrap();
        assert!(
            matches!(helper.read_packet().unwrap(), VideoPacket::Session { width, height } if width > 0 && height > 0)
        );
        let mut got_key = false;
        for _ in 0..5 {
            if matches!(
                helper.read_packet().unwrap(),
                VideoPacket::Frame { key: true, .. }
            ) {
                got_key = true;
                break;
            }
        }
        assert!(got_key, "Guest must produce an initial keyframe");
    }

    #[test]
    #[ignore = "Measures keyframe cadence in an explicitly selected local Android guest"]
    fn real_local_guest_measures_preview_keyframe_cadence() {
        let adb = PathBuf::from(std::env::var("MIRPG_TEST_ADB").expect("Set MIRPG_TEST_ADB"));
        let serial = std::env::var("MIRPG_TEST_GUEST_SERIAL").expect("Set MIRPG_TEST_GUEST_SERIAL");
        let mut helper =
            GuestHelper::connect_preview(&adb, &serial, &helper_path().unwrap()).unwrap();
        helper.video.as_ref().unwrap().set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut first_pts = None;
        let mut last_pts = 0_u64;
        let mut keyframes = 0_usize;
        for _ in 0..180 {
            match helper.read_packet().unwrap() {
                VideoPacket::Frame {
                    key,
                    pts_us,
                    config,
                    ..
                } => {
                    if config {
                        continue;
                    }
                    if first_pts.is_none() {
                        first_pts = Some(pts_us);
                    }
                    last_pts = pts_us;
                    if key {
                        keyframes += 1;
                    }
                    if let Some(first) = first_pts {
                        if last_pts.saturating_sub(first) >= 3_000_000 {
                            break;
                        }
                    }
                }
                VideoPacket::Session { .. } => {}
            }
        }
        let span = first_pts.map(|first| last_pts.saturating_sub(first)).unwrap_or(0);
        assert!(span >= 2_500_000, "Preview did not produce enough timed video: {span} us");
        eprintln!("Observed {keyframes} preview keyframes over {span} us");
    }

    #[test]
    #[ignore = "Verifies scrcpy reset-video recovery in an explicitly selected local Android guest"]
    fn real_local_guest_reset_video_emits_fresh_keyframe() {
        let adb = PathBuf::from(std::env::var("MIRPG_TEST_ADB").expect("Set MIRPG_TEST_ADB"));
        let serial = std::env::var("MIRPG_TEST_GUEST_SERIAL").expect("Set MIRPG_TEST_GUEST_SERIAL");
        let mut helper =
            GuestHelper::connect_preview(&adb, &serial, &helper_path().unwrap()).unwrap();
        helper.video.as_ref().unwrap().set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut control = helper.control_socket().unwrap();
        let mut initial_pts = None;
        for _ in 0..60 {
            if let VideoPacket::Frame {
                key: true,
                pts_us,
                config: false,
                ..
            } = helper.read_packet().unwrap()
            {
                initial_pts = Some(pts_us);
                break;
            }
        }
        let initial_pts = initial_pts.expect("Guest must produce an initial keyframe");
        control.write_all(&[SCRCPY_CONTROL_RESET_VIDEO]).unwrap();
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(5) {
            if let VideoPacket::Frame {
                key: true,
                pts_us,
                config: false,
                ..
            } = helper.read_packet().unwrap()
            {
                if pts_us > initial_pts {
                    return;
                }
            }
        }
        panic!("scrcpy reset-video did not produce a fresh keyframe");
    }

    fn probe_display_size(adb: &Path, serial: &str) -> (u16, u16) {
        let out = adb_command(adb, serial, &["shell", "wm", "size"]).unwrap();
        // "Physical size: 1080x2400" optionally followed by "Override size: ...".
        let size = out
            .lines()
            .filter_map(|line| line.rsplit(':').next())
            .map(str::trim)
            .last()
            .and_then(|size| size.split_once('x'))
            .and_then(|(w, h)| Some((w.parse::<u16>().ok()?, h.parse::<u16>().ok()?)))
            .expect("wm size output");
        size
    }

    fn probe_tap(control: &mut TcpStream, x: u32, y: u32, width: u16, height: u16) {
        use super::super::guest_protocol::touch_packet;
        control.write_all(&touch_packet(0, 0, x, y, width, height).unwrap()).unwrap();
        control.write_all(&touch_packet(1, 0, x, y, width, height).unwrap()).unwrap();
    }

    /// `adb shell` with the whole output captured (`run_adb` cannot drain a
    /// large dump).
    fn probe_shell(adb: &Path, serial: &str, args: &[&str]) -> String {
        let output = Command::new(adb)
            .creation_flags(0x08000000)
            .args(["-s", serial, "shell"])
            .args(args)
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    /// The visible texts of the foreground screen, in document order.
    fn probe_screen_texts(adb: &Path, serial: &str) -> Vec<String> {
        let xml = probe_shell(adb, serial, &["uiautomator dump /data/local/tmp/probe-ui.xml >/dev/null; cat /data/local/tmp/probe-ui.xml"]);
        let mut texts = Vec::new();
        for part in xml.split(" text=\"").skip(1) {
            if let Some((text, _)) = part.split_once('"') {
                if !text.is_empty() {
                    texts.push(text.to_owned());
                }
            }
        }
        texts
    }

    fn probe_open_settings(adb: &Path, serial: &str) -> Vec<String> {
        probe_shell(adb, serial, &["am", "force-stop", "com.android.settings"]);
        probe_shell(adb, serial, &["input", "keyevent", "3"]);
        probe_shell(adb, serial, &["am", "start", "-a", "android.settings.SETTINGS"]);
        thread::sleep(Duration::from_secs(3));
        probe_screen_texts(adb, serial)
    }

    #[test]
    #[ignore = "Probes helper control-only touch space in an explicitly selected local Android guest"]
    fn real_local_guest_control_only_touch_space() {
        let adb = PathBuf::from(std::env::var("MIRPG_TEST_ADB").expect("Set MIRPG_TEST_ADB"));
        let serial = std::env::var("MIRPG_TEST_GUEST_SERIAL").expect("Set MIRPG_TEST_GUEST_SERIAL");
        let (w, h) = probe_display_size(&adb, &serial);
        eprintln!("display size {w}x{h}");
        let mut helper =
            GuestHelper::connect_control_only(&adb, &serial, &helper_path().unwrap()).unwrap();
        assert!(helper.read_packet().is_err(), "control-only has no video socket");
        let mut control = helper.control_socket().unwrap();
        let (cx, cy) = ((w / 2) as u32, (h / 2) as u32);
        let main = probe_open_settings(&adb, &serial);
        eprintln!("settings main screen: {main:?}");

        probe_tap(&mut control, cx, cy, w, h);
        thread::sleep(Duration::from_millis(1500));
        let after_display = probe_screen_texts(&adb, &serial);
        eprintln!("after display-size tap ({cx},{cy}) in {w}x{h}: {after_display:?}");

        let main_again = probe_open_settings(&adb, &serial);
        assert_eq!(main, main_again, "settings must reset to the same screen");
        let (hw, hh) = (w / 2, h / 2);
        let (hx, hy) = ((hw / 2) as u32, (hh / 2) as u32);
        probe_tap(&mut control, hx, hy, hw, hh);
        thread::sleep(Duration::from_millis(1500));
        let after_half = probe_screen_texts(&adb, &serial);
        eprintln!("after half-size tap ({hx},{hy}) in {hw}x{hh}: {after_half:?}");

        probe_shell(&adb, &serial, &["input", "keyevent", "3"]);
        assert_ne!(main, after_display, "display-size tap must be delivered at the centre");
        eprintln!(
            "RESULT display_delivered={} half_delivered={} half_same_target_as_display={}",
            main != after_display,
            main != after_half,
            after_half == after_display
        );
    }
}
