//! Host-GPU video for an emulator: a screen captured on this PC (a
//! `HostScreenSource`) is encoded here (`host_video`) while a control-only
//! helper carries input. When the host path cannot deliver a first frame, the
//! session falls back to the in-Android helper video.
//!
//! A child module of `remote_windows`: it reuses that module's private session
//! machinery (geometry, input worker, watchdog and frame backpressure).
//!
//! No provider has a source since the Android Emulator was removed; the
//! BlueStacks host-capture work adds one (`host_screen_source`).

use super::super::{
    guest_runtime::{adb_command, bind_to_process_lifetime, GuestHelper, GuestStreamProfile},
    host_video::{
        even_size, orient_rgba, stream_box, upright_rgba, EncodedHostFrame, HostEncoder, HostImage,
        BOTTOM_UP,
    },
    remote::GuestEvent,
};
use super::{
    decrement_pending, display_touch_space, input_loop, spawn_recovery_watchdog, FrameSender,
    GuestGeometry, GuestIdleRefresh, GuestInputCommand, VideoReset,
};
use base::message_proto::EmulatorRequest;
use hbb_common::{bail, log, ResultType};
use std::{
    io::{BufRead, BufReader},
    os::windows::process::CommandExt,
    path::Path,
    process::{Child, ChildStdout, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

/// The host path must deliver its first frame this soon after subscribing.
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(5);
/// Longest wait for a feed image before re-checking cancel and reset.
const POLL: Duration = Duration::from_millis(20);

/// One guest shell for the whole session. It prints Android's boot id once,
/// then its display rotation every 250 ms; printing every tick also ends the
/// loop (SIGPIPE) soon after the adb client is gone.
const ROTATION_LOOP: &str = "echo \"b=$(cat /proc/sys/kernel/random/boot_id)\"; while :; do r=$(dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentOrientation=[0-3]'); echo \"r=$r\" || exit; sleep 0.25; done";
const ROTATION_UNKNOWN: u8 = u8::MAX;
/// How long the first encode waits for the watcher's first report.
const FIRST_ROTATION_WAIT: Duration = Duration::from_secs(1);
/// A watcher whose shell ended is restarted at most this often.
const ROTATION_RESTART: Duration = Duration::from_secs(3);

/// The rotation in one line of `ROTATION_LOOP`.
fn parse_rotation(line: &str) -> Option<u8> {
    let value = line.trim().strip_prefix("r=mCurrentOrientation=")?;
    value.parse::<u8>().ok().filter(|rotation| *rotation < 4)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RotationReading {
    /// The watcher printed at least one line (parsable or not).
    reported: bool,
    /// The last rotation it parsed.
    rotation: Option<u32>,
}

/// What the watcher has seen. An unparsable line, or the shell ending,
/// keeps the last known rotation.
struct RotationState {
    rotation: AtomicU8,
    reported: AtomicBool,
    /// Android's boot id when the watcher first started.
    boot: Mutex<Option<String>>,
    /// A later shell printed another boot id: Android was restarted.
    restarted: AtomicBool,
}

impl RotationState {
    fn new() -> Self {
        Self {
            rotation: AtomicU8::new(ROTATION_UNKNOWN),
            reported: AtomicBool::new(false),
            boot: Mutex::new(None),
            restarted: AtomicBool::new(false),
        }
    }

    fn apply(&self, line: &str) {
        if let Some(boot) = line.trim().strip_prefix("b=") {
            if boot.is_empty() {
                return;
            }
            let mut first = self.boot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            match first.as_deref() {
                None => *first = Some(boot.to_owned()),
                Some(first) if first != boot => self.restarted.store(true, Ordering::Release),
                Some(_) => {}
            }
            return;
        }
        if let Some(rotation) = parse_rotation(line) {
            self.rotation.store(rotation, Ordering::Release);
        }
        self.reported.store(true, Ordering::Release);
    }

    fn rotation(&self) -> Option<u32> {
        let rotation = self.rotation.load(Ordering::Acquire);
        (rotation != ROTATION_UNKNOWN).then_some(u32::from(rotation))
    }

    fn guest_restarted(&self) -> bool {
        self.restarted.load(Ordering::Acquire)
    }

    fn reading(&self) -> RotationReading {
        // `reported` first: a rotation stored before it is then seen too.
        let reported = self.reported.load(Ordering::Acquire);
        RotationReading {
            reported,
            rotation: self.rotation(),
        }
    }
}

/// Reads watcher lines until `stop`. When a shell ends, `restart` starts a
/// new one, at most once per `retry` (counted from the last start).
fn supervise<R: BufRead>(
    state: &RotationState,
    stop: &AtomicBool,
    first: R,
    mut restart: impl FnMut() -> ResultType<R>,
    retry: Duration,
) {
    let mut reader = Some(first);
    let mut last_start = Instant::now();
    loop {
        if let Some(reader) = reader.take() {
            for line in reader.lines() {
                let Ok(line) = line else { break };
                state.apply(&line);
            }
        }
        loop {
            if stop.load(Ordering::Acquire) {
                return;
            }
            let left = retry.saturating_sub(last_start.elapsed());
            if left.is_zero() {
                break;
            }
            thread::sleep(left.min(Duration::from_millis(50)));
        }
        last_start = Instant::now();
        match restart() {
            Ok(restarted) => {
                hbb_common::throttled_log!(
                    Duration::from_secs(60),
                    info,
                    "Rotation watcher ended; restarted it"
                );
                reader = Some(restarted);
            }
            Err(error) => hbb_common::throttled_log!(
                Duration::from_secs(60),
                warn,
                "Rotation watcher ended and cannot restart: {error}"
            ),
        }
    }
}

pub(super) fn spawn_rotation_shell(adb: &Path, serial: &str) -> ResultType<(Child, ChildStdout)> {
    let mut child = Command::new(adb)
        .creation_flags(0x08000000)
        .args(["-s", serial, "shell", ROTATION_LOOP])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    bind_to_process_lifetime(&child);
    match child.stdout.take() {
        Some(stdout) => Ok((child, stdout)),
        None => {
            end_child(&mut child);
            bail!("the rotation watcher has no output")
        }
    }
}

fn end_child(child: &mut Child) {
    if let Err(error) = child.kill() {
        log::trace!("Rotation watcher kill: {error}");
    }
    let _ = child.wait();
}

/// Watches the guest's display rotation through one persistent `adb shell`
/// (restarted, throttled, if it ends). A source that keeps the portrait panel
/// leaves the host to turn frames upright itself. Killed (and joined) on
/// drop.
pub(super) struct RotationWatcher {
    child: Arc<Mutex<Option<Child>>>,
    stop: Arc<AtomicBool>,
    reader: Option<thread::JoinHandle<()>>,
    state: Arc<RotationState>,
    started: Instant,
}

impl RotationWatcher {
    pub(super) fn start(adb: &Path, serial: &str) -> ResultType<Self> {
        let started = Instant::now();
        let (child, stdout) = spawn_rotation_shell(adb, serial)?;
        let child = Arc::new(Mutex::new(Some(child)));
        let stop = Arc::new(AtomicBool::new(false));
        let state = Arc::new(RotationState::new());
        let reader = {
            let (child, stop, state) = (child.clone(), stop.clone(), state.clone());
            let (adb, serial) = (adb.to_owned(), serial.to_owned());
            thread::Builder::new()
                .name("emulator-rotation".to_owned())
                .spawn(move || {
                    let restart = || -> ResultType<BufReader<ChildStdout>> {
                        let mut slot = child.lock().unwrap();
                        if let Some(mut ended) = slot.take() {
                            end_child(&mut ended);
                        }
                        // Checked under the lock: drop sets `stop` first and
                        // then kills whatever child is in the slot.
                        if stop.load(Ordering::Acquire) {
                            bail!("stopped");
                        }
                        let (restarted, stdout) = spawn_rotation_shell(&adb, &serial)?;
                        *slot = Some(restarted);
                        Ok(BufReader::new(stdout))
                    };
                    supervise(&state, &stop, BufReader::new(stdout), restart, ROTATION_RESTART);
                })
        };
        match reader {
            Ok(reader) => Ok(Self {
                child,
                stop,
                reader: Some(reader),
                state,
                started,
            }),
            Err(error) => {
                if let Some(mut child) = child.lock().unwrap().take() {
                    end_child(&mut child);
                }
                Err(error.into())
            }
        }
    }

    /// Android was restarted (`adb reboot`) since the watcher started: the
    /// input helper died with it.
    pub(super) fn guest_restarted(&self) -> bool {
        self.state.guest_restarted()
    }
}

impl Drop for RotationWatcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(mut child) = self.child.lock().unwrap().take() {
            end_child(&mut child);
        }
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

/// The rotation to turn the next image upright with, or `None` to hold it
/// while the watcher has not reported yet (up to `FIRST_ROTATION_WAIT` after
/// it started). Unknown after that counts as 0 (logged).
fn encode_rotation(watcher: Option<(RotationReading, Duration)>) -> Option<u32> {
    let Some((reading, waited)) = watcher else {
        return Some(0);
    };
    if let Some(rotation) = reading.rotation {
        return Some(rotation);
    }
    if !reading.reported && waited < FIRST_ROTATION_WAIT {
        log::trace!("Display rotation not reported yet; holding the first frame");
        return None;
    }
    hbb_common::throttled_log!(
        Duration::from_secs(60),
        warn,
        "Display rotation unknown; streaming the emulator screen unrotated"
    );
    Some(0)
}

fn current_rotation(watcher: Option<&RotationWatcher>) -> Option<u32> {
    encode_rotation(watcher.map(|watcher| (watcher.state.reading(), watcher.started.elapsed())))
}

/// Bounds how long the host path may go without delivering a frame after
/// subscribing, and again after the one reconnect.
struct Liveness {
    subscribed: Instant,
    /// A frame has been delivered: the host path is live.
    streaming: bool,
    /// A frame has been delivered since the last (re)subscribe.
    delivered: bool,
}

impl Liveness {
    fn new(subscribed: Instant) -> Self {
        Self {
            subscribed,
            streaming: false,
            delivered: false,
        }
    }

    fn delivered(&mut self) {
        self.streaming = true;
        self.delivered = true;
    }

    fn resubscribed(&mut self, now: Instant) {
        self.subscribed = now;
        self.delivered = false;
    }

    /// `NoFirstFrame` when nothing came before the first frame; an error
    /// when a re-subscribed feed stays silent.
    fn check(&self, now: Instant) -> ResultType<Option<HostOutcome>> {
        if self.delivered || now.saturating_duration_since(self.subscribed) < FIRST_FRAME_TIMEOUT {
            return Ok(None);
        }
        if !self.streaming {
            return Ok(Some(HostOutcome::NoFirstFrame(format!(
                "no frame within {} s",
                FIRST_FRAME_TIMEOUT.as_secs()
            ))));
        }
        bail!(
            "the host screen source sent no frame within {} s of reconnecting",
            FIRST_FRAME_TIMEOUT.as_secs()
        )
    }
}

/// A screen captured on this PC: images fitted into a `width`x`height` box,
/// rows top-down. A failure arrives as an `Err` on the channel and is the
/// last item. Dropping the returned guard stops the source.
pub(super) trait HostScreenSource {
    fn start(
        &self,
        width: u32,
        height: u32,
    ) -> ResultType<(Box<dyn Send>, Receiver<ResultType<HostImage>>)>;
}

/// What `run_session` hands the host path.
pub(super) struct HostSession<'a> {
    pub(super) request: &'a EmulatorRequest,
    pub(super) id: u64,
    pub(super) target_id: &'a str,
    pub(super) events: &'a hbb_common::tokio::sync::mpsc::Sender<GuestEvent>,
    pub(super) cancel: &'a Arc<AtomicBool>,
    pub(super) capture_input: &'a SyncSender<GuestInputCommand>,
    pub(super) pending_requests: &'a Arc<AtomicUsize>,
    pub(super) preview: bool,
    pub(super) adb: &'a Path,
    pub(super) serial: &'a str,
    pub(super) helper: &'a Path,
    pub(super) source: &'a dyn HostScreenSource,
}

pub(super) enum HostAttempt {
    /// The session ended on the host path (cancelled or failed).
    Finished(ResultType<()>),
    /// No first frame: continue with the in-Android video, with this input.
    Fallback(Receiver<GuestInputCommand>),
}

#[derive(Debug, PartialEq, Eq)]
enum HostOutcome {
    Cancelled,
    NoFirstFrame(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct HostSettings {
    long_side: u32,
    fps: u32,
    bit_rate: u32,
    keyframe_frames: usize,
}

impl HostSettings {
    fn new(preview: bool) -> Self {
        let profile = GuestStreamProfile::for_host_video(preview);
        let fps = profile.max_fps().max(1);
        Self {
            long_side: profile.max_size(),
            fps,
            bit_rate: profile.bit_rate(),
            keyframe_frames: (profile.keyframe_interval_secs() * fps) as usize,
        }
    }

    /// Images that arrive sooner than this after the last encode wait (and
    /// are replaced by newer ones).
    fn min_gap(&self) -> Duration {
        Duration::from_millis(u64::from(1000 / self.fps).saturating_sub(2))
    }
}

/// The last `WxH` of `wm size` (an override size wins over the physical one).
fn parse_wm_size(output: &str) -> Option<(u16, u16)> {
    output
        .lines()
        .filter_map(|line| line.rsplit(':').next())
        .filter_map(|size| size.trim().split_once('x'))
        .filter_map(|(w, h)| Some((w.trim().parse::<u16>().ok()?, h.trim().parse::<u16>().ok()?)))
        .filter(|(w, h)| *w > 0 && *h > 0)
        .last()
}

fn display_size(adb: &Path, serial: &str) -> ResultType<(u16, u16)> {
    let output = adb_command(adb, serial, &["shell", "wm", "size"])?;
    match parse_wm_size(&output) {
        Some(size) => Ok(size),
        None => bail!("unrecognised display size {:?}", output.trim()),
    }
}

/// Runs the session on the host path. Returns `Fallback` (after one `warn`)
/// when it cannot deliver a first frame.
pub(super) fn run(session: &HostSession, input: Receiver<GuestInputCommand>) -> HostAttempt {
    let fallback = |input, reason: String| {
        if session.cancel.load(Ordering::Acquire) {
            return HostAttempt::Finished(Ok(()));
        }
        log::warn!("Host video unavailable, using in-Android video: {reason}");
        HostAttempt::Fallback(input)
    };
    let settings = HostSettings::new(session.preview);
    // Full screen: a control-only helper, which injects in display pixels.
    let (helper, display) = if session.preview {
        (None, None)
    } else {
        let display = match display_size(session.adb, session.serial) {
            Ok(display) => display,
            Err(error) => return fallback(input, format!("cannot read the display size: {error}")),
        };
        match GuestHelper::connect_control_only(session.adb, session.serial, session.helper) {
            Ok(helper) => (Some(helper), Some(display)),
            Err(error) => return fallback(input, format!("input helper: {error}")),
        }
    };
    let control = match helper.as_ref().map(GuestHelper::control_socket).transpose() {
        Ok(control) => control,
        Err(error) => return HostAttempt::Finished(Err(error)),
    };
    let rotation = match RotationWatcher::start(session.adb, session.serial) {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            log::warn!("Rotation watcher unavailable: {error}");
            None
        }
    };
    let reset = Arc::new(AtomicBool::new(false));
    let geometry = Arc::new(Mutex::new(GuestGeometry::default()));
    let idle = Arc::new(Mutex::new(GuestIdleRefresh::default()));
    let stop = Arc::new(AtomicBool::new(false));
    let input_stopped = Arc::new(AtomicBool::new(false));
    let timed_out = Arc::new(AtomicBool::new(false));
    let input_worker = {
        let (geometry, stop, pending, reset, stopped) = (
            geometry.clone(),
            stop.clone(),
            session.pending_requests.clone(),
            reset.clone(),
            input_stopped.clone(),
        );
        thread::Builder::new()
            .name("emulator-input".to_owned())
            .spawn(move || {
                match control {
                    Some(control) => {
                        if let Err(error) = input_loop(
                            control,
                            &input,
                            &geometry,
                            &stop,
                            &pending,
                            &VideoReset::Host(reset),
                        ) {
                            log::warn!("Guest input stopped: {error}");
                        }
                    }
                    None => forward_resets(&input, &reset, &stop, &pending),
                }
                stopped.store(true, Ordering::Release);
                input
            })
    };
    let input_worker = match input_worker {
        Ok(worker) => worker,
        Err(error) => return HostAttempt::Finished(Err(error.into())),
    };
    let watchdog = spawn_recovery_watchdog(
        geometry.clone(),
        idle.clone(),
        session.capture_input.clone(),
        stop.clone(),
        timed_out.clone(),
        || {},
    );
    let outcome = match &watchdog {
        Ok(_) => host_video_loop(&HostVideo {
            session,
            settings,
            display,
            rotation: rotation.as_ref(),
            geometry: &geometry,
            idle: &idle,
            reset: &reset,
            timed_out: &timed_out,
            input_stopped: &input_stopped,
        }),
        Err(error) => Err(hbb_common::anyhow::anyhow!("Guest recovery watchdog: {error}")),
    };
    stop.store(true, Ordering::Release);
    if let Ok(watchdog) = watchdog {
        if watchdog.join().is_err() {
            log::warn!("Guest recovery watchdog panicked");
        }
    }
    let input = input_worker.join();
    if input.is_err() {
        log::warn!("Guest input worker panicked");
    }
    drop(helper);
    drop(rotation);
    match outcome {
        Ok(HostOutcome::Cancelled) if timed_out.load(Ordering::Acquire) => HostAttempt::Finished(
            Err(hbb_common::anyhow::anyhow!(
                "Guest screen did not produce a current frame within 10 seconds"
            )),
        ),
        Ok(HostOutcome::Cancelled) => HostAttempt::Finished(Ok(())),
        Ok(HostOutcome::NoFirstFrame(reason)) => match input {
            Ok(input) => fallback(input, reason),
            Err(_) => HostAttempt::Finished(Err(hbb_common::anyhow::anyhow!(
                "Guest input worker panicked"
            ))),
        },
        Err(error) => HostAttempt::Finished(Err(error)),
    }
}

/// Preview input: no helper, only video resets reach the host encoder.
fn forward_resets(
    receiver: &Receiver<GuestInputCommand>,
    reset: &AtomicBool,
    stop: &AtomicBool,
    pending: &AtomicUsize,
) {
    while !stop.load(Ordering::Acquire) {
        match receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(GuestInputCommand::ResetVideo) => reset.store(true, Ordering::Release),
            Ok(GuestInputCommand::Request(_)) => decrement_pending(pending),
            Ok(GuestInputCommand::ReleaseAll) | Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}

struct HostVideo<'a> {
    session: &'a HostSession<'a>,
    settings: HostSettings,
    /// The device display (full screen only): the touch space.
    display: Option<(u16, u16)>,
    rotation: Option<&'a RotationWatcher>,
    geometry: &'a Mutex<GuestGeometry>,
    idle: &'a Mutex<GuestIdleRefresh>,
    reset: &'a AtomicBool,
    timed_out: &'a AtomicBool,
    input_stopped: &'a AtomicBool,
}

/// Delivers the encoder's output.
fn deliver(
    sender: &mut FrameSender,
    frames: Vec<EncodedHostFrame>,
    live: &mut Liveness,
) -> ResultType<()> {
    for frame in frames.into_iter().filter(|frame| !frame.data.is_empty()) {
        sender.send(frame.data, frame.key, frame.pts)?;
        live.delivered();
    }
    Ok(())
}

/// Source -> host encoder -> session. `NoFirstFrame` when nothing was
/// delivered within `FIRST_FRAME_TIMEOUT` (or the source or encoder failed
/// before that); an error when the source stays silent that long after the
/// reconnect.
fn host_video_loop(video: &HostVideo) -> ResultType<HostOutcome> {
    let session = video.session;
    let (box_width, box_height) = stream_box(video.settings.long_side);
    let start_feed = || session.source.start(box_width, box_height);
    let (mut feed, mut images) = match start_feed() {
        Ok(started) => started,
        Err(error) => return Ok(HostOutcome::NoFirstFrame(error.to_string())),
    };
    let mut live = Liveness::new(Instant::now());
    let mut sender = FrameSender::new(
        session.request,
        session.id,
        session.target_id,
        session.events,
        session.capture_input,
        session.preview,
        video.geometry,
        video.idle,
        "Guest video (host GPU)",
    );
    let mut encoder: Option<HostEncoder> = None;
    // The upright stream size and the rotation it was turned by.
    let mut size: Option<(u32, u32, u32)> = None;
    let mut pending: Option<HostImage> = None;
    // The last encoded image, re-encoded if Android's rotation moves on
    // while the screen is still.
    let mut last_image: Option<HostImage> = None;
    let mut last_encode: Option<Instant> = None;
    let mut reconnected = false;
    let min_gap = video.settings.min_gap();
    let clock = Instant::now();
    loop {
        if session.cancel.load(Ordering::Acquire) || video.timed_out.load(Ordering::Acquire) {
            return Ok(HostOutcome::Cancelled);
        }
        if video.input_stopped.load(Ordering::Acquire) {
            bail!("Guest input stopped")
        }
        // Ends the session so the phone reopens it with a new input helper.
        if video.rotation.map_or(false, RotationWatcher::guest_restarted)
            || super::super::emulator_power::rebooted_after(session.serial, clock)
        {
            bail!("Android restarted in the emulator")
        }
        if let Some(outcome) = live.check(Instant::now())? {
            return Ok(outcome);
        }
        if video.reset.swap(false, Ordering::AcqRel) {
            if let Some(active) = encoder.as_mut() {
                match active.force_key() {
                    Ok(frames) => deliver(&mut sender, frames, &mut live)?,
                    Err(error) if !live.streaming => {
                        return Ok(HostOutcome::NoFirstFrame(error.to_string()))
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        // `None` holds the first image until the watcher's first report.
        let rotation = current_rotation(video.rotation);
        if let Some(rotation) = rotation {
            requeue_on_rotation(
                &mut pending,
                &mut last_image,
                size.map(|(_, _, rotation)| rotation),
                rotation,
            );
        }
        let due = last_encode
            .map(|last| min_gap.saturating_sub(last.elapsed()))
            .unwrap_or(Duration::ZERO);
        if let (true, Some(rotation)) = (due.is_zero(), rotation) {
            if let Some(image) = pending.take() {
                let (feed_width, feed_height) = even_size(image.width, image.height);
                if feed_width == 0 || feed_height == 0 {
                    continue;
                }
                let (width, height) = if rotation % 2 == 1 {
                    (feed_height, feed_width)
                } else {
                    (feed_width, feed_height)
                };
                if size != Some((width, height, rotation)) {
                    // A new geometry (size or rotation): release the old
                    // encoder (and its slot) first; the new one starts with a
                    // keyframe.
                    encoder = None;
                    size = Some((width, height, rotation));
                    let stream = (u16::try_from(width)?, u16::try_from(height)?);
                    let changed = {
                        let mut current = video.geometry.lock().unwrap();
                        let changed = current.begin_stream(stream.0, stream.1);
                        if let Some(display) = video.display {
                            current.touch_space = display_touch_space(display, stream);
                        }
                        changed
                    };
                    if !session.preview && changed {
                        sender.send_waiting_screen()?;
                    }
                }
                let encode_started = Instant::now();
                let encoded = (|| -> ResultType<Vec<EncodedHostFrame>> {
                    let active = match encoder.as_mut() {
                        Some(active) => active,
                        None => encoder.insert(HostEncoder::new(
                            width,
                            height,
                            video.settings.bit_rate,
                            video.settings.keyframe_frames,
                            session.preview,
                        )?),
                    };
                    let (rgba, _, _) = upright_rgba(
                        orient_rgba(&image, BOTTOM_UP),
                        feed_width,
                        feed_height,
                        rotation,
                    )?;
                    active.encode(rgba, clock.elapsed().as_millis() as i64)
                })();
                // The cap counts from the start of an encode, so encode time
                // does not push every later frame back.
                last_encode = Some(encode_started);
                if !session.preview {
                    sender
                        .timing
                        .sample("encode", crate::frame_timing::ms(encode_started.elapsed()));
                }
                last_image = Some(image);
                match encoded {
                    Ok(frames) => deliver(&mut sender, frames, &mut live)?,
                    Err(error) if !live.streaming => {
                        return Ok(HostOutcome::NoFirstFrame(error.to_string()))
                    }
                    Err(error) => return Err(error),
                }
                continue;
            }
        }
        let wait = if pending.is_some() && rotation.is_some() {
            due.min(POLL)
        } else {
            POLL
        };
        let failure = match images.recv_timeout(wait.max(Duration::from_millis(1))) {
            Ok(Ok(image)) => {
                pending = Some(image);
                continue;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Ok(Err(error)) => error,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                hbb_common::anyhow::anyhow!("the host screen source stopped")
            }
        };
        if !live.streaming {
            return Ok(HostOutcome::NoFirstFrame(failure.to_string()));
        }
        if reconnected {
            return Err(failure);
        }
        // One silent reconnect: restart the source and start a new encoder so
        // the next image is a keyframe.
        reconnected = true;
        log::info!("Host screen source dropped ({failure}); reconnecting");
        drop(feed);
        (feed, images) = start_feed()?;
        live.resubscribed(Instant::now());
        pending = None;
        last_image = None;
        encoder = None;
    }
}

/// Android's rotation can change after the last image was encoded (the
/// watcher lags the rotation animation). With no newer image waiting, the
/// last one is queued again so it goes through the geometry change.
fn requeue_on_rotation(
    pending: &mut Option<HostImage>,
    last_image: &mut Option<HostImage>,
    encoded_rotation: Option<u32>,
    rotation: u32,
) {
    if pending.is_none() && encoded_rotation.is_some_and(|encoded| encoded != rotation) {
        *pending = last_image.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_image(seq: u32) -> HostImage {
        HostImage {
            width: 2,
            height: 2,
            seq,
            pixels: vec![0; 16],
        }
    }

    #[test]
    fn a_still_screen_is_reencoded_when_the_rotation_changes() {
        // Encoded at rotation 0, Android now reports 1, nothing newer: requeue.
        let (mut pending, mut last) = (None, Some(feed_image(7)));
        requeue_on_rotation(&mut pending, &mut last, Some(0), 1);
        assert_eq!(pending.map(|image| image.seq), Some(7));
        assert!(last.is_none());
        // Same rotation: nothing to do.
        let (mut pending, mut last) = (None, Some(feed_image(7)));
        requeue_on_rotation(&mut pending, &mut last, Some(1), 1);
        assert!(pending.is_none() && last.is_some());
        // A newer image is already waiting: it carries the new rotation.
        let (mut pending, mut last) = (Some(feed_image(8)), Some(feed_image(7)));
        requeue_on_rotation(&mut pending, &mut last, Some(0), 1);
        assert_eq!(pending.map(|image| image.seq), Some(8));
        assert!(last.is_some());
        // Nothing encoded yet.
        let (mut pending, mut last) = (None, None);
        requeue_on_rotation(&mut pending, &mut last, None, 1);
        assert!(pending.is_none());
    }

    #[test]
    fn rotation_lines_parse_only_known_rotations() {
        assert_eq!(parse_rotation("r=mCurrentOrientation=1\r"), Some(1));
        assert_eq!(parse_rotation("r=mCurrentOrientation=3"), Some(3));
        assert_eq!(parse_rotation("r="), None);
        assert_eq!(parse_rotation("garbage"), None);
        // An unparsable line keeps the last rotation, but still counts as
        // the watcher's first report.
        let state = RotationState::new();
        assert_eq!(state.reading(), RotationReading { reported: false, rotation: None });
        state.apply("r=");
        assert_eq!(state.reading(), RotationReading { reported: true, rotation: None });
        state.apply("r=mCurrentOrientation=1");
        state.apply("garbage");
        state.apply("r=");
        assert_eq!(state.reading(), RotationReading { reported: true, rotation: Some(1) });
    }

    #[test]
    fn a_new_android_boot_is_noticed_and_is_not_a_rotation_report() {
        let state = RotationState::new();
        state.apply("b=8c1f-first");
        assert_eq!(state.reading(), RotationReading { reported: false, rotation: None });
        state.apply("r=mCurrentOrientation=1");
        // A restarted shell of the same boot (an adb hiccup).
        state.apply("b=8c1f-first");
        assert!(!state.guest_restarted());
        // A shell after `adb reboot`: Android booted again.
        state.apply("b=77aa-second");
        assert!(state.guest_restarted());
        assert_eq!(state.rotation(), Some(1));
        assert!(ROTATION_LOOP.starts_with("echo \"b=$(cat /proc/sys/kernel/random/boot_id)\""));
    }

    #[test]
    fn an_empty_boot_id_is_ignored() {
        let state = RotationState::new();
        state.apply("b=");
        state.apply("b=8c1f-first");
        state.apply("b=");
        assert!(!state.guest_restarted());
        state.apply("b=77aa-second");
        assert!(state.guest_restarted());
    }

    #[test]
    fn a_dead_watcher_keeps_the_last_rotation_and_restarts_throttled() {
        let state = RotationState::new();
        let stop = AtomicBool::new(false);
        let retry = Duration::from_millis(30);
        let mut restarts = Vec::new();
        let started = Instant::now();
        supervise(
            &state,
            &stop,
            std::io::Cursor::new(b"r=mCurrentOrientation=1\n".as_slice()),
            || {
                // The shell ended (EOF): the last rotation is kept.
                let last = if restarts.is_empty() { 1 } else { 3 };
                assert_eq!(state.rotation(), Some(last));
                restarts.push(started.elapsed());
                match restarts.len() {
                    1 => Ok(std::io::Cursor::new(b"r=mCurrentOrientation=3\n".as_slice())),
                    2 => bail!("adb is gone"),
                    _ => {
                        stop.store(true, Ordering::Release);
                        bail!("adb is gone")
                    }
                }
            },
            retry,
        );
        assert_eq!(state.rotation(), Some(3));
        assert_eq!(restarts.len(), 3);
        // At most one restart per `retry`, even when restarts fail at once.
        assert!(restarts[0] >= retry, "{restarts:?}");
        assert!(restarts[1] - restarts[0] >= retry, "{restarts:?}");
        assert!(restarts[2] - restarts[1] >= retry, "{restarts:?}");
    }

    #[test]
    fn the_first_encode_waits_for_the_first_rotation_report() {
        let unknown = RotationReading { reported: false, rotation: None };
        let short = Duration::from_millis(100);
        // Held while the watcher has not reported yet.
        assert_eq!(encode_rotation(Some((unknown, short))), None);
        // Released at 0 once the wait is over.
        assert_eq!(encode_rotation(Some((unknown, FIRST_ROTATION_WAIT))), Some(0));
        // A reading releases it at once.
        let landscape = RotationReading { reported: true, rotation: Some(1) };
        assert_eq!(encode_rotation(Some((landscape, short))), Some(1));
        // A build that never prints the orientation does not hold it.
        let silent = RotationReading { reported: true, rotation: None };
        assert_eq!(encode_rotation(Some((silent, short))), Some(0));
        // No watcher: unrotated, as before.
        assert_eq!(encode_rotation(None), Some(0));
    }

    #[test]
    fn a_resubscribed_feed_must_deliver_within_the_first_frame_timeout() {
        let start = Instant::now();
        let mut live = Liveness::new(start);
        assert!(live.check(start).unwrap().is_none());
        // Nothing before the first frame: fall back.
        assert!(matches!(
            live.check(start + FIRST_FRAME_TIMEOUT).unwrap(),
            Some(HostOutcome::NoFirstFrame(_))
        ));
        live.delivered();
        assert!(live.check(start + FIRST_FRAME_TIMEOUT * 3).unwrap().is_none());
        // Reconnected: the timeout applies again, and fails the session.
        let again = start + FIRST_FRAME_TIMEOUT * 3;
        live.resubscribed(again);
        assert!(live.check(again + FIRST_FRAME_TIMEOUT / 2).unwrap().is_none());
        assert!(live.check(again + FIRST_FRAME_TIMEOUT).is_err());
        live.delivered();
        assert!(live.check(again + FIRST_FRAME_TIMEOUT * 2).unwrap().is_none());
    }

    #[test]
    fn landscape_touch_maps_to_the_rotated_display() {
        // Rotation 1: the upright stream is 1280x576 and the helper injects
        // in the rotated 2400x1080 display.
        let space = display_touch_space((1080, 2400), (1280, 576));
        assert_eq!(space, (2400, 1080));
        assert_eq!(super::super::scale_touch(640, 1280, space.0), 1200);
        assert_eq!(super::super::scale_touch(288, 576, space.1), 540);
        assert_eq!(super::super::scale_touch(1279, 1280, space.0), 2398);
    }

    #[test]
    fn wm_size_prefers_the_override() {
        assert_eq!(parse_wm_size("Physical size: 1080x2400\n"), Some((1080, 2400)));
        assert_eq!(
            parse_wm_size("Physical size: 1080x2400\r\nOverride size: 720x1600\r\n"),
            Some((720, 1600))
        );
        assert_eq!(parse_wm_size("error"), None);
    }

    #[test]
    fn preview_settings_cap_at_thirty_fps_with_a_one_second_gop() {
        let preview = HostSettings::new(true);
        assert_eq!(
            preview,
            HostSettings {
                long_side: 360,
                fps: 30,
                bit_rate: 350_000,
                keyframe_frames: 30,
            }
        );
        assert_eq!(preview.min_gap(), Duration::from_millis(31));
        let fullscreen = HostSettings::new(false);
        assert_eq!(fullscreen.fps, 60);
        assert_eq!(fullscreen.keyframe_frames % 60, 0);
        assert_eq!(fullscreen.min_gap(), Duration::from_millis(14));
    }
}
