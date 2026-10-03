use std::io::{self, Read};

pub const HELPER_VERSION: &str = "4.0";
pub const HELPER_SHA256: &str = "84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a";
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum VideoPacket {
    Session {
        width: u16,
        height: u16,
    },
    Frame {
        data: Vec<u8>,
        config: bool,
        key: bool,
        pts_us: u64,
    },
}

pub fn read_video_packet(reader: &mut impl Read) -> io::Result<VideoPacket> {
    let mut flags = [0; 8];
    let mut length = [0; 4];
    reader.read_exact(&mut flags)?;
    reader.read_exact(&mut length)?;
    let flags = u64::from_be_bytes(flags);
    let length = u32::from_be_bytes(length);
    // v4 uses the top bit for session metadata, not codec configuration.
    if flags & (1 << 63) != 0 {
        let width = flags as u32;
        if flags >> 32 & 0x7ffffffe != 0
            || width == 0
            || width > u16::MAX as u32
            || length == 0
            || length > u16::MAX as u32
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid guest dimensions",
            ));
        }
        return Ok(VideoPacket::Session {
            width: width as u16,
            height: length as u16,
        });
    }
    if length == 0 || length as usize > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid guest frame size",
        ));
    }
    let mut data = vec![0; length as usize];
    reader.read_exact(&mut data)?;
    Ok(VideoPacket::Frame {
        data,
        config: flags & (1 << 62) != 0,
        key: flags & (1 << 61) != 0,
        pts_us: flags & ((1 << 61) - 1),
    })
}

pub fn touch_packet(
    action: u8,
    pointer: u64,
    x: u32,
    y: u32,
    width: u16,
    height: u16,
) -> io::Result<[u8; 32]> {
    if !matches!(action, 0 | 1 | 2 | 3)
        || width == 0
        || height == 0
        || x >= width as u32
        || y >= height as u32
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid guest touch",
        ));
    }
    let mut packet = [0; 32];
    packet[0] = 2;
    packet[1] = action;
    packet[2..10].copy_from_slice(&pointer.to_be_bytes());
    packet[10..14].copy_from_slice(&x.to_be_bytes());
    packet[14..18].copy_from_slice(&y.to_be_bytes());
    packet[18..20].copy_from_slice(&width.to_be_bytes());
    packet[20..22].copy_from_slice(&height.to_be_bytes());
    if matches!(action, 0 | 2) {
        packet[22..24].copy_from_slice(&u16::MAX.to_be_bytes());
        packet[24..28].copy_from_slice(&1_u32.to_be_bytes());
        packet[28..32].copy_from_slice(&1_u32.to_be_bytes());
    }
    Ok(packet)
}

#[derive(Debug, PartialEq, Eq)]
pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub key: bool,
    pub pts_ms: i64,
}

#[derive(Default)]
pub struct H264Frames {
    config: Vec<u8>,
    origin_us: Option<u64>,
}

impl H264Frames {
    pub fn accept(&mut self, packet: VideoPacket) -> io::Result<Option<EncodedFrame>> {
        let (mut data, config, key, pts_us) = match packet {
            VideoPacket::Session { .. } => {
                self.config.clear();
                self.origin_us = None;
                return Ok(None);
            }
            VideoPacket::Frame {
                data,
                config,
                key,
                pts_us,
            } => (data, config, key, pts_us),
        };
        if data.is_empty() || data.len() > MAX_FRAME_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid H.264 frame size",
            ));
        }
        if config {
            self.config = data;
            self.origin_us = None;
            return Ok(None);
        }
        if self.origin_us.is_none() && !key {
            return Ok(None);
        }
        if key {
            if self.config.is_empty() || self.config.len() + data.len() > MAX_FRAME_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Missing or oversized H.264 configuration",
                ));
            }
            let mut configured = Vec::with_capacity(self.config.len() + data.len());
            configured.extend_from_slice(&self.config);
            configured.append(&mut data);
            data = configured;
        }
        let origin = *self.origin_us.get_or_insert(pts_us);
        let delta = pts_us.checked_sub(origin).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Guest timestamp precedes stream start",
            )
        })?;
        Ok(Some(EncodedFrame {
            data,
            key,
            pts_ms: (delta / 1000) as i64,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn h264_starts_on_a_keyframe_with_configuration_and_resets_after_rotation() {
        let mut frames = H264Frames::default();
        let media = |data, config, key, pts_us| VideoPacket::Frame {
            data,
            config,
            key,
            pts_us,
        };
        assert!(frames
            .accept(media(vec![9], false, false, 1_000_000))
            .unwrap()
            .is_none());
        assert!(frames
            .accept(media(vec![1, 2], true, false, 0))
            .unwrap()
            .is_none());
        assert_eq!(
            frames
                .accept(media(vec![3], false, true, 1_000_000))
                .unwrap(),
            Some(EncodedFrame {
                data: vec![1, 2, 3],
                key: true,
                pts_ms: 0
            })
        );
        assert_eq!(
            frames
                .accept(media(vec![4], false, false, 1_035_000))
                .unwrap(),
            Some(EncodedFrame {
                data: vec![4],
                key: false,
                pts_ms: 35
            })
        );
        assert!(frames
            .accept(VideoPacket::Session {
                width: 720,
                height: 1280
            })
            .unwrap()
            .is_none());
        assert!(frames
            .accept(media(vec![5], false, false, 1_045_000))
            .unwrap()
            .is_none());
        assert!(frames
            .accept(media(vec![6], false, true, 1_050_000))
            .is_err());
        frames.accept(media(vec![7], true, false, 0)).unwrap();
        assert_eq!(
            frames
                .accept(media(vec![8], false, true, 1_060_000))
                .unwrap(),
            Some(EncodedFrame {
                data: vec![7, 8],
                key: true,
                pts_ms: 0
            })
        );
    }

    #[test]
    fn reads_v4_session_config_and_key_without_treating_session_as_a_length() {
        let mut wire = Vec::new();
        wire.extend_from_slice(&0x80000000_u32.to_be_bytes());
        wire.extend_from_slice(&1280_u32.to_be_bytes());
        wire.extend_from_slice(&720_u32.to_be_bytes());
        wire.extend_from_slice(&(1_u64 << 62).to_be_bytes());
        wire.extend_from_slice(&4_u32.to_be_bytes());
        wire.extend_from_slice(&[0, 0, 0, 1]);
        wire.extend_from_slice(&((1_u64 << 61) | 1234567).to_be_bytes());
        wire.extend_from_slice(&3_u32.to_be_bytes());
        wire.extend_from_slice(&[1, 2, 3]);
        let mut input = wire.as_slice();
        assert_eq!(
            read_video_packet(&mut input).unwrap(),
            VideoPacket::Session {
                width: 1280,
                height: 720
            }
        );
        assert_eq!(
            read_video_packet(&mut input).unwrap(),
            VideoPacket::Frame {
                data: vec![0, 0, 0, 1],
                config: true,
                key: false,
                pts_us: 0
            }
        );
        assert_eq!(
            read_video_packet(&mut input).unwrap(),
            VideoPacket::Frame {
                data: vec![1, 2, 3],
                config: false,
                key: true,
                pts_us: 1234567
            }
        );
        assert!(input.is_empty());
    }

    #[test]
    fn rejects_oversized_or_truncated_frames_and_invalid_dimensions() {
        for size in [0, MAX_FRAME_BYTES as u32 + 1] {
            let mut wire = vec![0_u8; 8];
            wire.extend_from_slice(&size.to_be_bytes());
            assert_eq!(
                read_video_packet(&mut wire.as_slice()).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        let mut truncated = vec![0_u8; 8];
        truncated.extend_from_slice(&3_u32.to_be_bytes());
        truncated.push(0);
        assert_eq!(
            read_video_packet(&mut truncated.as_slice())
                .unwrap_err()
                .kind(),
            io::ErrorKind::UnexpectedEof
        );
        for width in [0_u32, 65536] {
            let mut wire = 0x80000000_u32.to_be_bytes().to_vec();
            wire.extend_from_slice(&width.to_be_bytes());
            wire.extend_from_slice(&720_u32.to_be_bytes());
            assert_eq!(
                read_video_packet(&mut wire.as_slice()).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
    }

    #[test]
    fn touch_uses_guest_dimensions_and_rejects_out_of_bounds_input() {
        let packet = touch_packet(0, 0x1234567887654321, 100, 200, 1080, 1920).unwrap();
        assert_eq!(
            packet,
            [
                2, 0, 0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21, 0, 0, 0, 100, 0, 0, 0, 200,
                4, 0x38, 7, 0x80, 0xff, 0xff, 0, 0, 0, 1, 0, 0, 0, 1
            ]
        );
        for (action, x, y, width, height) in [
            (0, 1080, 0, 1080, 1920),
            (0, 0, 1920, 1080, 1920),
            (0, 0, 0, 0, 1920),
            (9, 0, 0, 1080, 1920),
        ] {
            assert_eq!(
                touch_packet(action, 0, x, y, width, height)
                    .unwrap_err()
                    .kind(),
                io::ErrorKind::InvalidInput
            );
        }
        let release = touch_packet(1, 0, 100, 200, 1080, 1920).unwrap();
        assert_eq!(&release[22..32], &[0; 10]);
    }
}
