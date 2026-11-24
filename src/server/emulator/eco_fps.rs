//! Approval-gated BlueStacks Eco FPS policy. No live BlueStacks writer is provided.
//! This deliberately leaves the existing ADB, guest video and input paths untouched.

use std::{collections::BTreeMap, time::Duration};

pub const MANAGED_INSTANCES: [&str; 2] = ["Tiramisu64", "Tiramisu64_2"];
pub const NORMAL_FPS: u8 = 60;
pub const DEFAULT_IDLE_FPS: u8 = 12;
pub const DEFAULT_IDLE_AFTER: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Activity {
    Active,
    Inactive,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InstanceSignals<'a> {
    pub instance_id: &'a str,
    pub running: bool,
    /// True activity, not merely a discovery or ADB connection.
    pub remote: Activity,
    pub local: Activity,
    /// Include MIRPG solver screenshot/video workers, not just RustDesk previews.
    pub solver_capture: Activity,
}

impl InstanceSignals<'_> {
    fn verified_idle(&self) -> bool {
        self.running
            && self.remote == Activity::Inactive
            && self.local == Activity::Inactive
            && self.solver_capture == Activity::Inactive
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EcoMode {
    /// Disable Eco; the backend must independently verify the instance's 60 FPS ceiling.
    Normal,
    Eco(u8),
}

impl EcoMode {
    pub fn target_fps(self) -> u8 {
        match self {
            Self::Normal => NORMAL_FPS,
            Self::Eco(fps) => fps,
        }
    }
}

/// A future live backend must compare state before changing anything and reject
/// an unrecognized/manual mode. The only current backend is the disarmed one.
pub trait EcoBackend {
    fn read_mode(&mut self, instance_id: &str) -> Result<EcoMode, String>;
    fn compare_and_set(
        &mut self,
        instance_id: &str,
        expected: EcoMode,
        requested: EcoMode,
    ) -> Result<(), String>;
}

/// No host commands, registry changes, BlueStacks config writes or ADB calls.
#[derive(Default)]
pub struct DisarmedBackend;

impl EcoBackend for DisarmedBackend {
    fn read_mode(&mut self, _instance_id: &str) -> Result<EcoMode, String> {
        Err("BlueStacks live Eco control is not approved or implemented".to_owned())
    }

    fn compare_and_set(
        &mut self,
        _instance_id: &str,
        _expected: EcoMode,
        _requested: EcoMode,
    ) -> Result<(), String> {
        Err("BlueStacks live Eco control is not approved or implemented".to_owned())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EcoPolicy {
    pub enabled: bool,
    pub idle_fps: u8,
    pub idle_after: Duration,
}

impl Default for EcoPolicy {
    fn default() -> Self {
        Self {
            enabled: false,
            idle_fps: DEFAULT_IDLE_FPS,
            idle_after: DEFAULT_IDLE_AFTER,
        }
    }
}

impl EcoPolicy {
    pub fn validate(&self) -> Result<(), String> {
        if !(10..=15).contains(&self.idle_fps) {
            return Err("Idle Eco FPS must be between 10 and 15".to_owned());
        }
        if !(Duration::from_secs(30)..=Duration::from_secs(600)).contains(&self.idle_after) {
            return Err("Idle confirmation must be between 30 and 600 seconds".to_owned());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EcoTransition {
    pub instance_id: String,
    pub requested: EcoMode,
    /// An error is an explicit rejection, not evidence that a mode was applied.
    pub result: Result<(), String>,
}

#[derive(Default)]
struct InstanceState {
    idle_since: Option<Duration>,
    /// Ownership is earned only after a successful compare-and-set.
    eco_owned: bool,
}

/// Pure per-instance controller: the caller supplies freshly observed activity
/// and elapsed monotonic time, while the backend owns all external interactions.
/// An active/unknown solver, remote or local signal always prevents entering Eco.
pub struct EcoController<B: EcoBackend> {
    policy: EcoPolicy,
    backend: B,
    states: BTreeMap<&'static str, InstanceState>,
}

impl<B: EcoBackend> EcoController<B> {
    pub fn new(policy: EcoPolicy, backend: B) -> Result<Self, String> {
        policy.validate()?;
        Ok(Self {
            policy,
            backend,
            states: MANAGED_INSTANCES
                .iter()
                .map(|id| (*id, InstanceState::default()))
                .collect(),
        })
    }

    /// Disabling restores only modes that this controller previously changed.
    /// A failed restore remains pending and is retried on a subsequent tick.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.policy.enabled = enabled;
    }

    pub fn reconcile(
        &mut self,
        now: Duration,
        observations: &[InstanceSignals<'_>],
    ) -> Vec<EcoTransition> {
        let mut transitions = Vec::new();
        for id in MANAGED_INSTANCES {
            let mut matches = observations.iter().filter(|item| item.instance_id == id);
            let Some(observation) = matches.next() else {
                self.states.get_mut(id).unwrap().idle_since = None;
                continue;
            };
            // Duplicate/missing identities or a stopped instance must never be
            // treated as a safe running target for a BlueStacks setting write.
            if matches.next().is_some() || !observation.running {
                self.states.get_mut(id).unwrap().idle_since = None;
                continue;
            }
            let state = self.states.get_mut(id).unwrap();
            let verified_idle = self.policy.enabled && observation.verified_idle();
            if verified_idle {
                state.idle_since.get_or_insert(now);
            } else {
                state.idle_since = None;
            }
            let desired = if state.eco_owned && !verified_idle {
                Some(EcoMode::Normal)
            } else if !state.eco_owned
                && verified_idle
                && now
                    .checked_sub(state.idle_since.unwrap_or(now))
                    .unwrap_or_default()
                    >= self.policy.idle_after
            {
                Some(EcoMode::Eco(self.policy.idle_fps))
            } else {
                None
            };
            let Some(requested) = desired else {
                continue;
            };
            let expected = if state.eco_owned {
                EcoMode::Eco(self.policy.idle_fps)
            } else {
                EcoMode::Normal
            };
            // Never adopt/overwrite a manually configured Eco mode.
            let result = if state.eco_owned {
                self.backend.compare_and_set(id, expected, requested)
            } else {
                match self.backend.read_mode(id) {
                    Ok(mode) if mode == EcoMode::Normal => {
                        self.backend.compare_and_set(id, expected, requested)
                    }
                    Ok(mode) => Err(format!(
                        "Manual/unknown BlueStacks mode {:?}; not taking ownership",
                        mode
                    )),
                    Err(error) => Err(error),
                }
            };
            if result.is_ok() {
                state.eco_owned = matches!(requested, EcoMode::Eco(_));
            }
            transitions.push(EcoTransition {
                instance_id: id.to_owned(),
                requested,
                result,
            });
        }
        transitions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct MockBackend {
        modes: BTreeMap<String, EcoMode>,
        writes: Vec<(String, EcoMode, EcoMode)>,
        fail_writes: bool,
    }

    impl MockBackend {
        fn with_normal_instances() -> Self {
            Self {
                modes: MANAGED_INSTANCES
                    .iter()
                    .map(|id| (id.to_string(), EcoMode::Normal))
                    .collect(),
                ..Default::default()
            }
        }
    }

    impl EcoBackend for MockBackend {
        fn read_mode(&mut self, id: &str) -> Result<EcoMode, String> {
            self.modes
                .get(id)
                .copied()
                .ok_or_else(|| "unknown instance".to_owned())
        }

        fn compare_and_set(
            &mut self,
            id: &str,
            expected: EcoMode,
            requested: EcoMode,
        ) -> Result<(), String> {
            if self.fail_writes {
                return Err("synthetic writer failure".to_owned());
            }
            if self.read_mode(id)? != expected {
                return Err("BlueStacks mode changed outside the controller".to_owned());
            }
            self.modes.insert(id.to_owned(), requested);
            self.writes.push((id.to_owned(), expected, requested));
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

    fn enabled() -> EcoPolicy {
        EcoPolicy {
            enabled: true,
            ..EcoPolicy::default()
        }
    }

    #[test]
    fn disabled_by_default_never_writes_idle_instances() {
        let mut controller =
            EcoController::new(EcoPolicy::default(), MockBackend::with_normal_instances()).unwrap();
        let observations: Vec<_> = MANAGED_INSTANCES.iter().map(|id| signals(id)).collect();
        assert!(controller
            .reconcile(Duration::ZERO, &observations)
            .is_empty());
        assert!(controller
            .reconcile(Duration::from_secs(900), &observations)
            .is_empty());
        assert!(controller.backend.writes.is_empty());
    }

    #[test]
    fn idle_then_remote_or_local_activity_restores_only_affected_instance() {
        let mut controller =
            EcoController::new(enabled(), MockBackend::with_normal_instances()).unwrap();
        let mut observations: Vec<_> = MANAGED_INSTANCES.iter().map(|id| signals(id)).collect();
        assert!(controller
            .reconcile(Duration::ZERO, &observations)
            .is_empty());
        assert!(controller
            .reconcile(Duration::from_secs(119), &observations)
            .is_empty());
        let report = controller.reconcile(Duration::from_secs(120), &observations);
        assert_eq!(report.len(), 2);
        assert!(report
            .iter()
            .all(|entry| entry.requested == EcoMode::Eco(12) && entry.result.is_ok()));
        observations[0].remote = Activity::Active;
        let report = controller.reconcile(Duration::from_secs(121), &observations);
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].instance_id, "Tiramisu64");
        assert_eq!(report[0].requested, EcoMode::Normal);
        assert_eq!(controller.backend.modes["Tiramisu64_2"], EcoMode::Eco(12));
        observations[1].local = Activity::Active;
        let report = controller.reconcile(Duration::from_secs(122), &observations);
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].instance_id, "Tiramisu64_2");
        assert_eq!(report[0].requested, EcoMode::Normal);
        assert!(controller
            .reconcile(Duration::from_secs(123), &observations)
            .is_empty());
    }

    #[test]
    fn unknown_and_active_solver_capture_never_throttle_and_force_restore() {
        let mut controller =
            EcoController::new(enabled(), MockBackend::with_normal_instances()).unwrap();
        let mut observation = signals(MANAGED_INSTANCES[0]);
        observation.solver_capture = Activity::Unknown;
        controller.reconcile(Duration::ZERO, &[observation]);
        assert!(controller
            .reconcile(Duration::from_secs(300), &[observation])
            .is_empty());
        observation.solver_capture = Activity::Inactive;
        controller.reconcile(Duration::from_secs(300), &[observation]);
        assert_eq!(
            controller
                .reconcile(Duration::from_secs(420), &[observation])
                .len(),
            1
        );
        observation.solver_capture = Activity::Active;
        let report = controller.reconcile(Duration::from_secs(421), &[observation]);
        assert_eq!(report[0].requested, EcoMode::Normal);
        assert!(report[0].result.is_ok());
    }

    #[test]
    fn unexpected_duplicate_stopped_and_unknown_instances_cannot_be_changed() {
        let mut controller =
            EcoController::new(enabled(), MockBackend::with_normal_instances()).unwrap();
        let mut stopped = signals(MANAGED_INSTANCES[0]);
        stopped.running = false;
        let unknown = signals("NotMyBlueStacks");
        let inputs = [
            stopped,
            signals(MANAGED_INSTANCES[1]),
            signals(MANAGED_INSTANCES[1]),
            unknown,
        ];
        controller.reconcile(Duration::ZERO, &inputs);
        assert!(controller
            .reconcile(Duration::from_secs(300), &inputs)
            .is_empty());
        assert!(controller.backend.writes.is_empty());
    }

    #[test]
    fn disable_recovers_owned_modes_without_touching_unowned_manual_eco() {
        let mut backend = MockBackend::with_normal_instances();
        backend
            .modes
            .insert(MANAGED_INSTANCES[1].to_owned(), EcoMode::Eco(5));
        let mut controller = EcoController::new(enabled(), backend).unwrap();
        let observations: Vec<_> = MANAGED_INSTANCES.iter().map(|id| signals(id)).collect();
        controller.reconcile(Duration::ZERO, &observations);
        let report = controller.reconcile(Duration::from_secs(120), &observations);
        assert_eq!(report.len(), 2);
        assert!(report[1].result.is_err());
        controller.set_enabled(false);
        let report = controller.reconcile(Duration::from_secs(121), &observations);
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].requested, EcoMode::Normal);
        assert!(report[0].result.is_ok());
        assert_eq!(
            controller.backend.modes[MANAGED_INSTANCES[1]],
            EcoMode::Eco(5)
        );
    }

    #[test]
    fn failed_restore_keeps_ownership_until_success_or_manual_resolution() {
        let mut controller =
            EcoController::new(enabled(), MockBackend::with_normal_instances()).unwrap();
        let mut observation = signals(MANAGED_INSTANCES[0]);
        controller.reconcile(Duration::ZERO, &[observation]);
        controller.reconcile(Duration::from_secs(120), &[observation]);
        observation.remote = Activity::Active;
        controller.backend.fail_writes = true;
        let report = controller.reconcile(Duration::from_secs(121), &[observation]);
        assert!(report[0].result.is_err());
        assert_eq!(
            controller.backend.modes[MANAGED_INSTANCES[0]],
            EcoMode::Eco(12)
        );
        controller.backend.fail_writes = false;
        assert!(
            controller.reconcile(Duration::from_secs(122), &[observation])[0]
                .result
                .is_ok()
        );
        assert_eq!(
            controller.backend.modes[MANAGED_INSTANCES[0]],
            EcoMode::Normal
        );
    }

    #[test]
    fn manual_mode_conflict_is_not_overwritten_even_during_restore() {
        let mut controller =
            EcoController::new(enabled(), MockBackend::with_normal_instances()).unwrap();
        let mut observation = signals(MANAGED_INSTANCES[0]);
        controller.reconcile(Duration::ZERO, &[observation]);
        controller.reconcile(Duration::from_secs(120), &[observation]);
        controller
            .backend
            .modes
            .insert(MANAGED_INSTANCES[0].to_owned(), EcoMode::Eco(11));
        observation.local = Activity::Active;
        assert!(
            controller.reconcile(Duration::from_secs(121), &[observation])[0]
                .result
                .is_err()
        );
        assert_eq!(
            controller.backend.modes[MANAGED_INSTANCES[0]],
            EcoMode::Eco(11)
        );
    }

    #[test]
    fn disarmed_backend_and_invalid_policies_fail_closed() {
        assert!(!EcoPolicy::default().enabled);
        assert_eq!(EcoMode::Normal.target_fps(), 60);
        assert_eq!(EcoMode::Eco(12).target_fps(), 12);
        assert!(EcoController::new(
            EcoPolicy {
                idle_fps: 5,
                ..enabled()
            },
            DisarmedBackend
        )
        .is_err());
        assert!(EcoController::new(
            EcoPolicy {
                idle_after: Duration::from_secs(0),
                ..enabled()
            },
            DisarmedBackend
        )
        .is_err());
        let mut controller = EcoController::new(enabled(), DisarmedBackend).unwrap();
        let observation = signals(MANAGED_INSTANCES[0]);
        controller.reconcile(Duration::ZERO, &[observation]);
        let report = controller.reconcile(Duration::from_secs(120), &[observation]);
        assert_eq!(report.len(), 1);
        assert!(report[0]
            .result
            .as_ref()
            .unwrap_err()
            .contains("not approved"));
    }
}
