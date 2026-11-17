//! Host-GPU video for Google's Android Emulator. The emulator's own screen
//! feed (`avd_feed`) is encoded on this PC (`avd_video`) while a control-only
//! helper carries input. When the host path cannot deliver a first frame, the
//! session falls back to the in-Android helper video.
//!
//! A child module of `remote_windows`: it reuses that module's private session
//! machinery (geometry, input worker, watchdog and frame backpressure).

use super::super::{
    avd_feed::{self, FeedImage, ScreenFeed},
    avd_video::{
        even_size, orient_rgba, stream_box, upright_rgba, EncodedHostFrame, HostEncoder, BOTTOM_UP,
    },
    guest_runtime::{adb_command, GuestHelper, GuestStreamProfile},
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
    process::{Child, Command, Stdio},
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

/// One guest shell for the whole session. It prints Android's display
/// rotation every 250 ms; printing every tick also ends the loop (SIGPIPE)
/// soon after the adb client is gone.
const ROTATION_LOOP: &str = "while :; do r=$(dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentOrientation=[0-3]'); echo \"r=$r\" || exit; sleep 0.25; done";
const ROTATION_UNKNOWN: u8 = u8::MAX;

/// The rotation in one line of `ROTATION_LOOP`.
fn parse_rotation(line: &str) -> Option<u8> {
    let value = line.trim().strip_prefix("r=mCurrentOrientation=")?;
    value.parse::<u8>().ok().filter(|rotation| *rotation < 4)
}

/// Watches the guest's display rotation through one persistent `adb shell`.
/// The emulator feed keeps the portrait panel, so the host turns frames
/// upright itself. Killed (and joined) on drop.
pub(super) struct RotationWatcher {
    child: Child,
    reader: Option<thread::JoinHandle<()>>,
    rotation: Arc<AtomicU8>,
}

impl RotationWatcher {
    pub(super) fn start(adb: &Path, serial: &str) -> ResultType<Self> {
        let mut child = Command::new(adb)
            .creation_flags(0x08000000)
            .args(["-s", serial, "shell", ROTATION_LOOP])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let Some(stdout) = child.stdout.take() else {
            let _ = child.kill();
            let _ = child.wait();
            bail!("the rotation watcher has no output")
        };
        let rotation = Arc::new(AtomicU8::new(ROTATION_UNKNOWN));
        let shared = rotation.clone();
        let reader = thread::Builder::new()
            .name("emulator-rotation".to_owned())
            .spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    let rotation = parse_rotation(&line).unwrap_or(ROTATION_UNKNOWN);
                    shared.store(rotation, Ordering::Release);
                }
                shared.store(ROTATION_UNKNOWN, Ordering::Release);
            });
        match reader {
            Ok(reader) => Ok(Self {
                child,
                reader: Some(reader),
                rotation,
            }),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(error.into())
            }
        }
    }

    /// Android's current display rotation (0-3), if known.
    pub(super) fn rotation(&self) -> Option<u32> {
        let rotation = self.rotation.load(Ordering::Acquire);
        (rotation != ROTATION_UNKNOWN).then_some(u32::from(rotation))
    }
}

impl Drop for RotationWatcher {
    fn drop(&mut self) {
        if let Err(error) = self.child.kill() {
            log::trace!("Rotation watcher kill: {error}");
        }
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

/// The rotation to turn frames upright with: 0 when unknown (logged).
fn current_rotation(watcher: Option<&RotationWatcher>) -> u32 {
    match watcher.and_then(RotationWatcher::rotation) {
        Some(rotation) => rotation,
        None => {
            hbb_common::throttled_log!(
                Duration::from_secs(60),
                warn,
                "AVD display rotation unknown; streaming the emulator screen unrotated"
            );
            0
        }
    }
}

/// Test hook: the AVD name given to `discover`, to force discovery to fail.
#[cfg(test)]
pub(super) static FEED_AVD_OVERRIDE: Mutex<Option<String>> = Mutex::new(None);
/// Test evidence: host-path streams that reached `stream_ready`.
#[cfg(test)]
pub(super) static HOST_STREAMS_READY: AtomicUsize = AtomicUsize::new(0);

fn feed_avd_name(avd: &str) -> String {
    #[cfg(test)]
    if let Some(name) = FEED_AVD_OVERRIDE.lock().unwrap().clone() {
        return name;
    }
    avd.to_owned()
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
    /// The AVD name (the provider instance id).
    pub(super) avd: &'a str,
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
        let profile = GuestStreamProfile::for_android_emulator(preview);
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
        log::warn!("AVD host video unavailable, using in-Android video: {reason}");
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
            log::warn!("AVD rotation watcher unavailable: {error}");
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

/// Delivers the encoder's output; `streaming` turns true with the first frame.
fn deliver(
    sender: &mut FrameSender,
    frames: Vec<EncodedHostFrame>,
    streaming: &mut bool,
) -> ResultType<()> {
    for frame in frames.into_iter().filter(|frame| !frame.data.is_empty()) {
        let _became_ready = sender.send(frame.data, frame.key, frame.pts)?;
        #[cfg(test)]
        if _became_ready {
            HOST_STREAMS_READY.fetch_add(1, Ordering::AcqRel);
        }
        *streaming = true;
    }
    Ok(())
}

/// Feed -> host encoder -> session. `NoFirstFrame` when nothing was delivered
/// within `FIRST_FRAME_TIMEOUT` (or the feed or encoder failed before that).
fn host_video_loop(video: &HostVideo) -> ResultType<HostOutcome> {
    let session = video.session;
    let avd = feed_avd_name(session.avd);
    let (box_width, box_height) = stream_box(video.settings.long_side);
    let start_feed = || -> ResultType<(ScreenFeed, Receiver<ResultType<FeedImage>>)> {
        ScreenFeed::start(avd_feed::discover(&avd)?, box_width, box_height)
    };
    let (mut feed, mut images) = match start_feed() {
        Ok(started) => started,
        Err(error) => return Ok(HostOutcome::NoFirstFrame(error.to_string())),
    };
    let subscribed = Instant::now();
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
    // A frame has been delivered: the host path is live.
    let mut streaming = false;
    let mut encoder: Option<HostEncoder> = None;
    // The upright stream size and the rotation it was turned by.
    let mut size: Option<(u32, u32, u32)> = None;
    let mut pending: Option<FeedImage> = None;
    // The last encoded image, re-encoded if Android's rotation moves on
    // while the screen is still.
    let mut last_image: Option<FeedImage> = None;
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
        if !streaming && subscribed.elapsed() >= FIRST_FRAME_TIMEOUT {
            return Ok(HostOutcome::NoFirstFrame(format!(
                "no frame within {} s",
                FIRST_FRAME_TIMEOUT.as_secs()
            )));
        }
        if video.reset.swap(false, Ordering::AcqRel) {
            if let Some(active) = encoder.as_mut() {
                match active.force_key() {
                    Ok(frames) => deliver(&mut sender, frames, &mut streaming)?,
                    Err(error) if !streaming => {
                        return Ok(HostOutcome::NoFirstFrame(error.to_string()))
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        requeue_on_rotation(
            &mut pending,
            &mut last_image,
            size.map(|(_, _, rotation)| rotation),
            current_rotation(video.rotation),
        );
        let due = last_encode
            .map(|last| min_gap.saturating_sub(last.elapsed()))
            .unwrap_or(Duration::ZERO);
        if due.is_zero() {
            if let Some(image) = pending.take() {
                let (feed_width, feed_height) = even_size(image.width, image.height);
                if feed_width == 0 || feed_height == 0 {
                    continue;
                }
                let rotation = current_rotation(video.rotation);
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
                    Ok(frames) => deliver(&mut sender, frames, &mut streaming)?,
                    Err(error) if !streaming => {
                        return Ok(HostOutcome::NoFirstFrame(error.to_string()))
                    }
                    Err(error) => return Err(error),
                }
                continue;
            }
        }
        let wait = if pending.is_some() { due.min(POLL) } else { POLL };
        let failure = match images.recv_timeout(wait.max(Duration::from_millis(1))) {
            Ok(Ok(image)) => {
                pending = Some(image);
                continue;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Ok(Err(error)) => error,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                hbb_common::anyhow::anyhow!("the screen feed stopped")
            }
        };
        if !streaming {
            return Ok(HostOutcome::NoFirstFrame(failure.to_string()));
        }
        if reconnected {
            return Err(failure);
        }
        // One silent reconnect: re-read the discovery file, re-subscribe and
        // start a new encoder so the next image is a keyframe.
        reconnected = true;
        log::info!("AVD screen feed dropped ({failure}); reconnecting");
        drop(feed);
        (feed, images) = start_feed()?;
        pending = None;
        last_image = None;
        encoder = None;
    }
}

/// Android's rotation can change after the last image was encoded (the
/// watcher lags the rotation animation). With no newer image waiting, the
/// last one is queued again so it goes through the geometry change.
fn requeue_on_rotation(
    pending: &mut Option<FeedImage>,
    last_image: &mut Option<FeedImage>,
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

    fn feed_image(seq: u32) -> FeedImage {
        FeedImage {
            width: 2,
            height: 2,
            rotation: 0,
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
