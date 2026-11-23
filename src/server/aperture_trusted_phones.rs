//! Host-side list of phones whose device key may log in without a password.
//! The service process is the only writer; the UI removes entries through IPC.

use crate::aperture_device_proof::public_key_b64;
use hbb_common::config::Config;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Mutex};

pub const OPTION_KEY: &str = "aperture-trusted-phones";

/// Held across every read-modify-write of the stored list (sync code only, no await inside).
static WRITE_LOCK: Mutex<()> = Mutex::new(());

fn lock() -> std::sync::MutexGuard<'static, ()> {
    WRITE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TrustedPhone {
    /// Base64 of the phone's public signing key.
    pub public_key: String,
    pub name: String,
    pub added_unix: u64,
    pub last_used_unix: u64,
}

/// Corrupt or empty input reads as an empty list.
pub fn parse(json: &str) -> Vec<TrustedPhone> {
    serde_json::from_str(json).unwrap_or_default()
}

pub fn list() -> Vec<TrustedPhone> {
    parse(&Config::get_option(OPTION_KEY))
}

fn save(list: &[TrustedPhone]) {
    match serde_json::to_string(list) {
        Ok(json) => Config::set_option(OPTION_KEY.to_owned(), json),
        Err(e) => hbb_common::log::error!("Failed to serialize trusted phones: {}", e),
    }
}

pub fn is_trusted(public_key: &[u8]) -> bool {
    let key = public_key_b64(public_key);
    list().iter().any(|p| p.public_key == key)
}

/// Returns true if the key was newly added; an existing key keeps one entry and gets the new name.
pub fn add(public_key: &[u8], name: &str, now_unix: u64) -> bool {
    let _guard = lock();
    let (updated, added) = add_to(list(), public_key, name, now_unix);
    save(&updated);
    added
}

pub fn remove(public_key_b64: &str) -> bool {
    let _guard = lock();
    let (updated, removed) = remove_from(list(), public_key_b64);
    if removed {
        save(&updated);
    }
    removed
}

pub fn touch(public_key: &[u8], now_unix: u64) {
    let key = public_key_b64(public_key);
    let _guard = lock();
    let (updated, touched) = touch_in(list(), &key, now_unix);
    if touched {
        save(&updated);
    }
}

/// Whole-map options replace from the UI: keep the service's own trusted-phone list,
/// ignoring whatever the incoming map carries for that key (the UI never writes it).
pub fn apply_options(incoming: HashMap<String, String>) {
    let _guard = lock();
    let merged = preserve_list(incoming, &Config::get_option(OPTION_KEY));
    Config::set_options(merged);
}

fn preserve_list(mut incoming: HashMap<String, String>, current: &str) -> HashMap<String, String> {
    if current.is_empty() {
        incoming.remove(OPTION_KEY);
    } else {
        incoming.insert(OPTION_KEY.to_owned(), current.to_owned());
    }
    incoming
}

fn add_to(
    mut list: Vec<TrustedPhone>,
    public_key: &[u8],
    name: &str,
    now_unix: u64,
) -> (Vec<TrustedPhone>, bool) {
    let key = public_key_b64(public_key);
    if let Some(existing) = list.iter_mut().find(|p| p.public_key == key) {
        existing.name = name.to_owned();
        return (list, false);
    }
    list.push(TrustedPhone {
        public_key: key,
        name: name.to_owned(),
        added_unix: now_unix,
        last_used_unix: now_unix,
    });
    (list, true)
}

fn remove_from(mut list: Vec<TrustedPhone>, public_key_b64: &str) -> (Vec<TrustedPhone>, bool) {
    let before = list.len();
    list.retain(|p| p.public_key != public_key_b64);
    let removed = list.len() != before;
    (list, removed)
}

fn touch_in(
    mut list: Vec<TrustedPhone>,
    public_key_b64: &str,
    now_unix: u64,
) -> (Vec<TrustedPhone>, bool) {
    let mut touched = false;
    if let Some(p) = list.iter_mut().find(|p| p.public_key == public_key_b64) {
        p.last_used_unix = now_unix;
        touched = true;
    }
    (list, touched)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corrupt_list_reads_as_empty() {
        assert_eq!(parse("{not json"), vec![]);
        assert_eq!(parse(""), vec![]);
    }

    #[test]
    fn adding_same_key_twice_keeps_one_entry() {
        let (list, added) = add_to(vec![], &[1, 2, 3], "Pixel", 10);
        assert!(added);
        let (list, added) = add_to(list, &[1, 2, 3], "Pixel 9", 20);
        assert!(!added);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "Pixel 9");
        assert_eq!(list[0].added_unix, 10);
    }

    #[test]
    fn remove_deletes_only_that_key() {
        let (list, _) = add_to(vec![], &[1], "A", 1);
        let (list, _) = add_to(list, &[2], "B", 1);
        let (list, removed) = remove_from(list, &public_key_b64(&[1]));
        assert!(removed);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].public_key, public_key_b64(&[2]));
        let (list, removed) = remove_from(list, &public_key_b64(&[9]));
        assert!(!removed);
        assert_eq!(list.len(), 1);
    }

    #[test]
    fn whole_map_replace_preserves_current_list() {
        let mut incoming = HashMap::new();
        incoming.insert("other".to_owned(), "1".to_owned());
        incoming.insert(OPTION_KEY.to_owned(), "[stale]".to_owned());
        let merged = preserve_list(incoming.clone(), "[current]");
        assert_eq!(merged.get(OPTION_KEY).map(String::as_str), Some("[current]"));
        assert_eq!(merged.get("other").map(String::as_str), Some("1"));
        let merged = preserve_list(incoming, "");
        assert!(!merged.contains_key(OPTION_KEY));
    }

    #[test]
    fn touch_updates_last_used_only() {
        let (list, _) = add_to(vec![], &[1], "A", 5);
        let (list, touched) = touch_in(list, &public_key_b64(&[1]), 99);
        assert!(touched);
        assert_eq!(list[0].last_used_unix, 99);
        assert_eq!(list[0].added_unix, 5);
    }
}
