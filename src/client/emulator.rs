use super::*;
use crate::client::{get_hwcodec_config, VideoHandler};
use hbb_common::ResultType;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, SyncSender, TrySendError},
};

const GUEST_CHANNEL_BASE: usize = 0x40000000;
// Absorb short delivery bursts without losing H.264 reference frames. The worker
// drains the available burst immediately and presents its newest decoded image.
const GUEST_VIDEO_QUEUE_SIZE: usize = 8;

pub(super) struct GuestVideoDecoder {
    sender: SyncSender<EmulatorVideoFrame>,
    cancelled: Arc<AtomicBool>,
    waiting_key: bool,
}

impl GuestVideoDecoder {
    fn start<T: InvokeUiSession>(session: &Session<T>, channel: usize) -> ResultType<Self> {
        let (sender, receiver) = mpsc::sync_channel::<EmulatorVideoFrame>(GUEST_VIDEO_QUEUE_SIZE);
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
                    let mut video = VideoFrame {
                        display: channel as i32,
                        ..Default::default()
                    };
                    video.set_h264s(EncodedVideoFrames {
                        frames: std::iter::once(frame)
                            .chain(receiver.try_iter())
                            .take(GUEST_VIDEO_QUEUE_SIZE)
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
            cancelled,
            waiting_key: true,
        })
    }

    fn push(&mut self, frame: EmulatorVideoFrame) {
        if self.waiting_key && !frame.key {
            return;
        }
        let key = frame.key;
        match self.sender.try_send(frame) {
            Ok(()) => {
                if key {
                    self.waiting_key = false;
                }
            }
            Err(TrySendError::Full(_)) => {
                self.waiting_key = true;
                hbb_common::throttled_log!(
                    std::time::Duration::from_secs(5),
                    warn,
                    "Guest video decoder queue full; waiting for a keyframe"
                );
            }
            Err(TrySendError::Disconnected(_)) => self.waiting_key = true,
        }
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
            cancelled: Arc::new(AtomicBool::new(false)),
            waiting_key: true,
        };
        // Six frames delivered together after 200 ms of network/scheduling jitter.
        for index in 0..6 {
            decoder.push(EmulatorVideoFrame {
                pts: index * 33,
                key: index == 0,
                ..Default::default()
            });
        }
        assert_eq!(
            receiver
                .try_iter()
                .map(|frame| frame.pts)
                .collect::<Vec<_>>(),
            vec![0, 33, 66, 99, 132, 165],
            "Losing a reference frame freezes playback until the next keyframe"
        );
        decoder.push(EmulatorVideoFrame {
            pts: 198,
            ..Default::default()
        });
        assert_eq!(receiver.try_recv().unwrap().pts, 198);
    }
}

impl<T: InvokeUiSession> Remote<T> {
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
        if let Some(emulator_response::Union::Previews(previews)) = response.union.as_ref() {
            self.dashboard_enabled = previews.enabled;
            self.guest_previews.retain(|id, _| previews.enabled && previews.session_ids.contains(id));
            self.handler.handle_emulator_response(response);
            return;
        }
        if let Some(emulator_response::Union::Status(status)) = response.union.as_ref() {
            if status.preview {
                if status.session_id == 0 || status.session_id > 0x001fffffffffffff { return; }
                match status.state.enum_value_or_default() {
                    EmulatorSessionState::EmulatorStarting if self.guest_previews.len() < 4 => {
                        self.guest_previews.insert(status.session_id, None);
                    }
                    EmulatorSessionState::EmulatorStreaming if self.guest_previews.contains_key(&status.session_id) && status.width > 0 && status.height > 0 && status.width <= 360 && status.height <= 360 => {
                        let channel = GUEST_CHANNEL_BASE | (status.session_id as usize & 0x3fffffff);
                        match GuestVideoDecoder::start(&self.handler, channel) {
                            Ok(decoder) => { self.guest_previews.insert(status.session_id, Some(decoder)); }
                            Err(error) => {
                                let mut failed = response.clone();
                                if let Some(emulator_response::Union::Status(status)) = failed.union.as_mut() {
                                    status.state = EmulatorSessionState::EmulatorFailed.into();
                                    status.error = format!("Could not decode preview: {error}");
                                }
                                self.handler.handle_emulator_response(failed);
                                return;
                            }
                        }
                    }
                    EmulatorSessionState::EmulatorFailed => { self.guest_previews.remove(&status.session_id); }
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

    pub(super) fn handle_emulator_video(&mut self, frame: EmulatorVideoFrame) {
        if !frame.data.is_empty() && frame.data.len() <= 8 * 1024 * 1024 {
            if let Some(Some(decoder)) = self.guest_previews.get_mut(&frame.session_id) {
                decoder.push(frame);
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
            decoder.push(frame);
        }
    }
}
