use hbb_common::{bail, ResultType};
use std::{collections::BTreeMap, fmt, sync::Arc};

#[cfg(windows)]
pub mod bluestacks;
#[cfg(windows)]
pub mod boot_windows;
#[cfg(windows)]
pub mod ldplayer;
#[cfg(windows)]
pub mod guest_protocol;
#[cfg(windows)]
pub mod guest_runtime;
#[cfg(windows)]
pub mod host_management;
pub mod remote;
#[cfg(windows)]
pub mod remote_windows;

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ProviderId(String);

impl ProviderId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
}

impl fmt::Display for ProviderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdbEndpoint {
    pub serial: String,
}

impl AdbEndpoint {
    pub fn new(serial: impl Into<String>) -> Self {
        Self {
            serial: serial.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
/// Normalized user-facing emulator state. Providers own guest lifecycle/readiness
/// states; RustDesk session/media layers own Connecting, Connected, and StreamError.
pub enum EmulatorState {
    Stopped,
    Starting,
    Booting,
    Ready,
    Connecting,
    Connected,
    Stopping,
    Restarting,
    AdbOffline,
    Unresponsive,
    StreamError,
    Error,
    #[default]
    Unknown,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum EmulatorOrientation {
    Portrait,
    Landscape,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EmulatorDisplay {
    pub width: u32,
    pub height: u32,
    pub dpi: u32,
    pub orientation: EmulatorOrientation,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ThumbnailState {
    Ready,
    Pending,
    Unsupported,
    #[default]
    Unavailable,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct VideoCapabilities {
    pub h264: bool,
    pub h265: bool,
    pub dynamic_bitrate: bool,
    pub dynamic_fps: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AudioCapabilities {
    pub guest_capture: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InputCapabilities {
    pub touch: bool,
    pub multitouch: bool,
    pub keyboard: bool,
    pub hardware_keyboard: bool,
    pub clipboard: bool,
    pub android_navigation: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EmulatorCapabilities {
    pub start: bool,
    pub stop: bool,
    pub restart: bool,
    pub adb: bool,
    pub thumbnail: bool,
    pub video: VideoCapabilities,
    pub audio: AudioCapabilities,
    pub input: InputCapabilities,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EmulatorRuntimeState {
    pub state: EmulatorState,
    pub adb_endpoint: Option<AdbEndpoint>,
    pub display: Option<EmulatorDisplay>,
    pub foreground_package: Option<String>,
    pub foreground_app_name: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EmulatorTarget {
    pub provider: ProviderId,
    /// Provider-scoped identity that must survive refreshes and emulator restarts.
    /// It must not be derived from a PID, ADB endpoint, or display name.
    pub stable_id: String,
    /// Opaque provider-native identifier used only by provider implementations.
    provider_instance_id: String,
    pub display_name: String,
    pub android_flavor: Option<String>,
    pub android_version: Option<String>,
    pub state: EmulatorState,
    pub adb_endpoint: Option<AdbEndpoint>,
    pub display: Option<EmulatorDisplay>,
    pub foreground_package: Option<String>,
    pub foreground_app_name: Option<String>,
    pub capabilities: EmulatorCapabilities,
    pub thumbnail_state: ThumbnailState,
    pub last_error: Option<String>,
}

impl EmulatorTarget {
    pub fn new(
        provider: ProviderId,
        stable_id: impl Into<String>,
        provider_instance_id: impl Into<String>,
        display_name: impl Into<String>,
    ) -> Self {
        Self {
            provider,
            stable_id: stable_id.into(),
            provider_instance_id: provider_instance_id.into(),
            display_name: display_name.into(),
            android_flavor: None,
            android_version: None,
            state: EmulatorState::Unknown,
            adb_endpoint: None,
            display: None,
            foreground_package: None,
            foreground_app_name: None,
            capabilities: EmulatorCapabilities::default(),
            thumbnail_state: ThumbnailState::Unavailable,
            last_error: None,
        }
    }
}

pub trait EmulatorProvider: Send + Sync {
    fn provider_id(&self) -> ProviderId;
    fn discover(&self) -> ResultType<Vec<EmulatorTarget>>;
    fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState>;
    fn start(&self, target: &EmulatorTarget) -> ResultType<()>;
    fn stop(&self, target: &EmulatorTarget) -> ResultType<()>;
    fn restart(&self, target: &EmulatorTarget) -> ResultType<()>;
    fn resolve_adb(&self, target: &EmulatorTarget) -> ResultType<AdbEndpoint>;
    fn capabilities(&self, target: &EmulatorTarget) -> EmulatorCapabilities;
}

#[derive(Default)]
pub struct ProviderRegistry {
    providers: BTreeMap<ProviderId, Arc<dyn EmulatorProvider>>,
}

impl ProviderRegistry {
    pub fn register(&mut self, provider: Arc<dyn EmulatorProvider>) -> ResultType<()> {
        let id = provider.provider_id();
        if self.providers.contains_key(&id) {
            bail!("emulator provider '{id}' is already registered");
        }
        self.providers.insert(id, provider);
        Ok(())
    }

    pub fn provider(&self, id: &ProviderId) -> Option<Arc<dyn EmulatorProvider>> {
        self.providers.get(id).cloned()
    }

    pub fn provider_for(&self, target: &EmulatorTarget) -> Option<Arc<dyn EmulatorProvider>> {
        self.provider(&target.provider)
    }

    pub fn discover_all(&self) -> ResultType<Vec<EmulatorTarget>> {
        let mut discovered = Vec::new();
        for (provider_id, provider) in &self.providers {
            for mut target in provider.discover()? {
                if &target.provider != provider_id {
                    bail!(
                        "emulator provider '{}' returned a target owned by '{}'",
                        provider_id,
                        target.provider
                    );
                }
                target.capabilities = provider.capabilities(&target);
                discovered.push(target);
            }
        }
        Ok(discovered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::ResultType;
    use std::sync::Arc;

    struct FakeProvider {
        id: ProviderId,
        targets: Vec<EmulatorTarget>,
        capabilities: EmulatorCapabilities,
    }

    impl FakeProvider {
        fn new(id: &str, targets: Vec<EmulatorTarget>) -> Self {
            Self {
                id: ProviderId::new(id),
                targets,
                capabilities: EmulatorCapabilities::default(),
            }
        }

        fn with_capabilities(mut self, capabilities: EmulatorCapabilities) -> Self {
            self.capabilities = capabilities;
            self
        }
    }

    impl EmulatorProvider for FakeProvider {
        fn provider_id(&self) -> ProviderId {
            self.id.clone()
        }

        fn discover(&self) -> ResultType<Vec<EmulatorTarget>> {
            Ok(self.targets.clone())
        }

        fn refresh(&self, target: &EmulatorTarget) -> ResultType<EmulatorRuntimeState> {
            Ok(EmulatorRuntimeState {
                state: target.state,
                ..Default::default()
            })
        }

        fn start(&self, _target: &EmulatorTarget) -> ResultType<()> {
            Ok(())
        }

        fn stop(&self, _target: &EmulatorTarget) -> ResultType<()> {
            Ok(())
        }

        fn restart(&self, _target: &EmulatorTarget) -> ResultType<()> {
            Ok(())
        }

        fn resolve_adb(&self, _target: &EmulatorTarget) -> ResultType<AdbEndpoint> {
            Ok(AdbEndpoint::new("127.0.0.1:5555"))
        }

        fn capabilities(&self, _target: &EmulatorTarget) -> EmulatorCapabilities {
            self.capabilities.clone()
        }
    }

    fn target(provider: &str, stable_id: &str, name: &str) -> EmulatorTarget {
        EmulatorTarget::new(ProviderId::new(provider), stable_id, stable_id, name)
    }

    #[test]
    fn new_target_starts_unknown_with_optional_runtime_metadata_absent() {
        let target = target("ldplayer", "0", "Main");

        assert_eq!(target.state, EmulatorState::Unknown);
        assert_eq!(target.display_name, "Main");
        assert!(target.android_version.is_none());
        assert!(target.adb_endpoint.is_none());
        assert!(target.display.is_none());
        assert!(target.foreground_package.is_none());
        assert!(target.last_error.is_none());
        assert_eq!(target.capabilities, EmulatorCapabilities::default());
    }

    #[test]
    fn normalized_state_distinguishes_lifecycle_readiness_and_failures() {
        let states = [
            EmulatorState::Stopped,
            EmulatorState::Starting,
            EmulatorState::Booting,
            EmulatorState::Ready,
            EmulatorState::Connecting,
            EmulatorState::Connected,
            EmulatorState::Stopping,
            EmulatorState::Restarting,
            EmulatorState::AdbOffline,
            EmulatorState::Unresponsive,
            EmulatorState::StreamError,
            EmulatorState::Error,
            EmulatorState::Unknown,
        ];

        assert_eq!(states.len(), 13);
        assert_ne!(EmulatorState::Starting, EmulatorState::Booting);
        assert_ne!(EmulatorState::Ready, EmulatorState::Connected);
        assert_ne!(EmulatorState::AdbOffline, EmulatorState::StreamError);
    }

    #[test]
    fn registry_rejects_duplicate_provider_ids() {
        let mut registry = ProviderRegistry::default();
        registry
            .register(Arc::new(FakeProvider::new("ldplayer", vec![])))
            .unwrap();

        let err = registry
            .register(Arc::new(FakeProvider::new("ldplayer", vec![])))
            .unwrap_err();

        assert!(err.to_string().contains("ldplayer"));
    }

    #[test]
    fn registry_routes_target_to_owning_provider() {
        let mut registry = ProviderRegistry::default();
        let provider: Arc<dyn EmulatorProvider> = Arc::new(FakeProvider::new("ldplayer", vec![]));
        registry.register(provider.clone()).unwrap();
        let target = target("ldplayer", "0", "LD Main");

        let resolved = registry.provider_for(&target).unwrap();

        assert!(Arc::ptr_eq(&provider, &resolved));
    }

    #[test]
    fn registry_populates_target_capabilities_from_provider() {
        let mut registry = ProviderRegistry::default();
        let mut capabilities = EmulatorCapabilities::default();
        capabilities.start = true;
        capabilities.stop = true;
        capabilities.video.h264 = true;
        capabilities.input.touch = true;
        registry
            .register(Arc::new(
                FakeProvider::new("ldplayer", vec![target("ldplayer", "0", "LD Main")])
                    .with_capabilities(capabilities.clone()),
            ))
            .unwrap();

        let discovered = registry.discover_all().unwrap();

        assert_eq!(discovered[0].capabilities, capabilities);
    }

    #[test]
    fn registry_discovers_targets_across_providers_in_provider_id_order() {
        let mut registry = ProviderRegistry::default();
        registry
            .register(Arc::new(FakeProvider::new(
                "ldplayer",
                vec![target("ldplayer", "0", "LD Main")],
            )))
            .unwrap();
        registry
            .register(Arc::new(FakeProvider::new(
                "bluestacks",
                vec![target("bluestacks", "Pie64", "BlueStacks Pie")],
            )))
            .unwrap();

        let discovered = registry.discover_all().unwrap();
        let names: Vec<_> = discovered
            .iter()
            .map(|target| target.display_name.as_str())
            .collect();

        assert_eq!(names, vec!["BlueStacks Pie", "LD Main"]);
    }

    #[test]
    fn registry_rejects_provider_results_with_the_wrong_provider_id() {
        let mut registry = ProviderRegistry::default();
        registry
            .register(Arc::new(FakeProvider::new(
                "ldplayer",
                vec![target("bluestacks", "0", "Wrong Owner")],
            )))
            .unwrap();

        let err = registry.discover_all().unwrap_err();

        assert!(err.to_string().contains("ldplayer"));
        assert!(err.to_string().contains("bluestacks"));
    }
}
