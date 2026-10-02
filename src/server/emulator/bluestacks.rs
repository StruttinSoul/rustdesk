use super::{
    AdbEndpoint, EmulatorCapabilities, EmulatorDisplay, EmulatorOrientation, EmulatorProvider,
    EmulatorRuntimeState, EmulatorState, EmulatorTarget, ProviderId,
};
use hbb_common::{bail, log, ResultType};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use winreg::{enums::*, RegKey};

const PROVIDER_ID: &str = "bluestacks";
const BLUESTACKS_REGISTRY_PATH: &str = r"SOFTWARE\BlueStacks_nxt";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlueStacksInstallation {
    pub install_dir: PathBuf,
    pub data_dir: Option<PathBuf>,
    pub user_defined_dir: PathBuf,
    pub config_path: PathBuf,
    pub version: String,
}

impl BlueStacksInstallation {
    pub fn player_path(&self) -> PathBuf {
        self.install_dir.join("HD-Player.exe")
    }

    pub fn adb_path(&self) -> PathBuf {
        self.install_dir.join("HD-Adb.exe")
    }

    pub fn multi_instance_manager_path(&self) -> PathBuf {
        self.install_dir.join("HD-MultiInstanceManager.exe")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BlueStacksConfigDocument {
    source: String,
    values: BTreeMap<String, String>,
}

impl BlueStacksConfigDocument {
    fn parse(source: &str) -> ResultType<Self> {
        let mut values = BTreeMap::new();
        for (line_number, line) in source.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, encoded_value)) = line.split_once('=') else {
                bail!(
                    "BlueStacks config line {} is not a key/value pair",
                    line_number + 1
                );
            };
            let key = key.trim();
            if key.is_empty() {
                bail!("BlueStacks config line {} has an empty key", line_number + 1);
            }
            let encoded_value = encoded_value.trim();
            let value = encoded_value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .unwrap_or(encoded_value);
            values.insert(key.to_owned(), value.to_owned());
        }
        Ok(Self {
            source: source.to_owned(),
            values,
        })
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    fn render(&self) -> String {
        self.source.clone()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BlueStacksInstanceInfo {
    id: String,
    display_name: String,
    android_flavor: Option<String>,
    android_version: Option<String>,
    running: bool,
    adb_enabled: bool,
    adb_port: Option<u16>,
    notifications_enabled: Option<bool>,
    width: Option<u32>,
    height: Option<u32>,
    dpi: Option<u32>,
}

fn instances_from_config(
    document: &BlueStacksConfigDocument,
    running_commands: &[Vec<String>],
) -> Vec<BlueStacksInstanceInfo> {
    const INSTANCE_PREFIX: &str = "bst.instance.";
    let mut ids = BTreeSet::new();
    for key in document.values.keys() {
        let Some(remainder) = key.strip_prefix(INSTANCE_PREFIX) else {
            continue;
        };
        if let Some((id, _)) = remainder.split_once('.') {
            if !id.is_empty() {
                ids.insert(id.to_owned());
            }
        }
    }

    let adb_enabled = config_bool(document.get("bst.enable_adb_access")) == Some(true);
    ids.into_iter()
        .map(|id| {
            let prefix = format!("{INSTANCE_PREFIX}{id}.");
            let value = |suffix: &str| document.get(&format!("{prefix}{suffix}"));
            let (flavor, version) = android_metadata(&id);
            BlueStacksInstanceInfo {
                display_name: value("display_name")
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or(&id)
                    .to_owned(),
                android_flavor: flavor.map(str::to_owned),
                android_version: version.map(str::to_owned),
                running: running_commands
                    .iter()
                    .any(|command| command_line_has_instance(command, &id)),
                adb_enabled,
                adb_port: value("status.adb_port")
                    .or_else(|| value("adb_port"))
                    .and_then(|value| value.parse::<u16>().ok()),
                notifications_enabled: config_bool(value("enable_notifications")),
                width: value("fb_width").and_then(|value| value.parse::<u32>().ok()),
                height: value("fb_height").and_then(|value| value.parse::<u32>().ok()),
                dpi: value("dpi").and_then(|value| value.parse::<u32>().ok()),
                id,
            }
        })
        .collect()
}

fn config_bool(value: Option<&str>) -> Option<bool> {
    match value?.trim() {
        "1" | "true" | "TRUE" | "True" => Some(true),
        "0" | "false" | "FALSE" | "False" => Some(false),
        _ => None,
    }
}

fn android_metadata(instance_id: &str) -> (Option<&'static str>, Option<&'static str>) {
    let base = instance_id
        .split_once('_')
        .map(|(base, _)| base)
        .unwrap_or(instance_id);
    match base {
        "Nougat32" => (Some("Nougat 32-bit"), Some("7.1.2")),
        "Nougat64" => (Some("Nougat 64-bit"), Some("7.1.2")),
        "Pie64" => (Some("Pie 64-bit"), Some("9")),
        "Rvc64" => (Some("Android 11"), Some("11")),
        "Android13" => (Some("Android 13"), Some("13")),
        _ => (None, None),
    }
}

fn command_line_has_instance(command: &[String], instance_id: &str) -> bool {
    command.windows(2).any(|args| {
        args[0].eq_ignore_ascii_case("--instance") && args[1].eq_ignore_ascii_case(instance_id)
    })
}

fn direct_launch_args(instance_id: &str, package: &str) -> ResultType<Vec<String>> {
    if instance_id.is_empty()
        || !instance_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
    {
        bail!("invalid BlueStacks instance id '{instance_id}'");
    }
    if package.is_empty()
        || !package.contains('.')
        || !package
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_'))
    {
        bail!("invalid Android package '{package}'");
    }
    Ok([
        "--instance",
        instance_id,
        "--cmd",
        "launchApp",
        "--package",
        package,
        "--source",
        "desktop_shortcut",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect())
}

fn is_valid_installation(install_dir: &Path, config_path: &Path) -> bool {
    install_dir.join("HD-Player.exe").is_file()
        && install_dir.join("HD-Adb.exe").is_file()
        && config_path.is_file()
}

fn instance_to_target(instance: &BlueStacksInstanceInfo) -> EmulatorTarget {
    let state = if !instance.running {
        EmulatorState::Stopped
    } else if !instance.adb_enabled {
        EmulatorState::AdbOffline
    } else {
        EmulatorState::Booting
    };
    let mut target = EmulatorTarget::new(
        ProviderId::new(PROVIDER_ID),
        format!("{PROVIDER_ID}:{}", instance.id),
        instance.id.clone(),
        instance.display_name.clone(),
    );
    target.android_flavor = instance.android_flavor.clone();
    target.android_version = instance.android_version.clone();
    target.state = state;
    target.adb_endpoint = instance
        .adb_port
        .map(|port| AdbEndpoint::new(format!("127.0.0.1:{port}")));
    target.display = match (instance.width, instance.height) {
        (Some(width), Some(height)) => Some(EmulatorDisplay {
            width,
            height,
            dpi: instance.dpi.unwrap_or_default(),
            orientation: if width == 0 || height == 0 {
                EmulatorOrientation::Unknown
            } else if width >= height {
                EmulatorOrientation::Landscape
            } else {
                EmulatorOrientation::Portrait
            },
        }),
        _ => None,
    };
    target.capabilities = capabilities_for_instance(instance);
    if state == EmulatorState::AdbOffline {
        target.last_error = Some(
            "BlueStacks ADB access is disabled; enable it manually in BlueStacks Advanced settings if remote Android control is needed"
                .to_owned(),
        );
    }
    target
}

fn capabilities_for_instance(instance: &BlueStacksInstanceInfo) -> EmulatorCapabilities {
    EmulatorCapabilities {
        start: true,
        stop: false,
        restart: false,
        adb: instance.adb_enabled && instance.adb_port.is_some(),
        ..Default::default()
    }
}

fn running_player_commands() -> Vec<Vec<String>> {
    let system = hbb_common::sysinfo::System::new_all();
    system
        .processes()
        .values()
        .filter(|process| process.name().eq_ignore_ascii_case("HD-Player.exe"))
        .map(|process| process.cmd().to_vec())
        .collect()
}

fn registry_installation() -> Option<BlueStacksInstallation> {
    let root = RegKey::predef(HKEY_LOCAL_MACHINE);
    let mut seen = BTreeSet::new();
    for flags in [
        KEY_READ | KEY_WOW64_64KEY,
        KEY_READ | KEY_WOW64_32KEY,
        KEY_READ,
    ] {
        let Ok(key) = root.open_subkey_with_flags(BLUESTACKS_REGISTRY_PATH, flags) else {
            continue;
        };
        let Ok(install_dir) = key.get_value::<String, _>("InstallDir") else {
            continue;
        };
        let Ok(user_defined_dir) = key.get_value::<String, _>("UserDefinedDir") else {
            continue;
        };
        let install_dir = PathBuf::from(install_dir.trim());
        let user_defined_dir = PathBuf::from(user_defined_dir.trim());
        let identity = format!(
            "{}|{}",
            install_dir.to_string_lossy().to_ascii_lowercase(),
            user_defined_dir.to_string_lossy().to_ascii_lowercase()
        );
        if !seen.insert(identity) {
            continue;
        }
        let config_path = user_defined_dir.join("bluestacks.conf");
        if !is_valid_installation(&install_dir, &config_path) {
            continue;
        }
        return Some(BlueStacksInstallation {
            install_dir,
            data_dir: key
                .get_value::<String, _>("DataDir")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .map(|value| PathBuf::from(value.trim())),
            user_defined_dir,
            config_path,
            version: key
                .get_value::<String, _>("Version")
                .unwrap_or_default()
                .trim()
                .to_owned(),
        });
    }
    None
}

pub struct BlueStacksProvider {
    installation: BlueStacksInstallation,
}

impl BlueStacksProvider {
    pub fn detect() -> ResultType<Option<Self>> {
        let Some(installation) = registry_installation() else {
            log::debug!("BlueStacks 5 installation was not detected in the registry");
            return Ok(None);
        };
        log::debug!(
            "detected BlueStacks {} at '{}'",
            installation.version,
            installation.install_dir.display()
        );
        Ok(Some(Self { installation }))
    }

    pub fn installation(&self) -> &BlueStacksInstallation {
        &self.installation
    }

    fn read_config(&self) -> ResultType<BlueStacksConfigDocument> {
        let raw = fs::read_to_string(&self.installation.config_path)?;
        BlueStacksConfigDocument::parse(&raw)
    }

    fn instances(&self) -> ResultType<Vec<BlueStacksInstanceInfo>> {
        let config = self.read_config()?;
        Ok(instances_from_config(&config, &running_player_commands()))
    }

    fn target_instance_id<'a>(&self, target: &'a EmulatorTarget) -> ResultType<&'a str> {
        if target.provider != ProviderId::new(PROVIDER_ID) {
            bail!(
                "BlueStacks provider cannot operate target owned by '{}'",
                target.provider
            );
        }
        let instance_id = target.provider_instance_id.as_str();
        let expected = format!("{PROVIDER_ID}:{instance_id}");
        if target.stable_id != expected {
            bail!(
                "BlueStacks target identity mismatch: expected '{expected}', got '{}'",
                target.stable_id
            );
        }
        Ok(instance_id)
    }

    pub fn launch_package(&self, target: &EmulatorTarget, package: &str) -> ResultType<()> {
        let instance_id = self.target_instance_id(target)?;
        let args = direct_launch_args(instance_id, package)?;
        Command::new(self.installation.player_path()).args(args).spawn()?;
        Ok(())
    }
}

impl EmulatorProvider for BlueStacksProvider {
    fn provider_id(&self) -> ProviderId {
        ProviderId::new(PROVIDER_ID)
    }

    fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
        Ok(self
            .instances()?
            .iter()
            .map(instance_to_target)
            .collect())
    }

    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
        let instance_id = self.target_instance_id(target)?;
        let instance = self
            .instances()?
            .into_iter()
            .find(|instance| instance.id == instance_id)
            .ok_or_else(|| {
                hbb_common::anyhow::anyhow!(
                    "BlueStacks instance '{instance_id}' no longer exists"
                )
            })?;
        let normalized = instance_to_target(&instance);
        Ok(EmulatorRuntimeState {
            state: normalized.state,
            adb_endpoint: normalized.adb_endpoint,
            display: normalized.display,
            foreground_package: None,
            foreground_app_name: None,
            last_error: normalized.last_error,
        })
    }

    fn start(&self, target: &EmulatorTarget) -> ResultType<()> {
        let instance_id = self.target_instance_id(target)?;
        Command::new(self.installation.player_path())
            .args(["--instance", instance_id])
            .spawn()?;
        Ok(())
    }

    fn stop(&self, target: &EmulatorTarget) -> ResultType<()> {
        let _ = self.target_instance_id(target)?;
        bail!("BlueStacks per-instance stop is unavailable through a supported interface")
    }

    fn restart(&self, target: &EmulatorTarget) -> ResultType<()> {
        let _ = self.target_instance_id(target)?;
        bail!("BlueStacks per-instance restart is unavailable through a supported interface")
    }

    fn resolve_adb(&self, target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
        let instance_id = self.target_instance_id(target)?;
        let instance = self
            .instances()?
            .into_iter()
            .find(|instance| instance.id == instance_id)
            .ok_or_else(|| {
                hbb_common::anyhow::anyhow!(
                    "BlueStacks instance '{instance_id}' no longer exists"
                )
            })?;
        if !instance.adb_enabled {
            bail!("BlueStacks ADB access is disabled")
        }
        let port = instance
            .adb_port
            .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks ADB port is unavailable"))?;
        Ok(AdbEndpoint::new(format!("127.0.0.1:{port}")))
    }

    fn capabilities(&self, target: &EmulatorTarget) -> EmulatorCapabilities {
        if self.target_instance_id(target).is_err() {
            return EmulatorCapabilities::default();
        }
        target.capabilities.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf, time::{SystemTime, UNIX_EPOCH}};

    const CURRENT_CONF: &str = r#"bst.enable_adb_access="0"
bst.enable_programmatic_ads="1"
bst.enable_smart_downloads="0"
bst.instance.Nougat32.adb_port="5555"
bst.instance.Nougat32.display_name="BlueStacks App Player"
bst.instance.Nougat32.dpi="240"
bst.instance.Nougat32.enable_notifications="1"
bst.instance.Nougat32.fb_height="1080"
bst.instance.Nougat32.fb_width="1920"
bst.instance.Nougat32.status.adb_port="5555"
bst.launch_store_on_boot="1"
bst.status.hypervisor="hyperv"
"#;

    #[test]
    fn parses_bluestacks_conf_values_without_losing_unknown_lines() {
        let document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();

        assert_eq!(document.get("bst.enable_adb_access"), Some("0"));
        assert_eq!(
            document.get("bst.instance.Nougat32.display_name"),
            Some("BlueStacks App Player")
        );
        assert_eq!(document.get("bst.status.hypervisor"), Some("hyperv"));
        assert_eq!(document.render(), CURRENT_CONF);
    }

    #[test]
    fn enumerates_instances_from_provider_native_config_keys() {
        let document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();
        let instances = instances_from_config(&document, &[]);

        assert_eq!(instances.len(), 1);
        let instance = &instances[0];
        assert_eq!(instance.id, "Nougat32");
        assert_eq!(instance.display_name, "BlueStacks App Player");
        assert_eq!(instance.android_flavor.as_deref(), Some("Nougat 32-bit"));
        assert_eq!(instance.android_version.as_deref(), Some("7.1.2"));
        assert_eq!(instance.adb_port, Some(5555));
        assert!(!instance.adb_enabled);
        assert!(!instance.running);
        assert_eq!(instance.width, Some(1920));
        assert_eq!(instance.height, Some(1080));
        assert_eq!(instance.dpi, Some(240));
    }

    #[test]
    fn maps_supported_bluestacks_android_flavors() {
        assert_eq!(
            android_metadata("Nougat32"),
            (Some("Nougat 32-bit"), Some("7.1.2"))
        );
        assert_eq!(
            android_metadata("Nougat64_2"),
            (Some("Nougat 64-bit"), Some("7.1.2"))
        );
        assert_eq!(
            android_metadata("Pie64"),
            (Some("Pie 64-bit"), Some("9"))
        );
        assert_eq!(
            android_metadata("Rvc64_1"),
            (Some("Android 11"), Some("11"))
        );
        assert_eq!(
            android_metadata("Android13"),
            (Some("Android 13"), Some("13"))
        );
        assert_eq!(android_metadata("Future64"), (None, None));
    }

    #[test]
    fn matches_running_instance_from_hd_player_command_line() {
        let command = vec![
            r"C:\Program Files\BlueStacks_nxt\HD-Player.exe".to_owned(),
            "--instance".to_owned(),
            "Nougat32".to_owned(),
            "--cmd".to_owned(),
            "launchApp".to_owned(),
        ];

        assert!(command_line_has_instance(&command, "Nougat32"));
        assert!(!command_line_has_instance(&command, "Pie64"));
    }

    #[test]
    fn builds_official_direct_app_shortcut_arguments() {
        let args = direct_launch_args("Nougat32", "com.nexon.maplem.global").unwrap();

        assert_eq!(
            args,
            vec![
                "--instance",
                "Nougat32",
                "--cmd",
                "launchApp",
                "--package",
                "com.nexon.maplem.global",
                "--source",
                "desktop_shortcut",
            ]
        );
    }

    #[test]
    fn rejects_invalid_android_package_for_direct_launch() {
        let err = direct_launch_args("Nougat32", "com.example.game & calc.exe").unwrap_err();
        assert!(err.to_string().contains("invalid Android package"));
    }

    #[test]
    fn validates_only_complete_official_bluestacks_installations() {
        let dir = temp_dir("valid-install");
        let config_path = dir.join("data").join("bluestacks.conf");
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        fs::write(dir.join("HD-Player.exe"), b"").unwrap();
        fs::write(dir.join("HD-Adb.exe"), b"").unwrap();
        fs::write(&config_path, CURRENT_CONF).unwrap();

        assert!(is_valid_installation(&dir, &config_path));
        fs::remove_file(dir.join("HD-Adb.exe")).unwrap();
        assert!(!is_valid_installation(&dir, &config_path));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn normalizes_provider_instance_without_advertising_unsupported_stop() {
        let document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();
        let instance = instances_from_config(&document, &[]).remove(0);
        let target = instance_to_target(&instance);

        assert_eq!(target.stable_id, "bluestacks:Nougat32");
        assert_eq!(target.display_name, "BlueStacks App Player");
        assert_eq!(target.state, EmulatorState::Stopped);
        assert!(!target.capabilities.adb);
        assert!(target.capabilities.start);
        assert!(!target.capabilities.stop);
        assert!(!target.capabilities.restart);
        assert_eq!(target.android_version.as_deref(), Some("7.1.2"));
        assert_eq!(target.display.as_ref().map(|display| display.width), Some(1920));
    }

    #[test]
    fn running_instance_with_disabled_adb_reports_adb_offline() {
        let document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();
        let running = vec![vec![
            "HD-Player.exe".to_owned(),
            "--instance".to_owned(),
            "Nougat32".to_owned(),
        ]];
        let instance = instances_from_config(&document, &running).remove(0);
        let target = instance_to_target(&instance);

        assert_eq!(target.state, EmulatorState::AdbOffline);
        assert!(target
            .last_error
            .as_deref()
            .unwrap_or_default()
            .contains("disabled"));
    }

    #[test]
    #[ignore = "requires a local BlueStacks 5 installation; read-only"]
    fn detects_and_discovers_real_local_bluestacks_installation() {
        let provider = BlueStacksProvider::detect()
            .unwrap()
            .expect("BlueStacks 5 should be installed");
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

    fn temp_dir(suffix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("rustdesk-bluestacks-{suffix}-{nonce}"))
    }
}
