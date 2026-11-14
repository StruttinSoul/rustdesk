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
const GUEST_VIDEO_QUEUE_SIZE: usize = 8;
const GUEST_VIDEO_REFRESH_RETRY: std::time::Duration = std::time::Duration::from_secs(1);

pub(super) struct GuestVideoDecoder {
    sender: SyncSender<EmulatorVideoFrame>,
    flush: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    waiting_key: bool,
    last_refresh: Option<std::time::Instant>,
}

impl GuestVideoDecoder {
    fn start<T: InvokeUiSession>(session: &Session<T>, channel: usize) -> ResultType<Self> {
        let (sender, receiver) = mpsc::sync_channel::<EmulatorVideoFrame>(GUEST_VIDEO_QUEUE_SIZE);
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
                        let Some(key) = frames.iter().rposition(|frame| frame.key) else {
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
                    let mut video = VideoFrame {
                        display: channel as i32,
                        ..Default::default()
                    };
                    video.set_h264s(EncodedVideoFrames {
                        frames: frames
                            .into_iter()
                            .map(|frame| EncodedVideoFrame {
                                data: frame.data,
                                key: frame.key,
                                pts: frame.pts,
                                ..Default::default()
                            })
                            .collect(),
                        ..Default::default()
                    });
                    let mut pixels = true;
                    match decoder.handle_frame(video, &mut pixels, &mut None) {
                        Ok(true) if !stop.load(Ordering::Acquire) => {
                            if pixels {
                                ui.on_rgba(channel, &mut decoder.rgb);
                            } else {
                                #[cfg(all(feature = "vram", feature = "flutter"))]
                                ui.on_texture(channel, decoder.texture.texture);
                            }
                        }
                        Err(error) => hbb_common::throttled_log!(
                            std::time::Duration::from_secs(5),
                            warn,
                            "Guest video decode failed: {error}"
                        ),
                        _ => {}
                    }
                }
            })?;
        Ok(Self {
            sender,
            flush,
            cancelled,
            waiting_key: true,
            last_refresh: None,
        })
    }

    fn push(&mut self, frame: EmulatorVideoFrame) -> bool {
        if self.waiting_key && !frame.key {
            return self.refresh_if_due();
        }
        let key = frame.key;
        match self.sender.try_send(frame) {
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
    fn guest_video_preserves_references_during_a_short_delivery_burst() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
            flush: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            waiting_key: true,
            last_refresh: None,
        };
        // Six frames delivered together after 200 ms of network/scheduling jitter.
        for index in 0..6 {
            assert!(!decoder.push(EmulatorVideoFrame {
                pts: index * 33,
                key: index == 0,
                ..Default::default()
            }));
        }
        assert_eq!(
            std::iter::from_fn(|| receiver.try_recv().ok())
                .map(|frame| frame.pts)
                .collect::<Vec<_>>(),
            vec![0, 33, 66, 99, 132, 165],
            "Losing a reference frame freezes playback until the next keyframe"
        );
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 198,
            ..Default::default()
        }));
        assert_eq!(receiver.try_recv().unwrap().pts, 198);
    }

    #[test]
    fn guest_video_requests_refresh_when_decode_backlog_exceeds_limit() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
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
        assert_eq!(receiver.try_recv().unwrap().pts, 1_000);
        assert!(!decoder.push(EmulatorVideoFrame {
            pts: 1_033,
            ..Default::default()
        }));
        assert_eq!(receiver.try_recv().unwrap().pts, 1_033);
    }

    #[tokio::test]
    async fn guest_video_ingest_does_not_block_when_decoder_is_busy() {
        let (sender, receiver) = mpsc::sync_channel(GUEST_VIDEO_QUEUE_SIZE);
        let mut decoder = GuestVideoDecoder {
            sender,
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
                        match GuestVideoDecoder::start(&self.handler, channel) {
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
                        || status.width == 0
                        || status.height == 0
                        || status.width > 1280
                        || status.height > 1280
                    {
                        return;
                    }
                    let channel = GUEST_CHANNEL_BASE | (status.session_id as usize & 0x3fffffff);
                    self.guest_video.take();
                    match GuestVideoDecoder::start(&self.handler, channel) {
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
