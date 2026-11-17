//! Host-side H.264 encoding of the emulator's own screen feed.
//!
//! The feed (`avd_feed`) yields RGBA frames; this module crops them to even
//! dimensions, converts to NV12 and encodes them with the host's hardware
//! encoder (NVENC on the target machine). It also owns the global budget of
//! host encoders so previews never starve a full-screen session.

use super::avd_feed::FeedImage;
use hbb_common::{bail, ResultType};
use scrap::{
    codec::{EncoderApi, EncoderCfg},
    convert_to_yuv,
    hwcodec::{HwRamEncoder, HwRamEncoderConfig},
    ARGBRotate, CodecFormat, PixelBuffer, Pixfmt, RotationMode,
};
use std::{
    os::raw::c_int,
    sync::atomic::{AtomicUsize, Ordering},
};

/// Rows of the emulator feed are delivered top-down (Task 3 ruling).
pub const BOTTOM_UP: bool = false;

/// Most host encoders alive at once.
const MAX_ENCODERS: usize = 6;
/// Previews may only take a slot while fewer than this many are in use.
const PREVIEW_LIMIT: usize = 4;

/// The square the feed fits the emulator screen into; it keeps aspect.
pub fn stream_box(long_side: u32) -> (u32, u32) {
    (long_side, long_side)
}

/// Rounds each dimension down to an even number (H.264 4:2:0).
pub fn even_size(width: u32, height: u32) -> (u32, u32) {
    (width & !1, height & !1)
}

/// Crops the image to `even_size` and, when `bottom_up`, flips the rows.
pub fn orient_rgba(image: &FeedImage, bottom_up: bool) -> Vec<u8> {
    let (w, h) = even_size(image.width, image.height);
    let (w, h) = (w as usize, h as usize);
    let src_stride = image.width as usize * 4;
    let row = w * 4;
    let mut out = Vec::with_capacity(row * h);
    for y in 0..h {
        let sy = if bottom_up { h - 1 - y } else { y };
        let start = sy * src_stride;
        out.extend_from_slice(&image.pixels[start..start + row]);
    }
    out
}

/// Turns an RGBA frame captured at Android display `rotation` (0-3, the
/// emulator feed keeps the portrait panel) upright. Rotations 1 and 3 swap
/// width and height. Returns the frame and its new size.
pub fn upright_rgba(
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    rotation: u32,
) -> ResultType<(Vec<u8>, u32, u32)> {
    let mode = match rotation % 4 {
        0 => return Ok((rgba, width, height)),
        // Android rotation 1 draws the landscape UI turned clockwise.
        1 => RotationMode::kRotate270,
        2 => RotationMode::kRotate180,
        _ => RotationMode::kRotate90,
    };
    if rgba.len() as u64 != u64::from(width) * u64::from(height) * 4 {
        bail!("Frame is {} bytes, expected {width}x{height} RGBA", rgba.len());
    }
    let (out_width, out_height) = if rotation % 2 == 1 {
        (height, width)
    } else {
        (width, height)
    };
    let mut out = vec![0u8; rgba.len()];
    // SAFETY: both buffers hold width * height 4-byte pixels and the strides
    // match their row widths; libyuv rotates 32-bit pixels whatever their
    // channel order.
    let result = unsafe {
        ARGBRotate(
            rgba.as_ptr(),
            (width * 4) as c_int,
            out.as_mut_ptr(),
            (out_width * 4) as c_int,
            width as c_int,
            height as c_int,
            mode,
        )
    };
    if result != 0 {
        bail!("Rotating the emulator frame failed ({result})");
    }
    Ok((out, out_width, out_height))
}

static IN_USE: AtomicUsize = AtomicUsize::new(0);

pub struct EncoderBudget;

impl EncoderBudget {
    /// Takes an encoder slot, or `None` when the budget is spent. Previews
    /// only get one while fewer than `PREVIEW_LIMIT` slots are in use.
    pub fn try_acquire(preview: bool) -> Option<EncoderSlot> {
        let limit = if preview { PREVIEW_LIMIT } else { MAX_ENCODERS };
        IN_USE
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < limit).then_some(n + 1)
            })
            .ok()
            .map(|_| EncoderSlot { _private: () })
    }
}

/// One host-encoder slot, released on drop.
#[derive(Debug)]
pub struct EncoderSlot {
    _private: (),
}

impl Drop for EncoderSlot {
    fn drop(&mut self) {
        IN_USE.fetch_sub(1, Ordering::SeqCst);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedHostFrame {
    pub data: Vec<u8>,
    pub key: bool,
    pub pts: i64,
}

/// Quality ratio for which the encoder's bitrate lands on `bit_rate` bps.
/// `HwRamEncoder::calc_bitrate` is not linear in the ratio, so the ratio is
/// found by bisection (the function is monotonic).
fn quality_for(bit_rate: u32, width: usize, height: usize) -> f32 {
    let target = (bit_rate / 1000).max(1) as f32;
    let (mut lo, mut hi) = (0.001_f32, 64.0_f32);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if (HwRamEncoder::calc_bitrate(width, height, mid, true) as f32) < target {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    (lo + hi) / 2.0
}

pub struct HostEncoder {
    encoder: HwRamEncoder,
    config: HwRamEncoderConfig,
    width: u32,
    height: u32,
    last: Option<(Vec<u8>, i64)>,
    frames: u64,
    yuv: Vec<u8>,
    mid: Vec<u8>,
    // Last field: the encoder is dropped before its slot is released.
    _slot: EncoderSlot,
}

impl HostEncoder {
    pub fn new(
        width: u32,
        height: u32,
        bit_rate: u32,
        keyframe_frames: usize,
        preview: bool,
    ) -> ResultType<HostEncoder> {
        let Some(info) = HwRamEncoder::try_get(CodecFormat::H264) else {
            bail!("No hardware H.264 encoder");
        };
        Self::with_codec(info.name, width, height, bit_rate, keyframe_frames, preview)
    }

    /// Private seam: `new` plus an explicit ffmpeg codec name.
    fn with_codec(
        name: String,
        width: u32,
        height: u32,
        bit_rate: u32,
        keyframe_frames: usize,
        preview: bool,
    ) -> ResultType<HostEncoder> {
        if width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 {
            bail!("Host encoder needs even, non-zero dimensions, got {width}x{height}");
        }
        let Some(slot) = EncoderBudget::try_acquire(preview) else {
            bail!("Hardware encoder budget is full");
        };
        let config = HwRamEncoderConfig {
            name,
            mc_name: None,
            width: width as usize,
            height: height as usize,
            quality: quality_for(bit_rate, width as usize, height as usize),
            keyframe_interval: Some(keyframe_frames),
        };
        let encoder = HwRamEncoder::new(EncoderCfg::HWRAM(config.clone()), false)?;
        Ok(HostEncoder {
            encoder,
            config,
            width,
            height,
            last: None,
            frames: 0,
            yuv: Vec::new(),
            mid: Vec::new(),
            _slot: slot,
        })
    }

    /// Frames fed to the encoder so far.
    pub fn frame_count(&self) -> u64 {
        self.frames
    }

    /// Encodes one oriented RGBA frame (`width * height * 4` bytes); `pts_ms`
    /// is passed to the encoder unchanged.
    pub fn encode(&mut self, rgba: Vec<u8>, pts_ms: i64) -> ResultType<Vec<EncodedHostFrame>> {
        let out = self.encode_ref(&rgba, pts_ms)?;
        self.last = Some((rgba, pts_ms));
        Ok(out)
    }

    fn encode_ref(&mut self, rgba: &[u8], pts_ms: i64) -> ResultType<Vec<EncodedHostFrame>> {
        let (w, h) = (self.width as usize, self.height as usize);
        if rgba.len() != w * h * 4 {
            bail!(
                "Frame is {} bytes, expected {} for {w}x{h} RGBA",
                rgba.len(),
                w * h * 4
            );
        }
        let buffer = PixelBuffer::new(rgba, Pixfmt::RGBA, w, h);
        convert_to_yuv(&buffer, self.encoder.yuvfmt(), &mut self.yuv, &mut self.mid)?;
        let frames = self.encoder.encode(&self.yuv, pts_ms)?;
        self.frames += 1;
        Ok(frames
            .into_iter()
            .map(|f| EncodedHostFrame {
                data: f.data,
                key: f.key == 1,
                pts: f.pts,
            })
            .collect())
    }

    /// Re-creates the encoder (keeping the budget slot) and re-encodes the
    /// last image, so the first returned frame is a keyframe.
    pub fn force_key(&mut self) -> ResultType<Vec<EncodedHostFrame>> {
        let Some((rgba, pts)) = self.last.take() else {
            return Ok(Vec::new());
        };
        self.encoder = HwRamEncoder::new(EncoderCfg::HWRAM(self.config.clone()), false)?;
        let out = self.encode_ref(&rgba, pts);
        self.last = Some((rgba, pts));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The slot counter is global; every test that touches it holds this.
    static BUDGET_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        BUDGET_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn image(width: u32, height: u32, pixels: Vec<u8>) -> FeedImage {
        FeedImage {
            width,
            height,
            rotation: 0,
            seq: 0,
            pixels,
        }
    }

    #[test]
    fn even_crop_drops_last_column_and_row() {
        assert_eq!(even_size(577, 1281), (576, 1280));
        assert_eq!(stream_box(1280), (1280, 1280));
        // 3x3 image, pixel i has all four bytes == i.
        let pixels: Vec<u8> = (0..9u8).flat_map(|i| [i; 4]).collect();
        let out = orient_rgba(&image(3, 3, pixels), false);
        assert_eq!(out.len(), 2 * 2 * 4);
        let expect: Vec<u8> = [0u8, 1, 3, 4].iter().flat_map(|&i| [i; 4]).collect();
        assert_eq!(out, expect);
    }

    #[test]
    fn orient_rgba_flips_bottom_up_rows() {
        let top = [1u8; 8];
        let bottom = [2u8; 8];
        let pixels: Vec<u8> = top.iter().chain(bottom.iter()).copied().collect();
        let img = image(2, 2, pixels.clone());
        assert_eq!(orient_rgba(&img, false), pixels);
        let flipped: Vec<u8> = bottom.iter().chain(top.iter()).copied().collect();
        assert_eq!(orient_rgba(&img, true), flipped);
    }

    #[test]
    fn upright_rgba_rotates_each_android_rotation() {
        // 2x3 image, pixel i has all four bytes == i:
        //   0 1
        //   2 3
        //   4 5
        let pixels: Vec<u8> = (0..6u8).flat_map(|i| [i; 4]).collect();
        let ids = |out: &[u8]| out.chunks(4).map(|p| p[0]).collect::<Vec<_>>();
        let (out, w, h) = upright_rgba(pixels.clone(), 2, 3, 0).unwrap();
        assert_eq!((ids(&out), w, h), (vec![0, 1, 2, 3, 4, 5], 2, 3));
        // Rotation 1: turn counter-clockwise.
        let (out, w, h) = upright_rgba(pixels.clone(), 2, 3, 1).unwrap();
        assert_eq!((ids(&out), w, h), (vec![1, 3, 5, 0, 2, 4], 3, 2));
        let (out, w, h) = upright_rgba(pixels.clone(), 2, 3, 2).unwrap();
        assert_eq!((ids(&out), w, h), (vec![5, 4, 3, 2, 1, 0], 2, 3));
        // Rotation 3: turn clockwise.
        let (out, w, h) = upright_rgba(pixels.clone(), 2, 3, 3).unwrap();
        assert_eq!((ids(&out), w, h), (vec![4, 2, 0, 5, 3, 1], 3, 2));
        assert!(upright_rgba(vec![0; 8], 2, 3, 1).is_err());
    }

    #[test]
    fn budget_keeps_two_for_fullscreen() {
        let _g = lock();
        let mut held: Vec<EncoderSlot> = (0..4)
            .map(|_| EncoderBudget::try_acquire(false).expect("full-screen slot"))
            .collect();
        assert!(EncoderBudget::try_acquire(true).is_none());
        held.push(EncoderBudget::try_acquire(false).expect("fifth"));
        held.push(EncoderBudget::try_acquire(false).expect("sixth"));
        assert!(EncoderBudget::try_acquire(true).is_none());
        assert!(EncoderBudget::try_acquire(false).is_none());
        held.pop();
        assert!(EncoderBudget::try_acquire(false).is_some());
        drop(held);
        assert!(EncoderBudget::try_acquire(true).is_some());
    }

    #[test]
    fn quality_ratio_lands_on_requested_bitrate() {
        for (w, h, bps) in [(576usize, 1280usize, 4_000_000u32), (202, 360, 350_000)] {
            let q = quality_for(bps, w, h);
            let got = HwRamEncoder::calc_bitrate(w, h, q, true) as f32;
            let want = (bps / 1000) as f32;
            assert!((got - want).abs() / want < 0.01, "{w}x{h}: {got} vs {want}");
        }
    }

    fn nvenc(w: u32, h: u32) -> HostEncoder {
        HostEncoder::with_codec("h264_nvenc".to_owned(), w, h, 4_000_000, 60, false)
            .expect("h264_nvenc encoder")
    }

    fn nal_types(data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0;
        while i + 3 < data.len() {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                out.push(data[i + 3] & 0x1f);
                i += 3;
            } else {
                i += 1;
            }
        }
        out
    }

    #[test]
    #[ignore = "needs an NVIDIA GPU"]
    fn real_nvenc_first_frame_is_key_with_sps() {
        let _g = lock();
        let mut enc = nvenc(576, 1280);
        let grey = vec![128u8; 576 * 1280 * 4];
        let frames = enc.encode(grey, 0).expect("encode");
        let first = frames.first().expect("a frame");
        assert!(first.key);
        let nals = nal_types(&first.data);
        let sps = nals.iter().position(|&t| t == 7).expect("SPS");
        let idr = nals.iter().position(|&t| t == 5).expect("IDR");
        assert!(sps < idr);
    }

    #[test]
    #[ignore = "needs an NVIDIA GPU"]
    fn reset_video_reencodes_last_image_as_key() {
        let _g = lock();
        let mut enc = nvenc(576, 1280);
        for i in 0..10u8 {
            let frame = vec![i.wrapping_mul(20); 576 * 1280 * 4];
            enc.encode(frame, i as i64 * 16).expect("encode");
        }
        let before = IN_USE.load(std::sync::atomic::Ordering::SeqCst);
        let frames = enc.force_key().expect("force_key");
        assert_eq!(IN_USE.load(std::sync::atomic::Ordering::SeqCst), before);
        assert!(frames.first().expect("a frame").key);
        assert!(nal_types(&frames[0].data).contains(&7));
    }
}
