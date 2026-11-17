use super::{
    avd::AvdProvider,
    bluestacks::BlueStacksProvider,
    guest_protocol::{text_packet, touch_packet, H264Frames, VideoPacket},
    guest_runtime::{
        adb_command, helper_path, is_default_adb_server, GuestHelper, SCRCPY_CONTROL_RESET_VIDEO,
    },
    ldplayer::LdPlayerProvider,
    remote::{GuestEvent, PROTOCOL_VERSION},
    EmulatorProvider, EmulatorState, EmulatorTarget,
};
use base::message_proto::{
    emulator_request, EmulatorInstance, EmulatorInventory, EmulatorNavigation, EmulatorRequest,
    EmulatorResponse, EmulatorSessionState, EmulatorSessionStatus, EmulatorVideoFrame,
};
use hbb_common::{bail, log, ResultType};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Write,
    net::{Shutdown, TcpStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

#[path = "avd_host_video.rs"]
mod avd_host_video;

const GUEST_INPUT_QUEUE_SIZE: usize = 256;
const GUEST_INPUT_MOVE_SHED_THRESHOLD: usize = 24;

struct LocalTarget {
    provider: Arc<dyn EmulatorProvider>,
    target: EmulatorTarget,
}

fn targets() -> (Vec<LocalTarget>, Vec<String>) {
    let mut found = Vec::new();
    let mut errors = Vec::new();
    let providers: [(&str, ResultType<Option<Arc<dyn EmulatorProvider>>>); 3] = [
        (
            "BlueStacks",
            BlueStacksProvider::detect().map(|provider| {
                provider.map(|provider| Arc::new(provider) as Arc<dyn EmulatorProvider>)
            }),
        ),
        (
            "LDPlayer",
            LdPlayerProvider::detect().map(|provider| {
                provider.map(|provider| Arc::new(provider) as Arc<dyn EmulatorProvider>)
            }),
        ),
        (
            "Android Emulator",
            AvdProvider::detect().map(|provider| {
                provider.map(|provider| Arc::new(provider) as Arc<dyn EmulatorProvider>)
            }),
        ),
    ];
    for (name, provider) in providers {
        match provider {
            Ok(Some(provider)) => match provider.discover() {
                Ok(instances) => found.extend(instances.into_iter().map(|target| LocalTarget {
                    provider: provider.clone(),
                    target,
                })),
                Err(error) => errors.push(format!("{name}: {error}")),
            },
            Ok(None) => {}
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }
    (found, errors)
}

pub fn inventory(
    request_id: u64,
    operation_session_identity: &str,
    operation_generation: u64,
) -> EmulatorResponse {
    let (targets, provider_errors) = targets();
    let instances = targets
        .into_iter()
        .map(|local| {
            let mut instance = EmulatorInstance {
            default_package: if local.target.provider.to_string() == "bluestacks" {
                super::bluestacks::default_app_for_instance(&local.target.provider_instance_id)
            } else {
                String::new()
            },
            target_id: local.target.stable_id,
            provider: local.target.provider.to_string(),
            name: local.target.display_name,
            state: format!("{:?}", local.target.state).to_lowercase(),
            android_version: local.target.android_version.unwrap_or_default(),
            last_error: local.target.last_error.unwrap_or_default(),
            ..Default::default()
            };
            if let Some(percent) = local.target.progress_percent {
                // An emulator still being copied: nothing but its progress.
                instance.state = "cloning".to_owned();
                instance.progress_percent = percent;
                instance.last_error.clear();
            } else if instance.provider == "avd"
                && !matches!(
                    local.target.state,
                    EmulatorState::Stopped | EmulatorState::Unknown
                )
            {
                instance.window_visible =
                    super::avd_launch_windows::window_visible(&local.target.provider_instance_id);
            }
            super::shutdown_windows::annotate(&mut instance);
            instance
        })
        .collect();
    let mut response = response(request_id);
    response.set_inventory(EmulatorInventory {
        instances,
        provider_errors,
        dashboard: true,
        capabilities: vec![
            "operation.identity.v1".to_owned(),
            "operation.ack.v1".to_owned(),
            "desktop.stream_liveness.v1".to_owned(),
            "guest.text.v1".to_owned(),
            "guest.video_refresh.v1".to_owned(),
            "host.status".to_owned(),
            "host.windows.list.v1".to_owned(),
            "host.window_focus.v1".to_owned(),
            "host.emulator_shutdown.v1".to_owned(),
            "host.avd_manage.v1".to_owned(),
            "host.process_end".to_owned(),
            "host.shell_restart.v1".to_owned(),
            "host.process_identity.v2".to_owned(),
            "host.recover.bluestacks_adb".to_owned(),
            "host.phone_workspace.v1".to_owned(),
            "host.gateway.status.v1".to_owned(),
            "host.gateway.setup.v1".to_owned(),
            "host.gateway.imdb.v1".to_owned(),
            "host.gateway.restart.v1".to_owned(),
        ],
        operation_session_identity: operation_session_identity.to_owned(),
        operation_generation,
        ..Default::default()
    });
    response
}

pub fn response(request_id: u64) -> EmulatorResponse {
    EmulatorResponse {
        request_id,
        protocol_version: PROTOCOL_VERSION,
        ..Default::default()
    }
}

pub fn error_response(request_id: u64, error: impl Into<String>) -> EmulatorResponse {
    let mut response = response(request_id);
    response.set_error(error.into());
    response
}

pub fn status_response(
    request_id: u64,
    session_id: u64,
    target_id: &str,
    state: EmulatorSessionState,
    width: u16,
    height: u16,
    error: String,
) -> EmulatorResponse {
    let mut response = response(request_id);
    response.set_status(EmulatorSessionStatus {
        session_id,
        target_id: target_id.to_owned(),
        state: state.into(),
        width: width as u32,
        height: height as u32,
        error,
        ..Default::default()
    });
    response
}

pub fn with_phase(mut response: EmulatorResponse, phase: &str) -> EmulatorResponse {
    if let Some(base::message_proto::emulator_response::Union::Status(status)) =
        response.union.as_mut()
    {
        status.phase = phase.to_owned();
    }
    response
}

fn has_live_preview(provider: &str) -> bool {
    matches!(provider, "bluestacks" | "avd")
}

/// Providers whose emulator-N serial could be BlueStacks' port alias.
fn may_be_bluestacks_alias(provider: &str) -> bool {
    provider != "bluestacks"
}

/// The adb.exe of the running default (port 5037) ADB server, if any.
pub(super) fn running_adb_server() -> Option<PathBuf> {
    // Processes only: new_all() also queries disks, networks and components.
    let mut system = hbb_common::sysinfo::System::new();
    system.refresh_processes();
    system
        .processes()
        .values()
        .find_map(|process| {
            (process.name().eq_ignore_ascii_case("adb.exe")
                && is_default_adb_server(process.cmd())
                && process.exe().is_file())
            .then(|| process.exe().to_path_buf())
        })
}

fn adb_executable() -> ResultType<PathBuf> {
    if let Some(adb) = running_adb_server() {
        return Ok(adb);
    }
    for root in [
        std::env::var_os("ANDROID_SDK_ROOT"),
        std::env::var_os("ANDROID_HOME"),
        std::env::var_os("LOCALAPPDATA")
            .map(|path| PathBuf::from(path).join("Android/Sdk").into_os_string()),
        // The SYSTEM service's own LOCALAPPDATA is not the signed-in user's.
        crate::platform::get_active_user_home()
            .map(|home| home.join(r"AppData\Local\Android\Sdk").into_os_string()),
    ]
    .into_iter()
    .flatten()
    {
        let adb = PathBuf::from(root).join("platform-tools/adb.exe");
        if adb.is_file() {
            return Ok(adb);
        }
    }
    bail!("A current Android platform-tools ADB installation is required for guest streaming")
}

pub struct GuestSession {
    pub id: u64,
    pub target_id: String,
    pub preview: bool,
    cancel: Arc<AtomicBool>,
    sockets: Arc<Mutex<Vec<TcpStream>>>,
    input: SyncSender<GuestInputCommand>,
    pending_requests: Arc<AtomicUsize>,
}

enum GuestInputCommand {
    Request(EmulatorRequest),
    ReleaseAll,
    ResetVideo,
}

/// How a `ResetVideo` request reaches the video encoder.
enum VideoReset {
    /// The helper encodes: send scrcpy's reset-video control message.
    Helper,
    /// The host encodes: raise the flag its video loop polls.
    Host(Arc<AtomicBool>),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct GuestGeometry {
    width: u16,
    height: u16,
    /// The space the helper injects touches in. The stream size on the
    /// helper path; the device display on the host path.
    touch_space: (u16, u16),
    generation: u64,
    ready: bool,
}

/// The device display size oriented like the stream (landscape when the
/// stream is), which is the space a control-only helper injects touches in.
fn display_touch_space(display: (u16, u16), stream: (u16, u16)) -> (u16, u16) {
    let (short, long) = (display.0.min(display.1), display.0.max(display.1));
    if stream.0 > stream.1 {
        (long, short)
    } else {
        (short, long)
    }
}

/// A stream coordinate scaled to the touch space (rounded, kept inside it).
fn scale_touch(value: u32, from: u16, to: u16) -> u32 {
    if from == to || from == 0 || to == 0 {
        return value;
    }
    let scaled = (u64::from(value) * u64::from(to) + u64::from(from) / 2) / u64::from(from);
    scaled.min(u64::from(to) - 1) as u32
}

#[derive(Default)]
struct GuestIdleRefresh {
    last_frame: Option<Instant>,
    requested: bool,
}

impl GuestIdleRefresh {
    fn note_frame(&mut self, now: Instant) {
        self.last_frame = Some(now);
        self.requested = false;
    }

    fn take_due(&mut self, now: Instant) -> bool {
        let due = self
            .last_frame
            .map(|last| now.saturating_duration_since(last) >= Duration::from_secs(2))
            .unwrap_or(false);
        if self.requested || !due {
            return false;
        }
        self.requested = true;
        true
    }
}

// A full connection channel must not stop reading the scrcpy socket: doing
// so buffers old frames in TCP and eventually makes the remote view jump ahead.
// After any dropped H.264 reference, wait for a new random-access frame.
#[derive(Default)]
struct GuestFrameBackpressure {
    waiting_key: bool,
    last_refresh: Option<Instant>,
}

impl GuestFrameBackpressure {
    fn deliver(
        &mut self,
        frame: EmulatorVideoFrame,
        events: &hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
        input: &SyncSender<GuestInputCommand>,
    ) -> ResultType<()> {
        if self.waiting_key && !frame.key {
            self.request_refresh(input);
            return Ok(());
        }
        let key = frame.key;
        match events.try_send(GuestEvent::Frame(frame)) {
            Ok(()) => {
                if key {
                    self.waiting_key = false;
                    self.last_refresh = None;
                }
            }
            Err(hbb_common::tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                self.waiting_key = true;
                hbb_common::throttled_log!(
                    Duration::from_secs(5),
                    warn,
                    "Guest video transport queue saturated; discard dependent frames and request a new keyframe"
                );
                self.request_refresh(input);
            }
            Err(hbb_common::tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                bail!("Guest event transport disconnected")
            }
        }
        Ok(())
    }

    fn request_refresh(&mut self, input: &SyncSender<GuestInputCommand>) {
        if self
            .last_refresh
            .is_some_and(|sent| sent.elapsed() < Duration::from_secs(1))
        {
            return;
        }
        if input.try_send(GuestInputCommand::ResetVideo).is_ok() {
            self.last_refresh = Some(Instant::now());
        }
    }
}

/// Delivers a session's encoded frames, for the helper and host paths alike:
/// idle-refresh and timing bookkeeping, `stream_ready` once per geometry,
/// then the shared backpressure.
struct FrameSender<'a> {
    request: &'a EmulatorRequest,
    id: u64,
    target_id: &'a str,
    events: &'a hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
    capture_input: &'a SyncSender<GuestInputCommand>,
    preview: bool,
    geometry: &'a Mutex<GuestGeometry>,
    idle: &'a Mutex<GuestIdleRefresh>,
    backpressure: GuestFrameBackpressure,
    timing: crate::frame_timing::TimingWindow,
    last_frame: Option<Instant>,
}

impl<'a> FrameSender<'a> {
    #[allow(clippy::too_many_arguments)]
    fn new(
        request: &'a EmulatorRequest,
        id: u64,
        target_id: &'a str,
        events: &'a hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
        capture_input: &'a SyncSender<GuestInputCommand>,
        preview: bool,
        geometry: &'a Mutex<GuestGeometry>,
        idle: &'a Mutex<GuestIdleRefresh>,
        timing_name: &'static str,
    ) -> Self {
        Self {
            request,
            id,
            target_id,
            events,
            capture_input,
            preview,
            geometry,
            idle,
            backpressure: GuestFrameBackpressure::default(),
            timing: crate::frame_timing::TimingWindow::new(
                timing_name,
                Duration::from_secs(5),
                Instant::now(),
            ),
            last_frame: None,
        }
    }

    /// The loading phase while a new geometry has no frame yet.
    fn send_waiting_screen(&self) -> ResultType<()> {
        self.events.blocking_send(GuestEvent::Response(with_phase(
            status_response(
                self.request.request_id,
                self.id,
                self.target_id,
                EmulatorSessionState::EmulatorStarting,
                0,
                0,
                String::new(),
            ),
            "waiting_screen",
        )))?;
        Ok(())
    }

    /// Delivers one encoded frame. True when it made the geometry ready
    /// (and `stream_ready` was sent).
    fn send(&mut self, data: Vec<u8>, key: bool, pts: i64) -> ResultType<bool> {
        let read_at = Instant::now();
        self.idle.lock().unwrap().note_frame(read_at);
        if !self.preview {
            if let Some(previous) = self.last_frame {
                self.timing
                    .sample("read_gap", crate::frame_timing::ms(read_at - previous));
            }
            self.last_frame = Some(read_at);
            self.timing.sample("kbytes", data.len() as f64 / 1024.0);
            if let Some(latency) = crate::frame_timing::HOST_TAPS.take_latency(read_at) {
                self.timing
                    .sample("tap_to_frame", crate::frame_timing::ms(latency));
            }
        }
        let ready_dimensions = {
            let mut current = self.geometry.lock().unwrap();
            let became_ready = !current.ready;
            current.ready = true;
            became_ready.then_some((current.width, current.height))
        };
        if let Some((width, height)) = ready_dimensions {
            self.events.blocking_send(GuestEvent::Response(with_preview(
                with_phase(
                    status_response(
                        self.request.request_id,
                        self.id,
                        self.target_id,
                        EmulatorSessionState::EmulatorStreaming,
                        width,
                        height,
                        String::new(),
                    ),
                    "stream_ready",
                ),
                self.preview,
            )))?;
        }
        self.backpressure.deliver(
            EmulatorVideoFrame {
                session_id: self.id,
                data: data.into(),
                key,
                pts,
                ..Default::default()
            },
            self.events,
            self.capture_input,
        )?;
        if !self.preview {
            self.timing
                .sample("deliver", crate::frame_timing::ms(read_at.elapsed()));
            if let Some(line) = self.timing.take_due(Instant::now()) {
                log::info!("{line}");
            }
        }
        Ok(ready_dimensions.is_some())
    }
}

impl GuestGeometry {
    fn ready(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            touch_space: (width, height),
            generation: 1,
            ready: true,
        }
    }

    fn begin_stream(&mut self, width: u16, height: u16) -> bool {
        let changed = self.generation == 0 || self.width != width || self.height != height;
        self.width = width;
        self.height = height;
        self.touch_space = (width, height);
        self.generation = self.generation.saturating_add(1).max(1);
        self.ready = false;
        changed
    }
}

impl GuestSession {
    pub fn start(
        request: EmulatorRequest,
        events: hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
    ) -> ResultType<Self> {
        Self::start_with_mode(request, events, false)
    }

    pub fn start_preview(
        request_id: u64,
        target_id: String,
        events: hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
    ) -> ResultType<Self> {
        let mut request = EmulatorRequest {
            request_id,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_select(base::message_proto::EmulatorSelectRequest {
            target_id,
            ..Default::default()
        });
        Self::start_with_mode(request, events, true)
    }

    fn start_with_mode(
        request: EmulatorRequest,
        events: hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
        preview: bool,
    ) -> ResultType<Self> {
        let Some(emulator_request::Union::Select(selection)) = request.union.as_ref() else {
            bail!("Expected emulator selection")
        };
        let target_id = selection.target_id.clone();
        let bytes = *uuid::Uuid::new_v4().as_bytes();
        let id = u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]) & 0x001fffffffffffff;
        if id == 0 {
            bail!("Could not allocate guest session identity")
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let sockets = Arc::new(Mutex::new(Vec::new()));
        let (input, receiver) = mpsc::sync_channel(GUEST_INPUT_QUEUE_SIZE);
        let capture_input = input.clone();
        let pending_requests = Arc::new(AtomicUsize::new(0));
        let session_pending = pending_requests.clone();
        let session = Self {
            id,
            target_id: target_id.clone(),
            preview,
            cancel: cancel.clone(),
            sockets: sockets.clone(),
            input,
            pending_requests: session_pending,
        };
        thread::Builder::new()
            .name("emulator-guest".to_owned())
            .spawn(move || {
                let result = run_session(
                    &request,
                    id,
                    &target_id,
                    &events,
                    &cancel,
                    &sockets,
                    receiver,
                    &capture_input,
                    &pending_requests,
                    preview,
                );
                if let Err(error) = result {
                    if !cancel.load(Ordering::Acquire) {
                        log::warn!("Guest session {id} failed: {error}");
                        let _ = events.blocking_send(GuestEvent::Response(with_preview(
                            status_response(
                                request.request_id,
                                id,
                                &target_id,
                                EmulatorSessionState::EmulatorFailed,
                                0,
                                0,
                                error.to_string(),
                            ),
                            preview,
                        )));
                    }
                }
            })?;
        Ok(session)
    }

    pub fn input(&self, request: EmulatorRequest) -> ResultType<()> {
        if self.preview {
            bail!("Preview streams cannot receive input")
        }
        if self.cancel.load(Ordering::Acquire) {
            bail!("Guest session is closed")
        }
        if sheds_under_load(&request, self.pending_requests.load(Ordering::Acquire)) {
            log::trace!("Shedding guest touch move under input load");
            return Ok(());
        }
        self.pending_requests.fetch_add(1, Ordering::AcqRel);
        self.input
            .try_send(GuestInputCommand::Request(request))
            .map_err(|_| {
                decrement_pending(&self.pending_requests);
                hbb_common::anyhow::anyhow!("Guest input is busy or disconnected")
            })
    }

    pub fn release_input(&self) -> ResultType<()> {
        if self.preview || self.cancel.load(Ordering::Acquire) {
            return Ok(());
        }
        self.input
            .try_send(GuestInputCommand::ReleaseAll)
            .map_err(|_| hbb_common::anyhow::anyhow!("Guest input is busy or disconnected"))
    }

    pub fn refresh_video(&self) -> ResultType<()> {
        if self.cancel.load(Ordering::Acquire) {
            bail!("Guest session is closed")
        }
        self.input
            .try_send(GuestInputCommand::ResetVideo)
            .map_err(|_| hbb_common::anyhow::anyhow!("Guest video reset is busy or disconnected"))
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
        for socket in self.sockets.lock().unwrap().drain(..) {
            if let Err(error) = socket.shutdown(Shutdown::Both) {
                log::trace!("Guest cancellation socket: {error}");
            }
        }
    }
}

impl Drop for GuestSession {
    fn drop(&mut self) {
        self.cancel();
    }
}

fn run_session(
    request: &EmulatorRequest,
    id: u64,
    target_id: &str,
    events: &hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
    cancel: &Arc<AtomicBool>,
    sockets: &Arc<Mutex<Vec<TcpStream>>>,
    input: mpsc::Receiver<GuestInputCommand>,
    capture_input: &SyncSender<GuestInputCommand>,
    pending_requests: &Arc<AtomicUsize>,
    preview: bool,
) -> ResultType<()> {
    let Some(emulator_request::Union::Select(selection)) = request.union.as_ref() else {
        bail!("Expected emulator selection")
    };
    let (targets, _) = targets();
    let local = targets
        .into_iter()
        .find(|target| target.target.stable_id == target_id)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Emulator instance no longer exists"))?;
    if preview
        && (!has_live_preview(&local.target.provider.to_string())
            || local.target.state == EmulatorState::Stopped)
    {
        bail!("Only running BlueStacks and Android Emulator instances have live previews")
    }
    if !local.provider.capabilities(&local.target).adb {
        bail!("Enable ADB debugging in this emulator instance's settings before connecting")
    }
    let adb = adb_executable()?;
    let helper = helper_path()?;
    let is_stopped = local.target.state == EmulatorState::Stopped;
    if is_stopped && !selection.start_if_stopped {
        bail!("Emulator instance is stopped")
    }
    let send_startup_phase = |phase: &str| -> ResultType<()> {
        if !preview {
            events.blocking_send(GuestEvent::Response(with_phase(
                status_response(
                    request.request_id,
                    id,
                    target_id,
                    EmulatorSessionState::EmulatorStarting,
                    0,
                    0,
                    String::new(),
                ),
                phase,
            )))?;
        }
        Ok(())
    };
    if is_stopped {
        send_startup_phase("boot_requested")?;
        local.provider.start(&local.target)?;
    }
    send_startup_phase("starting_android")?;
    let started = Instant::now();
    let serial = loop {
        if cancel.load(Ordering::Acquire) {
            return Ok(());
        }
        if let Ok(endpoint) = local.provider.resolve_adb(&local.target) {
            if endpoint.serial.starts_with("127.0.0.1:") {
                let _ = adb_command(&adb, &endpoint.serial, &["connect", &endpoint.serial]);
            }
            match adb_command(
                &adb,
                &endpoint.serial,
                &["shell", "getprop", "sys.boot_completed"],
            ) {
                Ok(value) if value.trim() == "1" => break endpoint.serial,
                Err(error) if error.to_string().contains("device offline") => {
                    // Reset only this stale transport, never the shared ADB server.
                    if let Err(error) = adb_command(&adb, &endpoint.serial, &["reconnect"]) {
                        hbb_common::throttled_log!(
                            Duration::from_secs(5),
                            warn,
                            "Guest ADB reconnect failed: {error}"
                        );
                    }
                }
                _ => {}
            }
        }
        if started.elapsed() > Duration::from_secs(90) {
            bail!("Android boot/ADB did not become ready within 90 seconds")
        }
        thread::sleep(Duration::from_millis(500));
    };
    send_startup_phase("waiting_screen")?;
    // Android's emulator-N aliases are port based and may belong to a different
    // provider when both runtimes are installed. Never inject into that guest.
    let bluestacks_marker = adb_command(
        &adb,
        &serial,
        &["shell", "getprop", "ro.bst.ime_listener_port"],
    )?;
    if may_be_bluestacks_alias(&local.target.provider.to_string())
        && !bluestacks_marker.trim().is_empty()
    {
        bail!("This emulator's ADB endpoint belongs to BlueStacks; resolve the ADB port conflict in the emulator settings")
    }
    if selection.launch_default_app && local.target.provider.to_string() == "bluestacks" {
        super::bluestacks::launch_default_app(&local.target.provider_instance_id)?;
    }
    if cancel.load(Ordering::Acquire) {
        return Ok(());
    }
    let input = if local.target.provider.to_string() == "avd" {
        let session = avd_host_video::HostSession {
            request,
            id,
            target_id,
            events,
            cancel,
            capture_input,
            pending_requests,
            preview,
            adb: &adb,
            serial: &serial,
            helper: &helper,
            avd: &local.target.provider_instance_id,
        };
        match avd_host_video::run(&session, input) {
            avd_host_video::HostAttempt::Finished(result) => return result,
            avd_host_video::HostAttempt::Fallback(input) => input,
        }
    } else {
        input
    };
    let mut helper = if preview {
        GuestHelper::connect_preview(&adb, &serial, &helper)?
    } else if local.target.provider.to_string() == "avd" {
        GuestHelper::connect_android_emulator(&adb, &serial, &helper)?
    } else {
        GuestHelper::connect(&adb, &serial, &helper)?
    };
    let control = helper.control_socket()?;
    let stop_socket = helper.cancellation_socket()?;
    {
        let mut owned = sockets.lock().unwrap();
        if cancel.load(Ordering::Acquire) {
            return Ok(());
        }
        owned.push(stop_socket);
    }
    let geometry = Arc::new(Mutex::new(GuestGeometry::default()));
    let input_geometry = geometry.clone();
    let input_stop_flag = Arc::new(AtomicBool::new(false));
    let input_cancel = input_stop_flag.clone();
    let input_pending = pending_requests.clone();
    let input_stop = helper.cancellation_socket()?;
    let writer = thread::Builder::new()
        .name("emulator-input".to_owned())
        .spawn(move || {
            if let Err(error) = input_loop(
                control,
                &input,
                &input_geometry,
                &input_cancel,
                &input_pending,
                &VideoReset::Helper,
            ) {
                log::warn!("Guest input stopped: {error}");
            }
            if let Err(error) = input_stop.shutdown(Shutdown::Both) {
                log::trace!("Guest input cancellation: {error}");
            }
        })?;
    let recovery_stop_flag = Arc::new(AtomicBool::new(false));
    let recovery_stop = recovery_stop_flag.clone();
    let recovery_timed_out = Arc::new(AtomicBool::new(false));
    let recovery_timeout = recovery_timed_out.clone();
    let recovery_geometry = geometry.clone();
    let recovery_socket = helper.cancellation_socket()?;
    let capture_idle = Arc::new(Mutex::new(GuestIdleRefresh::default()));
    let watchdog_idle = capture_idle.clone();
    let recovery_input = capture_input.clone();
    let recovery_watchdog = spawn_recovery_watchdog(
        recovery_geometry,
        watchdog_idle,
        recovery_input,
        recovery_stop,
        recovery_timeout,
        move || {
            if let Err(error) = recovery_socket.shutdown(Shutdown::Both) {
                log::trace!("Guest recovery watchdog shutdown: {error}");
            }
        },
    )?;
    let mut frames = H264Frames::default();
    let mut sender = FrameSender::new(
        request,
        id,
        target_id,
        events,
        capture_input,
        preview,
        &geometry,
        &capture_idle,
        "Guest video (host)",
    );
    let result = (|| -> ResultType<()> {
        loop {
            if cancel.load(Ordering::Acquire) {
                return Ok(());
            }
            let packet = helper.read_packet()?;
            if let VideoPacket::Session { width, height } = &packet {
                let changed = geometry.lock().unwrap().begin_stream(*width, *height);
                if !preview && changed {
                    sender.send_waiting_screen()?;
                }
            }
            if let Some(frame) = frames.accept(packet)? {
                sender.send(frame.data, frame.key, frame.pts_ms)?;
            }
        }
    })();
    recovery_stop_flag.store(true, Ordering::Release);
    if recovery_watchdog.join().is_err() {
        log::warn!("Guest recovery watchdog panicked");
    }
    input_stop_flag.store(true, Ordering::Release);
    if writer.join().is_err() {
        log::warn!("Guest input worker panicked");
    }
    drop(helper);
    if recovery_timed_out.load(Ordering::Acquire) {
        bail!("Guest screen did not produce a current frame within 10 seconds")
    }
    result
}

/// Fails a stream whose new geometry has no current frame within 10 s
/// (`on_timeout` unblocks the video reader), and asks for a fresh frame once
/// the screen has been still for 2 s.
fn spawn_recovery_watchdog(
    geometry: Arc<Mutex<GuestGeometry>>,
    idle: Arc<Mutex<GuestIdleRefresh>>,
    input: SyncSender<GuestInputCommand>,
    stop: Arc<AtomicBool>,
    timed_out: Arc<AtomicBool>,
    on_timeout: impl FnOnce() + Send + 'static,
) -> std::io::Result<thread::JoinHandle<()>> {
    thread::Builder::new()
        .name("emulator-recovery-watchdog".to_owned())
        .spawn(move || {
            let mut observed_generation = 0;
            let mut waiting_since = None;
            while !stop.load(Ordering::Acquire) {
                let current = *geometry.lock().unwrap();
                if current.generation != observed_generation {
                    observed_generation = current.generation;
                    waiting_since = (current.generation != 0 && !current.ready).then(Instant::now);
                } else if current.ready {
                    waiting_since = None;
                }
                if waiting_since
                    .map(|started| started.elapsed() >= Duration::from_secs(10))
                    .unwrap_or(false)
                {
                    timed_out.store(true, Ordering::Release);
                    on_timeout();
                    break;
                }
                // Some emulator encoders stop repeating frames on a static screen.
                // Probe once; only an actual new capture can rearm the probe.
                if idle.lock().unwrap().take_due(Instant::now()) {
                    if let Err(error) = input.try_send(GuestInputCommand::ResetVideo) {
                        log::trace!("Idle guest refresh unavailable: {error}");
                    }
                }
                thread::sleep(Duration::from_millis(100));
            }
        })
}

pub fn with_preview(mut response: EmulatorResponse, preview: bool) -> EmulatorResponse {
    if let Some(base::message_proto::emulator_response::Union::Status(status)) =
        response.union.as_mut()
    {
        status.preview = preview;
    }
    response
}

fn sheds_under_load(request: &EmulatorRequest, pending: usize) -> bool {
    pending >= GUEST_INPUT_MOVE_SHED_THRESHOLD
        && matches!(
            request.union.as_ref(),
            Some(emulator_request::Union::Touch(touch)) if touch.action == 2
        )
}

fn decrement_pending(pending: &AtomicUsize) {
    let _ = pending.fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
        Some(count.saturating_sub(1))
    });
}

fn input_loop(
    mut socket: TcpStream,
    receiver: &mpsc::Receiver<GuestInputCommand>,
    geometry: &Mutex<GuestGeometry>,
    cancel: &AtomicBool,
    pending_requests: &AtomicUsize,
    reset: &VideoReset,
) -> ResultType<()> {
    let mut touches = BTreeMap::new();
    let mut keys = BTreeSet::new();
    let mut observed_generation = 0;
    let result = (|| -> ResultType<()> {
        loop {
            if cancel.load(Ordering::Acquire) {
                break;
            }
            let command = match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(command) => Some(command),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            if matches!(command, Some(GuestInputCommand::Request(_))) {
                decrement_pending(pending_requests);
            }
            let current = *geometry.lock().unwrap();
            if current.generation != observed_generation {
                release_guest_input(&mut socket, &mut touches, &mut keys);
                observed_generation = current.generation;
            }
            let Some(command) = command else {
                continue;
            };
            if matches!(command, GuestInputCommand::ReleaseAll) {
                release_guest_input(&mut socket, &mut touches, &mut keys);
                continue;
            }
            if matches!(command, GuestInputCommand::ResetVideo) {
                match reset {
                    // scrcpy v4 control message 17 resets video capture/encoding. It
                    // produces fresh codec config plus a random-access frame without
                    // tearing down the ADB/helper session.
                    VideoReset::Helper => socket.write_all(&[SCRCPY_CONTROL_RESET_VIDEO])?,
                    VideoReset::Host(flag) => flag.store(true, Ordering::Release),
                }
                continue;
            }
            let GuestInputCommand::Request(request) = command else {
                continue;
            };
            if !current.ready {
                continue;
            }
            match request.union {
                Some(emulator_request::Union::Navigation(navigation)) => {
                    let key = match navigation.enum_value_or_default() {
                        EmulatorNavigation::EmulatorBack => 4,
                        EmulatorNavigation::EmulatorHome => 3,
                        EmulatorNavigation::EmulatorRecents => 187,
                        _ => bail!("Unknown Android navigation action"),
                    };
                    socket.write_all(&key_packet(key, true))?;
                    socket.write_all(&key_packet(key, false))?;
                }
                Some(emulator_request::Union::Key(key)) => {
                    socket.write_all(&key_packet(key.keycode, key.down))?;
                    if key.down {
                        keys.insert(key.keycode);
                    } else {
                        keys.remove(&key.keycode);
                    }
                }
                Some(emulator_request::Union::Text(text)) => {
                    socket.write_all(&text_packet(&text.text)?)?;
                }
                Some(emulator_request::Union::Touch(touch)) => {
                    let (width, height) = (current.width, current.height);
                    if (width as u32, height as u32) != (touch.width, touch.height) {
                        release_guest_touches(&mut socket, &mut touches);
                        log::trace!(
                            "Ignoring stale guest touch geometry {}x{}; current is {}x{}",
                            touch.width,
                            touch.height,
                            width,
                            height
                        );
                        continue;
                    }
                    if touch.action != 0 && !touches.contains_key(&touch.pointer_id) {
                        log::trace!(
                            "Ignoring guest touch action {} for inactive pointer {}",
                            touch.action,
                            touch.pointer_id
                        );
                        continue;
                    }
                    if touch.action == 0
                        && !touches.contains_key(&touch.pointer_id)
                        && touches.len() >= 10
                    {
                        bail!("Too many Android touch pointers")
                    }
                    let (space_width, space_height) = current.touch_space;
                    let x = scale_touch(touch.x, width, space_width);
                    let y = scale_touch(touch.y, height, space_height);
                    socket.write_all(&touch_packet(
                        touch.action as u8,
                        touch.pointer_id,
                        x,
                        y,
                        space_width,
                        space_height,
                    )?)?;
                    if touch.action == 0 {
                        crate::frame_timing::HOST_TAPS.touch_down(Instant::now());
                    }
                    if touch.action == 1 || touch.action == 3 {
                        touches.remove(&touch.pointer_id);
                    } else {
                        touches.insert(touch.pointer_id, (x, y, space_width, space_height));
                    }
                }
                _ => bail!("Unexpected guest input request"),
            }
        }
        Ok(())
    })();
    release_guest_input(&mut socket, &mut touches, &mut keys);
    result
}

fn release_guest_input(
    socket: &mut TcpStream,
    touches: &mut BTreeMap<u64, (u32, u32, u16, u16)>,
    keys: &mut BTreeSet<u32>,
) {
    release_guest_touches(socket, touches);
    for key in std::mem::take(keys) {
        if let Err(error) = socket.write_all(&key_packet(key, false)) {
            log::trace!("Guest key release: {error}");
        }
    }
}

fn release_guest_touches(
    socket: &mut TcpStream,
    touches: &mut BTreeMap<u64, (u32, u32, u16, u16)>,
) {
    for (pointer, (x, y, width, height)) in std::mem::take(touches) {
        if let Err(error) = touch_packet(3, pointer, x, y, width, height)
            .and_then(|packet| socket.write_all(&packet))
        {
            log::trace!("Guest touch release: {error}");
        }
    }
}

fn key_packet(keycode: u32, down: bool) -> [u8; 14] {
    let mut packet = [0; 14];
    packet[1] = if down { 0 } else { 1 };
    packet[2..6].copy_from_slice(&keycode.to_be_bytes());
    packet
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Read, net::TcpListener};

    #[test]
    fn android_emulator_gets_previews_and_the_bluestacks_alias_guard() {
        assert!(has_live_preview("bluestacks"));
        assert!(has_live_preview("avd"));
        assert!(!has_live_preview("ldplayer"));
        assert!(!may_be_bluestacks_alias("bluestacks"));
        assert!(may_be_bluestacks_alias("ldplayer"));
        assert!(may_be_bluestacks_alias("avd"));
    }

    fn shed_touch(action: u32) -> EmulatorRequest {
        let mut request = EmulatorRequest::new();
        request.set_touch(base::message_proto::EmulatorTouch {
            action,
            pointer_id: 1,
            width: 1280,
            height: 720,
            ..Default::default()
        });
        request
    }

    #[test]
    fn touch_moves_shed_only_at_or_above_threshold() {
        let moves = shed_touch(2);
        assert!(!sheds_under_load(&moves, 0));
        assert!(!sheds_under_load(
            &moves,
            GUEST_INPUT_MOVE_SHED_THRESHOLD - 1
        ));
        assert!(sheds_under_load(&moves, GUEST_INPUT_MOVE_SHED_THRESHOLD));
        assert!(sheds_under_load(&moves, GUEST_INPUT_QUEUE_SIZE));
    }

    #[test]
    fn non_move_input_is_never_shed() {
        let mut key = EmulatorRequest::new();
        key.set_key(base::message_proto::EmulatorKey {
            keycode: 29,
            down: true,
            ..Default::default()
        });
        let mut text = EmulatorRequest::new();
        text.set_text(base::message_proto::EmulatorText {
            text: "a".to_owned(),
            ..Default::default()
        });
        let mut navigation = EmulatorRequest::new();
        navigation.set_navigation(EmulatorNavigation::EmulatorBack);
        let requests = [
            shed_touch(0),
            shed_touch(1),
            shed_touch(3),
            key,
            text,
            navigation,
            EmulatorRequest::new(),
        ];
        for request in &requests {
            for pending in [0, GUEST_INPUT_MOVE_SHED_THRESHOLD, GUEST_INPUT_QUEUE_SIZE] {
                assert!(!sheds_under_load(request, pending));
            }
        }
    }

    #[test]
    fn pending_decrement_saturates_at_zero() {
        let pending = AtomicUsize::new(1);
        decrement_pending(&pending);
        decrement_pending(&pending);
        assert_eq!(pending.load(Ordering::Acquire), 0);
    }

    #[test]
    fn inventory_negotiates_operation_capabilities_and_scope() {
        let response = inventory(77, "scope-a", 4);
        let inventory = match response.union {
            Some(base::message_proto::emulator_response::Union::Inventory(inventory)) => inventory,
            _ => panic!("Expected emulator inventory"),
        };
        assert_eq!(inventory.operation_session_identity, "scope-a");
        assert_eq!(inventory.operation_generation, 4);
        assert!(inventory
            .capabilities
            .contains(&"operation.identity.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"operation.ack.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"desktop.stream_liveness.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.process_end".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.shell_restart.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.process_identity.v2".to_owned()));
        assert!(inventory.capabilities.contains(&"guest.text.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"guest.video_refresh.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.recover.bluestacks_adb".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.phone_workspace.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.gateway.status.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.gateway.setup.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.gateway.imdb.v1".to_owned()));
        assert!(inventory
            .capabilities
            .contains(&"host.gateway.restart.v1".to_owned()));
    }

    #[test]
    fn idle_preview_refresh_is_bounded_and_rearmed_only_by_a_frame() {
        let now = Instant::now();
        let mut idle = GuestIdleRefresh::default();
        assert!(!idle.take_due(now + Duration::from_secs(20)));
        idle.note_frame(now);
        assert!(!idle.take_due(now + Duration::from_secs(1)));
        assert!(idle.take_due(now + Duration::from_secs(2)));
        assert!(!idle.take_due(now + Duration::from_secs(30)));
        idle.note_frame(now + Duration::from_secs(31));
        assert!(!idle.take_due(now + Duration::from_secs(32)));
        assert!(idle.take_due(now + Duration::from_secs(33)));
    }

    #[test]
    fn flowing_preview_frames_do_not_request_capture_resets() {
        let now = Instant::now();
        let mut idle = GuestIdleRefresh::default();
        for second in 0..30 {
            let frame_at = now + Duration::from_secs(second);
            idle.note_frame(frame_at);
            assert!(!idle.take_due(frame_at + Duration::from_millis(1900)));
        }
    }

    #[test]
    fn startup_phase_is_carried_as_evidence() {
        let response = with_phase(
            status_response(
                1,
                2,
                "bluestacks:Tiramisu64",
                EmulatorSessionState::EmulatorStarting,
                0,
                0,
                String::new(),
            ),
            "waiting_screen",
        );
        let status = match response.union {
            Some(base::message_proto::emulator_response::Union::Status(status)) => status,
            _ => panic!("Expected emulator status"),
        };
        assert_eq!(status.phase, "waiting_screen");
    }

    #[test]
    fn guest_transport_preserves_short_frame_bursts_without_restarting_video() {
        let (events, mut receiver) = hbb_common::tokio::sync::mpsc::channel(
            super::super::remote::GUEST_EVENT_QUEUE_SIZE,
        );
        let (input, requests) = mpsc::sync_channel(2);
        let mut sender = GuestFrameBackpressure::default();
        // Six 30-FPS frames arriving together after a 200-ms scheduling delay.
        for index in 0..6 {
            sender
                .deliver(
                    EmulatorVideoFrame {
                        session_id: 9,
                        pts: index * 33,
                        key: index == 0,
                        ..Default::default()
                    },
                    &events,
                    &input,
                )
                .unwrap();
        }
        assert!(
            requests.try_recv().is_err(),
            "A short frame burst must not reset the guest encoder"
        );
        let delivered = std::iter::from_fn(|| receiver.try_recv().ok())
            .map(|event| match event {
                GuestEvent::Frame(frame) => frame.pts,
                _ => panic!("Expected video frame"),
            })
            .collect::<Vec<_>>();
        assert_eq!(delivered, vec![0, 33, 66, 99, 132, 165]);
    }

    #[test]
    fn guest_transport_preserves_a_short_burst_at_sixty_fps() {
        let (events, mut receiver) = hbb_common::tokio::sync::mpsc::channel(
            super::super::remote::GUEST_EVENT_QUEUE_SIZE,
        );
        let (input, requests) = mpsc::sync_channel(2);
        let mut sender = GuestFrameBackpressure::default();
        // The Android Emulator streams at 60 FPS: a 200-ms delay is 12 frames.
        for index in 0..12 {
            sender
                .deliver(
                    EmulatorVideoFrame {
                        session_id: 9,
                        pts: index * 17,
                        key: index == 0,
                        ..Default::default()
                    },
                    &events,
                    &input,
                )
                .unwrap();
        }
        assert!(
            requests.try_recv().is_err(),
            "A short 60-FPS burst must not reset the guest encoder"
        );
        assert_eq!(std::iter::from_fn(|| receiver.try_recv().ok()).count(), 12);
    }

    #[test]
    fn full_guest_event_channel_drops_references_and_recovers_at_next_keyframe() {
        let (events, mut receiver) = hbb_common::tokio::sync::mpsc::channel(1);
        let (input, requests) = mpsc::sync_channel(2);
        let mut sender = GuestFrameBackpressure::default();
        let frame = |pts, key| EmulatorVideoFrame {
            session_id: 9,
            pts,
            key,
            ..Default::default()
        };

        // Simulate a stalled connection: capture must not wait for the receiver.
        events.try_send(GuestEvent::Frame(frame(0, true))).unwrap();
        sender.deliver(frame(33, false), &events, &input).unwrap();
        assert!(sender.waiting_key);
        assert!(matches!(
            requests.try_recv(),
            Ok(GuestInputCommand::ResetVideo)
        ));
        sender.deliver(frame(66, false), &events, &input).unwrap();
        assert!(requests.try_recv().is_err(), "Do not flood reset requests");

        // An available slot is not enough: dependent H.264 frames remain invalid
        // after the first drop, even if the network briefly catches up.
        assert!(matches!(receiver.try_recv(), Ok(GuestEvent::Frame(_))));
        sender.deliver(frame(99, false), &events, &input).unwrap();
        assert!(receiver.try_recv().is_err());
        sender.deliver(frame(132, true), &events, &input).unwrap();
        assert!(!sender.waiting_key);
        match receiver.try_recv() {
            Ok(GuestEvent::Frame(recovered)) => {
                assert!(recovered.key);
                assert_eq!(recovered.pts, 132);
            }
            _ => panic!("Expected fresh keyframe after recovery"),
        }
        sender.deliver(frame(165, false), &events, &input).unwrap();
        assert!(matches!(receiver.try_recv(), Ok(GuestEvent::Frame(frame)) if frame.pts == 165));
    }

    #[hbb_common::tokio::test]
    async fn unknown_instance_reports_failure_without_a_guest_session() {
        let mut request = EmulatorRequest {
            request_id: 9,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_select(base::message_proto::EmulatorSelectRequest {
            target_id: format!("bluestacks:missing-{}", uuid::Uuid::new_v4()),
            start_if_stopped: true,
            ..Default::default()
        });
        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::channel(2);
        let session = GuestSession::start(request, sender).unwrap();
        let event = hbb_common::tokio::time::timeout(Duration::from_secs(20), receiver.recv())
            .await
            .unwrap()
            .unwrap();
        match event {
            GuestEvent::Response(response) => match response.union {
                Some(base::message_proto::emulator_response::Union::Status(status)) => {
                    assert_eq!(status.session_id, session.id);
                    assert_eq!(
                        status.state.enum_value_or_default(),
                        EmulatorSessionState::EmulatorFailed
                    );
                    assert!(status.error.contains("no longer exists"));
                }
                _ => panic!("Expected failed selection status"),
            },
            _ => panic!("Unknown instance must not stream video"),
        }
        assert!(
            hbb_common::tokio::time::timeout(Duration::from_secs(5), receiver.recv())
                .await
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn disconnect_releases_guest_touches_and_held_keys() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let sender_socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        // The helper keeps its original control handle alive while the input
        // worker releases held events. Preserve that ownership in this fixture.
        let _owned_control = sender_socket.try_clone().unwrap();
        let (mut reader, _) = listener.accept().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let (sender, receiver) = mpsc::sync_channel(2);
        let mut touch = EmulatorRequest::new();
        touch.set_touch(base::message_proto::EmulatorTouch {
            action: 0,
            pointer_id: 1,
            x: 100,
            y: 200,
            width: 1280,
            height: 720,
            ..Default::default()
        });
        sender.send(GuestInputCommand::Request(touch)).unwrap();
        let mut key = EmulatorRequest::new();
        key.set_key(base::message_proto::EmulatorKey {
            keycode: 29,
            down: true,
            ..Default::default()
        });
        sender.send(GuestInputCommand::Request(key)).unwrap();
        drop(sender);
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &Mutex::new(GuestGeometry::ready(1280, 720)),
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &VideoReset::Helper,
            )
        });
        let mut wire = [0; 92];
        reader.read_exact(&mut wire).unwrap();
        worker.join().unwrap().unwrap();
        assert_eq!(
            &wire[..32],
            &touch_packet(0, 1, 100, 200, 1280, 720).unwrap()
        );
        assert_eq!(&wire[32..46], &key_packet(29, true));
        assert_eq!(
            &wire[46..78],
            &touch_packet(3, 1, 100, 200, 1280, 720).unwrap()
        );
        assert_eq!(&wire[78..], &key_packet(29, false));
    }

    #[test]
    fn liveness_release_cancels_guest_input_without_stopping_worker() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let sender_socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let _owned_control = sender_socket.try_clone().unwrap();
        let (mut reader, _) = listener.accept().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let (sender, receiver) = mpsc::sync_channel(5);

        let mut touch = EmulatorRequest::new();
        touch.set_touch(base::message_proto::EmulatorTouch {
            action: 0,
            pointer_id: 7,
            x: 320,
            y: 240,
            width: 1280,
            height: 720,
            ..Default::default()
        });
        sender.send(GuestInputCommand::Request(touch)).unwrap();

        let mut key = EmulatorRequest::new();
        key.set_key(base::message_proto::EmulatorKey {
            keycode: 29,
            down: true,
            ..Default::default()
        });
        sender.send(GuestInputCommand::Request(key)).unwrap();
        sender.send(GuestInputCommand::ReleaseAll).unwrap();

        for down in [true, false] {
            let mut follow_up = EmulatorRequest::new();
            follow_up.set_key(base::message_proto::EmulatorKey {
                keycode: 30,
                down,
                ..Default::default()
            });
            sender.send(GuestInputCommand::Request(follow_up)).unwrap();
        }
        drop(sender);

        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &Mutex::new(GuestGeometry::ready(1280, 720)),
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &VideoReset::Helper,
            )
        });
        let mut wire = [0; 120];
        reader.read_exact(&mut wire).unwrap();
        worker.join().unwrap().unwrap();

        assert_eq!(
            &wire[..32],
            &touch_packet(0, 7, 320, 240, 1280, 720).unwrap()
        );
        assert_eq!(&wire[32..46], &key_packet(29, true));
        assert_eq!(
            &wire[46..78],
            &touch_packet(3, 7, 320, 240, 1280, 720).unwrap()
        );
        assert_eq!(&wire[78..92], &key_packet(29, false));
        assert_eq!(&wire[92..106], &key_packet(30, true));
        assert_eq!(&wire[106..], &key_packet(30, false));
    }

    #[test]
    fn video_refresh_writes_scrcpy_reset_video_control_message() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let sender_socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let _owned_control = sender_socket.try_clone().unwrap();
        let (mut reader, _) = listener.accept().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let (sender, receiver) = mpsc::sync_channel(1);
        sender.send(GuestInputCommand::ResetVideo).unwrap();
        drop(sender);
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &Mutex::new(GuestGeometry::ready(1280, 720)),
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &VideoReset::Helper,
            )
        });
        let mut wire = [0_u8; 1];
        reader.read_exact(&mut wire).unwrap();
        worker.join().unwrap().unwrap();
        assert_eq!(wire, [SCRCPY_CONTROL_RESET_VIDEO]);
    }

    #[test]
    fn rotation_releases_multitouch_blocks_stale_contacts_and_keeps_worker_alive() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let sender_socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let _owned_control = sender_socket.try_clone().unwrap();
        let (mut reader, _) = listener.accept().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let (sender, receiver) = mpsc::sync_channel(8);
        let geometry = Arc::new(Mutex::new(GuestGeometry::ready(1280, 720)));
        let worker_geometry = geometry.clone();
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &worker_geometry,
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &VideoReset::Helper,
            )
        });

        let request = |action, pointer_id, x, y, width, height| {
            let mut request = EmulatorRequest::new();
            request.set_touch(base::message_proto::EmulatorTouch {
                action,
                pointer_id,
                x,
                y,
                width,
                height,
                ..Default::default()
            });
            GuestInputCommand::Request(request)
        };

        sender.send(request(0, 7, 320, 240, 1280, 720)).unwrap();
        sender.send(request(0, 8, 500, 300, 1280, 720)).unwrap();
        let mut initial = [0; 64];
        reader.read_exact(&mut initial).unwrap();
        assert_eq!(
            &initial[..32],
            &touch_packet(0, 7, 320, 240, 1280, 720).unwrap()
        );
        assert_eq!(
            &initial[32..],
            &touch_packet(0, 8, 500, 300, 1280, 720).unwrap()
        );

        geometry.lock().unwrap().begin_stream(720, 1280);
        let mut releases = [0; 64];
        reader.read_exact(&mut releases).unwrap();
        assert_eq!(
            &releases[..32],
            &touch_packet(3, 7, 320, 240, 1280, 720).unwrap()
        );
        assert_eq!(
            &releases[32..],
            &touch_packet(3, 8, 500, 300, 1280, 720).unwrap()
        );

        // Old geometry is rejected while the new stream has no current frame.
        sender.send(request(2, 7, 321, 241, 1280, 720)).unwrap();
        // A fresh frame makes input eligible again, but an old pointer cannot
        // resume with a move; it must start with a new down.
        geometry.lock().unwrap().ready = true;
        sender.send(request(2, 7, 200, 300, 720, 1280)).unwrap();
        sender.send(request(0, 9, 200, 300, 720, 1280)).unwrap();
        sender.send(request(1, 9, 200, 300, 720, 1280)).unwrap();
        drop(sender);

        let mut wire = [0; 64];
        reader.read_exact(&mut wire).unwrap();
        worker.join().unwrap().unwrap();
        assert_eq!(
            &wire[..32],
            &touch_packet(0, 9, 200, 300, 720, 1280).unwrap()
        );
        assert_eq!(
            &wire[32..],
            &touch_packet(1, 9, 200, 300, 720, 1280).unwrap()
        );
    }

    fn loopback_control() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let sender_socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (reader, _) = listener.accept().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        (sender_socket, reader)
    }

    #[test]
    fn host_touch_maps_feed_space_to_display_space() {
        let (sender_socket, mut reader) = loopback_control();
        let _owned_control = sender_socket.try_clone().unwrap();
        let (sender, receiver) = mpsc::sync_channel(2);
        let mut touch = EmulatorRequest::new();
        touch.set_touch(base::message_proto::EmulatorTouch {
            action: 0,
            pointer_id: 1,
            x: 288,
            y: 640,
            width: 576,
            height: 1280,
            ..Default::default()
        });
        sender.send(GuestInputCommand::Request(touch)).unwrap();
        drop(sender);
        let geometry = GuestGeometry {
            touch_space: (1080, 2400),
            ..GuestGeometry::ready(576, 1280)
        };
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &Mutex::new(geometry),
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &VideoReset::Helper,
            )
        });
        let mut wire = [0; 64];
        reader.read_exact(&mut wire).unwrap();
        worker.join().unwrap().unwrap();
        let down = &wire[..32];
        assert_eq!(down[1], 0);
        assert_eq!(u32::from_be_bytes(down[10..14].try_into().unwrap()), 540);
        assert_eq!(u32::from_be_bytes(down[14..18].try_into().unwrap()), 1200);
        assert_eq!(u16::from_be_bytes(down[18..20].try_into().unwrap()), 1080);
        assert_eq!(u16::from_be_bytes(down[20..22].try_into().unwrap()), 2400);
        // The release on disconnect uses the same display-space contact.
        assert_eq!(
            &wire[32..],
            &touch_packet(3, 1, 540, 1200, 1080, 2400).unwrap()
        );
    }

    #[test]
    fn host_touch_space_clamps_to_the_display_edge() {
        assert_eq!(scale_touch(575, 576, 1080), 1078);
        assert_eq!(scale_touch(576, 576, 1080), 1079);
        assert_eq!(scale_touch(100, 1280, 1280), 100);
    }

    #[test]
    fn display_space_follows_orientation() {
        assert_eq!(display_touch_space((1080, 2400), (1280, 576)), (2400, 1080));
        assert_eq!(display_touch_space((1080, 2400), (576, 1280)), (1080, 2400));
        assert_eq!(display_touch_space((2400, 1080), (576, 1280)), (1080, 2400));
    }

    #[test]
    fn host_reset_sets_flag_instead_of_writing_control() {
        let (sender_socket, mut reader) = loopback_control();
        let (sender, receiver) = mpsc::sync_channel(1);
        sender.send(GuestInputCommand::ResetVideo).unwrap();
        drop(sender);
        let flag = Arc::new(AtomicBool::new(false));
        let reset = VideoReset::Host(flag.clone());
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                &receiver,
                &Mutex::new(GuestGeometry::ready(1280, 720)),
                &AtomicBool::new(false),
                &AtomicUsize::new(0),
                &reset,
            )
        });
        worker.join().unwrap().unwrap();
        assert!(flag.load(Ordering::Acquire));
        let mut wire = Vec::new();
        reader.read_to_end(&mut wire).unwrap();
        assert!(wire.is_empty(), "wrote {wire:?}");
    }

    #[test]
    fn size_change_starts_a_new_geometry() {
        let mut geometry = GuestGeometry::default();
        assert!(geometry.begin_stream(576, 1280));
        let first = geometry.generation;
        assert!(geometry.begin_stream(1280, 576));
        assert!(geometry.generation > first);
        assert!(!geometry.ready);
        assert_eq!(geometry.touch_space, (1280, 576));
    }

    #[hbb_common::tokio::test]
    #[ignore = "Captures an explicitly selected idle local BlueStacks preview without injecting input"]
    async fn idle_preview_keeps_delivering_current_frames() {
        async fn next_frame(
            receiver: &mut hbb_common::tokio::sync::mpsc::Receiver<GuestEvent>,
            session_id: u64,
        ) {
            loop {
                match receiver.recv().await.expect("Preview closed before its next frame") {
                    GuestEvent::Frame(frame) if frame.session_id == session_id => {
                        assert!(!frame.data.is_empty());
                        return;
                    }
                    _ => {}
                }
            }
        }
        let target = std::env::var("MIRPG_TEST_IDLE_TARGET").expect("Set MIRPG_TEST_IDLE_TARGET");
        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::channel(32);
        let session = GuestSession::start_preview(1, target, sender).unwrap();
        hbb_common::tokio::time::timeout(
            Duration::from_secs(30), next_frame(&mut receiver, session.id),
        ).await.expect("Preview did not start");
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(12) {
            hbb_common::tokio::time::timeout(
                Duration::from_secs(3), next_frame(&mut receiver, session.id),
            ).await.expect("Idle preview stopped delivering frames before the stale-image deadline");
        }
        session.cancel();
    }

    #[hbb_common::tokio::test]
    #[ignore = "Captures an explicitly selected idle local fullscreen guest without injecting input"]
    async fn idle_fullscreen_keeps_delivering_current_frames() {
        let target = std::env::var("MIRPG_TEST_IDLE_TARGET").expect("Set MIRPG_TEST_IDLE_TARGET");
        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::channel(32);
        let mut request = EmulatorRequest { request_id: 1, protocol_version: PROTOCOL_VERSION, ..Default::default() };
        request.set_select(base::message_proto::EmulatorSelectRequest { target_id: target, ..Default::default() });
        let session = GuestSession::start(request, sender).unwrap();
        let started = Instant::now();
        let mut received = 0;
        let mut maximum_gap = Duration::ZERO;
        let mut last_frame = Instant::now();
        let result = async {
            while started.elapsed() < Duration::from_secs(15) {
                let event = hbb_common::tokio::time::timeout(
                    if received == 0 { Duration::from_secs(30) } else { Duration::from_secs(3) },
                    receiver.recv(),
                ).await.map_err(|_| "Fullscreen stopped delivering frames before the four-second input deadline")?
                    .ok_or("Fullscreen closed before its next frame")?;
                if let GuestEvent::Response(response) = &event {
                    if let Some(base::message_proto::emulator_response::Union::Status(status)) = &response.union {
                        if received != 0 && status.state.enum_value_or_default() == EmulatorSessionState::EmulatorStarting {
                            return Err("Same-size recovery replaced the live image with a loading screen");
                        }
                    }
                }
                if let GuestEvent::Frame(frame) = event {
                    assert_eq!(frame.session_id, session.id);
                    assert!(!frame.data.is_empty());
                    if received != 0 { maximum_gap = maximum_gap.max(last_frame.elapsed()); }
                    last_frame = Instant::now();
                    received += 1;
                }
            }
            Ok::<_, &str>(())
        }.await;
        session.cancel();
        eprintln!("Fullscreen capture: frames={received}, elapsed={:?}, maximum_gap={maximum_gap:?}", started.elapsed());
        result.unwrap();
    }

    #[hbb_common::tokio::test]
    #[ignore = "Starts guest capture in two explicitly selected local emulator instances"]
    async fn two_guest_sessions_keep_separate_identities_and_cancel_independently() {
        async fn next_key(
            receiver: &mut hbb_common::tokio::sync::mpsc::Receiver<GuestEvent>,
            expected: u64,
            key_required: bool,
        ) -> ResultType<()> {
            loop {
                let event =
                    hbb_common::tokio::time::timeout(Duration::from_secs(110), receiver.recv())
                        .await?
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Guest event channel closed"))?;
                match event {
                    GuestEvent::Frame(frame) if frame.key || !key_required => {
                        if frame.session_id != expected {
                            bail!("Guest identity mismatch");
                        }
                        eprintln!(
                            "Guest {expected} frame: {} bytes, key={}",
                            frame.data.len(),
                            frame.key
                        );
                        return Ok(());
                    }
                    GuestEvent::Response(response) => {
                        if let Some(base::message_proto::emulator_response::Union::Status(status)) =
                            response.union
                        {
                            if status.state.enum_value_or_default()
                                == EmulatorSessionState::EmulatorFailed
                            {
                                bail!("{}", status.error);
                            }
                            if status.session_id != expected {
                                bail!("Guest identity mismatch");
                            }
                            eprintln!("Guest {expected} status: {:?}", status.state);
                        }
                    }
                    _ => {}
                }
            }
        }
        let target_ids = [
            std::env::var("MIRPG_TEST_TARGET_A").expect("Set MIRPG_TEST_TARGET_A"),
            std::env::var("MIRPG_TEST_TARGET_B").expect("Set MIRPG_TEST_TARGET_B"),
        ];
        assert_ne!(target_ids[0], target_ids[1]);
        let mut sessions = Vec::new();
        let mut receivers = Vec::new();
        for target_id in target_ids {
            let mut request = EmulatorRequest {
                request_id: 1,
                protocol_version: PROTOCOL_VERSION,
                ..Default::default()
            };
            request.set_select(base::message_proto::EmulatorSelectRequest {
                target_id,
                start_if_stopped: true,
                ..Default::default()
            });
            let (sender, receiver) = hbb_common::tokio::sync::mpsc::channel(2);
            sessions.push(GuestSession::start(request, sender).unwrap());
            receivers.push(receiver);
        }
        assert_ne!(sessions[0].id, sessions[1].id);
        let result = async {
            eprintln!("Waiting for first guest {}", sessions[0].id);
            next_key(&mut receivers[0], sessions[0].id, true).await?;
            eprintln!("Waiting for second guest {}", sessions[1].id);
            next_key(&mut receivers[1], sessions[1].id, true).await?;
            sessions[0].cancel();
            while receivers[1].try_recv().is_ok() {}
            let mut navigation = EmulatorRequest {
                session_id: sessions[1].id,
                ..Default::default()
            };
            navigation.set_navigation(EmulatorNavigation::EmulatorHome);
            sessions[1].input(navigation.clone())?;
            eprintln!("Waiting for surviving guest after Home");
            hbb_common::tokio::time::timeout(
                Duration::from_secs(20),
                next_key(&mut receivers[1], sessions[1].id, false),
            )
            .await??;
            navigation.set_navigation(EmulatorNavigation::EmulatorBack);
            sessions[1].input(navigation)?;
            Ok::<(), hbb_common::anyhow::Error>(())
        }
        .await;
        for session in &sessions {
            session.cancel();
        }
        for receiver in &mut receivers {
            hbb_common::tokio::time::timeout(Duration::from_secs(35), async {
                while receiver.recv().await.is_some() {}
            })
            .await
            .unwrap();
        }
        result.unwrap();
    }

    const TRIAL_AVD: &str = "Aperture_Trial_Play35";

    fn trial_adb() -> PathBuf {
        PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_default())
            .join(r"Android\Sdk\platform-tools\adb.exe")
    }

    fn trial_shell(serial: &str, args: &[&str]) -> String {
        let mut command = std::process::Command::new(trial_adb());
        if !serial.is_empty() {
            command.args(["-s", serial]);
        }
        let output = command.args(args).output().unwrap();
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn trial_serial() -> String {
        let devices = trial_shell("", &["devices"]);
        for line in devices.lines().skip(1) {
            let serial = line.split_whitespace().next().unwrap_or("");
            if serial.starts_with("emulator-")
                && trial_shell(serial, &["emu", "avd", "name"])
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

    fn trial_ui_xml(serial: &str) -> String {
        trial_shell(
            serial,
            &[
                "shell",
                "uiautomator dump /data/local/tmp/t5-ui.xml >/dev/null; cat /data/local/tmp/t5-ui.xml",
            ],
        )
    }

    /// The centre of the first UI node with `text` (XML-escaped), in display
    /// pixels of the current rotation.
    fn trial_centre_of(xml: &str, text: &str) -> Option<(u32, u32)> {
        let node = &xml[xml.find(&format!(" text=\"{text}\""))?..];
        let bounds = &node[node.find(" bounds=\"[")? + 10..];
        let bounds = &bounds[..bounds.find('"')?];
        let numbers: Vec<u32> = bounds
            .split(|c: char| !c.is_ascii_digit())
            .filter(|part| !part.is_empty())
            .filter_map(|part| part.parse().ok())
            .collect();
        match numbers[..] {
            [left, top, right, bottom] => Some(((left + right) / 2, (top + bottom) / 2)),
            _ => None,
        }
    }

    /// The display's (long, short) side.
    fn trial_landscape_display(serial: &str) -> (u32, u32) {
        let size = trial_shell(serial, &["shell", "wm", "size"]);
        let (width, height) = size
            .lines()
            .filter_map(|line| line.rsplit(':').next()?.trim().split_once('x'))
            .filter_map(|(w, h)| Some((w.trim().parse::<u32>().ok()?, h.trim().parse::<u32>().ok()?)))
            .last()
            .expect("wm size");
        (width.max(height), width.min(height))
    }

    fn trial_screen_texts(serial: &str) -> Vec<String> {
        let xml = trial_ui_xml(serial);
        xml.split(" text=\"")
            .skip(1)
            .filter_map(|part| part.split_once('"').map(|(text, _)| text.to_owned()))
            .filter(|text| !text.is_empty())
            .collect()
    }

    fn trial_open_settings(serial: &str) -> Vec<String> {
        for package in ["com.android.settings", "com.google.android.settings.intelligence"] {
            trial_shell(serial, &["shell", "am", "force-stop", package]);
        }
        trial_shell(serial, &["shell", "input", "keyevent", "3"]);
        // NEW_TASK | CLEAR_TASK: always the main Settings screen.
        trial_shell(
            serial,
            &["shell", "am", "start", "-f", "0x10008000", "-a", "android.settings.SETTINGS"],
        );
        thread::sleep(Duration::from_secs(3));
        trial_screen_texts(serial)
    }

    fn trial_select() -> EmulatorRequest {
        let mut request = EmulatorRequest {
            request_id: 1,
            protocol_version: PROTOCOL_VERSION,
            ..Default::default()
        };
        request.set_select(base::message_proto::EmulatorSelectRequest {
            target_id: format!("avd:{TRIAL_AVD}"),
            ..Default::default()
        });
        request
    }

    type Events = hbb_common::tokio::sync::mpsc::Receiver<GuestEvent>;
    type TestRuntime = hbb_common::tokio::runtime::Runtime;

    fn test_runtime() -> TestRuntime {
        hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    fn next_event(runtime: &TestRuntime, events: &mut Events, wait: Duration) -> Option<GuestEvent> {
        runtime
            .block_on(async { hbb_common::tokio::time::timeout(wait, events.recv()).await })
            .ok()
            .flatten()
    }

    /// Waits for `stream_ready` (optionally of a landscape or portrait
    /// stream), returning its size.
    fn wait_stream_ready(
        runtime: &TestRuntime,
        events: &mut Events,
        within: Duration,
        landscape: Option<bool>,
    ) -> Option<(u32, u32)> {
        let started = Instant::now();
        while started.elapsed() < within {
            let Some(event) = next_event(runtime, events, within.saturating_sub(started.elapsed()))
            else {
                break;
            };
            if let GuestEvent::Response(response) = event {
                if let Some(base::message_proto::emulator_response::Union::Status(status)) =
                    response.union
                {
                    let state = status.state.enum_value_or_default();
                    assert_ne!(state, EmulatorSessionState::EmulatorFailed, "{}", status.error);
                    if state == EmulatorSessionState::EmulatorStreaming
                        && status.phase == "stream_ready"
                        && landscape.map_or(true, |landscape| {
                            (status.width > status.height) == landscape
                        })
                    {
                        return Some((status.width, status.height));
                    }
                }
            }
        }
        None
    }

    /// Consumes events until the stream has been ready in the expected
    /// orientation, with no geometry change, for 1 s; returns its size.
    /// The fixture stops reading events while it drives the guest over adb.
    /// The session then stalls on the full event queue in the middle of a
    /// geometry change (HOME turns the guest portrait), and a tap sent before
    /// that backlog clears arrives while the geometry is not ready.
    fn settle_stream(
        runtime: &TestRuntime,
        events: &mut Events,
        ready: &mut Option<(u32, u32)>,
        landscape: bool,
        within: Duration,
    ) -> Option<(u32, u32)> {
        let started = Instant::now();
        let mut changed = Instant::now();
        while started.elapsed() < within {
            if let Some(size) = *ready {
                if (size.0 > size.1) == landscape && changed.elapsed() >= Duration::from_secs(1) {
                    return Some(size);
                }
            }
            if let Some(GuestEvent::Response(response)) =
                next_event(runtime, events, Duration::from_millis(50))
            {
                if let Some(base::message_proto::emulator_response::Union::Status(status)) =
                    response.union
                {
                    let state = status.state.enum_value_or_default();
                    assert_ne!(state, EmulatorSessionState::EmulatorFailed, "{}", status.error);
                    match status.phase.as_str() {
                        "stream_ready" => *ready = Some((status.width, status.height)),
                        "waiting_screen" => *ready = None,
                        _ => {}
                    }
                    changed = Instant::now();
                }
            }
        }
        None
    }

    /// Puts the guest in `rotation` (accelerometer off) and waits until the
    /// stream has settled in that orientation; returns the stream size.
    /// The setting is re-put while waiting: Android can rewrite user_rotation
    /// when Settings starts (it restores the rotation it was last shown in).
    fn force_rotation(
        runtime: &TestRuntime,
        events: &mut Events,
        serial: &str,
        current: (u32, u32),
        rotation: u32,
    ) -> (u32, u32) {
        let rotation_value = rotation.to_string();
        let wanted = [("accelerometer_rotation", "0"), ("user_rotation", rotation_value.as_str())];
        let mut ready = Some(current);
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(15) {
            for (key, value) in wanted {
                if trial_setting(serial, key) != value {
                    trial_shell(serial, &["shell", "settings", "put", "system", key, value]);
                }
            }
            let settled =
                settle_stream(runtime, events, &mut ready, rotation % 2 == 1, Duration::from_secs(3));
            if let Some(size) = settled {
                if wanted.iter().all(|(key, value)| trial_setting(serial, key) == *value) {
                    return size;
                }
            }
        }
        panic!("the stream did not settle at rotation {rotation}: {ready:?}");
    }

    /// Consumes events for `duration`: (frames, key frames).
    fn pump(runtime: &TestRuntime, events: &mut Events, duration: Duration) -> (usize, usize) {
        let started = Instant::now();
        let (mut frames, mut keys) = (0, 0);
        while started.elapsed() < duration {
            if let Some(GuestEvent::Frame(frame)) =
                next_event(runtime, events, duration.saturating_sub(started.elapsed()))
            {
                frames += 1;
                keys += usize::from(frame.key);
            }
        }
        (frames, keys)
    }

    fn tap(session: &GuestSession, (width, height): (u32, u32)) {
        tap_at(session, (width, height), (width / 2, height / 2));
    }

    fn tap_at(session: &GuestSession, (width, height): (u32, u32), (x, y): (u32, u32)) {
        for action in [0, 1] {
            let mut request = EmulatorRequest {
                session_id: session.id,
                ..Default::default()
            };
            request.set_touch(base::message_proto::EmulatorTouch {
                action,
                pointer_id: 0,
                x,
                y,
                width,
                height,
                ..Default::default()
            });
            session.input(request).unwrap();
            thread::sleep(Duration::from_millis(60));
        }
    }

    fn close(runtime: &TestRuntime, session: GuestSession, mut events: Events) {
        session.cancel();
        drop(session);
        runtime
            .block_on(async {
                hbb_common::tokio::time::timeout(Duration::from_secs(35), async {
                    while events.recv().await.is_some() {}
                })
                .await
            })
            .expect("guest session did not close");
    }

    /// Restores the trial emulator's rotation settings on drop.
    struct RotationGuard {
        serial: String,
        accelerometer: String,
        user_rotation: String,
    }

    impl Drop for RotationGuard {
        fn drop(&mut self) {
            for (key, value) in [
                ("user_rotation", &self.user_rotation),
                ("accelerometer_rotation", &self.accelerometer),
            ] {
                let value = if value.is_empty() || value == "null" {
                    "0"
                } else {
                    value.as_str()
                };
                trial_shell(&self.serial, &["shell", "settings", "put", "system", key, value]);
            }
        }
    }

    fn trial_setting(serial: &str, key: &str) -> String {
        trial_shell(serial, &["shell", "settings", "get", "system", key])
            .trim()
            .to_owned()
    }

    #[test]
    #[ignore = "Streams the running Aperture_Trial_Play35 emulator through the host GPU"]
    fn real_local_avd_streams_from_host_near_sixty_fps() {
        let serial = trial_serial();
        capture_log();
        assert!(
            scrap::hwcodec::HwRamEncoder::try_get(scrap::CodecFormat::H264).is_some(),
            "no hardware H.264 encoder in the hwcodec config"
        );
        let runtime = test_runtime();
        trial_shell(&serial, &["shell", "input", "keyevent", "KEYCODE_HOME"]);
        let host_streams = avd_host_video::HOST_STREAMS_READY.load(Ordering::Acquire);
        let (sender, mut events) =
            hbb_common::tokio::sync::mpsc::channel(super::super::remote::GUEST_EVENT_QUEUE_SIZE);
        let started = Instant::now();
        let session = GuestSession::start(trial_select(), sender).unwrap();
        let size = wait_stream_ready(&runtime, &mut events, Duration::from_secs(10), None)
            .expect("no stream_ready within 10 s");
        let ready_after = started.elapsed();
        // The hook counts after `stream_ready` is sent, so it can lag the event.
        let counted = Instant::now();
        while avd_host_video::HOST_STREAMS_READY.load(Ordering::Acquire) == host_streams
            && counted.elapsed() < Duration::from_secs(1)
        {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            avd_host_video::HOST_STREAMS_READY.load(Ordering::Acquire) > host_streams,
            "the session fell back to in-Android video"
        );
        eprintln!("RESULT stream_ready after {ready_after:?} at {size:?}");

        // A moving screen: one bounded on-device swipe loop.
        let swiper = {
            let serial = serial.clone();
            thread::spawn(move || {
                trial_shell(
                    &serial,
                    &[
                        "shell",
                        "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do input swipe 800 1500 100 1500 250; input swipe 100 1500 800 1500 250; done",
                    ],
                );
            })
        };
        let first = loop {
            match next_event(&runtime, &mut events, Duration::from_secs(2)) {
                Some(GuestEvent::Frame(frame)) => break frame,
                Some(_) => {}
                None => panic!("no frame after stream_ready"),
            }
        };
        assert!(first.key, "the first frame must be a keyframe");
        thread::sleep(Duration::from_millis(300));
        while events.try_recv().is_ok() {}
        let (frames, keys) = pump(&runtime, &mut events, Duration::from_secs(5));
        eprintln!("RESULT moving screen: {frames} frames ({keys} key) in 5 s");
        swiper.join().unwrap();

        // A still screen, then an explicit refresh.
        let (still_frames, still_keys) = pump(&runtime, &mut events, Duration::from_secs(5));
        eprintln!("RESULT still screen: {still_frames} frames ({still_keys} key) in 5 s");
        let requested = Instant::now();
        session.refresh_video().unwrap();
        let refresh_latency = loop {
            assert!(
                requested.elapsed() < Duration::from_secs(1),
                "no keyframe within 1 s of refresh"
            );
            if let Some(GuestEvent::Frame(frame)) =
                next_event(&runtime, &mut events, Duration::from_millis(100))
            {
                if frame.key {
                    break requested.elapsed();
                }
            }
        };
        eprintln!("RESULT refresh keyframe after {refresh_latency:?}");

        // A tap through input() at the centre of the stream.
        trial_open_settings(&serial);
        let size = force_rotation(&runtime, &mut events, &serial, size, 0);
        let main = trial_screen_texts(&serial);
        tap(&session, size);
        pump(&runtime, &mut events, Duration::from_millis(1500));
        let after = trial_screen_texts(&serial);
        let portrait_tap = main != after;
        eprintln!("RESULT portrait tap landed={portrait_tap}: {main:?} -> {after:?}");

        // Landscape: rotate the guest, wait for the new geometry, tap again.
        let landscape = {
            let _restore = RotationGuard {
                serial: serial.clone(),
                accelerometer: trial_setting(&serial, "accelerometer_rotation"),
                user_rotation: trial_setting(&serial, "user_rotation"),
            };
            trial_shell(&serial, &["shell", "settings", "put", "system", "accelerometer_rotation", "0"]);
            trial_shell(&serial, &["shell", "settings", "put", "system", "user_rotation", "1"]);
            let rotated =
                wait_stream_ready(&runtime, &mut events, Duration::from_secs(10), Some(true));
            eprintln!("RESULT landscape stream_ready: {rotated:?}");
            rotated.map(|rotated| {
                trial_open_settings(&serial);
                let rotated = force_rotation(&runtime, &mut events, &serial, rotated, 1);
                let main = trial_screen_texts(&serial);
                tap(&session, rotated);
                pump(&runtime, &mut events, Duration::from_millis(1500));
                let after = trial_screen_texts(&serial);
                let centre = main != after;
                eprintln!("RESULT landscape centre tap landed={centre}: {main:?} -> {after:?}");

                // Off-centre (lower-left quadrant): "Network & internet" by its
                // bounds in the rotated display. A swapped mapping would put
                // this tap far outside the 1080-pixel-high landscape screen.
                trial_open_settings(&serial);
                let settled = force_rotation(&runtime, &mut events, &serial, rotated, 1);
                assert_eq!(settled, rotated, "the landscape stream size changed");
                let display = trial_landscape_display(&serial);
                let target = trial_centre_of(&trial_ui_xml(&serial), "Network &amp; internet")
                    .expect("Network & internet in landscape Settings");
                let point = (
                    target.0 * rotated.0 / display.0,
                    target.1 * rotated.1 / display.1,
                );
                tap_at(&session, rotated, point);
                pump(&runtime, &mut events, Duration::from_millis(1500));
                let after = trial_screen_texts(&serial);
                let off_centre = after.iter().any(|text| text == "Internet")
                    && !after.iter().any(|text| text == "Connected devices");
                eprintln!(
                    "RESULT landscape off-centre tap at display {target:?} = stream {point:?} landed={off_centre}: {after:?}"
                );
                centre && off_centre
            })
        };
        trial_shell(&serial, &["shell", "input", "keyevent", "3"]);
        pump(&runtime, &mut events, Duration::from_secs(2));
        close(&runtime, session, events);

        assert!(ready_after <= Duration::from_secs(10));
        assert!(frames >= 250, "only {frames} frames in 5 s");
        assert!(portrait_tap, "the portrait tap did not land");
        assert_eq!(landscape, Some(true), "landscape stream or tap failed");
    }

    #[test]
    #[ignore = "Rotates the running Aperture_Trial_Play35 emulator"]
    fn real_rotation_watcher_follows_the_guest() {
        let serial = trial_serial();
        // Captured before Settings opens: opening it can rewrite user_rotation.
        let _restore = RotationGuard {
            serial: serial.clone(),
            accelerometer: trial_setting(&serial, "accelerometer_rotation"),
            user_rotation: trial_setting(&serial, "user_rotation"),
        };
        trial_open_settings(&serial);
        trial_shell(&serial, &["shell", "settings", "put", "system", "accelerometer_rotation", "0"]);
        trial_shell(&serial, &["shell", "settings", "put", "system", "user_rotation", "0"]);
        let watcher = avd_host_video::RotationWatcher::start(&trial_adb(), &serial).unwrap();
        let wait_for = |rotation: u32| {
            let started = Instant::now();
            while started.elapsed() < Duration::from_secs(6) {
                if watcher.rotation() == Some(rotation) {
                    return Some(started.elapsed());
                }
                thread::sleep(Duration::from_millis(20));
            }
            None
        };
        assert!(wait_for(0).is_some(), "no initial rotation");
        // The guest's own rotation (its animation) can take seconds; the
        // watcher is measured against when the display itself reports it.
        let display_reports = |serial: String, rotation: u32, started: Instant| {
            thread::spawn(move || {
                let wanted = format!("mCurrentOrientation={rotation}");
                while started.elapsed() < Duration::from_secs(6) {
                    if trial_shell(
                        &serial,
                        &["shell", "dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-3]'"],
                    )
                    .contains(&wanted)
                    {
                        return Some(started.elapsed());
                    }
                }
                None
            })
        };
        let mut latencies = Vec::new();
        for rotation in [1, 2, 3, 0] {
            let started = Instant::now();
            trial_shell(
                &serial,
                &["shell", "settings", "put", "system", "user_rotation", &rotation.to_string()],
            );
            let display = display_reports(serial.clone(), rotation, started);
            // Both measured from `started`.
            let seen = wait_for(rotation).map(|_| started.elapsed());
            let display = display.join().unwrap();
            latencies.push((rotation, display, seen));
        }
        drop(watcher);
        // The guest loop ends at its next echo, after the dumpsys it may be
        // in (slow while the guest is still rotating).
        let dropped = Instant::now();
        let leftover = loop {
            thread::sleep(Duration::from_millis(500));
            let leftover =
                trial_shell(&serial, &["shell", "ps -A -o ARGS | grep -c '[m]CurrentOrientation'"]);
            if leftover.trim() == "0" || dropped.elapsed() >= Duration::from_secs(5) {
                break leftover;
            }
        };
        eprintln!(
            "RESULT rotation (rotation, display, watcher) {latencies:?}; leftover loops {}",
            leftover.trim()
        );
        for (rotation, display, seen) in latencies {
            let seen = seen.unwrap_or_else(|| panic!("rotation {rotation} not seen"));
            let display = display.unwrap_or_else(|| panic!("the display never reached {rotation}"));
            // The watcher polls every 250 ms (plus a dumpsys); the display
            // time is itself an adb poll, so allow for both.
            let lag = seen.saturating_sub(display);
            assert!(lag <= Duration::from_secs(1), "rotation {rotation}: watcher {lag:?} behind");
        }
        assert_eq!(leftover.trim(), "0", "the guest loop outlived the watcher");
    }

    /// Soak length and sample interval: APERTURE_SOAK_MINUTES (30) and
    /// APERTURE_SOAK_SAMPLE_SECS (300).
    fn soak_timing() -> (Duration, Duration) {
        let read = |key: &str, default: u64| {
            std::env::var(key)
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(default)
        };
        (
            Duration::from_secs(read("APERTURE_SOAK_MINUTES", 30) * 60),
            Duration::from_secs(read("APERTURE_SOAK_SAMPLE_SECS", 300)),
        )
    }

    /// Guest memory and process counts, for the soak samples.
    fn trial_guest_stats(serial: &str) -> String {
        trial_shell(
            serial,
            &[
                "shell",
                "echo \"avail=$(grep MemAvailable /proc/meminfo | tr -s ' ' | cut -d' ' -f2)kB procs=$(ps -A | wc -l) watch_loops=$(ps -A -o ARGS | grep -c '[m]CurrentOrientation') helpers=$(ps -A -o ARGS | grep -c '[c]om.genymobile.scrcpy') load=$(cut -d' ' -f1-3 /proc/loadavg)\"",
            ],
        )
        .trim()
        .to_owned()
    }

    #[test]
    #[ignore = "Streams the running Aperture_Trial_Play35 emulator through the host GPU for 30 minutes"]
    fn soak_host_stream() {
        let serial = trial_serial();
        capture_log();
        let (length, every) = soak_timing();
        let runtime = test_runtime();
        trial_open_settings(&serial);
        let (sender, mut events) =
            hbb_common::tokio::sync::mpsc::channel(super::super::remote::GUEST_EVENT_QUEUE_SIZE);
        let session = GuestSession::start(trial_select(), sender).unwrap();
        wait_stream_ready(&runtime, &mut events, Duration::from_secs(10), None)
            .expect("no stream_ready within 10 s");
        // One time-bounded on-device loop keeps the Settings list moving.
        let swiper = {
            let serial = serial.clone();
            let secs = length.as_secs() + 30;
            thread::spawn(move || {
                trial_shell(
                    &serial,
                    &[
                        "shell",
                        &format!("end=$(( $(date +%s) + {secs} )); while [ $(date +%s) -lt $end ]; do input swipe 540 1700 540 900 400; input swipe 540 900 540 1700 400; done"),
                    ],
                );
            })
        };
        let started = Instant::now();
        let mut frame_times: std::collections::VecDeque<Instant> = Default::default();
        let mut next_sample = started + Duration::from_secs(30);
        while started.elapsed() < length + Duration::from_secs(31) {
            if let Some(GuestEvent::Frame(_)) =
                next_event(&runtime, &mut events, Duration::from_millis(50))
            {
                frame_times.push_back(Instant::now());
            }
            while frame_times
                .front()
                .is_some_and(|time| time.elapsed() > Duration::from_secs(60))
            {
                frame_times.pop_front();
            }
            if Instant::now() >= next_sample {
                next_sample += every;
                let last_5s = frame_times
                    .iter()
                    .filter(|time| time.elapsed() <= Duration::from_secs(5))
                    .count();
                let per_5s_over_minute = frame_times.len() as f64 / 12.0;
                let timing = CAPTURED_LOG
                    .0
                    .lock()
                    .unwrap()
                    .iter()
                    .rev()
                    .find(|line| line.contains("Guest video (host GPU)"))
                    .cloned()
                    .unwrap_or_default();
                eprintln!(
                    "SOAK host t={:>4}s frames/5s={last_5s} (minute avg {per_5s_over_minute:.0}) guest[{}] timing[{timing}]",
                    started.elapsed().as_secs(),
                    trial_guest_stats(&serial)
                );
            }
        }
        close(&runtime, session, events);
        let _ = swiper.join();
        eprintln!("SOAK host end guest[{}]", trial_guest_stats(&serial));
    }

    #[test]
    #[ignore = "Runs the rotation watcher shell in the running Aperture_Trial_Play35 emulator"]
    fn real_closed_job_ends_the_watcher_shell() {
        use std::io::BufRead;
        let serial = trial_serial();
        let loops = || {
            trial_shell(&serial, &["shell", "ps -A -o ARGS | grep -c '[m]CurrentOrientation'"])
                .trim()
                .to_owned()
        };
        assert_eq!(loops(), "0", "a watcher loop is already running");
        let (mut child, stdout) =
            avd_host_video::spawn_rotation_shell(&trial_adb(), &serial).unwrap();
        // Stands in for this process's lifetime job: closing it is what an
        // abrupt exit does.
        let job = super::super::guest_runtime::KillOnCloseJob::new().unwrap();
        job.assign(&child).unwrap();
        let mut line = String::new();
        std::io::BufReader::new(stdout).read_line(&mut line).unwrap();
        assert!(line.starts_with("r="), "{line:?}");
        assert_eq!(loops(), "1");
        drop(job);
        let closed = Instant::now();
        while child.try_wait().unwrap().is_none() {
            assert!(closed.elapsed() < Duration::from_secs(2), "adb outlived the job");
            thread::sleep(Duration::from_millis(20));
        }
        let host_gone = closed.elapsed();
        let guest_gone = loop {
            if loops() == "0" {
                break closed.elapsed();
            }
            assert!(closed.elapsed() < Duration::from_secs(10), "the guest loop outlived adb");
            thread::sleep(Duration::from_millis(250));
        };
        eprintln!("RESULT job closed: adb gone after {host_gone:?}, guest loop gone after {guest_gone:?}");
    }

    #[test]
    #[ignore = "Rotates the running Aperture_Trial_Play35 emulator and streams it through the host GPU"]
    fn real_cold_landscape_start_is_upright() {
        let serial = trial_serial();
        capture_log();
        let runtime = test_runtime();
        let _restore = RotationGuard {
            serial: serial.clone(),
            accelerometer: trial_setting(&serial, "accelerometer_rotation"),
            user_rotation: trial_setting(&serial, "user_rotation"),
        };
        trial_open_settings(&serial);
        trial_shell(&serial, &["shell", "settings", "put", "system", "accelerometer_rotation", "0"]);
        trial_shell(&serial, &["shell", "settings", "put", "system", "user_rotation", "1"]);
        let rotated = Instant::now();
        while !trial_shell(&serial, &["shell", "dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-3]'"])
            .contains("mCurrentOrientation=1")
        {
            assert!(rotated.elapsed() < Duration::from_secs(5), "the guest did not rotate");
            thread::sleep(Duration::from_millis(100));
        }
        thread::sleep(Duration::from_secs(1));
        let log_mark = CAPTURED_LOG.0.lock().unwrap().len();
        let host_streams = avd_host_video::HOST_STREAMS_READY.load(Ordering::Acquire);
        let (sender, mut events) =
            hbb_common::tokio::sync::mpsc::channel(super::super::remote::GUEST_EVENT_QUEUE_SIZE);
        let started = Instant::now();
        let session = GuestSession::start(trial_select(), sender).unwrap();
        // Every stream_ready of the first 6 s, and when the first frame came.
        let mut readies = Vec::new();
        let mut first_frame = None;
        while started.elapsed() < Duration::from_secs(6) {
            match next_event(&runtime, &mut events, Duration::from_millis(100)) {
                Some(GuestEvent::Response(response)) => {
                    if let Some(base::message_proto::emulator_response::Union::Status(status)) =
                        response.union
                    {
                        let state = status.state.enum_value_or_default();
                        assert_ne!(state, EmulatorSessionState::EmulatorFailed, "{}", status.error);
                        if status.phase == "stream_ready" {
                            readies.push((started.elapsed(), status.width, status.height));
                        }
                    }
                }
                Some(GuestEvent::Frame(frame)) if first_frame.is_none() => {
                    first_frame = Some((started.elapsed(), frame.key));
                }
                _ => {}
            }
        }
        let host_readies =
            avd_host_video::HOST_STREAMS_READY.load(Ordering::Acquire) - host_streams;
        eprintln!("RESULT cold landscape: stream_ready {readies:?}; host readies {host_readies}; first frame {first_frame:?}");

        // The first tap of the session: "Network & internet" by its bounds in
        // the rotated display (lower-left quadrant in landscape).
        let landed = readies.first().map(|&(_, width, height)| {
            let display = trial_landscape_display(&serial);
            let target = trial_centre_of(&trial_ui_xml(&serial), "Network &amp; internet")
                .expect("Network & internet in landscape Settings");
            let point = (target.0 * width / display.0, target.1 * height / display.1);
            while events.try_recv().is_ok() {}
            tap_at(&session, (width, height), point);
            pump(&runtime, &mut events, Duration::from_millis(1500));
            let after = trial_screen_texts(&serial);
            let landed = after.iter().any(|text| text == "Internet")
                && !after.iter().any(|text| text == "Connected devices");
            eprintln!("RESULT cold landscape first tap at stream {point:?} landed={landed}: {after:?}");
            landed
        });
        trial_shell(&serial, &["shell", "input", "keyevent", "3"]);
        close(&runtime, session, events);
        let unknown_warned = CAPTURED_LOG.0.lock().unwrap()[log_mark..]
            .iter()
            .any(|line| line.contains("rotation unknown"));
        eprintln!("RESULT rotation-unknown warn={unknown_warned}");

        assert_eq!(host_readies, 1, "the session must reach stream_ready once, on the host path");
        assert_eq!(readies.len(), 1, "exactly one stream_ready: {readies:?}");
        assert_eq!((readies[0].1, readies[0].2), (1280, 576), "the first stream must be upright");
        assert!(!unknown_warned, "rotation unknown was logged");
        assert_eq!(landed, Some(true), "the first landscape tap did not land");
    }

    struct CapturedLog(Mutex<Vec<String>>);

    impl hbb_common::log::Log for CapturedLog {
        fn enabled(&self, metadata: &hbb_common::log::Metadata) -> bool {
            metadata.level() <= hbb_common::log::Level::Info
        }

        fn log(&self, record: &hbb_common::log::Record) {
            if self.enabled(record.metadata()) {
                let line = format!("{} {}", record.level(), record.args());
                eprintln!("{line}");
                self.0.lock().unwrap().push(line);
            }
        }

        fn flush(&self) {}
    }

    static CAPTURED_LOG: CapturedLog = CapturedLog(Mutex::new(Vec::new()));

    fn capture_log() {
        // Only the first test of a run installs it; later ones share it.
        if hbb_common::log::set_logger(&CAPTURED_LOG).is_ok() {
            hbb_common::log::set_max_level(hbb_common::log::LevelFilter::Info);
        }
    }

    #[test]
    #[ignore = "Streams the running Aperture_Trial_Play35 emulator with its screen feed hidden"]
    fn blocked_feed_falls_back_to_in_android_video() {
        trial_serial();
        capture_log();
        *avd_host_video::FEED_AVD_OVERRIDE.lock().unwrap() =
            Some("Aperture_No_Such_Avd".to_owned());
        let runtime = test_runtime();
        let (sender, mut events) =
            hbb_common::tokio::sync::mpsc::channel(super::super::remote::GUEST_EVENT_QUEUE_SIZE);
        let started = Instant::now();
        let session = GuestSession::start(trial_select(), sender).unwrap();
        let ready = wait_stream_ready(&runtime, &mut events, Duration::from_secs(25), None);
        let ready_after = started.elapsed();
        let (frames, _) = pump(&runtime, &mut events, Duration::from_secs(1));
        close(&runtime, session, events);
        *avd_host_video::FEED_AVD_OVERRIDE.lock().unwrap() = None;
        let warned = CAPTURED_LOG.0.lock().unwrap().iter().any(|line| {
            line.starts_with("WARN AVD host video unavailable, using in-Android video: ")
        });
        eprintln!(
            "RESULT fallback stream_ready={ready:?} after {ready_after:?}, {frames} frames in 1 s, warned={warned}"
        );
        assert!(ready.is_some(), "no stream_ready within 25 s");
        assert!(frames > 0);
        assert!(warned, "the fallback warn line is missing");
    }
}
