use super::{
    AdbEndpoint, EmulatorCapabilities, EmulatorDisplay, EmulatorOrientation, EmulatorProvider,
    EmulatorRuntimeState, EmulatorState, EmulatorTarget, ProviderId,
};
use hbb_common::{bail, config::Config, log, ResultType};
use serde_json::Value;
use std::{
    collections::HashSet,
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use winreg::{enums::*, RegKey};

const PROVIDER_ID: &str = "ldplayer";
const LIST2_CURRENT_FIELD_COUNT: usize = 10;
const ADB_BASE_SERIAL_PORT: u32 = 5554;
const OPTION_INSTALL_DIR: &str = "emulator-ldplayer-install-dir";
const ENV_INSTALL_DIR: &str = "RUSTDESK_LDPLAYER_INSTALL_DIR";
const LDPLAYER_REGISTRY_PATH: &str = r"SOFTWARE\XuanZhi\LDPlayer9";
const COMMAND_TIMEOUT: Duration = Duration::from_secs(8);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(25);
const RESTART_STOP_TIMEOUT: Duration = Duration::from_secs(15);
const RESTART_STOP_POLL_INTERVAL: Duration = Duration::from_millis(200);

#[derive(Clone, Debug, Eq, PartialEq)]
struct LdPlayerInstanceRecord {
    index: u32,
    name: String,
    top_window_handle: i64,
    bind_window_handle: i64,
    runtime_status: u32,
    process_id: i64,
    headless_process_id: i64,
    width: u32,
    height: u32,
    dpi: u32,
}

fn parse_list2(output: &str) -> ResultType<Vec<LdPlayerInstanceRecord>> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .enumerate()
        .map(|(line_index, line)| parse_list2_line(line_index + 1, line))
        .collect()
}

fn parse_list2_line(line_number: usize, line: &str) -> ResultType<LdPlayerInstanceRecord> {
    let fields: Vec<_> = line.split(',').map(str::trim).collect();
    if fields.len() < LIST2_CURRENT_FIELD_COUNT {
        bail!(
            "LDPlayer list2 line {line_number} has {} fields; expected at least {LIST2_CURRENT_FIELD_COUNT} fields",
            fields.len()
        );
    }

    Ok(LdPlayerInstanceRecord {
        index: parse_number(fields[0], line_number, "index")?,
        name: fields[1].to_owned(),
        top_window_handle: parse_number(fields[2], line_number, "top window handle")?,
        bind_window_handle: parse_number(fields[3], line_number, "bind window handle")?,
        runtime_status: parse_number(fields[4], line_number, "runtime status")?,
        process_id: parse_number(fields[5], line_number, "process id")?,
        headless_process_id: parse_number(fields[6], line_number, "headless process id")?,
        width: parse_number(fields[7], line_number, "width")?,
        height: parse_number(fields[8], line_number, "height")?,
        dpi: parse_number(fields[9], line_number, "dpi")?,
    })
}

fn parse_number<T>(value: &str, line_number: usize, field_name: &str) -> ResultType<T>
where
    T: std::str::FromStr,
{
    value.parse::<T>().map_err(|_| {
        hbb_common::anyhow::anyhow!(
            "LDPlayer list2 line {line_number} has invalid {field_name}: '{value}'"
        )
    })
}

fn coarse_state(record: &LdPlayerInstanceRecord, adb_enabled: Option<bool>) -> EmulatorState {
    let has_process = record.process_id > 0 || record.headless_process_id > 0;
    if record.runtime_status == 0 && !has_process {
        return EmulatorState::Stopped;
    }
    if record.runtime_status != 1 || record.headless_process_id <= 0 {
        return EmulatorState::Starting;
    }
    if adb_enabled == Some(false) {
        return EmulatorState::AdbOffline;
    }
    EmulatorState::Booting
}

fn stable_id(index: u32) -> String {
    format!("{PROVIDER_ID}:{index}")
}

fn adb_serial(index: u32) -> ResultType<String> {
    let offset = index
        .checked_mul(2)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("LDPlayer index is too large: {index}"))?;
    let port = ADB_BASE_SERIAL_PORT.checked_add(offset).ok_or_else(|| {
        hbb_common::anyhow::anyhow!("LDPlayer ADB serial overflow for index {index}")
    })?;
    Ok(format!("emulator-{port}"))
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct LdPlayerInstanceConfig {
    player_name: Option<String>,
    adb_enabled: Option<bool>,
    width: Option<u32>,
    height: Option<u32>,
    dpi: Option<u32>,
}

fn parse_instance_config(raw: &str) -> ResultType<LdPlayerInstanceConfig> {
    let value: Value = serde_json::from_str(raw)?;
    let object = value.as_object().ok_or_else(|| {
        hbb_common::anyhow::anyhow!("LDPlayer instance config must be a JSON object")
    })?;

    let resolution = object
        .get("advancedSettings.resolution")
        .and_then(Value::as_object);

    Ok(LdPlayerInstanceConfig {
        player_name: object
            .get("statusSettings.playerName")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        adb_enabled: object.get("basicSettings.adbDebug").and_then(json_bool),
        width: resolution.and_then(|r| r.get("width")).and_then(json_u32),
        height: resolution.and_then(|r| r.get("height")).and_then(json_u32),
        dpi: object
            .get("advancedSettings.resolutionDpi")
            .and_then(json_u32),
    })
}

fn json_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(value) => Some(*value),
        Value::Number(value) => value.as_i64().map(|value| value != 0),
        Value::String(value) => match value.trim() {
            "1" | "true" | "TRUE" | "True" => Some(true),
            "0" | "false" | "FALSE" | "False" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn json_u32(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
}

fn select_install_dir<I>(
    override_dir: Option<PathBuf>,
    candidates: I,
) -> ResultType<Option<PathBuf>>
where
    I: IntoIterator<Item = PathBuf>,
{
    if let Some(path) = override_dir {
        if is_valid_install_dir(&path) {
            return Ok(Some(path));
        }
        bail!(
            "LDPlayer install override '{}' does not contain ldconsole.exe and adb.exe",
            path.display()
        );
    }

    Ok(candidates
        .into_iter()
        .find(|path| is_valid_install_dir(path)))
}

fn is_valid_install_dir(path: &Path) -> bool {
    path.join("ldconsole.exe").is_file() && path.join("adb.exe").is_file()
}

#[derive(Clone, Debug)]
struct CommandResult {
    success: bool,
    timed_out: bool,
    stdout: String,
    stderr: String,
}

trait CommandRunner: Send + Sync {
    fn run(&self, program: &Path, args: &[String]) -> ResultType<CommandResult>;
}

#[derive(Default)]
struct SystemCommandRunner;

impl CommandRunner for SystemCommandRunner {
    fn run(&self, program: &Path, args: &[String]) -> ResultType<CommandResult> {
        let mut child = Command::new(program)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let started_at = Instant::now();

        loop {
            if let Some(status) = child.try_wait()? {
                let mut stdout = Vec::new();
                let mut stderr = Vec::new();
                if let Some(mut pipe) = child.stdout.take() {
                    pipe.read_to_end(&mut stdout)?;
                }
                if let Some(mut pipe) = child.stderr.take() {
                    pipe.read_to_end(&mut stderr)?;
                }
                return Ok(CommandResult {
                    success: status.success(),
                    timed_out: false,
                    stdout: String::from_utf8_lossy(&stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&stderr).into_owned(),
                });
            }

            if started_at.elapsed() >= COMMAND_TIMEOUT {
                let _ = child.kill();
                let _ = child.wait();
                drop(child.stdout.take());
                drop(child.stderr.take());
                return Ok(CommandResult {
                    success: false,
                    timed_out: true,
                    stdout: String::new(),
                    stderr: String::new(),
                });
            }

            thread::sleep(COMMAND_POLL_INTERVAL);
        }
    }
}

pub struct LdPlayerProvider {
    install_dir: PathBuf,
    console_path: PathBuf,
    runner: Arc<dyn CommandRunner>,
}

impl LdPlayerProvider {
    pub fn detect() -> ResultType<Option<Self>> {
        let override_dir = configured_install_override();
        let candidates = detected_install_candidates();
        let Some(install_dir) = select_install_dir(override_dir, candidates)? else {
            log::debug!("LDPlayer installation was not detected");
            return Ok(None);
        };
        log::debug!(
            "detected LDPlayer installation at '{}'",
            install_dir.display()
        );
        Self::with_runner(install_dir, Arc::new(SystemCommandRunner)).map(Some)
    }

    fn with_runner(install_dir: PathBuf, runner: Arc<dyn CommandRunner>) -> ResultType<Self> {
        if !is_valid_install_dir(&install_dir) {
            bail!(
                "LDPlayer install directory '{}' does not contain ldconsole.exe and adb.exe",
                install_dir.display()
            );
        }
        Ok(Self {
            console_path: install_dir.join("ldconsole.exe"),
            install_dir,
            runner,
        })
    }

    fn run_console(&self, args: &[String]) -> ResultType<CommandResult> {
        self.runner.run(&self.console_path, args)
    }

    fn run_console_checked(&self, args: &[String]) -> ResultType<()> {
        let result = self.run_console(args)?;
        if result.timed_out {
            bail!("LDPlayer command '{}' timed out", args.join(" "));
        }
        let error_text = command_error_text(&result);
        if !result.success || error_text.is_some() {
            bail!(
                "LDPlayer command '{}' failed: {}",
                args.join(" "),
                error_text.unwrap_or_else(|| "non-zero exit status".to_owned())
            );
        }
        Ok(())
    }

    fn wait_until_stopped(&self, index: u32, timeout: Duration) -> ResultType<()> {
        let started_at = Instant::now();
        loop {
            let record = self.find_record(index)?;
            if coarse_state(&record, None) == EmulatorState::Stopped {
                return Ok(());
            }
            if started_at.elapsed() >= timeout {
                bail!("LDPlayer instance {index} did not stop within {timeout:?}");
            }
            let remaining = timeout.saturating_sub(started_at.elapsed());
            thread::sleep(RESTART_STOP_POLL_INTERVAL.min(remaining));
        }
    }

    fn read_instance_config(&self, index: u32) -> ResultType<LdPlayerInstanceConfig> {
        let path = self
            .install_dir
            .join("vms")
            .join("config")
            .join(format!("leidian{index}.config"));
        match fs::read_to_string(&path) {
            Ok(raw) => parse_instance_config(&raw),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                Ok(LdPlayerInstanceConfig::default())
            }
            Err(err) => bail!(
                "failed to read LDPlayer instance config '{}': {err}",
                path.display()
            ),
        }
    }

    fn list_records(&self) -> ResultType<Vec<LdPlayerInstanceRecord>> {
        let result = self.run_console(&["list2".to_owned()])?;
        if result.timed_out {
            bail!("LDPlayer list2 timed out");
        }
        if !result.success {
            bail!(
                "LDPlayer list2 failed: {}",
                nonempty_output(&result).unwrap_or_else(|| "non-zero exit status".to_owned())
            );
        }
        parse_list2(&result.stdout)
    }

    fn find_record(&self, index: u32) -> ResultType<LdPlayerInstanceRecord> {
        self.list_records()?
            .into_iter()
            .find(|record| record.index == index)
            .ok_or_else(|| {
                hbb_common::anyhow::anyhow!("LDPlayer instance {index} no longer exists")
            })
    }

    fn record_to_target(&self, record: LdPlayerInstanceRecord) -> ResultType<EmulatorTarget> {
        let config = self.read_instance_config(record.index)?;
        let state = coarse_state(&record, config.adb_enabled);
        let display = display_from_record(&record);
        let mut target = EmulatorTarget::new(
            ProviderId::new(PROVIDER_ID),
            stable_id(record.index),
            record.index.to_string(),
            record.name,
        );
        target.state = state;
        target.adb_endpoint = Some(AdbEndpoint::new(adb_serial(record.index)?));
        target.display = Some(display);
        target.capabilities = capabilities_for_config(&config);
        if state == EmulatorState::AdbOffline && config.adb_enabled == Some(false) {
            target.last_error = Some("ADB debugging is disabled in LDPlayer settings".to_owned());
        }
        Ok(target)
    }

    fn target_index(&self, target: &EmulatorTarget) -> ResultType<u32> {
        if target.provider != ProviderId::new(PROVIDER_ID) {
            bail!(
                "LDPlayer provider cannot operate target owned by '{}'",
                target.provider
            );
        }
        let index = target.provider_instance_id.parse::<u32>().map_err(|_| {
            hbb_common::anyhow::anyhow!(
                "invalid LDPlayer provider instance id '{}'",
                target.provider_instance_id
            )
        })?;
        let expected_stable_id = stable_id(index);
        if target.stable_id != expected_stable_id {
            bail!(
                "LDPlayer target identity mismatch: expected '{expected_stable_id}', got '{}'",
                target.stable_id
            );
        }
        Ok(index)
    }

    fn probe_adb_state(&self, index: u32) -> ResultType<AdbProbe> {
        let result = self.run_console(&[
            "adb".to_owned(),
            "--index".to_owned(),
            index.to_string(),
            "--command".to_owned(),
            "get-state".to_owned(),
        ])?;
        Ok(classify_adb_probe(&result))
    }

    fn probe_boot_completed(&self, index: u32) -> ResultType<BootProbe> {
        let result = self.run_console(&[
            "adb".to_owned(),
            "--index".to_owned(),
            index.to_string(),
            "--command".to_owned(),
            "shell getprop sys.boot_completed".to_owned(),
        ])?;
        Ok(classify_boot_probe(&result))
    }

    pub fn start_and_wait_ready<F>(
        &self,
        target: &EmulatorTarget,
        timeout: Duration,
        poll_interval: Duration,
        mut cancelled: F,
    ) -> ResultType<EmulatorRuntimeState>
    where
        F: FnMut() -> bool,
    {
        self.start(target)?;
        let started_at = Instant::now();
        loop {
            if cancelled() {
                bail!("LDPlayer Start & Connect was cancelled");
            }
            if started_at.elapsed() >= timeout {
                bail!("LDPlayer Start & Connect timed out after {timeout:?}");
            }

            let runtime = self.refresh(target)?;
            if runtime.state == EmulatorState::Ready {
                return Ok(runtime);
            }
            if matches!(
                runtime.state,
                EmulatorState::Error | EmulatorState::Unresponsive
            ) {
                bail!(
                    "LDPlayer failed while waiting for Android: {}",
                    runtime
                        .last_error
                        .unwrap_or_else(|| format!("state {:?}", runtime.state))
                );
            }
            if runtime.state == EmulatorState::AdbOffline
                && runtime
                    .last_error
                    .as_deref()
                    .map(|message| message.to_ascii_lowercase().contains("disabled"))
                    .unwrap_or(false)
            {
                bail!(
                    "LDPlayer cannot become ready: {}",
                    runtime.last_error.unwrap_or_default()
                );
            }

            if !poll_interval.is_zero() {
                let remaining = timeout.saturating_sub(started_at.elapsed());
                if remaining.is_zero() {
                    bail!("LDPlayer Start & Connect timed out after {timeout:?}");
                }
                thread::sleep(poll_interval.min(remaining));
            }
        }
    }
}

impl EmulatorProvider for LdPlayerProvider {
    fn provider_id(&self) -> ProviderId {
        ProviderId::new(PROVIDER_ID)
    }

    fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
        let records = self.list_records()?;
        log::debug!("LDPlayer discovered {} configured instances", records.len());
        records
            .into_iter()
            .map(|record| self.record_to_target(record))
            .collect()
    }

    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
        let index = self.target_index(target)?;
        let record = self.find_record(index)?;
        let config = self.read_instance_config(index)?;
        let endpoint = AdbEndpoint::new(adb_serial(index)?);
        let display = display_from_record(&record);
        let state = coarse_state(&record, config.adb_enabled);

        if state != EmulatorState::Booting {
            return Ok(EmulatorRuntimeState {
                state,
                adb_endpoint: Some(endpoint),
                display: Some(display),
                last_error: if state == EmulatorState::AdbOffline
                    && config.adb_enabled == Some(false)
                {
                    Some("ADB debugging is disabled in LDPlayer settings".to_owned())
                } else {
                    None
                },
                ..Default::default()
            });
        }

        match self.probe_adb_state(index)? {
            AdbProbe::Online => match self.probe_boot_completed(index)? {
                BootProbe::Complete => Ok(EmulatorRuntimeState {
                    state: EmulatorState::Ready,
                    adb_endpoint: Some(endpoint),
                    display: Some(display),
                    ..Default::default()
                }),
                BootProbe::Booting => Ok(EmulatorRuntimeState {
                    state: EmulatorState::Booting,
                    adb_endpoint: Some(endpoint),
                    display: Some(display),
                    ..Default::default()
                }),
                BootProbe::Offline(message) => Ok(EmulatorRuntimeState {
                    state: EmulatorState::AdbOffline,
                    adb_endpoint: Some(endpoint),
                    display: Some(display),
                    last_error: Some(message),
                    ..Default::default()
                }),
                BootProbe::Error(message) => Ok(EmulatorRuntimeState {
                    state: EmulatorState::Unresponsive,
                    adb_endpoint: Some(endpoint),
                    display: Some(display),
                    last_error: Some(message),
                    ..Default::default()
                }),
            },
            AdbProbe::Missing => Ok(EmulatorRuntimeState {
                state: EmulatorState::Booting,
                adb_endpoint: Some(endpoint),
                display: Some(display),
                ..Default::default()
            }),
            AdbProbe::Offline(message) => Ok(EmulatorRuntimeState {
                state: EmulatorState::AdbOffline,
                adb_endpoint: Some(endpoint),
                display: Some(display),
                last_error: Some(message),
                ..Default::default()
            }),
            AdbProbe::Error(message) => Ok(EmulatorRuntimeState {
                state: EmulatorState::Unresponsive,
                adb_endpoint: Some(endpoint),
                display: Some(display),
                last_error: Some(message),
                ..Default::default()
            }),
        }
    }

    fn start(&self, target: &EmulatorTarget) -> ResultType<()> {
        let index = self.target_index(target)?;
        log::debug!("starting LDPlayer instance {index}");
        self.run_console_checked(&["launch".to_owned(), "--index".to_owned(), index.to_string()])
    }

    fn stop(&self, target: &EmulatorTarget) -> ResultType<()> {
        let index = self.target_index(target)?;
        log::debug!("stopping LDPlayer instance {index}");
        self.run_console_checked(&["quit".to_owned(), "--index".to_owned(), index.to_string()])
    }

    fn restart(&self, target: &EmulatorTarget) -> ResultType<()> {
        let index = self.target_index(target)?;
        log::debug!("restarting LDPlayer instance {index}");
        self.stop(target)?;
        self.wait_until_stopped(index, RESTART_STOP_TIMEOUT)?;
        self.start(target)
    }

    fn resolve_adb(&self, target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
        let index = self.target_index(target)?;
        Ok(AdbEndpoint::new(adb_serial(index)?))
    }

    fn capabilities(&self, target: &EmulatorTarget) -> EmulatorCapabilities {
        let config = self
            .target_index(target)
            .and_then(|index| self.read_instance_config(index))
            .unwrap_or_default();
        capabilities_for_config(&config)
    }
}

fn capabilities_for_config(config: &LdPlayerInstanceConfig) -> EmulatorCapabilities {
    EmulatorCapabilities {
        start: true,
        stop: true,
        restart: true,
        adb: config.adb_enabled != Some(false),
        ..Default::default()
    }
}

fn display_from_record(record: &LdPlayerInstanceRecord) -> EmulatorDisplay {
    let orientation = if record.width == 0 || record.height == 0 {
        EmulatorOrientation::Unknown
    } else if record.width >= record.height {
        EmulatorOrientation::Landscape
    } else {
        EmulatorOrientation::Portrait
    };
    EmulatorDisplay {
        width: record.width,
        height: record.height,
        dpi: record.dpi,
        orientation,
    }
}

#[derive(Debug, Eq, PartialEq)]
enum AdbProbe {
    Online,
    Missing,
    Offline(String),
    Error(String),
}

fn classify_adb_probe(result: &CommandResult) -> AdbProbe {
    if result.timed_out {
        return AdbProbe::Missing;
    }
    let stdout = result.stdout.trim();
    let combined = combined_output(result);
    let lower = combined.to_ascii_lowercase();
    if stdout.eq_ignore_ascii_case("device") {
        AdbProbe::Online
    } else if lower.contains("offline") {
        AdbProbe::Offline(
            nonempty_output(result).unwrap_or_else(|| "ADB device is offline".to_owned()),
        )
    } else if lower.contains("not found")
        || lower.contains("no devices")
        || lower.contains("no device")
        || combined.trim().is_empty()
    {
        AdbProbe::Missing
    } else {
        AdbProbe::Error(
            nonempty_output(result).unwrap_or_else(|| "ADB state probe failed".to_owned()),
        )
    }
}

#[derive(Debug, Eq, PartialEq)]
enum BootProbe {
    Complete,
    Booting,
    Offline(String),
    Error(String),
}

fn classify_boot_probe(result: &CommandResult) -> BootProbe {
    if result.timed_out {
        return BootProbe::Booting;
    }
    let stdout = result.stdout.trim();
    let combined = combined_output(result);
    let lower = combined.to_ascii_lowercase();
    if stdout == "1" {
        BootProbe::Complete
    } else if lower.contains("offline") {
        BootProbe::Offline(
            nonempty_output(result).unwrap_or_else(|| "ADB device is offline".to_owned()),
        )
    } else if result.success
        || lower.contains("not found")
        || lower.contains("no devices")
        || lower.contains("no device")
        || stdout.is_empty()
    {
        BootProbe::Booting
    } else {
        BootProbe::Error(
            nonempty_output(result).unwrap_or_else(|| "Android boot probe failed".to_owned()),
        )
    }
}

fn command_error_text(result: &CommandResult) -> Option<String> {
    let combined = combined_output(result);
    if combined.to_ascii_lowercase().contains("error:") {
        Some(combined.trim().to_owned())
    } else {
        None
    }
}

fn combined_output(result: &CommandResult) -> String {
    format!("{}\n{}", result.stdout, result.stderr)
}

fn nonempty_output(result: &CommandResult) -> Option<String> {
    let combined = combined_output(result);
    let trimmed = combined.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn configured_install_override() -> Option<PathBuf> {
    std::env::var_os(ENV_INSTALL_DIR)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            let configured = Config::get_option(OPTION_INSTALL_DIR);
            (!configured.trim().is_empty()).then(|| PathBuf::from(configured.trim()))
        })
}

fn detected_install_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    candidates.extend(running_process_install_candidates());
    candidates.extend(registry_install_candidates());
    candidates.extend(common_install_candidates());
    dedupe_paths(candidates)
}

fn running_process_install_candidates() -> Vec<PathBuf> {
    let system = hbb_common::sysinfo::System::new_all();
    system
        .processes()
        .values()
        .filter(|process| {
            process.name().eq_ignore_ascii_case("dnplayer.exe")
                || process.name().eq_ignore_ascii_case("ldconsole.exe")
                || process.name().eq_ignore_ascii_case("dnconsole.exe")
        })
        .filter_map(|process| process.exe().parent().map(Path::to_path_buf))
        .collect()
}

fn registry_install_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for hive in [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER] {
        let root = RegKey::predef(hive);
        if let Ok(key) = root.open_subkey_with_flags(LDPLAYER_REGISTRY_PATH, KEY_READ) {
            if let Ok(value) = key.get_value::<String, _>("InstallDir") {
                if !value.trim().is_empty() {
                    candidates.push(PathBuf::from(value.trim()));
                }
            }
        }
    }
    candidates
}

fn common_install_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for variable in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Some(root) = std::env::var_os(variable) {
            let root = PathBuf::from(root);
            candidates.push(root.join("LDPlayer").join("LDPlayer9"));
            candidates.push(root.join("LDPlayer9"));
        }
    }
    candidates
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    paths
        .into_iter()
        .filter(|path| seen.insert(path.to_string_lossy().to_ascii_lowercase()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::VecDeque,
        fs,
        path::PathBuf,
        sync::{Arc, Mutex},
        time::{Duration, Instant, SystemTime, UNIX_EPOCH},
    };

    const CURRENT_LIST2: &str = "\
0,LDPlayer-1-2-0,0,0,0,-1,-1,1280,720,240\r\n\
2,LDPlayer-1-2,0,0,0,-1,-1,1280,720,240\r\n\
3,HomeHubEufy,0,0,0,-1,-1,1280,720,280\r\n";

    #[test]
    fn parses_current_list2_output() {
        let records = parse_list2(CURRENT_LIST2).unwrap();

        assert_eq!(records.len(), 3);
        assert_eq!(records[0].index, 0);
        assert_eq!(records[0].name, "LDPlayer-1-2-0");
        assert_eq!(records[0].runtime_status, 0);
        assert_eq!(records[0].process_id, -1);
        assert_eq!(records[0].headless_process_id, -1);
        assert_eq!(
            (records[0].width, records[0].height, records[0].dpi),
            (1280, 720, 240)
        );
        assert_eq!(records[2].dpi, 280);
    }

    #[test]
    fn accepts_additional_future_list2_fields() {
        let records = parse_list2("7,Future,11,22,1,333,444,1920,1080,320,new,fields\n").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].index, 7);
        assert_eq!(records[0].name, "Future");
        assert_eq!(records[0].runtime_status, 1);
    }

    #[test]
    fn rejects_missing_list2_fields() {
        let err = parse_list2("0,TooShort,0,0,0,-1,-1,1280,720\n").unwrap_err();

        assert!(err.to_string().contains("10 fields"));
    }

    #[test]
    fn rejects_malformed_numeric_list2_fields() {
        let err = parse_list2("0,Bad,0,0,ready,-1,-1,1280,720,240\n").unwrap_err();

        assert!(err.to_string().contains("runtime status"));
    }

    #[test]
    fn empty_list2_output_is_a_valid_empty_inventory() {
        assert!(parse_list2("\r\n").unwrap().is_empty());
    }

    #[test]
    fn classifies_stopped_starting_and_booting_from_current_runtime_fields() {
        let stopped = parse_list2("0,Stopped,0,0,0,-1,-1,1280,720,240\n").unwrap();
        let starting = parse_list2("0,Starting,724694,331372,2,26036,-1,1280,720,240\n").unwrap();
        let booting = parse_list2("0,Booting,724694,331372,1,26036,29752,1280,720,240\n").unwrap();

        assert_eq!(coarse_state(&stopped[0], None), EmulatorState::Stopped);
        assert_eq!(coarse_state(&starting[0], None), EmulatorState::Starting);
        assert_eq!(
            coarse_state(&booting[0], Some(true)),
            EmulatorState::Booting
        );
        assert_eq!(
            coarse_state(&booting[0], Some(false)),
            EmulatorState::AdbOffline
        );
    }

    #[test]
    fn stable_id_uses_provider_index_and_survives_rename() {
        assert_eq!(stable_id(3), "ldplayer:3");
        let before = parse_list2("3,OldName,0,0,0,-1,-1,1280,720,280\n").unwrap();
        let after = parse_list2("3,NewName,0,0,0,-1,-1,1280,720,280\n").unwrap();

        assert_eq!(stable_id(before[0].index), stable_id(after[0].index));
    }

    #[test]
    fn maps_current_ldplayer_indices_to_adb_serials() {
        assert_eq!(adb_serial(0).unwrap(), "emulator-5554");
        assert_eq!(adb_serial(2).unwrap(), "emulator-5558");
        assert_eq!(adb_serial(3).unwrap(), "emulator-5560");
    }

    #[test]
    fn parses_current_instance_config_metadata() {
        let config = parse_instance_config(
            r#"{
                "statusSettings.playerName": "Main",
                "basicSettings.adbDebug": 0,
                "advancedSettings.resolution": {"width": 1280, "height": 720},
                "advancedSettings.resolutionDpi": 240
            }"#,
        )
        .unwrap();

        assert_eq!(config.player_name.as_deref(), Some("Main"));
        assert_eq!(config.adb_enabled, Some(false));
        assert_eq!(config.width, Some(1280));
        assert_eq!(config.height, Some(720));
        assert_eq!(config.dpi, Some(240));
    }

    #[test]
    fn accepts_missing_optional_instance_config_fields() {
        let config = parse_instance_config("{}").unwrap();

        assert_eq!(config, LdPlayerInstanceConfig::default());
    }

    #[test]
    fn rejects_malformed_instance_config() {
        assert!(parse_instance_config("{not json}").is_err());
    }

    #[test]
    fn install_selection_returns_none_when_provider_is_not_installed() {
        assert_eq!(
            select_install_dir(None, Vec::<PathBuf>::new()).unwrap(),
            None
        );
    }

    #[test]
    fn install_selection_accepts_a_valid_discovered_directory() {
        let dir = temp_install_dir("discovered");
        create_install_files(&dir);

        let selected = select_install_dir(None, vec![dir.clone()]).unwrap();

        assert_eq!(selected.as_deref(), Some(dir.as_path()));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn explicit_install_override_is_validated() {
        let dir = temp_install_dir("invalid-override");
        fs::create_dir_all(&dir).unwrap();

        let err = select_install_dir(Some(dir.clone()), Vec::<PathBuf>::new()).unwrap_err();

        assert!(err.to_string().contains("override"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_discovers_zero_instances() {
        let dir = temp_install_dir("zero");
        create_install_files(&dir);
        let runner = FakeRunner::new(vec![ok("")]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let targets = provider.discover().unwrap();

        assert!(targets.is_empty());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_discovers_multiple_instances_with_normalized_metadata() {
        let dir = temp_install_dir("multiple");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        write_instance_config(&dir, 2, false);
        let runner = FakeRunner::new(vec![ok("0,Main,0,0,0,-1,-1,1280,720,240\n\
             2,Farm,724694,331372,1,26036,29752,1920,1080,320\n")]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let targets = provider.discover().unwrap();

        assert_eq!(targets.len(), 2);
        assert_eq!(targets[0].stable_id, "ldplayer:0");
        assert_eq!(targets[0].display_name, "Main");
        assert_eq!(targets[0].state, EmulatorState::Stopped);
        assert_eq!(
            targets[0].adb_endpoint.as_ref().unwrap().serial,
            "emulator-5554"
        );
        assert_eq!(targets[0].display.as_ref().unwrap().width, 1280);
        assert_eq!(targets[0].display.as_ref().unwrap().height, 720);
        assert_eq!(targets[0].display.as_ref().unwrap().dpi, 240);
        assert_eq!(targets[1].stable_id, "ldplayer:2");
        assert_eq!(targets[1].state, EmulatorState::AdbOffline);
        assert!(targets[1]
            .last_error
            .as_deref()
            .unwrap()
            .contains("disabled"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refresh_marks_boot_completed_android_ready() {
        let dir = temp_install_dir("ready");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            ok("device\r\n"),
            ok("1\r\n"),
        ]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();
        let target = target_for_index(0, "Main");

        let state = provider.refresh(&target).unwrap();

        assert_eq!(state.state, EmulatorState::Ready);
        assert_eq!(state.adb_endpoint.unwrap().serial, "emulator-5554");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refresh_distinguishes_adb_offline_from_android_booting() {
        let dir = temp_install_dir("offline");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            ok_err("", "error: device offline\r\n"),
        ]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let state = provider.refresh(&target_for_index(0, "Main")).unwrap();

        assert_eq!(state.state, EmulatorState::AdbOffline);
        assert!(state.last_error.unwrap().contains("offline"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refresh_keeps_missing_adb_target_in_booting_state() {
        let dir = temp_install_dir("booting");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            ok_err("", "error: device 'emulator-5554' not found\r\n"),
        ]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let state = provider.refresh(&target_for_index(0, "Main")).unwrap();

        assert_eq!(state.state, EmulatorState::Booting);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refresh_keeps_timed_out_adb_probe_in_booting_state() {
        let dir = temp_install_dir("adb-timeout");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            timed_out(),
        ]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let state = provider.refresh(&target_for_index(0, "Main")).unwrap();

        assert_eq!(state.state, EmulatorState::Booting);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refresh_keeps_timed_out_boot_probe_in_booting_state() {
        let dir = temp_install_dir("boot-probe-timeout");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            ok("device\r\n"),
            timed_out(),
        ]);
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let state = provider.refresh(&target_for_index(0, "Main")).unwrap();

        assert_eq!(state.state, EmulatorState::Booting);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn restart_stops_waits_for_stopped_then_launches() {
        let dir = temp_install_dir("restart");
        create_install_files(&dir);
        let runner = FakeRunner::new(vec![
            ok(""),
            ok("3,HomeHubEufy,0,0,0,-1,-1,1280,720,280\n"),
            ok(""),
        ]);
        let calls = runner.calls.clone();
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        provider
            .restart(&target_for_index(3, "HomeHubEufy"))
            .unwrap();

        assert_eq!(
            calls.lock().unwrap().as_slice(),
            &[
                vec!["quit".to_owned(), "--index".to_owned(), "3".to_owned()],
                vec!["list2".to_owned()],
                vec!["launch".to_owned(), "--index".to_owned(), "3".to_owned()],
            ]
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_capabilities_reflect_instance_adb_setting() {
        let dir = temp_install_dir("capabilities");
        create_install_files(&dir);
        write_instance_config(&dir, 0, false);
        let provider =
            LdPlayerProvider::with_runner(dir.clone(), Arc::new(FakeRunner::new(vec![]))).unwrap();

        let capabilities = provider.capabilities(&target_for_index(0, "Main"));

        assert!(capabilities.start);
        assert!(capabilities.stop);
        assert!(capabilities.restart);
        assert!(!capabilities.adb);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn start_and_wait_ready_runs_launch_then_waits_for_android() {
        let dir = temp_install_dir("start-and-wait");
        create_install_files(&dir);
        write_instance_config(&dir, 0, true);
        let runner = FakeRunner::new(vec![
            ok(""),
            ok("0,Main,724694,331372,1,26036,29752,1280,720,240\n"),
            ok("device\r\n"),
            ok("1\r\n"),
        ]);
        let calls = runner.calls.clone();
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();

        let runtime = provider
            .start_and_wait_ready(
                &target_for_index(0, "Main"),
                Duration::from_secs(1),
                Duration::ZERO,
                || false,
            )
            .unwrap();

        assert_eq!(runtime.state, EmulatorState::Ready);
        assert_eq!(calls.lock().unwrap()[0], vec!["launch", "--index", "0"]);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn start_and_wait_ready_honors_cancellation() {
        let dir = temp_install_dir("start-and-cancel");
        create_install_files(&dir);
        let provider =
            LdPlayerProvider::with_runner(dir.clone(), Arc::new(FakeRunner::new(vec![ok("")])))
                .unwrap();

        let err = provider
            .start_and_wait_ready(
                &target_for_index(0, "Main"),
                Duration::from_secs(1),
                Duration::ZERO,
                || true,
            )
            .unwrap_err();

        assert!(err.to_string().contains("cancelled"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn start_and_wait_ready_honors_timeout() {
        let dir = temp_install_dir("start-and-timeout");
        create_install_files(&dir);
        let provider =
            LdPlayerProvider::with_runner(dir.clone(), Arc::new(FakeRunner::new(vec![ok("")])))
                .unwrap();

        let err = provider
            .start_and_wait_ready(
                &target_for_index(0, "Main"),
                Duration::ZERO,
                Duration::ZERO,
                || false,
            )
            .unwrap_err();

        assert!(err.to_string().contains("timed out"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn start_and_stop_route_to_instance_specific_commands() {
        let dir = temp_install_dir("lifecycle");
        create_install_files(&dir);
        let runner = FakeRunner::new(vec![ok(""), ok("")]);
        let calls = runner.calls.clone();
        let provider = LdPlayerProvider::with_runner(dir.clone(), Arc::new(runner)).unwrap();
        let target = target_for_index(2, "Farm");

        provider.start(&target).unwrap();
        provider.stop(&target).unwrap();

        assert_eq!(
            calls.lock().unwrap().as_slice(),
            &[
                vec!["launch".to_owned(), "--index".to_owned(), "2".to_owned()],
                vec!["quit".to_owned(), "--index".to_owned(), "2".to_owned()],
            ]
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn lifecycle_rejects_mismatched_stable_identity() {
        let dir = temp_install_dir("identity-mismatch");
        create_install_files(&dir);
        let provider =
            LdPlayerProvider::with_runner(dir.clone(), Arc::new(FakeRunner::new(vec![]))).unwrap();
        let mut target = target_for_index(2, "Farm");
        target.stable_id = "ldplayer:3".to_owned();

        assert!(provider.start(&target).is_err());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[ignore = "requires a local LDPlayer installation"]
    fn detects_and_discovers_real_local_ldplayer_installation() {
        let provider = LdPlayerProvider::detect()
            .unwrap()
            .expect("LDPlayer should be installed");
        let targets = provider.discover().unwrap();

        assert!(!targets.is_empty());
        for target in targets {
            println!(
                "{} {} state={:?} adb={:?} display={:?} capabilities={:?}",
                target.stable_id,
                target.display_name,
                target.state,
                target.adb_endpoint,
                target.display,
                target.capabilities
            );
        }
    }

    #[test]
    #[ignore = "requires a local LDPlayer installation and changes emulator lifecycle state"]
    fn real_local_ldplayer_lifecycle_roundtrip() {
        let provider = LdPlayerProvider::detect()
            .unwrap()
            .expect("LDPlayer should be installed");
        let target = provider
            .discover()
            .unwrap()
            .into_iter()
            .find(|target| target.state == EmulatorState::Stopped && target.capabilities.adb)
            .expect("requires at least one stopped LDPlayer instance with ADB enabled");

        let result: ResultType<()> = (|| {
            let ready = provider.start_and_wait_ready(
                &target,
                Duration::from_secs(90),
                Duration::from_secs(1),
                || false,
            )?;
            println!("after start: {:?} {:?}", ready.state, ready.adb_endpoint);
            if ready.state != EmulatorState::Ready {
                bail!("real LDPlayer instance did not reach Ready state");
            }

            provider.restart(&target)?;
            println!("restart command succeeded for {}", target.stable_id);

            let restart_deadline = Instant::now() + Duration::from_secs(90);
            loop {
                let runtime = provider.refresh(&target)?;
                println!("after restart: {:?}", runtime.state);
                if runtime.state == EmulatorState::Ready {
                    break;
                }
                if Instant::now() >= restart_deadline {
                    bail!("real LDPlayer instance did not return to Ready after restart");
                }
                std::thread::sleep(Duration::from_secs(1));
            }

            provider.stop(&target)?;
            let stop_deadline = Instant::now() + Duration::from_secs(25);
            loop {
                let runtime = provider.refresh(&target)?;
                println!("after stop: {:?}", runtime.state);
                if runtime.state == EmulatorState::Stopped {
                    break;
                }
                if Instant::now() >= stop_deadline {
                    bail!("real LDPlayer instance did not reach Stopped state");
                }
                std::thread::sleep(Duration::from_millis(500));
            }
            Ok(())
        })();

        let _ = provider.stop(&target);
        result.unwrap();
    }

    fn temp_install_dir(suffix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("rustdesk-ldplayer-{suffix}-{nonce}"))
    }

    fn create_install_files(dir: &std::path::Path) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join("ldconsole.exe"), b"fixture").unwrap();
        fs::write(dir.join("adb.exe"), b"fixture").unwrap();
    }

    fn write_instance_config(dir: &std::path::Path, index: u32, adb_enabled: bool) {
        let config_dir = dir.join("vms").join("config");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join(format!("leidian{index}.config")),
            format!(
                "{{\"basicSettings.adbDebug\":{},\"statusSettings.playerName\":\"Fixture\"}}",
                if adb_enabled { 1 } else { 0 }
            ),
        )
        .unwrap();
    }

    fn target_for_index(index: u32, name: &str) -> EmulatorTarget {
        EmulatorTarget::new(
            ProviderId::new(PROVIDER_ID),
            stable_id(index),
            index.to_string(),
            name,
        )
    }

    #[derive(Clone, Debug)]
    struct FakeRunner {
        responses: Arc<Mutex<VecDeque<CommandResult>>>,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
    }

    impl FakeRunner {
        fn new(responses: Vec<CommandResult>) -> Self {
            Self {
                responses: Arc::new(Mutex::new(responses.into())),
                calls: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    impl CommandRunner for FakeRunner {
        fn run(&self, _program: &std::path::Path, args: &[String]) -> ResultType<CommandResult> {
            self.calls.lock().unwrap().push(args.to_vec());
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| hbb_common::anyhow::anyhow!("unexpected fake command: {args:?}"))
        }
    }

    fn ok(stdout: &str) -> CommandResult {
        CommandResult {
            success: true,
            timed_out: false,
            stdout: stdout.to_owned(),
            stderr: String::new(),
        }
    }

    fn ok_err(stdout: &str, stderr: &str) -> CommandResult {
        CommandResult {
            success: true,
            timed_out: false,
            stdout: stdout.to_owned(),
            stderr: stderr.to_owned(),
        }
    }

    fn timed_out() -> CommandResult {
        CommandResult {
            success: false,
            timed_out: true,
            stdout: String::new(),
            stderr: String::new(),
        }
    }
}
