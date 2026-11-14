use super::{
    AdbEndpoint, EmulatorCapabilities, EmulatorDisplay, EmulatorOrientation, EmulatorProvider,
    EmulatorRuntimeState, EmulatorState, EmulatorTarget, ProviderId,
};
use hbb_common::{bail, config::Config, log, ResultType};
use serde_derive::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use winreg::{enums::*, RegKey};

const PROVIDER_ID: &str = "bluestacks";
const BLUESTACKS_REGISTRY_PATH: &str = r"SOFTWARE\BlueStacks_nxt";
const WINDOWS_RUN_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
const WINDOWS_UNINSTALL_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
const WINDOWS_SERVICES_KEY: &str = r"SYSTEM\CurrentControlSet\Services";
const OPTION_CLEANUP_JOURNAL: &str = "emulator-bluestacks-cleanup-journal";
const OPTION_CLEANUP_VERSION: &str = "emulator-bluestacks-cleanup-version";
const OPTION_CLEANUP_SELECTION: &str = "emulator-bluestacks-cleanup-selection";
const OPTION_DEFAULT_APPS: &str = "emulator-bluestacks-default-apps";
const COMMAND_TIMEOUT: Duration = Duration::from_secs(8);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(25);
const DEFAULT_LAUNCH_TIMEOUT: Duration = Duration::from_secs(90);
const DEFAULT_LAUNCH_POLL_INTERVAL: Duration = Duration::from_millis(750);

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
                bail!(
                    "BlueStacks config line {} has an empty key",
                    line_number + 1
                );
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

    fn set_existing(&mut self, key: &str, value: &str) -> bool {
        if !self.values.contains_key(key) {
            return false;
        }
        if self.get(key) == Some(value) {
            return true;
        }

        let mut rendered = String::with_capacity(self.source.len());
        let mut replaced = false;
        for chunk in self.source.split_inclusive('\n') {
            let (line, ending) = if let Some(line) = chunk.strip_suffix("\r\n") {
                (line, "\r\n")
            } else if let Some(line) = chunk.strip_suffix('\n') {
                (line, "\n")
            } else {
                (chunk, "")
            };
            let matches_key = line
                .split_once('=')
                .map(|(candidate, _)| candidate.trim() == key)
                .unwrap_or(false);
            if matches_key {
                rendered.push_str(key);
                rendered.push_str("=\"");
                rendered.push_str(value);
                rendered.push('"');
                rendered.push_str(ending);
                replaced = true;
            } else {
                rendered.push_str(line);
                rendered.push_str(ending);
            }
        }
        if !replaced {
            return false;
        }
        self.source = rendered;
        self.values.insert(key.to_owned(), value.to_owned());
        true
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CleanupProfile {
    Standard,
    CleanGaming,
    Custom,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupSelection {
    pub disable_gameplay_ads: bool,
    pub disable_smart_downloads: bool,
    pub disable_store_on_start: bool,
    pub disable_desktop_notifications: bool,
    pub disable_app_shortcuts: bool,
    pub disable_optional_startup: bool,
    pub hide_desktop_shortcuts: bool,
    /// Destructive choices intentionally remain outside all profile presets.
    pub remove_optional_components: bool,
    /// Android cleanup is review-driven rather than a profile side effect.
    pub disable_optional_android_apps: bool,
}

impl CleanupSelection {
    pub fn for_profile(profile: CleanupProfile) -> Self {
        match profile {
            CleanupProfile::Standard => Self {
                disable_gameplay_ads: true,
                disable_smart_downloads: true,
                disable_store_on_start: true,
                ..Default::default()
            },
            CleanupProfile::CleanGaming => Self {
                disable_gameplay_ads: true,
                disable_smart_downloads: true,
                disable_store_on_start: true,
                disable_desktop_notifications: true,
                disable_app_shortcuts: true,
                disable_optional_startup: true,
                hide_desktop_shortcuts: true,
                ..Default::default()
            },
            CleanupProfile::Custom => Self::default(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ConfigChange {
    pub key: String,
    pub original_value: String,
    pub applied_value: String,
}

impl ConfigChange {
    fn new(key: &str, original_value: &str, applied_value: &str) -> Self {
        Self {
            key: key.to_owned(),
            original_value: original_value.to_owned(),
            applied_value: applied_value.to_owned(),
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct StartupChange {
    pub hive: String,
    pub key_path: String,
    pub value_name: String,
    pub original_command: String,
    #[serde(default)]
    pub registry_view: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ShortcutChange {
    pub original_path: String,
    pub disabled_path: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct RemovedComponentRecord {
    pub id: String,
    pub display_name: String,
    pub version: String,
    pub install_location: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupJournal {
    #[serde(default)]
    pub config_changes: Vec<ConfigChange>,
    #[serde(default)]
    pub startup_changes: Vec<StartupChange>,
    #[serde(default)]
    pub shortcut_changes: Vec<ShortcutChange>,
    #[serde(default)]
    pub disabled_android_packages: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub removed_components: Vec<RemovedComponentRecord>,
}

impl CleanupJournal {
    fn record_config_change(&mut self, key: &str, original_value: &str, applied_value: &str) {
        if self.config_changes.iter().any(|change| change.key == key) {
            return;
        }
        self.config_changes
            .push(ConfigChange::new(key, original_value, applied_value));
    }

    fn record_startup_change(&mut self, entry: &BlueStacksStartupEntry) {
        if self.startup_changes.iter().any(|change| {
            change.hive == entry.hive
                && change.key_path == entry.key_path
                && change.value_name == entry.value_name
                && change.registry_view == entry.registry_view
        }) {
            return;
        }
        self.startup_changes.push(StartupChange {
            hive: entry.hive.clone(),
            key_path: entry.key_path.clone(),
            value_name: entry.value_name.clone(),
            original_command: entry.command.clone(),
            registry_view: entry.registry_view.clone(),
        });
    }

    fn is_empty(&self) -> bool {
        self.config_changes.is_empty()
            && self.startup_changes.is_empty()
            && self.shortcut_changes.is_empty()
            && self
                .disabled_android_packages
                .values()
                .all(|packages| packages.is_empty())
            && self.removed_components.is_empty()
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RestoreConfigReport {
    restored: Vec<String>,
    skipped_conflicts: Vec<String>,
}

fn restore_config_changes(
    document: &mut BlueStacksConfigDocument,
    journal: &CleanupJournal,
) -> RestoreConfigReport {
    let mut report = RestoreConfigReport::default();
    for change in &journal.config_changes {
        match document.get(&change.key) {
            Some(current) if current == change.applied_value => {
                if document.set_existing(&change.key, &change.original_value) {
                    report.restored.push(change.key.clone());
                }
            }
            Some(current) if current == change.original_value => {
                // Already restored outside this tool; no action required.
                report.restored.push(change.key.clone());
            }
            Some(_) => report.skipped_conflicts.push(change.key.clone()),
            None => report.skipped_conflicts.push(change.key.clone()),
        }
    }
    report
}

fn apply_config_cleanup(
    document: &mut BlueStacksConfigDocument,
    selection: &CleanupSelection,
    journal: &mut CleanupJournal,
) -> Vec<String> {
    let mut desired = Vec::<(String, &'static str)>::new();
    if selection.disable_gameplay_ads {
        desired.push(("bst.enable_programmatic_ads".to_owned(), "0"));
    }
    if selection.disable_smart_downloads {
        desired.push(("bst.enable_smart_downloads".to_owned(), "0"));
    }
    if selection.disable_store_on_start {
        desired.push(("bst.launch_store_on_boot".to_owned(), "0"));
    }
    if selection.disable_app_shortcuts {
        desired.push(("bst.create_desktop_shortcuts".to_owned(), "0"));
    }
    if selection.disable_desktop_notifications {
        desired.extend(
            document
                .values
                .keys()
                .filter(|key| {
                    key.starts_with("bst.instance.") && key.ends_with(".enable_notifications")
                })
                .cloned()
                .map(|key| (key, "0")),
        );
    }

    let mut changed = Vec::new();
    for (key, applied_value) in desired {
        let Some(original_value) = document.get(&key).map(str::to_owned) else {
            continue;
        };
        if original_value == applied_value {
            continue;
        }
        journal.record_config_change(&key, &original_value, applied_value);
        if document.set_existing(&key, applied_value) {
            changed.push(key);
        }
    }
    changed
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComponentClassification {
    Required,
    FeatureSpecific,
    Optional,
    PromotionalFrontend,
    Unknown,
}

fn classify_component(display_name: &str) -> ComponentClassification {
    let normalized = display_name.trim().to_ascii_lowercase();
    if matches!(
        normalized.as_str(),
        "bluestacks" | "bluestacks 5" | "bluestacks app player"
    ) {
        ComponentClassification::Required
    } else if normalized.contains("bluestacks services") {
        ComponentClassification::FeatureSpecific
    } else if normalized == "bluestacks x" || normalized.starts_with("bluestacks x ") {
        ComponentClassification::PromotionalFrontend
    } else if normalized.contains("bluestacks ai") || normalized.contains("blueai") {
        ComponentClassification::Optional
    } else {
        ComponentClassification::Unknown
    }
}

fn classify_service(name: &str, display_name: &str, image_path: &str) -> ComponentClassification {
    let normalized = format!("{name} {display_name} {image_path}").to_ascii_lowercase();
    if normalized.contains("bluestacks hypervisor")
        || normalized.contains("bluestacksdrv")
        || normalized.contains("bstkdrv")
        || normalized.contains("bstksvc")
    {
        ComponentClassification::Required
    } else {
        ComponentClassification::Unknown
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AndroidPackageClassification {
    ProtectedSystem,
    ProtectedGoogle,
    ProtectedBlueStacks,
    UserInstalled,
    OptionalPromotional,
    Unknown,
}

fn classify_android_package(package: &str, user_installed: bool) -> AndroidPackageClassification {
    let package = package.trim().to_ascii_lowercase();
    if package == "com.uncube.gamevantage" {
        return AndroidPackageClassification::OptionalPromotional;
    }
    if package == "com.android.vending" || package.starts_with("com.google.") {
        return AndroidPackageClassification::ProtectedGoogle;
    }
    if package == "android"
        || package.starts_with("com.android.")
        || package.starts_with("org.chromium.")
    {
        return AndroidPackageClassification::ProtectedSystem;
    }
    if package.starts_with("com.bluestacks.")
        || package.starts_with("com.bst.")
        || package.starts_with("com.nowgg.bluestacks")
    {
        return AndroidPackageClassification::ProtectedBlueStacks;
    }
    if user_installed {
        AndroidPackageClassification::UserInstalled
    } else {
        AndroidPackageClassification::Unknown
    }
}

fn validate_android_disable(package: &str, user_installed: bool) -> ResultType<()> {
    if classify_android_package(package, user_installed)
        != AndroidPackageClassification::OptionalPromotional
    {
        bail!("Android package '{package}' is protected or not approved for cleanup");
    }
    Ok(())
}

fn cleanup_needs_reapply(last_applied_version: &str, current_version: &str) -> bool {
    !last_applied_version.trim().is_empty()
        && !current_version.trim().is_empty()
        && last_applied_version.trim() != current_version.trim()
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct StartupEntryClassification {
    pub classification: ComponentClassification,
    pub safe_to_disable: bool,
}

fn classify_startup_entry(name: &str, command: &str) -> StartupEntryClassification {
    let combined = format!("{} {}", name, command).to_ascii_lowercase();
    if combined.contains("updater") || combined.contains("bstksvc") {
        return StartupEntryClassification {
            classification: ComponentClassification::Required,
            safe_to_disable: false,
        };
    }
    if combined.contains("hd-player.exe") && combined.contains("bluestacks") {
        return StartupEntryClassification {
            classification: ComponentClassification::FeatureSpecific,
            safe_to_disable: true,
        };
    }
    if combined.contains("bluestacks services") || combined.contains("bluestacksservices") {
        return StartupEntryClassification {
            classification: ComponentClassification::FeatureSpecific,
            safe_to_disable: true,
        };
    }
    if combined.contains("bluestacks x") || combined.contains("bluestacksx") {
        return StartupEntryClassification {
            classification: ComponentClassification::PromotionalFrontend,
            safe_to_disable: true,
        };
    }
    if combined.contains("blueai") || combined.contains("bluestacks ai") {
        return StartupEntryClassification {
            classification: ComponentClassification::Optional,
            safe_to_disable: true,
        };
    }
    StartupEntryClassification {
        classification: ComponentClassification::Unknown,
        safe_to_disable: false,
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RestorePathReport {
    restored: Vec<String>,
    skipped_conflicts: Vec<String>,
}

fn disabled_shortcut_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".rustdesk-disabled");
    PathBuf::from(value)
}

fn disable_shortcut(path: &Path, journal: &mut CleanupJournal) -> ResultType<bool> {
    if journal
        .shortcut_changes
        .iter()
        .any(|change| Path::new(&change.original_path) == path)
    {
        return Ok(false);
    }
    if !path.is_file() {
        return Ok(false);
    }
    let disabled_path = disabled_shortcut_path(path);
    if disabled_path.exists() {
        bail!(
            "cannot hide BlueStacks shortcut '{}' because '{}' already exists",
            path.display(),
            disabled_path.display()
        );
    }
    fs::rename(path, &disabled_path)?;
    journal.shortcut_changes.push(ShortcutChange {
        original_path: path.to_string_lossy().into_owned(),
        disabled_path: disabled_path.to_string_lossy().into_owned(),
    });
    Ok(true)
}

fn apply_recommended_shortcut_cleanup(
    shortcuts: Vec<BlueStacksShortcut>,
    journal: &mut CleanupJournal,
    report: &mut CleanupApplyReport,
) -> ResultType<()> {
    for shortcut in shortcuts
        .into_iter()
        .filter(|shortcut| shortcut.recommended_cleanup)
    {
        let path = PathBuf::from(&shortcut.path);
        match disable_shortcut(&path, journal) {
            Ok(true) => {
                report.hidden_shortcuts.push(shortcut.path.clone());
                save_cleanup_journal(journal);
                log::info!("BlueStacks cleanup hid desktop shortcut {}", shortcut.path);
            }
            Ok(false) => {}
            Err(error) => {
                let requires_admin = error
                    .downcast_ref::<std::io::Error>()
                    .and_then(std::io::Error::raw_os_error)
                    == Some(5);
                log::warn!(
                    "BlueStacks cleanup skipped desktop shortcut {}: {}",
                    shortcut.path,
                    error
                );
                report.skipped_actions.push(CleanupSkippedAction {
                    action: "hide_desktop_shortcut".to_owned(),
                    target: shortcut.path,
                    error: error.to_string(),
                    requires_admin,
                });
            }
        }
    }
    Ok(())
}

fn restore_shortcut_changes(journal: &mut CleanupJournal) -> ResultType<RestorePathReport> {
    let mut report = RestorePathReport::default();
    let mut retained = Vec::new();
    for change in journal.shortcut_changes.drain(..) {
        let original = PathBuf::from(&change.original_path);
        let disabled = PathBuf::from(&change.disabled_path);
        if original.exists() {
            if disabled.exists() {
                report.skipped_conflicts.push(change.original_path.clone());
                retained.push(change);
            } else {
                report.restored.push(change.original_path);
            }
            continue;
        }
        if disabled.exists() {
            fs::rename(&disabled, &original)?;
            report.restored.push(change.original_path);
        } else {
            report.skipped_conflicts.push(change.original_path.clone());
            retained.push(change);
        }
    }
    journal.shortcut_changes = retained;
    Ok(report)
}

#[derive(Clone, Debug, Default, Deserialize)]
struct BlueStacksAppCacheEntry {
    #[serde(default)]
    package: String,
    #[serde(default, rename = "appLabel")]
    app_label: String,
    #[serde(default)]
    activity: String,
    #[serde(default)]
    category: String,
    #[serde(default, rename = "versionName")]
    version_name: String,
}

fn parse_app_cache(raw: &str) -> Vec<BlueStacksInstalledApp> {
    let entries = match serde_json::from_str::<Vec<BlueStacksAppCacheEntry>>(raw) {
        Ok(entries) => entries,
        Err(error) => {
            log::debug!("failed to parse BlueStacks app cache: {error}");
            return Vec::new();
        }
    };
    entries
        .into_iter()
        .filter(|entry| {
            !entry.package.is_empty()
                && entry.package.contains('.')
                && entry
                    .package
                    .chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_'))
        })
        .map(|entry| BlueStacksInstalledApp {
            package: entry.package,
            label: entry.app_label,
            activity: entry.activity,
            category: entry.category,
            version_name: entry.version_name,
        })
        .collect()
}

fn read_instance_app_cache(
    installation: &BlueStacksInstallation,
    instance_id: &str,
) -> Vec<BlueStacksInstalledApp> {
    if instance_id.is_empty()
        || !instance_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
    {
        return Vec::new();
    }
    let path = installation
        .user_defined_dir
        .join("Engine")
        .join(instance_id)
        .join("AppCache")
        .join("AppCache.json");
    match fs::read_to_string(&path) {
        Ok(raw) => parse_app_cache(&raw),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => {
            log::debug!(
                "failed to read BlueStacks app cache '{}': {}",
                path.display(),
                error
            );
            Vec::new()
        }
    }
}

fn parse_package_list(output: &str) -> BTreeSet<String> {
    output
        .lines()
        .filter_map(|line| line.trim().strip_prefix("package:"))
        .map(str::trim)
        .filter(|package| !package.is_empty())
        .map(str::to_owned)
        .collect()
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DefaultApps {
    #[serde(default)]
    packages: BTreeMap<String, String>,
}

impl DefaultApps {
    fn set(&mut self, instance_id: &str, package: &str) -> ResultType<()> {
        // Reuse the same strict package validation as direct launch.
        let _ = direct_launch_args(instance_id, package)?;
        self.packages
            .insert(instance_id.to_owned(), package.to_owned());
        Ok(())
    }

    fn get(&self, instance_id: &str) -> Option<&str> {
        self.packages.get(instance_id).map(String::as_str)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShortcutLocation {
    Desktop,
    StartMenu,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksShortcut {
    pub path: String,
    pub name: String,
    pub location: ShortcutLocation,
    pub recommended_cleanup: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksStartupEntry {
    pub id: String,
    pub hive: String,
    pub key_path: String,
    pub registry_view: String,
    pub value_name: String,
    pub command: String,
    pub classification: ComponentClassification,
    pub safe_to_disable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksComponent {
    pub id: String,
    pub display_name: String,
    pub version: String,
    pub install_location: String,
    pub classification: ComponentClassification,
    pub can_remove: bool,
    #[serde(skip_serializing, default)]
    uninstall_command: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksService {
    pub name: String,
    pub display_name: String,
    pub image_path: String,
    pub classification: ComponentClassification,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AndroidPackageInfo {
    pub package: String,
    pub classification: AndroidPackageClassification,
    pub user_installed: bool,
    pub disabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AndroidPackageInventory {
    pub instance_id: String,
    pub available: bool,
    pub message: String,
    pub packages: Vec<AndroidPackageInfo>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupSkippedAction {
    pub action: String,
    pub target: String,
    pub error: String,
    pub requires_admin: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupApplyReport {
    pub changed_config_keys: Vec<String>,
    pub disabled_startup_entries: Vec<String>,
    pub hidden_shortcuts: Vec<String>,
    pub skipped_actions: Vec<CleanupSkippedAction>,
    pub version: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupRestoreReport {
    pub restored_config_keys: Vec<String>,
    pub restored_startup_entries: Vec<String>,
    pub restored_shortcuts: Vec<String>,
    pub restored_android_packages: Vec<String>,
    pub manual_reinstall_components: Vec<String>,
    pub skipped_conflicts: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LaunchReport {
    pub instance_id: String,
    pub package: String,
    pub started_instance: bool,
    pub adb_verified: bool,
    pub message: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CleanupSupport {
    pub disable_gameplay_ads: bool,
    pub disable_smart_downloads: bool,
    pub disable_store_on_start: bool,
    pub disable_desktop_notifications: bool,
    pub disable_app_shortcuts: bool,
    pub disable_optional_startup: bool,
    pub hide_desktop_shortcuts: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksInstallationInventory {
    pub version: String,
    pub install_dir: String,
    pub data_dir: String,
    pub user_defined_dir: String,
    pub config_path: String,
    pub player_path: String,
    pub adb_path: String,
    pub multi_instance_manager_path: String,
    pub multi_instance_manager_available: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksInstalledApp {
    pub package: String,
    pub label: String,
    pub activity: String,
    pub category: String,
    pub version_name: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksInstanceInventory {
    pub id: String,
    pub display_name: String,
    pub android_flavor: String,
    pub android_version: String,
    pub running: bool,
    pub adb_enabled: bool,
    pub adb_port: Option<u16>,
    pub notifications_enabled: Option<bool>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub dpi: Option<u32>,
    pub default_package: String,
    pub installed_apps: Vec<BlueStacksInstalledApp>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksInventory {
    pub installed: bool,
    pub installation: BlueStacksInstallationInventory,
    pub hypervisor: String,
    pub instances: Vec<BlueStacksInstanceInventory>,
    pub services: Vec<BlueStacksService>,
    pub startup_entries: Vec<BlueStacksStartupEntry>,
    pub shortcuts: Vec<BlueStacksShortcut>,
    pub components: Vec<BlueStacksComponent>,
    pub cleanup_support: CleanupSupport,
    pub selected_cleanup: Option<CleanupSelection>,
    pub last_cleanup_version: String,
    pub cleanup_needs_reapply: bool,
    pub restore_available: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum BlueStacksAction {
    RefreshInventory,
    ApplyProfile {
        profile: CleanupProfile,
        #[serde(default)]
        selection: Option<CleanupSelection>,
    },
    Restore,
    SetDefaultApp {
        instance_id: String,
        package: String,
    },
    PlayApp {
        instance_id: String,
        package: String,
    },
    LaunchDefaultApp {
        instance_id: String,
    },
    InspectAndroidPackages {
        instance_id: String,
    },
    DisableOptionalAndroidPackage {
        instance_id: String,
        package: String,
        #[serde(default)]
        confirmed: bool,
    },
    RemoveOptionalComponent {
        component_id: String,
        #[serde(default)]
        confirmed: bool,
    },
}

impl BlueStacksAction {
    fn name(&self) -> &'static str {
        match self {
            Self::RefreshInventory => "refresh_inventory",
            Self::ApplyProfile { .. } => "apply_profile",
            Self::Restore => "restore",
            Self::SetDefaultApp { .. } => "set_default_app",
            Self::PlayApp { .. } => "play_app",
            Self::LaunchDefaultApp { .. } => "launch_default_app",
            Self::InspectAndroidPackages { .. } => "inspect_android_packages",
            Self::DisableOptionalAndroidPackage { .. } => "disable_optional_android_package",
            Self::RemoveOptionalComponent { .. } => "remove_optional_component",
        }
    }

    fn validate_confirmation(&self) -> ResultType<()> {
        match self {
            Self::DisableOptionalAndroidPackage { confirmed, .. }
            | Self::RemoveOptionalComponent { confirmed, .. }
                if !confirmed =>
            {
                bail!("this BlueStacks action requires explicit confirmation")
            }
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BlueStacksActionResult {
    pub ok: bool,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl BlueStacksActionResult {
    fn success(action: &str, data: serde_json::Value) -> Self {
        Self {
            ok: true,
            action: action.to_owned(),
            data: Some(data),
            error: None,
        }
    }

    fn failure(action: &str, error: impl Into<String>) -> Self {
        Self {
            ok: false,
            action: action.to_owned(),
            data: None,
            error: Some(error.into()),
        }
    }
}

fn load_cleanup_journal() -> CleanupJournal {
    serde_json::from_str(&Config::get_option(OPTION_CLEANUP_JOURNAL)).unwrap_or_default()
}

fn save_cleanup_journal(journal: &CleanupJournal) {
    let encoded = serde_json::to_string(journal).unwrap_or_default();
    Config::set_option(OPTION_CLEANUP_JOURNAL.to_owned(), encoded);
}

fn load_default_apps() -> DefaultApps {
    serde_json::from_str(&Config::get_option(OPTION_DEFAULT_APPS)).unwrap_or_default()
}

pub(super) fn default_app_for_instance(instance_id: &str) -> String {
    load_default_apps()
        .get(instance_id)
        .unwrap_or_default()
        .to_owned()
}

fn save_default_apps(apps: &DefaultApps) {
    let encoded = serde_json::to_string(apps).unwrap_or_default();
    Config::set_option(OPTION_DEFAULT_APPS.to_owned(), encoded);
}

pub fn management_inventory() -> ResultType<BlueStacksInventory> {
    let Some(provider) = BlueStacksProvider::detect()? else {
        return Ok(BlueStacksInventory::default());
    };
    let document = provider.read_config()?;
    let instances = provider.instances()?;
    let services = enumerate_services();
    let startup_entries = enumerate_startup_entries();
    let shortcuts = enumerate_shortcuts();
    let components = enumerate_components();
    let default_apps = load_default_apps();
    let last_cleanup_version = Config::get_option(OPTION_CLEANUP_VERSION);
    let selected_cleanup =
        serde_json::from_str::<CleanupSelection>(&Config::get_option(OPTION_CLEANUP_SELECTION))
            .ok();
    let cleanup_journal = load_cleanup_journal();
    let cleanup_support = CleanupSupport {
        disable_gameplay_ads: document.values.contains_key("bst.enable_programmatic_ads"),
        disable_smart_downloads: document.values.contains_key("bst.enable_smart_downloads"),
        disable_store_on_start: document.values.contains_key("bst.launch_store_on_boot"),
        disable_desktop_notifications: document
            .values
            .keys()
            .any(|key| key.starts_with("bst.instance.") && key.ends_with(".enable_notifications")),
        disable_app_shortcuts: document.values.contains_key("bst.create_desktop_shortcuts"),
        disable_optional_startup: startup_entries.iter().any(|entry| entry.safe_to_disable),
        hide_desktop_shortcuts: shortcuts
            .iter()
            .any(|shortcut| shortcut.recommended_cleanup),
    };
    let instance_inventory = instances
        .into_iter()
        .map(|instance| BlueStacksInstanceInventory {
            installed_apps: read_instance_app_cache(&provider.installation, &instance.id),
            default_package: default_apps
                .get(&instance.id)
                .unwrap_or_default()
                .to_owned(),
            id: instance.id,
            display_name: instance.display_name,
            android_flavor: instance.android_flavor.unwrap_or_default(),
            android_version: instance.android_version.unwrap_or_default(),
            running: instance.running,
            adb_enabled: instance.adb_enabled,
            adb_port: instance.adb_port,
            notifications_enabled: instance.notifications_enabled,
            width: instance.width,
            height: instance.height,
            dpi: instance.dpi,
        })
        .collect();
    let installation = BlueStacksInstallationInventory {
        version: provider.installation.version.clone(),
        install_dir: provider
            .installation
            .install_dir
            .to_string_lossy()
            .into_owned(),
        data_dir: provider
            .installation
            .data_dir
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default(),
        user_defined_dir: provider
            .installation
            .user_defined_dir
            .to_string_lossy()
            .into_owned(),
        config_path: provider
            .installation
            .config_path
            .to_string_lossy()
            .into_owned(),
        player_path: provider
            .installation
            .player_path()
            .to_string_lossy()
            .into_owned(),
        adb_path: provider
            .installation
            .adb_path()
            .to_string_lossy()
            .into_owned(),
        multi_instance_manager_path: provider
            .installation
            .multi_instance_manager_path()
            .to_string_lossy()
            .into_owned(),
        multi_instance_manager_available: provider
            .installation
            .multi_instance_manager_path()
            .is_file(),
    };
    Ok(BlueStacksInventory {
        installed: true,
        cleanup_needs_reapply: cleanup_needs_reapply(
            &last_cleanup_version,
            &provider.installation.version,
        ),
        installation,
        hypervisor: document
            .get("bst.status.hypervisor")
            .unwrap_or_default()
            .to_owned(),
        instances: instance_inventory,
        services,
        startup_entries,
        shortcuts,
        components,
        cleanup_support,
        selected_cleanup,
        last_cleanup_version,
        restore_available: !cleanup_journal.is_empty(),
    })
}

pub fn management_inventory_json() -> String {
    let value = match management_inventory() {
        Ok(inventory) => serde_json::json!({"ok": true, "inventory": inventory}),
        Err(error) => serde_json::json!({"ok": false, "error": error.to_string()}),
    };
    serde_json::to_string(&value).unwrap_or_else(|error| {
        format!(r#"{{"ok":false,"error":"failed to serialize BlueStacks inventory: {error}"}}"#)
    })
}

fn execute_action(action: &BlueStacksAction) -> ResultType<serde_json::Value> {
    action.validate_confirmation()?;
    match action {
        BlueStacksAction::RefreshInventory => Ok(serde_json::to_value(management_inventory()?)?),
        BlueStacksAction::ApplyProfile { profile, selection } => {
            let selection = match profile {
                CleanupProfile::Custom => selection.clone().ok_or_else(|| {
                    hbb_common::anyhow::anyhow!(
                        "custom BlueStacks cleanup requires an explicit selection"
                    )
                })?,
                CleanupProfile::Standard | CleanupProfile::CleanGaming => {
                    CleanupSelection::for_profile(*profile)
                }
            };
            let report = apply_cleanup(selection)?;
            Ok(serde_json::json!({
                "report": report,
                "inventory": management_inventory()?,
            }))
        }
        BlueStacksAction::Restore => {
            let report = restore_cleanup()?;
            Ok(serde_json::json!({
                "report": report,
                "inventory": management_inventory()?,
            }))
        }
        BlueStacksAction::SetDefaultApp {
            instance_id,
            package,
        } => {
            set_default_app(instance_id, package)?;
            Ok(serde_json::json!({
                "instance_id": instance_id,
                "package": package,
                "inventory": management_inventory()?,
            }))
        }
        BlueStacksAction::PlayApp {
            instance_id,
            package,
        } => {
            set_default_app(instance_id, package)?;
            let report = launch_default_app(instance_id)?;
            Ok(serde_json::json!({
                "report": report,
                "inventory": management_inventory()?,
            }))
        }
        BlueStacksAction::LaunchDefaultApp { instance_id } => {
            Ok(serde_json::to_value(launch_default_app(instance_id)?)?)
        }
        BlueStacksAction::InspectAndroidPackages { instance_id } => {
            Ok(serde_json::to_value(android_packages(instance_id)?)?)
        }
        BlueStacksAction::DisableOptionalAndroidPackage {
            instance_id,
            package,
            ..
        } => {
            disable_optional_android_package(instance_id, package)?;
            Ok(serde_json::to_value(android_packages(instance_id)?)?)
        }
        BlueStacksAction::RemoveOptionalComponent { component_id, .. } => {
            remove_optional_component(component_id)?;
            Ok(serde_json::json!({
                "component_id": component_id,
                "manual_reinstall_required_for_restore": true,
                "message": "The registered BlueStacks uninstaller was started. Reinstall this optional component manually if you later want it back.",
            }))
        }
    }
}

pub fn handle_action_json(payload: &str) -> String {
    let action = match serde_json::from_str::<BlueStacksAction>(payload) {
        Ok(action) => action,
        Err(error) => {
            return serde_json::to_string(&BlueStacksActionResult::failure(
                "invalid",
                format!("invalid BlueStacks action payload: {error}"),
            ))
            .unwrap_or_default();
        }
    };
    let action_name = action.name();
    let result = match execute_action(&action) {
        Ok(data) => BlueStacksActionResult::success(action_name, data),
        Err(error) => BlueStacksActionResult::failure(action_name, error.to_string()),
    };
    serde_json::to_string(&result).unwrap_or_else(|error| {
        format!(r#"{{"ok":false,"action":"{action_name}","error":"failed to serialize BlueStacks action result: {error}"}}"#)
    })
}

fn write_config_document(path: &Path, document: &BlueStacksConfigDocument) -> ResultType<()> {
    let temp = path.with_extension("conf.rustdesk-tmp");
    let backup = path.with_extension("conf.rustdesk-backup");
    if temp.exists() || backup.exists() {
        bail!(
            "BlueStacks config staging files already exist beside '{}'; refusing to overwrite them",
            path.display()
        );
    }
    fs::write(&temp, document.render())?;
    fs::rename(path, &backup)?;
    if let Err(error) = fs::rename(&temp, path) {
        let _ = fs::rename(&backup, path);
        let _ = fs::remove_file(&temp);
        return Err(error.into());
    }
    fs::remove_file(&backup)?;
    Ok(())
}

fn registry_root(hive: &str) -> Option<RegKey> {
    match hive {
        "HKCU" => Some(RegKey::predef(HKEY_CURRENT_USER)),
        "HKLM" => Some(RegKey::predef(HKEY_LOCAL_MACHINE)),
        _ => None,
    }
}

fn registry_view_flags(view: &str, write: bool) -> u32 {
    let base = if write {
        KEY_READ | KEY_WRITE
    } else {
        KEY_READ
    };
    match view {
        "64" => base | KEY_WOW64_64KEY,
        "32" => base | KEY_WOW64_32KEY,
        _ => base,
    }
}

fn enumerate_startup_entries() -> Vec<BlueStacksStartupEntry> {
    let mut entries = Vec::new();
    let mut seen = BTreeSet::new();
    for (hive_name, root) in [
        ("HKCU", RegKey::predef(HKEY_CURRENT_USER)),
        ("HKLM", RegKey::predef(HKEY_LOCAL_MACHINE)),
    ] {
        for view in ["64", "32", "default"] {
            let Ok(key) =
                root.open_subkey_with_flags(WINDOWS_RUN_KEY, registry_view_flags(view, false))
            else {
                continue;
            };
            for value in key.enum_values().flatten() {
                let value_name = value.0;
                let Ok(command) = key.get_value::<String, _>(&value_name) else {
                    continue;
                };
                let lower = format!("{} {}", value_name, command).to_ascii_lowercase();
                if !lower.contains("bluestacks") && !lower.contains("blueai") {
                    continue;
                }
                let identity_key = format!(
                    "{hive_name}|{WINDOWS_RUN_KEY}|{}|{}",
                    value_name.to_ascii_lowercase(),
                    command.to_ascii_lowercase()
                );
                if !seen.insert(identity_key) {
                    continue;
                }
                let identity = format!("{hive_name}|{view}|{WINDOWS_RUN_KEY}|{value_name}");
                let classified = classify_startup_entry(&value_name, &command);
                entries.push(BlueStacksStartupEntry {
                    id: identity,
                    hive: hive_name.to_owned(),
                    key_path: WINDOWS_RUN_KEY.to_owned(),
                    registry_view: view.to_owned(),
                    value_name,
                    command,
                    classification: classified.classification,
                    safe_to_disable: classified.safe_to_disable,
                });
            }
        }
    }
    entries
}

fn disable_startup_entry(
    entry: &BlueStacksStartupEntry,
    journal: &mut CleanupJournal,
) -> ResultType<bool> {
    if !entry.safe_to_disable {
        bail!(
            "startup entry '{}' is not approved for cleanup",
            entry.value_name
        );
    }
    let Some(root) = registry_root(&entry.hive) else {
        bail!(
            "unsupported startup registry hive '{}': refusing change",
            entry.hive
        );
    };
    let key = root.open_subkey_with_flags(
        &entry.key_path,
        registry_view_flags(&entry.registry_view, true),
    )?;
    let current = match key.get_value::<String, _>(&entry.value_name) {
        Ok(value) => value,
        Err(_) => return Ok(false),
    };
    if current != entry.command {
        bail!(
            "startup entry '{}' changed since inventory; refusing cleanup",
            entry.value_name
        );
    }
    journal.record_startup_change(entry);
    key.delete_value(&entry.value_name)?;
    Ok(true)
}

fn restore_startup_changes(journal: &mut CleanupJournal) -> ResultType<RestorePathReport> {
    let mut report = RestorePathReport::default();
    let mut retained = Vec::new();
    for change in journal.startup_changes.drain(..) {
        let Some(root) = registry_root(&change.hive) else {
            report.skipped_conflicts.push(change.value_name.clone());
            retained.push(change);
            continue;
        };
        let Ok(key) = root.open_subkey_with_flags(
            &change.key_path,
            registry_view_flags(&change.registry_view, true),
        ) else {
            report.skipped_conflicts.push(change.value_name.clone());
            retained.push(change);
            continue;
        };
        match key.get_value::<String, _>(&change.value_name) {
            Ok(current) if current == change.original_command => {
                report.restored.push(change.value_name);
            }
            Ok(_) => {
                report.skipped_conflicts.push(change.value_name.clone());
                retained.push(change);
            }
            Err(_) => {
                key.set_value(&change.value_name, &change.original_command)?;
                report.restored.push(change.value_name);
            }
        }
    }
    journal.startup_changes = retained;
    Ok(report)
}

fn collect_bluestacks_shortcuts(
    root: &Path,
    location: ShortcutLocation,
    output: &mut Vec<BlueStacksShortcut>,
) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_bluestacks_shortcuts(&path, location, output);
            continue;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let lower = name.to_ascii_lowercase();
        if !lower.ends_with(".lnk") || !lower.contains("bluestacks") {
            continue;
        }
        let recommended_cleanup = location == ShortcutLocation::Desktop
            && matches!(
                lower.as_str(),
                "bluestacks 5.lnk" | "bluestacks manager.lnk"
            );
        output.push(BlueStacksShortcut {
            path: path.to_string_lossy().into_owned(),
            name: name.to_owned(),
            location,
            recommended_cleanup,
        });
    }
}

fn enumerate_shortcuts() -> Vec<BlueStacksShortcut> {
    let mut shortcuts = Vec::new();
    if let Some(public) = std::env::var_os("PUBLIC") {
        collect_bluestacks_shortcuts(
            &PathBuf::from(public).join("Desktop"),
            ShortcutLocation::Desktop,
            &mut shortcuts,
        );
    }
    if let Some(profile) = std::env::var_os("USERPROFILE") {
        collect_bluestacks_shortcuts(
            &PathBuf::from(profile).join("Desktop"),
            ShortcutLocation::Desktop,
            &mut shortcuts,
        );
    }
    if let Some(program_data) = std::env::var_os("ProgramData") {
        collect_bluestacks_shortcuts(
            &PathBuf::from(program_data)
                .join("Microsoft")
                .join("Windows")
                .join("Start Menu")
                .join("Programs"),
            ShortcutLocation::StartMenu,
            &mut shortcuts,
        );
    }
    if let Some(app_data) = std::env::var_os("APPDATA") {
        collect_bluestacks_shortcuts(
            &PathBuf::from(app_data)
                .join("Microsoft")
                .join("Windows")
                .join("Start Menu")
                .join("Programs"),
            ShortcutLocation::StartMenu,
            &mut shortcuts,
        );
    }
    shortcuts.sort_by(|left, right| left.path.cmp(&right.path));
    shortcuts.dedup_by(|left, right| left.path.eq_ignore_ascii_case(&right.path));
    shortcuts
}

fn enumerate_components() -> Vec<BlueStacksComponent> {
    let mut components = Vec::new();
    let mut seen = BTreeSet::new();
    for (hive_name, root) in [
        ("HKCU", RegKey::predef(HKEY_CURRENT_USER)),
        ("HKLM", RegKey::predef(HKEY_LOCAL_MACHINE)),
    ] {
        for view in ["64", "32", "default"] {
            let Ok(uninstall) = root
                .open_subkey_with_flags(WINDOWS_UNINSTALL_KEY, registry_view_flags(view, false))
            else {
                continue;
            };
            for subkey_name in uninstall.enum_keys().flatten() {
                let Ok(subkey) = uninstall.open_subkey_with_flags(&subkey_name, KEY_READ) else {
                    continue;
                };
                let Ok(display_name) = subkey.get_value::<String, _>("DisplayName") else {
                    continue;
                };
                let lower = display_name.to_ascii_lowercase();
                if !lower.contains("bluestacks") && !lower.contains("blueai") {
                    continue;
                }
                let classification = classify_component(&display_name);
                let uninstall_command = subkey
                    .get_value::<String, _>("QuietUninstallString")
                    .or_else(|_| subkey.get_value::<String, _>("UninstallString"))
                    .unwrap_or_default();
                let identity_key = format!(
                    "{hive_name}|{}|{}|{}",
                    subkey_name.to_ascii_lowercase(),
                    display_name.to_ascii_lowercase(),
                    uninstall_command.to_ascii_lowercase()
                );
                if !seen.insert(identity_key) {
                    continue;
                }
                let id = format!("{hive_name}|{view}|{subkey_name}");
                let can_remove = matches!(
                    classification,
                    ComponentClassification::Optional
                        | ComponentClassification::PromotionalFrontend
                ) && !uninstall_command.trim().is_empty();
                components.push(BlueStacksComponent {
                    id,
                    display_name,
                    version: subkey
                        .get_value::<String, _>("DisplayVersion")
                        .unwrap_or_default(),
                    install_location: subkey
                        .get_value::<String, _>("InstallLocation")
                        .unwrap_or_default(),
                    classification,
                    can_remove,
                    uninstall_command,
                });
            }
        }
    }
    if !components.iter().any(|component| {
        component
            .display_name
            .trim()
            .eq_ignore_ascii_case("BlueStacks X")
    }) {
        let mut candidates = Vec::new();
        for variable in ["ProgramFiles(x86)", "ProgramFiles"] {
            if let Some(root) = std::env::var_os(variable) {
                candidates.push(PathBuf::from(root).join("BlueStacks X"));
            }
        }
        candidates.extend(
            hbb_common::sysinfo::System::new_all()
                .processes()
                .values()
                .filter(|process| process.name().eq_ignore_ascii_case("BlueStacks X.exe"))
                .filter_map(|process| process.exe().parent().map(Path::to_path_buf)),
        );
        let mut seen_paths = BTreeSet::new();
        for candidate in candidates {
            let identity = candidate.to_string_lossy().to_ascii_lowercase();
            if !seen_paths.insert(identity) {
                continue;
            }
            if let Some(component) = bluestacks_x_component_from_dir(&candidate) {
                components.push(component);
                break;
            }
        }
    }
    components.sort_by(|left, right| left.display_name.cmp(&right.display_name));
    components
}

fn bluestacks_x_component_from_dir(install_dir: &Path) -> Option<BlueStacksComponent> {
    let executable = install_dir.join("BlueStacks X.exe");
    let uninstaller = install_dir.join("BlueStacksXUninstaller.exe");
    if !executable.is_file() || !uninstaller.is_file() {
        return None;
    }
    Some(BlueStacksComponent {
        id: format!("filesystem|{}", install_dir.to_string_lossy()),
        display_name: "BlueStacks X".to_owned(),
        version: String::new(),
        install_location: install_dir.to_string_lossy().into_owned(),
        classification: ComponentClassification::PromotionalFrontend,
        can_remove: true,
        uninstall_command: format!("\"{}\"", uninstaller.display()),
    })
}

fn parse_registered_uninstall_command(command: &str) -> ResultType<(PathBuf, Vec<String>)> {
    let command = command.trim();
    if command.is_empty() {
        bail!("registered uninstaller command is empty")
    }
    if command
        .chars()
        .any(|ch| matches!(ch, '&' | '|' | '<' | '>' | '^' | '\n' | '\r'))
    {
        bail!("registered uninstaller contains shell metacharacters")
    }

    let (program, remainder) = if let Some(rest) = command.strip_prefix('"') {
        let Some(end) = rest.find('"') else {
            bail!("registered uninstaller has an unterminated quoted executable path")
        };
        (rest[..end].to_owned(), rest[end + 1..].trim())
    } else {
        let lower = command.to_ascii_lowercase();
        let Some(end) = lower.find(".exe") else {
            bail!("registered uninstaller does not name an executable")
        };
        (
            command[..end + 4].trim().to_owned(),
            command[end + 4..].trim(),
        )
    };
    let program_path = PathBuf::from(&program);
    let file_name = program_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if matches!(
        file_name.as_str(),
        "cmd.exe" | "powershell.exe" | "pwsh.exe" | "wscript.exe" | "cscript.exe"
    ) {
        bail!("script/shell uninstallers are not accepted")
    }
    if !program_path.is_absolute() && file_name != "msiexec.exe" {
        bail!("registered uninstaller executable path is not absolute")
    }

    let mut args = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    for ch in remainder.chars() {
        match ch {
            '"' => quoted = !quoted,
            ch if ch.is_whitespace() && !quoted => {
                if !current.is_empty() {
                    args.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(ch),
        }
    }
    if quoted {
        bail!("registered uninstaller has unterminated argument quoting")
    }
    if !current.is_empty() {
        args.push(current);
    }
    Ok((program_path, args))
}

fn validate_component_removal(component: &BlueStacksComponent) -> ResultType<()> {
    if !component.can_remove {
        bail!(
            "component '{}' is not marked removable",
            component.display_name
        )
    }
    if !matches!(
        component.classification,
        ComponentClassification::Optional | ComponentClassification::PromotionalFrontend
    ) {
        bail!(
            "component '{}' is required, feature-specific, or unknown and cannot be removed",
            component.display_name
        )
    }
    if component.uninstall_command.trim().is_empty() {
        bail!(
            "component '{}' has no registered uninstaller",
            component.display_name
        )
    }
    Ok(())
}

fn enumerate_services() -> Vec<BlueStacksService> {
    let root = RegKey::predef(HKEY_LOCAL_MACHINE);
    let Ok(services) = root.open_subkey_with_flags(WINDOWS_SERVICES_KEY, KEY_READ) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for name in services.enum_keys().flatten() {
        let Ok(service) = services.open_subkey_with_flags(&name, KEY_READ) else {
            continue;
        };
        let display_name = service
            .get_value::<String, _>("DisplayName")
            .unwrap_or_else(|_| name.clone());
        let image_path = service
            .get_value::<String, _>("ImagePath")
            .unwrap_or_default();
        let lower = format!("{} {} {}", name, display_name, image_path).to_ascii_lowercase();
        if !lower.contains("bluestacks") && !lower.contains("bstksvc") {
            continue;
        }
        let classification = classify_service(&name, &display_name, &image_path);
        result.push(BlueStacksService {
            name,
            display_name,
            image_path,
            classification,
        });
    }
    result
}

#[derive(Debug)]
struct TimedCommandOutput {
    success: bool,
    timed_out: bool,
    stdout: String,
    stderr: String,
}

fn run_command_with_timeout(program: &Path, args: &[String]) -> ResultType<TimedCommandOutput> {
    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started = Instant::now();
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
            return Ok(TimedCommandOutput {
                success: status.success(),
                timed_out: false,
                stdout: String::from_utf8_lossy(&stdout).into_owned(),
                stderr: String::from_utf8_lossy(&stderr).into_owned(),
            });
        }
        if started.elapsed() >= COMMAND_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(TimedCommandOutput {
                success: false,
                timed_out: true,
                stdout: String::new(),
                stderr: String::new(),
            });
        }
        thread::sleep(COMMAND_POLL_INTERVAL);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AdbConnectionMode {
    ProbeOnly,
    EnsureConnected,
}

impl AdbConnectionMode {
    fn should_connect(self) -> bool {
        matches!(self, Self::EnsureConnected)
    }
}

fn run_adb(
    provider: &BlueStacksProvider,
    instance: &BlueStacksInstanceInfo,
    args: &[&str],
) -> ResultType<String> {
    run_adb_with_mode(provider, instance, args, AdbConnectionMode::EnsureConnected)
}

fn run_adb_with_mode(
    provider: &BlueStacksProvider,
    instance: &BlueStacksInstanceInfo,
    args: &[&str],
    connection_mode: AdbConnectionMode,
) -> ResultType<String> {
    if !instance.adb_enabled {
        bail!("BlueStacks ADB access is disabled")
    }
    let port = instance
        .adb_port
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks ADB port is unavailable"))?;
    let serial = format!("127.0.0.1:{port}");
    let adb_path = hbb_common::sysinfo::System::new_all()
        .processes()
        .values()
        .find_map(|process| {
            if !process.name().eq_ignore_ascii_case("adb.exe")
                || !super::guest_runtime::is_default_adb_server(process.cmd())
                || !process.exe().is_file()
            {
                return None;
            }
            Some(process.exe().to_path_buf())
        })
        .unwrap_or_else(|| provider.installation.adb_path());
    if connection_mode.should_connect() {
        let connect_args = vec!["connect".to_owned(), serial.clone()];
        let connect = run_command_with_timeout(&adb_path, &connect_args)?;
        if connect.timed_out {
            bail!("BlueStacks ADB connect timed out for {serial}")
        }
        if !connect.success {
            let error = connect.stderr.trim().to_owned();
            bail!(
                "BlueStacks ADB connect failed for {serial}: {}",
                if error.is_empty() {
                    "non-zero exit status"
                } else {
                    &error
                }
            );
        }
    }
    let mut command_args = vec!["-s".to_owned(), serial.clone()];
    command_args.extend(args.iter().map(|arg| (*arg).to_owned()));
    let output = run_command_with_timeout(&adb_path, &command_args)?;
    if output.timed_out {
        bail!("BlueStacks ADB command timed out for {serial}")
    }
    if !output.success {
        let error = output.stderr.trim().to_owned();
        bail!(
            "BlueStacks ADB command failed for {serial}: {}",
            if error.is_empty() {
                "non-zero exit status"
            } else {
                &error
            }
        );
    }
    Ok(output.stdout)
}

pub fn watchdog_adb_health() -> ResultType<(usize, usize)> {
    adb_health(AdbConnectionMode::ProbeOnly)
}

fn adb_health(connection_mode: AdbConnectionMode) -> ResultType<(usize, usize)> {
    let Some(provider) = BlueStacksProvider::detect()? else {
        return Ok((0, 0));
    };
    let mut expected = 0usize;
    let mut healthy = 0usize;
    for instance in provider
        .instances()?
        .iter()
        .filter(|instance| instance.running && instance.adb_enabled && instance.adb_port.is_some())
    {
        expected += 1;
        if run_adb_with_mode(&provider, instance, &["get-state"], connection_mode)
            .map(|state| state.trim().eq_ignore_ascii_case("device"))
            .unwrap_or(false)
        {
            healthy += 1;
        }
    }
    Ok((expected, healthy))
}

pub fn recover_adb_connections() -> ResultType<usize> {
    let (expected, healthy) = adb_health(AdbConnectionMode::EnsureConnected)?;
    if expected > 0 && healthy == 0 {
        bail!("No running BlueStacks ADB instance could be reached")
    }
    Ok(healthy)
}

fn find_instance(
    provider: &BlueStacksProvider,
    instance_id: &str,
) -> ResultType<BlueStacksInstanceInfo> {
    provider
        .instances()?
        .into_iter()
        .find(|instance| instance.id == instance_id)
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!("BlueStacks instance '{instance_id}' does not exist")
        })
}

fn android_package_inventory_unavailable_reason(
    instance: &BlueStacksInstanceInfo,
) -> Option<&'static str> {
    if !instance.adb_enabled || instance.adb_port.is_none() {
        return Some("ADB is disabled in BlueStacks; Android packages were not inspected");
    }
    if !instance.running {
        return Some("BlueStacks instance is stopped; start it before inspecting Android packages");
    }
    None
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AndroidRestorePreparation {
    Ready,
    StartAndWait,
}

fn android_restore_preparation(
    instance: &BlueStacksInstanceInfo,
) -> ResultType<AndroidRestorePreparation> {
    if !instance.adb_enabled {
        bail!("ADB is disabled")
    }
    if instance.adb_port.is_none() {
        bail!("ADB port is unavailable")
    }
    Ok(if instance.running {
        AndroidRestorePreparation::Ready
    } else {
        AndroidRestorePreparation::StartAndWait
    })
}

pub fn android_packages(instance_id: &str) -> ResultType<AndroidPackageInventory> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let instance = find_instance(&provider, instance_id)?;
    if let Some(message) = android_package_inventory_unavailable_reason(&instance) {
        return Ok(AndroidPackageInventory {
            instance_id: instance_id.to_owned(),
            available: false,
            message: message.to_owned(),
            packages: Vec::new(),
        });
    }
    let system = parse_package_list(&run_adb(
        &provider,
        &instance,
        &["shell", "pm", "list", "packages", "-s"],
    )?);
    let user = parse_package_list(&run_adb(
        &provider,
        &instance,
        &["shell", "pm", "list", "packages", "-3"],
    )?);
    let disabled = parse_package_list(&run_adb(
        &provider,
        &instance,
        &["shell", "pm", "list", "packages", "-d"],
    )?);
    let mut all = system.clone();
    all.extend(user.iter().cloned());
    let packages = all
        .into_iter()
        .map(|package| AndroidPackageInfo {
            classification: classify_android_package(&package, user.contains(&package)),
            user_installed: user.contains(&package),
            disabled: disabled.contains(&package),
            package,
        })
        .collect();
    Ok(AndroidPackageInventory {
        instance_id: instance_id.to_owned(),
        available: true,
        message: String::new(),
        packages,
    })
}

pub fn disable_optional_android_package(instance_id: &str, package: &str) -> ResultType<()> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let instance = find_instance(&provider, instance_id)?;
    let inventory = android_packages(instance_id)?;
    let info = inventory
        .packages
        .iter()
        .find(|info| info.package == package)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Android package '{package}' was not found"))?;
    validate_android_disable(package, info.user_installed)?;
    if info.disabled {
        return Ok(());
    }
    let _ = run_adb(
        &provider,
        &instance,
        &["shell", "pm", "disable-user", "--user", "0", package],
    )?;
    let mut journal = load_cleanup_journal();
    let packages = journal
        .disabled_android_packages
        .entry(instance_id.to_owned())
        .or_default();
    if !packages.iter().any(|item| item == package) {
        packages.push(package.to_owned());
    }
    save_cleanup_journal(&journal);
    log::info!("BlueStacks cleanup disabled Android package {package} on {instance_id}");
    Ok(())
}

pub fn set_default_app(instance_id: &str, package: &str) -> ResultType<()> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let _ = find_instance(&provider, instance_id)?;
    let mut apps = load_default_apps();
    apps.set(instance_id, package)?;
    save_default_apps(&apps);
    Ok(())
}

pub fn remove_optional_component(component_id: &str) -> ResultType<()> {
    let component = enumerate_components()
        .into_iter()
        .find(|component| component.id == component_id)
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!("BlueStacks component '{component_id}' was not found")
        })?;
    validate_component_removal(&component)?;
    let (mut program, args) = parse_registered_uninstall_command(&component.uninstall_command)?;
    if program
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.eq_ignore_ascii_case("msiexec.exe"))
        .unwrap_or(false)
        && !program.is_absolute()
    {
        let system_root = std::env::var_os("SystemRoot")
            .ok_or_else(|| hbb_common::anyhow::anyhow!("SystemRoot is unavailable"))?;
        program = PathBuf::from(system_root)
            .join("System32")
            .join("msiexec.exe");
    }
    if !program.is_file() {
        bail!(
            "registered uninstaller '{}' does not exist; refusing removal",
            program.display()
        )
    }
    Command::new(&program).args(&args).spawn()?;
    let mut journal = load_cleanup_journal();
    if !journal
        .removed_components
        .iter()
        .any(|record| record.id == component.id)
    {
        journal.removed_components.push(RemovedComponentRecord {
            id: component.id.clone(),
            display_name: component.display_name.clone(),
            version: component.version.clone(),
            install_location: component.install_location.clone(),
        });
        save_cleanup_journal(&journal);
    }
    log::info!(
        "BlueStacks cleanup started registered uninstaller for optional component {}",
        component.display_name
    );
    Ok(())
}

fn wait_for_android_ready(
    provider: &BlueStacksProvider,
    instance_id: &str,
    timeout: Duration,
) -> ResultType<BlueStacksInstanceInfo> {
    let deadline = Instant::now() + timeout;
    loop {
        let instance = find_instance(provider, instance_id)?;
        if can_probe_android_ready(&instance) {
            if run_adb(provider, &instance, &["get-state"])
                .map(|output| output.trim().eq_ignore_ascii_case("device"))
                .unwrap_or(false)
                && run_adb(
                    provider,
                    &instance,
                    &["shell", "getprop", "sys.boot_completed"],
                )
                .map(|output| output.trim() == "1")
                .unwrap_or(false)
            {
                return Ok(instance);
            }
        }
        if Instant::now() >= deadline {
            bail!("BlueStacks instance '{instance_id}' did not become Android-ready before timeout")
        }
        thread::sleep(DEFAULT_LAUNCH_POLL_INTERVAL);
    }
}

fn can_probe_android_ready(instance: &BlueStacksInstanceInfo) -> bool {
    instance.adb_enabled && instance.adb_port.is_some()
}

pub fn launch_default_app(instance_id: &str) -> ResultType<LaunchReport> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let apps = load_default_apps();
    let package = apps
        .get(instance_id)
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!(
                "no default app is configured for BlueStacks instance '{instance_id}'"
            )
        })?
        .to_owned();
    let target = provider
        .discover()?
        .into_iter()
        .find(|target| target.provider_instance_id == instance_id)
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!("BlueStacks instance '{instance_id}' does not exist")
        })?;
    let started_instance = target.state == EmulatorState::Stopped;
    let instance = find_instance(&provider, instance_id)?;

    if !instance.adb_enabled || instance.adb_port.is_none() {
        provider.launch_package(&target, &package)?;
        return Ok(LaunchReport {
            instance_id: instance_id.to_owned(),
            package,
            started_instance,
            adb_verified: false,
            message: "Launch requested through BlueStacks; ADB is disabled so Android boot/package verification was skipped".to_owned(),
        });
    }

    if started_instance {
        provider.start(&target)?;
    }
    let ready = wait_for_android_ready(&provider, instance_id, DEFAULT_LAUNCH_TIMEOUT)?;
    let package_path = run_adb(&provider, &ready, &["shell", "pm", "path", &package])?;
    if !package_path
        .lines()
        .any(|line| line.trim().starts_with("package:"))
    {
        bail!(
            "default Android package '{package}' is not installed on BlueStacks instance '{instance_id}'"
        )
    }
    let refreshed_target = provider
        .discover()?
        .into_iter()
        .find(|target| target.provider_instance_id == instance_id)
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!(
                "BlueStacks instance '{instance_id}' disappeared before app launch"
            )
        })?;
    provider.launch_package(&refreshed_target, &package)?;
    Ok(LaunchReport {
        instance_id: instance_id.to_owned(),
        package,
        started_instance,
        adb_verified: true,
        message: "Android boot and package availability verified; app launch requested through BlueStacks".to_owned(),
    })
}

pub fn apply_cleanup(selection: CleanupSelection) -> ResultType<CleanupApplyReport> {
    if selection.remove_optional_components || selection.disable_optional_android_apps {
        bail!("destructive component/package actions cannot be applied through a cleanup profile")
    }
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let instances = provider.instances()?;
    if instances.iter().any(|instance| instance.running) {
        bail!("stop all BlueStacks instances before applying cleanup settings")
    }

    let mut report = CleanupApplyReport {
        version: provider.installation.version.clone(),
        ..Default::default()
    };
    let mut journal = load_cleanup_journal();
    let mut document = provider.read_config()?;
    report.changed_config_keys = apply_config_cleanup(&mut document, &selection, &mut journal);
    if !report.changed_config_keys.is_empty() {
        // Persist the restore record before touching BlueStacks' config. If the
        // atomic swap fails at any point, restore can safely resolve entries
        // that are still at their original values instead of losing history.
        save_cleanup_journal(&journal);
        write_config_document(&provider.installation.config_path, &document)?;
        for key in &report.changed_config_keys {
            log::info!("BlueStacks cleanup changed config key {key}");
        }
    }

    if selection.disable_optional_startup {
        for entry in enumerate_startup_entries()
            .into_iter()
            .filter(|entry| entry.safe_to_disable)
        {
            if disable_startup_entry(&entry, &mut journal)? {
                report
                    .disabled_startup_entries
                    .push(entry.value_name.clone());
                save_cleanup_journal(&journal);
                log::info!(
                    "BlueStacks cleanup disabled startup entry {}",
                    entry.value_name
                );
            }
        }
    }

    if selection.hide_desktop_shortcuts {
        apply_recommended_shortcut_cleanup(enumerate_shortcuts(), &mut journal, &mut report)?;
    }

    Config::set_option(
        OPTION_CLEANUP_SELECTION.to_owned(),
        serde_json::to_string(&selection).unwrap_or_default(),
    );
    Config::set_option(
        OPTION_CLEANUP_VERSION.to_owned(),
        provider.installation.version.clone(),
    );
    Ok(report)
}

fn validate_restore_runtime_state(
    journal: &CleanupJournal,
    instances: &[BlueStacksInstanceInfo],
) -> ResultType<()> {
    if !journal.config_changes.is_empty() && instances.iter().any(|instance| instance.running) {
        bail!("stop all BlueStacks instances before restoring BlueStacks configuration")
    }
    Ok(())
}

pub fn restore_cleanup() -> ResultType<CleanupRestoreReport> {
    let provider = BlueStacksProvider::detect()?
        .ok_or_else(|| hbb_common::anyhow::anyhow!("BlueStacks 5 is not installed"))?;
    let mut journal = load_cleanup_journal();
    validate_restore_runtime_state(&journal, &provider.instances()?)?;
    let mut report = CleanupRestoreReport::default();

    if !journal.config_changes.is_empty() {
        let mut document = provider.read_config()?;
        let config_report = restore_config_changes(&mut document, &journal);
        if !config_report.restored.is_empty() {
            write_config_document(&provider.installation.config_path, &document)?;
            report.restored_config_keys = config_report.restored.clone();
            let restored: BTreeSet<_> = config_report.restored.into_iter().collect();
            journal
                .config_changes
                .retain(|change| !restored.contains(&change.key));
        }
        report
            .skipped_conflicts
            .extend(config_report.skipped_conflicts);
        save_cleanup_journal(&journal);
    }

    let startup_report = restore_startup_changes(&mut journal)?;
    report.restored_startup_entries = startup_report.restored;
    report
        .skipped_conflicts
        .extend(startup_report.skipped_conflicts);
    save_cleanup_journal(&journal);

    let shortcut_report = restore_shortcut_changes(&mut journal)?;
    report.restored_shortcuts = shortcut_report.restored;
    report
        .skipped_conflicts
        .extend(shortcut_report.skipped_conflicts);
    save_cleanup_journal(&journal);

    let disabled_snapshot = journal.disabled_android_packages.clone();
    for (instance_id, packages) in disabled_snapshot {
        let Ok(mut instance) = find_instance(&provider, &instance_id) else {
            report
                .skipped_conflicts
                .push(format!("{instance_id}: Android instance missing"));
            continue;
        };
        let preparation = match android_restore_preparation(&instance) {
            Ok(preparation) => preparation,
            Err(error) => {
                report
                    .skipped_conflicts
                    .push(format!("{instance_id}: {error}"));
                continue;
            }
        };
        if preparation == AndroidRestorePreparation::StartAndWait {
            let target = instance_to_target(&instance);
            if let Err(error) = provider.start(&target) {
                report.skipped_conflicts.push(format!(
                    "{instance_id}: failed to start for Android restore: {error}"
                ));
                continue;
            }
            match wait_for_android_ready(&provider, &instance_id, DEFAULT_LAUNCH_TIMEOUT) {
                Ok(ready) => instance = ready,
                Err(error) => {
                    report.skipped_conflicts.push(format!(
                        "{instance_id}: Android did not become ready for restore: {error}"
                    ));
                    continue;
                }
            }
        }
        for package in packages {
            let inventory = android_packages(&instance_id)?;
            let Some(info) = inventory
                .packages
                .iter()
                .find(|info| info.package == package)
            else {
                report
                    .skipped_conflicts
                    .push(format!("{instance_id}:{package}"));
                continue;
            };
            if info.disabled {
                let _ = run_adb(&provider, &instance, &["shell", "pm", "enable", &package])?;
            }
            report
                .restored_android_packages
                .push(format!("{instance_id}:{package}"));
            if let Some(recorded) = journal.disabled_android_packages.get_mut(&instance_id) {
                recorded.retain(|item| item != &package);
            }
            save_cleanup_journal(&journal);
        }
    }
    journal
        .disabled_android_packages
        .retain(|_, packages| !packages.is_empty());
    save_cleanup_journal(&journal);

    report.manual_reinstall_components = journal
        .removed_components
        .iter()
        .map(|record| record.display_name.clone())
        .collect();

    if journal.is_empty() {
        Config::set_option(OPTION_CLEANUP_JOURNAL.to_owned(), String::new());
        Config::set_option(OPTION_CLEANUP_VERSION.to_owned(), String::new());
        Config::set_option(OPTION_CLEANUP_SELECTION.to_owned(), String::new());
    }
    Ok(report)
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
        "Android13" | "Tiramisu64" => (Some("Android 13"), Some("13")),
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

fn running_player_commands(system: &hbb_common::sysinfo::System) -> Vec<Vec<String>> {
    system
        .processes()
        .values()
        .filter(|process| process.name().eq_ignore_ascii_case("HD-Player.exe"))
        .map(|process| process.cmd().to_vec())
        .collect()
}

fn running_player_ports(system: &hbb_common::sysinfo::System) -> ResultType<BTreeSet<u16>> {
    use winapi::{
        shared::{
            iprtrmib::TCP_TABLE_OWNER_PID_LISTENER, tcpmib::MIB_TCPROW_OWNER_PID,
            winerror::ERROR_INSUFFICIENT_BUFFER, ws2def::AF_INET,
        },
        um::iphlpapi::GetExtendedTcpTable,
    };

    let players: BTreeSet<_> = system
        .processes()
        .values()
        .filter(|process| process.name().eq_ignore_ascii_case("HD-Player.exe"))
        .map(|process| process.pid().as_u32())
        .collect();
    if players.is_empty() {
        return Ok(BTreeSet::new());
    }
    // Elevated players may hide their command lines. The Windows TCP owner
    // table still identifies which player owns each configured ADB listener.
    let mut bytes = 0;
    let result = unsafe {
        GetExtendedTcpTable(
            std::ptr::null_mut(),
            &mut bytes,
            0,
            AF_INET as u32,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    if result != ERROR_INSUFFICIENT_BUFFER {
        bail!("Could not size the TCP owner table: {result}")
    }
    let mut buffer = vec![0u32; (bytes as usize + 3) / 4];
    let result = unsafe {
        GetExtendedTcpTable(
            buffer.as_mut_ptr() as _,
            &mut bytes,
            0,
            AF_INET as u32,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    if result != 0 {
        bail!("Could not read the TCP owner table: {result}")
    }
    let count = buffer.first().copied().unwrap_or_default() as usize;
    if bytes < 4
        || bytes as usize > buffer.len() * 4
        || count > (bytes as usize - 4) / std::mem::size_of::<MIB_TCPROW_OWNER_PID>()
    {
        bail!("Invalid TCP owner table size")
    }
    // The table header and rows contain only DWORD fields, aligned like buffer.
    let rows = unsafe {
        std::slice::from_raw_parts(buffer.as_ptr().add(1) as *const MIB_TCPROW_OWNER_PID, count)
    };
    Ok(rows
        .iter()
        .filter(|row| {
            players.contains(&row.dwOwningPid)
                && (row.dwLocalAddr == 0 || row.dwLocalAddr == u32::from_ne_bytes([127, 0, 0, 1]))
        })
        .map(|row| u16::from_be(row.dwLocalPort as u16))
        .collect())
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
        let system = hbb_common::sysinfo::System::new_all();
        let mut instances = instances_from_config(&config, &running_player_commands(&system));
        match running_player_ports(&system) {
            Ok(ports) => {
                for instance in &mut instances {
                    instance.running |= instance
                        .adb_port
                        .map(|port| ports.contains(&port))
                        .unwrap_or(false);
                }
            }
            Err(error) => hbb_common::throttled_log!(
                Duration::from_secs(5),
                warn,
                "BlueStacks listener discovery failed: {error}"
            ),
        }
        Ok(instances)
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
        Command::new(self.installation.player_path())
            .args(args)
            .spawn()?;
        Ok(())
    }
}

impl EmulatorProvider for BlueStacksProvider {
    fn provider_id(&self) -> ProviderId {
        ProviderId::new(PROVIDER_ID)
    }

    fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
        Ok(self.instances()?.iter().map(instance_to_target).collect())
    }

    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
        let instance_id = self.target_instance_id(target)?;
        let instance = self
            .instances()?
            .into_iter()
            .find(|instance| instance.id == instance_id)
            .ok_or_else(|| {
                hbb_common::anyhow::anyhow!("BlueStacks instance '{instance_id}' no longer exists")
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
                hbb_common::anyhow::anyhow!("BlueStacks instance '{instance_id}' no longer exists")
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
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn watchdog_probe_does_not_request_adb_reconnect() {
        assert!(!AdbConnectionMode::ProbeOnly.should_connect());
        assert!(AdbConnectionMode::EnsureConnected.should_connect());
    }

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
        assert_eq!(android_metadata("Pie64"), (Some("Pie 64-bit"), Some("9")));
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
        assert_eq!(
            target.display.as_ref().map(|display| display.width),
            Some(1920)
        );
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
    fn android_package_inventory_requires_a_running_adb_instance() {
        let raw =
            CURRENT_CONF.replace("bst.enable_adb_access=\"0\"", "bst.enable_adb_access=\"1\"");
        let document = BlueStacksConfigDocument::parse(&raw).unwrap();
        let stopped = instances_from_config(&document, &[]).remove(0);
        assert_eq!(
            android_package_inventory_unavailable_reason(&stopped),
            Some("BlueStacks instance is stopped; start it before inspecting Android packages")
        );

        let running_commands = vec![vec![
            "HD-Player.exe".to_owned(),
            "--instance".to_owned(),
            "Nougat32".to_owned(),
        ]];
        let running = instances_from_config(&document, &running_commands).remove(0);
        assert_eq!(android_package_inventory_unavailable_reason(&running), None);
    }

    #[test]
    fn android_ready_probe_does_not_depend_on_process_running_detection() {
        let raw =
            CURRENT_CONF.replace("bst.enable_adb_access=\"0\"", "bst.enable_adb_access=\"1\"");
        let document = BlueStacksConfigDocument::parse(&raw).unwrap();
        let stopped = instances_from_config(&document, &[]).remove(0);

        assert!(!stopped.running);
        assert!(can_probe_android_ready(&stopped));
    }

    #[test]
    fn standard_and_clean_gaming_profiles_select_only_reversible_cleanup() {
        let standard = CleanupSelection::for_profile(CleanupProfile::Standard);
        assert!(standard.disable_gameplay_ads);
        assert!(standard.disable_smart_downloads);
        assert!(standard.disable_store_on_start);
        assert!(!standard.disable_desktop_notifications);
        assert!(!standard.disable_optional_startup);
        assert!(!standard.hide_desktop_shortcuts);

        let clean = CleanupSelection::for_profile(CleanupProfile::CleanGaming);
        assert!(clean.disable_gameplay_ads);
        assert!(clean.disable_smart_downloads);
        assert!(clean.disable_store_on_start);
        assert!(clean.disable_desktop_notifications);
        assert!(clean.disable_app_shortcuts);
        assert!(clean.disable_optional_startup);
        assert!(clean.hide_desktop_shortcuts);
        assert!(!clean.remove_optional_components);
        assert!(!clean.disable_optional_android_apps);
    }

    #[test]
    fn config_editor_changes_only_keys_present_in_current_release() {
        let mut document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();

        assert!(document.set_existing("bst.enable_programmatic_ads", "0"));
        assert!(!document.set_existing("bst.feature.future_setting", "0"));
        assert_eq!(document.get("bst.enable_programmatic_ads"), Some("0"));
        assert!(!document.render().contains("bst.feature.future_setting"));
        assert!(document
            .render()
            .contains("bst.enable_programmatic_ads=\"0\""));
    }

    #[test]
    fn cleanup_journal_preserves_first_original_value_across_reapply() {
        let mut journal = CleanupJournal::default();
        journal.record_config_change("bst.enable_programmatic_ads", "1", "0");
        journal.record_config_change("bst.enable_programmatic_ads", "9", "0");

        assert_eq!(journal.config_changes.len(), 1);
        assert_eq!(journal.config_changes[0].original_value, "1");
        assert_eq!(journal.config_changes[0].applied_value, "0");
    }

    #[test]
    fn startup_journal_keeps_same_run_value_from_distinct_registry_views() {
        let mut journal = CleanupJournal::default();
        let entry = |registry_view: &str| BlueStacksStartupEntry {
            id: format!("HKLM|{registry_view}|{WINDOWS_RUN_KEY}|BlueStacks X"),
            hive: "HKLM".to_owned(),
            key_path: WINDOWS_RUN_KEY.to_owned(),
            registry_view: registry_view.to_owned(),
            value_name: "BlueStacks X".to_owned(),
            command: r#""C:\Program Files (x86)\BlueStacks X\BlueStacks X.exe" --hidden"#
                .to_owned(),
            classification: ComponentClassification::PromotionalFrontend,
            safe_to_disable: true,
        };

        journal.record_startup_change(&entry("32"));
        journal.record_startup_change(&entry("64"));
        journal.record_startup_change(&entry("64"));

        assert_eq!(journal.startup_changes.len(), 2);
        assert!(journal
            .startup_changes
            .iter()
            .any(|change| change.registry_view == "32"));
        assert!(journal
            .startup_changes
            .iter()
            .any(|change| change.registry_view == "64"));
    }

    #[test]
    fn parses_bluestacks_bridge_actions_from_tagged_json() {
        let apply: BlueStacksAction =
            serde_json::from_str(r#"{"action":"apply_profile","profile":"clean_gaming"}"#).unwrap();
        assert!(matches!(
            apply,
            BlueStacksAction::ApplyProfile {
                profile: CleanupProfile::CleanGaming,
                selection: None
            }
        ));

        let inspect: BlueStacksAction = serde_json::from_str(
            r#"{"action":"inspect_android_packages","instance_id":"Nougat32"}"#,
        )
        .unwrap();
        assert!(matches!(
            inspect,
            BlueStacksAction::InspectAndroidPackages { ref instance_id }
                if instance_id == "Nougat32"
        ));

        assert!(
            serde_json::from_str::<BlueStacksAction>(r#"{"action":"delete_everything"}"#).is_err()
        );
    }

    #[test]
    fn serializes_bluestacks_bridge_action_result_as_structured_json() {
        let result = BlueStacksActionResult::success(
            "set_default_app",
            serde_json::json!({"instance_id":"Nougat32","package":"com.example.game"}),
        );
        let value = serde_json::to_value(result).unwrap();

        assert_eq!(value["ok"], true);
        assert_eq!(value["action"], "set_default_app");
        assert_eq!(value["data"]["instance_id"], "Nougat32");
        assert!(value.get("error").is_none());
    }

    #[test]
    fn destructive_bridge_actions_require_explicit_confirmation() {
        let unconfirmed: BlueStacksAction = serde_json::from_str(
            r#"{"action":"remove_optional_component","component_id":"filesystem|C:\\BlueStacks X","confirmed":false}"#,
        )
        .unwrap();
        assert!(unconfirmed.validate_confirmation().is_err());

        let confirmed: BlueStacksAction = serde_json::from_str(
            r#"{"action":"remove_optional_component","component_id":"filesystem|C:\\BlueStacks X","confirmed":true}"#,
        )
        .unwrap();
        assert!(confirmed.validate_confirmation().is_ok());
    }

    #[test]
    fn restore_skips_config_value_changed_manually_after_cleanup() {
        let raw = "bst.enable_programmatic_ads=\"2\"\nbst.enable_smart_downloads=\"0\"\n";
        let mut document = BlueStacksConfigDocument::parse(raw).unwrap();
        let journal = CleanupJournal {
            config_changes: vec![
                ConfigChange::new("bst.enable_programmatic_ads", "1", "0"),
                ConfigChange::new("bst.enable_smart_downloads", "1", "0"),
            ],
            ..Default::default()
        };

        let report = restore_config_changes(&mut document, &journal);

        assert_eq!(report.restored, vec!["bst.enable_smart_downloads"]);
        assert_eq!(
            report.skipped_conflicts,
            vec!["bst.enable_programmatic_ads"]
        );
        assert_eq!(document.get("bst.enable_programmatic_ads"), Some("2"));
        assert_eq!(document.get("bst.enable_smart_downloads"), Some("1"));
    }

    #[test]
    fn restore_treats_config_already_back_at_original_as_resolved() {
        let mut document =
            BlueStacksConfigDocument::parse("bst.enable_programmatic_ads=\"1\"\n").unwrap();
        let journal = CleanupJournal {
            config_changes: vec![ConfigChange::new("bst.enable_programmatic_ads", "1", "0")],
            ..Default::default()
        };

        let report = restore_config_changes(&mut document, &journal);

        assert_eq!(report.restored, vec!["bst.enable_programmatic_ads"]);
        assert!(report.skipped_conflicts.is_empty());
        assert_eq!(document.get("bst.enable_programmatic_ads"), Some("1"));
    }

    #[test]
    fn android_restore_preparation_starts_only_stopped_adb_instances() {
        let raw =
            CURRENT_CONF.replace("bst.enable_adb_access=\"0\"", "bst.enable_adb_access=\"1\"");
        let document = BlueStacksConfigDocument::parse(&raw).unwrap();
        let stopped = instances_from_config(&document, &[]).remove(0);
        assert_eq!(
            android_restore_preparation(&stopped).unwrap(),
            AndroidRestorePreparation::StartAndWait
        );

        let running_commands = vec![vec![
            "HD-Player.exe".to_owned(),
            "--instance".to_owned(),
            "Nougat32".to_owned(),
        ]];
        let running = instances_from_config(&document, &running_commands).remove(0);
        assert_eq!(
            android_restore_preparation(&running).unwrap(),
            AndroidRestorePreparation::Ready
        );

        let adb_disabled =
            instances_from_config(&BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap(), &[])
                .remove(0);
        assert!(android_restore_preparation(&adb_disabled).is_err());
    }

    #[test]
    fn config_restore_refuses_to_run_while_an_instance_is_running() {
        let document = BlueStacksConfigDocument::parse(CURRENT_CONF).unwrap();
        let running_commands = vec![vec![
            "HD-Player.exe".to_owned(),
            "--instance".to_owned(),
            "Nougat32".to_owned(),
        ]];
        let running = instances_from_config(&document, &running_commands);
        let journal = CleanupJournal {
            config_changes: vec![ConfigChange::new("bst.enable_programmatic_ads", "1", "0")],
            ..Default::default()
        };

        assert!(validate_restore_runtime_state(&journal, &running).is_err());
        assert!(validate_restore_runtime_state(&CleanupJournal::default(), &running).is_ok());
    }

    #[test]
    fn clean_gaming_applies_supported_user_settings_but_not_feature_flags() {
        let raw = format!(
            "{}bst.create_desktop_shortcuts=\"1\"\nbst.feature.programmatic_ads=\"1\"\n",
            CURRENT_CONF
        );
        let mut document = BlueStacksConfigDocument::parse(&raw).unwrap();
        let mut journal = CleanupJournal::default();
        let changed = apply_config_cleanup(
            &mut document,
            &CleanupSelection::for_profile(CleanupProfile::CleanGaming),
            &mut journal,
        );

        assert!(changed.contains(&"bst.enable_programmatic_ads".to_owned()));
        assert!(changed.contains(&"bst.launch_store_on_boot".to_owned()));
        assert!(changed.contains(&"bst.create_desktop_shortcuts".to_owned()));
        assert!(changed.contains(&"bst.instance.Nougat32.enable_notifications".to_owned()));
        assert_eq!(document.get("bst.feature.programmatic_ads"), Some("1"));
        assert!(!journal.config_changes.is_empty());
    }

    #[test]
    fn classifies_bluestacks_components_conservatively() {
        assert_eq!(
            classify_component("BlueStacks"),
            ComponentClassification::Required
        );
        assert_eq!(
            classify_component("BlueStacks 5"),
            ComponentClassification::Required
        );
        assert_eq!(
            classify_component("BlueStacks Services"),
            ComponentClassification::FeatureSpecific
        );
        assert_eq!(
            classify_component("BlueStacks X"),
            ComponentClassification::PromotionalFrontend
        );
        assert_eq!(
            classify_component("BlueStacks AI"),
            ComponentClassification::Optional
        );
        assert_eq!(
            classify_component("BlueStacks Future Helper"),
            ComponentClassification::Unknown
        );
    }

    #[test]
    fn protects_bluestacks_hypervisor_and_runtime_services() {
        assert_eq!(
            classify_service(
                "BlueStacksDrv_nxt",
                "BlueStacks Hypervisor_nxt",
                r"\??\C:\Program Files\BlueStacks_nxt\BstkDrv_nxt.sys",
            ),
            ComponentClassification::Required
        );
        assert_eq!(
            classify_service(
                "BstkSVC",
                "BlueStacks Service",
                r"C:\BlueStacks\BstkSVC.exe"
            ),
            ComponentClassification::Required
        );
        assert_eq!(
            classify_service("FutureSvc", "Future helper", r"C:\Future\helper.exe"),
            ComponentClassification::Unknown
        );
    }

    #[test]
    fn android_cleanup_protects_core_and_only_allows_known_promotional_package() {
        for package in [
            "android",
            "com.android.vending",
            "com.google.android.gms",
            "com.google.android.webview",
            "com.bluestacks.settings",
            "com.bst.instance",
        ] {
            assert!(matches!(
                classify_android_package(package, false),
                AndroidPackageClassification::ProtectedSystem
                    | AndroidPackageClassification::ProtectedGoogle
                    | AndroidPackageClassification::ProtectedBlueStacks
            ));
            assert!(validate_android_disable(package, false).is_err());
        }

        assert_eq!(
            classify_android_package("com.uncube.gamevantage", true),
            AndroidPackageClassification::OptionalPromotional
        );
        assert!(validate_android_disable("com.uncube.gamevantage", true).is_ok());
        assert_eq!(
            classify_android_package("com.example.usergame", true),
            AndroidPackageClassification::UserInstalled
        );
        assert!(validate_android_disable("com.example.usergame", true).is_err());
        assert_eq!(
            classify_android_package("com.vendor.unknownsystem", false),
            AndroidPackageClassification::Unknown
        );
    }

    #[test]
    fn version_change_requests_reapply_without_blocking_update() {
        assert!(!cleanup_needs_reapply("5.22.280.1026", "5.22.280.1026"));
        assert!(cleanup_needs_reapply("5.22.280.1026", "5.22.300.1000"));
        assert!(!cleanup_needs_reapply("", "5.22.300.1000"));
    }

    #[test]
    fn only_known_optional_startup_helpers_are_safe_to_disable() {
        let services = classify_startup_entry(
            "electron.app.BlueStacks Services",
            r#""C:\Users\me\bluestacks-services\BlueStacksServices.exe" --hidden"#,
        );
        assert_eq!(
            services.classification,
            ComponentClassification::FeatureSpecific
        );
        assert!(services.safe_to_disable);

        let x = classify_startup_entry(
            "BlueStacks X",
            r#""C:\Program Files (x86)\BlueStacks X\BlueStacks X.exe" --hidden"#,
        );
        assert_eq!(
            x.classification,
            ComponentClassification::PromotionalFrontend
        );
        assert!(x.safe_to_disable);

        let player = classify_startup_entry(
            "BlueStacks 5",
            r#""C:\Program Files\BlueStacks_nxt\HD-Player.exe" --instance Nougat32"#,
        );
        assert_eq!(
            player.classification,
            ComponentClassification::FeatureSpecific
        );
        assert!(player.safe_to_disable);

        let updater = classify_startup_entry(
            "BlueStacks Updater",
            r#""C:\Program Files\BlueStacks_nxt\BlueStacksUpdater.exe""#,
        );
        assert!(!updater.safe_to_disable);
    }

    #[test]
    fn shortcut_disable_is_idempotent_and_restore_refuses_conflict() {
        let dir = temp_dir("shortcut-journal");
        fs::create_dir_all(&dir).unwrap();
        let shortcut = dir.join("BlueStacks 5.lnk");
        fs::write(&shortcut, b"shortcut").unwrap();
        let mut journal = CleanupJournal::default();

        let disabled = disable_shortcut(&shortcut, &mut journal).unwrap();
        assert!(disabled);
        assert!(!shortcut.exists());
        assert_eq!(journal.shortcut_changes.len(), 1);
        assert!(!disable_shortcut(&shortcut, &mut journal).unwrap());
        assert_eq!(journal.shortcut_changes.len(), 1);

        fs::write(&shortcut, b"user replacement").unwrap();
        let report = restore_shortcut_changes(&mut journal).unwrap();
        assert!(report.restored.is_empty());
        assert_eq!(report.skipped_conflicts.len(), 1);
        assert_eq!(journal.shortcut_changes.len(), 1);
        assert_eq!(fs::read(&shortcut).unwrap(), b"user replacement");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn shortcut_restore_reverses_only_our_hidden_file() {
        let dir = temp_dir("shortcut-restore");
        fs::create_dir_all(&dir).unwrap();
        let shortcut = dir.join("BlueStacks Manager.lnk");
        fs::write(&shortcut, b"shortcut").unwrap();
        let mut journal = CleanupJournal::default();

        assert!(disable_shortcut(&shortcut, &mut journal).unwrap());
        let report = restore_shortcut_changes(&mut journal).unwrap();

        assert_eq!(report.restored.len(), 1);
        assert!(report.skipped_conflicts.is_empty());
        assert!(shortcut.exists());
        assert!(journal.shortcut_changes.is_empty());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn shortcut_cleanup_skips_a_failed_rename_and_continues() {
        use std::fs::OpenOptions;
        use std::os::windows::fs::OpenOptionsExt;

        let dir = temp_dir("shortcut-partial");
        fs::create_dir_all(&dir).unwrap();
        let blocked = dir.join("BlueStacks 5.lnk");
        let writable = dir.join("BlueStacks Manager.lnk");
        fs::write(&blocked, b"blocked shortcut").unwrap();
        fs::write(&writable, b"writable shortcut").unwrap();

        // Deny delete sharing so Windows rejects the first rename. This gives
        // the cleanup loop a deterministic per-item filesystem failure.
        let lock = OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&blocked)
            .unwrap();
        let shortcuts = vec![
            BlueStacksShortcut {
                path: blocked.to_string_lossy().into_owned(),
                name: "BlueStacks 5.lnk".to_owned(),
                location: ShortcutLocation::Desktop,
                recommended_cleanup: true,
            },
            BlueStacksShortcut {
                path: writable.to_string_lossy().into_owned(),
                name: "BlueStacks Manager.lnk".to_owned(),
                location: ShortcutLocation::Desktop,
                recommended_cleanup: true,
            },
        ];
        let mut journal = CleanupJournal::default();
        let mut report = CleanupApplyReport::default();

        let result = apply_recommended_shortcut_cleanup(shortcuts, &mut journal, &mut report);
        let writable_hidden = disabled_shortcut_path(&writable).exists();
        let report_json = serde_json::to_value(&report).unwrap();
        drop(lock);
        fs::remove_dir_all(&dir).unwrap();

        assert!(
            result.is_ok(),
            "one shortcut failure should not abort cleanup"
        );
        assert!(
            writable_hidden,
            "cleanup should continue to later shortcuts"
        );
        assert_eq!(journal.shortcut_changes.len(), 1);
        assert_eq!(report.hidden_shortcuts.len(), 1);
        assert_eq!(
            report_json["skipped_actions"][0]["target"],
            blocked.to_string_lossy().as_ref()
        );
    }

    #[test]
    fn parses_adb_package_lists_without_accepting_noise() {
        let packages = parse_package_list(
            "package:com.android.vending\r\npackage:com.uncube.gamevantage\r\nerror: ignored\r\n",
        );
        assert_eq!(
            packages,
            BTreeSet::from([
                "com.android.vending".to_owned(),
                "com.uncube.gamevantage".to_owned(),
            ])
        );
    }

    #[test]
    fn cleanup_journal_and_default_apps_round_trip_json() {
        let mut journal = CleanupJournal::default();
        journal.record_config_change("bst.enable_programmatic_ads", "1", "0");
        journal.disabled_android_packages.insert(
            "Nougat32".to_owned(),
            vec!["com.uncube.gamevantage".to_owned()],
        );
        let encoded = serde_json::to_string(&journal).unwrap();
        let decoded: CleanupJournal = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded, journal);

        let mut apps = DefaultApps::default();
        apps.set("Nougat32", "com.nexon.maplem.global").unwrap();
        assert_eq!(apps.get("Nougat32"), Some("com.nexon.maplem.global"));
        assert!(apps.set("Nougat32", "bad package & calc").is_err());
    }

    #[test]
    fn parses_installed_apps_from_bluestacks_app_cache() {
        let apps = parse_app_cache(
            r#"[
                {
                    "activity": "com.nexon.ma.MainActivity",
                    "appLabel": "MapleStory : Idle RPG",
                    "category": "Role Playing",
                    "package": "com.nexon.ma",
                    "versionName": "1.16.0"
                },
                {
                    "activity": "ignored.Activity",
                    "appLabel": "Broken",
                    "category": "",
                    "package": "bad package",
                    "versionName": "1"
                }
            ]"#,
        );

        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].package, "com.nexon.ma");
        assert_eq!(apps[0].label, "MapleStory : Idle RPG");
        assert_eq!(apps[0].activity, "com.nexon.ma.MainActivity");
        assert_eq!(apps[0].category, "Role Playing");
        assert_eq!(apps[0].version_name, "1.16.0");
    }

    #[test]
    fn parses_registered_uninstaller_without_shell_interpretation() {
        let (program, args) = parse_registered_uninstall_command(
            r#""C:\Program Files (x86)\BlueStacks X\Uninstall.exe" --uninstall --silent"#,
        )
        .unwrap();
        assert_eq!(
            program,
            PathBuf::from(r"C:\Program Files (x86)\BlueStacks X\Uninstall.exe")
        );
        assert_eq!(args, vec!["--uninstall", "--silent"]);
        assert!(parse_registered_uninstall_command("cmd.exe /c del C:\\important").is_err());
        assert!(parse_registered_uninstall_command(
            r#""C:\Program Files\BlueStacks\Uninstall.exe" & calc.exe"#
        )
        .is_err());
    }

    #[test]
    fn component_uninstall_guard_rejects_required_and_unknown_components() {
        let component = |classification| BlueStacksComponent {
            id: "test".to_owned(),
            display_name: "Test".to_owned(),
            version: String::new(),
            install_location: String::new(),
            classification,
            can_remove: true,
            uninstall_command: r#""C:\Temp\uninstall.exe""#.to_owned(),
        };
        assert!(validate_component_removal(&component(ComponentClassification::Required)).is_err());
        assert!(validate_component_removal(&component(ComponentClassification::Unknown)).is_err());
        assert!(validate_component_removal(&component(ComponentClassification::Optional)).is_ok());
        assert!(validate_component_removal(&component(
            ComponentClassification::PromotionalFrontend
        ))
        .is_ok());
    }

    #[test]
    fn detects_bluestacks_x_only_when_player_and_vendor_uninstaller_are_present() {
        let dir = temp_dir("bluestacks-x");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("BlueStacks X.exe"), b"").unwrap();
        assert!(bluestacks_x_component_from_dir(&dir).is_none());

        fs::write(dir.join("BlueStacksXUninstaller.exe"), b"").unwrap();
        let component = bluestacks_x_component_from_dir(&dir).unwrap();
        assert_eq!(component.display_name, "BlueStacks X");
        assert_eq!(
            component.classification,
            ComponentClassification::PromotionalFrontend
        );
        assert!(component.can_remove);
        assert!(component
            .uninstall_command
            .contains("BlueStacksXUninstaller.exe"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[ignore = "requires BLUESTACKS_RUNNING_INSTANCE to name a running local instance; read-only"]
    fn discovers_running_instance_without_readable_player_command_line() {
        let instance_id = std::env::var("BLUESTACKS_RUNNING_INSTANCE").unwrap();
        let provider = BlueStacksProvider::detect().unwrap().unwrap();
        let target = provider
            .discover()
            .unwrap()
            .into_iter()
            .find(|target| target.provider_instance_id == instance_id)
            .unwrap();
        assert_ne!(
            target.state,
            EmulatorState::Stopped,
            "A running elevated player must not be reported as stopped"
        );
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

    #[test]
    #[ignore = "starts a local instance and launches the explicitly configured smoke-test app"]
    fn plays_real_local_bluestacks_app() {
        let instance_id = std::env::var("BLUESTACKS_SMOKE_INSTANCE").unwrap();
        let package = std::env::var("BLUESTACKS_SMOKE_PACKAGE").unwrap();
        let payload = serde_json::json!({
            "action": "play_app",
            "instance_id": instance_id,
            "package": package,
        });
        let result: serde_json::Value =
            serde_json::from_str(&handle_action_json(&payload.to_string())).unwrap();
        println!("launch result: {}", result["data"]["report"]);
        assert_eq!(result["ok"], true, "{}", result["error"]);
        assert_eq!(result["data"]["report"]["package"], package);
        assert_eq!(result["data"]["report"]["adb_verified"], true);
    }

    #[test]
    #[ignore = "requires a local BlueStacks 5 installation; read-only"]
    fn inventories_real_local_bluestacks_management_surfaces() {
        let provider = BlueStacksProvider::detect()
            .unwrap()
            .expect("BlueStacks 5 should be installed");
        let components = enumerate_components();
        let startup = enumerate_startup_entries();
        let shortcuts = enumerate_shortcuts();
        let services = enumerate_services();

        println!("BlueStacks {}", provider.installation.version);
        println!("components={components:#?}");
        println!("startup={startup:#?}");
        println!("shortcuts={shortcuts:#?}");
        println!("services={services:#?}");

        assert!(components
            .iter()
            .any(|component| { component.classification == ComponentClassification::Required }));
        assert!(shortcuts
            .iter()
            .any(|shortcut| shortcut.name.eq_ignore_ascii_case("BlueStacks 5.lnk")));
    }

    fn temp_dir(suffix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("rustdesk-bluestacks-{suffix}-{nonce}"))
    }
}
