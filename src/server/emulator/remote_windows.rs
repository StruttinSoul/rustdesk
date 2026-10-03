use super::{
    bluestacks::BlueStacksProvider,
    guest_protocol::{touch_packet, H264Frames, VideoPacket},
    guest_runtime::{adb_command, helper_path, is_default_adb_server, GuestHelper},
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
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

struct LocalTarget {
    provider: Arc<dyn EmulatorProvider>,
    target: EmulatorTarget,
}

fn targets() -> (Vec<LocalTarget>, Vec<String>) {
    let mut found = Vec::new();
    let mut errors = Vec::new();
    let providers: [(&str, ResultType<Option<Arc<dyn EmulatorProvider>>>); 2] = [
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

pub fn inventory(request_id: u64) -> EmulatorResponse {
    let (targets, provider_errors) = targets();
    let instances = targets
        .into_iter()
        .map(|local| EmulatorInstance {
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
        })
        .collect();
    let mut response = response(request_id);
    response.set_inventory(EmulatorInventory {
        instances,
        provider_errors,
        dashboard: true,
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

fn adb_executable() -> ResultType<PathBuf> {
    if let Some(adb) = hbb_common::sysinfo::System::new_all()
        .processes()
        .values()
        .find_map(|process| {
            (process.name().eq_ignore_ascii_case("adb.exe")
                && is_default_adb_server(process.cmd())
                && process.exe().is_file())
            .then(|| process.exe().to_path_buf())
        })
    {
        return Ok(adb);
    }
    for root in [
        std::env::var_os("ANDROID_SDK_ROOT"),
        std::env::var_os("ANDROID_HOME"),
        std::env::var_os("LOCALAPPDATA")
            .map(|path| PathBuf::from(path).join("Android/Sdk").into_os_string()),
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
    input: SyncSender<EmulatorRequest>,
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
        let mut request = EmulatorRequest { request_id, protocol_version: PROTOCOL_VERSION, ..Default::default() };
        request.set_select(base::message_proto::EmulatorSelectRequest { target_id, ..Default::default() });
        Self::start_with_mode(request, events, true)
    }

    fn start_with_mode(request: EmulatorRequest, events: hbb_common::tokio::sync::mpsc::Sender<GuestEvent>, preview: bool) -> ResultType<Self> {
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
        let (input, receiver) = mpsc::sync_channel(32);
        let session = Self {
            id,
            target_id: target_id.clone(),
            preview,
            cancel: cancel.clone(),
            sockets: sockets.clone(),
            input,
        };
        thread::Builder::new()
            .name("emulator-guest".to_owned())
            .spawn(move || {
                let result = run_session(
                    &request, id, &target_id, &events, &cancel, &sockets, receiver, preview,
                );
                if let Err(error) = result {
                    if !cancel.load(Ordering::Acquire) {
                        log::warn!("Guest session {id} failed: {error}");
                        let _ = events.blocking_send(GuestEvent::Response(with_preview(status_response(
                            request.request_id,
                            id,
                            &target_id,
                            EmulatorSessionState::EmulatorFailed,
                            0,
                            0,
                            error.to_string(),
                        ), preview)));
                    }
                }
            })?;
        Ok(session)
    }

    pub fn input(&self, request: EmulatorRequest) -> ResultType<()> {
        if self.preview { bail!("Preview streams cannot receive input") }
        if self.cancel.load(Ordering::Acquire) {
            bail!("Guest session is closed")
        }
        self.input
            .try_send(request)
            .map_err(|_| hbb_common::anyhow::anyhow!("Guest input is busy or disconnected"))
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
    input: mpsc::Receiver<EmulatorRequest>,
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
    if preview && (local.target.provider.to_string() != "bluestacks" || local.target.state == EmulatorState::Stopped) {
        bail!("Only running BlueStacks instances have live previews")
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
    if is_stopped {
        local.provider.start(&local.target)?;
    }
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
    // Android's emulator-N aliases are port based and may belong to a different
    // provider when both runtimes are installed. Never inject into that guest.
    let bluestacks_marker = adb_command(
        &adb,
        &serial,
        &["shell", "getprop", "ro.bst.ime_listener_port"],
    )?;
    if local.target.provider.to_string() == "ldplayer" && !bluestacks_marker.trim().is_empty() {
        bail!("This LDPlayer ADB endpoint belongs to BlueStacks; resolve the ADB port conflict in the emulator settings")
    }
    if selection.launch_default_app && local.target.provider.to_string() == "bluestacks" {
        super::bluestacks::launch_default_app(&local.target.provider_instance_id)?;
    }
    if cancel.load(Ordering::Acquire) {
        return Ok(());
    }
    let mut helper = if preview { GuestHelper::connect_preview(&adb, &serial, &helper)? } else { GuestHelper::connect(&adb, &serial, &helper)? };
    let control = helper.control_socket()?;
    let stop_socket = helper.cancellation_socket()?;
    {
        let mut owned = sockets.lock().unwrap();
        if cancel.load(Ordering::Acquire) {
            return Ok(());
        }
        owned.push(stop_socket);
    }
    let dimensions = Arc::new(Mutex::new((0, 0)));
    let input_dimensions = dimensions.clone();
    let input_stop_flag = Arc::new(AtomicBool::new(false));
    let input_cancel = input_stop_flag.clone();
    let input_stop = helper.cancellation_socket()?;
    let writer = thread::Builder::new()
        .name("emulator-input".to_owned())
        .spawn(move || {
            if let Err(error) = input_loop(control, input, &input_dimensions, &input_cancel) {
                log::warn!("Guest input stopped: {error}");
            }
            if let Err(error) = input_stop.shutdown(Shutdown::Both) {
                log::trace!("Guest input cancellation: {error}");
            }
        })?;
    let mut frames = H264Frames::default();
    let result = (|| -> ResultType<()> {
        loop {
            if cancel.load(Ordering::Acquire) {
                return Ok(());
            }
            let packet = helper.read_packet()?;
            if let VideoPacket::Session { width, height } = &packet {
                *dimensions.lock().unwrap() = (*width, *height);
                events.blocking_send(GuestEvent::Response(with_preview(status_response(
                    request.request_id,
                    id,
                    target_id,
                    EmulatorSessionState::EmulatorStreaming,
                    *width,
                    *height,
                    String::new(),
                ), preview)))?;
            }
            if let Some(frame) = frames.accept(packet)? {
                events.blocking_send(GuestEvent::Frame(EmulatorVideoFrame {
                    session_id: id,
                    data: frame.data.into(),
                    key: frame.key,
                    pts: frame.pts_ms,
                    ..Default::default()
                }))?;
            }
        }
    })();
    input_stop_flag.store(true, Ordering::Release);
    if writer.join().is_err() {
        log::warn!("Guest input worker panicked");
    }
    drop(helper);
    result
}

pub fn with_preview(mut response: EmulatorResponse, preview: bool) -> EmulatorResponse {
    if let Some(base::message_proto::emulator_response::Union::Status(status)) = response.union.as_mut() {
        status.preview = preview;
    }
    response
}

fn input_loop(
    mut socket: TcpStream,
    receiver: mpsc::Receiver<EmulatorRequest>,
    dimensions: &Mutex<(u16, u16)>,
    cancel: &AtomicBool,
) -> ResultType<()> {
    let mut touches = BTreeMap::new();
    let mut keys = BTreeSet::new();
    let result = (|| -> ResultType<()> {
        loop {
            if cancel.load(Ordering::Acquire) {
                break;
            }
            let request = match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(request) => request,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
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
                Some(emulator_request::Union::Touch(touch)) => {
                    let (width, height) = *dimensions.lock().unwrap();
                    if (width as u32, height as u32) != (touch.width, touch.height) {
                        bail!("Guest display dimensions changed; retry touch")
                    }
                    if touch.action == 0
                        && !touches.contains_key(&touch.pointer_id)
                        && touches.len() >= 10
                    {
                        bail!("Too many Android touch pointers")
                    }
                    socket.write_all(&touch_packet(
                        touch.action as u8,
                        touch.pointer_id,
                        touch.x,
                        touch.y,
                        width,
                        height,
                    )?)?;
                    if touch.action == 1 || touch.action == 3 {
                        touches.remove(&touch.pointer_id);
                    } else {
                        touches.insert(touch.pointer_id, (touch.x, touch.y, width, height));
                    }
                }
                _ => bail!("Unexpected guest input request"),
            }
        }
        Ok(())
    })();
    for (pointer, (x, y, width, height)) in touches {
        if let Err(error) = touch_packet(3, pointer, x, y, width, height)
            .and_then(|packet| socket.write_all(&packet))
        {
            log::trace!("Guest touch release: {error}");
        }
    }
    for key in keys {
        if let Err(error) = socket.write_all(&key_packet(key, false)) {
            log::trace!("Guest key release: {error}");
        }
    }
    result
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
        sender.send(touch).unwrap();
        let mut key = EmulatorRequest::new();
        key.set_key(base::message_proto::EmulatorKey {
            keycode: 29,
            down: true,
            ..Default::default()
        });
        sender.send(key).unwrap();
        drop(sender);
        let worker = thread::spawn(move || {
            input_loop(
                sender_socket,
                receiver,
                &Mutex::new((1280, 720)),
                &AtomicBool::new(false),
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
}
