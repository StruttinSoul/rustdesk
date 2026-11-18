//! Memory, CPU cores and screen of a managed Android emulator, chosen on the
//! phone. The choice is kept next to the emulator (`aperture-settings.json` in
//! its folder) and written to its `config.ini` only while it is stopped: at
//! once when it is stopped, otherwise at its next start. A running emulator's
//! `config.ini` is never rewritten.

use super::remote::{AVD_CORE_CHOICES, AVD_RAM_CHOICES_MB, AVD_SCREEN_CHOICES};
use hbb_common::{anyhow::Context, bail, ResultType};
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

pub const SETTINGS_FILE: &str = "aperture-settings.json";

/// Settings of one emulator; `None` leaves a setting as it is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AvdSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ram_mb: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cores: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen: Option<(u32, u32)>,
}

impl AvdSettings {
    /// The change a request asks for; 0 leaves a setting as it is. Only the
    /// values the phone offers are accepted.
    pub fn requested(ram_mb: u32, cores: u32, width: u32, height: u32) -> ResultType<Self> {
        let settings = Self {
            ram_mb: (ram_mb != 0).then_some(ram_mb),
            cores: (cores != 0).then_some(cores),
            screen: ((width, height) != (0, 0)).then_some((width, height)),
        };
        if settings.ram_mb.map_or(false, |ram| !AVD_RAM_CHOICES_MB.contains(&ram)) {
            bail!("Memory must be 2, 3, 4, 6 or 8 GB")
        }
        if settings.cores.map_or(false, |cores| !AVD_CORE_CHOICES.contains(&cores)) {
            bail!("CPU cores must be 2, 4, 6 or 8")
        }
        if settings.screen.map_or(false, |screen| !AVD_SCREEN_CHOICES.contains(&screen)) {
            bail!("The screen must be 1080 x 2208 or 1080 x 2400")
        }
        if settings.is_empty() {
            bail!("No setting to change")
        }
        Ok(settings)
    }

    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// These settings with `newer`'s values where it has one.
    pub fn merged(self, newer: Self) -> Self {
        Self {
            ram_mb: newer.ram_mb.or(self.ram_mb),
            cores: newer.cores.or(self.cores),
            screen: newer.screen.or(self.screen),
        }
    }

    /// The settings `current` does not have yet.
    pub fn unapplied(&self, current: &Self) -> Self {
        let differs = |chosen: Option<u32>, now: Option<u32>| chosen.filter(|_| chosen != now);
        Self {
            ram_mb: differs(self.ram_mb, current.ram_mb),
            cores: differs(self.cores, current.cores),
            screen: self.screen.filter(|_| self.screen != current.screen),
        }
    }

    /// Drops values a hand-edited file may hold that the phone cannot offer.
    fn offered_only(self) -> Self {
        Self {
            ram_mb: self.ram_mb.filter(|ram| AVD_RAM_CHOICES_MB.contains(ram)),
            cores: self.cores.filter(|cores| AVD_CORE_CHOICES.contains(cores)),
            screen: self.screen.filter(|screen| AVD_SCREEN_CHOICES.contains(screen)),
        }
    }

    /// The phone's field names; a missing setting is left out.
    pub fn to_json(&self) -> serde_json::Value {
        let mut value = serde_json::json!({});
        if let Some(ram) = self.ram_mb {
            value["ram_mb"] = ram.into();
        }
        if let Some(cores) = self.cores {
            value["cpu_cores"] = cores.into();
        }
        if let Some((width, height)) = self.screen {
            value["screen_width"] = width.into();
            value["screen_height"] = height.into();
        }
        value
    }
}

/// "memory 4096 -> 6144 MB, cores 4 -> 6, screen 1080x2400 -> 1080x2208" for
/// the settings in `change`, with their values in `before`.
pub fn describe_change(before: &AvdSettings, change: &AvdSettings) -> String {
    let number = |value: Option<u32>| value.map_or("?".to_owned(), |n| n.to_string());
    let screen = |value: Option<(u32, u32)>| value.map_or("?".to_owned(), |(w, h)| format!("{w}x{h}"));
    let mut parts = Vec::new();
    if let Some(ram) = change.ram_mb {
        parts.push(format!("memory {} -> {ram} MB", number(before.ram_mb)));
    }
    if let Some(cores) = change.cores {
        parts.push(format!("cores {} -> {cores}", number(before.cores)));
    }
    if change.screen.is_some() {
        parts.push(format!("screen {} -> {}", screen(before.screen), screen(change.screen)));
    }
    parts.join(", ")
}

/// The settings chosen on the phone for the emulator in `avd_dir`; none when
/// nothing was chosen yet.
pub fn load(avd_dir: &Path) -> ResultType<AvdSettings> {
    let path = avd_dir.join(SETTINGS_FILE);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AvdSettings::default())
        }
        Err(error) => return Err(error).context("Cannot read the emulator's settings"),
    };
    let settings: AvdSettings =
        serde_json::from_str(&text).context("The emulator's settings file is damaged")?;
    Ok(settings.offered_only())
}

/// Replaces the chosen settings in one step, so a start never reads half a file.
pub fn store(avd_dir: &Path, settings: &AvdSettings) -> ResultType<()> {
    let path = avd_dir.join(SETTINGS_FILE);
    let temp = avd_dir.join(format!("{SETTINGS_FILE}.tmp"));
    let written = fs::write(&temp, serde_json::to_string(settings)?)
        .and_then(|()| fs::rename(&temp, &path));
    if let Err(error) = written {
        if let Err(cleanup) = fs::remove_file(&temp) {
            hbb_common::log::trace!("Removing {}: {cleanup}", temp.display());
        }
        return Err(error).context("Cannot save the emulator's settings");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_take_only_offered_values() {
        let change = AvdSettings::requested(6144, 0, 1080, 2400).unwrap();
        assert_eq!(change.ram_mb, Some(6144));
        assert_eq!(change.cores, None);
        assert_eq!(change.screen, Some((1080, 2400)));
        assert!(AvdSettings::requested(0, 0, 0, 0).is_err());
        assert!(AvdSettings::requested(5000, 0, 0, 0).is_err());
        assert!(AvdSettings::requested(0, 3, 0, 0).is_err());
        assert!(AvdSettings::requested(0, 0, 1080, 1920).is_err());
        assert!(AvdSettings::requested(0, 0, 1080, 0).is_err());
    }

    #[test]
    fn a_later_choice_overrides_only_what_it_sets() {
        let first = AvdSettings::requested(6144, 6, 0, 0).unwrap();
        let later = AvdSettings::requested(0, 2, 1080, 2400).unwrap();
        let merged = first.merged(later);
        assert_eq!(merged, AvdSettings { ram_mb: Some(6144), cores: Some(2), screen: Some((1080, 2400)) });
    }

    #[test]
    fn unapplied_lists_what_the_config_does_not_have() {
        let chosen = AvdSettings { ram_mb: Some(6144), cores: Some(4), screen: Some((1080, 2400)) };
        let current = AvdSettings { ram_mb: Some(4096), cores: Some(4), screen: Some((1080, 2400)) };
        assert_eq!(chosen.unapplied(&current), AvdSettings { ram_mb: Some(6144), ..Default::default() });
        assert!(chosen.unapplied(&chosen).is_empty());
    }

    #[test]
    fn the_file_round_trips_and_ignores_values_the_phone_cannot_offer() {
        let dir = std::env::temp_dir().join(format!("aperture-avd-settings-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        assert!(load(&dir).unwrap().is_empty());
        let chosen = AvdSettings { ram_mb: Some(8192), cores: Some(8), screen: Some((1080, 2208)) };
        store(&dir, &chosen).unwrap();
        assert_eq!(load(&dir).unwrap(), chosen);
        assert!(!dir.join(format!("{SETTINGS_FILE}.tmp")).exists());
        fs::write(dir.join(SETTINGS_FILE), r#"{"ram_mb":99999,"cores":4,"screen":[1,2]}"#).unwrap();
        assert_eq!(load(&dir).unwrap(), AvdSettings { cores: Some(4), ..Default::default() });
        fs::write(dir.join(SETTINGS_FILE), "not json").unwrap();
        assert!(load(&dir).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn json_uses_the_phone_field_names() {
        let chosen = AvdSettings { ram_mb: Some(2048), cores: None, screen: Some((1080, 2400)) };
        assert_eq!(
            chosen.to_json(),
            serde_json::json!({"ram_mb": 2048, "screen_width": 1080, "screen_height": 2400})
        );
    }
}
