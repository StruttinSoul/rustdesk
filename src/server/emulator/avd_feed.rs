//! Discovery of the Android Emulator's local gRPC screen feed and the little
//! protobuf / gRPC wire format needed to read it. Pure apart from `discover`.

use super::avd;
use hbb_common::{
    bail,
    protobuf::{CodedInputStream, CodedOutputStream},
    ResultType,
};
use hbb_common::tokio::{self, sync::Notify};
use std::{
    fmt,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, TrySendError},
        Arc,
    },
    thread::JoinHandle,
    time::Duration,
};

const RGBA8888: i32 = 1;
const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

/// The emulator's gRPC bearer token. Never printed.
#[derive(Clone, PartialEq, Eq)]
pub struct FeedToken(String);

impl FeedToken {
    pub fn bearer(&self) -> String {
        format!("Bearer {}", self.0)
    }
}

impl fmt::Debug for FeedToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedEndpoint {
    pub port: u16,
    pub token: FeedToken,
    /// `emulator-<port.serial>`: the guest's ADB serial, when the file names it.
    pub serial: Option<String>,
}

/// Reads `grpc.port` and `grpc.token` from an emulator `pid_<pid>.ini`.
pub fn parse_running_ini(text: &str) -> ResultType<FeedEndpoint> {
    let mut port = None;
    let mut token = None;
    let mut serial = None;
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "grpc.port" => port = value.trim().parse::<u16>().ok().filter(|p| *p != 0),
            "port.serial" => {
                serial = value
                    .trim()
                    .parse::<u16>()
                    .ok()
                    .filter(|port| *port >= 5554 && port % 2 == 0)
                    .map(|port| format!("emulator-{port}"))
            }
            "grpc.token" => {
                let value = value.trim();
                if !value.is_empty() {
                    token = Some(value.to_owned());
                }
            }
            _ => {}
        }
    }
    match (port, token) {
        (Some(port), Some(token)) => Ok(FeedEndpoint {
            port,
            token: FeedToken(token),
            serial,
        }),
        (None, _) => bail!("the emulator discovery file has no valid grpc.port"),
        (_, None) => bail!("the emulator discovery file has no grpc.token"),
    }
}

/// `<temp>\avd\running\pid_<pid>.ini` for each temp dir, in order.
pub fn discovery_paths(pid: u32, temp_dirs: &[PathBuf]) -> Vec<PathBuf> {
    temp_dirs
        .iter()
        .map(|dir| {
            dir.join("avd")
                .join("running")
                .join(format!("pid_{pid}.ini"))
        })
        .collect()
}

/// The emulator (qemu) process running the named AVD.
pub fn find_emulator_pid(processes: &[(u32, String, Vec<String>)], avd: &str) -> Option<u32> {
    processes
        .iter()
        .find(|(_, exe, cmd)| avd::launched_avd(exe, cmd).as_deref() == Some(avd))
        .map(|(pid, _, _)| *pid)
}

/// Finds the running AVD's gRPC endpoint on this PC.
pub fn discover(avd: &str) -> ResultType<FeedEndpoint> {
    let mut system = hbb_common::sysinfo::System::new();
    system.refresh_processes();
    let mut temp_dirs = Vec::new();
    let processes: Vec<(u32, String, Vec<String>)> = system
        .processes()
        .iter()
        .map(|(pid, process)| (pid.as_u32(), process.name().to_owned(), process.cmd().to_vec()))
        .collect();
    let Some(pid) = find_emulator_pid(&processes, avd) else {
        bail!("no emulator process for {avd}");
    };
    if let Some(process) = system.process(hbb_common::sysinfo::Pid::from_u32(pid)) {
        temp_dirs.extend(
            process
                .environ()
                .iter()
                .filter_map(|entry| entry.split_once('='))
                .filter(|(key, _)| key.eq_ignore_ascii_case("TEMP"))
                .map(|(_, value)| PathBuf::from(value)),
        );
    }
    if let Some(home) = crate::platform::get_active_user_home() {
        temp_dirs.push(home.join("AppData").join("Local").join("Temp"));
    }
    let Some(path) = discovery_paths(pid, &temp_dirs)
        .into_iter()
        .find(|path| path.is_file())
    else {
        bail!("no discovery file for the emulator of {avd}");
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|e| hbb_common::anyhow::anyhow!("cannot read the discovery file of {avd}: {e}"))?;
    parse_running_ini(&text).map_err(|e| {
        hbb_common::anyhow::anyhow!("bad discovery file for the emulator of {avd}: {e}")
    })
}

/// `ImageFormat { format: RGBA8888, width, height }`.
pub fn encode_image_format(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = Vec::new();
    {
        let mut out = CodedOutputStream::vec(&mut bytes);
        // Writes to a Vec cannot fail.
        let _ = out.write_enum(1, RGBA8888);
        let _ = out.write_uint32(3, width);
        let _ = out.write_uint32(4, height);
        let _ = out.flush();
    }
    bytes
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedImage {
    pub width: u32,
    pub height: u32,
    pub rotation: u32,
    pub seq: u32,
    pub pixels: Vec<u8>,
}

fn skip(input: &mut CodedInputStream, tag: u32) -> ResultType<()> {
    let Some(wire_type) = hbb_common::protobuf::rt::WireType::new(tag & 7) else {
        bail!("bad protobuf wire type in the screen feed");
    };
    input.skip_field(wire_type)?;
    Ok(())
}

fn decode_rotation(bytes: &[u8]) -> ResultType<u32> {
    let mut input = CodedInputStream::from_bytes(bytes);
    let mut rotation = 0;
    while let Some(tag) = input.read_raw_tag_or_eof()? {
        match tag {
            8 => rotation = input.read_uint32()?,
            _ => skip(&mut input, tag)?,
        }
    }
    Ok(rotation)
}

/// (width, height, rotation); missing fields are 0.
fn decode_format(bytes: &[u8]) -> ResultType<(u32, u32, u32)> {
    let mut input = CodedInputStream::from_bytes(bytes);
    let (mut width, mut height, mut rotation) = (0, 0, 0);
    while let Some(tag) = input.read_raw_tag_or_eof()? {
        match tag {
            18 => rotation = decode_rotation(&input.read_bytes()?)?,
            24 => width = input.read_uint32()?,
            32 => height = input.read_uint32()?,
            _ => skip(&mut input, tag)?,
        }
    }
    Ok((width, height, rotation))
}

/// Decodes the emulator's `Image` message, skipping fields it does not need.
pub fn decode_image(bytes: &[u8]) -> ResultType<FeedImage> {
    let mut input = CodedInputStream::from_bytes(bytes);
    let mut image = FeedImage {
        width: 0,
        height: 0,
        rotation: 0,
        seq: 0,
        pixels: Vec::new(),
    };
    while let Some(tag) = input.read_raw_tag_or_eof()? {
        match tag {
            10 => {
                let (width, height, rotation) = decode_format(&input.read_bytes()?)?;
                image.width = width;
                image.height = height;
                image.rotation = rotation;
            }
            34 => image.pixels = input.read_bytes()?,
            40 => image.seq = input.read_uint32()?,
            _ => skip(&mut input, tag)?,
        }
    }
    Ok(image)
}

/// One uncompressed gRPC message: flag 0 and a big-endian u32 length.
pub fn grpc_frame(message: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(message.len() + 5);
    frame.push(0);
    frame.extend_from_slice(&(message.len() as u32).to_be_bytes());
    frame.extend_from_slice(message);
    frame
}

/// Reassembles gRPC messages from arbitrarily chunked bytes.
#[derive(Default)]
pub struct GrpcDeframer {
    buffer: Vec<u8>,
}

impl GrpcDeframer {
    pub fn push(&mut self, bytes: &[u8]) -> ResultType<Vec<Vec<u8>>> {
        self.buffer.extend_from_slice(bytes);
        let mut messages = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 5 {
            let head = &self.buffer[start..start + 5];
            if head[0] != 0 {
                bail!("compressed gRPC messages are not supported");
            }
            let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
            if len > MAX_MESSAGE_BYTES {
                bail!("gRPC message of {len} bytes is too large");
            }
            if self.buffer.len() - start - 5 < len {
                break;
            }
            messages.push(self.buffer[start + 5..start + 5 + len].to_vec());
            start += 5 + len;
        }
        self.buffer.drain(..start);
        Ok(messages)
    }
}

const STREAM_PATH: &str = "/android.emulation.control.EmulatorController/streamScreenshot";
const WINDOW_BYTES: u32 = 32 * 1024 * 1024;
const FRAME_BYTES: u32 = 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

fn grpc_code_name(code: i32) -> &'static str {
    match code {
        1 => "CANCELLED",
        2 => "UNKNOWN",
        3 => "INVALID_ARGUMENT",
        5 => "NOT_FOUND",
        7 => "PERMISSION_DENIED",
        8 => "RESOURCE_EXHAUSTED",
        12 => "UNIMPLEMENTED",
        13 => "INTERNAL",
        14 => "UNAVAILABLE",
        16 => "UNAUTHENTICATED",
        _ => "ERROR",
    }
}

/// An error for a non-zero `grpc-status` in `headers` (response headers or
/// trailers); `None` when there is no status or it is 0. Only the status and
/// message are used, never other header values.
fn grpc_status_error(headers: &http::HeaderMap) -> Option<hbb_common::anyhow::Error> {
    let code: i32 = headers
        .get("grpc-status")?
        .to_str()
        .ok()?
        .trim()
        .parse()
        .ok()?;
    if code == 0 {
        return None;
    }
    let message = headers
        .get("grpc-message")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .chars()
        .take(200)
        .collect::<String>();
    Some(hbb_common::anyhow::anyhow!(
        "the screen feed failed: gRPC status {code} ({}) {message}",
        grpc_code_name(code)
    ))
}

/// Validates the decoded image and hands it to the consumer. Latest-wins: if
/// the consumer has not taken the previous image yet, this newer one is
/// dropped. Returns false once the consumer is gone.
fn deliver(tx: &mpsc::SyncSender<ResultType<FeedImage>>, message: &[u8]) -> ResultType<bool> {
    let image = decode_image(message)?;
    let expected = (image.width as usize)
        .checked_mul(image.height as usize)
        .and_then(|pixels| pixels.checked_mul(4));
    if image.width == 0 || image.height == 0 || expected != Some(image.pixels.len()) {
        bail!(
            "the screen feed sent a {}x{} image with {} pixel bytes",
            image.width,
            image.height,
            image.pixels.len()
        );
    }
    match tx.try_send(Ok(image)) {
        Ok(()) | Err(TrySendError::Full(_)) => Ok(true),
        Err(TrySendError::Disconnected(_)) => Ok(false),
    }
}

async fn stream_images(
    endpoint: FeedEndpoint,
    width: u32,
    height: u32,
    tx: &mpsc::SyncSender<ResultType<FeedImage>>,
) -> ResultType<()> {
    let tcp = tokio::time::timeout(
        CONNECT_TIMEOUT,
        tokio::net::TcpStream::connect(("127.0.0.1", endpoint.port)),
    )
    .await
    .map_err(|_| hbb_common::anyhow::anyhow!("timed out connecting to the emulator screen feed"))?
    .map_err(|e| hbb_common::anyhow::anyhow!("cannot connect to the emulator screen feed: {e}"))?;
    let _ = tcp.set_nodelay(true);
    let (sender, connection) = h2::client::Builder::new()
        .initial_window_size(WINDOW_BYTES)
        .initial_connection_window_size(WINDOW_BYTES)
        .max_frame_size(FRAME_BYTES)
        .handshake::<_, hbb_common::bytes::Bytes>(tcp)
        .await?;
    let driver = tokio::spawn(connection);
    let result = async {
        let mut auth = http::HeaderValue::from_str(&endpoint.token.bearer())
            .map_err(|_| hbb_common::anyhow::anyhow!("the emulator gRPC token is not valid"))?;
        auth.set_sensitive(true);
        let request = http::Request::builder()
            .method("POST")
            .uri(format!("http://127.0.0.1:{}{STREAM_PATH}", endpoint.port))
            .header("content-type", "application/grpc")
            .header("te", "trailers")
            .header("authorization", auth)
            .body(())?;
        let mut sender = sender.ready().await?;
        let (response, mut send_body) = sender.send_request(request, false)?;
        send_body.send_data(
            hbb_common::bytes::Bytes::from(grpc_frame(&encode_image_format(width, height))),
            true,
        )?;
        let response = response.await?;
        if let Some(error) = grpc_status_error(response.headers()) {
            return Err(error);
        }
        if response.status() != http::StatusCode::OK {
            bail!("the screen feed answered HTTP {}", response.status().as_u16());
        }
        let mut body = response.into_body();
        let mut deframer = GrpcDeframer::default();
        while let Some(chunk) = body.data().await {
            let chunk = chunk?;
            let _ = body.flow_control().release_capacity(chunk.len());
            for message in deframer.push(&chunk)? {
                if !deliver(tx, &message)? {
                    return Ok(());
                }
            }
        }
        if let Some(error) = body.trailers().await?.as_ref().and_then(grpc_status_error) {
            return Err(error);
        }
        bail!("the screen feed ended")
    }
    .await;
    driver.abort();
    result
}

/// A running AVD screen feed. Dropping it cancels the stream and joins its
/// thread.
pub struct ScreenFeed {
    cancelled: Arc<AtomicBool>,
    cancel: Arc<Notify>,
    thread: Option<JoinHandle<()>>,
}

impl ScreenFeed {
    /// Starts streaming `width`x`height` RGBA frames. Returns promptly; a
    /// connect or auth failure arrives as the first `Err` on the channel. The
    /// channel holds one image: while the consumer is behind, newer images are
    /// dropped. An `Err` is always delivered and is the last item.
    pub fn start(
        endpoint: FeedEndpoint,
        width: u32,
        height: u32,
    ) -> ResultType<(ScreenFeed, mpsc::Receiver<ResultType<FeedImage>>)> {
        let (tx, rx) = mpsc::sync_channel(1);
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = Arc::new(Notify::new());
        let thread = {
            let cancelled = cancelled.clone();
            let cancel = cancel.clone();
            std::thread::Builder::new()
                .name("emulator-feed".to_owned())
                .spawn(move || {
                    let error = match tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                    {
                        Ok(runtime) => runtime.block_on(async {
                            tokio::select! {
                                _ = cancel.notified() => None,
                                result = stream_images(endpoint, width, height, &tx) => {
                                    result.err()
                                }
                            }
                        }),
                        Err(e) => Some(hbb_common::anyhow::anyhow!(
                            "cannot start the screen feed runtime: {e}"
                        )),
                    };
                    let Some(error) = error else { return };
                    // Unlike images, the terminal error is never dropped.
                    let mut item = Err(error);
                    while !cancelled.load(Ordering::Relaxed) {
                        match tx.try_send(item) {
                            Err(TrySendError::Full(back)) => {
                                item = back;
                                std::thread::sleep(Duration::from_millis(5));
                            }
                            Ok(()) | Err(TrySendError::Disconnected(_)) => break,
                        }
                    }
                })?
        };
        Ok((
            ScreenFeed {
                cancelled,
                cancel,
                thread: Some(thread),
            },
            rx,
        ))
    }
}

impl Drop for ScreenFeed {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Relaxed);
        self.cancel.notify_one();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

const STATUS_PATH: &str = "/android.emulation.control.EmulatorController/getStatus";
/// The controller answers from the emulator process, not from Android, so it
/// stays quick while Android or its ADB transport is stuck.
const STATUS_TIMEOUT: Duration = Duration::from_secs(3);

/// What the emulator's controller says about Android (`EmulatorStatus`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuestStatus {
    pub booted: bool,
    pub uptime_ms: u64,
    pub heartbeat: u64,
}

/// Decodes `EmulatorStatus`, skipping the fields it does not need.
pub fn decode_status(bytes: &[u8]) -> ResultType<GuestStatus> {
    let mut input = CodedInputStream::from_bytes(bytes);
    let mut status = GuestStatus::default();
    while let Some(tag) = input.read_raw_tag_or_eof()? {
        match tag {
            16 => status.uptime_ms = input.read_uint64()?,
            24 => status.booted = input.read_bool()?,
            48 => status.heartbeat = input.read_uint64()?,
            _ => skip(&mut input, tag)?,
        }
    }
    Ok(status)
}

async fn request_status(endpoint: &FeedEndpoint) -> ResultType<GuestStatus> {
    let tcp = tokio::net::TcpStream::connect(("127.0.0.1", endpoint.port))
        .await
        .map_err(|e| hbb_common::anyhow::anyhow!("cannot connect to the emulator controller: {e}"))?;
    let _ = tcp.set_nodelay(true);
    let (sender, connection) =
        h2::client::Builder::new().handshake::<_, hbb_common::bytes::Bytes>(tcp).await?;
    let driver = tokio::spawn(connection);
    let result = async {
        let mut auth = http::HeaderValue::from_str(&endpoint.token.bearer())
            .map_err(|_| hbb_common::anyhow::anyhow!("the emulator gRPC token is not valid"))?;
        auth.set_sensitive(true);
        let request = http::Request::builder()
            .method("POST")
            .uri(format!("http://127.0.0.1:{}{STATUS_PATH}", endpoint.port))
            .header("content-type", "application/grpc")
            .header("te", "trailers")
            .header("authorization", auth)
            .body(())?;
        let mut sender = sender.ready().await?;
        let (response, mut send_body) = sender.send_request(request, false)?;
        send_body.send_data(hbb_common::bytes::Bytes::from(grpc_frame(&[])), true)?;
        let response = response.await?;
        if let Some(error) = grpc_status_error(response.headers()) {
            return Err(error);
        }
        if response.status() != http::StatusCode::OK {
            bail!("the emulator controller answered HTTP {}", response.status().as_u16());
        }
        let mut body = response.into_body();
        let mut deframer = GrpcDeframer::default();
        while let Some(chunk) = body.data().await {
            let chunk = chunk?;
            let _ = body.flow_control().release_capacity(chunk.len());
            if let Some(message) = deframer.push(&chunk)?.first() {
                return decode_status(message);
            }
        }
        if let Some(error) = body.trailers().await?.as_ref().and_then(grpc_status_error) {
            return Err(error);
        }
        bail!("the emulator controller sent no status")
    }
    .await;
    driver.abort();
    result
}

/// Asks the emulator's controller for Android's state, within
/// `STATUS_TIMEOUT`. Blocking: runs its own runtime on a scoped thread, so it
/// never nests in a caller's runtime.
pub fn guest_status(endpoint: &FeedEndpoint) -> ResultType<GuestStatus> {
    std::thread::scope(|scope| {
        scope
            .spawn(|| -> ResultType<GuestStatus> {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()?;
                runtime.block_on(async {
                    tokio::time::timeout(STATUS_TIMEOUT, request_status(endpoint))
                        .await
                        .map_err(|_| {
                            hbb_common::anyhow::anyhow!(
                                "the emulator controller did not answer within {} s",
                                STATUS_TIMEOUT.as_secs()
                            )
                        })?
                })
            })
            .join()
            .unwrap_or_else(|_| bail!("the emulator status check panicked"))
    })
}

/// Whether an AVD can be opened, by its emulator controller rather than ADB.
#[derive(Debug, PartialEq, Eq)]
pub enum Readiness {
    /// Android has booted: its ADB serial.
    Ready(String),
    /// The emulator runs and Android is still booting.
    Booting,
    /// The controller cannot tell (no discovery file, no serial, no answer).
    Unknown(String),
}

fn readiness_of(serial: Option<String>, status: ResultType<GuestStatus>) -> Readiness {
    match (serial, status) {
        (_, Err(error)) => Readiness::Unknown(error.to_string()),
        (Some(serial), Ok(status)) if status.booted => Readiness::Ready(serial),
        (None, Ok(status)) if status.booted => {
            Readiness::Unknown("the discovery file names no ADB serial".to_owned())
        }
        (_, Ok(_)) => Readiness::Booting,
    }
}

/// The running AVD's readiness from its emulator controller.
pub fn readiness(endpoint: &FeedEndpoint) -> Readiness {
    readiness_of(endpoint.serial.clone(), guest_status(endpoint))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_port_and_token() {
        let endpoint = parse_running_ini("grpc.port=8554\ngrpc.token=abc\n").unwrap();
        assert_eq!(endpoint.port, 8554);
        assert_eq!(endpoint.token.bearer(), "Bearer abc");
        assert!(!format!("{:?}", endpoint).contains("abc"));
    }

    #[test]
    fn the_discovery_file_names_the_guest_serial() {
        let text = "port.serial=5554\nport.adb=5555\ngrpc.port=8554\ngrpc.token=abc\n";
        let endpoint = parse_running_ini(text).unwrap();
        assert_eq!(endpoint.serial.as_deref(), Some("emulator-5554"));
        // Not an emulator console port: no serial, the endpoint still works.
        let odd = parse_running_ini("port.serial=5555\ngrpc.port=8554\ngrpc.token=abc\n").unwrap();
        assert_eq!(odd.serial, None);
        assert_eq!(parse_running_ini("grpc.port=8554\ngrpc.token=abc\n").unwrap().serial, None);
    }

    #[test]
    fn decodes_the_emulator_status() {
        // version "37", uptime 70000, booted, vmConfig {hypervisor 2}, heartbeat 42.
        let bytes = [
            0x0a, 0x02, b'3', b'7', 0x10, 0xf0, 0xa2, 0x04, 0x18, 0x01, 0x22, 0x02, 0x08, 0x02,
            0x30, 0x2a,
        ];
        assert_eq!(
            decode_status(&bytes).unwrap(),
            GuestStatus {
                booted: true,
                uptime_ms: 70_000,
                heartbeat: 42,
            }
        );
        assert_eq!(decode_status(&[]).unwrap(), GuestStatus::default());
    }

    #[test]
    fn readiness_needs_a_booted_guest_with_a_serial() {
        let booted = GuestStatus {
            booted: true,
            ..Default::default()
        };
        assert_eq!(
            readiness_of(Some("emulator-5554".to_owned()), Ok(booted)),
            Readiness::Ready("emulator-5554".to_owned())
        );
        assert_eq!(
            readiness_of(Some("emulator-5554".to_owned()), Ok(GuestStatus::default())),
            Readiness::Booting
        );
        assert!(matches!(readiness_of(None, Ok(booted)), Readiness::Unknown(_)));
        assert!(matches!(
            readiness_of(Some("emulator-5554".to_owned()), Err(hbb_common::anyhow::anyhow!("x"))),
            Readiness::Unknown(_)
        ));
    }

    #[test]
    fn missing_token_is_an_error_without_secrets() {
        let error = parse_running_ini("grpc.port=8554\n").unwrap_err();
        assert!(error.to_string().contains("grpc.token"));
        let error = parse_running_ini("grpc.port=0\ngrpc.token=sekrit\n").unwrap_err();
        assert!(!error.to_string().contains("sekrit"));
    }

    #[test]
    fn discovery_rejects_other_pid_files() {
        let dir = PathBuf::from("T");
        assert_eq!(
            discovery_paths(42, &[dir.clone()]),
            vec![dir.join("avd").join("running").join("pid_42.ini")]
        );
    }

    #[test]
    fn finds_the_qemu_pid_for_an_avd() {
        let args = vec!["-avd".to_owned(), "Maple_1".to_owned()];
        let processes = vec![
            (7, "emulator.exe".to_owned(), args.clone()),
            (9, "qemu-system-x86_64.exe".to_owned(), args),
        ];
        assert_eq!(find_emulator_pid(&processes, "Maple_1"), Some(9));
        assert_eq!(find_emulator_pid(&processes, "Other"), None);
    }

    #[test]
    fn image_format_round_trips_known_bytes() {
        assert_eq!(
            encode_image_format(1280, 1280),
            [0x08, 0x01, 0x18, 0x80, 0x0a, 0x20, 0x80, 0x0a]
        );
    }

    #[test]
    fn decodes_image_fields_and_skips_unknown() {
        let mut bytes = vec![0x0a, 0x08, 0x18, 0x04, 0x20, 0x02, 0x12, 0x02, 0x08, 0x01];
        bytes.extend_from_slice(&[0x22, 32]);
        bytes.extend(1..=32u8);
        bytes.extend_from_slice(&[0x28, 0x03, 0x30, 99]);
        let image = decode_image(&bytes).unwrap();
        assert_eq!(
            image,
            FeedImage {
                width: 4,
                height: 2,
                rotation: 1,
                seq: 3,
                pixels: (1..=32u8).collect(),
            }
        );
    }

    #[test]
    fn deframer_splits_across_chunks() {
        let mut stream = grpc_frame(b"hello");
        stream.extend(grpc_frame(b"world!"));
        let mut deframer = GrpcDeframer::default();
        let mut got = Vec::new();
        for chunk in [&stream[..3], &stream[3..11], &stream[11..]] {
            got.extend(deframer.push(chunk).unwrap());
        }
        assert_eq!(got, vec![b"hello".to_vec(), b"world!".to_vec()]);
        assert!(GrpcDeframer::default()
            .push(&[1, 0, 0, 0, 1, 0])
            .is_err());
    }

    const TRIAL_AVD: &str = "Aperture_Trial_Play35";

    fn adb_path() -> PathBuf {
        PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_default())
            .join("Android")
            .join("Sdk")
            .join("platform-tools")
            .join("adb.exe")
    }

    fn adb(args: &[&str]) -> String {
        let out = std::process::Command::new(adb_path()).args(args).output().unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn trial_serial() -> String {
        let devices = adb(&["devices"]);
        for line in devices.lines().skip(1) {
            let serial = line.split_whitespace().next().unwrap_or("");
            if !serial.starts_with("emulator-") {
                continue;
            }
            if adb(&["-s", serial, "emu", "avd", "name"])
                .lines()
                .next()
                .map(str::trim)
                == Some(TRIAL_AVD)
            {
                return serial.to_owned();
            }
        }
        panic!("{TRIAL_AVD} is not running");
    }

    #[test]
    #[ignore = "needs the running Aperture_Trial_Play35 emulator"]
    fn real_feed_streams_moving_screen_near_sixty_fps() {
        let serial = trial_serial();
        let endpoint = discover(TRIAL_AVD).unwrap();
        let (feed, rx) = ScreenFeed::start(endpoint, 1280, 1280).unwrap();
        // One bounded on-device loop: no adb round trips between swipes, so the
        // screen keeps moving for the whole measurement.
        adb(&["-s", &serial, "shell", "input", "keyevent", "KEYCODE_HOME"]);
        let swiper = {
            let serial = serial.clone();
            std::thread::spawn(move || {
                adb(&[
                    "-s",
                    &serial,
                    "shell",
                    "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do input swipe 800 1500 100 1500 250; input swipe 100 1500 800 1500 250; done",
                ]);
            })
        };
        let begin = std::time::Instant::now();
        let mut count = 0usize;
        while begin.elapsed() < std::time::Duration::from_secs(8) {
            match rx.recv_timeout(std::time::Duration::from_secs(2)) {
                Ok(Ok(image)) => {
                    assert_eq!(image.width.max(image.height), 1280);
                    assert_eq!(image.pixels.len(), (image.width * image.height * 4) as usize);
                    count += 1;
                }
                Ok(Err(e)) => panic!("feed error: {e}"),
                Err(e) => panic!("no image: {e}"),
            }
        }
        let secs = begin.elapsed().as_secs_f64();
        let _ = swiper.join();
        let dropped = std::time::Instant::now();
        drop(feed);
        assert!(dropped.elapsed() < std::time::Duration::from_secs(2));
        println!("feed fps: {:.1} ({count} images in {secs:.1}s)", count as f64 / secs);
        assert!(count >= 400, "only {count} images");
    }

    /// The raw feed alone (no session, watcher or helper) under the same
    /// moving screen as the host soak: APERTURE_SOAK_MINUTES (30),
    /// APERTURE_SOAK_SAMPLE_SECS (300).
    #[test]
    #[ignore = "reads the running Aperture_Trial_Play35 emulator's feed for 30 minutes"]
    fn soak_raw_feed() {
        use std::time::{Duration, Instant};
        let read = |key: &str, default: u64| {
            std::env::var(key)
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(default)
        };
        let length = Duration::from_secs(read("APERTURE_SOAK_MINUTES", 30) * 60);
        let every = Duration::from_secs(read("APERTURE_SOAK_SAMPLE_SECS", 300));
        let serial = trial_serial();
        let stats = |serial: &str| {
            adb(&[
                "-s",
                serial,
                "shell",
                "echo \"avail=$(grep MemAvailable /proc/meminfo | tr -s ' ' | cut -d' ' -f2)kB procs=$(ps -A | wc -l) watch_loops=$(ps -A -o ARGS | grep -c '[m]CurrentOrientation') helpers=$(ps -A -o ARGS | grep -c '[c]om.genymobile.scrcpy') load=$(cut -d' ' -f1-3 /proc/loadavg)\"",
            ])
            .trim()
            .to_owned()
        };
        for package in ["com.android.settings", "com.google.android.settings.intelligence"] {
            adb(&["-s", &serial, "shell", "am", "force-stop", package]);
        }
        adb(&["-s", &serial, "shell", "am", "start", "-f", "0x10008000", "-a", "android.settings.SETTINGS"]);
        std::thread::sleep(Duration::from_secs(3));
        let (feed, rx) = ScreenFeed::start(discover(TRIAL_AVD).unwrap(), 1280, 1280).unwrap();
        let swiper = {
            let serial = serial.clone();
            let secs = length.as_secs() + 30;
            std::thread::spawn(move || {
                adb(&[
                    "-s",
                    &serial,
                    "shell",
                    &format!("end=$(( $(date +%s) + {secs} )); while [ $(date +%s) -lt $end ]; do input swipe 540 1700 540 900 400; input swipe 540 900 540 1700 400; done"),
                ]);
            })
        };
        let started = Instant::now();
        let mut times: std::collections::VecDeque<Instant> = Default::default();
        let mut next_sample = started + Duration::from_secs(30);
        while started.elapsed() < length + Duration::from_secs(31) {
            match rx.recv_timeout(Duration::from_millis(50)) {
                Ok(Ok(_)) => times.push_back(Instant::now()),
                Ok(Err(e)) => panic!("feed error: {e}"),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(e) => panic!("feed stopped: {e}"),
            }
            while times.front().is_some_and(|time| time.elapsed() > Duration::from_secs(60)) {
                times.pop_front();
            }
            if Instant::now() >= next_sample {
                next_sample += every;
                let last_5s = times
                    .iter()
                    .filter(|time| time.elapsed() <= Duration::from_secs(5))
                    .count();
                eprintln!(
                    "SOAK feed t={:>4}s images/5s={last_5s} (minute avg {:.0}) guest[{}]",
                    started.elapsed().as_secs(),
                    times.len() as f64 / 12.0,
                    stats(&serial)
                );
            }
        }
        drop(feed);
        let _ = swiper.join();
        eprintln!("SOAK feed end guest[{}]", stats(&serial));
    }

    #[test]
    #[ignore = "needs the running Aperture_Trial_Play35 emulator"]
    fn real_controller_reports_the_booted_guest_without_adb() {
        let serial = trial_serial();
        let endpoint = discover(TRIAL_AVD).unwrap();
        for _ in 0..5 {
            let asked = std::time::Instant::now();
            let readiness = readiness(&endpoint);
            let took = asked.elapsed();
            println!("RESULT readiness {readiness:?} in {took:?}");
            assert_eq!(readiness, Readiness::Ready(serial.clone()));
            assert!(took < std::time::Duration::from_secs(1), "{took:?}");
        }
        assert!(discover("Aperture_No_Such_Avd").is_err());
    }

    #[test]
    #[ignore = "needs the running Aperture_Trial_Play35 emulator"]
    fn unauthenticated_feed_is_an_error() {
        let real = discover(TRIAL_AVD).unwrap();
        let wrong = FeedEndpoint {
            port: real.port,
            token: FeedToken("wrong".to_owned()),
            serial: None,
        };
        let (_feed, rx) = ScreenFeed::start(wrong, 1280, 1280).unwrap();
        let first = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
        let error = first.unwrap_err().to_string();
        assert!(error.contains("UNAUTHENTICATED") || error.contains("16"), "{error}");
    }
}
