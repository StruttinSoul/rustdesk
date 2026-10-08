use base::message_proto::DisplayInfo;
use hbb_common::{bail, config::Config, lazy_static, ResultType};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, sync::Mutex};

const OPTION_OWNED_SESSION: &str = "mirpg-phone-workspace-owned-session-v1";
const SESSION_SCHEMA: u32 = 1;

lazy_static::lazy_static! {
    static ref WORKSPACE_LOCK: Mutex<()> = Mutex::new(());
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PhoneWorkspaceProfile {
    pub width: u32,
    pub height: u32,
    pub orientation: String,
    pub dpi: u32,
}

impl PhoneWorkspaceProfile {
    pub fn validate(&self) -> ResultType<()> {
        if !(720..=3840).contains(&self.width) || !(720..=3840).contains(&self.height) {
            bail!("Phone Workspace size must be between 720 and 3840 pixels per side.");
        }
        match self.orientation.as_str() {
            "portrait" if self.height > self.width => {}
            "landscape" if self.width > self.height => {}
            "portrait" | "landscape" => {
                bail!("Phone Workspace orientation does not match the requested size.")
            }
            _ => bail!("Phone Workspace orientation must be portrait or landscape."),
        }
        if self.dpi != 0 {
            bail!("Custom Phone Workspace DPI is not supported by this virtual display driver.");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct PhysicalDisplayState {
    name: String,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    scale_milli: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PhoneWorkspaceSession {
    pub schema: u32,
    pub id: String,
    pub driver: String,
    pub display_index: u32,
    pub device_name: String,
    pub profile: PhoneWorkspaceProfile,
    pub created_at_ms: u64,
    pub expected_virtual_names: Vec<String>,
    #[serde(default)]
    owner_process_id: u32,
    physical_before: Vec<PhysicalDisplayState>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PhoneWorkspaceSupport {
    pub schema: u32,
    pub supported: bool,
    pub driver: String,
    pub driver_installed: bool,
    pub requires_driver_install: bool,
    pub custom_dpi_supported: bool,
    pub owned_cleanup_supported: bool,
    pub reason: String,
    pub profiles: Vec<PhoneWorkspaceProfile>,
    pub active_session: Option<PhoneWorkspaceSession>,
    pub reconciliation: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum OwnershipState {
    Absent,
    Active,
    Ambiguous,
}

pub fn query_support() -> PhoneWorkspaceSupport {
    let _guard = WORKSPACE_LOCK.lock().unwrap();
    query_support_unlocked()
}

fn query_support_unlocked() -> PhoneWorkspaceSupport {
    let driver = crate::virtual_display_manager::current_driver_impl().to_owned();
    let platform_supported = crate::virtual_display_manager::is_virtual_display_supported();
    let driver_installed = crate::virtual_display_manager::is_virtual_display_driver_installed();
    let owned_cleanup_supported =
        crate::virtual_display_manager::supports_owned_virtual_display_cleanup();
    let current_virtual =
        normalized_names(crate::virtual_display_manager::current_virtual_display_names());
    let (mut active_session, session_error) = match load_session() {
        Ok(session) => (session, None),
        Err(error) => (None, Some(error.to_string())),
    };
    let reconciliation = if let Some(session) = active_session.as_ref() {
        match ownership_state(session, &current_virtual, native_ownership_proven(session)) {
            OwnershipState::Active => "owned_display_present".to_owned(),
            OwnershipState::Absent => {
                clear_session();
                active_session = None;
                "stale_record_cleared".to_owned()
            }
            OwnershipState::Ambiguous => "ownership_ambiguous".to_owned(),
        }
    } else if session_error.is_some() {
        "ownership_record_invalid".to_owned()
    } else {
        "none".to_owned()
    };
    let amyuni_foreign_display = driver == "amyuni_idd"
        && active_session.is_none()
        && session_error.is_none()
        && !current_virtual.is_empty();
    let ownership_ambiguous = reconciliation == "ownership_ambiguous";
    let supported = platform_supported
        && driver_installed
        && owned_cleanup_supported
        && session_error.is_none()
        && !ownership_ambiguous
        && !amyuni_foreign_display;
    let reason = if !platform_supported {
        "Phone Workspace requires Windows 10 2004 or newer.".to_owned()
    } else if !driver_installed {
        "The virtual display driver is not installed. Phone Workspace will not install it automatically."
            .to_owned()
    } else if !owned_cleanup_supported {
        format!(
            "The active {driver} virtual display backend cannot safely identify and remove one owned display after a restart."
        )
    } else if let Some(error) = session_error {
        format!(
            "Phone Workspace found an invalid ownership record and will not create another display until it is resolved: {error}"
        )
    } else if ownership_ambiguous {
        "Phone Workspace can see the recorded virtual display, but native ownership can no longer be proven. No display will be added or removed automatically."
            .to_owned()
    } else if amyuni_foreign_display {
        "An Amyuni virtual display already exists outside the current Phone Workspace session. No additional display will be created automatically."
            .to_owned()
    } else {
        String::new()
    };
    PhoneWorkspaceSupport {
        schema: SESSION_SCHEMA,
        supported,
        driver,
        driver_installed,
        requires_driver_install: platform_supported && !driver_installed,
        custom_dpi_supported: false,
        owned_cleanup_supported,
        reason,
        profiles: vec![
            PhoneWorkspaceProfile {
                width: 1080,
                height: 2400,
                orientation: "portrait".to_owned(),
                dpi: 0,
            },
            PhoneWorkspaceProfile {
                width: 2400,
                height: 1080,
                orientation: "landscape".to_owned(),
                dpi: 0,
            },
        ],
        active_session,
        reconciliation,
    }
}

pub fn begin(profile: PhoneWorkspaceProfile) -> ResultType<(PhoneWorkspaceSession, bool)> {
    let _guard = WORKSPACE_LOCK.lock().unwrap();
    profile.validate()?;
    let support = query_support_unlocked();
    if !support.supported {
        bail!("{}", support.reason);
    }

    if let Some(existing) = support.active_session {
        let current =
            normalized_names(crate::virtual_display_manager::current_virtual_display_names());
        match ownership_state(&existing, &current, native_ownership_proven(&existing)) {
            OwnershipState::Active if existing.profile == profile => {
                return Ok((existing, true));
            }
            OwnershipState::Active => {
                bail!(
                    "A Phone Workspace display is already active. End it before changing profile."
                );
            }
            OwnershipState::Ambiguous => {
                bail!("Phone Workspace ownership is ambiguous. No additional display was created.");
            }
            OwnershipState::Absent => clear_session(),
        }
    }

    let virtual_before =
        normalized_names(crate::virtual_display_manager::current_virtual_display_names());
    let physical_before = fresh_physical_display_state(&virtual_before)?;
    let modes = vec![virtual_display::MonitorMode {
        width: profile.width,
        height: profile.height,
        sync: 60,
    }];
    let (display_index, device_name) =
        crate::virtual_display_manager::plug_in_owned_monitor_existing_driver(modes)?;
    let virtual_after =
        normalized_names(crate::virtual_display_manager::current_virtual_display_names());
    let session = PhoneWorkspaceSession {
        schema: SESSION_SCHEMA,
        id: format!("phone-workspace-{}", uuid::Uuid::new_v4()),
        driver: support.driver,
        display_index,
        device_name,
        profile,
        created_at_ms: now_ms(),
        expected_virtual_names: virtual_after.clone(),
        owner_process_id: std::process::id(),
        physical_before: physical_before.clone(),
    };
    if let Err(error) = save_session(&session) {
        let _ = crate::virtual_display_manager::plug_out_owned_monitor(
            session.display_index,
            &session.device_name,
        );
        return Err(error);
    }
    if !exactly_one_owned_display_added(&virtual_before, &virtual_after, &session.device_name) {
        let cleanup = rollback_created_session(&session);
        if let Err(error) = cleanup {
            bail!("Windows did not expose exactly one identifiable Phone Workspace display. Cleanup also failed, so the ownership record was retained: {error}");
        }
        bail!("Windows did not expose exactly one identifiable Phone Workspace display. Activation was rolled back.");
    }
    let physical_after = match fresh_physical_display_state(&virtual_after) {
        Ok(state) => state,
        Err(error) => {
            let cleanup = rollback_created_session(&session);
            if let Err(cleanup_error) = cleanup {
                bail!("Phone Workspace could not verify the physical monitor state after creation: {error}. Cleanup also failed, so the ownership record was retained: {cleanup_error}");
            }
            bail!("Phone Workspace could not verify the physical monitor state after creation: {error}. Activation was rolled back.");
        }
    };
    if physical_after != physical_before {
        let cleanup = rollback_created_session(&session);
        if let Err(error) = cleanup {
            bail!("Physical monitor state changed while creating Phone Workspace. Cleanup also failed, so the ownership record was retained: {error}");
        }
        bail!("Physical monitor state changed while creating Phone Workspace; activation was rolled back.");
    }
    Ok((session, false))
}

pub fn end(owned_display_id: &str) -> ResultType<String> {
    let _guard = WORKSPACE_LOCK.lock().unwrap();
    if owned_display_id.is_empty() || owned_display_id.len() > 128 {
        bail!("Phone Workspace display identity is invalid.");
    }
    let Some(session) = load_session()? else {
        return Ok("Phone Workspace is already inactive.".to_owned());
    };
    if session.id != owned_display_id {
        bail!("Phone Workspace display identity does not match the owned display.");
    }
    let current = normalized_names(crate::virtual_display_manager::current_virtual_display_names());
    match ownership_state(&session, &current, native_ownership_proven(&session)) {
        OwnershipState::Absent => {
            clear_session();
            Ok(
                "Phone Workspace display was already absent; stale ownership was cleared."
                    .to_owned(),
            )
        }
        OwnershipState::Ambiguous => {
            bail!("Virtual display state changed outside Phone Workspace. Cleanup was not attempted so a foreign display cannot be removed.");
        }
        OwnershipState::Active => {
            crate::virtual_display_manager::plug_out_owned_monitor(
                session.display_index,
                &session.device_name,
            )?;
            let after =
                normalized_names(crate::virtual_display_manager::current_virtual_display_names());
            if contains_name(&after, &session.device_name) {
                bail!("Windows still reports the owned Phone Workspace display after cleanup.");
            }
            clear_session();
            Ok("Phone Workspace display removed.".to_owned())
        }
    }
}

fn ownership_state(
    session: &PhoneWorkspaceSession,
    current: &[String],
    native_owned: bool,
) -> OwnershipState {
    if !contains_name(current, &session.device_name) {
        return OwnershipState::Absent;
    }
    if normalized_names(current.to_vec())
        == normalized_names(session.expected_virtual_names.clone())
        && native_owned
    {
        OwnershipState::Active
    } else {
        OwnershipState::Ambiguous
    }
}

fn native_ownership_proven(session: &PhoneWorkspaceSession) -> bool {
    session.owner_process_id == std::process::id()
        && session.driver == crate::virtual_display_manager::current_driver_impl()
        && crate::virtual_display_manager::owned_monitor_matches(
            session.display_index,
            &session.device_name,
        )
}

fn fresh_physical_display_state(virtual_names: &[String]) -> ResultType<Vec<PhysicalDisplayState>> {
    let displays = super::super::display_service::try_get_displays()?;
    let infos = super::super::display_service::update_sync_displays(&displays);
    Ok(physical_display_state(&infos, virtual_names))
}

fn rollback_created_session(session: &PhoneWorkspaceSession) -> ResultType<()> {
    crate::virtual_display_manager::plug_out_owned_monitor(
        session.display_index,
        &session.device_name,
    )?;
    clear_session();
    Ok(())
}

fn exactly_one_owned_display_added(before: &[String], after: &[String], owned: &str) -> bool {
    let before = normalized_names(before.to_vec());
    let after = normalized_names(after.to_vec());
    if after.len() != before.len() + 1 || !contains_name(&after, owned) {
        return false;
    }
    before.iter().all(|name| contains_name(&after, name))
}

fn normalized_names(names: Vec<String>) -> Vec<String> {
    let mut names = names
        .into_iter()
        .map(|name| name.trim_end_matches('\0').to_owned())
        .collect::<Vec<_>>();
    names.sort_by_key(|name| name.to_ascii_lowercase());
    names.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
    names
}

fn contains_name(names: &[String], target: &str) -> bool {
    let target = target.trim_end_matches('\0');
    names
        .iter()
        .any(|name| name.trim_end_matches('\0').eq_ignore_ascii_case(target))
}

fn physical_display_state(
    displays: &[DisplayInfo],
    virtual_names: &[String],
) -> Vec<PhysicalDisplayState> {
    let virtual_names = virtual_names
        .iter()
        .map(|name| name.to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    let mut state = displays
        .iter()
        .filter(|display| !virtual_names.contains(&display.name.to_ascii_lowercase()))
        .map(|display| PhysicalDisplayState {
            name: display.name.clone(),
            x: display.x,
            y: display.y,
            width: display.width,
            height: display.height,
            scale_milli: (display.scale * 1000.0).round() as i64,
        })
        .collect::<Vec<_>>();
    state.sort_by_key(|display| display.name.to_ascii_lowercase());
    state
}

fn load_session() -> ResultType<Option<PhoneWorkspaceSession>> {
    let raw = Config::get_option(OPTION_OWNED_SESSION);
    if raw.is_empty() {
        return Ok(None);
    }
    let session: PhoneWorkspaceSession = serde_json::from_str(&raw)?;
    if session.schema != SESSION_SCHEMA
        || !session.id.starts_with("phone-workspace-")
        || session.id.len() > 128
        || session.device_name.is_empty()
    {
        bail!("Phone Workspace ownership record is invalid.");
    }
    Ok(Some(session))
}

fn save_session(session: &PhoneWorkspaceSession) -> ResultType<()> {
    let encoded = serde_json::to_string(session)?;
    Config::set_option(OPTION_OWNED_SESSION.to_owned(), encoded);
    Ok(())
}

fn clear_session() {
    Config::set_option(OPTION_OWNED_SESSION.to_owned(), String::new());
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> PhoneWorkspaceSession {
        PhoneWorkspaceSession {
            schema: SESSION_SCHEMA,
            id: "phone-workspace-test".to_owned(),
            driver: "rustdesk_idd".to_owned(),
            display_index: 3,
            device_name: r"\\.\DISPLAYV".to_owned(),
            profile: PhoneWorkspaceProfile {
                width: 1080,
                height: 2400,
                orientation: "portrait".to_owned(),
                dpi: 0,
            },
            created_at_ms: 1,
            expected_virtual_names: vec![
                r"\\.\DISPLAYFOREIGN".to_owned(),
                r"\\.\DISPLAYV".to_owned(),
            ],
            owner_process_id: std::process::id(),
            physical_before: Vec::new(),
        }
    }

    #[test]
    fn physical_monitor_state_preserved() {
        let physical = DisplayInfo {
            name: r"\\.\DISPLAY1".to_owned(),
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            scale: 1.25,
            ..Default::default()
        };
        let virtual_display = DisplayInfo {
            name: r"\\.\DISPLAYV".to_owned(),
            x: 2560,
            y: 0,
            width: 1080,
            height: 2400,
            scale: 1.0,
            ..Default::default()
        };
        let before = physical_display_state(std::slice::from_ref(&physical), &[]);
        let after =
            physical_display_state(&[physical, virtual_display], &[r"\\.\DISPLAYV".to_owned()]);
        assert_eq!(before, after);
    }

    #[test]
    fn foreign_virtual_display_not_removed() {
        let owned = session();
        let current = vec![
            r"\\.\DISPLAYFOREIGN".to_owned(),
            r"\\.\DISPLAYV".to_owned(),
            r"\\.\DISPLAYOTHER".to_owned(),
        ];
        assert_eq!(
            ownership_state(&owned, &current, true),
            OwnershipState::Ambiguous
        );
    }

    #[test]
    fn reconnect_does_not_create_duplicate() {
        let owned = session();
        assert_eq!(
            ownership_state(&owned, &owned.expected_virtual_names, true),
            OwnershipState::Active
        );
    }

    #[test]
    fn host_crash_reconciles_owned_display() {
        let owned = session();
        let reconstructed =
            serde_json::from_str::<PhoneWorkspaceSession>(&serde_json::to_string(&owned).unwrap())
                .unwrap();
        assert_eq!(
            ownership_state(&reconstructed, &reconstructed.expected_virtual_names, false),
            OwnershipState::Ambiguous
        );
        assert_eq!(
            ownership_state(&reconstructed, &reconstructed.expected_virtual_names, true),
            OwnershipState::Active
        );
    }

    #[test]
    fn dpi_unsupported_is_reported() {
        let profile = PhoneWorkspaceProfile {
            width: 1080,
            height: 2400,
            orientation: "portrait".to_owned(),
            dpi: 420,
        };
        assert!(profile.validate().unwrap_err().to_string().contains("DPI"));
    }

    #[test]
    fn cleanup_failure_visible() {
        let owned = session();
        let current = vec![
            r"\\.\DISPLAYFOREIGN".to_owned(),
            r"\\.\DISPLAYV".to_owned(),
            r"\\.\DISPLAYOTHER".to_owned(),
        ];
        assert_eq!(
            ownership_state(&owned, &current, true),
            OwnershipState::Ambiguous
        );
    }
}
