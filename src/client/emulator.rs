use super::*;
use crate::client::{get_hwcodec_config, VideoHandler};
use hbb_common::ResultType;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, SyncSender, TrySendError},
    Arc,
};

const GUEST_CHANNEL_BASE: usize = 0x40000000;
// Preserve short H.264 bursts, but do not let a slow decoder accumulate seconds of
// stale video. BlueStacks does not reliably emit periodic keyframes, so overload
// recovery asks the pinned guest helper to reset video and provide a fresh random-
// access boundary.
// Cover a 300-ms delivery burst with scheduling headroom; drain immediately.
const GUEST_VIDEO_QUEUE_SIZE: usize = 12;
const GUEST_VIDEO_REFRESH_RETRY: std::time::Duration = std::time::Duration::from_secs(1);

/// Longest full-screen edge accepted from the PC. It must cover the largest
/// `aperture-guest-max-size` (1920) and match `_guestStreamMaxEdge` in
/// `flutter/lib/models/emulator_model.dart`; a larger stream is ignored.
const GUEST_STREAM_MAX_EDGE: u32 = 2048;

fn is_guest_stream_size(width: u32, height: u32) -> bool {
    (1..=GUEST_STREAM_MAX_EDGE).contains(&width) && (1..=GUEST_STREAM_MAX_EDGE).contains(&height)
}

/// A received guest frame with when it arrived, for timing the phone side.
struct QueuedFrame {
    arrived: std::time::Instant,
    tap_ms: Option<f64>,
    frame: EmulatorVideoFrame,
}

pub(super) struct GuestVideoDecoder {
    sender: SyncSender<QueuedFrame>,
    /// Main stream only: time taps and log a timing summary.
    timed: bool,
    flush: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    waiting_key: bool,
    last_refresh: Option<std::time::Instant>,
}

impl GuestVideoDecoder {
    fn start<T: InvokeUiSession>(
        session: &Session<T>,
        channel: usize,
        timed: bool,
    ) -> ResultType<Self> {
        let (sender, receiver) = mpsc::sync_channel::<QueuedFrame>(GUEST_VIDEO_QUEUE_SIZE);
        let flush = Arc::new(AtomicBool::new(false));
        let worker_flush = flush.clone();
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = cancelled.clone();
        let ui = session.ui_handler.clone();
        std::thread::Builder::new()
            .name("emulator-decoder".to_owned())
            .spawn(move || {
                get_hwcodec_config();
                let mut decoder = VideoHandler::new(CodecFormat::H264, channel);
                let mut timing = crate::frame_timing::TimingWindow::new(
                    "Guest video (phone)",
                    std::time::Duration::from_secs(5),
                    std::time::Instant::now(),
                );
                let mut last_arrival: Option<std::time::Instant> = None;
                while let Ok(frame) = receiver.recv() {
                    if stop.load(Ordering::Acquire) {
                        break;
                    }
                    let mut frames = vec![frame];
                    let recovering = worker_flush.swap(false, Ordering::AcqRel);
                    if recovering {
                        while let Ok(frame) = receiver.try_recv() {
                            frames.push(frame);
                        }
                        decoder.reset(Some(CodecFormat::H264));
                        timing.count("flush");
                        let Some(key) = frames.iter().rposition(|queued| queued.frame.key) else {
                            continue;
                        };
                        frames.drain(..key);
                    } else {
                        while frames.len() < GUEST_VIDEO_QUEUE_SIZE {
                            let Ok(frame) = receiver.try_recv() else {
                                break;
                            };
                            frames.push(frame);
                        }
                    }
                    let decode_started = std::time::Instant::now();
                    if timed {
                        timing.sample("batch", frames.len() as f64);
                        for queued in &frames {
                            if let Some(previous) = last_arrival {
                                timing.sample(
                                    "arrival_gap",
                                    crate::frame_timing::ms(
                                        queued.arrived.saturating_duration_since(previous),
                                    ),
                                );
                            }
                            last_arrival = Some(queued.arrived);
                            timing.sample(
                                "queue",
                                crate::frame_timing::ms(
                                    decode_started.saturating_duration_since(queued.arrived),
                                ),
                            );
                            if let Some(tap_ms) = queued.tap_ms {
                                timing.sample("tap_to_frame", tap_ms);
                            }
                        }
                    }
                    let mut video = VideoFrame {
                        display: channel as i32,
                        ..Default::default()
                    };
                    video.set_h264s(EncodedVideoFrames {
                        frames: frames
                            .into_iter()
                            .map(|queued| EncodedVideoFrame {
                                data: queued.frame.data,
                                key: queued.frame.key,
                                pts: queued.frame.pts,
                                ..Default::default()
                            })
                            .collect(),
                        ..Default::default()
                    });
                    let mut pixels = true;
                    let result = decoder.handle_frame(video, &mut pixels, &mut None);
                    let decoded = std::time::Instant::now();
                    if timed {
                        timing.sample("decode", crate::frame_timing::ms(decoded - decode_started));
                    }
                    match result {
                        Ok(true) if !stop.load(Ordering::Acquire) => {
                            if pixels {
                                ui.on_rgba(channel, &mut decoder.rgb);
                            } else {
                                #[cfg(all(feature = "vram", feature = "flutter"))]
                                ui.on_texture(channel, decoder.texture.texture);
                            }
                            if timed {
                                timing.sample("present", crate::frame_timing::ms(decoded.elapsed()));
                            }
                        }
                        Err(error) => hbb_common::throttled_log!(
                            std::time::Duration::from_secs(5),
                            warn,
                            "Guest video decode failed: {error}"
                        ),
                        _ => {}
                    }
                    if timed {
                        if let Some(line) = timing.take_due(std::time::Instant::now()) {
                            log::info!("{line}");
                        }
                    }
                }
            })?;
        Ok(Self {
            sender,
            timed,
            flush,
            cancelled,
            waiting_key: true,
            last_refresh: None,
        })
    }

    fn push(&mut self, frame: EmulatorVideoFrame) -> bool {
        let arrived = std::time::Instant::now();
        let tap_ms = self
            .timed
            .then(|| crate::frame_timing::CLIENT_TAPS.take_latency(arrived))
            .flatten()
            .map(crate::frame_timing::ms);
        if self.waiting_key && !frame.key {
            return self.refresh_if_due();
        }
        let key = frame.key;
        match self.sender.try_send(QueuedFrame {
            arrived,
            tap_ms,
            frame,
        }) {
            Ok(()) => {
                if key {
                    self.waiting_key = false;
                    self.last_refresh = None;
                }
                false
            }
            Err(TrySendError::Full(_)) => {
                self.flush.store(true, Ordering::Release);
                self.waiting_key = true;
                self.refresh_if_due()
            }
            Err(TrySendError::Disconnected(_)) => {
                self.waiting_key = true;
                false
            }
        }
    }

    fn refresh_if_due(&mut self) -> bool {
        let due = self
            .last_refresh
            .map(|sent| sent.elapsed() >= GUEST_VIDEO_REFRESH_RETRY)
            .unwrap_or(true);
        if due {
            self.last_refresh = Some(std::time::Instant::now());
        }
        due
    }
}

impl Drop for GuestVideoDecoder {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashboard_preview_fps_restores_preference_without_saving_a_preview_cap() {
        let mut config = crate::client::LoginConfigHandler::default();
        config.config.options.insert("custom-fps".into(), "60".into());
        config.config.image_quality = "custom".into();
        config.last_auto_fps = Some(5);
        let message = config.set_dashboard_preview_mode(true);
        let Some(message::Union::Misc(misc)) = message.union else { panic!("missing FPS message") };
        let Some(misc::Union::Option(option)) = misc.union else { panic!("missing FPS option") };
        assert_eq!(option.custom_fps, 6);
        assert_eq!(*config.custom_fps.lock().unwrap(), Some(6));
        assert_eq!(config.config.options["custom-fps"], "60");
        config.set_dashboard_preview_mode(false);
        assert_eq!(*config.custom_fps.lock().unwrap(), Some(60));
        assert_eq!(config.last_auto_fps, None);
        config.config.image_quality = "balanced".into();
        config.set_dashboard_preview_mode(false);
        assert_eq!(*config.custom_fps.lock().unwrap(), Some(30));
    }


    #[test]
    fn the_full_screen_profile_fits_the_accepted_stream_size() {
        assert!(is_guest_stream_size(1080, 1920));
        assert!(is_guest_stream_size(1920, 886));
        assert!(is_guest_stream_size(2048, 944));
        assert!(!is_guest_stream_size(2049, 944));
        assert!(!is_guest_stream_size(944, 2049));
        assert!(!is_guest_stream_size(0, 720));
        assert!(!is_guest_stream_size(720, 0));
    }

    #[test]
    fn guest_video_preserves_references_during_a_short_delivery_burst() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
            timed: false,
            flush: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            waiting_key: true,
            last_refresh: None,
        };
        // Ten frames delivered together after a brief scheduling/delivery stall.
        for index in 0..10 {
            assert!(!decoder.push(EmulatorVideoFrame {
                pts: index * 33,
                key: index == 0,
                ..Default::default()
            }));
        }
        assert_eq!(
            std::iter::from_fn(|| receiver.try_recv().ok())
                .map(|queued| queued.frame.pts)
                .collect::<Vec<_>>(),
            (0..10).map(|index| index * 33).collect::<Vec<_>>(),
            "Losing a reference frame freezes playback until the next keyframe"
        );
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 330,
            ..Default::default()
        }));
        assert_eq!(receiver.try_recv().unwrap().frame.pts, 330);
    }

    #[test]
    fn guest_video_requests_refresh_when_decode_backlog_exceeds_limit() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
            timed: false,
            flush: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            waiting_key: true,
            last_refresh: None,
        };
        for index in 0..GUEST_VIDEO_QUEUE_SIZE {
            assert!(!decoder.push(EmulatorVideoFrame {
                pts: index as i64 * 33,
                key: index == 0,
                ..Default::default()
            }));
        }
        assert!(decoder.push(EmulatorVideoFrame {
            pts: GUEST_VIDEO_QUEUE_SIZE as i64 * 33,
            ..Default::default()
        }));
        assert!(decoder.waiting_key);
        assert!(decoder.flush.load(Ordering::Acquire));
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 999,
            ..Default::default()
        }));
        let _ = receiver.try_iter().count();
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 1_000,
            key: true,
            ..Default::default()
        }));
        assert!(!decoder.waiting_key);
        assert_eq!(receiver.try_recv().unwrap().frame.pts, 1_000);
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 1_033,
            ..Default::default()
        }));
        assert_eq!(receiver.try_recv().unwrap().frame.pts, 1_033);
    }

    #[tokio::test]
    async fn guest_video_ingest_does_not_block_when_decoder_is_busy() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
            timed: false,
            flush: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            waiting_key: true,
            last_refresh: None,
        };
        let enqueue = async {
            for index in 0..(GUEST_VIDEO_QUEUE_SIZE * 4) {
                let _ = decoder.push(EmulatorVideoFrame {
                    pts: index as i64 * 33,
                    key: true,
                    ..Default::default()
                });
            }
        };

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), enqueue)
                .await
                .is_ok(),
            "Guest video backpressure must not stall the shared session receive loop"
        );
        let queued = std::iter::from_fn(|| receiver.try_recv().ok()).count();
        assert!(
            queued <= GUEST_VIDEO_QUEUE_SIZE,
            "A stalled decoder must not retain an unbounded video backlog: {queued} frames"
        );
    }
}

impl crate::client::LoginConfigHandler {
    pub(crate) fn set_dashboard_preview_mode(&mut self, preview: bool) -> Message {
        let active_fps = if self.config.image_quality == "custom" {
            self.config.options.get("custom-fps")
                .and_then(|fps| fps.parse::<i32>().ok())
                .filter(|fps| (5..=120).contains(fps))
                .unwrap_or(30)
        } else {
            30
        };
        self.last_auto_fps = None;
        self.set_custom_fps(if preview { active_fps.min(6) } else { active_fps }, false)
    }
}

impl<T: InvokeUiSession> Session<T> {
    pub(crate) fn set_dashboard_preview_mode(&self, preview: bool) {
        let message = self.lc.write().unwrap().set_dashboard_preview_mode(preview);
        self.send(Data::Message(message));
    }
}

impl<T: InvokeUiSession> Remote<T> {
    fn request_guest_video_refresh(&self, session_id: u64) {
        if !self.guest_video_refresh_supported {
            return;
        }
        let mut request = EmulatorRequest {
            protocol_version: 1,
            session_id,
            ..Default::default()
        };
        request.set_refresh_video(base::message_proto::EmulatorVideoRefreshRequest::new());
        let mut message = Message::new();
        message.set_emulator_request(request);
        let _ = self.sender.send(Data::Message(message));
    }

    pub(super) fn handle_emulator_response(&mut self, response: EmulatorResponse) {
        let supported = self
            .handler
            .lc
            .read()
            .unwrap()
            .peer_info
            .as_ref()
            .and_then(|peer| peer.features.as_ref())
            .map(|features| features.emulator)
            .unwrap_or(false);
        if !supported || response.protocol_version != 1 {
            return;
        }
        if let Some(emulator_response::Union::Inventory(inventory)) = response.union.as_ref() {
            self.guest_video_refresh_supported = inventory
                .capabilities
                .iter()
                .any(|capability| capability == "guest.video_refresh.v1");
        }
        if let Some(emulator_response::Union::Previews(previews)) = response.union.as_ref() {
            self.dashboard_enabled = previews.enabled;
            self.guest_previews
                .retain(|id, _| previews.enabled && previews.session_ids.contains(id));
            for display in previews
                .displays
                .iter()
                .copied()
                .map(|display| display as usize)
            {
                if let Some(thread) = self.video_threads.get_mut(&display) {
                    while thread.video_queue.write().unwrap().pop().is_some() {}
                    *thread.discard_queue.write().unwrap() = true;
                    let _ = thread.video_sender.send(MediaData::Reset);
                    self.handler.refresh_video(display as _);
                }
            }
            self.handler.handle_emulator_response(response);
            return;
        }
        if let Some(emulator_response::Union::Status(status)) = response.union.as_ref() {
            if status.preview {
                if status.session_id == 0 || status.session_id > 0x001fffffffffffff {
                    return;
                }
                match status.state.enum_value_or_default() {
                    EmulatorSessionState::EmulatorStarting if self.guest_previews.len() < 4 => {
                        self.guest_previews.insert(status.session_id, None);
                    }
                    EmulatorSessionState::EmulatorStreaming
                        if self.guest_previews.contains_key(&status.session_id)
                            && status.width > 0
                            && status.height > 0
                            && status.width <= 360
                            && status.height <= 360 =>
                    {
                        let channel =
                            GUEST_CHANNEL_BASE | (status.session_id as usize & 0x3fffffff);
                        match GuestVideoDecoder::start(&self.handler, channel, false) {
                            Ok(decoder) => {
                                self.guest_previews.insert(status.session_id, Some(decoder));
                            }
                            Err(error) => {
                                let mut failed = response.clone();
                                if let Some(emulator_response::Union::Status(status)) =
                                    failed.union.as_mut()
                                {
                                    status.state = EmulatorSessionState::EmulatorFailed.into();
                                    status.error = format!("Could not decode preview: {error}");
                                }
                                self.handler.handle_emulator_response(failed);
                                return;
                            }
                        }
                    }
                    EmulatorSessionState::EmulatorFailed => {
                        self.guest_previews.remove(&status.session_id);
                    }
                    _ => return,
                }
                self.handler.handle_emulator_response(response);
                return;
            }
            match status.state.enum_value_or_default() {
                EmulatorSessionState::EmulatorStarting => {
                    if status.session_id == 0 || status.session_id > 0x001fffffffffffff {
                        return;
                    }
                    self.emulator_session_id = status.session_id;
                    self.guest_video.take();
                }
                EmulatorSessionState::EmulatorStreaming => {
                    if status.session_id != self.emulator_session_id
                        || !is_guest_stream_size(status.width, status.height)
                    {
                        return;
                    }
                    let channel = GUEST_CHANNEL_BASE | (status.session_id as usize & 0x3fffffff);
                    self.guest_video.take();
                    match GuestVideoDecoder::start(&self.handler, channel, true) {
                        Ok(decoder) => self.guest_video = Some(decoder),
                        Err(error) => {
                            let mut failed = response.clone();
                            if let Some(emulator_response::Union::Status(status)) =
                                failed.union.as_mut()
                            {
                                status.state = EmulatorSessionState::EmulatorFailed.into();
                                status.error =
                                    format!("Could not start guest video decoder: {error}");
                            }
                            self.handler.handle_emulator_response(failed);
                            return;
                        }
                    }
                }
                EmulatorSessionState::EmulatorDesktop => {
                    self.emulator_session_id = 0;
                    self.guest_video.take();
                    for thread in self.video_threads.values() {
                        let _ = thread.video_sender.send(MediaData::Reset);
                    }
                }
                EmulatorSessionState::EmulatorFailed => {
                    if status.session_id != self.emulator_session_id {
                        return;
                    }
                    self.guest_video.take();
                }
                _ => return,
            }
        }
        self.handler.handle_emulator_response(response);
    }

    pub(super) async fn handle_emulator_video(&mut self, frame: EmulatorVideoFrame) {
        if !frame.data.is_empty() && frame.data.len() <= 8 * 1024 * 1024 {
            let session_id = frame.session_id;
            if let Some(Some(decoder)) = self.guest_previews.get_mut(&frame.session_id) {
                let refresh = decoder.push(frame);
                if refresh {
                    self.request_guest_video_refresh(session_id);
                }
                return;
            }
        }
        if self.emulator_session_id == 0
            || frame.session_id != self.emulator_session_id
            || frame.data.is_empty()
            || frame.data.len() > 8 * 1024 * 1024
        {
            return;
        }
        if let Some(decoder) = self.guest_video.as_mut() {
            let session_id = frame.session_id;
            let refresh = decoder.push(frame);
            if refresh {
                self.request_guest_video_refresh(session_id);
            }
        }
    }
}
