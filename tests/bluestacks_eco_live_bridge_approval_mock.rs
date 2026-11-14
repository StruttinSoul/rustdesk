//! Mock-only approval tests for a hypothetical BlueStacks host Eco UI bridge.
//! No Windows UI, ADB, emulator, native process, registry or config access.
//! Run as an isolated file with rustc --test; do not include in a live build.

#[path = "../src/server/emulator/eco_fps.rs"]
mod eco_fps;

use eco_fps::{
    Activity, EcoBackend, EcoController, EcoMode, EcoPolicy, InstanceSignals, MANAGED_INSTANCES,
};
use std::{collections::BTreeMap, time::Duration};

const VERIFIED_RELEASE: &str = "5.22.280.1026";

#[derive(Clone)]
struct SyntheticPanel {
    instance: String,
    process_identity_verified: bool,
    version: String,
    unique_window: bool,
    accessible_eco_toggle: bool,
    accessible_eco_fps: bool,
    desktop_interactive: bool,
    mode: EcoMode,
    sound_on: bool,
}

impl SyntheticPanel {
    fn ready(instance: &str) -> Self {
        Self {
            instance: instance.to_owned(),
            process_identity_verified: true,
            version: VERIFIED_RELEASE.to_owned(),
            unique_window: true,
            accessible_eco_toggle: true,
            accessible_eco_fps: true,
            desktop_interactive: true,
            mode: EcoMode::Normal,
            sound_on: true,
        }
    }

    fn verify(&self, requested: &str) -> Result<(), String> {
        if self.instance != requested
            || !MANAGED_INSTANCES.contains(&requested)
            || !self.process_identity_verified
            || !self.unique_window
            || self.version != VERIFIED_RELEASE
        {
            return Err("Instance/window/process/version identity is not verified".into());
        }
        if !self.desktop_interactive || !self.accessible_eco_toggle || !self.accessible_eco_fps {
            return Err("Per-instance Eco controls cannot be read semantically".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum JournalStatus {
    Prepared,
    Owned,
}

#[derive(Clone, Debug)]
struct JournalEntry {
    previous: EcoMode,
    requested: EcoMode,
    sound_on: bool,
    status: JournalStatus,
}

/// A synthetic UI: a write is permitted only after semantic readback, strict
/// identity matching and pre-write ownership recording. The journal lives in
/// memory in this test; a future real version MUST fsync protected storage.
struct SyntheticUiBridge {
    panels: BTreeMap<String, SyntheticPanel>,
    journal: BTreeMap<String, JournalEntry>,
    writes: Vec<(String, EcoMode)>,
    interrupted_after_prepare: bool,
    interrupted_after_click: bool,
}

impl SyntheticUiBridge {
    fn ready() -> Self {
        Self {
            panels: MANAGED_INSTANCES
                .iter()
                .map(|id| (id.to_string(), SyntheticPanel::ready(id)))
                .collect(),
            journal: BTreeMap::new(),
            writes: Vec::new(),
            interrupted_after_prepare: false,
            interrupted_after_click: false,
        }
    }

    fn recover_pending(&mut self, instance: &str) -> Result<(), String> {
        let Some(entry) = self.journal.get(instance).cloned() else {
            return Ok(());
        };
        // There is no proof of controller ownership after a crash between
        // a UI click and its readback. Never blindly send a toggle to undo it.
        if entry.status == JournalStatus::Prepared {
            let panel = self.panels.get(instance).ok_or("Instance missing")?;
            panel.verify(instance)?;
            if panel.mode == entry.previous && panel.sound_on == entry.sound_on {
                self.journal.remove(instance);
                Ok(())
            } else {
                Err("Ambiguous prepared transaction: manual review required".into())
            }
        } else {
            Err("Owned Eco setting requires separately approved recovery".into())
        }
    }
}

impl EcoBackend for SyntheticUiBridge {
    fn read_mode(&mut self, instance: &str) -> Result<EcoMode, String> {
        let panel = self.panels.get(instance).ok_or("Instance missing")?;
        panel.verify(instance)?;
        if self
            .journal
            .get(instance)
            .map(|entry| entry.status == JournalStatus::Prepared)
            .unwrap_or(false)
        {
            return Err("Unresolved prepared journal must be reconciled".into());
        }
        Ok(panel.mode)
    }

    fn compare_and_set(
        &mut self,
        instance: &str,
        expected: EcoMode,
        requested: EcoMode,
    ) -> Result<(), String> {
        let panel = self.panels.get(instance).ok_or("Instance missing")?;
        panel.verify(instance)?;
        if panel.mode != expected {
            return Err("Concurrent/manual Eco change: CAS rejected".into());
        }
        if self
            .journal
            .get(instance)
            .map(|entry| entry.status == JournalStatus::Prepared)
            .unwrap_or(false)
        {
            return Err("Unresolved prepared journal".into());
        }
        if requested == EcoMode::Normal {
            let owned = self.journal.get(instance);
            if !matches!(owned, Some(entry) if entry.status == JournalStatus::Owned && entry.requested == expected)
            {
                return Err("Refusing to restore a mode this controller does not own".into());
            }
        } else if requested != EcoMode::Eco(12) || expected != EcoMode::Normal {
            return Err("Unexpected FPS transition".into());
        }
        let sound_on = panel.sound_on;
        self.journal.insert(
            instance.to_owned(),
            JournalEntry {
                previous: expected,
                requested,
                sound_on,
                status: JournalStatus::Prepared,
            },
        );
        if self.interrupted_after_prepare {
            return Err("Simulated crash before UI write".into());
        }
        // Mock only: no keyboard/window messages or actual UI interaction.
        self.panels.get_mut(instance).unwrap().mode = requested;
        self.writes.push((instance.to_owned(), requested));
        if self.interrupted_after_click {
            return Err("Simulated crash after UI write but before readback".into());
        }
        let after = self.panels.get(instance).unwrap();
        if after.mode != requested || after.sound_on != sound_on {
            return Err("Post-write mode/audio readback mismatch".into());
        }
        if requested == EcoMode::Normal {
            self.journal.remove(instance);
        } else {
            self.journal.get_mut(instance).unwrap().status = JournalStatus::Owned;
        }
        Ok(())
    }
}

fn signals(id: &str) -> InstanceSignals<'_> {
    InstanceSignals {
        instance_id: id,
        running: true,
        remote: Activity::Inactive,
        local: Activity::Inactive,
        solver_capture: Activity::Inactive,
    }
}

fn enabled_policy() -> EcoPolicy {
    EcoPolicy {
        enabled: true,
        ..EcoPolicy::default()
    }
}

#[test]
fn current_jarvis_unaudited_ui_semantics_must_block_toggle_without_side_effects() {
    let mut backend = SyntheticUiBridge::ready();
    backend
        .panels
        .get_mut(MANAGED_INSTANCES[0])
        .unwrap()
        .accessible_eco_toggle = false;
    assert!(backend.read_mode(MANAGED_INSTANCES[0]).is_err());
    assert!(backend
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Normal, EcoMode::Eco(12))
        .is_err());
    assert!(backend.writes.is_empty());
    assert!(backend.journal.is_empty());
    let mut controller = EcoController::new(enabled_policy(), backend).unwrap();
    let target = signals(MANAGED_INSTANCES[0]);
    controller.reconcile(Duration::ZERO, &[target]);
    let outcomes = controller.reconcile(Duration::from_secs(120), &[target]);
    assert_eq!(outcomes.len(), 1);
    assert!(outcomes[0].result.is_err());
}

#[test]
fn wrong_identity_version_duplicate_or_locked_desktop_are_rejected_without_writes() {
    for fault in 0..4 {
        let mut bridge = SyntheticUiBridge::ready();
        let panel = bridge.panels.get_mut(MANAGED_INSTANCES[0]).unwrap();
        match fault {
            0 => panel.process_identity_verified = false,
            1 => panel.version = "5.22.999.0000".to_owned(),
            2 => panel.unique_window = false,
            _ => panel.desktop_interactive = false,
        }
        assert!(bridge.read_mode(MANAGED_INSTANCES[0]).is_err());
        assert!(bridge
            .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Normal, EcoMode::Eco(12))
            .is_err());
        assert!(bridge.writes.is_empty());
        assert!(bridge.journal.is_empty());
    }
}

#[test]
fn protected_sound_and_other_instances_survive_successful_mock_round_trip() {
    let mut bridge = SyntheticUiBridge::ready();
    assert!(bridge
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Normal, EcoMode::Eco(12))
        .is_ok());
    assert_eq!(bridge.panels[MANAGED_INSTANCES[0]].mode, EcoMode::Eco(12));
    assert!(bridge.panels[MANAGED_INSTANCES[0]].sound_on);
    for id in &MANAGED_INSTANCES[1..] {
        assert_eq!(bridge.panels[*id].mode, EcoMode::Normal);
    }
    assert!(bridge
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Eco(12), EcoMode::Normal)
        .is_ok());
    assert!(bridge.journal.is_empty());
    assert_eq!(bridge.writes.len(), 2);
}

#[test]
fn manual_eco_five_fps_and_out_of_band_changes_cannot_be_overwritten() {
    let mut bridge = SyntheticUiBridge::ready();
    bridge.panels.get_mut(MANAGED_INSTANCES[0]).unwrap().mode = EcoMode::Eco(5);
    assert!(bridge
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Normal, EcoMode::Eco(12))
        .is_err());
    assert!(bridge.writes.is_empty());
    bridge.panels.get_mut(MANAGED_INSTANCES[0]).unwrap().mode = EcoMode::Normal;
    bridge
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Normal, EcoMode::Eco(12))
        .unwrap();
    bridge.panels.get_mut(MANAGED_INSTANCES[0]).unwrap().mode = EcoMode::Eco(10);
    assert!(bridge
        .compare_and_set(MANAGED_INSTANCES[0], EcoMode::Eco(12), EcoMode::Normal)
        .is_err());
    assert_eq!(bridge.panels[MANAGED_INSTANCES[0]].mode, EcoMode::Eco(10));
}

#[test]
fn crashes_before_and_after_mock_click_keep_recovery_uncertain_until_proven() {
    let id = MANAGED_INSTANCES[0];
    let mut bridge = SyntheticUiBridge::ready();
    bridge.interrupted_after_prepare = true;
    assert!(bridge
        .compare_and_set(id, EcoMode::Normal, EcoMode::Eco(12))
        .is_err());
    assert_eq!(bridge.journal[id].status, JournalStatus::Prepared);
    assert!(bridge.recover_pending(id).is_ok());
    assert!(bridge.journal.is_empty());
    bridge.interrupted_after_prepare = false;
    bridge.interrupted_after_click = true;
    assert!(bridge
        .compare_and_set(id, EcoMode::Normal, EcoMode::Eco(12))
        .is_err());
    assert_eq!(bridge.journal[id].status, JournalStatus::Prepared);
    let persisted_journal = bridge.journal.clone();
    let persisted_panels = bridge.panels.clone();
    let mut restarted = SyntheticUiBridge::ready();
    restarted.journal = persisted_journal;
    restarted.panels = persisted_panels;
    assert!(restarted.recover_pending(id).is_err());
    assert!(restarted.read_mode(id).is_err());
    assert_eq!(restarted.panels[id].mode, EcoMode::Eco(12));
    assert!(restarted.writes.is_empty());
    assert_eq!(bridge.writes.len(), 1);
}

#[test]
fn unknown_remote_local_or_solver_signal_blocks_mock_eco_eligibility() {
    let mut controller = EcoController::new(enabled_policy(), SyntheticUiBridge::ready()).unwrap();
    for channel in 0..3 {
        let mut observation = signals(MANAGED_INSTANCES[0]);
        match channel {
            0 => observation.remote = Activity::Unknown,
            1 => observation.local = Activity::Unknown,
            _ => observation.solver_capture = Activity::Unknown,
        }
        controller.reconcile(Duration::from_secs(1000), &[observation]);
        assert!(controller
            .reconcile(Duration::from_secs(1300), &[observation])
            .is_empty());
    }
}
