use super::guest_protocol::{read_video_packet, VideoPacket, HELPER_SHA256, HELPER_VERSION};
use hbb_common::{bail, config::Config, log, ResultType};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    net::{Shutdown, SocketAddr, TcpStream},
    ops::RangeInclusive,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const SCRCPY_CONTROL_RESET_VIDEO: u8 = 17;

const GUEST_MAX_SIZE_OPTION: &str = "aperture-guest-max-size";
const GUEST_MAX_FPS_OPTION: &str = "aperture-guest-max-fps";
const GUEST_BIT_RATE_OPTION: &str = "aperture-guest-bit-rate";
const GUEST_KEYFRAME_INTERVAL_OPTION: &str = "aperture-guest-keyframe-interval";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GuestStreamProfile {
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
        Self::connect_with_options(adb, serial, helper, false, false)
    }

    /// Full-screen stream for Google's Android Emulator (see `uncapped_fps`).
    pub fn connect_android_emulator(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, false, true)
    }

    pub fn connect_preview(adb: &Path, serial: &str, helper: &Path) -> ResultType<Self> {
        Self::connect_with_options(adb, serial, helper, true, false)
    }

    fn connect_with_options(
        adb: &Path,
        serial: &str,
        helper: &Path,
        preview: bool,
        uncapped_fps: bool,
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
                    "video_codec=h264",
                    "send_device_meta=false",
                    "send_dummy_byte=false",
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
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let started = Instant::now();
        loop {
            let attempt = || -> ResultType<(TcpStream, TcpStream)> {
                let mut video = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
                video.set_read_timeout(Some(Duration::from_secs(2)))?;
                let control = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
                control.set_write_timeout(Some(Duration::from_secs(1)))?;
                control.set_nodelay(true)?;
                let mut codec = [0; 4];
                video.read_exact(&mut codec)?;
                if &codec != b"h264" {
                    bail!("Guest helper did not select H.264")
                }
                video.set_read_timeout(None)?;
                Ok((video, control))
            };
            match attempt() {
                Ok((video, control)) => {
                    session.video = Some(video);
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
    if !is_local_emulator(serial) {
        bail!("ADB requires a local emulator endpoint")
    }
    run_adb(adb, &[&["-s", serial], args].concat())
}

/// `adb devices` on the default server.
pub(super) fn adb_devices(adb: &Path) -> ResultType<String> {
    run_adb(adb, &["devices"])
}

fn run_adb(adb: &Path, args: &[&str]) -> ResultType<String> {
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
        if started.elapsed() > Duration::from_secs(15) {
            child.kill()?;
            let _ = child.wait()?;
            bail!("Guest ADB command timed out")
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
}
