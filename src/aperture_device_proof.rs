//! Device-key login proof: a paired phone signs the host's login challenge.

use base::message_proto::{DeviceProof, Hash};
use hbb_common::sodiumoxide::crypto::sign;

const DOMAIN_TAG: &[u8] = b"aperture-device-login-v1";
const PROOF_VERSION: u32 = 1;

fn push_field(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(bytes);
}

/// The signed bytes: domain tag, then each field length-prefixed (u32 LE).
pub fn proof_message(host_id: &str, salt: &str, challenge: &str, conn_type: i32) -> Vec<u8> {
    let mut out = Vec::with_capacity(
        DOMAIN_TAG.len() + 16 + host_id.len() + salt.len() + challenge.len() + 4,
    );
    out.extend_from_slice(DOMAIN_TAG);
    push_field(&mut out, host_id.as_bytes());
    push_field(&mut out, salt.as_bytes());
    push_field(&mut out, challenge.as_bytes());
    push_field(&mut out, &conn_type.to_le_bytes());
    out
}

pub fn sign_proof(sk: &sign::SecretKey, host_id: &str, hash: &Hash, conn_type: i32) -> DeviceProof {
    let msg = proof_message(host_id, &hash.salt, &hash.challenge, conn_type);
    let sig = sign::sign_detached(&msg, sk);
    DeviceProof {
        public_key: sk.public_key().0.to_vec().into(),
        signature: sig.to_bytes().to_vec().into(),
        version: PROOF_VERSION,
        ..Default::default()
    }
}

pub fn verify_proof(proof: &DeviceProof, host_id: &str, hash: &Hash, conn_type: i32) -> bool {
    if proof.version != PROOF_VERSION {
        return false;
    }
    let Some(pk) = sign::PublicKey::from_slice(&proof.public_key) else {
        return false;
    };
    let Ok(sig) = sign::Signature::from_bytes(&proof.signature) else {
        return false;
    };
    let msg = proof_message(host_id, &hash.salt, &hash.challenge, conn_type);
    sign::verify_detached(&sig, &msg, &pk)
}

pub fn public_key_b64(pk: &[u8]) -> String {
    crate::encode64(pk)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hash(challenge: &str) -> Hash {
        Hash {
            salt: "s".to_owned(),
            challenge: challenge.to_owned(),
            ..Default::default()
        }
    }

    #[test]
    fn valid_proof_verifies() {
        let (_pk, sk) = sign::gen_keypair();
        let proof = sign_proof(&sk, "373491561", &hash("c"), 0);
        assert!(verify_proof(&proof, "373491561", &hash("c"), 0));
    }

    #[test]
    fn proof_does_not_verify_for_other_challenge_or_host() {
        let (_pk, sk) = sign::gen_keypair();
        let proof = sign_proof(&sk, "373491561", &hash("c"), 0);
        assert!(!verify_proof(&proof, "373491561", &hash("c2"), 0));
        assert!(!verify_proof(&proof, "999", &hash("c"), 0));
        assert!(!verify_proof(&proof, "373491561", &hash("c"), 1));
    }

    #[test]
    fn fields_cannot_run_together() {
        assert_ne!(
            proof_message("ab", "c", "d", 0),
            proof_message("a", "bc", "d", 0)
        );
    }

    #[test]
    fn wrong_version_or_lengths_rejected() {
        let (_pk, sk) = sign::gen_keypair();
        let good = sign_proof(&sk, "373491561", &hash("c"), 0);
        let mut p = good.clone();
        p.version = 2;
        assert!(!verify_proof(&p, "373491561", &hash("c"), 0));
        let mut p = good.clone();
        p.public_key = p.public_key[..31].to_vec().into();
        assert!(!verify_proof(&p, "373491561", &hash("c"), 0));
        let mut p = good;
        p.signature = p.signature[..63].to_vec().into();
        assert!(!verify_proof(&p, "373491561", &hash("c"), 0));
    }
}
