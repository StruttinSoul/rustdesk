use hbb_common::sysinfo::{Pid, Process, System};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    env, fs,
    io::{Read, Write},
    net::{Ipv4Addr, SocketAddrV4, TcpStream},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const PROCESS_RECORD_LIMIT: u64 = 8 * 1024;
const COMMAND_OUTPUT_LIMIT: usize = 16 * 1024;
const MANAGEMENT_RESPONSE_LIMIT: usize = 24 * 1024;
const MANAGEMENT_MATERIAL_LIMIT: u64 = 8 * 1024;
const MANAGEMENT_NETWORK_TIMEOUT: Duration = Duration::from_secs(5);
const OPERATION_CACHE_LIMIT: usize = 64;

#[derive(Debug, Deserialize)]
struct ProcessRecord {
    runner_pid: u32,
    gateway_pid: u32,
}

#[derive(Debug, Default, Deserialize)]
struct ManagementOutput {
    runtime: Option<ManagementRuntime>,
    imdb: Option<ManagementIMDb>,
    accepted: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManagementMaterialWire {
    management_token: String,
    setup_fingerprint: String,
    setup_listen: String,
}

struct ManagementMaterial {
    token: String,
    fingerprint: [u8; 32],
    port: u16,
}

#[derive(Debug, Default, Deserialize)]
struct ManagementRuntime {
    gateway_version: Option<String>,
    identity_ready: Option<bool>,
    silo: Option<ManagementSilo>,
    metadata: Option<ManagementMetadata>,
    capacity: Option<ManagementCapacity>,
}

#[derive(Debug, Default, Deserialize)]
struct ManagementSilo {
    state: Option<String>,
    profile_selected: Option<bool>,
    profile_verified: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct ManagementMetadata {
    imdb: Option<ManagementIMDb>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct ManagementIMDb {
    enabled: Option<bool>,
    state: Option<String>,
    updated_at: Option<String>,
    refreshing: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct ManagementCapacity {
    active: Option<u32>,
    max: Option<u32>,
}

#[derive(Clone, Debug)]
struct CachedOperation {
    operation_id: String,
    action: String,
    target: String,
    payload_fingerprint: String,
    result: Result<String, GatewayOperationError>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GatewayOperationError {
    pub(crate) message: String,
    pub(crate) outcome_unknown: bool,
}

impl GatewayOperationError {
    fn definite(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            outcome_unknown: false,
        }
    }

    fn unknown(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            outcome_unknown: true,
        }
    }

    #[cfg(test)]
    fn contains(&self, value: &str) -> bool {
        self.message.contains(value)
    }
}

impl From<String> for GatewayOperationError {
    fn from(message: String) -> Self {
        Self::definite(message)
    }
}

#[derive(Debug)]
struct SupervisorContext {
    root: PathBuf,
    process_identity: String,
    setup_url: Option<String>,
    setup_port: u16,
}

static GATEWAY_OPERATIONS: OnceLock<Mutex<VecDeque<CachedOperation>>> = OnceLock::new();

#[derive(Clone, Debug, Serialize)]
pub struct GatewayStatus {
    schema: u32,
    sampled_at_ms: u64,
    installed: bool,
    process_state: String,
    gateway_pid: Option<u32>,
    process_identity: String,
    version: String,
    reachability: String,
    gateway_health: String,
    api_version: String,
    trusted_pin_matched: Option<bool>,
    protected_health_available: bool,
    identity_ready: Option<bool>,
    silo_state: String,
    silo_profile_selected: Option<bool>,
    silo_profile_verified: Option<bool>,
    active_sessions: Option<u32>,
    max_sessions: Option<u32>,
    imdb_enabled: Option<bool>,
    imdb_state: String,
    imdb_refreshing: Option<bool>,
    imdb_updated_at: String,
    setup_control_available: bool,
    provider_control_available: bool,
    restart_control_available: bool,
    detail: String,
}

pub fn status() -> GatewayStatus {
    let sampled_at_ms = now_ms();
    let system = System::new_all();
    let Some(root) = discover_runtime_root(&system) else {
        return GatewayStatus {
            schema: 1,
            sampled_at_ms,
            installed: false,
            process_state: "unknown".to_owned(),
            gateway_pid: None,
            process_identity: String::new(),
            version: String::new(),
            reachability: "unknown".to_owned(),
            gateway_health: String::new(),
            api_version: String::new(),
            trusted_pin_matched: None,
            protected_health_available: false,
            identity_ready: None,
            silo_state: String::new(),
            silo_profile_selected: None,
            silo_profile_verified: None,
            active_sessions: None,
            max_sessions: None,
            imdb_enabled: None,
            imdb_state: String::new(),
            imdb_refreshing: None,
            imdb_updated_at: String::new(),
            setup_control_available: false,
            provider_control_available: false,
            restart_control_available: false,
            detail: "Marquee Gateway runtime was not found on this Windows host.".to_owned(),
        };
    };

    let record = read_process_record(&root);
    let runner = record
        .as_ref()
        .and_then(|record| system.process(Pid::from_u32(record.runner_pid)));
    let gateway = record
        .as_ref()
        .and_then(|record| system.process(Pid::from_u32(record.gateway_pid)));
    let gateway_executable = root.join("marquee-gateway.exe");
    let manager = root.join("runtime_manager.py");
    let runner_verified = runner
        .map(|process| runner_matches_manager(process, &manager))
        .unwrap_or(false);
    let gateway_verified = gateway
        .map(|process| same_path(process.exe(), &gateway_executable))
        .unwrap_or(false);
    let gateway_parent_verified = gateway
        .and_then(|process| process.parent())
        .zip(record.as_ref())
        .map(|(parent, record)| parent == Pid::from_u32(record.runner_pid))
        .unwrap_or(false);

    let process_state = match (
        record.is_some(),
        runner_verified,
        gateway_verified,
        gateway_parent_verified,
    ) {
        (_, true, true, true) => "running",
        (_, true, false, _) => "supervisor_running",
        (_, _, true, _) => "orphaned_child",
        (true, false, false, _) => "stale_record",
        (false, _, _, _) => "unknown",
    }
    .to_owned();
    let gateway_pid = gateway_verified.then(|| record.as_ref().unwrap().gateway_pid);
    let process_identity = if gateway_verified {
        gateway
            .and_then(|process| {
                let pid = process.pid().as_u32();
                super::host_management::process_creation_time_100ns(pid)
                    .filter(|creation| *creation > 0)
                    .map(|creation| format!("gateway:{pid}:{creation}"))
            })
            .unwrap_or_default()
    } else {
        String::new()
    };
    let owned_child = runner_verified && gateway_verified && gateway_parent_verified;
    let setup_port = gateway.and_then(|process| setup_port_from_command(process.cmd()));
    let management_result = if owned_child {
        setup_port
            .ok_or_else(|| "Gateway setup listener is unavailable.".to_owned())
            .and_then(|port| management_status(&root, port))
    } else {
        Err("Gateway child ownership is not verified.".to_owned())
    };
    let management = management_result.as_ref().ok();
    let runtime = management.as_ref().and_then(|value| value.runtime.as_ref());
    let imdb = management
        .as_ref()
        .and_then(|value| value.imdb.as_ref())
        .or_else(|| {
            runtime
                .and_then(|value| value.metadata.as_ref())
                .and_then(|value| value.imdb.as_ref())
        });
    let version = runtime
        .and_then(|value| value.gateway_version.as_deref())
        .filter(|value| !value.is_empty() && value.len() <= 128)
        .unwrap_or_default()
        .to_owned();
    let setup_control_available = owned_child && setup_port.is_some();
    let management_available = management.is_some();

    let (reachability, trusted_pin_matched, protected_health_available, detail) =
        if management_available {
            (
                "reachable".to_owned(),
                Some(true),
                true,
                "Gateway returned authenticated local management status.".to_owned(),
            )
        } else if owned_child {
            (
            "unknown".to_owned(),
            None,
            false,
            format!(
                "Gateway process ownership is verified; authenticated local management is unavailable ({}).",
                management_result
                    .as_ref()
                    .err()
                    .map(String::as_str)
                    .unwrap_or("unknown reason")
            ),
        )
        } else if gateway_verified {
            (
                "unknown".to_owned(),
                None,
                false,
                "Gateway process is running, but its supervisor ownership could not be verified."
                    .to_owned(),
            )
        } else {
            (
            "unknown".to_owned(),
            None,
            false,
            "Gateway reachability is unknown because no verified owned child is currently observable."
                .to_owned(),
        )
        };

    let restart_control_available = management_available && !process_identity.is_empty();

    GatewayStatus {
        schema: 1,
        sampled_at_ms,
        installed: true,
        process_state,
        gateway_pid,
        process_identity,
        version,
        reachability,
        gateway_health: String::new(),
        api_version: String::new(),
        trusted_pin_matched,
        protected_health_available,
        identity_ready: runtime.and_then(|value| value.identity_ready),
        silo_state: runtime
            .and_then(|value| value.silo.as_ref())
            .and_then(|value| value.state.as_deref())
            .unwrap_or_default()
            .to_owned(),
        silo_profile_selected: runtime
            .and_then(|value| value.silo.as_ref())
            .and_then(|value| value.profile_selected),
        silo_profile_verified: runtime
            .and_then(|value| value.silo.as_ref())
            .and_then(|value| value.profile_verified),
        active_sessions: runtime
            .and_then(|value| value.capacity.as_ref())
            .and_then(|value| value.active),
        max_sessions: runtime
            .and_then(|value| value.capacity.as_ref())
            .and_then(|value| value.max),
        imdb_enabled: imdb.and_then(|value| value.enabled),
        imdb_state: imdb
            .and_then(|value| value.state.as_deref())
            .unwrap_or_default()
            .to_owned(),
        imdb_refreshing: imdb.and_then(|value| value.refreshing),
        imdb_updated_at: imdb
            .and_then(|value| value.updated_at.as_deref())
            .unwrap_or_default()
            .to_owned(),
        setup_control_available,
        provider_control_available: management_available,
        restart_control_available,
        detail,
    }
}

fn discover_runtime_root(system: &System) -> Option<PathBuf> {
    if let Some(root) = env::var_os("MARQUEE_GATEWAY_RUNTIME") {
        let candidate = PathBuf::from(root);
        if runtime_root_is_valid(&candidate) {
            return Some(candidate);
        }
    }
    for process in system.processes().values() {
        if !process.name().eq_ignore_ascii_case("marquee-gateway.exe") {
            continue;
        }
        if let Some(parent) = process.exe().parent() {
            if runtime_root_is_valid(parent) {
                return Some(parent.to_path_buf());
            }
        }
    }
    if let Some(profile) = env::var_os("USERPROFILE") {
        let candidate = PathBuf::from(profile).join("MarqueeGatewayRuntime");
        if runtime_root_is_valid(&candidate) {
            return Some(candidate);
        }
    }
    // RustDesk may run before interactive sign-in under a service account. In that
    // case USERPROFILE points at the service profile, so accept a per-user runtime
    // only when discovery is unambiguous.
    if let Some(system_drive) = env::var_os("SystemDrive") {
        let users = PathBuf::from(system_drive).join("Users");
        if let Ok(entries) = fs::read_dir(users) {
            let mut matches = entries
                .flatten()
                .map(|entry| entry.path().join("MarqueeGatewayRuntime"))
                .filter(|candidate| runtime_root_is_valid(candidate))
                .collect::<Vec<_>>();
            matches.sort();
            matches.dedup();
            if matches.len() == 1 {
                return matches.pop();
            }
        }
    }
    None
}

fn runtime_root_is_valid(root: &Path) -> bool {
    root.join("runtime_manager.py").is_file() && root.join("marquee-gateway.exe").is_file()
}

fn read_process_record(root: &Path) -> Option<ProcessRecord> {
    let path = root.join("process.json");
    let metadata = fs::metadata(&path).ok()?;
    if metadata.len() == 0 || metadata.len() > PROCESS_RECORD_LIMIT {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn is_python_executable(path: &Path) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(|name| name.to_ascii_lowercase().starts_with("python"))
        .unwrap_or(false)
}

fn runner_matches_manager(process: &Process, manager: &Path) -> bool {
    if !is_python_executable(process.exe()) {
        return false;
    }
    command_matches_manager(process.cmd(), manager)
}

fn command_matches_manager(command: &[String], manager: &Path) -> bool {
    command.windows(2).any(|pair| {
        same_path(Path::new(&pair[0]), manager) && pair[1].eq_ignore_ascii_case("serve")
    })
}

fn same_path(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left
            .to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy()),
    }
}

fn parse_management_material(bytes: &[u8]) -> Result<ManagementMaterial, String> {
    let wire: ManagementMaterialWire = serde_json::from_slice(bytes)
        .map_err(|_| "Gateway management material is invalid.".to_owned())?;
    if wire.management_token.len() != 43
        || !wire
            .management_token
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || value == b'-' || value == b'_')
    {
        return Err("Gateway management token is invalid.".to_owned());
    }
    if wire.setup_fingerprint.len() != 64
        || !wire
            .setup_fingerprint
            .bytes()
            .all(|value| value.is_ascii_hexdigit())
    {
        return Err("Gateway management certificate fingerprint is invalid.".to_owned());
    }
    let (host, port) = wire
        .setup_listen
        .rsplit_once(':')
        .ok_or_else(|| "Gateway management listener is invalid.".to_owned())?;
    let port: u16 = port
        .parse()
        .ok()
        .filter(|port| *port > 0)
        .ok_or_else(|| "Gateway management listener is invalid.".to_owned())?;
    if host != "127.0.0.1" {
        return Err("Gateway management listener is not loopback-only.".to_owned());
    }
    let mut fingerprint = [0u8; 32];
    for (index, byte) in fingerprint.iter_mut().enumerate() {
        let offset = index * 2;
        *byte = u8::from_str_radix(&wire.setup_fingerprint[offset..offset + 2], 16)
            .map_err(|_| "Gateway management certificate fingerprint is invalid.".to_owned())?;
    }
    Ok(ManagementMaterial {
        token: wire.management_token,
        fingerprint,
        port,
    })
}

fn parse_management_http_response(bytes: &[u8]) -> Result<(u16, Vec<u8>), String> {
    if bytes.len() > MANAGEMENT_RESPONSE_LIMIT {
        return Err("Gateway management response exceeded the limit.".to_owned());
    }
    let header_end = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
        .ok_or_else(|| "Gateway management response headers were incomplete.".to_owned())?;
    let headers = std::str::from_utf8(&bytes[..header_end - 4])
        .map_err(|_| "Gateway management response headers were invalid.".to_owned())?;
    let mut lines = headers.split("\r\n");
    let status_line = lines
        .next()
        .ok_or_else(|| "Gateway management response status was missing.".to_owned())?;
    let mut status_parts = status_line.split_whitespace();
    let protocol = status_parts.next().unwrap_or_default();
    let status: u16 = status_parts
        .next()
        .and_then(|value| value.parse().ok())
        .filter(|value| (100..=599).contains(value))
        .ok_or_else(|| "Gateway management response status was invalid.".to_owned())?;
    if !matches!(protocol, "HTTP/1.1" | "HTTP/1.0") {
        return Err("Gateway management response protocol was invalid.".to_owned());
    }

    let mut content_length = None;
    let mut chunked = false;
    for line in lines {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| "Gateway management response header was invalid.".to_owned())?;
        let name = name.trim();
        let value = value.trim();
        if name.eq_ignore_ascii_case("Content-Length") {
            if content_length.is_some() {
                return Err("Gateway management response length was ambiguous.".to_owned());
            }
            content_length = Some(
                value
                    .parse::<usize>()
                    .ok()
                    .filter(|length| *length <= COMMAND_OUTPUT_LIMIT)
                    .ok_or_else(|| "Gateway management response length was invalid.".to_owned())?,
            );
        } else if name.eq_ignore_ascii_case("Transfer-Encoding") {
            if !value.eq_ignore_ascii_case("chunked") || chunked {
                return Err("Gateway management response encoding was unsupported.".to_owned());
            }
            chunked = true;
        }
    }
    if chunked && content_length.is_some() {
        return Err("Gateway management response framing was ambiguous.".to_owned());
    }

    let body = &bytes[header_end..];
    if chunked {
        return decode_chunked_management_body(body).map(|body| (status, body));
    }
    let expected = content_length
        .ok_or_else(|| "Gateway management response length was missing.".to_owned())?;
    if body.len() != expected {
        return Err("Gateway management response body length did not match.".to_owned());
    }
    Ok((status, body.to_vec()))
}

fn decode_chunked_management_body(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut position = 0usize;
    let mut decoded = Vec::new();
    loop {
        let line_end = bytes[position..]
            .windows(2)
            .position(|window| window == b"\r\n")
            .map(|offset| position + offset)
            .ok_or_else(|| "Gateway management chunk header was incomplete.".to_owned())?;
        let size_text = std::str::from_utf8(&bytes[position..line_end])
            .map_err(|_| "Gateway management chunk size was invalid.".to_owned())?;
        if size_text.is_empty() || size_text.contains(';') {
            return Err("Gateway management chunk size was invalid.".to_owned());
        }
        let size = usize::from_str_radix(size_text, 16)
            .ok()
            .filter(|size| *size <= COMMAND_OUTPUT_LIMIT.saturating_sub(decoded.len()))
            .ok_or_else(|| "Gateway management chunk size exceeded the limit.".to_owned())?;
        position = line_end + 2;
        if size == 0 {
            if bytes.get(position..) != Some(b"\r\n".as_slice()) {
                return Err("Gateway management chunk terminator was invalid.".to_owned());
            }
            return Ok(decoded);
        }
        let end = position
            .checked_add(size)
            .ok_or_else(|| "Gateway management chunk size was invalid.".to_owned())?;
        if end + 2 > bytes.len() || bytes.get(end..end + 2) != Some(b"\r\n".as_slice()) {
            return Err("Gateway management chunk body was incomplete.".to_owned());
        }
        decoded.extend_from_slice(&bytes[position..end]);
        position = end + 2;
    }
}

fn management_status(root: &Path, expected_port: u16) -> Result<ManagementOutput, String> {
    let material = load_management_material(root, expected_port)?;
    management_json_request(&material, "GET", "/v1/local-management/status", b"", 200)
}

fn load_management_material(root: &Path, expected_port: u16) -> Result<ManagementMaterial, String> {
    let path = root
        .join(".rustdesk-management")
        .join("rustdesk-management.dpapi");
    let metadata = fs::metadata(&path)
        .map_err(|_| "Gateway management credentials are unavailable.".to_owned())?;
    if metadata.len() == 0 || metadata.len() > MANAGEMENT_MATERIAL_LIMIT {
        return Err("Gateway management credentials are invalid.".to_owned());
    }
    let protected = fs::read(path)
        .map_err(|_| "Gateway management credentials could not be read.".to_owned())?;
    let mut clear = unprotect_management_material(&protected)?;
    let parsed = parse_management_material(&clear);
    clear.fill(0);
    let material = parsed?;
    if material.port != expected_port {
        return Err("Gateway management listener does not match the verified process.".to_owned());
    }
    Ok(material)
}

fn unprotect_management_material(protected: &[u8]) -> Result<Vec<u8>, String> {
    use std::ptr;
    use winapi::{
        shared::minwindef::HLOCAL,
        um::{
            dpapi::{CryptUnprotectData, CRYPTPROTECT_LOCAL_MACHINE, CRYPTPROTECT_UI_FORBIDDEN},
            winbase::LocalFree,
            wincrypt::DATA_BLOB,
        },
    };

    if protected.is_empty() || protected.len() > MANAGEMENT_MATERIAL_LIMIT as usize {
        return Err("Gateway management credentials are invalid.".to_owned());
    }
    let mut input = DATA_BLOB {
        cbData: protected.len() as u32,
        pbData: protected.as_ptr() as *mut u8,
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN | CRYPTPROTECT_LOCAL_MACHINE,
            &mut output,
        )
    };
    if ok == 0 || output.pbData.is_null() || output.cbData == 0 {
        return Err("Gateway management credentials could not be unprotected.".to_owned());
    }
    let result = if output.cbData as usize > MANAGEMENT_MATERIAL_LIMIT as usize {
        Err("Gateway management credentials are too large.".to_owned())
    } else {
        Ok(unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() })
    };
    unsafe {
        for offset in 0..output.cbData as usize {
            std::ptr::write_volatile(output.pbData.add(offset), 0);
        }
        LocalFree(output.pbData as HLOCAL);
    }
    result
}

fn management_json_request(
    material: &ManagementMaterial,
    method: &str,
    path: &str,
    body: &[u8],
    expected_status: u16,
) -> Result<ManagementOutput, String> {
    let (status, body) = management_http_request(material, method, path, body)?;
    if status != expected_status {
        return Err(format!(
            "Gateway local management returned HTTP status {status}."
        ));
    }
    serde_json::from_slice(&body)
        .map_err(|_| "Gateway local management returned invalid data.".to_owned())
}

fn management_http_request(
    material: &ManagementMaterial,
    method: &str,
    path: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>), String> {
    if !matches!(method, "GET" | "POST")
        || !path.starts_with("/v1/local-management/")
        || path.bytes().any(|value| value <= b' ' || value == 0x7f)
        || body.len() > 1024
    {
        return Err("Gateway local management request is invalid.".to_owned());
    }
    let deadline = Instant::now() + MANAGEMENT_NETWORK_TIMEOUT;
    let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, material.port);
    let tcp = TcpStream::connect_timeout(&address.into(), MANAGEMENT_NETWORK_TIMEOUT)
        .map_err(|_| "Gateway local management could not connect.".to_owned())?;
    let remaining = management_request_remaining(deadline)?;
    tcp.set_read_timeout(Some(remaining))
        .map_err(|_| "Gateway local management timeout could not be configured.".to_owned())?;
    tcp.set_write_timeout(Some(remaining))
        .map_err(|_| "Gateway local management timeout could not be configured.".to_owned())?;

    let mut builder = native_tls::TlsConnector::builder();
    builder.danger_accept_invalid_certs(true);
    builder.danger_accept_invalid_hostnames(true);
    let connector = builder
        .build()
        .map_err(|_| "Gateway local management TLS could not be initialized.".to_owned())?;
    let mut stream = connector
        .connect("127.0.0.1", tcp)
        .map_err(|_| "Gateway local management TLS connection failed.".to_owned())?;
    let remaining = management_request_remaining(deadline)?;
    stream
        .get_mut()
        .set_read_timeout(Some(remaining))
        .and_then(|_| stream.get_mut().set_write_timeout(Some(remaining)))
        .map_err(|_| "Gateway local management timeout could not be configured.".to_owned())?;
    let certificate = stream
        .peer_certificate()
        .map_err(|_| "Gateway local management certificate was unavailable.".to_owned())?
        .ok_or_else(|| "Gateway local management certificate was unavailable.".to_owned())?;
    let certificate = certificate
        .to_der()
        .map_err(|_| "Gateway local management certificate was invalid.".to_owned())?;
    let digest = Sha256::digest(&certificate);
    if !constant_time_equal(&material.fingerprint, digest.as_ref()) {
        return Err("Gateway local management certificate did not match bootstrap.".to_owned());
    }

    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer {}\r\nAccept: application/json\r\nConnection: close\r\n",
        material.port, material.token
    );
    if method == "POST" {
        request.push_str("Content-Type: application/json\r\n");
        request.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    request.push_str("\r\n");
    let remaining = management_request_remaining(deadline)?;
    stream
        .get_mut()
        .set_write_timeout(Some(remaining))
        .map_err(|_| "Gateway local management timeout could not be configured.".to_owned())?;
    stream
        .write_all(request.as_bytes())
        .and_then(|_| stream.write_all(body))
        .and_then(|_| stream.flush())
        .map_err(|_| "Gateway local management request could not be sent.".to_owned())?;

    let mut response = Vec::with_capacity(4096);
    let mut buffer = [0u8; 4096];
    loop {
        let remaining = management_request_remaining(deadline)?;
        stream
            .get_mut()
            .set_read_timeout(Some(remaining))
            .map_err(|_| "Gateway local management timeout could not be configured.".to_owned())?;
        let read = stream
            .read(&mut buffer)
            .map_err(|_| "Gateway local management response could not be read.".to_owned())?;
        if read == 0 {
            break;
        }
        if response.len().saturating_add(read) > MANAGEMENT_RESPONSE_LIMIT {
            return Err("Gateway local management response exceeded the limit.".to_owned());
        }
        response.extend_from_slice(&buffer[..read]);
    }
    parse_management_http_response(&response)
}

fn management_request_remaining(deadline: Instant) -> Result<Duration, String> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err("Gateway local management request timed out.".to_owned())
    } else {
        Ok(remaining)
    }
}

fn constant_time_equal(expected: &[u8], actual: &[u8]) -> bool {
    if expected.len() != actual.len() {
        return false;
    }
    expected
        .iter()
        .zip(actual)
        .fold(0u8, |difference, (left, right)| difference | (left ^ right))
        == 0
}

fn verified_supervisor_context() -> Result<SupervisorContext, String> {
    let system = System::new_all();
    let root = discover_runtime_root(&system)
        .ok_or_else(|| "Marquee Gateway runtime was not found.".to_owned())?;
    let record = read_process_record(&root)
        .ok_or_else(|| "Gateway supervisor process record is unavailable.".to_owned())?;
    let runner = system
        .process(Pid::from_u32(record.runner_pid))
        .ok_or_else(|| "Gateway supervisor is not running.".to_owned())?;
    let manager = root.join("runtime_manager.py");
    if !runner_matches_manager(runner, &manager) {
        return Err("Gateway supervisor identity could not be verified.".to_owned());
    }
    let gateway = system
        .process(Pid::from_u32(record.gateway_pid))
        .ok_or_else(|| "Gateway process is not running.".to_owned())?;
    if !same_path(gateway.exe(), &root.join("marquee-gateway.exe"))
        || gateway.parent() != Some(Pid::from_u32(record.runner_pid))
    {
        return Err("Gateway child ownership could not be verified.".to_owned());
    }
    let creation = super::host_management::process_creation_time_100ns(record.gateway_pid)
        .filter(|value| *value > 0)
        .ok_or_else(|| "Gateway process identity is unavailable.".to_owned())?;
    let setup_port = setup_port_from_command(gateway.cmd())
        .ok_or_else(|| "Gateway setup listener is unavailable.".to_owned())?;
    Ok(SupervisorContext {
        root,
        process_identity: format!("gateway:{}:{}", record.gateway_pid, creation),
        setup_url: setup_url_from_command(gateway.cmd()),
        setup_port,
    })
}

fn setup_url_from_command(command: &[String]) -> Option<String> {
    let port = setup_port_from_command(command)?;
    Some(format!("https://127.0.0.1:{port}/setup"))
}

fn setup_port_from_command(command: &[String]) -> Option<u16> {
    let value = command.windows(2).find_map(|pair| {
        pair[0]
            .eq_ignore_ascii_case("--setup-listen")
            .then_some(pair[1].as_str())
    })?;
    let (host, port) = value.rsplit_once(':')?;
    let port: u16 = port.parse().ok()?;
    if host != "127.0.0.1" || port == 0 {
        return None;
    }
    Some(port)
}

fn run_operation_once<F>(
    operation_id: &str,
    action: &str,
    target: &str,
    payload_fingerprint: &str,
    apply: F,
) -> Result<String, GatewayOperationError>
where
    F: FnOnce() -> Result<String, GatewayOperationError>,
{
    if operation_id.is_empty() || operation_id.len() > 128 {
        return Err(GatewayOperationError::definite(
            "Gateway operation identity is invalid.",
        ));
    }
    let cache = GATEWAY_OPERATIONS.get_or_init(|| Mutex::new(VecDeque::new()));
    let mut operations = cache
        .lock()
        .map_err(|_| GatewayOperationError::definite("Gateway operation cache is unavailable."))?;
    if let Some(existing) = operations
        .iter()
        .find(|item| item.operation_id == operation_id)
    {
        if existing.action != action
            || existing.target != target
            || existing.payload_fingerprint != payload_fingerprint
        {
            return Err(GatewayOperationError::definite(
                "Gateway operation id already belongs to a different request.",
            ));
        }
        return existing.result.clone();
    }

    // Keep the cache lock while the bounded operation runs. Gateway management
    // mutations are infrequent and this makes duplicate operation IDs atomic:
    // a reconnect cannot execute the same restart/provider mutation twice.
    let result = apply();
    operations.push_back(CachedOperation {
        operation_id: operation_id.to_owned(),
        action: action.to_owned(),
        target: target.to_owned(),
        payload_fingerprint: payload_fingerprint.to_owned(),
        result: result.clone(),
    });
    while operations.len() > OPERATION_CACHE_LIMIT {
        operations.pop_front();
    }
    result
}

pub(crate) fn open_setup(operation_id: &str) -> Result<String, GatewayOperationError> {
    run_operation_once(
        operation_id,
        "gateway_setup_open",
        "gateway:setup",
        "",
        || {
            let context = verified_supervisor_context()?;
            let url = context
                .setup_url
                .ok_or_else(|| "Gateway setup listener is unavailable.".to_owned())?;
            let session_id = crate::platform::windows::get_current_session_id(false);
            if session_id == u32::MAX {
                return Err(GatewayOperationError::definite(
                    "No interactive Windows session is available for setup.",
                ));
            }
            crate::platform::windows::run_exe_in_session(
                "explorer.exe",
                vec![url.as_str()],
                session_id,
                true,
            )
            .map_err(|error| format!("Windows could not open Gateway setup: {error}"))?;
            Ok("Gateway setup handoff sent to Windows.".to_owned())
        },
    )
}

pub(crate) fn set_imdb_enabled(
    operation_id: &str,
    enabled: bool,
) -> Result<String, GatewayOperationError> {
    let fingerprint = if enabled {
        "enabled=true"
    } else {
        "enabled=false"
    };
    run_operation_once(
        operation_id,
        "gateway_imdb_set_enabled",
        "gateway:imdb",
        fingerprint,
        || {
            let context = verified_supervisor_context()?;
            let material = load_management_material(&context.root, context.setup_port)?;
            let body = serde_json::json!({
                "operation_id": operation_id,
                "enabled": enabled,
            })
            .to_string();
            let result = management_json_request(
                &material,
                "POST",
                "/v1/local-management/imdb/enabled",
                body.as_bytes(),
                200,
            )
            .map_err(GatewayOperationError::unknown)?;
            let observed = result
                .imdb
                .as_ref()
                .and_then(|value| value.enabled)
                .or_else(|| {
                    result
                        .runtime
                        .as_ref()
                        .and_then(|value| value.metadata.as_ref())
                        .and_then(|value| value.imdb.as_ref())
                        .and_then(|value| value.enabled)
                });
            if observed != Some(enabled) {
                return Err(GatewayOperationError::unknown(
                    "Gateway did not confirm the IMDb setting.",
                ));
            }
            Ok(if enabled {
                "IMDb provider enabled.".to_owned()
            } else {
                "IMDb provider disabled; existing cache is retained.".to_owned()
            })
        },
    )
}

pub(crate) fn refresh_imdb(operation_id: &str) -> Result<String, GatewayOperationError> {
    run_operation_once(
        operation_id,
        "gateway_imdb_refresh",
        "gateway:imdb",
        "",
        || {
            let context = verified_supervisor_context()?;
            let material = load_management_material(&context.root, context.setup_port)?;
            let body = serde_json::json!({"operation_id": operation_id}).to_string();
            let result = management_json_request(
                &material,
                "POST",
                "/v1/local-management/imdb/refresh",
                body.as_bytes(),
                202,
            )
            .map_err(GatewayOperationError::unknown)?;
            if result.accepted != Some(true) {
                return Err(GatewayOperationError::definite(
                    "IMDb refresh was not queued; it may be disabled, already queued, or running.",
                ));
            }
            Ok("IMDb refresh queued.".to_owned())
        },
    )
}

pub(crate) fn restart(
    operation_id: &str,
    expected_process_identity: &str,
    active_sessions_known: bool,
    confirmed_active_sessions: u32,
) -> Result<String, GatewayOperationError> {
    let target = format!("gateway:restart:{expected_process_identity}");
    let fingerprint = format!(
        "active_sessions_known={active_sessions_known};confirmed_active_sessions={confirmed_active_sessions}"
    );
    run_operation_once(
        operation_id,
        "gateway_restart",
        &target,
        &fingerprint,
        || {
            let context = verified_supervisor_context()?;
            if context.process_identity != expected_process_identity {
                return Err(GatewayOperationError::definite(
                    "Gateway process changed; refresh status before restarting.",
                ));
            }
            let material = load_management_material(&context.root, context.setup_port)?;
            let before =
                management_json_request(&material, "GET", "/v1/local-management/status", b"", 200)?;
            if active_sessions_known {
                let observed = before
                    .runtime
                    .as_ref()
                    .and_then(|value| value.capacity.as_ref())
                    .and_then(|value| value.active)
                    .ok_or_else(|| {
                        "Gateway session impact is now unknown; refresh before restarting."
                            .to_owned()
                    })?;
                if observed != confirmed_active_sessions {
                    return Err(GatewayOperationError::definite(
                        "Gateway active sessions changed; review the interruption impact again.",
                    ));
                }
            }
            let current = verified_supervisor_context()?;
            if current.process_identity != expected_process_identity
                || current.setup_port != context.setup_port
                || !same_path(&current.root, &context.root)
            {
                return Err(GatewayOperationError::definite(
                    "Gateway process changed; refresh status before restarting.",
                ));
            }
            let body = serde_json::json!({"operation_id": operation_id}).to_string();
            let result = management_json_request(
                &material,
                "POST",
                "/v1/local-management/restart",
                body.as_bytes(),
                202,
            )
            .map_err(GatewayOperationError::unknown)?;
            if result.accepted != Some(true) {
                return Err(GatewayOperationError::definite(
                    "Gateway supervisor did not accept the restart.",
                ));
            }
            Ok("Gateway restart requested; recheck status while it comes back.".to_owned())
        },
    )
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Barrier,
    };
    use std::thread;

    #[test]
    fn supervisor_command_must_match_exact_manager_and_serve_action() {
        let manager = Path::new(r"C:\Users\test\MarqueeGatewayRuntime\runtime_manager.py");
        assert!(command_matches_manager(
            &[
                r"C:\Python314\python.exe".to_owned(),
                manager.to_string_lossy().into_owned(),
                "serve".to_owned(),
            ],
            manager,
        ));
        assert!(!command_matches_manager(
            &[
                r"C:\Python314\python.exe".to_owned(),
                r"C:\Temp\runtime_manager.py".to_owned(),
                "serve".to_owned(),
            ],
            manager,
        ));
        assert!(!command_matches_manager(
            &[
                r"C:\Python314\python.exe".to_owned(),
                manager.to_string_lossy().into_owned(),
                "health".to_owned(),
            ],
            manager,
        ));
    }

    #[test]
    fn process_record_rejects_oversized_or_invalid_json() {
        let root = std::env::temp_dir().join(format!("mirpg-gateway-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("process.json"), b"not-json").unwrap();
        assert!(read_process_record(&root).is_none());
        fs::write(
            root.join("process.json"),
            vec![b'x'; PROCESS_RECORD_LIMIT as usize + 1],
        )
        .unwrap();
        assert!(read_process_record(&root).is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn gateway_operation_id_reuses_only_the_same_payload() {
        let calls = AtomicUsize::new(0);
        let id = "test-gateway-op-payload-20261006";
        let first = run_operation_once(
            id,
            "gateway_imdb_set_enabled",
            "gateway:imdb",
            "enabled=true",
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok("enabled".to_owned())
            },
        );
        let replay = run_operation_once(
            id,
            "gateway_imdb_set_enabled",
            "gateway:imdb",
            "enabled=true",
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok("must-not-run".to_owned())
            },
        );
        let mismatch = run_operation_once(
            id,
            "gateway_imdb_set_enabled",
            "gateway:imdb",
            "enabled=false",
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok("must-not-run".to_owned())
            },
        );

        assert_eq!(first.as_deref(), Ok("enabled"));
        assert_eq!(replay.as_deref(), Ok("enabled"));
        assert!(mismatch.unwrap_err().contains("different"));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn concurrent_duplicate_gateway_operation_executes_once() {
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(2));
        let mut threads = Vec::new();
        for _ in 0..2 {
            let calls = Arc::clone(&calls);
            let start = Arc::clone(&start);
            threads.push(thread::spawn(move || {
                start.wait();
                run_operation_once(
                    "test-gateway-op-concurrent-20261006",
                    "gateway_restart",
                    "gateway:restart:fixture",
                    "known=true;sessions=0",
                    || {
                        calls.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(75));
                        Ok("accepted".to_owned())
                    },
                )
            }));
        }
        let results = threads
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();

        assert!(results
            .iter()
            .all(|result| result.as_deref() == Ok("accepted")));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn unknown_gateway_operation_result_is_cached_and_replayed() {
        let calls = AtomicUsize::new(0);
        let id = "test-gateway-op-unknown-20261006";
        let first = run_operation_once(
            id,
            "gateway_restart",
            "gateway:restart:fixture-unknown",
            "known=true;sessions=0",
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                Err(GatewayOperationError::unknown(
                    "Gateway restart response was lost.",
                ))
            },
        );
        let replay = run_operation_once(
            id,
            "gateway_restart",
            "gateway:restart:fixture-unknown",
            "known=true;sessions=0",
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok("must-not-run".to_owned())
            },
        );

        let expected = GatewayOperationError::unknown("Gateway restart response was lost.");
        assert_eq!(first, Err(expected.clone()));
        assert_eq!(replay, Err(expected));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn management_material_accepts_only_strict_loopback_credentials() {
        let valid = format!(
            r#"{{"management_token":"{}","setup_fingerprint":"{}","setup_listen":"127.0.0.1:9799"}}"#,
            "A".repeat(43),
            "a".repeat(64),
        );
        let parsed = parse_management_material(valid.as_bytes()).unwrap();
        assert_eq!(parsed.port, 9799);

        for invalid in [
            valid.replace("127.0.0.1:9799", "0.0.0.0:9799"),
            valid.replace(&"A".repeat(43), "short"),
            valid.replace(&"a".repeat(64), &"z".repeat(64)),
        ] {
            assert!(parse_management_material(invalid.as_bytes()).is_err());
        }
    }

    #[test]
    fn management_http_parser_handles_length_and_chunked_without_extra_bytes() {
        let length = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"accepted\":true}";
        let (status, body) = parse_management_http_response(length).unwrap();
        assert_eq!(status, 200);
        assert_eq!(body, br#"{"accepted":true}"#);

        let chunked = b"HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n11\r\n{\"accepted\":true}\r\n0\r\n\r\n";
        let (status, body) = parse_management_http_response(chunked).unwrap();
        assert_eq!(status, 202);
        assert_eq!(body, br#"{"accepted":true}"#);

        let trailing = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}x";
        assert!(parse_management_http_response(trailing).is_err());
    }
}
