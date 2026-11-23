//! The phone's device-signing key and its per-host pairing state.

use super::ConnType;
use base::message_proto::DeviceProof;
use hbb_common::{config::LocalConfig, sodiumoxide::crypto::sign};
use std::sync::Mutex;

/// LocalConfig option holding the base64 of the 64-byte signing secret key.
pub const KEY_OPTION: &str = "aperture-device-sign-sk";
/// PeerConfig option set to `Y` once the host accepted this phone's key.
pub const PAIRED_OPTION: &str = "aperture-device-paired";

static KEY_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn decode_key(stored: &str) -> Option<sign::SecretKey> {
    if stored.is_empty() {
        return None;
    }
    let bytes = crate::decode64(stored).ok()?;
    sign::SecretKey::from_slice(&bytes)
}

/// Returns the stored key, or creates, stores and returns a new one.
pub(crate) fn load_or_create_key_with(
    get: impl FnOnce() -> String,
    set: impl FnOnce(String),
) -> sign::SecretKey {
    if let Some(sk) = decode_key(&get()) {
        return sk;
    }
    let (_pk, sk) = sign::gen_keypair();
    set(crate::encode64(&sk.0[..]));
    sk
}

/// The phone's signing key (LocalConfig `aperture-device-sign-sk`), created once.
pub fn load_or_create_key() -> sign::SecretKey {
    let _guard = KEY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    load_or_create_key_with(
        || LocalConfig::get_option(KEY_OPTION),
        |v| LocalConfig::set_option(KEY_OPTION.to_owned(), v),
    )
}

pub fn is_paired_value(value: &str) -> bool {
    value == "Y"
}

/// A proof goes only over the encrypted LAN fast path, to a host this phone
/// paired with, on the main remote connection.
pub fn should_send_proof(via_secure_lan: bool, paired: bool, conn_type: ConnType) -> bool {
    via_secure_lan && paired && conn_type == ConnType::DEFAULT_CONN
}

#[derive(Debug, PartialEq, Eq)]
pub enum RetryAction {
    /// Run the login again with the same hash; it now takes the password path.
    RerunHash,
    /// No proof was in flight: treat the error like any other login error.
    None,
}

/// The host refused the key: forget the pairing and retry with the password.
pub fn on_device_key_rejected(paired: &mut bool, proof: &mut Option<DeviceProof>) -> RetryAction {
    *paired = false;
    if proof.take().is_some() {
        RetryAction::RerunHash
    } else {
        RetryAction::None
    }
}

/// `"paired"`, `"can-pair"` (authorized, not via the key) or `"unavailable"`.
pub fn pairing_state(paired: bool, authorized: bool, logged_in_with_key: bool) -> &'static str {
    if paired {
        "paired"
    } else if authorized && !logged_in_with_key {
        "can-pair"
    } else {
        "unavailable"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn should_send_proof_only_on_secure_lan_paired_default_conn() {
        assert!(should_send_proof(true, true, ConnType::DEFAULT_CONN));
        assert!(!should_send_proof(false, true, ConnType::DEFAULT_CONN));
        assert!(!should_send_proof(true, false, ConnType::DEFAULT_CONN));
        assert!(!should_send_proof(true, true, ConnType::FILE_TRANSFER));
        assert!(!should_send_proof(true, true, ConnType::TERMINAL));
        assert!(!should_send_proof(true, true, ConnType::PORT_FORWARD));
    }

    #[test]
    fn key_is_created_once_and_reused() {
        let store = RefCell::new(String::new());
        let first = load_or_create_key_with(|| store.borrow().clone(), |v| *store.borrow_mut() = v);
        assert!(!store.borrow().is_empty());
        let saved = store.borrow().clone();
        let second = load_or_create_key_with(|| store.borrow().clone(), |v| *store.borrow_mut() = v);
        assert_eq!(first.public_key(), second.public_key());
        assert_eq!(*store.borrow(), saved);
    }

    #[test]
    fn invalid_stored_key_is_replaced() {
        let store = RefCell::new("not-a-key".to_owned());
        let key = load_or_create_key_with(|| store.borrow().clone(), |v| *store.borrow_mut() = v);
        assert_eq!(decode_key(&store.borrow()).map(|k| k.public_key()), Some(key.public_key()));
    }

    #[test]
    fn rejection_clears_paired_flag_and_retries_with_password() {
        let (_pk, sk) = sign::gen_keypair();
        let mut paired = true;
        let mut proof = Some(crate::aperture_device_proof::sign_proof(
            &sk,
            "1",
            &Default::default(),
            0,
        ));
        assert_eq!(on_device_key_rejected(&mut paired, &mut proof), RetryAction::RerunHash);
        assert!(!paired);
        assert!(proof.is_none());
        // Without a proof in flight there is nothing to retry, so it cannot loop.
        assert_eq!(on_device_key_rejected(&mut paired, &mut proof), RetryAction::None);
        assert!(!should_send_proof(true, paired, ConnType::DEFAULT_CONN));
    }

    #[test]
    fn pairing_state_values() {
        assert_eq!(pairing_state(true, false, false), "paired");
        assert_eq!(pairing_state(true, true, true), "paired");
        assert_eq!(pairing_state(false, true, false), "can-pair");
        assert_eq!(pairing_state(false, true, true), "unavailable");
        assert_eq!(pairing_state(false, false, false), "unavailable");
    }
}
