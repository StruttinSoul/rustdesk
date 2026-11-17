//! Discovery of the Android Emulator's local gRPC screen feed and the little
//! protobuf / gRPC wire format needed to read it. Pure apart from `discover`.

use super::avd;
use hbb_common::{
    bail,
    protobuf::{CodedInputStream, CodedOutputStream},
    ResultType,
};
use std::{fmt, path::PathBuf};

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
}

/// Reads `grpc.port` and `grpc.token` from an emulator `pid_<pid>.ini`.
pub fn parse_running_ini(text: &str) -> ResultType<FeedEndpoint> {
    let mut port = None;
    let mut token = None;
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "grpc.port" => port = value.trim().parse::<u16>().ok().filter(|p| *p != 0),
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
}
